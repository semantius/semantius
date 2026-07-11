-- =====================================================
-- MODULE VERSION TRACKING
-- =====================================================
-- Adds version and version_date columns to modules table.
-- Automatically increments version and sets version_date when
-- modules or any related table (entities, roles, permissions,
-- processes) is modified.
-- =====================================================

-- =====================================================
-- ADD COLUMNS TO MODULES TABLE
-- =====================================================

ALTER TABLE modules ADD COLUMN version INTEGER NOT NULL DEFAULT 0;
ALTER TABLE modules ADD COLUMN version_date TIMESTAMPTZ;

-- =====================================================
-- ADD FIELD METADATA
-- =====================================================

INSERT INTO fields (table_name, field_name, title, description, format, is_pk, field_order, input_type, width, ctype, searchable, reference_table, reference_delete_mode)
VALUES
    ('modules', 'version', 'Version', 'Auto-incremented version number', 'int32', FALSE, 85, 'readonly', 'default', 'core', FALSE, '', ''),
    ('modules', 'version_date', 'Version Date', 'Timestamp of last version change', 'date-time', FALSE, 86, 'readonly', 'default', 'core', FALSE, '', '');

-- =====================================================
-- TRIGGER FUNCTION: bump_module_version
-- =====================================================
-- Increments version and sets version_date on the modules row directly.
-- Called by AFTER triggers on modules itself.

CREATE OR REPLACE FUNCTION bump_module_version()
RETURNS TRIGGER AS $$
BEGIN
    -- On INSERT or UPDATE, bump the version for the affected module
    IF TG_OP = 'DELETE' THEN
        -- No version bump needed when module itself is deleted
        RETURN OLD;
    END IF;

    -- Use a direct UPDATE bypassing triggers by using a session variable guard
    IF current_setting('app.bumping_module_version', TRUE) = 'true' THEN
        RETURN NEW;
    END IF;

    PERFORM set_config('app.bumping_module_version', 'true', TRUE);

    UPDATE modules
    SET version = version + 1,
        version_date = CURRENT_TIMESTAMP
    WHERE id = NEW.id;

    PERFORM set_config('app.bumping_module_version', 'false', TRUE);

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- =====================================================
-- TRIGGER FUNCTION: bump_module_version_from_related
-- =====================================================
-- Increments version on the parent module when a related table changes.
-- Expects the related table to have a module_id column.

CREATE OR REPLACE FUNCTION bump_module_version_from_related()
RETURNS TRIGGER AS $$
DECLARE
    v_module_id INTEGER;
BEGIN
    -- Determine the module_id from the affected row
    IF TG_OP = 'DELETE' THEN
        v_module_id := OLD.module_id;
    ELSE
        v_module_id := NEW.module_id;
    END IF;

    -- If module_id is NULL, nothing to bump
    IF v_module_id IS NULL THEN
        IF TG_OP = 'DELETE' THEN
            RETURN OLD;
        END IF;
        RETURN NEW;
    END IF;

    -- Guard against recursive calls
    IF current_setting('app.bumping_module_version', TRUE) = 'true' THEN
        IF TG_OP = 'DELETE' THEN
            RETURN OLD;
        END IF;
        RETURN NEW;
    END IF;

    PERFORM set_config('app.bumping_module_version', 'true', TRUE);

    UPDATE modules
    SET version = version + 1,
        version_date = CURRENT_TIMESTAMP
    WHERE id = v_module_id;

    PERFORM set_config('app.bumping_module_version', 'false', TRUE);

    -- On UPDATE, if module_id changed, also bump the old module
    IF TG_OP = 'UPDATE' AND OLD.module_id IS DISTINCT FROM NEW.module_id AND OLD.module_id IS NOT NULL THEN
        PERFORM set_config('app.bumping_module_version', 'true', TRUE);

        UPDATE modules
        SET version = version + 1,
            version_date = CURRENT_TIMESTAMP
        WHERE id = OLD.module_id;

        PERFORM set_config('app.bumping_module_version', 'false', TRUE);
    END IF;

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION bump_module_version() IS
'Trigger function on modules that increments the module version when a version-relevant column changes, unless a related-table bump is already in progress (guarded by app.bumping_module_version).';
COMMENT ON FUNCTION bump_module_version_from_related() IS
'Trigger function on module-scoped tables (entities, roles, permissions, processes, …) that bumps the owning module''s version when a related row changes, using app.bumping_module_version to avoid recursive double-bumps.';

-- =====================================================
-- TRIGGERS ON MODULES TABLE
-- =====================================================

CREATE TRIGGER bump_module_version_trigger
    AFTER INSERT OR UPDATE ON modules
    FOR EACH ROW
    EXECUTE FUNCTION bump_module_version();

-- =====================================================
-- TRIGGERS ON RELATED TABLES
-- =====================================================

CREATE TRIGGER bump_module_version_on_entities
    AFTER INSERT OR UPDATE OR DELETE ON entities
    FOR EACH ROW
    EXECUTE FUNCTION bump_module_version_from_related();

CREATE TRIGGER bump_module_version_on_roles
    AFTER INSERT OR UPDATE OR DELETE ON roles
    FOR EACH ROW
    EXECUTE FUNCTION bump_module_version_from_related();

CREATE TRIGGER bump_module_version_on_permissions
    AFTER INSERT OR UPDATE OR DELETE ON permissions
    FOR EACH ROW
    EXECUTE FUNCTION bump_module_version_from_related();

CREATE TRIGGER bump_module_version_on_processes
    AFTER INSERT OR UPDATE OR DELETE ON processes
    FOR EACH ROW
    EXECUTE FUNCTION bump_module_version_from_related();

-- Revoke default PUBLIC execute on trigger functions
REVOKE EXECUTE ON FUNCTION bump_module_version() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION bump_module_version_from_related() FROM PUBLIC;
