# Delete a tag (with cleanup)

Remove a tag from the catalog. `tags` is the target of a `reference + restrict`
FK from `feature_tags.tag_id`, so the platform refuses a parent DELETE while
any `feature_tags` rows reference the tag. The recipe walks the chain first,
surfaces the number of attached features, and asks the user to confirm a
cascade before deleting.

## FK & shape assumptions

- `tags.tag_name` is unique, resolve with `tag_name=eq.<value>`.
- `feature_tags.tag_id -> tags.id`, `reference + restrict`. The platform
  rejects the parent DELETE with a foreign-key constraint error while any
  child rows exist.
- `feature_tags.feature_id -> features.id`, `parent + cascade`. Deleting the
  junction rows does not affect features.
- Edit on `tags` requires `product_roadmap:admin` per the entity's
  `**Edit permission:** admin` declaration; the caller must hold it (or have
  it via rollup).

## Composition rules

None.

## Recipe

```bash
# Step 1: resolve the tag
enc_name=$(printf '%s' "$tag_name" | jq -sRr @uri)
tag=$(semantius call crud postgrestRequest --single \
  "{\"method\":\"GET\",\"path\":\"/tags?tag_name=eq.${enc_name}&select=id,tag_name\"}")
# expect: --single; abort with "tag '<name>' not found" on zero rows.
tag_id=$(printf '%s' "$tag" | jq -r '.id')

# Step 2: count and preview the attached feature_tags rows
links=$(semantius call crud postgrestRequest \
  "{\"method\":\"GET\",\"path\":\"/feature_tags?tag_id=eq.${tag_id}&select=id,feature_id,feature_tag_label&limit=50\"}")
# expect: array-default; empty array means no cleanup needed.

count=$(printf '%s' "$links" | jq 'length')

if [ "$count" -gt 0 ]; then
  # Step 3: ask the user before cascading. Show the count and a sample of
  # affected features (the feature_tag_label carries "<feature_title> /
  # <tag_name>" so it reads cleanly). Phrasing:
  #   "The tag '<name>' is currently attached to <count> features (sample
  #    below). Deleting it will remove every feature_tags link first, then
  #    the tag itself. Proceed?"
  # If the user declines, STOP. Do not delete anything.
  # If the user confirms, continue to Step 4.
  :
fi

# Step 4: delete the junction rows (idempotent, a re-run with zero links is
# a no-op)
semantius call crud postgrestRequest \
  "{\"method\":\"DELETE\",\"path\":\"/feature_tags?tag_id=eq.${tag_id}\"}"
# expect: array-default; success returns the deleted rows.

# Step 5: delete the tag
semantius call crud postgrestRequest \
  "{\"method\":\"DELETE\",\"path\":\"/tags?id=eq.${tag_id}\"}"
# expect: array-default; success returns the deleted tag row.

# Step 6: verify
semantius call crud postgrestRequest \
  "{\"method\":\"GET\",\"path\":\"/tags?id=eq.${tag_id}&select=id\"}"
# expect: array-default; empty array confirms the tag is gone.

semantius call crud postgrestRequest \
  "{\"method\":\"GET\",\"path\":\"/feature_tags?tag_id=eq.${tag_id}&select=id\"}"
# expect: array-default; empty array confirms no orphan junction rows.
```

## Validation

- The `tags` row is gone (Step 6 verify returns `[]`).
- No `feature_tags` rows reference the deleted `tag_id` (Step 6 second verify
  returns `[]`).
- Features that previously carried the tag are untouched (their other tag
  links and every non-tag field are unchanged).

## Failure modes (extended)

- **Caller lacks `product_roadmap:admin`.** The DELETE on `tags` is rejected
  by the platform's row-level edit-permission check. Recovery: hand off to an
  administrator. Detect by reading the tag row after the DELETE attempt; if
  it is still present, the DELETE did not land.

- **Race: a new `feature_tags` row is inserted between Step 4 and Step 5.**
  The Step 5 parent DELETE is rejected with the `restrict` foreign-key error.
  Recovery: re-run the script; the second attempt picks up the new junction
  row in Step 2 and re-confirms with the user. Do not loop the script
  automatically; the new link signals that another user wants the tag alive.

- **User declines the cascade at Step 3.** Stop without deleting anything.
  The recipe is idempotent on re-run; no state to clean up.

- **Tag is in use by a hidden / archived feature that the read filtered out.**
  Not applicable in this model, `feature_tags` has no soft-delete column and
  every row is read. If a future model change adds one, this recipe must be
  regenerated.
