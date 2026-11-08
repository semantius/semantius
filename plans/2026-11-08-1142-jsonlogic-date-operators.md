# JsonLogic date operators and UTC enforcement

## Context

`evaluate_json_logic` has no date operators. Date strings become epoch seconds in
arithmetic, and nothing converts a number back to a date, so a computed date such
as `notice_deadline = term_end - notice_period_days` cannot be expressed. The
integer workaround is either unreadable (epoch days) or goes stale (days remaining
from `$today`, because computed fields only run on write).

This plan adds six date operators on the server and in the browser, enforces UTC
everywhere, and fixes the browser's missing custom operators.

The product is not live: no upgrade path, no new migration file, and unreleased
`.once.sql` files may be edited.

## Working rules

- Edit on each checkout's existing default branch: `main`, and `semantius` for
  `postgrest-mcp`. No branches. No commits, including this file and `extension/`.
- We are not live: create no new migration file. Every migration change below
  edits an existing file in `apps/_core/migrations/`.
- Docs have no tests.

## Operators

| Operator | Result |
|---|---|
| `{"date_add":[date, amount, unit]}` | Same type as the input. A negative amount subtracts. Month ends clamp (Jan 31 + 1 month = Feb 28). |
| `{"date_add":[date, duration]}` | As above, with an ISO 8601 duration. Applied months first, then days, then time, as Postgres does. |
| `{"date_diff":[end, start, unit]}` | Whole elapsed units as an integer, truncated toward zero, same order as `-`. Months and years follow Postgres `age()`. |
| `{"date_part":[date, part]}` | Integer: `year`, `iso_year`, `quarter`, `month`, `week` (ISO), `day`, `weekday` (Mon=1), `day_of_year`, `hour`, `minute`, `second`, `epoch`. |
| `{"date_trunc":[date, unit]}` | Start of the period, same type as the input. |
| `{"to_date":[value]}` | ISO date. Accepts a date, a date-time or an epoch number. Numbers are read as UTC, which reverses the epoch cast at `0050_jsonlogic.sql:57`. |
| `{"date_format":[date, pattern]}` | Text. Tokens: `YYYY YY Q MM Mon Month DD Dy Day HH24 MI SS` plus common separators. English names, no blank padding. |

Units are `year quarter month week day hour minute second`.

### Shared rules

- Null or `""` for a date, amount or duration gives null out.
- Only ISO 8601 is accepted, through a regex gate, so `today`, `infinity`, J-dates
  and locale formats are refused.
- Offsets are honored. A date-time with no offset is read as UTC.
- Fractional seconds are accepted. Date-time output is truncated to whole seconds
  on both sides and rendered as `YYYY-MM-DDTHH:MM:SS+00:00`.
- `date_add`, `date_trunc`, `date_part` and `date_format` refuse sub-day units,
  parts and tokens on a date-only value. `date_diff` reads a date-only value as
  midnight UTC and allows every unit.
- An amount is a whole JSON number or a numeric string.
- A duration is ISO 8601, including the per-field minus signs Postgres emits.

### Errors

| Code | Raised for |
|---|---|
| `90915` | A value that is not a date |
| `90916` | An unknown unit or part, a missing unit, a sub-day unit or part on a date-only value, or a duration with a time part on a date-only value |
| `90917` | A `date_format` pattern outside the token list, or a sub-day token on a date-only value |
| `90918` | An amount or duration that is not valid |

The hint carries the operator and the value, because class 90 errors skip the step
that adds entity and field. A well-formed impossible date such as `2026-02-30`
raises Postgres's own `22008`.

## UTC enforcement

- **Operators:** helpers convert to a UTC `timestamp` with `AT TIME ZONE 'UTC'` and
  all math runs on that value, so results cannot depend on the session zone. They
  need no `SET`: a `SET` on a helper ends when it returns, and
  `evaluate_json_logic` has none.
- **Rule data:** these get `SET timezone = 'UTC'` and
  `SET intervalstyle = 'iso_8601'`, so `$today`, `$now` and row values all render
  in UTC and durations in ISO 8601:
  `common.record_rules_<t>`, `compute_validate_<t>`, both `select_rule_<t>`
  overloads, `common.record_write_<t>`, `computed_backfill`, `jl_request_context`.
- **Database default:** `ALTER DATABASE <current_database()> SET timezone = 'UTC'`
  and `SET intervalstyle = 'iso_8601'`. This covers a client sending a date-time
  with no offset, which Postgres reads in the session zone before any rule runs.
  It raises an error if the role is not the owner.
- **Browser:** UTC methods only. `$today` and `$now` are UTC.

## Changes

### `C:\dev\semantius`

- `apps/_core/migrations/0050_jsonlogic.sql`: parsing helpers and six branches,
  placed just before the `Unrecognized operation` raise so existing operators pay
  nothing. Each branch is written literally as `IF op = 'date_add' THEN`, because
  the sem-schema sync test only recognizes that form. Helpers follow the COMMENT,
  REVOKE and GRANT pattern at lines 901-929, with `SET search_path = public`. No
  EXCEPTION block in the parser.
- `apps/_core/migrations/0210_computed_validation.sql`: the `SET` clauses on the
  generated `record_rules`, `compute_validate` and `select_rule` functions,
  `computed_backfill` and `jl_request_context`; the header comment at lines 16-17
  says UTC.
- `apps/_core/migrations/0160_dd_functions.sql`: the `SET` clauses on the generated
  `record_write_<t>`.
- `apps/_core/migrations/0020_settings.once.sql`: the database defaults.
- `apps/_core/migrations/0440_rollup.sql`: the date operators as filter values, and
  date literals resolved to UTC when a filter is compiled.
- `docs/error-contract.md`: rows for 90915 to 90918.
- `extension/`: regenerate with `deno task extension 0.5.0-beta1` after the last
  SQL edit and confirm with `--check`.

### `C:\dev\schema-poc-1\packages\sem-schema`

Make the same edits in `C:\dev\semantius-app\packages\sem-schema`: the app builds
from that tracked copy, and the two are byte-identical today.

- `src/jsonlogic/operators.ts`: `date_add(2,3)`, `date_diff(3,3)`, `date_part(2,2)`,
  `date_trunc(2,2)`, `to_date(1,1)`, `date_format(2,2)`. Export the unit, part and
  token lists beside `RACI_LETTERS`, and from `index.ts`.
- `src/jsonlogic/validate.ts`: reject unknown literal units and parts and invalid
  literal `date_format` patterns when a rule is edited.

### `C:\dev\semantius-app`

- New `apps/web/src/lib/jsonLogicDates.ts`: registers the six operators on the
  shared `json-logic-js` engine and imports the lists from `sem-schema`. Plain
  calendar math on date-only values, with no `Date` objects or date-fns, so results
  cannot shift with the browser's zone or differ from Postgres at month ends.
- Existing bug: `concat` is the only custom operator registered in the browser, so
  `has_permission` in an `input_type_rule` fails and silently falls back. Register
  `has_permission` (reusing `lib/permissions.ts`) and `is_match`.
- `apps/web/src/contexts/AuthContext.tsx`: publishes the signed-in user to the rule
  module, because operators are global and synchronous and `SchemaForm` does not
  use `useAuth`.
- One shared context builder supplies `$today`, `$now` and `$user_id` at all three
  evaluation sites: `computedFields.ts:164`, `computedFields.ts:249` and
  `SchemaForm.tsx:109`.
- `apps/web/src/components/form/SchemaForm.tsx`: evaluate `input_type_rule` through
  `applyJsonLogic` so `let` works. Rules containing `set_record` keep falling back
  to the static `input_type`, because no record lookup exists there.

### `C:\dev\semantius-agent\semantius-plugin\skills\use-semantius\references`

- `jsonlogic.md`: new `#### Date operators` section between the `concat` section
  and cross-entity lookups, covering the operators, epoch coercion, the null trap
  (a null date counts as 1970 in arithmetic) and the warning that a computed field
  reading `$today` goes stale. Also the documented differences below.
- `jsonlogic.md:77-78` and `526-527`: `$today` and `$now` are UTC.
- `jsonlogic.md:135`: `value_changed`, `require_permission`, `is_raci_actor` and
  `has_consultation` cannot run in the browser.
- `select-rule.md:28`: UTC wording.

### `C:\dev\semantius.com\apps\web\src\content\docs\business-logic`

- `extensions.mdx`: one `###` section per operator in the **Form:** layout of
  `is_match`; the `$today` description says UTC.
- `jsonlogic.mdx:89`: add the six names.

### `C:\dev\postgrest-mcp` (branch `semantius`)

- `src/SKILL.md:403-404`: UTC wording, then `npm run generate` for
  `instructions.ts`.

## Differences to document

- A bad date leaves the field unchanged in the form, because both browser call
  sites swallow errors. The server refuses it on save.
- A bad date in a `select_rule` hides the row (`0210_computed_validation.sql:1014`).
- Epoch arithmetic is server-only, because `-` on a date string is `NaN` in the
  browser. Rules should use `date_add`.
- Rollup filters accept the date operators as values, compiled to calls of the
  same `jl_date_*` functions (`0440_rollup.sql`). Their arguments are limited to
  date, date-time, integer and duration columns, literals and other date
  operators, and `$today` and `$now` stay refused.
- Near midnight the form's `$today` can differ from the user's calendar, because
  it is UTC.
- Jan 31 + 1 month = Feb 28, yet `date_diff` between those is 0 months.

## Tests

| Where | What |
|---|---|
| `semantius` `apps/test/tests/0100_test_jsonlogic.json` | Date-only cases shared with the browser; regenerate the `.sql` with the `testgen_jsonlogic` command |
| `semantius` `0110_test_jsonlogic_ext.sql` | Every unit and part, DST, offsets, durations, nulls, epoch round trip, 90915 to 90918, refused `today` and `infinity`; update `plan(92)`; also under `SET LOCAL timezone` at UTC+14 and UTC-11 |
| `semantius` `0650_test_computed_validation.sql` | Computed `date` column via `date_add`, backfill, null source date, non-UTC session |
| `semantius` `0600_test_select_rule.sql` | `$today` under a non-UTC session |
| `semantius` `0555_test_rollup.sql` | Each date operator compiled and interpreted over the same rows, a real rollup following a child write, UTC literals, and the refusals |
| `semantius` new `09xx` guard | Database `TimeZone=UTC` and `IntervalStyle=iso_8601`; the `SET` clauses on each generated function |
| `sem-schema` `data-validation.test.ts` | Each operator accepted; wrong argument count, unknown unit and bad pattern rejected |
| `sem-schema` `jsonlogic-backend-sync.test.ts` | New assertions comparing the unit, part and token lists with the SQL |
| `apps/web` `computedFields.test.ts` | Shared fixture cases read from the sibling checkout, the three `$` variables, `has_permission`, `is_match`, under two `TZ` values |
| `apps/web` `SchemaForm.test.tsx` | `input_type_rule` with a date operator, `$today`, `has_permission`, `is_match`, `let`, and the `set_record` fallback |

## Verification

1. In `semantius`: `deno task connect`, `deno task dropall --confirm`,
   `deno task migrate --apps _core,nwind,test --verbose`, `deno task test`.
2. `pgdocker/pg-ext-retest.sh`, the only path that runs the `.once` change through
   the extension installer.
3. `deno task extension 0.5.0-beta1 --check`.
4. `jest` in both `sem-schema` copies with `SEMANTIUS_BACKEND_REQUIRED=1`, then
   `diff -r` the two `src` folders.
5. `vitest run` in `apps/web`.

The Cloudflare preview that `semantius-app` and `semantius.com` require before
completion is deferred, because deploying needs a commit.

## Out of scope

- Business days.
- Making existing `<`, `>` and arithmetic honor a non-UTC offset in a literal typed
  into a rule.

## Consequences

- Every API reader of a `duration` field gets ISO 8601 (`P3DT4H`) instead of
  `3 days 04:00:00`.
- A dump restored without `--create` loses the database defaults. `get_userinfo`
  then refuses the session with 90011 and names the two statements to run, which
  `SECURITY.md` records.
