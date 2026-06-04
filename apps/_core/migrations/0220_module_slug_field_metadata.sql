-- =====================================================
-- MIGRATION: module_slug field metadata
-- =====================================================
-- 0200 removed the auto-generation trigger for module_slug; the slug must now
-- be supplied explicitly by the caller. Update the dictionary metadata for the
-- modules.module_slug field accordingly so the UI reflects reality:
--   * description no longer claims auto-generation
--   * input_type becomes 'required' (was 'default')
--
-- 0060 already carries these values for fresh databases; this migration brings
-- existing/production databases (where 0060 ran before the edit) into line.

UPDATE fields
SET description = 'URL-safe unique identifier for module',
    input_type  = 'required'
WHERE table_name = 'modules'
  AND field_name = 'module_slug';
