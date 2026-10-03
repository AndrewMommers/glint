class_name Cosmetics
extends RefCounted
## Static catalog: card backs, table themes, avatar frames, titles and the
## campaign levels. Everything unlocks by player level.

const BACKS := [
	{"id": "classic", "name": "Classic", "level": 1, "bg": "161624", "oval": "ff4d6d", "text": "ffd24a"},
	{"id": "midnight", "name": "Midnight", "level": 2, "bg": "0f1a3a", "oval": "c9d6ff", "text": "0f1a3a"},
	{"id": "sunset", "name": "Sunset", "level": 4, "bg": "ff7a59", "bg2": "c2297a", "oval": "fff1e0", "text": "c2297a"},
	{"id": "aurora", "name": "Aurora", "level": 6, "bg": "2b1d6b", "bg2": "0fb5a6", "oval": "ffffff", "text": "5b3fd6"},
	{"id": "neon", "name": "Neon", "level": 9, "bg": "07070d", "outline": "39f5ff", "text": "ff3df2"},
	{"id": "galaxy", "name": "Galaxy", "level": 12, "bg": "120a2e", "bg2": "3a1670", "outline": "b9a6ff", "text": "ffffff", "stars": true},
	{"id": "gold", "name": "Gold Rush", "level": 16, "bg": "151515", "oval": "e8b84a", "text": "151515", "border": "e8b84a"},
	{"id": "prism", "name": "Prism", "level": 20, "bg": "1b1b2b", "rainbow": true, "text": "ffffff"},
]

const THEMES := [
	{"id": "aurora", "name": "Aurora", "level": 1, "top": "090a1a", "bottom": "170b29", "blobs": ["f2385f", "3373ff", "1fcc85", "ffc22e"]},
	{"id": "ocean", "name": "Deep Ocean", "level": 3, "top": "03121f", "bottom": "06263a", "blobs": ["00b4d8", "0077b6", "48cae4", "5e60ce"]},
	{"id": "sunset", "name": "Sunset Strip", "level": 5, "top": "1a0a12", "bottom": "2a0d1a", "blobs": ["ff6b6b", "c44569", "ff9f43", "f8b500"]},
	{"id": "forest", "name": "Forest", "level": 8, "top": "06140d", "bottom": "0d2418", "blobs": ["2ecc71", "16a085", "a3cb38", "1e8449"]},
	{"id": "neon", "name": "Neon City", "level": 11, "top": "05010d", "bottom": "0d0221", "blobs": ["ff00c8", "00f0ff", "7b2fff", "ff2e63"]},
	{"id": "mono", "name": "Monochrome", "level": 14, "top": "0b0b0f", "bottom": "15151c", "blobs": ["9aa0b5", "5c6275", "d0d4e0", "3a3f4f"]},
	{"id": "royal", "name": "Royal", "level": 18, "top": "0d0720", "bottom": "1d0b3a", "blobs": ["8e44ad", "6c5ce7", "e84393", "f1c40f"]},
]

const FRAMES := [
	{"id": "none", "name": "None", "level": 1},
	{"id": "silver", "name": "Silver", "level": 3, "color": "c9d1e0"},
	{"id": "emerald", "name": "Emerald", "level": 7, "color": "2ecc71"},
	{"id": "gold", "name": "Gold", "level": 10, "color": "f5c542"},
	{"id": "rainbow", "name": "Rainbow", "level": 15},
	{"id": "crown", "name": "Crown", "level": 25, "color": "f5c542"},
]

const TITLES := [
	[1, "Rookie"], [3, "Casual"], [5, "Regular"], [8, "Strategist"], [10, "Card Shark"],
	[15, "Wild Master"], [20, "Stack Lord"], [25, "Glint Legend"], [35, "Grandmaster"], [50, "Mythic"],
]

const R_NONE := {}

## Campaign levels: escalating bots and house rules.
const STAGES := [
	{"name": "First Deal", "desc": "Learn the ropes against a single rookie.", "bots": 1, "difficulty": "easy", "rules": {}},
	{"name": "Table for Three", "desc": "Two rookies. Watch the colors.", "bots": 2, "difficulty": "easy", "rules": {}},
	{"name": "Full House", "desc": "Three easy bots, more chaos.", "bots": 3, "difficulty": "easy", "rules": {}},
	{"name": "Getting Serious", "desc": "Bots that actually think.", "bots": 2, "difficulty": "normal", "rules": {}},
	{"name": "Stack Attack", "desc": "+2s and +4s stack. Don't be last.", "bots": 3, "difficulty": "normal", "rules": {"stacking": true}},
	{"name": "Quick Hands", "desc": "Five-card hands and jump-ins.", "bots": 3, "difficulty": "normal", "rules": {"handSize": 5, "jumpIn": true}},
	{"name": "Seven-O Chaos", "desc": "7 swaps, 0 rotates. Nothing is safe.", "bots": 3, "difficulty": "normal", "rules": {"sevenO": true}},
	{"name": "No Mercy Draw", "desc": "Draw until you match — and play it.", "bots": 3, "difficulty": "normal", "rules": {"drawToMatch": true, "forcePlay": true}},
	{"name": "The Sharks", "desc": "Two hard bots that punish mistakes.", "bots": 2, "difficulty": "hard", "rules": {}},
	{"name": "Crowded Table", "desc": "Five sharp opponents at once.", "bots": 5, "difficulty": "hard", "rules": {"stacking": true}},
	{"name": "House of Rules", "desc": "Every house rule, hard bots.", "bots": 3, "difficulty": "hard", "rules": {"stacking": true, "jumpIn": true, "sevenO": true, "drawToMatch": true}},
	{"name": "Grand Finale", "desc": "Seven hard bots. Nine cards. Good luck.", "bots": 7, "difficulty": "hard", "rules": {"handSize": 9, "stacking": true, "jumpIn": true}},
]


static func stage_settings(i: int) -> Dictionary:
	var st: Dictionary = STAGES[i]
	var rules := {"handSize": 7, "stacking": false, "drawToMatch": false, "forcePlay": false, "sevenO": false, "jumpIn": false}
	rules.merge(st.rules, true)
	return {"rules": rules, "turnTime": 0, "targetScore": 0, "difficulty": st.difficulty, "public": false}


static func stage_reward(i: int) -> int:
	return 60 + i * 20


static func list_for(kind: String) -> Array:
	match kind:
		"back":
			return BACKS
		"theme":
			return THEMES
		"frame":
			return FRAMES
	return []


static func find(kind: String, id: String) -> Dictionary:
	for it in list_for(kind):
		if it.id == id:
			return it
	var l := list_for(kind)
	return l[0] if l.size() > 0 else {}


static func title_for(level: int) -> String:
	var t := "Rookie"
	for row in TITLES:
		if level >= row[0]:
			t = row[1]
	return t


## Everything that unlocks exactly at the given level.
static func unlocks_at(level: int) -> Array:
	var out := []
	for kind in ["back", "theme", "frame"]:
		for it in list_for(kind):
			if it.level == level and level > 1:
				out.append({"kind": kind, "item": it})
	for row in TITLES:
		if row[0] == level and level > 1:
			out.append({"kind": "title", "item": {"name": row[1], "level": level}})
	return out


static func kind_label(kind: String) -> String:
	return {"back": "Card back", "theme": "Table theme", "frame": "Avatar frame", "title": "Title"}.get(kind, kind)
