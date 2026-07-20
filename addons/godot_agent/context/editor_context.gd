@tool
extends RefCounted
## Builds the live editor-context block that is prefixed to every user message,
## so the agent always sees the current scene, selection and recent run output.

const MAX_TREE_LINES := 40
const MAX_RUN_TAIL := 15


static func build(tools) -> String:
	var lines: Array[String] = []
	lines.append("=== GODOT EDITOR CONTEXT (auto-generated, current as of this message) ===")
	lines.append("Project: %s  (root: %s)" % [
		str(ProjectSettings.get_setting("application/config/name", "?")),
		ProjectSettings.globalize_path("res://"),
	])
	lines.append("Godot: " + str(Engine.get_version_info().get("string", "?")))
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		lines.append("Edited scene: (none open)")
	else:
		lines.append("Edited scene: " + (root.scene_file_path if root.scene_file_path != "" else "(unsaved)"))
		var tree: Array[String] = []
		_walk(root, 0, tree)
		lines.append_array(tree)
	var sel := EditorInterface.get_selection().get_selected_nodes()
	if not sel.is_empty():
		var names := sel.map(func(n: Node): return "%s (%s)" % [n.name, n.get_class()])
		lines.append("Selected: " + ", ".join(names))
	var script := EditorInterface.get_script_editor().get_current_script()
	if script != null:
		lines.append("Open script: " + script.resource_path)
	var open := EditorInterface.get_open_scenes()
	if open.size() > 1:
		lines.append("Open scenes: " + ", ".join(open))
	var main_scene := String(ProjectSettings.get_setting("application/run/main_scene", ""))
	lines.append("Main scene: " + (main_scene if main_scene != "" else "(not set — set one via set_project_setting before run_project)"))
	var autoloads: Array[String] = []
	var actions: Array[String] = []
	for p in ProjectSettings.get_property_list():
		var prop_name := String(p["name"])
		if prop_name.begins_with("autoload/"):
			autoloads.append(prop_name.trim_prefix("autoload/"))
		elif prop_name.begins_with("input/") and not prop_name.begins_with("input/ui_"):
			actions.append(prop_name.trim_prefix("input/"))
	if not autoloads.is_empty():
		lines.append("Autoloads: " + ", ".join(autoloads))
	lines.append("Input actions (custom): " + (", ".join(actions) if not actions.is_empty() else "(none — ui_* defaults only)"))
	var files := _project_files_summary()
	if files != "":
		lines.append("Project files: " + files)
	if tools != null and not tools.run_output.is_empty():
		lines.append("Last run output (tail):")
		var tail: Array = tools.run_output.slice(maxi(0, tools.run_output.size() - MAX_RUN_TAIL))
		for l in tail:
			lines.append("  " + str(l))
	lines.append("=== END CONTEXT ===")
	return "\n".join(lines)


static func _project_files_summary() -> String:
	var entries: Array[String] = []
	var dir := DirAccess.open("res://")
	if dir == null:
		return ""
	dir.list_dir_begin()
	var count := 0
	var fname := dir.get_next()
	while fname != "" and count < 30:
		if not fname.begins_with(".") and fname != "addons":
			entries.append(fname + "/" if dir.current_is_dir() else fname)
			count += 1
		fname = dir.get_next()
	dir.list_dir_end()
	entries.sort()
	return ", ".join(entries)


static func _walk(node: Node, depth: int, out: Array[String]) -> void:
	if out.size() >= MAX_TREE_LINES:
		return
	var line := "  " + "  ".repeat(depth) + String(node.name) + " (" + node.get_class() + ")"
	var s = node.get_script()
	if s != null and s is Resource and s.resource_path != "":
		line += " [" + s.resource_path.get_file() + "]"
	out.append(line)
	for c in node.get_children():
		_walk(c, depth + 1, out)
