extends Node
## Autoload registered by the Godot Agent plugin. Inert in normal play and in
## exports — it only activates when the game was launched by the agent's
## run_project tool, which passes `-- --ga-frames=<dir>`. Then it saves a
## downscaled screenshot of the running game every second so the agent can see.

const MAX_WIDTH := 960

var _dir := ""


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--ga-frames="):
			_dir = arg.trim_prefix("--ga-frames=")
	if _dir == "":
		return
	DirAccess.make_dir_recursive_absolute(_dir)
	var t := Timer.new()
	t.wait_time = 1.0
	t.timeout.connect(_snap)
	add_child(t)
	t.start()


func _snap() -> void:
	var img := get_viewport().get_texture().get_image()
	if img == null or img.is_empty():
		return
	if img.get_width() > MAX_WIDTH:
		img.resize(MAX_WIDTH, int(img.get_height() * float(MAX_WIDTH) / img.get_width()))
	img.save_png(_dir.path_join("frame_latest.png"))
