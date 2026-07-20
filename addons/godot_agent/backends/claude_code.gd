@tool
extends "agent_backend.gd"
## Claude Code backend: each send() spawns `claude -p … --output-format
## stream-json` in the project root and parses the streamed events. Multi-turn
## continuity uses --session-id on the first turn and --resume afterwards.

const ProcRunner := preload("../util/proc_runner.gd")
const CliFinder := preload("../util/cli_finder.gd")
const SystemPrompt := preload("../context/system_prompt.gd")

var model := "sonnet"
var permission_mode := "acceptEdits"  # or "bypassPermissions" / "plan"
var profile := "economy"  # ask | quick | economy | power
var cli_override := ""
var project_dir := ""
var mcp_config_path := ""  # absolute path of the generated MCP config json
var session_id := ""
var first_turn := true

var _proc  # ProcRunner
var _stderr_tail: Array[String] = []
var _got_result := false
var _announced_tools := {}  # tool_use id -> true


func display_name() -> String:
	return "Claude Code"


func availability() -> Dictionary:
	var path := CliFinder.find("claude", cli_override)
	if path == "":
		return {"ok": false, "detail": "claude CLI not found — install Claude Code or set cli_override in user://godot_agent.cfg"}
	return {"ok": true, "detail": path}


func new_session() -> void:
	session_id = ""
	first_turn = true


func send(prompt: String) -> void:
	if busy:
		error.emit("still working on the previous message")
		return
	var avail := availability()
	if not avail["ok"]:
		error.emit(String(avail["detail"]))
		return
	if session_id == "":
		session_id = _uuid4()
		first_turn = true
	# Tier orchestration: model, permissions, turn caps and thinking budget.
	var eff_model := model
	var eff_permission := permission_mode
	match profile:
		"ask":
			eff_model = "haiku"
			eff_permission = "plan"
		"quick":
			eff_model = "haiku"
		"power":
			eff_model = "opus"
	var args := PackedStringArray([
		"-p", prompt,
		"--output-format", "stream-json",
		"--verbose",
		"--include-partial-messages",
		"--model", eff_model,
		"--permission-mode", eff_permission,
		"--append-system-prompt", SystemPrompt.build(profile),
	])
	if profile == "ask":
		args.append_array(PackedStringArray(["--max-turns", "4"]))
	elif profile == "quick":
		args.append_array(PackedStringArray(["--max-turns", "10"]))
	if mcp_config_path != "":
		args.append_array(PackedStringArray(["--mcp-config", mcp_config_path, "--strict-mcp-config"]))
		if profile == "ask":
			args.append_array(PackedStringArray(["--allowedTools", "mcp__godot_editor"]))
		else:
			# The user grants full machine + web access to build tiers.
			args.append_array(PackedStringArray(["--allowedTools", "mcp__godot_editor", "Bash", "WebSearch", "WebFetch"]))
		if eff_permission == "acceptEdits":
			# Safe mode: route remaining permission requests to the in-editor
			# Allow/Deny dialog instead of silently denying them.
			args.append_array(PackedStringArray(["--permission-prompt-tool", "mcp__godot_editor__approve"]))
	if first_turn:
		args.append_array(PackedStringArray(["--session-id", session_id]))
	else:
		args.append_array(PackedStringArray(["--resume", session_id]))
	_stderr_tail.clear()
	_announced_tools.clear()
	_got_result = false
	_proc = ProcRunner.new()
	_proc.line_out.connect(_handle_line)
	_proc.line_err.connect(_handle_stderr)
	_proc.finished.connect(_handle_finished)
	# Generous MCP tool timeout so an approval dialog can sit unanswered a while.
	var env := {"MCP_TOOL_TIMEOUT": "600000"}
	if profile == "power":
		env["MAX_THINKING_TOKENS"] = "16000"
	var err: int = _proc.start(String(avail["detail"]), args, project_dir, env)
	if err != OK:
		error.emit("failed to start claude (%d)" % err)
		_proc = null
		return
	busy = true
	status.emit("thinking…")


func cancel() -> void:
	if _proc != null and _proc.running:
		_proc.kill()
	busy = false
	status.emit("stopped")


func pump() -> void:
	if _proc != null:
		_proc.pump()


func _handle_stderr(line: String) -> void:
	_stderr_tail.append(line)
	if _stderr_tail.size() > 20:
		_stderr_tail = _stderr_tail.slice(_stderr_tail.size() - 20)


func _handle_finished(code: int) -> void:
	busy = false
	if not _got_result:
		var detail := "\n".join(_stderr_tail).strip_edges()
		if detail == "":
			detail = "(no stderr output)"
		error.emit("claude exited unexpectedly (code %d): %s" % [code, detail])
	_proc = null


func _handle_line(line: String) -> void:
	if line.strip_edges() == "":
		return
	var data = JSON.parse_string(line)
	if not (data is Dictionary):
		return
	match String(data.get("type", "")):
		"system":
			if String(data.get("subtype", "")) == "init":
				var sid := String(data.get("session_id", ""))
				if sid != "":
					session_id = sid
				status.emit("session %s · %s" % [session_id.substr(0, 8), String(data.get("model", model))])
		"stream_event":
			_handle_stream_event(data.get("event", {}))
		"assistant":
			_handle_assistant(data.get("message", {}))
		"user":
			_handle_tool_results(data.get("message", {}))
		"result":
			_got_result = true
			first_turn = false
			var usage = data.get("usage", {})
			if not (usage is Dictionary):
				usage = {}
			turn_done.emit({
				"cost_usd": float(data.get("total_cost_usd", 0.0)),
				"duration_ms": int(data.get("duration_ms", 0)),
				"num_turns": int(data.get("num_turns", 0)),
				"is_error": bool(data.get("is_error", false)),
				"subtype": String(data.get("subtype", "")),
				"result": String(data.get("result", "")),
				"tokens_in": int(usage.get("input_tokens", 0)) + int(usage.get("cache_read_input_tokens", 0)),
				"tokens_out": int(usage.get("output_tokens", 0)),
			})
		_:
			pass  # tolerate unknown event types across CLI versions


func _handle_stream_event(event) -> void:
	if not (event is Dictionary):
		return
	match String(event.get("type", "")):
		"content_block_delta":
			var delta = event.get("delta", {})
			if delta is Dictionary:
				match String(delta.get("type", "")):
					"text_delta":
						stream_delta.emit(String(delta.get("text", "")))
					"thinking_delta":
						thinking_delta.emit(String(delta.get("thinking", delta.get("text", ""))))
		"content_block_start":
			var block = event.get("content_block", {})
			if block is Dictionary and String(block.get("type", "")) == "tool_use":
				var id := String(block.get("id", ""))
				if id != "" and not _announced_tools.has(id):
					_announced_tools[id] = true
					tool_activity.emit(id, String(block.get("name", "?")), "")


func _handle_assistant(message) -> void:
	if not (message is Dictionary):
		return
	var texts: Array[String] = []
	for block in message.get("content", []):
		if not (block is Dictionary):
			continue
		match String(block.get("type", "")):
			"text":
				texts.append(String(block.get("text", "")))
			"tool_use":
				var id := String(block.get("id", ""))
				var tool := String(block.get("name", "?"))
				var input = block.get("input", {})
				if not (input is Dictionary):
					input = {}
				if not _announced_tools.has(id):
					_announced_tools[id] = true
					tool_activity.emit(id, tool, "")
				tool_update.emit(id, tool, describe_input(input), body_for(input))
	if not texts.is_empty():
		message_complete.emit("\n\n".join(texts))


func _handle_tool_results(message) -> void:
	if not (message is Dictionary):
		return
	for block in message.get("content", []):
		if block is Dictionary and String(block.get("type", "")) == "tool_result" and bool(block.get("is_error", false)):
			var content = block.get("content", "")
			var text := ""
			if content is String:
				text = content
			elif content is Array:
				for part in content:
					if part is Dictionary and part.get("type", "") == "text":
						text += String(part.get("text", ""))
			tool_update.emit(String(block.get("tool_use_id", "")), "", "⚠ " + text.left(160), "")


static func _uuid4() -> String:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var b := PackedByteArray()
	b.resize(16)
	for i in range(16):
		b[i] = rng.randi_range(0, 255)
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	var hex := b.hex_encode()
	return "%s-%s-%s-%s-%s" % [hex.substr(0, 8), hex.substr(8, 4), hex.substr(12, 4), hex.substr(16, 4), hex.substr(20, 12)]
