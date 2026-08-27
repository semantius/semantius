#!/bin/bash
# =============================================================================
# 20-authenticator-login.sh  -  give semantius_authenticator a LOGIN + password
# =============================================================================
# Baked into the semantius/postgres image. Runs once, at first container init, over the
# local socket as `postgres`, AFTER 10-install-extension.sql (so the extension has
# already created semantius_authenticator NOLOGIN with its `authenticated`
# membership).
#
# This is the ONE genuinely-shell init step: it injects a PER-ENVIRONMENT SECRET
# (the password) from an env var. Versioned SQL / the extension can't and must
# never carry a password — that is why this is a .sh (shell init scripts get
# env-var interpolation; .sql ones do NOT) and why LOGIN/password live in the
# deployment layer, not in the extension.
#
# semantius_authenticator is the SESSION-mode login role (the Supabase/Neon
# "authenticator" pattern). The extension creates it NOLOGIN NOSUPERUSER
# NOINHERIT and GRANTs it `authenticated`; here we flip it to LOGIN and set its
# password. PostgREST connects as this role and, per request, SET ROLEs into
# `authenticated` or `anon` — it is NOINHERIT, so without that SET ROLE it can do
# nothing.
#
# Password: $SEMANTIUS_AUTHENTICATOR_PASSWORD (passed in via the compose
# environment: block). Falls back to a dev default so a bare `docker run` still
# works out of the box.
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
    -- The extension creates these first; be defensive in case it is ever absent
    -- (e.g. a non-extension provisioning path reuses this script).
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
        CREATE ROLE authenticated NOLOGIN;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'semantius_authenticator') THEN
        CREATE ROLE semantius_authenticator LOGIN NOSUPERUSER NOINHERIT;
        RAISE NOTICE 'Role semantius_authenticator created (LOGIN NOSUPERUSER NOINHERIT)';
    ELSE
        -- Created NOLOGIN by the extension; session mode needs LOGIN.
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

echo "20-authenticator-login.sh: semantius_authenticator is LOGIN with a password (session mode ready)."
