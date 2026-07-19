@tool
extends RefCounted
## Abstract AI backend. Concrete backends (claude_code.gd, opencode.gd) emit
## these signals on the main thread from pump(), which the plugin calls every
## frame.

signal status(text: String)
signal stream_delta(text: String)              # incremental assistant text
signal message_complete(full_text: String)     # authoritative text of one assistant message
signal tool_activity(tool_name: String, detail: String)
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
