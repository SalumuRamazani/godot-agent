extends SceneTree
## Headless backend test: spawns tests/fake_claude.sh through the real
## ProcRunner + ClaudeCodeBackend pipeline (threads, pumping, stream-json
## parsing) and asserts the emitted signals. No tokens are spent.
## Run from the repo root:  godot --headless -s tests/test_stream_parser.gd

const ClaudeBackend := preload("res://addons/godot_agent/backends/claude_code.gd")

var _failures := 0


func _initialize() -> void:
	var backend := ClaudeBackend.new()
	backend.cli_override = ProjectSettings.globalize_path("res://tests/fake_claude.sh")
	backend.project_dir = ProjectSettings.globalize_path("res://")
	backend.mcp_config_path = ""  # not needed by the fake

	var deltas: Array[String] = []
	var completes: Array[String] = []
	var tool_calls: Array[String] = []
	var updates: Array = []
	var thinking: Array[String] = []
	var results: Array[Dictionary] = []
	var errors: Array[String] = []
	backend.stream_delta.connect(func(t): deltas.append(t))
	backend.thinking_delta.connect(func(t): thinking.append(t))
	backend.message_complete.connect(func(t): completes.append(t))
	backend.tool_activity.connect(func(_id, n, _d): tool_calls.append(n))
	backend.tool_update.connect(func(_id, n, d, b): updates.append([n, d, b]))
	backend.turn_done.connect(func(m): results.append(m))
	backend.error.connect(func(e): errors.append(e))

	backend.send("hi there")
	var waited := 0
	while backend.busy and waited < 15000:
		backend.pump()
		OS.delay_msec(10)
		waited += 10
	backend.pump()

	_check("no backend errors: " + str(errors), errors.is_empty())
	_check("text streamed in deltas", "".join(deltas) == "Hello world.")
	_check("thinking streamed", "".join(thinking) == "pondering the scene")
	_check("two complete messages", completes.size() == 2 and completes[1] == "Done! Added the node.")
	_check("tool announced exactly once", tool_calls == ["mcp__godot_editor__add_node"])
	_check("tool update carries detail", updates.size() == 1 and updates[0][1] == "Hero")
	_check("turn_done with cost", results.size() == 1 and absf(float(results[0].get("cost_usd", 0)) - 0.0042) < 0.00001)
	_check("session id adopted from CLI", backend.session_id == "fake-session-1234")
	_check("no longer first turn", backend.first_turn == false)

	if _failures == 0:
		print("PASS: test_stream_parser (9 checks)")
	quit(_failures)


func _check(what: String, ok: bool) -> void:
	if ok:
		print("  ok - " + what)
	else:
		_failures += 1
		printerr("  FAIL - " + what)
