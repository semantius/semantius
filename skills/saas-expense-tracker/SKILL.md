---
name: saas-expense-tracker
description: >-
  Use this skill for anything involving the SaaS Expense Tracker & Budget,
  the in-house system that records the company's SaaS subscriptions, the
  seats consumed against them, and the planned spend per fiscal period.
  Trigger when the user says: "add a new SaaS subscription", "cancel the
  Slack subscription", "assign Bob a license on Figma", "revoke Alice's
  GitHub seat", "offboard Sarah and revoke her licenses", "create a
  budget line for engineering dev tools", "renew the Notion
  subscription", "what's our SaaS spend by department this quarter",
  "which licenses are unused", "show upcoming renewals". Loads alongside
  `use-semantius`, which owns CLI install, PostgREST encoding, and cube
  query mechanics.
semantic_model: saas_expense_tracker
---

# SaaS Expense Tracker & Budget

This skill carries the domain map and the jobs-to-be-done for the
SaaS Expense Tracker & Budget. Platform mechanics, CLI install, env
vars, PostgREST URL-encoding, `sqlToRest`, cube
`discover`/`validate`/`load`, and schema-management tools, live in
`use-semantius`. Assume it loads alongside; do not re-explain CLI
basics here.

If a task is purely about defining schema, managing permissions, or
running ad-hoc queries against tables you already know, call
`use-semantius` directly, going through this skill adds nothing.

**Auto-managed fields** (set by Semantius on every table; never include
in POST/PATCH bodies): `id`, `created_at`, `updated_at`. Every other
required field, including the caller-populated `*_label` columns on
`license_assignments` (`assignment_label`) and `budget_lines`
(`budget_line_name`), is **caller-populated** and must appear in the
POST body. The composition rule for each is given in its JTBD below.
The other label columns in this model (`vendor_name`,
`subscription_name`, `department_name`, `period_name`, `full_name`)
are natural fields the user supplies directly, also required on create.

**Currency.** All monetary fields (`recurring_amount`, `unit_price`,
`total_contract_value`, `negotiated_savings`, `planned_amount`,
`monthly_cost_allocation`) are stored in a single implicit base
currency. Multi-currency is not modeled; do not invent a `currency`
column.

---

## Domain glossary

The spend funnel runs **Vendor -> Subscription -> License Assignment**
on the consumption side and **Budget Period -> Budget Line** on the
plan side, with Departments and Users orbiting both.

| Concept | Table | Notes |
|---|---|---|
| Vendor | `vendors` | The company that sells a SaaS product (e.g. Slack Technologies, Atlassian); `vendor_name` is unique |
| Subscription | `subscriptions` | One product-commercial pairing on one record: app, vendor, terms (seats, price, cadence, dates), and contract details |
| Department | `departments` | Cost center funding spend; supports a self-referencing parent hierarchy |
| Budget Period | `budget_periods` | A fiscal year, quarter, month, or custom range that contains budget lines |
| Budget Line | `budget_lines` | Planned spend allocated to a department, subscription, or category for one period |
| License Assignment | `license_assignments` | Junction: which user is consuming a seat on which subscription; used for chargeback and unused-license detection |
| User | `users` | Internal employee, deduped against the Semantius built-in `users` table |

## Key enums

Only the enums that gate JTBDs are listed; full enum sets live in the
semantic model. Arrows mark the typical lifecycle path; `|` separates
terminal states.

- `subscriptions.status`: `pending` -> `trialing` -> `active` -> `cancelled` | `expired` | `deprecated` | `archived` (default on create: `pending`)
- `subscriptions.billing_cycle`: `monthly`, `quarterly`, `annual`, `multi_year`, `one_time` (default on create: `monthly`)
- `subscriptions.criticality`: `critical`, `important`, `nice_to_have`
- `license_assignments.status`: `pending` -> `active` -> `inactive` | `revoked` (default on create: `active`)
- `budget_periods.status`: `draft` -> `open` -> `closed` -> `archived` (default on create: `draft`)
- `budget_periods.period_type`: `fiscal_year`, `quarter`, `month`, `custom` (default on create: `fiscal_year`)
- `budget_lines.category`: same as `subscriptions.category` plus `unallocated`; the two diverge here so do not assume they are interchangeable
- `subscriptions.category` / `budget_lines.category`: `communication`, `dev_tools`, `productivity`, `marketing`, `sales`, `hr`, `finance`, `security`, `design`, `analytics`, `infrastructure`, `other` (and `unallocated` only for `budget_lines`)
- `users.status`: `active` -> `inactive` | `offboarded` (default on create: `active`)
- `departments.status`: `active`, `inactive`

## Foreign-key cheatsheet

Only the FKs that JTBDs cross. Format: `child.field -> parent.id`
(delete behavior in parens).

- `subscriptions.vendor_id -> vendors.id` (**restrict**: a vendor cannot be deleted while subscriptions exist)
- `subscriptions.business_owner_id -> users.id` (clear)
- `subscriptions.primary_department_id -> departments.id` (clear)
- `subscriptions.signatory_user_id -> users.id` (clear)
- `license_assignments.subscription_id -> subscriptions.id` (parent, cascade)
- `license_assignments.user_id -> users.id` (parent, cascade)
- `budget_lines.budget_period_id -> budget_periods.id` (parent, cascade)
- `budget_lines.department_id -> departments.id` (clear)
- `budget_lines.subscription_id -> subscriptions.id` (clear)
- `departments.manager_user_id -> users.id` (clear)
- `departments.parent_department_id -> departments.id` (clear, self-ref)
- `users.department_id -> departments.id` (clear)

**Unique columns** (409 on duplicate POST): `vendors.vendor_name`,
`departments.department_code`, `users.email`, `users.employee_id`.

**No DB-level uniqueness on the natural junction key.**
`license_assignments(subscription_id, user_id)` is **not** constrained.
POSTing the same pair twice creates a duplicate row that double-counts
in chargeback. Recipes must read first.

**No DB-level cap on seat consumption.** `subscriptions.seat_count` is
informational; the database does not stop a 51st `active`
license_assignment on a 50-seat subscription. The recipe must count
existing active assignments before inserting.

**Built-in `users` table.** This deployment treats Semantius's
built-in `users` as authoritative. Do not POST to a parallel `users`
table; reference the built-in for `business_owner_id`,
`signatory_user_id`, `license_assignments.user_id`,
`departments.manager_user_id`, and `users.department_id`.

This model declares no `audit_log: true` flags, so no entity has a
managed audit trail. Treat `updated_at` as the only built-in change
indicator and recommend `users.update_user`, etc., directly when the
user asks "who changed X" (the answer is "we don't record that here").

---

## Jobs to be done

### Add a SaaS subscription

**Triggers:** `add a new SaaS subscription`, `we just signed a contract with X`, `onboard the Notion subscription`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `vendor_id` | yes | Resolve `vendor_name` to id; create the vendor first if it does not exist |
| `subscription_name` | yes | Human label, e.g. `"Slack Business+ -- Engineering"` |
| `billing_cycle` | yes | One of `monthly`, `quarterly`, `annual`, `multi_year`, `one_time` |
| `recurring_amount` | yes | Total per billing cycle in base currency |
| `start_date` | yes | YYYY-MM-DD; do not bake a literal value |
| `status` | yes | `pending` if contract is signed but not yet billing; `trialing` for active trial; `active` if `start_date <= today` and billing has begun |
| `business_owner_id`, `primary_department_id`, `signatory_user_id` | no | Each cleared if the referenced user/department is deleted |
| `seat_count`, `unit_price`, `end_date`, `auto_renew`, `category`, `criticality`, `payment_method`, `payment_terms`, `contract_number`, `signed_date`, `total_contract_value`, `renewal_notice_days`, `negotiated_savings`, `document_url`, `description`, `website_url`, `notes` | no | Fill if the user named them |

If the user names a vendor that does not yet exist, create the vendor
first (single POST to `/vendors`) and reuse the new id.

**Lookup convention.** Semantius adds a `search_vector` column to
searchable entities for full-text search across all text fields. Use
it whenever the user passes a name or title, not a UUID:

```bash
# Resolve a vendor by anything the user typed
semantius call crud postgrestRequest '{"method":"GET","path":"/vendors?search_vector=wfts(simple).<term>&select=id,vendor_name"}'

# Resolve a subscription by anything the user typed (product name, vendor, etc.)
semantius call crud postgrestRequest '{"method":"GET","path":"/subscriptions?search_vector=wfts(simple).<term>&select=id,subscription_name,status,seat_count,end_date"}'
```

Use `wfts(simple).<term>` for fuzzy text searches, never `ilike` and
never `fts`, they bypass the search index and mismatch the platform
convention. `eq.<value>` is the right tool for known-exact values
(UUIDs, FK ids, status enums, unique columns like `vendor_name` or
`users.email`).

**Recipe:**

```bash
# 1. Resolve the vendor; create one if it does not exist
semantius call crud postgrestRequest '{"method":"GET","path":"/vendors?search_vector=wfts(simple).<term>&select=id,vendor_name"}'
# If empty, create:
semantius call crud postgrestRequest '{
  "method":"POST",
  "path":"/vendors",
  "body":{"vendor_name":"<vendor name>"}
}'

# 2. Resolve the business owner / department / signatory if named
semantius call crud postgrestRequest '{"method":"GET","path":"/users?email=eq.<email>&select=id,full_name,status"}'
semantius call crud postgrestRequest '{"method":"GET","path":"/departments?search_vector=wfts(simple).<term>&select=id,department_name"}'

# 3. Decide the right initial status
#    - pending: contract signed, billing has not started
#    - trialing: in a free/paid trial period
#    - active: start_date is today or earlier and billing has begun
#    Default the model uses on insert is `pending`.

# 4. Create the subscription
semantius call crud postgrestRequest '{
  "method":"POST",
  "path":"/subscriptions",
  "body":{
    "subscription_name":"Slack Business+ -- Engineering",
    "vendor_id":"<vendor id>",
    "billing_cycle":"annual",
    "recurring_amount":24000,
    "start_date":"<today, YYYY-MM-DD>",
    "status":"active",
    "business_owner_id":"<optional user id>",
    "primary_department_id":"<optional department id>",
    "signatory_user_id":"<optional user id>",
    "seat_count":50,
    "unit_price":40,
    "auto_renew":true,
    "category":"communication",
    "criticality":"important",
    "end_date":"<optional, YYYY-MM-DD>",
    "renewal_notice_days":30
  }
}'
```

`start_date`, `end_date`, `signed_date`: provide real dates at call
time; do not copy the placeholders.

**Validation:** the row exists, `vendor_id` resolves to an existing
vendor, `recurring_amount > 0`, and `status` matches the contract
state.

**Failure modes:**
- 409 on `vendors.vendor_name` when creating the vendor -> the vendor
  already exists; re-run step 1 with the exact `vendor_name` and use
  the returned id.
- FK violation on `vendor_id` when POSTing the subscription -> step 1
  did not produce an id; the vendor does not exist. Create it first.
- `end_date < start_date` -> not DB-guarded but semantically wrong;
  ask the user to confirm the dates rather than POSTing.

---

### Cancel a subscription (cascade-revoke licenses)

**Triggers:** `cancel the Slack subscription`, `terminate our Notion contract`, `we are dropping Asana`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `subscription_id` | yes | Resolve via `subscription_name` if the user names the product |
| `effective_end_date` | yes | When billing actually stops; YYYY-MM-DD |
| Reason | no | Free text, goes to `notes` |

**This is a Pattern C cascade.** Cancelling a subscription is not a
single PATCH; it ripples to every active license_assignment on it.
The DB cascades only on **delete**, not on a status flip; without
the cascade your chargeback report will keep billing departments for
seats nobody is using anymore.

**Paired write rule.** `status=cancelled` and `end_date` (the actual
stop date) move together in the same PATCH. If `end_date` is already
set to a future date by the contract, overwrite only if the user
explicitly says cancellation is earlier than the contract end.

**Recipe:**

```bash
# 1. Resolve the subscription and read its current state
semantius call crud postgrestRequest '{"method":"GET","path":"/subscriptions?id=eq.<id>&select=id,subscription_name,status,end_date,seat_count"}'

# 2. Refuse if status is already terminal (`cancelled`, `expired`, `archived`); tell the user.

# 3. Find every active license_assignment so we can revoke them
semantius call crud postgrestRequest '{"method":"GET","path":"/license_assignments?subscription_id=eq.<id>&status=eq.active&select=id,user_id,assignment_label"}'

# 4. Flip the subscription
semantius call crud postgrestRequest '{
  "method":"PATCH","path":"/subscriptions?id=eq.<id>",
  "body":{
    "status":"cancelled",
    "end_date":"<effective_end_date, YYYY-MM-DD>",
    "auto_renew":false
  }
}'

# 5. Revoke every active license_assignment in one ranged PATCH
semantius call crud postgrestRequest '{
  "method":"PATCH","path":"/license_assignments?subscription_id=eq.<id>&status=eq.active",
  "body":{
    "status":"revoked",
    "last_active_date":"<today, YYYY-MM-DD>"
  }
}'
```

`effective_end_date`, `last_active_date`: set to real dates at call
time; do not copy the placeholders.

**Validation:** the subscription shows `status=cancelled`, `end_date`
non-null, `auto_renew=false`. A re-read of license_assignments for
this subscription returns zero rows where `status=active`.

**Failure modes:**
- The subscription is already `cancelled` -> do not retry; the
  previous cancellation stands.
- Step 5 PATCH fails after step 4 succeeds -> the subscription is
  cancelled but seats remain marked active. Re-run step 5 with the
  same filter; do not re-PATCH the subscription.
- The user wants the cancellation back-dated past existing
  `last_active_date` values on the assignments -> ask before
  overwriting; you would lose engagement data.

---

### Assign a license to a user

**Triggers:** `assign Bob a license on Figma`, `give Sarah a Slack seat`, `add Alice to GitHub`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `subscription_id` | yes | Resolve via `subscription_name` |
| `user_id` | yes | Resolve via `users.email=eq.<email>` |
| `assigned_date` | no | Defaults to today; set explicitly if back-filling |
| `monthly_cost_allocation` | no | Per-seat chargeback amount in base currency |

**Junction without DB-level uniqueness.** The table does not constrain
`(subscription_id, user_id)`. POSTing the same pair twice creates a
duplicate row that double-counts the seat in chargeback. Read first.

**Seat-count invariant.** `subscriptions.seat_count` is informational,
not enforced. Before creating an active assignment, count existing
active rows; if the new total would exceed `seat_count`, surface the
overage to the user instead of silently going over.

**Caller-populated label.** `license_assignments.assignment_label` is
required on insert and not auto-derived. Compose it as
`"{user.full_name} / {subscription.subscription_name}"`. The recipe
must read both rows in step 1 to have the values.

**Recipe:**

```bash
# 1. Resolve the user, the subscription, and check for an existing assignment in one round
semantius call crud postgrestRequest '{"method":"GET","path":"/users?email=eq.<email>&select=id,full_name,status"}'
semantius call crud postgrestRequest '{"method":"GET","path":"/subscriptions?search_vector=wfts(simple).<term>&select=id,subscription_name,status,seat_count"}'
semantius call crud postgrestRequest '{"method":"GET","path":"/license_assignments?subscription_id=eq.<sub>&user_id=eq.<usr>&select=id,status,assignment_label"}'

# 2. If the existing-assignment read returns a row:
#    - status=active: do nothing; tell the user.
#    - status in (inactive, revoked, pending): re-activate via PATCH (see "Revoke a license" for the inverse shape):
semantius call crud postgrestRequest '{
  "method":"PATCH","path":"/license_assignments?id=eq.<existing id>",
  "body":{"status":"active","assigned_date":"<today, YYYY-MM-DD>","last_active_date":null}
}'

# 3. If no existing row, count the active seats and check the cap
semantius call crud postgrestRequest '{"method":"GET","path":"/license_assignments?subscription_id=eq.<sub>&status=eq.active&select=id"}'
# If the count is already at or above subscriptions.seat_count, surface the overage and ask the user before continuing.

# 4. Refuse if user.status is `offboarded` (active license on an offboarded user is almost always a mistake).
# 5. Refuse if subscription.status is `cancelled`, `expired`, `deprecated`, or `archived`.

# 6. Create
semantius call crud postgrestRequest '{
  "method":"POST",
  "path":"/license_assignments",
  "body":{
    "assignment_label":"<user.full_name> / <subscription.subscription_name>",
    "subscription_id":"<sub id>",
    "user_id":"<user id>",
    "assigned_date":"<today, YYYY-MM-DD>",
    "status":"active",
    "monthly_cost_allocation":40
  }
}'
```

`assigned_date`: set at call time; do not copy the placeholder.

**Validation:** exactly one row exists for the
`(subscription_id, user_id)` pair, `status=active`,
`assignment_label` matches the "user / subscription" composition.

**Failure modes:**
- A POST without the read-first -> the table accepts a duplicate.
  Recover by PATCH-ing one of the duplicates to `status=revoked`
  (audit-friendly cleanup).
- The user being assigned is not in `users` yet -> create the user
  first via `use-semantius`; do not invent a fake id.
- The subscription is over-seated already -> ask the user whether to
  raise `seat_count` first, revoke an existing assignment, or skip;
  do not just silently exceed the cap.

---

### Revoke a license assignment

**Triggers:** `revoke Alice's GitHub seat`, `take Bob off Figma`, `remove this license`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `assignment_id` | yes | Resolve via `(user, subscription)` if the user names them |
| `last_active_date` | yes | Set to today on a fresh revoke; preserve the existing value if the user is just bookkeeping a known stale row |

**Paired write rule.** `status=revoked` and `last_active_date` move
together. The `last_active_date` field powers the unused-license
report; setting `status=revoked` without it leaves the report blind
to when the seat actually stopped being used.

**Recipe:**

```bash
# 1. Resolve the assignment if needed
semantius call crud postgrestRequest '{"method":"GET","path":"/license_assignments?subscription_id=eq.<sub>&user_id=eq.<usr>&select=id,status,assignment_label,last_active_date"}'

# 2. Revoke
semantius call crud postgrestRequest '{
  "method":"PATCH","path":"/license_assignments?id=eq.<id>",
  "body":{
    "status":"revoked",
    "last_active_date":"<today, YYYY-MM-DD>"
  }
}'
```

`last_active_date`: set at call time; do not copy the placeholder.

**Soft path: deactivate, do not delete.** Prefer
`status=revoked` (or `status=inactive` for a temporary pause) over a
DELETE. Deleting drops the chargeback history; revoking preserves it.

**Validation:** the row shows `status=revoked` and `last_active_date`
non-null.

**Failure modes:**
- The row is already `revoked` -> no-op; tell the user.
- DELETE used instead of PATCH -> chargeback history for past months
  is lost; not recoverable from this skill. Use PATCH next time.

---

### Offboard a user (cascade-revoke licenses, clear ownership)

**Triggers:** `offboard Sarah and revoke her licenses`, `Mark left, clean up his accounts`, `terminate user X`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `user_id` | yes | Resolve via `email=eq.<email>` |
| `effective_date` | yes | When access stops; YYYY-MM-DD |

**This is a Pattern C cascade.** Offboarding is not a single PATCH;
it ripples across three tables:

1. `license_assignments`: every active row for this user flips to
   `revoked` with `last_active_date` set.
2. `subscriptions`: the FKs `business_owner_id` and `signatory_user_id`
   delete-mode is `clear`, so the database silently nulls them on a
   user **delete**, not on offboarding. While the user record is kept
   (offboarding is a status flip, not a delete), surface every
   subscription where this user is owner or signatory so the user can
   reassign. Do not auto-clear ownership; that is a reassignment
   decision, not a cleanup.
3. `users`: flip `status` to `offboarded`.

**Recipe:**

```bash
# 1. Resolve the user
semantius call crud postgrestRequest '{"method":"GET","path":"/users?email=eq.<email>&select=id,full_name,status,department_id"}'

# 2. Revoke every active license assignment in one ranged PATCH
semantius call crud postgrestRequest '{
  "method":"PATCH","path":"/license_assignments?user_id=eq.<id>&status=eq.active",
  "body":{
    "status":"revoked",
    "last_active_date":"<effective_date, YYYY-MM-DD>"
  }
}'

# 3. Surface ownership the user holds so the operator can reassign
semantius call crud postgrestRequest '{"method":"GET","path":"/subscriptions?or=(business_owner_id.eq.<id>,signatory_user_id.eq.<id>)&select=id,subscription_name,business_owner_id,signatory_user_id"}'
# Present the list to the user and ask who should take over each subscription; PATCH owner/signatory per their answer.

# 4. Surface departments the user manages
semantius call crud postgrestRequest '{"method":"GET","path":"/departments?manager_user_id=eq.<id>&select=id,department_name"}'
# Same: ask before clearing or reassigning.

# 5. Flip the user to offboarded
semantius call crud postgrestRequest '{
  "method":"PATCH","path":"/users?id=eq.<id>",
  "body":{"status":"offboarded"}
}'
```

`effective_date`: set to a real date at call time; do not copy the
placeholder.

**Validation:** the user shows `status=offboarded`; a re-read of
license_assignments for this user returns zero rows where
`status=active`; every subscription previously owned or signed by the
user has been reassigned (or the operator has explicitly said "leave
empty for now", in which case PATCH them to null).

**Failure modes:**
- Step 2 PATCH fails after the user is offboarded in step 5 -> seats
  remain marked active for an offboarded user; chargeback keeps
  billing. Re-run step 2 with the same filter.
- The operator skips the ownership surface in steps 3-4 -> a
  cancelled subscription a year later has nobody to ask "should we
  renew"; the cleanup is then manual. Always run the surface reads,
  even if the user wants to skip.
- The user is referenced as `signatory_user_id` on a `pending` or
  `active` contract that has not yet started billing -> the
  signatory matters legally, not operationally; ask whether to
  reassign or leave as a historical record.

---

### Add a budget line to a budget period

**Triggers:** `create a budget line for engineering dev tools`, `allocate $100k to marketing software for FY2026`, `add a budget line for the Slack subscription`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `budget_period_id` | yes | Resolve via `period_name=eq.<name>` |
| `planned_amount` | yes | Base currency |
| `department_id` | no | Allocates the line to a department |
| `subscription_id` | no | Forecasts the line against a specific subscription; leave null for category-level allocation |
| `category` | no | Pick from `subscriptions.category` plus `unallocated` |
| `notes` | no | Free text |

**Period-status invariant.** `budget_lines.budget_period_id` has a
`parent` cascade FK, so the database does not stop you from inserting
into a `closed` or `archived` period. Operationally, lines should
only be added when the period is `draft` or `open`. Read the period
status first.

**Caller-populated label.** `budget_lines.budget_line_name` is
required on insert and not auto-derived. Compose it as
`"{department.department_name} -- {category} -- {budget_period.period_name}"`,
e.g. `"Engineering -- dev_tools -- FY2026"`. If `department_id` is
null, drop that segment; if `category` is null, drop that segment.

**Category-source rule.** `budget_lines.category` is its own enum
that mostly mirrors `subscriptions.category` but also has
`unallocated`. When the user names a category, validate against
**`budget_lines.category`**, not `subscriptions.category`; the
divergence is real.

**Recipe:**

```bash
# 1. Resolve the period and read its status
semantius call crud postgrestRequest '{"method":"GET","path":"/budget_periods?period_name=eq.<name>&select=id,period_name,status,start_date,end_date"}'

# 2. Refuse if period.status is `closed` or `archived`; tell the user the period is locked.

# 3. Resolve the department and (optionally) subscription so you can compose the label
semantius call crud postgrestRequest '{"method":"GET","path":"/departments?search_vector=wfts(simple).<term>&select=id,department_name,status"}'
semantius call crud postgrestRequest '{"method":"GET","path":"/subscriptions?search_vector=wfts(simple).<term>&select=id,subscription_name"}'

# 4. Create the line
semantius call crud postgrestRequest '{
  "method":"POST",
  "path":"/budget_lines",
  "body":{
    "budget_line_name":"Engineering -- dev_tools -- FY2026",
    "budget_period_id":"<period id>",
    "department_id":"<dept id, optional>",
    "subscription_id":"<sub id, optional>",
    "category":"dev_tools",
    "planned_amount":120000,
    "notes":"<optional>"
  }
}'
```

**Validation:** the row exists, `budget_period_id` points at a
`draft` or `open` period, `planned_amount > 0`, `budget_line_name`
follows the composition rule.

**Failure modes:**
- Adding a line to a `closed` or `archived` period -> the DB accepts
  it, but it pollutes locked-period reporting. Recover by DELETE-ing
  the offending line or, if the period must accept more, ask the
  user to reopen the period (single PATCH to `status=open`) and
  re-add cleanly.
- Picking a `category` value that exists on `subscriptions.category`
  but not on `budget_lines.category` (or vice versa) -> the platform
  will reject it. The two enums share most values plus `unallocated`
  on the budget side; refer to "Key enums" above.

---

### Renew a subscription

**Triggers:** `renew the Notion subscription`, `we are extending Slack for another year`, `the auto-renew kicked in for Figma`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `subscription_id` | yes | Resolve via `subscription_name` |
| New `end_date` | yes | YYYY-MM-DD; the new term-end |
| New `recurring_amount` | no | Only if pricing changed |
| New `seat_count`, `unit_price`, `payment_terms`, `total_contract_value` | no | Only if the renewal contract changed them |

**Renewal style.** The model says a subscription is "superseded when
renewed", which leaves room for two patterns. Pick the right one by
asking the user (or inferring from the magnitude of change):

- **Same row, extended dates** -- when nothing material changed
  except the term. PATCH the existing row to push out `end_date`,
  reset `signed_date`, optionally update `recurring_amount`.
- **New row, archive the old** -- when seat count, pricing, or
  contract structure materially changed and the operator wants the
  old terms preserved for historical chargeback. POST a fresh
  subscription with the new terms; PATCH the old one to
  `status=archived` once the new one is `active`. The model has no
  back-pointer between predecessor and successor, so record the
  link in the new row's `notes` ("supersedes <old subscription_name>")
  to keep the chain readable.

**Recipe (extend in place):**

```bash
# 1. Read the current state
semantius call crud postgrestRequest '{"method":"GET","path":"/subscriptions?id=eq.<id>&select=id,subscription_name,status,end_date,recurring_amount,seat_count,auto_renew"}'

# 2. Refuse if status is terminal (`cancelled`, `expired`, `archived`); a renewal of a cancelled contract is a new subscription, not a renewal.

# 3. PATCH the new term
semantius call crud postgrestRequest '{
  "method":"PATCH","path":"/subscriptions?id=eq.<id>",
  "body":{
    "status":"active",
    "end_date":"<new end date, YYYY-MM-DD>",
    "signed_date":"<today, YYYY-MM-DD>",
    "recurring_amount":24000,
    "auto_renew":true
  }
}'
```

**Recipe (supersede with a new row):**

```bash
# 1. Read the current row so you can copy the unchanged fields
semantius call crud postgrestRequest '{"method":"GET","path":"/subscriptions?id=eq.<id>&select=*"}'

# 2. POST the new subscription (use "Add a SaaS subscription" recipe; copy vendor_id, primary_department_id, business_owner_id, signatory_user_id, category, criticality unchanged)
# Set status=active, start_date=<today>, recurring_amount/seat_count to the new contract values.
# Add a notes line: "supersedes <old subscription_name>".

# 3. After the new row is verified `active`, archive the old one
semantius call crud postgrestRequest '{
  "method":"PATCH","path":"/subscriptions?id=eq.<old id>",
  "body":{
    "status":"archived",
    "end_date":"<yesterday, YYYY-MM-DD>",
    "auto_renew":false
  }
}'
```

`end_date`, `signed_date`, `start_date`: set to real dates at call
time; do not copy the placeholders.

**License assignments under supersede.** When the old row is
archived, its license_assignments do **not** auto-move to the new
row (no cascade between siblings). For each currently-active
license_assignment on the old subscription, the operator must POST
an equivalent assignment on the new subscription before archiving
the old one. Surface this list to the user before step 3.

**Validation (extend):** the row shows `status=active`, `end_date`
extended past its previous value, `signed_date` updated.
**Validation (supersede):** the new row exists with `status=active`;
the old row shows `status=archived`; license assignments have been
re-pointed.

**Failure modes:**
- Extending in place on a status that was already `expired` -> the
  PATCH will succeed but the row's history is wrong; the contract
  lapsed and was re-signed, which is a new contract. Use supersede.
- Supersede without re-pointing license_assignments -> the new
  subscription shows zero seats consumed; chargeback is wrong.
  Recover by POSTing the missing assignments before the user
  notices the discrepancy.
- Supersede by deleting the old row instead of archiving -> the
  cascade drops every historical license_assignment. Never DELETE a
  subscription that has run for more than a day; archive it.

---

## Common queries

These are starting points, not contracts. Cube schema names drift
when the model is regenerated, so always run `cube discover '{}'`
first and map the dimension and measure names below against
`discover`'s output. The cube name is usually the entity's table name
with the first letter capitalized (e.g. `Subscriptions`,
`LicenseAssignments`, `BudgetLines`), but verify.

```bash
# Always first
semantius call cube discover '{}'
```

```bash
# SaaS spend by department, current period
# (recurring_amount summed; for true period spend you would normalize by billing_cycle, but this is the quick view)
semantius call cube load '{"query":{
  "measures":["Subscriptions.sum_recurring_amount"],
  "dimensions":["Departments.department_name","Subscriptions.billing_cycle"],
  "filters":[{"member":"Subscriptions.status","operator":"equals","values":["active","trialing"]}],
  "order":{"Subscriptions.sum_recurring_amount":"desc"}
}}'
```

```bash
# Upcoming renewals in the next 90 days
semantius call cube load '{"query":{
  "measures":["Subscriptions.count","Subscriptions.sum_recurring_amount"],
  "dimensions":["Subscriptions.subscription_name","Subscriptions.end_date","Vendors.vendor_name","Subscriptions.auto_renew"],
  "filters":[
    {"member":"Subscriptions.status","operator":"equals","values":["active","trialing"]}
  ],
  "timeDimensions":[{"dimension":"Subscriptions.end_date","dateRange":"next 90 days"}],
  "order":{"Subscriptions.end_date":"asc"}
}}'
```

```bash
# Unused-license report: active assignments whose last_active_date is older than 60 days
# (or null, depending on what your loaders set on idle accounts)
semantius call cube load '{"query":{
  "measures":["LicenseAssignments.count","LicenseAssignments.sum_monthly_cost_allocation"],
  "dimensions":["Subscriptions.subscription_name","Users.full_name","Departments.department_name","LicenseAssignments.last_active_date"],
  "filters":[
    {"member":"LicenseAssignments.status","operator":"equals","values":["active"]},
    {"member":"LicenseAssignments.last_active_date","operator":"beforeDate","values":["<today minus 60 days, YYYY-MM-DD>"]}
  ],
  "order":{"LicenseAssignments.sum_monthly_cost_allocation":"desc"}
}}'
```

`<today minus 60 days, YYYY-MM-DD>`: compute at call time; do not
copy the placeholder.

```bash
# Budget vs expected for a period (planned_amount from budget_lines, expected from subscriptions)
# Two cube reads, joined by department + category in the calling agent;
# a single query is hard because the two sides have different time semantics.
semantius call cube load '{"query":{
  "measures":["BudgetLines.sum_planned_amount"],
  "dimensions":["Departments.department_name","BudgetLines.category"],
  "filters":[{"member":"BudgetPeriods.period_name","operator":"equals","values":["FY2026"]}]
}}'
semantius call cube load '{"query":{
  "measures":["Subscriptions.sum_recurring_amount"],
  "dimensions":["Departments.department_name","Subscriptions.category"],
  "filters":[{"member":"Subscriptions.status","operator":"equals","values":["active","trialing"]}]
}}'
```

```bash
# Top vendors by total spend
semantius call cube load '{"query":{
  "measures":["Subscriptions.count","Subscriptions.sum_recurring_amount"],
  "dimensions":["Vendors.vendor_name"],
  "filters":[{"member":"Subscriptions.status","operator":"equals","values":["active","trialing"]}],
  "order":{"Subscriptions.sum_recurring_amount":"desc"},
  "limit":20
}}'
```

---

## Guardrails

- Never PATCH `subscriptions.status` to `cancelled` without setting
  `end_date` in the same call; chargeback reports drift if the stop
  date is missing.
- Never cancel a subscription without revoking its active
  license_assignments in the same operation; the cascade is
  client-side, not DB-managed.
- Never POST to `license_assignments` for a `(subscription_id, user_id)`
  pair that already has an `active` row; reactivate via PATCH if a
  prior `inactive`/`revoked` row exists.
- Never POST an active license_assignment on a subscription whose
  status is `cancelled`, `expired`, `deprecated`, or `archived`, or
  on a user whose status is `offboarded`; refuse and surface the
  conflict.
- Never set `license_assignments.status=revoked` without
  `last_active_date` in the same call; the unused-license report
  goes blind.
- Never DELETE a license_assignment that has run for more than a day;
  PATCH to `status=revoked` to preserve chargeback history.
- Never DELETE a subscription that has run for more than a day; the
  cascade drops historical license_assignments. Use
  `status=archived`.
- Never add a `budget_line` to a `closed` or `archived`
  `budget_period`; the period is locked operationally even though
  the DB allows it.
- When validating a `budget_lines.category`, use the
  `budget_lines.category` enum (it includes `unallocated`), not
  `subscriptions.category`.
- When offboarding a user, surface every subscription they own or
  signed before flipping `users.status=offboarded`; do not
  auto-clear ownership.
- Lookups for human-friendly identifiers (vendor names, subscription
  names, department names, period names) use
  `search_vector=wfts(simple).<term>`; never `ilike` and never `fts`.
  `eq.<value>` is for known-exact values (UUIDs, FK ids, status
  enums, `vendor_name`, `users.email`, `period_name`,
  `department_code`).
- `users` exists as a Semantius built-in in this deployment; treat
  it as the authoritative table and reference it rather than
  creating a parallel one.

## What this skill does NOT do

- Schema changes, use `use-semantius` directly.
- RBAC / permissions, use `use-semantius` directly.
- One-off seed data, write a script, do not bake it into a JTBD.
- Multi-currency reporting: every monetary field is stored in a
  single implicit base currency; an FX layer would need a
  `currency` column on every money-bearing record plus an
  `exchange_rates` entity.
- Invoice / AP-level tracking: no `invoices` or `invoice_line_items`
  exist; "expected" spend is computed from
  `subscriptions.recurring_amount` x cadence, not from received
  bills, so paid-vs-due, dispute handling, and line-level
  allocations are out of scope.
- Multi-product master agreements: contract fields
  (`contract_number`, `signed_date`, `document_url`,
  `total_contract_value`, `renewal_notice_days`,
  `negotiated_savings`) live on the subscription row, not in a
  separate `contracts` entity, so an MSA covering several
  subscriptions cannot be modeled cleanly.
- Product-versus-terms split: a single `subscriptions` record
  carries both the product identity and the commercial terms; there
  is no `saas_applications` entity, so product-level reporting
  without double-counting is not available.
- Approval workflows: no `approval_requests` or `purchase_orders`;
  purchase, renewal, and budget-change approvals are not tracked
  here.
- Detailed engagement analytics: only
  `license_assignments.last_active_date` exists for unused-license
  detection; per-user activity logs and feature adoption need a
  dedicated event entity that is not modeled.
- Shared category lookup: `subscriptions.category` and
  `budget_lines.category` are independent enums (the latter has
  `unallocated`), so renaming or adding a category requires
  changing both enums until they are promoted to a lookup table.
