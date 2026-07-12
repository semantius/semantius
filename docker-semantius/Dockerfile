# ---------------------------------------------------------------------------
# docker-semantius/Dockerfile — PostgreSQL 18 with the Semantius core extension
# baked in. This is the reusable, publishable DB image:
#   ghcr.io/adenin-platform/semantius-db:<version>
#
# It is deliberately runtime-agnostic — NO PostgREST, NO OAuth validator, NO role
# bootstrap or pg_hba here. A consumer stack (e.g. ../pgrest) supplies roles,
# pg_hba, and the front-end. That keeps this image a pure "Postgres + extension"
# artifact that any stack — or a Dokploy template — can pull and build on.
#
# Build context is the REPO ROOT (see build.sh / docker-compose.yml) so this can
# COPY the generated ./extension files into PostgreSQL's extension dir. The repo
# -root .dockerignore (`*` then `!extension`) keeps the context tiny.
# Generate the files first, from the repo root:   deno task extension
# ---------------------------------------------------------------------------
FROM postgres:18

# The .control + versioned SQL must live in the cluster's extension directory so
# CREATE EXTENSION can find them. The official postgres image builds as root, so
# no USER dance is needed. The glob picks up whatever version is present, so a
# version bump needs no edit here.
COPY extension/pg_semantic_platform.control extension/pg_semantic_platform--*.sql \
     /usr/share/postgresql/18/extension/
