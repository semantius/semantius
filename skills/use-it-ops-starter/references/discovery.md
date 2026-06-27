# Discovery procedure

Reconciles the DomainMap-emitted `spec.json` (the DomainMap model this domain assumes) against what is
actually deployed in this deployment. Discovery is **read-only** against the platform; it never
inserts, updates, or deletes. Its outputs are `discovered.json` (full snapshot + per-concept
resolution) and `state.jsonc` (lean deltas).

As of core v0.1.2 the live platform carries **provenance columns**, so discovery is a set of
deterministic reads, not name guessing. `scripts/phase2a-structural.ts` runs the resolution ladder
below for every concept and resolves a fully-stamped deployment with **zero** user prompts. This doc
is (a) the contract phase2a implements and (b) the **Phase 2b** procedure the agent runs for the
genuine ambiguities phase2a could not resolve.

## Empties are never NULL (core v0.1.2)

Every provenance column is NOT NULL with an empty default. Test emptiness against the empty value,
never `IS NULL`:

| Column | Empty value | Empty means |
|---|---|---|
| `catalog_entity_code`, `catalog_field_code`, `catalog_module_code`, `catalog_role_code` | `''` | created outside the deploy pipeline (hand-built / pre-provenance) |
| `catalog_owner_module` | `''` | this module owns it, or the entity is local |
| `catalog_entity_aliases` | `'[]'` | never a merge target |
| `entity_type` | `'unclassified'` | unclassified upstream; derive locally |

---

## Pass 1: domain membership (deploy stamp + entity-first)

Domain membership is the **union of two deterministic signals**, never module code alone:

1. **Deploy stamp (`settings.domain_code`)**, the deploy pipeline writes
   `{ domain_code, module_kind, naming_mode, catalog_snapshot }` into each provisioned module's
   `settings` JSONB. Querying `settings->>domain_code = IT-OPS-STARTER` resolves the slice directly and is
   the authoritative marker. It holds even when a deployment's entities were created WITHOUT
   `catalog_entity_code` stamps (hand-built tables), which the entity probe alone would miss.
2. **Entity-first**, the live `module_id`s that host the domain's OWNED entities, resolved from
   the canonical master codes (`spec.data_objects[].name`). This catches a deployment that packages
   the domain under any module name (a "hiring-starter" bundle hosts the ATS entities under
   `catalog_module_code = hiring-starter`) and a module whose `settings` were never stamped.

`catalog_module_code` / `module_slug` are weak hints folded into the same union.

```bash
# (a) AUTHORITATIVE: the deploy stamp.
semantius call crud postgrestRequest '{"method":"GET","path":"/modules?settings->>domain_code=eq.IT-OPS-STARTER&select=id,module_slug,module_name,catalog_module_code,settings"}'
# (b) entity-first (owned master codes -> the modules that host them).
semantius call crud postgrestRequest '{"method":"GET","path":"/entities?catalog_entity_code=in.(<spec.data_objects[].name>)&select=module_id,catalog_entity_code"}'
# HINT: module codes + slugs.
semantius call crud postgrestRequest '{"method":"GET","path":"/modules?catalog_module_code=in.(<spec.modules[].code>)&select=id,module_slug,catalog_module_code"}'
```

`phase1-environment.ts` does this and emits the de-duplicated union of `module_id`s as the
**domain slice** (`domain_slice`, each entry tagged with `matched_by` and its `settings`), which
scopes ladder step 2. Keying the entity query on OWNED masters (not embedded masters / consumers)
keeps a foreign module that merely hosts a shared master out of the slice. An absent spec module is
a deployment choice (or a bundled package), not a failure.

---

## Pass 2: the resolution ladder (per DomainMap concept)

For each concept `X` the domain assumes (the union of every module's `masters`,
`embedded_masters`, and `consumers`; each name **is** its canonical code under D6), resolve `X`
against the live deployment in this order. **First hit wins.**

### Step 1, FK reachability (most robust)

Walk the FK fields on the domain's own entities. For each field with a non-empty `reference_table`,
resolve the target entity's `catalog_entity_code`. Whatever a domain FK points at, carrying
`catalog_entity_code = X`, **is** `X` for this domain. Reseating is universal (silo, same-name
share, and reuse/merge all repoint the FK), so this resolves every topology whenever `X` still has a
consumer in the domain, including a concept owned by another module that this domain only references.

### Step 2, owned canonical code, scoped to the domain slice

```bash
# entities is keyed by table_name (no name/id column); module_id IN the domain's present modules.
semantius call crud postgrestRequest '{"method":"GET","path":"/entities?catalog_entity_code=eq.<X>&module_id=in.(<domain_module_ids>)&select=table_name,module_id,catalog_entity_code"}'
```

Catches masters the domain owns and the domain's own silos (where `table_name` is an `X`-rename,
e.g. `erp_vendors` carrying `catalog_entity_code = vendors`), including an `X` with no incoming FK.
A hit whose `name` differs from `X` is a deterministic **rename** (record `entity_renames[X] = name`).
Exactly one in-slice hit resolves; more than one is a genuine `multi_owner` ambiguity (Phase 2b).

### Step 3, alias (reuse/merge onto a differently-named host)

```bash
semantius call crud postgrestRequest '{"method":"GET","path":"/entities?catalog_entity_aliases=cs.[{\"alias_code\":\"<X>\",\"source_domain\":\"<D>\"}]&select=table_name,module_id,catalog_entity_aliases"}'
```

(`cs` is PostgREST JSONB containment, `@>`.) Resolve on the **`(alias_code, source_domain)` pair**,
never `alias_code` alone, so the domain matches only its own merge, not another domain's
identically-named one. This catches the reuse/merge where `X` was renamed onto an existing host and
left no FK shadow. The host's `name` is the live table; record `entity_renames[X] = name`.

### Step 4, absent (true omission vs external context)

None of the above resolved `X`. Split by whether the domain OWNS `X`:

- **Owned** (`X` is one of the domain's masters): genuinely not deployed here. Record in
  `omitted_entities`; the skill must not generate queries against it.
- **External** (`X` is only an `embedded_master` / `consumer`, a concept another domain
  masters that this deployment did not bring along): record in `external_entities`, not
  `omitted_entities`. It was never this domain's to deploy, so do not report it as an ATS
  omission. The skill still cannot query it here; the distinction is for accurate explanation.

(A `step 0` precedes step 1: any resolution the user already recorded in `state.jsonc` from a
prior Phase 2b, `entity_renames`, `omitted_entities`, `custom_entities`, is applied first, so
the bootstrap loop converges. See Phase 2b below.)

> The danger the ladder removes: without step 3 (and with no FK shadow) a reuse/merge looks like
> **absence**, so a live, renamed concept is mis-filed as omitted and every workflow it drives is
> silently dropped. Step 1 mitigates; step 3 makes it deterministic.

---

## Pass 3: fields (per discovered entity)

`phase2a` pulls each entity's full operational shape ONCE and persists it, so the skill never
re-queries field names, formats, enums, relationships, or write rules at runtime. The entity read
captures `id_column`, `label_column`, `label_parent`, `description`, `view`/`edit_permission` (the
label column is entity-specific and must be read, not assumed), governance flags (`edit_mode`,
`is_child`, `audit_log`, `cube_mode`, `managed`, `searchable`, `updated_at`), and the **operating
contract**:

- **`validation_rules`**, live jsonlogic write guards, each with a human `message` + `description`
  (e.g. moving an application to `hired` requires `hiring-starter:hire_candidate`; an edit-scope rule
  limiting writes to the owner). Honor these before any write; surface the `message` on a block.
- **`select_rule`**, row-level read visibility (RLS). A query may over- or under-return relative to
  what the UI shows; the rule tells you the actual scope (e.g. own rows unless `view_all_*`).
- **`computed_fields`**, server-derived/virtual fields; never write them, and do not assume they are
  present on a naive read.

Fields are pulled with the provenance key plus the operational columns (including the per-field
`input_type_rule`, the conditional required/readonly/visibility jsonlogic):

```bash
# entity: identity + governance + operating contract
semantius call crud postgrestRequest '{"method":"GET","path":"/entities?table_name=eq.<live_table>&select=table_name,id_column,label_column,label_parent,description,view_permission,edit_permission,validation_rules,select_rule,computed_fields,edit_mode,is_child,audit_log,cube_mode,managed,searchable,updated_at"}'
# fields: provenance + operational shape
semantius call crud postgrestRequest '{"method":"GET","path":"/fields?table_name=eq.<live_table>&select=field_name,catalog_field_code,format,ctype,cube_type,is_pk,is_nullable,unique_value,searchable,precision,input_type,input_type_rule,default_value,reference_table,reference_delete_mode,relationship_label,singular_label_parent,plural_label_parent,enum_values,title,description,field_order&order=field_order.asc"}'
```

- **Field renames are a join:** `catalog_field_code` holds the canonical/blueprint field name even
  when `field_name` drifted. Match a spec field to its live field by `catalog_field_code`, not by
  name. (A bare `''` code is a pre-provenance/custom field, fall back to the name.)
- **Lifecycle column is invariant:** the lifecycle column is ALWAYS named `workflow_state`
  (`field_name`) on every deployment, never `status`/`state`/`stage`/`disposition`. Match it
  exactly; never guess among synonyms. If a master whose spec declares `lifecycle_states` has no
  live `workflow_state` column, that is drift: phase2a flags it as a `lifecycle_field_missing`
  ambiguity rather than silently recording `lifecycle_field: null`.
- **Lifecycle / enum vocabulary is live:** `enum_values` on the lifecycle field IS the current set
  of states. A customer who adds or removes a state changes this row; the persisted `lifecycle_values`
  reflect the deployment, not the frozen `spec.json`.
- **Relationship shape is live:** each FK field carries `reference_table` (target),
  `reference_delete_mode` (`restrict` / `clear` / `cascade`), and `relationship_label` (the verb the
  UI renders). All three are persisted so the skill knows the relationship and its delete behavior
  without re-deriving them.
- **FK omissions:** if the spec expects an FK on `X` and no live field carries that
  `catalog_field_code`, record the omission so the skill does not reference it.

---

## Phase 2b: resolve the genuine ambiguities only

`phase2a` emits an `ambiguities[]` list. A fully-stamped deployment yields none. Each remaining one
is a real judgment call. Default to ASK; a wrong resolution propagates into every later run.

**How the loop terminates (read this).** The cycle is: phase2a emits ambiguities → the agent
asks the user → the agent records the resolutions in `state.jsonc` → the agent re-invokes
`bootstrap.ts`. This converges **because `phase2a` reads `state.jsonc` back on every run** (step 0
of the ladder) and drops anything already resolved from the `ambiguities[]` it emits. `state.jsonc`
is JSONC (JSON + `//` / `/* */` comments + trailing commas), parsed with `Bun.JSONC.parse`, so
comments and key ordering can never corrupt a value. Record each resolution under the matching key:

| Resolution | Record in `state.jsonc` as | Effect on next phase2a run |
|---|---|---|
| rename confirmed / multi_owner pick | `"entity_renames": { "concept": "live_table" }` | concept resolves via `state_resolution`; ambiguity gone |
| row confirmed custom | `"custom_entities": ["live_table", ...]` | row recorded as custom; no `custom_entity` ambiguity |
| concept confirmed omitted | `"omitted_entities": ["concept", ...]` | concept forced absent; no ambiguity |
| user said "skip" | `"unresolved_questions": ["concept_or_live_name", ...]` | downgraded to non-blocking `deferred[]`; surfaced next session |

Values are matched verbatim against concept codes / live table names, so write the bare code
(`"background_checks"`), not a decorated phrase. List items may also be objects
(`{ "concept": "background_checks", "note": "..." }`); phase2a reads `concept` / `live_name` /
`name` keys in any order.

| Ambiguity `kind` | When phase2a emits it | Agent action |
|---|---|---|
| `rename_candidate` | a live row with **empty** `catalog_entity_code` whose name/label matches an otherwise-unresolved concept | ASK: *"`<live_name>` has no catalog lineage but looks like your `<concept>`. Same thing?"* On yes, record the rename in `state.jsonc`; on no, treat as custom. |
| `custom_entity` | an **empty-code** row matching no concept | ASK to classify its role (master / log / reference data), or confirm it is custom. Record in `state.custom_entities`. |
| `multi_owner` | more than one in-slice entity shares `catalog_entity_code = X` | ASK which is the one the domain means; record the choice. |

Everything phase2a resolved via steps 1–3 is deterministic and needs **no** prompt. Stamped-but-not-
this-domain rows (a neighbor-domain master reused here, non-empty code matching no concept) are
recorded informationally, not prompted.

If the user says "skip" / "I don't know", record the question in `state.unresolved_questions` and
proceed; surface unresolved questions at the start of the next session.

---

## Pass 4: write `discovered.json` + `state.jsonc`, report

`phase2a` writes `discovered.json` (full snapshot, loaded on demand). Per entity it records the
provenance reads:

```json
{
  "discovered_at": "2026-06-15",
  "domain_code": "ATS",
  "slice_module_ids": [1033],
  "modules": {
    "1033": {
      "module_slug": "hiring-starter", "module_name": "Hiring Starter", "catalog_module_code": "hiring-starter",
      "settings": { "domain_code": "ATS", "module_kind": "starter", "naming_mode": "agent-optimized" }
    }
  },
  "resolution": {
    "<concept>": { "via": "state_resolution|fk_reachability|owned_code|alias|absent|external_absent|deferred", "live_table": "<name>", "renamed": false }
  },
  "entity_renames": { "<canonical_concept>": "<live_table>" },
  "omitted_entities": ["<owned_concept_not_deployed>"],
  "external_entities": ["<concept_owned_by_another_domain>"],
  "custom_entities": [{ "live_name": "<name>", "module_id": 0, "catalog_entity_code": "" }],
  "fetch_errors": [],
  "entities": {
    "job_applications": {
      "catalog_entity_code": "job_applications", "catalog_owner_module": "", "entity_type": "operational_workflow",
      "catalog_entity_aliases": [],
      "module_id": 1033, "singular_label": "Application", "plural_label": "Applications",
      "description": "...", "id_column": "id", "label_column": "application_ref", "label_parent": "candidate_id",
      "view_permission": "hiring-starter:read", "edit_permission": "hiring-starter:manage",
      "edit_mode": "auto", "is_child": false, "audit_log": true, "cube_mode": "auto", "managed": true, "searchable": true, "updated_at": "...",
      "validation_rules": [
        { "code": "hire_via_application_requires_permission",
          "message": "Only users with the hire-candidate permission can move an application to hired.",
          "description": "Gates the transition into the hired terminal state.",
          "jsonlogic": { "if": ["...status==hired...", { "require_permission": "hiring-starter:hire_candidate" }, true] } }
      ],
      "select_rule": { "or": [{ "==": [{ "var": "owner_user_id" }, { "var": "$user_id" }] }, { "has_permission": "hiring-starter:view_all_applications" }] },
      "computed_fields": [],
      "fields": [
        { "name": "candidate_id", "title": "Candidate", "catalog_field_code": "candidate_id",
          "format": "reference", "ctype": "", "cube_type": "dimension", "is_pk": false, "is_nullable": true, "unique_value": false,
          "searchable": true, "precision": null, "field_order": 30, "input_type": "required", "input_type_rule": {}, "default_value": "",
          "reference_table": "candidates", "reference_delete_mode": "restrict", "relationship_label": "submits",
          "singular_label_parent": "", "plural_label_parent": "", "enum_values": null },
        { "name": "workflow_state", "title": "Status", "catalog_field_code": "workflow_state",
          "format": "enum", "ctype": "", "cube_type": "dimension", "is_pk": false, "is_nullable": false, "unique_value": false,
          "searchable": false, "precision": 2, "field_order": 60, "input_type": "required", "input_type_rule": {}, "default_value": "applied",
          "reference_table": "", "reference_delete_mode": "", "relationship_label": "has",
          "singular_label_parent": "", "plural_label_parent": "",
          "enum_values": ["applied", "screening", "interviewing", "offer_extended", "hired", "rejected", "withdrawn"] }
      ],
      "lifecycle_field": "workflow_state",
      "lifecycle_values": ["applied", "screening", "interviewing", "offer_extended", "hired", "rejected", "withdrawn"]
    }
  }
}
```

The agent then writes the lean `state.jsonc` deltas (module presence, `entity_renames`,
`omitted_entities`, `custom_entities`, `unresolved_questions`, plus any Phase 2b resolutions), and
surfaces a one-screen summary:

```
IT Operations Starter discovery complete (deterministic).
  Modules: 3 of 4 deployed (<code> not deployed)
  Concepts: 11 resolved (1 rename: job_applications -> applications via owned_code), 2 omitted
  Custom / empty-code rows: 1 (referral_bonuses -> classify)
  Ambiguities needing you: 0
  Written to: discovered.json + state.jsonc
```

---

## When discovery should ASK vs ASSUME

The ladder makes most of this moot: steps 1–3 are deterministic and never ASK. ASK only on the
Phase 2b ambiguities above, all of which arise from **empty** provenance (rows outside the deploy
pipeline) or genuine multi-recurrence. Specifically:

- **`rename_candidate` / `custom_entity` / `multi_owner`**: ASK.
- **Deterministic resolution (steps 1–3)**: ASSUME (it is a platform read, not a guess).
- **Module not deployed**: ASSUME deployment choice, don't ASK.
- **Field omissions**: log to state, don't ASK upfront; let runtime failures drive it.
