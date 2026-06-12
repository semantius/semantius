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

-- NB: ctype coverage for created_at/updated_at (formerly a b6 backfill here) is now set inline at
-- every insert site as ctype='audit' (b7), alongside the is_core→ctype migration, so no backfill
-- is needed — the database is regenerated with correct values in place.
