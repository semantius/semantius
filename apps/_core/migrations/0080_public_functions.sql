-- =====================================================
-- PUBLIC FUNCTIONS
-- =====================================================
-- User-facing functions in the public schema
-- These provide convenient access to RBAC and user information
-- =====================================================

-- =====================================================
-- GET USER MODULES (Helper function)
-- =====================================================

-- Get modules the current user has permission to view
-- This function manually filters modules by permission since it may be
-- called from a SECURITY DEFINER context where RLS is bypassed
-- Used internally by get_userinfo()
CREATE OR REPLACE FUNCTION public.get_user_modules()
RETURNS JSONB AS $$
BEGIN
    RETURN COALESCE(
        (SELECT jsonb_agg(
            jsonb_build_object(
                'id', m.id,
                'module_name', m.module_name,
                'description', m.description,
                'view_permission', m.view_permission,
                'logo_url', m.logo_url,
                'logo_color', m.logo_color,
                'home_page', m.home_page,
                'module_slug', m.module_slug,
                'created_at', m.created_at,
                'updated_at', m.updated_at
            ) ORDER BY m.module_name
        )
        FROM modules m
        WHERE rbac.has_any_permission('admin', m.view_permission)),
        '[]'::jsonb
    );
END;
$$ LANGUAGE plpgsql SET search_path = public;

COMMENT ON FUNCTION public.get_user_modules IS 
'Returns modules array filtered by RLS. Used internally by get_userinfo().';

-- Revoke default PUBLIC execute, then grant only to semantius_user
REVOKE EXECUTE ON FUNCTION public.get_user_modules() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_user_modules() TO semantius_user;

-- =====================================================
-- GET USER INFO
-- =====================================================

-- Get current authenticated user's information
-- Returns the user record from the users table for the current JWT as JSON
-- IMPORTANT: This function creates/updates the user record and updates last_seen
-- Clients should call this function when they detect a new login to initialize the user
CREATE OR REPLACE FUNCTION public.get_userinfo()
RETURNS JSONB AS $$
DECLARE
    v_external_id TEXT;
    v_email TEXT;
    v_user_id INTEGER;
    v_result JSONB;
    v_roles JSONB;
    v_permissions JSONB;
    v_modules JSONB;
BEGIN
    -- Get current user from JWT
    v_external_id := rbac.uid();

    -- Get email from JWT if available
    v_email := current_setting('request.jwt.claim.email', true);

    -- Create or update user record and update last_seen
    v_user_id := rbac.upsert_user_from_jwt(v_external_id, v_email);
    
    -- Verify user was created/found successfully
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Failed to create or find user: external_id = %', v_external_id
            USING ERRCODE = 'data_exception';
    END IF;
    
    -- Verify user exists in users table
    IF NOT EXISTS (SELECT 1 FROM users WHERE id = v_user_id) THEN
        RAISE EXCEPTION 'User not found in users table: user_id = %', v_user_id
            USING ERRCODE = 'data_exception';
    END IF;
    
    -- Build roles array with role details
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'role_id', r.id,
            'role_name', r.role_name,
            'description', r.description,
            'module_id', r.module_id,
            'assigned_at', ur.assigned_at
        ) ORDER BY r.role_name
    ), '[]'::jsonb)
    INTO v_roles
    FROM user_roles ur
    JOIN roles r ON ur.role_id = r.id
    WHERE ur.user_id = v_user_id;
    
    -- Build permissions array (all effective permissions including inherited)
    SELECT COALESCE(jsonb_agg(
        permission_name ORDER BY permission_name
    ), '[]'::jsonb)
    INTO v_permissions
    FROM rbac.get_user_permissions(v_external_id);

    -- Explicitly initialize the context cache with the permissions we just computed.
    -- This is necessary because get_user_modules() -> has_any_permission() uses
    -- ensure_context_initialized() which may see a stale snapshot (STABLE function)
    -- when the user was just created in this same function call.
    PERFORM set_config('app.current_user_id', v_user_id::TEXT, true);
    PERFORM set_config('app.current_external_id', v_external_id, true);
    PERFORM set_config('app.user_permissions', COALESCE(
        (SELECT string_agg(p.value #>> '{}', ',' ORDER BY p.value #>> '{}')
         FROM jsonb_array_elements(v_permissions) AS p(value)),
        ''
    ), true);
    PERFORM set_config('app.context_initialized', 'true', true);

    -- Build modules array (filtered by permissions via helper function)
    v_modules := public.get_user_modules();
    
    -- Build the final JSON result
    SELECT jsonb_build_object(
        'user_id', u.id,
        'external_id', u.external_id,
        'email', u.email,
        'is_disabled', u.is_disabled,
        'created_at', u.created_at,
        'updated_at', u.updated_at,
        'last_seen', u.last_seen,
        'roles', v_roles,
        'permissions', v_permissions,
        'modules', v_modules
    )
    INTO v_result
    FROM users u
    WHERE u.id = v_user_id;
    
    -- Final safety check (should never be NULL after previous validations)
    IF v_result IS NULL THEN
        RAISE EXCEPTION 'Unexpected error: unable to build user info JSON for user_id = %', v_user_id
            USING ERRCODE = 'data_exception';
    END IF;
    
    RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION public.get_userinfo IS 
'Returns current authenticated user info as JSON with nested roles, permissions, and modules (filtered by RLS via helper function). Creates/updates user record and updates last_seen. Call once when new login detected.';

-- Revoke default PUBLIC execute, then grant only to semantius_user
REVOKE EXECUTE ON FUNCTION public.get_userinfo() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_userinfo() TO semantius_user;


-- =====================================================
-- GET SCHEMA CHILDREN
-- =====================================================

-- Get child relationships for a table
-- Returns an array of fields that reference the given table with format='parent'
-- Each child entry includes: fields.id, fields.title, entities.singular_label,
-- entities.plural_label, entities.id_column, entities.label_column
CREATE OR REPLACE FUNCTION public.get_schema_children(p_table_name TEXT)
RETURNS JSON AS $$
DECLARE
    v_result JSON;
BEGIN
    PERFORM rbac.uid();

    SELECT COALESCE(
        json_agg(
            json_build_object(
                'id', f.id,
                'title', f.title,
                'singular_label', e.singular_label,
                'plural_label', e.plural_label,
                'singular_label_parent', f.singular_label_parent,
                'plural_label_parent', f.plural_label_parent,
                'id_column', e.id_column,
                'label_column', e.label_column
            ) ORDER BY f.id
        ),
        '[]'::json
    )
    INTO v_result
    FROM fields f
    JOIN entities e ON f.table_name = e.table_name
    WHERE f.reference_table = p_table_name
      AND f.format = 'parent';

    RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION public.get_schema_children IS 
'Returns array of child relationships (fields with format=''parent'') that reference the given table. Each entry contains field id, title, and the child entity''s singular_label, plural_label, id_column, and label_column.';

-- Revoke default PUBLIC execute, then grant only to semantius_user
REVOKE EXECUTE ON FUNCTION public.get_schema_children(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_schema_children(TEXT) TO semantius_user;

-- =====================================================
-- GET SCHEMA FOR TABLE (Internal helper)
-- =====================================================

-- Helper that builds a schema JSON for a single table. Self-gating (b9): it applies the
-- view_permission check + existence-hiding itself (identical undefined_table error for
-- missing-table and permission-denied), so it is safe to expose directly to the request role.
-- Used by get_schema()/get_schemas()/get_*_cubes() so any future change applies to all.
CREATE OR REPLACE FUNCTION public.build_schema_for_table(p_table_name TEXT)
RETURNS JSON AS $$
DECLARE
    v_table_record RECORD;
    v_properties JSON;
    v_required_fields JSON;
    v_children JSON;
    v_result JSON;
    v_cache_version TEXT;
    v_db_version    TEXT;
BEGIN
    PERFORM rbac.uid();

    SELECT * INTO v_table_record
    FROM entities
    WHERE table_name = p_table_name;

    -- Permission gate + existence-hiding (b9). build_schema_for_table is GRANTed to the request
    -- role and reachable directly as /rpc/build_schema_for_table, so it must apply the SAME
    -- view_permission check + existence-hiding as get_schema()/get_schemas() rather than trusting
    -- callers — otherwise any request-role caller reads any table's full schema (including its
    -- select_rule logic) by calling this helper directly and skipping the wrappers. A missing
    -- table and a permission-denied table raise the IDENTICAL undefined_table error so existence
    -- cannot be probed. The four in-tree callers already pre-check, so the gate is redundant (and
    -- harmless) for them.
    IF NOT FOUND THEN
        SELECT value INTO v_cache_version FROM _settings WHERE name = 'cache_version';
        SELECT value INTO v_db_version    FROM _settings WHERE name = 'db_version';
        RAISE EXCEPTION 'Table "%" not found in entities', p_table_name
            USING ERRCODE = 'undefined_table',
                  DETAIL = json_build_object('cache_current', v_cache_version IS NOT NULL AND v_db_version IS NOT NULL AND v_cache_version >= v_db_version)::text;
    END IF;

    IF NOT rbac.has_permission(v_table_record.view_permission) THEN
        SELECT value INTO v_cache_version FROM _settings WHERE name = 'cache_version';
        SELECT value INTO v_db_version    FROM _settings WHERE name = 'db_version';
        RAISE EXCEPTION 'Table "%" not found in tables metadata', p_table_name
            USING ERRCODE = 'undefined_table',
                  DETAIL = json_build_object('cache_current', v_cache_version IS NOT NULL AND v_db_version IS NOT NULL AND v_cache_version >= v_db_version)::text;
    END IF;

    -- Build properties object from fields
    -- Each field becomes a property with JSON Schema attributes
    WITH ordered_fields AS (
        SELECT 
            f.field_name,
            f.format,
            f.title,
            f.description,
            f.default_value,
            f.input_type,
            f.width,
            f.field_order,
            f.enum_values,
            f.reference_table,
            f.reference_delete_mode,
            f.ctype,
            f.is_core,
            f.searchable,
            f.cube_type,
            f.singular_label_parent,
            f.plural_label_parent,
            f.unique_value,
            f."precision",
            f.relationship_label,
            f.input_type_rule,
            -- Join with tables to get id_column and label_column when reference_table is set
            -- COALESCE to empty string is intentional: provides consistent output when referenced table
            -- doesn't exist or is missing columns. These fields are only added to JSON output when
            -- format='reference' and reference_table is not empty (see line ~245).
            COALESCE(t.id_column, '') AS reference_table_id_column,
            COALESCE(t.label_column, '') AS reference_table_label_column,
            COALESCE(t.singular_label, '') AS reference_table_singular_label,
            COALESCE(t.plural_label, '') AS reference_table_plural_label
        FROM fields f
        LEFT JOIN entities t ON f.reference_table = t.table_name
        WHERE f.table_name = p_table_name
        ORDER BY f.field_order
    ),
    properties_with_defaults AS (
        SELECT 
            field_name,
            field_order,
            (jsonb_build_object(
                'type', CASE
                    WHEN format IN ('reference', 'parent') AND reference_table IN ('entities', 'fields')
                    THEN to_jsonb('string'::text)
                    ELSE format_to_json_type(format)
                END,
                'title', title,
                'description', description,
                'inputMode', input_type,
                'width', width,
                'field_order', field_order
            ) || 
            -- Add ctype field if present
            CASE 
                WHEN ctype IS NOT NULL AND ctype != ''
                THEN jsonb_build_object('ctype', ctype)
                ELSE '{}'::jsonb
            END ||
            -- Add is_core field
            jsonb_build_object('is_core', is_core) ||
            -- Add searchable field
            jsonb_build_object('searchable', searchable) ||
            -- Add cube_type field
            jsonb_build_object('cube_type', cube_type) ||
            -- Add unique_value field
            jsonb_build_object('unique_value', unique_value) ||
            -- Add precision only for number formats
            CASE
                WHEN format_to_json_type(format)::text = '"number"'
                THEN jsonb_build_object('precision', "precision")
                ELSE '{}'::jsonb
            END ||
            -- Add input_type_rule only when a non-empty JsonLogic rule is set
            CASE
                WHEN input_type_rule IS NOT NULL AND input_type_rule != '{}'::jsonb
                THEN jsonb_build_object('input_type_rule', input_type_rule)
                ELSE '{}'::jsonb
            END ||
            -- Add format field only for string-based formats (email, url, etc), not for type mappers (int32, float, etc) or enum
            CASE 
                WHEN format IS NOT NULL 
                     AND format != '' 
                     AND format NOT IN ('int32', 'int64', 'integer', 'float', 'double', 'number', 'boolean', 'object', 'array', 'null', 'enum')
                THEN jsonb_build_object('format', format)
                ELSE '{}'::jsonb
            END ||
            -- Add enum field if enum_values is present
            CASE 
                WHEN enum_values IS NOT NULL AND jsonb_array_length(enum_values) > 0
                THEN jsonb_build_object('enum', effective_enum_values(input_type, enum_values))
                ELSE '{}'::jsonb
            END ||
            -- Add reference_table field if format is 'reference' or 'parent'
            CASE 
                WHEN format IN ('reference', 'parent') AND reference_table != ''
                THEN jsonb_build_object(
                    'reference_table', reference_table,
                    'reference_delete_mode', reference_delete_mode,
                    'relationship_label', relationship_label,
                    'reference_table_id_column', reference_table_id_column,
                    'reference_table_label_column', reference_table_label_column,
                    'reference_table_singular_label', reference_table_singular_label,
                    'reference_table_plural_label', reference_table_plural_label
                )
                ELSE '{}'::jsonb
            END ||
            -- Add singular_label_parent / plural_label_parent for parent fields when set
            CASE
                WHEN format = 'parent' AND singular_label_parent != ''
                THEN jsonb_build_object(
                    'singular_label_parent', singular_label_parent,
                    'plural_label_parent', plural_label_parent
                )
                ELSE '{}'::jsonb
            END ||
            -- Add default field separately to handle type conversion properly
            CASE
                -- Enum: use effective default (first value when required without explicit default, else '')
                WHEN format = 'enum' THEN
                    jsonb_build_object('default', effective_enum_default(default_value, input_type, enum_values))
                WHEN default_value IS NOT NULL AND trim(default_value) != '' THEN
                    CASE
                        -- Special case: reference/parent to entities/fields are string-typed
                        WHEN format IN ('reference', 'parent') AND reference_table IN ('entities', 'fields')
                        THEN jsonb_build_object('default', trim(both '''' from default_value))
                        WHEN format_to_json_type(format)::text = '"integer"' THEN jsonb_build_object('default', (default_value::INTEGER))
                        WHEN format_to_json_type(format)::text = '"number"' THEN jsonb_build_object('default', (default_value::NUMERIC))
                        WHEN format_to_json_type(format)::text = '"boolean"' THEN jsonb_build_object('default', (default_value::BOOLEAN))
                        WHEN format_to_json_type(format)::text IN ('"object"', '"array"') THEN jsonb_build_object('default', default_value::jsonb)
                        -- For strings, trim quotes if present (handles SQL literal strings like 'active')
                        ELSE jsonb_build_object('default', trim(both '''' from default_value))
                    END
                -- Special case: reference/parent to entities/fields get empty string default
                WHEN format IN ('reference', 'parent') AND reference_table IN ('entities', 'fields')
                THEN jsonb_build_object('default', '')
                -- For string types without explicit default, add empty string default
                WHEN format_to_json_type(format)::text = '"string"' THEN jsonb_build_object('default', '')
                -- For JSON types without explicit default, add empty object default
                WHEN format = 'json' THEN jsonb_build_object('default', '{}'::jsonb)
                ELSE '{}'::jsonb
            END)::json AS property_value
        FROM ordered_fields
    )
    SELECT COALESCE(
        json_object_agg(
            field_name,
            property_value ORDER BY field_order
        ),
        '{}'::json
    )
    INTO v_properties
    FROM properties_with_defaults;
    
    -- Build required fields array (fields where nullability is false based on format)
    -- Exclude the id_column since it's auto-generated and not required for INSERT
    -- Exclude created_at and updated_at since they are auto-maintained by triggers
    WITH required_fields AS (
        SELECT field_name, field_order
        FROM fields
        WHERE table_name = p_table_name
          AND is_nullable = FALSE
          AND field_name != v_table_record.id_column
          AND field_name NOT IN ('created_at', 'updated_at')
          AND default_value IS NULL
          AND format != 'json'
        ORDER BY field_order
    )
    SELECT COALESCE(
        json_agg(field_name),
        '[]'::json
    )
    INTO v_required_fields
    FROM required_fields;
    
    -- Get children (fields in other tables that reference this table with format='parent')
    v_children := public.get_schema_children(p_table_name);

    -- Build the final JSON Schema result
    v_result := json_build_object(
        '$schema', 'https://semantius.com/meta/sem-schema/v1',
        '$id', 'https://example.com/schemas/' || p_table_name || '.schema.json',
        'title', v_table_record.singular_label,
        'description', v_table_record.description,
        'table', row_to_json(v_table_record),
        'type', 'object',
        'properties', v_properties,
        'required', v_required_fields,
        'children', v_children,
        'additionalProperties', false
    );
    
    RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION public.build_schema_for_table IS
'Builds a schema JSON for a single table. Self-gating: applies the view_permission check with existence-hiding (raises the same undefined_table error for a missing table and for a permission-denied table), matching get_schema(). Used by get_schema()/get_schemas()/get_module_cubes()/get_user_cubes() for consistent output from a single implementation.';

-- Revoke default PUBLIC execute, then grant only to semantius_user
REVOKE EXECUTE ON FUNCTION public.build_schema_for_table(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.build_schema_for_table(TEXT) TO semantius_user;

-- =====================================================
-- GET SCHEMA
-- =====================================================

-- Get schema information for a table in extended JSON Schema format
-- Returns JSON Schema with table metadata and properties
-- Raises an error when the table is not found
CREATE OR REPLACE FUNCTION public.get_schema(p_table_name TEXT)
RETURNS JSON AS $$
DECLARE
    v_table_record RECORD;
    v_cache_version TEXT;
    v_db_version    TEXT;
BEGIN
    PERFORM rbac.uid();

    -- Check if table exists in entities metadata
    SELECT * INTO v_table_record
    FROM entities
    WHERE table_name = p_table_name;

    -- Raise error if table not found
    IF NOT FOUND THEN
        SELECT value INTO v_cache_version FROM _settings WHERE name = 'cache_version';
        SELECT value INTO v_db_version    FROM _settings WHERE name = 'db_version';
        RAISE EXCEPTION 'Table "%" not found in entities', p_table_name
            USING ERRCODE = 'undefined_table',
                  DETAIL = json_build_object('cache_current', v_cache_version IS NOT NULL AND v_db_version IS NOT NULL AND v_cache_version >= v_db_version)::text;
    END IF;

    -- Check if user has view permission for this table
    -- Raise same error to avoid leaking table existence
    IF NOT rbac.has_permission(v_table_record.view_permission) THEN
        SELECT value INTO v_cache_version FROM _settings WHERE name = 'cache_version';
        SELECT value INTO v_db_version    FROM _settings WHERE name = 'db_version';
        RAISE EXCEPTION 'Table "%" not found in tables metadata', p_table_name
            USING ERRCODE = 'undefined_table',
                  DETAIL = json_build_object('cache_current', v_cache_version IS NOT NULL AND v_db_version IS NOT NULL AND v_cache_version >= v_db_version)::text;
    END IF;

    RETURN public.build_schema_for_table(p_table_name);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION public.get_schema IS 
'Returns table schema in extended JSON Schema format with table metadata in a table object and fields as properties. Raises an error if table not found.';

-- Revoke default PUBLIC execute, then grant only to semantius_user
REVOKE EXECUTE ON FUNCTION public.get_schema(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_schema(TEXT) TO semantius_user;

-- =====================================================
-- GET SCHEMAS
-- =====================================================

-- Get schemas for multiple tables in extended JSON Schema format
-- Accepts a comma-separated list of table names
-- Returns a JSON array of schemas, one per table
-- Each schema uses the same format as get_schema()
-- Raises an error if any table is not found or the user lacks view permission
-- (same error behaviour as get_schema() — use the same error code to avoid
--  leaking information about table existence)
CREATE OR REPLACE FUNCTION public.get_schemas(p_table_names TEXT)
RETURNS JSON AS $$
DECLARE
    v_table_name TEXT;
    v_table_record RECORD;
    v_schemas JSON[] := '{}';
    v_schema JSON;
BEGIN
    PERFORM rbac.uid();

    FOREACH v_table_name IN ARRAY string_to_array(p_table_names, ',')
    LOOP
        v_table_name := trim(v_table_name);
        -- Skip blank entries that result from leading/trailing commas or spaces
        IF v_table_name = '' THEN
            CONTINUE;
        END IF;

        -- Raise error if table not found in entities metadata
        SELECT * INTO v_table_record
        FROM entities
        WHERE table_name = v_table_name;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Table "%" not found in entities', v_table_name
                USING ERRCODE = 'undefined_table';
        END IF;

        -- Raise same error when user lacks view permission (avoid leaking table existence)
        IF NOT rbac.has_permission(v_table_record.view_permission) THEN
            RAISE EXCEPTION 'Table "%" not found in tables metadata', v_table_name
                USING ERRCODE = 'undefined_table';
        END IF;

        v_schema := public.build_schema_for_table(v_table_name);
        v_schemas := array_append(v_schemas, v_schema);
    END LOOP;

    RETURN array_to_json(v_schemas);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION public.get_schemas IS 
'Returns an array of table schemas in extended JSON Schema format for the given comma-separated list of table names. Raises an error (undefined_table) if any table is not found or the current user lacks view permission, matching the error behaviour of get_schema(). Delegates per-table schema building to build_schema_for_table().';

-- Revoke default PUBLIC execute, then grant only to semantius_user
REVOKE EXECUTE ON FUNCTION public.get_schemas(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_schemas(TEXT) TO semantius_user;

-- =====================================================
-- PING
-- =====================================================

CREATE OR REPLACE FUNCTION public.ping()
RETURNS TABLE(
    server_time TIMESTAMPTZ,
    current_user_name TEXT,
    current_role_name TEXT,
    session_user_name TEXT
) AS $$
BEGIN
    RETURN QUERY SELECT 
        NOW() as server_time,
        current_user::TEXT as current_user_name,
        current_role::TEXT as current_role_name,
        session_user::TEXT as session_user_name;
END;
$$ LANGUAGE plpgsql SET search_path = public;

COMMENT ON FUNCTION public.ping IS 
'Returns the current server timestamp and user information as a table. Useful for testing connectivity and server time.';

-- Revoke default PUBLIC execute, then grant only to semantius_user
REVOKE EXECUTE ON FUNCTION public.ping() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.ping() TO semantius_user;



-- =====================================================
-- HAS PUBLIC READ
-- =====================================================

-- Function that returns comprehensive user access information
-- Returns JSON with current user's role, role membership, and permission status
CREATE OR REPLACE FUNCTION public.has_public_read()
RETURNS JSONB AS $$
DECLARE
    v_current_role TEXT;
    v_is_semantius_user BOOLEAN := FALSE;
    v_has_public_read BOOLEAN := FALSE;
BEGIN
    PERFORM rbac.uid();

    -- Get the current PostgreSQL role
    v_current_role := current_user;
    
    -- Check if current user is a member of semantius_user role
    -- Using pg_has_role to check role membership
    BEGIN
        v_is_semantius_user := pg_has_role(current_user, 'semantius_user', 'member');
    EXCEPTION WHEN OTHERS THEN
        -- If role doesn't exist or any other error, default to false
        v_is_semantius_user := FALSE;
    END;
    
    -- Check if user has public:read permission via RBAC system
    BEGIN
        v_has_public_read := rbac.has_permission('public:read'::text);
    EXCEPTION WHEN OTHERS THEN
        -- If RBAC system fails, default to false
        v_has_public_read := FALSE;
    END;
    
    -- Return all information as JSON
    RETURN jsonb_build_object(
        'current_role', v_current_role,
        'is_member_of_semantius_user', v_is_semantius_user,
        'has_public_read_permission', v_has_public_read
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION public.has_public_read IS 
'Returns current user access information: PostgreSQL role, semantius_user membership, and public:read permission status.';

-- Revoke default PUBLIC execute, then grant only to semantius_user
REVOKE EXECUTE ON FUNCTION public.has_public_read() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.has_public_read() TO semantius_user;

-- =====================================================
-- HAS PERMISSION (public RPC wrapper)
-- =====================================================

-- Thin public-schema wrapper over rbac.has_permission() so the permission
-- check is reachable as a PostgREST RPC (POST /rpc/has_permission with body
-- {"p_permission_name": "..."}). The rbac schema itself is not exposed by
-- PostgREST, so callers cannot invoke rbac.has_permission() directly.
--
-- Companion RACI operators is_raci_actor(text,text,text) and
-- has_consultation(text,text,text) are already public-schema functions
-- granted to semantius_user (see 0210_raci.sql), so they are already
-- reachable as /rpc/is_raci_actor and /rpc/has_consultation. Only
-- has_permission needed a public wrapper.
--
-- Returns TRUE when the current authenticated user holds the named
-- permission; FALSE otherwise. Never throws for a missing permission
-- (mirrors rbac.has_permission semantics); rbac.uid() still enforces that
-- a valid JWT context is present.
CREATE OR REPLACE FUNCTION public.has_permission(p_permission_name TEXT)
RETURNS BOOLEAN AS $$
BEGIN
    PERFORM rbac.uid();
    RETURN rbac.has_permission(p_permission_name);
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION public.has_permission IS
'Public RPC wrapper over rbac.has_permission(). Returns TRUE when the current authenticated user holds the named permission. Exposed in the public schema so PostgREST can serve it as /rpc/has_permission, since the rbac schema is not exposed.';

-- Revoke default PUBLIC execute, then grant only to semantius_user
REVOKE EXECUTE ON FUNCTION public.has_permission(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.has_permission(TEXT) TO semantius_user;

-- =====================================================
-- GET MODULE CUBE
-- =====================================================

-- Returns schemas for all entities that form the "cube" for a given module:
--   1. All entities that directly belong to the module.
--   2. All entities referenced via the reference_table field of any field
--      that belongs to one of those module entities.
-- Entities are sorted alphabetically and deduplicated. Tables the current user
-- lacks view permission for are silently skipped.
-- Returns a JSON array of schemas in the same format as get_schema().
-- The p_module_name parameter is matched against modules.module_slug (URL-safe
-- identifier), not modules.module_name. The parameter name is preserved for
-- PostgREST RPC wire compatibility.
CREATE OR REPLACE FUNCTION public.get_module_cubes(p_module_name TEXT)
RETURNS SETOF JSON AS $$
DECLARE
    v_table_name TEXT;
    v_table_record RECORD;
    v_schema JSON;
BEGIN
    PERFORM rbac.uid();

    FOR v_table_name IN
        SELECT DISTINCT name
        FROM (
            -- All entities belonging to the module
            SELECT e.table_name AS name
            FROM entities e
            JOIN modules m ON m.id = e.module_id
            WHERE m.module_slug = p_module_name

            UNION

            -- All entities referenced via reference_table from fields of module entities
            SELECT f.reference_table AS name
            FROM fields f
            JOIN entities e ON e.table_name = f.table_name
            JOIN modules m ON m.id = e.module_id
            WHERE m.module_slug = p_module_name
              AND f.reference_table != ''
        ) AS names
        ORDER BY name
    LOOP
        -- Check if the table exists and the user has view permission; skip otherwise
        SELECT * INTO v_table_record
        FROM entities
        WHERE table_name = v_table_name;

        IF FOUND AND rbac.has_permission(v_table_record.view_permission) THEN
            v_schema := public.build_schema_for_table(v_table_name);
            IF v_schema IS NOT NULL THEN
                RETURN NEXT v_schema;
            END IF;
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION public.get_module_cubes IS
'Returns a JSON array of schemas (same format as get_schema()) for the distinct set of entities that form the logical cube for a given module: all entities belonging to the module plus all entities referenced via reference_table from fields of those entities. The p_module_name parameter is matched against modules.module_slug (URL-safe identifier), not modules.module_name; the parameter name is preserved for PostgREST RPC wire compatibility. Tables the current user lacks view permission for are silently skipped.';

-- Revoke default PUBLIC execute, then grant only to semantius_user
REVOKE EXECUTE ON FUNCTION public.get_module_cubes(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_module_cubes(TEXT) TO semantius_user;

-- =====================================================
-- GET USER CUBES
-- =====================================================

-- Returns schemas for all entities across all modules that the current user
-- has view permission for. Referenced tables are not additionally included —
-- they will already appear when the user has view permission on them directly.
-- Returns a JSON array of schemas in the same format as get_schema().
CREATE OR REPLACE FUNCTION public.get_user_cubes()
RETURNS SETOF JSON AS $$
DECLARE
    v_table_record RECORD;
    v_schema JSON;
BEGIN
    PERFORM rbac.uid();

    FOR v_table_record IN
        SELECT *
        FROM entities
        ORDER BY table_name
    LOOP
        IF rbac.has_permission(v_table_record.view_permission) THEN
            v_schema := public.build_schema_for_table(v_table_record.table_name);
            IF v_schema IS NOT NULL THEN
                RETURN NEXT v_schema;
            END IF;
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION public.get_user_cubes IS
'Returns a JSON array of schemas (same format as get_schema()) for all entities that the current user has view permission for, across all modules.';

-- Revoke default PUBLIC execute, then grant only to semantius_user
REVOKE EXECUTE ON FUNCTION public.get_user_cubes() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_user_cubes() TO semantius_user;
