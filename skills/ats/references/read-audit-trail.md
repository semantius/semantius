# Read decision audit trail

Surface the audit history for one row in an audit-logged ATS entity.
Used when the user asks "who changed X", "when did Y happen", or "show
the history of Z". The audit-logged entities in this domain are
`job_openings`, `candidates`, `job_applications`, `interview_feedback`,
and `offers`; nothing else carries automatic audit rows.

## FK & shape assumptions

- The Semantius platform writes audit rows automatically on every INSERT/UPDATE/DELETE for an entity declared `audit_log: true`. The audit endpoint shape (URL path, response columns) is platform-managed and is documented in `use-semantius` `references/crud-tools.md` under the Audit subsection. The recipe defers to that path shape rather than baking it in here, because platform versions differ.
- Audit rows reference the source row by `(entity_table, row_id)`. Looking up a row's history is a filtered read against the audit endpoint, not a join in cube.
- The user-facing audit fields typically include the changed columns, the previous and new values, the actor (`user_id` or system), and the timestamp.

## Composition rules

None. This recipe reads, it does not write.

## Recipe

```bash
# Step 1: validate that the target entity is in the audit-logged set.
# Refuse if the user named users / departments / application_stages /
# candidate_sources / candidate_documents / application_notes / interviews /
# hiring_team_members; those are not audit-logged in this domain.

# Step 2: resolve the target row id from the user's pair (candidate name,
# job code, offer label, etc.). Use the same lookup conventions as other
# JTBDs:
#   - job_openings: job_code (eq) preferred; job_title (wfts) accepted.
#   - candidates: email_address (eq) preferred; full_name (wfts) accepted.
#   - job_applications: pair (candidate, job) -> applications array, then disambiguate.
#   - interview_feedback: (candidate, interview_kind, interviewer email) -> single row.
#   - offers: application_id + status filter -> offers array.

# expect: --single (lookup by id / unique column) or array (fuzzy lookup).

# Step 3: query the audit endpoint for the resolved row. The exact path
# shape lives in use-semantius references/crud-tools.md; consult that
# reference at call time. The shape is roughly:
#   GET /<audit-prefix>?entity_table=eq.<table>&row_id=eq.<id>&order=changed_at.desc
# but the column names and the prefix can vary by Semantius version.

# expect: array; zero rows is "no history yet" (the row was created but never
# updated, or audit logging was toggled on after the row was created).

# Step 4: present the rows to the user. Group by changed_at descending.
# For each row, name the changed columns, the actor (user_full_name from a
# joined users read if the audit row has a user_id), and the new values.
# If the audit row contains a previous-vs-new payload, surface both.
```

## Validation

- The returned audit rows reference the resolved row's `id` and the named entity's table.
- The columns reported as changed actually exist on the entity in the current schema (cross-check by reading one entity row's `select=*` and confirming the column name; on column-rename drift the audit history may reference the old column name).
- If the user asked for a time window, every returned row's timestamp falls inside that window.

## Failure modes (extended)

- **Target entity not audit-logged.** The recipe refuses on step 1. Tell the user which entity is being asked about and offer the closest audit-logged neighbor: for `interviews` -> the parent `job_applications`; for `application_notes` -> the parent `job_applications`; for `candidate_documents` -> the parent `candidates`; for `hiring_team_members` -> not really substitutable; the user's question may need to be answered from `created_at` / `updated_at` columns directly via `use-semantius`.
- **Audit endpoint path shape changed.** If the call shape from `use-semantius` `references/crud-tools.md` returns a 404 or unexpected payload, the platform version has drifted past what the reference documents. Abort with a clear stderr message naming the suspected drift and recommend running `semantius -d` to discover the current audit-tool surface.
- **Audit rows reference a column the current entity no longer has.** A column was renamed or dropped after the audit row was written. Surface the audit row's column name verbatim and explain to the user that the column has since been renamed or removed; do not silently translate to the current name.
- **The actor is `null` or `system`.** Some audit rows reflect platform-initiated writes (cascades, validation rejections that still wrote audit rows for the failed-write attempt). Report verbatim; do not invent an actor.
- **Long audit histories.** If the row has many years of history, paginate via `limit` / `offset` rather than loading everything; the user's question is usually about the most recent N changes.
