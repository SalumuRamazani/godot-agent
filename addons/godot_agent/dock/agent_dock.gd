@tool
extends VBoxContainer
## The chat dock. Entirely code-built (no .tscn) so diffs stay reviewable.
## Wire-up happens in setup(); the plugin adds this control to the right dock.

const EditorContextBuilder := preload("../context/editor_context.gd")

const MODELS := ["sonnet", "opus", "haiku"]
const MODES := [["Safe (accept edits)", "acceptEdits"], ["Full Auto (YOLO)", "bypassPermissions"]]
const SETTINGS_PATH := "user://godot_agent.cfg"

var tools
var backends := {}          # id -> backend instance
var backend_ids: Array = [] # display order
var mcp_port := 0

var _backend  # active backend
var _cfg := ConfigFile.new()

var _backend_sel: OptionButton
var _model_sel: OptionButton
var _mode_sel: OptionButton
var _new_btn: Button
var _scroll: ScrollContainer
var _messages: VBoxContainer
var _status: Label
var _input: TextEdit
var _send_btn: Button
var _stop_btn: Button

var _cur_label: RichTextLabel  # streaming assistant bubble
var _cur_raw := ""
var _busy := false
var _scroll_queued := false

var _re_bold: RegEx
var _re_inline_code: RegEx


func setup(p_backends: Dictionary, p_backend_ids: Array, p_tools, p_mcp_port: int) -> void:
	backends = p_backends
	backend_ids = p_backend_ids
	tools = p_tools
	mcp_port = p_mcp_port


func _ready() -> void:
	_re_bold = RegEx.new()
	_re_bold.compile("\\*\\*(.+?)\\*\\*")
	_re_inline_code = RegEx.new()
	_re_inline_code.compile("`([^`\\n]+)`")
	_cfg.load(SETTINGS_PATH)
	_build_ui()
	_apply_settings()
	_select_backend(_backend_sel.selected)
	_hello()


# ------------------------------------------------------------------ UI build

func _build_ui() -> void:
	custom_minimum_size = Vector2(300, 0)
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 6)

	var header := HFlowContainer.new()
	add_child(header)

	_backend_sel = OptionButton.new()
	for id in backend_ids:
		_backend_sel.add_item(backends[id].display_name())
	_backend_sel.item_selected.connect(_select_backend)
	header.add_child(_backend_sel)

	_model_sel = OptionButton.new()
	for m in MODELS:
		_model_sel.add_item(m)
	_model_sel.item_selected.connect(func(_i): _apply_backend_options(); _save_settings())
	header.add_child(_model_sel)

	_mode_sel = OptionButton.new()
	for m in MODES:
		_mode_sel.add_item(m[0])
	_mode_sel.item_selected.connect(func(_i): _apply_backend_options(); _save_settings())
	header.add_child(_mode_sel)

	_new_btn = Button.new()
	_new_btn.text = "New"
	_new_btn.tooltip_text = "Start a fresh conversation (clears the chat and the agent session)"
	_new_btn.pressed.connect(_on_new_chat)
	header.add_child(_new_btn)

	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(_scroll)

	_messages = VBoxContainer.new()
	_messages.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_messages.add_theme_constant_override("separation", 8)
	_scroll.add_child(_messages)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_font_size_override("font_size", 11)
	_status.modulate = Color(1, 1, 1, 0.55)
	add_child(_status)

	_input = TextEdit.new()
	_input.custom_minimum_size = Vector2(0, 64)
	_input.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_input.placeholder_text = "Ask the agent… (Enter to send, Shift+Enter for newline)"
	_input.gui_input.connect(_on_input_key)
	add_child(_input)

	var buttons := HBoxContainer.new()
	add_child(buttons)
	_send_btn = Button.new()
	_send_btn.text = "Send"
	_send_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_send_btn.pressed.connect(_on_send)
	buttons.add_child(_send_btn)
	_stop_btn = Button.new()
	_stop_btn.text = "Stop"
	_stop_btn.disabled = true
	_stop_btn.pressed.connect(_on_stop)
	buttons.add_child(_stop_btn)


func _apply_settings() -> void:
	var backend_idx := int(_cfg.get_value("ui", "backend", 0))
	_backend_sel.selected = clampi(backend_idx, 0, backend_ids.size() - 1)
	var model := String(_cfg.get_value("ui", "model", "sonnet"))
	_model_sel.selected = maxi(0, MODELS.find(model))
	var mode := String(_cfg.get_value("ui", "mode", "acceptEdits"))
	for i in range(MODES.size()):
		if MODES[i][1] == mode:
			_mode_sel.selected = i
	for id in backend_ids:
		if "cli_override" in backends[id]:
			backends[id].cli_override = String(_cfg.get_value("cli", id, ""))


func _save_settings() -> void:
	_cfg.set_value("ui", "backend", _backend_sel.selected)
	_cfg.set_value("ui", "model", MODELS[_model_sel.selected])
	_cfg.set_value("ui", "mode", MODES[_mode_sel.selected][1])
	_cfg.save(SETTINGS_PATH)


func _hello() -> void:
	var avail: Dictionary = _backend.availability()
	_add_meta("Godot Agent ready. MCP server on 127.0.0.1:%d. Try: \"Create a scene with a bouncing ball and run it.\"" % mcp_port)
	if not avail["ok"]:
		_add_error(String(avail["detail"]))


# ------------------------------------------------------------------ backend

func _select_backend(idx: int) -> void:
	if _backend != null:
		for sig in ["status", "stream_delta", "message_complete", "tool_activity", "turn_done", "error"]:
			var cb: Callable = Callable(self, "_on_backend_" + sig)
			if _backend.is_connected(sig, cb):
				_backend.disconnect(sig, cb)
	_backend = backends[backend_ids[idx]]
	_backend.status.connect(_on_backend_status)
	_backend.stream_delta.connect(_on_backend_stream_delta)
	_backend.message_complete.connect(_on_backend_message_complete)
	_backend.tool_activity.connect(_on_backend_tool_activity)
	_backend.turn_done.connect(_on_backend_turn_done)
	_backend.error.connect(_on_backend_error)
	if "http_host" in _backend:
		_backend.http_host = self
	var is_claude: bool = backend_ids[idx] == "claude_code"
	_model_sel.disabled = not is_claude
	_mode_sel.disabled = not is_claude
	_apply_backend_options()
	_refresh_status()
	_save_settings()


func _apply_backend_options() -> void:
	if "model" in _backend:
		_backend.model = MODELS[_model_sel.selected]
	if "permission_mode" in _backend:
		_backend.permission_mode = MODES[_mode_sel.selected][1]


func _refresh_status(extra := "") -> void:
	var avail: Dictionary = _backend.availability()
	var cli := String(avail["detail"]) if avail["ok"] else "NOT FOUND"
	var text := "MCP :%d · %s: %s" % [mcp_port, _backend.display_name(), cli.get_file() if avail["ok"] else cli]
	if extra != "":
		text += " · " + extra
	_status.text = text
	_status.tooltip_text = String(avail["detail"])


# ------------------------------------------------------------------ actions

func _on_input_key(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.shift_pressed \
			and (event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER):
		_input.accept_event()
		_on_send()


func _on_send() -> void:
	if _busy:
		return
	var text := _input.text.strip_edges()
	if text == "":
		return
	_input.text = ""
	_add_user_bubble(text)
	var prompt := EditorContextBuilder.build(tools) + "\n\nUser request:\n" + text
	_set_busy(true)
	_backend.send(prompt)
	_queue_scroll()


func _on_stop() -> void:
	_backend.cancel()
	_finalize_stream()
	_add_meta("stopped")
	_set_busy(false)


func _on_new_chat() -> void:
	if _busy:
		_backend.cancel()
		_set_busy(false)
	_backend.new_session()
	for c in _messages.get_children():
		c.queue_free()
	_cur_label = null
	_cur_raw = ""
	_hello()


func _set_busy(b: bool) -> void:
	_busy = b
	_send_btn.disabled = b
	_stop_btn.disabled = not b
	if not b:
		_refresh_status()


# ------------------------------------------------------------------ backend events

func _on_backend_status(text: String) -> void:
	_refresh_status(text)


func _on_backend_stream_delta(text: String) -> void:
	if _cur_label == null:
		_begin_assistant_bubble()
	_cur_raw += text
	_cur_label.text = _md_to_bbcode(_cur_raw)
	_queue_scroll()


func _on_backend_message_complete(full_text: String) -> void:
	if _cur_label == null:
		_begin_assistant_bubble()
	_cur_raw = full_text
	_cur_label.text = _md_to_bbcode(_cur_raw)
	_finalize_stream()
	_queue_scroll()


func _on_backend_tool_activity(tool_name: String, detail: String) -> void:
	_finalize_stream()
	var short_name := tool_name.replace("mcp__godot_editor__", "")
	var label := Label.new()
	label.text = "⚙ " + short_name + ("  " + detail if detail != "" else "")
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", 11)
	label.modulate = Color(1, 1, 1, 0.6)
	_messages.add_child(label)
	_queue_scroll()


func _on_backend_turn_done(meta: Dictionary) -> void:
	_finalize_stream()
	var bits: Array[String] = []
	if meta.get("is_error", false):
		_add_error("turn ended with an error (%s): %s" % [meta.get("subtype", "?"), String(meta.get("result", "")).left(300)])
	if float(meta.get("cost_usd", 0)) > 0:
		bits.append("$%.4f" % float(meta["cost_usd"]))
	if int(meta.get("num_turns", 0)) > 0:
		bits.append("%d steps" % int(meta["num_turns"]))
	if int(meta.get("duration_ms", 0)) > 0:
		bits.append("%.1fs" % (int(meta["duration_ms"]) / 1000.0))
	_add_meta("✓ done" + ("  ·  " + "  ·  ".join(bits) if not bits.is_empty() else ""))
	_set_busy(false)
	if tools != null and tools.editor_enabled:
		tools.call_tool("refresh_filesystem", {})
	_queue_scroll()


func _on_backend_error(message: String) -> void:
	_finalize_stream()
	_add_error(message)
	_set_busy(false)
	_queue_scroll()


# ------------------------------------------------------------------ bubbles

func _panel(bg: Color) -> PanelContainer:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = bg
	style.corner_radius_top_left = 6
	style.corner_radius_top_right = 6
	style.corner_radius_bottom_left = 6
	style.corner_radius_bottom_right = 6
	style.content_margin_left = 8
	style.content_margin_right = 8
	style.content_margin_top = 6
	style.content_margin_bottom = 6
	panel.add_theme_stylebox_override("panel", style)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_messages.add_child(panel)
	return panel


func _rich_label(bbcode: bool) -> RichTextLabel:
	var label := RichTextLabel.new()
	label.bbcode_enabled = bbcode
	label.fit_content = true
	label.scroll_active = false
	label.selection_enabled = true
	label.context_menu_enabled = true
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return label


func _accent() -> Color:
	if has_theme_color("accent_color", "Editor"):
		return get_theme_color("accent_color", "Editor")
	return Color(0.26, 0.5, 0.9)


func _add_user_bubble(text: String) -> void:
	var c := _accent()
	c.a = 0.18
	var label := _rich_label(false)
	label.text = text
	_panel(c).add_child(label)


func _begin_assistant_bubble() -> void:
	var label := _rich_label(true)
	_panel(Color(1, 1, 1, 0.05)).add_child(label)
	_cur_label = label
	_cur_raw = ""


func _finalize_stream() -> void:
	if _cur_label != null and _cur_raw.strip_edges() == "":
		var panel := _cur_label.get_parent()
		if panel != null:
			panel.queue_free()
	_cur_label = null
	_cur_raw = ""


func _add_error(text: String) -> void:
	var label := _rich_label(false)
	label.text = "⚠ " + text
	_panel(Color(0.8, 0.15, 0.15, 0.22)).add_child(label)
	_queue_scroll()


func _add_meta(text: String) -> void:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", 11)
	label.modulate = Color(1, 1, 1, 0.5)
	_messages.add_child(label)
	_queue_scroll()


func _queue_scroll() -> void:
	if _scroll_queued:
		return
	_scroll_queued = true
	call_deferred("_scroll_to_bottom")


func _scroll_to_bottom() -> void:
	_scroll_queued = false
	await get_tree().process_frame
	if is_instance_valid(_scroll):
		_scroll.scroll_vertical = int(_scroll.get_v_scroll_bar().max_value)


# ------------------------------------------------------------------ markdown

## Minimal, safe markdown→bbcode: escapes all incoming brackets, then applies
## fenced code blocks, inline code and bold. Anything else stays plain text.
func _md_to_bbcode(md: String) -> String:
	var out := ""
	var in_code := false
	for raw_line in md.split("\n"):
		var line: String = raw_line
		if line.strip_edges().begins_with("```"):
			out += "[code]" if not in_code else "[/code]"
			in_code = not in_code
			out += "\n"
			continue
		line = line.replace("[", "[lb]")
		if not in_code:
			line = _re_inline_code.sub(line, "[code]$1[/code]", true)
			line = _re_bold.sub(line, "[b]$1[/b]", true)
			if line.begins_with("# ") or line.begins_with("## ") or line.begins_with("### "):
				line = "[b]" + line.lstrip("# ") + "[/b]"
		out += line + "\n"
	if in_code:
		out += "[/code]"
	return out.rstrip("\n")
