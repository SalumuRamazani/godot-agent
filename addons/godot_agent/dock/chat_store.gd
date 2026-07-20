@tool
extends RefCounted
## Chat persistence: one JSON file per conversation under the project's
## user:// editor-data dir. Written incrementally as messages arrive, so a
## reload (or crash) never loses a conversation. The stored session_id lets a
## restored chat continue the same agent session.

const DIR := "user://godot_agent_chats"
const MAX_LISTED := 30


static func _ensure_dir() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIR))


static func create(backend_id: String, model: String) -> Dictionary:
	var stamp := Time.get_datetime_string_from_system(true).replace(":", "-")
	return {
		"id": stamp + "_" + str(randi() % 10000),
		"title": "",
		"created": int(Time.get_unix_time_from_system()),
		"updated": int(Time.get_unix_time_from_system()),
		"backend": backend_id,
		"model": model,
		"session_id": "",
		"messages": [],
	}


static func save(chat: Dictionary) -> void:
	if chat.is_empty() or String(chat.get("id", "")) == "":
		return
	_ensure_dir()
	chat["updated"] = int(Time.get_unix_time_from_system())
	var f := FileAccess.open(DIR + "/" + String(chat["id"]) + ".json", FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(chat))


static func list_chats() -> Array:
	_ensure_dir()
	var out := []
	for fname in DirAccess.get_files_at(DIR):
		if not fname.ends_with(".json"):
			continue
		var d = JSON.parse_string(FileAccess.get_file_as_string(DIR + "/" + fname))
		if d is Dictionary and not d.get("messages", []).is_empty():
			out.append({
				"id": String(d.get("id", fname.trim_suffix(".json"))),
				"title": String(d.get("title", "")),
				"updated": int(d.get("updated", 0)),
			})
	out.sort_custom(func(a, b): return a["updated"] > b["updated"])
	return out.slice(0, MAX_LISTED)


static func load_chat(id: String) -> Dictionary:
	var d = JSON.parse_string(FileAccess.get_file_as_string(DIR + "/" + id + ".json"))
	return d if d is Dictionary else {}
