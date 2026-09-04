# Plan: the cheap performance wins (P3, and half of P2)

Written 2026-09-04. One of three plans that replaced a single oversized one;
six review rounds showed the work was three settled changes stapled to two hard
ones. This is the settled part. Siblings:
`plans/perf-statement-triggers.md` (P4) and
`plans/select-rule-native-predicates.md` (the rest of P2).

## Context

`plans/pg_semantius-open-items.md` carries three High-priority performance rows.
This plan takes **all of P3's work** and **the half of P2 that needs no new
concepts**: make existing code do less work per row and per call. Nothing here
introduces new coupling, new generated objects, or a new trust boundary.

| Change | File | Effect |
|---|---|---|
| Stop resolving the caller twice per permission check | `0030_rbac_functions.sql` | 26.6 → ~11 µs per `has_permission` |
| Resolve the request context once per query, not per row | `0180_computed_validation.sql` | ~14 µs off every rule row, read and write (~7 µs of it marginal once Step 1 lands) |
| Remove the interpreter's two SQL round trips per node | `0210_raci.sql` | 30–50% off the 51 µs interpreter |

Net on a 100k-row scan of a table with a `select_rule`: about **5 s → 2.5–3 s**.
P2 stays open but much cheaper, and its remaining question becomes decidable
against a measured number instead of the 2026-09-02 review's.

## Open items

**Owns, and therefore closes.** Every row here is owned by this plan and by no
other. A plan may own several rows; a row has exactly one owner.

| Row | Done when, and whether this plan gets there |
|---|---|
| **P3** | `has_permission` at ~5 µs per call. **This plan delivers ~11 µs.** Closing needs either the extra frame collapse named at the end of Step 1, or that target renegotiated with the owner. Do not tick it at 11 µs without deciding which. |
| **P11** | The request context resolved once per statement rather than once per row — asserted structurally, because a timing figure alone cannot distinguish the two — and one rule row at ~54 µs from ~68. **This plan meets that.** Split out of P2 on 2026-09-04 so the row has a single owner. |

**Touches without owning.** Listed so no sibling plan double-counts them.

| Row | Effect here | Owner |
|---|---|---|
| **Q2** | 16 `SELECT expr INTO` sites become 15 (sub-step 5, in `rbac.uid`) | unowned |
| **Q5** | 12 unused variables become 11 (sub-step 6, `v_external_id`) | unowned |
| **S12** | the delimiter half only (sub-step 7); the row's done-when is the client-settable GUC and needs the signed cache | unowned |
| **P7** | **made worse** — `jl_request_context` is a new STABLE function that writes settings; add it to that row | unowned |

Q2 and Q5 are multi-site janitorial rows that no single plan finishes. They are
deliberately left unowned rather than split further.

---

**Deliberately not here:**

- **`plans/perf-statement-triggers.md` (P4, statement-level audit and queue
  triggers)** — its Steps 1-2 are independent, but its Step 3 consumes Step 2's
  `jl_request_context`, so it lands after this one. Opens with a
  prototype, because it needs one generic function reading a transition table
  across many tables of different row types, and the only precedent in this tree
  (`0070_dd_functions.sql:1606-1622`) is three triggers bound to a single table
  with their own functions. Part of its win is banked by Step 2 below, so its
  remaining gap will be measurable rather than estimated.
- **`plans/select-rule-native-predicates.md`** — native rule columns, or a
  decision not to build them. **It consumes `jl_request_context()` and the
  two-argument `select_rule_<t>` this plan introduces**, so an edit to either
  object here has a downstream consumer. Every blocker across six review rounds landed
  there: it is where a column name enters an RLS policy for the first time,
  which pulls in a fields-lifecycle trigger, a permanent policy/read-helper
  split, and drift tripwires. Decide it after measuring what this plan leaves
  behind.

The audit/NOTIFY work of `plans/audit-ddl-noise.md` has **landed** (`419a2ab`),
touching `0150`, `0090` and `pg-ext-lifecycle.sh`. Nothing in this plan touches
those files; `plans/perf-statement-triggers.md` does.

---

## Step 1 — `0030_rbac_functions.sql`: the permission hot path (P3)

Every check resolves the caller twice: once directly, and once inside
`ensure_context_initialized`, whose "already done" shortcut sits *after* two
unconditional calls (`0030:338-352`).

1. In `ensure_context_initialized`, replace the `rbac.is_bearer_session()` call
   at `0030:340` with the bare expression `system_user LIKE 'oauth:%'`. The
   function carries `SET search_path` (`0030:311-314`), which blocks SQL
   inlining, so calling it costs a real function call on every check. Keep the
   function itself — `whoami` and the tests use it.
2. Move `PERFORM rbac.uid()` (`0030:338`) into the bearer branch and the cold
   branch. The bearer path is otherwise unchanged: it still re-derives on every
   call, which is what keeps release-review S2 bearer-only.
3. **Warm-path revalidation.** Take the shortcut only when
   `app.context_initialized = 'true'` **and** `app.current_external_id` is
   non-empty **and** equals `current_setting('request.jwt.claim.sub', true)`.
   Three setting reads, no SQL, ~1 µs.

   State plainly in the comment what this does and does not buy. A forged cache
   *with valid claims* already escalates today — `has_permission` calls `uid()`
   at `0030:513` but then still reads `app.user_permissions` at `0030:524`. The
   only property today's call adds is that a session with **no valid claims at
   all** is refused, and that is exactly what the `sub` comparison preserves. So
   this is not a fix for S2; it is the guarantee that this change introduces no
   *new* escalation. Closing S2 needs the signed cache in
   `docs/bearer-mode-status.md`, out of scope.

   Record why the comparison is sound: both settings are transaction-local and
   written by the same cold pass — the Neon path returns the setting verbatim,
   the Supabase fan-out writes it before re-reading at `0030:157`, the PG18
   override rewrites it at `0030:169-174`, and both `get_userinfo` prefills
   assign `rbac.uid()` (`0080:101`, `0190:136`). This matters because the warm
   path no longer does the Supabase normalisation itself.

   **Do not weaken the ordering at `0030:362-379`**: `ensure_context_initialized`
   raises 28000 for a subject with no `users` row, and sets `app.current_user_id`
   *before* `app.context_initialized`. `select-rule-native-predicates.md`
   depends on that ordering if it is ever built.
4. Drop the leading `PERFORM rbac.uid()` from `has_permission` (`0030:513`),
   `has_any_permission` (`0030:585`) and `get_current_user_permissions`
   (`0030:720`) — the next statement calls `ensure_context_initialized`, which
   calls it.

   This needs `apps/test/tests/0060_test_security.sql:85` widened to accept
   `rbac.uid()` **or** `rbac.ensure_context_initialized()`, and its rationale
   comment corrected ("rbac.uid() is STABLE and cached per transaction so the
   cost is zero" is the belief this item disproves). **Say in the commit message
   that this weakens a security guard** for every future SECURITY DEFINER
   function in `public`/`rbac` — a deliberate trade, and Step 2's new function
   relies on it. Do not add the three checkers to the exception list instead;
   that would hide them entirely.

   One edge changes: an unauthenticated caller passing a blank permission name
   now gets FALSE instead of 42501 (`0030:516-518`). Accept and pin it.
5. `v_system_user := system_user` instead of `SELECT … INTO` (`0030:168`) — the
   one real Q2 case in `rbac`.

   **Do not cache the `jwt_aud` lookup.** It was proposed twice and is wrong
   both ways: `apps/test/tests/0250_test_jwt_aud.sql` runs all five audience
   cases in one transaction and calls `uid()` at `:12` *before* the
   `INSERT INTO _settings` at `:24`, so any cache primes itself with "no
   audience required" and cases (d) and (e) stop raising. It is also
   client-forgeable. And after sub-steps 2 and 4 there is nothing to save —
   `uid()` is not called on a warm check at all.
6. Remove the dead `v_external_id` in `has_permission` (`0030:511`) — Q5,
   cosmetic, untested by design.
7. Unify the `app.oauth_scopes` delimiter to comma in `user_has_permission`
   (`0030:483`) — S12's delimiter half. **`validate_oauth_scopes` (`0030:770`)
   keeps splitting on space** — `0405_test_rbac_helpers.sql:126-129` pins it.

**Expected: 26.6 → ~11 µs.** The residual is two nested SECURITY DEFINER
plpgsql frames with their own `search_path` save/restore (`0030:383`,
`0030:550`) plus about five GUC reads. The open-items row asks for 5 µs; that
needs the `has_permission → ensure_context_initialized` frame collapsed as well.
Do it only if the measurement misses and the extra complexity earns its place.

---

## Step 2 — `0180_computed_validation.sql`: resolve the context once per query

The generated rule predicate calls `ensure_context_initialized` and rebuilds
`$today`/`$now`/`$user_id` **for every row** (`0180:340-349`).

- Add `public.jl_request_context()` — STABLE, SECURITY DEFINER, pinned
  `search_path`, COMMENT, `REVOKE EXECUTE … FROM PUBLIC` +
  `GRANT … TO semantius_user`. It calls `rbac.ensure_context_initialized()` once
  and returns `{"$today":…, "$now":…, "$user_id":…}`.
  - It **must keep propagating 42501**: that call is the only thing refusing an
    unauthenticated session, because the rule-branch SELECT policy
    (`0180:376-378`) carries no permission conjunct and the exception handler at
    `0180:351-355` sits *below* it.
  - `$user_id` must mirror `0180:345-348` exactly — NULL **or empty string**
    maps to jsonb `null`. A naive `to_jsonb(current_setting(...)::int)` raises
    22P02 on the empty case.
  - It passes `0060_test_security.sql` only because of Step 1 sub-step 4's
    widening. Land them together.
  - Add it to open item **P7**'s list: a STABLE function that writes settings
    through `ensure_context_initialized`.
- Generate a **two-argument** predicate `select_rule_<t>(p_row, p_ctx jsonb)`,
  keeping the one-argument form as a wrapper that supplies the context —
  `get_record_by_id` (`0070:1831-1834`) calls that form, and the `set_record`
  JsonLogic operator goes through it.
  - **Both signatures must be dropped at all four drop sites** or
    `DROP … IF EXISTS` silently no-ops and the CASCADE never removes the
    dependent policy: `0180:293`, `0180:306`, `0180:429`, `0140:209-210`.
  - **Both need their own `REVOKE`/`GRANT`/`COMMENT`** (`0180:368-373`) or 0060
    and 0240 fail.
- Emit **all three policies** with the context passed in — not just SELECT.
  `build_select_rule_policy` embeds the same per-row helper call in the
  UPDATE and DELETE quals too (`0180:387-389`, `0180:390-392`, both
  `… AND public.%I(%I.*)`), and those are evaluated per row for every write, so
  leaving them alone keeps `ensure_context_initialized` firing per row on the
  write path. SELECT becomes
  `USING (public.select_rule_t(t, (SELECT public.jl_request_context())))`
  (`0180:376-378`); UPDATE and DELETE keep their
  `(SELECT rbac.has_permission(…)) AND …` wrapper around the same two-argument
  call. An uncorrelated sub-select in an RLS qual becomes a once-per-statement
  InitPlan — the device P1 already used for `rbac.has_permission`. Pass `t`, not
  `t.*`, in every one.
**Do not touch `build_record_logic_trigger` here.** `0180_computed_validation.sql`
holds two independent generators: the compute/validate BEFORE ROW trigger
(`:29-215`) and the policy generator this step edits (`:280-399`). They share no
code. The trigger's per-row costs belong to P4 and are owned entirely by
`plans/perf-statement-triggers.md`, so that one open item is closed by one plan.
There is no InitPlan in a BEFORE ROW trigger anyway, so nothing here would help
it.

**Expected: ~68 → ~54 µs per rule row.** Marginal win once Step 1 has landed is
~10–13%, not the ~21% a standalone reading suggests — `0180:340` calls the same
`ensure_context_initialized` Step 1 already made cheap. The endpoint is what
matters.

---

## Step 3 — `0210_raci.sql`: remove the interpreter's per-node SQL round trips

The installed interpreter is `0210:380-1020` — a `CREATE OR REPLACE` over the
`0015_jsonlogic.sql` copy, so that is the body to edit. It extracts its operator
with **two separate SQL queries per node** (`0210:430-431`):

```sql
SELECT key INTO op FROM jsonb_object_keys(rule) AS key LIMIT 1;
IF (SELECT count(*) FROM jsonb_object_keys(rule)) <> 1 THEN RETURN rule; END IF;
```

Neither qualifies for PL/pgSQL's simple-expression fast path — both have a
`FROM` over a set-returning function — so both go through full SPI. A rule as
small as `col1 == 'x'` evaluates two nodes, so that is **four SQL executions per
row**, plausibly 30–50% of the 51 µs, against 2–6 µs of IF-chain walking.

Replace the two scans with one non-SPI expression, e.g.

```sql
op := jsonb_path_query_first(rule, '$.keyvalue().key') #>> '{}';
IF op IS NULL OR rule - op <> '{}'::jsonb THEN RETURN rule; END IF;
```

**The zero-key guard is required, not optional.** Today `{}` leaves `op` NULL
and returns at `0210:431`; without the NULL check it falls through to
`vals := rule -> NULL`.

**Do not also reorder the operator IF-chain, and do not convert it to `CASE`.**
`exec_stmt_case` walks its WHEN list linearly too, so the conversion buys
nothing, and reordering is predicted to miss a 10% gate while being the change
most likely to disturb the file. One change, measured, kept only if it clears
10%.

Safety net: `0015_test_jsonlogic.sql` (288 assertions),
`0016_test_jsonlogic_ext.sql` and `0350_test_raci.sql` exercise this function
harder than anything else in the repo. **But the corpus has no `{}` case** —
verified — so the new guard has no net until one is added (see Tests).

---

## Step 4 — regenerate

`deno task extension 0.5.0`, then `deno task bundle-sql`;
`git status --porcelain -- extension/` must be clean.

---

## Tests

House style: `BEGIN; SELECT plan(N); …; SELECT * FROM finish(); ROLLBACK;` with
an exact count. Every assertion must be able to fail, and every negative
assertion needs a positive control beside it — see `0301_test_audit_ddl_scope.sql`.

### New: `apps/test/tests/0446_test_rbac_hot_path.sql`

- **Structural, and failing-capable everywhere** (call-counting is not an
  option: `track_functions` is superuser-only and the suite runs against
  whatever `DATABASE_URL` names): `has_permission`, `has_any_permission` and
  `get_current_user_permissions` no longer contain `PERFORM rbac.uid()` in
  `prosrc`. **This is the assertion that fails on revert**; companion
  assertions about the call chain are documentation.
- **Bearer ordering:** in `ensure_context_initialized`'s `prosrc`,
  `strpos(…, 'oauth:%') > 0` **and** `< strpos(…, 'app.context_initialized')`.
  The `> 0` half is required — `strpos` returns 0 when absent, satisfying `<`
  vacuously.
- **A forged cache is refused.** Authenticated as user1, set
  `app.user_permissions = 'admin'`, `app.context_initialized = 'true'` and
  `app.current_external_id` to *user3's* external id; `has_permission('admin')`
  must be false. **Today it returns true.** Positive control: a genuine warm hit
  still returns the cached answer, so the revalidation did not just disable the
  cache.
- **Two scopes, asserted as agreement:** with
  `app.oauth_scopes = 'nwind:view nwind:manage'`, `user_has_permission` and
  `has_permission` disagree today (space vs comma) and agree after.
- **Blank permission name, unauthenticated** returns FALSE, not 42501.
- **The ordering Step 2 and the native-predicates plan rely on:**
  `ensure_context_initialized` raises **28000** (not 42501) for a subject with
  no `users` row, and leaves `app.current_user_id` populated whenever
  `app.context_initialized = 'true'`.

### New: `apps/test/tests/0447_test_request_context.sql`

- **`jl_request_context()` refuses an unauthenticated session** (42501) and an
  unknown subject (28000) — the gate. Positive control: it returns a populated
  object for an authenticated one.
- **`$user_id` is jsonb `null` for both NULL and empty string**, matching
  `0180:345-348`. The empty-string case is the one a naive implementation gets
  wrong.
- **Both helper signatures exist**, and a `get_record_by_id` call on a
  rule-bearing entity still works.
- **Both signatures survive a rebuild:** two successive
  `UPDATE entities SET select_rule = …`. If the two-argument form is not dropped
  at `0180:306` the second `CREATE FUNCTION` raises 42723. **Do not assert on
  `DELETE FROM entities`** — `delete_table_trigger` is BEFORE DELETE
  (`0070:1212-1213`), so the composite type drops first and cascades both away
  regardless.
- **Entity rename** rebuilds under the new name with both signatures and all
  three policies.
### Extend: `apps/test/tests/0445_test_policy_initplan_form.sql`

Nothing anywhere pins the `(SELECT …)` wrapper around `jl_request_context`, and
the entire Step 2 win depends on it — an edit to the bare call reverts it
silently. 0445 is this repo's precedent for exactly that failure mode: extend
its two catalog sweeps and its per-generator checks to strip and search
`jl_request_context\(` as well, with a positive count so the sweep cannot pass
vacuously.

**The strip pattern must tolerate a leading paren or cast.** This plan's own
emission deparses as `(SELECT jl_request_context() …)`, which strips cleanly, but
`plans/select-rule-native-predicates.md` emits
`(SELECT (public.jl_request_context() ->> '$user_id')::int)` — a `(` sits between
`SELECT ` and the call, so a literal `SELECT jl_request_context\(` pattern would
miss it, the residual search would fire, and Part 1 would fail on
`user_bookmarks_select_policy`. Write the pattern to allow the paren now, or that
plan has to widen it later.

**Match `jl_request_context\(`, not `public\.jl_request_context\(`** —
`pg_get_expr` deparses the schema qualifier out, which is why `0445:119` asserts
on a bare `select_rule_p1_initplan\(` although the function is created as
`public.%I`. A qualified pattern would match nothing and pass on everything.

### Extend: `apps/test/tests/0015_test_jsonlogic.json`

Add a `{}` rule case (expected: passthrough) and regenerate with
`deno task testgen_jsonlogic`. Verified absent today, so Step 3's zero-key guard
is otherwise untested.

### Unchanged, and therefore the regression net

`0250_test_jwt_aud.sql` — the guard that no `jwt_aud` caching crept into
sub-step 5. Also `0405_test_rbac_helpers.sql`, `0410_test_uid_claim_paths.sql`,
`0435_test_bearer_context_bypass.sql`, `0390_test_unauthenticated_access.sql`,
`0280_test_user_permissions.sql`, `0330_test_select_rule.sql`,
`0331_test_select_rule_write_protection.sql`,
`0332_test_definer_read_helper_select_rule.sql`,
`0335_test_select_rule_temporal.sql`,
`0338_test_enable_managed_builds_select_rule.sql`,
`0320_test_computed_validation.sql`, `0337_test_record_logic_delete_arm.sql`,
`0291_test_ddl_rename_deep.sql`, `0295_test_entity_changes.sql`,
`0380_test_user_bookmarks.sql`, `0016_test_jsonlogic_ext.sql`,
`0350_test_raci.sql`.

Structural guards that fail on shape rather than behaviour, so a refactor breaks
them by accident: `0060_test_security.sql` (widened here, deliberately),
`0240_test_no_unsafe_functions.sql` (pinned `search_path` + COMMENT on every
function, the new ones included), `0336_test_iroles_catalog_guard.sql`,
`0430_test_owner_hardening.sql`.

### Not reachable from pgTAP

`cd pgdocker && deno run --allow-net test_bearer_cache.ts` must stay green, and
should gain a read of a `select_rule` table: `jl_request_context` is a new
`ensure_context_initialized` call site and bearer sessions take the
non-shortcut branch (`0030:340-345`). pgTAP cannot open a bearer session.

### Measured, not asserted

Per open-items Appendix B; record before/after in each row before closing it.

| | Expect |
|---|---|
| `has_permission` | 26.6 → ~11 µs |
| One rule row | ~68 → ~54 µs |
| Interpreter node | 30–50% off 51 µs, gated at 10% |
| 100k-row scan of a rule-bearing table | ~5 s → ~2.5–3 s |

---

## Verification

```sh
deno task connect
deno task dropall --confirm
deno task migrate --apps _core,nwind,test --verbose
deno task test
deno task extension 0.5.0 && deno task bundle-sql
git status --porcelain -- extension/          # must be empty
pgdocker/pg-cli-retest.sh                     # migrate path
pgdocker/pg-ext-retest.sh                     # CREATE EXTENSION path
cd pgdocker && deno run --allow-net test_bearer_cache.ts
```

Then `deno task test --coverage` and update
`docs/pg_semantius-test-coverage.md`.

Bookkeeping in `plans/pg_semantius-open-items.md`: **close P3 only once the
5 µs target is met or its done-when is rewritten with the owner** (see "Open
items this plan moves" above); **rewrite P2's
row** to what remains (native rule columns only, with the measured new baseline,
and the note that the general "compile JsonLogic" fix is rejected); add
`jl_request_context` to **P7**; note the Q2, Q5 and S12 fragments absorbed;
update the header's gap list; cross-check both directions. No commits without
asking.

---

## Adjacent, not this plan's work

Surfaced during review, worth its own open item rather than widening this
change: `user_bookmarks_insert_policy` (`0280_user_bookmarks.sql:106-109`) names
`user_id` in its `WITH CHECK` and is destroyed **today** by two separate paths —
`delete_dd_field`'s `DROP COLUMN … CASCADE` (`0070:1163-1167`) and
`update_entity_policies`, which drops it and recreates it permission-only on any
`edit_permission` change.
