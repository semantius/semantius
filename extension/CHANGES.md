# Changes

## 0.5.0

First build of the rebuilt packaging. The extension is now a **thin
installer**: `CREATE EXTENSION pg_semantius` creates only the cluster roles,
the `semantius` schema and its functions, and `SELECT semantius.migrate()`
installs the core schema as ordinary objects.

- Backup is a plain `pg_dump` and restore a single-pass `pg_restore`, on the
  same cluster or a fresh one. No flags, no `PGOPTIONS`, no three passes.
- `DROP EXTENSION` never causes data loss: it removes the `semantius` schema
  and its functions and nothing else, and never needs `CASCADE`.
- Custom fields added to core entities survive dump and restore.
- `schema = public` and `encoding = 'UTF8'` in the control file; no
  `requires`, so `CASCADE` can no longer install pgcrypto into the wrong
  schema. LATIN1 and SQL_ASCII databases are refused.
- New `semantius.pending()`, `semantius.version()` and `semantius.status()`.
- `_versions` gained a `checksum` column, written by both install paths.
- `rbac.uid()` accepts a token that carries **no** `role` claim when its `roles`
  claim contains `authenticated`. Microsoft Entra ID is the case this exists
  for: `role` and `roles` are both in its restricted claim set, so no
  claims-mapping policy can emit `role`, and an app role named `authenticated`
  arrives as `"roles": ["authenticated"]` instead. PostgREST selects the
  database role from that same array (`jwt-role-claim-key = .roles[0]`), so both
  ends of one token read the same thing. A `role` claim holding any other value
  is still refused.
- A token from Microsoft Entra ID, recognized by its `iss` claim, identifies its
  user as `entra.<tid>.<oid>` rather than by `sub`. Entra's `sub` is pairwise:
  each app registration receives a different one for the same person, so a
  second client or a re-created registration would have produced a second
  user. An Entra token without `tid` or `oid` is refused (`90009`).
- New `public.fix_id_sequence(p_table)`: after an import that wrote explicit
  ids, moves the table's id sequence past `max(id)` so the next ordinary insert
  does not fail with 23505. Callable by holders of the entity's
  `edit_permission`; never lowers a sequence; answers `90232` (retry) when the
  table stays locked by another writer for 2 s.
- `modules.module_slug` is optional: a module saved with an empty slug gets
  one derived from `module_name` (lowercase, each run of other characters
  becoming one hyphen), on insert and on an update that clears it. A slug that
  is set is never rewritten, so renaming a module keeps its URLs.
- The field metadata of the core tables now carries the same defaults as their
  columns, so a record created through the generated UI gets the column's
  default instead of an empty value: `modules.access_scope` (`basic`, now
  required), `modules.home_page` (`/`), `modules.module_type` (`domain`),
  `modules.view_permission` (`user:read`), `roles.origin` and
  `permission_hierarchy.origin` (`user`), `entities.computed_fields` and
  `entities.validation_rules` (`[]`). Creating a module in the UI failed with
  `valid_access_scope` before.
- `get_schema()` no longer gives a reference to a text-keyed entity
  (`permissions`, `entities`) the empty string as its default. The column is
  nullable and `''` names no row, so a form that saved it failed the foreign
  key: creating a module with `manage_permission` left empty failed with
  `modules_manage_permission_fkey`.
- Removed: the `pg_extension_config_dump` registry, the three-pass restore
  procedure and the `pg_semantius.skip_audit` workaround, none of which are
  needed once no table is an extension member.

0.5.0 is a fresh start. The earlier 0.1.0, 0.3.0 and 0.4.0 builds were
published as GitHub Releases but are treated as development snapshots: their
version history was discarded, so **there is no upgrade path from them**. An
installation on 0.3.0 or 0.4.0 cannot `ALTER EXTENSION ... UPDATE` to 0.5.0 and
cannot `DROP EXTENSION` without `CASCADE` (in those builds the core tables were
extension members). Moving to 0.5.0 means: dump the data, install 0.5.0 into a
new database, `SELECT semantius.migrate()`, reload.
