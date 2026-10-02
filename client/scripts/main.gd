extends Control
## App controller: menus, campaign, customization, lobby and the table,
## driven by server messages.

const CONFIG_PATH := "user://settings.cfg"

var bg := ColorRect.new()
var bg_mat := ShaderMaterial.new()
var screen_root := Control.new()
var toast_root := Control.new()
var modal_root := Control.new()
var table: Table

var player_name := ""
var server_addr := "127.0.0.1"
var singleplayer := false
var campaign_stage := -1
var _on_connected: Callable
var _after_left: Callable
var _last_state: Dictionary = {}
var _rooms_box: VBoxContainer
var _lobby_sig := ""
var _round_track := {}  # "code/round" -> counters for XP
var _awarded := {}  # "code/round" -> award result

# Settings edited before a room exists (quick play / create room).
var setup := {
	"bots": 3,
	"settings": {
		"rules": {"handSize": 7, "stacking": false, "drawToMatch": false, "forcePlay": false, "sevenO": false, "jumpIn": false},
		"turnTime": 0,
		"targetScore": 0,
		"difficulty": "normal",
		"public": true,
	},
}


func _ready() -> void:
	theme = UI.make_theme()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	bg_mat.shader = load("res://shaders/background.gdshader")
	bg.material = bg_mat
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	bg.resized.connect(func() -> void: bg_mat.set_shader_parameter("size", bg.size))

	screen_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	screen_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(screen_root)
	modal_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	modal_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(modal_root)
	toast_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	toast_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(toast_root)

	_load_config()
	_apply_cosmetics()
	Profile.changed.connect(_apply_cosmetics)
	Net.connected.connect(_net_connected)
	Net.disconnected.connect(_net_disconnected)
	Net.message.connect(_net_message)
	show_menu()
	_debug_args()


func _apply_cosmetics() -> void:
	var th := Cosmetics.find("theme", Profile.selected.theme)
	bg_mat.set_shader_parameter("base_top", Color(th.top))
	bg_mat.set_shader_parameter("base_bottom", Color(th.bottom))
	for i in 4:
		bg_mat.set_shader_parameter("blob%d" % (i + 1), Color(th.blobs[i]))
	CardView.default_back = Profile.selected.back


## Dev helpers:  godot --path client -- --demo --screen=campaign --shot=out.png@6 --autoplay --xp=900
func _debug_args() -> void:
	var quit_at := 0.0
	for a in OS.get_cmdline_user_args():
		if a == "--demo":
			_start_singleplayer.call_deferred(int(setup.bots), setup.settings, -1)
		elif a == "--autoplay":
			set_meta("autoplay", true)
		elif a.begins_with("--xp="):
			Profile.xp = int(a.get_slice("=", 1))
			Profile.changed.emit()
			show_menu()
		elif a.begins_with("--screen="):
			match a.get_slice("=", 1):
				"single":
					show_singleplayer()
				"multi":
					show_multiplayer()
				"campaign":
					show_campaign()
				"customize":
					show_customize()
				"profile":
					show_profile()
				"rules":
					show_rules()
		elif a.begins_with("--stage="):
			_start_stage.call_deferred(int(a.get_slice("=", 1)))
		elif a.begins_with("--shot="):
			var spec := a.get_slice("=", 1)
			var path := spec.get_slice("@", 0)
			var secs := float(spec.get_slice("@", 1))
			quit_at = maxf(quit_at, secs + 0.5)
			get_tree().create_timer(secs).timeout.connect(func() -> void:
				get_viewport().get_texture().get_image().save_png(path))
	if quit_at > 0:
		get_tree().create_timer(quit_at).timeout.connect(func() -> void:
			Net.stop_local_servers()
			get_tree().quit())


func _process(_d: float) -> void:
	# --autoplay: play the first legal card for us (for testing the table).
	if not has_meta("autoplay") or table == null or not table.is_my_turn():
		return
	if Engine.get_process_frames() % 20 != 0:
		return
	var st := table.st
	if st.get("canUno", false):
		Net.send({"t": "uno"})
	var playable: Array = st.get("playable", [])
	if playable.size() > 0:
		Net.send({"t": "play", "card": int(playable[0]), "color": "blue"})
	elif int(st.get("drawn", -1)) >= 0:
		Net.send({"t": "pass"})
	else:
		Net.send({"t": "draw"})


# ---------------------------------------------------------------- config

func _load_config() -> void:
	var cf := ConfigFile.new()
	if cf.load(CONFIG_PATH) == OK:
		player_name = cf.get_value("player", "name", "")
		server_addr = cf.get_value("net", "server", "127.0.0.1")
		var saved = cf.get_value("game", "setup", null)
		if saved is Dictionary:
			setup.merge(saved, true)
	if player_name == "":
		player_name = OS.get_environment("USERNAME").substr(0, 16)
	if player_name == "":
		player_name = "Player"


func _save_config() -> void:
	var cf := ConfigFile.new()
	cf.set_value("player", "name", player_name)
	cf.set_value("net", "server", server_addr)
	cf.set_value("game", "setup", setup)
	cf.save(CONFIG_PATH)


func _name() -> String:
	return player_name if player_name != "" else "Player"


# ---------------------------------------------------------------- screen helpers

func _clear() -> void:
	for c in screen_root.get_children():
		c.queue_free()
	table = null
	_lobby_sig = ""
	_rooms_box = null


func _decor() -> void:
	screen_root.add_child(FloatingCards.new())


func _centered(node: Control) -> CenterContainer:
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(node)
	screen_root.add_child(center)
	node.modulate.a = 0.0
	node.create_tween().tween_property(node, "modulate:a", 1.0, 0.25)
	return center


func _card(width: float) -> GlassPanel:
	var p := GlassPanel.new(32, 28)
	p.custom_minimum_size = Vector2(width, 0)
	p.tint_alpha = 0.1
	_centered(p)
	return p


func _title(text: String, sub: String = "") -> VBoxContainer:
	var v := UI.vbox(4)
	v.add_child(UI.label(text, 30, 800))
	if sub != "":
		var s := UI.label(sub, 15, 500, UI.MUTED)
		s.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		v.add_child(s)
	return v


func _header(text: String, sub: String, back: Callable) -> HBoxContainer:
	var row := UI.hbox(16)
	var t := _title(text, sub)
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(t)
	var b := UI.button("Back", back, false, 110)
	b.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	row.add_child(b)
	return row


func _logo(sz: int) -> HBoxContainer:
	var logo := UI.hbox(2)
	for l in [["U", "red"], ["N", "yellow"], ["O", "green"]]:
		var lab := UI.label(l[0], sz, 900, UI.CARD_COLORS[l[1]])
		lab.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.25))
		lab.add_theme_constant_override("outline_size", int(sz / 8))
		logo.add_child(lab)
	return logo


## A big menu button with a title and subtitle.
func _nav(title: String, sub: String, cb: Callable, primary: bool = false) -> Button:
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.custom_minimum_size = Vector2(0, 74)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if primary:
		UI.style_button(b, UI.ACCENT, 18)
	else:
		b.add_theme_stylebox_override("normal", UI.flat(Color(1, 1, 1, 0.08), 18, Color(1, 1, 1, 0.22), 1))
		b.add_theme_stylebox_override("hover", UI.flat(Color(1, 1, 1, 0.16), 18, Color(1, 1, 1, 0.42), 1))
		b.add_theme_stylebox_override("pressed", UI.flat(Color(1, 1, 1, 0.22), 18, Color(1, 1, 1, 0.5), 1))
	var col := UI.vbox(0)
	col.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	col.offset_left = 22
	col.offset_right = -22
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var t := UI.label(title, 21, 800)
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(t)
	if sub != "":
		var s := UI.label(sub, 13, 500, Color(1, 1, 1, 0.75) if primary else UI.MUTED)
		s.mouse_filter = Control.MOUSE_FILTER_IGNORE
		col.add_child(s)
	b.add_child(col)
	b.pressed.connect(cb)
	b.mouse_entered.connect(func() -> void:
		b.pivot_offset = b.size * 0.5
		b.create_tween().tween_property(b, "scale", Vector2(1.02, 1.02), 0.12))
	b.mouse_exited.connect(func() -> void:
		b.create_tween().tween_property(b, "scale", Vector2.ONE, 0.12))
	return b


func _avatar(d: float) -> SeatView.Avatar:
	var av := SeatView.Avatar.new(d)
	av.letter = _name().substr(0, 1).to_upper()
	av.color = UI.avatar_color(_name())
	av.frame = Profile.selected.frame
	av.level = Profile.level()
	return av


func _xp_bar(width: float) -> VBoxContainer:
	var info := Profile.level_for_xp(Profile.xp)
	var col := UI.vbox(6)
	var bar := XPBar.new()
	bar.custom_minimum_size = Vector2(width, 12)
	bar.value = 1.0 if info.max else float(info.into) / info.need
	col.add_child(bar)
	var txt := "Max level" if info.max else "%d / %d XP to level %d" % [info.into, info.need, info.level + 1]
	col.add_child(UI.label(txt, 13, 500, UI.MUTED))
	return col


# ---------------------------------------------------------------- main menu

func show_menu() -> void:
	_clear()
	singleplayer = false
	campaign_stage = -1
	_decor()
	var row := UI.hbox(36)
	row.alignment = BoxContainer.ALIGNMENT_CENTER

	# Left: logo + navigation.
	var left := UI.vbox(12)
	left.custom_minimum_size = Vector2(440, 0)
	left.add_child(_logo(112))
	left.add_child(UI.label("Glass edition  ·  Go-powered multiplayer", 16, 600, UI.MUTED))
	left.add_child(UI.spacer(0, 14))
	var nav_glass := GlassPanel.new(16, 26)
	nav_glass.tint_alpha = 0.06
	var nav := UI.vbox(12)
	nav_glass.add_child(nav)
	left.add_child(nav_glass)
	row.add_child(left)
	left = nav  # the buttons below go inside the glass
	var cleared := 0
	for i in Cosmetics.STAGES.size():
		if Profile.stars(i) > 0:
			cleared += 1
	left.add_child(_nav("Campaign", "%d / %d levels cleared  ·  ★ %d" % [cleared, Cosmetics.STAGES.size(), Profile.total_stars()], show_campaign, true))
	left.add_child(_nav("Quick Play", "You vs bots with your own house rules", show_singleplayer))
	left.add_child(_nav("Multiplayer", "Host on your network or join a server", show_multiplayer))
	var pair := UI.hbox(12)
	pair.add_child(_nav("Customize", "Backs · themes · frames", show_customize))
	pair.add_child(_nav("Profile", "Stats & unlocks", show_profile))
	left.add_child(pair)
	var bottom := UI.hbox(12)
	var how := UI.button("How to Play", show_rules)
	how.custom_minimum_size = Vector2(0, 42)
	how.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bottom.add_child(how)
	var quit := UI.button("Quit", func() -> void: get_tree().quit())
	quit.custom_minimum_size = Vector2(120, 42)
	bottom.add_child(quit)
	left.add_child(bottom)

	# Right: profile card.
	var card := GlassPanel.new(28, 28)
	card.tint_alpha = 0.1
	card.custom_minimum_size = Vector2(380, 0)
	card.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var col := UI.vbox(14)
	var head := UI.hbox(16)
	head.add_child(_avatar(96))
	var who := UI.vbox(2)
	who.alignment = BoxContainer.ALIGNMENT_CENTER
	who.add_child(UI.label("LEVEL %d" % Profile.level(), 13, 800, UI.ACCENT.lightened(0.35)))
	who.add_child(UI.label(Profile.title(), 24, 800))
	head.add_child(who)
	col.add_child(head)
	col.add_child(UI.section("Your name"))
	var name_edit := UI.line_edit(player_name, "Enter a name", 16)
	name_edit.text_changed.connect(func(t: String) -> void:
		player_name = t.strip_edges()
		_save_config())
	col.add_child(name_edit)
	col.add_child(_xp_bar(320))

	var stats := UI.hbox(8)
	var rounds := int(Profile.stats.rounds)
	var wins := int(Profile.stats.wins)
	for s in [[str(wins), "Wins"], ["%d%%" % (100 * wins / maxi(rounds, 1)), "Win rate"], [str(Profile.stats.best_streak), "Best streak"]]:
		stats.add_child(_stat_tile(s[0], s[1]))
	col.add_child(stats)

	var nxt := Profile.next_unlocks(1)
	if nxt.size() > 0:
		var u: Dictionary = nxt[0]
		var chip := PanelContainer.new()
		chip.add_theme_stylebox_override("panel", UI.flat(Color(UI.ACCENT, 0.18), 12, Color(UI.ACCENT, 0.5), 1))
		chip.add_child(UI.label("Next unlock  ·  Lv %d  %s: %s" % [u.item.level, Cosmetics.kind_label(u.kind), u.item.name], 14, 600))
		col.add_child(chip)
	card.add_child(col)
	row.add_child(card)
	_centered(row)


func _stat_tile(big: String, small: String) -> PanelContainer:
	var p := PanelContainer.new()
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	p.add_theme_stylebox_override("panel", UI.flat(Color(1, 1, 1, 0.06), 14, Color(1, 1, 1, 0.12), 1))
	var v := UI.vbox(0)
	var b := UI.label(big, 24, 800)
	b.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var s := UI.label(small, 12, 600, UI.MUTED)
	s.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(b)
	v.add_child(s)
	p.add_child(v)
	return p


# ---------------------------------------------------------------- campaign

func show_campaign() -> void:
	_clear()
	_decor()
	var p := _card(1040)
	var col := UI.vbox(18)
	col.add_child(_header("Campaign", "Beat each level to unlock the next.  ★ win   ★★ score 50+ points   ★★★ draw 3 cards or fewer", show_menu))
	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 14)
	grid.add_theme_constant_override("v_separation", 14)
	for i in Cosmetics.STAGES.size():
		grid.add_child(_stage_tile(i))
	col.add_child(grid)
	p.add_child(col)


func _stage_tile(i: int) -> Button:
	var stg: Dictionary = Cosmetics.STAGES[i]
	var unlocked := Profile.stage_unlocked(i)
	var stars := Profile.stars(i)
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(235, 168)
	b.disabled = not unlocked
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if unlocked else Control.CURSOR_FORBIDDEN
	var tint := Color(1, 1, 1, 0.07)
	var rim := Color(1, 1, 1, 0.18)
	if stars > 0:
		rim = Color("ffd24a", 0.55)
	b.add_theme_stylebox_override("normal", UI.flat(tint, 18, rim, 1))
	b.add_theme_stylebox_override("hover", UI.flat(Color(1, 1, 1, 0.15), 18, Color(1, 1, 1, 0.5), 1))
	b.add_theme_stylebox_override("pressed", UI.flat(Color(1, 1, 1, 0.2), 18, Color.WHITE, 1))
	b.add_theme_stylebox_override("disabled", UI.flat(Color(0, 0, 0, 0.18), 18, Color(1, 1, 1, 0.06), 1))

	var col := UI.vbox(4)
	col.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	col.offset_left = 18
	col.offset_right = -18
	col.offset_top = 14
	col.offset_bottom = -14
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var top := UI.hbox(8)
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var lv := UI.label("LEVEL %d" % (i + 1), 12, 800, UI.MUTED)
	lv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(lv)
	var star_txt := "★".repeat(stars) + "☆".repeat(3 - stars)
	top.add_child(UI.label(star_txt if unlocked else "🔒", 18, 700, Color("ffd24a") if stars > 0 else Color(1, 1, 1, 0.35)))
	col.add_child(top)
	col.add_child(UI.label(stg.name, 20, 800, UI.TEXT if unlocked else Color(1, 1, 1, 0.4)))
	var d := UI.label(stg.desc if unlocked else "Clear level %d to unlock" % i, 13, 500, UI.MUTED)
	d.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	d.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(d)
	var chips: Array[String] = ["%d bot%s" % [stg.bots, "" if stg.bots == 1 else "s"], str(stg.difficulty).capitalize()]
	var rn := {"stacking": "Stacking", "jumpIn": "Jump-in", "sevenO": "Seven-O", "drawToMatch": "Draw to match", "forcePlay": "Force play"}
	for k in stg.rules:
		if rn.has(k):
			chips.append(rn[k])
	var chip := UI.label("  ·  ".join(chips), 12, 600, UI.ACCENT.lightened(0.45) if unlocked else Color(1, 1, 1, 0.3))
	chip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(chip)
	for c in col.get_children():
		(c as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(col)
	b.pressed.connect(_start_stage.bind(i))
	return b


func _start_stage(i: int) -> void:
	var stg: Dictionary = Cosmetics.STAGES[i]
	_start_singleplayer(stg.bots, Cosmetics.stage_settings(i), i)


# ---------------------------------------------------------------- customize

var _custom_tab := "back"


func show_customize() -> void:
	_clear()
	_decor()
	var p := _card(980)
	var col := UI.vbox(18)
	col.add_child(_header("Customize", "You're level %d. Level up by playing to unlock more styles." % Profile.level(), show_menu))
	col.add_child(UI.segmented([["Card backs", "back"], ["Table themes", "theme"], ["Avatar frames", "frame"]], _custom_tab,
		func(v: String) -> void:
			_custom_tab = v
			show_customize()))
	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 14)
	grid.add_theme_constant_override("v_separation", 14)
	for it in Cosmetics.list_for(_custom_tab):
		grid.add_child(_cosmetic_tile(_custom_tab, it))
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 560)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.add_child(grid)
	col.add_child(scroll)
	p.add_child(col)


func _cosmetic_tile(kind: String, it: Dictionary) -> Button:
	var unlocked := Profile.is_unlocked(kind, it.id)
	var equipped: bool = Profile.selected[kind] == it.id
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(216, 262)
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if unlocked else Control.CURSOR_FORBIDDEN
	var rim := Color(UI.ACCENT.lightened(0.3), 0.95) if equipped else Color(1, 1, 1, 0.16)
	b.add_theme_stylebox_override("normal", UI.flat(Color(UI.ACCENT, 0.22) if equipped else Color(1, 1, 1, 0.06), 18, rim, 2 if equipped else 1))
	b.add_theme_stylebox_override("hover", UI.flat(Color(1, 1, 1, 0.14), 18, Color(1, 1, 1, 0.5), 2))
	b.add_theme_stylebox_override("pressed", UI.flat(Color(1, 1, 1, 0.2), 18, Color.WHITE, 2))

	var col := UI.vbox(8)
	col.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	col.offset_top = 14
	col.offset_bottom = -14
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var preview := CenterContainer.new()
	preview.custom_minimum_size = Vector2(0, 170)
	preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	match kind:
		"back":
			var holder := Control.new()
			holder.custom_minimum_size = Vector2(CardView.W, CardView.H)
			holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
			var cv := CardView.make({}, it.id)
			cv.rotation = -0.08
			holder.add_child(cv)
			preview.add_child(holder)
		"theme":
			var sw := ThemeSwatch.new()
			sw.theme_def = it
			preview.add_child(sw)
		"frame":
			var av := _avatar(110)
			av.frame = it.id
			av.level = 0
			preview.add_child(av)
	col.add_child(preview)
	var n := UI.label(it.name, 18, 800)
	n.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(n)
	var status := "Equipped" if equipped else ("Click to equip" if unlocked else "🔒  Unlocks at level %d" % it.level)
	var s := UI.label(status, 13, 600, UI.ACCENT.lightened(0.45) if equipped else UI.MUTED)
	s.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(s)
	for c in col.get_children():
		(c as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(col)
	if not unlocked:
		preview.modulate = Color(1, 1, 1, 0.35)
	b.pressed.connect(func() -> void:
		if unlocked:
			Profile.select(kind, it.id)
			show_customize()
		else:
			toast("Reach level %d to unlock %s" % [it.level, it.name], true))
	return b


# ---------------------------------------------------------------- profile

func show_profile() -> void:
	_clear()
	_decor()
	var p := _card(860)
	var col := UI.vbox(20)
	col.add_child(_header("Profile", "Your progress is saved on this PC.", show_menu))

	var head := UI.hbox(22)
	head.add_child(_avatar(120))
	var who := UI.vbox(6)
	who.alignment = BoxContainer.ALIGNMENT_CENTER
	who.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	who.add_child(UI.label(_name(), 30, 800))
	who.add_child(UI.label("Level %d  ·  %s  ·  %d XP total" % [Profile.level(), Profile.title(), Profile.xp], 16, 600, UI.ACCENT.lightened(0.4)))
	who.add_child(_xp_bar(560))
	head.add_child(who)
	col.add_child(head)

	var s := Profile.stats
	var rounds := int(s.rounds)
	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 12)
	var tiles := [
		[str(rounds), "Rounds played"], [str(s.wins), "Rounds won"], ["%d%%" % (100 * int(s.wins) / maxi(rounds, 1)), "Win rate"],
		[str(s.best_streak), "Best win streak"], [str(s.cards_played), "Cards played"], [str(s.uno_calls), "UNO calls"],
		[str(s.catches), "Players caught"], ["%d / %d" % [Profile.total_stars(), Cosmetics.STAGES.size() * 3], "Campaign stars"],
	]
	for t in tiles:
		var tile := _stat_tile(t[0], t[1])
		tile.custom_minimum_size = Vector2(190, 84)
		grid.add_child(tile)
	col.add_child(grid)

	col.add_child(UI.toggle("Gameplay hints", "Show tips above your hand during a game.", Profile.prefs.get("hints", true),
		func(on: bool) -> void:
			Profile.prefs.hints = on
			Profile.save()))
	col.add_child(UI.section("Coming up"))
	var nxt := Profile.next_unlocks(5)
	if nxt.is_empty():
		col.add_child(UI.label("You've unlocked everything. Legend.", 16, 600))
	for u in nxt:
		var row := UI.hbox(12)
		var lvl := UI.label("Lv %d" % u.item.level, 16, 800, UI.ACCENT.lightened(0.4))
		lvl.custom_minimum_size = Vector2(60, 0)
		row.add_child(lvl)
		row.add_child(UI.label(Cosmetics.kind_label(u.kind), 15, 500, UI.MUTED))
		row.add_child(UI.label(u.item.name, 16, 700))
		col.add_child(row)
	p.add_child(col)


# ---------------------------------------------------------------- how to play

var _rules_tab := "basics"


func show_rules() -> void:
	_clear()
	_decor()
	var p := _card(1000)
	var col := UI.vbox(18)
	col.add_child(_header("How to Play", "Everything you need to know, from the basics to every house rule.", show_menu))
	col.add_child(UI.segmented([["Basics", "basics"], ["Cards", "cards"], ["House rules", "house"], ["Controls", "controls"]], _rules_tab,
		func(v: String) -> void:
			_rules_tab = v
			show_rules()))
	var body: Control
	match _rules_tab:
		"cards":
			body = Help.cards()
		"house":
			body = Help.house_rules()
		"controls":
			body = Help.controls()
		_:
			body = Help.basics()
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 470)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(body)
	col.add_child(scroll)
	var tip := UI.label("💡  " + Help.random_tip(), 14, 500, UI.MUTED)
	col.add_child(tip)
	p.add_child(col)


# ---------------------------------------------------------------- dialogs

func _dialog(title: String, body: Control) -> void:
	_close_dialog()
	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.02, 0.06, 0.5)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed:
			_close_dialog())
	modal_root.add_child(dim)
	var panel := GlassPanel.new(28, 26)
	panel.tint_alpha = 0.14
	panel.custom_minimum_size = Vector2(460, 0)
	var col := UI.vbox(16)
	col.add_child(UI.label(title, 24, 800))
	col.add_child(body)
	panel.add_child(col)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(panel)
	modal_root.add_child(center)


func _close_dialog() -> void:
	for c in modal_root.get_children():
		c.queue_free()


# ---------------------------------------------------------------- rule presets

## Preset chips + save / share / import. on_apply(settings) is called after
## a preset is written into s.
func _presets_section(s: Dictionary, editable: bool, on_apply: Callable) -> VBoxContainer:
	var col := UI.vbox(8)
	var head := UI.hbox(8)
	var sec := UI.section("Rule presets")
	sec.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(sec)
	if not editable:
		head.add_child(UI.label("The host picks the rules — save them to use in your own lobby", 12, 500, UI.MUTED))
	col.add_child(head)

	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 8)
	flow.add_theme_constant_override("v_separation", 8)
	var user := Presets.load_user()
	for pr in Presets.BUILTIN + user:
		flow.add_child(_preset_chip(pr, s, editable, on_apply, pr in user))
	col.add_child(flow)

	var row := UI.hbox(8)
	var save := UI.button("Save current…", func() -> void: _save_preset_dialog(s), false)
	save.custom_minimum_size = Vector2(0, 36)
	row.add_child(save)
	var share := UI.button("Copy share code", func() -> void:
		DisplayServer.clipboard_set(Presets.encode(Presets.from_settings("Shared rules", s)))
		toast("Share code copied — friends can import it in their lobby"), false)
	share.custom_minimum_size = Vector2(0, 36)
	row.add_child(share)
	if editable:
		var imp := UI.button("Import code…", func() -> void: _import_preset_dialog(s, on_apply), false)
		imp.custom_minimum_size = Vector2(0, 36)
		row.add_child(imp)
	col.add_child(row)
	return col


func _preset_chip(pr: Dictionary, s: Dictionary, editable: bool, on_apply: Callable, is_user: bool) -> Control:
	var active := Presets.matches(pr, s)
	var row := UI.hbox(0)
	var b := Button.new()
	b.text = pr.name
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(0, 36)
	b.tooltip_text = (pr.desc + "\n" if pr.get("desc", "") != "" else "") + Presets.summary(pr)
	b.disabled = not editable and not active
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if editable else Control.CURSOR_ARROW
	var base := Color(UI.ACCENT, 0.85) if active else (Color("ffd24a", 0.12) if is_user else Color(1, 1, 1, 0.07))
	var rim := UI.ACCENT.lightened(0.35) if active else (Color("ffd24a", 0.4) if is_user else Color(1, 1, 1, 0.2))
	for st_name in ["normal", "disabled"]:
		var sb := UI.flat(base, 12, rim, 1)
		sb.content_margin_left = 14
		sb.content_margin_right = 14
		sb.content_margin_top = 4
		sb.content_margin_bottom = 4
		b.add_theme_stylebox_override(st_name, sb)
	var hov := UI.flat(base.lightened(0.15), 12, Color.WHITE, 1)
	hov.content_margin_left = 14
	hov.content_margin_right = 14
	b.add_theme_stylebox_override("hover", hov)
	b.add_theme_color_override("font_disabled_color", Color(1, 1, 1, 0.85) if active else Color(1, 1, 1, 0.35))
	if editable:
		b.pressed.connect(func() -> void:
			Presets.apply_to(pr, s)
			on_apply.call(s)
			toast("Loaded preset “%s”" % pr.name))
	row.add_child(b)
	if is_user:
		var x := UI.button("✕", func() -> void:
			Presets.remove_user(pr.name)
			toast("Deleted preset “%s”" % pr.name)
			_refresh_current())
		x.custom_minimum_size = Vector2(32, 36)
		x.tooltip_text = "Delete this preset"
		row.add_child(x)
	return row


func _save_preset_dialog(s: Dictionary) -> void:
	var body := UI.vbox(12)
	body.add_child(UI.label(Presets.summary(Presets.from_settings("", s)), 14, 500, UI.MUTED))
	var name_edit := UI.line_edit("", "Preset name, e.g. Friday Night", 24)
	body.add_child(name_edit)
	var row := UI.hbox(10)
	row.add_child(UI.spacer(0, 0, true))
	row.add_child(UI.button("Cancel", _close_dialog, false, 110))
	var do_save := func() -> void:
		var n := name_edit.text.strip_edges()
		if n == "":
			toast("Give your preset a name", true)
			return
		Presets.add_user(Presets.from_settings(n, s))
		_close_dialog()
		toast("Saved preset “%s”" % n)
		_refresh_current()
	row.add_child(UI.button("Save preset", do_save, true, 150))
	name_edit.text_submitted.connect(func(_t: String) -> void: do_save.call())
	body.add_child(row)
	_dialog("Save rule preset", body)
	name_edit.grab_focus.call_deferred()


func _import_preset_dialog(s: Dictionary, on_apply: Callable) -> void:
	var body := UI.vbox(12)
	body.add_child(UI.label("Paste a share code (starts with UNO1:)", 14, 500, UI.MUTED))
	var code_edit := UI.line_edit("", "UNO1:…", 400)
	body.add_child(code_edit)
	var keep := {"on": true}
	body.add_child(UI.toggle("Also save to my presets", "Keep it for future lobbies.", true, func(v: bool) -> void: keep.on = v))
	var row := UI.hbox(10)
	row.add_child(UI.spacer(0, 0, true))
	row.add_child(UI.button("Cancel", _close_dialog, false, 110))
	row.add_child(UI.button("Load rules", func() -> void:
		var pr := Presets.decode(code_edit.text)
		if pr.is_empty():
			toast("That doesn't look like a valid share code", true)
			return
		if keep.on:
			pr.name = "Imported %s" % Time.get_time_string_from_system().substr(0, 5)
			Presets.add_user(pr)
		_close_dialog()
		Presets.apply_to(pr, s)
		on_apply.call(s)
		toast("Rules loaded"), true, 150))
	body.add_child(row)
	_dialog("Import rules", body)
	code_edit.grab_focus.call_deferred()


## Re-renders whichever settings screen is showing.
func _refresh_current() -> void:
	if not _last_state.is_empty() and _last_state.get("phase") == "lobby" and not singleplayer:
		_lobby_sig = ""
		show_lobby(_last_state)
	else:
		show_singleplayer()


# ---------------------------------------------------------------- quick play

func _rules_editor(s: Dictionary, editable: bool, on_change: Callable, show_bots: bool) -> VBoxContainer:
	var rules: Dictionary = s.rules
	var col := UI.vbox(14)
	var changed := func() -> void: on_change.call(s)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 10)
	var defs := [
		["stacking", "Stacking", "+2 on +2, +4 on anything. Last one takes it all."],
		["jumpIn", "Jump-in", "Play an identical card out of turn."],
		["sevenO", "Seven-O", "7 swaps hands with a player, 0 rotates all."],
		["drawToMatch", "Draw to match", "Keep drawing until you can play."],
		["forcePlay", "Force play", "A playable drawn card must be played."],
	]
	for d in defs:
		var key: String = d[0]
		var t := UI.toggle(d[1], d[2], rules.get(key, false), func(on: bool) -> void:
			rules[key] = on
			changed.call(), editable)
		t.custom_minimum_size = Vector2(300, 68)
		grid.add_child(t)
	col.add_child(UI.section("House rules"))
	col.add_child(grid)

	var row := UI.hbox(24)
	var hand_col := UI.vbox(6)
	hand_col.add_child(UI.section("Starting hand"))
	hand_col.add_child(UI.stepper(int(rules.get("handSize", 7)), 3, 15, 1, func(v: int) -> String: return "%d cards" % v,
		func(v: int) -> void:
			rules["handSize"] = v
			changed.call(), editable))
	row.add_child(hand_col)
	var score_col := UI.vbox(6)
	score_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	score_col.add_child(UI.section("Match length"))
	score_col.add_child(UI.segmented([["1 round", 0], ["100", 100], ["250", 250], ["500", 500]], int(s.get("targetScore", 0)),
		func(v: int) -> void:
			s["targetScore"] = v
			changed.call(), editable))
	row.add_child(score_col)
	col.add_child(row)

	var row2 := UI.hbox(24)
	var timer_col := UI.vbox(6)
	timer_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	timer_col.add_child(UI.section("Turn timer"))
	timer_col.add_child(UI.segmented([["Off", 0], ["15s", 15], ["30s", 30], ["60s", 60]], int(s.get("turnTime", 0)),
		func(v: int) -> void:
			s["turnTime"] = v
			changed.call(), editable))
	row2.add_child(timer_col)
	if show_bots:
		var diff_col := UI.vbox(6)
		diff_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		diff_col.add_child(UI.section("Bot difficulty"))
		diff_col.add_child(UI.segmented([["Easy", "easy"], ["Normal", "normal"], ["Hard", "hard"]], s.get("difficulty", "normal"),
			func(v: String) -> void:
				s["difficulty"] = v
				changed.call(), editable))
		row2.add_child(diff_col)
	col.add_child(row2)
	return col


func show_singleplayer() -> void:
	_clear()
	_decor()
	var p := _card(680)
	var col := UI.vbox(18)
	col.add_child(_header("Quick Play", "Play against bots with your own house rules.", show_menu))
	col.add_child(UI.section("Opponents"))
	col.add_child(UI.stepper(int(setup.bots), 1, 7, 1, func(v: int) -> String: return "%d bot%s" % [v, "" if v == 1 else "s"],
		func(v: int) -> void:
			setup.bots = v
			_save_config()))
	col.add_child(_presets_section(setup.settings, true, func(_s: Dictionary) -> void:
		_save_config()
		show_singleplayer()))
	col.add_child(_rules_editor(setup.settings, true, func(_s: Dictionary) -> void: _save_config(), true))
	var row := UI.hbox(12)
	row.add_child(UI.spacer(0, 0, true))
	row.add_child(UI.button("Deal cards", func() -> void: _start_singleplayer(int(setup.bots), setup.settings, -1), true, 200))
	col.add_child(row)
	p.add_child(col)


func _start_singleplayer(bots: int, settings: Dictionary, stage: int) -> void:
	var err := Net.start_local_server(Net.LOCAL_PORT, false)
	if err != "":
		toast(err, true)
		return
	singleplayer = true
	campaign_stage = stage
	var s: Dictionary = settings.duplicate(true)
	s.public = false
	var create := func() -> void:
		Net.send({"t": "create", "name": _name(), "bots": bots, "settings": s})
	_connecting("Level %d · %s" % [stage + 1, Cosmetics.STAGES[stage].name] if stage >= 0 else "Shuffling the deck…")
	if Net.is_online():
		create.call()
	else:
		_on_connected = create
		Net.connect_to("127.0.0.1", Net.LOCAL_PORT, 15)


func _connecting(text: String) -> void:
	_clear()
	var p := _card(440)
	var col := UI.vbox(16)
	var l := UI.label(text, 22, 700)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(l)
	var tip := UI.label("💡  " + Help.random_tip(), 14, 500, UI.MUTED)
	tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(tip)
	col.add_child(UI.button("Cancel", func() -> void:
		Net.close()
		show_menu()))
	p.add_child(col)


# ---------------------------------------------------------------- multiplayer

func show_multiplayer() -> void:
	_clear()
	_decor()
	var p := _card(640)
	var col := UI.vbox(16)
	col.add_child(_header("Multiplayer", "Host a table on this PC for friends on your network, or connect to any UNO server.", show_menu))

	col.add_child(UI.section("Server"))
	var row := UI.hbox(10)
	var addr := UI.line_edit(server_addr, "host or host:port")
	addr.text_changed.connect(func(t: String) -> void:
		server_addr = t.strip_edges()
		_save_config())
	row.add_child(addr)
	row.add_child(UI.button("Browse rooms", _browse, false, 160))
	col.add_child(row)

	var host_btn := UI.button("Host on this PC", _host_local, true)
	host_btn.tooltip_text = "Starts a server on port %d and creates a room" % Net.DEFAULT_PORT
	var join_row := UI.hbox(10)
	var code := UI.line_edit("", "Room code", 4)
	code.custom_minimum_size.x = 160
	code.size_flags_horizontal = Control.SIZE_FILL
	join_row.add_child(code)
	join_row.add_child(UI.button("Join", func() -> void: _join(code.text), false, 120))
	code.text_submitted.connect(func(t: String) -> void: _join(t))
	join_row.add_child(UI.spacer(0, 0, true))
	join_row.add_child(UI.button("Create room on server", _create_remote, false))
	col.add_child(host_btn)
	col.add_child(join_row)

	col.add_child(UI.section("Open rooms"))
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 180)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_rooms_box = UI.vbox(8)
	_rooms_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rooms_box.add_child(UI.label("Press “Browse rooms” to look for open tables.", 15, 500, UI.MUTED))
	scroll.add_child(_rooms_box)
	col.add_child(scroll)
	p.add_child(col)


func _parse_addr() -> Array:
	var host := server_addr if server_addr != "" else "127.0.0.1"
	var port := Net.DEFAULT_PORT
	var i := host.rfind(":")
	if i > 0:
		port = int(host.substr(i + 1))
		host = host.substr(0, i)
	return [host, port]


## Connects to the configured server (if not already) and then runs then.
func _with_server(then: Callable) -> void:
	if Net.is_online():
		then.call()
		return
	_on_connected = then
	var a := _parse_addr()
	Net.connect_to(a[0], a[1], 1)


func _browse() -> void:
	_with_server(func() -> void: Net.send({"t": "list"}))


func _mp_settings() -> Dictionary:
	var s: Dictionary = setup.settings.duplicate(true)
	s.public = true
	if int(s.turnTime) == 0:
		s.turnTime = 30
	return s


func _host_local() -> void:
	var err := Net.start_local_server(Net.DEFAULT_PORT, true)
	if err != "":
		toast(err, true)
		return
	server_addr = "127.0.0.1"
	_save_config()
	var s := _mp_settings()
	_on_connected = func() -> void:
		Net.send({"t": "create", "name": _name(), "bots": 0, "settings": s})
	_connecting("Starting server…")
	Net.connect_to("127.0.0.1", Net.DEFAULT_PORT, 15)


func _create_remote() -> void:
	var s := _mp_settings()
	_with_server(func() -> void: Net.send({"t": "create", "name": _name(), "bots": 0, "settings": s}))


func _join(code: String) -> void:
	code = code.strip_edges().to_upper()
	if code.length() != 4:
		toast("Room codes are 4 letters", true)
		return
	_with_server(func() -> void: Net.send({"t": "join", "name": _name(), "code": code}))


func _show_rooms(rooms: Array) -> void:
	if _rooms_box == null or not is_instance_valid(_rooms_box):
		return
	for c in _rooms_box.get_children():
		c.queue_free()
	if rooms.is_empty():
		_rooms_box.add_child(UI.label("No open rooms right now — host one!", 15, 500, UI.MUTED))
	for r in rooms:
		var row := UI.hbox(12)
		var l := UI.label("%s's table" % r.host, 17, 650)
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(l)
		row.add_child(UI.label("%d / %d" % [r.players, r.max], 15, 500, UI.MUTED))
		row.add_child(UI.label(r.code, 15, 800))
		var code: String = r.code
		row.add_child(UI.button("Join", func() -> void: _join(code), true, 90))
		_rooms_box.add_child(row)


# ---------------------------------------------------------------- lobby

func show_lobby(st: Dictionary) -> void:
	# Rebuild only when something visible changed, so toggles don't flicker.
	var sig := JSON.stringify([st.players, st.settings, st.host])
	if sig == _lobby_sig:
		return
	_clear()
	_lobby_sig = sig
	var is_host: bool = st.host == st.you
	var p := _card(760)
	var col := UI.vbox(18)

	var head := UI.hbox(16)
	var t := _title("Lobby", "Share the code with friends. The host picks the rules.")
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(t)
	var code_btn := UI.button(st.code, func() -> void:
		DisplayServer.clipboard_set(st.code)
		toast("Room code copied"))
	code_btn.add_theme_font_override("font", UI.font(900))
	code_btn.add_theme_font_size_override("font_size", 32)
	code_btn.custom_minimum_size = Vector2(170, 64)
	code_btn.tooltip_text = "Click to copy"
	head.add_child(code_btn)
	col.add_child(head)
	if is_host and not singleplayer:
		var ips := Net.local_ips()
		if not ips.is_empty():
			col.add_child(UI.label("Friends on your network connect to:  %s" % "  ·  ".join(ips), 14, 500, UI.MUTED))

	col.add_child(UI.section("Players  %d / %d" % [st.players.size(), st.settings.get("maxPlayers", 8)]))
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 10)
	for pl in st.players:
		var chip := PanelContainer.new()
		chip.add_theme_stylebox_override("panel", UI.flat(Color(1, 1, 1, 0.07), 14, Color(1, 1, 1, 0.15), 1))
		chip.custom_minimum_size = Vector2(340, 0)
		var row := UI.hbox(10)
		var av := SeatView.Avatar.new()
		av.letter = str(pl.name).substr(0, 1).to_upper()
		av.color = UI.avatar_color(pl.name)
		av.is_bot = pl.bot
		av.frame = pl.get("frame", "")
		av.level = int(pl.get("level", 0))
		row.add_child(av)
		var nm: String = pl.name + ("  (you)" if pl.id == st.you else "") + ("  ♛" if pl.host else "")
		var l := UI.label(nm, 17, 650)
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		l.size_flags_vertical = Control.SIZE_FILL
		row.add_child(l)
		if pl.bot:
			row.add_child(UI.label(str(pl.get("difficulty", "")).capitalize(), 14, 500, UI.MUTED))
			if is_host:
				var id: String = pl.id
				var x := UI.button("✕", func() -> void: Net.send({"t": "remove_bot", "target": id}))
				x.custom_minimum_size = Vector2(38, 38)
				row.add_child(x)
		chip.add_child(row)
		grid.add_child(chip)
	col.add_child(grid)

	var settings_box := UI.vbox(16)
	settings_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	settings_box.add_child(_presets_section(st.settings.duplicate(true), is_host, func(s: Dictionary) -> void:
		setup.settings = s.duplicate(true)
		_save_config()
		Net.send({"t": "settings", "settings": s})))
	settings_box.add_child(_rules_editor(st.settings.duplicate(true), is_host, func(s: Dictionary) -> void:
		setup.settings = s.duplicate(true)
		_save_config()
		Net.send({"t": "settings", "settings": s}), true))
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(0, 400)
	scroll.add_child(settings_box)
	col.add_child(scroll)

	var row := UI.hbox(12)
	row.add_child(UI.button("Leave", _leave, false, 120))
	row.add_child(UI.spacer(0, 0, true))
	if is_host:
		var add := UI.button("+ Add bot", func() -> void: Net.send({"t": "add_bot"}), false, 150)
		add.disabled = st.players.size() >= st.settings.get("maxPlayers", 8)
		row.add_child(add)
		var start := UI.button("Start game", func() -> void: Net.send({"t": "start"}), true, 180)
		start.disabled = st.players.size() < 2
		row.add_child(start)
	else:
		row.add_child(UI.label("Waiting for the host to start…", 16, 500, UI.MUTED))
	col.add_child(row)
	p.add_child(col)


func _leave() -> void:
	Net.send({"t": "leave"})
	if singleplayer:
		var back_to_campaign := campaign_stage >= 0
		Net.close()
		Net.stop_local_servers()
		if back_to_campaign:
			show_campaign()
		else:
			show_menu()


# ---------------------------------------------------------------- progression

func _round_key(st: Dictionary) -> String:
	return "%s/%d" % [st.get("code", ""), int(st.get("round", 0))]


func _track(st: Dictionary) -> void:
	var key := _round_key(st)
	if not _round_track.has(key):
		_round_track[key] = {"played": 0, "uno": 0, "catch": 0, "caught": 0, "drawn": 0}
	var t: Dictionary = _round_track[key]
	var me: String = st.get("you", "")
	for e in st.get("events", []):
		var kind: String = e.get("kind", "")
		var by_me: bool = e.get("player", "") == me
		var at_me: bool = e.get("target", "") == me
		match kind:
			"play", "jumpin":
				if by_me:
					t.played += 1
			"uno":
				if by_me:
					t.uno += 1
			"catch":
				if by_me:
					t["catch"] += 1
				if at_me:
					t.caught += 1
					t.drawn += int(e.get("count", 0))
			"draw", "penalty":
				if by_me:
					t.drawn += int(e.get("count", 0))
			"draw2", "wild4":
				if at_me:
					t.drawn += int(e.get("count", 0))
	if st.get("phase") in ["roundover", "gameover"] and not _awarded.has(key):
		_awarded[key] = _award(st, t)


func _award(st: Dictionary, t: Dictionary) -> Dictionary:
	var me: String = st.get("you", "")
	var won: bool = st.get("winner", "") == me
	var pts := int(st.get("roundPoints", 0))
	var rows := [["Round played", 25]]
	if won:
		rows.append(["Victory", 60])
		if pts > 0:
			rows.append(["Points scored", mini(pts / 2, 100)])
	if t.played > 0:
		rows.append(["Cards played ×%d" % t.played, t.played * 2])
	if t.uno > 0:
		rows.append(["UNO calls", t.uno * 5])
	if t["catch"] > 0:
		rows.append(["Players caught", t["catch"] * 10])
	var target := int(st.get("settings", {}).get("targetScore", 0))
	var match_won: bool = won and st.get("phase") == "gameover" and target > 0
	if match_won:
		rows.append(["Match victory", 100])

	var subtotal := 0
	for r in rows:
		subtotal += int(r[1])
	var humans := 0
	var hard := false
	for p in st.get("players", []):
		if not p.bot:
			humans += 1
		elif p.get("difficulty", "") == "hard":
			hard = true
	if humans > 1:
		rows.append(["Multiplayer bonus", int(subtotal * 0.25)])
	elif hard:
		rows.append(["Hard bots bonus", int(subtotal * 0.3)])

	var stars := 0
	var first_clear := false
	if campaign_stage >= 0 and won:
		stars = 1 + (1 if pts >= 50 else 0) + (1 if t.drawn <= 3 else 0)
		first_clear = Profile.record_stage(campaign_stage, stars)
		if first_clear:
			rows.append(["Level %d cleared" % (campaign_stage + 1), Cosmetics.stage_reward(campaign_stage)])

	var total := 0
	for r in rows:
		total += int(r[1])

	Profile.bump("rounds")
	Profile.bump("cards_played", t.played)
	Profile.bump("uno_calls", t.uno)
	Profile.bump("catches", t["catch"])
	Profile.bump("caught", t.caught)
	if won:
		Profile.bump("wins")
		Profile.bump("points", pts)
		Profile.bump("streak")
		Profile.stats.best_streak = maxi(int(Profile.stats.best_streak), int(Profile.stats.streak))
	else:
		Profile.stats.streak = 0
	if match_won:
		Profile.bump("matches_won")
	var xp_before := Profile.xp
	var res := Profile.add_xp(total)
	res.merge({"rows": rows, "total": total, "stars": stars, "won": won, "xp_before": xp_before, "first_clear": first_clear})
	return res


## Adds XP, stars and campaign buttons to the end-of-round panel.
func _results_hook(st: Dictionary, body: VBoxContainer, buttons: HBoxContainer) -> void:
	var aw: Dictionary = _awarded.get(_round_key(st), {})
	if aw.is_empty():
		return
	if campaign_stage >= 0:
		var stars := int(aw.stars)
		var sl := UI.label("★".repeat(stars) + "☆".repeat(3 - stars), 44, 800, Color("ffd24a") if stars > 0 else Color(1, 1, 1, 0.3))
		sl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		body.add_child(sl)
		body.move_child(sl, 0)
		if not aw.won:
			var tl := UI.label("Level %d failed. Try again!" % (campaign_stage + 1), 16, 600, UI.MUTED)
			tl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			body.add_child(tl)
			body.move_child(tl, 1)

	var xp_box := PanelContainer.new()
	xp_box.add_theme_stylebox_override("panel", UI.flat(Color(1, 1, 1, 0.06), 16, Color(1, 1, 1, 0.12), 1))
	var col := UI.vbox(6)
	for r in aw.rows:
		var row := UI.hbox(8)
		var n := UI.label(r[0], 15, 500, UI.MUTED)
		n.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(n)
		row.add_child(UI.label("+%d" % r[1], 15, 700))
		col.add_child(row)
	var total_row := UI.hbox(8)
	var tn := UI.label("XP earned", 18, 800)
	tn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	total_row.add_child(tn)
	total_row.add_child(UI.label("+%d XP" % aw.total, 18, 900, UI.ACCENT.lightened(0.45)))
	col.add_child(total_row)

	var before := Profile.level_for_xp(int(aw.xp_before))
	var bar := XPBar.new()
	bar.custom_minimum_size = Vector2(420, 12)
	bar.value = float(before.into) / before.need
	col.add_child(bar)
	var lvl_label := UI.label("Level %d" % before.level, 13, 600, UI.MUTED)
	col.add_child(lvl_label)
	bar.animate_to(int(aw.xp_before), Profile.xp, lvl_label)
	xp_box.add_child(col)
	body.add_child(xp_box)

	if int(aw.to) > int(aw.from):
		var lu := UI.label("LEVEL UP!  %d → %d" % [aw.from, aw.to], 26, 900, Color("ffd24a"))
		lu.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		body.add_child(lu)
		for u in aw.unlocks:
			var chip := PanelContainer.new()
			chip.add_theme_stylebox_override("panel", UI.flat(Color(UI.ACCENT, 0.25), 12, Color(UI.ACCENT, 0.6), 1))
			var l := UI.label("Unlocked  %s: %s" % [Cosmetics.kind_label(u.kind), u.item.name], 15, 700)
			l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			chip.add_child(l)
			body.add_child(chip)

	if campaign_stage >= 0:
		if aw.won and campaign_stage + 1 < Cosmetics.STAGES.size():
			var nxt := campaign_stage + 1
			buttons.add_child(UI.button("Next level →", func() -> void: _goto_stage(nxt), true, 170))
		buttons.add_child(UI.button("Levels", func() -> void:
			_leave(), false, 110))


func _goto_stage(i: int) -> void:
	_after_left = func() -> void: _start_stage(i)
	Net.send({"t": "leave"})


# ---------------------------------------------------------------- network

func _net_connected() -> void:
	Net.send({"t": "hello", "name": _name(), "profile": Profile.net_profile()})
	if _on_connected.is_valid():
		var cb := _on_connected
		_on_connected = Callable()
		cb.call()


func _net_disconnected(reason: String) -> void:
	_on_connected = Callable()
	if reason != "":
		toast(reason, true)
	if table != null or _last_state.size() > 0 or singleplayer:
		_last_state = {}
		show_menu()


func _net_message(msg: Dictionary) -> void:
	match msg.get("t"):
		"state":
			_last_state = msg
			_track(msg)
			if msg.phase == "lobby":
				if singleplayer:
					Net.send({"t": "start"})
				else:
					show_lobby(msg)
			else:
				if table == null:
					_clear()
					table = Table.new()
					table.leave_requested.connect(_leave)
					table.results_hook = _results_hook
					screen_root.add_child(table)
				table.apply_state(msg)
		"rooms":
			_show_rooms(msg.get("rooms", []))
		"emote":
			if table:
				table.show_emote(msg.player, msg.text)
		"error":
			if table:
				table.toast(msg.msg, true)
			else:
				toast(msg.msg, true)
		"left":
			_last_state = {}
			if _after_left.is_valid():
				var cb := _after_left
				_after_left = Callable()
				_clear()
				cb.call()
			elif not singleplayer:
				show_menu()


func toast(text: String, error: bool = false) -> void:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", UI.flat(Color(UI.DANGER, 0.92) if error else Color(0.1, 0.1, 0.18, 0.92), 14, Color(1, 1, 1, 0.2), 1))
	p.add_child(UI.label(text, 16, 600))
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	toast_root.add_child(p)
	await get_tree().process_frame
	p.position = Vector2(size.x * 0.5 - p.size.x * 0.5, size.y - p.size.y - 40)
	var tw := p.create_tween()
	tw.tween_interval(3.0)
	tw.tween_property(p, "modulate:a", 0.0, 0.4)
	tw.tween_callback(p.queue_free)


# ---------------------------------------------------------------- widgets

class XPBar extends Control:
	var value := 0.0:
		set(v):
			value = v
			queue_redraw()

	## Animates across levels from one XP total to another.
	func animate_to(from_xp: int, to_xp: int, label: Label) -> void:
		var step := func(x: float) -> void:
			var info := Profile.level_for_xp(int(x))
			value = 1.0 if info.max else float(info.into) / info.need
			label.text = "Level %d  ·  %d / %d XP" % [info.level, info.into, info.need]
		var start := func() -> void:
			var tw := create_tween()
			tw.tween_interval(0.5)
			tw.tween_method(step, float(from_xp), float(to_xp), 1.4).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		if is_inside_tree():
			start.call()
		else:
			ready.connect(start, CONNECT_ONE_SHOT)

	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		var sb := StyleBoxFlat.new()
		sb.set_corner_radius_all(int(size.y * 0.5))
		sb.bg_color = Color(1, 1, 1, 0.1)
		draw_style_box(sb, r)
		if value > 0.0:
			var f := StyleBoxFlat.new()
			f.set_corner_radius_all(int(size.y * 0.5))
			f.bg_color = UI.ACCENT.lightened(0.15)
			f.shadow_color = Color(UI.ACCENT, 0.6)
			f.shadow_size = 8
			draw_style_box(f, Rect2(Vector2.ZERO, Vector2(maxf(size.y, size.x * clampf(value, 0, 1)), size.y)))


class ThemeSwatch extends Control:
	var theme_def := {}

	func _init() -> void:
		custom_minimum_size = Vector2(170, 150)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		var sb := StyleBoxFlat.new()
		sb.set_corner_radius_all(16)
		sb.bg_color = Color(theme_def.get("bottom", "000000"))
		sb.border_color = Color(1, 1, 1, 0.3)
		sb.set_border_width_all(1)
		draw_style_box(sb, r)
		var spots := [Vector2(0.25, 0.3), Vector2(0.75, 0.28), Vector2(0.7, 0.75), Vector2(0.3, 0.72)]
		var blobs: Array = theme_def.get("blobs", [])
		for i in blobs.size():
			var c := Color(blobs[i])
			for k in 6:
				draw_circle(spots[i] * size, 46 - k * 7, Color(c, 0.1 + k * 0.05))


## Slowly drifting cards behind the menus (the glass blurs them nicely).
class FloatingCards extends Control:
	var _cards := []

	func _ready() -> void:
		set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		var colors := ["red", "yellow", "green", "blue"]
		var values := ["7", "skip", "reverse", "draw2", "3", "9", "0"]
		var rng := RandomNumberGenerator.new()
		rng.randomize()
		for i in 11:
			var c := {}
			if i % 4 == 3:
				c = {"id": -1, "color": "wild", "value": "wild4" if i % 8 == 3 else "wild"}
			elif i % 5 != 4:
				c = {"id": -1, "color": colors[rng.randi() % 4], "value": values[rng.randi() % values.size()]}
			var v := CardView.make(c)
			v.modulate.a = 0.55
			var s := rng.randf_range(0.7, 1.25)
			v.scale = Vector2(s, s)
			v.position = Vector2(rng.randf_range(0, 1600), rng.randf_range(0, 900))
			v.rotation = rng.randf_range(-PI, PI)
			add_child(v)
			_cards.append({"v": v, "vel": Vector2(rng.randf_range(-14, 14), rng.randf_range(-20, -6)), "spin": rng.randf_range(-0.15, 0.15)})

	func _process(delta: float) -> void:
		for c in _cards:
			var v: CardView = c.v
			v.position += c.vel * delta
			v.rotation += c.spin * delta
			if v.position.y < -220:
				v.position.y = size.y + 60
			if v.position.x < -200:
				v.position.x = size.x + 60
			elif v.position.x > size.x + 200:
				v.position.x = -160
