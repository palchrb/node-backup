#!/usr/bin/env bash

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
