#!/usr/bin/env bash
# One-command deploy for a fresh VPS (Ubuntu 22.04/24.04 assumed).
# Idempotent: safe to re-run for updates.
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -f .env ]; then
  echo "Missing .env — copy .env.example to .env and fill in real values first."
  exit 1
fi

echo "==> Rendering alertmanager config from template"
./scripts/render-alertmanager-config.sh

echo "==> Pulling/building images"
docker compose pull --ignore-buildable || true
docker compose build

echo "==> Starting stack"
docker compose up -d

echo "==> Waiting for backend health check"
for i in $(seq 1 30); do
  if curl -sf "http://localhost:8000/healthz" >/dev/null 2>&1 || \
     docker compose exec -T backend python -c "import urllib.request;urllib.request.urlopen('http://localhost:8000/healthz')" >/dev/null 2>&1; then
    echo "backend healthy"
    break
  fi
  sleep 2
done

echo "==> Done. Verify:"
echo "  - https://\${DOMAIN}/healthz"
echo "  - https://\${DOMAIN}/grafana/  (dashboards)"
echo "  - Configure Vapi webhook URL as: https://\${DOMAIN}/webhooks/vapi"
