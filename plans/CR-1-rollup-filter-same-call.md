# CR 1: Compile a rollup's filter against fields created earlier in the same `create_field` call

## Problem

A `create_field` call may create a child's field and a rollup that reads it, as long as the rollup comes later in the array. This already works for `link_field` and `value_field`, and use-semantius documents it (`rollup-fields.md`). A rollup `filter` that reads such a field is refused with `90265`, because the column does not exist yet.

## Seen in

One agent run on tests.semantius.ai (2026-11-12):

1. One `create_field` call held 47 items: the fields of five new entities, including `job_applications.workflow_state` (an enum) and `job_applications.job_opening_id` (a reference).
2. Two rollups on `job_openings` came last in the array:
   - `application_count`: `{"link_field": "job_applications.job_opening_id", "function": "count", "include_hidden_rows": true}`
   - `hired_count`: the same, plus `"filter": {"==": [{"var": "workflow_state"}, "hired"]}`
3. The call failed, and nothing landed:

   ```
   (90265) Rollup hired_count on job_openings: the filter cannot be compiled: column workflow_state does not exist on job_applications
   ```

4. The 45 non-rollup items then went through in one call, and the 2 rollups, unchanged, in a second call. Both succeeded.

Part 9 of `0555_test_rollup.sql` (see Tests) reproduces it.

## Impact

Every build with a filtered rollup over a new child field fails on its first `create_field`. use-semantius sends all fields of a model in one call with rollups last (`data-modeling.md`, `rollup-fields.md`, `crud-tools.md`), so every agent that follows it hits this. The workaround, a second call for the rollups, gives up the single transaction.

## Cause (confirmed in the code)

- The filter is compiled in the BEFORE ROW trigger `zz_validate_rollup_field`, through `rollup_definition` and `rollup_filter_column`, which resolves a `var` in `pg_attribute` of the child (`0440_rollup.sql:151-159`).
- Columns are created by `add_field_trigger`, an AFTER INSERT ROW trigger (`0160_dd_functions.sql:1843`). In a multi-row INSERT every row's BEFORE triggers run first; the AFTER triggers are queued and fire row by row once all rows are inserted, each row's in name order (`add_field_trigger` before `zz_rollup_field_change`). So at BEFORE time no column of the statement exists.
- `link_field` and `value_field` are looked up in `fields`, which already holds the earlier rows, so they pass.

## Fix

Compile the filter after the columns exist: in the rollup row's own AFTER trigger. `zz_rollup_field_change` already calls `rollup_definition` there, through `rollup_sync_field` (`0440_rollup.sql:1263`). At that point every earlier row's column exists and no later row's does, which is exactly the rule of criterion 2.

Not the catalog option (resolving the filter's columns from `fields`):

- At AFTER time every row of the statement is already in `fields`, so a field later in the array would pass, which breaks criterion 2.
- The EXPLAIN probe cannot run against a column that does not exist, so the compile has to wait anyway.
- It adds a second type source; the compiler takes the catalog type on purpose (`0440_rollup.sql:134-138`, `161-163`).

## Trigger order this relies on

The fix renames, adds and moves no trigger. The triggers the rollup builders generate (`a_rollup_guard`, `update_<t>_updated_at`, `rollup_<child>_<link>_ins/_upd/_del/_trc`) keep their names and bodies, so the BEFORE order on record tables listed in `build_record_logic_trigger` (`0210_computed_validation.sql`) and pinned by `0657_test_computed_trigger_order.sql` is untouched.

It depends on two orders of the triggers on `fields`, which nothing documents or pins today:

1. **AFTER ROW events of a multi-row INSERT fire row by row**, once every row is inserted: all AFTER triggers of row 1, then of row 2, and so on. This is what makes every earlier row's column exist, and no later row's, when a rollup row's AFTER trigger runs.
2. **Within one row they fire in name order (byte order)**: `add_field_trigger`, `bump_module_version_on_fields`, `handle_field_parent_format_change_trigger`, `notify_pgrst_on_fields_change`, `zz_computed_field_added`, `zz_rollup_field_change`, `zzz_label_fn_field_insert_trigger`; then the statement-level `handle_field_searchable_insert_trigger`. `add_field_trigger` before `zz_rollup_field_change` is what makes the rollup's own column exist when its filter is compiled. None of the triggers in between reads the compiled filter.

The BEFORE INSERT order on `fields` is unaffected: `zz_validate_rollup_field` still sorts last, after `a_auto_order_fields`, `fields_ctype_lock` and `zz_derive_computed_ctype`.

## What the fix must handle

1. **The EXPLAIN probe.** It runs only in the BEFORE trigger, and only when `filter_sql` is set (`0440_rollup.sql:1410-1421`). With the compile postponed it would stop running on INSERT, and a literal the column cannot be cast from would fail in the backfill as PostgreSQL's 22P02 instead of 90265. It cannot move into `rollup_definition`: that function is STABLE, and PL/pgSQL refuses EXPLAIN in a non-volatile function.
2. **No filter-less rollup.** The builders read a NULL `filter_sql` as TRUE (`0440_rollup.sql:936`). The compile may only be skipped where the builders skip the rollup anyway. Catching 90265 and returning NULL would build a rollup that counts every row, without an error.
3. **An unmanaged parent.** `add_dd_field` creates no column for an unmanaged entity, so its rollup's own column never appears. Its filter keeps being compiled when the field is saved, as today.

## Implementation

All in `apps/_core/migrations/0440_rollup.sql` (repeatable). No signature change, no new function, no `.once.` file: the generated bodies do not change, so `rollup_rebuild_all()` is not needed.

1. **`rollup_definition`, the filter compile (`848-859`).** Compile only when the field's own column exists or the parent is unmanaged:

   ```sql
   IF v_child.managed AND pg_catalog.to_regclass(format('public.%I', v_child_rel)) IS NOT NULL
      AND (v_col_type IS NOT NULL OR NOT v_parent.managed) THEN
   ```

   In a multi-row INSERT the own column exists exactly when this row's `add_field_trigger` has run. BEFORE INSERT skips the compile; the AFTER trigger compiles strictly and raises 90265 with the same message and hint. A builder that reaches another row's rollup whose column does not exist yet gets `filter_sql` NULL with `column_exists` false and skips it, as now. UPDATE is unchanged: the column exists, so the BEFORE trigger compiles as today.
2. **Move the EXPLAIN probe (`1410-1421`)** from `zz_validate_rollup_field` into `rollup_sync_field`, right after `rollup_definition` and before `rollup_build_link`, `rollup_build_guard` and `rollup_backfill`. One place then covers INSERT, a definition change on UPDATE, and an entity switched to managed (`zz_rollup_entity_change`), which compiles today but never probes. Every caller is SECURITY DEFINER, so the probe still runs as the owner.
3. **Comments to bring in line:**
   - the header (`115-117`): the probe runs from `rollup_sync_field`;
   - the `filter_sql` note of `rollup_definition` (`610-611`): also NULL while the field's own column does not exist yet;
   - `834-837` and `848`: why the compile waits for the field's own column, naming the two trigger orders it depends on (row-by-row AFTER events, `add_field_trigger` before `zz_rollup_field_change`);
   - `1470-1472` (`zz_rollup_field_change`): its name must keep sorting after `add_field_trigger`, now also because the filter is compiled there;
   - `COMMENT ON FUNCTION zz_validate_rollup_field()` loses "and probes the compiled filter with EXPLAIN"; `COMMENT ON FUNCTION rollup_sync_field(fields, BOOLEAN)` gains it.
4. **`docs/rollup-fields.md`, section "The filter":** one sentence of client contract. In one insert of several fields, a rollup may name fields created by earlier rows, as its link field, its value field or in its filter, never fields created by later rows. The 90265 row of `docs/error-contract.md` stays as it is.
5. **Rebuild the extension:** `deno task extension <default_version from extension/pg_semantius.control>`. The working tree already holds unrelated uncommitted changes in `extension/` and other migrations; the rebuild carries them too.

## Tests

The existing refusals (`0555_test_rollup.sql:586-626`) insert through `pg_temp.ru_def`, so after the change they run through the AFTER path and pin the same code and message, including a column that exists nowhere (`596`) and the hint naming the table and the field (`612-616`). They need no change.

New Part 9 in `apps/test/tests/0555_test_rollup.sql`, with its own fixtures (two new entities on module 1, `public:read` / `admin`); the header's part list and `plan(179)` are updated:

1. One INSERT: a child link field, an enum, a number and a boolean, then a parent `count` filtered on the enum and a `sum` of the number filtered on the bare boolean. `lives_ok`. This also pins `link_field` and `value_field` created in the same statement, which no test covers today.
2. Child rows inserted: both totals are right, and a row the filter excludes is not counted (guards against a filter-less build).
3. A filter naming a field that comes later in the same INSERT: 90265, hint `problem` = `column <name> does not exist on <child>`.
4. A filter on a JSON column created in the same INSERT: 90265.
5. A same-INSERT integer column compared with `"abc"`: 90265, not 22P02 (the probe on the INSERT path).
6. An existing rollup's filter changed by UPDATE to a literal its column cannot be cast from: 90265 (the probe on the UPDATE path; no test today).
7. A tree: a rollup of an entity over its own records, whose filter names a column created in the same INSERT as the link field and the rollup.
8. The trigger order on `fields` the fix relies on, by name from `pg_trigger` (`COLLATE "C"`, as `pg_temp.before_triggers` in `0657_test_computed_trigger_order.sql` does): `add_field_trigger` sorts before `zz_rollup_field_change` among the AFTER INSERT row triggers, and `zz_validate_rollup_field` is the last BEFORE INSERT row trigger. Tests 1 and 3 pin the behavior; this one names the cause when a rename breaks it.

## Acceptance criteria

1. One `create_field` call with a child enum field followed by a parent `count` rollup whose filter reads that field succeeds, and the rollup counts correctly.
2. A filter naming a field that exists nowhere, or only later in the array, still fails with `90265`, matching the existing rule for `link_field` and `value_field`.
3. A filter on a column whose type the filter subset does not allow still fails with `90265`.
4. A literal the column cannot be cast from still fails with `90265`, on INSERT and on UPDATE.
5. Code, message and hint of every `90265` are unchanged.

## Verification

```bash
deno task connect                                     # if this fails, stop
deno task dropall --confirm
deno task migrate --apps _core,nwind,test --verbose
deno task test 0555*                                  # quick loop while working
deno task test                                        # full suite before done
```
