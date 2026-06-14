# Authorization Remediation — Master Plan (v2)

**Updated:** 2026-06-11 · **Owner:** Martin · **Status:** spec v2 FROZEN → starting Plan a + red-first tests.
**Spec (oracle):** [`docs/authz-spec.md`](../docs/authz-spec.md) — v2, frozen. All work derives from it.

Durable plan; resume from here if context is lost.

## 1. Why this exists

Stage-2 adversary panel (4 isolated lenses) found gaps worse than the originals. Headline:
a **CRITICAL read bypass** — any `public:read` holder reads any `select_rule`-hidden row via
`/rpc/evaluate_json_logic` or `/rpc/get_record_by_id` (the DEFINER read helpers check only
`view_permission`, never the rule). Full confirmed list in spec Appendix A.

## 2. Settled model (spec v2)

- **P1** database-per-tenant. **P2** admin-sees-all (admin-blind data is a non-goal; needs
  app-layer encryption, out of scope). **P3** request role = `authenticated` INHERITs
  `semantius_user`; BYPASSRLS owner separate.
- **D8 / canonical predicate:** `access(row) = select_rule(row)` when set, else
  `has_permission(view_permission)`. The rule REPLACES the permission; permissions are in-rule
  operators; grants (owner/RACI/blanket-role) compose as an inner OR. ONE predicate, enforced
  identically in: SELECT policy, DEFINER read helpers, and UPDATE/DELETE `USING`.
- Decisions: D2 silent-filter · D3 accept cascade · D4 trust BYPASSRLS owner · D5 core-field
  trigger keyed on `ctype` · D6 API-key=JWT · D7 extend files · D9 accept cascade (watch
  `raci_events`) · D10 fix read-helper red-first (priority 1) · D11 skip FORCE.

## 3. Pipeline

```
Spec v2 FROZEN ─► Plan a (inventory + ratchet baseline)
              └─► Plan c (tests, blind to b; red-first)  ─┐
              └─► Plan b (implementation)                  ├─► reconcile ─► integration gate ─► conformance gate
```
Isolation: b and c both derive from the frozen spec; c is NOT downstream of b. Reconciliation
only classifies coverage. Security-critical reviews use a diverse panel.

## 4. Plan b — implementation (edit originals; no version bump; refresh extension)

Priority order (security first):
- **b1 · Read-helper bypass (CRITICAL / D10).** `get_record_by_id` / `set_record` /
  `build_schema_for_table` must evaluate `access(row)` (the rule when set), not just
  `view_permission`. Revoke/bound `/rpc/evaluate_json_logic` for the request role. Files:
  `0070` (get_record_by_id ~1494), `0015`/`0210` (set_record, evaluate_json_logic grant), `0080`.
- **b2 · Write USING gating (I2).** Compile `access(row)` into UPDATE/DELETE `USING` (with
  `edit_permission`). Don't rely on PG's SELECT-policy-on-column-read. Files: `0180`
  (`build_select_rule_policy` — extend beyond SELECT), `0070`/`0145` (`create_dd_table`/
  `enable_dd_table`/`update_entity_policies` policy shapes).
- **b3 · Enforcement consistency.** Ensure SELECT policy, read helpers, write USING all use the
  identical `access(row)`. Reconstruct ALL policies on `managed` F→T (`enable_dd_table`).
- **b4 · `user_process_raci` view → `security_invoker = true`** (`0210:329`).
- **b5 · record-logic trigger `$mode`/`$old`/DELETE arm** (`0180`) → closes I7.
- **b6 · ctype coverage** (`0060` CHECK + enum + backfill created_at/updated_at).
- **b7 · drop `is_core`**: re-key rename/format/default/delete guards to `ctype <> ''`
  (`0070`/`0140`/`0145`); KEEP label-column rename (intentional; cascades to entities.label_column);
  drop column; derive `is_core` in
  `get_schema`; clear stuck rows; regen drizzle/kysely/docgen + extension bundle; update AGENTS.md.
- **b8 · I-roles guard** (test, not code): assert request role non-owner/non-BYPASSRLS; no
  policy `TO authenticated`/`TO public`; all views `security_invoker`.
- Also remove the redundant `is_core` format block (generic type-change guard suffices).

## 5. Plan a — existing-suite review
Inventory `apps/test/tests/` → spec cells; ratchet baseline `{file→count}` + covered set;
find weak/dup/orphan tests; orphans escalate to spec.

## 6. Plan c — new tests (spec-derived, isolated from b)
- c-regression (red on current main): b1 read bypass, I2 bare/WHERE-TRUE writes, I5 escalation,
  I8 oracle, I-roles, `user_process_raci` leak.
- c-newfeature (mutation-checked): `$mode`/DELETE arm, ctype-derived protection, write USING.

## 7. Current status / next action  (RESUME HERE)

**STATE (2026-06-12):** b1–b6, b8, b9 DONE, validated & COMMITTED. **b7 SQL DONE & validated**
(retest **1408 passing / 0 failing**); only the **client-artifact regen remains** (b7.8 — drizzle/
kysely/docgen + extension bundle; gated, not yet run). Tests: `0336`(b8) `0337`(b5) `0338`(b3)
`0339`(b6→b7 audit) `0341`(b9) `0342`(b7 lock/protection).

**b7 (drop is_core) — SQL COMPLETE 2026-06-12:**
- `is_core` boolean column **removed** from `fields` (CREATE TABLE + every INSERT across
  `0060`/`0150`/`0190` + the `0070`/`0145` generators); no `DROP COLUMN`, no backfill — values
  set inline during regeneration (user's call).
- New `ctype` enum `['', 'id', 'label', 'audit', 'core']` (`0060`): `audit` = created_at/updated_at
  (room for created_by/updated_by); `core` = the other system/metadata columns. id/label keep their
  specific markers.
- Protection re-keyed from `OLD.is_core` → `coalesce(OLD.ctype,'')<>''` in ALL guards: delete
  (`0070`), rename + the two format guards (`0140`), format/default (`0145`); `is_core`-mutation
  guards removed.
- **ctype lock** (`0070` `fields_ctype_lock`, BEFORE INSERT/UPDATE): only a BYPASSRLS caller (the
  owner that SECURITY DEFINER DD fns run as) may set/change ctype; user INSERT → ctype forced '',
  user UPDATE that changes ctype → rejected (`42501`). Makes the `core = ctype<>''` marker
  un-tamperable. Mutation-checked (disabling it reds `0342`).
- `get_schema` derives `is_core` as `(ctype<>'')` (`0080`), still emitted for client compat.
- **Verified**: protected-set (`ctype<>''`) after = the saved pre-b7 `is_core` set exactly (230
  cols; sole delta = the deliberately-removed `fields.is_core` meta-row). Baseline saved at
  `c:\tmp\is_core_baseline.txt`.
- **b7.8 DONE (2026-06-12):** client artifacts regenerated from a clean `_core`-ONLY DB (no
  nwind) — dropall + `migrate --apps _core` on the plain CLI container (`:5432`), then
  `drizzlegen` (×3: examples/drizzle, examples/nextjs, examples/spa-hono-backend), `kyselygen`
  (examples/kysely/src/types.ts), `docgen` (schema.md). Diffs are minimal/correct: `ctype` enum
  `+ "audit" | "core"`, `is_core` column removed, docgen annotates core columns. Extension
  rebuilt as **fresh-install-only 0.1.1** (`deno task extension 0.1.1`): new
  `pg_semantic_platform--0.1.1.sql` full install (no is_core; ctype enum new), `default_version`
  bumped, old `--0.1.0.sql` pruned. The auto-generated `0.1.0→0.1.1` upgrade script was a no-op
  (changes are in-place edits, not new migrations) so it was DELETED — 0.1.1 is fresh-install
  only (an `ALTER EXTENSION UPDATE` honestly errors instead of silently no-op'ing). NB: `:5432`
  is now `_core`-only — run `retest` to restore the full test DB. Stale top-level
  `migrate.sql`/`rename.sql` left untouched (separate generated artifacts).
- **b7 COMPLETE.** Plan b fully done (b1–b9).

**Earlier checkpoint note (still applies):** prior batches committed; b8/b5/b3/b6/b9 were committed
by the user. b7 SQL is uncommitted on the working tree.

- ✅ Spec v2 frozen (+ I6 label-rename amendment); D1–D11 ratified; panel findings folded in.
- ✅ Red-first net built & verified: 0331 (B,D,G,H), 0332 (read bypass), 0334 (view leak)
  pinned; 0333 (I5) + 0335 (I8) green pins. Files: `apps/test/tests/0331`–`0335`.
- ✅ **b1/b2/b4 DONE & validated** — full `retest`: **1373 passing, 0 failing**:
    - b1 — `get_record_by_id` (+`set_record`) honor the canonical predicate (`0070:1494`) → 0332 green.
    - b2 — `build_select_rule_policy` gates UPDATE/DELETE via `USING` (`0180`); `update_entity_policies`
      delegates to it (`0070`) → 0331 B/D/G/H green.
    - b4 — `user_process_raci` view `security_invoker=true` (`0210:329`) → 0334 green.

### Decisions since freeze (2026-06-12)
- **b1-rpc revoke → SKIPPED.** Read bypass already closed at `get_record_by_id`; revoking
  `evaluate_json_logic` from `semantius_user` would break the operator tests (0016/0350 call it
  ~30+× under `authenticate_as`), for low marginal value. Residual `/rpc` lever = a recursion
  depth/size bound (DoS), optional.
- **b3 → small fix (keep the toggle).** `managed` model: true = DD owns the table (auto-DDL +
  policies); false = external table cataloged for read/analytics, NO auto-DDL. TRUE→FALSE is
  already inert (add/update_dd_field skip DDL when unmanaged). FALSE→TRUE (`enable_dd_table`) is
  the only risky toggle (F3 ordering). Fix = `enable_dd_table` calls `build_select_rule_policy()`
  at the end → deterministic, keeps the runtime toggle.
- **b8 I-roles guard → catalog meta-test** (model on `0240`): assert no `public` RLS policy
  targets a role ≠ `semantius_user`, and every `public` view has `security_invoker=true`.

### Next actions (in order; edit migration originals → `deno task retest --confirm --env pgdocker-cli`)
1. ✅ **b8 DONE (2026-06-12)** — catalog I-roles guard `apps/test/tests/0336_test_iroles_catalog_guard.sql`
   (sibling to `0240`): part-1 asserts no public RLS policy targets a role ≠ `semantius_user`;
   part-2 asserts every public view is `security_invoker`. Green by design; mutation-checked
   (injected a `TO authenticated` policy + a non-invoker view → both queries caught them).
2. ✅ **b5 DONE (2026-06-12)** — record-logic trigger now `BEFORE INSERT OR UPDATE OR DELETE`
   (`0180`): injects `$mode` (`insert`/`update`/`delete`), populates `$old` on DELETE (= OLD),
   evaluates rules against OLD on DELETE (computed output discarded; validation_rules can abort
   the delete). Test `apps/test/tests/0337_test_record_logic_delete_arm.sql` (mutation-checked:
   reverting the DELETE arm fails the 3 delete-discriminating assertions). Closes I7. Full retest
   **1381 passing / 0 failing**.
3. ✅ **b3 DONE (2026-06-12)** — `enable_dd_table` now ends with `PERFORM
   build_select_rule_policy(NEW.table_name)` (`0145`), so the managed F→T toggle installs the
   canonical select_rule predicate deterministically instead of depending on the alphabetical
   firing order of `manage_select_rule_policy` (F3). Test
   `apps/test/tests/0338_test_enable_managed_builds_select_rule.sql` pins end-to-end enforcement
   across the toggle. Mutation-demonstrated: disabling the 0180 managed-change arm leaves 0338
   GREEN (enable_dd_table carries it); disabling BOTH turns it RED. Full retest **1387 passing /
   0 failing**.
4. ✅ **b6 DONE (2026-06-12)** — ctype coverage for the managed timestamps: `valid_ctype`
   CHECK + `fields.ctype` enum now include `created_at`/`updated_at` (`0060`); the runtime
   generators `create_dd_table` (`0070`) and `enable_dd_table` (`0145`) stamp them on new tables;
   backfill in `0240` sets every existing `created_at`/`updated_at` row to `ctype = field_name`.
   This makes the `core = ctype <> ''` identity (spec I6) complete for the timestamps, readying
   them for b7. Test `apps/test/tests/0339_test_ctype_timestamp_coverage.sql`. Full retest
   **1394 passing / 0 failing**. (NB: created_at/updated_at are excluded from `get_schema` output
   at `0080:400`, so this changes no schema/drizzle/kysely artifact — protection behavior still
   keys on `is_core` until b7 flips it.)
5. **b7** — drop `is_core` (re-key guards to `ctype`, derive in get_schema, regen drizzle/kysely/
   docgen + extension bundle). BIGGER — regenerates client artifacts; needs its own explicit go.
6. ✅ **b9 DONE (2026-06-12)** — read-helper completeness (panel-found, not covered by b1):
   - `build_schema_for_table` (`0080`) now self-gates with the same view_permission check +
     existence-hiding as `get_schema` (identical `undefined_table` for missing-table and
     permission-denied). All 4 in-tree callers already pre-check, so the gate is redundant for them.
   - `has_consultation` (`0210`) is now caller-scoped: only a participant in the governing process
     (holds a role with a RACI assignment on it) gets the real answer; non-participants fail closed.
   - LOW: first-user→Administrator (`0050`) now also requires `NEW.last_seen IS NOT NULL`, closing
     the over-grant where a pre-login batch of users (all last_seen NULL) each became admin.
     Residual concurrency window (two users created concurrently both WITH last_seen) accepted LOW.
   Test `apps/test/tests/0341_test_read_helper_completeness.sql` (mutation-checked: reverting all
   three fixes turns the 4 security assertions red). Full retest **1402 passing / 0 failing**.
7. **0335 / I8 — DONE (deleted 2026-06-12):** the characterization test was removed (it pinned the
   leak as expected); I8 is now an accepted LOW residual (spec Appendix A). Suite = **1371 passing**
   after removal. Optional backlog: close via a definer INSERT wrapper; bound evaluator
   recursion/size (the `/rpc/evaluate_json_logic` DoS residual).
- ⚠ Test-filter footgun: use `deno task test 0332_test …` (string). A bare `0332` parses as `332`
  and matches nothing.

### Backlog / open question (parked)
- RLS on `managed=false` (external/cataloged) tables: today they get NO DD-applied row security
  (policy builders skip unmanaged; DD never enabled RLS on an external table). Decide whether
  view_permission/select_rule should apply to read/analytics there, or external = trusted/open.

## 8. Key files
- Spec `docs/authz-spec.md`; evidence `apps/test/tests/0331_test_select_rule_write_protection.sql`
- Impl: `0015` jsonlogic, `0050` rbac rls, `0060` DD schema, `0070`/`0140`/`0145` DD functions,
  `0080` public functions, `0180` computed/validation, `0210` RACI
- Harness: `deno task test <filter> --env pgdocker-cli` (live) / `retest --confirm` (full reset)
