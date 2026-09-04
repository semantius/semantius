#!/usr/bin/env bash
# pg-ext-lifecycle.sh - proves the pg_semantius extension LIFECYCLE end to end:
# install, backup, single-pass restore, drop, uninstall, and the refusals.
#
# The pgTAP suite (pg-ext-retest.sh) proves that the extension-installed core
# behaves like the migrate-installed one. This script proves the properties the
# suite cannot see from inside one database:
#
#   0.  preflight: control file and generated script
#   1.  fresh install, two statements, no CASCADE
#   1b. a second database on the same cluster (roles already exist)
#   1c. concurrency: two migrate() callers serialise on the advisory lock
#   1d. transaction shape: psql -1, and BEGIN/ROLLBACK leaves nothing
#   2.  plain pg_dump -> SINGLE-PASS pg_restore, with custom data (B16)
#   2b. restore variants: -Fp | psql, -j 4, -1
#   4.  DROP EXTENSION is inert (no data loss), with and without CASCADE
#   4b. the documented uninstall recipe leaves no leftovers
#   6.  schema pinning: non-public search_path installs, SCHEMA other refuses
#   6b. hostile session settings produce an identical install
#   7.  refusals: a real pgmq, pgcrypto in the wrong schema, nested extension
#   8.  privileges: non-superuser cannot migrate(); functions are locked down
#   8b. role squatting is refused
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

# ---------------------------------------------------------------- 0 preflight
step "[0] Preflight: control file and generated script"
CONTROL="$REPO_ROOT/extension/pg_semantius.control"
[ -f "$CONTROL" ] || { echo "No extension build in ../extension. Run: deno task extension <version>" >&2; exit 1; }
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

# Stage the files into the container (the image has no PGXS).
docker cp "$(cygpath -w "$SQLFILE" 2>/dev/null || echo "$SQLFILE")" "$CONTAINER:/tmp/ext.sql" >/dev/null
docker cp "$(cygpath -w "$CONTROL" 2>/dev/null || echo "$CONTROL")" "$CONTAINER:/tmp/ext.control" >/dev/null
docker exec -u root "$CONTAINER" cp /tmp/ext.sql "$EXT_DIR/$(basename "$SQLFILE")"
docker exec -u root "$CONTAINER" cp /tmp/ext.control "$EXT_DIR/pg_semantius.control"
ok "extension files staged into the container"

# ------------------------------------------------------------ 1 fresh install
step "[1] Fresh install: CREATE EXTENSION (no CASCADE) then migrate()"
newdb life1
out=$(psqlrun life1 "CREATE EXTENSION pg_semantius") && ok "CREATE EXTENSION succeeds without CASCADE" \
  || bad "CREATE EXTENSION failed: $out"

n_pending_before=$(psqlq life1 "SELECT count(*) FROM semantius.pending()")
[ "$n_pending_before" -gt 0 ] 2>/dev/null && ok "pending() works before _versions exists ($n_pending_before)" \
  || bad "pending() before migrate: $n_pending_before"
v=$(psqlq life1 "SELECT semantius.version()")
check "version() equals the control file" "$(grep '^default_version' "$CONTROL" | cut -d"'" -f2)" "$v"

out=$(psqlq life1 "SELECT semantius.migrate()")
echo "$out" | grep -q "applied" && ok "migrate(): $out" || bad "migrate() failed: $out"

check "pending() is empty after migrate()" "0" "$(psqlq life1 'SELECT count(*) FROM semantius.pending()')"
check "migrate() again is a no-op" "0" "$(psqlq life1 "SELECT count(*) FROM semantius.pending()")"
check "pgcrypto is in public" "public" "$(psqlq life1 "SELECT extnamespace::regnamespace::text FROM pg_extension WHERE extname='pgcrypto'")"
check "extconfig is NULL (no dump registry)" "t" "$(psqlq life1 "SELECT extconfig IS NULL FROM pg_extension WHERE extname='pg_semantius'")"
check "members: no relations" "0" "$(psqlq life1 "SELECT count(*) FROM pg_depend d JOIN pg_extension e ON e.oid=d.refobjid WHERE d.refclassid='pg_extension'::regclass AND d.deptype='e' AND e.extname='pg_semantius' AND d.classid='pg_class'::regclass")"
check "core relations are non-members" "0" "$(psqlq life1 "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace JOIN pg_depend d ON d.objid=c.oid AND d.deptype='e' AND d.refclassid='pg_extension'::regclass WHERE n.nspname IN ('public','common','rbac','audit','pgmq')")"
check "audit_ddl_logs attribute migrate() as the query" "1" \
  "$(psqlq life1 "SELECT count(DISTINCT query_text) FROM audit_ddl_logs WHERE query_text ~ 'semantius\.migrate'")"

SIG1=$(psqlq life1 "$SIGNATURE_SQL")
ok "signature (rows/policies/triggers/evt/functions) = $SIG1"

# ------------------------------------------------------------ 1b second database
step "[1b] Second database on the same cluster (roles already exist)"
newdb life1b
psqlrun life1b "CREATE EXTENSION pg_semantius" >/dev/null && psqlq life1b "SELECT semantius.migrate()" >/dev/null \
  && ok "install succeeds when the roles already exist" || bad "second-database install failed"
check "no postgres -> semantius_user membership (B11)" "0" \
  "$(psqlq life1b "SELECT count(*) FROM pg_auth_members m JOIN pg_roles g ON g.oid=m.roleid JOIN pg_roles n ON n.oid=m.member WHERE g.rolname='semantius_user' AND n.rolname='postgres'")"
# `common` must look exactly like `rbac`, which never carried 0012's
# `GRANT USAGE ... TO CURRENT_USER`. Testing for a `postgres=` entry directly
# would be wrong: 0290's GRANT to semantius_owner materialises the owner's own
# entry in every one of these schemas, artefact or not.
check "schema common has no extra installer grant (B11)" \
  "$(psqlq life1b "SELECT array_to_string(nspacl,',') FROM pg_namespace WHERE nspname='rbac'")" \
  "$(psqlq life1b "SELECT array_to_string(nspacl,',') FROM pg_namespace WHERE nspname='common'")"

# ------------------------------------------------------------ 1c concurrency
step "[1c] Concurrency: two migrate() callers serialise on the advisory lock"
newdb life1c
psqlrun life1c "CREATE EXTENSION pg_semantius" >/dev/null
# Session A holds the lock inside an open transaction; B must wait, not fail.
docker exec -d "$CONTAINER" psql -U postgres -d life1c -c \
  "BEGIN; SELECT semantius.migrate(); SELECT pg_sleep(5); COMMIT;" >/dev/null
sleep 2
b_out=$(docker exec "$CONTAINER" psql -U postgres -d life1c -tAc "SELECT semantius.migrate()" 2>&1)
echo "$b_out" | grep -qE "applied|skipped" && ok "second caller completed after the first committed: $b_out" \
  || bad "second caller: $b_out"
check "each migration applied exactly once" "0" \
  "$(psqlq life1c "SELECT count(*) FROM (SELECT name FROM public._versions GROUP BY name HAVING count(*)>1) d")"

# ------------------------------------------------------- 1d transaction shape
step "[1d] Transaction shape"
newdb life1d
docker exec "$CONTAINER" psql -U postgres -d life1d -v ON_ERROR_STOP=1 -q -1 \
  -c "CREATE EXTENSION pg_semantius" -c "SELECT semantius.migrate()" >/dev/null 2>&1 \
  && ok "psql -1 (both statements in one transaction) succeeds" || bad "psql -1 install failed"
newdb life1d2
psqlrun life1d2 "CREATE EXTENSION pg_semantius" >/dev/null
docker exec "$CONTAINER" psql -U postgres -d life1d2 -q \
  -c "BEGIN; SELECT semantius.migrate(); ROLLBACK;" >/dev/null 2>&1
check "a rolled-back migrate() leaves no _versions" "" "$(psqlq life1d2 "SELECT to_regclass('public._versions')")"
check "a rolled-back migrate() leaves no schema common" "0" \
  "$(psqlq life1d2 "SELECT count(*) FROM pg_namespace WHERE nspname='common'")"
check "the roles still exist after the rollback" "4" \
  "$(psqlq life1d2 "SELECT count(*) FROM pg_roles WHERE rolname IN ('authenticated','semantius_user','semantius_authenticator','semantius_owner')")"

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
out=$(psqlq life2 "SELECT semantius.migrate()")
echo "$out" | grep -q "0 applied" && ok "migrate() after re-create is a no-op: $out" || bad "expected a no-op, got: $out"

# ------------------------------------------------------- 4b uninstall recipe
step "[4b] The documented uninstall recipe leaves no leftovers"
docker exec -i "$CONTAINER" psql -U postgres -d life2t -v ON_ERROR_STOP=1 -q >/dev/null 2>&1 <<'SQL'
DROP EXTENSION pg_semantius;
DROP EVENT TRIGGER IF EXISTS track_ddl_changes;
DROP EVENT TRIGGER IF EXISTS pgrst_ddl_watch;
DROP EVENT TRIGGER IF EXISTS pgrst_drop_watch;
DROP OWNED BY semantius_owner CASCADE;
DROP SCHEMA IF EXISTS common, rbac, audit, pgmq CASCADE;
DROP TABLE IF EXISTS public._versions;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  REVOKE SELECT, INSERT, UPDATE, DELETE ON TABLES FROM semantius_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  REVOKE USAGE, SELECT ON SEQUENCES FROM semantius_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT EXECUTE ON FUNCTIONS TO PUBLIC;
DROP OWNED BY semantius_user, authenticated, semantius_authenticator;
SQL
check "no event triggers left" "0" "$(psqlq life2t "SELECT count(*) FROM pg_event_trigger")"
# One row survives by design: undoing 0050's `REVOKE EXECUTE ON FUNCTIONS FROM
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

psqlrun life2t "CREATE EXTENSION pg_semantius" >/dev/null && psqlq life2t "SELECT semantius.migrate()" >/dev/null \
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
psqlq life6 "SELECT semantius.migrate()" >/dev/null
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
  -c "CREATE EXTENSION pg_semantius" -c "SELECT semantius.migrate()" >/dev/null 2>&1 \
  && ok "install succeeds under hostile PGOPTIONS" || bad "hostile install failed"
newdb life6d
psqlrun life6d "CREATE EXTENSION pg_semantius" >/dev/null; psqlq life6d "SELECT semantius.migrate()" >/dev/null
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
err=$(psqlq life7 "SELECT semantius.migrate()")
echo "$err" | grep -q "pgmq extension is installed" && ok "a real pgmq is refused (B4)" || bad "pgmq refusal: $err"
docker exec -u root "$CONTAINER" rm -f "$EXT_DIR/pgmq.control" "$EXT_DIR/pgmq--1.0.sql"

newdb life7b
psqlrun life7b "CREATE SCHEMA crypt_elsewhere" >/dev/null
psqlrun life7b "CREATE EXTENSION pgcrypto SCHEMA crypt_elsewhere" >/dev/null
psqlrun life7b "CREATE EXTENSION pg_semantius" >/dev/null
err=$(psqlq life7b "SELECT semantius.migrate()")
echo "$err" | grep -q "pgcrypto must be installed in schema public" \
  && ok "a misplaced pgcrypto is refused with a hint" || bad "pgcrypto refusal: $err"

newdb life7c
psqlrun life7c "CREATE EXTENSION pg_semantius" >/dev/null
docker exec -u root "$CONTAINER" sh -c "printf \"comment = 'nested'\ndefault_version = '1.0'\nrelocatable = false\nsuperuser = true\n\" > $EXT_DIR/pgsem_nested.control"
docker exec -u root "$CONTAINER" sh -c "printf 'SELECT semantius.migrate();\n' > $EXT_DIR/pgsem_nested--1.0.sql"
err=$(psqlq life7c "CREATE EXTENSION pgsem_nested")
echo "$err" | grep -q "cannot run inside a CREATE/ALTER EXTENSION script" \
  && ok "migrate() refuses to run inside an extension script" || bad "nested refusal: $err"
docker exec -u root "$CONTAINER" rm -f "$EXT_DIR/pgsem_nested.control" "$EXT_DIR/pgsem_nested--1.0.sql"

# ----------------------------------------------------------- 8 privileges
step "[8] Privileges (B15)"
err=$(psqlq life1 "SET ROLE authenticated; SELECT semantius.migrate()")
echo "$err" | grep -q "permission denied for schema semantius" \
  && ok "a request role cannot reach semantius.migrate()" || bad "role check: $err"
check "no function is PUBLIC-executable" "0" \
  "$(psqlq life1 "SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='semantius' AND has_function_privilege('public', p.oid, 'EXECUTE')")"
check "no function is SECURITY DEFINER" "0" \
  "$(psqlq life1 "SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='semantius' AND p.prosecdef")"
check "the schema is not PUBLIC-usable" "f" \
  "$(psqlq life1 "SELECT has_schema_privilege('public','semantius','USAGE')")"
# A role WITH usage and execute still hits the rolsuper gate.
psqlrun life1 "CREATE ROLE lifecycle_probe LOGIN; GRANT USAGE ON SCHEMA semantius TO lifecycle_probe; GRANT EXECUTE ON FUNCTION semantius.migrate() TO lifecycle_probe" >/dev/null
err=$(psqlq life1 "SET ROLE lifecycle_probe; SELECT semantius.migrate()")
echo "$err" | grep -q "must be run by a superuser" \
  && ok "a granted non-superuser still gets the superuser message" || bad "rolsuper gate: $err"
psqlrun life1 "REVOKE ALL ON FUNCTION semantius.migrate() FROM lifecycle_probe; REVOKE ALL ON SCHEMA semantius FROM lifecycle_probe; DROP ROLE lifecycle_probe" >/dev/null 2>&1 || true

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

# B11's other half: the BYPASSRLS gate in 0050 must RAISE, not ASSERT, so it
# cannot be switched off with plpgsql.check_asserts. Nothing else tests this.
# Match STATEMENTS, not the comment that explains why RAISE beat ASSERT: an
# earlier version of this check grepped for the word and failed on its own
# documentation.
n_assert=$(grep -cE "^[[:space:]]*ASSERT[[:space:]]" "$SQLFILE" || true)
check "no ASSERT statement survives in the generated script (B11)" "0" "$n_assert"

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
# The pgTAP suite proves the audit half of this (0301_test_audit_ddl_scope.sql);
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

res=$(notify_probe "CREATE TEMP TABLE lifecycle_tmp (id int)")
check "temp table: no NOTIFY pgrst" "silent" "$res"
check "temp table: no audit row" "0" \
  "$(psqlq life1 "SELECT count(*) FROM audit_ddl_logs WHERE object_identity LIKE '%lifecycle_tmp%'")"

res=$(notify_probe "CREATE TABLE public.lifecycle_owned (id int)")
check "public schema: NOTIFY pgrst still fires" "notified" "$res"
check "public schema: audit row still written" "1" \
  "$(psqlq life1 "SELECT count(*) FROM audit_ddl_logs WHERE object_identity = 'public.lifecycle_owned'")"

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
# Two halves: the generated companions really exist (so the churn really
# happened and the next assertion is not vacuous), and none of it was logged.
n_label=$(psqlq life1 "SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND (p.proname = '_label' OR p.proname LIKE '%' || chr(92) || '_label')")
[ "$n_label" -gt 0 ] 2>/dev/null && ok "the install generated $n_label *_label companions" \
  || bad "no *_label companions found, so the next check proves nothing"
check "generated *_label functions produce no audit rows" "0" \
  "$(psqlq life1 "SELECT count(*) FROM audit_ddl_logs WHERE object_identity ~ '(^|[.])[^.(]*_label[(]'")"

# ---------------------------------------------------------------- 12 cleanup
step "[12] Cleanup"
if [ "$KEEP" = "1" ]; then
  echo "   --keep: scratch databases left in place"
else
  for d in life1 life1b life1c life1d life1d2 life2 life2p life2j life2t \
           life6 life6b life6c life6d life7 life7b life7c life8 life8c life9 \
           life9b life_virgin; do
    dropdb_ "$d"
  done
  docker exec "$CONTAINER" rm -f /tmp/life1.dump /tmp/life1.sql /tmp/ext.sql /tmp/ext.control /tmp/listener.out || true
  ok "scratch databases and files removed"
fi

printf '\n=====================================\n'
printf 'lifecycle: %d passed, %d failed\n' "$pass_n" "$fail_n"
printf '=====================================\n'
[ "$fail_n" -eq 0 ] || exit 1
