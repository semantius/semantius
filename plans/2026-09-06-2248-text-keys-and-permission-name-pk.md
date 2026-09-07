# TEXT everywhere, then the permission name becomes the key

Written 2026-09-06 22:48, revised 23:20 after an adversarial subagent review that checked
every cited line and probed the foreign-key semantics live on PostgreSQL 18.6. Owns one row:
**S16**, restated below. Two parts, in order.

## The request this plan serves

Verbatim, 2026-09-06: "first normalize all varchar to text, then refactor permission pk.
generate a plan for that and let a subagent review the plan."

Decisions taken in the same conversation that this plan builds on:

- Deployment is one database per tenant (`docs/authz-spec.md` P1). A permission's serial id
  is minted per database and means nothing outside it; the name is what module packages
  seed, what every RLS policy embeds, what `has_permission` takes and what an OAuth scope
  carries. The owner: "I tend to drop the additional id for permissions and just use the name
  as pk".
- Nothing is released. Fixes go into the original migrations and there is no upgrade path,
  so a primary key change on the RBAC core is an edit today and a migration project after
  the first release.
- The general "int, text or uuid key per entity" feature discussed alongside is **not** in
  this plan. Only the piece this refactor cannot do without is: the dictionary must type a
  reference after the key it references, in the DDL it emits, in the JSON schema it serves
  and in the documentation it generates.

## Part 1: VARCHAR to TEXT

**Why.** `AGENTS.md:343` already says "ALWAYS use TEXT for string columns instead of VARCHAR".
The remaining VARCHARs are the five generated key columns, and their type leaks into the
documentation as a special case that needs explaining.

**Every site.** Found with `grep -rni "varchar\|character varying" apps/*/migrations` and
confirmed by the review over tests, `packages/**/*.ts`, `scripts`, `docs` and `*.md`:

| File | Column |
|---|---|
| `0020_rbac_schema.sql:184` | `user_roles.id VARCHAR GENERATED ALWAYS AS (...) STORED PRIMARY KEY` |
| `0020_rbac_schema.sql:196` | `role_permissions.id`, same shape |
| `0020_rbac_schema.sql:208` | `user_permissions.id`, same shape |
| `0020_rbac_schema.sql:225` | `permission_hierarchy.id`, same shape |
| `0060_dd_schema.sql:103` | `fields.id VARCHAR GENERATED ALWAYS AS (table_name \|\| '.' \|\| field_name) STORED PRIMARY KEY` |

Excluded on purpose: `0160_pgmq.sql` (three VARCHARs, vendored, kept byte-identical to
upstream by the 2026-09-05 decision) and `apps/test/migrations/0010_pgtap.sql` (vendored
pgTAP). No test asserts `character varying`; no TypeScript outside the generated bundles
mentions it; `docs/` does not either. The only `*.md` hits are `AGENTS.md` and this plan.

**Change.** `VARCHAR` becomes `TEXT` in the five definitions. Nothing else moves: the
dictionary already describes all five as format `text`, PostgREST and the UI see strings
either way, and the generated column expressions are unchanged.

**Documentation.** `AGENTS.md:286-302`, the "Primary Key Conventions and EXCEPTIONS" block,
is rewritten while it is open, because it is wrong in three places today, not only about
VARCHAR: EXCEPTION 1 names the `tables` table, which has been `entities` since 0140;
EXCEPTION 2 says the `fields` key is VARCHAR; EXCEPTION 3 says the junction tables have
composite keys and "do NOT have an `id` column", while all four have a generated `id` key
plus a UNIQUE on the pair. Write what the code does.

**Proof.** Both harnesses green, and a catalog assertion, not the documentation: a pgTAP
`col_type_is(... 'text')` for the five columns, or one `pg_attribute` query showing no
`character varying` in the five Semantius schemas outside `pgmq`. The review found that
`schema.md` is generated from `fields.format`, never from catalog types, and already shows
`text` for these keys, so regenerating it proves nothing about Part 1.

Part 1 lands, is regenerated and is green before Part 2 starts. It is independent of Part 2
and stays even if Part 2 is stopped.

## Part 2: `permission_name` is the primary key

### The row this plan owns, restated

S16 as it stands says permission names in five text columns are validated on save only, have
no foreign key, and a deleted permission leaves a dangling name that fails closed for
everyone. Its interim fix was a before-delete trigger; its later fix "convert to references".
This plan does the later fix directly and makes the interim one unnecessary: once the name is
the key, the five columns are ordinary foreign keys.

Restated S16, to be written into the open items when this plan starts: *Problem*: five text
columns name permissions without a foreign key (`entities.view_permission`,
`entities.edit_permission`, `modules.view_permission`, `queues.view_permission`,
`queues.manage_permission`); a deleted or renamed permission leaves a name that
`has_permission` fails closed on for everyone, admins included. *Fix*: this plan. *Done
when*: all five are foreign keys to `permissions(permission_name)`, a delete of a referenced
permission is refused, a rename propagates and the affected RLS policies are regenerated,
each pinned by a test.

### The table

```sql
CREATE TABLE permissions (
    permission_name TEXT PRIMARY KEY,
    description TEXT DEFAULT '',
    module_id INTEGER NOT NULL REFERENCES modules(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT permission_name_shape CHECK (permission_name ~ '^[a-z0-9_]+(:[a-z0-9_]+)*$')
);
```

The `id SERIAL` column and the `DEFAULT ''` on the name go, and so does
`SELECT setval('permissions_id_seq', ...)` at `0040_rbac_seed.sql:67`, which would otherwise
fail on a sequence that no longer exists (the `roles_id_seq` line beside it stays).

**The CHECK is strict on purpose, decided here rather than at execution time.** Two things
depend on the alphabet. Scopes are split on commas and whitespace (`0405` group 6), so a name
containing either could never be granted through a scope. And the hierarchy table's generated
key is `including || '.' || included`: the review showed live that with dots allowed,
`('a.b','c')` and `('a','b.c')` both generate `a.b.c` and the second legitimate pair fails
with a spurious primary-key violation. Forbidding dots removes the ambiguity. Every shipped
name (`admin`, `user:read`, `user:manage`, `public:read`, `nwind:view`, `nwind:manage`)
matches; module slugs are `[a-z0-9_]+`, so `<slug>:<verb>` names match. The comment at
`0020:222` uses `customer.manage` as an example and is corrected to a colon. Before executing,
check any provisioning path outside this repository that generates permission names.

### Every column that holds a permission id today, and what it becomes

Following the precedent already in the schema, a foreign key column is named after the key it
references: `fields.table_name` references `entities(table_name)`. So `permission_id` becomes
`permission_name`. Keeping the old names while they hold text was considered and rejected: the
dictionary rows, the tests and the generated documentation have to change anyway, and
`permission_id = 'nwind:manage'` misleads every future reader.

| Today | Becomes | Notes |
|---|---|---|
| `role_permissions.permission_id INTEGER` (`0020:197`) | `permission_name TEXT NOT NULL REFERENCES permissions(permission_name) ON DELETE CASCADE ON UPDATE CASCADE` | generated `id` and UNIQUE follow the rename |
| `user_permissions.permission_id` (`0020:209`) | same | |
| `permission_hierarchy.including_permission_id`, `included_permission_id` (`0020:226-227`) | `including_permission_name`, `included_permission_name`, same FK shape | `no_self_reference` CHECK, `origin` CHECK and UNIQUE follow |
| `modules.manage_permission_id`, `admin_permission_id` (`0020:244-245`) | `manage_permission`, `admin_permission` `TEXT REFERENCES permissions(permission_name) ON DELETE SET NULL ON UPDATE CASCADE` | nullable, as today |
| `dashboards.view_permission` (`0260:46`, dictionary-created; there is no `edit_permission` field) | unchanged declaration; comes out TEXT once the prerequisite lands | delete mode `clear` stays; nwind `0020_load_data.sql:3414` stores it by name lookup today and stores the literal after |

Indexes on those columns (`0020:291, 298, 320, 326, 327`) follow the renames. The
constraint-generated index names change to, on PostgreSQL 18.6:
`role_permissions_role_id_permission_name_key`, `user_permissions_user_id_permission_name_key`,
`permission_hierarchy_including_permission_name_included_per_key`, and the new
`modules_view_permission_fkey` and `modules_manage_permission_fkey`.
`0450_test_rbac_indexes.sql:102-110, 157` pin the old names, and `:132` hard-codes
`permission_id = 1` inside the EXPLAIN it runs.

### The five name columns become foreign keys

```sql
-- entities (hand-written DDL in 0060):
... REFERENCES permissions(permission_name) ON DELETE RESTRICT ON UPDATE CASCADE
-- modules.view_permission (0020, added after permissions exists):
... REFERENCES permissions(permission_name) ON DELETE NO ACTION ON UPDATE CASCADE
    DEFERRABLE INITIALLY DEFERRED
-- queues: dictionary-created, see below
```

**What the review corrected about RESTRICT and NO ACTION.** The first draft claimed RESTRICT
is checked the instant a permission row goes and NO ACTION at end of statement, so that a
module delete cascading to both its permissions and its entities would fail under RESTRICT
depending on cascade order. Probed live, it does not: a module delete whose entities name the
module's own permission **succeeds under both**, in both FK-creation orders. Referential
actions run with trigger firing suppressed and queue their checks into the outer statement's
event queue, after the remaining cascades. The two real differences are that NO ACTION
honours `DEFERRABLE` and RESTRICT never defers, and that NO ACTION re-checks for a substitute
key row on UPDATE. Consequences: NO ACTION is *required* only where the constraint is
deferred, that is `modules.view_permission`; everywhere else RESTRICT is fine and is what the
dictionary emits, so the dictionary's constraints can be accepted as they are. The module
delete scenario stays as a pinned test because it is the behaviour S16 needs, not because
the mode decides it.

**`DEFERRABLE INITIALLY DEFERRED` on `modules.view_permission`, and only there.** A module's
`view_permission` names a permission whose `module_id` names the module: a cycle. Every seed
inserts the module first (`0040:10-17`, nwind `0010:10-14`), so an immediate check fails on
the module insert. Deferred to commit, both rows exist by then. Verified live: the deferred
cycle installs, `DEFAULT 'user:read'` participates in the check and is seeded, and a rename
still cascades immediately through the deferred constraint. Entities and queues are always
created after their permissions, so their checks stay immediate and fail early.

**The consumer this breaks is the MCP server, not the cloud app.** The plan's first draft
said to grep the cloud app and the UI kit for module creation; the review did, and the
directories reachable from here contain no `permission_id`, no `permissions.id` and no module
creation. What does exist is `C:\dev\postgrest-mcp\src\tools\schemas\moduleSchema.ts:18`,
where `create_module` accepts `view_permission`, while `create_permission` is a separate tool
and every PostgREST request is its own transaction. After this change, `create_module` with a
`view_permission` that does not exist yet fails at that request's commit. The tool contract
has to say: create the module with an existing permission (the default `user:read` works),
then its permissions, then update the module. The same schemas hard-code
`manage_permission_id`/`admin_permission_id` as numbers (`moduleSchema.ts:19, 27`),
`permission_id` as a number (`role_permissionSchema.ts:11`) and
`including_permission_id`/`included_permission_id` as numbers
(`permission_hierarchySchema.ts:10-11`); `permissionSchema.ts:10` already carries
`permission_name`. Those files are outside this repository and are listed here so the
change set is complete; they are not edited by this plan.

**Entities.** The 0060 seed rows precede the 0070 triggers (`0060:64-65`), so no dictionary
DDL ever runs for them; the foreign keys are hand-written in the `CREATE TABLE entities`
DDL, and the two field rows' format change is metadata only.

**Queues are dictionary-created and get the dictionary's constraint.** `0170:18-40` inserts
the `queues` entity and `0170:53-56` inserts the two permission fields as format `text`,
which `add_dd_field` turns into columns. There is no hand-written table to put a constraint
on. With the fields declared as format `reference` to `permissions` (delete mode `restrict`)
and the prerequisite in place, `add_dd_field` creates `TEXT` columns with
`queues_view_permission_fkey ... ON DELETE RESTRICT ON UPDATE CASCADE` itself. Two follow-ups
in 0170, both with precedent: reference columns are nullable in the dictionary model
(`is_nullable`, `0070:97`), so `ALTER TABLE queues ALTER COLUMN ... SET NOT NULL` follows the
field inserts exactly as `0210_raci.sql:154-155` does for `raci_assignments.role_id`; and the
existing defaults (`'admin'`) are kept. The alternative, pre-creating the columns before the
field insert as `0250_webhook_receiver.sql:37-42` does for `table_name`, exists only to work
around the INTEGER typing that the prerequisite removes, so it is not used.

**Dictionary rows.** The five fields plus the two module columns become format `reference`
to `permissions`, `reference_delete_mode` `restrict` for the five and `clear` for the two,
so the UI renders a picker that stores the name (`InputReference.tsx:34-47` keys on the
referenced entity's `id_column`, which becomes `permission_name`; `0080:265, 337` emit it for
`reference` and `parent`). All seven have defaults, so they never enter the schema RPC's
`required` list (`0080:436-444` excludes fields with a default) and nothing the UI requires
changes. `rbac.validate_permission_exists` (`0030:974`) and its two callers, the INSERT-time
check in `create_dd_table` (`0070:292-297`) and `queue_validate_permissions`
(`0170:127-151`), become redundant: the foreign key is the check on INSERT and UPDATE alike,
and it covers the UPDATE path on entities that has no check today. They are removed, together
with the revoke at `0030:1167-1171`; that touches three tests outside the nine listed below:
`0060_test_security.sql:117` (exclusion list) and `:161` (revoke assertion), and
`0405_test_rbac_helpers.sql:341-343` (the 42501 `throws_ok`). If the owner prefers the
triggers' error sentences over a 23503, the three stay and this paragraph is wrong.

### Prerequisite: the dictionary types a reference after its key

Three places assume a reference is an integer, and all three must change together or the
schema RPC breaks while the DDL works.

1. **DDL.** `format_to_data_type` maps `reference` and `parent` to `INTEGER`
   (`0070:24-25`). Its live callers that add a column, `add_dd_field` at `0070:585` and the
   managed toggle's field builder `apply_field_ddl` at `0145:39`, already look up the
   referenced entity's `id_column` a few lines later, after the `ADD COLUMN`. The lookup
   moves before the `ADD COLUMN` and reads the key column's type from the catalog:

   ```sql
   SELECT format_type(a.atttypid, a.atttypmod)
   FROM entities e
   JOIN pg_attribute a ON a.attrelid = to_regclass(format('public.%I', e.table_name))
                      AND a.attname = e.id_column
   WHERE e.table_name = p_field.reference_table;   -- NEW.reference_table in add_dd_field
   ```

   `format_to_data_type` keeps `INTEGER` for the two formats as the fallback when no table
   is at hand. `0070:879` also calls it for a format change, but that definition of
   `update_dd_field` is dead: the function is redefined at `0140:542` and finally at
   `0145:360`, whose live path (`0145:459-466`) compares old and new types and raises when
   they differ. With the resolver, `text` to `reference(permissions)` compares TEXT to TEXT
   and passes; nothing in this plan relies on that, since the seeds insert rows with the new
   format rather than updating them.
2. **JSON schema.** `get_schema` decides a reference field's JSON `type` with a hard-coded
   list, `reference_table IN ('entities', 'fields')` at `0080:279-282`, and casts a default
   `::INTEGER` whenever the type came out `integer` (`0080:361-372`). With `permissions`
   text-keyed and the seven fields declared `reference`, `get_schema('entities')` and
   `get_schema('queues')` would raise `invalid input syntax for type integer` on
   `'public:read'` and `'admin'`, and take `get_schemas`, `get_module_cubes` and
   `get_user_cubes` down with them. The list is replaced by the referenced entity's key
   format: join `entities` to the `fields` row with `is_pk` for `reference_table` and use
   `format_to_json_type` of that format. Default handling follows the same type.
3. **Documentation.** `packages/cli/commands/docgen.ts:61` maps `reference` to `integer`
   and omits `parent`, which is why `schema.md:379-380` show `string` for the hierarchy
   columns today. It takes the same key-format rule, and `schema.md` is regenerated with
   `deno task docgen`.

Without item 1, `dashboards.view_permission` would be an INTEGER column with a foreign key to
a TEXT key and 0260 fails to install. Without item 2, the install succeeds and every schema
RPC fails at runtime.

### Functions in 0030

Four functions carry permission ids (34 lines in the file, 44 occurrences, all in these):

- `rbac.user_has_permission` (15 lines): resolves the name to an id, then walks
  `role_permissions`, `user_permissions` and `permission_hierarchy` by id. The resolution
  step disappears; the recursive CTE walks names. Same for its scope half.
- `rbac.get_user_permissions` (7): joins by id, already returns `permission_name` only, so
  its callers (`0030:423-425`, `0080:91-95`, `0190:141-144`) do not change.
- `rbac.check_permission_hierarchy_cycle` (10): recursive over ids, over names. It also
  raises `Including permission with Id % does not exist` and the `Included` twin
  (`0030:44-49`), and `0395_test_permission_hierarchy_cycle.sql:88, 96` pin those sentences.
  The checks are redundant with the foreign keys and go; the two assertions change to
  expect SQLSTATE 23503. So "no assertion is lost" is true, but two are rewritten.
- `rbac.grant_permission_to_administrator` (3 lines, `1144-1146`): the AFTER INSERT trigger
  on `permissions` inserts `(v_administrator_role_id, NEW.id)`; `NEW.permission_name`.

### Seeds and the sample module

- `0040_rbac_seed.sql`: permissions lose their explicit ids (`:17-21`); the hierarchy row
  `(2, 1)` becomes `('user:manage', 'user:read')`; `role_permissions` rows name permissions
  directly; the module UPDATE at `:58-61` sets `admin_permission = 'admin'`; the `setval`
  at `:67` goes.
- `apps/nwind/migrations/0010_create.sql:14-45` and `0020_load_data.sql:3414`: same shape,
  and the `SELECT id FROM permissions WHERE permission_name = ...` lookups become literals.
- `0060_dd_schema.sql`: the `permissions` entity row (`:391`) gets `id_column =
  'permission_name'`; its `id` field row (`:631`) goes; the `permission_name` row (`:632`)
  becomes the key (`is_pk`, ctype `id`) **and keeps `input_type = 'required'`**: every other
  `id`-ctype row is `readonly` because the database generates it, and copying that would make
  a permission impossible to create from the UI. `id_column = label_column =
  'permission_name'` is allowed; the junction rows already do `'id', 'id'`. The 13 lines
  mentioning `permission_id` are 6 field rows (`:593, 594, 658, 670, 681, 682`), 3
  generated-id descriptions (`:656, 668, 680`) and 4 label UPDATEs (`:663, 675, 686, 687`).

Known limit, pre-existing and now wider: `get_record_by_id(TEXT, INTEGER)` (`0070:1794`,
used by the JsonLogic operator at `0015:347` and by `0210:666`) cannot address a text-keyed
entity. It could not address `entities` or `fields` before either. Record it in the closure;
do not fix it here.

### Tests

Nine files mention `permission_id`, with counts: `0340_test_m3.sql` 23,
`0395_test_permission_hierarchy_cycle.sql` 18, `0450_test_rbac_indexes.sql` 10,
`0280_test_user_permissions.sql` 7, `apps/nwind/tests/0010_test_nwind_module.sql` 7,
`0190_test_auto_grant_admin_permissions.sql` 5, `0333_test_rbac_escalation.sql` 2,
`0415_test_queue_rpc_mutators.sql` 2, `0390_test_unauthenticated_access.sql` 1. Plus the
three validator sites in `0060` and `0405` named above. Each is adjusted to the new columns;
the only assertions that change meaning are the two error-text ones in 0395.

New pins, one file, `apps/test/tests/0455_test_permission_name_key.sql`:

1. Deleting a permission named by an entity, a module or a queue raises 23503 (three
   `throws_ok`).
2. Deleting a module whose entities name that module's own permissions succeeds, and the
   entities, the permissions and the physical tables are gone.
3. Renaming a permission propagates to `entities.view_permission`, and the entity's SELECT
   policy in `pg_policies` contains the new literal and not the old one. The review
   confirmed live that a cascaded UPDATE fires row-level triggers, including `WHEN`-guarded
   ones, and recomputes STORED generated columns, so `manage_select_rule_policy`
   (`0180:524`) and `update_entity_policies_trigger` (`0070:1257`) fire.
4. Inserting a module whose `view_permission` names a permission inserted later in the same
   transaction succeeds. The failure case cannot be shown by committing, because every test
   file rolls back and `RELEASE SAVEPOINT` does not run deferred checks; it is shown with
   `SET CONSTRAINTS modules_view_permission_fkey IMMEDIATE` inside a `throws_ok`, which the
   review verified raises 23503. Note for the reader: no existing test ever exercises this
   constraint, because none commits.
5. A permission name containing a space, a comma or a dot is refused by the CHECK.
6. `dashboards.view_permission` and `queues.view_permission` are TEXT columns with foreign
   keys to `permissions(permission_name)`, and `get_schema('queues')` reports them as
   `type: string` (the prerequisite, all three items).

### Documentation and generated files

- `AGENTS.md:286-302`: `permissions` leaves the "STANDARD" list and joins `entities` as a
  text-keyed table; the junction and hierarchy tables are described with their real columns.
  `AGENTS.md:311-316` says every TEXT column carries `DEFAULT ''`; a text primary key cannot,
  and the rewritten block records that exception. `AGENTS.md:453-460` test conventions
  already say to resolve permissions by name.
- `schema.md`: regenerated with `deno task docgen` after the docgen change.
- `deno task extension 0.5.0-beta1` and `deno task bundle-sql`: regenerated after each part.
- `SECURITY.md` and `docs/`: the 2026-09-06 grep found no sentence naming a permission id.

## Order of work

1. Part 1: five column edits, `AGENTS.md` block, catalog assertion, regenerate, both
   harnesses green.
2. Prerequisite, all three items, with the `dashboards`/`queues` assertion as its test.
3. `0020`, `0040`, `0060`, `0030`: table, links, module columns, dictionary rows, functions,
   the `setval` removal, the comment at `0020:222`.
4. `0060`, `0170`, `0020`: the entity foreign keys, the queue field rows and their
   `SET NOT NULL`, the deferred module constraint; remove the three validators.
5. `0260`, nwind, the nine plus three tests, the new test file.
6. `AGENTS.md`, `schema.md`, extension, bundles.
7. `./pgdocker/pg-cli-retest.sh`, `./pgdocker/pg-ext-retest.sh`, `./pgdocker/pg-ext-lifecycle.sh`.
8. Delete the S16 row, write its record in `plans/ext-solved-items.md`, delete this plan.
9. No commits without asking.

## What still needs the real database

The review could not settle these without a run, so the harness run in step 7 is where they
are answered, and each gets a line in the closure record:

- The cascaded UPDATE from a rename issued as `user3` passing through the RLS, audit and
  module-version triggers on `entities`, `modules` and `role_permissions`. Referential
  actions run as the referencing table's owner with RLS not forced, so RLS should not block.
- `0450` GROUP 2: the recursive permission walk still resolving through the renamed
  composite indexes with `enable_seqscan = off` on text keys.
- The resolver's behaviour for a reference to an entity with no physical table:
  `to_regclass` returns NULL, the INTEGER fallback applies and the `ADD CONSTRAINT` fails on
  the missing relation, which is what happens today.

## Done when

No VARCHAR remains outside vendored files, asserted from the catalog. `permissions` has no
`id` column and `permission_name` is its primary key. Every column that names a permission is
a foreign key to it. The six new assertions pass on both install layouts, the existing suite
is green with no assertion dropped, the schema RPCs return `string` for every reference to
`permissions`, the extension build equals the committed one, and S16 is recorded as closed.

## Decisions the owner takes at execution time

- Column naming: `permission_name` in the link tables as proposed, or keep `permission_id`.
- Remove `validate_permission_exists`, the two trigger checks and the two id existence
  checks in the cycle guard, or keep them for their error sentences.
- The strict name CHECK is decided in this plan for the two reasons given; the owner can
  veto it, in which case the hierarchy key needs a separator the alphabet excludes.
- Whether the MCP server's tool contract change is done alongside or after.

## Not in this plan

- The per-entity key format (`int32`, `int64`, `text`, `uuid`) for dictionary-created
  tables. Its design was discussed on 2026-09-06 and needs its own plan; this plan lands the
  piece it shares, the reference typing.
- Modules and roles keyed by slug. Same argument as permissions, no live hazard, and a
  larger footprint; a stated follow-up, sized in the conversation of 2026-09-06.
- `get_record_by_id` for text-keyed entities.
- The MCP server's schemas and skill text, listed above so nothing is missed.
