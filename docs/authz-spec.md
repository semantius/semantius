# Authorization Model — Specification v2 (FROZEN 2026-06-11)

**Status:** FROZEN v2. Incorporates the stage-2 adversary panel findings and decisions
D1–D11. Amendments require explicit review (note the change in this header).
**Amended 2026-06-12:** I6 corrected — the label-column rename restriction was *intentionally
lifted*; renaming the label column is a feature, not a DD-integrity violation.
**Amended 2026-06-12 (b-impl):** b1/b2/b4 implemented & validated — the read bypass, the I2/A4
write-delete bypass, and the `user_process_raci` view leak are FIXED. The `/rpc/evaluate_json_logic`
revoke was declined (read bypass closed at the helper instead). Live status →
`plans/authz-remediation-plan.md` §7.
**Amended 2026-06-12 (b5/b8):** I7 FIXED — the record-logic trigger gained a DELETE arm with
`$mode`/`$old`; validation_rules now govern deletes (test `0337`). I-roles backstopped by a
catalog guard (`0336`): no public RLS policy targets a role ≠ `semantius_user`; every public
view is `security_invoker`.
**Amended 2026-06-12 (b7):** I6 FIXED — `is_core` dropped; core identity is the single
un-tamperable marker `ctype <> ''` (enum adds `audit`/`core`), with a privilege-locked, immutable
`ctype` (`fields_ctype_lock`) and all guards re-keyed off it; is_core derived in `get_schema`.
Tests `0339`/`0342`. Protected-set verified unchanged vs the pre-b7 `is_core` set. Client-artifact
regen pending (plan §7 b7.8).
**Amended 2026-06-12 (b3/b6/b9):** b3 — `enable_dd_table` builds the select_rule policy
deterministically on the managed F→T toggle (`0145`, test `0338`). b6 — `created_at`/`updated_at`
carry `ctype` (`0060`/`0070`/`0145`/`0240`, test `0339`), completing the `core = ctype <> ''`
identity for the timestamps. b9 — read-helper completeness FIXED: `build_schema_for_table`
self-gates by view_permission, `has_consultation` is caller-scoped, first-user bootstrap over-grant
closed (test `0341`). Live status → `plans/authz-remediation-plan.md` §7.
**Purpose:** the single source of truth for *intended* RBAC/ABAC/DD-integrity behavior.
Tests and implementation derive from THIS document, independently of each other.

## How to use this document (isolation rules)

- **Tests derive from this spec, never from the implementation.** A test asserts an
  invariant cell below, not what the code currently does.
- **Implementation satisfies this spec.** Disagreement = a code bug or an explicit,
  reviewed amendment — never a silent drift.
- **Every invariant × axis cell is tested or marked N/A with a written reason.** No silent
  coverage caps. (Every gap found so far was an un-enumerated cell.)
- **Confirmed/suspected violations live in Appendix A**, separate from the oracle.

---

## Architecture premises (load-bearing)

- **P1 · Database-per-tenant.** Each tenant has its own PostgreSQL database; there is no
  in-DB `tenant`/`org` column. Tenant isolation is the database/connection boundary, out of
  scope. Every invariant concerns authorization *within one tenant's database*.
- **P2 · Admin sees all (non-goal: admin-blind data).** RBAC/ABAC protects users *from each
  other* and blocks unauthorized access. It does **not**, and cannot, protect data from a
  DB/infra admin or from backup access (RLS/policies are schema rules; a backup is raw data;
  whoever restores it owns the instance). True admin-opacity would require app-layer
  encryption with external key custody — explicitly out of scope. Therefore "admin sees all"
  is a premise, and audit-log/`has_consultation` exposure *to admins* is accepted, not a leak.
- **P3 · Role model.** The request-path role is **`authenticated`**, which is an INHERIT
  member of **`semantius_user`**; all RLS policies are authored `TO semantius_user` and apply
  to `authenticated` by membership. Tables are owned by a BYPASSRLS migration role distinct
  from the request role. `SECURITY DEFINER` functions run as that owner (RLS-off inside).

---

## THE CANONICAL PREDICATE (D8 — the heart of the model)

There is exactly **one effective row-access predicate per entity**:

```
access(row) =  select_rule(row)                    when select_rule is non-empty   ← the rule REPLACES the permission
               has_permission(view_permission)     otherwise (the "default rule")
```

- **REPLACE semantics:** a non-empty `select_rule` IS the complete authorization. It is
  **not** AND-ed or OR-ed with `view_permission`; `view_permission` is simply the default
  predicate used when no rule is set. (`view_permission` = "may reach this resource" — it is
  *not* a "see-all" override.)
- **Permissions are operators inside rules.** "Support sees all" is written as a
  `{"has_permission":"…"}` disjunct *in the rule*, not as `view_permission`. Grants
  (ownership, assignment, RACI, blanket-role) compose as an OR *inside* the rule. This is the
  ReBAC model: one check expression; roles are just terms in it.
- **`is_raci_actor`** (caller-scoped) is the RACI visibility grant. **`has_consultation`**
  is record-scoped (ignores the caller) and MUST NOT be used as a per-user visibility grant.
- **Forgetting a grant fails CLOSED** (denies) — the safe direction. The only hazard is an
  accidentally always-true rule; mitigated by author-time validation + tests.

**This single predicate MUST be enforced identically in every access path** (this is the
core of the remediation — today it is not):

| Path | required |
|---|---|
| SELECT RLS policy | evaluate `access(row)` (already does when rule set) |
| `get_record_by_id` / `set_record` / `build_schema_for_table` / reference-label joins | evaluate `access(row)` — **today they check only `view_permission` → the bypass** |
| UPDATE / DELETE `USING` | `has_permission(edit_permission) AND access(row)` — can't write a row you can't read |
| `INSERT`/`UPDATE` `WITH CHECK` | `has_permission(edit_permission)` (+ optional post-image `check_rule`, unbuilt) |

---

## Axes (countable coverage dimensions)

- **A1 · Subject** — anonymous · authenticated-no-perm · view-only · edit-but-no-view ·
  view+edit · row-owner/grantee · non-owner+edit · admin (auto-grants all) · API-key vs JWT ·
  `is_agent` service principal · disabled · `semantius_user`/`authenticated` vs DEFINER vs
  BYPASSRLS owner.
- **A2 · Object** — data entity with/without `select_rule`/`validation_rules`/`computed_fields` ·
  parent/child FK · DD-meta (`entities`,`fields`) · RBAC (`users`,`roles`,`permissions`,
  `role_permissions`,`user_roles`,`user_permissions`,`permission_hierarchy`) · RACI
  (`processes`,`raci_assignments`,`process_gates`,`raci_events`) · system (`_apikeys`,
  `audit_record_logs`,`audit_ddl_logs`,`webhook_*`,`queues`,`modules`,`_settings`) · derived
  (views incl. `user_process_raci`, `search_vector`, cubes, `get_schema`/`build_schema_for_table`).
- **A3 · Operation** — SELECT · INSERT · UPDATE · DELETE · DD-ops (create/alter/drop/rename).
- **A4 · Statement shape** — qualified-reading-a-column · **bare/`WHERE TRUE`/`SET=const`
  (reads no column)** · RETURNING · writable CTE · `ON CONFLICT DO UPDATE`/`DO NOTHING` ·
  `MERGE` · `UPDATE…FROM`/`DELETE…USING` · sub-select · FK cascade.
  **NB:** PG applies the SELECT policy to UPDATE/DELETE iff the statement *reads a column*,
  NOT because it is "qualified." The protective axis is "reads-a-column," and the only sound
  fix is to gate writes via `USING` (above), not to rely on the SELECT policy.
- **A5 · Condition state** — `select_rule` set/empty · `validation_rules`/`computed_fields`
  present · variable injection `$user_id`/`$old`/`$now`/`$today`/`$mode`(planned) ·
  `view_permission` (= reach) · `WITH CHECK`.
- **A6 · Enforcement layer** — RLS policy (bypassed by owner/BYPASSRLS) · BEFORE trigger
  (fires for owner; bypassed by `session_replication_role=replica`) · SECURITY DEFINER logic ·
  PostgREST/RPC.
- **A7 · Grant path** — role→`role_permissions` · direct `user_permissions` · recursive
  `permission_hierarchy` (permissions, NOT roles — roles are flat) · OAuth-scope intersection ·
  `is_disabled` gate · permission cache `app.user_permissions` (transaction-scoped).
- **A8 · Shared JsonLogic surface** — evaluator `evaluate_json_logic`/`jl_truthy`; operators
  `has_permission`, `is_raci_actor`, `has_consultation`, **`set_record`**, **`require_permission`**,
  **`throw_error`**, **`value_changed`**, + comparison/logic/arithmetic/regex; RPC exposure:
  `/rpc/has_permission`, `/rpc/is_raci_actor`, `/rpc/has_consultation`, **`/rpc/evaluate_json_logic`**,
  **`/rpc/get_record_by_id`**, **`/rpc/build_schema_for_table`**, `/rpc/get_schema*`.

---

## Invariants (must hold across all of A1–A8)

- **I1 · Read confinement** — no subject reads a row outside `access(row)` (the canonical
  predicate) via ANY path: SELECT, RETURNING, sub-select, **`get_record_by_id`/`set_record`/
  `build_schema_for_table`**, view, search, FK-label join, cube, or error message.
- **I2 · No write/delete of inaccessible rows** — a subject cannot UPDATE/DELETE a row for
  which `access(row)` is false, under EVERY statement shape (A4). Enforced via UPDATE/DELETE
  `USING`, not via incidental SELECT-policy application.
- **I3 · Write authorization** — writes require `has_permission(edit_permission)` AND
  `access(row)` on the affected row. An optional per-entity `check_rule` (post-image
  `WITH CHECK`) MAY further constrain new rows; it is currently unbuilt.
- **I4 · RBAC required** — no operation without its permission, including indirect paths
  (cascade, definer, upsert, RPC).
- **I5 · No privilege escalation** — cannot self-grant by writing `user_roles`/
  `role_permissions`/`user_permissions`/`permissions`/`permission_hierarchy`/`raci_assignments`
  without the governing permission. (Bootstrap first-user→admin is a characterized exception.)
- **I6 · DD integrity** — core fields (identified by `ctype <> ''`) cannot be deleted or
  structurally altered (format/default/pk) by any non-migration subject, via any op/shape/role;
  they cannot be renamed EXCEPT the label column (`ctype='label'`), whose rename is
  *intentionally allowed* and cascades to `entities.label_column` (pinned by
  `0292_test_label_column_rename.sql`). The core marker cannot be set/cleared to trap or free a
  field. Enforced by an all-roles trigger keyed on `ctype` (NOT the mutable `is_core` flag).
- **I7 · Rule completeness** — `validation_rules`/`computed_fields` evaluate for every
  affected row on INSERT/UPDATE/**DELETE** regardless of shape, with correct `$mode`/`$old`.
  Computed fields are authoritative (override user input).
- **I8 · No side-channel leak** — unique/FK violations, EXPLAIN estimates, `has_consultation`,
  metadata RPCs do not reveal existence/content of inaccessible rows. (I8 is structurally
  *guaranteed* by PG for unique constraints on `select_rule` entities — see Appendix A.)
- **I9 · Cascade safety** — `ON DELETE CASCADE`/`SET NULL` behavior is characterized; accepted
  that parent-delete authority governs the cascade (D3); credential/audit children noted (D9).
- **I10 · Right layer** — visibility → RLS + the canonical predicate re-applied in every
  DEFINER read path; DD integrity → all-roles trigger.
- **I-roles · Role hygiene** — `authenticated` INHERITs `semantius_user`; policies authored
  ONLY `TO semantius_user` (never `TO authenticated`/`TO public`); request role is non-owner,
  non-BYPASSRLS. Views are `security_invoker = true`.
- **I-perm · Permission resolution** — correct across all A7 paths; consistent at transaction
  boundaries (cache is tx-scoped; revoke/disable propagate on the next transaction, never
  mid-transaction; first-touch must seed the cache). In OAuth bearer sessions
  (`rbac.is_bearer_session()`) the cache is bypassed and the context re-derived on every
  call, because the request role can write the `app.*` GUCs there; readers that need the
  user id outside a permission check go through `rbac.user_id_or_null()`, never the raw GUC.
- **I-jsonlogic · Evaluator/operators** — each operator correct in isolation; record-reading
  operators (`set_record`/`get_record_by_id`) enforce `access(row)`, not just `view_permission`
  (read bypass closed at the helper — b1). `evaluate_json_logic` stays callable by the request
  role (the operator tests need direct calls) but is therefore NOT a read-confinement hole; the
  residual concern is bounded recursion/size (DoS), accepted.

---

## Decisions (ratified 2026-06-11)

- **D1 → subsumed by D8.** The `select_rule`-vs-permission combination question is settled by
  the canonical predicate (REPLACE). A separate post-image `check_rule` (WITH CHECK) remains
  an optional, currently-unbuilt refinement (I3).
- **D2 · Bulk write touching inaccessible rows → SILENT FILTER** (inherent to USING gating).
- **D3 · Cascade delete of children not directly deletable → ACCEPTED** (parent authority
  governs), with a mandatory I9 characterization test.
- **D4 · Privileged path (BYPASSRLS/superuser/owner) → TRUSTED / out of scope.** Regular
  access is `authenticated`/`semantius_user`, fully in scope. DEFINER *logic* is in scope.
- **D5 · Core-field protection → TRIGGER, all roles, keyed on `ctype`.** Not a JsonLogic rule
  (a tenant-editable rule could be edited away). is_core *identity* → `ctype`; *protection*
  stays a trigger; the `$mode`/DELETE arm is for tenant rules, not core protection.
- **D6 · API-key principal → SAME authz as the user's JWT** (scopes applied). Agents are
  dedicated `is_agent` users with their own permissions.
- **D7 · New-test placement → extend the existing home file** for object/op cells; new files
  for cross-cutting invariants (I1/I2/I5/I8/I9/I-roles).
- **D8 · `select_rule` REPLACES `view_permission`** (the canonical predicate above). The rule
  is the sole authorization when set; `view_permission` is the no-rule default; permission
  checks are in-rule operators. The fix is to enforce the one predicate identically in the
  SELECT policy, the DEFINER read helpers, and the write `USING` clauses.
- **D9 · Cascade into credential/audit children → mostly ACCEPT** (deleting a user *should*
  clean up keys/grants, and it requires parent-delete authority). Reconsider only
  `raci_events` (`target_role_id` cascade is the least defensible for an audit log).
- **D10 · Definer read-helper bypass → FIX, red-first (priority #1).** Make
  `get_record_by_id`/`set_record`/`build_schema_for_table` apply `access(row)`; lock down
  `/rpc/evaluate_json_logic` (revoke from the request role, or bound it). Pin with a regression
  test FIRST (it regressed before precisely because nothing pinned it).
- **D11 · FORCE RLS → SKIP.** Given the BYPASSRLS owner is separate from the non-privileged
  request role, FORCE adds nothing (BYPASSRLS overrides FORCE). Protection = role separation
  (pin via I-roles guard test) + fixing the DEFINER helpers (D10).

---

## Test methodology rules (binding on plans a/b/c)

- Spec-derived, not implementation-derived. Red-first where possible; new-capability cells
  use spec-derivation + adversarial review + a mutation check.
- Coverage ratchet: snapshot `{file→planned count}` + covered-cell set before changes; final
  suite must be a superset; no test dropped without a written map to a stronger one.
- One canonical test per cell. N/A cells carry a one-line reason.

---

## Appendix A — confirmed & suspected violations (NOT the oracle)

**FIXED (b1/b2/b4, validated 2026-06-12 — kept for history):** the read bypass (b1), the I2/A4
write-delete bypass (b2), and the `user_process_raci` view leak (b4) below are RESOLVED; their
red-first tests (0331/0332/0334) are now green. Items NOT marked FIXED remain open.

**CONFIRMED (stage-2 panel, evidence cited):**
- **CRITICAL — I1/I-jsonlogic [FIXED b1]:** `get_record_by_id` checks only `view_permission`, never
  `select_rule` (`0070:1508`); `set_record` calls it (`0210:565`); `evaluate_json_logic` is
  granted to the request role (`0015:721`) → any `public:read` holder reads any `select_rule`-
  hidden row via `/rpc/evaluate_json_logic` or `/rpc/get_record_by_id`. (D10)
- **I1 enforcement inconsistency:** the SELECT policy honors the rule but the DEFINER read
  helpers honor only `view_permission` — the disagreement IS the bypass.
- **I2/A4:** "qualified ⇒ protected" is wrong; `DELETE FROM t WHERE true` / `UPDATE … SET
  c=const` bypass the rule (read no column); some bare statements ARE protected. Fix = USING
  gating. (`0070:289-309`, `0180:302`; test `0331` cases B/D.)
- **I7 [FIXED b5]:** the record-logic trigger is now `BEFORE INSERT OR UPDATE OR DELETE` (`0180`)
  with `$mode`/`$old` injected and the rules evaluated against OLD on DELETE → validation_rules
  govern deletes; was previously `BEFORE INSERT OR UPDATE` only. (test `0337`.)
- **I6 [FIXED b7]:** the mutable `is_core` flag was dropped; core identity is now the single
  marker `ctype <> ''` (`['', 'id', 'label', 'audit', 'core']`). All protection guards (delete
  `0070`, rename + format `0140`, format/default `0145`) re-key on `coalesce(OLD.ctype,'')<>''`,
  and `ctype` is immutable + privilege-locked (`fields_ctype_lock`, `0070`): only a BYPASSRLS
  DD/migration caller may set/change it (user INSERT → forced '', user UPDATE changing it →
  rejected). So the marker can no longer be set/cleared to trap or free a field. is_core is
  derived (`ctype<>''`) in `get_schema`. (Label-column rename remains the one allowed exception.)
  Tests `0339`/`0342`. (Client artifact regen pending — plan §7 b7.8.)
- **I-roles:** `user_process_raci` view lacks `security_invoker` (`0210:329`) → non-admins read
  the whole RBAC/RACI assignment graph.
- **I3/D8:** `check_rule` is entirely unimplemented (no column/logic).
- **I8:** unique/FK violations on `select_rule` entities are an existence oracle (structural,
  not "suspected"); `has_consultation` is a record-existence oracle not caller-scoped (`0210:292`).
- **I-perm:** permission cache is transaction-scoped; first-touch stale-empty snapshot patched
  only in `get_userinfo` (`0080:110-121`); admin auto-grant bound to literal role name
  `Administrator`.
- **I5 (bootstrap):** first-user→Administrator keyed on race-prone `last_seen IS NOT NULL`
  heuristic (`0050:284-295`).

**ACCEPTED (per premises/decisions, not violations):** `select_rule` REPLACE semantics (D8);
audit-log read exposure to admin (P2); cascade into credential children (D9); DD metadata
world-readable to `public:read` (intended); BYPASSRLS owner out of scope (D4); the unique-
constraint existence oracle (I8) as a LOW residual (closing it needs a definer INSERT wrapper).

**FIXED (b9, validated 2026-06-12 — kept for history):**
- `has_consultation` [FIXED b9]: now caller-scoped (`0210`) — only a participant in the governing
  process gets the real answer; non-participants fail closed. (test `0341`.)
- `build_schema_for_table` [FIXED b9]: now self-gates by view_permission with the same
  `undefined_table` existence-hiding as `get_schema` (`0080`), so the direct `/rpc` call no longer
  bypasses the wrappers. (test `0341`.)
- first-user→Administrator [FIXED b9, LOW]: bootstrap now also requires `NEW.last_seen IS NOT NULL`
  (`0050`), closing the pre-login batch over-grant. Residual concurrency window accepted LOW.
