---
name: use-hvac-svc-mgmt
description: >-
  Run a heating and cooling service shop end to end: log customer calls, track contacts and the equipment installed at each site, set preventive maintenance cadences, turn a quote into a work order, dispatch and schedule a technician for the visit, draft recurring maintenance agreements, draw down spare parts, and bill the completed job with an invoice. Confirm appointments and send maintenance reminders to customers. Use for: HVAC, furnace, air conditioning, refrigeration, boiler, field service management, FSM, trades, contractor, home services, ticket, callout, route, truck roll, warranty, inventory, billing, quote-to-cash.
---

# use-hvac-svc-mgmt skill

This skill knows the **HVAC Service Management (small-org starter)** domain as shipped from the DomainMap catalog and as discovered in this deployment. It avoids re-discovering the domain shape on every conversation by persisting deployment-specific findings to local state.

For all Semantius CLI mechanics, PostgREST encoding, and cube DSL, defer to the `use-semantius` skill, which is expected to load alongside.

**Domain inventory** (as-designed, from `spec.json`, orientation only). The actual deployed entities, with renames and omissions already resolved, live in `discovered.json`; operate from that, never from this list:

- Workflows / capabilities: Dispatch and Routing Optimization, Installed Equipment Management, Mobile Technician Enablement, Field Parts and Truck Stock Management, Preventive Maintenance Planning, Service Contract and SLA Management

---

## File layout

| File | Source of truth | Mutated by |
|---|---|---|
| `SKILL.md` | rendered from template + spec in DomainMap | DomainMap on skill upgrade |
| `spec.json` | DomainMap catalog emit (structured per-domain data) | DomainMap on skill upgrade |
| `state.jsonc` | deployment discovery run | this skill |
| `discovered.json` | deployment discovery run (full discovered schema) | this skill |
| `learnings.jsonc` | deployment runtime | this skill (earned-knowledge store) |
| `ready.flag` | written by `scripts/bootstrap.ts` | bootstrap (single producer) |
| `references/` | generic, no per-domain content | DomainMap on skill upgrade |
| `scripts/` | generic Bun/TypeScript bootstrap scripts | DomainMap on skill upgrade |

The skill **learns** locally through two files: `state.jsonc` (structural deltas vs. spec) and `learnings.jsonc` (earned knowledge: error fixes, user corrections, validated recipes, deployment quirks). Both are read on every invocation and applied to subsequent operations. `SKILL.md` itself stays untouched: the procedure manual is stable; the learning layer grows around it.

The installer preserves `state.jsonc` and `learnings.jsonc` across upgrades. Teams should commit both alongside the skill if they want shared discovery and earned knowledge.

---

## On every invocation

Before doing any domain work, the skill follows this sequence:

1. **Verify `use-semantius` is loaded in the session.** Look at the available-skills list in the system reminder. If `use-semantius` is not present, halt with this exact message (use the command below verbatim; do NOT invent an install URL): *"This skill delegates all Semantius CLI mechanics to `use-semantius`. Install it and reload the session: `npx skills add https://github.com/semantius/semantius-cli/tree/main/skills/use-semantius`"*. This is an agent-level check (no script can see what's loaded in the Claude Code session); the agent performs it on every invocation as the cheapest gate.
2. **Verify Bun is installed.** Run `bun --version`. If exit code is non-zero, halt with the install link (`https://bun.sh/install`). All scripts in `scripts/` are TypeScript on Bun (no Python, ever, see hard rules). The skill cannot proceed without Bun.
3. **Read `learnings.jsonc`** in full (it is small). It is the **earned-knowledge** store: knowledge the skill had to work out or was told, that neither the CLI nor re-discovery can give back. Each entry is a `trigger` + `resolution` of kind `error_fix`, `user_input`, `recipe`, or `quirk`. Before solving a non-trivial operation or after a failure, match by `trigger` and apply `active` resolutions instead of re-deriving them; surface `proposed` ones for one-tap confirmation. Format and trust/decay rules: [references/learnings-format.md](./references/learnings-format.md).
   - If bootstrap halts Phase 1 with `can_offer_install: true` (the `semantius` CLI is not installed), **offer to run the install for the user.** The result carries `install_command` (the one-liner for their platform) and `install_docs`. Ask their go-ahead first (it modifies their system); never auto-install silently. On "yes", run the exact `install_command`, have them restart the shell if PATH changed, then re-run bootstrap. On "no", surface `install_docs` and stop.
4. **Check `ready.flag`.** Single-file check. The skill is ready when:
   - `ready.flag` exists, AND
   - `ready.flag.valid_through_emitted == spec.emitted`, AND
   - `ready.flag.valid_through_major == spec.facts_major`.
   If any condition fails, run `bun run scripts/bootstrap.ts` from the project root. Bootstrap orchestrates Phase 1 (environment) → Phase 2a (runs the provenance resolution ladder, writes `discovered.json`) → ready.flag. Phase 2a resolves every DomainMap concept against the live deployment by **deterministic platform reads** (no name guessing): see the ladder below. If Phase 2a leaves genuine ambiguities (a live row with an **empty** `catalog_entity_code`, i.e. created outside the deploy pipeline, or a concept that resolves to more than one in-domain entity), bootstrap DOES NOT write `ready.flag`; the agent runs Phase 2b ([references/discovery.md](./references/discovery.md)) to surface only those to the user, records resolutions in `state.jsonc`, then re-invokes `bootstrap.ts`. A fully provenance-stamped deployment yields zero ambiguities and no prompts. **Run all of this silently:** the user must never see bootstrap mechanics, internal file names, module IDs, version numbers, or read-by-read narration (see [How to talk about the deployment](#how-to-talk-about-the-deployment)).
5. **Once `ready.flag` is current,** answer the user's request from the persisted discovery, not from live re-queries. `discovered.json` already holds the full operational shape of this deployment, captured once at bootstrap: per entity the deployed `table_name`, `id_column` and `label_column` (read, never assumed: the label column is entity-specific, e.g. `candidate_name` vs `application_ref`), `description`, view/edit permissions, and per field the `name`, `title`, `format`, `ctype`, `enum_values` (live lifecycle/enum vocab), `reference_table` + `reference_delete_mode` + `relationship_label` (the relationship shape), and `is_pk`/`is_nullable`/`unique_value`. `state.jsonc` holds the deployment deltas (renames, omissions). Read those files; do NOT re-discover field names, formats, enums, or relationships per request, that is what the one-time discovery is for. **Before any write, apply the entity's operating contract from `discovered.json`**: `validation_rules` (live write guards, each with a human `message`), `input_type_rule` (conditional field editability), and `select_rule` (row-level read visibility, so you know what a query returns vs. what the UI shows). Never assume catalog names hold; this deployment may have renamed `suppliers` to `vendors`, dropped `cost_centers`, or split a master into two entities. Operational failures from semantius calls surface verbatim (Rule #6); the skill does NOT pre-flight authentication on every invocation; trust the CLI to error when it errors.
6. **When something is earned during the run, write it to `learnings.jsonc`** so it is not re-derived next session: a call that failed in a non-obvious way plus the working form (`error_fix`), a correction or rule the user supplied (`user_input`), a validated multi-step or multi-table operation (`recipe`), or a deployment-specific fact the schema cannot express (`quirk`). `user_input` is `active` immediately; a `recipe` is `active` only after it actually ran and returned the expected result; `error_fix`/`quirk` are `proposed` until reconfirmed or user-approved. Re-encountered knowledge bumps `confidence`/`last_seen` rather than duplicating; contradicted knowledge is marked `obsolete`, never deleted. Do NOT record what `discovered.json` already holds (a plain rename is fixed by re-discovery, not remembered here). These feed back into step 3 on the next invocation. See [references/learnings-format.md](./references/learnings-format.md).

To force a fresh discovery: delete `ready.flag` (or also `discovered.json` and `.phase1-cache.json` for a fully cold rebuild). The next invocation will re-run bootstrap.

---

## How discovery resolves concepts (the provenance ladder)

As of core v0.1.2 the live platform carries provenance columns, so discovery reads identity instead of guessing it. The **domain slice** (the modules Phase 2a scans) is resolved by Phase 1 as the UNION of two deterministic signals: **(a) the deploy stamp**, modules whose `settings.domain_code` equals this domain's code (the deploy pipeline writes `{ domain_code, module_kind, naming_mode, catalog_snapshot }` into each provisioned module's `settings` JSONB; this is the authoritative marker and holds even when a deployment's entities were never `catalog_entity_code`-stamped), and **(b) entity-first**, the live `module_id`s that host the domain's owned master codes. A module carrying a spec module code/slug is a weak hint folded into the same union. For each DomainMap concept `X` the domain assumes, Phase 2a resolves it against the live deployment in this order (first hit wins), and a live `table_name` that differs from `X` is a deterministic rename:

0. **State resolution**, a resolution the user already recorded in `state.jsonc` from a prior Phase 2b (rename, omission, or custom classification). Applied first so the bootstrap loop converges instead of re-asking.
1. **FK reachability**, a live FK on the domain's own entities whose `reference_table` resolves to an entity carrying `catalog_entity_code = X`. Reseating is universal, so this catches silo, same-name share, and reuse/merge whenever `X` still has a consumer in the domain.
2. **Owned canonical code**, `catalog_entity_code = X` AND the entity's module is in the domain slice. Catches masters the domain owns and its own silos (`table_name` is the `X`-rename).
3. **Alias**, an entity whose `catalog_entity_aliases` contains `{ alias_code: X, source_domain: <this domain> }` (JSONB containment; resolve on the **pair**, never `alias_code` alone). Catches a reuse/merge that renamed `X` onto a differently-named host.
4. **Absent**, none of the above. If the domain OWNS `X` it is a true omission (`omitted_entities`); if `X` is only referenced (embedded master / consumer owned by another domain) it is external context (`external_entities`), not an omission.

The provenance columns and their **empty** values (core v0.1.2 stores NOT NULL with an empty default, so test against the empty value, **never `IS NULL`**):

| Column (table) | Empty | Empty means |
|---|---|---|
| `catalog_entity_code` (`entities`) | `''` | outside the deploy pipeline (hand-built / pre-provenance) |
| `canonical_owner_module` (`entities`) | `''` | this module owns it, or local |
| `pattern_flags` (`entities`, json) | `'{}'` | no special behavior |
| `catalog_entity_aliases` (`entities`, json) | `'[]'` | never a merge target |
| `entity_type` (`entities`) | `'unclassified'` | unclassified upstream |
| `catalog_field_code` (`fields`) | `''` | outside the pipeline |
| `catalog_module_code` (`modules`) | `''` | greenfield; a weak **hint** for the slice (membership is resolved by `settings.domain_code` + entity-first, not by this code) |
| `settings` (`modules`, json) | `null` | not provisioned by the deploy pipeline (hand-built); its `domain_code` key is the authoritative slice marker when present |

`catalog_entity_code` stamps the **canonical** DomainMap code (so the join is clean across dialect and silo renames); the deployed name lives in `table_name`. The name/alias/label heuristic survives only as a fallback for rows whose `catalog_entity_code` is empty. Full procedure and query shapes: [references/discovery.md](./references/discovery.md).

---

## What's in `spec.json`

The DomainMap-emitted structured snapshot of this domain. Read on demand (not loaded into every conversation). Includes:

- Domain metadata (description)
- Functional ownership (owner / contributor / consumer business functions)
- Capabilities and the modules that realize them
- Modules with their masters, embedded-masters, consumers
- Per-master pattern flags, aliases, lifecycle states
- Intra-domain relationships and edges to platform built-ins
- Domain-level APQC process rollup (`apqc_processes_touched`) for cross-domain process queries
- System skills and tool sets per module
- Expected role personas with their module footprints
- Catalog enum vocabularies for any column the skill might write

**Treat `spec.json` as the read-only "as-designed" shape.** What this deployment actually configured lives in `state.jsonc`.

---

## What's in `state.jsonc`

Written by the skill during discovery. Records the deployment-specific reality:

`state.jsonc` is **JSONC** (JSON plus `//` and `/* */` comments and trailing commas), parsed by `phase2a` with Bun's built-in `Bun.JSONC.parse`. Comments are safe, so you can annotate decisions inline:

```jsonc
{
  "discovered_at": "2026-05-30",
  "discovered_against_major": 1,
  "discovered_against_emitted": "2026-05-30",

  "deployment": {
    "module_ids": [1033],          // the entity-first domain slice (from Phase 1)
    "org": "<from getCurrentUser>"
  },

  // The four keys below are the loop-termination contract: phase2a reads them back on every
  // run (ladder step 0) and drops anything already resolved from its ambiguities[].
  "entity_renames": {              // rename confirmations + multi_owner picks (concept -> live table)
    "job_applications": "applications",   // this deployment prefers the bare-word form
    "recruitment_sources": "sources"
  },
  "omitted_entities": ["background_checks"],   // OWNED concepts the user confirmed not deployed here
  "custom_entities": [],           // live table names confirmed custom
  "unresolved_questions": []       // concept/live names the user said "skip" (-> non-blocking deferred)
  // Note: external_entities is NOT recorded here; phase2a computes it into discovered.json.
  // Only the four keys above are read back by phase2a (ladder step 0).
}
```

---

## What's in `learnings.jsonc`

The **earned-knowledge** store: only knowledge the CLI exit codes and re-discovery cannot give back, what the schema does NOT tell us. It is NOT a drift detector and NOT a schema cache (those are `discovered.json` + re-discovery). A single JSONC array of entries, each a `trigger` (the situation it matches) + `resolution` (what to do), of one kind:

- **`error_fix`**, a call that failed in a non-obvious way, plus the working form found.
- **`user_input`**, a correction, confirmation, or rule the user supplied that is not in the schema.
- **`recipe`**, a validated multi-step or multi-table operation/query (e.g. a 3-table cube join for a metric), so a solution found once is not re-derived.
- **`quirk`**, a deployment-specific fact the schema cannot express (e.g. this deployment leaves `source_id` null and tracks source on the candidate).

The point is persistence: match by `trigger` before a non-trivial op, apply the known `resolution` instead of working it out again. Trust and decay (`proposed`/`active`/`obsolete`, confidence bumps, never-delete) are in [references/learnings-format.md](./references/learnings-format.md). Local to this deployment by default; a genuinely universal learning can be upstreamed via the catalog's contribution channel (never automatic). `learnings.jsonc` REPLACES the former `lessons.md` + `improvements.md`.

## What's in `discovered.json`

The full discovered schema written by the discovery procedure. This is the **operational source of truth** the skill works from: the entire deployed shape is captured once at bootstrap so no field name, format, enum, or relationship is ever re-queried or guessed at runtime. Loaded on demand (not on every conversation). It carries:

- `resolution`, per concept, how the ladder resolved it (`via: state_resolution | fk_reachability | owned_code | alias | absent | external_absent | deferred`, the `live_table`, and whether it `renamed`).
- `entity_renames`, canonical concept → live `table_name` (deterministic, from the ladder).
- `omitted_entities`, OWNED concepts not deployed here; `external_entities`, concepts owned by another domain and not present; `custom_entities`, live rows not claimed by a concept.
- `modules`, per `module_id` in the slice: `module_slug`, `module_name`, `catalog_module_code`, and the deploy `settings` (`domain_code`, `module_kind`, `naming_mode`). Use `module_slug` for UI URLs (the DEPLOYED slug, e.g. `hiring-starter`, not the catalog code).
- `entities`, per live table: identity and provenance (`catalog_entity_code`, `canonical_owner_module`, `entity_type`, `pattern_flags`, `catalog_entity_aliases`); the operational shape: `id_column`, `label_column`, `label_parent`, `description`, `view_permission`, `edit_permission`; governance: `edit_mode`, `is_child`, `audit_log`, `cube_mode`, `managed`, `searchable`, `updated_at`; and `fields`. Each field carries `name`, `title`, `description`, `catalog_field_code`, `format`, `ctype`, `cube_type`, `is_pk`, `is_nullable`, `unique_value`, `searchable`, `precision`, `field_order`, `input_type`, `input_type_rule`, `default_value`, `reference_table`, `reference_delete_mode`, `relationship_label`, `singular_label_parent`/`plural_label_parent`, and `enum_values`, plus the entity's `lifecycle_field`/`lifecycle_values`.
- **The operating contract** (honor before any write): `validation_rules` (live jsonlogic write guards, each with a human `message` + `description`, e.g. moving an application to `hired` requires a permission), `select_rule` (row-level read visibility / RLS, so you know what a query actually returns vs. what the UI shows), `computed_fields` (server-derived, never write them), and per-field `input_type_rule` (conditional required/readonly/visibility). These are the deployment's live "how to operate safely" rules and are captured so the skill applies them without re-deriving.

Together with `state.jsonc` this gives the complete picture of what this deployment actually has, no live re-query needed. When a customer edits a lifecycle state, renames a field, tightens a validation rule, or adds an entity, a fresh discovery (delete `ready.flag`) re-captures it; the live platform, not the frozen `spec.json`, is the source of truth.

---

## How to talk about the deployment

Use the words the customer knows. They experience Semantius as **the platform**, and their own configured instance as **your platform**, **this deployment**, or **your workspace**. **Never call it a "tenant" in anything the user reads.** "Tenant" is internal infrastructure vocabulary; the customer does not know they are one, and the word means nothing to them.

This governs every explanation you give about renames, omitted modules, or why a table is not present:

- Good: *"Your platform runs the Hiring Starter package. The broader Candidate CRM, talent pools, and compliance modules are available in the catalog and can be added whenever you need them."*
- Bad: *"This tenant runs the lightweight Hiring Starter bundle rather than the full catalog ATS module set."*

The word "tenant" may still appear in internal mechanics the customer never sees: state files, field names, script diagnostics, and these procedure docs. Only what the user reads is governed by this rule.

### Keep the machinery invisible

Everything in "On every invocation" (the `use-semantius`/Bun checks, `ready.flag`, bootstrap, the provenance ladder, `discovered.json`/`state.jsonc`/`learnings.jsonc`, module IDs, version numbers) is internal plumbing the user must NEVER see narrated. Run it silently. Do not announce file reads, "bootstrapping", "provenance-stamped", "discovery resolved", "module 1033", Bun versions, "on-invocation checks", or "6 of 8 entities, let me read the rest". If discovery has to run and will take a beat, say at most one plain line, e.g. *"One moment, taking stock of how your platform is set up..."*, then deliver the answer. The user asked a question; show them the answer, not the build log.

- Good: *"One moment, checking your setup... Your platform runs the Hiring Starter package, a slim recruiting pipeline. Here is what you can do."*
- Bad: *"There is no `ready.flag` or `discovered.json` yet, so I will run bootstrap. Bun 1.3.12 is present. Bootstrap succeeded with zero deferred questions; the deployment is fully provenance-stamped. Let me read `discovered.json`..."*

### Lead with what they can DO, then what they have

When the user asks an open question ("what can I do?", "help", "what is this?"), answer jobs-first: the workflows this deployment supports (post a job, screen candidates, schedule interviews, send offers), and only then the entities behind them. The entity and lifecycle detail is supporting material, not the headline. A data-model tour answers "show me the schema", not "what can I do".

### Use the human labels, hide the table names

In anything the user reads, use the entity `singular_label`/`plural_label` and field `title` from `discovered.json` (Candidates, Job Postings, Applications), never the raw `table_name`/`field_name` (`job_applications`, `interview_scorecards`, `workflow_state`). Raw names belong only in code blocks, copy-pasteable queries, or a block explicitly marked as the technical view. Do not mix the two in one sentence or diagram: a user-facing flow diagram uses labels; a diagram that shows raw table names is a technical view and should be labeled as such.

### Frame what is not deployed as available, not missing

`omitted_entities` and `external_entities`, and the capabilities they would power, are **optional features that exist in the broader catalog and can be added to this deployment**. They are not limitations, gaps, or anything broken. Describe them as opportunities to enable, never as a wall of "no X, no Y, no Z" that ends in "I cannot do that". Turning one on is a configuration / deployment change (a quick admin step), not a dead end.

- Good: *"Your platform runs the slim Hiring Starter pipeline. You can optionally add background checks, compliance (FCRA/EEO/OFCCP), requisitions and approvals, offer letter templates, talent pools, referrals, and assessments. These are available in the ATS catalog and can be switched on for your deployment whenever you need them. Want me to outline how to add one?"*
- Bad: *"No background checks, no compliance, no requisitions, no offer letters, no talent pools. Those are not deployed here and not something I can query."*

Stay honest: they are not active right now, but the framing is "available to enable", not "you do not have this", and you offer the next step (how to add it) rather than closing the door.

---

## Hard rules inherited from the catalog

These hold across every Semantius write the skill performs, regardless of what the user asks:

- **Use the `semantius` CLI exclusively.** Never call MCP-exposed Semantius tools; they might authenticate against a different scope and could fail or hit the wrong deployment.
- **Never use Python. Use Bun (TypeScript) for every script.** Python on Windows is brittle in this project's deployment surface (encoding mismatches piping JSON into `semantius`, venv/path drift, subprocess plumbing that swallows stderr). The bootstrap scripts ship as `.ts` files run with `bun`. Any script this skill writes (bootstrap, discovery, ad-hoc helpers, loaders) MUST be TypeScript on Bun. "Just this once" with Python is not acceptable. If you think Python is the right tool, you're wrong, write the TypeScript instead.


---

## Quick reference

Spec file: [`spec.json`](./spec.json)

State file: `./state.jsonc` (created on first discovery)

Learnings file: `./learnings.jsonc` (earned knowledge; created on first learning)

Discovered schema: `./discovered.json` (full entity/field/relationship snapshot)

Procedure references:
- [Bootstrap checks](./references/bootstrap.md)
- [Discovery procedure](./references/discovery.md)
- [Learnings format](./references/learnings-format.md)
- [Skill changelog](./references/skill-changelog.md)
