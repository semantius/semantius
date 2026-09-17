#!/usr/bin/env bash
# =============================================================================
# 40-nwind.sh  -  optionally load the Northwind demo module (gated by $NWIND)
# =============================================================================
# Baked into the semantius/postgres image. Runs once at first container init,
# AFTER the extension is installed (10) so the data-dictionary (modules/entities/
# fields tables) and public._versions exist for the module to register into.
#
# GATE: only runs when the NWIND env var is set to ANY non-empty value (e.g.
# NWIND=TRUE in the compose environment: block). Unset/empty -> skipped, so a
# plain database ships with no demo data.
#
# WHY THIS SCRIPT EXISTS AT ALL, AND WHAT IT OWES THE CLI.
# Migrations are the CLI's job. This is the one place that cannot call it: the
# initdb temp server runs with `listen_addresses=''` (socket only, no TCP) and
# the CLI's driver, deno.land/x/postgres, speaks TCP only. So the module has to
# be applied with psql, over the socket, from inside the container.
#
# That makes this script a SECOND IMPLEMENTATION of the migration runner, and a
# second implementation is only safe while it produces the same database the
# first one would. Its contract is packages/core/src/migrate.ts
# (executeMigrations), and every line below exists to match it:
#
#   * one transaction PER FILE, not per statement and not one for the whole set
#   * the migration's own rows and its public._versions row commit TOGETHER, so
#     a failure can never leave applied SQL that nothing has recorded
#   * _versions.name is '<app>.<file without .sql>', _versions.checksum is the
#     SHA-256 of the file's LF-normalized text - the extension writes that
#     column for _core, and the release's validate check ("applied rows whose
#     source text has changed since") skips any row where it is NULL
#   * files are applied in byte order of their names, the same order the CLI's
#     sqlFileNames.sort() produces
#   * a file already recorded in _versions is skipped, not reapplied
#   * an empty migration is an error, not a silent no-op
#   * NOTIFY pgrst inside the transaction, so a running PostgREST reloads
#
# The per-file transaction is not a nicety. The seed registers the module before
# it creates the module's own permissions, which is legal only because
# modules_view_permission_fkey is DEFERRABLE INITIALLY DEFERRED - "checked at
# COMMIT". Under psql's default autocommit every statement is its own
# transaction, so that check lands at the end of the module INSERT, 'nwind:view'
# does not exist yet, and first init dies with the container.
#
# If the CLI's runner changes, this must change with it.
# -----------------------------------------------------------------------------
set -euo pipefail

APP="nwind"
MIGRATIONS_DIR="/opt/semantius/nwind-migrations"

if [ -z "${NWIND:-}" ]; then
    echo "40-nwind.sh: NWIND unset — skipping the optional Northwind demo module."
    exit 0
fi

echo "40-nwind.sh: NWIND=${NWIND} — loading the optional Northwind demo module."

psql_run() {
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" "$@"
}
psql_scalar() {
    psql_run -tAc "$1" | tr -d '\r' | head -1
}

# The CLI calls ensureVersionsTable() first. Here the extension has already
# created _versions, so the table is a PRECONDITION rather than something to
# create - and asserting it beats creating a second, divergent copy of that DDL.
# A missing checksum column would otherwise be discovered as a failing INSERT
# halfway through the seed.
if [ "$(psql_scalar "SELECT to_regclass('public._versions') IS NOT NULL")" != "t" ]; then
    echo "40-nwind.sh: public._versions does not exist — the extension must be installed first." >&2
    exit 1
fi
if [ "$(psql_scalar "SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND table_name='_versions' AND column_name='checksum'")" != "1" ]; then
    echo "40-nwind.sh: public._versions has no checksum column — this image's extension is too old for this script." >&2
    exit 1
fi

# Byte order, to match the CLI's sqlFileNames.sort(); a locale-aware sort can
# order differently and would apply migrations out of sequence.
export LC_ALL=C
shopt -s nullglob

applied=0
skipped=0

for file in "$MIGRATIONS_DIR"/*.sql; do
    base="$(basename "$file")"
    name="${base%.sql}"
    version="${APP}.${name}"

    # The name is interpolated into a SQL literal below. Constraining it to the
    # characters a migration file is ever named with is what makes that safe,
    # and it also catches a file that was never meant to be shipped.
    case "$name" in
        *[!A-Za-z0-9._-]*)
            echo "40-nwind.sh: refusing migration '$base' — unexpected characters in the name." >&2
            exit 1
            ;;
    esac

    if [ "$(psql_scalar "SELECT EXISTS (SELECT 1 FROM public._versions WHERE name = '${version}')")" = "t" ]; then
        echo "  Skipping ${version} - already applied"
        skipped=$((skipped + 1))
        continue
    fi

    # The CLI raises on a migration that is empty or only whitespace; silently
    # recording one as applied would make it unrepeatable.
    if [ -z "$(tr -d '[:space:]' < "$file")" ]; then
        echo "40-nwind.sh: migration file ${base} is empty or contains only whitespace." >&2
        exit 1
    fi

    # SHA-256 of the LF-normalized text - byte-identical to the CLI's
    # migrationChecksum(), so a database seeded here and one migrated by the CLI
    # record the same value and both answer the validate check the same way.
    checksum="$(tr -d '\r' < "$file" | sha256sum | cut -d ' ' -f 1)"

    # The bookkeeping goes in its own file rather than a -c argument because
    # psql does not interpolate -v variables inside -c, and psql applies
    # multiple -f arguments in order inside the single transaction.
    record="$(mktemp)"
    printf "INSERT INTO public._versions (name, checksum) VALUES ('%s', '%s');\nNOTIFY pgrst, 'reload schema';\n" \
        "$version" "$checksum" > "$record"

    echo "  Executing migration: ${version}"
    if ! psql_run --single-transaction -f "$file" -f "$record"; then
        rm -f "$record"
        echo "40-nwind.sh: migration ${version} failed — nothing from it was committed." >&2
        exit 1
    fi
    rm -f "$record"

    echo "  Migration ${version} completed and recorded"
    applied=$((applied + 1))
done

if [ "$applied" -eq 0 ] && [ "$skipped" -eq 0 ]; then
    echo "40-nwind.sh: no migration files in ${MIGRATIONS_DIR}." >&2
    exit 1
fi

echo "40-nwind.sh: Northwind demo module loaded (${applied} applied, ${skipped} skipped)."
