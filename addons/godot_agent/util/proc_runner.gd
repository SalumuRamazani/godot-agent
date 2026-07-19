@tool
extends RefCounted
## Runs a child process with piped stdio and delivers its output lines on the
## caller's thread via pump(), which must be called regularly (e.g. from
## _process). Reader threads only touch mutex-guarded queues, so this works in
## the editor and in headless test scripts alike.
##
## OS.execute_with_pipe has no working-directory argument, so the command is
## wrapped in `/bin/sh -c "cd <cwd> && exec <exe> <args>"`.

signal line_out(line: String)
signal line_err(line: String)
signal finished(exit_code: int)

const MAX_QUEUED_LINES := 10000

var pid: int = -1
var running := false

var _stdio: FileAccess
var _stderr: FileAccess
var _threads: Array[Thread] = []
var _mutex := Mutex.new()
var _q_out := PackedStringArray()
var _q_err := PackedStringArray()
var _eof_count := 0


static func shell_quote(s: String) -> String:
	return "'" + s.replace("'", "'\\''") + "'"


## force_non_tty: give the child /dev/null stdin and a pipe (not the PTY) as
## stdout, via `exec … < /dev/null > >(cat)`. Some CLIs (Bun binaries like
## opencode) hang or misbehave when they detect a TTY. Streaming still works —
## the cat relay writes to our PTY. Requires /bin/bash for >(…).
func start(exe: String, args: PackedStringArray, cwd: String = "", env: Dictionary = {}, force_non_tty: bool = false) -> Error:
	if running:
		return ERR_BUSY
	var cmd := ""
	if cwd != "":
		cmd += "cd " + shell_quote(cwd) + " && "
	for k in env:
		cmd += String(k) + "=" + shell_quote(str(env[k])) + " "
	cmd += "exec " + shell_quote(exe)
	for a in args:
		cmd += " " + shell_quote(a)
	var shell := "/bin/sh"
	if force_non_tty:
		shell = "/bin/bash"
		cmd += " < /dev/null > >(cat)"
	var info: Dictionary = OS.execute_with_pipe(shell, PackedStringArray(["-c", cmd]))
	if info.is_empty():
		return FAILED
	_stdio = info["stdio"]
	_stderr = info["stderr"]
	pid = info["pid"]
	running = true
	_eof_count = 0
	_q_out.clear()
	_q_err.clear()
	var t_out := Thread.new()
	t_out.start(_read_loop.bind(_stdio, true))
	_threads.append(t_out)
	var t_err := Thread.new()
	t_err.start(_read_loop.bind(_stderr, false))
	_threads.append(t_err)
	return OK


func _read_loop(f: FileAccess, is_stdout: bool) -> void:
	# Pipe EOF reporting is unreliable across platforms (PTY-backed pipes can
	# return empty reads without ERR_FILE_EOF after the child dies), so treat
	# "empty read + process gone" as EOF too, and never spin hot. Deliberate
	# tradeoff: genuinely blank output lines are dropped.
	while f != null and f.is_open():
		var line := f.get_line()
		var err := f.get_error()
		if line != "":
			_mutex.lock()
			if is_stdout:
				if _q_out.size() < MAX_QUEUED_LINES:
					_q_out.append(line)
			else:
				if _q_err.size() < MAX_QUEUED_LINES:
					_q_err.append(line)
			_mutex.unlock()
		if err != OK:
			break
		if line == "":
			if not OS.is_process_running(pid):
				break
			OS.delay_msec(10)
	_mutex.lock()
	_eof_count += 1
	_mutex.unlock()


## Drain queued output on the calling thread. Emits line_out/line_err per line
## and finished(exit_code) once both pipes hit EOF.
func pump() -> void:
	# Signal handlers may drop their reference to us (e.g. a backend clearing
	# its proc on `finished`); keep self alive for the duration of the call.
	var _self_guard: RefCounted = self
	if _threads.is_empty():
		return
	_mutex.lock()
	var outs := _q_out.duplicate()
	_q_out.clear()
	var errs := _q_err.duplicate()
	_q_err.clear()
	var eofs := _eof_count
	_mutex.unlock()
	for l in outs:
		line_out.emit(l)
	for l in errs:
		line_err.emit(l)
	if eofs >= 2 and running:
		running = false
		for t in _threads:
			if t.is_started():
				t.wait_to_finish()
		_threads.clear()
		var code := OS.get_process_exit_code(pid)
		_stdio = null
		_stderr = null
		finished.emit(code)


func kill() -> void:
	if pid > 0 and running:
		OS.kill(pid)
	# Readers hit EOF after the kill; keep pumping until finished fires.


## Blocking cleanup for plugin teardown (does not emit signals).
func shutdown() -> void:
	if running and pid > 0:
		OS.kill(pid)
	for t in _threads:
		if t.is_started():
			t.wait_to_finish()
	_threads.clear()
	_stdio = null
	_stderr = null
	running = false
