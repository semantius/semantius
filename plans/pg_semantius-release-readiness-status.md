# pg_semantius release readiness: status and hand-off

Last updated: 2026-09-02. Working agreement: **no commits** (everything is
uncommitted in the working tree for review) and **no breaking change without
asking first** (open questions below).

## Where things are

| What | Path |
|---|---|
| Full plan (context, decisions, all parts) | `C:\Users\MartinAmm\.claude\plans\pg-semantius-is-a-postgresql-cosmic-sloth.md` (outside the repo; this file is the in-repo summary) |
| Coverage tooling | `packages/cli/commands/coverage.ts` (new), `packages/cli/commands/test.ts`, `packages/cli/cli.ts`, `packages/cli/commands/retest.ts` |
| Wrapper scripts forwarding `--coverage` | `pgdocker/pg-ext-retest.sh/.cmd`, `pgdocker/pg-cli-retest.sh/.cmd` |
| Docs updated | `README.md` (options + examples), `AGENTS.md` (test sequence), `pgdocker/README.md` |
| Coverage report (first measurement, gaps, ratchet) | `docs/pg_semantius-test-coverage.md` |
| Release review (security, performance, linter, packaging, tooling, fix list) | `plans/pg_semantius-release-review.md` |
| New pgTAP files (all green on both install layouts) | `apps/test/tests/0306_test_pgmq_operations.sql`, `0405_test_rbac_helpers.sql`, `0410_test_uid_claim_paths.sql`, `0415_test_queue_rpc_mutators.sql`, `0420_test_audit_truncate.sql` |

`git status` shows exactly these modified/new files; `coverage/` output is
gitignored.

## Done

1. Tool decision: plpgsql_check profiler + `track_functions`/`pg_stat_*` (pgcov and plpgsql_coverage rejected; rationale in the plan and `docs/pg_semantius-test-coverage.md`).
2. `deno task test --coverage [--coverage-min <pct>]` and `deno task retest --confirm --coverage`: reports `coverage/summary.json`, `coverage/uncovered.md`, `coverage/lcov.info` (mapped to migration lines). Plain `deno task test` output and exit codes verified byte-identical to HEAD (pass and fail cases, both reporters). TAP purity, threshold gate and degradation (no plpgsql_check, no superuser) verified.
3. First coverage numbers: 144/292 functions, 73.9% of PL/pgSQL statements; after the five new test files: 182/292 functions (62.3%), 83.3% statements, 1,967 assertions, suite green on the extension install and the migrate install.
4. Review complete: security (15 findings, 1 Critical: SQL injection via `fields.default_value` -> superuser), performance (12, measured), packaging (15, with dump/restore, drop, upgrade, second-database, schema-pinning, encoding and non-superuser experiments; 1 Critical: `pg_dump` loses all extension data, 2 High: install fails outside schema `public`, restore needs a three-phase procedure), linter (122 warnings), catalog audit, tooling (plpgsql_check profiler bug). Everything is in `plans/pg_semantius-release-review.md` with a prioritised 12-step fix list.

5. Fixes applied in the original migrations (decision: nothing is released): S1 default-value injection (`0070` `quote_default_value`, `0060` CHECK), S13 generated-trigger quoting (`0180`), T1 profiler workaround (`0145:793`), and the owner hardening (`0290_owner_hardening.sql`: dedicated `semantius_owner` NOSUPERUSER/BYPASSRLS role owns every core object when the installer is a superuser). Regression tests `0425_test_default_value_hardening.sql`, `0430_test_owner_hardening.sql`. `extension/` regenerated (`deno task extension 0.4.0`; the generator warns that 0.3.0-released migrations were edited, which is expected while nothing is released). Both install layouts green: 2,007 assertions; coverage 182/292 functions, 83.5% statements, no scratch workaround needed any more.

## In progress

Nothing running. The next steps all depend on the open questions below.

## Open questions (ask-first items, decisions needed)

1. **Dev image**: add `postgresql-18-plpgsql-check` to the runtime apt line in `pgdocker/Dockerfile` (dev images only, never the published image). The PGDG 2.10.4 build needs a current 18.x server: either list `postgresql-18` in the same `apt-get install` line so it upgrades, or build with `docker compose build --pull`. Without this, `--coverage` on the pgdocker stacks degrades to function-level data.
2. **Remaining Critical/High findings**: B1 `pg_extension_config_dump` (+ B3 restore procedure), B2 `schema = public` in the control file, S2 forgeable permission cache, S3 `set_request_context` impersonation, S4 queue RPC authorization, P1 per-row policies. Same approach as S1 (edit the original migrations) unless decided otherwise.
3. **Red tests**: add the pinning tests for the remaining findings now (the suite goes red until the fixes land) or only with the fixes.
4. **CI**: add `.github/workflows/test.yml` (plain + coverage jobs on the extension install) and gate `extension-release.yml` on the plain job.
5. **versions.json**: the generator compares against the recorded 0.3.0 hashes and warns on every regeneration now; if v0.3.0/v0.4.0 are not real releases, reset `extension/versions.json` to the current 0.4.0 set (or bump to 0.5.0) to silence it.
6. **Scratch container**: `semantius-cov-scratch` (port 5439) may be removed when no longer needed (`docker rm -f semantius-cov-scratch`).

## How to resume in a new session

1. Read this file, then `plans/pg_semantius-release-review.md` and
   `docs/pg_semantius-test-coverage.md`; the full plan is at the path above.
2. Answer the open questions; the working agreement stays in force.
3. Scratch database (throwaway, used for every measurement; safe to recreate):

```bash
docker rm -f semantius-cov-scratch
docker run -d --name semantius-cov-scratch -p 5439:5432 \
  -e POSTGRES_PASSWORD=devpassword -e POSTGRES_DB=appdb postgres:18
# wait for "PostgreSQL init process complete", then:
docker exec semantius-cov-scratch bash -c "apt-get update -qq && apt-get install -y -qq --only-upgrade postgresql-18 postgresql-client-18 && apt-get install -y -qq postgresql-18-plpgsql-check"
docker restart semantius-cov-scratch
docker cp extension/pg_semantius.control semantius-cov-scratch:/usr/share/postgresql/18/extension/
docker cp extension/pg_semantius--0.4.0.sql semantius-cov-scratch:/usr/share/postgresql/18/extension/
docker cp extension/pg_semantius--0.3.0--0.4.0.sql semantius-cov-scratch:/usr/share/postgresql/18/extension/
docker exec semantius-cov-scratch psql -U postgres -d appdb -c "CREATE EXTENSION pg_semantius CASCADE;"
deno task migrate --apps nwind,test --database-url postgresql://postgres:devpassword@localhost:5439/appdb
# optional second DB with the migrate-installed core:
docker exec semantius-cov-scratch psql -U postgres -d postgres -c "CREATE DATABASE appcli"
deno task migrate --apps _core,nwind,test --database-url postgresql://postgres:devpassword@localhost:5439/appcli
```

4. Runs:

```bash
deno task test --database-url postgresql://postgres:devpassword@localhost:5439/appdb              # plain
deno task test --coverage --database-url postgresql://postgres:devpassword@localhost:5439/appdb   # coverage
```

   Until question 2 is decided, statement-level coverage needs the one-line
   rewrite applied to the scratch database (`CREATE OR REPLACE FUNCTION
   rebuild_entity_label_functions ...` with the body from `0145` and line 793
   changed); otherwise the run still works but 29 files abort under the
   profiler and the report flags them.

5. Remaining plan items after the questions are answered:
   `pgdocker/pg-ext-lifecycle.sh` (step list in the review, section 4), the
   ask-first changes above, then the fix migrations and their red tests in
   the order of the review's 12-step fix list, `deno task extension 0.5.0`,
   and a final plain + coverage run on both stacks.
