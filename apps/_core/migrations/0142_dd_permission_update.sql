-- =====================================================
-- DDL PERMISSION UPDATE SUPPORT
-- =====================================================
-- When entities.edit_permission is changed, the INSERT, UPDATE, and DELETE
-- RLS policies must be dropped and recreated with the new permission value.
--
-- NOTE: The SELECT policy is already handled by manage_select_rule_policy
-- (in 0180_computed_validation.sql) which fires when view_permission changes.

-- =====================================================
-- TRIGGER FUNCTION: update RLS policies on permission change
-- =====================================================

CREATE OR REPLACE FUNCTION update_entity_policies()
RETURNS TRIGGER AS $$
BEGIN
    -- Only act on managed tables that have physical RLS policies
    IF NOT NEW.managed THEN
        RETURN NEW;
    END IF;

    -- Rebuild INSERT, UPDATE, DELETE policies with new edit_permission
    -- (trigger WHEN clause guarantees edit_permission has changed)
    EXECUTE format('DROP POLICY IF EXISTS %I ON %I',
        NEW.table_name || '_insert_policy', NEW.table_name);
    EXECUTE format('DROP POLICY IF EXISTS %I ON %I',
        NEW.table_name || '_update_policy', NEW.table_name);
    EXECUTE format('DROP POLICY IF EXISTS %I ON %I',
        NEW.table_name || '_delete_policy', NEW.table_name);

    EXECUTE format(
        'CREATE POLICY %I ON %I FOR INSERT TO semantius_user WITH CHECK (rbac.has_permission(%L))',
        NEW.table_name || '_insert_policy', NEW.table_name, NEW.edit_permission);

    EXECUTE format(
        'CREATE POLICY %I ON %I FOR UPDATE TO semantius_user USING (rbac.has_permission(%L)) WITH CHECK (rbac.has_permission(%L))',
        NEW.table_name || '_update_policy', NEW.table_name, NEW.edit_permission, NEW.edit_permission);

    EXECUTE format(
        'CREATE POLICY %I ON %I FOR DELETE TO semantius_user USING (rbac.has_permission(%L))',
        NEW.table_name || '_delete_policy', NEW.table_name, NEW.edit_permission);

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION update_entity_policies IS
'AFTER UPDATE trigger on entities: drops and recreates INSERT, UPDATE, and DELETE
RLS policies when edit_permission changes. The SELECT policy is handled separately
by manage_select_rule_policy (0180_computed_validation.sql).';

CREATE TRIGGER update_entity_policies_trigger
    AFTER UPDATE ON entities
    FOR EACH ROW
    WHEN (OLD.edit_permission IS DISTINCT FROM NEW.edit_permission)
    EXECUTE FUNCTION update_entity_policies();

COMMENT ON TRIGGER update_entity_policies_trigger ON entities IS
'Rebuilds INSERT/UPDATE/DELETE RLS policies when entities.edit_permission is updated';

REVOKE EXECUTE ON FUNCTION update_entity_policies() FROM PUBLIC;
