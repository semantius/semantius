# pg_semantius open items

One document, one list. Every open item is a row in the table below, sorted by
priority. When an item is fixed, delete its row; git keeps the history. IDs come
from the release review of 2026-09-02 and are never reused, so gaps (S1 to
S4, S13, P1, B1, B3, B12, B14, R3, R4, T1) mean fixed or dropped. The review,
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
- The extension is rebuilt from scratch, as a first version, once the
  migration-level rows below are closed. The current packaging does not back
  up and restore cleanly (the member-table dump registry, B16), so it is
  redone rather than patched. Until then `extension/` is only the input of
  the extension-path harness, and the rows marked `extension` describe what
  the rebuild has to get right.
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
| B2 | High | extension | `extension/pg_semantius.control` (no `schema =`); generator `packages/cli/commands/extension.ts` (`buildControlFile`) | The extension is hard-pinned to `public` (104 functions `SET search_path = public`, 172 `public.`-qualified references) but the control file does not declare it, so unqualified objects land in the installer's default schema and the install aborts: `ALTER DATABASE ... SET search_path = myschema, public` then `CREATE EXTENSION` fails with `relation "roles" does not exist`; `CREATE EXTENSION pg_semantius SCHEMA other` fails the same way. | Emit `schema = public` in `buildControlFile`; PostgreSQL then forces the target schema and rejects `SCHEMA other` with a clear message. | Install with a non-`public` default search_path succeeds; `SCHEMA other` fails with the schema error (R1). |
| P2 | High | migration | `0180_computed_validation.sql` (`select_rule_<t>` policies), `0015` | The generated per-row function calls `ensure_context_initialized()`, builds `to_jsonb(row)` plus `$`-variables and runs `evaluate_json_logic`; opaque to the planner. 100k rows, rule `col1 == 'x'`: 4.7-7.2 s vs native 17.7 ms. Per row: `evaluate_json_logic` 51 µs, `ensure_context_initialized` 14 µs, `to_jsonb` 2.9 µs. | (a) Guard `ensure_context_initialized` behind `current_setting('app.context_initialized', true) IS DISTINCT FROM 'true'`; (b) compile the comparison/boolean subset of JsonLogic to a native boolean expression in the policy, keeping the function as fallback; hoist `$user_id/$now/$today` into InitPlans. | (a) about 25% less per row; (b) 100k-row scan under a compilable rule at about 20 ms (from 4.7 s), rule columns indexable. |
| P3 | High | migration | `0030_rbac_functions.sql` (`uid`, `ensure_context_initialized`, `has_permission`) | Every `has_permission` runs `rbac.uid()` twice, and each `uid()` issues two SPI queries (`SELECT system_user INTO`, `_settings` read). Measured: `has_permission` 26.6 µs per call, `uid()` 8.0 µs, `ensure_context_initialized` 14.4 µs, the cache check itself 0.4 µs. | Test `app.context_initialized` before calling `uid()`; drop the redundant `PERFORM rbac.uid()` in the checkers; `v := system_user` instead of `SELECT ... INTO`; cache the validated sub per transaction. Coordinate with the bearer-mode signed cache in `docs/bearer-mode-status.md`. Absorbs the rbac part of Q2. | `has_permission` at about 5 µs per call (from 26 µs), re-measured per Appendix B. |
| P4 | High | migration | `0150` (audit), `0170` (queue), `0180` generated validators | Three FOR EACH ROW triggers each do statement-constant work per row (`primary_key_columns` catalog query, `pgmq.send` dynamic SQL, JsonLogic evaluation). INSERT 10k rows: plain 65 ms; audit 1.5-2.0 s; queue 0.8-1.0 s; validation 0.7-1.1 s; all three 4.25 s. Floors: set-based audit insert 497 ms, `pgmq.send_batch(10k)` 114 ms. | Statement-level triggers with transition tables: one `INSERT ... SELECT` for audit rows, one `pgmq.send_batch(queue, array_agg(...))` for queue events; build `$old`/`$now` only when the rule references them. | 10k-row INSERT with all three triggers at about 1.0-1.3 s (from 4.25 s). |
| B4 | Medium | migration | `0160_pgmq.sql` (header) | If the real `pgmq` extension is installed in the target database the install aborts at `CREATE TABLE IF NOT EXISTS pgmq.meta` with `table pgmq.meta is not a member of extension "pg_semantius"`. | Fail fast with a clear message at the top of 0160, or namespace the vendored copy; delete the dead `extname = 'pgmq'` schema guard. | Install into a database with `pgmq` installed stops with the intended message. |
| B5 | Medium | migration | `0090` (`pgrst_*` event triggers), `0150` (`track_ddl_changes`) | No `WHEN TAG IN` filter and no schema or `in_extension` filter: temp tables and unrelated schemas are logged, `NOTIFY pgrst` fires on any DDL anywhere. `CREATE TABLE other.t`: NOTIFY plus 2 audit rows; `CREATE TEMP TABLE`: 1 audit row. The extension install no longer logs its own 1,522 DDL events (the script sets `pg_semantius.skip_audit`); the migrate path still does. | `WHEN TAG IN (...)`; skip `in_extension` and `pg_temp` objects in `audit.log_ddl_event`; restrict to dictionary-managed schemas. | DDL in an unrelated schema or on a temp table produces neither an audit row nor a NOTIFY. |
| B6 | Medium | extension | script head (role creation, default privileges); `extension/README.md` | `DROP EXTENSION` leaves the three cluster roles and their memberships (including `postgres` as member of `semantius_user`), two `ALTER DEFAULT PRIVILEGES` entries, the `public` schema ACL and pgcrypto; once any dictionary-created table exists it refuses to drop without `CASCADE` (`4 policies depend on rbac.has_permission(text)`), and `CASCADE` strips that table's policies and triggers but keeps its data. | Document an uninstall recipe; skip `GRANT ... TO current_user` under `CREATE EXTENSION`. | The recipe in the README leaves no leftovers on a fresh database (R1). |
| B7 | Medium | extension | `.github/workflows/extension-release.yml`; `extension.ts` | The release workflow regenerates from the tag and ships that without proving it equals the committed, tested `extension/` and without running pgTAP. | `git diff --exit-code extension/` after generation; run the pgTAP suite and the lifecycle script before `gh release create` (R2). Once a version is really released, fail the generator on edited or removed released migrations instead of warning. | The workflow cannot publish a build that differs from the committed one or that fails the suite. |
| B8 | Medium | extension | `extension/README.md`, `README.md`, `docker-postgres/README.md` | Missing for a public release: the third role `semantius_authenticator`, the GUC contract (`request.jwt.claims`, `request.jwt.claim.{sub,email,role,name,given_name,family_name,aud}`, `app.{current_user_id,user_permissions,oauth_scopes,current_external_id,context_initialized,bumping_module_version}`, `dd.table_rename`, `pg_semantius.skip_audit`), the `pgrst` NOTIFY channel, the real PostgreSQL floor (16: `system_user`, `GRANT ... WITH INHERIT FALSE, SET TRUE`), the `schema = public` requirement, event-trigger side effects, that default privileges bind to the installing role, the non-superuser error text (B15), and a link to `SECURITY.md` for the trust model. The shipped README refers to repo-only paths and tasks. | Split `buildReadme` into a consumer README (install, backup and restore, uninstall, roles, GUCs, PostgreSQL version) and keep maintainer notes in the repo README. | A grep of the README against the GUCs the script reads finds every one. |
| P5 | Medium | migration | `0070` (`fields` triggers), `0145` (`rebuild_entity_label_functions`) | Every `fields` insert triggers a full label-function rebuild and an `entities` UPDATE (usually a no-op) that cascades into a dozen `entities` triggers and a `modules` UPDATE. 30-field entity: 150 ms (5 ms/field); per 31 fields: 31 rebuilds, 186 DDL events, 518 event-trigger firings, 253 NOTIFYs, 93 audit rows. | `UPDATE entities ... WHERE searchable IS DISTINCT FROM v`; skip the rebuild for fields that are neither reference/parent nor the label column (trigger WHEN clause); statement-level rebuild with transition tables for bulk inserts. | About 1.5 ms per field (from 5 ms); audit rows per field 1 (from 3). |
| P6 | Medium | migration | `0150_audit_log.sql` (`audit_ddl_logs.query_text`) | Stores `current_query()`, which for a migration script is the whole script, once per DDL event. 1,580 CREATE FUNCTION rows average 272 KB: 86 MB, 69% of the scratch database. 19% of all DDL events are generated label-function churn. | `left(current_query(), 8192)` or a hash plus dedup table; skip GRANT/REVOKE/COMMENT events for generated label functions. | `audit_ddl_logs` about 85% smaller after a full migration run. |
| P7 | Medium | migration | `rbac.uid`, `has_permission`, `has_any_permission`, `get_current_user_permissions`, `user_id`, `whoami`, `is_raci_actor`, `has_consultation`, generated `select_rule_*` | Declared STABLE but they write GUCs via `ensure_context_initialized`/`set_config`. The planner may evaluate them at plan time (side effects, a missing-JWT error during `EXPLAIN`/prepare) and their SQL sees the outer statement's snapshot (the workaround in `0080` exists because of this). 13 linter warnings. Hoisting is desirable: `WHERE rbac.has_permission('x')` over 20k rows is 5 ms hoisted vs 532 ms row-dependent. | Keep STABLE but move the writes into one VOLATILE `rbac.normalize_claims()`/`ensure_context_initialized()` called from a single place; the STABLE readers only read. | No plan-time side effects: `EXPLAIN` of a policy-guarded query without claims no longer raises; the 13 warnings are gone; the `0080` workaround can be removed. |
| Q7 | Medium (DB) | migration | `0160_pgmq.sql` (all vendored `pgmq.*` functions) | 75 linter warnings: every vendored function is EXECUTE-able by PUBLIC and none pins `search_path`; guard test 0240 excludes the `pgmq` schema. Practical exposure is limited (none is SECURITY DEFINER, the request role cannot read the queue tables) to information functions such as `list_queues`, `metrics_all`, `list_topic_bindings`. `convert_archive_partitioned` concatenates `table_name` (upstream code, never called). | Pin `search_path` on the vendored functions or document the exception in 0240; revoke PUBLIC on the information functions. | 0240 covers `pgmq` and is green. |
| R1 | Medium | tooling | `pgdocker/pg-ext-lifecycle.sh` (to write) | No single script proves the extension lifecycle. | Steps: preflight (files, control); fresh install (extension row, empty audit log, seeded counts, object signature); second database; schema pinning (non-`public` search_path must install, `SCHEMA other` must fail with the schema error); non-superuser error text; dump plus three-pass restore with sample data and an exact counter diff (exists as `pgdocker/pg-ext-dump-restore.sh`, fold it in); drop leftovers (fresh DB and DB with a dictionary table); event-trigger noise; LATIN1 install; the pgTAP suite via `pg-ext-retest.sh`; cleanup. Expected results depend on B2, B5 and B9. | The script runs green on the rebuilt extension. |
| R2 | Medium | tooling | CI | No test workflow. | Add `.github/workflows/test.yml` (plain and coverage jobs on the extension install) and gate `extension-release.yml` on it (B7). | Both jobs green on a pull request. |
| S5 | Medium (REST) | migration | `0150_audit_log.sql` (`audit_record_logs`, `audit_ddl_logs` INSERT policies) | INSERT policies are `WITH CHECK (true)` and INSERT is granted to `semantius_user`; user1 and an unauthenticated caller inserted rows with a foreign `user_id` and arbitrary `command_tag`/`query_text`. | Revoke INSERT from `semantius_user`; the SECURITY DEFINER triggers are the only legitimate writers. | user1 `INSERT INTO audit_ddl_logs (...)` raises 42501. |
| S6 | Medium (DB) | migration | `0012_create_cache.sql` (`common.cache_get/set/delete/cleanup/stats`) | SECURITY DEFINER without `rbac.uid()` and EXECUTE-able by PUBLIC, contradicting the comment in the file. Same PUBLIC grant on `audit.log_ddl_event()` and `common.update_updated_at_column()` (harmless trigger functions, inconsistent with every other schema). | `REVOKE EXECUTE ... FROM PUBLIC` on all of them; extend guard test 0060 to the `common` and `audit` schemas (it only scopes `public` and `rbac`). | `has_function_privilege('semantius_user', 'common.cache_get(text)', 'EXECUTE')` is false; 0060 stays green. |
| S7 | Medium (REST) | migration | `0110_apikeys.sql` (`public.validate_api_key(text)`) | Granted to `semantius_user` although its header says it must not be; no `rbac.uid()`; runs bcrypt (cost 10) and a definer UPDATE of `last_used_at`; the `key_id` lookup returns before `crypt()`, so timing distinguishes known from unknown key ids. It is the single hard-coded exception in test 0060. | Revoke from `semantius_user` and PUBLIC (internal auth primitive). If it must stay callable, require `rbac.uid()` and remove the 0060 exception. | `has_function_privilege('semantius_user', 'public.validate_api_key(text)', 'EXECUTE')` is false. |
| S8 | Medium (REST) | migration | `0050_rbac_rls.sql` (first-user bootstrap trigger) | Administrator is granted when `NEW.last_seen IS NOT NULL` and no other user has `last_seen`. Pre-provisioned users who never logged in keep `last_seen` NULL, so the next new principal becomes admin. | Gate the bootstrap on "no user rows at all" or on a one-shot marker (`_settings.bootstrap_done`) taken under an advisory lock. | Seed one user with `last_seen` NULL, create a new user via `get_userinfo()`, assert it does not hold the Administrator role. |
| S9 | Medium (DB) | migration | `0030_rbac_functions.sql` (`user_has_permission`, `get_user_permissions`) | Both take an arbitrary `p_external_id` and are granted to `semantius_user`; only the caller's authentication is checked. user1 read user3's full permission set. | Allow target = self, otherwise require `admin` (mirror `list_api_keys`). | user1 `get_user_permissions('user3')` raises or returns nothing. |
| B9 | Low | extension | control (no `encoding`); several runtime string literals | 136 non-ASCII lines, some in runtime literals (the composed-label separator), with no `encoding = 'UTF8'`. Install into a LATIN1 database succeeds with mojibake. | `encoding = 'UTF8'` in the control and/or `chr(8250)` for the separator. | LATIN1 install either refuses or renders the separator correctly (R1). |
| B10 | Low | extension | `extension/META.json`, generator, workflow | `git://` repository URL, maintainer without email, no `release_status`, no `Changes` file in the archive (`LICENSE` and `SECURITY.md` are copied in since 2026-09-03). | `https://github.com/semantius/semantius.git`, maintainer email, `"release_status": "stable"`, a `Changes` file; validate META in CI. | META validates in CI. |
| B11 | Low | migration | `0012` (`GRANT USAGE ON SCHEMA common TO CURRENT_USER`), `0050` (BYPASSRLS `ASSERT`) | The grant is a test artefact and a no-op for the superuser owner; the assert is redundant under `superuser = true` and a no-op if `plpgsql.check_asserts = off`. | Strip both in the generator, or turn the assert into `RAISE EXCEPTION`. | Neither reaches the generated script, or the assert cannot be switched off. |
| B13 | Low | extension | `extension/pg_semantius--0.4.0.sql` | Mixed CRLF/LF in the working tree (`git ls-files --eol`: `i/lf w/mixed`); the local build bakes the working-tree file, CI bakes the LF blob. | Normalise line endings in `renderBody`. | The local and the CI build are byte-identical. |
| B16 | Low | extension | `extension-dump.ts` (`public.fields` filter), `create_dd_table` | Fields added to core entities after the install and relabelled core rows are not dumped (the filter keeps only rows of non-core entities), and the restored `users`-style table would lack the physical column anyway. Documented in the README as "re-apply after a restore". Add a field to `users`, dump, restore: the column and its `fields` row are gone. This is the main reason the packaging is rebuilt rather than patched. | Either forbid custom fields on core entities or dump `fields WHERE ctype = ''` plus a post-restore `ALTER TABLE` reconciliation; settle it in the rebuild's design. | A field added to `users` survives dump and restore (`pgdocker/pg-ext-dump-restore.sh`). |
| P8 | Low | migration | `0080` RPCs, `rbac.get_user_permissions`, `list_api_keys`, `require_*` | VOLATILE but read-only (8 linter warnings). PostgREST serves only STABLE/IMMUTABLE RPCs via GET in read-only transactions. | Label STABLE. | The 8 warnings are gone; the RPCs answer GET. |
| P9 | Low | migration | `0080_public_functions.sql` (`get_user_cubes`, `get_module_cubes`, `get_schema`) | Per-entity loops with three SPI queries each; `get_module_cubes` re-selects the entity it iterates. `get_user_cubes()` 20-39 ms for 15 entities; `get_schema` 1.9 ms each. Fine at 33 entities. | For more entities, one set-based query or a cache keyed on `modules.version`. | About 0.3 ms per entity at scale (from 1.3-2.6 ms). |
| P10 | Low | migration | `0020_rbac_schema.sql` (indexes) | Redundant indexes: `users.external_id` has three, `permissions.permission_name`, `roles.role_name`, `roles.slug` two each; `user_roles(user_id)`, `role_permissions(role_id)`, `user_permissions(user_id)`, `permission_hierarchy(including)` duplicate the leading column of their composite unique index. Nothing lacks an index; the recursive permission CTE runs in 0.6 ms with index-only scans. | Drop the duplicates. | The duplicates are gone; the permission CTE still uses index-only scans. |
| Q1 | Low | migration | `create_dd_table`, `enable_dd_table` | 2 linter false positives, `syntax error at or near "%I"`: the linter tries to parse a `format()` template with `%I` placeholders, and they hide real errors in those two functions. | Build the template so the linter can parse it (or split the statement) and re-lint both functions. | plpgsql_check parses both functions. |
| Q2 | Low | migration | `rbac.uid`, `rbac.user_has_permission`, `delete_dd_field`, and 13 more | 16 `SELECT expr INTO variable` where a plain assignment avoids SPI. | Assignments; the rbac ones are part of P3. | The 16 warnings are gone. |
| Q3 | Low | migration | `rename_dd_table` (6), `jl_to_number` (5), pgmq `read_*_with_poll`/`purge_queue` (4), `format_to_data_type`, `auto_set_order_value` | 18 implicit casts. | Explicit casts. | The 18 warnings are gone. |
| Q4 | Low | migration | `evaluate_json_logic`, the DD engine | 23 shadowed loop variables `i`/`j`/`v_idx`; harmless but unlintable. | Rename. | The 23 warnings are gone. |
| Q5 | Low | migration | `rename_dd_table`, pgmq `drop_queue`, `queue_event_after_insert`, and others | 12 unused or never-read variables. | Remove. | The 12 warnings are gone. |
| Q6 | Low | tooling | `pgmq.notify_queue_listeners()`, `raci_emit_trigger_fn()` | Could not be linted because no trigger uses them in a fresh install. | Bind them in a test or lint them explicitly. | Both appear in the lint report. |
| R5 | Low | tooling | `pgdocker/Dockerfile` | Without `plpgsql_check` in the dev image, `--coverage` on the pgdocker stacks degrades to function-level data. | Add `postgresql-18-plpgsql-check` to the runtime apt line (dev images only). The PGDG 2.10.4 build needs a current 18.x server: list `postgresql-18` in the same install line or build with `--pull`. | The coverage report has statement data on the pgdocker stacks. |
| R6 | Low | tooling | `semantius-cov-scratch` (port 5439) | Scratch container from the review measurements is still running. | `docker rm -f semantius-cov-scratch` when no longer needed. | Container gone. |
| S10 | Low (DB) | migration | `0190_user_name_claims.sql` (`rbac.upsert_user_from_jwt`) | Granted to `semantius_user`; any caller can upsert any `external_id` and overwrite `email`/`last_seen`. user1 changed user3's email and created a ghost user. | Restrict to self (`external_id = rbac.uid()`), or revoke and call only from definer code (`get_userinfo`). | user1 upserting user3 raises. |
| S11 | Low (REST) | migration | `0090_notify_triggers.sql` (`common.refresh_schema_cache`) | `NOTIFY pgrst` is granted to `semantius_user`; anyone, authenticated or not, can spam PostgREST schema reloads. | Keep the grant only for the trigger path (call it from the definer triggers), or throttle. | Unauthenticated call raises. |
| S12 | Low (DB) | migration | `0030_rbac_functions.sql` (`has_permission`, `has_any_permission`, `user_has_permission`) | `app.oauth_scopes` is a client-settable GUC (a scoped session can clear its own confinement) and the delimiter is inconsistent: comma in `has_permission`/`has_any_permission`, space in `user_has_permission`. There is no definer entry point for scopes since `set_request_context` was removed. | Store scopes inside the signed cache planned in `docs/bearer-mode-status.md`; one delimiter everywhere; a self-only `rbac.set_request_scopes(p_oauth_scopes)` with normalisation and a narrow-only rule, see that document, step 5. | A scoped session that clears the GUC or calls the entry point with a wider list still has the scoped-out permission denied. |
| S15 | Low | migration | `0150_audit_log.sql` (`track_ddl_changes`, `audit.log_ddl_event`) | The event trigger fires for every DDL and calls `audit.current_user_id()`, which is revoked from `semantius_user`: the request role cannot even `CREATE TEMP TABLE`. | Grant EXECUTE on `audit.current_user_id()` to `semantius_user` and skip `pg_temp` objects in the event trigger (one change with B5). | user1 can create a temp table. |
| S16 | Low | migration | `entities.view_permission`/`edit_permission`, `modules.view_permission`, `queues.view_permission`/`manage_permission` | Permission names are stored as text, validated on save only, no foreign key. Deleting a permission that is still named leaves a dangling name that fails `has_permission` for everyone, admins included (fails closed). The UI renders these as plain text boxes because it keys on format, not on field name; `dashboards.view_permission` and `modules.manage_permission_id`/`admin_permission_id` are references and get the picker. Decision 2026-09-03: keep text for now; converting all of them touches the policy generators and the schema RPCs and needs its own plan. | Interim: a before-delete trigger on `permissions` that refuses to remove a name still used by an entity, module or queue. Later: convert to references. | Deleting a permission named by an entity raises. |
| S17 | Low | migration | `0050_rbac_rls.sql` (default privileges) | Default privileges grant `semantius_user` SELECT/INSERT/UPDATE/DELETE on every future table in `public`: any table created outside the data dictionary is fully writable by the request role unless it gets RLS. Documented as a behavior in `SECURITY.md` since 2026-09-03; dictionary tables always get RLS. | Decide: keep, or narrow the default and grant explicitly from `create_dd_table`. | A table created by hand in `public` is not writable by user1 (if narrowed), or the decision to keep is recorded here and the row deleted. |
| T2 | Low | tooling | plpgsql_check upstream | The profiler bug in Appendix A is worked around in `0145` but not reported. | File the report. | Issue link recorded here, then delete the row. |
| B15 | Info | extension | `superuser = true` | Non-superuser install fails with `permission denied to create extension "pg_semantius" / HINT: Must be superuser`. | Quote the error in the README (B8). | Part of B8. |
| P11 | Info | migration | `0070_dd_functions.sql` (`searchable` toggle) | Toggling `searchable` drops and re-adds a GENERATED STORED tsvector column plus GIN index: a full rewrite under ACCESS EXCLUSIVE, 652 ms per 100k rows, linear. | Document the lock; optionally defer to statement end so several toggles rewrite once. | Documented, or one rewrite per statement. |
| S14 | Info | migration | `0030_rbac_functions.sql` (`rbac.uid`) | In session mode the request role controls `request.jwt.claim.*`; `system_user` pins the identity only for PG18 `oauth:` sessions; without a `jwt_aud` row in `_settings` the audience is not enforced. This is the trust model, documented in `SECURITY.md` (2026-09-03). | Require `jwt_aud`; link the policy from the consumer README (B8). | A missing `jwt_aud` row refuses `uid()` (today only a mismatched `aud` raises, tests 0250 and 0410). |

Linter context for the Q rows: plpgsql_check reported 122 warnings on 63
functions at the review. The 11 "EXECUTE expression is SQL injection
vulnerable" warnings are closed (S1 fixed, the remaining sites use
`format(%I/%L)`); the STABLE/VOLATILE warnings are P7 and P8; the rest are
Q1 to Q7.

## Extension baseline (for the rebuild)

Facts of the current generated build, as a reference for what the rebuild
replaces: `relocatable = false`, `superuser = true`, `requires = 'pgcrypto'`,
no `schema`, `encoding` or `trusted` parameter; no `@extschema@`; members:
74 types, 270 functions, 52 relations, 4 schemas, 3 event triggers.
`extconfig` covers every member table and sequence except six documented
transients (registry in `packages/cli/commands/extension-dump.ts`, three-pass
restore in the generated `extension/README.md`, pinned by
`apps/test/tests/0440_test_config_dump.sql` and
`pgdocker/pg-ext-dump-restore.sh`; the install script refuses to install
when a member relation is unregistered or a filter still selects a seeded
row, and silences the audit triggers with `pg_semantius.skip_audit`, honoured
in superuser sessions only, so both audit logs are dumped as well). The
version manifest holds only the current build; there is no upgrade script.

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
