---
name: ats
description: >-
  Use this skill for anything involving ATS (Applicant Tracking System), the
  in-house domain that tracks job requisitions, candidates, applications, the
  pipeline of stages, interviews, scorecards, offers, and the hiring team
  assigned to each opening. Trigger when the user wants to submit a job
  application, move an application to the next stage, reject an application
  with a reason, schedule an interview, submit interview feedback, extend an
  offer, record offer acceptance and the resulting hire, transition a
  requisition (open, put on hold, fill, cancel), assign a hiring team
  member, or read the audit trail behind a hiring decision.
semantic_model: ats
---

# ATS

This skill carries the domain map and the jobs-to-be-done for the ATS
(Applicant Tracking System) domain. Platform mechanics (CLI install, env
vars, PostgREST URL-encoding, `sqlToRest`, cube `discover` / `validate` /
`load`, schema-management tools) live in `use-semantius`. Assume it
loads alongside; do not re-explain CLI basics here.

If a task is purely about defining schema, managing permissions, or
running ad-hoc queries against tables you already know, call
`use-semantius` directly, going through this skill adds nothing.

**Auto-managed fields** (set by Semantius on every table; never include
in POST/PATCH bodies): `id`, `created_at`, `updated_at`. The
`label_column` field is **required on insert and caller-populated** on
every entity unless the model explicitly says it is auto-derived. In
this domain that includes `job_applications.application_label`,
`candidate_documents.document_label`, `application_notes.note_subject`,
`interviews.interview_label`, `interview_feedback.feedback_label`,
`offers.offer_label`, and `hiring_team_members.team_member_label`. Each
JTBD that touches one of those entities documents how to compose the
value; do not omit `*_label` / `*_subject` from POST bodies.

**Platform-enforced invariants** (entity-level `validation_rules`
triggered on every INSERT/UPDATE; the platform rejects writes that
violate them with `{ "errors": [{ "code", "message" }, ...] }`. The
recipes here do NOT pre-validate these; they surface the platform's
error to the user verbatim if the write fails):

- `departments` rule `parent_not_self`: A department cannot reference itself as its parent. Why: a department's parent must be a different row; self-referential parents create degenerate hierarchies.
- `job_openings` rule `headcount_positive`: Headcount must be at least 1. Why: a requisition opens to hire at least one person; zero-headcount reqs are meaningless.
- `job_openings` rule `salary_min_non_negative`: Salary minimum must be at least 0.
- `job_openings` rule `salary_max_non_negative`: Salary maximum must be at least 0.
- `job_openings` rule `salary_band_ordered`: Salary minimum cannot exceed salary maximum. Why: when both ends of the salary band are set, the minimum must not exceed the maximum.
- `job_openings` rule `opened_before_filled`: Filled date cannot precede opened date. Why: a requisition must be opened before it can be filled.
- `job_openings` rule `opened_before_target_start`: Target start date cannot precede opened date.
- `job_openings` rule `filled_status_requires_filled_at`: A filled requisition must have a filled date. Why: once a requisition reaches the `filled` status, the fill date is required for reporting and audit.
- `job_openings` rule `non_draft_requires_opened_at`: A requisition that has left draft must have an opened date. Why: any non-draft status implies the requisition has been opened, so the opened date is required.
- `job_applications` rule `rejected_status_requires_rejected_at`: A rejected application must have a rejected date.
- `job_applications` rule `hired_status_requires_hired_at`: A hired application must have a hired date. Why: the hired timestamp is required for downstream onboarding and HRIS handoff.
- `job_applications` rule `rejection_reason_only_when_rejected`: Rejection reason can only be set when status is rejected. Why: a rejection reason has no meaning on an active, hired, withdrawn, or on-hold application.
- `job_applications` rule `applied_before_rejected`: Rejected date cannot precede applied date.
- `job_applications` rule `applied_before_hired`: Hired date cannot precede applied date.
- `interviews` rule `scheduled_start_before_end`: Scheduled end cannot precede scheduled start.
- `interview_feedback` rule `submitted_at_required_when_submitted`: A submitted scorecard must have a submitted_at timestamp.
- `interview_feedback` rule `submitted_at_only_when_submitted`: submitted_at can only be set when the scorecard is submitted.
- `offers` rule `base_salary_non_negative`: Base salary must be at least 0.
- `offers` rule `bonus_target_non_negative`: Bonus target must be at least 0.
- `offers` rule `post_draft_status_requires_extended_at`: Sent or completed offers must have an offer_extended_at timestamp.
- `offers` rule `extended_at_only_when_post_draft`: offer_extended_at can only be set once the offer is sent or further along.
- `offers` rule `responded_at_required_when_responded`: Responded offers must have a responded_at timestamp.
- `offers` rule `responded_at_only_when_responded`: responded_at can only be set when the candidate has responded.
- `offers` rule `extended_before_expires`: offer_expires_at cannot precede offer_extended_at.
- `offers` rule `extended_before_responded`: responded_at cannot precede offer_extended_at.

---

## Domain glossary

| Concept | Table | Notes |
|---|---|---|
| User | `users` | System users: recruiters, hiring managers, interviewers, coordinators |
| Department | `departments` | Org units that own job openings; supports parent-child hierarchy |
| Job Opening | `job_openings` | A specific role being hired for, with status, headcount, hiring team |
| Application Stage | `application_stages` | Pipeline steps (e.g. `New`, `Phone Screen`, `Onsite`, `Offer`); shared globally |
| Candidate Source | `candidate_sources` | Where a candidate or application came from (job board, referral, agency, ...) |
| Candidate | `candidates` | A person in the talent pool; exists independently of any specific application |
| Job Application | `job_applications` | Central pipeline record: a candidate applied to one opening, currently at one stage |
| Candidate Document | `candidate_documents` | Resume, cover letter, portfolio, work sample attached to a candidate |
| Application Note | `application_notes` | Note/comment thread on an application; visibility-scoped |
| Interview | `interviews` | Scheduled interview event tied to one application |
| Interview Feedback | `interview_feedback` | One interviewer's scorecard for one interview; rating + recommendation |
| Offer | `offers` | A formal offer extended to a candidate for one application |
| Hiring Team Member | `hiring_team_members` | Junction: a user assigned to a job opening with a specific role |

## Key enums

- `job_openings.status`: `draft` -> `open` -> `on_hold` | `filled` | `closed` | `cancelled` (treated as reversible per §7.2; no DB transition rule)
- `job_openings.employment_type`: `full_time` | `part_time` | `contract` | `internship` | `temporary`
- `job_openings.work_arrangement`: `onsite` | `remote` | `hybrid`
- `application_stages.stage_category`: `pre_screen` -> `screening` -> `interview` -> `offer` -> `hired` | `rejected`
- `candidate_sources.source_type`: `job_board` | `referral` | `agency` | `inbound` | `sourced` | `social_media` | `career_site` | `event` | `other`
- `candidates.candidate_status`: `active` -> `hired` | `archived` | `do_not_contact`
- `job_applications.status`: `active` -> `hired` | `rejected` | `withdrawn` | `on_hold` (reversible)
- `job_applications.rejection_reason`: `not_qualified` | `withdrew` | `position_filled` | `no_show` | `salary_mismatch` | `location_mismatch` | `culture_fit` | `other`
- `candidate_documents.document_type`: `resume` | `cover_letter` | `portfolio` | `work_sample` | `certification` | `reference_letter` | `other`
- `application_notes.visibility`: `hiring_team` | `recruiter_only` | `public`
- `interviews.interview_kind`: `phone_screen` | `video_call` | `onsite` | `technical` | `take_home` | `panel` | `final` | `reference_check`
- `interviews.status`: `scheduled` -> `completed` | `cancelled` | `no_show` | `rescheduled`
- `interview_feedback.overall_rating`: `strong_yes` | `yes` | `lean_yes` | `lean_no` | `no` | `strong_no`
- `interview_feedback.recommendation`: `advance` | `hold` | `reject`
- `offers.status`: `draft` -> `pending_approval` -> `approved` -> `sent` -> `accepted` | `declined` | `rescinded` | `expired` (reversible)
- `offers.candidate_response`: `pending` -> `accepted` | `declined` | `no_response`
- `hiring_team_members.team_role`: `recruiter` | `hiring_manager` | `interviewer` | `coordinator` | `executive_sponsor`

## When the runtime disagrees with the recipe

The FK shape and audit-logging facts in each JTBD's reference file
are baked in at skill-generation time. The live schema can drift,
admins can add a unique index, drop an FK, or toggle audit-logging
on a table without regenerating this skill. The recipes are not
self-correcting on their own, but the agent has an escape hatch.

When a recipe gets a `409 Conflict`, `422 Unprocessable Entity`, or
any other write failure the JTBD's reference file did not predict,
the recovery move is **read the live schema, then decide**:

```bash
semantius call crud read_field '{"filters": "entity=eq.<entity_id>"}'
semantius call crud read_field '{"filters": "entity=eq.<entity_id>,name=eq.<field_name>"}'
```

If the live shape contradicts the recipe's assumption (e.g. a unique
constraint exists where the recipe expected a free-form junction),
abort with a clear stderr message naming the drift; do not silently
"fix it up" with extra writes. Then surface to the user that the
skill is out of date and recommend regenerating via
`semantius-skill-maker`.

## Lookup convention

Semantius adds a `search_vector` column to searchable entities for
full-text search across all text fields. Use it whenever the user
passes a name, title, email, or description, not a UUID:

```bash
semantius call crud postgrestRequest '{"method":"GET","path":"/<table>?search_vector=wfts(simple).<term>&select=id,<label_column>"}'
```

Use `wfts(simple).<term>` for fuzzy text searches; never `ilike` and
never `fts`, they bypass the search index and mismatch the platform
convention.

Field-equality (`<column>=eq.<value>`) is the right tool for a
*different* job: filtering on a known-exact value. Use it for UUIDs,
FK ids, status enums, and unique columns whose values the caller
already knows verbatim. In this domain that includes
`users.email_address`, `candidates.email_address`,
`departments.department_code`, `job_openings.job_code`,
`application_stages.stage_name`, `application_stages.stage_order`,
`candidate_sources.source_name`, and `departments.department_name`.

If a lookup returns more than one row, present the candidates and
ask. If zero, ask the user to clarify rather than guessing.

## Timestamps in recipe bodies

Every `*_at` field, `*_date` field, or other moment-of-action value in
a recipe body is a placeholder the calling agent fills at call time,
not a literal copied from the example. The Recipe templates use
`<current ISO timestamp>` and `<today's date, YYYY-MM-DD>`; do not
copy those strings into a real call. This applies in SKILL.md, in
every reference file, in the Common queries appendix, and in any
script the calling agent invokes.

---

## Jobs to be done

### Submit a job application

**Triggers:** `apply Jane Doe to the Senior Engineer opening`, `submit a new application for ENG-2026-014`, `Bob applied to the open SDR role`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| candidate identifier | yes | `email_address` (`candidates.email_address=eq.<email>`) preferred; full name (`search_vector=wfts(simple).<name>`) accepted |
| job opening | yes | `job_code` (`job_openings.job_code=eq.<code>`) preferred; job title (`search_vector=wfts(simple).<title>`) accepted |
| candidate fields when creating | conditional | `full_name` required; `email_address`, `phone_number`, `linkedin_url`, `current_employer`, `current_job_title`, `location_city`, `location_country` optional |
| `source_id` | no | Resolved from `candidate_sources.source_name=eq.<name>`; defaults to inheriting the candidate's source |
| `assigned_recruiter_id` | no | Defaults to the opening's `recruiter_id` |

**Recipe:** see [`references/submit-application.md`](references/submit-application.md).

**Validation:** the new `job_applications` row exists with `status=active`, `current_stage_id` resolved to the first active stage by `stage_order`, `applied_at` set, and `application_label` matches the composition rule.

**Failure modes:**
- Job opening status not in `open` -> recipe refuses with a clear message; ask the user whether to apply against a `draft`/`on_hold`/`closed`/`cancelled` opening anyway (rare; usually a mistake).
- Candidate already has an `active` application against the same opening -> recipe refuses; tell the user the existing application id and ask whether to advance the existing one instead.

---

### Move application to next stage

**Triggers:** `move Jane to Phone Screen`, `advance the SDR applicant to Onsite`, `set Bob's stage to Final`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| application identifier | yes | Pair of (candidate name or email, job code or title); resolved to one application |
| target stage | yes | `application_stages.stage_name=eq.<name>` (case-sensitive exact match) |

**Recipe:** run `scripts/move-application-stage.sh <candidate-email-or-name> <job-code-or-title> <stage-name>`. Exit `0` on success, `1` on usage / unresolved lookup, `2` on platform error.

**Validation:** the target application's `current_stage_id` equals the resolved `application_stages.id`; `status` remains `active`.

**Failure modes:**
- Multiple applications match the (candidate, job) pair -> script exits 1 with the candidate / job pair the agent should ask the user to disambiguate.
- Application is not `active` (already `hired`/`rejected`/`withdrawn`/`on_hold`) -> script exits 1; the user should reopen the application via use-semantius before moving stages.

---

### Reject an application

**Triggers:** `reject Jane's application, salary mismatch`, `decline the SDR candidate, not qualified`, `pass on Bob, position filled`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| application identifier | yes | Pair of (candidate name or email, job code or title) |
| `rejection_reason` | yes | One of `not_qualified`, `withdrew`, `position_filled`, `no_show`, `salary_mismatch`, `location_mismatch`, `culture_fit`, `other` |

**Recipe:** run `scripts/reject-application.sh <candidate-email-or-name> <job-code-or-title> <rejection_reason>`. Exit `0` on success, `1` on usage / unresolved lookup, `2` on platform error.

**Validation:** application's `status=rejected`, `rejected_at` set, `rejection_reason` set.

**Failure modes:**
- Application status was already terminal (`hired`, `rejected`, `withdrawn`) -> script exits 1; the user should review the existing terminal state instead of overwriting it.
- Platform code `rejection_reason_only_when_rejected` -> the script never sets the reason without flipping status, so this only fires if the live schema has drifted; surface verbatim and abort.

---

### Schedule an interview

**Triggers:** `schedule a phone screen for Jane on Tuesday`, `book a panel with Bob for the SDR onsite`, `set up a final interview for the Senior Engineer applicant`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| application identifier | yes | Pair of (candidate name or email, job code or title); fuzzy lookups may need user disambiguation |
| `interview_kind` | yes | One of `phone_screen`, `video_call`, `onsite`, `technical`, `take_home`, `panel`, `final`, `reference_check` |
| `scheduled_start` / `scheduled_end` | yes | Both required; `scheduled_end` must follow `scheduled_start` |
| `location` or `meeting_url` | conditional | `location` for `onsite`; `meeting_url` for `video_call`/`phone_screen` |
| `coordinator_user_id` | no | Resolved from coordinator email |

**Recipe:** see [`references/schedule-interview.md`](references/schedule-interview.md).

**Validation:** new `interviews` row with `status=scheduled`, `interview_label` matches the composition rule, FKs resolve.

**Failure modes:**
- Multiple matching applications -> reference walks the user through disambiguation before any write.
- Conflicting interview already scheduled in the same window for the same coordinator/interviewer -> not enforced by the platform; the recipe surfaces the overlap and asks before booking.

---

### Submit interview feedback

**Triggers:** `submit my feedback for Jane's onsite, strong yes`, `record the panel scorecard for Bob`, `save Alex Kim's feedback as draft, leaning yes`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| interview identifier | yes | Pair of (candidate name or email, interview kind), or `interview_label` exact match |
| interviewer | yes | `users.email_address=eq.<email>` preferred; defaults to the current user when known |
| `overall_rating` | yes (when submitting) | `strong_yes` | `yes` | `lean_yes` | `lean_no` | `no` | `strong_no` |
| `recommendation` | yes (when submitting) | `advance` | `hold` | `reject` |
| `strengths`, `concerns`, `detailed_notes` | no | Plain text |
| submit-or-draft | yes | `submit` flips `is_submitted=true` + sets `submitted_at`; `draft` leaves them as-is |

**Recipe:** run `scripts/submit-feedback.sh <candidate-email-or-name> <interview-kind> <interviewer-email> <submit|draft> [rating] [recommendation]`. Exit `0` on success, `1` on usage / unresolved lookup, `2` on platform error.

**Validation:** `interview_feedback` row exists; when `submit`, `is_submitted=true` and `submitted_at` is set in the same write.

**Failure modes:**
- Interviewer not on `hiring_team_members` for the interview's job opening -> not enforced by the platform; recipe warns but proceeds (interviewers are sometimes added ad-hoc).
- Multiple `interviews` rows match the (candidate, kind) pair -> script exits 1; the agent should ask the user to specify the date or pass `interview_label` directly.

---

### Extend an offer

**Triggers:** `draft an offer for Jane, $180k base, $20k bonus`, `send the offer to Bob`, `move the SDR offer to pending approval`, `mark the Senior Engineer offer approved by Sam`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| application identifier | yes | Pair of (candidate name or email, job code or title) |
| target status | yes | One of `draft`, `pending_approval`, `approved`, `sent` |
| `base_salary`, `salary_currency` | yes (on draft) | Both required when creating the offer |
| `bonus_target`, `equity_amount`, `start_date`, `offer_expires_at` | no | Optional; equity is free-text |
| `approver_user_id` | required for `approved` | Resolved from approver email |
| `offer_extended_at` | required for `sent` | Set to current ISO timestamp at the same write that flips status to `sent` |

**Recipe:** see [`references/extend-offer.md`](references/extend-offer.md).

**Validation:** offer row at the requested status; for `sent`, `offer_extended_at` is set in the same call; for `approved`, `approver_user_id` is set.

**Failure modes:**
- Platform code `extended_at_only_when_post_draft` -> the recipe surfaces the rejection verbatim; the agent must flip status to `sent` (or further) in the same write that sets `offer_extended_at`.
- Application already has an active offer (`status` in `pending_approval`/`approved`/`sent`/`accepted`) -> not DB-enforced (an application "typically" has at most one active offer per §3.12); the recipe asks the user before extending a parallel offer.

---

### Record offer acceptance and hire

**Triggers:** `Jane accepted the offer`, `Bob declined the SDR offer`, `record the candidate's acceptance and hire her`, `Senior Engineer offer expired without response`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| application identifier | yes | Pair of (candidate name or email, job code or title) |
| candidate response | yes | One of `accepted`, `declined`, `no_response` (drives offer + application terminal state) |
| `responded_at` | yes | Current ISO timestamp at call time |

**Recipe:** run `scripts/record-offer-response.sh <candidate-email-or-name> <job-code-or-title> <accepted|declined|no_response>`. Exit `0` on success, `1` on usage / unresolved lookup, `2` on platform error.

**Validation:** `offers.candidate_response` matches input, `responded_at` set, `offers.status` reflects response (`accepted`/`declined` -> matching status; `no_response` -> `expired`); when `accepted`, `job_applications.status=hired` with `hired_at` set, and the candidate's `candidate_status=hired`.

**Failure modes:**
- The script does NOT auto-fill the requisition. Decreasing requisition headcount or flipping `job_openings.status=filled` is a separate JTBD; the script tells the user how many hires the opening still needs.
- Platform code `responded_at_required_when_responded` -> the script always sets the timestamp; this only fires on schema drift.

---

### Transition a requisition

**Triggers:** `open the Senior Engineer req`, `put ENG-2026-014 on hold`, `mark the SDR opening filled`, `cancel the closed-loss requisition`, `close the open Sales Lead req`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| job opening | yes | `job_code` preferred; job title accepted |
| target status | yes | One of `open`, `on_hold`, `filled`, `closed`, `cancelled` |
| `opened_at` | required for `open` from `draft` | Defaults to today's date |
| `filled_at` | required for `filled` | Defaults to today's date |
| `target_start_date` | optional on `open` | Set in the same call when known |

**Recipe:** run `scripts/transition-requisition.sh <job-code-or-title> <open|on_hold|filled|closed|cancelled> [yyyy-mm-dd]`. Exit `0` on success, `1` on usage / unresolved lookup, `2` on platform error.

**Validation:** `job_openings.status` matches target; `opened_at` is set whenever status leaves `draft`; `filled_at` is set when status becomes `filled`.

**Failure modes:**
- Platform code `non_draft_requires_opened_at` -> script always pairs the status flip with `opened_at` when transitioning out of `draft`; surfaces verbatim only on drift.
- Platform code `filled_status_requires_filled_at` -> same; pair the date.
- Platform code `opened_before_filled` -> if the user passes a fill date earlier than `opened_at`, the platform rejects the write; surface verbatim and ask the user to correct the date.

---

### Assign hiring team member

**Triggers:** `add Alex as interviewer on the Senior Engineer req`, `make Sam the hiring manager for ENG-2026-014`, `assign me as recruiter on the SDR opening`, `remove Pat from the hiring team`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| job opening | yes | `job_code` or job title |
| user | yes | `users.email_address=eq.<email>` preferred |
| `team_role` | yes | One of `recruiter`, `hiring_manager`, `interviewer`, `coordinator`, `executive_sponsor` |
| add or remove | yes | `add` POSTs / reactivates an `is_active=true` row; `remove` flips `is_active=false` so audit history survives |

**Recipe:** run `scripts/assign-hiring-team-member.sh <job-code-or-title> <user-email> <team_role> <add|remove>`. Exit `0` on success, `1` on usage / unresolved lookup, `2` on platform error.

**Validation:** for `add`, an `is_active=true` row exists for the (job_opening_id, user_id, team_role) triple; for `remove`, the matching row is `is_active=false`.

**Failure modes:**
- The (job_opening_id, user_id, team_role) triple has **no DB-level unique constraint**, so the script must read first to avoid duplicates. If the live schema has been hardened with a unique index, the platform's 409 surfaces and the script exits 2; surface to the user and recommend regenerating.
- `team_role=hiring_manager` on the junction does NOT update the opening's summary `hiring_manager_id`. Those two fields are independent (per §3.13); the script only writes the junction.

---

### Read decision audit trail

**Triggers:** `who changed Jane's offer status`, `when did the SDR application get rejected`, `show the audit trail for ENG-2026-014`, `why did Bob's salary band change`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| target entity | yes | One of `job_openings`, `candidates`, `job_applications`, `interview_feedback`, `offers` (these are the only audit-logged tables in this domain) |
| target row identifier | yes | Resolved to the row's `id` via the same lookup conventions as other JTBDs |
| time window | no | Defaults to all history |

**Recipe:** see [`references/read-audit-trail.md`](references/read-audit-trail.md).

**Validation:** the returned audit rows reference the resolved entity row; the changed-fields summary names columns that exist on the target entity in the current schema.

**Failure modes:**
- Target entity not in the audit-logged set (e.g. `users`, `interviews`) -> recipe refuses; tell the user the audit trail does not exist and offer the closest audit-logged neighbor (`job_applications` for an interview-related question).
- Audit endpoint shape may vary by Semantius version; if the call shape in the reference fails, fall back to the audit-trail patterns documented in `use-semantius` `references/crud-tools.md`.

---

## Common queries

Always run `cube discover '{}'` first to refresh the schema. Match the
dimension and measure names below against what `discover` returns;
field names drift when the model is regenerated, and `discover` is the
source of truth at query time.

```bash
# Pipeline by stage: count of active applications grouped by current stage
semantius call cube load '{"query":{
  "measures":["job_applications.count"],
  "dimensions":["application_stages.stage_name","application_stages.stage_order"],
  "filters":[{"member":"job_applications.status","operator":"equals","values":["active"]}],
  "order":{"application_stages.stage_order":"asc"}
}}'
```

```bash
# Source ROI: hire conversion rate by candidate source
semantius call cube load '{"query":{
  "measures":["job_applications.count"],
  "dimensions":["candidate_sources.source_name","job_applications.status"],
  "order":{"job_applications.count":"desc"}
}}'
```

```bash
# Time-to-hire: average days from applied_at to hired_at, by department
semantius call cube load '{"query":{
  "measures":["job_applications.avg_days_to_hire"],
  "dimensions":["departments.department_name"],
  "filters":[{"member":"job_applications.status","operator":"equals","values":["hired"]}],
  "order":{"job_applications.avg_days_to_hire":"desc"}
}}'
```

```bash
# Open requisitions by department
semantius call cube load '{"query":{
  "measures":["job_openings.count","job_openings.sum_headcount"],
  "dimensions":["departments.department_name"],
  "filters":[{"member":"job_openings.status","operator":"equals","values":["open"]}],
  "order":{"job_openings.sum_headcount":"desc"}
}}'
```

```bash
# Interviewer load: feedback count per interviewer over a rolling 30-day window
semantius call cube load '{"query":{
  "measures":["interview_feedback.count"],
  "dimensions":["users.display_name"],
  "timeDimensions":[{"dimension":"interview_feedback.submitted_at","dateRange":"last 30 days","granularity":"day"}],
  "filters":[{"member":"interview_feedback.is_submitted","operator":"equals","values":["true"]}],
  "order":{"interview_feedback.count":"desc"}
}}'
```

If `discover` reveals that `job_applications.avg_days_to_hire` (or any
other measure named here) is not defined as a measure in the current
schema, fall back to a `postgrestRequest` against the underlying
table and compute the aggregate client-side, do not invent measure
names.

---

## Guardrails

- Never POST to `users` from this skill. The `users` table is shared with HRIS / Identity & Access; managing users is out of scope. Resolve user FKs by `email_address=eq.<email>`.
- Never PATCH `job_applications.status` directly to `hired` or `rejected` without setting the paired timestamp (`hired_at` / `rejected_at`) and, for rejections, `rejection_reason` in the same call. The platform rejects the unpaired write.
- Never PATCH `offers.status` to `sent` (or any post-draft status) without setting `offer_extended_at` in the same call; same for `responded_at` when flipping `candidate_response` away from `pending`.
- Never PATCH `job_openings.status` away from `draft` without setting `opened_at` in the same call; never to `filled` without `filled_at`.
- Cancel-a-requisition does NOT cascade-reject its applications. Active applications survive a `cancelled` opening; recruiters typically reject them with `rejection_reason=position_filled` or `withdrew` afterward, one by one or via a follow-up sweep.
- `hiring_team_members` is the canonical hiring-team list. The summary `hiring_manager_id` and `recruiter_id` on `job_openings` are convenience FKs for the most-common case; this skill does not auto-sync them with the junction.
- Junction labels (`team_member_label`, `application_label`, `interview_label`, `feedback_label`, `offer_label`, `document_label`, `note_subject`) are caller-populated; each JTBD's reference / script composes them. Never POST these entities without the label.
- All `email_address` columns are unique. Look up by `eq.<email>` and treat zero rows as "create or ask"; never assume the email belongs to an existing user/candidate.

## What this skill does NOT do

- Schema changes, use `use-semantius` directly.
- RBAC / permissions, use `use-semantius` directly.
- One-off seed data; write a script, do not bake it into a JTBD.
- Bulk CSV import of candidates or applications. See `use-semantius` `references/webhook-import.md`.
- Per-job-opening pipelines (alternative pipelines for engineering vs sales vs executive). The model assumes a single shared `application_stages` set.
- Structured candidate skills (`candidate_skills` taxonomy). The unstructured `candidates.notes` field is the v1 home for skills observations.
- Configurable rejection reasons. The `rejection_reason` enum is fixed at the values listed above; custom reasons are not yet a thing.
- Email and calendar capture (`application_activities` / `email_messages` log). Inbound communication is not modeled in v1.
- Multi-step offer approval workflow (an `offer_approvals` entity with one row per approver). The single `approver_user_id` plus `pending_approval` status is the v1 design.
- Currency lookup table or enum for `salary_currency`. Free-text ISO 4217 codes are the v1 contract.
- GDPR consent and retention dates on candidates (`consent_given_at`, `retention_expires_at`) and automated purging.
- DB-level transition rules for `job_openings.status`, `job_applications.status`, `offers.status`, or `interview_feedback.is_submitted`. The model treats all of these as reversible; the audit log captures any reversal.
