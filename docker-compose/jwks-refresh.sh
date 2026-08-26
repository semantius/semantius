#!/usr/bin/env bash
# Refresh the OIDC signing keys (JWKS) after the identity provider rotates them:
# re-run the one-shot jwks-fetch to pull the current keys from JWKS_URL into the
# shared volume, then restart ONLY the PostgREST container so it re-reads them.
#
# WHY a restart (not a reload signal): PostgREST gets its jwt-secret from the
# PGRST_JWT_SECRET env var (@/jwks/jwks.json). Per the PostgREST docs, env-var
# config is NOT re-applied on a config reload (SIGUSR2 / NOTIFY 'reload config'),
# so only a restart re-reads the file. The database stays up — it is a ~1s blip
# on the API container.
#
# Most IdPs rotate slowly and publish new keys ahead of use, so running this
# on demand is usually enough. For a fast-rotating IdP, schedule it (e.g. a daily
# cron) — see README ("Key rotation").
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -f .env ]; then
  echo "No .env found. Run ./pg-rest-create.sh first (it copies .env.example)." >&2
  exit 1
fi

if [ -z "$(docker compose ps -aq)" ]; then
  echo "No containers exist. Run ./pg-rest-create.sh first." >&2
  exit 1
fi

# Re-fetch synchronously. If the fetch fails, `set -e` aborts here and PostgREST
# is left untouched (still serving with the keys it already has) — we never
# restart it onto a failed/empty fetch.
echo "Refreshing JWKS from the issuer ..."
docker compose run --rm jwks-fetch

echo "Restarting PostgREST to pick up the new keys ..."
docker compose restart postgrest

echo "Done — PostgREST is validating against the refreshed JWKS."
