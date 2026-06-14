# Plan: Merge the `cloud` app into `_core` (+ audit pgmq/raci queue test coverage)

## Locked decisions (user-approved; 3 subagent review passes — plan APPROVED & READY TO RUN)
- **Status: AUTHORIZED TO IMPLEMENT.** This plan is self-contained; implement it end-to-end in a
  fresh session with no further questions. All open decisions below are resolved.
- **Q1 → extension `0.1.3`** (warning-free regen; `prev=0.1.2` already carries the edited
  0020/0060 hashes).
- **Q2 → add ALL of:** pgmq-setup smoke test (`0305`); dashboards test (`0185`); deepen RACI enqueue
  assertion (message_type/id_value); RACI Informed-isolation; RACI non-admin RLS write-rejection.
- **Q3 → work directly on `main` (NO branch).** Do the `git mv`/edits/test-additions and regen in
  the working tree on `main`, run the full mandatory test sequence, and **report results** (show
  `git status` + full test output). Do **NOT** commit and do **NOT** push — the user reviews the
  uncommitted working tree and commits themselves.
- **Q4 → triggerdev bundle:** after `deno task bundle-sql`, **stage/include** the regenerated
  (tracked) `packages/triggerdev/src/migrations-bundle.ts` in the change set (its `cloud` key is gone)
  — it is part of the diff, not a stray dirty file.


## Background / motivation

- `apps/cloud/` is a separate migration folder ("extra module") with two files:
  - `0010_webhook_receiver.sql` → creates `webhook_receivers` + `webhook_receiver_logs`
  - `0020_dashboard.sql` → creates `dashboards`
- **Both already insert their entities into `module_id = 1` (the `_core` module).** So `cloud`
  is *not* actually a separate semantic module — it is only a separate deploy folder. There is no
  module-id remapping to do.
- pgmq is now unconditionally required by RACI (`0210_raci.sql` inserts a `queues` row +
  `queue_table_events` wiring for `raci_notify`), and `0160_pgmq.sql` / `0170_queue.sql` already
  live in `_core`. Keeping webhooks/dashboards in a separate optional app no longer makes sense.
- **Pre-release / prototyping**: every deploy starts from a dropped DB (`dropall`). No upgrade
  migration or backwards-compat shim is needed — folding into the base schema is safe.

## Goal

1. Move the two `cloud` migrations into `_core/migrations` so a plain `_core` deploy (and the
   generated PostgreSQL extension) creates `webhook_receivers`, `webhook_receiver_logs`, and
   `dashboards`.
2. Remove the `cloud` app and **every** reference to it (CLI commands, help text, pgdocker harness
   scripts, docs), without losing or weakening a single test.
3. Audit pgmq-setup and raci→queue test coverage; report findings and (optionally) close the gap.

---

## Part A — Move the migrations

The `_core/migrations` sequence currently ends at `0240_entities_field_metadata.sql`. The two
cloud migrations have no dependency on raci/queue; they only need the DD schema/functions
(`0060`/`0070`) and notify triggers (`0090`), all far earlier. Append them at the end:

| From | To |
|---|---|
| `apps/cloud/migrations/0010_webhook_receiver.sql` | `apps/_core/migrations/0250_webhook_receiver.sql` |
| `apps/cloud/migrations/0020_dashboard.sql` | `apps/_core/migrations/0260_dashboard.sql` |

- Move **verbatim** (content already targets `module_id = 1` and uses the DD insert pattern).
  Use `git mv` so history is preserved, then renumber.
- Delete the now-empty `apps/cloud/` directory.
- **Version-name change is expected and safe**: `_versions` rows go from `cloud.0010_webhook_receiver`
  to `_core.0250_webhook_receiver`. Because every deploy is from a dropped DB, nothing reads the old
  names. (Confirm no code greps for the literal `cloud.0010...` — none found.)

### The load-bearing ordering constraint (the reason the move is safe)
`apps/test/migrations/0030_seed.sql` (≈L371–385) INSERTs into `webhook_receivers` and
`webhook_receiver_logs`. **This only works because the webhook tables are created before the `test`
app runs.** Today that holds because `cloud` deploys before `test`; after the merge it still holds
because `_core/0250`/`0260` run during `_core`, before `test`. This is the constraint that would
break if 0250/0260 were ever numbered after `test`, omitted, or left out of the extension — so it
must be stated explicitly and verified.

### Ordering sanity checks (verify during implementation)
- `0041_test_no_unmanaged_ootb.sql` — asserts OOTB-entity managed-ness. Entities were already in
  module 1 and already deployed in the test sequence, so the asserted set is unchanged. **Verify
  it still passes** (it ran *after* cloud before; it still runs after `_core` now).
- `0072_apply_core_fts.sql` runs at 0072, before 0250/0260. `webhook_receivers` is a normal managed
  entity that gets FTS via the per-field searchable triggers, **not** via 0072, so position is fine.

---

## Part B — Catch every `cloud` reference

Confirmed inventory (from repo-wide grep). All must change so the merged layout is internally
consistent. **None of these change test behavior** — `cloud`'s migrations now run as part of `_core`.

### Code (must edit)
1. `packages/cli/commands/reset.ts`
   - L3 comment, L11 prompt text, L23 step label, **L24** `migrateCommand("_core,cloud", …)` →
     `migrateCommand("_core", …)`.
2. `packages/cli/commands/retest.ts`
   - L3 comment, L24 step label, **L25** `migrateCommand("cloud,test,nwind", …)` →
     `migrateCommand("test,nwind", …)` (migrate auto-prepends `_core`).
3. `packages/cli/cli.ts`
   - L143 help: `migrate --apps _core,cloud` → `_core`.
   - L144 help: `migrate --apps cloud,test` → `test`.

### pgdocker harness scripts (must edit — these are run by the test/deploy harness)
4. `pgdocker/pg-cli-retest.sh` / `.cmd` — replace `_core,cloud,test,nwind` → `_core,test,nwind`
   in comments + the actual `retest`/migrate invocation.
5. `pgdocker/pg-ext-retest.sh` / `.cmd` — **semantic change**, not just text:
   - The extension now bundles `_core` *including* webhook/dashboard (see Part C). The "Path B"
     step that deploys `cloud,test,nwind` on top of the extension-installed `_core` must become
     `test,nwind`. Drop the "cloud is required because test seeds webhook_receivers" rationale —
     `webhook_receivers` is now part of the extension's `_core`.
6. `pgdocker/pg-cli-deploy-module.sh` / `.cmd`, `pgdocker/pg-ext-deploy-module.sh` / `.cmd` —
   usage examples say `cloud,nwind`; change to `nwind` (or another still-valid module).
7. `pgdocker/README.md` — L282, L333–334, L341, L360, L379: update the `_core,cloud,test,nwind` /
   `cloud,test,nwind` / `cloud,nwind` references and the Path-B explanation.

### Docs (must edit for accuracy)
8. `AGENTS.md` — L109, L138, L321: `migrate --apps _core,cloud,test,nwind` → `_core,test,nwind`.
   (The "test before nwind" ordering note stays — that is about module-id sequencing, unrelated to
   cloud.)
9. `README.md` — grep for `cloud`; **expected: no app-list hits** (verify-only, likely no change).
10. `.github/copilot/environment.md` — the `cloud` hit is "GitHub's cloud environment", NOT the app
    (verify-only, no change expected).
11. `workflow.md` — the `cloud` hit is "cloudflare", NOT the app (verify-only, no change expected).
12. `plans/provenance-in-core-plan.md` L132 — historical plan; update the migrate command for
    consistency (low priority, but cheap).

### Generated artifacts — regenerate with `deno task bundle-sql`, don't hand-edit
13. `packages/{triggerdev,provisioning,neon-provisioner}/src/migrations-bundle.ts` each contain a
    `"cloud": {…}` key. `scripts/bundle-sql.ts` auto-discovers app folders, so after the move
    `deno task bundle-sql` drops the `cloud` key and folds its SQL into `_core`. The provisioning
    `migrate()` defaults to "all bundled apps" and takes an explicit `modules` list — **no hardcoded
    `cloud`** in the TS, so no source edit is required there.
    - **Tracking caveat (corrected):** `provisioning` + `neon-provisioner` bundles are genuinely
      git-ignored, BUT `packages/triggerdev/src/migrations-bundle.ts` is **a committed/tracked file**
      (despite a misleading `.gitignore` "placeholder" comment). After regenerating, the triggerdev
      bundle will appear as a **modified tracked file** with the `cloud` key removed. **Decision
      needed (Q4):** commit the regenerated triggerdev bundle, or leave it. Do not silently leave a
      dirty tracked file. (There's also a stale `webhook_receivers in 0100` comment embedded in that
      bundle's SQL — harmless, regenerated away.)

### Non-issues (confirmed, leave alone)
- All other `cloud` grep hits are `Cloudflare` / `semantius.cloud` / `@tidbcloud` / node_modules
  noise — unrelated to the app.
- `nwind` does not depend on `cloud`.
- No example app deploys the `cloud` app.

---

## Part C — Regenerate the PostgreSQL extension

The extension (`extension/`) is built by `deno task extension` from **`_core` only** (default
`apps: "_core"`). It currently does **not** include webhook/dashboard. After Part A, regenerating
will fold them in automatically.

- Current latest manifest version is `0.1.2` (uncommitted in the working tree, per git status).
  Per the provenance handoff doc, core is pre-release and ships as **v0.1.2**.
- **Edit-warning caveat (corrected):** the generator compares against
  `prev = highestVersionBelow(target)`. The working tree **already** has uncommitted edits to
  released `_core` migrations — git status shows `M 0020_rbac_schema.sql` and `M 0060_dd_schema.sql`,
  and their hashes already differ between 0.1.1 and 0.1.2 in `versions.json`. So:
  - Regenerating **as `0.1.2`** → `prev = 0.1.1` → the detector flags `0020`/`0060` as
    "edited released migration" (warnings will fire). Those edits are **pre-existing** (provenance/
    authz work, not this merge); the only *additions* from this merge are `0250`/`0260`.
  - Bumping **to `0.1.3`** → `prev = 0.1.2`, whose manifest already carries the post-edit
    `0020`/`0060` hashes → **no edit warning**; only `0250`/`0260` show as added.
- **Decision needed (Q1 below):** regenerate as `0.1.2` (accept the pre-existing 0020/0060 warnings,
  keep the pre-release version pinned) **or** bump to `0.1.3` for a warning-free run. *Revised
  recommendation: prefer `0.1.3` if a clean regeneration matters; otherwise `0.1.2` is fine as long
  as the 0020/0060 warnings are understood to be out-of-scope.*
- Command: `deno task extension <ver>`. Verify outputs: the full-install `.sql` now contains the
  webhook/dashboard DDL; the `versions.json` `<ver>` entry lists the two new files; the
  `…--<prev>--<ver>.sql` upgrade includes them.
- **Tracked-output note:** several extension outputs are version-controlled and currently modified
  (`versions.json`, `META.json`, `.control`, `extension/README.md`); the `--<prev>--<ver>.sql` and
  `--<ver>.sql` pair are untracked. Regeneration will change the tracked ones — fold into Q3/commit.
  If bumping to `0.1.3`, `pruneOldFullInstalls` deletes the untracked `…--0.1.2.sql` full install and
  writes a new `…--0.1.2--0.1.3.sql`; harmless (pre-release), just expect it.

---

## Part D — Audit pgmq / raci queue test coverage (the user's second question)

### Test files that touch the cloud entities (all to spot-check, all expected merge-insensitive)
Beyond the four named in Part A's sanity checks, these also reference `webhook_receiver`/`dashboard`
and should be spot-checked (they assert via managed-flag / FTS / enum / RLS-denial, none depend on
`cloud` being a separate app): `0010_test_rls.sql`, `0110_test_get_schema.sql`,
`0115_test_get_schemas.sql`, `0150_test_full_text_search.sql`, `0170_test_enum_constraints.sql`,
`0180_test_webhook_receiver.sql` (33 tests), plus the `0030_seed.sql` inserts noted in Part A.

### What exists today
- **`apps/test/tests/0310_test_queue.sql`** (41 tests) exercises pgmq **through** the `queues`
  entity:
  - Inserting a `queues` row registers it in `pgmq.meta` (T16), creates `pgmq.q_<name>` (T17) and
    `pgmq.a_<name>` (T18).
  - DML on a wired table enqueues INSERT/UPDATE/DELETE messages, read back via `pgmq.read` (T19–~T34).
  - Deleting the `queues` row drops it from `pgmq.meta` (T35).
- **`apps/test/tests/0350_test_raci.sql`** (tests 60–62):
  - T60: `raci_notify` queue row exists.
  - T61: `queue_table_events` wires `raci_events → raci_notify`.
  - T62: inserting a `raci_events` row **actually enqueues** a message (asserts
    `COUNT(*) > 0 FROM pgmq.read('raci_notify', …)`).

**So yes — there is real coverage that RACI creates a pgmq queue and writes to it on event insert,
and that the generic queue mechanism creates/writes/drops pgmq queues.** No existing test is being
lost or replaced by this merge (the webhook tests `0180_test_webhook_receiver.sql` + seed are
untouched and still run after `_core`).

### Gaps worth noting (report to user; implement only if they want)
1. **No direct pgmq-setup smoke test.** pgmq's schema/functions are only verified *indirectly* via
   the `queues` entity. A tiny dedicated test would assert: `pgmq` schema exists; `pgmq.meta`
   exists; `has_function('pgmq','send',…)`, `pgmq.read`, `pgmq.create`, `pgmq.drop_queue` exist;
   `semantius_user` has `USAGE` on `pgmq`. Catches a broken/missing `0160` independent of `0170`.
2. **RACI enqueue assertion could go deeper.** T62 (`0350_test_raci.sql` L674–675) **already**
   asserts `message->>'table' = 'raci_events'` and `message->>'op' = 'INSERT'`. What's *not* yet
   asserted: `message_type = 'entity_event'` and that `id_value` matches the inserted row's id.
   (Gap is narrower than first stated.)
3. **`dashboards` has zero test coverage** — no test references it (only the migration). The merge
   doesn't lose a test (there was none), but it's a pre-existing hole. Optional: a minimal
   existence/get_schema test.

### Broader coverage sweep (entities × RPC surface)
Cross-referenced every OOTB entity and every `public.*` RPC against `apps/test/tests`:
- **Entities:** all covered (2–6 test files each) **except `dashboards` = 0** — the only true
  entity-level hole. Likely slipped a prior test review precisely because it lived in the separate
  `cloud` app; folding it into `_core` brings it under the same lens (extra reason for this merge).
- **RPCs untested *by name*:** `ping()` (truly 0 — trivial healthcheck), `has_public_read()`
  (the `public:read` *permission/RLS path* is heavily tested across ~24 files, but the public RPC
  wrapper's JSON output isn't asserted), `get_schema_children()` (exercised *indirectly* inside
  `get_schema` — 6 files — but never called directly to assert the children-array shape).
  `set_entity_defaults()` shows 0 by name but is **fully tested behaviorally** by
  `0035_test_entity_defaults.sql` (22 tests) — not a gap.
- **Verdict:** the suite is thorough; `dashboards` is the one real gap. The three RPC items are
  minor (`ping` trivial; the other two have indirect coverage) — **optional**, not in scope unless
  the user wants them.

### RACI Consulted/Informed + negative-test review (deep-dive findings)
Read all 63 tests of `0350_test_raci.sql` + the migration. **Architecture note:** core does NOT
enforce gating — `0210_raci.sql:9` states enforcement is the two helper functions (`is_raci_actor`,
`has_consultation`) exposed as JsonLogic operators, intended for skill-authored
`validation_rules`/`select_rule`. So "a gate actually blocks a write" is a validation-rules concern,
not core-RACI.
- **Consulted — solidly covered:** assignment w/ `consult_mode='block'` (T24), event insert (T35),
  `has_consultation` pending→acted (T43/44), JsonLogic operator both branches (T49/50), emit (T54–56),
  caller-scoping in `0341`.
- **Informed — only covered *collectively* as "C/I", never isolated:** T54/55/56 lump consulted +
  informed into one count, and the fixture assigns BOTH to the same role (Sales User). A bug emitting
  two `consulted` + zero `informed` events would still pass. No per-letter breakdown; C and I never
  held by different roles; informed's "notify/read, never blocks" semantics untested.
- **Negative tests present (8 `throws_ok` in 0350):** T20 dup process_key (23505), T21 non-snake_case
  key (23514), T22 bad RACI letter (23514), T25 second-accountable invariant (23505), T26 bad
  consult_mode (23514), T28 bad gate_kind (23514), T33 raci_events.raci not C/I (23514), T34 bad
  status (23514). Plus adjacent security negatives: `0334` (view leak), `0336` (I-roles catalog
  guard), `0341` (caller-scoping).
- **Negative gaps:** (i) no behavioral RLS write-rejection in 0350 — every write runs as admin; no
  `throws_ok` that a non-privileged user is denied writing `processes`/`raci_assignments`/
  `process_gates`. (ii) no FK-violation negative (minor/generic). (iii) end-to-end gate enforcement
  ("transition blocked when consultation missing / caller isn't the actor") is tested by neither
  suite — only the helper booleans are.

### Test additions (Q2 decisions — ALL confirmed by user)
- **[DECIDED — add]** `apps/test/tests/0305_test_pgmq_setup.sql` — pgmq install smoke test (gap #1).
  Numbered before `0310` so a pgmq-install failure surfaces first. Asserts: `pgmq` schema exists;
  `pgmq.meta` exists; `has_function('pgmq','send',…)`, `pgmq.read`, `pgmq.create`,
  `pgmq.drop_queue`; `semantius_user` has `USAGE` on schema `pgmq`.
- **[DECIDED — add]** Deepen `0350_test_raci.sql` T62 with `message_type = 'entity_event'` and
  `id_value`-matches-inserted-row assertions (gap #2); bump the file's `plan(N)` count accordingly.
- **[DECIDED — add]** `apps/test/tests/0185_test_dashboards.sql` (gap #3; `0185` is free, sits next
  to the webhook test `0180`) — minimal: entity exists + `managed`; `get_schema('dashboards')` returns
  `config`(json)/`position`(int32)/`module_id`(ref→modules)/`view_permission`(ref→permissions); FK
  insert + delete-mode behavior; optional admin RLS. ~10–15 assertions.
- **[DECIDED — add] RACI Informed isolation** (in `0350_test_raci.sql`): change the make_offer
  fixture so Consulted and Informed are held by **different roles**. Seeded roles available:
  `User` (id 1), `Administrator` (id 2), `Sales User` (test seed). Current fixture is R=Sales User,
  A=Administrator, C=Sales User, **I=Sales User** → change **I to `User`** (distinct from both
  C=Sales User and A=Administrator). Then after the emit transition assert **exactly one**
  `raci='consulted'` event with `target_role_id` = Sales User's id AND **exactly one**
  `raci='informed'` event with `target_role_id` = User's id. Re-verify count-based T54/T56 still hold
  with the adjusted fixture (count is still 2 = 1 C + 1 I); bump `plan(N)`.
- **[DECIDED — add] RACI negative RLS write-rejection** (in `0350_test_raci.sql`): authenticate as a
  non-privileged user (e.g. `user1`) and `throws_ok` (or `is(...0)` under RLS) on an INSERT into
  `raci_assignments` (and/or `processes`/`process_gates`) — proves the catalog is admin-write-gated
  behaviorally, not just by policy shape. Restore `authenticate_as('user3')` afterward; bump `plan(N)`.
- **[NOTED — not implemented here]** End-to-end gate enforcement (a write actually blocked when
  `has_consultation`/`is_raci_actor` is false) belongs in a **`validation_rules` integration test**,
  not core-RACI. Flag to whoever owns the validation-rules suite; out of scope for this plan.

---

## Execution order

1. `git mv` the two cloud files into `_core` with new numbers; remove `apps/cloud/`.
2. Edit code refs (reset.ts, retest.ts, cli.ts).
3. Edit pgdocker scripts + README (Path-B semantic change included).
4. Edit docs (AGENTS.md, README.md, copilot env, workflow.md, provenance plan).
5. Tests: add `0305_test_pgmq_setup.sql`; add `0185_test_dashboards.sql`; in `0350_test_raci.sql`
   deepen T62 (message_type/id_value), add Informed-isolation assertions (C/I on different roles),
   and add a non-admin RLS write-rejection test — re-bump `plan(N)` for each edit.
6. `deno task bundle-sql` (regenerates bundles; triggerdev one is tracked — see Q4).
7. `deno task extension 0.1.3` (regenerate extension).
8. **Full mandatory test sequence** (AGENTS.md): `connect` → `dropall --confirm` →
   `migrate --apps _core,test,nwind --verbose` → `test`. All green, full output shown.
9. Optionally run a pgdocker harness (`pg-cli-retest`) to validate the edited scripts end-to-end.

## Risks / watch-items
- A test that implicitly assumed webhook/dashboard arrived *after* the whole `_core` run. Since they
  now run mid-`_core` (0250/0260) but still before `test`/`nwind`, the observable end-state for
  tests is identical. Verify `0041_test_no_unmanaged_ootb` and any `get_schema`/`get_schemas`
  count-based test (`0110`, `0115`) still pass.
- Extension regeneration at **0.1.3** (`prev=0.1.2`): only `0250`/`0260` are added, so it should run
  warning-free. (Regenerating *as 0.1.2* instead would warn about the already-edited 0020/0060 — see
  Part C; that's why 0.1.3 was chosen.)
- `deno fmt`/`deno check` on the three edited TS files (`reset.ts`, `retest.ts`, `cli.ts`).
- The RACI Informed-isolation change edits a shared fixture other tests read; re-run the **whole**
  `0350` file and confirm T54/T56/T62 still pass after the C/I-role split.

## Open questions for the user
- **Q1 (extension version):** regenerate as `0.1.2` (keeps the pre-release version pinned, but the
  generator will warn about the already-edited `0020`/`0060` — out of scope for this merge) **or**
  bump to `0.1.3` (warning-free; `prev=0.1.2` already carries those hashes)?
- **Q2 (test gaps):** just merge + report the coverage findings, or also add the pgmq-setup smoke
  test, deepen the RACI enqueue assertion (`message_type`/`id_value`), and/or add a `dashboards` test?
- **Q3 (commit):** stop after green tests for review, or also commit (on a branch, since we're on
  `main`)? Note regeneration also modifies tracked extension files (`versions.json`, `META.json`,
  `.control`, `extension/README.md`).
- **Q4 (triggerdev bundle):** after `deno task bundle-sql`, the **tracked**
  `packages/triggerdev/src/migrations-bundle.ts` changes (cloud key removed). Commit it, or leave it?
