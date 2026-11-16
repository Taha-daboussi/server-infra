#!/usr/bin/env bash
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "run as root: sudo $0" >&2; exit 1; }
here="$(cd "$(dirname "$0")" && pwd)"
admin="${ADMIN_USER:?set ADMIN_USER to your SSH login user}"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl git jq ufw fail2ban unattended-upgrades zstd logrotate

if ! command -v docker >/dev/null; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

install -m 0644 "$here/docker-daemon.json" /etc/docker/daemon.json
install -m 0644 "$here/sshd-hardening.conf" /etc/ssh/sshd_config.d/00-hardening.conf
install -m 0644 "$here/fail2ban-sshd.local" /etc/fail2ban/jail.d/sshd.local
install -m 0644 -D "$here/journald-size.conf" /etc/systemd/journald.conf.d/90-size.conf
install -m 0644 "$here/sysctl-swap.conf" /etc/sysctl.d/90-swap.conf
install -m 0644 "$here/logrotate-traefik" /etc/logrotate.d/traefik
mkdir -p /var/log/journal

if [[ ! -f /swapfile ]]; then
  fallocate -l 4G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
  swapon /swapfile
fi

if ! grep -q '# BEGIN UFW AND DOCKER' /etc/ufw/after.rules; then
  cat "$here/ufw-docker.rules" >> /etc/ufw/after.rules
fi
ufw default deny incoming
ufw default allow outgoing
ufw default deny routed
ufw limit 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 443/udp
ufw route allow proto tcp from any to 172.30.0.10 port 80
ufw route allow proto tcp from any to 172.30.0.10 port 443
ufw route allow proto udp from any to 172.30.0.10 port 443
ufw allow in on br-mon to 172.31.0.1 port 9100 proto tcp
ufw --force enable

usermod -aG docker "$admin"
id deploy >/dev/null 2>&1 || useradd --create-home --shell /bin/bash --groups docker deploy
install -d -o deploy -g deploy -m 700 /home/deploy/.ssh

install -d -m 755 /srv /srv/apps /srv/grafana /srv/grafana/dashboards
install -d -m 700 /srv/backups
install -d -m 755 /var/log/traefik
chown -R deploy:deploy /srv/apps /srv/grafana

docker network inspect edge >/dev/null 2>&1 \
  || docker network create --subnet 172.30.0.0/24 edge

install -m 0644 "$here/../systemd/infra-backup.service" /etc/systemd/system/
install -m 0644 "$here/../systemd/infra-backup.timer" /etc/systemd/system/

sysctl --system >/dev/null
systemctl daemon-reload
systemctl restart systemd-journald
systemctl restart docker
sshd -t
systemctl reload ssh
systemctl enable --now fail2ban unattended-upgrades infra-backup.timer
systemctl restart fail2ban
echo "host setup done"
