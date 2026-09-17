# ---------------------------------------------------------------------------
# docker-postgres/Dockerfile — PostgreSQL 18 with the Semantius core extension
# INSTALLED and the full runtime baked in. This is the self-contained,
# publishable DB image:
#   ghcr.io/semantius/postgres:<version>
#
# "Self-contained" is the point: a consumer stack (e.g. semantius-self-hosted)
# needs to mount NOTHING — no init scripts, no pg_hba, no role bootstrap. It just
# references this image, sets a few env vars, and gets a database with:
#   * the pg_semantius extension installed (roles + schemas + dictionary)
#   * semantius_authenticator flipped to LOGIN with a password from env
#   * the PostgREST `anon` role
#   * a custom pg_hba
#   * (optional) the Northwind demo module, when NWIND is set
# That makes the consumer stack a single copy-paste docker-compose.yml (+ .env) —
# e.g. a Dokploy template — with no sidecar files.
#
# Build context is the REPO ROOT (see build.sh / the CI workflow) so this can COPY
# the generated ./extension files AND the ./apps/nwind migrations. The repo-root
# .dockerignore whitelists exactly those paths to keep the context tiny.
# Generate the extension first, from the repo root:   deno task extension 0.3.0
# ---------------------------------------------------------------------------
FROM postgres:18

# --- Extension files: staged into the cluster's extension dir so the init step
#     below can CREATE EXTENSION. The glob picks up whatever version is present,
#     so a version bump needs no edit here. ---------------------------------
COPY extension/pg_semantius.control extension/pg_semantius--*.sql \
     /usr/share/postgresql/18/extension/

# --- Client auth config (activated by the CMD at the bottom) ----------------
COPY docker-postgres/conf/pg_hba.conf /etc/postgresql/pg_hba.conf

# --- First-init scripts: run once, in filename order, on a fresh data dir ----
#     10 install extension → 20 authenticator LOGIN+password → 30 anon → 40 nwind
COPY docker-postgres/initdb/ /docker-entrypoint-initdb.d/
RUN chmod 0755 /docker-entrypoint-initdb.d/*.sh

# --- Optional Northwind demo module -----------------------------------------
#     The migrations are copied in UNMERGED and UNMODIFIED, and 40-nwind.sh
#     applies them the way the CLI does - one transaction per file, each file
#     recorded in _versions with its checksum in that same transaction - but
#     only when NWIND is set. Neither file redeclares _core (that is the
#     extension).
#
#     The whole directory, not a list of filenames: the previous build named
#     0010 and 0020 in four places (this COPY, a cat, a hand-written _versions
#     INSERT and build.sh's preflight), so adding a third migration to
#     apps/nwind/migrations shipped an image that was silently missing it while
#     claiming the module was fully deployed. A directory copy cannot drift.
COPY apps/nwind/migrations/ /opt/semantius/nwind-migrations/

# Activate the baked pg_hba. The official entrypoint runs the init scripts, then
# passes these args through to the postgres server.
CMD ["postgres", "-c", "hba_file=/etc/postgresql/pg_hba.conf"]
