-- =====================================================
-- MIGRATION: module_slug validation via JsonLogic
-- =====================================================
-- Replace the SQL CHECK constraint and the auto-generation trigger that
-- 0020 originally installed on the modules table with a single JsonLogic
-- validation rule on the modules entity. Going forward, the slug must be
-- supplied explicitly by the caller and conform to the pattern below.
--
-- Allowed: lowercase a-z, 0-9, '-', '_'. First character must be a-z or
-- 0-9 (no leading '-' or '_'). Empty string is still accepted because the
-- column default is '' and not every flow sets a slug.
--
-- The DROPs below are idempotent so this migration is safe to apply to
-- production databases (where 0020 created these objects) and to fresh
-- databases (where the edited 0020 no longer creates them).

ALTER TABLE modules DROP CONSTRAINT IF EXISTS valid_module_slug;

DROP TRIGGER IF EXISTS auto_set_module_slug_trigger ON modules;
DROP FUNCTION IF EXISTS auto_set_module_slug();

UPDATE entities
SET validation_rules = validation_rules || '[{
    "code": "valid_module_slug",
    "message": "module_slug must be lowercase, start with a letter or digit, and contain only a-z, 0-9, ''-'' and ''_''",
    "source_module": "platform",
    "jsonlogic": {
        "or": [
            {"==": [{"var": "module_slug"}, ""]},
            {"is_match": [{"var": "module_slug"}, "^[a-z0-9][a-z0-9_-]*$"]}
        ]
    }
}]'::jsonb
WHERE table_name = 'modules';
