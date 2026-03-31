#!/usr/bin/env bash
# pg-dump-all.sh — dump all PostgreSQL databases before backup
#
# Discovers and dumps:
#   - A local (bare metal) PostgreSQL instance via pg_dumpall
#   - PostgreSQL in running Docker containers (detected by image name or env vars)
#
# Usage: set as PRE_BACKUP_COMMAND in /etc/default/node-backup:
#   PRE_BACKUP_COMMAND='/usr/local/lib/node-backup/pg-dump-all.sh'
#
# Dumps are written to PG_DUMP_DIR as <source>.sql.gz, one file per instance.
# Existing files are overwritten atomically — restic handles versioning.
# Ensure PG_DUMP_DIR is covered by BACKUP_PATHS (default /var/backups/postgresql
# is already covered if /var/backups is in BACKUP_PATHS).
set -uo pipefail

# shellcheck disable=SC1091
source /usr/local/lib/node-backup/lib.sh
load_env

DUMP_DIR="${PG_DUMP_DIR:-/var/backups/postgresql}"
PG_DUMP_LOCAL="${PG_DUMP_LOCAL:-auto}"
PG_DUMP_DOCKER="${PG_DUMP_DOCKER:-auto}"

mkdir -p "$DUMP_DIR"
errors=0

# =============================================================================
# Local (bare metal) PostgreSQL
# =============================================================================

dump_local() {
  if ! command -v pg_dumpall &>/dev/null; then
    if [[ "$PG_DUMP_LOCAL" == "1" ]]; then
      log "pg-dump: ERROR: pg_dumpall not found — install postgresql-client"
      return 1
    fi
    log "pg-dump: pg_dumpall not found, skipping local"
    return 0
  fi

  if ! pg_isready -q 2>/dev/null; then
    if [[ "$PG_DUMP_LOCAL" == "1" ]]; then
      log "pg-dump: ERROR: local PostgreSQL not ready"
      return 1
    fi
    log "pg-dump: no local PostgreSQL found, skipping"
    return 0
  fi

  local out="$DUMP_DIR/local.sql.gz"
  log "pg-dump: dumping local PostgreSQL -> $out"

  # runuser executes as the postgres OS user, which connects via Unix socket
  # using peer authentication — no password required.
  if runuser -u postgres -- pg_dumpall 2>/dev/null | gzip > "${out}.tmp" \
     && mv "${out}.tmp" "$out"; then
    log "pg-dump: local OK ($(du -sh "$out" | cut -f1))"
  else
    rm -f "${out}.tmp"
    log "pg-dump: ERROR: local dump failed"
    return 1
  fi
}

# =============================================================================
# Docker containers running PostgreSQL
# =============================================================================

dump_docker_container() {
  local cid="$1"
  local name image env_block pg_user

  name="$(docker inspect --format '{{.Name}}' "$cid" | tr -d '/')"
  image="$(docker inspect --format '{{.Config.Image}}' "$cid")"
  env_block="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$cid" 2>/dev/null)"

  # Identify PostgreSQL containers by image name or standard POSTGRES_* env vars
  local is_postgres=0
  echo "$image"     | grep -qiE '(postgres|postgis)' && is_postgres=1
  echo "$env_block" | grep -qE  '^POSTGRES_(USER|DB|PASSWORD)='  && is_postgres=1
  [[ $is_postgres -eq 0 ]] && return 0

  # Verify pg_dumpall is available inside the container before attempting
  if ! docker exec "$cid" sh -c 'command -v pg_dumpall' &>/dev/null; then
    log "pg-dump: WARNING: $name ($image) has no pg_dumpall — skipping"
    return 0
  fi

  # Use POSTGRES_USER from the container env, fall back to 'postgres'
  pg_user="$(echo "$env_block" | grep '^POSTGRES_USER=' | cut -d= -f2- | head -1)"
  pg_user="${pg_user:-postgres}"

  local out="$DUMP_DIR/docker_${name}.sql.gz"
  log "pg-dump: dumping container $name (image: $image, user: $pg_user) -> $out"

  if docker exec "$cid" pg_dumpall -U "$pg_user" 2>/dev/null \
     | gzip > "${out}.tmp" && mv "${out}.tmp" "$out"; then
    log "pg-dump: $name OK ($(du -sh "$out" | cut -f1))"
  else
    rm -f "${out}.tmp"
    log "pg-dump: ERROR: container $name dump failed"
    return 1
  fi
}

dump_docker() {
  if ! command -v docker &>/dev/null; then
    if [[ "$PG_DUMP_DOCKER" == "1" ]]; then
      log "pg-dump: ERROR: docker not found"
      return 1
    fi
    log "pg-dump: docker not found, skipping container dumps"
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

[[ "$PG_DUMP_LOCAL"  != "0" ]] && { dump_local  || errors=$((errors + 1)); }
[[ "$PG_DUMP_DOCKER" != "0" ]] && { dump_docker || errors=$((errors + 1)); }

if [[ $errors -gt 0 ]]; then
  log "pg-dump: completed with $errors error(s) — review logs above"
  exit 1
fi

log "pg-dump: all dumps complete"
