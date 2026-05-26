---
name: product-roadmap
description: >-
  Use this skill for anything involving Product Roadmap, the in-house domain
  that plans features from intake through RICE scoring, objective alignment,
  release scheduling, stakeholder voting, and ship. Trigger when the user wants
  to start a feature, ship a feature into a release, schedule or detach a
  feature against a release, cast a weighted vote on a feature, tag a feature,
  release a release through its workflow gate, delete a tag with feature-link
  cleanup, or report on the roadmap (RICE-ranked backlog, release scorecard,
  top voted features, throughput, tag distribution).
semantic_model: product_roadmap
---

# Product Roadmap

This skill carries the domain map and the jobs-to-be-done for Product Roadmap.
Platform mechanics, CLI install, env vars, PostgREST URL-encoding, `sqlToRest`,
cube `discover`/`validate`/`load`, and schema-management tools, live in
`use-semantius`. Assume it loads alongside; do not re-explain CLI basics here.

If a task is purely about defining schema, managing permissions, or running
ad-hoc queries against tables you already know, call `use-semantius` directly,
going through this skill adds nothing.

**Module type**: `domain`.

**Auto-managed fields** (set by Semantius on every table; never include in
POST/PATCH bodies): `id`, `created_at`, `updated_at`. The `label_column` field
is **required on insert and caller-populated** on every entity unless the model
explicitly marks it as `computed` (the platform writes it). In this model the
junctions and the comment thread (`feature_votes.feature_vote_label`,
`feature_tags.feature_tag_label`, `feature_comments.feature_comment_label`) and
the score column `features.rice_score` are all platform-computed (see
"Platform-derived fields" below); every other entity's label column
(`objectives.objective_name`, `features.feature_title`, `users.display_name`,
`releases.release_name`, `tags.tag_name`) is required on insert and must be
included in POST bodies.

**Platform-derived fields** (set by the platform's per-entity `computed_fields`
triggers on every INSERT/UPDATE; never include in POST/PATCH bodies, the
platform overwrites caller payloads):

- `features.rice_score`: (reach × impact × confidence) / effort, null when
  effort is missing or zero.
- `feature_votes.feature_vote_label`: composed at write time from the voter's
  display name and the feature's title via nested cross-entity lookups.
- `feature_comments.feature_comment_label`: first 80 characters of the comment
  body, for list display.
- `feature_tags.feature_tag_label`: composed at write time from the feature's
  title and the tag's name via nested cross-entity lookups.

**Platform-enforced invariants** (entity-level `validation_rules` triggered on
every INSERT/UPDATE; the platform rejects writes that violate them with
`{ "errors": [{ "code", "message" }, ...] }`. The recipes here do NOT
pre-validate these; they surface the platform's error to the user verbatim if
the write fails):

- `objectives` rule `objective_terminal_is_one_way`: "Once an objective is
  achieved, missed, or cancelled, its status cannot change." Why: achieved /
  missed / cancelled record the outcome of a strategic period; reopening a
  closed objective is a data-integrity bug, not a workflow.
- `features` rule `release_only_when_committed`: "A release can only be
  assigned once the feature is planned, in_progress, or shipped." Why:
  commitment is derived from Status; Release is only meaningful once committed.
- `features` rule `release_required_when_shipped`: "A shipped feature must
  reference the release it shipped in." Why: paired with the previous rule, a
  shipped feature shipped in some release.
- `features` rule `feature_shipped_is_one_way`: "Once a feature is shipped, its
  status cannot change." Why: shipped is the terminal outcome state; declined
  and parked are deliberately left reversible.
- `features` rule `features_locked_when_release_is_released`: "Cannot modify a
  feature attached to a released release." Why: a released release is the
  immutable historical record of what shipped, so its feature roster is frozen.
  Blocks attaching a new feature to a released release on insert; blocks any
  edit (including detachment) on a feature whose prior release was already in
  the released state.
- `features` rule `target_dates_ordered`: "Target start date must be on or
  before target completion date." Why: when both are set, completion cannot
  precede start.
- `features` rule `actual_dates_ordered`: "Actual start date must be on or
  before actual completion date." Why: when both are set, completion cannot
  precede start.
- `features` rule `actual_start_only_when_in_progress_or_later`: "Actual start
  date can only be set once the feature is in progress or shipped." Why: actual
  start has no domain meaning before work begins.
- `features` rule `actual_start_required_when_shipped`: "A shipped feature must
  record its actual start date." Why: at shipped, start date is the historical
  record of when work began.
- `features` rule `actual_completion_only_when_shipped`: "Actual completion
  date can only be set once the feature is shipped." Why: actual completion has
  no domain meaning before the terminal state.
- `features` rule `actual_completion_required_when_shipped`: "A shipped feature
  must record its actual completion date." Why: at shipped, completion date is
  the historical record of when the feature shipped.
- `features` rule `reach_score_non_negative`: "Reach must be zero or greater."
- `features` rule `impact_score_non_negative`: "Impact must be zero or
  greater."
- `features` rule `confidence_score_in_range`: "Confidence must be between 0
  and 100." Why: confidence is documented as a percentage on the field.
- `features` rule `effort_score_non_negative`: "Effort must be zero or
  greater." Why: zero is permitted (`rice_score` returns null rather than
  dividing by zero).
- `releases` rule `actual_date_only_when_released`: "Actual release date can
  only be set once the release status is released." Why: actual date is null
  until the release reaches its terminal state.
- `releases` rule `released_requires_actual_date`: "A released release must
  record its actual release date." Why: paired with the previous rule.
- `releases` rule `release_released_is_one_way`: "Once a release is released,
  its status cannot change." Why: un-releasing breaks the historical record of
  what shipped when. `cancelled` is deliberately left reversible.
- `feature_votes` rule `vote_weight_positive`: "Vote weight must be at least
  1." Why: zero or negative weight has no domain meaning.
- `feature_votes` rule `feature_votes_blocked_on_terminal_feature`: "Votes are
  not accepted on shipped or declined features." Why: once a feature reaches
  shipped or declined, the planning signal is moot. Applies to both inserts
  and weight updates. Parked features remain votable so revival signal still
  works.
- `feature_comments` rule `author_required_on_insert`: "Author must be set when
  a comment is created." Why: author is required on insert but nullable in
  storage so comments survive when their author is deleted; the check fires
  only on insert.
- `feature_comments` rule `feature_comments_no_new_on_shipped`: "New comments
  are not accepted on shipped features." Why: insert-only gate; existing
  comments can still be edited for typo fixes.

**Platform-enforced permissions** (rules whose JsonLogic invokes
`{"require_permission": "<code>"}`; the platform throws when the caller lacks
the named permission, surfacing the rule's `code` and `message` as a validation
failure. The recipes that hit these gates name the permission up-front so the
calling agent can either confirm the caller holds it before attempting the
write, or propose handing off to a user who holds it instead of hitting the
throw blind):

- `releases` rule `release_requires_release_permission` requires
  `product_roadmap:release_release` (release managers, product leads): "Only
  release managers may set a release's status to released." Why: transitioning
  a release to its terminal released state is a workflow gate that runs in
  addition to the one-way-terminal rule that locks it after the fact.
  `product_roadmap:release_release` is rolled up into `product_roadmap:admin`,
  so admins hold it implicitly.

**Restrict-cleanup chains** (inbound `reference + restrict` FKs that block
deletion of the target entity until children are explicitly cleaned up first.
The calling agent attempting to delete a listed entity must walk the named
children first, in the order given, or the platform will reject the DELETE
with a foreign-key constraint error):

- Deleting `tags` requires cleaning up first: `feature_tags` (via `tag_id`).
  See the `delete-tag` JTBD for the recipe.

**Conditional field UI states** (per-field UI mode overrides set via
`input_type_rule`. The platform evaluates the rule client-side at form-render
time and overrides the field's static `input_type` for the current record. The
rule does NOT gate writes; recipes that POST/PATCH bypass the form entirely.
Two patterns matter for recipe shape: when a rule flips a field's effective
mode to `required` on a sibling-field transition, the transition's recipe must
set that field in the same PATCH; when a rule flips to `readonly` after a
terminal state, recipes that update the entity after that state should not
write the field):

- `objectives.objective_status`: readonly once status is `achieved`, `missed`,
  or `cancelled` (paired server-side rule: `objective_terminal_is_one_way`).
- `features.feature_status`: readonly once status is `shipped` (paired:
  `feature_shipped_is_one_way`).
- `features.release_id`: required when status is `shipped` (paired:
  `release_required_when_shipped`).
- `features.actual_start_date`: hidden until status is `in_progress`, required
  at `shipped` (paired: `actual_start_only_when_in_progress_or_later`,
  `actual_start_required_when_shipped`).
- `features.actual_completion_date`: hidden until status is `shipped`, required
  at `shipped` (paired: `actual_completion_only_when_shipped`,
  `actual_completion_required_when_shipped`).
- `releases.release_status`: readonly once status is `released` (paired:
  `release_released_is_one_way`).
- `releases.actual_release_date`: hidden until status is `released`, required
  at `released` (paired: `actual_date_only_when_released`,
  `released_requires_actual_date`).

---

## Domain glossary

| Concept | Table | Notes |
|---|---|---|
| Objective | `objectives` | Strategic goal or theme that features roll up to |
| Feature | `features` | Central roadmap entity (idea, enhancement, change request, bug, tech debt). Carries RICE inputs and a target release once committed. |
| User | `users` | Shared with the platform's user catalog; PMs, owners, requesters, voters |
| Release | `releases` | Planned release with target and actual ship dates |
| Feature Vote | `feature_votes` | Junction, a user's vote on a feature with a tunable weight |
| Feature Comment | `feature_comments` | Discussion message posted on a feature |
| Tag | `tags` | Reusable label for categorizing features; tag catalog is admin-edited |
| Feature Tag | `feature_tags` | Junction, links a feature to a tag |

## Key enums

- `features.feature_status`: `new` → `under_review` → `planned` → `in_progress`
  → `shipped` | `declined` | `parked`. `shipped` is terminal (one-way). A
  feature is "committed" once it reaches `planned`, `in_progress`, or
  `shipped`; the Release link is only meaningful from that point.
- `releases.release_status`: `planned` → `in_progress` → `released` |
  `cancelled`. `released` is terminal (one-way) and gated by the
  `product_roadmap:release_release` permission.
- `objectives.objective_status`: `proposed` → `active` → `achieved` | `missed`
  | `cancelled`. `achieved` / `missed` / `cancelled` are terminal (one-way).
- `features.feature_type`: `new_feature`, `enhancement`, `change_request`,
  `bug`, `tech_debt`. Informational only; lifecycle is the same for every type.
- `features.feature_priority`: `critical`, `high`, `medium`, `low`.
- `features.feature_source`: `unspecified`, `customer`, `support`, `sales`,
  `internal`, `partner`.

## When the runtime disagrees with the recipe

The FK shape and audit-logging facts in each JTBD's reference file are baked in
at skill-generation time. The live schema can drift, admins can add a unique
index, drop an FK, or toggle audit-logging on a table without regenerating this
skill. The recipes are not self-correcting on their own, but the agent has an
escape hatch.

When a recipe gets a `409 Conflict`, `422 Unprocessable Entity`, or any other
write failure the JTBD's reference file did not predict, the recovery move is
**read the live schema, then decide**:

```bash
semantius call crud read_field '{"filters": "table_name=eq.<table>"}'
semantius call crud read_field '{"filters": "table_name=eq.<table>,field_name=eq.<col>"}'
```

If the live shape contradicts the recipe's assumption (for example a unique
constraint exists where the recipe expected a free-form junction), abort with
a clear stderr message naming the drift, do not silently "fix it up" with
extra writes. Then surface to the user that the skill is out of date and
recommend regenerating via `semantius-skill-maker`. Drift recovery is the
user's call, not the agent's.

## Lookup convention

Semantius adds a `search_vector` column to searchable entities for full-text
search across all text fields. Use it whenever the user passes a name, title,
email, or description, not a UUID:

```bash
semantius call crud postgrestRequest '{"method":"GET","path":"/<table>?search_vector=wfts(simple).<term>&select=id,<label_column>"}'
```

Use `wfts(simple).<term>` for fuzzy text searches; never `ilike` and never
`fts`, they bypass the search index and mismatch the platform convention.

Field-equality (`<column>=eq.<value>`) is the right tool for a *different* job:
filtering on a known-exact value. Use it for UUIDs, FK ids, status enums, and
unique columns whose values the caller already knows verbatim. In this domain
`releases.release_name`, `tags.tag_name`, and `users.email` are unique and
should be resolved with `=eq.<value>`; feature titles are non-unique and should
be resolved with `wfts(simple).<term>`.

If a lookup returns more than one row, present the candidates and ask. If
zero, ask the user to clarify rather than guessing.

## Timestamps in recipe bodies

Every `*_at` field, `*_date` field, or other moment-of-action value in a recipe
body is a placeholder the calling agent fills at call time, not a literal
copied from the example. The Recipe templates use `<current ISO timestamp>` and
`<today's date, YYYY-MM-DD>`; do not copy those strings into a real call. This
applies in SKILL.md, in every reference file, in the Common queries appendix,
and in any script the calling agent invokes.

---

## Jobs to be done

### Start a feature (planned → in_progress)

**Triggers:** `start feature X`, `move X to in progress`, `begin work on X`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `feature_title` | yes | resolved by `search_vector=wfts(simple).<term>` (titles are non-unique) |
| `actual_start_date` | no | defaults to today's date if omitted |

**Recipe:** run `scripts/start-feature.sh <feature-title> [YYYY-MM-DD]`. The
agent invokes; do not paste the script body here. Exit `0` on success, `1` on
unresolved/ambiguous feature or wrong source status, `2` on platform error.

**Validation:** after the call, the feature's `feature_status` is
`in_progress` and `actual_start_date` is set to the requested date.

**Failure modes:**

- Feature status is `new`, `under_review`, `declined`, `parked`, or
  `shipped` → script refuses with exit 1; the user should triage the feature
  to `planned` first (or revive it from `parked`).
- Platform throws `actual_dates_ordered` → the supplied `actual_start_date`
  is after an already-set `actual_completion_date`; that combination is
  impossible in `in_progress` since completion is only set at `shipped`, so
  this signals corrupted historical data; surface to the user.

---

### Ship a feature (X → shipped)

**Triggers:** `ship feature X in release Y`, `mark X as shipped`, `X shipped
in release Y`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `feature_title` | yes | resolved by `search_vector=wfts(simple).<term>` |
| `release_name` | yes | resolved by `release_name=eq.<value>` (unique). The release must be in `planned` or `in_progress` status. |
| `actual_completion_date` | no | defaults to today's date if omitted |

**Recipe:** run `scripts/ship-feature.sh <feature-title> <release-name>
[YYYY-MM-DD]`. The script reads the feature and the target release in parallel,
refuses if the release is `released` or `cancelled`, computes
`actual_start_date` (keeping any existing value, falling back to the completion
date), and PATCHes status, release, and both actual dates in a single call.
Exit `0` on success, `1` on lookup or precondition failure, `2` on platform
error.

**Validation:** after the call, the feature's `feature_status` is `shipped`,
`release_id` matches the resolved release, and both `actual_start_date` and
`actual_completion_date` are set with `actual_start_date <=
actual_completion_date`.

**Failure modes:**

- Target release is `released` → platform throws
  `features_locked_when_release_is_released`. Pick a different release or wait
  for the next one to open. The script refuses up-front rather than relying on
  the platform's throw.
- Feature was previously attached to a `released` release → same rule fires
  on the modification side. The feature's history is frozen and cannot be
  re-shipped; this should be a new feature record.
- Platform throws `release_only_when_committed` → unreachable from this
  recipe (status moves to `shipped` in the same PATCH); if seen, the platform
  has rejected the combined write for a different reason, surface verbatim.

---

### Schedule a feature into a release (or detach it)

**Triggers:** `schedule X for release Y`, `move X into Y`, `detach X from its
release`, `remove the release from X`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `feature_title` | yes | resolved by `search_vector=wfts(simple).<term>`. Status must be `planned` or `in_progress` (committed but not yet shipped). |
| `release_name` | yes | resolved by `release_name=eq.<value>`. Pass `--detach` instead to clear `release_id`. The release must be in `planned` or `in_progress`. |

**Recipe:** run `scripts/schedule-feature.sh <feature-title>
<release-name|--detach>`. The script reads the feature, refuses if its status
is not `planned` or `in_progress`, optionally reads the target release and
refuses if it is `released` or `cancelled`, then PATCHes `release_id`. Exit
`0` on success, `1` on lookup or precondition failure, `2` on platform error.

**Validation:** for an attach, the feature's `release_id` matches the resolved
release; for a detach, `release_id` is null. The feature's status is unchanged.

**Failure modes:**

- Feature is `shipped` → platform throws
  `features_locked_when_release_is_released`. Scheduling decisions on shipped
  features are not reversible; this should be a new feature.
- Feature is `new` or `under_review` → platform throws
  `release_only_when_committed`. Triage to `planned` first.
- Target release is `released` → platform throws
  `features_locked_when_release_is_released`. Pick a different release.

---

### Vote on a feature

**Triggers:** `vote for X`, `cast a vote on X for user Y`, `change my vote
weight on X`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `user_email` | yes | resolved by `email=eq.<value>` (unique) |
| `feature_title` | yes | resolved by `search_vector=wfts(simple).<term>` |
| `vote_weight` | no | integer >= 1; defaults to 1 |

**Recipe:** run `scripts/cast-vote.sh <user-email> <feature-title> [weight]`.
The `(feature_id, user_id)` junction has no DB-level uniqueness, so the script
reads first and either inserts a new vote or PATCHes the existing row's
`vote_weight` and `voted_at`. The `feature_vote_label` is platform-computed,
never include it in the body. Exit `0` on success, `1` on unresolved /
ambiguous lookup, `2` on platform error.

**Validation:** after the call, exactly one `feature_votes` row exists with the
matching `(feature_id, user_id)`, the requested `vote_weight`, and a
`voted_at` of the call time.

**Failure modes:**

- Feature status is `shipped` or `declined` → platform throws
  `feature_votes_blocked_on_terminal_feature`. Votes are not accepted on
  features whose planning decision is already made.
- `vote_weight` < 1 → platform throws `vote_weight_positive`. Surface the
  range to the user and retry.
- Two `feature_votes` rows already exist for the pair (historical duplicate
  from before this skill) → the script PATCHes the first; flag to the user
  and clean up the second by id.

---

### Tag a feature

**Triggers:** `tag X as Y`, `add the Y label to X`, `categorize X under Y`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `feature_title` | yes | resolved by `search_vector=wfts(simple).<term>` |
| `tag_name` | yes | resolved by `tag_name=eq.<value>` (unique). The tag must already exist; new tags are admin-edited. |

**Recipe:** run `scripts/tag-feature.sh <feature-title> <tag-name>`. The
`(feature_id, tag_id)` junction has no DB-level uniqueness, so the script
reads first and no-ops if the link already exists. The `feature_tag_label` is
platform-computed, never include it in the body. Exit `0` on success (insert
or no-op), `1` on unresolved lookup, `2` on platform error.

**Validation:** after the call, exactly one `feature_tags` row exists with the
matching `(feature_id, tag_id)`.

**Failure modes:**

- Tag does not exist → script refuses with exit 1. New tags require
  `product_roadmap:admin` and are not part of this recipe; ask an
  administrator to add the tag first.

---

### Release a release

**Triggers:** `release the X release`, `mark release X as released`, `ship
release X`

**Inputs:** `release_name`, optional `actual_release_date` (defaults to
today's date).

**Recipe:** see [`references/release-release.md`](references/release-release.md).

**Validation:** after the call, the release's `release_status` is `released`,
`actual_release_date` is set, and every attached feature is now frozen against
further edits (verify by reading one of the attached features and confirming
the platform refuses a subsequent PATCH with `code:
features_locked_when_release_is_released`).

**Failure modes:**

- Caller lacks `product_roadmap:release_release` → platform throws with
  `code: release_requires_release_permission` and `message: "Only release
  managers may set a release's status to released."` Hand off to a user who
  holds the permission (release managers or `product_roadmap:admin` holders).
- Release status is `cancelled` → platform throws
  `release_released_is_one_way` if you attempt to flip from `cancelled` to
  `released` (the one-way rule treats every terminal-to-terminal write as a
  change). A cancelled release should not be released; create a new release
  instead.

---

### Delete a tag (with cleanup)

**Triggers:** `delete the X tag`, `remove the X tag`, `retire the X label`

**Inputs:** `tag_name`.

**Recipe:** see [`references/delete-tag.md`](references/delete-tag.md).

**Validation:** after the cleanup, the `tags` row is gone and no `feature_tags`
rows reference the deleted `tag_id`.

**Failure modes:**

- Active `feature_tags` rows reference the tag → the platform refuses the
  parent delete with a foreign-key constraint error from the `tag_id`
  `restrict` rule. The recipe walks the chain first and confirms with the
  user before cascading.
- Caller lacks `product_roadmap:admin` → the tag catalog is admin-edited;
  the platform rejects the DELETE. Hand off to an administrator.

---

## Common queries

Always run `cube discover '{}'` first to refresh the schema. Match the
dimension and measure names below against what `discover` returns, field
names drift when the model is regenerated, and `discover` is the source of
truth at query time.

```bash
# RICE-ranked backlog: top 20 uncommitted features by rice_score
semantius call cube load '{"query":{
  "measures":["features.count"],
  "dimensions":["features.id","features.feature_title","features.feature_status","features.rice_score","features.feature_priority"],
  "filters":[{"member":"features.feature_status","operator":"equals","values":["new","under_review","planned"]},
             {"member":"features.rice_score","operator":"set"}],
  "order":{"features.rice_score":"desc"},
  "limit":20
}}'
```

```bash
# Release scorecard: planned vs. shipped feature counts per release
semantius call cube load '{"query":{
  "measures":["features.count"],
  "dimensions":["releases.release_name","releases.release_status","features.feature_status"],
  "order":{"releases.release_name":"asc"}
}}'
```

```bash
# Top voted features: sum of vote_weight per feature
semantius call cube load '{"query":{
  "measures":["feature_votes.sum_vote_weight","feature_votes.count"],
  "dimensions":["features.feature_title","features.feature_status"],
  "order":{"feature_votes.sum_vote_weight":"desc"},
  "limit":20
}}'
```

```bash
# Throughput: shipped feature count by actual_completion_date month
semantius call cube load '{"query":{
  "measures":["features.count"],
  "timeDimensions":[{"dimension":"features.actual_completion_date","granularity":"month"}],
  "filters":[{"member":"features.feature_status","operator":"equals","values":["shipped"]}],
  "order":{"features.actual_completion_date":"asc"}
}}'
```

```bash
# Tag distribution: feature count per tag
semantius call cube load '{"query":{
  "measures":["feature_tags.count"],
  "dimensions":["tags.tag_name"],
  "order":{"feature_tags.count":"desc"}
}}'
```

---

## Guardrails

- Never include `rice_score`, `feature_vote_label`, `feature_comment_label`,
  or `feature_tag_label` in any POST or PATCH body, the platform writes them
  on every INSERT/UPDATE and overwrites caller payloads.
- Never split a feature's terminal `shipped` write across two PATCHes: status,
  `release_id`, `actual_start_date`, and `actual_completion_date` go in one
  call. The intermediate state after only flipping status would fail multiple
  platform rules at once.
- Never attempt to flip a `shipped` feature, an `achieved`/`missed`/
  `cancelled` objective, or a `released` release back to an earlier state.
  These terminal states are one-way; the right action is a new record.
- Never attach or modify a feature whose `release_id` points to a `released`
  release. The historical record is frozen.
- Vote and tag junction inserts must read-first to dedupe, neither junction
  has DB-level uniqueness.
- Deleting a tag requires clearing its `feature_tags` rows first, the
  `tag_id` FK is `restrict` and the platform will reject the parent DELETE.

## What this skill does NOT do

- Schema changes, use `use-semantius` directly.
- RBAC / permissions, use `use-semantius` directly.
- One-off seed data, write a script, do not bake it into a JTBD.
- Bulk feature ingest from CSV, see `use-semantius`
  `references/webhook-import.md`.
- Unique-per-user vote enforcement at the DB level (currently caller-side
  dedup).
- Unique-per-feature tag-link enforcement at the DB level (currently
  caller-side dedup).
- A dedicated "ship feature" permission distinct from `product_roadmap:manage`.
- Author-only edit/delete on comments with a manager override.
- Feature-level cost data (use the Budgeting sibling domain via §6
  cross-model rows).
- One-way terminal `declined` or `parked` feature statuses; both remain
  reversible by design.
- One-way terminal `cancelled` releases; cancellation remains reversible.
- Cross-feature gating on objective status (filing a new feature under a
  `missed` or `cancelled` objective is allowed for retrospective analysis).
- Cross-feature gating on tag changes after a feature is shipped.
- Splitting a feature across multiple releases via a phased junction.
- RICE estimate history as a separate entity (current values live on the
  feature row).
- Customer-requests M:N junction beyond the simple `requester_id` FK.
- Structured time-periods entity for `objective_period` (currently freeform).
- Feature dependencies on other features.
- Feature source as its own entity (currently an enum).
- First-class attachments (mockups, specs, screenshots) entity.
- Release capacity data for load planning.
- A strategic tier above objectives (e.g. initiatives).
- Multi-product support (a re-introduced products entity owning objectives,
  features, and releases).
