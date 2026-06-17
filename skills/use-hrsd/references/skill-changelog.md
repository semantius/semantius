# Skill changelog

Per-skill audit trail. Append-only. Captures decisions, dated context, and the "why" behind notable changes, content that doesn't belong in `SKILL.md` (which stays lean and stable) but that a future agent or maintainer needs to understand the skill's evolution at this tenant.

Loaded on demand, not on every invocation. The skill reads this when context is needed to interpret older state or earned learnings, for example, when a `state.jsonc` entry references a decision made months ago, or when a recurring learning seems to contradict the procedure docs.

---

## When to append

- **`spec.json` was re-emitted with a major version bump**, record the migration, what changed, what tenant adaptations were preserved.
- **A discovery procedure was overridden by an earned learning**, record the why (the original problem) and link to the `learnings.jsonc` entry.
- **A tenant-specific decision was made that future runs must respect**, e.g. *"User confirmed on 2026-05-15 that the `vendors` entity in this tenant corresponds to `suppliers` in the spec, NOT the other way around. Reverse renames discussed and explicitly rejected."*
- **A category of error recurred and was resolved via a workaround**, note here so the rationale survives even if the specific entry rolls off `learnings.jsonc`.
- **A material change to the catalog DB (DomainMap-side) affected this skill**, e.g. an entity was renamed in the catalog and the local discovery state needed reconciling.
- **A field was deprecated or removed from `spec.json`** that the tenant was actively using, capture the migration path.

## When NOT to append

- Tactical fixes, validated recipes, deployment quirks, user corrections → `learnings.jsonc`
- Tenant-specific schema renames / omissions → `state.jsonc`
- Full discovered schema → `discovered.json`
- Routine successful discoveries, no need to log when everything just works.

The changelog is for narrative context that doesn't fit elsewhere. If a structured file already captures the fact, don't duplicate it here.

---

## Format

```markdown
## YYYY-MM-DD, Short title

**What:** what changed (a sentence or two)
**Why:** the reason it changed (the constraint, the past incident, the user decision)
**How to apply:** when this should shape the skill's behavior going forward (or "informational only" if it's a historical record with no ongoing effect)
```

Keep entries tight, 5-15 lines each. The changelog can grow long over time; aim for entries that earn their permanence.

---

## Sorting

Most recent first.

---

## Pruning

The changelog is append-only by default. However, entries that have been superseded by later entries can be marked obsolete with a strike-through + reason, the same convention as the `obsolete` status in `learnings.jsonc`:

```markdown
## ~~2026-03-10, Treat `applications` and `job_applications` as the same entity~~

Superseded 2026-05-20: tenant migrated to consistent `job_applications` naming during the v2 upgrade. Rename is no longer active in `state.jsonc`.
```

Strike-through preserves the history (a future maintainer can see the prior decision and when it was reversed) while making the current state legible.

---

## Relationship to the other files

| Surface | Scope | Cadence |
|---|---|---|
| `learnings.jsonc` | earned knowledge: error fixes, recipes, quirks, user input | as earned (frequent) |
| `skill-changelog.md` | narrative audit trail | when a decision or migration warrants it (rare) |
| `state.jsonc` | structured tenant deltas | every discovery run |
| `discovered.json` | structured tenant schema | every discovery run |

If a changelog entry is purely "this recurred and we found a workaround," the workaround belongs in `learnings.jsonc`. The changelog records "we decided," not "we learned."
