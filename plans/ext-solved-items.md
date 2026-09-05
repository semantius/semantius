# Semantius: solved items

The closed half of `plans/pg_semantius-open-items.md`. **Every row deleted from
that list is recorded here**, as the item was originally written, followed by
what was changed and what proves it. Deleting a row from the open items without
adding it here is not allowed: IDs are never reused, so a gap in one file has to
be explained by the other.

The first batch is the 0.5.0 extension rebuild of 2026-09-03, which closed
sixteen rows at once; it is documented in the four sections below, together with
an independent audit of those claims, and its rows were recovered from commit
`b2caa66`, the last one before the rebuild. Every closure after it gets its own
dated section, oldest first.

**The rebuild batch was audited on 2026-09-03 by a separate agent instructed to
be skeptical.** The verdicts are in "Audit results", and the corrections it
forced are folded in below. Two of its rows did not survive:

- **B7** is *not* closed and was never removed from the open items; it is
  listed here only because its workflow half is done.
- **R2** is *scope-changed, not solved*: its "Done when" was "both jobs green
  on a pull request", and the owner decided on 2026-09-03 to use neither pull
  requests nor a separate test workflow. It should be read as dropped.

Last updated: 2026-09-05.

## The 0.5.0 rebuild (2026-09-03): where every item stands

Derived from the item list as it was at commit `b2caa66`. Anything not in this
table was never in the rebuild's scope.

| ID | Area | State | Evidence / what remains |
|---|---|---|---|
| B2 | extension | **CLOSED** | `schema = public` + `encoding = 'UTF8'`, no `requires`. lifecycle step 6 (both halves), test 0440. |
| B4 | migration | **CLOSED, one gap** | Fail-fast in 0160 and in migrate()'s pre-flight, both 55000; dead guard removed. lifecycle step 7. GAP: migrate()'s pre-flight fires first, so 0160's own header guard is only reachable on the CLI path, which has no test. |
| B5 | migration | **CLOSED 2026-09-04** | Scoped audit: `audit.log_ddl_event()` skips `in_extension` objects, `pg_temp*` and every schema outside `public/common/rbac/audit/pgmq`; both `pgrst_ddl_watch` and `pgrst_drop_watch` carry the same schema filter. `0301_test_audit_ddl_scope.sql` + lifecycle step 11 (CREATE and DROP in a foreign schema and a temp table produce neither an audit row nor a NOTIFY; `public` still produces both). The row's own Problem text about the `pgrst_*` watches was wrong: they already filtered by tag and by `pg_temp`, only the schema filter was missing. Residue in **S18**. |
| B6 | extension | **CLOSED, boundary pinned** | DROP EXTENSION needs no CASCADE and touches nothing. lifecycle steps 4, 4b, test 0440 group 8. Two things survive the recipe BY DESIGN and are now asserted rather than assumed: one cosmetic `pg_default_acl` row (equal to the built-in default) and the `authenticated`->`semantius_user` membership, which only the recipe's conditional final `DROP ROLE` clears. pgcrypto is left installed on purpose (optional last step). |
| B7 | extension | **CLOSED** | Guard, both suites, the lifecycle script and the META checks all run before anything is packaged, released or pushed, and `--strict` is now passed by both `extension-release.yml` and `test.yml` (closed 2026-09-03: it is structurally inert while `versions.json` holds one build, since the check sits inside `if (prev)`, and becomes protective automatically at the second release). Contributor PRs get the same checks via `test.yml`; the maintainer pushes directly to `main` and verifies locally, then the tag gate re-checks everything. |
| B8 | extension | **CLOSED** | Consumer README generated; its own done-when now passes literally: all 18 GUCs the migrations read appear verbatim (the brace shorthand was expanded because a literal grep is the criterion). No repo-only paths. |
| B9 | extension | **CLOSED** | `encoding = 'UTF8'` plus an explicit pg_encoding_to_char check. lifecycle steps 9 and 9b: LATIN1 and SQL_ASCII both refused. |
| B10 | extension | **CLOSED, one deviation** | https:// URL, maintainer email, release_status, CHANGES.md, and four explicit CI assertions replacing the check that silently no-opped (`pgxn-utils` is a Ruby gem, so `pip install` always fell through). DEVIATION: release_status is `testing`, not the `stable` the row demanded - deliberate, nothing is released. |
| B11 | migration | **PARTIAL** | 0010/0012 skip the grants for a superuser; 0050's ASSERT is now RAISE EXCEPTION (0 ASSERT statements survive in the generated script - asserted). REMAINS: the row's first alternative was 'neither grant reaches the generated script'; both still do, runtime-guarded. Nothing exercises the BYPASSRLS RAISE firing, or the grant-skip, at runtime. |
| B13 | extension | **CLOSED, not repeatably** | Generator LF-normalizes before hashing and on every emitted file; confirmed byte-wise (CRLF sources in, zero CR bytes out) and two runs are byte-identical. REMAINS: no automated assertion; it rests on the release job's diff guard. |
| B15 | extension | **CLOSED** | README quotes all three refusal texts, and the CREATE EXTENSION refusal now has a real test (it did not before the audit): lifecycle step 8. |
| B16 | extension | **CLOSED** | The item that justified the rebuild. lifecycle step 2: a custom field on core `users` survives dump + single-pass restore with its physical column and its `fields` row. |
| P6 | migration | **CLOSED 2026-09-04** | `left(current_query(), 8192)` plus the generated-label filter. Measured on a full `pg-cli-retest.sh`: `audit_ddl_logs` 4,008 rows / 88.9 MB before, 2,156 rows / 8.4 MB after (**-90%**, target was -85%); raw `query_text` ~468 MB -> 16.7 MB; scratch database 116 MB -> 40 MB. Lifecycle step 11 pins the exact truncation with a deliberately over-long statement. The GRANT/REVOKE half of the label churn is unfilterable and is tracked in **S18**. |
| R1 | tooling | **CLOSED 2026-09-04** | `pg-ext-lifecycle.sh`: 95 assertions, 0 failures. The event-trigger-noise step landed as step 11 (12 assertions). The other missing step, "run the pgTAP suite from this script", was dropped by owner decision on 2026-09-03. The remaining uncovered steps are R7, not R1. |
| R2 | tooling | **CLOSED** | Resolved 2026-09-03 after the owner clarified: they work directly on `main` and tag releases and will not change that, but contributors may open PRs later. So `.github/workflows/test.yml` exists with a `pull_request`-only trigger (plus manual) - it never fires on a push, leaving the maintainer workflow untouched, and gives a contributor PR the full check set on a clean Linux runner: regenerate, the committed-equals-regenerated guard, both suites (Path B with coverage), the lifecycle script and the META checks. `extension-release.yml` deliberately does not depend on it, so a release stays self-contained. Not yet observed green, because no pull request exists to run it. |
| R5 | tooling | **CLOSED** | postgresql-18-plpgsql-check in the dev image; both stacks report statement coverage (1,816/2,162). Confirmed live in both containers. |

**Not closed: B11** — plus the gaps noted inside B4, B10 and B13, and the new limits of the scoped audit (**S18**). Those are tracked in
`plans/pg_semantius-open-items.md`, with the verification gaps collected under **R7**.

## The 0.5.0 rebuild: original rows

| ID | Priority | Area | Where | Problem | Fix | Done when |
|---|---|---|---|---|---|---|
| B2 | High | extension | `extension/pg_semantius.control` (no `schema =`); generator `packages/cli/commands/extension.ts` (`buildControlFile`) | The extension is hard-pinned to `public` (104 functions `SET search_path = public`, 172 `public.`-qualified references) but the control file does not declare it, so unqualified objects land in the installer's default schema and the install aborts: `ALTER DATABASE ... SET search_path = myschema, public` then `CREATE EXTENSION` fails with `relation "roles" does not exist`; `CREATE EXTENSION pg_semantius SCHEMA other` fails the same way. | Emit `schema = public` in `buildControlFile`; PostgreSQL then forces the target schema and rejects `SCHEMA other` with a clear message. | Install with a non-`public` default search_path succeeds; `SCHEMA other` fails with the schema error (R1). |
| B4 | Medium | migration | `0160_pgmq.sql` (header) | If the real `pgmq` extension is installed in the target database the install aborts at `CREATE TABLE IF NOT EXISTS pgmq.meta` with `table pgmq.meta is not a member of extension "pg_semantius"`. | Fail fast with a clear message at the top of 0160, or namespace the vendored copy; delete the dead `extname = 'pgmq'` schema guard. | Install into a database with `pgmq` installed stops with the intended message. |
| B6 | Medium | extension | script head (role creation, default privileges); `extension/README.md` | `DROP EXTENSION` leaves the three cluster roles and their memberships (including `postgres` as member of `semantius_user`), two `ALTER DEFAULT PRIVILEGES` entries, the `public` schema ACL and pgcrypto; once any dictionary-created table exists it refuses to drop without `CASCADE` (`4 policies depend on rbac.has_permission(text)`), and `CASCADE` strips that table's policies and triggers but keeps its data. | Document an uninstall recipe; skip `GRANT ... TO current_user` under `CREATE EXTENSION`. | The recipe in the README leaves no leftovers on a fresh database (R1). |
| B7 | Medium | extension | `.github/workflows/extension-release.yml`; `extension.ts` | The release workflow regenerates from the tag and ships that without proving it equals the committed, tested `extension/` and without running pgTAP. | `git diff --exit-code extension/` after generation; run the pgTAP suite and the lifecycle script before `gh release create` (R2). Once a version is really released, fail the generator on edited or removed released migrations instead of warning. | The workflow cannot publish a build that differs from the committed one or that fails the suite. |
| B9 | Low | extension | control (no `encoding`); several runtime string literals | 136 non-ASCII lines, some in runtime literals (the composed-label separator), with no `encoding = 'UTF8'`. Install into a LATIN1 database succeeds with mojibake. | `encoding = 'UTF8'` in the control and/or `chr(8250)` for the separator. | LATIN1 install either refuses or renders the separator correctly (R1). |
| B10 | Low | extension | `extension/META.json`, generator, workflow | `git://` repository URL, maintainer without email, no `release_status`, no `Changes` file in the archive (`LICENSE` and `SECURITY.md` are copied in since 2026-09-03). | `https://github.com/semantius/semantius.git`, maintainer email, `"release_status": "stable"`, a `Changes` file; validate META in CI. | META validates in CI. |
| B11 | Low | migration | `0012` (`GRANT USAGE ON SCHEMA common TO CURRENT_USER`), `0050` (BYPASSRLS `ASSERT`) | The grant is a test artifact and a no-op for the superuser owner; the assert is redundant under `superuser = true` and a no-op if `plpgsql.check_asserts = off`. | Strip both in the generator, or turn the assert into `RAISE EXCEPTION`. | Neither reaches the generated script, or the assert cannot be switched off. |
| B13 | Low | extension | `extension/pg_semantius--0.4.0.sql` | Mixed CRLF/LF in the working tree (`git ls-files --eol`: `i/lf w/mixed`); the local build bakes the working-tree file, CI bakes the LF blob. | Normalize line endings in `renderBody`. | The local and the CI build are byte-identical. |
| B15 | Info | extension | `superuser = true` | Non-superuser install fails with `permission denied to create extension "pg_semantius" / HINT: Must be superuser`. | Quote the error in the README (B8). | Part of B8. |
| B16 | Low | extension | `extension-dump.ts` (`public.fields` filter), `create_dd_table` | Fields added to core entities after the install and relabelled core rows are not dumped (the filter keeps only rows of non-core entities), and the restored `users`-style table would lack the physical column anyway. Documented in the README as "re-apply after a restore". Add a field to `users`, dump, restore: the column and its `fields` row are gone. This is the main reason the packaging is rebuilt rather than patched. | Either forbid custom fields on core entities or dump `fields WHERE ctype = ''` plus a post-restore `ALTER TABLE` reconciliation; settle it in the rebuild's design. | A field added to `users` survives dump and restore (`pgdocker/pg-ext-dump-restore.sh`). |
| R1 | Medium | tooling | `pgdocker/pg-ext-lifecycle.sh` (to write) | No single script proves the extension lifecycle. | Steps: preflight (files, control); fresh install (extension row, empty audit log, seeded counts, object signature); second database; schema pinning (non-`public` search_path must install, `SCHEMA other` must fail with the schema error); non-superuser error text; dump plus three-pass restore with sample data and an exact counter diff (exists as `pgdocker/pg-ext-dump-restore.sh`, fold it in); drop leftovers (fresh DB and DB with a dictionary table); event-trigger noise; LATIN1 install; the pgTAP suite via `pg-ext-retest.sh`; cleanup. Expected results depend on B2, B5 and B9. | The script runs green on the rebuilt extension. |
| R2 | Medium | tooling | CI | No test workflow. | Add `.github/workflows/test.yml` (plain and coverage jobs on the extension install) and gate `extension-release.yml` on it (B7). | Both jobs green on a pull request. |
| R5 | Low | tooling | `pgdocker/Dockerfile` | Without `plpgsql_check` in the dev image, `--coverage` on the pgdocker stacks degrades to function-level data. | Add `postgresql-18-plpgsql-check` to the runtime apt line (dev images only). The PGDG 2.10.4 build needs a current 18.x server: list `postgresql-18` in the same install line or build with `--pull`. | The coverage report has statement data on the pgdocker stacks. |

## The 0.5.0 rebuild: what was changed, and what is claimed to prove it

| ID | What was changed | Verified by (claimed) |
|---|---|---|
| B2 | `schema = public` + `encoding = 'UTF8'` in `buildControlFile`; no `requires` (CASCADE would misplace pgcrypto); `migrate()` pins `search_path = public`. | `pg-ext-lifecycle.sh` step 6; `0440_test_extension_membership.sql` (extnamespace/relocatable) |
| B4 | Fail-fast at the top of `0160_pgmq.sql` and in `migrate()`'s pre-flight, both SQLSTATE 55000; the dead `extname = 'pgmq'` guard and the stale config-dump comment deleted. | `pg-ext-lifecycle.sh` step 7 |
| B6 | `DROP EXTENSION` removes only the `semantius` schema and its functions, never needs CASCADE; ordered uninstall recipe in the generated README. | `pg-ext-lifecycle.sh` steps 4 and 4b; `0440_test_extension_membership.sql` group 8 |
| B7 | `extension-release.yml` now runs a `git status --porcelain extension/` guard, both suites, the lifecycle script and META validation before packaging/releasing/pushing; `--strict` added to the generator. | not executable locally - the workflow only runs on a tag push |
| B9 | `encoding = 'UTF8'` in the control file plus an explicit `pg_encoding_to_char` check in the script and in `migrate()` (55000), so SQL_ASCII is refused too. | `pg-ext-lifecycle.sh` steps 9 and 9b |
| B10 | `https://` repository URL, maintainer email, `release_status: 'testing'`, `extension/CHANGES.md` added and copied into the archive, META validated in the release job. | `pg-ext-lifecycle.sh` step 0 (partial); the release job's META validation |
| B11 | 0010 and 0012 skip their `GRANT ... TO CURRENT_USER` for a superuser; 0050's BYPASSRLS `ASSERT` became `RAISE EXCEPTION`. | `pg-ext-lifecycle.sh` step 1b; tests 0430 and 0060 |
| B13 | The generator LF-normalizes every embedded migration before hashing and every emitted file. | two consecutive generator runs are byte-identical; `file` reports no CRLF on any emitted file |
| B15 | `superuser = true` kept; the three refusal texts are quoted in the generated README. | `pg-ext-lifecycle.sh` step 8; `0440_test_extension_membership.sql` group 6 |
| B16 | Core-entity fields are ordinary data now that no table is an extension member. | `pg-ext-lifecycle.sh` step 2 (custom column on `users` + its `fields` row survive dump/restore) |
| R1 | `pgdocker/pg-ext-lifecycle.sh` written; 76 assertions. | the script itself: 76 passed, 0 failed |
| R2 | Folded into B7 by owner decision (no PRs, no separate test workflow): the suites run in the release job on the tag. | same as B7 |
| R5 | `postgresql-18-plpgsql-check` added to `pgdocker/Dockerfile` (dev images only). | `pg-ext-retest.sh --coverage` and `pg-cli-retest.sh --coverage` both report statement data |

## The 0.5.0 rebuild: audit results (independent, 2026-09-03)

| ID | Verdict | Note |
|---|---|---|
| B2 | solved, verified | both halves covered (non-`public` search_path install, `SCHEMA other` refusal) |
| B4 | solved, verified | the `migrate()` pre-flight fires first, so 0160's own header guard is only exercised on the CLI path, which has no test |
| B6 | **partial** | see below |
| B7 | solved (workflow half), **not verifiable locally** | tag-triggered only; still an open item |
| B9 | solved, verified | LATIN1 and SQL_ASCII both refused |
| B10 | **partial** | `release_status` is `testing`, not the `stable` the row demanded (deliberate: nothing is released) |
| B11 | **partial** | the grants are runtime-guarded, not absent from the script |
| B13 | solved, not independently verified | CRLF sources in, pure-LF artifacts out, confirmed byte-wise; no automated assertion |
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

- **R1**: closed on 2026-09-04. The event-trigger-noise step is now step 11;
  the pgTAP-suite clause was dropped by owner decision. The four other missing
  steps stay in open item **R7**.
- **B11**: nothing exercises the BYPASSRLS `RAISE EXCEPTION` firing, or the
  superuser grant-skip, at runtime.
- **B4**: 0160's own header guard is never reached on the extension path.
- **B13**: no repeatable assertion; it rests on the release-job diff guard.

## The 2026-09-04 follow-up (B5, P6, S15, R1)

Executed from `plans/audit-ddl-noise.md`. One change to one function plus its
two neighbours; both suites and the lifecycle script green on both install
paths (2,091 pgTAP assertions each, 95 lifecycle assertions).

| What changed | Where | Verified by |
|---|---|---|
| `audit.log_ddl_event()` is `SECURITY DEFINER` (S15). It was the only one of the three audit triggers that was not; the request role could not run any DDL, not even `CREATE TEMP TABLE`, because `audit.current_user_id()` is revoked from PUBLIC. | `0150_audit_log.sql` | `0301` tests 4-5; lifecycle step 11 (as `semantius_user`, status propagated via `psqlrun`) |
| Three `CONTINUE WHEN` filters: `in_extension`, schema scope (the five Semantius schemas; `pg_temp*` and foreign schemas out; NULL `schema_name` deliberately kept), and generated `*_label` companions (B5, P6). | `0150_audit_log.sql` | `0301` tests 1-3 and 8; lifecycle step 11 |
| `query_text` bounded with `left(current_query(), 8192)` (P6). | `0150_audit_log.sql` | `0301` test 7 (upper bound); lifecycle step 11 pins the exact truncation with an over-long statement, which the pgTAP assertion alone could not |
| `WHEN TAG IN (...)` on `track_ddl_changes` (B5). DROP tags omitted: `ddl_command_end` reports no rows for DROP commands, verified live. | `0150_audit_log.sql` | `0301` test 6 |
| `REVOKE EXECUTE ON FUNCTION audit.log_ddl_event() FROM PUBLIC` (part of S6). | `0150_audit_log.sql` | consistency with the two other audit triggers |
| The schema filter on **both** `pgrst_ddl_watch` and `pgrst_drop_watch`. The plan named only the first; a review found `DROP TABLE` in a foreign schema still fired `NOTIFY pgrst`. | `0090_notify_triggers.sql` | lifecycle step 11 (CREATE and DROP probes) |
| Lifecycle step 11, and a fix to step 10: its failure path ran `diff \| head` under `set -e -o pipefail`, so a real failure there aborted the run and steps 11-12 never executed. | `pgdocker/pg-ext-lifecycle.sh` | the script itself: 95 passed, 0 failed |

An independent review of this change found six defects, all fixed before the
final run: the unfiltered `pgrst_drop_watch`; a vacuous `query_text` bound
assertion (every statement `life1` had seen was short); a `notify_probe` whose
timeouts returned `silent`, so a probe that never started would have passed two
of the three assertions; an S15 check whose `case` catch-all reported ok on any
error not containing "permission denied"; `res=$(notify_probe ...)` aborting
the run under `set -e` on a failing DDL; and a comment claiming `CREATE SCHEMA`
reports no object identity, which it does. What the review could not make
work - filtering the `GRANT`/`REVOKE` half of the label churn - is **S18**.

## P11 (2026-09-04): `searchable` toggles stopped rewriting the whole table

The row as it stood in the open items:

| ID | Priority | Area | Where | Problem | Fix | Done when |
|---|---|---|---|---|---|---|
| P11 | Info | migration | `0070_dd_functions.sql` (`searchable` toggle) | Toggling `searchable` drops and re-adds a GENERATED STORED tsvector column plus GIN index: a full rewrite under ACCESS EXCLUSIVE, 652 ms per 100k rows, linear. | Document the lock; optionally defer to statement end so several toggles rewrite once. | Documented, or one rewrite per statement. |

Scope chosen by the owner on 2026-09-04: skip the unnecessary rewrites, coalesce
the necessary ones to one per statement, and document the lock. The
non-blocking route was offered and deliberately not taken.

| What changed | Where | Verified by |
|---|---|---|
| `update_search_vector_column` returns without any DDL when the expression it would generate matches the one already installed and the GIN index is still present. The comparison is an md5 fingerprint of the generated text, stamped into the `search_vector` column comment. It cannot be made against `pg_get_expr()`: PostgreSQL deparses the stored expression with casts of its own (`'simple'::regconfig`, `'A'::"char"`), so the deparsed form never matches what the function builds and the guard would never fire. | `0070_dd_functions.sql` | `0150` "toggling searchable on a non-text field should not rebuild search_vector" |
| The no-searchable-fields path also returns early when there is no column to drop. `ALTER TABLE` takes ACCESS EXCLUSIVE before it evaluates `IF EXISTS`, so a drop that matches nothing still blocked the table for the rest of the transaction. | `0070_dd_functions.sql` | not separately pinned: the reachable cases are unmanaged tables and core tables with no searchable fields, where `0150` only asserts the absence of the column either way |
| The row-level `handle_field_searchable_change_trigger` became three statement-level triggers (`_insert_`, `_update_`, `_delete_`) over one shared `apply_field_searchable_change(TEXT[], TEXT[])`. One trigger per event because a trigger with transition tables may only be defined for a single event. A statement now rebuilds a table once however many of its fields it touches. | `0070_dd_functions.sql` | `0150` "two searchable fields added in one statement should rebuild search_vector once" and "both fields added in the coalesced statement should be searchable" |
| The update path compares the *set* of searchable field names per table across the whole statement rather than pairing old rows with new ones. That catches one field being switched off while another is switched on, and needs no join key: `fields.id` is generated from `table_name` and `field_name`, so it moves when a field is renamed. | `0070_dd_functions.sql` | the existing `0150` multi-row `UPDATE fields SET searchable = FALSE` assertions |
| A latent ordering bug went with it. AFTER STATEMENT triggers run after all AFTER ROW triggers, so the tsvector expression is now always built after `add_field_trigger` and `update_field_trigger` have applied their DDL. The row-level version relied on trigger name ordering and only got it right for `add_field_trigger`: `update_field_trigger` sorts after `handle_field_*`, so an UPDATE changing both `format` and `searchable` built the expression against the pre-`ALTER` column. | `0070_dd_functions.sql` | by construction |
| The ACCESS EXCLUSIVE lock written down, with the per-row cost and the fact that a rewrite also rebuilds every index on the table. | `AGENTS.md` | n/a |

Measured on `pgdocker/pg-cli-retest.sh`: 2,094 assertions green, against 2,091
on a clean tree at the same commit minutes earlier - the delta is exactly the
three new ones. The three assertions count dropped-attribute placeholders in
`pg_attribute`, which is a direct count of full table rewrites: a rebuild drops
and re-adds `search_vector` and leaves one behind, a skipped rebuild leaves
none.

**Not done, deliberately.** A rebuild that really is needed is still
`ADD COLUMN ... GENERATED ... STORED`: a full heap rewrite under ACCESS
EXCLUSIVE, about 650 ms per 100k rows and linear, that also rebuilds every
index on the table. Removing that needs a plain `tsvector` column with a
maintenance trigger, a batched backfill outside the `fields` trigger
transaction, and `CREATE INDEX CONCURRENTLY` from a job - which makes
`search_vector` writable and leaves full-text search eventually consistent
after a schema edit. That route stays unbuilt.

**Residue.** The three new functions shifted `pg_proc` heap order and broke
`0290_owner_hardening.sql`, whose ownership loop has no `ORDER BY` and whose
`ALTER`s are observed by the DDL audit event trigger. Fixed in the same change
by granting EXECUTE on `audit.current_user_id()` to `semantius_owner` before
the loop; the loop is still order-dependent in principle and is open item
**S19**.

## P3 (2026-09-05): the warm permission check stopped resolving the caller twice

The row as it stood in the open items:

| ID | Priority | Area | Where | Problem | Fix | Done when |
|---|---|---|---|---|---|---|
| P3 | High | migration | `0030_rbac_functions.sql` (`uid`, `ensure_context_initialized`, `has_permission`) | Every `has_permission` runs `rbac.uid()` twice, and each `uid()` issues two SPI queries (`SELECT system_user INTO`, `_settings` read). Measured: `has_permission` 26.6 us per call, `uid()` 8.0 us, `ensure_context_initialized` 14.4 us, the cache check itself 0.4 us. | Test `app.context_initialized` before calling `uid()`; drop the redundant `PERFORM rbac.uid()` in the checkers; `v := system_user` instead of `SELECT ... INTO`; cache the validated sub per transaction. Coordinate with the bearer-mode signed cache in `docs/bearer-mode-status.md`. Absorbs the rbac part of Q2. **Owned by `plans/perf-hot-paths.md`**. | `has_permission` at about 5 us per call (from 26 us), re-measured per Appendix B. |

**Measured: 17.9-19.4 us -> 2.0 us per warm call**, about 9x, which clears the
5 us done-when. The absolute baseline is lower than the review's 26.6 us because
this is different hardware; the *structure* the review described reproduced
exactly (`has_permission` 17.02 total, its own body 4.88, `ensure_context_initialized`
8.64, `uid` 3.40 x 2 calls, `is_bearer_session` 1.19). The baseline was taken
twice - once on the database as found, once after stashing the change and
rebuilding from scratch - so the comparison is like-for-like. Method is
Appendix B: `track_functions = all`, a PL/pgSQL loop of 20,000 calls inside a
rolled-back transaction, read back from `pg_stat_xact_user_functions`.

Call counts per 20,000 warm checks, which is the part that cannot be timing noise:

| | before | after |
|---|---|---|
| `ensure_context_initialized` | 20,001 | 1 |
| `uid` | 40,005 | 3 |
| `is_bearer_session` | 20,001 | 0 |

| What changed | Where | Verified by |
|---|---|---|
| The cache test is inlined into `has_permission` and `has_any_permission`, which now read the three settings themselves and call `ensure_context_initialized()` only on a miss. A warm check enters one PL/pgSQL frame instead of two; the second frame was most of what the call cost, because a SECURITY DEFINER plpgsql entry with a `SET search_path` save/restore is expensive relative to a `current_setting` read. | `0030_rbac_functions.sql` | `0446_test_rbac_hot_path.sql`: both checkers mention `app.context_initialized` in `prosrc`. Before the change neither did, so this is the assertion that fails on revert. |
| The bearer-session test is the bare `system_user LIKE 'oauth:%'` rather than a call to `rbac.is_bearer_session()`. That function pins `search_path`, which stops PostgreSQL inlining it, so it cost a real function call on every check. The function stays: `whoami` reports through it and `0435` pins it. | `0030_rbac_functions.sql` | `0446`: `is_bearer_session` still exists and is false in a SCRAM session |
| `ensure_context_initialized` no longer opens with a redundant `PERFORM rbac.uid()`. Both of its branches fell through to `v_external_id := rbac.uid()` regardless, so the leading call was pure duplication rather than something to be moved. | `0030_rbac_functions.sql` | measured: `uid` calls per 20,000 checks fell from 40,005 to 3 |
| The warm shortcut now also requires `app.current_external_id` to be non-empty and to equal `request.jwt.claim.sub`. This is **not** a fix for the client-writable cache (S2) and buys nothing in a supported deployment, where the client never runs SQL and cannot write `app.*` at all. It replaces a side effect of the removed `rbac.uid()` calls: those refused a session carrying no valid claims, and the comparison keeps that refusal. Sound because both settings are transaction-local and written by the same cold pass - the Neon path returns the setting verbatim, the Supabase fan-out writes it before re-reading, the PG18 override rewrites it, and both `get_userinfo` prefills assign `rbac.uid()`. | `0030_rbac_functions.sql` | `0446`: a cache naming another subject is rebuilt and denied, by `has_permission` and `has_any_permission`, with a genuine warm hit as the positive control; and a session with no claims plus a hand-written cache raises 42501 |
| `v_system_user := system_user` instead of `SELECT system_user INTO` in `uid()` - the one real Q2 site in `rbac`. | `0030_rbac_functions.sql` | n/a (Q2 decremented to 15) |
| `app.oauth_scopes` separators normalized: any run of commas or whitespace separates, in all three GUC readers and in `validate_oauth_scopes`' request parameter. Previously `has_permission`/`has_any_permission` read commas and `user_has_permission` read spaces, so a list in the "wrong" format silently confined the session to nothing. Inlined rather than given a helper because `0240` requires every function to pin `search_path`, and a pinned `search_path` blocks inlining - the same trap as `is_bearer_session`. Cannot escalate: scopes only subtract, the permission has already been matched against the caller's own set before the scope test runs. | `0030_rbac_functions.sql` | `0405` GROUP 6, eleven assertions across all four readers with negative controls; verified to fail under the old readers before the change |

**Two things the owning plan asked for and did not get, deliberately.**

- The plan wanted `PERFORM rbac.uid()` deleted outright from the checkers, which
  costs the `0060_test_security.sql` guard: it would have had to accept
  `rbac.ensure_context_initialized()` as a substitute for a direct `rbac.uid()`
  call, for every SECURITY DEFINER function in `public` and `rbac`, forever -
  and that substitute is weaker after this change, because
  `ensure_context_initialized` now returns early on a warm session. Instead the
  call was kept on each checker's input-validation branch, which is never hot.
  Behavior is therefore unchanged for a blank permission name (an
  unauthenticated caller still gets 42501, not FALSE) and **`0060` needed no
  edit at all**.
- `get_current_user_permissions` was left alone: it has no validation branch to
  host the call, it is an RPC rather than a per-row path, and it is not named in
  P3's done-when. It gets the forged-cache protection anyway, through
  `ensure_context_initialized`, which carries the same subject test - verified.

**Residue.** `require_permission` and `require_any_permission` still open with
`PERFORM rbac.uid()` and so still cost about 14 us. They are outside P3's
done-when, which names `has_permission` only, but anyone re-measuring should
measure the right function. Not tracked as a new row.

**Read the 9x as what it is: per call.** The RLS policies in `0050_rbac_rls.sql`
invoke the checker as `(select rbac.has_permission('admin'))`, and the
sub-select makes it an InitPlan the planner evaluates once per query rather than
once per row. So table RLS was never paying 17.9 us per row and does not now
save 15.9 per row. Where the per-call figure is actually collected is everywhere
the check is *not* hoisted: the generated per-row rule predicates, the checkers
called from inside PL/pgSQL loops, and direct calls from application code and
RPCs. This does not reduce the change - the same reasoning is why P7 wants the
checkers to stay hoistable - but the headline number is a per-call one and
should not be quoted as a per-row throughput gain.

## P12 (2026-09-05): the JsonLogic interpreter stopped querying the database to read a JSON key

The row as it stood in the open items:

| ID | Priority | Area | Where | Problem | Fix | Done when |
|---|---|---|---|---|---|---|
| P12 | High | migration | `0210_raci.sql` (`evaluate_json_logic`, the installed CREATE OR REPLACE at :380-1020) | Identifying a node operator costs two SQL round trips (`:430-431`): a `SELECT ... FROM jsonb_object_keys` and a `SELECT count(*)` over the same set-returning function. Neither qualifies for PL/pgSQL simple-expression evaluation, so both go through full SPI - four executions per row for a two-node rule, plausibly 30-50% of the 51 µs interpreter cost. Reaches every caller: select_rule policies, generated validation triggers and RACI gates. | Identify the operator with one non-SPI expression (`jsonb_path_query_first`), keeping an explicit zero-key guard for the `{}` rule. Do not reorder the operator IF-chain and do not convert it to CASE - `exec_stmt_case` walks its WHEN list linearly too. **Owned by `plans/perf-hot-paths.md`**. | `evaluate_json_logic` issues no SQL round trip to identify a node operator, and one node is 30-50% cheaper, re-measured per Appendix B. |

Closed at the lower edge of its band, deliberately and on the record: **5.6-5.9
-> ~4.0 us per node, 29.0-30.8% cheaper, median 30.3% over eight samples.** The
30-50% figure in the done-when was always an estimate ("plausibly 30-50% of the
interpreter cost"); the real distribution of that cost is now known and is
written down below, so the row closes on measurement rather than on the guess.

Method: the pre-change body extracted from git, renamed together with its 27
recursive call sites, and run interleaved with the new one inside a single
transaction - 480,000 calls each - so machine load could not favor either. An
earlier attempt across separate transactions gave 12% and 31% and was discarded
as noise. A dispatch variant that briefly showed 3.01 us was discarded too: its
call count was 80,008 where every other variant showed 320,016, which is what
exposed that its recursion was not landing on itself.

| What changed | Where | Verified by |
|---|---|---|
| Operator identification is one non-SPI expression. `jsonb_path_query_first(rule, '$.keyvalue().key')` reads the key in the same order `jsonb_object_keys` returned it, and `rule - op` leaves `'{}'` exactly when that key was the only one. It replaces `SELECT key INTO op FROM jsonb_object_keys(rule) LIMIT 1` plus a second `SELECT count(*)` over the same set-returning function: both had a FROM clause, which disqualified them from PL/pgSQL's simple-expression path, so each went to the SQL engine to be planned and executed - four executions per row for a two-node rule. | `0210_raci.sql` and `0015_jsonlogic.sql` | the 290-case corpus, `0016_test_jsonlogic_ext.sql`, `0350_test_raci.sql` |
| An explicit NULL guard for the zero-key rule. `{}` yields no key, and without the guard the next line evaluates `rule -> NULL`. Verified load-bearing rather than assumed: rebuilt without it, `{}` raises `Unrecognized operation: <NULL>` instead of passing through. | both copies | new corpus case `[{}, {}, {}]` |
| The 12 operators that must run before the depth-first argument evaluation - the ones that short-circuit or bind their own scope - are wrapped in a single `op = ANY(ARRAY[...])` guard. The dispatch is 44 separate `IF op = '...'` statements, not an ELSIF chain, so every ordinary operator used to evaluate 12 dead statements before it could match, on every node of every rule on every row. No operator moved and no body changed. This is what took the figure from 25-29% to ~30%. | both copies | all 12 guarded operators have coverage (10 in the corpus, `let` and `set_record` in `0016`/`0350`), so one dropped from the list fails as `Unrecognized operation` |
| Both copies were fixed, not just the installed one. `0015` creates the function and `0210` replaces it with an extended version, so only `0210` runs - but leaving `0015` slow is a trap for whoever reads or measures the wrong one. | `0015_jsonlogic.sql` | n/a |
| A multi-key passthrough case was added alongside the `{}` one. The change swaps "count the keys" for "remove the key and see what is left", and multi-key is where those differ most in kind. Neither case existed anywhere in the 288-case corpus, which is now 290. | `0015_test_jsonlogic.json` | regenerated with `deno task testgen_jsonlogic` |

**Measured and declined.** Reordering the operators within the dispatch: 0-2%,
inside the noise, against a diff that churns the whole file. The owning plan
predicted this and was right, though it attributed the cost to the wrong thing -
the expense is the 12 dead statements ahead of the barrier, not the position of
any one operator behind it. Dropping the function's `SET search_path`: a real
~5%, refused because `0240` requires every function to pin one and that guard is
not worth five percent.

**Where the floor is.** What remains per node is the PL/pgSQL frame, the jsonb
operand handling, and the operator's own work. Past roughly 35% the floor is
PL/pgSQL itself: multiples rather than percentages need either C, which would end
this extension's pure-SQL portability, or not running the interpreter at all for
recognizable rule shapes - which is **P2**, and is where the order-of-magnitude
actually lives.

## B19 (2026-09-05): the install paths stopped disagreeing about line endings

Opened and closed the same day, during the P3/P12 work that exposed it. Recorded
here rather than dropped, because the failure mode is invisible by construction
and worth knowing about.

**What was wrong.** A PL/pgSQL function body is stored verbatim in
`pg_proc.prosrc`. The `.sql` files are LF in the repository and CRLF in a Windows
working tree - `core.autocrlf` is true and there is no `.gitattributes` - and two
of the three loaders passed the file through untouched. So the same migration
installed a textually different database depending on who ran it: **129 of 260
function bodies contained carriage returns after `deno task migrate`, and 0 after
`CREATE EXTENSION`.** The generated bundles carried them too - 17,362 CR bytes,
measured by reverting the fix.

**Why that is not cosmetic.** Anything written across a line break, or any
character class, means one thing on one checkout and another on the next, and no
machine can see the difference because each one only ever builds one of the two.
It had already happened: a scope-separator `btrim` was written with its character
set typed literally into the source instead of escaped, so the CRLF path trimmed
carriage returns and the LF build did not, and `rbac.validate_oauth_scopes`
returned a different number of rows on the two paths. Both suites were green.
Caught in review, before it was committed.

| What changed | Where | Verified by |
|---|---|---|
| Migration text is normalized to LF as it is read, so every path that feeds SQL to PostgreSQL agrees. `extension.ts` already did this at `toLf`, added earlier so a local build and CI would hash identically; the other two loaders did not. | `packages/cli/commands/migrate.ts`, `scripts/bundle-sql.ts` | 129 -> 0 carriage returns in `pg_proc.prosrc` after a full migrate; 17,362 -> 0 CR bytes in the generated bundles |
| A guard so it cannot come back: no function body in the Semantius schemas may contain a carriage return. It runs on both install paths, which is what makes it meaningful - the property it asserts is that the two agree. | `0240_test_no_unsafe_functions.sql` | green on `pg-cli-retest.sh` and `pg-ext-retest.sh`, 2130 assertions |
| The scope readers keep their own tripwire regardless: tab, CRLF and trailing-carriage-return inputs, and the `validate_oauth_scopes` row count that actually diverged. | `0405_test_rbac_helpers.sql` | the trailing-CR assertion returns 1 row under the fixed code and returned 2 under the old LF build |

**Both halves, and why neither alone is enough.** `.gitattributes` pins the
working tree - `* text=auto eol=lf`, with `.cmd`/`.bat`/`.ps1` kept at CRLF
because cmd.exe is unreliable with LF-only batch files. Every blob in the
repository was already LF, so it cost no content change; a fresh checkout of a
migration now yields 0 carriage returns where the tree held 1,249. That is the
origin of the defect and it is now shut.

It is still not sufficient on its own. It governs checkouts of this repository
and nothing else: an existing tree keeps its CRLF until the files are checked out
again, and a consumer who gets the SQL from the extension tarball, from a
published `migrations-bundle.ts`, or from an editor that saves CRLF is outside
its reach. The loader normalization is what makes the guarantee unconditional at
the boundary that matters - the text handed to PostgreSQL - and it is what makes
the `0240` assertion true on a tree that predates this change. The two are
complementary: `.gitattributes` keeps carriage returns out of the source so
nobody can type one into a character class by accident, `toLf` keeps them out of
the database whatever the source turned out to be.

## P13 and P4 (2026-09-05): the statement-constant work moved out of the per-row path

Two rows, one change, closed together because they are the two halves of it:
P13 hoisted the request context out of the generated RLS predicate, P4 moved the
audit and queue triggers off FOR EACH ROW.

The rows as they stood in the open items:

| ID | Priority | Area | Where | Problem | Fix | Done when |
|---|---|---|---|---|---|---|
| P13 | High | migration | `0180_computed_validation.sql` (`build_select_rule_policy`) | The generated `select_rule_<t>` predicate calls `ensure_context_initialized()` and rebuilds `$today`/`$now`/`$user_id` once per row — on the read path (`0180:340-349`) and on both write paths, since the same helper is embedded in the UPDATE/DELETE quals (`0180:387-392`). 14 µs of the ~68 µs per-row total. | Resolve it once per statement: a `jl_request_context()` helper reached through an uncorrelated sub-select so the planner makes it an InitPlan, passed into a two-argument form of the generated predicate. Split out of P2 on 2026-09-04. **Owned by `plans/perf-per-statement.md`**. | The context is resolved once per statement, not once per row — asserted structurally, because a timing figure alone cannot distinguish the two — and one rule row costs about 54 µs, from about 68. |
| P4 | High | migration | `0150` (audit), `0170` (queue), `0180` generated validators | Three FOR EACH ROW triggers each do statement-constant work per row (`primary_key_columns` catalog query, `pgmq.send` dynamic SQL, JsonLogic evaluation). INSERT 10k rows: plain 65 ms; audit 1.5-2.0 s; queue 0.8-1.0 s; validation 0.7-1.1 s; all three 4.25 s. Floors: set-based audit insert 497 ms, `pgmq.send_batch(10k)` 114 ms. | Statement-level triggers with transition tables: one `INSERT ... SELECT` for audit rows, one `pgmq.send_batch(queue, array_agg(...))` for queue events; build `$old`/`$now` only when the rule references them. **Owned by `plans/perf-per-statement.md`**, including the `$old`/`$now` conditional build. | 10k-row INSERT with all three triggers at about 1.0-1.3 s (from 4.25 s). Reachable only if the interpreter work lands first; it did on 2026-09-05 and took about **30%** off a node (29.0-30.8%, median 30.3), the lower edge of the estimated 30-50% (see P12), so the validator component improves by correspondingly less than this row assumed. Re-derive the target before treating it as measured. |

Both are closed **restated**, because both done-whens were arithmetic against
baselines that P3 and P12 had already cut. The endpoints below were re-measured
on 2026-09-05; the originals stay above so the drift is visible rather than
quietly overwritten.

### P13 - the context is resolved once per statement

Structural, which is what the row insisted on: `public.jl_request_context()` is
reached through an uncorrelated sub-select in all three generated policies, and
the planner lifts it to an InitPlan. `EXPLAIN (ANALYZE, VERBOSE)` on a 500-row
rule-bearing table shows the InitPlan at `loops=1` for SELECT, UPDATE and DELETE
alike, and the scan filter reads `select_rule_x(x.*, (InitPlan N).col1)`. UPDATE
carries three InitPlans because the SELECT policy applies alongside the UPDATE
policy and the planner does not merge them - a constant per statement, not per
row.

**The assertions bind.** A test that passes both before and after a fix is
worthless, and this row's wording exists to guard against exactly that, so the
pins were broken deliberately: emitting a bare call fails `0445` #6 and #8 and
`0447` #16; restoring the whole pre-change one-argument generator verbatim from
git fails `0445` #8-#9 and `0447` #9, #10, #11, #13, #14, #16. A caution for
anyone repeating that: the pgTAP harness sets `search_path = pgtap, public`, so
an unqualified `CREATE OR REPLACE FUNCTION` in a mutation lands in `pgtap` and
mutates nothing.

**Timing, re-measured.** Same transaction, interleaved, 100k rows, the
pre-change predicate body recreated verbatim alongside the shipped one:

| form | µs/row |
|---|---|
| context rebuilt per row | 20.95 |
| context hoisted to an InitPlan | 17.21 |

**-17.9%.** The row asked for "about 54 µs, from about 68". Neither figure
survives: 68 traces to the original P2 measurement taken *before* P3 and P12
landed, and 54 was 68 minus 14. The proportion is what carried over, and it
matches the owning plan's own estimate of 10-13%.

**Scope.** P13 covers the generated `select_rule_<t>` predicate and the policies
that call it. The BEFORE ROW compute/validate trigger still resolves its context
per row and is deliberately untouched - a trigger has no InitPlan to hoist into,
so there is nothing to do there. Read globally, "the context is resolved once per
statement" is a claim about the policies only.

**The largest win is one the row never asked for.** In a PostgreSQL 18 OAuth
bearer session `ensure_context_initialized` re-derives on every call rather than
reading the transaction cache, so a rule-bearing scan went from roughly a
millisecond *per row* to a millisecond *per statement*.

### P4 - audit and queue moved to statement level

10k-row INSERT into a fresh table carrying all three triggers, both arms
alternating inside one transaction with only the trigger mechanism swapped:

| | run A | run B |
|---|---|---|
| row-level triggers | 1.62 s | 1.60 s |
| statement-level | 0.70 s | 0.66 s |

**A 57% cut, reproduced twice.** A separate measurement across two databases
built from the two code states gave 2.3-2.5 s -> 0.89-1.14 s; the absolutes
differ with catalog size and cache warmth, the ratio does not (39-46% against
43%).

Per family, 10k rows, against a managed-table floor of 26 ms:

| family | row-level | statement-level |
|---|---|---|
| audit | 894 ms | 317 ms |
| queue | 336 ms | 128 ms |
| validator | 396 ms | 422 ms |

Trigger invocations on 2000 rows, which is the structural evidence rather than
the timing: INSERT goes from audit 2000 / queue 2000 to audit **1** / queue
**1**, and DELETE likewise. UPDATE keeps its per-row audit trigger by design.

**The row's own baseline is not reproducible.** It cites 4.25 s against a 65 ms
plain-table floor; this host's floor is 10-31 ms, so it is several times faster
and the 1.0-1.3 s band would be cleared partly by hardware. Applying the measured
57% to 4.25 s lands near 1.8 s, above the band - but 4.25 s is itself a
pre-P3/P12 number, so that arithmetic settles nothing either. The row closes on
the measured before and after, not on its stated band.

### What P4 named and this change did not solve

The row names three per-row costs. Two are gone:

- the `primary_key_columns` catalog query, now a DECLARE-section default
  evaluated once per statement - **except on UPDATE**, where `audit_i_u_d` stays
  row-level so the query stays per row;
- the `pgmq.send` dynamic SQL, now one `send_batch` per window of 1000. At
  128 ms per 10k rows this is essentially the 114 ms floor the row itself cites.

The third is untouched: **`evaluate_json_logic` still runs once per row**, and
the validator is now the single largest component of the remaining cost, about
396 ms of the ~700 ms all-three total. Only the `$old`/`$mode` context build
became conditional, and on the INSERT benchmark this row is stated against that
is a wash (419 vs 422 ms), because `$old` is null there anyway. Making the
interpreter per-statement is not possible in a BEFORE ROW trigger; not running it
at all for recognizable rule shapes is **P2**.

**The residual inside the validator, for whoever picks it up.** Per call on this
host: `ensure_context_initialized` 1.93 µs, `uid` 3.63, `user_id` 7.51,
`user_id_or_null` 11.57, `jl_request_context` 13.78. The owning plan costed a
substitution of `user_id_or_null` for a context helper at ~260 ms per 10k rows
and dropped it after measuring; the measurement understated how wrong the idea
was, because the helper is *dearer per call* than the lookup it would replace -
that step would have made the validator slower. What is genuinely available is
replacing `user_id_or_null` with `ensure_context_initialized` plus a settings
read, worth roughly 9.6 µs/row, about 96 ms at 10k, some 14% of the post-change
total. It needs its own measurement and its own decision.

### Accepted, and recorded here rather than discovered later

| What | Why it is accepted |
|---|---|
| An upsert's audit rows no longer interleave by id. `INSERT ... ON CONFLICT DO UPDATE` writes its UPDATE rows during execution and its INSERT rows at end of statement. | Content is preserved and both ops are logged; only the ordering within one statement changes. Pinned by `0300_test_audit_log.sql`. |
| Audit rows for a *nested* statement carry lower ids than the rows for the statement that caused them, because `ts` defaults to `now()` (transaction start) and a row trigger fires before a statement trigger. | Reordering the evidence table means changing `ts` to `clock_timestamp()`, a schema change with its own trade-offs. Recorded, not fixed. |
| `enable_tracking` skips a trigger that already exists by name, so changing the shape of `audit_i`, `audit_d` or `audit_t` reaches only tables that do not yet carry it. | Fresh installs only; this project ships no upgrade scripts. An existing table needs `disable_tracking()` first, and the function says so. |
| A statement trigger on a *leaf* partition does not fire for rows routed through the root. | Audit the root. The limitation an earlier draft was going to record - that transition tables are rejected on partitions - is **false** for statement triggers, and was removed rather than written down. |
| Two to three times more `audit_ddl_logs` rows per managed table, because `enable_tracking` now issues four `CREATE TRIGGER`s and the queue up to three. | Partly offsets `plans/audit-ddl-noise.md`. Scoping the event trigger further is a separate change. |
| `plpgsql_check` reports six new never-read variables that are in fact live. It cannot resolve a transition table, so it skips the statements that read them. | Inherent to statically checking transition tables. Tracked under **Q5**, which now says so. |

### Two defects found and fixed inside this change

- **A fail-open in the conditional `$old`/`$mode` build.** The first
  implementation decided whether to build them by searching the rule text for
  the variable name. The interpreter evaluates a `var`'s argument, so
  `{"var":{"cat":["$mo","de"]}}` resolves to `$mode` with the name nowhere in
  the text, and a delete guard such as `{"!=":[{"var":"$mode"},"delete"]}`
  silently began permitting deletes. `$mode` is now always built, and an
  object-valued `var` counts as an `$old` reference. Pinned by four assertions in
  `0448_test_statement_triggers.sql`.
- **A pre-existing leak in queue teardown.** The old delete path dropped only the
  trigger named for the mapping's current handler, so narrowing a handler from
  `change` to `delete` and then deleting the mapping stranded a live trigger
  enqueuing to a queue it was no longer mapped to. Every event name is now
  dropped.

### Pinned by

`0447_test_request_context.sql` (16 assertions, new),
`0448_test_statement_triggers.sql` (25, new),
`0445_test_policy_initplan_form.sql` (extended to sweep for a bare
`jl_request_context`), `0300_test_audit_log.sql`, `0310_test_queue.sql`,
`apps/nwind/tests/0020_test_nwind_schema.sql`, and a check in
`pgdocker/pg-ext-retest.sh` that audit rows written after `0270` carry
`order_column` - the single-transaction install being the only place a column is
added to an audited table between two writes to it.

## P2 (2026-09-05): scope-changed — shape recognition rejected, named operators adopted

The row as it stood in the open items:

| ID | Priority | Area | Where | Problem | Fix | Done when |
|---|---|---|---|---|---|---|
| P2 | High | migration | `0180_computed_validation.sql` (`build_select_rule_policy`) | Even with the request context hoisted (P13), the generated per-row predicate still builds `to_jsonb(row)` and runs `evaluate_json_logic` for every row scanned, and is opaque to the planner, so a rule column can never be used as an index condition. | Recognize known rule *shapes* and emit an equivalent native SQL predicate into all three policies, keeping the generated function as the fallback for anything unrecognized. A general JsonLogic-to-SQL compiler was considered and rejected. **Owned by `plans/select-rule-native-predicates.md`**, which opens with a go/no-go. | 100k-row scan under a recognized shape at about 20 ms with the rule column used as an index condition — or the row closed as scope-changed against the measured post-P13 baseline, which is **17.21 us per rule row** (from 20.95 before the context was hoisted), with the accepted scale limit recorded. |

**Closed as scope-changed, not as done.** The problem is real and confirmed by
measurement; the *fix* the row prescribed was rejected on review. The work itself
continues under **P14**, by a different mechanism. `plans/select-rule-native-predicates.md`
is superseded and marked as such rather than deleted, because its rejection
analysis is the reason P14 looks the way it does.

### The go/no-go measurement the plan asked for

Taken 2026-09-05 on `postgres18-cli` (PG18, post-P13 schema), 100k-row table,
`user_id` over 50 users so the caller owns 2,000 rows (2%). The helper was a
byte-for-byte copy of what `build_select_rule_policy` generates for the shipped
`user_bookmarks` rule. Everything ran inside one rolled-back transaction; second
of two runs; `EXPLAIN (ANALYZE, TIMING OFF)`.

| Query | Interpreted (today) | Native | Native + index |
|---|---|---|---|
| Full scan, variant 1 `{"==":[{"var":"col"},{"var":"$user_id"}]}` | **4,693 ms** | **7.9 ms** | **1.1 ms** |
| `count(*)`, variant 1 | 4,546 ms | 8.8 ms | 0.8 ms |
| Full scan, variant 2 `{"or":[{"has_permission":...},...]}`, non-holder | 5,404 ms | 8.2 ms | 6.7 ms (no Index Cond) |
| Full scan, variant 2, permission holder | 2,229 ms | 6.0 ms | — |
| `LIMIT 20`, page 1 | 33 ms | 0.2 ms | — |
| `OFFSET 1980 LIMIT 20` | **3,182 ms** | 6.8 ms | — |
| `ORDER BY title LIMIT 20` | **3,344 ms** | 8.2 ms | — |
| Floor, `USING (true)` | 4.6 ms | — | — |

Four things the measurement settled:

1. **The baseline did not fall the way the plan assumed.** The plan expected
   P3/P12/P13 to have taken this to 2.5-3 s and framed its trade-off against
   that. It is still **~4.7 s**: the per-row cost is dominated by the SECURITY
   DEFINER PL/pgSQL frame and `to_jsonb(p_row)`, which none of those three
   touched. End-to-end this is **~45 µs per row** against the 17.21 µs recorded
   in P13's closure, which measured the interpreter and not the frame around it.
2. **There is no cheaper mitigation.** With an index on the rule column present,
   the interpreted predicate still took **4,204 ms** and the index was ignored -
   `Seq Scan ... Filter: select_rule_bench_bm(...)`. Indexing, partitioning and
   ANALYZE are all inert against an opaque predicate.
3. **Both of the plan's variant-specific claims were right.** Variant 1 native
   becomes a real `Bitmap Index Scan ... Index Cond`. Variant 2 native with the
   same index present stays a sequential scan, as the plan predicted from
   `generate_bitmap_or_paths`.
4. **The plan's pagination argument was backwards.** It reasoned that under
   PostgREST everything is paginated, so only a full scan or `count(*)` is
   pathological. Page 1 is indeed cheap (33 ms), but **any sorted page, or any
   page past the first, costs ~3.2 s**, because a sort must see every visible row
   before returning twenty. The exposure is the ordinary UI grid, not a rare
   admin query.

### Why shape recognition was rejected

The plan's mechanism was a registry of recognizers, each matching one literal
rule shape by jsonb template equality, emitting native SQL for a match and
falling back to the interpreter otherwise. Rejected in favour of **named
operators** — a domain operator such as `is_owner`, implemented once in the
interpreter and emitted natively by the policy builder, on the model of the eight
custom operators the dialect already carries (`has_permission`,
`require_permission`, `set_record`, `value_changed`, `is_raci_actor`,
`has_consultation`, `is_match`, `throw_error`).

- **Almost the whole cost of the plan was proving equivalence**, and that burden
  exists only because a generic expression inherits the generic operators'
  coercion rules. The template-equality matching, the near-miss controls, the
  three-way differential, and the md5 drift tripwire over `jl_loose_eq` /
  `jl_to_number` / the `==` and `var` branches were all in service of proving
  that two independently-written predicates agree on cases nobody chose. A named
  operator is defined once and both implementations derive from that definition.
- **The plan's own deferred shape is the evidence.** It identified temporal
  validity (`{">=":[{"var":"col"},{"var":"$today"}]}`) as the obvious second
  shape and then deferred it, entirely because `>=` coerces both sides through
  `jl_to_number` — text rendering, `extract(epoch FROM txt::timestamp)`, and 0
  for null. A named `not_expired` operator resolving the column against
  `pg_attribute` has none of that. The shape was hard only because of the
  approach.
- **Performance becomes visible rather than accidental.** Under recognition,
  whether an entity is fast depends on whether its rule happens to match a
  template the author cannot see; rewording it silently costs 500x. A named
  operator is written on purpose.
- **The backwards-compatibility argument for recognition is thin here.** Exactly
  one rule ships (`user_bookmarks`, `0280:45`); the four variant-2 uses are test
  fixtures created and rolled back inside tests and do not exist in an
  installation.

### What this closure does not solve

The problem itself is untouched: an entity with a `select_rule` still degrades
linearly and unboundedly with row count, with no mitigation available to whoever
hits it. That is **P14**. Everything in the superseded plan about the column
lifecycle still applies to it and is not optional — naming a column inside an RLS
policy means `delete_dd_field`'s `DROP COLUMN ... CASCADE` (`0070:1164`) drops
the entity's policies and leaves RLS enabled with none, which returns zero rows
to everyone and raises nothing.

Two interpreter defects were found while probing the coercion path for this
decision and are filed separately as **B20** and **B21**.

Method and candidate-selection practice are written up in
[docs/jsonlogic-optimization-candidates.md](../docs/jsonlogic-optimization-candidates.md).
