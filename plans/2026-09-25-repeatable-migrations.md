# Plan: repeatable migrations, entity definitions as `.jsonc`, renumbering

## Context

Today every migration runs once: the runners skip a file whose name is already
in `public._versions`. A fix to a function, trigger or policy can only ship as a
new file, so files pile up once 0.5.0 is frozen. Metadata has the same problem:
`INSERT INTO entities/fields` works once; every later change needs a
hand-written `UPDATE` migration.

Outcome:
1. `.sql` and `.jsonc` files re-run whenever their content changes; files marked
   `.once.` run exactly once.
2. Entity metadata becomes declarative `.jsonc` (semantius-cli export format),
   applied inside PostgreSQL by `ensure_entities`.
3. All migrations are renumbered 0010, 0020, … in their new order.
4. A fresh install produces the same database as the baseline (section 9),
   proven by a diff.

0.5.0 is the first version; nothing is live. PostgreSQL 18 everywhere. No code is
shared with semantius-cli, only its file format.

---

## 1. Run rules (all apps)

| File | Runs |
|---|---|
| `NNNN_name.sql`, `NNNN_name.jsonc` | when `_versions` has no row for the file, or its recorded checksum differs |
| `NNNN_name.once.sql`, `NNNN_name.once.jsonc` | only when `_versions` has no row; never again, even when changed |

- **Ledger name** = `<app>.<full file name>`, e.g. `_core.0020_settings.once.sql`
  (today the `.sql` is stripped). The row stores the checksum: SHA-256 of the
  LF-normalized file text (existing `migrationChecksum` / `sha256hex`).
- **Numbers** are unique per app (loaders reject duplicates); files run in byte
  order of their name. One pass; each file decides run or skip at its position.
- **9900 and above** run last and also whenever any other file of the app ran in
  this pass, **including a pass that failed**: after a failing file, the 9900+
  files still run, each in its own transaction, and then the original error is
  raised again (a failure inside them is reported next to it). The files that
  committed before the failure are therefore never left owned by the installing
  superuser while their grants to `semantius_user` are live
  (`9900_owner_hardening.sql` hands new objects to `semantius_owner`).
- **Force a re-run**: `UPDATE _versions SET checksum = NULL WHERE …`.
- **One transaction per file** (CLI, extension, bundle runners), and every file of
  a run on **one connection**.
- **One migration at a time**: every runner (CLI, extension procedure,
  neon-provisioner, triggerdev) takes the session lock
  `pg_try_advisory_lock(hashtext('migrate'))` once for the whole run and fails at
  once with "another migration is running" when it is held. A session lock
  survives the per-file COMMITs, which `pg_advisory_xact_lock` does not. It is
  released at the end and on every error path (and by PostgreSQL when the
  connection closes). A file's ledger row is read only after the lock is held.
- **Numbering after release**: a file added after a release sorts after every
  file that release contains (9900+ excepted). Otherwise it runs mid-sequence on
  a fresh install but last on an upgrade. The extension build refuses an added
  file that sorts before the last released file.
- **Released file names are frozen**: the ledger key is the name, so a renamed
  `.once.` file runs again. The build's check for files removed since the last
  release stays in force for all files (a rename shows up as removed + added).
- **DD generator fixes reach existing entities only through a new `.once.` file**:
  re-running a repeatable file replaces a generator (`create_dd_table`,
  `build_select_rule_policy`, `build_record_logic_trigger`, …), not the policies,
  functions and triggers it generated earlier. A change to a generator ships with
  a `.once.` file that rebuilds its objects for every affected entity.
- **`pending()`** = the files the next migrate would run. **`status().changed_versions`**
  = `.once.` files whose checksum differs (display only).
- **Released `.once.` files are frozen.** During 0.5.0 every file may still be
  edited. From the first version after 0.5.0, a `.once.` file that a released
  version contains must not change: the extension build fails on such an edit
  (existing edit detection, extension.ts:293-348, narrowed to `.once.` files),
  and only an explicit instruction allows it (`--allow-edited-migrations`).
  `.sql` and `.jsonc` stay editable; that is their purpose.
- **Consequence of Q4/Q5**: an object changed by hand in the database (or
  metadata edited by an admin) stays changed until its file changes or its
  checksum is cleared; migrate does not repair it.

**Forward only, additive only — from the first version after 0.5.0.** 0.5.0 is
the only version where existing databases do not matter. After it there are no
down migrations and released `.once.` files are never edited; a mistake is fixed by
the next file. Migrations never rename, drop or change the type of a
table or column: add the new one, move the data, leave the old one (marked
deprecated in its description). This is what keeps `.jsonc` (current state,
edited in place) and later `.once.` files (history, never edited) consistent:
every `.once.` file sees the same starting point on a fresh install and on an
upgrade. `ensure_entities` never deletes, and the DD already rejects
type-changing format changes (90223).

**What goes where**: schema (tables, columns, constraints, indexes, types,
seeds, broad grants) goes into `.once.` files; code (functions, triggers,
views, event triggers, policies not generated by the DD) goes into `.sql`.
Repeatable files use `CREATE OR REPLACE FUNCTION/VIEW/TRIGGER`,
`DROP … IF EXISTS` + `CREATE` for policies and event triggers,
`CREATE … IF NOT EXISTS`, and restate security settings next to each function.
Not changeable in a repeatable file (needs a `.once.sql`): anything behind
`IF NOT EXISTS`, a function's return type, dropping view columns, and the
`valid_format` CHECK built from `dd_formats()`. A changed parameter list is not a
replacement: `CREATE OR REPLACE` adds a second overload and the old one keeps its
grants, so the file must `DROP FUNCTION IF EXISTS <old signature>` first.

## 2. `.jsonc` entity definitions

Format = semantius-cli export format version 1
(`C:\dev\semantius-cli\src\local-tools\transfer\format.ts`) plus comments:

```jsonc
// user bookmarks: personal favorites, own rows only
{
  "version": 1,
  "entities": [
    {
      "entity": {
        "table_name": "user_bookmarks",
        "module_name": "_core",
        "singular_label": "User Bookmark",
        "plural_label": "Favorites",
        "view_permission": "user:read",
        "edit_permission": "user:read",
        "label_column": "title",
        "order_column": "row_order",
        "select_rule": {"==": [{"var": "user_id"}, {"var": "$user_id"}]},
        // replaces the aaa_assign_user_id trigger and the hardened insert policy
        "computed_fields": [{"name": "user_id", "jsonlogic": {"var": "$user_id"}}],
        "fields": [
          {"field_name": "title", "ctype": "label", "title": "Title"},
          {"field_name": "user_id", "format": "reference", "reference_table": "users",
           "reference_delete_mode": "cascade", "input_type": "hidden", "field_order": 10}
        ]
      }
    }
  ]
}
```

- Top-level keys as in the export: `version` (1), `module`, `permissions`,
  `permission_hierarchy`, `roles`, `role_permissions`, `entities`; each entity
  entry may carry `records`. The same rules as the semantius-cli import
  (`import.ts`): metadata is matched by name, never by id, and never written
  with `ON CONFLICT`; create-only columns are written on insert only.
- Apply order as in the CLI import: module sections, entities, fields, then the
  entity columns that name fields (`label_parent`, `computed_fields`,
  `validation_rules`, `select_rule`), then the records. Every record is written
  under the rules, on a first apply as on a re-apply.
- Records are repeatable like everything else: keyed on the entity's id column,
  table by table in foreign-key order; a missing row is inserted, a differing
  row updated, nothing is deleted; `audit` columns and computed fields are not
  written; the id sequence is moved past the highest id after each table.
- Array order is creation order, so it fixes column order.
- Omitted key: default on insert, untouched on update. Explicit `null`: NULL.
- `module_name` replaces `module_id 1` and the module subselects.
- Core fields (id, label, created_at, updated_at) may be listed to adjust them,
  replacing today's `UPDATE fields …` after entity inserts.
- JSONC = JSON plus `//` and `/* */` comments, trailing commas, BOM, CRLF.
- Applied only when the file changed; admin edits survive until then.

## 3. New functions (file `ensure_entities.sql`)

Both `SECURITY INVOKER`, `SET search_path = public, pg_catalog`,
`COMMENT ON FUNCTION`, `REVOKE EXECUTE … FROM PUBLIC`, no grant to API roles.

**`public.jsonc_to_jsonb(jsonc text) RETURNS jsonb`** — `IMMUTABLE STRICT`
character scanner: drops a BOM, comments outside strings (respecting `\"`,
`\\`) and trailing commas, then casts to `jsonb`. No runner needs a JSONC library.

**`public.ensure_entities(definition jsonb) RETURNS jsonb`** — makes the listed
module sections, entities, fields and records exist as described (section 2); creates what is missing, updates only
what differs, never deletes, never uses `ON CONFLICT` on metadata. Returns a
summary (created/updated entities and fields, fields not in the definition) and
raises one NOTICE per change.
1. Validate keys (unknown → error; export's computed keys `searchable`,
   `is_child`, `plural`, `id`, `created_at`, `updated_at`, `module_id` are
   ignored). Values a trigger would rewrite (`field_order: 0`, empty
   `singular`/`singular_label`, non-array `enum_values`) are rejected, so
   re-applying an unchanged definition writes nothing.
2. Module sections (`module`, `permissions`, `permission_hierarchy`, `roles`,
   `role_permissions`), matched by name, same way as below; then resolve
   `module_name`.
3. Entities in array order, without `label_parent`, `computed_fields`,
   `validation_rules`, `select_rule`: insert if missing, else update only the
   changed columns; no UPDATE when nothing differs.
4. Fields in array order, key `(table_name, field_name)`, same way; `ctype`
   allowed on insert.
5. The deferred entity columns, same way.
6. Records (section 2), after all metadata.
7. Refused (not additive): changing `order_column` (drops the old column),
   `managed` from true to false. Everything else the DD rejects surfaces
   unchanged.

Every runner executes a `.jsonc` as:
```sql
SELECT public.ensure_entities(public.jsonc_to_jsonb($pgsem_jsonc$<raw file text>$pgsem_jsonc$));
```
(`$pgsem_jsonc$` differs from the extension's per-step tag, extension.ts:1103;
`assertNoTagCollisions` checks it; `lintMigration` skips `.jsonc`.)

## 4. No hand-written code may replace a DD-generated object

When `view_permission`, `edit_permission`, `select_rule`, `computed_fields`,
`validation_rules` or a field's type/reference/enum/unique/default change, the
DD drops and re-creates the objects it generates, under fixed names
(`<t>_{select,insert,update,delete}_policy`, `select_rule_<t>`,
`compute_validate_<t>`, `<t>_<f>_fkey`, `<t>_<f>_check`, `<t>_<f>_unique`,
`idx_<t>_<f>`, column NOT NULL/DEFAULT). Hand-written SQL that replaces one of
these is silently lost on such a change, and overwrites the DD's version when
it runs again.

**Rule:** attached logic (e.g. a coming ledger) uses its own object
names; anything the DD generates is expressed through metadata, never
overwritten by SQL. If metadata cannot express it, the DD is extended.

Today two objects break the rule; both move into metadata:
- **`user_bookmarks`**: the `aaa_assign_user_id` trigger and the stricter
  `user_bookmarks_insert_policy` (0280:78-110) are replaced by the computed field
  `user_id = $user_id` (section 2 example): the DD's compute trigger forces
  `user_id` to the current user on every insert and update, so the default
  insert policy suffices (its `WITH CHECK` always ran after the trigger and so
  always passed). Bookmarks become a pure `.jsonc`.
  The compute trigger reads `$user_id` through `rbac.user_id_or_null()`
  (0180:330), because it fires for every writer of every entity with rules,
  including the migrations and seeds that carry no claims. Without more, a
  bookmark written without claims would be stored with `user_id` NULL, where the
  old trigger (`rbac.user_id()`) raised. A platform `validation_rule` on
  `user_bookmarks` rejects a write whose `$user_id` is null (a new class-90 code,
  registered in `docs/error-contract.md`), so that write keeps failing.
- **`modules`**: `modules_select_policy` (0050:44, 2025, predates JsonLogic)
  checks each row's own `view_permission`. It becomes the `select_rule`
  `{"or": [{"has_permission": "admin"}, {"has_permission": {"var": "view_permission"}}]}`
  (JsonLogic evaluates operator arguments, 0015:408-412). A non-empty
  `select_rule` replaces the entity's `view_permission` for row access (D8,
  `docs/authz-spec.md`); the entity's `view_permission` then only decides who can
  fetch the `modules` schema through `get_schema` and its siblings (0080:240, 527,
  719, 758); it stays `'admin'`. The rule also fixes `get_record_by_id` and the
  JsonLogic `set_record` operator: they are SECURITY DEFINER and apply the DD
  predicate, which today is `view_permission = 'admin'` for `modules`, so a user
  who holds a module's own `view_permission` sees the row through RLS but gets
  NULL from them. With the rule they return what RLS returns.
  `0110_test_jsonlogic_ext.sql` is already corrected to expect that (user2,
  holding `nwind:view`, reads the Northwind module) and fails until this change.

The 40 hand-written policies of the 10 bootstrap tables (0050, 0060) use DD
names too. They are identical to what the DD generates, but a later admin edit
plus a re-run of their file would overwrite the DD's version. They are removed;
the completion step (section 6) lets the DD generate them through
`create_entity_policies(p_table_name text)`, the policy block of
`create_dd_table` (0070:440-490) extracted into its own function and used by
both.
## 5. Runner changes

| Where | Change |
|---|---|
| `packages/core/src/migrate.ts` (`executeMigrations` :161) | run rule, 9900 rule (also after a failing file, then re-raise), ledger read after the lock, ledger upsert with checksum, `.jsonc` wrapping; helpers `isOnce(fileName)`, `isJsonc(fileName)`, `shouldRun(file, ledgerRow, ranInPass)`, `wrapJsonc(text)` (`migrationChecksum` is already exported, :47) |
| `packages/cli/commands/migrate.ts` (`loadSqlFiles` :229, `generateMigrationScript` :271) | load the four suffixes, reject duplicate numbers; script mode applies the same run rules (each file guarded by its `_versions` row and checksum inside a `DO` block, ledger upsert with checksum, `.jsonc` wrapped); the script starts with `\set ON_ERROR_STOP on`, a failure is fatal, and the 9900 files do not run after a failure in script mode |
| `packages/cli/commands/extension.ts` (`renderInstaller` :1152, `migrate()` :1300, `pending()` :1409, `status()` :1441) | `migrate()` becomes `PROCEDURE semantius.migrate(INOUT summary jsonb DEFAULT NULL)`, called with `CALL`. Superuser and privilege checks first, then `pg_try_advisory_lock(hashtext('migrate'))` once (session lock, raises "another migration is running" when held; released at the end and in every file's exception handler before re-raising). Each file: read its ledger row, `set_config()` for `search_path`, `standard_conforming_strings`, `check_function_bodies`, `session_replication_role` (a procedure that commits cannot have `SET` clauses), the file in its `EXCEPTION` block, ledger upsert, then `COMMIT` outside that block. Called inside a transaction block, PostgreSQL itself raises 2D000. After a failing file, the 9900+ files run before the error is re-raised. `REVOKE`/`COMMENT ON PROCEDURE`. `pending()` and `status().pending` follow the run rules (checksum, 9900 rule); `status().pending` is today `array_length - applied` (:1506). Edit detection (:293-348): only `.once.` files frozen, the removed-file check stays for all files, an added file sorting before the last released file is refused. `lintMigration` keeps its ban (a session `SET` would still leak into the following files) with its message rewritten; it no longer claims one transaction |
| `scripts/bundle-sql.ts` (:73, :163, :187) → three `migrations-bundle.ts` | new suffixes; byte-order sort instead of `localeCompare` |
| `packages/neon-provisioner/src/migrate.ts` (:75-88) | today every query may run on a different pooled connection, so `BEGIN`/file/`COMMIT` are not one transaction. Take one client (`pool.connect()`) for the whole pass and release it at the end. Without `modules`, `migrate()` and `POST /migrate` migrate only `_core` (today: every bundled app, `nwind` included, :62-66) |
| `docker-postgres/initdb/40-nwind.sh` | applies the nwind `.jsonc` files (section 6) with the same wrapping and run rules as the runners, ledger = file name |

## 6. Conversion and new numbering

`CREATE TRIGGER` → `CREATE OR REPLACE TRIGGER` (same name, same firing order);
policies and event triggers → drop + create; metadata created after the DD is
complete → `.jsonc`; statement order kept inside every split; vendored code
(pgmq, pgTAP) untouched as `.once.sql`.

The core tables are registered before the DD triggers exist, so completion
steps are needed for them. They move into one file after all DD feature files,
in today's order: comments (0070:353-381), search vectors (0072), label
functions (0145:938), audit tracking (0150:997), record logic (0180:683), then
the new steps: `create_entity_policies` for the 10 bootstrap tables and
`build_select_rule_policy('modules')` (section 4).

`_core` (old → new):

| New | From | Content |
|---|---|---|
| 0010_core.sql | 0010 | pgcrypto, roles (guarded DO), `common` schema, `update_updated_at_column` |
| 0020_settings.once.sql | 0010 | `_settings` table, RLS, deny-all policy, default privileges (0010:67/73) |
| 0030_session_authenticator.sql | 0011 | unchanged |
| 0040_cache.sql | 0012 | unchanged |
| 0050_jsonlogic.sql | 0015 | unchanged |
| 0060_rbac_schema.once.sql | 0020, 0030 | 8 tables, 5 ADD COLUMN, 18 indexes; `rbac` schema, grants, default privileges (0030:5-21) |
| 0070_rbac_schema.sql | 0020 | slug functions + triggers, 4 `update_*_updated_at` triggers + comments |
| 0080_rbac_functions.sql | 0030 | 21 functions, 2 triggers, per-function revokes, and last the `REVOKE … ON ALL FUNCTIONS IN SCHEMA rbac FROM PUBLIC` (0030:1484-1486, must follow all functions) |
| 0090_rbac_seed.once.sql | 0040 | unchanged (deferred FK stays last) |
| 0100_rbac_rls.sql | 0050 | DO check, RLS enable, `versions_select_policy`, 8 triggers, 6 functions, per-object grants (the 32 core-table policies go, section 4) |
| 0110_rbac_grants.once.sql | 0050 | `ON ALL TABLES/SEQUENCES` grants (0050:258, 261), default privileges (0050:270-272) |
| 0120_dd_formats.sql | 0060 | `dd_formats()` |
| 0130_dd_schema.once.sql | 0060 | `entities`/`fields` tables, indexes |
| 0140_dd_schema.sql | 0060 | 3 functions, 5 triggers, grants, revokes (the 8 `entities`/`fields` policies go, section 4) |
| 0150_dd_bootstrap.once.sql | 0060 | DO block with CHECK constraints (0060:589-682), rows for the 10 core tables (`modules`: `select_rule`, `view_permission` stays `'admin'`) |
| 0160_dd_functions.sql | 0070 | 29 functions (+ `create_entity_policies`), 14 triggers, grants |
| 0170_dd_rename.sql | 0140 | 4 functions, 4 triggers |
| 0180_managed_enable.sql | 0145 | 10 functions, 8 triggers, `users_external_id_unique` |
| 0190_audit_log.once.sql | 0150 | `audit` schema, default privileges (0150:26-27), `audit.operation`, 2 tables, indexes, comments, RLS enable, `GRANT USAGE ON SCHEMA audit` |
| 0200_audit_log.sql | 0150 | 14 functions, 2 event triggers, 2 triggers, 4 policies, grants/revokes (0150:1059-1091) |
| 0210_computed_validation.sql | 0180 | 6 functions, 2 triggers |
| 0220_entity_insert_defaults.sql | 0230 | unchanged |
| 0230_entity_order_column.sql | 0270 | 2 functions, 3 triggers |
| 0240_dd_bootstrap_complete.once.sql | 0070, 0072, 0145, 0150, 0180 | the completion steps, in the order above |
| 0250_public_functions.sql | 0080 | unchanged |
| 0260_notify_triggers.sql | 0090 | functions, triggers, event triggers |
| 0270_apikeys.once.sql | 0110 | `_apikeys` table, indexes, deny-all policy |
| 0280_apikeys.sql | 0110 | 4 functions, RLS, grants |
| 0290_ensure_entities.sql | new | `jsonc_to_jsonb`, `ensure_entities` |
| 0300_audit_log.jsonc | 0150 | audit_record_logs, audit_ddl_logs (`managed: false`) |
| 0310_pgmq.once.sql | 0160 | vendored pgmq 1.11.1 |
| 0320_queue.jsonc | 0170 | queues, queue_table_events (`table_name` first) |
| 0330_queue_setup.once.sql | 0170 | `SET NOT NULL` ×2, `queue_table_events.table_name` NOT NULL / DEFAULT '' |
| 0340_queue.sql | 0170 | 12 functions, 6 triggers, grant |
| 0350_raci.jsonc | 0210 | processes, raci_assignments, process_gates, raci_events |
| 0360_raci_setup.once.sql | 0210 | `SET NOT NULL` ×2, CHECK `valid_process_key`, 2 UNIQUE constraints, 3 partial unique + 4 indexes, `raci_notify` seed |
| 0370_raci.sql | 0210 | trigger on users, 9 functions, view, gate trigger |
| 0380_webhook_receiver.jsonc | 0250 | webhook_receivers (`table_name` first), webhook_receiver_logs |
| 0390_webhook_receiver_setup.once.sql | 0250 | `table_name` NOT NULL / DEFAULT '' |
| 0400_dashboard.jsonc | 0260 | dashboards |
| 0410_user_bookmarks.jsonc | 0280 | user_bookmarks incl. computed `user_id` and the platform validation rule rejecting a null `$user_id` (trigger, function and policy override removed) |
| 0420_module_version.sql | 0282 | 3 functions, 6 triggers (needs `processes`) |
| 9900_owner_hardening.sql | 0290 | unchanged |

The `ADD COLUMN table_name TEXT NOT NULL DEFAULT ''` pre-creates (0170:167,
0250:42) are gone: `field_data_type` (0070:84) already gives a reference to
`entities` a TEXT column; the NOT NULL / DEFAULT move into 0330 / 0390.

`apps/test`: `0010_pgtap.once.sql`, `0020_ext.sql`, `0030_seed.once.sql`.
`apps/nwind`: `0010_nwind.jsonc` (module, permissions, hierarchy, role, grants,
entities, fields; replaces `0010_create.sql` including its `UPDATE`s and `DO`
blocks) and `0020_nwind_data.jsonc` (the records; replaces `0020_load_data.sql`).

## 7. Tests

New:
- **`pgdocker/pg-compare-installs.sh <baseline-ref>`**: installs the baseline
  (`git worktree`) and the new tree through the CLI into two databases and diffs:
  normalized `pg_dump -s` (reuse `norm()` from pg-ext-lifecycle.sh); column
  type/notnull/default/order, constraints, indexes, triggers (+ enabled),
  policies, functions (body, config, security, ACL, owner), table ACL/owner,
  default ACL, comments, event triggers; rows of entities, fields, modules,
  roles, permissions, role_permissions, permission_hierarchy, queues,
  queue_table_events, `pgmq.meta`, sequence values. Ignored: timestamps,
  `modules.version`, audit log tables, `_versions`. Expected differences
  (section 4): `modules` policies and entity row, `user_bookmarks` trigger,
  function, insert policy and `computed_fields`, the `compute_validate_*`
  objects for `user_bookmarks`, `create_entity_policies`. The CLI-vs-extension
  check already exists (pg-ext-lifecycle.sh:640-671).
- **Second migrate** (pg-ext-lifecycle.sh and CLI retest): nothing runs.
- **Upgrade = fresh install** (from the first release after this change on):
  `pg-compare-installs.sh` installs the previous release tag, migrates it to the
  current tree, and diffs it against a fresh install of the current tree. Guards
  the additive-only rule.
- **Forced re-run** (same harnesses): clear the checksum of every `.sql`/`.jsonc`,
  migrate, assert no error, identical snapshot, `modules.version` unchanged, no
  new `audit_record_logs` rows for `entities`/`fields`.
- **pgTAP `ensure_entities`**: create; unchanged definition writes nothing;
  partial update; omitted vs `null`; array order → column order;
  `managed: false`; `label_parent` to a field in the same file; references
  across files; rejected values and changes; unknown keys/module; module
  sections created and updated by name; records inserted, updated, unchanged
  (no write), never deleted, written under the validation rules and
  `select_rule`, id sequence moved past the highest id.
- **pgTAP `jsonc_to_jsonb`**: comment markers inside strings, `\"`/`\\`, comment
  at end without newline, CRLF, BOM, trailing comma before a comment, invalid JSON.
- **Behaviour kept (section 4)**: a user cannot insert or update a bookmark with
  another user's `user_id` (it is forced to their own), also after
  `edit_permission` changes; a non-admin sees exactly the modules whose
  `view_permission` they hold, an admin sees all, through RLS and through
  `get_record_by_id` alike (`0110_test_jsonlogic_ext.sql`); the 10 core tables' policies
  are unchanged in `pg_policies` (except `modules`); a bookmark write without
  claims raises (the validation rule), as it does today.
- **Runner tests** (CLI, extension, bundle): duplicate numbers rejected; `.once.`
  skipped when changed and listed in `changed_versions`; unchanged `.sql`/`.jsonc`
  skipped; 9900 rule; `pending()` and `status().pending`; `.jsonc` checksum parity;
  byte-order sort; tag collision check; a second runner fails at once while
  one holds the lock (CLI vs procedure, procedure vs procedure); build refuses an
  added file sorting before the last released one and a renamed released file.
- **Procedure**: a failing file leaves earlier files committed and the next
  `CALL` resumes there; `CALL` inside a transaction block fails with 2D000.
- **Hardening after a failure** (CLI and procedure): force a failure mid-pass,
  assert the 9900 files ran, no object in the core schemas is owned by the
  installing superuser, and the original error is the one reported.
- **Bundles are current**: `deno task bundle-sql --check` in `test.yml` fails when a
  `migrations-bundle.ts` differs from `apps/` (ignoring its `Generated:` line).
- **Security per conversion step**: `0900_test_security` and `0460` (rbac not
  executable by PUBLIC) run after every step.

Existing tests and scripts to change:
- Renamed files: `extension_test.ts:47,61`,
  `0300_test_rls.sql:256,259,268`,
  `scripts/extract-functions.ts:14-16`, `pg-ext-lifecycle.sh:507`,
  `docker-postgres/test-image.sh:170-185` (ledger names, "N applied" text).
- `SELECT semantius.migrate()` → `CALL`: `0980_test_extension_membership.sql`,
  `pg-ext-lifecycle.sh` (incl. :152 output grep, :549 `ON PROCEDURE`),
  `README.md:110`, `extension-release.yml:314`, `docker-compose/README.md:16`,
  `docker-postgres/README.md:19`, `docker-postgres/initdb/10-install-extension.sql:24`,
  `pgdocker/init-ext/20-extension.sql:24`, extension README (`buildReadme`).
- Single-transaction assumptions: `pg-ext-lifecycle.sh:186-196` (holds the lock
  via `BEGIN; SELECT migrate(); …`), `:198-201` (`psql -1` must now fail),
  `:206` (rollback leaves no rows → earlier files stay), `:403` (summary text).
- Readiness gates waiting for any `_core.%` row now see a half-migrated
  database: `pgdocker/pg-ext-retest.sh:76-80`, `docker-compose/test.sh:158-161`
  → wait for the `9900_owner_hardening.sql` row.
- `0890_test_user_bookmarks.sql:233-243`: the two assertions that the removed
  trigger and function exist become assertions on the `user_id` computed field
  and the `compute_validate_user_bookmarks` trigger (plan count unchanged); its
  behaviour tests stay as they are. Comments only: `0940_test_policy_subselect_form.sql:24-27`
  (`modules_select_policy` is no longer the one hand-written correlated policy)
  and `0950_test_volatility_contract.sql:29` (the insert policy no longer carries
  `user_id = rbac.user_id()`).
- `0910_test_no_unsafe_functions` (new functions), coverage threshold,
  `0920_test_catalog_hygiene` (comment step moved), `migrate.sql` `cmp`
  gates (`test.yml:200-211`, `extension-release.yml:94,152`).

## 8. References and docs

- Migration numbers in docs and comments: `RELEASE.md:71`, `docs/*.md`,
  `pgdocker/README.md`, `coverage.ts`, `drizzlegen.ts:12`, `kyselygen.ts:15`,
  `extension.ts` comments, test headers, cross-references inside migrations.
- `AGENTS.md`: line 145 (`migrate()` skips by name → checksum rule), the file
  names it cites (`0290_owner_hardening.sql`, `0030_rbac_functions.sql`,
  `0072_apply_core_fts.sql`, `0020`, `0140`), and the "a column is a two-place
  change" rule (the `fields` half of a core entity now lives in a `.jsonc`).
- `RELEASE.md`: checksum rule replaces "skip by name" and the planned
  `semantius.reapply()`; changed `.sql`/`.jsonc` now reach existing databases.
- `extension/CHANGES.md` and a proposed commit message handed to the user (not
  committed): old → new map (section 6), fresh database required (Q1).
- Regenerate `extension/` (as `0.5.0-beta1`) and the three `migrations-bundle.ts`.

## 9. Order of work

1. Runner changes (section 5) with runner tests; old files keep their names.
2. Section 4 in the old files: `create_entity_policies`, bookmarks computed
   field, `modules` select_rule; the existing suite (including the corrected
   `0110_test_jsonlogic_ext.sql`, red until this step) and the behaviour tests
   pass.
3. `jsonc_to_jsonb` + `ensure_entities` as a new old-style file.
4. The **baseline** is the previous version, `5404cdd`; do NOT commit (see
   "NO COMMITS" below). Build `pg-compare-installs.sh`, prove
   baseline vs baseline.
5. Convert `_core` in section 6 order; after each step: full suite, compare
   against the baseline, forced re-run test.
6. Rename test/nwind files; renumber; references and docs (section 8);
   regenerate; full CI harness run.

## Verification

- `deno task reset && deno task retest`
- `pgdocker/pg-compare-installs.sh <baseline>`: no diff
- `pgdocker/pg-ext-retest.sh --coverage`, `pgdocker/pg-cli-retest.sh`,
  `pgdocker/pg-ext-lifecycle.sh`
- `deno task extension 0.5.0-beta1`, then `git status -- extension/` clean
- `deno test --allow-read packages/cli/commands/extension_test.ts`
- Manual: change a title in `0400_dashboard.jsonc`, migrate → one `fields`
  UPDATE; migrate again → nothing runs.

## Decisions

Q1 fresh database, rebuild 0.5.0-beta1 (section 8) · Q2 no hand-written
override of DD objects; no companion rule, `managed` stays boolean (section 4) · Q3 one completion file (section 6) · Q4 only changed files run, no
audit suppression (section 1) · Q5 `.jsonc` applied only when changed
(section 2) · Q6 one transaction per file, procedure (sections 1, 5) ·
upgrading existing cloud tenants (who triggers `/migrate`, when) is postponed.

---

## Status / handoff (end of session 1)

### NO COMMITS - hard rule for every session of this plan

Never run `git commit`, `git stash`, `git reset`, `git checkout <branch>`,
`git branch`, `git tag`, `git rebase`, `git push` or anything else that
creates, moves or deletes a commit or a ref. The user reviews and commits
everything themselves when the work is finished. This overrides section 9
step 4 ("Commit: this is the baseline") and any other wording in this plan
or in a skill that suggests committing. Read-only git (`status`, `diff`,
`log`, `show`, `worktree add --detach <ref>` of an EXISTING commit for the
compare harness, and `worktree remove` of that temporary worktree) is fine.
If a step seems to need a commit, stop and ask.

### Where the work is

Uncommitted, in the working tree on `main` at `5404cdd` (= `origin/main`):
40 modified files plus 7 new untracked ones (`0285_ensure_entities.sql`,
`9900_owner_hardening.sql`, `0485`/`0486` tests, `migrate_test.ts`,
`migrate_build_test.ts`, `pg-compare-installs.sh`). Session 1 committed by
mistake; that was undone. A local safety branch
`backup/session1-repeatable-migrations` holds that state; leave it alone,
the user deletes it.

Steps 1-4 are done and green: `pg-cli-retest.sh` and `pg-ext-retest.sh` 2592
passing / 0 failing each, `pg-ext-lifecycle.sh` 150 / 0,
`deno test -A packages/core/src/migrate_test.ts packages/cli/commands/migrate_build_test.ts packages/cli/commands/extension_test.ts`
16 / 0. Step 5 has not started writing files; old files still carry their
old names (except `9900_owner_hardening.sql`, renamed already).

### Baseline correction

The baseline for step 5 is the previous version, `main` = `5404cdd` (an
existing commit; nothing needs committing to compare against it). `pg-compare-installs.sh 5404cdd` must show exactly the section 4
differences (modules policies + select_rule_modules functions/entity row,
user_bookmarks trigger/function/insert policy/computed_fields/validation_rules
and compute_validate_user_bookmarks, create_entity_policies,
ensure_entities* and jsonc_to_jsonb) and nothing else. Add an allowlist for
those to the script (or filter the diff) before starting the conversion.

### What was implemented, and where it differs from the text above

- `packages/core/src/migrate.ts`: run rules, `orderMigrationNames` (4-digit
  `NNNN_name[.once].(sql|jsonc)`, duplicates refused), `shouldRun`,
  `wrapJsonc`, `JSONC_TAG = $pgsem_jsonc$`, `acquire/releaseMigrationLock`,
  `runMigrations` (lock once, one client, all apps). Ledger upsert also
  resets `created_at`.
- CLI `migrate.ts`: `loadMigrationFiles` (shared with extension.ts), one
  connection; script mode = one DO block per file (`$pgsem_script$`, EXECUTE of
  the file under `$pgsem_<app>_<file>$`), session GUC `pgsem.ran` for the 9900
  rule, session lock taken in the script.
- `extension.ts`: `PROCEDURE semantius.migrate(INOUT summary jsonb)`. An early
  `COMMIT` before the lock makes CALL-in-transaction fail with 2D000 before
  anything is locked; `SET CONSTRAINTS ALL IMMEDIATE` inside each file block so
  deferred FK errors are catchable; the failing file's error is re-raised as
  `migration <app>.<file> failed: ... (SQLSTATE ..)` (P0001) after the 9900
  files ran, later failures appended to DETAIL. Manifest keys now carry the
  full file name. Misplaced added files are refused (not waivable), edited
  released `.once.` and removed files are refused unless
  `--allow-edited-migrations`.
- `9900_owner_hardening.sql` is NOT unchanged: every schema-level GRANT /
  ALTER DEFAULT PRIVILEGES is guarded by the schema's existence, otherwise the
  run-after-failure rule fails when a pass stopped before `audit`/`pgmq`
  existed.
- Readiness gates (`pg-ext-retest.sh`, `docker-compose/test.sh`) wait for
  `semantius.pending()` to be empty rather than for a named 9900 row.
- `docker-postgres/initdb/40-nwind.sh` implements the run rules and `.jsonc`
  wrapping in bash (not yet exercised: `docker-postgres/test-image.sh` not run).
- Section 4: `create_entity_policies(text)` (SECURITY INVOKER, raises 90231
  for a non-entity) is called for the ten core tables at the end of 0070;
  `build_select_rule_policy` for every managed entity with a select_rule at
  the end of 0180 (only `modules` today). Bookmarks rule is 90207 (registered
  in `docs/error-contract.md`); it exempts `$mode = delete` so a user delete
  still cascades from a session without claims.
- `0285_ensure_entities.sql` (becomes 0290 on renumbering) has FOUR functions:
  `jsonc_to_jsonb` (SQL, regex tokenizer), `ensure_entities`, and internal
  helpers `ensure_entities_row` (diff-update one row) and
  `ensure_entities_insert_rows` (one INSERT, `DEFAULT` for omitted keys). All
  SECURITY INVOKER, revoked from PUBLIC. Errors: 22023 malformed, 0A000 not
  additive (listed under Exemptions in error-contract.md). Choices made:
  ctype is insert-only and a differing ctype on an existing field raises
  0A000; order_column is refused only when the old value is non-empty;
  records of one entity must all carry the same keys; records support no
  `{"external_id": ...}` user mapping. The dictionary's field trigger does
  `SET LOCAL client_min_messages = WARNING` for the rest of the transaction,
  so ensure_entities restores the caller's level (`semantius.notice_level`)
  before each of its NOTICEs.

### Corrections to the plan text

- Step 5 cannot convert "with old names": the duplicate-number rule makes a
  split file collide with the dense old numbers (0010/0011/0012/0015). Convert
  straight into the final numbering in one go, then fix differences found by
  the compare (bisect by file if needed).
- "Bundles are current" in `test.yml` cannot work: all three
  `migrations-bundle.ts` are gitignored. `deno task bundle-sql --check` exists;
  decide whether to commit the bundles or drop the CI step.
- `packages/provisioning` (Neon HTTP driver) cannot hold a session lock or run
  a transaction per file; it now calls `runMigrations` but the guarantees do
  not hold there. Pre-existing; needs a decision.
- The plan file name should follow `plans/YYYY-MM-DD-HHMM-<topic>.md`.

### Step 5 split map (old statement -> new file)

Keep statement order inside every file. `CREATE TRIGGER` -> `CREATE OR REPLACE
TRIGGER`; `CREATE POLICY` / `CREATE EVENT TRIGGER` -> `DROP ... IF EXISTS` +
create. Statement numbers below are from a top-level statement splitter
(same logic as `topLevelStatements` in extension.ts); re-derive them rather
than trusting line numbers.

- 0010_create_core -> `0010_core.sql`: pgcrypto, both role DO blocks,
  `CREATE SCHEMA common`, COMMENT ON SCHEMA, `update_updated_at_column` +
  comment + revoke. `0020_settings.once.sql`: the two ALTER DEFAULT PRIVILEGES
  (public, common), `_settings` table, RLS, `settings_deny_all`.
- 0011 -> `0030_session_authenticator.sql`, 0012 -> `0040_cache.sql`,
  0015 -> `0050_jsonlogic.sql`: unchanged (already idempotent).
- 0020 + 0030:1-4 -> `0060_rbac_schema.once.sql`: rbac schema, its two GRANTs
  and two ALTER DEFAULT PRIVILEGES, all CREATE TABLEs, the 5 modules ADD
  COLUMNs, all 18 indexes. `0070_rbac_schema.sql`: `auto_set_module_slug`,
  `auto_set_role_slug` (+triggers, comments, revokes), the 4
  `update_*_updated_at` triggers.
- 0030 rest -> `0080_rbac_functions.sql` (2 triggers ->OR REPLACE; the
  `REVOKE ... ON ALL FUNCTIONS IN SCHEMA rbac` stays after all functions).
- 0040 -> `0090_rbac_seed.once.sql` unchanged.
- 0050 -> `0100_rbac_rls.sql`: BYPASSRLS DO, 8 RLS enables,
  `versions_select_policy` (drop+create), 6 functions, 8 triggers, per-function
  revokes. `0110_rbac_grants.once.sql`: `GRANT USAGE ON SCHEMA public`, the two
  ON ALL TABLES/SEQUENCES grants, the two ALTER DEFAULT PRIVILEGES.
- 0060 -> `0120_dd_formats.sql` (dd_formats + comment + revoke);
  `0130_dd_schema.once.sql` (entities/fields tables, their 9 indexes, the 2 RLS
  enables); `0140_dd_schema.sql` (validate_reference_table, auto_set_plural,
  enforce_catalog_aliases_append_only + their 5 triggers incl. the two
  updated_at ones, the GRANT on entities/fields, revokes);
  `0150_dd_bootstrap.once.sql` in this order: the 10 entity rows (modules keeps
  its select_rule), the CHECK-constraint DO block, the 9 field INSERTs.
- 0070 -> `0160_dd_functions.sql`, minus the comments DO block and the final
  `SELECT create_entity_policies(...)` (both -> 0240).
- 0072 -> 0240 entirely.
- 0080 -> `0250_public_functions.sql` unchanged; 0090 ->
  `0260_notify_triggers.sql` (2 triggers, 2 event triggers drop+create).
- 0110 -> `0270_apikeys.once.sql` (table, 2 indexes, RLS enable, deny-all
  policy, the table/sequence grants) and `0280_apikeys.sql` (4 functions).
- 0140 -> `0170_dd_rename.sql`; 0145 -> `0180_managed_enable.sql` (keeps
  `CREATE UNIQUE INDEX IF NOT EXISTS users_external_id_unique`) minus the final
  label-function backfill DO (-> 0240).
- 0150 -> `0190_audit_log.once.sql` (schema, its ALTER DEFAULT PRIVILEGES,
  COMMENT ON SCHEMA, the operation-type DO, both tables + indexes + comments,
  both RLS enables, GRANT USAGE ON SCHEMA audit); `0200_audit_log.sql` (all
  functions, 2 event triggers, the 2 entity triggers, 4 policies, the table and
  sequence GRANT/REVOKEs); tracking DO -> 0240; entity + field INSERTs ->
  `0300_audit_log.jsonc` (managed false, ctype on the fields).
- 0180 -> `0210_computed_validation.sql` minus the two bootstrap DO blocks
  (-> 0240). 0230 -> `0220_entity_insert_defaults.sql`, 0270 ->
  `0230_entity_order_column.sql`.
- `0240_dd_bootstrap_complete.once.sql`: comments DO (0070), 0072, label
  backfill (0145), audit tracking DO (0150), record-logic DO (0180),
  `create_entity_policies` for the 10 tables, select_rule DO (0180).
- 0285 -> `0290_ensure_entities.sql`; 0160 -> `0310_pgmq.once.sql`.
- 0170 -> `0320_queue.jsonc` (queue_name label field: unique_value, required;
  in `queue_table_events` list `table_name` FIRST, no pre-create);
  `0330_queue_setup.once.sql` (2x SET NOT NULL on queues, `table_name` SET NOT
  NULL + SET DEFAULT ''); `0340_queue.sql` (GRANT USAGE ON SCHEMA pgmq, all
  functions and 6 triggers).
- 0210 -> `0350_raci.jsonc` (4 entities, the label-field updates as core field
  entries listed first, computed_fields); `0360_raci_setup.once.sql` (2x SET NOT
  NULL, valid_process_key, the 2 UNIQUE constraints, the 7 indexes, raci_notify
  queue + its queue_table_events row); `0370_raci.sql` (users trigger, 9
  functions, view, gate trigger).
- 0250 -> `0380_webhook_receiver.jsonc` (`table_name` first, no pre-create) +
  `0390_webhook_receiver_setup.once.sql`; 0260 -> `0400_dashboard.jsonc`;
  0280 -> `0410_user_bookmarks.jsonc`; 0282 -> `0420_module_version.sql`.

### Gotchas found

- Column order: ensure_entities inserts consecutive new fields of one entity
  with one statement, so the search_vector rebuild runs once per batch. Where
  the old SQL used several INSERT statements for one entity with searchable
  fields, the physical order may differ; the compare will show it.
- No migration may contain the text `$pgsem_jsonc$`, not even in a comment.
- A function defined in two repeatable files would be downgraded when only the
  earlier file re-runs; checked: none today (pgmq overloads are within one file).
- Git Bash: `MSYS_NO_PATHCONV=1` breaks `git` paths, scope it to docker calls;
  inline Python heredocs lose backslashes, write scripts to files.

## Status / handoff (end of session 2)

### Where the work is

Steps 5 and 6 are done, but the new migration folders exist ONLY in a scratch
copy of the repository (Claude session scratchpad `conv/tree`): deleting the
old `apps/_core/migrations` files in the repository was refused by the
permission classifier, because several carry uncommitted step 1-4 edits. The
user replaces `apps/_core/migrations`, `apps/test/migrations`,
`apps/nwind/migrations` and `extension/` from that copy (or approves it). Every
other changed file (tests, scripts, docs, AGENTS.md, RELEASE.md,
`extension/CHANGES.md`, `0285_ensure_entities.sql`) is edited in the
repository directly. The pre-conversion tree (steps 1-4) is kept as
scratchpad `pre5`.

Verified in the scratch tree:
- `pg-compare-installs.sh <pre5 copy>`: no difference (schema, rows, pgmq,
  sequences, `_core,nwind`); second migrate applies nothing; forced re-run of
  all 32 repeatable files changes nothing (schema, rows, sequences,
  `modules.version`, no `entities`/`fields` audit rows). 5404cdd vs pre5 shows
  exactly the section 4 differences.
- CLI retest 2592/0, `pg-ext-retest.sh` 2592/0, unit tests 16/0,
  `deno task extension 0.5.0-beta1` deterministic, `bundle-sql --check` ok.
- Manual: a title change in `0400_dashboard.jsonc` -> one `fields` UPDATE,
  2 files applied (it + 9900); next migrate applies 0.

### Deviations from the text above

- `ensure_entities` moves an id sequence with `setval(seq, max, true)` (was
  `max + 1, false`): same next value, and `pg_sequences` matches what the old
  SQL left.
- nwind has THREE files: `0010_nwind.jsonc`, `0020_nwind_data.jsonc` (only the
  Northwind tables) and `0030_nwind_platform.once.sql` (the events queue and the
  sample rows in shared platform tables, resolved by name). Records are keyed on
  surrogate ids; in shared tables such an id depends on what other modules
  inserted first, and a re-apply would update another module's row.
- nwind column order: three bare field entries (`last_name`, `ship_name`,
  `territory_description`) end an insert batch so `search_vector` lands where
  the old SQL put it. Works, but relies on ensure_entities' batching.
- 0360 has two `SET NOT NULL` (0210 has only two).
- `pg-ext-retest.sh` step 3b (audit rows keep a column added mid-install) now
  passes vacuously: core-table audit tracking starts in 0240, after
  `entities.order_column` exists, so no audited table gets a column during the
  install. Needs a pgTAP test that writes, alters and writes again in one
  session, or removal.
- CLI retest (`pg-cli-retest.sh`) has no forced re-run of its own;
  `pg-compare-installs.sh` covers the CLI path.

### Open

- The swap into the repository (above), then `git status -- extension/` clean.
- `package.json` gained `"workspaces": ["packages/*"]` from a `deno check`;
  revert it.
- Decisions still pending from session 1: commit the three
  `migrations-bundle.ts` or drop the CI bundle check; `packages/provisioning`
  (Neon HTTP driver) cannot hold the lock or a transaction per file.
- `docker-postgres/test-image.sh` not run, so `40-nwind.sh` (which accepts all
  four suffixes) has not been exercised against the new nwind files.
- Rename this plan to `plans/YYYY-MM-DD-HHMM-<topic>.md`.
