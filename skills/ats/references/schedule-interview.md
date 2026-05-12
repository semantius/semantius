# Schedule an interview

Create a new `interviews` row tied to one `job_applications`. The recipe
disambiguates the application when the user's pair (candidate, job)
matches more than one row, composes the caller-populated
`interview_label`, and warns on coordinator/interviewer time-window
overlaps before booking.

## FK & shape assumptions

- `interviews.application_id -> job_applications.id` (parent, cascade)
- `interviews.coordinator_user_id -> users.id` (reference, clear, optional)
- `interviews` is **not** audit-logged; the audit trail for an interview lives on `job_applications` (status / stage changes) and on `interview_feedback` (per-interviewer scorecards).
- No DB-level uniqueness on (application_id, scheduled_start) or coordinator overlap. The recipe enforces overlap-warning client-side; the user decides whether to proceed.
- Platform invariant: `scheduled_start <= scheduled_end` (`scheduled_start_before_end`). The recipe pairs both fields in one POST.

## Composition rules

- `interview_label` (required, caller-populated): compose as
  `"<interview_kind label> for <candidates.full_name>"`, where
  `<interview_kind label>` is the title-cased English form of the enum
  value (`phone_screen` -> `Phone Screen`, `video_call` -> `Video Call`,
  `onsite` -> `Onsite`, `technical` -> `Technical`, `take_home` -> `Take
  Home`, `panel` -> `Panel`, `final` -> `Final`, `reference_check` ->
  `Reference Check`). Example: `"Phone Screen for Jane Doe"`.
- `<candidates.full_name>` comes from the read in step 2; do not invent.

## Recipe

```bash
# Step 1: resolve the application. Ask the user for both halves of the pair
# (candidate name or email, job code or title) and run the lookups in parallel.
# expect: array; zero rows is "ask the user", one row is the happy path,
# two or more is "ask the user to disambiguate".
applications=$(semantius call crud postgrestRequest \
  "{\"method\":\"GET\",\"path\":\"/job_applications?candidate_id=eq.<candidate_id>&job_opening_id=eq.<job_opening_id>&select=id,application_label,status,current_stage_id\"}")
# Branch:
#   zero rows: ASK THE USER ("no application found for <candidate> at <opening>; create one first via Submit-application?").
#   one row: continue.
#   two or more: ASK THE USER which application_label to use (e.g. one rejected and one active).

# Step 2: read the candidate's full_name for the label.
# expect: --single, the candidate row.
candidate=$(semantius call crud postgrestRequest --single \
  "{\"method\":\"GET\",\"path\":\"/candidates?id=eq.<candidate_id>&select=full_name\"}")

# Step 3: optional overlap warning. Read scheduled interviews in the same window
# for the coordinator (and/or for any interviewer the user named).
# expect: array; zero rows is "no overlap", any rows is "warn the user".
overlap=$(semantius call crud postgrestRequest \
  "{\"method\":\"GET\",\"path\":\"/interviews?coordinator_user_id=eq.<coordinator_user_id>&status=eq.scheduled&scheduled_start=lt.<scheduled_end>&scheduled_end=gt.<scheduled_start>&select=id,interview_label\"}")
# If overlap is non-empty: ASK THE USER whether to book anyway. Surface the existing
# interview_label values so the user can recognise what they are colliding with.

# Step 4: POST the interview.
# expect: --single, one row written.
semantius call crud postgrestRequest --single "{
  \"method\":\"POST\",
  \"path\":\"/interviews\",
  \"body\":{
    \"interview_label\":\"<interview_kind title-case> for <candidates.full_name>\",
    \"application_id\":\"<application_id>\",
    \"interview_kind\":\"<interview_kind>\",
    \"scheduled_start\":\"<scheduled_start ISO timestamp>\",
    \"scheduled_end\":\"<scheduled_end ISO timestamp>\",
    \"location\":\"<location or null>\",
    \"meeting_url\":\"<meeting_url or null>\",
    \"status\":\"scheduled\",
    \"coordinator_user_id\":\"<coordinator_user_id or null>\"
  }
}"

# Step 5: verify.
# expect: --single, the row we just wrote.
semantius call crud postgrestRequest --single \
  "{\"method\":\"GET\",\"path\":\"/interviews?id=eq.<new_interview_id>&select=id,interview_label,interview_kind,status,scheduled_start,scheduled_end\"}"
```

## Validation

- New `interviews` row with `status=scheduled`, `interview_label` matching the composition rule, `scheduled_end` strictly later than `scheduled_start`.
- The application referenced is in a non-terminal state (`active` or `on_hold`); scheduling against `hired`/`rejected`/`withdrawn` should refuse unless the user explicitly says otherwise (rescheduling a rejected candidate's last interview is rare and usually backfilling).

## Failure modes (extended)

- **Multiple matching applications.** The (candidate, job) pair can match a current application and a closed one from a previous round. Surface every match's `application_label` and `status` and ask. Do not auto-pick the active one if both are returned; the user may want to attach an interview to the closed one for documentation.
- **Coordinator/interviewer overlap.** The platform does not enforce non-overlap. The recipe warns; the user may book anyway (legitimate for two short calls back-to-back, or a panel that overlaps a 1:1). Pair the warning with the colliding `interview_label` so the user knows what they are choosing.
- **`scheduled_end` precedes `scheduled_start`.** Platform code `scheduled_start_before_end` rejects. Surface verbatim and ask the user to swap the timestamps.
- **`onsite` interview without `location`, or `video_call` / `phone_screen` without `meeting_url`.** Not platform-enforced (both fields are optional). The recipe should ask before submitting; an interview row missing both makes the calendar invitation downstream useless.
- **`application_id` belongs to a `cancelled` job opening.** The application's `job_opening_id` may resolve to a cancelled opening if the cancellation came after the application was filed. Warn the user; this is usually a mistake.
