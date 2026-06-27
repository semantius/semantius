---
name: use-lms
description: >-
  Author courses from lessons and assessments, publish new versions, and deliver self-paced training in the browser. Enroll learners and track each one through to completion, grade quizzes and exams, and post transcripts. Schedule instructor-led and virtual classroom sessions, book rooms, manage waitlists, and capture attendance. Assign mandatory compliance training, chase overdue learners, and keep audit-ready evidence for regulators. Issue certifications and badges, manage renewals and expiry, and let others verify them. Sequence learning paths tied to the skills a role needs, recommend the next course, and automate enrollments, reminders, and escalations. Handle learner consent and data-deletion requests. Use for: LMS, e-learning, SCORM, xAPI, Tin Can, cmi5, LRS, microlearning, blended learning, ILT, VILT, webinar, micro-credential, Open Badges, CEU, continuing education, recertification, OSHA, HIPAA, SOX, GDPR, anti-harassment, onboarding training, upskilling, reskilling, curriculum, course catalog, gradebook, proctoring, attestation, talent development, corporate L&D.
---

# use-lms skill

This skill knows the **Learning Management** domain as shipped from the DomainMap catalog and as discovered in this deployment. It avoids re-discovering the domain shape on every conversation by persisting deployment-specific findings to local state.

For all Semantius CLI mechanics, PostgREST encoding, cube DSL, and UI deep-link building, defer to the `use-semantius` skill, which is expected to load alongside.

**Domain inventory** (as-designed, from `spec.json`, orientation only). The actual deployed entities, with renames and omissions already resolved, live in `discovered.json`; operate from that, never from this list:

- Workflows / capabilities: Certification Management, Compliance Training, Content Delivery and Tracking, Course Authoring, Learning Paths, Credential Management, Instructor-Led Training Delivery, Learning Automation, Learner Privacy Compliance, Skills Management

---

## Runbook: every invocation, in order

**Rules that override your instincts, read these first:**

- **Determine state by running the script, never by reasoning about it.** Do not hand-probe the environment (`which semantius`, a manual `getCurrentUser`, "let me check whether you're connected") to decide what to do. Run `bun run scripts/bootstrap.ts` and act on what it returns. The script is the single source of truth for environment and connection state.
- **The only way to connect is: install the `semantius` CLI and configure `.env`.** There is no base URL to ask the user for, no cloud instance to spin up, no local-dev mode. If the platform is unreachable the fix is always exactly one of two things: install the CLI, or add `SEMANTIUS_API_KEY` to `.env` (see [Bootstrap exit handling](#bootstrap-exit-handling)). Never invent connection or onboarding options.
- ⛔ **A bootstrap HARD STOP is your ONLY move, not a failure to route around.** When bootstrap halts (CLI not installed, auth failure, **domain not deployed**), the action prescribed in [Bootstrap exit handling](#bootstrap-exit-handling) is the entire job for that turn. Do NOT reach for `semantius-admin` or any other skill to deploy/install/provision around the stop, and do NOT improvise an alternative because acting feels more helpful. Delivering the prescribed message and waiting IS the skill succeeding. This overrides any general instinct to "keep going until done".
- **A capability or usage question is discovery-gated.** Match by intent, not exact words: any open ask about what this can do or where to start. "What can I do here?", "show me an overview", "status", "give me the rundown", "what is this", "get started", and the like all route through [references/status-report.md](./references/status-report.md): run the gate, then report from `discovered.json`. Never answer one from the frontmatter (that is the pre-setup fallback only), and never let it short-circuit the gate.

Walk these gates in order. Pass to the next, or halt with the stated message. (Detailed expansion of each step: [Invocation steps (detailed reference)](#invocation-steps-detailed-reference).)

1. **`use-semantius` available?** Decide from your CURRENT CONTEXT, not the filesystem (installed-on-disk is not the same as in-context, so do NOT answer from file paths, `npx skills list`, or a prior turn). `use-semantius` carries a load canary, the token `us1-9d4f2a7b`, in its frontmatter `description`, so it rides in the available-skills list your harness surfaces (present whenever the skill is installed, even before its body loads). **Count** how many times that exact token appears anywhere in your current context, the available-skills list / skill descriptions AND any loaded skill bodies, NOT the conversation history. THIS instruction is the only place this skill writes it, so it contributes exactly one; `use-semantius`, when installed, contributes one more (from its description). List where you see each occurrence, then count.
   - **2 or more** (this instruction, plus `use-semantius`'s description) → available → step 2.
   - **1, or 0** → not available. Do NOT proceed and do NOT improvise its CLI mechanics (you do not have them; guessing them fails). Run `npx skills add semantius/semantius-cli --all` immediately (use this command verbatim; do NOT invent an install URL). This installs the whole Semantius CLI skill bundle (including `use-semantius` and `semantius-admin`) so later steps never have to install again.

     ⛔ **HARD STOP after this install. It ends the turn.** The newly installed skill only becomes usable in a NEW session; you cannot load it into this one. Do NOT continue to step 2 or any later step. Do NOT run bootstrap, discovery, or any script. Do NOT "verify" or "check" the install. Do NOT call `semantius` directly to route around the missing skill. Do NOT restart or re-source anything to force the load. Your ONLY action: tell the user, in plain language, that you had to install the Semantius tools, that they only work in a new session, and to start a new session and send their request again, **restating their actual request** so they can just resend it. No jargon (do not say "available-skills list" or "the client caches its list at startup"). Use this shape, with the real request filled in: *"I had to install the Semantius tools to do that, and they only work in a new session. Please start a new session, then send your request again, for example: «&lt;the user's original request&gt;»."* Then stop. Anti-patterns: continuing "in the meantime"; running bootstrap without `use-semantius`; offering other work while the user restarts.
2. **Bun installed?** Run `bun --version`.
   - Prints a version → step 3.
   - Non-zero exit → install it immediately by running the one-liner for the detected platform: **Windows (PowerShell)** `powershell -c "irm bun.sh/install.ps1 | iex"`; **macOS / Linux** `curl -fsSL https://bun.sh/install | bash`. Docs: https://bun.sh/install. Then run `bun --version` **once** more. If it now prints a version, continue to step 3. If it STILL fails → ⛔ **HARD STOP.** The installer wrote the new PATH to your system, but the process your shells are spawned from captured its environment at startup, so freshly spawned shells keep inheriting the stale PATH, and you cannot make that process re-read it. Do NOT proceed to later steps that need `bun`. Do NOT work around it with `npx bun`, an absolute path, or Python. Your ONLY action: say *"I've installed Bun, but it isn't on PATH for the process I run commands from. That environment was captured when your client started, so the new PATH likely won't apply until you restart the session (however your client does that). Once that's done, ask me again and I'll continue."* and stop. Every script here is TypeScript on Bun.
3. **Read `learnings.jsonc`** in full (it is small). Apply `active` resolutions matched by `trigger`; surface `proposed` ones for one-tap confirmation. It holds earned knowledge the CLI and re-discovery cannot give back. → step 4. Format: [references/learnings-format.md](./references/learnings-format.md).
4. **Is the discovery current?** Current = ALL of: `discovered.json` is present, AND `ready.flag` exists, AND `valid_through_emitted == spec.emitted`, AND `valid_through_major == spec.facts_major`. (`ready.flag` carries `schema_hash = sha256(discovered.json)`; you may also verify it matches to catch a drifted payload.) A current `ready.flag` with a missing `discovered.json` is a dangling flag: treat as NOT current and re-bootstrap, never answer from a flag whose payload is gone.
   - Current → step 5.
   - Any part fails → run `bun run scripts/bootstrap.ts` from the project root (do not probe by hand first), handle its result per [Bootstrap exit handling](#bootstrap-exit-handling), then re-check this gate. Run bootstrap and its Phase 2b follow-up silently ([Keep the machinery invisible](#keep-the-machinery-invisible)).
5. **Answer from the persisted discovery, never live re-queries.** `discovered.json` holds the full operational shape; `state.jsonc` holds the deployment deltas. **Before any write, apply the entity's operating contract** (`validation_rules`, `input_type_rule`, `select_rule`, `computed_fields`) from `discovered.json`. Catalog names may not hold (a master may be renamed, dropped, or split). Let `semantius` errors surface verbatim; do not pre-flight auth every turn. Field detail: [What's in `discovered.json`](#whats-in-discoveredjson).
6. **Write earned knowledge to `learnings.jsonc`** when something is learned this run (`error_fix`, `user_input`, `recipe`, `quirk`), so it is not re-derived next session. Trust/decay rules: [references/learnings-format.md](./references/learnings-format.md).

To force a fresh discovery: delete `ready.flag` (or also `discovered.json` and `.phase1-cache.json` for a fully cold rebuild); the next invocation re-runs bootstrap.

### Bootstrap exit handling

`bootstrap.ts` prints a JSON result. **Never show that JSON, the phase number, internal flags, file names, module IDs, or version numbers to the user.** Translate the exit into one plain line.

⛔ **CRITICAL: the exits below are HARD STOPS, not suggestions.** When bootstrap returns one of these results, your ONLY job is to execute the prescribed action and NOTHING ELSE. Do NOT reach for `semantius-admin`, `semantius-architect`, `semantius-modeler`, or any other skill to "fix" the condition yourself. Do NOT try to deploy, install, provision, or configure anything beyond exactly what the row says. Do NOT search the web or the platform for a dashboard URL, and do NOT invent an onboarding path. Performing the prescribed action correctly IS the skill working as designed: it is not a weak result or a failure, it is the success state.

| Bootstrap result | Your ONLY action | What you SAY (use this wording) |
|---|---|---|
| `can_offer_install: true` (CLI not installed) | Run the provided `install_command` immediately, then re-run bootstrap **once**. Do not ask first. ⛔ If bootstrap STILL reports the CLI missing, it's a PATH-captured-at-client-startup hard stop: the new PATH won't reach freshly spawned shells until the client process is restarted, which you can't force. Do NOT re-run in a loop and do NOT work around it (`npx`, absolute path), tell the user to restart the session and ask again, then STOP. ⛔ If the install command itself fails, surface `install_docs` and the error and STOP; do NOT retry with alternative methods (npm, brew, manual download). | *"Installing the Semantius CLI..."* then either *"...done, continuing."* or *"...installed, but it's not on PATH for this session yet. Please restart the session, then ask me again."* |
| Auth failure (missing or invalid `.env`) | Ask the user for their API key, save it to the `.env` the CLI reads, then re-verify. ⛔ If re-verification fails, surface the error and STOP. Do NOT try to create an account, find the key elsewhere, ask for a base URL, or bypass auth. | *"I need your Semantius API key to connect. Generate one at https://app.semantius.com/dashboard (Settings > API Keys), paste it here, and I'll save it and continue."* |
| JWT-audience error | Surface the error verbatim and STOP. Do NOT retry in a loop. | *(show the exact error, then)* *"This looks like a server-side auth-scope issue. Could you check the API key's audience?"* |
| **Domain not deployed (empty slice)** | ⛔ **HARD STOP. Your ONLY move is to deliver the message below and wait for the user's answer.** Do NOT call `semantius-admin` (or any skill) to deploy it yourself. Do NOT try to deploy, install, or provision the domain. Deploying begins only AFTER the user says yes, and only by walking THEM through it. | *"The Learning Management domain isn't deployed on your platform yet. It can be added from the catalog. Want me to walk you through deploying it?"* |
| OK, ambiguities remain | Run Phase 2b silently; ask ONLY the specific either/or it surfaces. | *(only the targeted question, e.g.)* *"Is your `applications` table the same as Job Applications?"* |
| OK, no ambiguities | Proceed to step 5 and answer. | *(nothing about bootstrap, just the answer.)* |

**After the user says yes to deploying:** Surface the blueprint URL from bootstrap's `fix` field verbatim (it ends with `Blueprint info: https://www.semantius.com/blueprints/<code>/`). Do not invent alternative paths (dashboard browsing, catalog search). The bootstrap result is the single source of truth for where to deploy. If the `fix` field is empty or malformed, tell the user to contact support; do not improvise a URL.

**Anti-patterns after a HARD STOP (do NOT do any of these):**

- Reaching for `semantius-admin` / `semantius-architect` / `semantius-modeler` to "just deploy it" or "just fix it" before the user has said go.
- Searching the web or the platform for a deploy URL, dashboard, or install alternative.
- Offering to spin up a new instance, account, or local-dev mode. None exist (see the runbook rules).
- Treating the stop as a failure and improvising an adjacent path "to be helpful". The stop IS the prescribed outcome; delivering it correctly is the skill succeeding.

### Common scenarios

| Scenario | Flow |
|---|---|
| First run, nothing set up | bootstrap → (install CLI, or ask for the API key, if it halts) → bootstrap again → answer |
| `ready.flag` current | read `discovered.json` → answer (no bootstrap) |
| Force re-discovery | delete `ready.flag` → bootstrap |
| Platform unreachable | bootstrap halts → install CLI, or ask for the API key and save it; never invent options |

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

## Invocation steps (detailed reference)

The action sequence is the [Runbook](#runbook-every-invocation-in-order) at the top of this file; this section is the detailed expansion of each gate. Same order, more depth:

1. **Verify `use-semantius` is available.** Use the load-canary **count** from Runbook step 1: count how many times `use-semantius`'s load-canary token appears anywhere in your context, the available-skills list / skill descriptions AND any loaded skill bodies (not the conversation history). `use-semantius` carries the token in its frontmatter `description`, so it is present whenever the skill is installed and surfaced, even before its body loads. This skill writes the token exactly once (in Runbook step 1), and `use-semantius` adds one more, so 2 or more occurrences mean available (proceed) and 1 or 0 means not available. Decide from context, not the filesystem (installed-on-disk is not in-context, so do not answer from file paths, `npx skills list`, or a prior turn). If not available, run `npx skills add semantius/semantius-cli --all` immediately (use this command verbatim; do NOT invent an install URL). This installs the whole Semantius CLI skill bundle (including `use-semantius` and `semantius-admin`) in one shot, so the deploy-blueprint fallback never has to install separately. ⛔ **HARD STOP after this install:** the added skill loads only after a session reload, which the agent cannot trigger. Do NOT continue to step 2, do NOT run any script, do NOT "verify" the install (a skill that isn't loaded can't be verified), and do NOT call `semantius` directly to work around it. The agent's only action is to tell the user, in plain language (no jargon), that the Semantius tools were just installed, that they only work in a new session, and to start a new session and send their request again, restating the user's actual request, e.g. *"I had to install the Semantius tools; they only work in a new session. Please start a new session and send your request again, for example: «&lt;the user's original request&gt;»."* Then stop. This is an agent-level check (no script can see which skills are loaded in your session); the agent performs it on every invocation as the cheapest gate.
2. **Verify Bun is installed.** Run `bun --version`. If the exit code is non-zero, install Bun immediately by running the one-liner for the detected platform: Windows (PowerShell) `powershell -c "irm bun.sh/install.ps1 | iex"`; macOS / Linux `curl -fsSL https://bun.sh/install | bash`. Then run `bun --version` **once** more. If it now prints a version, continue. If it STILL fails → ⛔ **HARD STOP:** the installer's PATH update isn't active in this shell and you cannot make it so. Do NOT proceed to later steps, and do NOT work around it with `npx bun`, an absolute path, or Python. Tell the user to restart their shell (or open a new terminal) and ask again, then stop. Docs: https://bun.sh/install. All scripts in `scripts/` are TypeScript on Bun (no Python, ever, see hard rules); the skill cannot proceed without Bun.
3. **Read `learnings.jsonc`** in full (it is small). It is the **earned-knowledge** store: knowledge the skill had to work out or was told, that neither the CLI nor re-discovery can give back. Each entry is a `trigger` + `resolution` of kind `error_fix`, `user_input`, `recipe`, or `quirk`. Before solving a non-trivial operation or after a failure, match by `trigger` and apply `active` resolutions instead of re-deriving them; surface `proposed` ones for one-tap confirmation. Format and trust/decay rules: [references/learnings-format.md](./references/learnings-format.md). (Bootstrap's `can_offer_install` and other exit modes are handled in [Bootstrap exit handling](#bootstrap-exit-handling), not here.)
4. **Check the discovery is current.** The skill is ready when:
   - `discovered.json` is present, AND
   - `ready.flag` exists, AND
   - `ready.flag.valid_through_emitted == spec.emitted`, AND
   - `ready.flag.valid_through_major == spec.facts_major`.
   (`ready.flag` carries `schema_hash = sha256(discovered.json)`; optionally verify it matches to catch a payload that drifted out of sync.) A current `ready.flag` with a missing `discovered.json` is a dangling flag: treat as NOT ready and re-bootstrap rather than trusting it. If any condition fails, run `bun run scripts/bootstrap.ts` from the project root. Bootstrap orchestrates Phase 1 (environment) → Phase 2a (runs the provenance resolution ladder, writes `discovered.json`) → ready.flag. Phase 2a resolves every DomainMap concept against the live deployment by **deterministic platform reads** (no name guessing): see the ladder below. If Phase 2a leaves genuine ambiguities (a live row with an **empty** `catalog_entity_code`, i.e. created outside the deploy pipeline, or a concept that resolves to more than one in-domain entity), bootstrap DOES NOT write `ready.flag`; the agent runs Phase 2b ([references/discovery.md](./references/discovery.md)) to surface only those to the user, records resolutions in `state.jsonc`, then re-invokes `bootstrap.ts`. A fully provenance-stamped deployment yields zero ambiguities and no prompts. **Run all of this silently:** the user must never see bootstrap mechanics, internal file names, module IDs, version numbers, or read-by-read narration (see [How to talk about the deployment](#how-to-talk-about-the-deployment)).
5. **Once `ready.flag` is current,** answer the user's request from the persisted discovery, not from live re-queries. `discovered.json` already holds the full operational shape of this deployment, captured once at bootstrap: per entity the deployed `table_name`, `id_column` and `label_column` (read, never assumed: the label column is entity-specific, e.g. `candidate_name` vs `application_ref`), `description`, view/edit permissions, and per field the `name`, `title`, `format`, `ctype`, `enum_values` (live lifecycle/enum vocab), `reference_table` + `reference_delete_mode` + `relationship_label` (the relationship shape), and `is_pk`/`is_nullable`/`unique_value`. `state.jsonc` holds the deployment deltas (renames, omissions). Read those files; do NOT re-discover field names, formats, enums, or relationships per request, that is what the one-time discovery is for. **Before any write, apply the entity's operating contract from `discovered.json`**: `validation_rules` (live write guards, each with a human `message`), `input_type_rule` (conditional field editability), and `select_rule` (row-level read visibility, so you know what a query returns vs. what the UI shows). Never assume catalog names hold; this deployment may have renamed `suppliers` to `vendors`, dropped `cost_centers`, or split a master into two entities. Operational failures from semantius calls surface verbatim (Rule #6); the skill does NOT pre-flight authentication on every invocation; trust the CLI to error when it errors.
6. **When something is earned during the run, write it to `learnings.jsonc`** so it is not re-derived next session: a call that failed in a non-obvious way plus the working form (`error_fix`), a correction or rule the user supplied (`user_input`), a validated multi-step or multi-table operation (`recipe`), or a deployment-specific fact the schema cannot express (`quirk`). `user_input` is `active` immediately; a `recipe` is `active` only after it actually ran and returned the expected result; `error_fix`/`quirk` are `proposed` until reconfirmed or user-approved. Re-encountered knowledge bumps `confidence`/`last_seen` rather than duplicating; contradicted knowledge is marked `obsolete`, never deleted. Do NOT record what `discovered.json` already holds (a plain rename is fixed by re-discovery, not remembered here). These feed back into step 3 on the next invocation. See [references/learnings-format.md](./references/learnings-format.md).

To force a fresh discovery: delete `ready.flag` (or also `discovered.json` and `.phase1-cache.json` for a fully cold rebuild). The next invocation will re-run bootstrap.

---

## How discovery resolves concepts (the provenance ladder)

As of core v0.1.2 the live platform carries provenance columns, so discovery reads identity instead of guessing it. The **domain slice** (the modules Phase 2a scans) is resolved by Phase 1 as the UNION of two deterministic signals: **(a) the deploy stamp**, modules whose `settings.domain_code` equals this domain's code (the deploy pipeline writes `{ domain_code, module_kind, naming_mode, catalog_snapshot }` into each provisioned module's `settings` JSONB; this is the authoritative marker and holds even when a deployment's entities were never `catalog_entity_code`-stamped), and **(b) entity-first**, the live `module_id`s that host the domain's owned master codes. A module carrying a spec module code/slug is a weak hint folded into the same union. For each DomainMap concept `X` the domain assumes, Phase 2a resolves it against the live deployment in this order (first hit wins), and a live `table_name` that differs from `X` is a deterministic rename:

0. **State resolution**, a resolution the user already recorded in `state.jsonc` from a prior Phase 2b (rename, omission, or custom classification). Applied first so the bootstrap loop converges instead of re-asking.
1. **FK reachability**, a live FK on the domain's own entities whose `reference_table` resolves to an entity carrying `catalog_entity_code = X`. Reseating is universal, so this catches silo, same-name share, and reuse/merge whenever `X` still has a consumer in the domain.
2. **Owned canonical code**, `catalog_entity_code = X` AND the entity's module is in the domain slice. Catches masters the domain owns and its own silos (`table_name` is the `X`-rename).
3. **Alias**, an entity whose `catalog_entity_aliases` contains `{ alias_code: X, source_domain: LMS }` (JSONB containment; resolve on the **pair**, never `alias_code` alone). Catches a reuse/merge that renamed `X` onto a differently-named host.
4. **Absent**, none of the above. If the domain OWNS `X` it is a true omission (`omitted_entities`); if `X` is only referenced (embedded master / consumer owned by another domain) it is external context (`external_entities`), not an omission.

The provenance columns and their **empty** values (core v0.1.2 stores NOT NULL with an empty default, so test against the empty value, **never `IS NULL`**):

| Column (table) | Empty | Empty means |
|---|---|---|
| `catalog_entity_code` (`entities`) | `''` | outside the deploy pipeline (hand-built / pre-provenance) |
| `catalog_owner_module` (`entities`) | `''` | this module owns it, or local |
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
- Per-master aliases, lifecycle states, and the per-entity `has_personal_content` hint
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
- `modules`, per `module_id` in the slice: `module_slug`, `module_name`, `catalog_module_code`, and the deploy `settings` (`domain_code`, `module_kind`, `naming_mode`). UI deep-links are built by `use-semantius` from `ui_baseurl` (returned by `getCurrentUser`, captured into `discovered.json`'s `deployment` block at bootstrap) plus the DEPLOYED `module_slug` + `table_name` from `discovered.json` (e.g. `hiring-starter`, never the catalog code). Resolve the real values; never emit `{ui_baseurl}`/`{table_name}` placeholders to the user.
- `entities`, per live table: identity and provenance (`catalog_entity_code`, `catalog_owner_module`, `entity_type`, `catalog_entity_aliases`); the operational shape: `id_column`, `label_column`, `label_parent`, `description`, `view_permission`, `edit_permission`; governance: `edit_mode`, `is_child`, `audit_log`, `cube_mode`, `managed`, `searchable`, `updated_at`; and `fields`. Each field carries `name`, `title`, `description`, `catalog_field_code`, `format`, `ctype`, `cube_type`, `is_pk`, `is_nullable`, `unique_value`, `searchable`, `precision`, `field_order`, `input_type`, `input_type_rule`, `default_value`, `reference_table`, `reference_delete_mode`, `relationship_label`, `singular_label_parent`/`plural_label_parent`, and `enum_values`, plus the entity's `lifecycle_field`/`lifecycle_values`.
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

Everything in the runbook (the `use-semantius`/Bun checks, `ready.flag`, bootstrap, the provenance ladder, `discovered.json`/`state.jsonc`/`learnings.jsonc`, module IDs, version numbers) is internal plumbing the user must NEVER see narrated. Run it silently. Do not announce file reads, "bootstrapping", "provenance-stamped", "discovery resolved", "module 1033", Bun versions, "on-invocation checks", or "6 of 8 entities, let me read the rest". If discovery has to run and will take a beat, say at most one plain line, e.g. *"One moment, taking stock of how your platform is set up..."*, then deliver the answer. The user asked a question; show them the answer, not the build log.

- Good: *"One moment, checking your setup... Your platform runs the Hiring Starter package, a slim recruiting pipeline. Here is what you can do."*
- Bad: *"There is no `ready.flag` or `discovered.json` yet, so I will run bootstrap. Bun 1.3.12 is present. Bootstrap succeeded with zero deferred questions; the deployment is fully provenance-stamped. Let me read `discovered.json`..."*

### Lead with what they can DO, then what they have

When the user asks an open question ("what can I do?", "status", "help", "what is this?", "get started"), lead jobs-first from `discovered.json`: the workflows this deployment supports, then the entities behind them, in human labels. It is discovery-gated and never answered from the frontmatter (except the pre-setup fallback). Full procedure and report shape: [references/status-report.md](./references/status-report.md).

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
- [Status and usage report](./references/status-report.md)
- [Learnings format](./references/learnings-format.md)
- [Skill changelog](./references/skill-changelog.md)
