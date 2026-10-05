# Plan: new `modules.access_scope` values

## Context

`modules.access_scope` is stored and checked but read by nothing. Its values
change from `basic` / `full` to the five values below, and postgrest-mcp is
updated to match. The change edits 0.5.0-beta1 in place: no new migration files.
A database that already installed beta1 keeps the old values until reinstalled.

## Values (in this order; default `custom`)

| Value | Label |
|---|---|
| `custom` | Custom permission structure |
| `basic` | Two permissions: view and edit |
| `advanced` | Three permissions: view, edit and admin. |
| `gated` | Three permissions: view, edit and admin and process gates |
| `raci` | Three permissions: view, edit and admin and enforced process gates. |

Field description (describes the field, not the options): "Permission structure of the module"

## semantius

1. `apps/_core/migrations/0060_rbac_schema.once.sql:28-29, 37`: the comment becomes
   "Permission structure of the module.", the column gets `DEFAULT 'custom'`, and
   `valid_access_scope` gets the five values.
2. `apps/_core/migrations/0150_dd_bootstrap.once.sql:253`: the new description, the
   five `{value, label}` pairs above, and `default_value 'custom'`.
3. `apps/test/tests/0700_test_get_schema.sql:680-682`: the test expects `custom`
   instead of `basic`, and its message says "defaults to custom". The plan count is
   unchanged.
4. `docs/error-contract.md:587`: "`access_scope` is `custom`, `basic`, `advanced`,
   `gated` or `raci`".
5. `extension/CHANGES.md`:
   - The existing bullet at lines 70-71, which says `access_scope` (`basic`, now
     required), says `custom` instead.
   - A new bullet in the 0.5.0 section: `modules.access_scope` takes `custom`,
     `basic`, `advanced`, `gated` or `raci` instead of `basic` or `full`, and the
     default is `custom`. This is not an upgrade path for an existing 0.5.0-beta1
     install, which has to be reinstalled to get them.
6. The four example type files in `bearer-auth-experimental/examples/`
   (`drizzle/src/schema/admin.ts`, `nextjs/lib/db/schema/admin.ts`,
   `spa-hono-backend/lib/db/schema/admin.ts` and `kysely/src/types.ts`): only the
   `access_scope` line changes, to the five values plus `.default("custom")` in the
   three drizzle files.
7. Regenerate the extension build with `deno task extension 0.5.0-beta1` and
   `schema.md` with `deno task docgen`.

## postgrest-mcp

1. `src/tools/schemas/moduleSchema.ts:89-94`:
   `z.enum(['custom', 'basic', 'advanced', 'gated', 'raci'])` with
   `.describe('Permission structure of the module. Omitted, it is custom.')`.
2. `src/SKILL.md:107` becomes the line below. Nothing else in the skill changes.
   > Optional: `access_scope` — permission structure of the module: `"custom"` (default), `"basic"`, `"advanced"`, `"gated"` or `"raci"`. Leave unset for ordinary modules.

   "Leave unset for ordinary modules" is existing text and stays.
3. Run `npm run generate` to rebuild the committed `src/generated/instructions.ts`.

## Verification

- **semantius:** `deno task connect`, `deno task dropall --confirm`,
  `deno task migrate --apps _core,nwind,test --verbose`, `deno task test`, then
  `deno task extension 0.5.0-beta1 --check`.
- **postgrest-mcp:** `npm test` and `npm run check-schema`, which compares against
  the regenerated `schema.md`.

## Not included

- `./release.sh`
- commits
