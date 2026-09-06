# Coverage: answer the two questions, hit the two targets

Written 2026-09-06 19:38, revised 20:05 after review. Replaces
`2026-09-06-1633-test-coverage.md`, whose measurements were sound and are reused, and whose
scope was not: thirteen changes, ten of them never asked for.

## The request this plan serves

Verbatim, 2026-09-06 15:18:

> "then let a subagent analyze the coverage and think about how we can improve it.
> especially why are 2 tables missing? why are functions only 63%? I think for table we
> should have 100%, functions probably as well or at least > 90%"

Four deliverables:

1. Why are 2 tables missing?
2. Why are functions only 63%?
3. Tables to 100%.
4. Functions to 100%, or at least 90%.

Anything that does not serve one of those four belongs at the bottom, under
"Not requested" - including work this plan believes is worth doing.

## Measurements

From `./pgdocker/pg-cli-retest.sh --coverage`, run 2026-09-06 18:21 on a clean tree. The
suite passed: 88 files, 2275 assertions. Every figure below was read out of
`coverage/summary.json` by script.

| | Called / total | % |
|---|---|---|
| Functions, as reported | 194 / 304 | 63.8 |
| Statements, as reported | 1897 / 2252 | 84.2 |
| Tables, as reported | 42 / 44 | 95.5 |

---

## Answer 1: why 2 tables are missing

**Both are vendored pgmq archive tables**: `pgmq.a_events` and `pgmq.a_raci_notify`. They
are the only untouched tables in the universe - every one of the 37 tables Semantius itself
owns is touched.

`pgmq.create()` builds an archive table `a_<queue>` beside every queue table `q_<queue>`
(`apps/_core/migrations/0160_pgmq.sql:1472`, via `create_non_partitioned` at `:1139`). Two
queues ship and persist past the suite: `raci_notify` (`0210_raci.sql:1248`, provisioned by
the queue trigger at `0170_queue.sql:74`) and `events` (the Northwind demo module). Their
queue tables are busy - `q_raci_notify` sees 8 inserts, 7 updates, 5 deletes - but nothing
ever archives from them.

The archive *feature* is tested. `apps/test/tests/0306_test_pgmq_operations.sql:64-69` and
`apps/test/tests/0415_test_queue_rpc_mutators.sql:41-68` both archive a message and read it
back. They do it on throwaway queues (`ops_q`, `rpc_q`) created inside the test, and every
pgTAP file here ends in `ROLLBACK`. The coverage universe is enumerated *after* the suite
finishes (`packages/cli/commands/coverage.ts`, `universeTablesSql()` called from
`collect()`), so those archive tables no longer exist when the denominator is built. Only
the two permanent archives survive to be counted, and no test writes them.

So: not dead code, not unreachable, and not ours.

## Answer 2: why functions are only 63%

**The number is a measurement artifact, in full.** All 110 never-called functions are
either vendored or generated - verified by parsing `coverage/summary.json`, and the
"neither" bucket is empty:

- **37 are vendored pgmq** (`0160_pgmq.sql`, pgmq v1.11.1): partman, partitioning, unlogged
  queues, FIFO indexes, grouped reads, topic bindings, and unused overload variants of
  entry points that are already covered. Semantius exposes none of it.
- **73 are generated** by the data dictionary at runtime, and they are not all label
  functions - the exact split is **27 `_label(rec <t>)` + 45 `<fk>_label(rec <t>)` + 1
  `select_rule_user_bookmarks(p_row user_bookmarks)`**. That last one is the 1-argument
  convenience overload of a select-rule policy function
  (`0180_computed_validation.sql:451`), `LANGUAGE sql SECURITY DEFINER`, granted to
  `semantius_user`. Its 2-argument sibling has 25 calls; the wrapper has none. It is the
  one never-called function that is neither vendored nor a label, and it is a reachable
  definer entry point, so change C has to cover it deliberately rather than sweep past it.

The hand-written universe is **142 functions, 142 called - 100.0%**.

| Denominator | Called / total | % |
|---|---|---|
| As reported today | 194 / 304 | 63.8 |
| Excluding vendored pgmq | 156 / 229 | 68.1 |
| **Hand-written only** | **142 / 142** | **100.0** |

Why the generated group looks untested: `apps/test/tests/0370_test_composed_labels.sql` is
a thorough label test - `SELECT plan(35)` over five hand-built entity shapes, asserting
composition, spine re-pointing and viewer-relative leakage - but it rolls back like every
file here, so the functions it exercised are gone before the universe is enumerated, while
the *shipped* entities' label functions sit in the denominator uncalled.

These are not inlining false negatives. The generated functions carry
`SET search_path = public` (`0145_managed_enable.sql:868`, `0180_computed_validation.sql:453`),
and `inline_function()` refuses any SQL function with a non-null `proconfig`. Confirmed
empirically: six `_label` functions do register calls in `pg_stat_user_functions`, which is
only possible if they are not inlined.

---

## The arithmetic that decides the plan

| | Tables | Functions |
|---|---|---|
| Today | 42/44 = 95.5% | 194/304 = 63.8% |
| Sweep every generated function (change C) | unchanged | 267/304 = **87.8%** |
| Take vendored pgmq out of the headline (change A) | 37/37 = **100%** | 156/229 = 68.1% |
| **Both** | **100%** | **229/229 = 100%** |

**Why pgmq comes out of the headline.** The argument stands on its own, before any target
is considered: pgmq v1.11.1 is third-party code that happens to be inlined into a migration
instead of installed as an extension. It belongs in a coverage denominator exactly as much
as `node_modules` or `vendor/` does, which is to say not at all. The proof that this is a
measurement problem and not a testing problem is the hand-written figure - **142/142 =
100%** - which is true regardless of what anyone wants the headline to say.

The requested floor is then a *consequence*, not the premise: with pgmq in the denominator
the ceiling is 87.8%, and the only way past 90% would be calling pgmq overloads Semantius
does not expose. That would be metric-chasing. With pgmq reported beside the headline
rather than inside it, both targets are met by testing real code.

**This is the one thing in the plan that changes the meaning of a permanent number**, so it
is stated rather than slipped in: after change A, "function coverage" names Semantius code
only. If you would rather keep pgmq in the denominator forever as a standing reminder, say
so and changes A and C both change shape - the >90% target then cannot be met honestly and
should be restated against the hand-written universe instead.

---

## Change A: separate vendored pgmq from the headline

**What is true today.** `packages/cli/commands/coverage.ts:159` sets
`CORE_SCHEMAS = ["public", "common", "rbac", "audit", "pgmq"]`, and both
`universeFunctionsSql()` (`:565`) and `universeTablesSql()` (`:607`) take everything in
those schemas. So 75 functions, 296 statements and 7 tables of third-party code sit in the
denominator of every headline ratio.

**The fix.** `pgmq` keeps being enumerated - the queue RPCs really do depend on it behaving,
and dropping it would hide a regression on the next version bump, which in this repo is a
migration edit - but it is reported as its own line:

1. A `vendored` flag on each `FunctionCoverage` / `TableCoverage` row, set from the schema.
2. `totals` computed over the non-vendored universe; a new `vendored` block beside it in
   `summary.json` carrying the same three ratios for pgmq.
3. `uncovered.md` keeps its pgmq sections, under a heading that says they are not counted.
4. The console prints both lines, so nobody reads the headline as covering pgmq.

**What this also moves, stated up front.** Change A is not confined to functions and tables.
pgmq carries 296 statements, of which 159 executed, so the **statement headline moves from
1897/2252 = 84.2% to 1738/1956 = 88.9%** with no test written. That is a reporting change,
not an improvement, and it must be reported as such after the run or the next reader will
credit it to test work.

**What is deliberately not in this change.** The previous plan also widened `--coverage-min`
to accept a metric name. `summary.json` already emits `threshold.metric`, hard-coded to
`"functions"` (`coverage.ts:122`), so the field exists; widening it is threshold plumbing,
it moves no coverage, and it is only useful if a CI gate is added. Out.

**Risk.** Confined to reporting. The one trap: functions and tables must be split the same
way, or the two headline ratios describe different universes.

**Verification.** `summary.json` must read `totals.tables` 37/37, `totals.functions`
156/229, `totals.statements` 1738/1956, and carry a `vendored` block with pgmq's own
figures.

**Documentation obligation.** `docs/test-coverage.md` is permanent and must carry the
reasoning written out, not linked, in its "Reading the result" section (`:56-80`): pgmq is
vendored upstream code inlined into a migration, it is exercised through the RPCs in
`0170_queue.sql`, and it is reported beside the headline rather than inside it. **Do not
write a partman statement count into that page.** The previous plan claimed 137 statements
were partman/partitioning code that cannot execute here; 137 is the count of *unexecuted*
pgmq statements, the partman and partitioning share is roughly 52, and a good part of the
rest are unexecuted branches inside pgmq functions that do run
(`validate_topic_pattern` 13/20, `read_with_poll` 9/11, `validate_routing_key` 11/14).
The page needs the reason, not a number that is wrong.

## Change C: the generated-function sweep

**What is true today.** 73 generated functions are never called: 27 `_label`, 45
`<fk>_label`, and the `select_rule_user_bookmarks` 1-arg overload. Six `_label` functions
are called, all from Northwind tests. **Not one `<fk>_label` companion on a shipped entity
is called by anything**, and neither is the definer wrapper. `0370_test_composed_labels.sql`
proves the generator on five hand-built shapes and then rolls them away; nothing proves it
against the shapes actually installed.

**The fix.** A new `apps/test/tests/0371_test_label_generator_sweep.sql`.

**Enumerate from `pg_proc`, not from the dictionary.** The obvious design - loop over
`entities` and `fields` and construct the function names - is wrong here, because the
generator does not emit a companion for every reference field. `rebuild_entity_label_functions`
carries five `CONTINUE WHEN` guards (`0145_managed_enable.sql:884-895`): missing parent
`id_column`, missing parent table, missing local column, missing parent key column, and a
collision guard that skips the companion when a real column already owns the
`<fk>_label` name. A dictionary-driven sweep would have to replicate all five and would
drift from the generator the moment one changes. Enumerating the catalog asks what actually
exists instead, and it cannot drift.

So: select from `pg_proc` every `public._label(rec <t>)`, every `public.<fk>_label(rec <t>)`
and every 1-argument `public.select_rule_<t>(p_row <t>)`, then call each one.

**Do not filter on `managed`.** `audit_record_logs` and `audit_ddl_logs` are registered as
entities with `managed = FALSE` (`0150_audit_log.sql:653-656`), but the label generator has
no managed guard, so both carry a `_label` function and both are in the never-called set. A
`WHERE managed` filter silently drops them and the sweep cannot reach 100%.

**Call with a NULL row, and separately assert real rows.** The generated functions are
`LANGUAGE sql STABLE` and **not** `STRICT` (`0145_managed_enable.sql:866-867`), so
`SELECT public._label(NULL::public.<t>)` executes the body and registers a call whatever the
table contains. That is what makes the sweep independent of row counts - `LIMIT 1` over an
empty table calls nothing and the sweep would decay silently. The NULL call proves the
function compiles and its body runs without raising, which is the generator smoke test.
On top of that, for entities that do hold rows, assert the composed value: `<fk>_label`
must equal `public._label(parent)` for the referenced row, looked up by the parent's
`entities.id_column` - which is not always `id` (`entities` itself is keyed on
`table_name`), so the test must read `id_column` the way the generator does at
`0145_managed_enable.sql:882`.

**Run it as the owner.** `RESET ROLE` before the sweep. Two reasons, both load-bearing:
every entity table carries RLS policies, so a `select_rule` policy would return zero rows
and the real-row assertions would pass vacuously; and every label function is
`REVOKE EXECUTE ... FROM PUBLIC` with a grant only to `semantius_user`
(`0145_managed_enable.sql:872-873`). The suite already does this in
`0350_test_raci.sql:684` and `0040_test_nwind_rbac.sql:263`.

**Assert the count.** Count the functions enumerated and the functions called, assert they
are equal, and assert the enumerated count is greater than zero - otherwise a sweep whose
catalog query stops matching anything passes as loudly as one that works.

**The `select_rule` overload is a real test, not a checkbox.** As an authenticated
non-admin, assert
`select_rule_<t>(r) = select_rule_<t>(r, jl_request_context())`. The wrapper resolves the
request context itself and is a `SECURITY DEFINER` function granted to `semantius_user`
that nothing has ever executed; the assertion pins that the two forms agree.

**Why this is not metric-chasing.** Calling a pgmq overload nobody uses proves nothing.
Calling every generated function on the shipped shapes is the only test that catches
"entity shape X produces a `_label` that does not compile or raises at runtime" - junctions,
self-references, spine chains and unmanaged audit tables that no hand-written fixture
covers. The generator is exercised today on five shapes it was designed against; this
exercises it on every shape it shipped.

**Done when.** Headline function coverage is **229/229 = 100.0%**, the count exercised is
asserted rather than assumed, and `coverage/uncovered.md` lists no never-called function
outside pgmq. If the `select_rule` overload is left out, the ceiling is 228/229 = 99.6% and
the plan has not met its target.

**Documentation obligation.** The test file header states why it exists and why `0370`
cannot replace it: pgTAP files roll back, so a test's own entities take their generated
functions with them, and only shipped shapes are ever measured. It also states why the
sweep reads `pg_proc` rather than `entities`/`fields` - the generator's guards decide which
companions exist, and a second copy of that logic in a test would drift.
`docs/test-coverage.md:70-79` currently says a handful of label functions being called
"proves the generator works; calling all of them proves nothing more". That is wrong on the
shipped shapes and has to be rewritten.

---

## What the four deliverables read after A and C

| Deliverable | Before | After |
|---|---|---|
| Why 2 tables missing | - | answered above: both vendored pgmq archives |
| Why functions 63% | - | answered above: 37 vendored + 73 generated, nothing else |
| Tables 100% | 42/44 = 95.5% | **37/37 = 100%** headline |
| Functions 100% / >90% | 194/304 = 63.8% | **229/229 = 100%** headline |
| Statements (not a target) | 1897/2252 = 84.2% | 1738/1956 = **88.9%**, from change A's denominator alone |

## Verification, once

`./pgdocker/pg-cli-retest.sh --coverage` after both changes. The suite must stay green and
the assertion count must have grown. Then read `coverage/summary.json` and check the rows
above against it. Report measured numbers; the table is a prediction until the run replaces
it.

---

## Not requested

Listed so the decisions are visible, not to smuggle scope back in. **None of this is in
scope without a separate go-ahead.**

- **Archive on the two permanent queues.** Four lines in `0350_test_raci.sql:685-686`
  (archive instead of `pgmq.delete`) and in `apps/nwind/tests/0040_test_nwind_rbac.sql`.
  It was change B in the first draft of this plan and it is demoted here because change A
  already meets the requested 100% - it would serve the *vendored* line, which the plan has
  just taken out of the headline, so by this plan's own scope rule it does not belong above.
  Worth doing on its merits: it is the only thing that would prove a queue Semantius
  provisions can actually archive. Two traps if it is ever done -
  `0040_test_nwind_rbac.sql` reads the same message **twice**, at `:268` (Test 28) and
  `:280` (Test 29), so archiving at the first read makes the second fail; and both
  `SELECT plan(66)` at `0350:18` and `SELECT plan(32)` at `0040:18` have to grow.
- **Statement coverage as test work.** After change A the headline reads 88.9%; roughly 187
  further statements are addressable by writing tests. The largest holes are
  `update_dd_field` 62/95, `apply_field_ddl` 31/58, `add_dd_field` 58/77,
  `delete_dd_field` 15/23. One item in that set is a finding rather than a percentage and is
  recorded here so it is not lost: **`public.validate_api_key` (`0110_apikeys.sql:124`)
  never executes line 168**, the wrong-secret return. Every negative case in the suite -
  unknown key id, empty string, NULL - returns before the secret is ever compared, so the
  credential comparison in the API-key authentication primitive is unexercised.
- **A CI coverage gate.** `.github/workflows/test.yml:83` passes no threshold, so nothing is
  enforced today. Adding one is an operability decision and needs the owner.
