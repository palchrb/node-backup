#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo ./install.sh"
  exit 1
fi

echo "== Installing node-backup =="

apt update
apt install -y restic rclone curl

install -d -m 755 /usr/local/lib/node-backup
install -d -m 755 /var/log/node-backup
install -d -m 755 /var/cache/restic

install -m 755 scripts/backup.sh /usr/local/lib/node-backup/backup.sh
install -m 755 scripts/notify.sh /usr/local/lib/node-backup/notify.sh
install -m 644 scripts/lib.sh /usr/local/lib/node-backup/lib.sh

install -m 644 env.example /etc/default/node-backup
install -m 644 excludes.txt /etc/node-backup-excludes.txt

install -m 644 systemd/node-backup.service /etc/systemd/system/node-backup.service
install -m 644 systemd/node-backup.timer /etc/systemd/system/node-backup.timer
install -m 644 systemd/node-backup-notify.service /etc/systemd/system/node-backup-notify.service
install -m 644 systemd/node-backup-notify.timer /etc/systemd/system/node-backup-notify.timer

systemctl daemon-reload

echo
echo "Installed."
echo "Next steps:"
echo "  1. Edit /etc/default/node-backup"
echo "  2. Ensure rclone remote exists"
echo "  3. Enable timers:"
echo "     sudo systemctl enable --now node-backup.timer"
echo "     sudo systemctl enable --now node-backup-notify.timer"
echo
