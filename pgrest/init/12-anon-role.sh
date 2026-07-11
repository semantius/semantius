#!/bin/bash
# =============================================================================
# 12-anon-role.sh  -  the PostgREST anonymous role (OpenAPI visibility)
# =============================================================================
# Runs once at first init, AFTER 11-session-role.sh, BEFORE 20-extension.sql.
#
# `anon` is PostgREST's `db-anon-role`: the role it SET ROLEs into for requests
# with NO (or an invalid) bearer token. Its only job in this stack is to let the
# token-less OpenAPI (Swagger) request at `/` succeed so the docs site can load
# the spec. Combined with PGRST_OPENAPI_MODE=ignore-privileges, PostgREST emits
# the FULL spec regardless of anon's privileges — so anon needs NO table grants.
#
# LOCKED DOWN: anon gets schema USAGE only, never SELECT/INSERT/... on any table.
# A token-less data request therefore fails at the GRANT level (permission
# denied) — before RLS is even consulted — so no data is exposed even by a table
# that forgot its RLS policy. (Authenticated requests go via `authenticated`,
# which holds the data privileges through its membership in `semantius_user`.)
# -----------------------------------------------------------------------------
set -euo pipefail

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<'EOSQL'
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
    -- its membership in `authenticated`. semantius_authenticator is created here
    -- by 11-session-role.sh (and re-asserted by the extension's migrations).
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'semantius_authenticator') THEN
        GRANT anon TO semantius_authenticator WITH INHERIT FALSE, SET TRUE;
    END IF;
END
$$;
EOSQL

echo "12-anon-role.sh: anon role ready; semantius_authenticator may SET ROLE anon."
