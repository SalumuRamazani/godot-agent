extends SceneTree
## Headless MCP protocol test: starts the in-editor HTTP server (with editor
## tools disabled, so only `echo` is exposed), then performs real HTTP
## round-trips over loopback with a StreamPeerTCP client.
## Run from the repo root:  godot --headless -s tests/test_mcp_server.gd

const McpServer := preload("res://addons/godot_agent/mcp/http_server.gd")
const McpTools := preload("res://addons/godot_agent/mcp/tools.gd")

var _failures := 0


func _initialize() -> void:
	var tools := McpTools.new()
	tools.editor_enabled = false
	var server := McpServer.new()
	server.tools = tools
	tools.server = server
	if server.start(9210) != OK:
		push_error("could not bind test port")
		quit(1)
		return

	# initialize
	var resp := _rpc(server, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "test", "version": "0"}}})
	_check("initialize returns serverInfo", resp.get("result", {}).get("serverInfo", {}).get("name", "") == "godot_editor")
	_check("initialize echoes protocolVersion", resp.get("result", {}).get("protocolVersion", "") == "2025-06-18")

	# notifications/initialized -> 202, empty body
	var raw := _http(server, JSON.stringify({"jsonrpc": "2.0", "method": "notifications/initialized"}))
	_check("notification gets 202", raw.begins_with("HTTP/1.1 202"))

	# tools/list
	resp = _rpc(server, {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
	var tool_list: Array = resp.get("result", {}).get("tools", [])
	var names: Array = tool_list.map(func(t): return t.get("name", ""))
	_check("tools/list returns echo + approve", tool_list.size() == 2 and names.has("echo") and names.has("approve"))
	_check("tools have object schemas", tool_list.all(func(t): return t.get("inputSchema", {}).get("type", "") == "object"))

	# tools/call
	resp = _rpc(server, {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "echo", "arguments": {"text": "hello godot"}}})
	var content: Array = resp.get("result", {}).get("content", [])
	_check("tools/call echo round-trips", content.size() == 1 and content[0].get("text", "") == "hello godot")
	_check("tools/call not an error", resp.get("result", {}).get("isError", true) == false)

	# unknown method -> -32601
	resp = _rpc(server, {"jsonrpc": "2.0", "id": 4, "method": "nope/nope", "params": {}})
	_check("unknown method errors", resp.get("error", {}).get("code", 0) == -32601)

	# unknown tool -> isError result
	resp = _rpc(server, {"jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": {"name": "missing", "arguments": {}}})
	_check("unknown tool flagged isError", resp.get("result", {}).get("isError", false) == true)

	# async approve: the response must be parked until resolve_approval
	var peer := StreamPeerTCP.new()
	peer.connect_to_host("127.0.0.1", server.port)
	var abody := JSON.stringify({"jsonrpc": "2.0", "id": 9, "method": "tools/call",
		"params": {"name": "approve", "arguments": {"tool_name": "Bash", "input": {"command": "ls -la"}}}}).to_utf8_buffer()
	var ahead := "POST /mcp HTTP/1.1\r\nHost: t\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n" % abody.size()
	var sent := false
	var response := PackedByteArray()
	for i in range(150):
		server.poll()
		peer.poll()
		if peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			if not sent:
				peer.put_data(ahead.to_utf8_buffer())
				peer.put_data(abody)
				sent = true
			elif peer.get_available_bytes() > 0:
				var r := peer.get_data(peer.get_available_bytes())
				if r[0] == OK:
					response.append_array(r[1])
		OS.delay_msec(2)
	_check("approve parks the request (no early response)", response.is_empty() and tools.pending_approvals.size() == 1)
	var ticket := String(tools.pending_approvals.keys()[0]) if tools.pending_approvals.size() > 0 else ""
	tools.resolve_approval(ticket, true)
	for i in range(500):
		server.poll()
		peer.poll()
		var st := peer.get_status()
		if st == StreamPeerTCP.STATUS_CONNECTED and peer.get_available_bytes() > 0:
			var r := peer.get_data(peer.get_available_bytes())
			if r[0] == OK:
				response.append_array(r[1])
		if st == StreamPeerTCP.STATUS_NONE or st == StreamPeerTCP.STATUS_ERROR:
			break
		OS.delay_msec(2)
	var araw := response.get_string_from_utf8()
	var body_at := araw.find("\r\n\r\n")
	var envelope = JSON.parse_string(araw.substr(body_at + 4)) if body_at >= 0 else null
	var inner = null
	if envelope is Dictionary:
		inner = JSON.parse_string(String(envelope.get("result", {}).get("content", [{}])[0].get("text", "")))
	_check("approve resolves to allow with original input",
		inner is Dictionary and inner.get("behavior", "") == "allow" and inner.get("updatedInput", {}).get("command", "") == "ls -la")
	peer.disconnect_from_host()

	server.stop()
	if _failures == 0:
		print("PASS: test_mcp_server (10 checks)")
	quit(_failures)


func _check(what: String, ok: bool) -> void:
	if ok:
		print("  ok - " + what)
	else:
		_failures += 1
		printerr("  FAIL - " + what)


func _rpc(server, msg: Dictionary) -> Dictionary:
	var raw := _http(server, JSON.stringify(msg))
	var idx := raw.find("\r\n\r\n")
	if idx < 0:
		_failures += 1
		printerr("  FAIL - no HTTP response for " + String(msg.get("method", "?")))
		return {}
	var body = JSON.parse_string(raw.substr(idx + 4))
	return body if body is Dictionary else {}


## One full HTTP request/response over loopback, polling server and client in
## lock-step. Returns the raw response text.
func _http(server, json_body: String) -> String:
	var peer := StreamPeerTCP.new()
	if peer.connect_to_host("127.0.0.1", server.port) != OK:
		return ""
	var body := json_body.to_utf8_buffer()
	var head := "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n" % body.size()
	var sent := false
	var response := PackedByteArray()
	for i in range(2000):
		server.poll()
		peer.poll()
		var st := peer.get_status()
		if st == StreamPeerTCP.STATUS_CONNECTED and not sent:
			peer.put_data(head.to_utf8_buffer())
			peer.put_data(body)
			sent = true
		if sent and st == StreamPeerTCP.STATUS_CONNECTED:
			var avail := peer.get_available_bytes()
			if avail > 0:
				var res := peer.get_data(avail)
				if res[0] == OK:
					response.append_array(res[1])
		if st == StreamPeerTCP.STATUS_NONE or st == StreamPeerTCP.STATUS_ERROR:
			break  # server closed the connection: response complete
		OS.delay_msec(2)
	peer.disconnect_from_host()
	return response.get_string_from_utf8()
