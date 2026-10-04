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
rm -rf /tmp/glint-deploy
systemctl daemon-reload
systemctl restart glint
sleep 2
systemctl is-active glint
journalctl -u glint -n 8 --no-pager -o cat
