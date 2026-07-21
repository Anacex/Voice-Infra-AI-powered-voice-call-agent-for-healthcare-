#!/usr/bin/env bash
# Restores a given dump file into a THROWAWAY database (voiceagent_restore_test)
# to prove the backup is actually restorable, without touching the live DB.
#
# Usage: ./backup/restore-test.sh backups/voiceagent_20260721T030000Z.dump
#
# This is what "have you tested your restore" means in practice — an
# untested backup is a hope, not a backup strategy.
set -euo pipefail
cd "$(dirname "$0")/.."

DUMP_FILE="${1:?usage: restore-test.sh <path-to-dump>}"
TEST_DB="voiceagent_restore_test"

echo "[restore-test] creating throwaway db ${TEST_DB}"
docker compose exec -T postgres psql -U voiceagent -d postgres \
  -c "DROP DATABASE IF EXISTS ${TEST_DB};" \
  -c "CREATE DATABASE ${TEST_DB} OWNER voiceagent;"

echo "[restore-test] restoring ${DUMP_FILE} into ${TEST_DB}"
docker compose exec -T postgres pg_restore -U voiceagent -d "${TEST_DB}" --no-owner < "${DUMP_FILE}"

echo "[restore-test] verifying row counts"
docker compose exec -T postgres psql -U voiceagent -d "${TEST_DB}" -c \
  "SELECT 'calls' AS table, count(*) FROM calls
   UNION ALL SELECT 'call_events', count(*) FROM call_events
   UNION ALL SELECT 'tool_calls', count(*) FROM tool_calls;"

echo "[restore-test] cleaning up"
docker compose exec -T postgres psql -U voiceagent -d postgres -c "DROP DATABASE ${TEST_DB};"

echo "[restore-test] PASSED — dump is restorable"
