-- =============================================================================
-- 10-install-extension.sql  -  install the Semantius core extension
-- =============================================================================
-- Baked into the semantius-db image and run once, at first container init, over
-- the local socket as `postgres` (superuser), against POSTGRES_DB. This is what
-- makes the image's "extension baked in" promise real: the .control + versioned
-- SQL are staged into the cluster's extension dir by the Dockerfile, and this
-- installs them into the freshly-created database.
--
-- CASCADE auto-installs the required extensions (pgcrypto, per the .control
-- `requires`). The extension's own script creates the semantius_user /
-- authenticated / semantius_authenticator roles (all NOLOGIN) and the
-- common/rbac/audit/pgmq schemas plus the data-dictionary tables.
--
-- The later init scripts build the runtime layer ON TOP of this: 20 flips
-- semantius_authenticator to LOGIN, 30 adds the PostgREST `anon` role, 40
-- optionally loads the Northwind demo module.
-- -----------------------------------------------------------------------------

CREATE EXTENSION IF NOT EXISTS pg_semantius CASCADE;
