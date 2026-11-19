#!/usr/bin/env bash
# notify.sh — daily health check; sends a webhook if anything is wrong.
#
# Detects:
#   - backup or maintenance (prune/check) that failed
#   - a run that never finished (status stuck at RUNNING while the systemd
#     unit is no longer active: killed by the memory cap, timed out, reboot)
#   - a status file that is too old (timer disabled, node was off, unit hung)
#   - a backup that has never run at all
set -euo pipefail

# shellcheck disable=SC1091
source /usr/local/lib/node-backup/lib.sh
load_env

BACKUP_STATUS_FILE="$(status_file_path)"
PRUNE_STATUS_FILE="$(prune_status_file_path)"
BACKUP_MAX_AGE_H="${STATUS_MAX_AGE_HOURS:-26}"
PRUNE_MAX_AGE_H="${PRUNE_STATUS_MAX_AGE_HOURS:-192}"

problems=()

# check_status <label> <file> <unit> <max_age_hours> <missing_is_problem>
check_status() {
  local label="$1" f="$2" unit="$3" max_age_h="$4" missing_is_problem="$5"
  local state ts detail age_h ts_epoch

  if [[ ! -f "$f" ]]; then
    [[ "$missing_is_problem" == "1" ]] && problems+=("$label has never run (no status file)")
    return 0
  fi

  read -r state ts detail < "$f" || true
  if [[ -z "${ts:-}" ]] || ! ts_epoch="$(date -d "$ts" +%s 2>/dev/null)"; then
    problems+=("$label status file is unreadable: $f")
    return 0
  fi
  age_h=$(( ( $(date +%s) - ts_epoch ) / 3600 ))

  case "$state" in
    OK)
      if (( age_h > max_age_h )); then
        problems+=("last successful $label is ${age_h}h old ($ts) — timer not firing or run hanging?")
      fi
      ;;
    RUNNING)
      if systemctl is-active --quiet "$unit"; then
        if (( age_h > max_age_h )); then
          problems+=("$label has been running for ${age_h}h (since $ts) — hung?")
        fi
      else
        problems+=("$label started at $ts but never finished (killed by memory cap, timeout or reboot)")
      fi
      ;;
    FAIL)
      problems+=("$label failed at $ts: ${detail:-no details}")
      ;;
    *)
      problems+=("$label status file has unknown state '$state'")
      ;;
  esac
}

check_status "backup"                 "$BACKUP_STATUS_FILE" node-backup.service       "$BACKUP_MAX_AGE_H" 1
check_status "maintenance (prune/check)" "$PRUNE_STATUS_FILE" node-backup-prune.service "$PRUNE_MAX_AGE_H"  0

if [[ ${#problems[@]} -eq 0 ]]; then
  log "notify: all OK — no notification needed"
  exit 0
fi

HOSTNAME_FQDN="$(hostname -f 2>/dev/null || hostname)"
NODE_NAME="${NODE_BACKUP_NAME:-node-backup}"
MESSAGE="node-backup problems on $HOSTNAME_FQDN: $(IFS='|'; echo "${problems[*]}" | sed 's/|/; /g')"

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/ }"
  printf '%s' "$s"
}

PAYLOAD="$(cat <<EOF_JSON
{
  "service": "node-backup",
  "node": "$(json_escape "$NODE_NAME")",
  "host": "$(json_escape "$HOSTNAME_FQDN")",
  "status": "FAIL",
  "timestamp": "$(date -Is)",
  "message": "$(json_escape "$MESSAGE")"
}
EOF_JSON
)"

if [[ "${WEBHOOK_ENABLED:-0}" != "1" ]]; then
  log "Webhook disabled — would have sent: $PAYLOAD"
  exit 0
fi

curl -fsS --max-time 30 --retry 3 -X POST \
  -H "Authorization: Bearer ${WEBHOOK_BEARER_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" \
  "$WEBHOOK_URL"

log "Failure notification sent: $MESSAGE"
