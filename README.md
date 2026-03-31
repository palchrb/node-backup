# node-backup

A lightweight, easy-to-roll-out backup system for Linux servers using **restic** and **rclone**.

## Features

- Backs up chosen directories via `restic` to any `rclone`-supported backend
- Automatic `restic init` on first run if the repository does not exist yet
- Configurable retention policy (daily / weekly / monthly)
- Optional **pre-backup** and **post-backup** hooks — run any command or script
- Auto-discovery dump scripts for **PostgreSQL** and **MariaDB/MySQL** (bare metal + Docker)
- Three systemd timers with fully configurable schedules: backup, failure notification, weekly prune
- Hard memory caps on all restic processes — protects host RAM on memory-constrained servers
- Webhook failure notifications (Bearer token auth)
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
sudo systemctl enable --now node-backup-prune.timer
```

That is all that is needed to get a node backing up on a schedule with failure alerts and
weekly repository maintenance.

---

## Initial setup checklist

Before enabling the timers, make sure the following are in place:

1. **rclone remote** — configure the backend once and copy `rclone.conf` to the server.
   Always store the rclone config under `/root/` so the backup service (which runs as root)
   can write refreshed OAuth tokens back to it without changing ownership of your user config:
   ```bash
   # On your workstation
   rclone config
   # Copy to the target node — use the root home directory
   scp ~/.config/rclone/rclone.conf root@<node>:/root/.config/rclone/rclone.conf
   ```

2. **Edit `/etc/default/node-backup`** — set at minimum:
   - `RESTIC_REPOSITORY` — e.g. `rclone:mys3bucket:backups/web01`
   - `RESTIC_PASSWORD` — a long, random password (store it safely)
   - `RCLONE_CONFIG` — `/root/.config/rclone/rclone.conf`
   - `BACKUP_PATHS` — space-separated list of directories to back up
   - `NODE_BACKUP_NAME` — a human-readable name for this node
   - `WEBHOOK_URL` + `WEBHOOK_BEARER_TOKEN` — if you want failure alerts

3. **Test a manual run** before enabling the timers:
   ```bash
   sudo systemctl start node-backup.service
   sudo journalctl -u node-backup.service -n 200 --no-pager
   ```

---

## Configuration

All configuration lives in `/etc/default/node-backup`. The installer creates this file
from `env.example` on first install and never overwrites it again. Every variable is
documented in that file.

Key variables at a glance:

| Variable | Purpose |
|---|---|
| `RESTIC_REPOSITORY` | Restic repository URL (`rclone:<remote>:<path>`) |
| `RESTIC_PASSWORD` | Repository encryption password |
| `RCLONE_CONFIG` | Path to rclone config — use `/root/.config/rclone/rclone.conf` |
| `BACKUP_PATHS` | Space-separated directories to back up |
| `EXCLUDES_FILE` | Path to file with exclusion patterns |
| `RETENTION_KEEP_DAILY` | How many daily snapshots to keep |
| `RETENTION_KEEP_WEEKLY` | How many weekly snapshots to keep |
| `RETENTION_KEEP_MONTHLY` | How many monthly snapshots to keep |
| `BACKUP_SCHEDULE` | When to run the backup (`OnCalendar` syntax) |
| `BACKUP_SCHEDULE_JITTER` | Random delay after schedule to spread load across nodes |
| `NOTIFY_SCHEDULE` | When to run the failure-check notification |
| `PRUNE_SCHEDULE` | When to run the weekly restic prune |
| `BACKUP_MEMORY_MAX` | Hard RAM cap for the backup process (default `1500M`) |
| `PRUNE_MEMORY_MAX` | Hard RAM cap for the prune process (default `2G`) |
| `NODE_BACKUP_NAME` | Node identifier included in webhook alerts |
| `PRE_BACKUP_COMMAND` | Command to run before backup starts |
| `POST_BACKUP_COMMAND` | Command to run after backup succeeds |
| `WEBHOOK_ENABLED` | `1` to enable failure webhook, `0` to disable |
| `WEBHOOK_URL` | Webhook endpoint URL |
| `WEBHOOK_BEARER_TOKEN` | Bearer token for webhook authentication |

---

## Systemd timers

There are three timers. All schedules are configured in `/etc/default/node-backup` and
applied by re-running `install.sh`.

| Timer | Default schedule | What it does |
|---|---|---|
| `node-backup.timer` | Daily at 03:30 + up to 20 min jitter | Runs backup, then `restic forget` |
| `node-backup-notify.timer` | Daily at 09:00 | Checks status file; fires webhook if last backup failed |
| `node-backup-prune.timer` | Sunday at 04:30 | Runs `restic prune` — repacks the repository |

Check timer status at any time:

```bash
systemctl list-timers 'node-backup*'
```

---

## Memory management

restic's memory usage splits across two very different operations:

**`restic backup` + `restic forget`** (daily) — relatively light. Forget only marks old
snapshots as unreferenced in the index; it does not touch pack files or load them into
memory. A few hundred MB is typical even for large repositories.

**`restic prune`** (weekly) — RAM-intensive. Prune loads the full pack index, identifies
unreferenced blobs across all packs, and rewrites affected pack files. On repositories
with many files or many snapshots this can spike to 1–3 GB.

To protect the host from being OOM-killed, both systemd services have a hard `MemoryMax=`
cgroup limit applied at install time:

```
BACKUP_MEMORY_MAX="1500M"   # backup service (backup + forget)
PRUNE_MEMORY_MAX="2G"       # prune service
```

If restic is killed by the memory cap you will see exit code 137 in the logs:

```bash
sudo journalctl -u node-backup-prune.service -n 50 --no-pager
```

Raise the limit in `/etc/default/node-backup` and re-run `install.sh` to apply it.

**Tuning guidelines by server RAM:**

| Server RAM | `BACKUP_MEMORY_MAX` | `PRUNE_MEMORY_MAX` |
|---|---|---|
| 2 GB | `500M` | `800M` |
| 4 GB | `800M` | `1200M` |
| 8 GB | `1500M` | `2G` (default) |
| 16 GB+ | `2G` | `4G` |

These are conservative starting points. Monitor actual usage with:

```bash
# While a backup or prune is running:
systemd-cgtop -n 1 /system.slice/node-backup.service
systemd-cgtop -n 1 /system.slice/node-backup-prune.service
```

---

## forget vs prune — why they are separated

restic repository cleanup is a two-step process:

1. **`restic forget`** — removes snapshot references according to the retention policy
   (keep 7 daily, 4 weekly, 6 monthly, etc.). This is fast and cheap: it only rewrites
   the snapshot index. No pack files are touched. Runs after every daily backup.

2. **`restic prune`** — scans all pack files to find blobs no snapshot references
   anymore, rewrites affected packs, and updates the index. This is the RAM- and
   IO-intensive step. Runs once per week.

Running `forget` daily without `prune` means the repository accumulates some unreferenced
data between weekly prune runs. The amount is bounded by one week of backup churn — in
practice a few percent of repository size at most. This is a worthwhile trade-off: daily
backups stay fast and low-memory, and the heavy work is deferred to a quiet window once
a week.

To run prune manually at any time:

```bash
sudo systemctl start node-backup-prune.service
sudo journalctl -u node-backup-prune.service -f
```

---

## Pre- and post-backup hooks

Set `PRE_BACKUP_COMMAND` and/or `POST_BACKUP_COMMAND` in `/etc/default/node-backup`.
Both are executed with `bash -lc "<command>"`.

- If `PRE_BACKUP_COMMAND` exits non-zero, the backup is **aborted** and marked as failed.
- `POST_BACKUP_COMMAND` runs only when the backup itself **succeeded**. A non-zero
  exit code is logged as a warning but does not change the backup status.

Examples:

```bash
# Auto-dump all PostgreSQL databases (bare metal + Docker) — see section below
PRE_BACKUP_COMMAND='/usr/local/lib/node-backup/pg-dump-all.sh'

# Both PostgreSQL and MariaDB
PRE_BACKUP_COMMAND='/usr/local/lib/node-backup/pg-dump-all.sh && /usr/local/lib/node-backup/mariadb-dump-all.sh'

# Send a healthcheck ping after a successful backup
POST_BACKUP_COMMAND='curl -fsS https://hc-ping.com/your-uuid'
```

---

## PostgreSQL dumps

`pg-dump-all.sh` auto-discovers and dumps every PostgreSQL instance on the node before
each backup run. There is only ever **one dump file per source on disk** — files are
overwritten each run. Restic snapshots them, so retention follows your normal policy.

**What it finds:**
- A local bare metal PostgreSQL install — detected via `pg_isready`, dumped with
  `pg_dumpall` running as the `postgres` OS user (Unix socket peer auth, no password)
- Any running Docker container whose image name contains `postgres` or `postgis`, or
  that has `POSTGRES_USER` / `POSTGRES_DB` / `POSTGRES_PASSWORD` environment variables

**Enable** in `/etc/default/node-backup`:

```bash
PRE_BACKUP_COMMAND='/usr/local/lib/node-backup/pg-dump-all.sh'
BACKUP_PATHS="/etc /var/backups /srv/docker"   # /var/backups covers the dump dir
```

Dumps land in `PG_DUMP_DIR` (default `/var/backups/postgresql`):

```
/var/backups/postgresql/
  local.sql.gz
  docker_myapp-postgres-1.sql.gz
  docker_invoicing-db.sql.gz
```

| Variable | `auto` | `1` | `0` |
|---|---|---|---|
| `PG_DUMP_LOCAL` | dump if postgres is running | always require | skip |
| `PG_DUMP_DOCKER` | dump if docker is available | always require | skip |

**Restore:**

```bash
# From live disk
gunzip -c /var/backups/postgresql/local.sql.gz | sudo -u postgres psql

# From a restic snapshot
source /etc/default/node-backup
sudo env RESTIC_REPOSITORY="$RESTIC_REPOSITORY" RESTIC_PASSWORD="$RESTIC_PASSWORD" \
  RCLONE_CONFIG="$RCLONE_CONFIG" \
  restic restore latest --target /restore --include /var/backups/postgresql
gunzip -c /restore/var/backups/postgresql/docker_myapp.sql.gz | docker exec -i myapp psql -U postgres
```

---

## MariaDB / MySQL dumps

`mariadb-dump-all.sh` works the same way for MariaDB and MySQL.

**What it finds:**
- A local bare metal MariaDB/MySQL install — detected via `mysqladmin status`, connected
  as root via Unix socket (`unix_socket` auth, no password on default Debian/Ubuntu)
- Any running Docker container whose image name contains `mariadb` or `mysql`, or that
  has `MYSQL_ROOT_PASSWORD` / `MARIADB_ROOT_PASSWORD` / `MYSQL_DATABASE` env vars.
  The root password is read from the container environment automatically.

Dumps use `--single-transaction` for consistent InnoDB snapshots without table locks.

**Enable** in `/etc/default/node-backup`:

```bash
# MariaDB only
PRE_BACKUP_COMMAND='/usr/local/lib/node-backup/mariadb-dump-all.sh'

# Both PostgreSQL and MariaDB
PRE_BACKUP_COMMAND='/usr/local/lib/node-backup/pg-dump-all.sh && /usr/local/lib/node-backup/mariadb-dump-all.sh'
```

Dumps land in `MARIADB_DUMP_DIR` (default `/var/backups/mariadb`):

```
/var/backups/mariadb/
  local.sql.gz
  docker_myapp-mariadb-1.sql.gz
```

| Variable | `auto` | `1` | `0` |
|---|---|---|---|
| `MARIADB_DUMP_LOCAL` | dump if MariaDB is running | always require | skip |
| `MARIADB_DUMP_DOCKER` | dump if docker is available | always require | skip |

**Restore:**

```bash
gunzip -c /var/backups/mariadb/local.sql.gz | mysql --user=root
gunzip -c /var/backups/mariadb/docker_myapp.sql.gz | docker exec -i myapp mysql -u root --password=<pass>
```

---

## Dump file rotation

Dump files on disk are **not rotated** — each run overwrites the same file. There is
exactly one dump per database source on the host filesystem at all times. Restic captures
a snapshot of that file during each backup run, so the number of historical dump copies in
the repository is controlled entirely by your retention policy (`RETENTION_KEEP_DAILY`,
`RETENTION_KEEP_WEEKLY`, `RETENTION_KEEP_MONTHLY`). No separate rotation tooling needed.

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

## rclone config and root ownership

The backup service runs as root. If `RCLONE_CONFIG` points to a file under `/home/`,
rclone will write refreshed OAuth tokens back to that file as root — changing ownership
and locking your user account out of their own config. Always use a root-owned path:

```bash
RCLONE_CONFIG="/root/.config/rclone/rclone.conf"
```

Copy your existing config there once:

```bash
sudo mkdir -p /root/.config/rclone
sudo cp ~/.config/rclone/rclone.conf /root/.config/rclone/rclone.conf
sudo chmod 600 /root/.config/rclone/rclone.conf
```

---

## Changing schedule or memory limits after install

Edit `/etc/default/node-backup`, then re-run the installer to apply changes to the
systemd units. The installer never overwrites your config file:

```bash
sudo ./install.sh
```

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
