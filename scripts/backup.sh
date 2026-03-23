#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source /usr/local/lib/node-backup/lib.sh
load_env

mkdir -p "${STATUS_DIR:-/var/log/node-backup}" "${RESTIC_CACHE_DIR:-/var/cache/restic}"
STATUS_FILE="$(status_file_path)"
HOSTNAME_FQDN="$(hostname -f 2>/dev/null || hostname)"

IFS=' ' read -r -a ALL_PATHS <<< "${BACKUP_PATHS:-/etc /var/backups}"
PATHS=()
for p in "${ALL_PATHS[@]}"; do
  [[ -e "$p" ]] || { log "$p does not exist, skipping"; continue; }
  PATHS+=("$p")
done

if [[ ${#PATHS[@]} -eq 0 ]]; then
  echo "FAIL $(date -Is) backup_rc=98" > "$STATUS_FILE"
  log "ERROR: no valid backup paths found"
  exit 98
fi

RET_ARGS=()
[[ -n "${RETENTION_KEEP_DAILY:-}"   ]] && RET_ARGS+=(--keep-daily   "$RETENTION_KEEP_DAILY")
[[ -n "${RETENTION_KEEP_WEEKLY:-}"  ]] && RET_ARGS+=(--keep-weekly  "$RETENTION_KEEP_WEEKLY")
[[ -n "${RETENTION_KEEP_MONTHLY:-}" ]] && RET_ARGS+=(--keep-monthly "$RETENTION_KEEP_MONTHLY")

IONICE=(ionice -c2 -n7 nice -n 19)

if [[ -n "${PRE_BACKUP_COMMAND:-}" ]]; then
  log "Running pre-backup command"
  set +e
  bash -lc "$PRE_BACKUP_COMMAND"
  pre_rc=$?
  set -e
  if [[ $pre_rc -ne 0 ]]; then
    echo "FAIL $(date -Is) backup_rc=97" > "$STATUS_FILE"
    log "ERROR: pre-backup command failed (rc=$pre_rc)"
    exit 97
  fi
fi

# init repo if missing
log "Checking restic repository"
set +e
env \
  RESTIC_REPOSITORY="$RESTIC_REPOSITORY" \
  RESTIC_PASSWORD="$RESTIC_PASSWORD" \
  RCLONE_CONFIG="$RCLONE_CONFIG" \
  restic snapshots >/dev/null 2>&1
repo_rc=$?
set -e

if [[ $repo_rc -ne 0 ]]; then
  log "Repository not ready, trying restic init"
  env \
    RESTIC_REPOSITORY="$RESTIC_REPOSITORY" \
    RESTIC_PASSWORD="$RESTIC_PASSWORD" \
    RCLONE_CONFIG="$RCLONE_CONFIG" \
    restic init || true
fi

log "Starting restic backup -> $RESTIC_REPOSITORY"
set +e
env \
  RESTIC_REPOSITORY="$RESTIC_REPOSITORY" \
  RESTIC_PASSWORD="$RESTIC_PASSWORD" \
  RESTIC_CACHE_DIR="$RESTIC_CACHE_DIR" \
  RCLONE_CONFIG="$RCLONE_CONFIG" \
  "${IONICE[@]}" \
  restic backup "${PATHS[@]}" \
    --exclude-file="$EXCLUDES_FILE" \
    --host "$HOSTNAME_FQDN" \
    --tag "$HOSTNAME_FQDN" \
    --tag "node-backup"
rc=$?
set -e

if [[ $rc -eq 0 ]]; then
  echo "OK $(date -Is) backup_rc=0" > "$STATUS_FILE"
else
  echo "FAIL $(date -Is) backup_rc=$rc" > "$STATUS_FILE"
  log "ERROR: restic backup failed (rc=$rc)"
  exit $rc
fi

if [[ ${#RET_ARGS[@]} -gt 0 ]]; then
  log "Running forget --prune"
  set +e
  env \
    RESTIC_REPOSITORY="$RESTIC_REPOSITORY" \
    RESTIC_PASSWORD="$RESTIC_PASSWORD" \
    RESTIC_CACHE_DIR="$RESTIC_CACHE_DIR" \
    RCLONE_CONFIG="$RCLONE_CONFIG" \
    restic forget --prune "${RET_ARGS[@]}"
  prune_rc=$?
  set -e

  if [[ $prune_rc -ne 0 ]]; then
    log "WARNING: forget/prune failed (rc=$prune_rc)"
  fi
fi

log "Unlock cleanup"
set +e
env \
  RESTIC_REPOSITORY="$RESTIC_REPOSITORY" \
  RESTIC_PASSWORD="$RESTIC_PASSWORD" \
  RCLONE_CONFIG="$RCLONE_CONFIG" \
  restic unlock >/dev/null 2>&1
set -e

if [[ -n "${POST_BACKUP_COMMAND:-}" ]]; then
  log "Running post-backup command"
  set +e
  bash -lc "$POST_BACKUP_COMMAND"
  post_rc=$?
  set -e
  if [[ $post_rc -ne 0 ]]; then
    log "WARNING: post-backup command failed (rc=$post_rc)"
  fi
fi

log "Backup complete"
