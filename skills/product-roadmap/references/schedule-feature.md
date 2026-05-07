# Schedule a feature into a release

Set or change a feature's `release_id`, with the matching
`feature_status` flip in the same PATCH. The load-bearing invariant
is the commitment rule:
`feature_status ∈ {planned, in_progress, shipped} ⇔ release_id is
set`. Schedule and status MUST agree, in one call; splitting the
write across two PATCHes leaves the row in a state that breaks
every release-content report.

## Status / release pairing

- Scheduling a `new` / `under_review` / `parked` / `declined`
  feature into a release: set `release_id` AND
  `feature_status=planned` together.
- Scheduling a `planned` feature into a different release: swap
  `release_id` only; status stays `planned`.
- Scheduling an `in_progress` or `shipped` feature into a different
  release: ask the user first, this rewrites history. On
  confirmation, swap `release_id` only; do not flip the status
  backward.
- Unscheduling (remove from a release): set `release_id=null` AND
  `feature_status=under_review` together.

## Refuse if the release is closed

Read the release first. Refuse to schedule into a release whose
`release_status` is `released` or `cancelled`; the work cannot ship
through a closed release.

## Recipe

```bash
# Step 1: parallel-fetch (no dependency between these two reads).
# expect: --single on release_name (unique); on failure ask the user
#         to pick a release that exists.
semantius call crud postgrestRequest --single '{"method":"GET","path":"/releases?release_name=eq.<name>&select=id,release_status,target_release_date"}'
# expect: --single on id=eq.<uuid>; on failure ask for the correct
#         feature title.
semantius call crud postgrestRequest --single '{"method":"GET","path":"/features?id=eq.<feature id>&select=id,feature_title,feature_status,release_id"}'

# Step 2: branching guards (consumes both reads).
#   - If release.release_status in (released, cancelled), refuse.
#   - If feature.feature_status in (in_progress, shipped) and the
#     caller is moving the feature to a different release, ask the
#     user first.
#   - If the caller is unscheduling (release_id -> null) and the
#     current status is in_progress or shipped, ask first; an
#     in-flight feature should not lose its release.

# Step 3a (schedule new -> planned): PATCH release_id and status
# together.
# expect: array (write returns the patched row); exit-code guard only.
semantius call crud postgrestRequest '{
  "method":"PATCH",
  "path":"/features?id=eq.<feature id>",
  "body":{
    "release_id":"<release id>",
    "feature_status":"planned",
    "target_start_date":"<optional, YYYY-MM-DD>",
    "target_completion_date":"<optional, YYYY-MM-DD>"
  }
}'

# Step 3b (swap release on a planned/in_progress/shipped feature):
# release_id only; do NOT touch feature_status.
# expect: array (write returns the patched row); exit-code guard only.
semantius call crud postgrestRequest '{
  "method":"PATCH",
  "path":"/features?id=eq.<feature id>",
  "body":{"release_id":"<new release id>"}
}'

# Step 3c (unschedule): release_id=null AND feature_status=under_review
# together. Setting only one breaks the commitment rule.
# expect: array (write returns the patched row); exit-code guard only.
semantius call crud postgrestRequest '{
  "method":"PATCH",
  "path":"/features?id=eq.<feature id>",
  "body":{"release_id":null,"feature_status":"under_review"}
}'

# Step 4: verify the pairing.
# expect: --single; the row we just PATCHed must exist.
semantius call crud postgrestRequest --single '{"method":"GET","path":"/features?id=eq.<feature id>&select=id,feature_status,release_id"}'
```

`target_start_date` and `target_completion_date` are placeholders the
calling agent fills with real dates the user named; do not copy the
example.

## Validation

- If `release_id` is set, `feature_status` is in
  `{planned, in_progress, shipped}`.
- If `release_id` is null, `feature_status` is in
  `{new, under_review, declined, parked}`.
- For new schedule (3a): `feature_status=planned` AND `release_id`
  matches the release the user named.
- The release the feature now points at has
  `release_status` in `{planned, in_progress}` (not `released` or
  `cancelled`).

## Failure modes (extended)

- **Release the user named has `release_status` in
  `(released, cancelled)`.** Refuse. Recovery: ask the user to
  pick a different release; the work cannot ship through a closed
  release.
- **Status flipped to `planned` but `release_id` not set in the same
  call** (split PATCH). Silent commitment-rule break: backlog
  reports treat the row as committed, release reports do not see
  it. Recovery: PATCH `release_id` to set, OR revert `feature_status`
  to `under_review`. Detect by reading
  `release_id IS NULL AND feature_status='planned'`.
- **`release_id` set but `feature_status` left at `new` /
  `under_review`.** Symmetric break. Recovery: PATCH
  `feature_status='planned'`.
- **Feature already on a different release.** Tell the user which
  one and confirm before swapping; release-content reports will
  change. Do not swap silently.
- **Unschedule attempted on an `in_progress` / `shipped` feature.**
  Ask first, the work has been started or shipped; dropping the
  release retroactively misrepresents what happened. Recovery on
  confirmation: still flip status back to `under_review`, never
  leave a non-committed row with no release.
