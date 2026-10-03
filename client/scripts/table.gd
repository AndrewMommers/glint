class_name Table
extends Control
## The in-game view. It is a pure function of the latest server state plus
## animations derived from the events attached to each state.

signal leave_requested
signal options_requested

## Optional: func(st, body: VBoxContainer, buttons: HBoxContainer) to extend
## the end-of-round panel (XP, campaign progress, …).
var results_hook: Callable

const COLOR_ORDER := ["red", "yellow", "green", "blue", "wild"]
const VALUE_ORDER := ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "skip", "reverse", "draw2", "wild", "wild4"]
const EMOTES := ["GG", "Nice!", "Oops", "Hurry up!", "Wow", "Haha", "Good luck", "GLINT? ✨"]

var st: Dictionary = {}
var me := ""
var time_left := 0.0

var seats := {}  # player id -> SeatView
var hand_views := {}  # card id -> CardView
var discard_views: Array = []
var _top_id := -1
var _results_key := ""  # "code/match/round" whose end-of-round menu was shown
## Set by main: singleplayer tables keep "Play again"; private multiplayer
## lobbies get "Continue / Leave".
var singleplayer := false

var seats_root := Control.new()
var piles := Control.new()
var ring := DirectionRing.new()
var draw_pile := Control.new()
var draw_badge := Label.new()
var discard_root := Control.new()
var hand_layer := Control.new()
var fx := Control.new()
var banner := Label.new()
var modal_layer := Control.new()

var my_panel: SeatView
var turn_label := UI.label("", 15, 700)
var log_box := UI.vbox(4)
var btn_draw: Button
var btn_pass: Button
var btn_uno: Button
var btn_catch: Button
var info_label := UI.label("", 15, 500, UI.MUTED)
var code_label := UI.label("", 15, 800)
var emote_row: HBoxContainer
var hand_tray := GlassPanel.new(0, 30)
var dock := GlassPanel.new(14, 22)
var activity := GlassPanel.new(16, 20)
var color_chip := ColorChip.new()
var turn_pill := Label.new()
var _prev_turn := ""
var hint_pill := Label.new()
var _hint_text := ""
var _last_tick := -1


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	for c in [seats_root, piles, hand_layer, fx, modal_layer]:
		c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(seats_root)
	add_child(piles)
	_build_piles()
	_build_hud()
	hand_tray.tint_alpha = 0.05
	hand_tray.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(hand_tray)
	add_child(hand_layer)
	_build_turn_pill()
	_build_hint_pill()
	add_child(fx)
	_build_banner()
	add_child(modal_layer)
	resized.connect(_layout)


# ---------------------------------------------------------------- building

func _build_piles() -> void:
	piles.add_child(ring)
	draw_pile.custom_minimum_size = Vector2(CardView.W, CardView.H)
	draw_pile.size = draw_pile.custom_minimum_size
	draw_pile.mouse_filter = Control.MOUSE_FILTER_STOP
	draw_pile.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	draw_pile.tooltip_text = "Draw a card (D)"
	for i in 4:
		var back := CardView.make()
		back.position = Vector2(-i * 2.5, -i * 3.0)
		draw_pile.add_child(back)
	draw_pile.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			_do_draw())
	draw_pile.mouse_entered.connect(func() -> void:
		create_tween().tween_property(draw_pile, "scale", Vector2(1.05, 1.05), 0.12))
	draw_pile.mouse_exited.connect(func() -> void:
		create_tween().tween_property(draw_pile, "scale", Vector2.ONE, 0.12))
	draw_pile.pivot_offset = draw_pile.size * 0.5
	piles.add_child(draw_pile)

	draw_badge.add_theme_font_override("font", UI.font(800))
	draw_badge.add_theme_font_size_override("font_size", 14)
	draw_badge.add_theme_stylebox_override("normal", _pill(Color(0, 0, 0, 0.45)))
	draw_badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	piles.add_child(draw_badge)

	discard_root.custom_minimum_size = Vector2(CardView.W, CardView.H)
	discard_root.size = discard_root.custom_minimum_size
	discard_root.pivot_offset = discard_root.size * 0.5
	discard_root.scale = Vector2(1.1, 1.1)
	discard_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	piles.add_child(discard_root)
	piles.add_child(color_chip)


func _pill(c: Color) -> StyleBoxFlat:
	var sb := UI.flat(c, 12)
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 4
	sb.content_margin_bottom = 4
	return sb


func _build_hud() -> void:
	# Top bar.
	var top := GlassPanel.new(12, 18)
	top.set_margins(18, 10)
	top.set_anchors_preset(Control.PRESET_TOP_WIDE)
	top.offset_left = 20
	top.offset_right = -20
	top.offset_top = 16
	var row := UI.hbox(16)
	var emb := TextureRect.new()
	emb.texture = preload("res://branding/emblem.svg")
	emb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	emb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	emb.custom_minimum_size = Vector2(36, 36)
	row.add_child(emb)
	var wm := TextureRect.new()
	wm.texture = preload("res://branding/wordmark.svg")
	wm.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	wm.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	wm.custom_minimum_size = Vector2(92, 38)
	row.add_child(wm)
	var code_chip := Button.new()
	code_chip.focus_mode = Control.FOCUS_NONE
	code_chip.tooltip_text = "Copy room code"
	code_chip.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	code_chip.add_theme_stylebox_override("normal", _pill(Color(1, 1, 1, 0.1)))
	code_chip.add_theme_stylebox_override("hover", _pill(Color(1, 1, 1, 0.2)))
	code_chip.add_theme_stylebox_override("pressed", _pill(Color(1, 1, 1, 0.25)))
	code_chip.add_child(code_label)
	code_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	code_chip.custom_minimum_size = Vector2(120, 34)
	code_chip.pressed.connect(func() -> void:
		DisplayServer.clipboard_set(st.get("code", ""))
		toast("Room code copied"))
	code_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	code_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	row.add_child(code_chip)
	info_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	info_label.size_flags_vertical = Control.SIZE_FILL
	row.add_child(info_label)
	var emote_btn := UI.button("💬", func() -> void: emote_row.visible = not emote_row.visible)
	emote_btn.tooltip_text = "Reactions"
	emote_btn.custom_minimum_size = Vector2(46, 40)
	row.add_child(emote_btn)
	var opt_btn := UI.button("⚙", func() -> void: options_requested.emit())
	opt_btn.tooltip_text = "Options (Esc)"
	opt_btn.custom_minimum_size = Vector2(46, 40)
	row.add_child(opt_btn)
	var rules_btn := UI.button("Rules", _show_rules)
	rules_btn.custom_minimum_size = Vector2(0, 40)
	row.add_child(rules_btn)
	var scores_btn := UI.button("Scores", _show_scores)
	scores_btn.custom_minimum_size = Vector2(0, 40)
	row.add_child(scores_btn)
	var leave_btn := UI.button("Leave", func() -> void: leave_requested.emit())
	leave_btn.custom_minimum_size = Vector2(0, 40)
	row.add_child(leave_btn)
	top.add_child(row)
	add_child(top)

	emote_row = UI.hbox(6)
	emote_row.visible = false
	emote_row.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	emote_row.position = Vector2(0, 0)
	for e in EMOTES:
		var b := UI.button(e, func() -> void:
			Net.send({"t": "emote", "text": e})
			emote_row.visible = false)
		b.custom_minimum_size = Vector2(0, 38)
		emote_row.add_child(b)
	add_child(emote_row)

	# My panel (bottom-left).
	my_panel = SeatView.new()
	my_panel.custom_minimum_size = Vector2(260, 0)
	add_child(my_panel)
	turn_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(turn_label)

	# Event log.
	log_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	log_box.alignment = BoxContainer.ALIGNMENT_END
	log_box.custom_minimum_size = Vector2(270, 168)
	var act := UI.vbox(8)
	act.add_child(UI.section("Activity"))
	act.add_child(log_box)
	activity.add_child(act)
	activity.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(activity)

	# Action buttons (bottom-right).
	var actions := UI.vbox(10)
	btn_uno = UI.button("GLINT!", func() -> void: Net.send({"t": "uno"}), false, 200)
	UI.style_button(btn_uno, Color("ffb020"), 18)
	btn_uno.add_theme_font_override("font", UI.font(900))
	btn_uno.add_theme_font_size_override("font_size", 26)
	btn_uno.add_theme_color_override("font_color", Color("1b1b2b"))
	btn_uno.add_theme_color_override("font_hover_color", Color("1b1b2b"))
	btn_uno.add_theme_color_override("font_pressed_color", Color("1b1b2b"))
	btn_uno.custom_minimum_size = Vector2(200, 64)
	btn_uno.pivot_offset = Vector2(100, 32)
	btn_uno.tooltip_text = "Call GLINT (G)"
	btn_catch = UI.button("CATCH! +2", func() -> void: Net.send({"t": "catch"}), false, 200)
	UI.style_button(btn_catch, UI.DANGER, 16)
	btn_catch.add_theme_font_override("font", UI.font(800))
	btn_catch.tooltip_text = "Someone forgot to call GLINT! (C)"
	btn_pass = UI.button("Keep & Pass", func() -> void: Net.send({"t": "pass"}), false, 200)
	btn_pass.tooltip_text = "Keep the drawn card (P)"
	btn_draw = UI.button("Draw", _do_draw, true, 200)
	btn_draw.tooltip_text = "Draw a card (D)"
	for pair in [[btn_catch, "C"], [btn_uno, "G"], [btn_pass, "P"], [btn_draw, "D"]]:
		_key_hint(pair[0], pair[1])
		actions.add_child(pair[0])
	dock.name = "Actions"
	dock.add_child(actions)
	add_child(dock)


func _key_hint(b: Button, key: String) -> void:
	if not Settings.v("key_hints"):
		return
	var k := UI.label(key, 12, 800, Color(1, 1, 1, 0.75))
	k.add_theme_stylebox_override("normal", _pill(Color(0, 0, 0, 0.28)))
	k.mouse_filter = Control.MOUSE_FILTER_IGNORE
	k.set_anchors_and_offsets_preset(Control.PRESET_CENTER_RIGHT)
	k.offset_left = -40
	k.offset_right = -10
	k.offset_top = -12
	k.offset_bottom = 12
	k.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	b.add_child(k)


func _build_hint_pill() -> void:
	hint_pill.add_theme_font_override("font", UI.font(600))
	hint_pill.add_theme_font_size_override("font_size", 15)
	var sb := UI.flat(Color(0.06, 0.06, 0.12, 0.72), 14, Color(1, 1, 1, 0.22), 1)
	sb.content_margin_left = 16
	sb.content_margin_right = 16
	sb.content_margin_top = 7
	sb.content_margin_bottom = 7
	hint_pill.add_theme_stylebox_override("normal", sb)
	hint_pill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hint_pill.modulate.a = 0.0
	add_child(hint_pill)


func _update_hint() -> void:
	var text := ""
	if Profile.prefs.get("hints", true):
		var playable := []
		for id in st.get("playable", []):
			playable.append(int(id))
		text = Help.hint_for(st, me, playable, st.get("hand", []))
	if text == _hint_text:
		return
	_hint_text = text
	var tw := hint_pill.create_tween()
	tw.tween_property(hint_pill, "modulate:a", 0.0, 0.12)
	if text != "":
		tw.tween_callback(func() -> void:
			hint_pill.text = "💡  " + text
			hint_pill.reset_size()
			hint_pill.position = Vector2(size.x * 0.5 - hint_pill.size.x * 0.5, size.y - CardView.H - 136))
		tw.tween_property(hint_pill, "modulate:a", 1.0, 0.2)


func _show_rules() -> void:
	var s: Dictionary = st.get("settings", {})
	var body := UI.vbox(16)
	var target := int(s.get("targetScore", 0))
	var tt := int(s.get("turnTime", 0))
	var line := "%d starting cards  ·  %s  ·  %s" % [int(s.get("rules", {}).get("handSize", 7)),
		"first to %d points" % target if target > 0 else "single round", "%ds turns" % tt if tt > 0 else "no turn timer"]
	var l := UI.label(line, 16, 600, UI.ACCENT.lightened(0.45))
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	body.add_child(l)
	var hr := Help.house_rules(s.get("rules", {}))
	hr.custom_minimum_size = Vector2(640, 0)
	body.add_child(hr)
	body.add_child(UI.section("Controls"))
	body.add_child(Help.controls())
	_modal("Table rules", body)


func _build_turn_pill() -> void:
	turn_pill.text = "YOUR TURN"
	turn_pill.add_theme_font_override("font", UI.font(900))
	turn_pill.add_theme_font_size_override("font_size", 16)
	turn_pill.add_theme_color_override("font_color", Color("1b1b2b"))
	var sb := _pill(Color("ffd24a"))
	sb.content_margin_left = 18
	sb.content_margin_right = 18
	sb.shadow_color = Color(1, 0.82, 0.29, 0.45)
	sb.shadow_size = 14
	turn_pill.add_theme_stylebox_override("normal", sb)
	turn_pill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	turn_pill.visible = false
	add_child(turn_pill)


func _build_banner() -> void:
	banner.add_theme_font_override("font", UI.font(900))
	banner.add_theme_font_size_override("font_size", 64)
	banner.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.35))
	banner.add_theme_constant_override("outline_size", 14)
	banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	banner.modulate.a = 0.0
	add_child(banner)


# ---------------------------------------------------------------- layout

func _center() -> Vector2:
	return Vector2(size.x * 0.5, size.y * 0.47)


func _seat_pos(i: int, n: int) -> Vector2:
	var a := -PI * 0.5
	if n > 1:
		a = lerpf(PI * 1.06, PI * 1.94, float(i) / (n - 1))
	var c := _center()
	return c + Vector2(cos(a) * size.x * 0.40, sin(a) * size.y * 0.31)


func _layout() -> void:
	var c := _center()
	draw_pile.position = c + Vector2(-CardView.W - 34, -CardView.H * 0.5)
	discard_root.position = c + Vector2(34, -CardView.H * 0.5)
	ring.position = c
	draw_badge.position = draw_pile.position + Vector2(CardView.W * 0.5 - draw_badge.size.x * 0.5, CardView.H + 12)
	color_chip.position = discard_root.position + Vector2(CardView.W * 0.5 - color_chip.size.x * 0.5, CardView.H + 18)
	banner.size = Vector2(size.x, 90)
	banner.position = Vector2(0, c.y - CardView.H * 0.5 - 120)

	var others := _others()
	for i in others.size():
		var sv: SeatView = seats.get(others[i].id)
		if sv:
			sv.reset_size()
			var target := _seat_pos(i, others.size()) - sv.size * 0.5
			target.y = maxf(target.y, 96)
			sv.position = target

	my_panel.reset_size()
	my_panel.position = Vector2(24, size.y - my_panel.size.y - 24)
	turn_label.size = Vector2(my_panel.size.x, 24)
	turn_label.position = my_panel.position + Vector2(0, -34)
	activity.reset_size()
	activity.position = Vector2(24, turn_label.position.y - activity.size.y - 14)
	dock.reset_size()
	dock.position = Vector2(size.x - dock.size.x - 24, size.y - dock.size.y - 24)
	emote_row.reset_size()
	emote_row.position = Vector2(size.x - emote_row.size.x - 24, 96)
	_layout_hand(true)


func _layout_hand(animate: bool) -> void:
	var ids := _sorted_hand_ids()
	var n := ids.size()
	if n == 0:
		return
	var avail := size.x * 0.5
	var spacing := minf(82.0, avail / maxf(n - 1, 1))
	var total := spacing * (n - 1)
	var spread := minf(0.5, n * 0.045)
	var tray_w := total + CardView.W + 70
	var tray_rect := Rect2(Vector2(size.x * 0.5 - tray_w * 0.5, size.y - 128), Vector2(tray_w, 150))
	if animate and hand_tray.size.x > 1:
		var ttw := hand_tray.create_tween().set_parallel(true)
		ttw.tween_property(hand_tray, "position", tray_rect.position, 0.3).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		ttw.tween_property(hand_tray, "size", tray_rect.size, 0.3).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	else:
		hand_tray.position = tray_rect.position
		hand_tray.size = tray_rect.size
	turn_pill.reset_size()
	turn_pill.pivot_offset = turn_pill.size * 0.5
	turn_pill.position = Vector2(size.x * 0.5 - turn_pill.size.x * 0.5, size.y - CardView.H - 92)
	for i in n:
		var v: CardView = hand_views[ids[i]]
		var t := 0.0 if n == 1 else float(i) / (n - 1) - 0.5
		var pos := Vector2(size.x * 0.5 - total * 0.5 + i * spacing - CardView.W * 0.5,
			size.y - CardView.H - 30 + t * t * 70.0)
		var rot := t * spread
		hand_layer.move_child(v, i)
		if animate:
			var tw := v.create_tween().set_parallel(true)
			tw.tween_property(v, "position", pos, 0.32).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
			tw.tween_property(v, "rotation", rot, 0.32).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
			tw.tween_property(v, "scale", Vector2.ONE, 0.32)
		else:
			v.position = pos
			v.rotation = rot


func _sorted_hand_ids() -> Array:
	var cards: Array = st.get("hand", []).duplicate()
	cards.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ca := COLOR_ORDER.find(a.color)
		var cb := COLOR_ORDER.find(b.color)
		if ca != cb:
			return ca < cb
		return VALUE_ORDER.find(a.value) < VALUE_ORDER.find(b.value))
	return cards.map(func(c: Dictionary) -> int: return int(c.id))


# ---------------------------------------------------------------- state

func _players() -> Array:
	return st.get("players", [])


func _others() -> Array:
	var ps := _players()
	var idx := -1
	for i in ps.size():
		if ps[i].id == me:
			idx = i
	var out := []
	for k in range(1, ps.size()):
		out.append(ps[(idx + k) % ps.size()])
	return out


func _player(id: String) -> Dictionary:
	for p in _players():
		if p.id == id:
			return p
	return {}


func _name(id: String) -> String:
	if id == me:
		return "You"
	return _player(id).get("name", "?")


func is_my_turn() -> bool:
	return st.get("phase") == "playing" and st.get("turn") == me


func apply_state(s: Dictionary) -> void:
	var first := st.is_empty()
	st = s
	me = s.get("you", "")
	time_left = s.get("timeLeft", 0.0)
	# A match restarts at round 1, so the match number is part of the key.
	var round_key := "%s/%d/%d" % [s.get("code", ""), int(s.get("match", 0)), int(s.get("round", 0))]
	if s.get("phase") == "playing" and _results_key != "" and round_key != _results_key:
		_close_modal()
		_results_key = ""
	if first or round_key != _last_round:
		_reset_round()
	_last_round = round_key

	_sync_seats()
	_process_events(s.get("events", []))
	_sync_hand()
	_sync_piles()
	_sync_controls()
	_layout()

	if s.get("phase") in ["roundover", "gameover"] and _results_key != round_key:
		_results_key = round_key
		get_tree().create_timer(1.3).timeout.connect(_show_results)


var _last_round := ""


func _reset_round() -> void:
	Audio.play("shuffle")
	for v in hand_views.values():
		v.queue_free()
	hand_views.clear()
	for v in discard_views:
		v.queue_free()
	discard_views.clear()
	_top_id = -1
	for c in log_box.get_children():
		c.queue_free()


func _sync_seats() -> void:
	var others := _others()
	var want := {}
	for p in others:
		want[p.id] = true
	for id in seats.keys():
		if not want.has(id):
			seats[id].queue_free()
			seats.erase(id)
	var col: Color = UI.CARD_COLORS.get(st.get("color", "wild"), UI.ACCENT)
	if st.get("color", "") == "" or st.get("color") == "wild":
		col = UI.ACCENT
	var frac := _time_frac()
	for p in others:
		var sv: SeatView = seats.get(p.id)
		if sv == null:
			sv = SeatView.new()
			seats[p.id] = sv
			seats_root.add_child(sv)
		sv.update(p, st.get("turn") == p.id and st.get("phase") == "playing", col, frac)
	my_panel.update(_player(me), is_my_turn(), col, frac, true)
	ring.set_color(col)
	ring.dir = st.get("dir", 1)


func _time_frac() -> float:
	var tt: int = st.get("settings", {}).get("turnTime", 0)
	if tt <= 0 or time_left <= 0.0:
		return 0.0
	return clampf(time_left / tt, 0.0, 1.0)


func _sync_hand() -> void:
	var cards := {}
	for c in st.get("hand", []):
		cards[int(c.id)] = c
	for id in hand_views.keys():
		if not cards.has(id):
			hand_views[id].queue_free()
			hand_views.erase(id)
	var spawn := hand_layer.get_global_transform().affine_inverse() * (draw_pile.global_position)
	var playable := {}
	for id in st.get("playable", []):
		playable[int(id)] = true
	var my_turn := is_my_turn()
	for id in cards:
		var v: CardView = hand_views.get(id)
		if v == null:
			v = CardView.make(cards[id])
			v.position = spawn
			v.scale = Vector2(0.8, 0.8)
			v.clicked.connect(_on_card_clicked)
			hand_layer.add_child(v)
			hand_views[id] = v
		v.playable = playable.has(id)
		v.dimmed = my_turn and not playable.has(id)
		v.rest = 14.0 if playable.has(id) else 0.0
		v.set_interactive(playable.has(id))


func _sync_piles() -> void:
	var top: Dictionary = st.get("top", {})
	if top.is_empty():
		return
	if int(top.id) != _top_id:
		_top_id = int(top.id)
		_push_discard(CardView.make(top))
	var pending: int = st.get("pending", 0)
	if pending > 0:
		draw_badge.text = "Take +%d" % pending
		(draw_badge.get_theme_stylebox("normal") as StyleBoxFlat).bg_color = Color(UI.DANGER, 0.85)
	else:
		draw_badge.text = "%d left" % st.get("drawPile", 0)
		(draw_badge.get_theme_stylebox("normal") as StyleBoxFlat).bg_color = Color(0, 0, 0, 0.45)
	draw_badge.reset_size()


func _push_discard(v: CardView) -> void:
	if v.get_parent():
		v.reparent(discard_root, true)
	else:
		discard_root.add_child(v)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(v.card.get("id", 0))
	var tw := v.create_tween().set_parallel(true)
	tw.tween_property(v, "position", Vector2(rng.randf_range(-6, 6), rng.randf_range(-6, 6)), 0.2)
	tw.tween_property(v, "rotation", rng.randf_range(-0.22, 0.22), 0.2)
	tw.tween_property(v, "scale", Vector2.ONE, 0.2)
	v.set_interactive(false)
	v.playable = false
	v.dimmed = false
	discard_views.append(v)
	while discard_views.size() > 5:
		discard_views.pop_front().queue_free()


func _sync_controls() -> void:
	var my_turn := is_my_turn()
	var drawn: int = st.get("drawn", -1)
	var rules: Dictionary = st.get("settings", {}).get("rules", {})
	var pending: int = st.get("pending", 0)
	btn_draw.visible = my_turn and drawn < 0
	btn_draw.text = "Take +%d" % pending if pending > 0 else "Draw"
	btn_pass.visible = my_turn and drawn >= 0 and not rules.get("forcePlay", false)
	btn_uno.visible = st.get("canUno", false)
	btn_catch.visible = st.get("canCatch", false)
	activity.visible = log_box.get_child_count() > 0
	dock.visible = btn_draw.visible or btn_pass.visible or btn_uno.visible or btn_catch.visible
	var col: Color = UI.CARD_COLORS.get(st.get("color", ""), Color.WHITE)
	color_chip.set_color(st.get("color", ""), col)
	turn_pill.visible = my_turn
	if my_turn and _prev_turn != me:
		Audio.play("turn", -3.0, 0.0)
		turn_pill.scale = Vector2(0.6, 0.6)
		turn_pill.create_tween().tween_property(turn_pill, "scale", Vector2.ONE, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_prev_turn = st.get("turn", "")
	_update_hint()
	if btn_uno.visible:
		_pulse(btn_uno)

	code_label.text = "ROOM  " + st.get("code", "")
	var parts := ["Round %d" % st.get("round", 0)]
	var target: int = st.get("settings", {}).get("targetScore", 0)
	parts.append("First to %d" % target if target > 0 else "Single round")
	var names := {"stacking": "Stacking", "drawToMatch": "Draw to match", "forcePlay": "Force play", "sevenO": "Seven-O", "jumpIn": "Jump-in"}
	for k in names:
		if rules.get(k, false):
			parts.append(names[k])
	info_label.text = "   ·   ".join(parts)

	if st.get("phase") != "playing":
		turn_label.text = ""
	elif my_turn:
		if pending > 0:
			turn_label.text = "Stack it or take +%d" % pending
		elif drawn >= 0:
			turn_label.text = "Play the drawn card?" if not rules.get("forcePlay", false) else "Play the drawn card"
		else:
			turn_label.text = ""  # the YOUR TURN pill says it
		turn_label.add_theme_color_override("font_color", Color("ffd24a"))
	else:
		turn_label.text = "%s's turn" % _name(st.get("turn", ""))
		turn_label.add_theme_color_override("font_color", UI.MUTED)


func _pulse(b: Button) -> void:
	if b.has_meta("pulsing"):
		return
	b.set_meta("pulsing", true)
	var tw := b.create_tween().set_loops()
	tw.tween_property(b, "scale", Vector2(1.06, 1.06), 0.45).set_trans(Tween.TRANS_SINE)
	tw.tween_property(b, "scale", Vector2.ONE, 0.45).set_trans(Tween.TRANS_SINE)


func _process(delta: float) -> void:
	if time_left > 0.0:
		time_left = maxf(0.0, time_left - delta)
		var frac := _time_frac()
		var turn: String = st.get("turn", "")
		if turn == me:
			my_panel.avatar.progress = frac
			var secs := int(ceil(time_left))
			if secs <= 5 and secs != _last_tick and Settings.v("timer_ticks"):
				_last_tick = secs
				Audio.play("tick", -2.0 if secs > 2 else 1.0, 0.0)
		elif seats.has(turn):
			seats[turn].avatar.progress = frac


# ---------------------------------------------------------------- events & fx

func _process_events(events: Array) -> void:
	for e in events:
		var kind: String = e.get("kind", "")
		var pid: String = e.get("player", "")
		var tid: String = e.get("target", "")
		var card: Dictionary = e.get("card", {})
		var text := ""
		var big := ""
		match kind:
			"play", "jumpin":
				text = "%s played %s" % [_name(pid), _card_name(card)]
				if kind == "jumpin":
					text = "%s jumped in with %s" % [_name(pid), _card_name(card)]
					big = "JUMP-IN!"
				if card.get("color") == "wild":
					text += " → %s" % str(e.get("color", "")).capitalize()
				_animate_play(pid, card)
			"draw":
				var n: int = e.get("count", 1)
				text = "%s drew %d card%s" % [_name(pid), n, "" if n == 1 else "s"]
				_animate_draw(pid, n)
			"pass":
				text = "%s passed" % _name(pid)
			"skip":
				text = "%s skipped" % _name(tid)
				big = "SKIP"
			"reverse":
				text = "Direction reversed"
				big = "REVERSE"
				ring.spin()
			"draw2", "wild4":
				text = "%s drew %d" % [_name(tid), e.get("count", 0)]
				big = "+2" if kind == "draw2" else "+4"
				_animate_draw(tid, e.get("count", 0))
				if tid == me:
					_shake(10.0 if kind == "wild4" else 6.0)
			"stack":
				text = "Stack is now +%d — %s" % [e.get("count", 0), "your move" if tid == me else _name(tid) + " to move"]
				big = "+%d" % e.get("count", 0)
			"penalty":
				text = "%s took %d cards" % [_name(pid), e.get("count", 0)]
				big = "+%d" % e.get("count", 0)
				_animate_draw(pid, e.get("count", 0))
			"swap":
				text = "%s swapped hands with %s" % [_name(pid), _name(tid)]
				big = "SWAP!"
			"rotate":
				text = "Everyone passed their hand"
				big = "ROTATE!"
			"uno":
				text = "%s called GLINT!" % _name(pid)
				big = "GLINT!"
			"catch":
				text = "%s caught %s! +%d" % [_name(pid), _name(tid), e.get("count", 2)]
				big = "CAUGHT!"
				_animate_draw(tid, e.get("count", 2))
			"timeout":
				text = "%s ran out of time" % _name(pid)
			"win":
				_confetti(pid == me)
				text = "%s won the round!" % _name(pid)
				big = "YOU WIN!" if pid == me else "%s WINS" % _name(pid).to_upper()
		_event_sound(kind, pid, tid)
		if text != "":
			_log(text)
		if big != "":
			_banner(big)


func _event_sound(kind: String, pid: String, tid: String) -> void:
	match kind:
		"play", "jumpin":
			Audio.play("card_play")
		"draw":
			Audio.play("card_draw")
		"skip":
			Audio.play("skip")
		"reverse", "swap", "rotate":
			Audio.play("reverse")
		"draw2", "stack", "penalty":
			Audio.play("plus2", 0.0 if tid == me or pid == me else -4.0)
		"wild4":
			Audio.play("plus4", 0.0 if tid == me else -3.0)
		"uno":
			Audio.play("uno")
		"catch":
			Audio.play("catch")
		"timeout":
			Audio.play("error")
		"win":
			Audio.duck(2.5)
			Audio.play("win" if pid == me else "lose", 0.0, 0.0)


func _card_name(c: Dictionary) -> String:
	var v: String = c.get("value", "")
	var names := {"skip": "Skip", "reverse": "Reverse", "draw2": "+2", "wild": "Wild", "wild4": "Wild +4"}
	var vn: String = names.get(v, v)
	if c.get("color") == "wild":
		return vn
	return "%s %s" % [str(c.get("color", "")).capitalize(), vn]


func _seat_center(pid: String) -> Vector2:
	if pid == me:
		return Vector2(size.x * 0.5, size.y - CardView.H * 0.5 - 30)
	var sv: SeatView = seats.get(pid)
	if sv:
		return sv.global_position + sv.size * 0.5
	return _center()


func _animate_play(pid: String, card: Dictionary) -> void:
	if card.is_empty():
		return
	var v: CardView
	var id := int(card.id)
	if pid == me and hand_views.has(id):
		v = hand_views[id]
		hand_views.erase(id)
		v.set_interactive(false)
		v.reparent(fx, true)
	else:
		v = CardView.make(card)
		fx.add_child(v)
		v.global_position = _seat_center(pid) - v.size * 0.5
		v.scale = Vector2(0.55, 0.55)
		v.rotation = -0.4
	v.playable = false
	v.dimmed = false
	_top_id = id
	var dest := discard_root.global_position
	var tw := v.create_tween().set_parallel(true)
	tw.tween_property(v, "global_position", dest, 0.32).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(v, "rotation", randf_range(-0.2, 0.2), 0.32)
	tw.tween_property(v, "scale", Vector2(1.08, 1.08), 0.32)
	tw.chain().tween_callback(func() -> void:
		if is_instance_valid(v):
			_push_discard(v))


func _animate_draw(pid: String, n: int) -> void:
	if pid == "" or pid == me:
		return  # our own new cards fly in from the pile in _sync_hand
	var dest := _seat_center(pid)
	var back: String = _player(pid).get("back", "")
	for i in mini(n, 6):
		var v := CardView.make({}, back)
		fx.add_child(v)
		v.global_position = draw_pile.global_position
		var tw := v.create_tween().set_parallel(true)
		tw.tween_property(v, "global_position", dest - v.size * 0.25, 0.38).set_delay(i * 0.07) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
		tw.tween_property(v, "scale", Vector2(0.4, 0.4), 0.38).set_delay(i * 0.07)
		tw.tween_property(v, "modulate:a", 0.0, 0.15).set_delay(0.3 + i * 0.07)
		tw.chain().tween_callback(v.queue_free)


func _banner(text: String) -> void:
	banner.text = text
	var col: Color = UI.CARD_COLORS.get(st.get("color", ""), Color.WHITE)
	if st.get("color", "wild") == "wild":
		col = Color.WHITE
	banner.add_theme_color_override("font_color", col.lightened(0.15))
	banner.pivot_offset = Vector2(size.x * 0.5, 45)
	banner.scale = Vector2(0.5, 0.5)
	banner.modulate.a = 1.0
	var tw := banner.create_tween()
	tw.tween_property(banner, "scale", Vector2.ONE, 0.28).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_interval(0.7)
	tw.tween_property(banner, "modulate:a", 0.0, 0.35)


func _log(text: String) -> void:
	var l := UI.label(text, 14, 500, Color(1, 1, 1, 0.8))
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(300, 0)
	log_box.add_child(l)
	while log_box.get_child_count() > 7:
		var old := log_box.get_child(0)
		log_box.remove_child(old)
		old.queue_free()
	for i in log_box.get_child_count():
		var c := log_box.get_child(i) as Control
		c.modulate.a = lerpf(0.25, 1.0, float(i + 1) / log_box.get_child_count())


func toast(text: String, error: bool = false) -> void:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", UI.flat(Color(UI.DANGER, 0.92) if error else Color(0.1, 0.1, 0.18, 0.92), 14, Color(1, 1, 1, 0.2), 1))
	p.add_child(UI.label(text, 16, 600))
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(p)
	await get_tree().process_frame
	p.position = Vector2(size.x * 0.5 - p.size.x * 0.5, 100)
	var tw := p.create_tween()
	tw.tween_interval(2.0)
	tw.tween_property(p, "modulate:a", 0.0, 0.4)
	tw.tween_callback(p.queue_free)


func show_emote(pid: String, text: String) -> void:
	Audio.play("pop")
	if pid == me:
		my_panel.show_emote(text)
	elif seats.has(pid):
		seats[pid].show_emote(text)


func _shake(strength: float) -> void:
	if Settings.v("reduce_motion"):
		return
	var tw := create_tween()
	for i in 6:
		var off := Vector2(randf_range(-1, 1), randf_range(-1, 1)) * strength * (1.0 - i / 6.0)
		tw.tween_property(self, "position", off, 0.04)
	tw.tween_property(self, "position", Vector2.ZERO, 0.05)


func _confetti(big: bool) -> void:
	if Settings.v("reduce_motion"):
		return
	var keys := ["red", "yellow", "green", "blue"]
	for i in (140 if big else 60):
		var p := ColorRect.new()
		p.color = UI.CARD_COLORS[keys[i % 4]].lightened(randf_range(0.0, 0.3))
		p.size = Vector2(randf_range(6, 12), randf_range(10, 18))
		p.pivot_offset = p.size * 0.5
		p.mouse_filter = Control.MOUSE_FILTER_IGNORE
		p.position = Vector2(size.x * 0.5 + randf_range(-80, 80), size.y * 0.42)
		fx.add_child(p)
		var dest := p.position + Vector2(randf_range(-size.x * 0.5, size.x * 0.5), randf_range(-size.y * 0.45, size.y * 0.55))
		var dur := randf_range(1.2, 2.2)
		var tw := p.create_tween().set_parallel(true)
		tw.tween_property(p, "position", dest, dur).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
		tw.tween_property(p, "rotation", randf_range(-12, 12), dur)
		tw.tween_property(p, "modulate:a", 0.0, 0.6).set_delay(dur - 0.5)
		tw.chain().tween_callback(p.queue_free)


# ---------------------------------------------------------------- input

func _do_draw() -> void:
	if is_my_turn() and st.get("drawn", -1) < 0:
		Net.send({"t": "draw"})


func _on_card_clicked(v: CardView) -> void:
	var c := v.card
	var rules: Dictionary = st.get("settings", {}).get("rules", {})
	if c.color == "wild":
		_pick_color(func(col: String) -> void: _send_play(c, col, ""))
	elif rules.get("sevenO", false) and c.value == "7" and _players().size() > 2:
		_pick_target(func(tid: String) -> void: _send_play(c, "", tid))
	else:
		_send_play(c, "", "")


func _send_play(c: Dictionary, color: String, target: String) -> void:
	var msg := {"t": "play", "card": int(c.id)}
	if color != "":
		msg.color = color
	if target != "":
		msg.target = target
	Net.send(msg)


func _unhandled_key_input(e: InputEvent) -> void:
	if not (e is InputEventKey and e.pressed and not e.echo) or modal_layer.get_child_count() > 0:
		return
	match e.keycode:
		KEY_ESCAPE:
			options_requested.emit()
		KEY_D, KEY_SPACE:
			_do_draw()
		KEY_P:
			if btn_pass.visible:
				Net.send({"t": "pass"})
		KEY_G, KEY_U:
			if btn_uno.visible:
				Net.send({"t": "uno"})
		KEY_C:
			if btn_catch.visible:
				Net.send({"t": "catch"})


# ---------------------------------------------------------------- modals

func _modal(title: String, body: Control, dismissable: bool = true) -> GlassPanel:
	_close_modal()
	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.02, 0.06, 0.45)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	if dismissable:
		dim.gui_input.connect(func(e: InputEvent) -> void:
			if e is InputEventMouseButton and e.pressed:
				_close_modal())
	modal_layer.add_child(dim)
	var panel := GlassPanel.new(28, 26)
	panel.tint_alpha = 0.12
	var col := UI.vbox(18)
	var t := UI.label(title, 28, 800)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(t)
	col.add_child(body)
	panel.add_child(col)
	modal_layer.add_child(panel)
	panel.modulate.a = 0.0
	panel.scale = Vector2(0.94, 0.94)
	await get_tree().process_frame
	if not is_instance_valid(panel):
		return panel
	panel.reset_size()
	panel.position = (size - panel.size) * 0.5
	panel.pivot_offset = panel.size * 0.5
	var tw := panel.create_tween().set_parallel(true)
	tw.tween_property(panel, "modulate:a", 1.0, 0.18)
	tw.tween_property(panel, "scale", Vector2.ONE, 0.22).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	return panel


func _close_modal() -> void:
	for c in modal_layer.get_children():
		c.queue_free()


func _pick_color(cb: Callable) -> void:
	var row := UI.hbox(16)
	for key in ["red", "yellow", "green", "blue"]:
		var b := Button.new()
		b.focus_mode = Control.FOCUS_NONE
		b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		b.custom_minimum_size = Vector2(104, 104)
		var c: Color = UI.CARD_COLORS[key]
		b.add_theme_stylebox_override("normal", UI.flat(c, 52, Color(1, 1, 1, 0.5), 3))
		b.add_theme_stylebox_override("hover", UI.flat(c.lightened(0.15), 52, Color.WHITE, 4))
		b.add_theme_stylebox_override("pressed", UI.flat(c.darkened(0.1), 52, Color.WHITE, 4))
		b.tooltip_text = key.capitalize()
		b.pressed.connect(func() -> void:
			_close_modal()
			cb.call(key))
		row.add_child(b)
	_modal("Choose a color", row)


func _pick_target(cb: Callable) -> void:
	var col := UI.vbox(10)
	for p in _others():
		var b := UI.button("%s  ·  %d cards" % [p.name, p.cards], func() -> void:
			_close_modal()
			cb.call(p.id), false, 360)
		col.add_child(b)
	_modal("Swap hands with…", col)


func _score_rows() -> VBoxContainer:
	var col := UI.vbox(8)
	var ps := _players().duplicate()
	ps.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.score > b.score)
	for i in ps.size():
		var p: Dictionary = ps[i]
		var row := UI.hbox(14)
		row.custom_minimum_size = Vector2(420, 0)
		row.add_child(UI.label("%d" % (i + 1), 18, 800, UI.MUTED))
		var n := UI.label(_name(p.id) + ("  (bot)" if p.bot else ""), 18, 650)
		n.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(n)
		row.add_child(UI.label("%d cards" % p.cards, 15, 500, UI.MUTED))
		row.add_child(UI.label("%d pts" % p.score, 18, 800, Color("ffd24a") if i == 0 else UI.TEXT))
		col.add_child(row)
	return col


func _show_scores() -> void:
	var target: int = st.get("settings", {}).get("targetScore", 0)
	var body := UI.vbox(16)
	body.add_child(_score_rows())
	if target > 0:
		var l := UI.label("First to %d points wins the match" % target, 14, 500, UI.MUTED)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		body.add_child(l)
	_modal("Scoreboard", body)


func _show_results() -> void:
	if not st.get("phase") in ["roundover", "gameover"]:
		return
	var over: bool = st.phase == "gameover"
	var winner: String = st.get("winner", "")
	var body := UI.vbox(18)
	var sub := UI.label("+%d points" % st.get("roundPoints", 0), 20, 700, Color("ffd24a"))
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	body.add_child(sub)
	body.add_child(_score_rows())
	var row := UI.hbox(12)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	var is_host: bool = st.get("host") == me
	var private_lobby: bool = not singleplayer and not st.get("settings", {}).get("public", true)
	if private_lobby:
		# Private multiplayer lobby: Continue or Leave.
		row.add_child(UI.button("Continue", func() -> void:
			_close_modal()
			if is_host:
				Net.send({"t": "start"})
			else:
				_waiting_for_host(), true, 180))
	elif is_host:
		row.add_child(UI.button("Play again" if over else "Next round", func() -> void:
			_close_modal()
			Net.send({"t": "start"}), true, 180))
	else:
		row.add_child(UI.label("Waiting for the host…", 16, 500, UI.MUTED))
	row.add_child(UI.button("Leave", func() -> void: leave_requested.emit(), false, 120))
	if results_hook.is_valid():
		results_hook.call(st, body, row)
	body.add_child(row)
	var title := ""
	if over:
		title = "You won the match! 🏆" if winner == me else "%s wins the match" % _name(winner)
	else:
		title = "You won round %d!" % st.get("round", 0) if winner == me else "%s wins round %d" % [_name(winner), st.get("round", 0)]
	_modal(title, body, false)


## Guests who pressed Continue wait here until the host starts the next round.
func _waiting_for_host() -> void:
	turn_label.text = "Waiting for %s to continue…" % _name(st.get("host", ""))
	turn_label.add_theme_color_override("font_color", UI.MUTED)
	toast("Waiting for the host to continue")


# ---------------------------------------------------------------- direction ring

class DirectionRing extends Node2D:
	var color := Color.WHITE
	var dir := 1
	var _angle := 0.0
	var _boost := 0.0

	func set_color(c: Color) -> void:
		var tw := create_tween()
		tw.tween_property(self, "color", c, 0.35)

	func spin() -> void:
		_boost = 6.0

	func _process(delta: float) -> void:
		_boost = move_toward(_boost, 0.0, delta * 8.0)
		_angle += delta * (0.35 + _boost) * dir
		queue_redraw()

	func _draw() -> void:
		# Soft glow in the active color under both piles.
		for i in 6:
			draw_circle(Vector2.ZERO, 215 - i * 28, Color(color, 0.025 + i * 0.012))
		var r := 196.0
		for k in 3:
			var a0 := _angle + k * TAU / 3.0
			var a1 := a0 + TAU / 3.0 * 0.62
			draw_arc(Vector2.ZERO, r, a0, a1, 40, Color(color, 0.55), 3.0, true)
			var tip_a := a1 if dir > 0 else a0
			var tip := Vector2(cos(tip_a), sin(tip_a)) * r
			var tangent := Vector2(-sin(tip_a), cos(tip_a)) * dir
			var normal := Vector2(cos(tip_a), sin(tip_a))
			draw_colored_polygon(PackedVector2Array([tip + tangent * 12, tip - tangent * 4 + normal * 9, tip - tangent * 4 - normal * 9]),
				Color(color, 0.75))


class ColorChip extends Control:
	var _name := ""
	var _col := Color.WHITE

	func _init() -> void:
		custom_minimum_size = Vector2(110, 30)
		size = custom_minimum_size
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func set_color(n: String, c: Color) -> void:
		if n == _name:
			return
		_name = n
		var step := func(x: Color) -> void:
			_col = x
			queue_redraw()
		create_tween().tween_method(step, _col, c, 0.3)

	func _draw() -> void:
		if _name == "" or _name == "wild":
			return
		var r := Rect2(Vector2.ZERO, size)
		var sb := StyleBoxFlat.new()
		sb.set_corner_radius_all(15)
		sb.bg_color = Color(0, 0, 0, 0.4)
		sb.border_color = Color(_col, 0.8)
		sb.set_border_width_all(1)
		sb.shadow_color = Color(_col, 0.35)
		sb.shadow_size = 10
		draw_style_box(sb, r)
		draw_circle(Vector2(18, 15), 7, _col)
		var f := UI.font(800)
		draw_string(f, Vector2(32, 15 + (f.get_ascent(14) - f.get_descent(14)) * 0.5), _name.to_upper(),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color.WHITE)
