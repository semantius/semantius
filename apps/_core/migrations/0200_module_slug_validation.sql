-- =====================================================
-- MIGRATION: module_slug validation via JsonLogic
-- =====================================================
-- Validate modules.module_slug at write time through a JsonLogic rule on
-- the modules entity. The SQL CHECK constraint and auto-generation trigger
-- that used to live on the modules table have been removed in 0020 — the
-- slug must now be supplied explicitly by the caller and conform to the
-- pattern enforced here.
--
-- Allowed: lowercase a-z, 0-9, '-', '_'. First character must be a-z or
-- 0-9 (no leading '-' or '_'). Empty string is still accepted because the
-- column default is '' and not every flow sets a slug.

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
