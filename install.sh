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
echo ">> Installing dependencies (curl, bzip2, unzip)..."
apt-get update -q
apt-get install -y curl bzip2 unzip ca-certificates
# restic and rclone themselves are installed from their official release
# downloads in step 6b — distro packages are often several years behind.

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
install -m 755 "$SCRIPT_DIR/scripts/node-backup-restic"  /usr/local/sbin/node-backup-restic

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
BACKUP_TIMEOUT="${BACKUP_TIMEOUT:-12h}"
PRUNE_TIMEOUT="${PRUNE_TIMEOUT:-24h}"
RESTIC_VERSION="${RESTIC_VERSION:-latest}"
RCLONE_VERSION="${RCLONE_VERSION:-latest}"

# -----------------------------------------------------------------------------
# 6b. Install restic from the official GitHub release (SHA256-verified)
# -----------------------------------------------------------------------------
install_restic() {
  local arch ver current tmp file
  case "$(uname -m)" in
    x86_64)        arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    armv7l|armv6l) arch=arm ;;
    i386|i686)     arch=386 ;;
    *) echo "ERROR: unsupported architecture $(uname -m)"; return 1 ;;
  esac

  if [[ "$RESTIC_VERSION" == "latest" ]]; then
    # Follow the /releases/latest redirect to .../tag/vX.Y.Z (no API token needed)
    ver="$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
      https://github.com/restic/restic/releases/latest)" || return 1
    ver="${ver##*/v}"
  else
    ver="${RESTIC_VERSION#v}"
  fi
  [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "ERROR: could not determine restic version (got '$ver')"; return 1; }

  current="$(/usr/local/bin/restic version 2>/dev/null | awk '{print $2}')" || true
  if [[ "$current" == "$ver" ]]; then
    echo ">> restic $ver already installed"
    return 0
  fi

  echo ">> Installing restic $ver (${current:+replacing $current, }linux/$arch)..."
  tmp="$(mktemp -d)"
  file="restic_${ver}_linux_${arch}.bz2"
  if ! curl -fsSL -o "$tmp/$file"      "https://github.com/restic/restic/releases/download/v${ver}/${file}" \
     || ! curl -fsSL -o "$tmp/SHA256SUMS" "https://github.com/restic/restic/releases/download/v${ver}/SHA256SUMS"; then
    rm -rf "$tmp"; echo "ERROR: download failed"; return 1
  fi
  if ! (cd "$tmp" && grep " ${file}\$" SHA256SUMS | sha256sum -c --quiet -); then
    rm -rf "$tmp"; echo "ERROR: restic checksum verification FAILED — not installing"; return 1
  fi
  bunzip2 "$tmp/$file"
  install -m 755 "$tmp/${file%.bz2}" /usr/local/bin/restic
  rm -rf "$tmp"
  /usr/local/bin/restic version
}

if ! install_restic; then
  if [[ -x /usr/local/bin/restic ]]; then
    echo "WARNING: restic install/upgrade failed — keeping existing $(/usr/local/bin/restic version)"
  else
    echo "ERROR: restic could not be installed and none is present. Aborting."
    exit 1
  fi
fi

# -----------------------------------------------------------------------------
# 6c. Install rclone from the official download site (SHA256-verified)
# -----------------------------------------------------------------------------
install_rclone() {
  local arch ver current tmp file base
  case "$(uname -m)" in
    x86_64)        arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    armv7l)        arch=arm-v7 ;;
    armv6l)        arch=arm ;;
    i386|i686)     arch=386 ;;
    *) echo "ERROR: unsupported architecture $(uname -m)"; return 1 ;;
  esac

  if [[ "$RCLONE_VERSION" == "latest" ]]; then
    # version.txt contains e.g. "rclone v1.76.0"
    ver="$(curl -fsSL https://downloads.rclone.org/version.txt)" || return 1
    ver="${ver##*v}"
  else
    ver="${RCLONE_VERSION#v}"
  fi
  ver="$(echo "$ver" | tr -d '[:space:]')"
  [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "ERROR: could not determine rclone version (got '$ver')"; return 1; }

  current="$(/usr/local/bin/rclone version 2>/dev/null | awk 'NR==1{print $2}')" || true
  current="${current#v}"
  if [[ "$current" == "$ver" ]]; then
    echo ">> rclone $ver already installed"
    return 0
  fi

  echo ">> Installing rclone $ver (${current:+replacing $current, }linux/$arch)..."
  tmp="$(mktemp -d)"
  base="rclone-v${ver}-linux-${arch}"
  file="${base}.zip"
  if ! curl -fsSL -o "$tmp/$file"      "https://downloads.rclone.org/v${ver}/${file}" \
     || ! curl -fsSL -o "$tmp/SHA256SUMS" "https://downloads.rclone.org/v${ver}/SHA256SUMS"; then
    rm -rf "$tmp"; echo "ERROR: download failed"; return 1
  fi
  if ! (cd "$tmp" && grep " ${file}\$" SHA256SUMS | sha256sum -c --quiet -); then
    rm -rf "$tmp"; echo "ERROR: rclone checksum verification FAILED — not installing"; return 1
  fi
  unzip -q "$tmp/$file" -d "$tmp"
  install -m 755 "$tmp/$base/rclone" /usr/local/bin/rclone
  rm -rf "$tmp"
  /usr/local/bin/rclone version | head -1
}

if ! install_rclone; then
  if [[ -x /usr/local/bin/rclone ]]; then
    echo "WARNING: rclone install/upgrade failed — keeping existing $(/usr/local/bin/rclone version | head -1)"
  else
    echo "ERROR: rclone could not be installed and none is present. Aborting."
    exit 1
  fi
fi

for pkg in restic rclone; do
  if dpkg -s "$pkg" &>/dev/null; then
    echo "NOTE: the distro '$pkg' package is also installed (/usr/bin/$pkg)."
    echo "      /usr/local/bin/$pkg takes precedence. Remove it with: apt-get remove $pkg"
  fi
done

echo ">> Applying configuration:"
echo "   BACKUP_SCHEDULE        = $BACKUP_SCHEDULE"
echo "   BACKUP_SCHEDULE_JITTER = $BACKUP_SCHEDULE_JITTER"
echo "   NOTIFY_SCHEDULE        = $NOTIFY_SCHEDULE"
echo "   PRUNE_SCHEDULE         = $PRUNE_SCHEDULE"
echo "   BACKUP_MEMORY_MAX      = $BACKUP_MEMORY_MAX"
echo "   PRUNE_MEMORY_MAX       = $PRUNE_MEMORY_MAX"
echo "   BACKUP_TIMEOUT         = $BACKUP_TIMEOUT"
echo "   PRUNE_TIMEOUT          = $PRUNE_TIMEOUT"

# -----------------------------------------------------------------------------
# 7. Install systemd units with config substituted
# -----------------------------------------------------------------------------
echo ">> Installing systemd units..."

install -m 644 "$SCRIPT_DIR/systemd/node-backup-notify.service" /etc/systemd/system/node-backup-notify.service

sed \
  -e "s|%%BACKUP_MEMORY_MAX%%|${BACKUP_MEMORY_MAX}|g" \
  -e "s|%%BACKUP_TIMEOUT%%|${BACKUP_TIMEOUT}|g" \
  "$SCRIPT_DIR/systemd/node-backup.service" \
  > /etc/systemd/system/node-backup.service

sed \
  -e "s|%%PRUNE_MEMORY_MAX%%|${PRUNE_MEMORY_MAX}|g" \
  -e "s|%%PRUNE_TIMEOUT%%|${PRUNE_TIMEOUT}|g" \
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

if grep -l '%%[A-Z_]*%%' /etc/systemd/system/node-backup*.service /etc/systemd/system/node-backup*.timer 2>/dev/null; then
  echo "ERROR: unreplaced placeholders in the systemd units listed above"
  exit 1
fi

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
echo "  4. Verify you can list snapshots and restore:"
echo "       sudo node-backup-restic snapshots"
echo
echo "  5. Store RESTIC_PASSWORD and rclone.conf OUTSIDE this node (password manager)."
echo "     Without them the backups cannot be restored if this node is lost."
echo
echo "  6. Enable the timers:"
echo "       sudo systemctl enable --now node-backup.timer"
echo "       sudo systemctl enable --now node-backup-notify.timer"
echo "       sudo systemctl enable --now node-backup-prune.timer"
echo
echo "  Tip: After changing any schedule or memory limit in the config,"
echo "  re-run this installer to apply the changes to the systemd units."
echo
