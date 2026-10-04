class_name LineLink
extends Node
## A TCP connection speaking newline-delimited JSON, optionally over TLS,
## with connection retries. Used for both the game and account connections.

signal connected
signal disconnected(reason: String)
signal message(msg: Dictionary)

var host := ""
var port := 0
var secure := false
var _tcp := StreamPeerTCP.new()
var _tls: StreamPeerTLS
var _tls_opts: TLSOptions
var _buf := PackedByteArray()
var _state := "idle"  # idle, connecting, handshake, connected
var _retries := 0
var _started := 0.0


func is_online() -> bool:
	return _state == "connected"


func is_busy() -> bool:
	return _state != "idle"


func open(h: String, p: int, retries: int = 0, tls_opts: TLSOptions = null) -> void:
	close()
	host = h
	port = p
	_retries = retries
	_tls_opts = tls_opts
	secure = tls_opts != null
	_dial()


func _dial() -> void:
	var ip := host
	if not ip.is_valid_ip_address():
		ip = IP.resolve_hostname(host, IP.TYPE_ANY)
	_tcp = StreamPeerTCP.new()
	_tls = null
	if ip == "" or _tcp.connect_to_host(ip, port) != OK:
		_state = "idle"
		disconnected.emit("Couldn't reach %s:%d" % [host, port])
		return
	_state = "connecting"
	_started = Time.get_ticks_msec() / 1000.0


func close() -> void:
	if _tls != null:
		_tls.disconnect_from_stream()
	if _state != "idle":
		_tcp.disconnect_from_host()
	_tls = null
	_state = "idle"
	_buf.clear()


func send(msg: Dictionary) -> void:
	if _state != "connected":
		return
	var data := (JSON.stringify(Net._intify(msg)) + "\n").to_utf8_buffer()
	if _tls != null:
		_tls.put_data(data)
	else:
		_tcp.put_data(data)


func _retry_or_fail(reason: String) -> void:
	_tcp = StreamPeerTCP.new()
	_tls = null
	if _retries > 0:
		_retries -= 1
		_state = "idle"
		get_tree().create_timer(0.4).timeout.connect(func() -> void:
			if _state == "idle":
				_dial())
	else:
		_state = "idle"
		disconnected.emit(reason)


func _process(_d: float) -> void:
	if _state == "idle":
		return
	_tcp.poll()
	var elapsed := Time.get_ticks_msec() / 1000.0 - _started
	match _state:
		"connecting":
			var st := _tcp.get_status()
			if st == StreamPeerTCP.STATUS_CONNECTED:
				_tcp.set_no_delay(true)
				if _tls_opts != null:
					_tls = StreamPeerTLS.new()
					if _tls.connect_to_stream(_tcp, Release.CERT_NAME, _tls_opts) != OK:
						_retry_or_fail("Secure connection to %s failed" % host)
						return
					_state = "handshake"
				else:
					_state = "connected"
					connected.emit()
			elif st == StreamPeerTCP.STATUS_ERROR or st == StreamPeerTCP.STATUS_NONE or elapsed > 4.0:
				_retry_or_fail("Couldn't reach %s:%d" % [host, port])
			return
		"handshake":
			_tls.poll()
			var ts := _tls.get_status()
			if ts == StreamPeerTLS.STATUS_CONNECTED:
				_state = "connected"
				connected.emit()
			elif ts != StreamPeerTLS.STATUS_HANDSHAKING or elapsed > 8.0:
				_retries = 0  # a certificate problem won't fix itself
				_retry_or_fail("Secure connection to %s failed — the server's certificate doesn't match this build" % host)
			return
	# connected
	var peer: StreamPeer = _tcp
	if _tls != null:
		_tls.poll()
		if _tls.get_status() != StreamPeerTLS.STATUS_CONNECTED:
			_lost()
			return
		peer = _tls
	elif _tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		_lost()
		return
	var n := peer.get_available_bytes()
	if n <= 0:
		return
	var res := peer.get_data(n)
	if res[0] != OK:
		return
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


func _lost() -> void:
	drop("Lost connection to %s" % host)


## Closes a connection that has gone quiet and reports it as lost.
func drop(reason: String) -> void:
	if _state != "connected":
		return
	close()
	disconnected.emit(reason)
