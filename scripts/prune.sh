#!/usr/bin/env bash
# prune.sh — weekly repository maintenance: prune, then integrity check.
#
# restic forget (run daily in backup.sh) marks old snapshots as unreferenced.
# restic prune (this script) repacks pack files and removes data that no
# snapshot refers to. restic check then verifies the repository structure and
# reads back a random subset of the actual data, so silent corruption on the
# storage backend is detected long before you need to restore.
#
# Status is pessimistic: RUNNING at start, OK only when both steps succeed.
set -euo pipefail

# shellcheck disable=SC1091
source /usr/local/lib/node-backup/lib.sh
load_env

PRUNE_STATUS_FILE="$(prune_status_file_path)"
write_status "$PRUNE_STATUS_FILE" RUNNING "started"

log "Starting restic prune"
set +e
restic_cmd prune
prune_rc=$?
set -e

if [[ $prune_rc -ne 0 ]]; then
  write_status "$PRUNE_STATUS_FILE" FAIL "restic prune failed (rc=$prune_rc)"
  log "ERROR: restic prune failed (rc=$prune_rc)"
  exit $prune_rc
fi
log "Prune complete"

# CHECK_READ_DATA_SUBSET: e.g. "5%" reads a random 5% of all pack data each
# week. Empty = structural check only (no data download).
CHECK_ARGS=()
if [[ -n "${CHECK_READ_DATA_SUBSET:-}" ]]; then
  CHECK_ARGS+=(--read-data-subset="$CHECK_READ_DATA_SUBSET")
fi

log "Starting restic check ${CHECK_ARGS[*]:-}"
set +e
restic_cmd check --with-cache "${CHECK_ARGS[@]}"
check_rc=$?
set -e

if [[ $check_rc -ne 0 ]]; then
  write_status "$PRUNE_STATUS_FILE" FAIL "restic check failed (rc=$check_rc) — repository may be damaged"
  log "ERROR: restic check failed (rc=$check_rc)"
  exit $check_rc
fi

write_status "$PRUNE_STATUS_FILE" OK "prune_rc=0 check_rc=0"
log "Repository maintenance complete"
