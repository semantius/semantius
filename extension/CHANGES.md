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
- Removed: the `pg_extension_config_dump` registry, the three-pass restore
  procedure and the `pg_semantius.skip_audit` workaround, none of which are
  needed once no table is an extension member.

Earlier 0.3.0 and 0.4.0 builds were development snapshots and were never
released; there is no upgrade path from them.
