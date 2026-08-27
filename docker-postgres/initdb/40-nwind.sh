#!/bin/bash
# =============================================================================
# 40-nwind.sh  -  optionally load the Northwind demo module (gated by $NWIND)
# =============================================================================
# Baked into the semantius-db image. Runs once at first container init, AFTER the
# extension is installed (10) so the data-dictionary (modules/entities/fields
# tables) exists for the module to register into.
#
# GATE: only runs when the NWIND env var is set to ANY non-empty value (e.g.
# NWIND=TRUE in the compose environment: block). Unset/empty -> skipped, so a
# plain database ships with no demo data.
#
# The seed itself (/opt/semantius/nwind.sql) is the app's two migrations
# (apps/nwind/migrations/0010_create.sql + 0020_load_data.sql) MERGED at image
# build time (see docker-semantius/Dockerfile). 0010 registers the Northwind
# module/entities into the dictionary (triggers auto-create the physical tables);
# 0020 loads the sample rows. Neither redeclares _core — that comes from the
# extension. The build also appends _versions guards so a later `deno task
# migrate --apps nwind` recognises the module as already deployed.
# -----------------------------------------------------------------------------
set -euo pipefail

if [ -z "${NWIND:-}" ]; then
    echo "40-nwind.sh: NWIND unset — skipping the optional Northwind demo module."
    exit 0
fi

echo "40-nwind.sh: NWIND=${NWIND} — loading the optional Northwind demo module."
psql -v ON_ERROR_STOP=1 \
     --username "$POSTGRES_USER" \
     --dbname "$POSTGRES_DB" \
     -f /opt/semantius/nwind.sql
echo "40-nwind.sh: Northwind demo module loaded."
