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
var server_addr := Release.server()
var singleplayer := false
var campaign_stage := -1
var _on_connected: Callable
var _after_left: Callable
var _last_state: Dictionary = {}
var _rooms_box: VBoxContainer
var _lobby_sig := ""
var _round_track := {}  # "code/round" -> counters for XP
var _awarded := {}  # "code/round" -> award result
var _screen := ""  # which rebuildable screen is showing (menu, account, friends)
var _account_mode := "login"
var _acct_draft := {}  # what's typed in the account form, kept across rebuilds
var _busy_node: Control  # the "Signing in…" popup
var _reconnecting := false  # trying to get back into an online game after a drop
var _rejoin_until := 0.0  # keep retrying until then (ticks, seconds)
var _chat: Array = []  # this room's chat, newest last
var _chat_box: ChatBox
var _chat_draft := ""
var _countdown: Label  # Quick Match "Starting in…"
var updater := Updater.new()
var _quick_at := 0.0

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
	Online.notice.connect(func(kind: String, text: String) -> void:
		if text != "":
			Audio.play("error" if kind == "error" else "notify")
			toast(text, kind == "error"))
	Online.invited.connect(_on_invited)
	Online.outdated.connect(_show_outdated)
	Online.status_changed.connect(_on_online_changed)
	Online.friends_changed.connect(func() -> void:
		if _screen == "friends":
			show_friends()
		elif _screen == "menu" and not get_viewport().gui_get_focus_owner() is LineEdit:
			show_menu())
	Net.connected.connect(_net_connected)
	Net.disconnected.connect(_net_disconnected)
	Net.message.connect(_net_message)
	show_menu()
	_debug_args()
	add_child(updater)
	_announce_update()
	# Look for an update once the boot screen is gone.
	get_tree().create_timer(3.0).timeout.connect(func() -> void: _check_updates(false))
	if Net.has_rejoinable_seat():
		get_tree().create_timer(2.5).timeout.connect(func() -> void:
			if Net.has_rejoinable_seat() and not Net.is_online():
				toast_action("You dropped out of an online game.", "Rejoin", _try_rejoin))
	# Branded boot screen on top of the (already built) menu.
	var skip_loader := false
	for a in OS.get_cmdline_user_args():
		if Release.dev_flags() and (a == "--demo" or a.begins_with("--stage=") or a.begins_with("--screen=")):
			skip_loader = true
	if not skip_loader:
		add_child(LoadingScreen.new())


func _apply_cosmetics() -> void:
	var th := Cosmetics.find("theme", Profile.selected.theme)
	bg_mat.set_shader_parameter("base_top", Color(th.top))
	bg_mat.set_shader_parameter("base_bottom", Color(th.bottom))
	for i in 4:
		bg_mat.set_shader_parameter("blob%d" % (i + 1), Color(th.blobs[i]))
	CardView.default_back = Profile.selected.back


## Dev helpers:  godot --path client -- --demo --screen=campaign --shot=out.png@6 --autoplay --xp=900
func _debug_args() -> void:
	if not Release.dev_flags():
		return
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
				"options":
					show_options()
				"account":
					show_account()
				"friends":
					show_friends()
		elif a.begins_with("--signin="):
			# --signin=host:port,user,password
			var parts := a.get_slice("=", 1).split(",")
			if parts.size() == 3:
				Online.sign_in(parts[0], parts[1], parts[2], false)
		elif a.begins_with("--register="):
			# --register=host:port,user,password,invite
			var parts := a.get_slice("=", 1).split(",")
			if parts.size() == 4:
				Online.sign_in(parts[0], parts[1], parts[2], true, parts[3])
		elif a.begins_with("--feedback="):
			var fb_text := a.get_slice("=", 1)
			get_tree().create_timer(2.0).timeout.connect(func() -> void:
				Online.send_feedback("bug", fb_text, _feedback_info(), _log_tail()))
		elif a == "--whats-new":
			_whats_new.call_deferred()
		elif a == "--auto-update":
			set_meta("auto_update", true)  # press "Update now" by itself (testing)
		elif a.begins_with("--connect="):
			server_addr = a.get_slice("=", 1)
		elif a.begins_with("--mp="):
			# --mp=quick | create | join:CODE  (on the --connect server)
			var what := a.get_slice("=", 1)
			if what == "quick":
				_quick.call_deferred()
			elif what == "create":
				_create_lobby.call_deferred()
			elif what.begins_with("join:"):
				_join.call_deferred(what.get_slice(":", 1))
		elif a.begins_with("--stage="):
			_start_stage.call_deferred(int(a.get_slice("=", 1)))
		elif a.begins_with("--fake-win="):
			_fake_win.call_deferred(int(a.get_slice("=", 1)))
		elif a.begins_with("--fake-replay="):
			# win, "Play again" (new match, round 1 again), win again
			var st_i := int(a.get_slice("=", 1))
			_fake_win.call_deferred(st_i, 1)
			get_tree().create_timer(4.0).timeout.connect(func() -> void: _fake_win(st_i, 2))
		elif a == "--fake-private":
			_fake_win.call_deferred(-1, 1, true)
		elif a == "--quick" or a.begins_with("--quick="):
			# 3-card hands so a round ends in seconds (for testing).
			# --quick = quick play vs 1 easy bot; --quick=N = campaign level N (0-based).
			var stage := int(a.get_slice("=", 1)) if "=" in a else -1
			var qs: Dictionary = Cosmetics.stage_settings(maxi(stage, 0))
			qs.rules.handSize = 3
			var bots: int = Cosmetics.STAGES[stage].bots if stage >= 0 else 1
			_start_singleplayer.call_deferred(bots, qs, stage)
		elif a.begins_with("--shot="):
			var spec := a.get_slice("=", 1)
			var path := spec.get_slice("@", 0)
			var secs := float(spec.get_slice("@", 1))
			quit_at = maxf(quit_at, secs + 0.5)
			get_tree().create_timer(secs).timeout.connect(func() -> void:
				var img := get_viewport().get_texture().get_image()
				if path.ends_with(".jpg"):  # website screenshots: 1600x900 JPEG
					img.resize(1600, 900, Image.INTERPOLATE_LANCZOS)
					img.save_jpg(path, 0.86)
				else:
					img.save_png(path))
	if quit_at > 0:
		get_tree().create_timer(quit_at).timeout.connect(func() -> void:
			Net.stop_local_servers()
			get_tree().quit())


## Dev: drive the end-of-round flow with a canned "you won" state, no server.
## --fake-win=N plays it as campaign level N (0-based), -1 for quick play.
func _fake_win(stage: int, match_no: int = 1, private_guest: bool = false) -> void:
	campaign_stage = stage
	singleplayer = not private_guest
	var me := "p1"
	var players := [
		{"id": me, "name": _name(), "cards": 0, "bot": false, "host": not private_guest, "score": 93, "vulnerable": false},
		{"id": "b2", "name": "Orbit", "cards": 1, "bot": true, "difficulty": "easy", "host": false, "score": 0, "vulnerable": false, "back": "classic"},
		{"id": "b3", "name": "Kiwi", "cards": 9, "bot": true, "difficulty": "easy", "host": false, "score": 0, "vulnerable": false, "back": "neon"},
	]
	var settings := Cosmetics.stage_settings(maxi(stage, 0))
	settings.public = false
	if private_guest:
		players[1].bot = false
		players[1].name = "Sam"
	var base := {"t": "state", "code": "TEST", "you": me, "host": "b2" if private_guest else me, "settings": settings, "players": players,
		"round": 1, "match": match_no, "hand": [], "top": {"id": 101, "color": "wild", "value": "wild4"}, "color": "blue",
		"dir": 1, "drawPile": 77, "pending": 0, "playable": [], "drawn": -1, "events": []}
	var playing := base.duplicate(true)
	playing.phase = "playing"
	playing.turn = me
	playing.hand = [{"id": 101, "color": "wild", "value": "wild4"}]
	_net_message(playing)
	await get_tree().create_timer(0.6).timeout
	var over := base.duplicate(true)
	over.phase = "gameover"
	over.winner = me
	over.roundPoints = 93
	over.events = [{"kind": "play", "player": me, "card": {"id": 101, "color": "wild", "value": "wild4"}, "color": "blue"},
		{"kind": "wild4", "player": me, "target": "b3", "count": 4}, {"kind": "win", "player": me}]
	_net_message(over)


func _process(_d: float) -> void:
	if _countdown != null and Engine.get_process_frames() % 10 == 0:
		_update_countdown()
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
		if not Release.is_release():  # release builds always use the official server
			server_addr = cf.get_value("net", "server", Release.server())
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


## The name others see: your account name when signed in, otherwise the
## name typed on the menu (for offline play).
func _name() -> String:
	if Online.is_signed_in() and Online.username != "":
		return Online.username
	return player_name if player_name != "" else "Player"


# ---------------------------------------------------------------- screen helpers

func _clear() -> void:
	_screen = ""
	for c in screen_root.get_children():
		c.queue_free()
	table = null
	_lobby_sig = ""
	_rooms_box = null


func _decor() -> void:
	Audio.music("menu")
	if not Settings.v("reduce_motion"):
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
	b.custom_minimum_size = Vector2(0, 66)
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
	_screen = "menu"
	singleplayer = false
	campaign_stage = -1
	_decor()
	var row := UI.hbox(36)
	row.alignment = BoxContainer.ALIGNMENT_CENTER

	# Left: logo + navigation.
	var left := UI.vbox(12)
	left.custom_minimum_size = Vector2(440, 0)
	var wm := TextureRect.new()
	wm.texture = preload("res://branding/wordmark.svg")
	wm.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	wm.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT
	wm.custom_minimum_size = Vector2(430, 176)
	var shine := ShaderMaterial.new()
	shine.shader = preload("res://shaders/shimmer.gdshader")
	shine.set_shader_parameter("strength", 0.4)
	wm.material = shine
	var tw := wm.create_tween().set_loops()
	tw.tween_method(func(v: float) -> void: shine.set_shader_parameter("sweep", v), -0.5, 1.6, 2.2)
	tw.tween_interval(3.5)
	left.add_child(wm)
	var tag := "v%s" % Release.version()
	if Release.channel() == "beta":
		tag += "  ·  CLOSED BETA"
	left.add_child(UI.label(tag, 16, 600, UI.MUTED))
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
	left.add_child(_nav("Multiplayer", "Quick Match, create or join a lobby", show_multiplayer))
	var pair := UI.hbox(12)
	pair.add_child(_nav("Customize", "Backs · themes · frames", show_customize))
	pair.add_child(_nav("Profile", "Stats & unlocks", show_profile))
	left.add_child(pair)
	var pair2 := UI.hbox(12)
	var fr_sub := "Sign in to add friends"
	if Online.is_signed_in():
		fr_sub = "%d online" % Online.online_friends().size()
		if Online.incoming.size() > 0:
			fr_sub += "  ·  %d request%s" % [Online.incoming.size(), "" if Online.incoming.size() == 1 else "s"]
	pair2.add_child(_nav("Friends", fr_sub, show_friends))
	pair2.add_child(_nav("Options", "Audio · display · gameplay", show_options))
	left.add_child(pair2)
	var bottom := UI.hbox(12)
	var how := UI.button("How to Play", show_rules)
	how.custom_minimum_size = Vector2(0, 42)
	how.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bottom.add_child(how)
	var fb := UI.button("Feedback", _feedback_dialog)
	fb.custom_minimum_size = Vector2(0, 42)
	fb.tooltip_text = "Report a bug or share an idea"
	bottom.add_child(fb)
	var quit := UI.button("Quit", func() -> void: get_tree().quit())
	quit.custom_minimum_size = Vector2(110, 42)
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
	var name_edit := UI.line_edit(_name(), "Enter a name", 16)
	if Online.is_signed_in():
		# Online you're always your account; the offline name returns on sign-out.
		name_edit.editable = false
		name_edit.tooltip_text = "Your account name. Everyone sees this, online and off."
		col.add_child(name_edit)
		col.add_child(UI.label("Your account name. Sign out to use a different name offline.", 12, 500, UI.MUTED))
	else:
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

	if Online.is_signed_in():
		var acc := UI.button("☁  Signed in as %s" % Online.username, show_account)
		acc.tooltip_text = "Your progress syncs to your account"
		col.add_child(acc)
	else:
		var acc := UI.button("Sign in / create account" if Online.status != "connecting" else "Connecting…", show_account)
		acc.tooltip_text = "Sync progress and play with friends"
		col.add_child(acc)
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
		[str(s.best_streak), "Best win streak"], [str(s.cards_played), "Cards played"], [str(s.uno_calls), "GLINT calls"],
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


## A popup with a spinner while something's happening; Cancel calls on_cancel.
func _busy(text: String, on_cancel: Callable) -> void:
	if _busy_node != null and is_instance_valid(_busy_node):
		_busy_node.get_node("%BusyText").text = text
		return
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.02, 0.06, 0.55)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(dim)
	var panel := GlassPanel.new(28, 26)
	panel.tint_alpha = 0.14
	panel.custom_minimum_size = Vector2(380, 0)
	var col := UI.vbox(18)
	var spin := RingSpinner.new()
	spin.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	col.add_child(spin)
	var l := UI.label(text, 20, 700)
	l.name = "BusyText"
	l.unique_name_in_owner = true
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(l)
	col.add_child(UI.button("Cancel", func() -> void:
		_unbusy()
		on_cancel.call()))
	panel.add_child(col)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.add_child(panel)
	root.add_child(center)
	modal_root.add_child(root)
	l.owner = root
	_busy_node = root


func _unbusy() -> void:
	if _busy_node != null and is_instance_valid(_busy_node):
		_busy_node.queue_free()
	_busy_node = null


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
	body.add_child(UI.label("Paste a share code (starts with GLINT1:)", 14, 500, UI.MUTED))
	var code_edit := UI.line_edit("", "GLINT1:…", 400)
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
	var err := Net.start_local_server(Net.LOCAL_PORT, false, false)
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
	if Net.is_online() and Net.connected_to("127.0.0.1", Net.LOCAL_PORT):
		create.call()
	else:
		_on_connected = create
		Net.connect_to("127.0.0.1", Net.LOCAL_PORT, 15)


func _connecting(text: String) -> void:
	_clear()
	var p := _card(440)
	var col := UI.vbox(16)
	var spin := LoadingScreen.CardSpinner.new()
	spin.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	col.add_child(spin)
	var l := UI.label(text, 22, 700)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(l)
	var tip := UI.label("💡  " + Help.random_tip(), 14, 500, UI.MUTED)
	tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(tip)
	col.add_child(UI.button("Cancel", func() -> void:
		_reconnecting = false
		Net.close()
		show_menu()))
	p.add_child(col)


# ---------------------------------------------------------------- multiplayer

func show_multiplayer() -> void:
	_clear()
	_decor()
	_screen = "multi"
	var p := _card(760)
	var col := UI.vbox(16)
	col.add_child(_header("Multiplayer", "Play with friends or anyone online.", show_menu))

	var quick := UI.button("⚡  Quick Match", _quick, true)
	quick.custom_minimum_size = Vector2(0, 64)
	quick.add_theme_font_size_override("font_size", 22)
	quick.tooltip_text = "Join a 4-player table with other players. Bots fill any empty seats."
	col.add_child(quick)

	var halves := UI.hbox(24)
	var create := UI.vbox(10)
	create.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	create.add_child(UI.section("Create a lobby"))
	var vis_note := UI.label("", 13, 500, UI.MUTED)
	vis_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var set_note := func() -> void:
		vis_note.text = "Listed below for anyone to join." if setup.get("lobby_public", true) \
			else "Hidden. Share the code with your friends."
	set_note.call()
	create.add_child(UI.segmented([["Public", true], ["Private", false]], setup.get("lobby_public", true), func(v: bool) -> void:
		setup.lobby_public = v
		_save_config()
		set_note.call()))
	create.add_child(vis_note)
	create.add_child(UI.button("Create lobby", _create_lobby, true))
	halves.add_child(create)

	var join := UI.vbox(10)
	join.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	join.add_child(UI.section("Join with a code"))
	var code := UI.line_edit("", "4-letter code", 4)
	code.text_submitted.connect(func(t: String) -> void: _join(t))
	join.add_child(code)
	join.add_child(UI.label("Ask the host for their lobby code.", 13, 500, UI.MUTED))
	join.add_child(UI.button("Join", func() -> void: _join(code.text)))
	halves.add_child(join)
	col.add_child(halves)

	var head := UI.hbox(10)
	var sec := UI.section("Open lobbies")
	sec.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(sec)
	head.add_child(UI.button("Refresh", _browse, false, 110))
	col.add_child(head)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 200)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_rooms_box = UI.vbox(8)
	_rooms_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rooms_box.add_child(UI.label("Looking for open lobbies…", 15, 500, UI.MUTED))
	scroll.add_child(_rooms_box)
	col.add_child(scroll)
	p.add_child(col)

	# Keep the list fresh while this screen is open.
	_browse()
	var t := Timer.new()
	t.wait_time = 6.0
	t.autostart = true
	t.timeout.connect(func() -> void:
		if _screen == "multi" and Net.is_online():
			Net.send({"t": "list"}))
	p.add_child(t)


func _parse_addr() -> Array:
	var host := server_addr if server_addr != "" else "127.0.0.1"
	var port := Net.DEFAULT_PORT
	var i := host.rfind(":")
	if i > 0:
		port = int(host.substr(i + 1))
		host = host.substr(0, i)
	return [host, port]


## Connects to the game server (if not already) and then runs then.
func _with_server(then: Callable) -> void:
	var a := _parse_addr()
	if Net.is_online() and Net.connected_to(a[0], a[1]):
		then.call()
		return
	singleplayer = false
	_on_connected = then
	var retries := 1
	if not Release.is_release() and Release.is_local(a[0]):
		# Dev builds: run a server on this PC if there isn't one.
		Net.start_local_server(int(a[1]), false)
		retries = 15
	Net.connect_to(a[0], a[1], retries)


func _quick() -> void:
	_with_server(func() -> void: Net.send({"t": "quick", "name": _name()}))


## Reconnects to the server we dropped from and asks for our seat back.
func _try_rejoin() -> void:
	var s := Net.seat
	if s.is_empty():
		return
	singleplayer = false
	if not _reconnecting:
		_rejoin_until = Time.get_ticks_msec() / 1000.0 + 90.0
	_reconnecting = true
	_connecting("Reconnecting to your game…")
	_on_connected = func() -> void:
		Net.send({"t": "rejoin", "code": s.code, "token": s.token})
	Net.connect_to(str(s.host), int(s.port), 10)


func _browse() -> void:
	_with_server(func() -> void: Net.send({"t": "list"}))


func _create_lobby() -> void:
	var s: Dictionary = setup.settings.duplicate(true)
	s.public = setup.get("lobby_public", true)
	if int(s.turnTime) == 0:
		s.turnTime = 30
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
		_rooms_box.add_child(UI.label("No open lobbies right now. Create one, or try Quick Match!", 15, 500, UI.MUTED))
	for r in rooms:
		var row := UI.hbox(12)
		var l := UI.label("Quick Match" if r.get("quick", false) else "%s's table" % r.host, 17, 650)
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(l)
		row.add_child(UI.label("%d / %d" % [r.players, r.max], 15, 500, UI.MUTED))
		row.add_child(UI.label(r.code, 15, 800))
		var code: String = r.code
		row.add_child(UI.button("Join", func() -> void: _join(code), true, 90))
		_rooms_box.add_child(row)


# ---------------------------------------------------------------- lobby

func show_lobby(st: Dictionary) -> void:
	if st.get("quick", false):
		_quick_at = Time.get_ticks_msec() / 1000.0 + float(st.get("startsIn", 0.0))
	# Rebuild only when something visible changed, so toggles don't flicker.
	var sig := JSON.stringify([st.players, st.settings, st.host])
	if sig == _lobby_sig:
		return
	# Keep a half-typed chat message across the rebuild.
	var typing := _chat_box != null and is_instance_valid(_chat_box) and _chat_box.input.has_focus()
	if _chat_box != null and is_instance_valid(_chat_box):
		_chat_draft = _chat_box.input.text
	_clear()
	_lobby_sig = sig
	var is_host: bool = st.host == st.you
	var quick: bool = st.get("quick", false)
	var show_chat: bool = Settings.v("chat") and not singleplayer
	var p := _card(1160 if show_chat else 760)
	var outer := UI.hbox(28)
	var col := UI.vbox(18)
	col.custom_minimum_size = Vector2(760, 0)
	outer.add_child(col)

	var head := UI.hbox(16)
	var t := _title("Quick Match", "Starts by itself. Bots fill any empty seats.") if quick \
		else _title("Lobby", "Share the code with friends. The host picks the rules.")
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
	if not singleplayer and not quick:
		var public: bool = st.settings.get("public", true)
		var vis := UI.hbox(12)
		if is_host:
			vis.add_child(UI.segmented([["Public", true], ["Private", false]], public, func(v: bool) -> void:
				setup.lobby_public = v
				_save_config()
				Net.send({"t": "settings", "settings": {"public": v}})))
		var vl := UI.label("Public: anyone can join from the lobby list." if public else "Private: only people with the code can join.", 14, 500, UI.MUTED)
		vl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		vl.size_flags_vertical = Control.SIZE_FILL
		vis.add_child(vl)
		col.add_child(vis)

	col.add_child(UI.section("Players  %d / %d" % [st.players.size(), st.settings.get("maxPlayers", 8)]))
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 10)
	var waiting_on := []  # players the host is waiting on to ready up
	for pl in st.players:
		grid.add_child(_lobby_chip(pl, st, is_host, quick))
		if not pl.bot and not pl.host and not pl.get("ready", false):
			waiting_on.append(pl.name)
	col.add_child(grid)

	var settings_box := UI.vbox(16)
	settings_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var editable := is_host and not quick
	if quick:
		settings_box.add_child(UI.label("Standard rules · 7 cards · %ds turns · one round" % int(st.settings.get("turnTime", 20)), 15, 600, UI.MUTED))
	if not quick:
		settings_box.add_child(_presets_section(st.settings.duplicate(true), editable, func(s: Dictionary) -> void:
			setup.settings = s.duplicate(true)
			_save_config()
			Net.send({"t": "settings", "settings": s})))
	settings_box.add_child(_rules_editor(st.settings.duplicate(true), editable, func(s: Dictionary) -> void:
		setup.settings = s.duplicate(true)
		_save_config()
		Net.send({"t": "settings", "settings": s}), true))
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(0, 360)
	scroll.add_child(settings_box)
	col.add_child(scroll)

	var row := UI.hbox(12)
	row.add_child(UI.button("Leave", _leave, false, 120))
	if Online.is_signed_in() and not singleplayer:
		row.add_child(UI.button("Invite friends", _invite_dialog, false, 150))
	row.add_child(UI.spacer(0, 0, true))
	if quick:
		_countdown = UI.label("", 16, 600, UI.MUTED)
		_countdown.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_countdown.size_flags_vertical = Control.SIZE_FILL
		row.add_child(_countdown)
		if is_host:
			var now := UI.button("Start now", func() -> void: Net.send({"t": "start"}), true, 160)
			now.tooltip_text = "Start right away. Bots take the empty seats."
			row.add_child(now)
	elif is_host:
		var add := UI.button("+ Add bot", func() -> void: Net.send({"t": "add_bot"}), false, 150)
		add.disabled = st.players.size() >= st.settings.get("maxPlayers", 8)
		row.add_child(add)
		var start := UI.button("Start game", func() -> void: Net.send({"t": "start"}), true, 180)
		start.disabled = st.players.size() < 2 or not waiting_on.is_empty()
		if not waiting_on.is_empty():
			start.tooltip_text = "Waiting for %s to get ready" % ", ".join(waiting_on)
		row.add_child(start)
	else:
		var me := {}
		for pl in st.players:
			if pl.id == st.you:
				me = pl
		var ready: bool = me.get("ready", false)
		row.add_child(UI.label("Waiting for the host…" if ready else "Ready up so the host can start", 15, 500, UI.MUTED))
		var rb := UI.button("Ready ✓" if ready else "I'm ready", func() -> void: Net.send({"t": "ready", "ready": not ready}), not ready, 160)
		row.add_child(rb)
	col.add_child(row)

	if show_chat:
		_chat_box = ChatBox.new(560)
		_chat_box.custom_minimum_size = Vector2(320, 0)
		_chat_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
		_chat_box.set_history(_chat)
		_chat_box.input.text = _chat_draft
		outer.add_child(_chat_box)
		if typing:
			_chat_box.input.grab_focus.call_deferred()
			_chat_box.input.caret_column = _chat_draft.length()
	p.add_child(outer)
	_update_countdown()


func _lobby_chip(pl: Dictionary, st: Dictionary, is_host: bool, quick: bool) -> PanelContainer:
	var chip := PanelContainer.new()
	var ready: bool = pl.get("ready", false) and not pl.host
	chip.add_theme_stylebox_override("panel", UI.flat(Color(1, 1, 1, 0.07), 14, Color(UI.SUCCESS, 0.6) if ready else Color(1, 1, 1, 0.15), 1))
	chip.custom_minimum_size = Vector2(370, 0)
	var row := UI.hbox(8)
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
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	row.add_child(l)
	var id: String = pl.id
	var small := func(text: String, tip: String, cb: Callable) -> Button:
		var b := UI.button(text, cb)
		b.custom_minimum_size = Vector2(38, 38)
		b.tooltip_text = tip
		return b
	if pl.bot:
		row.add_child(UI.label(str(pl.get("difficulty", "")).capitalize(), 14, 500, UI.MUTED))
		if is_host:
			row.add_child(small.call("✕", "Remove bot", func() -> void: Net.send({"t": "remove_bot", "target": id})))
	else:
		if ready:
			row.add_child(UI.label("Ready", 14, 700, UI.SUCCESS))
		if is_host and id != st.you:
			var who: String = pl.name
			if not quick:
				row.add_child(small.call("♛", "Make %s the host" % who, func() -> void: Net.send({"t": "make_host", "target": id})))
			row.add_child(small.call("✕", "Remove %s from the room" % who, func() -> void: _confirm_kick(id, who)))
	chip.add_child(row)
	return chip


func _confirm_kick(id: String, who: String) -> void:
	var body := UI.vbox(16)
	var l := UI.label("%s will be removed and can't rejoin this room." % who, 16, 500, UI.MUTED)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(380, 0)
	body.add_child(l)
	var row := UI.hbox(10)
	row.add_child(UI.spacer(0, 0, true))
	row.add_child(UI.button("Cancel", _close_dialog))
	var kick := UI.button("Remove", func() -> void:
		Net.send({"t": "kick", "target": id})
		_close_dialog())
	UI.style_button(kick, Color(UI.DANGER, 0.8))
	row.add_child(kick)
	body.add_child(row)
	_dialog("Remove %s?" % who, body)


func _update_countdown() -> void:
	if _countdown == null or not is_instance_valid(_countdown):
		return
	var left := ceili(_quick_at - Time.get_ticks_msec() / 1000.0)
	_countdown.text = "Starting in %ds" % left if left > 0 else "Starting…"


func _leave() -> void:
	Net.send({"t": "leave"})
	Net.clear_seat()
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
	# Includes the match: "Play again" restarts at round 1 in the same room.
	return "%s/%d/%d" % [st.get("code", ""), int(st.get("match", 0)), int(st.get("round", 0))]


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
		rows.append(["GLINT calls", t.uno * 5])
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

	if campaign_stage >= 0 and int(aw.stars) > 0:
		Audio.play("star")
	if int(aw.to) > int(aw.from):
		get_tree().create_timer(1.2).timeout.connect(func() -> void: Audio.play("level_up"))
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


# ---------------------------------------------------------------- options

func show_options() -> void:
	_clear()
	_decor()
	var p := _card(1040)
	var col := UI.vbox(18)
	col.add_child(_header("Options", "Changes apply instantly and are saved on this PC.", show_menu))
	col.add_child(_options_body())
	p.add_child(col)


func _options_body() -> HBoxContainer:
	var cols := UI.hbox(36)
	var left := UI.vbox(14)
	left.custom_minimum_size = Vector2(470, 0)
	var right := UI.vbox(14)
	right.custom_minimum_size = Vector2(470, 0)
	cols.add_child(left)
	cols.add_child(right)
	var setv := func(k: String) -> Callable:
		return func(val: Variant) -> void: Settings.set_value(k, val)

	left.add_child(UI.section("Audio"))
	left.add_child(UI.slider("Master", Settings.v("master"), setv.call("master")))
	left.add_child(UI.slider("Music", Settings.v("music"), setv.call("music")))
	left.add_child(UI.slider("Sound effects", Settings.v("sfx"), func(val: float) -> void:
		Settings.set_value("sfx", val)
		if Engine.get_process_frames() % 6 == 0:
			Audio.play("card_play")))
	left.add_child(UI.slider("Interface", Settings.v("ui"), setv.call("ui")))
	left.add_child(UI.toggle("Mute everything", "Silence all audio.", Settings.v("mute"), setv.call("mute")))

	left.add_child(UI.section("Display"))
	left.add_child(UI.toggle("Fullscreen", "Use the whole screen (F11 isn't bound — toggle it here).", Settings.v("fullscreen"), setv.call("fullscreen")))
	left.add_child(UI.toggle("V-Sync", "Sync to your monitor's refresh rate to avoid tearing.", Settings.v("vsync"), setv.call("vsync")))
	var fps := UI.vbox(6)
	fps.add_child(UI.label("Frame rate limit", 15, 600, UI.MUTED))
	fps.add_child(UI.segmented([["Unlimited", 0], ["30", 30], ["60", 60], ["120", 120], ["144", 144]], int(Settings.v("max_fps")), setv.call("max_fps")))
	left.add_child(fps)
	var scale := UI.vbox(6)
	scale.add_child(UI.label("Interface size", 15, 600, UI.MUTED))
	scale.add_child(UI.segmented([["90%", 0.9], ["100%", 1.0], ["110%", 1.1], ["125%", 1.25]], float(Settings.v("ui_scale")), setv.call("ui_scale")))
	left.add_child(scale)

	right.add_child(UI.section("Gameplay"))
	right.add_child(UI.toggle("Gameplay hints", "Tips above your hand, like when to call GLINT.", Profile.prefs.get("hints", true),
		func(on: bool) -> void:
			Profile.prefs.hints = on
			Profile.save()))
	right.add_child(UI.toggle("Turn timer ticks", "Tick during the last 5 seconds of your turn.", Settings.v("timer_ticks"), setv.call("timer_ticks")))
	right.add_child(UI.toggle("Keyboard hints", "Show shortcut keys on the action buttons.", Settings.v("key_hints"), setv.call("key_hints")))
	right.add_child(UI.toggle("Chat", "Show chat in online lobbies and games.", Settings.v("chat"), setv.call("chat")))
	right.add_child(UI.toggle("Reduce motion", "No screen shake, confetti or floating menu cards.", Settings.v("reduce_motion"), setv.call("reduce_motion")))

	right.add_child(UI.section("Account & data"))
	var acct := "Signed in as %s" % Online.username if Online.is_signed_in() else "Not signed in — progress is saved on this PC only."
	var al := UI.label(acct, 14, 500, UI.MUTED)
	al.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	right.add_child(al)
	var row := UI.hbox(10)
	row.add_child(UI.button("Account…", func() -> void:
		_close_dialog()
		if table == null:
			show_account()))
	row.add_child(UI.button("Reset options", func() -> void:
		Settings.reset_defaults()
		toast("Options reset")
		if table == null:
			show_options()))
	row.add_child(UI.button("Feedback…", _feedback_dialog))
	row.add_child(UI.button("Check for updates", func() -> void: _check_updates(true)))
	var reset := UI.button("Reset progress…", _confirm_reset_progress)
	UI.style_button(reset, Color(UI.DANGER, 0.7))
	row.add_child(reset)
	right.add_child(row)
	return cols


func _confirm_reset_progress() -> void:
	var body := UI.vbox(14)
	var l := UI.label("This wipes your XP, level, stats, campaign stars and equipped cosmetics on this PC. Your account copy (if signed in) keeps its higher XP.", 15, 500, UI.MUTED)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(420, 0)
	body.add_child(l)
	var row := UI.hbox(10)
	row.add_child(UI.spacer(0, 0, true))
	row.add_child(UI.button("Cancel", _close_dialog, false, 110))
	var go := UI.button("Reset everything", func() -> void:
		Profile.reset()
		_close_dialog()
		toast("Progress reset")
		show_menu(), false, 180)
	UI.style_button(go, UI.DANGER)
	row.add_child(go)
	body.add_child(row)
	_dialog("Reset progress?", body)


# ---------------------------------------------------------------- account

func _on_online_changed() -> void:
	if not Online.pending:
		_unbusy()
	if Online.is_signed_in():
		_acct_draft.clear()  # don't keep passwords around
	match _screen:
		"account":
			show_account()
		"friends":
			show_friends()
		"menu":
			if not get_viewport().gui_get_focus_owner() is LineEdit:
				show_menu()


func show_account() -> void:
	_clear()
	_decor()
	_screen = "account"
	var p := _card(560)
	var col := UI.vbox(16)
	col.add_child(_header("Account", "Sync your progress and play with friends.", show_menu))
	if Online.is_signed_in():
		var head := UI.hbox(16)
		var av := _avatar(80)
		av.letter = Online.username.substr(0, 1).to_upper()
		av.color = UI.avatar_color(Online.username)
		head.add_child(av)
		var who := UI.vbox(4)
		who.alignment = BoxContainer.ALIGNMENT_CENTER
		who.add_child(UI.label(Online.username, 26, 800))
		who.add_child(UI.label("Level %d  ·  progress syncs automatically" % Profile.level(), 14, 600, UI.ACCENT.lightened(0.4)))
		head.add_child(who)
		col.add_child(head)
		var row := UI.hbox(10)
		row.add_child(UI.button("Friends", show_friends, true, 140))
		row.add_child(UI.spacer(0, 0, true))
		row.add_child(UI.button("Sign out", func() -> void:
			Online.sign_out()
			toast("Signed out")
			show_account(), false, 120))
		col.add_child(row)
		p.add_child(col)
		return

	col.add_child(UI.segmented([["Sign in", "login"], ["Create account", "register"]], _account_mode, func(v: String) -> void:
		_account_mode = v
		show_account()))
	col.add_child(UI.section("Username"))
	var keep := func(e: LineEdit, key: String) -> void:
		e.text = _acct_draft.get(key, e.text)
		e.text_changed.connect(func(t: String) -> void: _acct_draft[key] = t)
	var user := UI.line_edit(Online.username, "3–16 letters, numbers or _", 16)
	keep.call(user, "user")
	col.add_child(user)
	col.add_child(UI.section("Password"))
	var pw := UI.line_edit("", "At least 8 characters", 128)
	pw.secret = true
	keep.call(pw, "pw")
	col.add_child(pw)
	var pw2: LineEdit
	var invite: LineEdit
	if _account_mode == "register":
		pw2 = UI.line_edit("", "Repeat password", 128)
		pw2.secret = true
		keep.call(pw2, "pw2")
		col.add_child(pw2)
		col.add_child(UI.section("Beta invite code"))
		invite = UI.line_edit("", "GLINT-XXXX-XXXX (from the developer)", 20)
		keep.call(invite, "invite")
		col.add_child(invite)
	if Online.last_error != "" and not Online.pending:
		var err := UI.label(Online.last_error, 14, 600, UI.DANGER)
		err.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		col.add_child(err)
	if Online.pending:
		_busy("Creating your account…" if _account_mode == "register" else "Signing in…", Online.cancel_pending)
	else:
		_unbusy()
	var submit := func() -> void:
		if pw2 != null and pw2.text != pw.text:
			toast("Passwords don't match", true)
			return
		if user.text.strip_edges().length() < 3 or pw.text.length() < 8:
			toast("Enter a username (3+) and password (8+)", true)
			return
		Online.sign_in(Online.addr, user.text, pw.text, _account_mode == "register", invite.text if invite else "")
	var go := UI.button("Create account" if _account_mode == "register" else "Sign in", submit, true)
	go.custom_minimum_size.y = 52
	col.add_child(go)
	pw.text_submitted.connect(func(_t: String) -> void: submit.call())
	var note := UI.label("Your account keeps your level and unlocks safe, lets you add friends and invite them to your lobby.", 13, 500, UI.MUTED)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(note)
	p.add_child(col)


# ---------------------------------------------------------------- friends

var _friends_timer: Timer


func show_friends() -> void:
	_clear()
	_decor()
	_screen = "friends"
	var p := _card(780)
	var col := UI.vbox(16)
	col.add_child(_header("Friends", "See who's online, join their table or invite them to yours.", show_menu))
	if not Online.is_signed_in():
		col.add_child(UI.label("Sign in to add friends and see when they're online.", 16, 500, UI.MUTED))
		col.add_child(UI.button("Sign in / create account", show_account, true))
		p.add_child(col)
		return
	if _friends_timer == null:
		_friends_timer = Timer.new()
		_friends_timer.wait_time = 6.0
		_friends_timer.timeout.connect(func() -> void:
			if _screen == "friends":
				Online.refresh_friends())
		add_child(_friends_timer)
	_friends_timer.start()

	var add_row := UI.hbox(10)
	var name_edit := UI.line_edit("", "Add a friend by username", 16)
	add_row.add_child(name_edit)
	var add := func() -> void:
		if name_edit.text.strip_edges() != "":
			Online.add_friend(name_edit.text)
			name_edit.text = ""
	add_row.add_child(UI.button("Add friend", add, true, 140))
	name_edit.text_submitted.connect(func(_t: String) -> void: add.call())
	col.add_child(add_row)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 460)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var list := UI.vbox(10)
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)
	col.add_child(scroll)

	if Online.incoming.size() > 0:
		list.add_child(UI.section("Friend requests"))
		for n in Online.incoming:
			var row := _friend_row(n, "Wants to be your friend", Color("ffd24a"))
			row.add_child(UI.button("Accept", func() -> void: Online.accept(n), true, 100))
			row.add_child(UI.button("Decline", func() -> void: Online.decline(n), false, 100))
			list.add_child(_row_panel(row))

	list.add_child(UI.section("Friends  ·  %d online" % Online.online_friends().size()))
	if Online.friends.is_empty():
		list.add_child(UI.label("No friends yet — add someone by their username above.", 15, 500, UI.MUTED))
	for f in Online.friends:
		var st := "Offline"
		var dot := Color(1, 1, 1, 0.3)
		if f.get("online", false):
			st = "Online"
			dot = UI.CARD_COLORS.green
			if f.get("room", "") != "":
				st = "At table %s" % f.room
				dot = UI.CARD_COLORS.yellow
		var row := _friend_row(f.name, "Level %d  ·  %s" % [int(f.get("level", 1)), st], dot)
		var fname: String = f.name
		if f.get("room", "") != "":
			var code: String = f.room
			row.add_child(UI.button("Join", func() -> void: _join(code), true, 90))
		var x := UI.button("✕", func() -> void: _confirm_remove_friend(fname))
		x.custom_minimum_size = Vector2(40, 40)
		x.tooltip_text = "Remove friend"
		row.add_child(x)
		list.add_child(_row_panel(row))

	if Online.outgoing.size() > 0:
		list.add_child(UI.section("Sent requests"))
		for n in Online.outgoing:
			var row := _friend_row(n, "Request pending", Color(1, 1, 1, 0.3))
			row.add_child(UI.button("Cancel", func() -> void: Online.decline(n), false, 100))
			list.add_child(_row_panel(row))
	p.add_child(col)


func _friend_row(name: String, sub: String, dot: Color) -> HBoxContainer:
	var row := UI.hbox(12)
	var av := SeatView.Avatar.new(44)
	av.letter = name.substr(0, 1).to_upper()
	av.color = UI.avatar_color(name)
	row.add_child(av)
	var txt := UI.vbox(0)
	txt.alignment = BoxContainer.ALIGNMENT_CENTER
	txt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	txt.add_child(UI.label(name, 17, 700))
	var s := UI.label("●  " + sub, 13, 600, UI.MUTED)
	s.add_theme_color_override("font_color", dot.lerp(UI.MUTED, 0.35))
	txt.add_child(s)
	row.add_child(txt)
	return row


func _row_panel(row: Control) -> PanelContainer:
	var pc := PanelContainer.new()
	var sb := UI.flat(Color(1, 1, 1, 0.06), 14, Color(1, 1, 1, 0.12), 1)
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	pc.add_theme_stylebox_override("panel", sb)
	pc.add_child(row)
	return pc


func _confirm_remove_friend(name: String) -> void:
	var body := UI.vbox(14)
	var row := UI.hbox(10)
	row.add_child(UI.spacer(0, 0, true))
	row.add_child(UI.button("Cancel", _close_dialog, false, 110))
	var go := UI.button("Remove", func() -> void:
		Online.remove_friend(name)
		_close_dialog(), false, 120)
	UI.style_button(go, UI.DANGER)
	row.add_child(go)
	body.add_child(row)
	_dialog("Remove %s from friends?" % name, body)


func _invite_dialog() -> void:
	Online.refresh_friends()
	var body := UI.vbox(10)
	var on := Online.online_friends()
	if on.is_empty():
		body.add_child(UI.label("None of your friends are online right now.", 15, 500, UI.MUTED))
	for f in on:
		var row := _friend_row(f.name, "At table %s" % f.room if f.get("room", "") != "" else "Online", UI.CARD_COLORS.green)
		var fname: String = f.name
		var b := UI.button("Invite", func() -> void: Online.invite(fname), true, 100)
		row.add_child(b)
		body.add_child(row)
	body.add_child(UI.button("Done", _close_dialog))
	_dialog("Invite friends", body)


func _on_invited(from: String, code: String) -> void:
	Audio.play("notify")
	toast_action("%s invited you to table %s" % [from, code], "Join", func() -> void:
		if singleplayer:
			Net.close()
			Net.stop_local_servers()
			singleplayer = false
			_clear()
			_join(code)
		elif table != null or not _last_state.is_empty():
			_after_left = func() -> void: _join(code)
			Net.send({"t": "leave"})
		else:
			_join(code))


## A toast with a button, shown for longer.
func toast_action(text: String, action: String, cb: Callable) -> void:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", UI.flat(Color(0.1, 0.1, 0.18, 0.95), 16, Color(UI.ACCENT, 0.7), 1))
	var row := UI.hbox(14)
	var l := UI.label(text, 16, 600)
	l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(l)
	row.add_child(UI.button(action, func() -> void:
		p.queue_free()
		cb.call(), true, 90))
	row.add_child(UI.button("✕", p.queue_free))
	p.add_child(row)
	toast_root.add_child(p)
	toast_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	await get_tree().process_frame
	if not is_instance_valid(p):
		return
	p.position = Vector2(size.x - p.size.x - 24, 96)
	var tw := p.create_tween()
	tw.tween_interval(12.0)
	tw.tween_property(p, "modulate:a", 0.0, 0.4)
	tw.tween_callback(p.queue_free)


# ---------------------------------------------------------------- beta

func _show_outdated(msg: Dictionary) -> void:
	# The server wants a newer build: offer the in-game update if there is one.
	_check_updates(true, func() -> void:
		var body := UI.vbox(14)
		var l := UI.label("You have v%s, the server needs v%s or newer. Download the latest beta to keep playing online. Your progress is safe." % [Release.version(), msg.get("min", "?")], 15, 500, UI.MUTED)
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.custom_minimum_size = Vector2(440, 0)
		body.add_child(l)
		var row := UI.hbox(10)
		row.add_child(UI.spacer(0, 0, true))
		row.add_child(UI.button("Later", _close_dialog, false, 100))
		row.add_child(UI.button("Download update", func() -> void:
			OS.shell_open(Release.download_url())
			_close_dialog(), true, 180))
		body.add_child(row)
		_dialog("Update required", body))


# ---------------------------------------------------------------- updates

## After the game was updated (in-game or with the installer), say so once
## and offer the release notes.
func _announce_update() -> void:
	if not Release.is_release():
		return
	var cf := ConfigFile.new()
	cf.load("user://version.cfg")
	var last: String = cf.get_value("version", "last", "")
	var now := Release.version()
	if last == now:
		return
	cf.set_value("version", "last", now)
	cf.save("user://version.cfg")
	if last == "":  # first launch ever (or first with this feature): nothing to announce
		return
	get_tree().create_timer(3.0).timeout.connect(func() -> void:
		Audio.play("notify")
		if Release.notes() != "":
			toast_action("Glint updated to v%s" % now, "What's new", _whats_new)
		else:
			toast("Glint updated to v%s" % now))


func _whats_new() -> void:
	var body := UI.vbox(16)
	var r := RichTextLabel.new()
	r.bbcode_enabled = true
	r.fit_content = true
	r.scroll_active = false
	r.custom_minimum_size = Vector2(520, 0)
	r.add_theme_font_override("normal_font", UI.font(500))
	r.add_theme_font_override("bold_font", UI.font(800))
	r.add_theme_font_override("italics_font", UI.font(500))
	r.add_theme_font_size_override("normal_font_size", 16)
	r.add_theme_font_size_override("bold_font_size", 16)
	r.add_theme_font_size_override("italics_font_size", 16)
	r.text = _md_to_bbcode(Release.notes())
	body.add_child(r)
	var row := UI.hbox(10)
	row.add_child(UI.spacer(0, 0, true))
	row.add_child(UI.button("Nice!", _close_dialog, true, 140))
	body.add_child(row)
	_dialog("What's new in v%s" % Release.version(), body)


## Just enough Markdown for release notes: headings, bullets, bold, italics, code.
static func _md_to_bbcode(md: String) -> String:
	var out := PackedStringArray()
	var bold := RegEx.create_from_string("\\*\\*(.+?)\\*\\*")
	var ital := RegEx.create_from_string("\\*(.+?)\\*")
	var code := RegEx.create_from_string("`(.+?)`")
	for line in md.split("\n"):
		line = line.strip_edges().replace("[", "[lb]")
		if line.begins_with("## ") or line.begins_with("# "):
			continue  # the dialog title already says which version
		var bullet := line.begins_with("- ")
		if bullet:
			line = line.substr(2)
		line = bold.sub(line, "[b]$1[/b]", true)
		line = ital.sub(line, "[i]$1[/i]", true)
		line = code.sub(line, "[b]$1[/b]", true)
		out.append(("  •  " + line) if bullet else line)
	return "\n".join(out).strip_edges()

## Asks the website for a newer version. Shows the update dialog if there is
## one; otherwise calls none_found (manual checks say "up to date").
func _check_updates(manual: bool, none_found: Callable = Callable()) -> void:
	if updater.busy:
		return
	updater.checked.connect(func(info: Dictionary) -> void:
		if not info.is_empty():
			_update_dialog(info)
		elif none_found.is_valid():
			none_found.call()
		elif manual:
			toast("You're on the latest version (v%s)" % Release.version() if Release.is_release() else "Updates are only checked in release builds"),
		CONNECT_ONE_SHOT)
	updater.check()


func _update_dialog(info: Dictionary) -> void:
	var patch: bool = info.mode == "patch"
	var mb := maxf(0.1, float(info.bytes) / 1048576.0)
	var body := UI.vbox(16)
	var text := ("Glint v%s is out (you have v%s). The update is %.1f MB and installs in a few seconds. Your progress and settings are kept." % [info.version, Release.version(), mb]) if patch \
		else ("Glint v%s is out (you have v%s). This one needs the full installer (%d MB). Your progress and settings are kept." % [info.version, Release.version(), roundi(mb)])
	var l := UI.label(text, 15, 500, UI.MUTED)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(460, 0)
	body.add_child(l)
	var bar := XPBar.new()
	bar.custom_minimum_size = Vector2(0, 14)
	bar.visible = false
	body.add_child(bar)
	var status := UI.label("", 14, 600, UI.MUTED)
	status.visible = false
	body.add_child(status)
	var row := UI.hbox(10)
	row.add_child(UI.spacer(0, 0, true))
	var later := UI.button("Later", _close_dialog, false, 110)
	row.add_child(later)
	var go := UI.button("Update now" if patch else "Download", Callable(), true, 180)
	row.add_child(go)
	body.add_child(row)
	var failed := [false]  # set when a download fails; "Try again" then re-checks
	var on_progress := func(done: int, total: int) -> void:
		if is_instance_valid(bar):
			bar.value = float(done) / maxf(1.0, total)
			status.text = "Downloading…  %.1f / %.1f MB" % [done / 1048576.0, total / 1048576.0]
	var on_done := func() -> void:
		if is_instance_valid(status):
			bar.value = 1.0
			status.text = "Restarting Glint…"
		await get_tree().create_timer(0.6).timeout
		updater.apply_and_restart()
	var on_fail := func(msg: String) -> void:
		failed[0] = true
		if is_instance_valid(status):
			status.text = msg
			status.add_theme_color_override("font_color", UI.DANGER)
			go.text = "Try again"
			go.disabled = false
			later.disabled = false
	var unhook := func() -> void:
		for pair in [[updater.progress, on_progress], [updater.downloaded, on_done], [updater.failed, on_fail]]:
			if pair[0].is_connected(pair[1]):
				pair[0].disconnect(pair[1])
	go.pressed.connect(func() -> void:
		if not patch:
			OS.shell_open(Release.download_url())
			_close_dialog()
			return
		if failed[0]:
			# Re-plan: some files may already be in place.
			unhook.call()
			_close_dialog()
			_check_updates(true)
			return
		go.disabled = true
		later.disabled = true
		bar.visible = true
		status.visible = true
		status.text = "Downloading…"
		updater.progress.connect(on_progress)
		updater.downloaded.connect(on_done)
		updater.failed.connect(on_fail)
		updater.download())
	later.pressed.connect(unhook)
	_dialog("Update available", body)
	if has_meta("auto_update") and patch:
		go.pressed.emit.call_deferred()


func _feedback_dialog() -> void:
	var body := UI.vbox(12)
	var cat := {"v": "bug"}
	body.add_child(UI.segmented([["🐞 Bug", "bug"], ["💡 Idea", "idea"], ["💬 Other", "other"]], "bug", func(v: String) -> void: cat.v = v))
	var text := TextEdit.new()
	text.placeholder_text = "What happened? What did you expect? Steps to reproduce help a lot."
	text.custom_minimum_size = Vector2(520, 170)
	text.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	text.add_theme_stylebox_override("normal", UI.flat(Color(0, 0, 0, 0.22), 12, Color(1, 1, 1, 0.18), 1))
	text.add_theme_stylebox_override("focus", UI.flat(Color(0, 0, 0, 0.28), 12, UI.ACCENT.lightened(0.2), 2))
	text.add_theme_color_override("font_color", UI.TEXT)
	text.add_theme_color_override("font_placeholder_color", Color(1, 1, 1, 0.35))
	body.add_child(text)
	var attach := {"on": true}
	body.add_child(UI.toggle("Attach game log", "Helps track down bugs. Contains no passwords.", true, func(v: bool) -> void: attach.on = v))
	var note := UI.label("Sent to the beta server along with your game version, OS and screen size%s." % (" and username" if Online.is_signed_in() else ""), 12, 500, UI.MUTED)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(note)
	var row := UI.hbox(10)
	row.add_child(UI.spacer(0, 0, true))
	row.add_child(UI.button("Cancel", _close_dialog, false, 110))
	row.add_child(UI.button("Send feedback", func() -> void:
		if text.text.strip_edges().length() < 5:
			toast("Tell us a little more first", true)
			return
		Online.send_feedback(cat.v, text.text, _feedback_info(), _log_tail() if attach.on else "")
		_close_dialog()
		toast("Sending feedback…"), true, 160))
	body.add_child(row)
	_dialog("Send feedback", body)
	text.grab_focus.call_deferred()


func _feedback_info() -> Dictionary:
	var info := {
		"version": Release.version(),
		"channel": Release.channel(),
		"os": OS.get_name(),
		"os_version": OS.get_version(),
		"locale": OS.get_locale(),
		"screen": "%dx%d" % [DisplayServer.screen_get_size().x, DisplayServer.screen_get_size().y],
		"window": "%dx%d" % [get_viewport().get_visible_rect().size.x, get_viewport().get_visible_rect().size.y],
		"gpu": RenderingServer.get_video_adapter_name(),
		"level": Profile.level(),
		"screen_name": _screen,
		"in_game": table != null,
	}
	if table != null:
		info.phase = table.st.get("phase", "")
		info.round = table.st.get("round", 0)
		info.rules = table.st.get("settings", {}).get("rules", {})
	return info


func _log_tail() -> String:
	var f := FileAccess.open("user://logs/godot.log", FileAccess.READ)
	if f == null:
		return ""
	var n := f.get_length()
	f.seek(maxi(0, n - 12000))
	return f.get_buffer(mini(n, 12000)).get_string_from_utf8()


# ---------------------------------------------------------------- network

func _net_connected() -> void:
	var hello := {"t": "hello", "name": _name(), "profile": Profile.net_profile(), "version": Release.version()}
	if Online.is_signed_in():
		hello.token = Online.token
	Net.send(hello)
	if _on_connected.is_valid():
		var cb := _on_connected
		_on_connected = Callable()
		cb.call()


func _net_disconnected(reason: String) -> void:
	_on_connected = Callable()
	if _reconnecting and Time.get_ticks_msec() / 1000.0 < _rejoin_until:
		# Still flaky: try again shortly (until the deadline).
		get_tree().create_timer(2.0).timeout.connect(func() -> void:
			if _reconnecting and not Net.is_online():
				_try_rejoin())
		return
	if _reconnecting:  # gave up
		_reconnecting = false
		_last_state = {}
		toast("Couldn't reconnect. You can rejoin from the menu for a few minutes.", true)
		show_menu()
		return
	# Dropped out of an online game: get straight back in.
	if not singleplayer and _last_state.size() > 0 and not Net.seat.is_empty():
		_try_rejoin()
		return
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
					table.options_requested.connect(func() -> void: _dialog("Options", _options_body()))
					Audio.music("game")
					table.results_hook = _results_hook
					table.singleplayer = singleplayer
					screen_root.add_child(table)
				table.apply_state(msg)
		"rooms":
			_show_rooms(msg.get("rooms", []))
		"seat":
			if _reconnecting:
				_reconnecting = false
				toast("You're back in the game")
		"rejoin_failed":
			var was_lobby: bool = _last_state.get("phase", "") == "lobby"
			var code: String = Net.seat.get("code", "")
			_reconnecting = false
			Net.clear_seat()
			if was_lobby and code != "":
				Net.send({"t": "join", "name": _name(), "code": code})
			else:
				_last_state = {}
				toast("Couldn't rejoin: %s" % msg.get("msg", "the game has ended"), true)
				show_menu()
		"chat_history":
			var items = msg.get("items")
			_chat = items if items is Array else []
			if _chat_box != null and is_instance_valid(_chat_box):
				_chat_box.set_history(_chat)
		"chat":
			_chat.append(msg)
			if _chat.size() > 60:
				_chat.pop_front()
			if _chat_box != null and is_instance_valid(_chat_box):
				_chat_box.add(msg)
			if table:
				table.add_chat(msg)
		"kicked":
			Net.clear_seat()
			_last_state = {}
			Audio.play("error")
			toast(msg.get("msg", "You were removed from the room."), true)
			_after_left = show_multiplayer
			Net.send({"t": "leave"})
		"outdated":
			_show_outdated(msg)
		"emote":
			if table:
				table.show_emote(msg.player, msg.text)
		"error":
			Audio.play("error")
			if table:
				table.toast(msg.msg, true)
			else:
				toast(msg.msg, true)
		"left":
			_last_state = {}
			_chat = []
			Net.clear_seat()
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


## A spinning ring for "please wait" popups.
class RingSpinner extends Control:
	var angle := 0.0

	func _init() -> void:
		custom_minimum_size = Vector2(64, 64)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _process(delta: float) -> void:
		angle = fmod(angle + delta * TAU * 1.1, TAU)
		queue_redraw()

	func _draw() -> void:
		var c := size * 0.5
		var r := minf(size.x, size.y) * 0.5 - 5.0
		draw_arc(c, r, 0.0, TAU, 64, Color(1, 1, 1, 0.12), 6.0, true)
		# The arc breathes between short and long as it spins.
		var span := lerpf(0.6, 2.2, 0.5 + 0.5 * sin(angle * 2.0))
		draw_arc(c, r, angle, angle + span, 48, UI.ACCENT.lightened(0.25), 6.0, true)


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
