# Field formats from SemSchema formats.json, and one definition per object in the migrations

Plan of record: `plans/2026-09-15-2230-field-formats-and-fold.md` in the
repo (AGENTS.md convention, stamped with the local time it is saved). Deleted when the
work lands.

## Goals

1. The backend's list of field formats is SemSchema's formats.json, held in one place; the
   format constraint, the `fields.format` enum values and the format-to-type mapping derive
   from it.
2. `null` is no longer a field format.
3. `get_schema()` returns the format of every property.
4. Every object in the migrations is defined once, in the file that owns it: no
   redefinitions, no create-then-drop, no later file re-stating earlier values.
5. Migration files left empty by this are deleted.
6. All of it is done by editing existing migration files; the only new file is the test.

## Decisions taken by the user

1. Plan file in the harness location for review; copied to `plans/` on approval.
2. The `fields.format` enum contains every format.
3. `get_schema()` returns `format` on every property; the 0080 suppression list goes.
4. Mutate, do not supersede: the old lists leave 0060/0070/0080.
5. No existing databases need to be migrated; every database is built fresh.
6. Fold the cleanup in.
7. `unique_value` on `users.external_id` is folded in: 0060 declares it, 0145 builds the
   index, 0190 is deleted.
8. `dd_formats()` holds formats.json verbatim (formats.json has no `null` entry).
   `valid_format` refuses `'null'`, the enum does not offer it,
   `format_to_json_type('null')` is NULL.
9. The new test pins derived facts, no copy of formats.json.
10. New functions may be added to existing files; every function is defined exactly once.
11. No change beyond what the goals and these decisions require.
12. Every column of a table, and its `fields` catalog row, is declared in the file that
    creates the table; no later file adds one.
13. `format_to_json_type()` reads `dd_formats()` (measured: about +0.1 µs per call,
    about +4% on `build_schema_for_table`; accepted).
14. The CLI `docgen` uses the same format list instead of its own mapping.
15. A row is inserted with its final values; a later UPDATE of the same row stays only
    where the row cannot carry the value at insert time (circular reference, row generated
    by a trigger, computed flag).
16. The `tables` compatibility view is removed.
17. Column comments: whatever hand-written comment a column has stays; the generated
    comments the moved columns lose are not replaced.
18. The generated example schemas under `bearer-auth-experimental/examples/` are not
    touched.

## Context

- **Source file:** `C:\dev\schema-poc-1\packages\sem-schema\formats.json`, 44 keys.
  Against the current backend list it adds `iri`, `iri-reference`, `idn-email`,
  `idn-hostname` and drops `null`. For the 40 names the backend already knows, the file's
  `type` equals today's `format_to_json_type()` result.
- **`format` is an enum column like the seven others**, whose CHECKs are
  `col = ANY(<array>)` built in the DO block at `0060:440-497` from the array that also
  feeds their `enum_values`. `valid_format` is built the same way; only the array's source
  differs (`dd_formats()` instead of a literal).
- **Who calls the format functions.** `build_schema_for_table` (0080) and
  `update_dd_field` (0145) are SECURITY DEFINER; `format_to_json_type` is revoked from
  PUBLIC and granted to nobody. `dd_formats()` gets the same: REVOKE from PUBLIC, no GRANT.
- **The extension generator accepts edited and deleted files in the newest version**
  (`packages/cli/commands/extension.ts:237-314`); 0.5.0-beta1 is the only version in
  `extension/versions.json`. CI fails unless committed `extension/` equals
  `deno task extension 0.5.0-beta1`.

## Principles for the fold

1. One definition per object, in the file that owns it; the final body wins; the earlier
   copies and their re-stated COMMENT/REVOKE/GRANT lines go.
2. The file that creates a table declares all its columns and catalog rows. A later
   machinery file (0072 FTS, 0145 unique index, 0150 audit, 0270 order column) only
   installs its feature on what an earlier file declared.
3. An object a later file drops is not created in the first place.
4. A file left with nothing is deleted.
5. PL/pgSQL binds called functions at run time, so a body may name a function a later
   file defines; each such case is noted with why nothing runs it too early.

## Part A: formats

### `apps/_core/migrations/0060_dd_schema.sql`

- Before the enum DO block (line 440), define `dd_formats()`:
  ```sql
  CREATE OR REPLACE FUNCTION dd_formats()
  RETURNS json LANGUAGE sql IMMUTABLE SET search_path = public
  AS $f$ SELECT $formats$ { ...formats.json verbatim... } $formats$::json $f$;
  COMMENT ON FUNCTION dd_formats() IS '...';
  REVOKE EXECUTE ON FUNCTION dd_formats() FROM PUBLIC;
  ```
  Comment above it: the list is SemSchema formats.json; `json`, not `jsonb`, because the
  file's key order is the enum order.
- Lines 159-172: delete the inline `valid_format` constraint.
- Lines 443-454: `format_values TEXT[] := ARRAY(SELECT k FROM json_object_keys(dd_formats()) WITH ORDINALITY AS t(k, n) ORDER BY n);`
- In the DO block, next to the other enum constraints (after line 467):
  `EXECUTE format('ALTER TABLE fields ADD CONSTRAINT valid_format CHECK (format = ANY(%L))', format_values);`

### `apps/_core/migrations/0070_dd_functions.sql`

- `format_to_json_type` (lines 114-131): the CASE becomes
  `RETURN dd_formats()::jsonb -> p_format -> 'type';`. Language, signature, comment and
  REVOKE unchanged.

### `apps/_core/migrations/0080_public_functions.sql`

- `build_schema_for_table`, lines 317-324: the CASE becomes
  `jsonb_build_object('format', format)`; its comment says the format is always emitted.

### `packages/cli/commands/docgen.ts`

- `formatToJsonType` (lines 54-87) loses its hand-written mapping. docgen loads
  `SELECT key, value->'type' AS type FROM json_each(dd_formats())` once over its existing
  connection and looks the format up: an array type gives `'json'` (today's output for
  `json`/`jsonlogic`), a string type is returned as is, an unknown name gives `'string'`.

## Part B: the fold

### B1. Functions defined once

| Object | Final body taken from | Now lives in | Deleted from |
|---|---|---|---|
| `update_dd_field()` | `0145:456-753`, comment `0145:755-761` | `0070:911-1202` (replaces body and comment) | `0140:544-864`, `0145:449-761`. Lines `0145:763-764` stay: they REVOKE `apply_field_ddl` and `enable_dd_table`. |
| `evaluate_json_logic(jsonb, jsonb)` | `0210:413-1155` | `0015:94-760` (replaces body; `0015:762-786` stay) | `0210:406-1155` |
| `public.get_userinfo()` | `0190:115-222` | `0080:44-137` (replaces body and comment; grants `0080:139-141` stay) | `0190:115-226` |
| `public.get_user_modules()` | `0080:16-34` as it is | `0080:16-34` | `0284:187-212` |
| `rbac.upsert_user_from_jwt` | `0190:28-113` (5 args, SECURITY INVOKER, its rationale, both REVOKEs; not the DROP of the 2-arg version) | `0030:312-346` (replaces the 2-arg version) | `0190:28-113` |

Late binding, noted in a comment at each definition:
- `update_dd_field` in 0070 calls `apply_field_ddl` (0145) and relies on the BEFORE
  trigger `validate_field_rename_and_format` (0140); no `UPDATE fields` runs between 0070
  and 0145 during install.
- `evaluate_json_logic` in 0015 calls `is_raci_actor` / `has_consultation` (0210); only a
  rule using those operators reaches that branch, and no core rule does.
- `get_userinfo` in 0080 reads `users.first_name` / `last_name`, declared in 0020 (B3).
- The moved `upsert_user_from_jwt` rationale says "get_userinfo() below"; it becomes
  "get_userinfo() in 0080".

### B2. Created-then-dropped objects: neither end survives

| Object | Remove creation at | Remove drop at |
|---|---|---|
| `auto_set_module_slug()` function, trigger, comments, REVOKE | `0020:43-74` | `0200:19-20` |
| `valid_module_slug` CHECK | `0020:31` | `0200:17` |
| `auto_set_field_order()` function, trigger, comment, REVOKE | `0070:566-593`, `0070:643` | `0270:180-187` |
| `fields_table_name_fkey` drop and re-add | `0060:115` gets `ON UPDATE CASCADE` | `0140:10-23` |

### B3. Columns and catalog values declared where the table is created

| Declaration | Goes to | Removed from |
|---|---|---|
| `users.first_name`, `users.last_name` (`TEXT DEFAULT ''`) | `0020` users table | `0190:11-13` |
| `users.is_agent` (`BOOLEAN NOT NULL DEFAULT FALSE`) and its column comment | `0020` users table | `0210:18-28` (trigger `0210:30-61` stays) |
| `modules.version`, `modules.version_date` | `0020` modules table | `0282:10-15` |
| `modules.module_slug` comment | `0020:39` | `0284:124` |
| `entities.order_column` column, `valid_order_column` CHECK, column comment | `0060` entities table | `0270:30-39` |
| fields rows `users.first_name` (22), `users.last_name` (23): ctype `core`, searchable TRUE; `users.is_agent` (100): default `'false'`, ctype `''`, width `default`, searchable FALSE | `0060:591-601` users INSERT (add `default_value` to its column list) | `0190:21-26`, `0210:63-72` |
| fields rows `modules.version` (85), `modules.version_date` (86) | `0060:604-626` | `0282:17-24` |
| fields rows `entities.audit_log` (122, default `'false'`, relationship_label `'has'`), `entities.order_column` (112) | `0060:557-583` | `0150:750-755`, `0270:41-46` |
| `audit_log = TRUE` for the ten core entities; `order_column = 'field_order'` for `fields` | `0060:405-421` entities INSERT (two more columns) | `0150:881-893`, `0270:189-199` |
| modules `validation_rules`: rule 90702 after 90701 | `0060:412-413` | `0200:22-34` |
| `fields('modules','module_slug')` title/description/input_type | already at `0060:614` | `0220`, `0284:126-183` |
| `fields('entities','singular'/'module_id')` values | already at `0060:560,566` | `0240` |
| `unique_value = TRUE` on `users.external_id` | `0060:594` | `0190:15-19` |

Every value in the moved rows is copied from the later file, including the ones that
file leaves to column defaults.

Consequences: the moved columns keep only a hand-written comment, if any (decision 17);
they sit before `search_vector` in the physical column order.

### B3a. Values set by a later UPDATE of the same row go into its INSERT

| UPDATE removed | Value goes into |
|---|---|
| `0060:431` `entity_type = 'junction'` for the four junction entities | `0060:405-421` entities INSERT (add `entity_type`) |
| `0060:540-553` `input_type_rule` for the `fields` rows | the `fields` rows INSERT in the DO block (add `input_type_rule`) |
| `0060:587` `enum_values` of `entities.entity_type` | `0060:557-583` entities fields INSERT (add `enum_values`) |
| `0060:629`, `0060:632` `enum_values` of `modules.module_type`, `modules.access_scope` | `0060:604-626` modules fields INSERT (add `enum_values`) |
| `0060:648` `unique_value` of `roles.slug`; `0060:651` `enum_values` of `roles.origin` | roles fields INSERT (add `unique_value`, `enum_values`) |
| `0060:675-676` parent labels | user_roles fields INSERT (add `singular_label_parent`, `plural_label_parent`) |
| `0060:687-688` parent labels | role_permissions fields INSERT (same two columns) |
| `0060:699-700` parent labels | user_permissions fields INSERT (same two columns) |
| `0060:711-712` parent labels; `0060:715` `enum_values` of `permission_hierarchy.origin` | permission_hierarchy fields INSERT (the two label columns and `enum_values`) |
| `0280:119` `order_column = 'row_order'` | `0280:28` user_bookmarks entities INSERT (add `order_column`; the 0270 insert trigger provisions the column) |

Their comments move with them. UPDATEs that stay, with the reason: `0040:58` (the
`_core` module row must exist before the roles and permissions it points to);
`0170:45`, `0210:89,139,196,243` (the label field row is generated by the
table-creation trigger); `0072:20-33` (`searchable`/`is_child` are computed and their
triggers do not exist when 0060 runs).

### B4. Feature installs that stay in the machinery files

- **0145**: after `update_dd_field`, one statement builds the index 0190 builds today:
  `CREATE UNIQUE INDEX IF NOT EXISTS users_external_id_unique ON users(external_id) WHERE external_id IS NOT NULL AND external_id != '';`
- **0150**: `manage_audit_log` is unchanged. The catch-up loop (lines 896-914) selects
  `WHERE e.managed AND e.audit_log` and passes the ignored columns inline:
  `CASE WHEN table_name = 'users' THEN ARRAY['last_seen'] ELSE '{}'::TEXT[] END`. The
  comment at 805-812 and the loop's "_core tables are managed=false" comment say that this
  loop builds the core tables' triggers at install and the trigger handles later toggles.
- **0270**: after the entities triggers, one statement installs the order trigger on
  `fields`:
  `CREATE TRIGGER zz_auto_order_fields BEFORE INSERT ON public.fields FOR EACH ROW EXECUTE FUNCTION auto_set_order_value('field_order');`

### B5. Files deleted

`0190_user_name_claims.sql`, `0200_module_slug_validation.sql`,
`0220_module_slug_field_metadata.sql`, `0240_entities_field_metadata.sql`,
`0284_module_slug_provision.sql`.

### B5a. `tables` view removed

- Delete `0130_create_tables_view_compat.sql` (it holds only the view, its comment, its
  `security_invoker` setting and its grant).
- Other repository: `C:\dev\postgrest-mcp\src\db\hook.ts:404` reads `FROM tables`; it
  becomes `FROM entities`. That change ships before or with this one.

### B6. Comments and docs the change makes wrong

- `0020:108-112` (cites 0200), `0020:189` (cites 0190).
- `0030:632` ("the two get_userinfo prefills").
- `0040:87` ("the ALTERs in 0282 and 0284").
- `0150:805-812` and the catch-up loop comment (B4).
- `0180:299` (example "entities.order_column added in 0270 then set here").
- `0270:180-199` section headers go with the removed code.
- `apps/test/tests/0025_test_module_slug.sql:4`.
- `docs/error-contract.md:49`, `docs/bearer-mode-status.md:245`,
  `docs/jsonlogic-optimization-candidates.md:7,295-297,399-400` (the interpreter is only
  in 0015).
- `0280:110-117` step comment (the column is provisioned by the INSERT).
- `apps/test/tests/0336_test_iroles_catalog_guard.sql:15` (mentions the `tables` view).
- `RELEASE.md:96` ("34 `_core` migrations" becomes 28).
- `AGENTS.md:374` (remove `'null'` from the primitive list), `AGENTS.md:425` ("format
  field: always included"), `AGENTS.md:294-295` (the `tables` view no longer exists),
  `AGENTS.md:343` and `:413` ("tables" becomes "entities").

## Tests

### Existing assertions that change (one swapped for one, plan counts unchanged)

| File | Lines | Today | Becomes |
|---|---|---|---|
| `apps/test/tests/0110_test_get_schema.sql` | 370-373 | `ok(NOT ... 'ratio' ? 'format')` | `is(... 'ratio'->>'format', 'double')` |
| same | 415-419 | `ok(NOT ... 'id' ? 'format')` | `is(... 'id'->>'format', 'int32')` |
| same | 421-424 | `ok(NOT ... 'units_in_stock' ? 'format')` | `is(... ->>'format', 'int32')` |
| same | 448-452 | `ok(NOT ... 'status' ? 'format')` | `is(... 'status'->>'format', 'enum')` |
| `apps/nwind/tests/0050_test_nwind_features.sql` | 136-140 | `ok(NOT ... 'status' ? 'format')` | `is(... 'status'->>'format', 'enum')` |

### New `apps/test/tests/0470_test_field_formats.sql`

`BEGIN; SELECT plan(N); ... SELECT * FROM finish(); ROLLBACK;`, exact N, derived facts
only:

1. `dd_formats()` has 44 keys; `iri`, `iri-reference`, `idn-email`, `idn-hostname` are
   among them; `null` is not.
2. `format_to_json_type(k)` equals `dd_formats()::jsonb->k->'type'` for every key;
   `format_to_json_type('null')` is NULL.
3. `enum_values` of the `fields.format` row equals the ordered key array; as user3,
   `get_schema('fields')->'properties'->'format'->'enum'` equals it.
4. `pg_get_constraintdef` of `valid_format` is `format = ANY(...)` over exactly the keys.
5. Inserting a field with format `'null'` raises 23514 naming `valid_format`.
6. As user3, every property of `get_schema('fields')` that has a `fields` row carries
   `format` equal to that row's format.

## Regenerate (never hand-edit)

`deno task extension 0.5.0-beta1`; `deno task docgen` (`schema.md`);
`deno task bundle-sql` (`packages/*/src/migrations-bundle.ts`).

## Verification

1. `deno task connect`; `deno task dropall --confirm`;
   `deno task migrate --apps _core,nwind,test --verbose`; `deno task test`.
2. `deno task test 0470*` while iterating; then the full suite, then
   `pgdocker/pg-cli-retest.sh`, `pgdocker/pg-ext-retest.sh`, `pgdocker/pg-ext-lifecycle.sh`.
3. Audit the result: no function defined more than once, no created-then-dropped object,
   no column or catalog row added outside the file that creates its table, no catalog
   value re-stated by a later file, no UPDATE of a just-inserted row other than the ones
   B3a keeps, no `tables` view.
4. `deno task extension 0.5.0-beta1` and `git status --porcelain -- extension/` empty
   after committing; `deno task docgen` diff limited to the `fields.format` row.
5. Commit only when asked; do not release.
