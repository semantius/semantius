# Finding JsonLogic optimization candidates

Last updated 2026-09-05.

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

For why the general "compile any JsonLogic expression to SQL" route was rejected,
see the P2 closure in [plans/ext-solved-items.md](../plans/ext-solved-items.md).

---

## What the cost actually looks like

Two generated functions carry every rule, one pair per entity:

| Function | Built by | Rules it carries |
|---|---|---|
| `select_rule_<table>(row, ctx)` | `build_select_rule_policy` (`0180`) | the entity's `select_rule`, called from all three RLS policies |
| `compute_validate_<table>()` | `build_record_logic_trigger` (`0180`) | the entity's computed-column expressions and validation rules, called from a row trigger |

Because the name carries the table, **per-function statistics give you a
per-entity ranking for free**. That is the whole basis of the method below.

Order of magnitude, measured 2026-09-05 on a 100k-row table with a
`{"==": [{"var":"user_id"}, {"var":"$user_id"}]}` rule:

| | Full scan |
|---|---|
| Interpreted (today) | ~4,700 ms |
| Native, no index | ~8 ms |
| Native, indexed column | ~1 ms |

An index on the rule column changes nothing while the rule is interpreted —
measured at 4,204 ms with the index present and ignored. There is no cheaper
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
   `pg_attribute` and compares dates as dates. See **B20** and **B21** in
   `plans/pg_semantius-open-items.md` for what that coercion path currently gets
   wrong.

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

A named operator is not just an interpreter branch. It also needs:

- a branch in `evaluate_json_logic` (`0210_raci.sql`), and the same in
  `0015_jsonlogic.sql` if the operator is not RACI-specific — both copies, or the
  two drift
- native emission in `build_select_rule_policy` (`0180_computed_validation.sql`)
- the column-lifecycle protection: naming a column inside an RLS policy means a
  `DROP COLUMN ... CASCADE` from `delete_dd_field` will drop the policy and leave
  RLS enabled with none, which hides every row silently
- corpus cases in `apps/test/tests/0015_test_jsonlogic.json`, regenerated with
  `deno task testgen_jsonlogic`
- a test that the interpreted and native forms agree, including on NULL
