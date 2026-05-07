# Record offer response and complete a hire (cascade)

An `accepted` response is not a single PATCH; it ripples across four
tables. The DB guards none of the steps; if the recipe stops after
step 1 the funnel report says "offer accepted" but the candidate is
still listed as `active` with no hire date.

## Cascade outline

1. `offers`: flip `status` and `candidate_response` together; set
   `responded_at`.
2. `job_applications` (on `accepted` only): set `status=hired`, set
   `hired_at`, set `current_stage_id` to the `hired`-category stage.
3. `candidates` (on `accepted` only): set `candidate_status=hired`.
4. `job_openings` (on `accepted` only, conditional): if hires now
   equal `headcount`, flip the opening to `filled` and set
   `filled_at`.

`declined` is just step 1; the application stays `active` so the
recruiter can decide whether to revise the offer or close the
pipeline.

## Recipe (accepted branch, the full cascade)

```bash
# Step 1: parallel-fetch (no dependency between these reads)
# Resolve the offer and walk to its application, candidate, and job.
semantius call crud postgrestRequest '{"method":"GET","path":"/offers?id=eq.<offer_id>&select=id,status,application_id,application:application_id(id,candidate_id,job_opening_id,current_stage_id)"}'
# expect: array of length 1.

# Read the candidate's current status separately so you can patch it.
semantius call crud postgrestRequest '{"method":"GET","path":"/candidates?id=eq.<candidate_id>&select=id,candidate_status"}'
# expect: array of length 1.

# Find the hired-category stage (lowest stage_order in that category).
semantius call crud postgrestRequest '{"method":"GET","path":"/application_stages?stage_category=eq.hired&order=stage_order.asc&limit=1&select=id,stage_name"}'
# expect: array of length 1; if empty, the model is missing the
# hired stage configuration and the cascade cannot complete.

# Read the job opening's headcount and count its current hires.
semantius call crud postgrestRequest '{"method":"GET","path":"/job_openings?id=eq.<job_opening_id>&select=id,headcount,status"}'
# expect: array of length 1.

semantius call crud postgrestRequest '{"method":"GET","path":"/job_applications?job_opening_id=eq.<job_opening_id>&status=eq.hired&select=id"}'
# expect: array; existing-hires count is the array length.

# Step 2: branch on read results
# - If the offer's status is already terminal (accepted/declined/
#   rescinded/expired): refuse; the operation is not idempotent on
#   already-resolved offers. Tell the user the current status.
# - Check for parallel active offers on the same application:
semantius call crud postgrestRequest '{"method":"GET","path":"/offers?application_id=eq.<application_id>&status=in.(draft,pending_approval,approved,sent)&id=neq.<offer_id>&select=id,status"}'
#   If non-empty: ask the user whether to rescind those parallel
#   offers first. Do not silently leave them or auto-rescind.

# Step 3: PATCH the offer (status + candidate_response + responded_at,
# all in one call so the paired fields stay aligned).
semantius call crud postgrestRequest '{
  "method":"PATCH","path":"/offers?id=eq.<offer_id>",
  "body":{"status":"accepted","candidate_response":"accepted","responded_at":"<current ISO timestamp>"}
}'
# expect: 204 No Content.

# Step 4: PATCH the application (status + hired_at + stage, all in one).
semantius call crud postgrestRequest '{
  "method":"PATCH","path":"/job_applications?id=eq.<application_id>",
  "body":{"status":"hired","hired_at":"<current ISO timestamp>","current_stage_id":"<hired stage id>"}
}'
# expect: 204 No Content.

# Step 5: PATCH the candidate.
semantius call crud postgrestRequest '{
  "method":"PATCH","path":"/candidates?id=eq.<candidate_id>",
  "body":{"candidate_status":"hired"}
}'
# expect: 204 No Content.

# Step 6: conditionally fill the job opening.
# Compute filled = (existing hires count + 1 [the one we just made])
# >= headcount.
# If filled is true AND job_opening.status != "filled":
semantius call crud postgrestRequest '{
  "method":"PATCH","path":"/job_openings?id=eq.<job_opening_id>",
  "body":{"status":"filled","filled_at":"<today, YYYY-MM-DD>"}
}'
# expect: 204 No Content.
# If filled is false: skip step 6 entirely.
# If the opening is already filled or closed: skip step 6 (the prior
# fill is correct; do not re-PATCH).
```

## Recipe (declined branch, no cascade)

```bash
# Just the offer flip. The application stays active; the recruiter
# decides separately whether to revise the offer or close.
semantius call crud postgrestRequest '{
  "method":"PATCH","path":"/offers?id=eq.<offer_id>",
  "body":{"status":"declined","candidate_response":"declined","responded_at":"<current ISO timestamp>"}
}'
# expect: 204 No Content.
```

After a `declined`, ask the user whether to also withdraw the
application or hold it for a counter-offer. Do not auto-flip the
application; that is a separate decision.

## Validation (accepted branch)

- The offer reads `status=accepted`, `candidate_response=accepted`,
  `responded_at` non-null.
- The application reads `status=hired`, `hired_at` non-null,
  `current_stage_id` resolves to a stage with
  `stage_category=hired`.
- The candidate reads `candidate_status=hired`.
- If the conditional step 6 ran: the job opening reads `status=filled`
  and `filled_at` non-null. If it did not run: the job opening's
  status is unchanged.

## Failure modes (extended)

- **PATCH mid-cascade fails.** Triggering: any of steps 3-6 returns
  non-2xx. Recovery: the funnel is in a half-applied state. Do NOT
  retry blindly. Read each row; identify which steps did not stick;
  PATCH only those, in the original order. Tell the user the
  cascade was interrupted and what was applied.
- **Parallel `sent`-status offer on the same application.**
  Triggering: step-2 read found another non-terminal offer.
  Recovery: ask the user. If they want to rescind it, PATCH that
  offer's `status` to `rescinded` before continuing the cascade. Do
  not leave parallel active offers; reports treat them as a data
  integrity problem.
- **Job opening already `filled` or `closed`.** Triggering: the
  step-1 read on `job_openings` showed a non-`open` status, or the
  conditional in step 6 evaluates to "already filled". Recovery:
  skip step 6 entirely. The previous fill is correct.
- **Hired-category stage not found.** Triggering: step-1 stage read
  returned empty. Recovery: the model is missing the hired stage and
  the cascade cannot complete cleanly. Surface the issue; the user
  must add a `stage_category=hired` row before the cascade can run.
- **Offer is already terminal.** Triggering: step-2 branch fired on
  the offer's prior status. Recovery: refuse and tell the user. The
  cascade is not idempotent past the offer flip; re-running on an
  already-accepted offer would re-stamp `responded_at` and the audit
  trail.
