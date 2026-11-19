# node-backup

A lightweight, easy-to-roll-out backup system for Linux servers using **restic** and **rclone**.

## Features

- Backs up chosen directories via `restic` to any `rclone`-supported backend
- restic and rclone installed from their official releases (SHA256-verified), pinnable per fleet
- Automatic `restic init` on first run — only when the repository genuinely does not exist
- Configurable retention policy (daily / weekly / monthly)
- Optional **pre-backup** and **post-backup** hooks — run any command or script
- Auto-discovery dump scripts for **PostgreSQL** and **MariaDB/MySQL** (bare metal + Docker)
- Three systemd timers with fully configurable schedules: backup, health check, weekly prune + integrity check
- Hard memory caps and runtime limits on all restic jobs — protects host RAM, prevents hung runs
- Webhook alerts (Bearer token auth) for failures, runs that never finished, and stale backups
- `node-backup-restic` helper for snapshots, restore and ad-hoc restic commands
- All configuration in a single env file with descriptions for every variable

---

## Quick rollout (per node)

```bash
# 1. Clone or copy the repo
git clone <your-repo-url> /opt/node-backup
cd /opt/node-backup

# 2. Run the installer (installs restic + rclone from official releases, scripts, systemd units)
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
   sudo node-backup-restic snapshots
   ```

4. **Store `RESTIC_PASSWORD` and `rclone.conf` outside the node** — see
   [Disaster recovery](#disaster-recovery). This is the step most often forgotten.

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
| `BACKUP_TIMEOUT` / `PRUNE_TIMEOUT` | Max runtime before systemd stops a hung job (`12h` / `24h`) |
| `CHECK_READ_DATA_SUBSET` | Share of repository data re-downloaded and verified weekly (`5%`) |
| `STATUS_MAX_AGE_HOURS` | Alert if the last successful backup is older than this (`26`) |
| `PRUNE_STATUS_MAX_AGE_HOURS` | Same for prune/check (`192` = 8 days) |
| `RESTIC_VERSION` | restic release to install (`latest` or e.g. `0.18.0`) |
| `RCLONE_VERSION` | rclone release to install (`latest` or e.g. `1.76.0`) |
| `RESTIC_RETRY_LOCK` | How long to wait for a repository lock held by another job (`1h`) |
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
| `node-backup-notify.timer` | Daily at 09:00 | Health check; fires webhook on any problem (see below) |
| `node-backup-prune.timer` | Sunday at 04:30 | Runs `restic prune`, then `restic check` with partial data verification |

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

A job killed by the memory cap is reported by the daily health check as "started but
never finished". Raise the limit in `/etc/default/node-backup` and re-run `install.sh`
to apply it.

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

`forget` groups snapshots by host and tags (`--group-by host,tags`), not by path. With
restic's default grouping, changing `BACKUP_PATHS` would start a new group and the old
snapshots would silently never be expired.

The weekly prune uses `--retry-lock`, so if Sunday's backup is still running when
prune starts, prune waits for it instead of failing.

To run prune manually at any time:

```bash
sudo systemctl start node-backup-prune.service
sudo journalctl -u node-backup-prune.service -f
```

---

## Pre- and post-backup hooks

Set `PRE_BACKUP_COMMAND` and/or `POST_BACKUP_COMMAND` in `/etc/default/node-backup`.
Both are executed with `bash -lc "<command>"`.

- If `PRE_BACKUP_COMMAND` exits non-zero, the **file backup still runs** — one broken
  database must not leave everything else on the node unprotected — but the run is
  marked FAIL and alerted. A failed dump never overwrites the previous good dump file.
- `POST_BACKUP_COMMAND` runs only when **everything** succeeded (dumps, backup, forget).
  That makes it the right place to ping an external dead man's switch: a missing ping
  then also covers database dump failures and a node that is down entirely.

Examples:

```bash
# Auto-dump all PostgreSQL databases (bare metal + Docker) — see section below
PRE_BACKUP_COMMAND='/usr/local/lib/node-backup/pg-dump-all.sh'

# Both PostgreSQL and MariaDB — the second runs even if the first fails,
# and the combined result is a failure if either one failed
PRE_BACKUP_COMMAND='/usr/local/lib/node-backup/pg-dump-all.sh; r=$?; /usr/local/lib/node-backup/mariadb-dump-all.sh && exit $r'

# Ping an external dead man's switch after a fully successful run
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

A candidate container is only dumped if `pg_isready` succeeds **inside** it. Application
containers that merely connect to PostgreSQL (and so carry `POSTGRES_*` variables and
often the client tools) are skipped. A container whose *image* is postgres but whose
server does not answer is reported as an error.

Dumps are streamed out of the container to the host — nothing is written inside the
container. If a dump fails, its stderr is written to the journal and the previous dump
file is left untouched.

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
sudo node-backup-restic restore latest --target /restore --include /var/backups/postgresql
gunzip -c /restore/var/backups/postgresql/docker_myapp.sql.gz | docker exec -i myapp psql -U postgres
```

---

## MariaDB / MySQL dumps

`mariadb-dump-all.sh` works the same way for MariaDB and MySQL.

**What it finds:**
- A local bare metal MariaDB/MySQL install — detected via `mariadb-admin ping` (or
  `mysqladmin`), connected as root via Unix socket (`unix_socket` auth, no password on
  default Debian/Ubuntu)
- Any running Docker container whose image name contains `mariadb` or `mysql`, or that
  has `MYSQL_ROOT_PASSWORD` / `MARIADB_ROOT_PASSWORD` (or the `*_FILE` Docker-secret
  variants) / `MYSQL_DATABASE` env vars

As with PostgreSQL, a container is only dumped if a server answers inside it. The root
password is read *inside* the container from its own environment and passed via
`MYSQL_PWD`, so it never appears in the host's process list. Both the newer
`mariadb-dump`/`mariadb-admin` names (MariaDB 11+ images ship only these) and the
classic `mysqldump`/`mysqladmin` names are supported.

Dumps use `--single-transaction` for consistent InnoDB snapshots without table locks.

**Enable** in `/etc/default/node-backup`:

```bash
# MariaDB only
PRE_BACKUP_COMMAND='/usr/local/lib/node-backup/mariadb-dump-all.sh'

# Both PostgreSQL and MariaDB
PRE_BACKUP_COMMAND='/usr/local/lib/node-backup/pg-dump-all.sh; r=$?; /usr/local/lib/node-backup/mariadb-dump-all.sh && exit $r'
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
gunzip -c /var/backups/mariadb/local.sql.gz | mariadb --user=root
gunzip -c /var/backups/mariadb/docker_myapp.sql.gz | docker exec -i myapp sh -c 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD"' 
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

The `node-backup-notify.timer` runs once per day (default 09:00) and reads the status
files written by the backup and prune jobs. It sends a webhook if **any** of these is true:

| Problem | How it is detected |
|---|---|
| Backup, dump, forget, prune or check failed | Status file says `FAIL` (with the reason) |
| A job started but never finished | Status says `RUNNING` but the systemd unit is no longer active — killed by the memory cap, stopped by the timeout, or interrupted by a reboot |
| A job is hanging | Status says `RUNNING` and the unit is active, but for longer than the max age |
| Backups silently stopped | Last success older than `STATUS_MAX_AGE_HOURS` (26h) — timer disabled, node was off |
| Prune/check silently stopped | Last success older than `PRUNE_STATUS_MAX_AGE_HOURS` (8 days) |
| Backup has never run | No status file at all |

Status is written pessimistically: a job sets `RUNNING` when it starts and only writes
`OK` when everything succeeded. A job that is killed can therefore never leave an old
`OK` behind.

Example payload:

```json
{
  "service": "node-backup",
  "node": "web01",
  "host": "web01.example.com",
  "status": "FAIL",
  "timestamp": "2026-03-24T09:00:02+00:00",
  "message": "node-backup problems on web01.example.com: backup failed at 2026-03-24T03:41:12+00:00: pre-backup command failed (rc=1)"
}
```

The request includes `Authorization: Bearer <WEBHOOK_BEARER_TOKEN>`.

Set `NOTIFY_SCHEDULE` to a time comfortably after your latest expected backup
completion (`BACKUP_SCHEDULE` + `BACKUP_SCHEDULE_JITTER` + estimated runtime).

---

## Integrity checks

After every weekly prune, `restic check --read-data-subset=5%` runs. It verifies the
repository structure and additionally downloads and verifies a random 5% of the stored
data. Because the subset is random each week, the whole repository is read back over
time, so corruption on the storage backend is found while there is still time to act —
not on the day you need a restore. A failed check is alerted like any other failure.

Adjust the share with `CHECK_READ_DATA_SUBSET` (more = more download traffic per week;
empty = structural check only). For a full verification run manually:

```bash
sudo node-backup-restic check --read-data
```

---

## Disaster recovery

The backups are encrypted with `RESTIC_PASSWORD`, and reaching them needs the
credentials in `rclone.conf`. **Both live on the node.** If the node is lost and these
were not stored elsewhere, the backups cannot be restored.

For every node, store in a password manager (or another place that is not the node):

- `RESTIC_PASSWORD`
- `RESTIC_REPOSITORY`
- the relevant section of `rclone.conf` (or how to recreate the remote)

Then **test a restore** — once when a node is set up, and periodically afterwards.
A backup that has never been restored from is an assumption, not a backup.

```bash
sudo node-backup-restic restore latest --target /restore/test --include /etc
ls -la /restore/test/etc
```

To restore onto a new machine: install node-backup, put the stored values into
`/etc/default/node-backup` and `rclone.conf`, then use `node-backup-restic`.

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

## Updating a node / changing install-time settings

```bash
cd /opt/node-backup && git pull
sudo ./install.sh
```

Re-running the installer always updates the scripts, the systemd units and (with
`RESTIC_VERSION` / `RCLONE_VERSION` set to `latest`) restic and rclone themselves. Schedules, memory limits and timeouts are
written into the systemd units at this point, so re-run it after changing those.

It **never overwrites** `/etc/default/node-backup` or `/etc/node-backup-excludes.txt`.
Variables added in newer versions fall back to safe defaults if missing; to set them,
compare your files with the repository versions:

```bash
sudo diff /etc/default/node-backup /opt/node-backup/env.example
sudo diff /etc/node-backup-excludes.txt /opt/node-backup/excludes.txt
```

---

## Restore

`node-backup-restic` runs any restic command against this node's repository, using the
settings from `/etc/default/node-backup`:

```bash
sudo node-backup-restic snapshots                       # list snapshots
sudo node-backup-restic ls latest /etc/nginx            # browse a snapshot
sudo node-backup-restic restore latest --target /restore/test
sudo node-backup-restic restore latest --target /restore --include /var/backups/postgresql
sudo node-backup-restic restore <snapshot-id> --target /restore/old
```

---

## Requirements

- Linux with systemd
- Debian/Ubuntu (`install.sh` uses `apt-get` for `curl`, `bzip2`, `unzip`)
- Network access during install to `github.com` (restic) and `downloads.rclone.org`
  (rclone). Both binaries are installed to `/usr/local/bin` and verified against the
  release's `SHA256SUMS`. Distro packages are not used because they are often years
  behind: features such as `--retry-lock` and exit code 10 for "repository does not
  exist" need a recent restic, and cloud backends like Jottacloud get regular fixes in
  rclone. If a distro package is also installed, `/usr/local/bin` takes precedence and
  the installer tells you how to remove it.
- A configured rclone remote for your chosen storage backend
- `curl` (for webhook notifications)
