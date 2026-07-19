@tool
extends "agent_backend.gd"
## EXPERIMENTAL opencode backend. Spawns `opencode serve` once (with
## OPENCODE_CONFIG pointing at a generated config that registers the in-editor
## MCP server), then drives it over its local REST API. Responses are not
## token-streamed: the full assistant message arrives when the turn completes.
## Untested against a live opencode install — treat as a starting point.

const ProcRunner := preload("../util/proc_runner.gd")
const CliFinder := preload("../util/cli_finder.gd")
const SystemPrompt := preload("../context/system_prompt.gd")

const SERVE_TIMEOUT_MS := 20000

var cli_override := ""
var project_dir := ""
var opencode_config_path := ""  # absolute path of generated config (OPENCODE_CONFIG)
var http_host: Node  # any in-tree node; used to parent HTTPRequest children

var _serve_proc  # ProcRunner
var _base_url := ""
var _session_ttl_id := ""
var _pending_prompt := ""
var _serve_started_at := 0
var _sent_system_prompt := false


func display_name() -> String:
	return "opencode (experimental)"


func availability() -> Dictionary:
	var path := CliFinder.find("opencode", cli_override)
	if path == "":
		return {"ok": false, "detail": "opencode CLI not found — install it from opencode.ai, or set cli_override"}
	return {"ok": true, "detail": path}


func new_session() -> void:
	_session_ttl_id = ""
	_sent_system_prompt = false


func cancel() -> void:
	busy = false
	_pending_prompt = ""
	status.emit("stopped (note: opencode may still finish server-side)")


func shutdown() -> void:
	if _serve_proc != null:
		_serve_proc.shutdown()
		_serve_proc = null


func pump() -> void:
	if _serve_proc != null:
		_serve_proc.pump()
	if _pending_prompt != "" and _base_url == "" and _serve_started_at > 0:
		if Time.get_ticks_msec() - _serve_started_at > SERVE_TIMEOUT_MS:
			busy = false
			_pending_prompt = ""
			_serve_started_at = 0
			error.emit("opencode serve did not report a listen address within 20s")


func send(prompt: String) -> void:
	if busy:
		error.emit("still working on the previous message")
		return
	if http_host == null or not is_instance_valid(http_host) or not http_host.is_inside_tree():
		error.emit("opencode backend has no host node for HTTP requests")
		return
	var avail := availability()
	if not avail["ok"]:
		error.emit(String(avail["detail"]))
		return
	busy = true
	if not _sent_system_prompt:
		prompt = SystemPrompt.build() + "\n\n" + prompt
		_sent_system_prompt = true
	if _base_url == "":
		_pending_prompt = prompt
		_start_serve(String(avail["detail"]))
	else:
		_continue_send(prompt)


func _start_serve(cli_path: String) -> void:
	if _serve_proc != null and _serve_proc.running:
		return
	status.emit("starting opencode serve…")
	_serve_proc = ProcRunner.new()
	_serve_proc.line_out.connect(_scan_for_url)
	_serve_proc.line_err.connect(_scan_for_url)
	_serve_proc.finished.connect(func(code):
		if _base_url == "":
			busy = false
			_pending_prompt = ""
			error.emit("opencode serve exited early (code %d)" % code)
		_base_url = "")
	var env := {}
	if opencode_config_path != "":
		env["OPENCODE_CONFIG"] = opencode_config_path
	_serve_started_at = Time.get_ticks_msec()
	var err: int = _serve_proc.start(cli_path, PackedStringArray(["serve", "--port", "0"]), project_dir, env)
	if err != OK:
		busy = false
		_pending_prompt = ""
		error.emit("failed to start opencode serve (%d)" % err)


func _scan_for_url(line: String) -> void:
	if _base_url != "":
		return
	var re := RegEx.new()
	re.compile("https?://(?:127\\.0\\.0\\.1|localhost|0\\.0\\.0\\.0):(\\d+)")
	var m := re.search(line)
	if m == null:
		return
	_base_url = "http://127.0.0.1:" + m.get_string(1)
	status.emit("opencode server on " + _base_url)
	if _pending_prompt != "":
		var p := _pending_prompt
		_pending_prompt = ""
		_continue_send(p)


func _continue_send(prompt: String) -> void:
	if _session_ttl_id == "":
		_request("POST", "/session", {}, func(code: int, body: Dictionary):
			if code >= 200 and code < 300 and body.has("id"):
				_session_ttl_id = String(body["id"])
				_post_message(prompt)
			else:
				busy = false
				error.emit("opencode: creating a session failed (HTTP %d): %s" % [code, JSON.stringify(body).left(200)]))
	else:
		_post_message(prompt)


func _post_message(prompt: String) -> void:
	status.emit("waiting for opencode… (no streaming in this experimental backend)")
	_request("POST", "/session/%s/message" % _session_ttl_id,
		{"parts": [{"type": "text", "text": prompt}]},
		func(code: int, body: Dictionary):
			busy = false
			if code < 200 or code >= 300:
				error.emit("opencode message failed (HTTP %d): %s" % [code, JSON.stringify(body).left(300)])
				return
			var text := ""
			for part in body.get("parts", []):
				if part is Dictionary and String(part.get("type", "")) == "text":
					text += String(part.get("text", ""))
			if text == "":
				text = "(opencode returned no text — raw: %s)" % JSON.stringify(body).left(300)
			message_complete.emit(text)
			turn_done.emit({"cost_usd": 0.0, "duration_ms": 0, "num_turns": 1, "is_error": false, "subtype": "opencode"}))


func _request(method: String, path: String, body: Dictionary, on_done: Callable) -> void:
	var req := HTTPRequest.new()
	req.timeout = 0
	http_host.add_child(req)
	req.request_completed.connect(func(result: int, code: int, _headers: PackedStringArray, resp_body: PackedByteArray):
		req.queue_free()
		if result != HTTPRequest.RESULT_SUCCESS:
			on_done.call(0, {"error": "request failed (result %d)" % result})
			return
		var parsed = JSON.parse_string(resp_body.get_string_from_utf8())
		on_done.call(code, parsed if parsed is Dictionary else {}))
	var http_method := HTTPClient.METHOD_POST if method == "POST" else HTTPClient.METHOD_GET
	var err := req.request(_base_url + path, PackedStringArray(["Content-Type: application/json"]), http_method, JSON.stringify(body))
	if err != OK:
		req.queue_free()
		on_done.call(0, {"error": "could not issue request (%d)" % err})
