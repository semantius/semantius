-- =====================================================
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
-- Returns the full API key (only time the secret is visible in plaintext).
-- Accessible via PostgREST RPC by all authenticated users.

CREATE OR REPLACE FUNCTION public.generate_api_key(p_user_id INTEGER)
RETURNS TEXT AS $$
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

            -- Attempt to insert with hashed secret
            INSERT INTO _apikeys (user_id, key_id, secret_hash)
            VALUES (v_target_user_id, v_new_key_id, crypt(v_new_secret, gen_salt('bf', 10)));

            -- If we reach here, insert was successful
            v_full_api_key := v_new_key_id || '-' || v_new_secret;
            v_done := TRUE;

        EXCEPTION WHEN unique_violation THEN
            -- If key_id already exists, loop again to generate a new one
            NULL;
        END;
    END LOOP;

    RETURN v_full_api_key;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION public.generate_api_key IS
'Generates a new API key. Pass 0 to generate for current user (uk- prefix), or a user id for admin-generated keys (sk- prefix). Returns the full key only once.';

-- Grant execute to semantius_user (accessible via PostgREST RPC)
REVOKE EXECUTE ON FUNCTION public.generate_api_key(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.generate_api_key(INTEGER) TO semantius_user;

-- =====================================================
-- VALIDATE API KEY FUNCTION (INTERNAL ONLY)
-- =====================================================
-- Validates an API key by splitting it into key_id and secret,
-- looking up the record, and verifying the bcrypt hash.
-- Returns the user_id if valid, NULL if invalid.
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
        RETURN v_record.user_id;
    ELSE
        RETURN NULL;
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION public.validate_api_key IS
'Validates an API key and returns the user_id if valid, NULL otherwise. Called by semantius_user for API key authentication.';

-- Grant to semantius_user so it can be used for API key auth flows
GRANT EXECUTE ON FUNCTION public.validate_api_key(TEXT) TO semantius_user;
