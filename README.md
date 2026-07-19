# Godot Agent

An AI coding agent that lives **inside the Godot editor** — a chat dock on the right side that sees your scenes, edits your scripts, runs your game and reads the errors. Like Cursor/Replit, but for Godot, powered by the **Claude Code** subscription you already have (experimental opencode support included).

Pure GDScript. No native code, no Python, no Node.js, no API keys pasted anywhere.

## How it works

```
┌─ Godot editor ─────────────────────────────────┐
│  Agent dock (chat) ── spawns ──► claude CLI    │
│  MCP server :8765  ◄── connects ──┘            │
│  (scene tools, class docs, run project, …)     │
└────────────────────────────────────────────────┘
```

- The plugin starts a tiny **MCP server** on `127.0.0.1:8765` (localhost only) exposing live editor tools: scene tree, add/move/delete nodes, set properties, attach scripts, exact ClassDB API lookup, run the project and capture its output.
- Each chat message spawns your **`claude` CLI** in the project root (`--output-format stream-json`), pre-wired to that MCP server and to a Godot-specific system prompt. Claude edits `.gd` files with its own file tools and manipulates scenes/runs the game through the editor tools.
- Every message is prefixed with a live snapshot of your editor state (current scene tree, selection, open script, last run output), so the agent always has full context.

## Requirements

- Godot **4.3+** (built and tested on 4.7)
- [Claude Code](https://claude.com/claude-code) installed and logged in (`claude` CLI) — the plugin finds it in the usual install locations even when Godot is launched from Finder
- macOS (Linux likely works; Windows needs CLI-discovery paths added — PRs welcome)

## Install

1. Copy the `addons/godot_agent` folder into your project's `addons/` directory.
2. Project → Project Settings → Plugins → enable **Godot Agent**.
3. The **Agent** dock appears on the right. Type something like:

> Create a scene with a bouncing ball, then run it and fix any errors.

## Controls

| Control | Meaning |
|---|---|
| Backend | **Claude Code** (default) or **opencode** (experimental) |
| Model | sonnet / opus / haiku |
| Safe (accept edits) | Claude may edit files and use editor tools; arbitrary shell commands are still blocked |
| Full Auto (YOLO) | `bypassPermissions` — the agent can run anything. Use in projects you have under version control. |
| New | Fresh conversation (new agent session) |
| Stop | Kill the current turn |

Settings persist per project in `user://godot_agent.cfg`. If your `claude` binary lives somewhere unusual, set it there:

```ini
[cli]
claude_code="/path/to/claude"
opencode="/path/to/opencode"
```

## Security notes

- The MCP server binds to **127.0.0.1 only** and exposes editor operations for the open project — nothing outside it.
- `--strict-mcp-config` is used, so the spawned Claude session sees *only* this MCP server, not your global ones.
- **Full Auto** mode is Claude Code's `bypassPermissions`: the agent can execute shell commands without asking. Keep your project in git.

## Editor tools exposed to the agent

`get_editor_state`, `get_scene_tree`, `open_scene`, `create_scene`, `save_all_scenes`, `add_node`, `delete_node`, `move_node`, `rename_node`, `set_node_properties`, `attach_script`, `get_class_info`, `search_classes`, `run_project`, `get_run_output`, `stop_run`, `play_in_editor`, `stop_playing`, `refresh_filesystem`

## Development / tests

This repo is itself a minimal Godot project — open it in Godot and the dock loads. Headless tests (no tokens spent):

```sh
godot --headless -s tests/test_mcp_server.gd      # MCP protocol over real loopback HTTP
godot --headless -s tests/test_stream_parser.gd   # stream-json parsing via a fake claude CLI
```

## Troubleshooting

- **"claude CLI not found"** — install Claude Code, or set the path in `user://godot_agent.cfg` (see above). Note `user://` is `~/Library/Application Support/Godot/app_userdata/<Project Name>/` on macOS.
- **Errors mentioning usage/spend limits** — that's your Claude subscription limit, not the plugin; check claude.ai/settings/usage.
- **Agent can't see files it just created** — it should call `refresh_filesystem` itself; the dock also rescans after every turn.

## Roadmap

- Git checkpoint/undo per agent turn (Ziva-style)
- Screenshot tool (editor viewport → agent)
- Full opencode streaming backend
- Windows/Linux CLI discovery

## License

MIT — see [LICENSE](LICENSE).
