# Provenance — core → platform-plan handoff (copy/paste to upstream)

**To:** author of `provenance-in-platform-plan.md` (architect / analyst / modeler / `use-*` skills)
**From:** semantius
**Re:** the plan is implemented in core — corrections, the as-built contract, rename-discovery test
coverage, and the decisions I need from you.
**Status:** core is **pre-release**, so this ships folded into the base schema as part of **v0.1.2**
(no upgrade migration). A fresh build produces the columns.

---

## 1. What I built

All of §3 of your plan, in core: 5 columns on `entities`, 1 on `fields`, 1 on `modules`, 1 on `roles`,
plus (pending your D3 call) a `lifecycle_states` registry table. They default empty, so an un-updated
modeler keeps working and existing rows read as "absent" — additive-safe, exactly as you intended.

## 2. Two places your plan's abstraction ≠ core reality (please align skill code to these)

1. **`"is_core": true` is not a thing.** Core dropped the `is_core` boolean; core-ness is now the
   field's **`ctype`** marker, and these columns are registered with **`ctype = 'core'`**. `is_core` is
   *derived* as `(ctype <> '')` and still appears in `get_schema()` output, so any skill reading
   `is_core` from the schema still works — but the **modeler must never write `ctype`** (it is
   privilege-locked); it writes the column *values* only.
2. **"nullable, default empty" → NOT NULL with an empty default.** Core has a no-NULL policy; `string`/
   `json`/`enum` are NOT NULL. "Absent" is `''` (text), `'{}'` (json object), `'[]'` (json array),
   `'unclassified'` (enum) — **never SQL NULL**. Discovery's "is this empty?" must test `= ''` /
   `= '{}'::jsonb` / `= '[]'::jsonb`, **not** `IS NULL`.

## 3. The as-built contract

| Table.column | Type / default | Skill-facing meaning |
|---|---|---|
| `entities.catalog_entity_code` | TEXT `''`, **non-unique** | **Canonical** uber-model code (D6), e.g. `vendors` — the rename/dialect/silo join key. `table_name` holds the deployed name and may drift; this does not. Empty = outside the pipeline (true custom). |
| `entities.canonical_owner_module` | TEXT `''` | Slug of the owning module for an `embedded_master` placeholder. Soft pointer, **not** an FK. Empty when this module is the owner or the entity is local. |
| `entities.entity_type` | TEXT `'unclassified'`, CHECK ∈ 6 | Closed set: `operational_workflow, operational_record, catalog, junction, computed, unclassified`. `write tier` derives **from** it. `unclassified` = absent/derive-locally. |
| `entities.pattern_flags` | JSONB `'{}'`, CHECK object | Sparse `{flag:true}` of bare authored names. Confirmed keys: `personal_content, submit_lock, single_approver`. Core does **not** constrain the key set. |
| `entities.catalog_entity_aliases` | JSONB `'[]'`, CHECK array | Array of `{alias_code, source_domain, source_module, decided}`. **Append-only.** Empty = never a merge target. Resolve on the `(alias_code, source_domain)` pair. |
| `fields.catalog_field_code` | TEXT `''` | Canonical/blueprint field name (e.g. `status`) — the field-rename join key. |
| `modules.catalog_module_code` | TEXT `''`, **non-unique** | Catalog blueprint the module came from; also the **domain axis** discovery groups by. |
| `roles.catalog_role_code` | TEXT `''`, **non-unique** | Catalog persona (D5 insurance — no core consumer yet). |
| `modules.settings.*` | (existing JSONB) | `catalog_snapshot / naming_mode / module_kind / promotion_decisions` are plain keys; **no DDL**, no core constraint. |

**Modeler stamping rules that matter:** stamp `catalog_entity_code` with the **canonical** code (not the
deployed name); **append** to `catalog_entity_aliases` (never rewrite prior elements); write
`'unclassified'` (never `''`) for an absent `entity_type`; codes are write-once at create (a rename
touches `table_name`/`field_name` only).

## 4. What core validates vs leaves to you

- **Core enforces:** the 6-value `entity_type` CHECK; `pattern_flags` is-object / `catalog_entity_aliases`
  is-array CHECKs; NOT NULL + empty defaults; core-column protection (un-deletable, `ctype` un-clearable).
- **Core does NOT enforce (yours unless we decide otherwise):** `entity_type` *derivation* (the D9
  ladder is architect/analyst); the `pattern_flags` key vocabulary; alias append-only-ness; and
  **write-once on the codes (D2)** — see Q2.

## 5. Renamed-entity discovery — coverage + the boundary

My first test pass **did not** cover rename discovery (only existence/defaults/CHECKs/round-trips). Fixed.
Core now tests the **data substrate** that makes your §4.1 ladder deterministic:

- **Entity rename survival** — rename `table_name` `suppliers→vendors_x`; `catalog_entity_code` stays
  `vendors`. (Mechanism confirmed: entity rename is an `UPDATE` of the PK row; all other columns travel
  with it.)
- **Field rename survival** — rename `field_name` `status→disposition`; `catalog_field_code` stays `status`.
- **Ladder step 2 join** — `WHERE catalog_entity_code='vendors' AND module_id IN (…)` resolves the
  renamed live table.
- **Ladder step 3 alias** — `WHERE catalog_entity_aliases @> '[{"alias_code":"suppliers","source_domain":"erp"}]'`
  resolves the merged-away identity that otherwise reads as absence.
- **Ladder step 1 (FK reseat)** is already covered by core's existing DDL-rename tests (a referencing
  field's `reference_table` auto-updates on rename).

**Boundary — your side:** core proves the columns make resolution a deterministic *read*. The full
ladder behavior — first-hit-wins ordering, the absence/omission branch, and the human-review prompt on
genuine ambiguity — is skill logic and must be tested in the skills suite, not core.

## 6. Decisions / inputs I need from you

**Blockers (finalize core's test file):**
1. **Exact discovery query shapes**, so core's substrate tests mirror what the skills actually run:
   (a) step-2 module scoping — is it `module_id IN (SELECT id FROM modules WHERE catalog_module_code = ANY(<domain slices>))`?
   (b) step-3 alias match — is JSONB containment `@>` on `{alias_code, source_domain}` the agreed predicate?
2. **Write-once (D2): enforce in core, or leave a modeler convention?** Core can make it a tested
   guarantee (immutability rule: reject a change once the code is non-empty), but the `fields`-level rule
   fires on every field write. Enforce → core owns the immutability test; convention → that test lives in
   your skills suite.

**Confirmations:**
3. Core has **no `entity_type` derivation duty** — store + range-check only; the D9 carry-forward/derive
   ladder is architect/analyst. (Assumed — confirm.)
4. `pattern_flags` stays **key-agnostic at the DB**; the confirmed-key vocabulary is enforced only in skills.
5. **`lifecycle_states` (D3): ship in v0.1.2 or defer?** Independent of the §3 columns — say the word.
6. Is there any topology in your §4.1 worked examples that the substrate tests in §5 would **not**
   exercise?
