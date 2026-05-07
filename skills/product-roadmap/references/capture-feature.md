# Capture a new feature (intake)

Insert a new row into `features` at the start of the funnel. The
load-bearing invariant is the commitment rule: a feature created via
intake stays at `feature_status=new` (or `under_review`) and must not
be set to `planned`/`in_progress`/`shipped` here, because those
require a `release_id` and belong to the schedule JTBD.

## Composition rules

`rice_score` is a stored computed field on `features`, the column is
`numeric` with scale 4. If the caller passes any of the four RICE
inputs (`reach_score`, `impact_score`, `confidence_score`,
`effort_score`), compute and write `rice_score` in the **same** POST
body:

```
rice_score = (reach_score * impact_score * confidence_score) / effort_score
```

Round to 4 decimals before writing. Skip the computation when
`effort_score` is missing, null, or zero (division undefined): write
`rice_score: null` and tell the user the score will compute once
effort is set. Never write a placeholder number.

## Recipe

```bash
# Step 1: parallel-fetch (no dependency between these reads). Resolve
# only the references the user actually named; skip the rest.
# expect: --single on user_email, cost_center_code (unique columns);
#         on failure ask the user to retype the email or code.
semantius call crud postgrestRequest --single '{"method":"GET","path":"/users?user_email=eq.<requester email>&select=id,user_full_name"}'
# expect: --single on user_email; on failure ask for the correct email.
semantius call crud postgrestRequest --single '{"method":"GET","path":"/users?user_email=eq.<owner email>&select=id,user_full_name"}'
# expect: array (wfts can return zero / one / many); zero means ask the
#         user to clarify, many means present candidates and ask.
semantius call crud postgrestRequest '{"method":"GET","path":"/objectives?search_vector=wfts(simple).<term>&select=id,objective_name,objective_status"}'
# expect: --single on cost_center_code; on failure ask for the correct code.
semantius call crud postgrestRequest --single '{"method":"GET","path":"/cost_centers?cost_center_code=eq.<code>&select=id,cost_center_name,cost_center_status"}'

# Step 2: branching guards (consumes step 1 reads).
#   - If the resolved objective has objective_status in (cancelled, missed),
#     ask the user before continuing; rolling new ideas into an
#     abandoned objective is almost always a mistake.
#   - If the resolved cost_center has cost_center_status=inactive, ask;
#     charging new work to an inactive bucket distorts the cost roll-up.
#   - Refuse if the caller passed feature_status in (planned, in_progress,
#     shipped); those need release_id and belong to the schedule JTBD.

# Step 3: compute rice_score per the rule above (only if any RICE input
# was provided AND effort_score is non-zero).

# Step 4: POST. Pass only the fields the caller provided plus the
# computed rice_score. submitted_at is the current ISO timestamp.
# expect: array (write returns the inserted row); exit-code guard only.
semantius call crud postgrestRequest '{
  "method":"POST",
  "path":"/features",
  "body":{
    "feature_title":"<title>",
    "feature_type":"<one of new_feature|enhancement|change_request|bug|tech_debt>",
    "feature_status":"new",
    "feature_priority":"<critical|high|medium|low>",
    "feature_source":"<unspecified|customer|support|sales|internal|partner>",
    "requester_id":"<optional uuid from step 1>",
    "owner_id":"<optional uuid from step 1>",
    "objective_id":"<optional uuid from step 1>",
    "cost_center_id":"<optional uuid from step 1>",
    "submitted_at":"<current ISO timestamp>",
    "reach_score":"<optional integer>",
    "impact_score":"<optional number>",
    "confidence_score":"<optional number>",
    "effort_score":"<optional number>",
    "rice_score":"<computed or null>"
  }
}'
```

## Validation

- New row exists; `feature_status` matches what the caller asked for
  (defaulting to `new`).
- If any RICE input was passed and `effort_score` is non-zero,
  `rice_score` equals `(reach * impact * confidence) / effort`
  rounded to 4 decimals.
- If `effort_score` is null or zero, `rice_score` is null (not a
  placeholder).
- Every FK column the caller named resolved to a real row in the
  parent table.

## Failure modes (extended)

- **Caller asks to set `feature_status=planned` at intake.** Refuse
  here. Recovery: route to the *Schedule a feature into a release*
  JTBD; the commitment rule needs `release_id` to agree.
- **`objective_id` resolves to an objective with status `cancelled`
  or `missed`.** Ask the user before continuing; rolling new ideas
  into an abandoned objective is almost always a mistake. Recovery:
  either pick a different objective or omit `objective_id`.
- **`cost_center_id` resolves to a cost center with
  `cost_center_status=inactive`.** Ask. Recovery: either pick an
  active cost center or omit the field; do not silently route spend
  to an inactive bucket.
- **RICE inputs passed but `effort_score=0`.** The formula divides by
  zero. Recovery: write `rice_score: null` and tell the user; do not
  write a placeholder.
- **FK lookup returns multiple rows** (fuzzy `wfts(simple)` on
  `objective_name`). Present candidates and ask; do not pick
  arbitrarily.
