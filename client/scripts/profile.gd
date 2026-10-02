extends Node
## Autoload "Profile": the local player's progression, stats, unlocks and
## selected cosmetics, saved to user://profile.cfg.

signal changed

const PATH := "user://profile.cfg"
const MAX_LEVEL := 50

var xp := 0  # lifetime XP
var stats := {
	"rounds": 0, "wins": 0, "matches_won": 0, "cards_played": 0, "uno_calls": 0,
	"catches": 0, "caught": 0, "streak": 0, "best_streak": 0, "points": 0,
}
var selected := {"back": "classic", "theme": "aurora", "frame": "none"}
var campaign := {}  # "stage index" -> best stars (1-3)
var prefs := {"hints": true}


func _ready() -> void:
	var cf := ConfigFile.new()
	if cf.load(PATH) != OK:
		return
	xp = cf.get_value("progress", "xp", 0)
	var s = cf.get_value("progress", "stats", {})
	if s is Dictionary:
		stats.merge(s, true)
	var sel = cf.get_value("cosmetics", "selected", {})
	if sel is Dictionary:
		selected.merge(sel, true)
	var pr = cf.get_value("prefs", "values", {})
	if pr is Dictionary:
		prefs.merge(pr, true)
	var c = cf.get_value("progress", "campaign", {})
	if c is Dictionary:
		campaign = c


func save() -> void:
	var cf := ConfigFile.new()
	cf.set_value("progress", "xp", xp)
	cf.set_value("progress", "stats", stats)
	cf.set_value("progress", "campaign", campaign)
	cf.set_value("cosmetics", "selected", selected)
	cf.set_value("prefs", "values", prefs)
	cf.save(PATH)
	changed.emit()


static func xp_needed(level: int) -> int:
	return 100 + (level - 1) * 40


static func level_for_xp(total: int) -> Dictionary:
	var lvl := 1
	var rest := total
	while lvl < MAX_LEVEL and rest >= xp_needed(lvl):
		rest -= xp_needed(lvl)
		lvl += 1
	return {"level": lvl, "into": rest, "need": xp_needed(lvl), "max": lvl >= MAX_LEVEL}


func level() -> int:
	return level_for_xp(xp).level


func title() -> String:
	return Cosmetics.title_for(level())


## Adds XP and returns {from, to, unlocks: [...]}.
func add_xp(amount: int) -> Dictionary:
	var before := level()
	xp += maxi(amount, 0)
	var after := level()
	var unlocks := []
	for l in range(before + 1, after + 1):
		unlocks.append_array(Cosmetics.unlocks_at(l))
	save()
	return {"from": before, "to": after, "unlocks": unlocks}


func is_unlocked(kind: String, id: String) -> bool:
	return level() >= int(Cosmetics.find(kind, id).get("level", 1))


func select(kind: String, id: String) -> void:
	if is_unlocked(kind, id):
		selected[kind] = id
		save()


func stars(stage: int) -> int:
	return int(campaign.get(str(stage), 0))


func stage_unlocked(stage: int) -> bool:
	return stage == 0 or stars(stage - 1) > 0


func total_stars() -> int:
	var n := 0
	for v in campaign.values():
		n += int(v)
	return n


## Records a campaign result; returns true on the first clear.
func record_stage(stage: int, s: int) -> bool:
	var first := stars(stage) == 0
	if s > stars(stage):
		campaign[str(stage)] = s
	return first


func bump(stat: String, by: int = 1) -> void:
	stats[stat] = int(stats.get(stat, 0)) + by


func net_profile() -> Dictionary:
	return {"back": selected.back, "frame": selected.frame, "level": level()}


## Upcoming unlocks after the current level.
func next_unlocks(count: int) -> Array:
	var out := []
	for l in range(level() + 1, MAX_LEVEL + 1):
		for u in Cosmetics.unlocks_at(l):
			out.append(u)
			if out.size() >= count:
				return out
	return out
