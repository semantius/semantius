-- =====================================================
-- PGTAP TESTING EXTENSIONS
-- =====================================================
-- This extends pgtap with authentication simulation functions
-- to test RBAC functionality with simulated JWT claims

SET LOCAL search_path TO pgtap;

CREATE OR REPLACE FUNCTION authenticate_as (
    external_id TEXT,
    email TEXT
)
    RETURNS void
    AS $$
        DECLARE
                original_sub text;
                original_email text;
        BEGIN
            -- Store original JWT claims in case we need to revert
            original_sub := current_setting('request.jwt.claim.sub', true);
            original_email := current_setting('request.jwt.claim.email', true);

            -- Validate parameters
            if external_id is null OR trim(external_id) = '' then
                RAISE EXCEPTION 'external_id cannot be null or empty';
            end if;

            -- Set the role to authenticated
            SET ROLE semantius_user;
            perform set_config('role', 'semantius_user', true);
            
            -- Ensure pgtap schema is in search path for testing functions
            perform set_config('search_path', 'pgtap, public', true);
            
            -- Set JWT claims in the format expected by rbac functions
            perform set_config('request.jwt.claim.sub', external_id, true);
            perform set_config('request.jwt.claim.email', email, true);

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