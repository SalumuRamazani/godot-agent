#!/bin/sh
# Emits a canned Claude Code stream-json conversation so the backend parser
# and process plumbing can be tested without spending tokens. Ignores args.
emit() { printf '%s\n' "$1"; sleep 0.02; }
emit '{"type":"system","subtype":"init","session_id":"fake-session-1234","model":"claude-test","tools":[]}'
emit '{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}}'
emit '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello "}}}'
emit '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"world."}}}'
emit '{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"mcp__godot_editor__add_node","input":{}}}}'
emit '{"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"Hello world."},{"type":"tool_use","id":"toolu_1","name":"mcp__godot_editor__add_node","input":{"type":"Sprite2D","node_name":"Hero"}}]}}'
emit '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"ok","is_error":false}]}}'
emit '{"type":"assistant","message":{"id":"m2","content":[{"type":"text","text":"Done! Added the node."}]}}'
emit '{"type":"result","subtype":"success","is_error":false,"duration_ms":1234,"num_turns":2,"result":"Done! Added the node.","session_id":"fake-session-1234","total_cost_usd":0.0042}'
exit 0
