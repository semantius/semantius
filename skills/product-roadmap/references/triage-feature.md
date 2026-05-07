# Triage a feature (move to under_review / declined / parked)

Move a feature through the non-committed part of the lifecycle. The
load-bearing invariant is the commitment rule: this JTBD does not
flip a feature into a committed state (`planned`, `in_progress`,
`shipped`); promoting to `planned` requires a `release_id` and is
the schedule JTBD's responsibility.

## Lifecycle gate (DB-unguarded)

Semantius accepts any value for `feature_status`; the rules below
are enforced client-side.

- From `new`: `under_review`, `declined`, or `parked` are valid.
  Promotion to `planned` is **not** done here.
- From `under_review`: same set as `new`.
- From `parked`: `under_review` (revisit) or `declined` are valid.
- From `declined`: `under_review` (reopen) is valid; ask the user
  before reopening, since declined decisions usually carry context.
- From `planned` / `in_progress`: ask the user before flipping
  backward to `under_review` or `new`; the work is being tracked
  elsewhere as in-flight, dropping the commitment can lose state.
- From `shipped`: refuse. Reopening a shipped feature is a model
  decision, not a triage step.

## Recipe

```bash
# Step 1: read current state.
# expect: --single on id=eq.<uuid>; on failure ask for the correct
#         feature title.
semantius call crud postgrestRequest --single '{"method":"GET","path":"/features?id=eq.<feature id>&select=id,feature_title,feature_status,release_id"}'

# Step 2: branching guards (consumes step 1).
#   - If feature_status=shipped, refuse.
#   - If feature_status in (planned, in_progress) and the target is
#     under_review/new, ask the user before continuing.
#   - If the target is planned, refuse here and route to the
#     Schedule a feature into a release JTBD.

# Step 3: PATCH. For declined or parked, also clear release_id if it
# was set: a non-committed feature must not carry a release_id, or
# release-content reports double-count it.
# expect: array (write returns the patched row); exit-code guard only.
semantius call crud postgrestRequest '{
  "method":"PATCH",
  "path":"/features?id=eq.<feature id>",
  "body":{
    "feature_status":"<under_review|declined|parked|new>",
    "release_id":null
  }
}'

# Step 4: verify.
# expect: --single; the row we just PATCHed must exist.
semantius call crud postgrestRequest --single '{"method":"GET","path":"/features?id=eq.<feature id>&select=id,feature_status,release_id"}'
```

## Validation

- `feature_status` matches the target.
- For `declined` or `parked`, `release_id` is null.
- For `under_review` or `new`, `release_id` is null (commitment rule:
  non-committed status implies no release).
- The row's `feature_status` value is one of the allowed enum values
  from §5.3 of the model; the PATCH did not silently write a typo.

## Failure modes (extended)

- **Caller asks to promote to `planned` here.** Refuse and route.
  Recovery: send the user to the *Schedule a feature into a release*
  JTBD; that JTBD owns the paired write of `release_id` +
  `feature_status=planned`.
- **Source status is `shipped`.** Refuse. Recovery: tell the user
  reopening a shipped feature is a model-level decision; if they
  truly want to reopen, that's a manual edit outside this skill.
- **Source status is `planned` or `in_progress` and target is
  `under_review` / `new`.** Ask first. Recovery on confirmation:
  PATCH the status AND set `release_id=null` in the same call;
  leaving `release_id` set on a non-committed row breaks the
  commitment rule and every release-content report.
- **Declined feature still has votes / comments / tags.** Fine, the
  FKs from those tables stay valid. Tell the user the discussion is
  preserved on the declined row; do not delete the children.
- **Caller's target is not in the enum.** Refuse with the valid set;
  don't write a typo (Semantius will accept whatever string is
  passed, the cleanup is painful).
