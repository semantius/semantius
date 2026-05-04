---
name: applicant-tracking
description: >-
  Use this skill for anything involving the Applicant Tracking System, the
  in-house recruiting domain that runs requisitions, candidates, interviews,
  offers, and hires through a single funnel. Trigger when the user says:
  "open a requisition", "apply this candidate to the job", "move the
  application to on-site", "schedule a phone screen", "submit interview
  feedback", "extend an offer", "the candidate accepted, mark them hired",
  "reject this application", "add Sarah as the hiring manager", "what does
  the pipeline look like by stage", "who's on the hiring team for the senior
  backend role". Loads alongside `use-semantius`, which owns CLI install,
  PostgREST encoding, and cube query mechanics.
semantic_model: applicant_tracking
---

# Applicant Tracking System

This skill carries the domain map and the jobs-to-be-done for the
Applicant Tracking System. Platform mechanics, CLI install, env vars,
PostgREST URL-encoding, `sqlToRest`, cube `discover`/`validate`/`load`,
and schema-management tools, live in `use-semantius`. Assume it loads
alongside; do not re-explain CLI basics here.

If a task is purely about defining schema, managing permissions, or
running ad-hoc queries against tables you already know, call
`use-semantius` directly, going through this skill adds nothing.

**Auto-managed fields** (set by Semantius on every table; never include
in POST/PATCH bodies): `id`, `created_at`, `updated_at`. Every other
required field, including every `*_label` column on junction and
sub-entity tables (`application_label`, `document_label`,
`interview_label`, `feedback_label`, `offer_label`,
`team_member_label`), is **caller-populated** and must appear in the
POST body. The label-composition convention for each is given in its
JTBD below.

---

## Domain glossary

The hiring funnel runs **Job Opening → Job Application → Interview →
Interview Feedback → Offer → Hire**, with `Candidate` orbiting on the
side as a person who can have many applications over time.

| Concept | Table | Notes |
|---|---|---|
| Department | `departments` | Owns job openings; optional parent/child hierarchy |
| Job Opening | `job_openings` | A specific role being hired for; has its own draft/open/filled lifecycle |
| Application Stage | `application_stages` | Configurable global pipeline steps (sorted by `stage_order`, grouped by `stage_category`) |
| Candidate Source | `candidate_sources` | Where candidates and applications originate from |
| Candidate | `candidates` | A person in the talent pool, exists independently of any application |
| Job Application | `job_applications` | The central pipeline row: one candidate applying to one job, currently at one stage |
| Application Note | `application_notes` | Comment thread on an application |
| Interview | `interviews` | A scheduled interview event tied to one application |
| Interview Feedback | `interview_feedback` | One interviewer's scorecard for one interview |
| Offer | `offers` | A formal offer extended for an application |
| Candidate Document | `candidate_documents` | Resume / cover letter / portfolio attached to a candidate |
| Hiring Team Member | `hiring_team_members` | Junction: a user assigned to a job opening with a role |
| User | `users` | Recruiters, hiring managers, interviewers, coordinators (deduped against the Semantius built-in `users`) |

## Key enums

Only the enums that gate JTBDs are listed; full enum sets live in the
semantic model. Arrows mark the typical lifecycle path; `|` separates
terminal states.

- `job_openings.status`: `draft` → `open` → `on_hold` | `filled` | `closed` | `cancelled`
- `application_stages.stage_category`: `pre_screen`, `screening`, `interview`, `offer`, `hired`, `rejected`
- `job_applications.status`: `active` → `hired` | `rejected` | `withdrawn` | `on_hold`
- `job_applications.rejection_reason`: `not_qualified`, `withdrew`, `position_filled`, `no_show`, `salary_mismatch`, `location_mismatch`, `culture_fit`, `other`
- `interviews.status`: `scheduled` → `completed` | `cancelled` | `no_show` | `rescheduled`
- `interviews.interview_kind`: `phone_screen`, `video_call`, `onsite`, `technical`, `take_home`, `panel`, `final`, `reference_check`
- `interview_feedback.overall_rating`: `strong_yes`, `yes`, `lean_yes`, `lean_no`, `no`, `strong_no`
- `interview_feedback.recommendation`: `advance`, `hold`, `reject`
- `offers.status`: `draft` → `pending_approval` → `approved` → `sent` → `accepted` | `declined` | `rescinded` | `expired`
- `offers.candidate_response`: `pending`, `accepted`, `declined`, `no_response`
- `hiring_team_members.team_role`: `recruiter`, `hiring_manager`, `interviewer`, `coordinator`, `executive_sponsor`
- `candidates.candidate_status`: `active` → `hired` | `archived` | `do_not_contact`
- `application_notes.visibility`: `hiring_team`, `recruiter_only`, `public`

## Foreign-key cheatsheet

Only the FKs that JTBDs cross. Format: `child.field → parent.id` (delete
behavior in parens).

- `job_applications.candidate_id → candidates.id` (parent, cascade)
- `job_applications.job_opening_id → job_openings.id` (restrict; historical applications survive a job closure)
- `job_applications.current_stage_id → application_stages.id` (restrict; stages cannot be deleted while in use)
- `job_applications.assigned_recruiter_id → users.id` (clear)
- `job_applications.source_id → candidate_sources.id` (clear)
- `interviews.application_id → job_applications.id` (parent, cascade)
- `interviews.coordinator_user_id → users.id` (clear)
- `interview_feedback.interview_id → interviews.id` (parent, cascade)
- `interview_feedback.interviewer_user_id → users.id` (**restrict**: the interviewer cannot be deleted while feedback exists)
- `offers.application_id → job_applications.id` (**restrict**, *no DB-level uniqueness*: the schema does not stop you from creating a second active offer on the same application; the recipe must check for an existing one)
- `offers.approver_user_id → users.id` (clear)
- `hiring_team_members.job_opening_id → job_openings.id` (parent, cascade)
- `hiring_team_members.user_id → users.id` (parent, cascade)
- `application_notes.author_user_id → users.id` (**restrict**: a user with authored notes cannot be deleted)
- `candidate_documents.candidate_id → candidates.id` (parent, cascade)

**Unique columns** (409 on duplicate POST): `departments.department_name`,
`departments.department_code`, `job_openings.job_code`,
`application_stages.stage_name`, `candidate_sources.source_name`,
`candidates.email_address`, `users.email_address`.

**No DB-level uniqueness on the natural junction keys.** Neither
`hiring_team_members(job_opening_id, user_id, team_role)` nor
`offers(application_id)` is constrained. Recipes that would create one
must read first.

**Audit-logged tables** (Semantius writes the audit rows automatically;
recipes do not manage them): `job_openings`, `candidates`,
`job_applications`, `interview_feedback`, `offers`.

---

## Jobs to be done

### Open a job opening

**Triggers:** `open a requisition`, `publish the job for X`, `move the job from draft to open`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `job_opening_id` or `job_code` | yes | Resolve `job_code` to `id` first if the user passes the code |
| `opened_at` | yes | Set to today; never bake a literal date |

**Lookup convention.** Semantius adds a `search_vector` column to
searchable entities for full-text search across all text fields. Use it
whenever the user passes a name, title, code, etc., not a UUID:

```bash
# Resolve a job opening by anything the user typed (job title, code, etc.)
semantius call crud postgrestRequest '{"method":"GET","path":"/job_openings?search_vector=wfts(simple).<term>&select=id,job_title,job_code,status,headcount"}'
```

Use `wfts(simple).<term>` for fuzzy text searches, never `ilike` and
never `fts`, they bypass the search index and mismatch the platform
convention. `eq.<value>` is the right tool for known-exact values
(UUIDs, FK ids, status enums, unique columns like `job_code` or
`email_address`).

**Recipe:**

```bash
# 1. Resolve the job (skip if the user passed an id)
semantius call crud postgrestRequest '{"method":"GET","path":"/job_openings?search_vector=wfts(simple).<term>&select=id,job_title,status,hiring_manager_id"}'

# 2. Verify current status is `draft` before opening; refuse to "open" anything already open/filled/closed/cancelled

# 3. Open the requisition
semantius call crud postgrestRequest '{
  "method":"PATCH",
  "path":"/job_openings?id=eq.<id>",
  "body":{
    "status":"open",
    "opened_at":"<today, YYYY-MM-DD>"
  }
}'
```

`opened_at`: set to today's date at call time; do not copy the
placeholder.

**Validation:** `status=open` and `opened_at` is non-null on the row.

**Failure modes:**
- Current status is not `draft` (e.g. already `open`) → do nothing and
  tell the user; "open" is not a re-runnable transition.
- `hiring_manager_id` was not set on creation → `create_field`
  required-on-insert means the row could not have been created without
  it; if you somehow find a `draft` row with no manager, ask the user
  to assign one before opening rather than opening it blind.

---

### Apply a candidate to a job opening

**Triggers:** `apply this candidate to X`, `add Jane to the senior engineer pipeline`, `create an application`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `candidate_id` | yes | Look up by `email_address=eq.<email>` (unique) or `search_vector=wfts(simple).<name>` |
| `job_opening_id` | yes | Look up by `job_code=eq.<code>` or `search_vector=wfts(simple).<title>` |
| `current_stage_id` | yes | Resolve to the lowest-`stage_order` stage with `stage_category=eq.pre_screen` |
| `applied_at` | yes | Use the current ISO timestamp at call time |
| `source_id` | no | Lookup by `source_name=eq.<name>` if the user names one |
| `assigned_recruiter_id` | no | Lookup user by `email_address=eq.<email>` |

**Caller-populated label.** `job_applications.application_label` is
required on insert and not auto-derived. Compose it as
`"{candidate.full_name} -> {job_opening.job_title}"`. The recipe must
read both rows in step 1 to have the values to compose with.

**Recipe:**

```bash
# 1. Resolve candidate, job, and the entry stage in one round of lookups
semantius call crud postgrestRequest '{"method":"GET","path":"/candidates?email_address=eq.<email>&select=id,full_name,candidate_status"}'
semantius call crud postgrestRequest '{"method":"GET","path":"/job_openings?search_vector=wfts(simple).<title>&select=id,job_title,status"}'
semantius call crud postgrestRequest '{"method":"GET","path":"/application_stages?stage_category=eq.pre_screen&order=stage_order.asc&limit=1&select=id,stage_name"}'

# 2. Sanity-check: candidate.candidate_status is `active`, job.status is `open`

# 3. Create the application
semantius call crud postgrestRequest '{
  "method":"POST",
  "path":"/job_applications",
  "body":{
    "application_label":"<candidate.full_name> -> <job_opening.job_title>",
    "candidate_id":"<from step 1>",
    "job_opening_id":"<from step 1>",
    "current_stage_id":"<from step 1>",
    "status":"active",
    "applied_at":"<current ISO timestamp>",
    "source_id":"<optional>",
    "assigned_recruiter_id":"<optional>"
  }
}'
```

`applied_at`: set to the current ISO timestamp at call time; do not
copy the placeholder.

**Validation:** new row exists, `status=active`, `current_stage_id`
points at a `pre_screen` stage, `application_label` matches the
"candidate -> job" composition.

**Failure modes:**
- Job's `status` is not `open` (e.g. `draft` or `filled`) → ask the
  user whether to open the job first or pick a different one; do not
  silently apply against a closed job.
- Candidate's `candidate_status` is `do_not_contact` → refuse and
  surface the candidate to the user.
- The user names a stage that has no row in `application_stages` →
  ask which existing stage to use rather than guessing.

---

### Advance an application to the next stage

**Triggers:** `move the application to phone screen`, `advance Jane to on-site`, `set the stage to offer`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `application_id` | yes | Resolve via candidate + job if the user names them |
| Target stage | yes | Resolve to a row in `application_stages` |

**This is a DB-unguarded lifecycle gate.** Semantius accepts any
`current_stage_id` PATCH on `job_applications`; the rule that you only
move *forward* (or to a clearly-named recovery stage) is enforced
client-side. Always read the application's current stage before writing.

**Recipe:**

```bash
# 1. Read the application's current state
semantius call crud postgrestRequest '{"method":"GET","path":"/job_applications?id=eq.<id>&select=id,status,current_stage_id,application_label"}'

# 2. Read the current and target stages so you can compare stage_order
semantius call crud postgrestRequest '{"method":"GET","path":"/application_stages?id=in.(<current>,<target>)&select=id,stage_name,stage_order,stage_category"}'

# 3. Refuse if status is not `active` (a `hired`/`rejected`/`withdrawn` row should not change stage)
# 4. Refuse if target.stage_order < current.stage_order, unless the user explicitly asked to "move back"
# 5. Refuse if target.stage_category is `hired` or `rejected`, those flips belong to the hire / reject JTBDs (which set side-effect fields)

# 6. Advance
semantius call crud postgrestRequest '{
  "method":"PATCH",
  "path":"/job_applications?id=eq.<id>",
  "body":{"current_stage_id":"<target stage id>"}
}'
```

**Validation:** `current_stage_id` is the target; `status` is still
`active`; the audit trail shows the change (`job_applications` is
audit-logged, no extra write needed).

**Failure modes:**
- Target stage has `stage_category=hired` or `=rejected` → route the
  user to the hire-cascade or close-application JTBD; advancing without
  setting `hired_at` / `rejected_at` corrupts the funnel.
- Application `status` is terminal → refuse; ask the user whether they
  meant to re-open the application first.

---

### Schedule an interview

**Triggers:** `schedule a phone screen with Jane`, `book the on-site for X`, `set up a panel interview`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `application_id` | yes | Resolve via candidate + job if the user names them |
| `interview_kind` | yes | Pick from the enum (`phone_screen`, `onsite`, `technical`, `panel`, etc.) |
| `scheduled_start`, `scheduled_end` | yes | ISO timestamps; do not bake literal values |
| `coordinator_user_id` | no | Lookup by user email |
| `meeting_url` or `location` | no | URL for video, free-text for `onsite` |

**Caller-populated label.** `interviews.interview_label` must be
composed: `"{interview_kind label} for {candidate.full_name}"`, e.g.
`"Tech phone screen for Jane Doe"`. The kind is the enum value with
underscores replaced by spaces (e.g. `phone_screen` → "Phone screen").

**Recipe:**

```bash
# 1. Look up the application and the candidate it points at, so you can compose the label
semantius call crud postgrestRequest '{"method":"GET","path":"/job_applications?id=eq.<id>&select=id,application_label,status,candidate:candidate_id(full_name)"}'

# 2. Refuse if application.status is not `active`

# 3. Schedule
semantius call crud postgrestRequest '{
  "method":"POST",
  "path":"/interviews",
  "body":{
    "interview_label":"<kind in plain English> for <candidate.full_name>",
    "application_id":"<id>",
    "interview_kind":"phone_screen",
    "scheduled_start":"<start ISO timestamp>",
    "scheduled_end":"<end ISO timestamp>",
    "status":"scheduled",
    "meeting_url":"<optional>",
    "location":"<optional>",
    "coordinator_user_id":"<optional>"
  }
}'
```

`scheduled_start` / `scheduled_end`: provide real ISO timestamps at
call time; do not copy the placeholders.

**Validation:** row exists with `status=scheduled`; `scheduled_end >
scheduled_start`.

**Failure modes:**
- Application is not `active` → refuse; do not schedule interviews on
  hired/rejected/withdrawn pipelines.
- `interview_kind=onsite` with no `location` → fine technically, but
  ask the user; an on-site with no address is almost always a mistake.

---

### Submit interview feedback

**Triggers:** `submit my feedback for X`, `record the interviewer scorecard`, `mark feedback as submitted`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `interview_id` | yes | Resolve via application if the user names the candidate |
| `interviewer_user_id` | yes | The user submitting; lookup by email |
| `overall_rating`, `recommendation` | no in DB, **yes in practice** | Both should be filled before submission |
| `strengths`, `concerns`, `detailed_notes` | no | Free text |

**Paired write rule.** `is_submitted=true` and `submitted_at` must move
together: when a draft row goes to submitted, set `submitted_at` to the
current timestamp in the **same PATCH**. Setting `is_submitted=true`
without `submitted_at` leaves an inconsistent row that downstream
reports treat as "submitted but no time" and silently exclude.

**Caller-populated label.** Compose
`"{interviewer.display_name}, {interview_kind in plain English} for
{candidate.full_name}"`, e.g. `"Alex Kim, on-site for Jane Doe"`.

**Recipe (create-and-submit in one call):**

```bash
# 1. Look up the interview, its application, and the candidate, so you have the names for the label
semantius call crud postgrestRequest '{"method":"GET","path":"/interviews?id=eq.<id>&select=id,interview_kind,status,application:application_id(candidate:candidate_id(full_name))"}'

# 2. Look up the interviewer
semantius call crud postgrestRequest '{"method":"GET","path":"/users?email_address=eq.<email>&select=id,display_name"}'

# 3. Submit
semantius call crud postgrestRequest '{
  "method":"POST",
  "path":"/interview_feedback",
  "body":{
    "feedback_label":"<interviewer.display_name>, <kind in plain English> for <candidate.full_name>",
    "interview_id":"<id>",
    "interviewer_user_id":"<id>",
    "overall_rating":"yes",
    "recommendation":"advance",
    "strengths":"<text>",
    "concerns":"<text>",
    "detailed_notes":"<text>",
    "is_submitted":true,
    "submitted_at":"<current ISO timestamp>"
  }
}'
```

`submitted_at`: set to the current timestamp at call time; do not copy
the placeholder.

**Recipe (promote a draft):**

```bash
# Same paired write on PATCH
semantius call crud postgrestRequest '{
  "method":"PATCH",
  "path":"/interview_feedback?id=eq.<id>",
  "body":{"is_submitted":true,"submitted_at":"<current ISO timestamp>"}
}'
```

**Validation:** `is_submitted=true` AND `submitted_at` is non-null on
the row.

**Failure modes:**
- `is_submitted=true` with `submitted_at` null → reports treat the
  scorecard as missing; recover by PATCH-setting `submitted_at`.
- The interviewer is set on a row but is not on the
  `hiring_team_members` for that job opening → not blocked by the DB,
  but flag to the user; out-of-team feedback is unusual.

---

### Extend an offer

**Triggers:** `extend an offer to Jane`, `send the offer for X`, `approve and send the offer`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `application_id` | yes | The application this offer ties to |
| `base_salary`, `salary_currency` | yes | Currency is an ISO 4217 code (e.g. `USD`) |
| `approver_user_id` | yes when moving to `approved` | Lookup user by email |
| `start_date`, `bonus_target`, `equity_amount`, `offer_expires_at` | no | Fill if the user named them |

**This is a DB-unguarded multi-step lifecycle.**
`draft` → `pending_approval` → `approved` → `sent` is enforced
client-side. The schema accepts any value at any time; your job is to
read-before-write and to set the right side-effect field on each
transition.

**There is no DB-level uniqueness on `offers.application_id`.** Before
creating a fresh offer, read for an existing non-terminal one
(`status` not in `accepted`, `declined`, `rescinded`, `expired`) and
either PATCH that one or refuse and surface it to the user; never
silently create a parallel active offer.

**Caller-populated label.** Compose
`"Offer, {candidate.full_name}, {job_opening.job_title}"`, e.g.
`"Offer, Jane Doe, Senior Engineer"`.

**Recipe (create as draft):**

```bash
# 1. Look up the application, its candidate and job so you have names for the label
semantius call crud postgrestRequest '{"method":"GET","path":"/job_applications?id=eq.<id>&select=id,status,candidate:candidate_id(full_name),job:job_opening_id(job_title)"}'

# 2. Check for an existing non-terminal offer on this application
semantius call crud postgrestRequest '{"method":"GET","path":"/offers?application_id=eq.<id>&status=in.(draft,pending_approval,approved,sent)&select=id,status"}'
# If anything returns, stop and route to the existing offer; do not POST a second one.

# 3. Create as draft
semantius call crud postgrestRequest '{
  "method":"POST",
  "path":"/offers",
  "body":{
    "offer_label":"Offer, <candidate.full_name>, <job_opening.job_title>",
    "application_id":"<id>",
    "status":"draft",
    "base_salary":150000,
    "salary_currency":"USD",
    "candidate_response":"pending"
  }
}'
```

**Recipe (advance through approval and send):**

```bash
# Move to pending_approval (no side-effect field needed)
semantius call crud postgrestRequest '{
  "method":"PATCH","path":"/offers?id=eq.<id>",
  "body":{"status":"pending_approval"}
}'

# Approve: status + approver in the same PATCH
semantius call crud postgrestRequest '{
  "method":"PATCH","path":"/offers?id=eq.<id>",
  "body":{"status":"approved","approver_user_id":"<approver id>"}
}'

# Send: status + offer_extended_at in the same PATCH
semantius call crud postgrestRequest '{
  "method":"PATCH","path":"/offers?id=eq.<id>",
  "body":{"status":"sent","offer_extended_at":"<current ISO timestamp>"}
}'
```

`offer_extended_at`: set to the current timestamp at call time; do
not copy the placeholder.

**Validation:** for each transition, `status` matches and the paired
field (`approver_user_id` on approval, `offer_extended_at` on send) is
non-null.

**Failure modes:**
- A pre-existing non-terminal offer was missed → 200 OK creates a
  duplicate that downstream reports treat as parallel offers; recover
  by `rescinded`-flipping one of them.
- `approved` set without `approver_user_id` → reports cannot answer
  "who approved this"; PATCH to add the approver.
- `sent` set without `offer_extended_at` → time-to-offer metrics break;
  PATCH to add the timestamp.

---

### Record offer response and complete a hire (cascade)

**Triggers:** `the candidate accepted, mark them hired`, `Jane accepted the offer`, `record offer acceptance`, `decline the offer`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `offer_id` | yes | Resolve via application if the user names the candidate |
| Response | yes | `accepted` or `declined` |

**This is a Pattern C materialization.** Recording an offer
acceptance is not a single PATCH; it ripples across four tables:

1. `offers`: `status` and `candidate_response` flip together; set `responded_at`.
2. `job_applications`: on `accepted`, `status=hired`, set `hired_at`, set `current_stage_id` to the `hired`-category stage.
3. `candidates`: on `accepted`, `candidate_status=hired`.
4. `job_openings`: on `accepted`, count the opening's hires so far; if hires now equals `headcount`, flip the opening to `filled` and set `filled_at`.

The DB guards none of these; if you stop after step 1 the funnel
report says "offer accepted" but the candidate is still listed as
`active` with no hire date.

**Recipe (accepted branch, the full cascade):**

```bash
# 1. Resolve the offer + walk to its application, candidate, and job opening in one read
semantius call crud postgrestRequest '{"method":"GET","path":"/offers?id=eq.<id>&select=id,status,application:application_id(id,candidate_id,job_opening_id,current_stage_id),candidate:application_id(candidate:candidate_id(id,candidate_status))"}'
# (If the embedded select shape isn't supported on this deployment, fall back to four separate GETs.)

# 2. Find the `hired`-category stage
semantius call crud postgrestRequest '{"method":"GET","path":"/application_stages?stage_category=eq.hired&order=stage_order.asc&limit=1&select=id,stage_name"}'

# 3. Read the job opening's headcount and count its current hires
semantius call crud postgrestRequest '{"method":"GET","path":"/job_openings?id=eq.<job_opening_id>&select=id,headcount,status"}'
semantius call crud postgrestRequest '{"method":"GET","path":"/job_applications?job_opening_id=eq.<job_opening_id>&status=eq.hired&select=id"}'

# 4. PATCH the offer (status + candidate_response + responded_at, all in one call)
semantius call crud postgrestRequest '{
  "method":"PATCH","path":"/offers?id=eq.<offer_id>",
  "body":{"status":"accepted","candidate_response":"accepted","responded_at":"<current ISO timestamp>"}
}'

# 5. PATCH the application (status + hired_at + stage, all in one call)
semantius call crud postgrestRequest '{
  "method":"PATCH","path":"/job_applications?id=eq.<application_id>",
  "body":{"status":"hired","hired_at":"<current ISO timestamp>","current_stage_id":"<hired stage id>"}
}'

# 6. PATCH the candidate
semantius call crud postgrestRequest '{
  "method":"PATCH","path":"/candidates?id=eq.<candidate_id>",
  "body":{"candidate_status":"hired"}
}'

# 7. If (existing hires + 1) >= headcount, fill the opening
semantius call crud postgrestRequest '{
  "method":"PATCH","path":"/job_openings?id=eq.<job_opening_id>",
  "body":{"status":"filled","filled_at":"<today, YYYY-MM-DD>"}
}'
```

`responded_at`, `hired_at`, `filled_at`: set at call time; do not copy
the placeholders.

**Recipe (declined branch, no cascade):**

```bash
# Just the offer flip; the application stays active so the recruiter can decide whether to extend a revised offer or close the pipeline
semantius call crud postgrestRequest '{
  "method":"PATCH","path":"/offers?id=eq.<offer_id>",
  "body":{"status":"declined","candidate_response":"declined","responded_at":"<current ISO timestamp>"}
}'
```

After a `declined`, ask the user whether to also withdraw the
application, or hold it for a counter-offer.

**Validation (accepted branch):** all four (or five, if filling) PATCHes
returned 2xx; a follow-up read of the application shows `status=hired`
and `hired_at` set; the candidate shows `candidate_status=hired`.

**Failure modes:**
- A PATCH in the middle of the cascade fails → the funnel is now in a
  half-applied state; do not retry blindly. Read each row, identify
  which steps did not stick, and PATCH only those. Tell the user.
- Another offer on the same application is still `sent` (parallel
  active offer) → `rescind` it (`status=rescinded`) before completing
  the hire.
- Job opening already `filled` or `closed` when you go to fill it →
  do not re-PATCH; the previous fill is correct.

---

### Close an application as rejected or withdrawn

**Triggers:** `reject this application`, `Jane withdrew, close her application`, `decline the candidate with reason X`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `application_id` | yes | Resolve via candidate + job if the user names them |
| Outcome | yes | `rejected` (recruiter-side) or `withdrawn` (candidate-side) |
| `rejection_reason` | yes for `rejected` | Pick from the enum |

**Paired write rule.** `status` and the paired side-effect field
(`rejected_at`, plus `rejection_reason` for `rejected`) must move in
the same PATCH. Also flip `current_stage_id` to the
`rejected`-category stage so funnel reports route the row correctly.

**Recipe (reject):**

```bash
# 1. Resolve the rejected stage
semantius call crud postgrestRequest '{"method":"GET","path":"/application_stages?stage_category=eq.rejected&order=stage_order.asc&limit=1&select=id,stage_name"}'

# 2. Close the application in one PATCH
semantius call crud postgrestRequest '{
  "method":"PATCH","path":"/job_applications?id=eq.<application_id>",
  "body":{
    "status":"rejected",
    "rejection_reason":"not_qualified",
    "rejected_at":"<current ISO timestamp>",
    "current_stage_id":"<rejected stage id>"
  }
}'
```

**Recipe (withdrawn):**

```bash
# Same shape; status=withdrawn, no rejection_reason needed (set rejected_at as the close timestamp)
semantius call crud postgrestRequest '{
  "method":"PATCH","path":"/job_applications?id=eq.<application_id>",
  "body":{
    "status":"withdrawn",
    "rejected_at":"<current ISO timestamp>",
    "current_stage_id":"<rejected stage id>"
  }
}'
```

`rejected_at`: set at call time; do not copy the placeholder.

**Validation:** `status` matches; `rejected_at` is non-null;
`current_stage_id` resolves to a `stage_category=rejected` stage.

**Failure modes:**
- `status=rejected` set with no `rejection_reason` → funnel-reason
  reports drop the row; PATCH to add it.
- Application has a `sent`-status offer outstanding → ask before
  closing; the offer should be `rescinded` first or a parallel
  workflow is implied.

---

### Add or remove a hiring team member

**Triggers:** `add Sarah as the hiring manager for X`, `assign Alex as an interviewer on the senior backend role`, `remove Mark from the hiring team`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `job_opening_id` | yes | Lookup by `job_code` or fuzzy title |
| `user_id` | yes | Lookup user by email |
| `team_role` | yes | `recruiter`, `hiring_manager`, `interviewer`, `coordinator`, `executive_sponsor` |

**Junction without DB-level uniqueness.** The table does not constrain
`(job_opening_id, user_id, team_role)`. POSTing the same triple twice
creates a duplicate row that pollutes "who is on the team" lists.
Always read first.

**Caller-populated label.** Compose
`"{user.display_name}, {team_role in plain English}, {job_opening.job_title}"`,
e.g. `"Alex Kim, hiring manager, Senior Engineer"`.

**Recipe (add):**

```bash
# 1. Resolve the user, the job, and check for an existing assignment in one round
semantius call crud postgrestRequest '{"method":"GET","path":"/users?email_address=eq.<email>&select=id,display_name"}'
semantius call crud postgrestRequest '{"method":"GET","path":"/job_openings?job_code=eq.<code>&select=id,job_title"}'
semantius call crud postgrestRequest '{"method":"GET","path":"/hiring_team_members?job_opening_id=eq.<job>&user_id=eq.<user>&team_role=eq.<role>&select=id,is_active"}'

# 2a. If a row already exists and is_active=true, do nothing; tell the user.
# 2b. If a row exists with is_active=false, re-activate instead of creating a new one:
semantius call crud postgrestRequest '{
  "method":"PATCH","path":"/hiring_team_members?id=eq.<existing id>",
  "body":{"is_active":true,"assigned_at":"<current ISO timestamp>"}
}'
# 2c. Otherwise, create:
semantius call crud postgrestRequest '{
  "method":"POST","path":"/hiring_team_members",
  "body":{
    "team_member_label":"<user.display_name>, <role in plain English>, <job_opening.job_title>",
    "job_opening_id":"<job id>",
    "user_id":"<user id>",
    "team_role":"interviewer",
    "assigned_at":"<current ISO timestamp>",
    "is_active":true
  }
}'
```

**Recipe (remove via soft-deactivate, the preferred path):**

```bash
# Set is_active=false; preserves history of who was on the team and when
semantius call crud postgrestRequest '{
  "method":"PATCH","path":"/hiring_team_members?id=eq.<id>",
  "body":{"is_active":false}
}'
```

`assigned_at`: set at call time; do not copy the placeholder.

**Validation (add):** exactly one row exists for the
`(job_opening_id, user_id, team_role)` triple, and `is_active=true`.

**Failure modes:**
- A POST without the read-first → the table accepts a duplicate. Recover
  by PATCH-ing one of the duplicates to `is_active=false` (not a hard
  delete; the audit-friendly cleanup).
- The user being added is not in `users` yet → create the user first
  (`use-semantius` handles user creation); do not invent a fake id.

---

## Common queries

These are starting points, not contracts. Cube schema names drift when
the model is regenerated, so always run `cube discover '{}'` first and
map the dimension and measure names below against `discover`'s output.
The cube name is usually the entity's table name with the first letter
capitalized (e.g. `JobApplications`), but verify.

```bash
# Always first
semantius call cube discover '{}'
```

```bash
# Open requisitions by department and status
semantius call cube load '{"query":{
  "measures":["JobOpenings.count"],
  "dimensions":["Departments.department_name","JobOpenings.status"],
  "filters":[{"member":"JobOpenings.status","operator":"equals","values":["open","draft","on_hold"]}],
  "order":{"JobOpenings.count":"desc"}
}}'
```

```bash
# Active pipeline by stage (how many applications sit at each stage right now)
semantius call cube load '{"query":{
  "measures":["JobApplications.count"],
  "dimensions":["ApplicationStages.stage_name","ApplicationStages.stage_order"],
  "filters":[{"member":"JobApplications.status","operator":"equals","values":["active"]}],
  "order":{"ApplicationStages.stage_order":"asc"}
}}'
```

```bash
# Time-to-hire trend (avg days from applied_at to hired_at, by hire month)
# Read the dateFilteringGuide that discover returns; the avg_days_to_hire measure name
# is illustrative, check discover output for the real one or compute via a custom measure.
semantius call cube load '{"query":{
  "measures":["JobApplications.avg_days_to_hire"],
  "timeDimensions":[{"dimension":"JobApplications.hired_at","granularity":"month","dateRange":"last 12 months"}]
}}'
```

```bash
# Source effectiveness: hires by candidate source over the last year
semantius call cube load '{"query":{
  "measures":["JobApplications.count"],
  "dimensions":["CandidateSources.source_name","CandidateSources.source_type"],
  "filters":[
    {"member":"JobApplications.status","operator":"equals","values":["hired"]},
    {"member":"JobApplications.hired_at","operator":"inDateRange","values":["last 12 months"]}
  ],
  "order":{"JobApplications.count":"desc"}
}}'
```

```bash
# Interviewer scorecard distribution: how each interviewer recommends across submitted feedback
semantius call cube load '{"query":{
  "measures":["InterviewFeedback.count"],
  "dimensions":["Users.display_name","InterviewFeedback.recommendation"],
  "filters":[{"member":"InterviewFeedback.is_submitted","operator":"equals","values":["true"]}],
  "order":{"Users.display_name":"asc"}
}}'
```

---

## Guardrails

- Never PATCH `job_applications.current_stage_id` to a stage with
  `stage_category=hired` or `=rejected` directly; route to the
  hire-cascade or close-application JTBDs so the paired side-effect
  fields (`hired_at`, `rejected_at`, `rejection_reason`) get set.
- Never PATCH `offers.status` to `sent`, `approved`, or `accepted`
  without setting the paired field in the same call
  (`offer_extended_at`, `approver_user_id`, `responded_at`).
- Never POST to `offers` for an `application_id` that already has a
  non-terminal offer; read first, PATCH or rescind the existing one.
- Never POST to `hiring_team_members` for a `(job_opening_id, user_id,
  team_role)` triple that already exists; reactivate via
  `is_active=true` instead.
- Never set `interview_feedback.is_submitted=true` without
  `submitted_at` in the same call.
- Lookups for human-friendly identifiers (names, titles, codes) use
  `search_vector=wfts(simple).<term>`; never `ilike` and never `fts`.
- Audit-logged tables (`job_openings`, `candidates`, `job_applications`,
  `interview_feedback`, `offers`) write their own audit rows; do not
  hand-write to any audit table.
- `users` may already exist as a Semantius built-in in this
  deployment; treat it as the authoritative table and reference it
  rather than creating a parallel one.

## What this skill does NOT do

- Schema changes, use `use-semantius` directly.
- RBAC / permissions, use `use-semantius` directly.
- One-off seed data, write a script, do not bake it into a JTBD.
- Per-job pipelines: stages are global in this model. If recruiters
  ask for a different pipeline per job family, that is a model change.
- Structured candidate skills taxonomy: candidates only have a
  free-text `notes` field; no `candidate_skills` join exists yet.
- Configurable rejection reasons: the values are an enum, not a
  lookup table; new reasons require a model change.
- Application activity log (emails, calendar events): no
  `application_activities` table exists; communication history is not
  modeled.
- Multi-step offer approval workflow: only a single
  `approver_user_id` and `pending_approval` status; chained approvers
  are not modeled.
- GDPR consent and retention dates on candidates: no
  `consent_given_at` or `retention_expires_at` fields; deletion is
  the only erasure path (cascade via `candidate_id`).
