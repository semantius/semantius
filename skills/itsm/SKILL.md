---
name: itsm
description: >-
  Use this skill for anything involving IT Service Management, the in-house
  ITSM domain that runs incidents, service requests, problems, and changes on
  top of a CMDB, a service catalog, knowledge articles, and SLAs. Trigger
  when the user says: "report an incident", "assign INC-00042 to the network
  team", "resolve this incident with a workaround", "raise a service request
  for a new laptop", "approve this service request", "open a change request
  for tonight's maintenance window", "approve the emergency change",
  "schedule the change for Saturday", "mark the change implemented", "roll
  these incidents up to a problem", "investigate this problem", "publish the
  runbook", "post a public comment on the ticket", "what's our SLA breach
  rate this month", "show me changes scheduled this week". Loads alongside
  `use-semantius`, which owns CLI install, PostgREST encoding, and cube
  query mechanics.
semantic_model: itsm
---

# IT Service Management

This skill carries the domain map and the jobs-to-be-done for IT
Service Management. Platform mechanics, CLI install, env vars,
PostgREST URL-encoding, `sqlToRest`, cube `discover`/`validate`/`load`,
and schema-management tools, live in `use-semantius`. Assume it loads
alongside; do not re-explain CLI basics here.

If a task is purely about defining schema, managing permissions, or
running ad-hoc queries against tables you already know, call
`use-semantius` directly, going through this skill adds nothing.

**Auto-managed fields** (set by Semantius on every table; never include
in POST/PATCH bodies): `id`, `created_at`, `updated_at`. Two
caller-populated label columns are **required on insert and not
auto-derived**: `change_configuration_items.change_ci_label` and
`ticket_comments.ticket_comment_label`. Compose the value client-side
on every POST; the composition rule is given in each affected JTBD.
All other label columns (`incident_number`, `request_number`,
`change_number`, `problem_number`, `article_title`, etc.) are also
caller-supplied (the model uses domain-shaped numbers like
`INC-00001`, `SR-00001`, `CHG-00001`, `PRB-00001`, `KB-00001`); the
recipes below show how to mint the next value.

---

## Domain glossary

The platform splits into two layers: a **CMDB** (configuration items
plus their vendors, owners, and support teams) and a **ticketing
funnel** that references it (incidents, service requests, problems,
changes). Knowledge articles and SLAs sit alongside; ticket comments
attach to any of the four ticket types.

| Concept | Table | Notes |
|---|---|---|
| User | `users` | Everyone in the system; `is_agent=true` flags IT staff (deduped against the Semantius built-in `users`) |
| Team | `teams` | An IT support group or queue (Service Desk, Network, DBA, Security) |
| Vendor | `vendors` | External providers that supply CIs or perform changes |
| Configuration Item | `configuration_items` | The CMDB row: any hardware, software, or service component IT manages |
| Service Catalog Item | `service_catalog_items` | The definition of a standard requestable service (new laptop, VPN access) |
| Service Request | `service_requests` | An instance of a user requesting a catalog item; has its own approval and fulfillment lifecycle |
| Incident | `incidents` | An unplanned interruption or quality degradation in a service |
| Problem | `problems` | An underlying root cause that explains one or more incidents |
| Change Request | `change_requests` | A planned addition, modification, or removal affecting CIs, with risk, schedule, and approval |
| Change CI | `change_configuration_items` | Junction: which CIs are affected by a given change request, with an `impact_role` qualifier |
| Knowledge Article | `knowledge_articles` | Documented solutions, runbooks, FAQs, known errors; has a publication lifecycle |
| Service Level Agreement | `service_level_agreements` | Response and resolution time targets keyed off `(ticket_type, priority)` |
| Ticket Comment | `ticket_comments` | A reply or work-note attached to exactly one ticket (polymorphic across the four ticket types) |

## Key enums

Only enums that gate JTBDs are listed; arrows mark the typical lifecycle path; `|` separates terminal states.

- `incidents.status`: `new` -> `assigned` -> `in_progress` -> `on_hold` -> `resolved` -> `closed` | `cancelled`
- `incidents.resolution_category`: `solved`, `workaround`, `duplicate`, `no_fault_found`, `user_error`, `configuration_change`
- `service_requests.status`: `new` -> `approval_pending` -> `approved` -> `in_progress` -> `fulfilled` -> `closed` | `cancelled`
- `problems.status`: `new` -> `investigating` -> `root_cause_known` -> `workaround_available` -> `resolved` -> `closed`
- `change_requests.status`: `draft` -> `approval_pending` -> `approved` -> `scheduled` -> `in_progress` -> `implemented` -> `review` -> `closed` | `cancelled` | `failed`
- `change_requests.change_type`: `standard`, `normal`, `emergency`
- `change_configuration_items.impact_role`: `primary`, `dependency`, `downstream`, `witness`
- `knowledge_articles.status`: `draft` -> `in_review` -> `published` -> `archived`
- `knowledge_articles.visibility`: `internal`, `customer`, `public`
- `ticket_comments.visibility`: `public`, `internal`
- Shared priority (incidents, service_requests, problems, service_level_agreements): `p4_low`, `p3_normal`, `p2_high`, `p1_critical`
- Shared severity (incidents.impact, incidents.urgency, change_requests.risk, change_requests.impact): `low`, `medium`, `high`
- Shared ticket-type discriminator (service_level_agreements.ticket_type, ticket_comments.ticket_type): `incident`, `service_request`, `problem`, `change_request`

## Foreign-key cheatsheet

Only the FKs that JTBDs cross. Format: `child.field -> parent.id` (delete behavior in parens).

- `incidents.reported_by_user_id -> users.id` (clear)
- `incidents.affected_configuration_item_id -> configuration_items.id` (clear)
- `incidents.assigned_to_user_id -> users.id` (clear)
- `incidents.assigned_team_id -> teams.id` (clear)
- `incidents.problem_id -> problems.id` (clear)
- `incidents.sla_id -> service_level_agreements.id` (clear)
- `service_requests.catalog_item_id -> service_catalog_items.id` (**restrict**: a catalog item with open requests cannot be deleted)
- `service_requests.requested_by_user_id -> users.id` (clear, required)
- `problems.known_error_article_id -> knowledge_articles.id` (clear)
- `problems.resolution_change_request_id -> change_requests.id` (clear)
- `problems.affected_configuration_item_id -> configuration_items.id` (clear)
- `change_requests.requested_by_user_id -> users.id` (clear, required)
- `change_requests.approver_user_id -> users.id` (clear)
- `change_requests.vendor_id -> vendors.id` (clear)
- `change_configuration_items.change_request_id -> change_requests.id` (cascade)
- `change_configuration_items.configuration_item_id -> configuration_items.id` (cascade)
- `knowledge_articles.author_user_id -> users.id` (clear, required)
- `ticket_comments.incident_id -> incidents.id` (cascade; one of four polymorphic FKs, see below)
- `ticket_comments.service_request_id -> service_requests.id` (cascade; polymorphic)
- `ticket_comments.problem_id -> problems.id` (cascade; polymorphic)
- `ticket_comments.change_request_id -> change_requests.id` (cascade; polymorphic)

**Unique columns** (409 on duplicate POST): `users.email`,
`teams.team_name`, `vendors.vendor_name`, `configuration_items.ci_name`,
`service_catalog_items.catalog_item_name`, `service_requests.request_number`,
`incidents.incident_number`, `problems.problem_number`,
`change_requests.change_number`, `knowledge_articles.article_title`,
`knowledge_articles.article_number`, `service_level_agreements.sla_name`.

**No DB-level uniqueness on the natural junction key** for
`change_configuration_items(change_request_id, configuration_item_id)`.
A POST that would create the same `(change, CI)` pair twice will
succeed and create a duplicate row that pollutes the affected-CI list.
The recipe must read first.

**Polymorphic invariant on `ticket_comments`** (caller-enforced, not DB-enforced).
Exactly one of `incident_id`, `service_request_id`, `problem_id`,
`change_request_id` must be non-null on every row, and it must match
the value of the `ticket_type` discriminator. The DB allows nulls on
each individually and accepts inconsistent rows; every write recipe
below sets exactly one FK and the matching discriminator in the same
POST. See §6.1 of the source model for the design discussion.

**Audit-logged tables** (Semantius writes the audit rows automatically;
recipes do not manage them): `vendors`, `configuration_items`,
`service_catalog_items`, `service_requests`, `incidents`, `problems`,
`change_requests`, `knowledge_articles`, `service_level_agreements`.

---

## Jobs to be done

### Report an incident

**Triggers:** `report an incident`, `the email server is down`, `log a P1 outage`, `assign INC-00042 to the network team`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `short_description` | yes | Free text; one-line description of what is broken |
| `reported_by_user_id` | yes | The user reporting; lookup by email |
| `impact`, `urgency`, `priority` | yes | All three required by the model; `priority` is what SLA matching keys off |
| `reported_at` | yes | Use the current ISO timestamp at call time |
| `affected_configuration_item_id` | no | Lookup the CI by `ci_name` (unique) or fuzzy text |
| `affected_user_id` | no | The user actually experiencing the outage, if not the same as `reported_by` |
| `assigned_to_user_id`, `assigned_team_id` | no | Set on first triage; can be patched later |
| `description` | no | Long-form details |

**Lookup convention.** Semantius adds a `search_vector` column to
searchable entities for full-text search across all text fields. Use
it whenever the user passes a name, title, code, etc., not a UUID:

```bash
# Resolve a CI by anything the user typed (name, hostname, asset tag, etc.)
semantius call crud postgrestRequest '{"method":"GET","path":"/configuration_items?search_vector=wfts(simple).<term>&select=id,ci_name,ci_type,status,environment"}'
```

Use `wfts(simple).<term>` for fuzzy text searches, never `ilike` and
never `fts`, they bypass the search index and mismatch the platform
convention. `eq.<value>` is the right tool for known-exact values
(UUIDs, FK ids, status enums, unique columns like `ci_name`,
`incident_number`, or `email`).

**SLA selection (paired write).** The model carries `sla_id`,
`sla_response_due_at`, `sla_resolution_due_at`, `sla_breached` on each
incident. None of these are auto-computed by the platform; the recipe
must look up the matching SLA row and compute the two due timestamps
in the same POST. SLA matching is by `(ticket_type='incident', priority,
is_active=true)`; if multiple match, prefer the one with the most
recent `effective_from` that is still in range.

**Minting `incident_number`.** The model uses `INC-NNNNN`. Read the
last incident number, increment, zero-pad to 5 digits.

**Recipe:**

```bash
# 1. Resolve the reporter, the CI (if named), and the next incident number
semantius call crud postgrestRequest '{"method":"GET","path":"/users?email=eq.<email>&select=id,user_name,is_agent"}'
semantius call crud postgrestRequest '{"method":"GET","path":"/configuration_items?search_vector=wfts(simple).<term>&select=id,ci_name,support_team_id"}'
semantius call crud postgrestRequest '{"method":"GET","path":"/incidents?order=incident_number.desc&limit=1&select=incident_number"}'

# 2. Pick the SLA that matches (ticket_type='incident', priority, is_active=true)
semantius call crud postgrestRequest '{"method":"GET","path":"/service_level_agreements?ticket_type=eq.incident&priority=eq.<priority>&is_active=is.true&order=effective_from.desc&limit=1&select=id,response_target_minutes,resolution_target_minutes"}'

# 3. Compute sla_response_due_at = reported_at + response_target_minutes,
#    and sla_resolution_due_at = reported_at + resolution_target_minutes (client-side)

# 4. Create the incident
semantius call crud postgrestRequest '{
  "method":"POST",
  "path":"/incidents",
  "body":{
    "incident_number":"INC-<next 5-digit>",
    "short_description":"<text>",
    "description":"<optional long text>",
    "reported_by_user_id":"<id from step 1>",
    "affected_user_id":"<optional>",
    "affected_configuration_item_id":"<optional>",
    "assigned_to_user_id":"<optional, often null on first report>",
    "assigned_team_id":"<optional, often the CI support_team_id>",
    "impact":"medium",
    "urgency":"medium",
    "priority":"p3_normal",
    "status":"new",
    "reported_at":"<current ISO timestamp>",
    "sla_id":"<id from step 2, or null if no match>",
    "sla_response_due_at":"<computed ISO timestamp, or null>",
    "sla_resolution_due_at":"<computed ISO timestamp, or null>",
    "sla_breached":false
  }
}'
```

`reported_at`, `sla_response_due_at`, `sla_resolution_due_at`: set at
call time; do not copy the placeholders.

**Validation:** new row exists with `incident_number=INC-...` and
`status=new`; `sla_id` is set if any active SLA matched; both due
timestamps are non-null when `sla_id` is set; `sla_breached=false`.

**Failure modes:**
- 409 on `incident_number` -> a parallel writer minted the same number;
  re-read `order=incident_number.desc&limit=1`, increment, retry once.
- No active SLA matches `(incident, priority)` -> create the incident
  with `sla_id=null` and the two due timestamps null; tell the user the
  SLA catalog is missing this priority and offer to add it via
  `use-semantius`.
- The named CI does not exist -> ask the user whether to leave
  `affected_configuration_item_id` null or to add the CI to the CMDB
  first; do not invent an id.

---

### Resolve and close an incident

**Triggers:** `resolve INC-00042`, `close this incident with a workaround`, `mark the printer outage solved`, `incident resolved by config change`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `incident_id` or `incident_number` | yes | Look up by `incident_number=eq.INC-...` (unique) or fuzzy text |
| `resolution_category` | yes for `resolved` | Pick from the enum |
| `resolution_notes` | yes for `resolved` | Free text describing the fix |
| `resolved_at` | yes for `resolved` | Use the current ISO timestamp |
| `closed_at` | yes for `closed` | Use the current ISO timestamp |

**This is a DB-unguarded multi-step lifecycle.** `assigned` ->
`in_progress` -> `on_hold`* -> `resolved` -> `closed` is enforced
client-side (`on_hold` is optional and re-enterable). The schema
accepts any value at any time. Two transitions need paired writes:

- `status='resolved'` must move with `resolved_at` AND
  `resolution_category` AND `resolution_notes` in the same PATCH.
  Setting `resolved` without these silently breaks the resolution-mix
  report.
- `status='closed'` must move with `closed_at` in the same PATCH.

`closed` is meant to follow `resolved` after a confirmation window;
do not skip directly from `in_progress` to `closed` without a
`resolved` step first, the resolution audit trail loses the cause.

**SLA breach check (optional but recommended).** When you set
`status='resolved'`, compare `now` to `sla_resolution_due_at`. If
`now > sla_resolution_due_at`, also set `sla_breached=true` in the
same PATCH so breach reports stay consistent.

**Recipe (resolve):**

```bash
# 1. Read the incident
semantius call crud postgrestRequest '{"method":"GET","path":"/incidents?incident_number=eq.<INC-...>&select=id,status,sla_resolution_due_at"}'

# 2. Refuse if status is `closed` or `cancelled`; resolve is invalid from terminal states.
# 3. Compare now to sla_resolution_due_at to decide sla_breached.

# 4. PATCH status + paired fields in one call
semantius call crud postgrestRequest '{
  "method":"PATCH",
  "path":"/incidents?id=eq.<id>",
  "body":{
    "status":"resolved",
    "resolution_category":"solved",
    "resolution_notes":"<text>",
    "resolved_at":"<current ISO timestamp>",
    "sla_breached":true
  }
}'
```

`resolved_at`: set at call time; do not copy the placeholder. Set
`sla_breached` to the computed boolean from step 3.

**Recipe (close after resolution):**

```bash
# Close as a separate PATCH; refuse if status is not currently `resolved`
semantius call crud postgrestRequest '{
  "method":"PATCH",
  "path":"/incidents?id=eq.<id>",
  "body":{"status":"closed","closed_at":"<current ISO timestamp>"}
}'
```

**Validation:** `status` matches; `resolved_at` (and `closed_at` if
closed) is non-null; `resolution_category` is set when `status` ever
became `resolved`.

**Failure modes:**
- `resolved` set without `resolution_category` -> resolution-mix
  reports drop the row; PATCH to add the category.
- `closed` set without `resolved` first -> the audit trail has no
  record of how the issue was fixed; the only recovery is to also
  PATCH the resolution fields after the fact.
- Reopening (status flipped back from `resolved` to `in_progress`) is
  allowed by the DB but should be rare; surface to the user before
  doing it.

---

### Raise and fulfill a service request

**Triggers:** `raise a service request for a new laptop`, `request VPN access for Bob`, `approve this service request`, `mark SR-00012 fulfilled`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `catalog_item_id` | yes | Resolve via `catalog_item_name` (unique) or fuzzy text |
| `requested_by_user_id` | yes | The user making the request; lookup by email |
| `requested_for_user_id` | no | Beneficiary, when raising on someone's behalf |
| `short_description` | yes | One-line summary |
| `priority` | yes | Defaults to `p3_normal` |
| `requested_at` | yes | Current ISO timestamp |

**Approval gate driven by the catalog item.** Each
`service_catalog_items.requires_approval` boolean decides the entry
status of a fresh service request:

- If `requires_approval=false`, create with `status='new'` and skip
  straight to assignment + work.
- If `requires_approval=true`, create with `status='approval_pending'`
  and route to the approval recipe before any fulfillment work.

**Paired writes on each transition:**

- `status='approved'` must move with `approved_at` in the same PATCH.
- `status='fulfilled'` must move with `fulfilled_at` in the same PATCH.
- `status='closed'` must move with `closed_at` in the same PATCH.

**Minting `request_number`.** The model uses `SR-NNNNN`. Read the
last request number, increment, zero-pad.

**Recipe (create):**

```bash
# 1. Resolve catalog item, requester, and the next request number
semantius call crud postgrestRequest '{"method":"GET","path":"/service_catalog_items?catalog_item_name=eq.<name>&select=id,requires_approval,delivery_team_id,target_delivery_days"}'
semantius call crud postgrestRequest '{"method":"GET","path":"/users?email=eq.<email>&select=id,user_name"}'
semantius call crud postgrestRequest '{"method":"GET","path":"/service_requests?order=request_number.desc&limit=1&select=request_number"}'

# 2. Pick entry status from catalog_item.requires_approval
#    (true -> approval_pending, false -> new)

# 3. Create
semantius call crud postgrestRequest '{
  "method":"POST",
  "path":"/service_requests",
  "body":{
    "request_number":"SR-<next 5-digit>",
    "catalog_item_id":"<id>",
    "requested_by_user_id":"<id>",
    "requested_for_user_id":"<optional>",
    "assigned_team_id":"<catalog_item.delivery_team_id, optional>",
    "short_description":"<text>",
    "description":"<optional>",
    "status":"approval_pending",
    "priority":"p3_normal",
    "requested_at":"<current ISO timestamp>",
    "due_date":"<computed: today + target_delivery_days, optional>"
  }
}'
```

**Recipe (approve):**

```bash
# Read first; refuse unless status is approval_pending
semantius call crud postgrestRequest '{"method":"GET","path":"/service_requests?id=eq.<id>&select=id,status"}'

semantius call crud postgrestRequest '{
  "method":"PATCH",
  "path":"/service_requests?id=eq.<id>",
  "body":{"status":"approved","approved_at":"<current ISO timestamp>"}
}'
```

**Recipe (work and fulfill):**

```bash
# Move into work
semantius call crud postgrestRequest '{
  "method":"PATCH",
  "path":"/service_requests?id=eq.<id>",
  "body":{"status":"in_progress","assigned_to_user_id":"<agent id>"}
}'

# Fulfill (paired write)
semantius call crud postgrestRequest '{
  "method":"PATCH",
  "path":"/service_requests?id=eq.<id>",
  "body":{"status":"fulfilled","fulfilled_at":"<current ISO timestamp>"}
}'

# Close after confirmation (paired write)
semantius call crud postgrestRequest '{
  "method":"PATCH",
  "path":"/service_requests?id=eq.<id>",
  "body":{"status":"closed","closed_at":"<current ISO timestamp>"}
}'
```

`requested_at`, `approved_at`, `fulfilled_at`, `closed_at`: set at
call time; do not copy the placeholders.

**Validation:** at each transition, `status` and the paired side-effect
field are both set; `request_number` is unique and follows `SR-NNNNN`.

**Failure modes:**
- 409 on `request_number` -> re-read the max and retry once.
- `approved` set without `approved_at` (or `fulfilled` without
  `fulfilled_at`, or `closed` without `closed_at`) -> SLA / time-to-
  fulfill reports drop the row; PATCH to add the missing timestamp.
- Catalog item is `is_active=false` -> refuse to create against an
  inactive item; ask the user whether to revive it or pick another.
- `requires_approval=true` but the user wants to skip approval ->
  refuse silently bypassing it; the approver chain exists for a
  reason. Surface and ask.

---

### Roll incidents up to a problem

**Triggers:** `roll these incidents up to a problem`, `the printer outages have a common cause, open a problem`, `link INC-00042 to PRB-00003`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| Incident IDs | yes | One or more existing incidents to link |
| `short_description` | yes | One-line summary of the suspected root cause area |
| `priority` | yes | Often the highest priority among the linked incidents |
| `opened_at` | yes | Current ISO timestamp |
| `affected_configuration_item_id` | no | If the incidents share a CI, copy it here |

**This is a Pattern C materialization.** Creating a problem from a
set of incidents is two steps that must both succeed:

1. POST a new `problems` row.
2. PATCH each incident to set `problem_id` to the new problem's id.

If you stop after step 1 the incidents are still orphaned and the
problem looks like it has no real-world evidence behind it. If you
PATCH only some incidents, the problem-incident-count metric is wrong.

**Minting `problem_number`.** `PRB-NNNNN`, same approach as incidents.

**Recipe:**

```bash
# 1. Read the incidents you'll be linking; capture the highest priority and a common CI if any
semantius call crud postgrestRequest '{"method":"GET","path":"/incidents?id=in.(<id1>,<id2>,...)&select=id,priority,affected_configuration_item_id"}'

# 2. Mint the next PRB-NNNNN
semantius call crud postgrestRequest '{"method":"GET","path":"/problems?order=problem_number.desc&limit=1&select=problem_number"}'

# 3. Create the problem
semantius call crud postgrestRequest '{
  "method":"POST",
  "path":"/problems",
  "body":{
    "problem_number":"PRB-<next 5-digit>",
    "short_description":"<text>",
    "description":"<optional>",
    "affected_configuration_item_id":"<optional, common CI from step 1>",
    "priority":"<highest priority from step 1>",
    "status":"new",
    "opened_at":"<current ISO timestamp>"
  }
}'

# 4. Link every incident in one bulk PATCH
semantius call crud postgrestRequest '{
  "method":"PATCH",
  "path":"/incidents?id=in.(<id1>,<id2>,...)",
  "body":{"problem_id":"<new problem id>"}
}'
```

`opened_at`: set at call time; do not copy the placeholder.

**Validation:** new problem row exists; every incident in the input
list now has `problem_id` equal to the new problem's id (re-GET to
confirm).

**Failure modes:**
- The bulk PATCH partially fails (PostgREST is all-or-nothing on a
  single PATCH, but a network drop can leave the client unsure) ->
  re-read the incident set and PATCH only those still missing
  `problem_id`.
- An incident in the input list is already linked to a different
  problem -> refuse to overwrite silently; show both problem ids and
  ask the user which one wins, or whether the two problems should
  merge first.

---

### Investigate and resolve a problem

**Triggers:** `investigate this problem`, `mark PRB-00003 root cause known`, `the workaround is X, record it`, `resolve the problem with this change`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `problem_id` or `problem_number` | yes | Look up by `problem_number=eq.PRB-...` |
| Target status | yes | One of `investigating`, `root_cause_known`, `workaround_available`, `resolved`, `closed` |
| `root_cause`, `workaround` | yes for `root_cause_known` / `workaround_available` | Free text |
| `resolution_change_request_id` | no | The change that fixes it; resolve via `change_number` |
| `known_error_article_id` | no | A KB article documenting the known error |

**This is a DB-unguarded lifecycle.** Status moves are accepted by the
schema but each meaningful transition has a paired write:

- `status='root_cause_known'` should move with `root_cause` text.
- `status='workaround_available'` should move with `workaround` text.
- `status='resolved'` must move with `resolved_at`.
- `status='closed'` must move with `closed_at`.

**Linking a resolution change is a separate concern.** Setting
`resolution_change_request_id` is what flips this problem from "we
know what's wrong" to "a specific change will fix it"; do it as a
separate PATCH from the status flip so the audit trail stays clean,
unless you happen to be doing both in the same call.

**Recipe (record root cause):**

```bash
semantius call crud postgrestRequest '{
  "method":"PATCH",
  "path":"/problems?id=eq.<id>",
  "body":{
    "status":"root_cause_known",
    "root_cause":"<text>"
  }
}'
```

**Recipe (link to a resolving change):**

```bash
# Resolve the change first
semantius call crud postgrestRequest '{"method":"GET","path":"/change_requests?change_number=eq.<CHG-...>&select=id,status"}'

# Link
semantius call crud postgrestRequest '{
  "method":"PATCH",
  "path":"/problems?id=eq.<id>",
  "body":{"resolution_change_request_id":"<change id>"}
}'
```

**Recipe (resolve):**

```bash
semantius call crud postgrestRequest '{
  "method":"PATCH",
  "path":"/problems?id=eq.<id>",
  "body":{"status":"resolved","resolved_at":"<current ISO timestamp>"}
}'
```

**Recipe (close):**

```bash
semantius call crud postgrestRequest '{
  "method":"PATCH",
  "path":"/problems?id=eq.<id>",
  "body":{"status":"closed","closed_at":"<current ISO timestamp>"}
}'
```

`resolved_at`, `closed_at`: set at call time; do not copy the
placeholders.

**Validation:** for each transition, `status` matches and the paired
text or timestamp field is set.

**Failure modes:**
- `resolved` set without `resolved_at` -> mean-time-to-resolve metric
  drops the row; PATCH to add the timestamp.
- `resolution_change_request_id` set to a change that is `cancelled`
  or `failed` -> the problem still claims to be resolved by that
  change; surface to the user and offer to clear the link.

---

### Submit a change request with affected CIs

**Triggers:** `open a change request for tonight's maintenance window`, `submit an emergency change`, `add the database server to this change`, `submit CHG-00042`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `short_description` | yes | One-line summary |
| `change_type` | yes | `standard`, `normal`, `emergency` |
| `risk`, `impact` | yes | All three-level severities |
| `requested_by_user_id` | yes | Lookup by email |
| Affected CIs | yes (>= 1) | One or more CI ids; each gets an `impact_role` (`primary`, `dependency`, `downstream`, `witness`) |
| `planned_start_at`, `planned_end_at` | no but recommended | ISO timestamps for the maintenance window |
| `implementation_plan`, `rollback_plan`, `test_plan` | no but recommended | Free text |
| `vendor_id` | no | If the change is performed by an external vendor |
| `assigned_team_id` | no | Implementer team |

**Junction has no DB-level uniqueness on
`(change_request_id, configuration_item_id)`.** A second POST with
the same `(change, CI)` pair creates a duplicate row that pollutes
the affected-CI list. Always read first before adding.

**Caller-populated junction label.**
`change_configuration_items.change_ci_label` is required on insert
and not auto-derived. Compose it as `"{change_number} / {ci_name}"`,
e.g. `"CHG-00042 / mail-server-01"`. The recipe must read both rows
to have the values to compose with.

**Minting `change_number`.** `CHG-NNNNN`, same pattern.

**Recipe (create the change in `draft`):**

```bash
# 1. Resolve requester and next CHG number
semantius call crud postgrestRequest '{"method":"GET","path":"/users?email=eq.<email>&select=id,user_name"}'
semantius call crud postgrestRequest '{"method":"GET","path":"/change_requests?order=change_number.desc&limit=1&select=change_number"}'

# 2. Create the change as draft
semantius call crud postgrestRequest '{
  "method":"POST",
  "path":"/change_requests",
  "body":{
    "change_number":"CHG-<next 5-digit>",
    "short_description":"<text>",
    "description":"<optional>",
    "change_type":"normal",
    "risk":"medium",
    "impact":"medium",
    "status":"draft",
    "requested_by_user_id":"<id>",
    "assigned_team_id":"<optional>",
    "vendor_id":"<optional>",
    "planned_start_at":"<optional ISO timestamp>",
    "planned_end_at":"<optional ISO timestamp>",
    "implementation_plan":"<optional text>",
    "rollback_plan":"<optional text>",
    "test_plan":"<optional text>"
  }
}'
```

**Recipe (attach affected CIs):**

```bash
# 1. For each CI, read the CI name and check whether the junction row already exists
semantius call crud postgrestRequest '{"method":"GET","path":"/configuration_items?id=eq.<ci_id>&select=id,ci_name"}'
semantius call crud postgrestRequest '{"method":"GET","path":"/change_configuration_items?change_request_id=eq.<change_id>&configuration_item_id=eq.<ci_id>&select=id,impact_role"}'

# 2a. If a junction row already exists with the same impact_role, do nothing.
# 2b. If it exists with a different impact_role and the user wants to change it, PATCH:
semantius call crud postgrestRequest '{
  "method":"PATCH",
  "path":"/change_configuration_items?id=eq.<existing id>",
  "body":{"impact_role":"<new role>"}
}'
# 2c. Otherwise, POST a new junction row with the composed label:
semantius call crud postgrestRequest '{
  "method":"POST",
  "path":"/change_configuration_items",
  "body":{
    "change_ci_label":"<change_number> / <ci_name>",
    "change_request_id":"<change id>",
    "configuration_item_id":"<ci id>",
    "impact_role":"primary"
  }
}'
```

**Recipe (submit for approval):**

```bash
# Refuse unless current status is `draft`
semantius call crud postgrestRequest '{"method":"GET","path":"/change_requests?id=eq.<id>&select=id,status"}'

semantius call crud postgrestRequest '{
  "method":"PATCH",
  "path":"/change_requests?id=eq.<id>",
  "body":{"status":"approval_pending"}
}'
```

**Validation:** change row exists with `status` in `draft` or
`approval_pending`; at least one matching `change_configuration_items`
row exists; every junction row has a non-empty `change_ci_label`
that matches the `"{change_number} / {ci_name}"` composition.

**Failure modes:**
- 409 on `change_number` -> re-read max and retry once.
- A junction row was POSTed without first reading -> a duplicate row
  exists; PATCH one of them to a different `impact_role` if the user
  truly meant two roles, otherwise DELETE the duplicate by id.
- `change_ci_label` left null or generic -> downstream UIs and
  reports show a blank affected-CI line; PATCH to set the proper
  composition.
- Submitting with no affected CIs (zero junction rows) -> permitted
  by the schema but almost always wrong; surface to the user before
  flipping to `approval_pending`.

---

### Approve, schedule, implement, and close a change request

**Triggers:** `approve the emergency change`, `schedule CHG-00042 for Saturday`, `start the maintenance window`, `mark the change implemented`, `close the change as failed`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `change_id` or `change_number` | yes | Resolve via `change_number=eq.CHG-...` |
| Target status | yes | `approved`, `scheduled`, `in_progress`, `implemented`, `review`, `closed`, `cancelled`, `failed` |
| `approver_user_id` | yes for `approved` | Lookup by email |
| `planned_start_at`, `planned_end_at` | yes for `scheduled` if not already set | ISO timestamps |
| `actual_start_at` | yes for `in_progress` | Current ISO timestamp |
| `actual_end_at` | yes for `implemented` and `failed` | Current ISO timestamp |
| `post_implementation_notes` | yes for `closed` (recommended) | Free text |

**This is a DB-unguarded multi-step lifecycle.** The schema accepts
any value at any time; the rules below are enforced client-side.
Each transition has a paired write:

- `approval_pending` -> `approved`: `approver_user_id` in the same PATCH.
- `approved` -> `scheduled`: `planned_start_at` and `planned_end_at`
  must be non-null on the row (PATCH them in if missing).
- `scheduled` -> `in_progress`: `actual_start_at` in the same PATCH.
- `in_progress` -> `implemented` or `failed`: `actual_end_at` in the
  same PATCH.
- `implemented` -> `review` -> `closed`: `post_implementation_notes`
  recommended on the close PATCH.

`emergency` changes may legitimately skip directly from
`approval_pending` to `in_progress` (CAB approval after the fact); if
the user signals it is an emergency, do not block the skip but
record approver + actual_start in the same PATCH.

**Recipe (approve):**

```bash
# Resolve approver and read the change
semantius call crud postgrestRequest '{"method":"GET","path":"/users?email=eq.<email>&select=id,user_name"}'
semantius call crud postgrestRequest '{"method":"GET","path":"/change_requests?id=eq.<id>&select=id,status,change_type"}'

# Refuse unless status is approval_pending; for emergency, allow as override
semantius call crud postgrestRequest '{
  "method":"PATCH",
  "path":"/change_requests?id=eq.<id>",
  "body":{"status":"approved","approver_user_id":"<approver id>"}
}'
```

**Recipe (schedule):**

```bash
# planned_start_at and planned_end_at must be set. If they are already on the row from create, only PATCH status; otherwise include them.
semantius call crud postgrestRequest '{
  "method":"PATCH",
  "path":"/change_requests?id=eq.<id>",
  "body":{
    "status":"scheduled",
    "planned_start_at":"<ISO timestamp>",
    "planned_end_at":"<ISO timestamp>"
  }
}'
```

**Recipe (start the window):**

```bash
semantius call crud postgrestRequest '{
  "method":"PATCH",
  "path":"/change_requests?id=eq.<id>",
  "body":{"status":"in_progress","actual_start_at":"<current ISO timestamp>"}
}'
```

**Recipe (mark implemented or failed):**

```bash
# Implemented (success)
semantius call crud postgrestRequest '{
  "method":"PATCH",
  "path":"/change_requests?id=eq.<id>",
  "body":{"status":"implemented","actual_end_at":"<current ISO timestamp>"}
}'

# Failed (rolled back)
semantius call crud postgrestRequest '{
  "method":"PATCH",
  "path":"/change_requests?id=eq.<id>",
  "body":{"status":"failed","actual_end_at":"<current ISO timestamp>","post_implementation_notes":"<rollback summary>"}
}'
```

**Recipe (review and close):**

```bash
# Optional review step
semantius call crud postgrestRequest '{
  "method":"PATCH",
  "path":"/change_requests?id=eq.<id>",
  "body":{"status":"review"}
}'

# Close
semantius call crud postgrestRequest '{
  "method":"PATCH",
  "path":"/change_requests?id=eq.<id>",
  "body":{"status":"closed","post_implementation_notes":"<text>"}
}'
```

`planned_start_at`, `planned_end_at`, `actual_start_at`,
`actual_end_at`: set at call time; do not copy the placeholders.

**Validation:** `status` matches; the paired field is set
(`approver_user_id`, `actual_start_at`, `actual_end_at` as appropriate);
a `closed`/`failed` change has both actual timestamps non-null.

**Failure modes:**
- `approved` set without `approver_user_id` -> "who approved this"
  query is blank; PATCH to add the approver.
- `in_progress` set without `actual_start_at` -> change-window
  duration metric drops the row; PATCH to add the timestamp.
- `implemented` or `failed` set without `actual_end_at` -> same.
- A change is set to `failed` but the affected CIs were already
  patched to a new state by the implementer -> the CMDB and the
  change record disagree. There is no automatic rollback; surface
  to the user and roll back CIs manually if the rollback plan calls
  for it.

---

### Post a ticket comment

**Triggers:** `post a public comment on INC-00042`, `add an internal work-note to PRB-00003`, `comment on the change`, `reply to the requester on SR-00012`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| Parent ticket | yes | Either the explicit ticket id + type, or a number like `INC-...`/`SR-...`/`PRB-...`/`CHG-...` from which both can be derived |
| `author_user_id` | yes | Lookup by email |
| `body` | yes | The comment text |
| `visibility` | yes | `public` or `internal`; defaults to `internal` |
| `posted_at` | yes | Current ISO timestamp |

**Polymorphic invariant (caller-enforced).** The row has four FK
columns (`incident_id`, `service_request_id`, `problem_id`,
`change_request_id`) and a `ticket_type` discriminator. **Exactly one
of the four must be set, and it must match `ticket_type`.** The DB
allows nulls on each individually and accepts inconsistent rows; the
recipe sets exactly one FK in the same POST that sets `ticket_type`.

**Caller-populated label.**
`ticket_comments.ticket_comment_label` is required on insert and not
auto-derived. Compose it as `"{ticket_type}-{ticket_number} #{seq}"`
where `seq` is a 1-based per-ticket counter, e.g.
`"incident-INC-00042 #3"`. To compute `seq`, count the existing
comments on that ticket and add 1.

Discriminator-to-FK mapping (use this table verbatim):

| `ticket_type` value | FK column to populate | Number prefix |
|---|---|---|
| `incident` | `incident_id` | `INC-` |
| `service_request` | `service_request_id` | `SR-` |
| `problem` | `problem_id` | `PRB-` |
| `change_request` | `change_request_id` | `CHG-` |

**Recipe:**

```bash
# 1. Resolve the parent ticket. Pick the right table from the prefix.
#    Example for an incident:
semantius call crud postgrestRequest '{"method":"GET","path":"/incidents?incident_number=eq.<INC-...>&select=id,incident_number"}'

# 2. Compute the next per-ticket seq by counting existing comments
semantius call crud postgrestRequest '{"method":"GET","path":"/ticket_comments?incident_id=eq.<id>&select=id"}'

# 3. Resolve the author
semantius call crud postgrestRequest '{"method":"GET","path":"/users?email=eq.<email>&select=id,user_name"}'

# 4. POST the comment with exactly one of the four FKs set, matching ticket_type
semantius call crud postgrestRequest '{
  "method":"POST",
  "path":"/ticket_comments",
  "body":{
    "ticket_comment_label":"incident-<INC-...> #<seq>",
    "ticket_type":"incident",
    "incident_id":"<id>",
    "service_request_id":null,
    "problem_id":null,
    "change_request_id":null,
    "author_user_id":"<id>",
    "body":"<text>",
    "visibility":"internal",
    "posted_at":"<current ISO timestamp>"
  }
}'
```

`posted_at`: set at call time; do not copy the placeholder.

**Validation:** the new row has exactly one of the four FKs non-null;
that FK column matches the `ticket_type` per the table above;
`ticket_comment_label` follows `"{ticket_type}-{ticket_number} #{seq}"`.

**Failure modes:**
- More than one of the four FKs set -> the row violates the caller
  invariant. The DB accepted it; recover by PATCHing the extras to
  null. Do not POST in this shape again.
- `ticket_type` does not match the populated FK column (e.g.
  `ticket_type='incident'` but `problem_id` is set) -> same recovery:
  null out the wrong FK and set the right one in the same PATCH.
- `ticket_comment_label` left null -> the row was rejected (label is
  required); compose it and retry.
- `seq` collision with a parallel writer -> harmless, `seq` is for
  display only and the DB does not constrain it; do not retry.

---

### Publish a knowledge article

**Triggers:** `publish the runbook for the printer outage`, `move KB-00042 to in_review`, `publish this article to customers`, `archive this knowledge article`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `article_id` or `article_title` | yes | Look up by `article_title` (unique) or `article_number` |
| Target status | yes | `draft`, `in_review`, `published`, `archived` |
| `published_at` | yes for `published` | Current ISO timestamp |
| `visibility` | no | `internal`, `customer`, `public`; tighten on publish if needed |

**This is a Pattern F publication lifecycle.**
`draft` -> `in_review` -> `published` -> `archived` is enforced
client-side. The schema accepts any value at any time. Two paired
writes:

- `status='published'` must move with `published_at` in the same PATCH.
- Re-publishing after `archived` should set `published_at` to the new
  publish time, not preserve the original.

`view_count` is auto-defaulted to 0 by the schema; do not write it on
publish.

**Recipe (move to review):**

```bash
semantius call crud postgrestRequest '{
  "method":"PATCH",
  "path":"/knowledge_articles?id=eq.<id>",
  "body":{"status":"in_review"}
}'
```

**Recipe (publish):**

```bash
# Read first; refuse unless status is `in_review` (or `archived` if re-publishing)
semantius call crud postgrestRequest '{"method":"GET","path":"/knowledge_articles?id=eq.<id>&select=id,status,visibility"}'

semantius call crud postgrestRequest '{
  "method":"PATCH",
  "path":"/knowledge_articles?id=eq.<id>",
  "body":{
    "status":"published",
    "published_at":"<current ISO timestamp>",
    "visibility":"customer"
  }
}'
```

**Recipe (archive):**

```bash
semantius call crud postgrestRequest '{
  "method":"PATCH",
  "path":"/knowledge_articles?id=eq.<id>",
  "body":{"status":"archived"}
}'
```

`published_at`: set at call time; do not copy the placeholder.

**Validation:** when `status='published'`, `published_at` is non-null.

**Failure modes:**
- `published` set without `published_at` -> the article shows as
  published but with no recorded publish time; PATCH to add it.
- `published` set directly from `draft` (skipping `in_review`) ->
  permitted by the schema but skips the editorial review the model
  intends; surface to the user before allowing it.
- `visibility='public'` set on a `known_error` article -> often
  unintended; surface, the article may contain internal-only
  diagnostic detail.

---

## Common queries

These are starting points, not contracts. Cube schema names drift
when the model is regenerated, so always run `cube discover '{}'`
first and map the dimension and measure names below against
`discover`'s output. The cube name is usually the entity's table
name with the first letter capitalized (e.g. `Incidents`,
`ServiceRequests`), but verify.

```bash
# Always first
semantius call cube discover '{}'
```

```bash
# Open tickets by team and priority (incidents only)
semantius call cube load '{"query":{
  "measures":["Incidents.count"],
  "dimensions":["Teams.team_name","Incidents.priority"],
  "filters":[{"member":"Incidents.status","operator":"notEquals","values":["closed","cancelled"]}],
  "order":{"Incidents.count":"desc"}
}}'
```

```bash
# SLA breach rate over the last 90 days (incidents resolved in window)
semantius call cube load '{"query":{
  "measures":["Incidents.count"],
  "dimensions":["Incidents.sla_breached"],
  "timeDimensions":[{"dimension":"Incidents.resolved_at","granularity":"month","dateRange":"last 90 days"}]
}}'
```

```bash
# Change calendar: changes scheduled in the next 14 days, by team
semantius call cube load '{"query":{
  "measures":["ChangeRequests.count"],
  "dimensions":["Teams.team_name","ChangeRequests.change_type","ChangeRequests.status"],
  "timeDimensions":[{"dimension":"ChangeRequests.planned_start_at","dateRange":"next 14 days"}],
  "order":{"ChangeRequests.count":"desc"}
}}'
```

```bash
# Top problems by incident count (pattern detection)
semantius call cube load '{"query":{
  "measures":["Incidents.count"],
  "dimensions":["Problems.problem_number","Problems.short_description","Problems.status"],
  "filters":[{"member":"Incidents.problem_id","operator":"set"}],
  "order":{"Incidents.count":"desc"},
  "limit":20
}}'
```

```bash
# Knowledge article views by status and visibility
semantius call cube load '{"query":{
  "measures":["KnowledgeArticles.sum_view_count","KnowledgeArticles.count"],
  "dimensions":["KnowledgeArticles.status","KnowledgeArticles.visibility","KnowledgeArticles.article_type"],
  "order":{"KnowledgeArticles.sum_view_count":"desc"}
}}'
```

---

## Guardrails

- Never PATCH `incidents.status` to `resolved` without setting
  `resolved_at`, `resolution_category`, and `resolution_notes` in the
  same call; or to `closed` without `closed_at`.
- Never PATCH `service_requests.status` to `approved`/`fulfilled`/
  `closed` without setting the matching paired timestamp
  (`approved_at`/`fulfilled_at`/`closed_at`) in the same call.
- Never PATCH `change_requests.status` past `approval_pending`
  without a paired write: `approver_user_id` for `approved`,
  `actual_start_at` for `in_progress`, `actual_end_at` for
  `implemented`/`failed`.
- Never PATCH `problems.status` to `resolved` without `resolved_at`,
  or to `closed` without `closed_at`.
- Never PATCH `knowledge_articles.status` to `published` without
  `published_at` in the same call.
- Never POST to `change_configuration_items` for a
  `(change_request_id, configuration_item_id)` pair that already
  exists; read first and PATCH the existing row's `impact_role` if it
  needs to change.
- Never POST to `ticket_comments` with more than one of
  `incident_id`/`service_request_id`/`problem_id`/`change_request_id`
  set, or with the populated FK not matching `ticket_type`. Always
  null the other three explicitly in the body.
- Never leave `ticket_comment_label` or `change_ci_label` blank on
  insert; both are required and not auto-derived.
- Lookups for human-friendly identifiers (CI names, user emails,
  ticket numbers, article titles) use either `eq.<value>` (for known
  unique columns) or `search_vector=wfts(simple).<term>` (for fuzzy
  text). Never `ilike`, never `fts`.
- Audit-logged tables (`vendors`, `configuration_items`,
  `service_catalog_items`, `service_requests`, `incidents`, `problems`,
  `change_requests`, `knowledge_articles`, `service_level_agreements`)
  write their own audit rows; do not hand-write to any audit table.
- `users` may already exist as a Semantius built-in in this
  deployment; treat it as the authoritative table and reference it
  rather than creating a parallel one.

## What this skill does NOT do

- Schema changes, use `use-semantius` directly.
- RBAC / permissions, use `use-semantius` directly.
- One-off seed data, write a script, do not bake it into a JTBD.
- Multiple support-group memberships per user: the model has only a
  single `users.primary_team_id`; M:N team membership is not
  supported.
- Multiple impacted CIs per incident: only one
  `incidents.affected_configuration_item_id` is modeled; an
  `incident_configuration_items` junction does not exist.
- Hierarchical service-catalog categories: `category` is a flat enum,
  not a lookup table.
- Polymorphic file attachments: there is no `attachments` entity in
  this model.
- Releases and deployments that bundle multiple changes: no
  `releases` or `deployments` entities exist yet.
- Change Advisory Board (CAB) meeting tracking: the model only stores
  a per-change `approver_user_id`, not a meeting-level approval
  record.
- SLA matching by category, customer segment, or per-region business
  hours: only `(ticket_type, priority)` plus a single
  `business_hours_only` flag are supported.
- Computed `incidents.priority` from `impact` x `urgency`: the field
  is stored, not derived; callers must set it explicitly.
- Typed CI dependencies (depends_on, runs_on, communicates_with): the
  model has only a single `parent_ci_id` self-reference.
- Sub-tasks under an incident or change (`incident_tasks`,
  `change_tasks`): not modeled; use ticket comments instead.
- Per-incident cost rollup or workaround-effectiveness scoring on
  problems: not modeled.
