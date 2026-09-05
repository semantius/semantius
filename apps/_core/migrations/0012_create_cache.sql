-- Create generic cache table for storing key-value pairs with expiration
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

-- Grant schema usage to the installing role (database owner) for testing.
-- Skipped for a superuser: it needs no grant and the ACL entry is a test
-- artifact that outlives the extension (B11).
DO $$
BEGIN
    IF NOT (SELECT rolsuper FROM pg_catalog.pg_roles WHERE rolname = current_user) THEN
        EXECUTE format('GRANT USAGE ON SCHEMA common TO %I', current_user);
    END IF;
END $$;

-- The cache functions are SECURITY DEFINER and read and write common._cache
-- unconditionally: they carry no rbac.uid(), because the callers are dictionary
-- code that runs before any identity exists. Nothing outside this file calls
-- them, and nothing outside the database may.
--
-- Withholding the grant to semantius_user is not enough. PostgreSQL grants
-- EXECUTE to PUBLIC on every new function, and the schema-wide
-- `ALTER DEFAULT PRIVILEGES ... REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC` in
-- 0010 does not prevent it: revoking the built-in PUBLIC grant leaves an ACL
-- that PostgreSQL normalizes back to the built-in default, so no pg_default_acl
-- row is stored and the next function is world-executable again. An explicit
-- per-function REVOKE is the only form that holds, and 0060_test_security.sql
-- fails if one is ever missed.
REVOKE EXECUTE ON FUNCTION common.cache_get(TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION common.cache_set(TEXT, TEXT, INTEGER) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION common.cache_delete(TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION common.cache_cleanup() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION common.cache_stats() FROM PUBLIC;

-- Add comments explaining the table and functions
COMMENT ON TABLE common._cache IS 'Generic cache table for storing key-value pairs with expiration. RLS enabled without policies to prevent Data API access.';
COMMENT ON COLUMN common._cache.key IS 'Unique cache key identifier';
COMMENT ON COLUMN common._cache.value IS 'Cached value (stored as text, can be JSON)';
COMMENT ON COLUMN common._cache.expires_at IS 'When this cache entry expires';

COMMENT ON FUNCTION common.cache_get(TEXT) IS 'Get cached value by key, returns NULL if expired or not found';
COMMENT ON FUNCTION common.cache_set(TEXT, TEXT, INTEGER) IS 'Set cached value with expiration in minutes';
COMMENT ON FUNCTION common.cache_delete(TEXT) IS 'Delete cached value by key, returns true if deleted';
COMMENT ON FUNCTION common.cache_cleanup() IS 'Clean up expired cache entries, returns count of deleted entries';
COMMENT ON FUNCTION common.cache_stats() IS 'Get cache statistics including total, expired, and active entries';