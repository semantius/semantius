---
name: customer-data-platform
description: >-
  Use this skill for anything involving the Customer Data Platform, the
  in-house CDP domain that ingests events from sources, resolves identifiers
  into unified profiles, organises profiles into audiences, and activates
  audiences to downstream destinations with consent tracked per purpose.
  Trigger when the user says: "find the profile for alice@example.com",
  "add a device id to this profile", "add this customer to the high-value
  audience", "remove them from the audience", "activate the audience to
  Meta Ads", "create a new audience of repeat buyers", "record marketing
  consent for this profile", "forget this customer", "GDPR delete",
  "merge these two profiles", "what's our profile lifecycle breakdown".
  Loads alongside `use-semantius`, which owns CLI install, PostgREST
  encoding, and cube query mechanics.
semantic_model: customer_data_platform
---

# Customer Data Platform

This skill carries the domain map and the jobs-to-be-done for the Customer
Data Platform. Platform mechanics, CLI install, env vars, PostgREST
URL-encoding, `sqlToRest`, cube `discover` / `validate` / `load`, and
schema-management tools, live in `use-semantius`. Assume it loads
alongside; do not re-explain CLI basics here.

If a task is purely about defining schema, managing permissions, or
running ad-hoc queries against tables you already know, call
`use-semantius` directly, going through this skill adds nothing.

**Auto-managed fields.** Semantius sets `id`, `created_at`, and
`updated_at` on every table; never include them in POST or PATCH bodies.
Every other required field, including the `label_column` field on each
entity, is **caller-populated**. The composite-label entities below
require the recipe to compose the label string explicitly:

- `profiles.profile_label` , best display name (full name, fall back to
  `primary_email`).
- `identities.identity_label` , `"{identity_type}: {identity_value}"`.
- `audience_memberships.membership_label` , `"{audience_name} / {profile_label}"`.
- `audience_activations.activation_label` , `"{audience_name} → {destination_name}"`.
- `consent_records.consent_label` , `"{profile_label} / {consent_purpose} / {status}"`.

Do not omit these `*_label` fields from POST bodies; they are required
and have no DB-level default.

---

## Domain glossary

| Concept | Table | Notes |
|---|---|---|
| Profile (golden record) | `profiles` | One row per resolved person; the unified customer record |
| Identity | `identities` | A single identifier (email, device_id, etc.) tied to a profile; the resolution graph |
| Account (B2B) | `accounts` | Company record; profiles can belong to one; self-references for parent / subsidiary |
| Event | `events` | Behavioural events ingested from sources; high-volume; `profile_id` is null until identity resolution catches up |
| Audience | `audiences` | A defined customer segment with rule logic; lifecycle on `status` |
| Audience membership | `audience_memberships` | Junction; **deactivation is `is_active=false` + `left_at`, never DELETE** (history retained) |
| Source | `sources` | Inbound channel (web SDK, server, warehouse, etc.); each holds a `write_key` |
| Destination | `destinations` | Outbound activation target (ads, ESP, warehouse, etc.) |
| Audience activation | `audience_activations` | Junction; defines that audience X is pushed to destination Y on a cadence |
| Computed trait | `computed_traits` | A *definition* of a derived attribute; values land in `profiles.custom_traits`, not here |
| Consent record | `consent_records` | **Append-only**, one row per change; never PATCH to update consent |

`users` and `roles` referenced from `*_created_by_user_id` are the
Semantius **built-in** tables (the model dedupes against them at deploy
time); manage operators with `use-semantius` directly, not from this
skill.

## Key enums

- `profiles.lifecycle_stage`: `anonymous` → `lead` → `prospect` → `customer` | `churned`
- `accounts.lifecycle_stage`: `prospect` → `customer` | `churned`
- `identities.identity_type`: `anonymous_id`, `user_id`, `email`, `phone`, `device_id`, `advertising_id`, `external_id`
- `events.event_type`: `track`, `page`, `screen`, `identify`, `group`, `alias`
- `audiences.status`: `draft` → `active` → `paused` → `archived` (terminal)
- `audiences.audience_type`: `rule_based`, `sql`, `lookalike`, `manual`
- `audiences.refresh_frequency`: `on_demand` (default), `realtime`, `hourly`, `daily`
- `audience_activations.sync_mode`: `incremental` (default), `full_resync`, `mirror`
- `audience_activations.sync_frequency`: `on_demand` (default), `realtime`, `hourly`, `daily`
- `audience_activations.last_sync_status`: `pending` (default for never-run), `success`, `partial`, `failed`
- `destinations.sync_status`: `idle`, `syncing`, `error`
- `destinations.destination_type`: `advertising`, `email`, `sms`, `push`, `analytics`, `warehouse`, `crm`, `custom_webhook`
- `sources.source_type`: `web_sdk`, `mobile_sdk_ios`, `mobile_sdk_android`, `server`, `cloud_app`, `warehouse`, `file_upload`, `http_api`
- `consent_records.consent_purpose`: `marketing`, `analytics`, `advertising`, `personalization`, `sale_of_data`, `all`
- `consent_records.status`: `unknown` (default), `granted`, `denied`, `withdrawn`
- `computed_traits.compute_frequency`: `on_demand` (default), `realtime`, `hourly`, `daily`, `weekly`
- `computed_traits.data_type`: `string`, `number`, `boolean`, `date`, `datetime`, `list`

## Foreign-key cheatsheet

- `identities.profile_id → profiles.id` (parent, **cascade**)
- `events.profile_id → profiles.id` (clear; events survive a profile delete)
- `events.source_id → sources.id` (**restrict** , a source with events cannot be deleted)
- `audience_memberships.audience_id → audiences.id` (parent, cascade)
- `audience_memberships.profile_id → profiles.id` (parent, cascade)
- `audience_memberships`: **no DB-level uniqueness** on `(audience_id, profile_id)` , read before insert to avoid duplicate memberships.
- `audience_activations.audience_id → audiences.id` (parent, cascade)
- `audience_activations.destination_id → destinations.id` (parent, cascade)
- `consent_records.profile_id → profiles.id` (parent, **cascade** , see Guardrails for the GDPR rationale)
- `accounts.parent_account_id → accounts.id` (self-reference, clear)
- `profiles.account_id → accounts.id` (clear)

**Unique constraints to watch:** `profiles.primary_email`,
`identities.identity_value` (in practice within an `identity_type`),
`sources.write_key`, `computed_traits.trait_name`, `users.email`,
`roles.role_name`.

**Audit-logged (Semantius writes the audit rows; recipes don't manage
them):** `profiles`, `accounts`, `audiences`, `sources`, `destinations`,
`audience_activations`, `consent_records`, `computed_traits`, `users`,
`roles`. `identities`, `events`, and `audience_memberships` are not
audit-logged (they are too high-volume).

---

## Jobs to be done

### Find a profile by any identifier

**Triggers:** `"find the profile for alice@example.com"`, `"who is device 12345"`, `"look up this customer"`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| identifier value | yes | Email, device id, anonymous id, user id, phone, etc., or a fuzzy name |
| identifier type | no | If known, narrows the search; otherwise infer from the value shape |

**Lookup convention.** Semantius adds a `search_vector` column for full-text
search across all text fields on each searchable entity. Use
`search_vector=wfts(simple).<term>` for fuzzy human input, never `ilike`
or `fts`. Use `<column>=eq.<value>` for known-exact values (UUIDs, FK
ids, unique columns whose value the caller already knows verbatim such
as `primary_email`, `write_key`, `trait_name`).

**Recipe:**

```bash
# 1. Try the identity graph first (works for any concrete identifier the user knows)
semantius call crud postgrestRequest '{"method":"GET","path":"/identities?identity_value=eq.<value>&select=id,profile_id,identity_type,is_primary"}'

# If the value is a unique email, profiles.primary_email also works directly:
semantius call crud postgrestRequest '{"method":"GET","path":"/profiles?primary_email=eq.<value>&select=id,profile_label,lifecycle_stage,account_id"}'

# If the user typed a name (not an exact identifier), full-text search profiles:
semantius call crud postgrestRequest '{"method":"GET","path":"/profiles?search_vector=wfts(simple).<term>&select=id,profile_label,primary_email,lifecycle_stage"}'

# 2. Resolve to the canonical profile row
semantius call crud postgrestRequest '{"method":"GET","path":"/profiles?id=eq.<profile_id>&select=id,profile_label,lifecycle_stage,account_id,first_seen_at,last_seen_at,custom_traits"}'
```

**Validation:** at most one profile id is returned per concrete
identifier (multiple hits mean identity resolution is broken , surface
to the user and consider the merge-profiles JTBD).

**Failure modes:**

- Zero hits on `identities` and on `profiles.primary_email` → the
  customer has not been seen yet; ask the user whether to create a new
  profile or wait for the next inbound event.
- Multiple distinct `profile_id`s for the same `identity_value` → two
  profiles describe the same person; route to **Merge two profiles**.

---

### Add an identity to a profile

**Triggers:** `"add a device id to this profile"`, `"link this email to the customer"`, `"add an external_id for the CRM"`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `profile_id` | yes | Resolve via the lookup JTBD if not given |
| `identity_type` | yes | One of the `identity_type` enum values |
| `identity_value` | yes | The actual identifier string |
| `is_primary` | no | If `true`, demote any existing primary of the same type first |
| `source_id` | no | Where the identifier was first seen, if known |

**Recipe:**

```bash
# 1. Resolve the profile (see "Find a profile by any identifier")

# 2. If is_primary=true, demote any existing primary of the same identity_type
semantius call crud postgrestRequest '{"method":"GET","path":"/identities?profile_id=eq.<profile_id>&identity_type=eq.<type>&is_primary=eq.true&select=id"}'
# If a row exists, demote it before inserting the new primary:
semantius call crud postgrestRequest '{"method":"PATCH","path":"/identities?id=eq.<existing_id>","body":{"is_primary":false}}'

# 3. Insert the new identity (compose identity_label as "{identity_type}: {identity_value}")
semantius call crud postgrestRequest '{
  "method":"POST",
  "path":"/identities",
  "body":{
    "identity_label":"<identity_type>: <identity_value>",
    "identity_type":"<identity_type>",
    "identity_value":"<identity_value>",
    "profile_id":"<profile_id>",
    "is_primary":false,
    "first_seen_at":"<current ISO timestamp>",
    "last_seen_at":"<current ISO timestamp>"
  }
}'
```

> `first_seen_at` / `last_seen_at`: set to the current timestamp at
> call time; do not copy any example value.

**Validation:** at most one `is_primary=true` row per
`(profile_id, identity_type)` after the call.

**Failure modes:**

- The `identity_value` already exists for a *different* profile → that
  is a candidate split; route to **Merge two profiles** instead of
  inserting.
- POST without `identity_label` → 400; the field is required and is
  not auto-derived.

---

### Manage audience membership (add or remove)

**Triggers:** `"add this customer to the high-value audience"`, `"put them in the cart-abandoners segment"`, `"remove them from the audience"`, `"drop this profile from the segment"`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `audience_id` | yes | Resolve by name (`audience_name=eq.<name>`) or full-text |
| `profile_id` | yes | Resolve via the lookup JTBD |
| `audience_name`, `profile_label` | yes for ADD | Needed to compose `membership_label` |

**Recipe (ADD):**

```bash
# 1. Resolve audience and profile names so you have id + label for each
semantius call crud postgrestRequest '{"method":"GET","path":"/audiences?search_vector=wfts(simple).<audience_term>&select=id,audience_name,status"}'

# 2. Read-before-insert: junction has NO DB-level uniqueness on (audience_id, profile_id)
semantius call crud postgrestRequest '{"method":"GET","path":"/audience_memberships?audience_id=eq.<audience_id>&profile_id=eq.<profile_id>&order=joined_at.desc&limit=1&select=id,is_active,left_at"}'

# Case A: an active row exists → no-op.
# Case B: a deactivated row exists → reactivate it (don't insert a duplicate):
semantius call crud postgrestRequest '{
  "method":"PATCH",
  "path":"/audience_memberships?id=eq.<existing_id>",
  "body":{"is_active":true,"left_at":null,"joined_at":"<current ISO timestamp>"}
}'

# Case C: no prior row → insert (compose membership_label)
semantius call crud postgrestRequest '{
  "method":"POST",
  "path":"/audience_memberships",
  "body":{
    "membership_label":"<audience_name> / <profile_label>",
    "audience_id":"<audience_id>",
    "profile_id":"<profile_id>",
    "joined_at":"<current ISO timestamp>",
    "is_active":true
  }
}'
```

**Recipe (REMOVE):**

```bash
# 1. Find the active membership row
semantius call crud postgrestRequest '{"method":"GET","path":"/audience_memberships?audience_id=eq.<audience_id>&profile_id=eq.<profile_id>&is_active=eq.true&select=id"}'

# 2. Deactivate. DO NOT DELETE; the row is retained for history per the model.
semantius call crud postgrestRequest '{
  "method":"PATCH",
  "path":"/audience_memberships?id=eq.<membership_id>",
  "body":{"is_active":false,"left_at":"<current ISO timestamp>"}
}'
```

> All timestamps: set at call time; do not copy example values.

**Validation:** at most one `is_active=true` membership per
`(audience_id, profile_id)`.

**Failure modes:**

- Calling DELETE on an `audience_memberships` row → silently destroys
  the membership history that downstream analytics relies on. Always
  PATCH `is_active=false` instead.
- Inserting without checking first → produces duplicate active
  memberships that inflate `audience.profile_count`.

---

### Create and progress an audience through its lifecycle

**Triggers:** `"create a new audience of repeat buyers"`, `"activate the trial-expiry audience"`, `"pause this audience"`, `"archive the holiday-2025 segment"`

**Inputs (create):**

| Name | Required | Notes |
|---|---|---|
| `audience_name` | yes | The label_column |
| `audience_type` | yes | One of `rule_based`, `sql`, `lookalike`, `manual` |
| `definition` | yes | JSON rule body or SQL string |
| `refresh_frequency` | yes | Default `on_demand`; pick `daily` or higher only when the source data justifies it |
| `status` | yes | Always create as `draft`; flip to `active` only after the definition is verified |
| `created_by_user_id` | no | Current operator id (resolves against the Semantius built-in `users` table) |

**Recipe:**

```bash
# 1. Create the audience (start in draft)
semantius call crud postgrestRequest '{
  "method":"POST",
  "path":"/audiences",
  "body":{
    "audience_name":"High-value buyers",
    "audience_type":"rule_based",
    "definition":"{\"and\":[{\"trait\":\"lifetime_value\",\"op\":\">\",\"value\":1000}]}",
    "status":"draft",
    "refresh_frequency":"daily",
    "created_by_user_id":"<current user id, optional>"
  }
}'

# 2. Activate (draft → active). Only flip from draft or paused; never directly from archived.
semantius call crud postgrestRequest '{"method":"PATCH","path":"/audiences?id=eq.<audience_id>","body":{"status":"active"}}'

# 3. Pause (active → paused). IMPORTANT: pausing the audience does NOT auto-pause
#    its activations. If the operator wants destination syncs to stop too, also patch
#    every active activation:
semantius call crud postgrestRequest '{"method":"PATCH","path":"/audience_activations?audience_id=eq.<audience_id>&is_active=eq.true","body":{"is_active":false}}'
semantius call crud postgrestRequest '{"method":"PATCH","path":"/audiences?id=eq.<audience_id>","body":{"status":"paused"}}'

# 4. Archive (terminal). Use only when the audience is truly retired.
semantius call crud postgrestRequest '{"method":"PATCH","path":"/audiences?id=eq.<audience_id>","body":{"status":"archived"}}'
```

**Validation:** after `pause` with the cascade step, no active
activations remain for the audience; after `archive`, the audience no
longer appears in operator dashboards.

**Failure modes:**

- Patching `status=active` directly with no prior verification → the
  next refresh fires against an unverified `definition` and may produce
  wrong membership; always create as `draft` and flip explicitly.
- Pausing the audience without pausing its activations → the
  destination keeps receiving the last computed snapshot until the
  next sync attempt; if that surprises the operator, run the cascade
  PATCH above.
- Status is not DB-guarded; any value from the enum is accepted. Always
  read the current status before writing.

---

### Activate an audience to a destination

**Triggers:** `"activate the audience to Meta Ads"`, `"push this segment to Salesforce"`, `"sync the audience to the warehouse"`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `audience_id` | yes | The audience must be `status=active` |
| `destination_id` | yes | The destination must be `is_active=true` |
| `audience_name`, `destination_name` | yes | Needed to compose `activation_label` |
| `sync_mode` | yes | Default `incremental`; pick `full_resync` for ad-platform reseeding, `mirror` for warehouses |
| `sync_frequency` | yes | Default `on_demand`; raise to `hourly`/`daily`/`realtime` based on the destination |
| `field_mappings` | no | JSON mapping profile fields → destination fields |

**Recipe:**

```bash
# 1. Resolve audience and destination
semantius call crud postgrestRequest '{"method":"GET","path":"/audiences?audience_name=eq.<name>&select=id,audience_name,status"}'
semantius call crud postgrestRequest '{"method":"GET","path":"/destinations?destination_name=eq.<name>&select=id,destination_name,is_active,destination_type"}'

# 2. Verify audience.status='active' and destination.is_active=true. Do not activate from
#    a draft, paused, or archived audience, and do not target an inactive destination.

# 3. Compose activation_label = "{audience_name} → {destination_name}" and POST
semantius call crud postgrestRequest '{
  "method":"POST",
  "path":"/audience_activations",
  "body":{
    "activation_label":"<audience_name> → <destination_name>",
    "audience_id":"<audience_id>",
    "destination_id":"<destination_id>",
    "sync_mode":"incremental",
    "sync_frequency":"daily",
    "field_mappings":{"primary_email":"email","first_name":"first_name"},
    "is_active":true,
    "last_sync_status":"pending"
  }
}'
```

**Validation:** the new activation appears in
`audience_activations` with `last_sync_status='pending'`; the platform's
sync worker will flip it to `success` / `partial` / `failed` on first
run.

**Failure modes:**

- POST without `activation_label` → 400; the composite label is
  required and not auto-derived.
- Targeting a destination whose `is_active=false` → the activation is
  created but no syncs run; verify `is_active` before insert.
- An activation already exists for the same `(audience_id, destination_id)` →
  the model does not block duplicates here; check first with
  `GET /audience_activations?audience_id=eq.X&destination_id=eq.Y` and
  PATCH the existing row instead of POSTing a second one.

---

### Record a consent change

**Triggers:** `"record marketing consent for this profile"`, `"this customer withdrew analytics consent"`, `"log a GDPR opt-in"`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `profile_id` | yes | Resolve via the lookup JTBD |
| `profile_label` | yes | Needed to compose `consent_label` |
| `consent_purpose` | yes | One of the `consent_purpose` enum values |
| `status` | yes | One of `unknown`, `granted`, `denied`, `withdrawn` |
| `jurisdiction` | no | E.g. `GDPR-EU`, `CCPA-CA` |
| `consent_text` | no | The exact text shown to the user at capture time, if available |
| `granted_at` / `withdrawn_at` | conditional | Set the one matching the new `status` |

**Recipe:**

```bash
# 1. Get the profile_label for the composite consent_label
semantius call crud postgrestRequest '{"method":"GET","path":"/profiles?id=eq.<profile_id>&select=profile_label"}'

# 2. APPEND a new consent row. NEVER PATCH an existing consent_records row,
#    the table is append-only by design and full history is required for audits.
semantius call crud postgrestRequest '{
  "method":"POST",
  "path":"/consent_records",
  "body":{
    "consent_label":"<profile_label> / <consent_purpose> / <status>",
    "profile_id":"<profile_id>",
    "consent_purpose":"marketing",
    "status":"granted",
    "jurisdiction":"GDPR-EU",
    "granted_at":"<current ISO timestamp>",
    "consent_text":"<the exact text shown to the user at capture time>"
  }
}'

# For status=withdrawn, set withdrawn_at instead and leave granted_at untouched:
#   "status":"withdrawn", "withdrawn_at":"<current ISO timestamp>"
```

> `granted_at` / `withdrawn_at`: set to the current timestamp at call
> time; do not copy any example value.

**Validation:** the new row is the most-recent (`order=created_at.desc&limit=1`)
for the `(profile_id, consent_purpose)` pair; the prior row remains
untouched.

**Failure modes:**

- PATCHing an existing consent_records row to "update" consent → silently
  destroys the audit trail. Always POST a new row.
- POST without `consent_label` → 400; compose the composite first.
- Setting `status=granted` without `granted_at` (or `status=withdrawn`
  without `withdrawn_at`) → the row is accepted but downstream consent
  reports cannot tell when consent took effect.

---

### Forget a profile (right-to-be-forgotten)

**Triggers:** `"forget this customer"`, `"GDPR delete for alice@example.com"`, `"erase this profile"`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `profile_id` | yes | Resolve via the lookup JTBD |

**Recipe:**

```bash
# 1. Identify the profile (see "Find a profile by any identifier")

# 2. (Optional) Inventory what will cascade so you can report it back to the user
semantius call crud postgrestRequest '{"method":"GET","path":"/identities?profile_id=eq.<profile_id>&select=id,identity_type,identity_value"}'
semantius call crud postgrestRequest '{"method":"GET","path":"/audience_memberships?profile_id=eq.<profile_id>&select=id,audience_id,is_active"}'
semantius call crud postgrestRequest '{"method":"GET","path":"/consent_records?profile_id=eq.<profile_id>&select=id,consent_purpose,status,created_at"}'

# 3. DELETE the profile. The platform cascades automatically:
#    identities (cascade), audience_memberships (cascade), consent_records (cascade).
#    events.profile_id gets cleared (FK clear); event rows themselves remain (orphaned).
semantius call crud postgrestRequest '{"method":"DELETE","path":"/profiles?id=eq.<profile_id>"}'

# 4. (Optional) If the jurisdiction requires erasure of behavioural data too,
#    delete orphaned events that retain identifying anonymous_id values:
semantius call crud postgrestRequest '{"method":"DELETE","path":"/events?profile_id=is.null&anonymous_id=eq.<anon_id>"}'
```

**Validation:** post-delete GETs against `identities`,
`audience_memberships`, and `consent_records` filtered by the old
`profile_id` return zero rows.

**Failure modes:**

- The `events.source_id → sources.id` FK is `restrict`. Profile delete
  does NOT cascade through events; events survive with `profile_id=null`.
  This is intentional (analytics counts hold) but the operator should
  know.
- If the deployment has overridden `consent_records.profile_id` to
  `restrict` (operators in retention-heavy regimes do this), the
  profile DELETE will fail until consent rows are explicitly
  soft-deleted or transferred. Tell the user; do not bypass.

---

### Merge two profiles (identity resolution)

**Triggers:** `"merge these two profiles"`, `"these are the same person, combine them"`, `"resolve this duplicate customer"`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `winner_id` | yes | The profile that survives |
| `loser_id` | yes | The profile that is absorbed and deleted |

Pick the winner deliberately: prefer the one with `primary_email` set,
more identities, older `first_seen_at`. Confirm with the user when
ambiguous.

**Recipe:**

```bash
# 1. Read both rows so you can pick winner / loser and compose the merged display name
semantius call crud postgrestRequest '{"method":"GET","path":"/profiles?id=in.(<winner_id>,<loser_id>)&select=id,profile_label,primary_email,first_name,last_name,first_seen_at,custom_traits,account_id"}'

# 2. Repoint identities (cascade-parent FK; safe to bulk PATCH)
semantius call crud postgrestRequest '{"method":"PATCH","path":"/identities?profile_id=eq.<loser_id>","body":{"profile_id":"<winner_id>"}}'

# 3. Repoint events (clear FK; safe to bulk PATCH)
semantius call crud postgrestRequest '{"method":"PATCH","path":"/events?profile_id=eq.<loser_id>","body":{"profile_id":"<winner_id>"}}'

# 4. Repoint consent_records (append-only, no dedupe needed)
semantius call crud postgrestRequest '{"method":"PATCH","path":"/consent_records?profile_id=eq.<loser_id>","body":{"profile_id":"<winner_id>"}}'

# 5. audience_memberships: the winner may already be in the same audience.
#    For each loser membership, check overlap with the winner first.
semantius call crud postgrestRequest '{"method":"GET","path":"/audience_memberships?profile_id=eq.<loser_id>&select=id,audience_id,is_active"}'
# For each loser membership: GET to see if the winner already has one in that audience
semantius call crud postgrestRequest '{"method":"GET","path":"/audience_memberships?profile_id=eq.<winner_id>&audience_id=eq.<audience_id>&select=id,is_active"}'
# If the winner has none → repoint:
semantius call crud postgrestRequest '{"method":"PATCH","path":"/audience_memberships?id=eq.<loser_membership_id>","body":{"profile_id":"<winner_id>"}}'
# If the winner already has one → deactivate the loser's membership instead:
semantius call crud postgrestRequest '{"method":"PATCH","path":"/audience_memberships?id=eq.<loser_membership_id>","body":{"is_active":false,"left_at":"<current ISO timestamp>"}}'

# 6. Refresh the winner's profile_label / primary_email if the loser had a better display name
semantius call crud postgrestRequest '{
  "method":"PATCH",
  "path":"/profiles?id=eq.<winner_id>",
  "body":{"profile_label":"<best display name>","primary_email":"<best email>"}
}'

# 7. DELETE the loser. All FK children have been repointed or deactivated; the
#    remaining cascade just clears the loser's deactivated membership rows.
semantius call crud postgrestRequest '{"method":"DELETE","path":"/profiles?id=eq.<loser_id>"}'
```

**Validation:**
- `GET /identities?profile_id=eq.<loser_id>` returns zero.
- `GET /events?profile_id=eq.<loser_id>` returns zero.
- For each `audience_id` the loser was in, the winner has at most one
  active membership.
- The loser id no longer resolves in `GET /profiles`.

**Failure modes:**

- Skipping the `audience_memberships` overlap check → the winner ends
  up with two active memberships in the same audience and inflates
  `audience.profile_count`.
- Deleting the loser before repointing children → the cascade wipes
  the loser's identities, events (clear), memberships, and consent
  history; the merged customer loses provenance.
- `events.source_id` is `restrict`; this does not affect the merge
  (events are PATCHed, not deleted), but be aware the same restriction
  applies if you later try to delete a source the merged events came
  from.

---

## Common queries

Always run `cube discover '{}'` first to refresh the schema. Match the
dimension and measure names below against what `discover` returns ,
field names drift when the model is regenerated, and `discover` is the
source of truth at query time.

For bulk ingest of historical events from CSV / Excel, see
`use-semantius` `references/webhook-import.md`; this skill does not
duplicate that flow.

```bash
# 1. Profiles by lifecycle stage
semantius call cube load '{"query":{
  "measures":["profiles.count"],
  "dimensions":["profiles.lifecycle_stage"],
  "order":{"profiles.count":"desc"}
}}'
```

```bash
# 2. Events per source per day, last 7 days
semantius call cube load '{"query":{
  "measures":["events.count"],
  "dimensions":["events.source_id"],
  "timeDimensions":[{"dimension":"events.received_at","granularity":"day","dateRange":"last 7 days"}],
  "order":{"events.received_at":"asc"}
}}'
```

```bash
# 3. Audience growth, active memberships joined per day for the last 30 days
semantius call cube load '{"query":{
  "measures":["audience_memberships.count"],
  "dimensions":["audience_memberships.audience_id"],
  "timeDimensions":[{"dimension":"audience_memberships.joined_at","granularity":"day","dateRange":"last 30 days"}],
  "filters":[{"member":"audience_memberships.is_active","operator":"equals","values":["true"]}]
}}'
```

```bash
# 4. Activation success rate by destination, last 7 days
semantius call cube load '{"query":{
  "measures":["audience_activations.count"],
  "dimensions":["audience_activations.destination_id","audience_activations.last_sync_status"],
  "timeDimensions":[{"dimension":"audience_activations.last_sync_at","granularity":"day","dateRange":"last 7 days"}]
}}'
```

```bash
# 5. Current consent state per (profile, purpose), append-only table.
# cube cannot easily express "latest row per group". Use PostgREST and
# reduce client-side to the first row per consent_purpose:
semantius call crud postgrestRequest '{"method":"GET","path":"/consent_records?profile_id=eq.<profile_id>&order=created_at.desc&select=consent_purpose,status,jurisdiction,granted_at,withdrawn_at,created_at"}'
```

> All `dateRange` values above are illustrative; substitute what the
> user actually asked for at call time.

---

## Guardrails

- **Consent is append-only.** Never PATCH or DELETE a `consent_records`
  row to "update" consent. Always POST a new row. The audit trail is
  the contract with the legal team.
- **Audience memberships are soft-deactivated.** Never DELETE an
  `audience_memberships` row. Set `is_active=false` and populate
  `left_at`. History is required for downstream analytics on audience
  churn.
- **The `audience_memberships` junction has no DB-level uniqueness** on
  `(audience_id, profile_id)`. Always read before insert; reactivate a
  prior row instead of inserting a duplicate.
- **Status enums are not DB-guarded.** Any value from the enum is
  accepted. Read the current `status` before writing on `audiences`,
  `accounts.lifecycle_stage`, `profiles.lifecycle_stage`, and
  `consent_records.status`.
- **Pausing an audience does not pause its activations.** The flow is
  two patches: pause every active activation first, then patch the
  audience to `paused`.
- **Composite labels are required and caller-populated.** Every POST to
  `identities`, `audience_memberships`, `audience_activations`, and
  `consent_records` must include the composite `*_label` per the rule
  in the auto-managed-fields note.
- **`events.source_id` is `restrict`.** A source cannot be deleted
  while events reference it. To retire a source, set `is_active=false`
  and stop ingesting; do not DELETE.
- **Profile DELETE cascades through `consent_records`** (the deliberate
  GDPR-aligned default). Operators in retention-heavy regimes may have
  overridden this to `restrict` at deploy time; if a profile DELETE
  returns an FK error on `consent_records`, surface it to the user
  rather than working around it.
- **`users` and `roles` are the Semantius built-ins** in deployed
  instances; manage operators with `use-semantius` directly, not from
  this skill. `*_created_by_user_id` references resolve against the
  built-in `users` table.

## What this skill does NOT do

- Schema changes, use `use-semantius` directly.
- RBAC / permissions, use `use-semantius` directly.
- One-off seed data, write a script, don't bake it into a JTBD.
- Bulk CSV / Excel event ingest, see `use-semantius`
  `references/webhook-import.md`.
- Per-trait time-series storage (the model keeps computed-trait values
  inside `profiles.custom_traits` JSON; per-trait history would need a
  dedicated `profile_trait_values` entity, not yet built).
- A first-class `sessions` entity (sessions are derived from
  `events.session_id`; not yet promoted to its own table).
- A structured rule entity for `audiences.definition` (today the
  definition is free-text JSON or SQL).
- Consent capture for *anonymous* identities prior to profile resolution
  (today `consent_records.profile_id` is required).
- Multi-parent account graphs (`accounts.parent_account_id` is a single
  self-reference, not a many-to-many).
- A dedicated `destination_credentials` entity with rotation history
  (secrets live outside this model in the platform secret store).
- Denormalized `events.account_id` for fast B2B segmentation (today,
  reach the account through `events.profile_id → profiles.account_id`).
