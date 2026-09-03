-- =============================================================================
-- 10-install-extension.sql  -  install the Semantius core extension
-- =============================================================================
-- Baked into the semantius/postgres image and run once, at first container init, over
-- the local socket as `postgres` (superuser), against POSTGRES_DB. This is what
-- makes the image's "extension baked in" promise real: the .control + versioned
-- SQL are staged into the cluster's extension dir by the Dockerfile, and this
-- installs them into the freshly-created database.
--
-- Two statements, and NO CASCADE. `CREATE EXTENSION` creates only the four
-- cluster roles (semantius_owner / semantius_user / authenticated /
-- semantius_authenticator, all NOLOGIN), the `semantius` schema and its
-- functions; `semantius.migrate()` then installs the common/rbac/audit/pgmq
-- schemas and the data dictionary as ORDINARY objects, so they survive
-- pg_dump/pg_restore and DROP EXTENSION. pgcrypto is created by migrate(),
-- in `public`, where 0110's unqualified calls need it.
--
-- The later init scripts build the runtime layer ON TOP of this: 20 flips
-- semantius_authenticator to LOGIN, 30 adds the PostgREST `anon` role, 40
-- optionally loads the Northwind demo module.
-- -----------------------------------------------------------------------------

CREATE EXTENSION IF NOT EXISTS pg_semantius;
SELECT semantius.migrate();
