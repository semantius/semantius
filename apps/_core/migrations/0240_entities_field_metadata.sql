-- =====================================================
-- MIGRATION: entities field metadata (singular, module_id input_type)
-- =====================================================
-- Adjust the dictionary metadata for two of the entities entity's own fields:
--
--   * singular   -- 0230 now auto-derives singular from table_name when blank,
--                   so it is no longer a required input ('required' -> 'default').
--   * module_id  -- every entity must belong to a module, so the module field is
--                   a required input ('default' -> 'required').
--
-- input_type is a UI-level hint (not a DB constraint), so the module_id column
-- remains nullable and bare inserts (e.g. from migrations) still work.
--
-- 0060 already carries these values for fresh databases; this migration brings
-- existing/production databases into line.

UPDATE fields
SET input_type = 'default',
    description = 'Singular form of table name (auto-derived from table_name when blank)'
WHERE table_name = 'entities'
  AND field_name = 'singular';

UPDATE fields
SET input_type = 'required'
WHERE table_name = 'entities'
  AND field_name = 'module_id';

-- =====================================================
-- ctype coverage for the managed system timestamps (b6)
-- =====================================================
-- created_at / updated_at are DD-managed core columns but were historically marked with an empty
-- ctype, so the canonical "core = ctype <> ''" identity (spec v2 I6, used by the b7 trigger) would
-- not recognize them. 0060 now enumerates 'created_at'/'updated_at' in valid_ctype and the runtime
-- generators (create_dd_table, enable_dd_table) stamp them on new tables; this backfills every
-- created_at/updated_at field row already present (bootstrap meta tables on a fresh DB, and any
-- existing/production database) so the marker is complete and uniform.
UPDATE fields
SET ctype = field_name
WHERE field_name IN ('created_at', 'updated_at')
  AND ctype IS DISTINCT FROM field_name;
