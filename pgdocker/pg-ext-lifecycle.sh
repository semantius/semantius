#!/usr/bin/env bash
# pg-ext-lifecycle.sh - proves the pg_semantius extension LIFECYCLE end to end:
# install, backup, single-pass restore, drop, uninstall, and the refusals.
#
# The pgTAP suite (pg-ext-retest.sh) proves that the extension-installed core
# behaves like the migrate-installed one. This script proves the properties the
# suite cannot see from inside one database:
#
#   0.  preflight: control file, generated script, generator unit tests
#   1.  fresh install, two statements, no CASCADE
#   1b. a second database on the same cluster (roles already exist)
#   1c. concurrency: a second migrator fails at once while one holds the lock
#   1d. transaction shape: CALL inside a transaction block is refused
#   1g. a failing file: earlier files stay, the 9900 files still run and hand
#       everything to semantius_owner, the next CALL resumes
#   1h. the same on the CLI runner (deno task migrate), plus its lock refusal
#   1e. first-user bootstrap: two concurrent logins elect exactly one admin
#   1f. fix_id_sequence gives up on a busy table with 90232
#   2.  plain pg_dump -> SINGLE-PASS pg_restore, with custom data (B16)
#   2b. restore variants: -Fp | psql, -j 4, -1
#   4.  DROP EXTENSION is inert (no data loss), with and without CASCADE
#   4b. the documented uninstall recipe leaves no leftovers
#   6.  schema pinning: non-public search_path installs, SCHEMA other refuses
#   6b. hostile session settings produce an identical install
#   7.  refusals: a real pgmq, pgcrypto in the wrong schema, nested extension
#   7d. 0310_pgmq.once.sql's own pgmq header guard on the CLI path
#   8.  privileges: non-superuser cannot migrate(); functions are locked down
#   8b. role squatting is refused
#   8d. the BYPASSRLS gate of 0100_rbac_rls.sql refuses an installer without the attribute
#   9.  LATIN1 and SQL_ASCII databases are refused
#   10. equivalence: the CLI-installed and extension-installed schemas match
#   11. event-trigger noise: the DDL audit and NOTIFY pgrst are scoped
#   12. cleanup
#
# Non-interactive, every exit code checked. Needs the ext stack running
# (pg-ext-create.sh) and the generated extension in ../extension.
#
#   ./pg-ext-lifecycle.sh              # run everything
#   ./pg-ext-lifecycle.sh --keep       # keep the scratch databases for triage
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$SCRIPT_DIR"

CONTAINER="${CONTAINER:-postgres18-ext}"
EXT_DIR="/usr/share/postgresql/18/extension"
KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

# docker cp needs a Windows-style source path under Git Bash, and docker exec
# arguments must not be path-converted. Both are handled here.
export MSYS_NO_PATHCONV=1

pass_n=0
fail_n=0
step() { printf '\n== %s ==\n' "$*"; }
ok()   { pass_n=$((pass_n + 1)); printf '   ok   %s\n' "$*"; }
bad()  { fail_n=$((fail_n + 1)); printf '   FAIL %s\n' "$*" >&2; }
check() { # check <description> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi
}

# psqlq is for VALUES and for the refusal tests: it prints stdout+stderr and
# swallows the status, because there a non-zero exit IS the expected result and
# the error text is what gets asserted. Without the `|| true`, `set -e` would
# abort the script on every refusal.
psqlq()  { docker exec "$CONTAINER" psql -U postgres -d "$1" -tAc "$2" 2>&1 || true; }

# psqlrun is for STATEMENTS whose success is the assertion. It must NOT swallow
# the status: `psqlrun ... && ok ... || bad ...` would otherwise always take the
# `ok` branch and the check could never fail. Used bare for preconditions, where
# `set -e` aborting loudly is the right outcome.
psqlrun() { docker exec "$CONTAINER" psql -U postgres -d "$1" -v ON_ERROR_STOP=1 -qc "$2" 2>&1; }

# psqlseq runs each argument as its OWN statement in one session, the way
# psqlq swallows the status. `psql -c "a; b"` sends both in one query message,
# which PostgreSQL runs as one implicit transaction - and CALL semantius.migrate()
# cannot commit inside a transaction. Used where a CALL must follow a SET ROLE.
psqlseq() { local db="$1"; shift; local args=(); for c in "$@"; do args+=(-c "$c"); done
            docker exec "$CONTAINER" psql -U postgres -d "$db" -tA "${args[@]}" 2>&1 || true; }
newdb()  { docker exec "$CONTAINER" psql -U postgres -d postgres -qc \
             "DROP DATABASE IF EXISTS $1" >/dev/null 2>&1
           docker exec "$CONTAINER" psql -U postgres -d postgres -qc \
             "CREATE DATABASE $1 TEMPLATE template0 ENCODING 'UTF8'" >/dev/null; }
dropdb_() { docker exec "$CONTAINER" psql -U postgres -d postgres -qc \
             "DROP DATABASE IF EXISTS $1" >/dev/null 2>&1 || true; }

# A comparable fingerprint of one database's core schema and data.
SIGNATURE_SQL="
SELECT (SELECT coalesce(sum(cnt), 0) FROM (
          SELECT (xpath('/row/c/text()', query_to_xml(
                    format('SELECT count(*) AS c FROM %I.%I', n.nspname, c.relname),
                    false, true, '')))[1]::text::bigint AS cnt
            FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
           WHERE c.relkind = 'r'
             AND n.nspname IN ('public','common','rbac','audit','pgmq')) s)
       || '/' || (SELECT count(*) FROM pg_policies)
       || '/' || (SELECT count(*) FROM pg_trigger WHERE NOT tgisinternal)
       || '/' || (SELECT count(*) FROM pg_event_trigger)
       || '/' || (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                   WHERE n.nspname IN ('public','common','rbac','audit','pgmq'))"

# The same without the audit log tables, for installs whose DDL history
# legitimately differs (an interrupted pass runs the 9900 files twice).
SIGNATURE_NOAUDIT_SQL="
SELECT (SELECT coalesce(sum(cnt), 0) FROM (
          SELECT (xpath('/row/c/text()', query_to_xml(
                    format('SELECT count(*) AS c FROM %I.%I', n.nspname, c.relname),
                    false, true, '')))[1]::text::bigint AS cnt
            FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
           WHERE c.relkind = 'r'
             AND c.relname NOT IN ('audit_record_logs', 'audit_ddl_logs')
             AND n.nspname IN ('public','common','rbac','audit','pgmq')) s)
       || '/' || (SELECT count(*) FROM pg_policies)
       || '/' || (SELECT count(*) FROM pg_trigger WHERE NOT tgisinternal)
       || '/' || (SELECT count(*) FROM pg_event_trigger)
       || '/' || (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                   WHERE n.nspname IN ('public','common','rbac','audit','pgmq'))"

# ---------------------------------------------------------------- 0 preflight
step "[0] Preflight: control file and generated script"
CONTROL="$REPO_ROOT/extension/pg_semantius.control"
[ -f "$CONTROL" ] || { echo "No extension build in ../extension. Run: deno task extension <version>" >&2; exit 1; }
# Everything below installs this build, so it must match the migrations.
EXT_VERSION="$(sed -nE "s/^default_version = '(.*)'/\1/p" "$CONTROL")"
( cd "$REPO_ROOT" && deno task extension "$EXT_VERSION" --check ) \
  || { echo "Refusing to test a stale extension build." >&2; exit 1; }
SQLFILE="$(ls "$REPO_ROOT"/extension/pg_semantius--*.sql | head -1)"

grep -q "^schema = public$"       "$CONTROL" && ok "control: schema = public"        || bad "control: schema = public missing"
grep -q "^relocatable = false$"   "$CONTROL" && ok "control: relocatable = false"    || bad "control: relocatable = false missing"
grep -q "^superuser = true$"      "$CONTROL" && ok "control: superuser = true"       || bad "control: superuser = true missing"
grep -q "^encoding = 'UTF8'$"     "$CONTROL" && ok "control: encoding = 'UTF8'"      || bad "control: encoding missing"
grep -q "^requires"               "$CONTROL" && bad "control: requires must be absent (CASCADE would misplace pgcrypto)" || ok "control: no requires"
# Exactly one config_dump CALL: migrate()'s own in-extension-script probe.
# Match the call, not the word, so the comment explaining it does not count.
n_cfg=$(grep -c "PERFORM pg_catalog.pg_extension_config_dump" "$SQLFILE" || true)
check "script: exactly one config_dump call (migrate()'s guard)" "1" "$n_cfg"
n_reg=$(grep -c "^SELECT pg_catalog.pg_extension_config_dump\|^SELECT pg_extension_config_dump" "$SQLFILE" || true)
check "script: no table is registered for pg_dump" "0" "$n_reg"
grep -q "skip_audit" "$SQLFILE" && bad "script: skip_audit must be gone" || ok "script: no skip_audit"

# B13 lives in the generator, not in the shipped bytes. On a fresh checkout
# .gitattributes makes the whole tree LF, and toLf() could then be deleted with
# every generated file still coming out CR-free - and that LF checkout is what
# CI, and therefore the release guard, builds from. Only a check that hands the
# normalizer CRLF itself fails on its removal, so that is a Deno unit test, run
# here on the host where this script already runs.
lftest=$(cd "$REPO_ROOT" && deno test --allow-read packages/cli/commands/extension_test.ts 2>&1) \
  && ok "LF normalization and the manifest checksum are unit-pinned (B13)" \
  || bad "deno test extension_test.ts failed: $(printf '%s' "$lftest" | tail -3 | tr '\n' ' ')"
# Pins, not the assertion above: on an LF checkout they stay green with toLf()
# removed. They fail if a CR reaches the shipped files by some other route.
# Counted with `tr`, not `grep $'\r'`: MSYS drops the carriage return on its way
# to grep.exe, leaving an empty pattern that matches every line.
check "pin: no CR byte in the generated script" "0" "$(tr -cd '\r' < "$SQLFILE" | wc -c | tr -d ' ')"
check "pin: no CR byte in the control file"     "0" "$(tr -cd '\r' < "$CONTROL"  | wc -c | tr -d ' ')"

# Stage the files into the container (the image has no PGXS).
docker cp "$(cygpath -w "$SQLFILE" 2>/dev/null || echo "$SQLFILE")" "$CONTAINER:/tmp/ext.sql" >/dev/null
docker cp "$(cygpath -w "$CONTROL" 2>/dev/null || echo "$CONTROL")" "$CONTAINER:/tmp/ext.control" >/dev/null
docker exec -u root "$CONTAINER" cp /tmp/ext.sql "$EXT_DIR/$(basename "$SQLFILE")"
docker exec -u root "$CONTAINER" cp /tmp/ext.control "$EXT_DIR/pg_semantius.control"
ok "extension files staged into the container"

# ------------------------------------------------------------ 1 fresh install
step "[1] Fresh install: CREATE EXTENSION (no CASCADE) then CALL migrate()"
newdb life1
out=$(psqlrun life1 "CREATE EXTENSION pg_semantius") && ok "CREATE EXTENSION succeeds without CASCADE" \
  || bad "CREATE EXTENSION failed: $out"

n_pending_before=$(psqlq life1 "SELECT count(*) FROM semantius.pending()")
[ "$n_pending_before" -gt 0 ] 2>/dev/null && ok "pending() works before _versions exists ($n_pending_before)" \
  || bad "pending() before migrate: $n_pending_before"
v=$(psqlq life1 "SELECT semantius.version()")
check "version() equals the control file" "$(grep '^default_version' "$CONTROL" | cut -d"'" -f2)" "$v"

out=$(psqlq life1 "CALL semantius.migrate()")
echo "$out" | grep -q '"applied"' && ok "migrate(): $(echo "$out" | grep '"applied"')" || bad "migrate() failed: $out"

check "pending() is empty after migrate()" "0" "$(psqlq life1 'SELECT count(*) FROM semantius.pending()')"
out=$(psqlq life1 "CALL semantius.migrate()")
echo "$out" | grep -q '"applied": 0' && ok "a second migrate() runs nothing" \
  || bad "a second migrate() ran something: $out"
check "  and status() reports nothing pending or changed" "0|{}" \
  "$(psqlq life1 "SELECT pending || '|' || changed_versions::text FROM semantius.status()")"

# Forced re-run: with every repeatable file's checksum cleared, migrate() runs
# them all again. That is what an upgrade does to each changed file, so it must
# succeed and change nothing - no object, no dictionary row, no module version.
life1_schema() { docker exec "$CONTAINER" pg_dump -U postgres -s -d life1 2>/dev/null \
                   | grep -v '^[\]' | grep -v '^--' | grep -v '^$' | md5sum; }
LIFE1_META_SQL="SELECT md5(string_agg(t, '|' ORDER BY t)) FROM (
                  SELECT (to_jsonb(e) - 'created_at' - 'updated_at')::text AS t FROM entities e
                  UNION ALL SELECT (to_jsonb(f) - 'created_at' - 'updated_at')::text FROM fields f
                  UNION ALL SELECT module_slug || '=' || version FROM modules) s"
schema_before=$(life1_schema)
meta_before=$(psqlq life1 "$LIFE1_META_SQL")
n_cleared=$(psqlq life1 "WITH u AS (UPDATE _versions SET checksum = NULL
                                     WHERE name !~ '[.]once[.](sql|jsonc)\$' RETURNING 1)
                         SELECT count(*) FROM u")
out=$(psqlq life1 "CALL semantius.migrate()")
echo "$out" | grep -q "\"applied\": $n_cleared," && ok "a forced re-run applies the $n_cleared repeatable files again" \
  || bad "forced re-run of $n_cleared files: $out"
check "  and leaves the schema unchanged" "$schema_before" "$(life1_schema)"
check "  and leaves entities, fields and module versions unchanged" "$meta_before" "$(psqlq life1 "$LIFE1_META_SQL")"
check "pgcrypto is in public" "public" "$(psqlq life1 "SELECT extnamespace::regnamespace::text FROM pg_extension WHERE extname='pgcrypto'")"
check "extconfig is NULL (no dump registry)" "t" "$(psqlq life1 "SELECT extconfig IS NULL FROM pg_extension WHERE extname='pg_semantius'")"
check "members: no relations" "0" "$(psqlq life1 "SELECT count(*) FROM pg_depend d JOIN pg_extension e ON e.oid=d.refobjid WHERE d.refclassid='pg_extension'::regclass AND d.deptype='e' AND e.extname='pg_semantius' AND d.classid='pg_class'::regclass")"
check "core relations are non-members" "0" "$(psqlq life1 "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace JOIN pg_depend d ON d.objid=c.oid AND d.deptype='e' AND d.refclassid='pg_extension'::regclass WHERE n.nspname IN ('public','common','rbac','audit','pgmq')")"
check "audit_ddl_logs attribute migrate() as the query" "1" \
  "$(psqlq life1 "SELECT count(DISTINCT query_text) FROM audit_ddl_logs WHERE query_text ~ 'semantius\.migrate'")"

SIG1=$(psqlq life1 "$SIGNATURE_SQL")
ok "signature (rows/policies/triggers/evt/functions) = $SIG1"
SIG1_NOAUDIT=$(psqlq life1 "$SIGNATURE_NOAUDIT_SQL")

# ------------------------------------------------------------ 1b second database
step "[1b] Second database on the same cluster (roles already exist)"
newdb life1b
psqlrun life1b "CREATE EXTENSION pg_semantius" >/dev/null && psqlq life1b "CALL semantius.migrate()" >/dev/null \
  && ok "install succeeds when the roles already exist" || bad "second-database install failed"
check "no postgres -> semantius_user membership (B11)" "0" \
  "$(psqlq life1b "SELECT count(*) FROM pg_auth_members m JOIN pg_roles g ON g.oid=m.roleid JOIN pg_roles n ON n.oid=m.member WHERE g.rolname='semantius_user' AND n.rolname='postgres'")"
# `common` must look exactly like `rbac`, which never carried 0040_cache.sql's
# `GRANT USAGE ... TO CURRENT_USER`. Testing for a `postgres=` entry directly
# would be wrong: 9900's GRANT to semantius_owner materializes the owner's own
# entry in every one of these schemas, artifact or not.
check "schema common has no extra installer grant (B11)" \
  "$(psqlq life1b "SELECT array_to_string(nspacl,',') FROM pg_namespace WHERE nspname='rbac'")" \
  "$(psqlq life1b "SELECT array_to_string(nspacl,',') FROM pg_namespace WHERE nspname='common'")"

# ------------------------------------------------------------ 1c concurrency
step "[1c] Concurrency: a second migrator fails at once while one holds the lock"
# Every runner takes the SESSION lock pg_try_advisory_lock(hashtext('migrate'))
# and fails rather than queueing: a queued run would start on a first pass that
# is half done. A session lock is what survives the procedure's per-file COMMITs.
newdb life1c
psqlrun life1c "CREATE EXTENSION pg_semantius" >/dev/null
# CLI vs procedure: the CLI runner holds exactly this lock for its whole run.
docker exec -d "$CONTAINER" psql -U postgres -d life1c \
  -c "SELECT pg_advisory_lock(hashtext('migrate'))" -c "SELECT pg_sleep(4)" >/dev/null
lock_held() { [ "$(psqlq life1c "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND granted AND objid = (hashtext('migrate')::bigint & 4294967295)")" = "1" ]; }
for _ in $(seq 50); do lock_held && break; sleep 0.1; done
b_out=$(psqlq life1c "CALL semantius.migrate()")
echo "$b_out" | grep -q "another migration is running" \
  && ok "the procedure fails at once while the CLI holds the lock" || bad "procedure vs CLI: $b_out"
check "  and it wrote nothing" "" "$(psqlq life1c "SELECT to_regclass('public._versions')")"
for _ in $(seq 60); do lock_held || break; sleep 0.1; done
# Procedure vs procedure (and vs CLI). A table lock stalls the first CALL inside
# its pass - the ledger DDL needs ACCESS EXCLUSIVE on _versions - while it holds
# the migration lock; the second CALL and a CLI-style lock attempt must fail.
psqlrun life1c "CALL semantius.migrate()" >/dev/null
docker exec -d "$CONTAINER" psql -U postgres -d life1c \
  -c "BEGIN; LOCK TABLE public._versions IN ACCESS EXCLUSIVE MODE; SELECT pg_sleep(4); COMMIT;" >/dev/null
sleep 1
docker exec -d "$CONTAINER" psql -U postgres -d life1c -c "CALL semantius.migrate()" >/dev/null
for _ in $(seq 50); do lock_held && break; sleep 0.1; done
b_out=$(psqlq life1c "CALL semantius.migrate()")
echo "$b_out" | grep -q "another migration is running" \
  && ok "a second CALL fails at once while the first holds the lock" || bad "procedure vs procedure: $b_out"
check "  and a CLI runner is refused the lock too" "f" \
  "$(psqlq life1c "SELECT pg_try_advisory_lock(hashtext('migrate'))")"
for _ in $(seq 80); do lock_held || break; sleep 0.1; done
check "the lock is released when the first CALL ends" "t" \
  "$(psqlseq life1c "SELECT pg_try_advisory_lock(hashtext('migrate'))" "SELECT pg_advisory_unlock(hashtext('migrate'))" | head -1)"
check "each migration applied exactly once" "0" \
  "$(psqlq life1c "SELECT count(*) FROM (SELECT name FROM public._versions GROUP BY name HAVING count(*)>1) d")"

# ------------------------------------------------------- 1d transaction shape
step "[1d] Transaction shape"
# migrate() commits after every file, which a procedure can only do when CALL is
# not inside a transaction block. PostgreSQL refuses it (2D000) at the
# procedure's first COMMIT, which comes before the lock and before any write.
newdb life1d
err=$(docker exec "$CONTAINER" psql -U postgres -d life1d -v ON_ERROR_STOP=1 -q -1 \
  -c "CREATE EXTENSION pg_semantius" -c "CALL semantius.migrate()" 2>&1 || true)
echo "$err" | grep -q "invalid transaction termination" \
  && ok "psql -1 (both statements in one transaction) is refused with 2D000" || bad "psql -1: $err"
newdb life1d2
psqlrun life1d2 "CREATE EXTENSION pg_semantius" >/dev/null
err=$(docker exec "$CONTAINER" psql -U postgres -d life1d2 -q \
  -c "BEGIN; CALL semantius.migrate(); ROLLBACK;" 2>&1 || true)
echo "$err" | grep -q "invalid transaction termination" \
  && ok "CALL inside BEGIN is refused with 2D000" || bad "CALL inside BEGIN: $err"
check "  and leaves no _versions" "" "$(psqlq life1d2 "SELECT to_regclass('public._versions')")"
check "  and no schema common" "0" \
  "$(psqlq life1d2 "SELECT count(*) FROM pg_namespace WHERE nspname='common'")"
check "  and no migration lock behind" "t" \
  "$(psqlseq life1d2 "SELECT pg_try_advisory_lock(hashtext('migrate'))" "SELECT pg_advisory_unlock(hashtext('migrate'))" | head -1)"
check "the roles still exist" "4" \
  "$(psqlq life1d2 "SELECT count(*) FROM pg_roles WHERE rolname IN ('authenticated','semantius_user','semantius_authenticator','semantius_owner')")"

# ------------------------------------------------ 1g a failing file mid-pass
step "[1g] A failing file: earlier files stay, the 9900 files run, the next CALL resumes"
# A table squatting on a name a mid-pass file creates with a plain CREATE TABLE
# (public._apikeys). It is owned by a separate role so that "nothing is owned
# by the installer" below is not confused by the squatter itself.
newdb life1g
psqlrun life1g "CREATE EXTENSION pg_semantius" >/dev/null
psqlq postgres "CREATE ROLE lifecycle_squatter NOLOGIN" >/dev/null 2>&1 || true
psqlrun life1g "CREATE TABLE public._apikeys (squat int); ALTER TABLE public._apikeys OWNER TO lifecycle_squatter" >/dev/null
err=$(psqlq life1g "CALL semantius.migrate()")
echo "$err" | grep -qE 'migration _core\.[0-9]{4}_apikeys(\.once)?\.sql failed' \
  && ok "the error names the failing file" || bad "failing file: $err"
echo "$err" | grep -q 'already exists' \
  && ok "  and carries the original error" || bad "original error: $err"
check "files before it stayed committed" "t" \
  "$(psqlq life1g "SELECT to_regclass('public.users') IS NOT NULL AND EXISTS (SELECT 1 FROM public._versions WHERE name LIKE '_core.%')")"
check "the failing file is not recorded" "0" \
  "$(psqlq life1g "SELECT count(*) FROM public._versions WHERE name ~ '^_core\.[0-9]{4}_apikeys'")"
check "the 9900 files ran after the failure" "1" \
  "$(psqlq life1g "SELECT count(*) FROM public._versions WHERE name = '_core.9900_owner_hardening.sql'")"
NOT_EXT_MEMBER="NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = x.oid AND d.deptype = 'e' AND d.refclassid = 'pg_extension'::regclass)"
check "no core relation is left owned by the installing superuser" "0" \
  "$(psqlq life1g "SELECT count(*) FROM pg_class x JOIN pg_namespace n ON n.oid = x.relnamespace WHERE n.nspname IN ('public','common','rbac','audit','pgmq') AND x.relkind IN ('r','p','S','v','m') AND x.relowner = 'postgres'::regrole AND $NOT_EXT_MEMBER")"
check "no core function is left owned by the installing superuser" "0" \
  "$(psqlq life1g "SELECT count(*) FROM pg_proc x JOIN pg_namespace n ON n.oid = x.pronamespace WHERE n.nspname IN ('public','common','rbac','audit','pgmq') AND x.proowner = 'postgres'::regrole AND $NOT_EXT_MEMBER")"
[ "$(psqlq life1g "SELECT count(*) FROM semantius.pending()")" -gt 0 ] 2>/dev/null \
  && ok "pending() lists the files that did not run" || bad "pending() after a failure is empty"
psqlrun life1g "DROP TABLE public._apikeys" >/dev/null
out=$(psqlq life1g "CALL semantius.migrate()")
echo "$out" | grep -q '"applied"' && ok "the next CALL resumes and completes" || bad "resume: $out"
check "  pending() is empty" "0" "$(psqlq life1g "SELECT count(*) FROM semantius.pending()")"
check "  the resumed files are owned by semantius_owner" "semantius_owner" \
  "$(psqlq life1g "SELECT relowner::regrole FROM pg_class WHERE oid = 'public._apikeys'::regclass")"
check "  the result equals an uninterrupted install" "$SIG1_NOAUDIT" "$(psqlq life1g "$SIGNATURE_NOAUDIT_SQL")"
if [ "$KEEP" != "1" ]; then
  dropdb_ life1g
  psqlq postgres "DROP ROLE IF EXISTS lifecycle_squatter" >/dev/null 2>&1 || true
fi

# ------------------------------------------------- 1h the same on the CLI
step "[1h] The CLI runner: a failing file, the 9900 files, the lock"
# The CLI connects over TCP from the host, like pg-ext-retest.sh.
read_env() { grep -E "^$1=" "$SCRIPT_DIR/.env" 2>/dev/null | tail -1 | cut -d '=' -f2- | tr -d '\r' || true; }
CLI_PORT="$(read_env POSTGRES_EXT_PORT)"
CLI_URL="postgresql://postgres:$(read_env POSTGRES_PASSWORD)@localhost:${CLI_PORT:-5433}/life1h"
newdb life1h
psqlq postgres "CREATE ROLE lifecycle_squatter NOLOGIN" >/dev/null 2>&1 || true
psqlrun life1h "CREATE TABLE public._apikeys (squat int); ALTER TABLE public._apikeys OWNER TO lifecycle_squatter" >/dev/null
out=$(cd "$REPO_ROOT" && deno task migrate --apps _core --database-url "$CLI_URL" 2>&1) \
  && bad "the CLI run succeeded over a squatted table" \
  || ok "the CLI run fails on the squatted file"
echo "$out" | grep -qE '[0-9]{4}_apikeys(\.once)?\.sql: relation "_apikeys" already exists' \
  && ok "  the reported error is the original one" || bad "CLI error: $(echo "$out" | tail -3 | tr '\n' ' ')"
check "  the 9900 files ran after the failure" "1" \
  "$(psqlq life1h "SELECT count(*) FROM public._versions WHERE name = '_core.9900_owner_hardening.sql'")"
check "  no core relation is left owned by the installing superuser" "0" \
  "$(psqlq life1h "SELECT count(*) FROM pg_class x JOIN pg_namespace n ON n.oid = x.relnamespace WHERE n.nspname IN ('public','common','rbac','audit','pgmq') AND x.relkind IN ('r','p','S','v','m') AND x.relowner = 'postgres'::regrole AND $NOT_EXT_MEMBER")"
check "  no core function is left owned by the installing superuser" "0" \
  "$(psqlq life1h "SELECT count(*) FROM pg_proc x JOIN pg_namespace n ON n.oid = x.pronamespace WHERE n.nspname IN ('public','common','rbac','audit','pgmq') AND x.proowner = 'postgres'::regrole AND $NOT_EXT_MEMBER")"
psqlrun life1h "DROP TABLE public._apikeys" >/dev/null
# While another session holds the migration lock, the CLI fails at once.
docker exec -d "$CONTAINER" psql -U postgres -d life1h \
  -c "SELECT pg_advisory_lock(hashtext('migrate'))" -c "SELECT pg_sleep(4)" >/dev/null
for _ in $(seq 50); do [ "$(psqlq life1h "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND granted")" = "1" ] && break; sleep 0.1; done
out=$(cd "$REPO_ROOT" && deno task migrate --apps _core --database-url "$CLI_URL" 2>&1) || true
echo "$out" | grep -q "another migration is running" \
  && ok "the CLI fails at once while another session holds the lock" || bad "CLI lock: $(echo "$out" | tail -2 | tr '\n' ' ')"
for _ in $(seq 60); do [ "$(psqlq life1h "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND granted")" = "0" ] && break; sleep 0.1; done
out=$(cd "$REPO_ROOT" && deno task migrate --apps _core --database-url "$CLI_URL" 2>&1) \
  && ok "the next CLI run resumes and completes" || bad "CLI resume: $(echo "$out" | tail -3 | tr '\n' ' ')"
check "  and it equals an uninterrupted install" "$SIG1_NOAUDIT" "$(psqlq life1h "$SIGNATURE_NOAUDIT_SQL")"
if [ "$KEEP" != "1" ]; then
  dropdb_ life1h
  psqlq postgres "DROP ROLE IF EXISTS lifecycle_squatter" >/dev/null 2>&1 || true
fi

# ------------------------------------------- 1e first-user bootstrap race
step "[1e] First-user bootstrap: two concurrent logins elect exactly one admin"
# The pgTAP suite cannot prove this. It runs in one session inside one
# transaction, and there is no dblink in this tree, so the only place two
# sessions can meet is here.
#
# The trigger that grants Administrator reads "does any user hold role 2" and
# then writes, which are two statements. Without the advisory lock two first
# logins arriving together both read an empty user_roles and both insert, and a
# fresh install ends up with two administrators - one of them whoever happened
# to log in second. With it, the loser waits for the winner to commit and then,
# under READ COMMITTED, takes a fresh snapshot in which the role is taken.
newdb life1e
psqlrun life1e "CREATE EXTENSION pg_semantius" >/dev/null
psqlq life1e "CALL semantius.migrate()" >/dev/null
check "a fresh install has no administrator" "0" \
  "$(psqlq life1e "SELECT count(*) FROM public.user_roles WHERE role_id = 2")"

# Session A provisions inside an open transaction and holds it for 5 seconds, so
# it still owns the lock when B arrives. get_userinfo() is the supported entry
# point and the one an application actually calls on first login.
race_login() { # race_login <sub> <email> <trailing sql>
  printf "BEGIN; SET ROLE semantius_user;
          SELECT set_config('request.jwt.claim.role', 'authenticated', true);
          SELECT set_config('request.jwt.claim.sub', '%s', true);
          SELECT set_config('request.jwt.claim.email', '%s', true);
          SELECT public.get_userinfo(); %s COMMIT;" "$1" "$2" "$3"
}
docker exec -d "$CONTAINER" psql -U postgres -d life1e \
  -c "$(race_login race_a a@example.test 'SELECT pg_sleep(5);')" >/dev/null
sleep 2
b_out=$(docker exec "$CONTAINER" psql -U postgres -d life1e -tAc \
  "$(race_login race_b b@example.test '')" 2>&1)
echo "$b_out" | grep -q "ERROR" && bad "second login failed: $b_out" \
  || ok "the second login completed after the first committed"

check "both principals exist, so the race really ran" "2" \
  "$(psqlq life1e "SELECT count(*) FROM public.users WHERE external_id IN ('race_a','race_b')")"
check "exactly one administrator" "1" \
  "$(psqlq life1e "SELECT count(*) FROM public.user_roles WHERE role_id = 2")"
check "and it is the login that got there first" "race_a" \
  "$(psqlq life1e "SELECT u.external_id FROM public.users u
                     JOIN public.user_roles ur ON ur.user_id = u.id
                    WHERE ur.role_id = 2")"
check "the loser still holds the User role" "1" \
  "$(psqlq life1e "SELECT count(*) FROM public.user_roles ur
                     JOIN public.users u ON u.id = ur.user_id
                    WHERE u.external_id = 'race_b' AND ur.role_id = 1")"

# A third login long after the fact is not elected either: the gate is the role,
# not the timing.
psqlq life1e "$(race_login race_c c@example.test '')" >/dev/null
check "a later login is not elected" "1" \
  "$(psqlq life1e "SELECT count(*) FROM public.user_roles WHERE role_id = 2")"

# ------------------------------------------ 1f fix_id_sequence lock timeout
step "[1f] fix_id_sequence gives up on a busy table with 90232"
# The pgTAP suite cannot hold a lock against itself, so the timeout is proven
# here: session A keeps an insert open, and session B must give up after the
# function's 2 s lock_timeout with 90232 instead of queueing behind A.
psqlrun life1e "INSERT INTO public.entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
                VALUES ('lock_probe', 'lock_probe', 'Lock Probe', 'Lock Probes', 'fix_id_sequence lock probe', 1, 'public:read', 'admin', 'id', 'label')" >/dev/null
fix_as_admin() { # race_a is the administrator 1e elected
  printf '%s' "BEGIN; SET LOCAL ROLE semantius_user;
               SET LOCAL \"request.jwt.claim.role\" = 'authenticated';
               SET LOCAL \"request.jwt.claim.sub\" = 'race_a';
               SELECT public.fix_id_sequence('lock_probe'); COMMIT;"
}
wait_for() { # wait_for <sql> <value>: poll life1e for up to 10 s
  for _ in $(seq 50); do [ "$(psqlq life1e "$1")" = "$2" ] && return 0; sleep 0.2; done
  return 1
}
LOCK_HELD="SELECT count(*) FROM pg_locks WHERE relation = to_regclass('public.lock_probe') AND mode = 'RowExclusiveLock' AND granted"
docker exec -d "$CONTAINER" psql -U postgres -d life1e -c \
  "BEGIN; INSERT INTO public.lock_probe (label) VALUES ('a'); SELECT pg_sleep(5); COMMIT;" >/dev/null
if wait_for "$LOCK_HELD" 1; then
  # `|| true`: the refusal is the expected result, and set -e would abort on it.
  b_out=$(docker exec "$CONTAINER" psql -U postgres -d life1e -v VERBOSITY=verbose -qtAc "$(fix_as_admin)" 2>&1 || true)
  echo "$b_out" | grep -q "90232" && ok "a call behind an open insert fails with 90232" \
    || bad "expected 90232, got: $b_out"
  wait_for "$LOCK_HELD" 0 || bad "session A never committed"
  check "the retry succeeds once the writer has committed" "2" \
    "$(docker exec "$CONTAINER" psql -U postgres -d life1e -qtAc "$(fix_as_admin)" 2>&1)"
else
  bad "session A never took its lock on lock_probe"
fi

# --------------------------------------------------- 2 dump / single-pass restore
step "[2] Plain pg_dump -> SINGLE-PASS pg_restore, with custom data (B16)"
docker exec -i "$CONTAINER" psql -U postgres -d life1 -v ON_ERROR_STOP=1 -q >/dev/null 2>&1 <<'SQL'
INSERT INTO public.fields (table_name, field_name, title, format, field_order)
VALUES ('users', 'lifecycle_note', 'Lifecycle Note', 'text', 901);
INSERT INTO public.entities (table_name, singular, plural, singular_label, plural_label, module_id)
VALUES ('lifecycle_widgets','widget','widgets','Widget','Widgets',
        (SELECT id FROM public.modules ORDER BY id LIMIT 1));
INSERT INTO public.lifecycle_widgets (label) VALUES ('alpha'), ('beta'), ('gamma');
SQL
check "custom column added to the CORE users table" "lifecycle_note" \
  "$(psqlq life1 "SELECT column_name FROM information_schema.columns WHERE table_schema='public' AND table_name='users' AND column_name='lifecycle_note'")"
SIG1=$(psqlq life1 "$SIGNATURE_SQL")

docker exec "$CONTAINER" pg_dump -U postgres -Fc -d life1 -f /tmp/life1.dump \
  && ok "pg_dump -Fc (no filters, no flags)" || bad "pg_dump failed"
newdb life2
if docker exec "$CONTAINER" pg_restore -U postgres -d life2 --exit-on-error /tmp/life1.dump; then
  ok "pg_restore --exit-on-error: ONE pass, exit 0"
else
  bad "pg_restore failed"
fi
check "restored signature matches the source" "$SIG1" "$(psqlq life2 "$SIGNATURE_SQL")"
check "B16: the custom column survived" "lifecycle_note" \
  "$(psqlq life2 "SELECT column_name FROM information_schema.columns WHERE table_schema='public' AND table_name='users' AND column_name='lifecycle_note'")"
check "B16: its fields row survived" "users.lifecycle_note" \
  "$(psqlq life2 "SELECT id FROM public.fields WHERE id='users.lifecycle_note'")"
check "the custom entity's rows survived" "3" "$(psqlq life2 "SELECT count(*) FROM public.lifecycle_widgets")"
check "pending() is empty on the restored database" "0" "$(psqlq life2 "SELECT count(*) FROM semantius.pending()")"

# ------------------------------------------------------- 2b restore variants
step "[2b] Restore variants: -Fp | psql, -j 4, -1"
docker exec "$CONTAINER" pg_dump -U postgres -d life1 -f /tmp/life1.sql
newdb life2p
docker exec "$CONTAINER" sh -c "psql -U postgres -d life2p -v ON_ERROR_STOP=1 -q -f /tmp/life1.sql" >/dev/null 2>&1 \
  && ok "-Fp restored with psql -v ON_ERROR_STOP=1" || bad "-Fp restore failed"
check "  signature matches" "$SIG1" "$(psqlq life2p "$SIGNATURE_SQL")"
newdb life2j
docker exec "$CONTAINER" pg_restore -U postgres -d life2j -j 4 --exit-on-error /tmp/life1.dump \
  && ok "pg_restore -j 4" || bad "pg_restore -j 4 failed"
check "  signature matches" "$SIG1" "$(psqlq life2j "$SIGNATURE_SQL")"
newdb life2t
docker exec "$CONTAINER" pg_restore -U postgres -d life2t -1 --exit-on-error /tmp/life1.dump \
  && ok "pg_restore -1 (single transaction)" || bad "pg_restore -1 failed"
check "  signature matches" "$SIG1" "$(psqlq life2t "$SIGNATURE_SQL")"

# ---------------------------------- 5 restore where the extension is not installed
# The dump carries CREATE EXTENSION pg_semantius. On a server that cannot have
# the extension - a managed service such as Neon, Supabase or RDS, where you do
# not control the extension directory - that one statement must fail and NOTHING
# else must: the schema and the data are ordinary objects, not extension members.
# This is the practical half of "backup is a plain pg_dump": a dump you can only
# restore on a machine you control is not portable.
#
# The files are moved aside and put back IMMEDIATELY after the restore attempt,
# before any assertion runs, so a failing check can never leave the container
# without its extension for the steps that follow.
step "[5] Restore where the extension is NOT installed (managed-service case)"
docker exec -u root "$CONTAINER" sh -c "mkdir -p /tmp/extstash && mv $EXT_DIR/pg_semantius* /tmp/extstash/"
newdb life5
set +e
restore_out=$(docker exec "$CONTAINER" pg_restore -U postgres -d life5 /tmp/life1.dump 2>&1)
restore_rc=$?
set -e
docker exec -u root "$CONTAINER" sh -c "mv /tmp/extstash/pg_semantius* $EXT_DIR/ && rmdir /tmp/extstash"
check "the extension files are back in place" "1" \
  "$(docker exec "$CONTAINER" sh -c "test -f $EXT_DIR/pg_semantius.control && echo 1 || echo 0")"

if [ "$restore_rc" -ne 0 ]; then
  ok "pg_restore exits non-zero without --exit-on-error (the extension is missing)"
else
  bad "pg_restore exited 0 although the extension could not be created"
fi
err_all=$(printf '%s\n' "$restore_out" | grep -c 'error:' || true)
err_ext=$(printf '%s\n' "$restore_out" | grep 'error:' | grep -c 'pg_semantius' || true)
check "every restore error concerns pg_semantius and nothing else" "$err_all" "$err_ext"
check "the restored signature still matches the source" "$SIG1" "$(psqlq life5 "$SIGNATURE_SQL")"
check "B16: the custom column survived without the extension" "lifecycle_note" \
  "$(psqlq life5 "SELECT column_name FROM information_schema.columns WHERE table_schema='public' AND table_name='users' AND column_name='lifecycle_note'")"
check "the custom entity's rows survived" "3" "$(psqlq life5 "SELECT count(*) FROM public.lifecycle_widgets")"
check "no semantius schema, so no pending()/version()" "0" \
  "$(psqlq life5 "SELECT count(*) FROM pg_namespace WHERE nspname='semantius'")"
check "the database is functional: RLS policies intact" \
  "$(psqlq life1 "SELECT count(*) FROM pg_policies")" "$(psqlq life5 "SELECT count(*) FROM pg_policies")"
psqlrun life5 "INSERT INTO public.lifecycle_widgets (label) VALUES ('delta')" >/dev/null \
  && ok "the database is functional: an ordinary write works" \
  || bad "an ordinary write failed on the extension-less restore"
check "  and the row is there" "4" "$(psqlq life5 "SELECT count(*) FROM public.lifecycle_widgets")"

# ------------------------------------------------------------------- 4 drop
step "[4] DROP EXTENSION is inert"
SIG_BEFORE=$(psqlq life2 "$SIGNATURE_SQL")
psqlrun life2 "DROP EXTENSION pg_semantius" >/dev/null && ok "DROP EXTENSION without CASCADE succeeds" \
  || bad "DROP EXTENSION failed"
check "signature unchanged after the drop" "$SIG_BEFORE" "$(psqlq life2 "$SIGNATURE_SQL")"
check "the semantius schema is gone" "0" "$(psqlq life2 "SELECT count(*) FROM pg_namespace WHERE nspname='semantius'")"
check "the four roles remain" "4" \
  "$(psqlq life2 "SELECT count(*) FROM pg_roles WHERE rolname IN ('authenticated','semantius_user','semantius_authenticator','semantius_owner')")"
SIG_CASCADE_BEFORE=$(psqlq life2j "$SIGNATURE_SQL")
psqlrun life2j "DROP EXTENSION pg_semantius CASCADE" >/dev/null && ok "DROP EXTENSION CASCADE also succeeds" \
  || bad "DROP EXTENSION CASCADE failed"
check "CASCADE is equally inert" "$SIG_CASCADE_BEFORE" "$(psqlq life2j "$SIGNATURE_SQL")"
psqlrun life2 "CREATE EXTENSION pg_semantius" >/dev/null && ok "re-CREATE EXTENSION after a drop" || bad "re-create failed"
out=$(psqlq life2 "CALL semantius.migrate()")
echo "$out" | grep -q '"applied": 0' && ok "migrate() after re-create is a no-op" || bad "expected a no-op, got: $out"

# ------------------------------------------------------- 4b uninstall recipe
step "[4b] The documented uninstall recipe leaves no leftovers"
docker exec -i "$CONTAINER" psql -U postgres -d life2t -v ON_ERROR_STOP=1 -q >/dev/null 2>&1 <<'SQL'
DROP EXTENSION pg_semantius;
DROP EVENT TRIGGER IF EXISTS track_ddl_changes;
DROP EVENT TRIGGER IF EXISTS track_ddl_drops;
DROP EVENT TRIGGER IF EXISTS pgrst_ddl_watch;
DROP EVENT TRIGGER IF EXISTS pgrst_drop_watch;
DROP OWNED BY semantius_owner CASCADE;
DROP SCHEMA IF EXISTS common, rbac, audit, pgmq CASCADE;
DROP TABLE IF EXISTS public._versions;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT EXECUTE ON FUNCTIONS TO PUBLIC;
DROP OWNED BY semantius_user, authenticated, semantius_authenticator;
SQL
check "no event triggers left" "0" "$(psqlq life2t "SELECT count(*) FROM pg_event_trigger")"
# One row survives by design: undoing 0020_settings.once.sql's `REVOKE EXECUTE ON FUNCTIONS FROM
# PUBLIC` means granting it back, which stores the built-in default explicitly
# rather than deleting the row. Verified cosmetic - a function created
# afterwards gets the default ACL and PUBLIC can execute it, exactly as in a
# virgin database. Anything else left behind would be a real leak.
check "only the cosmetic FUNCTIONS default ACL is left" "postgres|public|f|{=X/postgres}" \
  "$(psqlq life2t "SELECT coalesce(string_agg(defaclrole::regrole::text||'|'||defaclnamespace::regnamespace::text||'|'||defaclobjtype::text||'|'||defaclacl::text, ','), '') FROM pg_default_acl")"
check "only public remains"    "public" \
  "$(psqlq life2t "SELECT string_agg(nspname, ',' ORDER BY nspname) FROM pg_namespace WHERE nspname NOT LIKE 'pg_%' AND nspname <> 'information_schema'")"
check "only plpgsql remains installed" "plpgsql" \
  "$(psqlq life2t "SELECT string_agg(extname, ',' ORDER BY extname) FROM pg_extension WHERE extname <> 'pgcrypto'")"
# B6 named four leftovers. The schema/event-trigger/default-ACL ones are checked
# above; these are the remaining three, each asserted rather than assumed.
# PostgreSQL 15+ gives `public` an explicit default ACL (pg_database_owner=UC
# plus PUBLIC=U), so the target is a virgin database's value, not an empty one.
newdb life_virgin
check "the public schema ACL is back to a virgin database's default" \
  "$(psqlq life_virgin "SELECT coalesce(array_to_string(nspacl, ','), '') FROM pg_namespace WHERE nspname='public'")" \
  "$(psqlq life2t "SELECT coalesce(array_to_string(nspacl, ','), '') FROM pg_namespace WHERE nspname='public'")"
# `DROP OWNED BY` does not revoke role MEMBERSHIPS. Only the recipe's final
# `DROP ROLE` clears them, and that step is conditional on no other database in
# the cluster using the roles - false here, since the harness's own appdb does.
# So assert exactly what survives, which pins where the recipe's boundary is.
check "the only surviving membership is the one DROP ROLE would clear" "authenticated" \
  "$(psqlq life2t "SELECT coalesce(string_agg(n.rolname, ',' ORDER BY n.rolname), '') FROM pg_auth_members m JOIN pg_roles g ON g.oid=m.roleid JOIN pg_roles n ON n.oid=m.member WHERE g.rolname='semantius_user'")"
# pgcrypto is the one leftover the recipe leaves ON PURPOSE (step 10 is
# optional: other things in the database may use it). Assert it is still there,
# so "optional" stays a decision rather than an oversight.
check "pgcrypto is left installed (the recipe's optional last step)" "1" \
  "$(psqlq life2t "SELECT count(*) FROM pg_extension WHERE extname='pgcrypto'")"

psqlrun life2t "CREATE EXTENSION pg_semantius" >/dev/null && psqlq life2t "CALL semantius.migrate()" >/dev/null \
  && ok "a clean install succeeds again on that database" || bad "reinstall after uninstall failed"
# ... and it is a REAL install, not an empty shell.
check "  the reinstall really recreated the core schema" "0" \
  "$(psqlq life2t "SELECT count(*) FROM semantius.pending()")"

# --------------------------------------------------------- 6 schema pinning
step "[6] Schema pinning (B2)"
newdb life6
psqlrun life6 "ALTER DATABASE life6 SET search_path = other, public" >/dev/null
psqlrun life6 "CREATE SCHEMA other" >/dev/null
psqlrun life6 "CREATE EXTENSION pg_semantius" >/dev/null \
  && ok "installs with a non-public default search_path" || bad "install with other search_path failed"
psqlq life6 "CALL semantius.migrate()" >/dev/null
check "pgcrypto still landed in public" "public" \
  "$(psqlq life6 "SELECT extnamespace::regnamespace::text FROM pg_extension WHERE extname='pgcrypto'")"
newdb life6b
# The target schema must exist, or PostgreSQL reports THAT first and the
# extension's own refusal is never reached.
psqlrun life6b "CREATE SCHEMA other" >/dev/null
err=$(psqlq life6b "CREATE EXTENSION pg_semantius SCHEMA other")
echo "$err" | grep -q 'must be installed in schema "public"' \
  && ok "SCHEMA other is refused with PostgreSQL's message" || bad "SCHEMA other: $err"

# -------------------------------------------------- 6b hostile session settings
step "[6b] Hostile session settings produce an identical install"
newdb life6c
docker exec -e PGOPTIONS='-c standard_conforming_strings=off -c check_function_bodies=off -c DateStyle=German -c IntervalStyle=sql_standard -c default_transaction_isolation=serializable -c session_replication_role=replica' \
  "$CONTAINER" psql -U postgres -d life6c -v ON_ERROR_STOP=1 -q \
  -c "CREATE EXTENSION pg_semantius" -c "CALL semantius.migrate()" >/dev/null 2>&1 \
  && ok "install succeeds under hostile PGOPTIONS" || bad "hostile install failed"
newdb life6d
psqlrun life6d "CREATE EXTENSION pg_semantius" >/dev/null; psqlq life6d "CALL semantius.migrate()" >/dev/null
check "hostile install signature equals the plain one" \
  "$(psqlq life6d "$SIGNATURE_SQL")" "$(psqlq life6c "$SIGNATURE_SQL")"
check "the standard_conforming_strings canary is intact" \
  "$(psqlq life6d "SELECT md5(pg_get_expr(adbin, adrelid)) FROM pg_attrdef d JOIN pg_class c ON c.oid=d.adrelid WHERE c.relname='topic_bindings' LIMIT 1")" \
  "$(psqlq life6c "SELECT md5(pg_get_expr(adbin, adrelid)) FROM pg_attrdef d JOIN pg_class c ON c.oid=d.adrelid WHERE c.relname='topic_bindings' LIMIT 1")"

# ------------------------------------------------------------- 7 refusals
step "[7] Refusals: real pgmq, misplaced pgcrypto, nested extension script"
newdb life7
psqlrun life7 "CREATE EXTENSION pg_semantius" >/dev/null
# A stub pgmq extension is enough: migrate() checks pg_extension, not the code.
docker exec -u root "$CONTAINER" sh -c "printf \"comment = 'stub'\ndefault_version = '1.0'\nrelocatable = false\n\" > $EXT_DIR/pgmq.control"
docker exec -u root "$CONTAINER" sh -c "printf 'CREATE SCHEMA IF NOT EXISTS pgmq_stub;\n' > $EXT_DIR/pgmq--1.0.sql"
psqlrun life7 "CREATE EXTENSION pgmq" >/dev/null 2>&1 || true
err=$(psqlq life7 "CALL semantius.migrate()")
echo "$err" | grep -q "pgmq extension is installed" && ok "a real pgmq is refused (B4)" || bad "pgmq refusal: $err"

# 7d. The same refusal on the CLI path. migrate()'s pre-flight raises before any
# migration runs, so 0310_pgmq.once.sql's own header guard is never reached above; `psql -f`
# on the raw file is the only path that reaches it. The stub pgmq extension
# staged for step 7 is still in place, which is why this sub-step sits here.
newdb life7d
psqlrun life7d "CREATE EXTENSION pgmq" >/dev/null 2>&1 || true
MPGMQ="$REPO_ROOT/apps/_core/migrations/0310_pgmq.once.sql"
docker cp "$(cygpath -w "$MPGMQ" 2>/dev/null || echo "$MPGMQ")" "$CONTAINER:/tmp/pgmq.sql" >/dev/null
err=$(docker exec "$CONTAINER" psql -U postgres -d life7d -v ON_ERROR_STOP=1 -f /tmp/pgmq.sql 2>&1 || true)
# This phrase is 0310_pgmq.once.sql's alone: the pre-flight says "is installed;", so the
# assertion cannot pass by way of the pre-flight it is meant to bypass.
echo "$err" | grep -q "installed in this database" \
  && ok "0310_pgmq.once.sql's own header guard refuses a real pgmq on the CLI path (B4)" \
  || bad "0310_pgmq.once.sql header guard: $err"
# The stub creates schema pgmq_stub, so any pgmq schema here would be 0310_pgmq.once.sql's.
check "  and creates no pgmq schema" "0" \
  "$(psqlq life7d "SELECT count(*) FROM pg_namespace WHERE nspname = 'pgmq'")"
docker exec -u root "$CONTAINER" rm -f "$EXT_DIR/pgmq.control" "$EXT_DIR/pgmq--1.0.sql"

newdb life7b
psqlrun life7b "CREATE SCHEMA crypt_elsewhere" >/dev/null
psqlrun life7b "CREATE EXTENSION pgcrypto SCHEMA crypt_elsewhere" >/dev/null
psqlrun life7b "CREATE EXTENSION pg_semantius" >/dev/null
err=$(psqlq life7b "CALL semantius.migrate()")
echo "$err" | grep -q "pgcrypto must be installed in schema public" \
  && ok "a misplaced pgcrypto is refused with a hint" || bad "pgcrypto refusal: $err"

newdb life7c
psqlrun life7c "CREATE EXTENSION pg_semantius" >/dev/null
docker exec -u root "$CONTAINER" sh -c "printf \"comment = 'nested'\ndefault_version = '1.0'\nrelocatable = false\nsuperuser = true\n\" > $EXT_DIR/pgsem_nested.control"
docker exec -u root "$CONTAINER" sh -c "printf 'CALL semantius.migrate();\n' > $EXT_DIR/pgsem_nested--1.0.sql"
err=$(psqlq life7c "CREATE EXTENSION pgsem_nested")
echo "$err" | grep -q "cannot run inside a CREATE/ALTER EXTENSION script" \
  && ok "migrate() refuses to run inside an extension script" || bad "nested refusal: $err"
docker exec -u root "$CONTAINER" rm -f "$EXT_DIR/pgsem_nested.control" "$EXT_DIR/pgsem_nested--1.0.sql"

# ----------------------------------------------------------- 8 privileges
step "[8] Privileges (B15)"
err=$(psqlq life1 "SET ROLE authenticated; CALL semantius.migrate()")
echo "$err" | grep -q "permission denied for schema semantius" \
  && ok "a request role cannot reach semantius.migrate()" || bad "role check: $err"
check "no function is PUBLIC-executable" "0" \
  "$(psqlq life1 "SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='semantius' AND has_function_privilege('public', p.oid, 'EXECUTE')")"
check "no function is SECURITY DEFINER" "0" \
  "$(psqlq life1 "SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='semantius' AND p.prosecdef")"
check "the schema is not PUBLIC-usable" "f" \
  "$(psqlq life1 "SELECT has_schema_privilege('public','semantius','USAGE')")"
# A role WITH usage and execute still hits the rolsuper gate.
psqlrun life1 "CREATE ROLE lifecycle_probe LOGIN; GRANT USAGE ON SCHEMA semantius TO lifecycle_probe; GRANT EXECUTE ON PROCEDURE semantius.migrate(jsonb) TO lifecycle_probe" >/dev/null
err=$(psqlq life1 "SET ROLE lifecycle_probe; CALL semantius.migrate()")
echo "$err" | grep -q "must be run by a superuser" \
  && ok "a granted non-superuser still gets the superuser message" || bad "rolsuper gate: $err"
psqlrun life1 "REVOKE ALL ON PROCEDURE semantius.migrate(jsonb) FROM lifecycle_probe; REVOKE ALL ON SCHEMA semantius FROM lifecycle_probe; DROP ROLE lifecycle_probe" >/dev/null 2>&1 || true

# B15 is about the CREATE EXTENSION refusal, which the checks above do NOT
# cover: they all exercise migrate(). Install as a plain non-superuser and
# assert PostgreSQL's own message, the one the shipped README quotes.
newdb life8c
psqlrun life8c "CREATE ROLE ext_probe LOGIN" >/dev/null 2>&1 || true
psqlrun life8c "GRANT CREATE ON DATABASE life8c TO ext_probe" >/dev/null 2>&1 || true
err=$(docker exec "$CONTAINER" psql -U postgres -d life8c -tAc \
        "SET ROLE ext_probe; CREATE EXTENSION pg_semantius" 2>&1 || true)
echo "$err" | grep -q "permission denied to create extension" \
  && ok "a non-superuser cannot CREATE EXTENSION (B15)" || bad "CREATE EXTENSION as non-superuser: $err"
echo "$err" | grep -qi "must be superuser" \
  && ok "  and the hint names the superuser requirement" || bad "expected a superuser hint, got: $err"
psqlrun life8c "DROP ROLE IF EXISTS ext_probe" >/dev/null 2>&1 || true

# B11's other half: the BYPASSRLS gate in 0100_rbac_rls.sql must RAISE, not ASSERT, so it
# cannot be switched off with plpgsql.check_asserts. Nothing else tests this.
# Match STATEMENTS, not the comment that explains why RAISE beat ASSERT: an
# earlier version of this check grepped for the word and failed on its own
# documentation.
n_assert=$(grep -cE "^[[:space:]]*ASSERT[[:space:]]" "$SQLFILE" || true)
check "no ASSERT statement survives in the generated script (B11)" "0" "$n_assert"

# ------------------------------------------------- 8d the BYPASSRLS gate fires
step "[8d] The BYPASSRLS gate of 0100_rbac_rls.sql refuses an installer without the attribute"
# A superuser bypasses RLS whatever the attribute says, but the gate READS the
# attribute, so a superuser WITHOUT BYPASSRLS is the role that trips it. That is
# also the realistic case: NOBYPASSRLS is the CREATE ROLE default whatever else
# a role has, and postgres here shows it only because initdb set it - which is
# why no install has ever reached this gate.
newdb life8d
psqlrun life8d "CREATE ROLE gate_probe SUPERUSER" >/dev/null 2>&1 || true  # roles are cluster-wide; a dead run may have left it
psqlrun life8d "ALTER ROLE gate_probe NOBYPASSRLS" >/dev/null
psqlrun life8d "CREATE EXTENSION pg_semantius" >/dev/null
err=$(psqlseq life8d "SET ROLE gate_probe" "CALL semantius.migrate()")
echo "$err" | grep -q "does not have BYPASSRLS" \
  && ok "a superuser without BYPASSRLS is refused by the 0100_rbac_rls.sql gate (B11)" \
  || bad "BYPASSRLS gate: $err"
# quote_ident() leaves a plain identifier unquoted, so the hint is verbatim.
echo "$err" | grep -q "ALTER ROLE gate_probe BYPASSRLS" \
  && ok "  and the hint names the fix" || bad "expected the ALTER ROLE hint, got: $err"
# This is what makes the assertion honest. migrate() commits file by file, so
# the files before the gate stay applied; a gate moved later, or softened to a
# NOTICE, would leave the schemas of the files after it standing. `audit` and
# `pgmq` are created well after the gate.
check "  and nothing after the gate was applied" "0" \
  "$(psqlq life8d "SELECT count(*) FROM pg_namespace WHERE nspname IN ('audit','pgmq')")"
# And the gate was the ONLY refusal: same role, same database, attribute added.
psqlrun life8d "ALTER ROLE gate_probe BYPASSRLS" >/dev/null
out=$(psqlseq life8d "SET ROLE gate_probe" "CALL semantius.migrate()")
echo "$out" | grep -q '"applied"' \
  && ok "  and the same role installs once it has BYPASSRLS" \
  || bad "gate_probe still cannot install with BYPASSRLS"
# pg_shdepend is cluster-wide, so the role can only be dropped once its database
# is gone. Under --keep both are left for triage and the next run reuses them.
if [ "$KEEP" != "1" ]; then
  dropdb_ life8d
  psqlq postgres "DROP ROLE IF EXISTS gate_probe" >/dev/null 2>&1 || true
fi

# --------------------------------------------------------- 8b role squatting
step "[8b] Role squatting is refused"
newdb life8
psqlrun life8 "CREATE ROLE squatter LOGIN CREATEROLE" >/dev/null 2>&1 || true
psqlq life8 "DROP ROLE IF EXISTS semantius_owner" >/dev/null 2>&1 || true
if [ "$(psqlq life8 "SELECT count(*) FROM pg_roles WHERE rolname='semantius_owner'")" = "0" ]; then
  psqlrun life8 "CREATE ROLE semantius_owner LOGIN" >/dev/null
  err=$(psqlq life8 "CREATE EXTENSION pg_semantius")
  echo "$err" | grep -q "unexpected attributes" \
    && ok "a squatted semantius_owner is refused" || bad "role squatting: $err"
  psqlq life8 "DROP ROLE IF EXISTS semantius_owner" >/dev/null 2>&1 || true
else
  ok "skipped: semantius_owner is in use by another database on this cluster"
fi
psqlq life8 "DROP ROLE IF EXISTS squatter" >/dev/null 2>&1 || true

# ------------------------------------------------------------- 9 encodings
step "[9] Non-UTF8 databases are refused (B9)"
docker exec "$CONTAINER" psql -U postgres -d postgres -qc "DROP DATABASE IF EXISTS life9" >/dev/null 2>&1
docker exec "$CONTAINER" psql -U postgres -d postgres -qc \
  "CREATE DATABASE life9 TEMPLATE template0 ENCODING 'LATIN1' LC_COLLATE 'C' LC_CTYPE 'C'" >/dev/null 2>&1
err=$(psqlq life9 "CREATE EXTENSION pg_semantius")
echo "$err" | grep -qi "encoding\|UTF8" && ok "LATIN1 is refused" || bad "LATIN1: $err"
docker exec "$CONTAINER" psql -U postgres -d postgres -qc "DROP DATABASE IF EXISTS life9b" >/dev/null 2>&1
docker exec "$CONTAINER" psql -U postgres -d postgres -qc \
  "CREATE DATABASE life9b TEMPLATE template0 ENCODING 'SQL_ASCII' LC_COLLATE 'C' LC_CTYPE 'C'" >/dev/null 2>&1
err=$(psqlq life9b "CREATE EXTENSION pg_semantius")
echo "$err" | grep -q "requires a UTF8 database" && ok "SQL_ASCII is refused with the 55000 message" || bad "SQL_ASCII: $err"

# ------------------------------------------------------------ 10 equivalence
step "[10] Equivalence: the extension-installed schema equals the migrate-installed one"
CLI_CONTAINER="${CLI_CONTAINER:-postgres18-cli}"
if docker exec "$CLI_CONTAINER" psql -U postgres -d appdb -tAc "SELECT 1" >/dev/null 2>&1 \
   && docker exec "$CONTAINER" psql -U postgres -d appdb -tAc "SELECT 1" >/dev/null 2>&1; then
  # Schema-only dumps of both stacks. Extension MEMBERS are never dumped, so
  # the semantius schema and its functions appear on neither side; only the
  # CREATE EXTENSION line does, and it is filtered out here.
  #
  # PostgreSQL 18 wraps dumps in psql meta-commands carrying a random key, so
  # every line beginning with a backslash is dropped. The pattern uses a
  # character class because some greps reject a pattern ending in a backslash.
  norm() { # norm <container> <outfile>
    docker exec "$1" pg_dump -U postgres -s -d appdb 2>/dev/null \
      | grep -v '^[\]' \
      | grep -v 'CREATE EXTENSION IF NOT EXISTS pg_semantius' \
      | grep -v 'COMMENT ON EXTENSION pg_semantius' \
      | grep -v '^--' \
      | grep -v '^$' > "$2"
  }
  norm "$CLI_CONTAINER" /tmp/lifecycle-cli.sql
  norm "$CONTAINER"     /tmp/lifecycle-ext.sql
  if diff -q /tmp/lifecycle-cli.sql /tmp/lifecycle-ext.sql >/dev/null; then
    ok "schemas are byte-identical ($(wc -l < /tmp/lifecycle-cli.sql) lines each)"
  else
    bad "schemas differ:"
    # `set -e -o pipefail` would abort the whole run here (diff exits 1), so the
    # remaining steps would silently never run. The failure is already recorded.
    diff /tmp/lifecycle-cli.sql /tmp/lifecycle-ext.sql | head -20 >&2 || true
  fi
  rm -f /tmp/lifecycle-cli.sql /tmp/lifecycle-ext.sql
else
  ok "skipped: needs appdb on both $CLI_CONTAINER (migrate path) and $CONTAINER"
fi

# ------------------------------------------------------------ 11 event noise
step "[11] Event-trigger noise: the DDL audit and NOTIFY pgrst are scoped (B5, P6, S15)"
# life1 is the fresh install from step 1 and is untouched by the steps between.
# The pgTAP suite proves the audit half of this (0810_test_audit_ddl_scope.sql);
# the NOTIFY half can only be proved here, because a notification is queued at
# COMMIT and the suite runs inside a transaction that rolls back.
psqlrun life1 "CREATE SCHEMA lifecycle_foreign" >/dev/null

# notify_probe <sql> -> echoes "notified", "silent", or one of the failure
# tokens no-listener / ddl-failed / listener-stuck.
# A detached psql session LISTENs and then sleeps; psql prints
#   Asynchronous notification "pgrst" ... received from server process ...
# when one arrives. Both waits poll on pg_stat_activity rather than sleeping a
# fixed time: the LISTEN must be committed before the DDL commits, and the
# listener must have exited before its output file is read. The poll matches the
# sleeper's query text exactly, so the polling query never counts itself.
# Every failure mode returns its OWN token, never "silent": a probe that never
# started would otherwise pass the three "silent" assertions by accident, and a
# failing DDL inside $(...) would abort the whole script under `set -e` before
# step 12 could clean up.
notify_probe() {
  docker exec "$CONTAINER" rm -f /tmp/listener.out >/dev/null 2>&1 || true
  docker exec -d "$CONTAINER" sh -c \
    "psql -U postgres -d life1 -c 'LISTEN pgrst' -c 'SELECT pg_sleep(5)' > /tmp/listener.out 2>&1"
  i=0
  while [ "$(psqlq life1 "SELECT count(*) FROM pg_stat_activity WHERE datname='life1' AND query = 'SELECT pg_sleep(5)'")" != "1" ]; do
    i=$((i + 1))
    if [ "$i" -gt 20 ]; then echo no-listener; return 0; fi
    sleep 1
  done
  if ! docker exec "$CONTAINER" psql -U postgres -d life1 -v ON_ERROR_STOP=1 -qc "$1" >/dev/null; then
    echo ddl-failed; return 0
  fi
  i=0
  while [ "$(psqlq life1 "SELECT count(*) FROM pg_stat_activity WHERE datname='life1' AND query = 'SELECT pg_sleep(5)'")" = "1" ]; do
    i=$((i + 1))
    if [ "$i" -gt 20 ]; then echo listener-stuck; return 0; fi
    sleep 1
  done
  if docker exec "$CONTAINER" grep -q 'Asynchronous notification "pgrst"' /tmp/listener.out 2>/dev/null; then
    echo notified
  else
    echo silent
  fi
}

res=$(notify_probe "CREATE TABLE lifecycle_foreign.t (id int)")
check "foreign schema: no NOTIFY pgrst" "silent" "$res"
check "foreign schema: no audit row" "0" \
  "$(psqlq life1 "SELECT count(*) FROM audit_ddl_logs WHERE object_identity LIKE 'lifecycle_foreign.%'")"

res=$(notify_probe "DROP TABLE lifecycle_foreign.t")
check "foreign schema: no NOTIFY pgrst on DROP" "silent" "$res"
# The drop half of the audit is a second event trigger on sql_drop, and it is
# bounded by the same five schemas as the create half.
check "foreign schema: no audit row on DROP" "0" \
  "$(psqlq life1 "SELECT count(*) FROM audit_ddl_logs WHERE object_identity LIKE 'lifecycle_foreign.%'")"

res=$(notify_probe "CREATE TEMP TABLE lifecycle_tmp (id int)")
check "temp table: no NOTIFY pgrst" "silent" "$res"
check "temp table: no audit row" "0" \
  "$(psqlq life1 "SELECT count(*) FROM audit_ddl_logs WHERE object_identity LIKE '%lifecycle_tmp%'")"

res=$(notify_probe "CREATE TABLE public.lifecycle_owned (id int)")
check "public schema: NOTIFY pgrst still fires" "notified" "$res"
check "public schema: audit row still written" "1" \
  "$(psqlq life1 "SELECT count(*) FROM audit_ddl_logs WHERE object_identity = 'public.lifecycle_owned'")"

# ddl_command_end reports nothing at all for a DROP, so a table could be
# destroyed and leave no evidence until the sql_drop trigger existed. The
# assertion reads every row the DROP added, not rows matching a name: measured
# on PostgreSQL 18 this one statement reports eight dropped objects - the table,
# its sequence, its rowtype, its array type, the id default, the not-null
# constraint, the primary key and its index - and exactly one of them, the
# table, may reach the log. A name filter would not see the constraint rows,
# which are identified as "<name> on public.<table>".
psqlrun life1 "CREATE TABLE public.lifecycle_dropped (id serial PRIMARY KEY)" >/dev/null
drop_base=$(psqlq life1 "SELECT coalesce(max(id), 0) FROM audit_ddl_logs")
psqlrun life1 "DROP TABLE public.lifecycle_dropped" >/dev/null
check "public schema: a committed DROP TABLE is audited, as the table alone" \
  "DROP TABLE|table|public.lifecycle_dropped" \
  "$(psqlq life1 "SELECT coalesce(string_agg(command_tag||'|'||object_type||'|'||object_identity, ',' ORDER BY id), '') FROM audit_ddl_logs WHERE id > $drop_base")"

# S15: before the SECURITY DEFINER fix this failed with
# "permission denied for function current_user_id" from audit.log_ddl_event().
# psqlrun, not psqlq: the statement succeeding IS the assertion, so its exit
# status must propagate. psqlq swallows it and would report ok on any error
# whose text happens not to contain "permission denied".
if out=$(psqlrun life1 "SET ROLE semantius_user; CREATE TEMP TABLE lifecycle_tmp_user (id int)" 2>&1); then
  ok "the request role can create a temp table (S15)"
else
  bad "the request role still cannot create a temp table: $out"
fi

# P6: current_query() is the whole migration script on the CLI path, once per
# event. The column is bounded; the generated label companions are not logged.
# Every statement life1 has seen is short (the install attributes migrate() as
# the query), so asserting max(length) <= 8192 over what is already there would
# pass just as well with the bound removed. Issue an over-long statement and
# pin the stored length exactly.
pad=$(head -c 9000 < /dev/zero | tr "\0" "x")
psqlrun life1 "CREATE TABLE public.lifecycle_long (id int) /* $pad */" >/dev/null
check "an over-long DDL statement is truncated to exactly 8192 characters" "8192" \
  "$(psqlq life1 "SELECT length(query_text) FROM audit_ddl_logs WHERE object_identity = 'public.lifecycle_long'")"
maxlen=$(psqlq life1 "SELECT COALESCE(max(length(query_text)), 0) FROM audit_ddl_logs")
[ "$maxlen" -le 8192 ] 2>/dev/null && ok "no audit row exceeds the bound (max $maxlen)" \
  || bad "query_text max length is $maxlen"

# ---------------------------------------------------------------- 12 cleanup
step "[12] Cleanup"
if [ "$KEEP" = "1" ]; then
  echo "   --keep: scratch databases left in place"
else
  for d in life1 life1b life1c life1d life1d2 life1e life1g life1h life2 life2p life2j life2t life5 \
           life6 life6b life6c life6d life7 life7b life7c life7d life8 life8c life8d life9 \
           life9b life_virgin; do
    dropdb_ "$d"
  done
  docker exec "$CONTAINER" rm -f /tmp/life1.dump /tmp/life1.sql /tmp/ext.sql /tmp/ext.control /tmp/listener.out /tmp/pgmq.sql || true
  ok "scratch databases and files removed"
fi

printf '\n=====================================\n'
printf 'lifecycle: %d passed, %d failed\n' "$pass_n" "$fail_n"
printf '=====================================\n'
[ "$fail_n" -eq 0 ] || exit 1
