#!/usr/bin/env bash
# Renders alertmanager.yml from the checked-in template, substituting the
# real Discord webhook URL from .env. Run this before `docker compose up`
# (it's also the first step in deploy.sh). Output (alertmanager.yml) is gitignored.
set -euo pipefail
cd "$(dirname "$0")/.."

set -a; source .env; set +a

sed "s|__DISCORD_WEBHOOK_URL__|${DISCORD_WEBHOOK_URL}|g" \
  monitoring/prometheus/alertmanager.yml.template \
  > monitoring/prometheus/alertmanager.yml

echo "Rendered monitoring/prometheus/alertmanager.yml"
