-- Create generic cache table for storing key-value pairs with expiration
-- This eliminates the need for Redis and provides persistent caching across all function instances
-- RLS is enabled without policies to prevent access via Data API, only direct SQL functions
-- UNLOGGED table for better performance (truncated on crash, not replicated)


CREATE UNLOGGED TABLE IF NOT EXISTS common._cache (
    id BIGSERIAL PRIMARY KEY,
    key TEXT NOT NULL UNIQUE,
    value TEXT NOT NULL,
    expires_at TIMESTAMP WITH TIME ZONE NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
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
$$ LANGUAGE plpgsql SECURITY DEFINER;

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
$$ LANGUAGE plpgsql SECURITY DEFINER;

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
$$ LANGUAGE plpgsql SECURITY DEFINER;

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
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function to get cache statistics
CREATE OR REPLACE FUNCTION common.cache_stats()
RETURNS TABLE(
    total_entries BIGINT,
    expired_entries BIGINT,
    active_entries BIGINT,
    oldest_entry TIMESTAMP WITH TIME ZONE,
    newest_entry TIMESTAMP WITH TIME ZONE
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
$$ LANGUAGE plpgsql SECURITY DEFINER;

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
COMMENT ON FUNCTION common.cache_stats() IS 'Get cache statistics including total, expired, and active entries';