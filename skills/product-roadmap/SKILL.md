---
name: product-roadmap
description: >-
  Use this skill for anything involving the Product Roadmap, the
  in-house domain that captures features, scores them with RICE,
  rolls them up to objectives, and schedules committed work into
  releases, plus stakeholder votes, comments, and tags. Trigger
  when the user wants to schedule a feature into a release, start
  work on a feature, ship a feature, cast a vote on behalf of a
  user, tag a feature, post a comment, or pull pipeline /
  RICE / throughput reports.
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

**Auto-managed fields** (set by Semantius on every table; never include
in POST/PATCH bodies): `id`, `created_at`, `updated_at`. The
`label_column` field is **required on insert and caller-populated** on
every entity unless the model explicitly says it is auto-derived. For
this domain that means `feature_vote_label` on `feature_votes`,
`feature_tag_label` on `feature_tags`, and `comment_label` on
`comments` are all required on POST and the recipe must compose the
value (see each JTBD for the composition rule). Do not omit `*_label`
from POST bodies.

**Platform-derived fields** (set by the platform's per-entity
`computed_fields` triggers on every INSERT/UPDATE; never include in
POST/PATCH bodies, the platform overwrites caller payloads):

- `features.rice_score`: (reach × impact × confidence) / effort, null
  when effort is missing or 0.

**Platform-enforced invariants** (entity-level `validation_rules`
triggered on every INSERT/UPDATE; the platform rejects writes that
violate them with `{ "errors": [{ "code", "message" }, ...] }`. The
recipes here do NOT pre-validate these; they surface the platform's
error to the user verbatim if the write fails):

- `objectives` rule `objective_terminal_is_one_way`: Once an objective
  is achieved, missed, or cancelled, its status cannot change. Why:
  achieved / missed / cancelled record the outcome of a strategic
  period; reopening a closed objective is a data-integrity bug.
- `features` rule `release_only_when_committed`: A release can only be
  assigned once the feature is planned, in_progress, or shipped. Why:
  release_id is only meaningful once the feature is committed.
- `features` rule `release_required_when_shipped`: A shipped feature
  must reference the release it shipped in.
- `features` rule `feature_shipped_is_one_way`: Once a feature is
  shipped, its status cannot change. Why: shipped is the terminal
  outcome; reopening should be a new feature record.
- `features` rule `target_dates_ordered`: Target start date must be
  on or before target completion date.
- `features` rule `actual_dates_ordered`: Actual start date must be
  on or before actual completion date.
- `features` rule `actual_start_only_when_in_progress_or_later`:
  Actual start date can only be set once the feature is in_progress
  or shipped.
- `features` rule `actual_completion_only_when_shipped`: Actual
  completion date can only be set once the feature is shipped.
- `features` rule `actual_completion_required_when_shipped`: A
  shipped feature must record its actual completion date.
- `features` rule `reach_score_non_negative`: Reach must be zero or
  greater.
- `features` rule `impact_score_non_negative`: Impact must be zero
  or greater.
- `features` rule `confidence_score_in_range`: Confidence must be
  between 0 and 100.
- `features` rule `effort_score_positive`: Effort must be greater
  than zero. Why: 0 has no domain meaning and breaks the RICE
  divisor.
- `releases` rule `actual_date_only_when_released`: Actual release
  date can only be set once the release status is released.
- `releases` rule `released_requires_actual_date`: A released release
  must record its actual release date.
- `releases` rule `release_released_is_one_way`: Once a release is
  released, its status cannot change.
- `feature_votes` rule `vote_weight_positive`: Vote weight must be
  at least 1.
- `comments` rule `author_required_on_insert`: Author must be set
  when a comment is created. Why: author is required on insert but
  storage is nullable so a deleted user's comments survive as
  orphaned records.

---

## Domain glossary

| Concept | Table | Notes |
|---|---|---|
| Objective | `objectives` | Strategic goal or theme features roll up to |
| Feature | `features` | Central entity, anything on the roadmap (idea, enhancement, change request, bug, tech debt). Carries RICE scores, status, target / actual dates, optional release |
| User | `users` | PMs, owners, requesters, voters, stakeholders. Reused from the Semantius built-in `users` table |
| Release | `releases` | Planned release with target / actual ship dates |
| Feature Vote | `feature_votes` | Junction: a user's vote on a feature. M:N with optional weight |
| Comment | `comments` | Discussion message posted on a feature |
| Tag | `tags` | Reusable label for categorizing features |
| Feature Tag | `feature_tags` | Junction: feature ↔ tag M:N |

## Key enums

- `features.feature_status`: `new` → `under_review` → `planned` → `in_progress` → `shipped`. Sidetracks: `declined`, `parked` (both reversible). `shipped` is terminal one-way. Commitment is derived: status ∈ {planned, in_progress, shipped} ⇒ committed.
- `features.feature_type`: `new_feature`, `enhancement`, `change_request`, `bug`, `tech_debt`.
- `features.feature_priority`: `critical`, `high`, `medium`, `low`.
- `features.feature_source`: `unspecified`, `customer`, `support`, `sales`, `internal`, `partner`.
- `releases.release_status`: `planned` → `in_progress` → `released`. Sidetrack: `cancelled` (reversible). `released` is terminal one-way.
- `objectives.objective_status`: `proposed` → `active` → `achieved` | `missed` | `cancelled`. The three terminal values are one-way.

## When the runtime disagrees with the recipe

The FK shape and audit-logging facts in each JTBD's reference file
are baked in at skill-generation time. The live schema can drift,
admins can add a unique index, drop an FK, or toggle audit-logging
on a table without regenerating this skill. The recipes are not
self-correcting on their own, but the agent has an escape hatch.

When a recipe gets a `409 Conflict`, `422 Unprocessable Entity`, or
any other write failure the JTBD's reference file did not predict,
the recovery move is **read the live schema, then decide**:

```bash
# What FKs does this entity actually have right now?
semantius call crud read_field '{"filters": "entity=eq.<entity_id>"}'

# Or, more targeted, what does field <name> reference today?
semantius call crud read_field '{"filters": "entity=eq.<entity_id>,name=eq.<field_name>"}'
```

If the live shape contradicts the recipe's assumption, abort with a
clear stderr message naming the drift; do not silently "fix it up"
with extra writes. Then surface to the user that the skill is out of
date and recommend regenerating via `semantius-skill-maker`. Drift
recovery is the user's call, not the agent's.

## Lookup convention

Semantius adds a `search_vector` column to searchable entities for
full-text search across all text fields. Use it whenever the user
passes a name, title, email, or description, not a UUID:

```bash
semantius call crud postgrestRequest '{"method":"GET","path":"/<table>?search_vector=wfts(simple).<term>&select=id,<label_column>"}'
```

Use `wfts(simple).<term>` for fuzzy text searches; never `ilike` and
never `fts`, they bypass the search index and mismatch the platform
convention.

Field-equality (`<column>=eq.<value>`) is the right tool for a
*different* job: filtering on a known-exact value. Use it for UUIDs,
FK ids, status enums, and unique columns whose values the caller
already knows verbatim (e.g. `tag_name`, `user_email`,
`release_name`). The two patterns are not in competition:
`wfts(simple)` resolves a fuzzy human input to a row; `eq` selects
rows whose column exactly equals a known value.

If a lookup returns more than one row, present the candidates and
ask. If zero, ask the user to clarify rather than guessing.

## Timestamps in recipe bodies

Every `*_at` field, `*_date` field, or other moment-of-action value
in a recipe body is a placeholder the calling agent fills at call
time, not a literal copied from the example. The Recipe templates
use `<current ISO timestamp>` and `<today's date, YYYY-MM-DD>`; do
not copy those strings into a real call. This applies in SKILL.md,
in every reference file, in the Common queries appendix, and in any
script the calling agent invokes.

---

## Jobs to be done

### Schedule a feature into a release

**Triggers:** `schedule feature X for release Y`, `commit X to release Y`, `plan feature X`, `add feature X to the v2.5 release`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `feature_title` | yes | Resolve via `search_vector=wfts(simple).<term>` against `/features` |
| `release_name` | optional | Resolve via `release_name=eq.<name>` against `/releases` (column is unique). Omit if scheduling status only without committing to a release |
| `target_start_date` | optional | YYYY-MM-DD |
| `target_completion_date` | optional | YYYY-MM-DD; if both target dates are set, must be >= target_start_date |

**Recipe:** run `scripts/schedule-feature.sh <feature-title> [<release-name>] [<target-start-YYYY-MM-DD>] [<target-completion-YYYY-MM-DD>]`. The agent invokes; do not paste the script body here. Exit `0` on success, `1` on bad args / unresolved title or release / release in terminal state, `2` on platform error.

**Validation:** read the feature back; `feature_status` is `planned`, `release_id` matches the resolved release id (or null if no release was passed), target dates match what the caller passed.

**Failure modes:**

- Platform code `feature_shipped_is_one_way` → the feature is already shipped. Recovery: tell the user; if a follow-up is needed, capture it as a new feature.
- Release is `released` or `cancelled` → script refuses before writing; tell the user to pick a non-terminal release or omit `release_name` to schedule status only.
- Platform code `target_dates_ordered` → the caller passed a target completion that precedes target start. Recovery: ask the user for corrected dates.

---

### Start work on a feature

**Triggers:** `start work on X`, `mark feature X in progress`, `move X to in_progress`, `kick off X`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `feature_title` | yes | Resolve via `search_vector=wfts(simple).<term>` against `/features` |
| `actual_start_date` | optional | YYYY-MM-DD; defaults to today if omitted |

**Recipe:** run `scripts/start-feature.sh <feature-title> [<actual-start-YYYY-MM-DD>]`. Exit `0` on success, `1` on bad args / unresolved title / feature not in `planned` (the only state from which work can start cleanly), `2` on platform error.

**Validation:** read back; `feature_status` is `in_progress`, `actual_start_date` matches the date passed (or today).

**Failure modes:**

- Feature in `under_review` or `new` → script refuses; tell the user to schedule it first (Schedule a feature).
- Feature already `shipped` → `feature_shipped_is_one_way` rejects.
- `actual_start_only_when_in_progress_or_later` rejects → script writes status and date in one PATCH; if this fires, the platform is stricter than the recipe expects, surface verbatim.

---

### Ship a feature

**Triggers:** `ship feature X`, `mark X shipped`, `complete X`, `X is done`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `feature_title` | yes | Resolve via `search_vector=wfts(simple).<term>` against `/features` |
| `release_name` | yes (if not already set) | Resolve via `release_name=eq.<name>`. Required because shipped features must reference a release; if the feature already has `release_id` set, this can be omitted |
| `actual_completion_date` | optional | YYYY-MM-DD; defaults to today if omitted |

**Recipe:** run `scripts/ship-feature.sh <feature-title> [<release-name>] [<actual-completion-YYYY-MM-DD>]`. Exit `0` on success, `1` on bad args / unresolved title or release / feature not in `in_progress`, `2` on platform error.

**Validation:** read back; `feature_status` is `shipped`, `release_id` is set, `actual_completion_date` matches.

**Failure modes:**

- Feature in `planned` (no work started) → script refuses; tell the user to start work first.
- Platform code `release_required_when_shipped` → no release on the feature and none was supplied. Recovery: re-run with `<release-name>`.
- Platform code `actual_dates_ordered` → completion date precedes the recorded `actual_start_date`. Recovery: ask the user for a corrected completion date.

---

### Cast a vote on a feature

**Triggers:** `vote for X`, `record a vote on X for user Y`, `add weighted vote (3) for X for user Y`, `upvote X`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `feature_title` | yes | Resolve via `search_vector=wfts(simple).<term>` against `/features` |
| `user_email` | yes | Resolve via `user_email=eq.<email>` against `/users` (column is unique) |
| `vote_weight` | optional | Integer >= 1; defaults to 1 |

**Recipe:** run `scripts/cast-vote.sh <feature-title> <user-email> [<weight>]`. The script reads the parents, dedupes against the (`feature_id`, `user_id`) pair, and either INSERTs a new vote or PATCHes the weight on the existing one. Exit `0` on success, `1` on bad args / unresolved title or email / pre-existing duplicate junction rows, `2` on platform error.

**Validation:** read back the matching `feature_votes` row by `(feature_id, user_id)`; weight matches and `feature_vote_label` is `"<user_full_name> -> <feature_title>"`.

**Failure modes:**

- Two `feature_votes` rows already exist for the same `(feature_id, user_id)` (data corruption from before this skill was used) → script aborts and tells the user to clean up the duplicates manually before retrying. The dedupe path assumes at most one prior row.
- Platform code `vote_weight_positive` → caller passed weight < 1. Recovery: re-run with weight >= 1.
- User is `inactive` → not blocked by the platform but worth surfacing; script proceeds and prints a warning to stderr.

---

### Tag a feature

**Triggers:** `tag X with mobile`, `add tag enterprise to feature X`, `apply tag platform to X`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `feature_title` | yes | Resolve via `search_vector=wfts(simple).<term>` against `/features` |
| `tag_name` | yes | Looked up via `tag_name=eq.<name>` against `/tags` (column is unique). If absent, this JTBD asks the user before creating the tag |

**Recipe:** see [`references/tag-feature.md`](references/tag-feature.md). Tagging has a user-confirmation branch (creating a missing tag) so it lives as a reference, not a script.

**Validation:** read the matching `feature_tags` row by `(feature_id, tag_id)`; `feature_tag_label` is `"<feature_title> / <tag_name>"`.

**Failure modes:**

- The `(feature_id, tag_id)` junction row already exists → recipe is a no-op; report "already tagged" rather than re-inserting.
- `tag_name` not found and the user declines to create it → recipe aborts cleanly; do not silently fall through.

---

### Post a comment on a feature

**Triggers:** `comment on X saying ...`, `post comment on feature X for user Y`, `add note to X`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `feature_title` | yes | Resolve via `search_vector=wfts(simple).<term>` against `/features` |
| `user_email` | yes | Resolve via `user_email=eq.<email>`. `author_required_on_insert` rejects an INSERT with no author |
| `comment_body` | yes | Free text; the script composes `comment_label` from the first 80 chars deterministically |

**Recipe:** run `scripts/post-comment.sh <feature-title> <user-email> <comment-body>`. Exit `0` on success, `1` on bad args / unresolved title or email / empty body, `2` on platform error.

**Validation:** read back the row by `id` (returned from POST); `comment_label` matches the deterministic cut rule from the script.

**Failure modes:**

- `author_required_on_insert` rejects → the email was not resolved and the script tried to POST anyway; should not fire because the script aborts on unresolved email, but if it does, surface verbatim.
- Body is empty after trimming → script refuses; the model requires `comment_body`.

---

## Common queries

Always run `cube discover '{}'` first to refresh the schema. Match
the dimension and measure names below against what `discover`
returns; field names drift when the model is regenerated, and
`discover` is the source of truth at query time.

```bash
# Roadmap pipeline: feature count by current status
semantius call cube load '{"query":{
  "measures":["features.count"],
  "dimensions":["features.feature_status"],
  "order":{"features.count":"desc"}
}}'
```

```bash
# Top RICE features still in flight (exclude shipped / declined / parked)
semantius call cube load '{"query":{
  "measures":["features.avg_rice_score"],
  "dimensions":["features.feature_title","features.feature_priority"],
  "filters":[
    {"member":"features.feature_status","operator":"notEquals","values":["shipped","declined","parked"]}
  ],
  "order":{"features.avg_rice_score":"desc"},
  "limit":20
}}'
```

```bash
# Release throughput: shipped feature count per release
semantius call cube load '{"query":{
  "measures":["features.count"],
  "dimensions":["releases.release_name","releases.actual_release_date"],
  "filters":[
    {"member":"features.feature_status","operator":"equals","values":["shipped"]}
  ],
  "order":{"releases.actual_release_date":"desc"}
}}'
```

```bash
# Top-voted features by total vote weight
semantius call cube load '{"query":{
  "measures":["feature_votes.sum_vote_weight","feature_votes.count"],
  "dimensions":["features.feature_title","features.feature_status"],
  "order":{"feature_votes.sum_vote_weight":"desc"},
  "limit":20
}}'
```

```bash
# Pipeline by objective: feature count grouped by objective and status
semantius call cube load '{"query":{
  "measures":["features.count"],
  "dimensions":["objectives.objective_name","features.feature_status"],
  "order":{"objectives.objective_name":"asc"}
}}'
```

---

## Guardrails

- Never PATCH `features.rice_score` directly; it is platform-derived. Write the inputs (`reach_score`, `impact_score`, `confidence_score`, `effort_score`) and let the trigger recompute.
- Never PATCH `features.feature_status` to `shipped` without `release_id` and `actual_completion_date` set in the same call; the platform rejects in two separate ways otherwise.
- Never PATCH a feature whose current `feature_status` is `shipped`; the platform refuses every write that changes status (one-way).
- Never PATCH `releases.release_status` to `released` without `actual_release_date` in the same call.
- Never PATCH an objective whose current `objective_status` is `achieved`, `missed`, or `cancelled`; one-way terminal.
- Never POST a `feature_votes`, `feature_tags`, or `comments` row without the caller-populated `*_label` field; defaults are empty strings, but the value carries the human-readable display.
- Junction inserts (`feature_votes`, `feature_tags`) have **no DB-level uniqueness** on the natural key pair; always read first and dedupe.
- `comments.author_id` is required on every INSERT (platform-enforced); resolve the user before POSTing.
- Built-in `users` table: this domain reuses Semantius's built-in `users`; do not create a duplicate `users` table.

## What this skill does NOT do

- Schema changes, use `use-semantius` directly.
- RBAC / permissions, use `use-semantius` directly.
- One-off seed data, write a script, don't bake it into a JTBD.
- Per-feature cost tracking; the model defers that to a Budgeting sibling domain.
- Making `declined` or `parked` one-way terminal states; only `shipped` is currently terminal.
- Cancelling releases as a one-way terminal record; `cancelled` is reversible by design.
- Splitting a feature across multiple releases (no `feature_releases` junction yet).
- Tracking RICE estimate history; scores live as fields on `features`, not as a separate `estimates` entity.
- Linking features to specific customer accounts beyond the cross-model FK hint; no `customer_requests` M:N junction.
- Promoting `objective_period` from a freeform string to a structured `time_periods` entity.
- Modeling feature dependencies (no `feature_dependencies` self-junction).
- Promoting `feature_source` from an enum to its own `feature_sources` entity.
- Modeling attachments (mockups, specs, screenshots) as a first-class `attachments` entity.
- Release-load planning with team capacity vs. allocated effort.
- A strategic tier above `objectives` (e.g. `initiatives`).
- Multi-product roadmaps (no `products` entity that owns objectives, features, and releases).
