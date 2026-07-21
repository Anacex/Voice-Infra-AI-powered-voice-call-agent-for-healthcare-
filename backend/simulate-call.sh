#!/usr/bin/env bash
# Simulates a full call lifecycle (start -> tool call -> end) against your
# local backend, so you can verify the whole pipeline (webhook receipt ->
# Postgres write -> Prometheus metrics -> Grafana) works BEFORE wiring up
# a real Vapi account and phone number.
#
# Usage: ./backend/simulate-call.sh [base_url]
#   default base_url = http://localhost:8000
set -euo pipefail

BASE_URL="${1:-http://localhost:8000}"
CALL_ID="test-call-$(date +%s)"

echo "==> Simulating call ${CALL_ID} against ${BASE_URL}"

echo "--> 1/3 status-update (in-progress)"
curl -sf -X POST "${BASE_URL}/webhooks/vapi" \
  -H "Content-Type: application/json" \
  -d @- <<EOF | jq . || true
{
  "message": {
    "type": "status-update",
    "status": "in-progress",
    "call": {
      "id": "${CALL_ID}",
      "phoneNumber": {"number": "+15551234567"},
      "customer": {"number": "+15559876543"}
    }
  }
}
EOF

sleep 1

echo "--> 2/3 tool-calls (simulated 'check_appointment_availability')"
curl -sf -X POST "${BASE_URL}/webhooks/vapi" \
  -H "Content-Type: application/json" \
  -d @- <<EOF | jq . || true
{
  "message": {
    "type": "tool-calls",
    "call": {"id": "${CALL_ID}"},
    "toolCallList": [
      {
        "function": {
          "name": "check_appointment_availability",
          "arguments": {"date": "2026-07-22", "provider": "Dr. Smith"}
        }
      }
    ]
  }
}
EOF

sleep 1

echo "--> 3/3 end-of-call-report"
curl -sf -X POST "${BASE_URL}/webhooks/vapi" \
  -H "Content-Type: application/json" \
  -d @- <<EOF | jq . || true
{
  "message": {
    "type": "end-of-call-report",
    "call": {"id": "${CALL_ID}"},
    "durationSeconds": 87,
    "endedReason": "customer-ended-call",
    "transcript": [
      {"role": "assistant", "message": "Thank you for calling Lakewood Family Medicine, this is Sarah."},
      {"role": "user", "message": "Hi, I need to schedule an appointment."}
    ],
    "analysis": {"summary": "Patient requested to schedule an appointment."}
  }
}
EOF

echo ""
echo "==> Done. Verify:"
echo "  curl -s ${BASE_URL}/calls/${CALL_ID} | jq ."
echo "  curl -s ${BASE_URL}/metrics | grep voice_"
