#!/usr/bin/env bash
set -euo pipefail
exec > >(tee /var/log/cloud-init-output.log) 2>&1

echo "==> Installing Docker"
apt-get update
apt-get install -y ca-certificates curl gnupg git
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

echo "==> Cloning repo"
mkdir -p /opt/voice-infra
git clone ${repo_url} /opt/voice-infra
cd /opt/voice-infra

echo "==> Writing .env (never committed — written directly on the host from Terraform vars)"
cat > .env <<ENVEOF
DOMAIN=${domain}
PG_PASSWORD=${pg_password}
GRAFANA_ADMIN_PASSWORD=${grafana_admin_password}
VAPI_WEBHOOK_SECRET=${vapi_webhook_secret}
VAPI_API_KEY=${vapi_api_key}
DISCORD_WEBHOOK_URL=${discord_webhook_url}
ENVEOF
chmod 600 .env

echo "==> Rendering alertmanager config"
chmod +x scripts/render-alertmanager-config.sh
./scripts/render-alertmanager-config.sh

echo "==> Bringing up the stack (production compose file, Caddy handles TLS)"
docker compose up -d --build

echo "==> Installing backup cron"
chmod +x backup/backup.sh backup/restore-test.sh
(crontab -l 2>/dev/null; cat backup/crontab.example | sed "s|/opt/voice-infra|/opt/voice-infra|g") | crontab -

echo "==> cloud-init complete"
