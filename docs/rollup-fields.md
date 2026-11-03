# Rollup fields

A rollup field holds an aggregate over the records of a child entity: the sum
of an order's line amounts, the number of tickets a customer has open, the
latest shipping date of an order's lines. The database maintains it. This page
records the rules and the reasons; what each function and trigger does is in
`apps/_core/migrations/0440_rollup.sql` and `schema.md`.

## What a rollup is

A rollup is a **property of a field, not a format**. The field keeps an
ordinary format, because the format is what drives forms and grids, and the
definition in `fields.rollup` is what makes it a rollup:

```jsonc
{
  "link_field":  "order_details.order_id",   // <child entity>.<reference or parent field pointing at this entity>
  "function":    "sum",                      // sum | min | max | avg | count
  "value_field": "amount",                   // a field of the child; required unless function is count, forbidden with count
  "filter":      {"==": [{"var": "status"}, "open"]},  // optional, see "The filter"
  "include_hidden_rows": true                // optional, see "Hidden child rows"
}
```

The field's `ctype` becomes `rollup`. It is derived from the definition, never
sent by a client, and it is the marker to query for: `WHERE ctype = 'rollup'`,
`/fields?ctype=eq.rollup`, the `ctype` of every property `get_schema()`
returns, the `(rollup)` mark in `schema.md`. Unlike the other managed markers
(`id`, `label`, `audit`, `core`), `rollup` does not make a core column: the
field stays the administrator's to rename, to retype within its column type
and to delete (`dd_ctype_is_core` in `0160_dd_functions.sql` is the one
predicate every protection keys on).

## The result type follows the value field

The format of the rollup field has to fit what it holds, and the dictionary
refuses a definition whose format does not (90268):

| function | value field | format of the rollup field |
|---|---|---|
| `count` | none | an integer format (`int64` recommended) or `number` |
| `sum` | a numeric format | a numeric format; `number` keeps every digit, an integer format is the administrator's choice and overflow is theirs |
| `avg` | a numeric format | `number`, `float` or `double` |
| `min`, `max` | a numeric, text-typed, `date` or `date-time` format | the same column type as the value field: `email` over `text` passes (both TEXT), `date` over `date-time` does not |

**Decimal places are copied.** When the value field is a `number`, the rollup
field takes its `precision` on creation and whenever the value field changes,
so a sum of three-decimal amounts has three decimals. An `avg` over integers
keeps the rollup field's own precision. A later precision change on the value
field is not carried to an existing column, for the same reason a precision
change is not applied to any existing `number` column.

**Empty aggregates.** A parent with no matching child holds the format's zero
value: `0` for numbers, `''` for text, and NULL for `date` and `date-time`,
the two nullable formats. `sum` and `avg` are computed in `numeric` whatever
the value column is, so an integer sum cannot overflow and a float sum is
exact before it is cast to the column.

**Changing the type.** A definition that needs another column type
(`sum(amount)` to `max(ship_date)`) is a format change, and goes through the
usual rule for one: 90223, drop and recreate the field.

Keys, booleans, times, durations, UUIDs, binaries and JSON cannot be
aggregated (90264); nothing a rollup column could hold comes out of them.

## Which entities qualify

The child must point at the parent through a `reference` or `parent` field,
named in `link_field` as `<child>.<field>` (90262). A tree is allowed: the
child may be the parent itself. A rollup may aggregate another rollup (a sum
of totals), but a chain of rollups that comes back to the field is refused
(90267). A field has one derivation: a field one of the entity's
`computed_fields` names (`ctype = 'computed'`) cannot be a rollup (90261), and
a computed rule cannot name a rollup field (90907), because the rule would run
after the rollup guard and overwrite the aggregate. Neither side may be an `is_a` or `has_a` entity (90249): their
records span several tables. An unmanaged entity on either side keeps the
definition as metadata; the objects are generated when both are managed.

## Hidden child rows

The aggregate is computed as the dictionary owner over **every** child record
and stored on the parent, where every holder of the parent's view permission
reads it. When the child is more restricted than the parent, because it has a
`select_rule` of its own or a different `view_permission` (which may be
narrower; the dictionary does not try to prove otherwise), the rollup would
show readers of the parent a sum, count, minimum or maximum over rows their
row security hides, a capability the access-checked `set_record` path never
had. Such a rollup is refused (90269) unless its definition carries
`"include_hidden_rows": true`. The flag is the administrator's decision, on
record in the definition. Giving a child a restriction while unflagged
rollups aggregate over it is refused with the same code, so a restriction
added later cannot turn an existing rollup into a leak. `SECURITY.md` lists
the flag among the things the extension does not protect against.

## What is generated

All generated as the dictionary owner, so they bypass row security (the
maintenance has to see every child row and write a parent the writing user may
not be allowed to edit):

- `common.rollup_<child>_<link>()`, one per child table and link field, with
  four statement-level triggers on the child table (`<name>_ins`, `_upd`,
  `_del`, `_trc`). It locks the parents a statement touched, then recomputes
  every rollup column that aggregates through that link for them, one UPDATE per
  statement, and writes a parent only when a value moved. After `TRUNCATE` it
  recomputes every parent.
- `common.rollup_guard_<parent>()` behind the row trigger `a_rollup_guard` on
  the parent table. A rollup column cannot be written by hand: on INSERT it is
  the empty aggregate, on UPDATE a changed value is recomputed. The guard
  sorts before `compute_validate_trigger`, so the parent's computed fields see
  the true value. `input_type` `default` and `readonly` are coerced to
  `disabled`: a form must not even submit a computed value, and an HTML
  `readonly` input is still part of the submission while a `disabled` one is
  not (`hidden` stays as set). `required`, `searchable` and `unique_value` are
  refused (90261).
- The parent's `update_<parent>_updated_at` and `audit_i_u_d` triggers carry
  the rollup columns as ignored columns.

Names longer than an identifier allows are shortened with an md5 tail, so two
long names can never silently become one. Nothing here may be written by hand;
`AGENTS.md` lists the generated objects.

## What happens on the parent

A child write that moves a total runs the parent's **own trigger stack**: its
`computed_fields` and `validation_rules` (evaluated as the user who wrote the
child), its queue mappings and its RACI triggers. That is deliberate: a rule
such as "the total stays under the credit limit" is a rule across records, and
a queue consumer wants to know when a total changed. The cost is that a parent
rule testing the writer's permission blocks child writes by users who cannot
edit the parent, and that queue traffic grows with child writes.

Two things do **not** happen. `updated_at` is not bumped and no audit row is
written when a child write changes nothing but rollup columns: a moved total is
not an edit of the parent record. The trigger that keeps `updated_at` therefore
carries the rollup columns as arguments, which also means a write that changes
nothing no longer moves `updated_at` (the behavior
`common.update_updated_at_column` describes for tables that opt in). When a
real column of the parent changes, the audit row still carries the rollup
columns in `record` and `old_record`; only the gate ignores them.

## The filter

The filter is JsonLogic over the child record, compiled to SQL by
`rollup_filter_sql`, never interpreted: it runs inside a generated aggregate as
the owner on every child write. It is a closed subset, and
`docs/jsonlogic-optimization-candidates.md` §5 records why that subset exists
next to the one interpreter:

| JsonLogic | SQL |
|---|---|
| `{"and": [a, b, ...]}`, `{"or": [...]}` | `(a AND b)`, `(a OR b)` |
| `{"!": x}`, `{"!!": x}` | `NOT (x)`, `(x)` |
| `==`, `===` / `!=`, `!==` | `a IS NOT DISTINCT FROM b` / `a IS DISTINCT FROM b`, so `null` compares as JsonLogic expects |
| `<`, `<=`, `>`, `>=` | `a < b`; `<` and `<=` also take three operands (`a < b AND b < c`). A NULL side yields NULL and **excludes** the row, where the interpreter would read NULL as 0 |
| `{"in": [x, [l1, l2]]}` | `x IN (l1, l2)`, literals only in the list, never empty |
| `{"var": "column"}` | the child's column: a plain name, present in the catalog, of type text, boolean, integer, numeric, float, date, timestamp, uuid or TypeID |
| a string, number or boolean | a literal cast to the type of the column it is compared with |
| a bare `{"var": "flag"}` | a boolean column as a condition |

Everything else is refused when the definition is saved (90265) and the error
names what was refused: any other operator (`if`, arithmetic, `cat`,
`substr`, `merge`, `missing`, `some`, the custom operators), a request
variable (`$user_id`, `$now`, `$today`: a rollup can only be kept correct by
triggers if it depends on the child row alone), a path, a `var` with a
default, an operator object with two keys, a literal the column cannot be cast
from (caught by an `EXPLAIN` probe at save time, so not at the first child
write).

Why this is safe to run as the owner: a column name reaches the SQL only after
it was found in `pg_attribute` of the child relation and only through `%I`; a
literal only through `%L` with a cast to a type name taken from the catalog;
operators come from a fixed list; and the generated body is wrapped in a
dollar tag derived from the body itself, so no literal can end it early.

## Lifecycle

- **Creating a rollup, or changing its definition,** recomputes every parent
  record whose stored value differs (a backfill): one pass over the parent
  table, row locks on the rows that change, no rewrite. The guard recomputes
  each changed row once more.
- **A backfill is a recalculation, not an edit.** Unlike a child write, it moves
  no `updated_at` and writes no audit row, queue message or RACI event, on the
  parent or on any rollup parent above it. Those tables take no other writes
  until its transaction commits. Saving a computed rule applies it to existing
  records the same way, and a record that cannot take its new value refuses the
  save (90908), so a computed field over a rollup is never left behind.
- **Removing the definition** (`rollup` back to `{}`, the field stays) keeps the
  last values as ordinary data, clears the `rollup` marker and drops the
  generated objects. `input_type` stays `disabled` until the administrator
  changes it. Removing a computed rule works the same way.
- **Renames** are followed: a renamed child or parent table, link field, value
  field, filtered column or rollup field rewrites the definitions that name it
  and regenerates the objects under the new names.
- **Deleting** the link field, the value field, or the child entity is refused
  while a rollup of another entity depends on it (90266), unless the same
  module delete takes both sides along. Deleting the rollup field drops the
  generated objects when it was the last one through its link, and returns the
  parent's `updated_at` and audit triggers to their plain form.
- **A `.jsonc` definition** may list a rollup before the child entity it
  aggregates over: `ensure_entities` applies rollup fields after every other
  field of every entity, which is why a rollup's column lands after its
  entity's other columns.

## Cost and concurrency

A statement that touches children of N parents runs N aggregate queries per
rollup column through that link; the link field's index keeps each one to the
siblings. It first locks those parents in key order, with `FOR NO KEY UPDATE`, so
concurrent writes to children of one parent wait for each other until commit, even
when no total moves. A foreign key check takes a weaker lock and does not wait.

Key order makes two statements through one link over the same parents queue rather
than deadlock. It cannot order locks taken in separate steps, so these can still
deadlock:

- **Two links to one parent table.** A child locks through each link in turn, so a
  transfer from A to B and one from B to A can cross.
- **A tree.** A statement with children under both a node and its parent locks the
  two in key order, usually parent first, while a write under the node alone locks
  the node and then climbs to the parent.
- **A parent, then its child.** A transaction that writes a parent and then a child
  can cross a write to that child, which holds the child row while it waits for the
  parent, even when that write moves no total.

PostgreSQL aborts one transaction with `40P01`. It changes nothing, so the totals
stay right, and its writer has to retry it.

The lock comes before the aggregate because the aggregate has to see the writer
ahead. An UPDATE that waits for a row lock keeps the value it computed from its
snapshot, which could not see the other writer's children, and rechecks
`IS DISTINCT FROM` against the row that writer committed. Two inserts under a
`count`, or two that add the same amount, compute the same value, so the second
skips the row and its children are never counted. Nor can the lock be skipped when
a total looks unchanged: a writer inserting 3 under a `max` of 10 sees no change
while another deletes the 10 without seeing the 3. The pgTAP suite runs in one
session and cannot show any of this; `pgdocker/pg-rollup-race.sh` does.

The filter compiler has no depth bound and the save-time probe plans whatever was
written, the same trusted-administrator residual `SECURITY.md` accepts for rules.
