-- =====================================================
-- RBAC SYSTEM - slug and updated_at triggers
-- =====================================================
-- Repeatable: the tables these triggers sit on are in 0060_rbac_schema.once.sql.

-- =====================================================
-- AUTO-SET MODULE SLUG TRIGGER
-- =====================================================
-- A module saved with an empty module_slug gets one derived from module_name,
-- on INSERT and on an UPDATE that clears it. A slug that is set is never
-- rewritten, so renaming a module does not move its URLs or break a client
-- that looks it up by slug (get_module_cubes matches on it).

CREATE OR REPLACE FUNCTION auto_set_module_slug()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.module_slug IS NULL OR trim(NEW.module_slug) = '' THEN
        -- Every run of characters outside the slug alphabet becomes one hyphen,
        -- and the ends are trimmed because rule 90702 wants a letter or digit
        -- first. A name with no ASCII letter or digit derives '', which leaves
        -- the column default in place.
        NEW.module_slug := trim(both '-_' from regexp_replace(lower(NEW.module_name), '[^a-z0-9_-]+', '-', 'g'));
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SET search_path = public;

COMMENT ON FUNCTION auto_set_module_slug IS
'Trigger function that derives module_slug from module_name when it is empty';

CREATE OR REPLACE TRIGGER auto_set_module_slug_trigger
    BEFORE INSERT OR UPDATE ON modules
    FOR EACH ROW
    EXECUTE FUNCTION auto_set_module_slug();

COMMENT ON TRIGGER auto_set_module_slug_trigger ON modules IS
'Derives module_slug from module_name when it is empty';

REVOKE EXECUTE ON FUNCTION auto_set_module_slug() FROM PUBLIC;

-- =====================================================
-- AUTO-SET ROLE SLUG TRIGGER
-- =====================================================
-- Automatically generates slug from role_name when not provided

CREATE OR REPLACE FUNCTION auto_set_role_slug()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.slug IS NULL OR trim(NEW.slug) = '' THEN
        NEW.slug := lower(regexp_replace(NEW.role_name, '[^a-zA-Z0-9]+', '_', 'g'));
        -- Collapse consecutive underscores into a single one
        NEW.slug := regexp_replace(NEW.slug, '_+', '_', 'g');
        -- Remove leading/trailing underscores
        NEW.slug := trim(both '_' from NEW.slug);
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SET search_path = public;

COMMENT ON FUNCTION auto_set_role_slug IS
'Trigger function that auto-generates slug from role_name when not provided';

CREATE OR REPLACE TRIGGER auto_set_role_slug_trigger
    BEFORE INSERT OR UPDATE ON roles
    FOR EACH ROW
    EXECUTE FUNCTION auto_set_role_slug();

COMMENT ON TRIGGER auto_set_role_slug_trigger ON roles IS
'Auto-generates slug from role_name when not explicitly provided';

-- Revoke default PUBLIC execute on trigger function
REVOKE EXECUTE ON FUNCTION auto_set_role_slug() FROM PUBLIC;

-- modules.view_permission is a foreign key to permissions(permission_name) too,
-- but it is NOT created here: it is DEFERRABLE INITIALLY DEFERRED, and a
-- deferred check queues a pending trigger event that PostgreSQL will not let a
-- later ALTER TABLE past. Adding the constraint after the first module is
-- seeded avoids ever queuing one - see 0090_rbac_seed.once.sql, where it is created
-- and the reasoning is written out.

-- =====================================================
-- TRIGGERS FOR updated_at AUTOMATION
-- =====================================================

CREATE OR REPLACE TRIGGER update_modules_updated_at
    BEFORE UPDATE ON modules
    FOR EACH ROW EXECUTE FUNCTION common.update_updated_at_column();

CREATE OR REPLACE TRIGGER update_permissions_updated_at
    BEFORE UPDATE ON permissions
    FOR EACH ROW EXECUTE FUNCTION common.update_updated_at_column();

CREATE OR REPLACE TRIGGER update_roles_updated_at
    BEFORE UPDATE ON roles
    FOR EACH ROW EXECUTE FUNCTION common.update_updated_at_column();

CREATE OR REPLACE TRIGGER update_users_updated_at
    BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION common.update_updated_at_column('last_seen');
