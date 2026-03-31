#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# node-backup installer
# Run as root: sudo ./install.sh
# Safe to re-run: scripts and systemd units are always updated; the config
# file and excludes file are never overwritten after first install.
# =============================================================================

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Run as root: sudo ./install.sh"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "== node-backup installer =="
echo

# -----------------------------------------------------------------------------
# 1. Install dependencies
# -----------------------------------------------------------------------------
echo ">> Installing dependencies (restic, rclone, curl)..."
apt-get update -q
apt-get install -y restic rclone curl

# -----------------------------------------------------------------------------
# 2. Create directories
# -----------------------------------------------------------------------------
install -d -m 755 /usr/local/lib/node-backup
install -d -m 755 /var/log/node-backup
install -d -m 755 /var/cache/restic

# -----------------------------------------------------------------------------
# 3. Install scripts
# -----------------------------------------------------------------------------
echo ">> Installing scripts..."
install -m 755 "$SCRIPT_DIR/scripts/backup.sh"           /usr/local/lib/node-backup/backup.sh
install -m 755 "$SCRIPT_DIR/scripts/notify.sh"           /usr/local/lib/node-backup/notify.sh
install -m 755 "$SCRIPT_DIR/scripts/prune.sh"            /usr/local/lib/node-backup/prune.sh
install -m 755 "$SCRIPT_DIR/scripts/pg-dump-all.sh"      /usr/local/lib/node-backup/pg-dump-all.sh
install -m 755 "$SCRIPT_DIR/scripts/mariadb-dump-all.sh" /usr/local/lib/node-backup/mariadb-dump-all.sh
install -m 644 "$SCRIPT_DIR/scripts/lib.sh"              /usr/local/lib/node-backup/lib.sh

# -----------------------------------------------------------------------------
# 4. Install configuration file (only on first install — never overwrite)
# -----------------------------------------------------------------------------
if [[ ! -f /etc/default/node-backup ]]; then
  install -m 640 -o root -g root "$SCRIPT_DIR/env.example" /etc/default/node-backup
  echo ">> Created /etc/default/node-backup from template."
  echo "   Edit this file before enabling the timers."
else
  echo ">> /etc/default/node-backup already exists — not overwritten."
fi

# -----------------------------------------------------------------------------
# 5. Install excludes file (only on first install — never overwrite)
# -----------------------------------------------------------------------------
if [[ ! -f /etc/node-backup-excludes.txt ]]; then
  install -m 644 "$SCRIPT_DIR/excludes.txt" /etc/node-backup-excludes.txt
  echo ">> Created /etc/node-backup-excludes.txt."
else
  echo ">> /etc/node-backup-excludes.txt already exists — not overwritten."
fi

# -----------------------------------------------------------------------------
# 6. Source config to read install-time values
# -----------------------------------------------------------------------------
# Source whichever file is available. The env file contains only variable
# assignments and is safe to source directly — the same mechanism used by the
# backup scripts at runtime via lib.sh:load_env().
_env_source=/etc/default/node-backup
[[ -f "$_env_source" ]] || _env_source="$SCRIPT_DIR/env.example"
# shellcheck disable=SC1090
source "$_env_source"

BACKUP_SCHEDULE="${BACKUP_SCHEDULE:-*-*-* 03:30:00}"
BACKUP_SCHEDULE_JITTER="${BACKUP_SCHEDULE_JITTER:-20min}"
NOTIFY_SCHEDULE="${NOTIFY_SCHEDULE:-*-*-* 09:00:00}"
PRUNE_SCHEDULE="${PRUNE_SCHEDULE:-Sun *-*-* 04:30:00}"
BACKUP_MEMORY_MAX="${BACKUP_MEMORY_MAX:-1500M}"
PRUNE_MEMORY_MAX="${PRUNE_MEMORY_MAX:-2G}"

echo ">> Applying configuration:"
echo "   BACKUP_SCHEDULE        = $BACKUP_SCHEDULE"
echo "   BACKUP_SCHEDULE_JITTER = $BACKUP_SCHEDULE_JITTER"
echo "   NOTIFY_SCHEDULE        = $NOTIFY_SCHEDULE"
echo "   PRUNE_SCHEDULE         = $PRUNE_SCHEDULE"
echo "   BACKUP_MEMORY_MAX      = $BACKUP_MEMORY_MAX"
echo "   PRUNE_MEMORY_MAX       = $PRUNE_MEMORY_MAX"

# -----------------------------------------------------------------------------
# 7. Install systemd units with config substituted
# -----------------------------------------------------------------------------
echo ">> Installing systemd units..."

install -m 644 "$SCRIPT_DIR/systemd/node-backup-notify.service" /etc/systemd/system/node-backup-notify.service

sed \
  -e "s|%%BACKUP_MEMORY_MAX%%|${BACKUP_MEMORY_MAX}|g" \
  "$SCRIPT_DIR/systemd/node-backup.service" \
  > /etc/systemd/system/node-backup.service

sed \
  -e "s|%%PRUNE_MEMORY_MAX%%|${PRUNE_MEMORY_MAX}|g" \
  "$SCRIPT_DIR/systemd/node-backup-prune.service" \
  > /etc/systemd/system/node-backup-prune.service

sed \
  -e "s|%%BACKUP_SCHEDULE%%|${BACKUP_SCHEDULE}|g" \
  -e "s|%%BACKUP_SCHEDULE_JITTER%%|${BACKUP_SCHEDULE_JITTER}|g" \
  "$SCRIPT_DIR/systemd/node-backup.timer" \
  > /etc/systemd/system/node-backup.timer

sed \
  -e "s|%%NOTIFY_SCHEDULE%%|${NOTIFY_SCHEDULE}|g" \
  "$SCRIPT_DIR/systemd/node-backup-notify.timer" \
  > /etc/systemd/system/node-backup-notify.timer

sed \
  -e "s|%%PRUNE_SCHEDULE%%|${PRUNE_SCHEDULE}|g" \
  "$SCRIPT_DIR/systemd/node-backup-prune.timer" \
  > /etc/systemd/system/node-backup-prune.timer

chmod 644 \
  /etc/systemd/system/node-backup.service \
  /etc/systemd/system/node-backup.timer \
  /etc/systemd/system/node-backup-prune.service \
  /etc/systemd/system/node-backup-prune.timer \
  /etc/systemd/system/node-backup-notify.timer

systemctl daemon-reload

# -----------------------------------------------------------------------------
# Done
# -----------------------------------------------------------------------------
echo
echo "======================================================================"
echo " node-backup installed successfully"
echo "======================================================================"
echo
echo "Next steps:"
echo
echo "  1. Edit the configuration file:"
echo "       sudo nano /etc/default/node-backup"
echo
echo "     At minimum set:"
echo "       RESTIC_REPOSITORY    — e.g. rclone:mybucket:backups/$(hostname -s)"
echo "       RESTIC_PASSWORD      — a long, random password"
echo "       RCLONE_CONFIG        — path to your rclone.conf (use /root/.config/rclone/rclone.conf)"
echo "       BACKUP_PATHS         — space-separated paths to back up"
echo "       NODE_BACKUP_NAME     — human-readable name for this node"
echo "       WEBHOOK_URL          — URL to receive failure alerts"
echo "       WEBHOOK_BEARER_TOKEN"
echo
echo "  2. Ensure the rclone remote is configured on this node:"
echo "       rclone listremotes"
echo
echo "  3. Test a manual run:"
echo "       sudo systemctl start node-backup.service"
echo "       sudo journalctl -u node-backup.service -n 200 --no-pager"
echo
echo "  4. Enable the timers:"
echo "       sudo systemctl enable --now node-backup.timer"
echo "       sudo systemctl enable --now node-backup-notify.timer"
echo "       sudo systemctl enable --now node-backup-prune.timer"
echo
echo "  Tip: After changing any schedule or memory limit in the config,"
echo "  re-run this installer to apply the changes to the systemd units."
echo
