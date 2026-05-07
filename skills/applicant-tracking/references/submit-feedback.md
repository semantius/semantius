# Submit interview feedback

Create or finalize one interviewer's scorecard for one interview.
`is_submitted=true` and `submitted_at` must move together in the
same write; otherwise downstream reports treat the row as "submitted
but no time" and silently exclude it.

## Composition rules

- `feedback_label`: composed as
  `"{interviewer.display_name}, {kind label fragment} for {candidate.full_name}"`,
  e.g. `"Alex Kim, On-site for Jane Doe"`. The kind label fragment
  follows the same enum-to-label mapping as the schedule-interview
  reference (`phone_screen` -> `Phone screen`, `onsite` -> `On-site`,
  `take_home` -> `Take-home`, etc.). Comma-space separates
  `interviewer.display_name` from the rest; ` for ` (space-f-o-r-space)
  separates the kind from the candidate.

## Recipe (create-and-submit in one call)

```bash
# Step 1: parallel-fetch (no dependency between these reads)
# Walk from the interview to its application and candidate so you
# have the name and kind for the label.
semantius call crud postgrestRequest '{"method":"GET","path":"/interviews?id=eq.<interview_id>&select=id,interview_kind,status,application:application_id(candidate:candidate_id(full_name))"}'
# expect: array of length 1; if empty, the interview id is wrong.
# If embedded-select is not supported, fall back to a chain of three
# GETs (interview -> application -> candidate).

# Look up the interviewer.
semantius call crud postgrestRequest '{"method":"GET","path":"/users?email_address=eq.<email>&select=id,display_name"}'
# expect: array of length 1; if empty, the interviewer needs a user
# row first (use-semantius user creation).

# Step 2: branch on read results
# - If the interviewer is not on the hiring_team_members for this
#   interview's job opening: not blocked, but flag to the user. Ask
#   whether to proceed; out-of-team feedback is unusual (a coverage
#   interviewer, an external reference) and worth a confirmation.

# Step 3: compose the label and POST.
semantius call crud postgrestRequest '{
  "method":"POST",
  "path":"/interview_feedback",
  "body":{
    "feedback_label":"<interviewer.display_name>, <kind label fragment> for <candidate.full_name>",
    "interview_id":"<interview_id>",
    "interviewer_user_id":"<interviewer.id>",
    "overall_rating":"<enum value>",
    "recommendation":"<enum value>",
    "strengths":"<text>",
    "concerns":"<text>",
    "detailed_notes":"<text>",
    "is_submitted":true,
    "submitted_at":"<current ISO timestamp>"
  }
}'
# expect: 201 with the new row's id.
```

## Recipe (promote a draft to submitted)

```bash
# Same paired-write rule on PATCH.
semantius call crud postgrestRequest '{
  "method":"PATCH",
  "path":"/interview_feedback?id=eq.<feedback_id>",
  "body":{"is_submitted":true,"submitted_at":"<current ISO timestamp>"}
}'
# expect: 204 No Content.
```

## Validation

- Read the row; `is_submitted=true` AND `submitted_at` is non-null.
- `interviewer_user_id` resolves to the user the recipe looked up.
- The audit log shows the create or transition (`interview_feedback`
  is audit-logged).

## Failure modes (extended)

- **`is_submitted=true` set without `submitted_at`.** Triggering: a
  prior call (not this recipe) split the paired write. Recovery: PATCH
  the row to set `submitted_at` to the current timestamp; downstream
  reports start counting it once the timestamp is present.
- **Interviewer not on the hiring team for this opening.**
  Triggering: step-2 branch fired. Recovery: ask the user. If they
  proceed, optionally suggest adding the interviewer to
  `hiring_team_members` so future feedback joins are clean (separate
  JTBD: add or remove a hiring team member).
- **Interviewer user does not exist.** Triggering: step-1 user lookup
  returned empty. Recovery: do not invent an id; route to
  `use-semantius` user creation. The interviewer must exist in `users`
  before feedback can be authored against them.
- **Embedded-select fallback path.** Same as schedule-interview: split
  the chain into three reads if the deployment does not support
  nested `select` paths.
