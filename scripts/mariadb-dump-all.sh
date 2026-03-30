#!/usr/bin/env bash
# mariadb-dump-all.sh — dump all MariaDB/MySQL databases before backup
#
# Discovers and dumps:
#   - A local (bare metal) MariaDB/MySQL instance via mysqldump
#   - MariaDB/MySQL in running Docker containers (detected by image name or env vars)
#
# Usage: set as PRE_BACKUP_COMMAND in /etc/default/node-backup:
#   PRE_BACKUP_COMMAND='/usr/local/lib/node-backup/mariadb-dump-all.sh'
#
# To run both PostgreSQL and MariaDB dumps:
#   PRE_BACKUP_COMMAND='/usr/local/lib/node-backup/pg-dump-all.sh && /usr/local/lib/node-backup/mariadb-dump-all.sh'
#
# Dumps are written to MARIADB_DUMP_DIR as <source>.sql.gz, one file per instance.
# Existing files are overwritten atomically — restic handles versioning.
# Ensure MARIADB_DUMP_DIR is covered by BACKUP_PATHS (default /var/backups/mariadb
# is already covered if /var/backups is in BACKUP_PATHS).
set -uo pipefail

# shellcheck disable=SC1091
source /usr/local/lib/node-backup/lib.sh
load_env

DUMP_DIR="${MARIADB_DUMP_DIR:-/var/backups/mariadb}"
MARIADB_DUMP_LOCAL="${MARIADB_DUMP_LOCAL:-auto}"
MARIADB_DUMP_DOCKER="${MARIADB_DUMP_DOCKER:-auto}"

mkdir -p "$DUMP_DIR"
errors=0

# Common mysqldump flags used for all dumps:
#   --single-transaction  consistent InnoDB snapshot without table locks
#   --quick               stream rows instead of buffering in memory
#   --routines            include stored procedures and functions
#   --events              include scheduled events
DUMP_OPTS=(--all-databases --single-transaction --quick --routines --events)

# =============================================================================
# Local (bare metal) MariaDB / MySQL
# =============================================================================

dump_local() {
  if ! command -v mysqldump &>/dev/null; then
    if [[ "$MARIADB_DUMP_LOCAL" == "1" ]]; then
      log "mariadb-dump: ERROR: mysqldump not found — install mariadb-client"
      return 1
    fi
    log "mariadb-dump: mysqldump not found, skipping local"
    return 0
  fi

  # Test connectivity. Running as root uses the unix_socket auth plugin,
  # which is the default on Debian/Ubuntu — no password needed.
  if ! mysqladmin --user=root status &>/dev/null; then
    if [[ "$MARIADB_DUMP_LOCAL" == "1" ]]; then
      log "mariadb-dump: ERROR: local MariaDB/MySQL not reachable"
      return 1
    fi
    log "mariadb-dump: no local MariaDB/MySQL found, skipping"
    return 0
  fi

  local out="$DUMP_DIR/local.sql.gz"
  log "mariadb-dump: dumping local MariaDB/MySQL -> $out"

  # Connect as root via Unix socket (no password, unix_socket auth).
  if mysqldump --user=root "${DUMP_OPTS[@]}" 2>/dev/null | gzip > "${out}.tmp" \
     && mv "${out}.tmp" "$out"; then
    log "mariadb-dump: local OK ($(du -sh "$out" | cut -f1))"
  else
    rm -f "${out}.tmp"
    log "mariadb-dump: ERROR: local dump failed"
    return 1
  fi
}

# =============================================================================
# Docker containers running MariaDB / MySQL
# =============================================================================

dump_docker_container() {
  local cid="$1"
  local name image env_block root_pass

  name="$(docker inspect --format '{{.Name}}' "$cid" | tr -d '/')"
  image="$(docker inspect --format '{{.Config.Image}}' "$cid")"
  env_block="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$cid" 2>/dev/null)"

  # Identify MariaDB/MySQL containers by image name or standard env vars
  local is_mariadb=0
  echo "$image"     | grep -qiE '(mariadb|mysql)'                           && is_mariadb=1
  echo "$env_block" | grep -qE  '^(MYSQL|MARIADB)_(ROOT_PASSWORD|DATABASE)=' && is_mariadb=1
  [[ $is_mariadb -eq 0 ]] && return 0

  # Verify mysqldump is available inside the container
  if ! docker exec "$cid" sh -c 'command -v mysqldump' &>/dev/null; then
    log "mariadb-dump: WARNING: $name ($image) has no mysqldump — skipping"
    return 0
  fi

  # Extract root password from container env (MARIADB_ takes precedence over MYSQL_)
  root_pass="$(echo "$env_block" | grep -E '^(MARIADB|MYSQL)_ROOT_PASSWORD=' \
    | sort -r | head -1 | cut -d= -f2-)"

  local out="$DUMP_DIR/docker_${name}.sql.gz"
  log "mariadb-dump: dumping container $name (image: $image) -> $out"

  if [[ -n "$root_pass" ]]; then
    docker exec "$cid" mysqldump --user=root --password="$root_pass" "${DUMP_OPTS[@]}" 2>/dev/null \
      | gzip > "${out}.tmp"
  else
    # No password set — container likely uses MYSQL_ALLOW_EMPTY_PASSWORD or similar
    docker exec "$cid" mysqldump --user=root "${DUMP_OPTS[@]}" 2>/dev/null \
      | gzip > "${out}.tmp"
  fi

  if mv "${out}.tmp" "$out" 2>/dev/null; then
    log "mariadb-dump: $name OK ($(du -sh "$out" | cut -f1))"
  else
    rm -f "${out}.tmp"
    log "mariadb-dump: ERROR: container $name dump failed"
    return 1
  fi
}

dump_docker() {
  if ! command -v docker &>/dev/null; then
    if [[ "$MARIADB_DUMP_DOCKER" == "1" ]]; then
      log "mariadb-dump: ERROR: docker not found"
      return 1
    fi
    log "mariadb-dump: docker not found, skipping container dumps"
    return 0
  fi

  local container_errors=0
  while IFS= read -r cid; do
    [[ -z "$cid" ]] && continue
    dump_docker_container "$cid" || container_errors=$((container_errors + 1))
  done < <(docker ps -q)

  return $container_errors
}

# =============================================================================
# Run
# =============================================================================

[[ "$MARIADB_DUMP_LOCAL"  != "0" ]] && { dump_local  || errors=$((errors + 1)); }
[[ "$MARIADB_DUMP_DOCKER" != "0" ]] && { dump_docker || errors=$((errors + 1)); }

if [[ $errors -gt 0 ]]; then
  log "mariadb-dump: completed with $errors error(s) — review logs above"
  exit 1
fi

log "mariadb-dump: all dumps complete"
