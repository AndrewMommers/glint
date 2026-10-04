class_name Updater
extends Node
## In-game updates. Release builds read the website's release.json. When a
## newer version is out and only the game files changed (Glint.pck,
## glint-server.exe), it downloads just those, checks their SHA-256, and
## swaps them in on restart. If the engine (Glint.exe) changed or the install
## folder isn't writable, the player is sent to the download page instead.

signal checked(info: Dictionary)  # {version, mode: "patch"|"installer", bytes, notes}; empty if up to date
signal progress(done: int, total: int)
signal failed(message: String)
signal downloaded

const SWAP_SCRIPT := "glint-update.cmd"

var info := {}  # the last check's result
var _manifest := {}
var _queue: Array = []  # files still to download
var _current := {}
var _http: HTTPRequest
var _done_bytes := 0
var _total_bytes := 0
var busy := false


func install_dir() -> String:
	return OS.get_executable_path().get_base_dir()


## Looks for an update. Emits checked() with the result.
func check() -> void:
	if not Release.is_release() or OS.get_name() != "Windows" or busy:
		checked.emit({})
		return
	busy = true
	var req := HTTPRequest.new()
	req.timeout = 15.0
	add_child(req)
	req.request_completed.connect(func(result: int, code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
		req.queue_free()
		busy = false
		if result != HTTPRequest.RESULT_SUCCESS or code != 200:
			checked.emit({})
			return
		var m = JSON.parse_string(body.get_string_from_utf8())
		if not m is Dictionary or not version_less(Release.version(), str(m.get("version", ""))):
			checked.emit({})
			return
		_manifest = m
		info = _plan(m)
		checked.emit(info))
	# Cache-buster: always ask the site for the current manifest.
	if req.request("%s?t=%d" % [Release.update_url(), Time.get_unix_time_from_system()]) != OK:
		req.queue_free()
		busy = false
		checked.emit({})


## Works out whether a small in-game patch is possible, and how big it is.
func _plan(m: Dictionary) -> Dictionary:
	var out := {"version": str(m.version), "mode": "installer", "bytes": int(m.get("setup", {}).get("bytes", 0)),
		"notes": str(m.get("notes", ""))}
	var patch: Dictionary = m.get("patch", {})
	if patch.is_empty() or not _writable():
		return out
	# The engine (Glint.exe) is too big to patch; it only changes on engine upgrades.
	if FileAccess.get_sha256(OS.get_executable_path()) != str(patch.get("exe_sha256", "")):
		return out
	_queue = []
	var total := 0
	for f in patch.get("files", []):
		var local := install_dir().path_join(str(f.name))
		if FileAccess.get_sha256(local) != str(f.sha256):
			_queue.append(f)
			total += int(f.bytes)
	out.mode = "patch"
	out.bytes = total
	return out


func _writable() -> bool:
	var probe := install_dir().path_join(".glint-write-test")
	var f := FileAccess.open(probe, FileAccess.WRITE)
	if f == null:
		return false
	f.close()
	DirAccess.remove_absolute(probe)
	return true


## Downloads the patch files next to the game as *.new.
func download() -> void:
	if info.get("mode") != "patch" or busy:
		return
	busy = true
	_done_bytes = 0
	_total_bytes = int(info.bytes)
	_next()


func _next() -> void:
	if _queue.is_empty():
		busy = false
		set_process(false)
		downloaded.emit()
		return
	_current = _queue.pop_front()
	_http = HTTPRequest.new()
	_http.download_file = install_dir().path_join(str(_current.name) + ".new")
	_http.timeout = 120.0
	add_child(_http)
	_http.request_completed.connect(_on_file_done)
	if _http.request(str(_current.url)) != OK:
		_fail("Couldn't start the download")
		return
	set_process(true)


func _process(_d: float) -> void:
	if _http != null and is_instance_valid(_http):
		progress.emit(_done_bytes + _http.get_downloaded_bytes(), _total_bytes)


func _on_file_done(result: int, code: int, _h: PackedStringArray, _b: PackedByteArray) -> void:
	var path := _http.download_file
	_http.queue_free()
	_http = null
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		DirAccess.remove_absolute(path)
		_fail("Download failed (%s). Check your connection and try again." % (code if code else result))
		return
	if FileAccess.get_sha256(path) != str(_current.sha256):
		DirAccess.remove_absolute(path)
		_fail("The download was damaged. Please try again.")
		return
	_done_bytes += int(_current.bytes)
	_next()


func _fail(msg: String) -> void:
	busy = false
	set_process(false)
	_queue.clear()
	failed.emit(msg)


## Quits and lets a small script swap the new files in, then relaunches.
func apply_and_restart() -> void:
	var dir := install_dir()
	var names := []
	for f in _manifest.get("patch", {}).get("files", []):
		names.append(str(f.name))
	var script := "\r\n".join([
		"@echo off",
		"rem Glint updater: waits for the game to close, swaps in the new files, relaunches.",
		"setlocal",
		"cd /d \"%~dp0\"",
		":wait",
		"tasklist /FI \"PID eq %1\" 2>nul | find \" %1 \" >nul && (ping -n 2 127.0.0.1 >nul & goto wait)",
		"set n=0",
		":swap",
		"set fail=0",
		"for %%F in (" + " ".join(names) + ") do if exist \"%%F.new\" (move /y \"%%F.new\" \"%%F\" >nul 2>&1 || set fail=1)",
		"if %fail%==1 if %n% lss 30 (set /a n+=1 & ping -n 2 127.0.0.1 >nul & goto swap)",
		"start \"\" \"" + OS.get_executable_path().get_file() + "\"",
		"(goto) 2>nul & del \"%~f0\"",
	]) + "\r\n"
	var f := FileAccess.open(dir.path_join(SWAP_SCRIPT), FileAccess.WRITE)
	if f == null:
		failed.emit("Couldn't write to the game folder")
		return
	f.store_string(script)
	f.close()
	Net.close()
	Net.stop_local_servers()  # its exe may be one of the files being replaced
	OS.create_process("cmd.exe", ["/c", dir.path_join(SWAP_SCRIPT), str(OS.get_process_id())])
	get_tree().quit()


## Same ordering as the server's versionLess: 0.9.0-beta.2 < 0.9.0-beta.10 < 0.9.0.
static func version_less(a: String, b: String) -> bool:
	if a == "":
		return b != ""
	var pa := _split(a)
	var pb := _split(b)
	for i in 3:
		if pa[0][i] != pb[0][i]:
			return pa[0][i] < pb[0][i]
	var ap: String = pa[1]
	var bp: String = pb[1]
	if ap == bp or ap == "":
		return false
	if bp == "":
		return true
	var aa := ap.split(".")
	var bb := bp.split(".")
	for i in mini(aa.size(), bb.size()):
		if aa[i] == bb[i]:
			continue
		if aa[i].is_valid_int() and bb[i].is_valid_int():
			return int(aa[i]) < int(bb[i])
		return aa[i] < bb[i]
	return aa.size() < bb.size()


static func _split(v: String) -> Array:
	v = v.strip_edges().trim_prefix("v")
	var pre := ""
	var i := v.find("-")
	if i >= 0:
		pre = v.substr(i + 1)
		v = v.substr(0, i)
	var n := [0, 0, 0]
	var parts := v.split(".", true, 2)
	for k in parts.size():
		n[k] = int(parts[k])
	return [n, pre]
