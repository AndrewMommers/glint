# UNO Glass

A modern UNO game with a **Go** authoritative game server and a **Godot 4.6** client with a frosted-glass (glassmorphism) UI.

- **Singleplayer vs bots.** Easy, normal, and hard AI. The Go server runs quietly on your PC.
- **Campaign.** 12 levels that ramp up the bots and house rules. Earn up to 3 stars per level.
- **Multiplayer.** Host on your PC for friends on your LAN, or run a dedicated server. Rooms use 4-letter codes, and there's a room browser, a turn timer, quick reactions, and bot takeover when someone disconnects.
- **House rules:** stacking, jump-in, Seven-O, draw-to-match, force play, custom starting hand, and match length (single round or first to 100/250/500).
- **Rule presets.** Built-in presets (Classic, Party, No Mercy, Speed, Chaos, Marathon), your own saved presets, and shareable `UNO1:` codes. Load them in Quick Play or in any lobby you host. Guests can save the host's rules for their own lobbies.
- **How to Play and hints.** A full rules screen (basics, cards, house rules, controls), an in-game **Rules** panel showing the table's active rules, contextual gameplay hints (which you can turn off in Profile), and tips on loading screens.
- **Progression.** XP, 50 levels and titles, and stats. Card backs, table themes, and avatar frames unlock as you level up. Other players see your card back, frame, and level.

## Quick start

Requirements: [Go 1.22+](https://go.dev/dl/) and [Godot 4.6](https://godotengine.org/download) (the standard build, not .NET).

```powershell
# 1. Build the server into the client folder (the game launches it for singleplayer/hosting)
./build.ps1          # or: go -C server build -o ../client/bin/uno-server.exe .

# 2. Open client/project.godot in Godot and press Play (F5)
```

On macOS/Linux, run `./build.sh` instead (it builds `client/bin/uno-server`).

### Dedicated server

```bash
cd server
go run . -addr :7777
```

Players open **Multiplayer**, enter `your-host:7777`, and then create or join a room. *Host on this PC* does the same thing on the local machine (port 7777, all interfaces). The lobby shows your LAN IPs so friends know where to connect.

### Exporting the game

Export the Godot project as usual, then put `uno-server.exe` (or `uno-server`) **next to the exported executable**. The client looks for it there, in `res://bin/`, and in `../server/`.

## How it fits together

```
┌──────────────────────┐   newline-delimited JSON over TCP   ┌──────────────────────────┐
│ Godot client (GDScript)│ ─────────────────────────────────▶ │ Go server                 │
│  menus, table, FX      │ ◀───────────────────────────────── │  rooms · rules · bots     │
│  local profile/XP      │   per-player "state" + events      │  timers · hidden hands    │
└──────────────────────┘                                     └──────────────────────────┘
```

- **The server is authoritative.** The client only sends intents (`play`, `draw`, `pass`, `uno`, `catch`, …). Every player gets their own view of the state with the other hands hidden, plus a list of events the client animates. The protocol is documented at the top of [`server/protocol.go`](server/protocol.go).
- **`server/uno`** is the pure rules engine plus bot AI, with no networking. It's covered by tests, including thousands of simulated games across all 32 house-rule combinations.
- **Each room runs on its own goroutine.** All of its state is touched only from that goroutine, and timers (bot thinking, turn timeouts, bot catches and jump-ins) are invalidated by a generation counter.
- **Singleplayer** launches `uno-server -addr 127.0.0.1:7778 -idle-exit 30s` and connects to it, so solo and online play run the exact same rules.

### Gameplay rules

- **UNO calls.** Press **UNO!** (or `U`) when you're about to play your second-to-last card, or right after. If you forget, anyone can **Catch** you (`C`) for +2 until the next player acts. Bots call it, and catch you, based on their difficulty.
- **Drawing.** Draw (`D`/Space) when you can't or don't want to play. If the drawn card is playable you can play it or keep it and pass (`P`). Under force play, you must play it.
- **Stacking.** +2 stacks on +2, and +4 stacks on +2 or +4. The first player who can't add to the stack draws all of it.
- **Seven-O.** A 7 makes you pick a player to swap hands with. A 0 rotates every hand in the direction of play.
- **Jump-in.** If you hold the exact same card as the one on top (same color and number/symbol), you can play it out of turn.
- **Scoring.** The round winner scores the cards left in everyone else's hands: number cards at face value, action cards 20, wilds 50.

### Progression

Your progression is stored locally in `user://profile.cfg`. XP comes from playing rounds, winning, points scored, cards played, UNO calls and catches, and match wins. There are bonuses for multiplayer, hard bots, and first-time campaign clears. Campaign stars: ★ for a win, ★★ for scoring 50+ points, ★★★ for drawing 3 cards or fewer.

## Project layout

```
server/                 Go module (no external dependencies)
  main.go               TCP server, client connections, message dispatch
  hub.go                room registry and public room listing
  room.go               lobby, seats, scheduling, per-player state views
  protocol.go           wire format
  uno/                  rules engine, bots and tests
client/                 Godot 4.6 project
  scripts/net.gd        autoload: TCP client and local server launcher
  scripts/profile.gd    autoload: XP, stats, unlocks, campaign stars
  scripts/cosmetics.gd  catalog: backs, themes, frames, titles, campaign levels
  scripts/main.gd       menus, campaign, customize, profile, lobby, XP awards
  scripts/table.gd      the game table and its animations
  scripts/card_view.gd  vector-drawn cards and backs
  scripts/seat_view.gd  player seats, avatars, frames
  scripts/glass_panel.gd + shaders/glass.gdshader   the frosted-glass panel
  shaders/background.gdshader                        animated, themeable aurora background
```

## Development

```bash
cd server && go test ./...
```

Debug launch flags for the client (after `--` on the Godot command line):
`--demo` (start a quick game), `--stage=N` (start campaign level N, counting from 0), `--autoplay` (the client plays for you), `--screen=campaign|customize|profile|single|multi`, `--xp=N` (preview progression), `--shot=path.png@seconds` (save a screenshot, then quit).
