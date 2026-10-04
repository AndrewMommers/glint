#!/usr/bin/env bash
# Installs the uploaded server build (and data, if included) and restarts it.
# Run on the VPS by deploy.ps1 after each upload.
set -euo pipefail
cd /tmp/glint-deploy
install -o root -g root -m 755 glint-server /opt/glint/glint-server
install -o root -g glint -m 640 glint.env /opt/glint/glint.env
install -m 644 glint.service /etc/systemd/system/glint.service
if [ -d data ]; then
  install -o glint -g glint -m 600 data/server.crt data/server.key /opt/glint/data/tls/
  for f in appwrite.key invites.json; do
    if [ -f "data/$f" ]; then install -o glint -g glint -m 600 "data/$f" /opt/glint/data/; fi
  done
  echo "data uploaded"
fi
# HTTPS front end for the browser version (Caddy) and the web build itself.
if ! command -v caddy >/dev/null; then
  apt-get install -yq caddy
fi
ufw allow 80/tcp comment "Glint web (HTTPS redirect)" >/dev/null
ufw allow 443/tcp comment "Glint web" >/dev/null
if [ -d web ]; then
  rm -rf /opt/glint/web.new && cp -r web /opt/glint/web.new
  chmod -R a+rX /opt/glint/web.new
  rm -rf /opt/glint/web.old; [ -d /opt/glint/web ] && mv /opt/glint/web /opt/glint/web.old
  mv /opt/glint/web.new /opt/glint/web && rm -rf /opt/glint/web.old
  chmod 755 /opt/glint
  echo "web build uploaded"
fi
install -m 644 Caddyfile /etc/caddy/Caddyfile
systemctl enable --now caddy >/dev/null 2>&1
systemctl reload caddy || systemctl restart caddy

rm -rf /tmp/glint-deploy
systemctl daemon-reload
systemctl restart glint
sleep 2
systemctl is-active glint
journalctl -u glint -n 8 --no-pager -o cat
