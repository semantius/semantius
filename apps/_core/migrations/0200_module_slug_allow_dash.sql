-- =====================================================
-- MIGRATION: Allow hyphens in module_slug
-- =====================================================
-- module_slug is used for UI and as a segment in URLs, where '-' is a
-- perfectly valid and common character (e.g. 'my-module', 'crm-app').
-- Update the CHECK constraint to allow lowercase letters, numbers,
-- underscores, and hyphens.
-- Also register a jsonlogic is_match validation rule on the modules entity
-- so that UI-layer validation uses the same pattern.

-- Update CHECK constraint on modules.module_slug
ALTER TABLE modules
    DROP CONSTRAINT valid_module_slug,
    ADD CONSTRAINT valid_module_slug CHECK (
        module_slug = '' OR module_slug ~ '^[a-z0-9][a-z0-9_-]*$'
    );

-- Add jsonlogic is_match validation rule to modules entity
UPDATE entities
SET validation_rules = validation_rules || '[{"code":"valid_module_slug","message":"module_slug must start with a letter or number and contain only lowercase letters, numbers, hyphens, and underscores","source_module":"platform","jsonlogic":{"or":[{"==":[{"var":"module_slug"},""]},{"is_match":[{"var":"module_slug"},"^[a-z0-9][a-z0-9_-]*$"]}]}}]'::jsonb
WHERE table_name = 'modules';
