class_name CardView
extends Control
## A single UNO card drawn entirely with vector primitives.

signal clicked(view: CardView)

const W := 104.0
const H := 156.0
const RADIUS := 13

## Card back used when back_id is empty (the local player's choice).
static var default_back := "classic"

var card: Dictionary = {}  # {id, color, value}; empty draws the back
var back_id := ""
var interactive := false
var playable := false:
	set(v):
		playable = v
		queue_redraw()
var dimmed := false:
	set(v):
		dimmed = v
		queue_redraw()
var lift := 0.0:
	set(v):
		lift = v
		queue_redraw()

## Resting lift (playable cards float up a little on your turn).
var rest := 0.0:
	set(v):
		if is_equal_approx(v, rest):
			return
		rest = v
		if _hover:
			return
		if is_inside_tree():
			create_tween().tween_property(self, "lift", v, 0.18).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		else:
			lift = v

var _hover := false


static func make(c: Dictionary = {}, back: String = "") -> CardView:
	var v := CardView.new()
	v.card = c
	v.back_id = back
	return v


func back_def() -> Dictionary:
	return Cosmetics.find("back", back_id if back_id != "" else default_back)


func _init() -> void:
	custom_minimum_size = Vector2(W, H)
	size = Vector2(W, H)
	pivot_offset = Vector2(W, H) * 0.5
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	mouse_entered.connect(_on_hover.bind(true))
	mouse_exited.connect(_on_hover.bind(false))


func set_interactive(v: bool) -> void:
	interactive = v
	mouse_filter = Control.MOUSE_FILTER_STOP if v else Control.MOUSE_FILTER_IGNORE
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if v else Control.CURSOR_ARROW
	if not v and _hover:
		_on_hover(false)


func _on_hover(on: bool) -> void:
	_hover = on and interactive
	var tw := create_tween()
	tw.tween_property(self, "lift", 34.0 if _hover and playable else (10.0 if _hover else rest), 0.14) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	z_index = 50 if _hover else 0


func _gui_input(e: InputEvent) -> void:
	if interactive and e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
		clicked.emit(self)
		accept_event()


func face_color() -> Color:
	return UI.CARD_COLORS.get(card.get("color", "wild"), UI.CARD_COLORS.wild)


func _draw() -> void:
	draw_set_transform(Vector2(0, -lift))
	var rect := Rect2(Vector2.ZERO, Vector2(W, H))

	if playable:
		var glow := StyleBoxFlat.new()
		glow.set_corner_radius_all(RADIUS + 4)
		glow.bg_color = Color(1, 1, 1, 0)
		glow.draw_center = false
		glow.border_color = Color(1, 0.97, 0.75, 0.95)
		glow.set_border_width_all(3)
		glow.shadow_color = Color(1, 0.9, 0.5, 0.45)
		glow.shadow_size = 16
		glow.expand_margin_left = 4
		glow.expand_margin_right = 4
		glow.expand_margin_top = 4
		glow.expand_margin_bottom = 4
		draw_style_box(glow, rect)

	var body := StyleBoxFlat.new()
	body.set_corner_radius_all(RADIUS)
	var bd := back_def()
	body.bg_color = face_color() if not card.is_empty() else Color(bd.bg)
	body.border_color = Color(1, 1, 1, 0.96)
	if card.is_empty() and bd.has("border"):
		body.border_color = Color(bd.border)
	body.set_border_width_all(5)
	body.shadow_color = Color(0, 0, 0, 0.38)
	body.shadow_size = 10
	body.shadow_offset = Vector2(0, 5)
	body.anti_aliasing = true
	draw_style_box(body, rect)

	var c := rect.size * 0.5
	if card.is_empty():
		_draw_back(c)
	else:
		_draw_face(c)

	# Gloss.
	draw_colored_polygon(PackedVector2Array([Vector2(9, 9), Vector2(W - 9, 9), Vector2(9, H * 0.52)]),
		Color(1, 1, 1, 0.09))

	if dimmed:
		var d := StyleBoxFlat.new()
		d.set_corner_radius_all(RADIUS)
		d.bg_color = Color(0.02, 0.02, 0.06, 0.5)
		draw_style_box(d, rect)
	draw_set_transform(Vector2.ZERO)


func _oval(c: Vector2, rx: float, ry: float, from: float = 0.0, to: float = TAU, n: int = 48) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in n + 1:
		var a := lerpf(from, to, float(i) / n)
		pts.append(c + Vector2(cos(a) * rx, sin(a) * ry).rotated(-0.42))
	return pts


func _draw_back(c: Vector2) -> void:
	var bd := back_def()
	var inner := Rect2(Vector2(5, 5), Vector2(W - 10, H - 10))
	if bd.has("bg2"):
		# Diagonal gradient between bg and bg2.
		var a := Color(bd.bg)
		var b := Color(bd.bg2)
		var pts := PackedVector2Array([inner.position, Vector2(inner.end.x, inner.position.y), inner.end, Vector2(inner.position.x, inner.end.y)])
		var poly := _inset(pts)
		var cols := PackedColorArray()
		for p in poly:
			cols.append(a.lerp(b, clampf((p.x + p.y) / (W + H), 0.0, 1.0)))
		draw_polygon(poly, cols)
	if bd.get("stars", false):
		var rng := RandomNumberGenerator.new()
		rng.seed = 7
		for i in 26:
			draw_circle(inner.position + Vector2(rng.randf() * inner.size.x, rng.randf() * inner.size.y),
				rng.randf_range(0.6, 1.8), Color(1, 1, 1, rng.randf_range(0.35, 0.9)))
	if bd.get("rainbow", false):
		var keys := ["red", "yellow", "green", "blue"]
		for i in 4:
			var pts := _oval(c, 38, 62, i * PI * 0.5, (i + 1) * PI * 0.5, 14)
			pts.insert(0, c)
			draw_colored_polygon(pts, UI.CARD_COLORS[keys[i]])
		draw_colored_polygon(_oval(c, 24, 42), Color(bd.bg))
	elif bd.has("oval"):
		draw_colored_polygon(_oval(c, 36, 60), Color(bd.oval))
	if bd.has("outline"):
		var o := _oval(c, 36, 60)
		draw_polyline(o, Color(bd.outline), 3.0, true)
		draw_polyline(o, Color(Color(bd.outline), 0.25), 9.0, true)
	_text_centered("UNO", c, 30, Color(bd.text), 900, -0.42, 7)


## Pulls the four corners inward so a gradient fits inside the rounded border.
func _inset(pts: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	var steps := 6
	var r := float(RADIUS - 5)
	var corners := [[pts[0], Vector2(r, r), PI], [pts[1], Vector2(-r, r), PI * 1.5], [pts[2], Vector2(-r, -r), 0.0], [pts[3], Vector2(r, -r), PI * 0.5]]
	for cr in corners:
		var center: Vector2 = cr[0] + cr[1]
		for k in steps + 1:
			var a: float = cr[2] + PI * 0.5 * k / steps
			out.append(center + Vector2(cos(a), sin(a)) * r)
	return out


func _draw_face(c: Vector2) -> void:
	var col := face_color()
	var value: String = card.get("value", "")
	var is_wild := value == "wild" or value == "wild4"

	if is_wild:
		var keys := ["red", "yellow", "green", "blue"]
		for i in 4:
			var pts := _oval(c, 34, 57, i * PI * 0.5, (i + 1) * PI * 0.5, 14)
			pts.insert(0, c)
			draw_colored_polygon(pts, UI.CARD_COLORS[keys[i]])
	else:
		draw_colored_polygon(_oval(c, 34, 57), Color.WHITE)

	var big := _label_for(value)
	match value:
		"skip", "reverse":
			_draw_symbol(value, c, 1.0, col)
		"wild":
			pass
		"wild4":
			_text_centered(big, c, 40, Color.WHITE, 900, 0.0, 8)
		_:
			_text_centered(big, c, 56 if big.length() == 1 else 42, col, 900, 0.0, 6, Color(0, 0, 0, 0.18))

	# Corner indices.
	for corner in [[Vector2(20, 24), 0.0], [Vector2(W - 20, H - 24), PI]]:
		draw_set_transform(corner[0] + Vector2(0, -lift), corner[1])
		if value == "skip" or value == "reverse":
			_draw_symbol(value, Vector2.ZERO, 0.42, Color.WHITE)
		else:
			_text_centered(big if value != "wild" else "W", Vector2.ZERO, 20, Color.WHITE, 800, 0.0, 4)
	draw_set_transform(Vector2(0, -lift))


func _label_for(value: String) -> String:
	match value:
		"draw2":
			return "+2"
		"wild4":
			return "+4"
		"wild":
			return "W"
	return value


func _draw_symbol(kind: String, c: Vector2, s: float, col: Color) -> void:
	var w := 7.0 * s + 1.0
	match kind:
		"skip":
			draw_arc(c, 21 * s, 0, TAU, 40, col, w, true)
			draw_line(c + Vector2(-14, 14) * s, c + Vector2(14, -14) * s, col, w, true)
		"reverse":
			for dir: float in [1.0, -1.0]:
				var a: Vector2 = c + Vector2(-12, 14) * s * dir
				var b: Vector2 = c + Vector2(10, -10) * s * dir
				var off: Vector2 = Vector2(6, 6) * s * dir
				draw_line(a + off, b + off, col, w, true)
				var tip: Vector2 = b + off + Vector2(6, -6) * s * dir
				var head := PackedVector2Array([tip, tip + Vector2(-14, 2) * s * dir, tip + Vector2(-2, 14) * s * dir])
				draw_colored_polygon(head, col)


func _text_centered(text: String, c: Vector2, sz: int, col: Color, weight: int, rot: float = 0.0,
		outline: int = 0, outline_col: Color = Color(0, 0, 0, 0.45)) -> void:
	var f := UI.font(weight)
	var ts := f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, sz)
	var asc := f.get_ascent(sz)
	var desc := f.get_descent(sz)
	var origin := Vector2(-ts.x * 0.5, (asc - desc) * 0.5)
	if rot != 0.0:
		draw_set_transform(c + Vector2(0, -lift), rot)
		c = Vector2.ZERO
	if outline > 0:
		draw_string_outline(f, c + origin, text, HORIZONTAL_ALIGNMENT_LEFT, -1, sz, outline, outline_col)
	draw_string(f, c + origin, text, HORIZONTAL_ALIGNMENT_LEFT, -1, sz, col)
	if rot != 0.0:
		draw_set_transform(Vector2(0, -lift))
