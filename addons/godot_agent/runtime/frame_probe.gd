extends Node
## Autoload registered by the Godot Agent plugin. Inert in normal play and in
## exports — it only activates when the game was launched by the agent's
## run_project tool, which passes `-- --ga-frames=<dir>`. Then it:
##  - saves a downscaled screenshot of the game every second (frame_latest.png)
##  - writes status.json (fps) alongside it
##  - polls input_cmd.json for simulated-input sequences (the play_input tool)
##    and executes them through Input.parse_input_event, so the agent can
##    actually PLAY the game: act -> watch -> fix.

var _max_width := 960
var _dir := ""
var _seq_done := 0
var _active_seq := 0
var _steps: Array = []
var _wait := 0.0
var _poll_accum := 0.0


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--ga-frames="):
			_dir = arg.trim_prefix("--ga-frames=")
		elif arg.begins_with("--ga-width="):
			_max_width = maxi(320, int(arg.trim_prefix("--ga-width=")))
	if _dir == "":
		set_process(false)
		return
	DirAccess.make_dir_recursive_absolute(_dir)
	var t := Timer.new()
	t.wait_time = 1.0
	t.timeout.connect(_snap)
	add_child(t)
	t.start()


func _process(delta: float) -> void:
	if _active_seq > 0:
		_wait -= delta
		while _wait <= 0.0:
			if _steps.is_empty():
				_finish_sequence()
				break
			_wait += _exec_step(_steps.pop_front())
	else:
		_poll_accum += delta
		if _poll_accum >= 0.25:
			_poll_accum = 0.0
			_poll_command()


func _poll_command() -> void:
	var path := _dir.path_join("input_cmd.json")
	if not FileAccess.file_exists(path):
		return
	var data = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (data is Dictionary):
		return
	var seq := int(data.get("seq", 0))
	if seq <= _seq_done or seq == _active_seq:
		return
	var steps = data.get("steps", [])
	if not (steps is Array) or steps.is_empty():
		_seq_done = seq
		return
	_active_seq = seq
	_steps = steps.duplicate()
	_wait = 0.0


## Executes one step and returns how long to wait afterwards (seconds).
func _exec_step(step) -> float:
	if not (step is Dictionary):
		return 0.0
	if step.has("wait_ms"):
		return maxf(0.0, float(step["wait_ms"]) / 1000.0)
	if step.has("action"):
		var action := String(step["action"])
		if not InputMap.has_action(action):
			return 0.0
		if step.has("hold_ms"):
			_send_action(action, true, float(step.get("strength", 1.0)))
			_steps.push_front({"action": action, "down": false})
			return maxf(0.016, float(step["hold_ms"]) / 1000.0)
		_send_action(action, bool(step.get("down", true)), float(step.get("strength", 1.0)))
		return 0.0
	if step.has("mouse_click"):
		var pos := _to_vec(step["mouse_click"])
		_send_mouse_motion(pos)
		_send_mouse_button(pos, true)
		_steps.push_front({"_mouse_up": step["mouse_click"]})
		return 0.06
	if step.has("_mouse_up"):
		_send_mouse_button(_to_vec(step["_mouse_up"]), false)
		return 0.0
	if step.has("mouse_move"):
		_send_mouse_motion(_to_vec(step["mouse_move"]))
		return 0.0
	return 0.0


func _to_vec(v) -> Vector2:
	if v is Array and v.size() >= 2:
		return Vector2(float(v[0]), float(v[1]))
	return Vector2.ZERO


func _send_action(action: String, pressed: bool, strength: float) -> void:
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = pressed
	ev.strength = clampf(strength, 0.0, 1.0)
	Input.parse_input_event(ev)


func _send_mouse_button(pos: Vector2, pressed: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.position = pos
	ev.global_position = pos
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = pressed
	Input.parse_input_event(ev)


func _send_mouse_motion(pos: Vector2) -> void:
	var ev := InputEventMouseMotion.new()
	ev.position = pos
	ev.global_position = pos
	Input.parse_input_event(ev)


func _finish_sequence() -> void:
	_seq_done = _active_seq
	_active_seq = 0
	_steps.clear()
	_snap()
	var f := FileAccess.open(_dir.path_join("input_done.json"), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({"seq": _seq_done, "unix": int(Time.get_unix_time_from_system())}))


func _snap() -> void:
	var img := get_viewport().get_texture().get_image()
	if img == null or img.is_empty():
		return
	if img.get_width() > _max_width:
		img.resize(_max_width, int(img.get_height() * float(_max_width) / img.get_width()))
	img.save_png(_dir.path_join("frame_latest.png"))
	var f := FileAccess.open(_dir.path_join("status.json"), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({"fps": int(Performance.get_monitor(Performance.TIME_FPS)), "unix": int(Time.get_unix_time_from_system())}))
