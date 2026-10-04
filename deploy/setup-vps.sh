#!/usr/bin/env bash
# One-time setup of a fresh Ubuntu 24.04 VPS for the Glint server.
# deploy.ps1 -FirstTime uploads this and runs it as root; it's safe to re-run.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
echo "== packages"
apt-get update -q
apt-get upgrade -yq
apt-get install -yq ufw fail2ban unattended-upgrades
dpkg-reconfigure -f noninteractive unattended-upgrades   # security updates install themselves

echo "== firewall: SSH + game port only"
ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH
ufw allow 7777/tcp comment "Glint"
ufw --force enable

echo "== SSH: keys only"
# Only once a key is installed (we're logged in with it), so this can't lock you out.
if [ -s /root/.ssh/authorized_keys ]; then
  printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin prohibit-password\n' > /etc/ssh/sshd_config.d/10-glint.conf
  systemctl reload ssh 2>/dev/null || systemctl reload sshd
fi

echo "== service user and folders"
id glint >/dev/null 2>&1 || useradd --system --home /opt/glint --shell /usr/sbin/nologin glint
install -d -o glint -g glint -m 750 /opt/glint
install -d -o glint -g glint -m 700 /opt/glint/data /opt/glint/data/tls

echo "== systemd unit"
install -m 644 /tmp/glint-deploy/glint.service /etc/systemd/system/glint.service
systemctl daemon-reload
systemctl enable glint

# Keep the journal small on a 1 GB box.
mkdir -p /etc/systemd/journald.conf.d
printf '[Journal]\nSystemMaxUse=200M\n' > /etc/systemd/journald.conf.d/glint.conf
systemctl restart systemd-journald

echo "== done. Next: deploy.ps1 uploads the server and its data."
