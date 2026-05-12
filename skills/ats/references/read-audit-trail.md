# Read decision audit trail

Read the audit history for one row in an audit-logged ATS table. The five audit-logged tables in this model are `job_openings`, `candidates`, `job_applications`, `interview_feedback`, and `offers`; every INSERT/UPDATE/DELETE on these tables is captured by the platform automatically. Other entities (`departments`, `application_stages`, `candidate_sources`, `users`, `candidate_documents`, `application_notes`, `interviews`, `hiring_team_members`) are not audit-logged; the recipe surfaces that clearly when the caller asks about an unaudited entity.

## FK & shape assumptions

- The audit log is platform-managed; recipes never write to it.
- Audit rows carry: the entity name, the row id, the actor user id, the timestamp, the operation (`insert` / `update` / `delete`), and the JSON diff (`before` / `after` per changed field).
- The endpoint shape is platform-specific; consult `use-semantius` `references/crud-tools.md` for the exact path. The recipe below names the contract by intent; map to the live tool name at call time.

## Composition rules

No composition. The recipe reads only.

## Recipe

```bash
# Step 1: confirm the target entity is audit-logged. If not, surface clearly and stop.
# The audit-logged set is fixed: job_openings, candidates, job_applications, interview_feedback, offers.
# If the user asks about an unaudited entity (departments, application_stages, users, candidate_documents,
# application_notes, interviews, candidate_sources, hiring_team_members), surface:
#   "<entity> is not audit-logged in this model. Recent edits are not recoverable from the audit trail;
#    consult the row's current state, or for application_notes edits the only record is the live row
#    (author_immutable_after_first_save guarantees the author field stays accurate)."

# Step 2: read the audit history for the row. The platform-managed audit endpoint accepts entity + id.
# expect: array; zero rows is "no recorded changes after creation" (still a valid result).
# See use-semantius references/crud-tools.md for the exact tool name and path shape on this deployment.
semantius call crud postgrestRequest \
  "{\"method\":\"GET\",\"path\":\"/audit_log?entity_name=eq.<entity>&row_id=eq.<row_id>&select=changed_at,actor_user_id,operation,changes&order=changed_at.asc\"}"

# Step 3: resolve actor user ids to display names for human readability (optional).
# expect: array; one row per distinct actor_user_id from step 2.
semantius call crud postgrestRequest \
  "{\"method\":\"GET\",\"path\":\"/users?id=in.(<comma-separated actor ids>)&select=id,display_name,email_address\"}"

# Step 4: present the merged timeline to the user, ordered by changed_at ascending.
# Each entry: timestamp, actor display_name, operation, the per-field before/after diff.
```

## Validation

- Every audit row in the response carries `changed_at`, `actor_user_id`, and a `changes` payload.
- The earliest row's `operation` is `insert`; subsequent rows are `update` (or `delete` if the row was removed).
- The actor ids resolve cleanly against `users` (some may be soft-removed; `is_active=false` is still a valid actor).

## Failure modes (extended)

- **Entity is not audit-logged.** Surface the fixed audit-logged set and stop. Do not invent a partial timeline from `created_at` / `updated_at`; those two columns exist on every table but are not an audit trail (no actor, no per-field diff).
- **Row not found.** The row id is wrong, or the row was deleted and the audit trail's delete entry was also pruned (deployment-dependent). Surface clearly and ask the user to re-confirm the id.
- **Audit endpoint path differs.** The exact endpoint shape (`/audit_log`, `/audits`, `/<entity>_audit`) is platform-specific. If the GET 404s, consult `use-semantius` `references/crud-tools.md` for the live path on this deployment; do not guess.
- **Actor resolves to a soft-removed user.** The actor row still resolves but carries `is_active=false`. Surface the display name with the inactive flag; do not filter the actor out (the audit entry is historical and the actor's current status is irrelevant to the historical fact).
