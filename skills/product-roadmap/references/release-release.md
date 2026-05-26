# Release a release

Mark a release as released, with paired `actual_release_date`. This transition
is gated by the `product_roadmap:release_release` permission; the recipe
pre-flights against the caller's permissions before attempting the write so
the user can hand off cleanly instead of hitting the platform's throw blind.
Once released, the release is one-way terminal and every attached feature is
frozen against further edits.

## FK & shape assumptions

- `releases.release_name` is unique, resolve with `release_name=eq.<value>`.
- `features.release_id -> releases.id`, `reference + clear`. Detaching a
  feature on parent delete is the cascade rule, but a `released` release can
  never be deleted in practice (no documented recipe does it) so the clear is
  defensive only.
- Audit logging on `releases` is on, every status flip and date set is
  recorded in the audit trail; no special handling required.

## Composition rules

None. `actual_release_date` is a plain date the caller fills at call time
(today's date by default).

## Recipe

```bash
# Step 1: parallel-fetch (no dependency between these reads)
# 1a: resolve the release by name
enc_name=$(printf '%s' "$release_name" | jq -sRr @uri)
release=$(semantius call crud postgrestRequest --single \
  "{\"method\":\"GET\",\"path\":\"/releases?release_name=eq.${enc_name}&select=id,release_status,actual_release_date\"}")
# expect: --single, exits 1 with stderr if zero rows; abort with
# "release '<name>' not found" and ask the user to confirm the name.

# 1b: check the caller's permissions (so we can hand off cleanly)
me=$(semantius call crud getCurrentUser '{}')
# expect: array-default (object body); inspect .effective_permissions
# for "product_roadmap:release_release" (admins hold it implicitly via
# the product_roadmap:admin rollup).

# Step 2: refuse if the release is not in a transitionable status
release_status=$(printf '%s' "$release" | jq -r '.release_status')
case "$release_status" in
  planned|in_progress) ;;
  released)
    echo "release '$release_name' is already released; no-op" >&2
    exit 0
    ;;
  cancelled)
    echo "release '$release_name' is cancelled; cannot release a cancelled release" >&2
    exit 1
    ;;
esac

# Step 3: pre-flight the permission. If the caller lacks
# product_roadmap:release_release (and is not an admin), STOP and ask the
# user how to proceed:
#   - "This transition requires product_roadmap:release_release, typically
#      held by release managers or product_roadmap:admin holders. Do you want
#      to (a) proceed under a different signed-in user, or (b) hand off to
#      someone who holds the permission?"
# Do not attempt the PATCH if the user picks (b); surface and stop.

# Step 4: PATCH the release. Status and actual_release_date go in one call.
release_id=$(printf '%s' "$release" | jq -r '.id')
body=$(jq -nc \
  --arg s "released" \
  --arg d "$actual_release_date" \
  '{release_status: $s, actual_release_date: $d}')
semantius call crud postgrestRequest \
  "{\"method\":\"PATCH\",\"path\":\"/releases?id=eq.${release_id}\",\"body\":${body}}"
# expect: array-default; success returns the patched row.
# On failure with code: release_requires_release_permission, surface
# the message verbatim and propose the handoff from Step 3.

# Step 5: verify
semantius call crud postgrestRequest --single \
  "{\"method\":\"GET\",\"path\":\"/releases?id=eq.${release_id}&select=release_status,actual_release_date\"}"
# expect: --single; release_status == "released" and actual_release_date set.
```

## Validation

- The release's `release_status` is `released`.
- The release's `actual_release_date` matches the value passed in.
- A subsequent PATCH against any attached feature is rejected by the platform
  with `code: features_locked_when_release_is_released` (spot-check by reading
  one feature's `release_id` and attempting a no-op PATCH; the rejection
  confirms the lock fired).

## Failure modes (extended)

- **Caller lacks the permission.** Platform throws with `code:
  release_requires_release_permission` and `message: "Only release managers
  may set a release's status to released."` The recipe's Step 3 pre-flight
  catches this before the PATCH; the fallback (surface the throw, propose
  handoff) only fires if the pre-flight was wrong (the user said they had the
  permission but `getCurrentUser` disagreed, or the permission was revoked
  between the read and the write). Recovery: hand off to a release manager or
  to a holder of `product_roadmap:admin`. Detect after the fact by reading
  the release's `release_status`; if still `planned` or `in_progress`, the
  PATCH did not land.

- **Release was concurrently flipped to `released` by another user.** The
  Step 4 PATCH then fires `release_released_is_one_way` (status changed from
  `released` to `released` is a no-op write, but most clients PATCH the
  status field unconditionally; the rule treats any write to a terminal
  status as a change). Surface as a benign race: read the row again, confirm
  it is already `released` with the right `actual_release_date`, treat as
  success.

- **`actual_release_date` is missing on the PATCH.** Platform throws
  `released_requires_actual_date`. The recipe always sets the field, so this
  signals a bug in the recipe rather than a user error. Surface and stop.

- **`actual_release_date` is set, but `release_status` is left unchanged.**
  Platform throws `actual_date_only_when_released`. Same shape as above,
  recipe bug; the PATCH must flip both fields in a single call.

- **One or more features attached to the release are in `in_progress` (work
  not yet finished).** The PATCH still succeeds, but those features are now
  frozen mid-flight. Recovery: there is none short of a new release record.
  Before triggering this recipe, the user should sweep attached features to
  `shipped` (with paired `actual_*_date`) or detach them to a future release.
  The recipe does not enforce this, the workflow assumption is that the user
  has already reconciled the release roster.
