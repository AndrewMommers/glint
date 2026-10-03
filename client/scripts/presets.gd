class_name Presets
extends RefCounted
## Rule presets: built-in ones plus player-saved ones (user://presets.cfg).
## A preset holds rules, match length and turn timer, and can be shared as a
## short "GLINT1:" code (older "UNO1:" codes still import).

const PATH := "user://presets.cfg"
const CODE_PREFIX := "GLINT1:"
const OLD_PREFIXES := ["UNO1:"]

const BUILTIN := [
	{"name": "Classic", "desc": "Official rules, single round.", "targetScore": 0, "turnTime": 0,
		"rules": {}},
	{"name": "Party", "desc": "Stacking and jump-ins, first to 250.", "targetScore": 250, "turnTime": 30,
		"rules": {"stacking": true, "jumpIn": true}},
	{"name": "No Mercy", "desc": "Stack everything, draw until you match, must play it.", "targetScore": 0, "turnTime": 30,
		"rules": {"stacking": true, "drawToMatch": true, "forcePlay": true}},
	{"name": "Speed", "desc": "Five cards, 15 second turns, jump-ins.", "targetScore": 0, "turnTime": 15,
		"rules": {"handSize": 5, "jumpIn": true}},
	{"name": "Chaos", "desc": "Every house rule at once.", "targetScore": 0, "turnTime": 30,
		"rules": {"stacking": true, "jumpIn": true, "sevenO": true, "drawToMatch": true}},
	{"name": "Marathon", "desc": "Ten-card hands, first to 500.", "targetScore": 500, "turnTime": 60,
		"rules": {"handSize": 10}},
]

const RULE_KEYS := ["handSize", "stacking", "drawToMatch", "forcePlay", "sevenO", "jumpIn"]


static func base_rules() -> Dictionary:
	return {"handSize": 7, "stacking": false, "drawToMatch": false, "forcePlay": false, "sevenO": false, "jumpIn": false}


## Normalised preset dict from anything preset-shaped.
static func normalize(p: Dictionary) -> Dictionary:
	var rules := base_rules()
	var src = p.get("rules", {})
	if src is Dictionary:
		for k in RULE_KEYS:
			if src.has(k):
				rules[k] = int(src[k]) if k == "handSize" else bool(src[k])
	rules.handSize = clampi(int(rules.handSize), 3, 15)
	return {
		"name": str(p.get("name", "Custom")).substr(0, 24),
		"desc": str(p.get("desc", "")),
		"rules": rules,
		"targetScore": clampi(int(p.get("targetScore", 0)), 0, 2000),
		"turnTime": clampi(int(p.get("turnTime", 0)), 0, 120),
	}


static func load_user() -> Array:
	var cf := ConfigFile.new()
	if cf.load(PATH) != OK:
		return []
	var list = cf.get_value("presets", "list", [])
	var out := []
	if list is Array:
		for p in list:
			if p is Dictionary:
				out.append(normalize(p))
	return out


static func save_user(list: Array) -> void:
	var cf := ConfigFile.new()
	cf.set_value("presets", "list", list)
	cf.save(PATH)


static func add_user(p: Dictionary) -> void:
	var list := load_user().filter(func(x: Dictionary) -> bool: return x.name != p.name)
	list.append(normalize(p))
	save_user(list)


static func remove_user(name: String) -> void:
	save_user(load_user().filter(func(x: Dictionary) -> bool: return x.name != name))


## Captures the current settings as a preset.
static func from_settings(name: String, s: Dictionary) -> Dictionary:
	return normalize({"name": name, "rules": s.get("rules", {}), "targetScore": s.get("targetScore", 0), "turnTime": s.get("turnTime", 0)})


## Writes a preset's values into a settings dict (keeps difficulty/public).
static func apply_to(p: Dictionary, s: Dictionary) -> void:
	var n := normalize(p)
	s.rules = n.rules.duplicate()
	s.targetScore = n.targetScore
	s.turnTime = n.turnTime


static func matches(p: Dictionary, s: Dictionary) -> bool:
	var n := normalize(p)
	var cur := normalize({"rules": s.get("rules", {}), "targetScore": s.get("targetScore", 0), "turnTime": s.get("turnTime", 0)})
	return JSON.stringify(n.rules) == JSON.stringify(cur.rules) and n.targetScore == cur.targetScore and n.turnTime == cur.turnTime


static func encode(p: Dictionary) -> String:
	var n := normalize(p)
	n.erase("desc")
	return CODE_PREFIX + Marshalls.utf8_to_base64(JSON.stringify(n))


## Returns the decoded preset, or {} if the code is invalid.
static func decode(code: String) -> Dictionary:
	code = code.strip_edges()
	var prefix := ""
	for p in [CODE_PREFIX] + OLD_PREFIXES:
		if code.begins_with(p):
			prefix = p
	if prefix == "":
		return {}
	var raw := Marshalls.base64_to_utf8(code.substr(prefix.length()))
	var data = JSON.parse_string(raw)
	if data is Dictionary:
		return normalize(data)
	return {}


## One-line summary like "Stacking · Jump-in · 5 cards · first to 250".
static func summary(p: Dictionary) -> String:
	var n := normalize(p)
	var parts := []
	var names := {"stacking": "Stacking", "jumpIn": "Jump-in", "sevenO": "Seven-O", "drawToMatch": "Draw to match", "forcePlay": "Force play"}
	for k in names:
		if n.rules[k]:
			parts.append(names[k])
	if parts.is_empty():
		parts.append("Official rules")
	if n.rules.handSize != 7:
		parts.append("%d cards" % n.rules.handSize)
	parts.append("first to %d" % n.targetScore if n.targetScore > 0 else "1 round")
	if n.turnTime > 0:
		parts.append("%ds turns" % n.turnTime)
	return "  ·  ".join(parts)
