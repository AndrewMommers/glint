extends Node
## Autoload "Audio": sound effects, UI sounds and crossfading music on
## separate Music / SFX / UI buses. Every Button in the game gets click and
## hover sounds automatically.

const SFX_NAMES := [
	"click", "hover", "card_play", "card_draw", "shuffle", "turn", "uno", "catch", "skip", "reverse",
	"plus2", "plus4", "win", "lose", "level_up", "error", "toggle", "pop", "tick", "star", "notify",
]
const UI_SOUNDS := ["click", "hover", "toggle", "pop", "notify", "error"]
const TRACKS := ["menu", "game"]

var _streams := {}
var _sfx_pool: Array[AudioStreamPlayer] = []
var _ui_pool: Array[AudioStreamPlayer] = []
var _music: Array[AudioStreamPlayer] = []
var _music_idx := 0
var _track := ""
var _last_hover := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for bus in ["Music", "SFX", "UI"]:
		if AudioServer.get_bus_index(bus) < 0:
			AudioServer.add_bus()
			var i := AudioServer.bus_count - 1
			AudioServer.set_bus_name(i, bus)
			AudioServer.set_bus_send(i, "Master")
	for n in SFX_NAMES:
		var path := "res://audio/sfx/%s.wav" % n
		if ResourceLoader.exists(path):
			_streams[n] = load(path)
	for t in TRACKS:
		var path := "res://audio/music/%s.wav" % t
		if ResourceLoader.exists(path):
			var s: AudioStream = load(path)
			if s is AudioStreamWAV:
				s.loop_mode = AudioStreamWAV.LOOP_FORWARD
				s.loop_begin = 0
				s.loop_end = int(s.get_length() * s.mix_rate)
			_streams["music_" + t] = s
	for i in 12:
		_sfx_pool.append(_player("SFX"))
	for i in 4:
		_ui_pool.append(_player("UI"))
	for i in 2:
		var m := _player("Music")
		m.volume_db = -80
		_music.append(m)
	get_tree().node_added.connect(_on_node_added)
	apply_volumes()


func _player(bus: String) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.bus = bus
	add_child(p)
	return p


func apply_volumes() -> void:
	var sv: Dictionary = Settings.values
	_set_bus("Master", float(sv.master), bool(sv.mute))
	_set_bus("Music", float(sv.music), false)
	_set_bus("SFX", float(sv.sfx), false)
	_set_bus("UI", float(sv.ui), false)


func _set_bus(bus: String, linear: float, mute: bool) -> void:
	var i := AudioServer.get_bus_index(bus)
	if i < 0:
		return
	AudioServer.set_bus_volume_db(i, linear_to_db(maxf(linear, 0.0001)))
	AudioServer.set_bus_mute(i, mute or linear <= 0.001)


## Plays a sound effect. pitch_jitter randomizes pitch slightly so repeats feel alive.
func play(name: String, volume_db: float = 0.0, pitch_jitter: float = 0.05) -> void:
	var s: AudioStream = _streams.get(name)
	if s == null:
		return
	var pool := _ui_pool if name in UI_SOUNDS else _sfx_pool
	var p: AudioStreamPlayer = null
	for cand in pool:
		if not cand.playing:
			p = cand
			break
	if p == null:
		p = pool[0]
	p.stream = s
	p.volume_db = volume_db
	p.pitch_scale = 1.0 + randf_range(-pitch_jitter, pitch_jitter)
	p.play()


## Crossfades to a music track ("menu", "game") or "" for silence.
func music(track: String, fade: float = 1.4) -> void:
	if track == _track:
		return
	_track = track
	var old := _music[_music_idx]
	_music_idx = 1 - _music_idx
	var nxt := _music[_music_idx]
	var tw := create_tween().set_parallel(true)
	tw.tween_property(old, "volume_db", -60.0, fade)
	tw.chain().tween_callback(old.stop)
	var s: AudioStream = _streams.get("music_" + track)
	if s:
		nxt.stream = s
		nxt.volume_db = -40.0
		nxt.play()
		var tw2 := create_tween()
		tw2.tween_property(nxt, "volume_db", 0.0, fade)


## Lowers the music briefly (e.g. under a win fanfare).
func duck(seconds: float = 1.5) -> void:
	var p := _music[_music_idx]
	if not p.playing:
		return
	var tw := create_tween()
	tw.tween_property(p, "volume_db", -14.0, 0.15)
	tw.tween_interval(seconds)
	tw.tween_property(p, "volume_db", 0.0, 0.8)


func _on_node_added(n: Node) -> void:
	if n is BaseButton:
		var b := n as BaseButton
		b.pressed.connect(func() -> void:
			play("toggle" if b.toggle_mode else "click", -2.0, 0.03))
		b.mouse_entered.connect(func() -> void:
			if b.disabled:
				return
			var now := Time.get_ticks_msec()
			if now - _last_hover > 45:
				_last_hover = now
				play("hover", -8.0, 0.08))
