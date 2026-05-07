# Schedule an interview

Create an `interviews` row tied to one `job_applications` row at a
specific time, with an interview kind and either a `meeting_url` or
a `location`. The `interview_label` is caller-populated.

## Composition rules

- `interview_label`: composed as
  `"{kind in plain English} for {candidate.full_name}"`, e.g.
  `"Phone screen for Jane Doe"`. The "kind in plain English" is
  produced by:
  1. Take the enum value (e.g. `phone_screen`).
  2. Replace underscores with single spaces (`phone screen`).
  3. Capitalize the first character only; leave the rest lowercase
     (`Phone screen`). This is sentence case, not title case.
  4. Special case: `onsite` renders as `On-site` (the only value in
     the enum that contains an implicit hyphen).
  5. Special case: `take_home` renders as `Take-home`.
  6. The separator before the candidate name is the literal string
     ` for ` (space-f-o-r-space). The candidate name is
     `candidate.full_name` verbatim.

The eight enum-to-label mappings are therefore:

| `interview_kind` | label fragment |
|---|---|
| `phone_screen` | `Phone screen` |
| `video_call` | `Video call` |
| `onsite` | `On-site` |
| `technical` | `Technical` |
| `take_home` | `Take-home` |
| `panel` | `Panel` |
| `final` | `Final` |
| `reference_check` | `Reference check` |

## Recipe

```bash
# Step 1: read the application and walk to its candidate so you have
# the name for the label. Lookup by id → --single.
semantius call crud postgrestRequest --single '{"method":"GET","path":"/job_applications?id=eq.<application_id>&select=id,application_label,status,candidate:candidate_id(full_name)"}'
# expect: --single; exit 1 means the application id is wrong.
# If the embedded select shape is not supported on this deployment,
# fall back to two --single GETs: /job_applications?id=eq.<id>&select=id,status,candidate_id
# then /candidates?id=eq.<candidate_id>&select=full_name.

# Step 2: optional coordinator lookup (only if the user named one).
# email_address is unique → --single. The lookup is optional, but if
# the user named a coordinator the value must resolve.
semantius call crud postgrestRequest --single '{"method":"GET","path":"/users?email_address=eq.<email>&select=id"}'
# expect: --single; exit 1 means the coordinator user does not exist —
# route to use-semantius user creation, do not invent an id.

# Step 3: branch on read results
# - If application.status != "active": refuse; do not schedule on
#   hired/rejected/withdrawn pipelines. Ask the user.
# - If interview_kind = "onsite" and the user did not provide a
#   location: ask whether to add one. Proceed with no location only
#   if the user explicitly says to.

# Step 4: compose the label and POST.
semantius call crud postgrestRequest --single '{
  "method":"POST",
  "path":"/interviews",
  "body":{
    "interview_label":"<kind label fragment> for <candidate.full_name>",
    "application_id":"<application_id>",
    "interview_kind":"<enum value>",
    "scheduled_start":"<start ISO timestamp>",
    "scheduled_end":"<end ISO timestamp>",
    "status":"scheduled",
    "meeting_url":"<optional>",
    "location":"<optional>",
    "coordinator_user_id":"<optional>"
  }
}'
# expect: --single asserts exactly one row was inserted; returns the
# bare new object including the generated id.
```

## Validation

- Read the new row; `status=scheduled`, `scheduled_end > scheduled_start`,
  `interview_label` matches the kind-fragment + candidate composition.
- The application is still `status=active` (no recipe step touched it,
  but worth a sanity check after a multi-step user session).

## Failure modes (extended)

- **Application is not `active`.** Triggering: step-3 branch fired.
  Recovery: refuse and ask the user; offer to re-open the application
  if they intended to (re-opening is not part of this recipe).
- **`onsite` with no location.** Triggering: step-3 branch fired.
  Recovery: ask the user whether to add one; almost always a mistake,
  but valid if they confirm (e.g. location TBD, location captured in
  the meeting URL).
- **Mismatched timestamps (`scheduled_end <= scheduled_start`).**
  Triggering: the agent filled the placeholders incorrectly. Recovery:
  surface the comparison; ask the user to provide a valid range.
  Don't try to auto-fix.
- **Embedded-select fallback path.** Triggering: the deployment does
  not support `candidate:candidate_id(full_name)` in `select`.
  Recovery: split into two reads (application then candidate); the
  rest of the recipe is unchanged.
