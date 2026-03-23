# node-backup

A lightweight, easy-to-roll-out backup system for Linux servers using **restic** and **rclone**.

## Features

- Backs up chosen directories via `restic` to any `rclone`-supported backend
- Automatic `restic init` on first run if the repository does not exist yet
- Configurable retention policy (daily / weekly / monthly)
- Optional **pre-backup** and **post-backup** hooks — run any command or script
- Systemd timer with configurable schedule and randomised jitter
- Webhook failure notifications (Bearer token auth) sent by a separate daily check timer
- Status file for simple health monitoring
- All configuration in a single env file with descriptions for every variable

---

## Quick rollout (per node)

```bash
# 1. Clone or copy the repo
git clone <your-repo-url> /opt/node-backup
cd /opt/node-backup

# 2. Run the installer (installs restic, rclone, scripts, and systemd units)
sudo ./install.sh

# 3. Edit the configuration file
sudo nano /etc/default/node-backup

# 4. Enable and start the timers
sudo systemctl enable --now node-backup.timer
sudo systemctl enable --now node-backup-notify.timer
```

That is all that is needed to get a node backing up on a schedule with failure alerts.

---

## Initial setup checklist

Before enabling the timers, make sure the following are in place:

1. **rclone remote** — configure the backend once and copy `rclone.conf` to the server:
   ```bash
   # On your workstation
   rclone config
   # Copy the resulting config to the target node
   scp ~/.config/rclone/rclone.conf root@<node>:/root/.config/rclone/rclone.conf
   ```

2. **Edit `/etc/default/node-backup`** — set at minimum:
   - `RESTIC_REPOSITORY` — e.g. `rclone:mys3bucket:backups/web01`
   - `RESTIC_PASSWORD` — a long, random password (store it safely)
   - `RCLONE_CONFIG` — path to the rclone config on this node
   - `BACKUP_PATHS` — space-separated list of directories to back up
   - `NODE_BACKUP_NAME` — a human-readable name for this node
   - `WEBHOOK_URL` + `WEBHOOK_BEARER_TOKEN` — if you want failure alerts

3. **Test a manual run** before enabling the timer:
   ```bash
   sudo systemctl start node-backup.service
   sudo journalctl -u node-backup.service -n 200 --no-pager
   ```

---

## Configuration

All configuration lives in `/etc/default/node-backup`. The installer creates this
file from `env.example` on first install. Every variable is documented in that file.

Key variables at a glance:

| Variable | Purpose |
|---|---|
| `RESTIC_REPOSITORY` | Restic repository URL (`rclone:<remote>:<path>`) |
| `RESTIC_PASSWORD` | Repository encryption password |
| `RCLONE_CONFIG` | Path to rclone configuration file |
| `BACKUP_PATHS` | Space-separated directories to back up |
| `EXCLUDES_FILE` | Path to file with exclusion patterns |
| `RETENTION_KEEP_DAILY` | How many daily snapshots to keep |
| `RETENTION_KEEP_WEEKLY` | How many weekly snapshots to keep |
| `RETENTION_KEEP_MONTHLY` | How many monthly snapshots to keep |
| `BACKUP_SCHEDULE` | systemd `OnCalendar` expression for backup time |
| `BACKUP_SCHEDULE_JITTER` | Random delay after schedule to spread load |
| `NOTIFY_SCHEDULE` | systemd `OnCalendar` expression for failure-check time |
| `NODE_BACKUP_NAME` | Node identifier included in webhook alerts |
| `PRE_BACKUP_COMMAND` | Command to run before backup starts |
| `POST_BACKUP_COMMAND` | Command to run after backup succeeds |
| `WEBHOOK_ENABLED` | `1` to enable failure webhook, `0` to disable |
| `WEBHOOK_URL` | Webhook endpoint URL |
| `WEBHOOK_BEARER_TOKEN` | Bearer token for webhook authentication |

---

## Pre- and post-backup hooks

Set `PRE_BACKUP_COMMAND` and/or `POST_BACKUP_COMMAND` in `/etc/default/node-backup`.
Both are executed with `bash -lc "<command>"`.

- If `PRE_BACKUP_COMMAND` exits non-zero, the backup is **aborted** and marked as failed.
- `POST_BACKUP_COMMAND` runs only when the backup itself **succeeded**. A non-zero
  exit code is logged as a warning but does not change the backup status.

Examples:

```bash
# Dump a MySQL database before backup
PRE_BACKUP_COMMAND='mysqldump -u root --all-databases > /var/backups/mysql-all.sql'

# Export data from a Docker container
PRE_BACKUP_COMMAND='docker exec myapp /app/bin/export.sh'

# Send a Slack success message after backup
POST_BACKUP_COMMAND='/usr/local/bin/notify-slack-success.sh'
```

---

## Webhook notifications

The `node-backup-notify.timer` runs once per day (default 09:00) and checks whether
the last backup succeeded. If not, it POSTs a JSON payload to `WEBHOOK_URL`:

```json
{
  "service": "node-backup",
  "node": "web01",
  "host": "web01.example.com",
  "status": "FAIL",
  "timestamp": "2026-03-23T03:31:00+00:00",
  "message": "Backup failed on web01.example.com at 2026-03-23T03:31:00+00:00"
}
```

The request includes `Authorization: Bearer <WEBHOOK_BEARER_TOKEN>`.

Set `NOTIFY_SCHEDULE` to a time comfortably after your latest expected backup
completion (`BACKUP_SCHEDULE` + `BACKUP_SCHEDULE_JITTER` + estimated runtime).

---

## Changing the schedule after install

Edit `/etc/default/node-backup` to update `BACKUP_SCHEDULE`, `BACKUP_SCHEDULE_JITTER`,
and `NOTIFY_SCHEDULE`, then re-run the installer to apply the new timers:

```bash
sudo ./install.sh
```

The installer will not overwrite your existing `/etc/default/node-backup`.

---

## Restore

```bash
source /etc/default/node-backup
sudo mkdir -p /restore/test
sudo env \
  RESTIC_REPOSITORY="$RESTIC_REPOSITORY" \
  RESTIC_PASSWORD="$RESTIC_PASSWORD" \
  RCLONE_CONFIG="$RCLONE_CONFIG" \
  restic restore latest --target /restore/test
```

List available snapshots:

```bash
sudo env \
  RESTIC_REPOSITORY="$RESTIC_REPOSITORY" \
  RESTIC_PASSWORD="$RESTIC_PASSWORD" \
  RCLONE_CONFIG="$RCLONE_CONFIG" \
  restic snapshots
```

---

## Requirements

- Linux with systemd
- `restic` and `rclone` (installed automatically by `install.sh` on Debian/Ubuntu)
- A configured rclone remote for your chosen storage backend
- `curl` (for webhook notifications)
