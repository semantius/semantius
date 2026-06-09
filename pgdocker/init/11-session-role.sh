#!/bin/bash
# =============================================================================
# 11-session-role.sh  -  give semantius_authenticator a LOGIN + password (local)
# =============================================================================
# Runs once, at first container init, over the local socket as `postgres`.
# SHELL (.sh) init scripts get env-var interpolation; .sql ones do NOT — so this
# is where the per-environment password is read. Runs AFTER 10-roles.sql (so
# `authenticated` already exists) and, on the ext stack, BEFORE 20-extension.sql
# (so the role is LOGIN before the extension's migrations run).
#
# semantius_authenticator is the SESSION-mode login role (the Supabase/Neon
# "authenticator" pattern). The core migrations (apps/_core/migrations/0011)
# create it NOLOGIN NOSUPERUSER NOINHERIT and GRANT it `authenticated`; here we
# flip it to LOGIN and set its password — exactly how 10-roles.sql flips
# `authenticated` to LOGIN. We also create it up-front (idempotently) so it can
# SCRAM-connect even before _core is deployed (the CLI stack deploys _core in a
# separate, later step).
#
# The app connects as this role and, per transaction, does:
#   SET LOCAL ROLE authenticated;
#   SELECT set_config('request.jwt.claims', $1, true);
# It is NOINHERIT, so without that SET ROLE it can do nothing.
#
# Password: $SEMANTIUS_AUTHENTICATOR_PASSWORD (passed in via the compose
# environment: block, sourced from pgdocker/.env). Falls back to a dev default so
# a bare `docker compose up` still works out of the box.
#   !!! DEV DEFAULT — set a real, unique value for anything shared or exposed. !!!
# -----------------------------------------------------------------------------
set -euo pipefail

PW="${SEMANTIUS_AUTHENTICATOR_PASSWORD:-devpassword}"

psql -v ON_ERROR_STOP=1 \
     --username "$POSTGRES_USER" \
     --dbname "$POSTGRES_DB" \
     --set=pw="$PW" <<'EOSQL'
DO $$
BEGIN
    -- authenticated is normally created by 10-roles.sql first; be defensive in
    -- case the run order ever changes (the GRANT below needs it to exist).
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
        CREATE ROLE authenticated NOLOGIN;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'semantius_authenticator') THEN
        CREATE ROLE semantius_authenticator LOGIN NOSUPERUSER NOINHERIT;
        RAISE NOTICE 'Role semantius_authenticator created (LOGIN NOSUPERUSER NOINHERIT)';
    ELSE
        -- Created NOLOGIN by the core migrations; session mode needs LOGIN.
        -- NOSUPERUSER/NOINHERIT re-asserted (cheap, and they are already so).
        ALTER ROLE semantius_authenticator LOGIN NOSUPERUSER NOINHERIT;
    END IF;

    -- Can SET ROLE authenticated, but never inherits its privileges passively.
    GRANT authenticated TO semantius_authenticator WITH INHERIT FALSE, SET TRUE;
END
$$;

-- Set the password. :'pw' is psql's safe-quoting form (the password is escaped
-- as a SQL string literal), so a password with quotes/specials is handled
-- correctly. PostgreSQL stores it as a SCRAM-SHA-256 verifier by default.
ALTER ROLE semantius_authenticator PASSWORD :'pw';
EOSQL

echo "11-session-role.sh: semantius_authenticator is LOGIN with a password (session mode ready)."
