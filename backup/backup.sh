#!/usr/bin/env bash
# Nightly Postgres backup for the voice agent DB.
#
# What it does:
#   1. pg_dump the DB (custom format, compressed) into ./backups/
#   2. Optionally uploads to S3 if BACKUP_S3_BUCKET is set (off-site copy —
#      a backup that lives on the same VPS as the primary is not a real backup)
#   3. Deletes local dumps older than RETENTION_DAYS (default 14)
#   4. Logs success/failure and pings Discord on failure so a broken backup
#      job doesn't fail silently for weeks
#
# Run via cron (see backup/crontab.example) or as a one-off:
#   ./backup/backup.sh
set -euo pipefail
cd "$(dirname "$0")/.."

set -a; source .env 2>/dev/null || true; set +a

BACKUP_DIR="$(dirname "$0")/backups"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-14}"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
FILENAME="voiceagent_${TIMESTAMP}.dump"

mkdir -p "$BACKUP_DIR"

notify_failure() {
  local msg="$1"
  echo "[backup] FAILURE: $msg" >&2
  if [ -n "${DISCORD_WEBHOOK_URL:-}" ]; then
    curl -sf -X POST -H "Content-Type: application/json" \
      -d "{\"content\": \"🔴 **Backup FAILED** on $(hostname): ${msg}\"}" \
      "$DISCORD_WEBHOOK_URL" || true
  fi
}

trap 'notify_failure "backup.sh exited with error at line $LINENO"' ERR

echo "[backup] starting dump -> ${BACKUP_DIR}/${FILENAME}"

docker compose exec -T postgres pg_dump -U voiceagent -d voiceagent -F custom \
  > "${BACKUP_DIR}/${FILENAME}"

# sanity check: a 0-byte or tiny dump means something is wrong — don't trust it
SIZE=$(stat -c%s "${BACKUP_DIR}/${FILENAME}" 2>/dev/null || stat -f%z "${BACKUP_DIR}/${FILENAME}")
if [ "$SIZE" -lt 100 ]; then
  notify_failure "dump file suspiciously small (${SIZE} bytes) — treating as failed"
  rm -f "${BACKUP_DIR}/${FILENAME}"
  exit 1
fi

echo "[backup] dump complete (${SIZE} bytes)"

if [ -n "${BACKUP_S3_BUCKET:-}" ]; then
  echo "[backup] uploading to s3://${BACKUP_S3_BUCKET}/"
  AWS_ACCESS_KEY_ID="${BACKUP_S3_ACCESS_KEY_ID}" \
  AWS_SECRET_ACCESS_KEY="${BACKUP_S3_SECRET_ACCESS_KEY}" \
    aws s3 cp "${BACKUP_DIR}/${FILENAME}" "s3://${BACKUP_S3_BUCKET}/${FILENAME}"
  echo "[backup] uploaded"
else
  echo "[backup] BACKUP_S3_BUCKET not set — backup is LOCAL ONLY. See README risk notes."
fi

echo "[backup] pruning local dumps older than ${RETENTION_DAYS} days"
find "$BACKUP_DIR" -name 'voiceagent_*.dump' -mtime "+${RETENTION_DAYS}" -delete

echo "[backup] done"
