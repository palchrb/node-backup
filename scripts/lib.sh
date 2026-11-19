#!/usr/bin/env bash
# Shared helpers for node-backup scripts. Sourced, not executed.

log() {
  echo "[$(date -Is)] $*"
}

require_file() {
  local f="$1"
  [[ -f "$f" ]] || { echo "Missing required file: $f" >&2; return 1; }
}

load_env() {
  require_file /etc/default/node-backup
  # shellcheck disable=SC1091
  source /etc/default/node-backup
}

status_file_path() {
  echo "${STATUS_DIR:-/var/log/node-backup}/primary.status"
}

prune_status_file_path() {
  echo "${STATUS_DIR:-/var/log/node-backup}/prune.status"
}

# write_status <file> <STATE> <detail>
# Status file format: "<STATE> <ISO timestamp> <detail>"
# STATE is one of: OK, FAIL, RUNNING
write_status() {
  local f="$1" state="$2" detail="${3:-}"
  mkdir -p "$(dirname "$f")"
  echo "$state $(date -Is) $detail" > "${f}.tmp" && mv "${f}.tmp" "$f"
}

# Run restic with the repository settings from the env file.
# --retry-lock makes restic wait for a lock held by a concurrent job
# (e.g. a backup still running when the weekly prune starts) instead of
# failing immediately.
restic_cmd() {
  env \
    RESTIC_REPOSITORY="$RESTIC_REPOSITORY" \
    RESTIC_PASSWORD="$RESTIC_PASSWORD" \
    RESTIC_CACHE_DIR="${RESTIC_CACHE_DIR:-/var/cache/restic}" \
    RCLONE_CONFIG="$RCLONE_CONFIG" \
    restic --retry-lock "${RESTIC_RETRY_LOCK:-1h}" "$@"
}

# run_logged <label> <command...>
# Runs a command with stderr captured; on failure the captured stderr is
# written to the log (indented) so the reason for the failure is visible.
# Stdout passes through untouched (so it can be piped).
run_logged() {
  local label="$1"; shift
  local errf rc
  errf="$(mktemp)"
  "$@" 2>"$errf"
  rc=$?
  if [[ $rc -ne 0 && -s "$errf" ]]; then
    log "$label: stderr:" >&2
    sed 's/^/    /' "$errf" | tail -n 20 >&2
  fi
  rm -f "$errf"
  return $rc
}
