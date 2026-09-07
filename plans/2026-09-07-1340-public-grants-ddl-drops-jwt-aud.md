# Plan: explicit table grants, DDL drops in the audit, and the audience row

Written 2026-09-07 13:40, revised the same day after an independent review
(findings folded in below; the two that needed the owner were put to the owner
and are recorded as decisions). Owns **S17**, **S18** and **S14**, the three
rows whose fix column began with "decide". No other plan is open.

## Open items

**Owns, and therefore closes.**

| Row | Decision (2026-09-07) | Done when |
|---|---|---|
| **S17** | **Narrow.** The request role no longer gets automatic data access on future tables in `public`. The dictionary grants at creation and at adoption, the core migrations grant what they create, and a table made by hand is invisible to the API until the operator grants it. **Adoption always secures the table**: flipping a pre-existing hand-made table to `managed = true` enables RLS, creates the four policies and grants, the same as a table the dictionary created. | A hand-made table in `public` is not readable by user1; a dictionary table still is; an adopted table has RLS, four policies and the grants; no `pg_default_acl` row grants `semantius_user` anything on tables or sequences in `public`. |
| **S18** | **Audit every command, add drops, accept the other two.** The tag allowlist goes; a second event trigger on `sql_drop` records drops, which `ddl_command_end` never reports. **The drop trigger returns early when `public.audit_ddl_logs` no longer exists**, so a teardown that drops tables in any order keeps working. GRANT/REVOKE rows stay identity-less and CREATE SCHEMA stays always-logged, both written into the comment above the function. | `DROP TABLE` in `public` produces one audit row; a command type nobody listed produces a row; a drop in a foreign schema produces none; the label-function rebuild still produces none; `DROP EXTENSION` produces none; `deno task dropall` still empties the database. |
| **S14** | **Keep optional, report, link.** `uid()` keeps accepting tokens without an audience check when `_settings` has no `jwt_aud` row. `semantius.status()` reports whether the row is set, and the consumer README links the trust model. Neon's own provider settings treat the audience as optional, so this matches the platform. | `status()` has a `jwt_aud_set` column that is false on a fresh install and true once the row exists; the README names the row and points at `SECURITY.md`. |

**Touches without owning.**

| Row | Effect here | Owner |
|---|---|---|
| **Q6** | Adds one trigger function, `audit.log_drop_event`. Event-trigger functions have no bound table, so it joins the set the lint invocation must handle; nothing else changes. | unowned |
| **R7** | Step 11 of the lifecycle script gains two assertions (a committed `DROP TABLE` is audited in `public`, not in a foreign schema); nothing it owns moves. | unowned |

**Found while reading, fixed here because it is in the same function.**
`semantius.status()` reads `_settings.key` to fill `db_version`
(`packages/cli/commands/extension.ts:1416`), but the column is `name`
(`0010_create_core.sql:108`). The `EXCEPTION WHEN OTHERS` around it swallows the
error, so `db_version` has always been NULL. Step 3 fixes the column name while
adding the audience column; a one-line pin goes into the same test.

---

## What each change is, in one paragraph

**S17.** `0050_rbac_rls.sql:264-268` says: every table and sequence created in
`public` from now on is readable and writable by `semantius_user`. That is what
makes a table created in the Neon console instantly reachable through the Data
API by every logged-in user, with no policies. The dictionary does not need the
default: it runs `CREATE TABLE` itself and can grant what it created. So the
default goes, and every site that creates a table the request role must reach
grants explicitly. There are three such sites that grant nothing today (listed
under Step 1b) and four that already do; everything created before `0050` is
covered by the one-time `GRANT ... ON ALL TABLES` at `0050:258`, which stays.

**S18.** The audit's event trigger fires only for tags in a hand-written list,
and `pg_event_trigger_ddl_commands()` never returns drop commands at all, so
`DROP TABLE` is not audited today and neither is any tag nobody enumerated.
Verified live on 2026-09-07 in `postgres18-cli`: a `DROP TABLE s.t` produced no
`ddl_command_end` row and nine `sql_drop` rows, one of them `original = true`.
The fix is two-sided: drop the allowlist (the schema filter is the scope, the
list was never the scope), and add an `sql_drop` trigger that records
`original` objects in the five schemas.

**S14.** `rbac.uid()` checks the JWT audience only when `_settings` holds a
`jwt_aud` row (`0030:187-193`). Nothing seeds the row, nothing reports its
absence, and the consumer README does not mention it. The decision is not to
enforce; the change is to make the absence visible in `status()` and to say in
the README what the row does.

---

## Step 1 — S17: explicit grants instead of the default

### 1a. Remove the default, keep the one-time grant

`0050_rbac_rls.sql:264-268`: delete both `ALTER DEFAULT PRIVILEGES` statements.
Keep `0050:258` and `:261` (`GRANT ... ON ALL TABLES` / `ON ALL SEQUENCES`):
they cover the tables that exist at that point in the migration order, every
one of them ours and every one of them with RLS (test `0060` 2.1). Rewrite the
comment at `0050:263` to say why there is no default: a table the dictionary
did not create has no policies, and a grant without policies is an open table
through the Data API.

`0290_owner_hardening.sql:189-192`: delete the two statements that reproduce the
table and sequence defaults for `semantius_owner`. The four `REVOKE EXECUTE`
defaults and the `rbac` `GRANT EXECUTE` default at `:193-202` stay; the
`pg_monitor` ones at `:203-206` stay.

### 1b. Grant at the creation sites

Determine the exact list by running, after a full migrate on a scratch
database with the default removed:

```sql
SELECT c.relname, c.relkind
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = 'public' AND c.relkind IN ('r', 'S')
   AND NOT has_table_privilege('semantius_user', c.oid, 'SELECT')
 ORDER BY 1;
```

Expected from reading the migrations; the query is the authority:

1. `0060_dd_schema.sql:13` `entities` and `:113` `fields`, created after `0050`
   and granted nothing. Add `GRANT SELECT, INSERT, UPDATE, DELETE ON entities,
   fields TO semantius_user` next to their RLS enable. Neither has a sequence:
   `entities` is keyed by `table_name TEXT` (`:14`) and `fields.id` is a
   generated text column (`:114`), so there is no sequence grant here.
2. `0070_dd_functions.sql:401`, `create_dd_table`, right after `ENABLE ROW LEVEL
   SECURITY`: grant the four table privileges and `USAGE, SELECT` on
   `pg_get_serial_sequence(NEW.table_name, NEW.id_column)`.
3. `0145_managed_enable.sql`, the adoption trigger. Today RLS and the four
   policies are created only inside the `IF NOT EXISTS` branch at `:212-276`
   (enable at `:247`), so a table the operator created by hand and then flipped
   to `managed = true` is adopted **without** RLS. **Decision 2026-09-07:
   adoption always secures the table.** Move the RLS enable, the four policies
   and the new grant out of the branch so both paths get them, each policy
   guarded by a `pg_policies` existence check (there is no `CREATE POLICY IF
   NOT EXISTS`); hand-written policies already on the table are left in place.
   The comment above the trigger says why: a grant is what exposes a table
   through the Data API, so it is never issued without policies. Note
   `0040_test_managed_flag.sql:139-148` flips only an entity with no physical
   table; the hand-made path has no test today and gets one in 1e.
4. Already explicit, unchanged: `0110_apikeys.sql:36-37`,
   `0130_create_tables_view_compat.sql:30`, `0150_audit_log.sql:834-837`,
   `0210_raci.sql:403-404` (the `user_process_raci` view).
5. `0150_audit_log.sql:839-844`: the two `REVOKE INSERT, UPDATE` statements
   exist to take back what the default handed the request role, and their
   comment says so. After 1a there is nothing to take back. Delete the two
   revokes and the comment, or keep the revokes and rewrite the comment as a
   belt-and-braces statement; either way `0060_test_security.sql:160-170`
   (which pins the missing privileges) and `0300:525-540` (a plain user
   cannot forge an audit row) stay green and must be run.
6. `_versions` exists before `0050` on both paths and has RLS with no policies
   (`packages/core/src/migrate.ts:43`); the one-time grant reaches it and is
   inert. Leave it alone unless the query above lists it.

Modules (`apps/*/migrations` other than `_core`) create no tables directly;
everything goes through `entities` inserts. Verified with a grep on
2026-09-07, and again by the review.

Stale comments to rewrite in the same change, because they describe the
default: `0430_test_owner_hardening.sql:62-63` ("the request role keeps its
privileges on them (default privileges)"; the assertion at `:89-93` stays green
through 1b.2, the sentence does not).

### 1c. The uninstall recipe and `status()`

The README template in `packages/cli/commands/extension.ts:830-833` and
`pgdocker/pg-ext-lifecycle.sh:360-363` both revoke the table and sequence
defaults. Delete those four lines from both. The `FUNCTIONS` revoke line stays.
The `pg_default_acl` assertion at `pg-ext-lifecycle.sh:373-374` is unchanged:
the recipe already revoked those rows, so the expected value was already
"only the cosmetic FUNCTIONS row".

`semantius.status().default_acls_ok` (`extension.ts:1451-1454`) tests for any
`pg_default_acl` row whose grantor is `current_user`. The rows that keep it
true after 1a are the installing role's own: the `FUNCTIONS` revokes at
`0010:67` and `:73`, the `rbac` entries at `0030:16-20` and the `audit` one at
`0150:26`. The `0290` entries are `FOR ROLE semantius_owner` and never counted.
So the column keeps its meaning; step 3's test asserts it stays true.

### 1d. Documents

- `SECURITY.md:105-109`: replace the bullet. New text says the request role
  has no access to a table the dictionary did not create or adopt; an
  unmanaged entity's table needs an explicit `GRANT` to `semantius_user`, and
  needs its own policies before that grant, because the grant is what exposes
  it. Adoption (`managed = true`) does both.
- `SECURITY.md:50-58`: the "restore by a differently named superuser" bullet
  lists "data access on future tables in `public`" as one of two things lost.
  Remove it; only the `rbac` EXECUTE default remains.
- README template `extension.ts:848` "Roles" table, the `semantius_user` row:
  add "no default access to tables; the dictionary grants per table".
- `AGENTS.md` mentions no default privilege; nothing to do.

### 1e. Tests

New `apps/test/tests/0460_test_public_grants.sql`:

1. No `pg_default_acl` row in `public` for object types `r` or `S` names
   `semantius_user` in its ACL, for any grantor role.
2. `CREATE TABLE public.hand_made (id int)` as the installer, then
   `has_table_privilege('semantius_user', 'public.hand_made', 'SELECT')` is
   false, and a `SELECT` as user1 raises 42501.
3. An entity inserted through the dictionary yields a table on which all four
   privileges hold and `has_sequence_privilege(... 'USAGE')` holds on its id
   sequence; an insert as user2 with the edit permission succeeds.
4. Adoption: a table created by hand, then an `entities` row with
   `managed = false` flipped to `true`, ends with RLS enabled, four policies,
   and the four privileges; a hand-written policy present before the flip is
   still there after it.
5. `0060` 2.1 stays green unchanged (all public tables still have RLS).

The existing tests create only temp tables as the request role, apart from
`0030:25` (a `throws_ok` as user1), `0301:45` and `0440:238` (as superuser,
never read as `semantius_user`), so none of them depends on the default.

---

## Step 2 — S18: every command, plus drops

### 2a. `0150_audit_log.sql`: the allowlist goes

Replace `CREATE EVENT TRIGGER track_ddl_changes ON ddl_command_end WHEN TAG IN
(...)` (`:607-628`) with the same trigger and no `WHEN` clause. `log_ddl_event`
itself is unchanged: the schema filter at `:583-585`, the `in_extension` skip
and the label-churn filter are the scope.

The `WHEN TAG` list in `pgrst_ddl_watch` (`0090_notify_triggers.sql:113`) is
not touched. That trigger drives PostgREST's schema reload, not evidence, and
a narrower list there is correct.

### 2b. A second trigger for drops

New function `audit.log_drop_event()` returning `event_trigger`, `SECURITY
DEFINER`, `SET search_path = ''`, for the same reason `log_ddl_event` is a
definer (a request-role `CREATE TEMP TABLE` must not fail on the audit insert).

First statement: `IF to_regclass('public.audit_ddl_logs') IS NULL THEN RETURN;
END IF;`. **Decision 2026-09-07.** `deno task dropall`
(`packages/cli/commands/dropall.ts:447-470`) drops the public tables in
alphabetical order with a per-table `catch` that only logs; `audit_ddl_logs`
is fourth, and without the guard every drop after it fails on the insert and
the database is left half torn down. The guard means drops issued after the
log table is gone are unaudited, which is the case where the audit itself is
being destroyed. The comment says exactly this.

Then loop over `pg_event_trigger_dropped_objects()` and insert a row when:

- `original` is true. A `DROP TABLE` reports the table plus its sequence, its
  rowtype, its array type, its default, two constraints and two indexes; only
  the table is `original`. Recording all nine would be the churn the scoped
  audit removed.
- the schema is one of the five, **or `schema_name IS NULL AND object_type =
  'schema'`**. `DROP SCHEMA` reports the schema itself with a NULL
  `schema_name`, the mirror of `CREATE SCHEMA`, and is logged for the same
  reason. The NULL rule must not be wider than that: `DROP EXTENSION
  pg_semantius` reports the extension as an `original` object with a NULL
  schema, and `pg-ext-lifecycle.sh:76-88` fingerprints every core table's row
  count (`audit_ddl_logs` included) across `DROP EXTENSION` and asserts at
  `:345` that the drop is inert. One audit row there fails step 4. The same
  shape is explained at `0090_notify_triggers.sql:158-163` for the pgrst
  watch.
- `is_temporary` is false. `pg_event_trigger_dropped_objects()` has that
  column, so the `pg_temp` prefix test the sibling needs is not needed here;
  `pgrst_drop_watch` at `0090:157` uses the same column.
- for `object_type = 'function'`, `object_identity` does not match the
  `_label(` pattern from `log_ddl_event:590`. `rebuild_entity_label_functions`
  (`0145:797`) issues `DROP FUNCTION IF EXISTS` on every label companion on
  every field edit; without this filter every field edit writes a `DROP
  FUNCTION` row and the churn the scoped audit removed comes straight back
  through the new door. `0448_test_statement_triggers.sql:405-412` bounds the
  DDL rows per plain field insert at 2 and will catch it if the filter is
  missing.

`command_tag` is `tg_tag`; `object_type`, `object_identity` come from the
dropped-objects row; `query_text` is `left(current_query(), 8192)` as in the
sibling.

```sql
CREATE EVENT TRIGGER track_ddl_drops ON sql_drop
    EXECUTE FUNCTION audit.log_drop_event();
```

The `DROP OWNED BY semantius_owner CASCADE` in the uninstall recipe would
produce thousands of rows, which is why the recipe drops the event triggers
first; the recipe (`extension.ts:818` section) and lifecycle 4b
(`pg-ext-lifecycle.sh:354`) must list `track_ddl_drops` in that `DROP EVENT
TRIGGER` statement.

### 2c. The comment above `log_ddl_event`

Rewrite `0150:542-571` so that the reader has the three accepted limitations
without a tracking id:

- GRANT and REVOKE arrive with no `classid`, `objid`, `schema_name` or
  `object_identity`, so they can be neither scoped nor recognized as label
  churn; they are kept because they are the privilege history the table
  exists for, and on the extension path their `query_text` is only `SELECT
  semantius.migrate()`. Recovering the target from the DDL text was
  considered and declined: it is a parser for an open-ended grammar, on an
  evidence table.
- There is no command-type filter on `track_ddl_changes`. A command type is
  audited if it touches one of the five schemas, whatever it is called. Drops
  are reported by a different PostgreSQL mechanism and have their own trigger.
- `CREATE SCHEMA` and `DROP SCHEMA` report no schema and are always logged,
  foreign ones included. `DROP EXTENSION` also reports no schema and is
  deliberately not logged (see 2b).

### 2d. Tests

`0301_test_audit_ddl_scope.sql` test 6 (`:116-130`, two assertions) becomes one:
`evttags IS NULL` for `track_ddl_changes`, "fires for every command type".
Then add:

- `CREATE STATISTICS` on a public table produces a row (a type the old list
  did not name).
- `DROP TABLE` of a public table produces exactly one `DROP TABLE` row, with
  `object_type = 'table'` and the table's identity, and no rows for its
  sequence or indexes.
- `DROP TABLE` in the foreign schema from test 1 produces nothing.
- Editing a field on an entity with label companions produces no `DROP
  FUNCTION` row.
- `audit.log_drop_event` is `SECURITY DEFINER` (mirror of test 5).

`plan(12)` becomes `plan(16)`. Also read: `0440_test_extension_membership.sql:
257-299` compares `pg_event_trigger` counts before and after `DROP EXTENSION`
and stays green because the new trigger is on both sides; `0300:334-344`
asserts `> 0`, not exact counts; no test pins an exact `audit_ddl_logs` total.

Lifecycle: `pg-ext-lifecycle.sh:87` prints the event-trigger count inside the
signature (both sides of every comparison change alike); the uninstall check
at `:367` expects 0 and needs the new trigger in the recipe at `:354`. Step 11
gains two committed assertions: a `DROP TABLE` in `public` leaves one audit
row, and a `DROP TABLE` in a foreign schema leaves none. The DDL ledger
comparison in step 10 (CLI versus extension install) may change its row count;
both sides change alike.

`deno task dropall` against a migrated database, then `deno task migrate`, is
part of the verification: it is the path the guard exists for and no harness
runs it.

---

## Step 3 — S14: report the audience row, link the policy

### 3a. `semantius.status()`

In `packages/cli/commands/extension.ts:1386-1460`:

- Add a column `jwt_aud_set boolean` after `default_acls_ok`. Value:
  `to_regclass('public._settings') IS NOT NULL AND EXISTS (SELECT 1 FROM
  public._settings s WHERE s.name = 'jwt_aud' AND s.value <> '')`, inside the
  same `BEGIN ... EXCEPTION` shape the `db_version` read uses, defaulting to
  false.
- Fix the `db_version` read at `:1416`: `s.key` to `s.name`.
- Extend the function comment: "…and whether the JWT audience is pinned".
- README template, `## Runtime configuration` at `extension.ts:873`: add a
  short paragraph after the settings table. `_settings` row `jwt_aud` pins the
  audience `rbac.uid()` accepts; without it any token from the trusted issuer
  is accepted, which is also Neon's default when the provider's audience is
  left blank; `status().jwt_aud_set` reports it; the trust model is in
  `SECURITY.md` under "Session mode trusts the application tier".

### 3b. `SECURITY.md:72-78`

Extend the session-mode bullet by one sentence: the row is optional; without
it the audience is not checked and `semantius.status()` reports
`jwt_aud_set = false`.

### 3c. Test

`status()` exists only on the extension path, and is `REVOKE ... FROM PUBLIC`
(`extension.ts:1457`), so it can be called only as the installer. Two
consequences for `0250_test_jwt_aud.sql`:

- The guard must be the `pg_temp` wrapper pattern of
  `0440_test_extension_membership.sql:34-46`, not the `CASE WHEN` of `0430`: a
  literal `semantius.status()` is resolved at parse time and makes the whole
  file fail on the migrate path, where the schema does not exist. Write
  `pg_temp.ext_status_jwt_aud_set()` and `pg_temp.ext_status_db_version()`
  that return NULL when the `semantius` schema is absent and otherwise
  `EXECUTE` the call.
- The calls must run as the installer: after the `RESET ROLE` at `0250:23`
  and before the `SET ROLE semantius_user` at `:27`, not after
  `authenticate_as('user1')` at `:10`. So: `RESET ROLE`; assert
  `jwt_aud_set` is false; `INSERT` the row; assert true; assert
  `default_acls_ok` is true (the 1c claim); with a `db_version` row present,
  assert `db_version` returns it; then `SET ROLE` and continue. On the migrate
  path each assertion `pass()`es with a skip message. Update the plan count.

---

## Order, verification, closure

1. Step 1 first, on the migrate path: `pgdocker/pg-cli-retest.sh`, then read
   the 1b query output on the scratch database and adjust the grant list.
2. Step 2, same harness, then `deno task dropall` followed by `deno task
   migrate` against the CLI container.
3. Step 3 needs the generated extension: `deno task extension 0.5.0-beta1`,
   then `pgdocker/pg-ext-retest.sh` and `pgdocker/pg-ext-lifecycle.sh` for the
   uninstall recipe, step 4's inert-drop signature, step 11 and the
   event-trigger counts.
4. `deno task bundle-sql` regenerates the three `migrations-bundle.ts` copies
   (untracked build output, but the packages read them).
5. `pgdocker/pg-cli-retest.sh --coverage` once at the end so the new trigger
   function shows in the coverage report.
6. One closure record per row in `plans/ext-solved-items.md`, in the shape of
   the existing sections: the row as it stood, what changed, what pins it,
   what it does not solve. S17's record carries the adoption decision. S18's
   record carries the live probe result, the `DROP EXTENSION` case and the
   dropall guard. S14's carries the `db_version` fix.
7. Delete the three rows, add S14, S17 and S18 to the gaps list in the
   open-items header, delete this plan.

No commits without asking.
