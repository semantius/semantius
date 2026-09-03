# pg_semantius test coverage (first measurement)

Measured on 2026-09-02 with `deno task test --coverage` against a throwaway
`postgres:18` container (PostgreSQL 18.6, plpgsql_check 2.10.4) on which the
extension was installed with `CREATE EXTENSION pg_semantius CASCADE` and the
`nwind,test` apps were migrated on top (the "Path B" layout of
`pgdocker/pg-ext-retest.sh`). The migrate-installed layout (Path A) gives the
same function/statement numbers. Suite: 71 files, 1,840 assertions, all green.

How the numbers are produced is documented in `packages/cli/commands/coverage.ts`
and `README.md` (option `--coverage`). Reports: `coverage/summary.json`,
`coverage/uncovered.md`, `coverage/lcov.info` (mapped to
`apps/_core/migrations/<file>.sql` lines, so editor coverage gutters work).

> The first two measurements needed a one-line rewrite of
> `rebuild_entity_label_functions` (`0145_managed_enable.sql:793`, review
> finding T1) applied to the scratch database only; since the fix landed in
> the migration itself, `--coverage` runs the whole suite unmodified.

## Totals

| Metric | Value |
|---|---|
| Extension functions (PL/pgSQL + SQL, incl. DD-generated `_label`/`*_label`) | 292 |
| Functions called at least once by the suite | 144 (49.3%) |
| Never called | 148 (72 of them DD-generated label functions, 65 vendored pgmq) |
| PL/pgSQL statements executed | 1,590 / 2,151 (73.9%) |
| Extension tables read or written | 30 / 31 (only `pgmq.a_raci_notify` untouched) |

Semantius-authored, non-generated code alone (i.e. excluding `0160_pgmq.sql`
and the generated label functions): 132 of 141 functions called (94%),
1,553 of 1,855 statements executed (84%).

## Statement coverage by migration file

| Migration | Functions called | Statements executed |
|---|---|---|
| 0010_create_core.sql | 1/1 | 3/3 (100%) |
| 0012_create_cache.sql | 5/5 | 14/14 (100%) |
| 0015_jsonlogic.sql | 4/4 | 34/47 (72%) |
| 0020_rbac_schema.sql | 1/1 | 6/6 (100%) |
| 0030_rbac_functions.sql | 11/16 | 103/175 (59%) |
| 0050_rbac_rls.sql | 4/4 | 26/28 (93%) |
| 0060_dd_schema.sql | 3/3 | 11/12 (92%) |
| 0070_dd_functions.sql | 23/23 | 237/273 (87%) |
| 0080_public_functions.sql | 7/8 | 63/66 (95%) |
| 0090_notify_triggers.sql | 5/5 | 24/24 (100%) |
| 0110_apikeys.sql | 4/4 | 48/54 (89%) |
| 0140_dd_rename.sql | 4/4 | 84/92 (91%) |
| 0145_managed_enable.sql | 10/10 | 157/218 (72%) |
| 0150_audit_log.sql | 9/10 | 41/49 (84%) |
| 0160_pgmq.sql (vendored pgmq 1.11.1) | 10/75 | 37/296 (13%) |
| 0170_queue.sql | 8/11 | 42/58 (72%) |
| 0180_computed_validation.sql | 4/4 | 87/102 (85%) |
| 0190_user_name_claims.sql | 2/3 | 24/41 (59%) |
| 0210_raci.sql | 6/6 | 357/378 (94%) |
| 0230_entity_insert_defaults.sql | 2/2 | 6/6 (100%) |
| 0270_entity_order_column.sql | 2/2 | 25/26 (96%) |
| 0280_user_bookmarks.sql | 1/1 | 4/4 (100%) |
| 0282_module_version.sql | 2/2 | 23/31 (74%) |
| 0284_module_slug_provision.sql | 1/1 | 2/2 (100%) |

## Never-called functions that matter

Reachable by `semantius_user` (executable through PostgREST `/rpc` or from
inside RLS/trigger paths) and Semantius-authored:

| Function | File:line | Why it matters |
|---|---|---|
| `rbac.whoami()` | 0030:842 | dumps GUCs, claims and permissions; behaviour untested |
| `rbac.require_any_permission(VARIADIC text[])` | 0030:665 | authorization helper, both branches untested |
| `rbac.user_has_permission(text, text)` | 0030:422 | cross-user permission check incl. OAuth scopes |
| `rbac.validate_oauth_scopes(text, text)` | 0030:762 | scope intersection logic |
| `rbac.get_current_user_permissions()` | 0030:740 | cache reader |
| `rbac.set_request_context(text, text, text)` | 0190:187 | session-mode entry point; removed 2026-09-03 (release review S3) |
| `public.ping()` | 0080:608 | RPC without `rbac.uid()` |
| `public.queue_pop(text)`, `queue_archive(text,bigint)`, `queue_delete(text,bigint)` | 0170:382-437 | SECURITY DEFINER queue mutators (per-queue authorization added 2026-09-03, release review S4) |
| `audit.truncate_trigger()` | 0150:280 | TRUNCATE audit path |

Vendored pgmq (`0160_pgmq.sql`): 65 of 75 functions never run, including
`pop`, `archive`, `set_vt`, `purge_queue`, `metrics`, `list_queues`,
`read_with_poll`, `send_batch`, all `send_topic`/`bind_topic` routing and all
partitioning helpers. They are executable by every database role (see review
finding S-02), so their behaviour is part of the extension's exposed surface.

DD-generated label functions: 14 of 86 executed. `_label(rec <table>)` and
`<fk>_label(rec <table>)` are only exercised for a handful of entities
(`0370_test_composed_labels.sql`, `nwind/0020`, `nwind/0030`); the generator
itself (`rebuild_entity_label_functions`) is well covered (48/49 statements).

## Called functions with the lowest statement coverage

| Function | Statements | Branches | File:line | Uncovered lines |
|---|---|---|---|---|
| `apply_field_ddl` | 31/58 (53%) | 41% | 0145:24 | 27 |
| `jl_to_number` | 9/14 (64%) | 45% | 0015:18 | 4 |
| `delete_dd_field` | 15/23 (65%) | 80% | 0070:1083 | 8 |
| `update_dd_field` | 62/95 (65%) | 56% | 0145:359 | 33 |
| `quote_default_value` | 8/12 (67%) | 60% | 0070:163 | 4 |
| `bump_module_version_from_related` | 15/22 (68%) | 64% | 0282:65 | 7 |
| `rbac.uid` | 28/41 (68%) | 68% | 0030:110 | 13 |
| `jl_loose_eq` | 11/16 (69%) | 58% | 0015:66 | 3 |
| `rbac.has_any_permission` | 15/21 (71%) | 57% | 0030:600 | 6 |
| `add_dd_field` | 58/77 (75%) | 64% | 0070:522 | 19 |
| `rbac.has_permission` | 11/14 (79%) | 63% | 0030:529 | 3 |
| `build_record_logic_trigger` | 35/44 (80%) | 65% | 0180:29 | 9 |

Security-relevant uncovered paths inside these:

- `rbac.uid()` (0030:134-171): the Supabase-style `request.jwt.claims` JSON
  fan-out, the PG18 `system_user = 'oauth:...'` override, and the audience
  check variants (JSON array vs scalar) never execute. The suite only drives
  the Neon-style `request.jwt.claim.*` GUCs set by `authenticate_as()`.
- `rbac.has_permission()` (0030:542, 565, 573): the OAuth-scope intersection
  branch and the cache-miss path.
- `rbac.has_any_permission()` (0030:600): the scope-filtered branch.
- `update_dd_field()` / `apply_field_ddl()` / `add_dd_field()`: format-change
  paths (enum, reference/parent, numeric precision), default-value rewrites,
  unique-index toggles and the FK `reference_delete_mode` variants are only
  partly exercised.

## Structural gaps (zero occurrences in the suite)

- Identifier hardening: no entity or field is ever created with a name
  containing `"`, `;`, `--`, spaces, 63+ bytes or non-ASCII; the DD engine
  builds DDL dynamically (`create_dd_table`, `apply_field_ddl`,
  `rename_dd_table`, `build_select_rule_policy`).
- Event triggers (`pgrst_ddl_watch`, `pgrst_drop_watch`, `track_ddl_changes`)
  are exercised implicitly but never asserted on.
- `anon` / no-role sessions beyond `0390`; OAuth scopes (`app.oauth_scopes`).
- Large inputs (deep JsonLogic, huge enums, long text), DD failure mid-way.
- Extension lifecycle: `ALTER EXTENSION ... UPDATE`, `DROP EXTENSION`,
  non-superuser install, `CREATE EXTENSION ... SCHEMA x` (covered by the
  packaging review, not by pgTAP). `pg_dump`/`pg_restore` into a second
  database on one cluster is covered by `pgdocker/pg-ext-dump-restore.sh`
  since 2026-09-03; `0440` pins the `pg_extension_config_dump` registration.
- Ten files run as the RLS-exempt owner (`0015, 0060, 0130, 0180, 0200, 0240,
  0305, 0336, 0385, 0990`); their table accesses do not exercise policies.

## Tests added after the first measurement

| File | Closes |
|---|---|
| `0306_test_pgmq_operations.sql` | 28 vendored pgmq functions: send_batch, read_with_poll, set_vt, pop, archive/delete (array forms), purge_queue, metrics, list_queues, drop_queue, topic routing, insert-notify throttle |
| `0405_test_rbac_helpers.sql` | `rbac.has_any_permission`, `require_any_permission`, `user_has_permission`, `get_current_user_permissions`, `validate_oauth_scopes`, `whoami`, the OAuth-scope branches of `has_permission`, `public.ping` |
| `0410_test_uid_claim_paths.sql` | the Supabase-style `request.jwt.claims` blob path of `rbac.uid()` and the JSON-scalar audience form |
| `0440_test_config_dump.sql` | on the extension install: every member table and sequence is registered with `pg_extension_config_dump` or a documented transient, the seed filters keep the seeded rows out and everything else in, the conditions run under pg_dump's `search_path = pg_catalog`; on both installs: `pg_semantius.skip_audit` silences the three audit trigger functions in a superuser session |
| `0415_test_queue_rpc_mutators.sql` | `queue_pop`, `queue_archive`, `queue_delete` (admin path); since 2026-09-03 also `queue_authorize`, `queue_validate_permissions` and the `queue_read` clamps (release review S4: denied, view-only and manage paths for user1/user2) |
| `0420_test_audit_truncate.sql` | `audit.truncate_trigger` |
| `0435_test_bearer_context_bypass.sql` | `rbac.is_bearer_session`, `rbac.user_id_or_null`, the `permission_cache` row of `whoami`, `audit.current_user_id` and the generated compute/validate trigger deriving `$user_id` through rbac (release review S2). The bearer bypass itself is not reachable from pgTAP (`system_user` cannot be faked); it was verified once by running the suite with the detector forced on, see the review's Fix status. |
| `0445_test_policy_initplan_form.sql` | every RLS policy predicate calls `rbac.has_permission()` through a scalar sub-select (an InitPlan, evaluated once per statement) and never bare (once per row): a sweep of the installed catalog plus the generator paths `create_dd_table`, `update_entity_policies`, `build_select_rule_policy` (both branches) and `enable_dd_table` (release review P1) |

Still never called after these: 37 pgmq functions
(partitioning, unlogged queues, grouped reads, `detach_archive`, the remaining
`send`/`send_batch`/`send_topic` overloads), and 72 generated label functions.
`rbac.set_request_context` was on this list until its removal on 2026-09-03
(release review S3).

## Ratchet

| Date | Functions called | Statements | Assertions | Note |
|---|---|---|---|---|
| 2026-09-02 | 144/292 (49.3%) | 1,590/2,151 (73.9%) | 1,840 | first measurement, extension install |
| 2026-09-02 | 182/292 (62.3%) | 1,792/2,151 (83.3%) | 1,967 | after the five files above |
| 2026-09-02 | 182/292 (62.3%) | 1,797/2,152 (83.5%) | 2,007 | after the S1/S13 fixes, `0290_owner_hardening` and tests 0425/0430 |
| 2026-09-03 | 183/294 (62.2%) | not measured (plpgsql_check absent from the extension image on this run) | 2,018 | after the S2 bearer-session cache bypass and test 0435 (two new functions in the universe) |
| 2026-09-03 | 186/295 (63.1%) | not measured (plpgsql_check absent from the extension image) | 2,083 | after the P1 InitPlan policy form and test 0445; also includes 0440 and the 0415 additions made since the previous row |

Re-run `pgdocker/pg-ext-retest.sh --coverage` after adding tests and append a
row.

## Appendix: every function never called by the suite (after the five new files)

Generated from `coverage/summary.json` of the 2026-09-02 run (76 files). Tags: `[sql]` SQL-language function (counted through `pg_stat_user_functions`), `[definer]` SECURITY DEFINER, `[trigger]` trigger function.

Caveat: SQL-language functions that the planner inlines are never counted, so a few `[sql]` entries below are false negatives. `pgmq.list_notify_insert_throttles()` and both `pgmq.list_topic_bindings` overloads are called by `0306_test_pgmq_operations.sql` but inlined; the same may apply to the `_label` functions when they are used inside queries.

### pgmq (37)

- `pgmq._belongs_to_pgmq(table_name text)` — 0160_pgmq.sql:1121
- `pgmq._create_fifo_index_if_not_exists(queue_name text)` — 0160_pgmq.sql:1483
- `pgmq._ensure_pg_partman_installed()` — 0160_pgmq.sql:1302
- `pgmq._extension_exists(extension_name text)` [sql] — 0160_pgmq.sql:1291
- `pgmq._get_partition_col(partition_interval text)` — 0160_pgmq.sql:1276
- `pgmq._get_pg_partman_major_version()` [sql] — 0160_pgmq.sql:1311
- `pgmq._get_pg_partman_schema()` [sql] — 0160_pgmq.sql:1014
- `pgmq.convert_archive_partitioned(table_name text, partition_interval text, retention_interval text, leading_partition integer)` — 0160_pgmq.sql:1521
- `pgmq.create_fifo_index(queue_name text)` — 0160_pgmq.sql:1501
- `pgmq.create_fifo_indexes_all()` — 0160_pgmq.sql:1510
- `pgmq.create_partitioned(queue_name text, partition_interval text, retention_interval text)` — 0160_pgmq.sql:1320
- `pgmq.create_unlogged(queue_name text)` — 0160_pgmq.sql:1209
- `pgmq.detach_archive(queue_name text)` — 0160_pgmq.sql:915
- `pgmq.drop_queue(queue_name text, partitioned boolean)` — 0160_pgmq.sql:1024
- `pgmq.list_notify_insert_throttles()` [sql] — 0160_pgmq.sql:1701
- `pgmq.list_topic_bindings()` [sql] — 0160_pgmq.sql:1988
- `pgmq.list_topic_bindings(queue_name text)` [sql] — 0160_pgmq.sql:2005
- `pgmq.read_grouped(queue_name text, vt integer, qty integer)` — 0160_pgmq.sql:346
- `pgmq.read_grouped_head(queue_name text, vt integer, qty integer)` — 0160_pgmq.sql:244
- `pgmq.read_grouped_rr(queue_name text, vt integer, qty integer)` — 0160_pgmq.sql:125
- `pgmq.read_grouped_rr_with_poll(queue_name text, vt integer, qty integer, max_poll_seconds integer, poll_interval_ms integer)` — 0160_pgmq.sql:210
- `pgmq.read_grouped_with_poll(queue_name text, vt integer, qty integer, max_poll_seconds integer, poll_interval_ms integer)` — 0160_pgmq.sql:445
- `pgmq.send(queue_name text, msg jsonb, delay integer)` [sql] — 0160_pgmq.sql:693
- `pgmq.send(queue_name text, msg jsonb, delay timestamp with time zone)` [sql] — 0160_pgmq.sql:702
- `pgmq.send(queue_name text, msg jsonb, headers jsonb)` [sql] — 0160_pgmq.sql:684
- `pgmq.send_batch(queue_name text, msgs jsonb[], delay integer)` [sql] — 0160_pgmq.sql:794
- `pgmq.send_batch(queue_name text, msgs jsonb[], delay timestamp with time zone)` [sql] — 0160_pgmq.sql:803
- `pgmq.send_batch(queue_name text, msgs jsonb[], headers jsonb[], delay integer)` [sql] — 0160_pgmq.sql:812
- `pgmq.send_batch_topic(routing_key text, msgs jsonb[])` [sql] — 0160_pgmq.sql:2062
- `pgmq.send_batch_topic(routing_key text, msgs jsonb[], delay integer)` [sql] — 0160_pgmq.sql:2089
- `pgmq.send_batch_topic(routing_key text, msgs jsonb[], delay timestamp with time zone)` [sql] — 0160_pgmq.sql:2103
- `pgmq.send_batch_topic(routing_key text, msgs jsonb[], headers jsonb[])` [sql] — 0160_pgmq.sql:2075
- `pgmq.send_batch_topic(routing_key text, msgs jsonb[], headers jsonb[], delay integer)` [sql] — 0160_pgmq.sql:2117
- `pgmq.send_batch_topic(routing_key text, msgs jsonb[], headers jsonb[], delay timestamp with time zone)` — 0160_pgmq.sql:2024
- `pgmq.send_topic(routing_key text, msg jsonb, delay integer)` — 0160_pgmq.sql:1977
- `pgmq.set_vt(queue_name text, msg_ids bigint[], vt integer)` [sql] — 0160_pgmq.sql:1005
- `pgmq.set_vt(queue_name text, msg_ids bigint[], vt timestamp with time zone)` — 0160_pgmq.sql:981

### rbac (1)

- `rbac.set_request_context(p_external_id text, p_email text, p_oauth_scopes text)` [definer] — 0190_user_name_claims.sql:187 (removed 2026-09-03, release review S3)

### Generated label functions (created by the data dictionary per entity) (72)

- `public._label(rec audit_ddl_logs)` [sql]
- `public._label(rec audit_record_logs)` [sql]
- `public._label(rec categories)` [sql]
- `public._label(rec customers)` [sql]
- `public._label(rec dashboards)` [sql]
- `public._label(rec entities)` [sql]
- `public._label(rec fields)` [sql]
- `public._label(rec modules)` [sql]
- `public._label(rec permission_hierarchy)` [sql]
- `public._label(rec permissions)` [sql]
- `public._label(rec process_gates)` [sql]
- `public._label(rec processes)` [sql]
- `public._label(rec products)` [sql]
- `public._label(rec queue_table_events)` [sql]
- `public._label(rec queues)` [sql]
- `public._label(rec raci_assignments)` [sql]
- `public._label(rec raci_events)` [sql]
- `public._label(rec role_permissions)` [sql]
- `public._label(rec roles)` [sql]
- `public._label(rec shippers)` [sql]
- `public._label(rec suppliers)` [sql]
- `public._label(rec user_bookmarks)` [sql]
- `public._label(rec user_permissions)` [sql]
- `public._label(rec user_roles)` [sql]
- `public._label(rec users)` [sql]
- `public._label(rec webhook_receiver_logs)` [sql]
- `public._label(rec webhook_receivers)` [sql]
- `public.admin_permission_id_label(rec modules)` [sql]
- `public.assigned_by_label(rec user_roles)` [sql]
- `public.category_id_label(rec products)` [sql]
- `public.customer_id_label(rec orders)` [sql]
- `public.default_admin_role_id_label(rec modules)` [sql]
- `public.default_manager_role_id_label(rec modules)` [sql]
- `public.default_viewer_role_id_label(rec modules)` [sql]
- `public.employee_id_label(rec employee_territories)` [sql]
- `public.employee_id_label(rec orders)` [sql]
- `public.granted_by_label(rec role_permissions)` [sql]
- `public.granted_by_label(rec user_permissions)` [sql]
- `public.included_permission_id_label(rec permission_hierarchy)` [sql]
- `public.including_permission_id_label(rec permission_hierarchy)` [sql]
- `public.manage_permission_id_label(rec modules)` [sql]
- `public.module_id_label(rec dashboards)` [sql]
- `public.module_id_label(rec entities)` [sql]
- `public.module_id_label(rec permissions)` [sql]
- `public.module_id_label(rec processes)` [sql]
- `public.module_id_label(rec roles)` [sql]
- `public.order_id_label(rec order_details)` [sql]
- `public.permission_id_label(rec role_permissions)` [sql]
- `public.permission_id_label(rec user_permissions)` [sql]
- `public.process_id_label(rec process_gates)` [sql]
- `public.process_id_label(rec raci_assignments)` [sql]
- `public.process_id_label(rec raci_events)` [sql]
- `public.product_id_label(rec order_details)` [sql]
- `public.queue_id_label(rec queue_table_events)` [sql]
- `public.region_id_label(rec territories)` [sql]
- `public.reports_to_label(rec employees)` [sql]
- `public.role_id_label(rec raci_assignments)` [sql]
- `public.role_id_label(rec role_permissions)` [sql]
- `public.role_id_label(rec user_roles)` [sql]
- `public.ship_via_label(rec orders)` [sql]
- `public.supplier_id_label(rec products)` [sql]
- `public.table_name_label(rec fields)` [sql]
- `public.table_name_label(rec queue_table_events)` [sql]
- `public.table_name_label(rec webhook_receivers)` [sql]
- `public.target_role_id_label(rec raci_events)` [sql]
- `public.territory_id_label(rec employee_territories)` [sql]
- `public.user_id_label(rec user_bookmarks)` [sql]
- `public.user_id_label(rec user_permissions)` [sql]
- `public.user_id_label(rec user_roles)` [sql]
- `public.view_permission_label(rec dashboards)` [sql]
- `public.webhook_id_label(rec webhook_receiver_logs)` [sql]
- `public.webhook_receiver_id_label(rec webhook_receiver_logs)` [sql]

