#!/usr/bin/env bash
# pg-compare-installs.sh - proves that two ways of building a database give the
# same database: the schema, the metadata and sample rows, and the sequences.
#
#   ./pg-compare-installs.sh <ref>              fresh install of <ref> vs fresh
#                                               install of the working tree
#   ./pg-compare-installs.sh --upgrade <ref>    <ref> migrated forward to the
#                                               working tree vs a fresh install
#                                               of the working tree
#
# <ref> is a git commit, or a directory holding a copy of the repository (for
# instance an uncommitted working tree copied aside before a refactoring).
#
# The first form guards a refactoring of the migrations (renumbering, splitting
# files, moving metadata into .jsonc): the result must not change. The second
# guards the forward-only, additive-only rule once a release exists: every
# .once. file must see the same starting point on an upgrade as on a fresh
# install, and a changed repeatable file must converge to what a fresh install
# builds.
#
# A commit is checked out into a temporary git worktree; either way <ref> is
# installed by ITS OWN CLI, so a ref from before a runner change is installed
# the way it was released. Both databases live on the plain CLI container
# (pg-cli-create.sh).
#
# After the comparison, the working tree's database goes through two more
# checks (RERUN=0 skips them, for a <ref> whose files are not yet repeatable):
#   * a second migrate applies no file;
#   * a forced re-run - the checksum of every repeatable .sql and .jsonc file
#     cleared, then migrate - succeeds, leaves every snapshot unchanged, leaves
#     modules.version unchanged and writes no audit row for entities or fields.
#     This is what proves the repeatable files are idempotent.
#
# Compared:
#   * pg_dump -s, normalized as in pg-ext-lifecycle.sh: columns (type, not
#     null, default, order), constraints, indexes, triggers and whether they
#     are enabled, policies, functions (body, settings, security, owner, ACL),
#     table owners and ACLs, default privileges, comments, event triggers;
#   * every row of every table in public, common and rbac, as JSON, ordered by
#     primary key, without the columns that record when something happened
#     (a CURRENT_TIMESTAMP or now() default, modules.version*, users.last_seen);
#   * pgmq.meta and every sequence's position.
# Ignored: the audit log tables and their sequences (the DDL history of two
# different installs differs by design), _versions (file names), _apikeys
# (random keys), and the db_version row of _settings (an install timestamp).
#
# Environment: APPS (default _core,nwind), CONTAINER (default postgres18-cli),
# KEEP=1 to keep both databases and the snapshot files for triage.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# Under Git Bash, the arguments of docker exec must not be path-converted;
# those of git must.
dk() { MSYS_NO_PATHCONV=1 docker "$@"; }

MODE=fresh
if [ "${1:-}" = "--upgrade" ]; then MODE=upgrade; shift; fi
REF="${1:-}"
[ -n "$REF" ] || { echo "usage: $0 [--upgrade] <git ref>" >&2; exit 2; }
if [ -d "$REF" ]; then
  REF_DIR="$(cd "$REF" && pwd)"
  [ -f "$REF_DIR/deno.json" ] || { echo "not a copy of the repository: $REF" >&2; exit 2; }
else
  REF_DIR=""
  git -C "$REPO_ROOT" rev-parse --verify --quiet "$REF^{commit}" >/dev/null \
    || { echo "neither a commit nor a directory: $REF" >&2; exit 2; }
fi

CONTAINER="${CONTAINER:-postgres18-cli}"
APPS="${APPS:-_core,nwind}"
read_env() { grep -E "^$1=" "$SCRIPT_DIR/.env" 2>/dev/null | tail -1 | cut -d '=' -f2- | tr -d '\r' || true; }
PW="$(read_env POSTGRES_PASSWORD)"
PORT="$(read_env POSTGRES_PORT)"; PORT="${PORT:-5432}"
[ -n "$PW" ] || { echo "No POSTGRES_PASSWORD in pgdocker/.env" >&2; exit 1; }
url() { echo "postgresql://postgres:${PW}@localhost:${PORT}/$1"; }

WORK="$(mktemp -d)"
WORKTREE="$WORK/ref"
DB_A=cmp_a   # fresh install of <ref> (fresh mode) or of the working tree (upgrade mode)
DB_B=cmp_b   # fresh install of the working tree (fresh mode) or <ref> migrated forward

psqlc() { dk exec "$CONTAINER" psql -U postgres -d "$1" -v ON_ERROR_STOP=1 -qtAX -c "$2"; }
newdb() {
  psqlc postgres "DROP DATABASE IF EXISTS $1" >/dev/null 2>&1
  psqlc postgres "CREATE DATABASE $1 TEMPLATE template0 ENCODING 'UTF8'" >/dev/null
}
cleanup() {
  [ -n "$REF_DIR" ] || git -C "$REPO_ROOT" worktree remove --force "$WORKTREE" >/dev/null 2>&1 || true
  if [ "${KEEP:-0}" = "1" ]; then
    echo "KEEP=1: databases $DB_A, $DB_B and snapshots in $WORK are left in place"
  else
    psqlc postgres "DROP DATABASE IF EXISTS $DB_A" >/dev/null 2>&1 || true
    psqlc postgres "DROP DATABASE IF EXISTS $DB_B" >/dev/null 2>&1 || true
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT

migrate_with() { # migrate_with <checkout> <db> [log suffix]
  local log="$WORK/migrate-$2${3:-}.log"
  ( cd "$1" && deno task migrate --apps "$APPS" --database-url "$(url "$2")" ) >"$log" 2>&1 \
    || { echo "migrate from $1 into $2 failed:" >&2; tail -20 "$log" >&2; exit 1; }
}

if [ -n "$REF_DIR" ]; then
  WORKTREE="$REF_DIR"
else
  echo "== Checking out $REF =="
  git -C "$REPO_ROOT" worktree add --detach "$WORKTREE" "$REF" >/dev/null
fi

newdb "$DB_A"
newdb "$DB_B"
if [ "$MODE" = fresh ]; then
  echo "== Installing $REF into $DB_A =="
  migrate_with "$WORKTREE" "$DB_A"
  echo "== Installing the working tree into $DB_B =="
  migrate_with "$REPO_ROOT" "$DB_B"
else
  echo "== Installing the working tree into $DB_A =="
  migrate_with "$REPO_ROOT" "$DB_A"
  echo "== Installing $REF into $DB_B, then migrating it to the working tree =="
  migrate_with "$WORKTREE" "$DB_B"
  migrate_with "$REPO_ROOT" "$DB_B"
fi

# ----------------------------------------------------------------- snapshots
ROWS_SQL="
DO \$\$ BEGIN END \$\$;
SELECT format('SELECT %L || E''\\t'' || (to_jsonb(t) - %L::text[])::text FROM %I.%I t %s ORDER BY %s;',
              n.nspname || '.' || c.relname,
              coalesce((SELECT array_agg(a.attname::text)
                          FROM pg_attribute a
                          LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
                         WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
                           AND (pg_get_expr(d.adbin, d.adrelid) ~* '(current_timestamp|now\(\))'
                                OR (c.relname = 'modules' AND a.attname IN ('version', 'version_date'))
                                OR (c.relname = 'users' AND a.attname = 'last_seen'))), '{}'),
              n.nspname, c.relname,
              CASE WHEN c.relname = '_settings' THEN 'WHERE t.name <> ''db_version''' ELSE '' END,
              coalesce((SELECT string_agg(format('t.%I', a.attname), ', ' ORDER BY k.ord)
                          FROM pg_index i
                          CROSS JOIN LATERAL unnest(i.indkey) WITH ORDINALITY AS k(attnum, ord)
                          JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum
                         WHERE i.indrelid = c.oid AND i.indisprimary), '1'))
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE c.relkind IN ('r', 'p')
   AND n.nspname IN ('public', 'common', 'rbac')
   AND c.relname NOT IN ('_versions', '_apikeys', 'audit_record_logs', 'audit_ddl_logs')
 ORDER BY n.nspname, c.relname"

snapshot() { # snapshot <db> <dir>
  mkdir -p "$2"
  # PostgreSQL 18 wraps dumps in psql meta-commands carrying a random key, so
  # every line starting with a backslash goes, as do comments and blank lines.
  dk exec "$CONTAINER" pg_dump -U postgres -s -d "$1" \
    | grep -v '^[\]' | grep -v '^--' | grep -v '^$' > "$2/schema.sql"
  psqlc "$1" "$ROWS_SQL" > "$2/rows.sql"
  dk exec -i "$CONTAINER" psql -U postgres -d "$1" -v ON_ERROR_STOP=1 -qtAX < "$2/rows.sql" > "$2/rows.txt"
  psqlc "$1" "SELECT queue_name || ' ' || is_partitioned || ' ' || is_unlogged FROM pgmq.meta ORDER BY queue_name" > "$2/pgmq.txt"
  psqlc "$1" "SELECT schemaname || '.' || sequencename || ' ' || coalesce(last_value::text, 'unused')
                FROM pg_sequences
               WHERE sequencename NOT LIKE 'audit\_%'
               ORDER BY 1" > "$2/sequences.txt"
}

echo "== Snapshotting both databases =="
snapshot "$DB_A" "$WORK/a"
snapshot "$DB_B" "$WORK/b"

fail=0
for f in schema.sql rows.txt pgmq.txt sequences.txt; do
  if diff -q "$WORK/a/$f" "$WORK/b/$f" >/dev/null; then
    echo "   same  $f ($(wc -l < "$WORK/a/$f" | tr -d ' ') lines)"
  else
    echo "   DIFF  $f"
    diff -u "$WORK/a/$f" "$WORK/b/$f" | head -"${DIFF_LINES:-80}" || true
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  if [ "$MODE" = fresh ]; then
    echo "The working tree does not install the same database as $REF." >&2
  else
    echo "Migrating $REF forward does not give the database a fresh install gives." >&2
  fi
  exit 1
fi
echo "No difference ($MODE, $REF vs the working tree, apps $APPS)."

[ "${RERUN:-1}" = "1" ] || exit 0
# The working tree's database: DB_B in fresh mode, DB_A in upgrade mode.
if [ "$MODE" = fresh ]; then DB_W="$DB_B"; SNAP_W="$WORK/b"; else DB_W="$DB_A"; SNAP_W="$WORK/a"; fi

echo "== Second migrate: nothing may run =="
# Applying a file rewrites its ledger row (checksum and created_at), so an
# unchanged ledger means no file ran.
LEDGER_SQL="SELECT name || ' ' || coalesce(checksum, '-') || ' ' || created_at FROM _versions ORDER BY name"
psqlc "$DB_W" "$LEDGER_SQL" > "$WORK/ledger-before.txt"
migrate_with "$REPO_ROOT" "$DB_W" -second
psqlc "$DB_W" "$LEDGER_SQL" > "$WORK/ledger-after.txt"
if ! diff -q "$WORK/ledger-before.txt" "$WORK/ledger-after.txt" >/dev/null; then
  echo "   FAIL  the second migrate applied files:" >&2
  diff "$WORK/ledger-before.txt" "$WORK/ledger-after.txt" | grep '^>' | cut -d' ' -f2 >&2 || true
  exit 1
fi
echo "   ok    0 files applied"

echo "== Forced re-run of every repeatable file =="
version_before="$(psqlc "$DB_W" "SELECT string_agg(module_slug || '=' || version, ',' ORDER BY id) FROM modules")"
audit_before="$(psqlc "$DB_W" "SELECT count(*) FROM public.audit_record_logs WHERE table_name IN ('entities', 'fields')")"
cleared="$(psqlc "$DB_W" "WITH u AS (UPDATE _versions SET checksum = NULL
                                   WHERE name !~ '[.]once[.](sql|jsonc)\$' RETURNING 1)
                           SELECT count(*) FROM u")"
echo "   $cleared checksums cleared"
migrate_with "$REPO_ROOT" "$DB_W" -rerun
snapshot "$DB_W" "$WORK/rerun"
rerun_fail=0
for f in schema.sql rows.txt pgmq.txt sequences.txt; do
  if ! diff -q "$SNAP_W/$f" "$WORK/rerun/$f" >/dev/null; then
    echo "   DIFF  $f after the re-run"
    diff -u "$SNAP_W/$f" "$WORK/rerun/$f" | head -"${DIFF_LINES:-80}" || true
    rerun_fail=1
  fi
done
version_after="$(psqlc "$DB_W" "SELECT string_agg(module_slug || '=' || version, ',' ORDER BY id) FROM modules")"
audit_after="$(psqlc "$DB_W" "SELECT count(*) FROM public.audit_record_logs WHERE table_name IN ('entities', 'fields')")"
if [ "$version_before" != "$version_after" ]; then
  echo "   FAIL  modules.version changed: $version_before -> $version_after"; rerun_fail=1
fi
if [ "$audit_before" != "$audit_after" ]; then
  echo "   FAIL  $((audit_after - audit_before)) new audit rows for entities/fields"
  psqlc "$DB_W" "SELECT table_name, op, record_pk FROM public.audit_record_logs
                  WHERE table_name IN ('entities', 'fields') ORDER BY id DESC LIMIT $((audit_after - audit_before))" | head -20
  rerun_fail=1
fi
[ "$rerun_fail" -eq 0 ] || { echo "The forced re-run is not idempotent." >&2; exit 1; }
echo "   ok    re-run changed nothing"
