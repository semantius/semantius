/**
 * Auto-generated SQL migrations bundle for @semantius/triggerdev.
 * DO NOT EDIT MANUALLY - regenerate with: deno task bundle-sql
 *
 * Generated: 2026-05-19T18:59:18.290Z
 * Apps: 3  |  Migrations: 24
 */

export interface MigrationFile {
  name: string;
  content: string;
}

/** Returns the bundled migrations for a given app name, sorted by filename. */
export function getBundledMigrations(appName: string): MigrationFile[] {
  const appMigrations = MIGRATIONS_BUNDLE[appName];
  if (!appMigrations) return [];
  return Object.entries(appMigrations)
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([name, content]) => ({ name, content }));
}

/** Returns all app names that have bundled migrations. */
export function getBundledAppNames(): string[] {
  return Object.keys(MIGRATIONS_BUNDLE).sort();
}

const MIGRATIONS_BUNDLE: Record<string, Record<string, string>> = {
  "_core": {
    "0010_create_core": `-- =====================================================
-- COMMON SCHEMA - Reusable Database Functions
-- =====================================================

-- Enable pgcrypto for gen_random_bytes()
CREATE EXTENSION IF NOT EXISTS pgcrypto;


-- Ensure the authenticated role exists (create it if missing)
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'authenticated') THEN
        CREATE ROLE authenticated NOLOGIN;
        RAISE NOTICE 'Role authenticated created';
    END IF;
END
$$;


-- ======================================================================================================================
-- COMMON SCHEMA - neondb_owner cannot switch to authenticated, add a new role semantius_user inheriting authenticated
-- ======================================================================================================================

DO $$
BEGIN
    -- Check if semantius_user role is missing
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'semantius_user') THEN
        
        CREATE ROLE semantius_user INHERIT NOLOGIN;
        
            -- Grant authenticated to semantius_user
            GRANT semantius_user TO authenticated;

            -- Grant semantius_user to current user
            EXECUTE format('GRANT semantius_user TO %I', current_user);
        
        RAISE NOTICE 'Role semantius_user created with INHERIT and granted authenticated role';
    END IF;
END $$;


-- =====================================================
-- SECURE DEFAULTS: Revoke PUBLIC execute on all future functions
-- =====================================================
-- PostgreSQL grants EXECUTE to PUBLIC by default on all functions.
-- This changes the default so new functions are NOT callable by PUBLIC,
-- preventing accidental privilege escalation via SECURITY DEFINER functions.
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

-- Create the common schema
CREATE SCHEMA IF NOT EXISTS common;

ALTER DEFAULT PRIVILEGES IN SCHEMA common
    REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

COMMENT ON SCHEMA common IS 'Shared database objects and functions used across multiple schemas';

-- Function to automatically update updated_at timestamp
CREATE OR REPLACE FUNCTION common.update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SET search_path = common;

COMMENT ON FUNCTION common.update_updated_at_column() IS 'Trigger function to automatically update updated_at column on row modification';

-- =====================================================
-- _SETTINGS TABLE
-- =====================================================
-- Stores system-level configuration key/value pairs.
-- RLS is enabled with an explicit deny-all policy so that
-- the table is never exposed through PostgREST / the Data API.
-- SECURITY DEFINER functions (e.g. rbac.uid(), common.refresh_schema_cache())
-- can still read and write it because they run as the function owner
-- who has BYPASSRLS privilege.

CREATE TABLE _settings (
    name  TEXT PRIMARY KEY,
    value TEXT NOT NULL DEFAULT ''
);

ALTER TABLE _settings ENABLE ROW LEVEL SECURITY;

CREATE POLICY settings_deny_all ON _settings
    FOR ALL
    TO semantius_user
    USING (false)
    WITH CHECK (false);
`,
    "0012_create_cache": `-- Create generic cache table for storing key-value pairs with expiration
-- This eliminates the need for Redis and provides persistent caching across all function instances
-- RLS is enabled without policies to prevent access via Data API, only direct SQL functions
-- UNLOGGED table for better performance (truncated on crash, not replicated)


CREATE UNLOGGED TABLE IF NOT EXISTS common._cache (
    id BIGSERIAL PRIMARY KEY,
    key TEXT NOT NULL UNIQUE,
    value TEXT NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Create index on key for fast lookups
CREATE INDEX IF NOT EXISTS idx_cache_key ON common._cache(key);

-- Create index on expires_at for efficient cleanup of expired entries
CREATE INDEX IF NOT EXISTS idx_cache_expires ON common._cache(expires_at);

-- Enable Row Level Security (RLS) without policies
-- This prevents access via Data API, only direct SQL functions can access
ALTER TABLE common._cache ENABLE ROW LEVEL SECURITY;

-- Function to get cached value (returns NULL if expired or not found)
CREATE OR REPLACE FUNCTION common.cache_get(ckey TEXT)
RETURNS TEXT AS $$
BEGIN
    RETURN (
        SELECT _cache.value 
        FROM common._cache 
        WHERE _cache.key = ckey 
          AND _cache.expires_at >= NOW()
        LIMIT 1
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = common;

-- Function to set cached value with expiration in minutes
CREATE OR REPLACE FUNCTION common.cache_set(ckey TEXT, cvalue TEXT, expires_minutes INTEGER)
RETURNS VOID AS $$
BEGIN
    INSERT INTO common._cache (key, value, expires_at, updated_at)
    VALUES (ckey, cvalue, NOW() + (expires_minutes || ' minutes')::INTERVAL, NOW())
    ON CONFLICT (key)
    DO UPDATE SET
        value = EXCLUDED.value,
        expires_at = EXCLUDED.expires_at,
        updated_at = NOW();
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = common;

-- Function to delete a cached value
CREATE OR REPLACE FUNCTION common.cache_delete(ckey TEXT)
RETURNS BOOLEAN AS $$
DECLARE
    deleted_count INTEGER;
BEGIN
    DELETE FROM common._cache WHERE _cache.key = ckey;
    GET DIAGNOSTICS deleted_count = ROW_COUNT;
    RETURN deleted_count > 0;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = common;

-- Function to clean up expired entries (returns count of deleted entries)
CREATE OR REPLACE FUNCTION common.cache_cleanup()
RETURNS INTEGER AS $$
DECLARE
    deleted_count INTEGER;
BEGIN
    DELETE FROM common._cache WHERE expires_at < NOW();
    GET DIAGNOSTICS deleted_count = ROW_COUNT;
    RETURN deleted_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = common;

-- Function to get cache statistics
CREATE OR REPLACE FUNCTION common.cache_stats()
RETURNS TABLE(
    total_entries BIGINT,
    expired_entries BIGINT,
    active_entries BIGINT,
    oldest_entry TIMESTAMPTZ,
    newest_entry TIMESTAMPTZ
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        COUNT(*)::BIGINT as total_entries,
        COUNT(*) FILTER (WHERE expires_at < NOW())::BIGINT as expired_entries,
        COUNT(*) FILTER (WHERE expires_at >= NOW())::BIGINT as active_entries,
        MIN(created_at) as oldest_entry,
        MAX(created_at) as newest_entry
    FROM common._cache;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = common;

-- Grant schema usage to current user (database owner) for testing
GRANT USAGE ON SCHEMA common TO CURRENT_USER;

-- Do NOT grant execute permissions to semantius_user role
-- This prevents access via PostgREST /rpc/ endpoints
-- Functions use SECURITY DEFINER so they can access the table directly
-- Only direct database connections can execute these functions

-- Add comments explaining the table and functions
COMMENT ON TABLE common._cache IS 'Generic cache table for storing key-value pairs with expiration. RLS enabled without policies to prevent Data API access.';
COMMENT ON COLUMN common._cache.key IS 'Unique cache key identifier';
COMMENT ON COLUMN common._cache.value IS 'Cached value (stored as text, can be JSON)';
COMMENT ON COLUMN common._cache.expires_at IS 'When this cache entry expires';

COMMENT ON FUNCTION common.cache_get(TEXT) IS 'Get cached value by key, returns NULL if expired or not found';
COMMENT ON FUNCTION common.cache_set(TEXT, TEXT, INTEGER) IS 'Set cached value with expiration in minutes';
COMMENT ON FUNCTION common.cache_delete(TEXT) IS 'Delete cached value by key, returns true if deleted';
COMMENT ON FUNCTION common.cache_cleanup() IS 'Clean up expired cache entries, returns count of deleted entries';
COMMENT ON FUNCTION common.cache_stats() IS 'Get cache statistics including total, expired, and active entries';`,
    "0015_jsonlogic": `-- Helper: JsonLogic truthy semantics
-- false, null, 0, "" and empty arrays are falsy; everything else is truthy
CREATE OR REPLACE FUNCTION jl_truthy(val jsonb) RETURNS boolean AS $$
BEGIN
    IF val IS NULL THEN RETURN false; END IF;
    CASE jsonb_typeof(val)
        WHEN 'boolean' THEN RETURN val::text = 'true';
        WHEN 'null'    THEN RETURN false;
        WHEN 'number'  THEN RETURN val::text::numeric <> 0;
        WHEN 'string'  THEN RETURN val #>> '{}' <> '';
        WHEN 'array'   THEN RETURN jsonb_array_length(val) > 0;
        ELSE RETURN true; -- objects are truthy
    END CASE;
END;
$$ LANGUAGE plpgsql IMMUTABLE SET search_path = public;

-- Helper: coerce jsonb value to numeric (for arithmetic / comparisons)
CREATE OR REPLACE FUNCTION jl_to_number(val jsonb) RETURNS numeric AS $$
DECLARE
    txt_val text;
BEGIN
    IF val IS NULL THEN RETURN 0; END IF;

    CASE jsonb_typeof(val)
        WHEN 'number' THEN
            RETURN val::text::numeric;

        WHEN 'string' THEN
            txt_val := val #>> '{}';

            -- First try numeric coercion to preserve original JsonLogic behavior.
            BEGIN
                RETURN txt_val::numeric;
            EXCEPTION WHEN invalid_text_representation THEN
                NULL;
            END;

            -- Then try timestamp/date coercion for ISO-like date strings.
            BEGIN
                RETURN extract(epoch FROM txt_val::timestamp)::numeric;
            EXCEPTION WHEN invalid_text_representation OR datetime_field_overflow THEN
                RETURN 0;
            END;

        WHEN 'boolean' THEN RETURN CASE WHEN val::text = 'true' THEN 1 ELSE 0 END;
        WHEN 'null' THEN RETURN 0;
        ELSE RETURN 0;
    END CASE;
END;
$$ LANGUAGE plpgsql IMMUTABLE SET search_path = public;

-- Helper: coerce jsonb value to text (for cat, substr, in-string)
CREATE OR REPLACE FUNCTION jl_to_text(val jsonb) RETURNS text AS $$
BEGIN
    IF val IS NULL THEN RETURN ''; END IF;
    CASE jsonb_typeof(val)
        WHEN 'string' THEN RETURN val #>> '{}';
        WHEN 'null'   THEN RETURN '';
        ELSE RETURN val::text;
    END CASE;
END;
$$ LANGUAGE plpgsql IMMUTABLE SET search_path = public;

-- Helper: loose equality (==) mimicking JS type coercion
-- Numbers are compared as numbers; if either side is a number and the other a string, coerce string to number.
CREATE OR REPLACE FUNCTION jl_loose_eq(a jsonb, b jsonb) RETURNS boolean AS $$
DECLARE
    ta text; tb text;
BEGIN
    IF a IS NULL AND b IS NULL THEN RETURN true; END IF;
    IF a IS NULL OR b IS NULL THEN RETURN false; END IF;
    ta := jsonb_typeof(a);
    tb := jsonb_typeof(b);
    -- Same type: direct comparison
    IF ta = tb THEN RETURN a = b; END IF;
    -- null == null only (already handled), null != anything else
    IF ta = 'null' OR tb = 'null' THEN RETURN false; END IF;
    -- number vs string: coerce string to number
    IF (ta = 'number' AND tb = 'string') OR (ta = 'string' AND tb = 'number') THEN
        RETURN jl_to_number(a) = jl_to_number(b);
    END IF;
    -- boolean vs other: coerce boolean to number then compare
    IF ta = 'boolean' OR tb = 'boolean' THEN
        RETURN jl_to_number(a) = jl_to_number(b);
    END IF;
    RETURN a = b;
END;
$$ LANGUAGE plpgsql IMMUTABLE SET search_path = public;

CREATE OR REPLACE FUNCTION evaluate_json_logic(rule jsonb, data jsonb)
RETURNS jsonb AS $$
DECLARE
    op text;
    vals jsonb;
    arr_len int;
    i int;
    current_val jsonb;
    a jsonb; b jsonb; c jsonb;
    num_a numeric; num_b numeric; num_c numeric;
    result jsonb;
    scoped_data jsonb;
    scoped_logic jsonb;
    initial_val jsonb;
    -- for var
    var_key text;
    sub_props text[];
    nav jsonb;
    -- for missing
    missing_arr jsonb;
    keys_arr jsonb;
    key_val text;
    looked_up jsonb;
    -- for merge
    merge_result jsonb;
    elem jsonb;
    j int;
    -- for substr
    src text;
    start_pos int;
    end_len int;
    temp_str text;
    -- for text ops
    txt_a text; txt_b text;
BEGIN
    -- Handle NULL rule
    IF rule IS NULL THEN RETURN 'null'::jsonb; END IF;

    -- Arrays with possible logic inside: recursively evaluate each element
    IF jsonb_typeof(rule) = 'array' THEN
        result := '[]'::jsonb;
        FOR i IN 0 .. jsonb_array_length(rule) - 1 LOOP
            result := result || jsonb_build_array(evaluate_json_logic(rule -> i, data));
        END LOOP;
        RETURN result;
    END IF;

    -- Not an object or multi-key object => pass through (primitive)
    IF jsonb_typeof(rule) <> 'object' THEN RETURN rule; END IF;
    -- Must have exactly one key to be logic
    SELECT key INTO op FROM jsonb_object_keys(rule) AS key LIMIT 1;
    IF (SELECT count(*) FROM jsonb_object_keys(rule)) <> 1 THEN RETURN rule; END IF;

    vals := rule -> op;
    -- Normalize: if vals is not an array, wrap it
    IF jsonb_typeof(vals) <> 'array' THEN
        vals := jsonb_build_array(vals);
    END IF;
    arr_len := jsonb_array_length(vals);

    -- ===================== if / ?: =====================
    IF op = 'if' OR op = '?:' THEN
        i := 0;
        WHILE i < arr_len - 1 LOOP
            IF jl_truthy(evaluate_json_logic(vals -> i, data)) THEN
                RETURN evaluate_json_logic(vals -> (i + 1), data);
            END IF;
            i := i + 2;
        END LOOP;
        -- Remaining single element = else clause
        IF arr_len = i + 1 THEN
            RETURN evaluate_json_logic(vals -> i, data);
        END IF;
        RETURN 'null'::jsonb;
    END IF;

    -- ===================== and =====================
    IF op = 'and' THEN
        current_val := 'null'::jsonb;
        FOR i IN 0 .. arr_len - 1 LOOP
            current_val := evaluate_json_logic(vals -> i, data);
            IF NOT jl_truthy(current_val) THEN
                RETURN current_val;
            END IF;
        END LOOP;
        RETURN current_val;
    END IF;

    -- ===================== or =====================
    IF op = 'or' THEN
        current_val := 'null'::jsonb;
        FOR i IN 0 .. arr_len - 1 LOOP
            current_val := evaluate_json_logic(vals -> i, data);
            IF jl_truthy(current_val) THEN
                RETURN current_val;
            END IF;
        END LOOP;
        RETURN current_val;
    END IF;

    -- ===================== filter =====================
    IF op = 'filter' THEN
        scoped_data := evaluate_json_logic(vals -> 0, data);
        scoped_logic := vals -> 1;
        IF jsonb_typeof(scoped_data) <> 'array' THEN
            RETURN '[]'::jsonb;
        END IF;
        result := '[]'::jsonb;
        FOR i IN 0 .. jsonb_array_length(scoped_data) - 1 LOOP
            IF jl_truthy(evaluate_json_logic(scoped_logic, scoped_data -> i)) THEN
                result := result || jsonb_build_array(scoped_data -> i);
            END IF;
        END LOOP;
        RETURN result;
    END IF;

    -- ===================== map =====================
    IF op = 'map' THEN
        scoped_data := evaluate_json_logic(vals -> 0, data);
        scoped_logic := vals -> 1;
        IF jsonb_typeof(scoped_data) <> 'array' THEN
            RETURN '[]'::jsonb;
        END IF;
        result := '[]'::jsonb;
        FOR i IN 0 .. jsonb_array_length(scoped_data) - 1 LOOP
            result := result || jsonb_build_array(evaluate_json_logic(scoped_logic, scoped_data -> i));
        END LOOP;
        RETURN result;
    END IF;

    -- ===================== reduce =====================
    IF op = 'reduce' THEN
        scoped_data := evaluate_json_logic(vals -> 0, data);
        scoped_logic := vals -> 1;
        IF arr_len >= 3 THEN
            initial_val := evaluate_json_logic(vals -> 2, data);
        ELSE
            initial_val := 'null'::jsonb;
        END IF;
        IF jsonb_typeof(scoped_data) <> 'array' THEN
            RETURN initial_val;
        END IF;
        current_val := initial_val;
        FOR i IN 0 .. jsonb_array_length(scoped_data) - 1 LOOP
            current_val := evaluate_json_logic(
                scoped_logic,
                jsonb_build_object('current', scoped_data -> i, 'accumulator', current_val)
            );
        END LOOP;
        RETURN current_val;
    END IF;

    -- ===================== all =====================
    IF op = 'all' THEN
        scoped_data := evaluate_json_logic(vals -> 0, data);
        scoped_logic := vals -> 1;
        IF jsonb_typeof(scoped_data) <> 'array' OR jsonb_array_length(scoped_data) = 0 THEN
            RETURN 'false'::jsonb;
        END IF;
        FOR i IN 0 .. jsonb_array_length(scoped_data) - 1 LOOP
            IF NOT jl_truthy(evaluate_json_logic(scoped_logic, scoped_data -> i)) THEN
                RETURN 'false'::jsonb;
            END IF;
        END LOOP;
        RETURN 'true'::jsonb;
    END IF;

    -- ===================== none =====================
    IF op = 'none' THEN
        scoped_data := evaluate_json_logic(vals -> 0, data);
        scoped_logic := vals -> 1;
        IF jsonb_typeof(scoped_data) <> 'array' OR jsonb_array_length(scoped_data) = 0 THEN
            RETURN 'true'::jsonb;
        END IF;
        FOR i IN 0 .. jsonb_array_length(scoped_data) - 1 LOOP
            IF jl_truthy(evaluate_json_logic(scoped_logic, scoped_data -> i)) THEN
                RETURN 'false'::jsonb;
            END IF;
        END LOOP;
        RETURN 'true'::jsonb;
    END IF;

    -- ===================== some =====================
    IF op = 'some' THEN
        scoped_data := evaluate_json_logic(vals -> 0, data);
        scoped_logic := vals -> 1;
        IF jsonb_typeof(scoped_data) <> 'array' OR jsonb_array_length(scoped_data) = 0 THEN
            RETURN 'false'::jsonb;
        END IF;
        FOR i IN 0 .. jsonb_array_length(scoped_data) - 1 LOOP
            IF jl_truthy(evaluate_json_logic(scoped_logic, scoped_data -> i)) THEN
                RETURN 'true'::jsonb;
            END IF;
        END LOOP;
        RETURN 'false'::jsonb;
    END IF;

    -- ===================== let =====================
    -- Binds a named variable into data and evaluates a logic expression.
    -- Usage: {"let":["name", value, logic]}
    IF op = 'let' THEN
        var_key := vals ->> 0;
        result := evaluate_json_logic(vals -> 1, data);
        RETURN evaluate_json_logic(vals -> 2, data || jsonb_build_object(var_key, result));
    END IF;

    -- ===================== set_record =====================
    -- Loads an entity record by id and stores it in data under the given name.
    -- Usage: {"set_record":["varName", "entityName", idExpression, logic]}
    -- Calls get_record_by_id(entityName, id) and stores the result like let.
    IF op = 'set_record' THEN
        var_key := vals ->> 0;
        txt_a := vals ->> 1;
        result := evaluate_json_logic(vals -> 2, data);
        nav := get_record_by_id(txt_a, jl_to_number(result)::integer);
        RETURN evaluate_json_logic(vals -> 3, data || jsonb_build_object(var_key, COALESCE(nav, 'null'::jsonb)));
    END IF;

    -- =====================================================
    -- All remaining operators: depth-first evaluate arguments
    -- =====================================================
    -- Evaluate all arguments first
    result := '[]'::jsonb;
    FOR i IN 0 .. arr_len - 1 LOOP
        result := result || jsonb_build_array(evaluate_json_logic(vals -> i, data));
    END LOOP;
    vals := result;
    arr_len := jsonb_array_length(vals);

    -- Get convenience references
    a := vals -> 0;
    IF arr_len > 1 THEN b := vals -> 1; ELSE b := NULL; END IF;
    IF arr_len > 2 THEN c := vals -> 2; ELSE c := NULL; END IF;

    -- ===================== var =====================
    IF op = 'var' THEN
        -- a = the key/path, b = default value
        -- If a is undefined/null/empty string, return data itself
        IF a IS NULL OR jsonb_typeof(a) = 'null' OR (jsonb_typeof(a) = 'string' AND a #>> '{}' = '') THEN
            RETURN data;
        END IF;
        var_key := jl_to_text(a);
        sub_props := string_to_array(var_key, '.');
        nav := data;
        FOR i IN 1 .. array_length(sub_props, 1) LOOP
            IF nav IS NULL OR jsonb_typeof(nav) = 'null' THEN
                -- not found, return default
                IF b IS NOT NULL THEN RETURN b; ELSE RETURN 'null'::jsonb; END IF;
            END IF;
            -- Try object key or array index
            IF jsonb_typeof(nav) = 'array' THEN
                BEGIN
                    nav := nav -> sub_props[i]::int;
                EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN
                    IF b IS NOT NULL THEN RETURN b; ELSE RETURN 'null'::jsonb; END IF;
                END;
            ELSE
                nav := nav -> sub_props[i];
            END IF;
            IF nav IS NULL THEN
                IF b IS NOT NULL THEN RETURN b; ELSE RETURN 'null'::jsonb; END IF;
            END IF;
        END LOOP;
        RETURN nav;
    END IF;

    -- ===================== missing =====================
    IF op = 'missing' THEN
        -- Arguments can be individual keys or a single array of keys
        IF arr_len = 1 AND jsonb_typeof(a) = 'array' THEN
            keys_arr := a;
        ELSE
            keys_arr := vals;
        END IF;
        missing_arr := '[]'::jsonb;
        FOR i IN 0 .. jsonb_array_length(keys_arr) - 1 LOOP
            key_val := keys_arr ->> i;
            looked_up := evaluate_json_logic(jsonb_build_object('var', keys_arr -> i), data);
            IF jsonb_typeof(looked_up) = 'null' OR (jsonb_typeof(looked_up) = 'string' AND looked_up #>> '{}' = '') THEN
                missing_arr := missing_arr || jsonb_build_array(keys_arr -> i);
            END IF;
        END LOOP;
        RETURN missing_arr;
    END IF;

    -- ===================== missing_some =====================
    IF op = 'missing_some' THEN
        -- a = need_count, b = array of keys
        num_a := jl_to_number(a);
        -- Compute missing using the missing operator
        missing_arr := evaluate_json_logic(jsonb_build_object('missing', b), data);
        IF jsonb_array_length(b) - jsonb_array_length(missing_arr) >= num_a THEN
            RETURN '[]'::jsonb;
        ELSE
            RETURN missing_arr;
        END IF;
    END IF;

    -- ===================== == =====================
    IF op = '==' THEN
        RETURN to_jsonb(jl_loose_eq(a, b));
    END IF;

    -- ===================== === =====================
    IF op = '===' THEN
        -- Strict equality: types must match
        IF jsonb_typeof(a) <> jsonb_typeof(b) THEN RETURN 'false'::jsonb; END IF;
        RETURN to_jsonb(a = b);
    END IF;

    -- ===================== != =====================
    IF op = '!=' THEN
        RETURN to_jsonb(NOT jl_loose_eq(a, b));
    END IF;

    -- ===================== !== =====================
    IF op = '!==' THEN
        IF jsonb_typeof(a) <> jsonb_typeof(b) THEN RETURN 'true'::jsonb; END IF;
        RETURN to_jsonb(a <> b);
    END IF;

    -- ===================== ! =====================
    IF op = '!' THEN
        RETURN to_jsonb(NOT jl_truthy(a));
    END IF;

    -- ===================== !! =====================
    IF op = '!!' THEN
        RETURN to_jsonb(jl_truthy(a));
    END IF;

    -- ===================== > =====================
    IF op = '>' THEN
        num_a := jl_to_number(a);
        num_b := jl_to_number(b);
        RETURN to_jsonb(num_a > num_b);
    END IF;

    -- ===================== >= =====================
    IF op = '>=' THEN
        num_a := jl_to_number(a);
        num_b := jl_to_number(b);
        RETURN to_jsonb(num_a >= num_b);
    END IF;

    -- ===================== < =====================
    IF op = '<' THEN
        num_a := jl_to_number(a);
        num_b := jl_to_number(b);
        IF c IS NULL THEN
            RETURN to_jsonb(num_a < num_b);
        ELSE
            num_c := jl_to_number(c);
            RETURN to_jsonb(num_a < num_b AND num_b < num_c);
        END IF;
    END IF;

    -- ===================== <= =====================
    IF op = '<=' THEN
        num_a := jl_to_number(a);
        num_b := jl_to_number(b);
        IF c IS NULL THEN
            RETURN to_jsonb(num_a <= num_b);
        ELSE
            num_c := jl_to_number(c);
            RETURN to_jsonb(num_a <= num_b AND num_b <= num_c);
        END IF;
    END IF;

    -- ===================== % =====================
    IF op = '%' THEN
        RETURN to_jsonb(jl_to_number(a) % jl_to_number(b));
    END IF;

    -- ===================== + =====================
    IF op = '+' THEN
        num_a := 0;
        FOR i IN 0 .. arr_len - 1 LOOP
            num_a := num_a + jl_to_number(vals -> i);
        END LOOP;
        -- Return integer if result is integer
        IF num_a = trunc(num_a) THEN
            RETURN to_jsonb(num_a::bigint);
        ELSE
            RETURN to_jsonb(num_a);
        END IF;
    END IF;

    -- ===================== * =====================
    IF op = '*' THEN
        num_a := jl_to_number(vals -> 0);
        FOR i IN 1 .. arr_len - 1 LOOP
            num_a := num_a * jl_to_number(vals -> i);
        END LOOP;
        IF num_a = trunc(num_a) THEN
            RETURN to_jsonb(num_a::bigint);
        ELSE
            RETURN to_jsonb(num_a);
        END IF;
    END IF;

    -- ===================== - =====================
    IF op = '-' THEN
        IF arr_len = 1 THEN
            num_a := -jl_to_number(a);
        ELSE
            num_a := jl_to_number(a) - jl_to_number(b);
        END IF;
        IF num_a = trunc(num_a) THEN
            RETURN to_jsonb(num_a::bigint);
        ELSE
            RETURN to_jsonb(num_a);
        END IF;
    END IF;

    -- ===================== / =====================
    IF op = '/' THEN
        num_a := jl_to_number(a);
        num_b := jl_to_number(b);
        IF num_b = 0 THEN RETURN 'null'::jsonb; END IF;
        num_c := num_a / num_b;
        IF num_c = trunc(num_c) THEN
            RETURN to_jsonb(num_c::bigint);
        ELSE
            RETURN to_jsonb(num_c);
        END IF;
    END IF;

    -- ===================== max =====================
    IF op = 'max' THEN
        num_a := jl_to_number(vals -> 0);
        FOR i IN 1 .. arr_len - 1 LOOP
            num_b := jl_to_number(vals -> i);
            IF num_b > num_a THEN num_a := num_b; END IF;
        END LOOP;
        IF num_a = trunc(num_a) THEN
            RETURN to_jsonb(num_a::bigint);
        ELSE
            RETURN to_jsonb(num_a);
        END IF;
    END IF;

    -- ===================== min =====================
    IF op = 'min' THEN
        num_a := jl_to_number(vals -> 0);
        FOR i IN 1 .. arr_len - 1 LOOP
            num_b := jl_to_number(vals -> i);
            IF num_b < num_a THEN num_a := num_b; END IF;
        END LOOP;
        IF num_a = trunc(num_a) THEN
            RETURN to_jsonb(num_a::bigint);
        ELSE
            RETURN to_jsonb(num_a);
        END IF;
    END IF;

    -- ===================== in =====================
    IF op = 'in' THEN
        IF b IS NULL THEN RETURN 'false'::jsonb; END IF;
        IF jsonb_typeof(b) = 'array' THEN
            -- Check if a is in the array
            FOR i IN 0 .. jsonb_array_length(b) - 1 LOOP
                IF a = b -> i THEN
                    RETURN 'true'::jsonb;
                END IF;
            END LOOP;
            RETURN 'false'::jsonb;
        ELSIF jsonb_typeof(b) = 'string' THEN
            -- Substring check
            txt_a := jl_to_text(a);
            txt_b := jl_to_text(b);
            RETURN to_jsonb(position(txt_a in txt_b) > 0);
        ELSE
            RETURN 'false'::jsonb;
        END IF;
    END IF;

    -- ===================== cat =====================
    IF op = 'cat' THEN
        txt_a := '';
        FOR i IN 0 .. arr_len - 1 LOOP
            txt_a := txt_a || jl_to_text(vals -> i);
        END LOOP;
        RETURN to_jsonb(txt_a);
    END IF;

    -- ===================== substr =====================
    IF op = 'substr' THEN
        src := jl_to_text(a);
        start_pos := jl_to_number(b)::int;
        -- Handle negative start: count from end
        IF start_pos < 0 THEN
            start_pos := length(src) + start_pos;
            IF start_pos < 0 THEN start_pos := 0; END IF;
        END IF;
        IF arr_len >= 3 THEN
            end_len := jl_to_number(c)::int;
            IF end_len < 0 THEN
                -- Negative length: from start_pos, take chars until end_len from end
                temp_str := substring(src FROM start_pos + 1);
                RETURN to_jsonb(substring(temp_str FROM 1 FOR length(temp_str) + end_len));
            ELSE
                RETURN to_jsonb(substring(src FROM start_pos + 1 FOR end_len));
            END IF;
        ELSE
            RETURN to_jsonb(substring(src FROM start_pos + 1));
        END IF;
    END IF;

    -- ===================== merge =====================
    IF op = 'merge' THEN
        merge_result := '[]'::jsonb;
        FOR i IN 0 .. arr_len - 1 LOOP
            elem := vals -> i;
            IF jsonb_typeof(elem) = 'array' THEN
                -- Concatenate array elements
                FOR j IN 0 .. jsonb_array_length(elem) - 1 LOOP
                    merge_result := merge_result || jsonb_build_array(elem -> j);
                END LOOP;
            ELSE
                merge_result := merge_result || jsonb_build_array(elem);
            END IF;
        END LOOP;
        RETURN merge_result;
    END IF;

    -- ===================== log =====================
    IF op = 'log' THEN
        RAISE NOTICE 'jsonlogic log: %', a;
        RETURN a;
    END IF;

    -- ===================== has_permission =====================
    -- Calls rbac.has_permission with the given permission name.
    -- Returns true when the user has the permission; false otherwise.
    IF op = 'has_permission' THEN
        IF rbac.has_permission(jl_to_text(a)) THEN
            RETURN 'true'::jsonb;
        ELSE
            RETURN 'false'::jsonb;
        END IF;
    END IF;

    -- ===================== require_permission =====================
    -- Calls rbac.require_permission with the given permission name.
    -- Returns true when the user has the permission; throws an error otherwise.
    IF op = 'require_permission' THEN
        PERFORM rbac.require_permission(jl_to_text(a));
        RETURN 'true'::jsonb;
    END IF;

    -- ===================== value_changed =====================
    -- Checks if a field value has changed compared to $old.
    -- When $old is missing or null in data, always returns true (new record).
    -- When $old is present, compares $old.<field> with current <field>.
    IF op = 'value_changed' THEN
        var_key := jl_to_text(a);
        nav := data -> '$old';
        -- If $old is absent or null, treat as new record => always changed
        IF nav IS NULL OR jsonb_typeof(nav) = 'null' THEN
            RETURN 'true'::jsonb;
        END IF;
        -- Compare old value with current value
        IF (nav -> var_key) IS DISTINCT FROM (data -> var_key) THEN
            RETURN 'true'::jsonb;
        ELSE
            RETURN 'false'::jsonb;
        END IF;
    END IF;

    -- ===================== throw_error =====================
    -- Raises an exception with the given message.
    -- Usage: {"throw_error":"message"}
    IF op = 'throw_error' THEN
        RAISE EXCEPTION '%', jl_to_text(a) USING ERRCODE = '23514';
    END IF;

    -- Unknown operator
    RAISE EXCEPTION 'Unrecognized operation: %', op;
END;
$$ LANGUAGE plpgsql STABLE SET search_path = public;

-- Revoke public execute on all jsonlogic functions
REVOKE EXECUTE ON FUNCTION jl_truthy(jsonb) FROM public;
REVOKE EXECUTE ON FUNCTION jl_to_number(jsonb) FROM public;
REVOKE EXECUTE ON FUNCTION jl_to_text(jsonb) FROM public;
REVOKE EXECUTE ON FUNCTION jl_loose_eq(jsonb, jsonb) FROM public;
REVOKE EXECUTE ON FUNCTION evaluate_json_logic(jsonb, jsonb) FROM public;

-- Grant execute to semantius_user for jsonlogic functions
-- Required for require_permission and value_changed operators which need an authenticated user context
GRANT EXECUTE ON FUNCTION jl_truthy(jsonb) TO semantius_user;
GRANT EXECUTE ON FUNCTION jl_to_number(jsonb) TO semantius_user;
GRANT EXECUTE ON FUNCTION jl_to_text(jsonb) TO semantius_user;
GRANT EXECUTE ON FUNCTION jl_loose_eq(jsonb, jsonb) TO semantius_user;
GRANT EXECUTE ON FUNCTION evaluate_json_logic(jsonb, jsonb) TO semantius_user;
`,
    "0020_rbac_schema": `-- =====================================================
-- RBAC SYSTEM - DDL (Tables, Indexes, Constraints)
-- =====================================================

-- =====================================================
-- MODULES
-- =====================================================

-- Modules: Logical groupings for roles and permissions
CREATE TABLE modules (
    id SERIAL PRIMARY KEY,
    module_name TEXT UNIQUE NOT NULL DEFAULT '',
    description TEXT DEFAULT '',
    module_type TEXT NOT NULL DEFAULT 'domain',
    view_permission TEXT DEFAULT 'user:read' NOT NULL,
    logo_url TEXT DEFAULT '',
    logo_color TEXT DEFAULT '',
    home_page TEXT DEFAULT '/' NOT NULL,
    module_slug TEXT DEFAULT '' NOT NULL UNIQUE,
    settings JSONB,
    dashboard_config JSONB,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT valid_module_slug CHECK (module_slug = '' OR module_slug ~ '^[a-z0-9_]+$'),
    CONSTRAINT valid_module_type CHECK (module_type IN ('domain', 'master'))
);

COMMENT ON TABLE modules IS 'Logical modules that group related roles and permissions';
COMMENT ON COLUMN modules.module_slug IS 'URL-safe unique identifier for module. Auto-generated from module_name if not provided.';

-- =====================================================
-- AUTO-SET MODULE SLUG TRIGGER
-- =====================================================
-- Automatically generates module_slug from module_name when not provided

CREATE OR REPLACE FUNCTION auto_set_module_slug()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.module_slug IS NULL OR trim(NEW.module_slug) = '' THEN
        NEW.module_slug := lower(regexp_replace(NEW.module_name, '[^a-zA-Z0-9]+', '_', 'g'));
        -- Collapse consecutive underscores into a single one
        NEW.module_slug := regexp_replace(NEW.module_slug, '_+', '_', 'g');
        -- Remove leading/trailing underscores
        NEW.module_slug := trim(both '_' from NEW.module_slug);
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SET search_path = public;

COMMENT ON FUNCTION auto_set_module_slug IS
'Trigger function that auto-generates module_slug from module_name when not provided';

CREATE TRIGGER auto_set_module_slug_trigger
    BEFORE INSERT OR UPDATE ON modules
    FOR EACH ROW
    EXECUTE FUNCTION auto_set_module_slug();

COMMENT ON TRIGGER auto_set_module_slug_trigger ON modules IS
'Auto-generates module_slug from module_name when not explicitly provided';

-- Revoke default PUBLIC execute on trigger function
REVOKE EXECUTE ON FUNCTION auto_set_module_slug() FROM PUBLIC;

-- =====================================================
-- PERMISSIONS AND ROLES
-- =====================================================

-- Permissions: Basic permissions in the system
CREATE TABLE permissions (
    id SERIAL PRIMARY KEY,
    permission_name TEXT UNIQUE NOT NULL DEFAULT '',
    description TEXT DEFAULT '',
    module_id INTEGER REFERENCES modules(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

COMMENT ON TABLE permissions IS 'System permissions that can be assigned to roles and organized via hierarchy';
COMMENT ON COLUMN permissions.module_id IS 'Optional reference to a module for logical grouping';

-- Roles: Groups of permissions
CREATE TABLE roles (
    id SERIAL PRIMARY KEY,
    role_name TEXT UNIQUE NOT NULL DEFAULT '',
    slug TEXT NOT NULL DEFAULT '' UNIQUE,
    description TEXT DEFAULT '',
    origin TEXT NOT NULL DEFAULT 'user',
    module_id INTEGER REFERENCES modules(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT valid_role_origin CHECK (origin IN ('system', 'model', 'model_master', 'user')),
    CONSTRAINT valid_role_slug CHECK (slug = '' OR slug ~ '^[a-z0-9_]+$')
);

COMMENT ON TABLE roles IS 'Groups of permissions that can be assigned to users';
COMMENT ON COLUMN roles.module_id IS 'Optional reference to a module for logical grouping';
COMMENT ON COLUMN roles.slug IS 'Snake_case unique identifier for role. Auto-generated from role_name if not provided.';
COMMENT ON COLUMN roles.origin IS 'How this role was created: system (platform built-ins), model (domain module scaffold), model_master (master module scaffold), or user (admin-created).';

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

CREATE TRIGGER auto_set_role_slug_trigger
    BEFORE INSERT OR UPDATE ON roles
    FOR EACH ROW
    EXECUTE FUNCTION auto_set_role_slug();

COMMENT ON TRIGGER auto_set_role_slug_trigger ON roles IS
'Auto-generates slug from role_name when not explicitly provided';

-- Revoke default PUBLIC execute on trigger function
REVOKE EXECUTE ON FUNCTION auto_set_role_slug() FROM PUBLIC;

-- Users: External users from JWT
CREATE TABLE users (
    id SERIAL PRIMARY KEY,
    external_id TEXT UNIQUE NOT NULL DEFAULT '',
    email TEXT DEFAULT '',
    display_name TEXT DEFAULT '',
    is_disabled BOOLEAN DEFAULT FALSE,
    settings JSONB,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    last_seen TIMESTAMPTZ
);

COMMENT ON TABLE users IS 'Users and agents';
COMMENT ON COLUMN users.external_id IS 'External identifier from authentication provider (e.g., Auth0, Firebase)';

-- User-Role mapping
CREATE TABLE user_roles (
    id VARCHAR GENERATED ALWAYS AS (user_id || '.' || role_id) STORED PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    role_id INTEGER NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
    assigned_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    assigned_by INTEGER REFERENCES users(id),
    UNIQUE (user_id, role_id)
);

COMMENT ON TABLE user_roles IS 'Many-to-many mapping between users and roles';

-- Role-Permission mapping
CREATE TABLE role_permissions (
    id VARCHAR GENERATED ALWAYS AS (role_id || '.' || permission_id) STORED PRIMARY KEY,
    role_id INTEGER NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
    permission_id INTEGER NOT NULL REFERENCES permissions(id) ON DELETE CASCADE,
    granted_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    granted_by INTEGER REFERENCES users(id),
    UNIQUE (role_id, permission_id)
);

COMMENT ON TABLE role_permissions IS 'Many-to-many mapping between roles and permissions';

-- User-Permission mapping (direct per-user permissions)
CREATE TABLE user_permissions (
    id VARCHAR GENERATED ALWAYS AS (user_id || '.' || permission_id) STORED PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    permission_id INTEGER NOT NULL REFERENCES permissions(id) ON DELETE CASCADE,
    granted_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    granted_by INTEGER REFERENCES users(id),
    UNIQUE (user_id, permission_id)
);

COMMENT ON TABLE user_permissions IS 'Many-to-many mapping between users and permissions for direct per-user permission grants';

-- =====================================================
-- PERMISSION HIERARCHY
-- =====================================================

-- Permission hierarchy: Defines which permissions imply others
-- Example: customer.manage implies customer.read and customer.write
CREATE TABLE permission_hierarchy (
    id VARCHAR GENERATED ALWAYS AS (including_permission_id || '.' || included_permission_id) STORED PRIMARY KEY,
    including_permission_id INTEGER NOT NULL REFERENCES permissions(id) ON DELETE CASCADE,
    included_permission_id INTEGER NOT NULL REFERENCES permissions(id) ON DELETE CASCADE,
    origin TEXT NOT NULL DEFAULT 'user',
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (including_permission_id, included_permission_id),
    CONSTRAINT no_self_reference CHECK (including_permission_id != included_permission_id),
    CONSTRAINT valid_permission_hierarchy_origin CHECK (origin IN ('system', 'model', 'model_master', 'user'))
);

COMMENT ON TABLE permission_hierarchy IS 'Defines permission inclusion (including permission implies included permissions)';
COMMENT ON COLUMN permission_hierarchy.including_permission_id IS 'The broader permission that includes other permissions';
COMMENT ON COLUMN permission_hierarchy.included_permission_id IS 'The narrower permission that is included by the broader one';
COMMENT ON COLUMN permission_hierarchy.origin IS 'How this hierarchy entry was created: system (platform-seeded), model (model file), model_master (promotion/wire-up), or user (admin-created).';

-- =====================================================
-- ADD FK COLUMNS TO MODULES (after roles and permissions exist)
-- =====================================================

ALTER TABLE modules ADD COLUMN manage_permission_id INTEGER REFERENCES permissions(id);
ALTER TABLE modules ADD COLUMN admin_permission_id INTEGER REFERENCES permissions(id);
ALTER TABLE modules ADD COLUMN default_viewer_role_id INTEGER REFERENCES roles(id);
ALTER TABLE modules ADD COLUMN default_manager_role_id INTEGER REFERENCES roles(id);
ALTER TABLE modules ADD COLUMN default_admin_role_id INTEGER REFERENCES roles(id);

COMMENT ON COLUMN modules.module_type IS 'Module type: domain (normal) or master (promoted for sharing).';
COMMENT ON COLUMN modules.manage_permission_id IS 'FK to the manage permission for this module. Populated by scaffold.';
COMMENT ON COLUMN modules.admin_permission_id IS 'FK to the admin permission for this module. Populated when any entity carries edit_permission: admin.';
COMMENT ON COLUMN modules.default_viewer_role_id IS 'FK to the default viewer role for this module. Populated by scaffold.';
COMMENT ON COLUMN modules.default_manager_role_id IS 'FK to the default manager role for this module. Populated by scaffold.';
COMMENT ON COLUMN modules.default_admin_role_id IS 'FK to the default admin role for this module. Populated when admin permission is present.';

-- =====================================================
-- TRIGGERS FOR updated_at AUTOMATION
-- =====================================================

CREATE TRIGGER update_modules_updated_at
    BEFORE UPDATE ON modules
    FOR EACH ROW EXECUTE FUNCTION common.update_updated_at_column();

CREATE TRIGGER update_permissions_updated_at
    BEFORE UPDATE ON permissions
    FOR EACH ROW EXECUTE FUNCTION common.update_updated_at_column();

CREATE TRIGGER update_roles_updated_at
    BEFORE UPDATE ON roles
    FOR EACH ROW EXECUTE FUNCTION common.update_updated_at_column();

CREATE TRIGGER update_users_updated_at
    BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION common.update_updated_at_column();

-- =====================================================
-- INDEXES - Modules
-- =====================================================

CREATE INDEX idx_modules_name ON modules(module_name);

-- =====================================================
-- INDEXES - Permissions
-- =====================================================

CREATE INDEX idx_permissions_name ON permissions(permission_name);
CREATE INDEX idx_permissions_module ON permissions(module_id);

-- =====================================================
-- INDEXES - Roles
-- =====================================================

CREATE INDEX idx_roles_name ON roles(role_name);
CREATE INDEX idx_roles_module ON roles(module_id);
CREATE INDEX idx_role_permissions_role ON role_permissions(role_id);
CREATE INDEX idx_role_permissions_permission ON role_permissions(permission_id);
CREATE INDEX idx_role_permissions_granted_by ON role_permissions(granted_by);

-- =====================================================
-- INDEXES - User Permissions
-- =====================================================

CREATE INDEX idx_user_permissions_user ON user_permissions(user_id);
CREATE INDEX idx_user_permissions_permission ON user_permissions(permission_id);
CREATE INDEX idx_user_permissions_granted_by ON user_permissions(granted_by);

-- =====================================================
-- INDEXES - Users
-- =====================================================

CREATE INDEX idx_users_external_id ON users(external_id);
CREATE INDEX idx_users_email ON users(email);
CREATE INDEX idx_users_enabled ON users(is_disabled) WHERE is_disabled = FALSE;
CREATE INDEX idx_users_disabled ON users(is_disabled) WHERE is_disabled = TRUE;

-- =====================================================
-- INDEXES - User Roles
-- =====================================================

CREATE INDEX idx_user_roles_user ON user_roles(user_id);
CREATE INDEX idx_user_roles_role ON user_roles(role_id);
CREATE INDEX idx_user_roles_assigned_by ON user_roles(assigned_by);

-- =====================================================
-- INDEXES - Permission Hierarchy
-- =====================================================

CREATE INDEX idx_permission_hierarchy_including ON permission_hierarchy(including_permission_id);
CREATE INDEX idx_permission_hierarchy_included ON permission_hierarchy(included_permission_id);

-- =====================================================
-- INDEXES - Modules FK columns
-- =====================================================

CREATE INDEX idx_modules_manage_permission ON modules(manage_permission_id);
CREATE INDEX idx_modules_admin_permission ON modules(admin_permission_id);
CREATE INDEX idx_modules_default_viewer_role ON modules(default_viewer_role_id);
CREATE INDEX idx_modules_default_manager_role ON modules(default_manager_role_id);
CREATE INDEX idx_modules_default_admin_role ON modules(default_admin_role_id);

-- =====================================================
-- INDEXES - Roles slug
-- =====================================================

CREATE INDEX idx_roles_slug ON roles(slug);`,
    "0030_rbac_functions": `-- =====================================================
-- CREATE SCHEMA
-- =====================================================

CREATE SCHEMA IF NOT EXISTS rbac;

-- =====================================================
-- GRANT PERMISSIONS
-- =====================================================

-- Allow semantius_user users to use rbac schema and execute functions
GRANT USAGE ON SCHEMA rbac TO semantius_user;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA rbac TO semantius_user;

-- Ensure future functions are automatically granted (THIS IS KEY!)
ALTER DEFAULT PRIVILEGES IN SCHEMA rbac
    GRANT EXECUTE ON FUNCTIONS TO semantius_user;

-- Revoke default PUBLIC execute on future rbac functions
ALTER DEFAULT PRIVILEGES IN SCHEMA rbac
    REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;


-- =====================================================
-- RBAC SYSTEM - PL/pgSQL FUNCTIONS
-- =====================================================
-- Run this AFTER creating schema and tables
-- All functions in rbac schema for organization
-- Tables remain in public schema for Neon Data API compatibility
-- =====================================================

-- =====================================================
-- CYCLE DETECTION FOR PERMISSION HIERARCHY
-- =====================================================

-- Function to detect cycles in permission hierarchy and enforce depth limit of 11
CREATE OR REPLACE FUNCTION rbac.check_permission_hierarchy_cycle()
RETURNS TRIGGER AS $$
DECLARE
    cycle_exists BOOLEAN;
    max_depth INTEGER;
BEGIN
    -- Validate that both including and included permissions exist (redundant with FK but explicit)
    IF NOT EXISTS (SELECT 1 FROM permissions WHERE id = NEW.including_permission_id) THEN
        RAISE EXCEPTION 'Including permission with Id % does not exist', NEW.including_permission_id;
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM permissions WHERE id = NEW.included_permission_id) THEN
        RAISE EXCEPTION 'Included permission with Id % does not exist', NEW.included_permission_id;
    END IF;
    
    -- Check if adding this edge would create a cycle or exceed depth limit
    -- A cycle exists if the included can reach the including through existing paths
    WITH RECURSIVE hierarchy_path AS (
        -- Start from the proposed included
        SELECT included_permission_id AS permission_id, 1 AS depth
        FROM permission_hierarchy
        WHERE including_permission_id = NEW.included_permission_id
        
        UNION ALL
        
        -- Recursively follow the hierarchy
        SELECT ph.included_permission_id, hp.depth + 1
        FROM permission_hierarchy ph
        INNER JOIN hierarchy_path hp ON ph.including_permission_id = hp.permission_id
        WHERE hp.depth < 11  -- Stop at depth 11
    )
    SELECT 
        EXISTS (SELECT 1 FROM hierarchy_path WHERE permission_id = NEW.including_permission_id),
        COALESCE(MAX(depth), 0)
    INTO cycle_exists, max_depth
    FROM hierarchy_path;
    
    IF cycle_exists THEN
        RAISE EXCEPTION 'Cannot add permission hierarchy: would create a cycle. Permission Id % cannot be both ancestor and descendant of permission Id %', 
            NEW.including_permission_id, NEW.included_permission_id;
    END IF;
    
    IF max_depth >= 11 THEN
        RAISE EXCEPTION 'Cannot add permission hierarchy: maximum depth of 11 levels would be exceeded. Current depth would be %', 
            max_depth + 1;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SET search_path = rbac, public;

COMMENT ON FUNCTION rbac.check_permission_hierarchy_cycle IS 
'Trigger function to prevent cycles and enforce 11-level depth limit in permission hierarchy.';

-- Apply trigger BEFORE INSERT OR UPDATE
CREATE TRIGGER prevent_permission_hierarchy_cycle
    BEFORE INSERT OR UPDATE ON permission_hierarchy
    FOR EACH ROW
    EXECUTE FUNCTION rbac.check_permission_hierarchy_cycle();

-- =====================================================
-- USER DETECTION AND IDENTIFICATION
-- =====================================================

-- Validate JWT claims before allowing any operation
-- Centralizes all JWT validation so that role, aud, or other checks
-- only need to be changed in one place.
-- Called by rbac.uid() which is the gateway for all authenticated operations.
-- Single JWT validation + user identity function
-- Handles both Neon format (individual request.jwt.claim.* settings)
-- and Supabase format (single request.jwt.claims JSON blob)
-- Normalizes Supabase format to Neon format for all downstream code
-- STABLE: result is cached per transaction, so safe to call from every function
CREATE OR REPLACE FUNCTION rbac.uid()
RETURNS TEXT AS $$
DECLARE
    v_role TEXT;
    sub_value TEXT;
    supabase_claims jsonb;
    claim_key TEXT;
    claim_value TEXT;
    v_required_aud TEXT;
    v_jwt_aud TEXT;
    v_aud_json JSONB;
BEGIN
    -- Step 1: Try Neon format (fastest path — individual claim settings)
    v_role := current_setting('request.jwt.claim.role', true);
    sub_value := current_setting('request.jwt.claim.sub', true);

    -- Step 2: If not Neon format, fall back to Supabase format (single JSON blob)
    IF NOT (v_role = 'authenticated' AND sub_value IS NOT NULL AND sub_value != '') THEN
        IF v_role IS NULL OR v_role = '' THEN
            BEGIN
                supabase_claims := current_setting('request.jwt.claims', true)::jsonb;
            EXCEPTION
                WHEN OTHERS THEN
                    RAISE EXCEPTION 'Authentication required: No valid JWT claims found'
                        USING ERRCODE = 'insufficient_privilege';
            END;

            IF supabase_claims IS NULL THEN
                RAISE EXCEPTION 'Authentication required: No valid JWT claims found'
                    USING ERRCODE = 'insufficient_privilege';
            END IF;

            -- Normalize: convert all Supabase JSON properties to Neon-style settings
            FOR claim_key, claim_value IN
                SELECT key, value::text
                FROM jsonb_each_text(supabase_claims)
            LOOP
                BEGIN
                    PERFORM set_config('request.jwt.claim.' || claim_key, claim_value, true);
                EXCEPTION
                    WHEN OTHERS THEN NULL;
                END;
            END LOOP;

            -- Read normalized values
            v_role := current_setting('request.jwt.claim.role', true);
            sub_value := current_setting('request.jwt.claim.sub', true);
        END IF;
    END IF;

    -- Validate role
    IF v_role IS DISTINCT FROM 'authenticated' THEN
        RAISE EXCEPTION 'Authentication required: JWT role claim must be authenticated'
            USING ERRCODE = 'insufficient_privilege';
    END IF;

    -- Validate sub
    IF sub_value IS NULL OR sub_value = '' THEN
        RAISE EXCEPTION 'Authentication required: JWT sub claim is missing'
            USING ERRCODE = 'insufficient_privilege';
    END IF;

    -- Validate JWT audience against _settings if a jwt_aud entry is configured.
    -- This function is SECURITY DEFINER so it bypasses RLS and can always read _settings.
    SELECT value INTO v_required_aud
    FROM _settings
    WHERE name = 'jwt_aud';

    IF v_required_aud IS NOT NULL AND v_required_aud != '' THEN
        v_jwt_aud := current_setting('request.jwt.claim.aud', true);

        IF v_jwt_aud IS NULL OR v_jwt_aud = '' THEN
            RAISE EXCEPTION 'Authentication required: JWT audience claim is missing'
                USING ERRCODE = 'insufficient_privilege';
        END IF;

        -- Try to parse aud as JSON (array or string).
        -- Neon sets array aud values as JSON (e.g. '["myapp","other"]');
        -- a plain string audience is not valid JSON and falls to the exception handler.
        BEGIN
            v_aud_json := v_jwt_aud::jsonb;
        EXCEPTION WHEN invalid_text_representation THEN
            -- Plain (non-JSON) string — compare directly
            IF v_jwt_aud != v_required_aud THEN
                RAISE EXCEPTION 'Authentication required: JWT audience does not match'
                    USING ERRCODE = 'insufficient_privilege';
            END IF;
            RETURN sub_value;
        END;

        IF jsonb_typeof(v_aud_json) = 'array' THEN
            -- aud is a JSON array — the required audience must be one of the elements
            IF NOT (v_aud_json ? v_required_aud) THEN
                RAISE EXCEPTION 'Authentication required: JWT audience does not match'
                    USING ERRCODE = 'insufficient_privilege';
            END IF;
        ELSE
            -- aud is a JSON scalar string — extract text and compare
            IF v_aud_json #>> '{}' != v_required_aud THEN
                RAISE EXCEPTION 'Authentication required: JWT audience does not match'
                    USING ERRCODE = 'insufficient_privilege';
            END IF;
        END IF;
    END IF;

    RETURN sub_value;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = rbac, public;

COMMENT ON FUNCTION rbac.uid IS
'JWT validation gate + user identity. Checks role=authenticated, returns sub. Auto-detects and normalizes Neon/Supabase JWT formats. When _settings contains a jwt_aud entry the JWT aud claim must match. STABLE — cached per transaction.';

-- =====================================================
-- USER MANAGEMENT
-- =====================================================

-- Read-only function to get user_id by external_id
-- Used by RLS policies in read-only transactions (e.g., PostgREST GET requests)
-- Returns NULL if user doesn't exist
CREATE OR REPLACE FUNCTION rbac.get_user_by_external_id(
    p_external_id TEXT
)
RETURNS INTEGER AS $$
DECLARE
    v_user_id INTEGER;
BEGIN
    PERFORM rbac.uid();

    -- Validate external_id is not empty
    IF p_external_id IS NULL OR trim(p_external_id) = '' THEN
        RETURN NULL;
    END IF;

    SELECT id INTO v_user_id
    FROM users
    WHERE external_id = p_external_id
      AND is_disabled = FALSE;

    RETURN v_user_id;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = rbac, public;

COMMENT ON FUNCTION rbac.get_user_by_external_id IS
'Read-only lookup of user_id by external_id. Returns NULL if user not found or disabled. Used by RLS policies.';

-- Initialize or update user from JWT
-- Called by get_userinfo() to create/update user and update last_seen
-- NOT called by RLS policies (they use read-only lookup)
CREATE OR REPLACE FUNCTION rbac.upsert_user_from_jwt(
    p_external_id TEXT,
    p_email TEXT DEFAULT NULL
)
RETURNS INTEGER AS $$
DECLARE
    v_user_id INTEGER;
BEGIN
    PERFORM rbac.uid();

    -- Validate external_id is not empty
    IF p_external_id IS NULL OR trim(p_external_id) = '' THEN
        RAISE EXCEPTION 'external_id cannot be null or empty';
    END IF;

    INSERT INTO users (external_id, email, last_seen)
    VALUES (p_external_id, p_email, CURRENT_TIMESTAMP)
    ON CONFLICT (external_id) DO UPDATE
    SET last_seen = CURRENT_TIMESTAMP,
        email = COALESCE(EXCLUDED.email, users.email)
    RETURNING id INTO v_user_id;
    
    RETURN v_user_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = rbac, public;

COMMENT ON FUNCTION rbac.upsert_user_from_jwt IS 
'Creates or updates user record from JWT claims. Updates last_seen timestamp. Called by get_userinfo().';

-- =====================================================
-- REQUEST CONTEXT - LAZY INITIALIZATION
-- =====================================================

-- Initialize request context on first use (lazy initialization)
-- Loads all user permissions once and caches them for the transaction
-- This is called automatically by permission checking functions
-- READ-ONLY: Does not modify database, compatible with PostgREST GET requests
CREATE OR REPLACE FUNCTION rbac.ensure_context_initialized()
RETURNS void AS $$
DECLARE
    v_external_id TEXT;
    v_user_id INTEGER;
    v_permissions TEXT;
    v_initialized TEXT;
BEGIN
    PERFORM rbac.uid();

    -- Check if already initialized in this transaction
    v_initialized := current_setting('app.context_initialized', true);

    IF v_initialized = 'true' THEN
        RETURN; -- Already initialized, skip
    END IF;
    
    -- Get current user from JWT
    v_external_id := rbac.uid();
    
    -- Read-only lookup: Get user_id without modifying database
    v_user_id := rbac.get_user_by_external_id(v_external_id);
    
    -- User must exist - client should have called get_userinfo() on first login
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'User not found: %. Client must call get_userinfo() on first login to create user record.', v_external_id
            USING ERRCODE = 'invalid_authorization_specification';
    END IF;
    
    -- OPTIMIZATION: Load all user permissions once as comma-separated string
    -- This expensive recursive CTE runs only once per request
    SELECT string_agg(permission_name, ',' ORDER BY permission_name)
    INTO v_permissions
    FROM rbac.get_user_permissions(v_external_id);
    
    -- Set PostgreSQL session variables scoped to the current transaction (LOCAL)
    -- Using true (LOCAL) ensures these are automatically cleared when the transaction ends,
    -- preventing stale permissions from leaking across requests on pooled connections
    PERFORM set_config('app.current_user_id', v_user_id::TEXT, true);
    PERFORM set_config('app.current_external_id', v_external_id, true);
    PERFORM set_config('app.user_permissions', COALESCE(v_permissions, ''), true);
    PERFORM set_config('app.context_initialized', 'true', true);
    
    -- Note: OAuth scopes handled separately if needed
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = rbac, public;

COMMENT ON FUNCTION rbac.ensure_context_initialized IS 
'Lazy initialization of request context. Called automatically on first permission check.';

-- Manual context initialization with OAuth scopes
-- Use this for OAuth/API requests where scopes need to be validated
CREATE OR REPLACE FUNCTION rbac.set_request_context(
    p_external_id TEXT DEFAULT NULL,
    p_email TEXT DEFAULT NULL,
    p_oauth_scopes TEXT DEFAULT NULL
)
RETURNS void AS $$
DECLARE
    v_external_id TEXT;
    v_user_id INTEGER;
    v_permissions TEXT;
BEGIN
    PERFORM rbac.uid();

    -- Use provided external_id or detect from JWT
    v_external_id := COALESCE(p_external_id, rbac.uid());
    
    -- Validate external_id is not empty
    IF v_external_id IS NULL OR trim(v_external_id) = '' THEN
        RAISE EXCEPTION 'external_id cannot be null or empty';
    END IF;
    
    -- Ensure user exists and update last_seen
    v_user_id := rbac.upsert_user_from_jwt(
        v_external_id, 
        COALESCE(p_email, current_setting('request.jwt.claim.email', true))
    );
    
    -- OPTIMIZATION: Load all user permissions once as comma-separated string
    SELECT string_agg(permission_name, ',' ORDER BY permission_name)
    INTO v_permissions
    FROM rbac.get_user_permissions(v_external_id);
    
    -- Set PostgreSQL session variables scoped to the current transaction (LOCAL)
    -- Using true (LOCAL) ensures these are automatically cleared when the transaction ends,
    -- preventing stale permissions from leaking across requests on pooled connections
    PERFORM set_config('app.current_user_id', v_user_id::TEXT, true);
    PERFORM set_config('app.current_external_id', v_external_id, true);
    PERFORM set_config('app.user_permissions', COALESCE(v_permissions, ''), true);
    PERFORM set_config('app.context_initialized', 'true', true);

    -- Store OAuth2 scopes if present (for API requests)
    IF p_oauth_scopes IS NOT NULL THEN
        PERFORM set_config('app.oauth_scopes', p_oauth_scopes, true);
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = rbac, public;

COMMENT ON FUNCTION rbac.set_request_context IS 
'Manually sets request context. Optional - context auto-initializes if not called. Use for OAuth scope validation.';

-- =====================================================
-- PERMISSION CHECKING
-- =====================================================

-- Check if user has a specific permission
-- This includes:
-- 1. Direct permissions from roles
-- 2. Implied permissions via hierarchy
-- 3. OAuth scope restrictions (if scopes are set)
CREATE OR REPLACE FUNCTION rbac.user_has_permission(
    p_external_id TEXT,
    p_permission_name TEXT
)
RETURNS BOOLEAN AS $$
DECLARE
    v_oauth_scopes TEXT;
    v_has_permission BOOLEAN;
    v_permission_id INTEGER;
BEGIN
    PERFORM rbac.uid();

    -- Validate inputs
    IF p_external_id IS NULL OR trim(p_external_id) = '' THEN
        RETURN FALSE;
    END IF;
    
    IF p_permission_name IS NULL OR trim(p_permission_name) = '' THEN
        RETURN FALSE;
    END IF;
    
    -- Get the permission_id for the requested permission
    SELECT id INTO v_permission_id
    FROM permissions
    WHERE permission_name = p_permission_name;
    
    -- If permission doesn't exist, return false
    IF v_permission_id IS NULL THEN
        RETURN FALSE;
    END IF;
    
    -- Check if user has the permission (including hierarchy)
    -- Using recursive CTE to follow the hierarchy
    WITH RECURSIVE permission_tree AS (
        -- Start with direct permissions from roles
        SELECT DISTINCT p.id AS permission_id
        FROM users u
        JOIN user_roles ur ON u.id = ur.user_id
        JOIN roles r ON ur.role_id = r.id
        JOIN role_permissions rp ON r.id = rp.role_id
        JOIN permissions p ON rp.permission_id = p.id
        WHERE u.external_id = p_external_id
          AND u.is_disabled = FALSE
        
        UNION
        
        -- Direct per-user permissions
        SELECT DISTINCT p.id AS permission_id
        FROM users u
        JOIN user_permissions up ON u.id = up.user_id
        JOIN permissions p ON up.permission_id = p.id
        WHERE u.external_id = p_external_id
          AND u.is_disabled = FALSE
        
        UNION
        
        -- Add implied permissions (included in hierarchy)
        SELECT DISTINCT ph.included_permission_id
        FROM permission_tree pt
        JOIN permission_hierarchy ph ON pt.permission_id = ph.including_permission_id
    )
    SELECT EXISTS (
        SELECT 1 FROM permission_tree
        WHERE permission_id = v_permission_id
    ) INTO v_has_permission;
    
    -- If user doesn't have the permission, return false immediately
    IF NOT v_has_permission THEN
        RETURN FALSE;
    END IF;
    
    -- Check OAuth2 scopes if present
    v_oauth_scopes := current_setting('app.oauth_scopes', true);
    
    -- If no OAuth scopes set (user-initiated request), allow
    IF v_oauth_scopes IS NULL OR v_oauth_scopes = '' THEN
        RETURN TRUE;
    END IF;
    
    -- Check if required permission is in OAuth scopes
    -- OAuth scopes can include the permission OR a parent permission that implies it
    RETURN EXISTS (
        WITH RECURSIVE permission_tree AS (
            -- Get permissions from OAuth scopes
            SELECT DISTINCT p.id AS permission_id
            FROM permissions p
            WHERE p.permission_name = ANY(string_to_array(v_oauth_scopes, ' '))
            
            UNION
            
            -- Add implied permissions
            SELECT DISTINCT ph.included_permission_id
            FROM permission_tree pt
            JOIN permission_hierarchy ph ON pt.permission_id = ph.including_permission_id
        )
        SELECT 1 FROM permission_tree
        WHERE permission_id = v_permission_id
    );
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = rbac, public;

COMMENT ON FUNCTION rbac.user_has_permission IS 
'Checks if user has permission by name, considering hierarchy and OAuth scopes.';

-- Check if current request user has permission
-- AUTO-INITIALIZES context on first call (lazy initialization)
-- OPTIMIZED: Uses cached permissions from session for ultra-fast lookups
CREATE OR REPLACE FUNCTION rbac.has_permission(
    p_permission_name TEXT
)
RETURNS BOOLEAN AS $$
DECLARE
    v_cached_permissions TEXT;
    v_oauth_scopes TEXT;
    v_external_id TEXT;
BEGIN
    PERFORM rbac.uid();

    -- Validate permission_name
    IF p_permission_name IS NULL OR trim(p_permission_name) = '' THEN
        RETURN FALSE;
    END IF;
    
    -- LAZY INITIALIZATION: Ensure context is initialized
    PERFORM rbac.ensure_context_initialized();
    
    -- OPTIMIZATION: Get cached permissions (now guaranteed to exist)
    v_cached_permissions := current_setting('app.user_permissions', true);
    
    -- Fast string search in comma-separated list
    -- This is 1000x faster than querying the database
    IF v_cached_permissions IS NOT NULL AND v_cached_permissions != '' THEN
        -- Check if permission exists in comma-separated list
        IF position(',' || p_permission_name || ',' IN ',' || v_cached_permissions || ',') > 0 THEN
            -- Permission found in cache, now check OAuth scopes if present
            v_oauth_scopes := current_setting('app.oauth_scopes', true);
            
            -- If no OAuth scopes set (user-initiated request), allow
            IF v_oauth_scopes IS NULL OR v_oauth_scopes = '' THEN
                RETURN TRUE;
            END IF;
            
            -- Check if permission is in OAuth scopes
            RETURN position(',' || p_permission_name || ',' IN ',' || v_oauth_scopes || ',') > 0;
        ELSE
            -- Permission not in cache
            RETURN FALSE;
        END IF;
    END IF;
    
    -- Should never reach here after initialization, but safety fallback
    RETURN FALSE;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = rbac, public;

COMMENT ON FUNCTION rbac.has_permission IS 
'Checks if current user has permission. Auto-initializes context and uses cached permissions.';

-- Require permission or raise exception
-- Use this in application functions to enforce permissions
CREATE OR REPLACE FUNCTION rbac.require_permission(
    p_permission_name TEXT
)
RETURNS void AS $$
BEGIN
    PERFORM rbac.uid();
    IF NOT rbac.has_permission(p_permission_name) THEN
        RAISE EXCEPTION 'Permission denied: % required', p_permission_name
            USING ERRCODE = 'insufficient_privilege';
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = rbac, public;

COMMENT ON FUNCTION rbac.require_permission IS 
'Raises exception if current user lacks permission. Use for access control.';

-- Check if user has any of the specified permissions (OR logic)
-- Uses cached permissions for optimal performance
CREATE OR REPLACE FUNCTION rbac.has_any_permission(
    VARIADIC p_permission_names TEXT[]
)
RETURNS BOOLEAN AS $$
DECLARE
    v_cached_permissions TEXT;
    v_permission TEXT;
    v_oauth_scopes TEXT;
    v_has_base_permission BOOLEAN := FALSE;
BEGIN
    PERFORM rbac.uid();

    -- Validate input
    IF p_permission_names IS NULL OR array_length(p_permission_names, 1) IS NULL THEN
        RETURN FALSE;
    END IF;

    -- LAZY INITIALIZATION: Ensure context is initialized
    PERFORM rbac.ensure_context_initialized();
    
    -- Get cached permissions (now guaranteed to exist)
    v_cached_permissions := current_setting('app.user_permissions', true);
    
    IF v_cached_permissions IS NOT NULL AND v_cached_permissions != '' THEN
        -- Check if any permission exists in cache
        FOREACH v_permission IN ARRAY p_permission_names
        LOOP
            IF position(',' || v_permission || ',' IN ',' || v_cached_permissions || ',') > 0 THEN
                v_has_base_permission := TRUE;
                EXIT; -- Found one, stop checking
            END IF;
        END LOOP;
        
        IF NOT v_has_base_permission THEN
            RETURN FALSE;
        END IF;
        
        -- Check OAuth scopes if present
        v_oauth_scopes := current_setting('app.oauth_scopes', true);
        
        IF v_oauth_scopes IS NULL OR v_oauth_scopes = '' THEN
            RETURN TRUE;
        END IF;
        
        -- Verify at least one permission is in OAuth scopes
        FOREACH v_permission IN ARRAY p_permission_names
        LOOP
            IF position(',' || v_permission || ',' IN ',' || v_oauth_scopes || ',') > 0 THEN
                RETURN TRUE;
            END IF;
        END LOOP;
        
        RETURN FALSE;
    END IF;
    
    -- Should never reach here after initialization
    RETURN FALSE;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = rbac, public;

COMMENT ON FUNCTION rbac.has_any_permission IS 
'Returns true if current user has at least one of the specified permissions.';

-- Require any of the specified permissions or raise exception
-- Use this when multiple permissions could authorize an action (OR logic)
CREATE OR REPLACE FUNCTION rbac.require_any_permission(
    VARIADIC p_permission_names TEXT[]
)
RETURNS void AS $$
BEGIN
    PERFORM rbac.uid();
    IF NOT rbac.has_any_permission(VARIADIC p_permission_names) THEN
        RAISE EXCEPTION 'Permission denied: one of (%) required', array_to_string(p_permission_names, ', ')
            USING ERRCODE = 'insufficient_privilege';
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = rbac, public;

COMMENT ON FUNCTION rbac.require_any_permission IS 
'Raises exception if current user lacks all specified permissions.';

-- =====================================================
-- PERMISSION QUERIES
-- =====================================================

-- Get all effective permissions for a user (including implied)
CREATE OR REPLACE FUNCTION rbac.get_user_permissions(
    p_external_id TEXT
)
RETURNS TABLE (
    permission_name TEXT
) AS $$
BEGIN
    PERFORM rbac.uid();

    -- Validate external_id
    IF p_external_id IS NULL OR trim(p_external_id) = '' THEN
        RETURN;
    END IF;

    RETURN QUERY
    WITH RECURSIVE permission_tree AS (
        -- Direct permissions from roles
        SELECT DISTINCT p.id AS permission_id, p.permission_name
        FROM users u
        JOIN user_roles ur ON u.id = ur.user_id
        JOIN roles r ON ur.role_id = r.id
        JOIN role_permissions rp ON r.id = rp.role_id
        JOIN permissions p ON rp.permission_id = p.id
        WHERE u.external_id = p_external_id
          AND u.is_disabled = FALSE
        
        UNION
        
        -- Direct per-user permissions
        SELECT DISTINCT p.id AS permission_id, p.permission_name
        FROM users u
        JOIN user_permissions up ON u.id = up.user_id
        JOIN permissions p ON up.permission_id = p.id
        WHERE u.external_id = p_external_id
          AND u.is_disabled = FALSE
        
        UNION
        
        -- Implied permissions
        SELECT DISTINCT p.id AS permission_id, p.permission_name
        FROM permission_tree pt
        JOIN permission_hierarchy ph ON pt.permission_id = ph.including_permission_id
        JOIN permissions p ON ph.included_permission_id = p.id
    )
    SELECT DISTINCT pt.permission_name
    FROM permission_tree pt
    ORDER BY pt.permission_name;
END;
$$ LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = rbac, public;

COMMENT ON FUNCTION rbac.get_user_permissions IS
'Returns all effective permissions for a user, including implied permissions.';

-- Get current user's permissions (uses lazy initialization)
CREATE OR REPLACE FUNCTION rbac.get_current_user_permissions()
RETURNS TABLE (
    permission_name TEXT
) AS $$
BEGIN
    PERFORM rbac.uid();

    -- Ensure context is initialized
    PERFORM rbac.ensure_context_initialized();

    -- Return cached permissions as table
    RETURN QUERY
    SELECT unnest(string_to_array(current_setting('app.user_permissions', true), ','))::TEXT
    WHERE current_setting('app.user_permissions', true) IS NOT NULL 
      AND current_setting('app.user_permissions', true) != '';
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = rbac, public;

COMMENT ON FUNCTION rbac.get_current_user_permissions IS 
'Returns all permissions for current user from cache. Auto-initializes if needed.';

-- Validate OAuth scopes against user permissions
CREATE OR REPLACE FUNCTION rbac.validate_oauth_scopes(
    p_external_id TEXT,
    p_requested_scopes TEXT
)
RETURNS TABLE (
    scope TEXT,
    is_valid BOOLEAN,
    reason TEXT
) AS $$
BEGIN
    PERFORM rbac.uid();

    -- Validate inputs
    IF p_external_id IS NULL OR trim(p_external_id) = '' THEN
        RAISE EXCEPTION 'external_id cannot be null or empty';
    END IF;

    IF p_requested_scopes IS NULL OR trim(p_requested_scopes) = '' THEN
        RETURN;
    END IF;

    RETURN QUERY
    WITH user_perms AS (
        SELECT permission_name FROM rbac.get_user_permissions(p_external_id)
    )
    SELECT 
        s.scope::TEXT,
        EXISTS (SELECT 1 FROM user_perms WHERE permission_name = s.scope) AS is_valid,
        CASE 
            WHEN EXISTS (SELECT 1 FROM user_perms WHERE permission_name = s.scope)
            THEN 'Granted'::TEXT
            ELSE 'User does not have this permission'::TEXT
        END AS reason
    FROM unnest(string_to_array(p_requested_scopes, ' ')) AS s(scope);
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = rbac, public;

COMMENT ON FUNCTION rbac.validate_oauth_scopes IS 
'Validates which OAuth scopes a user can request. Use during token issuance.';

-- Validate that a permission exists
-- Note: no rbac.uid() here — this function is called by triggers
-- during migrations when there is no JWT context.
CREATE OR REPLACE FUNCTION rbac.validate_permission_exists(p_permission_name TEXT)
RETURNS BOOLEAN AS $$
BEGIN
    RETURN EXISTS (
        SELECT 1 FROM permissions WHERE permission_name = p_permission_name
    );
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = rbac, public;

COMMENT ON FUNCTION rbac.validate_permission_exists IS 
'Validates that a permission exists in the permissions table.';

-- =====================================================
-- HELPER FUNCTIONS
-- =====================================================

-- Get current user's internal database Id
CREATE OR REPLACE FUNCTION rbac.user_id()
RETURNS INTEGER AS $$
BEGIN
    PERFORM rbac.uid();

    -- Ensure context is initialized
    PERFORM rbac.ensure_context_initialized();

    RETURN current_setting('app.current_user_id', true)::INTEGER;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = rbac, public;

COMMENT ON FUNCTION rbac.user_id IS 
'Returns internal user_id for current user. Auto-initializes if needed.';

-- =====================================================
-- DEBUGGING AND INTROSPECTION
-- =====================================================

-- Get complete context information for current user
CREATE OR REPLACE FUNCTION rbac.whoami()
RETURNS TABLE (
    context_type TEXT,
    key TEXT,
    value TEXT
) AS $$
DECLARE
    v_initialized TEXT;
    v_jwt_claims TEXT[];
    v_claim TEXT;
    v_claim_value TEXT;
BEGIN
    PERFORM rbac.uid();

    -- Return raw JWT settings BEFORE initialization
    RETURN QUERY SELECT
        'jwt_raw'::TEXT,
        'request.jwt.claim.sub'::TEXT,
        current_setting('request.jwt.claim.sub', true);
    
    RETURN QUERY SELECT 
        'jwt_raw'::TEXT,
        'request.jwt.claims'::TEXT,
        current_setting('request.jwt.claims', true);
    
    -- Initialize context (will throw error if no JWT)
    PERFORM rbac.ensure_context_initialized();
    
    v_initialized := current_setting('app.context_initialized', true);
    
    -- Return initialization status
    RETURN QUERY SELECT 
        'status'::TEXT,
        'context_initialized'::TEXT,
        COALESCE(v_initialized, 'false')::TEXT;
    
    -- Return app context variables
    RETURN QUERY SELECT 
        'app'::TEXT,
        'current_user_id'::TEXT,
        current_setting('app.current_user_id', true);
    
    RETURN QUERY SELECT 
        'app'::TEXT,
        'current_external_id'::TEXT,
        current_setting('app.current_external_id', true);
    
    RETURN QUERY SELECT 
        'app'::TEXT,
        'user_permissions'::TEXT,
        current_setting('app.user_permissions', true);
    
    RETURN QUERY SELECT 
        'app'::TEXT,
        'oauth_scopes'::TEXT,
        current_setting('app.oauth_scopes', true);
    
    -- Return common JWT claims (already normalized by rbac.uid())
    v_jwt_claims := ARRAY[
        'sub',
        'email',
        'email_verified',
        'name',
        'given_name',
        'family_name',
        'picture',
        'iss',
        'aud',
        'exp',
        'iat',
        'role'
    ];
    
    FOREACH v_claim IN ARRAY v_jwt_claims
    LOOP
        v_claim_value := current_setting('request.jwt.claim.' || v_claim, true);
        IF v_claim_value IS NOT NULL AND v_claim_value != '' THEN
            RETURN QUERY SELECT 
                'jwt'::TEXT,
                v_claim::TEXT,
                v_claim_value::TEXT;
        END IF;
    END LOOP;
    
    RETURN;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = rbac, public;

COMMENT ON FUNCTION rbac.whoami IS 
'Returns all context information: app session variables, JWT claims, and cached permissions. Requires authentication.';

-- =====================================================
-- AUTO-GRANT NEW PERMISSIONS TO ADMINISTRATOR ROLE
-- =====================================================

-- Trigger function to automatically grant new permissions to Administrator role
CREATE OR REPLACE FUNCTION rbac.grant_permission_to_administrator()
RETURNS TRIGGER AS $$
DECLARE
    v_administrator_role_id INTEGER;
BEGIN
    -- Get Administrator role id (role_name = 'Administrator')
    SELECT id INTO v_administrator_role_id
    FROM roles
    WHERE role_name = 'Administrator';
    
    -- If Administrator role exists, grant the new permission to it
    IF v_administrator_role_id IS NOT NULL THEN
        -- Upsert into role_permissions - insert or update if already exists
        INSERT INTO role_permissions (role_id, permission_id)
        VALUES (v_administrator_role_id, NEW.id)
        ON CONFLICT (role_id, permission_id) 
        DO UPDATE SET granted_at = CURRENT_TIMESTAMP;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SET search_path = rbac, public;

COMMENT ON FUNCTION rbac.grant_permission_to_administrator IS 
'Automatically grants newly created permissions to the Administrator role';

-- Apply trigger AFTER INSERT on permissions table
CREATE TRIGGER auto_grant_permission_to_administrator
    AFTER INSERT ON permissions
    FOR EACH ROW
    EXECUTE FUNCTION rbac.grant_permission_to_administrator();

-- Revoke default PUBLIC execute on all rbac functions defined above
-- Must come AFTER all CREATE FUNCTION statements
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA rbac FROM PUBLIC;

`,
    "0040_rbac_seed": `-- =====================================================
-- Description: Seeds initial modules, permissions, roles, and their relationships
-- =====================================================


-- =====================================================
-- SEED MODULES
-- =====================================================

INSERT INTO modules (id, module_name, module_slug, description, view_permission, logo_url, logo_color, home_page) VALUES
    (1, '_core', 'admin', 'Administration', 'admin', 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHdpZHRoPSIyNCIgaGVpZ2h0PSIyNCIgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9IiNmZmZmZmYiIHN0cm9rZS13aWR0aD0iMiIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIiBzdHJva2UtbGluZWpvaW49InJvdW5kIiBjbGFzcz0ibHVjaWRlIGx1Y2lkZS1zZXR0aW5ncy1pY29uIGx1Y2lkZS1zZXR0aW5ncyI+PHBhdGggZD0iTTkuNjcxIDQuMTM2YTIuMzQgMi4zNCAwIDAgMSA0LjY1OSAwIDIuMzQgMi4zNCAwIDAgMCAzLjMxOSAxLjkxNSAyLjM0IDIuMzQgMCAwIDEgMi4zMyA0LjAzMyAyLjM0IDIuMzQgMCAwIDAgMCAzLjgzMSAyLjM0IDIuMzQgMCAwIDEtMi4zMyA0LjAzMyAyLjM0IDIuMzQgMCAwIDAtMy4zMTkgMS45MTUgMi4zNCAyLjM0IDAgMCAxLTQuNjU5IDAgMi4zNCAyLjM0IDAgMCAwLTMuMzItMS45MTUgMi4zNCAyLjM0IDAgMCAxLTIuMzMtNC4wMzMgMi4zNCAyLjM0IDAgMCAwIDAtMy44MzFBMi4zNCAyLjM0IDAgMCAxIDYuMzUgNi4wNTFhMi4zNCAyLjM0IDAgMCAwIDMuMzE5LTEuOTE1Ii8+PGNpcmNsZSBjeD0iMTIiIGN5PSIxMiIgcj0iMyIvPjwvc3ZnPg==', '#e42528', '/admin/users');

-- =====================================================
-- SEED PERMISSIONS
-- =====================================================

INSERT INTO permissions (id, permission_name, description, module_id) VALUES
    (1, 'user:read', 'Read user information', 1),
    (2, 'user:manage', 'Manage users (includes read, create, update, delete)', 1),
    (3, 'public:read', 'Read public information', 1),
    (4, 'admin', 'Manage administrative functions', 1);

-- =====================================================
-- SEED PERMISSION HIERARCHY
-- =====================================================
-- user:manage (Id=2) implies user:read (Id=1)

INSERT INTO permission_hierarchy (including_permission_id, included_permission_id) VALUES
    (2, 1);

-- =====================================================
-- SEED ROLES
-- =====================================================

INSERT INTO roles (id, role_name, description, origin, module_id) VALUES
    (1, 'User', 'Standard user role with read-only access', 'system', 1),
    (2, 'Administrator', 'Administrator role with full management capabilities', 'system', 1);

-- =====================================================
-- SEED ROLE-PERMISSION MAPPINGS
-- =====================================================

-- User role gets user:read and public:read permissions
INSERT INTO role_permissions (role_id, permission_id) VALUES 
    (1, 1),
    (1, 3);

-- Administrator role gets user:manage, public:read, and admin permissions
INSERT INTO role_permissions (role_id, permission_id) VALUES 
    (2, 2),
    (2, 3),
    (2, 4);

-- =====================================================
-- SET MODULE FK REFERENCES
-- =====================================================

UPDATE modules SET
    admin_permission_id = (SELECT id FROM permissions WHERE permission_name = 'admin'),
    default_admin_role_id = (SELECT id FROM roles WHERE role_name = 'Administrator')
WHERE module_name = '_core';

-- =====================================================
-- RESET SEQUENCES (Reserve Ids < 10000 for internal use)
-- =====================================================

SELECT setval('permissions_id_seq', GREATEST(10000, (SELECT MAX(id) + 1 FROM permissions)));
SELECT setval('roles_id_seq', GREATEST(10000, (SELECT MAX(id) + 1 FROM roles)));
SELECT setval('modules_id_seq', GREATEST(1000, (SELECT MAX(id) + 1 FROM modules)));`,
    "0050_rbac_rls": `-- =====================================================
-- Description: Enable Row Level Security (RLS) policies
-- =====================================================

-- =====================================================
-- VERIFY BYPASSRLS ON FUNCTION OWNER
-- =====================================================
-- This check ensures SECURITY DEFINER functions can bypass RLS and avoid recursion
-- On Supabase: The 'postgres' role automatically has BYPASSRLS - no ALTER ROLE needed
-- On Neon: Roles created via Console/CLI/API inherit BYPASSRLS from 'neon_superuser' (projects after Aug 15, 2023)
-- On self-hosted: You may need to run: ALTER ROLE your_role BYPASSRLS;
-- Note: This verification will halt the script if BYPASSRLS is not available

DO $$
BEGIN
  ASSERT (
    SELECT rolbypassrls FROM pg_roles WHERE rolname = current_user
  ), 'Current role does not have BYPASSRLS privilege';
END $$;


-- =====================================================
-- ENABLE RLS ON ALL RBAC TABLES
-- =====================================================

ALTER TABLE modules ENABLE ROW LEVEL SECURITY;
ALTER TABLE permissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE users ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE role_permissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_permissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE permission_hierarchy ENABLE ROW LEVEL SECURITY;

-- =====================================================
-- MODULES - use view_permission column for SELECT, admin for others
-- =====================================================

CREATE POLICY modules_select_policy ON modules
    FOR SELECT
    TO semantius_user
    USING ((select rbac.has_any_permission('admin', view_permission)));

CREATE POLICY modules_insert_policy ON modules
    FOR INSERT
    TO semantius_user
    WITH CHECK ((select rbac.has_permission('admin')));

CREATE POLICY modules_update_policy ON modules
    FOR UPDATE
    TO semantius_user
    USING ((select rbac.has_permission('admin')))
    WITH CHECK ((select rbac.has_permission('admin')));

CREATE POLICY modules_delete_policy ON modules
    FOR DELETE
    TO semantius_user
    USING ((select rbac.has_permission('admin')));

-- =====================================================
-- USERS - user:read for SELECT, user:manage for others
-- =====================================================

CREATE POLICY users_select_policy ON users
    FOR SELECT
    TO semantius_user
    USING ((select rbac.has_permission('user:read')));

CREATE POLICY users_insert_policy ON users
    FOR INSERT
    TO semantius_user
    WITH CHECK ((select rbac.has_permission('user:manage')));

CREATE POLICY users_update_policy ON users
    FOR UPDATE
    TO semantius_user
    USING ((select rbac.has_permission('user:manage')))
    WITH CHECK ((select rbac.has_permission('user:manage')));

CREATE POLICY users_delete_policy ON users
    FOR DELETE
    TO semantius_user
    USING ((select rbac.has_permission('user:manage')));

-- =====================================================
-- PERMISSIONS - admin for all operations
-- =====================================================

CREATE POLICY permissions_select_policy ON permissions
    FOR SELECT
    TO semantius_user
    USING ((select rbac.has_permission('admin')));

CREATE POLICY permissions_insert_policy ON permissions
    FOR INSERT
    TO semantius_user
    WITH CHECK ((select rbac.has_permission('admin')));

CREATE POLICY permissions_update_policy ON permissions
    FOR UPDATE
    TO semantius_user
    USING ((select rbac.has_permission('admin')))
    WITH CHECK ((select rbac.has_permission('admin')));

CREATE POLICY permissions_delete_policy ON permissions
    FOR DELETE
    TO semantius_user
    USING ((select rbac.has_permission('admin')));

-- =====================================================
-- ROLES - admin for all operations
-- =====================================================

CREATE POLICY roles_select_policy ON roles
    FOR SELECT
    TO semantius_user
    USING ((select rbac.has_permission('admin')));

CREATE POLICY roles_insert_policy ON roles
    FOR INSERT
    TO semantius_user
    WITH CHECK ((select rbac.has_permission('admin')));

CREATE POLICY roles_update_policy ON roles
    FOR UPDATE
    TO semantius_user
    USING ((select rbac.has_permission('admin')))
    WITH CHECK ((select rbac.has_permission('admin')));

CREATE POLICY roles_delete_policy ON roles
    FOR DELETE
    TO semantius_user
    USING ((select rbac.has_permission('admin')));

-- =====================================================
-- USER_ROLES - admin for all operations
-- =====================================================

CREATE POLICY user_roles_select_policy ON user_roles
    FOR SELECT
    TO semantius_user
    USING ((select rbac.has_permission('admin')));

CREATE POLICY user_roles_insert_policy ON user_roles
    FOR INSERT
    TO semantius_user
    WITH CHECK ((select rbac.has_permission('admin')));

CREATE POLICY user_roles_update_policy ON user_roles
    FOR UPDATE
    TO semantius_user
    USING ((select rbac.has_permission('admin')))
    WITH CHECK ((select rbac.has_permission('admin')));

CREATE POLICY user_roles_delete_policy ON user_roles
    FOR DELETE
    TO semantius_user
    USING ((select rbac.has_permission('admin')));

-- =====================================================
-- ROLE_PERMISSIONS - admin for all operations
-- =====================================================

CREATE POLICY role_permissions_select_policy ON role_permissions
    FOR SELECT
    TO semantius_user
    USING ((select rbac.has_permission('admin')));

CREATE POLICY role_permissions_insert_policy ON role_permissions
    FOR INSERT
    TO semantius_user
    WITH CHECK ((select rbac.has_permission('admin')));

CREATE POLICY role_permissions_update_policy ON role_permissions
    FOR UPDATE
    TO semantius_user
    USING ((select rbac.has_permission('admin')))
    WITH CHECK ((select rbac.has_permission('admin')));

CREATE POLICY role_permissions_delete_policy ON role_permissions
    FOR DELETE
    TO semantius_user
    USING ((select rbac.has_permission('admin')));

-- =====================================================
-- USER_PERMISSIONS - admin for all operations
-- =====================================================

CREATE POLICY user_permissions_select_policy ON user_permissions
    FOR SELECT
    TO semantius_user
    USING ((select rbac.has_permission('admin')));

CREATE POLICY user_permissions_insert_policy ON user_permissions
    FOR INSERT
    TO semantius_user
    WITH CHECK ((select rbac.has_permission('admin')));

CREATE POLICY user_permissions_update_policy ON user_permissions
    FOR UPDATE
    TO semantius_user
    USING ((select rbac.has_permission('admin')))
    WITH CHECK ((select rbac.has_permission('admin')));

CREATE POLICY user_permissions_delete_policy ON user_permissions
    FOR DELETE
    TO semantius_user
    USING ((select rbac.has_permission('admin')));

-- =====================================================
-- PERMISSION_HIERARCHY - admin for all operations
-- =====================================================

CREATE POLICY permission_hierarchy_select_policy ON permission_hierarchy
    FOR SELECT
    TO semantius_user
    USING ((select rbac.has_permission('admin')));

CREATE POLICY permission_hierarchy_insert_policy ON permission_hierarchy
    FOR INSERT
    TO semantius_user
    WITH CHECK ((select rbac.has_permission('admin')));

CREATE POLICY permission_hierarchy_update_policy ON permission_hierarchy
    FOR UPDATE
    TO semantius_user
    USING ((select rbac.has_permission('admin')))
    WITH CHECK ((select rbac.has_permission('admin')));

CREATE POLICY permission_hierarchy_delete_policy ON permission_hierarchy
    FOR DELETE
    TO semantius_user
    USING ((select rbac.has_permission('admin')));

-- =====================================================
-- _VERSIONS - admin can query, deny insert/update/delete
-- =====================================================

CREATE POLICY versions_select_policy ON _versions
    FOR SELECT
    TO semantius_user
    USING ((select rbac.has_permission('admin')));

-- No INSERT, UPDATE, or DELETE policies - these operations are denied to all semantius_user roles

-- =====================================================
-- GRANT TABLE ACCESS TO semantius_user ROLE
-- =====================================================
-- Grant usage on public schema
GRANT USAGE ON SCHEMA public TO semantius_user;

-- Grant table permissions (RLS policies will further restrict access)
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO semantius_user;

-- Grant sequence usage for auto-increment columns
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO semantius_user;

-- Ensure future tables also get these grants
ALTER DEFAULT PRIVILEGES IN SCHEMA public 
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO semantius_user;

ALTER DEFAULT PRIVILEGES IN SCHEMA public 
    GRANT USAGE, SELECT ON SEQUENCES TO semantius_user;

-- =====================================================
-- TRIGGER: Auto-assign role 1 (User) to new users
-- =====================================================
-- When a new user is inserted, automatically assign them to role 1 (User role)
-- This ensures all users have at least the basic User role

CREATE OR REPLACE FUNCTION rbac.auto_assign_user_role()
RETURNS TRIGGER AS $$
DECLARE
    v_is_first_user BOOLEAN;
BEGIN
    -- Insert the user into role 1 (User) if not already assigned
    -- Note: Role ID 1 is explicitly seeded in 0040_rbac_seed.sql and reserved for the User role
    INSERT INTO user_roles (user_id, role_id)
    VALUES (NEW.id, 1)
    ON CONFLICT (user_id, role_id) DO NOTHING;
    
    -- Check if this is the first user (no other users have last_seen set)
    -- If this is the first user, also assign Administrator role (role ID 2)
    SELECT NOT EXISTS (
        SELECT 1 FROM users 
        WHERE id != NEW.id 
        AND last_seen IS NOT NULL
    ) INTO v_is_first_user;
    
    IF v_is_first_user THEN
        -- Assign Administrator role (role ID 2) to the first user
        INSERT INTO user_roles (user_id, role_id)
        VALUES (NEW.id, 2)
        ON CONFLICT (user_id, role_id) DO NOTHING;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = rbac, public;

COMMENT ON FUNCTION rbac.auto_assign_user_role IS 
'Trigger function to automatically assign role 1 (User) to newly created users. Also assigns role 2 (Administrator) to the first user accessing the system.';

CREATE TRIGGER auto_assign_user_role_trigger
    AFTER INSERT ON users
    FOR EACH ROW
    EXECUTE FUNCTION rbac.auto_assign_user_role();

COMMENT ON TRIGGER auto_assign_user_role_trigger ON users IS
'Automatically assigns role 1 (User) to new users after insertion.';

-- =====================================================
-- TRIGGER: Prevent deletion of role 1 from any user
-- =====================================================
-- This ensures that no user can have their User role removed,
-- maintaining the security principle that all users must have basic access

CREATE OR REPLACE FUNCTION rbac.prevent_user_role_deletion()
RETURNS TRIGGER AS $$
BEGIN
    -- Check if attempting to delete role 1 (User role)
    -- Note: Role ID 1 is explicitly seeded in 0040_rbac_seed.sql and reserved for the User role
    IF OLD.role_id = 1 THEN
        -- Allow cascade when the user itself is being deleted
        IF NOT EXISTS (SELECT 1 FROM users WHERE id = OLD.user_id) THEN
            RETURN OLD;
        END IF;
        RAISE EXCEPTION 'Cannot delete role 1 (User) from user. All users must have the User role.'
            USING ERRCODE = 'P0001';
    END IF;
    
    RETURN OLD;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = rbac, public;

COMMENT ON FUNCTION rbac.prevent_user_role_deletion IS 
'Trigger function to prevent deletion of role 1 (User) from any user.';

CREATE TRIGGER prevent_user_role_deletion_trigger
    BEFORE DELETE ON user_roles
    FOR EACH ROW
    EXECUTE FUNCTION rbac.prevent_user_role_deletion();

COMMENT ON TRIGGER prevent_user_role_deletion_trigger ON user_roles IS
'Prevents deletion of role 1 (User) from any user in user_roles table.';

-- =====================================================
-- TRIGGER: Default assigned_by to current user
-- =====================================================
-- When a user_role record is inserted without an assigned_by value,
-- automatically set it to the current user ID from the session context

CREATE OR REPLACE FUNCTION rbac.default_assigned_by()
RETURNS TRIGGER AS $$
DECLARE
    v_current_user_id INTEGER;
BEGIN
    IF NEW.assigned_by IS NULL THEN
        BEGIN
            v_current_user_id := rbac.user_id();
        EXCEPTION WHEN OTHERS THEN
            v_current_user_id := NULL;
        END;
        IF v_current_user_id IS NOT NULL THEN
            NEW.assigned_by := v_current_user_id;
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = rbac, public;

COMMENT ON FUNCTION rbac.default_assigned_by IS
'Trigger function to default assigned_by to the current user ID when not explicitly provided.';

CREATE TRIGGER default_assigned_by_trigger
    BEFORE INSERT ON user_roles
    FOR EACH ROW
    EXECUTE FUNCTION rbac.default_assigned_by();

COMMENT ON TRIGGER default_assigned_by_trigger ON user_roles IS
'Defaults assigned_by to the current session user when not provided on insert.';

-- =====================================================
-- TRIGGER: Default granted_by to current user for user_permissions
-- =====================================================

CREATE OR REPLACE FUNCTION rbac.default_granted_by()
RETURNS TRIGGER AS $$
DECLARE
    v_current_user_id INTEGER;
BEGIN
    IF NEW.granted_by IS NULL THEN
        BEGIN
            v_current_user_id := rbac.user_id();
        EXCEPTION WHEN OTHERS THEN
            v_current_user_id := NULL;
        END;
        IF v_current_user_id IS NOT NULL THEN
            NEW.granted_by := v_current_user_id;
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = rbac, public;

COMMENT ON FUNCTION rbac.default_granted_by IS
'Trigger function to default granted_by to the current user ID when not explicitly provided.';

CREATE TRIGGER default_granted_by_trigger
    BEFORE INSERT ON user_permissions
    FOR EACH ROW
    EXECUTE FUNCTION rbac.default_granted_by();

COMMENT ON TRIGGER default_granted_by_trigger ON user_permissions IS
'Defaults granted_by to the current session user when not provided on insert.';

-- Revoke default PUBLIC execute on trigger functions defined in this file
REVOKE EXECUTE ON FUNCTION rbac.auto_assign_user_role() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rbac.prevent_user_role_deletion() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rbac.default_assigned_by() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rbac.default_granted_by() FROM PUBLIC;`,
    "0060_dd_schema": `-- =====================================================
-- DYNAMIC TABLE MANAGEMENT SCHEMA
-- =====================================================
-- This schema allows runtime definition of tables and their fields
-- Integrates with RBAC system for permission-based access control
-- =====================================================

-- =====================================================
-- ENTITIES TABLE
-- =====================================================
-- Stores metadata about dynamically created tables

CREATE TABLE IF NOT EXISTS entities (
    table_name TEXT PRIMARY KEY,
    singular TEXT NOT NULL DEFAULT '',
    plural TEXT DEFAULT '',  -- Nullable because trigger auto-sets it before constraint check
    singular_label TEXT NOT NULL DEFAULT '',
    plural_label TEXT NOT NULL DEFAULT '',
    icon_url TEXT DEFAULT '',
    description TEXT DEFAULT '',
    module_id INTEGER REFERENCES modules(id) ON DELETE SET NULL,
    view_permission TEXT NOT NULL DEFAULT 'public:read',
    edit_permission TEXT NOT NULL DEFAULT 'admin',
    id_column TEXT NOT NULL DEFAULT 'id',
    label_column TEXT NOT NULL DEFAULT 'label',
    managed BOOLEAN NOT NULL DEFAULT TRUE,
    searchable BOOLEAN NOT NULL DEFAULT FALSE,
    is_child BOOLEAN NOT NULL DEFAULT FALSE,
    edit_mode TEXT NOT NULL DEFAULT 'auto',
    cube_mode TEXT NOT NULL DEFAULT 'auto',
    audit_log BOOLEAN NOT NULL DEFAULT FALSE,
    computed_fields JSONB NOT NULL DEFAULT '[]'::jsonb,
    validation_rules JSONB NOT NULL DEFAULT '[]'::jsonb,
    select_rule JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    -- Validate table_name follows PostgreSQL naming conventions
    CONSTRAINT valid_table_name CHECK (table_name ~ '^[a-z_][a-z0-9_]*$'),

    -- Validate column names follow PostgreSQL naming conventions
    CONSTRAINT valid_id_column CHECK (id_column ~ '^[a-z_][a-z0-9_]*$'),
    CONSTRAINT valid_label_column CHECK (label_column ~ '^[a-z_][a-z0-9_]*$'),

    -- Ensure plural matches table_name (plural is auto-assigned and not changeable)
    CONSTRAINT plural_matches_table_name CHECK (plural = table_name),

    -- computed_fields and validation_rules must be JSON arrays
    CONSTRAINT computed_fields_is_array CHECK (jsonb_typeof(computed_fields) = 'array'),
    CONSTRAINT validation_rules_is_array CHECK (jsonb_typeof(validation_rules) = 'array'),
    -- select_rule must be a JSON object
    CONSTRAINT select_rule_is_object CHECK (jsonb_typeof(select_rule) = 'object')
);

CREATE INDEX idx_entities_module ON entities(module_id);

COMMENT ON TABLE entities IS 
'Metadata for dynamically created tables. Each row triggers table creation and RLS policy setup.';

COMMENT ON COLUMN entities.table_name IS 'Physical table name in database (lowercase, underscores only)';
COMMENT ON COLUMN entities.singular IS 'Singular form of table name (e.g., customer for customers table)';
COMMENT ON COLUMN entities.plural IS 'Plural form of table name, auto-assigned to table_name (e.g., customers)';
COMMENT ON COLUMN entities.singular_label IS 'Human-readable singular label for UI/reports (e.g., Customer)';
COMMENT ON COLUMN entities.plural_label IS 'Human-readable plural label for UI/reports (e.g., Customers)';
COMMENT ON COLUMN entities.icon_url IS 'Optional URL or path to icon for this table';
COMMENT ON COLUMN entities.view_permission IS 'Permission required to SELECT from this table';
COMMENT ON COLUMN entities.edit_permission IS 'Permission required to INSERT/UPDATE/DELETE from this table';
COMMENT ON COLUMN entities.id_column IS 'Name of primary key column (created automatically)';
COMMENT ON COLUMN entities.label_column IS 'Name of label/display column (created automatically)';
COMMENT ON COLUMN entities.managed IS 'When false, automatic DDL execution for table and field changes is disabled';
COMMENT ON COLUMN entities.audit_log IS 'When TRUE, DML operations on this table are logged to audit_record_logs';
COMMENT ON COLUMN entities.computed_fields IS
'Ordered list of {name, jsonlogic, description?} entries. Each entry derives the named field from the same record before write. Default [].';
COMMENT ON COLUMN entities.validation_rules IS
'Ordered list of {code, message, jsonlogic, description?} entries. Each entry must evaluate truthy for the write to succeed. Default [].';
COMMENT ON COLUMN entities.select_rule IS
'JsonLogic rule evaluated per row for FOR SELECT RLS policy. When non-empty, generates a policy function that returns true only when the rule evaluates truthy. Default {}.';

-- =====================================================
-- FIELDS TABLE
-- =====================================================
-- Stores metadata about fields in dynamically created tables

CREATE TABLE IF NOT EXISTS fields (
    id VARCHAR GENERATED ALWAYS AS (table_name || '.' || field_name) STORED PRIMARY KEY,
    table_name TEXT NOT NULL REFERENCES entities(table_name) ON DELETE CASCADE,
    field_name TEXT NOT NULL DEFAULT '',
    title TEXT NOT NULL DEFAULT '',
    description TEXT DEFAULT '',
    format TEXT NOT NULL DEFAULT 'text',
    is_pk BOOLEAN NOT NULL DEFAULT FALSE,
    default_value TEXT DEFAULT '',
    field_order INTEGER NOT NULL DEFAULT 0,
    input_type TEXT NOT NULL DEFAULT 'default',
    width TEXT NOT NULL DEFAULT 'default',
    ctype TEXT DEFAULT '',
    is_core BOOLEAN NOT NULL DEFAULT FALSE,
    searchable BOOLEAN NOT NULL DEFAULT FALSE,
    enum_values JSONB DEFAULT NULL,
    "precision" SMALLINT NOT NULL DEFAULT 2,
    reference_table TEXT NOT NULL DEFAULT '',  -- Empty string means no reference (consistent with no-null policy)
    reference_delete_mode TEXT NOT NULL DEFAULT 'restrict',
    relationship_label TEXT NOT NULL DEFAULT 'has',
    singular_label_parent TEXT NOT NULL DEFAULT '',
    plural_label_parent TEXT NOT NULL DEFAULT '',
    unique_value BOOLEAN NOT NULL DEFAULT FALSE,
    cube_type TEXT NOT NULL DEFAULT 'auto',
    input_type_rule JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    
    -- Unique constraint on table_name and field_name
    CONSTRAINT fields_table_field_unique UNIQUE (table_name, field_name),
    
    -- Validate field_name follows PostgreSQL naming conventions
    CONSTRAINT valid_field_name CHECK (field_name ~ '^[a-z_][a-z0-9_]*$'),
    
    -- Validate format is a known format
    CONSTRAINT valid_format CHECK (
        format IN (
            -- Custom SemSchema formats
            'json', 'html', 'text', 'multiline', 'code', 'jsonata', 'reference', 'parent', 'enum',
            -- Standard JSON Schema formats
            'date', 'time', 'date-time', 'duration',
            'uri', 'uri-reference', 'uri-template', 'url',
            'email', 'hostname', 'ipv4', 'ipv6', 'regex', 'uuid',
            'json-pointer', 'json-pointer-uri-fragment', 'relative-json-pointer',
            'byte', 'int32', 'int64', 'float', 'double', 'password', 'binary',
            -- Primitive types from JSON Schema
            'string', 'number', 'integer', 'boolean', 'object', 'array', 'null'
        )
    ),
    

    
    -- Ensure precision is within a reasonable range for NUMERIC scale
    CONSTRAINT valid_precision CHECK ("precision" >= 0 AND "precision" <= 18),

    -- Ensure reference_table is set when format is 'reference' or 'parent'
    CONSTRAINT reference_requires_table CHECK (
        (format IN ('reference', 'parent') AND reference_table != '') OR (format NOT IN ('reference', 'parent'))
    ),

    -- Ensure format is 'reference' or 'parent' when reference_table is set
    CONSTRAINT reference_table_requires_reference_format CHECK (
        (reference_table != '' AND format IN ('reference', 'parent')) OR (reference_table = '')
    )
);

-- Add this partial unique index:
CREATE UNIQUE INDEX one_pk_per_table_idx
ON fields (table_name)
WHERE is_pk;-- Ensure only one primary key per table    

CREATE INDEX idx_fields_table ON fields(table_name);
CREATE INDEX idx_fields_name ON fields(field_name);
CREATE INDEX idx_fields_is_pk ON fields(is_pk) WHERE is_pk = TRUE;
CREATE INDEX idx_fields_reference_table ON fields(reference_table) WHERE reference_table != '';

COMMENT ON TABLE fields IS 
'Metadata for fields in dynamically created tables. Each row triggers ALTER TABLE to add column.';

COMMENT ON COLUMN fields.field_name IS 'Physical column name in database (lowercase, underscores only)';
COMMENT ON COLUMN fields.title IS 'Human-readable display name for the field';
COMMENT ON COLUMN fields.description IS 'Detailed description of the field (used for COMMENT ON COLUMN)';
COMMENT ON COLUMN fields.format IS 'JSON Schema format or primitive type for the field';
COMMENT ON COLUMN fields.is_pk IS 'Whether this field is the primary key';
COMMENT ON COLUMN fields.default_value IS 'Default value for the field (as SQL expression)';
COMMENT ON COLUMN fields.field_order IS 'Display order for the field';
COMMENT ON COLUMN fields.input_type IS 'Input type for UI rendering: default, required, readonly, disabled, or hidden';
COMMENT ON COLUMN fields.width IS 'Display width for UI rendering: default (auto), s (small), m (medium), or w (wide)';
COMMENT ON COLUMN fields.ctype IS 'Special column type: empty string (normal field), id (primary key), or label (display field)';
COMMENT ON COLUMN fields.is_core IS 'Whether this is a core system field (id, label, created_at, updated_at) that cannot be deleted or have structural changes';
COMMENT ON COLUMN fields.enum_values IS 'JSON array of allowed enum values for this field (e.g., ["active", "inactive", "pending"])';
COMMENT ON COLUMN fields."precision" IS 'Decimal scale (digits after the decimal point) used when generating NUMERIC columns for number formats. Default 2 (currency-style).';
COMMENT ON COLUMN fields.input_type_rule IS 'JsonLogic condition for field visibility in the UI. Evaluated client-side to show/hide the field.';
COMMENT ON COLUMN fields.reference_table IS 'Table name this field references (for foreign key relationships). Must reference entities.table_name when format is "reference". Empty string means no reference.';
COMMENT ON COLUMN fields.reference_delete_mode IS 'Controls ON DELETE behavior for foreign key: "restrict" (RESTRICT) or "clear" (SET NULL). Default: restrict.';
COMMENT ON COLUMN fields.relationship_label IS 'Verb describing what the referenced entity does to/with this entity (e.g. "employs", "heads"). Used for ER diagram and navigation labels.';
COMMENT ON COLUMN fields.singular_label_parent IS 'Custom singular label for the parent entity when format is ''parent''. Overrides the default singular_label from the parent entity when set.';
COMMENT ON COLUMN fields.plural_label_parent IS 'Custom plural label for the parent entity when format is ''parent''. Overrides the default plural_label from the parent entity when set.';
COMMENT ON COLUMN fields.unique_value IS 'When TRUE, enforces a partial unique index on this column. For string types, NULL and empty string values are excluded from the uniqueness check.';

-- Create trigger function to validate reference_table when not empty
-- We use a trigger instead of CHECK constraint to allow subqueries
CREATE OR REPLACE FUNCTION validate_reference_table()
RETURNS TRIGGER AS $$
BEGIN
    -- Only validate if reference_table is not empty
    IF NEW.reference_table != '' THEN
        -- Check if the referenced table exists
        IF NOT EXISTS (SELECT 1 FROM entities WHERE table_name = NEW.reference_table) THEN
            RAISE EXCEPTION 'Referenced table "%" not found in entities', NEW.reference_table;
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SET search_path = public;

CREATE TRIGGER validate_reference_table_trigger
    BEFORE INSERT OR UPDATE ON fields
    FOR EACH ROW
    EXECUTE FUNCTION validate_reference_table();

-- =====================================================
-- ENABLE RLS ON METADATA TABLES
-- =====================================================

ALTER TABLE entities ENABLE ROW LEVEL SECURITY;
ALTER TABLE fields ENABLE ROW LEVEL SECURITY;

-- =====================================================
-- RLS POLICIES FOR ENTITIES
-- =====================================================

CREATE POLICY entities_select_policy ON entities
    FOR SELECT
    TO semantius_user
    USING (rbac.has_permission('public:read'));

CREATE POLICY entities_insert_policy ON entities
    FOR INSERT
    TO semantius_user
    WITH CHECK (rbac.has_permission('admin'));

CREATE POLICY entities_update_policy ON entities
    FOR UPDATE
    TO semantius_user
    USING (rbac.has_permission('admin'))
    WITH CHECK (rbac.has_permission('admin'));

CREATE POLICY entities_delete_policy ON entities
    FOR DELETE
    TO semantius_user
    USING (rbac.has_permission('admin'));

-- =====================================================
-- RLS POLICIES FOR FIELDS
-- =====================================================

CREATE POLICY fields_select_policy ON fields
    FOR SELECT
    TO semantius_user
    USING (rbac.has_permission('public:read'));

CREATE POLICY fields_insert_policy ON fields
    FOR INSERT
    TO semantius_user
    WITH CHECK (rbac.has_permission('admin'));

CREATE POLICY fields_update_policy ON fields
    FOR UPDATE
    TO semantius_user
    USING (rbac.has_permission('admin'))
    WITH CHECK (rbac.has_permission('admin'));

CREATE POLICY fields_delete_policy ON fields
    FOR DELETE
    TO semantius_user
    USING (rbac.has_permission('admin'));

-- =====================================================
-- AUTO-SET PLURAL TRIGGER
-- =====================================================
-- Automatically sets plural to match table_name on INSERT/UPDATE
-- This ensures plural always equals table_name and ignores user input

CREATE OR REPLACE FUNCTION auto_set_plural()
RETURNS TRIGGER AS $$
BEGIN
    -- Always set plural to table_name, ignoring any provided value
    NEW.plural := NEW.table_name;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SET search_path = public;

COMMENT ON FUNCTION auto_set_plural IS 
'Trigger function that automatically sets plural column to match table_name, ignoring user input';

CREATE TRIGGER auto_set_plural_trigger
    BEFORE INSERT OR UPDATE ON entities
    FOR EACH ROW
    EXECUTE FUNCTION auto_set_plural();

COMMENT ON TRIGGER auto_set_plural_trigger ON entities IS
'Automatically sets plural to match table_name on INSERT/UPDATE';

-- =====================================================
-- UPDATE TIMESTAMP TRIGGERS
-- =====================================================
-- Uses common.update_updated_at_column() from common schema

CREATE TRIGGER update_entities_updated_at
    BEFORE UPDATE ON entities
    FOR EACH ROW
    EXECUTE FUNCTION common.update_updated_at_column();

CREATE TRIGGER update_fields_updated_at
    BEFORE UPDATE ON fields
    FOR EACH ROW
    EXECUTE FUNCTION common.update_updated_at_column();

-- =====================================================
-- SEED CORE TABLES METADATA
-- =====================================================
-- Add metadata for core RBAC and dynamic table system tables
-- These are marked with is_core=true to indicate they are system tables

-- Insert entities metadata for core tables
INSERT INTO entities (table_name, singular, plural, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column, validation_rules)
VALUES 
    ('entities', 'entity', 'entities', 'Entity', 'Entities', 'Metadata for dynamically created tables', (SELECT id FROM modules WHERE module_name = '_core'), 'public:read', 'admin', 'table_name', 'singular_label', '[]'::jsonb),
    ('fields', 'field', 'fields', 'Field', 'Fields', 'Metadata for fields in dynamically created tables', (SELECT id FROM modules WHERE module_name = '_core'), 'public:read', 'admin', 'id', 'title', '[]'::jsonb),
    ('users', 'user', 'users', 'User', 'Users', 'Users and agents', (SELECT id FROM modules WHERE module_name = '_core'), 'user:read', 'user:manage', 'id', 'email', '[]'::jsonb),
    ('modules', 'module', 'modules', 'Module', 'Modules', 'Logical modules that group related roles and permissions', (SELECT id FROM modules WHERE module_name = '_core'), 'admin', 'admin', 'id', 'module_name', '[]'::jsonb),
    ('roles', 'role', 'roles', 'Role', 'Roles', 'Groups of permissions that can be assigned to users', (SELECT id FROM modules WHERE module_name = '_core'), 'admin', 'admin', 'id', 'role_name',
     '[{"code":"origin_immutable_roles","message":"roles.origin is set on INSERT and cannot be changed","source_module":"platform","jsonlogic":{"if":[{"value_changed":"origin"},{"==":[{"var":"$old"},null]},true]}},{"code":"system_role_slug_immutable","message":"system role slugs cannot be changed after creation","source_module":"platform","jsonlogic":{"if":[{"and":[{"value_changed":"slug"},{"==":[{"var":"origin"},"system"]}]},{"==":[{"var":"$old"},null]},true]}}]'::jsonb),
    ('permissions', 'permission', 'permissions', 'Permission', 'Permissions', 'System permissions that can be assigned to roles', (SELECT id FROM modules WHERE module_name = '_core'), 'admin', 'admin', 'id', 'permission_name', '[]'::jsonb),
    ('user_roles', 'user_role', 'user_roles', 'User Role', 'User Roles', 'Many-to-many mapping between users and roles', (SELECT id FROM modules WHERE module_name = '_core'), 'admin', 'admin', 'id', 'id', '[]'::jsonb),
    ('role_permissions', 'role_permission', 'role_permissions', 'Role Permission', 'Role Permissions', 'Many-to-many mapping between roles and permissions', (SELECT id FROM modules WHERE module_name = '_core'), 'admin', 'admin', 'id', 'id', '[]'::jsonb),
    ('user_permissions', 'user_permission', 'user_permissions', 'User Permission', 'User Permissions', 'Many-to-many mapping between users and permissions for direct per-user permission grants', (SELECT id FROM modules WHERE module_name = '_core'), 'admin', 'admin', 'id', 'id', '[]'::jsonb),
    ('permission_hierarchy', 'permission_hierarchy', 'permission_hierarchy', 'Permission Hierarchy', 'Permission Hierarchy', 'Defines permission inclusion (including permission implies included permissions)', (SELECT id FROM modules WHERE module_name = '_core'), 'admin', 'admin', 'id', 'id',
     '[{"code":"origin_immutable_hierarchy","message":"permission_hierarchy.origin is set on INSERT and cannot be changed","source_module":"platform","jsonlogic":{"if":[{"value_changed":"origin"},{"==":[{"var":"$old"},null]},true]}}]'::jsonb);

-- =====================================================
-- ADD ENUM CONSTRAINTS AND INSERT FIELD METADATA USING DRY PRINCIPLE
-- =====================================================
-- Define enum value arrays ONCE and use for both CHECK constraints and field metadata
-- This ensures no duplication and maintains consistency

DO $$
DECLARE
  -- Define all enum value arrays in one place
  format_values TEXT[] := ARRAY[
    -- Custom SemSchema formats
    'json', 'html', 'text', 'multiline', 'code', 'jsonata', 'reference', 'parent', 'enum',
    -- Standard JSON Schema formats
    'date', 'time', 'date-time', 'duration',
    'uri', 'uri-reference', 'uri-template', 'url',
    'email', 'hostname', 'ipv4', 'ipv6', 'regex', 'uuid',
    'json-pointer', 'json-pointer-uri-fragment', 'relative-json-pointer',
    'byte', 'int32', 'int64', 'float', 'double', 'password', 'binary',
    -- Primitive types from JSON Schema
    'string', 'number', 'integer', 'boolean', 'object', 'array', 'null'
  ];
  input_type_values TEXT[] := ARRAY['default', 'required', 'readonly', 'disabled', 'hidden'];
  width_values TEXT[] := ARRAY['default', 's', 'm', 'w'];
  ctype_values TEXT[] := ARRAY['', 'id', 'label'];
  reference_delete_mode_values TEXT[] := ARRAY['', 'restrict', 'clear', 'cascade'];
  edit_mode_values TEXT[] := ARRAY['auto', 'sidebar', 'modal', 'page'];
  cube_mode_values TEXT[] := ARRAY['disabled', 'auto'];
  cube_type_values TEXT[] := ARRAY['auto', 'dimension', 'measure', 'disabled'];
BEGIN
  -- Add enum constraints
  EXECUTE format(
    'ALTER TABLE fields ADD CONSTRAINT valid_input_type CHECK (input_type = ANY(%L))',
    input_type_values
  );
  
  EXECUTE format(
    'ALTER TABLE fields ADD CONSTRAINT valid_width CHECK (width = ANY(%L))',
    width_values
  );
  
  EXECUTE format(
    'ALTER TABLE fields ADD CONSTRAINT valid_ctype CHECK (ctype = ANY(%L))',
    ctype_values
  );
  
  EXECUTE format(
    'ALTER TABLE fields ADD CONSTRAINT valid_reference_delete_mode CHECK (reference_delete_mode = ANY(%L))',
    reference_delete_mode_values
  );

  EXECUTE format(
    'ALTER TABLE entities ADD CONSTRAINT valid_edit_mode CHECK (edit_mode = ANY(%L))',
    edit_mode_values
  );

  EXECUTE format(
    'ALTER TABLE entities ADD CONSTRAINT valid_cube_mode CHECK (cube_mode = ANY(%L))',
    cube_mode_values
  );

  EXECUTE format(
    'ALTER TABLE fields ADD CONSTRAINT valid_cube_type CHECK (cube_type = ANY(%L))',
    cube_type_values
  );
  
  -- Insert field metadata for fields table using the same enum arrays
  -- Note: fields table has a generated primary key (id = table_name || '.' || field_name)
  -- All field definitions for the fields table are consolidated here with NO duplication
  INSERT INTO fields (table_name, field_name, title, description, default_value, format, is_pk, field_order, input_type, width, ctype, is_core, searchable, enum_values, reference_table, reference_delete_mode, relationship_label)
  VALUES
      ('fields', 'id',                   'Id',                   'Generated identifier (table_name.field_name)',                           '',         'text',      TRUE,  10,     'readonly', 'default', 'id',   TRUE,  FALSE, NULL,                            '',          '',        ''),
      ('fields', 'table_name',           'Table Name',           '',                                                                       '',         'parent',    FALSE, 20,     'default',  'default', NULL,   TRUE,  TRUE,  NULL,                            'entities',  'cascade', 'has fields'),
      ('fields', 'field_name',           'Field Name',           'Physical column name in database',                                       '',         'text',      FALSE, 30,     'required', 'default', NULL,   TRUE,  TRUE,  NULL,                            '',          '',        ''),
      ('fields', 'format',               'Format',               'JSON Schema format or primitive type',                                   'text',     'enum',      FALSE, 40,     'required', 'default', NULL,   TRUE,  FALSE, to_jsonb(format_values),         '',          '',        ''),
      ('fields', 'title',                'Title',                'Human-readable display name for the field',                              '',         'text',      FALSE, 50,     'required', 'default', 'label',TRUE,  TRUE,  NULL,                            '',          '',        ''),
      ('fields', 'description',          'Description',          '',                                                                       '',         'text',      FALSE, 60,     'default',  'w',       NULL,   TRUE,  TRUE,  NULL,                            '',          '',        ''),
      ('fields', 'is_pk',                'Is Primary Key',       '',                                                                       '',         'boolean',   FALSE, 70,     'default',  'default', NULL,   TRUE,  FALSE, NULL,                            '',          '',        ''),
      ('fields', 'default_value',        'Default Value',        '',                                                                       '',         'text',      FALSE, 90,     'hidden',   'default', NULL,   TRUE,  FALSE, NULL,                            '',          '',        ''),
      ('fields', 'field_order',          'Field Order',          '',                                                                       '',         'int32',     FALSE, 100,    'default',  'default', NULL,   TRUE,  FALSE, NULL,                            '',          '',        ''),
      ('fields', 'input_type',           'Input Type',           '',                                                                       'default',  'enum',      FALSE, 110,    'required', 'default', NULL,   TRUE,  FALSE, to_jsonb(input_type_values),     '',          '',        ''),
      ('fields', 'width',                'Width',                '',                                                                       'default',  'enum',      FALSE, 120,    'required', 'default', NULL,   TRUE,  FALSE, to_jsonb(width_values),          '',          '',        ''),
      ('fields', 'ctype',                'Column Type',          'Special column type (id, label, etc.)',                                  '',         'enum',      FALSE, 130,    'default',  'default', NULL,   TRUE,  FALSE, to_jsonb(ctype_values),          '',          '',        ''),
      ('fields', 'is_core',              'Is Core',              '',                                                                       '',         'boolean',   FALSE, 140,    'default',  'default', NULL,   TRUE,  FALSE, NULL,                            '',          '',        ''),
      ('fields', 'searchable',           'Searchable',           'Whether field is included in full-text search',                          '',         'boolean',   FALSE, 150,    'hidden',   'default', NULL,   TRUE,  FALSE, NULL,                            '',          '',        ''),
      ('fields', 'enum_values',          'Enum Values',          'JSON array of allowed enum values',                                      '',         'json',      FALSE, 160,    'hidden',   'w',       NULL,   TRUE,  FALSE, NULL,                            '',          '',        ''),
      ('fields', 'precision',            'Precision',            'Decimal scale used when generating NUMERIC columns for number formats',  '2',        'int32',     FALSE, 170,    'hidden',   'default', NULL,   TRUE,  FALSE, NULL,                            '',          '',        ''),
      ('fields', 'reference_table',      'Reference Table',      'Table name for foreign key relationships',                               '',         'text',      FALSE, 180,    'hidden',   'default', NULL,   TRUE,  FALSE, NULL,                            '',          '',        ''),
      ('fields', 'reference_delete_mode','Reference Delete Mode','ON DELETE behavior: restrict, clear, or cascade',                        'restrict', 'enum',      FALSE, 190,    'hidden',   'default', NULL,   TRUE,  FALSE, to_jsonb(reference_delete_mode_values), '', '',     ''),
      ('fields', 'relationship_label',   'Relationship Label',   'Verb describing what the referenced entity does to/with this entity',   'has',      'text',      FALSE, 200,    'hidden',   'default', NULL,   TRUE,  FALSE, NULL,                            '',          '',        ''),
      ('fields', 'singular_label_parent','Singular Label Parent','Custom singular label for the parent entity (overrides default when set)','',        'text',      FALSE, 210,    'hidden',   'default', NULL,   TRUE,  FALSE, NULL,                            '',          '',        ''),
      ('fields', 'plural_label_parent',  'Plural Label Parent',  'Custom plural label for the parent entity (overrides default when set)', '',         'text',      FALSE, 220,    'hidden',   'default', NULL,   TRUE,  FALSE, NULL,                            '',          '',        ''),
      ('fields', 'unique_value',         'Unique Value',         'When TRUE, enforces a partial unique index (NULL and empty strings are not enforced)', '', 'boolean', FALSE, 230, 'hidden',  'default', NULL, TRUE, FALSE, NULL,                           '',          '',        ''),
      ('fields', 'cube_type',            'Cube Type',            '',                                                                       'auto',     'enum',      FALSE, 240,    'required', 'default', NULL,   TRUE,  FALSE, to_jsonb(cube_type_values),      '',          '',        ''),
      ('fields', 'input_type_rule',      'Input Type Rule',      'JsonLogic condition for field visibility',                               '',         'json',      FALSE, 250,    'default',  'w',       NULL,   TRUE,  FALSE, NULL,                            '',          '',        ''),
      ('fields', 'created_at',           'Created At',           '',                                                                       '',         'date-time', FALSE, 900000, 'disabled', 'default', NULL,   TRUE,  FALSE, NULL,                            '',          '',        ''),
      ('fields', 'updated_at',           'Updated At',           '',                                                                       '',         'date-time', FALSE, 900000, 'disabled', 'default', NULL,   TRUE,  FALSE, NULL,                            '',          '',        '');

  -- Insert edit_mode field metadata for entities table (uses edit_mode_values defined above)
  INSERT INTO fields (table_name, field_name, title, description, default_value, format, is_pk, field_order, input_type, width, ctype, is_core, searchable, enum_values, reference_table, reference_delete_mode, relationship_label)
  VALUES
      ('entities', 'edit_mode', 'Edit Mode', 'UI edit mode for records of this table: auto, sidebar, modal, or page', 'auto', 'enum', FALSE, 119, 'default', 'default', NULL, TRUE, FALSE, to_jsonb(edit_mode_values), '', '', ''),
      ('entities', 'cube_mode', 'Cube Mode', 'Cube mode for OLAP cube generation', 'auto', 'enum', FALSE, 121, 'default', 'default', NULL, TRUE, FALSE, to_jsonb(cube_mode_values), '', '', '');

  -- Conditional visibility rules for format-dependent fields on the fields table.
  -- These fields default to 'hidden' and become visible/required only when the
  -- selected format makes them meaningful.
  UPDATE fields SET input_type_rule = rule::jsonb
  FROM (VALUES
    ('enum_values',          '{"if":[{"==":[{"var":"format"},"enum"]},"required","hidden"]}'),
    ('precision',            '{"if":[{"==":[{"var":"format"},"number"]},"required","hidden"]}'),
    ('reference_table',      '{"if":[{"in":[{"var":"format"},["reference","parent"]]},"required","hidden"]}'),
    ('reference_delete_mode','{"if":[{"in":[{"var":"format"},["reference","parent"]]},"required","hidden"]}'),
    ('relationship_label',   '{"if":[{"in":[{"var":"format"},["reference","parent"]]},"required","hidden"]}'),
    ('singular_label_parent','{"if":[{"==":[{"var":"format"},"parent"]},"default","hidden"]}'),
    ('plural_label_parent',  '{"if":[{"==":[{"var":"format"},"parent"]},"default","hidden"]}'),
    ('default_value',        '{"if":[{"!=":[{"var":"format"},"boolean"]},"default","hidden"]}'),
    ('searchable',           '{"if":[{"in":[{"var":"format"},["string","text","multiline","html","code"]]},"default","hidden"]}'),
    ('unique_value',         '{"if":[{"in":[{"var":"format"},["boolean","multiline","html","code","json","object","array"]]},"hidden","default"]}')
  ) AS r(field_name, rule)
  WHERE fields.table_name = 'fields' AND fields.field_name = r.field_name;
END $$;

-- Insert fields metadata for entities table
INSERT INTO fields (table_name, field_name, title, description, default_value, format, is_pk, field_order, input_type, width, ctype, is_core, searchable, reference_table, reference_delete_mode, relationship_label)
VALUES
    ('entities', 'table_name',     'Table Name',     'Physical table name in database',                       '',             'text',      TRUE,  1,   'required', 'default', 'id',   TRUE,  TRUE,  '', '',        ''),
    ('entities', 'singular',       'Singular',       'Singular form of table name',                           '',             'text',      FALSE, 10,  'required', 'default', NULL,   TRUE,  TRUE,  '', '',        ''),
    ('entities', 'plural',         'Plural',         'Plural form of table name, auto-assigned to table_name','',             'text',      FALSE, 20,  'readonly', 'default', NULL,   TRUE,  TRUE,  '', '',        ''),
    ('entities', 'singular_label', 'Singular Label', 'Human-readable singular label for UI/reports',          '',             'text',      FALSE, 30,  'default',  'default', 'label',TRUE,  TRUE,  '', '',        ''),
    ('entities', 'plural_label',   'Plural Label',   'Human-readable plural label for UI/reports',            '',             'text',      FALSE, 40,  'default',  'default', NULL,   TRUE,  TRUE,  '', '',        ''),
    ('entities', 'icon_url',       'Icon URL',       'Optional URL or path to icon for this table',           '',             'url',       FALSE, 50,  'default',  'w',       NULL,   TRUE,  FALSE, '', '',        ''),
    ('entities', 'description',    'Description',    '',                                                       '',             'text',      FALSE, 60,  'default',  'w',       NULL,   TRUE,  TRUE,  '', '',        ''),
    ('entities', 'module_id',      'Module Id',      '',                                                       '',             'reference', FALSE, 70,  'default',  'default', NULL,   TRUE,  FALSE, 'modules', 'clear', 'contains'),
    ('entities', 'view_permission','View Permission', 'Permission required to SELECT from this table',         'public:read',  'text',      FALSE, 80,  'default',  'default', NULL,   TRUE,  FALSE, '', '',        ''),
    ('entities', 'edit_permission','Edit Permission', 'Permission required to INSERT/UPDATE/DELETE from this table', 'admin', 'text',      FALSE, 90,  'default',  'default', NULL,   TRUE,  FALSE, '', '',        ''),
    ('entities', 'id_column',      'Id Column',      'Name of primary key column',                            'id',           'text',      FALSE, 100, 'default',  'default', NULL,   TRUE,  FALSE, '', '',        ''),
    ('entities', 'label_column',   'Label Column',   'Name of label/display column',                          'label',        'text',      FALSE, 110, 'default',  'default', NULL,   TRUE,  FALSE, '', '',        ''),
    ('entities', 'managed',        'Managed',        'When false, automatic DDL execution is disabled',       'true',         'boolean',   FALSE, 115, 'default',  'default', NULL,   TRUE,  FALSE, '', '',        ''),
    ('entities', 'searchable',     'Searchable',     'Whether table is included in full-text search (auto-computed)', '',    'boolean',   FALSE, 117, 'disabled', 'default', NULL,   TRUE,  FALSE, '', '',        ''),
    ('entities', 'is_child',       'Is Child',       'Whether table has any parent relationships (auto-computed)', '',       'boolean',   FALSE, 118, 'disabled', 'default', NULL,   TRUE,  FALSE, '', '',        ''),
    ('entities', 'computed_fields','Computed Fields', 'JsonLogic derivations evaluated on every write',        '',             'json',      FALSE, 123, 'default',  'w',       NULL,   TRUE,  FALSE, '', '',        ''),
    ('entities', 'validation_rules','Validation Rules','JsonLogic invariants that must hold for the write to succeed','',     'json',      FALSE, 124, 'default',  'w',       NULL,   TRUE,  FALSE, '', '',        ''),
    ('entities', 'select_rule',    'Select Rule',    'JsonLogic rule for per-row FOR SELECT RLS policy',         '',             'json',      FALSE, 125, 'default',  'w',       NULL,   TRUE,  FALSE, '', '',        ''),
    ('entities', 'created_at',     'Created At',     '',                                                       '',             'date-time', FALSE, 130, 'disabled', 'default', NULL,  TRUE,  FALSE, '', '',        ''),
    ('entities', 'updated_at',     'Updated At',     '',                                                       '',             'date-time', FALSE, 140, 'disabled', 'default', NULL,  TRUE,  FALSE, '', '',        '');

-- Insert fields metadata for users table
INSERT INTO fields (table_name, field_name, title, description, format, is_pk, field_order, input_type, width, ctype, is_core, searchable, reference_table, reference_delete_mode)
VALUES 
    ('users', 'id', 'Id', '', 'int32', TRUE, 1, 'readonly', 'default', 'id', TRUE, FALSE, '', ''),
    ('users', 'external_id', 'External Id', 'External identifier from authentication provider', 'text', FALSE, 10, 'readonly', 'default', NULL, TRUE, TRUE, '', ''),
    ('users', 'email', 'Email', '', 'email', FALSE, 20, 'default', 'default', 'label', TRUE, TRUE, '', ''),
    ('users', 'display_name', 'Display Name', '', 'text', FALSE, 25, 'default', 'default', NULL, TRUE, TRUE, '', ''),
    ('users', 'is_disabled', 'Is Disabled', '', 'boolean', FALSE, 30, 'default', 'default', NULL, TRUE, FALSE, '', ''),
    ('users', 'settings', 'Settings', 'User-specific settings and preferences', 'json', FALSE, 35, 'default', 'w', NULL, TRUE, FALSE, '', ''),
    ('users', 'created_at', 'Created At', '', 'date-time', FALSE, 40, 'disabled', 'default', NULL, TRUE, FALSE, '', ''),
    ('users', 'updated_at', 'Updated At', '', 'date-time', FALSE, 50, 'disabled', 'default', NULL, TRUE, FALSE, '', ''),
    ('users', 'last_seen', 'Last Seen', 'Timestamp when user was last active', 'date-time', FALSE, 60, 'readonly', 'default', NULL, TRUE, FALSE, '', '');

-- Insert fields metadata for modules table
INSERT INTO fields (table_name, field_name, title, description, format, is_pk, field_order, input_type, width, ctype, is_core, searchable, reference_table, reference_delete_mode)
VALUES 
    ('modules', 'id', 'Id', '', 'int32', TRUE, 1, 'readonly', 'default', 'id', TRUE, FALSE, '', ''),
    ('modules', 'module_name', 'Module Name', 'Unique module name', 'text', FALSE, 10, 'required', 'default', 'label', TRUE, TRUE, '', ''),
    ('modules', 'description', 'Description', '', 'text', FALSE, 20, 'default', 'w', NULL, TRUE, TRUE, '', ''),
    ('modules', 'module_type', 'Module Type', 'Module type: domain (normal) or master (promoted for sharing)', 'enum', FALSE, 25, 'readonly', 'default', NULL, TRUE, FALSE, '', ''),
    ('modules', 'view_permission', 'View Permission', 'Permission required to view this module', 'text', FALSE, 30, 'default', 'default', NULL, TRUE, FALSE, '', ''),
    ('modules', 'logo_url', 'Logo URL', 'URL or base64 data URI for module logo', 'url', FALSE, 35, 'default', 'w', NULL, TRUE, FALSE, '', ''),
    ('modules', 'logo_color', 'Logo Color', 'Hex color code for module logo', 'text', FALSE, 36, 'default', 'default', NULL, TRUE, FALSE, '', ''),
    ('modules', 'home_page', 'Home Page', 'Default home page path for module', 'text', FALSE, 37, 'default', 'default', NULL, TRUE, FALSE, '', ''),
    ('modules', 'module_slug', 'Module Slug', 'URL-safe unique identifier for module, auto-generated from module_name if not provided', 'text', FALSE, 38, 'default', 'default', NULL, TRUE, FALSE, '', ''),
    ('modules', 'manage_permission_id', 'Manage Permission', '', 'reference', FALSE, 39, 'default', 'default', NULL, TRUE, FALSE, 'permissions', 'clear'),
    ('modules', 'admin_permission_id', 'Admin Permission', '', 'reference', FALSE, 40, 'default', 'default', NULL, TRUE, FALSE, 'permissions', 'clear'),
    ('modules', 'default_viewer_role_id', 'Default Viewer Role', '', 'reference', FALSE, 41, 'default', 'default', NULL, TRUE, FALSE, 'roles', 'clear'),
    ('modules', 'default_manager_role_id', 'Default Manager Role', '', 'reference', FALSE, 42, 'default', 'default', NULL, TRUE, FALSE, 'roles', 'clear'),
    ('modules', 'default_admin_role_id', 'Default Admin Role', '', 'reference', FALSE, 43, 'default', 'default', NULL, TRUE, FALSE, 'roles', 'clear'),
    ('modules', 'settings', 'Settings', 'Module-specific settings and configuration', 'json', FALSE, 50, 'default', 'w', NULL, TRUE, FALSE, '', ''),
    ('modules', 'dashboard_config', 'Dashboard Configuration', '', 'json', FALSE, 60, 'default', 'w', NULL, TRUE, FALSE, '', ''),
    ('modules', 'created_at', 'Created At', '', 'date-time', FALSE, 90, 'disabled', 'default', NULL, TRUE, FALSE, '', ''),
    ('modules', 'updated_at', 'Updated At', '', 'date-time', FALSE, 100, 'disabled', 'default', NULL, TRUE, FALSE, '', '');

-- Set enum_values for module_type field
UPDATE fields SET enum_values = '["domain", "master"]'::jsonb WHERE table_name = 'modules' AND field_name = 'module_type';

-- Insert fields metadata for roles table
INSERT INTO fields (table_name, field_name, title, description, format, is_pk, field_order, input_type, width, ctype, is_core, searchable, reference_table, reference_delete_mode, relationship_label)
VALUES
    ('roles', 'id',          'Id',          '',                              'int32',     TRUE,  1,  'readonly', 'default', 'id',    TRUE, FALSE, '',        '',      ''),
    ('roles', 'role_name',   'Role Name',   'Unique role name',              'text',      FALSE, 10, 'required', 'default', 'label', TRUE, TRUE,  '',        '',      ''),
    ('roles', 'slug',        'Slug',        'Snake_case unique identifier for role, auto-generated from role_name', 'text', FALSE, 15, 'readonly', 'default', NULL, TRUE, FALSE, '', '', ''),
    ('roles', 'description', 'Description', '',                              'multiline', FALSE, 20, 'default',  'w',       NULL,    TRUE, TRUE,  '',        '',      ''),
    ('roles', 'origin',      'Origin',      '', 'enum', FALSE, 25, 'readonly', 'default', NULL, TRUE, FALSE, '', '', ''),
    ('roles', 'module_id',   'Module Id',   'Module this role belongs to',   'reference', FALSE, 30, 'default',  'default', NULL,    TRUE, FALSE, 'modules', 'clear', 'contains'),
    ('roles', 'created_at',  'Created At',  '',                              'date-time', FALSE, 40, 'disabled', 'default', NULL,    TRUE, FALSE, '',        '',      ''),
    ('roles', 'updated_at',  'Updated At',  '',                              'date-time', FALSE, 50, 'disabled', 'default', NULL,    TRUE, FALSE, '',        '',      '');

-- Mark roles.slug as unique (matches UNIQUE constraint on actual table)
UPDATE fields SET unique_value = TRUE WHERE table_name = 'roles' AND field_name = 'slug';

-- Set enum_values for roles.origin field
UPDATE fields SET enum_values = '["system", "model", "model_master", "user"]'::jsonb WHERE table_name = 'roles' AND field_name = 'origin';

-- Insert fields metadata for permissions table
INSERT INTO fields (table_name, field_name, title, description, format, is_pk, field_order, input_type, width, ctype, is_core, searchable, reference_table, reference_delete_mode, relationship_label)
VALUES
    ('permissions', 'id',              'Id',              '',                                    'int32',     TRUE,  1,  'readonly', 'default', 'id',    TRUE, FALSE, '',        '',      ''),
    ('permissions', 'permission_name', 'Permission Name', 'Unique permission name',              'text',      FALSE, 10, 'required', 'default', 'label', TRUE, TRUE,  '',        '',      ''),
    ('permissions', 'description',     'Description',     '',                                    'multiline', FALSE, 20, 'default',  'w',       NULL,    TRUE, TRUE,  '',        '',      ''),
    ('permissions', 'module_id',       'Module Id',       'Module this permission belongs to',   'reference', FALSE, 30, 'default',  'default', NULL,    TRUE, FALSE, 'modules', 'clear', 'contains'),
    ('permissions', 'created_at',      'Created At',      '',                                    'date-time', FALSE, 40, 'disabled', 'default', NULL,    TRUE, FALSE, '',        '',      ''),
    ('permissions', 'updated_at',      'Updated At',      '',                                    'date-time', FALSE, 50, 'disabled', 'default', NULL,    TRUE, FALSE, '',        '',      '');

-- Mark permission_name as unique (matches UNIQUE constraint on actual table)
UPDATE fields SET unique_value = TRUE WHERE table_name = 'permissions' AND field_name = 'permission_name';

-- Insert fields metadata for user_roles table
INSERT INTO fields (table_name, field_name, title, description, format, is_pk, field_order, input_type, width, ctype, is_core, searchable, reference_table, reference_delete_mode, relationship_label)
VALUES
    ('user_roles', 'id',          'Id',          'Generated identifier (user_id.role_id)',  'text',      TRUE,  1,  'readonly', 'default', 'id', TRUE, FALSE, '',      '',        ''),
    ('user_roles', 'user_id',     'User Id',     'User this role is assigned to',           'parent',    FALSE, 10, 'required', 'default', NULL, TRUE, FALSE, 'users', 'cascade', 'has roles'),
    ('user_roles', 'role_id',     'Role Id',     'Role assigned to the user',               'parent',    FALSE, 20, 'required', 'default', NULL, TRUE, FALSE, 'roles', 'cascade', 'assigned to'),
    ('user_roles', 'assigned_at', 'Assigned At', 'Timestamp when role was assigned',        'date-time', FALSE, 30, 'disabled', 'default', NULL, TRUE, FALSE, '',      '',        ''),
    ('user_roles', 'assigned_by', 'Assigned By', 'User who assigned this role',             'reference', FALSE, 40, 'default',  'default', NULL, TRUE, FALSE, 'users', 'clear',   'has assigned');

UPDATE fields SET singular_label_parent = 'Role', plural_label_parent = 'Roles' WHERE table_name = 'user_roles' AND field_name = 'user_id';
UPDATE fields SET singular_label_parent = 'User', plural_label_parent = 'Users' WHERE table_name = 'user_roles' AND field_name = 'role_id';

-- Insert fields metadata for role_permissions table
INSERT INTO fields (table_name, field_name, title, description, format, is_pk, field_order, input_type, width, ctype, is_core, searchable, reference_table, reference_delete_mode, relationship_label)
VALUES
    ('role_permissions', 'id',            'Id',            'Generated identifier (role_id.permission_id)', 'text',      TRUE,  1,  'readonly', 'default', 'id', TRUE, FALSE, '',            '',        ''),
    ('role_permissions', 'role_id',       'Role Id',       'Role this permission is granted to',           'parent',    FALSE, 10, 'default',  'default', NULL, TRUE, FALSE, 'roles',        'cascade', 'has permissions'),
    ('role_permissions', 'permission_id', 'Permission Id', 'Permission granted to the role',               'parent',    FALSE, 20, 'default',  'default', NULL, TRUE, FALSE, 'permissions',  'cascade', 'granted to'),
    ('role_permissions', 'granted_at',    'Granted At',    'Timestamp when permission was granted',        'date-time', FALSE, 30, 'disabled', 'default', NULL, TRUE, FALSE, '',             '',        ''),
    ('role_permissions', 'granted_by',    'Granted By',    'User who granted this permission',             'reference', FALSE, 40, 'default',  'default', NULL, TRUE, FALSE, 'users',        'clear',   'has granted');

UPDATE fields SET singular_label_parent = 'Permission', plural_label_parent = 'Permissions' WHERE table_name = 'role_permissions' AND field_name = 'role_id';
UPDATE fields SET singular_label_parent = 'Permission', plural_label_parent = 'Permissions' WHERE table_name = 'role_permissions' AND field_name = 'permission_id';

-- Insert fields metadata for user_permissions table
INSERT INTO fields (table_name, field_name, title, description, format, is_pk, field_order, input_type, width, ctype, is_core, searchable, reference_table, reference_delete_mode, relationship_label)
VALUES
    ('user_permissions', 'id',            'Id',            'Generated identifier (user_id.permission_id)', 'text',      TRUE,  1,  'readonly', 'default', 'id', TRUE, FALSE, '',             '',        ''),
    ('user_permissions', 'user_id',       'User Id',       'User this permission is granted to',           'parent',    FALSE, 10, 'required', 'default', NULL, TRUE, FALSE, 'users',         'cascade', 'has permissions'),
    ('user_permissions', 'permission_id', 'Permission Id', 'Permission granted to the user',               'parent',    FALSE, 20, 'required', 'default', NULL, TRUE, FALSE, 'permissions',   'cascade', 'granted to'),
    ('user_permissions', 'granted_at',    'Granted At',    'Timestamp when permission was granted',        'date-time', FALSE, 30, 'disabled', 'default', NULL, TRUE, FALSE, '',              '',        ''),
    ('user_permissions', 'granted_by',    'Granted By',    'User who granted this permission',             'reference', FALSE, 40, 'default',  'default', NULL, TRUE, FALSE, 'users',         'clear',   'has granted');

UPDATE fields SET singular_label_parent = 'Permission', plural_label_parent = 'Permissions' WHERE table_name = 'user_permissions' AND field_name = 'user_id';
UPDATE fields SET singular_label_parent = 'User',       plural_label_parent = 'Users'       WHERE table_name = 'user_permissions' AND field_name = 'permission_id';

-- Insert fields metadata for permission_hierarchy table
INSERT INTO fields (table_name, field_name, title, description, format, is_pk, field_order, input_type, width, ctype, is_core, searchable, reference_table, reference_delete_mode, relationship_label)
VALUES
    ('permission_hierarchy', 'id',                      'Id',                      'Generated identifier (including_permission_id.included_permission_id)', 'text',      TRUE,  1,  'readonly', 'default', 'id', TRUE, FALSE, '',             '',        ''),
    ('permission_hierarchy', 'including_permission_id',  'Including Permission Id',  'The broader permission that includes other permissions',                 'parent',    FALSE, 10, 'default',  'default', NULL, TRUE, FALSE, 'permissions',  'cascade', 'includes'),
    ('permission_hierarchy', 'included_permission_id',   'Included Permission Id',   'The narrower permission that is included by the broader one',            'parent',    FALSE, 20, 'default',  'default', NULL, TRUE, FALSE, 'permissions',  'cascade', 'included in'),
    ('permission_hierarchy', 'origin',                'Origin',                'How this hierarchy entry was created',                             'enum',      FALSE, 25, 'readonly', 'default', NULL, TRUE, FALSE, '',             '',        ''),
    ('permission_hierarchy', 'created_at',            'Created At',            '',                                                                'date-time', FALSE, 30, 'disabled', 'default', NULL, TRUE, FALSE, '',             '',        '');

UPDATE fields SET singular_label_parent = 'Includes',    plural_label_parent = 'Includes'    WHERE table_name = 'permission_hierarchy' AND field_name = 'including_permission_id';
UPDATE fields SET singular_label_parent = 'Included in', plural_label_parent = 'Included in' WHERE table_name = 'permission_hierarchy' AND field_name = 'included_permission_id';

-- Set enum_values for permission_hierarchy.origin field
UPDATE fields SET enum_values = '["system", "model", "model_master", "user"]'::jsonb WHERE table_name = 'permission_hierarchy' AND field_name = 'origin';

-- Revoke default PUBLIC execute on trigger functions defined in this file
REVOKE EXECUTE ON FUNCTION validate_reference_table() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION auto_set_plural() FROM PUBLIC;`,
    "0070_dd_functions": `-- =====================================================
-- DYNAMIC TABLE MANAGEMENT FUNCTIONS
-- =====================================================
-- Automatically creates tables and fields when metadata is inserted
-- Integrates with RBAC for automatic RLS policy creation
-- =====================================================

-- =====================================================
-- FORMAT TO DATA TYPE MAPPING FUNCTION
-- =====================================================
-- Maps JSON Schema format values to PostgreSQL data types
-- This function converts the format column value to an actual PostgreSQL type

CREATE OR REPLACE FUNCTION format_to_data_type(p_format TEXT, p_precision SMALLINT DEFAULT NULL)
RETURNS TEXT AS $$
DECLARE
    v_scale SMALLINT := COALESCE(p_precision, 2);
BEGIN
    RETURN CASE p_format
        -- Integer formats
        WHEN 'int32' THEN 'INTEGER'
        WHEN 'int64' THEN 'BIGINT'
        WHEN 'integer' THEN 'INTEGER'
        WHEN 'reference' THEN 'INTEGER'  -- Foreign key references use INTEGER
        WHEN 'parent' THEN 'INTEGER'     -- Parent references use INTEGER (like reference)
        
        -- Number formats
        WHEN 'float' THEN 'REAL'
        WHEN 'double' THEN 'DOUBLE PRECISION'
        WHEN 'number' THEN 'NUMERIC(18, ' || v_scale || ')'
        
        -- Special types (not TEXT)
        WHEN 'uuid' THEN 'UUID'
        WHEN 'binary' THEN 'BYTEA'
        
        -- Date/Time formats
        WHEN 'date' THEN 'DATE'
        WHEN 'time' THEN 'TIME'
        WHEN 'date-time' THEN 'TIMESTAMPTZ'
        WHEN 'duration' THEN 'INTERVAL'
        
        -- Boolean format
        WHEN 'boolean' THEN 'BOOLEAN'
        
        -- JSON formats
        WHEN 'json' THEN 'JSONB'
        WHEN 'object' THEN 'JSONB'
        WHEN 'array' THEN 'JSONB'
        
        -- Default case (handles all string-like formats: text, email, url, hostname, etc.)
        ELSE 'TEXT'
    END;
END;
$$ LANGUAGE plpgsql IMMUTABLE SET search_path = public;

COMMENT ON FUNCTION format_to_data_type IS 
'Maps JSON Schema format values to PostgreSQL data types for CREATE/ALTER TABLE statements. For "number" format, the optional p_precision argument controls the NUMERIC scale (default 2).';

-- =====================================================
-- HELPER FUNCTION: FORMAT TO JSON SCHEMA TYPE
-- =====================================================
-- Maps format values to JSON Schema primitive types
-- Used to avoid duplication in type and default value handling
-- This function is closely related to format_to_data_type above

CREATE OR REPLACE FUNCTION format_to_json_type(p_format TEXT)
RETURNS JSONB AS $$
BEGIN
    RETURN CASE 
        -- Special case: json format can accept any type
        WHEN p_format = 'json' THEN to_jsonb(ARRAY['object', 'array', 'string', 'number', 'integer', 'boolean', 'null'])
        -- Single type mappings
        WHEN p_format IN ('int32', 'int64', 'integer', 'reference', 'parent') THEN to_jsonb('integer'::text)
        WHEN p_format IN ('float', 'double', 'number') THEN to_jsonb('number'::text)
        WHEN p_format = 'boolean' THEN to_jsonb('boolean'::text)
        WHEN p_format IN ('array') THEN to_jsonb('array'::text)
        WHEN p_format IN ('object') THEN to_jsonb('object'::text)
        WHEN p_format = 'null' THEN to_jsonb('null'::text)
        ELSE to_jsonb('string'::text)
    END;
END;
$$ LANGUAGE plpgsql IMMUTABLE SET search_path = public;

COMMENT ON FUNCTION format_to_json_type IS 
'Maps format values to JSON Schema types (returns JSONB - either a string for single type or array for json format).';

-- =====================================================
-- IS_NULLABLE FUNCTION
-- =====================================================
-- Determines whether a column should allow NULL values based on its format.
-- Nullable formats: reference (optional FK), date (unknown date), date-time (not-yet timestamps)
-- All other formats use NOT NULL with appropriate defaults.

CREATE OR REPLACE FUNCTION is_nullable(p_format TEXT)
RETURNS BOOLEAN AS $$
BEGIN
    RETURN p_format IN ('reference', 'date', 'date-time');
END;
$$ LANGUAGE plpgsql IMMUTABLE SET search_path = public;

COMMENT ON FUNCTION is_nullable IS
'Determines whether a column should allow NULL values based on its format. Returns TRUE for reference, date, and date-time formats.';

-- =====================================================
-- ENUM HELPER FUNCTIONS
-- =====================================================
-- Centralised handling of enum default behaviour:
--   • effective_enum_values  -- expands enum_values with '' for non-required enums,
--                               so empty defaults are accepted by the CHECK constraint.
--   • effective_enum_default -- resolves the actual column default for an enum field
--                               based on input_type and the explicit default_value.

CREATE OR REPLACE FUNCTION effective_enum_values(p_input_type TEXT, p_enum_values JSONB)
RETURNS JSONB AS $$
BEGIN
    IF p_enum_values IS NULL OR jsonb_array_length(p_enum_values) = 0 THEN
        RETURN p_enum_values;
    END IF;
    -- For non-required enums, ensure '' is in the allowed list so the implicit
    -- empty-string default does not violate the CHECK constraint.
    IF p_input_type IS DISTINCT FROM 'required' AND NOT (p_enum_values @> '[""]'::jsonb) THEN
        RETURN p_enum_values || '[""]'::jsonb;
    END IF;
    RETURN p_enum_values;
END;
$$ LANGUAGE plpgsql IMMUTABLE SET search_path = public;

COMMENT ON FUNCTION effective_enum_values IS
'Returns the effective list of allowed enum values: appends '''' for non-required enums so that the implicit empty-string default is accepted by the CHECK constraint.';

CREATE OR REPLACE FUNCTION effective_enum_default(p_default_value TEXT, p_input_type TEXT, p_enum_values JSONB)
RETURNS TEXT AS $$
BEGIN
    -- Explicit default takes precedence
    IF p_default_value IS NOT NULL AND trim(p_default_value) != '' THEN
        RETURN p_default_value;
    END IF;
    -- Required enum without explicit default: pick the first allowed value
    IF p_input_type = 'required'
       AND p_enum_values IS NOT NULL
       AND jsonb_array_length(p_enum_values) > 0 THEN
        RETURN p_enum_values->>0;
    END IF;
    -- Non-required enum without explicit default: empty string
    RETURN '';
END;
$$ LANGUAGE plpgsql IMMUTABLE SET search_path = public;

COMMENT ON FUNCTION effective_enum_default IS
'Computes the effective default for an enum field: explicit default_value if set, else first enum value when input_type is required, else empty string.';

-- Add is_nullable as a computed read-only column on the fields table.
-- It is derived from the format column via the is_nullable() function above.
-- GENERATED ALWAYS means the value cannot be manually written.
ALTER TABLE fields ADD COLUMN is_nullable BOOLEAN GENERATED ALWAYS AS (is_nullable(format)) STORED;
COMMENT ON COLUMN fields.is_nullable IS 'Whether this field allows NULL values (computed from format: reference, date, date-time are nullable)';

-- =====================================================
-- HELPER FUNCTION: QUOTE DEFAULT VALUE
-- =====================================================
-- Properly quotes default values based on data type
-- Properly quotes default values based on data type for DDL statements

CREATE OR REPLACE FUNCTION quote_default_value(p_default_value TEXT, p_data_type TEXT)
RETURNS TEXT AS $$
BEGIN
    -- If default value is NULL or empty, return as-is
    IF p_default_value IS NULL OR trim(p_default_value) = '' THEN
        RETURN p_default_value;
    END IF;
    
    -- If it's a function call (contains parentheses) or cast (contains ::), return as-is
    IF p_default_value ~ '\\(|::' THEN
        RETURN p_default_value;
    END IF;
    
    -- If it's a numeric constant and data type is numeric, return as-is
    IF p_data_type IN ('INTEGER', 'BIGINT', 'SMALLINT', 'NUMERIC', 'DECIMAL', 'REAL', 'DOUBLE PRECISION') 
       AND p_default_value ~ '^-?[0-9]+(\\.[0-9]+)?$' THEN
        RETURN p_default_value;
    END IF;
    
    -- If it's a boolean constant, return uppercase for consistency
    IF p_data_type = 'BOOLEAN' AND p_default_value IN ('TRUE', 'FALSE', 'true', 'false', 't', 'f') THEN
        RETURN UPPER(p_default_value);
    END IF;
    
    -- For TEXT and string-like types, quote the value
    IF p_data_type IN ('TEXT', 'VARCHAR', 'CHAR', 'CHARACTER VARYING') THEN
        RETURN quote_literal(p_default_value);
    END IF;
    
    -- Default: return as-is (for special types like UUID, JSONB, etc.)
    RETURN p_default_value;
END;
$$ LANGUAGE plpgsql IMMUTABLE SET search_path = public;

COMMENT ON FUNCTION quote_default_value IS 
'Properly quotes default values based on data type for use in DDL statements.';

-- =====================================================
-- TRIGGER FUNCTION: CREATE TABLE ON INSERT
-- =====================================================

CREATE OR REPLACE FUNCTION create_dd_table()
RETURNS TRIGGER AS $$
DECLARE
    v_create_sql TEXT;
    v_policy_sql TEXT;
BEGIN
    -- Skip DDL execution if table is not managed
    IF NOT NEW.managed THEN
        RAISE NOTICE 'Skipping table creation for "%" (managed=false)', NEW.table_name;
        RETURN NEW;
    END IF;
    
    -- Validate that view and edit permissions exist
    IF NOT rbac.validate_permission_exists(NEW.view_permission) THEN
        RAISE EXCEPTION 'View permission "%" does not exist in permissions table', NEW.view_permission;
    END IF;
    
    IF NOT rbac.validate_permission_exists(NEW.edit_permission) THEN
        RAISE EXCEPTION 'Edit permission "%" does not exist in permissions table', NEW.edit_permission;
    END IF;
    
    -- Build CREATE TABLE statement
    v_create_sql := format(
        'CREATE TABLE IF NOT EXISTS public.%I (
            %I SERIAL PRIMARY KEY,
            %I TEXT NOT NULL DEFAULT '''',
            created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
            updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
        )',
        NEW.table_name,
        NEW.id_column,
        NEW.label_column
    );
    
    -- Create the table
    EXECUTE v_create_sql;
    
    -- Add table comment if description provided
    IF NEW.description IS NOT NULL AND trim(NEW.description) != '' THEN
        EXECUTE format(
            'COMMENT ON TABLE %I IS %L',
            NEW.table_name,
            NEW.description
        );
    END IF;
    
    -- Add updated_at trigger using common schema function
    EXECUTE format(
        'CREATE TRIGGER update_%I_updated_at
            BEFORE UPDATE ON %I
            FOR EACH ROW
            EXECUTE FUNCTION common.update_updated_at_column()',
        NEW.table_name,
        NEW.table_name
    );
    
    -- Enable RLS on the new table
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', NEW.table_name);
    
    -- Create RLS policies for SELECT (view permission)
    v_policy_sql := format(
        'CREATE POLICY %I_select_policy ON %I
            FOR SELECT
            TO semantius_user
            USING (rbac.has_permission(%L))',
        NEW.table_name,
        NEW.table_name,
        NEW.view_permission
    );
    EXECUTE v_policy_sql;
    
    -- Create RLS policies for INSERT (edit permission)
    v_policy_sql := format(
        'CREATE POLICY %I_insert_policy ON %I
            FOR INSERT
            TO semantius_user
            WITH CHECK (rbac.has_permission(%L))',
        NEW.table_name,
        NEW.table_name,
        NEW.edit_permission
    );
    EXECUTE v_policy_sql;
    
    -- Create RLS policies for UPDATE (edit permission)
    v_policy_sql := format(
        'CREATE POLICY %I_update_policy ON %I
            FOR UPDATE
            TO semantius_user
            USING (rbac.has_permission(%L))
            WITH CHECK (rbac.has_permission(%L))',
        NEW.table_name,
        NEW.table_name,
        NEW.edit_permission,
        NEW.edit_permission
    );
    EXECUTE v_policy_sql;
    
    -- Create RLS policies for DELETE (edit permission)
    v_policy_sql := format(
        'CREATE POLICY %I_delete_policy ON %I
            FOR DELETE
            TO semantius_user
            USING (rbac.has_permission(%L))',
        NEW.table_name,
        NEW.table_name,
        NEW.edit_permission
    );
    EXECUTE v_policy_sql;
    
    -- Insert field records for id, label, created_at, and updated_at columns
    -- All these are core fields that cannot be deleted or renamed (is_core = TRUE)
    -- The label column is marked as searchable=TRUE for full-text search
    INSERT INTO fields (table_name, field_name, title, format, is_pk, field_order, input_type, width, ctype, is_core, searchable, reference_table, reference_delete_mode)
    VALUES 
        (NEW.table_name, NEW.id_column, 'Id', 'int32', TRUE, 1, 'readonly', 'default', 'id', TRUE, FALSE, '', ''),
        (NEW.table_name, NEW.label_column, NEW.singular_label, 'text', FALSE, 1, 'required', 'default', 'label', TRUE, TRUE, '', ''),
        (NEW.table_name, 'created_at', 'Created At', 'date-time', FALSE, 999998, 'disabled', 'default', '', TRUE, FALSE, '', ''),
        (NEW.table_name, 'updated_at', 'Updated At', 'date-time', FALSE, 999999, 'disabled', 'default', '', TRUE, FALSE, '', '');
    
    -- Note: The handle_field_searchable_change_trigger will fire for the above INSERTs
    -- and update entities.searchable automatically. However, since we're in a nested trigger context,
    -- we need to ensure the searchable flag gets set correctly after this trigger completes.
    -- The solution is to update it directly here since the label field is always searchable.
    UPDATE entities 
    SET searchable = TRUE 
    WHERE table_name = NEW.table_name 
      AND EXISTS (SELECT 1 FROM fields WHERE table_name = NEW.table_name AND searchable = TRUE);

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION create_dd_table IS 
'Trigger function that creates a table with RLS policies when a row is inserted into entities table.';

-- Apply trigger AFTER INSERT on entities
CREATE TRIGGER create_table_trigger
    AFTER INSERT ON entities
    FOR EACH ROW
    EXECUTE FUNCTION create_dd_table();

-- =====================================================
-- TRIGGER FUNCTION: AUTO-SET FIELD ORDER ON INSERT
-- =====================================================
-- When a new field is inserted with field_order = 0 (the default),
-- automatically assign it to max(field_order) + 10 for that table,
-- so new fields are always appended to the end of the fields list.

CREATE OR REPLACE FUNCTION auto_set_field_order()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.field_order = 0 THEN
        SELECT COALESCE(MAX(field_order), 0) + 10
        INTO NEW.field_order
        FROM fields
        WHERE table_name = NEW.table_name;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SET search_path = public;

COMMENT ON FUNCTION auto_set_field_order IS
'Trigger function that auto-assigns field_order to max(field_order)+10 when field_order=0 is inserted.';

-- Apply trigger BEFORE INSERT on fields (must run before add_dd_field)
CREATE TRIGGER auto_set_field_order_trigger
    BEFORE INSERT ON fields
    FOR EACH ROW
    EXECUTE FUNCTION auto_set_field_order();

REVOKE EXECUTE ON FUNCTION auto_set_field_order() FROM PUBLIC;

-- =====================================================
-- TRIGGER FUNCTION: ADD FIELD ON INSERT
-- =====================================================

CREATE OR REPLACE FUNCTION add_dd_field()
RETURNS TRIGGER AS $$
DECLARE
    v_alter_sql TEXT;
    v_nullable_clause TEXT;
    v_default_clause TEXT;
    v_data_type TEXT;
    v_is_managed BOOLEAN;
    v_ref_id_column TEXT;
    v_fk_name TEXT;
    v_idx_name TEXT;
    v_on_delete TEXT;
BEGIN
    -- Suppress IF NOT EXISTS/IF EXISTS notices
    SET LOCAL client_min_messages = WARNING;
    
    -- Check if the parent table is managed
    SELECT managed INTO v_is_managed FROM entities WHERE table_name = NEW.table_name;
    
    IF NOT v_is_managed THEN
        RAISE NOTICE 'Skipping field addition for "%.%" (table managed=false)', NEW.table_name, NEW.field_name;
        RETURN NEW;
    END IF;
    
    -- Skip if this is the id or label column (already created by create_dd_table)
    IF NEW.field_name IN (
        SELECT id_column FROM entities WHERE table_name = NEW.table_name
        UNION
        SELECT label_column FROM entities WHERE table_name = NEW.table_name
    ) THEN
        -- Still add column comment if description provided
        IF NEW.description IS NOT NULL AND trim(NEW.description) != '' THEN
            EXECUTE format(
                'COMMENT ON COLUMN %I.%I IS %L',
                NEW.table_name,
                NEW.field_name,
                NEW.description
            );
        END IF;
        RETURN NEW;
    END IF;
    
    -- Convert format to PostgreSQL data type
    v_data_type := format_to_data_type(NEW.format, NEW."precision");
    
    -- Build nullable clause based on format
    IF NEW.is_nullable THEN
        v_nullable_clause := 'NULL';
    ELSE
        v_nullable_clause := 'NOT NULL';
    END IF;
    
    -- Build default clause with sensible defaults based on data type
    DECLARE
        v_resolved_default TEXT;
    BEGIN
        IF NEW.format = 'enum' THEN
            v_resolved_default := effective_enum_default(NEW.default_value, NEW.input_type, NEW.enum_values);
        ELSE
            v_resolved_default := NEW.default_value;
        END IF;

        IF v_resolved_default IS NOT NULL AND trim(v_resolved_default) != '' THEN
            v_default_clause := format('DEFAULT %s', quote_default_value(v_resolved_default, v_data_type));
        ELSIF NOT NEW.is_nullable THEN
            -- Provide sensible defaults for NOT NULL columns without explicit default
            -- For JSONB/JSON: if default_value is empty string, convert to empty JSON object
            IF v_data_type IN ('JSONB', 'JSON') THEN
                v_default_clause := 'DEFAULT ''{}''::jsonb';
            ELSE
                CASE
                    WHEN v_data_type = 'TEXT' THEN v_default_clause := 'DEFAULT ''''';
                    WHEN v_data_type IN ('INTEGER', 'BIGINT', 'SMALLINT') THEN v_default_clause := 'DEFAULT 0';
                    WHEN v_data_type IN ('REAL', 'DOUBLE PRECISION') OR v_data_type LIKE 'NUMERIC%' OR v_data_type LIKE 'DECIMAL%' THEN v_default_clause := 'DEFAULT 0.0';
                    WHEN v_data_type = 'BOOLEAN' THEN v_default_clause := 'DEFAULT FALSE';
                    WHEN v_data_type IN ('TIMESTAMP', 'TIMESTAMPTZ') THEN v_default_clause := 'DEFAULT CURRENT_TIMESTAMP';
                    WHEN v_data_type = 'DATE' THEN v_default_clause := 'DEFAULT CURRENT_DATE';
                    ELSE v_default_clause := '';
                END CASE;
            END IF;
        ELSE
            v_default_clause := '';
        END IF;
    END;
    
    -- Build ALTER TABLE statement
    v_alter_sql := format(
        'ALTER TABLE %I ADD COLUMN IF NOT EXISTS %I %s %s %s',
        NEW.table_name,
        NEW.field_name,
        v_data_type,
        v_nullable_clause,
        v_default_clause
    );
    
    -- Add the column
    EXECUTE v_alter_sql;
    
    -- Add column comment if description provided
    IF NEW.description IS NOT NULL AND trim(NEW.description) != '' THEN
        EXECUTE format(
            'COMMENT ON COLUMN %I.%I IS %L',
            NEW.table_name,
            NEW.field_name,
            NEW.description
        );
    END IF;
    
    -- If this is a primary key field, set it as primary key
    IF NEW.is_pk THEN
        -- Check if table already has a primary key
        IF EXISTS (
            SELECT 1 FROM fields 
            WHERE table_name = NEW.table_name
            AND is_pk = TRUE 
            AND field_name <> NEW.field_name
        ) THEN
            RAISE EXCEPTION 'Table % already has a primary key', NEW.table_name;
        END IF;
        
        -- Add primary key constraint
        EXECUTE format(
            'ALTER TABLE %I DROP CONSTRAINT IF EXISTS %I',
            NEW.table_name,
            NEW.table_name || '_pkey'
        );
        
        EXECUTE format(
            'ALTER TABLE %I ADD PRIMARY KEY (%I)',
            NEW.table_name,
            NEW.field_name
        );
    END IF;
    
    -- If this is a reference or parent field, add foreign key constraint
    IF NEW.format IN ('reference', 'parent') AND NEW.reference_table IS NOT NULL AND NEW.reference_table != '' THEN
        -- Get the id_column of the referenced table
        SELECT id_column INTO v_ref_id_column
        FROM entities
        WHERE table_name = NEW.reference_table;
        
        IF v_ref_id_column IS NULL THEN
            RAISE EXCEPTION 'Referenced table "%" not found', NEW.reference_table;
        END IF;
        
        -- Determine ON DELETE behavior based on reference_delete_mode
        IF NEW.reference_delete_mode = 'clear' THEN
            v_on_delete := 'SET NULL';
        ELSIF NEW.reference_delete_mode = 'cascade' THEN
            v_on_delete := 'CASCADE';
        ELSE
            v_on_delete := 'RESTRICT';
        END IF;
        
        -- Generate foreign key constraint name
        v_fk_name := format('%s_%s_fkey', NEW.table_name, NEW.field_name);
        
        -- Add foreign key constraint (skip if constraint already exists - e.g. pre-existing schema FKs)
        v_alter_sql := format(
            'ALTER TABLE %I ADD CONSTRAINT %I FOREIGN KEY (%I) REFERENCES %I(%I) ON DELETE %s',
            NEW.table_name,
            v_fk_name,
            NEW.field_name,
            NEW.reference_table,
            v_ref_id_column,
            v_on_delete
        );
        BEGIN
            EXECUTE v_alter_sql;
        EXCEPTION WHEN duplicate_object THEN
            RAISE NOTICE 'Foreign key constraint "%" already exists on "%.%", skipping creation. Verify ON DELETE behavior matches expected: %',
                v_fk_name, NEW.table_name, NEW.field_name, v_on_delete;
        END;
        
        -- Create index for foreign key
        v_idx_name := format('idx_%s_%s', NEW.table_name, NEW.field_name);
        v_alter_sql := format(
            'CREATE INDEX IF NOT EXISTS %I ON %I(%I)',
            v_idx_name,
            NEW.table_name,
            NEW.field_name
        );
        EXECUTE v_alter_sql;
    END IF;
    
    -- If this is an enum field, add CHECK constraint for allowed values
    IF NEW.format = 'enum' AND NEW.enum_values IS NOT NULL AND jsonb_array_length(NEW.enum_values) > 0 THEN
        DECLARE
            v_check_name TEXT;
            v_enum_values_sql TEXT;
            v_effective_enum JSONB;
        BEGIN
            -- Generate CHECK constraint name
            v_check_name := format('%s_%s_check', NEW.table_name, NEW.field_name);
            
            -- Compute effective allowed values (adds '' for non-required enums)
            v_effective_enum := effective_enum_values(NEW.input_type, NEW.enum_values);

            -- Build SQL array from JSONB array for IN clause
            v_enum_values_sql := (
                SELECT string_agg(quote_literal(value::text), ', ')
                FROM jsonb_array_elements_text(v_effective_enum) AS value
            );
            
            -- Add CHECK constraint
            v_alter_sql := format(
                'ALTER TABLE %I ADD CONSTRAINT %I CHECK (%I IN (%s))',
                NEW.table_name,
                v_check_name,
                NEW.field_name,
                v_enum_values_sql
            );
            EXECUTE v_alter_sql;
            
            RAISE NOTICE 'Added CHECK constraint "%" for enum field "%.%"',
                v_check_name, NEW.table_name, NEW.field_name;
        END;
    END IF;
    
    -- If unique_value is TRUE, create a partial unique index
    IF NEW.unique_value THEN
        DECLARE
            v_unique_idx_name TEXT;
            v_where_clause TEXT;
        BEGIN
            v_unique_idx_name := format('%s_%s_unique', NEW.table_name, NEW.field_name);
            -- For string types, exclude NULL and empty string from uniqueness enforcement
            IF format_to_json_type(NEW.format)::text = '"string"' THEN
                v_where_clause := format('%I IS NOT NULL AND %I != ''''', NEW.field_name, NEW.field_name);
            ELSE
                v_where_clause := format('%I IS NOT NULL', NEW.field_name);
            END IF;
            EXECUTE format(
                'CREATE UNIQUE INDEX IF NOT EXISTS %I ON %I(%I) WHERE %s',
                v_unique_idx_name,
                NEW.table_name,
                NEW.field_name,
                v_where_clause
            );
            RAISE NOTICE 'Created unique index "%" for field "%.%"', v_unique_idx_name, NEW.table_name, NEW.field_name;
        END;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION add_dd_field IS 
'Trigger function that adds a column to a table when a row is inserted into fields table.';

-- Apply trigger AFTER INSERT on fields
CREATE TRIGGER add_field_trigger
    AFTER INSERT ON fields
    FOR EACH ROW
    EXECUTE FUNCTION add_dd_field();

-- =====================================================
-- TRIGGER FUNCTION: UPDATE FIELD ON UPDATE
-- =====================================================

CREATE OR REPLACE FUNCTION update_dd_field()
RETURNS TRIGGER AS $$
DECLARE
    v_alter_sql TEXT;
    v_new_data_type TEXT;
    v_is_managed BOOLEAN;
    v_ref_id_column TEXT;
    v_fk_name TEXT;
    v_idx_name TEXT;
    v_on_delete TEXT;
BEGIN
    -- Check if the parent table is managed
    SELECT managed INTO v_is_managed FROM entities WHERE table_name = NEW.table_name;

    -- Prevent changing critical attributes
    IF OLD.table_name <> NEW.table_name THEN
        RAISE EXCEPTION 'Cannot change table_name of a field';
    END IF;
    
    IF OLD.field_name <> NEW.field_name THEN
        RAISE EXCEPTION 'Cannot rename field. Drop and recreate instead.';
    END IF;
    
    IF OLD.is_pk <> NEW.is_pk THEN
        RAISE EXCEPTION 'Cannot change primary key status of existing field';
    END IF;
    
    -- Prevent changing structural attributes of core fields
    -- Core fields can only have metadata updates (title, description, field_order, input_type, width)
    IF OLD.is_core THEN
        IF OLD.format <> NEW.format THEN
            RAISE EXCEPTION 'Cannot change format of core system field "%"', OLD.field_name;
        END IF;
        
        IF OLD.default_value IS DISTINCT FROM NEW.default_value THEN
            RAISE EXCEPTION 'Cannot change default value of core system field "%"', OLD.field_name;
        END IF;
        
        IF OLD.is_core <> NEW.is_core THEN
            RAISE EXCEPTION 'Cannot change is_core status of field "%"', OLD.field_name;
        END IF;
    END IF;
    
    -- Skip DDL operations if table is not managed (but allow metadata updates like description)
    IF NOT v_is_managed THEN
        -- Still allow updating column comments even if not managed
        IF OLD.description IS DISTINCT FROM NEW.description THEN
            IF NEW.description IS NOT NULL AND trim(NEW.description) != '' THEN
                EXECUTE format(
                    'COMMENT ON COLUMN %I.%I IS %L',
                    NEW.table_name,
                    NEW.field_name,
                    NEW.description
                );
            ELSE
                EXECUTE format(
                    'COMMENT ON COLUMN %I.%I IS NULL',
                    NEW.table_name,
                    NEW.field_name
                );
            END IF;
        END IF;
        
        RAISE NOTICE 'Skipping DDL operations for "%.%" (table managed=false)', NEW.table_name, NEW.field_name;
        RETURN NEW;
    END IF;
    
    -- Update column comment if description changed
    IF OLD.description IS DISTINCT FROM NEW.description THEN
        IF NEW.description IS NOT NULL AND trim(NEW.description) != '' THEN
            EXECUTE format(
                'COMMENT ON COLUMN %I.%I IS %L',
                NEW.table_name,
                NEW.field_name,
                NEW.description
            );
        ELSE
            EXECUTE format(
                'COMMENT ON COLUMN %I.%I IS NULL',
                NEW.table_name,
                NEW.field_name
            );
        END IF;
    END IF;
    
    -- Allow updating format (which changes data type)
    IF OLD.format <> NEW.format THEN
        v_new_data_type := format_to_data_type(NEW.format, NEW."precision");
        v_alter_sql := format(
            'ALTER TABLE %I ALTER COLUMN %I TYPE %s',
            NEW.table_name,
            NEW.field_name,
            v_new_data_type
        );
        EXECUTE v_alter_sql;
        RAISE NOTICE 'Changed column "%" type to % (format: %) in table "%"',
            NEW.field_name, v_new_data_type, NEW.format, NEW.table_name;
    END IF;
    
    -- Handle nullable change when format changes (e.g., text→reference would change nullability)
    IF OLD.format <> NEW.format THEN
        IF OLD.is_nullable <> NEW.is_nullable THEN
            IF NEW.is_nullable THEN
                v_alter_sql := format(
                    'ALTER TABLE %I ALTER COLUMN %I DROP NOT NULL',
                    NEW.table_name,
                    NEW.field_name
                );
            ELSE
                v_alter_sql := format(
                    'ALTER TABLE %I ALTER COLUMN %I SET NOT NULL',
                    NEW.table_name,
                    NEW.field_name
                );
            END IF;
            EXECUTE v_alter_sql;
            RAISE NOTICE 'Changed column "%" nullable to % in table "%"',
                NEW.field_name, NEW.is_nullable, NEW.table_name;
        END IF;
    END IF;
    
    -- Allow updating default value
    IF OLD.default_value IS DISTINCT FROM NEW.default_value THEN
        IF NEW.default_value IS NULL THEN
            v_alter_sql := format(
                'ALTER TABLE %I ALTER COLUMN %I DROP DEFAULT',
                NEW.table_name,
                NEW.field_name
            );
        ELSE
            v_alter_sql := format(
                'ALTER TABLE %I ALTER COLUMN %I SET DEFAULT %s',
                NEW.table_name,
                NEW.field_name,
                quote_default_value(NEW.default_value, format_to_data_type(NEW.format, NEW."precision"))
            );
        END IF;
        EXECUTE v_alter_sql;
        RAISE NOTICE 'Changed column "%" default value in table "%"',
            NEW.field_name, NEW.table_name;
    END IF;
    
    -- Handle foreign key reference changes
    IF OLD.format IN ('reference', 'parent') OR NEW.format IN ('reference', 'parent') THEN
        v_fk_name := format('%s_%s_fkey', NEW.table_name, NEW.field_name);
        v_idx_name := format('idx_%s_%s', NEW.table_name, NEW.field_name);
        
        -- Check if reference_table or reference_delete_mode changed
        IF (OLD.reference_table IS DISTINCT FROM NEW.reference_table) OR 
           (OLD.reference_delete_mode IS DISTINCT FROM NEW.reference_delete_mode) OR
           (OLD.format <> NEW.format) THEN
            
            -- Drop existing foreign key constraint if it exists
            IF OLD.format IN ('reference', 'parent') THEN
                EXECUTE format(
                    'ALTER TABLE %I DROP CONSTRAINT IF EXISTS %I',
                    NEW.table_name,
                    v_fk_name
                );
                RAISE NOTICE 'Dropped foreign key constraint "%"', v_fk_name;
            END IF;
            
            -- Add new foreign key constraint if format is now 'reference' or 'parent'
            IF NEW.format IN ('reference', 'parent') AND NEW.reference_table IS NOT NULL AND NEW.reference_table != '' THEN
                -- Get the id_column of the referenced table
                SELECT id_column INTO v_ref_id_column
                FROM entities
                WHERE table_name = NEW.reference_table;
                
                IF v_ref_id_column IS NULL THEN
                    RAISE EXCEPTION 'Referenced table "%" not found', NEW.reference_table;
                END IF;
                
                -- Determine ON DELETE behavior
                IF NEW.reference_delete_mode = 'clear' THEN
                    v_on_delete := 'SET NULL';
                ELSIF NEW.reference_delete_mode = 'cascade' THEN
                    v_on_delete := 'CASCADE';
                ELSE
                    v_on_delete := 'RESTRICT';
                END IF;
                
                -- Add foreign key constraint
                v_alter_sql := format(
                    'ALTER TABLE %I ADD CONSTRAINT %I FOREIGN KEY (%I) REFERENCES %I(%I) ON DELETE %s',
                    NEW.table_name,
                    v_fk_name,
                    NEW.field_name,
                    NEW.reference_table,
                    v_ref_id_column,
                    v_on_delete
                );
                EXECUTE v_alter_sql;
                
                -- Create index for foreign key if it doesn't exist
                v_alter_sql := format(
                    'CREATE INDEX IF NOT EXISTS %I ON %I(%I)',
                    v_idx_name,
                    NEW.table_name,
                    NEW.field_name
                );
                EXECUTE v_alter_sql;
                
                RAISE NOTICE 'Updated foreign key "%" from %.% to %.% with ON DELETE %',
                    v_fk_name, NEW.table_name, NEW.field_name, NEW.reference_table, v_ref_id_column, v_on_delete;
            ELSIF NEW.format NOT IN ('reference', 'parent') AND OLD.format IN ('reference', 'parent') THEN
                -- Drop index if format changed from reference/parent to something else
                EXECUTE format(
                    'DROP INDEX IF EXISTS %I',
                    v_idx_name
                );
                RAISE NOTICE 'Dropped index "%" for field "%.%"', v_idx_name, NEW.table_name, NEW.field_name;
            END IF;
        END IF;
    END IF;
    
    -- Handle enum CHECK constraint changes
    IF OLD.format = 'enum' OR NEW.format = 'enum' THEN
        DECLARE
            v_check_name TEXT;
            v_enum_values_sql TEXT;
            v_effective_enum JSONB;
        BEGIN
            v_check_name := format('%s_%s_check', NEW.table_name, NEW.field_name);
            
            -- Check if enum_values, input_type, or format changed
            IF (OLD.enum_values IS DISTINCT FROM NEW.enum_values)
               OR (OLD.format <> NEW.format)
               OR (OLD.input_type IS DISTINCT FROM NEW.input_type) THEN
                
                -- Drop existing CHECK constraint if it exists
                IF OLD.format = 'enum' THEN
                    EXECUTE format(
                        'ALTER TABLE %I DROP CONSTRAINT IF EXISTS %I',
                        NEW.table_name,
                        v_check_name
                    );
                    RAISE NOTICE 'Dropped CHECK constraint "%"', v_check_name;
                END IF;
                
                -- Add new CHECK constraint if format is now 'enum'
                IF NEW.format = 'enum' AND NEW.enum_values IS NOT NULL AND jsonb_array_length(NEW.enum_values) > 0 THEN
                    v_effective_enum := effective_enum_values(NEW.input_type, NEW.enum_values);

                    -- Build SQL array from JSONB array for IN clause
                    v_enum_values_sql := (
                        SELECT string_agg(quote_literal(value::text), ', ')
                        FROM jsonb_array_elements_text(v_effective_enum) AS value
                    );
                    
                    -- Add CHECK constraint
                    v_alter_sql := format(
                        'ALTER TABLE %I ADD CONSTRAINT %I CHECK (%I IN (%s))',
                        NEW.table_name,
                        v_check_name,
                        NEW.field_name,
                        v_enum_values_sql
                    );
                    EXECUTE v_alter_sql;
                    
                    RAISE NOTICE 'Updated CHECK constraint "%" for enum field "%.%"',
                        v_check_name, NEW.table_name, NEW.field_name;
                END IF;
            END IF;
        END;
    END IF;
    
    -- Handle unique_value changes
    IF OLD.unique_value IS DISTINCT FROM NEW.unique_value THEN
        DECLARE
            v_unique_idx_name TEXT;
            v_where_clause TEXT;
        BEGIN
            v_unique_idx_name := format('%s_%s_unique', NEW.table_name, NEW.field_name);
            IF NEW.unique_value THEN
                -- Create partial unique index
                IF format_to_json_type(NEW.format)::text = '"string"' THEN
                    v_where_clause := format('%I IS NOT NULL AND %I != ''''', NEW.field_name, NEW.field_name);
                ELSE
                    v_where_clause := format('%I IS NOT NULL', NEW.field_name);
                END IF;
                EXECUTE format(
                    'CREATE UNIQUE INDEX IF NOT EXISTS %I ON %I(%I) WHERE %s',
                    v_unique_idx_name,
                    NEW.table_name,
                    NEW.field_name,
                    v_where_clause
                );
                RAISE NOTICE 'Created unique index "%" for field "%.%"', v_unique_idx_name, NEW.table_name, NEW.field_name;
            ELSE
                -- Drop unique index
                EXECUTE format('DROP INDEX IF EXISTS %I', v_unique_idx_name);
                RAISE NOTICE 'Dropped unique index "%" for field "%.%"', v_unique_idx_name, NEW.table_name, NEW.field_name;
            END IF;
        END;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION update_dd_field IS 
'Trigger function that updates column properties when a field is updated.';

-- Apply trigger AFTER UPDATE on fields
CREATE TRIGGER update_field_trigger
    AFTER UPDATE ON fields
    FOR EACH ROW
    EXECUTE FUNCTION update_dd_field();

-- =====================================================
-- TRIGGER FUNCTION: DELETE FIELD ON DELETE
-- =====================================================

CREATE OR REPLACE FUNCTION delete_dd_field()
RETURNS TRIGGER AS $$
DECLARE
    v_is_managed BOOLEAN;
    v_table_exists BOOLEAN;
    v_fk_name TEXT;
    v_idx_name TEXT;
BEGIN
    -- Check if the parent table still exists in entities table
    -- If it doesn't exist, this deletion is part of a CASCADE from table deletion, so allow it
    SELECT EXISTS(SELECT 1 FROM entities WHERE table_name = OLD.table_name) INTO v_table_exists;
    
    IF NOT v_table_exists THEN
        -- Table is being deleted, allow cascade deletion of all fields including core fields
        RETURN OLD;
    END IF;
    
    -- Prevent deletion of core fields (id, label, created_at, updated_at) for standalone field deletions
    IF OLD.is_core THEN
        RAISE EXCEPTION 'Cannot delete core system field "%". Core fields (id, label, created_at, updated_at) cannot be deleted.', OLD.field_name;
    END IF;
    
    -- Check if the parent table is managed
    SELECT managed INTO v_is_managed FROM entities WHERE table_name = OLD.table_name;
    
    IF NOT v_is_managed THEN
        RAISE NOTICE 'Skipping field deletion for "%.%" (table managed=false)', OLD.table_name, OLD.field_name;
        RETURN OLD;
    END IF;
    
    -- Drop foreign key constraint if this is a reference or parent field
    IF OLD.format IN ('reference', 'parent') THEN
        v_fk_name := format('%s_%s_fkey', OLD.table_name, OLD.field_name);
        EXECUTE format(
            'ALTER TABLE %I DROP CONSTRAINT IF EXISTS %I',
            OLD.table_name,
            v_fk_name
        );
        RAISE NOTICE 'Dropped foreign key constraint "%"', v_fk_name;
        
        -- Drop index for foreign key
        v_idx_name := format('idx_%s_%s', OLD.table_name, OLD.field_name);
        EXECUTE format(
            'DROP INDEX IF EXISTS %I',
            v_idx_name
        );
        RAISE NOTICE 'Dropped index "%"', v_idx_name;
    END IF;
    
    -- Drop unique index if unique_value was set
    IF OLD.unique_value THEN
        EXECUTE format('DROP INDEX IF EXISTS %I', format('%s_%s_unique', OLD.table_name, OLD.field_name));
        RAISE NOTICE 'Dropped unique index "%"', format('%s_%s_unique', OLD.table_name, OLD.field_name);
    END IF;
    
    -- Drop the column (CASCADE to drop any dependent objects like generated columns)
    EXECUTE format(
        'ALTER TABLE %I DROP COLUMN IF EXISTS %I CASCADE',
        OLD.table_name,
        OLD.field_name
    );
    
    RAISE NOTICE 'Dropped column "%" from table "%"',
        OLD.field_name, OLD.table_name;
    
    RETURN OLD;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION delete_dd_field IS 
'Trigger function that drops a column when a field is deleted.';

-- Apply trigger BEFORE DELETE on fields
CREATE TRIGGER delete_field_trigger
    BEFORE DELETE ON fields
    FOR EACH ROW
    EXECUTE FUNCTION delete_dd_field();

-- =====================================================
-- TRIGGER FUNCTION: DELETE TABLE ON DELETE
-- =====================================================

CREATE OR REPLACE FUNCTION delete_dd_table()
RETURNS TRIGGER AS $$
BEGIN
    -- Skip DDL execution if table is not managed
    IF NOT OLD.managed THEN
        RAISE NOTICE 'Skipping table deletion for "%" (managed=false)', OLD.table_name;
        RETURN OLD;
    END IF;
    
    -- Drop the table (CASCADE will drop all dependent objects)
    EXECUTE format('DROP TABLE IF EXISTS %I CASCADE', OLD.table_name);
    
    RAISE NOTICE 'Dropped table "%"', OLD.table_name;
    
    RETURN OLD;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION delete_dd_table IS 
'Trigger function that drops a table when a row is deleted from entities table.';

-- Apply trigger BEFORE DELETE on entities
-- Note: Fields will be deleted via CASCADE on the foreign key
CREATE TRIGGER delete_table_trigger
    BEFORE DELETE ON entities
    FOR EACH ROW
    EXECUTE FUNCTION delete_dd_table();

-- =====================================================
-- FULL-TEXT SEARCH FUNCTIONS AND TRIGGERS
-- =====================================================
-- Manages search_vector column and GIN index based on searchable fields
-- Automatically maintains entities.searchable based on related fields

-- =====================================================
-- HELPER FUNCTION: Update search_vector column and index
-- =====================================================
-- This function generates and executes DDL to create/recreate the search_vector
-- column and GIN index for a table based on its searchable fields

CREATE OR REPLACE FUNCTION update_search_vector_column(p_table_name TEXT)
RETURNS VOID AS $$
DECLARE
    v_searchable_fields TEXT[];
    v_search_expr TEXT;
    v_table_exists BOOLEAN;
BEGIN
    -- Note: no rbac.uid() here — this function is called by triggers
    -- during migrations when there is no JWT context.

    -- Suppress IF NOT EXISTS/IF EXISTS notices
    SET LOCAL client_min_messages = WARNING;

    -- Check if the table actually exists in the database
    SELECT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'public' AND table_name = p_table_name
    ) INTO v_table_exists;
    
    IF NOT v_table_exists THEN

        RETURN;
    END IF;
    
    -- Get all searchable text-based fields for this table that actually exist as columns
    SELECT ARRAY_AGG(field_name ORDER BY field_order)
    INTO v_searchable_fields
    FROM fields f
    WHERE f.table_name = p_table_name
      AND f.searchable = TRUE
      AND format_to_json_type(f.format)::text = '"string"'  -- Only text-based fields
      AND EXISTS (  -- Only include fields that actually exist as columns in the table
          SELECT 1 FROM information_schema.columns c
          WHERE c.table_schema = 'public'
            AND c.table_name = p_table_name
            AND c.column_name = f.field_name
      );
    
    -- If no searchable fields, drop the search_vector column and index if they exist
    IF v_searchable_fields IS NULL OR array_length(v_searchable_fields, 1) IS NULL THEN
        -- Drop the GIN index first
        EXECUTE format(
            'DROP INDEX IF EXISTS %I',
            p_table_name || '_search_vector_idx'
        );
        
        -- Drop the search_vector column
        EXECUTE format(
            'ALTER TABLE %I DROP COLUMN IF EXISTS search_vector',
            p_table_name
        );
        

        RETURN;
    END IF;
    
    -- Build the tsvector expression by concatenating all searchable fields
    -- Using coalesce to handle NULL values and setweight for ranking
    v_search_expr := (
        SELECT string_agg(
            format('setweight(to_tsvector(''simple'', coalesce(%I, '''')), ''%s'')',
                f.field_name,
                CASE 
                    WHEN f.ctype = 'label' THEN 'A'  -- Label fields get highest weight
                    WHEN f.field_name IN ('title', 'name') THEN 'A'  -- Title/name fields
                    WHEN f.field_name LIKE '%description%' THEN 'B'  -- Description fields
                    ELSE 'C'  -- Other searchable fields
                END
            ),
            ' || '
            ORDER BY f.field_order
        )
        FROM fields f
        WHERE f.table_name = p_table_name
          AND f.searchable = TRUE
          AND format_to_json_type(f.format)::text = '"string"'
          AND EXISTS (  -- Only include fields that actually exist as columns
              SELECT 1 FROM information_schema.columns c
              WHERE c.table_schema = 'public'
                AND c.table_name = p_table_name
                AND c.column_name = f.field_name
          )
    );
    
    -- Drop existing search_vector column if it exists
    EXECUTE format(
        'ALTER TABLE %I DROP COLUMN IF EXISTS search_vector',
        p_table_name
    );
    
    -- Create the search_vector column as GENERATED ALWAYS
    EXECUTE format(
        'ALTER TABLE %I ADD COLUMN search_vector tsvector GENERATED ALWAYS AS (%s) STORED',
        p_table_name,
        v_search_expr
    );
    
    -- Drop existing GIN index if it exists
    EXECUTE format(
        'DROP INDEX IF EXISTS %I',
        p_table_name || '_search_vector_idx'
    );
    
    -- Create GIN index on the search_vector column
    EXECUTE format(
        'CREATE INDEX %I ON %I USING GIN (search_vector)',
        p_table_name || '_search_vector_idx',
        p_table_name
    );

END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION update_search_vector_column IS 
'Creates or updates the search_vector GENERATED column and GIN index for a table based on searchable fields. Works for both managed and core tables as long as the physical table exists.';

-- =====================================================
-- HELPER FUNCTION: Update entities.searchable flag
-- =====================================================
-- Auto-maintains the searchable flag on tables based on related fields

CREATE OR REPLACE FUNCTION update_table_searchable_flag(p_table_name TEXT)
RETURNS VOID AS $$
DECLARE
    v_has_searchable_fields BOOLEAN;
BEGIN
    -- Note: no rbac.uid() here — this function is called by triggers
    -- during migrations when there is no JWT context.

    -- Check if any fields in this table are searchable
    SELECT EXISTS (
        SELECT 1 FROM fields
        WHERE table_name = p_table_name
          AND searchable = TRUE
    ) INTO v_has_searchable_fields;

    -- Update the searchable flag on the entities record
    UPDATE entities 
    SET searchable = v_has_searchable_fields
    WHERE table_name = p_table_name;

END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION update_table_searchable_flag IS 
'Auto-maintains the searchable flag on entities table based on whether any related fields are searchable.';

-- =====================================================
-- TRIGGER FUNCTION: Handle field searchable changes
-- =====================================================
-- Detects when searchable field list changes and updates search_vector accordingly

CREATE OR REPLACE FUNCTION handle_field_searchable_change()
RETURNS TRIGGER AS $$
DECLARE
    v_searchable_changed BOOLEAN := FALSE;
    v_table_name_to_update TEXT;
BEGIN
    -- Determine which table needs updating and if searchable changed
    IF TG_OP = 'INSERT' THEN
        v_table_name_to_update := NEW.table_name;
        v_searchable_changed := (NEW.searchable = TRUE);
    ELSIF TG_OP = 'UPDATE' THEN
        v_table_name_to_update := NEW.table_name;
        v_searchable_changed := (OLD.searchable IS DISTINCT FROM NEW.searchable);
    ELSIF TG_OP = 'DELETE' THEN
        v_table_name_to_update := OLD.table_name;
        v_searchable_changed := (OLD.searchable = TRUE);
    END IF;
    
    -- Update search vector if searchable fields changed
    -- The add_field_trigger runs alphabetically before this trigger, so the column already exists
    IF v_searchable_changed THEN
        PERFORM update_search_vector_column(v_table_name_to_update);
    END IF;
    
    -- Always update the table searchable flag when fields change
    PERFORM update_table_searchable_flag(v_table_name_to_update);
    
    -- Return appropriate value based on operation
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    ELSE
        RETURN NEW;
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION handle_field_searchable_change IS 
'Trigger function that updates search_vector column and GIN index when searchable fields are created, updated, or deleted. The add_field_trigger executes before this trigger (alphabetically), ensuring the physical column exists before we update the search_vector.';

-- Apply trigger AFTER INSERT/UPDATE/DELETE on fields
CREATE TRIGGER handle_field_searchable_change_trigger
    AFTER INSERT OR UPDATE OR DELETE ON fields
    FOR EACH ROW
    EXECUTE FUNCTION handle_field_searchable_change();

COMMENT ON TRIGGER handle_field_searchable_change_trigger ON fields IS
'Automatically updates search_vector column and index when field searchable status changes';

-- =====================================================
-- TRIGGER FUNCTION: Recompute entities.searchable on direct update
-- =====================================================
-- Ensures entities.searchable always reflects the actual state of fields
-- even if someone tries to update it directly

CREATE OR REPLACE FUNCTION enforce_table_searchable_consistency()
RETURNS TRIGGER AS $$
DECLARE
    v_computed_searchable BOOLEAN;
BEGIN
    -- If searchable was changed, recompute it from fields and override the value
    IF OLD.searchable IS DISTINCT FROM NEW.searchable THEN
        -- Compute the correct value from fields
        SELECT EXISTS (
            SELECT 1 FROM fields 
            WHERE table_name = NEW.table_name 
              AND searchable = TRUE
        ) INTO v_computed_searchable;
        
        -- Override any manual change with the computed value
        NEW.searchable := v_computed_searchable;

    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SET search_path = public;

COMMENT ON FUNCTION enforce_table_searchable_consistency IS 
'Trigger function that ensures entities.searchable always reflects the status of related fields, preventing manual overrides.';

CREATE TRIGGER enforce_table_searchable_consistency_trigger
    BEFORE UPDATE ON entities
    FOR EACH ROW
    WHEN (OLD.searchable IS DISTINCT FROM NEW.searchable)
    EXECUTE FUNCTION enforce_table_searchable_consistency();

COMMENT ON TRIGGER enforce_table_searchable_consistency_trigger ON entities IS
'Ensures entities.searchable is always consistent with related fields, preventing manual changes';
-- =====================================================
-- IS_CHILD FUNCTIONS AND TRIGGERS
-- =====================================================
-- Manages entities.is_child based on whether any field has format='parent'
-- Automatically maintains entities.is_child similar to searchable

-- =====================================================
-- HELPER FUNCTION: Update entities.is_child flag
-- =====================================================

CREATE OR REPLACE FUNCTION update_table_is_child_flag(p_table_name TEXT)
RETURNS VOID AS $$
DECLARE
    v_has_parent_fields BOOLEAN;
BEGIN
    -- Note: no rbac.uid() here — this function is called by triggers
    -- during migrations when there is no JWT context.

    SELECT EXISTS (
        SELECT 1 FROM fields
        WHERE table_name = p_table_name
          AND format = 'parent'
    ) INTO v_has_parent_fields;
    
    UPDATE entities 
    SET is_child = v_has_parent_fields
    WHERE table_name = p_table_name;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION update_table_is_child_flag IS 
'Auto-maintains the is_child flag on entities table based on whether any related fields have format=''parent''.';

-- =====================================================
-- TRIGGER FUNCTION: Handle field parent format changes
-- =====================================================

CREATE OR REPLACE FUNCTION handle_field_parent_format_change()
RETURNS TRIGGER AS $$
DECLARE
    v_parent_changed BOOLEAN := FALSE;
    v_table_name_to_update TEXT;
BEGIN
    IF TG_OP = 'INSERT' THEN
        v_table_name_to_update := NEW.table_name;
        v_parent_changed := (NEW.format = 'parent');
    ELSIF TG_OP = 'UPDATE' THEN
        v_table_name_to_update := NEW.table_name;
        v_parent_changed := (OLD.format IS DISTINCT FROM NEW.format AND (OLD.format = 'parent' OR NEW.format = 'parent'));
    ELSIF TG_OP = 'DELETE' THEN
        v_table_name_to_update := OLD.table_name;
        v_parent_changed := (OLD.format = 'parent');
    END IF;

    IF v_parent_changed THEN
        PERFORM update_table_is_child_flag(v_table_name_to_update);
    END IF;

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    ELSE
        RETURN NEW;
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION handle_field_parent_format_change IS 
'Trigger function that updates entities.is_child when fields with format=''parent'' are created, updated, or deleted.';

CREATE TRIGGER handle_field_parent_format_change_trigger
    AFTER INSERT OR UPDATE OR DELETE ON fields
    FOR EACH ROW
    EXECUTE FUNCTION handle_field_parent_format_change();

COMMENT ON TRIGGER handle_field_parent_format_change_trigger ON fields IS
'Automatically updates entities.is_child when field parent format status changes';

-- =====================================================
-- TRIGGER FUNCTION: Recompute entities.is_child on direct update
-- =====================================================

CREATE OR REPLACE FUNCTION enforce_table_is_child_consistency()
RETURNS TRIGGER AS $$
DECLARE
    v_computed_is_child BOOLEAN;
BEGIN
    IF OLD.is_child IS DISTINCT FROM NEW.is_child THEN
        SELECT EXISTS (
            SELECT 1 FROM fields 
            WHERE table_name = NEW.table_name 
              AND format = 'parent'
        ) INTO v_computed_is_child;

        NEW.is_child := v_computed_is_child;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SET search_path = public;

COMMENT ON FUNCTION enforce_table_is_child_consistency IS 
'Trigger function that ensures entities.is_child always reflects the status of related fields, preventing manual overrides.';

CREATE TRIGGER enforce_table_is_child_consistency_trigger
    BEFORE UPDATE ON entities
    FOR EACH ROW
    WHEN (OLD.is_child IS DISTINCT FROM NEW.is_child)
    EXECUTE FUNCTION enforce_table_is_child_consistency();

COMMENT ON TRIGGER enforce_table_is_child_consistency_trigger ON entities IS
'Ensures entities.is_child is always consistent with related fields, preventing manual changes';

-- =====================================================
-- GET RECORD BY ID
-- =====================================================
-- Looks up an entity by table_name, reads its id_column, then queries the
-- physical table for the row matching the supplied id value. Returns the
-- full row as JSONB, or NULL when the entity or record does not exist.

CREATE OR REPLACE FUNCTION get_record_by_id(p_entity_name TEXT, p_id INTEGER)
RETURNS JSONB AS $$
DECLARE
    v_id_column TEXT;
    v_result JSONB;
BEGIN
    -- Look up the entity to find its id_column
    SELECT id_column INTO v_id_column
    FROM entities
    WHERE table_name = p_entity_name;

    -- Entity not found
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    -- Query the physical table for the record
    EXECUTE format(
        'SELECT row_to_json(t)::jsonb FROM %I t WHERE %I = $1 LIMIT 1',
        p_entity_name, v_id_column
    ) INTO v_result USING p_id;

    RETURN v_result;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION get_record_by_id IS
'Returns a single entity record as JSONB by looking up the entity id_column and querying the physical table. Returns NULL when the entity or record does not exist.';

-- Revoke default PUBLIC execute on all DDL functions defined in this file
REVOKE EXECUTE ON FUNCTION get_record_by_id(TEXT, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_record_by_id(TEXT, INTEGER) TO semantius_user;
REVOKE EXECUTE ON FUNCTION format_to_data_type(TEXT, SMALLINT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION effective_enum_values(TEXT, JSONB) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION effective_enum_default(TEXT, TEXT, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION effective_enum_values(TEXT, JSONB) TO semantius_user;
GRANT EXECUTE ON FUNCTION effective_enum_default(TEXT, TEXT, JSONB) TO semantius_user;
REVOKE EXECUTE ON FUNCTION is_nullable(TEXT) FROM PUBLIC;
-- Grant is_nullable to semantius_user: GENERATED ALWAYS columns evaluate their formula in the
-- inserting user's context, so semantius_user needs EXECUTE to insert rows into the fields table.
GRANT EXECUTE ON FUNCTION is_nullable(TEXT) TO semantius_user;
REVOKE EXECUTE ON FUNCTION format_to_json_type(TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION quote_default_value(TEXT, TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION create_dd_table() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION add_dd_field() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION update_dd_field() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION delete_dd_field() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION delete_dd_table() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION update_search_vector_column(TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION update_table_searchable_flag(TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION handle_field_searchable_change() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION enforce_table_searchable_consistency() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION update_table_is_child_flag(TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION handle_field_parent_format_change() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION enforce_table_is_child_consistency() FROM PUBLIC;
`,
    "0072_apply_core_fts": `-- =====================================================
-- APPLY FTS TO CORE DD TABLES
-- =====================================================
-- Core tables (entities, fields, users, modules, roles, permissions)
-- are created in 0060_dd_schema.sql before the DD trigger system (0070),
-- so their field metadata inserts don't fire handle_field_searchable_change_trigger.
-- We apply search_vector columns explicitly here.
-- Tables created later via the DD system (e.g. webhook_receivers in 0100)
-- get FTS automatically through the trigger.

-- Apply search_vector to core tables that have searchable fields
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
`,
    "0080_public_functions": `-- =====================================================
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

-- Internal helper that builds a schema JSON for a single table.
-- Assumes the caller has already verified the table exists and the
-- user has the required view permission. Used by both get_schema()
-- and get_schemas() so that any future change applies to both.
CREATE OR REPLACE FUNCTION public.build_schema_for_table(p_table_name TEXT)
RETURNS JSON AS $$
DECLARE
    v_table_record RECORD;
    v_properties JSON;
    v_required_fields JSON;
    v_children JSON;
    v_result JSON;
BEGIN
    PERFORM rbac.uid();

    SELECT * INTO v_table_record
    FROM entities
    WHERE table_name = p_table_name;

    -- Return NULL if the table does not exist (callers should verify before calling)
    IF NOT FOUND THEN
        RETURN NULL;
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
'Internal helper that builds a schema JSON for a single table without performing permission checks. Used by get_schema() and get_schemas() to ensure consistent output from a single implementation.';

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
`,
    "0090_notify_triggers": `-- =====================================================
-- POSTGREST SCHEMA RELOAD NOTIFICATIONS
-- =====================================================
-- Send NOTIFY pgrst commands when tables or fields are modified.
-- All notifications go through common.refresh_schema_cache() which
-- also keeps the db_version timestamp in _settings up to date.
-- =====================================================

-- =====================================================
-- COMMON: SCHEMA CACHE REFRESH
-- =====================================================
-- Central function called by all DDL and DML triggers.
-- Sends NOTIFY pgrst, 'reload schema' and writes the current
-- timestamp into _settings(name='db_version') so clients can
-- detect that the schema has changed without polling PostgREST.

CREATE OR REPLACE FUNCTION common.refresh_schema_cache() RETURNS void AS $$
DECLARE
    v_db_version_ts TEXT;
    v_current       TEXT;
BEGIN
    -- ISO 8601 datetime (e.g. 2026-03-20T22:21:49.813267+00:00)
    v_db_version_ts := to_char(clock_timestamp() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"+00:00"');

    -- Update db_version only when the stored value is outdated (or missing)
    SELECT value INTO v_current FROM _settings WHERE name = 'db_version';
    IF NOT FOUND OR v_current < v_db_version_ts THEN
        INSERT INTO _settings (name, value) VALUES ('db_version', v_db_version_ts)
        ON CONFLICT (name) DO UPDATE SET value = EXCLUDED.value;
    END IF;

    -- Notify PostgREST to reload its schema cache
    NOTIFY pgrst, 'reload schema';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, common;

COMMENT ON FUNCTION common.refresh_schema_cache() IS
'Notifies PostgREST to reload its schema cache and updates the db_version timestamp in _settings.';

-- =====================================================
-- TRIGGER FUNCTION: NOTIFY ON TABLES CHANGES
-- =====================================================

CREATE OR REPLACE FUNCTION notify_pgrst_tables()
RETURNS TRIGGER AS $$
BEGIN
    PERFORM common.refresh_schema_cache();

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    ELSE
        RETURN NEW;
    END IF;
END;
$$ LANGUAGE plpgsql SET search_path = public;

COMMENT ON FUNCTION notify_pgrst_tables IS
'Trigger function that notifies PostgREST to reload schema when entities are modified.';

-- Apply trigger on entities table
CREATE TRIGGER notify_pgrst_on_tables_change
    AFTER INSERT OR UPDATE OR DELETE ON entities
    FOR EACH ROW
    EXECUTE FUNCTION notify_pgrst_tables();

-- =====================================================
-- TRIGGER FUNCTION: NOTIFY ON FIELDS CHANGES
-- =====================================================

CREATE OR REPLACE FUNCTION notify_pgrst_fields()
RETURNS TRIGGER AS $$
BEGIN
    PERFORM common.refresh_schema_cache();

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    ELSE
        RETURN NEW;
    END IF;
END;
$$ LANGUAGE plpgsql SET search_path = public;

COMMENT ON FUNCTION notify_pgrst_fields IS
'Trigger function that notifies PostgREST to reload schema when fields are modified.';

-- Apply trigger on fields table
CREATE TRIGGER notify_pgrst_on_fields_change
    AFTER INSERT OR UPDATE OR DELETE ON fields
    FOR EACH ROW
    EXECUTE FUNCTION notify_pgrst_fields();

-- =====================================================
-- DDL EVENT TRIGGERS: NOTIFY ON SCHEMA CHANGES
-- =====================================================
-- Fire on every DDL command that PostgREST cares about so its
-- schema cache stays in sync automatically.

-- Watch CREATE and ALTER commands
CREATE OR REPLACE FUNCTION pgrst_ddl_watch() RETURNS event_trigger AS $$
DECLARE
    cmd record;
BEGIN
    FOR cmd IN SELECT * FROM pg_event_trigger_ddl_commands()
    LOOP
        IF cmd.command_tag IN (
          'CREATE SCHEMA', 'ALTER SCHEMA'
        , 'CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO', 'ALTER TABLE'
        , 'CREATE FOREIGN TABLE', 'ALTER FOREIGN TABLE'
        , 'CREATE VIEW', 'ALTER VIEW'
        , 'CREATE MATERIALIZED VIEW', 'ALTER MATERIALIZED VIEW'
        , 'CREATE FUNCTION', 'ALTER FUNCTION'
        , 'CREATE TRIGGER'
        , 'CREATE TYPE', 'ALTER TYPE'
        , 'CREATE RULE'
        , 'COMMENT'
        )
        -- don't notify for CREATE TEMP table or other pg_temp objects
        AND cmd.schema_name IS DISTINCT FROM 'pg_temp'
        THEN
            PERFORM common.refresh_schema_cache();
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql SET search_path = public;

-- Watch DROP commands
CREATE OR REPLACE FUNCTION pgrst_drop_watch() RETURNS event_trigger AS $$
DECLARE
    obj record;
BEGIN
    FOR obj IN SELECT * FROM pg_event_trigger_dropped_objects()
    LOOP
        IF obj.object_type IN (
          'schema'
        , 'table'
        , 'foreign table'
        , 'view'
        , 'materialized view'
        , 'function'
        , 'trigger'
        , 'type'
        , 'rule'
        )
        AND obj.is_temporary IS false -- no pg_temp objects
        THEN
            PERFORM common.refresh_schema_cache();
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql SET search_path = public;

CREATE EVENT TRIGGER pgrst_ddl_watch
    ON ddl_command_end
    EXECUTE PROCEDURE pgrst_ddl_watch();

CREATE EVENT TRIGGER pgrst_drop_watch
    ON sql_drop
    EXECUTE PROCEDURE pgrst_drop_watch();

-- Revoke default PUBLIC execute on notify trigger functions
REVOKE EXECUTE ON FUNCTION notify_pgrst_tables() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION notify_pgrst_fields() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION pgrst_ddl_watch() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION pgrst_drop_watch() FROM PUBLIC;

-- Allow semantius_user to call common.refresh_schema_cache() so that DML
-- triggers on entities/fields (which fire in the session user's context) can
-- invoke the function.  The function itself is SECURITY DEFINER, so it
-- always runs as the owner and is the only code that touches _settings.
GRANT USAGE ON SCHEMA common TO semantius_user;
GRANT EXECUTE ON FUNCTION common.refresh_schema_cache() TO semantius_user;
`,
    "0110_apikeys": `-- =====================================================
-- API KEYS TABLE AND FUNCTIONS
-- =====================================================
-- Internal table for storing API keys with hashed secrets.
-- RLS is enabled with no policies so it is only accessible
-- internally via SECURITY DEFINER functions (same pattern as _settings).
-- No entries in entities/fields - not exposed in the UI.

-- =====================================================
-- _APIKEYS TABLE
-- =====================================================

CREATE TABLE _apikeys (
    id SERIAL PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    key_id TEXT NOT NULL UNIQUE,
    secret_hash TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    last_used_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_apikeys_user_id ON _apikeys(user_id);
CREATE UNIQUE INDEX idx_apikeys_key_id ON _apikeys(key_id);

ALTER TABLE _apikeys ENABLE ROW LEVEL SECURITY;

-- Deny-all policy so the table is never exposed through PostgREST / the Data API.
-- SECURITY DEFINER functions can still read and write it.
CREATE POLICY apikeys_deny_all ON _apikeys
    FOR ALL
    TO semantius_user
    USING (false)
    WITH CHECK (false);

GRANT SELECT, INSERT, UPDATE, DELETE ON _apikeys TO semantius_user;
GRANT USAGE, SELECT ON SEQUENCE _apikeys_id_seq TO semantius_user;

-- =====================================================
-- GENERATE API KEY FUNCTION
-- =====================================================
-- Generates a new API key for a user.
-- When p_user_id = 0, uses the current session user id and prefix "uk-".
-- When p_user_id <> 0, validates user exists and requires admin permission,
-- uses prefix "sk-".
-- p_description is an optional human-readable label stored with the key.
-- Returns the full API key (only time the secret is visible in plaintext).
-- Accessible via PostgREST RPC by all authenticated users.

CREATE OR REPLACE FUNCTION public.generate_api_key(p_user_id INTEGER, p_description TEXT DEFAULT '')
RETURNS JSONB AS $$
DECLARE
    v_target_user_id INTEGER;
    v_key_prefix TEXT;
    v_new_key_id TEXT;
    v_new_secret TEXT;
    v_full_api_key TEXT;
    v_done BOOLEAN := FALSE;
BEGIN
    -- Authenticate the caller
    PERFORM rbac.uid();

    IF p_user_id = 0 THEN
        -- Use the current session user id
        v_target_user_id := rbac.user_id();
        v_key_prefix := 'uk-';
    ELSE
        -- Require admin permission for generating keys for other users
        PERFORM rbac.require_permission('admin');

        -- Validate the target user exists
        IF NOT EXISTS (SELECT 1 FROM users WHERE id = p_user_id) THEN
            RAISE EXCEPTION 'User with id % does not exist', p_user_id
                USING ERRCODE = 'invalid_parameter_value';
        END IF;

        v_target_user_id := p_user_id;
        v_key_prefix := 'sk-';
    END IF;

    -- Loop until we generate a unique key_id
    WHILE NOT v_done LOOP
        BEGIN
            -- Generate a 12-char random public ID (6 bytes = 12 hex chars)
            v_new_key_id := v_key_prefix || encode(gen_random_bytes(6), 'hex');

            -- Generate a 32-char random secret (16 bytes = 32 hex chars)
            v_new_secret := encode(gen_random_bytes(16), 'hex');

            -- Attempt to insert with hashed secret and description
            INSERT INTO _apikeys (user_id, key_id, secret_hash, description)
            VALUES (v_target_user_id, v_new_key_id, crypt(v_new_secret, gen_salt('bf', 10)), COALESCE(p_description, ''));

            -- If we reach here, insert was successful
            v_full_api_key := v_new_key_id || '-' || v_new_secret;
            v_done := TRUE;

        EXCEPTION WHEN unique_violation THEN
            -- If key_id already exists, loop again to generate a new one
            NULL;
        END;
    END LOOP;

    RETURN jsonb_build_object('api_key', v_full_api_key, 'key_id', v_new_key_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION public.generate_api_key IS
'Generates a new API key. Pass 0 to generate for current user (uk- prefix), or a user id for admin-generated keys (sk- prefix). Optionally pass a description. Returns a JSON object with an "api_key" field containing the full key (only time the secret is visible in plaintext).';

-- Grant execute to semantius_user (accessible via PostgREST RPC)
REVOKE EXECUTE ON FUNCTION public.generate_api_key(INTEGER, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.generate_api_key(INTEGER, TEXT) TO semantius_user;

-- =====================================================
-- VALIDATE API KEY FUNCTION (INTERNAL ONLY)
-- =====================================================
-- Validates an API key by splitting it into key_id and secret,
-- looking up the record, and verifying the bcrypt hash.
-- Returns the user_id if valid, NULL if invalid.
-- Updates last_used_at on successful validation.
-- NOT accessible via PostgREST (no GRANT to semantius_user).

CREATE OR REPLACE FUNCTION public.validate_api_key(p_api_key TEXT)
RETURNS INTEGER AS $$
DECLARE
    v_key_id TEXT;
    v_secret TEXT;
    v_last_dash INTEGER;
    v_record RECORD;
BEGIN
    -- Validate input
    IF p_api_key IS NULL OR p_api_key = '' THEN
        RETURN NULL;
    END IF;

    -- Split the key: everything up to the last '-' is key_id, the rest is secret
    -- Key format: prefix + public_id + '-' + secret
    -- e.g. "uk-abcdef012345-0123456789abcdef0123456789abcdef"
    v_last_dash := length(p_api_key) - position('-' IN reverse(p_api_key)) + 1;

    IF position('-' IN reverse(p_api_key)) = 0 OR v_last_dash >= length(p_api_key) THEN
        RETURN NULL;
    END IF;

    v_key_id := substring(p_api_key FROM 1 FOR v_last_dash - 1);
    v_secret := substring(p_api_key FROM v_last_dash + 1);

    IF v_key_id = '' OR v_secret = '' THEN
        RETURN NULL;
    END IF;

    -- Look up the record by key_id
    SELECT * INTO v_record
    FROM _apikeys
    WHERE key_id = v_key_id;

    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    -- Verify the secret against the stored bcrypt hash
    IF v_record.secret_hash = crypt(v_secret, v_record.secret_hash) THEN
        -- Update last_used_at on successful validation
        UPDATE _apikeys SET last_used_at = CURRENT_TIMESTAMP WHERE key_id = v_key_id;
        RETURN v_record.user_id;
    ELSE
        RETURN NULL;
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION public.validate_api_key IS
'Validates an API key and returns the user_id if valid, NULL otherwise. Updates last_used_at on successful validation. Called by semantius_user for API key authentication.';

-- Grant to semantius_user so it can be used for API key auth flows
GRANT EXECUTE ON FUNCTION public.validate_api_key(TEXT) TO semantius_user;

-- =====================================================
-- LIST API KEYS FUNCTION
-- =====================================================
-- Returns a JSON array of API keys for the current user or a specific user.
-- Each entry contains key_id, description, last_used_at, and created_at.
-- The secret hash is never returned.
-- When p_user_id = 0, returns keys for the current session user.
-- When p_user_id <> 0, requires admin permission.
-- Accessible via PostgREST RPC by all authenticated users.

CREATE OR REPLACE FUNCTION public.list_api_keys(p_user_id INTEGER DEFAULT 0)
RETURNS JSONB AS $$
DECLARE
    v_target_user_id INTEGER;
BEGIN
    -- Authenticate the caller
    PERFORM rbac.uid();

    IF p_user_id = 0 THEN
        v_target_user_id := rbac.user_id();
    ELSE
        -- Require admin permission to list keys for another user
        PERFORM rbac.require_permission('admin');

        -- Validate the target user exists
        IF NOT EXISTS (SELECT 1 FROM users WHERE id = p_user_id) THEN
            RAISE EXCEPTION 'User with id % does not exist', p_user_id
                USING ERRCODE = 'invalid_parameter_value';
        END IF;

        v_target_user_id := p_user_id;
    END IF;

    RETURN COALESCE(
        (SELECT jsonb_agg(
            jsonb_build_object(
                'key_id', key_id,
                'description', description,
                'last_used_at', last_used_at,
                'created_at', created_at
            ) ORDER BY created_at DESC
        )
        FROM _apikeys
        WHERE user_id = v_target_user_id),
        '[]'::jsonb
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION public.list_api_keys IS
'Returns a JSON array of API keys for the current user (p_user_id=0) or a specific user (admin only). Does not include the secret hash.';

-- Grant execute to semantius_user (accessible via PostgREST RPC)
REVOKE EXECUTE ON FUNCTION public.list_api_keys(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_api_keys(INTEGER) TO semantius_user;

-- =====================================================
-- DELETE API KEY FUNCTION
-- =====================================================
-- Deletes an API key by its public key_id.
-- Users may delete their own keys.
-- Admins may delete keys belonging to any user.
-- Returns TRUE if the key was deleted, raises an exception if not found
-- or if the caller does not have permission.
-- Accessible via PostgREST RPC by all authenticated users.

CREATE OR REPLACE FUNCTION public.delete_api_key(p_key_id TEXT)
RETURNS BOOLEAN AS $$
DECLARE
    v_current_user_id INTEGER;
    v_record RECORD;
BEGIN
    -- Authenticate the caller
    PERFORM rbac.uid();
    v_current_user_id := rbac.user_id();

    -- Look up the key
    SELECT * INTO v_record
    FROM _apikeys
    WHERE key_id = p_key_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'API key not found'
            USING ERRCODE = 'no_data_found';
    END IF;

    -- If the key belongs to another user, require admin permission
    IF v_record.user_id <> v_current_user_id THEN
        PERFORM rbac.require_permission('admin');
    END IF;

    DELETE FROM _apikeys WHERE key_id = p_key_id;

    RETURN TRUE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION public.delete_api_key IS
'Deletes an API key by its public key_id. Users may delete their own keys; admins may delete keys for any user.';

-- Grant execute to semantius_user (accessible via PostgREST RPC)
REVOKE EXECUTE ON FUNCTION public.delete_api_key(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_api_key(TEXT) TO semantius_user;
`,
    "0130_create_tables_view_compat": `-- =====================================================
-- BACKWARD COMPATIBILITY VIEW
-- =====================================================
-- Create an updatable view named "tables" that maps to "entities" table
-- This ensures external applications using the old "tables" name continue to work
-- Goal: semantius-core uses "entities", but old apps can still use "tables" view
-- =====================================================

-- Create a simple view that maps to entities table
-- PostgreSQL automatically makes this view updatable because:
-- 1. It selects from a single table (entities)
-- 2. It uses only simple column references (no expressions, aggregates, etc.)
-- 3. It doesn't use GROUP BY, HAVING, LIMIT, OFFSET, DISTINCT, UNION, etc.
-- This means INSERT, UPDATE, and DELETE operations work transparently without INSTEAD OF triggers
CREATE OR REPLACE VIEW tables AS
SELECT * FROM entities;

COMMENT ON VIEW tables IS 
'Backward compatibility view for entities table. PostgreSQL automatically makes this view updatable, allowing INSERT/UPDATE/DELETE operations to work transparently. External apps can continue using "tables" name while semantius-core uses "entities".';
-- =====================================================
-- SECURITY: Enable RLS and Grant Permissions
-- =====================================================
-- Views don't automatically inherit RLS from underlying tables
-- We must explicitly enable RLS and grant permissions

-- Enable Row Level Security on the view
ALTER VIEW tables SET (security_invoker = true);

-- Grant permissions to semantius_user role
GRANT SELECT, INSERT, UPDATE, DELETE ON tables TO semantius_user;

-- Note: The view will use the RLS policies from the underlying entities table
-- because we set security_invoker = true, which makes the view execute with
-- the permissions of the invoking user rather than the view owner`,
    "0140_dd_rename": `-- =====================================================
-- DDL RENAME SUPPORT
-- =====================================================
-- Adds support for renaming:
--   1. entities.table_name  → ALTER TABLE ... RENAME TO ...
--   2. fields.field_name    → ALTER TABLE ... RENAME COLUMN ... TO ...
-- Adds validation:
--   3. fields.format change → reject when underlying data type would change

-- =====================================================
-- STEP 1: Add ON UPDATE CASCADE to fields → entities FK
-- =====================================================
-- Required so that renaming entities.table_name automatically cascades
-- the metadata update to all related fields rows.

ALTER TABLE fields DROP CONSTRAINT IF EXISTS fields_table_name_fkey;

ALTER TABLE fields
    ADD CONSTRAINT fields_table_name_fkey
    FOREIGN KEY (table_name)
    REFERENCES entities(table_name)
    ON DELETE CASCADE
    ON UPDATE CASCADE;

-- =====================================================
-- STEP 2: TRIGGER FUNCTION: RENAME TABLE ON entities.table_name UPDATE
-- =====================================================
-- Fires BEFORE UPDATE on entities when table_name changes.
-- Renames the physical table and sets a transaction-local session variable
-- so the cascaded update to fields.table_name is allowed by update_dd_field.

CREATE OR REPLACE FUNCTION rename_dd_table()
RETURNS TRIGGER AS $$
DECLARE
    v_suffix    TEXT;
    v_old_name  TEXT;
    v_new_name  TEXT;
BEGIN
    IF OLD.table_name IS DISTINCT FROM NEW.table_name THEN
        -- Mark that a cascade rename is in progress (transaction-local)
        PERFORM set_config('dd.table_rename', OLD.table_name || ':' || NEW.table_name, TRUE);

        -- Rename the physical table and all associated named objects when managed
        IF OLD.managed THEN
            EXECUTE format('ALTER TABLE %I RENAME TO %I', OLD.table_name, NEW.table_name);
            RAISE NOTICE 'Renamed table "%" to "%"', OLD.table_name, NEW.table_name;

            -- Rename updated_at trigger (name pattern: update_<table>_updated_at)
            IF EXISTS (
                SELECT 1 FROM pg_trigger t
                JOIN pg_class c ON t.tgrelid = c.oid
                WHERE c.relname = NEW.table_name
                  AND c.relnamespace = 'public'::regnamespace
                  AND t.tgname = 'update_' || OLD.table_name || '_updated_at'
            ) THEN
                EXECUTE format(
                    'ALTER TRIGGER %I ON %I RENAME TO %I',
                    'update_' || OLD.table_name || '_updated_at',
                    NEW.table_name,
                    'update_' || NEW.table_name || '_updated_at'
                );
            END IF;

            -- Rename RLS policies (name patterns: <table>_select/insert/update/delete_policy)
            FOREACH v_suffix IN ARRAY ARRAY['select_policy', 'insert_policy', 'update_policy', 'delete_policy']
            LOOP
                IF EXISTS (
                    SELECT 1 FROM pg_policy p
                    JOIN pg_class c ON p.polrelid = c.oid
                    WHERE c.relname = NEW.table_name
                      AND c.relnamespace = 'public'::regnamespace
                      AND p.polname = OLD.table_name || '_' || v_suffix
                ) THEN
                    EXECUTE format(
                        'ALTER POLICY %I ON %I RENAME TO %I',
                        OLD.table_name || '_' || v_suffix,
                        NEW.table_name,
                        NEW.table_name || '_' || v_suffix
                    );
                END IF;
            END LOOP;

            -- Rename GIN search_vector index if it exists
            -- (name pattern: <table>_search_vector_idx)
            IF EXISTS (
                SELECT 1 FROM pg_indexes
                WHERE schemaname = 'public'
                  AND indexname = OLD.table_name || '_search_vector_idx'
            ) THEN
                EXECUTE format(
                    'ALTER INDEX %I RENAME TO %I',
                    OLD.table_name || '_search_vector_idx',
                    NEW.table_name || '_search_vector_idx'
                );
            END IF;

            -- Rename id sequence (<table>_<id_col>_seq)
            IF EXISTS (
                SELECT 1 FROM pg_class
                WHERE relname = OLD.table_name || '_' || OLD.id_column || '_seq'
                  AND relnamespace = 'public'::regnamespace
                  AND relkind = 'S'
            ) THEN
                EXECUTE format(
                    'ALTER SEQUENCE %I RENAME TO %I',
                    OLD.table_name || '_' || OLD.id_column || '_seq',
                    NEW.table_name || '_' || NEW.id_column || '_seq'
                );
            END IF;

            -- Rename primary key constraint (<table>_pkey)
            IF EXISTS (
                SELECT 1 FROM pg_constraint c
                JOIN pg_class t ON c.conrelid = t.oid
                WHERE c.conname = OLD.table_name || '_pkey'
                  AND t.relname = NEW.table_name
                  AND t.relnamespace = 'public'::regnamespace
                  AND c.contype = 'p'
            ) THEN
                EXECUTE format(
                    'ALTER TABLE %I RENAME CONSTRAINT %I TO %I',
                    NEW.table_name,
                    OLD.table_name || '_pkey',
                    NEW.table_name || '_pkey'
                );
            END IF;

            -- Rename all FK constraints named <old_table>_<field>_fkey
            FOR v_old_name IN
                SELECT c.conname
                FROM pg_constraint c
                JOIN pg_class t ON c.conrelid = t.oid
                WHERE t.relname = NEW.table_name
                  AND t.relnamespace = 'public'::regnamespace
                  AND c.conname LIKE (OLD.table_name || '\\_%\\_fkey') ESCAPE '\\'
                  AND c.contype = 'f'
            LOOP
                v_new_name := NEW.table_name || substring(v_old_name FROM length(OLD.table_name) + 1);
                EXECUTE format('ALTER TABLE %I RENAME CONSTRAINT %I TO %I',
                    NEW.table_name, v_old_name, v_new_name);
            END LOOP;

            -- Rename all FK indexes named idx_<old_table>_<field>
            FOR v_old_name IN
                SELECT indexname
                FROM pg_indexes
                WHERE schemaname = 'public'
                  AND tablename = NEW.table_name
                  AND indexname LIKE ('idx\\_' || OLD.table_name || '\\_%') ESCAPE '\\'
            LOOP
                v_new_name := 'idx_' || NEW.table_name || substring(v_old_name FROM length('idx_' || OLD.table_name) + 1);
                EXECUTE format('ALTER INDEX %I RENAME TO %I', v_old_name, v_new_name);
            END LOOP;

            -- Rename all check constraints named <old_table>_<field>_check
            FOR v_old_name IN
                SELECT c.conname
                FROM pg_constraint c
                JOIN pg_class t ON c.conrelid = t.oid
                WHERE t.relname = NEW.table_name
                  AND t.relnamespace = 'public'::regnamespace
                  AND c.conname LIKE (OLD.table_name || '\\_%\\_check') ESCAPE '\\'
                  AND c.contype = 'c'
            LOOP
                v_new_name := NEW.table_name || substring(v_old_name FROM length(OLD.table_name) + 1);
                EXECUTE format('ALTER TABLE %I RENAME CONSTRAINT %I TO %I',
                    NEW.table_name, v_old_name, v_new_name);
            END LOOP;

            -- Rename all unique indexes named <old_table>_<field>_unique
            FOR v_old_name IN
                SELECT indexname
                FROM pg_indexes
                WHERE schemaname = 'public'
                  AND tablename = NEW.table_name
                  AND indexname LIKE (OLD.table_name || '\\_%\\_unique') ESCAPE '\\'
            LOOP
                v_new_name := NEW.table_name || substring(v_old_name FROM length(OLD.table_name) + 1);
                EXECUTE format('ALTER INDEX %I RENAME TO %I', v_old_name, v_new_name);
            END LOOP;

        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION rename_dd_table IS
'BEFORE UPDATE trigger on entities: renames the physical table and ALL associated named
objects when table_name changes: updated_at trigger, RLS policies, GIN search_vector
index, id sequence, primary key constraint, FK constraints, FK indexes, check constraints,
and unique indexes.  Sets a transaction-local session variable so the cascaded update to
fields.table_name is allowed by update_dd_field without raising an exception.';

-- Apply trigger BEFORE UPDATE on entities (only when table_name changes)
CREATE TRIGGER rename_table_trigger
    BEFORE UPDATE ON entities
    FOR EACH ROW
    WHEN (OLD.table_name IS DISTINCT FROM NEW.table_name)
    EXECUTE FUNCTION rename_dd_table();

COMMENT ON TRIGGER rename_table_trigger ON entities IS
'Renames the physical database table when entities.table_name is updated';

-- =====================================================
-- STEP 2b: TRIGGER FUNCTION: CASCADE reference_table ON entities.table_name UPDATE
-- =====================================================
-- Fires AFTER UPDATE on entities when table_name changes.
-- Updates fields.reference_table in every field across ALL tables that currently
-- points at the old table name.  Must run AFTER (not BEFORE) the entities row is
-- committed so that validate_reference_table_trigger can find the new name.
-- The update cascades through update_dd_field() which drops and recreates the
-- physical FK constraint to reference the renamed table.

CREATE OR REPLACE FUNCTION rename_dd_reference_tables()
RETURNS TRIGGER AS $$
BEGIN
    -- Update every field in any table that references the old entity name.
    -- update_dd_field() (AFTER trigger on fields) will detect the reference_table
    -- change and rebuild the FK constraint to point at NEW.table_name.
    UPDATE fields
    SET reference_table = NEW.table_name
    WHERE reference_table = OLD.table_name;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION rename_dd_reference_tables IS
'AFTER UPDATE trigger on entities: when table_name changes, updates fields.reference_table
in all fields across all tables that referenced the old name.  Cascades through
update_dd_field() to rebuild the physical FK constraint on the referencing table.';

CREATE TRIGGER rename_reference_tables_trigger
    AFTER UPDATE ON entities
    FOR EACH ROW
    WHEN (OLD.table_name IS DISTINCT FROM NEW.table_name)
    EXECUTE FUNCTION rename_dd_reference_tables();

COMMENT ON TRIGGER rename_reference_tables_trigger ON entities IS
'Updates fields.reference_table and rebuilds FK constraints when entities.table_name is renamed';

-- =====================================================
-- STEP 3: TRIGGER FUNCTION: VALIDATE AND RENAME ON fields UPDATE
-- =====================================================
-- Fires BEFORE UPDATE on fields.
-- Handles two things:
--   A) field_name rename  → ALTER TABLE ... RENAME COLUMN ... TO ...
--      Also renames associated FK constraints, indexes, and check constraints.
--   B) format validation  → reject if the new format maps to a different data type.

CREATE OR REPLACE FUNCTION validate_field_rename_and_format()
RETURNS TRIGGER AS $$
DECLARE
    v_is_managed  BOOLEAN;
    v_old_type    TEXT;
    v_new_type    TEXT;
    v_old_fk      TEXT;
    v_new_fk      TEXT;
    v_old_idx     TEXT;
    v_new_idx     TEXT;
    v_old_check   TEXT;
    v_new_check   TEXT;
    v_old_unique  TEXT;
    v_new_unique  TEXT;
BEGIN
    -- Resolve parent entity's managed flag
    SELECT managed INTO v_is_managed FROM entities WHERE table_name = OLD.table_name;

    -- --------------------------------------------------
    -- A) Handle field_name rename
    -- --------------------------------------------------
    IF OLD.field_name IS DISTINCT FROM NEW.field_name THEN
        -- Core fields cannot be renamed
        IF OLD.is_core THEN
            RAISE EXCEPTION 'Cannot rename core system field "%"', OLD.field_name;
        END IF;

        IF v_is_managed THEN
            -- Rename the physical column
            EXECUTE format(
                'ALTER TABLE %I RENAME COLUMN %I TO %I',
                OLD.table_name, OLD.field_name, NEW.field_name
            );
            RAISE NOTICE 'Renamed column "%" to "%" in table "%"',
                OLD.field_name, NEW.field_name, OLD.table_name;

            -- Build old and new names for associated constraints / indexes
            v_old_fk     := format('%s_%s_fkey',   OLD.table_name, OLD.field_name);
            v_new_fk     := format('%s_%s_fkey',   OLD.table_name, NEW.field_name);
            v_old_idx    := format('idx_%s_%s',    OLD.table_name, OLD.field_name);
            v_new_idx    := format('idx_%s_%s',    OLD.table_name, NEW.field_name);
            v_old_check  := format('%s_%s_check',  OLD.table_name, OLD.field_name);
            v_new_check  := format('%s_%s_check',  OLD.table_name, NEW.field_name);
            v_old_unique := format('%s_%s_unique', OLD.table_name, OLD.field_name);
            v_new_unique := format('%s_%s_unique', OLD.table_name, NEW.field_name);

            -- Rename FK constraint if it exists
            IF EXISTS (
                SELECT 1 FROM pg_constraint c
                JOIN pg_class t ON c.conrelid = t.oid
                WHERE c.conname = v_old_fk
                  AND t.relname = OLD.table_name
                  AND t.relnamespace = 'public'::regnamespace
            ) THEN
                EXECUTE format('ALTER TABLE %I RENAME CONSTRAINT %I TO %I',
                    OLD.table_name, v_old_fk, v_new_fk);
                RAISE NOTICE 'Renamed FK constraint "%" to "%"', v_old_fk, v_new_fk;
            END IF;

            -- Rename FK index if it exists
            IF EXISTS (
                SELECT 1 FROM pg_indexes
                WHERE schemaname = 'public' AND indexname = v_old_idx
            ) THEN
                EXECUTE format('ALTER INDEX %I RENAME TO %I', v_old_idx, v_new_idx);
                RAISE NOTICE 'Renamed index "%" to "%"', v_old_idx, v_new_idx;
            END IF;

            -- Rename check constraint if it exists
            IF EXISTS (
                SELECT 1 FROM pg_constraint c
                JOIN pg_class t ON c.conrelid = t.oid
                WHERE c.conname = v_old_check
                  AND t.relname = OLD.table_name
                  AND t.relnamespace = 'public'::regnamespace
            ) THEN
                EXECUTE format('ALTER TABLE %I RENAME CONSTRAINT %I TO %I',
                    OLD.table_name, v_old_check, v_new_check);
                RAISE NOTICE 'Renamed check constraint "%" to "%"', v_old_check, v_new_check;
            END IF;

            -- Rename unique index if it exists
            IF EXISTS (
                SELECT 1 FROM pg_indexes
                WHERE schemaname = 'public' AND indexname = v_old_unique
            ) THEN
                EXECUTE format('ALTER INDEX %I RENAME TO %I', v_old_unique, v_new_unique);
                RAISE NOTICE 'Renamed unique index "%" to "%"', v_old_unique, v_new_unique;
            END IF;
        END IF;
    END IF;

    -- --------------------------------------------------
    -- B) Validate format change (only for managed tables)
    -- --------------------------------------------------
    -- For managed tables, the format maps to a physical column type.
    -- Changing format is valid only when the new format maps to the same
    -- underlying PostgreSQL data type (e.g. email → hostname is fine because
    -- both are TEXT, but email → json is not because TEXT ≠ JSONB).
    -- Unmanaged tables have no physical columns, so any format change is allowed.
    IF OLD.format IS DISTINCT FROM NEW.format AND v_is_managed THEN
        -- Core field formats cannot be changed (existing rule, enforced here too)
        IF OLD.is_core THEN
            RAISE EXCEPTION 'Cannot change format of core system field "%"', OLD.field_name;
        END IF;

        v_old_type := format_to_data_type(OLD.format);
        v_new_type := format_to_data_type(NEW.format);

        IF v_old_type <> v_new_type THEN
            RAISE EXCEPTION
                'Cannot change format of field "%" from "%" to "%" because it would require '
                'changing the column type from % to %. Drop and recreate the field instead.',
                OLD.field_name, OLD.format, NEW.format, v_old_type, v_new_type;
        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION validate_field_rename_and_format IS
'BEFORE UPDATE trigger on fields.
Renames the physical column (and associated constraints/indexes) when field_name changes.
Rejects format changes that would alter the underlying PostgreSQL data type.';

-- Apply trigger BEFORE UPDATE on fields
CREATE TRIGGER validate_field_rename_and_format_trigger
    BEFORE UPDATE ON fields
    FOR EACH ROW
    EXECUTE FUNCTION validate_field_rename_and_format();

COMMENT ON TRIGGER validate_field_rename_and_format_trigger ON fields IS
'Renames column and validates format compatibility on field updates';

-- =====================================================
-- STEP 4: Update update_dd_field() to handle the new semantics
-- =====================================================
-- Changes:
--   • table_name change: allow when the session variable set by rename_dd_table
--     confirms this is a cascade from an entity rename; reject otherwise.
--   • field_name change: no longer raise an exception — the BEFORE trigger
--     already renamed the physical column.  The AFTER trigger must use
--     NEW.field_name (already the renamed column name) for all subsequent DDL.
--   • format change: skip ALTER COLUMN TYPE when the data type is unchanged
--     (same-type format changes like email→hostname).  Incompatible type
--     changes are blocked by the BEFORE trigger before this code is reached.

CREATE OR REPLACE FUNCTION update_dd_field()
RETURNS TRIGGER AS $$
DECLARE
    v_alter_sql TEXT;
    v_old_data_type TEXT;
    v_new_data_type TEXT;
    v_is_managed BOOLEAN;
    v_ref_id_column TEXT;
    v_fk_name TEXT;
    v_idx_name TEXT;
    v_on_delete TEXT;
BEGIN
    -- Check if the parent table is managed
    SELECT managed INTO v_is_managed FROM entities WHERE table_name = NEW.table_name;

    -- Prevent changing critical attributes
    IF OLD.table_name <> NEW.table_name THEN
        -- Allow only when this is a cascade triggered by rename_dd_table()
        IF current_setting('dd.table_rename', TRUE) <> OLD.table_name || ':' || NEW.table_name THEN
            RAISE EXCEPTION 'Cannot change table_name of a field';
        END IF;
        -- Cascade rename: metadata has been updated; no DDL needed here
        RETURN NEW;
    END IF;

    -- field_name was renamed by validate_field_rename_and_format() BEFORE trigger;
    -- no exception here — just continue with the rest of the DDL using NEW.field_name.

    IF OLD.is_pk <> NEW.is_pk THEN
        RAISE EXCEPTION 'Cannot change primary key status of existing field';
    END IF;

    -- Prevent changing structural attributes of core fields
    -- Core fields can only have metadata updates (title, description, field_order, input_type, width)
    IF OLD.is_core THEN
        IF OLD.format <> NEW.format THEN
            RAISE EXCEPTION 'Cannot change format of core system field "%"', OLD.field_name;
        END IF;

        IF OLD.default_value IS DISTINCT FROM NEW.default_value THEN
            RAISE EXCEPTION 'Cannot change default value of core system field "%"', OLD.field_name;
        END IF;

        IF OLD.is_core <> NEW.is_core THEN
            RAISE EXCEPTION 'Cannot change is_core status of field "%"', OLD.field_name;
        END IF;
    END IF;

    -- Skip DDL operations if table is not managed (but allow metadata updates like description)
    IF NOT v_is_managed THEN
        -- Still allow updating column comments even if not managed
        IF OLD.description IS DISTINCT FROM NEW.description THEN
            IF NEW.description IS NOT NULL AND trim(NEW.description) != '' THEN
                EXECUTE format(
                    'COMMENT ON COLUMN %I.%I IS %L',
                    NEW.table_name,
                    NEW.field_name,
                    NEW.description
                );
            ELSE
                EXECUTE format(
                    'COMMENT ON COLUMN %I.%I IS NULL',
                    NEW.table_name,
                    NEW.field_name
                );
            END IF;
        END IF;

        RAISE NOTICE 'Skipping DDL operations for "%.%" (table managed=false)', NEW.table_name, NEW.field_name;
        RETURN NEW;
    END IF;

    -- Update column comment if description changed
    IF OLD.description IS DISTINCT FROM NEW.description THEN
        IF NEW.description IS NOT NULL AND trim(NEW.description) != '' THEN
            EXECUTE format(
                'COMMENT ON COLUMN %I.%I IS %L',
                NEW.table_name,
                NEW.field_name,
                NEW.description
            );
        ELSE
            EXECUTE format(
                'COMMENT ON COLUMN %I.%I IS NULL',
                NEW.table_name,
                NEW.field_name
            );
        END IF;
    END IF;

    -- Handle format change
    -- The BEFORE trigger already rejected incompatible type changes, so at this
    -- point OLD and NEW formats always map to the same data type.
    -- Only execute ALTER COLUMN TYPE when the mapped type actually differs
    -- (this guards against edge cases and keeps DDL minimal).
    IF OLD.format <> NEW.format THEN
        v_old_data_type := format_to_data_type(OLD.format);
        v_new_data_type := format_to_data_type(NEW.format);

        IF v_old_data_type <> v_new_data_type THEN
            -- Defensive check: BEFORE trigger should have prevented this
            RAISE EXCEPTION
                'Cannot change format of field "%" from "%" to "%" because it would require '
                'changing the column type from % to %.',
                NEW.field_name, OLD.format, NEW.format, v_old_data_type, v_new_data_type;
        END IF;

        -- Same underlying type — no ALTER needed; log the format change only
        RAISE NOTICE 'Changed format of column "%" from "%" to "%" in table "%" (data type unchanged: %)',
            NEW.field_name, OLD.format, NEW.format, NEW.table_name, v_new_data_type;
    END IF;

    -- Allow updating nullable constraint (derived from format)
    IF OLD.is_nullable <> NEW.is_nullable THEN
        IF NEW.is_nullable THEN
            v_alter_sql := format(
                'ALTER TABLE %I ALTER COLUMN %I DROP NOT NULL',
                NEW.table_name,
                NEW.field_name
            );
        ELSE
            v_alter_sql := format(
                'ALTER TABLE %I ALTER COLUMN %I SET NOT NULL',
                NEW.table_name,
                NEW.field_name
            );
        END IF;
        EXECUTE v_alter_sql;
        RAISE NOTICE 'Changed column "%" nullable to % in table "%"',
            NEW.field_name, NEW.is_nullable, NEW.table_name;
    END IF;

    -- Allow updating default value
    IF OLD.default_value IS DISTINCT FROM NEW.default_value THEN
        IF NEW.default_value IS NULL THEN
            v_alter_sql := format(
                'ALTER TABLE %I ALTER COLUMN %I DROP DEFAULT',
                NEW.table_name,
                NEW.field_name
            );
        ELSE
            v_alter_sql := format(
                'ALTER TABLE %I ALTER COLUMN %I SET DEFAULT %s',
                NEW.table_name,
                NEW.field_name,
                quote_default_value(NEW.default_value, format_to_data_type(NEW.format))
            );
        END IF;
        EXECUTE v_alter_sql;
        RAISE NOTICE 'Changed column "%" default value in table "%"',
            NEW.field_name, NEW.table_name;
    END IF;

    -- Handle foreign key reference changes
    IF OLD.format IN ('reference', 'parent') OR NEW.format IN ('reference', 'parent') THEN
        v_fk_name := format('%s_%s_fkey', NEW.table_name, NEW.field_name);
        v_idx_name := format('idx_%s_%s', NEW.table_name, NEW.field_name);

        -- Check if reference_table or reference_delete_mode changed
        IF (OLD.reference_table IS DISTINCT FROM NEW.reference_table) OR
           (OLD.reference_delete_mode IS DISTINCT FROM NEW.reference_delete_mode) OR
           (OLD.format <> NEW.format) THEN

            -- Drop existing foreign key constraint if it exists
            IF OLD.format IN ('reference', 'parent') THEN
                EXECUTE format(
                    'ALTER TABLE %I DROP CONSTRAINT IF EXISTS %I',
                    NEW.table_name,
                    v_fk_name
                );
                RAISE NOTICE 'Dropped foreign key constraint "%"', v_fk_name;
            END IF;

            -- Add new foreign key constraint if format is now 'reference' or 'parent'
            IF NEW.format IN ('reference', 'parent') AND NEW.reference_table IS NOT NULL AND NEW.reference_table != '' THEN
                -- Get the id_column of the referenced table
                SELECT id_column INTO v_ref_id_column
                FROM entities
                WHERE table_name = NEW.reference_table;

                IF v_ref_id_column IS NULL THEN
                    RAISE EXCEPTION 'Referenced table "%" not found', NEW.reference_table;
                END IF;

                -- Determine ON DELETE behavior
                IF NEW.reference_delete_mode = 'clear' THEN
                    v_on_delete := 'SET NULL';
                ELSE
                    v_on_delete := 'RESTRICT';
                END IF;

                -- Add foreign key constraint
                v_alter_sql := format(
                    'ALTER TABLE %I ADD CONSTRAINT %I FOREIGN KEY (%I) REFERENCES %I(%I) ON DELETE %s',
                    NEW.table_name,
                    v_fk_name,
                    NEW.field_name,
                    NEW.reference_table,
                    v_ref_id_column,
                    v_on_delete
                );
                EXECUTE v_alter_sql;

                -- Create index for foreign key if it doesn't exist
                v_alter_sql := format(
                    'CREATE INDEX IF NOT EXISTS %I ON %I(%I)',
                    v_idx_name,
                    NEW.table_name,
                    NEW.field_name
                );
                EXECUTE v_alter_sql;

                RAISE NOTICE 'Updated foreign key "%" from %.% to %.% with ON DELETE %',
                    v_fk_name, NEW.table_name, NEW.field_name, NEW.reference_table, v_ref_id_column, v_on_delete;
            ELSIF NEW.format NOT IN ('reference', 'parent') AND OLD.format IN ('reference', 'parent') THEN
                -- Drop index if format changed from reference/parent to something else
                EXECUTE format(
                    'DROP INDEX IF EXISTS %I',
                    v_idx_name
                );
                RAISE NOTICE 'Dropped index "%" for field "%.%"', v_idx_name, NEW.table_name, NEW.field_name;
            END IF;
        END IF;
    END IF;

    -- Handle enum CHECK constraint changes
    IF OLD.format = 'enum' OR NEW.format = 'enum' THEN
        DECLARE
            v_check_name TEXT;
            v_enum_values_sql TEXT;
        BEGIN
            v_check_name := format('%s_%s_check', NEW.table_name, NEW.field_name);

            -- Check if enum_values changed or format changed
            IF (OLD.enum_values IS DISTINCT FROM NEW.enum_values) OR (OLD.format <> NEW.format) THEN

                -- Drop existing CHECK constraint if it exists
                IF OLD.format = 'enum' THEN
                    EXECUTE format(
                        'ALTER TABLE %I DROP CONSTRAINT IF EXISTS %I',
                        NEW.table_name,
                        v_check_name
                    );
                    RAISE NOTICE 'Dropped CHECK constraint "%"', v_check_name;
                END IF;

                -- Add new CHECK constraint if format is now 'enum'
                IF NEW.format = 'enum' AND NEW.enum_values IS NOT NULL AND jsonb_array_length(NEW.enum_values) > 0 THEN
                    -- Build SQL array from JSONB array for IN clause
                    v_enum_values_sql := (
                        SELECT string_agg(quote_literal(value::text), ', ')
                        FROM jsonb_array_elements_text(NEW.enum_values) AS value
                    );

                    -- Add CHECK constraint
                    v_alter_sql := format(
                        'ALTER TABLE %I ADD CONSTRAINT %I CHECK (%I IN (%s))',
                        NEW.table_name,
                        v_check_name,
                        NEW.field_name,
                        v_enum_values_sql
                    );
                    EXECUTE v_alter_sql;

                    RAISE NOTICE 'Updated CHECK constraint "%" for enum field "%.%"',
                        v_check_name, NEW.table_name, NEW.field_name;
                END IF;
            END IF;
        END;
    END IF;

    -- Handle unique_value changes
    IF OLD.unique_value IS DISTINCT FROM NEW.unique_value THEN
        DECLARE
            v_unique_idx_name TEXT;
            v_where_clause TEXT;
        BEGIN
            v_unique_idx_name := format('%s_%s_unique', NEW.table_name, NEW.field_name);
            IF NEW.unique_value THEN
                -- Create partial unique index
                IF format_to_json_type(NEW.format)::text = '"string"' THEN
                    v_where_clause := format('%I IS NOT NULL AND %I != ''''', NEW.field_name, NEW.field_name);
                ELSE
                    v_where_clause := format('%I IS NOT NULL', NEW.field_name);
                END IF;
                EXECUTE format(
                    'CREATE UNIQUE INDEX IF NOT EXISTS %I ON %I(%I) WHERE %s',
                    v_unique_idx_name,
                    NEW.table_name,
                    NEW.field_name,
                    v_where_clause
                );
                RAISE NOTICE 'Created unique index "%" for field "%.%"', v_unique_idx_name, NEW.table_name, NEW.field_name;
            ELSE
                -- Drop unique index
                EXECUTE format('DROP INDEX IF EXISTS %I', v_unique_idx_name);
                RAISE NOTICE 'Dropped unique index "%" for field "%.%"', v_unique_idx_name, NEW.table_name, NEW.field_name;
            END IF;
        END;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION update_dd_field IS
'Trigger function that updates column properties when a field is updated.
table_name changes are allowed only as part of a cascade from rename_dd_table().
field_name renames are handled by the validate_field_rename_and_format BEFORE trigger.
format changes that alter the underlying data type are rejected by the BEFORE trigger.';

-- Revoke default PUBLIC execute on the new functions
REVOKE EXECUTE ON FUNCTION rename_dd_table() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rename_dd_reference_tables() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION validate_field_rename_and_format() FROM PUBLIC;
`,
    "0145_managed_enable": `-- =====================================================
-- MANAGED ENABLE SUPPORT
-- =====================================================
-- Adds support for:
--   1. Toggling entities.managed from FALSE to TRUE:
--      Creates the physical table (if missing) with full DDL setup
--      (RLS policies, updated_at trigger), then adds any missing
--      columns for existing field records.
--   2. Updating a field in a managed table when the column does not
--      yet exist in the database: column is created on-the-fly.

-- =====================================================
-- HELPER FUNCTION: apply_field_ddl
-- =====================================================
-- Applies all DDL for a single field record to the physical table.
-- Uses IF NOT EXISTS / exception guards so it is safe to call on
-- columns that already exist (idempotent).
-- Called by:
--   • enable_dd_table() trigger  – for each existing field when
--     managed is first enabled
--   • update_dd_field() trigger  – when the column is found to be
--     missing from an otherwise-managed table

CREATE OR REPLACE FUNCTION apply_field_ddl(p_field fields)
RETURNS VOID AS $$
DECLARE
    v_alter_sql      TEXT;
    v_nullable_clause TEXT;
    v_default_clause  TEXT;
    v_data_type       TEXT;
    v_ref_id_column   TEXT;
    v_fk_name         TEXT;
    v_idx_name        TEXT;
    v_on_delete       TEXT;
BEGIN
    SET LOCAL client_min_messages = WARNING;

    -- Convert format to PostgreSQL data type
    v_data_type := format_to_data_type(p_field.format, p_field."precision");

    -- Build nullable clause
    IF p_field.is_nullable THEN
        v_nullable_clause := 'NULL';
    ELSE
        v_nullable_clause := 'NOT NULL';
    END IF;

    -- Build default clause with sensible fallbacks for NOT NULL columns
    DECLARE
        v_resolved_default TEXT;
    BEGIN
        IF p_field.format = 'enum' THEN
            v_resolved_default := effective_enum_default(p_field.default_value, p_field.input_type, p_field.enum_values);
        ELSE
            v_resolved_default := p_field.default_value;
        END IF;

        IF v_resolved_default IS NOT NULL AND trim(v_resolved_default) != '' THEN
            v_default_clause := format('DEFAULT %s', quote_default_value(v_resolved_default, v_data_type));
        ELSIF NOT p_field.is_nullable THEN
            IF v_data_type IN ('JSONB', 'JSON') THEN
                v_default_clause := 'DEFAULT ''{}''::jsonb';
            ELSE
                CASE
                    WHEN v_data_type = 'TEXT'                                THEN v_default_clause := 'DEFAULT ''''';
                    WHEN v_data_type IN ('INTEGER', 'BIGINT', 'SMALLINT')    THEN v_default_clause := 'DEFAULT 0';
                    WHEN v_data_type IN ('REAL', 'DOUBLE PRECISION')
                         OR v_data_type LIKE 'NUMERIC%'
                         OR v_data_type LIKE 'DECIMAL%'                       THEN v_default_clause := 'DEFAULT 0.0';
                    WHEN v_data_type = 'BOOLEAN'                              THEN v_default_clause := 'DEFAULT FALSE';
                    WHEN v_data_type IN ('TIMESTAMP', 'TIMESTAMPTZ')          THEN v_default_clause := 'DEFAULT CURRENT_TIMESTAMP';
                    WHEN v_data_type = 'DATE'                                 THEN v_default_clause := 'DEFAULT CURRENT_DATE';
                    ELSE v_default_clause := '';
                END CASE;
            END IF;
        ELSE
            v_default_clause := '';
        END IF;
    END;

    -- Add column (IF NOT EXISTS makes this idempotent)
    v_alter_sql := format(
        'ALTER TABLE %I ADD COLUMN IF NOT EXISTS %I %s %s %s',
        p_field.table_name, p_field.field_name,
        v_data_type, v_nullable_clause, v_default_clause
    );
    EXECUTE v_alter_sql;

    -- Add / refresh column comment
    IF p_field.description IS NOT NULL AND trim(p_field.description) != '' THEN
        EXECUTE format('COMMENT ON COLUMN %I.%I IS %L',
            p_field.table_name, p_field.field_name, p_field.description);
    END IF;

    -- Foreign key (reference / parent format)
    IF p_field.format IN ('reference', 'parent')
       AND p_field.reference_table IS NOT NULL
       AND p_field.reference_table != ''
    THEN
        SELECT id_column INTO v_ref_id_column
        FROM entities WHERE table_name = p_field.reference_table;

        IF v_ref_id_column IS NOT NULL THEN
            IF p_field.reference_delete_mode = 'clear' THEN
                v_on_delete := 'SET NULL';
            ELSIF p_field.reference_delete_mode = 'cascade' THEN
                v_on_delete := 'CASCADE';
            ELSE
                v_on_delete := 'RESTRICT';
            END IF;

            v_fk_name  := format('%s_%s_fkey', p_field.table_name, p_field.field_name);
            v_idx_name := format('idx_%s_%s',  p_field.table_name, p_field.field_name);

            BEGIN
                EXECUTE format(
                    'ALTER TABLE %I ADD CONSTRAINT %I FOREIGN KEY (%I) REFERENCES %I(%I) ON DELETE %s',
                    p_field.table_name, v_fk_name, p_field.field_name,
                    p_field.reference_table, v_ref_id_column, v_on_delete
                );
            EXCEPTION WHEN duplicate_object THEN
                RAISE NOTICE 'FK "%" already exists on "%.%", skipping',
                    v_fk_name, p_field.table_name, p_field.field_name;
            END;

            EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON %I(%I)',
                v_idx_name, p_field.table_name, p_field.field_name);
        END IF;
    END IF;

    -- Enum CHECK constraint
    IF p_field.format = 'enum'
       AND p_field.enum_values IS NOT NULL
       AND jsonb_array_length(p_field.enum_values) > 0
    THEN
        DECLARE
            v_check_name      TEXT;
            v_enum_values_sql TEXT;
            v_effective_enum  JSONB;
        BEGIN
            v_check_name := format('%s_%s_check', p_field.table_name, p_field.field_name);
            v_effective_enum := effective_enum_values(p_field.input_type, p_field.enum_values);
            v_enum_values_sql := (
                SELECT string_agg(quote_literal(value::text), ', ')
                FROM jsonb_array_elements_text(v_effective_enum) AS value
            );
            BEGIN
                EXECUTE format(
                    'ALTER TABLE %I ADD CONSTRAINT %I CHECK (%I IN (%s))',
                    p_field.table_name, v_check_name, p_field.field_name, v_enum_values_sql
                );
            EXCEPTION WHEN duplicate_object THEN
                RAISE NOTICE 'CHECK constraint "%" already exists, skipping', v_check_name;
            END;
        END;
    END IF;

    -- Partial unique index
    IF p_field.unique_value THEN
        DECLARE
            v_unique_idx_name TEXT;
            v_where_clause    TEXT;
        BEGIN
            v_unique_idx_name := format('%s_%s_unique', p_field.table_name, p_field.field_name);
            IF format_to_json_type(p_field.format)::text = '"string"' THEN
                v_where_clause := format('%I IS NOT NULL AND %I != ''''',
                    p_field.field_name, p_field.field_name);
            ELSE
                v_where_clause := format('%I IS NOT NULL', p_field.field_name);
            END IF;
            EXECUTE format(
                'CREATE UNIQUE INDEX IF NOT EXISTS %I ON %I(%I) WHERE %s',
                v_unique_idx_name, p_field.table_name, p_field.field_name, v_where_clause
            );
        END;
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION apply_field_ddl(fields) IS
'Idempotent helper: applies ADD COLUMN + FK + CHECK + unique-index DDL for a
single field record.  Called by enable_dd_table() and update_dd_field() to
create columns that were defined while managed=false.';

-- =====================================================
-- TRIGGER FUNCTION: ENABLE TABLE WHEN managed F→T
-- =====================================================

CREATE OR REPLACE FUNCTION enable_dd_table()
RETURNS TRIGGER AS $$
DECLARE
    v_create_sql TEXT;
    v_field      fields%ROWTYPE;
BEGIN
    -- Guard: only proceed when managed transitions FALSE → TRUE
    IF NOT (OLD.managed = FALSE AND NEW.managed = TRUE) THEN
        RETURN NEW;
    END IF;

    SET LOCAL client_min_messages = WARNING;

    -- ── Create the physical table if it does not yet exist ──────────────
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'public' AND table_name = NEW.table_name
    ) THEN
        v_create_sql := format(
            'CREATE TABLE IF NOT EXISTS public.%I (
                %I SERIAL PRIMARY KEY,
                %I TEXT NOT NULL DEFAULT '''',
                created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
                updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
            )',
            NEW.table_name, NEW.id_column, NEW.label_column
        );
        EXECUTE v_create_sql;

        -- Table comment
        IF NEW.description IS NOT NULL AND trim(NEW.description) != '' THEN
            EXECUTE format('COMMENT ON TABLE %I IS %L', NEW.table_name, NEW.description);
        END IF;

        -- updated_at maintenance trigger
        EXECUTE format(
            'CREATE TRIGGER update_%I_updated_at
                BEFORE UPDATE ON %I
                FOR EACH ROW
                EXECUTE FUNCTION common.update_updated_at_column()',
            NEW.table_name, NEW.table_name
        );

        -- Row Level Security
        EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', NEW.table_name);

        EXECUTE format(
            'CREATE POLICY %I_select_policy ON %I
                FOR SELECT TO semantius_user
                USING (rbac.has_permission(%L))',
            NEW.table_name, NEW.table_name, NEW.view_permission
        );
        EXECUTE format(
            'CREATE POLICY %I_insert_policy ON %I
                FOR INSERT TO semantius_user
                WITH CHECK (rbac.has_permission(%L))',
            NEW.table_name, NEW.table_name, NEW.edit_permission
        );
        EXECUTE format(
            'CREATE POLICY %I_update_policy ON %I
                FOR UPDATE TO semantius_user
                USING (rbac.has_permission(%L))
                WITH CHECK (rbac.has_permission(%L))',
            NEW.table_name, NEW.table_name, NEW.edit_permission, NEW.edit_permission
        );
        EXECUTE format(
            'CREATE POLICY %I_delete_policy ON %I
                FOR DELETE TO semantius_user
                USING (rbac.has_permission(%L))',
            NEW.table_name, NEW.table_name, NEW.edit_permission
        );

        RAISE NOTICE 'Created table "%" (managed changed to true)', NEW.table_name;
    END IF;

    -- ── Insert core field records if they were never created ─────────────
    -- create_dd_table inserts these when managed=true on INSERT, but when
    -- an entity was created with managed=false those records do not exist.
    INSERT INTO fields (table_name, field_name, title, format, is_pk, field_order, input_type, width, ctype, is_core, searchable, reference_table, reference_delete_mode)
    SELECT NEW.table_name, NEW.id_column, 'Id', 'int32', TRUE, 1, 'readonly', 'default', 'id', TRUE, FALSE, '', ''
    WHERE NOT EXISTS (SELECT 1 FROM fields WHERE table_name = NEW.table_name AND field_name = NEW.id_column);

    INSERT INTO fields (table_name, field_name, title, format, is_pk, field_order, input_type, width, ctype, is_core, searchable, reference_table, reference_delete_mode)
    SELECT NEW.table_name, NEW.label_column, NEW.singular_label, 'text', FALSE, 1, 'required', 'default', 'label', TRUE, TRUE, '', ''
    WHERE NOT EXISTS (SELECT 1 FROM fields WHERE table_name = NEW.table_name AND field_name = NEW.label_column);

    INSERT INTO fields (table_name, field_name, title, format, is_pk, field_order, input_type, width, ctype, is_core, searchable, reference_table, reference_delete_mode)
    SELECT NEW.table_name, 'created_at', 'Created At', 'date-time', FALSE, 999998, 'disabled', 'default', '', TRUE, FALSE, '', ''
    WHERE NOT EXISTS (SELECT 1 FROM fields WHERE table_name = NEW.table_name AND field_name = 'created_at');

    INSERT INTO fields (table_name, field_name, title, format, is_pk, field_order, input_type, width, ctype, is_core, searchable, reference_table, reference_delete_mode)
    SELECT NEW.table_name, 'updated_at', 'Updated At', 'date-time', FALSE, 999999, 'disabled', 'default', '', TRUE, FALSE, '', ''
    WHERE NOT EXISTS (SELECT 1 FROM fields WHERE table_name = NEW.table_name AND field_name = 'updated_at');

    -- ── Add any missing columns for existing field records ───────────────
    FOR v_field IN
        SELECT * FROM fields WHERE table_name = NEW.table_name
    LOOP
        IF NOT EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_schema = 'public'
              AND table_name    = NEW.table_name
              AND column_name   = v_field.field_name
        ) THEN
            PERFORM apply_field_ddl(v_field);
            RAISE NOTICE 'Added missing column "%" to table "%" (managed changed to true)',
                v_field.field_name, NEW.table_name;
        END IF;
    END LOOP;

    -- Update searchable flag in case any searchable fields exist
    UPDATE entities
    SET searchable = EXISTS (
        SELECT 1 FROM fields
        WHERE table_name = NEW.table_name AND searchable = TRUE
    )
    WHERE table_name = NEW.table_name;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION enable_dd_table IS
'AFTER UPDATE trigger on entities: when managed changes from FALSE to TRUE,
creates the physical table (with RLS policies and updated_at trigger) if it does
not already exist, then adds any columns that were defined as field records while
the table was unmanaged.';

-- Apply trigger AFTER UPDATE on entities (only when managed changes F→T)
CREATE TRIGGER enable_table_trigger
    AFTER UPDATE ON entities
    FOR EACH ROW
    WHEN (OLD.managed = FALSE AND NEW.managed = TRUE)
    EXECUTE FUNCTION enable_dd_table();

COMMENT ON TRIGGER enable_table_trigger ON entities IS
'Creates the physical table and adds missing columns when managed changes from false to true.';

-- =====================================================
-- UPDATE update_dd_field: create missing column first
-- =====================================================
-- When a field belonging to a managed table is updated but the physical
-- column does not yet exist, create it via apply_field_ddl() before
-- attempting any ALTER operations.

CREATE OR REPLACE FUNCTION update_dd_field()
RETURNS TRIGGER AS $$
DECLARE
    v_alter_sql      TEXT;
    v_old_data_type  TEXT;
    v_new_data_type  TEXT;
    v_is_managed     BOOLEAN;
    v_ref_id_column  TEXT;
    v_fk_name        TEXT;
    v_idx_name       TEXT;
    v_on_delete      TEXT;
BEGIN
    -- Check if the parent table is managed
    SELECT managed INTO v_is_managed FROM entities WHERE table_name = NEW.table_name;

    -- Prevent changing critical attributes
    IF OLD.table_name <> NEW.table_name THEN
        -- Allow only when this is a cascade triggered by rename_dd_table()
        IF current_setting('dd.table_rename', TRUE) <> OLD.table_name || ':' || NEW.table_name THEN
            RAISE EXCEPTION 'Cannot change table_name of a field';
        END IF;
        -- Cascade rename: metadata has been updated; no DDL needed here
        RETURN NEW;
    END IF;

    -- field_name was renamed by validate_field_rename_and_format() BEFORE trigger;
    -- no exception here — just continue with the rest of the DDL using NEW.field_name.

    IF OLD.is_pk <> NEW.is_pk THEN
        RAISE EXCEPTION 'Cannot change primary key status of existing field';
    END IF;

    -- Prevent changing structural attributes of core fields
    IF OLD.is_core THEN
        IF OLD.format <> NEW.format THEN
            RAISE EXCEPTION 'Cannot change format of core system field "%"', OLD.field_name;
        END IF;

        IF OLD.default_value IS DISTINCT FROM NEW.default_value THEN
            RAISE EXCEPTION 'Cannot change default value of core system field "%"', OLD.field_name;
        END IF;

        IF OLD.is_core <> NEW.is_core THEN
            RAISE EXCEPTION 'Cannot change is_core status of field "%"', OLD.field_name;
        END IF;
    END IF;

    -- Skip DDL operations if table is not managed (but allow metadata updates like description)
    IF NOT v_is_managed THEN
        -- Still allow updating column comments even if not managed
        IF OLD.description IS DISTINCT FROM NEW.description THEN
            IF NEW.description IS NOT NULL AND trim(NEW.description) != '' THEN
                EXECUTE format(
                    'COMMENT ON COLUMN %I.%I IS %L',
                    NEW.table_name, NEW.field_name, NEW.description
                );
            ELSE
                EXECUTE format(
                    'COMMENT ON COLUMN %I.%I IS NULL',
                    NEW.table_name, NEW.field_name
                );
            END IF;
        END IF;

        RAISE NOTICE 'Skipping DDL operations for "%.%" (table managed=false)', NEW.table_name, NEW.field_name;
        RETURN NEW;
    END IF;

    -- If the physical column is missing from a managed table (e.g. it was defined
    -- while managed=false), create it now with the new field values and return.
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name   = NEW.table_name
          AND column_name  = NEW.field_name
    ) THEN
        PERFORM apply_field_ddl(NEW);
        RAISE NOTICE 'Created missing column "%.%" in managed table', NEW.table_name, NEW.field_name;
        RETURN NEW;
    END IF;

    -- Update column comment if description changed
    IF OLD.description IS DISTINCT FROM NEW.description THEN
        IF NEW.description IS NOT NULL AND trim(NEW.description) != '' THEN
            EXECUTE format(
                'COMMENT ON COLUMN %I.%I IS %L',
                NEW.table_name, NEW.field_name, NEW.description
            );
        ELSE
            EXECUTE format(
                'COMMENT ON COLUMN %I.%I IS NULL',
                NEW.table_name, NEW.field_name
            );
        END IF;
    END IF;

    -- Handle format change
    IF OLD.format <> NEW.format THEN
        v_old_data_type := format_to_data_type(OLD.format, OLD."precision");
        v_new_data_type := format_to_data_type(NEW.format, NEW."precision");

        IF v_old_data_type <> v_new_data_type THEN
            RAISE EXCEPTION
                'Cannot change format of field "%" from "%" to "%" because it would require '
                'changing the column type from % to %.',
                NEW.field_name, OLD.format, NEW.format, v_old_data_type, v_new_data_type;
        END IF;

        RAISE NOTICE 'Changed format of column "%" from "%" to "%" in table "%" (data type unchanged: %)',
            NEW.field_name, OLD.format, NEW.format, NEW.table_name, v_new_data_type;
    END IF;

    -- Allow updating nullable constraint (derived from format)
    IF OLD.is_nullable <> NEW.is_nullable THEN
        IF NEW.is_nullable THEN
            v_alter_sql := format(
                'ALTER TABLE %I ALTER COLUMN %I DROP NOT NULL',
                NEW.table_name, NEW.field_name
            );
        ELSE
            v_alter_sql := format(
                'ALTER TABLE %I ALTER COLUMN %I SET NOT NULL',
                NEW.table_name, NEW.field_name
            );
        END IF;
        EXECUTE v_alter_sql;
        RAISE NOTICE 'Changed column "%" nullable to % in table "%"',
            NEW.field_name, NEW.is_nullable, NEW.table_name;
    END IF;

    -- Allow updating default value
    IF OLD.default_value IS DISTINCT FROM NEW.default_value THEN
        IF NEW.default_value IS NULL THEN
            v_alter_sql := format(
                'ALTER TABLE %I ALTER COLUMN %I DROP DEFAULT',
                NEW.table_name, NEW.field_name
            );
        ELSE
            v_alter_sql := format(
                'ALTER TABLE %I ALTER COLUMN %I SET DEFAULT %s',
                NEW.table_name, NEW.field_name,
                quote_default_value(NEW.default_value, format_to_data_type(NEW.format, NEW."precision"))
            );
        END IF;
        EXECUTE v_alter_sql;
        RAISE NOTICE 'Changed column "%" default value in table "%"',
            NEW.field_name, NEW.table_name;
    END IF;

    -- Handle foreign key reference changes
    IF OLD.format IN ('reference', 'parent') OR NEW.format IN ('reference', 'parent') THEN
        v_fk_name  := format('%s_%s_fkey', NEW.table_name, NEW.field_name);
        v_idx_name := format('idx_%s_%s',  NEW.table_name, NEW.field_name);

        IF (OLD.reference_table IS DISTINCT FROM NEW.reference_table) OR
           (OLD.reference_delete_mode IS DISTINCT FROM NEW.reference_delete_mode) OR
           (OLD.format <> NEW.format)
        THEN
            -- Drop existing FK constraint if it exists
            IF OLD.format IN ('reference', 'parent') THEN
                EXECUTE format(
                    'ALTER TABLE %I DROP CONSTRAINT IF EXISTS %I',
                    NEW.table_name, v_fk_name
                );
                RAISE NOTICE 'Dropped foreign key constraint "%"', v_fk_name;
            END IF;

            -- Add new FK constraint
            IF NEW.format IN ('reference', 'parent')
               AND NEW.reference_table IS NOT NULL
               AND NEW.reference_table != ''
            THEN
                SELECT id_column INTO v_ref_id_column
                FROM entities WHERE table_name = NEW.reference_table;

                IF v_ref_id_column IS NULL THEN
                    RAISE EXCEPTION 'Referenced table "%" not found', NEW.reference_table;
                END IF;

                IF NEW.reference_delete_mode = 'clear' THEN
                    v_on_delete := 'SET NULL';
                ELSIF NEW.reference_delete_mode = 'cascade' THEN
                    v_on_delete := 'CASCADE';
                ELSE
                    v_on_delete := 'RESTRICT';
                END IF;

                v_alter_sql := format(
                    'ALTER TABLE %I ADD CONSTRAINT %I FOREIGN KEY (%I) REFERENCES %I(%I) ON DELETE %s',
                    NEW.table_name, v_fk_name, NEW.field_name,
                    NEW.reference_table, v_ref_id_column, v_on_delete
                );
                EXECUTE v_alter_sql;

                v_alter_sql := format(
                    'CREATE INDEX IF NOT EXISTS %I ON %I(%I)',
                    v_idx_name, NEW.table_name, NEW.field_name
                );
                EXECUTE v_alter_sql;

                RAISE NOTICE 'Updated foreign key "%" from %.% to %.% with ON DELETE %',
                    v_fk_name, NEW.table_name, NEW.field_name,
                    NEW.reference_table, v_ref_id_column, v_on_delete;
            ELSIF NEW.format NOT IN ('reference', 'parent') AND OLD.format IN ('reference', 'parent') THEN
                EXECUTE format('DROP INDEX IF EXISTS %I', v_idx_name);
                RAISE NOTICE 'Dropped index "%" for field "%.%"', v_idx_name, NEW.table_name, NEW.field_name;
            END IF;
        END IF;
    END IF;

    -- Handle enum CHECK constraint changes
    IF OLD.format = 'enum' OR NEW.format = 'enum' THEN
        DECLARE
            v_check_name      TEXT;
            v_enum_values_sql TEXT;
            v_effective_enum  JSONB;
        BEGIN
            v_check_name := format('%s_%s_check', NEW.table_name, NEW.field_name);

            IF (OLD.enum_values IS DISTINCT FROM NEW.enum_values)
               OR (OLD.format <> NEW.format)
               OR (OLD.input_type IS DISTINCT FROM NEW.input_type) THEN
                IF OLD.format = 'enum' THEN
                    EXECUTE format(
                        'ALTER TABLE %I DROP CONSTRAINT IF EXISTS %I',
                        NEW.table_name, v_check_name
                    );
                    RAISE NOTICE 'Dropped CHECK constraint "%"', v_check_name;
                END IF;

                IF NEW.format = 'enum'
                   AND NEW.enum_values IS NOT NULL
                   AND jsonb_array_length(NEW.enum_values) > 0
                THEN
                    v_effective_enum := effective_enum_values(NEW.input_type, NEW.enum_values);
                    v_enum_values_sql := (
                        SELECT string_agg(quote_literal(value::text), ', ')
                        FROM jsonb_array_elements_text(v_effective_enum) AS value
                    );
                    v_alter_sql := format(
                        'ALTER TABLE %I ADD CONSTRAINT %I CHECK (%I IN (%s))',
                        NEW.table_name, v_check_name, NEW.field_name, v_enum_values_sql
                    );
                    EXECUTE v_alter_sql;
                    RAISE NOTICE 'Updated CHECK constraint "%" for enum field "%.%"',
                        v_check_name, NEW.table_name, NEW.field_name;
                END IF;
            END IF;
        END;
    END IF;

    -- Handle unique_value changes
    IF OLD.unique_value IS DISTINCT FROM NEW.unique_value THEN
        DECLARE
            v_unique_idx_name TEXT;
            v_where_clause    TEXT;
        BEGIN
            v_unique_idx_name := format('%s_%s_unique', NEW.table_name, NEW.field_name);
            IF NEW.unique_value THEN
                IF format_to_json_type(NEW.format)::text = '"string"' THEN
                    v_where_clause := format('%I IS NOT NULL AND %I != ''''',
                        NEW.field_name, NEW.field_name);
                ELSE
                    v_where_clause := format('%I IS NOT NULL', NEW.field_name);
                END IF;
                EXECUTE format(
                    'CREATE UNIQUE INDEX IF NOT EXISTS %I ON %I(%I) WHERE %s',
                    v_unique_idx_name, NEW.table_name, NEW.field_name, v_where_clause
                );
                RAISE NOTICE 'Created unique index "%" for field "%.%"',
                    v_unique_idx_name, NEW.table_name, NEW.field_name;
            ELSE
                EXECUTE format('DROP INDEX IF EXISTS %I', v_unique_idx_name);
                RAISE NOTICE 'Dropped unique index "%" for field "%.%"',
                    v_unique_idx_name, NEW.table_name, NEW.field_name;
            END IF;
        END;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION update_dd_field IS
'Trigger function that updates column properties when a field is updated.
table_name changes are allowed only as part of a cascade from rename_dd_table().
field_name renames are handled by the validate_field_rename_and_format BEFORE trigger.
format changes that alter the underlying data type are rejected by the BEFORE trigger.
When the physical column is missing from a managed table (e.g. defined while managed=false),
the column is created via apply_field_ddl() and the function returns early.';

REVOKE EXECUTE ON FUNCTION apply_field_ddl(fields) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION enable_dd_table() FROM PUBLIC;
`,
    "0150_audit_log": `-- =====================================================
-- AUDIT LOG SYSTEM
-- =====================================================
-- Provides comprehensive audit logging for DML operations (INSERT, UPDATE,
-- DELETE, TRUNCATE) on managed entity tables and DDL schema changes.
--
-- Based on the supa_audit pattern (https://github.com/supabase/supa_audit)
-- but integrated directly into _core rather than as an extension.
--
-- All audit tables live in public schema (no separate audit namespace).
--
-- Features:
--   1. Per-table DML audit: enabled/disabled via entities.audit_log toggle
--   2. DDL audit: captures schema changes via event trigger
--   3. Automatic audit trigger management when entities are created/deleted
--   4. Audit trigger renamed when entities are renamed

-- =====================================================
-- STEP 1: Create audit schema (internal functions only)
-- =====================================================
-- The audit schema is used ONLY for internal helper functions and types.
-- The actual audit tables live in public schema for standard API access.

CREATE SCHEMA IF NOT EXISTS audit;

ALTER DEFAULT PRIVILEGES IN SCHEMA audit
    REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

COMMENT ON SCHEMA audit IS 'Internal audit helper functions and types (tables are in public schema)';

-- Create enum type for SQL operations to reduce disk/memory usage vs text
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON t.typnamespace = n.oid WHERE t.typname = 'operation' AND n.nspname = 'audit') THEN
        CREATE TYPE audit.operation AS ENUM (
            'INSERT',
            'UPDATE',
            'DELETE',
            'TRUNCATE'
        );
    END IF;
END $$;

-- =====================================================
-- STEP 2: Create DML audit table (audit_record_logs)
-- =====================================================

CREATE TABLE IF NOT EXISTS public.audit_record_logs (
    id             BIGSERIAL PRIMARY KEY,
    record_id      UUID,
    old_record_id  UUID,
    record_pk      TEXT NOT NULL DEFAULT '',
    op             audit.operation NOT NULL,
    ts             TIMESTAMPTZ NOT NULL DEFAULT now(),
    user_id        INTEGER NOT NULL DEFAULT 0,
    table_oid      OID NOT NULL,
    table_schema   NAME NOT NULL,
    table_name     NAME NOT NULL,
    record         JSONB,
    old_record     JSONB,

    -- at least one of record_id or old_record_id is populated, except for truncates
    CHECK (COALESCE(record_id, old_record_id) IS NOT NULL OR op = 'TRUNCATE'),
    -- record_id must be populated for insert and update
    CHECK ((op IN ('INSERT', 'UPDATE')) = (record_id IS NOT NULL)),
    CHECK ((op IN ('INSERT', 'UPDATE')) = (record IS NOT NULL)),
    -- old_record must be populated for update and delete
    CHECK ((op IN ('UPDATE', 'DELETE')) = (old_record_id IS NOT NULL)),
    CHECK ((op IN ('UPDATE', 'DELETE')) = (old_record IS NOT NULL))
);

COMMENT ON TABLE public.audit_record_logs IS
'Stores DML audit records for entity tables with audit_log enabled.
Each row captures the operation type, the full record (new/old), and metadata.';

COMMENT ON COLUMN public.audit_record_logs.record_pk IS 'Primary key value of the affected record for easy lookup';
COMMENT ON COLUMN public.audit_record_logs.user_id IS 'Internal user id from JWT (rbac.user_id). 0 when no JWT context.';

-- Indexes for efficient querying
CREATE INDEX IF NOT EXISTS audit_record_logs_record_id
    ON public.audit_record_logs(record_id)
    WHERE record_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS audit_record_logs_old_record_id
    ON public.audit_record_logs(old_record_id)
    WHERE old_record_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS audit_record_logs_ts
    ON public.audit_record_logs
    USING BRIN(ts);

CREATE INDEX IF NOT EXISTS audit_record_logs_table_oid
    ON public.audit_record_logs(table_oid);

CREATE INDEX IF NOT EXISTS audit_record_logs_record_pk
    ON public.audit_record_logs(record_pk)
    WHERE record_pk != '';

-- =====================================================
-- STEP 3: Create DDL audit table (audit_ddl_logs)
-- =====================================================

CREATE TABLE IF NOT EXISTS public.audit_ddl_logs (
    id              BIGSERIAL PRIMARY KEY,
    event_time      TIMESTAMPTZ NOT NULL DEFAULT now(),
    user_id         INTEGER NOT NULL DEFAULT 0,
    command_tag     TEXT NOT NULL DEFAULT '',
    object_type     TEXT NOT NULL DEFAULT '',
    object_identity TEXT NOT NULL DEFAULT '',
    query_text      TEXT NOT NULL DEFAULT ''
);

COMMENT ON TABLE public.audit_ddl_logs IS
'Stores DDL schema change events captured by the ddl_command_end event trigger.';

COMMENT ON COLUMN public.audit_ddl_logs.user_id IS 'Internal user id from JWT (rbac.user_id). 0 when no JWT context (e.g. migrations).';

CREATE INDEX IF NOT EXISTS audit_ddl_logs_event_time
    ON public.audit_ddl_logs
    USING BRIN(event_time);

-- =====================================================
-- STEP 4: Helper function to compute record_id from primary key
-- =====================================================

CREATE OR REPLACE FUNCTION audit.primary_key_columns(entity_oid OID)
    RETURNS TEXT[]
    STABLE
    SECURITY DEFINER
    SET search_path = ''
    LANGUAGE sql
AS $$
    SELECT
        COALESCE(
            array_agg(pa.attname::TEXT ORDER BY pa.attnum),
            ARRAY[]::TEXT[]
        )
    FROM
        pg_index pi
        JOIN pg_attribute pa
            ON pi.indrelid = pa.attrelid
            AND pa.attnum = ANY(pi.indkey)
    WHERE
        indrelid = $1
        AND indisprimary
$$;

COMMENT ON FUNCTION audit.primary_key_columns IS
'Returns the column names that form the primary key of a table, identified by OID.';

CREATE OR REPLACE FUNCTION audit.to_record_id(entity_oid OID, pkey_cols TEXT[], rec JSONB)
    RETURNS UUID
    STABLE
    LANGUAGE sql
    SET search_path = public
AS $$
    SELECT
        CASE
            WHEN rec IS NULL THEN NULL
            WHEN pkey_cols = ARRAY[]::TEXT[] THEN gen_random_uuid()
            ELSE (
                SELECT
                    md5(
                        (jsonb_build_array(to_jsonb($1)) || jsonb_agg($3 ->> key_))::TEXT
                    )::UUID
                FROM
                    unnest($2) x(key_)
            )
        END
$$;

COMMENT ON FUNCTION audit.to_record_id IS
'Computes a deterministic UUID from a table OID and primary key values, enabling
indexed lookup of a record''s full version history.';

-- Helper: extract primary key value as text from a jsonb record
CREATE OR REPLACE FUNCTION audit.extract_record_pk(pkey_cols TEXT[], rec JSONB)
    RETURNS TEXT
    STABLE
    LANGUAGE sql
    SET search_path = public
AS $$
    SELECT
        CASE
            WHEN rec IS NULL THEN ''
            WHEN pkey_cols = ARRAY[]::TEXT[] THEN ''
            WHEN array_length(pkey_cols, 1) = 1 THEN COALESCE(rec ->> pkey_cols[1], '')
            ELSE COALESCE(
                (SELECT string_agg(COALESCE(rec ->> key_, ''), ':' ORDER BY ord)
                 FROM unnest(pkey_cols) WITH ORDINALITY AS x(key_, ord)),
                ''
            )
        END
$$;

COMMENT ON FUNCTION audit.extract_record_pk IS
'Extracts the primary key value(s) from a JSONB record as a text string.
For single-column PKs, returns the value directly. For composite PKs, returns colon-separated values.';

-- Helper: safely get current user_id from JWT context, returning 0 when unavailable
CREATE OR REPLACE FUNCTION audit.current_user_id()
    RETURNS INTEGER
    STABLE
    LANGUAGE plpgsql
    SET search_path = public
AS $$
DECLARE
    v_user_id INTEGER;
BEGIN
    -- Try to get the user_id from the app context (set by rbac.ensure_context_initialized)
    v_user_id := current_setting('app.current_user_id', true)::INTEGER;
    IF v_user_id IS NOT NULL THEN
        RETURN v_user_id;
    END IF;
    RETURN 0;
EXCEPTION
    WHEN OTHERS THEN
        RETURN 0;
END;
$$;

COMMENT ON FUNCTION audit.current_user_id IS
'Safely returns the current JWT user_id from app context, or 0 when no JWT context is available (e.g. during migrations).';

-- =====================================================
-- STEP 5: DML audit trigger functions
-- =====================================================

CREATE OR REPLACE FUNCTION audit.insert_update_delete_trigger()
    RETURNS TRIGGER
    SECURITY DEFINER
    SET search_path = ''
    LANGUAGE plpgsql
AS $$
DECLARE
    pkey_cols TEXT[] = audit.primary_key_columns(TG_RELID);
    record_jsonb JSONB = to_jsonb(NEW);
    record_id UUID = audit.to_record_id(TG_RELID, pkey_cols, record_jsonb);
    old_record_jsonb JSONB = to_jsonb(OLD);
    old_record_id UUID = audit.to_record_id(TG_RELID, pkey_cols, old_record_jsonb);
    v_record_pk TEXT;
    v_user_id INTEGER;
BEGIN
    -- Extract primary key from whichever record is available (NEW for INSERT/UPDATE, OLD for DELETE)
    v_record_pk := audit.extract_record_pk(pkey_cols, COALESCE(record_jsonb, old_record_jsonb));
    v_user_id := audit.current_user_id();

    INSERT INTO public.audit_record_logs(
        record_id,
        old_record_id,
        record_pk,
        op,
        user_id,
        table_oid,
        table_schema,
        table_name,
        record,
        old_record
    )
    SELECT
        record_id,
        old_record_id,
        v_record_pk,
        TG_OP::audit.operation,
        v_user_id,
        TG_RELID,
        TG_TABLE_SCHEMA,
        TG_TABLE_NAME,
        record_jsonb,
        old_record_jsonb;

    RETURN COALESCE(NEW, OLD);
END;
$$;

COMMENT ON FUNCTION audit.insert_update_delete_trigger IS
'Row-level AFTER trigger function that logs INSERT, UPDATE, and DELETE operations
to audit_record_logs. Captures the JWT user_id and primary key value.';

CREATE OR REPLACE FUNCTION audit.truncate_trigger()
    RETURNS TRIGGER
    SECURITY DEFINER
    SET search_path = ''
    LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO public.audit_record_logs(
        op,
        user_id,
        table_oid,
        table_schema,
        table_name
    )
    SELECT
        TG_OP::audit.operation,
        audit.current_user_id(),
        TG_RELID,
        TG_TABLE_SCHEMA,
        TG_TABLE_NAME;

    RETURN COALESCE(OLD, NEW);
END;
$$;

COMMENT ON FUNCTION audit.truncate_trigger IS
'Statement-level AFTER trigger function that logs TRUNCATE operations to audit_record_logs.';

-- =====================================================
-- STEP 6: Enable/disable audit tracking functions
-- =====================================================

CREATE OR REPLACE FUNCTION audit.enable_tracking(target_table REGCLASS)
    RETURNS VOID
    VOLATILE
    SECURITY DEFINER
    SET search_path = ''
    LANGUAGE plpgsql
AS $$
DECLARE
    statement_row TEXT = format('
        CREATE TRIGGER audit_i_u_d
            AFTER INSERT OR UPDATE OR DELETE
            ON %s
            FOR EACH ROW
            EXECUTE FUNCTION audit.insert_update_delete_trigger();',
        $1
    );
    statement_stmt TEXT = format('
        CREATE TRIGGER audit_t
            AFTER TRUNCATE
            ON %s
            FOR EACH STATEMENT
            EXECUTE FUNCTION audit.truncate_trigger();',
        $1
    );
    pkey_cols TEXT[] = audit.primary_key_columns($1);
BEGIN
    IF pkey_cols = ARRAY[]::TEXT[] THEN
        RAISE EXCEPTION 'Table % cannot be audited because it has no primary key', $1;
    END IF;

    IF NOT EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid = $1 AND tgname = 'audit_i_u_d') THEN
        EXECUTE statement_row;
    END IF;

    IF NOT EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid = $1 AND tgname = 'audit_t') THEN
        EXECUTE statement_stmt;
    END IF;
END;
$$;

COMMENT ON FUNCTION audit.enable_tracking IS
'Creates audit triggers (audit_i_u_d for row-level, audit_t for truncate) on the given table.
Raises an exception if the table has no primary key.';

CREATE OR REPLACE FUNCTION audit.disable_tracking(target_table REGCLASS)
    RETURNS VOID
    VOLATILE
    SECURITY DEFINER
    SET search_path = ''
    LANGUAGE plpgsql
AS $$
DECLARE
    statement_row TEXT = format(
        'DROP TRIGGER IF EXISTS audit_i_u_d ON %s;',
        $1
    );
    statement_stmt TEXT = format(
        'DROP TRIGGER IF EXISTS audit_t ON %s;',
        $1
    );
BEGIN
    EXECUTE statement_row;
    EXECUTE statement_stmt;
END;
$$;

COMMENT ON FUNCTION audit.disable_tracking IS
'Removes audit triggers (audit_i_u_d, audit_t) from the given table.';

-- =====================================================
-- STEP 7: DDL event trigger function and event trigger
-- =====================================================

CREATE OR REPLACE FUNCTION audit.log_ddl_event()
RETURNS event_trigger
SET search_path = ''
LANGUAGE plpgsql AS $$
DECLARE
    obj RECORD;
    v_user_id INTEGER;
BEGIN
    v_user_id := audit.current_user_id();
    FOR obj IN SELECT * FROM pg_event_trigger_ddl_commands() LOOP
        INSERT INTO public.audit_ddl_logs (user_id, command_tag, object_type, object_identity, query_text)
        VALUES (v_user_id, obj.command_tag, COALESCE(obj.object_type, ''), COALESCE(obj.object_identity, ''), current_query());
    END LOOP;
END;
$$;

COMMENT ON FUNCTION audit.log_ddl_event IS
'Event trigger function that captures DDL commands and logs them to audit_ddl_logs with JWT user_id.';

CREATE EVENT TRIGGER track_ddl_changes
    ON ddl_command_end
    EXECUTE FUNCTION audit.log_ddl_event();

COMMENT ON EVENT TRIGGER track_ddl_changes IS
'Event trigger that fires after any DDL command completes, logging the change to audit_ddl_logs.';

-- =====================================================
-- STEP 8: audit_log column on entities
-- =====================================================
-- Column was added in 0060_dd_schema.sql. Nothing to do here.

-- =====================================================
-- STEP 9: Add field metadata for audit_log column
-- =====================================================

INSERT INTO fields (table_name, field_name, title, description, default_value, format, is_pk, field_order, input_type, width, ctype, is_core, searchable, reference_table, reference_delete_mode)
VALUES
    ('entities', 'audit_log', 'Audit Log', 'When enabled, DML operations on this table are logged to the audit log', 'false', 'boolean', FALSE, 122, 'default', 'default', NULL, TRUE, FALSE, '', '');

-- =====================================================
-- STEP 10: Register audit tables as entities (managed=false)
-- =====================================================
-- These are core system tables. managed=false means no DDL triggers fire
-- when inserting into entities, but having entries in entities/fields makes
-- them queryable through the standard API (get_schema, etc.).

INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column, managed)
VALUES
    ('audit_record_logs', 'audit_record_log', 'Audit Record Log', 'Audit Record Logs', 'DML audit trail for entity table records', (SELECT id FROM modules WHERE module_name = '_core'), 'admin', 'admin', 'id', 'table_name', FALSE),
    ('audit_ddl_logs', 'audit_ddl_log', 'Audit DDL Log', 'Audit DDL Logs', 'DDL audit trail for schema change events', (SELECT id FROM modules WHERE module_name = '_core'), 'admin', 'admin', 'id', 'command_tag', FALSE);

-- Field metadata for audit_record_logs
INSERT INTO fields (table_name, field_name, title, description, format, is_pk, field_order, input_type, width, ctype, is_core, searchable, reference_table, reference_delete_mode)
VALUES
    ('audit_record_logs', 'id',            'Id',            '',                                                                  'int64',     TRUE,  1,   'readonly', 'default', 'id',    TRUE, FALSE, '', ''),
    ('audit_record_logs', 'record_id',     'Record Id',     'Deterministic UUID computed from table OID and primary key values', 'uuid',      FALSE, 10,  'readonly', 'default', NULL,    TRUE, FALSE, '', ''),
    ('audit_record_logs', 'old_record_id', 'Old Record Id', 'Record id before update/delete',                                   'uuid',      FALSE, 20,  'readonly', 'default', NULL,    TRUE, FALSE, '', ''),
    ('audit_record_logs', 'record_pk',     'Record PK',     'Primary key value of the affected record',                          'text',      FALSE, 25,  'readonly', 'default', NULL,    TRUE, TRUE,  '', ''),
    ('audit_record_logs', 'op',            'Operation',     'DML operation type: INSERT, UPDATE, DELETE, TRUNCATE',               'text',      FALSE, 30,  'readonly', 'default', NULL,    TRUE, FALSE, '', ''),
    ('audit_record_logs', 'ts',            'Timestamp',     'When the operation occurred',                                        'date-time', FALSE, 40,  'readonly', 'default', NULL,    TRUE, FALSE, '', ''),
    ('audit_record_logs', 'user_id',       'User Id',       'Internal user id from JWT context (0 when unavailable)',             'int32',     FALSE, 50,  'readonly', 'default', NULL,    TRUE, FALSE, '', ''),
    ('audit_record_logs', 'table_oid',     'Table OID',     'PostgreSQL internal object identifier for the table',                'int32',     FALSE, 60,  'readonly', 'default', NULL,    TRUE, FALSE, '', ''),
    ('audit_record_logs', 'table_schema',  'Table Schema',  'Schema containing the table',                                       'text',      FALSE, 70,  'readonly', 'default', NULL,    TRUE, TRUE,  '', ''),
    ('audit_record_logs', 'table_name',    'Table Name',    'Name of the affected table',                                        'text',      FALSE, 80,  'readonly', 'default', 'label', TRUE, TRUE,  '', ''),
    ('audit_record_logs', 'record',        'Record',        'Full record after INSERT/UPDATE (JSONB)',                            'json',      FALSE, 90,  'readonly', 'w',       NULL,    TRUE, FALSE, '', ''),
    ('audit_record_logs', 'old_record',    'Old Record',    'Previous record before UPDATE/DELETE (JSONB)',                       'json',      FALSE, 100, 'readonly', 'w',       NULL,    TRUE, FALSE, '', '');

-- Field metadata for audit_ddl_logs
INSERT INTO fields (table_name, field_name, title, description, format, is_pk, field_order, input_type, width, ctype, is_core, searchable, reference_table, reference_delete_mode)
VALUES
    ('audit_ddl_logs', 'id',              'Id',              '',                                                                'int64',     TRUE,  1,   'readonly', 'default', 'id',    TRUE, FALSE, '', ''),
    ('audit_ddl_logs', 'event_time',      'Event Time',      'When the DDL command completed',                                  'date-time', FALSE, 10,  'readonly', 'default', NULL,    TRUE, FALSE, '', ''),
    ('audit_ddl_logs', 'user_id',         'User Id',         'Internal user id from JWT context (0 when unavailable)',           'int32',     FALSE, 20,  'readonly', 'default', NULL,    TRUE, FALSE, '', ''),
    ('audit_ddl_logs', 'command_tag',     'Command Tag',     'DDL command type (e.g. CREATE TABLE, ALTER TABLE)',                'text',      FALSE, 30,  'readonly', 'default', 'label', TRUE, TRUE,  '', ''),
    ('audit_ddl_logs', 'object_type',     'Object Type',     'Type of database object affected',                                'text',      FALSE, 40,  'readonly', 'default', NULL,    TRUE, TRUE,  '', ''),
    ('audit_ddl_logs', 'object_identity', 'Object Identity', 'Fully qualified name of the affected object',                     'text',      FALSE, 50,  'readonly', 'w',       NULL,    TRUE, TRUE,  '', ''),
    ('audit_ddl_logs', 'query_text',      'Query Text',      'The SQL statement that triggered the event',                      'text',      FALSE, 60,  'readonly', 'w',       NULL,    TRUE, FALSE, '', '');

-- =====================================================
-- STEP 11: Trigger to manage audit tracking on entity changes
-- =====================================================
-- Handles three scenarios:
--   A) INSERT: enable audit on newly created managed tables
--   B) UPDATE: toggle audit when audit_log changes, or when managed changes
--   C) Rename: audit triggers follow automatically (trigger names are stable: audit_i_u_d, audit_t)

CREATE OR REPLACE FUNCTION manage_audit_log()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        -- Enable audit on newly created managed tables with audit_log=TRUE
        IF NEW.managed AND NEW.audit_log THEN
            -- The physical table must exist (created by create_dd_table trigger)
            IF EXISTS (
                SELECT 1 FROM information_schema.tables t
                WHERE t.table_schema = 'public'
                  AND t.table_name = NEW.table_name
            ) THEN
                PERFORM audit.enable_tracking(NEW.table_name::REGCLASS);
                RAISE NOTICE 'Enabled audit tracking for new table "%"', NEW.table_name;
            END IF;
        END IF;
        RETURN NEW;
    END IF;

    IF TG_OP = 'UPDATE' THEN
        -- Case 1: audit_log toggled
        IF OLD.audit_log IS DISTINCT FROM NEW.audit_log THEN
            IF NEW.managed THEN
                IF NEW.audit_log THEN
                    PERFORM audit.enable_tracking(NEW.table_name::REGCLASS);
                    RAISE NOTICE 'Enabled audit tracking for table "%"', NEW.table_name;
                ELSE
                    PERFORM audit.disable_tracking(NEW.table_name::REGCLASS);
                    RAISE NOTICE 'Disabled audit tracking for table "%"', NEW.table_name;
                END IF;
            END IF;
        END IF;

        -- Case 2: managed toggled to TRUE (enable_dd_table creates the physical table)
        -- The enable_table_trigger fires first; by the time this runs the table exists.
        IF OLD.managed = FALSE AND NEW.managed = TRUE AND NEW.audit_log THEN
            IF EXISTS (
                SELECT 1 FROM information_schema.tables t
                WHERE t.table_schema = 'public'
                  AND t.table_name = NEW.table_name
            ) THEN
                PERFORM audit.enable_tracking(NEW.table_name::REGCLASS);
                RAISE NOTICE 'Enabled audit tracking for newly managed table "%"', NEW.table_name;
            END IF;
        END IF;

        RETURN NEW;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION manage_audit_log IS
'AFTER INSERT/UPDATE trigger on entities: manages audit trigger lifecycle.
On INSERT, enables audit for new managed tables. On UPDATE, toggles audit
when audit_log or managed flags change.';

CREATE TRIGGER manage_audit_log_trigger
    AFTER INSERT OR UPDATE ON entities
    FOR EACH ROW
    EXECUTE FUNCTION manage_audit_log();

COMMENT ON TRIGGER manage_audit_log_trigger ON entities IS
'Manages audit trigger lifecycle when entities are created or modified.';

-- =====================================================
-- STEP 12: Enable audit for _core tables
-- =====================================================
-- Enable audit_log on all _core entities (system tables).
-- These don't have physical audit triggers added yet because
-- audit_log was default FALSE and they were inserted in earlier
-- migrations, but they DO have physical tables.

UPDATE entities SET audit_log = TRUE
WHERE table_name IN (
    'entities', 'fields', 'users', 'modules', 'roles', 'permissions',
    'user_roles', 'role_permissions', 'user_permissions', 'permission_hierarchy'
);

-- Now enable tracking on those tables that are managed and have physical tables
DO $$
DECLARE
    v_rec RECORD;
BEGIN
    FOR v_rec IN
        SELECT e.table_name FROM entities e
        WHERE e.managed = FALSE  -- _core tables are managed=false
          AND e.audit_log = TRUE
    LOOP
        IF EXISTS (
            SELECT 1 FROM information_schema.tables t
            WHERE t.table_schema = 'public'
              AND t.table_name = v_rec.table_name
        ) THEN
            PERFORM audit.enable_tracking(v_rec.table_name::REGCLASS);
            RAISE NOTICE 'Enabled audit tracking for core table "%"', v_rec.table_name;
        END IF;
    END LOOP;
END $$;

-- =====================================================
-- STEP 13: RLS on audit tables
-- =====================================================
-- Audit tables are in public schema, so PostgREST can expose them.
-- RLS ensures only admin users can access audit data.

ALTER TABLE public.audit_record_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.audit_ddl_logs ENABLE ROW LEVEL SECURITY;

-- Allow all operations for admin users
CREATE POLICY audit_record_logs_select ON public.audit_record_logs
    FOR SELECT
    TO semantius_user
    USING (rbac.has_permission('admin'));

CREATE POLICY audit_record_logs_insert ON public.audit_record_logs
    FOR INSERT
    TO semantius_user
    WITH CHECK (true);

CREATE POLICY audit_record_logs_delete ON public.audit_record_logs
    FOR DELETE
    TO semantius_user
    USING (rbac.has_permission('admin'));

CREATE POLICY audit_ddl_logs_select ON public.audit_ddl_logs
    FOR SELECT
    TO semantius_user
    USING (rbac.has_permission('admin'));

CREATE POLICY audit_ddl_logs_insert ON public.audit_ddl_logs
    FOR INSERT
    TO semantius_user
    WITH CHECK (true);

CREATE POLICY audit_ddl_logs_delete ON public.audit_ddl_logs
    FOR DELETE
    TO semantius_user
    USING (rbac.has_permission('admin'));

-- Grant necessary table permissions to semantius_user
GRANT SELECT, INSERT, DELETE ON public.audit_record_logs TO semantius_user;
GRANT SELECT, INSERT, DELETE ON public.audit_ddl_logs TO semantius_user;
GRANT USAGE, SELECT ON SEQUENCE public.audit_record_logs_id_seq TO semantius_user;
GRANT USAGE, SELECT ON SEQUENCE public.audit_ddl_logs_id_seq TO semantius_user;

-- Grant usage on the audit schema to semantius_user (needed for trigger execution)
GRANT USAGE ON SCHEMA audit TO semantius_user;

-- Revoke default PUBLIC execute on audit functions
REVOKE EXECUTE ON FUNCTION audit.primary_key_columns(OID) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION audit.to_record_id(OID, TEXT[], JSONB) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION audit.extract_record_pk(TEXT[], JSONB) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION audit.current_user_id() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION audit.insert_update_delete_trigger() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION audit.truncate_trigger() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION audit.enable_tracking(REGCLASS) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION audit.disable_tracking(REGCLASS) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION manage_audit_log() FROM PUBLIC;
`,
    "0160_pgmq": `--
-- based on https://github.com/pgmq/pgmq v1.11.1
-- The PostgreSQL License Copyright (c) 2023, Tembo
------------------------------------------------------------
-- Schema, tables, records, privileges, indexes, etc
------------------------------------------------------------
-- When installed as an extension, we don't need to create the \`pgmq\` schema
-- because it is automatically created by postgres due to being declared in
-- the extension control file
DO
$$
BEGIN
    IF (SELECT NOT EXISTS( SELECT 1 FROM pg_extension WHERE extname = 'pgmq')) THEN
      CREATE SCHEMA IF NOT EXISTS pgmq;
    END IF;
END
$$;

-- Table where queues and metadata about them is stored
CREATE TABLE IF NOT EXISTS pgmq.meta (
    queue_name VARCHAR UNIQUE NOT NULL,
    is_partitioned BOOLEAN NOT NULL,
    is_unlogged BOOLEAN NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT now() NOT NULL
);

-- Grant permission to pg_monitor to all tables and sequences
-- These grants are intentionally placed here (after creating \`pgmq.meta\` but before creating other tables). This
-- allows the \`pg_dump\` output for a fresh installation to match the output for an installation that followed the
-- upgrade path.
GRANT USAGE ON SCHEMA pgmq TO pg_monitor;
GRANT SELECT ON ALL TABLES IN SCHEMA pgmq TO pg_monitor;
GRANT SELECT ON ALL SEQUENCES IN SCHEMA pgmq TO pg_monitor;
ALTER DEFAULT PRIVILEGES IN SCHEMA pgmq GRANT SELECT ON TABLES TO pg_monitor;
ALTER DEFAULT PRIVILEGES IN SCHEMA pgmq GRANT SELECT ON SEQUENCES TO pg_monitor;

-- Table to track notification throttling for queues
CREATE UNLOGGED TABLE IF NOT EXISTS pgmq.notify_insert_throttle (
    queue_name           VARCHAR UNIQUE NOT NULL -- Queue name (without 'q_' prefix)
       CONSTRAINT notify_insert_throttle_meta_queue_name_fk
            REFERENCES pgmq.meta (queue_name)
            ON DELETE CASCADE,
    throttle_interval_ms INTEGER NOT NULL DEFAULT 0, -- Min milliseconds between notifications (0 = no throttling)
    last_notified_at     TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT to_timestamp(0) -- Timestamp of last sent notification
);

CREATE INDEX IF NOT EXISTS idx_notify_throttle_active
    ON pgmq.notify_insert_throttle (queue_name, last_notified_at)
    WHERE throttle_interval_ms > 0;

CREATE TABLE IF NOT EXISTS pgmq.topic_bindings
(
    pattern        text NOT NULL, -- Wildcard pattern for routing key matching (* = one segment, # = zero or more segments)
    queue_name     text NOT NULL  -- Name of the queue that receives messages when pattern matches
        CONSTRAINT topic_bindings_meta_queue_name_fk
            REFERENCES pgmq.meta (queue_name)
            ON DELETE CASCADE,
    bound_at       TIMESTAMP WITH TIME ZONE DEFAULT now() NOT NULL, -- Timestamp when the binding was created
    compiled_regex text GENERATED ALWAYS AS (
        -- Pre-compile the pattern to regex for faster matching
        -- This avoids runtime compilation on every send_topic call
        '^' ||
        replace(
                replace(
                        regexp_replace(pattern, '([.+?{}()|\\[\\]\\\\^$])', '\\\\\\1', 'g'),
                        '*', '[^.]+'
                ),
                '#', '.*'
        ) || '$'
        ) STORED,                 -- Computed column: stores the compiled regex pattern
    CONSTRAINT topic_bindings_unique_pattern_queue UNIQUE (pattern, queue_name)
);

-- Create covering index for better performance when scanning patterns
-- Includes queue_name and compiled_regex to allow index-only scans (no table access needed)
CREATE INDEX IF NOT EXISTS idx_topic_bindings_covering ON pgmq.topic_bindings (pattern) INCLUDE (queue_name, compiled_regex);

-- Allow the following \`pgmq\` tables to be dumped by \`pg_dump\` when pgmq is installed as an extension
DO
$$
BEGIN
    IF EXISTS(SELECT 1 FROM pg_extension WHERE extname = 'pgmq') THEN
        PERFORM pg_catalog.pg_extension_config_dump('pgmq.meta', '');
        PERFORM pg_catalog.pg_extension_config_dump('pgmq.notify_insert_throttle', '');
        PERFORM pg_catalog.pg_extension_config_dump('pgmq.topic_bindings', '');
    END IF;
END
$$;

-- This type has the shape of a message in a queue, and is often returned by
-- pgmq functions that return messages
CREATE TYPE pgmq.message_record AS (
    msg_id BIGINT,
    read_ct INTEGER,
    enqueued_at TIMESTAMP WITH TIME ZONE,
    last_read_at TIMESTAMP WITH TIME ZONE,
    vt TIMESTAMP WITH TIME ZONE,
    message JSONB,
    headers JSONB
);

CREATE TYPE pgmq.queue_record AS (
    queue_name VARCHAR,
    is_partitioned BOOLEAN,
    is_unlogged BOOLEAN,
    created_at TIMESTAMP WITH TIME ZONE
);

------------------------------------------------------------
-- Functions
------------------------------------------------------------

-- prevents race conditions during queue creation by acquiring a transaction-level advisory lock
-- uses a transaction advisory lock maintain the lock until transaction commit
-- a race condition would still exist if lock was released before commit
CREATE FUNCTION pgmq.acquire_queue_lock(queue_name TEXT)
RETURNS void AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('pgmq.queue_' || queue_name));
END;
$$ LANGUAGE plpgsql;

-- read_grouped_round_robin
-- reads messages while preserving FIFO within groups and interleaving across groups (layered round-robin)
CREATE FUNCTION pgmq.read_grouped_rr(
    queue_name TEXT,
    vt INTEGER,
    qty INTEGER
)
RETURNS SETOF pgmq.message_record AS $$
DECLARE
    sql TEXT;
    qtable TEXT := pgmq.format_table_name(queue_name, 'q');
BEGIN
    sql := FORMAT(
        $QUERY$
        WITH fifo_groups AS (
            -- Determine the absolute head (oldest) message id per FIFO group, regardless of visibility
            SELECT
                COALESCE(headers->>'x-pgmq-group', '_default_fifo_group') AS fifo_key,
                MIN(msg_id) AS head_msg_id
            FROM pgmq.%1$I
            GROUP BY COALESCE(headers->>'x-pgmq-group', '_default_fifo_group')
        ),
        eligible_groups AS (
            -- Only groups whose head message is currently visible
            -- Acquire a transaction-level advisory lock per group to prevent concurrent selection
            SELECT
                g.fifo_key,
                g.head_msg_id,
                ROW_NUMBER() OVER (ORDER BY g.head_msg_id) AS group_priority
            FROM fifo_groups g
            JOIN pgmq.%2$I h ON h.msg_id = g.head_msg_id
            WHERE h.vt <= clock_timestamp()
              AND pg_try_advisory_xact_lock(pg_catalog.hashtextextended(g.fifo_key, 0))
        ),
        available_messages AS (
            -- All currently visible messages starting at the head for each eligible group
            SELECT
                m.msg_id,
                eg.group_priority,
                ROW_NUMBER() OVER (
                    PARTITION BY eg.fifo_key
                    ORDER BY m.msg_id
                ) AS msg_rank_in_group
            FROM pgmq.%3$I m
            JOIN eligible_groups eg
              ON COALESCE(m.headers->>'x-pgmq-group', '_default_fifo_group') = eg.fifo_key
            WHERE m.vt <= clock_timestamp()
              AND m.msg_id >= eg.head_msg_id
        ),
        ordered_messages AS (
            -- Layered round-robin: take rank 1 of all groups by group_priority, then rank 2, etc.
            -- Assign selection order before locking
            SELECT msg_id, ROW_NUMBER() OVER (ORDER BY msg_rank_in_group, group_priority) as selection_order
            FROM available_messages
        ),
        selected_messages AS (
            -- Lock the messages in the correct order, preserving selection_order
            SELECT om.msg_id, om.selection_order
            FROM ordered_messages om
            JOIN pgmq.%4$I m ON m.msg_id = om.msg_id
            WHERE om.selection_order <= $1
            ORDER BY om.selection_order
            FOR UPDATE OF m SKIP LOCKED
        ),
        updated_messages AS (
            UPDATE pgmq.%5$I m
            SET
                vt = clock_timestamp() + %6$L,
                read_ct = read_ct + 1,
                last_read_at = clock_timestamp()
            FROM selected_messages sm
            WHERE m.msg_id = sm.msg_id
              AND m.vt <= clock_timestamp() -- final guard to avoid duplicate reads under races
            RETURNING m.msg_id, m.read_ct, m.enqueued_at, m.last_read_at, m.vt, m.message, m.headers, sm.selection_order
        )
        SELECT msg_id, read_ct, enqueued_at, last_read_at, vt, message, headers
        FROM updated_messages
        ORDER BY selection_order;
        $QUERY$,
        qtable, qtable, qtable, qtable, qtable, make_interval(secs => vt)
    );
    RETURN QUERY EXECUTE sql USING qty;
END;
$$ LANGUAGE plpgsql;

-- read_grouped_rr_with_poll
-- reads messages using round-robin layering across groups, with polling support
CREATE FUNCTION pgmq.read_grouped_rr_with_poll(
    queue_name TEXT,
    vt INTEGER,
    qty INTEGER,
    max_poll_seconds INTEGER DEFAULT 5,
    poll_interval_ms INTEGER DEFAULT 100
)
RETURNS SETOF pgmq.message_record AS $$
DECLARE
    r pgmq.message_record;
    stop_at TIMESTAMP;
BEGIN
    stop_at := clock_timestamp() + make_interval(secs => max_poll_seconds);
    LOOP
      IF (SELECT clock_timestamp() >= stop_at) THEN
        RETURN;
      END IF;

      FOR r IN
        SELECT * FROM pgmq.read_grouped_rr(queue_name, vt, qty)
      LOOP
        RETURN NEXT r;
      END LOOP;
      IF FOUND THEN
        RETURN;
      ELSE
        PERFORM pg_sleep(poll_interval_ms::numeric / 1000);
      END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- read_grouped_head:  read the head of N different FIFO groups in a single operation.
-- This supports horizontal scaling by processing groups in parallel while ensuring message ordering is preserved per group.
CREATE FUNCTION pgmq.read_grouped_head(
    queue_name TEXT,
    vt INTEGER,
    qty INTEGER
)
RETURNS SETOF pgmq.message_record AS $$
DECLARE
    sql TEXT;
    qtable TEXT := pgmq.format_table_name(queue_name, 'q');
BEGIN
    sql := FORMAT(
        $QUERY$
        WITH fifo_groups AS (
            -- Determine the absolute head (oldest) message id per FIFO group, regardless of visibility
            SELECT 
                COALESCE(headers->>'x-pgmq-group', '_default_fifo_group') AS fifo_key,
                MIN(msg_id) AS head_msg_id
            FROM pgmq.%1$I
            GROUP BY COALESCE(headers->>'x-pgmq-group', '_default_fifo_group')
        ),
        selected_messages AS (
            -- Take at most 1 message per group
            SELECT g.head_msg_id msg_id
            FROM fifo_groups g
            JOIN pgmq.%1$I q ON q.msg_id = g.head_msg_id
	        WHERE q.vt <= clock_timestamp()
            ORDER BY q.msg_id
            LIMIT $1
            FOR UPDATE SKIP LOCKED
        )
        UPDATE pgmq.%1$I m
        SET
            vt = clock_timestamp() + %2$L,
            read_ct = read_ct + 1,
            last_read_at = clock_timestamp()
        FROM selected_messages sm
        WHERE m.msg_id = sm.msg_id
        RETURNING m.msg_id, m.read_ct, m.enqueued_at, m.last_read_at, m.vt, m.message, m.headers;
        $QUERY$,
        qtable, make_interval(secs => vt)
    );
    RETURN QUERY EXECUTE sql USING qty;
END;
$$ LANGUAGE plpgsql;

-- a helper to format table names and check for invalid characters
CREATE FUNCTION pgmq.format_table_name(queue_name text, prefix text)
RETURNS TEXT AS $$
BEGIN
    IF queue_name ~ '\\$|;|--|'''
    THEN
        RAISE EXCEPTION 'queue name contains invalid characters: $, ;, --, or \\''';
    END IF;
    RETURN lower(prefix || '_' || queue_name);
END;
$$ LANGUAGE plpgsql;

-- read
-- reads a number of messages from a queue, setting a visibility timeout on them
CREATE FUNCTION pgmq.read(
    queue_name TEXT,
    vt INTEGER,
    qty INTEGER,
    conditional JSONB DEFAULT '{}'
)
RETURNS SETOF pgmq.message_record AS $$
DECLARE
    sql TEXT;
    qtable TEXT := pgmq.format_table_name(queue_name, 'q');
BEGIN
    sql := FORMAT(
        $QUERY$
        WITH cte AS
        (
            SELECT msg_id
            FROM pgmq.%I
            WHERE vt <= clock_timestamp() AND CASE
                WHEN %L != '{}'::jsonb THEN (message @> %2$L)::integer
                ELSE 1
            END = 1
            ORDER BY msg_id ASC
            LIMIT $1
            FOR UPDATE SKIP LOCKED
        )
        UPDATE pgmq.%I m
        SET
            last_read_at = clock_timestamp(),
            vt = clock_timestamp() + %L,
            read_ct = read_ct + 1
        FROM cte
        WHERE m.msg_id = cte.msg_id
        RETURNING m.msg_id, m.read_ct, m.enqueued_at, m.last_read_at, m.vt, m.message, m.headers;
        $QUERY$,
        qtable, conditional, qtable, make_interval(secs => vt)
    );
    RETURN QUERY EXECUTE sql USING qty;
END;
$$ LANGUAGE plpgsql;

-- read_grouped
-- reads messages with AWS SQS FIFO-style batch retrieval behavior
-- attempts to return as many messages as possible from the same message group
CREATE FUNCTION pgmq.read_grouped(
    queue_name TEXT,
    vt INTEGER,
    qty INTEGER
)
RETURNS SETOF pgmq.message_record AS $$
DECLARE
    sql TEXT;
    qtable TEXT := pgmq.format_table_name(queue_name, 'q');
BEGIN
    sql := FORMAT(
        $QUERY$
        WITH fifo_groups AS (
            -- Find the minimum msg_id for each FIFO group that's ready to be processed
            SELECT
                COALESCE(headers->>'x-pgmq-group', '_default_fifo_group') as fifo_key,
                MIN(msg_id) as min_msg_id
            FROM pgmq.%I
            WHERE vt <= clock_timestamp()
            GROUP BY COALESCE(headers->>'x-pgmq-group', '_default_fifo_group')
        ),
        locked_groups AS (
            -- Lock the first available message in each FIFO group
            SELECT
                m.msg_id,
                fg.fifo_key
            FROM pgmq.%I m
            INNER JOIN fifo_groups fg ON
                COALESCE(m.headers->>'x-pgmq-group', '_default_fifo_group') = fg.fifo_key
                AND m.msg_id = fg.min_msg_id
            WHERE m.vt <= clock_timestamp()
            ORDER BY m.msg_id ASC
            FOR UPDATE SKIP LOCKED
        ),
        group_priorities AS (
            -- Assign priority to groups based on their oldest message
            SELECT
                fifo_key,
                msg_id as min_msg_id,
                ROW_NUMBER() OVER (ORDER BY msg_id) as group_priority
            FROM locked_groups
        ),
        filtered_groups as (
            SELECT * FROM group_priorities gp
            WHERE NOT EXISTS (
                -- Ensure no earlier message in this group is currently being processed
                SELECT 1
                FROM pgmq.%I m2
                WHERE COALESCE(m2.headers->>'x-pgmq-group', '_default_fifo_group') = gp.fifo_key
                AND m2.vt > clock_timestamp()
                AND m2.msg_id < gp.min_msg_id
            )
        ),
        available_messages as (
            SELECT gp.fifo_key, t.msg_id,gp.group_priority,
                ROW_NUMBER() OVER (PARTITION BY gp.fifo_key ORDER BY t.msg_id) as msg_rank_in_group
            FROM filtered_groups gp
            CROSS JOIN LATERAL (
                SELECT *
                FROM pgmq.%I t
                WHERE COALESCE(t.headers->>'x-pgmq-group', '_default_fifo_group') = gp.fifo_key
                AND t.vt <= clock_timestamp()
                ORDER BY msg_id
                LIMIT $1  -- tip to limit query impact, we know we need at most qty in each group
            ) t
            ORDER BY gp.group_priority
        ),
        batch_selection AS (
            -- Select messages to fill batch, prioritizing earliest group
            SELECT
                msg_id,
                ROW_NUMBER() OVER (ORDER BY group_priority, msg_rank_in_group) as overall_rank
            FROM available_messages
        ),
        selected_messages AS (
            -- Limit to requested quantity
            SELECT msg_id
            FROM batch_selection
            WHERE overall_rank <= $1
            ORDER BY msg_id
            FOR UPDATE SKIP LOCKED
        )
        UPDATE pgmq.%I m
        SET
            vt = clock_timestamp() + %L,
            read_ct = read_ct + 1,
            last_read_at = clock_timestamp()
        FROM selected_messages sm
        WHERE m.msg_id = sm.msg_id
        RETURNING m.msg_id, m.read_ct, m.enqueued_at, m.last_read_at, m.vt, m.message, m.headers;
        $QUERY$,
        qtable, qtable, qtable, qtable, qtable, make_interval(secs => vt)
    );
    RETURN QUERY EXECUTE sql USING qty;
END;
$$ LANGUAGE plpgsql;

-- read_grouped_with_poll
-- reads messages with AWS SQS FIFO-style batch retrieval behavior, with polling support
CREATE FUNCTION pgmq.read_grouped_with_poll(
    queue_name TEXT,
    vt INTEGER,
    qty INTEGER,
    max_poll_seconds INTEGER DEFAULT 5,
    poll_interval_ms INTEGER DEFAULT 100
)
RETURNS SETOF pgmq.message_record AS $$
DECLARE
    r pgmq.message_record;
    stop_at TIMESTAMP;
BEGIN
    stop_at := clock_timestamp() + make_interval(secs => max_poll_seconds);
    LOOP
      IF (SELECT clock_timestamp() >= stop_at) THEN
        RETURN;
      END IF;

      FOR r IN
        SELECT * FROM pgmq.read_grouped(queue_name, vt, qty)
      LOOP
        RETURN NEXT r;
      END LOOP;
      IF FOUND THEN
        RETURN;
      ELSE
        PERFORM pg_sleep(poll_interval_ms::numeric / 1000);
      END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

---- read_with_poll
---- reads a number of messages from a queue, setting a visibility timeout on them
CREATE FUNCTION pgmq.read_with_poll(
    queue_name TEXT,
    vt INTEGER,
    qty INTEGER,
    max_poll_seconds INTEGER DEFAULT 5,
    poll_interval_ms INTEGER DEFAULT 100,
    conditional JSONB DEFAULT '{}'
)
RETURNS SETOF pgmq.message_record AS $$
DECLARE
    r pgmq.message_record;
    stop_at TIMESTAMP;
    sql TEXT;
    qtable TEXT := pgmq.format_table_name(queue_name, 'q');
BEGIN
    stop_at := clock_timestamp() + make_interval(secs => max_poll_seconds);
    LOOP
      IF (SELECT clock_timestamp() >= stop_at) THEN
        RETURN;
      END IF;

      sql := FORMAT(
          $QUERY$
          WITH cte AS
          (
              SELECT msg_id
              FROM pgmq.%I
              WHERE vt <= clock_timestamp() AND CASE
                  WHEN %L != '{}'::jsonb THEN (message @> %2$L)::integer
                  ELSE 1
              END = 1
              ORDER BY msg_id ASC
              LIMIT $1
              FOR UPDATE SKIP LOCKED
          )
          UPDATE pgmq.%I m
          SET
              last_read_at = clock_timestamp(),
              vt = clock_timestamp() + %L,
              read_ct = read_ct + 1
          FROM cte
          WHERE m.msg_id = cte.msg_id
          RETURNING m.msg_id, m.read_ct, m.enqueued_at, m.last_read_at, m.vt, m.message, m.headers;
          $QUERY$,
          qtable, conditional, qtable, make_interval(secs => vt)
      );

      FOR r IN
        EXECUTE sql USING qty
      LOOP
        RETURN NEXT r;
      END LOOP;
      IF FOUND THEN
        RETURN;
      ELSE
        PERFORM pg_sleep(poll_interval_ms::numeric / 1000);
      END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

---- archive
---- removes a message from the queue, and sends it to the archive, where its
---- saved permanently.
CREATE FUNCTION pgmq.archive(
    queue_name TEXT,
    msg_id BIGINT
)
RETURNS BOOLEAN AS $$
DECLARE
    sql TEXT;
    result BIGINT;
    qtable TEXT := pgmq.format_table_name(queue_name, 'q');
    atable TEXT := pgmq.format_table_name(queue_name, 'a');
BEGIN
    sql := FORMAT(
        $QUERY$
        WITH archived AS (
            DELETE FROM pgmq.%I
            WHERE msg_id = $1
            RETURNING msg_id, vt, read_ct, enqueued_at, last_read_at, message, headers
        )
        INSERT INTO pgmq.%I (msg_id, vt, read_ct, enqueued_at, last_read_at, message, headers)
        SELECT msg_id, vt, read_ct, enqueued_at, last_read_at, message, headers
        FROM archived
        RETURNING msg_id;
        $QUERY$,
        qtable, atable
    );
    EXECUTE sql USING msg_id INTO result;
    RETURN NOT (result IS NULL);
END;
$$ LANGUAGE plpgsql;

---- archive
---- removes an array of message ids from the queue, and sends it to the archive,
---- where these messages will be saved permanently.
CREATE FUNCTION pgmq.archive(
    queue_name TEXT,
    msg_ids BIGINT[]
)
RETURNS SETOF BIGINT AS $$
DECLARE
    sql TEXT;
    qtable TEXT := pgmq.format_table_name(queue_name, 'q');
    atable TEXT := pgmq.format_table_name(queue_name, 'a');
BEGIN
    sql := FORMAT(
        $QUERY$
        WITH archived AS (
            DELETE FROM pgmq.%I
            WHERE msg_id = ANY($1)
            RETURNING msg_id, vt, read_ct, enqueued_at, last_read_at, message, headers
        )
        INSERT INTO pgmq.%I (msg_id, vt, read_ct, enqueued_at, last_read_at, message, headers)
        SELECT msg_id, vt, read_ct, enqueued_at, last_read_at, message, headers
        FROM archived
        RETURNING msg_id;
        $QUERY$,
        qtable, atable
    );
    RETURN QUERY EXECUTE sql USING msg_ids;
END;
$$ LANGUAGE plpgsql;

---- delete
---- deletes a message id from the queue permanently
CREATE FUNCTION pgmq.delete(
    queue_name TEXT,
    msg_id BIGINT
)
RETURNS BOOLEAN AS $$
DECLARE
    sql TEXT;
    result BIGINT;
    qtable TEXT := pgmq.format_table_name(queue_name, 'q');
BEGIN
    sql := FORMAT(
        $QUERY$
        DELETE FROM pgmq.%I
        WHERE msg_id = $1
        RETURNING msg_id
        $QUERY$,
        qtable
    );
    EXECUTE sql USING msg_id INTO result;
    RETURN NOT (result IS NULL);
END;
$$ LANGUAGE plpgsql;

---- delete
---- deletes an array of message ids from the queue permanently
CREATE FUNCTION pgmq.delete(
    queue_name TEXT,
    msg_ids BIGINT[]
)
RETURNS SETOF BIGINT AS $$
DECLARE
    sql TEXT;
    qtable TEXT := pgmq.format_table_name(queue_name, 'q');
BEGIN
    sql := FORMAT(
        $QUERY$
        DELETE FROM pgmq.%I
        WHERE msg_id = ANY($1)
        RETURNING msg_id
        $QUERY$,
        qtable
    );
    RETURN QUERY EXECUTE sql USING msg_ids;
END;
$$ LANGUAGE plpgsql;

-- send: actual implementation
CREATE FUNCTION pgmq.send(
    queue_name TEXT,
    msg JSONB,
    headers JSONB,
    delay TIMESTAMP WITH TIME ZONE
) RETURNS SETOF BIGINT AS $$
DECLARE
    sql TEXT;
    qtable TEXT := pgmq.format_table_name(queue_name, 'q');
BEGIN
    sql := FORMAT(
            $QUERY$
        INSERT INTO pgmq.%I (vt, message, headers)
        VALUES ($2, $1, $3)
        RETURNING msg_id;
        $QUERY$,
            qtable
           );
    RETURN QUERY EXECUTE sql USING msg, delay, headers;
END;
$$ LANGUAGE plpgsql;

-- send: 2 args, no delay or headers
CREATE FUNCTION pgmq.send(
    queue_name TEXT,
    msg JSONB
) RETURNS SETOF BIGINT AS $$
    SELECT * FROM pgmq.send(queue_name, msg, NULL, clock_timestamp());
$$ LANGUAGE sql;

-- send: 3 args with headers
CREATE FUNCTION pgmq.send(
    queue_name TEXT,
    msg JSONB,
    headers JSONB
) RETURNS SETOF BIGINT AS $$
    SELECT * FROM pgmq.send(queue_name, msg, headers, clock_timestamp());
$$ LANGUAGE sql;

-- send: 3 args with integer delay
CREATE FUNCTION pgmq.send(
    queue_name TEXT,
    msg JSONB,
    delay INTEGER
) RETURNS SETOF BIGINT AS $$
    SELECT * FROM pgmq.send(queue_name, msg, NULL, clock_timestamp() + make_interval(secs => delay));
$$ LANGUAGE sql;

-- send: 3 args with timestamp
CREATE FUNCTION pgmq.send(
    queue_name TEXT,
    msg JSONB,
    delay TIMESTAMP WITH TIME ZONE
) RETURNS SETOF BIGINT AS $$
    SELECT * FROM pgmq.send(queue_name, msg, NULL, delay);
$$ LANGUAGE sql;

-- send: 4 args with integer delay
CREATE FUNCTION pgmq.send(
    queue_name TEXT,
    msg JSONB,
    headers JSONB,
    delay INTEGER
) RETURNS SETOF BIGINT AS $$
    SELECT * FROM pgmq.send(queue_name, msg, headers, clock_timestamp() + make_interval(secs => delay));
$$ LANGUAGE sql;

-- _validate_batch_params: Private function to validate batch parameters
CREATE FUNCTION pgmq._validate_batch_params(
    msgs JSONB[],
    headers JSONB[]
) RETURNS void AS $$
BEGIN
    -- Validate that msgs is not NULL or empty
    IF msgs IS NULL OR array_length(msgs, 1) IS NULL THEN
        RAISE EXCEPTION 'msgs cannot be NULL or empty';
    END IF;

    -- Validate that headers array length matches msgs array length if headers is provided
    -- Note: array_length returns NULL for empty arrays, so we use COALESCE to treat empty arrays as length 0
    IF headers IS NOT NULL AND COALESCE(array_length(headers, 1), 0) != COALESCE(array_length(msgs, 1), 0) THEN
        RAISE EXCEPTION 'headers array length (%) must match msgs array length (%)',
            COALESCE(array_length(headers, 1), 0), COALESCE(array_length(msgs, 1), 0);
    END IF;
END;
$$ LANGUAGE plpgsql;

-- _send_batch: Private function that performs the actual batch insert without validation
CREATE FUNCTION pgmq._send_batch(
    queue_name TEXT,
    msgs JSONB[],
    headers JSONB[],
    delay TIMESTAMP WITH TIME ZONE
) RETURNS SETOF BIGINT AS $$
DECLARE
    sql TEXT;
    qtable TEXT := pgmq.format_table_name(queue_name, 'q');
BEGIN
    sql := FORMAT(
            $QUERY$
        INSERT INTO pgmq.%I (vt, message, headers)
        SELECT $2, unnest($1), unnest(coalesce($3, ARRAY[]::jsonb[]))
        RETURNING msg_id;
        $QUERY$,
            qtable
           );
    RETURN QUERY EXECUTE sql USING msgs, delay, headers;
END;
$$ LANGUAGE plpgsql;

-- send_batch: Public function with validation
CREATE FUNCTION pgmq.send_batch(
    queue_name TEXT,
    msgs JSONB[],
    headers JSONB[],
    delay TIMESTAMP WITH TIME ZONE
) RETURNS SETOF BIGINT AS $$
BEGIN
    PERFORM pgmq._validate_batch_params(msgs, headers);
    RETURN QUERY SELECT * FROM pgmq._send_batch(queue_name, msgs, headers, delay);
END;
$$ LANGUAGE plpgsql;

-- send batch: 2 args
CREATE FUNCTION pgmq.send_batch(
    queue_name TEXT,
    msgs JSONB[]
) RETURNS SETOF BIGINT AS $$
    SELECT * FROM pgmq.send_batch(queue_name, msgs, NULL, clock_timestamp());
$$ LANGUAGE sql;

-- send batch: 3 args with headers
CREATE FUNCTION pgmq.send_batch(
    queue_name TEXT,
    msgs JSONB[],
    headers JSONB[]
) RETURNS SETOF BIGINT AS $$
    SELECT * FROM pgmq.send_batch(queue_name, msgs, headers, clock_timestamp());
$$ LANGUAGE sql;

-- send batch: 3 args with integer delay
CREATE FUNCTION pgmq.send_batch(
    queue_name TEXT,
    msgs JSONB[],
    delay INTEGER
) RETURNS SETOF BIGINT AS $$
    SELECT * FROM pgmq.send_batch(queue_name, msgs, NULL, clock_timestamp() + make_interval(secs => delay));
$$ LANGUAGE sql;

-- send batch: 3 args with timestamp
CREATE FUNCTION pgmq.send_batch(
    queue_name TEXT,
    msgs JSONB[],
    delay TIMESTAMP WITH TIME ZONE
) RETURNS SETOF BIGINT AS $$
    SELECT * FROM pgmq.send_batch(queue_name, msgs, NULL, delay);
$$ LANGUAGE sql;

-- send_batch: 4 args with integer delay
CREATE FUNCTION pgmq.send_batch(
    queue_name TEXT,
    msgs JSONB[],
    headers JSONB[],
    delay INTEGER
) RETURNS SETOF BIGINT AS $$
    SELECT * FROM pgmq.send_batch(queue_name, msgs, headers, clock_timestamp() + make_interval(secs => delay));
$$ LANGUAGE sql;

-- returned by pgmq.metrics() and pgmq.metrics_all
CREATE TYPE pgmq.metrics_result AS (
    queue_name text,
    queue_length bigint,
    newest_msg_age_sec int,
    oldest_msg_age_sec int,
    total_messages bigint,
    scrape_time timestamp with time zone,
    queue_visible_length bigint
);

-- get metrics for a single queue
CREATE FUNCTION pgmq.metrics(queue_name TEXT)
RETURNS pgmq.metrics_result AS $$
DECLARE
    result_row pgmq.metrics_result;
    query TEXT;
    qtable TEXT := pgmq.format_table_name(queue_name, 'q');
BEGIN
    query := FORMAT(
        $QUERY$
        WITH q_summary AS (
            SELECT
                count(*) as queue_length,
                count(CASE WHEN vt <= NOW() THEN 1 END) as queue_visible_length,
                EXTRACT(epoch FROM (NOW() - max(enqueued_at)))::int as newest_msg_age_sec,
                EXTRACT(epoch FROM (NOW() - min(enqueued_at)))::int as oldest_msg_age_sec,
                NOW() as scrape_time
            FROM pgmq.%I
        ),
        all_metrics AS (
            SELECT CASE
                WHEN is_called THEN last_value ELSE 0
                END as total_messages
            FROM pgmq.%I
        )
        SELECT
            %L as queue_name,
            q_summary.queue_length,
            q_summary.newest_msg_age_sec,
            q_summary.oldest_msg_age_sec,
            all_metrics.total_messages,
            q_summary.scrape_time,
            q_summary.queue_visible_length
        FROM q_summary, all_metrics
        $QUERY$,
        qtable, qtable || '_msg_id_seq', queue_name
    );
    EXECUTE query INTO result_row;
    RETURN result_row;
END;
$$ LANGUAGE plpgsql;

-- get metrics for all queues
CREATE FUNCTION pgmq."metrics_all"()
RETURNS SETOF pgmq.metrics_result AS $$
DECLARE
    row_name RECORD;
    result_row pgmq.metrics_result;
BEGIN
    FOR row_name IN SELECT queue_name FROM pgmq.meta LOOP
        result_row := pgmq.metrics(row_name.queue_name);
        RETURN NEXT result_row;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- list queues
CREATE FUNCTION pgmq."list_queues"()
RETURNS SETOF pgmq.queue_record AS $$
BEGIN
  RETURN QUERY SELECT * FROM pgmq.meta;
END
$$ LANGUAGE plpgsql;

-- purge queue, deleting all entries in it.
CREATE OR REPLACE FUNCTION pgmq."purge_queue"(queue_name TEXT)
RETURNS BIGINT AS $$
DECLARE
  deleted_count INTEGER;
  qtable TEXT := pgmq.format_table_name(queue_name, 'q');
BEGIN
  -- Get the row count before truncating
  EXECUTE format('SELECT count(*) FROM pgmq.%I', qtable) INTO deleted_count;

  -- Use TRUNCATE for better performance on large tables
  EXECUTE format('TRUNCATE TABLE pgmq.%I', qtable);

  -- Return the number of purged rows
  RETURN deleted_count;
END
$$ LANGUAGE plpgsql;

-- unassign archive, so it can be kept when a queue is deleted
CREATE FUNCTION pgmq."detach_archive"(queue_name TEXT)
RETURNS VOID AS $$
DECLARE
  atable TEXT := pgmq.format_table_name(queue_name, 'a');
BEGIN
  RAISE WARNING 'detach_archive(queue_name) is deprecated and is a no-op. It will be removed in PGMQ v2.0. Archive tables are no longer member objects.';
END
$$ LANGUAGE plpgsql;

-- pop: implementation
CREATE FUNCTION pgmq.pop(queue_name TEXT, qty INTEGER DEFAULT 1)
RETURNS SETOF pgmq.message_record AS $$
DECLARE
    sql TEXT;
    result pgmq.message_record;
    qtable TEXT := pgmq.format_table_name(queue_name, 'q');
BEGIN
    sql := FORMAT(
        $QUERY$
        WITH cte AS
            (
                SELECT msg_id
                FROM pgmq.%I
                WHERE vt <= clock_timestamp()
                ORDER BY msg_id ASC
                LIMIT $1
                FOR UPDATE SKIP LOCKED
            )
        DELETE from pgmq.%I
        WHERE msg_id IN (select msg_id from cte)
        RETURNING msg_id, read_ct, enqueued_at, last_read_at, vt, message, headers;
        $QUERY$,
        qtable, qtable
    );
    RETURN QUERY EXECUTE sql USING qty;
END;
$$ LANGUAGE plpgsql;

-- Sets timestamp vt of a message, returns it
CREATE FUNCTION pgmq.set_vt(queue_name TEXT, msg_id BIGINT, vt TIMESTAMP WITH TIME ZONE)
RETURNS SETOF pgmq.message_record AS $$
DECLARE
    sql TEXT;
    result pgmq.message_record;
    qtable TEXT := pgmq.format_table_name(queue_name, 'q');
BEGIN
    sql := FORMAT(
        $QUERY$
        UPDATE pgmq.%I
        SET vt = $1
        WHERE msg_id = $2
        RETURNING msg_id, read_ct, enqueued_at, last_read_at, vt, message, headers;
        $QUERY$, 
        qtable
    );
    RETURN QUERY EXECUTE sql USING vt, msg_id;
END;
$$ LANGUAGE plpgsql;

-- Sets integer vt of a message, returns it
CREATE FUNCTION pgmq.set_vt(queue_name TEXT, msg_id BIGINT, vt INTEGER)
RETURNS SETOF pgmq.message_record AS $$
    SELECT * FROM pgmq.set_vt(queue_name, msg_id, clock_timestamp() + make_interval(secs => vt));
$$ LANGUAGE sql;

-- Sets timestamp vt of multiple messages, returns them
CREATE FUNCTION pgmq.set_vt(
    queue_name TEXT,
    msg_ids BIGINT[],
    vt TIMESTAMP WITH TIME ZONE
)
RETURNS SETOF pgmq.message_record AS $$
DECLARE
    sql TEXT;
    qtable TEXT := pgmq.format_table_name(queue_name, 'q');
BEGIN
    sql := FORMAT(
        $QUERY$
        UPDATE pgmq.%I
        SET vt = $1
        WHERE msg_id = ANY($2)
        RETURNING msg_id, read_ct, enqueued_at, last_read_at, vt, message, headers;
        $QUERY$,
        qtable
    );
    RETURN QUERY EXECUTE sql USING vt, msg_ids;
END;
$$ LANGUAGE plpgsql;

-- Sets integer vt of multiple messages, returns them
CREATE FUNCTION pgmq.set_vt(
    queue_name TEXT,
    msg_ids BIGINT[],
    vt INTEGER
)
RETURNS SETOF pgmq.message_record AS $$
    SELECT * FROM pgmq.set_vt(queue_name, msg_ids, clock_timestamp() + make_interval(secs => vt));
$$ LANGUAGE sql;

CREATE FUNCTION pgmq._get_pg_partman_schema()
RETURNS TEXT AS $$
  SELECT
    extnamespace::regnamespace::text
  FROM
    pg_extension
  WHERE
    extname = 'pg_partman';
$$ LANGUAGE SQL;

CREATE FUNCTION pgmq.drop_queue(queue_name TEXT, partitioned BOOLEAN)
RETURNS BOOLEAN AS $$
DECLARE
    qtable TEXT := pgmq.format_table_name(queue_name, 'q');
    fq_qtable TEXT := 'pgmq.' || qtable;
    atable TEXT := pgmq.format_table_name(queue_name, 'a');
    fq_atable TEXT := 'pgmq.' || atable;
BEGIN
    RAISE WARNING 'drop_queue(queue_name, partitioned) is deprecated and will be removed in PGMQ v2.0. Use drop_queue(queue_name) instead';

    PERFORM pgmq.drop_queue(queue_name);

    RETURN TRUE;
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION pgmq.drop_queue(queue_name TEXT)
RETURNS BOOLEAN AS $$
DECLARE
    qtable TEXT := pgmq.format_table_name(queue_name, 'q');
    qtable_seq TEXT := qtable || '_msg_id_seq';
    fq_qtable TEXT := 'pgmq.' || qtable;
    atable TEXT := pgmq.format_table_name(queue_name, 'a');
    fq_atable TEXT := 'pgmq.' || atable;
    partitioned BOOLEAN;
BEGIN
    PERFORM pgmq.acquire_queue_lock(queue_name);
    EXECUTE FORMAT(
        $QUERY$
        SELECT is_partitioned FROM pgmq.meta WHERE queue_name = %L
        $QUERY$,
        queue_name
    ) INTO partitioned;

    -- check if the queue exists
    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_name = qtable and table_schema = 'pgmq'
    ) THEN
        RAISE NOTICE 'pgmq queue \`%\` does not exist', queue_name;
        RETURN FALSE;
    END IF;

    EXECUTE FORMAT(
        $QUERY$
        DROP TABLE IF EXISTS pgmq.%I
        $QUERY$,
        qtable
    );

    EXECUTE FORMAT(
        $QUERY$
        DROP TABLE IF EXISTS pgmq.%I
        $QUERY$,
        atable
    );

     IF EXISTS (
          SELECT 1
          FROM information_schema.tables
          WHERE table_name = 'meta' and table_schema = 'pgmq'
     ) THEN
        EXECUTE FORMAT(
            $QUERY$
            DELETE FROM pgmq.meta WHERE queue_name = %L
            $QUERY$,
            queue_name
        );
     END IF;

     IF partitioned THEN
        EXECUTE FORMAT(
          $QUERY$
          DELETE FROM %I.part_config where parent_table in (%L, %L)
          $QUERY$,
          pgmq._get_pg_partman_schema(), fq_qtable, fq_atable
        );
     END IF;

    RETURN TRUE;
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION pgmq.validate_queue_name(queue_name TEXT)
RETURNS void AS $$
BEGIN
  IF length(queue_name) > 47 THEN
    -- complete table identifier must be <= 63
    -- https://www.postgresql.org/docs/17/sql-syntax-lexical.html#SQL-SYNTAX-IDENTIFIERS
    -- e.g. template_pgmq_q_my_queue is an identifier for my_queue when partitioned
    -- template_pgmq_q_ (16) + <a max length queue name> (47) = 63 
    RAISE EXCEPTION 'queue name is too long, maximum length is 47 characters';
  END IF;
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION pgmq._belongs_to_pgmq(table_name TEXT)
RETURNS BOOLEAN AS $$
DECLARE
    sql TEXT;
    result BOOLEAN;
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM pg_depend
    WHERE refobjid = (SELECT oid FROM pg_extension WHERE extname = 'pgmq')
    AND objid = (
        SELECT oid
        FROM pg_class
        WHERE relname = table_name
    )
  ) INTO result;
  RETURN result;
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION pgmq.create_non_partitioned(queue_name TEXT)
RETURNS void AS $$
DECLARE
  qtable TEXT := pgmq.format_table_name(queue_name, 'q');
  qtable_seq TEXT := qtable || '_msg_id_seq';
  atable TEXT := pgmq.format_table_name(queue_name, 'a');
BEGIN
  PERFORM pgmq.validate_queue_name(queue_name);
  PERFORM pgmq.acquire_queue_lock(queue_name);

  EXECUTE FORMAT(
    $QUERY$
    CREATE TABLE IF NOT EXISTS pgmq.%I (
        msg_id BIGINT PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
        read_ct INT DEFAULT 0 NOT NULL,
        enqueued_at TIMESTAMP WITH TIME ZONE DEFAULT now() NOT NULL,
        last_read_at TIMESTAMP WITH TIME ZONE,
        vt TIMESTAMP WITH TIME ZONE NOT NULL,
        message JSONB,
        headers JSONB
    )
    $QUERY$,
    qtable
  );

  EXECUTE FORMAT(
    $QUERY$
    CREATE TABLE IF NOT EXISTS pgmq.%I (
      msg_id BIGINT PRIMARY KEY,
      read_ct INT DEFAULT 0 NOT NULL,
      enqueued_at TIMESTAMP WITH TIME ZONE DEFAULT now() NOT NULL,
      last_read_at TIMESTAMP WITH TIME ZONE,
      archived_at TIMESTAMP WITH TIME ZONE DEFAULT now() NOT NULL,
      vt TIMESTAMP WITH TIME ZONE NOT NULL,
      message JSONB,
      headers JSONB
    );
    $QUERY$,
    atable
  );

  EXECUTE FORMAT(
    $QUERY$
    CREATE INDEX IF NOT EXISTS %I ON pgmq.%I (vt ASC);
    $QUERY$,
    qtable || '_vt_idx', qtable
  );

  EXECUTE FORMAT(
    $QUERY$
    CREATE INDEX IF NOT EXISTS %I ON pgmq.%I (archived_at);
    $QUERY$,
    'archived_at_idx_' || queue_name, atable
  );

  EXECUTE FORMAT(
    $QUERY$
    INSERT INTO pgmq.meta (queue_name, is_partitioned, is_unlogged)
    VALUES (%L, false, false)
    ON CONFLICT
    DO NOTHING;
    $QUERY$,
    queue_name
  );

END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION pgmq.create_unlogged(queue_name TEXT)
RETURNS void AS $$
DECLARE
  qtable TEXT := pgmq.format_table_name(queue_name, 'q');
  qtable_seq TEXT := qtable || '_msg_id_seq';
  atable TEXT := pgmq.format_table_name(queue_name, 'a');
BEGIN
  PERFORM pgmq.validate_queue_name(queue_name);
  PERFORM pgmq.acquire_queue_lock(queue_name);

  EXECUTE FORMAT(
    $QUERY$
    CREATE UNLOGGED TABLE IF NOT EXISTS pgmq.%I (
        msg_id BIGINT PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
        read_ct INT DEFAULT 0 NOT NULL,
        enqueued_at TIMESTAMP WITH TIME ZONE DEFAULT now() NOT NULL,
        last_read_at TIMESTAMP WITH TIME ZONE,
        vt TIMESTAMP WITH TIME ZONE NOT NULL,
        message JSONB,
        headers JSONB
    )
    $QUERY$,
    qtable
  );

  EXECUTE FORMAT(
    $QUERY$
    CREATE TABLE IF NOT EXISTS pgmq.%I (
      msg_id BIGINT PRIMARY KEY,
      read_ct INT DEFAULT 0 NOT NULL,
      enqueued_at TIMESTAMP WITH TIME ZONE DEFAULT now() NOT NULL,
      last_read_at TIMESTAMP WITH TIME ZONE,
      archived_at TIMESTAMP WITH TIME ZONE DEFAULT now() NOT NULL,
      vt TIMESTAMP WITH TIME ZONE NOT NULL,
      message JSONB,
      headers JSONB
    );
    $QUERY$,
    atable
  );

  EXECUTE FORMAT(
    $QUERY$
    CREATE INDEX IF NOT EXISTS %I ON pgmq.%I (vt ASC);
    $QUERY$,
    qtable || '_vt_idx', qtable
  );

  EXECUTE FORMAT(
    $QUERY$
    CREATE INDEX IF NOT EXISTS %I ON pgmq.%I (archived_at);
    $QUERY$,
    'archived_at_idx_' || queue_name, atable
  );

  EXECUTE FORMAT(
    $QUERY$
    INSERT INTO pgmq.meta (queue_name, is_partitioned, is_unlogged)
    VALUES (%L, false, true)
    ON CONFLICT
    DO NOTHING;
    $QUERY$,
    queue_name
  );
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION pgmq._get_partition_col(partition_interval TEXT)
RETURNS TEXT AS $$
DECLARE
  num INTEGER;
BEGIN
    BEGIN
        num := partition_interval::INTEGER;
        RETURN 'msg_id';
    EXCEPTION
        WHEN others THEN
            RETURN 'enqueued_at';
    END;
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION pgmq._extension_exists(extension_name TEXT)
    RETURNS BOOLEAN
    LANGUAGE SQL
AS $$
SELECT EXISTS (
    SELECT 1
    FROM pg_extension
    WHERE extname = extension_name
)
$$;

CREATE FUNCTION pgmq._ensure_pg_partman_installed()
RETURNS void AS $$
BEGIN
  IF NOT pgmq._extension_exists('pg_partman') THEN
    RAISE EXCEPTION 'pg_partman is required for partitioned queues';
  END IF;
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION pgmq._get_pg_partman_major_version()
RETURNS INT
LANGUAGE SQL
AS $$
  SELECT split_part(extversion, '.', 1)::INT
  FROM pg_extension
  WHERE extname = 'pg_partman'
$$;

CREATE FUNCTION pgmq.create_partitioned(
  queue_name TEXT,
  partition_interval TEXT DEFAULT '10000',
  retention_interval TEXT DEFAULT '100000'
)
RETURNS void AS $$
DECLARE
  partition_col TEXT;
  a_partition_col TEXT;
  qtable TEXT := pgmq.format_table_name(queue_name, 'q');
  qtable_seq TEXT := qtable || '_msg_id_seq';
  atable TEXT := pgmq.format_table_name(queue_name, 'a');
  fq_qtable TEXT := 'pgmq.' || qtable;
  fq_atable TEXT := 'pgmq.' || atable;
BEGIN
  PERFORM pgmq.validate_queue_name(queue_name);
  PERFORM pgmq.acquire_queue_lock(queue_name);
  PERFORM pgmq._ensure_pg_partman_installed();
  SELECT pgmq._get_partition_col(partition_interval) INTO partition_col;

  EXECUTE FORMAT(
    $QUERY$
    CREATE TABLE IF NOT EXISTS pgmq.%I (
        msg_id BIGINT GENERATED ALWAYS AS IDENTITY,
        read_ct INT DEFAULT 0 NOT NULL,
        enqueued_at TIMESTAMP WITH TIME ZONE DEFAULT now() NOT NULL,
        last_read_at TIMESTAMP WITH TIME ZONE,
        vt TIMESTAMP WITH TIME ZONE NOT NULL,
        message JSONB,
        headers JSONB
    ) PARTITION BY RANGE (%I)
    $QUERY$,
    qtable, partition_col
  );

  -- https://github.com/pgpartman/pg_partman/blob/master/doc/pg_partman.md
  -- p_parent_table - the existing parent table. MUST be schema qualified, even if in public schema.
  EXECUTE FORMAT(
    $QUERY$
    SELECT %I.create_parent(
      p_parent_table := %L,
      p_control := %L,
      p_interval := %L,
      p_type := case
        when pgmq._get_pg_partman_major_version() = 5 then 'range'
        else 'native'
      end
    )
    $QUERY$,
    pgmq._get_pg_partman_schema(),
    fq_qtable,
    partition_col,
    partition_interval
  );

  EXECUTE FORMAT(
    $QUERY$
    CREATE INDEX IF NOT EXISTS %I ON pgmq.%I (%I);
    $QUERY$,
    qtable || '_part_idx', qtable, partition_col
  );

  EXECUTE FORMAT(
    $QUERY$
    UPDATE %I.part_config
    SET
        retention = %L,
        retention_keep_table = false,
        retention_keep_index = true,
        automatic_maintenance = 'on'
    WHERE parent_table = %L;
    $QUERY$,
    pgmq._get_pg_partman_schema(),
    retention_interval,
    'pgmq.' || qtable
  );

  EXECUTE FORMAT(
    $QUERY$
    INSERT INTO pgmq.meta (queue_name, is_partitioned, is_unlogged)
    VALUES (%L, true, false)
    ON CONFLICT
    DO NOTHING;
    $QUERY$,
    queue_name
  );

  IF partition_col = 'enqueued_at' THEN
    a_partition_col := 'archived_at';
  ELSE
    a_partition_col := partition_col;
  END IF;

  EXECUTE FORMAT(
    $QUERY$
    CREATE TABLE IF NOT EXISTS pgmq.%I (
      msg_id BIGINT NOT NULL,
      read_ct INT DEFAULT 0 NOT NULL,
      enqueued_at TIMESTAMP WITH TIME ZONE DEFAULT now() NOT NULL,
      last_read_at TIMESTAMP WITH TIME ZONE,
      archived_at TIMESTAMP WITH TIME ZONE DEFAULT now() NOT NULL,
      vt TIMESTAMP WITH TIME ZONE NOT NULL,
      message JSONB,
      headers JSONB
    ) PARTITION BY RANGE (%I);
    $QUERY$,
    atable, a_partition_col
  );

  -- https://github.com/pgpartman/pg_partman/blob/master/doc/pg_partman.md
  -- p_parent_table - the existing parent table. MUST be schema qualified, even if in public schema.
  EXECUTE FORMAT(
    $QUERY$
    SELECT %I.create_parent(
      p_parent_table := %L,
      p_control := %L,
      p_interval := %L,
      p_type := case
        when pgmq._get_pg_partman_major_version() = 5 then 'range'
        else 'native'
      end
    )
    $QUERY$,
    pgmq._get_pg_partman_schema(),
    fq_atable,
    a_partition_col,
    partition_interval
  );

  EXECUTE FORMAT(
    $QUERY$
    UPDATE %I.part_config
    SET
        retention = %L,
        retention_keep_table = false,
        retention_keep_index = true,
        automatic_maintenance = 'on'
    WHERE parent_table = %L;
    $QUERY$,
    pgmq._get_pg_partman_schema(),
    retention_interval,
    'pgmq.' || atable
  );

  EXECUTE FORMAT(
    $QUERY$
    CREATE INDEX IF NOT EXISTS %I ON pgmq.%I (archived_at);
    $QUERY$,
    'archived_at_idx_' || queue_name, atable
  );

END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION pgmq.create(queue_name TEXT)
RETURNS void AS $$
BEGIN
    PERFORM pgmq.create_non_partitioned(queue_name);
END;
$$ LANGUAGE plpgsql;

-- _create_fifo_index_if_not_exists
-- internal function to create GIN index on headers for better FIFO performance
CREATE OR REPLACE FUNCTION pgmq._create_fifo_index_if_not_exists(queue_name TEXT)
RETURNS void AS $$
DECLARE
    qtable TEXT := pgmq.format_table_name(queue_name, 'q');
    index_name TEXT := qtable || '_fifo_idx';
BEGIN
    -- Create GIN index on headers for efficient FIFO key lookups
    EXECUTE FORMAT(
        $QUERY$
        CREATE INDEX IF NOT EXISTS %I ON pgmq.%I USING GIN (headers);
        $QUERY$,
        index_name, qtable
    );
END;
$$ LANGUAGE plpgsql;

-- create_fifo_index
-- creates a GIN index on the headers column to improve FIFO read performance
CREATE FUNCTION pgmq.create_fifo_index(queue_name TEXT)
RETURNS void AS $$
BEGIN
    PERFORM pgmq._create_fifo_index_if_not_exists(queue_name);
END;
$$ LANGUAGE plpgsql;

-- create_fifo_indexes_all
-- creates FIFO indexes on all existing queues
CREATE FUNCTION pgmq.create_fifo_indexes_all()
RETURNS void AS $$
DECLARE
    queue_record RECORD;
BEGIN
    FOR queue_record IN SELECT queue_name FROM pgmq.meta LOOP
        PERFORM pgmq.create_fifo_index(queue_record.queue_name);
    END LOOP;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pgmq.convert_archive_partitioned(
  table_name TEXT,
  partition_interval TEXT DEFAULT '10000',
  retention_interval TEXT DEFAULT '100000',
  leading_partition INT DEFAULT 10
)
RETURNS void AS $$
DECLARE
  a_table_name TEXT := pgmq.format_table_name(table_name, 'a');
  a_table_name_old TEXT := pgmq.format_table_name(table_name, 'a') || '_old';
  qualified_a_table_name TEXT := format('pgmq.%I', a_table_name);
  partition_col TEXT;
  a_partition_col TEXT;
BEGIN

  PERFORM c.relkind
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relname = a_table_name
    AND c.relkind = 'p';

  IF FOUND THEN
    RAISE NOTICE 'Table %s is already partitioned', a_table_name;
    RETURN;
  END IF;

  PERFORM c.relkind
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relname = a_table_name
    AND c.relkind = 'r';

  IF NOT FOUND THEN
    RAISE NOTICE 'Table %s does not exists', a_table_name;
    RETURN;
  END IF;

  SELECT pgmq._get_partition_col(partition_interval) INTO partition_col;

  -- For archive tables, use archived_at for time-based partitioning
  IF partition_col = 'enqueued_at' THEN
    a_partition_col := 'archived_at';
  ELSE
    a_partition_col := partition_col;
  END IF;

  EXECUTE 'ALTER TABLE ' || qualified_a_table_name || ' RENAME TO ' || a_table_name_old;

  -- When partitioning by time (archived_at), we need to exclude constraints and indexes
  -- because the existing PRIMARY KEY on msg_id alone is incompatible with partitioning by archived_at.
  -- When partitioning by msg_id, we can keep all constraints including PRIMARY KEY.
  IF a_partition_col = 'archived_at' THEN
    EXECUTE format( 'CREATE TABLE pgmq.%I (LIKE pgmq.%I including defaults including generated including storage including comments) PARTITION BY RANGE (%I)', a_table_name, a_table_name_old, a_partition_col );
  ELSE
    EXECUTE format( 'CREATE TABLE pgmq.%I (LIKE pgmq.%I including all) PARTITION BY RANGE (%I)', a_table_name, a_table_name_old, a_partition_col );
  END IF;

  EXECUTE 'ALTER INDEX pgmq.archived_at_idx_' || table_name || ' RENAME TO archived_at_idx_' || table_name || '_old';
  EXECUTE 'CREATE INDEX archived_at_idx_'|| table_name || ' ON ' || qualified_a_table_name ||'(archived_at)';

  -- https://github.com/pgpartman/pg_partman/blob/master/doc/pg_partman.md
  -- p_parent_table - the existing parent table. MUST be schema qualified, even if in public schema.
  EXECUTE FORMAT(
    $QUERY$
    SELECT %I.create_parent(
      p_parent_table := %L,
      p_control := %L,
      p_interval := %L,
      p_type := case
        when pgmq._get_pg_partman_major_version() = 5 then 'range'
        else 'native'
      end
    )
    $QUERY$,
    pgmq._get_pg_partman_schema(),
    qualified_a_table_name,
    a_partition_col,
    partition_interval
  );

  EXECUTE FORMAT(
    $QUERY$
    UPDATE %I.part_config
    SET
      retention = %L,
      retention_keep_table = false,
      retention_keep_index = false,
      infinite_time_partitions = true
    WHERE
      parent_table = %L;
    $QUERY$,
    pgmq._get_pg_partman_schema(),
    retention_interval,
    qualified_a_table_name
  );
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pgmq.notify_queue_listeners()
RETURNS TRIGGER AS $$
DECLARE
  queue_name_extracted TEXT; -- Queue name extracted from trigger table name
  updated_count        INTEGER; -- Number of rows updated (0 or 1)
BEGIN
  queue_name_extracted := substring(TG_TABLE_NAME from 3);

  UPDATE pgmq.notify_insert_throttle
  SET last_notified_at = clock_timestamp()
  WHERE queue_name = queue_name_extracted
    AND (
      throttle_interval_ms = 0 -- No throttling configured
          OR clock_timestamp() - last_notified_at >=
             (throttle_interval_ms * INTERVAL '1 millisecond') -- Throttle interval has elapsed
    );

  -- Check how many rows were updated (will be 0 or 1)
  GET DIAGNOSTICS updated_count = ROW_COUNT;

  IF updated_count > 0 THEN
    PERFORM PG_NOTIFY('pgmq.' || TG_TABLE_NAME || '.' || TG_OP, NULL);
  END IF;

RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pgmq.enable_notify_insert(queue_name TEXT, throttle_interval_ms INTEGER DEFAULT 250)
RETURNS void AS $$
DECLARE
  qtable TEXT := pgmq.format_table_name(queue_name, 'q');
  v_queue_name TEXT := queue_name;
  v_throttle_interval_ms INTEGER := throttle_interval_ms;
BEGIN
  -- Validate that throttle_interval_ms is non-negative
  IF v_throttle_interval_ms < 0 THEN
    RAISE EXCEPTION 'throttle_interval_ms must be non-negative';
  END IF;

  -- Validate that the queue table exists
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'pgmq' AND table_name = qtable) THEN
    RAISE EXCEPTION 'Queue "%" does not exist. Create it first using pgmq.create()', v_queue_name;
  END IF;

  PERFORM pgmq.disable_notify_insert(v_queue_name);

  INSERT INTO pgmq.notify_insert_throttle (queue_name, throttle_interval_ms)
  VALUES (v_queue_name, v_throttle_interval_ms)
  ON CONFLICT ON CONSTRAINT notify_insert_throttle_queue_name_key DO UPDATE
      SET throttle_interval_ms = EXCLUDED.throttle_interval_ms,
          last_notified_at = to_timestamp(0);

  EXECUTE FORMAT(
    $QUERY$
    CREATE CONSTRAINT TRIGGER trigger_notify_queue_insert_listeners
    AFTER INSERT ON pgmq.%I
    DEFERRABLE FOR EACH ROW
    EXECUTE PROCEDURE pgmq.notify_queue_listeners()
    $QUERY$,
    qtable
  );
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pgmq.disable_notify_insert(queue_name TEXT)
RETURNS void AS $$
DECLARE
  qtable TEXT := pgmq.format_table_name(queue_name, 'q');
  v_queue_name TEXT := queue_name;
BEGIN
  EXECUTE FORMAT(
    $QUERY$
    DROP TRIGGER IF EXISTS trigger_notify_queue_insert_listeners ON pgmq.%I;
    $QUERY$,
    qtable
  );

  DELETE FROM pgmq.notify_insert_throttle nit WHERE nit.queue_name = v_queue_name;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pgmq.list_notify_insert_throttles()
    RETURNS TABLE
            (
                queue_name           text,
                throttle_interval_ms integer,
                last_notified_at     TIMESTAMP WITH TIME ZONE
            )
    LANGUAGE sql
    STABLE
AS
$$
    SELECT queue_name, throttle_interval_ms, last_notified_at
    FROM pgmq.notify_insert_throttle
    ORDER BY queue_name;
$$;

CREATE OR REPLACE FUNCTION pgmq.update_notify_insert(queue_name text, throttle_interval_ms integer)
    RETURNS void
    LANGUAGE plpgsql
AS
$$
BEGIN
    IF throttle_interval_ms < 0 THEN
        RAISE EXCEPTION 'throttle_interval_ms must be non-negative, got: %', throttle_interval_ms;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pgmq.meta WHERE meta.queue_name = update_notify_insert.queue_name) THEN
        RAISE EXCEPTION 'Queue "%" does not exist. Create the queue first using pgmq.create()', queue_name;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pgmq.notify_insert_throttle WHERE notify_insert_throttle.queue_name = update_notify_insert.queue_name) THEN
        RAISE EXCEPTION 'Queue "%" does not have notify_insert enabled. Enable it first using pgmq.enable_notify_insert()', queue_name;
    END IF;

    UPDATE pgmq.notify_insert_throttle
    SET throttle_interval_ms = update_notify_insert.throttle_interval_ms,
        last_notified_at = to_timestamp(0)
    WHERE notify_insert_throttle.queue_name = update_notify_insert.queue_name;
END;
$$;

CREATE OR REPLACE FUNCTION pgmq.validate_routing_key(routing_key text)
    RETURNS boolean
    LANGUAGE plpgsql
    IMMUTABLE
AS
$$
BEGIN
    -- Valid routing key examples:
    --   "logs.error"
    --   "app.user-service.auth"
    --   "system_events.db.connection_failed"
    --
    -- Invalid routing key examples:
    --   ""                     - empty
    --   ".logs.error"          - starts with dot
    --   "logs.error."          - ends with dot
    --   "logs..error"          - consecutive dots
    --   "logs.error!"          - invalid character
    --   "logs error"           - space not allowed
    --   "logs.*"               - wildcards not allowed in routing keys

    IF routing_key IS NULL OR routing_key = '' THEN
        RAISE EXCEPTION 'routing_key cannot be NULL or empty';
    END IF;

    IF length(routing_key) > 255 THEN
        RAISE EXCEPTION 'routing_key length cannot exceed 255 characters, got % characters', length(routing_key);
    END IF;

    IF routing_key !~ '^[a-zA-Z0-9._-]+$' THEN
        RAISE EXCEPTION 'routing_key contains invalid characters. Only alphanumeric, dots, hyphens, and underscores are allowed. Got: %', routing_key;
    END IF;

    IF routing_key ~ '^\\.' THEN
        RAISE EXCEPTION 'routing_key cannot start with a dot. Got: %', routing_key;
    END IF;

    IF routing_key ~ '\\.$' THEN
        RAISE EXCEPTION 'routing_key cannot end with a dot. Got: %', routing_key;
    END IF;

    IF routing_key ~ '\\.\\.' THEN
        RAISE EXCEPTION 'routing_key cannot contain consecutive dots. Got: %', routing_key;
    END IF;

    RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION pgmq.validate_topic_pattern(pattern text)
    RETURNS boolean
    LANGUAGE plpgsql
    IMMUTABLE
AS
$$
BEGIN
    -- Valid pattern examples:
    --   "logs.*"           - matches one segment after logs. (e.g., logs.error, logs.info)
    --   "logs.#"           - matches one or more segments after logs. (e.g., logs.error, logs.api.error)
    --   "*.error"          - matches one segment before .error (e.g., app.error, db.error)
    --   "#.error"          - matches one or more segments before .error (e.g., app.error, x.y.error)
    --   "app.*.#"          - mixed wildcards (one segment then one or more)
    --   "#"                - catch-all pattern, matches any routing key
    --
    -- Invalid pattern examples:
    --   ".logs.*"          - starts with dot
    --   "logs.*."          - ends with dot
    --   "logs..error"      - consecutive dots
    --   "logs.**"          - consecutive stars
    --   "logs.##"          - consecutive hashes
    --   "logs.*#"          - adjacent wildcards
    --   "logs.error!"      - invalid character

    IF pattern IS NULL OR pattern = '' THEN
        RAISE EXCEPTION 'pattern cannot be NULL or empty';
    END IF;

    IF length(pattern) > 255 THEN
        RAISE EXCEPTION 'pattern length cannot exceed 255 characters, got % characters', length(pattern);
    END IF;

    IF pattern !~ '^[a-zA-Z0-9._\\-*#]+$' THEN
        RAISE EXCEPTION 'pattern contains invalid characters. Only alphanumeric, dots, hyphens, underscores, *, and # are allowed. Got: %', pattern;
    END IF;

    IF pattern ~ '^\\.' THEN
        RAISE EXCEPTION 'pattern cannot start with a dot. Got: %', pattern;
    END IF;

    IF pattern ~ '\\.$' THEN
        RAISE EXCEPTION 'pattern cannot end with a dot. Got: %', pattern;
    END IF;

    IF pattern ~ '\\.\\.' THEN
        RAISE EXCEPTION 'pattern cannot contain consecutive dots. Got: %', pattern;
    END IF;

    IF pattern ~ '\\*\\*' THEN
        RAISE EXCEPTION 'pattern cannot contain consecutive stars (**). Use # for multi-segment matching. Got: %', pattern;
    END IF;

    IF pattern ~ '##' THEN
        RAISE EXCEPTION 'pattern cannot contain consecutive hashes (##). A single # already matches zero or more segments. Got: %', pattern;
    END IF;

    IF pattern ~ '\\*#' OR pattern ~ '#\\*' THEN
        RAISE EXCEPTION 'pattern cannot contain adjacent wildcards (*# or #*). Separate wildcards with dots. Got: %', pattern;
    END IF;

    RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION pgmq.bind_topic(pattern text, queue_name text)
    RETURNS void
    LANGUAGE plpgsql
AS
$$
BEGIN
    PERFORM pgmq.validate_topic_pattern(pattern);
    IF queue_name IS NULL OR queue_name = '' THEN
        RAISE EXCEPTION 'queue_name cannot be NULL or empty';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pgmq.meta WHERE meta.queue_name = bind_topic.queue_name) THEN
        RAISE EXCEPTION 'Queue "%" does not exist. Create the queue first using pgmq.create()', queue_name;
    END IF;

    INSERT INTO pgmq.topic_bindings (pattern, queue_name)
    VALUES (pattern, queue_name)
    ON CONFLICT ON CONSTRAINT topic_bindings_unique_pattern_queue DO NOTHING;
END;
$$;

CREATE OR REPLACE FUNCTION pgmq.unbind_topic(pattern text, queue_name text)
    RETURNS boolean
    LANGUAGE plpgsql
AS
$$
DECLARE
    rows_deleted integer;
BEGIN
    IF pattern IS NULL OR pattern = '' THEN
        RAISE EXCEPTION 'pattern cannot be NULL or empty';
    END IF;

    IF queue_name IS NULL OR queue_name = '' THEN
        RAISE EXCEPTION 'queue_name cannot be NULL or empty';
    END IF;

    DELETE
    FROM pgmq.topic_bindings
    WHERE topic_bindings.pattern = unbind_topic.pattern
      AND topic_bindings.queue_name = unbind_topic.queue_name;

    GET DIAGNOSTICS rows_deleted = ROW_COUNT;

    IF rows_deleted > 0 THEN
        RETURN true;
    ELSE
        RETURN false;
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION pgmq.test_routing(routing_key text)
    RETURNS TABLE
            (
                pattern        text,
                queue_name     text,
                compiled_regex text
            )
    LANGUAGE plpgsql
    STABLE
AS
$$
BEGIN
    PERFORM pgmq.validate_routing_key(routing_key);
    RETURN QUERY
        SELECT b.pattern,
               b.queue_name,
               b.compiled_regex
        FROM pgmq.topic_bindings b
        WHERE routing_key ~ b.compiled_regex
        ORDER BY b.pattern;
END;
$$;

CREATE OR REPLACE FUNCTION pgmq.send_topic(routing_key text, msg jsonb, headers jsonb, delay integer)
    RETURNS integer
    LANGUAGE plpgsql
    VOLATILE
AS
$$
DECLARE
    b             RECORD;
    matched_count integer := 0;
BEGIN
    PERFORM pgmq.validate_routing_key(routing_key);

    IF msg IS NULL THEN
        RAISE EXCEPTION 'msg cannot be NULL';
    END IF;

    IF delay < 0 THEN
        RAISE EXCEPTION 'delay cannot be negative, got: %', delay;
    END IF;

    -- Filter matching patterns in SQL for better performance (uses index)
    -- Any failure will rollback the entire transaction
    FOR b IN
        SELECT DISTINCT tb.queue_name
        FROM pgmq.topic_bindings tb
        WHERE routing_key ~ tb.compiled_regex
        ORDER BY tb.queue_name -- Deterministic ordering, deduplicated by queue_name
        LOOP
            PERFORM pgmq.send(b.queue_name, msg, headers, delay);
            matched_count := matched_count + 1;
        END LOOP;

    RETURN matched_count;
END;
$$;

CREATE OR REPLACE FUNCTION pgmq.send_topic(routing_key text, msg jsonb)
    RETURNS integer
    LANGUAGE plpgsql
    VOLATILE
AS
$$
BEGIN
    RETURN pgmq.send_topic(routing_key, msg, NULL, 0);
END;
$$;

CREATE OR REPLACE FUNCTION pgmq.send_topic(routing_key text, msg jsonb, delay integer)
    RETURNS integer
    LANGUAGE plpgsql
    VOLATILE
AS
$$
BEGIN
    RETURN pgmq.send_topic(routing_key, msg, NULL, delay);
END;
$$;

CREATE OR REPLACE FUNCTION pgmq.list_topic_bindings()
    RETURNS TABLE
            (
                pattern        text,
                queue_name     text,
                bound_at       TIMESTAMP WITH TIME ZONE,
                compiled_regex text
            )
    LANGUAGE sql
    STABLE
AS
$$
    SELECT pattern, queue_name, bound_at, compiled_regex
    FROM pgmq.topic_bindings
    ORDER BY bound_at DESC, pattern, queue_name;
$$;

CREATE OR REPLACE FUNCTION pgmq.list_topic_bindings(queue_name text)
    RETURNS TABLE
            (
                pattern        text,
                queue_name     text,
                bound_at       TIMESTAMP WITH TIME ZONE,
                compiled_regex text
            )
    LANGUAGE sql
    STABLE
AS
$$
    SELECT pattern, tb.queue_name, bound_at, compiled_regex
    FROM pgmq.topic_bindings tb
    WHERE tb.queue_name = list_topic_bindings.queue_name
    ORDER BY bound_at DESC, pattern;
$$;

-- send_batch_topic: Base implementation with TIMESTAMP WITH TIME ZONE delay
CREATE OR REPLACE FUNCTION pgmq.send_batch_topic(
    routing_key text,
    msgs jsonb[],
    headers jsonb[],
    delay TIMESTAMP WITH TIME ZONE
)
    RETURNS TABLE(queue_name text, msg_id bigint)
    LANGUAGE plpgsql
    VOLATILE
AS
$$
DECLARE
    b RECORD;
BEGIN
    PERFORM pgmq.validate_routing_key(routing_key);

    -- Validate batch parameters once (not per queue)
    PERFORM pgmq._validate_batch_params(msgs, headers);

    -- Filter matching patterns in SQL for better performance (uses index)
    -- Any failure will rollback the entire transaction
    FOR b IN
        SELECT DISTINCT tb.queue_name
        FROM pgmq.topic_bindings tb
        WHERE routing_key ~ tb.compiled_regex
        ORDER BY tb.queue_name -- Deterministic ordering, deduplicated by queue_name
        LOOP
            -- Use private _send_batch to avoid redundant validation
            RETURN QUERY
            SELECT b.queue_name, batch_result.msg_id
            FROM pgmq._send_batch(b.queue_name, msgs, headers, delay) AS batch_result(msg_id);
        END LOOP;

    RETURN;
END;
$$;

-- send_batch_topic: 2 args (routing_key, msgs)
CREATE OR REPLACE FUNCTION pgmq.send_batch_topic(
    routing_key text,
    msgs jsonb[]
)
    RETURNS TABLE(queue_name text, msg_id bigint)
    LANGUAGE sql
    VOLATILE
AS
$$
    SELECT * FROM pgmq.send_batch_topic(routing_key, msgs, NULL, clock_timestamp());
$$;

-- send_batch_topic: 3 args with headers
CREATE OR REPLACE FUNCTION pgmq.send_batch_topic(
    routing_key text,
    msgs jsonb[],
    headers jsonb[]
)
    RETURNS TABLE(queue_name text, msg_id bigint)
    LANGUAGE sql
    VOLATILE
AS
$$
    SELECT * FROM pgmq.send_batch_topic(routing_key, msgs, headers, clock_timestamp());
$$;

-- send_batch_topic: 3 args with integer delay
CREATE OR REPLACE FUNCTION pgmq.send_batch_topic(
    routing_key text,
    msgs jsonb[],
    delay integer
)
    RETURNS TABLE(queue_name text, msg_id bigint)
    LANGUAGE sql
    VOLATILE
AS
$$
    SELECT * FROM pgmq.send_batch_topic(routing_key, msgs, NULL, clock_timestamp() + make_interval(secs => delay));
$$;

-- send_batch_topic: 3 args with timestamp delay
CREATE OR REPLACE FUNCTION pgmq.send_batch_topic(
    routing_key text,
    msgs jsonb[],
    delay TIMESTAMP WITH TIME ZONE
)
    RETURNS TABLE(queue_name text, msg_id bigint)
    LANGUAGE sql
    VOLATILE
AS
$$
    SELECT * FROM pgmq.send_batch_topic(routing_key, msgs, NULL, delay);
$$;

-- send_batch_topic: 4 args with integer delay
CREATE OR REPLACE FUNCTION pgmq.send_batch_topic(
    routing_key text,
    msgs jsonb[],
    headers jsonb[],
    delay integer
)
    RETURNS TABLE(queue_name text, msg_id bigint)
    LANGUAGE sql
    VOLATILE
AS
$$
    SELECT * FROM pgmq.send_batch_topic(routing_key, msgs, headers, clock_timestamp() + make_interval(secs => delay));
$$;`,
    "0170_queue": `-- =====================================================
-- QUEUE SYSTEM
-- =====================================================
-- Provides managed message queues backed by pgmq.
--
-- Features:
--   1. queues entity: each row represents a pgmq queue
--   2. queue_table_events child entity: maps table DML events
--      to queues so that inserts/updates/deletes on managed tables
--      are automatically enqueued as messages
--   3. RPC functions: queue_read, queue_pop, queue_archive,
--      queue_delete for PostgREST consumers

-- =====================================================
-- STEP 1: Create the queues entity
-- =====================================================

INSERT INTO entities (
    table_name,
    singular,
    singular_label,
    plural_label,
    description,
    module_id,
    view_permission,
    edit_permission,
    id_column,
    label_column
)
VALUES (
    'queues',
    'queue',
    'Queue',
    'Queues',
    'Message queues backed by pgmq',
    1, -- _core module
    'admin',
    'admin',
    'id',
    'queue_name'
);

-- The label_column 'queue_name' is auto-created by the DD trigger.
-- Mark it as unique and required.
UPDATE fields SET unique_value = TRUE, input_type = 'required'
WHERE table_name = 'queues' AND field_name = 'queue_name';

-- Grant semantius_user access to pgmq schema (needed for RPC wrappers)
GRANT USAGE ON SCHEMA pgmq TO semantius_user;

-- =====================================================
-- STEP 2: Triggers on queues table
-- =====================================================
-- INSERT  -> pgmq.create(queue_name)
-- UPDATE  -> reject queue_name change
-- DELETE  -> pgmq.drop_queue(queue_name)

CREATE OR REPLACE FUNCTION queue_after_insert()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pgmq.create(NEW.queue_name);
    RETURN NEW;
END;
$$;

CREATE TRIGGER queue_after_insert_trigger
    AFTER INSERT ON queues
    FOR EACH ROW
    EXECUTE FUNCTION queue_after_insert();

CREATE OR REPLACE FUNCTION queue_before_update()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.queue_name IS DISTINCT FROM NEW.queue_name THEN
        RAISE EXCEPTION 'Cannot change queue_name after creation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER queue_before_update_trigger
    BEFORE UPDATE ON queues
    FOR EACH ROW
    EXECUTE FUNCTION queue_before_update();

CREATE OR REPLACE FUNCTION queue_before_delete()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pgmq.drop_queue(OLD.queue_name);
    RETURN OLD;
END;
$$;

CREATE TRIGGER queue_before_delete_trigger
    BEFORE DELETE ON queues
    FOR EACH ROW
    EXECUTE FUNCTION queue_before_delete();

-- =====================================================
-- STEP 3: Create queue_table_events child entity
-- =====================================================

INSERT INTO entities (
    table_name,
    singular,
    singular_label,
    plural_label,
    description,
    module_id,
    view_permission,
    edit_permission,
    id_column,
    label_column
)
VALUES (
    'queue_table_events',
    'queue_table_event',
    'Queue Table Event',
    'Queue Table Events',
    'Maps table DML events to queues',
    1, -- _core module
    'admin',
    'admin',
    'id',
    'event_name'
);

-- Pre-create table_name column as TEXT (entities.table_name is TEXT, not INTEGER)
ALTER TABLE queue_table_events ADD COLUMN IF NOT EXISTS table_name TEXT NOT NULL DEFAULT '';

INSERT INTO fields (table_name, field_name, title, format, is_pk, field_order, input_type, width, description, default_value, enum_values, ctype, reference_table, reference_delete_mode, relationship_label, unique_value)
VALUES
    ('queue_table_events', 'queue_id',      'Queue',         'parent',    FALSE,  5, 'default',  'default', 'Parent queue this event belongs to',           NULL, NULL,                                                          NULL, 'queues',   'cascade', 'has events', FALSE),
    ('queue_table_events', 'table_name',    'Table',         'reference', FALSE, 10, 'required', 'default', 'Table whose DML events are captured',          '',   NULL,                                                          NULL, 'entities', 'cascade', 'has queue events', TRUE),
    ('queue_table_events', 'event_handler', 'Event Handler', 'enum',      FALSE, 20, 'required', 'default', 'Which DML operations trigger a queue message', '',   '["insert", "update", "upsert", "delete", "change"]'::jsonb,  NULL, '',         '',        '', FALSE);

-- =====================================================
-- STEP 4: Triggers on queue_table_events
-- =====================================================
-- Reject table_name change on UPDATE.
-- On INSERT / DELETE, create or drop the per-table trigger function
-- that enqueues the record JSON into the parent queue.

CREATE OR REPLACE FUNCTION queue_event_before_update()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.table_name IS DISTINCT FROM NEW.table_name THEN
        RAISE EXCEPTION 'Cannot change table_name on a queue table event';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER queue_event_before_update_trigger
    BEFORE UPDATE ON queue_table_events
    FOR EACH ROW
    EXECUTE FUNCTION queue_event_before_update();

-- Helper: build the queue message with id_field and id_value
-- (record and old_record are omitted; id_field comes from entities.id_column)

CREATE OR REPLACE FUNCTION queue_build_record_json()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql AS $$
DECLARE
    v_queue_name TEXT;
    v_id_field TEXT;
    v_event_type TEXT;
    v_id_value JSONB;
    v_row_jsonb JSONB;
    v_msg JSONB;
BEGIN
    -- Find the queue_name, id_column, and event_handler via queue_table_events + queues + entities.
    -- Falls back to 'id' when the LEFT JOIN to entities returns no row (table not registered
    -- in the entity system). The entities.id_column column always has a value when the row exists.
    SELECT q.queue_name, COALESCE(e.id_column, 'id'), qte.event_handler
    INTO v_queue_name, v_id_field, v_event_type
    FROM queue_table_events qte
    JOIN queues q ON q.id = qte.queue_id
    LEFT JOIN entities e ON e.table_name = TG_TABLE_NAME
    WHERE qte.table_name = TG_TABLE_NAME
    LIMIT 1;

    IF v_queue_name IS NULL THEN
        RETURN COALESCE(NEW, OLD);
    END IF;

    -- Extract the id value preserving its native JSON type (number, text, etc.)
    IF TG_OP = 'DELETE' THEN
        v_row_jsonb := to_jsonb(OLD);
    ELSE
        v_row_jsonb := to_jsonb(NEW);
    END IF;
    v_id_value := v_row_jsonb -> v_id_field;

    v_msg := jsonb_build_object(
        'op', TG_OP,
        'ts', now(),
        'table', TG_TABLE_NAME,
        'id_field', v_id_field,
        'id_value', v_id_value,
        'message_type', 'entity_event',
        'event_type', v_event_type
    );

    PERFORM pgmq.send(v_queue_name, v_msg);

    RETURN COALESCE(NEW, OLD);
END;
$$;

-- Manage event trigger creation / removal

CREATE OR REPLACE FUNCTION queue_event_after_insert()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql AS $$
DECLARE
    v_trigger_name TEXT;
    v_trigger_events TEXT;
    v_queue_name TEXT;
BEGIN
    -- Resolve the parent queue name
    SELECT q.queue_name INTO v_queue_name
    FROM queues q WHERE q.id = NEW.queue_id;

    IF v_queue_name IS NULL THEN
        RAISE EXCEPTION 'Parent queue not found for queue_id %', NEW.queue_id;
    END IF;

    -- Determine which trigger events to fire
    v_trigger_events := CASE NEW.event_handler
        WHEN 'insert' THEN 'INSERT'
        WHEN 'update' THEN 'UPDATE'
        WHEN 'upsert' THEN 'INSERT OR UPDATE'
        WHEN 'delete' THEN 'DELETE'
        WHEN 'change' THEN 'INSERT OR UPDATE OR DELETE'
    END;

    v_trigger_name := 'queue_' || v_queue_name || '_' || NEW.event_handler || '_on_' || NEW.table_name;

    -- Create the trigger on the target table
    EXECUTE format(
        'CREATE OR REPLACE TRIGGER %I
            AFTER %s ON %I
            FOR EACH ROW
            EXECUTE FUNCTION queue_build_record_json()',
        v_trigger_name,
        v_trigger_events,
        NEW.table_name
    );

    RETURN NEW;
END;
$$;

CREATE TRIGGER queue_event_after_insert_trigger
    AFTER INSERT ON queue_table_events
    FOR EACH ROW
    EXECUTE FUNCTION queue_event_after_insert();

CREATE OR REPLACE FUNCTION queue_event_after_delete()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql AS $$
DECLARE
    v_trigger_name TEXT;
    v_queue_name TEXT;
BEGIN
    -- Resolve the parent queue name
    SELECT q.queue_name INTO v_queue_name
    FROM queues q WHERE q.id = OLD.queue_id;

    IF v_queue_name IS NULL THEN
        -- Queue already deleted (cascade); nothing to clean up
        RETURN OLD;
    END IF;

    v_trigger_name := 'queue_' || v_queue_name || '_' || OLD.event_handler || '_on_' || OLD.table_name;

    -- Drop the trigger on the target table (ignore if missing)
    EXECUTE format(
        'DROP TRIGGER IF EXISTS %I ON %I',
        v_trigger_name,
        OLD.table_name
    );

    RETURN OLD;
END;
$$;

CREATE TRIGGER queue_event_after_delete_trigger
    AFTER DELETE ON queue_table_events
    FOR EACH ROW
    EXECUTE FUNCTION queue_event_after_delete();

-- Revoke public execute on trigger and helper functions
REVOKE EXECUTE ON FUNCTION queue_after_insert() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION queue_before_update() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION queue_before_delete() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION queue_event_before_update() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION queue_build_record_json() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION queue_event_after_insert() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION queue_event_after_delete() FROM PUBLIC;

-- =====================================================
-- STEP 5: RPC functions for PostgREST consumers
-- =====================================================

-- queue_read: read messages without removing them (visibility timeout)
CREATE OR REPLACE FUNCTION public.queue_read(
    p_queue_name TEXT,
    p_vt INTEGER DEFAULT 30,
    p_qty INTEGER DEFAULT 1
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_result JSONB;
BEGIN
    PERFORM rbac.uid();

    SELECT jsonb_agg(row_to_json(r))
    INTO v_result
    FROM pgmq.read(p_queue_name, p_vt, p_qty) r;

    RETURN COALESCE(v_result, '[]'::jsonb);
END;
$$;

COMMENT ON FUNCTION public.queue_read IS
'Reads messages from a pgmq queue with a visibility timeout (default 30s). Messages remain in the queue but become invisible to other readers for the specified duration.';

REVOKE EXECUTE ON FUNCTION public.queue_read(TEXT, INTEGER, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.queue_read(TEXT, INTEGER, INTEGER) TO semantius_user;

-- queue_pop: read and immediately delete a message
CREATE OR REPLACE FUNCTION public.queue_pop(
    p_queue_name TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_result JSONB;
BEGIN
    PERFORM rbac.uid();

    SELECT jsonb_agg(row_to_json(r))
    INTO v_result
    FROM pgmq.pop(p_queue_name) r;

    RETURN COALESCE(v_result, '[]'::jsonb);
END;
$$;

COMMENT ON FUNCTION public.queue_pop IS
'Pops (reads and deletes) a single message from a pgmq queue.';

REVOKE EXECUTE ON FUNCTION public.queue_pop(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.queue_pop(TEXT) TO semantius_user;

-- queue_archive: move a message to the archive table
CREATE OR REPLACE FUNCTION public.queue_archive(
    p_queue_name TEXT,
    p_msg_id BIGINT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_result BOOLEAN;
BEGIN
    PERFORM rbac.uid();

    SELECT pgmq.archive(p_queue_name, p_msg_id) INTO v_result;

    RETURN COALESCE(v_result, FALSE);
END;
$$;

COMMENT ON FUNCTION public.queue_archive IS
'Archives a message by moving it from the queue table to the archive table.';

REVOKE EXECUTE ON FUNCTION public.queue_archive(TEXT, BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.queue_archive(TEXT, BIGINT) TO semantius_user;

-- queue_delete: permanently delete a message
CREATE OR REPLACE FUNCTION public.queue_delete(
    p_queue_name TEXT,
    p_msg_id BIGINT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_result BOOLEAN;
BEGIN
    PERFORM rbac.uid();

    SELECT pgmq.delete(p_queue_name, p_msg_id) INTO v_result;

    RETURN COALESCE(v_result, FALSE);
END;
$$;

COMMENT ON FUNCTION public.queue_delete IS
'Permanently deletes a message from a pgmq queue.';

REVOKE EXECUTE ON FUNCTION public.queue_delete(TEXT, BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.queue_delete(TEXT, BIGINT) TO semantius_user;
`,
    "0180_computed_validation": `-- =====================================================
-- COMPUTED FIELDS AND VALIDATION RULES
-- =====================================================
-- Per-record derivation and invariant checks expressed as JsonLogic.
--
-- Schema for entities.computed_fields and entities.validation_rules lives in
-- 0060_dd_schema.sql alongside the rest of the entities table; this migration
-- contains only the runtime: a per-table BEFORE INSERT OR UPDATE trigger
-- function that is (re)generated whenever either array is non-empty, and
-- dropped when both are empty or the entity itself is deleted.
--
-- Reserved variables injected into the JsonLogic data:
--   $today    -> server date
--   $now      -> server timestamp
--   $user_id  -> internal user_id from JWT context, null when no context
--   $old      -> previous row as JSON on UPDATE, null on INSERT

-- =====================================================
-- STEP 1: Per-row trigger generator
-- =====================================================

CREATE OR REPLACE FUNCTION build_record_logic_trigger(p_table_name TEXT)
RETURNS VOID AS $$
DECLARE
    v_entity entities%ROWTYPE;
    v_fn_name TEXT;
    v_trg_name CONSTANT TEXT := 'compute_validate_trigger';
    v_body TEXT;
    v_rules_block TEXT := '';
    v_idx INT;
    v_item JSONB;
    v_name TEXT;
    v_path_sql TEXT;
    v_logic_lit TEXT;
    v_code TEXT;
    v_message TEXT;
BEGIN
    SELECT * INTO v_entity FROM entities WHERE table_name = p_table_name;
    IF NOT FOUND THEN
        -- Entity is being deleted — drop the function if it exists
        v_fn_name := 'compute_validate_' || p_table_name;
        EXECUTE format('DROP FUNCTION IF EXISTS public.%I() CASCADE', v_fn_name);
        RETURN;
    END IF;

    -- Skip unmanaged tables (no physical table to attach a trigger to)
    IF NOT v_entity.managed THEN
        RETURN;
    END IF;

    v_fn_name := 'compute_validate_' || p_table_name;

    -- Drop any existing trigger + function so we can recreate cleanly
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON %I', v_trg_name, p_table_name);
    EXECUTE format('DROP FUNCTION IF EXISTS public.%I() CASCADE', v_fn_name);

    -- Both arrays empty → nothing to install
    IF jsonb_array_length(COALESCE(v_entity.computed_fields, '[]'::jsonb)) = 0
       AND jsonb_array_length(COALESCE(v_entity.validation_rules, '[]'::jsonb)) = 0 THEN
        RETURN;
    END IF;

    -- Computed fields: evaluate each, write result into v_data at name (supports dotted paths)
    FOR v_idx IN 0 .. jsonb_array_length(COALESCE(v_entity.computed_fields, '[]'::jsonb)) - 1 LOOP
        v_item := v_entity.computed_fields -> v_idx;
        v_name := v_item ->> 'name';
        IF v_name IS NULL OR v_name = '' THEN
            RAISE EXCEPTION 'computed_fields[%] on "%" is missing required "name"', v_idx, p_table_name;
        END IF;
        IF (v_item -> 'jsonlogic') IS NULL THEN
            RAISE EXCEPTION 'computed_fields[%] on "%" is missing required "jsonlogic"', v_idx, p_table_name;
        END IF;
        v_logic_lit := quote_literal((v_item -> 'jsonlogic')::text);
        SELECT 'ARRAY[' || string_agg(quote_literal(part), ',') || ']::text[]'
          INTO v_path_sql
          FROM unnest(string_to_array(v_name, '.')) AS part;

        v_rules_block := v_rules_block || E'\\n' || format(
$BLOCK$    BEGIN
        v_result := evaluate_json_logic(%s::jsonb, v_data);
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'computed_fields[%s]: %%', SQLERRM;
    END;
    v_data := jsonb_set(v_data, %s, COALESCE(v_result, 'null'::jsonb), true);
$BLOCK$,
            v_logic_lit,
            replace(v_name, '%', '%%'),
            v_path_sql);
    END LOOP;

    -- Validation rules: evaluate each against post-derivation v_data, raise on falsy
    FOR v_idx IN 0 .. jsonb_array_length(COALESCE(v_entity.validation_rules, '[]'::jsonb)) - 1 LOOP
        v_item := v_entity.validation_rules -> v_idx;
        v_code := v_item ->> 'code';
        v_message := v_item ->> 'message';
        IF v_code IS NULL OR v_code = '' THEN
            RAISE EXCEPTION 'validation_rules[%] on "%" is missing required "code"', v_idx, p_table_name;
        END IF;
        IF v_message IS NULL THEN
            RAISE EXCEPTION 'validation_rules[%] on "%" is missing required "message"', v_idx, p_table_name;
        END IF;
        IF (v_item -> 'jsonlogic') IS NULL THEN
            RAISE EXCEPTION 'validation_rules[%] on "%" is missing required "jsonlogic"', v_idx, p_table_name;
        END IF;
        v_logic_lit := quote_literal((v_item -> 'jsonlogic')::text);

        v_rules_block := v_rules_block || E'\\n' || format(
$BLOCK$    BEGIN
        v_result := evaluate_json_logic(%s::jsonb, v_data);
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'validation_rules[%s]: %%', SQLERRM;
    END;
    IF NOT jl_truthy(v_result) THEN
        RAISE EXCEPTION %s USING ERRCODE = '23514', DETAIL = 'rule code: %s';
    END IF;
$BLOCK$,
            v_logic_lit,
            replace(v_code, '%', '%%'),
            quote_literal(v_message),
            replace(v_code, '%', '%%'));
    END LOOP;

    -- Assemble full function. Strip reserved vars before populating NEW so they
    -- never leak as columns even if the entity adds a column with the same name.
    v_body := format($FUNC$
CREATE FUNCTION public.%I() RETURNS TRIGGER AS $TRIG$
DECLARE
    v_data jsonb;
    v_result jsonb;
    v_uid_text text;
BEGIN
    v_uid_text := current_setting('app.current_user_id', true);
    v_data := to_jsonb(NEW) || jsonb_build_object(
        '$today',   to_jsonb(CURRENT_DATE),
        '$now',     to_jsonb(CURRENT_TIMESTAMP),
        '$user_id', CASE
                       WHEN v_uid_text IS NULL OR v_uid_text = '' THEN 'null'::jsonb
                       ELSE to_jsonb(v_uid_text::int)
                   END,
        '$old',     CASE WHEN TG_OP = 'UPDATE' THEN to_jsonb(OLD) ELSE 'null'::jsonb END
    );
%s
    v_data := v_data - '$today' - '$now' - '$user_id' - '$old';
    NEW := jsonb_populate_record(NULL::public.%I, v_data);
    RETURN NEW;
END;
$TRIG$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;
$FUNC$, v_fn_name, v_rules_block, p_table_name);

    EXECUTE v_body;

    -- Revoke PUBLIC execute on trigger function (security best practice)
    EXECUTE format('REVOKE EXECUTE ON FUNCTION public.%I() FROM PUBLIC', v_fn_name);

    EXECUTE format(
        'CREATE TRIGGER %I BEFORE INSERT OR UPDATE ON %I FOR EACH ROW EXECUTE FUNCTION public.%I()',
        v_trg_name, p_table_name, v_fn_name);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION build_record_logic_trigger IS
'Generates (or drops) the per-table BEFORE INSERT OR UPDATE trigger and trigger function used to evaluate computed_fields and validation_rules for the given entity.';

REVOKE EXECUTE ON FUNCTION build_record_logic_trigger(TEXT) FROM PUBLIC;

-- =====================================================
-- STEP 2: Trigger on entities to keep per-row trigger in sync
-- =====================================================

CREATE OR REPLACE FUNCTION manage_record_logic_trigger()
RETURNS TRIGGER AS $$
DECLARE
    v_fn_name TEXT;
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.managed AND (
              jsonb_array_length(COALESCE(NEW.computed_fields, '[]'::jsonb)) > 0
           OR jsonb_array_length(COALESCE(NEW.validation_rules, '[]'::jsonb)) > 0
        ) THEN
            PERFORM build_record_logic_trigger(NEW.table_name);
        END IF;
        RETURN NEW;
    END IF;

    IF TG_OP = 'UPDATE' THEN
        IF OLD.computed_fields IS DISTINCT FROM NEW.computed_fields
           OR OLD.validation_rules IS DISTINCT FROM NEW.validation_rules
           OR OLD.managed IS DISTINCT FROM NEW.managed THEN
            PERFORM build_record_logic_trigger(NEW.table_name);
        END IF;
        RETURN NEW;
    END IF;

    IF TG_OP = 'DELETE' THEN
        v_fn_name := 'compute_validate_' || OLD.table_name;
        EXECUTE format('DROP FUNCTION IF EXISTS public.%I() CASCADE', v_fn_name);
        RETURN OLD;
    END IF;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION manage_record_logic_trigger IS
'Trigger function on entities that creates/updates/drops the per-table BEFORE row trigger for computed_fields and validation_rules.';

-- AFTER INSERT/UPDATE so it runs after create_table_trigger (which creates the
-- physical table). AFTER DELETE so it runs after delete_table_trigger drops the
-- table — at that point only the standalone trigger function survives, which we
-- explicitly drop.
CREATE TRIGGER manage_record_logic_trigger
    AFTER INSERT OR UPDATE OR DELETE ON entities
    FOR EACH ROW
    EXECUTE FUNCTION manage_record_logic_trigger();

REVOKE EXECUTE ON FUNCTION manage_record_logic_trigger() FROM PUBLIC;

-- =====================================================
-- STEP 3: Per-row SELECT policy generator (select_rule)
-- =====================================================
-- When an entity has a non-empty select_rule (a JsonLogic object), this
-- function generates a helper function and replaces the default
-- <table>_select_policy with one that evaluates the rule per row.
-- The generated function converts the row to JSONB, injects reserved
-- variables ($user_id), evaluates the JsonLogic rule, and returns
-- true only when the result is truthy.

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

    -- If select_rule is empty, restore the default permission-only policy
    IF v_entity.select_rule = '{}'::jsonb THEN
        EXECUTE format(
            'CREATE POLICY %I ON %I FOR SELECT TO semantius_user USING (rbac.has_permission(%L))',
            v_policy_name, p_table_name, v_entity.view_permission);
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

    -- Create the new select policy using the generated function
    EXECUTE format(
        'CREATE POLICY %I ON %I FOR SELECT TO semantius_user USING (public.%I(%I.*))',
        v_policy_name, p_table_name, v_fn_name, p_table_name);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION build_select_rule_policy IS
'Generates (or drops) a per-row FOR SELECT RLS policy function that evaluates the entity select_rule JsonLogic against each row.';

REVOKE EXECUTE ON FUNCTION build_select_rule_policy(TEXT) FROM PUBLIC;

-- =====================================================
-- STEP 4: Trigger on entities to keep select_rule policy in sync
-- =====================================================

CREATE OR REPLACE FUNCTION manage_select_rule_policy()
RETURNS TRIGGER AS $$
DECLARE
    v_fn_name TEXT;
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.managed AND NEW.select_rule IS NOT NULL AND NEW.select_rule != '{}'::jsonb THEN
            PERFORM build_select_rule_policy(NEW.table_name);
        END IF;
        RETURN NEW;
    END IF;

    IF TG_OP = 'UPDATE' THEN
        IF OLD.select_rule IS DISTINCT FROM NEW.select_rule
           OR OLD.view_permission IS DISTINCT FROM NEW.view_permission
           OR OLD.managed IS DISTINCT FROM NEW.managed THEN
            PERFORM build_select_rule_policy(NEW.table_name);
        END IF;
        RETURN NEW;
    END IF;

    IF TG_OP = 'DELETE' THEN
        v_fn_name := 'select_rule_' || OLD.table_name;
        EXECUTE format('DROP FUNCTION IF EXISTS public.%I(public.%I) CASCADE', v_fn_name, OLD.table_name);
        RETURN OLD;
    END IF;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION manage_select_rule_policy IS
'Trigger function on entities that creates/updates/drops the per-table FOR SELECT RLS policy for select_rule.';

CREATE TRIGGER manage_select_rule_policy_trigger
    AFTER INSERT OR UPDATE OR DELETE ON entities
    FOR EACH ROW
    EXECUTE FUNCTION manage_select_rule_policy();

REVOKE EXECUTE ON FUNCTION manage_select_rule_policy() FROM PUBLIC;

-- =====================================================
-- STEP 5: Bootstrap triggers for entities inserted before this migration
-- =====================================================
-- Core entities (roles, permission_hierarchy, etc.) may have been inserted in
-- 0060_dd_schema.sql with non-empty validation_rules/computed_fields before the
-- manage_record_logic_trigger existed. Build their triggers now.

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
`,
  },
  "cloud": {
    "0010_webhook_receiver": `-- =====================================================
-- WEBHOOK RECEIVER TABLES
-- =====================================================
-- Create tables for webhook receivers and webhook receiver logs
-- These tables are created by inserting into the entities and fields tables
-- =====================================================

-- =====================================================
-- CREATE webhook_receivers TABLE
-- =====================================================

INSERT INTO entities (
    table_name, 
    singular, 
    singular_label, 
    plural_label, 
    description, 
    module_id, 
    view_permission, 
    edit_permission, 
    id_column, 
    label_column
)
VALUES (
    'webhook_receivers',
    'webhook_receiver',
    'Webhook Receiver',
    'Webhook Receivers',
    'Configuration for webhook endpoints',
    1, -- _core module
    'admin',
    'admin',
    'id',
    'label'
);

-- Pre-create table_name as TEXT before inserting the field metadata.
-- The 'parent' format normally maps to INTEGER in format_to_data_type(), which is designed
-- for auto-incrementing ID references. Here we need TEXT because entities.table_name is TEXT
-- (not an auto-incrementing INTEGER id). By pre-creating the column as TEXT, the DD trigger's
-- ADD COLUMN IF NOT EXISTS silently skips creation and proceeds to build the FK TEXT→TEXT.
ALTER TABLE webhook_receivers ADD COLUMN IF NOT EXISTS table_name TEXT NOT NULL DEFAULT '';

-- Add fields to webhook_receivers table
INSERT INTO fields (table_name, field_name, title, format, is_pk, field_order, input_type, width, description, default_value, enum_values, reference_table, reference_delete_mode, relationship_label)
VALUES
    ('webhook_receivers', 'table_name',   'Table',              'reference', FALSE, 10, 'default', 'default', 'Target table for webhook data',                           '',     NULL,                          'entities', 'cascade', 'has receivers'),
    ('webhook_receivers', 'description',  'Description',        'text',      FALSE, 20, 'default', 'w',       'Description of webhook receiver purpose',                 '',     NULL,                          '',         '',        ''),
    ('webhook_receivers', 'auth_type',    'Authentication Type','enum',      FALSE, 30, 'default', 'default', 'Type of authentication (none, hmac, or custom header)',   'none', '["none", "hmac", "header"]'::jsonb, '', '',   ''),
    ('webhook_receivers', 'secret',       'Secret',             'text',      FALSE, 40, 'default', 'default', 'Secret for webhook authentication',                       '',     NULL,                          '',         '',        ''),
    ('webhook_receivers', 'header_name',  'Header Name',        'text',      FALSE, 45, 'default', 'default', 'Custom header name for authentication',                   '',     NULL,                          '',         '',        ''),
    ('webhook_receivers', 'header_value', 'Header Value',       'text',      FALSE, 46, 'default', 'default', 'Expected value for custom header authentication',         '',     NULL,                          '',         '',        ''),
    ('webhook_receivers', 'jsonata',      'JSONata Expression', 'jsonata',   FALSE, 50, 'default', 'w',       'Optional JSONata expression to transform incoming data',  '',     NULL,                          '',         '',        '');

-- =====================================================
-- CREATE webhook_receiver_logs TABLE
-- =====================================================

INSERT INTO entities (
    table_name, 
    singular, 
    singular_label, 
    plural_label, 
    description, 
    module_id, 
    view_permission, 
    edit_permission, 
    id_column, 
    label_column
)
VALUES (
    'webhook_receiver_logs',
    'webhook_receiver_log',
    'Webhook Receiver Log',
    'Webhook Receiver Logs',
    'Log of webhook receiver events',
    1, -- _core module
    'admin',
    'admin',
    'id',
    'label'
);

-- Add fields to webhook_receiver_logs table
-- Note: 'label' is the label_column and is automatically created by the create_dd_table trigger
-- webhook_id is an explicit parent reference to webhook_receivers (ON DELETE CASCADE)
INSERT INTO fields (table_name, field_name, title, format, is_pk, field_order, input_type, width, description, default_value, enum_values, ctype, reference_table, reference_delete_mode, relationship_label)
VALUES
    ('webhook_receiver_logs', 'webhook_id',          'Webhook Receiver',    'parent',    FALSE,  5, 'default', 'default', 'Parent webhook receiver this log belongs to',     NULL,                 NULL,                        NULL, 'webhook_receivers', 'cascade', 'has logs'),
    ('webhook_receiver_logs', 'webhook_receiver_id', 'Webhook Receiver',    'reference', FALSE, 10, 'default', 'default', 'Reference to webhook receiver configuration',      NULL,                 NULL,                        NULL, 'webhook_receivers', 'clear',   'has logs'),
    ('webhook_receiver_logs', 'webhook_timestamp',   'Webhook Timestamp',   'date-time', FALSE, 30, 'default', 'default', 'Timestamp from webhook source',                    NULL,                 NULL,                        NULL, '',                  '',        ''),
    ('webhook_receiver_logs', 'received_timestamp',  'Received Timestamp',  'date-time', FALSE, 40, 'disabled','default', 'Timestamp when webhook was received',              'CURRENT_TIMESTAMP',  NULL,                        NULL, '',                  '',        ''),
    ('webhook_receiver_logs', 'payload',             'Payload',             'json',      FALSE, 50, 'default', 'w',       'Webhook payload data',                             NULL,                 NULL,                        NULL, '',                  '',        ''),
    ('webhook_receiver_logs', 'result',              'Result',              'enum',      FALSE, 60, 'default', 'default', 'Processing result: 10=received, 20=processed, 90=failed', '10',          '["10", "20", "90"]'::jsonb, NULL, '',                  '',        ''),
    ('webhook_receiver_logs', 'error_message',       'Error Message',       'text',      FALSE, 70, 'default', 'w',       'Error message if processing failed',               '',                   NULL,                        NULL, '',                  '',        '');

-- =====================================================
-- ADD INDEX
-- =====================================================
-- The dynamic table system creates the foreign key and index automatically
-- via the DD trigger when the table_name field is inserted with format='parent'
-- (constraint name: webhook_receivers_table_name_fkey)
`,
    "0020_dashboard": `-- =====================================================
-- DASHBOARD TABLE
-- =====================================================
-- Create table for user-configured dashboards
-- =====================================================

-- =====================================================
-- CREATE dashboards TABLE
-- =====================================================

INSERT INTO entities (
    table_name,
    singular,
    singular_label,
    plural_label,
    description,
    module_id,
    view_permission,
    edit_permission,
    id_column,
    label_column
)
VALUES (
    'dashboards',
    'dashboard',
    'Dashboard',
    'Dashboards',
    'User-configured dashboard layouts and configurations',
    1, -- _core module
    'admin',
    'admin',
    'id',
    'label'
);

-- Add fields to dashboards table
INSERT INTO fields (table_name, field_name, title, format, field_order, input_type, width, description, default_value, reference_table, reference_delete_mode)
VALUES
    ('dashboards', 'config',   'Configuration', 'json',  10, 'default', 'w', 'Dashboard layout and widget configuration', '', '', ''),
    ('dashboards', 'position', 'Position',      'int32', 20, 'default', 'default', 'Display order position', '0', '', '');

INSERT INTO fields (table_name, field_name, title, format, field_order, input_type, width, description, reference_table, reference_delete_mode)
VALUES
    ('dashboards', 'module_id',       'Module',          'reference', 30, 'default', 'default', 'Module this dashboard belongs to',     'modules',     'cascade'),
    ('dashboards', 'view_permission', 'View Permission',  'reference', 40, 'default', 'default', 'Permission required to view this dashboard', 'permissions', 'clear');
`,
  },
  "nwind": {
    "0010_create": `-- =====================================================
-- NORTHWIND ENTITY/FIELD DEFINITIONS
-- =====================================================
-- Converts the Northwind database from raw DDL to the
-- entity/field system. Tables are created automatically
-- by triggers when rows are inserted into entities.
-- =====================================================

-- Module
INSERT INTO modules (module_name, module_slug, description, view_permission, home_page)
VALUES ('Northwind', 'nwind', 'Northwind Sample Database', 'nwind:view', '/nwind');

-- Permissions
INSERT INTO permissions (permission_name, description, module_id) VALUES
    ('nwind:view',   'View Northwind data',   (SELECT id FROM modules WHERE module_name = 'Northwind')),
    ('nwind:manage', 'Manage Northwind data', (SELECT id FROM modules WHERE module_name = 'Northwind'));

-- Permission hierarchy: nwind:manage implies nwind:view
INSERT INTO permission_hierarchy (including_permission_id, included_permission_id)
SELECT p.id, c.id
FROM permissions p, permissions c
WHERE p.permission_name = 'nwind:manage'
  AND c.permission_name = 'nwind:view';

-- Set module FK references for Northwind
UPDATE modules SET
    manage_permission_id = (SELECT id FROM permissions WHERE permission_name = 'nwind:manage')
WHERE module_name = 'Northwind';

-- =====================================================
-- ENTITIES
-- =====================================================

-- 1. categories
INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES (
    'categories',
    'category',
    'Category',
    'Categories',
    'Product categories',
    (SELECT id FROM modules WHERE module_name = 'Northwind'),
    'nwind:view',
    'nwind:manage',
    'id',
    'category_name'
);

-- 2. customers
INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES (
    'customers',
    'customer',
    'Customer',
    'Customers',
    'Customer information and contact details',
    (SELECT id FROM modules WHERE module_name = 'Northwind'),
    'nwind:view',
    'nwind:manage',
    'id',
    'company_name'
);

-- 3. employees
INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES (
    'employees',
    'employee',
    'Employee',
    'Employees',
    'Employee records and contact information',
    (SELECT id FROM modules WHERE module_name = 'Northwind'),
    'nwind:view',
    'nwind:manage',
    'id',
    'last_name'
);

-- 4. suppliers
INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES (
    'suppliers',
    'supplier',
    'Supplier',
    'Suppliers',
    'Supplier information and contact details',
    (SELECT id FROM modules WHERE module_name = 'Northwind'),
    'nwind:view',
    'nwind:manage',
    'id',
    'company_name'
);

-- 5. products
INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES (
    'products',
    'product',
    'Product',
    'Products',
    'Product catalog and inventory',
    (SELECT id FROM modules WHERE module_name = 'Northwind'),
    'nwind:view',
    'nwind:manage',
    'id',
    'product_name'
);

-- 6. regions
INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES (
    'regions',
    'region',
    'Region',
    'Regions',
    'Sales territories and geographic regions',
    (SELECT id FROM modules WHERE module_name = 'Northwind'),
    'nwind:view',
    'nwind:manage',
    'id',
    'region_description'
);

-- 7. shippers
INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES (
    'shippers',
    'shipper',
    'Shipper',
    'Shippers',
    'Shipping companies and carriers',
    (SELECT id FROM modules WHERE module_name = 'Northwind'),
    'nwind:view',
    'nwind:manage',
    'id',
    'company_name'
);

-- 8. orders
INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES (
    'orders',
    'order',
    'Order',
    'Orders',
    'Customer orders and shipping details',
    (SELECT id FROM modules WHERE module_name = 'Northwind'),
    'nwind:view',
    'nwind:manage',
    'id',
    'ship_name'
);

-- 9. territories
INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES (
    'territories',
    'territory',
    'Territory',
    'Territories',
    'Sales territories within regions',
    (SELECT id FROM modules WHERE module_name = 'Northwind'),
    'nwind:view',
    'nwind:manage',
    'id',
    'territory_description'
);

-- 10. employee_territories (junction)
INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES (
    'employee_territories',
    'employee_territory',
    'Employee Territory',
    'Employee Territories',
    'Links employees to their assigned territories',
    (SELECT id FROM modules WHERE module_name = 'Northwind'),
    'nwind:view',
    'nwind:manage',
    'id',
    'label'
);

-- 11. order_details (junction)
INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES (
    'order_details',
    'order_detail',
    'Order Detail',
    'Order Details',
    'Individual line items within an order',
    (SELECT id FROM modules WHERE module_name = 'Northwind'),
    'nwind:view',
    'nwind:manage',
    'id',
    'label'
);

-- =====================================================
-- FIELDS
-- =====================================================

-- -----------------------------------------------------
-- categories fields
-- -----------------------------------------------------
-- (category_name is auto-created as the label_column)
INSERT INTO fields (table_name, field_name, title, format, field_order, input_type, width, description, default_value, searchable, ctype)
VALUES
    ('categories', 'description', 'Description', 'text', 20, 'default', 'w', 'Description of the product category', '', TRUE, '');

-- -----------------------------------------------------
-- customers fields
-- -----------------------------------------------------
-- (company_name is auto-created as the label_column)
INSERT INTO fields (table_name, field_name, title, format, field_order, input_type, width, description, default_value, searchable, unique_value, ctype)
VALUES
    ('customers', 'customer_id',    'Customer ID',    'text', 10, 'required', 'default', 'Unique short code identifying the customer', '', TRUE,  TRUE,  ''),
    ('customers', 'contact_name',   'Contact Name',   'text', 30, 'default',  'default', '',                                          '', TRUE,  FALSE, ''),
    ('customers', 'contact_title',  'Contact Title',  'text', 40, 'default',  'default', 'Job title of the primary contact',          '', FALSE, FALSE, ''),
    ('customers', 'address',        'Street Address', 'text', 50, 'default',  'w',       '',                                          '', FALSE, FALSE, ''),
    ('customers', 'city',           'City',           'text', 60, 'default',  'default', '',                                          '', TRUE,  FALSE, ''),
    ('customers', 'region',         'Region',         'text', 70, 'default',  'default', 'State or province',                         '', FALSE, FALSE, ''),
    ('customers', 'postal_code',    'Postal Code',    'text', 80, 'default',  'default', 'Postal or ZIP code',                        '', FALSE, FALSE, ''),
    ('customers', 'country',        'Country',        'text', 90, 'default',  'default', '',                                          '', TRUE,  FALSE, ''),
    ('customers', 'phone',          'Phone',          'text', 100, 'default', 'default', 'Primary phone number',                      '', FALSE, FALSE, ''),
    ('customers', 'fax',            'Fax',            'text', 110, 'default', 'default', '',                                          '', FALSE, FALSE, '');

-- -----------------------------------------------------
-- employees fields
-- -----------------------------------------------------
-- (last_name is auto-created as the label_column)
INSERT INTO fields (table_name, field_name, title, format, field_order, input_type, width, description, default_value, searchable, ctype)
VALUES
    ('employees', 'first_name',         'First Name',         'text', 20,  'required', 'default', '',                                        '', TRUE,  ''),
    ('employees', 'title',              'Title',              'text', 30,  'default',  'default', 'Job title',                               '', FALSE, ''),
    ('employees', 'title_of_courtesy',  'Title of Courtesy',  'text', 40,  'default',  'default', 'Courtesy title (Mr., Ms., Dr., etc.)',    '', FALSE, ''),
    ('employees', 'address',            'Street Address',     'text', 60,  'default',  'w',       '',                                        '', FALSE, ''),
    ('employees', 'city',               'City',               'text', 70,  'default',  'default', '',                                        '', TRUE,  ''),
    ('employees', 'region',             'Region',             'text', 80,  'default',  'default', 'State or province',                       '', FALSE, ''),
    ('employees', 'postal_code',        'Postal Code',        'text', 90,  'default',  'default', 'Postal or ZIP code',                      '', FALSE, ''),
    ('employees', 'country',            'Country',            'text', 100, 'default',  'default', '',                                        '', TRUE,  ''),
    ('employees', 'home_phone',         'Home Phone',         'text', 110, 'default',  'default', '',                                        '', FALSE, ''),
    ('employees', 'extension',          'Extension',          'text', 120, 'default',  'default', 'Phone extension',                         '', FALSE, ''),
    ('employees', 'notes',              'Notes',              'text', 130, 'default',  'w',       '',                                        '', FALSE, ''),
    ('employees', 'photo_path',         'Photo Path',         'text', 140, 'default',  'default', '',                                        '', FALSE, '');

-- birth_date: nullable (no sensible default)
INSERT INTO fields (table_name, field_name, title, format, field_order, input_type, width, description, searchable, ctype)
VALUES
    ('employees', 'birth_date', 'Birth Date', 'date', 50, 'default', 'default', '', FALSE, '');

-- hire_date: not nullable with default
INSERT INTO fields (table_name, field_name, title, format, field_order, input_type, width, description, default_value, searchable, ctype)
VALUES
    ('employees', 'hire_date', 'Hire Date', 'date', 55, 'default', 'default', '', 'CURRENT_DATE', FALSE, '');

-- reports_to: self-reference, nullable
INSERT INTO fields (table_name, field_name, title, format, field_order, input_type, width, description, reference_table, reference_delete_mode, searchable, relationship_label)
VALUES
    ('employees', 'reports_to', 'Reports To', 'reference', 150, 'default', 'default', 'Manager this employee reports to', 'employees', 'restrict', FALSE, 'manages');

-- -----------------------------------------------------
-- suppliers fields
-- -----------------------------------------------------
-- (company_name is auto-created as the label_column)
INSERT INTO fields (table_name, field_name, title, format, field_order, input_type, width, description, default_value, searchable, ctype)
VALUES
    ('suppliers', 'contact_name',  'Contact Name',  'text', 20,  'default',  'default', '',                               '', TRUE,  ''),
    ('suppliers', 'contact_title', 'Contact Title', 'text', 30,  'default',  'default', 'Job title of the primary contact', '', FALSE, ''),
    ('suppliers', 'address',       'Street Address','text', 40,  'default',  'w',       '',                               '', FALSE, ''),
    ('suppliers', 'city',          'City',          'text', 50,  'default',  'default', '',                               '', TRUE,  ''),
    ('suppliers', 'region',        'Region',        'text', 60,  'default',  'default', 'State or province',              '', FALSE, ''),
    ('suppliers', 'postal_code',   'Postal Code',   'text', 70,  'default',  'default', 'Postal or ZIP code',             '', FALSE, ''),
    ('suppliers', 'country',       'Country',       'text', 80,  'default',  'default', '',                               '', TRUE,  ''),
    ('suppliers', 'phone',         'Phone',         'text', 90,  'default',  'default', 'Primary phone number',           '', FALSE, ''),
    ('suppliers', 'fax',           'Fax',           'text', 100, 'default',  'default', '',                               '', FALSE, ''),
    ('suppliers', 'homepage',      'Homepage',      'text', 110, 'default',  'default', 'Supplier website URL',           '', FALSE, '');

-- -----------------------------------------------------
-- products fields
-- -----------------------------------------------------
-- (product_name is auto-created as the label_column)
INSERT INTO fields (table_name, field_name, title, format, field_order, input_type, width, description, default_value, searchable, ctype, cube_type)
VALUES
    ('products', 'quantity_per_unit', 'Quantity Per Unit',  'text',    40, 'default',  'default', 'Quantity and unit of measure per package',    '',      FALSE, '', 'auto'),
    ('products', 'unit_price',        'Unit Price',         'number',  50, 'default',  'default', '',                                            '0.0',   FALSE, '', 'auto'),
    ('products', 'units_in_stock',    'Units In Stock',     'int32',   60, 'default',  'default', 'Current stock quantity',                      '0',     FALSE, '', 'measure'),
    ('products', 'units_on_order',    'Units On Order',     'int32',   70, 'default',  'default', 'Quantity currently on order from supplier',   '0',     FALSE, '', 'measure'),
    ('products', 'reorder_level',     'Reorder Level',      'int32',   80, 'default',  'default', 'Minimum stock level before reordering',       '0',     FALSE, '', 'measure'),
    ('products', 'discontinued',      'Discontinued',       'boolean', 90, 'default',  'default', 'Whether the product is discontinued',         'FALSE', FALSE, '', 'auto');

INSERT INTO fields (table_name, field_name, title, format, field_order, input_type, width, description, reference_table, reference_delete_mode, searchable, relationship_label)
VALUES
    ('products', 'supplier_id', 'Supplier', 'reference', 20, 'default', 'default', 'Supplier providing this product', 'suppliers', 'restrict', FALSE, 'supplies'),
    ('products', 'category_id', 'Category', 'reference', 30, 'default', 'default', 'Category this product belongs to', 'categories', 'restrict', FALSE, 'contains');

-- -----------------------------------------------------
-- regions fields
-- -----------------------------------------------------
-- (region_description is auto-created as the label_column; no additional fields needed)

-- -----------------------------------------------------
-- shippers fields
-- -----------------------------------------------------
-- (company_name is auto-created as the label_column)
INSERT INTO fields (table_name, field_name, title, format, field_order, input_type, width, description, default_value, searchable, ctype)
VALUES
    ('shippers', 'phone', 'Phone', 'text', 20, 'default', 'default', '', '', FALSE, '');

-- -----------------------------------------------------
-- orders fields
-- -----------------------------------------------------
-- (ship_name is auto-created as the label_column)
INSERT INTO fields (table_name, field_name, title, format, field_order, input_type, width, description, default_value, searchable, ctype)
VALUES
    ('orders', 'ship_address',    'Ship Address',     'text',  50,  'default', 'w',       '',                                         '', FALSE, ''),
    ('orders', 'ship_city',       'Ship City',        'text',  60,  'default', 'default', '',                                         '', TRUE,  ''),
    ('orders', 'ship_region',     'Ship Region',      'text',  70,  'default', 'default', 'State or province for shipment',           '', FALSE, ''),
    ('orders', 'ship_postal_code','Ship Postal Code', 'text',  80,  'default', 'default', '',                                         '', FALSE, ''),
    ('orders', 'ship_country',    'Ship Country',     'text',  90,  'default', 'default', '',                                         '', TRUE,  ''),
    ('orders', 'freight',         'Freight',          'number', 100, 'default', 'default', 'Freight cost for the order',               '0.0', FALSE, '');

-- order_date and required_date: not nullable with defaults
INSERT INTO fields (table_name, field_name, title, format, field_order, input_type, width, description, default_value, searchable, ctype)
VALUES
    ('orders', 'order_date',    'Order Date',    'date', 110, 'default', 'default', '',    'CURRENT_DATE', FALSE, ''),
    ('orders', 'required_date', 'Required Date', 'date', 120, 'default', 'default', '', 'CURRENT_DATE', FALSE, '');

-- shipped_date: nullable (order may not yet be shipped)
INSERT INTO fields (table_name, field_name, title, format, field_order, input_type, width, description, searchable, ctype)
VALUES
    ('orders', 'shipped_date', 'Shipped Date', 'date', 130, 'default', 'default', '', FALSE, '');

-- FK references on orders (not parent — orders is not a junction/child table)
INSERT INTO fields (table_name, field_name, title, format, field_order, input_type, width, description, reference_table, reference_delete_mode, searchable, relationship_label)
VALUES
    ('orders', 'customer_id',  'Customer',    'reference', 10, 'default', 'default', 'Customer who placed the order',  'customers', 'restrict', FALSE, 'places'),
    ('orders', 'employee_id',  'Employee',    'reference', 20, 'default', 'default', 'Employee who handled the order', 'employees', 'restrict', FALSE, 'handles'),
    ('orders', 'ship_via',     'Shipped Via', 'reference', 30, 'default', 'default', 'Shipper used for this order',    'shippers',  'restrict', FALSE, 'ships');

-- -----------------------------------------------------
-- territories fields
-- -----------------------------------------------------
-- (territory_description is auto-created as the label_column)
INSERT INTO fields (table_name, field_name, title, format, field_order, input_type, width, description, default_value, searchable, unique_value, ctype)
VALUES
    ('territories', 'territory_id', 'Territory ID', 'text', 10, 'required', 'default', 'Unique code identifying the territory', '', TRUE, TRUE, '');

INSERT INTO fields (table_name, field_name, title, format, field_order, input_type, width, description, reference_table, reference_delete_mode, searchable, relationship_label)
VALUES
    ('territories', 'region_id', 'Region', 'reference', 30, 'default', 'default', 'Region this territory belongs to', 'regions', 'restrict', FALSE, 'contains');

-- -----------------------------------------------------
-- employee_territories fields (junction)
-- -----------------------------------------------------
INSERT INTO fields (table_name, field_name, title, format, field_order, input_type, width, description, reference_table, reference_delete_mode, searchable, relationship_label)
VALUES
    ('employee_territories', 'employee_id',  'Employee',  'parent', 10, 'required', 'default', 'Reference to the employee',  'employees',   'restrict', FALSE, 'assigned to'),
    ('employee_territories', 'territory_id', 'Territory', 'parent', 20, 'required', 'default', 'Reference to the territory', 'territories', 'restrict', FALSE, 'staffed by');

-- -----------------------------------------------------
-- order_details fields (junction)
-- -----------------------------------------------------
INSERT INTO fields (table_name, field_name, title, format, field_order, input_type, width, description, reference_table, reference_delete_mode, searchable, relationship_label)
VALUES
    ('order_details', 'order_id',   'Order',   'parent', 10, 'required', 'default', 'Reference to the order',   'orders',   'restrict', FALSE, 'contains'),
    ('order_details', 'product_id', 'Product', 'parent', 20, 'required', 'default', 'Reference to the product', 'products', 'restrict', FALSE, 'ordered in');

INSERT INTO fields (table_name, field_name, title, format, field_order, input_type, width, description, default_value, searchable, ctype, cube_type)
VALUES
    ('order_details', 'unit_price', 'Unit Price', 'number', 30, 'default', 'default', 'Actual price per unit charged on this order', '0.0', FALSE, '', 'auto'),
    ('order_details', 'quantity',   'Quantity',   'int32', 40, 'default', 'default', 'Number of units ordered',                     '0',   FALSE, '', 'measure'),
    ('order_details', 'discount',   'Discount',   'number', 50, 'default', 'default', 'Discount rate applied to this line item',     '0.0', FALSE, '', 'auto');


-- =====================================================
-- ROLE PERMISSIONS
-- =====================================================

-- Grant nwind:view and nwind:manage to role 2
INSERT INTO role_permissions (role_id, permission_id)
SELECT 2, p.id
FROM permissions p
WHERE p.permission_name IN ('nwind:view', 'nwind:manage')
  AND NOT EXISTS (
    SELECT 1 FROM role_permissions rp WHERE rp.role_id = 2 AND rp.permission_id = p.id
  );

-- Grant nwind:view and nwind:manage to role 10001 (Sales User) if it exists
INSERT INTO role_permissions (role_id, permission_id)
SELECT r.id, p.id
FROM roles r
CROSS JOIN permissions p
WHERE r.id = 10001
  AND r.role_name = 'Sales User'
  AND p.permission_name IN ('nwind:view', 'nwind:manage')
  AND NOT EXISTS (
    SELECT 1 FROM role_permissions rp WHERE rp.role_id = r.id AND rp.permission_id = p.id
  );

-- =====================================================
-- ENABLE AUDIT LOGGING FOR KEY TABLES
-- =====================================================
-- Enable DML audit logging for customers and products tables.
-- The audit_log column is added by _core/0150_audit_log.sql.
-- Other nwind tables can be enabled later as needed.

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'entities' AND column_name = 'audit_log'
    ) THEN
        UPDATE entities SET audit_log = TRUE
        WHERE table_name IN ('customers', 'products');
    END IF;
END $$;

-- =====================================================
-- EVENTS QUEUE
-- =====================================================
-- Pre-create a general-purpose "events" queue for tracking
-- entity change events from the Northwind module.

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_name = 'queues'
    ) THEN
        INSERT INTO queues (queue_name) VALUES ('events')
        ON CONFLICT DO NOTHING;
    END IF;
END $$;
`,
    "0020_load_data": `-- =====================================================
-- NORTHWIND SAMPLE DATA
-- =====================================================
-- Loads sample data for the Northwind demo application.
-- Tables are created by the entity system (0010_create.sql).
-- =====================================================

-- categories
INSERT INTO categories (id, category_name, description) VALUES
    (1, 'Beverages', 'Soft drinks, coffees, teas, beers, and ales'),
    (2, 'Condiments', 'Sweet and savory sauces, relishes, spreads, and seasonings'),
    (3, 'Confections', 'Desserts, candies, and sweet breads'),
    (4, 'Dairy Products', 'Cheeses'),
    (5, 'Grains/Cereals', 'Breads, crackers, pasta, and cereal'),
    (6, 'Meat/Poultry', 'Prepared meats'),
    (7, 'Produce', 'Dried fruit and bean curd'),
    (8, 'Seafood', 'Seaweed and fish');

-- customer_demographics: no data in original dataset

-- customers
INSERT INTO customers (customer_id, company_name, contact_name, contact_title, address, city, region, postal_code, country, phone, fax) VALUES
    ('ALFKI', 'Alfreds Futterkiste', 'Maria Anders', 'Sales Representative', 'Obere Str. 57', 'Berlin', '', '12209', 'Germany', '030-0074321', '030-0076545'),
    ('ANATR', 'Ana Trujillo Emparedados y helados', 'Ana Trujillo', 'Owner', 'Avda. de la Constitución 2222', 'México D.F.', '', '05021', 'Mexico', '(5) 555-4729', '(5) 555-3745'),
    ('ANTON', 'Antonio Moreno Taquería', 'Antonio Moreno', 'Owner', 'Mataderos  2312', 'México D.F.', '', '05023', 'Mexico', '(5) 555-3932', ''),
    ('AROUT', 'Around the Horn', 'Thomas Hardy', 'Sales Representative', '120 Hanover Sq.', 'London', '', 'WA1 1DP', 'UK', '(171) 555-7788', '(171) 555-6750'),
    ('BERGS', 'Berglunds snabbköp', 'Christina Berglund', 'Order Administrator', 'Berguvsvägen  8', 'Luleå', '', 'S-958 22', 'Sweden', '0921-12 34 65', '0921-12 34 67'),
    ('BLAUS', 'Blauer See Delikatessen', 'Hanna Moos', 'Sales Representative', 'Forsterstr. 57', 'Mannheim', '', '68306', 'Germany', '0621-08460', '0621-08924'),
    ('BLONP', 'Blondesddsl père et fils', 'Frédérique Citeaux', 'Marketing Manager', '24, place Kléber', 'Strasbourg', '', '67000', 'France', '88.60.15.31', '88.60.15.32'),
    ('BOLID', 'Bólido Comidas preparadas', 'Martín Sommer', 'Owner', 'C/ Araquil, 67', 'Madrid', '', '28023', 'Spain', '(91) 555 22 82', '(91) 555 91 99'),
    ('BONAP', 'Bon app''', 'Laurence Lebihan', 'Owner', '12, rue des Bouchers', 'Marseille', '', '13008', 'France', '91.24.45.40', '91.24.45.41'),
    ('BOTTM', 'Bottom-Dollar Markets', 'Elizabeth Lincoln', 'Accounting Manager', '23 Tsawassen Blvd.', 'Tsawassen', 'BC', 'T2F 8M4', 'Canada', '(604) 555-4729', '(604) 555-3745'),
    ('BSBEV', 'B''s Beverages', 'Victoria Ashworth', 'Sales Representative', 'Fauntleroy Circus', 'London', '', 'EC2 5NT', 'UK', '(171) 555-1212', ''),
    ('CACTU', 'Cactus Comidas para llevar', 'Patricio Simpson', 'Sales Agent', 'Cerrito 333', 'Buenos Aires', '', '1010', 'Argentina', '(1) 135-5555', '(1) 135-4892'),
    ('CENTC', 'Centro comercial Moctezuma', 'Francisco Chang', 'Marketing Manager', 'Sierras de Granada 9993', 'México D.F.', '', '05022', 'Mexico', '(5) 555-3392', '(5) 555-7293'),
    ('CHOPS', 'Chop-suey Chinese', 'Yang Wang', 'Owner', 'Hauptstr. 29', 'Bern', '', '3012', 'Switzerland', '0452-076545', ''),
    ('COMMI', 'Comércio Mineiro', 'Pedro Afonso', 'Sales Associate', 'Av. dos Lusíadas, 23', 'Sao Paulo', 'SP', '05432-043', 'Brazil', '(11) 555-7647', ''),
    ('CONSH', 'Consolidated Holdings', 'Elizabeth Brown', 'Sales Representative', 'Berkeley Gardens 12  Brewery', 'London', '', 'WX1 6LT', 'UK', '(171) 555-2282', '(171) 555-9199'),
    ('DRACD', 'Drachenblut Delikatessen', 'Sven Ottlieb', 'Order Administrator', 'Walserweg 21', 'Aachen', '', '52066', 'Germany', '0241-039123', '0241-059428'),
    ('DUMON', 'Du monde entier', 'Janine Labrune', 'Owner', '67, rue des Cinquante Otages', 'Nantes', '', '44000', 'France', '40.67.88.88', '40.67.89.89'),
    ('EASTC', 'Eastern Connection', 'Ann Devon', 'Sales Agent', '35 King George', 'London', '', 'WX3 6FW', 'UK', '(171) 555-0297', '(171) 555-3373'),
    ('ERNSH', 'Ernst Handel', 'Roland Mendel', 'Sales Manager', 'Kirchgasse 6', 'Graz', '', '8010', 'Austria', '7675-3425', '7675-3426'),
    ('FAMIA', 'Familia Arquibaldo', 'Aria Cruz', 'Marketing Assistant', 'Rua Orós, 92', 'Sao Paulo', 'SP', '05442-030', 'Brazil', '(11) 555-9857', ''),
    ('FISSA', 'FISSA Fabrica Inter. Salchichas S.A.', 'Diego Roel', 'Accounting Manager', 'C/ Moralzarzal, 86', 'Madrid', '', '28034', 'Spain', '(91) 555 94 44', '(91) 555 55 93'),
    ('FOLIG', 'Folies gourmandes', 'Martine Rancé', 'Assistant Sales Agent', '184, chaussée de Tournai', 'Lille', '', '59000', 'France', '20.16.10.16', '20.16.10.17'),
    ('FOLKO', 'Folk och fä HB', 'Maria Larsson', 'Owner', 'Åkergatan 24', 'Bräcke', '', 'S-844 67', 'Sweden', '0695-34 67 21', ''),
    ('FRANK', 'Frankenversand', 'Peter Franken', 'Marketing Manager', 'Berliner Platz 43', 'München', '', '80805', 'Germany', '089-0877310', '089-0877451'),
    ('FRANR', 'France restauration', 'Carine Schmitt', 'Marketing Manager', '54, rue Royale', 'Nantes', '', '44000', 'France', '40.32.21.21', '40.32.21.20'),
    ('FRANS', 'Franchi S.p.A.', 'Paolo Accorti', 'Sales Representative', 'Via Monte Bianco 34', 'Torino', '', '10100', 'Italy', '011-4988260', '011-4988261'),
    ('FURIB', 'Furia Bacalhau e Frutos do Mar', 'Lino Rodriguez', 'Sales Manager', 'Jardim das rosas n. 32', 'Lisboa', '', '1675', 'Portugal', '(1) 354-2534', '(1) 354-2535'),
    ('GALED', 'Galería del gastrónomo', 'Eduardo Saavedra', 'Marketing Manager', 'Rambla de Cataluña, 23', 'Barcelona', '', '08022', 'Spain', '(93) 203 4560', '(93) 203 4561'),
    ('GODOS', 'Godos Cocina Típica', 'José Pedro Freyre', 'Sales Manager', 'C/ Romero, 33', 'Sevilla', '', '41101', 'Spain', '(95) 555 82 82', ''),
    ('GOURL', 'Gourmet Lanchonetes', 'André Fonseca', 'Sales Associate', 'Av. Brasil, 442', 'Campinas', 'SP', '04876-786', 'Brazil', '(11) 555-9482', ''),
    ('GREAL', 'Great Lakes Food Market', 'Howard Snyder', 'Marketing Manager', '2732 Baker Blvd.', 'Eugene', 'OR', '97403', 'USA', '(503) 555-7555', ''),
    ('GROSR', 'GROSELLA-Restaurante', 'Manuel Pereira', 'Owner', '5ª Ave. Los Palos Grandes', 'Caracas', 'DF', '1081', 'Venezuela', '(2) 283-2951', '(2) 283-3397'),
    ('HANAR', 'Hanari Carnes', 'Mario Pontes', 'Accounting Manager', 'Rua do Paço, 67', 'Rio de Janeiro', 'RJ', '05454-876', 'Brazil', '(21) 555-0091', '(21) 555-8765'),
    ('HILAA', 'HILARION-Abastos', 'Carlos Hernández', 'Sales Representative', 'Carrera 22 con Ave. Carlos Soublette #8-35', 'San Cristóbal', 'Táchira', '5022', 'Venezuela', '(5) 555-1340', '(5) 555-1948'),
    ('HUNGC', 'Hungry Coyote Import Store', 'Yoshi Latimer', 'Sales Representative', 'City Center Plaza 516 Main St.', 'Elgin', 'OR', '97827', 'USA', '(503) 555-6874', '(503) 555-2376'),
    ('HUNGO', 'Hungry Owl All-Night Grocers', 'Patricia McKenna', 'Sales Associate', '8 Johnstown Road', 'Cork', 'Co. Cork', '', 'Ireland', '2967 542', '2967 3333'),
    ('ISLAT', 'Island Trading', 'Helen Bennett', 'Marketing Manager', 'Garden House Crowther Way', 'Cowes', 'Isle of Wight', 'PO31 7PJ', 'UK', '(198) 555-8888', ''),
    ('KOENE', 'Königlich Essen', 'Philip Cramer', 'Sales Associate', 'Maubelstr. 90', 'Brandenburg', '', '14776', 'Germany', '0555-09876', ''),
    ('LACOR', 'La corne d''abondance', 'Daniel Tonini', 'Sales Representative', '67, avenue de l''Europe', 'Versailles', '', '78000', 'France', '30.59.84.10', '30.59.85.11'),
    ('LAMAI', 'La maison d''Asie', 'Annette Roulet', 'Sales Manager', '1 rue Alsace-Lorraine', 'Toulouse', '', '31000', 'France', '61.77.61.10', '61.77.61.11'),
    ('LAUGB', 'Laughing Bacchus Wine Cellars', 'Yoshi Tannamuri', 'Marketing Assistant', '1900 Oak St.', 'Vancouver', 'BC', 'V3F 2K1', 'Canada', '(604) 555-3392', '(604) 555-7293'),
    ('LAZYK', 'Lazy K Kountry Store', 'John Steel', 'Marketing Manager', '12 Orchestra Terrace', 'Walla Walla', 'WA', '99362', 'USA', '(509) 555-7969', '(509) 555-6221'),
    ('LEHMS', 'Lehmanns Marktstand', 'Renate Messner', 'Sales Representative', 'Magazinweg 7', 'Frankfurt a.M.', '', '60528', 'Germany', '069-0245984', '069-0245874'),
    ('LETSS', 'Let''s Stop N Shop', 'Jaime Yorres', 'Owner', '87 Polk St. Suite 5', 'San Francisco', 'CA', '94117', 'USA', '(415) 555-5938', ''),
    ('LILAS', 'LILA-Supermercado', 'Carlos González', 'Accounting Manager', 'Carrera 52 con Ave. Bolívar #65-98 Llano Largo', 'Barquisimeto', 'Lara', '3508', 'Venezuela', '(9) 331-6954', '(9) 331-7256'),
    ('LINOD', 'LINO-Delicateses', 'Felipe Izquierdo', 'Owner', 'Ave. 5 de Mayo Porlamar', 'I. de Margarita', 'Nueva Esparta', '4980', 'Venezuela', '(8) 34-56-12', '(8) 34-93-93'),
    ('LONEP', 'Lonesome Pine Restaurant', 'Fran Wilson', 'Sales Manager', '89 Chiaroscuro Rd.', 'Portland', 'OR', '97219', 'USA', '(503) 555-9573', '(503) 555-9646'),
    ('MAGAA', 'Magazzini Alimentari Riuniti', 'Giovanni Rovelli', 'Marketing Manager', 'Via Ludovico il Moro 22', 'Bergamo', '', '24100', 'Italy', '035-640230', '035-640231'),
    ('MAISD', 'Maison Dewey', 'Catherine Dewey', 'Sales Agent', 'Rue Joseph-Bens 532', 'Bruxelles', '', 'B-1180', 'Belgium', '(02) 201 24 67', '(02) 201 24 68'),
    ('MEREP', 'Mère Paillarde', 'Jean Fresnière', 'Marketing Assistant', '43 rue St. Laurent', 'Montréal', 'Québec', 'H1J 1C3', 'Canada', '(514) 555-8054', '(514) 555-8055'),
    ('MORGK', 'Morgenstern Gesundkost', 'Alexander Feuer', 'Marketing Assistant', 'Heerstr. 22', 'Leipzig', '', '04179', 'Germany', '0342-023176', ''),
    ('NORTS', 'North/South', 'Simon Crowther', 'Sales Associate', 'South House 300 Queensbridge', 'London', '', 'SW7 1RZ', 'UK', '(171) 555-7733', '(171) 555-2530'),
    ('OCEAN', 'Océano Atlántico Ltda.', 'Yvonne Moncada', 'Sales Agent', 'Ing. Gustavo Moncada 8585 Piso 20-A', 'Buenos Aires', '', '1010', 'Argentina', '(1) 135-5333', '(1) 135-5535'),
    ('OLDWO', 'Old World Delicatessen', 'Rene Phillips', 'Sales Representative', '2743 Bering St.', 'Anchorage', 'AK', '99508', 'USA', '(907) 555-7584', '(907) 555-2880'),
    ('OTTIK', 'Ottilies Käseladen', 'Henriette Pfalzheim', 'Owner', 'Mehrheimerstr. 369', 'Köln', '', '50739', 'Germany', '0221-0644327', '0221-0765721'),
    ('PARIS', 'Paris spécialités', 'Marie Bertrand', 'Owner', '265, boulevard Charonne', 'Paris', '', '75012', 'France', '(1) 42.34.22.66', '(1) 42.34.22.77'),
    ('PERIC', 'Pericles Comidas clásicas', 'Guillermo Fernández', 'Sales Representative', 'Calle Dr. Jorge Cash 321', 'México D.F.', '', '05033', 'Mexico', '(5) 552-3745', '(5) 545-3745'),
    ('PICCO', 'Piccolo und mehr', 'Georg Pipps', 'Sales Manager', 'Geislweg 14', 'Salzburg', '', '5020', 'Austria', '6562-9722', '6562-9723'),
    ('PRINI', 'Princesa Isabel Vinhos', 'Isabel de Castro', 'Sales Representative', 'Estrada da saúde n. 58', 'Lisboa', '', '1756', 'Portugal', '(1) 356-5634', ''),
    ('QUEDE', 'Que Delícia', 'Bernardo Batista', 'Accounting Manager', 'Rua da Panificadora, 12', 'Rio de Janeiro', 'RJ', '02389-673', 'Brazil', '(21) 555-4252', '(21) 555-4545'),
    ('QUEEN', 'Queen Cozinha', 'Lúcia Carvalho', 'Marketing Assistant', 'Alameda dos Canàrios, 891', 'Sao Paulo', 'SP', '05487-020', 'Brazil', '(11) 555-1189', ''),
    ('QUICK', 'QUICK-Stop', 'Horst Kloss', 'Accounting Manager', 'Taucherstraße 10', 'Cunewalde', '', '01307', 'Germany', '0372-035188', ''),
    ('RANCH', 'Rancho grande', 'Sergio Gutiérrez', 'Sales Representative', 'Av. del Libertador 900', 'Buenos Aires', '', '1010', 'Argentina', '(1) 123-5555', '(1) 123-5556'),
    ('RATTC', 'Rattlesnake Canyon Grocery', 'Paula Wilson', 'Assistant Sales Representative', '2817 Milton Dr.', 'Albuquerque', 'NM', '87110', 'USA', '(505) 555-5939', '(505) 555-3620'),
    ('REGGC', 'Reggiani Caseifici', 'Maurizio Moroni', 'Sales Associate', 'Strada Provinciale 124', 'Reggio Emilia', '', '42100', 'Italy', '0522-556721', '0522-556722'),
    ('RICAR', 'Ricardo Adocicados', 'Janete Limeira', 'Assistant Sales Agent', 'Av. Copacabana, 267', 'Rio de Janeiro', 'RJ', '02389-890', 'Brazil', '(21) 555-3412', ''),
    ('RICSU', 'Richter Supermarkt', 'Michael Holz', 'Sales Manager', 'Grenzacherweg 237', 'Genève', '', '1203', 'Switzerland', '0897-034214', ''),
    ('ROMEY', 'Romero y tomillo', 'Alejandra Camino', 'Accounting Manager', 'Gran Vía, 1', 'Madrid', '', '28001', 'Spain', '(91) 745 6200', '(91) 745 6210'),
    ('SANTG', 'Santé Gourmet', 'Jonas Bergulfsen', 'Owner', 'Erling Skakkes gate 78', 'Stavern', '', '4110', 'Norway', '07-98 92 35', '07-98 92 47'),
    ('SAVEA', 'Save-a-lot Markets', 'Jose Pavarotti', 'Sales Representative', '187 Suffolk Ln.', 'Boise', 'ID', '83720', 'USA', '(208) 555-8097', ''),
    ('SEVES', 'Seven Seas Imports', 'Hari Kumar', 'Sales Manager', '90 Wadhurst Rd.', 'London', '', 'OX15 4NB', 'UK', '(171) 555-1717', '(171) 555-5646'),
    ('SIMOB', 'Simons bistro', 'Jytte Petersen', 'Owner', 'Vinbæltet 34', 'Kobenhavn', '', '1734', 'Denmark', '31 12 34 56', '31 13 35 57'),
    ('SPECD', 'Spécialités du monde', 'Dominique Perrier', 'Marketing Manager', '25, rue Lauriston', 'Paris', '', '75016', 'France', '(1) 47.55.60.10', '(1) 47.55.60.20'),
    ('SPLIR', 'Split Rail Beer & Ale', 'Art Braunschweiger', 'Sales Manager', 'P.O. Box 555', 'Lander', 'WY', '82520', 'USA', '(307) 555-4680', '(307) 555-6525'),
    ('SUPRD', 'Suprêmes délices', 'Pascale Cartrain', 'Accounting Manager', 'Boulevard Tirou, 255', 'Charleroi', '', 'B-6000', 'Belgium', '(071) 23 67 22 20', '(071) 23 67 22 21'),
    ('THEBI', 'The Big Cheese', 'Liz Nixon', 'Marketing Manager', '89 Jefferson Way Suite 2', 'Portland', 'OR', '97201', 'USA', '(503) 555-3612', ''),
    ('THECR', 'The Cracker Box', 'Liu Wong', 'Marketing Assistant', '55 Grizzly Peak Rd.', 'Butte', 'MT', '59801', 'USA', '(406) 555-5834', '(406) 555-8083'),
    ('TOMSP', 'Toms Spezialitäten', 'Karin Josephs', 'Marketing Manager', 'Luisenstr. 48', 'Münster', '', '44087', 'Germany', '0251-031259', '0251-035695'),
    ('TORTU', 'Tortuga Restaurante', 'Miguel Angel Paolino', 'Owner', 'Avda. Azteca 123', 'México D.F.', '', '05033', 'Mexico', '(5) 555-2933', ''),
    ('TRADH', 'Tradição Hipermercados', 'Anabela Domingues', 'Sales Representative', 'Av. Inês de Castro, 414', 'Sao Paulo', 'SP', '05634-030', 'Brazil', '(11) 555-2167', '(11) 555-2168'),
    ('TRAIH', 'Trail''s Head Gourmet Provisioners', 'Helvetius Nagy', 'Sales Associate', '722 DaVinci Blvd.', 'Kirkland', 'WA', '98034', 'USA', '(206) 555-8257', '(206) 555-2174'),
    ('VAFFE', 'Vaffeljernet', 'Palle Ibsen', 'Sales Manager', 'Smagsloget 45', 'Århus', '', '8200', 'Denmark', '86 21 32 43', '86 22 33 44'),
    ('VICTE', 'Victuailles en stock', 'Mary Saveley', 'Sales Agent', '2, rue du Commerce', 'Lyon', '', '69004', 'France', '78.32.54.86', '78.32.54.87'),
    ('VINET', 'Vins et alcools Chevalier', 'Paul Henriot', 'Accounting Manager', '59 rue de l''Abbaye', 'Reims', '', '51100', 'France', '26.47.15.10', '26.47.15.11'),
    ('WANDK', 'Die Wandernde Kuh', 'Rita Müller', 'Sales Representative', 'Adenauerallee 900', 'Stuttgart', '', '70563', 'Germany', '0711-020361', '0711-035428'),
    ('WARTH', 'Wartian Herkku', 'Pirkko Koskitalo', 'Accounting Manager', 'Torikatu 38', 'Oulu', '', '90110', 'Finland', '981-443655', '981-443655'),
    ('WELLI', 'Wellington Importadora', 'Paula Parente', 'Sales Manager', 'Rua do Mercado, 12', 'Resende', 'SP', '08737-363', 'Brazil', '(14) 555-8122', ''),
    ('WHITC', 'White Clover Markets', 'Karl Jablonski', 'Owner', '305 - 14th Ave. S. Suite 3B', 'Seattle', 'WA', '98128', 'USA', '(206) 555-4112', '(206) 555-4115'),
    ('WILMK', 'Wilman Kala', 'Matti Karttunen', 'Owner/Marketing Assistant', 'Keskuskatu 45', 'Helsinki', '', '21240', 'Finland', '90-224 8858', '90-224 8858'),
    ('WOLZA', 'Wolski  Zajazd', 'Zbyszek Piestrzeniewicz', 'Owner', 'ul. Filtrowa 68', 'Warszawa', '', '01-012', 'Poland', '(26) 642-7012', '(26) 642-7012');

-- customer_customer_demo: no data in original dataset

-- employees (insert without reports_to to avoid FK ordering issues)
INSERT INTO employees (id, last_name, first_name, title, title_of_courtesy, birth_date, hire_date, address, city, region, postal_code, country, home_phone, extension, notes, photo_path) VALUES
    (2, 'Fuller', 'Andrew', 'Vice President, Sales', 'Dr.', '1952-02-19', '1992-08-14', '908 W. Capital Way', 'Tacoma', 'WA', '98401', 'USA', '(206) 555-9482', '3457', 'Andrew received his BTS commercial in 1974 and a Ph.D. in international marketing from the University of Dallas in 1981.  He is fluent in French and Italian and reads German.  He joined the company as a sales representative, was promoted to sales manager in January 1992 and to vice president of sales in March 1993.  Andrew is a member of the Sales Management Roundtable, the Seattle Chamber of Commerce, and the Pacific Rim Importers Association.', 'http://accweb/emmployees/fuller.bmp'),
    (3, 'Leverling', 'Janet', 'Sales Representative', 'Ms.', '1963-08-30', '1992-04-01', '722 Moss Bay Blvd.', 'Kirkland', 'WA', '98033', 'USA', '(206) 555-3412', '3355', 'Janet has a BS degree in chemistry from Boston College (1984).  She has also completed a certificate program in food retailing management.  Janet was hired as a sales associate in 1991 and promoted to sales representative in February 1992.', 'http://accweb/emmployees/leverling.bmp'),
    (4, 'Peacock', 'Margaret', 'Sales Representative', 'Mrs.', '1937-09-19', '1993-05-03', '4110 Old Redmond Rd.', 'Redmond', 'WA', '98052', 'USA', '(206) 555-8122', '5176', 'Margaret holds a BA in English literature from Concordia College (1958) and an MA from the American Institute of Culinary Arts (1966).  She was assigned to the London office temporarily from July through November 1992.', 'http://accweb/emmployees/peacock.bmp'),
    (5, 'Buchanan', 'Steven', 'Sales Manager', 'Mr.', '1955-03-04', '1993-10-17', '14 Garrett Hill', 'London', '', 'SW1 8JR', 'UK', '(71) 555-4848', '3453', 'Steven Buchanan graduated from St. Andrews University, Scotland, with a BSC degree in 1976.  Upon joining the company as a sales representative in 1992, he spent 6 months in an orientation program at the Seattle office and then returned to his permanent post in London.  He was promoted to sales manager in March 1993.  Mr. Buchanan has completed the courses Successful Telemarketing and International Sales Management.  He is fluent in French.', 'http://accweb/emmployees/buchanan.bmp'),
    (6, 'Suyama', 'Michael', 'Sales Representative', 'Mr.', '1963-07-02', '1993-10-17', 'Coventry House\\nMiner Rd.', 'London', '', 'EC2 7JR', 'UK', '(71) 555-7773', '428', 'Michael is a graduate of Sussex University (MA, economics, 1983) and the University of California at Los Angeles (MBA, marketing, 1986).  He has also taken the courses Multi-Cultural Selling and Time Management for the Sales Professional.  He is fluent in Japanese and can read and write French, Portuguese, and Spanish.', 'http://accweb/emmployees/davolio.bmp'),
    (7, 'King', 'Robert', 'Sales Representative', 'Mr.', '1960-05-29', '1994-01-02', 'Edgeham Hollow\\nWinchester Way', 'London', '', 'RG1 9SP', 'UK', '(71) 555-5598', '465', 'Robert King served in the Peace Corps and traveled extensively before completing his degree in English at the University of Michigan in 1992, the year he joined the company.  After completing a course entitled Selling in Europe, he was transferred to the London office in March 1993.', 'http://accweb/emmployees/davolio.bmp'),
    (8, 'Callahan', 'Laura', 'Inside Sales Coordinator', 'Ms.', '1958-01-09', '1994-03-05', '4726 - 11th Ave. N.E.', 'Seattle', 'WA', '98105', 'USA', '(206) 555-1189', '2344', 'Laura received a BA in psychology from the University of Washington.  She has also completed a course in business French.  She reads and writes French.', 'http://accweb/emmployees/davolio.bmp'),
    (9, 'Dodsworth', 'Anne', 'Sales Representative', 'Ms.', '1966-01-27', '1994-11-15', '7 Houndstooth Rd.', 'London', '', 'WG2 7LT', 'UK', '(71) 555-4444', '452', 'Anne has a BA degree in English from St. Lawrence College.  She is fluent in French and German.', 'http://accweb/emmployees/davolio.bmp'),
    (1, 'Davolio', 'Nancy', 'Sales Representative', 'Ms.', '1948-12-08', '1992-05-01', '507 - 20th Ave. E.\\nApt. 2A', 'Seattle', 'WA', '98122', 'USA', '(206) 555-9857', '5467', 'Education includes a BA in psychology from Colorado State University in 1970.  She also completed The Art of the Cold Call.  Nancy is a member of Toastmasters International.', 'http://accweb/emmployees/davolio.bmp');

-- Set reports_to after all employees are inserted
UPDATE employees SET reports_to = 2 WHERE id = 3;
UPDATE employees SET reports_to = 2 WHERE id = 4;
UPDATE employees SET reports_to = 2 WHERE id = 5;
UPDATE employees SET reports_to = 5 WHERE id = 6;
UPDATE employees SET reports_to = 5 WHERE id = 7;
UPDATE employees SET reports_to = 2 WHERE id = 8;
UPDATE employees SET reports_to = 5 WHERE id = 9;
UPDATE employees SET reports_to = 2 WHERE id = 1;

-- regions
INSERT INTO regions (id, region_description) VALUES
    (1, 'Eastern'),
    (2, 'Western'),
    (3, 'Northern'),
    (4, 'Southern');

-- territories (auto-increment id; territory_id kept as text column)
INSERT INTO territories (territory_id, territory_description, region_id) VALUES
    ('01581', 'Westboro', 1),
    ('01730', 'Bedford', 1),
    ('01833', 'Georgetow', 1),
    ('02116', 'Boston', 1),
    ('02139', 'Cambridge', 1),
    ('02184', 'Braintree', 1),
    ('02903', 'Providence', 1),
    ('03049', 'Hollis', 3),
    ('03801', 'Portsmouth', 3),
    ('06897', 'Wilton', 1),
    ('07960', 'Morristown', 1),
    ('08837', 'Edison', 1),
    ('10019', 'New York', 1),
    ('10038', 'New York', 1),
    ('11747', 'Mellvile', 1),
    ('14450', 'Fairport', 1),
    ('19428', 'Philadelphia', 3),
    ('19713', 'Neward', 1),
    ('20852', 'Rockville', 1),
    ('27403', 'Greensboro', 1),
    ('27511', 'Cary', 1),
    ('29202', 'Columbia', 4),
    ('30346', 'Atlanta', 4),
    ('31406', 'Savannah', 4),
    ('32859', 'Orlando', 4),
    ('33607', 'Tampa', 4),
    ('40222', 'Louisville', 1),
    ('44122', 'Beachwood', 3),
    ('45839', 'Findlay', 3),
    ('48075', 'Southfield', 3),
    ('48084', 'Troy', 3),
    ('48304', 'Bloomfield Hills', 3),
    ('53404', 'Racine', 3),
    ('55113', 'Roseville', 3),
    ('55439', 'Minneapolis', 3),
    ('60179', 'Hoffman Estates', 2),
    ('60601', 'Chicago', 2),
    ('72716', 'Bentonville', 4),
    ('75234', 'Dallas', 4),
    ('78759', 'Austin', 4),
    ('80202', 'Denver', 2),
    ('80909', 'Colorado Springs', 2),
    ('85014', 'Phoenix', 2),
    ('85251', 'Scottsdale', 2),
    ('90405', 'Santa Monica', 2),
    ('94025', 'Menlo Park', 2),
    ('94105', 'San Francisco', 2),
    ('95008', 'Campbell', 2),
    ('95054', 'Santa Clara', 2),
    ('95060', 'Santa Cruz', 2),
    ('98004', 'Bellevue', 2),
    ('98052', 'Redmond', 2),
    ('98104', 'Seattle', 2);

-- employee_territories: join territory text code to integer FK
WITH territory_map AS (
    SELECT territory_id AS code, id FROM territories
)
INSERT INTO employee_territories (employee_id, territory_id)
SELECT d.emp_id, t.id
FROM (VALUES
    (1, '06897'),
    (1, '19713'),
    (2, '01581'),
    (2, '01730'),
    (2, '01833'),
    (2, '02116'),
    (2, '02139'),
    (2, '02184'),
    (2, '40222'),
    (3, '30346'),
    (3, '31406'),
    (3, '32859'),
    (3, '33607'),
    (4, '20852'),
    (4, '27403'),
    (4, '27511'),
    (5, '02903'),
    (5, '07960'),
    (5, '08837'),
    (5, '10019'),
    (5, '10038'),
    (5, '11747'),
    (5, '14450'),
    (6, '85014'),
    (6, '85251'),
    (6, '98004'),
    (6, '98052'),
    (6, '98104'),
    (7, '60179'),
    (7, '60601'),
    (7, '80202'),
    (7, '80909'),
    (7, '90405'),
    (7, '94025'),
    (7, '94105'),
    (7, '95008'),
    (7, '95054'),
    (7, '95060'),
    (8, '19428'),
    (8, '44122'),
    (8, '45839'),
    (8, '53404'),
    (9, '03049'),
    (9, '03801'),
    (9, '48075'),
    (9, '48084'),
    (9, '48304'),
    (9, '55113'),
    (9, '55439')
) AS d(emp_id, terr_code)
JOIN territory_map t ON t.code = d.terr_code;

-- shippers
INSERT INTO shippers (id, company_name, phone) VALUES
    (1, 'Speedy Express', '(503) 555-9831'),
    (2, 'United Package', '(503) 555-3199'),
    (3, 'Federal Shipping', '(503) 555-9931'),
    (4, 'Alliance Shippers', '1-800-222-0451'),
    (5, 'UPS', '1-800-782-7892'),
    (6, 'DHL', '1-800-225-5345');

-- orders: join customer text code to integer id
WITH customer_map AS (
    SELECT customer_id AS code, id FROM customers
)
INSERT INTO orders (id, customer_id, employee_id, order_date, required_date, shipped_date, ship_via, freight, ship_name, ship_address, ship_city, ship_region, ship_postal_code, ship_country)
SELECT d.order_id, c.id, d.employee_id, d.order_date, d.required_date, d.shipped_date, d.ship_via, d.freight, d.ship_name, d.ship_address, d.ship_city, d.ship_region, d.ship_postal_code, d.ship_country
FROM (VALUES
    (10248::integer, 'VINET'::text, 5::integer, '2024-07-04'::date, '2024-08-01'::date, '2024-07-16'::date, 3::integer, 32.38::real, 'Vins et alcools Chevalier', '59 rue de l''Abbaye', 'Reims', '', '51100', 'France'),
    (10249::integer, 'TOMSP'::text, 6::integer, '2024-07-05'::date, '2024-08-16'::date, '2024-07-10'::date, 1::integer, 11.61::real, 'Toms Spezialitäten', 'Luisenstr. 48', 'Münster', '', '44087', 'Germany'),
    (10250::integer, 'HANAR'::text, 4::integer, '2024-07-08'::date, '2024-08-05'::date, '2024-07-12'::date, 2::integer, 65.83::real, 'Hanari Carnes', 'Rua do Paço, 67', 'Rio de Janeiro', 'RJ', '05454-876', 'Brazil'),
    (10251::integer, 'VICTE'::text, 3::integer, '2024-07-08'::date, '2024-08-05'::date, '2024-07-15'::date, 1::integer, 41.34::real, 'Victuailles en stock', '2, rue du Commerce', 'Lyon', '', '69004', 'France'),
    (10252::integer, 'SUPRD'::text, 4::integer, '2024-07-09'::date, '2024-08-06'::date, '2024-07-11'::date, 2::integer, 51.3::real, 'Suprêmes délices', 'Boulevard Tirou, 255', 'Charleroi', '', 'B-6000', 'Belgium'),
    (10253::integer, 'HANAR'::text, 3::integer, '2024-07-10'::date, '2024-07-24'::date, '2024-07-16'::date, 2::integer, 58.17::real, 'Hanari Carnes', 'Rua do Paço, 67', 'Rio de Janeiro', 'RJ', '05454-876', 'Brazil'),
    (10254::integer, 'CHOPS'::text, 5::integer, '2024-07-11'::date, '2024-08-08'::date, '2024-07-23'::date, 2::integer, 22.98::real, 'Chop-suey Chinese', 'Hauptstr. 31', 'Bern', '', '3012', 'Switzerland'),
    (10255::integer, 'RICSU'::text, 9::integer, '2024-07-12'::date, '2024-08-09'::date, '2024-07-15'::date, 3::integer, 148.33::real, 'Richter Supermarkt', 'Starenweg 5', 'Genève', '', '1204', 'Switzerland'),
    (10256::integer, 'WELLI'::text, 3::integer, '2024-07-15'::date, '2024-08-12'::date, '2024-07-17'::date, 2::integer, 13.97::real, 'Wellington Importadora', 'Rua do Mercado, 12', 'Resende', 'SP', '08737-363', 'Brazil'),
    (10257::integer, 'HILAA'::text, 4::integer, '2024-07-16'::date, '2024-08-13'::date, '2024-07-22'::date, 3::integer, 81.91::real, 'HILARION-Abastos', 'Carrera 22 con Ave. Carlos Soublette #8-35', 'San Cristóbal', 'Táchira', '5022', 'Venezuela'),
    (10258::integer, 'ERNSH'::text, 1::integer, '2024-07-17'::date, '2024-08-14'::date, '2024-07-23'::date, 1::integer, 140.51::real, 'Ernst Handel', 'Kirchgasse 6', 'Graz', '', '8010', 'Austria'),
    (10259::integer, 'CENTC'::text, 4::integer, '2024-07-18'::date, '2024-08-15'::date, '2024-07-25'::date, 3::integer, 3.25::real, 'Centro comercial Moctezuma', 'Sierras de Granada 9993', 'México D.F.', '', '05022', 'Mexico'),
    (10260::integer, 'OTTIK'::text, 4::integer, '2024-07-19'::date, '2024-08-16'::date, '2024-07-29'::date, 1::integer, 55.09::real, 'Ottilies Käseladen', 'Mehrheimerstr. 369', 'Köln', '', '50739', 'Germany'),
    (10261::integer, 'QUEDE'::text, 4::integer, '2024-07-19'::date, '2024-08-16'::date, '2024-07-30'::date, 2::integer, 3.05::real, 'Que Delícia', 'Rua da Panificadora, 12', 'Rio de Janeiro', 'RJ', '02389-673', 'Brazil'),
    (10262::integer, 'RATTC'::text, 8::integer, '2024-07-22'::date, '2024-08-19'::date, '2024-07-25'::date, 3::integer, 48.29::real, 'Rattlesnake Canyon Grocery', '2817 Milton Dr.', 'Albuquerque', 'NM', '87110', 'USA'),
    (10263::integer, 'ERNSH'::text, 9::integer, '2024-07-23'::date, '2024-08-20'::date, '2024-07-31'::date, 3::integer, 146.06::real, 'Ernst Handel', 'Kirchgasse 6', 'Graz', '', '8010', 'Austria'),
    (10264::integer, 'FOLKO'::text, 6::integer, '2024-07-24'::date, '2024-08-21'::date, '2024-08-23'::date, 3::integer, 3.67::real, 'Folk och fä HB', 'Åkergatan 24', 'Bräcke', '', 'S-844 67', 'Sweden'),
    (10265::integer, 'BLONP'::text, 2::integer, '2024-07-25'::date, '2024-08-22'::date, '2024-08-12'::date, 1::integer, 55.28::real, 'Blondel père et fils', '24, place Kléber', 'Strasbourg', '', '67000', 'France'),
    (10266::integer, 'WARTH'::text, 3::integer, '2024-07-26'::date, '2024-09-06'::date, '2024-07-31'::date, 3::integer, 25.73::real, 'Wartian Herkku', 'Torikatu 38', 'Oulu', '', '90110', 'Finland'),
    (10267::integer, 'FRANK'::text, 4::integer, '2024-07-29'::date, '2024-08-26'::date, '2024-08-06'::date, 1::integer, 208.58::real, 'Frankenversand', 'Berliner Platz 43', 'München', '', '80805', 'Germany'),
    (10268::integer, 'GROSR'::text, 8::integer, '2024-07-30'::date, '2024-08-27'::date, '2024-08-02'::date, 3::integer, 66.29::real, 'GROSELLA-Restaurante', '5ª Ave. Los Palos Grandes', 'Caracas', 'DF', '1081', 'Venezuela'),
    (10269::integer, 'WHITC'::text, 5::integer, '2024-07-31'::date, '2024-08-14'::date, '2024-08-09'::date, 1::integer, 4.56::real, 'White Clover Markets', '1029 - 12th Ave. S.', 'Seattle', 'WA', '98124', 'USA'),
    (10270::integer, 'WARTH'::text, 1::integer, '2024-08-01'::date, '2024-08-29'::date, '2024-08-02'::date, 1::integer, 136.54::real, 'Wartian Herkku', 'Torikatu 38', 'Oulu', '', '90110', 'Finland'),
    (10271::integer, 'SPLIR'::text, 6::integer, '2024-08-01'::date, '2024-08-29'::date, '2024-08-30'::date, 2::integer, 4.54::real, 'Split Rail Beer & Ale', 'P.O. Box 555', 'Lander', 'WY', '82520', 'USA'),
    (10272::integer, 'RATTC'::text, 6::integer, '2024-08-02'::date, '2024-08-30'::date, '2024-08-06'::date, 2::integer, 98.03::real, 'Rattlesnake Canyon Grocery', '2817 Milton Dr.', 'Albuquerque', 'NM', '87110', 'USA'),
    (10273::integer, 'QUICK'::text, 3::integer, '2024-08-05'::date, '2024-09-02'::date, '2024-08-12'::date, 3::integer, 76.07::real, 'QUICK-Stop', 'Taucherstraße 10', 'Cunewalde', '', '01307', 'Germany'),
    (10274::integer, 'VINET'::text, 6::integer, '2024-08-06'::date, '2024-09-03'::date, '2024-08-16'::date, 1::integer, 6.01::real, 'Vins et alcools Chevalier', '59 rue de l''Abbaye', 'Reims', '', '51100', 'France'),
    (10275::integer, 'MAGAA'::text, 1::integer, '2024-08-07'::date, '2024-09-04'::date, '2024-08-09'::date, 1::integer, 26.93::real, 'Magazzini Alimentari Riuniti', 'Via Ludovico il Moro 22', 'Bergamo', '', '24100', 'Italy'),
    (10276::integer, 'TORTU'::text, 8::integer, '2024-08-08'::date, '2024-08-22'::date, '2024-08-14'::date, 3::integer, 13.84::real, 'Tortuga Restaurante', 'Avda. Azteca 123', 'México D.F.', '', '05033', 'Mexico'),
    (10277::integer, 'MORGK'::text, 2::integer, '2024-08-09'::date, '2024-09-06'::date, '2024-08-13'::date, 3::integer, 125.77::real, 'Morgenstern Gesundkost', 'Heerstr. 22', 'Leipzig', '', '04179', 'Germany'),
    (10278::integer, 'BERGS'::text, 8::integer, '2024-08-12'::date, '2024-09-09'::date, '2024-08-16'::date, 2::integer, 92.69::real, 'Berglunds snabbköp', 'Berguvsvägen  8', 'Luleå', '', 'S-958 22', 'Sweden'),
    (10279::integer, 'LEHMS'::text, 8::integer, '2024-08-13'::date, '2024-09-10'::date, '2024-08-16'::date, 2::integer, 25.83::real, 'Lehmanns Marktstand', 'Magazinweg 7', 'Frankfurt a.M.', '', '60528', 'Germany'),
    (10280::integer, 'BERGS'::text, 2::integer, '2024-08-14'::date, '2024-09-11'::date, '2024-09-12'::date, 1::integer, 8.98::real, 'Berglunds snabbköp', 'Berguvsvägen  8', 'Luleå', '', 'S-958 22', 'Sweden'),
    (10281::integer, 'ROMEY'::text, 4::integer, '2024-08-14'::date, '2024-08-28'::date, '2024-08-21'::date, 1::integer, 2.94::real, 'Romero y tomillo', 'Gran Vía, 1', 'Madrid', '', '28001', 'Spain'),
    (10282::integer, 'ROMEY'::text, 4::integer, '2024-08-15'::date, '2024-09-12'::date, '2024-08-21'::date, 1::integer, 12.69::real, 'Romero y tomillo', 'Gran Vía, 1', 'Madrid', '', '28001', 'Spain'),
    (10283::integer, 'LILAS'::text, 3::integer, '2024-08-16'::date, '2024-09-13'::date, '2024-08-23'::date, 3::integer, 84.81::real, 'LILA-Supermercado', 'Carrera 52 con Ave. Bolívar #65-98 Llano Largo', 'Barquisimeto', 'Lara', '3508', 'Venezuela'),
    (10284::integer, 'LEHMS'::text, 4::integer, '2024-08-19'::date, '2024-09-16'::date, '2024-08-27'::date, 1::integer, 76.56::real, 'Lehmanns Marktstand', 'Magazinweg 7', 'Frankfurt a.M.', '', '60528', 'Germany'),
    (10285::integer, 'QUICK'::text, 1::integer, '2024-08-20'::date, '2024-09-17'::date, '2024-08-26'::date, 2::integer, 76.83::real, 'QUICK-Stop', 'Taucherstraße 10', 'Cunewalde', '', '01307', 'Germany'),
    (10286::integer, 'QUICK'::text, 8::integer, '2024-08-21'::date, '2024-09-18'::date, '2024-08-30'::date, 3::integer, 229.24::real, 'QUICK-Stop', 'Taucherstraße 10', 'Cunewalde', '', '01307', 'Germany'),
    (10287::integer, 'RICAR'::text, 8::integer, '2024-08-22'::date, '2024-09-19'::date, '2024-08-28'::date, 3::integer, 12.76::real, 'Ricardo Adocicados', 'Av. Copacabana, 267', 'Rio de Janeiro', 'RJ', '02389-890', 'Brazil'),
    (10288::integer, 'REGGC'::text, 4::integer, '2024-08-23'::date, '2024-09-20'::date, '2024-09-03'::date, 1::integer, 7.45::real, 'Reggiani Caseifici', 'Strada Provinciale 124', 'Reggio Emilia', '', '42100', 'Italy'),
    (10289::integer, 'BSBEV'::text, 7::integer, '2024-08-26'::date, '2024-09-23'::date, '2024-08-28'::date, 3::integer, 22.77::real, 'B''s Beverages', 'Fauntleroy Circus', 'London', '', 'EC2 5NT', 'UK'),
    (10290::integer, 'COMMI'::text, 8::integer, '2024-08-27'::date, '2024-09-24'::date, '2024-09-03'::date, 1::integer, 79.7::real, 'Comércio Mineiro', 'Av. dos Lusíadas, 23', 'Sao Paulo', 'SP', '05432-043', 'Brazil'),
    (10291::integer, 'QUEDE'::text, 6::integer, '2024-08-27'::date, '2024-09-24'::date, '2024-09-04'::date, 2::integer, 6.4::real, 'Que Delícia', 'Rua da Panificadora, 12', 'Rio de Janeiro', 'RJ', '02389-673', 'Brazil'),
    (10292::integer, 'TRADH'::text, 1::integer, '2024-08-28'::date, '2024-09-25'::date, '2024-09-02'::date, 2::integer, 1.35::real, 'Tradiçao Hipermercados', 'Av. Inês de Castro, 414', 'Sao Paulo', 'SP', '05634-030', 'Brazil'),
    (10293::integer, 'TORTU'::text, 1::integer, '2024-08-29'::date, '2024-09-26'::date, '2024-09-11'::date, 3::integer, 21.18::real, 'Tortuga Restaurante', 'Avda. Azteca 123', 'México D.F.', '', '05033', 'Mexico'),
    (10294::integer, 'RATTC'::text, 4::integer, '2024-08-30'::date, '2024-09-27'::date, '2024-09-05'::date, 2::integer, 147.26::real, 'Rattlesnake Canyon Grocery', '2817 Milton Dr.', 'Albuquerque', 'NM', '87110', 'USA'),
    (10295::integer, 'VINET'::text, 2::integer, '2024-09-02'::date, '2024-09-30'::date, '2024-09-10'::date, 2::integer, 1.15::real, 'Vins et alcools Chevalier', '59 rue de l''Abbaye', 'Reims', '', '51100', 'France'),
    (10296::integer, 'LILAS'::text, 6::integer, '2024-09-03'::date, '2024-10-01'::date, '2024-09-11'::date, 1::integer, 0.12::real, 'LILA-Supermercado', 'Carrera 52 con Ave. Bolívar #65-98 Llano Largo', 'Barquisimeto', 'Lara', '3508', 'Venezuela'),
    (10297::integer, 'BLONP'::text, 5::integer, '2024-09-04'::date, '2024-10-16'::date, '2024-09-10'::date, 2::integer, 5.74::real, 'Blondel père et fils', '24, place Kléber', 'Strasbourg', '', '67000', 'France'),
    (10298::integer, 'HUNGO'::text, 6::integer, '2024-09-05'::date, '2024-10-03'::date, '2024-09-11'::date, 2::integer, 168.22::real, 'Hungry Owl All-Night Grocers', '8 Johnstown Road', 'Cork', 'Co. Cork', '', 'Ireland'),
    (10299::integer, 'RICAR'::text, 4::integer, '2024-09-06'::date, '2024-10-04'::date, '2024-09-13'::date, 2::integer, 29.76::real, 'Ricardo Adocicados', 'Av. Copacabana, 267', 'Rio de Janeiro', 'RJ', '02389-890', 'Brazil'),
    (10300::integer, 'MAGAA'::text, 2::integer, '2024-09-09'::date, '2024-10-07'::date, '2024-09-18'::date, 2::integer, 17.68::real, 'Magazzini Alimentari Riuniti', 'Via Ludovico il Moro 22', 'Bergamo', '', '24100', 'Italy'),
    (10301::integer, 'WANDK'::text, 8::integer, '2024-09-09'::date, '2024-10-07'::date, '2024-09-17'::date, 2::integer, 45.08::real, 'Die Wandernde Kuh', 'Adenauerallee 900', 'Stuttgart', '', '70563', 'Germany'),
    (10302::integer, 'SUPRD'::text, 4::integer, '2024-09-10'::date, '2024-10-08'::date, '2024-10-09'::date, 2::integer, 6.27::real, 'Suprêmes délices', 'Boulevard Tirou, 255', 'Charleroi', '', 'B-6000', 'Belgium'),
    (10303::integer, 'GODOS'::text, 7::integer, '2024-09-11'::date, '2024-10-09'::date, '2024-09-18'::date, 2::integer, 107.83::real, 'Godos Cocina Típica', 'C/ Romero, 33', 'Sevilla', '', '41101', 'Spain'),
    (10304::integer, 'TORTU'::text, 1::integer, '2024-09-12'::date, '2024-10-10'::date, '2024-09-17'::date, 2::integer, 63.79::real, 'Tortuga Restaurante', 'Avda. Azteca 123', 'México D.F.', '', '05033', 'Mexico'),
    (10305::integer, 'OLDWO'::text, 8::integer, '2024-09-13'::date, '2024-10-11'::date, '2024-10-09'::date, 3::integer, 257.62::real, 'Old World Delicatessen', '2743 Bering St.', 'Anchorage', 'AK', '99508', 'USA'),
    (10306::integer, 'ROMEY'::text, 1::integer, '2024-09-16'::date, '2024-10-14'::date, '2024-09-23'::date, 3::integer, 7.56::real, 'Romero y tomillo', 'Gran Vía, 1', 'Madrid', '', '28001', 'Spain'),
    (10307::integer, 'LONEP'::text, 2::integer, '2024-09-17'::date, '2024-10-15'::date, '2024-09-25'::date, 2::integer, 0.56::real, 'Lonesome Pine Restaurant', '89 Chiaroscuro Rd.', 'Portland', 'OR', '97219', 'USA'),
    (10308::integer, 'ANATR'::text, 7::integer, '2024-09-18'::date, '2024-10-16'::date, '2024-09-24'::date, 3::integer, 1.61::real, 'Ana Trujillo Emparedados y helados', 'Avda. de la Constitución 2222', 'México D.F.', '', '05021', 'Mexico'),
    (10309::integer, 'HUNGO'::text, 3::integer, '2024-09-19'::date, '2024-10-17'::date, '2024-10-23'::date, 1::integer, 47.3::real, 'Hungry Owl All-Night Grocers', '8 Johnstown Road', 'Cork', 'Co. Cork', '', 'Ireland'),
    (10310::integer, 'THEBI'::text, 8::integer, '2024-09-20'::date, '2024-10-18'::date, '2024-09-27'::date, 2::integer, 17.52::real, 'The Big Cheese', '89 Jefferson Way Suite 2', 'Portland', 'OR', '97201', 'USA'),
    (10311::integer, 'DUMON'::text, 1::integer, '2024-09-20'::date, '2024-10-04'::date, '2024-09-26'::date, 3::integer, 24.69::real, 'Du monde entier', '67, rue des Cinquante Otages', 'Nantes', '', '44000', 'France'),
    (10312::integer, 'WANDK'::text, 2::integer, '2024-09-23'::date, '2024-10-21'::date, '2024-10-03'::date, 2::integer, 40.26::real, 'Die Wandernde Kuh', 'Adenauerallee 900', 'Stuttgart', '', '70563', 'Germany'),
    (10313::integer, 'QUICK'::text, 2::integer, '2024-09-24'::date, '2024-10-22'::date, '2024-10-04'::date, 2::integer, 1.96::real, 'QUICK-Stop', 'Taucherstraße 10', 'Cunewalde', '', '01307', 'Germany'),
    (10314::integer, 'RATTC'::text, 1::integer, '2024-09-25'::date, '2024-10-23'::date, '2024-10-04'::date, 2::integer, 74.16::real, 'Rattlesnake Canyon Grocery', '2817 Milton Dr.', 'Albuquerque', 'NM', '87110', 'USA'),
    (10315::integer, 'ISLAT'::text, 4::integer, '2024-09-26'::date, '2024-10-24'::date, '2024-10-03'::date, 2::integer, 41.76::real, 'Island Trading', 'Garden House Crowther Way', 'Cowes', 'Isle of Wight', 'PO31 7PJ', 'UK'),
    (10316::integer, 'RATTC'::text, 1::integer, '2024-09-27'::date, '2024-10-25'::date, '2024-10-08'::date, 3::integer, 150.15::real, 'Rattlesnake Canyon Grocery', '2817 Milton Dr.', 'Albuquerque', 'NM', '87110', 'USA'),
    (10317::integer, 'LONEP'::text, 6::integer, '2024-09-30'::date, '2024-10-28'::date, '2024-10-10'::date, 1::integer, 12.69::real, 'Lonesome Pine Restaurant', '89 Chiaroscuro Rd.', 'Portland', 'OR', '97219', 'USA'),
    (10318::integer, 'ISLAT'::text, 8::integer, '2024-10-01'::date, '2024-10-29'::date, '2024-10-04'::date, 2::integer, 4.73::real, 'Island Trading', 'Garden House Crowther Way', 'Cowes', 'Isle of Wight', 'PO31 7PJ', 'UK'),
    (10319::integer, 'TORTU'::text, 7::integer, '2024-10-02'::date, '2024-10-30'::date, '2024-10-11'::date, 3::integer, 64.5::real, 'Tortuga Restaurante', 'Avda. Azteca 123', 'México D.F.', '', '05033', 'Mexico'),
    (10320::integer, 'WARTH'::text, 5::integer, '2024-10-03'::date, '2024-10-17'::date, '2024-10-18'::date, 3::integer, 34.57::real, 'Wartian Herkku', 'Torikatu 38', 'Oulu', '', '90110', 'Finland'),
    (10321::integer, 'ISLAT'::text, 3::integer, '2024-10-03'::date, '2024-10-31'::date, '2024-10-11'::date, 2::integer, 3.43::real, 'Island Trading', 'Garden House Crowther Way', 'Cowes', 'Isle of Wight', 'PO31 7PJ', 'UK'),
    (10322::integer, 'PERIC'::text, 7::integer, '2024-10-04'::date, '2024-11-01'::date, '2024-10-23'::date, 3::integer, 0.4::real, 'Pericles Comidas clásicas', 'Calle Dr. Jorge Cash 321', 'México D.F.', '', '05033', 'Mexico'),
    (10323::integer, 'KOENE'::text, 4::integer, '2024-10-07'::date, '2024-11-04'::date, '2024-10-14'::date, 1::integer, 4.88::real, 'Königlich Essen', 'Maubelstr. 90', 'Brandenburg', '', '14776', 'Germany'),
    (10324::integer, 'SAVEA'::text, 9::integer, '2024-10-08'::date, '2024-11-05'::date, '2024-10-10'::date, 1::integer, 214.27::real, 'Save-a-lot Markets', '187 Suffolk Ln.', 'Boise', 'ID', '83720', 'USA'),
    (10325::integer, 'KOENE'::text, 1::integer, '2024-10-09'::date, '2024-10-23'::date, '2024-10-14'::date, 3::integer, 64.86::real, 'Königlich Essen', 'Maubelstr. 90', 'Brandenburg', '', '14776', 'Germany'),
    (10326::integer, 'BOLID'::text, 4::integer, '2024-10-10'::date, '2024-11-07'::date, '2024-10-14'::date, 2::integer, 77.92::real, 'Bólido Comidas preparadas', 'C/ Araquil, 67', 'Madrid', '', '28023', 'Spain'),
    (10327::integer, 'FOLKO'::text, 2::integer, '2024-10-11'::date, '2024-11-08'::date, '2024-10-14'::date, 1::integer, 63.36::real, 'Folk och fä HB', 'Åkergatan 24', 'Bräcke', '', 'S-844 67', 'Sweden'),
    (10328::integer, 'FURIB'::text, 4::integer, '2024-10-14'::date, '2024-11-11'::date, '2024-10-17'::date, 3::integer, 87.03::real, 'Furia Bacalhau e Frutos do Mar', 'Jardim das rosas n. 32', 'Lisboa', '', '1675', 'Portugal'),
    (10329::integer, 'SPLIR'::text, 4::integer, '2024-10-15'::date, '2024-11-26'::date, '2024-10-23'::date, 2::integer, 191.67::real, 'Split Rail Beer & Ale', 'P.O. Box 555', 'Lander', 'WY', '82520', 'USA'),
    (10330::integer, 'LILAS'::text, 3::integer, '2024-10-16'::date, '2024-11-13'::date, '2024-10-28'::date, 1::integer, 12.75::real, 'LILA-Supermercado', 'Carrera 52 con Ave. Bolívar #65-98 Llano Largo', 'Barquisimeto', 'Lara', '3508', 'Venezuela'),
    (10331::integer, 'BONAP'::text, 9::integer, '2024-10-16'::date, '2024-11-27'::date, '2024-10-21'::date, 1::integer, 10.19::real, 'Bon app''', '12, rue des Bouchers', 'Marseille', '', '13008', 'France'),
    (10332::integer, 'MEREP'::text, 3::integer, '2024-10-17'::date, '2024-11-28'::date, '2024-10-21'::date, 2::integer, 52.84::real, 'Mère Paillarde', '43 rue St. Laurent', 'Montréal', 'Québec', 'H1J 1C3', 'Canada'),
    (10333::integer, 'WARTH'::text, 5::integer, '2024-10-18'::date, '2024-11-15'::date, '2024-10-25'::date, 3::integer, 0.59::real, 'Wartian Herkku', 'Torikatu 38', 'Oulu', '', '90110', 'Finland'),
    (10334::integer, 'VICTE'::text, 8::integer, '2024-10-21'::date, '2024-11-18'::date, '2024-10-28'::date, 2::integer, 8.56::real, 'Victuailles en stock', '2, rue du Commerce', 'Lyon', '', '69004', 'France'),
    (10335::integer, 'HUNGO'::text, 7::integer, '2024-10-22'::date, '2024-11-19'::date, '2024-10-24'::date, 2::integer, 42.11::real, 'Hungry Owl All-Night Grocers', '8 Johnstown Road', 'Cork', 'Co. Cork', '', 'Ireland'),
    (10336::integer, 'PRINI'::text, 7::integer, '2024-10-23'::date, '2024-11-20'::date, '2024-10-25'::date, 2::integer, 15.51::real, 'Princesa Isabel Vinhos', 'Estrada da saúde n. 58', 'Lisboa', '', '1756', 'Portugal'),
    (10337::integer, 'FRANK'::text, 4::integer, '2024-10-24'::date, '2024-11-21'::date, '2024-10-29'::date, 3::integer, 108.26::real, 'Frankenversand', 'Berliner Platz 43', 'München', '', '80805', 'Germany'),
    (10338::integer, 'OLDWO'::text, 4::integer, '2024-10-25'::date, '2024-11-22'::date, '2024-10-29'::date, 3::integer, 84.21::real, 'Old World Delicatessen', '2743 Bering St.', 'Anchorage', 'AK', '99508', 'USA'),
    (10339::integer, 'MEREP'::text, 2::integer, '2024-10-28'::date, '2024-11-25'::date, '2024-11-04'::date, 2::integer, 15.66::real, 'Mère Paillarde', '43 rue St. Laurent', 'Montréal', 'Québec', 'H1J 1C3', 'Canada'),
    (10340::integer, 'BONAP'::text, 1::integer, '2024-10-29'::date, '2024-11-26'::date, '2024-11-08'::date, 3::integer, 166.31::real, 'Bon app''', '12, rue des Bouchers', 'Marseille', '', '13008', 'France'),
    (10341::integer, 'SIMOB'::text, 7::integer, '2024-10-29'::date, '2024-11-26'::date, '2024-11-05'::date, 3::integer, 26.78::real, 'Simons bistro', 'Vinbæltet 34', 'Kobenhavn', '', '1734', 'Denmark'),
    (10342::integer, 'FRANK'::text, 4::integer, '2024-10-30'::date, '2024-11-13'::date, '2024-11-04'::date, 2::integer, 54.83::real, 'Frankenversand', 'Berliner Platz 43', 'München', '', '80805', 'Germany'),
    (10343::integer, 'LEHMS'::text, 4::integer, '2024-10-31'::date, '2024-11-28'::date, '2024-11-06'::date, 1::integer, 110.37::real, 'Lehmanns Marktstand', 'Magazinweg 7', 'Frankfurt a.M.', '', '60528', 'Germany'),
    (10344::integer, 'WHITC'::text, 4::integer, '2024-11-01'::date, '2024-11-29'::date, '2024-11-05'::date, 2::integer, 23.29::real, 'White Clover Markets', '1029 - 12th Ave. S.', 'Seattle', 'WA', '98124', 'USA'),
    (10345::integer, 'QUICK'::text, 2::integer, '2024-11-04'::date, '2024-12-02'::date, '2024-11-11'::date, 2::integer, 249.06::real, 'QUICK-Stop', 'Taucherstraße 10', 'Cunewalde', '', '01307', 'Germany'),
    (10346::integer, 'RATTC'::text, 3::integer, '2024-11-05'::date, '2024-12-17'::date, '2024-11-08'::date, 3::integer, 142.08::real, 'Rattlesnake Canyon Grocery', '2817 Milton Dr.', 'Albuquerque', 'NM', '87110', 'USA'),
    (10347::integer, 'FAMIA'::text, 4::integer, '2024-11-06'::date, '2024-12-04'::date, '2024-11-08'::date, 3::integer, 3.1::real, 'Familia Arquibaldo', 'Rua Orós, 92', 'Sao Paulo', 'SP', '05442-030', 'Brazil'),
    (10348::integer, 'WANDK'::text, 4::integer, '2024-11-07'::date, '2024-12-05'::date, '2024-11-15'::date, 2::integer, 0.78::real, 'Die Wandernde Kuh', 'Adenauerallee 900', 'Stuttgart', '', '70563', 'Germany'),
    (10349::integer, 'SPLIR'::text, 7::integer, '2024-11-08'::date, '2024-12-06'::date, '2024-11-15'::date, 1::integer, 8.63::real, 'Split Rail Beer & Ale', 'P.O. Box 555', 'Lander', 'WY', '82520', 'USA'),
    (10350::integer, 'LAMAI'::text, 6::integer, '2024-11-11'::date, '2024-12-09'::date, '2024-12-03'::date, 2::integer, 64.19::real, 'La maison d''Asie', '1 rue Alsace-Lorraine', 'Toulouse', '', '31000', 'France'),
    (10351::integer, 'ERNSH'::text, 1::integer, '2024-11-11'::date, '2024-12-09'::date, '2024-11-20'::date, 1::integer, 162.33::real, 'Ernst Handel', 'Kirchgasse 6', 'Graz', '', '8010', 'Austria'),
    (10352::integer, 'FURIB'::text, 3::integer, '2024-11-12'::date, '2024-11-26'::date, '2024-11-18'::date, 3::integer, 1.3::real, 'Furia Bacalhau e Frutos do Mar', 'Jardim das rosas n. 32', 'Lisboa', '', '1675', 'Portugal'),
    (10353::integer, 'PICCO'::text, 7::integer, '2024-11-13'::date, '2024-12-11'::date, '2024-11-25'::date, 3::integer, 360.63::real, 'Piccolo und mehr', 'Geislweg 14', 'Salzburg', '', '5020', 'Austria'),
    (10354::integer, 'PERIC'::text, 8::integer, '2024-11-14'::date, '2024-12-12'::date, '2024-11-20'::date, 3::integer, 53.8::real, 'Pericles Comidas clásicas', 'Calle Dr. Jorge Cash 321', 'México D.F.', '', '05033', 'Mexico'),
    (10355::integer, 'AROUT'::text, 6::integer, '2024-11-15'::date, '2024-12-13'::date, '2024-11-20'::date, 1::integer, 41.95::real, 'Around the Horn', 'Brook Farm Stratford St. Mary', 'Colchester', 'Essex', 'CO7 6JX', 'UK'),
    (10356::integer, 'WANDK'::text, 6::integer, '2024-11-18'::date, '2024-12-16'::date, '2024-11-27'::date, 2::integer, 36.71::real, 'Die Wandernde Kuh', 'Adenauerallee 900', 'Stuttgart', '', '70563', 'Germany'),
    (10357::integer, 'LILAS'::text, 1::integer, '2024-11-19'::date, '2024-12-17'::date, '2024-12-02'::date, 3::integer, 34.88::real, 'LILA-Supermercado', 'Carrera 52 con Ave. Bolívar #65-98 Llano Largo', 'Barquisimeto', 'Lara', '3508', 'Venezuela'),
    (10358::integer, 'LAMAI'::text, 5::integer, '2024-11-20'::date, '2024-12-18'::date, '2024-11-27'::date, 1::integer, 19.64::real, 'La maison d''Asie', '1 rue Alsace-Lorraine', 'Toulouse', '', '31000', 'France'),
    (10359::integer, 'SEVES'::text, 5::integer, '2024-11-21'::date, '2024-12-19'::date, '2024-11-26'::date, 3::integer, 288.43::real, 'Seven Seas Imports', '90 Wadhurst Rd.', 'London', '', 'OX15 4NB', 'UK'),
    (10360::integer, 'BLONP'::text, 4::integer, '2024-11-22'::date, '2024-12-20'::date, '2024-12-02'::date, 3::integer, 131.7::real, 'Blondel père et fils', '24, place Kléber', 'Strasbourg', '', '67000', 'France'),
    (10361::integer, 'QUICK'::text, 1::integer, '2024-11-22'::date, '2024-12-20'::date, '2024-12-03'::date, 2::integer, 183.17::real, 'QUICK-Stop', 'Taucherstraße 10', 'Cunewalde', '', '01307', 'Germany'),
    (10362::integer, 'BONAP'::text, 3::integer, '2024-11-25'::date, '2024-12-23'::date, '2024-11-28'::date, 1::integer, 96.04::real, 'Bon app''', '12, rue des Bouchers', 'Marseille', '', '13008', 'France'),
    (10363::integer, 'DRACD'::text, 4::integer, '2024-11-26'::date, '2024-12-24'::date, '2024-12-04'::date, 3::integer, 30.54::real, 'Drachenblut Delikatessen', 'Walserweg 21', 'Aachen', '', '52066', 'Germany'),
    (10364::integer, 'EASTC'::text, 1::integer, '2024-11-26'::date, '2025-01-07'::date, '2024-12-04'::date, 1::integer, 71.97::real, 'Eastern Connection', '35 King George', 'London', '', 'WX3 6FW', 'UK'),
    (10365::integer, 'ANTON'::text, 3::integer, '2024-11-27'::date, '2024-12-25'::date, '2024-12-02'::date, 2::integer, 22::real, 'Antonio Moreno Taquería', 'Mataderos  2312', 'México D.F.', '', '05023', 'Mexico'),
    (10366::integer, 'GALED'::text, 8::integer, '2024-11-28'::date, '2025-01-09'::date, '2024-12-30'::date, 2::integer, 10.14::real, 'Galería del gastronómo', 'Rambla de Cataluña, 23', 'Barcelona', '', '8022', 'Spain'),
    (10367::integer, 'VAFFE'::text, 7::integer, '2024-11-28'::date, '2024-12-26'::date, '2024-12-02'::date, 3::integer, 13.55::real, 'Vaffeljernet', 'Smagsloget 45', 'Århus', '', '8200', 'Denmark'),
    (10368::integer, 'ERNSH'::text, 2::integer, '2024-11-29'::date, '2024-12-27'::date, '2024-12-02'::date, 2::integer, 101.95::real, 'Ernst Handel', 'Kirchgasse 6', 'Graz', '', '8010', 'Austria'),
    (10369::integer, 'SPLIR'::text, 8::integer, '2024-12-02'::date, '2024-12-30'::date, '2024-12-09'::date, 2::integer, 195.68::real, 'Split Rail Beer & Ale', 'P.O. Box 555', 'Lander', 'WY', '82520', 'USA'),
    (10370::integer, 'CHOPS'::text, 6::integer, '2024-12-03'::date, '2024-12-31'::date, '2024-12-27'::date, 2::integer, 1.17::real, 'Chop-suey Chinese', 'Hauptstr. 31', 'Bern', '', '3012', 'Switzerland'),
    (10371::integer, 'LAMAI'::text, 1::integer, '2024-12-03'::date, '2024-12-31'::date, '2024-12-24'::date, 1::integer, 0.45::real, 'La maison d''Asie', '1 rue Alsace-Lorraine', 'Toulouse', '', '31000', 'France'),
    (10372::integer, 'QUEEN'::text, 5::integer, '2024-12-04'::date, '2025-01-01'::date, '2024-12-09'::date, 2::integer, 890.78::real, 'Queen Cozinha', 'Alameda dos Canàrios, 891', 'Sao Paulo', 'SP', '05487-020', 'Brazil'),
    (10373::integer, 'HUNGO'::text, 4::integer, '2024-12-05'::date, '2025-01-02'::date, '2024-12-11'::date, 3::integer, 124.12::real, 'Hungry Owl All-Night Grocers', '8 Johnstown Road', 'Cork', 'Co. Cork', '', 'Ireland'),
    (10374::integer, 'WOLZA'::text, 1::integer, '2024-12-05'::date, '2025-01-02'::date, '2024-12-09'::date, 3::integer, 3.94::real, 'Wolski Zajazd', 'ul. Filtrowa 68', 'Warszawa', '', '01-012', 'Poland'),
    (10375::integer, 'HUNGC'::text, 3::integer, '2024-12-06'::date, '2025-01-03'::date, '2024-12-09'::date, 2::integer, 20.12::real, 'Hungry Coyote Import Store', 'City Center Plaza 516 Main St.', 'Elgin', 'OR', '97827', 'USA'),
    (10376::integer, 'MEREP'::text, 1::integer, '2024-12-09'::date, '2025-01-06'::date, '2024-12-13'::date, 2::integer, 20.39::real, 'Mère Paillarde', '43 rue St. Laurent', 'Montréal', 'Québec', 'H1J 1C3', 'Canada'),
    (10377::integer, 'SEVES'::text, 1::integer, '2024-12-09'::date, '2025-01-06'::date, '2024-12-13'::date, 3::integer, 22.21::real, 'Seven Seas Imports', '90 Wadhurst Rd.', 'London', '', 'OX15 4NB', 'UK'),
    (10378::integer, 'FOLKO'::text, 5::integer, '2024-12-10'::date, '2025-01-07'::date, '2024-12-19'::date, 3::integer, 5.44::real, 'Folk och fä HB', 'Åkergatan 24', 'Bräcke', '', 'S-844 67', 'Sweden'),
    (10379::integer, 'QUEDE'::text, 2::integer, '2024-12-11'::date, '2025-01-08'::date, '2024-12-13'::date, 1::integer, 45.03::real, 'Que Delícia', 'Rua da Panificadora, 12', 'Rio de Janeiro', 'RJ', '02389-673', 'Brazil'),
    (10380::integer, 'HUNGO'::text, 8::integer, '2024-12-12'::date, '2025-01-09'::date, '2025-01-16'::date, 3::integer, 35.03::real, 'Hungry Owl All-Night Grocers', '8 Johnstown Road', 'Cork', 'Co. Cork', '', 'Ireland'),
    (10381::integer, 'LILAS'::text, 3::integer, '2024-12-12'::date, '2025-01-09'::date, '2024-12-13'::date, 3::integer, 7.99::real, 'LILA-Supermercado', 'Carrera 52 con Ave. Bolívar #65-98 Llano Largo', 'Barquisimeto', 'Lara', '3508', 'Venezuela'),
    (10382::integer, 'ERNSH'::text, 4::integer, '2024-12-13'::date, '2025-01-10'::date, '2024-12-16'::date, 1::integer, 94.77::real, 'Ernst Handel', 'Kirchgasse 6', 'Graz', '', '8010', 'Austria'),
    (10383::integer, 'AROUT'::text, 8::integer, '2024-12-16'::date, '2025-01-13'::date, '2024-12-18'::date, 3::integer, 34.24::real, 'Around the Horn', 'Brook Farm Stratford St. Mary', 'Colchester', 'Essex', 'CO7 6JX', 'UK'),
    (10384::integer, 'BERGS'::text, 3::integer, '2024-12-16'::date, '2025-01-13'::date, '2024-12-20'::date, 3::integer, 168.64::real, 'Berglunds snabbköp', 'Berguvsvägen  8', 'Luleå', '', 'S-958 22', 'Sweden'),
    (10385::integer, 'SPLIR'::text, 1::integer, '2024-12-17'::date, '2025-01-14'::date, '2024-12-23'::date, 2::integer, 30.96::real, 'Split Rail Beer & Ale', 'P.O. Box 555', 'Lander', 'WY', '82520', 'USA'),
    (10386::integer, 'FAMIA'::text, 9::integer, '2024-12-18'::date, '2025-01-01'::date, '2024-12-25'::date, 3::integer, 13.99::real, 'Familia Arquibaldo', 'Rua Orós, 92', 'Sao Paulo', 'SP', '05442-030', 'Brazil'),
    (10387::integer, 'SANTG'::text, 1::integer, '2024-12-18'::date, '2025-01-15'::date, '2024-12-20'::date, 2::integer, 93.63::real, 'Santé Gourmet', 'Erling Skakkes gate 78', 'Stavern', '', '4110', 'Norway'),
    (10388::integer, 'SEVES'::text, 2::integer, '2024-12-19'::date, '2025-01-16'::date, '2024-12-20'::date, 1::integer, 34.86::real, 'Seven Seas Imports', '90 Wadhurst Rd.', 'London', '', 'OX15 4NB', 'UK'),
    (10389::integer, 'BOTTM'::text, 4::integer, '2024-12-20'::date, '2025-01-17'::date, '2024-12-24'::date, 2::integer, 47.42::real, 'Bottom-Dollar Markets', '23 Tsawassen Blvd.', 'Tsawassen', 'BC', 'T2F 8M4', 'Canada'),
    (10390::integer, 'ERNSH'::text, 6::integer, '2024-12-23'::date, '2025-01-20'::date, '2024-12-26'::date, 1::integer, 126.38::real, 'Ernst Handel', 'Kirchgasse 6', 'Graz', '', '8010', 'Austria'),
    (10391::integer, 'DRACD'::text, 3::integer, '2024-12-23'::date, '2025-01-20'::date, '2024-12-31'::date, 3::integer, 5.45::real, 'Drachenblut Delikatessen', 'Walserweg 21', 'Aachen', '', '52066', 'Germany'),
    (10392::integer, 'PICCO'::text, 2::integer, '2024-12-24'::date, '2025-01-21'::date, '2025-01-01'::date, 3::integer, 122.46::real, 'Piccolo und mehr', 'Geislweg 14', 'Salzburg', '', '5020', 'Austria'),
    (10393::integer, 'SAVEA'::text, 1::integer, '2024-12-25'::date, '2025-01-22'::date, '2025-01-03'::date, 3::integer, 126.56::real, 'Save-a-lot Markets', '187 Suffolk Ln.', 'Boise', 'ID', '83720', 'USA'),
    (10394::integer, 'HUNGC'::text, 1::integer, '2024-12-25'::date, '2025-01-22'::date, '2025-01-03'::date, 3::integer, 30.34::real, 'Hungry Coyote Import Store', 'City Center Plaza 516 Main St.', 'Elgin', 'OR', '97827', 'USA'),
    (10395::integer, 'HILAA'::text, 6::integer, '2024-12-26'::date, '2025-01-23'::date, '2025-01-03'::date, 1::integer, 184.41::real, 'HILARION-Abastos', 'Carrera 22 con Ave. Carlos Soublette #8-35', 'San Cristóbal', 'Táchira', '5022', 'Venezuela'),
    (10396::integer, 'FRANK'::text, 1::integer, '2024-12-27'::date, '2025-01-10'::date, '2025-01-06'::date, 3::integer, 135.35::real, 'Frankenversand', 'Berliner Platz 43', 'München', '', '80805', 'Germany'),
    (10397::integer, 'PRINI'::text, 5::integer, '2024-12-27'::date, '2025-01-24'::date, '2025-01-02'::date, 1::integer, 60.26::real, 'Princesa Isabel Vinhos', 'Estrada da saúde n. 58', 'Lisboa', '', '1756', 'Portugal'),
    (10398::integer, 'SAVEA'::text, 2::integer, '2024-12-30'::date, '2025-01-27'::date, '2025-01-09'::date, 3::integer, 89.16::real, 'Save-a-lot Markets', '187 Suffolk Ln.', 'Boise', 'ID', '83720', 'USA'),
    (10399::integer, 'VAFFE'::text, 8::integer, '2024-12-31'::date, '2025-01-14'::date, '2025-01-08'::date, 3::integer, 27.36::real, 'Vaffeljernet', 'Smagsloget 45', 'Århus', '', '8200', 'Denmark'),
    (10400::integer, 'EASTC'::text, 1::integer, '2025-01-01'::date, '2025-01-29'::date, '2025-01-16'::date, 3::integer, 83.93::real, 'Eastern Connection', '35 King George', 'London', '', 'WX3 6FW', 'UK'),
    (10401::integer, 'RATTC'::text, 1::integer, '2025-01-01'::date, '2025-01-29'::date, '2025-01-10'::date, 1::integer, 12.51::real, 'Rattlesnake Canyon Grocery', '2817 Milton Dr.', 'Albuquerque', 'NM', '87110', 'USA'),
    (10402::integer, 'ERNSH'::text, 8::integer, '2025-01-02'::date, '2025-02-13'::date, '2025-01-10'::date, 2::integer, 67.88::real, 'Ernst Handel', 'Kirchgasse 6', 'Graz', '', '8010', 'Austria'),
    (10403::integer, 'ERNSH'::text, 4::integer, '2025-01-03'::date, '2025-01-31'::date, '2025-01-09'::date, 3::integer, 73.79::real, 'Ernst Handel', 'Kirchgasse 6', 'Graz', '', '8010', 'Austria'),
    (10404::integer, 'MAGAA'::text, 2::integer, '2025-01-03'::date, '2025-01-31'::date, '2025-01-08'::date, 1::integer, 155.97::real, 'Magazzini Alimentari Riuniti', 'Via Ludovico il Moro 22', 'Bergamo', '', '24100', 'Italy'),
    (10405::integer, 'LINOD'::text, 1::integer, '2025-01-06'::date, '2025-02-03'::date, '2025-01-22'::date, 1::integer, 34.82::real, 'LINO-Delicateses', 'Ave. 5 de Mayo Porlamar', 'I. de Margarita', 'Nueva Esparta', '4980', 'Venezuela'),
    (10406::integer, 'QUEEN'::text, 7::integer, '2025-01-07'::date, '2025-02-18'::date, '2025-01-13'::date, 1::integer, 108.04::real, 'Queen Cozinha', 'Alameda dos Canàrios, 891', 'Sao Paulo', 'SP', '05487-020', 'Brazil'),
    (10407::integer, 'OTTIK'::text, 2::integer, '2025-01-07'::date, '2025-02-04'::date, '2025-01-30'::date, 2::integer, 91.48::real, 'Ottilies Käseladen', 'Mehrheimerstr. 369', 'Köln', '', '50739', 'Germany'),
    (10408::integer, 'FOLIG'::text, 8::integer, '2025-01-08'::date, '2025-02-05'::date, '2025-01-14'::date, 1::integer, 11.26::real, 'Folies gourmandes', '184, chaussée de Tournai', 'Lille', '', '59000', 'France'),
    (10409::integer, 'OCEAN'::text, 3::integer, '2025-01-09'::date, '2025-02-06'::date, '2025-01-14'::date, 1::integer, 29.83::real, 'Océano Atlántico Ltda.', 'Ing. Gustavo Moncada 8585 Piso 20-A', 'Buenos Aires', '', '1010', 'Argentina'),
    (10410::integer, 'BOTTM'::text, 3::integer, '2025-01-10'::date, '2025-02-07'::date, '2025-01-15'::date, 3::integer, 2.4::real, 'Bottom-Dollar Markets', '23 Tsawassen Blvd.', 'Tsawassen', 'BC', 'T2F 8M4', 'Canada'),
    (10411::integer, 'BOTTM'::text, 9::integer, '2025-01-10'::date, '2025-02-07'::date, '2025-01-21'::date, 3::integer, 23.65::real, 'Bottom-Dollar Markets', '23 Tsawassen Blvd.', 'Tsawassen', 'BC', 'T2F 8M4', 'Canada'),
    (10412::integer, 'WARTH'::text, 8::integer, '2025-01-13'::date, '2025-02-10'::date, '2025-01-15'::date, 2::integer, 3.77::real, 'Wartian Herkku', 'Torikatu 38', 'Oulu', '', '90110', 'Finland'),
    (10413::integer, 'LAMAI'::text, 3::integer, '2025-01-14'::date, '2025-02-11'::date, '2025-01-16'::date, 2::integer, 95.66::real, 'La maison d''Asie', '1 rue Alsace-Lorraine', 'Toulouse', '', '31000', 'France'),
    (10414::integer, 'FAMIA'::text, 2::integer, '2025-01-14'::date, '2025-02-11'::date, '2025-01-17'::date, 3::integer, 21.48::real, 'Familia Arquibaldo', 'Rua Orós, 92', 'Sao Paulo', 'SP', '05442-030', 'Brazil'),
    (10415::integer, 'HUNGC'::text, 3::integer, '2025-01-15'::date, '2025-02-12'::date, '2025-01-24'::date, 1::integer, 0.2::real, 'Hungry Coyote Import Store', 'City Center Plaza 516 Main St.', 'Elgin', 'OR', '97827', 'USA'),
    (10416::integer, 'WARTH'::text, 8::integer, '2025-01-16'::date, '2025-02-13'::date, '2025-01-27'::date, 3::integer, 22.72::real, 'Wartian Herkku', 'Torikatu 38', 'Oulu', '', '90110', 'Finland'),
    (10417::integer, 'SIMOB'::text, 4::integer, '2025-01-16'::date, '2025-02-13'::date, '2025-01-28'::date, 3::integer, 70.29::real, 'Simons bistro', 'Vinbæltet 34', 'Kobenhavn', '', '1734', 'Denmark'),
    (10418::integer, 'QUICK'::text, 4::integer, '2025-01-17'::date, '2025-02-14'::date, '2025-01-24'::date, 1::integer, 17.55::real, 'QUICK-Stop', 'Taucherstraße 10', 'Cunewalde', '', '01307', 'Germany'),
    (10419::integer, 'RICSU'::text, 4::integer, '2025-01-20'::date, '2025-02-17'::date, '2025-01-30'::date, 2::integer, 137.35::real, 'Richter Supermarkt', 'Starenweg 5', 'Genève', '', '1204', 'Switzerland'),
    (10420::integer, 'WELLI'::text, 3::integer, '2025-01-21'::date, '2025-02-18'::date, '2025-01-27'::date, 1::integer, 44.12::real, 'Wellington Importadora', 'Rua do Mercado, 12', 'Resende', 'SP', '08737-363', 'Brazil'),
    (10421::integer, 'QUEDE'::text, 8::integer, '2025-01-21'::date, '2025-03-04'::date, '2025-01-27'::date, 1::integer, 99.23::real, 'Que Delícia', 'Rua da Panificadora, 12', 'Rio de Janeiro', 'RJ', '02389-673', 'Brazil'),
    (10422::integer, 'FRANS'::text, 2::integer, '2025-01-22'::date, '2025-02-19'::date, '2025-01-31'::date, 1::integer, 3.02::real, 'Franchi S.p.A.', 'Via Monte Bianco 34', 'Torino', '', '10100', 'Italy'),
    (10423::integer, 'GOURL'::text, 6::integer, '2025-01-23'::date, '2025-02-06'::date, '2025-02-24'::date, 3::integer, 24.5::real, 'Gourmet Lanchonetes', 'Av. Brasil, 442', 'Campinas', 'SP', '04876-786', 'Brazil'),
    (10424::integer, 'MEREP'::text, 7::integer, '2025-01-23'::date, '2025-02-20'::date, '2025-01-27'::date, 2::integer, 370.61::real, 'Mère Paillarde', '43 rue St. Laurent', 'Montréal', 'Québec', 'H1J 1C3', 'Canada'),
    (10425::integer, 'LAMAI'::text, 6::integer, '2025-01-24'::date, '2025-02-21'::date, '2025-02-14'::date, 2::integer, 7.93::real, 'La maison d''Asie', '1 rue Alsace-Lorraine', 'Toulouse', '', '31000', 'France'),
    (10426::integer, 'GALED'::text, 4::integer, '2025-01-27'::date, '2025-02-24'::date, '2025-02-06'::date, 1::integer, 18.69::real, 'Galería del gastronómo', 'Rambla de Cataluña, 23', 'Barcelona', '', '8022', 'Spain'),
    (10427::integer, 'PICCO'::text, 4::integer, '2025-01-27'::date, '2025-02-24'::date, '2025-03-03'::date, 2::integer, 31.29::real, 'Piccolo und mehr', 'Geislweg 14', 'Salzburg', '', '5020', 'Austria'),
    (10428::integer, 'REGGC'::text, 7::integer, '2025-01-28'::date, '2025-02-25'::date, '2025-02-04'::date, 1::integer, 11.09::real, 'Reggiani Caseifici', 'Strada Provinciale 124', 'Reggio Emilia', '', '42100', 'Italy'),
    (10429::integer, 'HUNGO'::text, 3::integer, '2025-01-29'::date, '2025-03-12'::date, '2025-02-07'::date, 2::integer, 56.63::real, 'Hungry Owl All-Night Grocers', '8 Johnstown Road', 'Cork', 'Co. Cork', '', 'Ireland'),
    (10430::integer, 'ERNSH'::text, 4::integer, '2025-01-30'::date, '2025-02-13'::date, '2025-02-03'::date, 1::integer, 458.78::real, 'Ernst Handel', 'Kirchgasse 6', 'Graz', '', '8010', 'Austria'),
    (10431::integer, 'BOTTM'::text, 4::integer, '2025-01-30'::date, '2025-02-13'::date, '2025-02-07'::date, 2::integer, 44.17::real, 'Bottom-Dollar Markets', '23 Tsawassen Blvd.', 'Tsawassen', 'BC', 'T2F 8M4', 'Canada'),
    (10432::integer, 'SPLIR'::text, 3::integer, '2025-01-31'::date, '2025-02-14'::date, '2025-02-07'::date, 2::integer, 4.34::real, 'Split Rail Beer & Ale', 'P.O. Box 555', 'Lander', 'WY', '82520', 'USA'),
    (10433::integer, 'PRINI'::text, 3::integer, '2025-02-03'::date, '2025-03-03'::date, '2025-03-04'::date, 3::integer, 73.83::real, 'Princesa Isabel Vinhos', 'Estrada da saúde n. 58', 'Lisboa', '', '1756', 'Portugal'),
    (10434::integer, 'FOLKO'::text, 3::integer, '2025-02-03'::date, '2025-03-03'::date, '2025-02-13'::date, 2::integer, 17.92::real, 'Folk och fä HB', 'Åkergatan 24', 'Bräcke', '', 'S-844 67', 'Sweden'),
    (10435::integer, 'CONSH'::text, 8::integer, '2025-02-04'::date, '2025-03-18'::date, '2025-02-07'::date, 2::integer, 9.21::real, 'Consolidated Holdings', 'Berkeley Gardens 12  Brewery', 'London', '', 'WX1 6LT', 'UK'),
    (10436::integer, 'BLONP'::text, 3::integer, '2025-02-05'::date, '2025-03-05'::date, '2025-02-11'::date, 2::integer, 156.66::real, 'Blondel père et fils', '24, place Kléber', 'Strasbourg', '', '67000', 'France'),
    (10437::integer, 'WARTH'::text, 8::integer, '2025-02-05'::date, '2025-03-05'::date, '2025-02-12'::date, 1::integer, 19.97::real, 'Wartian Herkku', 'Torikatu 38', 'Oulu', '', '90110', 'Finland'),
    (10438::integer, 'TOMSP'::text, 3::integer, '2025-02-06'::date, '2025-03-06'::date, '2025-02-14'::date, 2::integer, 8.24::real, 'Toms Spezialitäten', 'Luisenstr. 48', 'Münster', '', '44087', 'Germany'),
    (10439::integer, 'MEREP'::text, 6::integer, '2025-02-07'::date, '2025-03-07'::date, '2025-02-10'::date, 3::integer, 4.07::real, 'Mère Paillarde', '43 rue St. Laurent', 'Montréal', 'Québec', 'H1J 1C3', 'Canada'),
    (10440::integer, 'SAVEA'::text, 4::integer, '2025-02-10'::date, '2025-03-10'::date, '2025-02-28'::date, 2::integer, 86.53::real, 'Save-a-lot Markets', '187 Suffolk Ln.', 'Boise', 'ID', '83720', 'USA'),
    (10441::integer, 'OLDWO'::text, 3::integer, '2025-02-10'::date, '2025-03-24'::date, '2025-03-14'::date, 2::integer, 73.02::real, 'Old World Delicatessen', '2743 Bering St.', 'Anchorage', 'AK', '99508', 'USA'),
    (10442::integer, 'ERNSH'::text, 3::integer, '2025-02-11'::date, '2025-03-11'::date, '2025-02-18'::date, 2::integer, 47.94::real, 'Ernst Handel', 'Kirchgasse 6', 'Graz', '', '8010', 'Austria'),
    (10443::integer, 'REGGC'::text, 8::integer, '2025-02-12'::date, '2025-03-12'::date, '2025-02-14'::date, 1::integer, 13.95::real, 'Reggiani Caseifici', 'Strada Provinciale 124', 'Reggio Emilia', '', '42100', 'Italy'),
    (10444::integer, 'BERGS'::text, 3::integer, '2025-02-12'::date, '2025-03-12'::date, '2025-02-21'::date, 3::integer, 3.5::real, 'Berglunds snabbköp', 'Berguvsvägen  8', 'Luleå', '', 'S-958 22', 'Sweden'),
    (10445::integer, 'BERGS'::text, 3::integer, '2025-02-13'::date, '2025-03-13'::date, '2025-02-20'::date, 1::integer, 9.3::real, 'Berglunds snabbköp', 'Berguvsvägen  8', 'Luleå', '', 'S-958 22', 'Sweden'),
    (10446::integer, 'TOMSP'::text, 6::integer, '2025-02-14'::date, '2025-03-14'::date, '2025-02-19'::date, 1::integer, 14.68::real, 'Toms Spezialitäten', 'Luisenstr. 48', 'Münster', '', '44087', 'Germany'),
    (10447::integer, 'RICAR'::text, 4::integer, '2025-02-14'::date, '2025-03-14'::date, '2025-03-07'::date, 2::integer, 68.66::real, 'Ricardo Adocicados', 'Av. Copacabana, 267', 'Rio de Janeiro', 'RJ', '02389-890', 'Brazil'),
    (10448::integer, 'RANCH'::text, 4::integer, '2025-02-17'::date, '2025-03-17'::date, '2025-02-24'::date, 2::integer, 38.82::real, 'Rancho grande', 'Av. del Libertador 900', 'Buenos Aires', '', '1010', 'Argentina'),
    (10449::integer, 'BLONP'::text, 3::integer, '2025-02-18'::date, '2025-03-18'::date, '2025-02-27'::date, 2::integer, 53.3::real, 'Blondel père et fils', '24, place Kléber', 'Strasbourg', '', '67000', 'France'),
    (10450::integer, 'VICTE'::text, 8::integer, '2025-02-19'::date, '2025-03-19'::date, '2025-03-11'::date, 2::integer, 7.23::real, 'Victuailles en stock', '2, rue du Commerce', 'Lyon', '', '69004', 'France'),
    (10451::integer, 'QUICK'::text, 4::integer, '2025-02-19'::date, '2025-03-05'::date, '2025-03-12'::date, 3::integer, 189.09::real, 'QUICK-Stop', 'Taucherstraße 10', 'Cunewalde', '', '01307', 'Germany'),
    (10452::integer, 'SAVEA'::text, 8::integer, '2025-02-20'::date, '2025-03-20'::date, '2025-02-26'::date, 1::integer, 140.26::real, 'Save-a-lot Markets', '187 Suffolk Ln.', 'Boise', 'ID', '83720', 'USA'),
    (10453::integer, 'AROUT'::text, 1::integer, '2025-02-21'::date, '2025-03-21'::date, '2025-02-26'::date, 2::integer, 25.36::real, 'Around the Horn', 'Brook Farm Stratford St. Mary', 'Colchester', 'Essex', 'CO7 6JX', 'UK'),
    (10454::integer, 'LAMAI'::text, 4::integer, '2025-02-21'::date, '2025-03-21'::date, '2025-02-25'::date, 3::integer, 2.74::real, 'La maison d''Asie', '1 rue Alsace-Lorraine', 'Toulouse', '', '31000', 'France'),
    (10455::integer, 'WARTH'::text, 8::integer, '2025-02-24'::date, '2025-04-07'::date, '2025-03-03'::date, 2::integer, 180.45::real, 'Wartian Herkku', 'Torikatu 38', 'Oulu', '', '90110', 'Finland'),
    (10456::integer, 'KOENE'::text, 8::integer, '2025-02-25'::date, '2025-04-08'::date, '2025-02-28'::date, 2::integer, 8.12::real, 'Königlich Essen', 'Maubelstr. 90', 'Brandenburg', '', '14776', 'Germany'),
    (10457::integer, 'KOENE'::text, 2::integer, '2025-02-25'::date, '2025-03-25'::date, '2025-03-03'::date, 1::integer, 11.57::real, 'Königlich Essen', 'Maubelstr. 90', 'Brandenburg', '', '14776', 'Germany'),
    (10458::integer, 'SUPRD'::text, 7::integer, '2025-02-26'::date, '2025-03-26'::date, '2025-03-04'::date, 3::integer, 147.06::real, 'Suprêmes délices', 'Boulevard Tirou, 255', 'Charleroi', '', 'B-6000', 'Belgium'),
    (10459::integer, 'VICTE'::text, 4::integer, '2025-02-27'::date, '2025-03-27'::date, '2025-02-28'::date, 2::integer, 25.09::real, 'Victuailles en stock', '2, rue du Commerce', 'Lyon', '', '69004', 'France'),
    (10460::integer, 'FOLKO'::text, 8::integer, '2025-02-28'::date, '2025-03-28'::date, '2025-03-03'::date, 1::integer, 16.27::real, 'Folk och fä HB', 'Åkergatan 24', 'Bräcke', '', 'S-844 67', 'Sweden'),
    (10461::integer, 'LILAS'::text, 1::integer, '2025-02-28'::date, '2025-03-28'::date, '2025-03-05'::date, 3::integer, 148.61::real, 'LILA-Supermercado', 'Carrera 52 con Ave. Bolívar #65-98 Llano Largo', 'Barquisimeto', 'Lara', '3508', 'Venezuela'),
    (10462::integer, 'CONSH'::text, 2::integer, '2025-03-03'::date, '2025-03-31'::date, '2025-03-18'::date, 1::integer, 6.17::real, 'Consolidated Holdings', 'Berkeley Gardens 12  Brewery', 'London', '', 'WX1 6LT', 'UK'),
    (10463::integer, 'SUPRD'::text, 5::integer, '2025-03-04'::date, '2025-04-01'::date, '2025-03-06'::date, 3::integer, 14.78::real, 'Suprêmes délices', 'Boulevard Tirou, 255', 'Charleroi', '', 'B-6000', 'Belgium'),
    (10464::integer, 'FURIB'::text, 4::integer, '2025-03-04'::date, '2025-04-01'::date, '2025-03-14'::date, 2::integer, 89::real, 'Furia Bacalhau e Frutos do Mar', 'Jardim das rosas n. 32', 'Lisboa', '', '1675', 'Portugal'),
    (10465::integer, 'VAFFE'::text, 1::integer, '2025-03-05'::date, '2025-04-02'::date, '2025-03-14'::date, 3::integer, 145.04::real, 'Vaffeljernet', 'Smagsloget 45', 'Århus', '', '8200', 'Denmark'),
    (10466::integer, 'COMMI'::text, 4::integer, '2025-03-06'::date, '2025-04-03'::date, '2025-03-13'::date, 1::integer, 11.93::real, 'Comércio Mineiro', 'Av. dos Lusíadas, 23', 'Sao Paulo', 'SP', '05432-043', 'Brazil'),
    (10467::integer, 'MAGAA'::text, 8::integer, '2025-03-06'::date, '2025-04-03'::date, '2025-03-11'::date, 2::integer, 4.93::real, 'Magazzini Alimentari Riuniti', 'Via Ludovico il Moro 22', 'Bergamo', '', '24100', 'Italy'),
    (10468::integer, 'KOENE'::text, 3::integer, '2025-03-07'::date, '2025-04-04'::date, '2025-03-12'::date, 3::integer, 44.12::real, 'Königlich Essen', 'Maubelstr. 90', 'Brandenburg', '', '14776', 'Germany'),
    (10469::integer, 'WHITC'::text, 1::integer, '2025-03-10'::date, '2025-04-07'::date, '2025-03-14'::date, 1::integer, 60.18::real, 'White Clover Markets', '1029 - 12th Ave. S.', 'Seattle', 'WA', '98124', 'USA'),
    (10470::integer, 'BONAP'::text, 4::integer, '2025-03-11'::date, '2025-04-08'::date, '2025-03-14'::date, 2::integer, 64.56::real, 'Bon app''', '12, rue des Bouchers', 'Marseille', '', '13008', 'France'),
    (10471::integer, 'BSBEV'::text, 2::integer, '2025-03-11'::date, '2025-04-08'::date, '2025-03-18'::date, 3::integer, 45.59::real, 'B''s Beverages', 'Fauntleroy Circus', 'London', '', 'EC2 5NT', 'UK'),
    (10472::integer, 'SEVES'::text, 8::integer, '2025-03-12'::date, '2025-04-09'::date, '2025-03-19'::date, 1::integer, 4.2::real, 'Seven Seas Imports', '90 Wadhurst Rd.', 'London', '', 'OX15 4NB', 'UK'),
    (10473::integer, 'ISLAT'::text, 1::integer, '2025-03-13'::date, '2025-03-27'::date, '2025-03-21'::date, 3::integer, 16.37::real, 'Island Trading', 'Garden House Crowther Way', 'Cowes', 'Isle of Wight', 'PO31 7PJ', 'UK'),
    (10474::integer, 'PERIC'::text, 5::integer, '2025-03-13'::date, '2025-04-10'::date, '2025-03-21'::date, 2::integer, 83.49::real, 'Pericles Comidas clásicas', 'Calle Dr. Jorge Cash 321', 'México D.F.', '', '05033', 'Mexico'),
    (10475::integer, 'SUPRD'::text, 9::integer, '2025-03-14'::date, '2025-04-11'::date, '2025-04-04'::date, 1::integer, 68.52::real, 'Suprêmes délices', 'Boulevard Tirou, 255', 'Charleroi', '', 'B-6000', 'Belgium'),
    (10476::integer, 'HILAA'::text, 8::integer, '2025-03-17'::date, '2025-04-14'::date, '2025-03-24'::date, 3::integer, 4.41::real, 'HILARION-Abastos', 'Carrera 22 con Ave. Carlos Soublette #8-35', 'San Cristóbal', 'Táchira', '5022', 'Venezuela'),
    (10477::integer, 'PRINI'::text, 5::integer, '2025-03-17'::date, '2025-04-14'::date, '2025-03-25'::date, 2::integer, 13.02::real, 'Princesa Isabel Vinhos', 'Estrada da saúde n. 58', 'Lisboa', '', '1756', 'Portugal'),
    (10478::integer, 'VICTE'::text, 2::integer, '2025-03-18'::date, '2025-04-01'::date, '2025-03-26'::date, 3::integer, 4.81::real, 'Victuailles en stock', '2, rue du Commerce', 'Lyon', '', '69004', 'France'),
    (10479::integer, 'RATTC'::text, 3::integer, '2025-03-19'::date, '2025-04-16'::date, '2025-03-21'::date, 3::integer, 708.95::real, 'Rattlesnake Canyon Grocery', '2817 Milton Dr.', 'Albuquerque', 'NM', '87110', 'USA'),
    (10480::integer, 'FOLIG'::text, 6::integer, '2025-03-20'::date, '2025-04-17'::date, '2025-03-24'::date, 2::integer, 1.35::real, 'Folies gourmandes', '184, chaussée de Tournai', 'Lille', '', '59000', 'France'),
    (10481::integer, 'RICAR'::text, 8::integer, '2025-03-20'::date, '2025-04-17'::date, '2025-03-25'::date, 2::integer, 64.33::real, 'Ricardo Adocicados', 'Av. Copacabana, 267', 'Rio de Janeiro', 'RJ', '02389-890', 'Brazil'),
    (10482::integer, 'LAZYK'::text, 1::integer, '2025-03-21'::date, '2025-04-18'::date, '2025-04-10'::date, 3::integer, 7.48::real, 'Lazy K Kountry Store', '12 Orchestra Terrace', 'Walla Walla', 'WA', '99362', 'USA'),
    (10483::integer, 'WHITC'::text, 7::integer, '2025-03-24'::date, '2025-04-21'::date, '2025-04-25'::date, 2::integer, 15.28::real, 'White Clover Markets', '1029 - 12th Ave. S.', 'Seattle', 'WA', '98124', 'USA'),
    (10484::integer, 'BSBEV'::text, 3::integer, '2025-03-24'::date, '2025-04-21'::date, '2025-04-01'::date, 3::integer, 6.88::real, 'B''s Beverages', 'Fauntleroy Circus', 'London', '', 'EC2 5NT', 'UK'),
    (10485::integer, 'LINOD'::text, 4::integer, '2025-03-25'::date, '2025-04-08'::date, '2025-03-31'::date, 2::integer, 64.45::real, 'LINO-Delicateses', 'Ave. 5 de Mayo Porlamar', 'I. de Margarita', 'Nueva Esparta', '4980', 'Venezuela'),
    (10486::integer, 'HILAA'::text, 1::integer, '2025-03-26'::date, '2025-04-23'::date, '2025-04-02'::date, 2::integer, 30.53::real, 'HILARION-Abastos', 'Carrera 22 con Ave. Carlos Soublette #8-35', 'San Cristóbal', 'Táchira', '5022', 'Venezuela'),
    (10487::integer, 'QUEEN'::text, 2::integer, '2025-03-26'::date, '2025-04-23'::date, '2025-03-28'::date, 2::integer, 71.07::real, 'Queen Cozinha', 'Alameda dos Canàrios, 891', 'Sao Paulo', 'SP', '05487-020', 'Brazil'),
    (10488::integer, 'FRANK'::text, 8::integer, '2025-03-27'::date, '2025-04-24'::date, '2025-04-02'::date, 2::integer, 4.93::real, 'Frankenversand', 'Berliner Platz 43', 'München', '', '80805', 'Germany'),
    (10489::integer, 'PICCO'::text, 6::integer, '2025-03-28'::date, '2025-04-25'::date, '2025-04-09'::date, 2::integer, 5.29::real, 'Piccolo und mehr', 'Geislweg 14', 'Salzburg', '', '5020', 'Austria'),
    (10490::integer, 'HILAA'::text, 7::integer, '2025-03-31'::date, '2025-04-28'::date, '2025-04-03'::date, 2::integer, 210.19::real, 'HILARION-Abastos', 'Carrera 22 con Ave. Carlos Soublette #8-35', 'San Cristóbal', 'Táchira', '5022', 'Venezuela'),
    (10491::integer, 'FURIB'::text, 8::integer, '2025-03-31'::date, '2025-04-28'::date, '2025-04-08'::date, 3::integer, 16.96::real, 'Furia Bacalhau e Frutos do Mar', 'Jardim das rosas n. 32', 'Lisboa', '', '1675', 'Portugal'),
    (10492::integer, 'BOTTM'::text, 3::integer, '2025-04-01'::date, '2025-04-29'::date, '2025-04-11'::date, 1::integer, 62.89::real, 'Bottom-Dollar Markets', '23 Tsawassen Blvd.', 'Tsawassen', 'BC', 'T2F 8M4', 'Canada'),
    (10493::integer, 'LAMAI'::text, 4::integer, '2025-04-02'::date, '2025-04-30'::date, '2025-04-10'::date, 3::integer, 10.64::real, 'La maison d''Asie', '1 rue Alsace-Lorraine', 'Toulouse', '', '31000', 'France'),
    (10494::integer, 'COMMI'::text, 4::integer, '2025-04-02'::date, '2025-04-30'::date, '2025-04-09'::date, 2::integer, 65.99::real, 'Comércio Mineiro', 'Av. dos Lusíadas, 23', 'Sao Paulo', 'SP', '05432-043', 'Brazil'),
    (10495::integer, 'LAUGB'::text, 3::integer, '2025-04-03'::date, '2025-05-01'::date, '2025-04-11'::date, 3::integer, 4.65::real, 'Laughing Bacchus Wine Cellars', '2319 Elm St.', 'Vancouver', 'BC', 'V3F 2K1', 'Canada'),
    (10496::integer, 'TRADH'::text, 7::integer, '2025-04-04'::date, '2025-05-02'::date, '2025-04-07'::date, 2::integer, 46.77::real, 'Tradiçao Hipermercados', 'Av. Inês de Castro, 414', 'Sao Paulo', 'SP', '05634-030', 'Brazil'),
    (10497::integer, 'LEHMS'::text, 7::integer, '2025-04-04'::date, '2025-05-02'::date, '2025-04-07'::date, 1::integer, 36.21::real, 'Lehmanns Marktstand', 'Magazinweg 7', 'Frankfurt a.M.', '', '60528', 'Germany'),
    (10498::integer, 'HILAA'::text, 8::integer, '2025-04-07'::date, '2025-05-05'::date, '2025-04-11'::date, 2::integer, 29.75::real, 'HILARION-Abastos', 'Carrera 22 con Ave. Carlos Soublette #8-35', 'San Cristóbal', 'Táchira', '5022', 'Venezuela'),
    (10499::integer, 'LILAS'::text, 4::integer, '2025-04-08'::date, '2025-05-06'::date, '2025-04-16'::date, 2::integer, 102.02::real, 'LILA-Supermercado', 'Carrera 52 con Ave. Bolívar #65-98 Llano Largo', 'Barquisimeto', 'Lara', '3508', 'Venezuela'),
    (10500::integer, 'LAMAI'::text, 6::integer, '2025-04-09'::date, '2025-05-07'::date, '2025-04-17'::date, 1::integer, 42.68::real, 'La maison d''Asie', '1 rue Alsace-Lorraine', 'Toulouse', '', '31000', 'France'),
    (10501::integer, 'BLAUS'::text, 9::integer, '2025-04-09'::date, '2025-05-07'::date, '2025-04-16'::date, 3::integer, 8.85::real, 'Blauer See Delikatessen', 'Forsterstr. 57', 'Mannheim', '', '68306', 'Germany'),
    (10502::integer, 'PERIC'::text, 2::integer, '2025-04-10'::date, '2025-05-08'::date, '2025-04-29'::date, 1::integer, 69.32::real, 'Pericles Comidas clásicas', 'Calle Dr. Jorge Cash 321', 'México D.F.', '', '05033', 'Mexico'),
    (10503::integer, 'HUNGO'::text, 6::integer, '2025-04-11'::date, '2025-05-09'::date, '2025-04-16'::date, 2::integer, 16.74::real, 'Hungry Owl All-Night Grocers', '8 Johnstown Road', 'Cork', 'Co. Cork', '', 'Ireland'),
    (10504::integer, 'WHITC'::text, 4::integer, '2025-04-11'::date, '2025-05-09'::date, '2025-04-18'::date, 3::integer, 59.13::real, 'White Clover Markets', '1029 - 12th Ave. S.', 'Seattle', 'WA', '98124', 'USA'),
    (10505::integer, 'MEREP'::text, 3::integer, '2025-04-14'::date, '2025-05-12'::date, '2025-04-21'::date, 3::integer, 7.13::real, 'Mère Paillarde', '43 rue St. Laurent', 'Montréal', 'Québec', 'H1J 1C3', 'Canada'),
    (10506::integer, 'KOENE'::text, 9::integer, '2025-04-15'::date, '2025-05-13'::date, '2025-05-02'::date, 2::integer, 21.19::real, 'Königlich Essen', 'Maubelstr. 90', 'Brandenburg', '', '14776', 'Germany'),
    (10507::integer, 'ANTON'::text, 7::integer, '2025-04-15'::date, '2025-05-13'::date, '2025-04-22'::date, 1::integer, 47.45::real, 'Antonio Moreno Taquería', 'Mataderos  2312', 'México D.F.', '', '05023', 'Mexico'),
    (10508::integer, 'OTTIK'::text, 1::integer, '2025-04-16'::date, '2025-05-14'::date, '2025-05-13'::date, 2::integer, 4.99::real, 'Ottilies Käseladen', 'Mehrheimerstr. 369', 'Köln', '', '50739', 'Germany'),
    (10509::integer, 'BLAUS'::text, 4::integer, '2025-04-17'::date, '2025-05-15'::date, '2025-04-29'::date, 1::integer, 0.15::real, 'Blauer See Delikatessen', 'Forsterstr. 57', 'Mannheim', '', '68306', 'Germany'),
    (10510::integer, 'SAVEA'::text, 6::integer, '2025-04-18'::date, '2025-05-16'::date, '2025-04-28'::date, 3::integer, 367.63::real, 'Save-a-lot Markets', '187 Suffolk Ln.', 'Boise', 'ID', '83720', 'USA'),
    (10511::integer, 'BONAP'::text, 4::integer, '2025-04-18'::date, '2025-05-16'::date, '2025-04-21'::date, 3::integer, 350.64::real, 'Bon app''', '12, rue des Bouchers', 'Marseille', '', '13008', 'France'),
    (10512::integer, 'FAMIA'::text, 7::integer, '2025-04-21'::date, '2025-05-19'::date, '2025-04-24'::date, 2::integer, 3.53::real, 'Familia Arquibaldo', 'Rua Orós, 92', 'Sao Paulo', 'SP', '05442-030', 'Brazil'),
    (10513::integer, 'WANDK'::text, 7::integer, '2025-04-22'::date, '2025-06-03'::date, '2025-04-28'::date, 1::integer, 105.65::real, 'Die Wandernde Kuh', 'Adenauerallee 900', 'Stuttgart', '', '70563', 'Germany'),
    (10514::integer, 'ERNSH'::text, 3::integer, '2025-04-22'::date, '2025-05-20'::date, '2025-05-16'::date, 2::integer, 789.95::real, 'Ernst Handel', 'Kirchgasse 6', 'Graz', '', '8010', 'Austria'),
    (10515::integer, 'QUICK'::text, 2::integer, '2025-04-23'::date, '2025-05-07'::date, '2025-05-23'::date, 1::integer, 204.47::real, 'QUICK-Stop', 'Taucherstraße 10', 'Cunewalde', '', '01307', 'Germany'),
    (10516::integer, 'HUNGO'::text, 2::integer, '2025-04-24'::date, '2025-05-22'::date, '2025-05-01'::date, 3::integer, 62.78::real, 'Hungry Owl All-Night Grocers', '8 Johnstown Road', 'Cork', 'Co. Cork', '', 'Ireland'),
    (10517::integer, 'NORTS'::text, 3::integer, '2025-04-24'::date, '2025-05-22'::date, '2025-04-29'::date, 3::integer, 32.07::real, 'North/South', 'South House 300 Queensbridge', 'London', '', 'SW7 1RZ', 'UK'),
    (10518::integer, 'TORTU'::text, 4::integer, '2025-04-25'::date, '2025-05-09'::date, '2025-05-05'::date, 2::integer, 218.15::real, 'Tortuga Restaurante', 'Avda. Azteca 123', 'México D.F.', '', '05033', 'Mexico'),
    (10519::integer, 'CHOPS'::text, 6::integer, '2025-04-28'::date, '2025-05-26'::date, '2025-05-01'::date, 3::integer, 91.76::real, 'Chop-suey Chinese', 'Hauptstr. 31', 'Bern', '', '3012', 'Switzerland'),
    (10520::integer, 'SANTG'::text, 7::integer, '2025-04-29'::date, '2025-05-27'::date, '2025-05-01'::date, 1::integer, 13.37::real, 'Santé Gourmet', 'Erling Skakkes gate 78', 'Stavern', '', '4110', 'Norway'),
    (10521::integer, 'CACTU'::text, 8::integer, '2025-04-29'::date, '2025-05-27'::date, '2025-05-02'::date, 2::integer, 17.22::real, 'Cactus Comidas para llevar', 'Cerrito 333', 'Buenos Aires', '', '1010', 'Argentina'),
    (10522::integer, 'LEHMS'::text, 4::integer, '2025-04-30'::date, '2025-05-28'::date, '2025-05-06'::date, 1::integer, 45.33::real, 'Lehmanns Marktstand', 'Magazinweg 7', 'Frankfurt a.M.', '', '60528', 'Germany'),
    (10523::integer, 'SEVES'::text, 7::integer, '2025-05-01'::date, '2025-05-29'::date, '2025-05-30'::date, 2::integer, 77.63::real, 'Seven Seas Imports', '90 Wadhurst Rd.', 'London', '', 'OX15 4NB', 'UK'),
    (10524::integer, 'BERGS'::text, 1::integer, '2025-05-01'::date, '2025-05-29'::date, '2025-05-07'::date, 2::integer, 244.79::real, 'Berglunds snabbköp', 'Berguvsvägen  8', 'Luleå', '', 'S-958 22', 'Sweden'),
    (10525::integer, 'BONAP'::text, 1::integer, '2025-05-02'::date, '2025-05-30'::date, '2025-05-23'::date, 2::integer, 11.06::real, 'Bon app''', '12, rue des Bouchers', 'Marseille', '', '13008', 'France'),
    (10526::integer, 'WARTH'::text, 4::integer, '2025-05-05'::date, '2025-06-02'::date, '2025-05-15'::date, 2::integer, 58.59::real, 'Wartian Herkku', 'Torikatu 38', 'Oulu', '', '90110', 'Finland'),
    (10527::integer, 'QUICK'::text, 7::integer, '2025-05-05'::date, '2025-06-02'::date, '2025-05-07'::date, 1::integer, 41.9::real, 'QUICK-Stop', 'Taucherstraße 10', 'Cunewalde', '', '01307', 'Germany'),
    (10528::integer, 'GREAL'::text, 6::integer, '2025-05-06'::date, '2025-05-20'::date, '2025-05-09'::date, 2::integer, 3.35::real, 'Great Lakes Food Market', '2732 Baker Blvd.', 'Eugene', 'OR', '97403', 'USA'),
    (10529::integer, 'MAISD'::text, 5::integer, '2025-05-07'::date, '2025-06-04'::date, '2025-05-09'::date, 2::integer, 66.69::real, 'Maison Dewey', 'Rue Joseph-Bens 532', 'Bruxelles', '', 'B-1180', 'Belgium'),
    (10530::integer, 'PICCO'::text, 3::integer, '2025-05-08'::date, '2025-06-05'::date, '2025-05-12'::date, 2::integer, 339.22::real, 'Piccolo und mehr', 'Geislweg 14', 'Salzburg', '', '5020', 'Austria'),
    (10531::integer, 'OCEAN'::text, 7::integer, '2025-05-08'::date, '2025-06-05'::date, '2025-05-19'::date, 1::integer, 8.12::real, 'Océano Atlántico Ltda.', 'Ing. Gustavo Moncada 8585 Piso 20-A', 'Buenos Aires', '', '1010', 'Argentina'),
    (10532::integer, 'EASTC'::text, 7::integer, '2025-05-09'::date, '2025-06-06'::date, '2025-05-12'::date, 3::integer, 74.46::real, 'Eastern Connection', '35 King George', 'London', '', 'WX3 6FW', 'UK'),
    (10533::integer, 'FOLKO'::text, 8::integer, '2025-05-12'::date, '2025-06-09'::date, '2025-05-22'::date, 1::integer, 188.04::real, 'Folk och fä HB', 'Åkergatan 24', 'Bräcke', '', 'S-844 67', 'Sweden'),
    (10534::integer, 'LEHMS'::text, 8::integer, '2025-05-12'::date, '2025-06-09'::date, '2025-05-14'::date, 2::integer, 27.94::real, 'Lehmanns Marktstand', 'Magazinweg 7', 'Frankfurt a.M.', '', '60528', 'Germany'),
    (10535::integer, 'ANTON'::text, 4::integer, '2025-05-13'::date, '2025-06-10'::date, '2025-05-21'::date, 1::integer, 15.64::real, 'Antonio Moreno Taquería', 'Mataderos  2312', 'México D.F.', '', '05023', 'Mexico'),
    (10536::integer, 'LEHMS'::text, 3::integer, '2025-05-14'::date, '2025-06-11'::date, '2025-06-06'::date, 2::integer, 58.88::real, 'Lehmanns Marktstand', 'Magazinweg 7', 'Frankfurt a.M.', '', '60528', 'Germany'),
    (10537::integer, 'RICSU'::text, 1::integer, '2025-05-14'::date, '2025-05-28'::date, '2025-05-19'::date, 1::integer, 78.85::real, 'Richter Supermarkt', 'Starenweg 5', 'Genève', '', '1204', 'Switzerland'),
    (10538::integer, 'BSBEV'::text, 9::integer, '2025-05-15'::date, '2025-06-12'::date, '2025-05-16'::date, 3::integer, 4.87::real, 'B''s Beverages', 'Fauntleroy Circus', 'London', '', 'EC2 5NT', 'UK'),
    (10539::integer, 'BSBEV'::text, 6::integer, '2025-05-16'::date, '2025-06-13'::date, '2025-05-23'::date, 3::integer, 12.36::real, 'B''s Beverages', 'Fauntleroy Circus', 'London', '', 'EC2 5NT', 'UK'),
    (10540::integer, 'QUICK'::text, 3::integer, '2025-05-19'::date, '2025-06-16'::date, '2025-06-13'::date, 3::integer, 1007.64::real, 'QUICK-Stop', 'Taucherstraße 10', 'Cunewalde', '', '01307', 'Germany'),
    (10541::integer, 'HANAR'::text, 2::integer, '2025-05-19'::date, '2025-06-16'::date, '2025-05-29'::date, 1::integer, 68.65::real, 'Hanari Carnes', 'Rua do Paço, 67', 'Rio de Janeiro', 'RJ', '05454-876', 'Brazil'),
    (10542::integer, 'KOENE'::text, 1::integer, '2025-05-20'::date, '2025-06-17'::date, '2025-05-26'::date, 3::integer, 10.95::real, 'Königlich Essen', 'Maubelstr. 90', 'Brandenburg', '', '14776', 'Germany'),
    (10543::integer, 'LILAS'::text, 8::integer, '2025-05-21'::date, '2025-06-18'::date, '2025-05-23'::date, 2::integer, 48.17::real, 'LILA-Supermercado', 'Carrera 52 con Ave. Bolívar #65-98 Llano Largo', 'Barquisimeto', 'Lara', '3508', 'Venezuela'),
    (10544::integer, 'LONEP'::text, 4::integer, '2025-05-21'::date, '2025-06-18'::date, '2025-05-30'::date, 1::integer, 24.91::real, 'Lonesome Pine Restaurant', '89 Chiaroscuro Rd.', 'Portland', 'OR', '97219', 'USA'),
    (10545::integer, 'LAZYK'::text, 8::integer, '2025-05-22'::date, '2025-06-19'::date, '2025-06-26'::date, 2::integer, 11.92::real, 'Lazy K Kountry Store', '12 Orchestra Terrace', 'Walla Walla', 'WA', '99362', 'USA'),
    (10546::integer, 'VICTE'::text, 1::integer, '2025-05-23'::date, '2025-06-20'::date, '2025-05-27'::date, 3::integer, 194.72::real, 'Victuailles en stock', '2, rue du Commerce', 'Lyon', '', '69004', 'France'),
    (10547::integer, 'SEVES'::text, 3::integer, '2025-05-23'::date, '2025-06-20'::date, '2025-06-02'::date, 2::integer, 178.43::real, 'Seven Seas Imports', '90 Wadhurst Rd.', 'London', '', 'OX15 4NB', 'UK'),
    (10548::integer, 'TOMSP'::text, 3::integer, '2025-05-26'::date, '2025-06-23'::date, '2025-06-02'::date, 2::integer, 1.43::real, 'Toms Spezialitäten', 'Luisenstr. 48', 'Münster', '', '44087', 'Germany'),
    (10549::integer, 'QUICK'::text, 5::integer, '2025-05-27'::date, '2025-06-10'::date, '2025-05-30'::date, 1::integer, 171.24::real, 'QUICK-Stop', 'Taucherstraße 10', 'Cunewalde', '', '01307', 'Germany'),
    (10550::integer, 'GODOS'::text, 7::integer, '2025-05-28'::date, '2025-06-25'::date, '2025-06-06'::date, 3::integer, 4.32::real, 'Godos Cocina Típica', 'C/ Romero, 33', 'Sevilla', '', '41101', 'Spain'),
    (10551::integer, 'FURIB'::text, 4::integer, '2025-05-28'::date, '2025-07-09'::date, '2025-06-06'::date, 3::integer, 72.95::real, 'Furia Bacalhau e Frutos do Mar', 'Jardim das rosas n. 32', 'Lisboa', '', '1675', 'Portugal'),
    (10552::integer, 'HILAA'::text, 2::integer, '2025-05-29'::date, '2025-06-26'::date, '2025-06-05'::date, 1::integer, 83.22::real, 'HILARION-Abastos', 'Carrera 22 con Ave. Carlos Soublette #8-35', 'San Cristóbal', 'Táchira', '5022', 'Venezuela'),
    (10553::integer, 'WARTH'::text, 2::integer, '2025-05-30'::date, '2025-06-27'::date, '2025-06-03'::date, 2::integer, 149.49::real, 'Wartian Herkku', 'Torikatu 38', 'Oulu', '', '90110', 'Finland'),
    (10554::integer, 'OTTIK'::text, 4::integer, '2025-05-30'::date, '2025-06-27'::date, '2025-06-05'::date, 3::integer, 120.97::real, 'Ottilies Käseladen', 'Mehrheimerstr. 369', 'Köln', '', '50739', 'Germany'),
    (10555::integer, 'SAVEA'::text, 6::integer, '2025-06-02'::date, '2025-06-30'::date, '2025-06-04'::date, 3::integer, 252.49::real, 'Save-a-lot Markets', '187 Suffolk Ln.', 'Boise', 'ID', '83720', 'USA'),
    (10556::integer, 'SIMOB'::text, 2::integer, '2025-06-03'::date, '2025-07-15'::date, '2025-06-13'::date, 1::integer, 9.8::real, 'Simons bistro', 'Vinbæltet 34', 'Kobenhavn', '', '1734', 'Denmark'),
    (10557::integer, 'LEHMS'::text, 9::integer, '2025-06-03'::date, '2025-06-17'::date, '2025-06-06'::date, 2::integer, 96.72::real, 'Lehmanns Marktstand', 'Magazinweg 7', 'Frankfurt a.M.', '', '60528', 'Germany'),
    (10558::integer, 'AROUT'::text, 1::integer, '2025-06-04'::date, '2025-07-02'::date, '2025-06-10'::date, 2::integer, 72.97::real, 'Around the Horn', 'Brook Farm Stratford St. Mary', 'Colchester', 'Essex', 'CO7 6JX', 'UK'),
    (10559::integer, 'BLONP'::text, 6::integer, '2025-06-05'::date, '2025-07-03'::date, '2025-06-13'::date, 1::integer, 8.05::real, 'Blondel père et fils', '24, place Kléber', 'Strasbourg', '', '67000', 'France'),
    (10560::integer, 'FRANK'::text, 8::integer, '2025-06-06'::date, '2025-07-04'::date, '2025-06-09'::date, 1::integer, 36.65::real, 'Frankenversand', 'Berliner Platz 43', 'München', '', '80805', 'Germany'),
    (10561::integer, 'FOLKO'::text, 2::integer, '2025-06-06'::date, '2025-07-04'::date, '2025-06-09'::date, 2::integer, 242.21::real, 'Folk och fä HB', 'Åkergatan 24', 'Bräcke', '', 'S-844 67', 'Sweden'),
    (10562::integer, 'REGGC'::text, 1::integer, '2025-06-09'::date, '2025-07-07'::date, '2025-06-12'::date, 1::integer, 22.95::real, 'Reggiani Caseifici', 'Strada Provinciale 124', 'Reggio Emilia', '', '42100', 'Italy'),
    (10563::integer, 'RICAR'::text, 2::integer, '2025-06-10'::date, '2025-07-22'::date, '2025-06-24'::date, 2::integer, 60.43::real, 'Ricardo Adocicados', 'Av. Copacabana, 267', 'Rio de Janeiro', 'RJ', '02389-890', 'Brazil'),
    (10564::integer, 'RATTC'::text, 4::integer, '2025-06-10'::date, '2025-07-08'::date, '2025-06-16'::date, 3::integer, 13.75::real, 'Rattlesnake Canyon Grocery', '2817 Milton Dr.', 'Albuquerque', 'NM', '87110', 'USA'),
    (10565::integer, 'MEREP'::text, 8::integer, '2025-06-11'::date, '2025-07-09'::date, '2025-06-18'::date, 2::integer, 7.15::real, 'Mère Paillarde', '43 rue St. Laurent', 'Montréal', 'Québec', 'H1J 1C3', 'Canada'),
    (10566::integer, 'BLONP'::text, 9::integer, '2025-06-12'::date, '2025-07-10'::date, '2025-06-18'::date, 1::integer, 88.4::real, 'Blondel père et fils', '24, place Kléber', 'Strasbourg', '', '67000', 'France'),
    (10567::integer, 'HUNGO'::text, 1::integer, '2025-06-12'::date, '2025-07-10'::date, '2025-06-17'::date, 1::integer, 33.97::real, 'Hungry Owl All-Night Grocers', '8 Johnstown Road', 'Cork', 'Co. Cork', '', 'Ireland'),
    (10568::integer, 'GALED'::text, 3::integer, '2025-06-13'::date, '2025-07-11'::date, '2025-07-09'::date, 3::integer, 6.54::real, 'Galería del gastronómo', 'Rambla de Cataluña, 23', 'Barcelona', '', '8022', 'Spain'),
    (10569::integer, 'RATTC'::text, 5::integer, '2025-06-16'::date, '2025-07-14'::date, '2025-07-11'::date, 1::integer, 58.98::real, 'Rattlesnake Canyon Grocery', '2817 Milton Dr.', 'Albuquerque', 'NM', '87110', 'USA'),
    (10570::integer, 'MEREP'::text, 3::integer, '2025-06-17'::date, '2025-07-15'::date, '2025-06-19'::date, 3::integer, 188.99::real, 'Mère Paillarde', '43 rue St. Laurent', 'Montréal', 'Québec', 'H1J 1C3', 'Canada'),
    (10571::integer, 'ERNSH'::text, 8::integer, '2025-06-17'::date, '2025-07-29'::date, '2025-07-04'::date, 3::integer, 26.06::real, 'Ernst Handel', 'Kirchgasse 6', 'Graz', '', '8010', 'Austria'),
    (10572::integer, 'BERGS'::text, 3::integer, '2025-06-18'::date, '2025-07-16'::date, '2025-06-25'::date, 2::integer, 116.43::real, 'Berglunds snabbköp', 'Berguvsvägen  8', 'Luleå', '', 'S-958 22', 'Sweden'),
    (10573::integer, 'ANTON'::text, 7::integer, '2025-06-19'::date, '2025-07-17'::date, '2025-06-20'::date, 3::integer, 84.84::real, 'Antonio Moreno Taquería', 'Mataderos  2312', 'México D.F.', '', '05023', 'Mexico'),
    (10574::integer, 'TRAIH'::text, 4::integer, '2025-06-19'::date, '2025-07-17'::date, '2025-06-30'::date, 2::integer, 37.6::real, 'Trail''s Head Gourmet Provisioners', '722 DaVinci Blvd.', 'Kirkland', 'WA', '98034', 'USA'),
    (10575::integer, 'MORGK'::text, 5::integer, '2025-06-20'::date, '2025-07-04'::date, '2025-06-30'::date, 1::integer, 127.34::real, 'Morgenstern Gesundkost', 'Heerstr. 22', 'Leipzig', '', '04179', 'Germany'),
    (10576::integer, 'TORTU'::text, 3::integer, '2025-06-23'::date, '2025-07-07'::date, '2025-06-30'::date, 3::integer, 18.56::real, 'Tortuga Restaurante', 'Avda. Azteca 123', 'México D.F.', '', '05033', 'Mexico'),
    (10577::integer, 'TRAIH'::text, 9::integer, '2025-06-23'::date, '2025-08-04'::date, '2025-06-30'::date, 2::integer, 25.41::real, 'Trail''s Head Gourmet Provisioners', '722 DaVinci Blvd.', 'Kirkland', 'WA', '98034', 'USA'),
    (10578::integer, 'BSBEV'::text, 4::integer, '2025-06-24'::date, '2025-07-22'::date, '2025-07-25'::date, 3::integer, 29.6::real, 'B''s Beverages', 'Fauntleroy Circus', 'London', '', 'EC2 5NT', 'UK'),
    (10579::integer, 'LETSS'::text, 1::integer, '2025-06-25'::date, '2025-07-23'::date, '2025-07-04'::date, 2::integer, 13.73::real, 'Let''s Stop N Shop', '87 Polk St. Suite 5', 'San Francisco', 'CA', '94117', 'USA'),
    (10580::integer, 'OTTIK'::text, 4::integer, '2025-06-26'::date, '2025-07-24'::date, '2025-07-01'::date, 3::integer, 75.89::real, 'Ottilies Käseladen', 'Mehrheimerstr. 369', 'Köln', '', '50739', 'Germany'),
    (10581::integer, 'FAMIA'::text, 3::integer, '2025-06-26'::date, '2025-07-24'::date, '2025-07-02'::date, 1::integer, 3.01::real, 'Familia Arquibaldo', 'Rua Orós, 92', 'Sao Paulo', 'SP', '05442-030', 'Brazil'),
    (10582::integer, 'BLAUS'::text, 3::integer, '2025-06-27'::date, '2025-07-25'::date, '2025-07-14'::date, 2::integer, 27.71::real, 'Blauer See Delikatessen', 'Forsterstr. 57', 'Mannheim', '', '68306', 'Germany'),
    (10583::integer, 'WARTH'::text, 2::integer, '2025-06-30'::date, '2025-07-28'::date, '2025-07-04'::date, 2::integer, 7.28::real, 'Wartian Herkku', 'Torikatu 38', 'Oulu', '', '90110', 'Finland'),
    (10584::integer, 'BLONP'::text, 4::integer, '2025-06-30'::date, '2025-07-28'::date, '2025-07-04'::date, 1::integer, 59.14::real, 'Blondel père et fils', '24, place Kléber', 'Strasbourg', '', '67000', 'France'),
    (10585::integer, 'WELLI'::text, 7::integer, '2025-07-01'::date, '2025-07-29'::date, '2025-07-10'::date, 1::integer, 13.41::real, 'Wellington Importadora', 'Rua do Mercado, 12', 'Resende', 'SP', '08737-363', 'Brazil'),
    (10586::integer, 'REGGC'::text, 9::integer, '2025-07-02'::date, '2025-07-30'::date, '2025-07-09'::date, 1::integer, 0.48::real, 'Reggiani Caseifici', 'Strada Provinciale 124', 'Reggio Emilia', '', '42100', 'Italy'),
    (10587::integer, 'QUEDE'::text, 1::integer, '2025-07-02'::date, '2025-07-30'::date, '2025-07-09'::date, 1::integer, 62.52::real, 'Que Delícia', 'Rua da Panificadora, 12', 'Rio de Janeiro', 'RJ', '02389-673', 'Brazil'),
    (10588::integer, 'QUICK'::text, 2::integer, '2025-07-03'::date, '2025-07-31'::date, '2025-07-10'::date, 3::integer, 194.67::real, 'QUICK-Stop', 'Taucherstraße 10', 'Cunewalde', '', '01307', 'Germany'),
    (10589::integer, 'GREAL'::text, 8::integer, '2025-07-04'::date, '2025-08-01'::date, '2025-07-14'::date, 2::integer, 4.42::real, 'Great Lakes Food Market', '2732 Baker Blvd.', 'Eugene', 'OR', '97403', 'USA'),
    (10590::integer, 'MEREP'::text, 4::integer, '2025-07-07'::date, '2025-08-04'::date, '2025-07-14'::date, 3::integer, 44.77::real, 'Mère Paillarde', '43 rue St. Laurent', 'Montréal', 'Québec', 'H1J 1C3', 'Canada'),
    (10591::integer, 'VAFFE'::text, 1::integer, '2025-07-07'::date, '2025-07-21'::date, '2025-07-16'::date, 1::integer, 55.92::real, 'Vaffeljernet', 'Smagsloget 45', 'Århus', '', '8200', 'Denmark'),
    (10592::integer, 'LEHMS'::text, 3::integer, '2025-07-08'::date, '2025-08-05'::date, '2025-07-16'::date, 1::integer, 32.1::real, 'Lehmanns Marktstand', 'Magazinweg 7', 'Frankfurt a.M.', '', '60528', 'Germany'),
    (10593::integer, 'LEHMS'::text, 7::integer, '2025-07-09'::date, '2025-08-06'::date, '2025-08-13'::date, 2::integer, 174.2::real, 'Lehmanns Marktstand', 'Magazinweg 7', 'Frankfurt a.M.', '', '60528', 'Germany'),
    (10594::integer, 'OLDWO'::text, 3::integer, '2025-07-09'::date, '2025-08-06'::date, '2025-07-16'::date, 2::integer, 5.24::real, 'Old World Delicatessen', '2743 Bering St.', 'Anchorage', 'AK', '99508', 'USA'),
    (10595::integer, 'ERNSH'::text, 2::integer, '2025-07-10'::date, '2025-08-07'::date, '2025-07-14'::date, 1::integer, 96.78::real, 'Ernst Handel', 'Kirchgasse 6', 'Graz', '', '8010', 'Austria'),
    (10596::integer, 'WHITC'::text, 8::integer, '2025-07-11'::date, '2025-08-08'::date, '2025-08-12'::date, 1::integer, 16.34::real, 'White Clover Markets', '1029 - 12th Ave. S.', 'Seattle', 'WA', '98124', 'USA'),
    (10597::integer, 'PICCO'::text, 7::integer, '2025-07-11'::date, '2025-08-08'::date, '2025-07-18'::date, 3::integer, 35.12::real, 'Piccolo und mehr', 'Geislweg 14', 'Salzburg', '', '5020', 'Austria'),
    (10598::integer, 'RATTC'::text, 1::integer, '2025-07-14'::date, '2025-08-11'::date, '2025-07-18'::date, 3::integer, 44.42::real, 'Rattlesnake Canyon Grocery', '2817 Milton Dr.', 'Albuquerque', 'NM', '87110', 'USA'),
    (10599::integer, 'BSBEV'::text, 6::integer, '2025-07-15'::date, '2025-08-26'::date, '2025-07-21'::date, 3::integer, 29.98::real, 'B''s Beverages', 'Fauntleroy Circus', 'London', '', 'EC2 5NT', 'UK'),
    (10600::integer, 'HUNGC'::text, 4::integer, '2025-07-16'::date, '2025-08-13'::date, '2025-07-21'::date, 1::integer, 45.13::real, 'Hungry Coyote Import Store', 'City Center Plaza 516 Main St.', 'Elgin', 'OR', '97827', 'USA'),
    (10601::integer, 'HILAA'::text, 7::integer, '2025-07-16'::date, '2025-08-27'::date, '2025-07-22'::date, 1::integer, 58.3::real, 'HILARION-Abastos', 'Carrera 22 con Ave. Carlos Soublette #8-35', 'San Cristóbal', 'Táchira', '5022', 'Venezuela'),
    (10602::integer, 'VAFFE'::text, 8::integer, '2025-07-17'::date, '2025-08-14'::date, '2025-07-22'::date, 2::integer, 2.92::real, 'Vaffeljernet', 'Smagsloget 45', 'Århus', '', '8200', 'Denmark'),
    (10603::integer, 'SAVEA'::text, 8::integer, '2025-07-18'::date, '2025-08-15'::date, '2025-08-08'::date, 2::integer, 48.77::real, 'Save-a-lot Markets', '187 Suffolk Ln.', 'Boise', 'ID', '83720', 'USA'),
    (10604::integer, 'FURIB'::text, 1::integer, '2025-07-18'::date, '2025-08-15'::date, '2025-07-29'::date, 1::integer, 7.46::real, 'Furia Bacalhau e Frutos do Mar', 'Jardim das rosas n. 32', 'Lisboa', '', '1675', 'Portugal'),
    (10605::integer, 'MEREP'::text, 1::integer, '2025-07-21'::date, '2025-08-18'::date, '2025-07-29'::date, 2::integer, 379.13::real, 'Mère Paillarde', '43 rue St. Laurent', 'Montréal', 'Québec', 'H1J 1C3', 'Canada'),
    (10606::integer, 'TRADH'::text, 4::integer, '2025-07-22'::date, '2025-08-19'::date, '2025-07-31'::date, 3::integer, 79.4::real, 'Tradiçao Hipermercados', 'Av. Inês de Castro, 414', 'Sao Paulo', 'SP', '05634-030', 'Brazil'),
    (10607::integer, 'SAVEA'::text, 5::integer, '2025-07-22'::date, '2025-08-19'::date, '2025-07-25'::date, 1::integer, 200.24::real, 'Save-a-lot Markets', '187 Suffolk Ln.', 'Boise', 'ID', '83720', 'USA'),
    (10608::integer, 'TOMSP'::text, 4::integer, '2025-07-23'::date, '2025-08-20'::date, '2025-08-01'::date, 2::integer, 27.79::real, 'Toms Spezialitäten', 'Luisenstr. 48', 'Münster', '', '44087', 'Germany'),
    (10609::integer, 'DUMON'::text, 7::integer, '2025-07-24'::date, '2025-08-21'::date, '2025-07-30'::date, 2::integer, 1.85::real, 'Du monde entier', '67, rue des Cinquante Otages', 'Nantes', '', '44000', 'France'),
    (10610::integer, 'LAMAI'::text, 8::integer, '2025-07-25'::date, '2025-08-22'::date, '2025-08-06'::date, 1::integer, 26.78::real, 'La maison d''Asie', '1 rue Alsace-Lorraine', 'Toulouse', '', '31000', 'France'),
    (10611::integer, 'WOLZA'::text, 6::integer, '2025-07-25'::date, '2025-08-22'::date, '2025-08-01'::date, 2::integer, 80.65::real, 'Wolski Zajazd', 'ul. Filtrowa 68', 'Warszawa', '', '01-012', 'Poland'),
    (10612::integer, 'SAVEA'::text, 1::integer, '2025-07-28'::date, '2025-08-25'::date, '2025-08-01'::date, 2::integer, 544.08::real, 'Save-a-lot Markets', '187 Suffolk Ln.', 'Boise', 'ID', '83720', 'USA'),
    (10613::integer, 'HILAA'::text, 4::integer, '2025-07-29'::date, '2025-08-26'::date, '2025-08-01'::date, 2::integer, 8.11::real, 'HILARION-Abastos', 'Carrera 22 con Ave. Carlos Soublette #8-35', 'San Cristóbal', 'Táchira', '5022', 'Venezuela'),
    (10614::integer, 'BLAUS'::text, 8::integer, '2025-07-29'::date, '2025-08-26'::date, '2025-08-01'::date, 3::integer, 1.93::real, 'Blauer See Delikatessen', 'Forsterstr. 57', 'Mannheim', '', '68306', 'Germany'),
    (10615::integer, 'WILMK'::text, 2::integer, '2025-07-30'::date, '2025-08-27'::date, '2025-08-06'::date, 3::integer, 0.75::real, 'Wilman Kala', 'Keskuskatu 45', 'Helsinki', '', '21240', 'Finland'),
    (10616::integer, 'GREAL'::text, 1::integer, '2025-07-31'::date, '2025-08-28'::date, '2025-08-05'::date, 2::integer, 116.53::real, 'Great Lakes Food Market', '2732 Baker Blvd.', 'Eugene', 'OR', '97403', 'USA'),
    (10617::integer, 'GREAL'::text, 4::integer, '2025-07-31'::date, '2025-08-28'::date, '2025-08-04'::date, 2::integer, 18.53::real, 'Great Lakes Food Market', '2732 Baker Blvd.', 'Eugene', 'OR', '97403', 'USA'),
    (10618::integer, 'MEREP'::text, 1::integer, '2025-08-01'::date, '2025-09-12'::date, '2025-08-08'::date, 1::integer, 154.68::real, 'Mère Paillarde', '43 rue St. Laurent', 'Montréal', 'Québec', 'H1J 1C3', 'Canada'),
    (10619::integer, 'MEREP'::text, 3::integer, '2025-08-04'::date, '2025-09-01'::date, '2025-08-07'::date, 3::integer, 91.05::real, 'Mère Paillarde', '43 rue St. Laurent', 'Montréal', 'Québec', 'H1J 1C3', 'Canada'),
    (10620::integer, 'LAUGB'::text, 2::integer, '2025-08-05'::date, '2025-09-02'::date, '2025-08-14'::date, 3::integer, 0.94::real, 'Laughing Bacchus Wine Cellars', '2319 Elm St.', 'Vancouver', 'BC', 'V3F 2K1', 'Canada'),
    (10621::integer, 'ISLAT'::text, 4::integer, '2025-08-05'::date, '2025-09-02'::date, '2025-08-11'::date, 2::integer, 23.73::real, 'Island Trading', 'Garden House Crowther Way', 'Cowes', 'Isle of Wight', 'PO31 7PJ', 'UK'),
    (10622::integer, 'RICAR'::text, 4::integer, '2025-08-06'::date, '2025-09-03'::date, '2025-08-11'::date, 3::integer, 50.97::real, 'Ricardo Adocicados', 'Av. Copacabana, 267', 'Rio de Janeiro', 'RJ', '02389-890', 'Brazil'),
    (10623::integer, 'FRANK'::text, 8::integer, '2025-08-07'::date, '2025-09-04'::date, '2025-08-12'::date, 2::integer, 97.18::real, 'Frankenversand', 'Berliner Platz 43', 'München', '', '80805', 'Germany'),
    (10624::integer, 'THECR'::text, 4::integer, '2025-08-07'::date, '2025-09-04'::date, '2025-08-19'::date, 2::integer, 94.8::real, 'The Cracker Box', '55 Grizzly Peak Rd.', 'Butte', 'MT', '59801', 'USA'),
    (10625::integer, 'ANATR'::text, 3::integer, '2025-08-08'::date, '2025-09-05'::date, '2025-08-14'::date, 1::integer, 43.9::real, 'Ana Trujillo Emparedados y helados', 'Avda. de la Constitución 2222', 'México D.F.', '', '05021', 'Mexico'),
    (10626::integer, 'BERGS'::text, 1::integer, '2025-08-11'::date, '2025-09-08'::date, '2025-08-20'::date, 2::integer, 138.69::real, 'Berglunds snabbköp', 'Berguvsvägen  8', 'Luleå', '', 'S-958 22', 'Sweden'),
    (10627::integer, 'SAVEA'::text, 8::integer, '2025-08-11'::date, '2025-09-22'::date, '2025-08-21'::date, 3::integer, 107.46::real, 'Save-a-lot Markets', '187 Suffolk Ln.', 'Boise', 'ID', '83720', 'USA'),
    (10628::integer, 'BLONP'::text, 4::integer, '2025-08-12'::date, '2025-09-09'::date, '2025-08-20'::date, 3::integer, 30.36::real, 'Blondel père et fils', '24, place Kléber', 'Strasbourg', '', '67000', 'France'),
    (10629::integer, 'GODOS'::text, 4::integer, '2025-08-12'::date, '2025-09-09'::date, '2025-08-20'::date, 3::integer, 85.46::real, 'Godos Cocina Típica', 'C/ Romero, 33', 'Sevilla', '', '41101', 'Spain'),
    (10630::integer, 'KOENE'::text, 1::integer, '2025-08-13'::date, '2025-09-10'::date, '2025-08-19'::date, 2::integer, 32.35::real, 'Königlich Essen', 'Maubelstr. 90', 'Brandenburg', '', '14776', 'Germany'),
    (10631::integer, 'LAMAI'::text, 8::integer, '2025-08-14'::date, '2025-09-11'::date, '2025-08-15'::date, 1::integer, 0.87::real, 'La maison d''Asie', '1 rue Alsace-Lorraine', 'Toulouse', '', '31000', 'France'),
    (10632::integer, 'WANDK'::text, 8::integer, '2025-08-14'::date, '2025-09-11'::date, '2025-08-19'::date, 1::integer, 41.38::real, 'Die Wandernde Kuh', 'Adenauerallee 900', 'Stuttgart', '', '70563', 'Germany'),
    (10633::integer, 'ERNSH'::text, 7::integer, '2025-08-15'::date, '2025-09-12'::date, '2025-08-18'::date, 3::integer, 477.9::real, 'Ernst Handel', 'Kirchgasse 6', 'Graz', '', '8010', 'Austria'),
    (10634::integer, 'FOLIG'::text, 4::integer, '2025-08-15'::date, '2025-09-12'::date, '2025-08-21'::date, 3::integer, 487.38::real, 'Folies gourmandes', '184, chaussée de Tournai', 'Lille', '', '59000', 'France'),
    (10635::integer, 'MAGAA'::text, 8::integer, '2025-08-18'::date, '2025-09-15'::date, '2025-08-21'::date, 3::integer, 47.46::real, 'Magazzini Alimentari Riuniti', 'Via Ludovico il Moro 22', 'Bergamo', '', '24100', 'Italy'),
    (10636::integer, 'WARTH'::text, 4::integer, '2025-08-19'::date, '2025-09-16'::date, '2025-08-26'::date, 1::integer, 1.15::real, 'Wartian Herkku', 'Torikatu 38', 'Oulu', '', '90110', 'Finland'),
    (10637::integer, 'QUEEN'::text, 6::integer, '2025-08-19'::date, '2025-09-16'::date, '2025-08-26'::date, 1::integer, 201.29::real, 'Queen Cozinha', 'Alameda dos Canàrios, 891', 'Sao Paulo', 'SP', '05487-020', 'Brazil'),
    (10638::integer, 'LINOD'::text, 3::integer, '2025-08-20'::date, '2025-09-17'::date, '2025-09-01'::date, 1::integer, 158.44::real, 'LINO-Delicateses', 'Ave. 5 de Mayo Porlamar', 'I. de Margarita', 'Nueva Esparta', '4980', 'Venezuela'),
    (10639::integer, 'SANTG'::text, 7::integer, '2025-08-20'::date, '2025-09-17'::date, '2025-08-27'::date, 3::integer, 38.64::real, 'Santé Gourmet', 'Erling Skakkes gate 78', 'Stavern', '', '4110', 'Norway'),
    (10640::integer, 'WANDK'::text, 4::integer, '2025-08-21'::date, '2025-09-18'::date, '2025-08-28'::date, 1::integer, 23.55::real, 'Die Wandernde Kuh', 'Adenauerallee 900', 'Stuttgart', '', '70563', 'Germany'),
    (10641::integer, 'HILAA'::text, 4::integer, '2025-08-22'::date, '2025-09-19'::date, '2025-08-26'::date, 2::integer, 179.61::real, 'HILARION-Abastos', 'Carrera 22 con Ave. Carlos Soublette #8-35', 'San Cristóbal', 'Táchira', '5022', 'Venezuela'),
    (10642::integer, 'SIMOB'::text, 7::integer, '2025-08-22'::date, '2025-09-19'::date, '2025-09-05'::date, 3::integer, 41.89::real, 'Simons bistro', 'Vinbæltet 34', 'Kobenhavn', '', '1734', 'Denmark'),
    (10643::integer, 'ALFKI'::text, 6::integer, '2025-08-25'::date, '2025-09-22'::date, '2025-09-02'::date, 1::integer, 29.46::real, 'Alfreds Futterkiste', 'Obere Str. 57', 'Berlin', '', '12209', 'Germany'),
    (10644::integer, 'WELLI'::text, 3::integer, '2025-08-25'::date, '2025-09-22'::date, '2025-09-01'::date, 2::integer, 0.14::real, 'Wellington Importadora', 'Rua do Mercado, 12', 'Resende', 'SP', '08737-363', 'Brazil'),
    (10645::integer, 'HANAR'::text, 4::integer, '2025-08-26'::date, '2025-09-23'::date, '2025-09-02'::date, 1::integer, 12.41::real, 'Hanari Carnes', 'Rua do Paço, 67', 'Rio de Janeiro', 'RJ', '05454-876', 'Brazil'),
    (10646::integer, 'HUNGO'::text, 9::integer, '2025-08-27'::date, '2025-10-08'::date, '2025-09-03'::date, 3::integer, 142.33::real, 'Hungry Owl All-Night Grocers', '8 Johnstown Road', 'Cork', 'Co. Cork', '', 'Ireland'),
    (10647::integer, 'QUEDE'::text, 4::integer, '2025-08-27'::date, '2025-09-10'::date, '2025-09-03'::date, 2::integer, 45.54::real, 'Que Delícia', 'Rua da Panificadora, 12', 'Rio de Janeiro', 'RJ', '02389-673', 'Brazil'),
    (10648::integer, 'RICAR'::text, 5::integer, '2025-08-28'::date, '2025-10-09'::date, '2025-09-09'::date, 2::integer, 14.25::real, 'Ricardo Adocicados', 'Av. Copacabana, 267', 'Rio de Janeiro', 'RJ', '02389-890', 'Brazil'),
    (10649::integer, 'MAISD'::text, 5::integer, '2025-08-28'::date, '2025-09-25'::date, '2025-08-29'::date, 3::integer, 6.2::real, 'Maison Dewey', 'Rue Joseph-Bens 532', 'Bruxelles', '', 'B-1180', 'Belgium'),
    (10650::integer, 'FAMIA'::text, 5::integer, '2025-08-29'::date, '2025-09-26'::date, '2025-09-03'::date, 3::integer, 176.81::real, 'Familia Arquibaldo', 'Rua Orós, 92', 'Sao Paulo', 'SP', '05442-030', 'Brazil'),
    (10651::integer, 'WANDK'::text, 8::integer, '2025-09-01'::date, '2025-09-29'::date, '2025-09-11'::date, 2::integer, 20.6::real, 'Die Wandernde Kuh', 'Adenauerallee 900', 'Stuttgart', '', '70563', 'Germany'),
    (10652::integer, 'GOURL'::text, 4::integer, '2025-09-01'::date, '2025-09-29'::date, '2025-09-08'::date, 2::integer, 7.14::real, 'Gourmet Lanchonetes', 'Av. Brasil, 442', 'Campinas', 'SP', '04876-786', 'Brazil'),
    (10653::integer, 'FRANK'::text, 1::integer, '2025-09-02'::date, '2025-09-30'::date, '2025-09-19'::date, 1::integer, 93.25::real, 'Frankenversand', 'Berliner Platz 43', 'München', '', '80805', 'Germany'),
    (10654::integer, 'BERGS'::text, 5::integer, '2025-09-02'::date, '2025-09-30'::date, '2025-09-11'::date, 1::integer, 55.26::real, 'Berglunds snabbköp', 'Berguvsvägen  8', 'Luleå', '', 'S-958 22', 'Sweden'),
    (10655::integer, 'REGGC'::text, 1::integer, '2025-09-03'::date, '2025-10-01'::date, '2025-09-11'::date, 2::integer, 4.41::real, 'Reggiani Caseifici', 'Strada Provinciale 124', 'Reggio Emilia', '', '42100', 'Italy'),
    (10656::integer, 'GREAL'::text, 6::integer, '2025-09-04'::date, '2025-10-02'::date, '2025-09-10'::date, 1::integer, 57.15::real, 'Great Lakes Food Market', '2732 Baker Blvd.', 'Eugene', 'OR', '97403', 'USA'),
    (10657::integer, 'SAVEA'::text, 2::integer, '2025-09-04'::date, '2025-10-02'::date, '2025-09-15'::date, 2::integer, 352.69::real, 'Save-a-lot Markets', '187 Suffolk Ln.', 'Boise', 'ID', '83720', 'USA'),
    (10658::integer, 'QUICK'::text, 4::integer, '2025-09-05'::date, '2025-10-03'::date, '2025-09-08'::date, 1::integer, 364.15::real, 'QUICK-Stop', 'Taucherstraße 10', 'Cunewalde', '', '01307', 'Germany'),
    (10659::integer, 'QUEEN'::text, 7::integer, '2025-09-05'::date, '2025-10-03'::date, '2025-09-10'::date, 2::integer, 105.81::real, 'Queen Cozinha', 'Alameda dos Canàrios, 891', 'Sao Paulo', 'SP', '05487-020', 'Brazil'),
    (10660::integer, 'HUNGC'::text, 8::integer, '2025-09-08'::date, '2025-10-06'::date, '2025-10-15'::date, 1::integer, 111.29::real, 'Hungry Coyote Import Store', 'City Center Plaza 516 Main St.', 'Elgin', 'OR', '97827', 'USA'),
    (10661::integer, 'HUNGO'::text, 7::integer, '2025-09-09'::date, '2025-10-07'::date, '2025-09-15'::date, 3::integer, 17.55::real, 'Hungry Owl All-Night Grocers', '8 Johnstown Road', 'Cork', 'Co. Cork', '', 'Ireland'),
    (10662::integer, 'LONEP'::text, 3::integer, '2025-09-09'::date, '2025-10-07'::date, '2025-09-18'::date, 2::integer, 1.28::real, 'Lonesome Pine Restaurant', '89 Chiaroscuro Rd.', 'Portland', 'OR', '97219', 'USA'),
    (10663::integer, 'BONAP'::text, 2::integer, '2025-09-10'::date, '2025-09-24'::date, '2025-10-03'::date, 2::integer, 113.15::real, 'Bon app''', '12, rue des Bouchers', 'Marseille', '', '13008', 'France'),
    (10664::integer, 'FURIB'::text, 1::integer, '2025-09-10'::date, '2025-10-08'::date, '2025-09-19'::date, 3::integer, 1.27::real, 'Furia Bacalhau e Frutos do Mar', 'Jardim das rosas n. 32', 'Lisboa', '', '1675', 'Portugal'),
    (10665::integer, 'LONEP'::text, 1::integer, '2025-09-11'::date, '2025-10-09'::date, '2025-09-17'::date, 2::integer, 26.31::real, 'Lonesome Pine Restaurant', '89 Chiaroscuro Rd.', 'Portland', 'OR', '97219', 'USA'),
    (10666::integer, 'RICSU'::text, 7::integer, '2025-09-12'::date, '2025-10-10'::date, '2025-09-22'::date, 2::integer, 232.42::real, 'Richter Supermarkt', 'Starenweg 5', 'Genève', '', '1204', 'Switzerland'),
    (10667::integer, 'ERNSH'::text, 7::integer, '2025-09-12'::date, '2025-10-10'::date, '2025-09-19'::date, 1::integer, 78.09::real, 'Ernst Handel', 'Kirchgasse 6', 'Graz', '', '8010', 'Austria'),
    (10668::integer, 'WANDK'::text, 1::integer, '2025-09-15'::date, '2025-10-13'::date, '2025-09-23'::date, 2::integer, 47.22::real, 'Die Wandernde Kuh', 'Adenauerallee 900', 'Stuttgart', '', '70563', 'Germany'),
    (10669::integer, 'SIMOB'::text, 2::integer, '2025-09-15'::date, '2025-10-13'::date, '2025-09-22'::date, 1::integer, 24.39::real, 'Simons bistro', 'Vinbæltet 34', 'Kobenhavn', '', '1734', 'Denmark'),
    (10670::integer, 'FRANK'::text, 4::integer, '2025-09-16'::date, '2025-10-14'::date, '2025-09-18'::date, 1::integer, 203.48::real, 'Frankenversand', 'Berliner Platz 43', 'München', '', '80805', 'Germany'),
    (10671::integer, 'FRANR'::text, 1::integer, '2025-09-17'::date, '2025-10-15'::date, '2025-09-24'::date, 1::integer, 30.34::real, 'France restauration', '54, rue Royale', 'Nantes', '', '44000', 'France'),
    (10672::integer, 'BERGS'::text, 9::integer, '2025-09-17'::date, '2025-10-01'::date, '2025-09-26'::date, 2::integer, 95.75::real, 'Berglunds snabbköp', 'Berguvsvägen  8', 'Luleå', '', 'S-958 22', 'Sweden'),
    (10673::integer, 'WILMK'::text, 2::integer, '2025-09-18'::date, '2025-10-16'::date, '2025-09-19'::date, 1::integer, 22.76::real, 'Wilman Kala', 'Keskuskatu 45', 'Helsinki', '', '21240', 'Finland'),
    (10674::integer, 'ISLAT'::text, 4::integer, '2025-09-18'::date, '2025-10-16'::date, '2025-09-30'::date, 2::integer, 0.9::real, 'Island Trading', 'Garden House Crowther Way', 'Cowes', 'Isle of Wight', 'PO31 7PJ', 'UK'),
    (10675::integer, 'FRANK'::text, 5::integer, '2025-09-19'::date, '2025-10-17'::date, '2025-09-23'::date, 2::integer, 31.85::real, 'Frankenversand', 'Berliner Platz 43', 'München', '', '80805', 'Germany'),
    (10676::integer, 'TORTU'::text, 2::integer, '2025-09-22'::date, '2025-10-20'::date, '2025-09-29'::date, 2::integer, 2.01::real, 'Tortuga Restaurante', 'Avda. Azteca 123', 'México D.F.', '', '05033', 'Mexico'),
    (10677::integer, 'ANTON'::text, 1::integer, '2025-09-22'::date, '2025-10-20'::date, '2025-09-26'::date, 3::integer, 4.03::real, 'Antonio Moreno Taquería', 'Mataderos  2312', 'México D.F.', '', '05023', 'Mexico'),
    (10678::integer, 'SAVEA'::text, 7::integer, '2025-09-23'::date, '2025-10-21'::date, '2025-10-16'::date, 3::integer, 388.98::real, 'Save-a-lot Markets', '187 Suffolk Ln.', 'Boise', 'ID', '83720', 'USA'),
    (10679::integer, 'BLONP'::text, 8::integer, '2025-09-23'::date, '2025-10-21'::date, '2025-09-30'::date, 3::integer, 27.94::real, 'Blondel père et fils', '24, place Kléber', 'Strasbourg', '', '67000', 'France'),
    (10680::integer, 'OLDWO'::text, 1::integer, '2025-09-24'::date, '2025-10-22'::date, '2025-09-26'::date, 1::integer, 26.61::real, 'Old World Delicatessen', '2743 Bering St.', 'Anchorage', 'AK', '99508', 'USA'),
    (10681::integer, 'GREAL'::text, 3::integer, '2025-09-25'::date, '2025-10-23'::date, '2025-09-30'::date, 3::integer, 76.13::real, 'Great Lakes Food Market', '2732 Baker Blvd.', 'Eugene', 'OR', '97403', 'USA'),
    (10682::integer, 'ANTON'::text, 3::integer, '2025-09-25'::date, '2025-10-23'::date, '2025-10-01'::date, 2::integer, 36.13::real, 'Antonio Moreno Taquería', 'Mataderos  2312', 'México D.F.', '', '05023', 'Mexico'),
    (10683::integer, 'DUMON'::text, 2::integer, '2025-09-26'::date, '2025-10-24'::date, '2025-10-01'::date, 1::integer, 4.4::real, 'Du monde entier', '67, rue des Cinquante Otages', 'Nantes', '', '44000', 'France'),
    (10684::integer, 'OTTIK'::text, 3::integer, '2025-09-26'::date, '2025-10-24'::date, '2025-09-30'::date, 1::integer, 145.63::real, 'Ottilies Käseladen', 'Mehrheimerstr. 369', 'Köln', '', '50739', 'Germany'),
    (10685::integer, 'GOURL'::text, 4::integer, '2025-09-29'::date, '2025-10-13'::date, '2025-10-03'::date, 2::integer, 33.75::real, 'Gourmet Lanchonetes', 'Av. Brasil, 442', 'Campinas', 'SP', '04876-786', 'Brazil'),
    (10686::integer, 'PICCO'::text, 2::integer, '2025-09-30'::date, '2025-10-28'::date, '2025-10-08'::date, 1::integer, 96.5::real, 'Piccolo und mehr', 'Geislweg 14', 'Salzburg', '', '5020', 'Austria'),
    (10687::integer, 'HUNGO'::text, 9::integer, '2025-09-30'::date, '2025-10-28'::date, '2025-10-30'::date, 2::integer, 296.43::real, 'Hungry Owl All-Night Grocers', '8 Johnstown Road', 'Cork', 'Co. Cork', '', 'Ireland'),
    (10688::integer, 'VAFFE'::text, 4::integer, '2025-10-01'::date, '2025-10-15'::date, '2025-10-07'::date, 2::integer, 299.09::real, 'Vaffeljernet', 'Smagsloget 45', 'Århus', '', '8200', 'Denmark'),
    (10689::integer, 'BERGS'::text, 1::integer, '2025-10-01'::date, '2025-10-29'::date, '2025-10-07'::date, 2::integer, 13.42::real, 'Berglunds snabbköp', 'Berguvsvägen  8', 'Luleå', '', 'S-958 22', 'Sweden'),
    (10690::integer, 'HANAR'::text, 1::integer, '2025-10-02'::date, '2025-10-30'::date, '2025-10-03'::date, 1::integer, 15.8::real, 'Hanari Carnes', 'Rua do Paço, 67', 'Rio de Janeiro', 'RJ', '05454-876', 'Brazil'),
    (10691::integer, 'QUICK'::text, 2::integer, '2025-10-03'::date, '2025-11-14'::date, '2025-10-22'::date, 2::integer, 810.05::real, 'QUICK-Stop', 'Taucherstraße 10', 'Cunewalde', '', '01307', 'Germany'),
    (10692::integer, 'ALFKI'::text, 4::integer, '2025-10-03'::date, '2025-10-31'::date, '2025-10-13'::date, 2::integer, 61.02::real, 'Alfred''s Futterkiste', 'Obere Str. 57', 'Berlin', '', '12209', 'Germany'),
    (10693::integer, 'WHITC'::text, 3::integer, '2025-10-06'::date, '2025-10-20'::date, '2025-10-10'::date, 3::integer, 139.34::real, 'White Clover Markets', '1029 - 12th Ave. S.', 'Seattle', 'WA', '98124', 'USA'),
    (10694::integer, 'QUICK'::text, 8::integer, '2025-10-06'::date, '2025-11-03'::date, '2025-10-09'::date, 3::integer, 398.36::real, 'QUICK-Stop', 'Taucherstraße 10', 'Cunewalde', '', '01307', 'Germany'),
    (10695::integer, 'WILMK'::text, 7::integer, '2025-10-07'::date, '2025-11-18'::date, '2025-10-14'::date, 1::integer, 16.72::real, 'Wilman Kala', 'Keskuskatu 45', 'Helsinki', '', '21240', 'Finland'),
    (10696::integer, 'WHITC'::text, 8::integer, '2025-10-08'::date, '2025-11-19'::date, '2025-10-14'::date, 3::integer, 102.55::real, 'White Clover Markets', '1029 - 12th Ave. S.', 'Seattle', 'WA', '98124', 'USA'),
    (10697::integer, 'LINOD'::text, 3::integer, '2025-10-08'::date, '2025-11-05'::date, '2025-10-14'::date, 1::integer, 45.52::real, 'LINO-Delicateses', 'Ave. 5 de Mayo Porlamar', 'I. de Margarita', 'Nueva Esparta', '4980', 'Venezuela'),
    (10698::integer, 'ERNSH'::text, 4::integer, '2025-10-09'::date, '2025-11-06'::date, '2025-10-17'::date, 1::integer, 272.47::real, 'Ernst Handel', 'Kirchgasse 6', 'Graz', '', '8010', 'Austria'),
    (10699::integer, 'MORGK'::text, 3::integer, '2025-10-09'::date, '2025-11-06'::date, '2025-10-13'::date, 3::integer, 0.58::real, 'Morgenstern Gesundkost', 'Heerstr. 22', 'Leipzig', '', '04179', 'Germany'),
    (10700::integer, 'SAVEA'::text, 3::integer, '2025-10-10'::date, '2025-11-07'::date, '2025-10-16'::date, 1::integer, 65.1::real, 'Save-a-lot Markets', '187 Suffolk Ln.', 'Boise', 'ID', '83720', 'USA'),
    (10701::integer, 'HUNGO'::text, 6::integer, '2025-10-13'::date, '2025-10-27'::date, '2025-10-15'::date, 3::integer, 220.31::real, 'Hungry Owl All-Night Grocers', '8 Johnstown Road', 'Cork', 'Co. Cork', '', 'Ireland'),
    (10702::integer, 'ALFKI'::text, 4::integer, '2025-10-13'::date, '2025-11-24'::date, '2025-10-21'::date, 1::integer, 23.94::real, 'Alfred''s Futterkiste', 'Obere Str. 57', 'Berlin', '', '12209', 'Germany'),
    (10703::integer, 'FOLKO'::text, 6::integer, '2025-10-14'::date, '2025-11-11'::date, '2025-10-20'::date, 2::integer, 152.3::real, 'Folk och fä HB', 'Åkergatan 24', 'Bräcke', '', 'S-844 67', 'Sweden'),
    (10704::integer, 'QUEEN'::text, 6::integer, '2025-10-14'::date, '2025-11-11'::date, '2025-11-07'::date, 1::integer, 4.78::real, 'Queen Cozinha', 'Alameda dos Canàrios, 891', 'Sao Paulo', 'SP', '05487-020', 'Brazil'),
    (10705::integer, 'HILAA'::text, 9::integer, '2025-10-15'::date, '2025-11-12'::date, '2025-11-18'::date, 2::integer, 3.52::real, 'HILARION-Abastos', 'Carrera 22 con Ave. Carlos Soublette #8-35', 'San Cristóbal', 'Táchira', '5022', 'Venezuela'),
    (10706::integer, 'OLDWO'::text, 8::integer, '2025-10-16'::date, '2025-11-13'::date, '2025-10-21'::date, 3::integer, 135.63::real, 'Old World Delicatessen', '2743 Bering St.', 'Anchorage', 'AK', '99508', 'USA'),
    (10707::integer, 'AROUT'::text, 4::integer, '2025-10-16'::date, '2025-10-30'::date, '2025-10-23'::date, 3::integer, 21.74::real, 'Around the Horn', 'Brook Farm Stratford St. Mary', 'Colchester', 'Essex', 'CO7 6JX', 'UK'),
    (10708::integer, 'THEBI'::text, 6::integer, '2025-10-17'::date, '2025-11-28'::date, '2025-11-05'::date, 2::integer, 2.96::real, 'The Big Cheese', '89 Jefferson Way Suite 2', 'Portland', 'OR', '97201', 'USA'),
    (10709::integer, 'GOURL'::text, 1::integer, '2025-10-17'::date, '2025-11-14'::date, '2025-11-20'::date, 3::integer, 210.8::real, 'Gourmet Lanchonetes', 'Av. Brasil, 442', 'Campinas', 'SP', '04876-786', 'Brazil'),
    (10710::integer, 'FRANS'::text, 1::integer, '2025-10-20'::date, '2025-11-17'::date, '2025-10-23'::date, 1::integer, 4.98::real, 'Franchi S.p.A.', 'Via Monte Bianco 34', 'Torino', '', '10100', 'Italy'),
    (10711::integer, 'SAVEA'::text, 5::integer, '2025-10-21'::date, '2025-12-02'::date, '2025-10-29'::date, 2::integer, 52.41::real, 'Save-a-lot Markets', '187 Suffolk Ln.', 'Boise', 'ID', '83720', 'USA'),
    (10712::integer, 'HUNGO'::text, 3::integer, '2025-10-21'::date, '2025-11-18'::date, '2025-10-31'::date, 1::integer, 89.93::real, 'Hungry Owl All-Night Grocers', '8 Johnstown Road', 'Cork', 'Co. Cork', '', 'Ireland'),
    (10713::integer, 'SAVEA'::text, 1::integer, '2025-10-22'::date, '2025-11-19'::date, '2025-10-24'::date, 1::integer, 167.05::real, 'Save-a-lot Markets', '187 Suffolk Ln.', 'Boise', 'ID', '83720', 'USA'),
    (10714::integer, 'SAVEA'::text, 5::integer, '2025-10-22'::date, '2025-11-19'::date, '2025-10-27'::date, 3::integer, 24.49::real, 'Save-a-lot Markets', '187 Suffolk Ln.', 'Boise', 'ID', '83720', 'USA'),
    (10715::integer, 'BONAP'::text, 3::integer, '2025-10-23'::date, '2025-11-06'::date, '2025-10-29'::date, 1::integer, 63.2::real, 'Bon app''', '12, rue des Bouchers', 'Marseille', '', '13008', 'France'),
    (10716::integer, 'RANCH'::text, 4::integer, '2025-10-24'::date, '2025-11-21'::date, '2025-10-27'::date, 2::integer, 22.57::real, 'Rancho grande', 'Av. del Libertador 900', 'Buenos Aires', '', '1010', 'Argentina'),
    (10717::integer, 'FRANK'::text, 1::integer, '2025-10-24'::date, '2025-11-21'::date, '2025-10-29'::date, 2::integer, 59.25::real, 'Frankenversand', 'Berliner Platz 43', 'München', '', '80805', 'Germany'),
    (10718::integer, 'KOENE'::text, 1::integer, '2025-10-27'::date, '2025-11-24'::date, '2025-10-29'::date, 3::integer, 170.88::real, 'Königlich Essen', 'Maubelstr. 90', 'Brandenburg', '', '14776', 'Germany'),
    (10719::integer, 'LETSS'::text, 8::integer, '2025-10-27'::date, '2025-11-24'::date, '2025-11-05'::date, 2::integer, 51.44::real, 'Let''s Stop N Shop', '87 Polk St. Suite 5', 'San Francisco', 'CA', '94117', 'USA'),
    (10720::integer, 'QUEDE'::text, 8::integer, '2025-10-28'::date, '2025-11-11'::date, '2025-11-05'::date, 2::integer, 9.53::real, 'Que Delícia', 'Rua da Panificadora, 12', 'Rio de Janeiro', 'RJ', '02389-673', 'Brazil'),
    (10721::integer, 'QUICK'::text, 5::integer, '2025-10-29'::date, '2025-11-26'::date, '2025-10-31'::date, 3::integer, 48.92::real, 'QUICK-Stop', 'Taucherstraße 10', 'Cunewalde', '', '01307', 'Germany'),
    (10722::integer, 'SAVEA'::text, 8::integer, '2025-10-29'::date, '2025-12-10'::date, '2025-11-04'::date, 1::integer, 74.58::real, 'Save-a-lot Markets', '187 Suffolk Ln.', 'Boise', 'ID', '83720', 'USA'),
    (10723::integer, 'WHITC'::text, 3::integer, '2025-10-30'::date, '2025-11-27'::date, '2025-11-25'::date, 1::integer, 21.72::real, 'White Clover Markets', '1029 - 12th Ave. S.', 'Seattle', 'WA', '98124', 'USA'),
    (10724::integer, 'MEREP'::text, 8::integer, '2025-10-30'::date, '2025-12-11'::date, '2025-11-05'::date, 2::integer, 57.75::real, 'Mère Paillarde', '43 rue St. Laurent', 'Montréal', 'Québec', 'H1J 1C3', 'Canada'),
    (10725::integer, 'FAMIA'::text, 4::integer, '2025-10-31'::date, '2025-11-28'::date, '2025-11-05'::date, 3::integer, 10.83::real, 'Familia Arquibaldo', 'Rua Orós, 92', 'Sao Paulo', 'SP', '05442-030', 'Brazil'),
    (10726::integer, 'EASTC'::text, 4::integer, '2025-11-03'::date, '2025-11-17'::date, '2025-12-05'::date, 1::integer, 16.56::real, 'Eastern Connection', '35 King George', 'London', '', 'WX3 6FW', 'UK'),
    (10727::integer, 'REGGC'::text, 2::integer, '2025-11-03'::date, '2025-12-01'::date, '2025-12-05'::date, 1::integer, 89.9::real, 'Reggiani Caseifici', 'Strada Provinciale 124', 'Reggio Emilia', '', '42100', 'Italy'),
    (10728::integer, 'QUEEN'::text, 4::integer, '2025-11-04'::date, '2025-12-02'::date, '2025-11-11'::date, 2::integer, 58.33::real, 'Queen Cozinha', 'Alameda dos Canàrios, 891', 'Sao Paulo', 'SP', '05487-020', 'Brazil'),
    (10729::integer, 'LINOD'::text, 8::integer, '2025-11-04'::date, '2025-12-16'::date, '2025-11-14'::date, 3::integer, 141.06::real, 'LINO-Delicateses', 'Ave. 5 de Mayo Porlamar', 'I. de Margarita', 'Nueva Esparta', '4980', 'Venezuela'),
    (10730::integer, 'BONAP'::text, 5::integer, '2025-11-05'::date, '2025-12-03'::date, '2025-11-14'::date, 1::integer, 20.12::real, 'Bon app''', '12, rue des Bouchers', 'Marseille', '', '13008', 'France'),
    (10731::integer, 'CHOPS'::text, 7::integer, '2025-11-06'::date, '2025-12-04'::date, '2025-11-14'::date, 1::integer, 96.65::real, 'Chop-suey Chinese', 'Hauptstr. 31', 'Bern', '', '3012', 'Switzerland'),
    (10732::integer, 'BONAP'::text, 3::integer, '2025-11-06'::date, '2025-12-04'::date, '2025-11-07'::date, 1::integer, 16.97::real, 'Bon app''', '12, rue des Bouchers', 'Marseille', '', '13008', 'France'),
    (10733::integer, 'BERGS'::text, 1::integer, '2025-11-07'::date, '2025-12-05'::date, '2025-11-10'::date, 3::integer, 110.11::real, 'Berglunds snabbköp', 'Berguvsvägen  8', 'Luleå', '', 'S-958 22', 'Sweden'),
    (10734::integer, 'GOURL'::text, 2::integer, '2025-11-07'::date, '2025-12-05'::date, '2025-11-12'::date, 3::integer, 1.63::real, 'Gourmet Lanchonetes', 'Av. Brasil, 442', 'Campinas', 'SP', '04876-786', 'Brazil'),
    (10735::integer, 'LETSS'::text, 6::integer, '2025-11-10'::date, '2025-12-08'::date, '2025-11-21'::date, 2::integer, 45.97::real, 'Let''s Stop N Shop', '87 Polk St. Suite 5', 'San Francisco', 'CA', '94117', 'USA'),
    (10736::integer, 'HUNGO'::text, 9::integer, '2025-11-11'::date, '2025-12-09'::date, '2025-11-21'::date, 2::integer, 44.1::real, 'Hungry Owl All-Night Grocers', '8 Johnstown Road', 'Cork', 'Co. Cork', '', 'Ireland'),
    (10737::integer, 'VINET'::text, 2::integer, '2025-11-11'::date, '2025-12-09'::date, '2025-11-18'::date, 2::integer, 7.79::real, 'Vins et alcools Chevalier', '59 rue de l''Abbaye', 'Reims', '', '51100', 'France'),
    (10738::integer, 'SPECD'::text, 2::integer, '2025-11-12'::date, '2025-12-10'::date, '2025-11-18'::date, 1::integer, 2.91::real, 'Spécialités du monde', '25, rue Lauriston', 'Paris', '', '75016', 'France'),
    (10739::integer, 'VINET'::text, 3::integer, '2025-11-12'::date, '2025-12-10'::date, '2025-11-17'::date, 3::integer, 11.08::real, 'Vins et alcools Chevalier', '59 rue de l''Abbaye', 'Reims', '', '51100', 'France'),
    (10740::integer, 'WHITC'::text, 4::integer, '2025-11-13'::date, '2025-12-11'::date, '2025-11-25'::date, 2::integer, 81.88::real, 'White Clover Markets', '1029 - 12th Ave. S.', 'Seattle', 'WA', '98124', 'USA'),
    (10741::integer, 'AROUT'::text, 4::integer, '2025-11-14'::date, '2025-11-28'::date, '2025-11-18'::date, 3::integer, 10.96::real, 'Around the Horn', 'Brook Farm Stratford St. Mary', 'Colchester', 'Essex', 'CO7 6JX', 'UK'),
    (10742::integer, 'BOTTM'::text, 3::integer, '2025-11-14'::date, '2025-12-12'::date, '2025-11-18'::date, 3::integer, 243.73::real, 'Bottom-Dollar Markets', '23 Tsawassen Blvd.', 'Tsawassen', 'BC', 'T2F 8M4', 'Canada'),
    (10743::integer, 'AROUT'::text, 1::integer, '2025-11-17'::date, '2025-12-15'::date, '2025-11-21'::date, 2::integer, 23.72::real, 'Around the Horn', 'Brook Farm Stratford St. Mary', 'Colchester', 'Essex', 'CO7 6JX', 'UK'),
    (10744::integer, 'VAFFE'::text, 6::integer, '2025-11-17'::date, '2025-12-15'::date, '2025-11-24'::date, 1::integer, 69.19::real, 'Vaffeljernet', 'Smagsloget 45', 'Århus', '', '8200', 'Denmark'),
    (10745::integer, 'QUICK'::text, 9::integer, '2025-11-18'::date, '2025-12-16'::date, '2025-11-27'::date, 1::integer, 3.52::real, 'QUICK-Stop', 'Taucherstraße 10', 'Cunewalde', '', '01307', 'Germany'),
    (10746::integer, 'CHOPS'::text, 1::integer, '2025-11-19'::date, '2025-12-17'::date, '2025-11-21'::date, 3::integer, 31.43::real, 'Chop-suey Chinese', 'Hauptstr. 31', 'Bern', '', '3012', 'Switzerland'),
    (10747::integer, 'PICCO'::text, 6::integer, '2025-11-19'::date, '2025-12-17'::date, '2025-11-26'::date, 1::integer, 117.33::real, 'Piccolo und mehr', 'Geislweg 14', 'Salzburg', '', '5020', 'Austria'),
    (10748::integer, 'SAVEA'::text, 3::integer, '2025-11-20'::date, '2025-12-18'::date, '2025-11-28'::date, 1::integer, 232.55::real, 'Save-a-lot Markets', '187 Suffolk Ln.', 'Boise', 'ID', '83720', 'USA'),
    (10749::integer, 'ISLAT'::text, 4::integer, '2025-11-20'::date, '2025-12-18'::date, '2025-12-19'::date, 2::integer, 61.53::real, 'Island Trading', 'Garden House Crowther Way', 'Cowes', 'Isle of Wight', 'PO31 7PJ', 'UK'),
    (10750::integer, 'WARTH'::text, 9::integer, '2025-11-21'::date, '2025-12-19'::date, '2025-11-24'::date, 1::integer, 79.3::real, 'Wartian Herkku', 'Torikatu 38', 'Oulu', '', '90110', 'Finland'),
    (10751::integer, 'RICSU'::text, 3::integer, '2025-11-24'::date, '2025-12-22'::date, '2025-12-03'::date, 3::integer, 130.79::real, 'Richter Supermarkt', 'Starenweg 5', 'Genève', '', '1204', 'Switzerland'),
    (10752::integer, 'NORTS'::text, 2::integer, '2025-11-24'::date, '2025-12-22'::date, '2025-11-28'::date, 3::integer, 1.39::real, 'North/South', 'South House 300 Queensbridge', 'London', '', 'SW7 1RZ', 'UK'),
    (10753::integer, 'FRANS'::text, 3::integer, '2025-11-25'::date, '2025-12-23'::date, '2025-11-27'::date, 1::integer, 7.7::real, 'Franchi S.p.A.', 'Via Monte Bianco 34', 'Torino', '', '10100', 'Italy'),
    (10754::integer, 'MAGAA'::text, 6::integer, '2025-11-25'::date, '2025-12-23'::date, '2025-11-27'::date, 3::integer, 2.38::real, 'Magazzini Alimentari Riuniti', 'Via Ludovico il Moro 22', 'Bergamo', '', '24100', 'Italy'),
    (10755::integer, 'BONAP'::text, 4::integer, '2025-11-26'::date, '2025-12-24'::date, '2025-11-28'::date, 2::integer, 16.71::real, 'Bon app''', '12, rue des Bouchers', 'Marseille', '', '13008', 'France'),
    (10756::integer, 'SPLIR'::text, 8::integer, '2025-11-27'::date, '2025-12-25'::date, '2025-12-02'::date, 2::integer, 73.21::real, 'Split Rail Beer & Ale', 'P.O. Box 555', 'Lander', 'WY', '82520', 'USA'),
    (10757::integer, 'SAVEA'::text, 6::integer, '2025-11-27'::date, '2025-12-25'::date, '2025-12-15'::date, 1::integer, 8.19::real, 'Save-a-lot Markets', '187 Suffolk Ln.', 'Boise', 'ID', '83720', 'USA'),
    (10758::integer, 'RICSU'::text, 3::integer, '2025-11-28'::date, '2025-12-26'::date, '2025-12-04'::date, 3::integer, 138.17::real, 'Richter Supermarkt', 'Starenweg 5', 'Genève', '', '1204', 'Switzerland'),
    (10759::integer, 'ANATR'::text, 3::integer, '2025-11-28'::date, '2025-12-26'::date, '2025-12-12'::date, 3::integer, 11.99::real, 'Ana Trujillo Emparedados y helados', 'Avda. de la Constitución 2222', 'México D.F.', '', '05021', 'Mexico'),
    (10760::integer, 'MAISD'::text, 4::integer, '2025-12-01'::date, '2025-12-29'::date, '2025-12-10'::date, 1::integer, 155.64::real, 'Maison Dewey', 'Rue Joseph-Bens 532', 'Bruxelles', '', 'B-1180', 'Belgium'),
    (10761::integer, 'RATTC'::text, 5::integer, '2025-12-02'::date, '2025-12-30'::date, '2025-12-08'::date, 2::integer, 18.66::real, 'Rattlesnake Canyon Grocery', '2817 Milton Dr.', 'Albuquerque', 'NM', '87110', 'USA'),
    (10762::integer, 'FOLKO'::text, 3::integer, '2025-12-02'::date, '2025-12-30'::date, '2025-12-09'::date, 1::integer, 328.74::real, 'Folk och fä HB', 'Åkergatan 24', 'Bräcke', '', 'S-844 67', 'Sweden'),
    (10763::integer, 'FOLIG'::text, 3::integer, '2025-12-03'::date, '2025-12-31'::date, '2025-12-08'::date, 3::integer, 37.35::real, 'Folies gourmandes', '184, chaussée de Tournai', 'Lille', '', '59000', 'France'),
    (10764::integer, 'ERNSH'::text, 6::integer, '2025-12-03'::date, '2025-12-31'::date, '2025-12-08'::date, 3::integer, 145.45::real, 'Ernst Handel', 'Kirchgasse 6', 'Graz', '', '8010', 'Austria'),
    (10765::integer, 'QUICK'::text, 3::integer, '2025-12-04'::date, '2026-01-01'::date, '2025-12-09'::date, 3::integer, 42.74::real, 'QUICK-Stop', 'Taucherstraße 10', 'Cunewalde', '', '01307', 'Germany'),
    (10766::integer, 'OTTIK'::text, 4::integer, '2025-12-05'::date, '2026-01-02'::date, '2025-12-09'::date, 1::integer, 157.55::real, 'Ottilies Käseladen', 'Mehrheimerstr. 369', 'Köln', '', '50739', 'Germany'),
    (10767::integer, 'SUPRD'::text, 4::integer, '2025-12-05'::date, '2026-01-02'::date, '2025-12-15'::date, 3::integer, 1.59::real, 'Suprêmes délices', 'Boulevard Tirou, 255', 'Charleroi', '', 'B-6000', 'Belgium'),
    (10768::integer, 'AROUT'::text, 3::integer, '2025-12-08'::date, '2026-01-05'::date, '2025-12-15'::date, 2::integer, 146.32::real, 'Around the Horn', 'Brook Farm Stratford St. Mary', 'Colchester', 'Essex', 'CO7 6JX', 'UK'),
    (10769::integer, 'VAFFE'::text, 3::integer, '2025-12-08'::date, '2026-01-05'::date, '2025-12-12'::date, 1::integer, 65.06::real, 'Vaffeljernet', 'Smagsloget 45', 'Århus', '', '8200', 'Denmark'),
    (10770::integer, 'HANAR'::text, 8::integer, '2025-12-09'::date, '2026-01-06'::date, '2025-12-17'::date, 3::integer, 5.32::real, 'Hanari Carnes', 'Rua do Paço, 67', 'Rio de Janeiro', 'RJ', '05454-876', 'Brazil'),
    (10771::integer, 'ERNSH'::text, 9::integer, '2025-12-10'::date, '2026-01-07'::date, '2026-01-02'::date, 2::integer, 11.19::real, 'Ernst Handel', 'Kirchgasse 6', 'Graz', '', '8010', 'Austria'),
    (10772::integer, 'LEHMS'::text, 3::integer, '2025-12-10'::date, '2026-01-07'::date, '2025-12-19'::date, 2::integer, 91.28::real, 'Lehmanns Marktstand', 'Magazinweg 7', 'Frankfurt a.M.', '', '60528', 'Germany'),
    (10773::integer, 'ERNSH'::text, 1::integer, '2025-12-11'::date, '2026-01-08'::date, '2025-12-16'::date, 3::integer, 96.43::real, 'Ernst Handel', 'Kirchgasse 6', 'Graz', '', '8010', 'Austria'),
    (10774::integer, 'FOLKO'::text, 4::integer, '2025-12-11'::date, '2025-12-25'::date, '2025-12-12'::date, 1::integer, 48.2::real, 'Folk och fä HB', 'Åkergatan 24', 'Bräcke', '', 'S-844 67', 'Sweden'),
    (10775::integer, 'THECR'::text, 7::integer, '2025-12-12'::date, '2026-01-09'::date, '2025-12-26'::date, 1::integer, 20.25::real, 'The Cracker Box', '55 Grizzly Peak Rd.', 'Butte', 'MT', '59801', 'USA'),
    (10776::integer, 'ERNSH'::text, 1::integer, '2025-12-15'::date, '2026-01-12'::date, '2025-12-18'::date, 3::integer, 351.53::real, 'Ernst Handel', 'Kirchgasse 6', 'Graz', '', '8010', 'Austria'),
    (10777::integer, 'GOURL'::text, 7::integer, '2025-12-15'::date, '2025-12-29'::date, '2026-01-21'::date, 2::integer, 3.01::real, 'Gourmet Lanchonetes', 'Av. Brasil, 442', 'Campinas', 'SP', '04876-786', 'Brazil'),
    (10778::integer, 'BERGS'::text, 3::integer, '2025-12-16'::date, '2026-01-13'::date, '2025-12-24'::date, 1::integer, 6.79::real, 'Berglunds snabbköp', 'Berguvsvägen  8', 'Luleå', '', 'S-958 22', 'Sweden'),
    (10779::integer, 'MORGK'::text, 3::integer, '2025-12-16'::date, '2026-01-13'::date, '2026-01-14'::date, 2::integer, 58.13::real, 'Morgenstern Gesundkost', 'Heerstr. 22', 'Leipzig', '', '04179', 'Germany'),
    (10780::integer, 'LILAS'::text, 2::integer, '2025-12-16'::date, '2025-12-30'::date, '2025-12-25'::date, 1::integer, 42.13::real, 'LILA-Supermercado', 'Carrera 52 con Ave. Bolívar #65-98 Llano Largo', 'Barquisimeto', 'Lara', '3508', 'Venezuela'),
    (10781::integer, 'WARTH'::text, 2::integer, '2025-12-17'::date, '2026-01-14'::date, '2025-12-19'::date, 3::integer, 73.16::real, 'Wartian Herkku', 'Torikatu 38', 'Oulu', '', '90110', 'Finland'),
    (10782::integer, 'CACTU'::text, 9::integer, '2025-12-17'::date, '2026-01-14'::date, '2025-12-22'::date, 3::integer, 1.1::real, 'Cactus Comidas para llevar', 'Cerrito 333', 'Buenos Aires', '', '1010', 'Argentina'),
    (10783::integer, 'HANAR'::text, 4::integer, '2025-12-18'::date, '2026-01-15'::date, '2025-12-19'::date, 2::integer, 124.98::real, 'Hanari Carnes', 'Rua do Paço, 67', 'Rio de Janeiro', 'RJ', '05454-876', 'Brazil'),
    (10784::integer, 'MAGAA'::text, 4::integer, '2025-12-18'::date, '2026-01-15'::date, '2025-12-22'::date, 3::integer, 70.09::real, 'Magazzini Alimentari Riuniti', 'Via Ludovico il Moro 22', 'Bergamo', '', '24100', 'Italy'),
    (10785::integer, 'GROSR'::text, 1::integer, '2025-12-18'::date, '2026-01-15'::date, '2025-12-24'::date, 3::integer, 1.51::real, 'GROSELLA-Restaurante', '5ª Ave. Los Palos Grandes', 'Caracas', 'DF', '1081', 'Venezuela'),
    (10786::integer, 'QUEEN'::text, 8::integer, '2025-12-19'::date, '2026-01-16'::date, '2025-12-23'::date, 1::integer, 110.87::real, 'Queen Cozinha', 'Alameda dos Canàrios, 891', 'Sao Paulo', 'SP', '05487-020', 'Brazil'),
    (10787::integer, 'LAMAI'::text, 2::integer, '2025-12-19'::date, '2026-01-02'::date, '2025-12-26'::date, 1::integer, 249.93::real, 'La maison d''Asie', '1 rue Alsace-Lorraine', 'Toulouse', '', '31000', 'France'),
    (10788::integer, 'QUICK'::text, 1::integer, '2025-12-22'::date, '2026-01-19'::date, '2026-01-19'::date, 2::integer, 42.7::real, 'QUICK-Stop', 'Taucherstraße 10', 'Cunewalde', '', '01307', 'Germany'),
    (10789::integer, 'FOLIG'::text, 1::integer, '2025-12-22'::date, '2026-01-19'::date, '2025-12-31'::date, 2::integer, 100.6::real, 'Folies gourmandes', '184, chaussée de Tournai', 'Lille', '', '59000', 'France'),
    (10790::integer, 'GOURL'::text, 6::integer, '2025-12-22'::date, '2026-01-19'::date, '2025-12-26'::date, 1::integer, 28.23::real, 'Gourmet Lanchonetes', 'Av. Brasil, 442', 'Campinas', 'SP', '04876-786', 'Brazil'),
    (10791::integer, 'FRANK'::text, 6::integer, '2025-12-23'::date, '2026-01-20'::date, '2026-01-01'::date, 2::integer, 16.85::real, 'Frankenversand', 'Berliner Platz 43', 'München', '', '80805', 'Germany'),
    (10792::integer, 'WOLZA'::text, 1::integer, '2025-12-23'::date, '2026-01-20'::date, '2025-12-31'::date, 3::integer, 23.79::real, 'Wolski Zajazd', 'ul. Filtrowa 68', 'Warszawa', '', '01-012', 'Poland'),
    (10793::integer, 'AROUT'::text, 3::integer, '2025-12-24'::date, '2026-01-21'::date, '2026-01-08'::date, 3::integer, 4.52::real, 'Around the Horn', 'Brook Farm Stratford St. Mary', 'Colchester', 'Essex', 'CO7 6JX', 'UK'),
    (10794::integer, 'QUEDE'::text, 6::integer, '2025-12-24'::date, '2026-01-21'::date, '2026-01-02'::date, 1::integer, 21.49::real, 'Que Delícia', 'Rua da Panificadora, 12', 'Rio de Janeiro', 'RJ', '02389-673', 'Brazil'),
    (10795::integer, 'ERNSH'::text, 8::integer, '2025-12-24'::date, '2026-01-21'::date, '2026-01-20'::date, 2::integer, 126.66::real, 'Ernst Handel', 'Kirchgasse 6', 'Graz', '', '8010', 'Austria'),
    (10796::integer, 'HILAA'::text, 3::integer, '2025-12-25'::date, '2026-01-22'::date, '2026-01-14'::date, 1::integer, 26.52::real, 'HILARION-Abastos', 'Carrera 22 con Ave. Carlos Soublette #8-35', 'San Cristóbal', 'Táchira', '5022', 'Venezuela'),
    (10797::integer, 'DRACD'::text, 7::integer, '2025-12-25'::date, '2026-01-22'::date, '2026-01-05'::date, 2::integer, 33.35::real, 'Drachenblut Delikatessen', 'Walserweg 21', 'Aachen', '', '52066', 'Germany'),
    (10798::integer, 'ISLAT'::text, 2::integer, '2025-12-26'::date, '2026-01-23'::date, '2026-01-05'::date, 1::integer, 2.33::real, 'Island Trading', 'Garden House Crowther Way', 'Cowes', 'Isle of Wight', 'PO31 7PJ', 'UK'),
    (10799::integer, 'KOENE'::text, 9::integer, '2025-12-26'::date, '2026-02-06'::date, '2026-01-05'::date, 3::integer, 30.76::real, 'Königlich Essen', 'Maubelstr. 90', 'Brandenburg', '', '14776', 'Germany'),
    (10800::integer, 'SEVES'::text, 1::integer, '2025-12-26'::date, '2026-01-23'::date, '2026-01-05'::date, 3::integer, 137.44::real, 'Seven Seas Imports', '90 Wadhurst Rd.', 'London', '', 'OX15 4NB', 'UK'),
    (10801::integer, 'BOLID'::text, 4::integer, '2025-12-29'::date, '2026-01-26'::date, '2025-12-31'::date, 2::integer, 97.09::real, 'Bólido Comidas preparadas', 'C/ Araquil, 67', 'Madrid', '', '28023', 'Spain'),
    (10802::integer, 'SIMOB'::text, 4::integer, '2025-12-29'::date, '2026-01-26'::date, '2026-01-02'::date, 2::integer, 257.26::real, 'Simons bistro', 'Vinbæltet 34', 'Kobenhavn', '', '1734', 'Denmark'),
    (10803::integer, 'WELLI'::text, 4::integer, '2025-12-30'::date, '2026-01-27'::date, '2026-01-06'::date, 1::integer, 55.23::real, 'Wellington Importadora', 'Rua do Mercado, 12', 'Resende', 'SP', '08737-363', 'Brazil'),
    (10804::integer, 'SEVES'::text, 6::integer, '2025-12-30'::date, '2026-01-27'::date, '2026-01-07'::date, 2::integer, 27.33::real, 'Seven Seas Imports', '90 Wadhurst Rd.', 'London', '', 'OX15 4NB', 'UK'),
    (10805::integer, 'THEBI'::text, 2::integer, '2025-12-30'::date, '2026-01-27'::date, '2026-01-09'::date, 3::integer, 237.34::real, 'The Big Cheese', '89 Jefferson Way Suite 2', 'Portland', 'OR', '97201', 'USA'),
    (10806::integer, 'VICTE'::text, 3::integer, '2025-12-31'::date, '2026-01-28'::date, '2026-01-05'::date, 2::integer, 22.11::real, 'Victuailles en stock', '2, rue du Commerce', 'Lyon', '', '69004', 'France'),
    (10807::integer, 'FRANS'::text, 4::integer, '2025-12-31'::date, '2026-01-28'::date, '2026-01-30'::date, 1::integer, 1.36::real, 'Franchi S.p.A.', 'Via Monte Bianco 34', 'Torino', '', '10100', 'Italy'),
    (10808::integer, 'OLDWO'::text, 2::integer, '2026-01-01'::date, '2026-01-29'::date, '2026-01-09'::date, 3::integer, 45.53::real, 'Old World Delicatessen', '2743 Bering St.', 'Anchorage', 'AK', '99508', 'USA'),
    (10809::integer, 'WELLI'::text, 7::integer, '2026-01-01'::date, '2026-01-29'::date, '2026-01-07'::date, 1::integer, 4.87::real, 'Wellington Importadora', 'Rua do Mercado, 12', 'Resende', 'SP', '08737-363', 'Brazil'),
    (10810::integer, 'LAUGB'::text, 2::integer, '2026-01-01'::date, '2026-01-29'::date, '2026-01-07'::date, 3::integer, 4.33::real, 'Laughing Bacchus Wine Cellars', '2319 Elm St.', 'Vancouver', 'BC', 'V3F 2K1', 'Canada'),
    (10811::integer, 'LINOD'::text, 8::integer, '2026-01-02'::date, '2026-01-30'::date, '2026-01-08'::date, 1::integer, 31.22::real, 'LINO-Delicateses', 'Ave. 5 de Mayo Porlamar', 'I. de Margarita', 'Nueva Esparta', '4980', 'Venezuela'),
    (10812::integer, 'REGGC'::text, 5::integer, '2026-01-02'::date, '2026-01-30'::date, '2026-01-12'::date, 1::integer, 59.78::real, 'Reggiani Caseifici', 'Strada Provinciale 124', 'Reggio Emilia', '', '42100', 'Italy'),
    (10813::integer, 'RICAR'::text, 1::integer, '2026-01-05'::date, '2026-02-02'::date, '2026-01-09'::date, 1::integer, 47.38::real, 'Ricardo Adocicados', 'Av. Copacabana, 267', 'Rio de Janeiro', 'RJ', '02389-890', 'Brazil'),
    (10814::integer, 'VICTE'::text, 3::integer, '2026-01-05'::date, '2026-02-02'::date, '2026-01-14'::date, 3::integer, 130.94::real, 'Victuailles en stock', '2, rue du Commerce', 'Lyon', '', '69004', 'France'),
    (10815::integer, 'SAVEA'::text, 2::integer, '2026-01-05'::date, '2026-02-02'::date, '2026-01-14'::date, 3::integer, 14.62::real, 'Save-a-lot Markets', '187 Suffolk Ln.', 'Boise', 'ID', '83720', 'USA'),
    (10816::integer, 'GREAL'::text, 4::integer, '2026-01-06'::date, '2026-02-03'::date, '2026-02-04'::date, 2::integer, 719.78::real, 'Great Lakes Food Market', '2732 Baker Blvd.', 'Eugene', 'OR', '97403', 'USA'),
    (10817::integer, 'KOENE'::text, 3::integer, '2026-01-06'::date, '2026-01-20'::date, '2026-01-13'::date, 2::integer, 306.07::real, 'Königlich Essen', 'Maubelstr. 90', 'Brandenburg', '', '14776', 'Germany'),
    (10818::integer, 'MAGAA'::text, 7::integer, '2026-01-07'::date, '2026-02-04'::date, '2026-01-12'::date, 3::integer, 65.48::real, 'Magazzini Alimentari Riuniti', 'Via Ludovico il Moro 22', 'Bergamo', '', '24100', 'Italy'),
    (10819::integer, 'CACTU'::text, 2::integer, '2026-01-07'::date, '2026-02-04'::date, '2026-01-16'::date, 3::integer, 19.76::real, 'Cactus Comidas para llevar', 'Cerrito 333', 'Buenos Aires', '', '1010', 'Argentina'),
    (10820::integer, 'RATTC'::text, 3::integer, '2026-01-07'::date, '2026-02-04'::date, '2026-01-13'::date, 2::integer, 37.52::real, 'Rattlesnake Canyon Grocery', '2817 Milton Dr.', 'Albuquerque', 'NM', '87110', 'USA'),
    (10821::integer, 'SPLIR'::text, 1::integer, '2026-01-08'::date, '2026-02-05'::date, '2026-01-15'::date, 1::integer, 36.68::real, 'Split Rail Beer & Ale', 'P.O. Box 555', 'Lander', 'WY', '82520', 'USA'),
    (10822::integer, 'TRAIH'::text, 6::integer, '2026-01-08'::date, '2026-02-05'::date, '2026-01-16'::date, 3::integer, 7::real, 'Trail''s Head Gourmet Provisioners', '722 DaVinci Blvd.', 'Kirkland', 'WA', '98034', 'USA'),
    (10823::integer, 'LILAS'::text, 5::integer, '2026-01-09'::date, '2026-02-06'::date, '2026-01-13'::date, 2::integer, 163.97::real, 'LILA-Supermercado', 'Carrera 52 con Ave. Bolívar #65-98 Llano Largo', 'Barquisimeto', 'Lara', '3508', 'Venezuela'),
    (10824::integer, 'FOLKO'::text, 8::integer, '2026-01-09'::date, '2026-02-06'::date, '2026-01-30'::date, 1::integer, 1.23::real, 'Folk och fä HB', 'Åkergatan 24', 'Bräcke', '', 'S-844 67', 'Sweden'),
    (10825::integer, 'DRACD'::text, 1::integer, '2026-01-09'::date, '2026-02-06'::date, '2026-01-14'::date, 1::integer, 79.25::real, 'Drachenblut Delikatessen', 'Walserweg 21', 'Aachen', '', '52066', 'Germany'),
    (10826::integer, 'BLONP'::text, 6::integer, '2026-01-12'::date, '2026-02-09'::date, '2026-02-06'::date, 1::integer, 7.09::real, 'Blondel père et fils', '24, place Kléber', 'Strasbourg', '', '67000', 'France'),
    (10827::integer, 'BONAP'::text, 1::integer, '2026-01-12'::date, '2026-01-26'::date, '2026-02-06'::date, 2::integer, 63.54::real, 'Bon app''', '12, rue des Bouchers', 'Marseille', '', '13008', 'France'),
    (10828::integer, 'RANCH'::text, 9::integer, '2026-01-13'::date, '2026-01-27'::date, '2026-02-04'::date, 1::integer, 90.85::real, 'Rancho grande', 'Av. del Libertador 900', 'Buenos Aires', '', '1010', 'Argentina'),
    (10829::integer, 'ISLAT'::text, 9::integer, '2026-01-13'::date, '2026-02-10'::date, '2026-01-23'::date, 1::integer, 154.72::real, 'Island Trading', 'Garden House Crowther Way', 'Cowes', 'Isle of Wight', 'PO31 7PJ', 'UK'),
    (10830::integer, 'TRADH'::text, 4::integer, '2026-01-13'::date, '2026-02-24'::date, '2026-01-21'::date, 2::integer, 81.83::real, 'Tradiçao Hipermercados', 'Av. Inês de Castro, 414', 'Sao Paulo', 'SP', '05634-030', 'Brazil'),
    (10831::integer, 'SANTG'::text, 3::integer, '2026-01-14'::date, '2026-02-11'::date, '2026-01-23'::date, 2::integer, 72.19::real, 'Santé Gourmet', 'Erling Skakkes gate 78', 'Stavern', '', '4110', 'Norway'),
    (10832::integer, 'LAMAI'::text, 2::integer, '2026-01-14'::date, '2026-02-11'::date, '2026-01-19'::date, 2::integer, 43.26::real, 'La maison d''Asie', '1 rue Alsace-Lorraine', 'Toulouse', '', '31000', 'France'),
    (10833::integer, 'OTTIK'::text, 6::integer, '2026-01-15'::date, '2026-02-12'::date, '2026-01-23'::date, 2::integer, 71.49::real, 'Ottilies Käseladen', 'Mehrheimerstr. 369', 'Köln', '', '50739', 'Germany'),
    (10834::integer, 'TRADH'::text, 1::integer, '2026-01-15'::date, '2026-02-12'::date, '2026-01-19'::date, 3::integer, 29.78::real, 'Tradiçao Hipermercados', 'Av. Inês de Castro, 414', 'Sao Paulo', 'SP', '05634-030', 'Brazil'),
    (10835::integer, 'ALFKI'::text, 1::integer, '2026-01-15'::date, '2026-02-12'::date, '2026-01-21'::date, 3::integer, 69.53::real, 'Alfred''s Futterkiste', 'Obere Str. 57', 'Berlin', '', '12209', 'Germany'),
    (10836::integer, 'ERNSH'::text, 7::integer, '2026-01-16'::date, '2026-02-13'::date, '2026-01-21'::date, 1::integer, 411.88::real, 'Ernst Handel', 'Kirchgasse 6', 'Graz', '', '8010', 'Austria'),
    (10837::integer, 'BERGS'::text, 9::integer, '2026-01-16'::date, '2026-02-13'::date, '2026-01-23'::date, 3::integer, 13.32::real, 'Berglunds snabbköp', 'Berguvsvägen  8', 'Luleå', '', 'S-958 22', 'Sweden'),
    (10838::integer, 'LINOD'::text, 3::integer, '2026-01-19'::date, '2026-02-16'::date, '2026-01-23'::date, 3::integer, 59.28::real, 'LINO-Delicateses', 'Ave. 5 de Mayo Porlamar', 'I. de Margarita', 'Nueva Esparta', '4980', 'Venezuela'),
    (10839::integer, 'TRADH'::text, 3::integer, '2026-01-19'::date, '2026-02-16'::date, '2026-01-22'::date, 3::integer, 35.43::real, 'Tradiçao Hipermercados', 'Av. Inês de Castro, 414', 'Sao Paulo', 'SP', '05634-030', 'Brazil'),
    (10840::integer, 'LINOD'::text, 4::integer, '2026-01-19'::date, '2026-03-02'::date, '2026-02-16'::date, 2::integer, 2.71::real, 'LINO-Delicateses', 'Ave. 5 de Mayo Porlamar', 'I. de Margarita', 'Nueva Esparta', '4980', 'Venezuela'),
    (10841::integer, 'SUPRD'::text, 5::integer, '2026-01-20'::date, '2026-02-17'::date, '2026-01-29'::date, 2::integer, 424.3::real, 'Suprêmes délices', 'Boulevard Tirou, 255', 'Charleroi', '', 'B-6000', 'Belgium'),
    (10842::integer, 'TORTU'::text, 1::integer, '2026-01-20'::date, '2026-02-17'::date, '2026-01-29'::date, 3::integer, 54.42::real, 'Tortuga Restaurante', 'Avda. Azteca 123', 'México D.F.', '', '05033', 'Mexico'),
    (10843::integer, 'VICTE'::text, 4::integer, '2026-01-21'::date, '2026-02-18'::date, '2026-01-26'::date, 2::integer, 9.26::real, 'Victuailles en stock', '2, rue du Commerce', 'Lyon', '', '69004', 'France'),
    (10844::integer, 'PICCO'::text, 8::integer, '2026-01-21'::date, '2026-02-18'::date, '2026-01-26'::date, 2::integer, 25.22::real, 'Piccolo und mehr', 'Geislweg 14', 'Salzburg', '', '5020', 'Austria'),
    (10845::integer, 'QUICK'::text, 8::integer, '2026-01-21'::date, '2026-02-04'::date, '2026-01-30'::date, 1::integer, 212.98::real, 'QUICK-Stop', 'Taucherstraße 10', 'Cunewalde', '', '01307', 'Germany'),
    (10846::integer, 'SUPRD'::text, 2::integer, '2026-01-22'::date, '2026-03-05'::date, '2026-01-23'::date, 3::integer, 56.46::real, 'Suprêmes délices', 'Boulevard Tirou, 255', 'Charleroi', '', 'B-6000', 'Belgium'),
    (10847::integer, 'SAVEA'::text, 4::integer, '2026-01-22'::date, '2026-02-05'::date, '2026-02-10'::date, 3::integer, 487.57::real, 'Save-a-lot Markets', '187 Suffolk Ln.', 'Boise', 'ID', '83720', 'USA'),
    (10848::integer, 'CONSH'::text, 7::integer, '2026-01-23'::date, '2026-02-20'::date, '2026-01-29'::date, 2::integer, 38.24::real, 'Consolidated Holdings', 'Berkeley Gardens 12  Brewery', 'London', '', 'WX1 6LT', 'UK'),
    (10849::integer, 'KOENE'::text, 9::integer, '2026-01-23'::date, '2026-02-20'::date, '2026-01-30'::date, 2::integer, 0.56::real, 'Königlich Essen', 'Maubelstr. 90', 'Brandenburg', '', '14776', 'Germany'),
    (10850::integer, 'VICTE'::text, 1::integer, '2026-01-23'::date, '2026-03-06'::date, '2026-01-30'::date, 1::integer, 49.19::real, 'Victuailles en stock', '2, rue du Commerce', 'Lyon', '', '69004', 'France'),
    (10851::integer, 'RICAR'::text, 5::integer, '2026-01-26'::date, '2026-02-23'::date, '2026-02-02'::date, 1::integer, 160.55::real, 'Ricardo Adocicados', 'Av. Copacabana, 267', 'Rio de Janeiro', 'RJ', '02389-890', 'Brazil'),
    (10852::integer, 'RATTC'::text, 8::integer, '2026-01-26'::date, '2026-02-09'::date, '2026-01-30'::date, 1::integer, 174.05::real, 'Rattlesnake Canyon Grocery', '2817 Milton Dr.', 'Albuquerque', 'NM', '87110', 'USA'),
    (10853::integer, 'BLAUS'::text, 9::integer, '2026-01-27'::date, '2026-02-24'::date, '2026-02-03'::date, 2::integer, 53.83::real, 'Blauer See Delikatessen', 'Forsterstr. 57', 'Mannheim', '', '68306', 'Germany'),
    (10854::integer, 'ERNSH'::text, 3::integer, '2026-01-27'::date, '2026-02-24'::date, '2026-02-05'::date, 2::integer, 100.22::real, 'Ernst Handel', 'Kirchgasse 6', 'Graz', '', '8010', 'Austria'),
    (10855::integer, 'OLDWO'::text, 3::integer, '2026-01-27'::date, '2026-02-24'::date, '2026-02-04'::date, 1::integer, 170.97::real, 'Old World Delicatessen', '2743 Bering St.', 'Anchorage', 'AK', '99508', 'USA'),
    (10856::integer, 'ANTON'::text, 3::integer, '2026-01-28'::date, '2026-02-25'::date, '2026-02-10'::date, 2::integer, 58.43::real, 'Antonio Moreno Taquería', 'Mataderos  2312', 'México D.F.', '', '05023', 'Mexico'),
    (10857::integer, 'BERGS'::text, 8::integer, '2026-01-28'::date, '2026-02-25'::date, '2026-02-06'::date, 2::integer, 188.85::real, 'Berglunds snabbköp', 'Berguvsvägen  8', 'Luleå', '', 'S-958 22', 'Sweden'),
    (10858::integer, 'LACOR'::text, 2::integer, '2026-01-29'::date, '2026-02-26'::date, '2026-02-03'::date, 1::integer, 52.51::real, 'La corne d''abondance', '67, avenue de l''Europe', 'Versailles', '', '78000', 'France'),
    (10859::integer, 'FRANK'::text, 1::integer, '2026-01-29'::date, '2026-02-26'::date, '2026-02-02'::date, 2::integer, 76.1::real, 'Frankenversand', 'Berliner Platz 43', 'München', '', '80805', 'Germany'),
    (10860::integer, 'FRANR'::text, 3::integer, '2026-01-29'::date, '2026-02-26'::date, '2026-02-04'::date, 3::integer, 19.26::real, 'France restauration', '54, rue Royale', 'Nantes', '', '44000', 'France'),
    (10861::integer, 'WHITC'::text, 4::integer, '2026-01-30'::date, '2026-02-27'::date, '2026-02-17'::date, 2::integer, 14.93::real, 'White Clover Markets', '1029 - 12th Ave. S.', 'Seattle', 'WA', '98124', 'USA'),
    (10862::integer, 'LEHMS'::text, 8::integer, '2026-01-30'::date, '2026-03-13'::date, '2026-02-02'::date, 2::integer, 53.23::real, 'Lehmanns Marktstand', 'Magazinweg 7', 'Frankfurt a.M.', '', '60528', 'Germany'),
    (10863::integer, 'HILAA'::text, 4::integer, '2026-02-02'::date, '2026-03-02'::date, '2026-02-17'::date, 2::integer, 30.26::real, 'HILARION-Abastos', 'Carrera 22 con Ave. Carlos Soublette #8-35', 'San Cristóbal', 'Táchira', '5022', 'Venezuela'),
    (10864::integer, 'AROUT'::text, 4::integer, '2026-02-02'::date, '2026-03-02'::date, '2026-02-09'::date, 2::integer, 3.04::real, 'Around the Horn', 'Brook Farm Stratford St. Mary', 'Colchester', 'Essex', 'CO7 6JX', 'UK'),
    (10865::integer, 'QUICK'::text, 2::integer, '2026-02-02'::date, '2026-02-16'::date, '2026-02-12'::date, 1::integer, 348.14::real, 'QUICK-Stop', 'Taucherstraße 10', 'Cunewalde', '', '01307', 'Germany'),
    (10866::integer, 'BERGS'::text, 5::integer, '2026-02-03'::date, '2026-03-03'::date, '2026-02-12'::date, 1::integer, 109.11::real, 'Berglunds snabbköp', 'Berguvsvägen  8', 'Luleå', '', 'S-958 22', 'Sweden'),
    (10867::integer, 'LONEP'::text, 6::integer, '2026-02-03'::date, '2026-03-17'::date, '2026-02-11'::date, 1::integer, 1.93::real, 'Lonesome Pine Restaurant', '89 Chiaroscuro Rd.', 'Portland', 'OR', '97219', 'USA'),
    (10868::integer, 'QUEEN'::text, 7::integer, '2026-02-04'::date, '2026-03-04'::date, '2026-02-23'::date, 2::integer, 191.27::real, 'Queen Cozinha', 'Alameda dos Canàrios, 891', 'Sao Paulo', 'SP', '05487-020', 'Brazil'),
    (10869::integer, 'SEVES'::text, 5::integer, '2026-02-04'::date, '2026-03-04'::date, '2026-02-09'::date, 1::integer, 143.28::real, 'Seven Seas Imports', '90 Wadhurst Rd.', 'London', '', 'OX15 4NB', 'UK'),
    (10870::integer, 'WOLZA'::text, 5::integer, '2026-02-04'::date, '2026-03-04'::date, '2026-02-13'::date, 3::integer, 12.04::real, 'Wolski Zajazd', 'ul. Filtrowa 68', 'Warszawa', '', '01-012', 'Poland'),
    (10871::integer, 'BONAP'::text, 9::integer, '2026-02-05'::date, '2026-03-05'::date, '2026-02-10'::date, 2::integer, 112.27::real, 'Bon app''', '12, rue des Bouchers', 'Marseille', '', '13008', 'France'),
    (10872::integer, 'GODOS'::text, 5::integer, '2026-02-05'::date, '2026-03-05'::date, '2026-02-09'::date, 2::integer, 175.32::real, 'Godos Cocina Típica', 'C/ Romero, 33', 'Sevilla', '', '41101', 'Spain'),
    (10873::integer, 'WILMK'::text, 4::integer, '2026-02-06'::date, '2026-03-06'::date, '2026-02-09'::date, 1::integer, 0.82::real, 'Wilman Kala', 'Keskuskatu 45', 'Helsinki', '', '21240', 'Finland'),
    (10874::integer, 'GODOS'::text, 5::integer, '2026-02-06'::date, '2026-03-06'::date, '2026-02-11'::date, 2::integer, 19.58::real, 'Godos Cocina Típica', 'C/ Romero, 33', 'Sevilla', '', '41101', 'Spain'),
    (10875::integer, 'BERGS'::text, 4::integer, '2026-02-06'::date, '2026-03-06'::date, '2026-03-03'::date, 2::integer, 32.37::real, 'Berglunds snabbköp', 'Berguvsvägen  8', 'Luleå', '', 'S-958 22', 'Sweden'),
    (10876::integer, 'BONAP'::text, 7::integer, '2026-02-09'::date, '2026-03-09'::date, '2026-02-12'::date, 3::integer, 60.42::real, 'Bon app''', '12, rue des Bouchers', 'Marseille', '', '13008', 'France'),
    (10877::integer, 'RICAR'::text, 1::integer, '2026-02-09'::date, '2026-03-09'::date, '2026-02-19'::date, 1::integer, 38.06::real, 'Ricardo Adocicados', 'Av. Copacabana, 267', 'Rio de Janeiro', 'RJ', '02389-890', 'Brazil'),
    (10878::integer, 'QUICK'::text, 4::integer, '2026-02-10'::date, '2026-03-10'::date, '2026-02-12'::date, 1::integer, 46.69::real, 'QUICK-Stop', 'Taucherstraße 10', 'Cunewalde', '', '01307', 'Germany'),
    (10879::integer, 'WILMK'::text, 3::integer, '2026-02-10'::date, '2026-03-10'::date, '2026-02-12'::date, 3::integer, 8.5::real, 'Wilman Kala', 'Keskuskatu 45', 'Helsinki', '', '21240', 'Finland'),
    (10880::integer, 'FOLKO'::text, 7::integer, '2026-02-10'::date, '2026-03-24'::date, '2026-02-18'::date, 1::integer, 88.01::real, 'Folk och fä HB', 'Åkergatan 24', 'Bräcke', '', 'S-844 67', 'Sweden'),
    (10881::integer, 'CACTU'::text, 4::integer, '2026-02-11'::date, '2026-03-11'::date, '2026-02-18'::date, 1::integer, 2.84::real, 'Cactus Comidas para llevar', 'Cerrito 333', 'Buenos Aires', '', '1010', 'Argentina'),
    (10882::integer, 'SAVEA'::text, 4::integer, '2026-02-11'::date, '2026-03-11'::date, '2026-02-20'::date, 3::integer, 23.1::real, 'Save-a-lot Markets', '187 Suffolk Ln.', 'Boise', 'ID', '83720', 'USA'),
    (10883::integer, 'LONEP'::text, 8::integer, '2026-02-12'::date, '2026-03-12'::date, '2026-02-20'::date, 3::integer, 0.53::real, 'Lonesome Pine Restaurant', '89 Chiaroscuro Rd.', 'Portland', 'OR', '97219', 'USA'),
    (10884::integer, 'LETSS'::text, 4::integer, '2026-02-12'::date, '2026-03-12'::date, '2026-02-13'::date, 2::integer, 90.97::real, 'Let''s Stop N Shop', '87 Polk St. Suite 5', 'San Francisco', 'CA', '94117', 'USA'),
    (10885::integer, 'SUPRD'::text, 6::integer, '2026-02-12'::date, '2026-03-12'::date, '2026-02-18'::date, 3::integer, 5.64::real, 'Suprêmes délices', 'Boulevard Tirou, 255', 'Charleroi', '', 'B-6000', 'Belgium'),
    (10886::integer, 'HANAR'::text, 1::integer, '2026-02-13'::date, '2026-03-13'::date, '2026-03-02'::date, 1::integer, 4.99::real, 'Hanari Carnes', 'Rua do Paço, 67', 'Rio de Janeiro', 'RJ', '05454-876', 'Brazil'),
    (10887::integer, 'GALED'::text, 8::integer, '2026-02-13'::date, '2026-03-13'::date, '2026-02-16'::date, 3::integer, 1.25::real, 'Galería del gastronómo', 'Rambla de Cataluña, 23', 'Barcelona', '', '8022', 'Spain'),
    (10888::integer, 'GODOS'::text, 1::integer, '2026-02-16'::date, '2026-03-16'::date, '2026-02-23'::date, 2::integer, 51.87::real, 'Godos Cocina Típica', 'C/ Romero, 33', 'Sevilla', '', '41101', 'Spain'),
    (10889::integer, 'RATTC'::text, 9::integer, '2026-02-16'::date, '2026-03-16'::date, '2026-02-23'::date, 3::integer, 280.61::real, 'Rattlesnake Canyon Grocery', '2817 Milton Dr.', 'Albuquerque', 'NM', '87110', 'USA'),
    (10890::integer, 'DUMON'::text, 7::integer, '2026-02-16'::date, '2026-03-16'::date, '2026-02-18'::date, 1::integer, 32.76::real, 'Du monde entier', '67, rue des Cinquante Otages', 'Nantes', '', '44000', 'France'),
    (10891::integer, 'LEHMS'::text, 7::integer, '2026-02-17'::date, '2026-03-17'::date, '2026-02-19'::date, 2::integer, 20.37::real, 'Lehmanns Marktstand', 'Magazinweg 7', 'Frankfurt a.M.', '', '60528', 'Germany'),
    (10892::integer, 'MAISD'::text, 4::integer, '2026-02-17'::date, '2026-03-17'::date, '2026-02-19'::date, 2::integer, 120.27::real, 'Maison Dewey', 'Rue Joseph-Bens 532', 'Bruxelles', '', 'B-1180', 'Belgium'),
    (10893::integer, 'KOENE'::text, 9::integer, '2026-02-18'::date, '2026-03-18'::date, '2026-02-20'::date, 2::integer, 77.78::real, 'Königlich Essen', 'Maubelstr. 90', 'Brandenburg', '', '14776', 'Germany'),
    (10894::integer, 'SAVEA'::text, 1::integer, '2026-02-18'::date, '2026-03-18'::date, '2026-02-20'::date, 1::integer, 116.13::real, 'Save-a-lot Markets', '187 Suffolk Ln.', 'Boise', 'ID', '83720', 'USA'),
    (10895::integer, 'ERNSH'::text, 3::integer, '2026-02-18'::date, '2026-03-18'::date, '2026-02-23'::date, 1::integer, 162.75::real, 'Ernst Handel', 'Kirchgasse 6', 'Graz', '', '8010', 'Austria'),
    (10896::integer, 'MAISD'::text, 7::integer, '2026-02-19'::date, '2026-03-19'::date, '2026-02-27'::date, 3::integer, 32.45::real, 'Maison Dewey', 'Rue Joseph-Bens 532', 'Bruxelles', '', 'B-1180', 'Belgium'),
    (10897::integer, 'HUNGO'::text, 3::integer, '2026-02-19'::date, '2026-03-19'::date, '2026-02-25'::date, 2::integer, 603.54::real, 'Hungry Owl All-Night Grocers', '8 Johnstown Road', 'Cork', 'Co. Cork', '', 'Ireland'),
    (10898::integer, 'OCEAN'::text, 4::integer, '2026-02-20'::date, '2026-03-20'::date, '2026-03-06'::date, 2::integer, 1.27::real, 'Océano Atlántico Ltda.', 'Ing. Gustavo Moncada 8585 Piso 20-A', 'Buenos Aires', '', '1010', 'Argentina'),
    (10899::integer, 'LILAS'::text, 5::integer, '2026-02-20'::date, '2026-03-20'::date, '2026-02-26'::date, 3::integer, 1.21::real, 'LILA-Supermercado', 'Carrera 52 con Ave. Bolívar #65-98 Llano Largo', 'Barquisimeto', 'Lara', '3508', 'Venezuela'),
    (10900::integer, 'WELLI'::text, 1::integer, '2026-02-20'::date, '2026-03-20'::date, '2026-03-04'::date, 2::integer, 1.66::real, 'Wellington Importadora', 'Rua do Mercado, 12', 'Resende', 'SP', '08737-363', 'Brazil'),
    (10901::integer, 'HILAA'::text, 4::integer, '2026-02-23'::date, '2026-03-23'::date, '2026-02-26'::date, 1::integer, 62.09::real, 'HILARION-Abastos', 'Carrera 22 con Ave. Carlos Soublette #8-35', 'San Cristóbal', 'Táchira', '5022', 'Venezuela'),
    (10902::integer, 'FOLKO'::text, 1::integer, '2026-02-23'::date, '2026-03-23'::date, '2026-03-03'::date, 1::integer, 44.15::real, 'Folk och fä HB', 'Åkergatan 24', 'Bräcke', '', 'S-844 67', 'Sweden'),
    (10903::integer, 'HANAR'::text, 3::integer, '2026-02-24'::date, '2026-03-24'::date, '2026-03-04'::date, 3::integer, 36.71::real, 'Hanari Carnes', 'Rua do Paço, 67', 'Rio de Janeiro', 'RJ', '05454-876', 'Brazil'),
    (10904::integer, 'WHITC'::text, 3::integer, '2026-02-24'::date, '2026-03-24'::date, '2026-02-27'::date, 3::integer, 162.95::real, 'White Clover Markets', '1029 - 12th Ave. S.', 'Seattle', 'WA', '98124', 'USA'),
    (10905::integer, 'WELLI'::text, 9::integer, '2026-02-24'::date, '2026-03-24'::date, '2026-03-06'::date, 2::integer, 13.72::real, 'Wellington Importadora', 'Rua do Mercado, 12', 'Resende', 'SP', '08737-363', 'Brazil'),
    (10906::integer, 'WOLZA'::text, 4::integer, '2026-02-25'::date, '2026-03-11'::date, '2026-03-03'::date, 3::integer, 26.29::real, 'Wolski Zajazd', 'ul. Filtrowa 68', 'Warszawa', '', '01-012', 'Poland'),
    (10907::integer, 'SPECD'::text, 6::integer, '2026-02-25'::date, '2026-03-25'::date, '2026-02-27'::date, 3::integer, 9.19::real, 'Spécialités du monde', '25, rue Lauriston', 'Paris', '', '75016', 'France'),
    (10908::integer, 'REGGC'::text, 4::integer, '2026-02-26'::date, '2026-03-26'::date, '2026-03-06'::date, 2::integer, 32.96::real, 'Reggiani Caseifici', 'Strada Provinciale 124', 'Reggio Emilia', '', '42100', 'Italy'),
    (10909::integer, 'SANTG'::text, 1::integer, '2026-02-26'::date, '2026-03-26'::date, '2026-03-10'::date, 2::integer, 53.05::real, 'Santé Gourmet', 'Erling Skakkes gate 78', 'Stavern', '', '4110', 'Norway'),
    (10910::integer, 'WILMK'::text, 1::integer, '2026-02-26'::date, '2026-03-26'::date, '2026-03-04'::date, 3::integer, 38.11::real, 'Wilman Kala', 'Keskuskatu 45', 'Helsinki', '', '21240', 'Finland'),
    (10911::integer, 'GODOS'::text, 3::integer, '2026-02-26'::date, '2026-03-26'::date, '2026-03-05'::date, 1::integer, 38.19::real, 'Godos Cocina Típica', 'C/ Romero, 33', 'Sevilla', '', '41101', 'Spain'),
    (10912::integer, 'HUNGO'::text, 2::integer, '2026-02-26'::date, '2026-03-26'::date, '2026-03-18'::date, 2::integer, 580.91::real, 'Hungry Owl All-Night Grocers', '8 Johnstown Road', 'Cork', 'Co. Cork', '', 'Ireland'),
    (10913::integer, 'QUEEN'::text, 4::integer, '2026-02-26'::date, '2026-03-26'::date, '2026-03-04'::date, 1::integer, 33.05::real, 'Queen Cozinha', 'Alameda dos Canàrios, 891', 'Sao Paulo', 'SP', '05487-020', 'Brazil'),
    (10914::integer, 'QUEEN'::text, 6::integer, '2026-02-27'::date, '2026-03-27'::date, '2026-03-02'::date, 1::integer, 21.19::real, 'Queen Cozinha', 'Alameda dos Canàrios, 891', 'Sao Paulo', 'SP', '05487-020', 'Brazil'),
    (10915::integer, 'TORTU'::text, 2::integer, '2026-02-27'::date, '2026-03-27'::date, '2026-03-02'::date, 2::integer, 3.51::real, 'Tortuga Restaurante', 'Avda. Azteca 123', 'México D.F.', '', '05033', 'Mexico'),
    (10916::integer, 'RANCH'::text, 1::integer, '2026-02-27'::date, '2026-03-27'::date, '2026-03-09'::date, 2::integer, 63.77::real, 'Rancho grande', 'Av. del Libertador 900', 'Buenos Aires', '', '1010', 'Argentina'),
    (10917::integer, 'ROMEY'::text, 4::integer, '2026-03-02'::date, '2026-03-30'::date, '2026-03-11'::date, 2::integer, 8.29::real, 'Romero y tomillo', 'Gran Vía, 1', 'Madrid', '', '28001', 'Spain'),
    (10918::integer, 'BOTTM'::text, 3::integer, '2026-03-02'::date, '2026-03-30'::date, '2026-03-11'::date, 3::integer, 48.83::real, 'Bottom-Dollar Markets', '23 Tsawassen Blvd.', 'Tsawassen', 'BC', 'T2F 8M4', 'Canada'),
    (10919::integer, 'LINOD'::text, 2::integer, '2026-03-02'::date, '2026-03-30'::date, '2026-03-04'::date, 2::integer, 19.8::real, 'LINO-Delicateses', 'Ave. 5 de Mayo Porlamar', 'I. de Margarita', 'Nueva Esparta', '4980', 'Venezuela'),
    (10920::integer, 'AROUT'::text, 4::integer, '2026-03-03'::date, '2026-03-31'::date, '2026-03-09'::date, 2::integer, 29.61::real, 'Around the Horn', 'Brook Farm Stratford St. Mary', 'Colchester', 'Essex', 'CO7 6JX', 'UK'),
    (10921::integer, 'VAFFE'::text, 1::integer, '2026-03-03'::date, '2026-04-14'::date, '2026-03-09'::date, 1::integer, 176.48::real, 'Vaffeljernet', 'Smagsloget 45', 'Århus', '', '8200', 'Denmark'),
    (10922::integer, 'HANAR'::text, 5::integer, '2026-03-03'::date, '2026-03-31'::date, '2026-03-05'::date, 3::integer, 62.74::real, 'Hanari Carnes', 'Rua do Paço, 67', 'Rio de Janeiro', 'RJ', '05454-876', 'Brazil'),
    (10923::integer, 'LAMAI'::text, 7::integer, '2026-03-03'::date, '2026-04-14'::date, '2026-03-13'::date, 3::integer, 68.26::real, 'La maison d''Asie', '1 rue Alsace-Lorraine', 'Toulouse', '', '31000', 'France'),
    (10924::integer, 'BERGS'::text, 3::integer, '2026-03-04'::date, '2026-04-01'::date, '2026-04-08'::date, 2::integer, 151.52::real, 'Berglunds snabbköp', 'Berguvsvägen  8', 'Luleå', '', 'S-958 22', 'Sweden'),
    (10925::integer, 'HANAR'::text, 3::integer, '2026-03-04'::date, '2026-04-01'::date, '2026-03-13'::date, 1::integer, 2.27::real, 'Hanari Carnes', 'Rua do Paço, 67', 'Rio de Janeiro', 'RJ', '05454-876', 'Brazil'),
    (10926::integer, 'ANATR'::text, 4::integer, '2026-03-04'::date, '2026-04-01'::date, '2026-03-11'::date, 3::integer, 39.92::real, 'Ana Trujillo Emparedados y helados', 'Avda. de la Constitución 2222', 'México D.F.', '', '05021', 'Mexico'),
    (10927::integer, 'LACOR'::text, 4::integer, '2026-03-05'::date, '2026-04-02'::date, '2026-04-08'::date, 1::integer, 19.79::real, 'La corne d''abondance', '67, avenue de l''Europe', 'Versailles', '', '78000', 'France'),
    (10928::integer, 'GALED'::text, 1::integer, '2026-03-05'::date, '2026-04-02'::date, '2026-03-18'::date, 1::integer, 1.36::real, 'Galería del gastronómo', 'Rambla de Cataluña, 23', 'Barcelona', '', '8022', 'Spain'),
    (10929::integer, 'FRANK'::text, 6::integer, '2026-03-05'::date, '2026-04-02'::date, '2026-03-12'::date, 1::integer, 33.93::real, 'Frankenversand', 'Berliner Platz 43', 'München', '', '80805', 'Germany'),
    (10930::integer, 'SUPRD'::text, 4::integer, '2026-03-06'::date, '2026-04-17'::date, '2026-03-18'::date, 3::integer, 15.55::real, 'Suprêmes délices', 'Boulevard Tirou, 255', 'Charleroi', '', 'B-6000', 'Belgium'),
    (10931::integer, 'RICSU'::text, 4::integer, '2026-03-06'::date, '2026-03-20'::date, '2026-03-19'::date, 2::integer, 13.6::real, 'Richter Supermarkt', 'Starenweg 5', 'Genève', '', '1204', 'Switzerland'),
    (10932::integer, 'BONAP'::text, 8::integer, '2026-03-06'::date, '2026-04-03'::date, '2026-03-24'::date, 1::integer, 134.64::real, 'Bon app''', '12, rue des Bouchers', 'Marseille', '', '13008', 'France'),
    (10933::integer, 'ISLAT'::text, 6::integer, '2026-03-06'::date, '2026-04-03'::date, '2026-03-16'::date, 3::integer, 54.15::real, 'Island Trading', 'Garden House Crowther Way', 'Cowes', 'Isle of Wight', 'PO31 7PJ', 'UK'),
    (10934::integer, 'LEHMS'::text, 3::integer, '2026-03-09'::date, '2026-04-06'::date, '2026-03-12'::date, 3::integer, 32.01::real, 'Lehmanns Marktstand', 'Magazinweg 7', 'Frankfurt a.M.', '', '60528', 'Germany'),
    (10935::integer, 'WELLI'::text, 4::integer, '2026-03-09'::date, '2026-04-06'::date, '2026-03-18'::date, 3::integer, 47.59::real, 'Wellington Importadora', 'Rua do Mercado, 12', 'Resende', 'SP', '08737-363', 'Brazil'),
    (10936::integer, 'GREAL'::text, 3::integer, '2026-03-09'::date, '2026-04-06'::date, '2026-03-18'::date, 2::integer, 33.68::real, 'Great Lakes Food Market', '2732 Baker Blvd.', 'Eugene', 'OR', '97403', 'USA'),
    (10937::integer, 'CACTU'::text, 7::integer, '2026-03-10'::date, '2026-03-24'::date, '2026-03-13'::date, 3::integer, 31.51::real, 'Cactus Comidas para llevar', 'Cerrito 333', 'Buenos Aires', '', '1010', 'Argentina'),
    (10938::integer, 'QUICK'::text, 3::integer, '2026-03-10'::date, '2026-04-07'::date, '2026-03-16'::date, 2::integer, 31.89::real, 'QUICK-Stop', 'Taucherstraße 10', 'Cunewalde', '', '01307', 'Germany'),
    (10939::integer, 'MAGAA'::text, 2::integer, '2026-03-10'::date, '2026-04-07'::date, '2026-03-13'::date, 2::integer, 76.33::real, 'Magazzini Alimentari Riuniti', 'Via Ludovico il Moro 22', 'Bergamo', '', '24100', 'Italy'),
    (10940::integer, 'BONAP'::text, 8::integer, '2026-03-11'::date, '2026-04-08'::date, '2026-03-23'::date, 3::integer, 19.77::real, 'Bon app''', '12, rue des Bouchers', 'Marseille', '', '13008', 'France'),
    (10941::integer, 'SAVEA'::text, 7::integer, '2026-03-11'::date, '2026-04-08'::date, '2026-03-20'::date, 2::integer, 400.81::real, 'Save-a-lot Markets', '187 Suffolk Ln.', 'Boise', 'ID', '83720', 'USA'),
    (10942::integer, 'REGGC'::text, 9::integer, '2026-03-11'::date, '2026-04-08'::date, '2026-03-18'::date, 3::integer, 17.95::real, 'Reggiani Caseifici', 'Strada Provinciale 124', 'Reggio Emilia', '', '42100', 'Italy'),
    (10943::integer, 'BSBEV'::text, 4::integer, '2026-03-11'::date, '2026-04-08'::date, '2026-03-19'::date, 2::integer, 2.17::real, 'B''s Beverages', 'Fauntleroy Circus', 'London', '', 'EC2 5NT', 'UK'),
    (10944::integer, 'BOTTM'::text, 6::integer, '2026-03-12'::date, '2026-03-26'::date, '2026-03-13'::date, 3::integer, 52.92::real, 'Bottom-Dollar Markets', '23 Tsawassen Blvd.', 'Tsawassen', 'BC', 'T2F 8M4', 'Canada'),
    (10945::integer, 'MORGK'::text, 4::integer, '2026-03-12'::date, '2026-04-09'::date, '2026-03-18'::date, 1::integer, 10.22::real, 'Morgenstern Gesundkost', 'Heerstr. 22', 'Leipzig', '', '04179', 'Germany'),
    (10946::integer, 'VAFFE'::text, 1::integer, '2026-03-12'::date, '2026-04-09'::date, '2026-03-19'::date, 2::integer, 27.2::real, 'Vaffeljernet', 'Smagsloget 45', 'Århus', '', '8200', 'Denmark'),
    (10947::integer, 'BSBEV'::text, 3::integer, '2026-03-13'::date, '2026-04-10'::date, '2026-03-16'::date, 2::integer, 3.26::real, 'B''s Beverages', 'Fauntleroy Circus', 'London', '', 'EC2 5NT', 'UK'),
    (10948::integer, 'GODOS'::text, 3::integer, '2026-03-13'::date, '2026-04-10'::date, '2026-03-19'::date, 3::integer, 23.39::real, 'Godos Cocina Típica', 'C/ Romero, 33', 'Sevilla', '', '41101', 'Spain'),
    (10949::integer, 'BOTTM'::text, 2::integer, '2026-03-13'::date, '2026-04-10'::date, '2026-03-17'::date, 3::integer, 74.44::real, 'Bottom-Dollar Markets', '23 Tsawassen Blvd.', 'Tsawassen', 'BC', 'T2F 8M4', 'Canada'),
    (10950::integer, 'MAGAA'::text, 1::integer, '2026-03-16'::date, '2026-04-13'::date, '2026-03-23'::date, 2::integer, 2.5::real, 'Magazzini Alimentari Riuniti', 'Via Ludovico il Moro 22', 'Bergamo', '', '24100', 'Italy'),
    (10951::integer, 'RICSU'::text, 9::integer, '2026-03-16'::date, '2026-04-27'::date, '2026-04-07'::date, 2::integer, 30.85::real, 'Richter Supermarkt', 'Starenweg 5', 'Genève', '', '1204', 'Switzerland'),
    (10952::integer, 'ALFKI'::text, 1::integer, '2026-03-16'::date, '2026-04-27'::date, '2026-03-24'::date, 1::integer, 40.42::real, 'Alfred''s Futterkiste', 'Obere Str. 57', 'Berlin', '', '12209', 'Germany'),
    (10953::integer, 'AROUT'::text, 9::integer, '2026-03-16'::date, '2026-03-30'::date, '2026-03-25'::date, 2::integer, 23.72::real, 'Around the Horn', 'Brook Farm Stratford St. Mary', 'Colchester', 'Essex', 'CO7 6JX', 'UK'),
    (10954::integer, 'LINOD'::text, 5::integer, '2026-03-17'::date, '2026-04-28'::date, '2026-03-20'::date, 1::integer, 27.91::real, 'LINO-Delicateses', 'Ave. 5 de Mayo Porlamar', 'I. de Margarita', 'Nueva Esparta', '4980', 'Venezuela'),
    (10955::integer, 'FOLKO'::text, 8::integer, '2026-03-17'::date, '2026-04-14'::date, '2026-03-20'::date, 2::integer, 3.26::real, 'Folk och fä HB', 'Åkergatan 24', 'Bräcke', '', 'S-844 67', 'Sweden'),
    (10956::integer, 'BLAUS'::text, 6::integer, '2026-03-17'::date, '2026-04-28'::date, '2026-03-20'::date, 2::integer, 44.65::real, 'Blauer See Delikatessen', 'Forsterstr. 57', 'Mannheim', '', '68306', 'Germany'),
    (10957::integer, 'HILAA'::text, 8::integer, '2026-03-18'::date, '2026-04-15'::date, '2026-03-27'::date, 3::integer, 105.36::real, 'HILARION-Abastos', 'Carrera 22 con Ave. Carlos Soublette #8-35', 'San Cristóbal', 'Táchira', '5022', 'Venezuela'),
    (10958::integer, 'OCEAN'::text, 7::integer, '2026-03-18'::date, '2026-04-15'::date, '2026-03-27'::date, 2::integer, 49.56::real, 'Océano Atlántico Ltda.', 'Ing. Gustavo Moncada 8585 Piso 20-A', 'Buenos Aires', '', '1010', 'Argentina'),
    (10959::integer, 'GOURL'::text, 6::integer, '2026-03-18'::date, '2026-04-29'::date, '2026-03-23'::date, 2::integer, 4.98::real, 'Gourmet Lanchonetes', 'Av. Brasil, 442', 'Campinas', 'SP', '04876-786', 'Brazil'),
    (10960::integer, 'HILAA'::text, 3::integer, '2026-03-19'::date, '2026-04-02'::date, '2026-04-08'::date, 1::integer, 2.08::real, 'HILARION-Abastos', 'Carrera 22 con Ave. Carlos Soublette #8-35', 'San Cristóbal', 'Táchira', '5022', 'Venezuela'),
    (10961::integer, 'QUEEN'::text, 8::integer, '2026-03-19'::date, '2026-04-16'::date, '2026-03-30'::date, 1::integer, 104.47::real, 'Queen Cozinha', 'Alameda dos Canàrios, 891', 'Sao Paulo', 'SP', '05487-020', 'Brazil'),
    (10962::integer, 'QUICK'::text, 8::integer, '2026-03-19'::date, '2026-04-16'::date, '2026-03-23'::date, 2::integer, 275.79::real, 'QUICK-Stop', 'Taucherstraße 10', 'Cunewalde', '', '01307', 'Germany'),
    (10963::integer, 'FURIB'::text, 9::integer, '2026-03-19'::date, '2026-04-16'::date, '2026-03-26'::date, 3::integer, 2.7::real, 'Furia Bacalhau e Frutos do Mar', 'Jardim das rosas n. 32', 'Lisboa', '', '1675', 'Portugal'),
    (10964::integer, 'SPECD'::text, 3::integer, '2026-03-20'::date, '2026-04-17'::date, '2026-03-24'::date, 2::integer, 87.38::real, 'Spécialités du monde', '25, rue Lauriston', 'Paris', '', '75016', 'France'),
    (10965::integer, 'OLDWO'::text, 6::integer, '2026-03-20'::date, '2026-04-17'::date, '2026-03-30'::date, 3::integer, 144.38::real, 'Old World Delicatessen', '2743 Bering St.', 'Anchorage', 'AK', '99508', 'USA'),
    (10966::integer, 'CHOPS'::text, 4::integer, '2026-03-20'::date, '2026-04-17'::date, '2026-04-08'::date, 1::integer, 27.19::real, 'Chop-suey Chinese', 'Hauptstr. 31', 'Bern', '', '3012', 'Switzerland'),
    (10967::integer, 'TOMSP'::text, 2::integer, '2026-03-23'::date, '2026-04-20'::date, '2026-04-02'::date, 2::integer, 62.22::real, 'Toms Spezialitäten', 'Luisenstr. 48', 'Münster', '', '44087', 'Germany'),
    (10968::integer, 'ERNSH'::text, 1::integer, '2026-03-23'::date, '2026-04-20'::date, '2026-04-01'::date, 3::integer, 74.6::real, 'Ernst Handel', 'Kirchgasse 6', 'Graz', '', '8010', 'Austria'),
    (10969::integer, 'COMMI'::text, 1::integer, '2026-03-23'::date, '2026-04-20'::date, '2026-03-30'::date, 2::integer, 0.21::real, 'Comércio Mineiro', 'Av. dos Lusíadas, 23', 'Sao Paulo', 'SP', '05432-043', 'Brazil'),
    (10970::integer, 'BOLID'::text, 9::integer, '2026-03-24'::date, '2026-04-07'::date, '2026-04-24'::date, 1::integer, 16.16::real, 'Bólido Comidas preparadas', 'C/ Araquil, 67', 'Madrid', '', '28023', 'Spain'),
    (10971::integer, 'FRANR'::text, 2::integer, '2026-03-24'::date, '2026-04-21'::date, '2026-04-02'::date, 2::integer, 121.82::real, 'France restauration', '54, rue Royale', 'Nantes', '', '44000', 'France'),
    (10972::integer, 'LACOR'::text, 4::integer, '2026-03-24'::date, '2026-04-21'::date, '2026-03-26'::date, 2::integer, 0.02::real, 'La corne d''abondance', '67, avenue de l''Europe', 'Versailles', '', '78000', 'France'),
    (10973::integer, 'LACOR'::text, 6::integer, '2026-03-24'::date, '2026-04-21'::date, '2026-03-27'::date, 2::integer, 15.17::real, 'La corne d''abondance', '67, avenue de l''Europe', 'Versailles', '', '78000', 'France'),
    (10974::integer, 'SPLIR'::text, 3::integer, '2026-03-25'::date, '2026-04-08'::date, '2026-04-03'::date, 3::integer, 12.96::real, 'Split Rail Beer & Ale', 'P.O. Box 555', 'Lander', 'WY', '82520', 'USA'),
    (10975::integer, 'BOTTM'::text, 1::integer, '2026-03-25'::date, '2026-04-22'::date, '2026-03-27'::date, 3::integer, 32.27::real, 'Bottom-Dollar Markets', '23 Tsawassen Blvd.', 'Tsawassen', 'BC', 'T2F 8M4', 'Canada'),
    (10976::integer, 'HILAA'::text, 1::integer, '2026-03-25'::date, '2026-05-06'::date, '2026-04-03'::date, 1::integer, 37.97::real, 'HILARION-Abastos', 'Carrera 22 con Ave. Carlos Soublette #8-35', 'San Cristóbal', 'Táchira', '5022', 'Venezuela'),
    (10977::integer, 'FOLKO'::text, 8::integer, '2026-03-26'::date, '2026-04-23'::date, '2026-04-10'::date, 3::integer, 208.5::real, 'Folk och fä HB', 'Åkergatan 24', 'Bräcke', '', 'S-844 67', 'Sweden'),
    (10978::integer, 'MAISD'::text, 9::integer, '2026-03-26'::date, '2026-04-23'::date, '2026-04-23'::date, 2::integer, 32.82::real, 'Maison Dewey', 'Rue Joseph-Bens 532', 'Bruxelles', '', 'B-1180', 'Belgium'),
    (10979::integer, 'ERNSH'::text, 8::integer, '2026-03-26'::date, '2026-04-23'::date, '2026-03-31'::date, 2::integer, 353.07::real, 'Ernst Handel', 'Kirchgasse 6', 'Graz', '', '8010', 'Austria'),
    (10980::integer, 'FOLKO'::text, 4::integer, '2026-03-27'::date, '2026-05-08'::date, '2026-04-17'::date, 1::integer, 1.26::real, 'Folk och fä HB', 'Åkergatan 24', 'Bräcke', '', 'S-844 67', 'Sweden'),
    (10981::integer, 'HANAR'::text, 1::integer, '2026-03-27'::date, '2026-04-24'::date, '2026-04-02'::date, 2::integer, 193.37::real, 'Hanari Carnes', 'Rua do Paço, 67', 'Rio de Janeiro', 'RJ', '05454-876', 'Brazil'),
    (10982::integer, 'BOTTM'::text, 2::integer, '2026-03-27'::date, '2026-04-24'::date, '2026-04-08'::date, 1::integer, 14.01::real, 'Bottom-Dollar Markets', '23 Tsawassen Blvd.', 'Tsawassen', 'BC', 'T2F 8M4', 'Canada'),
    (10983::integer, 'SAVEA'::text, 2::integer, '2026-03-27'::date, '2026-04-24'::date, '2026-04-06'::date, 2::integer, 657.54::real, 'Save-a-lot Markets', '187 Suffolk Ln.', 'Boise', 'ID', '83720', 'USA'),
    (10984::integer, 'SAVEA'::text, 1::integer, '2026-03-30'::date, '2026-04-27'::date, '2026-04-03'::date, 3::integer, 211.22::real, 'Save-a-lot Markets', '187 Suffolk Ln.', 'Boise', 'ID', '83720', 'USA'),
    (10985::integer, 'HUNGO'::text, 2::integer, '2026-03-30'::date, '2026-04-27'::date, '2026-04-02'::date, 1::integer, 91.51::real, 'Hungry Owl All-Night Grocers', '8 Johnstown Road', 'Cork', 'Co. Cork', '', 'Ireland'),
    (10986::integer, 'OCEAN'::text, 8::integer, '2026-03-30'::date, '2026-04-27'::date, '2026-04-21'::date, 2::integer, 217.86::real, 'Océano Atlántico Ltda.', 'Ing. Gustavo Moncada 8585 Piso 20-A', 'Buenos Aires', '', '1010', 'Argentina'),
    (10987::integer, 'EASTC'::text, 8::integer, '2026-03-31'::date, '2026-04-28'::date, '2026-04-06'::date, 1::integer, 185.48::real, 'Eastern Connection', '35 King George', 'London', '', 'WX3 6FW', 'UK'),
    (10988::integer, 'RATTC'::text, 3::integer, '2026-03-31'::date, '2026-04-28'::date, '2026-04-10'::date, 2::integer, 61.14::real, 'Rattlesnake Canyon Grocery', '2817 Milton Dr.', 'Albuquerque', 'NM', '87110', 'USA'),
    (10989::integer, 'QUEDE'::text, 2::integer, '2026-03-31'::date, '2026-04-28'::date, '2026-04-02'::date, 1::integer, 34.76::real, 'Que Delícia', 'Rua da Panificadora, 12', 'Rio de Janeiro', 'RJ', '02389-673', 'Brazil'),
    (10990::integer, 'ERNSH'::text, 2::integer, '2026-04-01'::date, '2026-05-13'::date, '2026-04-07'::date, 3::integer, 117.61::real, 'Ernst Handel', 'Kirchgasse 6', 'Graz', '', '8010', 'Austria'),
    (10991::integer, 'QUICK'::text, 1::integer, '2026-04-01'::date, '2026-04-29'::date, '2026-04-07'::date, 1::integer, 38.51::real, 'QUICK-Stop', 'Taucherstraße 10', 'Cunewalde', '', '01307', 'Germany'),
    (10992::integer, 'THEBI'::text, 1::integer, '2026-04-01'::date, '2026-04-29'::date, '2026-04-03'::date, 3::integer, 4.27::real, 'The Big Cheese', '89 Jefferson Way Suite 2', 'Portland', 'OR', '97201', 'USA'),
    (10993::integer, 'FOLKO'::text, 7::integer, '2026-04-01'::date, '2026-04-29'::date, '2026-04-10'::date, 3::integer, 8.81::real, 'Folk och fä HB', 'Åkergatan 24', 'Bräcke', '', 'S-844 67', 'Sweden'),
    (10994::integer, 'VAFFE'::text, 2::integer, '2026-04-02'::date, '2026-04-16'::date, '2026-04-09'::date, 3::integer, 65.53::real, 'Vaffeljernet', 'Smagsloget 45', 'Århus', '', '8200', 'Denmark'),
    (10995::integer, 'PERIC'::text, 1::integer, '2026-04-02'::date, '2026-04-30'::date, '2026-04-06'::date, 3::integer, 46::real, 'Pericles Comidas clásicas', 'Calle Dr. Jorge Cash 321', 'México D.F.', '', '05033', 'Mexico'),
    (10996::integer, 'QUICK'::text, 4::integer, '2026-04-02'::date, '2026-04-30'::date, '2026-04-10'::date, 2::integer, 1.12::real, 'QUICK-Stop', 'Taucherstraße 10', 'Cunewalde', '', '01307', 'Germany'),
    (10997::integer, 'LILAS'::text, 8::integer, '2026-04-03'::date, '2026-05-15'::date, '2026-04-13'::date, 2::integer, 73.91::real, 'LILA-Supermercado', 'Carrera 52 con Ave. Bolívar #65-98 Llano Largo', 'Barquisimeto', 'Lara', '3508', 'Venezuela'),
    (10998::integer, 'WOLZA'::text, 8::integer, '2026-04-03'::date, '2026-04-17'::date, '2026-04-17'::date, 2::integer, 20.31::real, 'Wolski Zajazd', 'ul. Filtrowa 68', 'Warszawa', '', '01-012', 'Poland'),
    (10999::integer, 'OTTIK'::text, 6::integer, '2026-04-03'::date, '2026-05-01'::date, '2026-04-10'::date, 2::integer, 96.35::real, 'Ottilies Käseladen', 'Mehrheimerstr. 369', 'Köln', '', '50739', 'Germany'),
    (11000::integer, 'RATTC'::text, 2::integer, '2026-04-06'::date, '2026-05-04'::date, '2026-04-14'::date, 3::integer, 55.12::real, 'Rattlesnake Canyon Grocery', '2817 Milton Dr.', 'Albuquerque', 'NM', '87110', 'USA'),
    (11001::integer, 'FOLKO'::text, 2::integer, '2026-04-06'::date, '2026-05-04'::date, '2026-04-14'::date, 2::integer, 197.3::real, 'Folk och fä HB', 'Åkergatan 24', 'Bräcke', '', 'S-844 67', 'Sweden'),
    (11002::integer, 'SAVEA'::text, 4::integer, '2026-04-06'::date, '2026-05-04'::date, '2026-04-16'::date, 1::integer, 141.16::real, 'Save-a-lot Markets', '187 Suffolk Ln.', 'Boise', 'ID', '83720', 'USA'),
    (11003::integer, 'THECR'::text, 3::integer, '2026-04-06'::date, '2026-05-04'::date, '2026-04-08'::date, 3::integer, 14.91::real, 'The Cracker Box', '55 Grizzly Peak Rd.', 'Butte', 'MT', '59801', 'USA'),
    (11004::integer, 'MAISD'::text, 3::integer, '2026-04-07'::date, '2026-05-05'::date, '2026-04-20'::date, 1::integer, 44.84::real, 'Maison Dewey', 'Rue Joseph-Bens 532', 'Bruxelles', '', 'B-1180', 'Belgium'),
    (11005::integer, 'WILMK'::text, 2::integer, '2026-04-07'::date, '2026-05-05'::date, '2026-04-10'::date, 1::integer, 0.75::real, 'Wilman Kala', 'Keskuskatu 45', 'Helsinki', '', '21240', 'Finland'),
    (11006::integer, 'GREAL'::text, 3::integer, '2026-04-07'::date, '2026-05-05'::date, '2026-04-15'::date, 2::integer, 25.19::real, 'Great Lakes Food Market', '2732 Baker Blvd.', 'Eugene', 'OR', '97403', 'USA'),
    (11007::integer, 'PRINI'::text, 8::integer, '2026-04-08'::date, '2026-05-06'::date, '2026-04-13'::date, 2::integer, 202.24::real, 'Princesa Isabel Vinhos', 'Estrada da saúde n. 58', 'Lisboa', '', '1756', 'Portugal'),
    (11008::integer, 'ERNSH'::text, 7::integer, '2026-04-08'::date, '2026-05-06'::date, NULL, 3::integer, 79.46::real, 'Ernst Handel', 'Kirchgasse 6', 'Graz', '', '8010', 'Austria'),
    (11009::integer, 'GODOS'::text, 2::integer, '2026-04-08'::date, '2026-05-06'::date, '2026-04-10'::date, 1::integer, 59.11::real, 'Godos Cocina Típica', 'C/ Romero, 33', 'Sevilla', '', '41101', 'Spain'),
    (11010::integer, 'REGGC'::text, 2::integer, '2026-04-09'::date, '2026-05-07'::date, '2026-04-21'::date, 2::integer, 28.71::real, 'Reggiani Caseifici', 'Strada Provinciale 124', 'Reggio Emilia', '', '42100', 'Italy'),
    (11011::integer, 'ALFKI'::text, 3::integer, '2026-04-09'::date, '2026-05-07'::date, '2026-04-13'::date, 1::integer, 1.21::real, 'Alfred''s Futterkiste', 'Obere Str. 57', 'Berlin', '', '12209', 'Germany'),
    (11012::integer, 'FRANK'::text, 1::integer, '2026-04-09'::date, '2026-04-23'::date, '2026-04-17'::date, 3::integer, 242.95::real, 'Frankenversand', 'Berliner Platz 43', 'München', '', '80805', 'Germany'),
    (11013::integer, 'ROMEY'::text, 2::integer, '2026-04-09'::date, '2026-05-07'::date, '2026-04-10'::date, 1::integer, 32.99::real, 'Romero y tomillo', 'Gran Vía, 1', 'Madrid', '', '28001', 'Spain'),
    (11014::integer, 'LINOD'::text, 2::integer, '2026-04-10'::date, '2026-05-08'::date, '2026-04-15'::date, 3::integer, 23.6::real, 'LINO-Delicateses', 'Ave. 5 de Mayo Porlamar', 'I. de Margarita', 'Nueva Esparta', '4980', 'Venezuela'),
    (11015::integer, 'SANTG'::text, 2::integer, '2026-04-10'::date, '2026-04-24'::date, '2026-04-20'::date, 2::integer, 4.62::real, 'Santé Gourmet', 'Erling Skakkes gate 78', 'Stavern', '', '4110', 'Norway'),
    (11016::integer, 'AROUT'::text, 9::integer, '2026-04-10'::date, '2026-05-08'::date, '2026-04-13'::date, 2::integer, 33.8::real, 'Around the Horn', 'Brook Farm Stratford St. Mary', 'Colchester', 'Essex', 'CO7 6JX', 'UK'),
    (11017::integer, 'ERNSH'::text, 9::integer, '2026-04-13'::date, '2026-05-11'::date, '2026-04-20'::date, 2::integer, 754.26::real, 'Ernst Handel', 'Kirchgasse 6', 'Graz', '', '8010', 'Austria'),
    (11018::integer, 'LONEP'::text, 4::integer, '2026-04-13'::date, '2026-05-11'::date, '2026-04-16'::date, 2::integer, 11.65::real, 'Lonesome Pine Restaurant', '89 Chiaroscuro Rd.', 'Portland', 'OR', '97219', 'USA'),
    (11019::integer, 'RANCH'::text, 6::integer, '2026-04-13'::date, '2026-05-11'::date, NULL, 3::integer, 3.17::real, 'Rancho grande', 'Av. del Libertador 900', 'Buenos Aires', '', '1010', 'Argentina'),
    (11020::integer, 'OTTIK'::text, 2::integer, '2026-04-14'::date, '2026-05-12'::date, '2026-04-16'::date, 2::integer, 43.3::real, 'Ottilies Käseladen', 'Mehrheimerstr. 369', 'Köln', '', '50739', 'Germany'),
    (11021::integer, 'QUICK'::text, 3::integer, '2026-04-14'::date, '2026-05-12'::date, '2026-04-21'::date, 1::integer, 297.18::real, 'QUICK-Stop', 'Taucherstraße 10', 'Cunewalde', '', '01307', 'Germany'),
    (11022::integer, 'HANAR'::text, 9::integer, '2026-04-14'::date, '2026-05-12'::date, '2026-05-04'::date, 2::integer, 6.27::real, 'Hanari Carnes', 'Rua do Paço, 67', 'Rio de Janeiro', 'RJ', '05454-876', 'Brazil'),
    (11023::integer, 'BSBEV'::text, 1::integer, '2026-04-14'::date, '2026-04-28'::date, '2026-04-24'::date, 2::integer, 123.83::real, 'B''s Beverages', 'Fauntleroy Circus', 'London', '', 'EC2 5NT', 'UK'),
    (11024::integer, 'EASTC'::text, 4::integer, '2026-04-15'::date, '2026-05-13'::date, '2026-04-20'::date, 1::integer, 74.36::real, 'Eastern Connection', '35 King George', 'London', '', 'WX3 6FW', 'UK'),
    (11025::integer, 'WARTH'::text, 6::integer, '2026-04-15'::date, '2026-05-13'::date, '2026-04-24'::date, 3::integer, 29.17::real, 'Wartian Herkku', 'Torikatu 38', 'Oulu', '', '90110', 'Finland'),
    (11026::integer, 'FRANS'::text, 4::integer, '2026-04-15'::date, '2026-05-13'::date, '2026-04-28'::date, 1::integer, 47.09::real, 'Franchi S.p.A.', 'Via Monte Bianco 34', 'Torino', '', '10100', 'Italy'),
    (11027::integer, 'BOTTM'::text, 1::integer, '2026-04-16'::date, '2026-05-14'::date, '2026-04-20'::date, 1::integer, 52.52::real, 'Bottom-Dollar Markets', '23 Tsawassen Blvd.', 'Tsawassen', 'BC', 'T2F 8M4', 'Canada'),
    (11028::integer, 'KOENE'::text, 2::integer, '2026-04-16'::date, '2026-05-14'::date, '2026-04-22'::date, 1::integer, 29.59::real, 'Königlich Essen', 'Maubelstr. 90', 'Brandenburg', '', '14776', 'Germany'),
    (11029::integer, 'CHOPS'::text, 4::integer, '2026-04-16'::date, '2026-05-14'::date, '2026-04-27'::date, 1::integer, 47.84::real, 'Chop-suey Chinese', 'Hauptstr. 31', 'Bern', '', '3012', 'Switzerland'),
    (11030::integer, 'SAVEA'::text, 7::integer, '2026-04-17'::date, '2026-05-15'::date, '2026-04-27'::date, 2::integer, 830.75::real, 'Save-a-lot Markets', '187 Suffolk Ln.', 'Boise', 'ID', '83720', 'USA'),
    (11031::integer, 'SAVEA'::text, 6::integer, '2026-04-17'::date, '2026-05-15'::date, '2026-04-24'::date, 2::integer, 227.22::real, 'Save-a-lot Markets', '187 Suffolk Ln.', 'Boise', 'ID', '83720', 'USA'),
    (11032::integer, 'WHITC'::text, 2::integer, '2026-04-17'::date, '2026-05-15'::date, '2026-04-23'::date, 3::integer, 606.19::real, 'White Clover Markets', '1029 - 12th Ave. S.', 'Seattle', 'WA', '98124', 'USA'),
    (11033::integer, 'RICSU'::text, 7::integer, '2026-04-17'::date, '2026-05-15'::date, '2026-04-23'::date, 3::integer, 84.74::real, 'Richter Supermarkt', 'Starenweg 5', 'Genève', '', '1204', 'Switzerland'),
    (11034::integer, 'OLDWO'::text, 8::integer, '2026-04-20'::date, '2026-06-01'::date, '2026-04-27'::date, 1::integer, 40.32::real, 'Old World Delicatessen', '2743 Bering St.', 'Anchorage', 'AK', '99508', 'USA'),
    (11035::integer, 'SUPRD'::text, 2::integer, '2026-04-20'::date, '2026-05-18'::date, '2026-04-24'::date, 2::integer, 0.17::real, 'Suprêmes délices', 'Boulevard Tirou, 255', 'Charleroi', '', 'B-6000', 'Belgium'),
    (11036::integer, 'DRACD'::text, 8::integer, '2026-04-20'::date, '2026-05-18'::date, '2026-04-22'::date, 3::integer, 149.47::real, 'Drachenblut Delikatessen', 'Walserweg 21', 'Aachen', '', '52066', 'Germany'),
    (11037::integer, 'GODOS'::text, 7::integer, '2026-04-21'::date, '2026-05-19'::date, '2026-04-27'::date, 1::integer, 3.2::real, 'Godos Cocina Típica', 'C/ Romero, 33', 'Sevilla', '', '41101', 'Spain'),
    (11038::integer, 'SUPRD'::text, 1::integer, '2026-04-21'::date, '2026-05-19'::date, '2026-04-30'::date, 2::integer, 29.59::real, 'Suprêmes délices', 'Boulevard Tirou, 255', 'Charleroi', '', 'B-6000', 'Belgium'),
    (11039::integer, 'LINOD'::text, 1::integer, '2026-04-21'::date, '2026-05-19'::date, NULL, 2::integer, 65::real, 'LINO-Delicateses', 'Ave. 5 de Mayo Porlamar', 'I. de Margarita', 'Nueva Esparta', '4980', 'Venezuela'),
    (11040::integer, 'GREAL'::text, 4::integer, '2026-04-22'::date, '2026-05-20'::date, NULL, 3::integer, 18.84::real, 'Great Lakes Food Market', '2732 Baker Blvd.', 'Eugene', 'OR', '97403', 'USA'),
    (11041::integer, 'CHOPS'::text, 3::integer, '2026-04-22'::date, '2026-05-20'::date, '2026-04-28'::date, 2::integer, 48.22::real, 'Chop-suey Chinese', 'Hauptstr. 31', 'Bern', '', '3012', 'Switzerland'),
    (11042::integer, 'COMMI'::text, 2::integer, '2026-04-22'::date, '2026-05-06'::date, '2026-05-01'::date, 1::integer, 29.99::real, 'Comércio Mineiro', 'Av. dos Lusíadas, 23', 'Sao Paulo', 'SP', '05432-043', 'Brazil'),
    (11043::integer, 'SPECD'::text, 5::integer, '2026-04-22'::date, '2026-05-20'::date, '2026-04-29'::date, 2::integer, 8.8::real, 'Spécialités du monde', '25, rue Lauriston', 'Paris', '', '75016', 'France'),
    (11044::integer, 'WOLZA'::text, 4::integer, '2026-04-23'::date, '2026-05-21'::date, '2026-05-01'::date, 1::integer, 8.72::real, 'Wolski Zajazd', 'ul. Filtrowa 68', 'Warszawa', '', '01-012', 'Poland'),
    (11045::integer, 'BOTTM'::text, 6::integer, '2026-04-23'::date, '2026-05-21'::date, NULL, 2::integer, 70.58::real, 'Bottom-Dollar Markets', '23 Tsawassen Blvd.', 'Tsawassen', 'BC', 'T2F 8M4', 'Canada'),
    (11046::integer, 'WANDK'::text, 8::integer, '2026-04-23'::date, '2026-05-21'::date, '2026-04-24'::date, 2::integer, 71.64::real, 'Die Wandernde Kuh', 'Adenauerallee 900', 'Stuttgart', '', '70563', 'Germany'),
    (11047::integer, 'EASTC'::text, 7::integer, '2026-04-24'::date, '2026-05-22'::date, '2026-05-01'::date, 3::integer, 46.62::real, 'Eastern Connection', '35 King George', 'London', '', 'WX3 6FW', 'UK'),
    (11048::integer, 'BOTTM'::text, 7::integer, '2026-04-24'::date, '2026-05-22'::date, '2026-04-30'::date, 3::integer, 24.12::real, 'Bottom-Dollar Markets', '23 Tsawassen Blvd.', 'Tsawassen', 'BC', 'T2F 8M4', 'Canada'),
    (11049::integer, 'GOURL'::text, 3::integer, '2026-04-24'::date, '2026-05-22'::date, '2026-05-04'::date, 1::integer, 8.34::real, 'Gourmet Lanchonetes', 'Av. Brasil, 442', 'Campinas', 'SP', '04876-786', 'Brazil'),
    (11050::integer, 'FOLKO'::text, 8::integer, '2026-04-27'::date, '2026-05-25'::date, '2026-05-05'::date, 2::integer, 59.41::real, 'Folk och fä HB', 'Åkergatan 24', 'Bräcke', '', 'S-844 67', 'Sweden'),
    (11051::integer, 'LAMAI'::text, 7::integer, '2026-04-27'::date, '2026-05-25'::date, NULL, 3::integer, 2.79::real, 'La maison d''Asie', '1 rue Alsace-Lorraine', 'Toulouse', '', '31000', 'France'),
    (11052::integer, 'HANAR'::text, 3::integer, '2026-04-27'::date, '2026-05-25'::date, '2026-05-01'::date, 1::integer, 67.26::real, 'Hanari Carnes', 'Rua do Paço, 67', 'Rio de Janeiro', 'RJ', '05454-876', 'Brazil'),
    (11053::integer, 'PICCO'::text, 2::integer, '2026-04-27'::date, '2026-05-25'::date, '2026-04-29'::date, 2::integer, 53.05::real, 'Piccolo und mehr', 'Geislweg 14', 'Salzburg', '', '5020', 'Austria'),
    (11054::integer, 'CACTU'::text, 8::integer, '2026-04-28'::date, '2026-05-26'::date, NULL, 1::integer, 0.33::real, 'Cactus Comidas para llevar', 'Cerrito 333', 'Buenos Aires', '', '1010', 'Argentina'),
    (11055::integer, 'HILAA'::text, 7::integer, '2026-04-28'::date, '2026-05-26'::date, '2026-05-05'::date, 2::integer, 120.92::real, 'HILARION-Abastos', 'Carrera 22 con Ave. Carlos Soublette #8-35', 'San Cristóbal', 'Táchira', '5022', 'Venezuela'),
    (11056::integer, 'EASTC'::text, 8::integer, '2026-04-28'::date, '2026-05-12'::date, '2026-05-01'::date, 2::integer, 278.96::real, 'Eastern Connection', '35 King George', 'London', '', 'WX3 6FW', 'UK'),
    (11057::integer, 'NORTS'::text, 3::integer, '2026-04-29'::date, '2026-05-27'::date, '2026-05-01'::date, 3::integer, 4.13::real, 'North/South', 'South House 300 Queensbridge', 'London', '', 'SW7 1RZ', 'UK'),
    (11058::integer, 'BLAUS'::text, 9::integer, '2026-04-29'::date, '2026-05-27'::date, NULL, 3::integer, 31.14::real, 'Blauer See Delikatessen', 'Forsterstr. 57', 'Mannheim', '', '68306', 'Germany'),
    (11059::integer, 'RICAR'::text, 2::integer, '2026-04-29'::date, '2026-06-10'::date, NULL, 2::integer, 85.8::real, 'Ricardo Adocicados', 'Av. Copacabana, 267', 'Rio de Janeiro', 'RJ', '02389-890', 'Brazil'),
    (11060::integer, 'FRANS'::text, 2::integer, '2026-04-30'::date, '2026-05-28'::date, '2026-05-04'::date, 2::integer, 10.98::real, 'Franchi S.p.A.', 'Via Monte Bianco 34', 'Torino', '', '10100', 'Italy'),
    (11061::integer, 'GREAL'::text, 4::integer, '2026-04-30'::date, '2026-06-11'::date, NULL, 3::integer, 14.01::real, 'Great Lakes Food Market', '2732 Baker Blvd.', 'Eugene', 'OR', '97403', 'USA'),
    (11062::integer, 'REGGC'::text, 4::integer, '2026-04-30'::date, '2026-05-28'::date, NULL, 2::integer, 29.93::real, 'Reggiani Caseifici', 'Strada Provinciale 124', 'Reggio Emilia', '', '42100', 'Italy'),
    (11063::integer, 'HUNGO'::text, 3::integer, '2026-04-30'::date, '2026-05-28'::date, '2026-05-06'::date, 2::integer, 81.73::real, 'Hungry Owl All-Night Grocers', '8 Johnstown Road', 'Cork', 'Co. Cork', '', 'Ireland'),
    (11064::integer, 'SAVEA'::text, 1::integer, '2026-05-01'::date, '2026-05-29'::date, '2026-05-04'::date, 1::integer, 30.09::real, 'Save-a-lot Markets', '187 Suffolk Ln.', 'Boise', 'ID', '83720', 'USA'),
    (11065::integer, 'LILAS'::text, 8::integer, '2026-05-01'::date, '2026-05-29'::date, NULL, 1::integer, 12.91::real, 'LILA-Supermercado', 'Carrera 52 con Ave. Bolívar #65-98 Llano Largo', 'Barquisimeto', 'Lara', '3508', 'Venezuela'),
    (11066::integer, 'WHITC'::text, 7::integer, '2026-05-01'::date, '2026-05-29'::date, '2026-05-04'::date, 2::integer, 44.72::real, 'White Clover Markets', '1029 - 12th Ave. S.', 'Seattle', 'WA', '98124', 'USA'),
    (11067::integer, 'DRACD'::text, 1::integer, '2026-05-04'::date, '2026-05-18'::date, '2026-05-06'::date, 2::integer, 7.98::real, 'Drachenblut Delikatessen', 'Walserweg 21', 'Aachen', '', '52066', 'Germany'),
    (11068::integer, 'QUEEN'::text, 8::integer, '2026-05-04'::date, '2026-06-01'::date, NULL, 2::integer, 81.75::real, 'Queen Cozinha', 'Alameda dos Canàrios, 891', 'Sao Paulo', 'SP', '05487-020', 'Brazil'),
    (11069::integer, 'TORTU'::text, 1::integer, '2026-05-04'::date, '2026-06-01'::date, '2026-05-06'::date, 2::integer, 15.67::real, 'Tortuga Restaurante', 'Avda. Azteca 123', 'México D.F.', '', '05033', 'Mexico'),
    (11070::integer, 'LEHMS'::text, 2::integer, '2026-05-05'::date, '2026-06-02'::date, NULL, 1::integer, 136::real, 'Lehmanns Marktstand', 'Magazinweg 7', 'Frankfurt a.M.', '', '60528', 'Germany'),
    (11071::integer, 'LILAS'::text, 1::integer, '2026-05-05'::date, '2026-06-02'::date, NULL, 1::integer, 0.93::real, 'LILA-Supermercado', 'Carrera 52 con Ave. Bolívar #65-98 Llano Largo', 'Barquisimeto', 'Lara', '3508', 'Venezuela'),
    (11072::integer, 'ERNSH'::text, 4::integer, '2026-05-05'::date, '2026-06-02'::date, NULL, 2::integer, 258.64::real, 'Ernst Handel', 'Kirchgasse 6', 'Graz', '', '8010', 'Austria'),
    (11073::integer, 'PERIC'::text, 2::integer, '2026-05-05'::date, '2026-06-02'::date, NULL, 2::integer, 24.95::real, 'Pericles Comidas clásicas', 'Calle Dr. Jorge Cash 321', 'México D.F.', '', '05033', 'Mexico'),
    (11074::integer, 'SIMOB'::text, 7::integer, '2026-05-06'::date, '2026-06-03'::date, NULL, 2::integer, 18.44::real, 'Simons bistro', 'Vinbæltet 34', 'Kobenhavn', '', '1734', 'Denmark'),
    (11075::integer, 'RICSU'::text, 8::integer, '2026-05-06'::date, '2026-06-03'::date, NULL, 2::integer, 6.19::real, 'Richter Supermarkt', 'Starenweg 5', 'Genève', '', '1204', 'Switzerland'),
    (11076::integer, 'BONAP'::text, 4::integer, '2026-05-06'::date, '2026-06-03'::date, NULL, 2::integer, 38.28::real, 'Bon app''', '12, rue des Bouchers', 'Marseille', '', '13008', 'France'),
    (11077::integer, 'RATTC'::text, 1::integer, '2026-05-06'::date, '2026-06-03'::date, NULL, 2::integer, 8.53::real, 'Rattlesnake Canyon Grocery', '2817 Milton Dr.', 'Albuquerque', 'NM', '87110', 'USA')
) AS d(order_id, cust_code, employee_id, order_date, required_date, shipped_date, ship_via, freight, ship_name, ship_address, ship_city, ship_region, ship_postal_code, ship_country)
JOIN customer_map c ON c.code = d.cust_code;

-- suppliers
INSERT INTO suppliers (id, company_name, contact_name, contact_title, address, city, region, postal_code, country, phone, fax, homepage) VALUES
    (1, 'Exotic Liquids', 'Charlotte Cooper', 'Purchasing Manager', '49 Gilbert St.', 'London', '', 'EC1 4SD', 'UK', '(171) 555-2222', '', ''),
    (2, 'New Orleans Cajun Delights', 'Shelley Burke', 'Order Administrator', 'P.O. Box 78934', 'New Orleans', 'LA', '70117', 'USA', '(100) 555-4822', '', '#CAJUN.HTM#'),
    (3, 'Grandma Kelly''s Homestead', 'Regina Murphy', 'Sales Representative', '707 Oxford Rd.', 'Ann Arbor', 'MI', '48104', 'USA', '(313) 555-5735', '(313) 555-3349', ''),
    (4, 'Tokyo Traders', 'Yoshi Nagase', 'Marketing Manager', '9-8 Sekimai Musashino-shi', 'Tokyo', '', '100', 'Japan', '(03) 3555-5011', '', ''),
    (5, 'Cooperativa de Quesos ''Las Cabras''', 'Antonio del Valle Saavedra', 'Export Administrator', 'Calle del Rosal 4', 'Oviedo', 'Asturias', '33007', 'Spain', '(98) 598 76 54', '', ''),
    (6, 'Mayumi''s', 'Mayumi Ohno', 'Marketing Representative', '92 Setsuko Chuo-ku', 'Osaka', '', '545', 'Japan', '(06) 431-7877', '', 'Mayumi''s (on the World Wide Web)#http://www.microsoft.com/accessdev/sampleapps/mayumi.htm#'),
    (7, 'Pavlova, Ltd.', 'Ian Devling', 'Marketing Manager', '74 Rose St. Moonie Ponds', 'Melbourne', 'Victoria', '3058', 'Australia', '(03) 444-2343', '(03) 444-6588', ''),
    (8, 'Specialty Biscuits, Ltd.', 'Peter Wilson', 'Sales Representative', '29 King''s Way', 'Manchester', '', 'M14 GSD', 'UK', '(161) 555-4448', '', ''),
    (9, 'PB Knäckebröd AB', 'Lars Peterson', 'Sales Agent', 'Kaloadagatan 13', 'Göteborg', '', 'S-345 67', 'Sweden', '031-987 65 43', '031-987 65 91', ''),
    (10, 'Refrescos Americanas LTDA', 'Carlos Diaz', 'Marketing Manager', 'Av. das Americanas 12.890', 'Sao Paulo', '', '5442', 'Brazil', '(11) 555 4640', '', ''),
    (11, 'Heli Süßwaren GmbH & Co. KG', 'Petra Winkler', 'Sales Manager', 'Tiergartenstraße 5', 'Berlin', '', '10785', 'Germany', '(010) 9984510', '', ''),
    (12, 'Plutzer Lebensmittelgroßmärkte AG', 'Martin Bein', 'International Marketing Mgr.', 'Bogenallee 51', 'Frankfurt', '', '60439', 'Germany', '(069) 992755', '', 'Plutzer (on the World Wide Web)#http://www.microsoft.com/accessdev/sampleapps/plutzer.htm#'),
    (13, 'Nord-Ost-Fisch Handelsgesellschaft mbH', 'Sven Petersen', 'Coordinator Foreign Markets', 'Frahmredder 112a', 'Cuxhaven', '', '27478', 'Germany', '(04721) 8713', '(04721) 8714', ''),
    (14, 'Formaggi Fortini s.r.l.', 'Elio Rossi', 'Sales Representative', 'Viale Dante, 75', 'Ravenna', '', '48100', 'Italy', '(0544) 60323', '(0544) 60603', '#FORMAGGI.HTM#'),
    (15, 'Norske Meierier', 'Beate Vileid', 'Marketing Manager', 'Hatlevegen 5', 'Sandvika', '', '1320', 'Norway', '(0)2-953010', '', ''),
    (16, 'Bigfoot Breweries', 'Cheryl Saylor', 'Regional Account Rep.', '3400 - 8th Avenue Suite 210', 'Bend', 'OR', '97101', 'USA', '(503) 555-9931', '', ''),
    (17, 'Svensk Sjöföda AB', 'Michael Björn', 'Sales Representative', 'Brovallavägen 231', 'Stockholm', '', 'S-123 45', 'Sweden', '08-123 45 67', '', ''),
    (18, 'Aux joyeux ecclésiastiques', 'Guylène Nodier', 'Sales Manager', '203, Rue des Francs-Bourgeois', 'Paris', '', '75004', 'France', '(1) 03.83.00.68', '(1) 03.83.00.62', ''),
    (19, 'New England Seafood Cannery', 'Robb Merchant', 'Wholesale Account Agent', 'Order Processing Dept. 2100 Paul Revere Blvd.', 'Boston', 'MA', '02134', 'USA', '(617) 555-3267', '(617) 555-3389', ''),
    (20, 'Leka Trading', 'Chandra Leka', 'Owner', '471 Serangoon Loop, Suite #402', 'Singapore', '', '0512', 'Singapore', '555-8787', '', ''),
    (21, 'Lyngbysild', 'Niels Petersen', 'Sales Manager', 'Lyngbysild Fiskebakken 10', 'Lyngby', '', '2800', 'Denmark', '43844108', '43844115', ''),
    (22, 'Zaanse Snoepfabriek', 'Dirk Luchte', 'Accounting Manager', 'Verkoop Rijnweg 22', 'Zaandam', '', '9999 ZZ', 'Netherlands', '(12345) 1212', '(12345) 1210', ''),
    (23, 'Karkki Oy', 'Anne Heikkonen', 'Product Manager', 'Valtakatu 12', 'Lappeenranta', '', '53120', 'Finland', '(953) 10956', '', ''),
    (24, 'G''day, Mate', 'Wendy Mackenzie', 'Sales Representative', '170 Prince Edward Parade Hunter''s Hill', 'Sydney', 'NSW', '2042', 'Australia', '(02) 555-5914', '(02) 555-4873', 'G''day Mate (on the World Wide Web)#http://www.microsoft.com/accessdev/sampleapps/gdaymate.htm#'),
    (25, 'Ma Maison', 'Jean-Guy Lauzon', 'Marketing Manager', '2960 Rue St. Laurent', 'Montréal', 'Québec', 'H1J 1C3', 'Canada', '(514) 555-9022', '', ''),
    (26, 'Pasta Buttini s.r.l.', 'Giovanni Giudici', 'Order Administrator', 'Via dei Gelsomini, 153', 'Salerno', '', '84100', 'Italy', '(089) 6547665', '(089) 6547667', ''),
    (27, 'Escargots Nouveaux', 'Marie Delamare', 'Sales Manager', '22, rue H. Voiron', 'Montceau', '', '71300', 'France', '85.57.00.07', '', ''),
    (28, 'Gai pâturage', 'Eliane Noz', 'Sales Representative', 'Bat. B 3, rue des Alpes', 'Annecy', '', '74000', 'France', '38.76.98.06', '38.76.98.58', ''),
    (29, 'Forêts d''érables', 'Chantal Goulet', 'Accounting Manager', '148 rue Chasseur', 'Ste-Hyacinthe', 'Québec', 'J2S 7S8', 'Canada', '(514) 555-2955', '(514) 555-2921', '');

-- products
INSERT INTO products (id, product_name, supplier_id, category_id, quantity_per_unit, unit_price, units_in_stock, units_on_order, reorder_level, discontinued) VALUES
    (1, 'Chai', 8, 1, '10 boxes x 30 bags', 18, 39, 0, 10, TRUE),
    (2, 'Chang', 1, 1, '24 - 12 oz bottles', 19, 17, 40, 25, TRUE),
    (3, 'Aniseed Syrup', 1, 2, '12 - 550 ml bottles', 10, 13, 70, 25, FALSE),
    (4, 'Chef Anton''s Cajun Seasoning', 2, 2, '48 - 6 oz jars', 22, 53, 0, 0, FALSE),
    (5, 'Chef Anton''s Gumbo Mix', 2, 2, '36 boxes', 21.35, 0, 0, 0, TRUE),
    (6, 'Grandma''s Boysenberry Spread', 3, 2, '12 - 8 oz jars', 25, 120, 0, 25, FALSE),
    (7, 'Uncle Bob''s Organic Dried Pears', 3, 7, '12 - 1 lb pkgs.', 30, 15, 0, 10, FALSE),
    (8, 'Northwoods Cranberry Sauce', 3, 2, '12 - 12 oz jars', 40, 6, 0, 0, FALSE),
    (9, 'Mishi Kobe Niku', 4, 6, '18 - 500 g pkgs.', 97, 29, 0, 0, TRUE),
    (10, 'Ikura', 4, 8, '12 - 200 ml jars', 31, 31, 0, 0, FALSE),
    (11, 'Queso Cabrales', 5, 4, '1 kg pkg.', 21, 22, 30, 30, FALSE),
    (12, 'Queso Manchego La Pastora', 5, 4, '10 - 500 g pkgs.', 38, 86, 0, 0, FALSE),
    (13, 'Konbu', 6, 8, '2 kg box', 6, 24, 0, 5, FALSE),
    (14, 'Tofu', 6, 7, '40 - 100 g pkgs.', 23.25, 35, 0, 0, FALSE),
    (15, 'Genen Shouyu', 6, 2, '24 - 250 ml bottles', 13, 39, 0, 5, FALSE),
    (16, 'Pavlova', 7, 3, '32 - 500 g boxes', 17.45, 29, 0, 10, FALSE),
    (17, 'Alice Mutton', 7, 6, '20 - 1 kg tins', 39, 0, 0, 0, TRUE),
    (18, 'Carnarvon Tigers', 7, 8, '16 kg pkg.', 62.5, 42, 0, 0, FALSE),
    (19, 'Teatime Chocolate Biscuits', 8, 3, '10 boxes x 12 pieces', 9.2, 25, 0, 5, FALSE),
    (20, 'Sir Rodney''s Marmalade', 8, 3, '30 gift boxes', 81, 40, 0, 0, FALSE),
    (21, 'Sir Rodney''s Scones', 8, 3, '24 pkgs. x 4 pieces', 10, 3, 40, 5, FALSE),
    (22, 'Gustaf''s Knäckebröd', 9, 5, '24 - 500 g pkgs.', 21, 104, 0, 25, FALSE),
    (23, 'Tunnbröd', 9, 5, '12 - 250 g pkgs.', 9, 61, 0, 25, FALSE),
    (24, 'Guaraná Fantástica', 10, 1, '12 - 355 ml cans', 4.5, 20, 0, 0, TRUE),
    (25, 'NuNuCa Nuß-Nougat-Creme', 11, 3, '20 - 450 g glasses', 14, 76, 0, 30, FALSE),
    (26, 'Gumbär Gummibärchen', 11, 3, '100 - 250 g bags', 31.23, 15, 0, 0, FALSE),
    (27, 'Schoggi Schokolade', 11, 3, '100 - 100 g pieces', 43.9, 49, 0, 30, FALSE),
    (28, 'Rössle Sauerkraut', 12, 7, '25 - 825 g cans', 45.6, 26, 0, 0, TRUE),
    (29, 'Thüringer Rostbratwurst', 12, 6, '50 bags x 30 sausgs.', 123.79, 0, 0, 0, TRUE),
    (30, 'Nord-Ost Matjeshering', 13, 8, '10 - 200 g glasses', 25.89, 10, 0, 15, FALSE),
    (31, 'Gorgonzola Telino', 14, 4, '12 - 100 g pkgs', 12.5, 0, 70, 20, FALSE),
    (32, 'Mascarpone Fabioli', 14, 4, '24 - 200 g pkgs.', 32, 9, 40, 25, FALSE),
    (33, 'Geitost', 15, 4, '500 g', 2.5, 112, 0, 20, FALSE),
    (34, 'Sasquatch Ale', 16, 1, '24 - 12 oz bottles', 14, 111, 0, 15, FALSE),
    (35, 'Steeleye Stout', 16, 1, '24 - 12 oz bottles', 18, 20, 0, 15, FALSE),
    (36, 'Inlagd Sill', 17, 8, '24 - 250 g  jars', 19, 112, 0, 20, FALSE),
    (37, 'Gravad lax', 17, 8, '12 - 500 g pkgs.', 26, 11, 50, 25, FALSE),
    (38, 'Côte de Blaye', 18, 1, '12 - 75 cl bottles', 263.5, 17, 0, 15, FALSE),
    (39, 'Chartreuse verte', 18, 1, '750 cc per bottle', 18, 69, 0, 5, FALSE),
    (40, 'Boston Crab Meat', 19, 8, '24 - 4 oz tins', 18.4, 123, 0, 30, FALSE),
    (41, 'Jack''s New England Clam Chowder', 19, 8, '12 - 12 oz cans', 9.65, 85, 0, 10, FALSE),
    (42, 'Singaporean Hokkien Fried Mee', 20, 5, '32 - 1 kg pkgs.', 14, 26, 0, 0, TRUE),
    (43, 'Ipoh Coffee', 20, 1, '16 - 500 g tins', 46, 17, 10, 25, FALSE),
    (44, 'Gula Malacca', 20, 2, '20 - 2 kg bags', 19.45, 27, 0, 15, FALSE),
    (45, 'Rogede sild', 21, 8, '1k pkg.', 9.5, 5, 70, 15, FALSE),
    (46, 'Spegesild', 21, 8, '4 - 450 g glasses', 12, 95, 0, 0, FALSE),
    (47, 'Zaanse koeken', 22, 3, '10 - 4 oz boxes', 9.5, 36, 0, 0, FALSE),
    (48, 'Chocolade', 22, 3, '10 pkgs.', 12.75, 15, 70, 25, FALSE),
    (49, 'Maxilaku', 23, 3, '24 - 50 g pkgs.', 20, 10, 60, 15, FALSE),
    (50, 'Valkoinen suklaa', 23, 3, '12 - 100 g bars', 16.25, 65, 0, 30, FALSE),
    (51, 'Manjimup Dried Apples', 24, 7, '50 - 300 g pkgs.', 53, 20, 0, 10, FALSE),
    (52, 'Filo Mix', 24, 5, '16 - 2 kg boxes', 7, 38, 0, 25, FALSE),
    (53, 'Perth Pasties', 24, 6, '48 pieces', 32.8, 0, 0, 0, TRUE),
    (54, 'Tourtière', 25, 6, '16 pies', 7.45, 21, 0, 10, FALSE),
    (55, 'Pâté chinois', 25, 6, '24 boxes x 2 pies', 24, 115, 0, 20, FALSE),
    (56, 'Gnocchi di nonna Alice', 26, 5, '24 - 250 g pkgs.', 38, 21, 10, 30, FALSE),
    (57, 'Ravioli Angelo', 26, 5, '24 - 250 g pkgs.', 19.5, 36, 0, 20, FALSE),
    (58, 'Escargots de Bourgogne', 27, 8, '24 pieces', 13.25, 62, 0, 20, FALSE),
    (59, 'Raclette Courdavault', 28, 4, '5 kg pkg.', 55, 79, 0, 0, FALSE),
    (60, 'Camembert Pierrot', 28, 4, '15 - 300 g rounds', 34, 19, 0, 0, FALSE),
    (61, 'Sirop d''érable', 29, 2, '24 - 500 ml bottles', 28.5, 113, 0, 25, FALSE),
    (62, 'Tarte au sucre', 29, 3, '48 pies', 49.3, 17, 0, 0, FALSE),
    (63, 'Vegie-spread', 7, 2, '15 - 625 g jars', 43.9, 24, 0, 5, FALSE),
    (64, 'Wimmers gute Semmelknödel', 12, 5, '20 bags x 4 pieces', 33.25, 22, 80, 30, FALSE),
    (65, 'Louisiana Fiery Hot Pepper Sauce', 2, 2, '32 - 8 oz bottles', 21.05, 76, 0, 0, FALSE),
    (66, 'Louisiana Hot Spiced Okra', 2, 2, '24 - 8 oz jars', 17, 4, 100, 20, FALSE),
    (67, 'Laughing Lumberjack Lager', 16, 1, '24 - 12 oz bottles', 14, 52, 0, 10, FALSE),
    (68, 'Scottish Longbreads', 8, 3, '10 boxes x 8 pieces', 12.5, 6, 10, 15, FALSE),
    (69, 'Gudbrandsdalsost', 15, 4, '10 kg pkg.', 36, 26, 0, 15, FALSE),
    (70, 'Outback Lager', 7, 1, '24 - 355 ml bottles', 15, 15, 10, 30, FALSE),
    (71, 'Flotemysost', 15, 4, '10 - 500 g pkgs.', 21.5, 26, 0, 0, FALSE),
    (72, 'Mozzarella di Giovanni', 14, 4, '24 - 200 g pkgs.', 34.8, 14, 0, 0, FALSE),
    (73, 'Röd Kaviar', 17, 8, '24 - 150 g jars', 15, 101, 0, 5, FALSE),
    (74, 'Longlife Tofu', 4, 7, '5 kg pkg.', 10, 4, 20, 5, FALSE),
    (75, 'Rhönbräu Klosterbier', 12, 1, '24 - 0.5 l bottles', 7.75, 125, 0, 25, FALSE),
    (76, 'Lakkalikööri', 23, 1, '500 ml', 18, 57, 0, 20, FALSE),
    (77, 'Original Frankfurter grüne Soße', 12, 2, '12 boxes', 13, 32, 0, 15, FALSE);

-- order_details
INSERT INTO order_details (order_id, product_id, unit_price, quantity, discount) VALUES
    (10248, 11, 14, 12, 0),
    (10248, 42, 9.8, 10, 0),
    (10248, 72, 34.8, 5, 0),
    (10249, 14, 18.6, 9, 0),
    (10249, 51, 42.4, 40, 0),
    (10250, 41, 7.7, 10, 0),
    (10250, 51, 42.4, 35, 0.15),
    (10250, 65, 16.8, 15, 0.15),
    (10251, 22, 16.8, 6, 0.05),
    (10251, 57, 15.6, 15, 0.05),
    (10251, 65, 16.8, 20, 0),
    (10252, 20, 64.8, 40, 0.05),
    (10252, 33, 2, 25, 0.05),
    (10252, 60, 27.2, 40, 0),
    (10253, 31, 10, 20, 0),
    (10253, 39, 14.4, 42, 0),
    (10253, 49, 16, 40, 0),
    (10254, 24, 3.6, 15, 0.15),
    (10254, 55, 19.2, 21, 0.15),
    (10254, 74, 8, 21, 0),
    (10255, 2, 15.2, 20, 0),
    (10255, 16, 13.9, 35, 0),
    (10255, 36, 15.2, 25, 0),
    (10255, 59, 44, 30, 0),
    (10256, 53, 26.2, 15, 0),
    (10256, 77, 10.4, 12, 0),
    (10257, 27, 35.1, 25, 0),
    (10257, 39, 14.4, 6, 0),
    (10257, 77, 10.4, 15, 0),
    (10258, 2, 15.2, 50, 0.2),
    (10258, 5, 17, 65, 0.2),
    (10258, 32, 25.6, 6, 0.2),
    (10259, 21, 8, 10, 0),
    (10259, 37, 20.8, 1, 0),
    (10260, 41, 7.7, 16, 0.25),
    (10260, 57, 15.6, 50, 0),
    (10260, 62, 39.4, 15, 0.25),
    (10260, 70, 12, 21, 0.25),
    (10261, 21, 8, 20, 0),
    (10261, 35, 14.4, 20, 0),
    (10262, 5, 17, 12, 0.2),
    (10262, 7, 24, 15, 0),
    (10262, 56, 30.4, 2, 0),
    (10263, 16, 13.9, 60, 0.25),
    (10263, 24, 3.6, 28, 0),
    (10263, 30, 20.7, 60, 0.25),
    (10263, 74, 8, 36, 0.25),
    (10264, 2, 15.2, 35, 0),
    (10264, 41, 7.7, 25, 0.15),
    (10265, 17, 31.2, 30, 0),
    (10265, 70, 12, 20, 0),
    (10266, 12, 30.4, 12, 0.05),
    (10267, 40, 14.7, 50, 0),
    (10267, 59, 44, 70, 0.15),
    (10267, 76, 14.4, 15, 0.15),
    (10268, 29, 99, 10, 0),
    (10268, 72, 27.8, 4, 0),
    (10269, 33, 2, 60, 0.05),
    (10269, 72, 27.8, 20, 0.05),
    (10270, 36, 15.2, 30, 0),
    (10270, 43, 36.8, 25, 0),
    (10271, 33, 2, 24, 0),
    (10272, 20, 64.8, 6, 0),
    (10272, 31, 10, 40, 0),
    (10272, 72, 27.8, 24, 0),
    (10273, 10, 24.8, 24, 0.05),
    (10273, 31, 10, 15, 0.05),
    (10273, 33, 2, 20, 0),
    (10273, 40, 14.7, 60, 0.05),
    (10273, 76, 14.4, 33, 0.05),
    (10274, 71, 17.2, 20, 0),
    (10274, 72, 27.8, 7, 0),
    (10275, 24, 3.6, 12, 0.05),
    (10275, 59, 44, 6, 0.05),
    (10276, 10, 24.8, 15, 0),
    (10276, 13, 4.8, 10, 0),
    (10277, 28, 36.4, 20, 0),
    (10277, 62, 39.4, 12, 0),
    (10278, 44, 15.5, 16, 0),
    (10278, 59, 44, 15, 0),
    (10278, 63, 35.1, 8, 0),
    (10278, 73, 12, 25, 0),
    (10279, 17, 31.2, 15, 0.25),
    (10280, 24, 3.6, 12, 0),
    (10280, 55, 19.2, 20, 0),
    (10280, 75, 6.2, 30, 0),
    (10281, 19, 7.3, 1, 0),
    (10281, 24, 3.6, 6, 0),
    (10281, 35, 14.4, 4, 0),
    (10282, 30, 20.7, 6, 0),
    (10282, 57, 15.6, 2, 0),
    (10283, 15, 12.4, 20, 0),
    (10283, 19, 7.3, 18, 0),
    (10283, 60, 27.2, 35, 0),
    (10283, 72, 27.8, 3, 0),
    (10284, 27, 35.1, 15, 0.25),
    (10284, 44, 15.5, 21, 0),
    (10284, 60, 27.2, 20, 0.25),
    (10284, 67, 11.2, 5, 0.25),
    (10285, 1, 14.4, 45, 0.2),
    (10285, 40, 14.7, 40, 0.2),
    (10285, 53, 26.2, 36, 0.2),
    (10286, 35, 14.4, 100, 0),
    (10286, 62, 39.4, 40, 0),
    (10287, 16, 13.9, 40, 0.15),
    (10287, 34, 11.2, 20, 0),
    (10287, 46, 9.6, 15, 0.15),
    (10288, 54, 5.9, 10, 0.1),
    (10288, 68, 10, 3, 0.1),
    (10289, 3, 8, 30, 0),
    (10289, 64, 26.6, 9, 0),
    (10290, 5, 17, 20, 0),
    (10290, 29, 99, 15, 0),
    (10290, 49, 16, 15, 0),
    (10290, 77, 10.4, 10, 0),
    (10291, 13, 4.8, 20, 0.1),
    (10291, 44, 15.5, 24, 0.1),
    (10291, 51, 42.4, 2, 0.1),
    (10292, 20, 64.8, 20, 0),
    (10293, 18, 50, 12, 0),
    (10293, 24, 3.6, 10, 0),
    (10293, 63, 35.1, 5, 0),
    (10293, 75, 6.2, 6, 0),
    (10294, 1, 14.4, 18, 0),
    (10294, 17, 31.2, 15, 0),
    (10294, 43, 36.8, 15, 0),
    (10294, 60, 27.2, 21, 0),
    (10294, 75, 6.2, 6, 0),
    (10295, 56, 30.4, 4, 0),
    (10296, 11, 16.8, 12, 0),
    (10296, 16, 13.9, 30, 0),
    (10296, 69, 28.8, 15, 0),
    (10297, 39, 14.4, 60, 0),
    (10297, 72, 27.8, 20, 0),
    (10298, 2, 15.2, 40, 0),
    (10298, 36, 15.2, 40, 0.25),
    (10298, 59, 44, 30, 0.25),
    (10298, 62, 39.4, 15, 0),
    (10299, 19, 7.3, 15, 0),
    (10299, 70, 12, 20, 0),
    (10300, 66, 13.6, 30, 0),
    (10300, 68, 10, 20, 0),
    (10301, 40, 14.7, 10, 0),
    (10301, 56, 30.4, 20, 0),
    (10302, 17, 31.2, 40, 0),
    (10302, 28, 36.4, 28, 0),
    (10302, 43, 36.8, 12, 0),
    (10303, 40, 14.7, 40, 0.1),
    (10303, 65, 16.8, 30, 0.1),
    (10303, 68, 10, 15, 0.1),
    (10304, 49, 16, 30, 0),
    (10304, 59, 44, 10, 0),
    (10304, 71, 17.2, 2, 0),
    (10305, 18, 50, 25, 0.1),
    (10305, 29, 99, 25, 0.1),
    (10305, 39, 14.4, 30, 0.1),
    (10306, 30, 20.7, 10, 0),
    (10306, 53, 26.2, 10, 0),
    (10306, 54, 5.9, 5, 0),
    (10307, 62, 39.4, 10, 0),
    (10307, 68, 10, 3, 0),
    (10308, 69, 28.8, 1, 0),
    (10308, 70, 12, 5, 0),
    (10309, 4, 17.6, 20, 0),
    (10309, 6, 20, 30, 0),
    (10309, 42, 11.2, 2, 0),
    (10309, 43, 36.8, 20, 0),
    (10309, 71, 17.2, 3, 0),
    (10310, 16, 13.9, 10, 0),
    (10310, 62, 39.4, 5, 0),
    (10311, 42, 11.2, 6, 0),
    (10311, 69, 28.8, 7, 0),
    (10312, 28, 36.4, 4, 0),
    (10312, 43, 36.8, 24, 0),
    (10312, 53, 26.2, 20, 0),
    (10312, 75, 6.2, 10, 0),
    (10313, 36, 15.2, 12, 0),
    (10314, 32, 25.6, 40, 0.1),
    (10314, 58, 10.6, 30, 0.1),
    (10314, 62, 39.4, 25, 0.1),
    (10315, 34, 11.2, 14, 0),
    (10315, 70, 12, 30, 0),
    (10316, 41, 7.7, 10, 0),
    (10316, 62, 39.4, 70, 0),
    (10317, 1, 14.4, 20, 0),
    (10318, 41, 7.7, 20, 0),
    (10318, 76, 14.4, 6, 0),
    (10319, 17, 31.2, 8, 0),
    (10319, 28, 36.4, 14, 0),
    (10319, 76, 14.4, 30, 0),
    (10320, 71, 17.2, 30, 0),
    (10321, 35, 14.4, 10, 0),
    (10322, 52, 5.6, 20, 0),
    (10323, 15, 12.4, 5, 0),
    (10323, 25, 11.2, 4, 0),
    (10323, 39, 14.4, 4, 0),
    (10324, 16, 13.9, 21, 0.15),
    (10324, 35, 14.4, 70, 0.15),
    (10324, 46, 9.6, 30, 0),
    (10324, 59, 44, 40, 0.15),
    (10324, 63, 35.1, 80, 0.15),
    (10325, 6, 20, 6, 0),
    (10325, 13, 4.8, 12, 0),
    (10325, 14, 18.6, 9, 0),
    (10325, 31, 10, 4, 0),
    (10325, 72, 27.8, 40, 0),
    (10326, 4, 17.6, 24, 0),
    (10326, 57, 15.6, 16, 0),
    (10326, 75, 6.2, 50, 0),
    (10327, 2, 15.2, 25, 0.2),
    (10327, 11, 16.8, 50, 0.2),
    (10327, 30, 20.7, 35, 0.2),
    (10327, 58, 10.6, 30, 0.2),
    (10328, 59, 44, 9, 0),
    (10328, 65, 16.8, 40, 0),
    (10328, 68, 10, 10, 0),
    (10329, 19, 7.3, 10, 0.05),
    (10329, 30, 20.7, 8, 0.05),
    (10329, 38, 210.8, 20, 0.05),
    (10329, 56, 30.4, 12, 0.05),
    (10330, 26, 24.9, 50, 0.15),
    (10330, 72, 27.8, 25, 0.15),
    (10331, 54, 5.9, 15, 0),
    (10332, 18, 50, 40, 0.2),
    (10332, 42, 11.2, 10, 0.2),
    (10332, 47, 7.6, 16, 0.2),
    (10333, 14, 18.6, 10, 0),
    (10333, 21, 8, 10, 0.1),
    (10333, 71, 17.2, 40, 0.1),
    (10334, 52, 5.6, 8, 0),
    (10334, 68, 10, 10, 0),
    (10335, 2, 15.2, 7, 0.2),
    (10335, 31, 10, 25, 0.2),
    (10335, 32, 25.6, 6, 0.2),
    (10335, 51, 42.4, 48, 0.2),
    (10336, 4, 17.6, 18, 0.1),
    (10337, 23, 7.2, 40, 0),
    (10337, 26, 24.9, 24, 0),
    (10337, 36, 15.2, 20, 0),
    (10337, 37, 20.8, 28, 0),
    (10337, 72, 27.8, 25, 0),
    (10338, 17, 31.2, 20, 0),
    (10338, 30, 20.7, 15, 0),
    (10339, 4, 17.6, 10, 0),
    (10339, 17, 31.2, 70, 0.05),
    (10339, 62, 39.4, 28, 0),
    (10340, 18, 50, 20, 0.05),
    (10340, 41, 7.7, 12, 0.05),
    (10340, 43, 36.8, 40, 0.05),
    (10341, 33, 2, 8, 0),
    (10341, 59, 44, 9, 0.15),
    (10342, 2, 15.2, 24, 0.2),
    (10342, 31, 10, 56, 0.2),
    (10342, 36, 15.2, 40, 0.2),
    (10342, 55, 19.2, 40, 0.2),
    (10343, 64, 26.6, 50, 0),
    (10343, 68, 10, 4, 0.05),
    (10343, 76, 14.4, 15, 0),
    (10344, 4, 17.6, 35, 0),
    (10344, 8, 32, 70, 0.25),
    (10345, 8, 32, 70, 0),
    (10345, 19, 7.3, 80, 0),
    (10345, 42, 11.2, 9, 0),
    (10346, 17, 31.2, 36, 0.1),
    (10346, 56, 30.4, 20, 0),
    (10347, 25, 11.2, 10, 0),
    (10347, 39, 14.4, 50, 0.15),
    (10347, 40, 14.7, 4, 0),
    (10347, 75, 6.2, 6, 0.15),
    (10348, 1, 14.4, 15, 0.15),
    (10348, 23, 7.2, 25, 0),
    (10349, 54, 5.9, 24, 0),
    (10350, 50, 13, 15, 0.1),
    (10350, 69, 28.8, 18, 0.1),
    (10351, 38, 210.8, 20, 0.05),
    (10351, 41, 7.7, 13, 0),
    (10351, 44, 15.5, 77, 0.05),
    (10351, 65, 16.8, 10, 0.05),
    (10352, 24, 3.6, 10, 0),
    (10352, 54, 5.9, 20, 0.15),
    (10353, 11, 16.8, 12, 0.2),
    (10353, 38, 210.8, 50, 0.2),
    (10354, 1, 14.4, 12, 0),
    (10354, 29, 99, 4, 0),
    (10355, 24, 3.6, 25, 0),
    (10355, 57, 15.6, 25, 0),
    (10356, 31, 10, 30, 0),
    (10356, 55, 19.2, 12, 0),
    (10356, 69, 28.8, 20, 0),
    (10357, 10, 24.8, 30, 0.2),
    (10357, 26, 24.9, 16, 0),
    (10357, 60, 27.2, 8, 0.2),
    (10358, 24, 3.6, 10, 0.05),
    (10358, 34, 11.2, 10, 0.05),
    (10358, 36, 15.2, 20, 0.05),
    (10359, 16, 13.9, 56, 0.05),
    (10359, 31, 10, 70, 0.05),
    (10359, 60, 27.2, 80, 0.05),
    (10360, 28, 36.4, 30, 0),
    (10360, 29, 99, 35, 0),
    (10360, 38, 210.8, 10, 0),
    (10360, 49, 16, 35, 0),
    (10360, 54, 5.9, 28, 0),
    (10361, 39, 14.4, 54, 0.1),
    (10361, 60, 27.2, 55, 0.1),
    (10362, 25, 11.2, 50, 0),
    (10362, 51, 42.4, 20, 0),
    (10362, 54, 5.9, 24, 0),
    (10363, 31, 10, 20, 0),
    (10363, 75, 6.2, 12, 0),
    (10363, 76, 14.4, 12, 0),
    (10364, 69, 28.8, 30, 0),
    (10364, 71, 17.2, 5, 0),
    (10365, 11, 16.8, 24, 0),
    (10366, 65, 16.8, 5, 0),
    (10366, 77, 10.4, 5, 0),
    (10367, 34, 11.2, 36, 0),
    (10367, 54, 5.9, 18, 0),
    (10367, 65, 16.8, 15, 0),
    (10367, 77, 10.4, 7, 0),
    (10368, 21, 8, 5, 0.1),
    (10368, 28, 36.4, 13, 0.1),
    (10368, 57, 15.6, 25, 0),
    (10368, 64, 26.6, 35, 0.1),
    (10369, 29, 99, 20, 0),
    (10369, 56, 30.4, 18, 0.25),
    (10370, 1, 14.4, 15, 0.15),
    (10370, 64, 26.6, 30, 0),
    (10370, 74, 8, 20, 0.15),
    (10371, 36, 15.2, 6, 0.2),
    (10372, 20, 64.8, 12, 0.25),
    (10372, 38, 210.8, 40, 0.25),
    (10372, 60, 27.2, 70, 0.25),
    (10372, 72, 27.8, 42, 0.25),
    (10373, 58, 10.6, 80, 0.2),
    (10373, 71, 17.2, 50, 0.2),
    (10374, 31, 10, 30, 0),
    (10374, 58, 10.6, 15, 0),
    (10375, 14, 18.6, 15, 0),
    (10375, 54, 5.9, 10, 0),
    (10376, 31, 10, 42, 0.05),
    (10377, 28, 36.4, 20, 0.15),
    (10377, 39, 14.4, 20, 0.15),
    (10378, 71, 17.2, 6, 0),
    (10379, 41, 7.7, 8, 0.1),
    (10379, 63, 35.1, 16, 0.1),
    (10379, 65, 16.8, 20, 0.1),
    (10380, 30, 20.7, 18, 0.1),
    (10380, 53, 26.2, 20, 0.1),
    (10380, 60, 27.2, 6, 0.1),
    (10380, 70, 12, 30, 0),
    (10381, 74, 8, 14, 0),
    (10382, 5, 17, 32, 0),
    (10382, 18, 50, 9, 0),
    (10382, 29, 99, 14, 0),
    (10382, 33, 2, 60, 0),
    (10382, 74, 8, 50, 0),
    (10383, 13, 4.8, 20, 0),
    (10383, 50, 13, 15, 0),
    (10383, 56, 30.4, 20, 0),
    (10384, 20, 64.8, 28, 0),
    (10384, 60, 27.2, 15, 0),
    (10385, 7, 24, 10, 0.2),
    (10385, 60, 27.2, 20, 0.2),
    (10385, 68, 10, 8, 0.2),
    (10386, 24, 3.6, 15, 0),
    (10386, 34, 11.2, 10, 0),
    (10387, 24, 3.6, 15, 0),
    (10387, 28, 36.4, 6, 0),
    (10387, 59, 44, 12, 0),
    (10387, 71, 17.2, 15, 0),
    (10388, 45, 7.6, 15, 0.2),
    (10388, 52, 5.6, 20, 0.2),
    (10388, 53, 26.2, 40, 0),
    (10389, 10, 24.8, 16, 0),
    (10389, 55, 19.2, 15, 0),
    (10389, 62, 39.4, 20, 0),
    (10389, 70, 12, 30, 0),
    (10390, 31, 10, 60, 0.1),
    (10390, 35, 14.4, 40, 0.1),
    (10390, 46, 9.6, 45, 0),
    (10390, 72, 27.8, 24, 0.1),
    (10391, 13, 4.8, 18, 0),
    (10392, 69, 28.8, 50, 0),
    (10393, 2, 15.2, 25, 0.25),
    (10393, 14, 18.6, 42, 0.25),
    (10393, 25, 11.2, 7, 0.25),
    (10393, 26, 24.9, 70, 0.25),
    (10393, 31, 10, 32, 0),
    (10394, 13, 4.8, 10, 0),
    (10394, 62, 39.4, 10, 0),
    (10395, 46, 9.6, 28, 0.1),
    (10395, 53, 26.2, 70, 0.1),
    (10395, 69, 28.8, 8, 0),
    (10396, 23, 7.2, 40, 0),
    (10396, 71, 17.2, 60, 0),
    (10396, 72, 27.8, 21, 0),
    (10397, 21, 8, 10, 0.15),
    (10397, 51, 42.4, 18, 0.15),
    (10398, 35, 14.4, 30, 0),
    (10398, 55, 19.2, 120, 0.1),
    (10399, 68, 10, 60, 0),
    (10399, 71, 17.2, 30, 0),
    (10399, 76, 14.4, 35, 0),
    (10399, 77, 10.4, 14, 0),
    (10400, 29, 99, 21, 0),
    (10400, 35, 14.4, 35, 0),
    (10400, 49, 16, 30, 0),
    (10401, 30, 20.7, 18, 0),
    (10401, 56, 30.4, 70, 0),
    (10401, 65, 16.8, 20, 0),
    (10401, 71, 17.2, 60, 0),
    (10402, 23, 7.2, 60, 0),
    (10402, 63, 35.1, 65, 0),
    (10403, 16, 13.9, 21, 0.15),
    (10403, 48, 10.2, 70, 0.15),
    (10404, 26, 24.9, 30, 0.05),
    (10404, 42, 11.2, 40, 0.05),
    (10404, 49, 16, 30, 0.05),
    (10405, 3, 8, 50, 0),
    (10406, 1, 14.4, 10, 0),
    (10406, 21, 8, 30, 0.1),
    (10406, 28, 36.4, 42, 0.1),
    (10406, 36, 15.2, 5, 0.1),
    (10406, 40, 14.7, 2, 0.1),
    (10407, 11, 16.8, 30, 0),
    (10407, 69, 28.8, 15, 0),
    (10407, 71, 17.2, 15, 0),
    (10408, 37, 20.8, 10, 0),
    (10408, 54, 5.9, 6, 0),
    (10408, 62, 39.4, 35, 0),
    (10409, 14, 18.6, 12, 0),
    (10409, 21, 8, 12, 0),
    (10410, 33, 2, 49, 0),
    (10410, 59, 44, 16, 0),
    (10411, 41, 7.7, 25, 0.2),
    (10411, 44, 15.5, 40, 0.2),
    (10411, 59, 44, 9, 0.2),
    (10412, 14, 18.6, 20, 0.1),
    (10413, 1, 14.4, 24, 0),
    (10413, 62, 39.4, 40, 0),
    (10413, 76, 14.4, 14, 0),
    (10414, 19, 7.3, 18, 0.05),
    (10414, 33, 2, 50, 0),
    (10415, 17, 31.2, 2, 0),
    (10415, 33, 2, 20, 0),
    (10416, 19, 7.3, 20, 0),
    (10416, 53, 26.2, 10, 0),
    (10416, 57, 15.6, 20, 0),
    (10417, 38, 210.8, 50, 0),
    (10417, 46, 9.6, 2, 0.25),
    (10417, 68, 10, 36, 0.25),
    (10417, 77, 10.4, 35, 0),
    (10418, 2, 15.2, 60, 0),
    (10418, 47, 7.6, 55, 0),
    (10418, 61, 22.8, 16, 0),
    (10418, 74, 8, 15, 0),
    (10419, 60, 27.2, 60, 0.05),
    (10419, 69, 28.8, 20, 0.05),
    (10420, 9, 77.6, 20, 0.1),
    (10420, 13, 4.8, 2, 0.1),
    (10420, 70, 12, 8, 0.1),
    (10420, 73, 12, 20, 0.1),
    (10421, 19, 7.3, 4, 0.15),
    (10421, 26, 24.9, 30, 0),
    (10421, 53, 26.2, 15, 0.15),
    (10421, 77, 10.4, 10, 0.15),
    (10422, 26, 24.9, 2, 0),
    (10423, 31, 10, 14, 0),
    (10423, 59, 44, 20, 0),
    (10424, 35, 14.4, 60, 0.2),
    (10424, 38, 210.8, 49, 0.2),
    (10424, 68, 10, 30, 0.2),
    (10425, 55, 19.2, 10, 0.25),
    (10425, 76, 14.4, 20, 0.25),
    (10426, 56, 30.4, 5, 0),
    (10426, 64, 26.6, 7, 0),
    (10427, 14, 18.6, 35, 0),
    (10428, 46, 9.6, 20, 0),
    (10429, 50, 13, 40, 0),
    (10429, 63, 35.1, 35, 0.25),
    (10430, 17, 31.2, 45, 0.2),
    (10430, 21, 8, 50, 0),
    (10430, 56, 30.4, 30, 0),
    (10430, 59, 44, 70, 0.2),
    (10431, 17, 31.2, 50, 0.25),
    (10431, 40, 14.7, 50, 0.25),
    (10431, 47, 7.6, 30, 0.25),
    (10432, 26, 24.9, 10, 0),
    (10432, 54, 5.9, 40, 0),
    (10433, 56, 30.4, 28, 0),
    (10434, 11, 16.8, 6, 0),
    (10434, 76, 14.4, 18, 0.15),
    (10435, 2, 15.2, 10, 0),
    (10435, 22, 16.8, 12, 0),
    (10435, 72, 27.8, 10, 0),
    (10436, 46, 9.6, 5, 0),
    (10436, 56, 30.4, 40, 0.1),
    (10436, 64, 26.6, 30, 0.1),
    (10436, 75, 6.2, 24, 0.1),
    (10437, 53, 26.2, 15, 0),
    (10438, 19, 7.3, 15, 0.2),
    (10438, 34, 11.2, 20, 0.2),
    (10438, 57, 15.6, 15, 0.2),
    (10439, 12, 30.4, 15, 0),
    (10439, 16, 13.9, 16, 0),
    (10439, 64, 26.6, 6, 0),
    (10439, 74, 8, 30, 0),
    (10440, 2, 15.2, 45, 0.15),
    (10440, 16, 13.9, 49, 0.15),
    (10440, 29, 99, 24, 0.15),
    (10440, 61, 22.8, 90, 0.15),
    (10441, 27, 35.1, 50, 0),
    (10442, 11, 16.8, 30, 0),
    (10442, 54, 5.9, 80, 0),
    (10442, 66, 13.6, 60, 0),
    (10443, 11, 16.8, 6, 0.2),
    (10443, 28, 36.4, 12, 0),
    (10444, 17, 31.2, 10, 0),
    (10444, 26, 24.9, 15, 0),
    (10444, 35, 14.4, 8, 0),
    (10444, 41, 7.7, 30, 0),
    (10445, 39, 14.4, 6, 0),
    (10445, 54, 5.9, 15, 0),
    (10446, 19, 7.3, 12, 0.1),
    (10446, 24, 3.6, 20, 0.1),
    (10446, 31, 10, 3, 0.1),
    (10446, 52, 5.6, 15, 0.1),
    (10447, 19, 7.3, 40, 0),
    (10447, 65, 16.8, 35, 0),
    (10447, 71, 17.2, 2, 0),
    (10448, 26, 24.9, 6, 0),
    (10448, 40, 14.7, 20, 0),
    (10449, 10, 24.8, 14, 0),
    (10449, 52, 5.6, 20, 0),
    (10449, 62, 39.4, 35, 0),
    (10450, 10, 24.8, 20, 0.2),
    (10450, 54, 5.9, 6, 0.2),
    (10451, 55, 19.2, 120, 0.1),
    (10451, 64, 26.6, 35, 0.1),
    (10451, 65, 16.8, 28, 0.1),
    (10451, 77, 10.4, 55, 0.1),
    (10452, 28, 36.4, 15, 0),
    (10452, 44, 15.5, 100, 0.05),
    (10453, 48, 10.2, 15, 0.1),
    (10453, 70, 12, 25, 0.1),
    (10454, 16, 13.9, 20, 0.2),
    (10454, 33, 2, 20, 0.2),
    (10454, 46, 9.6, 10, 0.2),
    (10455, 39, 14.4, 20, 0),
    (10455, 53, 26.2, 50, 0),
    (10455, 61, 22.8, 25, 0),
    (10455, 71, 17.2, 30, 0),
    (10456, 21, 8, 40, 0.15),
    (10456, 49, 16, 21, 0.15),
    (10457, 59, 44, 36, 0),
    (10458, 26, 24.9, 30, 0),
    (10458, 28, 36.4, 30, 0),
    (10458, 43, 36.8, 20, 0),
    (10458, 56, 30.4, 15, 0),
    (10458, 71, 17.2, 50, 0),
    (10459, 7, 24, 16, 0.05),
    (10459, 46, 9.6, 20, 0.05),
    (10459, 72, 27.8, 40, 0),
    (10460, 68, 10, 21, 0.25),
    (10460, 75, 6.2, 4, 0.25),
    (10461, 21, 8, 40, 0.25),
    (10461, 30, 20.7, 28, 0.25),
    (10461, 55, 19.2, 60, 0.25),
    (10462, 13, 4.8, 1, 0),
    (10462, 23, 7.2, 21, 0),
    (10463, 19, 7.3, 21, 0),
    (10463, 42, 11.2, 50, 0),
    (10464, 4, 17.6, 16, 0.2),
    (10464, 43, 36.8, 3, 0),
    (10464, 56, 30.4, 30, 0.2),
    (10464, 60, 27.2, 20, 0),
    (10465, 24, 3.6, 25, 0),
    (10465, 29, 99, 18, 0.1),
    (10465, 40, 14.7, 20, 0),
    (10465, 45, 7.6, 30, 0.1),
    (10465, 50, 13, 25, 0),
    (10466, 11, 16.8, 10, 0),
    (10466, 46, 9.6, 5, 0),
    (10467, 24, 3.6, 28, 0),
    (10467, 25, 11.2, 12, 0),
    (10468, 30, 20.7, 8, 0),
    (10468, 43, 36.8, 15, 0),
    (10469, 2, 15.2, 40, 0.15),
    (10469, 16, 13.9, 35, 0.15),
    (10469, 44, 15.5, 2, 0.15),
    (10470, 18, 50, 30, 0),
    (10470, 23, 7.2, 15, 0),
    (10470, 64, 26.6, 8, 0),
    (10471, 7, 24, 30, 0),
    (10471, 56, 30.4, 20, 0),
    (10472, 24, 3.6, 80, 0.05),
    (10472, 51, 42.4, 18, 0),
    (10473, 33, 2, 12, 0),
    (10473, 71, 17.2, 12, 0),
    (10474, 14, 18.6, 12, 0),
    (10474, 28, 36.4, 18, 0),
    (10474, 40, 14.7, 21, 0),
    (10474, 75, 6.2, 10, 0),
    (10475, 31, 10, 35, 0.15),
    (10475, 66, 13.6, 60, 0.15),
    (10475, 76, 14.4, 42, 0.15),
    (10476, 55, 19.2, 2, 0.05),
    (10476, 70, 12, 12, 0),
    (10477, 1, 14.4, 15, 0),
    (10477, 21, 8, 21, 0.25),
    (10477, 39, 14.4, 20, 0.25),
    (10478, 10, 24.8, 20, 0.05),
    (10479, 38, 210.8, 30, 0),
    (10479, 53, 26.2, 28, 0),
    (10479, 59, 44, 60, 0),
    (10479, 64, 26.6, 30, 0),
    (10480, 47, 7.6, 30, 0),
    (10480, 59, 44, 12, 0),
    (10481, 49, 16, 24, 0),
    (10481, 60, 27.2, 40, 0),
    (10482, 40, 14.7, 10, 0),
    (10483, 34, 11.2, 35, 0.05),
    (10483, 77, 10.4, 30, 0.05),
    (10484, 21, 8, 14, 0),
    (10484, 40, 14.7, 10, 0),
    (10484, 51, 42.4, 3, 0),
    (10485, 2, 15.2, 20, 0.1),
    (10485, 3, 8, 20, 0.1),
    (10485, 55, 19.2, 30, 0.1),
    (10485, 70, 12, 60, 0.1),
    (10486, 11, 16.8, 5, 0),
    (10486, 51, 42.4, 25, 0),
    (10486, 74, 8, 16, 0),
    (10487, 19, 7.3, 5, 0),
    (10487, 26, 24.9, 30, 0),
    (10487, 54, 5.9, 24, 0.25),
    (10488, 59, 44, 30, 0),
    (10488, 73, 12, 20, 0.2),
    (10489, 11, 16.8, 15, 0.25),
    (10489, 16, 13.9, 18, 0),
    (10490, 59, 44, 60, 0),
    (10490, 68, 10, 30, 0),
    (10490, 75, 6.2, 36, 0),
    (10491, 44, 15.5, 15, 0.15),
    (10491, 77, 10.4, 7, 0.15),
    (10492, 25, 11.2, 60, 0.05),
    (10492, 42, 11.2, 20, 0.05),
    (10493, 65, 16.8, 15, 0.1),
    (10493, 66, 13.6, 10, 0.1),
    (10493, 69, 28.8, 10, 0.1),
    (10494, 56, 30.4, 30, 0),
    (10495, 23, 7.2, 10, 0),
    (10495, 41, 7.7, 20, 0),
    (10495, 77, 10.4, 5, 0),
    (10496, 31, 10, 20, 0.05),
    (10497, 56, 30.4, 14, 0),
    (10497, 72, 27.8, 25, 0),
    (10497, 77, 10.4, 25, 0),
    (10498, 24, 4.5, 14, 0),
    (10498, 40, 18.4, 5, 0),
    (10498, 42, 14, 30, 0),
    (10499, 28, 45.6, 20, 0),
    (10499, 49, 20, 25, 0),
    (10500, 15, 15.5, 12, 0.05),
    (10500, 28, 45.6, 8, 0.05),
    (10501, 54, 7.45, 20, 0),
    (10502, 45, 9.5, 21, 0),
    (10502, 53, 32.8, 6, 0),
    (10502, 67, 14, 30, 0),
    (10503, 14, 23.25, 70, 0),
    (10503, 65, 21.05, 20, 0),
    (10504, 2, 19, 12, 0),
    (10504, 21, 10, 12, 0),
    (10504, 53, 32.8, 10, 0),
    (10504, 61, 28.5, 25, 0),
    (10505, 62, 49.3, 3, 0),
    (10506, 25, 14, 18, 0.1),
    (10506, 70, 15, 14, 0.1),
    (10507, 43, 46, 15, 0.15),
    (10507, 48, 12.75, 15, 0.15),
    (10508, 13, 6, 10, 0),
    (10508, 39, 18, 10, 0),
    (10509, 28, 45.6, 3, 0),
    (10510, 29, 123.79, 36, 0),
    (10510, 75, 7.75, 36, 0.1),
    (10511, 4, 22, 50, 0.15),
    (10511, 7, 30, 50, 0.15),
    (10511, 8, 40, 10, 0.15),
    (10512, 24, 4.5, 10, 0.15),
    (10512, 46, 12, 9, 0.15),
    (10512, 47, 9.5, 6, 0.15),
    (10512, 60, 34, 12, 0.15),
    (10513, 21, 10, 40, 0.2),
    (10513, 32, 32, 50, 0.2),
    (10513, 61, 28.5, 15, 0.2),
    (10514, 20, 81, 39, 0),
    (10514, 28, 45.6, 35, 0),
    (10514, 56, 38, 70, 0),
    (10514, 65, 21.05, 39, 0),
    (10514, 75, 7.75, 50, 0),
    (10515, 9, 97, 16, 0.15),
    (10515, 16, 17.45, 50, 0),
    (10515, 27, 43.9, 120, 0),
    (10515, 33, 2.5, 16, 0.15),
    (10515, 60, 34, 84, 0.15),
    (10516, 18, 62.5, 25, 0.1),
    (10516, 41, 9.65, 80, 0.1),
    (10516, 42, 14, 20, 0),
    (10517, 52, 7, 6, 0),
    (10517, 59, 55, 4, 0),
    (10517, 70, 15, 6, 0),
    (10518, 24, 4.5, 5, 0),
    (10518, 38, 263.5, 15, 0),
    (10518, 44, 19.45, 9, 0),
    (10519, 10, 31, 16, 0.05),
    (10519, 56, 38, 40, 0),
    (10519, 60, 34, 10, 0.05),
    (10520, 24, 4.5, 8, 0),
    (10520, 53, 32.8, 5, 0),
    (10521, 35, 18, 3, 0),
    (10521, 41, 9.65, 10, 0),
    (10521, 68, 12.5, 6, 0),
    (10522, 1, 18, 40, 0.2),
    (10522, 8, 40, 24, 0),
    (10522, 30, 25.89, 20, 0.2),
    (10522, 40, 18.4, 25, 0.2),
    (10523, 17, 39, 25, 0.1),
    (10523, 20, 81, 15, 0.1),
    (10523, 37, 26, 18, 0.1),
    (10523, 41, 9.65, 6, 0.1),
    (10524, 10, 31, 2, 0),
    (10524, 30, 25.89, 10, 0),
    (10524, 43, 46, 60, 0),
    (10524, 54, 7.45, 15, 0),
    (10525, 36, 19, 30, 0),
    (10525, 40, 18.4, 15, 0.1),
    (10526, 1, 18, 8, 0.15),
    (10526, 13, 6, 10, 0),
    (10526, 56, 38, 30, 0.15),
    (10527, 4, 22, 50, 0.1),
    (10527, 36, 19, 30, 0.1),
    (10528, 11, 21, 3, 0),
    (10528, 33, 2.5, 8, 0.2),
    (10528, 72, 34.8, 9, 0),
    (10529, 55, 24, 14, 0),
    (10529, 68, 12.5, 20, 0),
    (10529, 69, 36, 10, 0),
    (10530, 17, 39, 40, 0),
    (10530, 43, 46, 25, 0),
    (10530, 61, 28.5, 20, 0),
    (10530, 76, 18, 50, 0),
    (10531, 59, 55, 2, 0),
    (10532, 30, 25.89, 15, 0),
    (10532, 66, 17, 24, 0),
    (10533, 4, 22, 50, 0.05),
    (10533, 72, 34.8, 24, 0),
    (10533, 73, 15, 24, 0.05),
    (10534, 30, 25.89, 10, 0),
    (10534, 40, 18.4, 10, 0.2),
    (10534, 54, 7.45, 10, 0.2),
    (10535, 11, 21, 50, 0.1),
    (10535, 40, 18.4, 10, 0.1),
    (10535, 57, 19.5, 5, 0.1),
    (10535, 59, 55, 15, 0.1),
    (10536, 12, 38, 15, 0.25),
    (10536, 31, 12.5, 20, 0),
    (10536, 33, 2.5, 30, 0),
    (10536, 60, 34, 35, 0.25),
    (10537, 31, 12.5, 30, 0),
    (10537, 51, 53, 6, 0),
    (10537, 58, 13.25, 20, 0),
    (10537, 72, 34.8, 21, 0),
    (10537, 73, 15, 9, 0),
    (10538, 70, 15, 7, 0),
    (10538, 72, 34.8, 1, 0),
    (10539, 13, 6, 8, 0),
    (10539, 21, 10, 15, 0),
    (10539, 33, 2.5, 15, 0),
    (10539, 49, 20, 6, 0),
    (10540, 3, 10, 60, 0),
    (10540, 26, 31.23, 40, 0),
    (10540, 38, 263.5, 30, 0),
    (10540, 68, 12.5, 35, 0),
    (10541, 24, 4.5, 35, 0.1),
    (10541, 38, 263.5, 4, 0.1),
    (10541, 65, 21.05, 36, 0.1),
    (10541, 71, 21.5, 9, 0.1),
    (10542, 11, 21, 15, 0.05),
    (10542, 54, 7.45, 24, 0.05),
    (10543, 12, 38, 30, 0.15),
    (10543, 23, 9, 70, 0.15),
    (10544, 28, 45.6, 7, 0),
    (10544, 67, 14, 7, 0),
    (10545, 11, 21, 10, 0),
    (10546, 7, 30, 10, 0),
    (10546, 35, 18, 30, 0),
    (10546, 62, 49.3, 40, 0),
    (10547, 32, 32, 24, 0.15),
    (10547, 36, 19, 60, 0),
    (10548, 34, 14, 10, 0.25),
    (10548, 41, 9.65, 14, 0),
    (10549, 31, 12.5, 55, 0.15),
    (10549, 45, 9.5, 100, 0.15),
    (10549, 51, 53, 48, 0.15),
    (10550, 17, 39, 8, 0.1),
    (10550, 19, 9.2, 10, 0),
    (10550, 21, 10, 6, 0.1),
    (10550, 61, 28.5, 10, 0.1),
    (10551, 16, 17.45, 40, 0.15),
    (10551, 35, 18, 20, 0.15),
    (10551, 44, 19.45, 40, 0),
    (10552, 69, 36, 18, 0),
    (10552, 75, 7.75, 30, 0),
    (10553, 11, 21, 15, 0),
    (10553, 16, 17.45, 14, 0),
    (10553, 22, 21, 24, 0),
    (10553, 31, 12.5, 30, 0),
    (10553, 35, 18, 6, 0),
    (10554, 16, 17.45, 30, 0.05),
    (10554, 23, 9, 20, 0.05),
    (10554, 62, 49.3, 20, 0.05),
    (10554, 77, 13, 10, 0.05),
    (10555, 14, 23.25, 30, 0.2),
    (10555, 19, 9.2, 35, 0.2),
    (10555, 24, 4.5, 18, 0.2),
    (10555, 51, 53, 20, 0.2),
    (10555, 56, 38, 40, 0.2),
    (10556, 72, 34.8, 24, 0),
    (10557, 64, 33.25, 30, 0),
    (10557, 75, 7.75, 20, 0),
    (10558, 47, 9.5, 25, 0),
    (10558, 51, 53, 20, 0),
    (10558, 52, 7, 30, 0),
    (10558, 53, 32.8, 18, 0),
    (10558, 73, 15, 3, 0),
    (10559, 41, 9.65, 12, 0.05),
    (10559, 55, 24, 18, 0.05),
    (10560, 30, 25.89, 20, 0),
    (10560, 62, 49.3, 15, 0.25),
    (10561, 44, 19.45, 10, 0),
    (10561, 51, 53, 50, 0),
    (10562, 33, 2.5, 20, 0.1),
    (10562, 62, 49.3, 10, 0.1),
    (10563, 36, 19, 25, 0),
    (10563, 52, 7, 70, 0),
    (10564, 17, 39, 16, 0.05),
    (10564, 31, 12.5, 6, 0.05),
    (10564, 55, 24, 25, 0.05),
    (10565, 24, 4.5, 25, 0.1),
    (10565, 64, 33.25, 18, 0.1),
    (10566, 11, 21, 35, 0.15),
    (10566, 18, 62.5, 18, 0.15),
    (10566, 76, 18, 10, 0),
    (10567, 31, 12.5, 60, 0.2),
    (10567, 51, 53, 3, 0),
    (10567, 59, 55, 40, 0.2),
    (10568, 10, 31, 5, 0),
    (10569, 31, 12.5, 35, 0.2),
    (10569, 76, 18, 30, 0),
    (10570, 11, 21, 15, 0.05),
    (10570, 56, 38, 60, 0.05),
    (10571, 14, 23.25, 11, 0.15),
    (10571, 42, 14, 28, 0.15),
    (10572, 16, 17.45, 12, 0.1),
    (10572, 32, 32, 10, 0.1),
    (10572, 40, 18.4, 50, 0),
    (10572, 75, 7.75, 15, 0.1),
    (10573, 17, 39, 18, 0),
    (10573, 34, 14, 40, 0),
    (10573, 53, 32.8, 25, 0),
    (10574, 33, 2.5, 14, 0),
    (10574, 40, 18.4, 2, 0),
    (10574, 62, 49.3, 10, 0),
    (10574, 64, 33.25, 6, 0),
    (10575, 59, 55, 12, 0),
    (10575, 63, 43.9, 6, 0),
    (10575, 72, 34.8, 30, 0),
    (10575, 76, 18, 10, 0),
    (10576, 1, 18, 10, 0),
    (10576, 31, 12.5, 20, 0),
    (10576, 44, 19.45, 21, 0),
    (10577, 39, 18, 10, 0),
    (10577, 75, 7.75, 20, 0),
    (10577, 77, 13, 18, 0),
    (10578, 35, 18, 20, 0),
    (10578, 57, 19.5, 6, 0),
    (10579, 15, 15.5, 10, 0),
    (10579, 75, 7.75, 21, 0),
    (10580, 14, 23.25, 15, 0.05),
    (10580, 41, 9.65, 9, 0.05),
    (10580, 65, 21.05, 30, 0.05),
    (10581, 75, 7.75, 50, 0.2),
    (10582, 57, 19.5, 4, 0),
    (10582, 76, 18, 14, 0),
    (10583, 29, 123.79, 10, 0),
    (10583, 60, 34, 24, 0.15),
    (10583, 69, 36, 10, 0.15),
    (10584, 31, 12.5, 50, 0.05),
    (10585, 47, 9.5, 15, 0),
    (10586, 52, 7, 4, 0.15),
    (10587, 26, 31.23, 6, 0),
    (10587, 35, 18, 20, 0),
    (10587, 77, 13, 20, 0),
    (10588, 18, 62.5, 40, 0.2),
    (10588, 42, 14, 100, 0.2),
    (10589, 35, 18, 4, 0),
    (10590, 1, 18, 20, 0),
    (10590, 77, 13, 60, 0.05),
    (10591, 3, 10, 14, 0),
    (10591, 7, 30, 10, 0),
    (10591, 54, 7.45, 50, 0),
    (10592, 15, 15.5, 25, 0.05),
    (10592, 26, 31.23, 5, 0.05),
    (10593, 20, 81, 21, 0.2),
    (10593, 69, 36, 20, 0.2),
    (10593, 76, 18, 4, 0.2),
    (10594, 52, 7, 24, 0),
    (10594, 58, 13.25, 30, 0),
    (10595, 35, 18, 30, 0.25),
    (10595, 61, 28.5, 120, 0.25),
    (10595, 69, 36, 65, 0.25),
    (10596, 56, 38, 5, 0.2),
    (10596, 63, 43.9, 24, 0.2),
    (10596, 75, 7.75, 30, 0.2),
    (10597, 24, 4.5, 35, 0.2),
    (10597, 57, 19.5, 20, 0),
    (10597, 65, 21.05, 12, 0.2),
    (10598, 27, 43.9, 50, 0),
    (10598, 71, 21.5, 9, 0),
    (10599, 62, 49.3, 10, 0),
    (10600, 54, 7.45, 4, 0),
    (10600, 73, 15, 30, 0),
    (10601, 13, 6, 60, 0),
    (10601, 59, 55, 35, 0),
    (10602, 77, 13, 5, 0.25),
    (10603, 22, 21, 48, 0),
    (10603, 49, 20, 25, 0.05),
    (10604, 48, 12.75, 6, 0.1),
    (10604, 76, 18, 10, 0.1),
    (10605, 16, 17.45, 30, 0.05),
    (10605, 59, 55, 20, 0.05),
    (10605, 60, 34, 70, 0.05),
    (10605, 71, 21.5, 15, 0.05),
    (10606, 4, 22, 20, 0.2),
    (10606, 55, 24, 20, 0.2),
    (10606, 62, 49.3, 10, 0.2),
    (10607, 7, 30, 45, 0),
    (10607, 17, 39, 100, 0),
    (10607, 33, 2.5, 14, 0),
    (10607, 40, 18.4, 42, 0),
    (10607, 72, 34.8, 12, 0),
    (10608, 56, 38, 28, 0),
    (10609, 1, 18, 3, 0),
    (10609, 10, 31, 10, 0),
    (10609, 21, 10, 6, 0),
    (10610, 36, 19, 21, 0.25),
    (10611, 1, 18, 6, 0),
    (10611, 2, 19, 10, 0),
    (10611, 60, 34, 15, 0),
    (10612, 10, 31, 70, 0),
    (10612, 36, 19, 55, 0),
    (10612, 49, 20, 18, 0),
    (10612, 60, 34, 40, 0),
    (10612, 76, 18, 80, 0),
    (10613, 13, 6, 8, 0.1),
    (10613, 75, 7.75, 40, 0),
    (10614, 11, 21, 14, 0),
    (10614, 21, 10, 8, 0),
    (10614, 39, 18, 5, 0),
    (10615, 55, 24, 5, 0),
    (10616, 38, 263.5, 15, 0.05),
    (10616, 56, 38, 14, 0),
    (10616, 70, 15, 15, 0.05),
    (10616, 71, 21.5, 15, 0.05),
    (10617, 59, 55, 30, 0.15),
    (10618, 6, 25, 70, 0),
    (10618, 56, 38, 20, 0),
    (10618, 68, 12.5, 15, 0),
    (10619, 21, 10, 42, 0),
    (10619, 22, 21, 40, 0),
    (10620, 24, 4.5, 5, 0),
    (10620, 52, 7, 5, 0),
    (10621, 19, 9.2, 5, 0),
    (10621, 23, 9, 10, 0),
    (10621, 70, 15, 20, 0),
    (10621, 71, 21.5, 15, 0),
    (10622, 2, 19, 20, 0),
    (10622, 68, 12.5, 18, 0.2),
    (10623, 14, 23.25, 21, 0),
    (10623, 19, 9.2, 15, 0.1),
    (10623, 21, 10, 25, 0.1),
    (10623, 24, 4.5, 3, 0),
    (10623, 35, 18, 30, 0.1),
    (10624, 28, 45.6, 10, 0),
    (10624, 29, 123.79, 6, 0),
    (10624, 44, 19.45, 10, 0),
    (10625, 14, 23.25, 3, 0),
    (10625, 42, 14, 5, 0),
    (10625, 60, 34, 10, 0),
    (10626, 53, 32.8, 12, 0),
    (10626, 60, 34, 20, 0),
    (10626, 71, 21.5, 20, 0),
    (10627, 62, 49.3, 15, 0),
    (10627, 73, 15, 35, 0.15),
    (10628, 1, 18, 25, 0),
    (10629, 29, 123.79, 20, 0),
    (10629, 64, 33.25, 9, 0),
    (10630, 55, 24, 12, 0.05),
    (10630, 76, 18, 35, 0),
    (10631, 75, 7.75, 8, 0.1),
    (10632, 2, 19, 30, 0.05),
    (10632, 33, 2.5, 20, 0.05),
    (10633, 12, 38, 36, 0.15),
    (10633, 13, 6, 13, 0.15),
    (10633, 26, 31.23, 35, 0.15),
    (10633, 62, 49.3, 80, 0.15),
    (10634, 7, 30, 35, 0),
    (10634, 18, 62.5, 50, 0),
    (10634, 51, 53, 15, 0),
    (10634, 75, 7.75, 2, 0),
    (10635, 4, 22, 10, 0.1),
    (10635, 5, 21.35, 15, 0.1),
    (10635, 22, 21, 40, 0),
    (10636, 4, 22, 25, 0),
    (10636, 58, 13.25, 6, 0),
    (10637, 11, 21, 10, 0),
    (10637, 50, 16.25, 25, 0.05),
    (10637, 56, 38, 60, 0.05),
    (10638, 45, 9.5, 20, 0),
    (10638, 65, 21.05, 21, 0),
    (10638, 72, 34.8, 60, 0),
    (10639, 18, 62.5, 8, 0),
    (10640, 69, 36, 20, 0.25),
    (10640, 70, 15, 15, 0.25),
    (10641, 2, 19, 50, 0),
    (10641, 40, 18.4, 60, 0),
    (10642, 21, 10, 30, 0.2),
    (10642, 61, 28.5, 20, 0.2),
    (10643, 28, 45.6, 15, 0.25),
    (10643, 39, 18, 21, 0.25),
    (10643, 46, 12, 2, 0.25),
    (10644, 18, 62.5, 4, 0.1),
    (10644, 43, 46, 20, 0),
    (10644, 46, 12, 21, 0.1),
    (10645, 18, 62.5, 20, 0),
    (10645, 36, 19, 15, 0),
    (10646, 1, 18, 15, 0.25),
    (10646, 10, 31, 18, 0.25),
    (10646, 71, 21.5, 30, 0.25),
    (10646, 77, 13, 35, 0.25),
    (10647, 19, 9.2, 30, 0),
    (10647, 39, 18, 20, 0),
    (10648, 22, 21, 15, 0),
    (10648, 24, 4.5, 15, 0.15),
    (10649, 28, 45.6, 20, 0),
    (10649, 72, 34.8, 15, 0),
    (10650, 30, 25.89, 30, 0),
    (10650, 53, 32.8, 25, 0.05),
    (10650, 54, 7.45, 30, 0),
    (10651, 19, 9.2, 12, 0.25),
    (10651, 22, 21, 20, 0.25),
    (10652, 30, 25.89, 2, 0.25),
    (10652, 42, 14, 20, 0),
    (10653, 16, 17.45, 30, 0.1),
    (10653, 60, 34, 20, 0.1),
    (10654, 4, 22, 12, 0.1),
    (10654, 39, 18, 20, 0.1),
    (10654, 54, 7.45, 6, 0.1),
    (10655, 41, 9.65, 20, 0.2),
    (10656, 14, 23.25, 3, 0.1),
    (10656, 44, 19.45, 28, 0.1),
    (10656, 47, 9.5, 6, 0.1),
    (10657, 15, 15.5, 50, 0),
    (10657, 41, 9.65, 24, 0),
    (10657, 46, 12, 45, 0),
    (10657, 47, 9.5, 10, 0),
    (10657, 56, 38, 45, 0),
    (10657, 60, 34, 30, 0),
    (10658, 21, 10, 60, 0),
    (10658, 40, 18.4, 70, 0.05),
    (10658, 60, 34, 55, 0.05),
    (10658, 77, 13, 70, 0.05),
    (10659, 31, 12.5, 20, 0.05),
    (10659, 40, 18.4, 24, 0.05),
    (10659, 70, 15, 40, 0.05),
    (10660, 20, 81, 21, 0),
    (10661, 39, 18, 3, 0.2),
    (10661, 58, 13.25, 49, 0.2),
    (10662, 68, 12.5, 10, 0),
    (10663, 40, 18.4, 30, 0.05),
    (10663, 42, 14, 30, 0.05),
    (10663, 51, 53, 20, 0.05),
    (10664, 10, 31, 24, 0.15),
    (10664, 56, 38, 12, 0.15),
    (10664, 65, 21.05, 15, 0.15),
    (10665, 51, 53, 20, 0),
    (10665, 59, 55, 1, 0),
    (10665, 76, 18, 10, 0),
    (10666, 29, 123.79, 36, 0),
    (10666, 65, 21.05, 10, 0),
    (10667, 69, 36, 45, 0.2),
    (10667, 71, 21.5, 14, 0.2),
    (10668, 31, 12.5, 8, 0.1),
    (10668, 55, 24, 4, 0.1),
    (10668, 64, 33.25, 15, 0.1),
    (10669, 36, 19, 30, 0),
    (10670, 23, 9, 32, 0),
    (10670, 46, 12, 60, 0),
    (10670, 67, 14, 25, 0),
    (10670, 73, 15, 50, 0),
    (10670, 75, 7.75, 25, 0),
    (10671, 16, 17.45, 10, 0),
    (10671, 62, 49.3, 10, 0),
    (10671, 65, 21.05, 12, 0),
    (10672, 38, 263.5, 15, 0.1),
    (10672, 71, 21.5, 12, 0),
    (10673, 16, 17.45, 3, 0),
    (10673, 42, 14, 6, 0),
    (10673, 43, 46, 6, 0),
    (10674, 23, 9, 5, 0),
    (10675, 14, 23.25, 30, 0),
    (10675, 53, 32.8, 10, 0),
    (10675, 58, 13.25, 30, 0),
    (10676, 10, 31, 2, 0),
    (10676, 19, 9.2, 7, 0),
    (10676, 44, 19.45, 21, 0),
    (10677, 26, 31.23, 30, 0.15),
    (10677, 33, 2.5, 8, 0.15),
    (10678, 12, 38, 100, 0),
    (10678, 33, 2.5, 30, 0),
    (10678, 41, 9.65, 120, 0),
    (10678, 54, 7.45, 30, 0),
    (10679, 59, 55, 12, 0),
    (10680, 16, 17.45, 50, 0.25),
    (10680, 31, 12.5, 20, 0.25),
    (10680, 42, 14, 40, 0.25),
    (10681, 19, 9.2, 30, 0.1),
    (10681, 21, 10, 12, 0.1),
    (10681, 64, 33.25, 28, 0),
    (10682, 33, 2.5, 30, 0),
    (10682, 66, 17, 4, 0),
    (10682, 75, 7.75, 30, 0),
    (10683, 52, 7, 9, 0),
    (10684, 40, 18.4, 20, 0),
    (10684, 47, 9.5, 40, 0),
    (10684, 60, 34, 30, 0),
    (10685, 10, 31, 20, 0),
    (10685, 41, 9.65, 4, 0),
    (10685, 47, 9.5, 15, 0),
    (10686, 17, 39, 30, 0.2),
    (10686, 26, 31.23, 15, 0),
    (10687, 9, 97, 50, 0.25),
    (10687, 29, 123.79, 10, 0),
    (10687, 36, 19, 6, 0.25),
    (10688, 10, 31, 18, 0.1),
    (10688, 28, 45.6, 60, 0.1),
    (10688, 34, 14, 14, 0),
    (10689, 1, 18, 35, 0.25),
    (10690, 56, 38, 20, 0.25),
    (10690, 77, 13, 30, 0.25),
    (10691, 1, 18, 30, 0),
    (10691, 29, 123.79, 40, 0),
    (10691, 43, 46, 40, 0),
    (10691, 44, 19.45, 24, 0),
    (10691, 62, 49.3, 48, 0),
    (10692, 63, 43.9, 20, 0),
    (10693, 9, 97, 6, 0),
    (10693, 54, 7.45, 60, 0.15),
    (10693, 69, 36, 30, 0.15),
    (10693, 73, 15, 15, 0.15),
    (10694, 7, 30, 90, 0),
    (10694, 59, 55, 25, 0),
    (10694, 70, 15, 50, 0),
    (10695, 8, 40, 10, 0),
    (10695, 12, 38, 4, 0),
    (10695, 24, 4.5, 20, 0),
    (10696, 17, 39, 20, 0),
    (10696, 46, 12, 18, 0),
    (10697, 19, 9.2, 7, 0.25),
    (10697, 35, 18, 9, 0.25),
    (10697, 58, 13.25, 30, 0.25),
    (10697, 70, 15, 30, 0.25),
    (10698, 11, 21, 15, 0),
    (10698, 17, 39, 8, 0.05),
    (10698, 29, 123.79, 12, 0.05),
    (10698, 65, 21.05, 65, 0.05),
    (10698, 70, 15, 8, 0.05),
    (10699, 47, 9.5, 12, 0),
    (10700, 1, 18, 5, 0.2),
    (10700, 34, 14, 12, 0.2),
    (10700, 68, 12.5, 40, 0.2),
    (10700, 71, 21.5, 60, 0.2),
    (10701, 59, 55, 42, 0.15),
    (10701, 71, 21.5, 20, 0.15),
    (10701, 76, 18, 35, 0.15),
    (10702, 3, 10, 6, 0),
    (10702, 76, 18, 15, 0),
    (10703, 2, 19, 5, 0),
    (10703, 59, 55, 35, 0),
    (10703, 73, 15, 35, 0),
    (10704, 4, 22, 6, 0),
    (10704, 24, 4.5, 35, 0),
    (10704, 48, 12.75, 24, 0),
    (10705, 31, 12.5, 20, 0),
    (10705, 32, 32, 4, 0),
    (10706, 16, 17.45, 20, 0),
    (10706, 43, 46, 24, 0),
    (10706, 59, 55, 8, 0),
    (10707, 55, 24, 21, 0),
    (10707, 57, 19.5, 40, 0),
    (10707, 70, 15, 28, 0.15),
    (10708, 5, 21.35, 4, 0),
    (10708, 36, 19, 5, 0),
    (10709, 8, 40, 40, 0),
    (10709, 51, 53, 28, 0),
    (10709, 60, 34, 10, 0),
    (10710, 19, 9.2, 5, 0),
    (10710, 47, 9.5, 5, 0),
    (10711, 19, 9.2, 12, 0),
    (10711, 41, 9.65, 42, 0),
    (10711, 53, 32.8, 120, 0),
    (10712, 53, 32.8, 3, 0.05),
    (10712, 56, 38, 30, 0),
    (10713, 10, 31, 18, 0),
    (10713, 26, 31.23, 30, 0),
    (10713, 45, 9.5, 110, 0),
    (10713, 46, 12, 24, 0),
    (10714, 2, 19, 30, 0.25),
    (10714, 17, 39, 27, 0.25),
    (10714, 47, 9.5, 50, 0.25),
    (10714, 56, 38, 18, 0.25),
    (10714, 58, 13.25, 12, 0.25),
    (10715, 10, 31, 21, 0),
    (10715, 71, 21.5, 30, 0),
    (10716, 21, 10, 5, 0),
    (10716, 51, 53, 7, 0),
    (10716, 61, 28.5, 10, 0),
    (10717, 21, 10, 32, 0.05),
    (10717, 54, 7.45, 15, 0),
    (10717, 69, 36, 25, 0.05),
    (10718, 12, 38, 36, 0),
    (10718, 16, 17.45, 20, 0),
    (10718, 36, 19, 40, 0),
    (10718, 62, 49.3, 20, 0),
    (10719, 18, 62.5, 12, 0.25),
    (10719, 30, 25.89, 3, 0.25),
    (10719, 54, 7.45, 40, 0.25),
    (10720, 35, 18, 21, 0),
    (10720, 71, 21.5, 8, 0),
    (10721, 44, 19.45, 50, 0.05),
    (10722, 2, 19, 3, 0),
    (10722, 31, 12.5, 50, 0),
    (10722, 68, 12.5, 45, 0),
    (10722, 75, 7.75, 42, 0),
    (10723, 26, 31.23, 15, 0),
    (10724, 10, 31, 16, 0),
    (10724, 61, 28.5, 5, 0),
    (10725, 41, 9.65, 12, 0),
    (10725, 52, 7, 4, 0),
    (10725, 55, 24, 6, 0),
    (10726, 4, 22, 25, 0),
    (10726, 11, 21, 5, 0),
    (10727, 17, 39, 20, 0.05),
    (10727, 56, 38, 10, 0.05),
    (10727, 59, 55, 10, 0.05),
    (10728, 30, 25.89, 15, 0),
    (10728, 40, 18.4, 6, 0),
    (10728, 55, 24, 12, 0),
    (10728, 60, 34, 15, 0),
    (10729, 1, 18, 50, 0),
    (10729, 21, 10, 30, 0),
    (10729, 50, 16.25, 40, 0),
    (10730, 16, 17.45, 15, 0.05),
    (10730, 31, 12.5, 3, 0.05),
    (10730, 65, 21.05, 10, 0.05),
    (10731, 21, 10, 40, 0.05),
    (10731, 51, 53, 30, 0.05),
    (10732, 76, 18, 20, 0),
    (10733, 14, 23.25, 16, 0),
    (10733, 28, 45.6, 20, 0),
    (10733, 52, 7, 25, 0),
    (10734, 6, 25, 30, 0),
    (10734, 30, 25.89, 15, 0),
    (10734, 76, 18, 20, 0),
    (10735, 61, 28.5, 20, 0.1),
    (10735, 77, 13, 2, 0.1),
    (10736, 65, 21.05, 40, 0),
    (10736, 75, 7.75, 20, 0),
    (10737, 13, 6, 4, 0),
    (10737, 41, 9.65, 12, 0),
    (10738, 16, 17.45, 3, 0),
    (10739, 36, 19, 6, 0),
    (10739, 52, 7, 18, 0),
    (10740, 28, 45.6, 5, 0.2),
    (10740, 35, 18, 35, 0.2),
    (10740, 45, 9.5, 40, 0.2),
    (10740, 56, 38, 14, 0.2),
    (10741, 2, 19, 15, 0.2),
    (10742, 3, 10, 20, 0),
    (10742, 60, 34, 50, 0),
    (10742, 72, 34.8, 35, 0),
    (10743, 46, 12, 28, 0.05),
    (10744, 40, 18.4, 50, 0.2),
    (10745, 18, 62.5, 24, 0),
    (10745, 44, 19.45, 16, 0),
    (10745, 59, 55, 45, 0),
    (10745, 72, 34.8, 7, 0),
    (10746, 13, 6, 6, 0),
    (10746, 42, 14, 28, 0),
    (10746, 62, 49.3, 9, 0),
    (10746, 69, 36, 40, 0),
    (10747, 31, 12.5, 8, 0),
    (10747, 41, 9.65, 35, 0),
    (10747, 63, 43.9, 9, 0),
    (10747, 69, 36, 30, 0),
    (10748, 23, 9, 44, 0),
    (10748, 40, 18.4, 40, 0),
    (10748, 56, 38, 28, 0),
    (10749, 56, 38, 15, 0),
    (10749, 59, 55, 6, 0),
    (10749, 76, 18, 10, 0),
    (10750, 14, 23.25, 5, 0.15),
    (10750, 45, 9.5, 40, 0.15),
    (10750, 59, 55, 25, 0.15),
    (10751, 26, 31.23, 12, 0.1),
    (10751, 30, 25.89, 30, 0),
    (10751, 50, 16.25, 20, 0.1),
    (10751, 73, 15, 15, 0),
    (10752, 1, 18, 8, 0),
    (10752, 69, 36, 3, 0),
    (10753, 45, 9.5, 4, 0),
    (10753, 74, 10, 5, 0),
    (10754, 40, 18.4, 3, 0),
    (10755, 47, 9.5, 30, 0.25),
    (10755, 56, 38, 30, 0.25),
    (10755, 57, 19.5, 14, 0.25),
    (10755, 69, 36, 25, 0.25),
    (10756, 18, 62.5, 21, 0.2),
    (10756, 36, 19, 20, 0.2),
    (10756, 68, 12.5, 6, 0.2),
    (10756, 69, 36, 20, 0.2),
    (10757, 34, 14, 30, 0),
    (10757, 59, 55, 7, 0),
    (10757, 62, 49.3, 30, 0),
    (10757, 64, 33.25, 24, 0),
    (10758, 26, 31.23, 20, 0),
    (10758, 52, 7, 60, 0),
    (10758, 70, 15, 40, 0),
    (10759, 32, 32, 10, 0),
    (10760, 25, 14, 12, 0.25),
    (10760, 27, 43.9, 40, 0),
    (10760, 43, 46, 30, 0.25),
    (10761, 25, 14, 35, 0.25),
    (10761, 75, 7.75, 18, 0),
    (10762, 39, 18, 16, 0),
    (10762, 47, 9.5, 30, 0),
    (10762, 51, 53, 28, 0),
    (10762, 56, 38, 60, 0),
    (10763, 21, 10, 40, 0),
    (10763, 22, 21, 6, 0),
    (10763, 24, 4.5, 20, 0),
    (10764, 3, 10, 20, 0.1),
    (10764, 39, 18, 130, 0.1),
    (10765, 65, 21.05, 80, 0.1),
    (10766, 2, 19, 40, 0),
    (10766, 7, 30, 35, 0),
    (10766, 68, 12.5, 40, 0),
    (10767, 42, 14, 2, 0),
    (10768, 22, 21, 4, 0),
    (10768, 31, 12.5, 50, 0),
    (10768, 60, 34, 15, 0),
    (10768, 71, 21.5, 12, 0),
    (10769, 41, 9.65, 30, 0.05),
    (10769, 52, 7, 15, 0.05),
    (10769, 61, 28.5, 20, 0),
    (10769, 62, 49.3, 15, 0),
    (10770, 11, 21, 15, 0.25),
    (10771, 71, 21.5, 16, 0),
    (10772, 29, 123.79, 18, 0),
    (10772, 59, 55, 25, 0),
    (10773, 17, 39, 33, 0),
    (10773, 31, 12.5, 70, 0.2),
    (10773, 75, 7.75, 7, 0.2),
    (10774, 31, 12.5, 2, 0.25),
    (10774, 66, 17, 50, 0),
    (10775, 10, 31, 6, 0),
    (10775, 67, 14, 3, 0),
    (10776, 31, 12.5, 16, 0.05),
    (10776, 42, 14, 12, 0.05),
    (10776, 45, 9.5, 27, 0.05),
    (10776, 51, 53, 120, 0.05),
    (10777, 42, 14, 20, 0.2),
    (10778, 41, 9.65, 10, 0),
    (10779, 16, 17.45, 20, 0),
    (10779, 62, 49.3, 20, 0),
    (10780, 70, 15, 35, 0),
    (10780, 77, 13, 15, 0),
    (10781, 54, 7.45, 3, 0.2),
    (10781, 56, 38, 20, 0.2),
    (10781, 74, 10, 35, 0),
    (10782, 31, 12.5, 1, 0),
    (10783, 31, 12.5, 10, 0),
    (10783, 38, 263.5, 5, 0),
    (10784, 36, 19, 30, 0),
    (10784, 39, 18, 2, 0.15),
    (10784, 72, 34.8, 30, 0.15),
    (10785, 10, 31, 10, 0),
    (10785, 75, 7.75, 10, 0),
    (10786, 8, 40, 30, 0.2),
    (10786, 30, 25.89, 15, 0.2),
    (10786, 75, 7.75, 42, 0.2),
    (10787, 2, 19, 15, 0.05),
    (10787, 29, 123.79, 20, 0.05),
    (10788, 19, 9.2, 50, 0.05),
    (10788, 75, 7.75, 40, 0.05),
    (10789, 18, 62.5, 30, 0),
    (10789, 35, 18, 15, 0),
    (10789, 63, 43.9, 30, 0),
    (10789, 68, 12.5, 18, 0),
    (10790, 7, 30, 3, 0.15),
    (10790, 56, 38, 20, 0.15),
    (10791, 29, 123.79, 14, 0.05),
    (10791, 41, 9.65, 20, 0.05),
    (10792, 2, 19, 10, 0),
    (10792, 54, 7.45, 3, 0),
    (10792, 68, 12.5, 15, 0),
    (10793, 41, 9.65, 14, 0),
    (10793, 52, 7, 8, 0),
    (10794, 14, 23.25, 15, 0.2),
    (10794, 54, 7.45, 6, 0.2),
    (10795, 16, 17.45, 65, 0),
    (10795, 17, 39, 35, 0.25),
    (10796, 26, 31.23, 21, 0.2),
    (10796, 44, 19.45, 10, 0),
    (10796, 64, 33.25, 35, 0.2),
    (10796, 69, 36, 24, 0.2),
    (10797, 11, 21, 20, 0),
    (10798, 62, 49.3, 2, 0),
    (10798, 72, 34.8, 10, 0),
    (10799, 13, 6, 20, 0.15),
    (10799, 24, 4.5, 20, 0.15),
    (10799, 59, 55, 25, 0),
    (10800, 11, 21, 50, 0.1),
    (10800, 51, 53, 10, 0.1),
    (10800, 54, 7.45, 7, 0.1),
    (10801, 17, 39, 40, 0.25),
    (10801, 29, 123.79, 20, 0.25),
    (10802, 30, 25.89, 25, 0.25),
    (10802, 51, 53, 30, 0.25),
    (10802, 55, 24, 60, 0.25),
    (10802, 62, 49.3, 5, 0.25),
    (10803, 19, 9.2, 24, 0.05),
    (10803, 25, 14, 15, 0.05),
    (10803, 59, 55, 15, 0.05),
    (10804, 10, 31, 36, 0),
    (10804, 28, 45.6, 24, 0),
    (10804, 49, 20, 4, 0.15),
    (10805, 34, 14, 10, 0),
    (10805, 38, 263.5, 10, 0),
    (10806, 2, 19, 20, 0.25),
    (10806, 65, 21.05, 2, 0),
    (10806, 74, 10, 15, 0.25),
    (10807, 40, 18.4, 1, 0),
    (10808, 56, 38, 20, 0.15),
    (10808, 76, 18, 50, 0.15),
    (10809, 52, 7, 20, 0),
    (10810, 13, 6, 7, 0),
    (10810, 25, 14, 5, 0),
    (10810, 70, 15, 5, 0),
    (10811, 19, 9.2, 15, 0),
    (10811, 23, 9, 18, 0),
    (10811, 40, 18.4, 30, 0),
    (10812, 31, 12.5, 16, 0.1),
    (10812, 72, 34.8, 40, 0.1),
    (10812, 77, 13, 20, 0),
    (10813, 2, 19, 12, 0.2),
    (10813, 46, 12, 35, 0),
    (10814, 41, 9.65, 20, 0),
    (10814, 43, 46, 20, 0.15),
    (10814, 48, 12.75, 8, 0.15),
    (10814, 61, 28.5, 30, 0.15),
    (10815, 33, 2.5, 16, 0),
    (10816, 38, 263.5, 30, 0.05),
    (10816, 62, 49.3, 20, 0.05),
    (10817, 26, 31.23, 40, 0.15),
    (10817, 38, 263.5, 30, 0),
    (10817, 40, 18.4, 60, 0.15),
    (10817, 62, 49.3, 25, 0.15),
    (10818, 32, 32, 20, 0),
    (10818, 41, 9.65, 20, 0),
    (10819, 43, 46, 7, 0),
    (10819, 75, 7.75, 20, 0),
    (10820, 56, 38, 30, 0),
    (10821, 35, 18, 20, 0),
    (10821, 51, 53, 6, 0),
    (10822, 62, 49.3, 3, 0),
    (10822, 70, 15, 6, 0),
    (10823, 11, 21, 20, 0.1),
    (10823, 57, 19.5, 15, 0),
    (10823, 59, 55, 40, 0.1),
    (10823, 77, 13, 15, 0.1),
    (10824, 41, 9.65, 12, 0),
    (10824, 70, 15, 9, 0),
    (10825, 26, 31.23, 12, 0),
    (10825, 53, 32.8, 20, 0),
    (10826, 31, 12.5, 35, 0),
    (10826, 57, 19.5, 15, 0),
    (10827, 10, 31, 15, 0),
    (10827, 39, 18, 21, 0),
    (10828, 20, 81, 5, 0),
    (10828, 38, 263.5, 2, 0),
    (10829, 2, 19, 10, 0),
    (10829, 8, 40, 20, 0),
    (10829, 13, 6, 10, 0),
    (10829, 60, 34, 21, 0),
    (10830, 6, 25, 6, 0),
    (10830, 39, 18, 28, 0),
    (10830, 60, 34, 30, 0),
    (10830, 68, 12.5, 24, 0),
    (10831, 19, 9.2, 2, 0),
    (10831, 35, 18, 8, 0),
    (10831, 38, 263.5, 8, 0),
    (10831, 43, 46, 9, 0),
    (10832, 13, 6, 3, 0.2),
    (10832, 25, 14, 10, 0.2),
    (10832, 44, 19.45, 16, 0.2),
    (10832, 64, 33.25, 3, 0),
    (10833, 7, 30, 20, 0.1),
    (10833, 31, 12.5, 9, 0.1),
    (10833, 53, 32.8, 9, 0.1),
    (10834, 29, 123.79, 8, 0.05),
    (10834, 30, 25.89, 20, 0.05),
    (10835, 59, 55, 15, 0),
    (10835, 77, 13, 2, 0.2),
    (10836, 22, 21, 52, 0),
    (10836, 35, 18, 6, 0),
    (10836, 57, 19.5, 24, 0),
    (10836, 60, 34, 60, 0),
    (10836, 64, 33.25, 30, 0),
    (10837, 13, 6, 6, 0),
    (10837, 40, 18.4, 25, 0),
    (10837, 47, 9.5, 40, 0.25),
    (10837, 76, 18, 21, 0.25),
    (10838, 1, 18, 4, 0.25),
    (10838, 18, 62.5, 25, 0.25),
    (10838, 36, 19, 50, 0.25),
    (10839, 58, 13.25, 30, 0.1),
    (10839, 72, 34.8, 15, 0.1),
    (10840, 25, 14, 6, 0.2),
    (10840, 39, 18, 10, 0.2),
    (10841, 10, 31, 16, 0),
    (10841, 56, 38, 30, 0),
    (10841, 59, 55, 50, 0),
    (10841, 77, 13, 15, 0),
    (10842, 11, 21, 15, 0),
    (10842, 43, 46, 5, 0),
    (10842, 68, 12.5, 20, 0),
    (10842, 70, 15, 12, 0),
    (10843, 51, 53, 4, 0.25),
    (10844, 22, 21, 35, 0),
    (10845, 23, 9, 70, 0.1),
    (10845, 35, 18, 25, 0.1),
    (10845, 42, 14, 42, 0.1),
    (10845, 58, 13.25, 60, 0.1),
    (10845, 64, 33.25, 48, 0),
    (10846, 4, 22, 21, 0),
    (10846, 70, 15, 30, 0),
    (10846, 74, 10, 20, 0),
    (10847, 1, 18, 80, 0.2),
    (10847, 19, 9.2, 12, 0.2),
    (10847, 37, 26, 60, 0.2),
    (10847, 45, 9.5, 36, 0.2),
    (10847, 60, 34, 45, 0.2),
    (10847, 71, 21.5, 55, 0.2),
    (10848, 5, 21.35, 30, 0),
    (10848, 9, 97, 3, 0),
    (10849, 3, 10, 49, 0),
    (10849, 26, 31.23, 18, 0.15),
    (10850, 25, 14, 20, 0.15),
    (10850, 33, 2.5, 4, 0.15),
    (10850, 70, 15, 30, 0.15),
    (10851, 2, 19, 5, 0.05),
    (10851, 25, 14, 10, 0.05),
    (10851, 57, 19.5, 10, 0.05),
    (10851, 59, 55, 42, 0.05),
    (10852, 2, 19, 15, 0),
    (10852, 17, 39, 6, 0),
    (10852, 62, 49.3, 50, 0),
    (10853, 18, 62.5, 10, 0),
    (10854, 10, 31, 100, 0.15),
    (10854, 13, 6, 65, 0.15),
    (10855, 16, 17.45, 50, 0),
    (10855, 31, 12.5, 14, 0),
    (10855, 56, 38, 24, 0),
    (10855, 65, 21.05, 15, 0.15),
    (10856, 2, 19, 20, 0),
    (10856, 42, 14, 20, 0),
    (10857, 3, 10, 30, 0),
    (10857, 26, 31.23, 35, 0.25),
    (10857, 29, 123.79, 10, 0.25),
    (10858, 7, 30, 5, 0),
    (10858, 27, 43.9, 10, 0),
    (10858, 70, 15, 4, 0),
    (10859, 24, 4.5, 40, 0.25),
    (10859, 54, 7.45, 35, 0.25),
    (10859, 64, 33.25, 30, 0.25),
    (10860, 51, 53, 3, 0),
    (10860, 76, 18, 20, 0),
    (10861, 17, 39, 42, 0),
    (10861, 18, 62.5, 20, 0),
    (10861, 21, 10, 40, 0),
    (10861, 33, 2.5, 35, 0),
    (10861, 62, 49.3, 3, 0),
    (10862, 11, 21, 25, 0),
    (10862, 52, 7, 8, 0),
    (10863, 1, 18, 20, 0.15),
    (10863, 58, 13.25, 12, 0.15),
    (10864, 35, 18, 4, 0),
    (10864, 67, 14, 15, 0),
    (10865, 38, 263.5, 60, 0.05),
    (10865, 39, 18, 80, 0.05),
    (10866, 2, 19, 21, 0.25),
    (10866, 24, 4.5, 6, 0.25),
    (10866, 30, 25.89, 40, 0.25),
    (10867, 53, 32.8, 3, 0),
    (10868, 26, 31.23, 20, 0),
    (10868, 35, 18, 30, 0),
    (10868, 49, 20, 42, 0.1),
    (10869, 1, 18, 40, 0),
    (10869, 11, 21, 10, 0),
    (10869, 23, 9, 50, 0),
    (10869, 68, 12.5, 20, 0),
    (10870, 35, 18, 3, 0),
    (10870, 51, 53, 2, 0),
    (10871, 6, 25, 50, 0.05),
    (10871, 16, 17.45, 12, 0.05),
    (10871, 17, 39, 16, 0.05),
    (10872, 55, 24, 10, 0.05),
    (10872, 62, 49.3, 20, 0.05),
    (10872, 64, 33.25, 15, 0.05),
    (10872, 65, 21.05, 21, 0.05),
    (10873, 21, 10, 20, 0),
    (10873, 28, 45.6, 3, 0),
    (10874, 10, 31, 10, 0),
    (10875, 19, 9.2, 25, 0),
    (10875, 47, 9.5, 21, 0.1),
    (10875, 49, 20, 15, 0),
    (10876, 46, 12, 21, 0),
    (10876, 64, 33.25, 20, 0),
    (10877, 16, 17.45, 30, 0.25),
    (10877, 18, 62.5, 25, 0),
    (10878, 20, 81, 20, 0.05),
    (10879, 40, 18.4, 12, 0),
    (10879, 65, 21.05, 10, 0),
    (10879, 76, 18, 10, 0),
    (10880, 23, 9, 30, 0.2),
    (10880, 61, 28.5, 30, 0.2),
    (10880, 70, 15, 50, 0.2),
    (10881, 73, 15, 10, 0),
    (10882, 42, 14, 25, 0),
    (10882, 49, 20, 20, 0.15),
    (10882, 54, 7.45, 32, 0.15),
    (10883, 24, 4.5, 8, 0),
    (10884, 21, 10, 40, 0.05),
    (10884, 56, 38, 21, 0.05),
    (10884, 65, 21.05, 12, 0.05),
    (10885, 2, 19, 20, 0),
    (10885, 24, 4.5, 12, 0),
    (10885, 70, 15, 30, 0),
    (10885, 77, 13, 25, 0),
    (10886, 10, 31, 70, 0),
    (10886, 31, 12.5, 35, 0),
    (10886, 77, 13, 40, 0),
    (10887, 25, 14, 5, 0),
    (10888, 2, 19, 20, 0),
    (10888, 68, 12.5, 18, 0),
    (10889, 11, 21, 40, 0),
    (10889, 38, 263.5, 40, 0),
    (10890, 17, 39, 15, 0),
    (10890, 34, 14, 10, 0),
    (10890, 41, 9.65, 14, 0),
    (10891, 30, 25.89, 15, 0.05),
    (10892, 59, 55, 40, 0.05),
    (10893, 8, 40, 30, 0),
    (10893, 24, 4.5, 10, 0),
    (10893, 29, 123.79, 24, 0),
    (10893, 30, 25.89, 35, 0),
    (10893, 36, 19, 20, 0),
    (10894, 13, 6, 28, 0.05),
    (10894, 69, 36, 50, 0.05),
    (10894, 75, 7.75, 120, 0.05),
    (10895, 24, 4.5, 110, 0),
    (10895, 39, 18, 45, 0),
    (10895, 40, 18.4, 91, 0),
    (10895, 60, 34, 100, 0),
    (10896, 45, 9.5, 15, 0),
    (10896, 56, 38, 16, 0),
    (10897, 29, 123.79, 80, 0),
    (10897, 30, 25.89, 36, 0),
    (10898, 13, 6, 5, 0),
    (10899, 39, 18, 8, 0.15),
    (10900, 70, 15, 3, 0.25),
    (10901, 41, 9.65, 30, 0),
    (10901, 71, 21.5, 30, 0),
    (10902, 55, 24, 30, 0.15),
    (10902, 62, 49.3, 6, 0.15),
    (10903, 13, 6, 40, 0),
    (10903, 65, 21.05, 21, 0),
    (10903, 68, 12.5, 20, 0),
    (10904, 58, 13.25, 15, 0),
    (10904, 62, 49.3, 35, 0),
    (10905, 1, 18, 20, 0.05),
    (10906, 61, 28.5, 15, 0),
    (10907, 75, 7.75, 14, 0),
    (10908, 7, 30, 20, 0.05),
    (10908, 52, 7, 14, 0.05),
    (10909, 7, 30, 12, 0),
    (10909, 16, 17.45, 15, 0),
    (10909, 41, 9.65, 5, 0),
    (10910, 19, 9.2, 12, 0),
    (10910, 49, 20, 10, 0),
    (10910, 61, 28.5, 5, 0),
    (10911, 1, 18, 10, 0),
    (10911, 17, 39, 12, 0),
    (10911, 67, 14, 15, 0),
    (10912, 11, 21, 40, 0.25),
    (10912, 29, 123.79, 60, 0.25),
    (10913, 4, 22, 30, 0.25),
    (10913, 33, 2.5, 40, 0.25),
    (10913, 58, 13.25, 15, 0),
    (10914, 71, 21.5, 25, 0),
    (10915, 17, 39, 10, 0),
    (10915, 33, 2.5, 30, 0),
    (10915, 54, 7.45, 10, 0),
    (10916, 16, 17.45, 6, 0),
    (10916, 32, 32, 6, 0),
    (10916, 57, 19.5, 20, 0),
    (10917, 30, 25.89, 1, 0),
    (10917, 60, 34, 10, 0),
    (10918, 1, 18, 60, 0.25),
    (10918, 60, 34, 25, 0.25),
    (10919, 16, 17.45, 24, 0),
    (10919, 25, 14, 24, 0),
    (10919, 40, 18.4, 20, 0),
    (10920, 50, 16.25, 24, 0),
    (10921, 35, 18, 10, 0),
    (10921, 63, 43.9, 40, 0),
    (10922, 17, 39, 15, 0),
    (10922, 24, 4.5, 35, 0),
    (10923, 42, 14, 10, 0.2),
    (10923, 43, 46, 10, 0.2),
    (10923, 67, 14, 24, 0.2),
    (10924, 10, 31, 20, 0.1),
    (10924, 28, 45.6, 30, 0.1),
    (10924, 75, 7.75, 6, 0),
    (10925, 36, 19, 25, 0.15),
    (10925, 52, 7, 12, 0.15),
    (10926, 11, 21, 2, 0),
    (10926, 13, 6, 10, 0),
    (10926, 19, 9.2, 7, 0),
    (10926, 72, 34.8, 10, 0),
    (10927, 20, 81, 5, 0),
    (10927, 52, 7, 5, 0),
    (10927, 76, 18, 20, 0),
    (10928, 47, 9.5, 5, 0),
    (10928, 76, 18, 5, 0),
    (10929, 21, 10, 60, 0),
    (10929, 75, 7.75, 49, 0),
    (10929, 77, 13, 15, 0),
    (10930, 21, 10, 36, 0),
    (10930, 27, 43.9, 25, 0),
    (10930, 55, 24, 25, 0.2),
    (10930, 58, 13.25, 30, 0.2),
    (10931, 13, 6, 42, 0.15),
    (10931, 57, 19.5, 30, 0),
    (10932, 16, 17.45, 30, 0.1),
    (10932, 62, 49.3, 14, 0.1),
    (10932, 72, 34.8, 16, 0),
    (10932, 75, 7.75, 20, 0.1),
    (10933, 53, 32.8, 2, 0),
    (10933, 61, 28.5, 30, 0),
    (10934, 6, 25, 20, 0),
    (10935, 1, 18, 21, 0),
    (10935, 18, 62.5, 4, 0.25),
    (10935, 23, 9, 8, 0.25),
    (10936, 36, 19, 30, 0.2),
    (10937, 28, 45.6, 8, 0),
    (10937, 34, 14, 20, 0),
    (10938, 13, 6, 20, 0.25),
    (10938, 43, 46, 24, 0.25),
    (10938, 60, 34, 49, 0.25),
    (10938, 71, 21.5, 35, 0.25),
    (10939, 2, 19, 10, 0.15),
    (10939, 67, 14, 40, 0.15),
    (10940, 7, 30, 8, 0),
    (10940, 13, 6, 20, 0),
    (10941, 31, 12.5, 44, 0.25),
    (10941, 62, 49.3, 30, 0.25),
    (10941, 68, 12.5, 80, 0.25),
    (10941, 72, 34.8, 50, 0),
    (10942, 49, 20, 28, 0),
    (10943, 13, 6, 15, 0),
    (10943, 22, 21, 21, 0),
    (10943, 46, 12, 15, 0),
    (10944, 11, 21, 5, 0.25),
    (10944, 44, 19.45, 18, 0.25),
    (10944, 56, 38, 18, 0),
    (10945, 13, 6, 20, 0),
    (10945, 31, 12.5, 10, 0),
    (10946, 10, 31, 25, 0),
    (10946, 24, 4.5, 25, 0),
    (10946, 77, 13, 40, 0),
    (10947, 59, 55, 4, 0),
    (10948, 50, 16.25, 9, 0),
    (10948, 51, 53, 40, 0),
    (10948, 55, 24, 4, 0),
    (10949, 6, 25, 12, 0),
    (10949, 10, 31, 30, 0),
    (10949, 17, 39, 6, 0),
    (10949, 62, 49.3, 60, 0),
    (10950, 4, 22, 5, 0),
    (10951, 33, 2.5, 15, 0.05),
    (10951, 41, 9.65, 6, 0.05),
    (10951, 75, 7.75, 50, 0.05),
    (10952, 6, 25, 16, 0.05),
    (10952, 28, 45.6, 2, 0),
    (10953, 20, 81, 50, 0.05),
    (10953, 31, 12.5, 50, 0.05),
    (10954, 16, 17.45, 28, 0.15),
    (10954, 31, 12.5, 25, 0.15),
    (10954, 45, 9.5, 30, 0),
    (10954, 60, 34, 24, 0.15),
    (10955, 75, 7.75, 12, 0.2),
    (10956, 21, 10, 12, 0),
    (10956, 47, 9.5, 14, 0),
    (10956, 51, 53, 8, 0),
    (10957, 30, 25.89, 30, 0),
    (10957, 35, 18, 40, 0),
    (10957, 64, 33.25, 8, 0),
    (10958, 5, 21.35, 20, 0),
    (10958, 7, 30, 6, 0),
    (10958, 72, 34.8, 5, 0),
    (10959, 75, 7.75, 20, 0.15),
    (10960, 24, 4.5, 10, 0.25),
    (10960, 41, 9.65, 24, 0),
    (10961, 52, 7, 6, 0.05),
    (10961, 76, 18, 60, 0),
    (10962, 7, 30, 45, 0),
    (10962, 13, 6, 77, 0),
    (10962, 53, 32.8, 20, 0),
    (10962, 69, 36, 9, 0),
    (10962, 76, 18, 44, 0),
    (10963, 60, 34, 2, 0.15),
    (10964, 18, 62.5, 6, 0),
    (10964, 38, 263.5, 5, 0),
    (10964, 69, 36, 10, 0),
    (10965, 51, 53, 16, 0),
    (10966, 37, 26, 8, 0),
    (10966, 56, 38, 12, 0.15),
    (10966, 62, 49.3, 12, 0.15),
    (10967, 19, 9.2, 12, 0),
    (10967, 49, 20, 40, 0),
    (10968, 12, 38, 30, 0),
    (10968, 24, 4.5, 30, 0),
    (10968, 64, 33.25, 4, 0),
    (10969, 46, 12, 9, 0),
    (10970, 52, 7, 40, 0.2),
    (10971, 29, 123.79, 14, 0),
    (10972, 17, 39, 6, 0),
    (10972, 33, 2.5, 7, 0),
    (10973, 26, 31.23, 5, 0),
    (10973, 41, 9.65, 6, 0),
    (10973, 75, 7.75, 10, 0),
    (10974, 63, 43.9, 10, 0),
    (10975, 8, 40, 16, 0),
    (10975, 75, 7.75, 10, 0),
    (10976, 28, 45.6, 20, 0),
    (10977, 39, 18, 30, 0),
    (10977, 47, 9.5, 30, 0),
    (10977, 51, 53, 10, 0),
    (10977, 63, 43.9, 20, 0),
    (10978, 8, 40, 20, 0.15),
    (10978, 21, 10, 40, 0.15),
    (10978, 40, 18.4, 10, 0),
    (10978, 44, 19.45, 6, 0.15),
    (10979, 7, 30, 18, 0),
    (10979, 12, 38, 20, 0),
    (10979, 24, 4.5, 80, 0),
    (10979, 27, 43.9, 30, 0),
    (10979, 31, 12.5, 24, 0),
    (10979, 63, 43.9, 35, 0),
    (10980, 75, 7.75, 40, 0.2),
    (10981, 38, 263.5, 60, 0),
    (10982, 7, 30, 20, 0),
    (10982, 43, 46, 9, 0),
    (10983, 13, 6, 84, 0.15),
    (10983, 57, 19.5, 15, 0),
    (10984, 16, 17.45, 55, 0),
    (10984, 24, 4.5, 20, 0),
    (10984, 36, 19, 40, 0),
    (10985, 16, 17.45, 36, 0.1),
    (10985, 18, 62.5, 8, 0.1),
    (10985, 32, 32, 35, 0.1),
    (10986, 11, 21, 30, 0),
    (10986, 20, 81, 15, 0),
    (10986, 76, 18, 10, 0),
    (10986, 77, 13, 15, 0),
    (10987, 7, 30, 60, 0),
    (10987, 43, 46, 6, 0),
    (10987, 72, 34.8, 20, 0),
    (10988, 7, 30, 60, 0),
    (10988, 62, 49.3, 40, 0.1),
    (10989, 6, 25, 40, 0),
    (10989, 11, 21, 15, 0),
    (10989, 41, 9.65, 4, 0),
    (10990, 21, 10, 65, 0),
    (10990, 34, 14, 60, 0.15),
    (10990, 55, 24, 65, 0.15),
    (10990, 61, 28.5, 66, 0.15),
    (10991, 2, 19, 50, 0.2),
    (10991, 70, 15, 20, 0.2),
    (10991, 76, 18, 90, 0.2),
    (10992, 72, 34.8, 2, 0),
    (10993, 29, 123.79, 50, 0.25),
    (10993, 41, 9.65, 35, 0.25),
    (10994, 59, 55, 18, 0.05),
    (10995, 51, 53, 20, 0),
    (10995, 60, 34, 4, 0),
    (10996, 42, 14, 40, 0),
    (10997, 32, 32, 50, 0),
    (10997, 46, 12, 20, 0.25),
    (10997, 52, 7, 20, 0.25),
    (10998, 24, 4.5, 12, 0),
    (10998, 61, 28.5, 7, 0),
    (10998, 74, 10, 20, 0),
    (10998, 75, 7.75, 30, 0),
    (10999, 41, 9.65, 20, 0.05),
    (10999, 51, 53, 15, 0.05),
    (10999, 77, 13, 21, 0.05),
    (11000, 4, 22, 25, 0.25),
    (11000, 24, 4.5, 30, 0.25),
    (11000, 77, 13, 30, 0),
    (11001, 7, 30, 60, 0),
    (11001, 22, 21, 25, 0),
    (11001, 46, 12, 25, 0),
    (11001, 55, 24, 6, 0),
    (11002, 13, 6, 56, 0),
    (11002, 35, 18, 15, 0.15),
    (11002, 42, 14, 24, 0.15),
    (11002, 55, 24, 40, 0),
    (11003, 1, 18, 4, 0),
    (11003, 40, 18.4, 10, 0),
    (11003, 52, 7, 10, 0),
    (11004, 26, 31.23, 6, 0),
    (11004, 76, 18, 6, 0),
    (11005, 1, 18, 2, 0),
    (11005, 59, 55, 10, 0),
    (11006, 1, 18, 8, 0),
    (11006, 29, 123.79, 2, 0.25),
    (11007, 8, 40, 30, 0),
    (11007, 29, 123.79, 10, 0),
    (11007, 42, 14, 14, 0),
    (11008, 28, 45.6, 70, 0.05),
    (11008, 34, 14, 90, 0.05),
    (11008, 71, 21.5, 21, 0),
    (11009, 24, 4.5, 12, 0),
    (11009, 36, 19, 18, 0.25),
    (11009, 60, 34, 9, 0),
    (11010, 7, 30, 20, 0),
    (11010, 24, 4.5, 10, 0),
    (11011, 58, 13.25, 40, 0.05),
    (11011, 71, 21.5, 20, 0),
    (11012, 19, 9.2, 50, 0.05),
    (11012, 60, 34, 36, 0.05),
    (11012, 71, 21.5, 60, 0.05),
    (11013, 23, 9, 10, 0),
    (11013, 42, 14, 4, 0),
    (11013, 45, 9.5, 20, 0),
    (11013, 68, 12.5, 2, 0),
    (11014, 41, 9.65, 28, 0.1),
    (11015, 30, 25.89, 15, 0),
    (11015, 77, 13, 18, 0),
    (11016, 31, 12.5, 15, 0),
    (11016, 36, 19, 16, 0),
    (11017, 3, 10, 25, 0),
    (11017, 59, 55, 110, 0),
    (11017, 70, 15, 30, 0),
    (11018, 12, 38, 20, 0),
    (11018, 18, 62.5, 10, 0),
    (11018, 56, 38, 5, 0),
    (11019, 46, 12, 3, 0),
    (11019, 49, 20, 2, 0),
    (11020, 10, 31, 24, 0.15),
    (11021, 2, 19, 11, 0.25),
    (11021, 20, 81, 15, 0),
    (11021, 26, 31.23, 63, 0),
    (11021, 51, 53, 44, 0.25),
    (11021, 72, 34.8, 35, 0),
    (11022, 19, 9.2, 35, 0),
    (11022, 69, 36, 30, 0),
    (11023, 7, 30, 4, 0),
    (11023, 43, 46, 30, 0),
    (11024, 26, 31.23, 12, 0),
    (11024, 33, 2.5, 30, 0),
    (11024, 65, 21.05, 21, 0),
    (11024, 71, 21.5, 50, 0),
    (11025, 1, 18, 10, 0.1),
    (11025, 13, 6, 20, 0.1),
    (11026, 18, 62.5, 8, 0),
    (11026, 51, 53, 10, 0),
    (11027, 24, 4.5, 30, 0.25),
    (11027, 62, 49.3, 21, 0.25),
    (11028, 55, 24, 35, 0),
    (11028, 59, 55, 24, 0),
    (11029, 56, 38, 20, 0),
    (11029, 63, 43.9, 12, 0),
    (11030, 2, 19, 100, 0.25),
    (11030, 5, 21.35, 70, 0),
    (11030, 29, 123.79, 60, 0.25),
    (11030, 59, 55, 100, 0.25),
    (11031, 1, 18, 45, 0),
    (11031, 13, 6, 80, 0),
    (11031, 24, 4.5, 21, 0),
    (11031, 64, 33.25, 20, 0),
    (11031, 71, 21.5, 16, 0),
    (11032, 36, 19, 35, 0),
    (11032, 38, 263.5, 25, 0),
    (11032, 59, 55, 30, 0),
    (11033, 53, 32.8, 70, 0.1),
    (11033, 69, 36, 36, 0.1),
    (11034, 21, 10, 15, 0.1),
    (11034, 44, 19.45, 12, 0),
    (11034, 61, 28.5, 6, 0),
    (11035, 1, 18, 10, 0),
    (11035, 35, 18, 60, 0),
    (11035, 42, 14, 30, 0),
    (11035, 54, 7.45, 10, 0),
    (11036, 13, 6, 7, 0),
    (11036, 59, 55, 30, 0),
    (11037, 70, 15, 4, 0),
    (11038, 40, 18.4, 5, 0.2),
    (11038, 52, 7, 2, 0),
    (11038, 71, 21.5, 30, 0),
    (11039, 28, 45.6, 20, 0),
    (11039, 35, 18, 24, 0),
    (11039, 49, 20, 60, 0),
    (11039, 57, 19.5, 28, 0),
    (11040, 21, 10, 20, 0),
    (11041, 2, 19, 30, 0.2),
    (11041, 63, 43.9, 30, 0),
    (11042, 44, 19.45, 15, 0),
    (11042, 61, 28.5, 4, 0),
    (11043, 11, 21, 10, 0),
    (11044, 62, 49.3, 12, 0),
    (11045, 33, 2.5, 15, 0),
    (11045, 51, 53, 24, 0),
    (11046, 12, 38, 20, 0.05),
    (11046, 32, 32, 15, 0.05),
    (11046, 35, 18, 18, 0.05),
    (11047, 1, 18, 25, 0.25),
    (11047, 5, 21.35, 30, 0.25),
    (11048, 68, 12.5, 42, 0),
    (11049, 2, 19, 10, 0.2),
    (11049, 12, 38, 4, 0.2),
    (11050, 76, 18, 50, 0.1),
    (11051, 24, 4.5, 10, 0.2),
    (11052, 43, 46, 30, 0.2),
    (11052, 61, 28.5, 10, 0.2),
    (11053, 18, 62.5, 35, 0.2),
    (11053, 32, 32, 20, 0),
    (11053, 64, 33.25, 25, 0.2),
    (11054, 33, 2.5, 10, 0),
    (11054, 67, 14, 20, 0),
    (11055, 24, 4.5, 15, 0),
    (11055, 25, 14, 15, 0),
    (11055, 51, 53, 20, 0),
    (11055, 57, 19.5, 20, 0),
    (11056, 7, 30, 40, 0),
    (11056, 55, 24, 35, 0),
    (11056, 60, 34, 50, 0),
    (11057, 70, 15, 3, 0),
    (11058, 21, 10, 3, 0),
    (11058, 60, 34, 21, 0),
    (11058, 61, 28.5, 4, 0),
    (11059, 13, 6, 30, 0),
    (11059, 17, 39, 12, 0),
    (11059, 60, 34, 35, 0),
    (11060, 60, 34, 4, 0),
    (11060, 77, 13, 10, 0),
    (11061, 60, 34, 15, 0),
    (11062, 53, 32.8, 10, 0.2),
    (11062, 70, 15, 12, 0.2),
    (11063, 34, 14, 30, 0),
    (11063, 40, 18.4, 40, 0.1),
    (11063, 41, 9.65, 30, 0.1),
    (11064, 17, 39, 77, 0.1),
    (11064, 41, 9.65, 12, 0),
    (11064, 53, 32.8, 25, 0.1),
    (11064, 55, 24, 4, 0.1),
    (11064, 68, 12.5, 55, 0),
    (11065, 30, 25.89, 4, 0.25),
    (11065, 54, 7.45, 20, 0.25),
    (11066, 16, 17.45, 3, 0),
    (11066, 19, 9.2, 42, 0),
    (11066, 34, 14, 35, 0),
    (11067, 41, 9.65, 9, 0),
    (11068, 28, 45.6, 8, 0.15),
    (11068, 43, 46, 36, 0.15),
    (11068, 77, 13, 28, 0.15),
    (11069, 39, 18, 20, 0),
    (11070, 1, 18, 40, 0.15),
    (11070, 2, 19, 20, 0.15),
    (11070, 16, 17.45, 30, 0.15),
    (11070, 31, 12.5, 20, 0),
    (11071, 7, 30, 15, 0.05),
    (11071, 13, 6, 10, 0.05),
    (11072, 2, 19, 8, 0),
    (11072, 41, 9.65, 40, 0),
    (11072, 50, 16.25, 22, 0),
    (11072, 64, 33.25, 130, 0),
    (11073, 11, 21, 10, 0),
    (11073, 24, 4.5, 20, 0),
    (11074, 16, 17.45, 14, 0.05),
    (11075, 2, 19, 10, 0.15),
    (11075, 46, 12, 30, 0.15),
    (11075, 76, 18, 2, 0.15),
    (11076, 6, 25, 20, 0.25),
    (11076, 14, 23.25, 20, 0.25),
    (11076, 19, 9.2, 10, 0.25),
    (11077, 2, 19, 24, 0.2),
    (11077, 3, 10, 4, 0),
    (11077, 4, 22, 1, 0),
    (11077, 6, 25, 1, 0.02),
    (11077, 7, 30, 1, 0.05),
    (11077, 8, 40, 2, 0.1),
    (11077, 10, 31, 1, 0),
    (11077, 12, 38, 2, 0.05),
    (11077, 13, 6, 4, 0),
    (11077, 14, 23.25, 1, 0.03),
    (11077, 16, 17.45, 2, 0.03),
    (11077, 20, 81, 1, 0.04),
    (11077, 23, 9, 2, 0),
    (11077, 32, 32, 1, 0),
    (11077, 39, 18, 2, 0.05),
    (11077, 41, 9.65, 3, 0),
    (11077, 46, 12, 3, 0.02),
    (11077, 52, 7, 2, 0),
    (11077, 55, 24, 2, 0),
    (11077, 60, 34, 2, 0.06),
    (11077, 64, 33.25, 2, 0.03),
    (11077, 66, 17, 1, 0),
    (11077, 73, 15, 2, 0.01),
    (11077, 75, 7.75, 4, 0),
    (11077, 77, 13, 2, 0);

-- Reset sequences to avoid conflicts with future auto-increment inserts
SELECT setval('categories_id_seq', (SELECT MAX(id) FROM categories), true);
SELECT setval('suppliers_id_seq', (SELECT MAX(id) FROM suppliers), true);
SELECT setval('employees_id_seq', (SELECT MAX(id) FROM employees), true);
SELECT setval('products_id_seq', (SELECT MAX(id) FROM products), true);
SELECT setval('regions_id_seq', (SELECT MAX(id) FROM regions), true);
SELECT setval('shippers_id_seq', (SELECT MAX(id) FROM shippers), true);
SELECT setval('orders_id_seq', (SELECT MAX(id) FROM orders), true);
`,
  },
};
