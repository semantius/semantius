-- =====================================================
-- SCHEMA-WIDE GRANTS FOR semantius_user
-- =====================================================
-- Runs once. ON ALL TABLES / ON ALL SEQUENCES grant what exists at this point
-- of a fresh install - the RBAC tables, _settings and _versions. Tables created
-- later get their grants from the dictionary or their own migration; a second
-- run would hand semantius_user every table created in between.

-- =====================================================
-- GRANT TABLE ACCESS TO semantius_user ROLE
-- =====================================================
-- Grant usage on public schema
GRANT USAGE ON SCHEMA public TO semantius_user;

-- Grant table permissions (RLS policies will further restrict access)
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO semantius_user;

-- Grant sequence usage for auto-increment columns
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO semantius_user;

-- Earlier releases did carry a default privilege here, and `deno task dropall`
-- does not remove one: pg_default_acl is database state, not schema state, so a
-- database that ever ran that release keeps handing the request role every new
-- table in public until it is taken back explicitly. These two revokes do that.
-- They bind to the installing role, which is the grantor of the rows they undo;
-- 9900_owner_hardening.sql takes back the semantius_owner pair. On a database that never had them
-- both are no-ops and leave no row behind.
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    REVOKE SELECT, INSERT, UPDATE, DELETE ON TABLES FROM semantius_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    REVOKE USAGE, SELECT ON SEQUENCES FROM semantius_user;
