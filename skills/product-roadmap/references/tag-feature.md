# Tag a feature

Add or remove a tag on a feature via the `feature_tags` junction.
The load-bearing invariant is junction uniqueness: the table has no
DB-level constraint on `(feature_id, tag_id)`, so the recipe must
read first and skip the POST if the pair already exists. POSTing
without the read pollutes "what tags does this feature have" lists.

## Composition rules

`feature_tags.feature_tag_label` is required on insert and
caller-populated. Compose as:

```
{feature.feature_title} / {tag.tag_name}
```

Separator is exactly ` / ` (space, ASCII forward slash, space).
Both values come from the read-first calls in step 1.

## Tag existence rule

If the `tag_name` the user named does not exist in `tags`, **ask
before creating one**. Tags are reusable categorization, not
free-form. Silently auto-creating tags fragments the taxonomy
(`mobile-app`, `mobile`, `Mobile` all coexisting). The `tag_name`
column is unique, so the fragment slips past the DB.

## Recipe (add a tag)

```bash
# Step 1: parallel-fetch (no dependency between these reads).
# expect: array (wfts can return zero / one / many); zero means ask
#         the user to clarify, many means present candidates and ask.
semantius call crud postgrestRequest '{"method":"GET","path":"/features?search_vector=wfts(simple).<feature term>&select=id,feature_title"}'
# expect: array; tag_name is unique so the result is zero or one. Zero
#         is the "ask before creating" branch (Tag existence rule).
semantius call crud postgrestRequest '{"method":"GET","path":"/tags?tag_name=eq.<name>&select=id,tag_name"}'

# Step 2: branching guards (consumes step 1).
#   - If the tag lookup returned zero rows, ask the user before
#     creating a new tag. Do not auto-create.

# Step 3: dedupe lookup (consumes step 1, needs both ids).
# expect: array (zero or one row); zero is the "POST new" branch,
#         one is the "do nothing" branch.
semantius call crud postgrestRequest '{"method":"GET","path":"/feature_tags?feature_id=eq.<feature id>&tag_id=eq.<tag id>&select=id"}'

# Step 4a (no existing pair): POST. Compose feature_tag_label from
# step 1 values.
# expect: array (write returns the inserted row); exit-code guard only.
semantius call crud postgrestRequest '{
  "method":"POST",
  "path":"/feature_tags",
  "body":{
    "feature_tag_label":"<feature_title from step 1> / <tag_name from step 1>",
    "feature_id":"<feature id>",
    "tag_id":"<tag id>"
  }
}'

# Step 4b (pair exists): do nothing; tell the user.

# Step 5: verify exactly one row.
# expect: --single; if step 4a ran or the pair already existed,
#         exactly one row matches.
semantius call crud postgrestRequest --single '{"method":"GET","path":"/feature_tags?feature_id=eq.<feature id>&tag_id=eq.<tag id>&select=id,feature_tag_label"}'
```

## Recipe (remove a tag)

```bash
# Resolve feature and tag (same step 1 as above), then:
# expect: array (DELETE returns the removed rows; zero rows is fine
#         and means the pair was already absent).
semantius call crud postgrestRequest '{
  "method":"DELETE",
  "path":"/feature_tags?feature_id=eq.<feature id>&tag_id=eq.<tag id>"
}'
```

## Validation

- Add: exactly one `feature_tags` row exists for the
  `(feature_id, tag_id)` pair.
- Add: `feature_tag_label` matches
  `"<feature_title> / <tag_name>"` with the values read in step 1.
- Remove: zero rows match the `(feature_id, tag_id)` pair.
- No new tag was silently created during the recipe; if a tag was
  added, the user explicitly asked for it.

## Failure modes (extended)

- **Tag the user named does not exist.** Ask before creating one.
  Recovery: confirm, then create the tag via `use-semantius` (CRUD
  tools) with a deliberate `tag_name`, `tag_color`, optional
  `tag_description`; then re-run this recipe with the new id.
  Auto-creating from a casual mention fragments the taxonomy and is
  hard to undo.
- **POST without the read-first dedupe (skipped step 3).** The
  table accepts a duplicate row. Detect:
  `select count(*) from feature_tags where feature_id=X and
  tag_id=Y` returns >1. Recovery: keep one, DELETE the rest. Both
  rows have the same `(feature_id, tag_id)` so picking which to
  keep is arbitrary; pick the lowest `id` and delete the others.
- **Casing or typo difference between user's input and existing
  tag** (e.g. user says "Mobile", tag is `mobile`). The
  `tag_name=eq.<name>` lookup returns zero. Recovery: try a
  `wfts(simple)` lookup as a sanity check; if a near-match exists,
  ask the user whether they meant that tag instead of creating a
  new one.
