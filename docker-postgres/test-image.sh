#!/usr/bin/env bash
# test-image.sh - boot the DB image the way a consumer's FIRST `create` boots it
# and prove the baked init scripts survive it, with and without the optional
# Northwind demo module.
#
# WHY THIS EXISTS AS ITS OWN SCRIPT. Everything else that touches nwind loads it
# through `deno task migrate`, which wraps each migration file in a transaction.
# The image does not: 40-nwind.sh feeds the merged seed to psql, and psql in
# autocommit gives every statement its own transaction. A statement that is only
# legal because a constraint is DEFERRABLE INITIALLY DEFERRED - the module row
# naming a view_permission that the next statement creates - passes under migrate
# and fails here, because "deferred until COMMIT" collapses to "checked at the
# end of this one INSERT". That whole class of defect is invisible to the pgTAP
# suites, which run inside a transaction by construction, and invisible to
# docker-compose/test.sh, which deploys nwind by calling migrate.
#
# It is also the only check that runs the initdb path at all. The release
# workflow builds this image and pushes it without ever starting it, so an init
# script that aborts ships to every consumer and takes down their first `create`.
#
# Plain `docker run` on purpose: no compose, no .env, and no checkout of
# semantius-self-hosted, so this is runnable in this repo's CI. A container with
# no volume mount has a fresh data directory, which is what makes init run - the
# entrypoint executes /docker-entrypoint-initdb.d only when it creates the
# cluster, so this is a true first-init every time.
#
# Usage:
#   ./test-image.sh                    build the image from ./extension, then test it
#   ./test-image.sh --no-build         test the image tag as it already exists locally
#   ./test-image.sh 0.5.0-beta1-pg18   test that existing tag (implies --no-build)
#   --keep                             leave the containers behind for triage
set -euo pipefail
cd "$(dirname "$0")"
REPO_ROOT="$(cd .. && pwd)"

# docker exec arguments must not be path-converted under Git Bash.
export MSYS_NO_PATHCONV=1

IMAGE="${IMAGE:-ghcr.io/semantius/postgres}"
DB="semantius"
BUILD=1
KEEP=0
TAG_ARG=""

while [ $# -gt 0 ]; do
  case "$1" in
    --no-build) BUILD=0 ;;
    --keep)     KEEP=1 ;;
    -h|--help)  sed -n '2,31p' "$0"; exit 0 ;;
    -*) echo "Unknown option: $1 (usage: ./test-image.sh [--no-build] [--keep] [<tag>])" >&2; exit 1 ;;
    *)  TAG_ARG="$1"; BUILD=0 ;;   # a bare argument names an existing image tag
  esac
  shift
done

pass_n=0
fail_n=0
step() { printf '\n== %s ==\n' "$*"; }
ok()   { pass_n=$((pass_n + 1)); printf '   ok   %s\n' "$*"; }
bad()  { fail_n=$((fail_n + 1)); printf '   FAIL %s\n' "$*" >&2; }
check() { # check <description> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi
}

# The tag is resolved exactly the way build.sh resolves it - the Postgres major
# from the Dockerfile's FROM line, the version from the control file - so this
# tests the image the build just produced rather than a moving :latest that may
# belong to a different version.
if [ -n "$TAG_ARG" ]; then
  TAG="${IMAGE}:${TAG_ARG}"
else
  pg_major="$(sed -nE 's|^FROM postgres:([0-9]+).*|\1|p' Dockerfile | head -1)"
  [ -n "$pg_major" ] || { echo "could not parse the Postgres major from Dockerfile" >&2; exit 1; }
  version="$(sed -nE "s/^default_version = '(.*)'/\1/p" "$REPO_ROOT/extension/pg_semantius.control" 2>/dev/null)"
  [ -n "$version" ] || { echo "could not read default_version from the control file" >&2; exit 1; }
  TAG="${IMAGE}:${version}-pg${pg_major}"
fi

C_ON="semantius-imgtest-nwind"
C_OFF="semantius-imgtest-plain"

cleanup() {
  if [ "$KEEP" = "1" ]; then
    echo "Keeping $C_ON and $C_OFF for triage."
    return
  fi
  docker rm -f "$C_ON" "$C_OFF" >/dev/null 2>&1 || true
}
trap cleanup EXIT

boot() { # boot <container> [nwind value]
  local c="$1" nwind="${2:-}"
  docker rm -f "$c" >/dev/null 2>&1 || true
  local args=(-d --name "$c" -e POSTGRES_PASSWORD=postgres -e "POSTGRES_DB=$DB")
  [ -n "$nwind" ] && args+=(-e "NWIND=$nwind")
  docker run "${args[@]}" "$TAG" >/dev/null
}

# The entrypoint prints this only after every /docker-entrypoint-initdb.d script
# has exited 0; a script that aborts takes the container down with it, so a dead
# container is the failure signal and needs no separate exit-code check.
init_done() { # init_done <container>
  local c="$1" deadline=$((SECONDS + 240))
  while :; do
    docker logs "$c" 2>&1 | grep -q 'PostgreSQL init process complete' && return 0
    [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" != "true" ] && return 1
    [ "$SECONDS" -ge "$deadline" ] && return 1
    sleep 2
  done
}

q() { # q <container> <sql> -> single scalar
  docker exec "$1" psql -U postgres -d "$DB" -tAc "$2" 2>/dev/null | tr -d '\r' | head -1
}

ready() { # ready <container> - init restarts the server; wait for the real one
  local c="$1" deadline=$((SECONDS + 120))
  until [ "$(q "$c" 'SELECT 1')" = "1" ]; do
    [ "$SECONDS" -ge "$deadline" ] && return 1
    sleep 1
  done
}

logged() { # logged <container> <substring>
  if docker logs "$1" 2>&1 | grep -qF "$2"; then echo yes; else echo no; fi
}

dump_logs() { # dump_logs <container>
  echo "--- last 40 log lines ---" >&2
  docker logs "$1" 2>&1 | tail -40 >&2
  echo "-------------------------" >&2
}

if [ "$BUILD" = "1" ]; then
  step "Building $TAG from ./extension"
  ./build.sh
else
  step "Testing the image as it stands: $TAG"
  docker image inspect "$TAG" >/dev/null 2>&1 \
    || { echo "No local image $TAG. Build it (./build.sh) or pull it first." >&2; exit 1; }
fi

# ---------------------------------------------------------------------------
# NWIND set: the demo module must load and the stack must come up. This is the
# case that regressed - the seed aborted mid-file and the container never
# reached "ready to accept connections".
# ---------------------------------------------------------------------------
step "First init with NWIND=TRUE"
boot "$C_ON" TRUE
if init_done "$C_ON"; then
  ok "init completed; the container is up"
  if ready "$C_ON"; then
    check "the nwind module is registered" "1" \
      "$(q "$C_ON" "SELECT count(*) FROM modules WHERE module_slug = 'nwind'")"
    check "both nwind permissions exist" "2" \
      "$(q "$C_ON" "SELECT count(*) FROM permissions WHERE permission_name IN ('nwind:view','nwind:manage')")"
    check "the module's view_permission resolves" "1" \
      "$(q "$C_ON" "SELECT count(*) FROM modules m JOIN permissions p ON p.permission_name = m.view_permission WHERE m.module_slug = 'nwind'")"
    check "the Northwind Sales role is seeded" "1" \
      "$(q "$C_ON" "SELECT count(*) FROM roles WHERE slug = 'northwind_sales'")"
    # The rows come from 0020_nwind_data.jsonc, the tables from 0010_nwind.jsonc:
    # entities without rows would mean the pass stopped between the two files.
    check "sample rows loaded (customers)" "t" \
      "$(q "$C_ON" "SELECT count(*) > 0 FROM customers")"
    check "sample rows loaded (orders)" "t" \
      "$(q "$C_ON" "SELECT count(*) > 0 FROM orders")"
    # Derived from the directory, never a literal count: hardcoding the file
    # list is what let the image ship a module missing a migration while every
    # check still passed.
    want_n="$(ls "$REPO_ROOT"/apps/nwind/migrations/ | grep -cE '\.(sql|jsonc)$')"
    check "every nwind migration recorded in _versions" "$want_n" \
      "$(q "$C_ON" "SELECT count(*) FROM public._versions WHERE name LIKE 'nwind.%'")"

    # The point of the init script is to leave the database the CLI would have
    # left. _versions is where that is checkable: same row names, and the same
    # checksum `migrate --apps nwind` writes - SHA-256 of the LF-normalized
    # file. A NULL here means the image recorded the migration without applying
    # it through anything that knows what it applied.
    for f in "$REPO_ROOT"/apps/nwind/migrations/*.sql "$REPO_ROOT"/apps/nwind/migrations/*.jsonc; do
      [ -f "$f" ] || continue
      n="$(basename "$f")"
      check "nwind.$n recorded with the CLI's checksum" \
        "$(tr -d '\r' < "$f" | sha256sum | cut -d ' ' -f 1)" \
        "$(q "$C_ON" "SELECT coalesce(checksum, '<null>') FROM public._versions WHERE name = 'nwind.$n'")"
    done
    check "the script applied every migration and skipped none" "yes" \
      "$(logged "$C_ON" "Northwind demo module loaded ($want_n applied, 0 skipped)")"
  else
    bad "the server never accepted connections after init"
    dump_logs "$C_ON"
  fi
else
  bad "init did not complete with NWIND=TRUE - the container died"
  dump_logs "$C_ON"
fi

# ---------------------------------------------------------------------------
# NWIND unset: the gate is a shipped promise - a plain database carries no demo
# data - and it is what every consumer that does not opt in actually runs.
# ---------------------------------------------------------------------------
step "First init with NWIND unset"
boot "$C_OFF"
if init_done "$C_OFF"; then
  ok "init completed; the container is up"
  if ready "$C_OFF"; then
    check "no nwind module" "0" \
      "$(q "$C_OFF" "SELECT count(*) FROM modules WHERE module_slug = 'nwind'")"
    check "no nwind rows in _versions" "0" \
      "$(q "$C_OFF" "SELECT count(*) FROM public._versions WHERE name LIKE 'nwind.%'")"
    check "the extension is installed" "1" \
      "$(q "$C_OFF" "SELECT count(*) FROM pg_extension WHERE extname = 'pg_semantius'")"
    check "the script reported the skip" "yes" \
      "$(logged "$C_OFF" '40-nwind.sh: NWIND unset')"
  else
    bad "the server never accepted connections after init"
    dump_logs "$C_OFF"
  fi
else
  bad "init did not complete with NWIND unset - the container died"
  dump_logs "$C_OFF"
fi

printf '\n== %s passed, %s failed ==\n' "$pass_n" "$fail_n"
[ "$fail_n" -eq 0 ] || exit 1
