# Plan: enforce `input_type = required` in the database

## Context

`input_type` reaches clients as `inputMode` and forms read it, but the database
only acts on it for enums. Anything that skips a form (PostgREST, MCP, bulk
imports) can save a required reference or date as `NULL` and a required string
as `''`. `apps/test/tests/0550_test_foreign_keys.sql:120` pins this as "a UI hint
only".

This plan makes the table refuse a missing value on a required field. What
"missing" means depends on the format:

- **`NULL`** for the nullable formats: `reference`, `date` and `date-time`. These
  have no blank value.
- **Blank (`''`)** for text-based formats. Their columns are already `NOT NULL`, so
  `''` is how they store "nothing".
- **Empty JSON (`{}`, `[]`)** for JSON formats. Their columns are also `NOT NULL`,
  and these are their defaults.

Implemented in the working trees of semantius and postgrest-mcp, not committed. Line
numbers refer to the code before that work.

## The production rule

There is no maintenance window. Every change must be safe on a live database and as
small as possible:

- **Never scan a table while holding a lock on it.** Checks always go on `NOT VALID`,
  so adding one takes its exclusive lock only for a moment. Any search for missing
  values happens first, as a plain read that blocks nobody.
- **One user table per transaction.** A migration file is one transaction in every
  runner (`packages/core/src/migrate.ts:374-389`, `packages/cli/commands/extension.ts:38`),
  so no migration file adds these checks.
- **A short `lock_timeout` on anything that locks a user table,** as
  `0250_public_functions.sql:952` already does, so it gives up instead of queueing
  live traffic behind it.
- **No row is ever changed.**

## Decisions

All seven are decided.

### D1. Existing rows: decided

Existing rows are never updated and there is no backfill. A check on `NOT VALID`
doesn't look at them. If a row with a missing value exists under a check, any later
`UPDATE` of it fails until the value is filled in, even when it changes another
column.

### D2. Labels: decided

No special handling. `required` on the automatic label row
(`0160_dd_functions.sql:1045`, `0180_managed_enable.sql:391`) is only a default, like
any other field's `input_type`, and no code reads it specially. An entity whose
writers don't send a label sets that field to `default` in its own metadata, the same
way it would for any other field. See step 7.

### D3. Which other values count as missing: decided

Besides `NULL`, `''`, `{}` and `[]`, these also count as missing:

- Whitespace-only strings. This needs `col ~ '[^[:space:]]'`, because `<> ''` lets `"   "`
  through.
- JSON `null` and `""`, which hold nothing, the same as `{}`, `[]` and `''`.
- A `rating` of `0`. The format's own description says 0 means not rated.

### D4. A required enum that is omitted: decided

The write fails. Today it silently gets its first value
(`0160_dd_functions.sql:633-638`), which saves a value nobody chose. An enum with an
explicit default keeps that default. See step 8.

### D5. The error for a missing required value: decided

Every refusal our check makes is `90258`, with `table` and `field_name` in the JSON
hint. A plain CHECK can only return 23514, so it raises through a small function. If
step 1's verification fails, stop and raise it rather than falling back to 23514.

An explicit `NULL` on a `NOT NULL` column returns PostgreSQL's own `23502`, because
`NOT NULL` runs before any CHECK. That isn't an error we raise, so it stays.

### D6. Adoption: decided

`managed = true` only adds what is missing. It never drops or changes a constraint
that is already there.

### D7. A required field whose existing rows already have missing values: decided

Skip it and warn. This applies when installing checks on existing fields and at
adoption. It isn't specific to labels: any field whose writers don't send a value is
affected, such as a junction created in production, whose label is `required` by
default.

Missing values in existing rows show that live writers may not send this field, and a
release must not start refusing them. The check is added by a later migrate, once the
rows are clean. A field changed to `default` no longer needs one. The cost is that such a
field stays unenforced until then.

## Design

**A CHECK constraint named `<rel>_<field>_assert`.**

- At the table, it covers every writer. It runs after BEFORE triggers, so a computed
  field can fill a required column.
- It has its own name so it can never collide with `<rel>_<field>_check`, which
  PostgreSQL can also auto-generate for someone's own inline check on an adopted table.
- The name sorts before `_check` on purpose. PostgreSQL runs CHECK constraints in name
  order, so an empty enum raises `90258` before the enum's own check returns 23514. An
  existing enum's `_check` therefore doesn't need rebuilding.
- `is_nullable()` stays format-only, along with its mirrors in `drizzlegen.ts`,
  `kyselygen.ts`, `0250_public_functions.sql` and `0180_managed_enable.sql`.
- A trigger is rejected: it costs a function call per row on every table, and installing
  one locks the table anyway.

The check has this shape, and `tableoid` means a table rename needs no rebuild:

`CHECK (CASE WHEN col ~ '[^[:space:]]' THEN TRUE ELSE common.dd_raise_required(tableoid, 'customer_id') END)`

| Formats | Column | The value passes when |
|---|---|---|
| `reference`, `date`, `date-time` | nullable | `col IS NOT NULL` |
| `enum` | `NOT NULL` | `col <> ''` |
| Everything else stored as `TEXT` | `NOT NULL`, default `''` | `col ~ '[^[:space:]]'` |
| `json`, `jsonlogic`, `object`, `array` | `JSONB` | `col NOT IN ('{}', '[]', 'null', '""')` |
| `rating` | `INTEGER` | `col <> 0` |
| `binary` | `BYTEA` | `octet_length(col) > 0` |
| `parent` | `NOT NULL` | No check. An omitted value falls back to `0` or `''` and fails the foreign key. |
| Other numbers, `boolean` | `NOT NULL` | No check. `0` and `false` are real values, and dropping their default would break the "every NOT NULL column has a DEFAULT" rule. |
| `uuid`, `time`, `duration` | `NOT NULL`, no default | No check. `NULL` is already refused and they have no empty value. |

Test the format branches first and decide the rest by `field_data_type()`, not a list
of names, so a new format is covered automatically. `field_data_type()` also returns
`TEXT` for an enum and a text-keyed `parent`, so those must come first.

**The enum's own `<rel>_<field>_check` keeps its existing list,** which leaves `''` out
of a required enum. The `_assert` check fires first, so `''` still returns `90258`, and
an upgraded database's `_check` is the same as a fresh install's.

**No check is generated for:**
- `is_pk` fields, which the key already constrains.
- Fields with a non-empty `input_type_rule`, because the rule can turn `required`
  off per record.
- Fields of unmanaged entities, where the dictionary runs no DDL.

**Behavior changes to expect:**
- Adding a required field to a populated table with no usable default is refused.
  The route is to add it as optional, backfill, then change it to required.
- A partial upsert fails when it omits a required field, even if the row exists,
  because PostgreSQL checks the proposed row before it resolves the conflict. This
  affects PostgREST upserts and `postgrest-mcp/src/db/hook.ts:584`.
- `get_schema()` reports `default: ''` for a required enum with no explicit default,
  so a form starts it empty.

## Errors

| Situation | Code | Message |
|---|---|---|
| A write leaves a required field missing, on insert or update | `90258` | `Field ${field_name} on ${table} is required` |
| Changing a field to required while rows have a missing value | `90259` | `Field ${field_name} on ${table} cannot be required while rows have no value for it` |
| Adding a required field to a populated table with no usable default | `90259` | Same |
| Setting `required` together with `reference_delete_mode = 'clear'` | `90257` | `Field ${field_name} on ${table} cannot be required while its delete mode is clear` |
| An existing field is skipped when installing checks | None | `WARNING` naming the table, field and reason |
| An enum value that isn't in the list | `23514` | Unchanged: PostgreSQL's sentence with `<rel>_<field>_check` |
| Removing an enum value that rows hold | `23514` | Unchanged |
| An explicit `NULL` on a `NOT NULL` column, or an omitted `binary` | `23502` | PostgreSQL's `NOT NULL` |
| A `parent` is omitted | `23503` | Unchanged: the foreign key. `23502` when the key type has no default. |
| A field change can't get its lock within the timeout | `55P03` | PostgreSQL's. Nothing changed, so retry. |

All three new codes carry `table` and `field_name` in the JSON hint, with `table`
naming the entity, not `<entity>_ext`.

## Changes to `input_type`

Each change runs in the field edit's own transaction and touches one table. Compare the
check expression before and after, and touch the constraint only when it differs.

| Change | What happens |
|---|---|
| Any other mode to `required` | Search for missing values first, without a lock. Refuse with `90259` if any exist. Otherwise add the check `NOT VALID`. |
| `required` to any other mode | The check is dropped. No data changes. |
| Between `default`, `readonly`, `disabled` and `hidden` | Nothing. |
| Re-saving the same mode, including an `ensure_entities` re-run | Nothing. |
| Adding a rule to a required field | The check is dropped, because the rule now decides per record, on the client. |
| Removing the rule from a required field | Same as changing to `required`. |
| Changing one non-empty rule to another | Nothing. |
| Changing `format` on a required field | Rebuilt only if the expression differs, after the same search. `text` to `email` has the same expression, so nothing happens. |
| Renaming a required field | The check is dropped and added under the new name, `NOT VALID` and without a search. A rename is never refused because of old rows. |
| Renaming the entity | The constraint name changes. The check itself uses `tableoid`, so it isn't rebuilt. |
| Changing `enum_values` | Search for rows outside the new list first, without a lock, and refuse with 23514 if any exist. Otherwise replace `_check`, `NOT VALID`. |
| Changing `default_value` | Column default only. The check doesn't change. |
| Changing `reference_delete_mode` to `clear` on a required reference | Refused with `90257`. |
| A `.jsonc` file changes a deployed field to required | Same as any change to required, so the migration fails with `90259` while rows have a missing value. Clean the rows first. |
| A field on an unmanaged entity | Metadata only. The check arrives with adoption. |

A row written between the search and the moment the check is added could keep a missing
value. That window is tiny, and such a row behaves like any other old row under D1.

## Steps

### semantius

1. **Helpers in `apps/_core/migrations/0160_dd_functions.sql`,** before `add_dd_field`:
   - `dd_required_check_expr(p_field fields)` returns the expression, or `NULL`. Wrap
     each test in a `CASE`, not an `OR`, because PostgreSQL doesn't guarantee `OR`
     evaluation order.
   - `dd_field_has_missing(p_field fields, p_rel TEXT)` runs the plain read.
   - `dd_add_required_check(p_field fields, p_rel TEXT)` adds `<rel>_<field>_assert`
     `NOT VALID` if it's absent, with `SET lock_timeout = '2s'`.
   - `common.dd_raise_required(p_table OID, p_field TEXT)` raises `90258`, resolving the
     entity name and stripping `_ext`. It must be `VOLATILE`, or the planner can evaluate
     it early and raise when nothing is wrong.
   - Revoke all of them from `PUBLIC` and add comments. Grant EXECUTE on
     `common.dd_raise_required` to `semantius_user`, because a write runs it as the
     writer. Column names go through `%I` and literals through `%L`.
   - Verify early: writes as `semantius_user` get `90258`, not a permission error;
     `tableoid` works in the check on insert and update; dump and restore works;
     `0900_test_security.sql` and `0910_test_no_unsafe_functions.sql` accept the function.

2. **`add_dd_field`:**
   - Before the `ALTER`, if the field gets a check and has no usable default, refuse with
     `90259` when `SELECT 1 FROM <rel> LIMIT 1` finds a row. A non-empty default needs no
     search, because every row gets that value.
   - Add the check after the column.
   - Replace the enum block (`0160_dd_functions.sql:1343-1375`) with one helper, shared
     with `update_dd_field` and `apply_field_ddl`. It adds the constraint `NOT VALID` when
     the table has rows. An empty table is validated, which costs nothing and keeps a
     fresh install's constraint the same as an earlier release's.
   - Remove the early return that skips the label column (`:1210-1222`) as far as checks
     are concerned, so a label is treated like any other field. Its column already exists
     there, so follow D7 instead of refusing: skip and warn when rows have missing values.

3. **`update_dd_field` and renames:**
   - Run the search before any `ALTER` in the function.
   - Replace the enum block (`0160_dd_functions.sql:1667-1707`) with "Changes to
     `input_type`".
   - A field rename reaches this function (`0160_dd_functions.sql:1460-1461`). Drop the
     check under the old name and add it under the new one, with no search.
   - `apps/_core/migrations/0170_dd_rename.sql:186-193`: rename `_assert` constraints on a
     table rename, alongside `_check`.

4. **`apps/_core/migrations/0180_managed_enable.sql`:**
   - `apply_field_ddl`: replace the enum block (`:140-166`) with the helpers, use
     `dd_column_default` instead of its own copy (`:47-82`), and use `dd_relation` rather
     than `p_field.table_name`.
   - `enable_dd_table`: the loop at `:403-416` only handles missing columns, so an adopted
     table gets no checks on columns it already has. For every field, add an enum's
     `_check` if no constraint has that name, and add `_assert` following D7. Never drop or
     change an existing constraint. Adoption must not abort over existing rows.

5. **Refuse `required` + `reference_delete_mode = 'clear'`** on a `reference` field that
   gets a check, because `ON DELETE SET NULL` would then fail on every parent delete. Add
   a BEFORE INSERT OR UPDATE trigger on `fields` raising `90257`, only when the row is new
   or one of those columns changes, so unrelated updates of an existing field still work.
   No shipped field has this combination.

6. **Install checks on existing fields, one table at a time.** A check is only created
   when a field is added or changed, so fields that are already required would never get
   one. Core table fields are also seeded before the triggers exist. This replaces the
   `.once.` file that `RELEASE.md:112-115` would otherwise call for.
   - A function in a repeatable file handles one table per call and takes the previous
     table's name, walking `entities` in order. It returns the next table, or `NULL` when
     done.
   - For each required field with no check, it does all its reads first, then its `ALTER`s:
     - It skips and warns if rows have missing values (D7).
     - It skips and warns on a `required` + `clear` field.
     - Otherwise it adds the check `NOT VALID`.
   - For a required enum with no explicit default, it sets the column default to `''`, and
     calls `dd_refresh_family` when an `is_a` or `has_a` view copied that default
     (`0160_dd_functions.sql:2932-2934`).
   - Read the field rows into a variable before any `ALTER`. Altering `fields` while a loop
     is reading it raises 55006.
   - On `55P03`, it skips that table with a warning and carries on.
   - Each runner calls it in a loop, committing between calls, after the migration files:
     `runMigrations` in `packages/core/src/migrate.ts` and the `migrate()` procedure in
     `packages/cli/commands/extension.ts`. Check that the provisioners get it through
     `runMigrations`.
   - It only ever adds what's missing, so a skipped table is picked up by the next migrate
     without a ledger entry. A skip doesn't fail the migrate; it is reported in the summary.

7. **Labels.** No hardcoded handling. `0160_dd_functions.sql:1045` and
   `0180_managed_enable.sql:391` stay as they are, as a default.
   - Correct the two shipped entities whose writers never send a label. In
     `apps/nwind/migrations/0010_nwind.jsonc`, `employee_territories` lists
     `{"field_name": "label", "input_type": "default"}`, and
     `apps/_core/migrations/0380_webhook_receiver.jsonc` does the same for
     `webhook_receiver_logs` (`postgrest-mcp/src/db/hook.ts:626-628` never writes it).
     Confirm `ensure_entities` applies a partial entry for an existing field.
   - Both `.jsonc` files run before step 6, so those fields never get a check.

8. **Omitted required enums.** Remove the first-value branch from `effective_enum_default`
   (`0160_dd_functions.sql:633-639`). The column default stays `''`, so the insert fails
   with `90258`.
   - Keep the function signatures of `effective_enum_default` and `dd_column_default`, with
     the now-unused `p_input_type`. Each migration file commits separately, so dropping a
     signature in `0160` would break `get_schema()` until `0250` commits. The comment must
     say this.
   - Confirm every writer of the affected fields supplies a value:
     `process_gates.gate_kind`, `queue_table_events.event_handler`,
     `raci_assignments.raci` and `raci_events.raci`.

9. **Tests.** See "Tests" below.

10. **Docs and generated files.**
    - `docs/error-contract.md`: `90257`, `90258` and `90259` in the class 90 tables, and the
      generated `<table>_<field>_assert` in "Constraint names". That section's opening
      (`:538-543`) says a constraint violation can't carry a number of ours, which this
      check now does, so it needs correcting.
    - `RELEASE.md`: how checks reach an existing database.
    - `AGENTS.md:129` already lists `_assert` among the generated names, with the owner's
      approval. Commit it together with this work.
    - The description of `fields.input_type` says only "How the UI presents". A new
      `0430_required_field_description.once.sql` says the database also refuses a missing
      value, because a released `0150_dd_bootstrap.once.sql` never runs again.
    - `extension/CHANGES.md`: a bullet in the 0.5.0 section.
    - `deno task docgen`, then `deno task extension 0.5.0-beta1`.
    - `drizzlegen.ts` and `kyselygen.ts` stay as they are: they describe the physical column,
      which stays nullable. Confirm this when implementing.

### postgrest-mcp

Deploy this before the semantius upgrade.

1. `src/db/hook.ts:584`: update when the row exists, instead of a partial
   `INSERT ... ON CONFLICT`, so a partial payload doesn't fail on a required field it
   doesn't send.
2. `src/SKILL.md:678`: `required` becomes "Editable and mandatory; the database refuses
   a missing value". Add the optional, backfill, then required route for populated tables,
   and that an entity whose writers don't send a label sets that field to `default`.
3. `src/tools/schemas/fieldSchema.ts:38-39`: match the new description.
4. Add step 5's refusal and the three new codes to the field rules in `src/SKILL.md`.
5. `src/SKILL.md:632`: an `enum` defaults to `''`, and a required enum with no
   `default_value` must be supplied on every write.
6. Run `npm run generate`.

### semantius-ui-kit

No planned change. The components derive `required` from `inputMode`, but it hasn't been
confirmed that they reject missing values on save or show `90258` clearly. Check both.

## Tests

### New: `apps/test/tests/0515_test_required_enforcement.sql`

Write as `user3`, not the owner, so `semantius_user` permissions are exercised. Each
refusal asserts the code and the hint keys.

**Missing values**
- Refused with `90258`, on insert and on update of an existing row:
  - `reference` to an integer key and to a text key, `date` and `date-time` as `NULL`.
  - Text as omitted, `''`, a space, a tab and a newline.
  - `json`, `object` and `array` as omitted, `{}`, `[]`, `null` and `""`.
  - `rating` as omitted and `0`, `binary` as empty, and `enum` as omitted and `''`.
- `23502` for an explicit `NULL` on required text and for an omitted `binary`.
- Accepted:
  - A real value in every format above.
  - `0` and `false` on required number and boolean fields.
  - An explicit `default_value`, including on an enum.
  - A computed field filling the required column.
- An enum value not in the list still returns 23514.
- A multi-row insert with one missing value fails as a whole.
- A partial upsert omitting a required field is refused, even when the row exists.

**Exemptions**
- No check on `is_pk` fields, on fields with an `input_type_rule`, or on unmanaged entities.
- A `parent` left out returns the foreign key error, unchanged.

**Every row of "Changes to `input_type`"**, each asserting the constraint's presence and
that no-op changes leave it untouched. Every check is `NOT VALID`.

**Adding a field**
- A required field on an empty table works.
- On a populated table, it's refused with `90259` without a default and accepted with one.

**Renames**
- After a field rename and a table rename, the check still refuses, and the hint names the
  new table and field.
- Renaming a field whose table has an old row with a missing value works.

**`required` with `clear`**
- `90257` when setting `required` on a `clear` reference, when setting `clear` on a required
  reference, and on insert of a field with both.
- Updating another column of such an existing field row still works.

**Old rows under a check**
- The row stays readable.
- An `UPDATE` of another column on it is refused with `90258`.
- An `UPDATE` that fills the value works.

**Labels**
- A label with the default `required` refuses an insert with no label, on any entity.
- A label set to `default` accepts one, including on a junction, whose `_label` still
  composes from its legs.
- A computed label passes.

**Families**
- `is_a`: writes through the view are refused for a missing value on the base's or the
  entity's own field, and the hint names the entity.
- `has_a`: the check applies only when the `_ext` row exists.

**Adoption**
- A table's own inline `CHECK`, auto-named `<table>_<col>_check`, survives unchanged.
- Checks are added to columns the table already has, and an enum's `_check` when no
  constraint has that name.
- A field with missing values is skipped with a warning, and adoption completes.

**Installing checks on existing fields**
- A field with no check gets one, a field with one is left alone, and a second pass changes
  nothing.
- A field with missing values is skipped, and gets its check on a later pass once the rows
  are clean.
- A `required` + `clear` field is skipped.
- A required enum's column default becomes `''`, including on an `is_a` view.

### New: a sweep in `apps/test/tests/0925_test_required_checks.sql`

Every required field of every managed entity, core tables included, has an `_assert` check
unless the design exempts it, and no other field has one. This catches a future path that
creates a field without calling the helper.

### New: `pgdocker` harness for concurrency

pgTAP runs in one session, so this needs two, in a `pgdocker/*.sh` script:
- While another session holds a table lock, the install function times out, skips that table
  and finishes the others, without queueing writers.
- While the search runs, writes to the table continue.

### Changes to existing tests

- `0510_test_enum_default_handling.sql`:
  - Scenario 4: an omitted insert fails with `90258`, and the `get_schema()` default is `''`.
  - `:479-485`: the refusal becomes `90259`.
  - `:493-498`: the refusal becomes `90258`.
- `0550_test_foreign_keys.sql:120-128`: becomes a `throws_ok` for `90258`.
- Fixtures that break. Start with the files that declare required fields: `0430`, `0435`,
  `0500`, `0580`, `0700`, `0840`, `0850`, and nwind `0020`, `0050`. A rough search of
  single-line inserts found 2 of 5 `territories` inserts without `territory_id`. Inserts
  with no label also break, and 41 test files create entities, including the unmarked
  junction fixture in `0670_test_composed_labels.sql`.
- `0850_test_raci.sql`, `0860_test_raci_gates_emit_trigger.sql` and `0840_test_queue.sql` must
  pass without changing what they assert. They exercise the system writers.

## Verification

1. The full sequence from `AGENTS.md`:
   ```bash
   deno task connect
   deno task dropall --confirm
   deno task migrate --apps _core,nwind,test --verbose
   deno task test
   ```
2. `pgdocker/pg-compare-installs.sh --upgrade v0.5.0-beta1`: an upgraded install must equal a
   fresh one. Both run the install function.
3. Upgrade a beta1 database under write traffic, seeded with rows that have missing values,
   and confirm that:
   - The migration completes and no writer waits more than a moment.
   - Fields with missing values are skipped with a warning, and their writers keep working.
   - Every other required field refuses a missing value.
   - Dump and restore keeps the constraints `NOT VALID` without failing.

## Out of scope

- **`readonly`, `disabled` and `hidden`:** the database doesn't enforce these either, but they
  need a separate decision.
- **Enforcing `input_type_rule` on the server:** it could run through
  `common.record_rules_<t>`, since validation rules already evaluate JsonLogic on the server.
  Until then, a rule-driven field stays UI-only.
- **The JSON Schema `required` array:** `inputMode` already covers this.
- **`VALIDATE CONSTRAINT`:** enforcement doesn't need it. It takes only a `SHARE UPDATE
  EXCLUSIVE` lock, so an operator can run it at any time to confirm a table is clean.
- **Other dictionary changes that scan under a lock:** adding a foreign key, `CREATE UNIQUE
  INDEX` and rebuilding `search_vector` all do today. This plan doesn't make them worse, but
  they break the production rule and need their own plan.
