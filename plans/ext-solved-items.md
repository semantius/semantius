# pg_semantius extension: items claimed solved

Rows moved out of `plans/pg_semantius-open-items.md` when the extension was
rebuilt as 0.5.0 on 2026-09-03. Each row below is the item **as it was
originally written** (recovered from commit `b2caa66`, the last one before the
rebuild), followed by what was changed and which test proves it.

**Audited on 2026-09-03 by a separate agent instructed to be skeptical.** The
audit's verdicts are in the last section, and the corrections it forced are
folded in below. Two rows did not survive it:

- **B7** is *not* closed and was never removed from the open items; it is
  listed here only because its workflow half is done.
- **R2** is *scope-changed, not solved*: its "Done when" was "both jobs green
  on a pull request", and the owner decided on 2026-09-03 to use neither pull
  requests nor a separate test workflow. It should be read as dropped.

Last updated: 2026-09-03.

## Where every extension-related item stands

Derived from the item list as it was at commit `b2caa66`. Anything not in this
table was never in the rebuild's scope.

| ID | Area | State | Evidence / what remains |
|---|---|---|---|
| B2 | extension | **CLOSED** | `schema = public` + `encoding = 'UTF8'`, no `requires`. lifecycle step 6 (both halves), test 0440. |
| B4 | migration | **CLOSED, one gap** | Fail-fast in 0160 and in migrate()'s pre-flight, both 55000; dead guard removed. lifecycle step 7. GAP: migrate()'s pre-flight fires first, so 0160's own header guard is only reachable on the CLI path, which has no test. |
| B5 | migration | **STILL OPEN** | Never claimed. Event-trigger noise is unchanged; only its Problem text was corrected (both paths log the install's DDL again now that skip_audit is gone). |
| B6 | extension | **CLOSED, boundary pinned** | DROP EXTENSION needs no CASCADE and touches nothing. lifecycle steps 4, 4b, test 0440 group 8. Two things survive the recipe BY DESIGN and are now asserted rather than assumed: one cosmetic `pg_default_acl` row (equal to the built-in default) and the `authenticated`->`semantius_user` membership, which only the recipe's conditional final `DROP ROLE` clears. pgcrypto is left installed on purpose (optional last step). |
| B7 | extension | **CLOSED** | Guard, both suites, the lifecycle script and the META checks all run before anything is packaged, released or pushed, and `--strict` is now passed by both `extension-release.yml` and `test.yml` (closed 2026-09-03: it is structurally inert while `versions.json` holds one build, since the check sits inside `if (prev)`, and becomes protective automatically at the second release). Contributor PRs get the same checks via `test.yml`; the maintainer pushes directly to `main` and verifies locally, then the tag gate re-checks everything. |
| B8 | extension | **CLOSED** | Consumer README generated; its own done-when now passes literally: all 18 GUCs the migrations read appear verbatim (the brace shorthand was expanded because a literal grep is the criterion). No repo-only paths. |
| B9 | extension | **CLOSED** | `encoding = 'UTF8'` plus an explicit pg_encoding_to_char check. lifecycle steps 9 and 9b: LATIN1 and SQL_ASCII both refused. |
| B10 | extension | **CLOSED, one deviation** | https:// URL, maintainer email, release_status, CHANGES.md, and four explicit CI assertions replacing the check that silently no-opped (`pgxn-utils` is a Ruby gem, so `pip install` always fell through). DEVIATION: release_status is `testing`, not the `stable` the row demanded - deliberate, nothing is released. |
| B11 | migration | **PARTIAL** | 0010/0012 skip the grants for a superuser; 0050's ASSERT is now RAISE EXCEPTION (0 ASSERT statements survive in the generated script - asserted). REMAINS: the row's first alternative was 'neither grant reaches the generated script'; both still do, runtime-guarded. Nothing exercises the BYPASSRLS RAISE firing, or the grant-skip, at runtime. |
| B13 | extension | **CLOSED, not repeatably** | Generator LF-normalises before hashing and on every emitted file; confirmed byte-wise (CRLF sources in, zero CR bytes out) and two runs are byte-identical. REMAINS: no automated assertion; it rests on the release job's diff guard. |
| B15 | extension | **CLOSED** | README quotes all three refusal texts, and the CREATE EXTENSION refusal now has a real test (it did not before the audit): lifecycle step 8. |
| B16 | extension | **CLOSED** | The item that justified the rebuild. lifecycle step 2: a custom field on core `users` survives dump + single-pass restore with its physical column and its `fields` row. |
| P6 | migration | **NARROWED** | Extension path now stores `SELECT semantius.migrate()` as query_text (~1,500 small rows). The whole-script query_text problem is CLI-path only. Row text updated; the CLI fix is still open. |
| R1 | tooling | **PARTIAL** | `pg-ext-lifecycle.sh` written: 83 assertions, 0 failures. REMAINS, from the row's own text: the event-trigger-noise step (blocked on B5) and invoking the pgTAP suite from this script. |
| R2 | tooling | **CLOSED** | Resolved 2026-09-03 after the owner clarified: they work directly on `main` and tag releases and will not change that, but contributors may open PRs later. So `.github/workflows/test.yml` exists with a `pull_request`-only trigger (plus manual) - it never fires on a push, leaving the maintainer workflow untouched, and gives a contributor PR the full check set on a clean Linux runner: regenerate, the committed-equals-regenerated guard, both suites (Path B with coverage), the lifecycle script and the META checks. `extension-release.yml` deliberately does not depend on it, so a release stays self-contained. Not yet observed green, because no pull request exists to run it. |
| R5 | tooling | **CLOSED** | postgresql-18-plpgsql-check in the dev image; both stacks report statement coverage (1,816/2,162). Confirmed live in both containers. |

**Not closed: B5, B11, P6, R1** — plus the gaps noted inside B4, B10 and B13. Those are tracked in `plans/pg_semantius-open-items.md`, with the
verification gaps collected under **R7**.

## Original rows

| ID | Priority | Area | Where | Problem | Fix | Done when |
|---|---|---|---|---|---|---|
| B2 | High | extension | `extension/pg_semantius.control` (no `schema =`); generator `packages/cli/commands/extension.ts` (`buildControlFile`) | The extension is hard-pinned to `public` (104 functions `SET search_path = public`, 172 `public.`-qualified references) but the control file does not declare it, so unqualified objects land in the installer's default schema and the install aborts: `ALTER DATABASE ... SET search_path = myschema, public` then `CREATE EXTENSION` fails with `relation "roles" does not exist`; `CREATE EXTENSION pg_semantius SCHEMA other` fails the same way. | Emit `schema = public` in `buildControlFile`; PostgreSQL then forces the target schema and rejects `SCHEMA other` with a clear message. | Install with a non-`public` default search_path succeeds; `SCHEMA other` fails with the schema error (R1). |
| B4 | Medium | migration | `0160_pgmq.sql` (header) | If the real `pgmq` extension is installed in the target database the install aborts at `CREATE TABLE IF NOT EXISTS pgmq.meta` with `table pgmq.meta is not a member of extension "pg_semantius"`. | Fail fast with a clear message at the top of 0160, or namespace the vendored copy; delete the dead `extname = 'pgmq'` schema guard. | Install into a database with `pgmq` installed stops with the intended message. |
| B6 | Medium | extension | script head (role creation, default privileges); `extension/README.md` | `DROP EXTENSION` leaves the three cluster roles and their memberships (including `postgres` as member of `semantius_user`), two `ALTER DEFAULT PRIVILEGES` entries, the `public` schema ACL and pgcrypto; once any dictionary-created table exists it refuses to drop without `CASCADE` (`4 policies depend on rbac.has_permission(text)`), and `CASCADE` strips that table's policies and triggers but keeps its data. | Document an uninstall recipe; skip `GRANT ... TO current_user` under `CREATE EXTENSION`. | The recipe in the README leaves no leftovers on a fresh database (R1). |
| B7 | Medium | extension | `.github/workflows/extension-release.yml`; `extension.ts` | The release workflow regenerates from the tag and ships that without proving it equals the committed, tested `extension/` and without running pgTAP. | `git diff --exit-code extension/` after generation; run the pgTAP suite and the lifecycle script before `gh release create` (R2). Once a version is really released, fail the generator on edited or removed released migrations instead of warning. | The workflow cannot publish a build that differs from the committed one or that fails the suite. |
| B9 | Low | extension | control (no `encoding`); several runtime string literals | 136 non-ASCII lines, some in runtime literals (the composed-label separator), with no `encoding = 'UTF8'`. Install into a LATIN1 database succeeds with mojibake. | `encoding = 'UTF8'` in the control and/or `chr(8250)` for the separator. | LATIN1 install either refuses or renders the separator correctly (R1). |
| B10 | Low | extension | `extension/META.json`, generator, workflow | `git://` repository URL, maintainer without email, no `release_status`, no `Changes` file in the archive (`LICENSE` and `SECURITY.md` are copied in since 2026-09-03). | `https://github.com/semantius/semantius.git`, maintainer email, `"release_status": "stable"`, a `Changes` file; validate META in CI. | META validates in CI. |
| B11 | Low | migration | `0012` (`GRANT USAGE ON SCHEMA common TO CURRENT_USER`), `0050` (BYPASSRLS `ASSERT`) | The grant is a test artefact and a no-op for the superuser owner; the assert is redundant under `superuser = true` and a no-op if `plpgsql.check_asserts = off`. | Strip both in the generator, or turn the assert into `RAISE EXCEPTION`. | Neither reaches the generated script, or the assert cannot be switched off. |
| B13 | Low | extension | `extension/pg_semantius--0.4.0.sql` | Mixed CRLF/LF in the working tree (`git ls-files --eol`: `i/lf w/mixed`); the local build bakes the working-tree file, CI bakes the LF blob. | Normalise line endings in `renderBody`. | The local and the CI build are byte-identical. |
| B15 | Info | extension | `superuser = true` | Non-superuser install fails with `permission denied to create extension "pg_semantius" / HINT: Must be superuser`. | Quote the error in the README (B8). | Part of B8. |
| B16 | Low | extension | `extension-dump.ts` (`public.fields` filter), `create_dd_table` | Fields added to core entities after the install and relabelled core rows are not dumped (the filter keeps only rows of non-core entities), and the restored `users`-style table would lack the physical column anyway. Documented in the README as "re-apply after a restore". Add a field to `users`, dump, restore: the column and its `fields` row are gone. This is the main reason the packaging is rebuilt rather than patched. | Either forbid custom fields on core entities or dump `fields WHERE ctype = ''` plus a post-restore `ALTER TABLE` reconciliation; settle it in the rebuild's design. | A field added to `users` survives dump and restore (`pgdocker/pg-ext-dump-restore.sh`). |
| R1 | Medium | tooling | `pgdocker/pg-ext-lifecycle.sh` (to write) | No single script proves the extension lifecycle. | Steps: preflight (files, control); fresh install (extension row, empty audit log, seeded counts, object signature); second database; schema pinning (non-`public` search_path must install, `SCHEMA other` must fail with the schema error); non-superuser error text; dump plus three-pass restore with sample data and an exact counter diff (exists as `pgdocker/pg-ext-dump-restore.sh`, fold it in); drop leftovers (fresh DB and DB with a dictionary table); event-trigger noise; LATIN1 install; the pgTAP suite via `pg-ext-retest.sh`; cleanup. Expected results depend on B2, B5 and B9. | The script runs green on the rebuilt extension. |
| R2 | Medium | tooling | CI | No test workflow. | Add `.github/workflows/test.yml` (plain and coverage jobs on the extension install) and gate `extension-release.yml` on it (B7). | Both jobs green on a pull request. |
| R5 | Low | tooling | `pgdocker/Dockerfile` | Without `plpgsql_check` in the dev image, `--coverage` on the pgdocker stacks degrades to function-level data. | Add `postgresql-18-plpgsql-check` to the runtime apt line (dev images only). The PGDG 2.10.4 build needs a current 18.x server: list `postgresql-18` in the same install line or build with `--pull`. | The coverage report has statement data on the pgdocker stacks. |

## What was changed, and what is claimed to prove it

| ID | What was changed | Verified by (claimed) |
|---|---|---|
| B2 | `schema = public` + `encoding = 'UTF8'` in `buildControlFile`; no `requires` (CASCADE would misplace pgcrypto); `migrate()` pins `search_path = public`. | `pg-ext-lifecycle.sh` step 6; `0440_test_extension_membership.sql` (extnamespace/relocatable) |
| B4 | Fail-fast at the top of `0160_pgmq.sql` and in `migrate()`'s pre-flight, both SQLSTATE 55000; the dead `extname = 'pgmq'` guard and the stale config-dump comment deleted. | `pg-ext-lifecycle.sh` step 7 |
| B6 | `DROP EXTENSION` removes only the `semantius` schema and its functions, never needs CASCADE; ordered uninstall recipe in the generated README. | `pg-ext-lifecycle.sh` steps 4 and 4b; `0440_test_extension_membership.sql` group 8 |
| B7 | `extension-release.yml` now runs a `git status --porcelain extension/` guard, both suites, the lifecycle script and META validation before packaging/releasing/pushing; `--strict` added to the generator. | not executable locally - the workflow only runs on a tag push |
| B9 | `encoding = 'UTF8'` in the control file plus an explicit `pg_encoding_to_char` check in the script and in `migrate()` (55000), so SQL_ASCII is refused too. | `pg-ext-lifecycle.sh` steps 9 and 9b |
| B10 | `https://` repository URL, maintainer email, `release_status: 'testing'`, `extension/CHANGES.md` added and copied into the archive, META validated in the release job. | `pg-ext-lifecycle.sh` step 0 (partial); the release job's META validation |
| B11 | 0010 and 0012 skip their `GRANT ... TO CURRENT_USER` for a superuser; 0050's BYPASSRLS `ASSERT` became `RAISE EXCEPTION`. | `pg-ext-lifecycle.sh` step 1b; tests 0430 and 0060 |
| B13 | The generator LF-normalises every embedded migration before hashing and every emitted file. | two consecutive generator runs are byte-identical; `file` reports no CRLF on any emitted file |
| B15 | `superuser = true` kept; the three refusal texts are quoted in the generated README. | `pg-ext-lifecycle.sh` step 8; `0440_test_extension_membership.sql` group 6 |
| B16 | Core-entity fields are ordinary data now that no table is an extension member. | `pg-ext-lifecycle.sh` step 2 (custom column on `users` + its `fields` row survive dump/restore) |
| R1 | `pgdocker/pg-ext-lifecycle.sh` written; 76 assertions. | the script itself: 76 passed, 0 failed |
| R2 | Folded into B7 by owner decision (no PRs, no separate test workflow): the suites run in the release job on the tag. | same as B7 |
| R5 | `postgresql-18-plpgsql-check` added to `pgdocker/Dockerfile` (dev images only). | `pg-ext-retest.sh --coverage` and `pg-cli-retest.sh --coverage` both report statement data |

## Audit results (independent, 2026-09-03)

| ID | Verdict | Note |
|---|---|---|
| B2 | solved, verified | both halves covered (non-`public` search_path install, `SCHEMA other` refusal) |
| B4 | solved, verified | the `migrate()` pre-flight fires first, so 0160's own header guard is only exercised on the CLI path, which has no test |
| B6 | **partial** | see below |
| B7 | solved (workflow half), **not verifiable locally** | tag-triggered only; still an open item |
| B9 | solved, verified | LATIN1 and SQL_ASCII both refused |
| B10 | **partial** | `release_status` is `testing`, not the `stable` the row demanded (deliberate: nothing is released) |
| B11 | **partial** | the grants are runtime-guarded, not absent from the script |
| B13 | solved, not independently verified | CRLF sources in, pure-LF artefacts out, confirmed byte-wise; no automated assertion |
| B15 | solved (documentation) | the `CREATE EXTENSION` refusal now has a test; it did not before the audit |
| B16 | solved, verified | the one item whose test lands exactly on its "Done when" |
| R1 | **partial** | two steps the row names are still absent: event-trigger noise, and running the pgTAP suite from this script |
| R2 | **not solved as written** | scope-changed; see above |
| R5 | solved, verified by measurement | confirmed live in both containers |

### Defects the audit found, and what was done about them

| Finding | Status |
|---|---|
| The release notes still told users `CREATE EXTENSION pg_semantius CASCADE;` and omitted `SELECT semantius.migrate();`, contradicting the shipped README | **fixed** — `extension-release.yml` now emits both statements and the no-CASCADE rationale |
| `psqlrun()` ended in `\|\| true`, so `psqlrun … && ok … \|\| bad` could never reach `bad`: seven "succeeds" assertions were unfailable | **fixed** — only `psqlq` (values and refusal text) swallows the status; `psqlrun` propagates it |
| The B10 CI check installed `pgxn-utils` with `pip`, but it is a **Ruby gem**, so it always fell through to a 7-key presence test that validated none of B10's four demands | **fixed** — `gem install`, and four explicit assertions (URL scheme, maintainer email, `release_status`, `CHANGES.md`) that run either way |
| B15's cited tests exercised `migrate()`, not the `CREATE EXTENSION` refusal it is actually about | **fixed** — a real non-superuser `CREATE EXTENSION` test was added |
| B11's cited tests (0430, 0060) are byte-identical to `b2caa66` and assert nothing about it | **partly fixed** — the script now asserts no `ASSERT` survives and no `check_asserts` dependency remains; the runtime grant guards still have no direct test |
| B6 never asserted three of the four leftovers it names: the `public` schema ACL, the role memberships, and pgcrypto | **fixed** — all three asserted; pgcrypto is asserted as *deliberately left*, since dropping it is the recipe's optional last step |
| The reinstall-after-uninstall assertion could not fail and did not check that the install was real | **fixed** — followed by a `pending()` check |

### Still open after the audit

- **R1**: the event-trigger-noise step and invoking the pgTAP suite are absent
  (tracked with the four other missing steps in open item **R7**).
- **B11**: nothing exercises the BYPASSRLS `RAISE EXCEPTION` firing, or the
  superuser grant-skip, at runtime.
- **B4**: 0160's own header guard is never reached on the extension path.
- **B13**: no repeatable assertion; it rests on the release-job diff guard.
