class_name PlayingCard
extends Control
## A standard playing card (Blackjack, Hold'em), drawn entirely with vectors:
## suits are shapes, not font glyphs, so they look the same in every browser.
## An empty rank draws the card face down.

const W := 104.0
const H := 148.0
const RED := Color("d93a56")
const BLACK := Color("1b1b2b")

var rank := ""  # "A", "2"…"10", "J", "Q", "K"; "" = face down
var suit := ""  # "S", "H", "D", "C"


static func make(card: Dictionary) -> PlayingCard:
	var c := PlayingCard.new()
	c.rank = str(card.get("rank", ""))
	c.suit = str(card.get("suit", ""))
	return c


func _init() -> void:
	custom_minimum_size = Vector2(W, H)
	size = custom_minimum_size
	pivot_offset = size * 0.5
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _draw() -> void:
	var r := Rect2(Vector2.ZERO, size)
	var shadow := StyleBoxFlat.new()
	shadow.bg_color = Color(0, 0, 0, 0)
	shadow.set_corner_radius_all(12)
	shadow.shadow_color = Color(0, 0, 0, 0.35)
	shadow.shadow_size = 10
	shadow.shadow_offset = Vector2(0, 5)
	draw_style_box(shadow, r)
	if rank == "":
		_draw_back(r)
		return
	var face := StyleBoxFlat.new()
	face.bg_color = Color("fbfbfe")
	face.set_corner_radius_all(12)
	face.border_color = Color(0, 0, 0, 0.08)
	face.set_border_width_all(1)
	draw_style_box(face, r)
	var col := RED if suit == "H" or suit == "D" else BLACK
	var font := UI.font(800)
	var fs := 22 if rank.length() < 2 else 19
	# Corner index, top-left and (rotated) bottom-right.
	draw_string(font, Vector2(9, 27), rank, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)
	_draw_suit(Vector2(18, 42), 8.5, col)
	draw_set_transform(size, PI)
	draw_string(font, Vector2(9, 27), rank, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)
	_draw_suit(Vector2(18, 42), 8.5, col)
	draw_set_transform(Vector2.ZERO)
	# Centre: a big pip, or a framed letter for face cards.
	var c := size * 0.5 + Vector2(0, 4)
	if rank == "J" or rank == "Q" or rank == "K":
		var frame := StyleBoxFlat.new()
		frame.bg_color = Color(col, 0.08)
		frame.border_color = Color(col, 0.55)
		frame.set_border_width_all(2)
		frame.set_corner_radius_all(8)
		draw_style_box(frame, Rect2(Vector2(24, 34), size - Vector2(48, 64)))
		draw_string(UI.font(900), Vector2(0, c.y + 4), rank, HORIZONTAL_ALIGNMENT_CENTER, size.x, 40, col)
		_draw_suit(c + Vector2(0, 30), 9, col)
	else:
		_draw_suit(c, 26 if rank == "A" else 21, col)


func _draw_back(r: Rect2) -> void:
	var back := StyleBoxFlat.new()
	back.bg_color = Color("3b2a8a")
	back.set_corner_radius_all(12)
	back.border_color = Color(1, 1, 1, 0.95)
	back.set_border_width_all(5)
	draw_style_box(back, r)
	var inner := Rect2(Vector2(10, 10), size - Vector2(20, 20))
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color("5a46c8")
	sb.set_corner_radius_all(7)
	draw_style_box(sb, inner)
	# The Glint gem.
	var c := size * 0.5
	var gem := PackedVector2Array([c + Vector2(0, -30), c + Vector2(20, 0), c + Vector2(0, 30), c + Vector2(-20, 0)])
	draw_colored_polygon(gem, Color(1, 1, 1, 0.9))
	var facet := PackedVector2Array([c + Vector2(0, -15), c + Vector2(10, 0), c + Vector2(0, 15), c + Vector2(-10, 0)])
	draw_colored_polygon(facet, Color(0.35, 0.27, 0.78, 0.35))


## Suit shapes centred on p, about s*2 wide.
func _draw_suit(p: Vector2, s: float, col: Color) -> void:
	match suit:
		"D":
			draw_colored_polygon(PackedVector2Array([p + Vector2(0, -s * 1.25), p + Vector2(s * 0.9, 0), p + Vector2(0, s * 1.25), p + Vector2(-s * 0.9, 0)]), col)
		"H":
			_heart(p, s, col, false)
		"S":
			_heart(p + Vector2(0, -s * 0.15), s, col, true)
			_stem(p + Vector2(0, s * 0.35), s, col)
		"C":
			var rr := s * 0.48
			draw_circle(p + Vector2(0, -s * 0.55), rr, col)
			draw_circle(p + Vector2(-s * 0.55, s * 0.12), rr, col)
			draw_circle(p + Vector2(s * 0.55, s * 0.12), rr, col)
			draw_circle(p + Vector2(0, -s * 0.05), rr * 0.6, col)
			_stem(p + Vector2(0, s * 0.3), s, col)


## A heart (or, upside down, the body of a spade).
func _heart(p: Vector2, s: float, col: Color, flip: bool) -> void:
	var k := -1.0 if flip else 1.0
	var rr := s * 0.52
	draw_circle(p + Vector2(-s * 0.48, -s * 0.28 * k), rr, col)
	draw_circle(p + Vector2(s * 0.48, -s * 0.28 * k), rr, col)
	draw_colored_polygon(PackedVector2Array([
		p + Vector2(-s * 0.98, -s * 0.12 * k), p + Vector2(s * 0.98, -s * 0.12 * k), p + Vector2(0, s * 1.0 * k)]), col)


func _stem(p: Vector2, s: float, col: Color) -> void:
	draw_colored_polygon(PackedVector2Array([p, p + Vector2(s * 0.42, s * 0.85), p + Vector2(-s * 0.42, s * 0.85)]), col)
