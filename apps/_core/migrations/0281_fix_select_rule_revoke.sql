-- =====================================================
-- FIX: REVOKE EXECUTE on generated select_rule functions
-- =====================================================
-- build_select_rule_policy() (migration 0180) generates a per-table
-- per-row function (select_rule_<table>) but forgot to REVOKE EXECUTE
-- on that function from PUBLIC, leaving it callable by any database role.
--
-- The gap was masked previously because all select_rule entities in the
-- tests set/unset select_rule inside a ROLLBACK transaction, so no
-- generated function survived. The user_bookmarks entity (migration 0280)
-- is the first permanent entity with a select_rule, which exposed it.
--
-- Fix: update build_select_rule_policy() to add the REVOKE, then rebuild
-- all existing select_rule functions to apply the revoke retroactively.

-- =====================================================
-- STEP 1: Patch build_select_rule_policy to add REVOKE
-- =====================================================

CREATE OR REPLACE FUNCTION build_select_rule_policy(p_table_name TEXT)
RETURNS VOID AS $$
DECLARE
    v_entity entities%ROWTYPE;
    v_fn_name TEXT;
    v_policy_name TEXT;
    v_body TEXT;
    v_logic_lit TEXT;
BEGIN
    SELECT * INTO v_entity FROM entities WHERE table_name = p_table_name;
    IF NOT FOUND THEN
        -- Entity is being deleted — drop the function if it exists
        v_fn_name := 'select_rule_' || p_table_name;
        EXECUTE format('DROP FUNCTION IF EXISTS public.%I(public.%I) CASCADE', v_fn_name, p_table_name);
        RETURN;
    END IF;

    -- Skip unmanaged tables
    IF NOT v_entity.managed THEN
        RETURN;
    END IF;

    v_fn_name := 'select_rule_' || p_table_name;
    v_policy_name := p_table_name || '_select_policy';

    -- Always drop old function (CASCADE removes anything depending on it)
    EXECUTE format('DROP FUNCTION IF EXISTS public.%I(public.%I) CASCADE', v_fn_name, p_table_name);

    -- Drop the existing select policy so we can recreate it
    EXECUTE format('DROP POLICY IF EXISTS %I ON %I', v_policy_name, p_table_name);

    -- If select_rule is empty, restore the default permission-only policies (read = view
    -- permission, writes = edit permission, no per-row rule).
    IF v_entity.select_rule = '{}'::jsonb THEN
        EXECUTE format(
            'CREATE POLICY %I ON %I FOR SELECT TO semantius_user USING (rbac.has_permission(%L))',
            v_policy_name, p_table_name, v_entity.view_permission);
        EXECUTE format('DROP POLICY IF EXISTS %I ON %I', p_table_name || '_update_policy', p_table_name);
        EXECUTE format('DROP POLICY IF EXISTS %I ON %I', p_table_name || '_delete_policy', p_table_name);
        EXECUTE format(
            'CREATE POLICY %I ON %I FOR UPDATE TO semantius_user USING (rbac.has_permission(%L)) WITH CHECK (rbac.has_permission(%L))',
            p_table_name || '_update_policy', p_table_name, v_entity.edit_permission, v_entity.edit_permission);
        EXECUTE format(
            'CREATE POLICY %I ON %I FOR DELETE TO semantius_user USING (rbac.has_permission(%L))',
            p_table_name || '_delete_policy', p_table_name, v_entity.edit_permission);
        RETURN;
    END IF;

    v_logic_lit := quote_literal(v_entity.select_rule::text);

    -- Build the per-row evaluation function
    v_body := format($FUNC$
CREATE FUNCTION public.%I(p_row public.%I) RETURNS BOOLEAN AS $SEL$
DECLARE
    v_data jsonb;
    v_result jsonb;
    v_uid_text text;
BEGIN
    PERFORM rbac.ensure_context_initialized();
    v_uid_text := current_setting('app.current_user_id', true);
    v_data := to_jsonb(p_row) || jsonb_build_object(
        '$today',   to_jsonb(CURRENT_DATE),
        '$now',     to_jsonb(CURRENT_TIMESTAMP),
        '$user_id', CASE
                       WHEN v_uid_text IS NULL OR v_uid_text = '' THEN 'null'::jsonb
                       ELSE to_jsonb(v_uid_text::int)
                   END
    );

    BEGIN
        v_result := evaluate_json_logic(%s::jsonb, v_data);
    EXCEPTION WHEN OTHERS THEN
        RETURN FALSE;
    END;

    RETURN jl_truthy(v_result);
END;
$SEL$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public;
$FUNC$, v_fn_name, p_table_name, v_logic_lit);

    EXECUTE v_body;

    -- Revoke PUBLIC execute on the generated function (security best practice).
    -- Without this revoke the function is callable by any database role, which
    -- violates the project's no-public-execute invariant (0060_test_security.sql).
    -- Grant EXECUTE to semantius_user so the RLS policy can call the function.
    EXECUTE format('REVOKE EXECUTE ON FUNCTION public.%I(public.%I) FROM PUBLIC', v_fn_name, p_table_name);
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%I(public.%I) TO semantius_user', v_fn_name, p_table_name);

    -- Create the new select policy using the generated function
    EXECUTE format(
        'CREATE POLICY %I ON %I FOR SELECT TO semantius_user USING (public.%I(%I.*))',
        v_policy_name, p_table_name, v_fn_name, p_table_name);

    -- The canonical predicate ALSO gates writes: edit_permission AND the row rule.
    EXECUTE format('DROP POLICY IF EXISTS %I ON %I', p_table_name || '_update_policy', p_table_name);
    EXECUTE format('DROP POLICY IF EXISTS %I ON %I', p_table_name || '_delete_policy', p_table_name);
    EXECUTE format(
        'CREATE POLICY %I ON %I FOR UPDATE TO semantius_user USING (rbac.has_permission(%L) AND public.%I(%I.*)) WITH CHECK (rbac.has_permission(%L))',
        p_table_name || '_update_policy', p_table_name, v_entity.edit_permission, v_fn_name, p_table_name, v_entity.edit_permission);
    EXECUTE format(
        'CREATE POLICY %I ON %I FOR DELETE TO semantius_user USING (rbac.has_permission(%L) AND public.%I(%I.*))',
        p_table_name || '_delete_policy', p_table_name, v_entity.edit_permission, v_fn_name, p_table_name);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION build_select_rule_policy IS
'Generates (or drops) a per-row FOR SELECT RLS policy function that evaluates the entity select_rule JsonLogic against each row. The generated function has EXECUTE revoked from PUBLIC.';

REVOKE EXECUTE ON FUNCTION build_select_rule_policy(TEXT) FROM PUBLIC;

-- =====================================================
-- STEP 2: Rebuild select_rule functions for existing entities
-- =====================================================
-- Re-runs build_select_rule_policy for every managed entity with a non-empty
-- select_rule so the generated functions get REVOKE applied retroactively.

DO $$
DECLARE
    v_table_name TEXT;
BEGIN
    FOR v_table_name IN
        SELECT e.table_name
        FROM entities e
        WHERE e.managed = TRUE
          AND e.select_rule IS NOT NULL
          AND e.select_rule != '{}'::jsonb
    LOOP
        PERFORM build_select_rule_policy(v_table_name);
        RAISE NOTICE 'Rebuilt select_rule policy for "%"', v_table_name;
    END LOOP;
END;
$$;
