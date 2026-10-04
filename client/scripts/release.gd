class_name Release
extends RefCounted
## Build configuration. Release builds get res://release.cfg (written by
## release.ps1) with the version, official server, its pinned TLS certificate
## and the download page. Without it the game runs in dev mode.

const DEV_VERSION := "0.9.0-dev"
const CERT_NAME := "uno-glass-server"  # must match server/tls.go CertName

static var _cfg: ConfigFile


static func _c() -> ConfigFile:
	if _cfg == null:
		_cfg = ConfigFile.new()
		var err := _cfg.load("res://release.cfg")
		if err == OK and not _cfg.has_section("release") and FileAccess.file_exists("res://release.cfg"):
			# A byte-order mark hides the [release] section from ConfigFile.
			var text := FileAccess.get_file_as_string("res://release.cfg").trim_prefix("\ufeff")
			_cfg = ConfigFile.new()
			err = _cfg.parse(text)
		if FileAccess.file_exists("res://release.cfg") or err != ERR_FILE_NOT_FOUND:
			print("release.cfg: load %s, version %s, server %s" % [error_string(err), _cfg.get_value("release", "version", "?"), _cfg.get_value("release", "server", "?")])
	return _cfg


static func is_release() -> bool:
	return _c().has_section("release")


## Dev flags (--demo, --shot…) work in dev builds, or test builds that opt in.
static func dev_flags() -> bool:
	return not is_release() or _c().get_value("release", "dev_flags", false)


static func version() -> String:
	return _c().get_value("release", "version", DEV_VERSION)


## The official server ("host:port") players connect to by default.
static func server() -> String:
	return _c().get_value("release", "server", "127.0.0.1:7777")


## This version's release notes (Markdown), shown after an update.
static func notes() -> String:
	return _c().get_value("release", "notes", "")


static func download_url() -> String:
	return _c().get_value("release", "download_url", "https://glint.appwrite.network/download/")


## The update manifest the game checks at startup (written by tools/publish_download.sh).
static func update_url() -> String:
	return _c().get_value("release", "update_url", "https://glint.appwrite.network/release.json")


static func channel() -> String:
	return _c().get_value("release", "channel", "dev")


## TLS options for connecting to host, or null for plain TCP. Public
## addresses always use TLS with the pinned certificate of the official
## server; this PC and LAN addresses stay plain (singleplayer, LAN hosting).
static func tls_for(host: String, _port: int) -> TLSOptions:
	var pem: String = _c().get_value("release", "cert", "")
	if pem == "" or (is_local(host) and not _c().get_value("release", "force_tls", false)):
		return null
	var cert := X509Certificate.new()
	if cert.load_from_string(pem) != OK:
		push_error("release.cfg: bad certificate")
		return null
	return TLSOptions.client(cert)


## Running in a browser (the web build).
static func is_web() -> bool:
	return OS.has_feature("web")


## Where the web build connects. By default it's /ws on the site it was loaded
## from (the proxy serves both); a local test page talks to a local server.
static func ws_url() -> String:
	var url: String = _c().get_value("release", "ws_url", "")
	if url != "" or not is_web():
		return url
	var host := str(JavaScriptBridge.eval("location.host", true))
	var hostname := str(JavaScriptBridge.eval("location.hostname", true))
	if hostname == "localhost" or hostname == "127.0.0.1":
		return "ws://127.0.0.1:7780/ws"
	var secure := str(JavaScriptBridge.eval("location.protocol", true)) == "https:"
	return ("wss://" if secure else "ws://") + host + "/ws"


static func is_local(host: String) -> bool:
	host = host.to_lower()
	if host == "localhost" or host == "::1" or host.ends_with(".local") or host.ends_with(".lan"):
		return true
	for prefix in ["127.", "10.", "192.168.", "169.254."]:
		if host.begins_with(prefix):
			return true
	if host.begins_with("172."):
		var second := int(host.get_slice(".", 1))
		return second >= 16 and second <= 31
	return false
