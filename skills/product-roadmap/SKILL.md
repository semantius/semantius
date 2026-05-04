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

**Auto-managed fields** (set by Semantius on every table; never include
in POST/PATCH bodies): `id`, `created_at`, `updated_at`. Every other
required field, including the three caller-populated junction and
sub-entity label columns (`feature_vote_label`, `comment_label`,
`feature_tag_label`), must appear in the POST body. The composition
convention for each is given in its JTBD below.

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
| Feature | `features` | The central roadmap entity: idea, enhancement, change request, bug, or tech debt |
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
agree: a committed feature should have a `release_id` set, and a
non-committed feature should not.

## Key enums

Only the enums that gate JTBDs are listed; full sets live in the
semantic model. Arrows mark the typical lifecycle path; `|` separates
terminal-ish states.

- `features.feature_status`: `new` → `under_review` → `planned` → `in_progress` → `shipped` | `declined` | `parked` (committed iff status ∈ {`planned`, `in_progress`, `shipped`})
- `features.feature_type`: `new_feature`, `enhancement`, `change_request`, `bug`, `tech_debt`
- `features.feature_priority`: `critical`, `high`, `medium`, `low`
- `features.feature_source`: `customer`, `support`, `sales`, `internal`, `partner`
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

**Audit-logged tables** (Semantius writes the audit rows automatically;
recipes do not manage them): `objectives`, `features`, `releases`,
`cost_centers`.

---

## Jobs to be done

### Capture a new feature (intake)

**Triggers:** `capture a new feature request`, `add this idea to the backlog`, `log a bug as a feature`, `create a change request`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `feature_title` | yes | label_column; what the user typed as the idea |
| `feature_type` | yes | One of `new_feature`, `enhancement`, `change_request`, `bug`, `tech_debt`; default `new_feature` |
| `feature_status` | no | Defaults to `new`; do not jump straight to `planned` here, that's the schedule JTBD |
| `feature_priority` | no | Default `medium` |
| `feature_source` | no | `customer`, `support`, `sales`, `internal`, `partner` |
| `requester_id` | no | Resolve via `user_email=eq.<email>` |
| `owner_id` | no | The PM owning the feature; resolve by email |
| `objective_id` | no | Resolve by `objective_name` via `wfts(simple)` |
| `cost_center_id` | no | Resolve by `cost_center_code=eq.<code>` (unique) |
| `submitted_at` | no | Set to the current ISO timestamp at intake |
| RICE inputs (`reach_score`, `impact_score`, `confidence_score`, `effort_score`) | no | If any are passed, see *RICE recompute* below |

**Lookup convention.** Semantius adds a `search_vector` column to
searchable entities for full-text search across all text fields. Use
it whenever the user passes a name, title, or description, not a UUID:

```bash
# Resolve an objective by anything the user typed
semantius call crud postgrestRequest '{"method":"GET","path":"/objectives?search_vector=wfts(simple).<term>&select=id,objective_name,objective_status"}'
```

Use `wfts(simple).<term>` for fuzzy text searches, never `ilike` and
never `fts`, they bypass the search index and mismatch the platform
convention. `eq.<value>` is the right tool for known-exact values
(UUIDs, FK ids, status enums, unique columns like `tag_name`,
`release_name`, `cost_center_code`, `user_email`).

**RICE recompute.** If the caller passes any of the four RICE inputs
at intake, compute `rice_score` in the same POST body using:

```
rice_score = (reach_score * impact_score * confidence_score) / effort_score
```

Skip the computation if `effort_score` is missing, null, or zero
(division would be undefined); leave `rice_score` null and tell the
user the score will compute once effort is set.

**Recipe:**

```bash
# 1. (Optional) resolve any human-friendly references the user named
semantius call crud postgrestRequest '{"method":"GET","path":"/users?user_email=eq.<email>&select=id,user_full_name"}'
semantius call crud postgrestRequest '{"method":"GET","path":"/cost_centers?cost_center_code=eq.<code>&select=id,cost_center_name"}'

# 2. Create the feature
semantius call crud postgrestRequest '{
  "method":"POST",
  "path":"/features",
  "body":{
    "feature_title":"<title>",
    "feature_type":"new_feature",
    "feature_status":"new",
    "feature_priority":"medium",
    "feature_source":"customer",
    "requester_id":"<optional>",
    "owner_id":"<optional>",
    "objective_id":"<optional>",
    "cost_center_id":"<optional>",
    "submitted_at":"<current ISO timestamp>",
    "reach_score":1000,
    "impact_score":1,
    "confidence_score":80,
    "effort_score":2,
    "rice_score":40000
  }
}'
```

`submitted_at`: set to the current ISO timestamp at call time; do not
copy the example value. The RICE numbers above are illustrative;
either pass real values from the user (and recompute `rice_score` per
the formula) or omit all five fields.

**Validation:** new row exists; `feature_status=new` (or whatever the
caller asked for); if any RICE input was passed, `rice_score` matches
the formula.

**Failure modes:**
- Caller asks to set `feature_status=planned` at intake → refuse and
  route to the *Schedule a feature into a release* JTBD; commitment
  needs `release_id` to agree.
- `objective_id` resolved to a `cancelled` or `missed` objective →
  ask the user; rolling new ideas into an abandoned objective is
  almost always a mistake.
- `cost_center_status=inactive` on the resolved cost center → ask;
  charging new work to an inactive bucket distorts the cost roll-up.

---

### Score a feature with RICE (recompute)

**Triggers:** `score this feature with RICE`, `update the RICE score`, `rescore X`, `set reach to 5000`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `feature_id` | yes | Resolve by `feature_title` via `wfts(simple)` |
| Any of `reach_score`, `impact_score`, `confidence_score`, `effort_score` | yes | At least one must be provided |

**This is a computed field.** `rice_score` is **stored**, not derived
on read; whenever any of the four inputs change, recompute and PATCH
`rice_score` in the **same** call:

```
rice_score = (reach_score * impact_score * confidence_score) / effort_score
```

Read the feature first to get the existing values, overlay the
caller's new ones, then recompute. PATCHing one input without
recomputing leaves the backlog sorted by a stale score and is the
most common silent corruption in this domain.

**Recipe:**

```bash
# 1. Read current scores
semantius call crud postgrestRequest '{"method":"GET","path":"/features?id=eq.<id>&select=id,feature_title,reach_score,impact_score,confidence_score,effort_score,rice_score"}'

# 2. Compute new rice_score = (reach * impact * confidence) / effort using the merged values

# 3. PATCH all four inputs (the changed ones) plus rice_score in one call
semantius call crud postgrestRequest '{
  "method":"PATCH",
  "path":"/features?id=eq.<id>",
  "body":{
    "reach_score":5000,
    "impact_score":2,
    "confidence_score":80,
    "effort_score":3,
    "rice_score":266666.67
  }
}'
```

**Validation:** `rice_score` on the row equals
`(reach * impact * confidence) / effort` with the post-PATCH inputs.

**Failure modes:**
- `effort_score` is null or zero after the PATCH → division is
  undefined; PATCH `rice_score` to null and tell the user the score
  will recompute once effort is set. Do not write a placeholder value.
- One score field PATCHed without `rice_score` recomputed → silent
  corruption; recover by reading the row, recomputing, and PATCHing
  `rice_score` to the correct value.

---

### Triage a feature (under_review → planned / declined / parked)

**Triggers:** `triage the backlog`, `move X to under review`, `decline this feature`, `park this idea for next quarter`, `promote X to planned`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `feature_id` | yes | Resolve by `feature_title` via `wfts(simple)` |
| Target `feature_status` | yes | One of `under_review`, `planned`, `declined`, `parked` |

**This is a DB-unguarded lifecycle gate.** Semantius accepts any
`feature_status` PATCH; the rules below are enforced client-side.

- `new` → `under_review`, `planned`, `declined`, or `parked` are valid.
- `under_review` → same set.
- `planned` / `in_progress` / `shipped` are committed states; do not
  drop a committed feature back to `under_review` or `new` without
  confirming with the user (the work is being tracked elsewhere as
  in-flight).
- Promoting to `planned` requires a `release_id`; if the user did
  not name a release, route to the *Schedule a feature into a
  release* JTBD instead of patching status alone.
- `shipped` is a terminal state; do not flip it via this JTBD.
  Reopening a shipped feature is a model decision, not a triage step.

**Recipe (decline or park):**

```bash
# 1. Read current state
semantius call crud postgrestRequest '{"method":"GET","path":"/features?id=eq.<id>&select=id,feature_title,feature_status,release_id"}'

# 2. Refuse if current status is `shipped`; ask the user before flipping `in_progress`/`planned` backwards.

# 3. PATCH
semantius call crud postgrestRequest '{
  "method":"PATCH",
  "path":"/features?id=eq.<id>",
  "body":{"feature_status":"declined"}
}'
```

**Recipe (move under_review → planned):** route to the *Schedule a
feature into a release* JTBD instead; do not PATCH `planned` here.

**Validation:** `feature_status` matches the target; for
`declined`/`parked`, `release_id` should be `null` (a declined
feature on a release schedule confuses release-content reports;
unset it in the same PATCH if it was set).

**Failure modes:**
- Promoting to `planned` without a `release_id` → the commitment rule
  breaks (status says committed, schedule says no). Either set
  `release_id` in the same PATCH (use the schedule JTBD) or refuse.
- Declining a feature that already has votes / comments / tags →
  fine, FKs from those tables stay valid; tell the user the
  discussion is preserved on the declined row.

---

### Schedule a feature into a release

**Triggers:** `schedule X into v2.5`, `add this feature to the March 2026 release`, `commit the dark mode work to v3.0`, `move this off the v2.5 release`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `feature_id` | yes | Resolve by `feature_title` via `wfts(simple)` |
| `release_id` | yes for scheduling, null for unscheduling | Resolve by `release_name=eq.<name>` (unique) |
| `target_start_date`, `target_completion_date` | no | Set if the user named them |

**Cross-FK invariant.** The commitment rule says
`feature_status ∈ {planned, in_progress, shipped} ⇔ release_id is
set`. Schedule and status must agree, in the **same PATCH**:

- Scheduling a `new` / `under_review` / `parked` / `declined` feature
  into a release → set `release_id` AND flip `feature_status` to
  `planned` together.
- Scheduling a `planned` feature into a different release → just
  swap `release_id`; status stays `planned`.
- Scheduling an `in_progress` or `shipped` feature into a different
  release → ask the user first; this rewrites history.
- Unscheduling (remove from a release) → set `release_id=null` AND
  flip `feature_status` back to `under_review` together. A
  null-`release_id` `planned` row breaks every release-content
  report.

**Read the release first.** Refuse to schedule into a release whose
`release_status` is `released` or `cancelled`; the work cannot ship
through a closed release.

**Recipe (schedule a new feature into a release):**

```bash
# 1. Resolve the release; verify it is not released/cancelled
semantius call crud postgrestRequest '{"method":"GET","path":"/releases?release_name=eq.<name>&select=id,release_status,target_release_date"}'

# 2. Read the feature's current state
semantius call crud postgrestRequest '{"method":"GET","path":"/features?id=eq.<id>&select=id,feature_status,release_id"}'

# 3. PATCH release_id and feature_status together
semantius call crud postgrestRequest '{
  "method":"PATCH",
  "path":"/features?id=eq.<id>",
  "body":{
    "release_id":"<release id>",
    "feature_status":"planned",
    "target_start_date":"<optional, YYYY-MM-DD>",
    "target_completion_date":"<optional, YYYY-MM-DD>"
  }
}'
```

**Recipe (unschedule):**

```bash
semantius call crud postgrestRequest '{
  "method":"PATCH",
  "path":"/features?id=eq.<id>",
  "body":{"release_id":null,"feature_status":"under_review"}
}'
```

**Validation:** if `release_id` is set, `feature_status` is in
`{planned, in_progress, shipped}`; if `release_id` is null,
`feature_status` is in `{new, under_review, declined, parked}`.

**Failure modes:**
- `release_status` of the resolved release is `released` or
  `cancelled` → refuse; ask the user to pick a different release.
- Status flipped to `planned` but `release_id` not set in the same
  call → silent commitment-rule break; recover by PATCH-ing
  `release_id` or reverting status.
- Feature already on a different release → tell the user which one
  and confirm before swapping; release-content reports change.

---

### Ship a release (cascade)

**Triggers:** `ship the March 2026 release`, `release v2.5`, `mark v3.0 as released`, `the release went out yesterday`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `release_id` | yes | Resolve by `release_name=eq.<name>` (unique) |
| `actual_release_date` | yes | The date it actually shipped; do not bake a literal |
| `release_notes` | no | HTML string published with the release |

**This is a Pattern C cascade.** Shipping a release is not a single
PATCH; it sweeps every feature attached to the release and flips
each from `planned` / `in_progress` to `shipped` in one bulk PATCH.
The DB does not enforce the cascade; if you stop after step 1, the
release report says "shipped on 2026-05-04" but its features still
sit at `in_progress`, and the backlog dashboard double-counts work
that has actually gone out.

Features already at `shipped`, `declined`, or `parked` on the
release should NOT be touched. Decline/park decisions made before
shipping are intentional, sweeping them to `shipped` would falsify
the record.

**Recipe:**

```bash
# 1. Resolve the release; verify it is not already released or cancelled
semantius call crud postgrestRequest '{"method":"GET","path":"/releases?release_name=eq.<name>&select=id,release_status,target_release_date,actual_release_date"}'

# 2. PATCH the release: status + actual_release_date + (optional) release_notes in one call
semantius call crud postgrestRequest '{
  "method":"PATCH",
  "path":"/releases?id=eq.<release id>",
  "body":{
    "release_status":"released",
    "actual_release_date":"<today, YYYY-MM-DD>",
    "release_notes":"<optional HTML>"
  }
}'

# 3. Sweep features: every feature on this release at planned or in_progress -> shipped (bulk PATCH)
semantius call crud postgrestRequest '{
  "method":"PATCH",
  "path":"/features?release_id=eq.<release id>&feature_status=in.(planned,in_progress)",
  "body":{"feature_status":"shipped"}
}'

# 4. Verify the sweep
semantius call crud postgrestRequest '{"method":"GET","path":"/features?release_id=eq.<release id>&select=id,feature_title,feature_status&order=feature_status.asc"}'
```

`actual_release_date`: set to the actual ship date at call time; do
not copy the placeholder.

**Validation:** the release row shows `release_status=released` and
`actual_release_date` non-null; every feature on the release is in
`{shipped, declined, parked}`; none remain at `planned` or
`in_progress`.

**Failure modes:**
- Step 2 succeeded but step 3 failed (partial cascade) → the funnel
  is half-applied; do NOT retry blindly. Read the feature list, see
  which rows are still `planned` / `in_progress`, and PATCH only
  those. Tell the user.
- A feature on the release is at `under_review` or `new` (commitment
  rule already broken before shipping) → leave it alone; do not
  sweep non-committed work to `shipped`. Surface the row to the
  user as a data-quality issue.
- Release is already `released` → do not re-ship; the original
  `actual_release_date` is correct. Refuse and tell the user.

---

### Vote on a feature

**Triggers:** `vote for the dark mode feature`, `record Alice's vote on X`, `Alex wants this feature too`, `bump the weight on this vote`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `feature_id` | yes | Resolve by `feature_title` via `wfts(simple)` |
| `user_id` | yes | Resolve by `user_email=eq.<email>` (unique) |
| `vote_weight` | no | Default 1; higher = stronger signal (e.g. 5 for an executive sponsor) |
| `voted_at` | no | Set to the current ISO timestamp at vote time |

**Junction without DB-level uniqueness.** The table does not constrain
`(feature_id, user_id)`. POSTing the same pair twice creates a
duplicate vote that silently inflates the vote-count signal. Always
read first.

**Caller-populated label.** `feature_votes.feature_vote_label` is
required on insert and not auto-derived. Compose it as
`"{user.user_full_name} → {feature.feature_title}"`. The recipe must
read both rows to have the values to compose with.

**Recipe (cast a new vote):**

```bash
# 1. Resolve the feature, the user, and check for an existing vote in one round
semantius call crud postgrestRequest '{"method":"GET","path":"/features?search_vector=wfts(simple).<term>&select=id,feature_title"}'
semantius call crud postgrestRequest '{"method":"GET","path":"/users?user_email=eq.<email>&select=id,user_full_name"}'
semantius call crud postgrestRequest '{"method":"GET","path":"/feature_votes?feature_id=eq.<feature>&user_id=eq.<user>&select=id,vote_weight,feature_vote_label"}'

# 2a. If a row already exists with the same vote_weight, do nothing; tell the user.
# 2b. If a row exists with a different vote_weight, PATCH the weight (do not POST a duplicate):
semantius call crud postgrestRequest '{
  "method":"PATCH","path":"/feature_votes?id=eq.<existing id>",
  "body":{"vote_weight":5,"voted_at":"<current ISO timestamp>"}
}'
# 2c. Otherwise, create:
semantius call crud postgrestRequest '{
  "method":"POST","path":"/feature_votes",
  "body":{
    "feature_vote_label":"<user.user_full_name> -> <feature.feature_title>",
    "feature_id":"<feature id>",
    "user_id":"<user id>",
    "vote_weight":1,
    "voted_at":"<current ISO timestamp>"
  }
}'
```

`voted_at`: set to the current ISO timestamp at call time; do not
copy the placeholder.

**Validation:** exactly one row exists for the `(feature_id,
user_id)` pair; `feature_vote_label` matches the
`"<full name> -> <feature title>"` composition.

**Failure modes:**
- A POST without the read-first → the table accepts a duplicate.
  Recover by DELETE-ing one of the duplicates, or by PATCH-ing one
  to the desired `vote_weight` and DELETE-ing the other.
- The user is not in `users` yet → create the user first
  (`use-semantius` handles user creation); do not invent a fake id.

---

### Tag a feature

**Triggers:** `tag this as mobile`, `add the enterprise tag to X`, `categorize this feature as platform`, `untag this`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `feature_id` | yes | Resolve by `feature_title` via `wfts(simple)` |
| `tag_id` | yes | Resolve by `tag_name=eq.<name>` (unique). If the tag does not exist, ask before creating one; tags are reusable categorization, not free-form |

**Junction without DB-level uniqueness.** The table does not
constrain `(feature_id, tag_id)`. POSTing the same pair twice
creates a duplicate row that pollutes "what tags does this feature
have" lists. Always read first.

**Caller-populated label.** `feature_tags.feature_tag_label` is
required on insert and not auto-derived. Compose it as
`"{feature.feature_title} / {tag.tag_name}"`.

**Recipe (add a tag):**

```bash
# 1. Resolve the feature and the tag, and check for an existing pair
semantius call crud postgrestRequest '{"method":"GET","path":"/features?search_vector=wfts(simple).<term>&select=id,feature_title"}'
semantius call crud postgrestRequest '{"method":"GET","path":"/tags?tag_name=eq.<name>&select=id,tag_name"}'
semantius call crud postgrestRequest '{"method":"GET","path":"/feature_tags?feature_id=eq.<feature>&tag_id=eq.<tag>&select=id"}'

# 2. If the pair exists, do nothing; tell the user. Otherwise:
semantius call crud postgrestRequest '{
  "method":"POST","path":"/feature_tags",
  "body":{
    "feature_tag_label":"<feature.feature_title> / <tag.tag_name>",
    "feature_id":"<feature id>",
    "tag_id":"<tag id>"
  }
}'
```

**Recipe (remove a tag):**

```bash
semantius call crud postgrestRequest '{
  "method":"DELETE","path":"/feature_tags?feature_id=eq.<feature>&tag_id=eq.<tag>"
}'
```

**Validation:** exactly one `feature_tags` row for the
`(feature_id, tag_id)` pair; `feature_tag_label` matches the
`"<feature title> / <tag name>"` composition.

**Failure modes:**
- The tag the user named does not exist → ask before creating one;
  silently auto-creating tags fragments the taxonomy
  (`mobile-app`, `mobile`, `Mobile` all coexisting).
- A POST without the read-first → duplicate row; recover by
  DELETE-ing the extra.

---

### Comment on a feature

**Triggers:** `comment on this feature`, `add a note to X`, `reply to the discussion on the dark mode feature`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `feature_id` | yes | Resolve by `feature_title` via `wfts(simple)` |
| `author_id` | yes on insert | Resolve by `user_email=eq.<email>`; storage is nullable so a deleted user's comments survive as orphaned, but the caller must always pass it |
| `comment_body` | yes | The full text the user wrote |
| `posted_at` | no | Set to the current ISO timestamp at post time |

**Caller-populated label.** `comments.comment_label` is required on
insert and not auto-derived. Compose it as the **first ~80
characters of `comment_body`**, trimmed at a word boundary if
possible. Do not pass the full body again as the label; the column
is for list-view display, not the message itself.

**Recipe:**

```bash
# 1. Resolve the feature and the author
semantius call crud postgrestRequest '{"method":"GET","path":"/features?search_vector=wfts(simple).<term>&select=id,feature_title"}'
semantius call crud postgrestRequest '{"method":"GET","path":"/users?user_email=eq.<email>&select=id,user_full_name"}'

# 2. Compose comment_label = first ~80 chars of comment_body (word-boundary trim)

# 3. Post the comment (paired write: posted_at goes in the same call as the body)
semantius call crud postgrestRequest '{
  "method":"POST","path":"/comments",
  "body":{
    "comment_label":"<first ~80 chars of comment_body>",
    "feature_id":"<feature id>",
    "author_id":"<user id>",
    "comment_body":"<full comment body>",
    "posted_at":"<current ISO timestamp>"
  }
}'
```

`posted_at`: set to the current ISO timestamp at call time; do not
copy the placeholder.

**Validation:** new row exists; `comment_label` is a prefix of
`comment_body` (≤ ~80 chars); `feature_id` resolves to a real
feature; `posted_at` is non-null.

**Failure modes:**
- `comment_label` set to the full body → list views become unreadable;
  recover by PATCH-ing `comment_label` to the trimmed prefix.
- `author_id` omitted on POST → required-on-insert; the row is
  rejected. Resolve the user first.
- `posted_at` left null → time-ordered comment threads break;
  PATCH to add the timestamp.

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
  `rice_score = (reach * impact * confidence) / effort` in the same
  call; if `effort_score` ends up null or zero, set `rice_score`
  to null rather than writing a placeholder.
- Never PATCH `releases.release_status=released` without setting
  `actual_release_date` in the same call, and always sweep the
  release's `planned`/`in_progress` features to `shipped` in the
  same operation; a half-shipped release corrupts every backlog
  and release-content report.
- Never POST to `feature_votes` for a `(feature_id, user_id)` pair
  that already exists; PATCH the existing row's `vote_weight` instead.
- Never POST to `feature_tags` for a `(feature_id, tag_id)` pair
  that already exists; the row is the link, there is nothing to
  update on it.
- Never auto-create tags from a casual user mention; ask first.
  `tag_name` is unique, but the taxonomy fragments
  (`mobile-app` / `mobile` / `Mobile`) if every typo becomes a new tag.
- Never schedule a feature into a release whose `release_status` is
  `released` or `cancelled`.
- Lookups for human-friendly identifiers (titles, names,
  descriptions) use `search_vector=wfts(simple).<term>`; never
  `ilike` and never `fts`.
- Audit-logged tables (`objectives`, `features`, `releases`,
  `cost_centers`) write their own audit rows; do not hand-write to
  any audit table.
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
