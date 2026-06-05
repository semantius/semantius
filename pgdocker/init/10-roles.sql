-- =============================================================================
-- 10-roles.sql  -  runtime role that OAuth bearer tokens map to
-- =============================================================================
-- Runs once, at first container init, over the local socket as `postgres`.
--
-- `authenticated` is the SAME role name Supabase and Neon use for authenticated
-- end-user requests, so the Semantius core RLS/RBAC layer (which checks the JWT
-- `role` claim == 'authenticated') works unchanged.
--
-- KEY DIFFERENCE vs the PostgREST model: with Supabase/Neon, PostgREST logs in
-- as `authenticator` and SET ROLEs into a NOLOGIN `authenticated`. Here clients
-- connect DIRECTLY via PostgreSQL-native OAuth and authenticate AS
-- `authenticated`, so the role MUST be able to LOG IN.
--
-- We only need the role to EXIST (with LOGIN) before the Semantius migrations
-- run. Those migrations create `semantius_user` and GRANT it the table/schema
-- privileges, then GRANT semantius_user -> authenticated, so `authenticated`
-- inherits its runtime rights from there. Nothing else to grant here.
-- -----------------------------------------------------------------------------

DO $$
BEGIN
    IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'authenticated') THEN
        -- Core migrations create it NOLOGIN; direct OAuth needs LOGIN.
        ALTER ROLE authenticated WITH LOGIN;
    ELSE
        CREATE ROLE authenticated WITH LOGIN;
    END IF;

    -- Allow the role to connect to this database (PUBLIC has CONNECT by
    -- default, but be explicit in case that default is revoked later).
    EXECUTE format('GRANT CONNECT ON DATABASE %I TO authenticated', current_database());
END
$$;
