# Tag a feature

Apply a tag to a feature via the `feature_tags` junction. The
`(feature_id, tag_id)` pair has no DB-level uniqueness, so the recipe
must read first. The `tag_name` lookup may miss; in that case the
recipe asks the user before creating the tag, which is why this lives
as a reference rather than a script.

## FK & shape assumptions

- `feature_tags.feature_id -> features.id` (parent, cascade)
- `feature_tags.tag_id -> tags.id` (parent, cascade)
- `(feature_id, tag_id)` junction has **no DB-level unique
  constraint**; recipe MUST read-first before insert to avoid
  duplicate junction rows.
- `tags.tag_name` is **unique** (DB-level); a creating-a-duplicate
  attempt returns 409.

## Composition rules

- `feature_tag_label`: composed as `"{feature_title} / {tag_name}"`.
  ASCII separator ` / ` (space-slash-space). The values come from the
  read-first calls in step 1; do not invent.

## Recipe

```bash
# Step 1: parallel-fetch (no dependency between these reads)
# expect: --single, exactly one feature must match the title; abort on miss / ambiguity
semantius call crud postgrestRequest --single '{"method":"GET","path":"/features?search_vector=wfts(simple).<feature-title-term>&select=id,feature_title"}'
# expect: array, zero rows is the "tag does not exist yet" branch
semantius call crud postgrestRequest '{"method":"GET","path":"/tags?tag_name=eq.<tag-name>&select=id,tag_name"}'

# Step 2: branch on tag lookup
# If tags lookup returned []:
#   ASK THE USER: "Tag '<tag-name>' does not exist yet. Create it?"
#   On yes: POST /tags with {"tag_name":"<tag-name>"}; capture the new id
#   On no: abort with a clear message; do not silently fall through
# If tags lookup returned [{...}]: use that id.

# Step 3: dedupe the junction
# expect: array, zero rows is the "go ahead and insert" branch
semantius call crud postgrestRequest '{"method":"GET","path":"/feature_tags?feature_id=eq.<feature_id>&tag_id=eq.<tag_id>&select=id"}'
# If returned [{...}]: report "feature is already tagged <tag-name>"; exit success.
# If returned []: continue to step 4.

# Step 4: insert the junction with the composed label
semantius call crud postgrestRequest '{
  "method":"POST",
  "path":"/feature_tags",
  "body":{
    "feature_id":"<feature_id>",
    "tag_id":"<tag_id>",
    "feature_tag_label":"<feature_title> / <tag_name>"
  }
}'

# Step 5: verify
# expect: --single, the row we just inserted must exist
semantius call crud postgrestRequest --single '{"method":"GET","path":"/feature_tags?feature_id=eq.<feature_id>&tag_id=eq.<tag_id>&select=id,feature_tag_label"}'
```

## Validation

- The `feature_tags` row exists with the expected `feature_id` and
  `tag_id`.
- `feature_tag_label` is exactly `"<feature_title> / <tag_name>"`,
  composed from the values read in step 1, not from the user's raw
  input.
- A repeat run with the same inputs is a no-op: step 3 hits the
  existing row and the recipe exits at "already tagged".

## Failure modes (extended)

- **Tag lookup returns multiple rows.** `tag_name` is unique, so this
  should be impossible. If it does happen, the live schema lost its
  unique constraint; abort with a clear message and recommend
  regenerating the skill, do not pick one and proceed.
- **POST to `/tags` returns 409.** Two callers tried to create the
  same tag in parallel; the other won. Re-read `/tags?tag_name=eq.<...>`
  to get the now-existing id and continue from step 3.
- **POST to `/feature_tags` returns 409 / unique violation.** The
  live schema added a unique index on `(feature_id, tag_id)` after
  generation; the dedupe in step 3 should have caught it. Treat as
  "already tagged" and report success.
- **Feature lookup returns zero rows.** The title did not match any
  feature. Ask the user to confirm the title or supply more
  distinguishing words; do not guess.
- **Feature lookup returns multiple rows.** The fuzzy search matched
  several. Present the candidates by `feature_title` and ask the user
  to pick; abort if they decline.
- **User declines to create a missing tag.** Exit cleanly with a
  message naming the tag that was not applied; do not write anything.
