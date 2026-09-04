# Plan: audit and NOTIFY noise (B5, P6, S15, R1)

Written 2026-09-03 for execution in a fresh session. Self-contained: everything
needed is here or named by file and line.

## Why these four are one change

They converge on a single 14-line function, `audit.log_ddl_event()` at
`apps/_core/migrations/0150_audit_log.sql:381-395`:

```sql
BEGIN
    v_user_id := audit.current_user_id();              -- S15 fails here
    FOR obj IN SELECT * FROM pg_event_trigger_ddl_commands() LOOP
        INSERT INTO public.audit_ddl_logs (...)         -- B5 needs a filter here
        VALUES (..., current_query());                  -- P6 needs this bounded
    END LOOP;
END;
```

- **B5** attacks the row *count* (temp tables, foreign schemas, `in_extension`
  objects are all logged; `NOTIFY pgrst` fires for foreign schemas).
- **P6** attacks the row *size* (`current_query()` stores the whole migration
  script per event: 1,580 `CREATE FUNCTION` rows averaging 272 KB = 86 MB,
  69% of a scratch database) and part of the count (19% of all DDL events are
  generated label-function churn).
- **S15** is the same function failing outright for the request role.
- **R1** has a lifecycle-script step blocked on B5, because it would pin
  behavior this change alters.

Fixing them separately means touching the same function four times and
rewriting the same test three times.

## Owner decisions already taken (2026-09-03)

1. **Option B, the scoped audit.** Restrict logging to the schemas Semantius
   owns. Rationale, in the owner's words: DDL in schemas that are not part of
   Semantius should never have been logged, so excluding it is the fix, not a
   loss of evidence. This was the one contested point — an earlier draft
   framed the restriction as a security regression; that framing was wrong.
2. **S15 by `SECURITY DEFINER`, not by granting.** See "S15" below.
3. Semantius-owned schemas are `public`, `common`, `rbac`, `audit`, `pgmq`.
   `public` stays in scope even though it can hold non-dictionary tables.

## Facts verified before writing this (re-verify if the tree has moved)

- `audit.log_ddl_event()` is **not** `SECURITY DEFINER`, while the other two
  audit triggers in the same file are. It is the odd one out.
- S15 reproduces exactly:
  `SET ROLE semantius_user; CREATE TEMP TABLE t(id int);` →
  `ERROR: permission denied for function current_user_id`
  `CONTEXT: PL/pgSQL function audit.log_ddl_event() line 6 at assignment`.
  The failure happens on the *call*, so the function's own
  `EXCEPTION WHEN OTHERS THEN RETURN 0` cannot catch it.
- **B5's problem statement is partly wrong.** `pgrst_ddl_watch` and
  `pgrst_drop_watch` (`0090_notify_triggers.sql:99-150`) *already* filter by
  command tag and by `pg_temp` / `is_temporary`. What they lack is a **schema**
  filter, which is why `CREATE TABLE other.t` still fires `NOTIFY`. The
  unfiltered part is `audit.log_ddl_event` alone. Correct B5's row text when
  closing it.
- `0300_test_audit_log.sql:327-340` asserts `count(*) > 0` for
  `CREATE TABLE` / `CREATE INDEX` / `CREATE TRIGGER` rows. Those are `public`
  DDL, so the schema restriction must not break them — check, don't assume.

## The changes

### 1. `0150_audit_log.sql` — `audit.log_ddl_event()`

- Add `SECURITY DEFINER` (it already has `SET search_path = ''`). This fixes
  **S15** without granting the request role anything, makes the three audit
  triggers consistent, and moves toward **S5**, which wants the definer
  triggers to be the only writers to the audit tables.
- Filter inside the loop, skipping:
  - `obj.in_extension` — objects created by an extension script;
  - `pg_temp*` schemas — note the schema is `pg_temp_N` at runtime, so match
    the prefix, not the literal `pg_temp`;
  - objects whose schema is not one of the five Semantius schemas;
  - generated label functions: `CREATE/ALTER/DROP FUNCTION`, `GRANT`, `REVOKE`
    and `COMMENT` events whose identity matches `_label` or `%\_label`
    (the naming used by `rebuild_entity_label_functions`,
    `0145_managed_enable.sql:791`). This is P6's churn half.
- Bound the text: `left(current_query(), 8192)`.

### 2. `0150_audit_log.sql` — the `track_ddl_changes` trigger (line ~400)

Move the tag list onto the trigger definition as `WHEN TAG IN (...)` so it does
not fire at all, rather than firing and returning. Reuse the list in
`0090_notify_triggers.sql:105-115` as the starting point.

**Check first:** the trigger listens on `ddl_command_end` only. Establish
whether DROP commands currently produce audit rows at all before deciding
whether the tag list needs DROP tags — do not assume either way.

### 3. `0090_notify_triggers.sql` — `pgrst_ddl_watch`

Add the missing schema filter, so `NOTIFY pgrst` stops firing for DDL in
schemas Semantius does not own. Tag and `pg_temp` filters are already there;
do not duplicate them.

### 4. `pgdocker/pg-ext-lifecycle.sh` — the R1 step

Add an event-trigger-noise step asserting the new behavior: DDL in a foreign
schema and on a temp table produces neither an audit row nor a NOTIFY, while
DDL in `public` still produces both.

### 5. Tests

Extend `0300_test_audit_log.sql`, or add a sibling. It must assert, at minimum:

- `CREATE TABLE other.t` in a non-Semantius schema → no `audit_ddl_logs` row;
- `CREATE TEMP TABLE` → no row (B5) **and succeeds as `semantius_user`** (S15);
- `CREATE TABLE public.t` → still logged (the regression guard for 0300, and
  the guard that the new `WHEN TAG IN` list did not drop a wanted event);
- `query_text` is never longer than 8192 characters;
- generated `*_label` function churn produces no rows;
**The NOTIFY half cannot be tested in pgTAP — do not try.** Verified on
2026-09-03: pgTAP tests run inside a transaction that rolls back, and a
notification is only queued at COMMIT. `pg_notification_queue_usage()` returns
`0` both before and after a `NOTIFY` in an uncommitted transaction, so there is
nothing to observe. Assert it in the lifecycle script instead, where sessions
commit for real; the mechanism below was verified to work:

```sh
# listener in the background, then committed DDL from a second session
docker exec -d "$CONTAINER" sh -c   'psql -U postgres -d <db> -c "LISTEN pgrst" -c "SELECT pg_sleep(4)" > /tmp/listener.out 2>&1'
sleep 1
docker exec "$CONTAINER" psql -U postgres -d <db> -qc "CREATE TABLE other.t (id int)"
sleep 4
docker exec "$CONTAINER" cat /tmp/listener.out   # must NOT contain "Asynchronous notification"
```

psql prints `Asynchronous notification "pgrst" with payload "reload schema"
received from server process with PID ...` when one arrives, so grep for that
string: absent for a foreign schema, present for `public`.

## Verification, per item's own "Done when"

| Item | Done when | How to prove it |
|---|---|---|
| B5 | DDL in an unrelated schema or on a temp table produces neither an audit row nor a NOTIFY | the new test, plus the lifecycle step |
| S15 | user1 can create a temp table | the new test, running as `semantius_user` |
| P6 | `audit_ddl_logs` about 85% smaller after a full migration run | **measure it** — see below |
| R1 | the script asserts the new noise behavior (the pgTAP clause was dropped, see below) | the new lifecycle step |

**P6 must be measured, not asserted.** Record
`pg_total_relation_size('audit_ddl_logs')` and `count(*)` after a full
`pg-cli-retest.sh` run before the change and after it, and put both numbers in
the row when closing it. The baseline in the row (86 MB, 69% of the database)
comes from the 2026-09-02 review and may have moved.

## Decided, not open

R1's original text also asked for "the pgTAP suite via `pg-ext-retest.sh`" to
run from the lifecycle script. **Owner decision, 2026-09-03: drop that clause.**
The suite is deterministic against a given tree, so running it a second time
against the same code proves nothing it has not already proven, and it already
runs in `pg-ext-retest.sh`, in `test.yml` and in the release job.

The one variant that *would* carry information — running the suite against the
**restored** database rather than the original — is already covered more
cheaply by the lifecycle script's step 2 (row, policy, trigger, event-trigger
and function counts identical) and step 10 (schema-only dumps of the two
install paths byte-identical, 22,815 lines). Revisit only if those two ever
stop being sufficient.

So R1's remaining scope is **one step**: the event-trigger-noise assertion,
blocked on B5 and unblocked by this plan.

## Guardrails (this repo, learned the hard way on 2026-09-03)

- Do not write "verified by test X" without opening X. An audit of the
  extension rebuild found six such claims that were simply untrue, including
  citations of two test files that had never been modified.
- A claim is worth what its executable check is worth. Prefer an assertion that
  can fail over a sentence in a document.
- When closing a row, cross-check both directions: every closed row absent from
  `plans/pg_semantius-open-items.md`, every open row present, and the header's
  gap list updated. Four bookkeeping errors were caught this way.
- `set -e` plus `err=$(cmd)` aborts on the refusal tests; and a helper ending
  in `|| true` makes `cmd && ok || bad` unfailable. Both bit this repo already.
- Migrations are CRLF in the working tree. Preserve line endings when editing
  them programmatically.
- Re-run `deno task extension 0.5.0` after any migration change, then
  `git status --porcelain -- extension/` must be clean, or the release guard
  will fail.
- Both suites must stay green on both paths: `pgdocker/pg-cli-retest.sh` and
  `pgdocker/pg-ext-retest.sh`, plus `pgdocker/pg-ext-lifecycle.sh`.
- No commits without asking.

## Order of work

1. Reproduce S15 and capture the P6 baseline numbers.
2. `0150` function: SECURITY DEFINER, filters, bounded text.
3. `0150` trigger: `WHEN TAG IN`, after checking the DROP question.
4. `0090`: the schema filter.
5. Tests, then `pg-cli-retest.sh` green.
6. Regenerate the extension; `pg-ext-retest.sh` and `pg-ext-lifecycle.sh` green.
7. Add the lifecycle noise step; re-run it.
8. Measure P6; close B5, S15, P6 and (pending the decision) R1 in
   `plans/pg_semantius-open-items.md`, correcting B5's problem text about the
   pgrst watches. Update `plans/ext-solved-items.md` if any of these are
   claimed closed.
