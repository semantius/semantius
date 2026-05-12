# Submit a job application

Create a new `job_applications` row for a candidate against a specific `job_openings`. The recipe handles candidate-exists branching (look up by email; if found, reuse; if not, ask the user before creating a new candidate row), composes the caller-populated `application_label`, and resolves the first active `application_stages` row by `stage_order`.

## FK & shape assumptions

- `job_applications.candidate_id -> candidates.id` (parent, cascade)
- `job_applications.job_opening_id -> job_openings.id` (reference, restrict)
- `job_applications.current_stage_id -> application_stages.id` (reference, restrict)
- `job_applications.source_id -> candidate_sources.id` (reference, clear, optional)
- `job_applications.assigned_recruiter_id -> users.id` (reference, clear, optional)
- `candidates.email_address` is **unique** when present (one candidate per email).
- `job_openings.job_code` is **unique**.
- `application_stages.stage_order` is **unique**; the lowest active `stage_order` is the pipeline entry point.
- No DB-level unique constraint on `(candidate_id, job_opening_id)`. The recipe checks for an existing `active` application before insert.
- `job_applications` is audit-logged; the create event is captured automatically.

## Composition rules

- `application_label` (required, caller-populated): compose as `"{candidates.full_name} -> {job_openings.job_title}"`. ASCII arrow ` -> ` (space-hyphen-greater-space). Both values come from the read-first calls in step 1; do not invent.

## Recipe

```bash
# Step 1: parallel-fetch (no dependency between these reads)
# expect: --single, exactly one job opening; exit 1 with "job opening '<code>' not found" if missing.
job_opening=$(semantius call crud postgrestRequest --single \
  "{\"method\":\"GET\",\"path\":\"/job_openings?job_code=eq.<job_code>&select=id,job_title,status,recruiter_id\"}")

# expect: --single, exactly one stage; the lowest active stage by stage_order.
first_stage=$(semantius call crud postgrestRequest --single \
  "{\"method\":\"GET\",\"path\":\"/application_stages?is_active=eq.true&order=stage_order.asc&limit=1&select=id,stage_name\"}")

# Step 2: candidate lookup by email (preferred) or fuzzy name.
# expect: --single when by email (email is unique); array when by name.
candidate=$(semantius call crud postgrestRequest --single \
  "{\"method\":\"GET\",\"path\":\"/candidates?email_address=eq.<email>&select=id,full_name,source_id\"}") \
  || candidate=""

# Step 3: branch on the result of step 2.
#   If candidate is empty: ASK THE USER before creating a new candidate row.
#     Required: full_name. Optional: phone_number, linkedin_url, current_employer.
#     POST /candidates with the user-confirmed fields, capture the new id.
#   If candidate exists: reuse its id.

# Step 4: dedupe-on-application. Refuse if an active application already exists.
# expect: array; zero rows is the go-ahead branch, one or more is the refuse branch.
existing=$(semantius call crud postgrestRequest \
  "{\"method\":\"GET\",\"path\":\"/job_applications?candidate_id=eq.<candidate_id>&job_opening_id=eq.<job_opening_id>&status=eq.active&select=id,current_stage_id\"}")
# If existing returns one or more rows: refuse, surface the existing application id, and ask
# whether to advance the existing one via Move-application-stage.

# Step 5: status sanity. If job_openings.status is not 'open' -> ASK THE USER before proceeding.
# Applying against a draft / on_hold / closed / cancelled opening is rare and usually a mistake.

# Step 6: compose application_label and POST.
# expect: --single, exactly one row written.
semantius call crud postgrestRequest --single "{
  \"method\":\"POST\",
  \"path\":\"/job_applications\",
  \"body\":{
    \"application_label\":\"<candidates.full_name> -> <job_openings.job_title>\",
    \"candidate_id\":\"<candidate_id>\",
    \"job_opening_id\":\"<job_opening_id>\",
    \"current_stage_id\":\"<first_stage_id>\",
    \"status\":\"active\",
    \"source_id\":\"<source_id or omit>\",
    \"applied_at\":\"<current ISO timestamp>\",
    \"assigned_recruiter_id\":\"<recruiter_id or omit>\"
  }
}"

# Step 7: verify the write.
# expect: --single, the row we just wrote.
semantius call crud postgrestRequest --single \
  "{\"method\":\"GET\",\"path\":\"/job_applications?id=eq.<new_application_id>&select=id,application_label,status,current_stage_id,applied_at\"}"
```

## Validation

- The new `job_applications` row exists with `status=active`, `applied_at` set, `current_stage_id` matching the resolved first-stage id, and `application_label` matching the composition rule.
- The candidate's `id` is referenced (either the pre-existing candidate or the newly-created one).
- The job opening's `status` was `open` at the time of the write, or the user explicitly approved a non-`open` exception.

## Failure modes (extended)

- **Job opening status not `open`.** The recipe asks the user; do not silently apply against `draft`, `on_hold`, `closed`, or `cancelled` openings. Recovery: confirm with the user, then proceed; or have the user transition the opening to `open` first via `scripts/transition-requisition.sh`.
- **Candidate does not exist.** Ask the user before POSTing a new `candidates` row. Required: `full_name`. Email duplicates are caught by the unique constraint on `candidates.email_address`; if the POST 409s, re-read by email; the candidate was created racing against this recipe (treat as "found" and continue).
- **Active duplicate application against the same opening.** The recipe refuses on the dedupe check; do not POST. Surface the existing application id and the stage it sits at; ask whether to advance the existing one (route to `move-application-stage`) or to mark the existing one `withdrawn` (use-semantius PATCH) and then re-apply. Closed / rejected / withdrawn applications against the same opening are NOT a duplicate-block; the recruiter may legitimately re-engage a candidate.
- **No active stages.** If `application_stages.is_active=true` returns zero rows, the pipeline is misconfigured. Abort with a stderr message naming the issue and recommend creating at least one active stage via `use-semantius` before retrying.
- **`source_id` not resolvable.** If the user named a source that does not exist in `candidate_sources`, ask whether to inherit the candidate's source (default), pick from the existing source list, or abort. Do not auto-create sources.
- **Platform validation rule firing on POST.** If the write fails with `applied_before_rejected` or `applied_before_hired` codes, the live row is in a state the recipe did not anticipate; abort and surface verbatim.
