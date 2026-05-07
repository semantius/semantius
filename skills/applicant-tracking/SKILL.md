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
Applicant Tracking System. Platform mechanics (CLI install, env vars,
PostgREST URL-encoding, `sqlToRest`, cube `discover`/`validate`/`load`,
schema-management tools) live in `use-semantius`. Assume it loads
alongside; do not re-explain CLI basics here.

If a task is purely about defining schema, managing permissions, or
running ad-hoc queries against tables you already know, call
`use-semantius` directly, going through this skill adds nothing.

**Auto-managed fields** (set by Semantius on every table; never include
in POST/PATCH bodies): `id`, `created_at`, `updated_at`. Every other
required field, including every `*_label` column on junction and
sub-entity tables (`application_label`, `document_label`,
`interview_label`, `feedback_label`, `offer_label`,
`team_member_label`, `note_subject`), is **caller-populated** and must
appear in the POST body. The label-composition convention for each
lives in the linked reference for the JTBD that creates the row.

---

## Domain glossary

The hiring funnel runs **Job Opening, Job Application, Interview,
Interview Feedback, Offer, Hire**, with `Candidate` orbiting on the
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

- `job_openings.status`: `draft` -> `open` -> `on_hold` | `filled` | `closed` | `cancelled`
- `application_stages.stage_category`: `pre_screen`, `screening`, `interview`, `offer`, `hired`, `rejected`
- `job_applications.status`: `active` -> `hired` | `rejected` | `withdrawn` | `on_hold`
- `job_applications.rejection_reason`: `not_qualified`, `withdrew`, `position_filled`, `no_show`, `salary_mismatch`, `location_mismatch`, `culture_fit`, `other`
- `interviews.status`: `scheduled` -> `completed` | `cancelled` | `no_show` | `rescheduled`
- `interviews.interview_kind`: `phone_screen`, `video_call`, `onsite`, `technical`, `take_home`, `panel`, `final`, `reference_check`
- `interview_feedback.overall_rating`: `strong_yes`, `yes`, `lean_yes`, `lean_no`, `no`, `strong_no`
- `interview_feedback.recommendation`: `advance`, `hold`, `reject`
- `offers.status`: `draft` -> `pending_approval` -> `approved` -> `sent` -> `accepted` | `declined` | `rescinded` | `expired`
- `offers.candidate_response`: `pending`, `accepted`, `declined`, `no_response`
- `hiring_team_members.team_role`: `recruiter`, `hiring_manager`, `interviewer`, `coordinator`, `executive_sponsor`
- `candidates.candidate_status`: `active` -> `hired` | `archived` | `do_not_contact`
- `application_notes.visibility`: `hiring_team`, `recruiter_only`, `public`

## Foreign-key cheatsheet

Only the FKs that JTBDs cross. Format: `child.field -> parent.id`
(delete behavior in parens).

- `job_applications.candidate_id -> candidates.id` (parent, cascade)
- `job_applications.job_opening_id -> job_openings.id` (restrict; historical applications survive a job closure)
- `job_applications.current_stage_id -> application_stages.id` (restrict; stages cannot be deleted while in use)
- `job_applications.assigned_recruiter_id -> users.id` (clear)
- `job_applications.source_id -> candidate_sources.id` (clear)
- `interviews.application_id -> job_applications.id` (parent, cascade)
- `interviews.coordinator_user_id -> users.id` (clear)
- `interview_feedback.interview_id -> interviews.id` (parent, cascade)
- `interview_feedback.interviewer_user_id -> users.id` (**restrict**: the interviewer cannot be deleted while feedback exists)
- `offers.application_id -> job_applications.id` (**restrict**, *no DB-level uniqueness*: the schema does not stop you from creating a second active offer on the same application; the recipe must check for an existing one)
- `offers.approver_user_id -> users.id` (clear)
- `hiring_team_members.job_opening_id -> job_openings.id` (parent, cascade)
- `hiring_team_members.user_id -> users.id` (parent, cascade)
- `application_notes.author_user_id -> users.id` (**restrict**: a user with authored notes cannot be deleted)
- `candidate_documents.candidate_id -> candidates.id` (parent, cascade)

**Unique columns** (409 on duplicate POST): `departments.department_name`,
`departments.department_code`, `job_openings.job_code`,
`application_stages.stage_name`, `candidate_sources.source_name`,
`candidates.email_address`, `users.email_address`.

**No DB-level uniqueness on the natural junction keys.** Neither
`hiring_team_members(job_opening_id, user_id, team_role)` nor
`offers(application_id)` is constrained. Recipes that would create
one must read first.

**Audit-logged tables** (Semantius writes the audit rows automatically;
recipes do not manage them): `job_openings`, `candidates`,
`job_applications`, `interview_feedback`, `offers`.

## Lookup convention

Semantius adds a `search_vector` column to searchable entities for
full-text search across all text fields. Use it whenever the user
passes a name, title, or code, not a UUID:

```bash
semantius call crud postgrestRequest '{"method":"GET","path":"/<table>?search_vector=wfts(simple).<term>&select=id,<label_column>"}'
```

Use `wfts(simple).<term>` for fuzzy text searches; never `ilike` and
never `fts`, they bypass the search index and mismatch the platform
convention.

Field-equality (`<column>=eq.<value>`) is the right tool for a
*different* job: filtering on a known-exact value. Use it for UUIDs,
FK ids, status enums, and unique columns whose values the caller
already knows verbatim (`job_code`, `email_address`, `department_code`,
`stage_name`, `source_name`).

If a lookup returns more than one row, present the candidates and
ask. If zero, ask the user to clarify rather than guessing.

## Timestamps in recipe bodies

Every `*_at` field, `*_date` field, or other moment-of-action value
in a recipe body is a placeholder the calling agent fills at call
time, not a literal copied from the example. Recipe templates use
`<current ISO timestamp>` and `<today's date, YYYY-MM-DD>`; do not
copy those strings into a real call. This applies in SKILL.md, in
every reference file, in the Common queries appendix, and in any
script the calling agent invokes.

## Label-composition separator convention

Caller-populated labels in this skill use comma separators between
parts and an ASCII arrow (` -> `, space-hyphen-greater-space) when
the relation is "actor against subject". Reference files spell out
the exact composition per JTBD; the convention here is just the
character set:

- ASCII arrow ` -> ` for "actor -> subject" relations
  (`application_label`: candidate -> job).
- Comma `, ` for noun phrases describing one row
  (`offer_label`, `team_member_label`, `feedback_label`).
- Space-joined kind + " for " + subject for "kind X for person Y"
  shapes (`interview_label`).

Do not mix Unicode arrows (`U+2192`) or em-dashes (`U+2014`); the
exact byte sequences above are what reports compare against.

---

## Jobs to be done

### Open a job opening

**Triggers:** `open a requisition`, `publish the job for X`, `move the job from draft to open`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `job_opening_id` or `job_code` | yes | Resolve `job_code=eq.<code>` first if the user passes the code |
| Confirmed open date | yes | Today; the script fills it |

**Recipe:** run `scripts/open-job.sh <job_id_or_code>`. The agent
invokes; do not paste the script body here. Exit `0` on success,
`1` on validation failure (job not found, status not `draft`,
multiple matches), `2` on platform error.

**Validation:** `status=open` and `opened_at` is non-null on the row.

**Failure modes:**
- Status is not `draft` (already `open`, `filled`, etc.) -> script
  exits 1; tell the user what the current status is and stop. "Open"
  is not a re-runnable transition.
- Multiple jobs match the search term -> script exits 1 with the
  candidate list; ask the user which one.

---

### Apply a candidate to a job opening

**Triggers:** `apply this candidate to X`, `add Jane to the senior engineer pipeline`, `create an application`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `candidate_id` | yes | Look up by `email_address=eq.<email>` (unique) or `search_vector=wfts(simple).<name>` |
| `job_opening_id` | yes | Look up by `job_code=eq.<code>` or `search_vector=wfts(simple).<title>` |
| `current_stage_id` | yes | The recipe resolves the lowest-`stage_order` stage with `stage_category=eq.pre_screen` |
| `applied_at` | yes | Current ISO timestamp at call time |
| `source_id` | no | Lookup by `source_name=eq.<name>` if the user names one |
| `assigned_recruiter_id` | no | Lookup user by `email_address=eq.<email>` |

**Recipe:** see [`references/apply-candidate.md`](references/apply-candidate.md).

**Validation:** new row exists, `status=active`, `current_stage_id`
points at a `pre_screen` stage, `application_label` matches the
candidate -> job composition.

**Failure modes:**
- Job's `status` is not `open` -> ask whether to open the job first or
  pick a different one; do not silently apply against a closed job.
- Candidate's `candidate_status` is `do_not_contact` -> refuse and
  surface the candidate to the user.

---

### Advance an application to the next stage

**Triggers:** `move the application to phone screen`, `advance Jane to on-site`, `set the stage to interview`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `application_id` | yes | Resolve via candidate + job if the user names them |
| Target stage | yes | Must resolve to a stage whose `stage_category` is not `hired` or `rejected` |

The Inputs table excludes `hired` and `rejected` target categories
on purpose. Those flips own paired side-effect fields (`hired_at`,
`rejected_at`, `rejection_reason`) and route to the offer-acceptance
cascade or close-application JTBDs.

**Recipe:** see [`references/advance-stage.md`](references/advance-stage.md).

**Validation:** `current_stage_id` is the target; `status` is still
`active`; the audit trail shows the change (`job_applications` is
audit-logged, no extra write needed).

**Failure modes:**
- Target stage has `stage_category=hired` or `=rejected` -> route the
  user to the offer-acceptance cascade or close-application JTBD.
- Application `status` is terminal -> refuse; ask whether to re-open
  the application first.

---

### Schedule an interview

**Triggers:** `schedule a phone screen with Jane`, `book the on-site for X`, `set up a panel interview`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `application_id` | yes | Resolve via candidate + job if the user names them |
| `interview_kind` | yes | Pick from the enum (`phone_screen`, `onsite`, `technical`, `panel`, etc.) |
| `scheduled_start`, `scheduled_end` | yes | ISO timestamps the agent fills at call time |
| `coordinator_user_id` | no | Lookup by user email |
| `meeting_url` or `location` | no | URL for video, free-text for `onsite` |

**Recipe:** see [`references/schedule-interview.md`](references/schedule-interview.md).

**Validation:** row exists with `status=scheduled`; `scheduled_end >
scheduled_start`; `interview_label` matches the kind + candidate
composition.

**Failure modes:**
- Application is not `active` -> refuse; do not schedule on
  hired/rejected/withdrawn pipelines.
- `interview_kind=onsite` with no `location` -> ask the user; an
  on-site with no address is almost always a mistake.

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

**Recipe:** see [`references/submit-feedback.md`](references/submit-feedback.md).

**Validation:** `is_submitted=true` AND `submitted_at` is non-null on
the row.

**Failure modes:**
- `is_submitted=true` set without `submitted_at` -> reports treat the
  scorecard as missing; PATCH to add the timestamp.
- Interviewer is not on the `hiring_team_members` for the opening ->
  not blocked by the DB, but flag to the user; out-of-team feedback
  is unusual.

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

**Recipe:** see [`references/extend-offer.md`](references/extend-offer.md).

**Validation:** for each transition, `status` matches and the paired
field (`approver_user_id` on approval, `offer_extended_at` on send)
is non-null.

**Failure modes:**
- A pre-existing non-terminal offer was missed -> 200 OK creates a
  duplicate; recover by `rescinded`-flipping one of them.
- `approved` set without `approver_user_id` -> reports cannot answer
  "who approved this"; PATCH to add the approver.
- `sent` set without `offer_extended_at` -> time-to-offer metrics
  break; PATCH to add the timestamp.

---

### Record offer response and complete a hire (cascade)

**Triggers:** `the candidate accepted, mark them hired`, `Jane accepted the offer`, `record offer acceptance`, `decline the offer`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `offer_id` | yes | Resolve via application if the user names the candidate |
| Response | yes | `accepted` or `declined` |

This is a Pattern C materialization: an `accepted` response ripples
across `offers`, `job_applications`, `candidates`, and possibly
`job_openings`. The DB guards none of the steps; stopping after the
first PATCH leaves a half-applied funnel.

**Recipe:** see [`references/record-offer-response.md`](references/record-offer-response.md).

**Validation (accepted branch):** every PATCH returned 2xx; a
follow-up read of the application shows `status=hired` and
`hired_at` set; the candidate shows `candidate_status=hired`; if
hires now equals `headcount`, the job opening shows `status=filled`.

**Failure modes:**
- A PATCH mid-cascade fails -> the funnel is half-applied; do not
  retry blindly. Read each row, identify which steps did not stick,
  PATCH only those.
- Another offer on the same application is still `sent` -> ask the
  user whether to `rescind` it before completing the hire.
- Job opening already `filled` or `closed` when the recipe goes to
  fill it -> do not re-PATCH; the previous fill is correct.

---

### Close an application as rejected or withdrawn

**Triggers:** `reject this application`, `Jane withdrew, close her application`, `decline the candidate with reason X`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `application_id` | yes | Resolve via candidate + job if the user names them |
| Outcome | yes | `rejected` (recruiter-side) or `withdrawn` (candidate-side) |
| `rejection_reason` | yes for `rejected` | Pick from the enum |

**Recipe:** see [`references/close-application.md`](references/close-application.md).

**Validation:** `status` matches; `rejected_at` is non-null;
`current_stage_id` resolves to a `stage_category=rejected` stage.

**Failure modes:**
- `status=rejected` set with no `rejection_reason` -> funnel-reason
  reports drop the row; PATCH to add it.
- Application has a `sent`-status offer outstanding -> ask the user
  before closing; the offer should be `rescinded` first.

---

### Add or remove a hiring team member

**Triggers:** `add Sarah as the hiring manager for X`, `assign Alex as an interviewer on the senior backend role`, `remove Mark from the hiring team`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `job_opening_id` | yes | Lookup by `job_code` or fuzzy title |
| `user_id` | yes | Lookup user by email |
| `team_role` | yes | `recruiter`, `hiring_manager`, `interviewer`, `coordinator`, `executive_sponsor` |
| Operation | yes | `add` or `remove` |

The script handles the read-first dedupe: if the
`(job_opening, user, role)` triple already exists active, no-op;
if it exists inactive, reactivate; otherwise create. Remove is a
soft-deactivate (`is_active=false`) so the team history is
preserved.

**Recipe:** run `scripts/manage-team-member.sh <op> <job_id_or_code> <user_email> <team_role>`.
Exit `0` on success, `1` on validation failure (user/job not found,
unknown role), `2` on platform error.

**Validation (add):** exactly one row exists for the
`(job_opening_id, user_id, team_role)` triple, with `is_active=true`.

**Failure modes:**
- A POST that bypassed the read-first -> the table accepts a
  duplicate. Recover by PATCH-ing one of the duplicates to
  `is_active=false`.
- The user being added is not in `users` yet -> create the user
  first via `use-semantius`; do not invent a fake id.

---

## Common queries

These are starting points, not contracts. Cube schema names drift
when the model is regenerated, so always run `cube discover '{}'`
first and map the dimension and measure names below against
`discover`'s output. The cube name is usually the entity's table
name with the first letter capitalized (e.g. `JobApplications`),
but verify.

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
# The avg_days_to_hire measure name is illustrative, check discover output
# for the real one or compute via a custom measure.
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
  offer-acceptance cascade or close-application JTBDs so the paired
  side-effect fields (`hired_at`, `rejected_at`, `rejection_reason`)
  get set.
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
  `application_activities` table exists; communication history is
  not modeled.
- Multi-step offer approval workflow: only a single
  `approver_user_id` and `pending_approval` status; chained
  approvers are not modeled.
- GDPR consent and retention dates on candidates: no
  `consent_given_at` or `retention_expires_at` fields; deletion is
  the only erasure path (cascade via `candidate_id`).
