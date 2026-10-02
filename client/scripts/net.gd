extends Node
## Autoload "Net": TCP connection to the Go server (newline-delimited JSON)
## plus launching a local server process for singleplayer / hosting.

signal connected
signal disconnected(reason: String)
signal message(msg: Dictionary)

const DEFAULT_PORT := 7777
const LOCAL_PORT := 7778  # private singleplayer server

var my_id := ""
var _tcp := StreamPeerTCP.new()
var _buf := PackedByteArray()
var _state := "idle"  # idle, connecting, connected
var _host := ""
var _port := 0
var _retries := 0
var _started_at := 0.0
var _server_pids := {}  # port -> pid


func is_online() -> bool:
	return _state == "connected"


func connect_to(host: String, port: int, retries: int = 0) -> void:
	close()
	_host = host
	_port = port
	_retries = retries
	_open()


func _open() -> void:
	var ip := _host
	if not ip.is_valid_ip_address():
		ip = IP.resolve_hostname(_host, IP.TYPE_IPV4)
	if ip == "":
		_fail("Couldn't resolve %s" % _host)
		return
	_tcp = StreamPeerTCP.new()
	var err := _tcp.connect_to_host(ip, _port)
	if err != OK:
		_fail("Couldn't connect to %s:%d" % [_host, _port])
		return
	_state = "connecting"
	_started_at = Time.get_ticks_msec() / 1000.0


func connected_to(host: String, port: int) -> bool:
	return _state != "idle" and _host == host and _port == port


func close() -> void:
	if _state != "idle":
		_tcp.disconnect_from_host()
	_state = "idle"
	_buf.clear()
	my_id = ""


func send(msg: Dictionary) -> void:
	if _state != "connected":
		return
	_tcp.put_data((JSON.stringify(_intify(msg)) + "\n").to_utf8_buffer())


## JSON numbers parse as floats in Godot and would be re-sent as "7.0",
## which Go rejects for int fields; send whole numbers as ints.
func _intify(v: Variant) -> Variant:
	match typeof(v):
		TYPE_FLOAT:
			return int(v) if v == floorf(v) else v
		TYPE_DICTIONARY:
			var d := {}
			for k in v:
				d[k] = _intify(v[k])
			return d
		TYPE_ARRAY:
			return v.map(_intify)
	return v


func _fail(reason: String) -> void:
	var was := _state
	_state = "idle"
	_buf.clear()
	if was != "idle" or reason != "":
		disconnected.emit(reason)


func _process(_delta: float) -> void:
	if _state == "idle":
		return
	_tcp.poll()
	var st := _tcp.get_status()
	match _state:
		"connecting":
			if st == StreamPeerTCP.STATUS_CONNECTED:
				_state = "connected"
				_tcp.set_no_delay(true)
				connected.emit()
			elif st == StreamPeerTCP.STATUS_ERROR or st == StreamPeerTCP.STATUS_NONE \
					or Time.get_ticks_msec() / 1000.0 - _started_at > 4.0:
				if _retries > 0:
					_retries -= 1
					_state = "idle"
					get_tree().create_timer(0.35).timeout.connect(_open)
				else:
					_fail("Couldn't reach the server at %s:%d" % [_host, _port])
		"connected":
			if st != StreamPeerTCP.STATUS_CONNECTED:
				_fail("Lost connection to the server")
				return
			var n := _tcp.get_available_bytes()
			if n > 0:
				var res := _tcp.get_data(n)
				if res[0] == OK:
					_buf.append_array(res[1])
					_drain()


func _drain() -> void:
	while true:
		var i := _buf.find(10)
		if i < 0:
			return
		var line := _buf.slice(0, i).get_string_from_utf8()
		_buf = _buf.slice(i + 1)
		var msg = JSON.parse_string(line)
		if msg is Dictionary:
			if msg.get("t") == "welcome":
				my_id = msg.get("id", "")
			message.emit(msg)


# ---- local server process ----

func find_server_binary() -> String:
	var exe := "uno-server.exe" if OS.get_name() == "Windows" else "uno-server"
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
		return "Server binary not found. Build it with:  go build -o client/bin/uno-server.exe ./server"
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
