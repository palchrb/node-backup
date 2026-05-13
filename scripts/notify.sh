#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source /usr/local/lib/node-backup/lib.sh
load_env

BACKUP_STATUS_FILE="$(status_file_path)"
PRUNE_STATUS_FILE="$(prune_status_file_path)"

read_status() {
  local f="$1" s t
  if [[ -f "$f" ]] && read -r s t _ <"$f"; then
    printf '%s %s' "$s" "$t"
  else
    printf 'FAIL %s' "$(date -Is)"
  fi
}

read -r BACKUP_STATE BACKUP_TS <<<"$(read_status "$BACKUP_STATUS_FILE")"

# Prune runs weekly — only check if the status file exists
PRUNE_STATE="OK"
PRUNE_TS=""
if [[ -f "$PRUNE_STATUS_FILE" ]]; then
  read -r PRUNE_STATE PRUNE_TS <<<"$(read_status "$PRUNE_STATUS_FILE")"
fi

if [[ "$BACKUP_STATE" == "OK" && "$PRUNE_STATE" == "OK" ]]; then
  log "notify: backup OK @ $BACKUP_TS, prune OK — no notification needed"
  exit 0
fi

HOSTNAME_FQDN="$(hostname -f 2>/dev/null || hostname)"
NODE_NAME="${NODE_BACKUP_NAME:-node-backup}"

# Build a message that names exactly what failed
if [[ "$BACKUP_STATE" != "OK" && "$PRUNE_STATE" != "OK" ]]; then
  MESSAGE="Backup failed at $BACKUP_TS and prune failed at $PRUNE_TS on $HOSTNAME_FQDN"
  FAILED_STATE="FAIL"
  FAILED_TS="$BACKUP_TS"
elif [[ "$BACKUP_STATE" != "OK" ]]; then
  MESSAGE="Backup failed on $HOSTNAME_FQDN at $BACKUP_TS"
  FAILED_STATE="$BACKUP_STATE"
  FAILED_TS="$BACKUP_TS"
else
  MESSAGE="Restic prune failed on $HOSTNAME_FQDN at $PRUNE_TS"
  FAILED_STATE="$PRUNE_STATE"
  FAILED_TS="$PRUNE_TS"
fi

PAYLOAD="$(cat <<EOF_JSON
{
  "service": "node-backup",
  "node": "$NODE_NAME",
  "host": "$HOSTNAME_FQDN",
  "status": "$FAILED_STATE",
  "timestamp": "$FAILED_TS",
  "message": "$MESSAGE"
}
EOF_JSON
)"

if [[ "${WEBHOOK_ENABLED:-0}" != "1" ]]; then
  log "Webhook disabled; status — backup: $BACKUP_STATE, prune: $PRUNE_STATE — would have sent: $PAYLOAD"
  exit 0
fi

curl -fsS -X POST \
  -H "Authorization: Bearer ${WEBHOOK_BEARER_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" \
  "$WEBHOOK_URL"

log "Failure notification sent: $MESSAGE"
