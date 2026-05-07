# Apply a candidate to a job opening

Create a new `job_applications` row tying one candidate to one job
opening at the entry pre-screen stage. The `application_label` is
caller-populated (no DB default), and the recipe must read both the
candidate and the job before posting so it has the names to compose
the label with.

## Composition rules

- `application_label`: composed as
  `"{candidate.full_name} -> {job_opening.job_title}"`. ASCII arrow
  ` -> ` (space-hyphen-greater-space). Both values come from the
  read-first calls in step 1; do not invent.

## Recipe

```bash
# Step 1: parallel-fetch (no dependency between these reads)
# Resolve the candidate. email_address is unique, so use --single
# when the user gave an email; the read must resolve to exactly one row.
semantius call crud postgrestRequest --single '{"method":"GET","path":"/candidates?email_address=eq.<email>&select=id,full_name,candidate_status"}'
# expect: --single; bare object on success. Exit 1 (zero rows) → ask the
# user to clarify or fall back to a fuzzy lookup (wfts, array mode).
# Exit 2 (>1 rows) is impossible on a unique column.

# Fuzzy fallback when the user gave a name, not an email.
semantius call crud postgrestRequest '{"method":"GET","path":"/candidates?search_vector=wfts(simple).<name>&select=id,full_name,candidate_status"}'
# expect: array; on length 0 ask the user, on length >1 present and ask.

# Resolve the job opening. job_code is unique → --single.
semantius call crud postgrestRequest --single '{"method":"GET","path":"/job_openings?job_code=eq.<code>&select=id,job_title,status"}'
# expect: --single; if exit 1, fall back to wfts.

# Fuzzy fallback for jobs.
semantius call crud postgrestRequest '{"method":"GET","path":"/job_openings?search_vector=wfts(simple).<title>&select=id,job_title,status"}'
# expect: array; on length 0 ask, on length >1 present and ask.

# Resolve the entry pre-screen stage. The recipe assumes the model is
# configured with at least one pre_screen stage; if not, this is a
# genuine recipe-blocker → --single.
semantius call crud postgrestRequest --single '{"method":"GET","path":"/application_stages?stage_category=eq.pre_screen&order=stage_order.asc&limit=1&select=id,stage_name"}'
# expect: --single; exit 1 means the model is missing entry-stage config;
# tell the user to add a stage_category=pre_screen row first.

# Step 2: branch on read results
# - If candidate.candidate_status = "do_not_contact": refuse and surface
#   the candidate to the user; do not POST.
# - If job_opening.status != "open": ask the user whether to open the
#   job first (route to "Open a job opening") or pick a different one;
#   do not POST until they decide.

# Step 3: optional lookups (only if the user named them).
# These are unique columns but the lookups are optional — if the user
# did not name a source or recruiter, skip the call entirely.
# When the call is made, the value must resolve or the user mistyped.
semantius call crud postgrestRequest --single '{"method":"GET","path":"/candidate_sources?source_name=eq.<name>&select=id"}'
# expect: --single; if exit 1, surface to the user (mistyped source name).

semantius call crud postgrestRequest --single '{"method":"GET","path":"/users?email_address=eq.<email>&select=id"}'
# expect: --single; if exit 1, the recruiter user does not exist; route
# to use-semantius user creation rather than inventing an id.

# Step 4: compose the label and POST. Apply the label-composition rule
# above; do not let the agent invent the format.
semantius call crud postgrestRequest --single '{
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
# expect: --single on POST asserts the insert affected exactly one row;
# returns the bare new object. If 409 on candidate+job, an application
# already exists for this pair (Semantius does not enforce uniqueness
# here, but a custom unique may); surface to the user.
```

## Validation

- Read the new row; `status=active`, `current_stage_id` resolves to a
  stage with `stage_category=pre_screen`, and `application_label`
  matches the `<candidate.full_name> -> <job_opening.job_title>`
  composition.
- The audit trail records the create (`job_applications` is
  audit-logged); no extra audit write needed.

## Failure modes (extended)

- **Job is `draft` or `filled`/`closed`/`cancelled`.** Triggering: the
  step-2 branch fired. Recovery: the agent asks the user. If they
  pick "open the job first", route to the open-a-job-opening JTBD
  (which is a script), and resume here once it returns 0. If they
  pick a different job, restart the recipe from step 1 with the new
  job_code.
- **Candidate `candidate_status=do_not_contact`.** Triggering: step-2
  branch fired. Recovery: refuse and surface; do not offer to flip
  the status silently. If the user wants to override the do-not-contact
  flag, that is a separate decision they should make explicitly and
  re-run.
- **The user named a stage that has no row in `application_stages`.**
  Triggering: step-1 stage read returned empty, or the user named a
  stage other than the entry stage. Recovery: this JTBD always uses
  the entry pre-screen stage; if the user wants to apply directly to
  a later stage, that is the advance-stage JTBD, not this one.
- **Composite duplicate (same candidate, same job, already applied).**
  Triggering: the model does not enforce this at the DB layer, but
  duplicates pollute the funnel. Recovery: read first; if a prior
  application exists, ask the user whether to re-open it (separate
  flow) or treat it as a re-apply.
