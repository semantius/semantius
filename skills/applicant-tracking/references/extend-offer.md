# Extend an offer

Create an `offers` row in `draft` (or advance an existing one through
`pending_approval` -> `approved` -> `sent`). The schema does not
enforce uniqueness on `offers.application_id`; the recipe must check
for an existing non-terminal offer before posting a new one. Each
status transition has a paired side-effect field that must move in
the same PATCH.

## Composition rules

- `offer_label`: composed as
  `"Offer, {candidate.full_name}, {job_opening.job_title}"`, e.g.
  `"Offer, Jane Doe, Senior Engineer"`. The literal prefix is `Offer`,
  comma-space separates the three parts. Both names come from the
  read in step 1.

## Recipe (create as draft)

```bash
# Step 1: parallel-fetch (no dependency between these reads)
# Walk from the application to its candidate and job for the label.
semantius call crud postgrestRequest '{"method":"GET","path":"/job_applications?id=eq.<application_id>&select=id,status,candidate:candidate_id(full_name),job:job_opening_id(job_title)"}'
# expect: array of length 1; if empty, the application id is wrong.
# If embedded-select is not supported, fall back to three GETs.

# Check for an existing non-terminal offer on this application.
semantius call crud postgrestRequest '{"method":"GET","path":"/offers?application_id=eq.<application_id>&status=in.(draft,pending_approval,approved,sent)&select=id,status"}'
# expect: array of length 0; if non-empty, do NOT post a second offer.

# Step 2: branch on read results
# - If the existing-offer read returned any rows: stop here. Do not
#   POST. Ask the user: "An offer is already <status> on this
#   application. Update that one (route to the advance-through-approval
#   recipe below), rescind it (separate flow), or stop?"

# Step 3: compose the label and POST as draft.
semantius call crud postgrestRequest '{
  "method":"POST",
  "path":"/offers",
  "body":{
    "offer_label":"Offer, <candidate.full_name>, <job_opening.job_title>",
    "application_id":"<application_id>",
    "status":"draft",
    "base_salary":<number>,
    "salary_currency":"<ISO 4217, e.g. USD>",
    "candidate_response":"pending",
    "bonus_target":"<optional>",
    "equity_amount":"<optional>",
    "start_date":"<optional, YYYY-MM-DD>",
    "offer_expires_at":"<optional, ISO timestamp>"
  }
}'
# expect: 201 with the new row's id.
```

## Recipe (advance through approval and send)

```bash
# Move to pending_approval (no side-effect field needed).
semantius call crud postgrestRequest '{
  "method":"PATCH","path":"/offers?id=eq.<offer_id>",
  "body":{"status":"pending_approval"}
}'
# expect: 204 No Content.

# Approve: status + approver in the same PATCH.
semantius call crud postgrestRequest '{
  "method":"PATCH","path":"/offers?id=eq.<offer_id>",
  "body":{"status":"approved","approver_user_id":"<approver id>"}
}'
# expect: 204 No Content.

# Send: status + offer_extended_at in the same PATCH.
semantius call crud postgrestRequest '{
  "method":"PATCH","path":"/offers?id=eq.<offer_id>",
  "body":{"status":"sent","offer_extended_at":"<current ISO timestamp>"}
}'
# expect: 204 No Content.
```

The three transitions are intentionally separate calls. Combining
them (e.g. POST as `sent`) bypasses the natural review checkpoints
and breaks the time-to-offer audit trail.

## Validation

- After the create: a single `offers` row exists with this
  `application_id` and `status=draft`.
- After approval: `status=approved` AND `approver_user_id` is non-null.
- After send: `status=sent` AND `offer_extended_at` is non-null.
- After every transition: re-read the row; the audit log carries the
  prior state (`offers` is audit-logged).

## Failure modes (extended)

- **Pre-existing non-terminal offer was missed.** Triggering: the
  step-1 dedupe read was skipped, and the POST went through.
  Recovery: read all `offers` for this `application_id`; pick the
  intended one; PATCH the others to `status=rescinded` with a note
  in `application_notes` explaining why. Reports treat parallel
  active offers as a data integrity problem; resolve quickly.
- **`status=approved` set without `approver_user_id`.** Triggering:
  the agent split the paired write. Recovery: PATCH to add the
  approver. Reports cannot answer "who approved this" until the field
  is set.
- **`status=sent` set without `offer_extended_at`.** Same shape;
  PATCH to add the timestamp.
- **Approver email does not resolve to a user.** Triggering: the
  user lookup at the start of the approval transition returned empty.
  Recovery: do not invent an id; route to `use-semantius` user
  creation (the approver must exist in `users` first).
- **Application is in a terminal status (hired/rejected/withdrawn).**
  Triggering: step-1 read showed the application is closed. Recovery:
  ask the user whether they meant a different application; do not
  silently extend an offer against a closed pipeline.
