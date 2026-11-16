# semantius-app: two open points after the backend change

The backend (`c:\dev\semantius`, pg_semantius 0.5.0) changed how JsonLogic
arithmetic reads its operands and which table names an entity may have. Two
things in this repository follow from that. Neither is decided; ask the
maintainer before changing behavior.

Four files are modified in the working tree and **not committed**: the
maintainer reviews and commits them. Do not commit, push or open a pull
request.

- `apps/web/src/lib/computedFields.ts`
- `apps/web/src/lib/computedFields.test.ts`
- `packages/sem-schema/src/jsonlogic/operators.ts` (comments only)
- `packages/sem-schema/src/jsonlogic/validate.ts` (comment only)

## 1. Arithmetic in computed fields still differs from the server in two cases

The server reads an operand of `+`, `-`, `*`, `/`, `%`, `max` and `min` like
this (`jl_operand` and `jl_try_number` in
`c:\dev\semantius\apps\_core\migrations\0050_jsonlogic.sql`):

- null, a missing argument and blank text count as 0;
- text that `Number()` reads is that number;
- other text raises `90920: <operator> has no finite result`;
- an array or an object counts as 0;
- ISO 8601 date or date-time text is its epoch seconds in UTC.

`operand()` in `computedFields.ts` now does the first three. It differs from
the server in the last two:

| Rule | Server | Browser |
|---|---|---|
| `{"+":["2026-01-01",1]}` | epoch seconds + 1 | raises 90920 |
| `{"-":["2026-01-02","2026-01-01"]}` | 86400 | raises 90920 |
| `{"+":[[1,2],3]}` | 3 | raises 90920 |
| `{"+":[[5],1]}` | 1 | 6 |
| `{"+":[{"var":"o"},1]}`, `o` an object | 1 | raises 90920 |

Arrays and objects: one more condition in `operand()` (count
`typeof value === 'object'` as 0) makes the browser match. Dates: matching the
server means reading ISO text as epoch seconds, as `jl_try_number` does; the
corpus case `{">=":["2024-01-01",0]}` (server `true`, browser `false`) is the
same gap in ordering. Which side should move is the maintainer's decision.

## 2. `pnpm check` is red on tests that call the live test tenant

The failures are not in the four changed files; `computedFields.test.ts`
passes. They changed between two runs a few minutes apart, so the tenant was
probably being upgraded to the new backend at the time.

- `src/hooks/formatRoundTrip.test.ts` (whole suite) and
  `src/hooks/useTableMutations.test.tsx:260`: a `POST /entities` fails. Both
  create a table whose name starts with `PREFIX = '_vitest_'`
  (`src/test/moduleFixture.ts:18`). The new backend refuses a table name
  starting with `_` with `90271` (it marks an internal table). Likely cause,
  **not confirmed**: capture the response body of the failing POST first.
- `src/components/form/__tests__/SchemaForm.test.tsx:1204`: `Table
  "applications" not found in entities`. The tenant has no `applications`
  entity. Tenant state, not code.
- `src/i18n/tenantTranslations.test.tsx:124` failed once with `42883 function
  public.build_schema_for_table(text) does not exist` and passed on a rerun.
  Most likely the upgrade in progress.

If 90271 is the cause, only the table names need another prefix: `PREFIX` also
marks labels and the stale-row sweep, so changing it everywhere changes more
than the failure needs. A fixture table name also has to respect the other new
limits: at most 41 bytes (`90273`), and table name plus field name plus 10
bytes at most 63 (`90276`). Error codes are listed in
`c:\dev\semantius\docs\error-contract.md`.
