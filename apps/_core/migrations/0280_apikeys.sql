-- =====================================================
-- API KEY FUNCTIONS
-- =====================================================
-- Repeatable. The _apikeys table is in 0270_apikeys.once.sql.

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

-- p_user_id follows users.id (BIGINT). An INTEGER version left behind by an
-- older build is a separate overload with grants of its own, so it is dropped.
DROP FUNCTION IF EXISTS public.generate_api_key(INTEGER, TEXT);

CREATE OR REPLACE FUNCTION public.generate_api_key(p_user_id BIGINT, p_description TEXT DEFAULT '')
RETURNS JSONB AS $$
DECLARE
    v_target_user_id BIGINT;
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
            RAISE EXCEPTION 'User with id ${user_id} does not exist'
                USING ERRCODE = '90401',
                      HINT = jsonb_build_object('user_id', p_user_id)::text;
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
REVOKE EXECUTE ON FUNCTION public.generate_api_key(BIGINT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.generate_api_key(BIGINT, TEXT) TO semantius_user;

-- =====================================================
-- VALIDATE API KEY FUNCTION (INTERNAL ONLY)
-- =====================================================
-- Validates an API key by splitting it into key_id and secret,
-- looking up the record, and verifying the bcrypt hash.
-- Returns the user_id if valid, NULL if invalid.
-- Updates last_used_at on successful validation.
-- NOT accessible via PostgREST (no GRANT to semantius_user).

-- CREATE OR REPLACE cannot change a return type, so a copy that still returns
-- the INTEGER of the int4 user keys is dropped first; the catalog test keeps a
-- re-run from dropping the current version.
DO $$
BEGIN
    IF (SELECT prorettype FROM pg_catalog.pg_proc
         WHERE oid = pg_catalog.to_regprocedure('public.validate_api_key(text)')) = 'pg_catalog.int4'::regtype THEN
        DROP FUNCTION public.validate_api_key(TEXT);
    END IF;
END $$;

CREATE OR REPLACE FUNCTION public.validate_api_key(p_api_key TEXT)
RETURNS BIGINT AS $$
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
'Validates an API key and returns the user_id if valid, NULL otherwise. Updates last_used_at on successful validation. Internal authentication primitive: reachable only from code that already runs as the owner, never by the request role.';

-- Reachable from the auth tier over a direct owner connection, and from nothing
-- else. That is the only caller shape that can work: the API-key exchange
-- continues by reading `users` with no JWT context, which needs the RLS bypass
-- an owner has and a request role never does.
--
-- It is the primitive that establishes an identity, so it cannot carry an
-- rbac.uid() check the way every other definer in this schema does, and a grant
-- to the request role would therefore be a grant with nothing behind it: an
-- unauthenticated bcrypt call at cost 10 per request, and a timing oracle,
-- because the key_id lookup returns before crypt() and so rejects an unknown key
-- id measurably faster than a wrong secret for a known one. The API-key tests
-- reach it with RESET ROLE for the same reason. If a new entry point needs it,
-- that entry point is a SECURITY DEFINER function, not a grant.
REVOKE EXECUTE ON FUNCTION public.validate_api_key(TEXT) FROM semantius_user;
REVOKE EXECUTE ON FUNCTION public.validate_api_key(TEXT) FROM PUBLIC;

-- =====================================================
-- LIST API KEYS FUNCTION
-- =====================================================
-- Returns a JSON array of API keys for the current user or a specific user.
-- Each entry contains key_id, description, last_used_at, and created_at.
-- The secret hash is never returned.
-- When p_user_id = 0, returns keys for the current session user.
-- When p_user_id <> 0, requires admin permission.
-- Accessible via PostgREST RPC by all authenticated users.

-- p_user_id follows users.id (BIGINT); see generate_api_key for the drop.
DROP FUNCTION IF EXISTS public.list_api_keys(INTEGER);

CREATE OR REPLACE FUNCTION public.list_api_keys(p_user_id BIGINT DEFAULT 0)
RETURNS JSONB AS $$
DECLARE
    v_target_user_id BIGINT;
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
            RAISE EXCEPTION 'User with id ${user_id} does not exist'
                USING ERRCODE = '90401',
                      HINT = jsonb_build_object('user_id', p_user_id)::text;
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
-- STABLE: writes nothing, so PostgREST serves it over GET.
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION public.list_api_keys IS
'Returns a JSON array of API keys for the current user (p_user_id=0) or a specific user (admin only). Does not include the secret hash.';

-- Grant execute to semantius_user (accessible via PostgREST RPC)
REVOKE EXECUTE ON FUNCTION public.list_api_keys(BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_api_keys(BIGINT) TO semantius_user;

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
    v_current_user_id BIGINT;
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
            USING ERRCODE = '90402';
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

-- An API key's id is set once, like every other auto_increment key; see the
-- pk_immutable triggers in 0070_rbac_schema.sql. _apikeys has no entities row,
-- so the dictionary does not install it.
CREATE OR REPLACE TRIGGER pk_immutable
    BEFORE UPDATE OF id ON _apikeys
    FOR EACH ROW EXECUTE FUNCTION common.reject_pk_change('id');
