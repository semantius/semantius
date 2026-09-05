-- =====================================================
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
    v_system_user TEXT;
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

    -- PostgreSQL 18 native OAuth hardening. With direct (non-PostgREST)
    -- connections the client can overwrite request.jwt.claims to spoof another
    -- subject. system_user holds the identity PostgreSQL validated from the
    -- bearer token, formatted as 'oauth:<sub>', and the client cannot forge it,
    -- so for OAuth sessions it is authoritative for the subject. (Supabase/Neon
    -- PostgREST sessions have system_user 'scram-sha-256:authenticator' and are
    -- left untouched.)
    v_system_user := system_user;
    IF v_system_user LIKE 'oauth:%' THEN
        sub_value := substring(v_system_user FROM 7);
        v_role := 'authenticated';
        PERFORM set_config('request.jwt.claim.sub', sub_value, true);
        PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
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
            RAISE EXCEPTION 'Authentication required: JWT audience claim is missing (expected %)', v_required_aud
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
                RAISE EXCEPTION 'Authentication required: JWT audience does not match (expected %, got %)', v_required_aud, v_jwt_aud
                    USING ERRCODE = 'insufficient_privilege';
            END IF;
            RETURN sub_value;
        END;

        IF jsonb_typeof(v_aud_json) = 'array' THEN
            -- aud is a JSON array — the required audience must be one of the elements
            IF NOT (v_aud_json ? v_required_aud) THEN
                RAISE EXCEPTION 'Authentication required: JWT audience does not match (expected %, got %)', v_required_aud, v_jwt_aud
                    USING ERRCODE = 'insufficient_privilege';
            END IF;
        ELSE
            -- aud is a JSON scalar string — extract text and compare
            IF v_aud_json #>> '{}' != v_required_aud THEN
                RAISE EXCEPTION 'Authentication required: JWT audience does not match (expected %, got %)', v_required_aud, v_jwt_aud
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

-- Bearer-session detection (PostgreSQL 18 SASL OAUTHBEARER). PostgreSQL pins
-- the verified identity in system_user as 'oauth:<sub>' for such sessions.
-- SCRAM logins (the session-mode authenticator, PostgREST, the CLI) carry
-- 'scram-sha-256:<role>' or NULL and are never bearer sessions.
CREATE OR REPLACE FUNCTION rbac.is_bearer_session()
RETURNS BOOLEAN AS $$
    SELECT system_user LIKE 'oauth:%';
$$ LANGUAGE sql STABLE SET search_path = rbac, public;

COMMENT ON FUNCTION rbac.is_bearer_session IS
'True when the session authenticated with a PostgreSQL 18 OAuth bearer token (system_user = oauth:<sub>). Such clients run SQL directly as the request role, so the app.* context cache is not trusted for them.';

-- Initialize request context on first use (lazy initialization)
-- Loads all user permissions once and caches them for the transaction
-- This is called automatically by permission checking functions
-- READ-ONLY: Does not modify database, compatible with PostgREST GET requests
--
-- Trust model of the cache: the app.* settings are ordinary GUCs that the
-- request role can overwrite, and nothing here can tell a value written by rbac
-- from one written by the client. Behind PostgREST or an app server that is
-- harmless, because the client never runs SQL at all. A PostgreSQL 18 OAuth
-- bearer session does hand the client SQL as the request role, so a cached
-- context could be forged there; for those sessions the shortcut below is
-- skipped entirely and the context is re-derived on every call. Making the
-- cache trustworthy for them needs it written and checksummed by a
-- definer-only writer, so that a hand-edited setting is detected rather than
-- believed. That is not built.
--
-- The shortcut also requires the cached subject to match the JWT subject, so
-- that a session carrying no valid claims cannot take it. That is not a defense
-- against forgery; rbac.has_permission carries the same test and spells out what
-- it does and does not guarantee.
CREATE OR REPLACE FUNCTION rbac.ensure_context_initialized()
RETURNS void AS $$
DECLARE
    v_external_id TEXT;
    v_user_id INTEGER;
    v_permissions TEXT;
    v_cached_external_id TEXT;
BEGIN
    -- The bearer test is the bare expression, not rbac.is_bearer_session():
    -- that function pins search_path, which stops PostgreSQL inlining it, so
    -- calling it costs a real function call on every permission check. The
    -- function stays - whoami and the tests use it.
    IF system_user LIKE 'oauth:%' THEN
        -- Permission cache disabled: say so once per session (server log and client).
        PERFORM rbac.uid();
        IF current_setting('app.bearer_cache_notice', true) IS DISTINCT FROM 'sent' THEN
            RAISE WARNING 'pg_semantius: OAuth bearer session detected; the transaction-scoped permission cache is disabled because app.* settings are client-writable in direct SQL sessions. Permissions are re-resolved on every check, which is correct but slower.';
            PERFORM set_config('app.bearer_cache_notice', 'sent', false);
        END IF;
    ELSE
        -- Warm path. See rbac.has_permission for why the subject is compared;
        -- the same four conditions are inlined there and in has_any_permission.
        v_cached_external_id := current_setting('app.current_external_id', true);
        IF current_setting('app.context_initialized', true) = 'true'
           AND v_cached_external_id IS NOT NULL
           AND v_cached_external_id <> ''
           AND v_cached_external_id = current_setting('request.jwt.claim.sub', true)
        THEN
            RETURN; -- Already initialized, skip
        END IF;
    END IF;

    -- Cold path. rbac.uid() validates the claims and returns the subject; it is
    -- the only place an identity is established.
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
'Lazy initialization of request context. Called automatically on first permission check. In OAuth bearer sessions the cached context is not trusted and is re-derived on every call.';

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
            WHERE p.permission_name = ANY(
                -- Separators normalized: any run of commas or whitespace.
                -- See rbac.has_permission for why this is inlined and why it
                -- cannot escalate.
                array_remove(regexp_split_to_array(v_oauth_scopes, '[,[:space:]]+'), ''))
            
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
    -- Validate permission_name. rbac.uid() runs on this cold branch only: it is
    -- what makes an unauthenticated caller raise 42501 instead of receiving
    -- FALSE, and keeping it here means guard test 0060_test_security.sql still
    -- sees a direct rbac.uid() call in this function.
    IF p_permission_name IS NULL OR trim(p_permission_name) = '' THEN
        PERFORM rbac.uid();
        RETURN FALSE;
    END IF;

    -- WARM PATH. The cache test is inlined here rather than delegated to
    -- rbac.ensure_context_initialized(), which is why the same few lines appear
    -- in three places. Delegating costs a second PL/pgSQL frame, and a frame - a
    -- SECURITY DEFINER entry with a search_path save and restore - costs several
    -- times the three current_setting reads it would be entering to perform. On
    -- a warm check that frame dominates, and a warm check is what almost every
    -- call is.
    --
    -- The copies must stay in step. has_any_permission and
    -- ensure_context_initialized carry the same test, and
    -- 0446_test_rbac_hot_path.sql asserts the ordering below in all three.
    --
    -- The bearer test stays ahead of the cache read, and must. The app.*
    -- settings are ordinary GUCs with no owner: whoever holds the session can
    -- overwrite them, and nothing here can tell a value written by rbac from
    -- one written by the client. Behind PostgREST or an app server that is
    -- harmless, because the client never runs SQL at all. A PostgreSQL 18 OAuth
    -- bearer session does run SQL as the request role while the identity is
    -- pinned in system_user, so there the cache is not trusted at any point and
    -- the context is rebuilt on every check.
    --
    -- The subject comparison is therefore NOT a defense against a forged cache:
    -- where the cache can be forged the bearer test above has already sent us to
    -- the cold path, and where it cannot there is nothing to defend against. It
    -- does exactly one thing - it refuses a session that carries no valid
    -- claims. Such a session has an empty request.jwt.claim.sub, which cannot
    -- equal a non-empty app.current_external_id, so it takes the cold path and
    -- rbac.uid() rejects it there.
    --
    -- What the warm path does not check is the role and audience claims.
    -- rbac.uid() validates those, and it runs only when the context is built:
    -- once per transaction, not once per check. Rewriting
    -- request.jwt.claim.role after the context exists does not change the answer
    -- for the rest of that transaction. That gives nothing away - a caller able
    -- to rewrite that GUC is running SQL in the session and can rewrite the
    -- subject too - but a warm check is not equivalent to a cold one and should
    -- not be read as if it were.
    --
    -- Why the comparison holds when the cache is genuine: app.current_external_id
    -- and request.jwt.claim.sub are both transaction-local and both written by
    -- the same cold pass. The Neon path returns the setting verbatim, the
    -- Supabase fan-out writes it before re-reading it, the PostgreSQL 18
    -- override rewrites it from system_user, and the two get_userinfo prefills
    -- assign rbac.uid() to it.
    IF system_user LIKE 'oauth:%' THEN
        PERFORM rbac.ensure_context_initialized();
    ELSE
        v_external_id := current_setting('app.current_external_id', true);
        IF current_setting('app.context_initialized', true) IS DISTINCT FROM 'true'
           OR v_external_id IS NULL
           OR v_external_id = ''
           OR v_external_id IS DISTINCT FROM current_setting('request.jwt.claim.sub', true)
        THEN
            PERFORM rbac.ensure_context_initialized();
        END IF;
    END IF;

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
            
            -- Check if permission is in OAuth scopes.
            -- Separator normalization. app.oauth_scopes was read as a
            -- comma-separated list here and as a space-separated one in
            -- rbac.user_has_permission, so the same value meant different things to
            -- different checkers and a list in the "wrong" format confined the session
            -- to nothing at all. Any run of commas or whitespace now separates, in all
            -- four readers, so "a,b", "a b" and " a ,, b " are the same two scopes.
            --
            -- Inlined rather than given a helper function on purpose: guard test 0240
            -- requires every function to pin search_path, and a pinned search_path
            -- stops PostgreSQL inlining the call - the same trap that made
            -- rbac.is_bearer_session() cost a real call on the hot path.
            --
            -- This cannot escalate. Scopes only ever subtract: the permission has
            -- already been found in the caller's own permission set above, and this
            -- test can only take it away again. Normalizing stops the filter denying
            -- what the token actually granted; it cannot grant what the user lacks.
            --
            -- Normalizing the separators does not make the confinement binding.
            -- app.oauth_scopes is a client-settable GUC like the rest of app.*, so
            -- a session that can run SQL can simply blank it and walk out of its
            -- own confinement - and blanking it reads as "no scopes", which the
            -- branch above treats as no restriction. Closing that needs the scope
            -- list to be carried inside a context the client cannot forge, i.e.
            -- written and checksummed by a definer-only entry point, so that a
            -- cleared or widened list is detected rather than believed. That work
            -- is not done; only the separator inconsistency is fixed here.
            RETURN p_permission_name = ANY(
                array_remove(regexp_split_to_array(v_oauth_scopes, '[,[:space:]]+'), ''));
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
    v_external_id TEXT;
BEGIN
    -- Validate input. rbac.uid() runs on this cold branch only - see
    -- rbac.has_permission for why.
    IF p_permission_names IS NULL OR array_length(p_permission_names, 1) IS NULL THEN
        PERFORM rbac.uid();
        RETURN FALSE;
    END IF;

    -- WARM PATH. Identical to the test in rbac.has_permission,
    -- inlined for the same reason and with the same ordering requirement: the
    -- bearer test must stay ahead of the cache read. The reasoning is spelled
    -- out there.
    IF system_user LIKE 'oauth:%' THEN
        PERFORM rbac.ensure_context_initialized();
    ELSE
        v_external_id := current_setting('app.current_external_id', true);
        IF current_setting('app.context_initialized', true) IS DISTINCT FROM 'true'
           OR v_external_id IS NULL
           OR v_external_id = ''
           OR v_external_id IS DISTINCT FROM current_setting('request.jwt.claim.sub', true)
        THEN
            PERFORM rbac.ensure_context_initialized();
        END IF;
    END IF;

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
            -- Separators normalized: any run of commas or whitespace.
            -- See rbac.has_permission for why this is inlined and why it
            -- cannot escalate.
            IF v_permission = ANY(
                array_remove(regexp_split_to_array(v_oauth_scopes, '[,[:space:]]+'), '')) THEN
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
    -- Separators normalized, as at the three GUC read sites. p_requested_scopes
    -- is an OAuth authorization-request scope string, which RFC 6749 delimits
    -- with spaces, so space was never wrong here; accepting commas too leaves no
    -- site in this file where the separator matters.
    --
    -- array_remove drops the empty strings that a leading, trailing or repeated
    -- separator produces, so a request of ',' or a tab yields no rows rather
    -- than one row for an empty scope. A NULL or all-blank request never gets
    -- this far: the guard at the top of the function returns first.
    FROM unnest(
        array_remove(regexp_split_to_array(p_requested_scopes, '[,[:space:]]+'), '')
    ) AS s(scope);
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

-- Same as rbac.user_id(), but NULL instead of an error when there is no
-- authenticated user (migrations, seed scripts, anonymous sessions) or the
-- user has no row yet. For trigger and audit code that must work in every
-- context. Goes through ensure_context_initialized(), so the value is
-- derived, never read raw from the client-writable app.current_user_id setting.
CREATE OR REPLACE FUNCTION rbac.user_id_or_null()
RETURNS INTEGER AS $$
BEGIN
    RETURN rbac.user_id();
EXCEPTION
    WHEN insufficient_privilege OR invalid_authorization_specification THEN
        RETURN NULL;
END;
$$ LANGUAGE plpgsql STABLE SET search_path = rbac, public;

COMMENT ON FUNCTION rbac.user_id_or_null IS
'Internal user_id of the current user, or NULL when no authenticated user context exists. Never reads app.current_user_id directly.';

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

    -- Whether the cached context is trusted in this session (not in bearer sessions)
    RETURN QUERY SELECT
        'status'::TEXT,
        'permission_cache'::TEXT,
        CASE WHEN rbac.is_bearer_session() THEN 'disabled (bearer session)' ELSE 'enabled' END::TEXT;

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

