# Advance an application to the next stage

Move a `job_applications` row from one `application_stage` to another.
The schema accepts any `current_stage_id` PATCH; the rule that you
only move forward (or to a clearly-named recovery stage) is enforced
client-side here. Always read the application's current stage before
writing.

## Recipe

```bash
# Step 1: parallel-fetch (no dependency between these reads)
# Read the application's current state. Lookup by id → --single.
semantius call crud postgrestRequest --single '{"method":"GET","path":"/job_applications?id=eq.<application_id>&select=id,status,current_stage_id,application_label"}'
# expect: --single; exit 1 means the application id is wrong (ask the
# user to disambiguate or look up by candidate + job instead).

# Read the current and target stages together; this is a multi-id
# lookup where the count is the answer (1 if current==target, 2
# otherwise), so use array mode.
semantius call crud postgrestRequest '{"method":"GET","path":"/application_stages?id=in.(<current>,<target>)&select=id,stage_name,stage_order,stage_category"}'
# expect: array of length 2 (or 1 if current==target); if shorter, one
# of the ids does not exist — surface to the user.

# Step 2: branch on read results
# - If application.status != "active" (it is hired/rejected/withdrawn/on_hold):
#   refuse; ask the user whether to re-open the application first.
#   Do not PATCH a terminal row's stage.
# - If target.stage_category in ("hired", "rejected"): refuse and route
#   the user to the offer-acceptance cascade (for hired) or
#   close-application JTBD (for rejected). Those flips own paired
#   side-effect fields that this recipe does not set.
# - If target.stage_order < current.stage_order: ask the user if they
#   meant to move backward. Backward moves are valid (e.g. recovering
#   from a mis-advance), but the user must explicitly confirm so
#   accidental drops do not happen silently.

# Step 3: PATCH only the stage. Status and side-effect fields stay
# untouched on a normal advance.
semantius call crud postgrestRequest --single '{
  "method":"PATCH",
  "path":"/job_applications?id=eq.<application_id>",
  "body":{"current_stage_id":"<target stage id>"}
}'
# expect: --single asserts the PATCH affected exactly one row; returns
# the bare updated object. If exit 1, the application id is wrong.
```

## Validation

- Re-read the row: `current_stage_id` equals the target id; `status`
  is still `active`.
- The audit log shows the change (`job_applications.audit_log: yes`);
  no extra audit write needed.

## Failure modes (extended)

- **Target stage is `hired` or `rejected` category.** Triggering:
  step-2 branch fired. Recovery: route to the offer-acceptance
  cascade or close-application JTBD; advancing without setting the
  paired side-effect fields (`hired_at`, `rejected_at`,
  `rejection_reason`) corrupts the funnel report and the audit
  trail.
- **Application `status` is terminal (`hired`, `rejected`,
  `withdrawn`).** Triggering: step-2 branch fired. Recovery: ask the
  user if they meant to re-open the application first. Re-opening is
  a manual decision, not part of this recipe.
- **Backward move not explicitly requested.** Triggering: step-2
  ordering check fired and the user has not said "move back".
  Recovery: surface the comparison and ask. If they confirm, repeat
  step 3.
- **Stage id does not exist.** Triggering: the in.(...) read in step 1
  returned shorter than expected. Recovery: ask the user to name
  the stage by `stage_name`; resolve by `stage_name=eq.<name>` and
  retry.
