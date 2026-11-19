#!/usr/bin/env bash
# pg-dump-all.sh — dump all PostgreSQL databases before backup
#
# Discovers and dumps:
#   - A local (bare metal) PostgreSQL instance via pg_dumpall
#   - PostgreSQL servers in running Docker containers
#
# Usage: set as PRE_BACKUP_COMMAND in /etc/default/node-backup:
#   PRE_BACKUP_COMMAND='/usr/local/lib/node-backup/pg-dump-all.sh'
#
# Dumps are written to PG_DUMP_DIR as <source>.sql.gz, one file per instance.
# Files are replaced atomically and only after a successful dump: if a dump
# fails, the previous good dump stays in place and the script exits non-zero.
set -uo pipefail

# shellcheck disable=SC1091
source /usr/local/lib/node-backup/lib.sh
load_env

DUMP_DIR="${PG_DUMP_DIR:-/var/backups/postgresql}"
PG_DUMP_LOCAL="${PG_DUMP_LOCAL:-auto}"
PG_DUMP_DOCKER="${PG_DUMP_DOCKER:-auto}"

mkdir -p "$DUMP_DIR"
chmod 700 "$DUMP_DIR"
errors=0

# write_dump <label> <outfile> <command...>
# Streams the command's stdout through gzip into <outfile>.tmp and only
# renames it into place if the whole pipeline succeeded.
write_dump() {
  local label="$1" out="$2"; shift 2
  if run_logged "$label" "$@" | gzip > "${out}.tmp" && mv "${out}.tmp" "$out"; then
    log "pg-dump: $label OK ($(du -sh "$out" | cut -f1))"
    return 0
  fi
  rm -f "${out}.tmp"
  log "pg-dump: ERROR: $label dump failed — previous dump (if any) kept"
  return 1
}

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

  log "pg-dump: dumping local PostgreSQL"
  # runuser executes as the postgres OS user, which connects via Unix socket
  # using peer authentication — no password required.
  write_dump "local" "$DUMP_DIR/local.sql.gz" runuser -u postgres -- pg_dumpall
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

  # Image name match = this is meant to be a database server.
  # Env-var-only match = could just be an application that CONNECTS to
  # PostgreSQL (apps often carry POSTGRES_USER/POSTGRES_PASSWORD too).
  local image_match=0 env_match=0
  echo "$image"     | grep -qiE '(postgres|postgis)'          && image_match=1
  echo "$env_block" | grep -qE  '^POSTGRES_(USER|DB|PASSWORD)=' && env_match=1
  [[ $image_match -eq 0 && $env_match -eq 0 ]] && return 0

  if ! docker exec "$cid" sh -c 'command -v pg_dumpall && command -v pg_isready' &>/dev/null; then
    [[ $image_match -eq 1 ]] && log "pg-dump: $name ($image) has no PostgreSQL tools — skipping"
    return 0
  fi

  # Is there actually a server running inside this container?
  if ! docker exec "$cid" pg_isready -q &>/dev/null; then
    if [[ $image_match -eq 1 ]]; then
      log "pg-dump: ERROR: $name ($image) looks like a PostgreSQL server but is not accepting connections"
      return 1
    fi
    # Application container with PostgreSQL client tools — not a server.
    return 0
  fi

  pg_user="$(echo "$env_block" | grep '^POSTGRES_USER=' | cut -d= -f2- | head -1)"
  pg_user="${pg_user:-postgres}"

  log "pg-dump: dumping container $name (image: $image, user: $pg_user)"
  write_dump "$name" "$DUMP_DIR/docker_${name}.sql.gz" \
    docker exec "$cid" pg_dumpall -U "$pg_user"
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

  local container_errors=0 cids
  if ! cids="$(docker ps -q 2>&1)"; then
    log "pg-dump: ERROR: docker ps failed: $cids"
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

[[ "$PG_DUMP_LOCAL"  != "0" ]] && { dump_local  || errors=$((errors + 1)); }
[[ "$PG_DUMP_DOCKER" != "0" ]] && { dump_docker || errors=$((errors + 1)); }

if [[ $errors -gt 0 ]]; then
  log "pg-dump: completed with errors — review logs above"
  exit 1
fi

log "pg-dump: all dumps complete"
