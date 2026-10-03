extends Node
## Autoload "Net": the game-server connection (newline-delimited JSON over
## TCP, TLS for the official server) plus launching a local server process
## for singleplayer / hosting.

signal connected
signal disconnected(reason: String)
signal message(msg: Dictionary)

const DEFAULT_PORT := 7777
const LOCAL_PORT := 7778  # private singleplayer server

var my_id := ""
var server_version := ""
var _link := LineLink.new()
var _host := ""
var _port := 0
var _server_pids := {}  # port -> pid


func _ready() -> void:
	add_child(_link)
	_link.connected.connect(func() -> void: connected.emit())
	_link.disconnected.connect(func(reason: String) -> void:
		my_id = ""
		disconnected.emit(reason))
	_link.message.connect(_on_message)


func is_online() -> bool:
	return _link.is_online()


func is_secure() -> bool:
	return _link.secure


func connected_to(host: String, port: int) -> bool:
	return _link.is_busy() and _host == host and _port == port


func connect_to(host: String, port: int, retries: int = 0) -> void:
	_host = host
	_port = port
	my_id = ""
	_link.open(host, port, retries, Release.tls_for(host, port))


func close() -> void:
	_link.close()
	my_id = ""


func send(msg: Dictionary) -> void:
	_link.send(msg)


## JSON numbers parse as floats in Godot and would be re-sent as "7.0",
## which Go rejects for int fields; send whole numbers as ints.
static func _intify(v: Variant) -> Variant:
	match typeof(v):
		TYPE_FLOAT:
			return int(v) if v == floorf(v) else v
		TYPE_DICTIONARY:
			var d := {}
			for k in v:
				d[k] = _intify(v[k])
			return d
		TYPE_ARRAY:
			var a := []
			for x in v:
				a.append(_intify(x))
			return a
	return v


func _on_message(msg: Dictionary) -> void:
	if msg.get("t") == "welcome":
		my_id = msg.get("id", "")
		server_version = msg.get("version", "")
	message.emit(msg)


# ---- local server process ----

func find_server_binary() -> String:
	var ext := ".exe" if OS.get_name() == "Windows" else ""
	for name in ["glint-server", "uno-server"]:  # uno-server: builds from before the rename
		var exe: String = name + ext
		var candidates := [
			OS.get_executable_path().get_base_dir().path_join(exe),
			ProjectSettings.globalize_path("res://bin").path_join(exe),
			ProjectSettings.globalize_path("res://").path_join("../server").path_join(exe),
		]
		for p in candidates:
			if FileAccess.file_exists(p):
				return p
	return ""


## Starts a server on this machine. lan=true listens on all interfaces so
## friends can join. Returns an error message or "".
func start_local_server(port: int, lan: bool, accounts: bool = true) -> String:
	if _server_pids.has(port) and OS.is_process_running(_server_pids[port]):
		return ""
	var path := find_server_binary()
	if path == "":
		return "Server binary not found. Build it with:  go build -o client/bin/glint-server.exe ./server"
	var addr := ("0.0.0.0:%d" if lan else "127.0.0.1:%d") % port
	var data_dir := OS.get_user_data_dir().path_join("server-data")
	var args := ["-addr", addr, "-idle-exit", "30s", "-data", data_dir, "-accounts=%s" % ("true" if accounts else "false")]
	var pid := OS.create_process(path, args)
	if pid <= 0:
		return "Couldn't start the local server"
	_server_pids[port] = pid
	return ""


func stop_local_servers() -> void:
	for pid in _server_pids.values():
		if OS.is_process_running(pid):
			OS.kill(pid)
	_server_pids.clear()


func local_ips() -> Array:
	var out := []
	for ip in IP.get_local_addresses():
		if ip.count(".") == 3 and not ip.begins_with("127.") and not ip.begins_with("169.254."):
			out.append(ip)
	return out


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		close()
		stop_local_servers()
