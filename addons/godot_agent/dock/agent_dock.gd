@tool
extends VBoxContainer
## The chat dock, entirely code-built. Visual language: quiet dark chrome from
## the editor theme, accent used only for the user's own messages and live
## state; agent output reads like a document, tools render as compact pills.

const EditorContextBuilder := preload("../context/editor_context.gd")
const ChatStore := preload("chat_store.gd")

const CLAUDE_MODELS := ["sonnet", "opus", "haiku"]
const SETTINGS_PATH := "user://godot_agent.cfg"
const STARTERS := [
	"Build a small playable demo game in this project, then run it and fix every error.",
	"Look at my current scene and add game feel: tweens, particles, screen shake.",
	"Run the game, read the output, and fix every error and warning you find.",
]

var tools
var backends := {}
var backend_ids: Array = []
var mcp_port := 0
var checkpoints  # util/checkpoints.gd, set by the plugin
var _turn_checkpoint := ""

var _backend
var _backend_id := "claude_code"
var _cfg := ConfigFile.new()

# header / config
var _status_dot: Label
var _backend_sel: OptionButton
var _mode_build: Button
var _mode_plan: Button
var _auto_check: CheckButton
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
var _working: Label
var _working_tween: Tween

var _cur_label: RichTextLabel
var _cur_raw := ""
var _busy := false
var _scroll_queued := false
var _tool_flow: HFlowContainer
var _pills := {}        # call_id -> pill entry dict
var _last_pill := {}    # most recent entry, for coalescing identical calls
var _think_header: Button
var _think_body: RichTextLabel
var _think_raw := ""
var _history_btn: MenuButton
var _history_ids: Array[String] = []
var _chat := {}            # current persisted conversation (chat_store.gd)
var _rec_by_call := {}     # call_id -> index into _chat.messages
var _restoring := false
var _last_final_text := ""

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
	_restore_latest()


# ------------------------------------------------------------------ theme bits

func _accent() -> Color:
	if has_theme_color("accent_color", "Editor"):
		return get_theme_color("accent_color", "Editor")
	return Color(0.33, 0.56, 0.93)


func _mono_font() -> Font:
	if has_theme_font("source", "EditorFonts"):
		return get_theme_font("source", "EditorFonts")
	return get_theme_default_font()


func _caption(text: String, font_size := 9) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", font_size)
	l.modulate = Color(1, 1, 1, 0.38)
	return l


# ------------------------------------------------------------------ UI build

func _build_ui() -> void:
	custom_minimum_size = Vector2(300, 0)
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 8)

	# ── identity row
	var title_row := HBoxContainer.new()
	title_row.add_theme_constant_override("separation", 6)
	add_child(title_row)
	var title := Label.new()
	title.text = "⬡ Godot Agent"
	title.add_theme_font_size_override("font_size", 14)
	var acc := _accent()
	title.add_theme_color_override("font_color", Color(acc.r, acc.g, acc.b).lerp(Color.WHITE, 0.55))
	title_row.add_child(title)
	_status_dot = Label.new()
	_status_dot.text = "●"
	_status_dot.add_theme_font_size_override("font_size", 11)
	title_row.add_child(_status_dot)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(spacer)
	_history_btn = MenuButton.new()
	_history_btn.text = "History"
	_history_btn.flat = true
	_history_btn.tooltip_text = "Reopen a previous conversation (it continues the same agent session)"
	_history_btn.about_to_popup.connect(_fill_history)
	_history_btn.get_popup().id_pressed.connect(_on_history_pick)
	title_row.add_child(_history_btn)
	_new_btn = Button.new()
	_new_btn.text = "＋ New"
	_new_btn.flat = true
	_new_btn.tooltip_text = "Start a fresh conversation"
	_new_btn.pressed.connect(_on_new_chat)
	title_row.add_child(_new_btn)

	# ── config row: backend · Build|Plan · Auto
	var cfg_row := HBoxContainer.new()
	cfg_row.add_theme_constant_override("separation", 6)
	add_child(cfg_row)
	_backend_sel = OptionButton.new()
	_backend_sel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_backend_sel.fit_to_longest_item = false
	for id in backend_ids:
		_backend_sel.add_item(backends[id].display_name())
	_backend_sel.item_selected.connect(_select_backend)
	cfg_row.add_child(_backend_sel)

	var seg := ButtonGroup.new()
	_mode_build = Button.new()
	_mode_build.text = "Build"
	_mode_build.toggle_mode = true
	_mode_build.button_group = seg
	_mode_build.button_pressed = true
	_mode_build.tooltip_text = "The agent edits files, changes scenes and runs the game."
	_mode_build.toggled.connect(func(on): if on: _mode_changed())
	cfg_row.add_child(_mode_build)
	_mode_plan = Button.new()
	_mode_plan.text = "Plan"
	_mode_plan.toggle_mode = true
	_mode_plan.button_group = seg
	_mode_plan.tooltip_text = "Read-only: explores the project and proposes a plan, touching nothing."
	_mode_plan.toggled.connect(func(on): if on: _mode_changed())
	cfg_row.add_child(_mode_plan)

	_auto_check = CheckButton.new()
	_auto_check.text = "Auto"
	_auto_check.tooltip_text = "Full autonomy incl. shell commands (Claude: bypassPermissions, opencode: --auto).\nOff = Safe: file edits and editor tools only. Keep your project in git."
	_auto_check.toggled.connect(func(_on): _apply_backend_options(); _save_settings(); _refresh_status())
	cfg_row.add_child(_auto_check)

	# ── model row (claude)
	_claude_model_sel = OptionButton.new()
	for m in CLAUDE_MODELS:
		_claude_model_sel.add_item(m)
	_claude_model_sel.item_selected.connect(func(_i): _apply_backend_options(); _save_settings())
	add_child(_claude_model_sel)

	# ── model row (openrouter)
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
	_variant_sel.tooltip_text = "Reasoning effort (provider-specific)"
	_variant_sel.item_selected.connect(func(_i): _apply_backend_options(); _save_settings())
	_oc_row.add_child(_variant_sel)
	_keys_btn = Button.new()
	_keys_btn.text = "Keys"
	_keys_btn.tooltip_text = "API keys (OpenRouter etc.) and advanced config"
	_keys_btn.pressed.connect(func(): _keys_dialog.popup_centered(Vector2i(560, 500)))
	_oc_row.add_child(_keys_btn)

	_build_model_picker()
	_build_keys_dialog()

	# ── chat
	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(_scroll)
	_messages = VBoxContainer.new()
	_messages.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_messages.add_theme_constant_override("separation", 6)
	_scroll.add_child(_messages)

	_working = Label.new()
	_working.text = "●  working…"
	_working.add_theme_font_size_override("font_size", 11)
	_working.add_theme_color_override("font_color", _accent())
	_working.visible = false
	add_child(_working)

	# ── input
	var input_panel := PanelContainer.new()
	var input_style := StyleBoxFlat.new()
	input_style.bg_color = Color(1, 1, 1, 0.03)
	input_style.set_corner_radius_all(10)
	input_style.content_margin_left = 8
	input_style.content_margin_right = 8
	input_style.content_margin_top = 8
	input_style.content_margin_bottom = 8
	input_panel.add_theme_stylebox_override("panel", input_style)
	add_child(input_panel)
	var input_box := VBoxContainer.new()
	input_box.add_theme_constant_override("separation", 6)
	input_panel.add_child(input_box)
	_input = TextEdit.new()
	_input.custom_minimum_size = Vector2(0, 56)
	_input.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_input.scroll_fit_content_height = true
	_input.placeholder_text = "What should we build?"
	_input.gui_input.connect(_on_input_key)
	var input_bg := StyleBoxEmpty.new()
	_input.add_theme_stylebox_override("normal", input_bg)
	_input.add_theme_stylebox_override("focus", input_bg)
	input_box.add_child(_input)
	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 6)
	input_box.add_child(btn_row)
	_status = Label.new()
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.add_theme_font_size_override("font_size", 10)
	_status.modulate = Color(1, 1, 1, 0.4)
	_status.clip_text = true
	btn_row.add_child(_status)
	_stop_btn = Button.new()
	_stop_btn.text = "Stop"
	_stop_btn.flat = true
	_stop_btn.disabled = true
	_stop_btn.pressed.connect(_on_stop)
	btn_row.add_child(_stop_btn)
	_send_btn = Button.new()
	_send_btn.text = "Send  ↵"
	_send_btn.pressed.connect(_on_send)
	btn_row.add_child(_send_btn)


func _build_model_picker() -> void:
	_model_dialog = AcceptDialog.new()
	_model_dialog.title = "Choose a model"
	_model_dialog.ok_button_text = "Use model"
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(460, 470)
	box.add_theme_constant_override("separation", 8)
	_model_filter = LineEdit.new()
	_model_filter.placeholder_text = "Search models…"
	_model_filter.clear_button_enabled = true
	_model_filter.text_changed.connect(func(_t): _refresh_model_list())
	box.add_child(_model_filter)
	var chips := HFlowContainer.new()
	chips.add_theme_constant_override("h_separation", 4)
	for chip in [["GLM", "glm"], ["Kimi", "kimi"], ["DeepSeek", "deepseek"], ["Qwen", "qwen"], ["Claude", "claude"], ["Gemini", "gemini"], ["Free", "free"]]:
		var b := Button.new()
		b.text = chip[0]
		b.flat = true
		b.add_theme_font_size_override("font_size", 11)
		var term: String = chip[1]
		b.pressed.connect(func():
			_model_filter.text = term
			_refresh_model_list())
		chips.add_child(b)
	box.add_child(chips)
	_model_list = ItemList.new()
	_model_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_model_list.item_activated.connect(func(_i): _pick_model(); _model_dialog.hide())
	box.add_child(_model_list)
	var hint := _caption("Free models need no key · add OPENROUTER_API_KEY under Keys for the full catalog", 10)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(hint)
	_model_dialog.add_child(box)
	_model_dialog.confirmed.connect(_pick_model)
	add_child(_model_dialog)


func _open_model_picker() -> void:
	var oc = backends.get("opencode")
	_all_models.assign(oc.list_models() if oc != null else [])
	_model_filter.text = ""
	_refresh_model_list()
	_model_dialog.popup_centered(Vector2i(500, 540))
	_model_filter.grab_focus()


## "openrouter/~z-ai/glm-4.7" -> {name: "glm-4.7", provider: "z-ai", source: "openrouter"}
func _pretty_model(id: String) -> Dictionary:
	var source := ""
	var rest := id
	if rest.begins_with("openrouter/"):
		source = "openrouter"
		rest = rest.trim_prefix("openrouter/")
	rest = rest.trim_prefix("~")
	var slash := rest.find("/")
	if slash < 0:
		return {"name": rest, "provider": source, "source": source}
	var provider := rest.substr(0, slash).trim_prefix("~")
	var model_name := rest.substr(slash + 1)
	if source == "":
		source = provider
	return {"name": model_name, "provider": provider, "source": source}


func _refresh_model_list() -> void:
	_model_list.clear()
	var q := _model_filter.text.strip_edges().to_lower()
	var free: Array = []
	var openrouter: Array = []
	var other: Array = []
	for id in _all_models:
		var pretty := _pretty_model(id)
		var hay := (id + " " + String(pretty["name"]) + " " + String(pretty["provider"])).to_lower()
		if q != "" and hay.find(q) < 0:
			continue
		var row := {"id": id, "name": pretty["name"], "provider": pretty["provider"]}
		if id.begins_with("opencode/"):
			row["provider"] = "free" if id.ends_with("-free") else "opencode"
			free.append(row)
		elif id.begins_with("openrouter/"):
			openrouter.append(row)
		else:
			other.append(row)
	var by_provider := func(a, b): return [a["provider"], a["name"]] < [b["provider"], b["name"]]
	openrouter.sort_custom(by_provider)
	other.sort_custom(by_provider)
	free.sort_custom(by_provider)
	_add_model_section("FREE — NO KEY NEEDED", free)
	_add_model_section("OPENROUTER", openrouter)
	_add_model_section("OTHER PROVIDERS", other)
	if _model_list.item_count == 0:
		_model_list.add_item("nothing matches — missing a key? See Keys")
		_model_list.set_item_disabled(0, true)
		return
	for i in range(_model_list.item_count):
		if _model_list.is_item_selectable(i):
			_model_list.select(i)
			break


func _add_model_section(title: String, rows: Array) -> void:
	if rows.is_empty():
		return
	var h := _model_list.add_item(title)
	_model_list.set_item_selectable(h, false)
	_model_list.set_item_disabled(h, true)
	_model_list.set_item_custom_fg_color(h, Color(1, 1, 1, 0.35))
	for row in rows:
		var idx := _model_list.add_item("%s      %s" % [row["name"], row["provider"]])
		_model_list.set_item_metadata(idx, row["id"])
		_model_list.set_item_tooltip(idx, row["id"])


func _pick_model() -> void:
	var sel := _model_list.get_selected_items()
	if sel.is_empty():
		return
	var meta = _model_list.get_item_metadata(sel[0])
	if meta is String and String(meta).contains("/"):
		_model_btn.text = String(meta)
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
	if String(_cfg.get_value("ui", "mode", "build")) == "plan":
		_mode_plan.button_pressed = true
	_auto_check.button_pressed = String(_cfg.get_value("ui", "perm", "safe")) == "auto"
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
	_cfg.set_value("ui", "mode", "plan" if _mode_plan.button_pressed else "build")
	_cfg.set_value("ui", "perm", "auto" if _auto_check.button_pressed else "safe")
	_cfg.set_value("opencode", "model", _model_btn.text.strip_edges())
	_cfg.set_value("opencode", "variant", "" if _variant_sel.selected <= 0 else _variant_sel.get_item_text(_variant_sel.selected))
	_cfg.set_value("opencode", "keys", _keys_edit.text)
	_cfg.set_value("opencode", "extra_config", _extra_cfg_edit.text)
	_cfg.save(SETTINGS_PATH)


func _mode_changed() -> void:
	_auto_check.disabled = _mode_plan.button_pressed
	_apply_backend_options()
	_save_settings()
	_refresh_status()


# ------------------------------------------------------------------ welcome

func _welcome() -> void:
	var card := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(1, 1, 1, 0.03)
	style.set_corner_radius_all(10)
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 10
	style.content_margin_bottom = 10
	card.add_theme_stylebox_override("panel", style)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	var head := Label.new()
	head.text = "What do you want to build?"
	head.add_theme_font_size_override("font_size", 13)
	box.add_child(head)
	for s in STARTERS:
		var b := Button.new()
		b.text = "▸ " + s
		b.flat = true
		b.clip_text = true
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.tooltip_text = s
		b.pressed.connect(func():
			_input.text = s
			_input.grab_focus())
		box.add_child(b)
	card.add_child(box)
	_messages.add_child(card)
	var avail: Dictionary = _backend.availability()
	if _backend_id == "opencode" and not _keys_edit.text.contains("OPENROUTER_API_KEY"):
		_add_meta("Free opencode/* models work with no key · Keys → OPENROUTER_API_KEY unlocks GLM, Kimi & more")
	if not avail["ok"]:
		_add_error(String(avail["detail"]))


# ------------------------------------------------------------------ history

func _record(entry: Dictionary) -> int:
	if _restoring:
		return -1
	if _chat.is_empty():
		var model: String = CLAUDE_MODELS[_claude_model_sel.selected] if _backend_id == "claude_code" else _model_btn.text
		_chat = ChatStore.create(_backend_id, model)
	if String(entry.get("role", "")) == "user" and String(_chat.get("title", "")) == "":
		_chat["title"] = String(entry.get("text", "")).left(48).replace("\n", " ")
	_chat["messages"].append(entry)
	ChatStore.save(_chat)
	return _chat["messages"].size() - 1


func _rel_date(ts: int) -> String:
	var diff := int(Time.get_unix_time_from_system()) - ts
	if diff < 90:
		return "just now"
	if diff < 3600:
		return "%dm ago" % (diff / 60)
	if diff < 86400:
		return "%dh ago" % (diff / 3600)
	return "%dd ago" % (diff / 86400)


func _fill_history() -> void:
	var popup := _history_btn.get_popup()
	popup.clear()
	_history_ids.clear()
	for c in ChatStore.list_chats():
		if String(c["id"]) == String(_chat.get("id", "")):
			continue
		var title := String(c["title"])
		if title == "":
			title = "(untitled)"
		popup.add_item("%s   ·  %s" % [title.left(38), _rel_date(int(c["updated"]))])
		_history_ids.append(String(c["id"]))
	if _history_ids.is_empty():
		popup.add_item("no previous conversations")
		popup.set_item_disabled(0, true)


func _on_history_pick(id: int) -> void:
	var idx := _history_btn.get_popup().get_item_index(id)
	if idx >= 0 and idx < _history_ids.size():
		_load_chat(_history_ids[idx])


func _restore_latest() -> void:
	var chats := ChatStore.list_chats()
	if chats.is_empty():
		_welcome()
		return
	_load_chat(String(chats[0]["id"]))


func _load_chat(id: String) -> void:
	var chat := ChatStore.load_chat(id)
	if chat.is_empty():
		_welcome()
		return
	if _busy:
		_backend.cancel()
		_set_busy(false)
	for c in _messages.get_children():
		c.queue_free()
	_cur_label = null
	_cur_raw = ""
	_last_final_text = ""
	_collapse_thinking()
	_reset_pills()
	_pills.clear()
	_rec_by_call.clear()
	_chat = chat
	# Switch UI to the chat's backend/model before rendering.
	var target := String(chat.get("backend", _backend_id))
	if backend_ids.has(target) and target != _backend_id:
		_backend_sel.selected = backend_ids.find(target)
		_select_backend(_backend_sel.selected)
	var model := String(chat.get("model", ""))
	if model != "":
		if _backend_id == "claude_code" and CLAUDE_MODELS.has(model):
			_claude_model_sel.selected = CLAUDE_MODELS.find(model)
		elif _backend_id != "claude_code" and model.contains("/"):
			_model_btn.text = model
		_apply_backend_options()
	_restoring = true
	var i := 0
	for m in chat.get("messages", []):
		if not (m is Dictionary):
			continue
		match String(m.get("role", "")):
			"user":
				_add_user_bubble(str(m.get("text", "")))
			"assistant":
				_begin_assistant_bubble()
				_cur_raw = str(m.get("text", ""))
				_cur_label.text = _md_to_bbcode(_cur_raw)
				_cur_label = null
				_cur_raw = ""
			"thinking":
				_begin_thinking_block()
				_think_raw = str(m.get("text", ""))
				_think_body.text = _think_raw
				_collapse_thinking()
			"tool":
				var hid := "hist_%d" % i
				_on_backend_tool_activity(hid, str(m.get("name", "tool")), "")
				if str(m.get("detail", "")) != "" or str(m.get("body", "")) != "":
					_on_backend_tool_update(hid, str(m.get("name", "tool")), str(m.get("detail", "")), str(m.get("body", "")))
			"meta":
				_add_meta(str(m.get("text", "")))
			"error":
				_add_error(str(m.get("text", "")))
		i += 1
	_restoring = false
	_reset_pills()
	_pills.clear()
	var sid := String(chat.get("session_id", ""))
	if sid != "":
		_backend.session_id = sid
		if "first_turn" in _backend:
			_backend.first_turn = false
	_add_meta("↺ restored (%s)%s" % [_rel_date(int(chat.get("updated", 0))), " · same agent session continues" if sid != "" else ""])
	_queue_scroll()


# ------------------------------------------------------------------ backend

func _select_backend(idx: int) -> void:
	if _backend != null:
		for sig in ["status", "thinking_delta", "stream_delta", "message_complete", "tool_activity", "tool_update", "turn_done", "error"]:
			var cb: Callable = Callable(self, "_on_backend_" + sig)
			if _backend.is_connected(sig, cb):
				_backend.disconnect(sig, cb)
	_backend = backends[backend_ids[idx]]
	_backend.status.connect(_on_backend_status)
	_backend.thinking_delta.connect(_on_backend_thinking_delta)
	_backend.stream_delta.connect(_on_backend_stream_delta)
	_backend.message_complete.connect(_on_backend_message_complete)
	_backend.tool_activity.connect(_on_backend_tool_activity)
	_backend.tool_update.connect(_on_backend_tool_update)
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
	var plan := _mode_plan.button_pressed
	var auto := _auto_check.button_pressed
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
	_status_dot.add_theme_color_override("font_color",
		Color(0.36, 0.78, 0.42) if avail["ok"] else Color(0.9, 0.4, 0.35))
	_status_dot.tooltip_text = String(avail["detail"])
	var mode := "Plan" if _mode_plan.button_pressed else ("Build · Auto" if _auto_check.button_pressed else "Build · Safe")
	var text := "%s  ·  MCP :%d" % [mode, mcp_port]
	if extra != "":
		text += "  ·  " + extra
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
	_record({"role": "user", "text": text})
	_last_final_text = ""
	_turn_checkpoint = ""
	if checkpoints != null and checkpoints.available and not _mode_plan.button_pressed \
			and bool(_cfg.get_value("checkpoints", "enabled", true)):
		_turn_checkpoint = checkpoints.checkpoint()
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
	_last_final_text = ""
	_collapse_thinking()
	_reset_pills()
	_pills.clear()
	_rec_by_call.clear()
	_chat = {}
	_welcome()


func _set_busy(b: bool) -> void:
	_busy = b
	_send_btn.disabled = b
	_stop_btn.disabled = not b
	_working.visible = b
	if _working_tween != null:
		_working_tween.kill()
		_working_tween = null
	if b:
		_working.modulate.a = 1.0
		_working_tween = create_tween().set_loops()
		_working_tween.tween_property(_working, "modulate:a", 0.25, 0.6)
		_working_tween.tween_property(_working, "modulate:a", 1.0, 0.6)
	else:
		_refresh_status()


# ------------------------------------------------------------------ backend events

func _on_backend_status(text: String) -> void:
	_refresh_status(text)


func _on_backend_thinking_delta(text: String) -> void:
	if _think_body == null or not is_instance_valid(_think_body):
		_begin_thinking_block()
	_think_raw += text
	_think_body.text = _think_raw
	_queue_scroll()


func _begin_thinking_block() -> void:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	_think_header = Button.new()
	_think_header.flat = true
	_think_header.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_think_header.text = "✦ Thinking ▾"
	_think_header.add_theme_font_size_override("font_size", 10)
	_think_header.modulate = Color(1, 1, 1, 0.5)
	var body := RichTextLabel.new()
	body.bbcode_enabled = false
	body.fit_content = true
	body.scroll_active = false
	body.selection_enabled = true
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_font_size_override("normal_font_size", 11)
	body.modulate = Color(1, 1, 1, 0.5)
	var header := _think_header
	_think_header.pressed.connect(func():
		body.visible = not body.visible
		header.text = header.text.trim_suffix("▸").trim_suffix("▾") + ("▾" if body.visible else "▸"))
	box.add_child(_think_header)
	box.add_child(body)
	_messages.add_child(box)
	_think_body = body
	_think_raw = ""


func _collapse_thinking() -> void:
	if _think_body != null and is_instance_valid(_think_body) and _think_body.visible:
		_think_body.visible = false
		if _think_header != null and is_instance_valid(_think_header):
			_think_header.text = "✦ Thought ▸"
	if _think_raw.strip_edges() != "":
		_record({"role": "thinking", "text": _think_raw})
	_think_body = null
	_think_header = null
	_think_raw = ""


func _on_backend_stream_delta(text: String) -> void:
	_collapse_thinking()
	_reset_pills()
	if _cur_label == null:
		_begin_assistant_bubble()
	_cur_raw += text
	_cur_label.text = _md_to_bbcode(_cur_raw)
	_queue_scroll()


func _on_backend_message_complete(full_text: String) -> void:
	_collapse_thinking()
	_reset_pills()
	if _cur_label == null and full_text.strip_edges() == _last_final_text.strip_edges():
		return  # this text already streamed and was finalized at a tool boundary
	if _cur_label == null:
		_begin_assistant_bubble()
	_cur_raw = full_text
	_cur_label.text = _md_to_bbcode(_cur_raw)
	_finalize_stream()
	_queue_scroll()


func _short_tool(tool_name: String) -> String:
	return tool_name.replace("mcp__godot_editor__", "").replace("godot_editor_", "")


func _on_backend_tool_activity(call_id: String, tool_name: String, _detail: String) -> void:
	_finalize_stream()
	_collapse_thinking()
	var short_name := _short_tool(tool_name)
	# Coalesce a repeat of the exact same plain call (e.g. get_run_output ×3).
	if _last_pill.get("name", "") == short_name and _last_pill.get("plain", false) \
			and _last_pill.get("label") != null and is_instance_valid(_last_pill["label"]):
		_last_pill["count"] += 1
		_last_pill["label"].text = "%s ×%d" % [short_name, _last_pill["count"]]
		if call_id != "":
			_pills[call_id] = _last_pill
		_queue_scroll()
		return
	if _tool_flow == null or not is_instance_valid(_tool_flow):
		_tool_flow = HFlowContainer.new()
		_tool_flow.add_theme_constant_override("h_separation", 4)
		_tool_flow.add_theme_constant_override("v_separation", 4)
		_messages.add_child(_tool_flow)
	var pill := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(1, 1, 1, 0.06)
	style.set_corner_radius_all(9)
	style.content_margin_left = 8
	style.content_margin_right = 8
	style.content_margin_top = 2
	style.content_margin_bottom = 2
	pill.add_theme_stylebox_override("panel", style)
	var label := Label.new()
	label.text = short_name
	label.add_theme_font_size_override("font_size", 10)
	label.add_theme_font_override("font", _mono_font())
	label.modulate = Color(1, 1, 1, 0.7)
	pill.add_child(label)
	_tool_flow.add_child(pill)
	var entry := {"name": short_name, "pill": pill, "label": label, "flow": _tool_flow,
		"count": 1, "plain": true, "body": "", "expand": null}
	if call_id != "":
		_pills[call_id] = entry
		var rec_idx := _record({"role": "tool", "name": short_name, "detail": "", "body": ""})
		if rec_idx >= 0:
			_rec_by_call[call_id] = rec_idx
	_last_pill = entry
	_queue_scroll()


func _on_backend_tool_update(call_id: String, tool_name: String, detail: String, body: String) -> void:
	var entry = _pills.get(call_id)
	if entry == null or entry.get("label") == null or not is_instance_valid(entry["label"]):
		if tool_name == "":
			return
		_on_backend_tool_activity(call_id, tool_name, "")
		entry = _pills.get(call_id)
		if entry == null:
			return
	if int(entry["count"]) == 1 and detail != "":
		entry["plain"] = false
		var text: String = entry["name"] + "  ·  " + detail
		if body != "":
			text += "  ▸"
		entry["label"].text = text
	if detail != "":
		entry["label"].tooltip_text = detail
	if body != "" and entry.get("expand") == null and is_instance_valid(entry["pill"]):
		entry["body"] = body
		var pill: PanelContainer = entry["pill"]
		pill.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		pill.tooltip_text = "Click to see the change"
		pill.gui_input.connect(func(ev: InputEvent):
			if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
				_toggle_diff(entry))
	if not _restoring and _rec_by_call.has(call_id):
		var rec_idx: int = _rec_by_call[call_id]
		if rec_idx < _chat.get("messages", []).size():
			if detail != "":
				_chat["messages"][rec_idx]["detail"] = detail
			if body != "":
				_chat["messages"][rec_idx]["body"] = body
			ChatStore.save(_chat)
	_queue_scroll()


func _toggle_diff(entry: Dictionary) -> void:
	var expand = entry.get("expand")
	if expand != null and is_instance_valid(expand):
		expand.visible = not expand.visible
		_queue_scroll()
		return
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0.28)
	style.set_corner_radius_all(8)
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 6
	style.content_margin_bottom = 6
	panel.add_theme_stylebox_override("panel", style)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var label := _rich_label(true)
	label.add_theme_font_size_override("normal_font_size", 11)
	label.text = _diff_to_bbcode(String(entry["body"]))
	panel.add_child(label)
	var flow = entry.get("flow")
	_messages.add_child(panel)
	if flow != null and is_instance_valid(flow):
		_messages.move_child(panel, flow.get_index() + 1)
	entry["expand"] = panel
	_queue_scroll()


func _diff_to_bbcode(diff: String) -> String:
	var out: Array[String] = []
	for raw_line in diff.split("\n"):
		var line := raw_line.replace("[", "[lb]")
		if raw_line.begins_with("+"):
			line = "[color=#8fce8f]" + line + "[/color]"
		elif raw_line.begins_with("-"):
			line = "[color=#e08585]" + line + "[/color]"
		out.append(line)
	return "[code]" + "\n".join(out) + "[/code]"


func _reset_pills() -> void:
	_tool_flow = null
	_last_pill = {}


func _on_backend_turn_done(meta: Dictionary) -> void:
	_finalize_stream()
	_collapse_thinking()
	_reset_pills()
	_pills.clear()
	if meta.get("is_error", false):
		_add_error("turn ended with an error (%s): %s" % [meta.get("subtype", "?"), String(meta.get("result", "")).left(300)])
	var bits: Array[String] = []
	if float(meta.get("cost_usd", 0)) > 0:
		bits.append("$%.4f" % float(meta["cost_usd"]))
	if int(meta.get("num_turns", 0)) > 0:
		bits.append("%d steps" % int(meta["num_turns"]))
	if int(meta.get("duration_ms", 0)) > 0:
		bits.append("%.1fs" % (int(meta["duration_ms"]) / 1000.0))
	var done_text := "✓ done" + ("   " + "  ·  ".join(bits) if not bits.is_empty() else "")
	_add_done_row(done_text, _turn_checkpoint)
	if not _chat.is_empty():
		_record({"role": "meta", "text": done_text})
		_chat["session_id"] = String(_backend.session_id) if "session_id" in _backend else ""
		_chat["backend"] = _backend_id
		_chat["model"] = CLAUDE_MODELS[_claude_model_sel.selected] if _backend_id == "claude_code" else _model_btn.text
		ChatStore.save(_chat)
	_set_busy(false)
	if tools != null and tools.editor_enabled:
		tools.call_tool("refresh_filesystem", {})
	_queue_scroll()


func _on_backend_error(message: String) -> void:
	_finalize_stream()
	_collapse_thinking()
	_reset_pills()
	_add_error(message)
	if not _chat.is_empty():
		_record({"role": "error", "text": message})
	_set_busy(false)
	_queue_scroll()


# ------------------------------------------------------------------ bubbles

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
	_messages.add_child(_caption("YOU"))
	var wrap := MarginContainer.new()
	wrap.add_theme_constant_override("margin_left", 24)
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	var c := _accent()
	c.a = 0.14
	style.bg_color = c
	style.set_corner_radius_all(10)
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 7
	style.content_margin_bottom = 7
	panel.add_theme_stylebox_override("panel", style)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var label := _rich_label(false)
	label.text = text
	panel.add_child(label)
	wrap.add_child(panel)
	_messages.add_child(wrap)


func _begin_assistant_bubble() -> void:
	_messages.add_child(_caption("AGENT"))
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(1, 1, 1, 0.025)
	style.set_corner_radius_all(10)
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 7
	style.content_margin_bottom = 7
	var a := _accent()
	a.a = 0.4
	style.border_color = a
	style.border_width_left = 2
	panel.add_theme_stylebox_override("panel", style)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var label := _rich_label(true)
	panel.add_child(label)
	_messages.add_child(panel)
	_cur_label = label
	_cur_raw = ""


func _finalize_stream() -> void:
	if _cur_label != null and _cur_raw.strip_edges() != "":
		_last_final_text = _cur_raw
		_record({"role": "assistant", "text": _cur_raw})
	if _cur_label != null and _cur_raw.strip_edges() == "":
		var panel := _cur_label.get_parent()
		if panel != null:
			var i := panel.get_index()
			if i > 0:
				var prev := _messages.get_child(i - 1)
				if prev is Label and prev.text == "AGENT":
					prev.queue_free()
			panel.queue_free()
	_cur_label = null
	_cur_raw = ""


func _add_error(text: String) -> void:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.8, 0.2, 0.18, 0.16)
	style.set_corner_radius_all(10)
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 7
	style.content_margin_bottom = 7
	panel.add_theme_stylebox_override("panel", style)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var label := _rich_label(false)
	label.text = "⚠  " + text
	panel.add_child(label)
	_messages.add_child(panel)
	_queue_scroll()


func _add_meta(text: String) -> void:
	var label := _caption(text, 10)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_messages.add_child(label)
	_queue_scroll()


func _add_done_row(text: String, cp: String) -> void:
	var row := HBoxContainer.new()
	var label := _caption(text, 10)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)
	if cp != "" and checkpoints != null:
		var btn := Button.new()
		btn.text = "↩ revert"
		btn.flat = true
		btn.add_theme_font_size_override("font_size", 10)
		btn.modulate = Color(1, 1, 1, 0.55)
		btn.tooltip_text = "Restore every project file to how it was before this turn.\nFiles the turn created are deleted; the editor cache (.godot) is untouched."
		btn.pressed.connect(func(): _confirm_revert(cp, btn))
		row.add_child(btn)
	_messages.add_child(row)
	_queue_scroll()


func _confirm_revert(cp: String, btn: Button) -> void:
	var d := ConfirmationDialog.new()
	d.dialog_text = "Revert all project files to before this turn?\nFiles created during the turn will be deleted."
	d.ok_button_text = "Revert"
	add_child(d)
	d.confirmed.connect(func():
		var err: String = checkpoints.restore(cp)
		if err != "":
			_add_error("revert failed: " + err)
		else:
			if tools != null and tools.editor_enabled:
				EditorInterface.get_resource_filesystem().scan()
			_add_meta("↩ reverted to the pre-turn checkpoint · reopen scenes if the editor asks")
			_record({"role": "meta", "text": "↩ reverted to the pre-turn checkpoint"})
			btn.disabled = true
		d.queue_free())
	d.canceled.connect(func(): d.queue_free())
	d.popup_centered()


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

## Minimal, safe markdown→bbcode: escape brackets, then fenced code (mono on a
## dark backdrop), inline code, bold, headers.
func _md_to_bbcode(md: String) -> String:
	var out := ""
	var in_code := false
	for raw_line in md.split("\n"):
		var line: String = raw_line
		if line.strip_edges().begins_with("```"):
			out += "[bgcolor=#00000042][code]" if not in_code else "[/code][/bgcolor]"
			in_code = not in_code
			out += "\n"
			continue
		line = line.replace("[", "[lb]")
		if not in_code:
			line = _re_inline_code.sub(line, "[bgcolor=#00000042][code]$1[/code][/bgcolor]", true)
			line = _re_bold.sub(line, "[b]$1[/b]", true)
			if line.begins_with("# ") or line.begins_with("## ") or line.begins_with("### "):
				line = "[b]" + line.lstrip("# ") + "[/b]"
		out += line + "\n"
	if in_code:
		out += "[/code][/bgcolor]"
	return out.rstrip("\n")
