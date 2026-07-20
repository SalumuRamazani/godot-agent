@tool
extends EditorPlugin
## Godot Agent: AI chat dock (right side) + in-editor MCP server. The MCP
## server exposes live editor tools on 127.0.0.1; the selected AI backend
## (Claude Code CLI, or experimentally opencode) is spawned per message with
## the project root as its working directory and this MCP server configured.

const McpServer := preload("mcp/http_server.gd")
const McpTools := preload("mcp/tools.gd")
const ClaudeBackend := preload("backends/claude_code.gd")
const OpencodeBackend := preload("backends/opencode.gd")
const AgentDock := preload("dock/agent_dock.gd")
const Checkpoints := preload("util/checkpoints.gd")

const PROBE_AUTOLOAD := "GodotAgentProbe"

var server
var tools
var dock
var checkpoints
var backends := {}


func _enter_tree() -> void:
	tools = McpTools.new()
	server = McpServer.new()
	server.tools = tools
	tools.server = server  # for async (approval) responses; both cleared on exit
	if server.start(8765) != OK:
		push_error("Godot Agent: could not bind any MCP port in 8765-8774; agent tools will be unavailable")
	_write_backend_configs()

	var project_root := ProjectSettings.globalize_path("res://")
	var claude := ClaudeBackend.new()
	claude.project_dir = project_root
	claude.mcp_config_path = ProjectSettings.globalize_path("user://godot_agent_mcp.json")
	var opencode := OpencodeBackend.new()
	opencode.project_dir = project_root
	opencode.opencode_config_path = ProjectSettings.globalize_path("user://godot_agent_opencode.json")
	opencode.mcp_url = "http://127.0.0.1:%d/mcp" % server.port
	backends = {"claude_code": claude, "opencode": opencode}

	checkpoints = Checkpoints.new()
	checkpoints.available = checkpoints.setup()
	if not ProjectSettings.has_setting("autoload/" + PROBE_AUTOLOAD):
		add_autoload_singleton(PROBE_AUTOLOAD, "res://addons/godot_agent/runtime/frame_probe.gd")

	dock = AgentDock.new()
	dock.name = "Agent"
	dock.setup(backends, ["claude_code", "opencode"], tools, server.port)
	dock.checkpoints = checkpoints
	# Bottom-right slot: usually empty, so the dock gets its own always-visible
	# panel under the Inspector instead of an overflowing tab strip.
	add_control_to_dock(EditorPlugin.DOCK_SLOT_RIGHT_BL, dock)
	call_deferred("_focus_dock")
	print("Godot Agent ready — 'Agent' panel on the lower right, MCP on 127.0.0.1:%d" % server.port)


func _focus_dock() -> void:
	if dock == null:
		return
	var tabs := dock.get_parent() as TabContainer
	if tabs != null:
		var idx := tabs.get_tab_idx_from_control(dock)
		if idx >= 0:
			tabs.current_tab = idx
		print("Godot Agent dock placed: container=%s tab %d/%d, visible=%s" % [
			tabs.get_class(), idx, tabs.get_tab_count(), str(dock.is_visible_in_tree())])


func _process(_delta: float) -> void:
	if server != null:
		server.poll()
	for b in backends.values():
		b.pump()
	if tools != null:
		tools.pump()


func _exit_tree() -> void:
	for b in backends.values():
		b.cancel()
		if b.has_method("shutdown"):
			b.shutdown()
	backends.clear()
	if tools != null:
		tools.shutdown()
		tools = null
	if server != null:
		server.stop()
		server = null
	if dock != null:
		remove_control_from_docks(dock)
		dock.queue_free()
		dock = null


func _write_backend_configs() -> void:
	# The opencode backend regenerates its own config before every run.
	var url := "http://127.0.0.1:%d/mcp" % server.port
	var claude_cfg := {"mcpServers": {"godot_editor": {"type": "http", "url": url}}}
	var f := FileAccess.open("user://godot_agent_mcp.json", FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(claude_cfg, "  "))
