class_name LineLink
extends Node
## A TCP connection speaking newline-delimited JSON, with retries.
## Used by the Online autoload for the account / friends connection.

signal connected
signal disconnected(reason: String)
signal message(msg: Dictionary)

var host := ""
var port := 0
var _tcp := StreamPeerTCP.new()
var _buf := PackedByteArray()
var _state := "idle"  # idle, connecting, connected
var _retries := 0
var _started := 0.0


func is_online() -> bool:
	return _state == "connected"


func is_busy() -> bool:
	return _state != "idle"


func open(h: String, p: int, retries: int = 0) -> void:
	close()
	host = h
	port = p
	_retries = retries
	_dial()


func _dial() -> void:
	var ip := host
	if not ip.is_valid_ip_address():
		ip = IP.resolve_hostname(host, IP.TYPE_IPV4)
	if ip == "" or _tcp.connect_to_host(ip, port) != OK:
		_state = "idle"
		disconnected.emit("Couldn't reach %s:%d" % [host, port])
		return
	_state = "connecting"
	_started = Time.get_ticks_msec() / 1000.0


func close() -> void:
	if _state != "idle":
		_tcp.disconnect_from_host()
	_tcp = StreamPeerTCP.new()
	_state = "idle"
	_buf.clear()


func send(msg: Dictionary) -> void:
	if _state == "connected":
		_tcp.put_data((JSON.stringify(Net._intify(msg)) + "\n").to_utf8_buffer())


func _process(_d: float) -> void:
	if _state == "idle":
		return
	_tcp.poll()
	var st := _tcp.get_status()
	if _state == "connecting":
		if st == StreamPeerTCP.STATUS_CONNECTED:
			_state = "connected"
			_tcp.set_no_delay(true)
			connected.emit()
		elif st == StreamPeerTCP.STATUS_ERROR or st == StreamPeerTCP.STATUS_NONE \
				or Time.get_ticks_msec() / 1000.0 - _started > 4.0:
			_tcp = StreamPeerTCP.new()
			if _retries > 0:
				_retries -= 1
				_state = "idle"
				get_tree().create_timer(0.4).timeout.connect(func() -> void:
					if _state == "idle":
						_dial())
			else:
				_state = "idle"
				disconnected.emit("Couldn't reach %s:%d" % [host, port])
		return
	if st != StreamPeerTCP.STATUS_CONNECTED:
		_state = "idle"
		_buf.clear()
		disconnected.emit("Lost connection to %s" % host)
		return
	var n := _tcp.get_available_bytes()
	if n > 0:
		var res := _tcp.get_data(n)
		if res[0] == OK:
			_buf.append_array(res[1])
			while true:
				var i := _buf.find(10)
				if i < 0:
					break
				var line := _buf.slice(0, i).get_string_from_utf8()
				_buf = _buf.slice(i + 1)
				var msg = JSON.parse_string(line)
				if msg is Dictionary:
					message.emit(msg)
