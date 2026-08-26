#!/usr/bin/env bash
# pg-ext-deploy-module.sh  -  Deploy one or more app modules onto the
# already-running EXTENSION container (port 5433), via the CLI migrate path.
#
#   ./pg-ext-deploy-module.sh nwind
#   ./pg-ext-deploy-module.sh nwind,test
#
# The module list is passed straight to `migrate --apps`. `_core` is already
# installed by the extension (CREATE EXTENSION pg_semantic_platform), so migrate
# auto-prepends `_core` but every `_core.*` migration is SKIPPED (the extension
# seeded `_versions`); only the given modules are deployed onto the extension's
# `_core`. The connection comes from the `.env.pgdocker-ext` profile (--env
# pgdocker-ext), exactly like the other CLI tasks — no bespoke URL handling.
# Unlike pg-ext-retest, this does NOT reset the stack or run the pgTAP suite.
# The mirror of pg-cli-deploy-module.sh.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

APPS="${1:-}"
if [ -z "$APPS" ]; then
  echo "usage: $(basename "$0") <module[,module...]>   e.g. nwind  or  nwind,test" >&2
  exit 2
fi

echo "== migrate --apps $APPS --env pgdocker-ext (migrate skips the seeded _core) =="
if ! ( cd "$REPO_ROOT" && deno task migrate --apps "$APPS" --env pgdocker-ext ); then
  echo "migrate failed — is the ext container running? Start it with ./pg-ext-start.sh" >&2
  exit 1
fi

echo
echo "Deployed onto the extension stack (port 5433): $APPS"
