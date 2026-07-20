@tool
extends RefCounted
## Per-turn safety net: snapshots the whole project into a SHADOW git repo
## (its own git-dir under user://) before every Build turn, so one click can
## revert whatever a turn did. The project's real .git — if any — is never
## touched or required.

const CliFinder := preload("cli_finder.gd")

var git_path := ""
var git_dir := ""
var work_tree := ""
var available := false


func setup() -> bool:
	git_path = CliFinder.find("git")
	if git_path == "":
		return false
	work_tree = ProjectSettings.globalize_path("res://")
	git_dir = ProjectSettings.globalize_path("user://godot_agent_history.git")
	if not DirAccess.dir_exists_absolute(git_dir):
		var out := []
		if OS.execute(git_path, PackedStringArray(["init", "--quiet", "--bare", git_dir]), out) != 0:
			return false
		# A bare repo plus explicit --work-tree gives us snapshots without a
		# .git in the project. Never snapshot editor caches or our own state.
		var f := FileAccess.open(git_dir.path_join("info/exclude"), FileAccess.WRITE)
		if f != null:
			f.store_string(".godot/\n.git/\n.DS_Store\n*.tmp\n")
	return true


func _git(args: Array) -> Dictionary:
	var full := PackedStringArray(["-C", work_tree, "--git-dir=" + git_dir, "--work-tree=" + work_tree])
	full.append_array(PackedStringArray(args))
	var out := []
	var code := OS.execute(git_path, full, out, true)
	return {"code": code, "out": String(out[0]) if out.size() > 0 else ""}


## Snapshot the current project state; returns the commit hash ("" on failure).
func checkpoint() -> String:
	if git_dir == "":
		return ""
	_git(["add", "-A"])
	_git(["-c", "user.email=agent@godot.local", "-c", "user.name=Godot Agent",
		"commit", "--quiet", "--allow-empty", "-m",
		"checkpoint " + Time.get_datetime_string_from_system()])
	var r := _git(["rev-parse", "HEAD"])
	return r["out"].strip_edges() if r["code"] == 0 else ""


## Restore every tracked file to the given checkpoint and delete files created
## since (excluding .godot). Returns an error string, or "" on success.
func restore(hash: String) -> String:
	if hash == "":
		return "no checkpoint hash"
	var r := _git(["checkout", "--quiet", hash, "--", "."])
	if r["code"] != 0:
		return "checkout failed: " + r["out"].left(200)
	# Remove files that did not exist at the checkpoint (they are untracked
	# relative to it after the index reset below).
	_git(["reset", "--quiet", hash])
	_git(["clean", "-fdq", "-e", ".godot"])
	return ""
