FROM postgres:18

# ---------------------------------------------------------------------------
# PostgreSQL 18 ships native OAuth (SASL OAUTHBEARER) but NO built-in token
# validator. We compile Percona's pg_oidc_validator, which verifies a JWT's
# signature against the issuer's published JWKS keys and maps the chosen
# claim (default: "sub") to a Postgres role.
#
#   Repo:   https://github.com/percona/pg_oidc_validator
#   Status: release 1.1.0 (upstream calls 1.0.0 its first stable release).
#           Semantius bearer mode itself is still experimental: the app.*
#           permission cache is bypassed in bearer sessions (see the README).
#
# The base image is multi-arch (linux/amd64 + linux/arm64) and we compile the
# validator from source inside the build, so the same Dockerfile produces a
# working image on Intel/AMD and on ARM (Apple Silicon, Windows on ARM, etc).
# ---------------------------------------------------------------------------
USER root

# Pin the validator to a release tag for reproducible builds. Override at
# build time with: --build-arg OIDC_VALIDATOR_REF=<tag-sha-or-branch>
ARG OIDC_VALIDATOR_REF=1.1.0

# Local patches applied on top of the pinned commit (see patches/ for rationale).
COPY patches/ /tmp/patches/

RUN set -eux; \
    apt-get update; \
    # Runtime deps (kept in the final image). The validator fetches JWKS over
    # HTTPS via libcurl; libpq-oauth is the client-side OAuth flow module (lets
    # psql inside the container do the OAuth flow too).
    #
    # postgresql-18-plpgsql-check is DEV-ONLY and deliberately absent from the
    # shipped image (docker-postgres/Dockerfile): `deno task test --coverage`
    # uses its profiler for statement-level coverage and degrades to
    # function-level data without it. The PGDG package is built against a
    # specific 18.x, so `postgresql-18` is listed alongside it: apt then
    # resolves the pair together instead of the server being left behind the
    # extension (build with --pull to keep the base image current).
    apt-get install -y --no-install-recommends \
        ca-certificates \
        libcurl4 \
        libpq-oauth \
        postgresql-18 \
        postgresql-18-plpgsql-check; \
    # Build-only deps (purged afterwards). g++ in trixie is >= 14 (C++23 capable).
    apt-get install -y --no-install-recommends \
        git \
        build-essential \
        postgresql-server-dev-18 \
        libcurl4-openssl-dev \
        libssl-dev; \
    git clone https://github.com/percona/pg_oidc_validator.git /tmp/validator; \
    git -C /tmp/validator checkout "$OIDC_VALIDATOR_REF"; \
    # Apply our patches (normalize CRLF first so it applies on any host).
    for p in /tmp/patches/*.patch; do \
        sed -i 's/\r$//' "$p"; \
        git -C /tmp/validator apply --ignore-whitespace --recount -v "$p"; \
    done; \
    make -C /tmp/validator USE_PGXS=1 install -j"$(nproc)"; \
    rm -rf /tmp/validator; \
    apt-get purge -y git build-essential postgresql-server-dev-18 \
        libcurl4-openssl-dev libssl-dev; \
    apt-get autoremove -y; \
    rm -rf /var/lib/apt/lists/*

USER postgres
