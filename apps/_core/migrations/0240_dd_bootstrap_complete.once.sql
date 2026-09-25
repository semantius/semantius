-- =====================================================
-- DICTIONARY BOOTSTRAP - completion for the core tables
-- =====================================================
-- Runs once. The core tables were registered in 0150_dd_bootstrap.once.sql,
-- before the dictionary triggers existed, so what those triggers do for every
-- other entity is done here for them, in this order: table and column
-- comments, search vectors, label functions, audit tracking, record logic,
-- RLS policies, select_rule policies.

-- The core tables (0060_rbac_schema.once.sql, 0130_dd_schema.once.sql) are registered in
-- 0150_dd_bootstrap.once.sql before the entity and field triggers exist, so
-- neither they nor their columns have a comment yet. Give them the ones the triggers would
-- have written. PostgREST shows these comments as descriptions in its OpenAPI output, so this
-- keeps the DD description the only source there too; later changes reach the comments through
-- the update triggers. 0480_test_core_comments_match_dd.sql fails if a migration overwrites one.
DO $$
DECLARE
    r RECORD;
    v_comment TEXT;
BEGIN
    FOR r IN
        SELECT e.table_name, e.plural_label, e.description
        FROM entities e
        JOIN information_schema.tables t
          ON t.table_schema = 'public' AND t.table_name = e.table_name AND t.table_type = 'BASE TABLE'
    LOOP
        v_comment := dd_table_comment(r.plural_label, r.description);
        IF v_comment IS NOT NULL THEN
            EXECUTE format('COMMENT ON TABLE %I IS %L', r.table_name, v_comment);
        END IF;
    END LOOP;

    FOR r IN
        SELECT f.table_name, f.field_name, f.title, f.format, f.description, f.enum_values
        FROM fields f
        JOIN information_schema.columns c
          ON c.table_schema = 'public' AND c.table_name = f.table_name AND c.column_name = f.field_name
    LOOP
        v_comment := dd_field_comment(r.title, r.format, r.description, r.enum_values);
        IF v_comment IS NOT NULL THEN
            EXECUTE format('COMMENT ON COLUMN %I.%I IS %L', r.table_name, r.field_name, v_comment);
        END IF;
    END LOOP;
END $$;

-- =====================================================
-- SEARCH VECTORS OF THE CORE TABLES
-- =====================================================
-- The fields rows of the core tables (entities, fields, users, modules, roles,
-- permissions) are inserted in 0150_dd_bootstrap.once.sql, before
-- handle_field_searchable_insert_trigger (0160_dd_functions.sql) exists, so
-- nothing has built their search_vector columns. Tables registered later
-- through the dictionary (e.g. webhook_receivers in
-- 0380_webhook_receiver.jsonc) get them from that trigger.
SELECT update_search_vector_column('entities');
SELECT update_search_vector_column('fields');
SELECT update_search_vector_column('users');
SELECT update_search_vector_column('modules');
SELECT update_search_vector_column('roles');
SELECT update_search_vector_column('permissions');

-- Update searchable flags for all core entities to ensure consistency
UPDATE entities t
SET searchable = EXISTS (
    SELECT 1 FROM fields f 
    WHERE f.table_name = t.table_name 
      AND f.searchable = TRUE
);

-- Update is_child flags for all core entities to ensure consistency
UPDATE entities t
SET is_child = EXISTS (
    SELECT 1 FROM fields f 
    WHERE f.table_name = t.table_name 
      AND f.format = 'parent'
);

-- =====================================================
-- LABEL FUNCTIONS
-- =====================================================
-- Build the label functions of every entity that already exists (the core tables and any entity
-- registered before the zzz_label_fn_* triggers of 0180_managed_enable.sql were installed).
-- Entities registered later get theirs from those AFTER triggers. Order-independent thanks to
-- check_function_bodies being off per build.
DO $$
DECLARE r RECORD;
BEGIN
    FOR r IN SELECT table_name FROM entities ORDER BY table_name LOOP
        PERFORM rebuild_entity_label_functions(r.table_name);
    END LOOP;
END $$;

-- =====================================================
-- AUDIT TRACKING OF THE CORE TABLES
-- =====================================================
-- The _core entities are registered with audit_log = TRUE
-- (0150_dd_bootstrap.once.sql) before manage_audit_log_trigger
-- (0200_audit_log.sql) exists, so their audit triggers are built here.

DO $$
DECLARE
    v_rec RECORD;
BEGIN
    FOR v_rec IN
        SELECT e.table_name FROM entities e
        WHERE e.managed
          AND e.audit_log
    LOOP
        IF EXISTS (
            SELECT 1 FROM information_schema.tables t
            WHERE t.table_schema = 'public'
              AND t.table_name = v_rec.table_name
        ) THEN
            PERFORM audit.enable_tracking(
                v_rec.table_name::REGCLASS,
                CASE WHEN v_rec.table_name = 'users' THEN ARRAY['last_seen'] ELSE '{}'::TEXT[] END
            );
            RAISE NOTICE 'Enabled audit tracking for core table "%"', v_rec.table_name;
        END IF;
    END LOOP;
END $$;

-- =====================================================
-- RECORD LOGIC OF THE CORE TABLES
-- =====================================================
-- Core entities (roles, permission_hierarchy, etc.) are registered in
-- 0150_dd_bootstrap.once.sql with non-empty validation_rules/computed_fields
-- before manage_record_logic_trigger (0210_computed_validation.sql) exists.
-- Build their record-logic triggers now.

DO $$
DECLARE
    v_table_name TEXT;
BEGIN
    FOR v_table_name IN
        SELECT e.table_name FROM entities e
        WHERE jsonb_array_length(COALESCE(e.computed_fields, '[]'::jsonb)) > 0
           OR jsonb_array_length(COALESCE(e.validation_rules, '[]'::jsonb)) > 0
    LOOP
        PERFORM build_record_logic_trigger(v_table_name);
    END LOOP;
END;
$$;

-- =====================================================
-- POLICIES OF THE CORE TABLES
-- =====================================================
-- The ten core tables were registered as entities in 0150_dd_bootstrap.once.sql
-- before create_dd_table existed, so nothing generated their policies. Generate them
-- now, the same way the dictionary does for every other entity, so that a
-- later change to one of their permissions rebuilds them like any other.
SELECT create_entity_policies(t)
  FROM unnest(ARRAY['entities', 'fields', 'users', 'modules', 'roles', 'permissions',
                    'user_roles', 'role_permissions', 'user_permissions',
                    'permission_hierarchy']) AS t;

-- =====================================================
-- SELECT_RULE POLICIES OF THE CORE TABLES
-- =====================================================
-- A core entity registered with a select_rule (modules) was never seen by
-- manage_select_rule_policy_trigger (0210_computed_validation.sql), which did
-- not exist yet. build_select_rule_policy drops and replaces the SELECT,
-- UPDATE and DELETE policies of its entity, while create_entity_policies
-- uses a plain CREATE POLICY that fails on an existing one, so the rule is
-- layered on last, as the dictionary does for every other entity.
DO $$
DECLARE
    v_table_name TEXT;
BEGIN
    FOR v_table_name IN
        SELECT e.table_name FROM entities e
        WHERE e.managed AND e.select_rule <> '{}'::jsonb
        ORDER BY e.table_name
    LOOP
        PERFORM build_select_rule_policy(v_table_name);
    END LOOP;
END;
$$;
