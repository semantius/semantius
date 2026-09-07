# Plan: the lifecycle assertions and the lint that sees every trigger function

Written 2026-09-07 14:18, revised the same day after an independent review
(findings folded in; the review also ran read-only probes on the containers,
cited below as "verified"). Owns **B11**, **R7** and **Q6**, the three tooling
rows that need no new infrastructure: every assertion runs in the container
the harness already has up. Written while a second plan was open on the same
lifecycle script and the same set of trigger functions; that plan landed first
on 2026-09-07, closing S14, S17 and S18, so the coordination points marked
**sibling** below are now statements about what is already in the tree.

## Open items

**Owns, and therefore closes.**

| Row | Decision or scope | Done when |
|---|---|---|
| **B11** | **Decided 2026-09-07: accept the runtime guard.** The two CURRENT_USER grants stay in the generated script, skipped when the installer is a superuser, which the extension path always is. Of the two assertions the row asks for, **one already exists**: `pg-ext-lifecycle.sh:149-157` asserts on a second-database install that `postgres` holds no `semantius_user` membership and that `common`'s ACL equals `rbac`'s (the shape that catches 0012's grant without tripping on the owner entry 0290 materializes), and `:391-392` asserts after uninstall that `authenticated` is the only member. What is missing is the BYPASSRLS gate firing. | The BYPASSRLS gate has a lifecycle assertion that fails when the gate is removed or weakened; the grant-skip assertion at `:149-157` is named in the closure record as the existing pin. |
| **R7** | The four runtime assertions the lifecycle script does not make: the BYPASSRLS gate firing (B11), `0160_pgmq.sql`'s own header guard on the CLI path (B4), a failure-capable LF-normalization assertion (B13), and the superuser grant-skip, which turns out to exist already (see B11) and is only counted here. | Each of the three new assertions fails when the behavior it asserts is removed, seen once by hand and recorded. |
| **Q6** | The seven trigger functions the linter never sees. **Tried live on 2026-09-07** in `postgres18-cli` with plpgsql_check 2.10: `plpgsql_check_function_tb(fn, relid => t, oldtable => 'old_rows', newtable => 'new_rows')` lints `audit.insert_trigger`, `queue_build_record_json` and `handle_field_searchable_update` with zero findings, where the same call without the transition names returns `relation "new_rows" does not exist` as its one finding; `raci_emit_trigger_fn` lints with `relid` alone (its body uses only `TG_OP`, `TG_TABLE_NAME` and `to_jsonb(OLD)`, so any rowtype serves). So the fix is a repeatable lint invocation that passes those arguments, not a test binding. `pgmq.notify_queue_listeners` is vendored and unbound and is accepted. | A scripted lint run reports the six Semantius statement-level trigger functions and `raci_emit_trigger_fn`, and names `pgmq.notify_queue_listeners` as the one PL/pgSQL function it skips, with the reason. |

**Touches without owning.**

| Row | Effect here | Owner |
|---|---|---|
| **S18** (landed) | `audit.log_drop_event` is now in the tree, an event-trigger function. Verified: plpgsql_check 2.10 checks `event_trigger` functions with no `relid` (`audit.log_ddl_event`, `pgrst_ddl_watch`, `pgrst_drop_watch` each return 0 findings), so it is linted like the rest and needs no override. | closed 2026-09-07 |
| **S17** (landed) | Lifecycle 4b and the uninstall recipe have already been edited. This plan adds sub-steps 0, 7d and 8c and does not touch 4b. | closed 2026-09-07 |

Two closed rows are named because the assertions are theirs: **B4** (the pgmq
refusal, closed with the extension rebuild) and **B13** (LF normalization,
closed 2026-09-03). Neither reopens; R7 owns the assertions.

**Labels.** The script's existing `ok`/`bad` texts carry row ids in
parentheses (`:149`, `:447`, `:505`), and so do several migration comments.
`AGENTS.md` says user-facing text carries no tracking id. This plan adds no
new ones: every label below names the behavior, and the closure record maps
label to row.

---

## Step 1 — `pgdocker/pg-ext-lifecycle.sh`: the three assertions

All use the existing helpers (`ok`/`bad` `:52-53`, `check` `:54-56`, `psqlq`
`:62`, `psqlrun` `:68`, `newdb` `:69`, `dropdb_` `:73`) and the container that
is already running. The step list in the header comment (`:9-30`) gains the
new sub-steps; step 12's database list (`:672-674`) gains `life7d` and
`life8d`, and its file list (`:677`) gains `/tmp/0160.sql`.

### 1a. The BYPASSRLS gate fires

New sub-step **8c**, after the `ASSERT` grep at `:499-505`, which stays.

The gate at `0050_rbac_rls.sql:17-24` reads `rolbypassrls` for `current_user`
and raises 55000 when it is false. A superuser bypasses RLS regardless of the
attribute, but the gate reads the attribute, so a **superuser without
BYPASSRLS** is the role that trips it. It is also the realistic case:
`NOBYPASSRLS` is the `CREATE ROLE` default whatever else the role has, and
`postgres` in both harness containers shows `t|t` only because `initdb` set
it. That is why no install has ever hit the gate.

```
newdb life8d
psqlrun life8d "CREATE ROLE gate_probe SUPERUSER" >/dev/null 2>&1 || true     # roles are cluster-wide; a dead earlier run may have left it
psqlrun life8d "ALTER ROLE gate_probe NOBYPASSRLS" >/dev/null
psqlrun life8d "CREATE EXTENSION pg_semantius" >/dev/null
err=$(psqlq life8d "SET ROLE gate_probe; SELECT semantius.migrate()")
echo "$err" | grep -q 'does not have BYPASSRLS'        -> ok "a superuser without BYPASSRLS is refused by the 0050 gate"
echo "$err" | grep -q 'ALTER ROLE gate_probe BYPASSRLS' -> ok "  and the hint names the fix"
check "  and nothing was applied" "0" "$(psqlq life8d "SELECT count(*) FROM pg_namespace WHERE nspname IN ('common','rbac','audit','pgmq')")"
psqlrun life8d "ALTER ROLE gate_probe BYPASSRLS" >/dev/null
psqlrun life8d "SET ROLE gate_probe; SELECT semantius.migrate()" >/dev/null && ok "  and the same role installs once it has BYPASSRLS" || bad "..."
dropdb_ life8d
psqlrun postgres "DROP ROLE IF EXISTS gate_probe" >/dev/null 2>&1 || true
```

Why each line is shaped as it is:

- The hint is built with `quote_ident(current_user)` (`0050:22`), and
  `quote_ident('gate_probe')` is unquoted, so the grep is on `ALTER ROLE
  gate_probe BYPASSRLS` without quotes. The `RAISE` message and its HINT reach
  psql because `migrate()` re-raises with the inner hint preserved
  (`extension.ts:1109-1119`), prefixed by `migration _core.0050_rbac_rls
  failed:`; `does not have BYPASSRLS` still matches.
- The "nothing was applied" check is what makes the assertion honest.
  `migrate()` is a plain function (`extension.ts:1241-1247`, not a definer,
  step 8 pins that) that `EXECUTE`s every migration inside one call
  (`:1105-1106`), so a refusal in `0050` leaves no schema behind, and a gate
  that had been moved later or weakened to a `NOTICE` would leave `common`
  standing. Nothing before `0050` checks BYPASSRLS, and the role blocks in
  `0010`/`0011` are `IF NOT EXISTS`, so `gate_probe` reaches the gate.
- The last install proves the gate was the only refusal. `SET ROLE` to another
  superuser is allowed for a superuser; `migrate()`'s own `rolsuper` gate
  (`:1258`) passes.
- The role owns nothing after the database is dropped: `0290` moved every
  object to `semantius_owner`, and event triggers and default ACLs are
  per-database. `DROP ROLE IF EXISTS`, with the `|| true` shape `ext_probe`
  uses at `:489` and `:497`.

### 1b. `0160_pgmq.sql`'s own header guard fires on the CLI path

Step 7 (`:438-448`) proves `migrate()`'s pre-flight refuses a real pgmq. It
stages a stub `pgmq` extension (`:443-445`) and removes it at `:448`. The
header guard inside `0160` (`0160_pgmq.sql:7-22`) is never reached on that
path because the pre-flight raises first, and on the CLI path nothing tests
it. Move the stub removal below a new check, **7d**:

```
newdb life7d
psqlrun life7d "CREATE EXTENSION pgmq" >/dev/null
docker cp "$(cygpath -w "$REPO_ROOT/apps/_core/migrations/0160_pgmq.sql" 2>/dev/null || echo ...)" "$CONTAINER:/tmp/0160.sql" >/dev/null
err=$(docker exec "$CONTAINER" psql -U postgres -d life7d -v ON_ERROR_STOP=1 -f /tmp/0160.sql 2>&1 || true)
echo "$err" | grep -q 'installed in this database' -> ok "0160's own header guard refuses a real pgmq on the CLI path"
check "  and creates no pgmq schema" "0" "$(psqlq life7d "SELECT count(*) FROM pg_namespace WHERE nspname = 'pgmq'")"
```

The grep is on the phrase only `0160`'s message carries (`installed in this
database`, `0160:16`); `migrate()`'s message (`extension.ts:1277`) says `is
installed;` and would not match, so the assertion cannot pass by accident
through the pre-flight. Running the raw file with `psql -f` is the CLI path
in miniature: the header `DO` block is the first statement (`0160:12-22`),
the next is `CREATE TABLE pgmq.meta` (`:25`), so nothing before the guard can
fail first. The stub creates schema `pgmq_stub`, not `pgmq` (`:444`), so the
schema count is a real check. Use the `docker cp`/`cygpath` form of step 0
(`:111-112`).

### 1c. LF normalization is asserted in a way that can fail

Today the only guard is the release job's "committed build must equal the
regenerated one" (`extension-release.yml:209-217`), which catches a CRLF
regression only on a release tag and only as an unexplained diff.

**A byte grep on the generated files cannot be the assertion.** `.gitattributes`
is `* text=auto eol=lf`, so every migration is LF in the working tree even on
this machine's `core.autocrlf=true`; remove `toLf` (`extension.ts:71-74`) and
the generator still produces CR-free output from a CR-free tree. R7's done-when
is "fails when the behavior is removed", so the check has to hand the
normalizer a CRLF input itself.

Do it as a Deno test, the first one in the repository:

- Export `toLf` and `sha256hex` from `extension.ts` (both are module-private
  today, `:73`, `:412`).
- `packages/cli/commands/extension_test.ts`, two `Deno.test`s:
  1. `sha256hex(toLf("a\r\nb\rc"))` equals `sha256hex("a\nb\nc")`. Fails the
     moment `toLf` stops normalizing.
  2. The checksum in `extension/versions.json` for `_core/0010_create_core`
     equals `sha256hex(toLf(<file text>))`. Pins what the manifest hashes
     (verified: SHA-256 hex of the normalized text, no prefix, key without
     `.sql`, `extension.ts:193-200`, `:412-420`; the value today is
     `457467a1…`, which also equals `tr -d '\r' < 0010_create_core.sql |
     sha256sum`).
- Lifecycle step 0, after the `skip_audit` check (`:108`): run `deno test
  --allow-read packages/cli/commands/extension_test.ts` from `$REPO_ROOT` and
  turn its exit code into `ok`/`bad`. Deno is on the host, which is where the
  lifecycle script runs; the script already tells the user to run `deno task
  extension` at `:94`, so the dependency is not new.
- Keep two byte greps as pins, labeled as pins: `grep -c $'\r' "$SQLFILE"` and
  the same on `$CONTROL`, both expected 0. They do not fail when `toLf` is
  removed; they fail if a CR ever reaches the shipped files by another route.
  `grep -c $'\r'` works in this Git Bash (verified).

### 1d. Bookkeeping

Header step list gains `7d`, `8c` and the two step-0 lines; step 12 gains
`life7d`, `life8d` and `/tmp/0160.sql`. **Sibling:** step 11 already carries the
two drop assertions and 4b the extra trigger name; no overlap.

---

## Step 2 — a scripted lint that reaches every trigger function (Q6)

### 2a. Why a script and not a test binding

The row's first idea was to bind `raci_emit_trigger_fn` in a test. It already
is: `0350_test_raci.sql:560-564` flips `emits_events` and
`raci_install_or_drop_emit_trigger` (`0210:1215-1257`) creates the trigger,
inside a transaction that rolls back. The linter runs against the installed
schema, after the suite, where no trigger binds the function. A binding in a
test can never help the linter. What helps is the `relid` argument, which is
what a bound trigger would have supplied, and for the six statement-level
functions the `oldtable`/`newtable` arguments, which are the transition-table
names the `REFERENCING` clauses declare (`0070:1676-1692`, `0150:434-459`,
`0170:334-370`).

There is no lint script today; the invocation lives only in the appendix of
the open-items list and is run by hand. So "appears in the lint report" has
no repeatable meaning until the invocation is a file.

### 2b. `deno task lint-sql`

`deno task lint` already exists (`deno.json:14`, Deno's own linter over the
checkout), so the name is `lint-sql`, delegating to a new
`packages/cli/commands/lint_sql.ts` in the shape of `coverage.ts`: connects to
the CLI database, installs plpgsql_check into schema `extensions` if missing
exactly as `coverage.ts:443-466` does, runs one query, prints a report. Needs
a migrated database (`pg-cli-retest.sh` first).

The query:

- Every PL/pgSQL function in `public`, `common`, `rbac`, `audit`, `pgmq`
  (`prolang = plpgsql`, `prokind = 'f'`).
- For each, `relid`, `oldtable` and `newtable` come from **all** of its bound
  triggers: `min(tgrelid)`, `max(tgoldtable)`, `max(tgnewtable)` over
  `pg_trigger WHERE tgfoid = p.oid`. Aggregating rather than taking the first
  row matters: `handle_field_searchable_update` is bound with both names, but a
  function bound several times may declare a different table per binding.
- An override list at the top of the file, each entry with a one-line reason,
  for what no binding supplies:
  - `public.raci_emit_trigger_fn`: `relid => 'public.user_bookmarks'`. No
    trigger binds it in a fresh install (bindings appear when a gate sets
    `emits_events`); any rowtype serves, see the Q6 row.
  - `public.queue_build_record_json`: `oldtable => 'old_rows'`. Verified: the
    body reads both `new_rows` and `old_rows`, but every trigger bound at
    install time is an INSERT trigger carrying only `tgnewtable`
    (`queue_events_insert_on_orders`, `queue_raci_notify_insert_on_raci_events`),
    and with `newtable` alone the check returns `relation "old_rows" does not
    exist`. The DELETE binding that would supply `old_rows` is created only
    for entities that opt in.
  - `pgmq.notify_queue_listeners`: **skipped**, reason: vendored,
    byte-identical to upstream v1.11.1, unbound by design, re-linted only at
    the next re-vendor.
- `event_trigger` functions are checked with no `relid`; verified to work for
  the three that existed when this was probed (`audit.log_ddl_event`,
  `public.pgrst_ddl_watch`, `public.pgrst_drop_watch`) and therefore for
  `audit.log_drop_event`, which has landed since. They must not appear as
  skips.
- The call is `extensions.plpgsql_check_function_tb(oid, relid => ...,
  oldtable => ..., newtable => ..., security_warnings => true,
  performance_warnings => true, extra_warnings => true, compatibility_warnings
  => true)`, the appendix invocation plus the two new arguments.

Output, to stdout and to `coverage/lint.txt` next to the coverage reports
(`coverage/` is gitignored): one line per finding
(`schema.function:line level message`), a summary by schema, the **checked**
count, and the **skipped** list. Any skip not in the override list prints as
`unexpected skip:`. Exit code is always 0: the owner decided on 2026-09-05
that style warnings do not fail builds, and the file header says so. The
skipped list is the assertion Q6 needs, visible without being a gate.

### 2c. Documents

- `docs/test-coverage.md` gets a short "Lint" section: how to run, what the
  transition-table arguments are for, what the skipped list means, and that it
  is not a gate.
- The "Linter" line in the open-items appendix ("How to re-measure") is
  replaced by `deno task lint-sql`. The "Linter context for Q6" paragraph is
  deleted with the row.

### 2d. The count

Run it once on a migrated database and record the totals in the closure
record: findings outside `pgmq`, findings in `pgmq` (expected: the 32 accepted
ones), checked functions, skipped functions (expected: exactly one). The
previous counts (40 outside `pgmq` on 2026-09-05, never re-run after the
2026-09-06 volatility batch) are superseded by this run.

---

## Order, verification, closure

1. Step 1c first, because it is host-only: write the Deno test, run it, then
   break `toLf` locally and see it fail, then restore.
2. Step 1a and 1b on the ext container: `pgdocker/pg-ext-lifecycle.sh`, all
   green. Then the failure check for each, by hand: for 8c, run the sub-step
   against a scratch copy of the generated script with the gate's `RAISE`
   commented out; for 7d, run it against a copy of `0160` with the header
   block removed. Record in the closure which of the three were seen failing.
3. Step 2 on the CLI container after `pgdocker/pg-cli-retest.sh`.
4. Closure records for B11, R7 and Q6 in `plans/ext-solved-items.md`: the row
   as it stood, what changed, what pins it, what it does not solve. B11's
   record carries the decision, names `:149-157` as the existing grant-skip
   pin, and says the non-superuser branch of the two guards is unasserted
   because neither harness can install as a non-superuser. Q6's carries the
   live trials and the counts.
5. Delete the three rows, add B11, Q6 and R7 to the gaps list in the
   open-items header, delete this plan.

No commits without asking.
