-- =============================================================================
-- 20-extension.sql  -  install the Semantius core extension (EXTENSION variant)
-- =============================================================================
-- Mounted only by docker-compose.ext.yml. Runs once, at first container init,
-- over the local socket as `postgres` (superuser), against POSTGRES_DB, AFTER
-- 10-roles.sql (so the `authenticated` role already exists).
--
-- The extension files (pg_semantius.control + pg_semantius--<version>.sql) are baked
-- into this image by Dockerfile.ext from the repo-root ./extension folder.
-- Regenerate them with `deno task extension` before rebuilding the image.
--
-- Two statements, and NO CASCADE. The extension itself only creates the four
-- cluster roles, the `semantius` schema and its functions; `semantius.migrate()`
-- then creates the common/rbac/audit/pgmq schemas, the dictionary tables and
-- the seed rows as ORDINARY objects, so they are not extension members and
-- survive both pg_dump/pg_restore and DROP EXTENSION.
--
-- CASCADE is deliberately absent: it would install pgcrypto into the caller's
-- default creation schema, while migrate() creates it in `public`, which is
-- where 0110's unqualified gen_random_bytes/crypt/gen_salt calls need it.
-- -----------------------------------------------------------------------------

CREATE EXTENSION IF NOT EXISTS pg_semantius;
SELECT semantius.migrate();
