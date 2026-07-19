@tool
extends VBoxContainer
## The chat dock. Entirely code-built (no .tscn) so diffs stay reviewable.
## Wire-up happens in setup(); the plugin adds this control to the right dock.

const EditorContextBuilder := preload("../context/editor_context.gd")

const CLAUDE_MODELS := ["sonnet", "opus", "haiku"]
const SETTINGS_PATH := "user://godot_agent.cfg"

var tools
var backends := {}          # id -> backend instance
var backend_ids: Array = [] # display order
var mcp_port := 0

var _backend  # active backend
var _backend_id := "claude_code"
var _cfg := ConfigFile.new()

# header
var _backend_sel: OptionButton
var _mode_sel: OptionButton      # Plan / Build
var _perm_sel: OptionButton      # Safe / Auto
var _new_btn: Button
var _claude_model_sel: OptionButton
var _oc_row: HBoxContainer
var _model_btn: Button
var _variant_sel: OptionButton
var _keys_btn: Button
# model picker
var _model_dialog: AcceptDialog
var _model_filter: LineEdit
var _model_list: ItemList
var _all_models: Array[String] = []
# keys dialog
var _keys_dialog: AcceptDialog
var _keys_edit: TextEdit
var _extra_cfg_edit: TextEdit
# chat
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
var _last_tool := ""           # for coalescing repeated tool lines
var _last_tool_label: Label
var _last_tool_count := 0

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
	add_theme_constant_override("separation", 8)

	# Row A: backend · mode · permission · new
	var row_a := HBoxContainer.new()
	row_a.add_theme_constant_override("separation", 6)
	add_child(row_a)

	_backend_sel = OptionButton.new()
	_backend_sel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_backend_sel.fit_to_longest_item = false
	for id in backend_ids:
		_backend_sel.add_item(backends[id].display_name())
	_backend_sel.item_selected.connect(_select_backend)
	row_a.add_child(_backend_sel)

	_mode_sel = OptionButton.new()
	_mode_sel.add_item("Build")
	_mode_sel.add_item("Plan")
	_mode_sel.tooltip_text = "Build: the agent edits files, changes scenes and runs the game.\nPlan: read-only — it explores the project and proposes a plan, touching nothing."
	_mode_sel.item_selected.connect(func(_i): _apply_backend_options(); _save_settings())
	row_a.add_child(_mode_sel)

	_perm_sel = OptionButton.new()
	_perm_sel.add_item("Safe")
	_perm_sel.add_item("Auto")
	_perm_sel.tooltip_text = "Safe: file edits and editor tools only; arbitrary shell commands are blocked.\nAuto: full autonomy incl. shell commands — keep your project in git."
	_perm_sel.item_selected.connect(func(_i): _apply_backend_options(); _save_settings())
	row_a.add_child(_perm_sel)

	_new_btn = Button.new()
	_new_btn.text = "New"
	_new_btn.tooltip_text = "Start a fresh conversation"
	_new_btn.pressed.connect(_on_new_chat)
	row_a.add_child(_new_btn)

	# Row B (claude): model
	_claude_model_sel = OptionButton.new()
	for m in CLAUDE_MODELS:
		_claude_model_sel.add_item(m)
	_claude_model_sel.item_selected.connect(func(_i): _apply_backend_options(); _save_settings())
	add_child(_claude_model_sel)

	# Row B (openrouter/opencode): model button · variant · keys
	_oc_row = HBoxContainer.new()
	_oc_row.add_theme_constant_override("separation", 6)
	add_child(_oc_row)

	_model_btn = Button.new()
	_model_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_model_btn.clip_text = true
	_model_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_model_btn.tooltip_text = "Pick a model — searchable list of everything your keys unlock"
	_model_btn.pressed.connect(_open_model_picker)
	_oc_row.add_child(_model_btn)

	_variant_sel = OptionButton.new()
	_variant_sel.add_item("effort")
	for v in ["minimal", "low", "medium", "high", "max"]:
		_variant_sel.add_item(v)
	_variant_sel.tooltip_text = "Reasoning effort (provider-specific; leave on 'effort' for default)"
	_variant_sel.item_selected.connect(func(_i): _apply_backend_options(); _save_settings())
	_oc_row.add_child(_variant_sel)

	_keys_btn = Button.new()
	_keys_btn.text = "Keys"
	_keys_btn.tooltip_text = "API keys (OpenRouter etc.) and advanced config"
	_keys_btn.pressed.connect(func(): _keys_dialog.popup_centered(Vector2i(560, 500)))
	_oc_row.add_child(_keys_btn)

	_build_model_picker()
	_build_keys_dialog()

	# Chat area
	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(_scroll)

	_messages = VBoxContainer.new()
	_messages.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_messages.add_theme_constant_override("separation", 10)
	_scroll.add_child(_messages)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_font_size_override("font_size", 10)
	_status.modulate = Color(1, 1, 1, 0.45)
	add_child(_status)

	_input = TextEdit.new()
	_input.custom_minimum_size = Vector2(0, 60)
	_input.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_input.placeholder_text = "Ask the agent…  (Enter to send · Shift+Enter for newline)"
	_input.gui_input.connect(_on_input_key)
	add_child(_input)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 6)
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


func _build_model_picker() -> void:
	_model_dialog = AcceptDialog.new()
	_model_dialog.title = "Choose a model"
	_model_dialog.ok_button_text = "Use model"
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(420, 380)
	box.add_theme_constant_override("separation", 6)
	_model_filter = LineEdit.new()
	_model_filter.placeholder_text = "Search… (glm, kimi, deepseek, qwen, free)"
	_model_filter.text_changed.connect(func(_t): _refresh_model_list())
	box.add_child(_model_filter)
	_model_list = ItemList.new()
	_model_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_model_list.item_activated.connect(func(_i): _pick_model(); _model_dialog.hide())
	box.add_child(_model_list)
	var hint := Label.new()
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 10)
	hint.modulate = Color(1, 1, 1, 0.55)
	hint.text = "opencode/*-free models need no key. Add OPENROUTER_API_KEY under Keys to unlock GLM, Kimi and hundreds more."
	box.add_child(hint)
	_model_dialog.add_child(box)
	_model_dialog.confirmed.connect(_pick_model)
	add_child(_model_dialog)


func _open_model_picker() -> void:
	var oc = backends.get("opencode")
	_all_models.assign(oc.list_models() if oc != null else [])
	_model_filter.text = ""
	_refresh_model_list()
	_model_dialog.popup_centered(Vector2i(460, 460))
	_model_filter.grab_focus()


func _refresh_model_list() -> void:
	_model_list.clear()
	var q := _model_filter.text.strip_edges().to_lower()
	var openrouter: Array[String] = []
	var others: Array[String] = []
	for m in _all_models:
		if q != "" and m.to_lower().find(q) < 0:
			continue
		if m.begins_with("openrouter/"):
			openrouter.append(m)
		else:
			others.append(m)
	for m in openrouter + others:
		_model_list.add_item(m)
	if _model_list.item_count == 0:
		_model_list.add_item("(nothing matches — no key set yet? See Keys)")
		_model_list.set_item_disabled(0, true)
	elif _model_list.item_count > 0:
		_model_list.select(0)


func _pick_model() -> void:
	var sel := _model_list.get_selected_items()
	if sel.is_empty():
		return
	var m := _model_list.get_item_text(sel[0])
	if m.contains("/"):
		_model_btn.text = m
		_apply_backend_options()
		_save_settings()


func _build_keys_dialog() -> void:
	_keys_dialog = AcceptDialog.new()
	_keys_dialog.title = "API keys & advanced config"
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	var keys_label := Label.new()
	keys_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	keys_label.text = "API keys, one KEY=value per line.\nOPENROUTER_API_KEY unlocks GLM, Kimi, DeepSeek, Qwen and hundreds more with a single key (openrouter.ai/keys).\nAlso works: ZHIPUAI_API_KEY, MOONSHOT_API_KEY, OPENAI_API_KEY, DEEPSEEK_API_KEY, GOOGLE_GENERATIVE_AI_API_KEY, XAI_API_KEY…\nStored in plain text in user://godot_agent.cfg. Alternative: `opencode auth login` in a terminal."
	box.add_child(keys_label)
	_keys_edit = TextEdit.new()
	_keys_edit.custom_minimum_size = Vector2(0, 140)
	_keys_edit.placeholder_text = "OPENROUTER_API_KEY=sk-or-…"
	box.add_child(_keys_edit)
	var cfg_label := Label.new()
	cfg_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	cfg_label.text = "Extra opencode config (JSON, optional) — provider options like temperature, custom providers, agents."
	box.add_child(cfg_label)
	_extra_cfg_edit = TextEdit.new()
	_extra_cfg_edit.custom_minimum_size = Vector2(0, 110)
	_extra_cfg_edit.placeholder_text = "{\"provider\": {\"openrouter\": {\"options\": {\"temperature\": 0.6}}}}"
	box.add_child(_extra_cfg_edit)
	_keys_dialog.add_child(box)
	_keys_dialog.confirmed.connect(_on_keys_saved)
	add_child(_keys_dialog)


func _on_keys_saved() -> void:
	if _extra_cfg_edit.text.strip_edges() != "" and not (JSON.parse_string(_extra_cfg_edit.text) is Dictionary):
		_add_error("Extra config is not valid JSON — it will be ignored until fixed.")
	_save_settings()
	_apply_backend_options()
	_refresh_status("keys saved")


func _parse_keys(text: String) -> Dictionary:
	var env := {}
	for line in text.split("\n"):
		var l := line.strip_edges()
		if l == "" or l.begins_with("#"):
			continue
		var idx := l.find("=")
		if idx > 0:
			env[l.substr(0, idx).strip_edges()] = l.substr(idx + 1).strip_edges()
	return env


# ------------------------------------------------------------------ settings

func _apply_settings() -> void:
	var backend_idx := int(_cfg.get_value("ui", "backend", 0))
	_backend_sel.selected = clampi(backend_idx, 0, backend_ids.size() - 1)
	_claude_model_sel.selected = maxi(0, CLAUDE_MODELS.find(String(_cfg.get_value("ui", "model", "sonnet"))))
	_mode_sel.selected = 1 if String(_cfg.get_value("ui", "mode", "build")) == "plan" else 0
	_perm_sel.selected = 1 if String(_cfg.get_value("ui", "perm", "safe")) == "auto" else 0
	_model_btn.text = String(_cfg.get_value("opencode", "model", "opencode/deepseek-v4-flash-free"))
	var variant := String(_cfg.get_value("opencode", "variant", ""))
	for i in range(1, _variant_sel.item_count):
		if _variant_sel.get_item_text(i) == variant:
			_variant_sel.selected = i
	_keys_edit.text = String(_cfg.get_value("opencode", "keys", ""))
	_extra_cfg_edit.text = String(_cfg.get_value("opencode", "extra_config", ""))
	for id in backend_ids:
		if "cli_override" in backends[id]:
			backends[id].cli_override = String(_cfg.get_value("cli", id, ""))


func _save_settings() -> void:
	_cfg.set_value("ui", "backend", _backend_sel.selected)
	_cfg.set_value("ui", "model", CLAUDE_MODELS[_claude_model_sel.selected])
	_cfg.set_value("ui", "mode", "plan" if _mode_sel.selected == 1 else "build")
	_cfg.set_value("ui", "perm", "auto" if _perm_sel.selected == 1 else "safe")
	_cfg.set_value("opencode", "model", _model_btn.text.strip_edges())
	_cfg.set_value("opencode", "variant", "" if _variant_sel.selected <= 0 else _variant_sel.get_item_text(_variant_sel.selected))
	_cfg.set_value("opencode", "keys", _keys_edit.text)
	_cfg.set_value("opencode", "extra_config", _extra_cfg_edit.text)
	_cfg.save(SETTINGS_PATH)


func _hello() -> void:
	var avail: Dictionary = _backend.availability()
	_add_meta("Ready · MCP 127.0.0.1:%d · try \"Create a scene with a bouncing ball and run it\"" % mcp_port)
	if _backend_id == "opencode" and not _keys_edit.text.contains("OPENROUTER_API_KEY"):
		_add_meta("Free opencode/* models work with no key. For GLM/Kimi: Keys → OPENROUTER_API_KEY, then pick under the model button.")
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
	_backend_id = backend_ids[idx]
	var is_claude := _backend_id == "claude_code"
	_claude_model_sel.visible = is_claude
	_oc_row.visible = not is_claude
	_apply_backend_options()
	_refresh_status()
	_save_settings()


func _apply_backend_options() -> void:
	var plan := _mode_sel.selected == 1
	var auto := _perm_sel.selected == 1
	if _backend_id == "claude_code":
		_backend.model = CLAUDE_MODELS[_claude_model_sel.selected]
		if plan:
			_backend.permission_mode = "plan"
		else:
			_backend.permission_mode = "bypassPermissions" if auto else "acceptEdits"
	else:
		var m := _model_btn.text.strip_edges()
		if m != "":
			_backend.model = m
		_backend.variant = "" if _variant_sel.selected <= 0 else _variant_sel.get_item_text(_variant_sel.selected)
		_backend.agent = "plan" if plan else "build"
		_backend.auto_approve = auto and not plan
		_backend.env_extra = _parse_keys(_keys_edit.text)
		var extra = JSON.parse_string(_extra_cfg_edit.text) if _extra_cfg_edit.text.strip_edges() != "" else {}
		_backend.extra_config = extra if extra is Dictionary else {}


func _refresh_status(extra := "") -> void:
	var avail: Dictionary = _backend.availability()
	var mode := "Plan" if _mode_sel.selected == 1 else ("Build·Auto" if _perm_sel.selected == 1 else "Build")
	var text := "MCP :%d · %s · %s" % [mcp_port, mode, "ready" if avail["ok"] else "CLI missing"]
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
	_reset_tool_coalescing()
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
	_reset_tool_coalescing()
	if _cur_label == null:
		_begin_assistant_bubble()
	_cur_raw += text
	_cur_label.text = _md_to_bbcode(_cur_raw)
	_queue_scroll()


func _on_backend_message_complete(full_text: String) -> void:
	_reset_tool_coalescing()
	if _cur_label == null:
		_begin_assistant_bubble()
	_cur_raw = full_text
	_cur_label.text = _md_to_bbcode(_cur_raw)
	_finalize_stream()
	_queue_scroll()


func _on_backend_tool_activity(tool_name: String, detail: String) -> void:
	_finalize_stream()
	var short_name := tool_name.replace("mcp__godot_editor__", "").replace("godot_editor_", "")
	if detail == "" and short_name == _last_tool and _last_tool_label != null and is_instance_valid(_last_tool_label):
		_last_tool_count += 1
		_last_tool_label.text = "⚙ %s ×%d" % [short_name, _last_tool_count]
		return
	var label := Label.new()
	label.text = "⚙ " + short_name + ("   " + detail if detail != "" else "")
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", 11)
	label.modulate = Color(1, 1, 1, 0.55)
	_messages.add_child(label)
	_last_tool = short_name if detail == "" else ""
	_last_tool_label = label
	_last_tool_count = 1
	_queue_scroll()


func _reset_tool_coalescing() -> void:
	_last_tool = ""
	_last_tool_label = null
	_last_tool_count = 0


func _on_backend_turn_done(meta: Dictionary) -> void:
	_finalize_stream()
	_reset_tool_coalescing()
	if meta.get("is_error", false):
		_add_error("turn ended with an error (%s): %s" % [meta.get("subtype", "?"), String(meta.get("result", "")).left(300)])
	var bits: Array[String] = []
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
	_reset_tool_coalescing()
	_add_error(message)
	_set_busy(false)
	_queue_scroll()


# ------------------------------------------------------------------ bubbles

func _accent() -> Color:
	if has_theme_color("accent_color", "Editor"):
		return get_theme_color("accent_color", "Editor")
	return Color(0.26, 0.5, 0.9)


func _panel(bg: Color, border_accent := false) -> PanelContainer:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = bg
	style.set_corner_radius_all(8)
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	if border_accent:
		var a := _accent()
		a.a = 0.35
		style.border_color = a
		style.border_width_left = 2
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


func _add_user_bubble(text: String) -> void:
	var c := _accent()
	c.a = 0.16
	var label := _rich_label(false)
	label.text = text
	_panel(c).add_child(label)


func _begin_assistant_bubble() -> void:
	var label := _rich_label(true)
	_panel(Color(1, 1, 1, 0.04), true).add_child(label)
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
	_panel(Color(0.8, 0.15, 0.15, 0.2)).add_child(label)
	_queue_scroll()


func _add_meta(text: String) -> void:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", 10)
	label.modulate = Color(1, 1, 1, 0.45)
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
