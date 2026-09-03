# pg_semantius open items

One document, one list. Every open item is a row in the table below, sorted by
priority. When an item is fixed, delete its row; git keeps the history. IDs come
from the release review of 2026-09-02 and are never reused, so gaps (S1 to
S4, S13, P1, B1, B2, B3, B4, B6, B7, B8, B9, B10, B12, B13, B14, B15, B16,
R2, R3, R4, R5, T1) mean fixed or dropped. The review,
the readiness hand-off, and the separate blocker and next-action lists that
used to sit above the detail tables were retired on 2026-09-03; all of them
are in git history under `plans/`.

S2, the client-writable permission cache, is solved for regular
configurations (PostgREST and app-server sessions, where the client never
runs SQL) and is deliberately not listed here. What remains of it applies to
PostgreSQL 18 OAuth bearer sessions only and is tracked in
`docs/bearer-mode-status.md`.

Last updated: 2026-09-03.

## Working agreement

- Nothing is released, and nothing that exists counts as a release. The
  0.3.0 and 0.4.0 extension builds were development snapshots: their version
  history (`extension/versions.json`, the 0.3.0 to 0.4.0 upgrade script) was
  discarded on 2026-09-03 and the manifest now holds only the current build.
  Fixes go into the original migrations; there are no upgrade scripts.
- The rows closed by that rebuild were moved to `plans/ext-solved-items.md`,
  which carries their original text, what changed, and the results of an
  independent audit of those claims. Read it before assuming an item is shut:
  B6, B10, B11 and R1 came back **partial**, and R2 is scope-changed rather
  than solved.
- The extension was rebuilt from scratch on 2026-09-03 as version 0.5.0 and
  is now a **thin installer**: `CREATE EXTENSION pg_semantius` creates only the
  cluster roles, the `semantius` schema and its functions, and
  `SELECT semantius.migrate()` installs the core schema as ordinary objects.
  Backup is a plain `pg_dump`, restore a single-pass `pg_restore`, and
  `DROP EXTENSION` causes no data loss. The design and the evidence are in
  `plans/pg_semantius-extension-rebuild.md`; the lifecycle is proven by
  `pgdocker/pg-ext-lifecycle.sh`. The schema is `semantius`, not
  `pg_semantius`: PostgreSQL reserves the `pg_` prefix for system schemas.
- Every fix lands with its pinning test in the same change. The suite must
  stay green on both install layouts: `pgdocker/pg-cli-retest.sh` (migrate
  path) and `pgdocker/pg-ext-retest.sh` (`CREATE EXTENSION` path); add
  `--coverage` for the report in `docs/pg_semantius-test-coverage.md`.
- Regenerate the extension with `deno task extension <version>` and the
  `packages/*/migrations-bundle.ts` copies with `scripts/bundle-sql.ts`
  before anything ships.
- No commits without asking.

Reachability in the priority column: (REST) callable through PostgREST as
`semantius_user`; (DB) needs SQL access as the request role, i.e. session
mode, an app-tier SQL injection, or a PostgreSQL 18 OAuth bearer session.
`rbac`, `common` and `pgmq` are not exposed by PostgREST. Timings are from the
review, measured inside rolled-back transactions on ephemeral 100k and
10k-row entities; method in Appendix B.

## Open items

Sorted by priority (High, Medium, Low, Info), then by ID. Area: `migration`
is a change to `apps/_core/migrations`, `extension` to the generator, control
file or shipped README, `tooling` to the harnesses and CI.

| ID | Priority | Area | Where | Problem | Fix | Done when |
|---|---|---|---|---|---|---|
| P2 | High | migration | `0180_computed_validation.sql` (`select_rule_<t>` policies), `0015` | The generated per-row function calls `ensure_context_initialized()`, builds `to_jsonb(row)` plus `$`-variables and runs `evaluate_json_logic`; opaque to the planner. 100k rows, rule `col1 == 'x'`: 4.7-7.2 s vs native 17.7 ms. Per row: `evaluate_json_logic` 51 µs, `ensure_context_initialized` 14 µs, `to_jsonb` 2.9 µs. | (a) Guard `ensure_context_initialized` behind `current_setting('app.context_initialized', true) IS DISTINCT FROM 'true'`; (b) compile the comparison/boolean subset of JsonLogic to a native boolean expression in the policy, keeping the function as fallback; hoist `$user_id/$now/$today` into InitPlans. | (a) about 25% less per row; (b) 100k-row scan under a compilable rule at about 20 ms (from 4.7 s), rule columns indexable. |
| P3 | High | migration | `0030_rbac_functions.sql` (`uid`, `ensure_context_initialized`, `has_permission`) | Every `has_permission` runs `rbac.uid()` twice, and each `uid()` issues two SPI queries (`SELECT system_user INTO`, `_settings` read). Measured: `has_permission` 26.6 µs per call, `uid()` 8.0 µs, `ensure_context_initialized` 14.4 µs, the cache check itself 0.4 µs. | Test `app.context_initialized` before calling `uid()`; drop the redundant `PERFORM rbac.uid()` in the checkers; `v := system_user` instead of `SELECT ... INTO`; cache the validated sub per transaction. Coordinate with the bearer-mode signed cache in `docs/bearer-mode-status.md`. Absorbs the rbac part of Q2. | `has_permission` at about 5 µs per call (from 26 µs), re-measured per Appendix B. |
| P4 | High | migration | `0150` (audit), `0170` (queue), `0180` generated validators | Three FOR EACH ROW triggers each do statement-constant work per row (`primary_key_columns` catalog query, `pgmq.send` dynamic SQL, JsonLogic evaluation). INSERT 10k rows: plain 65 ms; audit 1.5-2.0 s; queue 0.8-1.0 s; validation 0.7-1.1 s; all three 4.25 s. Floors: set-based audit insert 497 ms, `pgmq.send_batch(10k)` 114 ms. | Statement-level triggers with transition tables: one `INSERT ... SELECT` for audit rows, one `pgmq.send_batch(queue, array_agg(...))` for queue events; build `$old`/`$now` only when the rule references them. | 10k-row INSERT with all three triggers at about 1.0-1.3 s (from 4.25 s). |
| B5 | Medium | migration | `0090` (`pgrst_*` event triggers), `0150` (`track_ddl_changes`) | No `WHEN TAG IN` filter and no schema or `in_extension` filter: temp tables and unrelated schemas are logged, `NOTIFY pgrst` fires on any DDL anywhere. `CREATE TABLE other.t`: NOTIFY plus 2 audit rows; `CREATE TEMP TABLE`: 1 audit row. Both install paths log the install's own DDL again since the 2026-09-03 rebuild removed the `skip_audit` workaround; on the extension path every row carries `query_text = 'SELECT semantius.migrate()'`. | `WHEN TAG IN (...)`; skip `in_extension` and `pg_temp` objects in `audit.log_ddl_event`; restrict to dictionary-managed schemas. | DDL in an unrelated schema or on a temp table produces neither an audit row nor a NOTIFY. |
| B11 | Low | migration | `0010:37`, `0012:104` (the CURRENT_USER grants), `0050:20` (the BYPASSRLS gate) | Partly fixed 2026-09-03: both grants are now skipped when the installing role is a superuser, and 0050's `ASSERT` became a `RAISE EXCEPTION` (no `ASSERT` statement survives in the generated script, asserted by `pg-ext-lifecycle.sh`). The row's first alternative - "neither reaches the generated script" - is still unmet: both grants are present at `pg_semantius--0.5.0.sql:242` and `:531`, only runtime-guarded. | Either drop the grants from the generated script entirely, or accept the runtime guard and rewrite this row's done-when. Add a test that the BYPASSRLS `RAISE EXCEPTION` actually fires and that a superuser install skips the grants. | The BYPASSRLS gate has a test that fails when it is removed, and the grant-skip is asserted on a superuser install. |
| R1 | Medium | tooling | `pgdocker/pg-ext-lifecycle.sh` | Written 2026-09-03 and green (83 assertions, 0 failures), but two steps this row named are still absent: the **event-trigger noise** step (blocked on B5, whose behaviour it would pin) and **running the pgTAP suite** from the script. | Add both once B5 lands; the suite step can simply invoke `pg-ext-retest.sh`. | The script covers every step this row lists. |
| P5 | Medium | migration | `0070` (`fields` triggers), `0145` (`rebuild_entity_label_functions`) | Every `fields` insert triggers a full label-function rebuild and an `entities` UPDATE (usually a no-op) that cascades into a dozen `entities` triggers and a `modules` UPDATE. 30-field entity: 150 ms (5 ms/field); per 31 fields: 31 rebuilds, 186 DDL events, 518 event-trigger firings, 253 NOTIFYs, 93 audit rows. | `UPDATE entities ... WHERE searchable IS DISTINCT FROM v`; skip the rebuild for fields that are neither reference/parent nor the label column (trigger WHEN clause); statement-level rebuild with transition tables for bulk inserts. | About 1.5 ms per field (from 5 ms); audit rows per field 1 (from 3). |
| R7 | Low | tooling | `pgdocker/pg-ext-lifecycle.sh` | Steps the script does not cover. From the rebuild design: a fresh-cluster restore (needs a second container), the `ALTER EXTENSION ... UPDATE` path and its cross-version cases (needs a generated `<v+1>` bundle), failure atomicity (needs a deliberately broken migration), and the restore with the extension files absent. From R1's own original text, found by the 2026-09-03 audit: the event-trigger-noise step (blocked on B5) and invoking the pgTAP suite from this script. Also unexercised: the BYPASSRLS `RAISE EXCEPTION` firing and the superuser grant-skip at runtime (B11), 0160's own header guard on the CLI path (B4), and any repeatable assertion for LF normalisation (B13), which currently rests on the release job's diff guard. None gates the three requirements, which steps 1, 2 and 4 prove directly. | Add design §7 steps 3, 4c, 4c-b, 4d, 5, 5b, plus the two R1 steps and the four runtime gaps above. | The script covers every step listed in the design and in R1's original text. |
| P6 | Medium | migration | `0150_audit_log.sql` (`audit_ddl_logs.query_text`) | CLI path only since the 2026-09-03 rebuild: on the extension path `current_query()` is `SELECT semantius.migrate()`, about 1,500 small rows. On the CLI path it still stores `current_query()`, which for a migration script is the whole script, once per DDL event. 1,580 CREATE FUNCTION rows average 272 KB: 86 MB, 69% of the scratch database. 19% of all DDL events are generated label-function churn. | `left(current_query(), 8192)` or a hash plus dedup table; skip GRANT/REVOKE/COMMENT events for generated label functions. | `audit_ddl_logs` about 85% smaller after a full migration run. |
| P7 | Medium | migration | `rbac.uid`, `has_permission`, `has_any_permission`, `get_current_user_permissions`, `user_id`, `whoami`, `is_raci_actor`, `has_consultation`, generated `select_rule_*` | Declared STABLE but they write GUCs via `ensure_context_initialized`/`set_config`. The planner may evaluate them at plan time (side effects, a missing-JWT error during `EXPLAIN`/prepare) and their SQL sees the outer statement's snapshot (the workaround in `0080` exists because of this). 13 linter warnings. Hoisting is desirable: `WHERE rbac.has_permission('x')` over 20k rows is 5 ms hoisted vs 532 ms row-dependent. | Keep STABLE but move the writes into one VOLATILE `rbac.normalize_claims()`/`ensure_context_initialized()` called from a single place; the STABLE readers only read. | No plan-time side effects: `EXPLAIN` of a policy-guarded query without claims no longer raises; the 13 warnings are gone; the `0080` workaround can be removed. |
| Q7 | Medium (DB) | migration | `0160_pgmq.sql` (all vendored `pgmq.*` functions) | 75 linter warnings: every vendored function is EXECUTE-able by PUBLIC and none pins `search_path`; guard test 0240 excludes the `pgmq` schema. Practical exposure is limited (none is SECURITY DEFINER, the request role cannot read the queue tables) to information functions such as `list_queues`, `metrics_all`, `list_topic_bindings`. `convert_archive_partitioned` concatenates `table_name` (upstream code, never called). | Pin `search_path` on the vendored functions or document the exception in 0240; revoke PUBLIC on the information functions. | 0240 covers `pgmq` and is green. |
| S5 | Medium (REST) | migration | `0150_audit_log.sql` (`audit_record_logs`, `audit_ddl_logs` INSERT policies) | INSERT policies are `WITH CHECK (true)` and INSERT is granted to `semantius_user`; user1 and an unauthenticated caller inserted rows with a foreign `user_id` and arbitrary `command_tag`/`query_text`. | Revoke INSERT from `semantius_user`; the SECURITY DEFINER triggers are the only legitimate writers. | user1 `INSERT INTO audit_ddl_logs (...)` raises 42501. |
| S6 | Medium (DB) | migration | `0012_create_cache.sql` (`common.cache_get/set/delete/cleanup/stats`) | SECURITY DEFINER without `rbac.uid()` and EXECUTE-able by PUBLIC, contradicting the comment in the file. Same PUBLIC grant on `audit.log_ddl_event()` and `common.update_updated_at_column()` (harmless trigger functions, inconsistent with every other schema). | `REVOKE EXECUTE ... FROM PUBLIC` on all of them; extend guard test 0060 to the `common` and `audit` schemas (it only scopes `public` and `rbac`). | `has_function_privilege('semantius_user', 'common.cache_get(text)', 'EXECUTE')` is false; 0060 stays green. |
| S7 | Medium (REST) | migration | `0110_apikeys.sql` (`public.validate_api_key(text)`) | Granted to `semantius_user` although its header says it must not be; no `rbac.uid()`; runs bcrypt (cost 10) and a definer UPDATE of `last_used_at`; the `key_id` lookup returns before `crypt()`, so timing distinguishes known from unknown key ids. It is the single hard-coded exception in test 0060. | Revoke from `semantius_user` and PUBLIC (internal auth primitive). If it must stay callable, require `rbac.uid()` and remove the 0060 exception. | `has_function_privilege('semantius_user', 'public.validate_api_key(text)', 'EXECUTE')` is false. |
| S8 | Medium (REST) | migration | `0050_rbac_rls.sql` (first-user bootstrap trigger) | Administrator is granted when `NEW.last_seen IS NOT NULL` and no other user has `last_seen`. Pre-provisioned users who never logged in keep `last_seen` NULL, so the next new principal becomes admin. | Gate the bootstrap on "no user rows at all" or on a one-shot marker (`_settings.bootstrap_done`) taken under an advisory lock. | Seed one user with `last_seen` NULL, create a new user via `get_userinfo()`, assert it does not hold the Administrator role. |
| S9 | Medium (DB) | migration | `0030_rbac_functions.sql` (`user_has_permission`, `get_user_permissions`) | Both take an arbitrary `p_external_id` and are granted to `semantius_user`; only the caller's authentication is checked. user1 read user3's full permission set. | Allow target = self, otherwise require `admin` (mirror `list_api_keys`). | user1 `get_user_permissions('user3')` raises or returns nothing. |
| P8 | Low | migration | `0080` RPCs, `rbac.get_user_permissions`, `list_api_keys`, `require_*` | VOLATILE but read-only (8 linter warnings). PostgREST serves only STABLE/IMMUTABLE RPCs via GET in read-only transactions. | Label STABLE. | The 8 warnings are gone; the RPCs answer GET. |
| P9 | Low | migration | `0080_public_functions.sql` (`get_user_cubes`, `get_module_cubes`, `get_schema`) | Per-entity loops with three SPI queries each; `get_module_cubes` re-selects the entity it iterates. `get_user_cubes()` 20-39 ms for 15 entities; `get_schema` 1.9 ms each. Fine at 33 entities. | For more entities, one set-based query or a cache keyed on `modules.version`. | About 0.3 ms per entity at scale (from 1.3-2.6 ms). |
| P10 | Low | migration | `0020_rbac_schema.sql` (indexes) | Redundant indexes: `users.external_id` has three, `permissions.permission_name`, `roles.role_name`, `roles.slug` two each; `user_roles(user_id)`, `role_permissions(role_id)`, `user_permissions(user_id)`, `permission_hierarchy(including)` duplicate the leading column of their composite unique index. Nothing lacks an index; the recursive permission CTE runs in 0.6 ms with index-only scans. | Drop the duplicates. | The duplicates are gone; the permission CTE still uses index-only scans. |
| Q1 | Low | migration | `create_dd_table`, `enable_dd_table` | 2 linter false positives, `syntax error at or near "%I"`: the linter tries to parse a `format()` template with `%I` placeholders, and they hide real errors in those two functions. | Build the template so the linter can parse it (or split the statement) and re-lint both functions. | plpgsql_check parses both functions. |
| Q2 | Low | migration | `rbac.uid`, `rbac.user_has_permission`, `delete_dd_field`, and 13 more | 16 `SELECT expr INTO variable` where a plain assignment avoids SPI. | Assignments; the rbac ones are part of P3. | The 16 warnings are gone. |
| Q3 | Low | migration | `rename_dd_table` (6), `jl_to_number` (5), pgmq `read_*_with_poll`/`purge_queue` (4), `format_to_data_type`, `auto_set_order_value` | 18 implicit casts. | Explicit casts. | The 18 warnings are gone. |
| Q4 | Low | migration | `evaluate_json_logic`, the DD engine | 23 shadowed loop variables `i`/`j`/`v_idx`; harmless but unlintable. | Rename. | The 23 warnings are gone. |
| Q5 | Low | migration | `rename_dd_table`, pgmq `drop_queue`, `queue_event_after_insert`, and others | 12 unused or never-read variables. | Remove. | The 12 warnings are gone. |
| Q6 | Low | tooling | `pgmq.notify_queue_listeners()`, `raci_emit_trigger_fn()` | Could not be linted because no trigger uses them in a fresh install. | Bind them in a test or lint them explicitly. | Both appear in the lint report. |
| R6 | Low | tooling | `semantius-cov-scratch` (port 5439) | Scratch container from the review measurements is still running. | `docker rm -f semantius-cov-scratch` when no longer needed. | Container gone. |
| S10 | Low (DB) | migration | `0190_user_name_claims.sql` (`rbac.upsert_user_from_jwt`) | Granted to `semantius_user`; any caller can upsert any `external_id` and overwrite `email`/`last_seen`. user1 changed user3's email and created a ghost user. | Restrict to self (`external_id = rbac.uid()`), or revoke and call only from definer code (`get_userinfo`). | user1 upserting user3 raises. |
| S11 | Low (REST) | migration | `0090_notify_triggers.sql` (`common.refresh_schema_cache`) | `NOTIFY pgrst` is granted to `semantius_user`; anyone, authenticated or not, can spam PostgREST schema reloads. | Keep the grant only for the trigger path (call it from the definer triggers), or throttle. | Unauthenticated call raises. |
| S12 | Low (DB) | migration | `0030_rbac_functions.sql` (`has_permission`, `has_any_permission`, `user_has_permission`) | `app.oauth_scopes` is a client-settable GUC (a scoped session can clear its own confinement) and the delimiter is inconsistent: comma in `has_permission`/`has_any_permission`, space in `user_has_permission`. There is no definer entry point for scopes since `set_request_context` was removed. | Store scopes inside the signed cache planned in `docs/bearer-mode-status.md`; one delimiter everywhere; a self-only `rbac.set_request_scopes(p_oauth_scopes)` with normalisation and a narrow-only rule, see that document, step 5. | A scoped session that clears the GUC or calls the entry point with a wider list still has the scoped-out permission denied. |
| S15 | Low | migration | `0150_audit_log.sql` (`track_ddl_changes`, `audit.log_ddl_event`) | The event trigger fires for every DDL and calls `audit.current_user_id()`, which is revoked from `semantius_user`: the request role cannot even `CREATE TEMP TABLE`. | Grant EXECUTE on `audit.current_user_id()` to `semantius_user` and skip `pg_temp` objects in the event trigger (one change with B5). | user1 can create a temp table. |
| S16 | Low | migration | `entities.view_permission`/`edit_permission`, `modules.view_permission`, `queues.view_permission`/`manage_permission` | Permission names are stored as text, validated on save only, no foreign key. Deleting a permission that is still named leaves a dangling name that fails `has_permission` for everyone, admins included (fails closed). The UI renders these as plain text boxes because it keys on format, not on field name; `dashboards.view_permission` and `modules.manage_permission_id`/`admin_permission_id` are references and get the picker. Decision 2026-09-03: keep text for now; converting all of them touches the policy generators and the schema RPCs and needs its own plan. | Interim: a before-delete trigger on `permissions` that refuses to remove a name still used by an entity, module or queue. Later: convert to references. | Deleting a permission named by an entity raises. |
| S17 | Low | migration | `0050_rbac_rls.sql` (default privileges) | Default privileges grant `semantius_user` SELECT/INSERT/UPDATE/DELETE on every future table in `public`: any table created outside the data dictionary is fully writable by the request role unless it gets RLS. Documented as a behavior in `SECURITY.md` since 2026-09-03; dictionary tables always get RLS. | Decide: keep, or narrow the default and grant explicitly from `create_dd_table`. | A table created by hand in `public` is not writable by user1 (if narrowed), or the decision to keep is recorded here and the row deleted. |
| T2 | Low | tooling | plpgsql_check upstream | The profiler bug in Appendix A is worked around in `0145` but not reported. | File the report. | Issue link recorded here, then delete the row. |
| P11 | Info | migration | `0070_dd_functions.sql` (`searchable` toggle) | Toggling `searchable` drops and re-adds a GENERATED STORED tsvector column plus GIN index: a full rewrite under ACCESS EXCLUSIVE, 652 ms per 100k rows, linear. | Document the lock; optionally defer to statement end so several toggles rewrite once. | Documented, or one rewrite per statement. |
| S14 | Info | migration | `0030_rbac_functions.sql` (`rbac.uid`) | In session mode the request role controls `request.jwt.claim.*`; `system_user` pins the identity only for PG18 `oauth:` sessions; without a `jwt_aud` row in `_settings` the audience is not enforced. This is the trust model, documented in `SECURITY.md` (2026-09-03). | Require `jwt_aud`; link the policy from the consumer README (B8). | A missing `jwt_aud` row refuses `uid()` (today only a mismatched `aud` raises, tests 0250 and 0410). |

Linter context for the Q rows: plpgsql_check reported 122 warnings on 63
functions at the review. The 11 "EXECUTE expression is SQL injection
vulnerable" warnings are closed (S1 fixed, the remaining sites use
`format(%I/%L)`); the STABLE/VOLATILE warnings are P7 and P8; the rest are
Q1 to Q7.

## Extension baseline (what the rebuild replaced)

For reference, the 0.4.0 development snapshot: `relocatable = false`,
`superuser = true`, `requires = 'pgcrypto'`, no `schema`, `encoding` or
`trusted` parameter; members: 74 types, 270 functions, **52 relations**, 4
schemas, 3 event triggers, with `extconfig` covering every member table and
sequence except six documented transients. It needed a three-pass restore, a
`pg_extension_config_dump` registry and a `pg_semantius.skip_audit` workaround,
and `DROP EXTENSION` destroyed all data.

0.5.0 has **4 members** (the `semantius` schema and three functions), `extconfig
IS NULL`, and all 52 relations are ordinary objects.

## Appendix A. Upstream bug report draft (plpgsql_check)

Title: profiler re-evaluates dynamic EXECUTE expressions after execution
(`profiler_get_dyn_queryid`), breaking statements whose expression depends on
state the statement changed.

Repro (PostgreSQL 18.6, plpgsql_check 2.10.4):

```sql
CREATE FUNCTION public.f1() RETURNS int LANGUAGE sql AS 'SELECT 1';
CREATE FUNCTION public.drop_them() RETURNS void LANGUAGE plpgsql AS $$
DECLARE r record;
BEGIN
  FOR r IN SELECT p.oid::regprocedure AS sig FROM pg_proc p WHERE p.proname = 'f1' LOOP
    EXECUTE 'DROP FUNCTION IF EXISTS ' || r.sig;
  END LOOP;
END $$;
SET plpgsql_check.profiler = on;
SELECT public.drop_them();
-- ERROR:  syntax error at or near "16xxx"
-- CONTEXT:  PL/pgSQL function drop_them() line 5 at EXECUTE
```

With the profiler off the function succeeds. Cause: `profiler_stmt_end` calls
`profiler_get_queryid` then `profiler_get_dyn_queryid`, which runs
`profiler_plugin.assign_expr()` on the EXECUTE string expression a second
time (after the DROP) and `pg_parse_query()`s the result; the `regprocedure`
now renders as a bare OID and the parse fails inside the profiler. Any
expression with side effects (`nextval()`, `clock_timestamp()` in the SQL
text, `set_config`) is evaluated twice as well. Suggested fix: capture the
query string in `stmt_beg` (or from the executed statement's cached text)
instead of re-evaluating, and wrap the parse in `PG_TRY` so a profiler failure
never aborts the profiled function. No server setting avoids it
(`compute_query_id` off/on/regress, the fake queryid hook, versions 2.10.3
and 2.10.4 all fail).

## Appendix B. How to re-measure

- Catalog audit: `pg_proc`/`aclexplode` for PUBLIC and `semantius_user`
  EXECUTE, `pg_class.relrowsecurity`, `pg_policies`, `pg_extension.extconfig`,
  `pg_event_trigger`, `pg_default_acl`, `proconfig` search_path check.
- Linter: `extensions.plpgsql_check_function_tb(oid, relid => <first bound table>, security_warnings => true, performance_warnings => true, extra_warnings => true, compatibility_warnings => true)` over all PL/pgSQL members of the extension.
- Performance: `EXPLAIN (ANALYZE, BUFFERS)` and `\timing` inside `BEGIN ... ROLLBACK` as owner or after `pgtap.authenticate_as('user2')`; per-call costs from `pg_stat_xact_user_functions` with `track_functions = all`; 100k/10k-row ephemeral entities created through the data dictionary.
- Coverage: `deno task test --coverage` (plpgsql_check profiler plus `pg_stat_user_functions`), report and ratchet in `docs/pg_semantius-test-coverage.md`.
