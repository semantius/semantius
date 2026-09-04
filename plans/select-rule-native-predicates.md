# Plan: native predicates for select_rule — and whether to build them at all

Written 2026-09-04. One of three plans that replaced a single oversized one.
Siblings: `plans/perf-hot-paths.md` and
`plans/perf-per-statement.md`, both of which land first.

**This plan starts with a go/no-go, not with work.** Everything below the
decision section is the design as it stood after six review rounds, preserved so
the analysis is not lost — but every blocker any of those rounds found landed
here, and the cost is materially different from what it looked like when the
work was first approved.

---

## Open items

**Owns, and therefore closes.** One row, owned by this plan alone since P2 was
split on 2026-09-04.

| Row | Effect of this plan |
|---|---|
| **P2** | **This is the row this plan exists to close**, either way it goes. On a GO: satisfy part (b) of the done-when — "100k-row scan under a compilable rule at about 20 ms, rule columns indexable" — noting that only shape 1 *variant 1* becomes indexable; variant 2 is fast but not. On a NO-GO: close it as **scope-changed**, recording the measured post-`perf-per-statement` baseline, that the general "compile JsonLogic" fix was rejected, and the accepted limit that entities with a `select_rule` do not scale to full scans. Part (a) was already satisfied by `plans/perf-per-statement.md` (P11). |

**Touches without owning.**

| Row | Effect here | Owner |
|---|---|---|
| **P5** | on a GO, adds about ten DDL events per field on rule-bearing entities | unowned |
| **P7** | untouched; `jl_request_context` was already added to that row by `plans/perf-per-statement.md`, and the recognizers are neither SECURITY DEFINER nor write settings | unowned |
| **B13** | referenced only, for the tripwire's CRLF normalization | closed |

P2 is the only High row this plan owns, and it closes in one of two quite
different ways. Decide first.

---

## The decision

The two sibling plans take a 100k-row scan of a rule-bearing table from about
5 s to about 2.5–3 s, by making the existing interpreter cheaper. This
plan would take it to about **20 ms**, and make rule columns **indexable**, by
emitting a native SQL predicate into the RLS policy for rules matching a known
shape.

**What it costs, now that it is understood:**

- A column name enters an RLS policy for the first time in this codebase. That
  creates a **column-level dependency the interpreted helper never had**, and the
  data-dictionary field lifecycle was written assuming no such dependency
  exists. Consequence: a three-arm trigger on `fields`, without which
  `delete_dd_field`'s `DROP COLUMN … CASCADE` (`0070:1163-1167`) silently drops
  the entity's policies and leaves RLS enabled with none — every read returns
  zero rows, nothing raises.
- A **permanent split**: the policy is native while `get_record_by_id`
  (`0070_dd_functions.sql:1831-1834`) keeps calling the interpreted helper. Two implementations of
  the canonical predicate on either side of the boundary
  `0332_test_definer_read_helper_select_rule.sql` exists to police.
- A registry, a dispatcher, per-shape equivalence proofs, two completeness
  tripwires, an md5 drift tripwire and a three-way differential test.

**What it buys today:** speed for **one shipped rule** (`user_bookmarks`,
`0280_user_bookmarks.sql:45`) and four test entities. The value is in future rule-bearing entities,
not current ones.

**Decide against a measured number.** After the two sibling plans land, measure a
100k-row scan under `{"==":[{"var":"col"},{"var":"$user_id"}]}`. "Is 20 ms worth
the coupling above" is a different question at 2.5 s than it was at 5 s, and the
5 s figure comes from the 2026-09-02 review, before any of this work.

If the answer is no: close P2 as scope-changed, record that entities with a
`select_rule` do not scale to full scans, and delete the rest of this file. Under
PostgREST every query is paginated, so the pathological case is a full scan or a
`count(*)`.

---

## Prerequisites, if it is built

`plans/perf-per-statement.md` must have landed. This plan uses
`public.jl_request_context()` and the two-argument
`select_rule_<t>(p_row, p_ctx jsonb)` that its Step 1 introduces.
`plans/perf-hot-paths.md` lands before that, so both are in place.

---

## Not a compiler

An earlier draft proposed a general JsonLogic→SQL compiler. **Rejected.** It is a
second implementation of a 44-operator language whose definition is split across
`0015_jsonlogic.sql` and the `CREATE OR REPLACE` at `0210_raci.sql:380-1020`, so
the two drift silently, and four review passes found semantic divergences in the
draft. Verified divergences of the obvious mapping, for the record:

| Rule | Row | Interpreter | Naive native | Cause |
|---|---|---|---|---|
| `{"!=":[{"var":"label"},"x"]}` | `label` NULL | **true** | `label <> 'x'` → false | `jl_loose_eq(null,'x')` false, negated |
| `{"<":[{"var":"n"},5]}` | `n` NULL | **true** | `n < 5` → false | `jl_to_number('null')` = **0** (`0015:46`) |
| `{">":[{"var":"label"},"9"]}` | `label='10'` | **true** | `label > '9'` → false | `>` coerces **both** sides via `jl_to_number` (`0210:712`) |
| `{"===":[{"var":"n"},"5"]}` | `n=5` | **false** | `n = 5` → true | `===` requires equal `jsonb_typeof` (`0210:684`) |

`<`/`<=` also have a three-argument between form (`0210:726-747`).

Instead: a **registry of recognizers**, each matching one literal rule shape
exactly. Anything unrecognized is left exactly as it is today.

---

## Structure

- `public.jl_shape_sql(p_rule jsonb, p_table_name text) RETURNS text` — tries
  each recognizer in order, returns SQL text or NULL.
- One recognizer per shape: `jl_shape_owner_scoped(p_rule, p_table_name)`, etc.
- **Every one of these needs `REVOKE EXECUTE … FROM PUBLIC`, a COMMENT and a
  pinned `search_path`.** `0060_test_security.sql` Test 2.2 is a **blanket
  sweep** for any function in `public`/`rbac` executable by PUBLIC, not a
  definer-only check; 0240 requires the `search_path` and COMMENT. No `GRANT` is
  needed — the recognizers run only inside `build_select_rule_policy` (SECURITY
  DEFINER, `0180:394`); what `semantius_user` evaluates is the *emitted text*,
  which names `jl_request_context()` and `rbac.has_permission()`, both already
  granted.
- `build_select_rule_policy` uses the returned text for **all three policies** —
  SELECT (`0180:376-378`) and the UPDATE/DELETE pair (`0180:385-392`), which keep
  their `(SELECT rbac.has_permission(edit)) AND …` wrapper. Emitting native for
  SELECT only would split the predicate *within one function*, so any divergence
  becomes "denied on read, permitted on update" — the I2 class `0180:380-384`
  exists to close.
- The `select_rule_<t>()` helper is **still generated for every rule**, because
  `get_record_by_id` calls it unconditionally and the `set_record` operator goes
  through it.

Adding a later shape touches: one function with its REVOKE, COMMENT and
`SET search_path`; one dispatcher line; one entry in the test's expected-name
array; a fixture; **and a differential matrix plus near-miss controls with its
own NULL analysis** (rule 4 mandates the proof). No hand-edited file outside
`0180_computed_validation.sql` and the test. Realistically 2–3× the "one function,
one line" reading — still far cheaper than a compiler.

---

## Rules every recognizer obeys

1. **Exact structural match, or NULL.** Implement as **jsonb template
   equality**: pull the variable parts out with `#>>`, rebuild the template with
   `jsonb_build_object`, compare the whole rule with `=`. Two statements per
   variant, and `jsonb =` rejects extra keys, extra operands and swapped
   operands for free. **Never `@>`** — jsonb array containment is
   order-insensitive and accepts extra elements, so it would admit the
   swapped-operand rule the near-miss control must reject. Say that in the file.
2. **The shape must consume the request context.** A separate
   `(SELECT jl_request_context()) IS NOT NULL AND …` conjunct does **not** work
   as an auth gate: an InitPlan is evaluated lazily, so once the predicate
   becomes an index condition the gate is left as a filter over the index output.
   Requiring the shape itself to reference `$user_id`/`$today`/`$now` or
   `has_permission` makes the gate intrinsic.

   **The correct claim is parity with today, not an absolute guarantee:** the
   gate fires on the first tuple the scan filters, or *before* the first tuple
   when the predicate becomes an index condition (runtime index keys are
   evaluated in `ExecReScanIndexScan`, even on an empty table). On any plan that
   yields zero tuples neither fires — that is exactly today's behavior, where
   `select_rule_<t>()` is also never called. Consequence to accept and write
   down: the same query on the same data can answer 42501 or zero rows depending
   on the plan chosen, which is why the gate test *must* insert a row first.

   Do **not** cite `0390_test_unauthenticated_access.sql:41-45` as the existing
   net — it targets `public.products`, which has no `select_rule`.

   Note this **permanently excludes context-free rules**, including
   `0445_test_policy_initplan_form.sql:101`'s own control rule. A deliberate
   consequence, not a gap to close later.
3. **Catalog-checked, on the actual column type.** Resolve every referenced
   column against `pg_attribute` and accept an explicit `atttypid` allowlist
   (`int4`, optionally `int8`) — **not** the field's `format`.
   `format_to_data_type` (`0070:14-54`) falls through to `TEXT` for anything
   unmatched, and a native `text = int` has no operator, so `CREATE POLICY` would
   fail *inside* a `fields` trigger. A `boolean` column diverges too
   (`jl_loose_eq` coerces via `jl_to_number`, `0015:83-84`).

   This check is also what stops migration `0280` failing: the entity row
   carrying the rule is inserted at `0280:45`, the `user_id` field only at
   `0280_user_bookmarks.sql:56`, so at build time the column does not exist yet.
4. **Equivalence proved per shape, including NULLs**, pinned by a differential
   test.

---

## Shape 1 — owner-scoped (the one to implement)

| Rule | Emitted |
|---|---|
| `{"==":[{"var":"<col>"},{"var":"$user_id"}]}` — shipped, `0280_user_bookmarks.sql:45` | `<col> = (SELECT public.jl_request_context() ->> '$user_id')::int` |
| `{"or":[{"has_permission":"<p>"},{"==":[{"var":"<col>"},{"var":"$user_id"}]}]}` — 4 test uses (`0330`, `0331`, `0332`, `0338`) | `(SELECT rbac.has_permission('<p>')) OR <col> = (SELECT public.jl_request_context() ->> '$user_id')::int` |

The emission contains a literal `public.jl_request_context()` call — there is no
`ctx` binding in a policy expression, and it is that call, not a jsonb deref,
that carries the gate of rule 2.

**Keep the cast outside the sub-select**, as written above. The obvious form
`(SELECT (public.jl_request_context() ->> '$user_id')::int)` puts a `(` between
`SELECT ` and the call, which defeats 0445's strip-then-search sweep and fails
its Part 1 on the shipped entity. `(SELECT … ->> …)::int` keeps the call directly
after `SELECT` and is otherwise identical.

**Equivalence.** `<col>` is `int4` by rule 3; `$user_id` is an integer and
non-null wherever this runs — **the premise is not rule 2's gate but the ordering
at `0030:362-379`**: `ensure_context_initialized` raises 28000 for a subject with
no `users` row and sets `app.current_user_id` *before* `app.context_initialized`,
so the warm-path early return can only be taken with the id populated.
`perf-hot-paths.md` edits that path; any future change there invalidates this
proof.

Both sides being jsonb numbers, `jl_loose_eq` reduces to `a = b` (`0015:75`). A
NULL column becomes jsonb `null` against a number, types differ, so `0015:77`
returns false; native `col = 5` yields NULL, which RLS also reads as false.

**The one genuine divergence, to be recorded and tested:** if `$user_id` *were*
jsonb `null` as well, both types are `'null'`, so line **75** fires —
`'null'::jsonb = 'null'::jsonb` is **TRUE**, while native `NULL = NULL` is false.
Unreachable while the invariant above holds (it needs a hand-forged partial
`app.*` cache), but it is the case a future shape author will copy the proof for.

**Expected gain differs by variant.** Variant 1 becomes an index condition:
~5 s → ~20 ms on 100k rows, column indexable. Variant 2 cannot —
`(SELECT rbac.has_permission('p'))` is a SubPlan boolean and
`generate_bitmap_or_paths` needs every OR arm index-matchable — so it stays a
seq-scan native filter: fast (~20 ms on 100k) but **not indexable**.

---

## Shape 2 — temporal validity (identified, deferred)

`{">=":[{"var":"<col>"},{"var":"$today"}]}` and the `$now` variant, from
`0335_test_select_rule_temporal.sql:31,66`. Deferred, with the reason recorded so
the next person does not assume it is easy: `>=` coerces **both** sides through
`jl_to_number` (`0210:719-724`), which renders a date as text, does
`extract(epoch FROM txt::timestamp)`, and returns **0** for null (`0015:18-50`).

**Only the `COALESCE(col, 'epoch')` route is viable** — `is_nullable('date')` is
TRUE (`0070:94-98`), so a dd-managed date column can never be `attnotnull`. The
timezone concern is narrower than it first appears: `to_jsonb` renders both sides
in the same session `TimeZone` before `txt::timestamp` strips the offset, so
ordering is preserved except across a DST transition falling between the two
values. The NULL argument alone justifies deferring.

---

## The shared prerequisite: a fields-lifecycle hook — three arms, all AFTER

Naming a column in a policy is new coupling the field lifecycle was not written
for. Modelled on `dd_label_fn_sync_field` / `zzz_label_fn_field_*`
(`0145:1049-1096`) — the same shape, not a novel construct — with the
`entities.select_rule <> '{}'` gate **inside** the function, because a trigger
`WHEN` clause cannot query `entities`.

- **AFTER INSERT** — fields arrive after the entity row, so a rule that could not
  be recognized at entity-insert must be retried once its column exists. Must
  sort after `add_field_trigger` (`0070:794-797`), which runs the
  `ALTER TABLE … ADD COLUMN`; a `zzz_` prefix guarantees that.
- **AFTER DELETE — mandatory.** `delete_dd_field` runs `DROP COLUMN … CASCADE`
  from a BEFORE DELETE trigger (`0070:1163-1183`). Against a native policy the
  CASCADE drops all three policies, leaving RLS on with none — silent, total,
  permanent read failure.
- **AFTER UPDATE, with `field_name` in the `WHEN` clause.** Keep the clause tight
  or `rename_dd_reference_tables` (`0140:271-273`) rebuilds a policy for every
  referencing entity on every table rename.

**There is no fourth arm.** A review round claimed a `format` change would start
failing against a native policy, because PostgreSQL refuses to alter the type of
a column used in a policy definition. The hazard class is real but the path is
**unreachable**: the only `ALTER TABLE … ALTER COLUMN … TYPE` in the tree is
`0070:881`, and it is dead code — `update_dd_field` is `CREATE OR REPLACE`d at
`0140:535` and `0145:360`, and the installed body raises instead
(`0145:459-468`); a type-changing `format` edit is rejected a step earlier still
by `validate_field_rename_and_format` (`0140:496-501`), whose own comment says
so.

**That makes the validator load-bearing for this plan.** Add a comment there
recording it: relaxing that rejection would also break the native `select_rule`
policies.

**The rename arm asserts a limitation, not an invariant.** Nothing rewrites
`entities.select_rule` on a field rename — the only `SET select_rule` in `0140`
(`:322-326`) is gated on `LIKE '%set_record%'` and concerns entity names. So
after a rename the rule still names the old column, rule 3's catalog lookup
fails, the recognizer returns NULL, and the interpreted helper resolves
`{"var":"old_name"}` to jsonb `null`.

**For variant 1 that hides every row; for variant 2 it does not** — `or`
short-circuits on the first truthy operand (`0210:469-478`) and `has_permission`
returns true for a holder (`0210:915-921`), so an admin still sees everything.
Four of the five in-tree fixtures are variant 2 (`0330:22`, `0331:34`,
`0332:35`, `0338:23`); only the shipped `0280_user_bookmarks.sql:45` is variant
1. So **pin the rename assertion to a variant-1 fixture, or to a non-admin
caller** — an unscoped "all rows hidden" fails by construction. Assert the
accepted behavior (*renaming a column named in `select_rule` disables the
comparison arm, fail-closed*) and **do not** add an "owner still sees their own
row" control: it would fail by design.

Cost: roughly ten extra DDL events per field on a rule-bearing entity — note it
in open item **P5**'s row.

---

## Tests

### New: `apps/test/tests/0449_test_select_rule_shapes.sql`

- **The gate.** Unauthenticated read of a table using a registered shape raises
  42501; an unknown subject raises **28000** (the distinction
  `0390_test_unauthenticated_access.sql:160-171` already pins). **Insert at least
  one row first** — on a zero-tuple scan neither the old nor the new predicate
  fires. Positive control: the same on an unregistered rule.
- **The fields hook, all three arms**, each failing-capable: add a field whose
  column the rule names → the policy becomes native; **delete** it → all three
  policies still exist (this one fails silently and catastrophically without the
  hook); **rename** it → the fail-closed behavior above.
- **Three-way differential** — two oracles are not enough, because the policy is
  native while `get_record_by_id` stays interpreted. Over the **agreeing**
  fixtures (NULL owner, own row, another's row, admin and non-admin caller):
  `visible-through-policy` ≡ `get_record_by_id(...) IS NOT NULL` ≡
  `jl_truthy(evaluate_json_logic(rule, to_jsonb(row) || ctx))`.
  **Do not drive this from `0015_test_jsonlogic.json`** — that corpus is plain
  jsonb data and exercises nothing the registry emits.
- **The both-null case gets its own asymmetric assertion**, not a row in the
  matrix above — it is the one place the three oracles are *known* to disagree,
  so folding it in makes the `≡` assertion unpassable. Set up a NULL-owner row
  and a genuine warm context, then blank `app.current_user_id` alone (leaving
  `app.context_initialized` and `app.current_external_id` intact so the
  revalidation still takes the shortcut). Assert the three values individually:
  policy → hidden, interpreter → visible, `get_record_by_id` → returns the row.
  Characterize it in the comment as a **bounded I1 canonical-predicate
  divergence**, reachable only through a forged partial cache.
- **Recognized / not recognized**, the control that stops the rest passing
  vacuously. **Sweep all three policies by name** — `<t>_select_policy`,
  `<t>_update_policy`, `<t>_delete_policy` — asserting each qual contains the
  bare column and none contains `select_rule_`; near-miss variations (operands
  swapped, a third operand, a different operator, a `text` column) leave all
  three naming `select_rule_`.
  **This is the only net for the "native in all three policies" decision.**
  `0331_test_select_rule_write_protection.sql` does *not* protect it: all eleven
  of its assertions are behavioural, and a SELECT-only native emission computes
  the same answers.
- **Write-side differential for variant 1.** Not first-time cover —
  `0380_test_user_bookmarks.sql:169-205` already exercises exactly this
  behaviourally (own-row UPDATE as positive control, cross-user UPDATE and
  DELETE both affecting zero visible rows) under the shipped variant-1 rule. Its
  value here is that those writes now run against a **native** UPDATE/DELETE
  qual (`0180:385-392`) and must still agree with the interpreted oracle. Keep
  0380 in the unaffected list as the behavioural net; add the differential.
- **The registry is complete and wired**, two tripwires. The sorted list of
  `pg_proc` names matching `jl\_shape\_%` **in `public`**, excluding
  `jl_shape_sql`, equals an expected array; and `jl_shape_sql`'s `prosrc`
  mentions every one of them. State both honestly: the second is a `prosrc`
  heuristic (a name in a comment satisfies it), and the first forces the author
  into this file but cannot verify they added a *fixture* rather than widening
  the array. Procedural enforcement — the array and the fixtures live together.
- **Drift tripwire**: `md5(replace(prosrc, E'\r\n', E'\n'))` of `jl_loose_eq`,
  `jl_to_number` and `jl_truthy` (whole body — short and high-signal) plus the
  `==` and `var` branches of `evaluate_json_logic`, against a recorded baseline,
  with the failure message saying *re-derive every `jl_shape_*` equivalence proof
  before re-baselining*. Normalize line endings — `prosrc` is the migration
  file's literal text, and `prosrc` carries CRLF on the migrate path and LF on
  the `CREATE EXTENSION` path (B13 is closed in `plans/ext-solved-items.md`; the
  residue is tracked under R7). **Cut the
  two branches out by anchoring on the banner comments**
  (`-- ===================== == =====================` to the next banner), not
  by character offset. Do **not** hash all ~640 lines: it would fire on any
  unrelated operator addition and train people to re-baseline reflexively.
  Take the baseline after `perf-hot-paths.md` Step 3, which edits that function
  deliberately. Know what it does not cover: the operator extraction
  (`0210:427-438`) and the shared operand loop (`0210:598-612`) feed the hashed
  branches but are not themselves hashed. **Add the `or` (`0210:469-478`) and
  `has_permission` (`0210:915-921`) branches to the hashed set** — variant 2's
  equivalence proof rests on both, each is under ten lines, and both are
  banner-anchored like the others.
- **The helper still exists for recognized shapes** — a direct call and a
  `get_record_by_id` call both succeed.

### Existing tests this change updates

| File | Why |
|---|---|
| `0338_test_enable_managed_builds_select_rule.sql:46-52` | asserts `qual LIKE '%select_rule_em_rule_test%'`; its rule **is** shape 1 variant 2, so the helper name leaves the qual. Its behavioural assertion at `:67-70` stays green |
| `0445_test_policy_initplan_form.sql` | **a required edit, not just a re-run.** Its `:114-121` assertions do still hold (its own rule matches no template), but **Part 1 (`:37-47`) is a catalog-wide sweep whose header names 0280 as in scope**. `perf-hot-paths.md` extends that sweep to strip `SELECT jl_request_context\(`; a careless variant-1 emission puts a `(` between `SELECT ` and the call, so the strip misses, the residual search fires, and Part 1 fails on `user_bookmarks_select_policy`. See the emission note under Shape 1 |

Unaffected, and therefore the regression net: `0330`, `0331`, `0335` (shape 2,
deferred), `0320`, `0337`, `0291`, `0295`, `0380`.

**`0332_test_definer_read_helper_select_rule.sql` is not merely unaffected — it
becomes load-bearing**, as the standing regression net for the accepted
policy/helper split, complemented by the three-way differential above. Keep this
note next to the list, or the next reader deletes it as redundant.

### Indexability

No `EXPLAIN` precedent exists anywhere in `apps/test/tests/`, and the request
role cannot create an index. Prove it in `pgdocker/pg-ext-lifecycle.sh`: entity,
index on the rule column, `ANALYZE`, assert `EXPLAIN` output contains
`Index Cond`. **Use variant 1** — variant 2 is a SubPlan boolean and can never be
an index condition.

---

## Verification

The standard sequence (see `plans/perf-hot-paths.md`), plus the lifecycle script
for the indexability step.

Bookkeeping in `plans/pg_semantius-open-items.md`: close **P2**, recording the
measured before/after and that the general "compile JsonLogic" fix was rejected
in favour of the registry, with shape 2 named as the next candidate. Add the
fields-hook DDL cost to **P5**'s row. No commits without asking.
