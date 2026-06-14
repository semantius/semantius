# Composed Record Labels (`label_parent` + `_label`)

> Status: **IMPLEMENTED** (see §18 As-built). Full suite green (`deno task retest`): 1534 passing.

## 1. Problem

A record's label should answer *"which record is this?"* to a human. Root / spine entities with an
intrinsic name (`candidates.full_name`, `job_postings.title`) already do. Relational entities —
whose own columns are statuses, ratings, dates, and FKs — do not. Live example: an interview
scorecard labels itself `"Scorecard 6"`; opening it you cannot tell which candidate it concerns.

**Every record should expose a fully-qualified, human-readable label composed from its parent
chain, always current, respecting each caller's read permissions.**

## 2. Mechanism (decided)

Labels are **derived at read time, not stored**, and surfaced as **PostgREST computed columns** —
a function whose single argument is a table's row type is exposed as a selectable column of that
table (`select=id,_label`). No view layer, no stored column, no change-propagation.

The functions are **`SECURITY INVOKER`**, so every parent read performed inside them is gated by
that parent's own RLS policy. A parent the caller cannot read simply yields no row and the label
degrades — it can never leak (labels are viewer-relative).

The functions are **generated** per entity from the same metadata `get_schema` reads, kept in sync
by lightweight `AFTER` triggers, and built with `check_function_bodies = off` so generation is
order-independent and tolerant of mutual references.

Three decisions resolved during review (the substance of this revision):

1. **Degrade-correct fold (§6).** Each arm is a scalar subquery (NULL when the FK is
   null/deleted/hidden) and the local term is `NULLIF(local,'')`; the fold is
   `NULLIF(concat_ws(sep, …), '')`. `concat_ws` skips NULL arms, so a missing parent or empty local
   never produces a dangling separator and always degrades to the visible boundary.
2. **Block self-reference instead of bounding recursion (§11).** Self-referential `label_parent` is
   rejected and the identity graph is kept acyclic, so the generated functions terminate with **no
   runtime depth guard**. Trade-off: self-hierarchies (`categories.parent_id`) do not compose their
   ancestry in v1 — they fall back to the local label.
3. **`get_schema` discovery is synthesised from metadata (§5.4).** The derived columns are emitted
   as **ordinary `properties` entries discriminated by `ctype`** (each `<fk>_label` right after its
   FK), built from the **same shared predicate** (`dd_is_fk_format`) the generator uses, so the
   advertised set can never drift from the built set. They are deliberately **absent from the fields
   catalog / `read_field`** (not authored fields) — there is no separate side list.

## 3. Concepts

Two orthogonal axes:

| Axis | Question | Carried by |
|---|---|---|
| Lifecycle / ownership | "If the target is deleted, what happens to me?" | `format` (`parent` vs `reference`) — unchanged |
| Identity / labeling | "Which parent do I inherit my composed label from?" | **`label_parent`** (new) |

The spine is often a `reference`, not a `parent`, so identity is a marker independent of delete
behaviour. Intrinsic identity → own field names it → `label_parent` empty. Relational identity →
only meaningful under a parent → `label_parent` names the spine FK.

## 4. What is added

1. **`entities.label_parent`** *(optional, default `''`)* — names one reference/parent FK on the
   entity = the identity spine. Empty for intrinsic / self-identifying records.
2. **`_label`** — a derived, read-time, selectable computed column on every entity (§6).
3. **`<fk>_label`** — a derived, read-time, selectable computed column for every reference/parent
   field, returning the referenced record's composed label.

## 5. The label columns

### 5.1 `label_parent`

- Names a field on the entity; mirrors `label_column`. Validated by `validate_label_parent` (§10).
- MUST be a reference/parent FK, MUST NOT target a junction, MUST NOT be self-referential, and the
  cross-entity spine graph MUST stay acyclic.
- Changing it changes the composed label with no data migration (nothing is stored).

### 5.2 `_label` / `<fk>_label`

- `_label` exists on every entity; `<fk>_label` (FK field name + `_label`) on every reference/parent
  field. Both read-only (computed columns cannot be written) and opt-in (not in `select=*`).
- They are **not authored/editable** fields — absent from the `fields` catalog (`read_field` never
  returns them). But for clients they are **ordinary `get_schema` properties**, discriminated by
  `ctype` (§5.4) — not a separate side list.

### 5.3 Separator

Global ` › ` in v1. Per-entity override deferred. Collisions are not escaped.

### 5.4 Discovery (`get_schema`)

The derived columns appear **inline in `properties`** like any other property, discriminated only by
`ctype` (`_label` / `fk_label`), and **ordered so each `<fk>_label` sits immediately after its FK**
(and `_label` after the local label column). There is **no separate `label_columns` key** — a
consumer iterates `properties` once and keys off `ctype`. Each derived property carries the normal
property shape (`type:string`, `format:text`, `title`, `inputMode:readonly`, `width`, `field_order`,
`is_core:false`, `searchable:false`) plus:

| Attribute | `_label` | `<fk>_label` |
|---|---|---|
| `ctype` | `_label` | `fk_label` |
| `writable` | `false` | `false` |
| `selectable` | `true` | `true` |
| `source` | the spine FK (`label_parent`) or `null` | `{field, reference_table}` |
| `reference_table` | — | the referenced entity |

The synthesis uses the same shared `dd_is_fk_format` predicate as the generator (advertised set ==
generated set) and is collision-aware (a companion shadowed by a real column is not emitted).

The existing auto `label` field (the local label, `ctype: label`) is unchanged and distinct from
`_label`.

## 6. Composition (behaviour, as generated)

Let `loc = NULLIF(local_label, '')`. Each generated body:

```
root        r._label      =  loc
relational  r._label      =  NULLIF(concat_ws(' › ', (SELECT p._label FROM spine p WHERE p.id = r.<fk>), loc), '')
junction    r._label      =  NULLIF(concat_ws(' › ', legA, legB, …), '')   -- legK = (SELECT p._label FROM <ref> p WHERE p.id = r.<legK>), no local term
companion   r.<fk>_label  =  (SELECT p._label FROM <ref> p WHERE p.id = r.<fk>)
```

- **Fallback:** a null/deleted/hidden parent → the subquery is NULL → `concat_ws` drops it → no
  dangling separator, degrade to the visible boundary. Empty local with a spine → parent chain only.
- **Currency:** an ancestor label change is reflected on the next descendant read, no write.
- **Defensive generation:** bodies only reference columns/tables that physically exist, so the
  generator produces valid SQL for any entity shape (core meta-tables, composite-PK junctions,
  dangling references).

### Junctions

`entity_type = 'junction'` is authoritative; until stamped, a fallback heuristic recognises a pure
pairing table (≥2 parent legs; every non-leg field is an id/label/recognised-audit column). A
junction's `_label` combines its parent legs in field order, no local term. A hidden leg drops out
(no leak). Self-referential legs are skipped (bounded).

## 7. Security (requirement — met)

Composed labels respect row-level read permissions because the generated functions are
`SECURITY INVOKER`: each parent read runs as the caller and is gated by the parent's RLS policy. A
parent hidden/deleted/null degrades to the local label — no error, no leak. Labels are
viewer-relative; consumers must not assume a single canonical string. *(Note: in this codebase the
generated SELECT policy is entity-level `has_permission(view_permission)`; the mechanism is
correct for any row-level policy too.)*

## 8. Performance & search

Reading a composed label costs work proportional to chain depth × result size — acceptable for
paginated display. Filtering/sorting by `_label` works but is not indexed; large-set label search
is out of scope in v1 (search the local label).

## 9. Reserved field-name namespace (requirement — met, narrowed)

Only the **`_` prefix** is reserved for request-role creation/rename (`reserve_field_namespace`) —
it protects the entity-level `_label` and the `_*` system namespace. The **`_label` suffix is NOT
reserved**: denormalised display columns ending in `_label` (e.g. `customer_label`) are common and
allowed, as is even a deliberate `<fk>_label`. Privileged DD/migration code (BYPASSRLS) is exempt.

Companion collisions are handled by **precedence, not prohibition**: a real column always wins over
a generated `<fk>_label`, and both the generator and `get_schema` are **collision-aware** — they
skip a companion whose name is already an authored column, so nothing is ever silently shadowed and
discovery stays truthful. (A blanket `*_label` ban was rejected as too broad; an `*_id_label`
heuristic was rejected because it misses non-`_id` FKs like `assigned_by` → `assigned_by_label`.)

## 10. Validation (requirements — met)

`label_parent`, when set: MUST name an existing reference/parent FK; MUST NOT target a junction;
MUST NOT be set on a junction; MUST NOT be self-referential; and the spine graph MUST be acyclic.

## 11. Termination (requirement — met by validation, not runtime guard)

Self-referential spines are rejected and the identity spine graph is acyclic, so every generated
function terminates without a runtime depth bound. Self-hierarchy composition is descoped in v1
(falls back to local label).

## 12. Consumption

Record header/detail title and global search/reference pickers read `_label` (fixes the original
gap). Scoped grids may keep the local `label` or adopt `_label`/`<fk>_label`. When two results share
a `_label` the UI disambiguates — `_label` is not a key. Cube/analytics: out of scope in v1.

## 13. Provisioning & migration

Every entity gets `_label`; every reference/parent field gets `<fk>_label`. They track schema
changes via the lifecycle wiring (§18). Provisioning is order-independent. No data backfill
(nothing stored); a one-time function backfill builds them for entities that predate the triggers.

## 14. Phasing (as-built)

Shipped as one coherent change: `label_parent` + reservations + validations + `<fk>_label`/`_label`
generation + junction handling + get_schema discovery, then tests. (The original 4-phase split had a
dependency inversion — `<fk>_label` is defined in terms of `_label` — so the two land together.)

## 15–17

Open questions resolved as in §2. Original test matrix (A–K) is exercised by the as-built test
suite (§18); the security cases (C2, J3) and the depth-3 chain (A4) are the load-bearing ones.

## 18. As-built (files)

- **`apps/_core/migrations/0060_dd_schema.sql`** — `entities.label_parent` column, `valid_label_parent`
  CHECK, and `entities.label_parent` field metadata.
- **`apps/_core/migrations/0145_managed_enable.sql`** — appended section:
  - shared predicate `dd_is_fk_format`; junction detection `dd_is_junction`; `dd_spine_parent`;
  - generator `rebuild_entity_label_functions` (degrade-correct fold; collision-aware companion
    skip; REVOKE PUBLIC / GRANT semantius_user on each generated function);
  - `reserve_field_namespace` (§9, `_`-prefix only) + trigger;
  - `validate_label_parent` (§10, acyclic + no self-ref) + trigger;
  - lifecycle wiring (`zzz_`-named AFTER triggers on entities/fields) + a backfill `DO` block.
- **`apps/_core/migrations/0080_public_functions.sql`** — `build_schema_for_table` emits the derived
  `_label` / `<fk>_label` columns **inline in `properties`** (ctype `_label`/`fk_label`, each
  companion ordered right after its FK), collision-aware (a companion shadowed by a real column is
  not emitted). No separate `label_columns` key.
- **`apps/test/tests/0370_test_composed_labels.sql`** — 28 assertions: composition (A1/A2/A4),
  companion (B1/B3), fallback (A5/A7), currency (D1/D2/D3), junction (J1/J3), security/no-leak
  (C2), discovery (H1/H4/H5/H9), reservation (F1/F2/F3), validation (F6/F7/F8/F10/F11).
- **Adjusted to satisfy the change:** `0060_test_security.sql` (added
  `rebuild_entity_label_functions` to the documented "helper called by triggers during migrations"
  allowlist for the SECURITY-DEFINER-must-call-`rbac.uid()` policy). *(No change to
  `0320_test_computed_validation.sql`: its `old_label` fixture is fine once the `_label` suffix is
  no longer reserved.)*

## 19. Acceptance checklist

- [x] `_`-prefixed field names rejected; `*_label` suffix allowed; `<fk>_label` companions are
      collision-aware (an authored column wins and is not shadowed).
- [x] Every entity exposes `_label`; every reference/parent field exposes `<fk>_label`; read-only, opt-in.
- [x] `label_parent` empty → `_label` = local; empty local + spine → parent chain only (never empty-due-to-null).
- [x] `label_parent` → a junction, on a junction, self-referential, or cyclic are rejected.
- [x] A caller who cannot read a parent never sees its label via `_label`/`<fk>_label` (C2, J3).
- [x] Renaming an ancestor updates descendants with no writes (D1).
- [x] Self-referential spines blocked; composition always terminates (no runtime guard).
- [x] Label columns absent from `select=*` and the fields catalog/`read_field`; present in
      get_schema `properties` discriminated by `ctype` `_label`/`fk_label` (each `<fk>_label` right
      after its FK).
- [x] Junctions (incl. `user_roles`) combine their legs; raw `id` not shown.
- [x] Composed labels not surfaced in the cube (v1).
- [x] Full suite green: `deno task retest` → 1534 passing.
