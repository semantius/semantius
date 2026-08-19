-- =============================================================================
-- 30-postgrest-anon.sql  -  the PostgREST anonymous role (OpenAPI visibility)
-- =============================================================================
-- Baked into the semantius-db image. Runs once at first init, AFTER
-- 20-authenticator-login.sh (so semantius_authenticator exists and is LOGIN).
--
-- Pure SQL — no env var, so it is a .sql, not a .sh. `anon` is a PURELY PostgREST
-- concept (it appears nowhere in the extension); it is the role PostgREST SET
-- ROLEs into for requests with NO (or an invalid) bearer token. Its only job is
-- to let the token-less OpenAPI (Swagger) request at `/` succeed so a docs site
-- can load the spec. Combined with PGRST_OPENAPI_MODE=ignore-privileges,
-- PostgREST emits the FULL spec regardless of anon's privileges — so anon needs
-- NO table grants.
--
-- LOCKED DOWN: anon gets schema USAGE only, never SELECT/INSERT/... on any table.
-- A token-less data request therefore fails at the GRANT level (permission
-- denied) — before RLS is even consulted — so no data is exposed even by a table
-- that forgot its RLS policy. (Authenticated requests go via `authenticated`,
-- which holds the data privileges through its membership in `semantius_user`.)
-- -----------------------------------------------------------------------------

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
        CREATE ROLE anon NOLOGIN NOSUPERUSER NOINHERIT;
        RAISE NOTICE 'Role anon created (NOLOGIN NOSUPERUSER NOINHERIT)';
    END IF;

    -- Structure visibility for the OpenAPI request; NOT data access.
    GRANT USAGE ON SCHEMA public TO anon;

    -- PostgREST logs in as semantius_authenticator and must be able to SET ROLE
    -- anon for unauthenticated requests. SET TRUE, INHERIT FALSE — same shape as
    -- its membership in `authenticated`.
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'semantius_authenticator') THEN
        GRANT anon TO semantius_authenticator WITH INHERIT FALSE, SET TRUE;
    END IF;
END
$$;
