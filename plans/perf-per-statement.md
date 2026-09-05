# Plan: statement-level audit and queue triggers (P4, P13)

> **Landed 2026-09-05.** Both rows it owned are closed, restated against
> re-measured baselines rather than their stated ones. The outcome, what it
> did not solve and the accepted limitations are in
> `plans/ext-solved-items.md`; this file is kept as the record of how the
> work was reasoned about, including the two decisions that measurement
> reversed.

Written 2026-09-04. Corrected and decided 2026-09-05 — see "Decisions taken"
below. One of three plans that replaced a single oversized one. Siblings:
`plans/perf-hot-paths.md` (landed) and `plans/select-rule-native-predicates.md`
(lands after this one).

## Context

Open item **P4**: three `FOR EACH ROW` triggers each do statement-constant work
per row. Measured on a 10k-row INSERT: plain 65 ms; audit 1.5–2.0 s; queue
0.8–1.0 s; validation 0.7–1.1 s; all three together 4.25 s. Measured floors:
set-based audit insert 497 ms, `pgmq.send_batch(10k)` 114 ms.

Two of the three convert cleanly to statement-level triggers with transition
tables. The third — the generated validator — **cannot**: it is a BEFORE trigger
that writes back to `NEW` (`0180:157-159`), transition tables are AFTER-only,
and a statement trigger cannot modify rows. Its cost is attacked differently
(see Step 4).

### `plans/perf-hot-paths.md` has landed

Both rows it owned are closed: **P3** on 2026-09-05 (`has_permission` 17.9–19.4
→ 2.0 µs) and **P12** on 2026-09-05 (`evaluate_json_logic` 5.6–5.9 → ~4.0 µs per
node, median 30.3% — the *lower* edge of its estimated 30–50% band). Its test
`apps/test/tests/0446_test_rbac_hot_path.sql` is in the tree and the extension
was regenerated.

**It did not add `jl_request_context()`** — an earlier draft of this file said it
did, in two places, and that was wrong; `open-items:111` records the same
correction. **Step 1 of this plan introduces that function.** (An earlier version
made Step 1 a prerequisite for Step 4b; 4b was dropped on 2026-09-05 after
measurement, so the four steps are now independent and can land in any order.)

What genuinely depends on the sibling plan is the *arithmetic*, not an API: the
targets below assume the P3 and P12 wins are already in. They are.

The audit/NOTIFY work of `plans/audit-ddl-noise.md` has also landed (`419a2ab`).
This is the plan that edits `0150_audit_log.sql` and `pg-ext-lifecycle.sh` after
it, so re-read both before starting.

**Line numbers** were taken against the post-`419a2ab` tree and re-verified on
2026-09-05 against the post-P12 tree. The `0210_raci.sql` citations moved when
P12 landed and have been updated here; everything else still resolves. Re-check
`0210` first if anything else lands in that file.

## Decisions taken (2026-09-05)

Three questions the earlier draft left open. All three are settled; the steps
below already reflect them.

| Question | Decision | Why |
|---|---|---|
| The old **P11** ID collided with a row closed the same day | The request-context row is **P13** | `open-items` says IDs are never reused, and P11 was already spent on the `fields.searchable` rewrite fix. Renamed in `open-items` and in `select-rule-native-predicates.md` |
| The validator's per-row caller lookup vs. a context helper that must refuse anonymous sessions | **Neither — Step 4b is dropped** | Measured: the substitution saves ~2 ms at 10k rows, not the 260 ms the row assumed. With 4b gone, no non-raising helper is needed at all, which removes the whole question and a security surface with it |
| Whether one generic function may hold a static `… FROM new_table` across differently-shaped tables | **Static statement. Reversed on 2026-09-05 after measurement** | An earlier version of this file said "do not find out — use `EXECUTE format(...)`". Both halves of that were wrong; see below |
| P4's 1.0–1.3 s done-when | **Struck. Measure, then restate or close** | It was derived from a pre-P3 validator figure and from 4b's phantom 260 ms |

The third decision deleted a whole step (the prototype). **Steps are renumbered**
from the earlier draft: old Step 2 is gone, and old Steps 3/4/5/6 are now
**2/3/4/5**.

## Open items

**Owns, and therefore closes.** Both rows are owned by this plan and by no other.

| Row | Done when | Does this plan get there? |
|---|---|---|
| **P13** | The request context resolved once per statement rather than once per row, asserted structurally, and one rule row at ~54 µs from ~68 | **Yes** — Step 1. Split out of P2 on 2026-09-04 so the row has one owner; renumbered from P11 on 2026-09-05 |
| **P4** | 10k-row INSERT with all three triggers at 1.0–1.3 s, from 4.25 | **Yes, but re-derive the target first** — see below. All three of P4's named fixes (statement-level audit, `send_batch` for the queue, the conditional `$old`/`$now` build) are in this plan; nothing is credited to a sibling |

**Touches without owning.**

| Row | Effect here | Owner |
|---|---|---|
| **Q5** | one further unused-variable site (`queue_event_after_insert`, rewritten by Step 2). Base is **11, not 12** — `perf-hot-paths.md` landed and took one. So 11 becomes 10 | unowned |
| **P7** | `jl_request_context` (Step 1) is a new STABLE function that writes settings through `ensure_context_initialized`; add it to that row | unowned |

---

### Target — do not derive one, measure one

Two successive drafts of this file computed a projected total and then argued
about whether it cleared P4's 1.0–1.3 s. Both were building on a number that had
already expired. **Do not repeat that.** The rule for this plan: land Steps 1–3,
measure the 10k-row INSERT, and only then either close P4 or restate its
done-when against the evidence.

What is actually known, measured post-P3/P12 on PG 18.6:

- **Floors** are unchanged: plain 65 ms + set-based audit 497 ms +
  `send_batch(10k)` 114 ms = **676 ms**.
- **The 0.7–1.1 s validator figure is stale.** It predates P3, which cut
  `has_permission` from 17.9–19.4 to 2.0 µs and made
  `ensure_context_initialized` cheap. Anything derived from it double-counts P3.
- **The per-row context build measures 13.51 µs**, i.e. 135 ms at 10k rows —
  that is the *whole* build at `0180:174-185` (the caller lookup plus `to_jsonb`
  plus the five-key `jsonb_build_object`), not just the lookup. Of it,
  `rbac.user_id_or_null()` is 6.72 µs → **67 ms at 10k**.
- **The 260 ms attributed to the caller lookup never existed**, which is why
  Step 4b is gone. See Step 4.

A naive projection from these lands somewhere near **1.3–1.6 s**, above P4's
stated target. That number is written here to stop anyone re-deriving a
comfortable one, not to be closed against. Measure.

**The bulk win is real and large** regardless: on a single 10k-row INSERT the
audit path measures 504.7 ms row-level against 239.9 ms statement-level, ~53%.

---

## Step 1 — `0180_computed_validation.sql`: resolve the context once per query (P13)

The generated rule predicate calls `ensure_context_initialized` and rebuilds
`$today`/`$now`/`$user_id` **for every row** (`0180:340-349`).

### The helper

**One function, not two.** An earlier version of this step also specified a
non-raising `jl_request_context_or_null()` for the validator. Step 4b is gone, so
nothing needs it — and a SECURITY DEFINER that swallows `insufficient_privilege`
and returns a usable object is the highest-risk shape in this codebase. Do not
add it back without a caller.

`public.jl_request_context()` — STABLE, SECURITY DEFINER, pinned `search_path`,
COMMENT, `GRANT EXECUTE … TO semantius_user`. It returns
`{"$today":…, "$now":…, "$user_id":…}`.

**Body shape, and why it is not negotiable:**

```
PERFORM rbac.uid();                      -- see below
PERFORM rbac.ensure_context_initialized();
-- then read app.current_user_id, exactly as rbac.user_id() does at 0030:937-939
```

- **`PERFORM rbac.uid();` must appear literally.**
  `0060_test_security.sql:76-107` requires every non-trigger SECURITY DEFINER
  function in `public`/`rbac` to contain the string `rbac.uid()` in `prosrc`
  (`:85`), with escape hatches only via the hard-coded list at `:89-101` and
  `select\_rule\_%` at `:103`. A body that reaches `uid()` only indirectly
  through `ensure_context_initialized` **fails TEST 2.3**. Adding the name to the
  allowlist instead is the weakening that guard exists to prevent — don't.
  `rbac.user_id()` already opens this way (`0030:934`); copy it.
- The direct call is also *correct*, not just test-appeasing:
  `ensure_context_initialized`'s warm path returns early **without** calling
  `uid()`, so relying on it for the gate makes the refusal incidental. Cost is
  2.69 µs, paid once per statement through the InitPlan.
- It **must keep propagating 42501**: that gate is the only thing refusing an
  unauthenticated session, because the rule-branch SELECT policy
  (`0180:375-377`) carries no permission conjunct and the exception handler at
  `0180:351-355` sits *below* it.
- `$user_id` must mirror `0180:345-348` exactly: NULL **or empty string** maps to
  jsonb `null`. A naive `to_jsonb(current_setting(...)::int)` raises 22P02 on the
  empty case.

**On the object hygiene:** `REVOKE EXECUTE … FROM PUBLIC` is already the schema
default (`0010_create_core.sql:52-53`, reinforced at `0290_owner_hardening.sql:158`)
so the GRANT is the part that matters; the COMMENT requirement comes from
`0240_test_no_unsafe_functions.sql:46-72`, not from 0060. An earlier version of
this file got all three of those wrong.

Add it to open item **P7**'s list.

### Why Step 1 matters more than the INSERT benchmark shows

Measured on `user_bookmarks`: hoisting takes the predicate from 26.05 to
21.46 µs/row, **−17.6%** — if anything better than the 10–13% estimated below.
But the real payoff is elsewhere. **In a PG18 bearer session
`ensure_context_initialized()` re-derives on every call** (`0030:351-357`) at
roughly **1 ms** (`docs/bearer-mode-status.md` cost table). Per row inside a
policy that is ~10 s per 10k rows; hoisted to an InitPlan it is 1 ms per
statement — three orders of magnitude, on the path that has no other mitigation.
That, not the ~5% on the INSERT benchmark, is the argument for this step.

Hoisting does not weaken bearer safety **provided `jl_request_context()` reads
`app.current_user_id` immediately after `ensure_context_initialized()`**, the way
`rbac.user_id()` does at `0030:937-939`. Do not split those two.

### The two-argument predicate

- Generate a **two-argument** predicate `select_rule_<t>(p_row, p_ctx jsonb)`,
  keeping the one-argument form as a wrapper that supplies the context —
  `get_record_by_id` (`0070:1831-1834`) calls that form, and the `set_record`
  JsonLogic operator goes through it.
  - **Both signatures must be dropped at all four drop sites** or
    `DROP … IF EXISTS` silently no-ops and the CASCADE never removes the
    dependent policy: `0180:293`, `0180:306`, `0180:429`, `0140:209-210`.
  - **Both need their own `REVOKE`/`GRANT`/`COMMENT`** (`0180:368-373`) or 0060
    and 0240 fail.

### All three policies, not just SELECT

`build_select_rule_policy` embeds the same per-row helper call in the UPDATE and
DELETE quals too (`0180:387-389`, `0180:390-392`, both `… AND public.%I(%I.*)`),
and those are evaluated per row for every write, so leaving them alone keeps
`ensure_context_initialized` firing per row on the write path. SELECT becomes

```
USING (public.select_rule_t(t, (SELECT public.jl_request_context())))
```

(`0180:375-377`); UPDATE and DELETE keep their `(SELECT rbac.has_permission(…))
AND …` wrapper around the same two-argument call. An uncorrelated sub-select in
an RLS qual becomes a once-per-statement InitPlan — the device P1 already used
for `rbac.has_permission`. Leave the row argument as the existing `%I.*` — with a two-argument
`(composite, jsonb)` predicate both `sr(zt, …)` and `sr(zt.*, …)` create and
deparse identically, so changing it is diff for nothing.

**Do not touch `build_record_logic_trigger` in this step.**
`0180_computed_validation.sql` holds two independent generators: the
compute/validate BEFORE ROW trigger (`:29-210`) and the policy generator this
step edits (`:280-394`). They share no code. The trigger is **Step 4** of this
same plan — this is a sequencing rule, not a scope boundary, and the earlier
draft's claim that the trigger belonged to another plan was a paste from the
sibling file.

**Expected: ~68 → ~54 µs per rule row.** The marginal win is ~10–13%, not the
~21% a standalone reading suggests — `0180:340` calls the same
`ensure_context_initialized` that P3 already made cheap. The endpoint is what
matters.

---

## Step 2 — `0170_queue.sql`: enqueue once per statement

`queue_build_record_json()` (`0170:226-281`) runs a three-table lookup and a
`pgmq.send` per row, though the lookup is statement-constant and
`queue_table_events.table_name` is `unique_value` (`0170:188` — confirm this
before relying on the `LIMIT 1` argument), so the `LIMIT 1` can only ever match
one mapping.

- Rewrite it statement-level with `REFERENCING NEW TABLE AS new_rows` /
  `OLD TABLE AS old_rows`: one lookup, then
  `PERFORM pgmq.send_batch(v_queue_name, array_agg(msg))` (`0160:775`, the
  two-argument form — pass no `headers`).
- **Read the transition table with a plain static statement.** An earlier
  version of this file mandated `EXECUTE format(...)` against a cached-plan
  hazard. **Measured on PG 18.6, that hazard does not exist here** and the
  dynamic form costs +26 µs per statement (+41%). Do not reintroduce it. Why the
  analogy to `0180:146-155` fails: that code caches a *composite type
  descriptor* in a plpgsql expression's `fn_extra`; a transition table is an RTE
  resolved from the query environment carrying the source relation's OID, so
  `ALTER TABLE` invalidates the plan and a different relation re-analyzes. Two
  direct checks: 2000 statements alternating between two differently-shaped
  tables gave 2000/2000 correct payloads at no re-plan penalty, and
  INSERT → `ALTER TABLE ADD COLUMN` → INSERT in one transaction carried the new
  column. `0448` keeps both as standing tests — see Tests.
- **The empty guard is mandatory, not an optimization.** A statement trigger
  fires for zero-row statements, `array_agg` over nothing is NULL, and
  `pgmq._validate_batch_params` raises `msgs cannot be NULL or empty`
  (`0160:726`).
- **Chunk the send. A bare `array_agg` over the transition table introduces a
  hard failure the current code does not have.** `array_agg` accumulates in
  memory and does not spill. A message in the shape of `0170:262-270` measures
  **188 bytes** inside a `jsonb[]`: 10k rows is 1.8 MB, 1M rows is 188 MB held
  in the trigger's context and then passed into `send_batch` →
  `_validate_batch_params` → `_send_batch`'s `EXECUTE … USING msgs`
  (`0160:757`), so two to three live references. **Around 5.7 M rows crosses the
  1 GB varlena limit and the statement aborts** — `array size exceeds the
  maximum allowed` — where today's per-row `pgmq.send` succeeds. Aggregate and
  send in windows of ~1000 rather than one array. The audit rewrite is immune
  because `INSERT … SELECT` streams; that asymmetry is the tell.
- **Record the small-statement regression.** At one row the batch path pays the
  transition-table read plus `_send_batch`'s re-plan plus two extra plpgsql
  frames (`send_batch` 2-arg → 4-arg → `_validate_batch_params` → `_send_batch`,
  against `send` 2-arg → 4-arg): roughly **+50–150 µs on a 1-row INSERT**.
  `pgmq.send` (`0160:651-671`) already does one `EXECUTE format` per call, so
  batching genuinely removes N−1 re-plans — the win is real from a handful of
  rows up, but it is not free at N=1.
- **Keep everything table-specific a parameter, never an interpolated
  identifier.** The live temptation is `v_id_field`, read from
  `entities.id_column` (`0170:242`) which is admin-writable: reach the value as
  `to_jsonb(r) -> $n`, not `r.%I`.
- PostgreSQL forbids `REFERENCING` on a trigger defined for more than one event,
  so the `upsert` and `change` handlers (`0170:283-333`, which map to
  `INSERT OR UPDATE` and `INSERT OR UPDATE OR DELETE`) must fan out into
  per-event triggers.
  - **`CREATE OR REPLACE TRIGGER` must become `DROP TRIGGER IF EXISTS` +
    `CREATE TRIGGER`** (`0170:314`) — **not** because `OR REPLACE` cannot make
    the conversion (measured on PG 18.6: it converts a 3-event row trigger into
    a single-event statement trigger with a transition table just fine) but
    because the fan-out **renames** the triggers, and `queue_event_after_insert`
    issues no DROP at all (`0170:313-321`). Without an explicit drop the old
    `queue_<q>_<handler>_on_<table>` is orphaned and keeps firing the old
    row-level path alongside the new one.
  - **The new name is `queue_<q>_<event>_on_<table>`** — the event *replaces*
    the handler rather than being appended. Consequences, all intended:
    `insert`/`update`/`delete` mappings keep the exact names they have today
    (handler name == event name), so only `upsert` and `change` mappings change
    shape; `upsert` becomes two triggers and `change` three; and the `_on_<table>`
    suffix is preserved, which is what keeps `0140_dd_rename.sql:214-227` (it
    matches `'queue\_%'` AND `'%\_on\_<old_table>'`) renaming them on entity
    rename. The handler is recoverable from `queue_table_events`, which is where
    `0170:242-243` already reads it from.
    - The 63-byte identifier limit is **not** a reason for this. Real names in a
      migrated database top out at 39 bytes
      (`queue_raci_notify_insert_on_raci_events`), and every handler and event
      name is exactly 6 characters (`0170:189`), so the swap adds zero bytes.
      There *is* a pre-existing overflow path — a near-max 47-byte queue name
      (`0160:1109-1114`) plus a long table name exceeds 63 today, before any
      fan-out — but that is a separate bug, not this step's to fix or to justify
      itself by.
- `queue_event_after_delete()` (`0170:335-366`) must drop the new set **and** the
  old single name, so a mapping created before this change tears down cleanly.
- New functions need `REVOKE EXECUTE … FROM PUBLIC`, a COMMENT and a pinned
  `search_path` (0060, 0240).
- Record the pre-existing leak this widens: there is no AFTER UPDATE trigger on
  `queue_table_events`, so changing `event_handler` already orphans the old
  trigger. The fan-out multiplies the orphans.

---

## Step 3 — `0150_audit_log.sql`: statement-level audit for INSERT and DELETE

The row trigger re-runs a catalog query for the primary key columns on every row
(`0150:232`).

**INSERT and DELETE become statement-level** — one `INSERT … SELECT` over the
transition table with `audit.primary_key_columns(TG_RELID)` (`0150:126-149`) and
`audit.current_user_id()` (`0150:201-215`) evaluated once. **`audit_i_u_d`
stays, for UPDATE only.**

Same **static-statement** rule as Step 2, and for the same reason — see the
measurement there. This is the path where the dynamic form was measured at
+46% on single-row INSERTs (63.9 µs row-level → 66.9 µs static → 93.1 µs
dynamic), which is the PostgREST common case.

### Why UPDATE stays row-level

The audit row carries `record`, `old_record`, `record_id` and `old_record_id`,
and the CHECK constraints at `0150:63-69` *require* all four for `op = 'UPDATE'`.
Transition tables are unordered row sets whose only join key is the primary key —
which `old_record_id` exists precisely to track *changing*.
**`entities.table_name` is the primary key** (`0060_dd_schema.sql:13-14`) and
`rename_dd_table` renames it (`0140_dd_rename.sql:39-46`), and `entities` is
audited (`0150:606-610`) — so PK-changing UPDATEs on an audited table are real,
not hypothetical. (`tables` is a backward-compatibility *view* over `entities`,
`0130_create_tables_view_compat.sql:15`; AGENTS.md still describes it as a
table.) Pairing by PK would silently mis-associate before/after images in an
evidence table. Owner decision, 2026-09-04.

### Mechanics

- `audit.enable_tracking` (`0150:308-346`) now creates four triggers and
  `audit.disable_tracking` (`0150:352-372`) drops four. Keep the names fixed
  literals — that is what makes renames free (`0150:530`).
- Bodies keep `SET search_path = ''`, so every identifier stays schema-qualified
  **except the transition-table names**, which are ephemeral named relations and
  cannot be qualified. Say so in a comment, or a reviewer will "fix" it.
- **DDL audit noise roughly doubles.** `enable_tracking` goes from 2 to 4
  `CREATE TRIGGER`s and the queue fans 1 into up to 3, each firing
  `track_ddl_changes` (`0150:446-467`; `CREATE TRIGGER` is in the tag list at
  `:458`) — 2–3× more `audit_ddl_logs` rows per managed table, partly undoing
  `plans/audit-ddl-noise.md`. Accept it or scope the event trigger further; do
  not discover it after landing.
- `audit_t` (TRUNCATE, `0150:276-299`) is untouched. Note it uses no transition
  table at all — it selects constants — so it is *not* the shape to copy.
- `COALESCE(record_jsonb, old_record_jsonb)` (`0150:241`) and
  `RETURN COALESCE(NEW, OLD)` (`0150:268`) become dead but harmless once the
  function only serves UPDATE.

### No new limitation — and do not invent one

An earlier draft was going to record "transition tables are rejected on
partitions and inheritance children, so `enable_tracking` now fails on those."
**That is false for statement triggers.** Measured on PG 18.6: `CREATE TRIGGER
… FOR EACH STATEMENT … REFERENCING` is accepted on a partitioned parent, on an
individual partition, and on an inheritance child. The restriction PostgreSQL
actually enforces is narrower and applies only to row triggers:

```
ERROR:  ROW triggers with transition tables are not supported on partitions
ERROR:  ROW triggers with transition tables are not supported on inheritance children
```

Step 3 creates statement triggers, so nothing is lost and there is nothing to
record. Write the true restriction into the comment instead, so nobody re-adds
the false one.

**The real partition nuance, which is worth recording:** a statement trigger on
a *leaf* partition does not fire for rows routed through the root, so auditing a
leaf alone would be incomplete. Track the root.

### One real hazard: `enable_tracking` on an already-tracked database

`0150:338` skips the CREATE when a trigger *named* `audit_i_u_d` already exists.
After this step that name still exists (UPDATE-only), so on a database that
already carries the 3-event form, `enable_tracking` would leave it 3-event
**and** add `audit_i`/`audit_d` — INSERTs and DELETEs logged twice. Fresh
installs are unaffected and this project ships no upgrade scripts, so the
correct action is to say so explicitly in the file, or make the guard
shape-aware rather than name-aware. Do not leave it unstated.

### Two behavior changes to pin, not assume

- **`INSERT … ON CONFLICT DO UPDATE`** on the audited `users` table. The live
  implementation is `0190_user_name_claims.sql:30-59` (the 2-arg overload in
  `0030` is dropped at `0190:28`), and `0300_test_audit_log.sql:469-471` only
  asserts the trigger *exists* — nothing pins what an upsert logs today. Content
  is preserved, but the **ordering** changes: UPDATE rows are written during
  execution and INSERT rows at end of statement, so `audit_record_logs.id` no
  longer interleaves within a multi-row upsert.
- **Causality inverts for nested statements.** `audit_record_logs.ts` defaults
  to `now()` (`0150:54`) — transaction start — so within a transaction `id` is
  the only total order. Row triggers fire before statement triggers, so audit
  rows produced by a *nested* statement (for example `raci_emit_trigger_fn`
  inserting into `raci_events` from an AFTER ROW trigger, `0210:1117-1129`) get
  **lower ids than the audit rows for the statement that caused them**. In an
  evidence table that reads backwards. Record it, or switch `ts` to
  `clock_timestamp()` — but that is a schema change and needs its own decision.
- INSERT/DELETE audit moves from AFTER ROW to AFTER STATEMENT. Today
  `audit_i_u_d` sorts alphabetically **before** both `queue_*` (`0170:314-317`,
  AFTER ROW) and `raci_emit_on_*` (`0210:1209-1214`, AFTER ROW), so audit
  currently fires first per row; afterwards it fires once, last. **Both of those
  are AFTER ROW, not BEFORE ROW.** The question is answerable and was answered:
  nothing in the tree reads `audit_record_logs` from a trigger, so no dependency
  exists. Re-check with a grep before relying on it rather than re-opening it.

---

## Step 4 — the validator: build `$old`/`$mode` only when a rule needs them

**This step owns what remains of the validator half of P4.** It edits
`build_record_logic_trigger` (`0180:29-210`), the other generator in the same
file from the one Step 1 edits (`0180:280-394`). They share no code and Step 1 is
no longer a prerequisite — 4b, which consumed Step 1's helper, is gone.

P4's row names the conditional build among its fixes. Worth little on the INSERT
benchmark (`$old` is `null`, `$mode` a literal) but it is P4's work and belongs
here.

- **Match on substring, not an exact key** — `0320_test_computed_validation.sql:275`
  uses `{"var":"$old.label"}`.
- **Treat `value_changed` as a `$old` reference** — `0210:974-991` reads `$old`
  implicitly and returns `true` when it is absent, so `{"value_changed":"status"}`
  would silently invert.
- **There is no InitPlan in a BEFORE ROW trigger**, so this is the only
  structural win available on this path.

### Dropped: substituting the per-row caller lookup (was 4b)

Two earlier versions of this file made the per-row
`v_uid_text := rbac.user_id_or_null()::text` (`0180:174`) the centrepiece of the
validator work, worth ~260 ms at 10k rows, to be fixed by a non-raising context
helper. **Measured on PG 18.6, post-P3, that is wrong on both counts.**

| call | µs |
|---|---|
| `rbac.uid()` | 2.69 |
| `rbac.ensure_context_initialized()` | 1.82 |
| `rbac.user_id()` | 5.77 |
| `rbac.user_id_or_null()` | **6.72** |
| `rbac.has_permission('admin')` | 1.19 |

- `rbac.user_id_or_null()` costs **67 ms at 10k rows**, not 260. The whole
  per-row context build at `0180:174-185` — that call plus `to_jsonb` plus the
  five-key `jsonb_build_object` — is 13.51 µs/row, 135 ms at 10k.
- The substitution does not remove the chain, it **renames** it. A BEFORE ROW
  trigger has no InitPlan, so a context helper still runs `uid()` +
  `ensure_context_initialized()` once per row. Measured side by side over 20k
  iterations: today 13.51 µs/row, the substitution 13.30 µs/row — **a 2 ms
  saving at 10k rows.**
- The 260 ms figure was double-counting P3, which had already cut this chain.

Dropping it removes the only caller for a non-raising context helper, and with
it a SECURITY DEFINER that would have swallowed `insufficient_privilege` and
returned a usable object. That is a good trade at 2 ms.

**If someone wants this headroom back later**, the target is the whole 13.51 µs
build, not the caller lookup inside it, and the shape to try is the two lines
the policy generator already uses at `0180:340-341` — `ensure_context_initialized`
then read `app.current_user_id` — inside a local exception block, worth roughly
4.7 µs/row (~47 ms at 10k). It needs its own measurement and its own decision;
it is not part of this plan.

### The install path still constrains whatever replaces it

Recorded here because it cost two rounds to establish and will be needed by any
future attempt. **All application access is authenticated; the install path is
not.** `deno task migrate` and `CREATE EXTENSION` + `semantius.migrate()` run
with no JWT and write to rule-bearing tables:

- `0200_module_slug_validation.sql:22-34` adds a `validation_rules` entry to the
  `modules` entity, which fires `manage_record_logic_trigger` (`0180:236-242`)
  and installs `compute_validate_trigger` on `modules`.
- `0282_module_version.sql:48`, `:95` and `:106` then run version-bump UPDATEs on
  `modules` — fired by every entity and field write after 0282 — and
  `0284_module_slug_provision.sql:96-99` backfills slugs.
- **Do not cite `0284:105`** (`UPDATE modules SET module_slug = '' WHERE
  module_slug IS NULL`) as the proof: `0020_rbac_schema.sql:19` declares the
  column `DEFAULT '' NOT NULL`, so on every fresh-install path that statement
  matches zero rows and fires nothing. An earlier draft used it.

The blast radius is wider than `modules`: a migrated database carries
`compute_validate_trigger` on `entities`, `fields`, `modules`, `roles`,
`permission_hierarchy`, `raci_assignments` and `process_gates`, so nearly every
post-0200 migration statement crosses a validator. `rbac.user_id_or_null()`
returns NULL for all of them, which is why 4a leaves that call alone. The
codebase already treats "no user" as a normal install state:
`audit.current_user_id()` is `COALESCE(rbac.user_id_or_null(), 0)` (`0150:211`).

---

## Step 5 — regenerate

Regenerate the **current** version *in place*. Today that is `0.5.0-beta1`, but
read it from `default_version` in `extension/pg_semantius.control` rather than
trusting this line — it moves.

**Never pass a version that is not already the current one.**
`deno task extension <new-version>` *cuts a release*: it writes a new install
script, deletes the previous one, writes an upgrade script, bumps
`default_version` and records the version in `versions.json`. Only the newest
version is mutable and may be regenerated in place, which is what is wanted here.
`--strict` is accepted but ignored: the released-migration check has been on by
default since it was introduced (`packages/cli/cli.ts:413-419`). It does not bite
here — regenerating the newest version skips that check entirely, because it
compares against the *previous* version and the newest one has none below it
(`packages/cli/commands/extension.ts:91-96`, `:273`). Editing migrations and
regenerating in place is the intended workflow, and `--allow-edited-migrations`
is not needed.

```sh
VER=$(sed -n "s/.*default_version *= *'\(.*\)'.*/\1/p" extension/pg_semantius.control)
deno task extension "$VER" && deno task bundle-sql
git status --porcelain -- extension/          # must be empty
```

---

## Tests

### New: `apps/test/tests/0447_test_request_context.sql`

- **`jl_request_context()` refuses an unauthenticated session** (42501) and an
  unknown subject (28000) — the gate. Positive control: it returns a populated
  object for an authenticated one.
- **The gate holds end to end, not just in the helper.** Nothing in the tree
  pins this today: `0390_test_unauthenticated_access.sql:40-44` exercises
  `public.products`, which has **no** `select_rule`, and the only rule-bearing
  entity in the dev database is `user_bookmarks`. Add it — `SET ROLE
  semantius_user` with no claims, then `SELECT count(*) FROM <rule-bearing
  table>` must raise 42501, and 28000 for an unknown subject. Without this a
  later edit swapping in a non-raising helper opens the read path silently, and
  0445's sweep would not catch it (`jl_request_context\(` does not match
  `jl_request_context_or_null(`).
- **`$user_id` is jsonb `null` for both NULL and empty string**, matching
  `0180:345-348`. The empty-string case is the one a naive implementation gets
  wrong.
- **A forged context cannot reach a security decision.** The two-argument form
  must be granted to `semantius_user` (RLS quals run with the querying role's
  privileges), so `SELECT select_rule_t(t, '{"$user_id":1}') FROM t` is callable
  by design. It is a rule oracle, not a data bypass: RLS still filters `t`, and
  the JsonLogic `has_permission` operator (`0015_jsonlogic.sql:665-674`) resolves
  through `rbac.has_permission()` on the *session*, never from `$user_id`. The
  invariant to pin, 0332-style: `get_record_by_id` uses the **one**-argument form
  (`0070:1831-1834`), so a forged context cannot make it return a hidden row.
  Nothing pins that today.
- **Both predicate signatures exist**, and a `get_record_by_id` call on a
  rule-bearing entity still works.
- **Both signatures survive a rebuild:** two successive
  `UPDATE entities SET select_rule = …`. If the two-argument form is not dropped
  at `0180:306` the second `CREATE FUNCTION` raises 42723. **Do not assert on
  `DELETE FROM entities`** — `delete_table_trigger` is BEFORE DELETE
  (`0070:1212-1213`), so the composite type drops first and cascades both away
  regardless.
- **Entity rename** rebuilds under the new name with both signatures and all
  three policies.

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
  Precedent for bit tests: `0337_test_record_logic_delete_arm.sql:54`.
- `audit_i_u_d` is still a **row** trigger for UPDATE only: `tgtype & 1` and
  `& 16` set, `& 4` and `& 8` clear (today `tgtype = 29`).
  **Do not assert on a PK-changing UPDATE** — with UPDATE row-level it passes
  whether or not the fix is right.

**Two tables, one session** — the case the deleted prototype existed to settle,
now a regression test instead. Audit two tables of **different shapes** in one
transaction and one session, INSERT into both, and assert both sets of audit rows
carry the right columns. Do the same for two queued tables. This is what would
fail if the static-statement decision ever turns out to be wrong on a future
PostgreSQL — it is the standing guard that replaced the prototype and lets the
cheap form stay.

**Audit**
- A 3-row INSERT and a 3-row DELETE write 3 correct rows each (`record_pk`,
  `record_id`, `user_id`).
- The CHECK constraints at `0150:63-69` are satisfied for every op — a wrong
  `INSERT … SELECT` raises rather than silently passing.
- `INSERT … ON CONFLICT DO UPDATE` on an audited table produces the right mix of
  INSERT and UPDATE rows. This is **new coverage**, not a re-verification.
- **All four triggers gone after `audit.disable_tracking`** — the control that
  `hasnt_trigger(…, 'audit_i_u_d')` no longer provides on its own.

**Validator (Step 4)**
- `$user_id` still resolves correctly for an authenticated writer, and a write
  from an unauthenticated context still succeeds rather than raising. The
  migration path proves this too, but only by dying — an explicit assertion says
  *why*.

### Extend: `apps/test/tests/0445_test_policy_initplan_form.sql`

Nothing anywhere pins the `(SELECT …)` wrapper around `jl_request_context`, and
the **entire Step 1 win** depends on it — an edit to the bare call reverts it
silently. 0445 is this repo's precedent for exactly that failure mode: extend
its two catalog sweeps (`:37-47`, `:50` onward) and its per-generator checks to
strip and search `jl_request_context\(` as well, with a positive count so the
sweep cannot pass vacuously.

**The strip pattern must be `SELECT \(*jl_request_context\(`** — one or more
optional parens, not "tolerate a leading paren". Measured deparse on PG 18.6:

| emitted | `pg_get_expr` gives back |
|---|---|
| this plan's own form | `sr(zt.*, ( SELECT jl_request_context() AS jl_request_context))` — no paren, strips cleanly |
| `(SELECT f() ->> 'k')::int` | `(( SELECT (jl_request_context() ->> '$user_id'::text)))::integer` — **one** paren |
| `(SELECT (f() ->> 'k')::int)` | `( SELECT ((jl_request_context() ->> …))::integer AS int4)` — **two** parens |

`plans/select-rule-native-predicates.md:191-192` emits the first of those two
shapes and its `:199-200` names the second as the careless variant to avoid —
but **both** defeat a literal `SELECT jl_request_context\(`, so that plan's
belief that its own form is safe is also wrong. Write the paren-tolerant pattern
here and tell that plan its note needs the same fix.

**Bump `SELECT plan(12)` at `0445:32`** to match the assertions added. The runner
fails on a plan/assertion mismatch (`packages/cli/commands/test.ts:221`); the
plan asked for "a positive count" without saying to change this.

**Match `jl_request_context\(`, not `public\.jl_request_context\(`** —
`pg_get_expr` deparses the schema qualifier out, which is why `0445:119` asserts
on a bare `select_rule_p1_initplan\(` although the function is created as
`public.%I`. A qualified pattern would match nothing and pass on everything.

**There is only one helper to sweep for.** The non-raising sibling an earlier
version specified was dropped with Step 4b, so no exclusion is needed. If one
ever comes back, note that `jl_request_context\(` does not match
`jl_request_context_or_null(` — the sweep would pass while the gate was gone.

### On the extension path

Both statement triggers use the static form, so the descriptor question is
answered by test rather than by construction — which makes this assertion
**required, not optional**. Add it to `pgdocker/pg-ext-retest.sh` or
`pg-ext-lifecycle.sh` after `CREATE EXTENSION` + `semantius.migrate()`: audit
rows written for `entities` after `0270` must still carry `order_column` in
`record`. It is the only place the single-transaction install path is exercised,
and it costs one line.

The install path is also the standing test for the static-statement decision: a
`CREATE EXTENSION` + `migrate()` run is one transaction in which `0270` adds
`entities.order_column` between audited writes, which is exactly the descriptor
case the dynamic form was going to guard against.

### Existing tests this change updates

| File | Why |
|---|---|
| `0310_test_queue.sql` — **five** assertions, not one | literal trigger names at `:178`, `:230`, `:269` and `:311`, plus a **NOT-EXISTS control at `:353`** which would go falsely green under renamed triggers. The single-event handlers survive only because handler name == event name; `change` at `:311` does not |
| `0300_test_audit_log.sql:469-471`, `:244-246` | the `audit_i_u_d` name, and the post-`disable_tracking` control |
| `apps/nwind/tests/0020_test_nwind_schema.sql:373-377` | `hasnt_trigger(orders,'audit_i_u_d')` stays green but stops proving audit is off once `audit_i`/`audit_d` exist |

**The `select_rule` test family is the regression net for Step 1's drop sites.**
`0291_test_ddl_rename_deep.sql:196/384/390`, `0295_test_entity_changes.sql:237/273/301/330/427/443`,
`0330_test_select_rule.sql:37` and `0338_test_enable_managed_builds_select_rule.sql:42/50`
all assert on `proname` alone, so a second overload does not break them. The
three **NOT EXISTS** assertions (`0291:384`, `0295:330`, `0295:443`) are exactly
what catches a drop site that removed only one of the two signatures — do not
weaken them to accommodate the overload.

Unaffected, and therefore the rest of the regression net: `0420_test_audit_truncate.sql`,
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
VER=$(sed -n "s/.*default_version *= *'\(.*\)'.*/\1/p" extension/pg_semantius.control)
deno task extension "$VER" && deno task bundle-sql   # regenerate, never cut a new version
git status --porcelain -- extension/          # must be empty
pgdocker/pg-cli-retest.sh
pgdocker/pg-ext-retest.sh                     # the single-transaction install path
pgdocker/pg-ext-lifecycle.sh
```

Then `deno task test --coverage` and update
`docs/pg_semantius-test-coverage.md`.

Bookkeeping in `plans/pg_semantius-open-items.md`: **close P13** and **close
P4** against their stated done-whens, having measured both. Decrement Q5 to 10.
Add `jl_request_context` to **P7**. Record
the accepted limitations (partitions/inheritance on `enable_tracking`, the upsert
ordering change). Move both closed rows to `plans/ext-solved-items.md` with their
original text — deleting a row without adding it there is not allowed.

One correction still owed to a sibling: `plans/select-rule-native-predicates.md:384`
credits the 0445 sweep extension to `perf-hot-paths.md`, which contains no
`jl_request_context` at all. It is this plan's Step 1. Fix that line when this
lands, together with the paren-pattern note above.
No commits without asking.
