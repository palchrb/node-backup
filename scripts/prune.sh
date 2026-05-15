#!/usr/bin/env bash
# prune.sh — repack and remove unreferenced data from the restic repository
#
# Runs weekly via node-backup-prune.timer. Separated from the daily backup
# so that backup + forget stays fast and light every day, while the
# RAM-intensive repack step only runs once a week.
#
# restic forget (run daily in backup.sh) marks old snapshots as unreferenced.
# restic prune (this script) does the actual work: it repacks pack files,
# removes data that no snapshot refers to, and updates the index.
set -euo pipefail

# shellcheck disable=SC1091
source /usr/local/lib/node-backup/lib.sh
load_env

PRUNE_STATUS_FILE="$(prune_status_file_path)"

log "Starting restic prune"
set +e
env \
  RESTIC_REPOSITORY="$RESTIC_REPOSITORY" \
  RESTIC_PASSWORD="$RESTIC_PASSWORD" \
  RESTIC_CACHE_DIR="${RESTIC_CACHE_DIR:-/var/cache/restic}" \
  RCLONE_CONFIG="$RCLONE_CONFIG" \
  restic prune
prune_rc=$?
set -e

if [[ $prune_rc -ne 0 ]]; then
  echo "FAIL $(date -Is) prune_rc=$prune_rc" > "$PRUNE_STATUS_FILE"
  log "ERROR: restic prune failed (rc=$prune_rc)"
  exit $prune_rc
fi

echo "OK $(date -Is) prune_rc=0" > "$PRUNE_STATUS_FILE"
log "Prune complete"
