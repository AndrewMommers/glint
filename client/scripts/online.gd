extends Node
## Autoload "Online": the player account (sign in / register / token resume),
## profile sync and friends, over its own connection to the account server.

signal status_changed
signal friends_changed
signal notice(kind: String, text: String)
signal invited(from: String, code: String)
signal outdated(msg: Dictionary)

const PATH := "user://account.cfg"

var addr := Release.server()
var username := ""
var token := ""
var status := "offline"  # offline, connecting, online (connected, not signed in), signed_in
var last_error := ""
var friends: Array = []
var incoming: Array = []
var outgoing: Array = []

var _link := LineLink.new()
var _after_connect: Callable
var _queue: Array = []  # messages to send once connected (e.g. feedback)
var _outdated := false
var _push_timer := Timer.new()
var _reconnect_timer := Timer.new()


func _ready() -> void:
	add_child(_link)
	_link.connected.connect(_on_connected)
	_link.disconnected.connect(_on_disconnected)
	_link.message.connect(_on_message)
	_push_timer.one_shot = true
	_push_timer.wait_time = 2.0
	_push_timer.timeout.connect(_push_now)
	add_child(_push_timer)
	_reconnect_timer.wait_time = 8.0
	_reconnect_timer.timeout.connect(func() -> void:
		if token != "" and status == "offline" and not _outdated:
			_open())
	add_child(_reconnect_timer)
	_reconnect_timer.start()
	Profile.changed.connect(push_profile)

	var cf := ConfigFile.new()
	if cf.load(PATH) == OK:
		addr = cf.get_value("account", "server", addr)
		username = cf.get_value("account", "username", "")
		token = cf.get_value("account", "token", "")
	if token != "" or Release.is_release():
		_open()  # release builds always check in, so outdated builds hear about it


func _save() -> void:
	var cf := ConfigFile.new()
	cf.set_value("account", "server", addr)
	cf.set_value("account", "username", username)
	cf.set_value("account", "token", token)
	cf.save(PATH)


func is_signed_in() -> bool:
	return status == "signed_in"


func host_port() -> Array:
	var host := addr if addr != "" else "127.0.0.1"
	var port := Net.DEFAULT_PORT
	var i := host.rfind(":")
	if i > 0:
		port = int(host.substr(i + 1))
		host = host.substr(0, i)
	return [host, port]


func _open() -> void:
	var hp := host_port()
	status = "connecting"
	status_changed.emit()
	_link.open(hp[0], hp[1], 2, Release.tls_for(hp[0], hp[1]))


func _set_status(s: String) -> void:
	status = s
	status_changed.emit()


# ---------------------------------------------------------------- account

## Signs in (or registers) on the given server.
func sign_in(server: String, user: String, password: String, register: bool, invite: String = "") -> void:
	var t := "register" if register else "login"
	var msg := {"t": t, "username": user.strip_edges(), "password": password, "version": Release.version()}
	if register and invite.strip_edges() != "":
		msg.invite = invite.strip_edges()
	last_error = ""
	if server != addr or not _link.is_online():
		addr = server
		_after_connect = func() -> void: _link.send(msg)
		_open()
	else:
		_link.send(msg)


func sign_out() -> void:
	_link.send({"t": "logout"})
	token = ""
	username = ""
	friends = []
	incoming = []
	outgoing = []
	_save()
	_set_status("online" if _link.is_online() else "offline")
	friends_changed.emit()


func push_profile() -> void:
	if is_signed_in():
		_push_timer.start()


func _push_now() -> void:
	if is_signed_in():
		_link.send({"t": "profile_push", "xp": Profile.xp, "level": Profile.level(), "data": Profile.to_dict()})


# ---------------------------------------------------------------- friends

func refresh_friends() -> void:
	_link.send({"t": "friends"})


func add_friend(name: String) -> void:
	_link.send({"t": "friend_add", "username": name.strip_edges()})


func accept(name: String) -> void:
	_link.send({"t": "friend_accept", "username": name})


func decline(name: String) -> void:
	_link.send({"t": "friend_decline", "username": name})


func remove_friend(name: String) -> void:
	_link.send({"t": "friend_remove", "username": name})


func invite(name: String) -> void:
	_link.send({"t": "invite", "username": name})


## Sends player feedback to the official server (signed in or not).
func send_feedback(category: String, text: String, info: Dictionary, log_text: String) -> void:
	var msg := {"t": "feedback", "category": category, "text": text, "info": info, "log": log_text}
	if _link.is_online():
		_link.send(msg)
	else:
		_queue.append(msg)
		if not _link.is_busy():
			_open()


func online_friends() -> Array:
	return friends.filter(func(f: Dictionary) -> bool: return f.get("online", false))


# ---------------------------------------------------------------- link events

func _on_connected() -> void:
	_set_status("online")
	if _after_connect.is_valid():
		var cb := _after_connect
		_after_connect = Callable()
		cb.call()
	elif token != "":
		_link.send({"t": "auth", "token": token, "version": Release.version()})
	else:
		# Anonymous hello: lets the server tell outdated builds to update.
		_link.send({"t": "hello", "name": "", "version": Release.version()})
	for m in _queue:
		_link.send(m)
	_queue.clear()


func _on_disconnected(reason: String) -> void:
	var was := status
	if _after_connect.is_valid():
		_after_connect = Callable()
		last_error = reason
		_set_status("offline")
		notice.emit("error", reason)
		return
	_set_status("offline")
	if was == "signed_in" and not _outdated:
		notice.emit("info", "Friends offline — reconnecting…")


func _on_message(m: Dictionary) -> void:
	match m.get("t"):
		"auth_ok":
			username = m.get("username", "")
			token = m.get("token", "")
			_save()
			_sync_profile(int(m.get("xp", 0)), m.get("data", null))
			_set_status("signed_in")
		"auth_error":
			last_error = m.get("msg", "")
			notice.emit("error", last_error)
			status_changed.emit()
		"auth_expired":
			token = ""
			username = ""
			_save()
			notice.emit("error", m.get("msg", "Please sign in again"))
			_set_status("online")
		"logged_out":
			_set_status("online")
		"friends":
			friends = m.get("friends", [])
			incoming = m.get("incoming", [])
			outgoing = m.get("outgoing", [])
			friends_changed.emit()
		"notice":
			notice.emit(m.get("kind", "info"), m.get("msg", ""))
		"invite":
			invited.emit(m.get("from", "?"), m.get("code", ""))
		"error":
			notice.emit("error", m.get("msg", ""))
		"outdated":
			_outdated = true  # stop reconnecting until the game is updated
			outdated.emit(m)


## Keeps whichever profile has more XP: the account's or this PC's.
func _sync_profile(server_xp: int, data: Variant) -> void:
	if data is Dictionary and server_xp > Profile.xp:
		Profile.from_dict(data)
		notice.emit("info", "Progress loaded from your account")
	else:
		_push_timer.start(0.2)
