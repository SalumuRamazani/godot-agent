@tool
extends RefCounted
## Locates CLI binaries by absolute path. A Finder-launched Godot has no shell
## PATH, so we check known install locations first and only fall back to asking
## a login shell.


static func find(cli_name: String, override_path: String = "") -> String:
	if override_path != "" and FileAccess.file_exists(override_path):
		return override_path
	var home := OS.get_environment("HOME")
	var candidates := [
		home + "/.local/bin/" + cli_name,
		"/opt/homebrew/bin/" + cli_name,
		"/usr/local/bin/" + cli_name,
		home + "/.claude/local/" + cli_name,
		home + "/.opencode/bin/" + cli_name,
		home + "/bin/" + cli_name,
	]
	for c in candidates:
		if FileAccess.file_exists(c):
			return c
	var out := []
	var code := OS.execute("/bin/zsh", PackedStringArray(["-l", "-c", "command -v " + cli_name]), out)
	if code == 0 and out.size() > 0:
		var lines := String(out[0]).strip_edges().split("\n")
		var p := String(lines[lines.size() - 1]).strip_edges()
		if p != "" and FileAccess.file_exists(p):
			return p
	return ""
