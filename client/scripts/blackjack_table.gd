class_name BlackjackTable
extends Control
## The Blackjack table: the dealer at the top, up to five seats along the
## rail, and your controls at the bottom (chips to bet, then Hit / Stand /
## Double / Split). The server runs the rounds; this just shows them.

signal leave_requested
signal options_requested
signal rules_requested

const CHIP_VALUES := [10, 25, 50, 100, 500]
const CHIP_COLORS := {10: "3d8bff", 25: "22c983", 50: "ff4d6d", 100: "1b1b2b", 500: "8b6cff"}
const SEAT_CARD_SCALE := 0.72

var st := {}  # last state
var me := ""
var singleplayer := false
var _rows := {}  # "dealer" / "<seat>/<hand>" -> CardRow
var _seat_nodes := {}  # seat id -> SeatBox
var _pending_bet := 0
var _last_bet := 0
var _time_left := 0.0
var _last_phase := ""

var top_info := UI.label("", 15, 600, UI.MUTED)
var code_label := UI.label("", 15, 800)
var dealer_box := Control.new()
var dealer_total := Label.new()
var shoe := Control.new()
var controls := GlassPanel.new(18, 24)
var controls_row := UI.hbox(10)
var status := UI.label("", 18, 700)
var log_box := UI.vbox(4)
var chat_input: LineEdit


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_top()
	dealer_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dealer_box)
	dealer_total.add_theme_font_override("font", UI.font(800))
	dealer_total.add_theme_font_size_override("font_size", 16)
	dealer_total.add_theme_stylebox_override("normal", _pill(Color(0, 0, 0, 0.45)))
	dealer_box.add_child(dealer_total)
	var dl := UI.label("DEALER", 13, 800, Color(1, 1, 1, 0.55))
	dl.name = "DealerLabel"
	dealer_box.add_child(dl)
	_build_shoe()
	_build_log()
	controls.set_margins(22, 14)
	var col := UI.vbox(10)
	status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(status)
	controls_row.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_child(controls_row)
	controls.add_child(col)
	add_child(controls)
	resized.connect(_layout)


func _pill(c: Color) -> StyleBoxFlat:
	var sb := UI.flat(c, 12)
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 4
	sb.content_margin_bottom = 4
	return sb


func _build_top() -> void:
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
	row.add_child(UI.label("Blackjack", 22, 900))
	var code_chip := PanelContainer.new()
	code_chip.add_theme_stylebox_override("panel", _pill(Color(1, 1, 1, 0.1)))
	code_chip.add_child(code_label)
	row.add_child(code_chip)
	top_info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top_info.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	top_info.size_flags_vertical = Control.SIZE_FILL
	row.add_child(top_info)
	var opt := UI.button("Options", func() -> void: options_requested.emit())
	row.add_child(opt)
	row.add_child(UI.button("Rules", func() -> void: rules_requested.emit()))
	row.add_child(UI.button("Leave", func() -> void: leave_requested.emit()))
	top.add_child(row)
	add_child(top)


func _build_shoe() -> void:
	shoe.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for i in 4:
		var c := PlayingCard.new()
		c.scale = Vector2(0.62, 0.62)
		c.rotation = -0.22
		c.position = Vector2(-i * 3.0, -i * 3.0)
		shoe.add_child(c)
	add_child(shoe)


func _build_log() -> void:
	var panel := GlassPanel.new(16, 20)
	panel.name = "Log"
	var col := UI.vbox(8)
	col.add_child(UI.section("Table"))
	log_box.custom_minimum_size = Vector2(280, 120)
	log_box.alignment = BoxContainer.ALIGNMENT_END
	log_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(log_box)
	if Settings.v("chat") and not singleplayer:
		chat_input = UI.line_edit("", "Press Enter to chat", ChatBox.MAX_LEN)
		chat_input.custom_minimum_size = Vector2(280, 36)
		chat_input.text_submitted.connect(func(t: String) -> void:
			ChatBox.send(t)
			chat_input.clear()
			chat_input.release_focus())
		col.add_child(chat_input)
	panel.add_child(col)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(panel)


func _log(node: Control) -> void:
	node.custom_minimum_size = Vector2(280, 0)
	log_box.add_child(node)
	while log_box.get_child_count() > 6:
		var old := log_box.get_child(0)
		log_box.remove_child(old)
		old.queue_free()


func log_text(text: String) -> void:
	var l := UI.label(text, 14, 500, Color(1, 1, 1, 0.8))
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_log(l)


func add_chat(e: Dictionary) -> void:
	_log(ChatBox.line(e, 14))


# ---------------------------------------------------------------- state

func apply_state(s: Dictionary) -> void:
	var prev := st
	st = s
	me = s.get("you", "")
	var bj: Dictionary = s.get("bj", {})
	_time_left = float(bj.get("timeLeft", 0.0))
	code_label.text = "TABLE %s" % s.get("code", "")
	var phase: String = bj.get("phase", "")
	if phase != _last_phase:
		_on_phase(phase, prev)
		_last_phase = phase
	_sync_dealer(bj)
	_sync_seats(s, bj)
	_sync_controls(bj)
	_layout()


func _on_phase(phase: String, prev: Dictionary) -> void:
	match phase:
		"betting":
			_pending_bet = 0
			log_text("Place your bets")
		"playing":
			Audio.play("shuffle")
		"results":
			_announce_results()


func _announce_results() -> void:
	var mine := _my_seat()
	if mine.is_empty() or mine.get("hands", []).is_empty():
		return
	var staked := 0
	var paid := 0
	var best := ""
	for h in mine.hands:
		staked += int(h.bet)
		paid += int(h.get("payout", 0))
		var r: String = h.get("result", "")
		if r == "blackjack" or best == "":
			best = r
	var net := paid - staked
	if net > 0:
		Audio.play("win")
		log_text(("Blackjack! " if best == "blackjack" else "You win ") + "+%d chips" % net)
	elif net == 0:
		log_text("Push: your bet comes back")
	else:
		Audio.play("lose")
		log_text("You lose %d chips" % -net)


func _my_seat() -> Dictionary:
	for s in st.get("bj", {}).get("seats", []):
		if s.id == me:
			return s
	return {}


func my_chips() -> int:
	return int(_my_seat().get("chips", 0))


func _player(id: String) -> Dictionary:
	for p in st.get("players", []):
		if p.id == id:
			return p
	return {}


func _name_of(id: String) -> String:
	return "You" if id == me else str(_player(id).get("name", "?"))


func _sync_dealer(bj: Dictionary) -> void:
	var cards: Array = bj.get("dealer", [])
	var row := _row("dealer", 1.0, dealer_box)
	row.set_cards(cards, _shoe_point())
	var total := int(bj.get("dealerTotal", 0))
	dealer_total.text = str(total) if not cards.is_empty() else ""
	dealer_total.visible = not cards.is_empty()
	if total > 21:
		dealer_total.text = "%d · Bust" % total


func _row(key: String, scale_: float, parent: Control) -> CardRow:
	if not _rows.has(key) or not is_instance_valid(_rows[key]):
		var r := CardRow.new()
		r.card_scale = scale_
		parent.add_child(r)
		_rows[key] = r
	return _rows[key]


func _sync_seats(s: Dictionary, bj: Dictionary) -> void:
	var seats: Array = bj.get("seats", [])
	var want := {}
	for sj in seats:
		want[sj.id] = true
	for id in _seat_nodes.keys():
		if not want.has(id):
			_seat_nodes[id].queue_free()
			_seat_nodes.erase(id)
	for sj in seats:
		var box: SeatBox = _seat_nodes.get(sj.id)
		if box == null:
			box = SeatBox.new()
			add_child(box)
			_seat_nodes[sj.id] = box
		var p := _player(sj.id)
		box.update(sj, p, sj.id == me, bj.get("turn", "") == sj.id, bj.get("phase", ""), _shoe_point())


func _sync_controls(bj: Dictionary) -> void:
	for c in controls_row.get_children():
		c.queue_free()
	var phase: String = bj.get("phase", "")
	var mine := _my_seat()
	var chips := int(mine.get("chips", 0))
	var min_bet := int(bj.get("minBet", 10))
	var max_bet := int(bj.get("maxBet", 500))
	match phase:
		"betting":
			var placed := int(mine.get("bet", 0))
			if placed > 0:
				status.text = "Bet placed: %d. Waiting for the others…" % placed
				return
			if chips < min_bet:
				status.text = "Not enough chips for this table (minimum %d)" % min_bet
				return
			status.text = "Your bet: %d" % _pending_bet if _pending_bet > 0 else "Place your bet (%d to %d)" % [min_bet, max_bet]
			for v in CHIP_VALUES:
				if v > max_bet or v > chips:
					continue
				var b := ChipButton.new()
				b.value = v
				b.chip_color = Color(CHIP_COLORS[v])
				b.pressed.connect(func() -> void:
					_pending_bet = mini(_pending_bet + v, mini(chips, max_bet))
					Audio.play("pop")
					_sync_controls(st.get("bj", {})))
				controls_row.add_child(b)
			if _pending_bet > 0:
				controls_row.add_child(UI.button("Clear", func() -> void:
					_pending_bet = 0
					_sync_controls(st.get("bj", {}))))
			elif _last_bet >= min_bet and _last_bet <= chips:
				controls_row.add_child(UI.button("Repeat %d" % _last_bet, func() -> void: _place_bet(_last_bet)))
			var go := UI.button("Bet", func() -> void: _place_bet(_pending_bet), true, 140)
			go.disabled = _pending_bet < min_bet
			controls_row.add_child(go)
		"playing":
			if bj.get("turn", "") != me:
				status.text = "%s to play…" % _name_of(bj.get("turn", ""))
				return
			status.text = "Your turn"
			var hit := UI.button("Hit", func() -> void: Net.send({"t": "hit"}), true, 130)
			hit.tooltip_text = "Take another card (H)"
			controls_row.add_child(hit)
			var stand := UI.button("Stand", func() -> void: Net.send({"t": "stand"}), false, 130)
			stand.tooltip_text = "Keep your hand (S)"
			controls_row.add_child(stand)
			var dbl := UI.button("Double", func() -> void: Net.send({"t": "double"}), false, 130)
			dbl.tooltip_text = "Double your bet, take one card and stand (D)"
			dbl.disabled = not bj.get("canDouble", false)
			controls_row.add_child(dbl)
			var spl := UI.button("Split", func() -> void: Net.send({"t": "split"}), false, 130)
			spl.tooltip_text = "Split a pair into two hands (P)"
			spl.disabled = not bj.get("canSplit", false)
			controls_row.add_child(spl)
		"dealer":
			status.text = "Dealer's turn"
		"results":
			status.text = "Next hand soon…"
		_:
			status.text = ""


func _place_bet(amount: int) -> void:
	if amount <= 0:
		return
	_last_bet = amount
	_pending_bet = 0
	Audio.play("pop")
	Net.send({"t": "bet", "amount": amount})


func _process(delta: float) -> void:
	if _time_left > 0.0:
		_time_left = maxf(0.0, _time_left - delta)
	var bj: Dictionary = st.get("bj", {})
	var phase: String = bj.get("phase", "")
	var chips := my_chips()
	var info := "Chips: %d" % chips
	if phase == "betting" and _time_left > 0:
		info += "    ·    Betting closes in %ds" % ceili(_time_left)
	elif phase == "playing" and bj.get("turn", "") == me and _time_left > 0:
		info += "    ·    %ds to decide" % ceili(_time_left)
	top_info.text = info


func _unhandled_key_input(e: InputEvent) -> void:
	if not (e is InputEventKey and e.pressed and not e.echo):
		return
	var bj: Dictionary = st.get("bj", {})
	match e.keycode:
		KEY_ESCAPE:
			options_requested.emit()
		KEY_ENTER, KEY_KP_ENTER, KEY_T:
			if chat_input != null:
				chat_input.grab_focus()
				get_viewport().set_input_as_handled()
	if bj.get("phase", "") != "playing" or bj.get("turn", "") != me:
		return
	match e.keycode:
		KEY_H:
			Net.send({"t": "hit"})
		KEY_S:
			Net.send({"t": "stand"})
		KEY_D:
			if bj.get("canDouble", false):
				Net.send({"t": "double"})
		KEY_P:
			if bj.get("canSplit", false):
				Net.send({"t": "split"})


func _shoe_point() -> Vector2:
	return shoe.global_position + Vector2(20, 30)


func _layout() -> void:
	var w := size.x
	var h := size.y
	dealer_box.position = Vector2(w * 0.5, h * 0.24)
	var dl := dealer_box.get_node_or_null("DealerLabel")
	if dl:
		dl.reset_size()
		dl.position = Vector2(-dl.size.x * 0.5, -100)
	if _rows.has("dealer"):
		var row: CardRow = _rows["dealer"]
		row.position = Vector2(-row.width() * 0.5, -70)
		dealer_total.reset_size()
		dealer_total.position = Vector2(-dealer_total.size.x * 0.5, 86)
	shoe.position = Vector2(w - 190, 130)
	# Seats along the rail, left to right.
	var ids: Array = []
	for sj in st.get("bj", {}).get("seats", []):
		ids.append(sj.id)
	var n := ids.size()
	for i in n:
		var box: SeatBox = _seat_nodes.get(ids[i])
		if box == null:
			continue
		var t := 0.5 if n == 1 else float(i) / (n - 1)
		var x := lerpf(w * 0.18, w * 0.82, t)
		var y := h * 0.55 + sin(t * PI) * h * 0.05
		box.reset_size()
		box.position = Vector2(x - box.size.x * 0.5, y - 40)
	controls.reset_size()
	controls.position = Vector2(w * 0.5 - controls.size.x * 0.5, h - controls.size.y - 22)
	var lg := get_node_or_null("Log") as Control
	if lg:
		lg.reset_size()
		lg.position = Vector2(22, 108)  # top-left, clear of the seats


func _draw() -> void:
	# The felt: a wide glass arc under the seats.
	var c := Vector2(size.x * 0.5, size.y * 0.1)
	var r := Vector2(size.x * 0.46, size.y * 0.66)
	var pts := PackedVector2Array()
	for i in 65:
		var a := PI * float(i) / 64.0
		pts.append(c + Vector2(cos(a) * r.x, sin(a) * r.y))
	draw_colored_polygon(pts, Color(0.13, 0.62, 0.45, 0.10))
	draw_polyline(pts, Color(1, 1, 1, 0.18), 2.0, true)
	draw_string(UI.font(800), Vector2(0, size.y * 0.43), "BLACKJACK PAYS 3 TO 2", HORIZONTAL_ALIGNMENT_CENTER, size.x, 18, Color(1, 1, 1, 0.16))
	draw_string(UI.font(600), Vector2(0, size.y * 0.43 + 26), "Dealer stands on all 17s", HORIZONTAL_ALIGNMENT_CENTER, size.x, 14, Color(1, 1, 1, 0.13))


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		queue_redraw()


func toast(text: String, error: bool = false) -> void:
	log_text(("⚠ " if error else "") + text)


# ---------------------------------------------------------------- pieces

## A row of overlapping cards that animates new cards in from the shoe.
class CardRow extends Control:
	var card_scale := 1.0
	var _cards: Array[PlayingCard] = []

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func width() -> float:
		var n := _cards.size()
		return 0.0 if n == 0 else (PlayingCard.W + (n - 1) * _step()) * card_scale

	func _step() -> float:
		return PlayingCard.W * 0.42

	func set_cards(cards: Array, from_global: Vector2) -> void:
		# A new round (fewer cards): start over.
		if cards.size() < _cards.size():
			for c in _cards:
				c.queue_free()
			_cards.clear()
		for i in cards.size():
			var data: Dictionary = cards[i]
			if i < _cards.size():
				var have := _cards[i]
				if have.rank != str(data.get("rank", "")) or have.suit != str(data.get("suit", "")):
					_flip(have, data)  # the hole card turns over
				continue
			var c := PlayingCard.make(data)
			c.scale = Vector2(card_scale, card_scale)
			if card_scale != 1.0:
				c.pivot_offset = Vector2.ZERO  # scale from the corner so the row lines up
			add_child(c)
			_cards.append(c)
			var target := Vector2(i * _step() * card_scale, 0)
			if is_inside_tree() and not Settings.v("reduce_motion"):
				c.global_position = from_global
				c.rotation = -0.4
				var tw := c.create_tween().set_parallel(true)
				tw.tween_property(c, "position", target, 0.28).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT).set_delay(0.06 * i)
				tw.tween_property(c, "rotation", 0.0, 0.28).set_delay(0.06 * i)
				Audio.play("card_draw")
			else:
				c.position = target

	func _flip(c: PlayingCard, data: Dictionary) -> void:
		var tw := c.create_tween()
		tw.tween_property(c, "scale:x", 0.0, 0.12)
		tw.tween_callback(func() -> void:
			c.rank = str(data.get("rank", ""))
			c.suit = str(data.get("suit", ""))
			c.queue_redraw())
		tw.tween_property(c, "scale:x", card_scale, 0.12)


## One player's spot at the table: name, chips, bet and hands.
class SeatBox extends VBoxContainer:
	const CARD_SCALE := 0.72
	var name_label := UI.label("", 16, 800)
	var chips_label := UI.label("", 13, 600, UI.MUTED)
	var hands_box := HBoxContainer.new()
	var bet_label := Label.new()
	var _rows := {}

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		alignment = BoxContainer.ALIGNMENT_CENTER
		add_theme_constant_override("separation", 6)
		hands_box.alignment = BoxContainer.ALIGNMENT_CENTER
		hands_box.add_theme_constant_override("separation", 18)
		hands_box.custom_minimum_size = Vector2(0, PlayingCard.H * CARD_SCALE + 30)
		add_child(hands_box)
		bet_label.add_theme_font_override("font", UI.font(800))
		bet_label.add_theme_font_size_override("font_size", 14)
		bet_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		add_child(bet_label)
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		add_child(name_label)
		chips_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		add_child(chips_label)

	func update(sj: Dictionary, p: Dictionary, is_me: bool, acting: bool, phase: String, shoe_at: Vector2) -> void:
		var nm := "You" if is_me else str(p.get("name", "?"))
		if p.get("away", false):
			nm += " (away)"
		name_label.text = nm
		name_label.add_theme_color_override("font_color", Color("ffd24a") if acting else UI.TEXT)
		chips_label.text = "%d chips" % int(sj.get("chips", 0))
		var hands: Array = sj.get("hands", [])
		var bet := int(sj.get("bet", 0))
		if phase == "betting":
			if p.get("away", false) or int(sj.get("chips", 0)) < 1:
				bet_label.text = "Sitting out"
			else:
				bet_label.text = "Bet %d" % bet if bet > 0 else ("Betting…" if not is_me else "")
		else:
			bet_label.text = ""
		var keep := {}
		for hi in hands.size():
			var hd: Dictionary = hands[hi]
			var key := str(hi)
			keep[key] = true
			var holder: HandBox = _rows.get(key)
			if holder == null:
				holder = HandBox.new()
				hands_box.add_child(holder)
				_rows[key] = holder
			holder.update(hd, shoe_at)
		for key in _rows.keys():
			if not keep.has(key):
				_rows[key].queue_free()
				_rows.erase(key)


## One hand: its cards, total, bet and result.
class HandBox extends VBoxContainer:
	const CARD_SCALE := 0.72
	var row := CardRow.new()
	var holder := Control.new()
	var info := Label.new()

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_theme_constant_override("separation", 4)
		row.card_scale = CARD_SCALE
		holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
		holder.add_child(row)
		add_child(holder)
		info.add_theme_font_override("font", UI.font(800))
		info.add_theme_font_size_override("font_size", 14)
		info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		add_child(info)

	func update(hd: Dictionary, shoe_at: Vector2) -> void:
		row.set_cards(hd.get("cards", []), shoe_at)
		holder.custom_minimum_size = Vector2(maxf(row.width(), PlayingCard.W * CARD_SCALE), PlayingCard.H * CARD_SCALE)
		var total := int(hd.get("total", 0))
		var txt := "%d%s · bet %d" % [total, " soft" if hd.get("soft", false) and total < 21 else "", int(hd.get("bet", 0))]
		var res: String = hd.get("result", "")
		var col := UI.TEXT
		match res:
			"blackjack":
				txt = "BLACKJACK! +%d" % (int(hd.payout) - int(hd.bet))
				col = Color("ffd24a")
			"win":
				txt = "WIN +%d" % int(hd.bet)
				col = UI.SUCCESS
			"push":
				txt = "PUSH"
				col = UI.MUTED
			"bust", "lose":
				txt = res.to_upper()
				col = UI.DANGER
		if res == "" and total > 21:
			txt = "BUST"
			col = UI.DANGER
		info.text = txt
		info.add_theme_color_override("font_color", col)
		var glow: bool = hd.get("active", false)
		modulate = Color(1, 1, 1, 1) if glow or res != "" or hd.get("cards", []).size() == 0 else Color(1, 1, 1, 0.92)
		info.add_theme_stylebox_override("normal", _hl(glow))

	func _hl(on: bool) -> StyleBoxFlat:
		var sb := UI.flat(Color("ffd24a", 0.25) if on else Color(0, 0, 0, 0.35), 10)
		sb.content_margin_left = 10
		sb.content_margin_right = 10
		sb.content_margin_top = 2
		sb.content_margin_bottom = 2
		return sb


## A round chip you click to add to your bet.
class ChipButton extends Button:
	var value := 10
	var chip_color := Color.WHITE

	func _init() -> void:
		custom_minimum_size = Vector2(64, 64)
		flat = true
		focus_mode = Control.FOCUS_NONE
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		tooltip_text = "Add to your bet"

	func _draw() -> void:
		var c := size * 0.5
		var r := minf(size.x, size.y) * 0.5 - 3
		var hover := is_hovered()
		draw_circle(c + Vector2(0, 3), r, Color(0, 0, 0, 0.35))
		draw_circle(c, r, chip_color.lightened(0.12 if hover else 0.0))
		for i in 8:
			var a := TAU * i / 8.0
			draw_line(c + Vector2(cos(a), sin(a)) * (r - 7), c + Vector2(cos(a), sin(a)) * (r - 1), Color(1, 1, 1, 0.85), 5.0)
		draw_circle(c, r * 0.62, Color(1, 1, 1, 0.92))
		draw_string(UI.font(900), Vector2(0, c.y + 7), str(value), HORIZONTAL_ALIGNMENT_CENTER, size.x, 18, chip_color.darkened(0.15))
