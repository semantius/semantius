# Close an application as rejected or withdrawn

Move a `job_applications` row to a terminal status. `status` and the
paired side-effect fields (`rejected_at`, plus `rejection_reason` for
`rejected`) must move in the same PATCH; the `current_stage_id` also
flips to a `rejected`-category stage so funnel reports route the row
correctly.

## Recipe (reject)

```bash
# Step 1: parallel-fetch (no dependency between these reads)
# Read the application's current state.
semantius call crud postgrestRequest '{"method":"GET","path":"/job_applications?id=eq.<application_id>&select=id,status,current_stage_id"}'
# expect: array of length 1.

# Resolve the rejected-category stage (lowest stage_order).
semantius call crud postgrestRequest '{"method":"GET","path":"/application_stages?stage_category=eq.rejected&order=stage_order.asc&limit=1&select=id,stage_name"}'
# expect: array of length 1; if empty, the model is missing the
# rejected stage configuration. Surface to the user; cannot continue.

# Check for a non-terminal offer on this application.
semantius call crud postgrestRequest '{"method":"GET","path":"/offers?application_id=eq.<application_id>&status=in.(draft,pending_approval,approved,sent)&select=id,status"}'
# expect: array; if non-empty, branch in step 2.

# Step 2: branch on read results
# - If the application is already in a terminal status
#   (hired/rejected/withdrawn): refuse and tell the user the current
#   status. This recipe is not idempotent past the close.
# - If a `sent`-status offer is outstanding: ask the user. The offer
#   should be `rescinded` first (route to extend-offer.md's transition
#   recipe with status=rescinded). Do not silently close while a sent
#   offer is live.

# Step 3: PATCH the application in one call (status + reason +
# rejected_at + stage all together).
semantius call crud postgrestRequest '{
  "method":"PATCH","path":"/job_applications?id=eq.<application_id>",
  "body":{
    "status":"rejected",
    "rejection_reason":"<enum value, required>",
    "rejected_at":"<current ISO timestamp>",
    "current_stage_id":"<rejected stage id>"
  }
}'
# expect: 204 No Content.
```

## Recipe (withdrawn)

```bash
# Same shape; status=withdrawn, no rejection_reason needed.
# Use rejected_at as the close timestamp (the column is overloaded
# in this model; the rejected_at field stores the close moment for
# both rejected and withdrawn outcomes).
semantius call crud postgrestRequest '{
  "method":"PATCH","path":"/job_applications?id=eq.<application_id>",
  "body":{
    "status":"withdrawn",
    "rejected_at":"<current ISO timestamp>",
    "current_stage_id":"<rejected stage id>"
  }
}'
# expect: 204 No Content.
```

## Validation

- The row reads the target `status` (`rejected` or `withdrawn`),
  `rejected_at` is non-null, `current_stage_id` resolves to a stage
  with `stage_category=rejected`.
- For `rejected`: `rejection_reason` is non-null and matches the
  enum.
- The audit log records the change (`job_applications` is
  audit-logged).

## Failure modes (extended)

- **`status=rejected` set without `rejection_reason`.** Triggering:
  the agent split the paired write or omitted the reason. Recovery:
  PATCH to add it. Funnel-by-reason reports drop the row until the
  field is populated.
- **Application has a `sent`-status offer outstanding.** Triggering:
  step-2 branch fired on the offer read. Recovery: ask the user.
  The right sequence is to rescind the offer first (route to
  `references/extend-offer.md` for the rescind PATCH), then return
  here.
- **Application is already terminal.** Triggering: step-2 branch
  fired on the application status read. Recovery: refuse; tell the
  user the current status. Re-closing would re-stamp `rejected_at`
  and corrupt the audit trail.
- **Rejected-category stage not found.** Triggering: step-1 stage
  read returned empty. Recovery: the model is missing the rejected
  stage configuration. Surface the issue; cannot complete until the
  user adds a `stage_category=rejected` row.
