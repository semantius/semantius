# Provenance in Core — v0.1.2 change notes (for the skill agents)

**Audience:** the authors of the architect / analyst / modeler / `use-*` discovery skills, and the
author of `semantius-agent/provenance-in-platform-plan.md`.

**Status:** **Specification for the v0.1.2 build — not yet merged into the migrations.** `semantius-core`
is pre-release, so there is no upgrade path to preserve and these changes are **folded into the base
migrations** (no `0250`/`0260` add-on). Once built, a fresh `dropall → migrate` produces the columns.
Both review passes (security/testing + completeness) are incorporated.

This document is the **contract**: what core now stores, in core's *real* terms (which differ from the
platform-plan's abstraction in two places — read §2 first), how to stamp it, what core validates, and
what core does **not** do. It supersedes the migration-numbering in
`plans/provenance-in-core-plan.md` (the column set and tests there still stand; only the "add a new
migration" mechanic is replaced by "edit the base migrations").

---

## 1. TL;DR

- 8 new columns added by editing base `CREATE TABLE`s + DD seed blocks: 5 on `entities`, 1 on
  `fields`, 1 on `modules`, 1 on `roles`. Plus an optional `lifecycle_states` registry table (D3).
- They default to **empty** (`''` / `'{}'` / `'[]'` / `'unclassified'`) — omit them and behaviour is
  unchanged (additive-safe).
- **`is_core: true` does not exist as a column.** It is now expressed as **`ctype = 'core'`** on the
  field-metadata row. (§2)
- **"nullable, default empty"** from the plan = **NOT NULL with an empty default** in core (no-NULL
  policy). (§2)
- Core validates **shape** (object/array/enum CHECKs) and protects the columns as core (un-deletable,
  ctype-locked). Core does **not** enforce write-once or derive `entity_type` — those are skill/modeler
  responsibilities unless we decide otherwise (§6, §8).
- Rename-discovery is now **explicitly tested** at the data-substrate level (§7) — this was missing
  from the first draft and is fixed.

---

## 2. The two corrections every agent must internalize

The platform-plan's `create_field`-style JSON blocks (`"is_core": true`, `"unique_value": false`,
`"format": "string"`) describe an *abstraction*. Core's reality:

### 2.1 `is_core` → `ctype = 'core'`
The boolean `is_core` column was **dropped**. A field's core status is its **`ctype`** enum
(`'' | id | label | audit | core`); `is_core` is *derived* as `(ctype <> '')` and still emitted in
`get_schema()` for compatibility. Every provenance field is registered with **`ctype = 'core'`**.
`ctype` is privilege-locked (`fields_ctype_lock` trigger): only BYPASSRLS/migration code may set it, so
**the modeler never sets `ctype`** — it writes the column *values*, and core already stamped the
metadata. A non-empty `ctype` automatically makes the column un-renamable / un-deletable.

### 2.2 "nullable, default empty" → NOT NULL + empty default
Core enforces a **no-NULL policy**; `is_nullable(format)` is TRUE only for `reference`/`date`/
`date-time`. So `string`/`json`/`enum` columns are **NOT NULL**. "Absent" is represented by `''`
(text), `'{}'` (json object), `'[]'` (json array), `'unclassified'` (enum) — **never SQL NULL**. When
a discovery skill checks "is this empty?", it tests `= ''` / `= '{}'::jsonb` / `= '[]'::jsonb`, not
`IS NULL`.

(Also: the physical table is `entities`; `tables` is a `SELECT *` compat view that inherits the new
columns automatically.)

---

## 3. Columns added — the storage contract

### 3.1 `entities` (5 columns)
Declared inline in `CREATE TABLE entities` with these exact types/defaults/CHECKs:

```sql
catalog_entity_code     TEXT  NOT NULL DEFAULT '',
canonical_owner_module  TEXT  NOT NULL DEFAULT '',
entity_type             TEXT  NOT NULL DEFAULT 'unclassified',
pattern_flags           JSONB NOT NULL DEFAULT '{}'::jsonb,
catalog_entity_aliases  JSONB NOT NULL DEFAULT '[]'::jsonb,
-- inline CHECKs (alongside the existing computed_fields_is_array etc.):
CONSTRAINT valid_entity_type CHECK (entity_type IN
  ('operational_workflow','operational_record','catalog','junction','computed','unclassified')),
CONSTRAINT pattern_flags_is_object        CHECK (jsonb_typeof(pattern_flags) = 'object'),
CONSTRAINT catalog_entity_aliases_is_array CHECK (jsonb_typeof(catalog_entity_aliases) = 'array')
```

| Column | Meaning (for skills) | Notes |
|---|---|---|
| `catalog_entity_code` | **Canonical** uber-model code (D6), e.g. `vendors`. The rename/dialect/silo **join key**. | Non-unique (shared masters & silos recur; disambiguate by `module_id`). `table_name` holds the deployed name and may drift; this does **not**. Empty = created outside the pipeline (genuine custom). |
| `canonical_owner_module` | For an `embedded_master` placeholder: slug of the owning module. | Soft string pointer, **not** an FK — target may not be deployed yet. Empty when this module *is* the owner or the entity is local. |
| `entity_type` | Data-class axis (D9), closed 6-value set. | `write tier` derives **from** it, not the reverse. `unclassified` = absent/derive-locally. No `platform`/`log`/`reference`. |
| `pattern_flags` | Authored behaviour flags, sparse `{flag: true}`. | Bare authored names (no `has_` prefix). Confirmed keys: `personal_content`, `submit_lock`, `single_approver`. Missing key = false. Core does **not** constrain the key set. |
| `catalog_entity_aliases` | Reuse/merge record: array of `{alias_code, source_domain, source_module, decided}`. | **Append-only** (a later cross-domain merge adds an element). Empty array = never a merge target. Resolving unit is the `(alias_code, source_domain)` pair. |

### 3.2 `fields` (1 column)
Inline in `CREATE TABLE fields`:
```sql
catalog_field_code  TEXT NOT NULL DEFAULT '',
```
Canonical/blueprint field name (e.g. `status`). The **field-rename join key** (`field_name` drifts to
`disposition`; this stays `status`). Empty = outside the pipeline.

### 3.3 `modules` + `roles` (1 each)
Inline in `CREATE TABLE modules` / `CREATE TABLE roles` (both **non-unique** lineage — a clone deploys
one catalog code into several modules; `module_slug`/`roles.slug` remain identity):
```sql
-- modules
catalog_module_code  TEXT NOT NULL DEFAULT '',   -- e.g. ATS-CANDIDATE-CRM; also the domain axis
-- roles
catalog_role_code    TEXT NOT NULL DEFAULT '',   -- catalog persona; no consumer yet (D5 insurance)
```

### 3.4 `modules.settings.*` — **no DDL**
`catalog_snapshot`, `naming_mode`, `module_kind`, `promotion_decisions` live as keys in the existing
freeform `modules.settings` JSONB. Core adds nothing and constrains nothing — the modeler reads/writes
them as plain JSON.

### 3.5 `lifecycle_states` registry (D3) — **DEFERRED, not in v0.1.2**
Per the plan author's ruling (§8 Q5): do **not** ship a standalone table. The lifecycle slice will
**extend `process_gates`** when the RACI-in-platform work lands. The §3.1–§3.3 columns ship in v0.1.2
without it. The shape below is retained for that future work only.

A governed registry anchored on `(entity, state_column, state)` so the **state column is readable** (no
more guessing `status`/`state`/`lifecycle_state`):

| field | type | meaning |
|---|---|---|
| `entity` | text | governed table (mirrors `entities.table_name`) |
| `state_column` | text | which column holds the state (the anchor) |
| `state` | text | the enum value (matches a `fields.enum_values` entry) |
| `state_order` | integer | authored display order |
| `is_initial` | boolean | initial state |
| `is_terminal` | boolean | terminal state (`terminal_lock` is the **consequence** of this — D1, one home) |
| `requires_permission` | text | workflow-gate permission to enter this state; cross-refs `process_gates` |

The full transition graph is deliberately out of scope (discovery confirmed it isn't needed).

---

## 4. Where the edits land (for reviewers)

| Change | File |
|---|---|
| `modules.catalog_module_code`, `roles.catalog_role_code` (CREATE TABLE) | `apps/_core/migrations/0020_rbac_schema.sql` (modules @ ~L10–26, roles @ ~L82–93) |
| `entities` 5 columns + CHECKs (CREATE TABLE) | `apps/_core/migrations/0060_dd_schema.sql` (CREATE TABLE entities @ L13–53) |
| `fields.catalog_field_code` (CREATE TABLE) | `apps/_core/migrations/0060_dd_schema.sql` (CREATE TABLE fields @ L84–147) |
| DD field-metadata seed rows (`ctype='core'`) for all 8 | `apps/_core/migrations/0060_dd_schema.sql` (entities seed L444–466, fields seed L391–417, modules seed L482–501, roles seed L507–516) |
| `lifecycle_states` table (if adopted) | `apps/_core/migrations/0210_raci.sql` (new STEP, after `process_gates`) |
| Regenerated docs | `schema.md` via `deno task docgen` |

**Seed-row shape** (example — the entity codes; `ctype='core'` is the critical column):
```sql
('entities','catalog_entity_code','Catalog Entity Code','Canonical identity (uber-model code)…',
 'text', 126, 'default','default','core',''),
('entities','entity_type','Entity Type','Data-class axis (D9)…','enum', 122,'readonly','default','core',
 'unclassified','["operational_workflow","operational_record","catalog","junction","computed","unclassified"]'::jsonb),
('entities','pattern_flags','Pattern Flags','Authored behaviour flags…','json',128,'default','w','core',''),
('entities','catalog_entity_aliases','Catalog Entity Aliases','Reuse/merge aliases…','json',129,'default','w','core','')
```
The metadata seed runs in `0060`, *before* the `add_dd_field` trigger exists (`0070`), so these INSERTs
are **pure registration** — the physical columns come from the `CREATE TABLE`s. That is why the columns
must be declared inline (matching how every existing core column is both declared and seeded).

---

## 5. The write contract for the modeler

1. **Omit = safe.** Every column defaults empty; an un-upgraded modeler keeps working, existing rows
   read empty, discovery falls back to today's behaviour.
2. **`catalog_entity_code` stamps the CANONICAL code (D6)** — `vendors`, not the deployed `erp_vendors`
   / `accounts`. The deployed name lives in `table_name`. This is what makes rename detection a clean
   equality join.
3. **`pattern_flags`** is a JSON object of `true`-valued bare keys; **`catalog_entity_aliases`** is a
   JSON array of objects, **append** on each reuse/merge (never rewrite prior elements).
4. **`entity_type`**: carry forward a *classified* `data_objects.entity_type` verbatim; treat upstream
   `unclassified`/null as absent and derive locally. Never write `''` — write `'unclassified'`.
5. **Do not touch `ctype`.** It is core-managed and locked; you write the column *values* only.
6. **Codes are write-once by intent (D2)** — set at create, never rewritten on a later rename (a rename
   updates `table_name`/`field_name` only). Whether core *enforces* this is an open question (§6/§8).

PostgREST exposes the new columns automatically — no PostgREST config in this repo.

---

## 6. What core enforces vs what it does NOT

**Enforced (testable here):**
- `entity_type` ∈ the closed 6-value set (inline CHECK).
- `pattern_flags` is a JSON object; `catalog_entity_aliases` is a JSON array (inline CHECKs).
- NOT NULL + empty defaults on all 8.
- Core-column protection: each new field is `ctype='core'`, so it cannot be renamed/deleted and its
  `ctype` cannot be cleared by a tenant admin.
- **Write-once on the three scalar join-key codes (D2 — ruled "enforce in core", §8 Q2).**
  `catalog_entity_code`, `catalog_field_code`, `catalog_module_code` reject a value-changing UPDATE
  once non-empty, via a `validation_rules` entry on the owning entity (`entities`/`fields`/`modules`)
  — the proven `roles.origin` path, rejection = SQLSTATE `23514`. `'' → value` backfill and INSERT
  stay allowed. **This is the one canonical rule shape (verified against the JsonLogic engine — see
  §6a); do not use any other variant.** The rule reads "if the code changed, allow only when this is an
  INSERT (`$old` is null) **or** the old value was empty":
  ```json
  {"code":"catalog_entity_code_write_once","source_module":"platform",
   "message":"catalog_entity_code is write-once: it cannot be changed once set",
   "jsonlogic":{"if":[{"value_changed":"catalog_entity_code"},
                      {"or":[{"==":[{"var":"$old"},null]},{"==":[{"var":"$old.catalog_entity_code"},""]}]},
                      true]}}
  ```
  Because the rule body fires only when `value_changed(code)` is true, every DD-internal metadata write
  (searchable/is_child recompute, rename's `UPDATE … SET table_name/field_name`, format change) passes
  untouched — verified: none of those paths writes a `catalog_*` column. (Add a one-line code comment to
  that effect on each rule so nobody "fixes" it later.)
- **`catalog_entity_aliases` append-only** (new ⊇ old), via a small `BEFORE UPDATE` trigger on
  `entities` using jsonb superset (`NEW.catalog_entity_aliases @> OLD.catalog_entity_aliases`). Spec
  (matches house style — cf. the generated validators): `SECURITY DEFINER`, `SET search_path = public`,
  `BEFORE UPDATE ON entities FOR EACH ROW WHEN (OLD.catalog_entity_aliases IS DISTINCT FROM
  NEW.catalog_entity_aliases)`, and `RAISE EXCEPTION … USING ERRCODE = '23514'` so it shares the codes'
  rejection class. The one piece of net-new trigger code; cheap and exact. Semantics to know (and test):
  `@>` is order-insensitive (reorder passes — fine for an append ledger) and blocks removal/mutation of
  any existing element; it intentionally **over-blocks an admin correcting a bad alias** (a fix would
  need a BYPASSRLS path — acceptable for now). If preferred as a skills convention instead, drop the
  trigger — the codes remain core-enforced regardless.

**NOT enforced by core (intentional):**
- **`entity_type` derivation (D9 ladder).** Core only stores + range-checks (§8 Q3 confirmed).
- **`pattern_flags` key vocabulary.** Core accepts any object (§8 Q4 confirmed).
- **`catalog_role_code` mutability.** Left mutable — no consumer yet (D5), so no write-once rule. Add
  one if/when a persona-mapping consumer appears. `canonical_owner_module` is a soft pointer, also not
  write-once (a placeholder's owner may legitimately resolve/change).

---

## 6a. Implementation notes (security/test review incorporated, 2026-06-12)

- **`entity_type` CHECK is the inline 6-value one, and it is authoritative.** Declare
  `entity_type TEXT NOT NULL DEFAULT 'unclassified'` + `CONSTRAINT valid_entity_type CHECK (entity_type
  IN (…6…))` inline in `CREATE TABLE entities` (0060). The field-metadata seed runs in 0060 **before**
  the `add_dd_field` trigger is created (0070), so registering it with `format='enum'` +
  `input_type='readonly'` does **not** generate the DD's `effective_enum_values` CHECK (which would
  append a 7th `''` value). The inline 6-value CHECK wins; `readonly` is a pure UI hint. Tests assert
  the closed set by rejecting both a bogus value (`'platform'`) **and** `''`.
- **Append the write-once rule to `modules.validation_rules`; do not clobber.** `modules` already
  receives a `valid_module_slug` rule (appended in `0200_module_slug_validation.sql` via `||`). Put the
  `catalog_module_code_write_once` rule in the `0060` `modules` seed literal (currently `'[]'`); `0200`
  then `||`-appends the slug rule → final `[write_once, valid_module_slug]`. Assert the post-merge
  `jsonb_array_length` so a future clobber is caught (mirror `0340`). `entities`/`fields` seeds are
  currently `'[]'`, so their rule goes straight into the seed literal.
- **Tests assert SQLSTATE *and* message.** Validation rejection is `23514` only while the rule body
  uses total operators (`if/value_changed/or/==/var`); a future typo would surface as `P0001`. Assert
  both the code (`23514`) and the rule's message string (as `0320`/`0340` do) so that regression is
  caught.

## 7. Test coverage — including **renamed-entity discovery**

> **Direct answer to "do your tests cover discovery of renamed entities?"** — The first draft did
> **not**: it covered existence, defaults, shape/enum CHECKs, round-trips, non-uniqueness and
> core-protection, but **not** the rename-survival invariant that is the entire point of
> `catalog_entity_code` / `catalog_field_code`. That gap is now closed. Core can and does test the
> **data substrate** that makes rename discovery deterministic; the **ladder orchestration and
> human-review prompts run in the skills** and are tested in `semantius-agent`.

New/auditable coverage (`apps/test/tests/0360_test_catalog_provenance.sql`, plus rename asserts that
can also be co-located in `0290_test_ddl_rename.sql` where the rename machinery already runs):

**A. Substrate (per column):** existence (`has_column`), DD registration + `is_core` derives true,
format correct, empty defaults on a fresh **and** a pre-existing seeded entity, round-trips, the three
shape/enum CHECKs reject bad values (`23514`), the three lineage codes are non-unique, and core
protection (`P0001` on delete, `42501` on ctype clear).

**B. Rename discovery (the part that was missing):**
1. **Entity rename survival.** Create entity `table_name='suppliers'`, `catalog_entity_code='vendors'`;
   `UPDATE entities SET table_name='vendors_x'`; assert `catalog_entity_code` is **still** `'vendors'`.
   (Verified mechanism: entity rename is an `UPDATE` of the PK row — all other columns travel with it;
   `fields.table_name` cascades. See `0290_test_ddl_rename.sql`.)
2. **Field rename survival.** Field `field_name='status'`, `catalog_field_code='status'`; rename to
   `disposition`; assert `catalog_field_code` still `'status'`.
3. **Discovery join — ladder step 2 (owned canonical code).** After the rename, prove the live (renamed)
   table is resolvable by the join the `use-*` skill runs:
   `SELECT table_name FROM entities WHERE catalog_entity_code='vendors' AND module_id IN (…)` → returns
   `vendors_x`.
4. **Discovery — ladder step 3 (alias).** Seed `catalog_entity_aliases` with
   `[{"alias_code":"suppliers","source_domain":"erp",…}]`; prove
   `… WHERE catalog_entity_aliases @> '[{"alias_code":"suppliers","source_domain":"erp"}]'::jsonb`
   resolves the host entity (the merged-away identity that otherwise masquerades as absence).
5. **Ladder step 1 (FK reseat)** is already covered generically by `0290_test_ddl_rename.sql` Test 4b
   (a referencing field's `reference_table` auto-updates on rename); a provenance-flavoured assertion
   joining via `catalog_field_code` can be added for explicitness.

**C. Topologies & identity invariants (added per the plan author's Q6):**
6. **Multi-recurrence disambiguation (the most important guarantee).** 3 entities all
   `catalog_entity_code='vendors'` in 3 modules; the step-2 query scoped to one domain
   (`… AND module_id IN (SELECT id FROM modules WHERE catalog_module_code = ANY(:slice))`) returns
   **exactly** the in-domain row, not all three. Proves identity = `(code, module)`, never code alone.
7. **Same-name share owned elsewhere.** Entity owned by another module, consumed via FK, no alias, no
   own row in the asking domain; step-2 returns empty and step-1 (FK) resolves it.
8. **Merge FK-shadow vs rename-cascade.** A field `catalog_field_code='supplier_id'` whose
   `reference_table` is repointed to `vendors` (a *merge*, not a same-table rename); confirms step-1
   resolves a merge, not only a rename.
9. **Identity & enforcement invariants** (each an explicit assertion):
   - **Non-uniqueness** — two rows with the same code coexist, for `entities`, `modules`, **and**
     `roles` (the recurrence/clone topologies depend on it).
   - **Soft pointer** — `canonical_owner_module` accepts a genuinely non-existent slug
     (`'module-not-deployed-yet'`) via `lives_ok` (proves it is not an FK).
   - **Write-once (all three codes):** reject `value→other` (`23514` + message); **allow** `''→value`
     backfill; **allow** INSERT of a row with a non-empty code (the modeler's stamping path — this is
     the case the buggy rule shape would wrongly block, so it must be asserted); **allow** an
     unchanged-row UPDATE (`UPDATE … SET description=… WHERE <code>='vendors'`); **allow** DELETE of a
     code-bearing row (the rule must not block deletes / cascade deletes).
   - **Aliases append-only:** `lives_ok` adding an element (`[a] → [a,b]`); `throws_ok 23514` removing
     one (`[a,b] → [a]`); `lives_ok` reordering (`[a,b] → [b,a]`) so a stricter reimplementation can't
     silently tighten the contract.
   - **entity_type closed set:** reject `'platform'` **and** `''` (both `23514`); accept each of the 6.

**Boundary:** core proves *the columns make rename resolution a deterministic read*. It does **not**
test the full §4.1 ladder (first-hit-wins ordering, the absence/omission branch, the user-prompt on
genuine ambiguity) — that is skill logic and belongs in the `semantius-agent` test suite.

---

## 8. Decisions — RESOLVED by the plan author (2026-06-12)

All six closed; folded into this build.

1. **Discovery query shapes (locked — core tests mirror these verbatim):**
   - Step 2: `module_id IN (SELECT id FROM modules WHERE catalog_module_code = ANY(:domain_slice_codes))`,
     where `:domain_slice_codes` = the `catalog_module_code`s the consuming domain's uber-model owns.
   - Step 3: `catalog_entity_aliases @> '[{"alias_code":"X","source_domain":"D"}]'::jsonb` — the
     `(alias_code, source_domain)` pair, never `alias_code` alone.
2. **Write-once: ENFORCE in core.** The three scalar join-key codes (`catalog_entity_code`,
   `catalog_field_code`, `catalog_module_code`) are write-once via `validation_rules` (§6). Aliases are
   append-only. `catalog_role_code` stays mutable (no consumer). Rationale (plan author): the codes are
   the rename/merge join keys — a silent rewrite corrupts discovery + the analyst with no visible error,
   exactly what a DB invariant should prevent.
3. **`entity_type`: no core derivation** — store + 6-value CHECK only. ✓
4. **`pattern_flags`: key-agnostic at the DB.** ✓
5. **`lifecycle_states`: DEFERRED** (§3.5) — extends `process_gates` when RACI-in-platform lands.
6. **Three extra discovery topologies + identity invariants added to the test set** (§7.C).

## 9. Build / packaging note

These edits land in the **base migrations** (`0020`, `0060`), not an add-on. The repo also ships a
bundled extension (`extension/pg_semantic_platform--0.1.1.sql`); **re-bundle to
`--0.1.2.sql`** (via `deno task bundle-sql` / the packaging step) so the extension install path carries
the columns too. Regenerate `schema.md` (`deno task docgen`).
