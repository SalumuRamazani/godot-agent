#!/bin/sh
# Emits canned `opencode run --format json` events (captured from opencode
# 1.18.3) so the backend parser can be tested without tokens. Ignores args.
emit() { printf '%s\n' "$1"; sleep 0.02; }
emit '{"type":"step_start","timestamp":1,"sessionID":"ses_fake123","part":{"id":"prt_1","messageID":"msg_1","sessionID":"ses_fake123","type":"step-start"}}'
emit '{"type":"text","timestamp":2,"sessionID":"ses_fake123","part":{"id":"prt_2","messageID":"msg_1","sessionID":"ses_fake123","type":"text","text":"Hello "}}'
emit '{"type":"text","timestamp":3,"sessionID":"ses_fake123","part":{"id":"prt_2","messageID":"msg_1","sessionID":"ses_fake123","type":"text","text":"Hello world."}}'
emit '{"type":"tool","timestamp":4,"sessionID":"ses_fake123","part":{"id":"prt_3","messageID":"msg_1","sessionID":"ses_fake123","type":"tool","tool":"godot_editor_get_editor_state","callID":"call_1","state":{"status":"completed","input":{},"output":"{}"}}}'
emit '{"type":"step_finish","timestamp":5,"sessionID":"ses_fake123","part":{"id":"prt_4","reason":"tool-calls","messageID":"msg_1","sessionID":"ses_fake123","type":"step-finish","tokens":{"total":100,"input":90,"output":10,"reasoning":0,"cache":{"write":0,"read":0}},"cost":0.001}}'
emit '{"type":"text","timestamp":6,"sessionID":"ses_fake123","part":{"id":"prt_5","messageID":"msg_2","sessionID":"ses_fake123","type":"text","text":"Done."}}'
emit '{"type":"step_finish","timestamp":7,"sessionID":"ses_fake123","part":{"id":"prt_6","reason":"stop","messageID":"msg_2","sessionID":"ses_fake123","type":"step-finish","tokens":{"total":50,"input":45,"output":5,"reasoning":0,"cache":{"write":0,"read":0}},"cost":0.002}}'
exit 0
