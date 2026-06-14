# Provenance in core — implementation reference (v0.1.2)

> **Authoritative contract:** [`docs/provenance-core-0.1.2-changes.md`](../docs/provenance-core-0.1.2-changes.md)
> — the as-built column set, enforcement rules, resolved decisions (§8), and the full test matrix (§7).
> **This file is the implementation reference only** (how the source plan maps to core, the build
> steps, the execution sequence). Where the two ever differ, the changes-doc wins.

**Source plan:** `C:\dev\semantius-agent\provenance-in-platform-plan.md` (D1–D9 settled; Q1–Q6 + the
three discovery topologies resolved with the plan author on 2026-06-12).

**Scope.** Only what `semantius-core` owns: the columns, their DD registration, constraints,
write-once / append-only enforcement, and tests. *Stamping* (the modeler/skill writing the codes) lives
in `semantius-agent` / the Deno MCP server and is out of scope here.

**Approach — pre-release, so fold into the BASE migrations (no add-on migration).** Columns are
declared **inline** in the `CREATE TABLE`s and registered (`ctype='core'`) in the existing DD seed
blocks. `lifecycle_states` is **DEFERRED** — per D3 it will extend `process_gates` when the
RACI-in-platform work lands; it does **not** ship as a standalone table in v0.1.2. The §3 columns ship
without it.

---

## 1. Translating the source plan to core reality

The source plan is written at the platform-abstraction level. Five corrections drive the build:

| Source plan says | Core reality | Consequence |
|---|---|---|
| `"is_core": true` | The `is_core` boolean was **dropped**; core status is the field's `ctype` (`'', id, label, audit, core`), and `is_core` is *derived* as `(ctype <> '')` in `get_schema()`. | Register every provenance field with **`ctype = 'core'`**. `ctype` is privilege-locked (`fields_ctype_lock`, `0070_dd_functions.sql:387`) — only a BYPASSRLS caller (migrations) may set it. The modeler writes column *values*, never `ctype`. |
| "nullable, default empty" | **No-NULL policy** (`AGENTS.md`); `is_nullable(format)` is TRUE only for `reference`/`date`/`date-time` (`0070:94`). `string`/`text`/`json`/`enum` are **NOT NULL**. | "Absent" = `DEFAULT ''` / `'{}'` / `'[]'` / `'unclassified'` — never SQL NULL. Discovery tests `= ''` / `= '{}'::jsonb` / `= '[]'::jsonb`, never `IS NULL`. |
| table `entities` | Physical table is `entities` (PK `table_name`); `tables` is a `SELECT *` compat view (`0130`) that auto-inherits new columns. | Add columns to `entities`; the `tables` view and `get_schema()`'s `table` object pick them up for free. |
| MCP `create_field` adds the column | Under the **fold-in** approach the physical columns are declared **inline in `CREATE TABLE`**; the DD field-metadata seed (in `0060`, *before* the `add_dd_field` trigger exists in `0070`) is **pure registration**. | No `add_dd_field` interplay, and **no `add_dd_field` JSONB-`'{}'` default trap** — declaring inline lets us set the exact default per column. |
| `pattern_flags` / `catalog_entity_aliases` are JSON | The DD never emits a `jsonb_typeof` shape CHECK. | Declare each JSONB column inline with its exact default **and** a shape CHECK: `pattern_flags JSONB NOT NULL DEFAULT '{}'` + `CHECK (jsonb_typeof(pattern_flags)='object')`; `catalog_entity_aliases JSONB NOT NULL DEFAULT '[]'` + `CHECK (… = 'array')`. |

**Precedents to mirror:** `users.is_agent` (`0210_raci.sql:19-39`, a column added to a core table),
`process_gates` (`0210:150-189`, governance-family DDL), and the `roles` `origin_immutable`
`validation_rules` (`0060_dd_schema.sql:315`, the write-once enforcement path — proven by
`0340_test_m3.sql:358-364`, which rejects an `origin` change with SQLSTATE `23514`).

---

## 2. Build steps (all in the base migrations)

**`0020_rbac_schema.sql`** — in the existing `CREATE TABLE`s:
- `modules`: `catalog_module_code TEXT NOT NULL DEFAULT ''` (non-unique — no UNIQUE).
- `roles`: `catalog_role_code TEXT NOT NULL DEFAULT ''` (non-unique).

**`0060_dd_schema.sql`** — three things:
1. `CREATE TABLE entities`: add the 5 columns inline with their defaults + 3 inline CHECKs —
   `catalog_entity_code`/`canonical_owner_module` (TEXT `''`), `entity_type` (TEXT `'unclassified'` +
   `CONSTRAINT valid_entity_type CHECK (entity_type IN (…6…))`), `pattern_flags` (JSONB `'{}'` +
   object CHECK), `catalog_entity_aliases` (JSONB `'[]'` + array CHECK). `CREATE TABLE fields`: add
   `catalog_field_code TEXT NOT NULL DEFAULT ''`.
2. Add the **8 field-metadata seed rows** (`ctype='core'`, `searchable=FALSE`, `unique_value=FALSE`)
   to the entities/fields/modules/roles seed blocks. `entity_type` row: `format='enum'`,
   `input_type='readonly'` (UI hint only — does **not** create a second CHECK, since the seed runs
   before the `0070` `add_dd_field` trigger), `enum_values` = the 6 values, `default_value='unclassified'`.
3. **Enforcement:**
   - Add the write-once `validation_rules` to the `entities`/`fields`/`modules` seed rows (canonical
     rule shape in the changes-doc §6). **Append** for `modules` — `0200_module_slug_validation.sql`
     already `||`-appends `valid_module_slug`, so put the write-once rule in the `0060` `modules` seed
     literal and let `0200` append slug → final `[write_once, valid_module_slug]`.
   - Add a small `BEFORE UPDATE ON entities` trigger (`SECURITY DEFINER`, `SET search_path = public`,
     `WHEN (OLD.catalog_entity_aliases IS DISTINCT FROM NEW.catalog_entity_aliases)`, raise with
     `ERRCODE '23514'`) enforcing `NEW.catalog_entity_aliases @> OLD.catalog_entity_aliases` (append-only).

**Not in v0.1.2:** `lifecycle_states` (deferred → `process_gates`); `modules.settings.*` keys
(`catalog_snapshot`/`naming_mode`/`module_kind`/`promotion_decisions`) need **no DDL** (freeform JSONB).

**Packaging:** re-bundle the extension `pg_semantic_platform--0.1.1.sql` → `--0.1.2.sql`
(`deno task bundle-sql` / the packaging step); regenerate `schema.md` (`deno task docgen`).

---

## 3. Enforcement detail (write-once + append-only — DECIDED: enforce in core, D2/§8 Q2)

The three scalar join-key codes (`catalog_entity_code`, `catalog_field_code`, `catalog_module_code`)
are write-once; `catalog_role_code` stays **mutable** (no consumer, D5); `canonical_owner_module` is a
soft pointer (not write-once — a placeholder's owner may legitimately resolve). **Use exactly this rule
shape** (verified against the JsonLogic engine):

```json
{"code":"catalog_entity_code_write_once","source_module":"platform",
 "message":"catalog_entity_code is write-once: it cannot be changed once set",
 "jsonlogic":{"if":[{"value_changed":"catalog_entity_code"},
                    {"or":[{"==":[{"var":"$old"},null]},{"==":[{"var":"$old.catalog_entity_code"},""]}]},
                    true]}}
```

It allows INSERT and `'' → value` backfill, and blocks only `value → other`.

⚠️ **Do NOT use the `{"and":[value_changed, {"!=":[$old.code,""]}]} → false` variant** — on INSERT
`$old` is null, so it returns `false` and **blocks the modeler's INSERT of a freshly-stamped code** (its
primary path). The body fires only when `value_changed(code)` is true, so every DD-internal metadata
write (searchable/is_child recompute, rename's `UPDATE … SET table_name/field_name`, format change)
passes untouched — none writes a `catalog_*` column. Add a one-line comment to each rule saying so.

---

## 4. Test checklist

The authoritative, full matrix is the **changes-doc §7** (A substrate · B rename discovery · C
topologies & invariants). New file `apps/test/tests/0360_test_catalog_provenance.sql`, `0350_test_raci`
idiom (`BEGIN … plan(N) … authenticate_as('user3') … ROLLBACK`, `prov_`-prefixed probes). Cover, at
minimum:

- **Per column (×8):** `has_column`; DD metadata registered; `is_core` derives `true` via `get_schema`;
  `format` correct; empty default on a fresh **and** a pre-existing seeded entity (e.g. `departments`
  reads `catalog_entity_aliases='[]'`, not `'{}'`); round-trip.
- **Shape/enum CHECKs:** `pattern_flags` rejects non-object; `catalog_entity_aliases` rejects non-array;
  `entity_type` rejects `'platform'` **and** `''` (assert `23514` + message); accepts each of the 6.
- **Rename survival:** entity `table_name` rename keeps `catalog_entity_code`; field `field_name` rename
  keeps `catalog_field_code`.
- **Discovery joins (Q1 shapes verbatim):** step-2 `… AND module_id IN (SELECT id FROM modules WHERE
  catalog_module_code = ANY(:slice))`; step-3 `catalog_entity_aliases @> '[{"alias_code":…,"source_domain":…}]'::jsonb`.
- **Three topologies:** multi-recurrence disambiguation (3 modules share `vendors`; scoped step-2
  returns exactly the in-domain row); same-name FK share (no own row → step-1 resolves); merge
  FK-shadow vs rename-cascade.
- **Invariants:** non-uniqueness on entity/module/role codes; soft pointer (non-existent slug
  `lives_ok`); write-once (reject `value→other`; allow INSERT-with-code, `''→value`, unchanged-row
  UPDATE, DELETE) with `23514`+message; aliases append-only (allow add, reject remove, allow reorder).
- **Fixture notes:** give each fixture module a distinct `module_slug`; resolve `module_id` by
  slug/name, never a hard-coded id.

---

## 5. Execution sequence (per `AGENTS.md`; psql unavailable — Deno CLI only)

1. Edit `0020`, `0060` per §2; write `0360_test_catalog_provenance.sql` (§4); set `plan(N)` to the real count.
2. `deno task connect` — verify DB; **stop** if it fails.
3. `deno task dropall --confirm`
4. `deno task migrate --apps _core,test,nwind --verbose` (order: `test` before `nwind`).
5. `deno task test` — all green, including `0360`. Show full output.
6. Re-bundle the extension → `--0.1.2.sql`; `deno task docgen` (regenerate `schema.md`); review the diff.

**Definition of done:** every §2 column + CHECK, the write-once/append-only enforcement, the rename-
survival + discovery-join + three-topology tests, and the identity invariants each have ≥1 passing
assertion; the full prior suite still passes; the extension is re-bundled to 0.1.2 and `schema.md` regenerated.
