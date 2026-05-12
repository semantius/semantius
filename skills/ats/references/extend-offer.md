# Extend an offer

Walk an `offers` row through the lifecycle `draft` -> `pending_approval`
-> `approved` -> `sent`, with paired timestamps and an explicit
approver. The recipe handles each transition as its own write because
the platform-enforced timestamp pairings differ at each step, and
because some transitions need a user confirmation (parallel offers on
the same application; non-standard salary band).

## FK & shape assumptions

- `offers.application_id -> job_applications.id` (reference, **restrict**: an offer survives a `delete` of the application; the offer of record is preserved).
- `offers.approver_user_id -> users.id` (reference, clear, optional).
- `offers` is audit-logged; status changes, salary fields, and approver are on the audit trail automatically.
- No DB-level uniqueness on `(application_id, status='active'-ish)`. The recipe asks the user before extending a parallel offer when an existing offer is in `pending_approval` / `approved` / `sent` / `accepted`.
- Platform invariants in this entity (full list in SKILL.md preamble): `base_salary_non_negative`, `bonus_target_non_negative`, `post_draft_status_requires_extended_at`, `extended_at_only_when_post_draft`, `responded_at_required_when_responded`, `responded_at_only_when_responded`, `extended_before_expires`, `extended_before_responded`. The recipe NEVER pre-validates these; it pairs the side-effect fields and surfaces the platform's error verbatim on failure.

## Composition rules

- `offer_label` (required on draft, caller-populated): compose as
  `"Offer, <candidates.full_name>, <job_openings.job_title>"`. Both
  values come from the read-first calls in step 1. Example:
  `"Offer, Jane Doe, Senior Engineer"`.

## Recipe

The recipe has four entry points (`draft`, `pending_approval`,
`approved`, `sent`). The agent picks one based on the user's intent;
each entry point is a self-contained mini-recipe.

### Entry: create a draft offer

```bash
# Step 1: parallel-fetch.
# expect: --single each.
candidate=$(semantius call crud postgrestRequest --single \
  "{\"method\":\"GET\",\"path\":\"/candidates?id=eq.<candidate_id>&select=full_name\"}")
job_opening=$(semantius call crud postgrestRequest --single \
  "{\"method\":\"GET\",\"path\":\"/job_openings?id=eq.<job_opening_id>&select=job_title,salary_min,salary_max,salary_currency\"}")
application=$(semantius call crud postgrestRequest --single \
  "{\"method\":\"GET\",\"path\":\"/job_applications?id=eq.<application_id>&select=id,status\"}")

# Step 2: parallel-offer guard.
# expect: array; zero rows is the go-ahead, one or more is "ask the user".
existing=$(semantius call crud postgrestRequest \
  "{\"method\":\"GET\",\"path\":\"/offers?application_id=eq.<application_id>&status=in.(draft,pending_approval,approved,sent,accepted)&select=id,offer_label,status\"}")
# If existing is non-empty: ASK THE USER whether to extend a parallel offer
# (rare; usually the existing offer should be rescinded first). Surface
# offer_label and status from the rows.

# Step 3: salary-band sanity. If base_salary lies outside
# [job_opening.salary_min, job_opening.salary_max]: ASK THE USER. The platform
# does not enforce band-vs-offer agreement; the recipe does.

# Step 4: POST the draft.
# expect: --single, one row written.
semantius call crud postgrestRequest --single "{
  \"method\":\"POST\",
  \"path\":\"/offers\",
  \"body\":{
    \"offer_label\":\"Offer, <candidates.full_name>, <job_openings.job_title>\",
    \"application_id\":\"<application_id>\",
    \"status\":\"draft\",
    \"base_salary\":<base_salary>,
    \"salary_currency\":\"<salary_currency ISO 4217>\",
    \"bonus_target\":<bonus_target or null>,
    \"equity_amount\":\"<equity_amount or null>\",
    \"start_date\":\"<start_date YYYY-MM-DD or null>\",
    \"offer_expires_at\":\"<offer_expires_at ISO timestamp or null>\",
    \"candidate_response\":\"pending\"
  }
}"
```

### Entry: move draft -> pending_approval

```bash
# expect: --single, the offer row updated.
semantius call crud postgrestRequest --single "{
  \"method\":\"PATCH\",
  \"path\":\"/offers?id=eq.<offer_id>\",
  \"body\":{\"status\":\"pending_approval\"}
}"
```

No paired field; this transition is a pure status flip.

### Entry: move pending_approval -> approved

```bash
# expect: --single. ASK THE USER for the approver email; resolve to user id first.
approver=$(semantius call crud postgrestRequest --single \
  "{\"method\":\"GET\",\"path\":\"/users?email_address=eq.<approver_email>&select=id\"}")

semantius call crud postgrestRequest --single "{
  \"method\":\"PATCH\",
  \"path\":\"/offers?id=eq.<offer_id>\",
  \"body\":{
    \"status\":\"approved\",
    \"approver_user_id\":\"<approver_user_id>\"
  }
}"
```

### Entry: move approved -> sent

```bash
# expect: --single. The status flip and offer_extended_at MUST go in one PATCH.
semantius call crud postgrestRequest --single "{
  \"method\":\"PATCH\",
  \"path\":\"/offers?id=eq.<offer_id>\",
  \"body\":{
    \"status\":\"sent\",
    \"offer_extended_at\":\"<current ISO timestamp>\"
  }
}"
```

If the user has already specified `offer_expires_at` on the draft, the
platform's `extended_before_expires` check enforces ordering; if not,
the agent should ask whether to set one in the same write (e.g.
`<scheduled_end ISO timestamp>` 7 days out is a common policy, but the
recipe does not assume).

## Validation

- For each entry, the post-write read confirms the new `status` and the paired field. For `sent`, `offer_extended_at` is non-null and equals the value in the PATCH.
- For `approved`, `approver_user_id` is non-null and resolves to a real `users.id`.
- The `application_id`'s parent `job_applications.status` is still `active` (or `on_hold`); offers should not be extended against terminal applications.

## Failure modes (extended)

- **Platform code `post_draft_status_requires_extended_at`.** The PATCH flipped status to `sent` (or further) without `offer_extended_at`. The recipe pairs the field; this code only fires on schema drift or a manual PATCH. Surface verbatim and re-issue with the timestamp.
- **Platform code `extended_at_only_when_post_draft`.** The caller set `offer_extended_at` while status was still `draft`/`pending_approval`/`approved`. Recovery: clear `offer_extended_at` in a follow-up PATCH OR flip status to `sent` in the same call.
- **Platform code `extended_before_expires`.** `offer_expires_at` precedes `offer_extended_at`. Ask the user for a corrected expiry (typically `offer_extended_at + 7 days`).
- **Platform code `base_salary_non_negative` / `bonus_target_non_negative`.** Negative monetary value. Ask the user to correct.
- **Parallel offer exists and the user wants to proceed anyway.** The platform allows this; the recipe just warned. Proceed with the POST. The subsequent "Record offer acceptance and hire" JTBD will pick whichever offer the candidate responds to; the parallel offer should be `rescinded` afterward. The recipe does not auto-rescind.
- **Application is `hired`/`rejected`/`withdrawn`.** Refuse on the application-status read; do not let the user extend an offer against a terminal application. They must reopen the application via `use-semantius` first.
- **Salary band drift.** If a `compensation_management` module is deployed and `job_openings.salary_band_id` is set, the offer should anchor to the same band. The recipe does not check this; mention it in the user prompt and recommend running the band check via `use-semantius`.
