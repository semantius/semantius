# Status and usage report

The handler for a capability or usage question, matched by intent and not exact words: any open ask about what this can do or where to start ("what can I do here?", "show me an overview", "status", "give me the rundown", "what is this", "get started", and the like). SKILL.md keeps only the one-line trigger that routes here; this file holds the whole procedure. Built entirely from `discovered.json`, never the frontmatter description (except the pre-setup fallback in step 3). Read-only; run it silently.

## Procedure

1. **Run the gate first** (SKILL.md Runbook step 4). A capability question is discovery-gated: do not answer it ahead of the gate. If the discovery is not current, bootstrap runs now, and this is where the install / connect check fires; handle it per SKILL.md "Bootstrap exit handling" before producing any report.

2. **Once the discovery is current, report jobs-first from `discovered.json`** (the three tiers below). Lead with what the user can DO, then the entities behind it. Human labels only, never raw table names; frame optional or absent pieces as available to enable.

3. **Pre-setup fallback ONLY.** If the platform genuinely cannot be reached after you have offered to connect (install the CLI / set `.env`), give the generic capabilities from the frontmatter description plus the connect offer, and say plainly it is the as-designed overview, not this deployment's actual shape. This is the only time the frontmatter answers a capability question.

## The three tiers

The first tier alone answers most asks; tiers 2 and 3 add live numbers only when the user wants them.

1. **What you can do, per deployed entity (static, no live query).**
   For each entity in `discovered.json` (the resolved slice, post-rename, minus `omitted_entities` / `external_entities`):
   - the `singular_label` / `plural_label` and `description` (labels, never the raw `table_name`),
   - the operations available, from the spec tool set plus `view_permission` / `edit_permission`,
   - the lifecycle, from `lifecycle_field` / `lifecycle_values`.

   This is the headline answer and needs no platform call.

2. **How much is there (optional, live).**
   A per-entity `count(*)`, and for entities that have a lifecycle a group-by count over `lifecycle_values`. Counts are role-scoped by `select_rule`, so present them as "what you can see", not an absolute total. Delegate the count call to `use-semantius`.

3. **Domain rollups (optional, live).**
   The numbers this domain exists to surface (for example, records approaching a date threshold), as a count-with-filter on the relevant deployed entity. Keep to entities actually present.

## Framing

- Use human labels throughout; raw table/field names belong only in an explicitly technical block.
- Frame `omitted_entities` / `external_entities` as available to enable, not missing.
- Keep the machinery invisible: no file names, module IDs, version numbers, or bootstrap narration.

These mirror the rules in SKILL.md ("Use the human labels", "Frame what is not deployed as available", "Keep the machinery invisible").
