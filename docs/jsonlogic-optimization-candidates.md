# Finding JsonLogic optimization candidates

Last updated 2026-09-06.

Semantius stores row-visibility, computed-column and validation rules as
JsonLogic in the data dictionary, and evaluates them with the interpreter in
`0210_raci.sql`. That interpreter runs **once per row**, and it is opaque to the
query planner: no index on a column named in a rule can ever be used to satisfy
that rule.

The escape hatch is a **named operator** — a domain operator such as
`has_permission` or `is_raci_actor`, implemented once in the interpreter and
emitted as native SQL by the policy builder. Named operators are cheap to
evaluate and, where the emitted SQL is a plain column comparison, indexable.

This document is about deciding *which* operator to add next on evidence rather
than on hunch. It is a periodic review, not something to automate or to run
continuously.

Two other routes were designed and rejected before this one. Both reasons are
written out under "Do not write a general compiler" below, so this page stands
on its own.

---

## Status: postponed, and what would change that

This was tracked as an open item until 2026-09-06, when it was **postponed by
decision**. Nothing about the problem changed. It is owned by no plan, and this
document is its only record.

Postponed because **nothing is slow today and no caller can reach it.** Exactly
one entity ships a `select_rule` - `user_bookmarks`
(`0280_user_bookmarks.sql:45`), a per-user bookmarks table that will not grow.
The other rule shapes measured alongside it on 2026-09-05 - four uses of
`{"or":[{"has_permission":...},...]}` - are test fixtures created and rolled
back inside tests; they do not exist in an installation. Their numbers are not
reproduced here because they measure a shape nobody ships: a full scan cost
5,404 ms interpreted for a non-holder and 2,229 ms for a permission holder,
against 8.2 ms and 6.0 ms native, and the native form stayed a sequential scan
with an index present because an `OR` needs every arm index-matchable.

It was graded Medium rather than the High it had carried since the release
review of 2026-09-02. That grade was set in a different context, and a problem
nobody can reach does not outrank the reachable security work that sat at Medium
beside it - the audit tables writable by the request role, the first-user
bootstrap that could elect a second administrator, and reading another user's
permissions, all since fixed.

**What makes this urgent is the first `select_rule` on an entity that grows.**
From that point the degradation is silent, unbounded and has no workaround: it
is linear in row count, it never raises, and an index on the rule column is
ignored. Treat that as the trigger to pick this up - not a slow-query report,
which arrives long after.

When it is picked up, it is done when both hold:

- a 100k-row scan under a named operator runs in about **20 ms or better**, with
  the rule column used as an index condition; and
- `delete_dd_field` on a column named in a policy leaves the policies intact,
  pinned by a test capable of failing (constraint 3 under "When you add one" is
  why this is part of the definition of done and not a detail).

---

## What the cost actually looks like

Two generated functions carry every rule, one pair per entity:

| Function | Built by | Rules it carries |
|---|---|---|
| `select_rule_<table>(row, ctx)` | `build_select_rule_policy` (`0180`) | the entity's `select_rule`, called from all three RLS policies |
| `compute_validate_<table>()` | `build_record_logic_trigger` (`0180`) | the entity's computed-column expressions and validation rules, called from a row trigger |

Because the name carries the table, **per-function statistics give you a
per-entity ranking for free**. That is the whole basis of the method below.

Measured 2026-09-05 on `postgres18-cli`, on a schema where the request context
had already been hoisted to one resolution per statement: a 100k-row
table, `user_id` spread over 50 users so the caller owns 2,000 rows (2%), rule
`{"==": [{"var":"user_id"}, {"var":"$user_id"}]}`. The helper was a
byte-for-byte copy of what `build_select_rule_policy` generates for the shipped
`user_bookmarks` rule; one rolled-back transaction, second of two runs,
`EXPLAIN (ANALYZE, TIMING OFF)`.

| Query | Interpreted (today) | Native | Native + index |
|---|---|---|---|
| Full scan | **4,693 ms** | 7.9 ms | 1.1 ms |
| `count(*)` | 4,546 ms | 8.8 ms | 0.8 ms |
| `LIMIT 20`, page 1 | 33 ms | 0.2 ms | — |
| `OFFSET 1980 LIMIT 20` | **3,182 ms** | 6.8 ms | — |
| `ORDER BY title LIMIT 20` | **3,344 ms** | 8.2 ms | — |
| Floor, `USING (true)` | 4.6 ms | — | — |

End-to-end that is about **45 µs per row**, against 17.21 µs for the rule
evaluation alone — the difference is the SECURITY DEFINER PL/pgSQL frame and the
`to_jsonb(p_row)` around it. Three earlier optimizations (a cheaper warm
permission check, an interpreter that no longer queries the database to read a
JSON key, and the hoisted request context) touched neither, which is why the
baseline is still ~4.7 s.

**Pagination does not save you.** Page 1 is genuinely cheap, but any *sorted*
page, and any page past the first, costs ~3.2 s: a sort must see every visible
row before it can return twenty. The exposure is the ordinary UI grid, not a
rare admin query.

An index on the rule column changes nothing while the rule is interpreted —
measured at 4,204 ms with the index present and ignored
(`Seq Scan ... Filter: select_rule_<t>(...)`). Indexing, partitioning and
`ANALYZE` are all inert against an opaque predicate. There is no cheaper
mitigation than a named operator.

---

## Signal 1 — which rules are actually hot

Per-function timing is **off by default** (`track_functions = none`). Turn it on
for a measurement window; it is not free, so turn it off again afterwards.

```sql
-- Cluster-wide, so every session contributes. Needs a reload, not a restart.
ALTER SYSTEM SET track_functions = 'pl';
SELECT pg_reload_conf();

-- Optional: start from zero so the window is well defined.
SELECT pg_stat_reset();
```

Leave it running under representative load — a working day is usually enough.
Then:

```sql
SELECT p.proname                                              AS fn,
       s.calls,
       round(s.total_time::numeric, 1)                        AS total_ms,
       round((s.total_time / NULLIF(s.calls, 0))::numeric, 4) AS ms_per_call
FROM   pg_stat_user_functions s
JOIN   pg_proc p ON p.oid = s.funcid
WHERE  p.proname LIKE 'select\_rule\_%'
   OR  p.proname LIKE 'compute\_validate\_%'
ORDER  BY s.total_time DESC;
```

Read `total_ms` first, not `ms_per_call`: a cheap rule called constantly costs
more than an expensive one called twice. `select_rule_<t>` exists in a one-argument
and a two-argument form — the two-argument one does the work; the one-argument
wrapper only resolves the request context for `get_record_by_id`.

Turn tracking off when the window closes:

```sql
ALTER SYSTEM RESET track_functions;
SELECT pg_reload_conf();
```

**Caveats.** Statistics are cluster-wide and cumulative since the last reset, so
a window without a reset mixes in whatever came before. They do not survive
`pg_stat_reset()` or a crash. And a rule that is slow but only ever runs on a
small table will still rank low — which is correct, and is why signal 3 exists.

---

## Signal 2 — which shapes people actually write

Independent of speed: what does the rule vocabulary look like across the whole
installation? A shape written once is not worth an operator however slow it is.

```sql
WITH RECURSIVE nodes(n) AS (
    SELECT select_rule
    FROM   entities
    WHERE  select_rule IS NOT NULL AND select_rule <> '{}'::jsonb
  UNION ALL
    SELECT x.v
    FROM   nodes, LATERAL (
        SELECT value AS v FROM jsonb_each(n)            WHERE jsonb_typeof(n) = 'object'
        UNION ALL
        SELECT value      FROM jsonb_array_elements(n)  WHERE jsonb_typeof(n) = 'array'
    ) x
)
SELECT k AS operator, count(*) AS uses
FROM   nodes, LATERAL jsonb_object_keys(n) k
WHERE  jsonb_typeof(n) = 'object'
GROUP  BY 1
ORDER  BY 2 DESC, 1;
```

To see whole rules rather than operator frequencies — usually more informative,
because it is the *shape* that becomes an operator, not the operator that appears
in it:

```sql
SELECT select_rule::text AS rule, count(*) AS entities,
       string_agg(table_name, ', ' ORDER BY table_name) AS used_by
FROM   entities
WHERE  select_rule IS NOT NULL AND select_rule <> '{}'::jsonb
GROUP  BY 1
ORDER  BY 2 DESC;
```

`computed_fields` and `validation_rules` hold **arrays of wrapper objects**, not
bare rules — each element carries the rule under a `jsonlogic` key alongside
`name`, or `code` and `message`. Seed the recursion from that key, or the census
counts the wrapper keys as operators:

```sql
-- replaces the first branch of the CTE above
    SELECT elem -> 'jsonlogic'
    FROM   entities, LATERAL jsonb_array_elements(
               COALESCE(validation_rules, '[]'::jsonb)) elem
    WHERE  elem -> 'jsonlogic' IS NOT NULL
```

---

## Signal 3 — does the table have the row count to matter

A rule is only a problem on a table large enough for per-row cost to show.

```sql
SELECT e.table_name,
       e.select_rule::text AS rule,
       c.reltuples::bigint AS approx_rows
FROM   entities e
JOIN   pg_class c ON c.relname = e.table_name
WHERE  e.select_rule IS NOT NULL AND e.select_rule <> '{}'::jsonb
ORDER  BY c.reltuples DESC;
```

`reltuples` is an estimate maintained by `ANALYZE`; `-1` means never analyzed.

---

## Deciding

A shape earns a named operator when it is **hot** (signal 1), **repeated**
(signal 2) and **on a table with rows** (signal 3). Any one of the three alone is
not enough:

- hot but written once → fix that one entity, or accept it
- repeated but always tiny → no benefit to buy
- large table but the rule is rarely evaluated → not on a hot path

Beyond the three signals, prefer a shape that:

1. **Reduces to a plain column comparison.** That is what becomes an index
   condition. A shape whose native form contains a sub-select — anything of the
   form `has_permission(...) OR <column test>` — is fast but *not* indexable,
   because every arm of an `OR` has to be index-matchable for the planner to use
   a bitmap. Measured 2026-09-05: variant with an `OR has_permission` arm stayed
   a sequential scan with the index present.
2. **Names something a person would recognize** — "is the owner", "not expired",
   "in my department". If you cannot name it in three words it is probably two
   operators, or none.
3. **Can be defined without inheriting the generic operators' coercion rules.**
   This is the main reason to prefer a named operator over recognizing a generic
   expression: `{">=": [{"var":"valid_to"}, {"var":"$today"}]}` drags in
   `jl_to_number`, which renders both sides as text and tries numeric then
   timestamp coercion. A named `not_expired` operator resolves the column against
   `pg_attribute` and compares dates as dates. The generic path is faithful to
   the reference since 2026-09-05 (two strings compare as text, and a
   non-numeric string no longer raises, both fixed 2026-09-05 and pinned by
   corpus cases 290 to 311), but it still cannot know that a column is a date,
   which is the point.

## Confirming the win before committing

Two checks, on a copy, before writing the operator:

```sql
-- 1. Is it actually the rule, and not the query?
EXPLAIN (ANALYZE, TIMING OFF, COSTS OFF) SELECT * FROM <table>;
--    Look for: Seq Scan ... Filter: select_rule_<table>(...)
--              Rows Removed by Filter: <large>

-- 2. Would the native form be indexable? Try it by hand.
CREATE INDEX ON <table> (<rule column>);
ANALYZE <table>;
--    then EXPLAIN a query with the hand-written native predicate and look for
--    "Index Cond". If it is a Seq Scan, the shape is fast but not indexable —
--    still worth doing, but say so when you write it down.
```

Run both inside a transaction you roll back. The request role cannot create
indexes, so this is a DBA-side exercise; `pgdocker/pg-ext-lifecycle.sh` is where
an assertion of this kind belongs if you want it pinned.

## When you add one

A named operator is not just an interpreter branch. Four constraints below are
not obvious and were each established the hard way; the rest is bookkeeping.

### The mechanical parts

- a branch in `evaluate_json_logic` (`0210_raci.sql`), and the same in
  `0015_jsonlogic.sql` if the operator is not RACI-specific — both copies, or the
  two drift
- native emission in `build_select_rule_policy` (`0180_computed_validation.sql`)
- corpus cases in `apps/test/tests/0015_test_jsonlogic.json`, regenerated with
  `deno task testgen_jsonlogic`
- a test that the interpreted and native forms agree, including on NULL

### 1. The operator must consume the request context itself

Do **not** try to gate authentication with a separate
`(SELECT jl_request_context()) IS NOT NULL AND ...` conjunct. An InitPlan is
evaluated lazily, so once the predicate becomes an index condition the gate is
left as a filter over the index output and never runs first. Requiring the
operator itself to reference `$user_id` / `$today` / `$now` or `has_permission`
makes the gate intrinsic instead.

**The honest claim is parity with today, not an absolute guarantee.** The gate
fires on the first tuple the scan filters, or before the first tuple when the
predicate is an index condition (runtime index keys are evaluated in
`ExecReScanIndexScan`, even on an empty table). On any plan that yields zero
tuples neither fires — which is exactly today's behavior, where
`select_rule_<t>()` is never called either. Consequence to accept: the same query
on the same data can answer 42501 or zero rows depending on the plan chosen,
**so a gate test must insert a row first** or it proves nothing.

This permanently excludes context-free operators. That is a deliberate
consequence, not a gap to close later.

### 2. Resolve the column against the catalog, not against `format`

Check `pg_attribute.atttypid` against an explicit allowlist. Do **not** derive
the type from the field's `format`: `format_to_data_type` (`0070_dd_functions.sql:14-54`)
falls through to `TEXT` for anything it does not recognize, and a native
`text = int` has no operator — so `CREATE POLICY` would fail *inside* a `fields`
trigger, at DDL time, where it is worst. A `boolean` column diverges for a
different reason (`jl_loose_eq` coerces it through `jl_to_number`,
`0015_jsonlogic.sql:83-84`).

The same check is what stops migration `0280_user_bookmarks.sql` failing: the
entity row carrying the rule is inserted at `:45`, its `user_id` field only at
`:56`, so at policy-build time the column does not exist yet. The emission must
degrade to the interpreted form rather than raise.

### 3. The `fields` lifecycle hook — three arms, all AFTER

Naming a column inside an RLS policy creates a column-level dependency the
interpreted helper never had, and the data-dictionary field lifecycle was
written assuming no such dependency exists. Model the trigger on
`dd_label_fn_sync_field` / `zzz_label_fn_field_*` (`0145_managed_enable.sql:1049-1096`) — the
same shape, not a novel construct — with the `entities.select_rule <> '{}'` gate
*inside* the function, because a trigger `WHEN` clause cannot query `entities`.

- **AFTER INSERT.** Fields arrive after the entity row, so an operator that could
  not resolve its column at entity-insert must be retried once the column exists.
  Must sort after `add_field_trigger` (`0070_dd_functions.sql:794`), which runs the
  `ALTER TABLE ... ADD COLUMN`; a `zzz_` prefix guarantees that.
- **AFTER DELETE — mandatory.** `delete_dd_field` runs `DROP COLUMN ... CASCADE`
  from a BEFORE DELETE trigger (`0070_dd_functions.sql:1164`). Against a native policy that
  CASCADE drops all three policies, leaving RLS enabled with none — every read
  returns zero rows and nothing raises. This is the failure that must not ship.
- **AFTER UPDATE, with `field_name` in the `WHEN` clause.** Keep the clause tight
  or `rename_dd_reference_tables` (`0140_dd_rename.sql:272`) rebuilds a policy for every
  referencing entity on every table rename.

Renaming a column named by an operator is **not** covered by this: nothing
rewrites `entities.select_rule` on a field rename. Assert the accepted
behavior — the comparison fails closed — rather than pretending it round-trips.

Budget about ten extra DDL events per field on rule-bearing entities. That cost
lands on top of what adding a field already triggers - a full label-function
rebuild and an `entities` UPDATE that cascades through the entity trigger stack -
so measure it there before assuming the budget is affordable.

### 4. Do not write a general compiler, and do not recognize shapes either

**Shape recognition was the second rejected route**: a registry of recognizers,
each matching one literal rule shape by jsonb template equality, emitting native
SQL on a match and falling back to the interpreter otherwise. Four reasons it
lost to named operators, recorded 2026-09-05:

- **Almost the whole cost was proving equivalence**, and that burden exists only
  because a generic expression inherits the generic operators' coercion rules.
  Template matching, near-miss controls, a three-way differential and an md5
  drift tripwire over `jl_loose_eq` / `jl_to_number` were all in service of
  proving that two independently written predicates agree on cases nobody chose.
- **Its own deferred shape was the evidence.** Temporal validity
  (`{">=":[{"var":"col"},{"var":"$today"}]}`) was identified as the obvious
  second shape and then deferred, entirely because `>=` coerces both sides
  through `jl_to_number`. A named `not_expired` operator has none of that. The
  shape was hard only because of the approach.
- **Performance becomes visible rather than accidental.** Under recognition,
  whether an entity is fast depends on whether its rule happens to match a
  template the author cannot see; rewording it silently costs 500x.
- **The backwards-compatibility argument is thin here.** Exactly one rule ships.

A general JsonLogic-to-SQL translator was designed and rejected twice. It is a
second implementation of a 44-operator language whose definition is split across
`0015_jsonlogic.sql` and the `CREATE OR REPLACE` in `0210_raci.sql`, so the two
drift silently, and review passes kept finding semantic divergences between the
interpreter and the obvious SQL mapping. Named operators exist precisely so that
neither side has to reverse-engineer the other: an operator is defined once and
both implementations derive from that definition, instead of two independently
written predicates having to be proven equal on cases nobody chose.
