#!/usr/bin/env bash
# mariadb-dump-all.sh — dump all MariaDB/MySQL databases before backup
#
# Discovers and dumps:
#   - A local (bare metal) MariaDB/MySQL instance
#   - MariaDB/MySQL servers in running Docker containers
#
# Usage: set as PRE_BACKUP_COMMAND in /etc/default/node-backup:
#   PRE_BACKUP_COMMAND='/usr/local/lib/node-backup/mariadb-dump-all.sh'
#
# To run both PostgreSQL and MariaDB dumps (both run even if the first fails):
#   PRE_BACKUP_COMMAND='/usr/local/lib/node-backup/pg-dump-all.sh; r=$?; /usr/local/lib/node-backup/mariadb-dump-all.sh && exit $r'
#
# Dumps are written to MARIADB_DUMP_DIR as <source>.sql.gz, one file per instance.
# Files are replaced atomically and only after a successful dump: if a dump
# fails, the previous good dump stays in place and the script exits non-zero.
set -uo pipefail

# shellcheck disable=SC1091
source /usr/local/lib/node-backup/lib.sh
load_env

DUMP_DIR="${MARIADB_DUMP_DIR:-/var/backups/mariadb}"
MARIADB_DUMP_LOCAL="${MARIADB_DUMP_LOCAL:-auto}"
MARIADB_DUMP_DOCKER="${MARIADB_DUMP_DOCKER:-auto}"

mkdir -p "$DUMP_DIR"
chmod 700 "$DUMP_DIR"
errors=0

# mysqldump flags used for all dumps:
#   --single-transaction  consistent InnoDB snapshot without table locks
#   --quick               stream rows instead of buffering in memory
#   --routines            include stored procedures and functions
#   --events              include scheduled events
DUMP_OPTS=(--all-databases --single-transaction --quick --routines --events)

# Runs INSIDE a container. Picks mariadb-* tools (MariaDB 11+ images no longer
# ship the mysql* names) or falls back to mysql* tools, and reads the root
# password from the container's own environment (incl. *_FILE secrets).
# The password is passed via MYSQL_PWD, so it never appears in a process list.
# Usage: sh -c "$IN_CONTAINER" sh <admin|dump> [args...]
# shellcheck disable=SC2016
IN_CONTAINER='
kind="$1"; shift
if [ "$kind" = admin ]; then
  bin=$(command -v mariadb-admin || command -v mysqladmin)
else
  bin=$(command -v mariadb-dump || command -v mysqldump)
fi
[ -n "$bin" ] || { echo "no $kind tool found in container" >&2; exit 127; }
pw="${MARIADB_ROOT_PASSWORD:-${MYSQL_ROOT_PASSWORD:-}}"
[ -z "$pw" ] && [ -n "${MARIADB_ROOT_PASSWORD_FILE:-}" ] && pw=$(cat "$MARIADB_ROOT_PASSWORD_FILE")
[ -z "$pw" ] && [ -n "${MYSQL_ROOT_PASSWORD_FILE:-}" ]   && pw=$(cat "$MYSQL_ROOT_PASSWORD_FILE")
[ -n "$pw" ] && export MYSQL_PWD="$pw"
exec "$bin" --user=root "$@"
'

# write_dump <label> <outfile> <command...>
write_dump() {
  local label="$1" out="$2"; shift 2
  if run_logged "$label" "$@" | gzip > "${out}.tmp" && mv "${out}.tmp" "$out"; then
    log "mariadb-dump: $label OK ($(du -sh "$out" | cut -f1))"
    return 0
  fi
  rm -f "${out}.tmp"
  log "mariadb-dump: ERROR: $label dump failed — previous dump (if any) kept"
  return 1
}

# =============================================================================
# Local (bare metal) MariaDB / MySQL
# =============================================================================

dump_local() {
  local dump_bin admin_bin
  dump_bin="$(command -v mariadb-dump || command -v mysqldump || true)"
  admin_bin="$(command -v mariadb-admin || command -v mysqladmin || true)"

  if [[ -z "$dump_bin" || -z "$admin_bin" ]]; then
    if [[ "$MARIADB_DUMP_LOCAL" == "1" ]]; then
      log "mariadb-dump: ERROR: mariadb-dump/mysqldump not found — install mariadb-client"
      return 1
    fi
    log "mariadb-dump: no MariaDB/MySQL client tools found, skipping local"
    return 0
  fi

  # Running as root uses the unix_socket auth plugin (default on
  # Debian/Ubuntu) — no password needed.
  if ! "$admin_bin" --user=root ping &>/dev/null; then
    if [[ "$MARIADB_DUMP_LOCAL" == "1" ]]; then
      log "mariadb-dump: ERROR: local MariaDB/MySQL not reachable"
      return 1
    fi
    log "mariadb-dump: no local MariaDB/MySQL found, skipping"
    return 0
  fi

  log "mariadb-dump: dumping local MariaDB/MySQL"
  write_dump "local" "$DUMP_DIR/local.sql.gz" "$dump_bin" --user=root "${DUMP_OPTS[@]}"
}

# =============================================================================
# Docker containers running MariaDB / MySQL
# =============================================================================

dump_docker_container() {
  local cid="$1"
  local name image env_block

  name="$(docker inspect --format '{{.Name}}' "$cid" | tr -d '/')"
  image="$(docker inspect --format '{{.Config.Image}}' "$cid")"
  env_block="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$cid" 2>/dev/null)"

  # Image name match = this is meant to be a database server.
  # Env-var-only match = could be an application that CONNECTS to MySQL.
  local image_match=0 env_match=0
  echo "$image"     | grep -qiE '(mariadb|mysql)'                                     && image_match=1
  echo "$env_block" | grep -qE  '^(MYSQL|MARIADB)_(ROOT_PASSWORD|ROOT_PASSWORD_FILE|DATABASE)=' && env_match=1
  [[ $image_match -eq 0 && $env_match -eq 0 ]] && return 0

  if ! docker exec "$cid" sh -c '(command -v mariadb-dump || command -v mysqldump) && (command -v mariadb-admin || command -v mysqladmin)' &>/dev/null; then
    [[ $image_match -eq 1 ]] && log "mariadb-dump: $name ($image) has no MariaDB/MySQL tools — skipping"
    return 0
  fi

  # Is there actually a server running inside this container?
  if ! docker exec "$cid" sh -c "$IN_CONTAINER" sh admin ping &>/dev/null; then
    if [[ $image_match -eq 1 ]]; then
      log "mariadb-dump: ERROR: $name ($image) looks like a MariaDB/MySQL server but ping failed (down or wrong root password?)"
      return 1
    fi
    return 0
  fi

  log "mariadb-dump: dumping container $name (image: $image)"
  write_dump "$name" "$DUMP_DIR/docker_${name}.sql.gz" \
    docker exec "$cid" sh -c "$IN_CONTAINER" sh dump "${DUMP_OPTS[@]}"
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

  local container_errors=0 cids
  if ! cids="$(docker ps -q 2>&1)"; then
    log "mariadb-dump: ERROR: docker ps failed: $cids"
    return 1
  fi
  while IFS= read -r cid; do
    [[ -z "$cid" ]] && continue
    dump_docker_container "$cid" || container_errors=$((container_errors + 1))
  done <<< "$cids"

  return $container_errors
}

# =============================================================================
# Run
# =============================================================================

[[ "$MARIADB_DUMP_LOCAL"  != "0" ]] && { dump_local  || errors=$((errors + 1)); }
[[ "$MARIADB_DUMP_DOCKER" != "0" ]] && { dump_docker || errors=$((errors + 1)); }

if [[ $errors -gt 0 ]]; then
  log "mariadb-dump: completed with errors — review logs above"
  exit 1
fi

log "mariadb-dump: all dumps complete"
