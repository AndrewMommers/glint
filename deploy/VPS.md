# Running the Glint server on a Vultr VPS

The server runs on a small Linux VPS, so testers can play online without your PC
being on. Accounts, friends and feedback stay in Appwrite. The VPS only runs
the game server.

## 1. Create an SSH key (once, on this PC)

In PowerShell:

```powershell
ssh-keygen -t ed25519 -C "glint-vps"
```

Press Enter to accept the default file. Adding a passphrase is a good idea.
Then copy the public key:

```powershell
Get-Content $env:USERPROFILE\.ssh\id_ed25519.pub | Set-Clipboard
```

## 2. Create the server on Vultr

In the Vultr dashboard: **Deploy → Deploy New Server**.

| Setting | Choose |
|---|---|
| Type | **Cloud Compute – Shared CPU** (Regular Performance is fine) |
| Location | **Sydney**, close to your players and to Appwrite (also Sydney) |
| Image | **Ubuntu 24.04 LTS x64** |
| Plan | **1 vCPU, 1 GB RAM, 25 GB SSD** (about US$5/month). One server handles hundreds of tables. |
| SSH Keys | **Add New**, paste the key from step 1, and select it |
| Auto Backups | Optional. Accounts live in Appwrite, so there's little to lose. |
| Hostname | `glint-1` |

Deploy it and wait until it shows **Running**, then copy its **IPv4 address**.

## 3. Install Glint on it

```powershell
.\deploy\deploy.cmd -Server <IPv4 address> -FirstTime
```

This takes a few minutes. It:
- installs updates and turns on automatic security updates;
- sets up a firewall that allows only SSH and TCP 7777, and fail2ban against SSH password guessing;
- creates a locked-down `glint` service that restarts itself if it ever stops;
- uploads the server, the TLS certificate the game builds pin, the Appwrite key and the invite list.

At the end it checks that port 7777 answers from your PC.

## 4. Publish the game

```powershell
.\release.cmd -Version 1.0.1 -Publish
```

That builds the browser version and deploys it with the server. Caddy serves it with free HTTPS at `https://<ip-with-dashes>.sslip.io/`, or at your own domain with `deploy.cmd -Domain play.example.com`. Players reach it through the website's Play page.

From now on the VPS owns the invite list. Use `deploy\server.cmd` instead of
`beta\invites.cmd`, and don't run `beta\run-server.cmd` for testers any more.

## Everyday commands

```powershell
.\deploy\deploy.cmd                                  # ship a new server build (after changing server code)
.\deploy\server.cmd status                           # running? recent log lines
.\deploy\server.cmd logs                             # live log, Ctrl+C to stop
.\deploy\server.cmd invites create -n 5 -note "Sam"
.\deploy\server.cmd invites list
.\deploy\server.cmd invites revoke GLINT-XXXX-XXXX
.\deploy\server.cmd restart
```

`deploy.cmd -SyncData` re-uploads the certificate, Appwrite key and invites from
`beta\server-data`. **This overwrites the VPS's invite list**, including which
codes were used, so only use it if you mean to.

## Good to know

- **Restarting ends running games.** Deploy when nobody's playing (`server.cmd status` shows the recent joins).
- **The certificate must stay the same.** Builds pin `beta\server-data\tls\server.crt`. If it's ever regenerated, every tester needs a new build.
- **New server version:** bump `beta\VERSION` along with a release, then run `deploy.cmd`, so older builds are asked to update.
- **Moving to a new VPS:** run `deploy.cmd -Server <new IP> -FirstTime -SyncData`. If the address changes, players need a new build, so a domain name pointing at the VPS makes future moves painless.
