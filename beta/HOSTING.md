# Hosting the closed beta on this PC

The beta server runs on your PC and testers connect to it over the internet.
Connections from the internet are encrypted with TLS. Each release pins the
server's self-signed certificate, so you don't need a domain.

## One-time setup

You do these steps yourself: they change your router and firewall settings.

1. **Give this PC a fixed LAN address.** Set a DHCP reservation in your router
   so the port forward doesn't break when the PC gets a new address.
2. **Forward the port.** In your router, forward **TCP 7777** to this PC's LAN
   address.
3. **Allow it through Windows Firewall.** Run this once in an *Administrator*
   PowerShell:
   ```powershell
   New-NetFirewallRule -DisplayName "Glint beta server" -Direction Inbound -Protocol TCP -LocalPort 7777 -Action Allow
   ```
4. **Get an address for testers.** Your public IP is shown at <https://ifconfig.me>.
   Home IPs can change, so a free dynamic-DNS name is better
   (for example `yourname.duckdns.org` from <https://www.duckdns.org>, plus its
   updater). Testers can also type a new address themselves in
   Multiplayer or Account if it changes.

## Appwrite (accounts, friends, feedback)

The server stores player accounts in your Appwrite project (`beta/appwrite.json`):
- **Logins:** Appwrite Auth owns passwords and sessions.
- **Player data:** player rows and feedback live in the `uno` TablesDB database.
- **The API key:** it stays on this PC. It's never put in the game.

One-time setup:

1. **Create an API key.** In the Appwrite console, open your project, then **Overview → API keys → Create API key**. Name it `glint-server`, with no expiry, and give it these scopes:
   - **Auth:** `users.read`, `users.write`, `sessions.write`
   - **Database:** `databases.read`, `databases.write`, `tables.read`, `tables.write`,
     `columns.read`, `columns.write`, `indexes.read`, `indexes.write`, `rows.read`, `rows.write`
2. **Save the key.** Paste it into a new file, `beta\server-data\appwrite.key`. The file holds just the key. That folder is git-ignored, so don't put the key anywhere else.
3. **Create the database.** Run `beta\appwrite-setup.cmd`. It creates the `uno` database with a `players` table and a `feedback` table, readable and writable only by the server. It's safe to run again.

From then on, `beta\run-server.cmd` uses Appwrite automatically. The startup banner shows `Accounts: Appwrite …`.

Without a key it falls back to the local `beta\server-data\accounts.json`.

**Notes:**
- Players need a password of at least 8 characters, which is Appwrite's rule.
- In Appwrite, players show up under **Auth** with the labels `player` and `beta`. Their internal email is `<username>@players.unoglass.app`. No mail is ever sent there.
- **Blocking** a user in the Appwrite console stops them from signing in.
- Feedback can be read in **Databases → uno → feedback**, or with `beta\feedback.cmd`.

## Every session

```powershell
beta\run-server.cmd          # keep this window open while testers play
```

You can play on this PC at `127.0.0.1:7777`.

## Invites, feedback and testers

```powershell
beta\invites.cmd create -n 5 -note "Discord friends"   # single-use codes to hand out
beta\invites.cmd list                                  # who used which code
beta\invites.cmd revoke Username                       # remove a tester (applies at next sign-in)
beta\feedback.cmd                                      # read bug reports and ideas
beta\feedback.cmd -Log                                 # include the attached game logs
```

## Shipping a new beta build

```powershell
release.cmd -Version 0.9.0-beta.2 -Server yourname.duckdns.org:7777 -Godot C:\path\to\Godot_v4.6.2-stable_win64.exe
release.cmd ... -Publish     # uploads the installer + zip to the website download (add -GitHub to mirror there)
```

The script writes the new version to `beta\VERSION`. After you restart
`run-server.ps1`, older builds are asked to update.

## Back up

`beta\server-data\` holds the accounts, invites, feedback and **the TLS private
key**. It's ignored by git, so back it up yourself. If you lose the key, you'll
have to ship a new build, because old builds can no longer connect.
