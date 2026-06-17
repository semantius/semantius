# Earned-knowledge memory (`learnings.jsonc`)

The skill keeps knowledge it had to **earn** (work out, or be told) so it is not re-derived every
session. It is NOT a drift detector and NOT a schema cache; those are already handled (see
Boundaries). `learnings.jsonc` REPLACES the old `lessons.md` + `improvements.md` surfaces;
`state.jsonc` (structural resolutions) and `discovered.json` (current schema) are unchanged.

The skill reads this file each session (it is small) and applies it before solving a non-trivial
operation or after a failure.

## Boundaries (why this store is small and specific)

| Concern | Already handled by | This store's job |
|---|---|---|
| "A call failed" (detection) | `semantius` CLI exit codes (4 = schema/RLS/validation, 5 = auth, 3 = transient) | nothing, detection is free |
| "The schema changed" (drift) | re-run discovery, `discovered.json` refreshes | nothing, re-discover, don't learn |
| "What the schema IS" (fields, FKs, enums, guards) | `discovered.json` (incl. behavioral columns) | nothing, already captured |
| **"What the schema does NOT tell us"** | nobody | **everything below** |

So this store holds only knowledge the CLI and re-discovery cannot give you.

## What it holds

| Kind | Captures | Answers |
|---|---|---|
| `error_fix` | a call that failed in a non-obvious way, plus the working form found | keep hints about errors faced |
| `user_input` | a correction, confirmation, or rule the user supplied that is not in the schema | user provided feedback / helped |
| `recipe` | a validated multi-step or multi-table operation/query (e.g. a 3-table cube join for a metric) | joining over 3 tables; a solution already found once |
| `quirk` | a deployment-specific fact the schema cannot express (e.g. this deployment leaves `source_id` null and tracks source on the candidate) | deployment reality vs as-designed |

## The point: do not re-derive

Every entry is `trigger` (the situation it matches) + `resolution` (what to do). Before solving a
non-trivial operation, or after a failure, the agent checks the store by `trigger`; on a hit it
applies the known resolution instead of re-deriving it. That is how a solution found once is not
found again.

Persistence is the guaranteed win. Application is agent-side matching (this is "knowing how", not a
deterministic platform read), but the knowledge survives the session either way, which the old
markdown logs only did as prose.

## Entry shape

`learnings.jsonc` is JSONC (JSON plus `//` and `/* */` comments and trailing commas), parsed with
Bun's built-in `Bun.JSONC.parse`, same as `state.jsonc`. It is a single top-level array of entries.
Created on first write; absent means empty.

```jsonc
[
  {
    "id": "recipe-2026-06-15-001",
    "kind": "recipe",                  // error_fix | user_input | recipe | quirk
    "trigger": "metric: average time-to-hire by recruitment source",
    "resolution": "cube: dimension RecruitmentSources.source_name; measure = avg days between job_applications.applied_on and the hired transition; join path applications -> candidates -> recruitment_sources; filter status=hired",
    "evidence": "ran 2026-06-15, returned 7 sources, numbers confirmed by the user",
    "source": "agent",                 // agent | user
    "confidence": 1,
    "status": "active",                // proposed | active | obsolete
    "first_seen": "2026-06-15",
    "last_seen": "2026-06-15"
  }
]
```

## Trust & decay

- `user_input` -> `active` immediately (the user is the authority).
- `recipe` -> `active` only after it actually ran and returned the expected result (validated, not
  guessed).
- `error_fix` / `quirk` -> `active` when user-approved or reconfirmed; otherwise `proposed`.
- Re-encountered -> `confidence++`, bump `last_seen` (no duplicate entry).
- Contradicted later -> `status: obsolete` + reason; kept for audit, never deleted.

## Drift (the small leftover)

On an exit-4 error whose message is schema-shaped ("column/relation does not exist"),
`discovered.json` is probably stale: re-run discovery, retry once, else surface and stop (per
`use-semantius`: do not silently adapt). Record an entry ONLY if there is a non-schema lesson in it;
a plain rename is fixed by re-discovery, not remembered here.

## Recall & apply

- Read `learnings.jsonc` each session (it is small).
- Before a non-trivial op, or after a failure: match by `trigger`; apply `active` resolutions;
  surface `proposed` ones for one-tap confirmation.
- When a learning is genuinely universal (every deployment would hit it), the human can choose to
  upstream it via the catalog's contribution channel. The skill does NOT auto-publish.
- Significant procedural learnings that future maintainers must understand also warrant a
  [skill-changelog.md](skill-changelog.md) entry (the audit trail); the changelog records
  "we decided", `learnings.jsonc` records "we learned / were told".
