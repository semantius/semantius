---
name: product-roadmap
description: >-
  Use this skill for anything involving the Product Roadmap, the in-house
  domain that tracks features (new ideas, enhancements, change requests, bugs,
  tech debt) from intake through RICE scoring, objective alignment, release
  scheduling, and ship. Trigger when the user says: "capture a new feature
  request", "score this feature with RICE", "rescore the dark mode feature",
  "triage the under-review backlog", "schedule feature X into v2.5", "ship the
  March 2026 release", "vote for the dark mode feature", "tag this as mobile",
  "comment on this feature", "what's the top-voted feature this quarter",
  "what's our planned spend by cost center", "show pipeline by status". Loads
  alongside `use-semantius`, which owns CLI install, PostgREST encoding, and
  cube query mechanics.
semantic_model: product_roadmap
---

# Product Roadmap

This skill carries the domain map and the jobs-to-be-done for the
Product Roadmap. Platform mechanics, CLI install, env vars, PostgREST
URL-encoding, `sqlToRest`, cube `discover`/`validate`/`load`, and
schema-management tools, live in `use-semantius`. Assume it loads
alongside; do not re-explain CLI basics here.

If a task is purely about defining schema, managing permissions, or
running ad-hoc queries against tables you already know, call
`use-semantius` directly, going through this skill adds nothing.

**Auto-managed fields** (set by Semantius on every table; never
include in POST/PATCH bodies): `id`, `created_at`, `updated_at`. The
three caller-populated junction and sub-entity label columns
(`feature_vote_label`, `comment_label`, `feature_tag_label`) are
**not** auto-managed: they are required on insert and must appear in
every POST body. Composition rules live in each affected JTBD.

For bulk CSV / Excel import of features, votes, or tags, see
`use-semantius` `references/webhook-import.md`; this skill does not
script imports.

---

## Domain glossary

The roadmap funnel runs **Feature intake → RICE scoring → Triage →
Release scheduling → Ship**, with `Objectives` as the strategic frame
features roll up to, `Cost centers` as the funding bucket, and
`Votes` / `Tags` / `Comments` as stakeholder signals around each
feature.

| Concept | Table | Notes |
|---|---|---|
| Objective | `objectives` | Strategic goal or theme features roll up to (e.g. "Reduce churn by 10%") |
| Feature | `features` | The central roadmap entity: idea, enhancement, change request, bug, or tech debt; carries `estimated_cost` and `actual_cost` (numeric, scale 2) plus the four RICE inputs feeding the stored `rice_score` |
| Release | `releases` | A planned release with target and actual ship dates; features schedule into one |
| Cost Center | `cost_centers` | Funding bucket a feature is charged to; supports cost roll-up vs `annual_budget` |
| User | `users` | PMs, owners, requesters, voters (deduped against the Semantius built-in `users`) |
| Feature Vote | `feature_votes` | Junction, weighted user vote on a feature; caller composes `feature_vote_label` |
| Comment | `comments` | Discussion message on a feature; caller composes `comment_label` |
| Tag | `tags` | Reusable category label (e.g. `mobile`, `enterprise`); `tag_name` unique |
| Feature Tag | `feature_tags` | Junction linking features to tags; caller composes `feature_tag_label` |

**Commitment rule.** A feature is **committed** when
`feature_status` is one of `planned`, `in_progress`, `shipped`. The
flag is derived, there is no separate boolean. `release_id` should
agree: a committed feature has a `release_id` set, and a
non-committed feature does not.

**Feature stored fields with computed value.** `features.rice_score`
is `numeric` with scale 4 and is computed as
`(reach_score * impact_score * confidence_score) / effort_score`. It
must be recomputed in the same call as any RICE input change; see
the *Score a feature with RICE* JTBD for the rule.

## Key enums

Only the enums that gate JTBDs are listed; full sets live in the
semantic model. Arrows mark the typical lifecycle path; `|` separates
terminal-ish states.

- `features.feature_status`: `new` → `under_review` → `planned` → `in_progress` → `shipped` | `declined` | `parked` (committed iff status ∈ {`planned`, `in_progress`, `shipped`})
- `features.feature_type`: `new_feature`, `enhancement`, `change_request`, `bug`, `tech_debt`
- `features.feature_priority`: `critical`, `high`, `medium`, `low`
- `features.feature_source`: `unspecified`, `customer`, `support`, `sales`, `internal`, `partner`
- `releases.release_status`: `planned` → `in_progress` → `released` | `cancelled`
- `objectives.objective_status`: `proposed` → `active` → `achieved` | `missed` | `cancelled`

## Foreign-key cheatsheet

Only the FKs that JTBDs cross. Format: `child.field → parent.id`
(delete behavior in parens).

- `features.objective_id → objectives.id` (clear)
- `features.release_id → releases.id` (clear; null until scheduled)
- `features.cost_center_id → cost_centers.id` (clear)
- `features.requester_id → users.id` (clear)
- `features.owner_id → users.id` (clear)
- `objectives.objective_owner_id → users.id` (clear)
- `cost_centers.cost_center_owner_id → users.id` (clear)
- `feature_votes.feature_id → features.id` (parent, cascade)
- `feature_votes.user_id → users.id` (parent, cascade)
- `comments.feature_id → features.id` (parent, cascade)
- `comments.author_id → users.id` (set null; orphaned comments survive a deleted user)
- `feature_tags.feature_id → features.id` (parent, cascade)
- `feature_tags.tag_id → tags.id` (parent, cascade)

**Unique columns** (409 on duplicate POST): `users.user_email`,
`releases.release_name`, `tags.tag_name`,
`cost_centers.cost_center_code`.

**No DB-level uniqueness on the natural junction keys.** Neither
`feature_votes(feature_id, user_id)` nor `feature_tags(feature_id,
tag_id)` is constrained. Recipes that would create one must read
first.

**Audit-logged tables** (Semantius writes the audit rows
automatically; recipes do not manage them): `objectives`, `features`,
`releases`, `cost_centers`.

## Lookup convention

Semantius adds a `search_vector` column to searchable entities for
full-text search across all text fields. Use it whenever the user
passes a name, title, or description, not a UUID:

```bash
semantius call crud postgrestRequest '{"method":"GET","path":"/<table>?search_vector=wfts(simple).<term>&select=id,<label_column>"}'
```

Use `wfts(simple).<term>` for fuzzy text searches; never `ilike` and
never `fts`, they bypass the search index and mismatch the platform
convention. `<column>=eq.<value>` is the right tool for known-exact
values (UUIDs, FK ids, status enums, unique columns like `tag_name`,
`release_name`, `cost_center_code`, `user_email`). If a fuzzy lookup
returns more than one row, present the candidates and ask. If zero,
ask the user to clarify rather than guessing.

## Timestamps in recipe bodies

Every `*_at` field, `*_date` field, or other moment-of-action value
in a recipe body (`submitted_at`, `voted_at`, `posted_at`,
`actual_release_date`, `target_start_date`, `target_completion_date`)
is a placeholder the calling agent fills at call time, not a literal
copied from the example. The recipes use `<current ISO timestamp>`
and `<today's date, YYYY-MM-DD>`; do not copy those strings into a
real call. This applies in SKILL.md, in every reference file, in
the Common queries appendix, and in any script.

---

## Jobs to be done

### Capture a new feature (intake)

**Triggers:** `capture a new feature request`, `add this idea to the
backlog`, `log a bug as a feature`, `create a change request`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `feature_title` | yes | label_column; what the user typed as the idea |
| `feature_type` | yes | One of `new_feature`, `enhancement`, `change_request`, `bug`, `tech_debt` |
| `feature_status` | no | Defaults to `new`; must NOT be `planned`/`in_progress`/`shipped` here, those route to the schedule JTBD |
| `feature_priority` | no | Default `medium` |
| `feature_source` | no | `customer`, `support`, `sales`, `internal`, `partner`, `unspecified` |
| `requester_id` | no | Resolve via `user_email=eq.<email>` |
| `owner_id` | no | The PM owning the feature; resolve by email |
| `objective_id` | no | Resolve by `objective_name` via `wfts(simple)` |
| `cost_center_id` | no | Resolve by `cost_center_code=eq.<code>` (unique) |
| `submitted_at` | no | Set to the current ISO timestamp at intake |
| RICE inputs (`reach_score`, `impact_score`, `confidence_score`, `effort_score`) | no | If any are passed, recipe recomputes `rice_score` |

**Recipe:** see [`references/capture-feature.md`](references/capture-feature.md).

**Validation:** new row exists with the resolved FKs; `feature_status`
matches what the caller asked for (default `new`); if any RICE input
was passed and `effort_score` is non-zero, `rice_score` equals
`(reach * impact * confidence) / effort` rounded to 4 decimals.

**Failure modes:**
- Caller asks for `feature_status=planned` at intake → refuse and
  route to the *Schedule a feature into a release* JTBD.
- `objective_id` resolves to a `cancelled`/`missed` objective, or
  `cost_center_status=inactive` → ask the user before proceeding.

---

### Score a feature with RICE (recompute)

**Triggers:** `score this feature with RICE`, `update the RICE
score`, `rescore X`, `set reach to 5000`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `feature_id` | yes | Resolve by `feature_title` via `wfts(simple)` |
| Any of `reach_score`, `impact_score`, `confidence_score`, `effort_score` | yes | At least one must be provided |

**Recipe:** run `scripts/score-rice.sh <feature_id> [reach=<n>] [impact=<n>] [confidence=<n>] [effort=<n>]`.
The script reads current scores, overlays the caller's deltas,
recomputes `rice_score` rounded to 4 decimals (or null if effort is
null/zero), and PATCHes everything in one call. Exit 0 on success,
1 on bad inputs / feature not found, 2 on platform error.

**Validation:** all four RICE inputs on the row reflect the merged
values; `rice_score` equals `(reach * impact * confidence) / effort`
with the post-PATCH inputs rounded to 4 decimals; OR `rice_score`
is null and `effort_score` is null/zero.

**Failure modes:**
- `effort_score` is null or zero after the PATCH → division
  undefined; PATCH `rice_score` to null, do not write a placeholder.
- Score field PATCHed without `rice_score` recomputed → silent
  corruption; recover by reading the row, recomputing, and
  re-PATCHing.

---

### Triage a feature (move to under_review / declined / parked)

**Triggers:** `triage the backlog`, `move X to under review`,
`decline this feature`, `park this idea for next quarter`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `feature_id` | yes | Resolve by `feature_title` via `wfts(simple)` |
| Target `feature_status` | yes | One of `under_review`, `declined`, `parked`, `new` (promotion to `planned` is the schedule JTBD, not this one) |

**Recipe:** see [`references/triage-feature.md`](references/triage-feature.md).

**Validation:** `feature_status` matches the target; for `declined`
or `parked`, `release_id` is null (a non-committed feature with a
release_id breaks release-content reports).

**Failure modes:**
- Caller asks to promote to `planned` here → refuse and route to the
  schedule JTBD.
- Source status is `shipped` → refuse; reopening a shipped feature
  is a model-level decision, not a triage step.

---

### Schedule a feature into a release

**Triggers:** `schedule X into v2.5`, `add this feature to the March
2026 release`, `commit the dark mode work to v3.0`, `move this off
the v2.5 release`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `feature_id` | yes | Resolve by `feature_title` via `wfts(simple)` |
| `release_id` | yes for scheduling, null for unscheduling | Resolve by `release_name=eq.<name>` (unique) |
| `target_start_date`, `target_completion_date` | no | Set if the user named them |

**Recipe:** see [`references/schedule-feature.md`](references/schedule-feature.md).

**Validation:** if `release_id` is set, `feature_status ∈ {planned,
in_progress, shipped}`; if `release_id` is null, `feature_status ∈
{new, under_review, declined, parked}`; the release the feature
points at is not `released` or `cancelled`.

**Failure modes:**
- Resolved release has `release_status` in `(released, cancelled)`
  → refuse; ask the user to pick a different release.
- `feature_status=planned` written without `release_id` set in the
  same call → silent commitment-rule break; recover by PATCH-ing
  `release_id` or reverting the status.

---

### Ship a release

**Triggers:** `ship the March 2026 release`, `release v2.5`,
`mark v3.0 as released`, `the release went out yesterday`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `release_id` | yes | Resolve by `release_name=eq.<name>` (unique) |
| `actual_release_date` | yes | The date it actually shipped (YYYY-MM-DD) |
| `release_notes` | no | HTML string published with the release |

**Recipe:** run `scripts/ship-release.sh <release_id> <actual_release_date> [release_notes_html]`.
The script PATCHes the release, sweeps `planned`/`in_progress`
features on the release to `shipped`, and verifies no committed
features remain. Exit 0 on success, 1 on bad inputs / already
released, 2 on platform error (rerun is a deterministic no-op for
already-shipped rows).

**Validation:** the release row shows `release_status=released` and
non-null `actual_release_date`; every feature on the release is in
`{shipped, declined, parked}`; none remain at `planned` or
`in_progress`. Features at `new` / `under_review` on a shipped
release are surfaced as a data-quality warning, not swept.

**Failure modes:**
- Release is already `released` or `cancelled` → script exits 1;
  do not re-ship, the original `actual_release_date` stands.
- Step 2 (release PATCH) succeeded but step 3 (sweep) failed →
  script exits 2 naming the failed step. Rerun the script; the
  feature filter is `feature_status in (planned, in_progress)`, so
  already-shipped rows are not re-touched.

---

### Vote on a feature

**Triggers:** `vote for the dark mode feature`, `record Alice's vote
on X`, `Alex wants this feature too`, `bump the weight on this vote`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `feature_id` | yes | Resolve by `feature_title` via `wfts(simple)` |
| `user_id` | yes | Resolve by `user_email=eq.<email>` (unique) |
| `vote_weight` | no | Default 1; higher = stronger signal |
| `voted_at` | no | Set to the current ISO timestamp at vote time |

**Recipe:** run `scripts/cast-vote.sh <feature_id> <user_id> [vote_weight]`.
The script reads both parents to compose
`feature_vote_label = "<user_full_name> -> <feature_title>"`, dedupes
on the `(feature_id, user_id)` pair, PATCHes if the row exists or
POSTs otherwise, and refreshes `voted_at` to the current timestamp.
Exit 0 on success, 1 on bad inputs / parents not found, 2 on platform
error.

**Validation:** exactly one row exists for the
`(feature_id, user_id)` pair; `feature_vote_label` matches the
`"<user_full_name> -> <feature_title>"` composition.

**Failure modes:**
- POST without the read-first dedupe → duplicate row, vote count
  inflates; recover by deleting duplicates by `voted_at`.
- User not in `users` yet → create via `use-semantius`, do not
  invent a fake id.

---

### Tag a feature

**Triggers:** `tag this as mobile`, `add the enterprise tag to X`,
`categorize this feature as platform`, `untag this`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `feature_id` | yes | Resolve by `feature_title` via `wfts(simple)` |
| `tag_id` | yes | Resolve by `tag_name=eq.<name>` (unique). If absent, ask before creating one |

**Recipe:** see [`references/tag-feature.md`](references/tag-feature.md).

**Validation:** add: exactly one `feature_tags` row for the pair,
`feature_tag_label` matches `"<feature_title> / <tag_name>"`; remove:
zero rows match the pair.

**Failure modes:**
- Tag named by the user does not exist → ask before creating; do
  not auto-create (taxonomy fragmentation: `mobile`, `Mobile`,
  `mobile-app` co-existing).
- POST without the read-first dedupe → duplicate row; recover by
  deleting the extra.

---

### Comment on a feature

**Triggers:** `comment on this feature`, `add a note to X`, `reply
to the discussion on the dark mode feature`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `feature_id` | yes | Resolve by `feature_title` via `wfts(simple)` |
| `author_id` | yes on insert | Resolve by `user_email=eq.<email>`; storage is nullable so a deleted user's comments survive, but the caller must always pass it |
| `comment_body` | yes | The full text the user wrote |
| `posted_at` | no | Set to the current ISO timestamp at post time |

**Recipe:** run `scripts/post-comment.sh <feature_id> <author_id> <comment_body>`.
The script verifies both parents exist, composes `comment_label`
deterministically (verbatim if body is at most 80 chars; otherwise
the first 80 chars cut at the last whitespace position when one
exists, with the U+2026 ellipsis appended), and POSTs the row with
`posted_at` set to the current timestamp. NOT idempotent: every run
POSTs a new row. Exit 0 on success, 1 on bad inputs / parents not
found, 2 on platform error.

**Validation:** new row exists; if body ≤80 chars, `comment_label`
equals `comment_body`; otherwise `comment_label` ends with `…`
(U+2026) and the prefix is at most 80 chars cut at a word boundary
when one exists; `posted_at` non-null.

**Failure modes:**
- `comment_label` set to the full body when body > 80 chars → list
  views break; PATCH `comment_label` per the composition rule.
- `author_id` omitted on POST → required-on-insert; resolve user
  first.

---

## Common queries

These are starting points, not contracts. Cube schema names drift
when the model is regenerated, so always run `cube discover '{}'`
first and map the dimension and measure names below against
`discover`'s output. The cube name is usually the entity's table
name with the first letter capitalized (e.g. `Features`), but
verify.

```bash
# Always first
semantius call cube discover '{}'
```

```bash
# RICE-ranked backlog: top features by rice_score, only non-terminal statuses
semantius call cube load '{"query":{
  "measures":["Features.count"],
  "dimensions":["Features.feature_title","Features.feature_status","Features.rice_score","Features.feature_priority"],
  "filters":[{"member":"Features.feature_status","operator":"equals","values":["new","under_review","planned"]}],
  "order":{"Features.rice_score":"desc"},
  "limit":50
}}'
```

```bash
# Pipeline counts by feature_status
semantius call cube load '{"query":{
  "measures":["Features.count"],
  "dimensions":["Features.feature_status"],
  "order":{"Features.count":"desc"}
}}'
```

```bash
# Cost rollup: estimated and actual cost by cost center, vs annual_budget
semantius call cube load '{"query":{
  "measures":["Features.sum_estimated_cost","Features.sum_actual_cost"],
  "dimensions":["CostCenters.cost_center_code","CostCenters.cost_center_name","CostCenters.annual_budget"],
  "order":{"Features.sum_estimated_cost":"desc"}
}}'
```

```bash
# Top-voted features (sum of vote_weight per feature)
semantius call cube load '{"query":{
  "measures":["FeatureVotes.sum_vote_weight","FeatureVotes.count"],
  "dimensions":["Features.feature_title","Features.feature_status"],
  "order":{"FeatureVotes.sum_vote_weight":"desc"},
  "limit":20
}}'
```

```bash
# Release contents and ship dates: features grouped by release, last 12 months
semantius call cube load '{"query":{
  "measures":["Features.count"],
  "dimensions":["Releases.release_name","Releases.release_status"],
  "timeDimensions":[{"dimension":"Releases.actual_release_date","granularity":"month","dateRange":"last 12 months"}],
  "order":{"Releases.actual_release_date":"desc"}
}}'
```

---

## Guardrails

- Never PATCH `features.feature_status` to `planned` without setting
  `release_id` in the same call; the commitment rule (committed iff
  status ∈ {planned, in_progress, shipped} and release_id is set)
  must hold.
- Never PATCH any of `features.{reach_score, impact_score,
  confidence_score, effort_score}` without recomputing
  `rice_score = (reach * impact * confidence) / effort` rounded to
  4 decimals in the same call; if `effort_score` ends up null or
  zero, set `rice_score` to null rather than writing a placeholder.
- Never PATCH `releases.release_status=released` without setting
  `actual_release_date` in the same call, and always sweep the
  release's `planned`/`in_progress` features to `shipped` in the
  same operation; the `scripts/ship-release.sh` script does this
  atomically.
- Never POST to `feature_votes` for a `(feature_id, user_id)` pair
  that already exists; PATCH the existing row's `vote_weight`
  instead.
- Never POST to `feature_tags` for a `(feature_id, tag_id)` pair
  that already exists; the row is the link, there is nothing to
  update on it.
- Never auto-create tags from a casual user mention; ask first.
  `tag_name` is unique, but the taxonomy fragments
  (`mobile-app` / `mobile` / `Mobile`) if every typo becomes a new
  tag.
- Never schedule a feature into a release whose `release_status` is
  `released` or `cancelled`.
- Lookups for human-friendly identifiers (titles, names,
  descriptions) use `search_vector=wfts(simple).<term>`; never
  `ilike` and never `fts`.
- `users` may already exist as a Semantius built-in in this
  deployment; treat it as the authoritative table and reference it
  rather than creating a parallel one.

## What this skill does NOT do

- Schema changes, use `use-semantius` directly.
- RBAC / permissions, use `use-semantius` directly.
- One-off seed data, write a script, do not bake it into a JTBD.
- Bulk import of features / votes / tags from CSV or Excel; see
  `use-semantius` `references/webhook-import.md`.
- Splitting a feature across multiple releases (no
  `feature_releases` junction with phase metadata exists yet).
- RICE history: only the current scores live on the feature; no
  separate `estimates` entity captures who scored what when.
- Cost history: only current `estimated_cost` and `actual_cost`
  live on the feature; no `cost_estimates` entity timestamps the
  values.
- Multi-currency cost tracking: no `currency_code` field on
  features or cost centers.
- Splitting a feature across multiple cost centers; no
  `feature_cost_allocations` junction exists.
- Period-scoped cost-center budgets: only a single `annual_budget`
  field, not a `cost_center_budgets` per fiscal period.
- Linking features to specific customers / accounts; no
  `customer_requests` entity exists.
- Feature dependencies (predecessor / successor); no
  `feature_dependencies` self-junction exists.
- Promoting `feature_source` from an enum to its own table; sources
  carry no metadata beyond the enum value.
- Attachments (mockups, specs, screenshots) on features; no
  `attachments` entity exists.
- Release capacity (team capacity vs. allocated effort); no
  capacity fields on `releases`.
- A strategic tier above `objectives` (e.g. `initiatives`) for
  multi-objective programs.
- Multi-product roadmaps; this model is single-product (no
  `products` entity above objectives, features, and releases).
