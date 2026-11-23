#!/usr/bin/env bash
# pg-compare-installs.sh - proves that two ways of building a database give the
# same database: the schema, the metadata and sample rows, and the sequences.
#
#   ./pg-compare-installs.sh <ref>              fresh install of <ref> vs fresh
#                                               install of the working tree
#   ./pg-compare-installs.sh --upgrade <ref>    <ref> migrated forward to the
#                                               working tree vs a fresh install
#                                               of the working tree
#   ./pg-compare-installs.sh --upgrade-ext <ref>
#                                               the same through the extension:
#                                               <ref>'s extension, updated to
#                                               the working tree's, vs a fresh
#                                               extension install of the
#                                               working tree
#
# <ref> is a git commit, or a directory holding a copy of the repository (for
# instance an uncommitted working tree copied aside before a refactoring).
#
# The first form guards a refactoring of the migrations (renumbering, splitting
# files, moving metadata into .jsonc): the result must not change. The second
# and third guard the forward-only, additive-only rule once a release exists:
# every .once. file must see the same starting point on an update as on a fresh
# install, and a changed repeatable file must converge to what a fresh install
# builds. release.sh runs both as its update test.
#
# A commit is checked out into a temporary git worktree; either way <ref> is
# installed by ITS OWN CLI, so a ref from before a runner change is installed
# the way it was released. Both databases live on the plain CLI container
# (pg-cli-create.sh), or with --upgrade-ext on the extension container
# (pg-ext-create.sh).
#
# --upgrade-ext installs <ref>'s extension build (CREATE EXTENSION, migrate())
# and nwind with <ref>'s CLI, then updates it the way a deployment does: with
# ALTER EXTENSION pg_semantius UPDATE and migrate() when the working tree's
# default_version differs from <ref>'s, and otherwise, for a re-release, which
# no update path leads to, with DROP and CREATE EXTENSION and migrate(). nwind
# follows with the working tree's CLI. The working tree's database is a fresh
# extension install plus nwind through the CLI. The container's extension
# directory holds <ref>'s build only while <ref> is installed; a trap puts the
# working tree's back on every way out.
#
# REF_PRERELEASE=1 says <ref> is a pre-release, whose run-once files may still
# change in place: a database it built may then be refused with "replace the
# database with a fresh install". Such a refusal passes when the database is
# unchanged by it (ledger and schema); the comparison is then skipped, and the
# re-run checks below still run on the working tree's database.
#
# After the comparison, the working tree's database goes through two more
# checks (RERUN=0 skips them, for a <ref> whose files are not yet repeatable):
#   * a second migrate applies no file;
#   * a forced re-run - the checksum of every repeatable .sql and .jsonc file
#     cleared (with --upgrade-ext, of _core's, and migrate() re-runs them),
#     then migrate - succeeds, leaves every snapshot unchanged, leaves
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
# (random keys), and two rows of _settings: db_version (an install timestamp)
# and row_move_secret (random per install).
#
# Environment: APPS (default _core,nwind), CONTAINER (default postgres18-cli,
# postgres18-ext with --upgrade-ext), KEEP=1 to keep both databases and the
# snapshot files for triage, REF_PRERELEASE=1 when <ref> is a pre-release
# (above; release.sh sets it from the tag name).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# Under Git Bash, the arguments of docker exec must not be path-converted;
# those of git must.
dk() { MSYS_NO_PATHCONV=1 docker "$@"; }

MODE=fresh
case "${1:-}" in
  --upgrade)     MODE=upgrade; shift ;;
  --upgrade-ext) MODE=upgrade-ext; shift ;;
esac
REF="${1:-}"
[ -n "$REF" ] || { echo "usage: $0 [--upgrade | --upgrade-ext] <git ref>" >&2; exit 2; }
PRERELEASE="${REF_PRERELEASE:-0}"
if [ -d "$REF" ]; then
  REF_DIR="$(cd "$REF" && pwd)"
  [ -f "$REF_DIR/deno.json" ] || { echo "not a copy of the repository: $REF" >&2; exit 2; }
else
  REF_DIR=""
  git -C "$REPO_ROOT" rev-parse --verify --quiet "$REF^{commit}" >/dev/null \
    || { echo "neither a commit nor a directory: $REF" >&2; exit 2; }
fi

APPS="${APPS:-_core,nwind}"
read_env() { grep -E "^$1=" "$SCRIPT_DIR/.env" 2>/dev/null | tail -1 | cut -d '=' -f2- | tr -d '\r' || true; }
PW="$(read_env POSTGRES_PASSWORD)"
if [ "$MODE" = upgrade-ext ]; then
  CONTAINER="${CONTAINER:-postgres18-ext}"
  PORT="$(read_env POSTGRES_EXT_PORT)"; PORT="${PORT:-5433}"
else
  CONTAINER="${CONTAINER:-postgres18-cli}"
  PORT="$(read_env POSTGRES_PORT)"; PORT="${PORT:-5432}"
fi
[ -n "$PW" ] || { echo "No POSTGRES_PASSWORD in pgdocker/.env" >&2; exit 1; }
url() { echo "postgresql://postgres:${PW}@localhost:${PORT}/$1"; }

WORK="$(mktemp -d)"
WORKTREE="$WORK/ref"
DB_A=cmp_a   # fresh install of <ref> (fresh mode) or of the working tree (upgrade modes)
DB_B=cmp_b   # fresh install of the working tree (fresh mode) or <ref> updated

psqlc() { dk exec "$CONTAINER" psql -U postgres -d "$1" -v ON_ERROR_STOP=1 -qtAX -c "$2"; }
newdb() {
  psqlc postgres "DROP DATABASE IF EXISTS $1" >/dev/null 2>&1
  psqlc postgres "CREATE DATABASE $1 TEMPLATE template0 ENCODING 'UTF8'" >/dev/null
}

# The extension container installs whatever lies in its extension directory
# (the image has no PGXS), so --upgrade-ext stages <ref>'s build there for its
# install and the working tree's for the update. Every later run of a harness
# on this container expects the working tree's build, so the trap puts it back
# on every way out, also after a failure while <ref>'s build is staged.
EXT_DIR="/usr/share/postgresql/18/extension"
REF_STAGED=0
stage_ext() { # stage_ext <extension dir>: its control file and scripts, into the container
  local f
  for f in "$1"/pg_semantius.control "$1"/pg_semantius--*.sql; do
    [ -f "$f" ] || continue
    dk cp "$(cygpath -w "$f" 2>/dev/null || echo "$f")" "$CONTAINER:/tmp/$(basename "$f")" >/dev/null
    dk exec -u root "$CONTAINER" sh -c "cp '/tmp/$(basename "$f")' '$EXT_DIR/' && rm -f '/tmp/$(basename "$f")'"
  done
}
restore_ext() { # the working tree's build, without the scripts only <ref> has
  local f
  for f in "$WORKTREE"/extension/pg_semantius--*.sql; do
    if [ -f "$f" ] && [ ! -f "$REPO_ROOT/extension/$(basename "$f")" ]; then
      dk exec -u root "$CONTAINER" rm -f "$EXT_DIR/$(basename "$f")"
    fi
  done
  stage_ext "$REPO_ROOT/extension"
  REF_STAGED=0
}

cleanup() {
  if [ "$REF_STAGED" = 1 ]; then
    restore_ext || echo "Could not put the working tree's extension build back into $CONTAINER; recreate it with pg-ext-create.sh." >&2
  fi
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

migrate_cmd() { # migrate_cmd <checkout> <db>
  ( cd "$1" && deno task migrate --apps "$APPS" --database-url "$(url "$2")" )
}
migrate_with() { # migrate_with <checkout> <db> [log suffix]
  local log="$WORK/migrate-$2${3:-}.log"
  migrate_cmd "$1" "$2" >"$log" 2>&1 \
    || { echo "migrate from $1 into $2 failed:" >&2; tail -20 "$log" >&2; exit 1; }
}
ext_migrate() { # ext_migrate <db> <log suffix>: CALL semantius.migrate()
  local log="$WORK/ext-migrate-$1$2.log"
  psqlc "$1" "CALL semantius.migrate()" >"$log" 2>&1 \
    || { echo "CALL semantius.migrate() in $1 failed:" >&2; tail -20 "$log" >&2; exit 1; }
}
ext_install() { # ext_install <db>: a fresh extension install
  psqlc "$1" "CREATE EXTENSION pg_semantius" >/dev/null
  ext_migrate "$1" -install
}

# A pre-release's run-once files may still change in place, so a database a
# pre-release built may be one the working tree cannot update: the runner then
# refuses it with "replace the database with a fresh install" instead of
# building a schema a fresh install never has. Such a refusal passes the update
# test only when it is clean: the runner said "replace", and the database is
# exactly as it was before the call, ledger and schema. A refusal after a
# partial change fails like any other failed update. A final release gets no
# such allowance: every database it built must update.
REPLACE_ADVICE="replace the database with a fresh install"
LEDGER_SQL="SELECT name || ' ' || coalesce(checksum, '-') || ' ' || created_at FROM _versions ORDER BY name"
ledger_and_schema() { # ledger_and_schema <db> <file>
  { psqlc "$1" "$LEDGER_SQL"
    dk exec "$CONTAINER" pg_dump -U postgres -s -d "$1" | grep -v '^[\]' | grep -v '^--' | grep -v '^$'
  } > "$2"
}
REFUSED=0
update_with() { # update_with <db> <log> <command...>: the update of <ref>'s database
  local db="$1" log="$2"; shift 2
  [ "$PRERELEASE" = 1 ] && ledger_and_schema "$db" "$WORK/before-update.txt"
  if "$@" >"$log" 2>&1; then return 0; fi
  if [ "$PRERELEASE" != 1 ]; then
    echo "the update of $db failed:" >&2; tail -20 "$log" >&2; exit 1
  fi
  clean_refusal "$db" "$log" "$WORK/before-update.txt" || exit 1
  REFUSED=1
}
clean_refusal() { # clean_refusal <db> <log> <snapshot taken before the call>
  if ! grep -qF "$REPLACE_ADVICE" "$2"; then
    echo "   FAIL  the update of $1 failed, and not with \"$REPLACE_ADVICE\":" >&2
    tail -20 "$2" >&2
    return 1
  fi
  ledger_and_schema "$1" "$WORK/after-refusal.txt"
  if ! diff -q "$3" "$WORK/after-refusal.txt" >/dev/null; then
    echo "   FAIL  the update of $1 was refused with \"$REPLACE_ADVICE\", but it changed the database:" >&2
    diff -u "$3" "$WORK/after-refusal.txt" | head -"${DIFF_LINES:-80}" >&2 || true
    return 1
  fi
  echo "   ok    refused with \"$REPLACE_ADVICE\"; the ledger and the schema are unchanged"
  grep -m1 -F "$REPLACE_ADVICE" "$2" | sed -e 's/\x1b\[[0-9;]*m//g' -e 's/^/          /'
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
elif [ "$MODE" = upgrade ]; then
  echo "== Installing the working tree into $DB_A =="
  migrate_with "$REPO_ROOT" "$DB_A"
  echo "== Installing $REF into $DB_B, then migrating it to the working tree =="
  migrate_with "$WORKTREE" "$DB_B"
  update_with "$DB_B" "$WORK/migrate-$DB_B-update.log" migrate_cmd "$REPO_ROOT" "$DB_B"
else
  ext_version() { sed -nE "s/^default_version = '(.*)'/\1/p" "$1/pg_semantius.control" 2>/dev/null | tr -d '\r'; }
  REF_VERSION="$(ext_version "$WORKTREE/extension")"
  WT_VERSION="$(ext_version "$REPO_ROOT/extension")"
  [ -n "$REF_VERSION" ] && [ -f "$WORKTREE/extension/pg_semantius--$REF_VERSION.sql" ] \
    || { echo "$REF has no extension build in extension/" >&2; exit 1; }
  [ -n "$WT_VERSION" ] && [ -f "$REPO_ROOT/extension/pg_semantius--$WT_VERSION.sql" ] \
    || { echo "the working tree has no extension build in extension/" >&2; exit 1; }

  echo "== Installing $REF ($REF_VERSION) as the extension into $DB_B, nwind with its CLI =="
  REF_STAGED=1
  stage_ext "$WORKTREE/extension"
  ext_install "$DB_B"
  migrate_with "$WORKTREE" "$DB_B" -ref
  restore_ext

  echo "== Installing the working tree ($WT_VERSION) as the extension into $DB_A, nwind with its CLI =="
  ext_install "$DB_A"
  migrate_with "$REPO_ROOT" "$DB_A"

  if [ "$REF_VERSION" = "$WT_VERSION" ]; then
    # No upgrade script leads from a version to itself, so a re-release reaches
    # a database through a new extension object: DROP EXTENSION leaves every
    # core object in place, and migrate() then applies what differs.
    echo "== Updating $DB_B: re-release of $WT_VERSION, DROP and CREATE EXTENSION, then migrate() =="
    psqlc "$DB_B" "DROP EXTENSION pg_semantius" >/dev/null
    psqlc "$DB_B" "CREATE EXTENSION pg_semantius" >/dev/null
  else
    echo "== Updating $DB_B: ALTER EXTENSION pg_semantius UPDATE ($REF_VERSION -> $WT_VERSION), then migrate() =="
    psqlc "$DB_B" "ALTER EXTENSION pg_semantius UPDATE" >/dev/null
    got="$(psqlc "$DB_B" "SELECT extversion FROM pg_extension WHERE extname = 'pg_semantius'")"
    [ "$got" = "$WT_VERSION" ] \
      || { echo "ALTER EXTENSION UPDATE left $DB_B at $got, not $WT_VERSION" >&2; exit 1; }
    echo "   ok    extversion is $got"
  fi
  update_with "$DB_B" "$WORK/ext-migrate-$DB_B-update.log" psqlc "$DB_B" "CALL semantius.migrate()"
  # nwind follows with the working tree's CLI, as after a real update. Its
  # _core rows are now the extension's, so the CLI applies none of them.
  [ "$REFUSED" = 1 ] || migrate_with "$REPO_ROOT" "$DB_B" -update
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
              CASE WHEN c.relname = '_settings' THEN 'WHERE t.name NOT IN (''db_version'', ''row_move_secret'')' ELSE '' END,
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

if [ "$REFUSED" = 1 ]; then
  # A refused database has nothing to compare; the working tree's own database
  # still goes through the re-run checks below.
  echo "== Snapshotting $DB_A ($REF's database was refused cleanly, so there is no comparison) =="
  snapshot "$DB_A" "$WORK/a"
else
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
      echo "Updating $REF does not give the database a fresh install gives." >&2
    fi
    exit 1
  fi
  echo "No difference ($MODE, $REF vs the working tree, apps $APPS)."
fi

[ "${RERUN:-1}" = "1" ] || exit 0
# The working tree's database: DB_B in fresh mode, DB_A in the upgrade modes.
if [ "$MODE" = fresh ]; then DB_W="$DB_B"; SNAP_W="$WORK/b"; else DB_W="$DB_A"; SNAP_W="$WORK/a"; fi
# The extension's database is re-run through migrate(), which runs _core only,
# so only _core's checksums are cleared there.
rerun_migrate() { # rerun_migrate <log suffix>
  if [ "$MODE" = upgrade-ext ]; then ext_migrate "$DB_W" "$1"; else migrate_with "$REPO_ROOT" "$DB_W" "$1"; fi
}
RERUN_ROWS="name !~ '[.]once[.](sql|jsonc)\$'"
[ "$MODE" = upgrade-ext ] && RERUN_ROWS="$RERUN_ROWS AND pg_catalog.starts_with(name, '_core.')"

echo "== Second migrate: nothing may run =="
# Applying a file rewrites its ledger row (checksum and created_at), so an
# unchanged ledger means no file ran.
psqlc "$DB_W" "$LEDGER_SQL" > "$WORK/ledger-before.txt"
rerun_migrate -second
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
                                   WHERE $RERUN_ROWS RETURNING 1)
                           SELECT count(*) FROM u")"
echo "   $cleared checksums cleared"
rerun_migrate -rerun
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
