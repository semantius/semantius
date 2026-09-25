-- =====================================================
-- RBAC FUNCTIONS
-- =====================================================
-- Repeatable. The rbac schema and its default privileges are in
-- 0060_rbac_schema.once.sql.

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
    depth_below INTEGER;
    depth_above INTEGER;
BEGIN
    -- Nothing below needs either permission to exist. The two foreign keys on
    -- this table do reject a row naming an unregistered one, but a foreign key
    -- is an AFTER trigger and fires at the end of the statement, so this BEFORE
    -- trigger sees the row first. A name matching no permission contributes no
    -- rows to either walk, which is the same answer as a name at the edge of the
    -- graph.

    -- Check if adding this edge would create a cycle or exceed depth limit
    -- A cycle exists if the included can reach the including through existing paths
    WITH RECURSIVE hierarchy_path AS (
        -- Start from the proposed included
        SELECT included_permission_name AS permission_name, 1 AS depth
        FROM permission_hierarchy
        WHERE including_permission_name = NEW.included_permission_name

        UNION ALL

        -- Recursively follow the hierarchy
        SELECT ph.included_permission_name, hp.depth + 1
        FROM permission_hierarchy ph
        INNER JOIN hierarchy_path hp ON ph.including_permission_name = hp.permission_name
        WHERE hp.depth < 11  -- Stop at depth 11
    )
    SELECT
        EXISTS (SELECT 1 FROM hierarchy_path WHERE permission_name = NEW.including_permission_name),
        COALESCE(MAX(depth), 0)
    INTO cycle_exists, depth_below
    FROM hierarchy_path;

    -- The chain the new edge joins runs through it, so what is above the
    -- including permission counts as much as what is below the included one.
    -- Measuring only downward lets an 11-edge chain grow without limit: every
    -- edge added under its leaf sees nothing below it and passes.
    --
    -- Both walks stop at 11. That is not an approximation of the answer: a
    -- single side reaching 11 already puts the total over the limit, so the
    -- counts are exact wherever the verdict depends on them.
    WITH RECURSIVE ancestor_path AS (
        SELECT including_permission_name AS permission_name, 1 AS depth
        FROM permission_hierarchy
        WHERE included_permission_name = NEW.including_permission_name

        UNION ALL

        SELECT ph.including_permission_name, ap.depth + 1
        FROM permission_hierarchy ph
        INNER JOIN ancestor_path ap ON ph.included_permission_name = ap.permission_name
        WHERE ap.depth < 11
    )
    SELECT COALESCE(MAX(depth), 0) INTO depth_above FROM ancestor_path;

    IF cycle_exists THEN
        RAISE EXCEPTION 'Cannot add permission hierarchy: would create a cycle. Permission ${including} cannot be both ancestor and descendant of permission ${included}'
            USING ERRCODE = '90210',
                  HINT = jsonb_build_object(
                      'including', NEW.including_permission_name,
                      'included',  NEW.included_permission_name)::text;
    END IF;
    
    -- depth_above + the new edge + depth_below, counted in edges.
    IF depth_above + 1 + depth_below > 11 THEN
        RAISE EXCEPTION 'Cannot add permission hierarchy: maximum depth of 11 levels would be exceeded. Current depth would be ${depth}'
            USING ERRCODE = '90211',
                  HINT = jsonb_build_object('depth', depth_above + 1 + depth_below)::text;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SET search_path = rbac, public;

COMMENT ON FUNCTION rbac.check_permission_hierarchy_cycle IS 
'Trigger function to prevent cycles and enforce 11-level depth limit in permission hierarchy.';

-- Apply trigger BEFORE INSERT OR UPDATE
CREATE OR REPLACE TRIGGER prevent_permission_hierarchy_cycle
    BEFORE INSERT OR UPDATE ON permission_hierarchy
    FOR EACH ROW
    EXECUTE FUNCTION rbac.check_permission_hierarchy_cycle();

-- =====================================================
-- USER DETECTION AND IDENTIFICATION
-- =====================================================

-- Validate JWT claims before allowing any operation
-- Centralizes all JWT validation so that role, aud, or other checks
-- only need to be changed in one place.
-- This is the gateway for all authenticated operations: every entry point in
-- this file reaches it, directly or through ensure_context_initialized.
-- Single JWT validation + user identity function
-- Handles both Neon format (individual request.jwt.claim.* settings)
-- and Supabase format (single request.jwt.claims JSON blob)
-- Normalizes Supabase format to Neon format for all downstream code
-- Accepts a `roles` array carrying `authenticated` when no `role` claim exists
-- at all (Step 3) — the only shape some issuers can emit
-- STABLE, and it writes - transaction-local GUCs only, never a row. So does
-- rbac.ensure_context_initialized(), which every STABLE reader calls. STABLE
-- also lets the planner run the call while estimating selectivity, so never
-- write `col <op> rbac.uid()` in a policy USING clause or a view: EXPLAIN would
-- raise on a session with no claims. Pinned by
-- 0950_test_volatility_contract.sql.
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
    v_roles_claim TEXT;
    v_roles_json JSONB;
    v_iss TEXT;
    v_tid TEXT;
    v_oid TEXT;
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
                        USING ERRCODE = 'insufficient_privilege',
                              HINT = jsonb_build_object('code', '90001')::text;
            END;

            IF supabase_claims IS NULL THEN
                RAISE EXCEPTION 'Authentication required: No valid JWT claims found'
                    USING ERRCODE = 'insufficient_privilege',
                          HINT = jsonb_build_object('code', '90001')::text;
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

    -- Step 3: an issuer that CANNOT mint a `role` claim. Microsoft Entra ID is
    -- the case this exists for: `role` and `roles` are both in its restricted
    -- claim set, so no claims-mapping policy can emit `role`, and an app role
    -- named `authenticated` arrives as `"roles": ["authenticated"]` instead.
    -- PostgREST selects the database role from that same array
    -- (jwt-role-claim-key = `.roles[0]`), so reading it here keeps both ends of
    -- one token agreeing about one thing rather than inventing a second
    -- convention.
    --
    -- ONLY when `role` is absent. A token that carries `role` with some other
    -- value has already answered the question and stays answered: `anon` plus a
    -- `roles` array is still `anon`.
    --
    -- Step 2 has fanned the blob out, so this arrives as the JSON TEXT of
    -- whatever `roles` held — an array from Entra, but issuers exist that emit
    -- a bare or space-separated string, and neither of those is valid JSON. So
    -- the cast is guarded: a cast failure is one of those strings, never an
    -- error for the caller.
    IF v_role IS NULL OR v_role = '' THEN
        v_roles_claim := current_setting('request.jwt.claim.roles', true);

        IF v_roles_claim IS NOT NULL AND v_roles_claim <> '' THEN
            BEGIN
                v_roles_json := v_roles_claim::jsonb;
            EXCEPTION
                WHEN OTHERS THEN v_roles_json := NULL;
            END;

            IF v_roles_json IS NOT NULL AND jsonb_typeof(v_roles_json) = 'array' THEN
                IF v_roles_json ? 'authenticated' THEN
                    v_role := 'authenticated';
                END IF;
            ELSE
                -- A JSON string, or text that never parsed. Both may hold a
                -- space-separated list, and a single name is a list of one.
                IF 'authenticated' = ANY (string_to_array(
                        COALESCE(v_roles_json #>> '{}', v_roles_claim), ' ')) THEN
                    v_role := 'authenticated';
                END IF;
            END IF;

            -- Cache the verdict the way Step 2 caches the blob, so a second
            -- call in the same request takes the fast path at the top.
            IF v_role = 'authenticated' THEN
                PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
            END IF;
        END IF;
    END IF;

    -- Step 4: Microsoft Entra ID subjects. Entra's `sub` is pairwise: the same
    -- person gets a different `sub` in every app registration, so a second
    -- client (UI, CLI, MCP) or a re-created registration would arrive as a new
    -- user with no roles. `oid` is the user's object id, the same for every
    -- app in the tenant, but unique only within that tenant - hence
    -- entra.<tid>.<oid>. Both are GUIDs, so the dots cannot be ambiguous, and
    -- the prefix keeps the value apart from any other issuer's plain `sub`.
    --
    -- Detected by `iss`, not by the mere presence of tid/oid: any issuer can
    -- name a claim `oid`, but only Entra signs these issuer URLs, and the token
    -- layer has already refused issuers it does not trust. v2 tokens, v1
    -- tokens and External ID (CIAM) tenants respectively.
    --
    -- The result is written back into request.jwt.claim.sub because every
    -- warm-path cache test in this file compares against that setting; a
    -- second call recomputes the same value from tid/oid, never from `sub`.
    -- An Entra token without tid or oid is refused rather than falling back to
    -- `sub`: the fallback would silently create a second identity for a user
    -- who already exists under entra.<tid>.<oid>.
    v_iss := current_setting('request.jwt.claim.iss', true);
    IF v_iss ~ '^https://login\.microsoftonline\.com/[^/]+/v2\.0$'
       OR v_iss ~ '^https://sts\.windows\.net/[^/]+/$'
       OR v_iss ~ '^https://[^/]+\.ciamlogin\.com/[^/]+/v2\.0$'
    THEN
        v_tid := current_setting('request.jwt.claim.tid', true);
        v_oid := current_setting('request.jwt.claim.oid', true);
        IF v_tid IS NULL OR v_tid = '' OR v_oid IS NULL OR v_oid = '' THEN
            RAISE EXCEPTION 'Authentication required: Microsoft Entra ID token is missing the tid or oid claim'
                USING ERRCODE = 'insufficient_privilege',
                      HINT = jsonb_build_object('code', '90009')::text;
        END IF;
        sub_value := 'entra.' || v_tid || '.' || v_oid;
        PERFORM set_config('request.jwt.claim.sub', sub_value, true);
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
            USING ERRCODE = 'insufficient_privilege',
                  HINT = jsonb_build_object('code', '90002')::text;
    END IF;

    -- Validate sub
    IF sub_value IS NULL OR sub_value = '' THEN
        RAISE EXCEPTION 'Authentication required: JWT sub claim is missing'
            USING ERRCODE = 'insufficient_privilege',
                  HINT = jsonb_build_object('code', '90003')::text;
    END IF;

    -- Validate JWT audience against _settings if a jwt_aud entry is configured.
    -- This function is SECURITY DEFINER so it bypasses RLS and can always read _settings.
    SELECT value INTO v_required_aud
    FROM _settings
    WHERE name = 'jwt_aud';

    IF v_required_aud IS NOT NULL AND v_required_aud != '' THEN
        v_jwt_aud := current_setting('request.jwt.claim.aud', true);

        IF v_jwt_aud IS NULL OR v_jwt_aud = '' THEN
            RAISE EXCEPTION 'Authentication required: JWT audience claim is missing (expected ${expected})'
                USING ERRCODE = 'insufficient_privilege',
                      HINT = jsonb_build_object('code', '90004', 'expected', v_required_aud)::text;
        END IF;

        -- Try to parse aud as JSON (array or string).
        -- Neon sets array aud values as JSON (e.g. '["myapp","other"]');
        -- a plain string audience is not valid JSON and falls to the exception handler.
        BEGIN
            v_aud_json := v_jwt_aud::jsonb;
        EXCEPTION WHEN invalid_text_representation THEN
            -- Plain (non-JSON) string — compare directly
            IF v_jwt_aud != v_required_aud THEN
                RAISE EXCEPTION 'Authentication required: JWT audience does not match (expected ${expected}, got ${actual})'
                    USING ERRCODE = 'insufficient_privilege',
                          HINT = jsonb_build_object('code', '90005',
                                                    'expected', v_required_aud,
                                                    'actual',   v_jwt_aud)::text;
            END IF;
            RETURN sub_value;
        END;

        IF jsonb_typeof(v_aud_json) = 'array' THEN
            -- aud is a JSON array — the required audience must be one of the elements
            IF NOT (v_aud_json ? v_required_aud) THEN
                RAISE EXCEPTION 'Authentication required: JWT audience does not match (expected ${expected}, got ${actual})'
                    USING ERRCODE = 'insufficient_privilege',
                          HINT = jsonb_build_object('code', '90005',
                                                    'expected', v_required_aud,
                                                    'actual',   v_jwt_aud)::text;
            END IF;
        ELSE
            -- aud is a JSON scalar string — extract text and compare
            IF v_aud_json #>> '{}' != v_required_aud THEN
                RAISE EXCEPTION 'Authentication required: JWT audience does not match (expected ${expected}, got ${actual})'
                    USING ERRCODE = 'insufficient_privilege',
                          HINT = jsonb_build_object('code', '90005',
                                                    'expected', v_required_aud,
                                                    'actual',   v_jwt_aud)::text;
            END IF;
        END IF;
    END IF;

    RETURN sub_value;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = rbac, public;

COMMENT ON FUNCTION rbac.uid IS
'JWT validation gate + user identity. Checks role=authenticated, returns sub. A token with NO role claim is accepted when its roles claim contains authenticated - the shape Microsoft Entra ID emits, where role and roles are both restricted claims and an app role is the only way to say it; a role claim holding any other value is still refused. A token whose iss is a Microsoft Entra ID issuer returns entra.<tid>.<oid> instead of sub (Entra sub differs per app registration), written back into request.jwt.claim.sub; such a token without tid or oid is refused. Auto-detects and normalizes Neon/Supabase JWT formats. When _settings contains a jwt_aud entry the JWT aud claim must match. STABLE, but that never memoizes a PL/pgSQL call - every textual call runs the full validation and a _settings read; the hot paths (rbac.has_permission, has_any_permission, user_id, ensure_context_initialized) carry their own warm test instead of calling this on every check.';

-- =====================================================
-- USER MANAGEMENT
-- =====================================================

-- Read-only function to get user_id by external_id
-- Returns NULL if user doesn't exist
--
-- Nothing in the database calls it: the policies resolve the caller through
-- rbac.has_permission and the context cache instead. It exists as an RPC for a
-- client that holds an external_id and wants the internal one, which is why the
-- target check below is the whole of its access control.
--
-- SELF-OR-ADMIN. Four functions in this file take a subject as a parameter and
-- answer a question about it - this one, user_has_permission,
-- get_user_permissions and validate_oauth_scopes. All four are SECURITY DEFINER
-- and reachable over PostgREST RPC, so a target check is the only thing between
-- an authenticated session and another principal's authorization state:
-- user_roles, role_permissions and permissions are invisible to a plain user
-- under RLS, and these functions read straight past that.
--
-- The identity half is a smaller gain, and worth being honest about. `user:read`
-- sits in the base User role, so a logged-in session can already read the whole
-- users table; guarding this function matters for a deployment that narrows
-- `user:read`, and costs nothing where it does not.
--
-- Asking about yourself is ordinary; asking about somebody else is an
-- administrative act. The rule is the one public.list_api_keys already applies,
-- and it raises rather than returning empty so a denial is never mistaken for an
-- answer.
--
-- rbac.uid() is called inside the test, not before it: it is the authentication
-- gate, raising when the session carries no valid claims. STABLE does not make
-- the call free - a textual call runs the full validation and a _settings read
-- every time, which is why the hot paths carry a warm test instead - but this
-- function is not a hot path, and the self branch needs the subject anyway.
CREATE OR REPLACE FUNCTION rbac.get_user_by_external_id(
    p_external_id TEXT
)
RETURNS INTEGER AS $$
DECLARE
    v_user_id INTEGER;
BEGIN
    IF p_external_id IS DISTINCT FROM rbac.uid() THEN
        PERFORM rbac.require_permission('admin');
    END IF;

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
'Read-only lookup of user_id by external_id. Returns NULL if user not found or disabled. Self-or-admin: asking about another principal requires admin. Reachable over PostgREST RPC; no policy or function in the database calls it.';

-- Initialize or update user from JWT
-- Called by get_userinfo() to create/update user and update last_seen
-- Not reachable by the request role at all: see the revoke below this function.
CREATE OR REPLACE FUNCTION rbac.upsert_user_from_jwt(
    p_external_id TEXT,
    p_email TEXT DEFAULT NULL,
    p_display_name TEXT DEFAULT NULL,
    p_first_name TEXT DEFAULT NULL,
    p_last_name TEXT DEFAULT NULL
)
RETURNS INTEGER AS $$
DECLARE
    v_id           INTEGER;
    v_last_seen    TIMESTAMPTZ;
    v_email        TEXT;
    v_display_name TEXT;
    v_first_name   TEXT;
    v_last_name    TEXT;
BEGIN
    IF p_external_id IS NULL OR trim(p_external_id) = '' THEN
        RAISE EXCEPTION 'external_id cannot be null or empty' USING ERRCODE = '90007';
    END IF;

    SELECT id, last_seen, email, display_name, first_name, last_name
      INTO v_id, v_last_seen, v_email, v_display_name, v_first_name, v_last_name
      FROM users WHERE external_id = p_external_id;

    IF FOUND THEN
        -- Each test below is the SET expression of the UPDATE compared with
        -- the stored value, so the row is written exactly when the write
        -- would change it, or when the heartbeat is older than the throttle.
        -- last_seen IS NULL is tested on its own: NULL < timestamp is never true.
        IF v_last_seen IS NULL
           OR v_last_seen < CURRENT_TIMESTAMP - INTERVAL '5 minutes'
           OR v_email        IS DISTINCT FROM COALESCE(p_email, v_email)
           OR v_display_name IS DISTINCT FROM COALESCE(NULLIF(p_display_name, ''), v_display_name)
           OR v_first_name   IS DISTINCT FROM COALESCE(NULLIF(p_first_name, ''), v_first_name)
           OR v_last_name    IS DISTINCT FROM COALESCE(NULLIF(p_last_name, ''), v_last_name)
        THEN
            UPDATE users
               SET last_seen    = CURRENT_TIMESTAMP,
                   email        = COALESCE(p_email, email),
                   display_name = COALESCE(NULLIF(p_display_name, ''), display_name),
                   first_name   = COALESCE(NULLIF(p_first_name, ''), first_name),
                   last_name    = COALESCE(NULLIF(p_last_name, ''), last_name)
             WHERE id = v_id;
        END IF;
        RETURN v_id;
    END IF;

    -- First login. ON CONFLICT covers two first logins racing: the loser
    -- updates the winner's row once, unthrottled, which is harmless.
    INSERT INTO users (external_id, email, display_name, first_name, last_name, last_seen)
    VALUES (p_external_id, p_email, COALESCE(p_display_name, ''), COALESCE(p_first_name, ''), COALESCE(p_last_name, ''), CURRENT_TIMESTAMP)
    -- The arbiter is the dictionary's partial unique index, so the predicate
    -- has to be repeated for inference to work.
    ON CONFLICT (external_id) WHERE external_id IS NOT NULL AND external_id <> '' DO UPDATE
    SET last_seen    = CURRENT_TIMESTAMP,
        email        = COALESCE(EXCLUDED.email, users.email),
        display_name = COALESCE(NULLIF(EXCLUDED.display_name, ''), users.display_name),
        first_name   = COALESCE(NULLIF(EXCLUDED.first_name, ''), users.first_name),
        last_name    = COALESCE(NULLIF(EXCLUDED.last_name, ''), users.last_name)
    RETURNING id INTO v_id;
    RETURN v_id;
END;
$$ LANGUAGE plpgsql SECURITY INVOKER SET search_path = rbac, public;

COMMENT ON FUNCTION rbac.upsert_user_from_jwt IS
'Creates or updates user record from JWT claims. Stores name as display_name, given_name as first_name, family_name as last_name. A repeat call within five minutes of the stored last_seen, with claims that match the stored values, writes nothing at all - not even last_seen - so a heartbeat login costs one indexed SELECT. Called by get_userinfo().';

-- Provisioning is not a request-role capability. This function takes the subject
-- as a parameter and writes to users, so a caller that could reach it could
-- create a principal that never authenticated, overwrite another one's email, or
-- refresh a foreign last_seen - and last_seen is what the first-user bootstrap in
-- 0100_rbac_rls.sql reads. It is SECURITY INVOKER: its one caller,
-- public.get_userinfo() (0250_public_functions.sql), is SECURITY DEFINER, so a
-- call reached through get_userinfo runs as the owner regardless, and
-- get_userinfo's own rbac.uid() call is the authentication gate - this function
-- trusts the subject its caller already authenticated rather than repeating
-- that check itself. The revoke from semantius_user has to be explicit: the
-- ALTER DEFAULT PRIVILEGES in 0060_rbac_schema.once.sql grants EXECUTE on every
-- function created in this schema.
REVOKE EXECUTE ON FUNCTION rbac.upsert_user_from_jwt(TEXT, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION rbac.upsert_user_from_jwt(TEXT, TEXT, TEXT, TEXT, TEXT) FROM semantius_user;

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
-- VOLATILE, and one of the two writers the STABLE readers reach: rbac.uid()
-- normalizes claims into GUCs of its own on the Supabase and PostgreSQL 18
-- paths. Both write settings only, never a row.
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
        -- Just the one-time notice here; the uid() gate below serves this
        -- branch too. Once per transaction: the flag is transaction-local so
        -- that it cannot outlive the request. A session-scoped one would survive
        -- on a pooled backend and silence the warning for every later request
        -- that happened to land on the same connection.
        -- An unauthenticated bearer session sees this WARNING
        -- before the 42501 that the gate below still raises for it, which is
        -- harmless - the notice is only asserted in authenticated sessions.
        IF current_setting('app.bearer_cache_notice', true) IS DISTINCT FROM 'sent' THEN
            RAISE WARNING 'pg_semantius: OAuth bearer session detected; the transaction-scoped permission cache is disabled because app.* settings are client-writable in direct SQL sessions. Permissions are re-resolved on every check, which is correct but slower.';
            PERFORM set_config('app.bearer_cache_notice', 'sent', true);
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

    -- Cold path: the one call that establishes identity for both branches above.
    v_external_id := rbac.uid();

    -- Direct lookup rather than rbac.get_user_by_external_id(): that wrapper's
    -- self-or-admin guard re-validates the same claims a second time, purely to
    -- confirm a subject cannot fail to be itself, since its argument is the
    -- external_id this function just resolved one line up. This function is
    -- already a definer, so nothing is lost by reading the row directly instead.
    SELECT id INTO v_user_id FROM users WHERE external_id = v_external_id AND is_disabled = FALSE;

    -- User must exist - client should have called get_userinfo() on first login
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'User not found: ${external_id}. Client must call get_userinfo() on first login to create user record.'
            USING ERRCODE = 'insufficient_privilege',
                  HINT = jsonb_build_object('code', '90006', 'external_id', v_external_id)::text;
    END IF;

    -- OPTIMIZATION: Load all user permissions once as comma-separated string.
    -- Once per transaction where the cache is trusted, which is every session
    -- but a bearer one - there the context is rebuilt on every check, so this
    -- recursive CTE runs per check and the WARNING above says so.
    SELECT string_agg(permission_name, ',' ORDER BY permission_name)
    INTO v_permissions
    FROM rbac.get_user_permissions_by_id(v_user_id);
    
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
-- 1. Permissions from the subject's roles
-- 2. Direct per-user grants from user_permissions
-- 3. Implied permissions via hierarchy
-- 4. OAuth scope restrictions (if scopes are set)
CREATE OR REPLACE FUNCTION rbac.user_has_permission(
    p_external_id TEXT,
    p_permission_name TEXT
)
RETURNS BOOLEAN AS $$
DECLARE
    v_scope_closure TEXT;
    v_has_permission BOOLEAN;
BEGIN
    -- Self-or-admin, as at rbac.get_user_by_external_id, where the rule is
    -- explained. Note that the admin test runs through rbac.has_permission and
    -- therefore honors app.oauth_scopes: a session confined to scopes that do
    -- not include 'admin' cannot ask about another subject even if the principal
    -- behind it is an administrator.
    IF p_external_id IS DISTINCT FROM rbac.uid() THEN
        PERFORM rbac.require_permission('admin');
    END IF;

    -- Validate inputs
    IF p_external_id IS NULL OR trim(p_external_id) = '' THEN
        RETURN FALSE;
    END IF;
    
    IF p_permission_name IS NULL OR trim(p_permission_name) = '' THEN
        RETURN FALSE;
    END IF;
    
    -- Check if user has the permission (including hierarchy)
    -- Using recursive CTE to follow the hierarchy
    v_has_permission := EXISTS (
    WITH RECURSIVE permission_tree AS (
        -- Start with direct permissions from roles
        SELECT DISTINCT rp.permission_name
        FROM users u
        JOIN user_roles ur ON u.id = ur.user_id
        JOIN roles r ON ur.role_id = r.id
        JOIN role_permissions rp ON r.id = rp.role_id
        WHERE u.external_id = p_external_id
          AND u.is_disabled = FALSE
        
        UNION
        
        -- Direct per-user permissions
        SELECT DISTINCT up.permission_name
        FROM users u
        JOIN user_permissions up ON u.id = up.user_id
        WHERE u.external_id = p_external_id
          AND u.is_disabled = FALSE
        
        UNION
        
        -- Add implied permissions (included in hierarchy)
        SELECT DISTINCT ph.included_permission_name
        FROM permission_tree pt
        JOIN permission_hierarchy ph ON pt.permission_name = ph.including_permission_name
    )
    SELECT 1 FROM permission_tree
    WHERE permission_name = p_permission_name
    );
    
    -- If user doesn't have the permission, return false immediately
    IF NOT v_has_permission THEN
        RETURN FALSE;
    END IF;
    
    -- Check OAuth2 scopes if present. The expansion this function has always
    -- applied now lives in rbac.scope_closure, so the two cached checkers apply
    -- exactly the same one.
    v_scope_closure := rbac.scope_closure();

    -- If no OAuth scopes set (user-initiated request), allow
    IF v_scope_closure IS NULL THEN
        RETURN TRUE;
    END IF;

    RETURN position(',' || p_permission_name || ',' IN ',' || v_scope_closure || ',') > 0;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = rbac, public;

COMMENT ON FUNCTION rbac.user_has_permission IS 
'Checks if user has permission by name, considering hierarchy and OAuth scopes.';

-- =====================================================
-- OAUTH SCOPE CONFINEMENT
-- =====================================================
-- A scope names a permission, and naming a permission names everything that
-- permission includes. permission_hierarchy is what a permission MEANS, so a
-- token scoped to user:manage may read users: user:manage includes user:read.
--
-- Matching the scope list literally instead is not a stricter reading, it is a
-- broken one. The policies on users ask for user:read to SELECT and user:manage
-- to INSERT, UPDATE and DELETE, so a literal match would give a token scoped to
-- user:manage the three write policies and deny it the read - authority to write
-- rows it cannot see. All three checkers expand the scope side for that reason:
-- if one compared the raw strings instead, the same session would get opposite
-- answers to one question depending on which function a policy called.
--
-- Expanding the scope side cannot widen authority. Every checker intersects this
-- list with the permissions the user actually holds, which are themselves
-- already the transitive closure of their grants; a scope can only subtract from
-- that. The one thing it must not do is subtract more than the token asked for.
--
-- What this still does not do is make confinement binding. app.oauth_scopes is a
-- client-settable GUC like the rest of app.*, so a session that can run SQL can
-- blank it and walk out of its own confinement - a blank list reads as "no
-- scopes", i.e. no restriction. Closing that needs the list carried in a context
-- the client cannot forge, written and checksummed by a definer-only entry
-- point. Not done here.
CREATE OR REPLACE FUNCTION rbac.expand_scopes(p_scopes TEXT)
RETURNS TEXT AS $$
    WITH RECURSIVE permission_tree AS (
        -- Separators normalized: any run of commas or whitespace, so 'a,b',
        -- 'a b' and ' a ,, b ' name the same two scopes. A scope naming no
        -- registered permission contributes nothing, which is why the seed
        -- side reads from permissions rather than from the array directly.
        SELECT DISTINCT p.permission_name
        FROM permissions p
        WHERE p.permission_name = ANY(
            array_remove(regexp_split_to_array(p_scopes, '[,[:space:]]+'), ''))

        UNION

        SELECT DISTINCT ph.included_permission_name
        FROM permission_tree pt
        JOIN permission_hierarchy ph ON pt.permission_name = ph.including_permission_name
    )
    SELECT string_agg(permission_name, ',' ORDER BY permission_name) FROM permission_tree;
$$ LANGUAGE sql STABLE SET search_path = rbac, public;

COMMENT ON FUNCTION rbac.expand_scopes IS
'The permissions a scope list confines a session to: the names it carries plus everything those names include through permission_hierarchy, as a comma-separated list. NULL when the list names no registered permission.';

-- SECURITY INVOKER, deliberately. permissions and permission_hierarchy are
-- admin-only under RLS, and this has to answer the same way for every caller, so
-- it relies on running inside one of the three SECURITY DEFINER checkers below -
-- there current_user is the owner, which holds BYPASSRLS. Reached any other way
-- it sees no rows, returns nothing, and the caller reads that as "confined to
-- nothing": the failure is a denial, never a grant. The request role cannot
-- reach it at all (revoked at the end of this file).
CREATE OR REPLACE FUNCTION rbac.scope_closure()
RETURNS TEXT AS $$
DECLARE
    v_raw      TEXT;
    v_expanded TEXT;
BEGIN
    v_raw := current_setting('app.oauth_scopes', true);

    -- No list at all is no confinement. A list made only of separators is NOT
    -- the same thing and must not be read as one - it expands to nothing and
    -- denies everything, which is what a caller asking for nothing deserves.
    IF v_raw IS NULL OR v_raw = '' THEN
        RETURN NULL;
    END IF;

    -- The expansion is a recursive walk, so it is computed once per transaction
    -- and kept beside app.user_permissions. The cache is keyed on the raw list
    -- it was built from, so rewriting app.oauth_scopes mid-transaction rebuilds
    -- rather than answering from the previous list.
    --
    -- Not read in a bearer session: there the app.* settings are client-writable
    -- and nothing can tell a value written by rbac from one written by the
    -- client, which is the same stance rbac.has_permission takes toward the
    -- permission cache. It costs the walk on every check and is correct.
    IF system_user NOT LIKE 'oauth:%' THEN
        v_expanded := current_setting('app.oauth_scopes_expanded', true);
        IF v_expanded IS NOT NULL
           AND current_setting('app.oauth_scopes_expanded_for', true) IS NOT DISTINCT FROM v_raw
        THEN
            RETURN v_expanded;
        END IF;
    END IF;

    -- COALESCE, so a list naming nothing registered is '' - confined to nothing -
    -- and never NULL, which the callers read as unconfined.
    v_expanded := COALESCE(rbac.expand_scopes(v_raw), '');

    IF system_user NOT LIKE 'oauth:%' THEN
        PERFORM set_config('app.oauth_scopes_expanded_for', v_raw, true);
        PERFORM set_config('app.oauth_scopes_expanded', v_expanded, true);
    END IF;

    RETURN v_expanded;
END;
$$ LANGUAGE plpgsql STABLE SET search_path = rbac, public;

COMMENT ON FUNCTION rbac.scope_closure IS
'The expanded scope list confining this session, or NULL when it is not confined. Memoized per transaction against the raw app.oauth_scopes it was built from; never memoized in an OAuth bearer session, where app.* is client-writable.';

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
    v_scope_closure TEXT;
    v_external_id TEXT;
BEGIN
    -- Validate permission_name. rbac.uid() runs on this cold branch only: it is
    -- what makes an unauthenticated caller raise 42501 instead of receiving
    -- FALSE, and keeping it here means guard test 0900_test_security.sql still
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
    -- The copies must stay in step. has_any_permission, ensure_context_initialized
    -- and rbac.user_id() carry the same test, and 0320_test_rbac_hot_path.sql
    -- asserts the ordering below in all four.
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
    -- override rewrites it from system_user, and the get_userinfo prefill
    -- assigns rbac.uid() to it.
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
            -- Permission found in cache, now check OAuth scopes if present.
            --
            -- The raw setting is read here rather than left to
            -- rbac.scope_closure(), which would answer the same question: almost
            -- every session carries no scope list, and that case has to stay one
            -- current_setting read. Entering scope_closure would cost a PL/pgSQL
            -- frame - a search_path save and restore - several times what the
            -- read costs, on every permission check in the system. Same
            -- reasoning as the inlined warm-path test above.
            v_oauth_scopes := current_setting('app.oauth_scopes', true);

            -- No scopes set (user-initiated request): no restriction.
            IF v_oauth_scopes IS NULL OR v_oauth_scopes = '' THEN
                RETURN TRUE;
            END IF;

            -- Confined. rbac.scope_closure() is the expanded list: the scopes
            -- the token names plus everything those include, memoized for the
            -- transaction.
            v_scope_closure := rbac.scope_closure();
            
            -- This cannot escalate. The permission has already been found in
            -- the caller's own permission set above, so this test can only take
            -- it away again; it never adds one. The same string search as the
            -- cache test, over the same comma-separated shape, which is why
            -- rbac.scope_closure returns a list rather than an array.
            RETURN position(',' || p_permission_name || ',' IN ',' || v_scope_closure || ',') > 0;
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
        RAISE EXCEPTION 'Permission denied: ${permission} required'
            USING ERRCODE = 'insufficient_privilege',
                  HINT = jsonb_build_object(
                      'code',       '90101',
                      'hint',       'Ask an administrator to grant ${permission}',
                      'permission', p_permission_name)::text;
    END IF;
END;
-- STABLE so PostgREST serves it over GET; raising is not a side effect.
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = rbac, public;

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
    v_scope_closure TEXT;
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

    IF v_cached_permissions IS NULL OR v_cached_permissions = '' THEN
        -- Not reachable after initialization; a user with no permissions at all
        -- still gets an empty cache entry rather than none.
        RETURN FALSE;
    END IF;

    -- Resolved once, before the loop: the confinement does not change while the
    -- loop runs, and rbac.scope_closure walks permission_hierarchy on its first
    -- call in a transaction. The raw setting is tested first so an unconfined
    -- session never enters that frame at all - see rbac.has_permission for why
    -- one frame on this path is worth avoiding. A list that names nothing
    -- registered expands to '' and confines the session to nothing, which is not
    -- the same as carrying no list.
    v_oauth_scopes := current_setting('app.oauth_scopes', true);

    IF v_oauth_scopes IS NOT NULL AND v_oauth_scopes <> '' THEN
        v_scope_closure := rbac.scope_closure();
    END IF;

    -- One loop, and it has to be one: both conditions must hold for the SAME
    -- permission. Asking them separately - 'is any of these held' AND 'is any of
    -- these in scope' - lets the two answers come from different entries, so a
    -- token scoped to a permission its bearer does not hold would still unlock
    -- the ones the bearer does hold. A scope list is an intersection with what
    -- the user holds and can only ever subtract; nothing about it may widen an
    -- answer. The single-permission checkers cannot split this way, which is why
    -- the trap is specific to the variadic form.
    --
    -- The scope side is the expanded list, as in rbac.has_permission and
    -- rbac.user_has_permission: a scope names a permission and everything that
    -- permission includes, so a token scoped to a parent permission satisfies a
    -- check naming one of its children.
    FOREACH v_permission IN ARRAY p_permission_names
    LOOP
        IF position(',' || v_permission || ',' IN ',' || v_cached_permissions || ',') > 0
           AND (v_scope_closure IS NULL
                OR position(',' || v_permission || ',' IN ',' || v_scope_closure || ',') > 0)
        THEN
            RETURN TRUE;
        END IF;
    END LOOP;

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
        RAISE EXCEPTION 'Permission denied: one of (${permissions}) required'
            USING ERRCODE = 'insufficient_privilege',
                  HINT = jsonb_build_object(
                      'code',        '90102',
                      'permissions', array_to_string(p_permission_names, ', '))::text;
    END IF;
END;
-- STABLE, as rbac.require_permission.
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = rbac, public;

COMMENT ON FUNCTION rbac.require_any_permission IS 
'Raises exception if current user lacks all specified permissions.';

-- =====================================================
-- PERMISSION QUERIES
-- =====================================================

-- Get all effective permissions for a user by internal id, with no subject to
-- check and therefore no self-or-admin guard of its own.
--
-- permissions is keyed by permission_name and every FK carries the name, so no
-- join to permissions or roles is needed to answer this - unlike the CTE this
-- replaces, which joined roles only to get from user_roles to role_permissions.
--
-- Not SECURITY DEFINER, deliberately: every caller - rbac.get_user_permissions
-- below, rbac.ensure_context_initialized and public.get_userinfo - is itself
-- SECURITY DEFINER, so a call reached from any of them already runs as the
-- owner (semantius_owner, BYPASSRLS, or the installing role on managed
-- platforms, which 0100_rbac_rls.sql requires to be BYPASSRLS; no table here carries FORCE
-- ROW LEVEL SECURITY) regardless of this function's own label. That keeps it
-- outside guard test 0900_test_security.sql's rule that every definer calls
-- rbac.uid(): an internal helper with no identity of its own to authenticate
-- should not satisfy that rule by pretense.
CREATE OR REPLACE FUNCTION rbac.get_user_permissions_by_id(p_user_id INTEGER)
RETURNS TABLE (permission_name TEXT) AS $$
BEGIN
    -- A disabled user has no permissions. The comparison with FALSE is on
    -- purpose: is_disabled is nullable and NULL must keep meaning "no permissions".
    IF p_user_id IS NULL OR NOT EXISTS (
        SELECT 1 FROM users WHERE id = p_user_id AND is_disabled = FALSE
    ) THEN
        RETURN;
    END IF;

    RETURN QUERY
    WITH RECURSIVE permission_tree AS (
        SELECT rp.permission_name
        FROM user_roles ur
        JOIN role_permissions rp ON rp.role_id = ur.role_id
        WHERE ur.user_id = p_user_id
        UNION
        SELECT up.permission_name
        FROM user_permissions up
        WHERE up.user_id = p_user_id
        UNION
        SELECT ph.included_permission_name
        FROM permission_tree pt
        JOIN permission_hierarchy ph ON ph.including_permission_name = pt.permission_name
    )
    SELECT pt.permission_name FROM permission_tree pt ORDER BY pt.permission_name;
END;
$$ LANGUAGE plpgsql STABLE SET search_path = rbac, public;

COMMENT ON FUNCTION rbac.get_user_permissions_by_id IS
'Returns all effective permissions for an already-resolved internal user id:
role grants, direct per-user grants, and their hierarchy closure (UNION already
de-duplicates, so no DISTINCT is needed per branch). A disabled or unknown id
returns no rows. Has no subject to authenticate, so it carries no guard of its
own - see the comment above this function for why that is safe.';

-- Not a request-role capability: it takes an internal id directly, with no
-- self-or-admin guard, because it has no subject of its own to check against
-- one. The explicit revoke from semantius_user is required regardless of that:
-- the ALTER DEFAULT PRIVILEGES in 0060_rbac_schema.once.sql grants EXECUTE on
-- every function created in this schema.
REVOKE EXECUTE ON FUNCTION rbac.get_user_permissions_by_id(INTEGER) FROM PUBLIC, semantius_user;

-- Get all effective permissions for a user (including implied)
CREATE OR REPLACE FUNCTION rbac.get_user_permissions(
    p_external_id TEXT
)
RETURNS TABLE (
    permission_name TEXT
) AS $$
DECLARE
    v_user_id INTEGER;
BEGIN
    -- Self-or-admin, as at rbac.get_user_by_external_id. The guard cannot
    -- recurse through the context: rbac.ensure_context_initialized builds the
    -- permission cache from rbac.get_user_permissions_by_id, which takes an
    -- internal id and carries no guard, so it never reaches the admin test that
    -- would call back into it.
    IF p_external_id IS DISTINCT FROM rbac.uid() THEN
        PERFORM rbac.require_permission('admin');
    END IF;

    -- Validate external_id
    IF p_external_id IS NULL OR trim(p_external_id) = '' THEN
        RETURN;
    END IF;

    -- No is_disabled filter here: an unknown external_id leaves v_user_id NULL,
    -- and a disabled one resolves to a real id, but rbac.get_user_permissions_by_id
    -- applies the same is_disabled = FALSE test on the id either way.
    SELECT id INTO v_user_id FROM users WHERE external_id = p_external_id;

    RETURN QUERY SELECT * FROM rbac.get_user_permissions_by_id(v_user_id);
END;
-- STABLE: reads only.
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = rbac, public;

COMMENT ON FUNCTION rbac.get_user_permissions IS
'Self-or-admin wrapper: resolves the subject external_id to its internal id and
delegates to rbac.get_user_permissions_by_id for the actual permission set,
including implied permissions. Returns no rows for an unknown or disabled
subject rather than raising, so neither case is distinguishable from the other.';

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
    -- Self-or-admin, as at rbac.get_user_by_external_id. It would be inherited
    -- from rbac.get_user_permissions above in any case; stating it here is what
    -- makes the empty-external_id rejection and the scope split unreachable for
    -- a caller asking about somebody else.
    IF p_external_id IS DISTINCT FROM rbac.uid() THEN
        PERFORM rbac.require_permission('admin');
    END IF;

    -- Validate inputs
    IF p_external_id IS NULL OR trim(p_external_id) = '' THEN
        RAISE EXCEPTION 'external_id cannot be null or empty' USING ERRCODE = '90007';
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

-- =====================================================
-- HELPER FUNCTIONS
-- =====================================================

-- Get current user's internal database Id. On an audited UPDATE it is called
-- once per row (audit.current_user_id -> user_id_or_null -> user_id), because
-- audit_i_u_d is the one row-level audit trigger; audit_i and audit_d are
-- statement-level and reach it once. public.jl_request_context reaches it twice
-- per statement. So unlike the other checkers a cold call here is not confined
-- to the first check of a transaction - on the row-level path it recurs per
-- row. The warm test is therefore inlined here
-- too, exactly as in rbac.has_permission, whose comment carries the full
-- reasoning for the ordering and for what the subject comparison does and does
-- not guarantee; this copy relies on the same invariants.
CREATE OR REPLACE FUNCTION rbac.user_id()
RETURNS INTEGER AS $$
DECLARE
    v_external_id TEXT;
BEGIN
    IF system_user LIKE 'oauth:%' THEN
        PERFORM rbac.ensure_context_initialized();
    ELSE
        v_external_id := current_setting('app.current_external_id', true);
        IF current_setting('app.context_initialized', true) IS DISTINCT FROM 'true'
           OR v_external_id IS NULL
           OR v_external_id = ''
           OR v_external_id IS DISTINCT FROM current_setting('request.jwt.claim.sub', true)
        THEN
            -- Cold: the direct call is the authentication gate 0900_test_security.sql requires
            -- of a definer the request role can execute, and what turns a
            -- session with no claims into 42501 rather than a NULL id.
            PERFORM rbac.uid();
            PERFORM rbac.ensure_context_initialized();
        END IF;
    END IF;
    RETURN current_setting('app.current_user_id', true)::INTEGER;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = rbac, public;

COMMENT ON FUNCTION rbac.user_id IS
'Returns internal user_id for current user. Warm path (an initialized context
whose cached subject matches the live JWT sub) reads app.current_user_id
straight back with no further call; a cold context is rebuilt via rbac.uid()
(the authentication gate) and rbac.ensure_context_initialized().';

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
        INSERT INTO role_permissions (role_id, permission_name)
        VALUES (v_administrator_role_id, NEW.permission_name)
        ON CONFLICT (role_id, permission_name) 
        DO UPDATE SET granted_at = CURRENT_TIMESTAMP;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SET search_path = rbac, public;

COMMENT ON FUNCTION rbac.grant_permission_to_administrator IS 
'Automatically grants newly created permissions to the Administrator role';

-- Apply trigger AFTER INSERT on permissions table
CREATE OR REPLACE TRIGGER auto_grant_permission_to_administrator
    AFTER INSERT ON permissions
    FOR EACH ROW
    EXECUTE FUNCTION rbac.grant_permission_to_administrator();

-- Revoke default PUBLIC execute on all rbac functions defined above
-- Must come AFTER all CREATE FUNCTION statements
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA rbac FROM PUBLIC;

-- The scope helpers are SECURITY INVOKER and only correct inside one of the
-- three definer checkers, where current_user is the owner. Taking EXECUTE away
-- from the request role is what stops them being called anywhere else: the
-- ALTER DEFAULT PRIVILEGES in 0060_rbac_schema.once.sql grants it to
-- semantius_user on every function
-- created in this schema, so the revoke has to be explicit.
REVOKE EXECUTE ON FUNCTION rbac.expand_scopes(TEXT) FROM semantius_user;
REVOKE EXECUTE ON FUNCTION rbac.scope_closure() FROM semantius_user;
