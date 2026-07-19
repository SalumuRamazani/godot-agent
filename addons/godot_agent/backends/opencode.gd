@tool
extends "agent_backend.gd"
## opencode backend: each send() spawns `opencode run --format json` in the
## project root, streaming raw JSON events. Any provider/model opencode knows
## works (`opencode models`), including the free `opencode/*-free` ones.
## API keys are passed as environment variables (env_extra) or configured once
## globally via `opencode auth login`. The in-editor MCP server is injected via
## a generated OPENCODE_CONFIG file, so the agent gets the same editor tools as
## the Claude Code backend.

const ProcRunner := preload("../util/proc_runner.gd")
const CliFinder := preload("../util/cli_finder.gd")
const SystemPrompt := preload("../context/system_prompt.gd")

const VARIANTS := ["minimal", "low", "medium", "high", "max"]

var model := "opencode/deepseek-v4-flash-free"
var variant := ""            # provider-specific reasoning effort, see VARIANTS
var auto_approve := false    # --auto: auto-approve permissions (Full Auto)
var cli_override := ""
var project_dir := ""
var opencode_config_path := ""  # absolute; regenerated before every run
var mcp_url := ""               # set by the plugin: http://127.0.0.1:<port>/mcp
var env_extra := {}             # e.g. {"OPENROUTER_API_KEY": "sk-…"}
var extra_config := {}          # deep-merged into the generated opencode config
var session_id := ""

var _proc  # ProcRunner
var _stderr_tail: Array[String] = []
var _saw_finish := false
var _cost := 0.0
var _steps := 0
var _started_ms := 0
var _part_progress := {}    # text part id -> chars already emitted
var _announced_calls := {}  # tool callID -> true


func display_name() -> String:
	return "OpenRouter / opencode"


func availability() -> Dictionary:
	var path := CliFinder.find("opencode", cli_override)
	if path == "":
		return {"ok": false, "detail": "opencode CLI not found — curl -fsSL https://opencode.ai/install | bash, or set cli_override"}
	return {"ok": true, "detail": path}


func new_session() -> void:
	session_id = ""


func cancel() -> void:
	if _proc != null and _proc.running:
		_proc.kill()
	busy = false
	status.emit("stopped")


func pump() -> void:
	if _proc != null:
		_proc.pump()


func send(prompt: String) -> void:
	if busy:
		error.emit("still working on the previous message")
		return
	var avail := availability()
	if not avail["ok"]:
		error.emit(String(avail["detail"]))
		return
	_write_config()
	var args := PackedStringArray(["run", "--format", "json", "-m", model])
	if variant in VARIANTS:
		args.append_array(PackedStringArray(["--variant", variant]))
	if auto_approve:
		args.append("--auto")
	if session_id != "":
		args.append_array(PackedStringArray(["-s", session_id]))
	args.append(prompt)
	var env := {}
	if opencode_config_path != "":
		env["OPENCODE_CONFIG"] = opencode_config_path
	for k in env_extra:
		env[k] = env_extra[k]
	_stderr_tail.clear()
	_part_progress.clear()
	_announced_calls.clear()
	_saw_finish = false
	_cost = 0.0
	_steps = 0
	_started_ms = Time.get_ticks_msec()
	_proc = ProcRunner.new()
	_proc.line_out.connect(_handle_line)
	_proc.line_err.connect(_handle_stderr)
	_proc.finished.connect(_handle_finished)
	var err: int = _proc.start(String(avail["detail"]), args, project_dir, env, true)
	if err != OK:
		error.emit("failed to start opencode (%d)" % err)
		_proc = null
		return
	busy = true
	status.emit("thinking… (%s)" % model)


func _write_config() -> void:
	if opencode_config_path == "":
		return
	var cfg := {"$schema": "https://opencode.ai/config.json"}
	if mcp_url != "":
		cfg["mcp"] = {"godot_editor": {"type": "remote", "url": mcp_url, "enabled": true}}
	# Godot specialisation at the system level: every opencode session loads
	# the Godot instructions file, whatever model is selected.
	var instructions_path := opencode_config_path.get_base_dir() + "/godot_agent_instructions.md"
	var fi := FileAccess.open(instructions_path, FileAccess.WRITE)
	if fi != null:
		fi.store_string(SystemPrompt.build())
		cfg["instructions"] = [instructions_path]
	cfg = _deep_merge(cfg, extra_config)
	var f := FileAccess.open(opencode_config_path, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(cfg, "  "))


static func _deep_merge(base: Dictionary, extra: Dictionary) -> Dictionary:
	var out := base.duplicate(true)
	for k in extra:
		if out.has(k) and out[k] is Dictionary and extra[k] is Dictionary:
			out[k] = _deep_merge(out[k], extra[k])
		else:
			out[k] = extra[k]
	return out


func _handle_stderr(line: String) -> void:
	_stderr_tail.append(line)
	if _stderr_tail.size() > 20:
		_stderr_tail = _stderr_tail.slice(_stderr_tail.size() - 20)


func _handle_finished(code: int) -> void:
	busy = false
	if _saw_finish:
		turn_done.emit({
			"cost_usd": _cost,
			"duration_ms": Time.get_ticks_msec() - _started_ms,
			"num_turns": _steps,
			"is_error": code != 0,
			"subtype": "opencode",
			"result": "",
		})
	else:
		var detail := "\n".join(_stderr_tail).strip_edges()
		if detail == "":
			detail = "(no output — wrong model name, or missing API key? Open Keys… to add one, or pick a free opencode/* model)"
		error.emit("opencode exited (code %d): %s" % [code, detail.left(600)])
	_proc = null


func _handle_line(line: String) -> void:
	if line.strip_edges() == "":
		return
	var data = JSON.parse_string(line)
	if not (data is Dictionary):
		return
	var sid := String(data.get("sessionID", ""))
	if sid != "" and session_id == "":
		session_id = sid
		status.emit("session " + sid.right(8))
	var part = data.get("part", {})
	if not (part is Dictionary):
		part = {}
	match String(data.get("type", "")):
		"text":
			var id := String(part.get("id", ""))
			var full := String(part.get("text", ""))
			var prev := int(_part_progress.get(id, 0))
			if full.length() > prev:
				stream_delta.emit(full.substr(prev))
				_part_progress[id] = full.length()
		"tool", "tool_use":
			var call_id := String(part.get("callID", part.get("id", "")))
			var tool := String(part.get("tool", "?"))
			var state = part.get("state", {})
			if call_id != "" and not _announced_calls.has(call_id):
				_announced_calls[call_id] = true
				tool_activity.emit(tool, "")
			if state is Dictionary and String(state.get("status", "")) == "error":
				tool_activity.emit(tool, "error: " + String(state.get("error", "")).left(200))
		"step_finish":
			_saw_finish = true
			_steps += 1
			_cost += float(part.get("cost", 0.0))
		"error":
			tool_activity.emit("error", String(data.get("error", JSON.stringify(data))).left(300))
		_:
			pass  # tolerate unknown event types across opencode versions


## Blocking helper for the dock's model picker: returns ["provider/model", …].
## Reflects whatever API keys are configured (env_extra + `opencode auth`).
func list_models() -> Array[String]:
	var avail := availability()
	if not avail["ok"]:
		return []
	var cmd := ""
	for k in env_extra:
		cmd += String(k) + "=" + ProcRunner.shell_quote(str(env_extra[k])) + " "
	if opencode_config_path != "":
		_write_config()
		cmd += "OPENCODE_CONFIG=" + ProcRunner.shell_quote(opencode_config_path) + " "
	cmd += "exec " + ProcRunner.shell_quote(String(avail["detail"])) + " models"
	var out := []
	var code := OS.execute("/bin/sh", PackedStringArray(["-c", cmd]), out)
	var models: Array[String] = []
	if code == 0 and out.size() > 0:
		for l in String(out[0]).split("\n"):
			var m := l.strip_edges()
			if m != "" and m.contains("/") and not m.contains(" "):
				models.append(m)
	return models
