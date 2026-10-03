class_name LoadingScreen
extends Control
## Branded boot screen. Picks up exactly where the boot splash leaves off
## (same background, card fan and wordmark), shines the logo, runs real
## warm-up steps behind a glass progress bar, then fades into the menu.

signal finished

const EMBLEM := preload("res://branding/emblem-transparent.svg")
const WORDMARK := preload("res://branding/wordmark.svg")
const MIN_TIME := 2.4

var bg := ColorRect.new()
var fan := TextureRect.new()
var word := TextureRect.new()
var bar := XPBarLite.new()
var status := UI.label("", 15, 600, Color(1, 1, 1, 0.75))
var tip := UI.label("", 14, 500, Color(1, 1, 1, 0.5))
var ver := UI.label("", 13, 600, Color(1, 1, 1, 0.4))
var _t := 0.0
var _shine: ShaderMaterial


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/background.gdshader")
	var th := Cosmetics.find("theme", Profile.selected.theme)
	mat.set_shader_parameter("base_top", Color(th.top))
	mat.set_shader_parameter("base_bottom", Color(th.bottom))
	for i in 4:
		mat.set_shader_parameter("blob%d" % (i + 1), Color(th.blobs[i]))
	bg.material = mat
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	bg.resized.connect(func() -> void: mat.set_shader_parameter("size", bg.size))

	for t in [fan, word]:
		t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		t.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(t)
	fan.texture = EMBLEM
	word.texture = WORDMARK
	_shine = ShaderMaterial.new()
	_shine.shader = load("res://shaders/shimmer.gdshader")
	word.material = _shine

	bar.custom_minimum_size = Vector2(420, 10)
	add_child(bar)
	for l in [status, tip, ver]:
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		add_child(l)
	ver.text = "v%s%s" % [Release.version(), "  ·  closed beta" if Release.channel() == "beta" else ""]
	tip.text = "💡  " + Help.random_tip()
	bar.modulate.a = 0.0
	status.modulate.a = 0.0
	tip.modulate.a = 0.0
	resized.connect(_layout)
	_layout()
	_run.call_deferred()


## Mirrors the splash.svg layout so the hand-off from the boot splash is seamless.
func _layout() -> void:
	var k := minf(size.x / 1600.0, size.y / 900.0)
	var c := size * 0.5
	var fs := 512.0 * k * 0.78
	fan.size = Vector2(fs, fs)
	fan.pivot_offset = fan.size * Vector2(0.5, 0.78)
	fan.position = Vector2(c.x - 256.0 * k * 0.78, c.y - 175.0 * k - 238.0 * k * 0.78)
	var ww := 1000.0 * k * 0.8
	word.size = Vector2(ww, ww * 0.41)
	word.pivot_offset = word.size * 0.5
	word.position = Vector2(c.x - 490.0 * k * 0.8, c.y - 5.0 * k)
	var by := word.position.y + word.size.y + 22.0 * k
	bar.size = Vector2(420, 10)
	bar.position = Vector2(c.x - 210, by)
	status.size = Vector2(size.x, 24)
	status.position = Vector2(0, by + 20)
	tip.size = Vector2(size.x, 24)
	tip.position = Vector2(0, size.y - 44)
	ver.size = Vector2(size.x - 28, 20)
	ver.position = Vector2(0, size.y - 32)
	ver.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT


func _process(delta: float) -> void:
	_t += delta
	fan.rotation = sin(_t * 1.3) * 0.03
	fan.scale = Vector2.ONE * (1.0 + sin(_t * 2.0) * 0.012)
	_shine.set_shader_parameter("sweep", fmod(_t * 0.55, 1.9) - 0.5)


func _step(text: String, frac: float) -> void:
	status.text = text
	bar.target = frac
	await get_tree().process_frame
	await get_tree().process_frame


func _run() -> void:
	var start := Time.get_ticks_msec() / 1000.0
	var tw := create_tween().set_parallel(true)
	for c in [bar, status, tip]:
		tw.tween_property(c, "modulate:a", 1.0, 0.4).set_delay(0.25)
	Audio.play("shuffle", -6.0, 0.0)

	await _step("Shuffling the deck…", 0.15)
	for w in [400, 500, 600, 650, 700, 800, 900]:
		UI.font(w).get_string_size("Glint 0123456789", HORIZONTAL_ALIGNMENT_LEFT, -1, 18)
	await _step("Polishing the glass…", 0.4)
	# Draw a glass panel and some cards once so their shaders are compiled.
	var warm := Control.new()
	warm.modulate.a = 0.01
	warm.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(warm)
	var gp := GlassPanel.new()
	gp.size = Vector2(40, 40)
	warm.add_child(gp)
	for c in ["red", "wild"]:
		warm.add_child(CardView.make({"id": -1, "color": c, "value": "wild4" if c == "wild" else "7"}))
	warm.add_child(CardView.make())
	await _step("Tuning the music…", 0.65)
	await _step("Dealing you in…", 0.85)
	warm.queue_free()

	var left := MIN_TIME - (Time.get_ticks_msec() / 1000.0 - start)
	if left > 0:
		await get_tree().create_timer(left).timeout
	await _step("Ready!", 1.0)
	await get_tree().create_timer(0.25).timeout
	finished.emit()
	var out := create_tween().set_parallel(true)
	out.tween_property(self, "modulate:a", 0.0, 0.45)
	out.tween_property(word, "scale", Vector2(1.06, 1.06), 0.45)
	out.chain().tween_callback(queue_free)


func _gui_input(e: InputEvent) -> void:
	accept_event()  # block clicks to the menu underneath


class XPBarLite extends Control:
	var value := 0.0
	var target := 0.0

	func _process(delta: float) -> void:
		value = move_toward(value, target, delta * 1.6)
		queue_redraw()

	func _draw() -> void:
		var sb := StyleBoxFlat.new()
		sb.set_corner_radius_all(int(size.y * 0.5))
		sb.bg_color = Color(1, 1, 1, 0.12)
		sb.border_color = Color(1, 1, 1, 0.25)
		sb.set_border_width_all(1)
		draw_style_box(sb, Rect2(Vector2.ZERO, size))
		if value > 0.0:
			var f := StyleBoxFlat.new()
			f.set_corner_radius_all(int(size.y * 0.5))
			f.bg_color = UI.ACCENT.lightened(0.15)
			f.shadow_color = Color(UI.ACCENT, 0.7)
			f.shadow_size = 10
			draw_style_box(f, Rect2(Vector2.ZERO, Vector2(maxf(size.y, size.x * value), size.y)))


## Four mini cards spinning like a fan — used while connecting.
class CardSpinner extends Control:
	var _t := 0.0

	func _init() -> void:
		custom_minimum_size = Vector2(96, 96)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _process(delta: float) -> void:
		_t += delta
		queue_redraw()

	func _draw() -> void:
		var c := size * 0.5
		var keys := ["red", "yellow", "green", "blue"]
		for i in 4:
			var spread := 0.35 + 0.25 * sin(_t * 3.0)
			var a := _t * 2.2 + (i - 1.5) * spread
			draw_set_transform(c + Vector2(0, 10), a)
			var sb := StyleBoxFlat.new()
			sb.set_corner_radius_all(6)
			sb.bg_color = UI.CARD_COLORS[keys[i]]
			sb.border_color = Color.WHITE
			sb.set_border_width_all(3)
			sb.anti_aliasing = true
			draw_style_box(sb, Rect2(Vector2(-16, -46), Vector2(32, 48)))
		draw_set_transform(Vector2.ZERO)
