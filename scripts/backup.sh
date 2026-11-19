#!/usr/bin/env bash
# backup.sh — daily backup: pre-command, restic backup, restic forget.
#
# Status handling is pessimistic: the status file is set to RUNNING at start
# and only becomes OK when everything succeeded. If this script is killed
# (memory cap, timeout, reboot) the status stays RUNNING and notify.sh
# reports it as a failure.
set -euo pipefail

# shellcheck disable=SC1091
source /usr/local/lib/node-backup/lib.sh
load_env

mkdir -p "${STATUS_DIR:-/var/log/node-backup}" "${RESTIC_CACHE_DIR:-/var/cache/restic}"
STATUS_FILE="$(status_file_path)"
HOSTNAME_FQDN="$(hostname -f 2>/dev/null || hostname)"

write_status "$STATUS_FILE" RUNNING "started"

fail() {
  local detail="$1" rc="$2"
  write_status "$STATUS_FILE" FAIL "$detail"
  log "ERROR: $detail"
  exit "$rc"
}

# -----------------------------------------------------------------------------
# Paths
# -----------------------------------------------------------------------------
IFS=' ' read -r -a ALL_PATHS <<< "${BACKUP_PATHS:-/etc /var/backups}"
PATHS=()
for p in "${ALL_PATHS[@]}"; do
  [[ -e "$p" ]] || { log "$p does not exist, skipping"; continue; }
  PATHS+=("$p")
done
[[ ${#PATHS[@]} -gt 0 ]] || fail "no valid backup paths found" 98

if [[ ! -f "${EXCLUDES_FILE:-}" ]]; then
  fail "excludes file not found: ${EXCLUDES_FILE:-<unset>}" 96
fi

# -----------------------------------------------------------------------------
# Pre-backup command
# A failure here is recorded but does NOT stop the file backup: one broken
# database must not leave every other file on the node without a backup.
# The run is still marked FAIL at the end so the failure is alerted.
# -----------------------------------------------------------------------------
pre_rc=0
if [[ -n "${PRE_BACKUP_COMMAND:-}" ]]; then
  log "Running pre-backup command"
  set +e
  bash -lc "$PRE_BACKUP_COMMAND"
  pre_rc=$?
  set -e
  if [[ $pre_rc -ne 0 ]]; then
    log "ERROR: pre-backup command failed (rc=$pre_rc) — continuing with file backup"
  fi
fi

# -----------------------------------------------------------------------------
# Repository check — init only when the repository genuinely does not exist.
# restic exit code 10 = repository does not exist. Anything else non-zero
# (network down, wrong password, locked) is a real error, not a reason to init.
# -----------------------------------------------------------------------------
log "Checking restic repository"
set +e
run_logged "restic cat config" restic_cmd cat config >/dev/null
repo_rc=$?
set -e

case $repo_rc in
  0)  ;;
  10)
    log "Repository does not exist — running restic init"
    run_logged "restic init" restic_cmd init || fail "restic init failed" 95
    ;;
  12) fail "wrong restic repository password (rc=12)" 12 ;;
  *)  fail "restic repository not reachable (rc=$repo_rc)" "$repo_rc" ;;
esac

# -----------------------------------------------------------------------------
# Backup
# -----------------------------------------------------------------------------
log "Starting restic backup -> $RESTIC_REPOSITORY"
set +e
restic_cmd backup "${PATHS[@]}" \
  --exclude-file="$EXCLUDES_FILE" \
  --host "$HOSTNAME_FQDN" \
  --tag "$HOSTNAME_FQDN" \
  --tag "node-backup"
rc=$?
set -e

case $rc in
  0) ;;
  3) log "WARNING: snapshot created, but some files could not be read (rc=3)" ;;
  *) fail "restic backup failed (rc=$rc)" "$rc" ;;
esac

# -----------------------------------------------------------------------------
# Forget (cheap; marks old snapshots. Data is removed by the weekly prune.)
# --group-by host,tags keeps retention working even if BACKUP_PATHS changes
# (the default grouping includes paths, which would orphan old snapshots).
# -----------------------------------------------------------------------------
forget_rc=0
RET_ARGS=()
[[ -n "${RETENTION_KEEP_DAILY:-}"   ]] && RET_ARGS+=(--keep-daily   "$RETENTION_KEEP_DAILY")
[[ -n "${RETENTION_KEEP_WEEKLY:-}"  ]] && RET_ARGS+=(--keep-weekly  "$RETENTION_KEEP_WEEKLY")
[[ -n "${RETENTION_KEEP_MONTHLY:-}" ]] && RET_ARGS+=(--keep-monthly "$RETENTION_KEEP_MONTHLY")

if [[ ${#RET_ARGS[@]} -gt 0 ]]; then
  log "Running forget (prune runs separately on its own weekly timer)"
  set +e
  run_logged "restic forget" restic_cmd forget \
    --host "$HOSTNAME_FQDN" --tag node-backup --group-by host,tags \
    "${RET_ARGS[@]}"
  forget_rc=$?
  set -e
  [[ $forget_rc -eq 0 ]] || log "WARNING: forget failed (rc=$forget_rc)"
fi

# -----------------------------------------------------------------------------
# Final status
# -----------------------------------------------------------------------------
problems=()
[[ $pre_rc    -ne 0 ]] && problems+=("pre-backup command failed (rc=$pre_rc)")
[[ $rc        -eq 3 ]] && problems+=("some files could not be read (rc=3)")
[[ $forget_rc -ne 0 ]] && problems+=("forget failed (rc=$forget_rc)")

if [[ ${#problems[@]} -gt 0 ]]; then
  detail="$(IFS=';'; echo "${problems[*]}")"
  write_status "$STATUS_FILE" FAIL "$detail"
  log "Backup finished with problems: $detail"
  exit 1
fi

write_status "$STATUS_FILE" OK "backup_rc=0"

# Post-backup command runs only when everything succeeded, so an external
# dead man's switch pinged from here also catches database dump failures.
if [[ -n "${POST_BACKUP_COMMAND:-}" ]]; then
  log "Running post-backup command"
  set +e
  bash -lc "$POST_BACKUP_COMMAND"
  post_rc=$?
  set -e
  [[ $post_rc -eq 0 ]] || log "WARNING: post-backup command failed (rc=$post_rc)"
fi

log "Backup complete"
