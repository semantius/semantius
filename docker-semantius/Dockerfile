# ---------------------------------------------------------------------------
# docker-semantius/Dockerfile — PostgreSQL 18 with the Semantius core extension
# INSTALLED and the full runtime baked in. This is the self-contained,
# publishable DB image:
#   ghcr.io/semantius/semantius-db:<version>
#
# "Self-contained" is the point: a consumer stack (e.g. ../docker-compose) needs
# to mount NOTHING — no init scripts, no pg_hba, no role bootstrap. It just
# references this image, sets a few env vars, and gets a database with:
#   * the pg_semantic_platform extension installed (roles + schemas + dictionary)
#   * semantius_authenticator flipped to LOGIN with a password from env
#   * the PostgREST `anon` role
#   * a custom pg_hba
#   * (optional) the Northwind demo module, when NWIND is set
# That makes ../docker-compose a single copy-paste docker-compose.yml (+ .env) —
# e.g. a Dokploy template — with no sidecar files.
#
# Build context is the REPO ROOT (see build.sh / the CI workflow) so this can COPY
# the generated ./extension files AND the ./apps/nwind migrations. The repo-root
# .dockerignore whitelists exactly those paths to keep the context tiny.
# Generate the extension first, from the repo root:   deno task extension 0.2.0
# ---------------------------------------------------------------------------
FROM postgres:18

# --- Extension files: staged into the cluster's extension dir so the init step
#     below can CREATE EXTENSION. The glob picks up whatever version is present,
#     so a version bump needs no edit here. ---------------------------------
COPY extension/pg_semantic_platform.control extension/pg_semantic_platform--*.sql \
     /usr/share/postgresql/18/extension/

# --- Client auth config (activated by the CMD at the bottom) ----------------
COPY docker-semantius/conf/pg_hba.conf /etc/postgresql/pg_hba.conf

# --- First-init scripts: run once, in filename order, on a fresh data dir ----
#     10 install extension → 20 authenticator LOGIN+password → 30 anon → 40 nwind
COPY docker-semantius/initdb/ /docker-entrypoint-initdb.d/
RUN chmod 0755 /docker-entrypoint-initdb.d/*.sh

# --- Optional Northwind demo module -----------------------------------------
#     MERGE the app's two migrations at BUILD time into one seed baked into the
#     image; 40-nwind.sh runs it only when NWIND is set. Neither file redeclares
#     _core (that is the extension). Append _versions guards so a later
#     `deno task migrate --apps nwind` treats the module as already deployed.
COPY apps/nwind/migrations/0010_create.sql apps/nwind/migrations/0020_load_data.sql /tmp/nwind/
RUN mkdir -p /opt/semantius \
 && cat /tmp/nwind/0010_create.sql /tmp/nwind/0020_load_data.sql > /opt/semantius/nwind.sql \
 && printf "\n-- Record migration versions so the CLI does not re-apply nwind.\nINSERT INTO public._versions (name) VALUES ('nwind.0010_create'), ('nwind.0020_load_data') ON CONFLICT (name) DO NOTHING;\n" \
      >> /opt/semantius/nwind.sql \
 && rm -rf /tmp/nwind

# Activate the baked pg_hba. The official entrypoint runs the init scripts, then
# passes these args through to the postgres server.
CMD ["postgres", "-c", "hba_file=/etc/postgresql/pg_hba.conf"]
