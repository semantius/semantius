# Performance and volatility: P5, P7, P8, P9, P10

Owner of the five remaining `P` rows in `plans/pg_semantius-open-items.md` -
**P5**, **P7** and **P9** (Medium; P9 was re-graded from Low on 2026-09-06, see
change 5) and **P8**, **P10** (Low). Written 2026-09-06,
after **P14** was closed as postponed and its record moved to
`docs/jsonlogic-optimization-candidates.md`. No other `P` row is open, and these
three are the only Medium rows left on the list; P8 and P10 are Low and are here
because they are `P` rows, not because of their priority.

Facts below were read on 2026-09-06 from the migrations in
`apps/_core/migrations`. **Only P9 has been re-measured** (2026-09-06, recorded
under change 0); every other number is quoted from the 2026-09-02 release review,
and several of those baselines have already been cut since by P3, P11, P12 and
P13. Change 0 exists because of that.

Sections end with a question where the answer is not mine to make. The project
rule is that nothing touching data safety, security or operability is decided by
an agent alone, and P7 is squarely inside that rule. **The owner answered
change 3's and change 5's questions on 2026-09-06**; the answers are recorded in
place and the executing session works from them rather than reopening them.

## Change 0: re-measure before anything is touched

Four of the five rows are graded on numbers from a schema that no longer exists.
P3 took a warm permission check from 17.9-19.4 us to 2.0 us, P13 moved the
request context to one resolution per statement, P11 made the searchable
triggers statement-level, and P12 cut the interpreter by 30%. P5's "5 ms per
field" and P7's "5 ms hoisted vs 532 ms row-dependent" both predate all four.

Before any fix, re-run the three measurements on `postgres18-cli`, inside
rolled-back transactions, by the method in Appendix B of the open items:

1. **P5**: insert a 30-field entity and count wall time, audit rows, DDL events
   and NOTIFYs per field.
2. **P7**: `WHERE rbac.has_permission('x')` over a 20k-row table, hoisted and
   row-dependent, and the same query through an RLS policy.
3. **P9**: `get_user_cubes()` and `get_schema()` at the installation's current
   entity count, **cold and warm, at two different entity counts** - the cold
   figure below does not extrapolate from one point.
4. ~~**P7's cold path** at 250 entities, warm and cold.~~ **Dropped
   2026-09-06.** It was added to gate the choice between option A and option B.
   Option B is chosen and keeps the cache on every path that has a seam, so
   nothing gates on this number. The cold cost is still what a bearer session
   pays, and that is already measured in `docs/bearer-mode-status.md:99-104`.

Record the results in this file before editing SQL. If a row no longer
reproduces, it closes as fixed-by-something-else with a dated section in
`plans/ext-solved-items.md`, not silently.

### Measured 2026-09-06: P9

`postgres18-cli`, live `appdb`, **33 entities**, in a rolled-back transaction as
`semantius_user` with `request.jwt.claim.sub = user3` (Administrator, so every
entity is visible and none is skipped by the permission test):

| Call | Cold (first in the backend) | Warm |
|---|---|---|
| `get_user_cubes()` | 85 ms | **28.7 / 29.8 ms** |
| `build_schema_for_table()` over all 33 entities | 34.6 ms | 28.3 ms |
| `get_schema('users')` | 10.1 ms | 1.8 ms |

Two things follow, and one caveat.

**Warm, the cost is `build_schema_for_table`**: running it directly over all 33
entities costs what the whole of `get_user_cubes` costs (28.3 vs 28.7 ms), so
the wrapper adds nothing measurable and any fix has to be in the per-entity work
or in not repeating it. And **it is linear at about 0.87 ms per entity** warm,
which is the number to extrapolate the warm path with.

**The caveat: the cold figures do not support an extrapolation.** Cold,
`get_user_cubes` costs 85 ms against `build_schema_for_table`'s 34.6 ms - a 50 ms
gap that is *not* explained by the per-entity work, and nothing here says whether
it is a fixed per-backend plan-compilation cost or itself per-entity. The "about
280 ms cold at 250 entities" figure in change 5 assumes fixed. **Measure the cold
path at two entity counts before relying on it**; if the gap scales, the cold
number is far worse than 280 ms.

---

## The mechanism behind P7 and P8

`STABLE` is a promise to the planner, and PostgreSQL takes it up in a place that
is easy to miss: `estimate_expression_value()` folds `STABLE` calls - not only
`IMMUTABLE` ones - while estimating selectivity, so a `STABLE` function with
constant arguments can be **executed by the planner**, before the executor
starts. Anything it writes is written then; anything it raises aborts planning
rather than execution. That is why P7's "done when" is phrased as `EXPLAIN` of a
policy-guarded query no longer raising.

Where that folding reaches is narrow, and it decides how much work P7 is: the
estimators look at the non-`Var` side of a restriction clause, at `LIMIT`/`OFFSET`,
and at pattern and array estimation. The foldable shape is
`col <op> stable_fn(<const>)`. A bare boolean call used as a qual falls to a
default selectivity un-evaluated, and a targetlist entry is never estimated at
all. Change 3 step 1 establishes whether any instance of that shape exists here.

The snapshot half of P7's row is a *different* complaint and should not be
conflated with this one: planning does run under a snapshot. What a `STABLE`
function cannot see is a row written earlier inside the same enclosing function
call, because it reads the calling statement's snapshot - which is exactly what
the comment at `0080_public_functions.sql:96-99` says, and why the workaround
there exists. No volatility change fixes that, which is why P7 closes with that
clause unmet.

The functions and the writes themselves are listed under change 3.

---

## Change 1: P10, the redundant indexes

**Smallest, independent of everything else, and first.**

What is true today in `0020_rbac_schema.sql`: `users.external_id` carries a
`UNIQUE` constraint (`:151`) *and* `idx_users_external_id` (`:294`);
`permissions.permission_name` (`:83`, `:269`), `roles.role_name` (`:96`, `:276`)
and `roles.slug` (`:97`, `:328`) are the same pattern. Four more duplicate the
leading column of a composite unique constraint: `idx_user_roles_user` (`:303`)
under `UNIQUE (user_id, role_id)` (`:171`), `idx_role_permissions_role` (`:278`)
under `:183`, `idx_user_permissions_user` (`:286`) under `:195`, and
`idx_permission_hierarchy_including` (`:311`) under `:212`.

### The three indexes on `users.external_id`, and which one survives

Confirmed on the live database, `\d users`:

| Index | Built by | Shape |
|---|---|---|
| `users_external_id_key` | the `UNIQUE` on the column, `0020:151` | total unique |
| `idx_users_external_id` | `0020:294` | plain btree, redundant against either unique index |
| `users_external_id_unique` | the data dictionary, `0070:1059-1078`, because `0190:15` sets `unique_value = TRUE` | **partial** unique: `WHERE external_id IS NOT NULL AND external_id <> ''` |

`users` is not a dictionary-built table: it is a hand-written `CREATE TABLE` at
`0020:149-159`, forty migrations before the dictionary exists, and is *registered*
as an entity later at `0060:380`. The third index exists because `0190:15` set the
flag to *describe* the constraint and the dictionary read it as an instruction to
*build* one.

**Done 2026-09-06.** `users.external_id` now carries exactly one index, the
dictionary's. Both harnesses green at 2,247 assertions; the live catalog shows
`users_external_id_unique` alone, and `rbac.upsert_user_from_jwt` called twice
for one subject returns the same row. The other seven duplicates in this change
are not done.

**Owner's decision, 2026-09-06: one index, and the dictionary's is the one that
stays.** The principle is that the physical table must match what
`unique_value = TRUE` in the dictionary produces - the dictionary is the source
of truth for the model, so a hand-written constraint that disagrees with it is
the thing that is wrong. Paired with it: **agents get a generated identifier**
(a prefix plus a random suffix) rather than an empty `external_id`, so the case
the two index shapes disagree about stops existing. That second half is an
identity-model change, not an index cleanup, and is now tracked as **S20** -
Medium, because until it lands the empty string is a legal shared identity.

Two consequences follow that are not style questions, and both must be handled
in the same change:

1. **The dictionary's index is partial and the constraint is not.** The column is
   `NOT NULL DEFAULT ''`, so today exactly one row may carry `external_id = ''`.
   Under the partial index, **many rows may**. That is arguably the better rule -
   a pre-provisioned user with no external identity yet is a real state, and the
   present schema allows only one of them - but it is a data-integrity change and
   it needs to be intended, not inherited. State it in the closure.
2. **Four `ON CONFLICT (external_id)` sites stop working**, not two: `0030:315`
   (`upsert_user_from_jwt`), `0190:50`, and `apps/test/tests/0300_test_audit_log.sql:482`
   and `:486`, which take the suite down on the first run after the change. A
   bare `ON CONFLICT (col)` needs a *total* unique index; PostgreSQL will not
   infer a partial one. Each becomes
   `ON CONFLICT (external_id) WHERE external_id IS NOT NULL AND external_id <> ''`
   - an exact predicate match - or the change breaks user login on the first
   upsert. `upsert_user_from_jwt` already rejects an empty `external_id` at
   `0030:309-311`, so the predicate excludes nothing it can insert. The generated
   copies (`extension/pg_semantius--*.sql`, `packages/*/src/migrations-bundle.ts`)
   follow from the regeneration step, which must run **before** the harnesses.

3. **The eighth edit is not a `DROP INDEX`.** `users_external_id_key` is
   constraint-backed, so removing it means deleting the `UNIQUE` keyword at
   `0020:151`. That also means there is **no** unique index on `external_id`
   between `0020` and `0190:15` - the `unique_value` UPDATE is what builds the
   dictionary's one. Nothing inserts users in between today; record that as a
   load-bearing ordering assumption, because a future migration that seeds a user
   earlier would silently lose the constraint.
4. **`get_schema` keeps reporting `unique_value: true`** for the column
   (`0080:259`, `:303`) when it is only partially unique afterward. A client
   enforcing uniqueness from the schema will be wrong about `''`. Say so in the
   closure, or fix the reporting.

**Pin.** In a **new `0450_test_rbac_indexes.sql`** - not an extension of
`0405_test_rbac_helpers.sql`, because pgTAP wants one exact `plan(N)` and the
choice cannot be left open. It asserts: the duplicates are absent; the recursive
permission CTE still plans as index-only scans; two rows with
`external_id = ''` both insert (the new rule, stated deliberately); and
`rbac.upsert_user_from_jwt` called twice for one subject yields one row. That
last one is the regression that would otherwise reach production as a failed
login. Run it as user3 (Administrator) - `users` carries RLS requiring
`user:manage` (`0050:72-88`) plus audit triggers.

The other seven duplicates are ordinary `DROP INDEX` edits in `0020`.

**Fix.** Drop the duplicates in place in `0020` (prototyping mode: fixes go into
the original migration, there are no upgrade scripts). Enumerate from the
catalog first, do not work from the list above:

```sql
SELECT c.relname AS tbl, i.relname AS idx, pg_get_indexdef(i.oid)
FROM   pg_index x
JOIN   pg_class i ON i.oid = x.indexrelid
JOIN   pg_class c ON c.oid = x.indrelid
JOIN   pg_namespace n ON n.oid = c.relnamespace
WHERE  n.nspname = 'rbac'
ORDER  BY 1, 3;
```

**Risk.** A leading-column index is not automatically redundant against a
composite unique index - it is narrower, so an index-only scan over it is
cheaper. On tables this size that does not pay for a second index, but the plan
check below is what decides it, not the rule of thumb.

**Pin.** A new `0450_test_rbac_indexes.sql`, or an extension of
`0405_test_rbac_helpers.sql`: assert the duplicates are absent, **and** assert
the recursive permission CTE still plans as index-only scans. The row's 0.6 ms
is the thing that must not regress; a test that only counts indexes proves
nothing about the plan.

---

## Change 2: P5, the cost of adding a field

**Independent of P7. Second.**

The row's three sub-fixes are not equal, and one of them cannot be done the way
it is written.

**(a) The no-op `entities` UPDATE.** `update_table_searchable_flag`
(`0070_dd_functions.sql:1459`) and `update_table_is_child_flag` (`:1681`) both
end in an unconditional `UPDATE entities SET <flag> = v WHERE table_name = ...`.
The value is usually unchanged, and the UPDATE still fires the `entities`
trigger stack. Nineteen triggers on `entities` fire on UPDATE, but **most are
gated by a `WHEN` clause and do not fire on an unchanged flag** - among them
`enforce_table_searchable_consistency_trigger` (`0070:1664`),
`update_entity_policies_trigger` (`0070:1258`), the three rename triggers
(`0140:254`, `:292`, `:347`), `enable_table_trigger` (`0145:345`) and
`zzz_label_fn_entity_update_trigger` (`0145:1070`). About seven ungated ones
actually run, plus a `modules` UPDATE through the version trigger.

Adding `AND <flag> IS DISTINCT FROM v` to both is a two-line change. **Do it
first and re-measure**, but treat "this is where most of the 5 ms goes" as a
hypothesis that change 0 tests, not as the reason to stop: with two thirds of
the stack already gated, the saving may be smaller than the row implies.

**(b) Skipping the label rebuild.** `zzz_label_fn_field_insert_trigger`
(`0145_managed_enable.sql:1079`) fires `rebuild_entity_label_functions` for
*every* field insert, and that function emits DDL.

**The gate is not the three-way test the row implies.** Five kinds of field
change the generated bodies, and the last two are the ones that will be missed:

- a `reference`/`parent` field;
- the entity's `label_column`;
- a field named by `label_parent`;
- **any ordinary scalar field on a junction-shaped entity**, because
  `rebuild_entity_label_functions` branches on `dd_is_junction` (`0145:810`),
  whose heuristic (`0145:700-716`) holds only while the entity has no payload
  field beyond id / label / audit. One plain field flips the `_label` body from
  the combined parent legs to the local term;
- **a field whose name collides with an `<fk>_label` companion**, because the
  generator skips the companion when a real column already owns that name
  (`0145:891-895`). `reserve_field_namespace()` (`0145:928-945`) reserves only
  names starting with `_`, so `customer_id_label` is a legal field name and
  inserting it must rebuild, to drop the function it now shadows.

The row proposes a trigger `WHEN` clause. **That cannot work as written**: the
`label_column` lives on `entities`, and a `WHEN` clause may not query another
table - the same constraint already recorded in
`docs/jsonlogic-optimization-candidates.md`. The gate has to sit inside
`dd_label_fn_sync_field()` (`0145:1048`) as an early `RETURN NULL`. The trigger
still fires; the DDL is what is skipped, and the DDL is the cost. A partial
`WHEN (NEW.format IN ('reference','parent'))` is **wrong** on its own, because it
would skip the label column.

`dd_label_fn_sync_field()` is shared by three triggers - INSERT (`0145:1079`),
DELETE (`:1084`) and UPDATE (`:1089`). P5 is about insert cost only, so the gate
carries `TG_OP = 'INSERT'`; gating the other two is a behavior change nobody
asked for.

**(c) Statement-level rebuild with transition tables.** The P11 shape
(`handle_field_searchable_*`, `0070:1532-1622`) applied to the label triggers.
Largest of the three, and it only pays on bulk inserts. Do it only if (a) and (b)
miss the target, and note that a trigger using transition tables may carry one
event only, so it is three trigger functions rather than one - and the linter
cannot parse that shape, which is what **Q6** is.

**Risk.** (b) is the one that can break something silently: skip a rebuild that
was needed and `<fk>_label` goes stale, which nothing raises on. Derive the gate
from what `rebuild_entity_label_functions` actually reads (`0145:746`), not from
a guess about what matters.

**Pin.** Extend `0448_test_statement_triggers.sql` and
`0370_test_composed_labels.sql`: insert a plain scalar field and assert **no**
label DDL fired; insert a reference field, the label column, and a
`label_parent` target, and assert it did, with the composed label correct in each
case. Assert the audit-row count per field.

**Done when.** One audit row per field, and per-field time cut to about a third
of whatever change 0 measures. The row's absolute 1.5 ms came from a 5 ms
baseline that P11 has already cut; a ratio survives the re-measurement, an
absolute does not.

---

## Change 3: P7, the STABLE functions that write

**Settled as option B on 2026-09-06 (decision record below). The work is small: a
reproduction, one write to re-scope, and a contract to write down.
`rbac.begin_request()` is not built.**

### What P7 is

Three writes sit on functions the planner is entitled to treat as side-effect
free:

- `rbac.uid()` is `STABLE` (`0030_rbac_functions.sql:233`) and writes
  `request.jwt.claim.*` - the claims fan-out at `:149` and the PostgreSQL 18
  subject override at `:172-173`.
- `rbac.ensure_context_initialized()` is `VOLATILE` (`0030:424`) and writes the
  four `app.*` settings at `:417-420`. It is called from the `STABLE` readers,
  which is the shape the linter flags.
- The same function writes `app.bearer_cache_notice` with `is_local = false`
  (`0030:380`), so in a bearer session that write **outlives the transaction**,
  and it is paired with a `RAISE WARNING`.

The row lists ten members. Besides `uid`, `user_id`, `has_permission` and
`jl_request_context` (`0180_computed_validation.sql:349`) they are
`rbac.whoami` (`0030:1108`), `rbac.get_current_user_permissions` (`0030:891`),
`rbac.has_any_permission` (`0030:787`), the generated `select_rule_*` functions,
and `public.is_raci_actor` / `public.has_consultation` - which live in `public`,
not `rbac` (`0080_public_functions.sql:642-646`), and are `STABLE` at
`0210_raci.sql:254` and `:297`. All reach the same two writers. The closing
record must list them, or the row reads as half-done.

### The decision, and why

**Option B: the readers keep their lazy write.** Recorded 2026-09-06, after the
owner established that **Neon's Data API is the primary deployment target - the
product's own cloud runs on it.**

The alternative was to make the readers pure and have a `VOLATILE`
`rbac.begin_request(claims)` build the context at the start of each request,
replacing the `set_config('request.jwt.claims', ...)` the client adapters already
make. It fails on the primary target: the Data API is Neon's own PostgREST, no
code of ours runs per request, and Neon exposes no `db-pre-request`. Every check
there would cost about 1 ms cold instead of 0.025 ms warm - and per *row*
wherever the interpreter's `has_permission` operator appears
(`0015_jsonlogic.sql:675`), which is every `select_rule` and every validation
rule. That would hand the fast path to deployments with an app tier and take it
away from production.

Option B keeps it, and keeps it where it is needed. The `app.*` cache is
transaction-local and PostgREST runs one transaction per request, so the first
check in a request builds it and the rest read it; `set_config` is legal inside
the read-only transaction a `GET` runs in. It is safe there for the reason
`SECURITY.md:79-84` already gives: behind PostgREST the client never runs SQL, so
`app.*` is out of its reach. Direct SQL keeps working unchanged, which was the
owner's other requirement.

**What the option-A analysis is still good for.** It established that
`rbac.uid()` cannot be made pure by deleting the fan-out - `:149` is what creates
`request.jwt.claim.aud`, which `:195` reads to enforce `jwt_aud`, and six other
consumers read the fanned-out settings - and that `rbac.user_id()`'s 28000 raise
lives inside `ensure_context_initialized` (`0030:403-405`), the function a split
would empty. Both are reasons the split cost more than it looked. Recorded so the
option is not reopened casually; not work.

### Step 1: reproduce - and there is nothing in the tree to reproduce against

The question is whether a `STABLE` function with constant arguments is actually
evaluated at plan time on any reachable path. `estimate_expression_value()` does
fold `STABLE` calls, but only where the estimators look: the non-`Var` side of a
restriction clause, `LIMIT`/`OFFSET`, and pattern or array estimation. The
foldable shape is `col <op> stable_fn(<const>)`.

**A search on 2026-09-06 found no instance of that shape.** Every RLS policy is
sub-select wrapped (`0050_rbac_rls.sql:47-197`, `0180_computed_validation.sql:482`,
`:493`, `:496`), pinned by `0445_test_policy_initplan_form.sql`. The only
unwrapped calls are `0080_public_functions.sql:22` and
`0284_module_slug_provision.sql:199`, both
`rbac.has_any_permission('admin', m.view_permission)` - correlated on a column,
so neither hoistable nor foldable, and both inside functions with no volatility
marker. There is no `WHERE col = rbac.user_id()` index qual anywhere.
`public.has_permission(TEXT)` (`0080:652`) is a bare boolean call in a targetlist
when PostgREST invokes it as an RPC, and a targetlist entry is never estimated.

So the reproduction is **synthetic**: build `WHERE some_col = <a STABLE reader
returning a comparable value>(<constant>)` on a table with statistics, `ANALYZE`,
then `EXPLAIN` with `track_functions = 'pl'` on and read
`pg_stat_user_functions`. If it does not fire there it fires nowhere in this
tree, and P7's plan-time clause is met by construction rather than by a fix.

Two cheap extras, because they are the row's other claims: `EXPLAIN` of a
policy-guarded query with no claims set, and the same through `PREPARE` at the
sixth execution, where PostgreSQL switches to a generic plan.

### Step 2: the one write that must move regardless

`app.bearer_cache_notice` (`0030:380`) is written with `is_local = false`, so it
survives the transaction, and it is paired with a `RAISE WARNING`. Whether or not
step 1 reproduces, that is a side effect on a read path and it is the one thing
here that is unambiguously wrong. Make it transaction-local, or move it somewhere
allowed to write.

`apps/test/migrations/0020_ext.sql:57-60` also writes `app.*` with
`is_local = false`. That is a test helper deliberately setting up a session, not a
defect - say so in the closure, or a later reader will "fix" it.

### Step 3: write the contract down

Which functions may write, which may only read, why the readers are `STABLE`
anyway, and what a cold session costs. In the code comments on `rbac.uid()` and
`rbac.ensure_context_initialized()` per the AGENTS.md rule, with the short version
in `AGENTS.md`.

### Pin

- `0435_test_bearer_context_bypass.sql`: the bearer notice does not outlive its
  transaction. That is the whole behavioral change.
- If step 1 reproduces, the call site it finds gets the sub-select shape and an
  assertion in `0445_test_policy_initplan_form.sql`.
- `0446_test_rbac_hot_path.sql`, `0447_test_request_context.sql`,
  `0410_test_uid_claim_paths.sql` and `apps/test/migrations/0020_ext.sql` are
  **untouched**. They were at risk while option A was live; they are not now.

### How P7 closes

**Restated.** Delivered: no plan-time side effect on any reachable path, and one
non-idempotent write removed. Not delivered, and the record must say so:

- **The 13 linter warnings stay**, accepted rather than fixed - the readers keep
  their lazy write, because the primary target has no seam to build the cache
  from.
- **The `0080`/`0190` workaround stays.** It is a snapshot problem, not a
  volatility one: a `STABLE` function reads the calling statement's snapshot and
  cannot see the user row `get_userinfo()` just created (`0080:96-106`,
  `0190:140-151`).

### What option B does not fix, and who owns it

Two review findings are real and are **not** closed by this change:

- **`0050_rbac_rls.sql:47`** (the test half is now tracked as **R10**) -
  `modules_select_policy` is
  `(select rbac.has_any_permission('admin', view_permission))`. The column
  reference makes the sub-select correlated, so it is a SubPlan evaluated per row
  rather than an InitPlan. **Closed as not worth fixing, 2026-09-06**: an
  installation carries under 20 modules, so the whole policy costs about 0.5 ms
  warm and 20 ms in bearer mode, on a table nobody scans in a loop.

  What is worth fixing is the test. `0445_test_policy_initplan_form.sql` is named
  for the InitPlan form and reads as a guarantee that policies evaluate once per
  statement; it actually checks only that the call sits inside a sub-select. This
  policy passes it while doing the thing the name forbids. Either rename the test
  to what it checks, or make it distinguish a correlated sub-select from an
  uncorrelated one. A test that overpromises is worse than no test.
- **Bearer mode pays every per-row site cold** - `0015_jsonlogic.sql:675`,
  `0210_raci.sql:961`, `:1048`, `:1060`. Known and accepted
  (`docs/bearer-mode-status.md:106-107`); option B neither helps nor worsens it.


## Change 4: P8, labeling the read-only RPCs STABLE

**Option B removes this change's precondition, and that has to be faced rather
than inherited.**

The row reads as eight mechanical `STABLE` labels. Every function it names -
`public.get_schema`, `get_schemas`, `get_user_cubes`, `get_module_cubes`,
`get_user_modules`, `rbac.require_permission`, `require_any_permission`,
`list_api_keys` (`0110_apikeys.sql`), and `rbac.get_user_permissions` through its
self-or-admin guard at `0030:821-828` - reaches `set_config` by way of
`rbac.uid()` or `rbac.has_permission()` (`0080:156`, `:209`, `:231`, `:507`,
`:525`, `:563`, `:584`, `:688`, `:716`, `:747`, `:754`; `0030:692`, `:794`).
There is no member that does not.

The earlier draft said "wait until P7 is settled". Under option B, P7 is settled
**by keeping those writes**, so waiting is waiting for something that will not
happen. Labeling these `STABLE` moves eight functions into the same accepted
position as the ten P7 already covers: `STABLE` over a lazy transaction-local
write, on a path the planner does not fold. The trade is real - eight P8 warnings
become eight P7-shaped ones - so P8's "the 8 warnings are gone" is not
deliverable either way.

**Decided 2026-09-06: label them.** The row closes **against its original
wording**, not restated. plpgsql_check does not chase into called functions - it
already reports these eight as "VOLATILE but read-only", which is why they are P8
and not P7 - so labeling them removes those eight warnings and adds none. Both of
the row's clauses are met: the warnings go, and the RPCs answer `GET`.

**One check before labeling each function: does it touch a table.** The writes
that make this a judgment call are all `set_config(..., true)` - transaction-local
settings, discarded at commit, and legal inside the read-only transaction a `GET`
runs in. Verified on 2026-09-06 that none of `get_schema`, `get_schemas`,
`get_user_cubes`, `get_module_cubes`, `get_user_modules` or `list_api_keys`
writes a row. **`public.get_userinfo` does** - it upserts the user - so it is not
in P8's list and must stay `VOLATILE`. Neither of the two things `STABLE` licenses
bites here: evaluate-once-and-reuse needs repeated calls inside one query, and
plan-time folding needs `col <op> fn(const)`, while an RPC arrives as a
targetlist entry, which is never estimated.

**Pin, corrected.** The earlier pin -
`BEGIN READ ONLY; SELECT public.get_schema('...'); ROLLBACK;` - proves nothing:
the only writes on that path are `set_config` GUC writes, which are legal in a
read-only transaction, and `build_schema_for_table` touches no table, so the
statement passes today, before and after. What PostgREST's `GET` gate actually
reads is `pg_proc.provolatile`, so the pin is a catalog assertion - each named
function is `s` - plus one live `GET` through PostgREST in
`pgdocker/pg-ext-lifecycle.sh`, which pgTAP cannot express.

---

## Change 5: P9, the per-entity loops

`get_user_cubes()` rebuilds every entity's schema from scratch on every call,
three queries per entity. Measured 2026-09-06 (change 0): **0.87 ms per entity**
warm, effectively all of it inside `build_schema_for_table`. At 33 entities that
is 29 ms; at 250, about 220 ms.

**Target, set by the owner 2026-09-06: under 150 ms at 250 entities**, which is
under 0.6 ms per entity - a 1.45x improvement on today. That is a modest ask, and
it decides the fix.

### The fix is the set-based rewrite. There is no cache

The row offered two routes and they are not equally priced:

- **One set-based query** instead of the per-entity loop with three queries each.
  It removes the round trips and nothing else. The row's own estimate was 0.3 ms
  per entity - 75 ms at 250, comfortably inside the target.
- **A cache** keyed on a model version. Faster still, and it drags in three
  problems the rewrite does not have: what invalidates it (`modules.version` does
  not move on a `fields` change today), staleness across module boundaries (an
  entity's schema embeds the referenced entity's labels and id/label columns from
  whatever module those live in, plus its list of children), and where it lives
  (`common._cache` requires a TTL and is `UNLOGGED`, so a fresh install or
  restore starts empty and stays empty until someone edits a module).

**Chosen: the rewrite.** A cache is only worth those three problems if the
rewrite misses the target, and on the numbers it should not. Measure after the
rewrite; revisit only if it does.

`get_module_cubes` (`0080:681`) re-selects the entity it is already iterating
(`0080:712-714`: the loop yields table *names*, then re-reads the `entities` row
for each). Fix that first - it is minutes, and it is a bug rather than a scaling
question. `get_user_cubes` (`0080:741`) does not have it.

### What does not change

`build_schema_for_table` refuses a caller without the entity's `view_permission`
at `0080:231` - the b9 fix, pinned by
`0341_test_read_helper_completeness.sql:47-57`. The rewrite must keep that gate
per caller. It is roughly 6% of the cost (a warm check is 0.025 ms,
`docs/bearer-mode-status.md:99-104`), so there is nothing to gain by touching it
and a read bypass to lose.

### Still worth doing: the `fields` bump on `modules.version`

Decided 2026-09-06, and it stands on its own now that the cache is not being
built. `0282_module_version.sql:130-155` puts bump triggers on `modules`,
`entities`, `roles`, `permissions` and `processes` - **not on `fields`**. A field
edit moves the version only as a side effect of the unconditional
`UPDATE entities` in `update_table_searchable_flag` (`0070:1475`) and
`update_table_is_child_flag` (`0070:1695`), which change 2(a) removes.

So `modules.version` claims to mean "the model changed" and does not. Add an
explicit `AFTER INSERT OR UPDATE OR DELETE ON fields` trigger resolving the module
through `entities.module_id` by `table_name` (`fields` has no `module_id`), and
land it **before** change 2(a). It is a correctness fix for every consumer of that
version, not a cache dependency.

### Pin

`get_user_cubes()` under 150 ms at 250 entities, measured the way change 0
measured 33; the per-caller gate still refusing an entity the caller cannot view,
asserted against `0341_test_read_helper_completeness.sql`'s existing case; and
`modules.version` moving on a `fields` insert, update and delete.


## Order, and why

1. **Change 0**, re-measure. Everything else is graded against what it produces.
2. **Change 1 (P10)**, drop the duplicate indexes and settle the `external_id`
   constraint. Independent of everything else, own test.
3. **Change 3 (P7)**, the synthetic reproduction, the `0030:380` re-scope and the
   contract. Small, and independent of the rest.
4. **The `fields` bump trigger on `modules.version`** (decided 2026-09-06). It
   is a correctness fix on its own and it must land **before** change 2(a)
   removes the accidental path, or field edits become invisible to every
   consumer of that version in between.
5. **Changes 2 and 5 together (P5 and P9).** *Not* one after the other: change
   2(a) removes the unconditional `UPDATE entities` that is currently the only
   thing bumping `modules.version` when a field changes, which is what change
   5's cache keys on. With the trigger from step 4 in place they are safe, but
   they touch the same triggers and are designed together.
6. **Change 4 (P8)**, after its own question is answered. No longer blocked on
   change 3 - option B settled P7 by keeping the writes, so there is nothing to
   wait for.

Each change lands with its pinning test in the same commit, both harnesses green
(`pgdocker/pg-cli-retest.sh` and `pgdocker/pg-ext-retest.sh`), and its own dated
section in `plans/ext-solved-items.md` carrying the original row text. Regenerate
the extension with `deno task extension <version>` and the
`packages/*/migrations-bundle.ts` copies with `scripts/bundle-sql.ts` **before**
running the harnesses, not only before shipping - change 1 edits SQL that the
generated bundles carry. Nothing is committed without asking.

## Documentation this plan owes

Not optional and not an afterthought: a row leaves the open list only when its
record exists somewhere durable.

| Change | Document | What goes in |
|---|---|---|
| all | `plans/ext-solved-items.md` | one dated section per change, with the original row text, what changed, and what proves it |
| all | `plans/pg_semantius-open-items.md` | delete the closed rows, add the IDs to the gap list at `:6`, add a closure bullet, move the date |
| all | none - run `./pgdocker/pg-cli-retest.sh --coverage` after each change and compare against the previous run. `docs/test-coverage.md` says how to read it; it holds no numbers, so there is nothing to regenerate |
| 0 | this file | the re-measured baselines, written down before any SQL is edited |
| 1 (P10) | `SECURITY.md`, and the `0020` / `0190` comments | `users.external_id` becomes partially unique: many rows may carry `''`. That is a data-integrity rule change and belongs where someone reasoning about identity will find it |
| 2 (P5) | `docs/jsonlogic-optimization-candidates.md` | its "budget about ten extra DDL events per field" note names P5; if P5's trigger shape changes, that paragraph follows |
| 3 (P7) | the `rbac.uid()` and `rbac.ensure_context_initialized()` code comments, and `AGENTS.md` | the volatility contract - which functions may write, which may only read, why the readers are `STABLE` **anyway**, and what a cold session costs. By the AGENTS.md rule the reasoning goes in the comment, not behind a pointer; `AGENTS.md` gets the one-paragraph version |
| 3 (P7) | `SECURITY.md` | its "What is not" register carries "The transaction-scoped context cache is client-writable". Option B keeps that true and adds why: the primary target has no per-request seam, so the lazy write stays. Sharpen the bullet rather than replacing it |
| 3 (P7) | `docs/bearer-mode-status.md` | the bearer notice changes scope, and that document is where the bearer session's behavior is recorded |
| 3 (P7) | `docs/authz-spec.md` | **no.** The test is "does the change alter when a caller is refused". Under option B nobody's refusal changes - that test was met by option A, which is not being built. Leave the spec alone |
| 5 (P9) | the cache's own code comment | what invalidates it, what happens when it is stale, and why the gate still runs on every read. Not a pointer to this plan |
| all | code comments | the AGENTS.md rule: the reasoning goes into the comment, not a pointer to this plan. Plan ids dangle by construction - this file is deleted once it owns no row |


## Not in this plan

- **P14** - closed as postponed on 2026-09-06; record in
  `docs/jsonlogic-optimization-candidates.md`. If it is ever built it adds
  roughly ten DDL events per field on rule-bearing entities, which is change 2's
  business.
- **The Q rows** - vendored pgmq code (Q2, Q3, Q5) and the statement-level
  trigger functions the linter cannot parse (Q6). Q6 grows if change 2 takes
  option (c).
- **S12, S16-S19, B11, B17, B18, R6-R9, T2, S14** - not `P`, and not Medium.
