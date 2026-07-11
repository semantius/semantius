# ---------------------------------------------------------------------------
# pgrest/Dockerfile — PostgreSQL 18 with the Semantius core extension baked in,
# for the PostgREST stack. NO pg_oidc_validator, NO PostgreSQL-native OAuth:
# authentication is done by PostgREST IN FRONT of the database, which connects
# over SCRAM as `semantius_authenticator` and SET ROLEs per request.
#
# Unlike pgdocker/Dockerfile.ext (which layers on the compiled-OAuth base image
# postgres18-cli:local), this goes straight from stock postgres:18 — no validator,
# no libpq-oauth, no patches.
#
# Build context is the REPO ROOT (see docker-compose.yml: build.context: ..) so
# this can COPY the generated ./extension files into PostgreSQL's extension dir.
# The repo-root .dockerignore (`*` then `!extension`) keeps the context tiny.
# Generate the files first, from the repo root:   deno task extension
# init-ext/20-extension.sql then runs CREATE EXTENSION at first container init.
# ---------------------------------------------------------------------------
FROM postgres:18

# The .control + versioned SQL must live in the cluster's extension directory so
# CREATE EXTENSION can find them. The official postgres image builds as root, so
# no USER dance is needed (contrast Dockerfile.ext, whose base left USER postgres).
# The glob picks up whatever version is present, so a version bump needs no edit.
COPY extension/pg_semantic_platform.control extension/pg_semantic_platform--*.sql \
     /usr/share/postgresql/18/extension/
