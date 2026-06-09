#!/usr/bin/env bash
# pg-cli-deploy-module.sh  -  Deploy one or more app modules onto the
# already-running plain CLI-testing container (port 5432), via the CLI migrate
# path.
#
#   ./pg-cli-deploy-module.sh nwind
#   ./pg-cli-deploy-module.sh cloud,nwind
#
# The module list is passed straight to `migrate --apps`. migrate auto-prepends
# `_core`, which is a no-op if it is already applied (or installs it if the DB is
# fresh). The connection comes from the `.env.pgdocker-cli` profile (--env
# pgdocker-cli), exactly like the other CLI tasks — no bespoke URL handling.
# Unlike pg-cli-retest, this does NOT recreate the container, dropall, or run the
# pgTAP suite — it just deploys the given modules onto whatever is already there.
# The mirror of pg-ext-deploy-module.sh.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

APPS="${1:-}"
if [ -z "$APPS" ]; then
  echo "usage: $(basename "$0") <module[,module...]>   e.g. nwind  or  cloud,nwind" >&2
  exit 2
fi

echo "== migrate --apps $APPS --env pgdocker-cli (auto-prepends _core) =="
if ! ( cd "$REPO_ROOT" && deno task migrate --apps "$APPS" --env pgdocker-cli ); then
  echo "migrate failed — is the CLI container running? Start it with ./pg-cli-start.sh" >&2
  exit 1
fi

echo
echo "Deployed onto the CLI stack (port 5432): $APPS"
