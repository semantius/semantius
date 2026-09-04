# Plan: statement-level audit and queue triggers (P4)

Written 2026-09-04. One of three plans that replaced a single oversized one.
Siblings: `plans/perf-hot-paths.md` (P3 and half of P2, land first) and
`plans/select-rule-native-predicates.md`.

## Context

Open item **P4**: three `FOR EACH ROW` triggers each do statement-constant work
per row. Measured on a 10k-row INSERT: plain 65 ms; audit 1.5–2.0 s; queue
0.8–1.0 s; validation 0.7–1.1 s; all three together 4.25 s. Measured floors:
set-based audit insert 497 ms, `pgmq.send_batch(10k)` 114 ms.

Two of the three convert cleanly to statement-level triggers with transition
tables. The third — the generated validator — **cannot**: it is a BEFORE trigger
that writes back to `NEW` (`0180:156-162`), transition tables are AFTER-only,
and a statement trigger cannot modify rows. Its cost is attacked differently
(see Step 5).

**Depends on `plans/perf-hot-paths.md` having landed** — Step 3 below uses
`jl_request_context()`, which that plan introduces.

The audit/NOTIFY work of `plans/audit-ddl-noise.md` has also **landed**
(`419a2ab`). This is the plan that edits `0150_audit_log.sql` and
`pg-ext-lifecycle.sh` after it, so re-read both before starting: the line numbers
cited here were taken against the post-`419a2ab` tree.

## Open items

**Owns, and therefore closes.** Both rows are owned by this plan and by no other.

| Row | Done when | Does this plan get there? |
|---|---|---|
| **P11** | The request context resolved once per statement rather than once per row, asserted structurally, and one rule row at ~54 µs from ~68 | **Yes** — Step 1. Split out of P2 on 2026-09-04 so the row has one owner. |
| **P4** | 10k-row INSERT with all three triggers at 1.0–1.3 s, from 4.25 | **Yes, provided `plans/perf-hot-paths.md` has landed** — see Target. All three of P4's named fixes (statement-level audit, `send_batch` for the queue, the conditional `$old`/`$now` build) are in this plan; nothing is credited to a sibling. |

**Touches without owning.**

| Row | Effect here | Owner |
|---|---|---|
| **Q5** | one further unused-variable site (`queue_event_after_insert`, rewritten by Step 3). Base is **11, not 12** — `plans/perf-hot-paths.md` lands first and takes one. So 11 becomes 10 | unowned |
| **P7** | `jl_request_context` (Step 1) is a new STABLE function that writes settings through `ensure_context_initialized`; add it to that row | unowned |

---

### Target — reachable, but only after `perf-hot-paths.md`

An earlier draft called 1.0–1.3 s unreachable and put it at ~1.38–1.78 s. That was
wrong: it summed the floors while assuming the validator kept **both** its per-row
caller resolution **and** the un-sped interpreter. Neither survives.

- Floors: plain 65 ms + set-based audit 497 ms + `send_batch(10k)` 114 ms = **676 ms**.
- The validator is 0.7–1.1 s today. Its dominant per-row cost is
  `rbac.user_id_or_null()` at `0180:174` — the same ~26 µs chain as
  `has_permission`, so roughly 260 ms of that at 10k rows. Step 5b removes it.
- What remains of the validator is `to_jsonb`, the context build and
  `evaluate_json_logic` per rule. `plans/perf-hot-paths.md` Step 2 takes 30–50%
  off the interpreter, which is why that plan must land first.
- Validator after both: roughly **300–500 ms**. Total **~1.0–1.2 s**, inside the
  row's target.

Measure it rather than trusting this. If the validator lands above ~620 ms the
row misses, and the remedy is more interpreter work, not more trigger work.

---

## Step 1 — `0180_computed_validation.sql`: resolve the context once per query (P11)

The generated rule predicate calls `ensure_context_initialized` and rebuilds
`$today`/`$now`/`$user_id` **for every row** (`0180:340-349`).

- Add `public.jl_request_context()` — STABLE, SECURITY DEFINER, pinned
  `search_path`, COMMENT, `REVOKE EXECUTE … FROM PUBLIC` +
  `GRANT … TO semantius_user`. It calls `rbac.ensure_context_initialized()` once
  and returns `{"$today":…, "$now":…, "$user_id":…}`.
  - It **must keep propagating 42501**: that call is the only thing refusing an
    unauthenticated session, because the rule-branch SELECT policy
    (`0180:376-378`) carries no permission conjunct and the exception handler at
    `0180:351-355` sits *below* it.
  - `$user_id` must mirror `0180:345-348` exactly — NULL **or empty string**
    maps to jsonb `null`. A naive `to_jsonb(current_setting(...)::int)` raises
    22P02 on the empty case.
  - It passes `0060_test_security.sql` only because of Step 1 sub-step 4's
    widening. Land them together.
  - Add it to open item **P7**'s list: a STABLE function that writes settings
    through `ensure_context_initialized`.
- Generate a **two-argument** predicate `select_rule_<t>(p_row, p_ctx jsonb)`,
  keeping the one-argument form as a wrapper that supplies the context —
  `get_record_by_id` (`0070:1831-1834`) calls that form, and the `set_record`
  JsonLogic operator goes through it.
  - **Both signatures must be dropped at all four drop sites** or
    `DROP … IF EXISTS` silently no-ops and the CASCADE never removes the
    dependent policy: `0180:293`, `0180:306`, `0180:429`, `0140:209-210`.
  - **Both need their own `REVOKE`/`GRANT`/`COMMENT`** (`0180:368-373`) or 0060
    and 0240 fail.
- Emit **all three policies** with the context passed in — not just SELECT.
  `build_select_rule_policy` embeds the same per-row helper call in the
  UPDATE and DELETE quals too (`0180:387-389`, `0180:390-392`, both
  `… AND public.%I(%I.*)`), and those are evaluated per row for every write, so
  leaving them alone keeps `ensure_context_initialized` firing per row on the
  write path. SELECT becomes
  `USING (public.select_rule_t(t, (SELECT public.jl_request_context())))`
  (`0180:376-378`); UPDATE and DELETE keep their
  `(SELECT rbac.has_permission(…)) AND …` wrapper around the same two-argument
  call. An uncorrelated sub-select in an RLS qual becomes a once-per-statement
  InitPlan — the device P1 already used for `rbac.has_permission`. Pass `t`, not
  `t.*`, in every one.
**Do not touch `build_record_logic_trigger` here.** `0180_computed_validation.sql`
holds two independent generators: the compute/validate BEFORE ROW trigger
(`:29-215`) and the policy generator this step edits (`:280-399`). They share no
code. The trigger's per-row costs belong to P4 and are owned entirely by
`plans/perf-per-statement.md`, so that one open item is closed by one plan.
There is no InitPlan in a BEFORE ROW trigger anyway, so nothing here would help
it.

**Expected: ~68 → ~54 µs per rule row.** Marginal win once Step 1 has landed is
~10–13%, not the ~21% a standalone reading suggests — `0180:340` calls the same
`ensure_context_initialized` Step 1 already made cheap. The endpoint is what
matters.

---

---

## Step 2 — prototype first, before writing anything

This is the one place the work needs a capability **the tree has never
exercised**, and it must be settled before Steps 3 and 4 are written.

The only `REFERENCING` precedent in the whole repo is `0070:1606-1620`: three
statement triggers bound to a **single** table (`fields`), each with its own
dedicated function and named columns. `audit_t` — which an earlier draft called
"the shape to copy" — uses **no transition table at all** (`0150:276-299`); it
selects constants.

Steps 3 and 4 need something different: **one generic plpgsql function holding a
static `… FROM new_table`, reused across a dozen audited or queued tables of
different row types in the same session.** PL/pgSQL caches a statement's plan per
*function*, not per relation. Whether the cached plan re-resolves the transition
table's descriptor on each firing is an empirical question, and the failure modes
are a cached-plan type error (loud) or silently wrong audit rows (quiet).

The tree already documents this hazard class and its mitigation ten lines from
where Step 4 works: `0180:146-159` builds its statement with
`EXECUTE format(...)` precisely so the descriptor is re-resolved every call.

**Prototype:** two audited tables of different shapes, tracked in one
transaction, exercised in one session. If the static form misbehaves, use
`EXECUTE format(...)` and record why in the file.

Related and real, but the smaller sibling: a column added to an audited table
*later in the same transaction*. `entities` is audited and `0270` adds
`order_column` mid-migration, and the single-transaction `CREATE EXTENSION` path
is where that surfaces. The multi-table case is what decides the design; this one
decides whether an extra test is needed (see Tests).

---

## Step 3 — `0170_queue.sql`: enqueue once per statement

`queue_build_record_json()` (`0170:226-281`) runs a three-table lookup and a
`pgmq.send` per row, though the lookup is statement-constant and
`queue_table_events.table_name` is `unique_value` (`0170:188`), so the `LIMIT 1`
can only ever match one mapping.

- Rewrite it statement-level with `REFERENCING NEW TABLE AS new_rows` /
  `OLD TABLE AS old_rows`: one lookup, then
  `PERFORM pgmq.send_batch(v_queue_name, array_agg(msg))` (`0160:775`, the
  two-argument form — pass no `headers`).
- **The empty guard is mandatory, not an optimisation.** A statement trigger
  fires for zero-row statements, `array_agg` over nothing is NULL, and
  `pgmq._validate_batch_params` raises `msgs cannot be NULL or empty`
  (`0160:725-727`).
- PostgreSQL forbids `REFERENCING` on a trigger defined for more than one event,
  so the `upsert` and `change` handlers (`0170:283-333`, which map to
  `INSERT OR UPDATE` and `INSERT OR UPDATE OR DELETE`) must fan out into
  per-event triggers.
  - **`CREATE OR REPLACE TRIGGER` must become `DROP TRIGGER IF EXISTS` +
    `CREATE TRIGGER`** — it cannot turn a row trigger into a statement trigger
    with a `REFERENCING` clause.
  - **Put the event discriminator before the table name.** The current name
    `queue_<q>_<handler>_on_<table>` already approaches the 63-byte identifier
    limit; two names truncating alike would give a duplicate create and a
    silently missed drop.
- `queue_event_after_delete()` (`0170:335-366`) must drop the new set **and** the
  old single name, so a mapping created before this change tears down cleanly.
- New functions need `REVOKE EXECUTE … FROM PUBLIC`, a COMMENT and a pinned
  `search_path` (0060, 0240).
- Record the pre-existing leak this widens: there is no AFTER UPDATE trigger on
  `queue_table_events`, so changing `event_handler` already orphans the old
  trigger. The fan-out multiplies the orphans.

---

## Step 4 — `0150_audit_log.sql`: statement-level audit for INSERT and DELETE

The row trigger re-runs a catalog query for the primary key columns on every row
(`0150:232`).

**INSERT and DELETE become statement-level** — one `INSERT … SELECT` over the
transition table with `audit.primary_key_columns(TG_RELID)` (`0150:126-149`) and
`audit.current_user_id()` evaluated once. **`audit_i_u_d` stays, for UPDATE
only.**

### Why UPDATE stays row-level

The audit row carries `record`, `old_record`, `record_id` and `old_record_id`,
and the CHECK constraints at `0150:63-69` *require* all four for `op = 'UPDATE'`.
Transition tables are unordered row sets whose only join key is the primary key —
which `old_record_id` exists precisely to track *changing*.
**`entities.table_name` is the primary key** (`0060_dd_schema.sql:13-14`) and
`rename_dd_table` renames it (`0140_dd_rename.sql:39-46`), and `entities` is
audited (`0150:606-610`) — so PK-changing UPDATEs on an audited table are real,
not hypothetical. (`tables` is a backward-compatibility *view* over `entities`,
`0130_create_tables_view_compat.sql:15`; AGENTS.md still describes it as a table.) Pairing by PK would silently mis-associate before/after
images in an evidence table. Owner decision, 2026-09-04.

### Mechanics

- `audit.enable_tracking` (`0150:308-346`) now creates four triggers and
  `audit.disable_tracking` (`0150:352-372`) drops four. Keep the names fixed
  literals — that is what makes renames free (`0150:530`).
- Bodies keep `SET search_path = ''`, so every identifier stays schema-qualified
  **except the transition-table names**, which are ephemeral named relations and
  cannot be qualified. Say so in a comment, or a reviewer will "fix" it.
- `audit_t` (TRUNCATE) is untouched.
- `COALESCE(record_jsonb, old_record_jsonb)` (`0150:241`) and
  `RETURN COALESCE(NEW, OLD)` (`0150:268`) become dead but harmless once the
  function only serves UPDATE.

### Two limitations to write into the file

- Transition tables are rejected on partitions and inheritance children, so
  `audit.enable_tracking(REGCLASS)` — public API over any table — now fails on
  those.
- The stale-tuple-descriptor hazard of Step 0, documented at `0180:146-155`.

### Two behaviour changes to pin, not assume

- **`INSERT … ON CONFLICT DO UPDATE`** on the audited `users` table. The live
  implementation is `0190_user_name_claims.sql:30-59` (the 2-arg overload in
  `0030` is dropped at `0190:28`), and `0300_test_audit_log.sql:463-472` only
  asserts the trigger *exists* — nothing pins what an upsert logs today. Content
  is preserved, but the **ordering** changes: UPDATE rows are written during
  execution and INSERT rows at end of statement, so `audit_record_logs.id` no
  longer interleaves within a multi-row upsert.
- INSERT/DELETE audit moves from AFTER ROW to AFTER STATEMENT. Today
  `audit_i_u_d` sorts alphabetically **before** both `queue_*`
  (`0170:314-317`, AFTER ROW) and `raci_emit_on_*` (`0210:1167-1170`, AFTER
  ROW), so audit currently fires first per row; afterwards it fires once, last.
  **Both of those are AFTER ROW, not BEFORE ROW** — so "nothing depends on the
  order" is *unverified*, not established. Give the Step 0 prototype an ordering
  check, or verify it directly before relying on it.

---

## Step 5 — the validator: conditional context, and per-row caller resolution

**This step owns the whole validator half of P4**, moved here on 2026-09-04 so
P4 has a single owning plan. It edits `build_record_logic_trigger`
(`0180:29-215`), a different generator from the policy one
`plans/perf-hot-paths.md` edits (`0180:280-399`), sharing no code - so the two
plans do not collide even though both touch that file.

### 5a — build `$old`/`$mode` only when a rule references them

P4's row names this among its fixes. Worth little on the INSERT benchmark
(`$old` is `null`, `$mode` a literal) but it is P4's work and belongs here.

- **Match on substring, not an exact key** - `0320_test_computed_validation.sql:275`
  uses `{"var":"$old.label"}`.
- **Treat `value_changed` as a `$old` reference** - `0210:935-948` reads `$old`
  implicitly and returns `true` when it is absent, so
  `{"value_changed":"status"}` would silently invert.
- **There is no InitPlan in a BEFORE ROW trigger**, so this is the only
  structural win available on this path.

### 5b — the real per-row cost

The generated compute/validate trigger's real per-row cost is **not** the
`$old`/`$mode` build (worth nothing on an INSERT: `$old` is `'null'::jsonb`,
`$mode` a literal). It is `0180:174`,
`v_uid_text := rbac.user_id_or_null()::text`, which resolves the caller through
`rbac.user_id()` → `uid()` → `ensure_context_initialized` on **every row**.

`perf-hot-paths.md` already makes that chain cheaper and adds
`jl_request_context()`. Use it here — but **not as a literal swap**:
`jl_request_context()` propagates 42501, while `user_id_or_null()` deliberately
returns NULL for unauthenticated and migration contexts (`0180:172-173`). Give
`jl_request_context` a non-raising sibling for this call site, or hoist only the
`$today`/`$now` half.

This is the component with the headroom against P4's target. Measure it
separately from Steps 1 and 2.

---

## Step 6 — regenerate

`deno task extension 0.5.0`, then `deno task bundle-sql`;
`git status --porcelain -- extension/` must be clean.

---

## Tests

### New: `apps/test/tests/0448_test_statement_triggers.sql`

**Queue**
- A 3-row INSERT produces exactly 3 messages with today's payload shape, on the
  same queue.
- A 0-row `INSERT … SELECT … WHERE false` produces none **and does not raise** —
  the empty guard.
- UPDATE and DELETE still enqueue with the right `op`.
- `event_handler = 'change'` still covers all three events after the name
  fan-out.
- Deleting the mapping leaves **no** trigger behind on the target table.
- **Message identity:** `event_type` still comes from
  `queue_table_events.event_handler` (`0170:242-243`), not from `TG_OP`.

**Statement-level, positively**
- `(tgtype & 1) = 0` on the new queue triggers and on `audit_i` / `audit_d`.
  Precedent for bit tests: `0337_test_record_logic_delete_arm.sql:53-54`.
- `audit_i_u_d` is still a **row** trigger for UPDATE only: `tgtype & 1` and
  `& 16` set, `& 4` and `& 8` clear (today `tgtype = 29`).
  **Do not assert on a PK-changing UPDATE** — with UPDATE row-level it passes
  whether or not the fix is right.

**Audit**
- A 3-row INSERT and a 3-row DELETE write 3 correct rows each (`record_pk`,
  `record_id`, `user_id`).
- The CHECK constraints at `0150:63-69` are satisfied for every op — a wrong
  `INSERT … SELECT` raises rather than silently passing.
- `INSERT … ON CONFLICT DO UPDATE` on an audited table produces the right mix of
  INSERT and UPDATE rows. This is **new coverage**, not a re-verification.
- **All four triggers gone after `audit.disable_tracking`** — the control that
  `hasnt_trigger(…, 'audit_i_u_d')` no longer provides on its own.

**Validator (Step 5)**
- `$user_id` still resolves correctly for an authenticated writer, and a write
  from an unauthenticated or migration context still succeeds rather than
  raising — the non-raising-sibling requirement.

### New: `apps/test/tests/0447_test_request_context.sql`

- **`jl_request_context()` refuses an unauthenticated session** (42501) and an
  unknown subject (28000) — the gate. Positive control: it returns a populated
  object for an authenticated one.
- **`$user_id` is jsonb `null` for both NULL and empty string**, matching
  `0180:345-348`. The empty-string case is the one a naive implementation gets
  wrong.
- **Both helper signatures exist**, and a `get_record_by_id` call on a
  rule-bearing entity still works.
- **Both signatures survive a rebuild:** two successive
  `UPDATE entities SET select_rule = …`. If the two-argument form is not dropped
  at `0180:306` the second `CREATE FUNCTION` raises 42723. **Do not assert on
  `DELETE FROM entities`** — `delete_table_trigger` is BEFORE DELETE
  (`0070:1212-1213`), so the composite type drops first and cascades both away
  regardless.
- **Entity rename** rebuilds under the new name with both signatures and all
  three policies.
### Extend: `apps/test/tests/0445_test_policy_initplan_form.sql`

Nothing anywhere pins the `(SELECT …)` wrapper around `jl_request_context`, and
the entire Step 2 win depends on it — an edit to the bare call reverts it
silently. 0445 is this repo's precedent for exactly that failure mode: extend
its two catalog sweeps and its per-generator checks to strip and search
`jl_request_context\(` as well, with a positive count so the sweep cannot pass
vacuously.

**The strip pattern must tolerate a leading paren or cast.** This plan's own
emission deparses as `(SELECT jl_request_context() …)`, which strips cleanly, but
`plans/select-rule-native-predicates.md` emits
`(SELECT (public.jl_request_context() ->> '$user_id')::int)` — a `(` sits between
`SELECT ` and the call, so a literal `SELECT jl_request_context\(` pattern would
miss it, the residual search would fire, and Part 1 would fail on
`user_bookmarks_select_policy`. Write the pattern to allow the paren now, or that
plan has to widen it later.

**Match `jl_request_context\(`, not `public\.jl_request_context\(`** —
`pg_get_expr` deparses the schema qualifier out, which is why `0445:119` asserts
on a bare `select_rule_p1_initplan\(` although the function is created as
`public.%I`. A qualified pattern would match nothing and pass on everything.

### Extend: `apps/test/tests/0445_test_policy_initplan_form.sql`

Nothing anywhere pins the `(SELECT …)` wrapper around `jl_request_context`, and
the entire Step 2 win depends on it — an edit to the bare call reverts it
silently. 0445 is this repo's precedent for exactly that failure mode: extend
its two catalog sweeps and its per-generator checks to strip and search
`jl_request_context\(` as well, with a positive count so the sweep cannot pass
vacuously.

**The strip pattern must tolerate a leading paren or cast.** This plan's own
emission deparses as `(SELECT jl_request_context() …)`, which strips cleanly, but
`plans/select-rule-native-predicates.md` emits
`(SELECT (public.jl_request_context() ->> '$user_id')::int)` — a `(` sits between
`SELECT ` and the call, so a literal `SELECT jl_request_context\(` pattern would
miss it, the residual search would fire, and Part 1 would fail on
`user_bookmarks_select_policy`. Write the pattern to allow the paren now, or that
plan has to widen it later.

**Match `jl_request_context\(`, not `public\.jl_request_context\(`** —
`pg_get_expr` deparses the schema qualifier out, which is why `0445:119` asserts
on a bare `select_rule_p1_initplan\(` although the function is created as
`public.%I`. A qualified pattern would match nothing and pass on everything.

### On the extension path only

The stale-descriptor hazard cannot be seen from `deno task test`: the migrate
path commits between files, and `0300`'s content assertions run in their own
post-install transaction where the descriptor is fresh. Add one assertion to
`pgdocker/pg-ext-retest.sh` or `pg-ext-lifecycle.sh` after
`CREATE EXTENSION` + `semantius.migrate()` — that audit rows written for
`entities` after `0270` still carry `order_column` in `record`. Or sidestep it
with `EXECUTE format(...)` per Step 0 and say so.

### Existing tests this change updates

| File | Why |
|---|---|
| `0310_test_queue.sql` — **five** assertions, not one | literal trigger names at `:178`, `:230`, `:269` and `:308-313`, plus a **NOT-EXISTS control at `:350-356`** which would go falsely green under renamed triggers — the same failure mode flagged for nwind's `hasnt_trigger` below. The single-event handlers survive only because handler name == event name; `change` at `:308-313` does not |
| `0300_test_audit_log.sql:463-472`, `:244-257` | the `audit_i_u_d` name, and the post-`disable_tracking` control |
| `apps/nwind/tests/0020_test_nwind_schema.sql:373-377` | `hasnt_trigger(orders,'audit_i_u_d')` stays green but stops proving audit is off once `audit_i`/`audit_d` exist |

Unaffected, and therefore the regression net: `0420_test_audit_truncate.sql`,
`0415_test_queue_rpc_mutators.sql`, `0306_test_pgmq_operations.sql`,
`0320_test_computed_validation.sql`, `0337_test_record_logic_delete_arm.sql`,
`0301_test_audit_ddl_scope.sql`.

Note there is **no hard-coded trigger count to edit**. The `pg_trigger` count
lives in `pg-ext-lifecycle.sh`'s `SIGNATURE_SQL` fingerprint (`:76-88`, the count
at `:85`), which is computed on both sides everywhere it is used (steps 1, 2, 2b,
4 and 6b). Step 10 (`:438-470`) is a `pg_dump -s` text diff between the two
stacks, also both-sided. 2 → 4 triggers is absorbed either way.

---

## Verification

```sh
deno task connect
deno task dropall --confirm
deno task migrate --apps _core,nwind,test --verbose
deno task test
deno task extension 0.5.0 && deno task bundle-sql
git status --porcelain -- extension/          # must be empty
pgdocker/pg-cli-retest.sh
pgdocker/pg-ext-retest.sh                     # the single-transaction install path
pgdocker/pg-ext-lifecycle.sh
```

Then `deno task test --coverage` and update
`docs/pg_semantius-test-coverage.md`.

Bookkeeping in `plans/pg_semantius-open-items.md`: **close P11** and **close
P4** against their stated done-whens, having measured both. Decrement Q5 to 10.
Add `jl_request_context` to **P7**. Record the two accepted limitations (partitions/inheritance, the
upsert ordering change). No commits without asking.
