#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source /usr/local/lib/node-backup/lib.sh
load_env

STATUS_FILE="$(status_file_path)"

read_status() {
  local f="$1" s t
  if [[ -f "$f" ]] && read -r s t _ <"$f"; then
    printf '%s %s' "$s" "$t"
  else
    printf 'FAIL %s' "$(date -Is)"
  fi
}

read -r STATE TS <<<"$(read_status "$STATUS_FILE")"

if [[ "$STATE" == "OK" ]]; then
  log "notify: backup OK @ $TS; no notification needed"
  exit 0
fi

HOSTNAME_FQDN="$(hostname -f 2>/dev/null || hostname)"
NODE_NAME="${NODE_BACKUP_NAME:-node-backup}"

PAYLOAD="$(cat <<EOF_JSON
{
  "service": "node-backup",
  "node": "$NODE_NAME",
  "host": "$HOSTNAME_FQDN",
  "status": "$STATE",
  "timestamp": "$TS",
  "message": "Backup failed on $HOSTNAME_FQDN at $TS"
}
EOF_JSON
)"

if [[ "${WEBHOOK_ENABLED:-0}" != "1" ]]; then
  log "Webhook disabled; backup status is $STATE — would have sent: $PAYLOAD"
  exit 0
fi

curl -fsS -X POST \
  -H "Authorization: Bearer ${WEBHOOK_BEARER_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" \
  "$WEBHOOK_URL"

log "Failure notification sent"
