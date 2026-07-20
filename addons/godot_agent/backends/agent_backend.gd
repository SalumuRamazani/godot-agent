@tool
extends RefCounted
## Abstract AI backend. Concrete backends (claude_code.gd, opencode.gd) emit
## these signals on the main thread from pump(), which the plugin calls every
## frame.

signal status(text: String)
signal thinking_delta(text: String)            # incremental reasoning stream
signal stream_delta(text: String)              # incremental assistant text
signal message_complete(full_text: String)     # authoritative text of one assistant message
signal tool_activity(call_id: String, tool_name: String, detail: String)   # a tool call started
signal tool_update(call_id: String, tool_name: String, detail: String, body: String)  # inputs/results known; body = expandable content (diff…)
signal turn_done(meta: Dictionary)             # {cost_usd, duration_ms, num_turns, is_error, subtype}
signal error(message: String)

var busy := false


func display_name() -> String:
	return "?"


## {ok: bool, detail: String} — detail is the CLI path or the failure reason.
func availability() -> Dictionary:
	return {"ok": false, "detail": "not implemented"}


func send(_prompt: String) -> void:
	push_error("AgentBackend.send not implemented")


func cancel() -> void:
	pass


func new_session() -> void:
	pass


func pump() -> void:
	pass


# ---------------------------------------------------------------- shared helpers

## Short human label for a tool call, extracted from its input.
static func describe_input(input: Dictionary) -> String:
	for k in ["file_path", "filePath", "path", "scene_path", "script_path",
			"node_name", "new_name", "node_path", "source_path", "action",
			"class", "query", "pattern", "setting", "command", "description"]:
		if input.has(k):
			var v := str(input[k])
			if k in ["file_path", "filePath", "path", "scene_path", "script_path"]:
				return v.get_file()
			return v.left(48)
	return ""


## Expandable body for a tool call: a mini-diff for edits, content for writes.
static func body_for(input: Dictionary) -> String:
	var old := str(input.get("old_string", input.get("oldString", "")))
	var new := str(input.get("new_string", input.get("newString", "")))
	if old != "" or new != "":
		return mini_diff(old, new)
	var edits = input.get("edits")
	if edits is Array and not edits.is_empty():
		var parts: Array[String] = []
		for e in edits:
			if e is Dictionary:
				parts.append(mini_diff(str(e.get("old_string", "")), str(e.get("new_string", ""))))
		return "\n⋯\n".join(parts).left(2400)
	if input.has("content"):
		var lines := str(input["content"]).split("\n")
		var out: Array[String] = []
		for l in lines.slice(0, 40):
			out.append("+ " + l)
		if lines.size() > 40:
			out.append("… (%d more lines)" % (lines.size() - 40))
		return "\n".join(out)
	return ""


static func mini_diff(old: String, new: String) -> String:
	var out: Array[String] = []
	if old != "":
		for l in old.split("\n"):
			out.append("- " + l)
	if new != "":
		for l in new.split("\n"):
			out.append("+ " + l)
	return "\n".join(out).left(2400)
