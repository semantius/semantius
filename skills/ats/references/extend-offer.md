# Extend an offer

Create or progress an `offers` row through `draft` -> `pending_approval` -> `approved` -> `sent`. The `approved` transition hits the platform-enforced `ats:approve_offer` permission gate, which is why this is a reference and not a script: the recipe pre-flights the caller's permission and routes hand-off to an approver when the caller cannot self-approve. The recipe also asks the user before creating a second active offer when one already exists on the application.

## FK & shape assumptions

- `offers.application_id -> job_applications.id` (reference, restrict; offers survive any cleanup attempt of the application)
- `offers.approver_user_id -> users.id` (reference, clear, optional until status reaches `approved`)
- `offers` is audit-logged; the approval event is captured automatically.
- No DB-level unique constraint on `(application_id, status='active-ish')`; the platform accepts multiple non-terminal offers on the same application.
- The platform enforces `approve_offer_requires_approver_permission` on the status transition into `approved`: only callers holding `ats:approve_offer` may make the flip. The static `edit_permission` (`ats:manage`) lets the team draft and route.
- The platform enforces `approver_user_id_required_when_approved`: once status is `approved`, `approver_user_id` must be non-null.
- The platform enforces `post_draft_status_requires_extended_at` and `extended_at_only_when_post_draft`: `offer_extended_at` must be set on `sent` and may NOT be set before `sent`.

## Composition rules

- `offer_label` (required, caller-populated): compose as `"Offer, {candidates.full_name}, {job_openings.job_title}"`. Comma-space separators. Both names come from the read-first calls; do not invent.

## Recipe

```bash
# Step 1: parallel-fetch the application + joined candidate / job + any existing offers on the application.
# expect: --single, exactly one application; exit 1 with "application not found" if missing.
application=$(semantius call crud postgrestRequest --single \
  "{\"method\":\"GET\",\"path\":\"/job_applications?candidate_id=eq.<candidate_id>&job_opening_id=eq.<job_opening_id>&status=eq.active&select=id,candidates(full_name),job_openings(job_title)\"}")

# expect: array; zero rows is "create new draft", one or more is "branch on existing offers".
existing_offers=$(semantius call crud postgrestRequest \
  "{\"method\":\"GET\",\"path\":\"/offers?application_id=eq.<application_id>&select=id,status,offer_label,base_salary,approver_user_id&order=created_at.desc\"}")

# Step 2: branch on existing offers.
#   No active offer (every row is in declined / rescinded / expired): proceed to create a new draft.
#   At least one active offer (status in draft / pending_approval / approved / sent / accepted): ASK THE USER
#     ("an active offer for <candidate> on <job> already exists at status=<X>. Create a parallel offer,
#     advance the existing one, or abort?"). Looks good? Do not silently create a duplicate.

# Step 3: pre-flight the permission check when target status is `approved`.
# expect: --single, the caller's user_role rows for ats:approve_offer.
# Read use-semantius references/rbac.md for the exact tool shape; the literal call is roughly:
caller_has_approve=$(semantius call crud postgrestRequest \
  "{\"method\":\"GET\",\"path\":\"/user_role?user_id=eq.<caller_user_id>&select=role(role_permission(permission(permission_code)))\"}")
# Parse the embedded permission_code list. If `ats:approve_offer` is not present AND the target status
# is `approved`: ASK THE USER ("Approving an offer requires the ats:approve_offer permission, typically
# held by hiring leaders and recruiting directors. Hand off to an approver, proceed as a different user,
# or abort?"). Do not attempt the approve PATCH blind; the platform will throw with the rule code below.

# Step 4: write the offer (POST for new draft, PATCH for existing).
#
# Target status = draft (create):
# expect: --single, exactly one row written.
semantius call crud postgrestRequest --single "{
  \"method\":\"POST\",
  \"path\":\"/offers\",
  \"body\":{
    \"offer_label\":\"Offer, <candidates.full_name>, <job_openings.job_title>\",
    \"application_id\":\"<application_id>\",
    \"status\":\"draft\",
    \"base_salary\":<base_salary>,
    \"bonus_target\":<bonus_target or omit>,
    \"equity_amount\":\"<free text or omit>\",
    \"start_date\":\"<YYYY-MM-DD or omit>\",
    \"offer_expires_at\":\"<ISO timestamp or omit>\"
  }
}"
#
# Target status = pending_approval (PATCH existing draft):
semantius call crud postgrestRequest --single "{
  \"method\":\"PATCH\",
  \"path\":\"/offers?id=eq.<offer_id>\",
  \"body\":{\"status\":\"pending_approval\"}
}"
#
# Target status = approved (PATCH; pair approver_user_id; the platform enforces the permission gate):
# expect: --single. On platform throw of approve_offer_requires_approver_permission, surface the
# rule's message and route to the hand-off branch from step 3.
semantius call crud postgrestRequest --single "{
  \"method\":\"PATCH\",
  \"path\":\"/offers?id=eq.<offer_id>\",
  \"body\":{
    \"status\":\"approved\",
    \"approver_user_id\":\"<approver_user_id>\"
  }
}"
#
# Target status = sent (PATCH; pair offer_extended_at):
semantius call crud postgrestRequest --single "{
  \"method\":\"PATCH\",
  \"path\":\"/offers?id=eq.<offer_id>\",
  \"body\":{
    \"status\":\"sent\",
    \"offer_extended_at\":\"<current ISO timestamp>\"
  }
}"

# Step 5: verify the write.
# expect: --single, the row we just wrote.
semantius call crud postgrestRequest --single \
  "{\"method\":\"GET\",\"path\":\"/offers?id=eq.<offer_id>&select=id,offer_label,status,base_salary,approver_user_id,offer_extended_at\"}"
```

## Validation

- The `offers` row exists with the target status.
- When target status is `approved`: `approver_user_id` is non-null and matches the resolved approver.
- When target status is `sent`: `offer_extended_at` is set in the same PATCH.
- `offer_label` matches the composition rule.
- No parallel non-terminal offer was silently created.

## Failure modes (extended)

- **Platform code `approve_offer_requires_approver_permission`.** The caller does not hold `ats:approve_offer`. The recipe's step-3 pre-flight should catch this before the PATCH; if the live permission set drifts between pre-flight and write (a race), the platform's throw lands. Surface the rule's message verbatim. Recovery: identify the offer-approver (typically a hiring leader or recruiting director), confirm with the user, and re-run the recipe with that user as the acting caller; or have the user PATCH the offer themselves under their own session.
- **Platform code `approver_user_id_required_when_approved`.** The PATCH set `status=approved` without `approver_user_id`. The recipe pairs both in one body; if this fires, the recipe was modified or the call was hand-edited. Surface verbatim.
- **Platform code `post_draft_status_requires_extended_at`.** The PATCH set `status=sent` (or beyond) without `offer_extended_at`. The recipe pairs both; if this fires, the recipe was modified. Surface verbatim.
- **Platform code `extended_at_only_when_post_draft`.** The PATCH set `offer_extended_at` while status is still `draft` / `pending_approval` / `approved`. Move status to `sent` in the same call, or drop the timestamp.
- **Platform code `extended_before_expires` or `extended_before_responded`.** Caller passed inconsistent timestamps. Surface verbatim; re-prompt for corrected dates.
- **Parallel active offer.** The recipe asks before creating a second active offer. The user may legitimately want a parallel offer (renegotiation, alternative role), so the recipe does not refuse, but it does not silently proceed either.
- **Application not active.** If the application is `rejected`, `withdrawn`, `on_hold`, or `hired`, refuse and surface. Extending an offer on a non-active application is almost always a re-key error.
