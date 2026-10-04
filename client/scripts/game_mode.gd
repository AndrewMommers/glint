class_name GameMode
extends RefCounted
## Which game in the Glint library this copy is running. The website's play
## page picks it with ?game=… (blackjack, glint-cards); dev runs use --game=….

const CARDS := "cards"
const BLACKJACK := "blackjack"

static var current := CARDS


static func detect() -> void:
	var wanted := ""
	if Release.is_web():
		wanted = str(JavaScriptBridge.eval("new URLSearchParams(location.search).get('game') || ''", true))
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--game="):
			wanted = a.get_slice("=", 1)
	current = BLACKJACK if wanted == "blackjack" else CARDS


static func is_blackjack() -> bool:
	return current == BLACKJACK


## The name the server uses for this game in create / quick / list ("" = Glint Cards).
static func server_name() -> String:
	return "blackjack" if current == BLACKJACK else ""


static func title() -> String:
	return "Blackjack" if current == BLACKJACK else "Glint Cards"
