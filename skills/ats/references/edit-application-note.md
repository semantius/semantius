# Edit / delete an application note

UPDATE or DELETE an `application_notes` row. The platform's `edit_restricted_to_author_or_manager` rule gates every UPDATE / DELETE: the caller must be the original `author_user_id`, or hold the elevated `ats:manage_all_notes` permission. The recipe reads the row first, surfaces the author identity to the caller, and asks before attempting the write when the caller is not the author. The `author_immutable_after_first_save` rule freezes `author_user_id` after creation, so PATCH bodies must omit it.

## FK & shape assumptions

- `application_notes.application_id -> job_applications.id` (reference, cascade; the note dies with the application)
- `application_notes.author_user_id -> users.id` (reference, restrict; the author cannot be deleted while their notes exist)
- `application_notes` is **not** audit-logged; edits and deletions overwrite without a per-row history.
- The platform enforces `edit_restricted_to_author_or_manager` on UPDATE / DELETE (INSERT is unrestricted).
- The platform enforces `author_immutable_after_first_save` on UPDATE; never include `author_user_id` in a PATCH body.

## Composition rules

This recipe does not compose any label. `note_subject` is caller-supplied and edited verbatim; the recipe surfaces it as the label of the row but does not re-derive it.

## Recipe

```bash
# Step 1: read the note row to determine the author and surface to the caller.
# expect: --single, exactly one note; exit 1 with "note '<id>' not found" if missing.
note=$(semantius call crud postgrestRequest --single \
  "{\"method\":\"GET\",\"path\":\"/application_notes?id=eq.<note_id>&select=id,note_subject,author_user_id,visibility,users:author_user_id(display_name,email_address)\"}")

# Step 2: branch on caller identity.
#   If <caller_user_id> equals note.author_user_id: proceed to step 3 directly (author edit path).
#   Otherwise: ASK THE USER ("This note was authored by <author display_name>; editing or deleting
#     a note authored by someone else requires the ats:manage_all_notes permission (held by hiring leads
#     and HR partners). Proceed as a manager, hand off to <author display_name>, or abort?"). Looks good?
#   Do not attempt the write blind; if the caller lacks both ownership and the override, the platform
#   throws edit_restricted_to_author_or_manager and the user gets a confusing error.

# Step 3: write (PATCH for edit, DELETE for delete).
#
# Edit mode (PATCH):
# expect: --single, the updated row. Never include author_user_id in the body; it is immutable.
semantius call crud postgrestRequest --single "{
  \"method\":\"PATCH\",
  \"path\":\"/application_notes?id=eq.<note_id>\",
  \"body\":{
    \"note_subject\":\"<new subject or omit to keep>\",
    \"note_body\":\"<new body or omit to keep>\",
    \"visibility\":\"<hiring_team|recruiter_only|public or omit to keep>\"
  }
}"
#
# Delete mode (DELETE):
# expect: --single (or empty body); the row is gone.
semantius call crud postgrestRequest --single \
  "{\"method\":\"DELETE\",\"path\":\"/application_notes?id=eq.<note_id>\"}"

# Step 4: verify.
# Edit: read the row and confirm the changed fields match the input; author_user_id is unchanged.
# expect: --single.
semantius call crud postgrestRequest --single \
  "{\"method\":\"GET\",\"path\":\"/application_notes?id=eq.<note_id>&select=id,note_subject,note_body,visibility,author_user_id\"}"

# Delete: read by id and confirm zero rows.
# expect: array; zero rows is the success branch.
semantius call crud postgrestRequest \
  "{\"method\":\"GET\",\"path\":\"/application_notes?id=eq.<note_id>&select=id\"}"
```

## Validation

- On edit: the targeted fields changed; `author_user_id` is unchanged; `application_id` is unchanged.
- On delete: a follow-up read returns zero rows.
- The caller's identity was either the author or a `ats:manage_all_notes` holder when the write succeeded.

## Failure modes (extended)

- **Platform code `edit_restricted_to_author_or_manager`.** The caller is not the author and lacks `ats:manage_all_notes`. The recipe's step-2 branch should catch this before the PATCH; if the platform throws anyway, surface the rule's message verbatim. Recovery: ask the user to hand off the edit to the original author (typically the right path for a recruiter correcting their own note), or escalate to an HR partner / hiring lead who holds `ats:manage_all_notes`. Never attempt to PATCH `author_user_id` to the caller; the platform also enforces `author_immutable_after_first_save` and the workaround is impossible by design.
- **Platform code `author_immutable_after_first_save`.** The PATCH body included `author_user_id`. The recipe omits it; if this fires, the recipe was hand-modified. Drop the field from the body and retry.
- **Note not found.** The id is wrong or the parent application was already deleted (cascade). Surface clearly and abort.
- **Edit-then-delete race.** If a caller PATCHes and then immediately DELETEs in the same workflow, the delete is unaffected by the platform's rule scope (rules apply per-write); no extra handling needed.
- **Visibility change to `public`.** The platform does not gate visibility transitions, but a note flipping to `public` is visible to the candidate. Ask the user to confirm when the input flips visibility to `public` from `hiring_team` or `recruiter_only`; this is the only judgment branch the edit-mode path adds beyond the author-or-manager gate.
