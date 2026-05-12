---
name: ats
description: >-
  Use this skill for anything involving ATS (Applicant Tracking System), the
  in-house domain that tracks job requisitions, candidates, applications,
  pipeline stages, interviews, scorecards, offers, and the hiring team
  assigned to each opening. Trigger when the user wants to submit a job
  application, move an application to the next stage, reject an application
  with a reason, schedule an interview, submit interview feedback, extend
  an offer, record offer acceptance and the resulting hire, transition a
  requisition, assign a hiring team member, edit or delete an application
  note, or read the audit trail behind a hiring decision.
semantic_model: ats
---

# ATS

This skill carries the domain map and the jobs-to-be-done for the
Applicant Tracking System. Platform mechanics, CLI install, env vars,
PostgREST URL-encoding, `sqlToRest`, cube `discover`/`validate`/`load`,
and schema-management tools live in `use-semantius`. Assume it loads
alongside; do not re-explain CLI basics here.

If a task is purely about defining schema, managing permissions, or
running ad-hoc queries against tables you already know, call
`use-semantius` directly. Going through this skill adds nothing.

**Auto-managed fields** (set by Semantius on every table; never include
in POST/PATCH bodies): `id`, `created_at`, `updated_at`. Every other
field is caller-managed. In particular, the `label_column` of every
entity in this model is **required on insert and caller-populated**
unless the model says otherwise. This includes the junction
`hiring_team_members` (`team_member_label`) and sub-entities like
`job_applications` (`application_label`), `candidate_documents`
(`document_label`), `application_notes` (`note_subject`), `interviews`
(`interview_label`), `interview_feedback` (`feedback_label`), and
`offers` (`offer_label`). Each JTBD names the composition rule for the
label it touches; do not omit the `*_label` field from POST bodies.

**Platform-enforced invariants** (entity-level `validation_rules`
triggered on every INSERT/UPDATE; the platform rejects writes that
violate them with `{ "errors": [{ "code", "message" }, ...] }`. The
recipes here do NOT pre-validate these; they surface the platform's
error to the user verbatim if the write fails):

- `departments` rule `parent_not_self`: A department cannot reference itself as its parent.
- `job_openings` rule `headcount_positive`: Headcount must be at least 1.
- `job_openings` rule `salary_min_non_negative`: Salary minimum must be at least 0.
- `job_openings` rule `salary_max_non_negative`: Salary maximum must be at least 0.
- `job_openings` rule `salary_band_ordered`: Salary minimum cannot exceed salary maximum.
- `job_openings` rule `opened_before_filled`: Filled date cannot precede opened date.
- `job_openings` rule `opened_before_target_start`: Target start date cannot precede opened date.
- `job_openings` rule `filled_status_requires_filled_at`: A filled requisition must have a filled date.
- `job_openings` rule `non_draft_requires_opened_at`: A requisition that has left draft must have an opened date.
- `job_applications` rule `rejected_status_requires_rejected_at`: A rejected application must have a rejected date.
- `job_applications` rule `hired_status_requires_hired_at`: A hired application must have a hired date.
- `job_applications` rule `rejection_reason_only_when_rejected`: Rejection reason can only be set when status is rejected.
- `job_applications` rule `rejection_reason_required_when_rejected`: A rejected application must record a rejection reason.
- `job_applications` rule `rejected_at_only_when_rejected`: `rejected_at` can only be set when status is rejected.
- `job_applications` rule `hired_at_only_when_hired`: `hired_at` can only be set when status is hired.
- `job_applications` rule `applied_before_rejected`: Rejected date cannot precede applied date.
- `job_applications` rule `applied_before_hired`: Hired date cannot precede applied date.
- `application_notes` rule `edit_restricted_to_author_or_manager`: Only the note's original author or a user with the manage-all-notes permission can edit or delete this note.
- `application_notes` rule `author_immutable_after_first_save`: The note's author cannot be reassigned after the note is created.
- `interviews` rule `scheduled_start_before_end`: Scheduled end cannot precede scheduled start.
- `interview_feedback` rule `submitted_at_required_when_submitted`: A submitted scorecard must have a `submitted_at` timestamp.
- `interview_feedback` rule `submitted_at_only_when_submitted`: `submitted_at` can only be set when the scorecard is submitted.
- `interview_feedback` rule `feedback_write_restricted_to_interviewer`: Only the assigned interviewer or a user with manage-all-feedback can write this scorecard.
- `interview_feedback` rule `submit_feedback_restricted_to_interviewer`: Only the assigned interviewer or a user with manage-all-feedback can change the submission status of this scorecard.
- `interview_feedback` rule `interviewer_immutable_after_first_save`: The scorecard's interviewer cannot be reassigned after the scorecard is created.
- `offers` rule `base_salary_non_negative`: Base salary must be at least 0.
- `offers` rule `bonus_target_non_negative`: Bonus target must be at least 0.
- `offers` rule `post_draft_status_requires_extended_at`: Sent or completed offers must have an `offer_extended_at` timestamp.
- `offers` rule `extended_at_only_when_post_draft`: `offer_extended_at` can only be set once the offer is sent or further along.
- `offers` rule `responded_at_required_when_responded`: Responded offers must have a `responded_at` timestamp.
- `offers` rule `responded_at_only_when_responded`: `responded_at` can only be set when the candidate has responded.
- `offers` rule `extended_before_expires`: `offer_expires_at` cannot precede `offer_extended_at`.
- `offers` rule `extended_before_responded`: `responded_at` cannot precede `offer_extended_at`.
- `offers` rule `approve_offer_requires_approver_permission`: Only users with the offer-approver permission can mark an offer approved.
- `offers` rule `approver_user_id_required_when_approved`: An approved offer must record which user approved it.

**Platform-enforced permissions** (rules whose JsonLogic invokes
`{"require_permission": "<code>"}`; the platform throws when the caller
lacks the named permission, surfacing the rule's `code` and `message`
as a validation failure. The recipes that hit these gates name the
permission up-front so the calling agent can either confirm the caller
holds it before attempting the write, or propose handing off to a user
who holds it instead of hitting the throw blind):

- `application_notes` rule `edit_restricted_to_author_or_manager` requires `ats:manage_all_notes` (held by hiring leads and HR partners): Only the note's original author or a user with the manage-all-notes permission can edit or delete this note. Why: notes are personal commentary; the author owns their own edits, anyone else needs the elevated override. INSERT is unrestricted; the gate applies only on UPDATE / DELETE.
- `interview_feedback` rule `feedback_write_restricted_to_interviewer` requires `ats:manage_all_feedback` (held by HR / RecOps): Only the assigned interviewer or a user with manage-all-feedback can write this scorecard. Why: `ats:interview` (the entity's narrow `edit_permission`) is held by external panel interviewers; this row-level rule restricts every write to the row's assigned interviewer unless the elevated override applies.
- `interview_feedback` rule `submit_feedback_restricted_to_interviewer` requires `ats:manage_all_feedback` (held by HR / RecOps): Only the assigned interviewer or a user with manage-all-feedback can change the submission status of this scorecard. Why: the transition into `is_submitted = true` (or any later unsubmit) is the audit-trail lock event and must be performed by the original interviewer or by an elevated override.
- `offers` rule `approve_offer_requires_approver_permission` requires `ats:approve_offer` (held by hiring leaders and recruiting directors with offer-approval authority): Only users with the offer-approver permission can mark an offer approved. Why: moving an offer into `approved` is the budget-commitment step; baseline `ats:manage` lets the team draft and route, this gate adds a sign-off check on the specific transition.

**Restrict-cleanup chains** (inbound `reference + restrict` FKs that
block deletion of the target entity until children are explicitly
cleaned up first. The calling agent attempting to delete a listed
entity must walk the named children first, or the platform will reject
the DELETE with a foreign-key constraint error. This module routes
cleanup through existing reject / withdraw / transition workflows
rather than per-entity delete JTBDs; the chains below describe what
those workflows already prevent, and what a raw `DELETE` against any
listed entity would surface):

- Deleting `users` requires cleaning up first: `job_openings` (via `hiring_manager_id`), `application_notes` (via `author_user_id`), `interview_feedback` (via `interviewer_user_id`). A user who has ever been a hiring manager, note author, or interviewer cannot be deleted; reassign or archive instead.
- Deleting `departments` requires cleaning up first: `job_openings` (via `department_id`). Close or transfer every job opening that points at the department before deleting.
- Deleting `application_stages` requires cleaning up first: `job_applications` (via `current_stage_id`). Move every application off the stage (advance, reject, or withdraw) before deleting; the stage is referenced as a live pipeline position, not a historical pointer.
- Deleting `job_openings` requires cleaning up first: `job_applications` (via `job_opening_id`). Applications survive job closure (the `restrict` is deliberate); transition them to terminal status before any attempt to delete the opening.
- Deleting `candidates` requires cleaning up first: nothing (the parent-cascade on `job_applications.candidate_id` wipes applications, documents, notes, interviews, and feedback down the chain). The only blocker on the candidate row itself is `offers` (via `job_applications.offers.application_id` indirectly, since `offers.application_id` is `restrict`); reject or expire every live offer first.
- Deleting `job_applications` requires cleaning up first: `offers` (via `application_id`). Reject, decline, expire, or rescind every offer that points at the application before deletion.

---

## Domain glossary

| Concept | Table | Notes |
|---|---|---|
| User | `users` | Recruiter, hiring manager, interviewer, or coordinator. Built-in table; dedupe via `email_address`. |
| Department | `departments` | Organizational unit that owns job openings. Optional parent-child hierarchy. |
| Job Opening | `job_openings` | Pipeline: one requisition for one role. Status drives the funnel. |
| Application Stage | `application_stages` | Configurable pipeline step (Phone Screen, On-site, etc.). Global, ordered by `stage_order`. |
| Candidate Source | `candidate_sources` | Where candidates come from (job board, referral, agency, inbound, sourced). |
| Candidate | `candidates` | Pipeline: a person in the talent pool. Exists independently of any specific application. |
| Job Application | `job_applications` | Pipeline: central record. A candidate applied to one opening; sits at one current stage. |
| Candidate Document | `candidate_documents` | Resumes, cover letters, portfolios, work samples. URL-only; no binary. |
| Application Note | `application_notes` | Author-owned comment on an application. Visibility controls audience. |
| Interview | `interviews` | A scheduled event tied to an application. Has many feedback rows. |
| Interview Feedback | `interview_feedback` | Scorecard from one interviewer for one interview. `is_submitted` is the lock event. |
| Offer | `offers` | A formal offer extended for a specific application. Approval-gated. |
| Hiring Team Member | `hiring_team_members` | Junction: a user assigned to an opening in a specific role. |

## Key enums

- `job_openings.status`: `draft` -> `open` -> `on_hold` | `filled` | `closed` | `cancelled` (reversible; see §7.2)
- `job_openings.employment_type`: `full_time` | `part_time` | `contract` | `internship` | `temporary`
- `job_openings.work_arrangement`: `onsite` | `remote` | `hybrid`
- `application_stages.stage_category`: `pre_screen` -> `screening` -> `interview` -> `offer` -> `hired` | `rejected`
- `candidates.candidate_status`: `active` -> `hired` | `archived` | `do_not_contact`
- `job_applications.status`: `active` -> `hired` | `rejected` | `withdrawn` | `on_hold`
- `job_applications.rejection_reason`: `not_qualified` | `withdrew` | `position_filled` | `no_show` | `salary_mismatch` | `location_mismatch` | `culture_fit` | `other`
- `interviews.status`: `scheduled` -> `completed` | `cancelled` | `no_show` | `rescheduled`
- `interviews.interview_kind`: `phone_screen` | `video_call` | `onsite` | `technical` | `take_home` | `panel` | `final` | `reference_check`
- `interview_feedback.overall_rating`: `strong_yes` | `yes` | `lean_yes` | `lean_no` | `no` | `strong_no`
- `interview_feedback.recommendation`: `advance` | `hold` | `reject`
- `offers.status`: `draft` -> `pending_approval` -> `approved` -> `sent` -> `accepted` | `declined` | `rescinded` | `expired`
- `offers.candidate_response`: `pending` -> `accepted` | `declined` | `no_response`
- `hiring_team_members.team_role`: `recruiter` | `hiring_manager` | `interviewer` | `coordinator` | `executive_sponsor`
- `application_notes.visibility`: `hiring_team` | `recruiter_only` | `public`
- `candidate_documents.document_type`: `resume` | `cover_letter` | `portfolio` | `work_sample` | `certification` | `reference_letter` | `other`
- `candidate_sources.source_type`: `job_board` | `referral` | `agency` | `inbound` | `sourced` | `social_media` | `career_site` | `event` | `other`

## Cross-cutting data rules

- Salary fields (`salary_min`, `salary_max`, `base_salary`, `bonus_target`) are **unitless** in this v1; currency is deferred (see §7.2). Do not assume USD, do not append currency strings, do not invent a `salary_currency` field.
- Rows soft-deactivated via `is_active=false` (on `users`, `application_stages`, `candidate_sources`, `hiring_team_members`) are still readable. Recipes that enumerate "active" sets filter `is_active=eq.true` explicitly.

## When the runtime disagrees with the recipe

The FK shape and audit-logging facts in each JTBD's reference file are
baked in at skill-generation time. The live schema can drift (admins
can add a unique index, drop an FK, or toggle audit-logging on a table
without regenerating this skill). The recipes are not self-correcting
on their own, but the agent has an escape hatch.

When a recipe gets a `409 Conflict`, `422 Unprocessable Entity`, or
any other write failure the JTBD's reference file did not predict, the
recovery move is **read the live schema, then decide**:

```bash
# What FKs does this entity actually have right now?
semantius call crud read_field '{"filters": "entity=eq.<entity_id>"}'

# Or, more targeted, what does field <name> reference today?
semantius call crud read_field '{"filters": "entity=eq.<entity_id>,name=eq.<field_name>"}'
```

If the live shape contradicts the recipe's assumption (e.g. a unique
constraint exists where the recipe expected a free-form junction),
abort with a clear stderr message naming the drift. Do not silently
"fix it up" with extra writes. Then surface to the user that the skill
is out of date and recommend regenerating via `semantius-skill-maker`.

## Lookup convention

Semantius adds a `search_vector` column to searchable entities for
full-text search across all text fields. Use it whenever the user
passes a name, title, or description (not a UUID):

```bash
semantius call crud postgrestRequest '{"method":"GET","path":"/<table>?search_vector=wfts(simple).<term>&select=id,<label_column>"}'
```

Use `wfts(simple).<term>` for fuzzy text searches; never `ilike` and
never `fts`, they bypass the search index.

Field-equality (`<column>=eq.<value>`) is the right tool for a
different job: filtering on a known-exact value. Use it for UUIDs,
FK ids, status enums, and unique columns whose values the caller
already knows verbatim (`email_address`, `job_code`, `department_code`,
`source_name`, `stage_name`).

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

**Triggers:** `submit an application`, `apply candidate to job`, `add Jane to the Senior Engineer req`, `record a new application`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `candidate identifier` | yes | Email (preferred; resolved by `email_address=eq.<value>`) or full name (fuzzy via `wfts(simple)`). If absent, recipe asks before creating a new candidate row. |
| `job opening identifier` | yes | `job_code` (resolved by `job_code=eq.<value>`) or fuzzy job title via `wfts(simple)`. |
| `source` | no | `source_name` of a `candidate_sources` row, or omit to inherit the candidate's source. |

**Recipe:** see [`references/submit-application.md`](references/submit-application.md).

**Validation:**

- The new `job_applications` row exists with `status=active`, `applied_at` set, `current_stage_id` matching the resolved first-stage id, and `application_label` matching the composition rule.
- No prior `active` application exists for the same `(candidate_id, job_opening_id)`.

**Failure modes:**

- Active duplicate `(candidate_id, job_opening_id)` already exists -> refuse; route to "Move application to next stage" or have the user withdraw the existing one first.
- `job_opening.status != open` -> ask the user before proceeding; applying against `draft`, `on_hold`, `closed`, or `cancelled` is rare and usually a mistake.

---

### Move application to next stage

**Triggers:** `advance the application`, `move to phone screen`, `progress Jane to on-site`, `next stage`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `candidate identifier` | yes | Email or full name (see Lookup convention). |
| `job code` | yes | Resolves the opening; combined with `candidate_id` to find the application. |
| `target stage` | yes | `stage_name` (unique) or `stage_order` integer. Refuses moves into `rejected` / `hired` category stages (those have their own JTBDs). |

**Recipe:** run `scripts/move-application-stage.sh <candidate-email-or-name> <job-code> <target-stage-name>`. Exit `0` on success; `1` on resolution failure or category mismatch; `2` on platform error.

**Validation:**

- The application's `current_stage_id` equals the resolved target stage.
- The application's `status` remains `active`.

**Failure modes:**

- Multiple `active` applications match `(candidate, job_code)` -> script refuses; ask the user to disambiguate.
- Target stage is `rejected` or `hired` category -> script refuses; route to "Reject an application" or "Record offer acceptance and hire".

---

### Reject an application

**Triggers:** `reject the application`, `decline Jane for the role`, `mark application rejected with reason X`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `candidate identifier` | yes | Email or full name. |
| `job code` | yes | Resolves the opening. |
| `rejection reason` | yes | One of: `not_qualified`, `withdrew`, `position_filled`, `no_show`, `salary_mismatch`, `location_mismatch`, `culture_fit`, `other`. |

**Recipe:** run `scripts/reject-application.sh <candidate-email-or-name> <job-code> <rejection-reason>`. Exit `0` on success; `1` on resolution / enum failure; `2` on platform error.

**Validation:**

- The application's `status=rejected`, `rejection_reason` matches the input, `rejected_at` is set in the same PATCH.
- The application's `current_stage_id` is moved to the first active stage in `rejected` category, when one exists.

**Failure modes:**

- Platform code `rejection_reason_only_when_rejected` -> the recipe paired `status` + `rejection_reason` + `rejected_at`; if this fires, the live row drifted (script re-reads and surfaces verbatim).
- Application is already `rejected` or `hired` -> script refuses; rejecting a terminal application is rare and usually a re-key error.

---

### Schedule an interview

**Triggers:** `schedule an interview`, `book a phone screen for Jane`, `set up the onsite`, `arrange the panel`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `candidate identifier` | yes | Email or full name. |
| `job code` | yes | Resolves the opening; combined with `candidate_id` to find the application. |
| `interview_kind` | yes | One of: `phone_screen`, `video_call`, `onsite`, `technical`, `take_home`, `panel`, `final`, `reference_check`. |
| `scheduled_start`, `scheduled_end` | yes | ISO timestamps. The recipe checks coordinator-overlap and asks the user before scheduling a conflict. |
| `coordinator email` | no | If omitted, inherits the application's `assigned_recruiter_id`. |
| `location` or `meeting_url` | conditional | One of the two should be set (onsite vs remote); the recipe does not enforce. |

**Recipe:** see [`references/schedule-interview.md`](references/schedule-interview.md).

**Validation:**

- The new `interviews` row exists with `status=scheduled`, the resolved `application_id`, and matching `scheduled_start` / `scheduled_end`.
- `interview_label` matches the composition rule (e.g. `"Tech Phone Screen, Jane Doe"`).

**Failure modes:**

- Coordinator has an overlapping `scheduled` interview at the same time -> ask the user before proceeding.
- Platform code `scheduled_start_before_end` -> caller swapped start / end; surface the rule message and re-prompt.

---

### Submit / finalize interview feedback

**Triggers:** `submit my scorecard`, `finalize feedback for the on-site`, `record interview feedback for Jane`, `save my interview notes as draft`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `candidate identifier` | yes | Email or full name. |
| `interview_kind` | yes | Identifies which interview's scorecard (combined with candidate and most-recent match). |
| `interviewer email` | yes | Resolved by `email_address=eq.<value>` (unique). |
| `submit | draft` mode | yes | `submit` flips `is_submitted=true` and pairs `submitted_at`. `draft` saves without locking. |
| `overall_rating`, `recommendation` | conditional | Required when mode is `submit`. |

**Recipe:** run `scripts/submit-feedback.sh <candidate-email-or-name> <interview-kind> <interviewer-email> <submit|draft> [overall_rating] [recommendation]`. Exit `0` on success; `1` on resolution / enum failure; `2` on platform error.

**Validation:**

- The `interview_feedback` row exists for `(interview_id, interviewer_user_id)`. On `submit`, `is_submitted=true` and `submitted_at` is set in the same write.
- `interviewer_user_id` matches the input on INSERT and is unchanged on UPDATE (the platform enforces immutability).

**Failure modes:**

- Platform code `feedback_write_restricted_to_interviewer` -> the caller is not the assigned interviewer and lacks `ats:manage_all_feedback`. The script surfaces the code verbatim. Recovery: confirm the caller's user identity, or hand off to HR / RecOps who hold `ats:manage_all_feedback`.
- Platform code `submit_feedback_restricted_to_interviewer` -> same root cause, scoped to the `is_submitted` flip.
- Platform code `interviewer_immutable_after_first_save` -> a caller tried to PATCH `interviewer_user_id`; never include that field in PATCH bodies after insert.

---

### Extend an offer

**Triggers:** `extend an offer`, `send Jane an offer`, `approve and send the offer`, `move the offer from draft to sent`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `candidate identifier` | yes | Email or full name. |
| `job code` | yes | Resolves the application that the offer attaches to. |
| `target offer status` | yes | One of: `pending_approval`, `approved`, `sent`. `approved` triggers the `ats:approve_offer` permission check. |
| `base_salary` | yes (on draft create) | Unitless v1. |
| `bonus_target`, `equity_amount`, `start_date`, `offer_expires_at` | no | Free-form per the schema. |
| `approver user email` | conditional | Required when `target offer status = approved`; resolved to `approver_user_id`. |

**Recipe:** see [`references/extend-offer.md`](references/extend-offer.md).

**Validation:**

- The `offers` row exists with the target status. When status is `sent`, `offer_extended_at` is set in the same PATCH. When status is `approved`, `approver_user_id` is set in the same PATCH.
- `offer_label` matches the composition rule.

**Failure modes:**

- Platform code `approve_offer_requires_approver_permission` -> the caller lacks `ats:approve_offer`. The reference's pre-flight reads `read_user_role` / `read_role_permission` against the caller; on failure, propose handing off to a user who holds the permission (typically a hiring leader or recruiting director).
- A parallel `active` offer exists on the same application (status not in `declined` / `rescinded` / `expired`) -> ask the user before creating a second offer.

---

### Record offer acceptance and hire

**Triggers:** `Jane accepted the offer`, `record acceptance`, `mark hired`, `the candidate accepted, close out the funnel`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `candidate identifier` | yes | Email or full name. |
| `job code` | yes | Resolves the application + active offer. |
| `response` | yes | One of: `accepted`, `declined`, `no_response`. Only `accepted` cascades to hire. |

**Recipe:** run `scripts/record-offer-response.sh <candidate-email-or-name> <job-code> <accepted|declined|no_response>`. Exit `0` on success; `1` on resolution / state failure; `2` on platform error.

**Validation:**

- On `accepted`: the offer's `status=accepted`, `candidate_response=accepted`, `responded_at` set; the parent `job_applications.status=hired`, `hired_at` set, `current_stage_id` moved to the first `hired` category stage; the candidate's `candidate_status=hired`.
- On `declined` / `no_response`: only the offer row updates; the application stays at its current stage so the recruiter can reject explicitly or re-engage.

**Failure modes:**

- The active offer is not in `sent` status -> script refuses; recovery is to send the offer first via "Extend an offer".
- Multiple `active` offers exist on the application -> script refuses; ask the user to rescind the duplicates first.

---

### Transition a requisition

**Triggers:** `open the req`, `put the requisition on hold`, `close out the position`, `cancel the requisition`, `mark filled`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `job code` | yes | Resolves the opening. |
| `target status` | yes | One of: `open`, `on_hold`, `filled`, `closed`, `cancelled`. The recipe pairs `opened_at` on first `open`, and `filled_at` on `filled`. |

**Recipe:** run `scripts/transition-requisition.sh <job-code> <target-status>`. Exit `0` on success; `1` on resolution / enum failure; `2` on platform error.

**Validation:**

- The `job_openings.status` equals the target.
- On `open` from `draft`: `opened_at` is set in the same PATCH.
- On `filled`: `filled_at` is set in the same PATCH.

**Failure modes:**

- Platform code `non_draft_requires_opened_at` -> the recipe transitioned past `draft` without pairing `opened_at`; the script does this in one PATCH, so this fires only on a live-data drift.
- Platform code `filled_status_requires_filled_at` -> the recipe paired the date; if this fires, the live row drifted.
- Platform code `opened_before_filled` -> `opened_at` is set later than `filled_at`; surface verbatim and ask the user for the correct dates.

---

### Assign hiring team member

**Triggers:** `assign Alex to the hiring team`, `add an interviewer to the panel`, `make Sarah a coordinator on ENG-2026-014`, `remove Bob from the team`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `user email` | yes | Resolves the `user_id`. |
| `job code` | yes | Resolves the `job_opening_id`. |
| `team_role` | yes | One of: `recruiter`, `hiring_manager`, `interviewer`, `coordinator`, `executive_sponsor`. |
| `mode` | yes | `add` or `remove`. `remove` soft-deactivates via `is_active=false`, never DELETEs. |

**Recipe:** run `scripts/assign-hiring-team-member.sh <user-email> <job-code> <team-role> <add|remove>`. Exit `0` on success; `1` on resolution / enum failure; `2` on platform error.

**Validation:**

- On `add`: a row with `(job_opening_id, user_id, team_role, is_active=true)` exists; `team_member_label` matches the composition rule.
- On `remove`: the matching row has `is_active=false`; history is preserved.

**Failure modes:**

- The `(job_opening_id, user_id, team_role)` natural key has **no DB-level uniqueness** (see §7.2). The script dedupes by reading first and reactivating a soft-removed row when one exists, rather than POSTing a duplicate.

---

### Edit / delete an application note

**Triggers:** `edit my note on the application`, `delete the note I left`, `correct the recruiter note`, `redact the application note`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `note id` | yes | The `application_notes.id` to edit or delete. Recipe reads the row first to determine `author_user_id`. |
| `mode` | yes | `edit` (PATCH body fields) or `delete`. |
| `caller user identifier` | yes | The acting user; the recipe asks before writing when the caller is not the author. |

**Recipe:** see [`references/edit-application-note.md`](references/edit-application-note.md).

**Validation:**

- On `edit`: the note's `note_body`, `note_subject`, `visibility`, or `noted_at` change; `author_user_id` is unchanged.
- On `delete`: the row no longer exists.

**Failure modes:**

- Platform code `edit_restricted_to_author_or_manager` -> the caller is not the author and lacks `ats:manage_all_notes`. Recovery: confirm the caller's identity, or hand off to an HR partner / hiring lead who holds the permission.
- Platform code `author_immutable_after_first_save` -> a caller tried to PATCH `author_user_id`; never include that field in PATCH bodies after insert.

---

### Read decision audit trail

**Triggers:** `who approved this offer`, `show the audit trail for Jane's application`, `what changed on the offer last week`, `who moved the application to rejected`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `entity name` | yes | One of the audit-logged tables: `job_openings`, `candidates`, `job_applications`, `interview_feedback`, `offers`. |
| `row id` | yes | The specific row whose history the user wants. |

**Recipe:** see [`references/read-audit-trail.md`](references/read-audit-trail.md).

**Validation:**

- The audit response includes every recorded change on the row with timestamps and the actor user id.

**Failure modes:**

- Audit endpoint returns no rows -> either the entity is not audit-logged, or the row never changed after creation. Both are valid; surface clearly.

---

## Common queries

Always run `cube discover '{}'` first to refresh the schema. Match the
dimension and measure names below against what `discover` returns; field
names drift when the model is regenerated, and `discover` is the source
of truth at query time.

```bash
# Pipeline by stage (active applications grouped by current stage)
semantius call cube load '{"query":{
  "measures":["job_applications.count"],
  "dimensions":["application_stages.stage_name","application_stages.stage_order"],
  "filters":[{"member":"job_applications.status","operator":"equals","values":["active"]}],
  "order":{"application_stages.stage_order":"asc"}
}}'
```

```bash
# Source ROI (hires by candidate_source over rolling 90 days)
semantius call cube load '{"query":{
  "measures":["job_applications.count"],
  "dimensions":["candidate_sources.source_name","candidate_sources.source_type"],
  "filters":[{"member":"job_applications.status","operator":"equals","values":["hired"]}],
  "timeDimensions":[{"dimension":"job_applications.hired_at","dateRange":"last 90 days"}],
  "order":{"job_applications.count":"desc"}
}}'
```

```bash
# Time-to-hire by department (avg days from applied_at to hired_at)
semantius call cube load '{"query":{
  "measures":["job_applications.avg_days_to_hire"],
  "dimensions":["departments.department_name"],
  "filters":[{"member":"job_applications.status","operator":"equals","values":["hired"]}],
  "timeDimensions":[{"dimension":"job_applications.hired_at","dateRange":"last 180 days"}]
}}'
```

```bash
# Open requisitions by department (current open count + avg days open)
semantius call cube load '{"query":{
  "measures":["job_openings.count","job_openings.avg_days_open"],
  "dimensions":["departments.department_name"],
  "filters":[{"member":"job_openings.status","operator":"equals","values":["open"]}]
}}'
```

```bash
# Interviewer load (interviews scheduled per interviewer, rolling 30 days)
semantius call cube load '{"query":{
  "measures":["interviews.count"],
  "dimensions":["users.display_name"],
  "filters":[{"member":"interviews.status","operator":"notEquals","values":["cancelled"]}],
  "timeDimensions":[{"dimension":"interviews.scheduled_start","dateRange":"last 30 days"}],
  "order":{"interviews.count":"desc"}
}}'
```

Cube measure / dimension names follow the live `discover` output; the
queries above are starting points, not contracts.

---

## Guardrails

- Never PATCH `job_applications.status` to `rejected` without setting `rejection_reason` AND `rejected_at` in the same call (the platform pairs all three via `rejection_reason_only_when_rejected`, `rejection_reason_required_when_rejected`, `rejected_at_only_when_rejected`, `rejected_status_requires_rejected_at`).
- Never PATCH `job_applications.status` to `hired` without setting `hired_at` in the same call.
- Never PATCH `offers.status` to `approved` without setting `approver_user_id` in the same call, AND never attempt without verifying the caller holds `ats:approve_offer`.
- Never PATCH `offers.status` to `sent` without setting `offer_extended_at` in the same call.
- Never PATCH `interview_feedback.is_submitted` to `true` without setting `submitted_at` in the same call, AND never attempt unless the caller is the row's `interviewer_user_id` or holds `ats:manage_all_feedback`.
- Never PATCH `interview_feedback.interviewer_user_id` after insert; the platform freezes it via `interviewer_immutable_after_first_save`.
- Never PATCH `application_notes.author_user_id` after insert; the platform freezes it via `author_immutable_after_first_save`.
- Never attempt to write `application_notes` UPDATE / DELETE as a non-author unless the caller holds `ats:manage_all_notes`.
- Salary fields are unitless in v1; do not attempt to write a `salary_currency` value, the field does not exist.
- `hiring_team_members` has no DB-level uniqueness on `(job_opening_id, user_id, team_role)`; recipes that assign team members dedupe-before-insert.
- Soft-deactivation (`is_active=false`) preserves history on `users`, `application_stages`, `candidate_sources`, and `hiring_team_members`; recipes never DELETE these rows in normal workflows.
- Junction and sub-entity labels (`application_label`, `interview_label`, `feedback_label`, `offer_label`, `team_member_label`, `document_label`, `note_subject`) are caller-populated on insert; see each JTBD for the composition rule.

## What this skill does NOT do

- Schema changes; use `use-semantius` directly.
- RBAC / permissions; use `use-semantius` directly.
- One-off seed data; write a script, don't bake it into a JTBD.
- Per-job pipeline configuration (single global pipeline is the v1 assumption).
- Structured candidate skills taxonomy (the v1 model carries `notes` only).
- Custom configurable rejection reasons (the v1 model is an enum).
- Email and calendar integration / activity logging.
- Multi-step offer approval workflows (v1 carries a single `approver_user_id`).
- Multi-currency salary fields (v1 is unitless).
- GDPR consent and retention dates as structured fields.
- Read-side scoping for external panel interviewers; `ats:interview` narrows writes but not reads.
