---
name: equipment-lease-management
description: >-
  Use this skill for anything involving Equipment Lease Management,
  the in-house lessee-side system that tracks lease contracts with
  vendors, the assets they cover, the planned and actual payment
  streams they generate, and the budgets those payments are measured
  against. Trigger when the user says: "add a new lease contract",
  "register the new copier lease", "add the laptops covered by this
  contract", "generate the payment schedule for this lease",
  "record the March payment for contract LC-2026-0042", "terminate
  this lease early", "renew the vehicle lease", "retire this asset",
  "decommission the printer", "add a budget line for IT hardware in
  Q1", "approve the FY2026 leasing budget", "what is our total lease
  obligation next quarter", "which contracts are over budget", "show
  upcoming contract renewals", "show overdue payments". Loads
  alongside `use-semantius`, which owns CLI install, PostgREST
  encoding, and cube query mechanics.
semantic_model: equipment_lease_management
---

# Equipment Lease Management

This skill carries the domain map and the jobs-to-be-done for
Equipment Lease Management. Platform mechanics, CLI install, env
vars, PostgREST URL-encoding, `sqlToRest`, cube
`discover`/`validate`/`load`, and schema-management tools, live in
`use-semantius`. Assume it loads alongside; do not re-explain CLI
basics here.

If a task is purely about defining schema, managing permissions, or
running ad-hoc queries against tables you already know, call
`use-semantius` directly, going through this skill adds nothing.

**Auto-managed fields** (set by Semantius on every table; never include
in POST/PATCH bodies): `id`, `created_at`, `updated_at`. Every other
required field, including the caller-populated label columns
`payment_schedules.schedule_reference` and
`budget_lines.budget_line_label`, is **caller-populated** and must
appear in the POST body. The composition rule for each appears in
its JTBD below. The other label columns in this model
(`vendor_name`, `category_name`, `location_name`, `cost_center_name`,
`full_name`, `contract_number`, `asset_tag`, `payment_reference`,
`period_name`) are natural fields the user supplies directly, also
required on create.

**Currency.** Every monetary field carries an explicit `currency_code`
(ISO 4217). The platform does not convert between currencies and
does not snapshot FX rates; rolling up across currencies is a
reporting-time concern handled by the calling agent.

**Bulk import.** No webhook receivers are declared for this model.
For CSV import of vendors, contracts, assets, schedules, payments,
or budget lines, see `use-semantius` `references/webhook-import.md`.

---

## Domain glossary

The model splits cleanly into a **contract spine**
(Vendor -> Lease Contract -> Leased Asset, with payment_schedules
fanning out from the contract and lease_payments settling each
schedule) and a **budget spine** (Cost Center + Fiscal Period ->
Budget Line, optionally sliced by Equipment Category).

| Concept | Table | Notes |
|---|---|---|
| Vendor | `vendors` | Lessor company; `vendor_code` is unique |
| Equipment Category | `equipment_categories` | Classification bucket (IT hardware, vehicles, copiers, machinery); `category_name` is unique |
| Location | `locations` | Physical site where assets live; `location_code` is unique |
| Cost Center | `cost_centers` | Internal org unit charged for lease cost; `cost_center_code` is unique |
| User | `users` | Employee owner / approver / signatory; deduped against the Semantius built-in `users` table |
| Lease Contract | `lease_contracts` | Master legal agreement with one vendor; one contract owns many assets and many payment schedules |
| Leased Asset | `leased_assets` | Individual piece of equipment under a contract; `asset_tag` and `serial_number` are unique |
| Payment Schedule | `payment_schedules` | One planned payment obligation generated from contract terms; the set of schedules is the contract's full cash plan |
| Lease Payment | `lease_payments` | Actual payment posted/invoiced against one schedule row; `payment_reference` is unique |
| Fiscal Period | `fiscal_periods` | Budget calendar unit; `period_name` is unique; `is_closed` blocks budget-line edits operationally |
| Budget Line | `budget_lines` | Planned spend for a (cost_center, fiscal_period, optional category) tuple |

## Key enums

Only the enums that gate JTBDs are listed; full enum sets live in the
semantic model. Arrows mark the typical lifecycle path; `|` separates
terminal states.

- `lease_contracts.contract_status`: `draft` -> `active` -> `expired` | `terminated` | `renewed`
- `lease_contracts.lease_type`: `operating`, `finance`, `short_term` (ASC 842 classification)
- `lease_contracts.payment_frequency`: `monthly`, `quarterly`, `semi_annual`, `annual`
- `payment_schedules.schedule_status`: `pending` -> `invoiced` -> `paid` | `overdue` | `waived`
- `lease_payments.payment_method`: `ach`, `wire`, `check`, `credit_card`, `other`
- `leased_assets.condition_status`: `new` -> `good` -> `fair` -> `poor` -> `retired`
- `budget_lines.budget_status`: `draft` -> `approved` -> `locked`
- `fiscal_periods.period_type`: `month`, `quarter`, `half_year`, `year`
- `vendors.vendor_status`, `cost_centers.cost_center_status`, `users.user_status`: `active` | `inactive` (informational; do not gate writes)

## Foreign-key cheatsheet

Only the FKs that JTBDs cross. Format: `child.field -> parent.id`
(delete behavior in parens).

- `lease_contracts.vendor_id -> vendors.id` (**restrict**)
- `lease_contracts.primary_cost_center_id -> cost_centers.id` (**restrict**)
- `lease_contracts.contract_owner_id -> users.id` (**restrict**)
- `leased_assets.lease_contract_id -> lease_contracts.id` (**parent, cascade**: deleting a contract drops every asset)
- `leased_assets.equipment_category_id -> equipment_categories.id` (restrict)
- `leased_assets.location_id -> locations.id` (clear)
- `leased_assets.deployed_to_user_id -> users.id` (clear)
- `payment_schedules.lease_contract_id -> lease_contracts.id` (**parent, cascade**: deleting a contract drops every schedule, which then breaks any `lease_payments` that referenced them)
- `payment_schedules.fiscal_period_id -> fiscal_periods.id` (clear)
- `lease_payments.payment_schedule_id -> payment_schedules.id` (**restrict**: a schedule cannot be deleted while payments reference it)
- `lease_payments.approved_by_user_id -> users.id` (clear)
- `budget_lines.cost_center_id -> cost_centers.id` (restrict)
- `budget_lines.fiscal_period_id -> fiscal_periods.id` (restrict)
- `budget_lines.equipment_category_id -> equipment_categories.id` (clear)
- `budget_lines.approved_by_user_id -> users.id` (clear)

**Unique columns** (409 on duplicate POST): `vendors.vendor_code`,
`equipment_categories.category_name`, `locations.location_code`,
`cost_centers.cost_center_code`, `users.email`, `users.employee_id`,
`lease_contracts.contract_number`, `leased_assets.asset_tag`,
`leased_assets.serial_number`, `lease_payments.payment_reference`,
`fiscal_periods.period_name`.

**No DB-level composite uniqueness on `budget_lines`.** The tuple
`(cost_center_id, fiscal_period_id, equipment_category_id)` is
expected to be unique but is enforced only in application logic.
Recipes must read first.

**No DB-level cap or balance check between schedules and payments.**
The DB does not stop you from posting a `lease_payment` whose
`payment_amount` differs from the matching
`payment_schedules.scheduled_amount`, or from posting two payments
against the same schedule. The recipe must reconcile.

**Built-in `users` table.** This deployment treats Semantius's
built-in `users` as authoritative. Do not POST to a parallel `users`
table; reference the built-in for `lease_contracts.contract_owner_id`,
`leased_assets.deployed_to_user_id`,
`lease_payments.approved_by_user_id`,
`budget_lines.approved_by_user_id`,
`locations.site_manager_id`, and `cost_centers.manager_id`.

This model declares no `audit_log: true` flags, so no entity has a
managed audit trail. Treat `updated_at` as the only built-in change
indicator and recommend `use-semantius` directly when the user asks
"who changed X" (the answer is "we don't record that here").

---

## Jobs to be done

### Add a lease contract

**Triggers:** `add a new lease contract`, `register the new copier lease`, `we just signed a vehicle lease with X`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `contract_number` | yes | Unique; format like `LC-2026-0042` |
| `vendor_id` | yes | Resolve via `vendor_name` or `vendor_code`; create the vendor first if it does not exist |
| `primary_cost_center_id` | yes | Resolve via `cost_center_code` |
| `contract_owner_id` | yes | Resolve via `users.email` |
| `lease_type` | yes | `operating`, `finance`, or `short_term` (ASC 842 classification; ask the user if unclear) |
| `commencement_date`, `end_date`, `term_months` | yes | All three are required; verify `end_date - commencement_date` lines up with `term_months` |
| `currency_code` | yes | ISO 4217 (e.g. `USD`); used by every monetary field on this contract and its schedules/payments |
| `payment_frequency` | yes | `monthly`, `quarterly`, `semi_annual`, `annual` |
| `auto_renewal` | yes | Boolean |
| `contract_status` | yes | `draft` while terms are being finalized; `active` once signed and commenced |
| `contract_title`, `monthly_payment_amount`, `total_contract_value`, `renewal_notice_days`, `signed_date`, `notes` | no | Fill if the user named them |

If the user names a vendor that does not yet exist, create the vendor
first (single POST to `/vendors`) and reuse the new id. Same for
cost_center and equipment_category if they come up.

**Lookup convention.** Semantius adds a `search_vector` column to
searchable entities for full-text search across all text fields. Use
it whenever the user passes a name, title, or description, not a
UUID:

```bash
# Resolve a vendor by anything the user typed
semantius call crud postgrestRequest '{"method":"GET","path":"/vendors?search_vector=wfts(simple).<term>&select=id,vendor_name,vendor_code,vendor_status"}'

# Resolve a contract by number, title, or vendor
semantius call crud postgrestRequest '{"method":"GET","path":"/lease_contracts?search_vector=wfts(simple).<term>&select=id,contract_number,contract_title,contract_status,end_date"}'
```

Use `wfts(simple).<term>` for fuzzy text searches, never `ilike` and
never `fts`, they bypass the search index and mismatch the platform
convention. `eq.<value>` is the right tool for known-exact values
(UUIDs, FK ids, status enums, unique columns like `vendor_code`,
`contract_number`, `users.email`, `period_name`,
`cost_center_code`).

**Status guidance.** `draft` is the right status while the contract
is being negotiated and assets/schedules have not yet been finalized.
Flip to `active` only when `commencement_date` has been reached (or
is today) and the contract has been signed. Adding leased_assets and
generating payment_schedules can happen against either `draft` or
`active`.

**Recipe:**

```bash
# 1. Resolve the vendor; create if missing
semantius call crud postgrestRequest '{"method":"GET","path":"/vendors?search_vector=wfts(simple).<term>&select=id,vendor_name,vendor_code"}'
# If empty:
semantius call crud postgrestRequest '{
  "method":"POST",
  "path":"/vendors",
  "body":{"vendor_name":"<vendor name>","vendor_code":"<code>","vendor_status":"active"}
}'

# 2. Resolve the cost_center and contract owner
semantius call crud postgrestRequest '{"method":"GET","path":"/cost_centers?cost_center_code=eq.<code>&select=id,cost_center_name,cost_center_status"}'
semantius call crud postgrestRequest '{"method":"GET","path":"/users?email=eq.<email>&select=id,full_name,user_status"}'

# 3. Validate term_months matches the date span (ask the user if the math does not line up)

# 4. Create the contract
semantius call crud postgrestRequest '{
  "method":"POST",
  "path":"/lease_contracts",
  "body":{
    "contract_number":"LC-2026-0042",
    "contract_title":"IT fleet refresh 2026",
    "vendor_id":"<vendor id>",
    "primary_cost_center_id":"<cost_center id>",
    "contract_owner_id":"<owner id>",
    "contract_status":"draft",
    "lease_type":"operating",
    "commencement_date":"<commencement date, YYYY-MM-DD>",
    "end_date":"<end date, YYYY-MM-DD>",
    "term_months":36,
    "currency_code":"USD",
    "monthly_payment_amount":2500,
    "total_contract_value":90000,
    "payment_frequency":"monthly",
    "auto_renewal":false,
    "renewal_notice_days":60,
    "signed_date":"<signed date, YYYY-MM-DD>"
  }
}'
```

`commencement_date`, `end_date`, `signed_date`: provide real dates at
call time; do not copy the placeholder values.

**Validation:** the row exists; `vendor_id`, `primary_cost_center_id`,
and `contract_owner_id` resolve; `term_months` is consistent with
`(end_date - commencement_date)`; `total_contract_value` is roughly
consistent with `monthly_payment_amount * term_months` (off by one
period on advance vs arrears is fine).

**Failure modes:**
- 409 on `contract_number` -> a contract with that number already
  exists; tell the user and ask whether this is a duplicate import
  or a renumbering. Do not silently increment.
- FK violation on `vendor_id` / `primary_cost_center_id` /
  `contract_owner_id` -> step 1 / 2 did not produce an id. Re-resolve
  before retrying.
- `term_months` not consistent with the date span -> not DB-guarded;
  ask the user which value is authoritative rather than guessing.

---

### Add leased assets to a contract

**Triggers:** `add the laptops covered by this contract`, `register the leased copier`, `the contract covers 12 vehicles, add them`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `lease_contract_id` | yes | Parent FK; resolve via `contract_number` |
| `asset_tag` | yes | Unique; the operator's internal tag (e.g. `IT-LAP-0421`) |
| `asset_description` | yes | Plain string, e.g. `"MacBook Pro 14, M3 Pro, 18GB"` |
| `equipment_category_id` | yes | Resolve via `category_name`; create the category first if missing |
| `condition_status` | yes | Usually `new` for a fresh lease |
| `location_id`, `deployed_to_user_id`, `manufacturer`, `model`, `serial_number`, `acquisition_cost`, `monthly_rent_amount`, `notes` | no | Fill if the user named them; `serial_number` is unique |

**Cascade-on-delete warning.** `leased_assets.lease_contract_id` is a
**parent** FK with cascade delete: removing the contract drops every
asset. This is rarely what the operator wants once a contract has
gone live; use the terminate-contract or supersede flows instead of
DELETE.

**Bulk add.** When the user names many assets in one go, POST them
as an array body in a single call; PostgREST accepts a JSON array.

**Recipe:**

```bash
# 1. Resolve the contract and check status
semantius call crud postgrestRequest '{"method":"GET","path":"/lease_contracts?contract_number=eq.<number>&select=id,contract_status,commencement_date,end_date"}'

# 2. Refuse if contract_status is `expired`, `terminated`, or `renewed`. Adding assets to a closed contract is almost always a mistake; tell the user.

# 3. Resolve the equipment_category (and location / deployed-to user if named)
semantius call crud postgrestRequest '{"method":"GET","path":"/equipment_categories?category_name=eq.<name>&select=id,category_name"}'
# If empty:
semantius call crud postgrestRequest '{
  "method":"POST","path":"/equipment_categories",
  "body":{"category_name":"<name>","description":"<optional>"}
}'

# 4. Insert one or many assets (array body for bulk)
semantius call crud postgrestRequest '{
  "method":"POST",
  "path":"/leased_assets",
  "body":[
    {
      "asset_tag":"IT-LAP-0421",
      "asset_description":"MacBook Pro 14, M3 Pro, 18GB",
      "lease_contract_id":"<contract id>",
      "equipment_category_id":"<category id>",
      "condition_status":"new",
      "location_id":"<optional location id>",
      "deployed_to_user_id":"<optional user id>",
      "manufacturer":"Apple",
      "model":"MacBook Pro 14 M3 Pro",
      "serial_number":"C02XX0YYZZ",
      "acquisition_cost":2500,
      "monthly_rent_amount":75
    }
  ]
}'
```

**Validation:** every row exists; `lease_contract_id` resolves to a
non-terminal contract; `serial_number` values, where supplied, are
unique across `leased_assets`.

**Failure modes:**
- 409 on `asset_tag` -> the tag is already in use; ask the user for a
  fresh tag rather than overwriting.
- 409 on `serial_number` -> a duplicate serial means the same
  physical asset is already on another contract; ask the user before
  registering it again.
- FK violation on `lease_contract_id` -> the contract was not
  resolved or has been deleted; re-resolve before retrying.

---

### Generate payment schedules for a contract

**Triggers:** `generate the payment schedule for this lease`, `build out the monthly payments for contract LC-2026-0042`, `create the schedule rows`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `lease_contract_id` | yes | Resolve via `contract_number` |
| Anchor amount | yes | Read from contract: `monthly_payment_amount` x cadence implied by `payment_frequency`; ask if missing |
| Anchor date | yes | Read from contract: `commencement_date`; first payment date is usually that day or the first of the next cycle, ask if unclear |

**Pattern C materialization.** The platform does not auto-generate
schedule rows from a contract. Each row in `payment_schedules` is a
caller-driven POST; the set of rows for a contract is the contract's
full planned cash-out across the term.

**Caller-populated label.** `payment_schedules.schedule_reference` is
required on insert and not auto-derived. Compose it as
`"{contract_number} / {period_name}"` when the schedule rolls into a
fiscal_period (e.g. `"LC-2026-0042 / 2026-03"`), or
`"{contract_number} / payment {payment_number}"` when no fiscal
period is named. The recipe must read the contract row in step 1 to
have `contract_number`, and resolve fiscal_periods in step 2 if you
are tagging them.

**Schedule arithmetic.** Number of rows = `term_months` divided by
the cadence implied by `payment_frequency`:

| `payment_frequency` | Months per payment | Rows for `term_months=36` |
|---|---|---|
| `monthly` | 1 | 36 |
| `quarterly` | 3 | 12 |
| `semi_annual` | 6 | 6 |
| `annual` | 12 | 3 |

`payment_number` is 1-based and runs to the row count. `scheduled_date`
walks forward from `commencement_date` by the cadence.
`scheduled_amount` is `total_contract_value / row_count` if the user
gave a TCV, otherwise `monthly_payment_amount * months_per_payment`.

**Bulk insert.** POST the full set as a JSON array in one call; do not
loop. The platform accepts hundreds of rows in a single body.

**Recipe:**

```bash
# 1. Read the contract anchor values
semantius call crud postgrestRequest '{"method":"GET","path":"/lease_contracts?contract_number=eq.<number>&select=id,contract_number,commencement_date,end_date,term_months,payment_frequency,monthly_payment_amount,total_contract_value,currency_code"}'

# 2. Optionally resolve the fiscal_periods that each scheduled_date falls in (loop or batch by date range)
semantius call crud postgrestRequest '{"method":"GET","path":"/fiscal_periods?period_type=eq.month&start_date=lte.<scheduled_date>&end_date=gte.<scheduled_date>&select=id,period_name,start_date,end_date"}'

# 3. Refuse if any schedule rows already exist for this contract (avoid double-generation)
semantius call crud postgrestRequest '{"method":"GET","path":"/payment_schedules?lease_contract_id=eq.<contract id>&select=id&limit=1"}'
# If non-empty, ask the user whether to delete existing rows and regenerate, or abort.

# 4. POST the full schedule as one array body
semantius call crud postgrestRequest '{
  "method":"POST",
  "path":"/payment_schedules",
  "body":[
    {
      "schedule_reference":"LC-2026-0042 / 2026-03",
      "lease_contract_id":"<contract id>",
      "fiscal_period_id":"<fiscal period id, optional>",
      "payment_number":1,
      "scheduled_date":"<commencement_date, YYYY-MM-DD>",
      "scheduled_amount":2500,
      "currency_code":"USD",
      "schedule_status":"pending"
    }
  ]
}'
```

`scheduled_date`: compute at call time from `commencement_date` and
the cadence; do not copy the placeholder.

**Validation:** the row count equals `term_months / months_per_payment`;
`payment_number` runs 1..N with no gaps; `sum(scheduled_amount)`
roughly equals `total_contract_value`; every `scheduled_date` falls
within `[commencement_date, end_date]`.

**Failure modes:**
- Step 4 fails partway -> some rows posted, some not. Re-read existing
  rows for this contract, identify which `payment_number` values are
  missing, and POST only those.
- The user did not give `total_contract_value` -> the schedule sum
  will not balance to a reported TCV. Tell the user the rows were
  generated from `monthly_payment_amount * months_per_payment` and
  surface the computed total so they can update the contract row if
  needed.
- The contract has `payment_frequency=annual` but `term_months=11` ->
  the math does not produce a whole number of payments. Ask the user
  whether to cap the last row to a partial period or extend
  `term_months`.

---

### Post a payment against a schedule (mark as paid)

**Triggers:** `record the March payment for contract LC-2026-0042`, `the Q1 payment cleared`, `post payment 1042 against this lease`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `payment_schedule_id` | yes | Resolve via `(contract_number, payment_number)` or `schedule_reference` |
| `payment_reference` | yes | Unique; voucher or AP posting number |
| `payment_date` | yes | Actual posting date; YYYY-MM-DD |
| `payment_amount` | yes | Should match `scheduled_amount`; flag deltas |
| `currency_code` | yes | Should match the schedule's `currency_code`; the platform does not convert |
| `payment_method` | yes | One of `ach`, `wire`, `check`, `credit_card`, `other` |
| `approved_by_user_id`, `invoice_number`, `notes` | no | Fill if the user named them |

**Pattern C with paired write.** Posting a payment is two writes:
insert into `lease_payments` AND flip
`payment_schedules.schedule_status` to `paid`. The DB does **not**
update the schedule for you; missing the second step leaves the
contract showing the schedule as `pending` even though the cash has
moved.

**Amount reconciliation.** The DB does not compare
`payment_amount` against `scheduled_amount`. If they differ:

- A small under/over (rounding, FX) -> post the actual `payment_amount`
  and add a `notes` line explaining the variance. Still flip the
  schedule to `paid`.
- A material under (partial payment) -> flip the schedule to
  `invoiced` instead of `paid` and tell the user the schedule needs
  another payment, or that the schedule should be split first. Do
  not flip to `paid` on a partial.
- An over-payment -> flag to the user. The data model has no concept
  of credits; an over-payment is almost always a data-entry error.

**Currency mismatch.** Refuse if
`lease_payments.currency_code` differs from the schedule's
`currency_code`; the platform has no FX layer and the totals will
silently drift.

**Recipe:**

```bash
# 1. Resolve the schedule and read its current state
semantius call crud postgrestRequest '{"method":"GET","path":"/payment_schedules?schedule_reference=eq.<ref>&select=id,lease_contract_id,payment_number,scheduled_date,scheduled_amount,currency_code,schedule_status"}'

# 2. Refuse if schedule_status is already `paid` or `waived` (the user is duplicating); tell the operator.

# 3. Compare payment_amount vs scheduled_amount; decide whether the next status is `paid` (full) or stays `invoiced` (partial). Surface any variance to the user before continuing.

# 4. Insert the lease_payment
semantius call crud postgrestRequest '{
  "method":"POST",
  "path":"/lease_payments",
  "body":{
    "payment_reference":"AP-2026-001042",
    "payment_schedule_id":"<schedule id>",
    "payment_date":"<payment date, YYYY-MM-DD>",
    "payment_amount":2500,
    "currency_code":"USD",
    "payment_method":"ach",
    "invoice_number":"INV-V-9921",
    "approved_by_user_id":"<optional approver id>"
  }
}'

# 5. Flip the schedule to paid (only if step 3 said full)
semantius call crud postgrestRequest '{
  "method":"PATCH","path":"/payment_schedules?id=eq.<schedule id>",
  "body":{"schedule_status":"paid"}
}'
```

`payment_date`: set at call time; do not copy the placeholder.

**Validation:** a `lease_payments` row exists with the new id; the
matching `payment_schedules.schedule_status` is `paid` (or
`invoiced` for a partial); `currency_code` matches the schedule; the
sum of `lease_payments.payment_amount` for this schedule is within
rounding of `scheduled_amount`.

**Failure modes:**
- 409 on `payment_reference` -> duplicate; the payment was already
  posted. Read the existing row to confirm and skip.
- Step 4 succeeds, step 5 fails -> the payment is recorded but the
  schedule still shows `pending`/`invoiced`. Re-run step 5 with the
  schedule id; do not re-POST the payment.
- `currency_code` mismatch between payment and schedule -> refuse
  before step 4. Surface the mismatch to the user; one side is wrong.
- Operator wants to DELETE a posted payment -> do not. The schedule
  has a `restrict` FK on the schedule side, so deleting the schedule
  fails anyway; deleting the payment loses the audit trail of what
  cleared. PATCH a correcting `notes` line and post a reversing entry
  if the AP system allows it.

---

### Terminate a lease contract early

**Triggers:** `terminate this lease early`, `we are walking away from contract LC-2026-0042`, `cancel the copier lease`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `lease_contract_id` | yes | Resolve via `contract_number` |
| Effective termination date | yes | YYYY-MM-DD; what to set as the new `end_date` |
| Reason | no | Free text into `notes` |

**Pattern A cascade with paired writes.** Termination is **not** a
single PATCH. Three things must change together:

1. `lease_contracts.contract_status` flips to `terminated` and
   `end_date` is overwritten with the effective termination date.
2. Every `payment_schedules` row for this contract whose
   `schedule_status` is `pending` or `invoiced` and whose
   `scheduled_date` is on or after the effective date must flip to
   `waived` (the cash will not be paid). Schedules already `paid`
   stay `paid`. Schedules already `overdue` need a manual call from
   the operator; ask whether to settle or waive.
3. Each `leased_assets` row should usually move to
   `condition_status=retired` with a `decommission_date` set to the
   effective date. Skip this step if the user explicitly says the
   assets are being kept (e.g. negotiated buy-out).

The DB cascades only on **delete**, not on a status flip; without
this client-side cascade, the variance report keeps planning future
payments that will never happen.

**Do not DELETE the contract.** The cascade-on-delete drops every
asset and every schedule (which then orphans payments through the
restrict FK chain). Use the status flip.

**Recipe:**

```bash
# 1. Resolve the contract and read current state
semantius call crud postgrestRequest '{"method":"GET","path":"/lease_contracts?contract_number=eq.<number>&select=id,contract_number,contract_status,commencement_date,end_date"}'

# 2. Refuse if contract_status is already terminal (`expired`, `terminated`, `renewed`); tell the user.

# 3. Surface the schedule rows that will be waived
semantius call crud postgrestRequest '{"method":"GET","path":"/payment_schedules?lease_contract_id=eq.<id>&schedule_status=in.(pending,invoiced,overdue)&scheduled_date=gte.<effective_date>&select=id,payment_number,scheduled_date,scheduled_amount,schedule_status&order=payment_number.asc"}'
# Show the list to the user; ask explicitly about any `overdue` rows (they may need to be settled, not waived).

# 4. Flip the contract
semantius call crud postgrestRequest '{
  "method":"PATCH","path":"/lease_contracts?id=eq.<id>",
  "body":{
    "contract_status":"terminated",
    "end_date":"<effective_date, YYYY-MM-DD>",
    "auto_renewal":false,
    "notes":"<termination reason>"
  }
}'

# 5. Waive future schedules in one ranged PATCH
semantius call crud postgrestRequest '{
  "method":"PATCH","path":"/payment_schedules?lease_contract_id=eq.<id>&schedule_status=in.(pending,invoiced)&scheduled_date=gte.<effective_date>",
  "body":{"schedule_status":"waived"}
}'

# 6. Retire the assets (skip only if the user said the assets are being kept)
semantius call crud postgrestRequest '{
  "method":"PATCH","path":"/leased_assets?lease_contract_id=eq.<id>&condition_status=neq.retired",
  "body":{
    "condition_status":"retired",
    "decommission_date":"<effective_date, YYYY-MM-DD>"
  }
}'
```

`effective_date`: set to a real date at call time; do not copy the
placeholder.

**Validation:** the contract shows `contract_status=terminated`,
`end_date=<effective>`, `auto_renewal=false`. A re-read of
`payment_schedules` for this contract shows zero `pending`/`invoiced`
rows after the effective date. A re-read of `leased_assets` shows
every row at `condition_status=retired` with `decommission_date`
set (unless skipped).

**Failure modes:**
- Step 5 fails after step 4 succeeds -> the contract is terminated
  but the future schedules still show `pending`. Re-run step 5 with
  the same filter; do not re-PATCH the contract.
- An `overdue` schedule is in the future-of-effective range -> the
  recipe excludes it from the bulk waive on purpose. Ask the user
  whether each overdue row should be (a) settled with a final
  payment, (b) waived as part of a settlement deal, or (c) left as
  is for collections.
- Contract has scheduled rows already `paid` past the effective date
  (e.g. an annual payment covering the full year) -> termination does
  not refund cash; tell the user the payment stays `paid`. Refunds
  live outside this model.

---

### Renew or supersede a contract

**Triggers:** `renew the vehicle lease`, `we are extending the copier contract for another year`, `the auto-renewal kicked in for LC-2026-0042`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `lease_contract_id` | yes | Resolve via `contract_number` |
| New `end_date` | yes | YYYY-MM-DD; the new term-end |
| New `term_months` | yes | If the renewal extends the term; recompute |
| New `monthly_payment_amount`, `total_contract_value`, `payment_frequency` | no | Only if the renewal contract changed them |

**Renewal style.** The model leaves room for two patterns. Pick the
right one by asking the user (or inferring from the magnitude of
change):

- **Same row, extended term** -- when nothing material changed except
  the term and (optionally) the payment amount. PATCH the existing
  row to push out `end_date`, update `term_months`, optionally update
  `monthly_payment_amount` / `total_contract_value`, set
  `signed_date`. Then **append** new payment_schedules for the
  extension period (do not regenerate the whole schedule; the
  historical rows are real cash that has already moved).
  `contract_status` stays `active`.
- **New row, supersede the old** -- when the renewal is a fresh
  contract with materially different terms. POST a new
  `lease_contracts` row with the new terms; PATCH the old row to
  `contract_status=renewed` once the new one is `active`. The model
  has no back-pointer between predecessor and successor, so record
  the link in the new row's `notes` ("supersedes <old
  contract_number>") to keep the chain readable.

**Asset migration on supersede.** When the same physical assets carry
over, you must move each `leased_assets` row to point at the new
`lease_contract_id`. There is no UPSERT for this, run a ranged PATCH:

```bash
semantius call crud postgrestRequest '{
  "method":"PATCH","path":"/leased_assets?lease_contract_id=eq.<old>",
  "body":{"lease_contract_id":"<new>"}
}'
```

The old contract is then carrying zero assets but still owns its
historical schedules and payments, which is correct. Do not DELETE
the old contract; that cascades and drops the history.

**Schedule migration on supersede.** Generate a fresh
`payment_schedules` set for the new contract using the
"Generate payment schedules" recipe. Do not move historical schedule
rows over; they belong to the old contract and the historical
payments reference them.

**Recipe (extend in place):**

```bash
# 1. Read the current row
semantius call crud postgrestRequest '{"method":"GET","path":"/lease_contracts?id=eq.<id>&select=id,contract_number,contract_status,end_date,term_months,monthly_payment_amount,total_contract_value,payment_frequency,currency_code,auto_renewal"}'

# 2. Refuse if contract_status is `terminated` (a terminated lease is not renewed; it is replaced).
#    Allow if status is `active` or `expired` (lapsed-then-renewed is a known case).

# 3. PATCH the new term
semantius call crud postgrestRequest '{
  "method":"PATCH","path":"/lease_contracts?id=eq.<id>",
  "body":{
    "contract_status":"active",
    "end_date":"<new end date, YYYY-MM-DD>",
    "term_months":48,
    "signed_date":"<today, YYYY-MM-DD>",
    "monthly_payment_amount":2500,
    "total_contract_value":120000,
    "auto_renewal":true
  }
}'

# 4. Append schedules for the extension only (do not regenerate the historical ones)
#    Use the "Generate payment schedules" recipe but start payment_number from
#    (max existing payment_number + 1) and walk dates from (old end_date + cadence).
```

**Recipe (supersede with a new row):**

```bash
# 1. Read the old row to copy unchanged fields
semantius call crud postgrestRequest '{"method":"GET","path":"/lease_contracts?id=eq.<old id>&select=*"}'

# 2. Create the new contract via the "Add a lease contract" recipe; copy vendor_id, primary_cost_center_id, contract_owner_id, lease_type, currency_code unchanged.
#    Set commencement_date=<renewal start>, end_date=<new end>, term_months=<new term>, contract_status=active.
#    Add a notes line: "supersedes <old contract_number>".

# 3. Move the assets to the new contract
semantius call crud postgrestRequest '{
  "method":"PATCH","path":"/leased_assets?lease_contract_id=eq.<old id>",
  "body":{"lease_contract_id":"<new id>"}
}'

# 4. Generate a fresh payment_schedules set for the new contract (see "Generate payment schedules").

# 5. Mark the old contract renewed
semantius call crud postgrestRequest '{
  "method":"PATCH","path":"/lease_contracts?id=eq.<old id>",
  "body":{
    "contract_status":"renewed",
    "auto_renewal":false
  }
}'
```

`end_date`, `signed_date`, `commencement_date`: set to real dates at
call time; do not copy the placeholders.

**Validation (extend):** the row shows `contract_status=active`,
`end_date` extended, `term_months` updated, `signed_date` updated;
new schedule rows exist with `payment_number` starting where the old
ones left off and `scheduled_date` walking forward from the prior
end.
**Validation (supersede):** the new row exists at
`contract_status=active`; the old row is `renewed`; every
`leased_assets` formerly on the old row points at the new id; the
new contract has its own complete payment_schedules set.

**Failure modes:**
- Extending in place when status was `terminated` -> reject; a
  terminated lease is not renewed. POST a fresh contract instead.
- Supersede without moving assets -> the new contract appears to
  have zero physical assets and reports zero deployed equipment.
  Recover by running step 3 against `lease_contract_id=eq.<old>`.
- Supersede by deleting the old contract instead of marking it
  `renewed` -> the cascade drops every historical asset, schedule,
  and (through the restrict chain) blocks on payment rows. Never
  DELETE a contract that has paid history.
- Extend in place by regenerating the whole schedule -> the historical
  `paid` rows get wiped and the matching `lease_payments` go orphan
  (FK is restrict; the bulk regenerate fails on the first paid row).
  Append rows; do not regenerate.

---

### Decommission a leased asset

**Triggers:** `retire this asset`, `decommission the printer`, `IT-LAP-0421 is being returned`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `asset_id` | yes | Resolve via `asset_tag` or `serial_number` |
| `decommission_date` | yes | YYYY-MM-DD |
| Reason | no | Free text into `notes` |

**Paired write rule.** `condition_status=retired` and
`decommission_date` move together. The DB allows
`condition_status=retired` without `decommission_date`, but the
asset-deployed report then shows the row as still active (because
`decommission_date IS NULL` is the typical filter). Always set both.

**Clear deployment fields.** A retired asset should have
`location_id` and `deployed_to_user_id` cleared so the deployed-by-
location and deployed-by-user reports stop counting it. The DB does
not auto-clear them.

**Do not DELETE.** Deleting a leased_asset loses the historical link
to the contract; PATCH preserves it. The model has no separate
"retired_assets" archive.

**Recipe:**

```bash
# 1. Resolve the asset
semantius call crud postgrestRequest '{"method":"GET","path":"/leased_assets?asset_tag=eq.<tag>&select=id,asset_tag,condition_status,decommission_date,location_id,deployed_to_user_id,lease_contract_id"}'

# 2. Refuse if condition_status is already `retired`; the asset was already decommissioned. Tell the user.

# 3. Decommission
semantius call crud postgrestRequest '{
  "method":"PATCH","path":"/leased_assets?id=eq.<id>",
  "body":{
    "condition_status":"retired",
    "decommission_date":"<decommission_date, YYYY-MM-DD>",
    "location_id":null,
    "deployed_to_user_id":null,
    "notes":"<reason>"
  }
}'
```

`decommission_date`: set at call time; do not copy the placeholder.

**Validation:** the row shows `condition_status=retired`,
`decommission_date` non-null, `location_id` and
`deployed_to_user_id` null.

**Failure modes:**
- The parent contract is still `active` and has many other live
  assets -> fine; one asset retiring early (damage, theft) is
  expected. Do not flip the contract status.
- The parent contract is the only asset's last live asset -> the
  contract still bills. Surface to the user; they may want to
  terminate the contract early (separate JTBD).
- Operator deleted instead of patching -> historical asset/contract
  link is lost. Not recoverable from this skill; tell the user to
  recreate the row from the contract record if audit is needed.

---

### Add and approve a budget line

**Triggers:** `add a budget line for IT hardware in Q1`, `allocate $250k to engineering for FY2026 leases`, `approve the FY2026 leasing budget`

**Inputs (add):**

| Name | Required | Notes |
|---|---|---|
| `cost_center_id` | yes | Resolve via `cost_center_code` |
| `fiscal_period_id` | yes | Resolve via `period_name` |
| `equipment_category_id` | no | Optional category slice |
| `planned_amount` | yes | In `currency_code` |
| `currency_code` | yes | ISO 4217 |
| `budget_status` | yes | `draft` on first create |
| `notes` | no | Free text |

**Inputs (approve):**

| Name | Required | Notes |
|---|---|---|
| `budget_line_id` | yes | Resolve via `(cost_center_code, period_name, [category_name])` |
| `approved_by_user_id` | yes | Resolve via `users.email` |

**Composite uniqueness, app-level only.** The tuple
`(cost_center_id, fiscal_period_id, equipment_category_id)` is
expected to be unique but **not** enforced by the database. POSTing
a duplicate tuple succeeds and creates a second budget line that
double-counts in variance reports. Always read first.

**Caller-populated label.** `budget_lines.budget_line_label` is
required on insert and not auto-derived. Compose it as
`"{cost_center_code} / {period_name} / {category_name}"` (e.g.
`"CC-100 / 2026-Q1 / IT hardware"`). If `equipment_category_id` is
null, drop the trailing segment: `"CC-100 / 2026-Q1"`. The recipe
reads cost_center / period / category in step 1 to have the values.

**Period closed-status check.** `fiscal_periods.is_closed=true`
should block both new budget_lines and edits to existing ones. The
DB does not enforce this; the recipe must read the period and
refuse if closed. Surface the closed status to the user instead of
silently posting.

**Paired write on approval.** `budget_status=approved` and
`approved_by_user_id` and `approved_at` move together. Without
`approved_at`, approval-cycle-time reports go blind; without
`approved_by_user_id`, accountability is lost.

**Recipe (add):**

```bash
# 1. Resolve cost_center, fiscal_period, and (optional) equipment_category
semantius call crud postgrestRequest '{"method":"GET","path":"/cost_centers?cost_center_code=eq.<code>&select=id,cost_center_code,cost_center_name,cost_center_status"}'
semantius call crud postgrestRequest '{"method":"GET","path":"/fiscal_periods?period_name=eq.<name>&select=id,period_name,is_closed,start_date,end_date"}'
semantius call crud postgrestRequest '{"method":"GET","path":"/equipment_categories?category_name=eq.<name>&select=id,category_name"}'

# 2. Refuse if fiscal_period.is_closed is true; tell the user the period is locked.

# 3. Refuse if a budget_line already exists for the same (cost_center_id, fiscal_period_id, equipment_category_id) tuple
semantius call crud postgrestRequest '{"method":"GET","path":"/budget_lines?cost_center_id=eq.<cc>&fiscal_period_id=eq.<fp>&equipment_category_id=eq.<ec>&select=id,budget_line_label,budget_status,planned_amount"}'
# If the row exists, ask the user whether to PATCH the existing line instead.

# 4. Create the line
semantius call crud postgrestRequest '{
  "method":"POST",
  "path":"/budget_lines",
  "body":{
    "budget_line_label":"CC-100 / 2026-Q1 / IT hardware",
    "cost_center_id":"<cc id>",
    "fiscal_period_id":"<fp id>",
    "equipment_category_id":"<ec id, optional>",
    "planned_amount":250000,
    "currency_code":"USD",
    "budget_status":"draft"
  }
}'
```

**Recipe (approve):**

```bash
# 1. Resolve the budget_line and the approver
semantius call crud postgrestRequest '{"method":"GET","path":"/budget_lines?id=eq.<id>&select=id,budget_line_label,budget_status,fiscal_period_id"}'
semantius call crud postgrestRequest '{"method":"GET","path":"/users?email=eq.<email>&select=id,full_name"}'

# 2. Refuse if budget_status is already `approved` or `locked`. (`locked` is a one-way flip after approval; do not PATCH back to `approved`.)

# 3. Re-check the parent fiscal_period is not closed (an approve on a closed period is operationally wrong).

# 4. Approve
semantius call crud postgrestRequest '{
  "method":"PATCH","path":"/budget_lines?id=eq.<id>",
  "body":{
    "budget_status":"approved",
    "approved_by_user_id":"<approver id>",
    "approved_at":"<current ISO timestamp>"
  }
}'
```

`approved_at`: set to the current ISO timestamp at call time; do not
copy the placeholder. The field is `date-time`, so the value should
be a full timestamp (e.g. `2026-05-04T14:30:00Z`).

**Validation:** for add, exactly one row exists for the
`(cost_center_id, fiscal_period_id, equipment_category_id)` tuple,
`budget_line_label` follows the composition rule, `planned_amount > 0`,
`budget_status='draft'`. For approve, the row shows
`budget_status='approved'`, `approved_by_user_id` set,
`approved_at` non-null.

**Failure modes:**
- Adding a line to a `is_closed=true` period -> the DB accepts it and
  the period rolls forward dirty. Recover by DELETE-ing the line, or
  ask the user to reopen the period (PATCH `is_closed=false`) and
  re-add cleanly.
- POST without the read-first uniqueness check -> the table accepts a
  duplicate tuple. Recover by DELETE-ing one of the duplicates; the
  variance report will double-count until cleaned.
- Approving with only `budget_status=approved` and no
  `approved_by_user_id` / `approved_at` -> the row shows approved
  but accountability and timing are lost. Re-PATCH with the missing
  fields; the row was not "really" approved before.
- Locking a budget_line (`budget_status=locked`) and then trying to
  edit it -> the DB allows the edit; the lock is operational only.
  Surface to the user before patching a locked line.

---

## Common queries

These are starting points, not contracts. Cube schema names drift
when the model is regenerated, so always run `cube discover '{}'`
first and map the dimension and measure names below against
`discover`'s output. The cube name is usually the entity's table name
with the first letter capitalized (e.g. `LeaseContracts`,
`PaymentSchedules`, `LeasePayments`, `BudgetLines`,
`LeasedAssets`), but verify.

```bash
# Always first
semantius call cube discover '{}'
```

```bash
# Total lease obligation by fiscal period (sum of scheduled, future-dated)
# Useful for "what is our total lease commitment next quarter"
semantius call cube load '{"query":{
  "measures":["PaymentSchedules.count","PaymentSchedules.sum_scheduled_amount"],
  "dimensions":["FiscalPeriods.period_name","PaymentSchedules.currency_code"],
  "filters":[
    {"member":"PaymentSchedules.schedule_status","operator":"equals","values":["pending","invoiced","overdue"]}
  ],
  "timeDimensions":[{"dimension":"PaymentSchedules.scheduled_date","dateRange":"next 365 days"}],
  "order":{"FiscalPeriods.period_name":"asc"}
}}'
```

```bash
# Active contracts by vendor with total contract value
semantius call cube load '{"query":{
  "measures":["LeaseContracts.count","LeaseContracts.sum_total_contract_value"],
  "dimensions":["Vendors.vendor_name","LeaseContracts.currency_code","LeaseContracts.lease_type"],
  "filters":[{"member":"LeaseContracts.contract_status","operator":"equals","values":["active"]}],
  "order":{"LeaseContracts.sum_total_contract_value":"desc"}
}}'
```

```bash
# Planned vs scheduled by cost center for a period (variance starting point)
# Two cube reads, joined by cost_center in the calling agent;
# a single query is awkward because budget_lines and payment_schedules attach to the cost center via different chains
# (budget_lines.cost_center_id direct; payment_schedules via payment_schedules.lease_contract_id -> lease_contracts.primary_cost_center_id).
semantius call cube load '{"query":{
  "measures":["BudgetLines.sum_planned_amount"],
  "dimensions":["CostCenters.cost_center_code","EquipmentCategories.category_name","BudgetLines.currency_code"],
  "filters":[
    {"member":"FiscalPeriods.period_name","operator":"equals","values":["2026-Q1"]},
    {"member":"BudgetLines.budget_status","operator":"equals","values":["approved","locked"]}
  ]
}}'
semantius call cube load '{"query":{
  "measures":["PaymentSchedules.sum_scheduled_amount"],
  "dimensions":["CostCenters.cost_center_code","PaymentSchedules.currency_code"],
  "filters":[
    {"member":"FiscalPeriods.period_name","operator":"equals","values":["2026-Q1"]},
    {"member":"PaymentSchedules.schedule_status","operator":"equals","values":["pending","invoiced","paid","overdue"]}
  ]
}}'
```

```bash
# Overdue payment schedules (operational AR-from-the-lessee-side report)
semantius call cube load '{"query":{
  "measures":["PaymentSchedules.count","PaymentSchedules.sum_scheduled_amount"],
  "dimensions":["LeaseContracts.contract_number","Vendors.vendor_name","PaymentSchedules.scheduled_date","PaymentSchedules.currency_code"],
  "filters":[
    {"member":"PaymentSchedules.schedule_status","operator":"equals","values":["overdue"]}
  ],
  "order":{"PaymentSchedules.scheduled_date":"asc"}
}}'
```

```bash
# Upcoming contract renewals in the next 90 days (active, near end_date)
semantius call cube load '{"query":{
  "measures":["LeaseContracts.count","LeaseContracts.sum_total_contract_value"],
  "dimensions":["LeaseContracts.contract_number","Vendors.vendor_name","LeaseContracts.end_date","LeaseContracts.auto_renewal","LeaseContracts.renewal_notice_days"],
  "filters":[{"member":"LeaseContracts.contract_status","operator":"equals","values":["active"]}],
  "timeDimensions":[{"dimension":"LeaseContracts.end_date","dateRange":"next 90 days"}],
  "order":{"LeaseContracts.end_date":"asc"}
}}'
```

```bash
# Assets deployed by location and category (live inventory view)
semantius call cube load '{"query":{
  "measures":["LeasedAssets.count","LeasedAssets.sum_acquisition_cost"],
  "dimensions":["Locations.location_name","EquipmentCategories.category_name","LeasedAssets.condition_status"],
  "filters":[{"member":"LeasedAssets.condition_status","operator":"notEquals","values":["retired"]}],
  "order":{"LeasedAssets.count":"desc"}
}}'
```

---

## Guardrails

- Never PATCH `lease_contracts.contract_status` to `terminated`
  without overwriting `end_date` and surfacing the future
  `pending`/`invoiced` schedule rows for waive/settle decisions in
  the same operation.
- Never DELETE a `lease_contract` that has any history (paid
  schedules, real assets); the cascade drops every asset and
  schedule and orphans payments through the restrict FK chain. Use
  `contract_status=terminated` or `=renewed`.
- Never POST a `lease_payment` without flipping the matching
  `payment_schedules.schedule_status` (`paid` for full,
  `invoiced` for partial) in the same operation; the contract's
  cash position drifts otherwise.
- Never post a `lease_payment` whose `currency_code` differs from
  the schedule's `currency_code`; the platform has no FX layer.
- Never DELETE a `lease_payment`; the schedule's restrict FK and the
  audit trail both bleed. PATCH a correcting note.
- Never add a `budget_line` to a `is_closed=true` `fiscal_period`;
  the DB allows it but the period is locked operationally.
- Never POST a second `budget_line` for the same
  `(cost_center_id, fiscal_period_id, equipment_category_id)` tuple;
  composite uniqueness is app-level only and the variance report
  will double-count.
- Never approve a `budget_line` without setting
  `approved_by_user_id` and `approved_at` in the same call.
- Never set `leased_assets.condition_status=retired` without
  `decommission_date` and clearing `location_id` /
  `deployed_to_user_id` in the same call.
- Never regenerate `payment_schedules` for a contract that has any
  `paid` or `invoiced` rows; append, do not rebuild.
- Lookups for human-friendly identifiers (vendor names, contract
  titles, asset descriptions, schedule references) use
  `search_vector=wfts(simple).<term>`; never `ilike` and never
  `fts`. `eq.<value>` is for known-exact values (UUIDs, FK ids,
  status enums, `vendor_code`, `contract_number`, `asset_tag`,
  `serial_number`, `period_name`, `cost_center_code`,
  `users.email`, `payment_reference`).
- `users` exists as a Semantius built-in in this deployment; treat
  it as the authoritative table and reference it rather than
  creating a parallel one.

## What this skill does NOT do

- Schema changes, use `use-semantius` directly.
- RBAC / permissions, use `use-semantius` directly.
- One-off seed data, write a script, do not bake it into a JTBD.
- Multi-cost-center allocation: `lease_contracts.primary_cost_center_id`
  is a single FK, so a contract whose cost is split across cost
  centers cannot be modeled cleanly until a `cost_allocations`
  junction is introduced.
- ASC 842 remeasurement events: term extensions, payment changes, and
  scope changes are not tracked as their own entity; they live as
  edits on `lease_contracts` and the audit gap means historical
  remeasurement reasoning is lost.
- Contract document storage: scanned PDFs, amendments, and
  supporting docs have no `contract_documents` entity; document
  links can only be stuffed into `notes`.
- Asset-level cost-center override: every asset on a contract bills
  to the contract's `primary_cost_center_id`; one asset on a shared
  contract cannot be charged to a different cost center without a
  `leased_assets.cost_center_id` field.
- Multi-currency conversion and FX-rate snapshots: every monetary
  field carries a `currency_code` but the platform does not convert.
  Reporting across currencies is the calling agent's problem.
- Hierarchical cost centers or equipment categories: both are flat
  structures, so drill-down reporting along a parent-child tree is
  not available.
- Contract options (renewal options, purchase options): only the
  scalar `auto_renewal` and `renewal_notice_days` exist; options
  with their own exercise/expiry dates are not modeled.
- Database-enforced composite uniqueness on `budget_lines`: the
  `(cost_center_id, fiscal_period_id, equipment_category_id)` tuple
  is unique only in application logic.
- Multi-step approval workflows: only the single
  `approved_by_user_id` / `approved_at` pair on `lease_contracts`
  and `budget_lines` exists; routing chains, delegations, and
  rejection cycles are not modeled.
