class_name UI
extends RefCounted
## Shared look & feel: palette, fonts, theme and small widget builders.

const CARD_COLORS := {
	"red": Color("ff4d6d"),
	"yellow": Color("ffc23d"),
	"green": Color("22c983"),
	"blue": Color("3d8bff"),
	"wild": Color("1b1b2b"),
}
const ACCENT := Color("8b6cff")
const TEXT := Color(1, 1, 1, 0.95)
const MUTED := Color(1, 1, 1, 0.58)
const DANGER := Color("ff5a7a")

static var _fonts := {}


static func font(weight: int = 500) -> Font:
	if not _fonts.has(weight):
		var f := SystemFont.new()
		f.font_names = PackedStringArray(["Inter", "Segoe UI Variable Display", "Segoe UI", "SF Pro Display", "Helvetica Neue", "Roboto", "Arial"])
		f.font_weight = weight
		f.antialiasing = TextServer.FONT_ANTIALIASING_GRAY
		f.hinting = TextServer.HINTING_LIGHT
		f.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_AUTO
		_fonts[weight] = f
	return _fonts[weight]


static func flat(bg: Color, radius: int = 14, border: Color = Color(0, 0, 0, 0), bw: int = 0) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(radius)
	sb.border_color = border
	sb.set_border_width_all(bw)
	sb.content_margin_left = 18
	sb.content_margin_right = 18
	sb.content_margin_top = 10
	sb.content_margin_bottom = 10
	sb.anti_aliasing = true
	return sb


static func make_theme() -> Theme:
	var t := Theme.new()
	t.default_font = font(500)
	t.default_font_size = 18

	var rim := Color(1, 1, 1, 0.22)
	t.set_stylebox("normal", "Button", flat(Color(1, 1, 1, 0.08), 14, rim, 1))
	t.set_stylebox("hover", "Button", flat(Color(1, 1, 1, 0.16), 14, Color(1, 1, 1, 0.4), 1))
	t.set_stylebox("pressed", "Button", flat(Color(1, 1, 1, 0.24), 14, Color(1, 1, 1, 0.5), 1))
	t.set_stylebox("hover_pressed", "Button", flat(Color(1, 1, 1, 0.26), 14, Color(1, 1, 1, 0.55), 1))
	t.set_stylebox("disabled", "Button", flat(Color(1, 1, 1, 0.03), 14, Color(1, 1, 1, 0.08), 1))
	t.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	for c in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
		t.set_color(c, "Button", TEXT)
	t.set_color("font_disabled_color", "Button", Color(1, 1, 1, 0.3))
	t.set_font("font", "Button", font(600))

	var le := flat(Color(0, 0, 0, 0.22), 12, Color(1, 1, 1, 0.18), 1)
	le.content_margin_left = 14
	t.set_stylebox("normal", "LineEdit", le)
	var lef := flat(Color(0, 0, 0, 0.28), 12, ACCENT.lightened(0.2), 2)
	lef.content_margin_left = 14
	t.set_stylebox("focus", "LineEdit", lef)
	t.set_stylebox("read_only", "LineEdit", le)
	t.set_color("font_color", "LineEdit", TEXT)
	t.set_color("font_placeholder_color", "LineEdit", Color(1, 1, 1, 0.35))
	t.set_color("caret_color", "LineEdit", Color.WHITE)
	t.set_color("selection_color", "LineEdit", Color(ACCENT, 0.5))

	t.set_color("font_color", "Label", TEXT)

	var grab := flat(Color(1, 1, 1, 0.25), 4)
	grab.set_content_margin_all(0)
	var grab_hl := flat(Color(1, 1, 1, 0.4), 4)
	grab_hl.set_content_margin_all(0)
	var track := StyleBoxEmpty.new()
	t.set_stylebox("grabber", "VScrollBar", grab)
	t.set_stylebox("grabber_highlight", "VScrollBar", grab_hl)
	t.set_stylebox("grabber_pressed", "VScrollBar", grab_hl)
	t.set_stylebox("scroll", "VScrollBar", track)
	var rail := flat(Color(1, 1, 1, 0.12), 6)
	rail.content_margin_top = 4
	rail.content_margin_bottom = 4
	t.set_stylebox("slider", "HSlider", rail)
	var fill := flat(ACCENT, 6)
	fill.content_margin_top = 4
	fill.content_margin_bottom = 4
	t.set_stylebox("grabber_area", "HSlider", fill)
	t.set_stylebox("grabber_area_highlight", "HSlider", flat(ACCENT.lightened(0.15), 6))
	t.set_icon("grabber", "HSlider", _knob(Color.WHITE))
	t.set_icon("grabber_highlight", "HSlider", _knob(Color(1, 0.95, 1)))
	t.set_stylebox("panel", "TooltipPanel", flat(Color(0.08, 0.08, 0.14, 0.95), 10, rim, 1))
	t.set_color("font_color", "TooltipLabel", TEXT)
	return t


static func label(text: String, size: int = 18, weight: int = 500, color: Color = TEXT) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", font(weight))
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l


static func button(text: String, cb: Callable = Callable(), primary: bool = false, min_w: float = 0) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.custom_minimum_size = Vector2(min_w, 46)
	if primary:
		style_button(b, ACCENT)
	if cb.is_valid():
		b.pressed.connect(cb)
	return b


## Gives a button a solid accent color in all states.
static func style_button(b: Button, c: Color, radius: int = 14) -> void:
	b.add_theme_stylebox_override("normal", flat(c, radius, c.lightened(0.25), 1))
	b.add_theme_stylebox_override("hover", flat(c.lightened(0.12), radius, c.lightened(0.4), 1))
	b.add_theme_stylebox_override("pressed", flat(c.darkened(0.12), radius, c.lightened(0.3), 1))
	b.add_theme_stylebox_override("hover_pressed", flat(c.darkened(0.05), radius, c.lightened(0.3), 1))
	b.add_theme_stylebox_override("disabled", flat(Color(c, 0.25), radius, Color(1, 1, 1, 0.08), 1))


static func vbox(sep: int = 12) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", sep)
	return v


static func hbox(sep: int = 12) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", sep)
	return h


static func spacer(w: float = 0, h: float = 0, expand: bool = false) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(w, h)
	if expand:
		c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		c.size_flags_vertical = Control.SIZE_EXPAND_FILL
	return c


static func line_edit(text: String, placeholder: String, max_len: int = 32) -> LineEdit:
	var e := LineEdit.new()
	e.text = text
	e.placeholder_text = placeholder
	e.max_length = max_len
	e.custom_minimum_size = Vector2(0, 46)
	e.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return e


## A segmented control. options: Array of [label, value]. cb(value).
static func segmented(options: Array, current: Variant, cb: Callable, enabled: bool = true) -> HBoxContainer:
	var row := hbox(6)
	var group := ButtonGroup.new()
	for o in options:
		var b := button(str(o[0]))
		b.toggle_mode = true
		b.button_group = group
		b.custom_minimum_size = Vector2(0, 40)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.button_pressed = o[1] == current
		b.disabled = not enabled
		b.add_theme_stylebox_override("pressed", flat(Color(ACCENT, 0.85), 12, ACCENT.lightened(0.35), 1))
		b.add_theme_stylebox_override("hover_pressed", flat(Color(ACCENT, 0.95), 12, ACCENT.lightened(0.4), 1))
		b.add_theme_stylebox_override("disabled", flat(Color(1, 1, 1, 0.04), 12, Color(1, 1, 1, 0.1), 1))
		var value: Variant = o[1]
		b.toggled.connect(func(on: bool) -> void:
			if on:
				cb.call(value))
		row.add_child(b)
	return row


## A pill toggle with title and description. cb(bool).
static func toggle(title: String, desc: String, on: bool, cb: Callable, enabled: bool = true) -> Button:
	var b := Button.new()
	b.toggle_mode = true
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.button_pressed = on
	b.disabled = not enabled
	b.custom_minimum_size = Vector2(0, 62)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.add_theme_stylebox_override("pressed", flat(Color(ACCENT, 0.32), 14, ACCENT.lightened(0.3), 1))
	b.add_theme_stylebox_override("hover_pressed", flat(Color(ACCENT, 0.4), 14, ACCENT.lightened(0.4), 1))
	var dis := flat(Color(1, 1, 1, 0.05), 14, Color(1, 1, 1, 0.12), 1)
	b.add_theme_stylebox_override("disabled", dis)

	var row := hbox(12)
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.offset_left = 16
	row.offset_right = -16
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var texts := vbox(0)
	texts.alignment = BoxContainer.ALIGNMENT_CENTER
	texts.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	texts.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var t := label(title, 17, 650)
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var d := label(desc, 13, 400, MUTED)
	d.mouse_filter = Control.MOUSE_FILTER_IGNORE
	d.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	texts.add_child(t)
	texts.add_child(d)
	row.add_child(texts)
	var sw := Switch.new()
	sw.on = on
	row.add_child(sw)
	b.add_child(row)
	b.toggled.connect(func(v: bool) -> void:
		sw.on = v
		cb.call(v))
	return b


## A [-] value [+] stepper. cb(int).
static func stepper(value: int, lo: int, hi: int, step: int, fmt: Callable, cb: Callable, enabled: bool = true) -> HBoxContainer:
	var row := hbox(8)
	var minus := button("–")
	var plus := button("+")
	var lbl := label(fmt.call(value), 18, 650)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.custom_minimum_size = Vector2(110, 0)
	minus.custom_minimum_size = Vector2(46, 40)
	plus.custom_minimum_size = Vector2(46, 40)
	minus.disabled = not enabled
	plus.disabled = not enabled
	var state := {"v": value}
	var bump := func(d: int) -> void:
		state.v = clampi(state.v + d, lo, hi)
		lbl.text = fmt.call(state.v)
		cb.call(state.v)
	minus.pressed.connect(bump.bind(-step))
	plus.pressed.connect(bump.bind(step))
	row.add_child(minus)
	row.add_child(lbl)
	row.add_child(plus)
	return row


static func section(text: String) -> Label:
	var l := label(text.to_upper(), 12, 700, MUTED)
	l.add_theme_constant_override("line_spacing", 0)
	return l


## Deterministic avatar color from a name.
static func avatar_color(name: String) -> Color:
	var h := 0
	for ch in name.to_utf8_buffer():
		h = (h * 31 + ch) % 1000003
	return Color.from_hsv(fposmod(h * 0.6180339, 1.0), 0.55, 0.95)


class Switch extends Control:
	var on := false:
		set(v):
			on = v
			if not is_inside_tree():
				knob = 1.0 if v else 0.0
				return
			var tw := create_tween()
			tw.tween_property(self, "knob", 1.0 if v else 0.0, 0.16).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	var knob := 0.0:
		set(v):
			knob = v
			queue_redraw()

	func _init() -> void:
		custom_minimum_size = Vector2(46, 26)
		size_flags_vertical = Control.SIZE_SHRINK_CENTER
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _ready() -> void:
		knob = 1.0 if on else 0.0

	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, custom_minimum_size)
		var sb := StyleBoxFlat.new()
		sb.set_corner_radius_all(13)
		sb.bg_color = Color(1, 1, 1, 0.14).lerp(UI.ACCENT, knob)
		sb.border_color = Color(1, 1, 1, 0.25)
		sb.set_border_width_all(1)
		draw_style_box(sb, r)
		var x := lerpf(13.0, r.size.x - 13.0, knob)
		draw_circle(Vector2(x, 13), 9.5, Color.WHITE)



static func _knob(c: Color) -> ImageTexture:
	var s := 22
	var img := Image.create(s, s, false, Image.FORMAT_RGBA8)
	var r := s * 0.5
	for y in s:
		for x in s:
			var d := Vector2(x + 0.5 - r, y + 0.5 - r).length()
			var a := clampf(r - 1.5 - d, 0.0, 1.0)
			var shadow := clampf(r - d, 0.0, 1.0) * 0.35
			var col := c if a > 0 else Color(0, 0, 0, shadow)
			col.a = maxf(a, shadow)
			img.set_pixel(x, y, col)
	return ImageTexture.create_from_image(img)


## A labelled 0-100% volume slider. cb(value 0..1).
static func slider(title: String, value: float, cb: Callable) -> HBoxContainer:
	var row := hbox(14)
	var l := label(title, 16, 600)
	l.custom_minimum_size = Vector2(150, 0)
	row.add_child(l)
	var s := HSlider.new()
	s.min_value = 0
	s.max_value = 100
	s.step = 1
	s.value = value * 100
	s.focus_mode = Control.FOCUS_NONE
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	s.custom_minimum_size = Vector2(240, 22)
	row.add_child(s)
	var pct := label("%d%%" % int(value * 100), 15, 700, MUTED)
	pct.custom_minimum_size = Vector2(52, 0)
	pct.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(pct)
	s.value_changed.connect(func(v: float) -> void:
		pct.text = "%d%%" % int(v)
		cb.call(v / 100.0))
	return row
