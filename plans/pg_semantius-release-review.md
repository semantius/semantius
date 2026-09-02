# pg_semantius 0.4.0 release review (security, performance, best practices)

Date: 2026-09-02. Scope: the extension as generated from `apps/_core/migrations`
(33 files, `extension/pg_semantius--0.4.0.sql`), its control file and release
tooling. Every finding below was verified against the source (file:line) and,
where marked, reproduced with a rolled-back experiment on a throwaway
PostgreSQL 18.6 container that had `CREATE EXTENSION pg_semantius` plus the
Northwind sample and the test identities installed (user1: User role, user2:
Northwind Sales, user3: Administrator). Nothing in the repo was changed by
the review; fixes are proposed, not implemented.

Inputs: a full function/table/policy/trigger inventory, the plpgsql_check
2.10 linter over all 187 PL/pgSQL functions (with security and performance
warnings), a catalog privilege/RLS audit, the coverage data in
`docs/pg_semantius-test-coverage.md`, three independent review passes
(security, performance, packaging) and measurements with `EXPLAIN ANALYZE`
on ephemeral 100k-row entities.

## Fix status (2026-09-02, same day as the review)

Nothing is released, so fixes went into the original migrations (no upgrade
script needed). Applied and verified with the full suite on both install
layouts (2,007 assertions green, coverage run green):

| Finding | Fix | Where | Pinned by |
|---|---|---|---|
| S1 (Critical) | `quote_default_value()` now returns caller text only as a `quote_literal()` string (PostgreSQL casts it to the column type) or, for an exact-match allow-list of argument-less expressions (`CURRENT_TIMESTAMP`, `now()`, `gen_random_uuid()`, ...), booleans, plain numerics and `NULL`, the bare keyword; the `(`/`::` and type fall-through raw returns are gone. Every existing default in core and Northwind (`0`, `0.0`, `false`, `[]`, `CURRENT_DATE`, `CURRENT_TIMESTAMP`, enum names, words) still resolves. | `0070_dd_functions.sql` (function), all five callers unchanged | `0425_test_default_value_hardening.sql` (injection payloads rejected, no role created, legitimate defaults applied end to end) |
| S1 defence in depth | `fields.default_value` CHECK `valid_default_value`: no `;`, no control characters, no `--` or `/*`, at most 200 characters. | `0060_dd_schema.sql` | `0425` |
| Owner hardening (S1 root cause) | New last migration creates `semantius_owner` (NOLOGIN, NOSUPERUSER, NOCREATEDB, NOCREATEROLE, NOINHERIT, BYPASSRLS), re-owns every core table, sequence, view, function and type to it (other extensions' objects excluded, event triggers untouched), grants it CREATE/USAGE on the five schemas and reproduces the default privileges for objects it creates later. Runs only when the installer is a superuser; on Neon/Supabase it is a NOTICE no-op (only superusers can create BYPASSRLS roles, and there the installing role already is a non-superuser owner). SECURITY DEFINER dictionary code therefore runs with schema-owner powers, never superuser. | `0290_owner_hardening.sql` | `0430_test_owner_hardening.sql` (role attributes, ownership of all core relations/functions, dictionary-created tables and generated functions owned by the role, request-role privileges preserved) |
| S13 (Low) | `validation_rules[].code`, `computed_fields[].name` and `message` are emitted into the generated trigger body as `quote_literal()` strings (with `%` escaped where used as a RAISE format). | `0180_computed_validation.sql` | `0425` group 4 (quotes and percent signs in code/name/message) |
| T1 (tooling) | `rebuild_entity_label_functions` builds the DROP statement into a variable before `EXECUTE`, so the plpgsql_check profiler's re-evaluation is harmless; `--coverage` now runs the full suite without any scratch workaround. | `0145_managed_enable.sql:793` | coverage run green (2,007 assertions, 83.5% statements) |

Audit of every other user-writable column that reaches dynamic SQL, done for
this fix: `fields.format`/`precision` (CASE mapping with a fixed ELSE, typed
column), `reference_delete_mode` (CASE plus CHECK), `enum_values`
(`quote_literal` per element), `unique_value` (boolean), all identifiers
(`table_name`, `field_name`, `reference_table`, `label_parent`,
`order_column`, `queue_name`, RACI entity names: `%I`), permissions in
policies (`%L`), `select_rule`/JsonLogic (`quote_literal`), descriptions and
titles (`COMMENT ... %L`), `queue_table_events.event_handler` (CASE),
`audit.enable_tracking` (`regclass`), the label-function generator (`%I`/`%L`
throughout). No other raw interpolation exists; the vendored pgmq
`convert_archive_partitioned` still concatenates `table_name` but is not
SECURITY DEFINER and is never called by Semantius code (S-02 covers its
exposure).

Still open from this review: S2, S3, S4 (High), B1, B2, B3 and everything
Medium and below.

## Release blockers (open)

S1 (default-value SQL injection, Critical) was the seventh entry here; it is
fixed in the original migrations together with the owner hardening (see "Fix
status" above) and is no longer a blocker.

| ID | Severity | One line |
|---|---|---|
| S2 | High | The permission cache is a client-settable GUC; any in-database session of the request role can grant itself `admin` for the transaction. Verified. |
| S3 | High | `rbac.set_request_context('<any user>')` loads another user's permissions into the caller's session. Verified (user1 became Administrator for the transaction). |
| S4 | High | `queue_read/pop/archive/delete` accept any queue name from any authenticated user (PostgREST-reachable). Verified: user1 read `orders` events and could pop `raci_notify`. |
| B1 | Critical | No extension table is registered with `pg_extension_config_dump`; a plain `pg_dump`/`pg_restore` of an installed database silently drops every user, role, permission, entity, field, module, API key, queue and audit row while the physical entity tables survive as orphans. Verified (modules 2 to 1, users 1 to 0, `_versions` 34 to 33). |
| B2 | High | `CREATE EXTENSION` aborts mid-script (`relation "roles" does not exist`) in any database whose default creation schema is not `public`, and with `CREATE EXTENSION ... SCHEMA other`; the control file needs `schema = public`. Verified. |
| B3 | High | Even with config-dump registration a single-shot `pg_restore` fails (FK cycles between `modules`/`permissions`/`roles`, dictionary triggers firing during `COPY`); the restore procedure must be three-phase with `--disable-triggers`. Verified. |
| P1 | High | Generated RLS policies use the bare `USING (rbac.has_permission(...))` form and are evaluated per row (1.7 s for 100k rows vs 10 ms with the sub-select form). |

Everything else is Medium or below and can follow in the next minor version.

---

## 1. Security findings

Reachability legend: (REST) callable through PostgREST as `semantius_user`;
(DB) needs SQL access as the request role, i.e. session mode
(`semantius_authenticator` + `SET ROLE authenticated`), an app-tier SQL
injection, or any future wrapper. The `rbac` and `common` schemas are not
exposed by PostgREST.

| ID | Severity | Where | Finding | Evidence | Fix | Pinning test |
|---|---|---|---|---|---|---|
| S1 | **Critical**, FIXED (was REST, admin) | `0070_dd_functions.sql:163-196` (`quote_default_value`), callers `0070:582,903`, `0140:678`, `0145:59,502` | `quote_default_value` returns the value **raw** when it contains `(` or `::` (line 172) and for every type that is not text/numeric/boolean (line 195). The callers interpolate it with `%s` into `ALTER TABLE %I ALTER COLUMN %I SET DEFAULT %s` and `EXECUTE` it inside SECURITY DEFINER triggers owned by the installing superuser. | As user3 (admin): `UPDATE fields SET default_value = '(0); CREATE ROLE pwned SUPERUSER'` on an integer field of `shippers` created the role with `rolsuper = t`. Four variants worked (`;` after `(...)`, `::`, at field creation, at update). | Never emit a raw default: quote everything with `%L` unless it matches a strict allow-list (`^-?[0-9]+(\.[0-9]+)?$`, `TRUE/FALSE`, `NULL`, a fixed list of function calls such as `now()`, `CURRENT_TIMESTAMP`, `gen_random_uuid()`); drop the `~ '\(|::'` and fall-through branches. Also reconsider running DD DDL as a dedicated owner role without superuser. | user3 sets `default_value := '(0); CREATE ROLE x SUPERUSER'` on a fresh field: expect an error and `pg_roles` unchanged. |
| S2 | **High** (DB) | `0030_rbac_functions.sql:311-355` (`ensure_context_initialized`), `:529-571` (`has_permission`) | The transaction-scoped cache `app.user_permissions` / `app.context_initialized` is an ordinary GUC that the request role can set; `has_permission` trusts it verbatim. | As user1: `set_config('app.context_initialized','true',true)` + `set_config('app.user_permissions','admin',true)` made `rbac.has_permission('admin')` true and the admin-only `roles`/`permissions` tables readable. | Keep the cache but make it unforgeable: derive permissions inside a SECURITY DEFINER path only and store them under a value the client cannot set (e.g. a GUC namespaced to a placeholder reserved with `MarkGUCPrefixReserved`, or a `pg_temp` table created by the definer, or re-validate the cache against a definer-computed hash per transaction). | user1 sets both GUCs by hand; `rbac.has_permission('admin')` must stay false. |
| S3 | **High** (DB) | `0190_user_name_claims.sql:187-240` | `rbac.set_request_context(p_external_id, ...)` uses `COALESCE(p_external_id, rbac.uid())` as the identity, upserts that user and loads that user's permissions and id into the session. | `authenticate_as('user1'); set_request_context('user3')` then `has_permission('admin') = true`, `rbac.user_id() = 1003`. | Ignore `p_external_id` unless the caller holds an explicit service/admin permission; otherwise always use `rbac.uid()`. Revoke from `semantius_user` if only trusted code calls it. | user1 calls `set_request_context('user3')`: expect 42501 and `has_permission('admin') = false`. |
| S4 | **High** (REST) | `0170_queue.sql:352-461` | The four queue RPCs are SECURITY DEFINER, granted to `semantius_user`, and only call `rbac.uid()`: no permission check, no check that the queue is registered, arbitrary `p_queue_name`, unbounded `p_vt`/`p_qty`. | As user1: `queue_read('events', 3600, 10)` returned an `orders` event (record id of a table user1 cannot read) and hid it from real consumers for an hour; `queue_pop('raci_notify')` succeeded. | Resolve the queue through `queues`, enforce its `view_permission` for read and `edit_permission` for pop/archive/delete, reject unregistered names, clamp `p_vt` and `p_qty`. | user1: `queue_pop('events')` raises 42501; `queue_read('events', 0, 1)` raises 42501. |
| S5 | Medium (REST) | `0150_audit_log.sql:582-616` | `audit_record_logs` / `audit_ddl_logs` INSERT policies are `WITH CHECK (true)` and INSERT is granted to `semantius_user`. | user1 and an unauthenticated `semantius_user` inserted rows with `user_id = 1003` and arbitrary `command_tag`/`query_text`. | Revoke INSERT from `semantius_user`; the SECURITY DEFINER triggers are the only legitimate writers. | user1 `INSERT INTO audit_ddl_logs (...)` raises 42501. |
| S6 | Medium (DB) | `0012_create_cache.sql:27-105` | `common.cache_get/set/delete/cleanup/stats` are SECURITY DEFINER without `rbac.uid()` and EXECUTE-able by PUBLIC (no REVOKE), contradicting the comment at line 102. | user1 and an unauthenticated `semantius_user` ran `cache_set/get/stats/cleanup`. | `REVOKE EXECUTE ... FROM PUBLIC` on all five; extend the 0060 guard test to the `common` and `audit` schemas (it only scopes `public` and `rbac`). | `has_function_privilege('semantius_user', 'common.cache_get(text)', 'EXECUTE')` is false. |
| S7 | Medium (REST) | `0110_apikeys.sql:122,177` | `public.validate_api_key(text)` is granted to `semantius_user` although its header says it must not be, has no `rbac.uid()`, runs bcrypt (cost 10) and a definer UPDATE of `last_used_at`; the `key_id` lookup returns before `crypt()` so timing distinguishes known from unknown key ids. | Callable unauthenticated. It is also the single hard-coded exception in test 0060. | Revoke from `semantius_user`/PUBLIC (internal auth primitive); if it must stay callable, require `rbac.uid()` and remove the 0060 exception. | `has_function_privilege('semantius_user', 'public.validate_api_key(text)', 'EXECUTE')` is false. |
| S8 | Medium (REST) | `0050_rbac_rls.sql:271-303` | First-user bootstrap grants Administrator when `NEW.last_seen IS NOT NULL` and no other user has `last_seen`. Pre-provisioned users who never logged in keep `last_seen` NULL, so the next new principal becomes admin. | With user1-3 seeded (`last_seen` NULL), a brand-new sub calling `get_userinfo()` received the Administrator role. | Gate the bootstrap on "no user rows at all" or on an explicit one-shot marker (`_settings.bootstrap_done`) taken under an advisory lock. | Seed one user with `last_seen` NULL, create a new user via `get_userinfo()`, assert it does not hold role 2. |
| S9 | Medium (DB) | `0030:422-528` (`user_has_permission`), `:686-739` (`get_user_permissions`) | Both take an arbitrary `p_external_id` and are granted to `semantius_user`; only the caller's authentication is checked. | user1 read user3's full permission set including `admin`. | Allow target = self, otherwise require `admin` (mirror `list_api_keys`). | user1: `get_user_permissions('user3')` raises or returns nothing. |
| S10 | Low (DB) | `0190_user_name_claims.sql:30-65` | `rbac.upsert_user_from_jwt` is granted to `semantius_user`; any caller can upsert any `external_id` and overwrite `email`/`last_seen`. | user1 changed user3's email and created a ghost user. | Restrict to self (`external_id = rbac.uid()`) or revoke and call only from definer code. | user1 upserting user3 raises. |
| S11 | Low (REST) | `0090_notify_triggers.sql:176` | `common.refresh_schema_cache()` (`NOTIFY pgrst`) is granted to `semantius_user`; any caller, authenticated or not, can spam PostgREST schema reloads. | Verified callable unauthenticated. | Keep the grant only for the trigger path (call it from the definer triggers), or throttle. | unauthenticated call raises. |
| S12 | Low (DB) | `0030:494,557,638`, `0190:229` | `app.oauth_scopes` is a client-settable GUC (a scoped session can clear its own confinement) and its delimiter is inconsistent: comma-separated in `has_permission`/`has_any_permission`, space-separated in `user_has_permission`, stored verbatim by `set_request_context`. | user1 with scopes `public:read` was denied `user:read`; after `set_config('app.oauth_scopes','')` it was allowed. | Store scopes with the (fixed) permission cache; normalise to one delimiter in `set_request_context`. | scoped session clears the GUC; a scoped-out permission stays denied. |
| S13 | Low, FIXED (admin) | `0180_computed_validation.sql:93-131` | `validation_rules[].code` and `computed_fields[].name` are inserted raw into the generated trigger body (only `%` is escaped; `message` and the JsonLogic are `quote_literal`ed). A quote breaks the generated function. Not exploitable for privilege gain: the insertion point sits after an unconditional `RAISE EXCEPTION`, so injected statements are dead code. | Attempts with `'`/`$$` produced syntax errors or broke the entity's trigger; no execution. | `quote_literal` both values like `message`. | admin saves a rule whose `code` contains `'`; the entity still accepts writes or the save is rejected cleanly. |
| S14 | Info | `0030:110-237` | In session mode the request role controls `request.jwt.claim.*`; `system_user` pins the identity only for PG18 `oauth:` sessions; without a `jwt_aud` row in `_settings` the audience is not enforced. This is the documented trust model, listed so deployments never expose the request role directly and configure `jwt_aud`. | user1 setting `request.jwt.claim.sub = 'user3'` became user3. | Document; require `jwt_aud`; prefer bearer/OAuth. | with `jwt_aud` set, a missing/mismatched `aud` raises (0250, 0410). |
| S15 | Low | `0150_audit_log.sql:385-404` | `track_ddl_changes` fires for every DDL in the database and `audit.log_ddl_event` calls `audit.current_user_id()`, which is revoked from `semantius_user`: the request role cannot even `CREATE TEMP TABLE`. | `CREATE TEMP TABLE t(x int)` as user1: permission denied for function `current_user_id`. | Grant EXECUTE on `audit.current_user_id()` to `semantius_user`, and skip `pg_temp` objects in the event trigger. | user1 can create a temp table. |

Reviewed and found sound: `get_record_by_id` enforces the canonical predicate
(view_permission or the per-row `select_rule` function) and returns NULL
without leaking existence; all DD identifiers go through `%I`, enum lists and
unique-index predicates through `quote_literal`; FK/index/constraint names are
composed internally; the only raw interpolation in the DD engine is S1. pgmq
base tables are not readable by `semantius_user` and no pgmq function is
SECURITY DEFINER (the exposure is the wrapper RPCs, S4). RLS is enabled with
policies on every `public` table, all policies are `TO semantius_user`,
`_apikeys`/`_settings` are deny-all, views are `security_invoker`,
`user_bookmarks` confines to own rows. The JWT gate rejects empty `sub`, wrong
`role` and malformed claims and handles array/scalar audiences. API keys use a
128-bit secret with bcrypt cost 10. JsonLogic recursion and payload size are
unbounded, which the spec (I-jsonlogic) accepts as a residual DoS.

### Privilege facts from the catalog audit (extension install)

- All 75 `pgmq.*` functions are EXECUTE-able by PUBLIC and by `semantius_user`
  (`GRANT USAGE ON SCHEMA pgmq` at `0170:49`), and none of them pins
  `search_path`; test 0240 excludes the `pgmq` schema, so this is invisible to
  the suite. None is SECURITY DEFINER, and `semantius_user` cannot read the
  queue tables, so the practical exposure is limited to S4 and to information
  functions (`list_queues`, `metrics_all`, `list_topic_bindings`).
- `audit.log_ddl_event()` and `common.update_updated_at_column()` are
  EXECUTE-able by PUBLIC (harmless trigger functions, but inconsistent with
  every other schema).
- Default privileges grant `semantius_user` SELECT/INSERT/UPDATE/DELETE on
  every future table in `public` (`0050:259`): any table created outside the
  data dictionary is fully writable by the request role unless it gets RLS.
- `pg_extension.extconfig` is empty (B1).
- `GRANT USAGE ON SCHEMA common TO CURRENT_USER` (`0012:100`) is a test
  artefact shipped in the release.

---

## 2. Performance findings (measured)

All timings on the scratch server inside rolled-back transactions; the 100k
and 10k-row entities were ephemeral.

| ID | Severity | Where | Finding | Measurement | Change | Expected gain |
|---|---|---|---|---|---|---|
| P1 | **High** | `0070:313-362` (generated policies), `0145:251-270`, `0180:306-314,377-380`, `0150:585-610` | `USING (rbac.has_permission('x'))` stays a per-row `Filter`; only `USING ((SELECT rbac.has_permission('x')))` becomes an InitPlan evaluated once. The RBAC core tables already use the sub-select form (`0050:42-53`); 28 of 36 tables use the bare form. | `order_details` (2,155 rows) as user2: bare 33.8 ms / 8,644 buffers, sub-select 11.6 ms / 1,183 buffers. 100k-row entity: bare 1.66-1.91 s vs owner 5.4 ms. Point lookups unaffected. | Emit `((SELECT rbac.has_permission(%L)))` in the five generator sites and rewrite existing policies in a migration (`ALTER POLICY ... USING ((SELECT ...))` for every policy whose `pg_get_expr(polqual)` starts with `rbac.has_permission(`). | Full scans 1.66 s to about 10 ms; one `has_permission` call per statement instead of per row. |
| P2 | **High** | `0180:271-394` (`select_rule_<t>` policies), `0015` | The generated per-row function calls `ensure_context_initialized()`, builds `to_jsonb(row)` plus `$`-variables and runs `evaluate_json_logic`; opaque to the planner. | 100k rows, rule `col1 == 'x'`: 4.7-7.2 s (47-72 µs/row) vs native `col1 = 'x'` 17.7 ms. Components: `evaluate_json_logic` 51 µs, `ensure_context_initialized` 14 µs, `to_jsonb` 2.9 µs per row. | (a) Guard `ensure_context_initialized` behind `current_setting('app.context_initialized', true) IS DISTINCT FROM 'true'`; (b) compile the comparison/boolean subset of JsonLogic (`==,!=,<,<=,>,>=,in,and,or,!,!!` over `var`/constants/`$user_id`) to a native boolean expression in the policy, keeping the function as fallback; hoist `$user_id/$now/$today` into InitPlans. | (a) minus 25%; (b) 4.7 s to about 20 ms for compilable rules, and rule columns become indexable. |
| P3 | **High** | `0030:110-237` (`uid`), `:319`, `:538` | Every `has_permission` runs `rbac.uid()` twice (directly and inside `ensure_context_initialized`), and each `uid()` issues two SPI queries (`SELECT system_user INTO`, `_settings` read). | `has_permission` 26.6 µs per call, `uid()` 8.0 µs, `ensure_context_initialized` 14.4 µs, the actual cache check 0.4 µs; 6 buffer hits per call. Explains 21k `uid` calls for 9.5k `has_permission` calls in the suite. | Test `app.context_initialized` before calling `uid()`; drop the redundant `PERFORM rbac.uid()` in `has_permission`/`has_any_permission`; use `v := system_user` instead of `SELECT ... INTO`; cache the validated sub per transaction (must be combined with the S2 fix). | `has_permission` 26 µs to about 5 µs. |
| P4 | **High** | `0150:229-236` (audit), `0170:190-236` (queue), `0180` generated validators | Three FOR EACH ROW triggers each do statement-constant work per row (`primary_key_columns` catalog query, `pgmq.send` dynamic SQL, JsonLogic evaluation). | INSERT 10k rows: plain 65 ms; audit 1.5-2.0 s; queue 0.8-1.0 s; validation 0.7-1.1 s; all three 4.25 s (65x). Floors: set-based audit insert 497 ms, `pgmq.send_batch(10k)` 114 ms vs 10k `pgmq.send` 617 ms. | Statement-level triggers with transition tables: one `INSERT ... SELECT` for audit rows, one `pgmq.send_batch(queue, array_agg(...))` for queue events; build `$old`/`$now` only when the rule references them. | 4.25 s to about 1.0-1.3 s per 10k rows. |
| P5 | Medium | `0070:1391-1392`, `0145:1043-1074`, `:745-793` | Every `fields` insert triggers a full label-function rebuild and an `entities` UPDATE (usually a no-op value) that cascades into a dozen `entities` triggers and a `modules` UPDATE. | 30-field entity: 150 ms (5 ms/field); per 31 fields: 31 `rebuild_entity_label_functions`, 186 DDL events, 518 event-trigger firings, 253 NOTIFYs, 93 audit rows. | `UPDATE entities ... WHERE searchable IS DISTINCT FROM v`; skip the rebuild for fields that are neither reference/parent nor the label column (trigger WHEN clause); statement-level rebuild with transition tables for bulk inserts. | field insert 5 ms to about 1.5 ms; audit rows per field 3 to 1. |
| P6 | Medium | `0150:396` | `audit_ddl_logs.query_text` stores `current_query()`, which for a migration script is the whole script, once per DDL event. | 1,580 CREATE FUNCTION rows average 272 KB: 86 MB on disk, 69% of the scratch database. 19% of all DDL events are generated label-function churn. | `left(current_query(), 8192)` or a hash plus dedup table; skip GRANT/REVOKE/COMMENT events for generated label functions. | about 85% smaller `audit_ddl_logs`. |
| P7 | Medium | `rbac.uid`, `has_permission`, `has_any_permission`, `get_current_user_permissions`, `user_id`, `whoami`, `is_raci_actor`, `has_consultation`, generated `select_rule_*` | Declared STABLE but they write GUCs via `ensure_context_initialized`/`set_config`. The planner may evaluate them at plan time (side effects and a missing-JWT error during `EXPLAIN`/prepare), and their SQL sees the outer statement's snapshot (the workaround at `0080:96-99` exists because of this). Linter: 13 "STABLE but expression is VOLATILE" warnings. | `WHERE rbac.has_permission('x')` over 20k rows: 5 ms (hoisted) vs 532 ms row-dependent. | Keep STABLE (hoisting is desirable) but move the writes into one VOLATILE `rbac.normalize_claims()`/`ensure_context_initialized()` called from a single place; the STABLE readers only read. | removes plan-time side effects and the snapshot foot-gun. |
| P8 | Low | `0080` RPCs, `rbac.get_user_permissions`, `list_api_keys`, `require_*` | VOLATILE but read-only (8 linter warnings). PostgREST serves only STABLE/IMMUTABLE RPCs via GET in read-only transactions. | no CPU cost. | Label STABLE. | GET-able, read-replica routable. |
| P9 | Low | `0080:741-762`, `:681-724`, `:555-595`, `:198` | Per-entity loops with three SPI queries each; `get_module_cubes` re-selects the entity it iterates. | `get_user_cubes()` 20-39 ms for 15 entities; `get_schema` 1.9 ms each. | Fine at 33 entities; for more, one set-based query or a cache keyed on `modules.version`. | 1.3-2.6 ms/entity to about 0.3 ms at scale. |
| P10 | Low | `0020:269-328` | Redundant indexes: `users.external_id` has three, `permissions.permission_name`, `roles.role_name`, `roles.slug` two each; `user_roles(user_id)`, `role_permissions(role_id)`, `user_permissions(user_id)`, `permission_hierarchy(including)` duplicate the leading column of their composite unique index. No lookup lacks an index; the recursive permission CTE runs in 0.6 ms with index-only scans. | | Drop the duplicates. | fewer index writes. |
| P11 | Info | `0070:1254-1365` | Toggling `searchable` drops and re-adds a GENERATED STORED tsvector column plus GIN index: a full rewrite under ACCESS EXCLUSIVE. | 100k rows: 652 ms; linear (about 6.5 s per million rows); no overhead beyond PostgreSQL's own rewrite. | Document the lock; optionally defer to statement end so several toggles rewrite once. | |
| P12 | Info | generated `compute_validate_entities/fields/modules` | Metadata validation rules evaluate on every metadata write. | 934 evaluations per 31 field inserts (21.6 ms). | none; shrinks with P5. | |

Measured and fine: permission resolution CTE (0.6 ms, all joins indexed);
the cache lookup itself (0.4 µs); point lookups under any policy form
(0.14-0.26 ms); `get_schema_children` (0.09 ms); NOTIFY fan-out (37 µs each,
deduplicated per transaction); entity create (83 ms) and table rename (76 ms)
as admin operations; `pgmq.send_batch` at 11 µs per message.

---

## 3. Code-quality findings (plpgsql_check linter, 122 warnings on 63 functions)

| Kind | Count | Notes |
|---|---|---|
| security: "EXECUTE expression is SQL injection vulnerable" | 11 | pgmq `convert_archive_partitioned` L41/52/53 (real: `||` concatenation of `table_name`, upstream code, never called); the other 8 are `v_alter_sql`/`v_body` strings built with `format(%I/%L)`: safe except for the `%s` default path in S1. |
| error: `syntax error at or near "%I"` | 2 | `create_dd_table` L45, `enable_dd_table` L39: the linter tries to parse a `format()` template with `%I` placeholders; false positives, but they hide real errors in those functions from the linter. |
| performance: STABLE routine with VOLATILE expression | 13 | see P7. |
| performance: VOLATILE routine that could be STABLE/IMMUTABLE | 12 | see P8; plus pgmq `format_table_name`, `validate_queue_name`, `_get_partition_col`, `_validate_batch_params` (IMMUTABLE candidates). |
| performance: `SELECT expr INTO variable` | 16 | plain assignments would avoid SPI (`rbac.uid` L58, `rbac.user_has_permission` L30, `delete_dd_field` L10, ...). |
| warning: `target type is different type than source type` | 18 | implicit casts in `rename_dd_table` (6), `jl_to_number` (5), pgmq `read_*_with_poll`/`purge_queue` (4), `format_to_data_type`, `auto_set_order_value`. |
| extra: shadowed loop variable `i`/`j`/`v_idx` | 23 | `evaluate_json_logic` and the DD engine reuse loop variable names; harmless but the linter cannot check them. |
| extra: unused/never-read variables | 12 | e.g. `rename_dd_table`, pgmq `drop_queue` (`qtable_seq`, `fq_qtable`, `fq_atable`, `atable`), `queue_event_after_insert` (`v_trigger_name`). |

Two trigger functions could not be linted because no trigger uses them in a
fresh install: `pgmq.notify_queue_listeners()` and `raci_emit_trigger_fn()`.

---

## 4. Extension packaging and best practices

Experiments ran in throwaway databases on the scratch server (all dropped
afterwards): fresh install, plain dump/restore, naive and filtered
`pg_extension_config_dump` variants (via throwaway upgrade scripts), `DROP
EXTENSION` with and without dictionary-created tables, a second database on
the same cluster, non-`public` default schema and `SCHEMA other`, upgrade
from the real `v0.3.0` script, non-superuser install, event-trigger noise, a
LATIN1 database, and a database that already has a `pgmq` extension.

Baseline facts: `relocatable = false`, `superuser = true`, `requires =
'pgcrypto'`, no `schema`, `encoding` or `trusted` parameter; 0 occurrences of
`@extschema@`; `extconfig` NULL; members: 74 types, 270 functions, 52
relations (31 tables, 19 sequences, 2 views), 4 schemas, 3 event triggers;
the script has no `BEGIN`/`COMMIT`, no psql meta-commands, no nested `CREATE
EXTENSION`; 250 `COMMENT ON` statements and the control `comment` is applied
to the extension; `plpgsql.check_asserts` is on by default, so the `ASSERT`
guard is live unless someone turns it off.

| ID | Severity | Where | Finding | Evidence | Fix |
|---|---|---|---|---|---|
| B1 | **Critical** | `0160_pgmq.sql:79-87` (the only `pg_extension_config_dump` calls, guarded by `extname = 'pgmq'`, never executed) | `extconfig` is empty, so `pg_dump` omits the contents of all 31 member tables; a restore re-seeds the defaults and leaves dictionary-created physical tables (with their rows and `updated_at` triggers) as orphans without dictionary rows. | Fresh install + module/entity/user data, `pg_dump -Fc`, `pg_restore` (exit 0, no errors): modules 2 to 1, permissions 6 to 4, roles 3 to 2, entities 23 to 22, fields 235 to 230, users 1 to 0, user_roles 3 to 0, `_settings` 2 to 1, `_versions` 34 to 33, `modules_id_seq` 1001 to 1000, while the orphan `demo_items` table kept its 2 rows. | Emit a config-dump section (design below) in the full install and in the next upgrade script; document the restore procedure (B3). |
| B2 | **High** | `extension/pg_semantius.control` (no `schema =`); generator `extension.ts:495-513` | The extension is hard-pinned to `public` (104 functions `SET search_path = public`, 172 `public.`-qualified references, the `_versions` seed) but the control file does not declare it, so unqualified objects land in the installer's default schema and the install aborts. | `ALTER DATABASE ... SET search_path = myschema, public` then `CREATE EXTENSION`: `relation "roles" does not exist` in `grant_permission_to_administrator()` (script line 2385), nothing installed. `CREATE EXTENSION pg_semantius SCHEMA other`: identical error. | Emit `schema = public` in `buildControlFile`; PostgreSQL then forces the target schema and rejects `SCHEMA other` with a clear message. |
| B3 | **High** | `0040_rbac_seed.sql:58-61` (module FK back-references), `0030:938-968` (auto-grant trigger), `0070:255-300` (`create_dd_table` validation), users auto-role trigger | Even with correct config-dump filters a single-shot `pg_restore` fails: FK cycles `modules` to `permissions`/`roles` (pg_dump warns), and DML triggers fire during `COPY` (permission validation, admin auto-grant, first-role assignment). | Filtered dump, single-shot restore: 9 errors (`modules_manage_permission_id_fkey`, `check_permission_hierarchy_cycle`, `user_roles` duplicate key). Three-phase restore (`--section=pre-data`, `--data-only --disable-triggers`, `--section=post-data`): 0 errors, all 21 counters and 4 sequences identical to the source. | Document the three-phase restore; optionally honour a `pg_semantius.restoring` GUC in `create_dd_table`, `grant_permission_to_administrator`, the users role trigger and `audit.log_ddl_event` so a single-shot restore works. |
| B4 | Medium | `0160_pgmq.sql:11-21` | If the real `pgmq` extension is installed in the target database the install aborts at `CREATE TABLE IF NOT EXISTS pgmq.meta`. | `ERROR: table pgmq.meta is not a member of extension "pg_semantius"`. | Fail fast with a clear message at the top of 0160, or namespace the vendored copy; delete the dead guard at 79-87. |
| B5 | Medium | `0090:157-163`, `0150:387-409` | The three event triggers have no `WHEN TAG IN` filter and no schema/`in_extension` filter: `track_ddl_changes` logs 1,522 rows during the extension's own install, logs temp tables and unrelated schemas; `pgrst_*` NOTIFY on any DDL anywhere. | After `CREATE EXTENSION`: `audit_ddl_logs` = 1,522. `CREATE TABLE other.t`: NOTIFY `pgrst` + 2 audit rows. `CREATE TEMP TABLE`: 1 audit row (no NOTIFY). | `WHEN TAG IN (...)`; skip `in_extension` and `pg_temp` objects in `audit.log_ddl_event`; restrict to dictionary-managed schemas. |
| B6 | Medium | script lines 38-61, 74-80, 167-190; `extension/README.md:64-69` | `DROP EXTENSION` leaves the three cluster roles and their memberships (including `postgres` as member of `semantius_user`, from `GRANT semantius_user TO current_user`), two `ALTER DEFAULT PRIVILEGES IN SCHEMA public` entries, the `public` schema ACL and pgcrypto; once any dictionary-created table exists it refuses to drop without `CASCADE`, which strips that table's policies and triggers but keeps its data. | Fresh DB: drop succeeds; leftovers as listed. DB with `demo_items`: `cannot drop extension ... trigger update_demo_items_updated_at depends on common.update_updated_at_column(); 4 policies depend on rbac.has_permission(text)`; `CASCADE` leaves `public.demo_items` with 2 rows, 0 triggers, 0 policies. | Document an uninstall recipe; skip `GRANT ... TO current_user` under `CREATE EXTENSION`. |
| B7 | Medium | `.github/workflows/extension-release.yml:57-75`; `extension.ts:182-199` | The release workflow regenerates from the tag and ships that without proving it equals the committed, tested `extension/` and without running pgTAP; edits to released migrations only warn. | File review; the manual harnesses (`docker-postgres/build.sh`, `pgdocker/pg-ext-retest.sh`) exist but are not wired in. | `git diff --exit-code extension/` after generation; run the pgTAP suite (and the lifecycle script) before `gh release create`; a `--strict` generator mode that fails on edited or removed released migrations. |
| B8 | Medium | `extension/README.md`, `README.md:183-200`, `docker-postgres/README.md:25-28` | Missing for a public release: the third role `semantius_authenticator`, the GUC contract (`request.jwt.claims`, `request.jwt.claim.{sub,email,role,name,given_name,family_name,aud}`, `app.{current_user_id,user_permissions,oauth_scopes,current_external_id,context_initialized,bumping_module_version}`, `dd.table_rename`) and the `pgrst` NOTIFY channel, the backup caveat and restore procedure, upgrade details (older full installs are pruned, so `VERSION '0.3.0'` is impossible and there is no downgrade), the real PostgreSQL floor (the SQL needs 16: `system_user`, `GRANT ... WITH INHERIT FALSE, SET TRUE`; nothing in it needs 18), the `schema = public` requirement, event-trigger side effects, that default privileges bind to the installing role, the non-superuser error text. The shipped README also refers to `../pgdocker`, `deno task extension` and `apps/_core/migrations`, which mean nothing inside a PGXN distribution. | grep of the README vs. the GUCs the script reads. | Split `buildReadme` into a consumer README (install, upgrade, backup/restore, uninstall, roles, GUCs, PostgreSQL version) and keep maintainer notes in the repo README. |
| B9 | Low | control (no `encoding`); script lines 1627, 8147, 8259, 8278, 12542, 12622, 12679, 12737 | 136 non-ASCII lines, several in runtime string literals (the composed-label separator), with no `encoding = 'UTF8'`. | Install into a LATIN1 database succeeds with mojibake (`length = octet_length`). | `encoding = 'UTF8'` in the control (non-UTF8 databases then fail loudly) and/or `chr(8250)` for the separator. |
| B10 | Low | `extension/META.json:32`, generator `:555-577`, workflow `:65-72` | `git://` repository URL (GitHub no longer serves it), maintainer without email, no `release_status`, no `LICENSE`/`Changes` in the archive. | File review; the required Meta-Spec 1.0.0 keys are present. | `https://github.com/semantius/semantius.git`, maintainer email, `"release_status": "stable"`, copy `LICENSE` into the zip; validate META in CI. |
| B11 | Low | `0012:100` (script 302), `0050:14-19` (script 2457) | `GRANT USAGE ON SCHEMA common TO CURRENT_USER` is a no-op for the superuser owner; the BYPASSRLS `ASSERT` is redundant under `superuser = true` and a no-op if `plpgsql.check_asserts = off`. | | Strip both in the generator, or turn the assert into `RAISE EXCEPTION`. |
| B12 | Low | script 15-22 vs 14738; `pg_semantius--0.3.0--0.4.0.sql:12-19` | `_versions` is created unqualified and seeded as `public._versions`; a version-bump-only upgrade script still re-emits the `_versions` DDL. | | Resolved by B2; emit the block in upgrade scripts only when migrations were added. |
| B13 | Low | `extension/pg_semantius--0.4.0.sql` | The working-tree file has mixed CRLF/LF (`git ls-files --eol`: `i/lf w/mixed`); `docker-postgres/build.sh` bakes the working-tree file locally, CI bakes the LF blob. | | Normalise line endings in `renderBody`. |
| B14 | Info | `versions.json`, `pg_semantius--0.3.0--0.4.0.sql` | The upgrade path works: `CREATE EXTENSION ... VERSION '0.3.0'` (script from the git tag) then `ALTER EXTENSION UPDATE` yields exactly the object set of a fresh 0.4.0 install (403 `pg_describe_object` entries, identical hash); no downgrade path, as expected. | | Keep; document. |
| B15 | Info | `superuser = true` | Non-superuser install (database owner with CREATEDB, CREATEROLE, BYPASSRLS) fails with `permission denied to create extension "pg_semantius" / HINT: Must be superuser to create this extension.` | | Quote in the README. |

### Config-dump design (for B1/B3)

Seeded rows are identified by the reserved id ranges from
`0040_rbac_seed.sql:64-69` (`modules.id < 1000`, `permissions`/`roles.id <
10000`) and by well-known keys; conditions must be `public.`-qualified because
`pg_dump` runs with `search_path = pg_catalog`; every dumped table's sequence
is marked separately; the generator emits the calls as a final section of the
full install and of every upgrade script whose source version predates the
feature (existing installs only get `extconfig` through an upgrade).

| Table | Condition | Seeded rows |
|---|---|---|
| `public.modules` | `WHERE id >= 1000` | id 1 (`_core`) |
| `public.permissions`, `public.roles` | `WHERE id >= 10000` | ids 1-4 / 1-2 |
| `public.permission_hierarchy` | `WHERE including_permission_id >= 10000 OR included_permission_id >= 10000` | (2,1) |
| `public.role_permissions` | `WHERE role_id >= 10000 OR permission_id >= 10000` | 5 pairs |
| `public.entities` | `WHERE module_id >= 1000` | 22 core rows |
| `public.fields` | `WHERE table_name IN (SELECT table_name FROM public.entities WHERE module_id >= 1000)` | 230 core rows (add `OR ctype = ''` if custom fields on core entities must survive) |
| `public._settings` | `WHERE name <> 'db_version'` | `db_version` |
| `public._versions` | `WHERE name NOT LIKE '\_core.%'` | 33 `_core.*` guards; keeps `nwind.*`/`test.*` so `deno task migrate` does not re-run apps after a restore |
| `users`, `user_roles`, `user_permissions`, `_apikeys`, `dashboards`, `user_bookmarks`, `webhook_receivers`, `webhook_receiver_logs`, `processes`, `process_gates`, `queues`, `queue_table_events`, `raci_assignments`, `raci_events`, `audit_record_logs` | `''` | none |
| `public.audit_ddl_logs` | exclude until B5 lands (1,522 install rows, ids collide on restore) | |
| `pgmq.meta` | `WHERE queue_name <> 'raci_notify'` | user queues' `q_*`/`a_*` tables are non-members and dump normally |
| `pgmq.topic_bindings` | `''` | none |
| `pgmq.notify_insert_throttle`, `common._cache`, `pgmq.q_raci_notify`, `pgmq.a_raci_notify` | exclude | transient |
| sequences: `modules_id_seq`, `permissions_id_seq`, `roles_id_seq`, `users_id_seq`, `_apikeys_id_seq`, `dashboards_id_seq`, `user_bookmarks_id_seq`, `webhook_receivers_id_seq`, `webhook_receiver_logs_id_seq`, `processes_id_seq`, `process_gates_id_seq`, `queues_id_seq`, `queue_table_events_id_seq`, `raci_assignments_id_seq`, `raci_events_id_seq`, `audit_record_logs_id_seq` | `''` | without them a restore leaves `modules_id_seq` at 1000 and the next module collides |

Restore procedure to document (same extension version on both sides):
`pg_restore --section=pre-data`, then `pg_restore --data-only
--disable-triggers`, then `pg_restore --section=post-data`.

### Lifecycle script

The experiments above map onto a `pgdocker/pg-ext-lifecycle.sh` with these
steps: preflight (files, control), fresh install (extension row, empty audit
log, seeded counts, object signature), second database, schema pinning
(non-`public` search_path must install; `SCHEMA other` must fail with the
schema error), non-superuser install error text, dump plus three-phase
restore with sample data and an exact counter diff, upgrade from the previous
tag (object signature and `_versions` guards equal to a fresh install), drop
leftovers (fresh DB and DB with a dictionary table), event-trigger noise,
LATIN1 install, the pgTAP suite via `pg-ext-retest.sh`, cleanup. It is
proposed, not yet added (a new script is additive under the working
agreement, but it depends on decisions B2/B5/B9 for its expected results).

---

## 5. Tooling finding

| ID | Where | Finding | Fix |
|---|---|---|---|
| T1 (FIXED) | `0145_managed_enable.sql:793` and plpgsql_check `profiler.c` (`profiler_get_dyn_queryid`) | The plpgsql_check profiler re-evaluates every `EXECUTE` string expression once after the statement ran, to compute a query id, and parses the result. `EXECUTE 'DROP FUNCTION IF EXISTS ' || r.sig` drops the function first, so the second rendering of the `regprocedure` yields a bare OID and the profiler's own parse throws `syntax error at or near "<oid>"`, aborting 29 test files under `--coverage`. No server setting avoids it (`compute_query_id` off/on/regress, the fake queryid hook, versions 2.10.3 and 2.10.4 all fail). It is an upstream bug (side-effecting expressions are evaluated twice), reported below. | One-line rewrite in a new migration: `v_sql := 'DROP FUNCTION IF EXISTS ' || r.sig; EXECUTE v_sql;` (the re-evaluation of a plain variable is harmless). It is the only site in all migrations with this drop-then-render shape. |

---

## 6. Prioritised fix list

Released migrations are frozen, so every fix is a new migration (`0290_...`
onward) followed by `deno task extension 0.5.0`.

1. ~~S1 `quote_default_value` allow-list plus `%L` quoting; regression test with the injection payloads.~~ Done (with S13, T1 and the owner hardening; see "Fix status").
2. B1/B3 `pg_extension_config_dump` registration with seed filters and sequences (in the full install and the 0.4.0 to 0.5.0 upgrade script); documented three-phase restore; dump/restore lifecycle test.
3. B2 `schema = public` in the control file (one-line generator change; install currently fails outside `public`).
4. S2 unforgeable permission cache (also unlocks the P3 caching); S3 identity binding in `set_request_context`; S12 scope storage and delimiter.
5. S4 queue RPC authorization and clamps.
6. P1 sub-select policy form in the generators plus a one-off `ALTER POLICY` migration.
7. S5, S6, S7, S10, S11: grant/policy hygiene (one migration); widen guard test 0060 to `common`/`audit`, and 0240 to `pgmq` (pin `search_path` on the vendored functions or document the exception).
8. S8 bootstrap marker; S9 target-user check; B4 fail-fast when a real `pgmq` is installed.
9. T1 one-line rewrite (enables statement coverage without the scratch workaround).
10. B7 release workflow gates (diff check, pgTAP, strict generator); B8/B10 README and META; B9 `encoding = 'UTF8'`; B11/B12/B13 generator cleanups.
11. P3/P7 `uid()`/cache restructuring; P4 statement-level audit/queue triggers; P5 DDL fan-out; P6 DDL log size; P10 index cleanup; P8 volatility labels.
12. S13 quoting of rule `code`/`name`; S15 temp-table permission; B5/B6 event-trigger filters and uninstall recipe.

Tests that pin these findings are red against the current code, so they are
proposed here rather than added to the suite (see the Working agreement in
the plan). The passing tests added in this pass are listed in
`docs/pg_semantius-test-coverage.md`.

---

## Appendix A. Upstream bug report draft (plpgsql_check)

Title: profiler re-evaluates dynamic EXECUTE expressions after execution
(`profiler_get_dyn_queryid`), breaking statements whose expression depends on
state the statement changed.

Repro (PostgreSQL 18.6, plpgsql_check 2.10.4, any function `f` and table `t`):

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
`profiler_get_queryid` -> `profiler_get_dyn_queryid`, which runs
`profiler_plugin.assign_expr()` on the EXECUTE string expression a second
time (after the DROP) and `pg_parse_query()`s the result; the `regprocedure`
now renders as a bare OID and the parse fails inside the profiler. Any
expression with side effects (`nextval()`, `clock_timestamp()` in the SQL
text, `set_config`) is evaluated twice as well. Suggested fix: capture the
query string in `stmt_beg` (or from the executed statement's cached text)
instead of re-evaluating, and wrap the parse in `PG_TRY` so a profiler failure
never aborts the profiled function.

## Appendix B. How the numbers were produced

- Catalog audit: `pg_proc`/`aclexplode` for PUBLIC and `semantius_user`
  EXECUTE, `pg_class.relrowsecurity`, `pg_policies`, `pg_extension.extconfig`,
  `pg_event_trigger`, `pg_default_acl`, `proconfig` search_path check.
- Linter: `extensions.plpgsql_check_function_tb(oid, relid => <first bound table>, security_warnings => true, performance_warnings => true, extra_warnings => true, compatibility_warnings => true)` over all PL/pgSQL members of the extension.
- Performance: `EXPLAIN (ANALYZE, BUFFERS)` and `\timing` inside `BEGIN ... ROLLBACK` as owner or after `pgtap.authenticate_as('user2')`; per-call costs from `pg_stat_xact_user_functions` with `track_functions = all`; 100k/10k-row ephemeral entities created through the data dictionary.
- Coverage: `deno task test --coverage` (plpgsql_check profiler + `pg_stat_user_functions`), see `docs/pg_semantius-test-coverage.md`.
