# Plan: the two hot paths — permission checks and the JsonLogic interpreter

Written 2026-09-04. First of three; siblings are `plans/perf-per-statement.md`
and `plans/select-rule-native-predicates.md`.

Two functions in this codebase are called an enormous number of times and are
more expensive than they need to be. Both fixes are self-contained edits to a
single function, both have large existing test nets, and neither introduces a new
object, a new coupling or a new trust boundary. **This is the low-hanging fruit,
and it closes two open items outright.**

## Open items

**Owns, and therefore closes.**

| Row | Done when | Does this plan get there? |
|---|---|---|
| **P3** | `has_permission` at about 5 µs per call, from 26.6 | **Yes** — see the arithmetic under Step 1. Reaching it *requires* sub-step 8; without that the floor is ~11 µs. |
| **P12** | *(new row)* `evaluate_json_logic` no longer issues SQL round trips to identify a node's operator | **Yes** — Step 2 removes both. |

**Touches without owning.**

| Row | Effect here | Owner |
|---|---|---|
| **Q2** | 16 `SELECT expr INTO` sites become 15 (sub-step 5) | unowned |
| **Q5** | 12 unused variables become 11 (sub-step 6) | unowned |
| **S12** | the delimiter half only (sub-step 7); its done-when is the client-settable GUC and needs the signed cache | unowned |
| **P7** | untouched — this plan adds no STABLE function | unowned |

Q2 and Q5 are multi-site janitorial rows no single plan finishes; left unowned
rather than split further.

---

## Step 1 — `0030_rbac_functions.sql`: the permission check (P3)

Every check resolves the caller twice: once directly, once inside
`ensure_context_initialized`, whose "already done" shortcut sits *after* two
unconditional calls (`0030:338-352`).

### The arithmetic, because it decides how far to go

From the open-items row: `has_permission` 26.6 µs, `uid()` 8.0,
`ensure_context_initialized` 14.4 (which *includes* its own `uid()` call), the
cache check 0.4. So 26.6 ≈ 8.0 direct + 14.4 + 0.4 + ~3.8 of its own frame.

- Removing both `uid()` calls (sub-steps 2-4) leaves ~10.6 µs.
- The 6.4 µs left inside `ensure_context_initialized` is almost all **frame**
  cost — a SECURITY DEFINER plpgsql entry with a `SET search_path` save/restore —
  not the `current_setting` reads, which are ~0.4 each.
- **Collapsing that frame (sub-step 8) is therefore what reaches ~5 µs.** It is
  not optional garnish; it is the difference between closing P3 and not.

### The edits

1. In `ensure_context_initialized`, replace the `rbac.is_bearer_session()` call
   at `0030:340` with the bare expression `system_user LIKE 'oauth:%'`. That
   function carries `SET search_path` (`0030:311-314`), which blocks SQL
   inlining, so calling it costs a real function call per check. Keep the
   function — `whoami` and the tests use it.
2. Move `PERFORM rbac.uid()` (`0030:338`) into the bearer branch and the cold
   branch. The bearer path is otherwise unchanged: it still re-derives on every
   call, which is what keeps release-review S2 bearer-only.
3. **Warm-path revalidation.** Take the shortcut only when
   `app.context_initialized = 'true'` **and** `app.current_external_id` is
   non-empty **and** equals `current_setting('request.jwt.claim.sub', true)`.

   Say plainly in the comment what this does and does not buy. A forged cache
   *with valid claims* already escalates today — `has_permission` calls `uid()`
   at `0030:513` but still reads `app.user_permissions` at `0030:524`. The only
   property today's call adds is that a session with **no valid claims at all**
   is refused, and that is what the `sub` comparison preserves. Not a fix for S2;
   a guarantee of no *new* escalation. S2 needs the signed cache in
   `docs/bearer-mode-status.md`, out of scope.

   Why the comparison is sound: both settings are transaction-local and written
   by the same cold pass — the Neon path returns the setting verbatim, the
   Supabase fan-out writes it before re-reading at `0030:157`, the PG18 override
   rewrites it at `0030:169-174`, and both `get_userinfo` prefills assign
   `rbac.uid()` (`0080:101`, `0190:136`).

   **Do not weaken the ordering at `0030:362-379`**: it raises 28000 for a
   subject with no `users` row, and sets `app.current_user_id` *before*
   `app.context_initialized`. `select-rule-native-predicates.md` depends on it.
4. Drop the leading `PERFORM rbac.uid()` from `has_permission` (`0030:513`),
   `has_any_permission` (`0030:585`) and `get_current_user_permissions`
   (`0030:720`).

   This needs `apps/test/tests/0060_test_security.sql:85` widened to accept
   `rbac.uid()` **or** `rbac.ensure_context_initialized()`, and its rationale
   comment corrected. **Say in the commit message that this weakens a security
   guard** for every future SECURITY DEFINER function in `public`/`rbac`. Do not
   add the three checkers to the exception list instead — that hides them.

   One edge changes: an unauthenticated caller passing a blank permission name
   gets FALSE instead of 42501 (`0030:516-518`). Accept and pin it.
5. `v_system_user := system_user` instead of `SELECT … INTO` (`0030:168`) — the
   one real Q2 case in `rbac`.

   **Do not cache the `jwt_aud` lookup.** Proposed twice, wrong both ways:
   `0250_test_jwt_aud.sql` runs all five audience cases in one transaction and
   calls `uid()` at `:12` *before* the `INSERT INTO _settings` at `:24`, so any
   cache primes itself with "no audience required" and cases (d) and (e) stop
   raising. It is also client-forgeable, and after sub-steps 2 and 4 there is
   nothing to save — `uid()` is not called on a warm check at all.
6. Remove the dead `v_external_id` in `has_permission` (`0030:511`) — Q5.
7. Unify the `app.oauth_scopes` delimiter to comma in `user_has_permission`
   (`0030:483`). **`validate_oauth_scopes` (`0030:770`) keeps splitting on
   space** — `0405_test_rbac_helpers.sql:126-129` pins it.
8. **Collapse the warm frame — this is what closes P3.** Inline the sub-step 3
   check into `has_permission`, `has_any_permission` and
   `get_current_user_permissions`: each reads the three settings itself and only
   calls `ensure_context_initialized()` on a miss. One plpgsql frame on the warm
   path instead of two.

   **The cost, stated plainly:** the bearer test now lives in three places
   instead of one, and each copy must keep `system_user LIKE 'oauth:%'` ahead of
   the cache read, or that checker silently trusts a forged cache in a bearer
   session. Mitigated by applying the same `prosrc` ordering assertion to all
   three (see Tests), not by care.

**Expected: 26.6 → ~5 µs**, which meets P3's done-when. Without sub-step 8,
~11 µs and P3 stays open.

---

## Step 2 — `0210_raci.sql`: the interpreter's per-node SQL round trips (P12)

The installed interpreter is `0210:380-1020` — a `CREATE OR REPLACE` over the
`0015_jsonlogic.sql` copy, so that is the body to edit. It identifies each node's
operator with **two separate SQL queries** (`0210:430-431`):

```sql
SELECT key INTO op FROM jsonb_object_keys(rule) AS key LIMIT 1;
IF (SELECT count(*) FROM jsonb_object_keys(rule)) <> 1 THEN RETURN rule; END IF;
```

Neither qualifies for PL/pgSQL's simple-expression fast path — both have a `FROM`
over a set-returning function — so both go through full SPI. A rule as small as
`col1 == 'x'` has two nodes, so that is **four SQL executions per row**, plausibly
30–50% of the 51 µs interpreter cost, against 2–6 µs of IF-chain walking.

Replace both with one non-SPI expression, e.g.

```sql
op := jsonb_path_query_first(rule, '$.keyvalue().key') #>> '{}';
IF op IS NULL OR rule - op <> '{}'::jsonb THEN RETURN rule; END IF;
```

**The zero-key guard is required, not optional.** Today `{}` leaves `op` NULL and
returns at `0210:431`; without the NULL check it falls through to
`vals := rule -> NULL`.

**Do not also reorder the operator IF-chain, and do not convert it to `CASE`.**
`exec_stmt_case` walks its WHEN list linearly too, so the conversion buys nothing,
and reordering is the change most likely to disturb the file for no measurable
gain.

**Why this is worth doing on its own:** `evaluate_json_logic` is not only the
`select_rule` path. It runs in every generated validation trigger and every RACI
gate, so the win lands on `plans/perf-per-statement.md`'s targets too — which is
why that plan's P4 arithmetic assumes this one has landed.

Safety net: `0015_test_jsonlogic.sql` (288 assertions),
`0016_test_jsonlogic_ext.sql` and `0350_test_raci.sql` exercise this function
harder than anything else in the repo. **But the corpus has no `{}` case** —
verified — so the new guard has no net until one is added.

---

## Step 3 — regenerate

`deno task extension 0.5.0`, then `deno task bundle-sql`;
`git status --porcelain -- extension/` must be clean.

---

## Tests

House style: `BEGIN; SELECT plan(N); …; SELECT * FROM finish(); ROLLBACK;` with an
exact count. Every assertion must be able to fail, and every negative assertion
needs a positive control — see `0301_test_audit_ddl_scope.sql`.

### New: `apps/test/tests/0446_test_rbac_hot_path.sql`

- **Structural, failing-capable everywhere** (call-counting is not an option:
  `track_functions` is superuser-only and the suite runs against whatever
  `DATABASE_URL` names): `has_permission`, `has_any_permission` and
  `get_current_user_permissions` no longer contain `PERFORM rbac.uid()` in
  `prosrc`. **This is the assertion that fails on revert.**
- **Bearer ordering, in all four functions** — the three checkers after sub-step
  8, and `ensure_context_initialized`: `strpos(prosrc,'oauth:%') > 0` **and**
  `< strpos(prosrc,'app.context_initialized')`. The `> 0` half is required;
  `strpos` returns 0 when absent, satisfying `<` vacuously. This is the guard that
  makes sub-step 8's duplication safe.
- **A forged cache is refused.** As user1, set `app.user_permissions = 'admin'`,
  `app.context_initialized = 'true'` and `app.current_external_id` to *user3's*
  external id; `has_permission('admin')` must be false. **Today it returns true.**
  Repeat for `has_any_permission` and `get_current_user_permissions`, since each
  now carries its own copy of the check. Positive control: a genuine warm hit
  still returns the cached answer.
- **Two scopes, asserted as agreement:** with
  `app.oauth_scopes = 'nwind:view nwind:manage'`, `user_has_permission` and
  `has_permission` disagree today (space vs comma) and agree after.
- **Blank permission name, unauthenticated** returns FALSE, not 42501.
- **The ordering the siblings rely on:** `ensure_context_initialized` raises
  **28000** (not 42501) for a subject with no `users` row, and leaves
  `app.current_user_id` populated whenever `app.context_initialized = 'true'`.

### Extend: `apps/test/tests/0015_test_jsonlogic.json`

Add a `{}` rule case (expected: passthrough) and regenerate with
`deno task testgen_jsonlogic`. Verified absent today, so Step 2's zero-key guard
is otherwise untested.

### Unchanged, and therefore the regression net

`0250_test_jwt_aud.sql` (the guard that no `jwt_aud` caching crept into sub-step
5), `0405_test_rbac_helpers.sql`, `0410_test_uid_claim_paths.sql`,
`0435_test_bearer_context_bypass.sql`, `0390_test_unauthenticated_access.sql`,
`0280_test_user_permissions.sql`, `0016_test_jsonlogic_ext.sql`,
`0350_test_raci.sql`, and the whole `select_rule` family (`0330`, `0331`, `0332`,
`0335`, `0338`, `0380`) — this plan does not touch `0180` at all.

Structural guards: `0060_test_security.sql` (widened here, deliberately),
`0240_test_no_unsafe_functions.sql`, `0336_test_iroles_catalog_guard.sql`,
`0430_test_owner_hardening.sql`.

### Not reachable from pgTAP

`cd pgdocker && deno run --allow-net test_bearer_cache.ts` must stay green — it is
the only place a real bearer session exists, and sub-step 8 puts the bearer test
in three new places.

### Measured, not asserted

| | Expect |
|---|---|
| `has_permission`, warm | 26.6 → ~5 µs (~11 without sub-step 8) |
| One `evaluate_json_logic` node | 30–50% cheaper |

---

## Verification

```sh
deno task connect
deno task dropall --confirm
deno task migrate --apps _core,nwind,test --verbose
deno task test
deno task extension 0.5.0 && deno task bundle-sql
git status --porcelain -- extension/          # must be empty
pgdocker/pg-cli-retest.sh
pgdocker/pg-ext-retest.sh
cd pgdocker && deno run --allow-net test_bearer_cache.ts
```

Then `deno task test --coverage` and update
`docs/pg_semantius-test-coverage.md`.

Bookkeeping in `plans/pg_semantius-open-items.md`: **close P3** (measured at
~5 µs) and **close P12**. Decrement Q2 to 15 and Q5 to 11. Note S12's delimiter
half done. Update the header gap list. No commits without asking.
