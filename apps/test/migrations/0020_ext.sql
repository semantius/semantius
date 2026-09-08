-- =====================================================
-- PGTAP TESTING EXTENSIONS
-- =====================================================
-- This extends pgtap with authentication simulation functions
-- to test RBAC functionality with simulated JWT claims

SET LOCAL search_path TO pgtap;

CREATE OR REPLACE FUNCTION authenticate_as (
    external_id TEXT
)
    RETURNS void
    AS $$
        DECLARE
                original_sub text;
                original_email text;
                user_email text;
                user_display_name text;
                user_first_name text;
                user_last_name text;
        BEGIN
            -- Store original JWT claims in case we need to revert
            original_sub := current_setting('request.jwt.claim.sub', true);
            original_email := current_setting('request.jwt.claim.email', true);

            -- Validate parameters
            if external_id is null OR trim(external_id) = '' then
                RAISE EXCEPTION 'external_id cannot be null or empty';
            end if;

            -- Look up the user details for this external_id
            SELECT u.email, u.display_name, u.first_name, u.last_name
            INTO user_email, user_display_name, user_first_name, user_last_name
            FROM users u WHERE u.external_id = authenticate_as.external_id;
            
            if user_email is null then
                RAISE EXCEPTION 'User with external_id "%" not found', external_id;
            end if;

            -- Set the role to authenticated
            SET ROLE semantius_user;
            perform set_config('role', 'semantius_user', true);
            
            -- Ensure pgtap schema is in search path for testing functions
            perform set_config('search_path', 'pgtap, public', true);
            
            -- Set JWT claims in the format expected by rbac functions
            perform set_config('request.jwt.claim.sub', external_id, true);
            perform set_config('request.jwt.claim.email', user_email, true);
            perform set_config('request.jwt.claim.name', COALESCE(user_display_name, ''), true);
            perform set_config('request.jwt.claim.given_name', COALESCE(user_first_name, ''), true);
            perform set_config('request.jwt.claim.family_name', COALESCE(user_last_name, ''), true);
            perform set_config('request.jwt.claim.role', 'authenticated', true);
            perform set_config('request.jwt.claim.aud', '', true);

            -- Clear all app context variables set by ensure_context_initialized
            PERFORM set_config('app.current_user_id', NULL, false);
            PERFORM set_config('app.current_external_id', NULL, false);
            PERFORM set_config('app.user_permissions', NULL, false);
            PERFORM set_config('app.context_initialized', NULL, false);
            PERFORM set_config('app.oauth_scopes', NULL, false);

        EXCEPTION
            -- revert back to original auth data
            WHEN OTHERS THEN
                set local role semantius_user;
                if original_sub is not null then
                    set local "request.jwt.claim.sub" to original_sub;
                end if;
                if original_email is not null then
                    set local "request.jwt.claim.email" to original_email;
                end if;
                RAISE;
        END
    $$ LANGUAGE plpgsql;

-- Helper: extract the key_id from a full API key string (everything before the last '-')
CREATE OR REPLACE FUNCTION extract_api_key_id(full_key TEXT)
RETURNS TEXT AS $$
BEGIN
    RETURN substring(full_key FROM 1 FOR length(full_key) - position('-' IN reverse(full_key)));
END;
$$ LANGUAGE plpgsql;

-- Helper: run a statement and return the four error fields PostgREST puts on
-- the wire, so a test can assert the whole shape of an error and not only its
-- SQLSTATE and message, which is all pgTAP's throws_ok compares. Returns JSON
-- null when the statement does not raise. The handler rolls the statement's
-- subtransaction back, so nothing it wrote survives the call.
CREATE OR REPLACE FUNCTION catch_error(p_sql TEXT)
RETURNS JSONB AS $$
DECLARE
    v_state TEXT;
    v_message TEXT;
    v_detail TEXT;
    v_hint TEXT;
BEGIN
    EXECUTE p_sql;
    RETURN 'null'::jsonb;
EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS
        v_state   = RETURNED_SQLSTATE,
        v_message = MESSAGE_TEXT,
        v_detail  = PG_EXCEPTION_DETAIL,
        v_hint    = PG_EXCEPTION_HINT;
    RETURN jsonb_build_object(
        'code',    v_state,
        'message', v_message,
        'details', v_detail,
        'hint',    v_hint);
END;
$$ LANGUAGE plpgsql;

-- Helper: the hint of a raised error, parsed as the JSON object the error
-- contract puts there. JSON null when the statement did not raise, and the
-- string itself wrapped under "hint" when it is not an object - the same
-- reading a client does.
CREATE OR REPLACE FUNCTION catch_error_hint(p_sql TEXT)
RETURNS JSONB AS $$
DECLARE
    v_err JSONB;
    v_hint TEXT;
    v_obj JSONB;
BEGIN
    v_err := catch_error(p_sql);
    IF v_err = 'null'::jsonb THEN
        RETURN 'null'::jsonb;
    END IF;
    v_hint := v_err ->> 'hint';
    IF v_hint IS NULL OR v_hint = '' THEN
        RETURN '{}'::jsonb;
    END IF;
    BEGIN
        v_obj := v_hint::jsonb;
    EXCEPTION WHEN OTHERS THEN
        v_obj := NULL;
    END;
    IF v_obj IS NULL OR jsonb_typeof(v_obj) <> 'object' THEN
        RETURN jsonb_build_object('hint', v_hint);
    END IF;
    RETURN v_obj;
END;
$$ LANGUAGE plpgsql;
