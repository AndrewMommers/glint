<p align="center"><img src="branding/png/social-preview-1280x640.png" alt="Glint" width="100%"></p>

# Glint

> ### ▶ [Play Glint in your browser](https://glint.appwrite.network/play/)
> Glint is played on the website. There's nothing to install. This repo is the source code.

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

### The live server

Glint runs on a Vultr VPS: the Go server, plus Caddy serving the browser build over HTTPS. Anyone can create an account (at most 3 new accounts per address per hour), outdated game copies are asked to reload, and players can send feedback from inside the game.

- [`deploy/VPS.md`](deploy/VPS.md): setting up the VPS, then `deploy\deploy.cmd` to ship server builds and `deploy\server.cmd` for status and logs
- `beta\feedback.ps1` reads player feedback (also in Appwrite)
- The invite system still exists (`glint-server -invite-only`, `deploy\server.cmd invites ...`) if registration ever needs closing again. The `beta\` folder keeps its name for the server's data and tools.

### Dedicated server

```bash
cd server
go run . -addr :7777
```

Release builds always connect to the official server baked into the build, so there's no address to type. In **Multiplayer**, players can press **Quick Match**, create a **public** lobby (listed for anyone) or a **private** one (code only), join with a 4-letter code, or pick from the open lobbies. Dev builds connect to `127.0.0.1:7777` and start a local server if none is running. Use `--connect=host:port` to test against another server.

### Online play

- **Quick Match** puts you at the fullest open 4-seat Quick Match table, or opens a new one. It uses the standard rules with 20-second turns and a single round. It starts 30 seconds after the first player arrives (at least 8 seconds after anyone joins, or 3 seconds once it's full), and bots fill the empty seats. The host can press *Start now*.
- **Lobby hosts** can remove players (who can't rejoin that room), hand the host role to someone else, and must wait for everyone to press *I'm ready* before starting. If the host leaves, the role moves to another player.
- **Rejoining.** If your connection drops or the game closes mid-round, a bot plays your seat. The game reconnects you automatically for 90 seconds, and the main menu offers *Rejoin* after a restart. The server holds the seat for the rest of the match, and if every player drops, it pauses the game and keeps the room for 3 minutes. Clients send a ping every 5 seconds, so dead connections are noticed in seconds.
- **Chat** works in lobbies and at the table: press `Enter` or `T`. Messages are limited to 140 characters and 5 per 10 seconds, with a profanity mask, and joins, leaves and host changes appear as system lines. It can be turned off in Options.

### Releasing (the browser version)

```powershell
.\release.cmd -Version 1.0.1 -Publish
```

This bumps the version, runs the server tests, exports the web build to `build\web` and deploys the server plus the game to the VPS (`deploy\deploy.cmd -Web`). Players play it on the website's **Play** page, which embeds the game from the VPS. Opened directly, the game redirects to the website, and only the website may embed it (Caddy sets `frame-ancestors`).

In the browser the game talks to the server over WebSocket (`wss://<vps>/ws`, through Caddy) instead of raw TCP. Solo games and the campaign are private tables with bots on the server.

### Building a Windows build (local testing only)

Glint isn't distributed as a desktop app any more, but a Windows build is handy for testing:

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

## Website

`website/` is the game's landing page at **https://glint.appwrite.network**: a static site with no build step, no trackers and no external requests.
It's hosted on Appwrite Sites. Every push to `main` that changes `website/` redeploys it (`.github/workflows/deploy-website.yml` runs `tools/deploy_website.sh`).
`/play/` embeds the game from the VPS full-screen. `/download/` only redirects to `/play/`, so old links and older game builds still land on the right page.
To preview the site, double-click `tools\preview-website.cmd`; the local preview can embed the live game too.
To preview it, run `python -m http.server 8099 --directory website` and open http://localhost:8099.
The screenshots in `website/assets/shots/` are taken from the game.

## Branding

The logo, app icon, palette, typography, glass recipe and marketing art are all generated from
[`tools/gen_branding.py`](tools/gen_branding.py). See [`branding/BRAND.md`](branding/BRAND.md) for the guidelines.

## Development

```bash
cd server && go test ./...
```

Debug launch flags for the client (after `--` on the Godot command line):
`--demo` (start a quick game), `--stage=N` (start campaign level N, counting from 0), `--autoplay` (the client plays for you), `--screen=campaign|customize|profile|single|multi`, `--xp=N` (preview progression), `--shot=path.png@seconds` (save a screenshot, then quit).
