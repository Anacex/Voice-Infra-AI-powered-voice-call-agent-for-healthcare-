#!/usr/bin/env bash
# Creates the Vapi assistant from agent-config.json and provisions a phone
# number, via the Vapi API — reproducible, not a dashboard click-through.
#
# Requires: VAPI_API_KEY in .env, and either:
#   - DOMAIN set to your ngrok hostname for local testing, or
#   - DOMAIN set to your real domain once deployed
#
# Usage: ./scripts/setup-vapi-agent.sh
set -euo pipefail
cd "$(dirname "$0")/.."

set -a; source .env; set +a

: "${VAPI_API_KEY:?Set VAPI_API_KEY in .env (from Vapi dashboard -> Settings -> API Keys)}"
: "${DOMAIN:?Set DOMAIN in .env (your ngrok hostname for local testing, or real domain once deployed)}"

# Defensive: strip any accidental http(s):// prefix or trailing slash —
# DOMAIN should be a bare hostname, e.g. abc123.ngrok-free.dev
DOMAIN="${DOMAIN#http://}"
DOMAIN="${DOMAIN#https://}"
DOMAIN="${DOMAIN%/}"

echo "==> Rendering agent-config.json with DOMAIN=${DOMAIN}"
CONFIG=$(sed -e "s|__DOMAIN__|${DOMAIN}|g" \
              -e "s|__VAPI_WEBHOOK_SECRET__|${VAPI_WEBHOOK_SECRET:-}|g" \
              agent-config.json | python3 -c "
import json, sys
data = json.load(sys.stdin)
data.pop('_comment', None)
print(json.dumps(data))
")

echo "==> Creating assistant"
HTTP_STATUS=$(curl -s -o /tmp/vapi-assistant-response.json -w "%{http_code}" \
  -X POST "https://api.vapi.ai/assistant" \
  -H "Authorization: Bearer ${VAPI_API_KEY}" \
  -H "Content-Type: application/json" \
  -d "$CONFIG")

if [ "$HTTP_STATUS" -lt 200 ] || [ "$HTTP_STATUS" -ge 300 ]; then
  echo "==> FAILED (HTTP ${HTTP_STATUS}). Vapi's response:"
  cat /tmp/vapi-assistant-response.json
  echo ""
  echo "Common causes: wrong DOMAIN format (no https:// prefix — just the hostname),"
  echo "wrong/expired VAPI_API_KEY (must be the PRIVATE key), or malformed agent-config.json."
  exit 1
fi

RESPONSE=$(cat /tmp/vapi-assistant-response.json)

ASSISTANT_ID=$(echo "$RESPONSE" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
echo "==> Assistant created: ${ASSISTANT_ID}"
echo "$ASSISTANT_ID" > .vapi-assistant-id

echo ""
echo "==> Next: provision a phone number and attach this assistant."
echo "    Easiest path is still the Vapi dashboard (Phone Numbers -> Buy/Import),"
echo "    since free trial numbers and area-code selection are dashboard-only."
echo "    Once you have a number, attach the assistant:"
echo ""
echo "    curl -X PATCH https://api.vapi.ai/phone-number/<PHONE_NUMBER_ID> \\"
echo "      -H \"Authorization: Bearer \$VAPI_API_KEY\" \\"
echo "      -H \"Content-Type: application/json\" \\"
echo "      -d '{\"assistantId\": \"${ASSISTANT_ID}\"}'"
echo ""
echo "==> Then call the number and watch: docker compose logs -f backend"