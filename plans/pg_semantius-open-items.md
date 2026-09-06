# pg_semantius open items

One document, one list. Every open item is a row in the table below, sorted by
priority. When an item is fixed, delete its row; git keeps the history. IDs come
from the release review of 2026-09-02 and are never reused, so gaps (S1 to
S11, S13, S15, P1, P2, P3, P4, P6, P11, P12, P13, P14, B1 to B10, B12 to B16, B19, B20, B21,
Q1, Q4, Q7, R1 to R5, T1) mean fixed or dropped. The review, the readiness hand-off, and the separate blocker and
next-action lists that used to sit above the detail tables were retired on
2026-09-03; all of them are in git history under `plans/`.

S2, the client-writable permission cache, is solved for regular
configurations (PostgREST and app-server sessions, where the client never
runs SQL) and is deliberately not listed here. What remains of it applies to
PostgreSQL 18 OAuth bearer sessions only and is tracked in
`docs/bearer-mode-status.md`.

Last updated: 2026-09-06.

**Plan ownership is 1:1 from this side.** Every row is owned by at most one plan
under `plans/`, named in its Fix column; a plan may own several rows. A plan that
merely *touches* a row it does not own says so and does not claim it. P2 was
split on 2026-09-04 to hold this: its per-row context half became **P13**.
It was briefly numbered P11, an ID already taken by a row closed the same
day; renumbered 2026-09-05.

## Working agreement

- Nothing is released, and nothing that exists counts as a release. The
  0.3.0 and 0.4.0 extension builds were development snapshots: their version
  history (`extension/versions.json`, the 0.3.0 to 0.4.0 upgrade script) was
  discarded on 2026-09-03 and the manifest now holds only the current build.
  Fixes go into the original migrations; there are no upgrade scripts.
- **Every row deleted from this list is recorded in
  `plans/ext-solved-items.md`**, with its original text, what changed and what
  proves it. Deleting a row without adding it there is not allowed. For the
  0.5.0 rebuild batch that file also carries an independent audit of the
  claims: read it before assuming an item is shut, because B6, B10 and B11 came
  back **partial** and R2 is scope-changed rather than solved. R1 was also
  partial and was closed on 2026-09-04.
- The extension was rebuilt from scratch on 2026-09-03 as version 0.5.0 and
  is now a **thin installer**: `CREATE EXTENSION pg_semantius` creates only the
  cluster roles, the `semantius` schema and its functions, and
  `SELECT semantius.migrate()` installs the core schema as ordinary objects.
  Backup is a plain `pg_dump`, restore a single-pass `pg_restore`, and
  `DROP EXTENSION` causes no data loss. All three are proven by
  `pgdocker/pg-ext-lifecycle.sh` steps 1, 2 and 4; the item-by-item record is
  in `plans/ext-solved-items.md` and the shipped behavior is documented in
  `extension/README.md`. The design document was deleted on 2026-09-05 once
  its last live reference (R7) was made self-contained; it is in git history. The schema is `semantius`, not
  `pg_semantius`: PostgreSQL reserves the `pg_` prefix for system schemas.
- **B5, P6, S15 and R1 were one change** and were closed together on
  2026-09-04 (by a plan file since deleted; detail in `plans/ext-solved-items.md`):
  the DDL audit is scoped to the five
  Semantius schemas, `audit.log_ddl_event()` is `SECURITY DEFINER`,
  `query_text` is bounded to 8192 characters, and both `pgrst_*` watches carry
  the schema filter. Pinned by `apps/test/tests/0301_test_audit_ddl_scope.sql`
  (12 assertions) and `pg-ext-lifecycle.sh` step 11 (12 assertions, including
  the NOTIFY probe the pgTAP suite cannot run). What the change cannot reach is
  tracked as **S18**. Fresh installs only: `migrate()` never re-applies an
  applied migration, so an existing database keeps the old trigger.
- **P11 closed 2026-09-04.** `fields.searchable` toggles no longer rewrite the
  table when the generated expression is unchanged, and no longer rewrite it
  once per changed field row: the searchable triggers are statement-level with
  transition tables, and `update_search_vector_column` compares a fingerprint
  stamped into the `search_vector` column comment. A rewrite that is really
  needed still takes ACCESS EXCLUSIVE for the whole heap, now documented in
  `AGENTS.md`. Detail and evidence in `plans/ext-solved-items.md`; the residue
  it exposed is **S19**.
- **P3 closed 2026-09-05.** A warm `has_permission` no longer resolves the
  caller twice, and no longer enters a second PL/pgSQL frame to find out the
  context is already built: **17.9-19.4 -> 2.0 µs**, with
  `ensure_context_initialized` called once per transaction instead of once per
  check. Detail, method and the two things the owning plan asked for that were
  deliberately not done are in `plans/ext-solved-items.md`. It carried the
  separator half of **S12** with it, and `0060_test_security.sql` did **not**
  have to be weakened. No residue.
- **P13 and P4 closed 2026-09-05, both restated.** The audit and queue triggers
  are statement-level and the request context is resolved once per statement
  through an InitPlan: a 10k-row INSERT carrying all three triggers went
  **1.61 -> 0.70 s** (57%, measured both ways round in one transaction), and the
  generated rule predicate **20.95 -> 17.21 µs per row**. Neither row could be
  closed against its stated numbers - both were arithmetic on baselines that P3
  and P12 had already cut, and P4's 4.25 s does not reproduce on this hardware -
  so both were restated against re-measured endpoints. What P4 named and this did
  **not** solve: `evaluate_json_logic` still runs once per row and is now the
  largest remaining cost on the path, and `primary_key_columns` is still per row
  on UPDATE, where the audit trigger stays row-level by design. Detail, the
  accepted limitations and the residual left inside the validator are in
  `plans/ext-solved-items.md`. Residue: six statement-level trigger functions the
  linter cannot parse, tracked as **Q6** since 2026-09-05 (Q5 described them as
  false positives until it was re-linted that day).
- Every fix lands with its pinning test in the same change. The suite must
  stay green on both install layouts: `pgdocker/pg-cli-retest.sh` (migrate
  path) and `pgdocker/pg-ext-retest.sh` (`CREATE EXTENSION` path); add
  `--coverage` for the report in `docs/pg_semantius-test-coverage.md`.
- Regenerate the extension with `deno task extension <version>` and the
  `packages/*/migrations-bundle.ts` copies with `scripts/bundle-sql.ts`
  before anything ships.
- No commits without asking.
- **Q1 and Q4 closed 2026-09-05, Q2, Q3 and Q5 restated as pgmq-only.** Every
  plpgsql_check finding in our own code under the Q rows is gone: the two
  dictionary functions the linter could not parse now lint, the interpreter no
  longer shadows its own loop counter, and the dead variables, implicit casts
  and `SELECT expr INTO` sites are fixed. Nothing in the vendored `0160_pgmq.sql`
  was touched; what remains under Q2, Q3, Q5 and Q7 is upstream pgmq code. No
  lint gate was added, by decision: style warnings are not to fail builds.
  Record in `plans/ext-solved-items.md`.
- **B20 and B21 closed 2026-09-05.** Two strings compare as text in the four
  comparison operators, as the reference does, and `jl_to_number` no longer
  raises on a non-numeric, non-date string; it is also STABLE now, because its
  timestamp fallback follows `DateStyle`. Pinned by 21 corpus cases (290 to 311).
  Record in `plans/ext-solved-items.md`.
- **S5, S6, S9, S10 and S11 closed 2026-09-05**, together with three findings
  of the same shape that the plan's review turned up:
  `rbac.get_user_by_external_id` and `rbac.validate_oauth_scopes` got the S9
  guard, `rbac.validate_permission_exists` was revoked. The mechanism behind
  all of them: `ALTER DEFAULT PRIVILEGES ... REVOKE EXECUTE ON FUNCTIONS FROM
  PUBLIC` stores no catalog row and protects nothing, so only explicit revokes
  count. Record in `plans/ext-solved-items.md`.
- **S7 closed 2026-09-05.** `public.validate_api_key(text)` is revoked from
  `semantius_user` and PUBLIC, as its own header always claimed. It is an
  authentication primitive, so it cannot check an identity, and a grant would
  hand any session a bcrypt call at cost 10 and a timing oracle over which key
  ids exist. Guard test 2.2 loses its one hard-coded exception. Record in
  `plans/ext-solved-items.md`.
- **S8 closed 2026-09-05.** The first-user bootstrap is gated on "no user holds
  role 2", under an advisory lock, instead of on "no other user has a
  `last_seen`" - a heuristic that stayed true after the election whenever the
  administrator was pre-provisioned or its `last_seen` was cleared, so every
  later first login was elected too. The concurrency half of the pin is
  `pgdocker/pg-ext-lifecycle.sh` step 1e, which pgTAP cannot express. Paired with
  it, `rbac.assert_administrator_remains` refuses any statement that would leave
  no enabled holder of role 2, because the election fires on INSERT only and an
  established principal is therefore never elected however often it logs in; a
  BYPASSRLS connection is exempt. With that,
  `plans/security-grants-and-guards.md` is fully executed and owns no open row.
  Record in `plans/ext-solved-items.md`.
- **Q7 was accepted and closed 2026-09-05**: the vendored pgmq functions are
  unreachable from PostgREST and expose metadata only over a DB-only path
  (`plans/ext-solved-items.md`).
- **P12 closed 2026-09-05.** `evaluate_json_logic` no longer runs two SQL
  queries per node to read one JSON key, and no longer evaluates twelve dead
  `IF` statements before reaching an ordinary operator: **5.6-5.9 -> ~4.0 us per
  node, median 30.3%**. Closed at the lower edge of its 30-50% band on purpose -
  that band was an estimate, and what remains is not reachable by tuning the
  function. Detail, the two optimizations measured and declined, and where the
  floor is are in `plans/ext-solved-items.md`.
- **P2 closed 2026-09-05 as scope-changed, and reopened as P14.** The problem is
  confirmed, the prescribed fix was rejected. Measured on 100k rows: a scan under
  the shipped rule shape is **4,693 ms** interpreted against **7.9 ms** native and
  **1.1 ms** native-and-indexed, and an index on the rule column is *ignored*
  while the predicate is interpreted (4,204 ms with it present), so there is no
  cheaper mitigation. Two of the closed plan's assumptions did not survive
  measurement: the post-P13 baseline is ~4.7 s, not the 2.5-3 s it projected, and
  its "everything is paginated so only full scans hurt" argument is wrong - any
  sorted page or any page past the first costs ~3.2 s. The mechanism changed from
  recognizing generic rule *shapes* to adding **named operators**, because the
  equivalence-proof burden that dominated the old plan exists only for generic
  expressions. The plan that prescribed the rejected mechanism was deleted the
  same day; the four constraints P14 inherits from it live in
  `docs/jsonlogic-optimization-candidates.md`. Full
  record in `plans/ext-solved-items.md`; **B20** and **B21** were found while
  probing the coercion path for this decision.
- **P14 closed 2026-09-06 as postponed**, by decision. The problem is unchanged
  and unfixed: an entity with a `select_rule` degrades linearly and unboundedly
  with row count, and no index can mitigate it. It is postponed because nothing
  is slow today and no caller can reach it - `user_bookmarks` is the only entity
  that ships a rule, and it will not grow. Everything the row carried, including
  the measurements, the priority reasoning, the trigger that makes it urgent (the
  first `select_rule` on an entity that grows) and its definition of done, now
  lives in `docs/jsonlogic-optimization-candidates.md`, which is its sole record
  and already held the four constraints any implementation must respect. Closure
  record in `plans/ext-solved-items.md`.

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
| B11 | Low | migration | `0010:37`, `0012:104` (the CURRENT_USER grants), `0050:20` (the BYPASSRLS gate) | Partly fixed 2026-09-03: both grants are now skipped when the installing role is a superuser, and 0050's `ASSERT` became a `RAISE EXCEPTION` (no `ASSERT` statement survives in the generated script, asserted by `pg-ext-lifecycle.sh`). The row's first alternative - "neither reaches the generated script" - is still unmet: both grants are present at `pg_semantius--0.5.0.sql:242` and `:531`, only runtime-guarded. | Either drop the grants from the generated script entirely, or accept the runtime guard and rewrite this row's done-when. Add a test that the BYPASSRLS `RAISE EXCEPTION` actually fires and that a superuser install skips the grants. | The BYPASSRLS gate has a test that fails when it is removed, and the grant-skip is asserted on a superuser install. |
| P5 | Medium | migration | `0070` (`fields` triggers), `0145` (`rebuild_entity_label_functions`) | Every `fields` insert triggers a full label-function rebuild and an `entities` UPDATE (usually a no-op) that cascades into a dozen `entities` triggers and a `modules` UPDATE. 30-field entity: 150 ms (5 ms/field); per 31 fields: 31 rebuilds, 186 DDL events, 518 event-trigger firings, 253 NOTIFYs, 93 audit rows. | `UPDATE entities ... WHERE searchable IS DISTINCT FROM v`; skip the rebuild for fields that are neither reference/parent nor the label column (trigger WHEN clause); statement-level rebuild with transition tables for bulk inserts. **Owned by `plans/perf-volatility-and-trigger-cost.md`**, change 2: start with the two-line `IS DISTINCT FROM` guard and stop as soon as the target is met. The postponed named-operator work (`docs/jsonlogic-optimization-candidates.md`, formerly **P14**) would *add* about ten DDL events per field on rule-bearing entities (a three-arm `fields` trigger keeping the policies in step with the column), so account for that here if it is ever built. | About 1.5 ms per field (from 5 ms); audit rows per field 1 (from 3). |
| R7 | Low | tooling | `pgdocker/pg-ext-lifecycle.sh` | Four runtime assertions the script does not make, each belonging to another row and each needing no new infrastructure: the BYPASSRLS `RAISE EXCEPTION` in `0050_rbac_rls.sql` actually firing, and a superuser install skipping the CURRENT_USER grants (both **B11**); `0160_pgmq.sql`'s own header guard on the CLI path, which `migrate()`'s pre-flight currently pre-empts (**B4**); and a repeatable assertion for LF normalization, which today rests only on the release job's diff guard (**B13**). Split out of the old R7 on 2026-09-05, which mixed these with two much more expensive families now tracked as **R8** and **R9**. | Add the four assertions to the existing script. They run in the container that is already up, so they belong on the per-PR path with the rest of the lifecycle. | Each of the four fails when the behavior it asserts is removed. |
| R8 | Low | tooling | a new `pgdocker/pg-ext-portability.sh` | Two restore scenarios that need a **second container**, so they do not belong in `pg-ext-lifecycle.sh` on the per-PR path. (a) *Fresh cluster*: the step-2 dump restored into a second `postgres18-ext:local` without the init mounts - with `POSTGRES_USER=postgres` it should be clean and tests 0430, 0060, 0240 green there; with `POSTGRES_USER=admin` every error should match `role "postgres" does not exist`, `status()` should report the ownership and default-ACL drift and `harden()` should clear it. (b) *Dump taken after `DROP EXTENSION`*, restored on a fresh cluster: should fail only on role references, and succeed once `pg_dumpall --globals-only` has been applied first, with the `pg_auth_members` rows for the four roles equal to the source. Neither gates the three requirements, which lifecycle steps 1, 2 and 4 prove directly, and the in-principle case is now covered - step 5 (restore where the extension is not installed at all) landed 2026-09-05. | Write the script; run it from `extension-release.yml` only, not from `test.yml`, so a second container does not cost every contributor pull request. | Both scenarios asserted, green on a release tag. |
| R9 | Low | tooling | a new `pgdocker/pg-ext-upgrade.sh` | The `ALTER EXTENSION ... UPDATE` path, untested because **there has only ever been one version**: `extension/versions.json` holds `0.5.0-beta1` and nothing else, so there is no real upgrade to exercise and the test has to fabricate one. Three scenarios, all needing a generated `<v+1>` bundle built from a temp copy of `apps/_core` with a dummy migration appended plus a copy of `versions.json` (without it no upgrade script is written): (a) *upgrade* - `ALTER EXTENSION pg_semantius UPDATE`, then `pending()` returns exactly the dummy, `migrate()` applies only it, `version()` is `<v+1>`, and the function ACL checks of lifecycle step 8 still hold; (b) *cross-version* - the step-2 dump restored on the `<v+1>` server lists the dummy as pending, and a `<v+1>` dump restored on the `<v>` server has `pending()` empty with `status()` listing the dummy as unknown; (c) *failure atomicity* - a `<v+1>` bundle whose dummy fails midway makes `migrate()` raise with the migration name, the original SQLSTATE and message, leaves `_versions` unchanged, still lists the dummy as pending, and leaves no schema `common` on a fresh database. | Write the script; run it on the release tag. It is synthetic today and becomes load-bearing at the second release, which is the first time a real upgrade path ships - promote it to a hard gate then. | All three scenarios asserted, and the second release cannot be cut without them passing. |
| P7 | Medium | migration | `rbac.uid`, `has_permission`, `has_any_permission`, `get_current_user_permissions`, `user_id`, `whoami`, `is_raci_actor`, `has_consultation`, `public.jl_request_context`, generated `select_rule_*` | Declared STABLE but they write GUCs via `ensure_context_initialized`/`set_config`. The planner may evaluate them at plan time (side effects, a missing-JWT error during `EXPLAIN`/prepare) and their SQL sees the outer statement's snapshot (the workaround in `0080` exists because of this). 13 linter warnings. Hoisting is desirable: `WHERE rbac.has_permission('x')` over 20k rows is 5 ms hoisted vs 532 ms row-dependent. | Keep STABLE but move the writes into one VOLATILE `rbac.normalize_claims()`/`ensure_context_initialized()` called from a single place; the STABLE readers only read. **Owned by `plans/perf-volatility-and-trigger-cost.md`** (change 3). Settled there on 2026-09-06 as **option B**: the readers keep their lazy write, and no `rbac.begin_request()` is built. Making them pure needs something to build the context at the start of each request, and the primary deployment target - Neon's managed Data API - runs no code of ours per request and exposes no `db-pre-request`, so it would run permanently cold: about 1 ms per check instead of 0.025 ms, and per row wherever the interpreter's `has_permission` operator appears. What is left is a reproduction, re-scoping the one write that outlives its transaction (`0030:380`), and writing the contract down. `public.jl_request_context` is a member: it is STABLE and reaches `ensure_context_initialized` through `rbac.user_id()`, and it is called from every generated `select_rule` policy through an uncorrelated sub-select, so a plan-time evaluation would hit it too. This previously named the hot-paths plan as its owner, which does not and never did add a STABLE function - corrected 2026-09-05; that plan has since landed and been deleted. | Restated 2026-09-06 with the option-B decision: no plan-time side effects on any reachable path (`EXPLAIN` of a policy-guarded query without claims no longer raises), and `app.bearer_cache_notice` no longer outlives its transaction. The 13 linter warnings are **accepted, not fixed** - the readers keep their lazy write, because Neon's Data API has no per-request seam to build the cache from. The `0080` workaround stays: it is a snapshot problem, not a volatility one. |
| P9 | Medium | migration | `0080_public_functions.sql` (`get_user_cubes`, `get_module_cubes`, `get_schema`) | Per-entity loops with three SPI queries each; `get_module_cubes` re-selects the entity it iterates. Measured 2026-09-06 on the live 33-entity database, warm, as an Administrator who sees every entity: `get_user_cubes()` **28.7-29.8 ms** (85 ms cold), which is **0.87 ms per entity**, effectively all of it inside `build_schema_for_table`; `get_schema` 1.8 ms warm. The shape is a per-entity loop so the warm cost should scale linearly, but that is inferred from one entity count, not measured across two. Fine at 33 entities, and the owner confirmed on 2026-09-06 that **250 entities - about ten real modules - is the realistic high end in production**, where the warm call would cost about 220 ms. The cold figure (85 ms at 33) does not extrapolate from a single point and is unmeasured at scale. | A cache keyed on `modules.version`, not the set-based rewrite: at the target scale a set-based version still rebuilds every schema per call, while the cache makes the call independent of the entity count and also removes the cold cost a rotating connection pool pays repeatedly. It may not leak: populate it on the version bump rather than on a read, cache only the permission-invariant part, and re-run `build_schema_for_table`'s per-caller gate (`0080:231`) on every read. `modules.version` does not move on a `fields` change today - only as a side effect of a no-op `UPDATE entities` that change 2 removes - so an explicit `fields` bump trigger lands first (decided 2026-09-06); it is a correctness fix for every consumer of that version, not only for this cache. Measure first how much of the 0.87 ms is that gate rather than the building - if the gate dominates, the cache buys little and the per-entity checks are the target instead. `get_module_cubes` re-selecting the entity it already iterates (`0080:712-714`) is separable and can be fixed on its own. **Owned by `plans/perf-volatility-and-trigger-cost.md`** (change 5). | `get_user_cubes()` under about 30 ms warm at 250 entities - an absolute target, not a per-entity one, because the chosen fix is meant to make the call independent of the entity count - with `build_schema_for_table`'s per-caller gate still enforced on every read. |
| P8 | Low | migration | `0080` RPCs, `rbac.get_user_permissions`, `list_api_keys`, `require_*` | VOLATILE but read-only (8 linter warnings). PostgREST serves only STABLE/IMMUTABLE RPCs via GET in read-only transactions. | Label STABLE. **Owned by `plans/perf-volatility-and-trigger-cost.md`** (change 4), which establishes that every function named here reaches `set_config` through `rbac.uid`/`has_permission` - `rbac.get_user_permissions` included, through the self-or-admin guard at `0030:821-828`. There is no member that can be labeled before P7 is settled, so this row is blocked on it. | The 8 warnings are gone; the RPCs answer GET. |
| P10 | Low | migration | `0020_rbac_schema.sql` (indexes) | Redundant indexes: `users.external_id` has three, `permissions.permission_name`, `roles.role_name`, `roles.slug` two each; `user_roles(user_id)`, `role_permissions(role_id)`, `user_permissions(user_id)`, `permission_hierarchy(including)` duplicate the leading column of their composite unique index. Nothing lacks an index; the recursive permission CTE runs in 0.6 ms with index-only scans. | Drop the duplicates, enumerating them from the catalog rather than from this row. **Owned by `plans/perf-volatility-and-trigger-cost.md`** (change 1). | The duplicates are gone; the permission CTE still uses index-only scans. |
| Q2 | Low | migration | `0160_pgmq.sql` (`_belongs_to_pgmq`, `convert_archive_partitioned`, `create_partitioned`) | 3 `SELECT expr INTO variable`, all in the vendored pgmq v1.11.1 code. The 14 Semantius sites were converted to assignments on 2026-09-05 (`plans/ext-solved-items.md`); the count is from a re-lint that day, not decremented. | Leave the vendored file byte-identical to upstream. Either accept and delete this row, or re-vendor from an upstream release that has fixed them. | The decision is recorded, or the vendored copy no longer reports them. |
| Q3 | Low | migration | `0160_pgmq.sql` (`read_with_poll`, `read_grouped_with_poll`, `read_grouped_rr_with_poll`, `purge_queue`) | 4 implicit casts, all vendored pgmq. The 15 Semantius casts were made explicit on 2026-09-05. | As Q2. | As Q2. |
| Q5 | Low | migration | `0160_pgmq.sql` (`drop_queue` (4), `create_non_partitioned`/`create_partitioned`/`create_unlogged` (`qtable_seq`), `_belongs_to_pgmq`, `_get_partition_col`, `convert_archive_partitioned`, `detach_archive`, `pop`, `set_vt`) | 13 unused or never-read variables and parameters, all vendored pgmq. The six Semantius ones were removed on 2026-09-05. Recorded invocation: plpgsql_check 2.10, `extensions.plpgsql_check_function_tb(oid, relid => <bound table or 0>, security_warnings => true, performance_warnings => true, extra_warnings => true, compatibility_warnings => true)` over every PL/pgSQL function in `public`, `rbac`, `audit`, `common`, `pgmq`. The "six transition-table false positives" this row used to describe do not occur under that invocation: those functions abort the linter instead and are Q6. | As Q2. | As Q2. |
| Q6 | Low | tooling | `raci_emit_trigger_fn()`; `audit.insert_trigger`, `audit.delete_trigger`, `handle_field_searchable_insert/update/delete`, `queue_build_record_json`; pgmq `notify_queue_listeners()` | Seven Semantius trigger functions the linter never sees: `raci_emit_trigger_fn` because no trigger binds it in a fresh install, and the six statement-level trigger functions because plpgsql_check 2.10 stops at `relation "new_rows" does not exist` when no transition table is declared for the check. `pgmq.notify_queue_listeners` is vendored and unbound. | Bind `raci_emit_trigger_fn` in a test. For the six, pass `oldtable`/`newtable` to `plpgsql_check_function` (the arguments exist for this case; untried here), or accept and say so. | All seven appear in the lint report, or the acceptance is written into this row. |
| R6 | Low | tooling | `semantius-cov-scratch` (port 5439) | Scratch container from the review measurements is still running. | `docker rm -f semantius-cov-scratch` when no longer needed. | Container gone. |
| S12 | Low (DB) | migration | `0030_rbac_functions.sql` (`has_permission`, `has_any_permission`, `user_has_permission`) | `app.oauth_scopes` is a client-settable GUC: a scoped session can clear its own confinement. There is no definer entry point for scopes since `set_request_context` was removed. **The delimiter half is done (2026-09-05).** Separators are normalized rather than unified: any run of commas or whitespace separates, in all three GUC readers and in `validate_oauth_scopes`' request parameter, so `"a,b"`, `"a b"` and `" a ,, b "` are the same two scopes. That is stronger than the "one delimiter everywhere" the design asked for - it needs no writer to have normalized first, and it stays correct when `set_request_scopes` later normalizes on write. It cannot escalate: scopes only subtract, the permission is matched against the caller's own set before the scope test runs. Pinned by `0405` GROUP 6. | Store scopes inside the signed cache planned in `docs/bearer-mode-status.md`; a self-only `rbac.set_request_scopes(p_oauth_scopes)` with a narrow-only rule, see that document, step 5. The delimiter clause of that step is satisfied. | A scoped session that clears the GUC or calls the entry point with a wider list still has the scoped-out permission denied. |
| S16 | Low | migration | `entities.view_permission`/`edit_permission`, `modules.view_permission`, `queues.view_permission`/`manage_permission` | Permission names are stored as text, validated on save only, no foreign key. Deleting a permission that is still named leaves a dangling name that fails `has_permission` for everyone, admins included (fails closed). The UI renders these as plain text boxes because it keys on format, not on field name; `dashboards.view_permission` and `modules.manage_permission_id`/`admin_permission_id` are references and get the picker. Decision 2026-09-03: keep text for now; converting all of them touches the policy generators and the schema RPCs and needs its own plan. | Interim: a before-delete trigger on `permissions` that refuses to remove a name still used by an entity, module or queue. Later: convert to references. | Deleting a permission named by an entity raises. |
| S17 | Low | migration | `0050_rbac_rls.sql` (default privileges) | Default privileges grant `semantius_user` SELECT/INSERT/UPDATE/DELETE on every future table in `public`: any table created outside the data dictionary is fully writable by the request role unless it gets RLS. Documented as a behavior in `SECURITY.md` since 2026-09-03; dictionary tables always get RLS. | Decide: keep, or narrow the default and grant explicitly from `create_dd_table`. | A table created by hand in `public` is not writable by user1 (if narrowed), or the decision to keep is recorded here and the row deleted. |
| S18 | Low | migration | `0150_audit_log.sql` (`audit.log_ddl_event`, `track_ddl_changes`) | What the 2026-09-04 scoped audit cannot see. (a) `GRANT`/`REVOKE` events arrive from `pg_event_trigger_ddl_commands()` with NULL `classid`, `objid`, `schema_name` **and** `object_identity` (verified live), so they can be neither scoped to a schema nor recognized as generated-label churn: 766 of the 2156 rows a full migrate leaves, 36%, identify no object. They were kept rather than dropped, because dropping them would discard the privilege history the table exists for - but on the extension path their `query_text` is only `SELECT semantius.migrate()`, so there they carry nothing at all. (b) `WHEN TAG IN (...)` is an allowlist on an evidence table: a DDL kind nobody enumerated (`CREATE STATISTICS`, `ALTER ROUTINE`, text-search configurations, `IMPORT FOREIGN SCHEMA`) is silently unaudited, and nothing tests that the list is still complete. None is emitted by any migration today. (c) `CREATE SCHEMA` reports a NULL `schema_name`, so creating a schema is always logged and always fires `NOTIFY pgrst`, foreign schemas included. | (a) accept and document, or record the grant target from the DDL text; (b) decide between the allowlist and auditing every tag, and if it stays, a test that fails when a new tag appears in the migrations without being listed; (c) accept. | Each of the three is either fixed or recorded here as a deliberate limitation, and the row deleted. |
| S19 | Low | migration | `0290_owner_hardening.sql` (the `pg_proc` ownership loop) | The loop that runs `ALTER FUNCTION ... OWNER TO semantius_owner` has no `ORDER BY`, and the DDL audit event trigger fires on every statement it issues. `audit.log_ddl_event()` is SECURITY DEFINER and calls `audit.current_user_id()`, which 0150 revokes from PUBLIC: the moment `log_ddl_event` changes owner it starts running as `semantius_owner`, and if `current_user_id` has not moved yet the migration dies on `log_ddl_event`'s own ALTER with `permission denied for function current_user_id`. Which of the two moves first is `pg_proc` heap order, so adding or removing any function anywhere in the codebase can flip it - it flipped on 2026-09-04 when P11 added three, and a clean tree migrated fine minutes earlier. Fixed by granting EXECUTE on `audit.current_user_id()` to `semantius_owner` before the loop, which grants nothing the end state lacks since that role owns the function seconds later. | Residue: the loop is still order-dependent for any future SECURITY DEFINER function that calls a PUBLIC-revoked helper during DDL, and nothing detects it until an install fails. Either order the loop explicitly, or remove the event trigger's dependency on a revoked function. | A new SECURITY DEFINER function calling a PUBLIC-revoked helper cannot break 0290, by test or by construction. |
| B17 | Low | extension | `extension.ts` (`pruneOldFullInstalls`), `extension-release.yml` (packaging step) | An upgrade script whose endpoints are no longer in `versions.json` survives regeneration and is shipped. `pruneOldFullInstalls` deliberately keeps anything with a second `--` (`if (mid.includes("--")) continue;`), and the packaging step globs `cp extension/pg_semantius--*.sql`, so the archive can offer PostgreSQL an `ALTER EXTENSION ... UPDATE` path that the manifest knows nothing about. Verified by dropping a fabricated `pg_semantius--0.4.0--0.5.0.sql` into a copy of `extension/` and regenerating: the stale full install was removed, the orphan survived. Latent today - the 2026-09-03 manifest wipe is exactly how one is created. | Prune upgrade scripts whose `<from>` or `<to>` is absent from the manifest, or package from the manifest instead of a glob. | An orphaned upgrade script is deleted by the next generation, or never reaches the archive. |
| B18 | Low | tooling | `packages/*/src/migrations-bundle.ts`, `scripts/bundle-sql.ts`, `.gitignore:149` | The three bundle copies are generated by hand (`RELEASE.md` asks for it) and nothing verifies them. `packages/triggerdev/src/migrations-bundle.ts` is **tracked** despite being ignored, and is stale: it still holds the pre-P11 row-level `handle_field_searchable_change` trigger and lacks 0290's `GRANT EXECUTE ON FUNCTION audit.current_user_id()`. The other two are untracked. The release workflow's porcelain guard is scoped `-- extension/` and cannot see any of this. | Decide whether the bundles are build output (untrack all three, generate on demand) or artifacts (track all three, regenerate in the release flow and extend the porcelain guard to cover them). | The tracked copy either matches a fresh `bundle-sql.ts` run or is not tracked. |
| T2 | Low | tooling | plpgsql_check upstream | The profiler bug in Appendix A is worked around in `0145` but not reported. | File the report. | Issue link recorded here, then delete the row. |
| S14 | Info | migration | `0030_rbac_functions.sql` (`rbac.uid`) | In session mode the request role controls `request.jwt.claim.*`; `system_user` pins the identity only for PG18 `oauth:` sessions; without a `jwt_aud` row in `_settings` the audience is not enforced. This is the trust model, documented in `SECURITY.md` (2026-09-03). | Require `jwt_aud`; link the policy from the consumer README (B8). | A missing `jwt_aud` row refuses `uid()` (today only a mismatched `aud` raises, tests 0250 and 0410). |

Linter context for the Q rows: plpgsql_check reported 122 warnings on 63
functions at the review. Re-linted 2026-09-05 with the invocation recorded in
Q5: 131 findings, 99 of them outside `pgmq`. After the same-day sweep of our
own code (Q1 and Q4 closed, the Semantius halves of Q2, Q3 and Q5 done; record
in `plans/ext-solved-items.md`) the linter reports 40 outside `pgmq`, none of
them a Q kind: 23 STABLE/VOLATILE (P7, P8), 8 `format(%I/%L)` sites it calls
unsanitized (S1 audited every dynamic-SQL site), 2 dynamic-SQL results it
cannot type, and the 7 unlinted trigger functions in Q6. The 11 "EXECUTE
expression is SQL injection vulnerable" warnings from the review are closed (S1
fixed). The 32 `pgmq` findings are untouched and are Q2, Q3 and Q5; the 75 grant and
search_path warnings on the same functions were accepted with Q7. There
is deliberately no lint gate in CI: the owner does not want style warnings
failing builds.

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
