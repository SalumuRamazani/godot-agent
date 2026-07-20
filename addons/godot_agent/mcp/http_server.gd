@tool
extends RefCounted
## Minimal MCP "streamable HTTP" server: JSON-RPC over HTTP POST with plain
## application/json responses (no SSE — allowed by the MCP spec). Binds to
## 127.0.0.1 only. poll() must be called every frame from the main thread;
## tool handlers therefore run on the main thread, which the editor requires.

const MAX_REQUEST_BYTES := 4 * 1024 * 1024
const PROTOCOL_FALLBACK := "2025-03-26"
const SERVER_NAME := "godot_editor"
const SERVER_VERSION := "0.1.0"

var port: int = 0
var tools  # mcp/tools.gd instance (duck-typed: list_tools(), call_tool())

var _server := TCPServer.new()
var _conns: Array[Dictionary] = []
var _pending := {}  # async ticket -> {"conn": Dictionary, "id": Variant}


func start(preferred: int = 8765, tries: int = 10) -> Error:
	for i in range(tries):
		if _server.listen(preferred + i, "127.0.0.1") == OK:
			port = preferred + i
			return OK
	return FAILED


func stop() -> void:
	for c in _conns:
		var peer: StreamPeerTCP = c["peer"]
		peer.disconnect_from_host()
	_conns.clear()
	_pending.clear()
	tools = null
	_server.stop()
	port = 0


## Finish a parked (async) tools/call — e.g. once the user clicks Allow/Deny.
func complete_async(ticket: String, out: Dictionary) -> void:
	var entry = _pending.get(ticket)
	if entry == null:
		return
	_pending.erase(ticket)
	var envelope := _result(entry["id"], {
		"content": [{"type": "text", "text": String(out.get("text", ""))}],
		"isError": bool(out.get("is_error", false)),
	})
	_respond(entry["conn"], 200, JSON.stringify(envelope))


func poll() -> void:
	while _server.is_connection_available():
		var peer := _server.take_connection()
		if peer != null:
			peer.set_no_delay(true)
			_conns.append({"peer": peer, "buf": PackedByteArray(), "headers": {}, "stage": "headers", "method": "", "path": "", "content_length": 0, "done": false})
	for c in _conns:
		_poll_conn(c)
	_conns = _conns.filter(func(c): return not c["done"])


func _poll_conn(c: Dictionary) -> void:
	var peer: StreamPeerTCP = c["peer"]
	peer.poll()
	var status := peer.get_status()
	if status == StreamPeerTCP.STATUS_ERROR or status == StreamPeerTCP.STATUS_NONE:
		c["done"] = true
		if c.has("ticket"):
			_pending.erase(c["ticket"])  # client gave up while parked
		return
	if status != StreamPeerTCP.STATUS_CONNECTED:
		return
	if c["stage"] == "parked":
		return  # waiting for complete_async
	var avail := peer.get_available_bytes()
	if avail > 0:
		var res := peer.get_data(avail)
		if res[0] == OK:
			var buf: PackedByteArray = c["buf"]
			buf.append_array(res[1])
			c["buf"] = buf
	var buf: PackedByteArray = c["buf"]
	if buf.size() > MAX_REQUEST_BYTES:
		_respond(c, 400, "{\"error\":\"request too large\"}")
		return
	if c["stage"] == "headers":
		var text := buf.get_string_from_utf8()
		var head_end := text.find("\r\n\r\n")
		if head_end < 0:
			return
		var head := text.substr(0, head_end)
		var lines := head.split("\r\n")
		var req_parts := lines[0].split(" ")
		if req_parts.size() < 2:
			_respond(c, 400, "")
			return
		c["method"] = req_parts[0]
		c["path"] = req_parts[1]
		var headers := {}
		for i in range(1, lines.size()):
			var idx := lines[i].find(":")
			if idx > 0:
				headers[lines[i].substr(0, idx).strip_edges().to_lower()] = lines[i].substr(idx + 1).strip_edges()
		c["headers"] = headers
		c["content_length"] = int(headers.get("content-length", "0"))
		# Keep only the body bytes in the buffer. head_end is a character
		# index; recompute as byte offset to survive multibyte header values.
		var head_bytes := text.substr(0, head_end + 4).to_utf8_buffer().size()
		c["buf"] = buf.slice(head_bytes)
		c["stage"] = "body"
	if c["stage"] == "body":
		var body_buf: PackedByteArray = c["buf"]
		if body_buf.size() < c["content_length"]:
			return
		var body := body_buf.slice(0, c["content_length"]).get_string_from_utf8()
		_handle_http(c, c["method"], c["path"], body)


func _handle_http(c: Dictionary, method: String, path: String, body: String) -> void:
	if not path.begins_with("/mcp"):
		_respond(c, 404, "{\"error\":\"not found\"}")
		return
	match method:
		"POST":
			_handle_jsonrpc(c, body)
		"DELETE":
			_respond(c, 200, "")
		"GET":
			_respond(c, 405, "")  # no SSE stream offered
		_:
			_respond(c, 405, "")


func _handle_jsonrpc(c: Dictionary, body: String) -> void:
	var parsed = JSON.parse_string(body)
	if parsed == null:
		_respond(c, 400, JSON.stringify({"jsonrpc": "2.0", "id": null, "error": {"code": -32700, "message": "parse error"}}))
		return
	if parsed is Array:
		var responses := []
		for msg in parsed:
			if msg is Dictionary and msg.has("id"):
				responses.append(_dispatch(msg, {}))
		if responses.is_empty():
			_respond(c, 202, "")
		else:
			_respond(c, 200, JSON.stringify(responses))
		return
	if not (parsed is Dictionary):
		_respond(c, 400, "")
		return
	if not parsed.has("id"):
		_respond(c, 202, "")  # notification (e.g. notifications/initialized)
		return
	var envelope := _dispatch(parsed, c)
	if envelope.get("__parked", false):
		c["stage"] = "parked"
		return
	_respond(c, 200, JSON.stringify(envelope))


func _dispatch(msg: Dictionary, conn: Dictionary) -> Dictionary:
	var id = msg.get("id")
	var method := String(msg.get("method", ""))
	var params = msg.get("params", {})
	if not (params is Dictionary):
		params = {}
	match method:
		"initialize":
			var proto = params.get("protocolVersion", PROTOCOL_FALLBACK)
			if not (proto is String):
				proto = PROTOCOL_FALLBACK
			return _result(id, {
				"protocolVersion": proto,
				"capabilities": {"tools": {}},
				"serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
			})
		"ping":
			return _result(id, {})
		"tools/list":
			return _result(id, {"tools": tools.list_tools()})
		"tools/call":
			var tool_name := String(params.get("name", ""))
			var args = params.get("arguments", {})
			if not (args is Dictionary):
				args = {}
			var out: Dictionary = tools.call_tool(tool_name, args)
			if String(out.get("async_ticket", "")) != "":
				if conn.is_empty():
					return {"jsonrpc": "2.0", "id": id, "error": {"code": -32000, "message": "async tools unsupported in batch requests"}}
				var ticket := String(out["async_ticket"])
				conn["ticket"] = ticket
				_pending[ticket] = {"conn": conn, "id": id}
				return {"__parked": true}
			var content := []
			if String(out.get("image_b64", "")) != "":
				content.append({"type": "image", "data": String(out["image_b64"]), "mimeType": "image/png"})
			content.append({"type": "text", "text": String(out.get("text", ""))})
			return _result(id, {
				"content": content,
				"isError": bool(out.get("is_error", false)),
			})
		_:
			return {"jsonrpc": "2.0", "id": id, "error": {"code": -32601, "message": "method not found: " + method}}


func _result(id, result: Dictionary) -> Dictionary:
	return {"jsonrpc": "2.0", "id": id, "result": result}


func _respond(c: Dictionary, code: int, body: String) -> void:
	var status_text: String = {200: "OK", 202: "Accepted", 400: "Bad Request", 404: "Not Found", 405: "Method Not Allowed"}.get(code, "OK")
	var b := body.to_utf8_buffer()
	var head := "HTTP/1.1 %d %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % [code, status_text, b.size()]
	var peer: StreamPeerTCP = c["peer"]
	peer.put_data(head.to_utf8_buffer())
	if b.size() > 0:
		peer.put_data(b)
	peer.disconnect_from_host()
	c["done"] = true
