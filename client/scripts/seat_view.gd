class_name SeatView
extends GlassPanel
## An opponent (or yourself) around the table: avatar with turn timer,
## name, card count, a mini fan of card backs and GLINT badges.

var player_id := ""
var avatar := Avatar.new()
var name_label := UI.label("", 17, 700)
var sub_label := UI.label("", 13, 500, UI.MUTED)
var badge := Label.new()
var mini := MiniHand.new()
var dots := Dots.new()
var _emote: Control


func _init() -> void:
	super(14, 20)
	custom_minimum_size = Vector2(220, 0)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var col := UI.vbox(8)
	var row := UI.hbox(12)
	row.add_child(avatar)
	var texts := UI.vbox(0)
	texts.alignment = BoxContainer.ALIGNMENT_CENTER
	texts.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_label.custom_minimum_size = Vector2(110, 0)
	texts.add_child(name_label)
	texts.add_child(sub_label)
	row.add_child(texts)
	row.add_child(dots)
	col.add_child(row)
	col.add_child(mini)
	add_child(col)

	badge.add_theme_font_override("font", UI.font(900))
	badge.add_theme_font_size_override("font_size", 15)
	badge.add_theme_color_override("font_color", Color("1b1b2b"))
	var bsb := UI.flat(Color("ffd24a"), 10)
	bsb.content_margin_left = 10
	bsb.content_margin_right = 10
	bsb.content_margin_top = 2
	bsb.content_margin_bottom = 2
	badge.add_theme_stylebox_override("normal", bsb)
	badge.visible = false
	badge.top_level = true  # floats over the corner, outside the container layout
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(badge)


func update(p: Dictionary, active: bool, color: Color, time_frac: float, is_me: bool = false) -> void:
	player_id = p.get("id", "")
	var nm: String = p.get("name", "?")
	avatar.letter = nm.substr(0, 1).to_upper()
	avatar.color = UI.avatar_color(nm)
	avatar.is_bot = p.get("bot", false)
	avatar.progress = time_frac if active else 0.0
	avatar.frame = p.get("frame", "")
	avatar.level = int(p.get("level", 0))
	mini.back = p.get("back", "classic")
	var tags := ""
	if p.get("host", false):
		tags += "  ♛"
	name_label.text = ("You" if is_me else nm) + tags
	var cards: int = p.get("cards", 0)
	var sub := "%d card%s · %d pts" % [cards, "" if cards == 1 else "s", p.get("score", 0)]
	if p.get("bot", false):
		sub = "%s bot · " % str(p.get("difficulty", "")).capitalize() + sub
	sub_label.text = sub
	mini.count = cards
	dots.visible = active and not is_me
	glow = Color(color, 0.85) if active else Color(0, 0, 0, 0)
	tint_alpha = 0.16 if active else 0.08

	if p.get("vulnerable", false):
		_set_badge("NO GLINT!", UI.DANGER, Color.WHITE)
	elif cards == 1:
		_set_badge("GLINT", Color("ffd24a"), Color("1b1b2b"))
	else:
		badge.visible = false


func _set_badge(text: String, bg: Color, fg: Color) -> void:
	badge.text = text
	badge.visible = true
	(badge.get_theme_stylebox("normal") as StyleBoxFlat).bg_color = bg
	badge.add_theme_color_override("font_color", fg)


func _process(_d: float) -> void:
	if badge.visible:
		badge.size = badge.get_minimum_size()
		badge.global_position = global_position + Vector2(size.x - badge.size.x - 6, -14)


func show_emote(text: String) -> void:
	if is_instance_valid(_emote):
		_emote.queue_free()
	var bubble := PanelContainer.new()
	var sb := UI.flat(Color(1, 1, 1, 0.92), 16)
	bubble.add_theme_stylebox_override("panel", sb)
	var l := UI.label(text, 17, 700, Color("1b1b2b"))
	bubble.add_child(l)
	bubble.top_level = true
	bubble.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bubble)
	_emote = bubble
	await get_tree().process_frame
	if not is_instance_valid(bubble):
		return
	bubble.global_position = global_position + Vector2(size.x * 0.5 - bubble.size.x * 0.5, -bubble.size.y - 10)
	bubble.pivot_offset = bubble.size * 0.5
	bubble.scale = Vector2(0.6, 0.6)
	var tw := bubble.create_tween()
	tw.tween_property(bubble, "scale", Vector2.ONE, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_interval(2.2)
	tw.tween_property(bubble, "modulate:a", 0.0, 0.4)
	tw.tween_callback(bubble.queue_free)


class Avatar extends Control:
	var color := Color.WHITE:
		set(v):
			color = v
			queue_redraw()
	var letter := "":
		set(v):
			letter = v
			queue_redraw()
	var is_bot := false:
		set(v):
			is_bot = v
			queue_redraw()
	var progress := 0.0:
		set(v):
			progress = v
			queue_redraw()
	var frame := "":
		set(v):
			frame = v
			queue_redraw()
	var level := 0:
		set(v):
			level = v
			queue_redraw()

	func _init(diameter: float = 52.0) -> void:
		custom_minimum_size = Vector2(diameter, diameter)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _process(_d: float) -> void:
		if frame == "rainbow":
			queue_redraw()

	func _draw() -> void:
		var d := minf(size.x, size.y) if size.x > 0 else custom_minimum_size.x
		var k := d / 52.0
		var c := Vector2(d, d) * 0.5
		draw_circle(c, 24 * k, Color(color, 0.25))
		draw_circle(c, 20 * k, color.darkened(0.15))
		var f := UI.font(800)
		var fs := int(22 * k)
		var ts := f.get_string_size(letter, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
		draw_string(f, c + Vector2(-ts.x * 0.5, (f.get_ascent(fs) - f.get_descent(fs)) * 0.5), letter,
			HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color.WHITE)
		_draw_frame(c, k)
		if is_bot:
			draw_circle(c + Vector2(16, 16) * k, 8 * k, Color("1b1b2b"))
			draw_circle(c + Vector2(16, 16) * k, 5 * k, Color("7ee8fa"))
		if level > 0:
			var lt := str(level)
			var lfs := int(11 * k) + 1
			var lw := f.get_string_size(lt, HORIZONTAL_ALIGNMENT_LEFT, -1, lfs).x + 8 * k
			var r := Rect2(c + Vector2(-17 * k - lw * 0.5, 9 * k), Vector2(lw, 15 * k))
			var sb := StyleBoxFlat.new()
			sb.set_corner_radius_all(int(8 * k))
			sb.bg_color = UI.ACCENT
			sb.border_color = Color(1, 1, 1, 0.8)
			sb.set_border_width_all(1)
			draw_style_box(sb, r)
			draw_string(f, Vector2(r.position.x + 4 * k, r.position.y + r.size.y * 0.5 + (f.get_ascent(lfs) - f.get_descent(lfs)) * 0.5),
				lt, HORIZONTAL_ALIGNMENT_LEFT, -1, lfs, Color.WHITE)
		if progress > 0.0:
			draw_arc(c, 25 * k, -PI / 2, -PI / 2 + TAU * progress, 48,
				Color.WHITE.lerp(UI.DANGER, 1.0 - progress), 3.0 * k, true)

	func _draw_frame(c: Vector2, k: float) -> void:
		var def := Cosmetics.find("frame", frame)
		match def.get("id", "none"):
			"none":
				return
			"rainbow":
				var keys := ["red", "yellow", "green", "blue"]
				var t := Time.get_ticks_msec() / 1000.0
				for i in 4:
					var a0 := t + i * TAU / 4.0
					draw_arc(c, 23.5 * k, a0, a0 + TAU / 4.0, 16, UI.CARD_COLORS[keys[i]], 3.5 * k, true)
			"crown":
				var col := Color(def.color)
				draw_arc(c, 23.5 * k, 0, TAU, 48, col, 3.5 * k, true)
				var top := c + Vector2(0, -27 * k)
				var pts := PackedVector2Array([
					top + Vector2(-11, 6) * k, top + Vector2(-11, -6) * k, top + Vector2(-5, 0) * k,
					top + Vector2(0, -9) * k, top + Vector2(5, 0) * k, top + Vector2(11, -6) * k, top + Vector2(11, 6) * k])
				draw_colored_polygon(pts, col)
			_:
				var col := Color(def.color)
				draw_arc(c, 23.5 * k, 0, TAU, 48, col, 3.5 * k, true)
				draw_arc(c, 27 * k, 0, TAU, 48, Color(col, 0.3), 2.0 * k, true)


class MiniHand extends Control:
	var count := 0:
		set(v):
			count = v
			queue_redraw()
	var back := "classic":
		set(v):
			back = v
			queue_redraw()

	func _init() -> void:
		custom_minimum_size = Vector2(0, 34)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var n := mini(count, 14)
		if n == 0:
			return
		var bd := Cosmetics.find("back", back)
		var w := 20.0
		var h := 30.0
		var step := minf(12.0, (size.x - w) / max(n - 1, 1))
		var total := step * (n - 1) + w
		var x0 := (size.x - total) * 0.5
		for i in n:
			var r := Rect2(x0 + i * step, 2, w, h)
			var sb := StyleBoxFlat.new()
			sb.set_corner_radius_all(4)
			sb.bg_color = Color(bd.bg)
			if bd.has("bg2"):
				sb.bg_color = Color(bd.bg).lerp(Color(bd.bg2), 0.5)
			sb.border_color = Color(bd.get("border", "ffffffd9"))
			sb.set_border_width_all(2)
			draw_style_box(sb, r)
			var dot: Color = Color(bd.get("oval", bd.get("outline", "ff4d6d")))
			if bd.get("rainbow", false):
				dot = UI.CARD_COLORS[["red", "yellow", "green", "blue"][i % 4]]
			draw_circle(r.get_center(), 5, dot)


class Dots extends Control:
	func _init() -> void:
		custom_minimum_size = Vector2(30, 20)
		size_flags_vertical = Control.SIZE_SHRINK_CENTER
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _process(_d: float) -> void:
		if visible:
			queue_redraw()

	func _draw() -> void:
		var t := Time.get_ticks_msec() / 1000.0
		for i in 3:
			var a := 0.3 + 0.7 * maxf(0.0, sin(t * 6.0 - i * 0.9))
			draw_circle(Vector2(5 + i * 10, 10 - a * 3.0), 3.2, Color(1, 1, 1, a))
