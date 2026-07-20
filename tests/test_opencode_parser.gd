extends SceneTree
## Headless opencode-backend test: spawns tests/fake_opencode.sh through the
## real ProcRunner + OpencodeBackend pipeline and asserts the emitted signals.
## Run from the repo root:  godot --headless -s tests/test_opencode_parser.gd

const OpencodeBackend := preload("res://addons/godot_agent/backends/opencode.gd")

var _failures := 0


func _initialize() -> void:
	var backend := OpencodeBackend.new()
	backend.cli_override = ProjectSettings.globalize_path("res://tests/fake_opencode.sh")
	backend.project_dir = ProjectSettings.globalize_path("res://")
	backend.opencode_config_path = "/tmp/godot_agent_test_opencode.json"
	backend.mcp_url = "http://127.0.0.1:9999/mcp"
	backend.env_extra = {"FAKE_KEY": "abc"}

	var deltas: Array[String] = []
	var tool_calls: Array[String] = []
	var updates: Array = []
	var thinking: Array[String] = []
	var results: Array[Dictionary] = []
	var errors: Array[String] = []
	backend.stream_delta.connect(func(t): deltas.append(t))
	backend.thinking_delta.connect(func(t): thinking.append(t))
	backend.tool_activity.connect(func(_id, n, _d): tool_calls.append(n))
	backend.tool_update.connect(func(_id, n, d, b): updates.append([n, d, b]))
	backend.turn_done.connect(func(m): results.append(m))
	backend.error.connect(func(e): errors.append(e))

	backend.send("hi")
	var waited := 0
	while backend.busy and waited < 15000:
		backend.pump()
		OS.delay_msec(10)
		waited += 10
	backend.pump()

	_check("no backend errors: " + str(errors), errors.is_empty())
	_check("cumulative text deduplicated into deltas", "".join(deltas) == "Hello world.Done.")
	_check("reasoning streamed as thinking", "".join(thinking) == "let me check the scene")
	_check("tools announced once each", tool_calls == ["godot_editor_get_editor_state", "edit"])
	var edit_updates: Array = updates.filter(func(u): return u[0] == "edit")
	_check("edit update carries file name", edit_updates.size() == 1 and edit_updates[0][1] == "player.gd")
	_check("edit update carries mini-diff", edit_updates.size() == 1 and edit_updates[0][2].contains("- speed = 100") and edit_updates[0][2].contains("+ speed = 300"))
	_check("turn_done sums step costs", results.size() == 1 and absf(float(results[0].get("cost_usd", 0)) - 0.003) < 0.0001)
	_check("session id captured", backend.session_id == "ses_fake123")
	var gen = JSON.parse_string(FileAccess.get_file_as_string("/tmp/godot_agent_test_opencode.json"))
	_check("config file written with MCP url", gen is Dictionary and gen.get("mcp", {}).get("godot_editor", {}).get("url", "") == "http://127.0.0.1:9999/mcp")

	if _failures == 0:
		print("PASS: test_opencode_parser (9 checks)")
	quit(_failures)


func _check(what: String, ok: bool) -> void:
	if ok:
		print("  ok - " + what)
	else:
		_failures += 1
		printerr("  FAIL - " + what)
