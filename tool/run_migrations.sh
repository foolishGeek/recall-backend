#!/usr/bin/env bash
# Applies every migration, in order, to a throwaway local Postgres.
#
# This is the check tool/check_sql.py cannot do: it proves the chain actually
# executes -- functions resolve, constraints hold, seeds insert. No Docker; just
# Homebrew Postgres plus small test doubles for the Supabase-only pieces
# (pg_net, pg_cron, auth, vault) in tool/pgtest/.
#
# Usage: tool/run_migrations.sh [--keep]
#   --keep  leave the cluster running afterwards for querying

set -euo pipefail

PGBIN="${PGBIN:-/opt/homebrew/opt/postgresql@17/bin}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PGTEST="$REPO_ROOT/tool/pgtest"
CLUSTER="${TMPDIR:-/tmp}/recall-pgtest"
PORT="${PGTEST_PORT:-55432}"
DB=recall_test
KEEP=0
[[ "${1:-}" == "--keep" ]] && KEEP=1

export PGHOST="$CLUSTER/sock" PGPORT="$PORT"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

cleanup() {
  if [[ $KEEP -eq 1 ]]; then
    log "cluster left running on port $PORT (psql -h $PGHOST -p $PORT $DB)"
    return
  fi
  "$PGBIN/pg_ctl" -D "$CLUSTER/data" -m immediate stop >/dev/null 2>&1 || true
  rm -rf "$CLUSTER"
}
trap cleanup EXIT

# --- fresh cluster ---------------------------------------------------------
log "creating throwaway cluster at $CLUSTER"
"$PGBIN/pg_ctl" -D "$CLUSTER/data" -m immediate stop >/dev/null 2>&1 || true
rm -rf "$CLUSTER"
mkdir -p "$CLUSTER/data" "$CLUSTER/sock"
"$PGBIN/initdb" -D "$CLUSTER/data" --locale=C --encoding=UTF8 >/dev/null

# Install the Supabase test doubles alongside the real extensions.
EXTDIR="$("$PGBIN/pg_config" --sharedir)/extension"
for f in pg_net.control pg_net--0.1.sql pg_cron.control pg_cron--0.1.sql; do
  cp "$PGTEST/$f" "$EXTDIR/$f"
done

log "starting postgres on port $PORT"
"$PGBIN/pg_ctl" -D "$CLUSTER/data" \
  -o "-p $PORT -k $CLUSTER/sock -c listen_addresses=''" \
  -w -l "$CLUSTER/server.log" start >/dev/null

"$PGBIN/createdb" "$DB"

# client_min_messages=warning: "does not exist, skipping" NOTICEs from the
# idempotent DROP IF EXISTS guards would otherwise bury the real errors.
psql() {
  "$PGBIN/psql" -v ON_ERROR_STOP=1 -q --no-psqlrc -d "$DB" \
    -c "SET client_min_messages TO warning;" "$@"
}

# --- bootstrap ------------------------------------------------------------
log "installing Supabase bootstrap (roles, auth, vault, extensions)"
psql -v dbname="$DB" -f "$PGTEST/00_bootstrap.sql"
# Reconnect so the new search_path takes effect for the migrations.
psql -c "CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;" \
     -c "CREATE EXTENSION IF NOT EXISTS pg_cron;"

# --- migrations -----------------------------------------------------------
log "applying migrations"
failed=0
applied=0
for f in "$REPO_ROOT"/supabase/migrations/*.sql; do
  name="$(basename "$f")"
  if out=$(psql -f "$f" 2>&1); then
    applied=$((applied + 1))
    printf '  \033[32mok\033[0m   %s\n' "$name"
  else
    failed=$((failed + 1))
    printf '  \033[31mFAIL\033[0m %s\n' "$name"
    printf '%s\n' "$out" | sed 's/^/       /'
    break   # later migrations assume this one applied
  fi
done

echo
if [[ $failed -gt 0 ]]; then
  log "applied $applied, then FAILED on $name"
  exit 1
fi
log "all $applied migrations applied cleanly"

# --- behaviour tests ------------------------------------------------------
# Always on a freshly migrated database, so no test can see another's rows.
shopt -s nullglob
export PGBIN PGTEST_DB="$DB"
for t in "$PGTEST"/[1-9]*.sql "$PGTEST"/[1-9]*.sh; do
  echo
  log "running $(basename "$t")"
  case "$t" in
    *.sh)
      bash "$t" || { log "FAILED $(basename "$t")"; exit 1; } ;;
    *)
      "$PGBIN/psql" -v ON_ERROR_STOP=1 -q --no-psqlrc -d "$DB" -f "$t" 2>&1 \
        | sed -E 's/^psql:[^ ]+ (NOTICE|INFO):[[:space:]]*//' \
        || { log "FAILED $(basename "$t")"; exit 1; } ;;
  esac
done

echo
log "migrations applied and all behaviour tests passed"
