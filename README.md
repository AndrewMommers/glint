<p align="center"><img src="branding/png/social-preview-1280x640.png" alt="Glint" width="100%"></p>

# Glint

> ### ⬇ [Download Glint (closed beta)](https://github.com/AndrewMommers/glint-beta/releases/latest)
> The installer (`Glint-Setup-….exe`) and the portable zip live in the **glint-beta** repo's Releases.
> This repo is the source code.

A modern color-matching card game with a **Go** authoritative game server and a **Godot 4.6** client with a frosted-glass (glassmorphism) UI.

- **Singleplayer vs bots.** Easy, normal, and hard AI. The Go server runs quietly on your PC.
- **Campaign.** 12 levels that ramp up the bots and house rules. Earn up to 3 stars per level.
- **Multiplayer.** Host on your PC for friends on your LAN, or run a dedicated server. Rooms use 4-letter codes, and there's a room browser, a turn timer, quick reactions, and bot takeover when someone disconnects.
- **House rules:** stacking, jump-in, Seven-O, draw-to-match, force play, custom starting hand, and match length (single round or first to 100/250/500).
- **Rule presets.** Built-in presets (Classic, Party, No Mercy, Speed, Chaos, Marathon), your own saved presets, and shareable `GLINT1:` codes. Load them in Quick Play or in any lobby you host. Guests can save the host's rules for their own lobbies.
- **How to Play and hints.** A full rules screen (basics, cards, house rules, controls), an in-game **Rules** panel showing the table's active rules, contextual gameplay hints (which you can turn off in Profile), and tips on loading screens.
- **Accounts and friends.** Register and sign in on any server. Progression syncs to your account. Add friends by username, see who's online and at which table, invite friends to your lobby, and join their tables in one click.
- **Sound and music.** Original synthesized sound effects for every card and action, plus two seamless music loops (menu and in-game). Volumes are mixed on separate Music, SFX and UI buses.
- **Options.** Master, music, SFX and UI volume, mute, fullscreen, V-Sync, an FPS cap, interface size, gameplay hints, turn-timer ticks, keyboard hints, reduce motion, and reset options or progress. Open it from the menu, or in game with ⚙ or Esc.
- **Progression.** XP, 50 levels and titles, and stats. Card backs, table themes, and avatar frames unlock as you level up. Other players see your card back, frame, and level.

## Quick start

Requirements: [Go 1.22+](https://go.dev/dl/) and [Godot 4.6](https://godotengine.org/download) (the standard build, not .NET).

```powershell
# 1. Build the server into the client folder (the game launches it for singleplayer/hosting)
./build.ps1          # or: go -C server build -o ../client/bin/glint-server.exe .

# 2. Open client/project.godot in Godot and press Play (F5)
```

On macOS/Linux, run `./build.sh` instead (it builds `client/bin/glint-server`).

### Closed beta

The beta runs on a server on this PC. It's encrypted with a pinned self-signed certificate, registration needs an invite code, outdated builds are told to update, and testers can send feedback from inside the game. See [`beta/HOSTING.md`](beta/HOSTING.md) for:

- running the server with `beta\run-server.ps1`
- managing invites with `beta\invites.ps1`
- reading feedback with `beta\feedback.ps1`
- shipping builds with `release.ps1`

### Dedicated server

```bash
cd server
go run . -addr :7777
```

Players open **Multiplayer**, enter `your-host:7777`, and then create or join a room. *Host on this PC* does the same thing on the local machine (port 7777, all interfaces). The lobby shows your LAN IPs so friends know where to connect.

### Building the standalone game (Glint.exe)

```powershell
.\export.ps1 -Godot "C:\path\to\Godot_v4.6.2-stable_win64.exe"
```

This produces `build\Glint.exe`, `build\Glint.pck` and `build\glint-server.exe`. Double-click `Glint.exe` to play, and zip the `build` folder to share it.

- With Godot export templates installed (Editor → Manage Export Templates), the script does a proper, slimmer release export.
- Without them, it uses the Godot binary as the runtime.

When exporting manually, keep `glint-server.exe` **next to the game executable**. The client looks for it there, in `res://bin/`, and in `../server/`.

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
- **Singleplayer** launches `glint-server -addr 127.0.0.1:7778 -idle-exit 30s` and connects to it, so solo and online play run the exact same rules.

### Gameplay rules

- **GLINT calls.** Press **GLINT!** (or `G`) when you're about to play your second-to-last card, or right after. If you forget, anyone can **Catch** you (`C`) for +2 until the next player acts. Bots call it, and catch you, based on their difficulty.
- **Drawing.** Draw (`D`/Space) when you can't or don't want to play. If the drawn card is playable you can play it or keep it and pass (`P`). Under force play, you must play it.
- **Stacking.** +2 stacks on +2, and +4 stacks on +2 or +4. The first player who can't add to the stack draws all of it.
- **Seven-O.** A 7 makes you pick a player to swap hands with. A 0 rotates every hand in the direction of play.
- **Jump-in.** If you hold the exact same card as the one on top (same color and number/symbol), you can play it out of turn.
- **Scoring.** The round winner scores the cards left in everyone else's hands: number cards at face value, action cards 20, wilds 50.

### Accounts and friends

Accounts live on whichever server you sign in to. To be friends, everyone signs in to the same server, for example the PC that uses **Host on this PC** or a dedicated `glint-server`.

- **Storage.** Accounts are kept in `<data>/accounts.json`. Set the folder with `-data`, and disable accounts with `-accounts=false`.
- **Security.** Passwords are stored as salted PBKDF2-SHA256 hashes. Session tokens are random and stored hashed, so you stay signed in until you sign out.
- **Profile sync.** Your synced profile is whichever copy has more XP: the account's or the local one. Progression is still client-reported, so treat it as casual, not competitive.

### Audio

Every sound and both music loops are generated by [`tools/gen_audio.py`](tools/gen_audio.py), a dependency-free Python synthesizer. Tweak it and rerun `python tools/gen_audio.py` to regenerate `client/audio/`.

### Progression

Your progression is stored locally in `user://profile.cfg`. XP comes from playing rounds, winning, points scored, cards played, GLINT calls and catches, and match wins. There are bonuses for multiplayer, hard bots, and first-time campaign clears. Campaign stars: ★ for a win, ★★ for scoring 50+ points, ★★★ for drawing 3 cards or fewer.

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

## Branding

The logo, app icon, palette, typography, glass recipe and marketing art are all generated from
[`tools/gen_branding.py`](tools/gen_branding.py). See [`branding/BRAND.md`](branding/BRAND.md) for the guidelines.

## Development

```bash
cd server && go test ./...
```

Debug launch flags for the client (after `--` on the Godot command line):
`--demo` (start a quick game), `--stage=N` (start campaign level N, counting from 0), `--autoplay` (the client plays for you), `--screen=campaign|customize|profile|single|multi`, `--xp=N` (preview progression), `--shot=path.png@seconds` (save a screenshot, then quit).
