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
- Each chat message spawns your chosen agent CLI in the project root, pre-wired to that MCP server and to a Godot-specific system prompt. The agent edits `.gd` files with its own file tools and manipulates scenes/runs the game through the editor tools.
  - **Claude Code backend**: `claude -p … --output-format stream-json`, uses your Claude subscription.
  - **opencode backend**: `opencode run --format json` — runs **any model opencode supports**: OpenRouter (GLM, Kimi, DeepSeek, Qwen, …), direct provider keys, or the built-in free `opencode/*-free` models which need **no key at all**.
- Every message is prefixed with a live snapshot of your editor state (current scene tree, selection, open script, last run output), so the agent always has full context.

## Requirements

- Godot **4.3+** (built and tested on 4.7)
- At least one backend CLI:
  - [Claude Code](https://claude.com/claude-code) installed and logged in (`claude` CLI), and/or
  - [opencode](https://opencode.ai): `curl -fsSL https://opencode.ai/install | bash`
- The plugin finds both CLIs in the usual install locations even when Godot is launched from Finder
- macOS (Linux likely works; Windows needs CLI-discovery paths added — PRs welcome)

## Install

1. Copy the `addons/godot_agent` folder into your project's `addons/` directory.
2. Project → Project Settings → Plugins → enable **Godot Agent**.
3. The **Agent** dock appears on the right. Type something like:

> Create a scene with a bouncing ball, then run it and fix any errors.

## Controls

| Control | Meaning |
|---|---|
| Backend | **Claude Code** or **opencode** |
| Model | Claude Code: sonnet / opus / haiku. opencode: free-form `provider/model` field + a **Models** browser |
| Models (opencode) | Lists every model your keys unlock (`opencode models`) — click one to select it |
| variant (opencode) | Provider reasoning effort: minimal / low / medium / high / max |
| Keys… (opencode) | Paste API keys (`KEY=value` per line) + optional extra opencode config JSON |
| Safe (accept edits) | The agent may edit files and use editor tools; arbitrary shell commands are still blocked |
| Full Auto (YOLO) | Claude: `bypassPermissions` · opencode: `--auto`. The agent can run anything — keep your project in git. |
| New | Fresh conversation (new agent session) |
| Stop | Kill the current turn |

## Running GLM, Kimi, or any model (OpenRouter)

1. Switch the backend dropdown to **OpenRouter / opencode**. It already works with the free `opencode/*-free` models — no key needed. (opencode is the local agent engine; OpenRouter is where the models come from.)
2. Click **Keys…** and paste your key(s), one per line:
   ```
   OPENROUTER_API_KEY=sk-or-…
   ```
   OpenRouter alone unlocks GLM, Kimi, DeepSeek, Qwen, Gemini, GPT and hundreds more. You can also use direct provider keys (`ZHIPUAI_API_KEY` for GLM, `MOONSHOT_API_KEY` for Kimi, …), or run `opencode auth login` once in a terminal instead.
3. Click **Models** and pick one — e.g. `openrouter/z-ai/glm-4.6` or `openrouter/moonshotai/kimi-k2` (use whatever exact ids the list shows) — or type any `provider/model` straight into the field.
4. Optional: set a **variant** (reasoning effort) and put provider parameters (temperature etc.) in the **Keys…** dialog's extra-config JSON, e.g.
   ```json
   {"provider": {"openrouter": {"options": {"temperature": 0.6}}}}
   ```
5. Chat. Same editor tools, same workflow as the Claude backend.

Settings persist per project in `user://godot_agent.cfg` (macOS: `~/Library/Application Support/Godot/app_userdata/<Project Name>/`). API keys are stored there in plain text — keep that file out of any repo. If a CLI lives somewhere unusual:

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
godot --headless -s tests/test_mcp_server.gd       # MCP protocol over real loopback HTTP
godot --headless -s tests/test_stream_parser.gd    # stream-json parsing via a fake claude CLI
godot --headless -s tests/test_opencode_parser.gd  # opencode event parsing via a fake opencode CLI
```

## Troubleshooting

- **"claude CLI not found"** — install Claude Code, or set the path in `user://godot_agent.cfg` (see above). Note `user://` is `~/Library/Application Support/Godot/app_userdata/<Project Name>/` on macOS.
- **Errors mentioning usage/spend limits** — that's your Claude subscription limit, not the plugin; check claude.ai/settings/usage.
- **Agent can't see files it just created** — it should call `refresh_filesystem` itself; the dock also rescans after every turn.

## Roadmap

- Git checkpoint/undo per agent turn (Ziva-style)
- Screenshot tool (editor viewport → agent)
- Windows/Linux CLI discovery

## License

MIT — see [LICENSE](LICENSE).
