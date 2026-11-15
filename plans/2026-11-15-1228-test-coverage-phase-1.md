# Phase 1: tests to complete coverage (no fixes)

Written 2026-11-15 12:28. Phase 2 (the fixes) gets its own plan, written from
the failures this phase produces.

## Context

A read-only review of the suite on 2026-11-15 found it broad but not complete:
several permission deny paths are never exercised as a user, no test feeds
hostile text into identifiers or free-text metadata, and the JsonLogic
interpreter and the rollup filter compiler have untested behaviors.

The work is split in two. This phase writes tests until coverage is complete and
re-measures it. It changes no code under test. A test that exposes a defect
fails and stays failing; fixing it is Phase 2.

## Baseline

Measured 2026-11-15 12:23 with `./pgdocker/pg-cli-retest.sh --coverage`: 89
files, all passing.

| Measure | Result |
|---|---|
| Functions called | 387 of 388 (99.7%). Never called: `rollup_rebuild_all()` |
| PL/pgSQL statements executed | 3379 of 3671 (92.0%), 292 open, in 99 partly covered functions |
| Tables touched | 38 of 38 |

Vendored pgmq is measured apart and is not a target. The line numbers below are
from that run's `coverage/uncovered.md`; re-run before starting if a migration
has changed since.

## Expected behavior the tests assert

Decided by the maintainer on 2026-11-15. Today's code differs in every point, so
the tests for them are red until Phase 2.

1. `users.external_id` of an existing user can be changed only by a holder of
   `admin`. `user:manage` alone is not enough. A direct owner or superuser
   connection is exempt.
2. A rule is checked when it is saved, for all three kinds (`select_rule`,
   `validation_rules[].jsonlogic`, `computed_fields[].jsonlogic`): an unknown
   operator anywhere is refused, and a select rule or validation rule that is
   not a single operator object is refused. `select_rule = {}` stays valid.
3. `_settings` and `_apikeys` cannot be registered as entities or adopted.
4. The JsonLogic interpreter follows the reference (JavaScript) semantics in
   the cases listed under step 4.
5. No generator wraps a generated function body in a fixed dollar tag.

## Rules for this phase

- Only `apps/test/tests/` and `apps/nwind/tests/` change, plus
  `apps/test/tests/0100_test_jsonlogic.json` and the SQL generated from it with
  `deno task testgen_jsonlogic`. No migration, CLI, seed or doc edit.
- A test asserts the intended behavior. Where the code differs, the assertion
  fails and stays: it is not weakened, skipped or marked `todo`. The runner
  counts every `not ok` as a failure and has no `todo` handling.
- Every assertion that may fail is a real assertion (`throws_ok`, `lives_ok`,
  `is(catch_error(...), ...)`), never a bare statement. A bare statement that
  raises aborts the file and hides every later assertion.
- A refusal whose error code does not exist yet is asserted by class, for
  example `matches(catch_error(...) ->> 'code', '^909')`. Phase 2 tightens it.
- Where the intended behavior is not decided, the test records what happens
  today and the case goes into the report as an open decision.
- Conventions are in AGENTS.md, "Testing Framework". A new subject takes a free
  number next to its closest relative; the same subject joins the existing file
  as a new part. Comments say what the behavior is and why, never this plan.
- A failure that is not listed as expected red is either a mistake in the new
  test, fixed here, or a newly found defect, added to the report.

## Execution order

The steps are numbered by subject, not by order. They run in two rounds.

**Round 1: steps 1, 2, 4 and 6**, in that order. Each is specified down to the
statement and is checked by the runner and the coverage report, so it needs no
judgment about what the code should do.

- After each step run `deno task test <prefix>*` for the files touched, and at
  the end of the round `./pgdocker/pg-cli-retest.sh --coverage`.
- Expected red in this round: the step 4 cases whose "Today" differs from
  "Expected". Nothing else is expected to fail. Any other failing assertion is
  left as written and listed; it is not changed until it passes, and no
  migration is touched to make it pass.
- Not in this round: `0650_test_computed_validation.sql:320-351` (step 3
  rewrites it), the `ru_both` comparison in `0555` (step 5), and
  `0535_test_identifier_hardening.sql` (step 7).
- The round ends with a hand-over in the session reply: the files changed, the
  coverage totals, every line of step 2 still uncovered with the reason, and
  every failing assertion with its file and description.

**Round 2: steps 3, 5, 7 and 8.** These decide whether a difference is intended
or a defect, and step 8 turns the failures into the input of Phase 2. Round 2
starts by reading the round 1 diff against the rules above.

## Step 1: the function no test calls

`rollup_rebuild_all()` (`0440_rollup.sql:1351`) regenerates every rollup
maintenance function and guard; it exists for the `.once.` file that ships with
a change to the builders. New part in `0555_test_rollup.sql`, as the owner: drop
one generated maintenance function (with its four triggers) and one guard, call
`rollup_rebuild_all()`, then assert both are back, the four triggers and
`a_rollup_guard` exist, and a child write still moves the parent total.

## Step 2: close statement coverage

For each uncovered line add the case that reaches it. A line that cannot be
reached gets its reason in the report (step 8).

| Test file | Function: uncovered lines |
|---|---|
| `0100` corpus, `0110` | `evaluate_json_logic` 592 (filter over a non-array), 624 (reduce without a start value), 753 (non-numeric index into an array), 915, 942, 956 (fractional result of `-`, `max`, `min`), 977 (`in` against a number or object), 1032-1033 (`log`); `jl_loose_eq` 120; `jl_try_number` 64; `jl_to_text`, `jl_truthy` (SQL NULL argument) |
| `0650`, `0655`, `0600` | `build_record_logic_trigger` 133-135, 214, 219, 288, 293, 298 (codes 90900 to 90904); `build_select_rule_policy` 976-979; `jl_error_hint` 50, 53; `manage_record_logic_trigger` 593; `manage_select_rule_policy` 1176; `computed_backfill` 800 |
| `0555` | `rollup_filter_literal` 202, 220, 224-225, 227, 231, 233; `rollup_filter_operand` 405, 415, 421-422; `rollup_filter_cond` 481, 484, 487, 505, 512, 517, 528, 534, 541, 556; `rollup_filter_date_arg` 265; `rollup_filter_date_op` 334, 343; `rollup_definition` 650, 663, 667, 671, 675, 679, 683, 697, 725; `rollup_backfill` 1243, 1250; `rollup_sync_field` 1289; `rollup_build_guard` 1164; `zz_rollup_entity_change` 1629; `zz_validate_rollup_field` 1409 |
| `0435` | `typeid_generate_text` 307, 311; `base32_decode` 183, 213, 217; `dd_sync_typeid_prefix` 2496; `is_a_part_missing` 4289; `get_record_by_id` 4681 |
| `0400` to `0480`, `05xx` | `update_dd_field` 1921, 1928, 1966, 1982-1984, 2019, 2029, 2141-2142, 2170-2171, 2174, 2176, 2180; `add_dd_field` 1697, 1739, 1745, 1751, 1757, 1772, 1809, 1842; `delete_dd_field` 2268-2269; `effective_enum_values` 711; `update_entity_policies` 2439; `create_entity_policies` 1240; `update_search_vector_column` 2593; `apply_field_ddl` 79, 81, 96, 109, 117, 126-129, 132, 134; `enable_dd_table` 200, 239; `dd_install_missing_checks` 535, 590-591; `rebuild_entity_label_functions` 774, 822; `validate_field_rename_and_format` 523-524; `rename_dd_table` 43; `handle_entity_order_column` 117 |
| `0490` | `ensure_entities` 345, 352, 363, 373, 379, 383, 388, 395, 401, 410, 416, 425, 431, 440, 446, 457, 464, 468, 498, 504, 510, 524, 590, 612, 616, 631, 647, 668, 922, 926, 933 (each refusal asserted with its message, not only its SQLSTATE); `ensure_entities_insert_rows` 128 |
| `0420` | `bump_module_version_from_related` 63, 70-71, 73, 87, 89, 94 (a row moved to another module); `bump_module_version` 21 |
| `0840` | `queue_build_record_json` 165, 193-194, 212-213 (a batch over the flush size); `queue_event_before_update` 113; `queue_event_after_insert` 267; `queue_event_after_delete` 342 |
| `0800`, `0810` | `audit.current_user_id` 112; `audit.enable_tracking` 424, 441-442 (code 90601); `manage_audit_log` 828, 833-834, 841; `audit.log_drop_event` 662 |
| `0200` to `0260`, `03xx` | `rbac.uid` 278-281; `rbac.ensure_context_initialized` 587-589; `rbac.user_id` 1312; `rbac.has_permission` 909, 963; `rbac.has_any_permission` 1018, 1036; `rbac.get_user_by_external_id` 428; `rbac.get_user_permissions` 1193; `rbac.upsert_user_from_jwt` 463; `rbac.default_assigned_by` 342; `rbac.default_granted_by` 376; `get_userinfo` 86, 152; `list_api_keys` 204 (90401); `delete_api_key` 262 (90402); `generate_api_key` 44 |
| `0700`, `0730`, `0850` | `get_schemas` 696; `fix_id_sequence` 962; `is_raci_actor` 87; `has_consultation` 138 |
| nwind and platform suites | Generated functions, reported without a source mapping: `common.record_rules_<t>` and `compute_validate_<t>` of the shipped entities, `select_rule_modules`, `select_rule_user_bookmarks`, `common.rollup_order_details_order_id`. Make every shipped validation rule fail once, and fire each trigger arm (insert, update, delete, truncate). What is left is the generated error handler, which no shipped rule can reach; the same handler is covered through a test entity in `0650`. |

Expected unreachable: `dd_dollar_quote` 84 (the body would have to contain the
md5 of itself).

Not visible as statements, but missing in every test file: the formats `html`,
`time`, `uri`, `uri-reference`, `uri-template`, `ipv4`, `ipv6`, `regex`,
`json-pointer`, `relative-json-pointer`, `byte`, `password` (`0500`: create a
field, write and read a value, default and required where the format allows; a
required `time` field added to a table that has rows); `precision` changed on an
existing field (`0520`); `unique_value` turned on for an existing field, with
and without duplicates (`0540`); `MERGE` against an audited table, a queue-mapped
table and a rollup child (`0820`); a multi-row insert into a table with an order
column (`0480`). Also give the four `throws_ok` calls that accept any error a
code: `0460_test_ddl_rename.sql:297`, `351`, `0840_test_queue.sql:544`, `546`.

## Step 3: rules at save time and at run time

`0650_test_computed_validation.sql:320-351` saves a computed field with an
unknown operator and checks what a write then raises. That is two subjects, and
after decision 2 the save itself is refused, so the part becomes three cases,
each on its own entity:

1. **Save.** Inserting an entity whose computed field is `{"unknown_op":[1,2]}`
   is refused with a class 909 code and no entity row is left behind. Same for a
   validation rule with an unknown operator, a validation rule
   `{"==":[1,1],"x":2}`, and in `0600` a `select_rule` with an unknown operator
   and one with two keys. `select_rule = {}` is accepted. Expected red.
2. **Run time, an error of ours passes through the generated trigger
   untouched.** This needs no unknown operator, only a rule that is valid when
   saved and fails on the row: computed field
   `{"date_add":[{"var":"label"},1,"day"]}`, insert with label `boom`. Expect
   code 90915, the message `${operator} needs an ISO 8601 date or date-time, not
   ${value}` unprefixed, and the hint `{"operator":"date_add","value":"boom"}`
   with no key added. Green now and after the fix.
3. **Run time, a stored rule with an unknown operator.** This is an installation
   whose rules were saved before the check existed. Store the rule past the
   save path: create the entity and its field normally, then as the owner
   `ALTER TABLE entities DISABLE TRIGGER USER`, set `computed_fields`, enable the
   triggers again, and call `build_record_logic_trigger` for the table. Assert
   what lines 340-351 assert today: a write raises 90910 with the message
   unprefixed and the hint `{"op":"unknown_op"}`. Green now.
   In `0600`, the same fixture for `select_rule`: record what a reader sees for
   a stored rule with an unknown operator (today every row is hidden, with no
   error) and for one with two keys (today every row is visible). The second is
   an open decision for the report: a stored rule of that shape keeps exposing
   rows until it is rewritten.

Case 3 stays green after the fix only if the save check is a trigger of its own
on `entities` and not part of `build_record_logic_trigger` or
`build_select_rule_policy`. If the check sat in the builders, a stored rule of
this kind would also block every later rebuild of that entity (a rename, a
managed flip). To be confirmed in the Phase 2 plan.

## Step 4: JsonLogic interpreter

A case goes into the shared corpus `0100_test_jsonlogic.json` only when plain
JavaScript gives the same answer, because the browser evaluator's suite reads
that file and may turn red with it. Everything else goes into
`0110_test_jsonlogic_ext.sql`. After editing the JSON run
`deno task testgen_jsonlogic`.

| Rule | Expected | Today | Goes into |
|---|---|---|---|
| `{"in":[null,"abc"]}`, `{"in":[{"var":"missing"},"abc"]}` | `false` | `true` | corpus |
| `{"in":["","abc"]}` | `true` | `true` | corpus |
| `{"<":["abc",5]}`, `{"<=":["abc",5]}`, `{">":[5,"abc"]}`, `{">=":[5,"abc"]}` | `false` | `true` | corpus |
| `{"<":[null,5]}`, `{"<":["",5]}` | `true` | `true` | corpus |
| `{">":["NaN",0]}`, `{">":["infinity",0]}`, `{">":["today",0]}` | `false` | `true` | corpus |
| `{">":["Infinity",0]}` | `true` | `true` | corpus |
| `{"*":[10000000000,10000000000]}` | `100000000000000000000` | raises 22003 | corpus |
| `{"substr":["abc",0,-5]}` | `""` | raises 22011 | corpus |
| `{"===":[1]}` / `{"!==":[1]}` | `false` / `true` | SQL NULL | corpus |
| `{"!!":[{}]}` | `true` | `true` | corpus |
| `{"%":[1,0]}` | `null` | raises 22012 | `0110` |
| `{"/":[1,0]}` | `null` | `null` | `0110` |
| `{">":["01/02/2026",0]}` | `false` | depends on DateStyle | `0110` |
| `{"-":["2026-01-05T01:00:00+02:00","2026-01-04T23:00:00Z"]}` | `0` | `7200` | `0110` |

## Step 5: rollup filter compiler

All in `0555_test_rollup.sql`, extending the `ru_both` comparison at lines
246-263, which today covers the date operators only.

- **Both ways over the same rows.** A fixture table with text, integer,
  numeric, boolean, date, date-time and UUID columns and NULLs in each nullable
  one. Every operator of the subset: `==`, `===`, `!=`, `!==`, `<`, `<=`, `>`,
  `>=`, three-operand `<` and `<=`, `in` with strings and with numbers, `and`,
  `or`, `!`, `!!`, a bare boolean column, a boolean literal, `{}`. `!!`, `===`,
  `!==` and `>=` are compiled by no test today.
- **Where the two are meant to differ**, assert each side's own count: an
  ordering comparison against a NULL column (`docs/rollup-fields.md:154`), a
  string column against a number literal, an `in` list of strings against a
  numeric column.
- **Where they differ and nothing says so**, record both counts as an open
  decision: `!` over a NULL comparison, and text ordering under the column's
  collation against the interpreter's `"C"`.
- **Refusals** are written in step 2, which lists the uncovered lines of
  `rollup_filter_*`. Check here that none of these is missing:
  `>` and `>=` with three operands; `==` with one and with three; `!` with two;
  `and` with none; `in` with a non-list; an array as an operand;
  `{"var":["a",1]}`; a boolean or a string against the wrong column type; a
  number against a boolean or TypeID column; two columns of different types; a
  column type outside the allow-list (`0440_rollup.sql:165-167`).
- **Run time.** A child row whose date is `infinity`, and one whose bigint
  amount is beyond the integer range, under a filter with a date operator. The
  comment at `0440_rollup.sql:296-299` promises such a write cannot fail.
  Possibly red.

## Step 6: permissions

Policies, grants and constraints are not PL/pgSQL statements, so the coverage
report cannot list them.

- **Deny-all tables** (`0390`): as `user1` and as `user3`, `SELECT` from
  `_settings` and `_apikeys` returns no row, `INSERT` raises 42501, `UPDATE`
  and `DELETE` change nothing.
- **RBAC and catalog tables** (`0390`): as `user1` and `user2`, `UPDATE` and
  `DELETE` on `user_roles`, `role_permissions`, `user_permissions`, `roles`,
  `permissions`, `permission_hierarchy` and `entities` leave every row as it
  was; `SELECT` on the first four shows only what the policy allows.
- **Audit logs** (`0800`): read the policies at `0200_audit_log.sql:868-889`,
  then assert the read and the delete for a caller they exclude.
- **Hierarchy** (`0350`): removing an edge removes the effective permission.
- **`get_schema_children`** (`0700`): no test calls it; assert its result for a
  caller with and without the view permission.
- **`select_rule` writes** (`0610`): a caller who sees a row through the rule
  but lacks the edit permission cannot write it; an insert outside the caller's
  own rule and an update that moves a row out of it behave as
  `0210_computed_validation.sql:1116-1120` says.
- **`edit_permission` changed on a live entity** (`0450`): the former editor is
  denied afterward.
- **Rollup** (`0555`): adding a `select_rule` to the child of an existing
  rollup is re-validated.
- **pgmq** (`0830`): the request role holds no table privilege on a queue table.
- **Role attributes** (`0970`): `semantius_user` does not bypass row-level
  security.
- **Last Administrator** (`0370`): the guard covers `DELETE` and `is_disabled`
  only (`0100_rbac_rls.sql:290-320`). Record what happens for an
  `UPDATE user_roles` that re-points the last administrator's row and for
  removing `admin` from role 2. Open decision.

## Step 7: hostile input and the remaining decisions

New file `0535_test_identifier_hardening.sql`, next to `0530`.

- **Identifiers.** For `entities.table_name`, `id_column`, `label_column`,
  `label_parent`, `order_column` and `fields.field_name`, each of: a double
  quote, a single quote, a semicolon, a space, an uppercase letter, a hyphen, a
  dot, a dollar sign, a non-ASCII letter, a leading digit, a trailing newline.
  Each is refused with 23514 and the message names the constraint
  (`0130_dd_schema.once.sql:84-205`). No table or role the attempts named exists
  afterward.
- **Long and colliding names.** A table name over 63 bytes; two names sharing
  their first 63 bytes; table `a_b` with field `c` next to table `a` with field
  `b_c`, both `unique_value` (`0160_dd_functions.sql:1814`, `1837`). Intended:
  refused, or both work and both uniqueness rules hold. Possibly red.
- **Reserved words.** Entities and fields named `user`, `order`, `select`,
  `group`: create, insert, read, rename, delete.
- **Metadata text.** Enum values, `title`, `description`, `plural_label` and
  `singular_label` containing `O'Brien`, `50%`, `a$b$`, `back\slash` and
  `"quoted"`: the entity builds, the table and column comments return the text
  exactly, the enum CHECK accepts exactly those values, `get_schema` returns
  them.
- **Dollar tags.** A has_a entity whose base column has the default `x$RW$y`
  (and with `$VW$`, `$DISPATCH$`, `$body$`): the family builds and the default
  applies. In `0910_test_no_unsafe_functions.sql`: no generator's source
  contains `AS $<fixed tag>$`. Expected red for `dd_build_record_write`,
  `dd_build_view_write`, `dd_build_is_a_dispatch`
  (`0160_dd_functions.sql:3915`, `4124`, `4195`) and
  `rebuild_entity_label_functions` (`0180_managed_enable.sql:832`, `865`).
- **`external_id`** (`0390`). The fixture at
  `0370_test_last_administrator.sql:88-91` builds a caller with `user:manage`
  and no `admin`. That caller's `UPDATE users SET external_id` raises 42501 on
  its own row and on `user3`'s row, and both rows are unchanged. As `user3` the
  update succeeds. The caller can still change `email` and `display_name`.
  Expected red.
- **Internal tables** (`0960`). `INSERT INTO entities` naming `_settings` or
  `_apikeys` is refused with a class 90 code. Expected red.

## Step 8: final run and report

```bash
./pgdocker/pg-cli-retest.sh --coverage
```

The report goes into the session reply, not into a file:

1. Coverage before and after: functions, statements, tables.
2. Every statement still uncovered, with the reason.
3. Every failing assertion, mapped to the defect it exposes and marked as
   expected red or newly found. This list is the input of the Phase 2 plan.
4. The open decisions collected in steps 3, 5 and 6.

AGENTS.md requires every task to end with a passing suite. This phase is the
agreed exception: it ends with the complete test output shown and with exactly
the failures list 3 explains.

## Outcome

Executed 2026-11-15, both rounds. Final run on a fresh container
(`./pgdocker/pg-cli-retest.sh --coverage`): 4990 passing, 89 failing, no file
aborted. The failing assertions by defect and the open decisions are in
`2026-11-15-1430-fixes-phase-2.md`, section "From Phase 1"; they are not
repeated here.

| Measure | Baseline | After |
|---|---|---|
| Functions called | 387 of 388 | 388 of 388 |
| PL/pgSQL statements executed | 3379 of 3671 (92.0%) | 3581 of 3671 (97.5%) |
| Tables touched | 38 of 38 | 38 of 38 |

Changed: 35 test files, and four new ones (`0445_test_field_ddl_edge_cases.sql`,
`0535_test_identifier_hardening.sql`, `0665_test_shipped_record_rules.sql`,
`apps/nwind/tests/0060_test_nwind_record_logic.sql`). Nothing under test changed.

Failures per file: `0100` 13, `0110` 16, `0390` 4, `0420` 1, `0500` 2, `0535` 13,
`0540` 6, `0555` 9, `0600` 5, `0610` 1, `0650` 7, `0700` 3, `0910` 1, `0960` 8.

Added after that run, on the maintainer's decision that a literal is no rule:
two red assertions in `0650` (a validation rule whose condition is a text
literal or `true` is refused at save) and two green ones in `0600` (the CHECK
`select_rule_is_object` already refuses a literal `select_rule`). That makes 91
failing, 9 of them in `0650`; only those two files were re-run.

Later the same day the maintainer settled the open decisions, and the tests in
`0110`, `0390`, `0555`, `0600`, `0650` and `0960` were changed to follow them
(see "Decisions" in the Phase 2 plan). The suite then stands at 97 failing; the
list per step is in the Phase 2 plan. The step 4 table above still says null
for `/` and `%` by zero: that was replaced by "an error, as in SQL".

### Defects this phase exposed

Counted on 2026-11-15, after Phase 2 was executed. A defect is one entry of
Part A or Part B of the Phase 2 plan.

- **12 defects** ended this phase with at least one failing assertion: A1 to
  A6, B4, B8, B11, B16, B17 and B18. Together they held 89 failing assertions
  at the end of this phase's own run, and 97 once the tests followed the
  maintainer's decisions.
- **3 of the 12 were found by this phase** and were not known before it: B16
  (`unique_value` on a column that is not text), B17 (a role moved to no
  module) and B18 (a keyed write that moves a row out of the writer's rule).
  The other 9 were known or suspected from the review that preceded this
  phase, and this phase turned each into a failing test.
- **2 of the known ones turned out wider than reported**: B4 (two more values
  a rollup date operator cannot read) and B8 (the effect of a cut or shared
  generated name, run for the first time).
- A4 is one entry and seven separate wrong answers of the JsonLogic
  interpreter.

Phase 2 fixed all 12. The 12 entries of Part B that had no failing test (B1,
B2, B3, B5, B6, B7, B9, B10, B12, B13, B14, B15) are open; this phase recorded
today's behavior for B1, B3 and B13.

### Statements still uncovered (90)

- **Generated error handlers, 55**, in `common.record_rules_*`: no shipped rule
  can raise into them (step 2, last row).
- **Unreachable, 15.** `dd_dollar_quote` 84. `rollup_filter_literal` 233,
  `rollup_filter_operand` 422, `rollup_filter_cond` 556: a `RETURN NULL` after a
  call that always raises. `manage_audit_log` 841, `manage_record_logic_trigger`
  593, `manage_select_rule_policy` 1176: no event their triggers are declared
  for reaches the line. `add_dd_field` 1739, 1745, 1751, 1757
  (`one_pk_per_table_idx` refuses a second key row first) and 1772
  (`validate_reference_table` raises the same 90212 first). `update_dd_field`
  1966, 2019 (`dd_field_comment` never returns NULL). `enable_dd_table` 200 (the
  trigger's `WHEN` is the same condition).
- **Needs an `oauth:` connection, 10.** `rbac.uid` 278-281,
  `ensure_context_initialized` 587-589, `rbac.user_id` 1312, `has_permission`
  909, `has_any_permission` 1018.
- **Needs a second session, 1.** `fix_id_sequence` 962; the container harness
  covers it.
- **Reachable only through a contrived fixture, 5.** `get_userinfo` 86, 152 (a
  trigger on `users` that removes the row), `has_permission` 963,
  `has_any_permission` 1036 (deleting the grants of role 1),
  `queue_event_after_insert` 267 (dropping the foreign key). Such cases were
  written and removed again on the maintainer's decision: the suite holds only
  cases a client can trigger.
- **Not mapped to a line, 4.** Three in `evaluate_json_logic`, one in
  `select_rule_user_bookmarks`.

### Deviations from this plan

- Step 4: `{"*":[10000000000,10000000000]}` and `{"substr":["abc",0,-5]}` are in
  `0110`, not in the corpus. They raise today, and the generated corpus file is
  made of bare statements, so one raise aborts it and hides every other case.
  The generator is not changed for this; the cases move when they return a
  value.
- Step 2, `time`: the plan left a required `time` field on a table with rows
  undecided. The maintainer decided on 2026-11-15 that `time` is nullable like
  `date`; the two assertions in `0500` assert that and are red.
- Step 3: the save cases also cover an unknown operator below the top of a rule
  and an UPDATE of an existing entity.
- Step 7, identifiers: the cases also run on the update and rename path, because
  the table is renamed before the CHECK refuses the row. `label_parent` is
  refused with 90226 by its trigger before the CHECK; 23514 is asserted with
  the trigger disabled.
- Step 7, internal tables: each registration attempt runs in a subtransaction
  that is rolled back, because deleting a managed `_apikeys` entity drops the
  table.
- Running: `deno task test` in this checkout reads a `DATABASE_URL` that points
  at a cloud database. Every run of this phase went to the local container with
  `--database-url`, as `pg-cli-retest.sh` does.

## Not in this phase

- Any fix to migrations, the CLI or the docs, including `SECURITY.md` and
  `docs/error-contract.md`.
- CI: `.github/workflows/test.yml` has never run, and it runs coverage before
  the lifecycle script although `docs/test-coverage.md:187-193` says that makes
  lifecycle step 10 fail.
- The Deno unit tests and the `pgdocker` race, lock and auth harnesses.
- Rules after a rename: a field rename rewrites no rule, and a table rename
  replaces every quoted occurrence of the old name in a rule that contains
  `set_record` (`0170_dd_rename.sql:365-384`).
- The `$old` detection for `{"var":[{...}, default]}`
  (`0210_computed_validation.sql:198-200`).
