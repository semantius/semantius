-- =============================================================================
-- 20-extension.sql  -  install the Semantius core extension (EXTENSION variant)
-- =============================================================================
-- Mounted only by docker-compose.ext.yml. Runs once, at first container init,
-- over the local socket as `postgres` (superuser), against POSTGRES_DB, AFTER
-- 10-roles.sql (so the `authenticated` role already exists).
--
-- The extension files (semantius.control + semantius--<version>.sql) are baked
-- into this image by Dockerfile.ext from the repo-root ./extension folder.
-- Regenerate them with `deno task extension` before rebuilding the image.
--
-- CASCADE auto-installs the required extensions (pgcrypto). The extension's own
-- script creates the `semantius_user` role and the common/rbac/audit/pgmq
-- schemas plus the data-dictionary tables - i.e. it replaces the CLI migrate
-- step for this variant.
-- -----------------------------------------------------------------------------

CREATE EXTENSION IF NOT EXISTS semantius CASCADE;
