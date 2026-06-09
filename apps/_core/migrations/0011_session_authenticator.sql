-- =====================================================================================
-- 0011_session_authenticator.sql  -  session-mode login role (Supabase/Neon pattern)
-- =====================================================================================
-- Creates `semantius_authenticator`, the restricted login role the SESSION auth
-- mode connects as. Created HERE, in the core migrations, so EVERY deployment —
-- local pgdocker, Neon, Supabase — gets the SAME role automatically when the
-- schema is deployed (it is not a local-only artifact).
--
-- Two auth modes share this database:
--   * bearer  — clients connect via PostgreSQL-native OAuth AS `authenticated`
--               (PG18 OAUTHBEARER; pg_oidc_validator verifies the RS256 token
--               in-DB and PostgreSQL pins the identity via system_user).
--   * session — the app (having already verified the JWT) connects as THIS role
--               over SCRAM, then per transaction:
--                   SET LOCAL ROLE authenticated;
--                   SELECT set_config('request.jwt.claims', $1, true);
--               i.e. it SET ROLEs into `authenticated`, exactly like Supabase's
--               `authenticator -> authenticated`.
--
-- Security floor (the entire point of this role):
--   NOSUPERUSER  -> cannot bypass anything.
--   NOINHERIT    -> holds NONE of authenticated's privileges passively; it can do
--                   nothing but `SET ROLE authenticated`. A NOINHERIT gatekeeper
--                   that ENFORCES RLS by SET ROLE-ing into an RLS-subject role —
--                   it never bypasses RLS. This is what makes it safe to expose
--                   with a password.
--   NOBYPASSRLS  -> the default; never granted. The only RLS-bypass risk on a
--                   managed platform is connecting as the `postgres`/owner role
--                   instead of this one.
--
-- LOGIN + password are deliberately NOT set here (never commit a password). They
-- are set per-environment by a step we own:
--   * local pgdocker: init/11-session-role.sh (reads $SEMANTIUS_AUTHENTICATOR_PASSWORD)
--   * managed:        deno task setup-session-role (ALTER ... LOGIN PASSWORD over
--                     the owner connection)
-- This mirrors exactly how `authenticated` is created NOLOGIN in 0010 and flipped
-- to LOGIN by pgdocker init/10-roles.sql.
--
-- Idempotent + NON-DESTRUCTIVE OF LOGIN: if the role already exists (e.g. the
-- local init script created it LOGIN before the migrations ran) this does NOT
-- strip LOGIN or touch its attributes — it only (re-)asserts the membership grant.
-- -------------------------------------------------------------------------------------

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'semantius_authenticator') THEN
        -- NOLOGIN here; the per-environment step flips LOGIN and sets the password.
        CREATE ROLE semantius_authenticator NOLOGIN NOSUPERUSER NOINHERIT;
        RAISE NOTICE 'Role semantius_authenticator created (NOLOGIN NOSUPERUSER NOINHERIT)';
    END IF;

    -- Membership in `authenticated` so the role can `SET ROLE authenticated`.
    --   INHERIT FALSE -> never gains authenticated's privileges passively, even if
    --                    the role is later (mistakenly) ALTERed to INHERIT.
    --   SET TRUE      -> may `SET ROLE authenticated` (the only thing it can do).
    -- Idempotent: re-running just re-asserts the same membership options.
    GRANT authenticated TO semantius_authenticator WITH INHERIT FALSE, SET TRUE;
END
$$;

COMMENT ON ROLE semantius_authenticator IS
'Session-mode login role (Supabase/Neon authenticator pattern). NOSUPERUSER NOINHERIT NOBYPASSRLS; can do nothing but SET ROLE authenticated. LOGIN + password are set per-environment, never in committed SQL.';
