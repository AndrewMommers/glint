class_name Help
extends RefCounted
## How-to-play content, loading-screen tips and in-game hints.

const HOUSE_RULES := [
	["stacking", "Stacking", "When a +2 is played on you, add your own +2 (or a +4) to pass the pile on. A +4 can stack on +2 or +4. The first player who can't stack draws the whole pile."],
	["jumpIn", "Jump-in", "Holding the exact same card as the top of the pile (same color and same number or symbol)? Play it out of turn. Play continues from you."],
	["sevenO", "Seven-O", "Playing a 7 lets you swap hands with any player. Playing a 0 passes every hand to the next player in the direction of play."],
	["drawToMatch", "Draw to match", "Instead of drawing one card, keep drawing until you get one you can play."],
	["forcePlay", "Force play", "If the card you draw is playable, you must play it. No keeping it for later."],
]

const BASICS := [
	["Goal", "Be the first player to get rid of all your cards. The winner scores points for every card left in the other players' hands."],
	["Your turn", "Match the top card of the pile by color, number or symbol, or play a Wild. Playable cards glow and lift up in your hand."],
	["Can't play?", "Draw a card. If it's playable you may play it right away or keep it and pass."],
	["GLINT!", "When you're about to play your second-to-last card, press GLINT!. Forget, and anyone can Catch you before the next player moves: you draw 2."],
	["Scoring", "Number cards are worth their face value, Skip / Reverse / +2 are 20, Wilds are 50. Matches can be a single round or first to 100 / 250 / 500."],
]

const CARDS := [
	[{"color": "red", "value": "7"}, "Number cards", "0 to 9 in four colors. Match by color or number."],
	[{"color": "blue", "value": "skip"}, "Skip", "The next player loses their turn."],
	[{"color": "green", "value": "reverse"}, "Reverse", "Flips the direction of play. With two players it works like a Skip."],
	[{"color": "yellow", "value": "draw2"}, "Draw Two", "The next player draws 2 cards and loses their turn."],
	[{"color": "wild", "value": "wild"}, "Wild", "Play on anything and choose the next color."],
	[{"color": "wild", "value": "wild4"}, "Wild Draw Four", "Choose the color; the next player draws 4 and loses their turn."],
]

const CONTROLS := [
	["Click a glowing card", "Play it (wilds ask for a color, Seven-O 7s ask for a player)"],
	["D  /  Space", "Draw a card, or take a stacked penalty"],
	["P", "Keep the card you drew and pass"],
	["G", "Call GLINT!"],
	["C", "Catch a player who forgot to call GLINT"],
	["💬", "Send a quick reaction"],
]

const TIPS := [
	"Save your Wild cards for when you're stuck. They match everything.",
	"Dump high-value cards early. If someone else goes out, they count against you.",
	"When the next player is down to one card, hit them with a +2, Skip or Reverse.",
	"Change the color to one your opponents haven't been playing.",
	"Press GLINT! before you play your second-to-last card, not after someone notices.",
	"Watch other players' card counts. A forgotten GLINT is a free +2 for you.",
	"With Stacking on, holding a +4 is your insurance against a big pile.",
	"In Seven-O, swap hands with whoever has the fewest cards.",
	"Jump-in works on exact matches only: same color and same number or symbol.",
	"Campaign stars: win for ★, score 50+ points for ★★, draw 3 cards or fewer for ★★★.",
]


static func random_tip() -> String:
	return TIPS[randi() % TIPS.size()]


## Contextual hint for the current table state, or "" when there's nothing useful to say.
static func hint_for(st: Dictionary, me: String, playable: Array, hand: Array) -> String:
	if st.get("phase") != "playing":
		return ""
	if st.get("canCatch", false):
		return "Someone forgot to call GLINT! Catch them for +2 (C)"
	if st.get("canUno", false):
		return "Two cards left: call GLINT! (G) before you play"
	var my_turn: bool = st.get("turn") == me
	var rules: Dictionary = st.get("settings", {}).get("rules", {})
	if not my_turn:
		if playable.size() > 0 and rules.get("jumpIn", false):
			return "Jump-in! You hold an exact match, so play it now"
		return ""
	var pending := int(st.get("pending", 0))
	if pending > 0:
		if playable.is_empty():
			return "You can't stack. Take the +%d (D)" % pending
		return "Stack a +2 / +4 to pass it on, or take the +%d" % pending
	if int(st.get("drawn", -1)) >= 0:
		if rules.get("forcePlay", false):
			return "Force play: you must play the card you drew"
		return "Play the card you drew, or keep it and pass (P)"
	if playable.is_empty():
		return "No playable cards. Draw one (D)"
	# Pressure: next player close to winning?
	var players: Array = st.get("players", [])
	var my_idx := -1
	for i in players.size():
		if players[i].id == me:
			my_idx = i
	if my_idx >= 0 and players.size() > 1:
		var nxt: Dictionary = players[(my_idx + int(st.get("dir", 1)) + players.size()) % players.size()]
		if int(nxt.get("cards", 9)) <= 2:
			for c in hand:
				if int(c.id) in playable and c.value in ["skip", "reverse", "draw2", "wild4"]:
					return "%s is almost out. Slow them down with an action card!" % nxt.name
	var only_wild := true
	for c in hand:
		if int(c.id) in playable and c.color != "wild":
			only_wild = false
	if only_wild:
		return "Only a Wild fits. Pick the color you hold the most of"
	return ""


# ---------------------------------------------------------------- builders

static func _entry(title: String, body: String, title_w: float = 150) -> HBoxContainer:
	var row := UI.hbox(16)
	var t := UI.label(title, 16, 800)
	t.custom_minimum_size = Vector2(title_w, 0)
	t.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	row.add_child(t)
	var b := UI.label(body, 15, 500, Color(1, 1, 1, 0.78))
	b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(b)
	return row


static func basics() -> VBoxContainer:
	var col := UI.vbox(16)
	for e in BASICS:
		col.add_child(_entry(e[0], e[1]))
	return col


static func cards() -> GridContainer:
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 18)
	grid.add_theme_constant_override("v_separation", 18)
	for e in CARDS:
		var row := UI.hbox(14)
		row.custom_minimum_size = Vector2(290, 0)
		var holder := Control.new()
		holder.custom_minimum_size = Vector2(CardView.W * 0.7, CardView.H * 0.7)
		var cv := CardView.make(e[0])
		cv.scale = Vector2(0.7, 0.7)
		cv.pivot_offset = Vector2.ZERO
		holder.add_child(cv)
		row.add_child(holder)
		var txt := UI.vbox(4)
		txt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		txt.alignment = BoxContainer.ALIGNMENT_CENTER
		txt.add_child(UI.label(e[1], 17, 800))
		var d := UI.label(e[2], 14, 500, Color(1, 1, 1, 0.75))
		d.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		txt.add_child(d)
		row.add_child(txt)
		grid.add_child(row)
	return grid


## House rules list. With `active` given, marks which rules are on.
static func house_rules(active: Dictionary = {}) -> VBoxContainer:
	var col := UI.vbox(14)
	for e in HOUSE_RULES:
		var title: String = e[1]
		if not active.is_empty():
			title += "   ✓ ON" if active.get(e[0], false) else "   off"
		var row := _entry(title, e[2], 190)
		if not active.is_empty() and not active.get(e[0], false):
			row.modulate.a = 0.45
		col.add_child(row)
	return col


static func controls() -> VBoxContainer:
	var col := UI.vbox(12)
	for e in CONTROLS:
		col.add_child(_entry(e[0], e[1], 200))
	return col
