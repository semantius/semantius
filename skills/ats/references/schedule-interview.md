# Schedule an interview

Create a new `interviews` row tied to an existing `job_applications` row. The recipe composes the caller-populated `interview_label`, optionally inherits the coordinator from the application's assigned recruiter, and checks for coordinator scheduling overlap before writing. The overlap check is the branch that needs user confirmation, which is why this is a reference and not a script.

## FK & shape assumptions

- `interviews.application_id -> job_applications.id` (parent, cascade)
- `interviews.coordinator_user_id -> users.id` (reference, clear, optional)
- `interview_feedback.interview_id -> interviews.id` (reference, cascade)
- `interviews` is **not** audit-logged; `interview_feedback` is.
- The platform enforces `scheduled_start_before_end` on every INSERT/UPDATE.
- No DB-level unique constraint on `(application_id, scheduled_start)`; multiple interviews on the same application at the same moment are legal.

## Composition rules

- `interview_label` (required, caller-populated): compose as `"{Title-cased interview_kind}, {candidates.full_name}"`. Title-case the kind by replacing `_` with space and capitalizing each word: `phone_screen -> Phone Screen`, `video_call -> Video Call`, `onsite -> Onsite`, `technical -> Technical`, `take_home -> Take Home`, `panel -> Panel`, `final -> Final`, `reference_check -> Reference Check`. Comma-space separator. The candidate name comes from the read-first call in step 1; do not invent.

## Recipe

```bash
# Step 1: parallel-fetch the application + candidate (joined via embed) and the coordinator user.
# expect: --single, exactly one application; exit 1 with "application not found" if missing.
application=$(semantius call crud postgrestRequest --single \
  "{\"method\":\"GET\",\"path\":\"/job_applications?candidate_id=eq.<candidate_id>&job_opening_id=eq.<job_opening_id>&status=eq.active&select=id,assigned_recruiter_id,candidates(full_name)\"}")

# Resolve coordinator: either the user-named coordinator email, or fallback to application.assigned_recruiter_id.
# expect: --single when by email (email is unique); exit 1 with "coordinator '<email>' not found" if missing.
coordinator=$(semantius call crud postgrestRequest --single \
  "{\"method\":\"GET\",\"path\":\"/users?email_address=eq.<coordinator_email>&select=id,display_name\"}") \
  || coordinator=""
# If coordinator is empty AND user did not supply an email, set coordinator_user_id = application.assigned_recruiter_id (may be null).

# Step 2: coordinator-overlap check (only when a coordinator is set).
# expect: array; zero rows is the go-ahead branch, one or more is the user-confirm branch.
overlaps=$(semantius call crud postgrestRequest \
  "{\"method\":\"GET\",\"path\":\"/interviews?coordinator_user_id=eq.<coordinator_id>&status=eq.scheduled&scheduled_start=lt.<scheduled_end>&scheduled_end=gt.<scheduled_start>&select=id,interview_label,scheduled_start,scheduled_end\"}")
# If overlaps is non-empty: ASK THE USER before proceeding ("Coordinator <name> has <N> overlapping
# scheduled interview(s). Schedule anyway, or pick a different time?"). Do not silently
# overbook. Looks good?

# Step 3: compose interview_label and POST.
# expect: --single, exactly one row written.
semantius call crud postgrestRequest --single "{
  \"method\":\"POST\",
  \"path\":\"/interviews\",
  \"body\":{
    \"interview_label\":\"<Title-cased interview_kind>, <candidates.full_name>\",
    \"application_id\":\"<application_id>\",
    \"interview_kind\":\"<phone_screen|video_call|onsite|technical|take_home|panel|final|reference_check>\",
    \"scheduled_start\":\"<scheduled_start ISO timestamp>\",
    \"scheduled_end\":\"<scheduled_end ISO timestamp>\",
    \"status\":\"scheduled\",
    \"location\":\"<location string or omit>\",
    \"meeting_url\":\"<url or omit>\",
    \"coordinator_user_id\":\"<coordinator_id or omit>\"
  }
}"

# Step 4: verify the write.
# expect: --single, the row we just wrote.
semantius call crud postgrestRequest --single \
  "{\"method\":\"GET\",\"path\":\"/interviews?id=eq.<new_interview_id>&select=id,interview_label,status,scheduled_start,scheduled_end,coordinator_user_id\"}"
```

## Validation

- The new `interviews` row exists with `status=scheduled`, the resolved `application_id`, and matching `scheduled_start` / `scheduled_end`.
- `interview_label` matches the composition rule.
- When a coordinator is set, the row's `coordinator_user_id` matches the resolved user.
- When an overlap was detected, the user explicitly approved the scheduling conflict before the write.

## Failure modes (extended)

- **Application not found.** The candidate has no active application against the opening. Recovery: confirm with the user; submit a new application first via the Submit-application JTBD, then re-run.
- **Coordinator overlap.** The recipe surfaces overlapping scheduled interviews and asks before writing. The user may proceed (overbook is legal), pick a different start/end time, or unassign the coordinator. Never auto-resolve.
- **Platform code `scheduled_start_before_end`.** The caller swapped start / end timestamps. Surface the rule's message verbatim and re-prompt; do not silently swap.
- **Coordinator not found by email.** Either the email is misspelled or the user has been soft-removed (`is_active=false`). Ask the user to confirm the email; the recipe does not auto-create users.
- **Location and meeting_url both empty.** The model does not enforce one or the other, but the recipe asks the user to confirm before writing an interview with neither (an onsite without an address or a remote without a link is usually a mistake).
