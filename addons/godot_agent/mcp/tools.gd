@tool
extends RefCounted
## MCP tool registry: schemas + handlers. All handlers run on the main thread
## (the HTTP server is polled from _process), which the editor APIs require.
## With editor_enabled = false (headless tests) only a trivial `echo` tool is
## exposed so the protocol can be tested without an editor.

const ProcRunner := preload("../util/proc_runner.gd")

const MAX_TREE_NODES := 300
const MAX_RUN_LINES := 2000

signal approval_requested(ticket: String, tool_name: String, summary: String)

var editor_enabled := true
var run_proc  # ProcRunner while the game is running via run_project
var run_output: Array[String] = []
var server  # mcp/http_server.gd — needed to complete async (approval) responses
var pending_approvals := {}  # ticket -> {"tool": String, "input": Dictionary}
var _input_seq := 0


func pump() -> void:
	if run_proc != null:
		run_proc.pump()


func shutdown() -> void:
	if run_proc != null:
		run_proc.shutdown()
		run_proc = null
	server = null
	pending_approvals.clear()


## Called by the dock when the user clicks Allow or Deny.
func resolve_approval(ticket: String, allow: bool) -> void:
	var req = pending_approvals.get(ticket)
	if req == null or server == null:
		return
	pending_approvals.erase(ticket)
	var payload: Dictionary
	if allow:
		payload = {"behavior": "allow", "updatedInput": req["input"]}
	else:
		payload = {"behavior": "deny", "message": "The user denied this action in the Godot Agent dock."}
	server.complete_async(ticket, {"text": JSON.stringify(payload), "is_error": false})


# ---------------------------------------------------------------- tool list

func list_tools() -> Array:
	if not editor_enabled:
		return [_def("echo", "Echo back the given text (test tool).",
			{"text": {"type": "string"}}, ["text"]),
			_approve_def()]
	return [
		_approve_def(),
		_def("get_editor_state", "Snapshot of the editor: edited scene, open scenes, selected nodes, current script, whether the game is playing, project root and Godot version.", {}, []),
		_def("get_scene_tree", "Node tree of a scene as indented text: name (Type) [script]. Omit scene_path for the currently edited scene.",
			{"scene_path": {"type": "string", "description": "res:// path of a .tscn; omit for the edited scene"}}, []),
		_def("open_scene", "Open a scene file in the editor and make it the edited scene.",
			{"scene_path": {"type": "string"}}, ["scene_path"]),
		_def("create_scene", "Create a new .tscn with a single root node, save it and open it in the editor.",
			{"scene_path": {"type": "string", "description": "res:// path for the new .tscn"},
			 "root_type": {"type": "string", "description": "Node class for the root, e.g. Node2D, CharacterBody2D. Default Node2D"},
			 "root_name": {"type": "string", "description": "Root node name; defaults to file name in PascalCase"}}, ["scene_path"]),
		_def("save_all_scenes", "Save every open scene to disk.", {}, []),
		_def("add_node", "Add a node to the currently edited scene. parent_path is relative to the scene root ('' or '.' = root). Optionally set properties (Vector2/3/Color as arrays, resources as res:// path strings).",
			{"parent_path": {"type": "string"}, "type": {"type": "string"}, "node_name": {"type": "string"},
			 "properties": {"type": "object"},
			 "save": {"type": "boolean", "description": "Save the scene afterwards (default true)"}},
			["type", "node_name"]),
		_def("delete_node", "Remove a node (and its children) from the edited scene.",
			{"node_path": {"type": "string"}, "save": {"type": "boolean"}}, ["node_path"]),
		_def("move_node", "Reparent a node within the edited scene, optionally at a child index.",
			{"node_path": {"type": "string"}, "new_parent_path": {"type": "string"},
			 "index": {"type": "integer"}, "save": {"type": "boolean"}}, ["node_path", "new_parent_path"]),
		_def("rename_node", "Rename a node in the edited scene.",
			{"node_path": {"type": "string"}, "new_name": {"type": "string"}, "save": {"type": "boolean"}}, ["node_path", "new_name"]),
		_def("set_node_properties", "Set properties on a node in the edited scene. Values: numbers/strings/bools as-is, Vector2/3/Color as [x,y]/[x,y,z]/[r,g,b,a], 'Vector2(1,2)'-style strings, res:// paths load resources.",
			{"node_path": {"type": "string"}, "properties": {"type": "object"}, "save": {"type": "boolean"}}, ["node_path", "properties"]),
		_def("attach_script", "Attach an existing .gd script file to a node in the edited scene. Create the file with your file tools first, then refresh_filesystem, then attach.",
			{"node_path": {"type": "string"}, "script_path": {"type": "string", "description": "res:// path of the .gd file"}, "save": {"type": "boolean"}}, ["node_path", "script_path"]),
		_def("get_class_info", "Exact API of a Godot class in THIS engine build: methods with signatures, properties, signals, inheritance chain. Use before calling unfamiliar APIs.",
			{"class": {"type": "string"}}, ["class"]),
		_def("search_classes", "Search Godot class names (case-insensitive substring).",
			{"query": {"type": "string"}}, ["query"]),
		_def("run_project", "Run the project (or one scene) as a separate process, capturing stdout/stderr. Then use get_run_output; stop with stop_run.",
			{"scene": {"type": "string", "description": "Optional res:// scene to run instead of the main scene"}}, []),
		_def("get_run_output", "Output captured from the running (or last) run_project process.",
			{"tail": {"type": "integer", "description": "How many trailing lines (default 100)"}}, []),
		_def("stop_run", "Stop the process started by run_project.", {}, []),
		_def("play_in_editor", "Play the main scene (or a given scene) inside the editor, visible to the user. Output is NOT captured — prefer run_project for debugging.",
			{"scene": {"type": "string"}}, []),
		_def("stop_playing", "Stop the scene playing in the editor.", {}, []),
		_def("refresh_filesystem", "Rescan the project filesystem so files created/edited outside the editor appear. Call after using your file tools.", {}, []),
		_def("instance_scene", "Instantiate a saved .tscn as a child inside the currently edited scene (proper scene composition — prefer this over duplicating nodes).",
			{"scene_path": {"type": "string"}, "parent_path": {"type": "string", "description": "'' or '.' = scene root"},
			 "node_name": {"type": "string"}, "properties": {"type": "object"}, "save": {"type": "boolean"}}, ["scene_path"]),
		_def("connect_signal", "Create a persistent signal connection between two nodes in the edited scene (saved into the .tscn, like the editor's Node panel). The target method should exist in the target's script.",
			{"source_path": {"type": "string"}, "signal_name": {"type": "string"},
			 "target_path": {"type": "string"}, "method": {"type": "string"}, "save": {"type": "boolean"}},
			["source_path", "signal_name", "target_path", "method"]),
		_def("add_input_action", "Create/replace an input action in the project's Input Map with key and/or mouse bindings, e.g. action 'jump' with keys ['Space','W']. Saves project.godot.",
			{"action": {"type": "string"},
			 "keys": {"type": "array", "items": {"type": "string"}, "description": "Key names: 'Space', 'A', 'Left', 'Shift', 'Escape', …"},
			 "mouse_button": {"type": "integer", "description": "Optional: 1=left, 2=right, 3=middle"}}, ["action"]),
		_def("set_project_setting", "Set a project setting and save project.godot. E.g. 'application/run/main_scene' = 'res://main.tscn', 'display/window/size/viewport_width' = 1280.",
			{"setting": {"type": "string"}, "value": {"description": "New value (string/number/bool)"}}, ["setting", "value"]),
		_def("get_project_setting", "Read a project setting (e.g. 'application/run/main_scene').",
			{"setting": {"type": "string"}}, ["setting"]),
		_def("get_node_properties", "Current non-default property values of a node in the edited scene (what the Inspector shows changed).",
			{"node_path": {"type": "string"}}, ["node_path"]),
		_def("get_game_screenshot", "SEE the running game: returns the latest screenshot (refreshed every second) of the game started with run_project, plus its FPS. Wait ~2s after starting before the first call. Use it to verify visuals, layout and that things actually appear.", {}, []),
		_def("screenshot_editor", "SEE the editor viewport (the scene as the user sees it while editing). view: '2d' or '3d' (default 3d).",
			{"view": {"type": "string"}}, []),
		_def("play_input", "PLAY the running game by simulating input. steps is an array executed in order; each step is one of: {\"action\":\"jump\",\"hold_ms\":150} tap/hold an Input Map action; {\"action\":\"move_right\",\"down\":true} press without releasing (parallel holds — release later with down:false); {\"wait_ms\":500}; {\"mouse_click\":[x,y]}; {\"mouse_move\":[x,y]}. Actions must exist in the Input Map. Returns the estimated duration — wait that long, then get_game_screenshot and get_run_output to see what happened. Playtest every gameplay feature you build.",
			{"steps": {"type": "array", "items": {"type": "object"}}}, ["steps"]),
	]


func _approve_def() -> Dictionary:
	return _def("approve", "Internal permission gate used by the Claude Code harness in Safe mode. NEVER call this tool yourself.",
		{"tool_name": {"type": "string"}, "input": {"type": "object"}}, [])


func _def(tool_name: String, desc: String, props: Dictionary, required: Array) -> Dictionary:
	return {
		"name": tool_name,
		"description": desc,
		"inputSchema": {"type": "object", "properties": props, "required": required},
	}


# ---------------------------------------------------------------- dispatch

func call_tool(tool_name: String, args: Dictionary) -> Dictionary:
	if not editor_enabled and not (tool_name in ["echo", "approve"]):
		return _err("editor tools unavailable in headless mode")
	match tool_name:
		"echo":
			return _ok(String(args.get("text", "")))
		"approve":
			return _approve(args)
		"get_editor_state":
			return _get_editor_state()
		"get_scene_tree":
			return _get_scene_tree(args)
		"open_scene":
			return _open_scene(args)
		"create_scene":
			return _create_scene(args)
		"save_all_scenes":
			EditorInterface.save_all_scenes()
			return _ok("All open scenes saved.")
		"add_node":
			return _add_node(args)
		"delete_node":
			return _delete_node(args)
		"move_node":
			return _move_node(args)
		"rename_node":
			return _rename_node(args)
		"set_node_properties":
			return _set_node_properties(args)
		"attach_script":
			return _attach_script(args)
		"get_class_info":
			return _get_class_info(args)
		"search_classes":
			return _search_classes(args)
		"run_project":
			return _run_project(args)
		"get_run_output":
			return _get_run_output(args)
		"stop_run":
			return _stop_run()
		"play_in_editor":
			return _play_in_editor(args)
		"stop_playing":
			EditorInterface.stop_playing_scene()
			return _ok("Stopped playing.")
		"refresh_filesystem":
			EditorInterface.get_resource_filesystem().scan()
			return _ok("Filesystem rescan started.")
		"instance_scene":
			return _instance_scene(args)
		"connect_signal":
			return _connect_signal(args)
		"add_input_action":
			return _add_input_action(args)
		"set_project_setting":
			return _set_project_setting(args)
		"get_project_setting":
			var s := String(args.get("setting", ""))
			if not ProjectSettings.has_setting(s):
				return _ok("(setting not set: %s)" % s)
			return _ok(var_to_str(ProjectSettings.get_setting(s)))
		"get_node_properties":
			return _get_node_properties(args)
		"get_game_screenshot":
			return _get_game_screenshot()
		"screenshot_editor":
			return _screenshot_editor(args)
		"play_input":
			return _play_input(args)
		_:
			return _err("unknown tool: " + tool_name)


func _approve(args: Dictionary) -> Dictionary:
	var req_tool := String(args.get("tool_name", "?"))
	var input = args.get("input", {})
	if not (input is Dictionary):
		input = {}
	var ticket := "%d_%d" % [Time.get_ticks_usec(), randi() % 100000]
	pending_approvals[ticket] = {"tool": req_tool, "input": input}
	var summary := String(input.get("command", input.get("description", "")))
	if summary == "":
		summary = JSON.stringify(input).left(200)
	approval_requested.emit(ticket, req_tool, summary)
	return {"async_ticket": ticket}


func _ok(text: String) -> Dictionary:
	return {"text": text, "is_error": false}


func _err(text: String) -> Dictionary:
	return {"text": "ERROR: " + text, "is_error": true}


# ---------------------------------------------------------------- handlers

func _get_editor_state() -> Dictionary:
	var root := EditorInterface.get_edited_scene_root()
	var sel := EditorInterface.get_selection().get_selected_nodes()
	var script := EditorInterface.get_script_editor().get_current_script()
	var state := {
		"edited_scene": root.scene_file_path if root != null else "(none)",
		"edited_scene_root": ("%s (%s)" % [root.name, root.get_class()]) if root != null else "",
		"open_scenes": Array(EditorInterface.get_open_scenes()),
		"selected_nodes": sel.map(func(n: Node): return "%s (%s)" % [_path_in_scene(root, n), n.get_class()]),
		"current_script": script.resource_path if script != null else "(none)",
		"playing": EditorInterface.is_playing_scene(),
		"run_project_active": run_proc != null and run_proc.running,
		"project_root": ProjectSettings.globalize_path("res://"),
		"godot_version": Engine.get_version_info().get("string", "?"),
	}
	return _ok(JSON.stringify(state, "  "))


func _get_scene_tree(args: Dictionary) -> Dictionary:
	var scene_path := String(args.get("scene_path", ""))
	var root: Node = null
	var temp := false
	if scene_path == "":
		root = EditorInterface.get_edited_scene_root()
		if root == null:
			return _err("no scene is being edited; pass scene_path or open one")
	else:
		if not ResourceLoader.exists(scene_path):
			return _err("scene not found: " + scene_path)
		var ps: PackedScene = load(scene_path)
		if ps == null:
			return _err("could not load scene: " + scene_path)
		root = ps.instantiate()
		temp = true
	var lines: Array[String] = []
	var count := _walk_tree(root, root, 0, lines)
	if temp:
		root.free()
	var header := scene_path if scene_path != "" else String(root.scene_file_path) if root != null else ""
	var text := "\n".join(lines)
	if count >= MAX_TREE_NODES:
		text += "\n… (truncated at %d nodes)" % MAX_TREE_NODES
	return _ok(text)


func _walk_tree(scene_root: Node, node: Node, depth: int, lines: Array[String]) -> int:
	if lines.size() >= MAX_TREE_NODES:
		return lines.size()
	var line := "  ".repeat(depth) + String(node.name) + " (" + node.get_class() + ")"
	var s := node.get_script()
	if s != null and s is Resource and s.resource_path != "":
		line += " [script: " + s.resource_path + "]"
	if node != scene_root and node.scene_file_path != "":
		line += " [instance: " + node.scene_file_path + "]"
	lines.append(line)
	for child in node.get_children():
		_walk_tree(scene_root, child, depth + 1, lines)
	return lines.size()


func _open_scene(args: Dictionary) -> Dictionary:
	var path := String(args.get("scene_path", ""))
	if not ResourceLoader.exists(path):
		return _err("scene not found: " + path)
	EditorInterface.open_scene_from_path(path)
	return _ok("Opened " + path)


func _create_scene(args: Dictionary) -> Dictionary:
	var path := String(args.get("scene_path", ""))
	var root_type := String(args.get("root_type", "Node2D"))
	if path == "" or not path.begins_with("res://") or not path.ends_with(".tscn"):
		return _err("scene_path must be a res:// path ending in .tscn")
	if not ClassDB.class_exists(root_type) or not ClassDB.is_parent_class(root_type, "Node"):
		return _err("root_type is not a Node class: " + root_type)
	if not ClassDB.can_instantiate(root_type):
		return _err("cannot instantiate " + root_type)
	var node: Node = ClassDB.instantiate(root_type)
	var root_name := String(args.get("root_name", ""))
	node.name = root_name if root_name != "" else path.get_file().get_basename().to_pascal_case()
	var ps := PackedScene.new()
	var pack_err := ps.pack(node)
	if pack_err != OK:
		node.free()
		return _err("pack failed: %d" % pack_err)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var save_err := ResourceSaver.save(ps, path)
	node.free()
	if save_err != OK:
		return _err("save failed: %d" % save_err)
	EditorInterface.get_resource_filesystem().scan()
	EditorInterface.open_scene_from_path(path)
	return _ok("Created and opened %s (root: %s)" % [path, root_type])


func _edited_root() -> Node:
	return EditorInterface.get_edited_scene_root()


func _resolve(node_path: String) -> Node:
	var root := _edited_root()
	if root == null:
		return null
	var p := node_path.strip_edges()
	if p == "" or p == "." or p == "/" or p == String(root.name):
		return root
	if p.begins_with(String(root.name) + "/"):
		p = p.substr(String(root.name).length() + 1)
	if p.begins_with("root/"):
		p = p.substr(5)
	return root.get_node_or_null(p)


func _path_in_scene(root: Node, node: Node) -> String:
	if root == null or node == null:
		return ""
	if node == root:
		return "."
	return String(root.get_path_to(node))


func _maybe_save(args: Dictionary) -> String:
	if bool(args.get("save", true)):
		EditorInterface.save_scene()
		return " Scene saved."
	EditorInterface.mark_scene_as_unsaved()
	return " Scene NOT saved yet."


func _add_node(args: Dictionary) -> Dictionary:
	var root := _edited_root()
	if root == null:
		return _err("no scene is being edited; open or create one first")
	var parent := _resolve(String(args.get("parent_path", "")))
	if parent == null:
		return _err("parent not found: " + String(args.get("parent_path", "")))
	var type := String(args.get("type", ""))
	if not ClassDB.class_exists(type) or not ClassDB.is_parent_class(type, "Node"):
		var similar := _suggest_classes(type)
		return _err("unknown node type: %s%s" % [type, ("; did you mean: " + similar) if similar != "" else ""])
	if not ClassDB.can_instantiate(type):
		return _err("cannot instantiate " + type)
	var node: Node = ClassDB.instantiate(type)
	node.name = String(args.get("node_name", type))
	parent.add_child(node)
	node.owner = root
	var prop_report := ""
	var props = args.get("properties", {})
	if props is Dictionary and not props.is_empty():
		prop_report = " " + _apply_properties(node, props) + "."
	var saved := _maybe_save(args)
	return _ok("Added %s (%s) under %s.%s%s" % [node.name, type, _path_in_scene(root, parent), prop_report, saved])


func _delete_node(args: Dictionary) -> Dictionary:
	var root := _edited_root()
	var node := _resolve(String(args.get("node_path", "")))
	if node == null:
		return _err("node not found: " + String(args.get("node_path", "")))
	if node == root:
		return _err("refusing to delete the scene root")
	var desc := "%s (%s)" % [_path_in_scene(root, node), node.get_class()]
	node.get_parent().remove_child(node)
	node.free()
	var saved := _maybe_save(args)
	return _ok("Deleted %s.%s" % [desc, saved])


func _move_node(args: Dictionary) -> Dictionary:
	var root := _edited_root()
	var node := _resolve(String(args.get("node_path", "")))
	var new_parent := _resolve(String(args.get("new_parent_path", "")))
	if node == null:
		return _err("node not found: " + String(args.get("node_path", "")))
	if new_parent == null:
		return _err("new parent not found: " + String(args.get("new_parent_path", "")))
	if node == root:
		return _err("cannot move the scene root")
	node.reparent(new_parent, false)
	node.owner = root
	var index := int(args.get("index", -1))
	if index >= 0:
		new_parent.move_child(node, mini(index, new_parent.get_child_count() - 1))
	var saved := _maybe_save(args)
	return _ok("Moved %s under %s.%s" % [node.name, _path_in_scene(root, new_parent), saved])


func _rename_node(args: Dictionary) -> Dictionary:
	var node := _resolve(String(args.get("node_path", "")))
	if node == null:
		return _err("node not found: " + String(args.get("node_path", "")))
	var old := String(node.name)
	node.name = String(args.get("new_name", old))
	var saved := _maybe_save(args)
	return _ok("Renamed %s to %s.%s" % [old, node.name, saved])


func _set_node_properties(args: Dictionary) -> Dictionary:
	var node := _resolve(String(args.get("node_path", "")))
	if node == null:
		return _err("node not found: " + String(args.get("node_path", "")))
	var props = args.get("properties", {})
	if not (props is Dictionary) or props.is_empty():
		return _err("properties must be a non-empty object")
	var report := _apply_properties(node, props)
	var saved := _maybe_save(args)
	return _ok("%s on %s.%s" % [report, node.name, saved])


func _apply_properties(node: Node, props: Dictionary) -> String:
	var set_ok: Array[String] = []
	var failed: Array[String] = []
	var types := {}
	for p in node.get_property_list():
		types[p["name"]] = p["type"]
	for key in props:
		var prop := String(key)
		if not types.has(prop):
			failed.append(prop + " (no such property)")
			continue
		var value = _coerce(props[key], int(types[prop]))
		node.set(prop, value)
		set_ok.append(prop)
	var out := "Set: " + ", ".join(set_ok) if not set_ok.is_empty() else "Set nothing"
	if not failed.is_empty():
		out += "; FAILED: " + ", ".join(failed)
	return out


func _coerce(value, target_type: int):
	if value is Array:
		var nums: Array = value.filter(func(v): return v is float or v is int)
		if nums.size() == value.size():
			match target_type:
				TYPE_VECTOR2:
					if value.size() >= 2: return Vector2(value[0], value[1])
				TYPE_VECTOR2I:
					if value.size() >= 2: return Vector2i(int(value[0]), int(value[1]))
				TYPE_VECTOR3:
					if value.size() >= 3: return Vector3(value[0], value[1], value[2])
				TYPE_VECTOR3I:
					if value.size() >= 3: return Vector3i(int(value[0]), int(value[1]), int(value[2]))
				TYPE_COLOR:
					if value.size() == 3: return Color(value[0], value[1], value[2])
					if value.size() >= 4: return Color(value[0], value[1], value[2], value[3])
				TYPE_RECT2:
					if value.size() >= 4: return Rect2(value[0], value[1], value[2], value[3])
	if value is String:
		match target_type:
			TYPE_NODE_PATH:
				return NodePath(value)
			TYPE_COLOR:
				return Color.from_string(value, Color.WHITE)
			TYPE_OBJECT:
				if value.begins_with("res://") and ResourceLoader.exists(value):
					return load(value)
			TYPE_VECTOR2, TYPE_VECTOR3, TYPE_VECTOR4, TYPE_TRANSFORM2D, TYPE_TRANSFORM3D, TYPE_QUATERNION, TYPE_BASIS:
				var parsed = str_to_var(value)
				if parsed != null:
					return parsed
	return value


func _attach_script(args: Dictionary) -> Dictionary:
	var node := _resolve(String(args.get("node_path", "")))
	if node == null:
		return _err("node not found: " + String(args.get("node_path", "")))
	var path := String(args.get("script_path", ""))
	if not FileAccess.file_exists(ProjectSettings.globalize_path(path)):
		return _err("script file does not exist: " + path + " — create it with your file tools first")
	if not ResourceLoader.exists(path):
		EditorInterface.get_resource_filesystem().scan()
	var script = load(path)
	if script == null:
		return _err("could not load script (after a filesystem scan, retry attach_script): " + path)
	node.set_script(script)
	var saved := _maybe_save(args)
	return _ok("Attached %s to %s.%s" % [path, node.name, saved])


func _suggest_classes(query: String) -> String:
	if query.length() < 3:
		return ""
	var hits: Array[String] = []
	for cls in ClassDB.get_class_list():
		if String(cls).findn(query) >= 0:
			hits.append(String(cls))
			if hits.size() >= 5:
				break
	return ", ".join(hits)


func _get_class_info(args: Dictionary) -> Dictionary:
	var cls := String(args.get("class", ""))
	if not ClassDB.class_exists(cls):
		var sug := _suggest_classes(cls)
		return _err("class not found: %s%s" % [cls, ("; similar: " + sug) if sug != "" else ""])
	var lines: Array[String] = []
	var chain: Array[String] = []
	var cur := cls
	while cur != "":
		chain.append(cur)
		cur = ClassDB.get_parent_class(cur)
	lines.append("class %s  (inherits: %s)" % [cls, " > ".join(chain.slice(1))])
	lines.append("")
	lines.append("Methods (own):")
	for m in ClassDB.class_get_method_list(cls, true):
		lines.append("  " + _format_method(m))
	lines.append("")
	lines.append("Properties (own):")
	for p in ClassDB.class_get_property_list(cls, true):
		if int(p["usage"]) & PROPERTY_USAGE_EDITOR or int(p["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE:
			lines.append("  %s: %s" % [p["name"], _type_name(int(p["type"]), String(p.get("class_name", "")))])
	lines.append("")
	lines.append("Signals (own):")
	for s in ClassDB.class_get_signal_list(cls, true):
		var sargs := []
		for a in s.get("args", []):
			sargs.append("%s: %s" % [a["name"], _type_name(int(a["type"]), String(a.get("class_name", "")))])
		lines.append("  %s(%s)" % [s["name"], ", ".join(sargs)])
	lines.append("")
	lines.append("For inherited members, call get_class_info on a parent class.")
	return _ok("\n".join(lines))


func _format_method(m: Dictionary) -> String:
	var params := []
	var m_args: Array = m.get("args", [])
	var defaults: Array = m.get("default_args", [])
	var first_default := m_args.size() - defaults.size()
	for i in range(m_args.size()):
		var a: Dictionary = m_args[i]
		var piece := "%s: %s" % [a["name"], _type_name(int(a["type"]), String(a.get("class_name", "")))]
		if i >= first_default:
			piece += " = " + str(defaults[i - first_default])
		params.append(piece)
	var ret: Dictionary = m.get("return", {})
	var ret_s := _type_name(int(ret.get("type", TYPE_NIL)), String(ret.get("class_name", "")))
	return "%s(%s) -> %s" % [m["name"], ", ".join(params), ret_s]


func _type_name(t: int, cls: String) -> String:
	if t == TYPE_OBJECT and cls != "":
		return cls
	if t == TYPE_NIL:
		return "void"
	return type_string(t)


func _search_classes(args: Dictionary) -> Dictionary:
	var q := String(args.get("query", ""))
	if q == "":
		return _err("query is required")
	var hits: Array[String] = []
	for cls in ClassDB.get_class_list():
		if String(cls).findn(q) >= 0:
			hits.append(String(cls))
			if hits.size() >= 60:
				break
	if hits.is_empty():
		return _ok("No classes match '%s'." % q)
	return _ok("\n".join(hits))


# ---------------------------------------------------------------- run tools

func _run_project(args: Dictionary) -> Dictionary:
	if run_proc != null and run_proc.running:
		return _err("a run is already active (pid %d); call stop_run first" % run_proc.pid)
	run_output.clear()
	run_proc = ProcRunner.new()
	run_proc.line_out.connect(func(l): _append_run_line(l))
	run_proc.line_err.connect(func(l): _append_run_line(l))
	run_proc.finished.connect(func(code): run_output.append("[process exited with code %d]" % code))
	var proj := ProjectSettings.globalize_path("res://")
	var run_args := PackedStringArray(["--path", proj])
	var scene := String(args.get("scene", ""))
	if scene != "":
		run_args.append(scene)
	for stale in ["frame_latest.png", "status.json", "input_cmd.json", "input_done.json"]:
		DirAccess.remove_absolute(_frames_dir().path_join(stale))
	run_args.append_array(PackedStringArray(["--", "--ga-frames=" + _frames_dir()]))
	var err: int = run_proc.start(OS.get_executable_path(), run_args)
	if err != OK:
		return _err("failed to start the game process (%d)" % err)
	return _ok("Project started (pid %d). Use get_run_output to read output, stop_run to stop. Give it a second or two to boot before reading." % run_proc.pid)


func _append_run_line(line: String) -> void:
	run_output.append(line)
	if run_output.size() > MAX_RUN_LINES:
		run_output = run_output.slice(run_output.size() - MAX_RUN_LINES)


func _get_run_output(args: Dictionary) -> Dictionary:
	var tail := int(args.get("tail", 100))
	var lines := run_output.slice(maxi(0, run_output.size() - tail))
	var still: bool = run_proc != null and run_proc.running
	var head := "[running: %s, %d total lines]\n" % [str(still), run_output.size()]
	return _ok(head + "\n".join(lines))


func _stop_run() -> Dictionary:
	if run_proc == null or not run_proc.running:
		return _ok("No run is active.")
	run_proc.kill()
	return _ok("Kill signal sent to pid %d." % run_proc.pid)


func _instance_scene(args: Dictionary) -> Dictionary:
	var root := _edited_root()
	if root == null:
		return _err("no scene is being edited; open or create one first")
	var scene_path := String(args.get("scene_path", ""))
	if not ResourceLoader.exists(scene_path):
		return _err("scene not found: " + scene_path)
	if root.scene_file_path == scene_path:
		return _err("cannot instance a scene into itself")
	var parent := _resolve(String(args.get("parent_path", "")))
	if parent == null:
		return _err("parent not found: " + String(args.get("parent_path", "")))
	var ps: PackedScene = load(scene_path)
	if ps == null:
		return _err("could not load: " + scene_path)
	var node := ps.instantiate()
	var node_name := String(args.get("node_name", ""))
	if node_name != "":
		node.name = node_name
	parent.add_child(node)
	node.owner = root
	var prop_report := ""
	var props = args.get("properties", {})
	if props is Dictionary and not props.is_empty():
		prop_report = " " + _apply_properties(node, props) + "."
	var saved := _maybe_save(args)
	return _ok("Instanced %s as %s under %s.%s%s" % [scene_path, node.name, _path_in_scene(root, parent), prop_report, saved])


func _connect_signal(args: Dictionary) -> Dictionary:
	var root := _edited_root()
	var src := _resolve(String(args.get("source_path", "")))
	var tgt := _resolve(String(args.get("target_path", "")))
	if src == null:
		return _err("source not found: " + String(args.get("source_path", "")))
	if tgt == null:
		return _err("target not found: " + String(args.get("target_path", "")))
	var sig := String(args.get("signal_name", ""))
	if not src.has_signal(sig):
		var sigs := src.get_signal_list().map(func(s): return s["name"])
		return _err("no signal '%s' on %s. Available: %s" % [sig, src.name, ", ".join(sigs.slice(0, 25))])
	var method := String(args.get("method", ""))
	var callable := Callable(tgt, method)
	if src.is_connected(sig, callable):
		return _ok("Already connected: %s.%s -> %s.%s" % [src.name, sig, tgt.name, method])
	var err := src.connect(sig, callable, CONNECT_PERSIST)
	if err != OK:
		return _err("connect failed (%d)" % err)
	var note := "" if tgt.get_script() != null and tgt.get_script().get_script_method_list().any(func(m): return m["name"] == method) \
		else " NOTE: method '%s' not found in the target's script yet — create it or the game will error." % method
	var saved := _maybe_save(args)
	return _ok("Connected %s.%s -> %s.%s (persistent).%s%s" % [src.name, sig, tgt.name, method, note, saved])


func _add_input_action(args: Dictionary) -> Dictionary:
	var action := String(args.get("action", "")).strip_edges()
	if action == "":
		return _err("action name is required")
	var events := []
	var bad: Array[String] = []
	for k in args.get("keys", []):
		var code := OS.find_keycode_from_string(String(k))
		if code == KEY_NONE:
			bad.append(String(k))
			continue
		var ev := InputEventKey.new()
		ev.physical_keycode = code
		events.append(ev)
	var mb := int(args.get("mouse_button", 0))
	if mb > 0:
		var mev := InputEventMouseButton.new()
		mev.button_index = mb
		events.append(mev)
	if events.is_empty():
		return _err("no valid bindings%s" % ((" (unknown keys: " + ", ".join(bad) + ")") if not bad.is_empty() else ""))
	ProjectSettings.set_setting("input/" + action, {"deadzone": 0.2, "events": events})
	var err := ProjectSettings.save()
	if err != OK:
		return _err("could not save project.godot (%d)" % err)
	var extra := ("" if bad.is_empty() else " Unknown keys skipped: " + ", ".join(bad) + ".")
	return _ok("Input action '%s' saved with %d binding(s).%s" % [action, events.size(), extra])


func _set_project_setting(args: Dictionary) -> Dictionary:
	var setting := String(args.get("setting", ""))
	if setting == "":
		return _err("setting is required")
	var value = args.get("value")
	if value is String:
		var parsed = str_to_var(value)
		if parsed != null and not (parsed is String) and not value.begins_with("res://") and not value.begins_with("uid://"):
			value = parsed
	ProjectSettings.set_setting(setting, value)
	var err := ProjectSettings.save()
	if err != OK:
		return _err("could not save project.godot (%d)" % err)
	return _ok("%s = %s (saved)" % [setting, var_to_str(value)])


func _get_node_properties(args: Dictionary) -> Dictionary:
	var node := _resolve(String(args.get("node_path", "")))
	if node == null:
		return _err("node not found: " + String(args.get("node_path", "")))
	var lines: Array[String] = []
	lines.append("%s (%s)" % [node.name, node.get_class()])
	for p in node.get_property_list():
		if not (int(p["usage"]) & PROPERTY_USAGE_STORAGE):
			continue
		var prop := String(p["name"])
		if prop.begins_with("_") or prop in ["script", "owner", "scene_file_path"]:
			continue
		var value = node.get(prop)
		var default = ClassDB.class_get_property_default_value(node.get_class(), prop)
		if str(value) == str(default):
			continue
		lines.append("  %s = %s" % [prop, var_to_str(value).left(120)])
		if lines.size() >= 60:
			lines.append("  … (truncated)")
			break
	if node.get_script() != null:
		lines.append("  script = " + str(node.get_script().resource_path))
	return _ok("\n".join(lines))


func _frames_dir() -> String:
	return ProjectSettings.globalize_path("user://godot_agent_frames")


func _get_game_screenshot() -> Dictionary:
	var path := _frames_dir().path_join("frame_latest.png")
	if not FileAccess.file_exists(path):
		if run_proc == null or not run_proc.running:
			return _err("no game running — start it with run_project first, wait ~2s, then call again")
		return _err("no frame captured yet — wait a second and call again")
	var age := int(Time.get_unix_time_from_system()) - int(FileAccess.get_modified_time(path))
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		return _err("frame file unreadable")
	var note := "Screenshot of the running game (saved at %s)." % path
	if age > 5:
		note += " WARNING: frame is %ds old — the game may have stopped or crashed; check get_run_output." % age
	var status = JSON.parse_string(FileAccess.get_file_as_string(_frames_dir().path_join("status.json")))
	if status is Dictionary:
		note += " Game FPS: %d." % int(status.get("fps", 0))
	var done = JSON.parse_string(FileAccess.get_file_as_string(_frames_dir().path_join("input_done.json")))
	if done is Dictionary:
		note += " Input sequence #%d completed." % int(done.get("seq", 0))
	return {"text": note, "is_error": false, "image_b64": Marshalls.raw_to_base64(bytes)}


func _play_input(args: Dictionary) -> Dictionary:
	if run_proc == null or not run_proc.running:
		return _err("no game running — start it with run_project first")
	var steps = args.get("steps", [])
	if not (steps is Array) or steps.is_empty():
		return _err("steps must be a non-empty array")
	if steps.size() > 100:
		return _err("too many steps (max 100)")
	_input_seq += 1
	var f := FileAccess.open(_frames_dir().path_join("input_cmd.json"), FileAccess.WRITE)
	if f == null:
		return _err("could not write the input command file")
	f.store_string(JSON.stringify({"seq": _input_seq, "steps": steps}))
	f = null
	var est := 300
	for s in steps:
		if s is Dictionary:
			est += int(s.get("hold_ms", 0)) + int(s.get("wait_ms", 0)) + (80 if s.has("mouse_click") else 0)
	return _ok("Input sequence #%d dispatched (~%dms incl. pickup delay). Wait that long, then get_game_screenshot (it will confirm 'sequence #%d completed') and get_run_output." % [_input_seq, est, _input_seq])


func _screenshot_editor(args: Dictionary) -> Dictionary:
	var view := String(args.get("view", "3d"))
	var vp: Viewport = EditorInterface.get_editor_viewport_2d() if view == "2d" else EditorInterface.get_editor_viewport_3d(0)
	if vp == null:
		return _err("no %s editor viewport" % view)
	var img := vp.get_texture().get_image()
	if img == null or img.is_empty():
		return _err("could not capture the editor viewport (headless editor has no rendering)")
	if img.get_width() > 1152:
		img.resize(1152, int(img.get_height() * 1152.0 / img.get_width()))
	DirAccess.make_dir_recursive_absolute(_frames_dir())
	var path := _frames_dir().path_join("editor_%s.png" % view)
	img.save_png(path)
	return {"text": "Editor %s viewport screenshot (saved at %s)." % [view, path], "is_error": false,
		"image_b64": Marshalls.raw_to_base64(FileAccess.get_file_as_bytes(path))}


func _play_in_editor(args: Dictionary) -> Dictionary:
	var scene := String(args.get("scene", ""))
	if scene != "":
		EditorInterface.play_custom_scene(scene)
		return _ok("Playing %s in the editor." % scene)
	var main_scene := String(ProjectSettings.get_setting("application/run/main_scene", ""))
	if main_scene == "":
		return _err("no main scene set in project settings; pass a scene or set one")
	EditorInterface.play_main_scene()
	return _ok("Playing the main scene in the editor.")
