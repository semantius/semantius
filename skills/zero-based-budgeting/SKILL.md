---
name: zero-based-budgeting
description: >-
  Use this skill for anything involving Zero-Based Budgeting, the in-house
  ZBB platform where every cost-center owner rebuilds budget from zero each
  cycle by submitting decision packages with multiple funding levels, ranks
  them, and walks them through an explicit approval workflow. Trigger when
  the user says: "open the FY26 budget cycle", "lock the cycle", "draft a
  decision package", "add a minimum / current / enhanced funding level",
  "add cost line items to the enhanced level", "submit this package for
  review", "approve the package at the current level", "cut this package
  to minimum", "reject this package", "defer the package to next cycle",
  "rank the packages for cost center CC-1001", "reorder the rankings",
  "assign Jane as approver on CC-1001", "what's the total committed
  budget for FY26", "show package count by status by cost center". Loads
  alongside `use-semantius`, which owns CLI install, PostgREST encoding,
  and cube query mechanics.
semantic_model: zero_based_budgeting
---

# Zero-Based Budgeting

This skill carries the domain map and the jobs-to-be-done for Zero-Based
Budgeting. Platform mechanics, CLI install, env vars, PostgREST URL-encoding,
`sqlToRest`, cube `discover` / `validate` / `load`, and schema-management
tools, live in `use-semantius`. Assume it loads alongside; do not re-explain
CLI basics here.

If a task is purely about defining schema, managing permissions, or running
ad-hoc queries against tables you already know, call `use-semantius`
directly, going through this skill adds nothing.

**Auto-managed fields** (set by Semantius on every table; never include in
POST/PATCH bodies): `id`, `created_at`, `updated_at`. Every entity's
**`label_column` field is required on insert and caller-populated**, this
includes the natural-label entities (`budget_cycles.cycle_name`,
`cost_centers.cost_center_name`, `decision_packages.package_title`, etc.)
**and** the three composed-label entities (`package_rankings.ranking_label`,
`approval_actions.action_label`, `cost_center_assignments.assignment_label`)
where the recipe must compose the value, see each JTBD for the composition
rule. Do not omit `*_label` / `*_name` / `*_title` fields from POST bodies.

---

## Domain glossary

| Concept | Table | Notes |
|---|---|---|
| Budget Cycle | `budget_cycles` | The planning period (e.g. "FY26 ZBB Cycle"); scopes packages and rankings |
| Cost Center | `cost_centers` | The ZBB "decision unit"; org unit accountable for justifying its own budget; hierarchical via `parent_cost_center_id` |
| Decision Package | `decision_packages` | The atomic ZBB artifact: a discrete activity / service / expenditure being justified from zero |
| Funding Level | `funding_levels` | A service-level option for a package (typically minimum / current / enhanced); each has its own cost stack |
| Cost Line Item | `cost_line_items` | Granular cost row inside a funding level; `total_cost_amount` is the canonical figure |
| Cost Category | `cost_categories` | Taxonomy (Salary, Contractor, Software, Travel, Capex, ...); hierarchical |
| GL Account | `gl_accounts` | Chart-of-accounts linkage for line items; hierarchical |
| Cost Driver | `cost_drivers` | Reusable quantitative driver (FTE count, transaction volume) referenced by line items |
| Package Ranking | `package_rankings` | Priority ordering of packages within a cost center, scoped to a cycle |
| Approval Action | `approval_actions` | One review event on a package; the full sequence is the audit trail |
| User | `users` | Owner / reviewer / approver / controller (matches Semantius built-in `users`) |
| Cost Center Assignment | `cost_center_assignments` | Junction: which user holds which role on which cost center |

`users` overlaps the Semantius built-in user table; the deployer reuses the
built-in. Do not POST to a duplicate `users` table; reference existing user
ids via `read_user` or `postgrestRequest GET /users`.

## Key enums

- `budget_cycles.cycle_status`: `draft` -> `planning` -> `in_review` -> `locked` -> `archived`
- `decision_packages.package_status`: `draft` -> `submitted` -> `in_review` -> `approved` | `rejected` | `cut` | `deferred`
- `decision_packages.package_type`: `continuing` | `new` | `discretionary` | `mandatory`
- `decision_packages.priority_tier`: `must_have` | `should_have` | `nice_to_have`
- `funding_levels.level_tier`: `minimum` | `current` | `enhanced` | `custom`
- `cost_line_items.cost_period`: `one_time` | `recurring_annual`
- `cost_categories.category_type`: `opex` | `capex` | `mixed`
- `gl_accounts.account_type`: `asset` | `liability` | `equity` | `revenue` | `expense` | `contra`
- `approval_actions.action_type`: `submit` | `approve` | `reject` | `cut` | `defer` | `request_changes` | `withdraw`
- `cost_center_assignments.assignment_role`: `owner` | `reviewer` | `approver` | `controller`

## Foreign-key cheatsheet

- `cost_centers.parent_cost_center_id -> cost_centers.id` (self-ref, clear on delete)
- `cost_centers.owner_user_id -> users.id` (clear on delete)
- `decision_packages.cost_center_id -> cost_centers.id` (parent, restrict on delete)
- `decision_packages.budget_cycle_id -> budget_cycles.id` (restrict on delete)
- `decision_packages.selected_funding_level_id -> funding_levels.id` (clear on delete). **Cross-FK invariant:** the referenced `funding_levels.decision_package_id` must equal this package's `id`. Always verify before patching.
- `decision_packages.owner_user_id -> users.id` (restrict on delete)
- `funding_levels.decision_package_id -> decision_packages.id` (parent, cascade on delete)
- `cost_line_items.funding_level_id -> funding_levels.id` (parent, cascade on delete)
- `cost_line_items.cost_category_id -> cost_categories.id` (restrict on delete)
- `cost_line_items.gl_account_id -> gl_accounts.id` (clear on delete)
- `cost_line_items.cost_driver_id -> cost_drivers.id` (clear on delete)
- `package_rankings.cost_center_id -> cost_centers.id` (parent, cascade on delete)
- `package_rankings.budget_cycle_id -> budget_cycles.id` (restrict on delete)
- `package_rankings.decision_package_id -> decision_packages.id` (cascade on delete)
- `approval_actions.decision_package_id -> decision_packages.id` (parent, **restrict** on delete to preserve audit trail)
- `approval_actions.funding_level_id -> funding_levels.id` (clear on delete)
- `approval_actions.actor_user_id -> users.id` (restrict on delete)
- `cost_center_assignments.cost_center_id -> cost_centers.id` (parent, cascade on delete)
- `cost_center_assignments.user_id -> users.id` (cascade on delete)

**Composite uniqueness (DB-enforced; expect 409 on collision):**
- `package_rankings (cost_center_id, budget_cycle_id, rank_position)` unique
- `package_rankings (cost_center_id, budget_cycle_id, decision_package_id)` unique

**Unique columns (single-field):** `cost_centers.cost_center_code`,
`decision_packages.package_code`, `cost_categories.category_code`,
`gl_accounts.account_code`, `cost_drivers.driver_code`, `users.user_email`.

**Junction without uniqueness:** `cost_center_assignments` has no DB-level
unique constraint on `(user_id, cost_center_id, assignment_role)`. Recipes
must dedupe before insert.

**Audit-logged tables** (Semantius writes the audit rows; recipes don't
manage them): `budget_cycles`, `cost_centers`, `decision_packages`,
`funding_levels`, `cost_line_items`, `package_rankings`, `approval_actions`.
The `approval_actions` table is *also* the domain audit trail of governance
decisions; it is caller-written and a first-class entity, not a system log.

---

## Jobs to be done

### Open or lock a budget cycle

**Triggers:** `"open the FY26 budget cycle"`, `"move the cycle to planning"`, `"lock the cycle"`, `"archive last year's cycle"`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `cycle_name` or `id` | yes | Caller may pass either; resolve by name first |
| target status | yes | One of `planning`, `in_review`, `locked`, `archived` |

The valid lifecycle is `draft -> planning -> in_review -> locked -> archived`.
The DB accepts any value, so the recipe must read current status and refuse
backwards transitions and skips that lose audit clarity (e.g. `draft ->
locked`). Locking and archiving have a hard precondition: no packages may
be `in_review` or `submitted` on this cycle.

**Recipe:**

```bash
# 1. Resolve the cycle (fuzzy on name, or exact on id)
semantius call crud postgrestRequest '{"method":"GET","path":"/budget_cycles?search_vector=wfts(simple).<term>&select=id,cycle_name,cycle_status"}'

# 2. Verify the requested transition is forward (draft -> planning -> in_review -> locked -> archived).
#    Refuse backwards moves; ask the user to confirm a skip (e.g. planning -> locked).

# 3. For target=locked or target=archived, check no in-flight packages remain
semantius call crud postgrestRequest '{"method":"GET","path":"/decision_packages?budget_cycle_id=eq.<cycle_id>&package_status=in.(submitted,in_review)&select=id,package_code,package_status"}'
# If any rows come back, abort and list them. Locking with packages still under review loses the
# point of the cycle gate.

# 4. Flip the status
semantius call crud postgrestRequest '{
  "method":"PATCH",
  "path":"/budget_cycles?id=eq.<cycle_id>",
  "body":{"cycle_status":"locked"}
}'
```

**Validation:**
- `cycle_status` reads back as the target value.
- For `locked` / `archived`: zero packages in `submitted` or `in_review` for this cycle.

**Failure modes:**
- *In-flight packages remain* on a lock attempt -> abort, present the list, ask the user to resolve each (approve / reject / withdraw) before retrying.
- *Backwards transition requested* (e.g. `locked -> planning`) -> refuse; archived/locked cycles are deliberately frozen. Ask whether the user wants a new cycle for the FY instead.

---

### Author a decision package with funding levels

**Triggers:** `"draft a decision package"`, `"create a new package for CC-1001"`, `"add a minimum / current / enhanced funding level"`, `"set the recommended funding level"`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `cost_center` | yes | code or id; resolve via `cost_center_code=eq.<code>` |
| `budget_cycle` | yes | name or id; cycle must be in `planning` (packages on a `locked` cycle cannot be authored) |
| `package_code` | yes | unique, e.g. `"PKG-FY26-001"`; reject 409 with a suggestion to bump the number |
| `package_title` | yes | label |
| `package_type` | yes | one of `continuing`, `new`, `discretionary`, `mandatory` |
| `business_justification` | yes | the "why" narrative; HTML allowed |
| `owner_user_id` | yes | resolve via email if user passes one |
| funding levels | yes | at least 2; exactly one must be `is_recommended_level=true` |

**Recipe:**

```bash
# 1. Verify cost center, cycle, and owner exist; verify cycle is in `planning`
semantius call crud postgrestRequest '{"method":"GET","path":"/cost_centers?cost_center_code=eq.CC-1001&select=id"}'
semantius call crud postgrestRequest '{"method":"GET","path":"/budget_cycles?id=eq.<cycle_id>&select=id,cycle_status"}'
semantius call crud postgrestRequest '{"method":"GET","path":"/users?user_email=eq.<owner_email>&select=id"}'

# 2. Create the package in `draft`. Do NOT set selected_funding_level_id yet -
#    the funding level rows do not exist until step 3.
semantius call crud postgrestRequest '{
  "method":"POST",
  "path":"/decision_packages",
  "body":{
    "package_code":"PKG-FY26-001",
    "package_title":"K8s migration platform",
    "cost_center_id":"<cc_id>",
    "budget_cycle_id":"<cycle_id>",
    "package_type":"new",
    "priority_tier":"should_have",
    "package_status":"draft",
    "business_justification":"<html>",
    "owner_user_id":"<owner_id>"
  }
}'
# Capture returned id as <package_id>.

# 3. Create the funding levels (>= 2). Pick exactly one as `is_recommended_level=true`.
#    Use ascending `level_order` (1 = lowest tier).
semantius call crud postgrestRequest '{
  "method":"POST",
  "path":"/funding_levels",
  "body":{
    "funding_level_label":"Minimum",
    "decision_package_id":"<package_id>",
    "level_tier":"minimum",
    "level_order":1,
    "is_recommended_level":false,
    "currency_code":"USD",
    "service_description":"<html>"
  }
}'
semantius call crud postgrestRequest '{
  "method":"POST",
  "path":"/funding_levels",
  "body":{
    "funding_level_label":"Current",
    "decision_package_id":"<package_id>",
    "level_tier":"current",
    "level_order":2,
    "is_recommended_level":true,
    "currency_code":"USD",
    "service_description":"<html>"
  }
}'
semantius call crud postgrestRequest '{
  "method":"POST",
  "path":"/funding_levels",
  "body":{
    "funding_level_label":"Enhanced +2 FTE",
    "decision_package_id":"<package_id>",
    "level_tier":"enhanced",
    "level_order":3,
    "is_recommended_level":false,
    "currency_code":"USD",
    "service_description":"<html>"
  }
}'

# 4. selected_funding_level_id stays NULL on a draft. It is set during the review JTBD when
#    an approver picks a level. Do not set it here.
```

**Validation:**
- The package has at least 2 funding levels.
- Exactly one funding level has `is_recommended_level=true`.
- `selected_funding_level_id` is null while `package_status=draft`.

**Failure modes:**
- *409 on `package_code`* -> a package already uses this code in some cycle (codes are globally unique). Suggest bumping the suffix or scoping with the cycle prefix (`PKG-FY26-NNN`).
- *Cycle is not `planning`* -> packages cannot be authored on `draft`, `in_review`, `locked`, or `archived` cycles. Either move the cycle forward or ask the user to pick a different cycle.
- *Multiple `is_recommended_level=true`* -> the model permits it at the DB level but the next JTBD (submit) refuses. Easier to fix here: PATCH all but one back to `false` before submit.

---

### Add cost line items to a funding level

**Triggers:** `"add salary line to the enhanced level"`, `"itemize the minimum funding level"`, `"add a Datadog license line item"`, `"break down the cost stack"`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `funding_level_id` | yes | parent |
| `line_item_label` | yes | label; the line item description |
| `cost_category_id` | yes | required FK; resolve via `category_code=eq.<code>` |
| `total_cost_amount` | yes | canonical figure used in roll-ups |
| `quantity` + `unit_cost_amount` | optional | if both supplied, set `total_cost_amount = quantity * unit_cost_amount` and verify the math |
| `gl_account_id`, `cost_driver_id` | optional | both `clear` on delete |
| `currency_code` | yes | ISO 4217; should match the parent `funding_levels.currency_code` |
| `cost_period` | yes | `one_time` or `recurring_annual` |

**Composition rule (computed field):** `total_cost_amount` is the canonical
roll-up figure. When the caller passes `quantity` and `unit_cost_amount`,
**always set `total_cost_amount = quantity * unit_cost_amount` in the same
POST body**. Do not rely on the platform to compute it. If the caller passes
a `total_cost_amount` that disagrees with `quantity * unit_cost_amount`,
flag the discrepancy and ask which figure is canonical before writing.

**Recipe:**

```bash
# 1. Resolve cost category (and optionally GL account / cost driver) by code
semantius call crud postgrestRequest '{"method":"GET","path":"/cost_categories?category_code=eq.SALARY&select=id"}'

# 2. Read parent funding level to copy currency_code (line items should match parent)
semantius call crud postgrestRequest '{"method":"GET","path":"/funding_levels?id=eq.<fl_id>&select=id,currency_code,decision_package_id"}'

# 3. POST the line item with computed total
semantius call crud postgrestRequest '{
  "method":"POST",
  "path":"/cost_line_items",
  "body":{
    "line_item_label":"Senior Engineer salaries (x2)",
    "funding_level_id":"<fl_id>",
    "cost_category_id":"<cat_id>",
    "gl_account_id":"<gl_id>",
    "cost_driver_id":"<driver_id>",
    "quantity":2,
    "unit_cost_amount":180000,
    "total_cost_amount":360000,
    "currency_code":"USD",
    "cost_period":"recurring_annual"
  }
}'
```

**Validation:**
- If `quantity` and `unit_cost_amount` are both set: `total_cost_amount == quantity * unit_cost_amount`.
- `currency_code` matches the parent funding level's currency.

**Failure modes:**
- *Inconsistent totals* (caller's `total_cost_amount` differs from `quantity * unit_cost_amount`) -> stop, present both values, ask which is canonical. Do not silently overwrite.
- *Missing `cost_category_id`* -> required FK; resolve a category first or ask the user to pick one. The platform will 400 without it.
- *Currency mismatch with parent funding level* -> warn, the model has not yet promoted currency to a first-class entity (§6.2 future), so mixed-currency roll-ups within one funding level corrupt the total.

---

### Submit a package for review

**Triggers:** `"submit this package"`, `"send PKG-FY26-001 to review"`, `"mark the package as submitted"`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `package_id` or `package_code` | yes | resolve by code if a code is passed |
| `actor_user_id` | yes | who is submitting; usually the package owner |

**Preconditions (must read-and-check before writing):**
- `package_status` is currently `draft`.
- The package has >=2 funding levels.
- Exactly one of those levels has `is_recommended_level=true`.
- The package's `budget_cycle.cycle_status` is `planning` (a cycle in
  `draft` has not opened for submissions; one in `in_review` / `locked` /
  `archived` has closed).

**Recipe:**

```bash
# 1. Resolve the package (fuzzy on title, or exact on package_code)
semantius call crud postgrestRequest '{"method":"GET","path":"/decision_packages?package_code=eq.PKG-FY26-001&select=id,package_status,budget_cycle_id,owner_user_id"}'

# 2. Check funding levels: count and recommended flag
semantius call crud postgrestRequest '{"method":"GET","path":"/funding_levels?decision_package_id=eq.<package_id>&select=id,level_tier,is_recommended_level"}'
# Verify count >= 2 and exactly one row has is_recommended_level=true.

# 3. Check the parent cycle is `planning`
semantius call crud postgrestRequest '{"method":"GET","path":"/budget_cycles?id=eq.<cycle_id>&select=id,cycle_name,cycle_status"}'

# 4. Flip status and stamp submitted_at in the SAME PATCH
semantius call crud postgrestRequest '{
  "method":"PATCH",
  "path":"/decision_packages?id=eq.<package_id>",
  "body":{
    "package_status":"submitted",
    "submitted_at":"<current ISO timestamp>"
  }
}'
# `submitted_at`: set to the current timestamp at call time; do not copy the example value.

# 5. Write the approval_action audit row. action_label is caller-composed:
#    "{action_type capitalized} | {actor display_name} | {today YYYY-MM-DD}"
semantius call crud postgrestRequest '{"method":"GET","path":"/users?id=eq.<actor_user_id>&select=display_name"}'
semantius call crud postgrestRequest '{
  "method":"POST",
  "path":"/approval_actions",
  "body":{
    "action_label":"Submit | <actor display_name> | <today YYYY-MM-DD>",
    "decision_package_id":"<package_id>",
    "actor_user_id":"<actor_user_id>",
    "action_type":"submit",
    "acted_at":"<current ISO timestamp>"
  }
}'
# `acted_at` and the date in `action_label`: render at call time; do not copy the example values.
```

**Validation:**
- After step 4: `package_status=submitted` and `submitted_at` is non-null.
- After step 5: a new `approval_actions` row exists for this package with `action_type=submit`.

**Failure modes:**
- *Funding-level count < 2* -> abort; ask the user to add a second level. ZBB requires the choice to be explicit.
- *Zero or multiple recommended levels* -> abort; PATCH the funding levels so exactly one is `is_recommended_level=true`, then retry submit.
- *Parent cycle is not `planning`* -> if `draft`, advance the cycle first; if `in_review` / `locked` / `archived`, the submission window is closed.
- *Status was not `draft`* -> the package was already submitted or further along. Read `approval_actions` to see the history before deciding whether to withdraw and re-submit.

---

### Review a package (approve / reject / cut / defer / request_changes / withdraw)

**Triggers:** `"approve the package at the current level"`, `"approve PKG-FY26-001 at enhanced"`, `"cut this package to minimum"`, `"reject the package"`, `"defer to next cycle"`, `"request changes on the justification"`, `"withdraw my submission"`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `package_id` or `package_code` | yes | resolve first |
| `action_type` | yes | one of `approve`, `reject`, `cut`, `defer`, `request_changes`, `withdraw` |
| `actor_user_id` | yes | the reviewer or owner (for `withdraw`) |
| `funding_level_id` | required for `approve` and `cut` | the level being approved or cut to. **Must belong to this package** (cross-FK invariant) |
| `comment` | optional | recommended for `reject`, `cut`, `request_changes`, `defer` |

**Polymorphic outcome (each branch sets a different package_status and a
different set of side-effect fields):**

| `action_type` | `package_status` after | Sets `selected_funding_level_id`? | Sets `approved_at`? |
|---|---|---|---|
| `submit` | `submitted` | no | no |
| `approve` | `approved` | yes (the chosen level) | yes (current timestamp) |
| `cut` | `cut` | yes (a lower-tier level) | no |
| `reject` | `rejected` | no | no |
| `defer` | `deferred` | no | no |
| `request_changes` | `in_review` (or stays `submitted`) | no | no |
| `withdraw` | `draft` | no | no |

`request_changes` does NOT terminate the package; it bounces it back for the
owner to revise. `withdraw` is the owner's escape hatch and only valid while
status is `submitted` or `in_review`.

**Cross-FK invariant (CRITICAL):** for `approve` and `cut`, the
`funding_level_id` passed must satisfy
`funding_levels.decision_package_id = <package_id>`. Verify before writing,
the DB does not enforce it through the `decision_packages.selected_funding_level_id`
edge.

**Recipe (approve branch shown; other branches differ only in the patch
body and the `action_type`):**

```bash
# 1. Resolve the package
semantius call crud postgrestRequest '{"method":"GET","path":"/decision_packages?package_code=eq.PKG-FY26-001&select=id,package_status,cost_center_id,budget_cycle_id"}'

# 2. Verify status is reviewable: must be `submitted` or `in_review` for approve / cut / reject /
#    defer / request_changes; must be `submitted` or `in_review` for withdraw.
#    `approved`, `rejected`, `cut`, `deferred` are terminal - refuse a second action with a clear
#    message, ask the user to confirm a status repair before proceeding.

# 3. For approve / cut: verify the target funding level belongs to this package
semantius call crud postgrestRequest '{"method":"GET","path":"/funding_levels?id=eq.<funding_level_id>&select=id,decision_package_id,level_tier"}'
# If decision_package_id != <package_id>, abort. The cross-FK invariant would be violated.

# 4. PATCH the package: status + selected_funding_level_id + approved_at in ONE call
semantius call crud postgrestRequest '{
  "method":"PATCH",
  "path":"/decision_packages?id=eq.<package_id>",
  "body":{
    "package_status":"approved",
    "selected_funding_level_id":"<funding_level_id>",
    "approved_at":"<current ISO timestamp>"
  }
}'
# `approved_at`: set to the current timestamp at call time; do not copy the example value.

# 5. Write the approval_action audit row. The label rule is the same as for submit.
semantius call crud postgrestRequest '{"method":"GET","path":"/users?id=eq.<actor_user_id>&select=display_name"}'
semantius call crud postgrestRequest '{
  "method":"POST",
  "path":"/approval_actions",
  "body":{
    "action_label":"Approve | <actor display_name> | <today YYYY-MM-DD>",
    "decision_package_id":"<package_id>",
    "funding_level_id":"<funding_level_id>",
    "actor_user_id":"<actor_user_id>",
    "action_type":"approve",
    "comment":"<optional reviewer comment>",
    "acted_at":"<current ISO timestamp>"
  }
}'
# `acted_at` and the date in `action_label`: render at call time; do not copy the example values.
```

**Branch differences:**

- *cut:* step 4 body becomes `{"package_status":"cut","selected_funding_level_id":"<lower_level_id>"}` (no `approved_at`); step 5 `action_type:"cut"` and label prefix `"Cut"`. Verify the chosen level is a *lower* tier than the recommended one (not enforced; flag if not).
- *reject:* step 3 is skipped (no funding level needed); step 4 body becomes `{"package_status":"rejected"}`; step 5 `action_type:"reject"`, label prefix `"Reject"`, comment strongly recommended.
- *defer:* step 3 skipped; step 4 body `{"package_status":"deferred"}`; step 5 `action_type:"defer"`, label prefix `"Defer"`.
- *request_changes:* step 3 skipped; step 4 body `{"package_status":"in_review"}` (or omit the PATCH if status is already `in_review`); step 5 `action_type:"request_changes"`, label prefix `"Request changes"`, comment strongly recommended.
- *withdraw:* step 3 skipped; step 4 body `{"package_status":"draft","submitted_at":null}`, this resets the owner's flow; step 5 `action_type:"withdraw"`, label prefix `"Withdraw"`. Refuse if package is already terminal (`approved`, `rejected`, `cut`, `deferred`).

**Validation:**
- Status reads back as the expected post-state for the branch.
- For `approve`: `selected_funding_level_id` is set AND `approved_at` is non-null AND `funding_levels.decision_package_id` for that level equals the package id.
- A new `approval_actions` row exists with the correct `action_type` and a non-empty `action_label`.

**Failure modes:**
- *Cross-FK invariant violation* on `approve`/`cut` (chosen funding level belongs to a different package) -> abort. Likely an id mix-up; re-resolve the package and its levels and confirm with the user.
- *Terminal-state retry* (e.g. approving an already-`approved` package) -> refuse; the audit trail in `approval_actions` is canonical. If the user genuinely wants to revise, the workflow is `withdraw -> revise -> resubmit`, and the cycle must still be in `planning`.
- *No `funding_level_id` on a `cut`* -> the model treats `cut` as "approved at a lower level". Without a target level, the action is functionally a `reject`; ask the user to confirm.

---

### Rank packages within a cost center for a cycle

**Triggers:** `"rank the packages for CC-1001"`, `"set PKG-FY26-001 to rank 3"`, `"reorder the rankings"`, `"insert a ranking at position 2"`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `cost_center_id` | yes | resolve via `cost_center_code` |
| `budget_cycle_id` | yes | resolve via `cycle_name` |
| `decision_package_id` | yes | must already exist and have `cost_center_id` matching the ranking's CC |
| `rank_position` | yes | 1 = highest priority |
| `ranking_label` | yes | **caller-populated**; compose from related rows (see below) |
| `rationale` | optional | text |

**Cross-FK invariant:** `decision_packages.cost_center_id` for the ranked
package must equal the ranking's `cost_center_id`. Same for `budget_cycle_id`.
A package cannot be ranked under a cost center it doesn't belong to.

**Composite uniqueness (DB-enforced; recipes must handle 409):**
- `(cost_center_id, budget_cycle_id, rank_position)` unique -> only one row at any rank
- `(cost_center_id, budget_cycle_id, decision_package_id)` unique -> a package can only be ranked once per cycle in a given CC

**Caller-populated label rule (from the model's §7.7):**
`ranking_label = "{cycle_name} / {cost_center_code} / #{rank_position} {package_title}"`
Example: `"FY26 ZBB Cycle / CC-1001 / #3 K8s Migration"`. Compose at call
time from looked-up values; do not hardcode.

**Recipe:**

```bash
# 1. Resolve cost center, cycle, package; verify the package belongs to this CC and cycle
semantius call crud postgrestRequest '{"method":"GET","path":"/cost_centers?cost_center_code=eq.CC-1001&select=id,cost_center_code"}'
semantius call crud postgrestRequest '{"method":"GET","path":"/budget_cycles?id=eq.<cycle_id>&select=id,cycle_name"}'
semantius call crud postgrestRequest '{"method":"GET","path":"/decision_packages?id=eq.<package_id>&select=id,package_title,cost_center_id,budget_cycle_id"}'
# Verify package.cost_center_id == <cc_id> AND package.budget_cycle_id == <cycle_id>.
# If not, abort - ranking a package under a different CC silently misroutes the priority.

# 2. Check whether the target rank_position is already taken (so we can warn the user before 409s)
semantius call crud postgrestRequest '{"method":"GET","path":"/package_rankings?cost_center_id=eq.<cc_id>&budget_cycle_id=eq.<cycle_id>&rank_position=eq.<n>&select=id,decision_package_id"}'
# If a row exists, the user wanted an INSERT at this position. Either:
#   (a) shift the conflicting row(s) down by 1 first (multiple PATCHes, descending order to avoid 409),
#   (b) or PATCH the existing ranking row to a different rank.

# 3. Compose the label at call time
RANKING_LABEL="<cycle_name> / <cost_center_code> / #<rank_position> <package_title>"

# 4. Insert
semantius call crud postgrestRequest '{
  "method":"POST",
  "path":"/package_rankings",
  "body":{
    "ranking_label":"<composed RANKING_LABEL>",
    "cost_center_id":"<cc_id>",
    "budget_cycle_id":"<cycle_id>",
    "decision_package_id":"<package_id>",
    "rank_position":3,
    "rationale":"<optional text>"
  }
}'
```

**Validation:**
- The new row exists; `(cc, cycle, rank)` triple is unique.
- `ranking_label` reflects the looked-up cycle name, CC code, position, and package title.
- The ranked package's `cost_center_id` and `budget_cycle_id` match the ranking's.

**Failure modes:**
- *409 on `(cost_center_id, budget_cycle_id, rank_position)`* -> the rank is already taken. Choose: (a) shift conflicting rows down (PATCH each in descending order to avoid intermediate collisions), (b) PATCH the existing row to a different position, or (c) ask the user.
- *409 on `(cost_center_id, budget_cycle_id, decision_package_id)`* -> this package is already ranked in this cycle. PATCH the existing row instead of inserting.
- *Cross-FK mismatch* (ranking's CC != package's CC) -> abort and surface the discrepancy. Likely an id mix-up; do not "fix" by writing.

---

### Assign a user to a cost center role

**Triggers:** `"assign Jane as approver on CC-1001"`, `"add Bob as reviewer for engineering"`, `"make Alice the controller for finance"`, `"set the primary owner for CC-2002"`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `cost_center_id` | yes | resolve via `cost_center_code` |
| `user_id` | yes | resolve via `user_email` |
| `assignment_role` | yes | one of `owner`, `reviewer`, `approver`, `controller` |
| `assignment_label` | yes | **caller-populated**; compose from related rows (see below) |
| `is_primary` | optional | by convention one primary per `(cost_center, role)` |
| `valid_from`, `valid_to` | optional | overlap is permitted (§6.2 open) |

**No DB-level uniqueness on `(user_id, cost_center_id, assignment_role)`.**
Recipes must read-before-insert to avoid silent duplicates. The model's
§6.2 leaves overlap-vs-uniqueness as an open question, so for now: dedupe
on the natural triple before inserting; if the user explicitly wants a
second concurrent assignment (e.g. an interim approver), confirm first.

**Caller-populated label rule (from the model's §7.7):**
`assignment_label = "{user.display_name} | {assignment_role capitalized} | {cost_center.cost_center_code}"`
Example: `"Jane Doe | Approver | CC-1001"`.

**Recipe:**

```bash
# 1. Resolve user and cost center
semantius call crud postgrestRequest '{"method":"GET","path":"/users?user_email=eq.jane@example.com&select=id,display_name"}'
semantius call crud postgrestRequest '{"method":"GET","path":"/cost_centers?cost_center_code=eq.CC-1001&select=id,cost_center_code"}'

# 2. Dedupe-before-insert on (user_id, cost_center_id, assignment_role)
semantius call crud postgrestRequest '{"method":"GET","path":"/cost_center_assignments?user_id=eq.<user_id>&cost_center_id=eq.<cc_id>&assignment_role=eq.approver&select=id,is_primary,valid_from,valid_to"}'
# If a matching active row exists, do NOT POST a duplicate. Either PATCH the existing row
# (e.g. to bump valid_to) or report "already assigned" to the user.

# 3. Compose label at call time
ASSIGN_LABEL="<user display_name> | <Role capitalized> | <cost_center_code>"

# 4. Insert
semantius call crud postgrestRequest '{
  "method":"POST",
  "path":"/cost_center_assignments",
  "body":{
    "assignment_label":"<composed ASSIGN_LABEL>",
    "cost_center_id":"<cc_id>",
    "user_id":"<user_id>",
    "assignment_role":"approver",
    "is_primary":true,
    "valid_from":"<today YYYY-MM-DD or omit>"
  }
}'
# `valid_from` (and `valid_to`): render at call time; do not copy the example values.
```

**Validation:**
- Exactly one new row exists for the `(user, cc, role)` triple.
- `assignment_label` reflects the looked-up user name, role, and CC code.
- If `is_primary=true`, no other row for the same `(cc, role)` was previously primary, or the user explicitly wanted to take primacy.

**Failure modes:**
- *Duplicate triple already exists* -> do not insert; PATCH the existing row (renew dates, flip `is_primary`) or report "already assigned" depending on user intent.
- *Multiple primaries on the same `(cc, role)`* -> the model permits it but it breaks routing. Before writing `is_primary=true`, GET existing primaries and PATCH them to `false` first, in the same logical operation.

---

## Common queries

Always run `cube discover '{}'` first to refresh the schema. Match the
dimension and measure names below against what `discover` returns, field
names drift when the model is regenerated, and `discover` is the source of
truth at query time.

```bash
# Total committed budget for a cycle (sum of selected funding levels' line items)
# Filter to packages with package_status=approved and a non-null selected_funding_level_id;
# join through funding_levels to cost_line_items.
semantius call cube load '{"query":{
  "measures":["cost_line_items.sum_total_cost_amount"],
  "dimensions":["budget_cycles.cycle_name"],
  "filters":[
    {"member":"decision_packages.package_status","operator":"equals","values":["approved"]},
    {"member":"funding_levels.id","operator":"set"},
    {"member":"budget_cycles.cycle_name","operator":"equals","values":["<cycle name at call time>"]}
  ]
}}'
```

```bash
# Package count by status, by cost center, by cycle
semantius call cube load '{"query":{
  "measures":["decision_packages.count"],
  "dimensions":["budget_cycles.cycle_name","cost_centers.cost_center_code","decision_packages.package_status"],
  "order":{"decision_packages.count":"desc"}
}}'
```

```bash
# Spend by cost category for a cycle (across all approved packages' selected levels)
semantius call cube load '{"query":{
  "measures":["cost_line_items.sum_total_cost_amount"],
  "dimensions":["cost_categories.category_name"],
  "filters":[
    {"member":"decision_packages.package_status","operator":"equals","values":["approved"]},
    {"member":"budget_cycles.cycle_name","operator":"equals","values":["<cycle name at call time>"]}
  ],
  "order":{"cost_line_items.sum_total_cost_amount":"desc"}
}}'
```

```bash
# Approval throughput: action count by type by week
semantius call cube load '{"query":{
  "measures":["approval_actions.count"],
  "dimensions":["approval_actions.action_type"],
  "timeDimensions":[{"dimension":"approval_actions.acted_at","granularity":"week","dateRange":"last 90 days"}]
}}'
```

```bash
# Top-ranked packages cycle-wide (ranks 1-3 from every cost center)
semantius call cube load '{"query":{
  "measures":["package_rankings.count"],
  "dimensions":["cost_centers.cost_center_code","decision_packages.package_title","package_rankings.rank_position"],
  "filters":[
    {"member":"package_rankings.rank_position","operator":"lte","values":["3"]},
    {"member":"budget_cycles.cycle_name","operator":"equals","values":["<cycle name at call time>"]}
  ],
  "order":{"cost_centers.cost_center_code":"asc","package_rankings.rank_position":"asc"}
}}'
```

---

## Guardrails

- Never PATCH `decision_packages.package_status` to `approved` without
  setting `selected_funding_level_id` AND `approved_at` in the same call,
  and without verifying the chosen level's `decision_package_id` matches
  the package id.
- Never insert `funding_levels` with `is_recommended_level=true` without
  first PATCHing any sibling rows for the same package back to `false`,
  the model permits multiple recommended levels at the DB layer but the
  submit JTBD refuses them.
- Never lock or archive a `budget_cycle` while any of its packages are
  `submitted` or `in_review`. Resolve those first.
- Never POST to `cost_center_assignments` without read-before-insert on
  `(user_id, cost_center_id, assignment_role)`, no DB-level uniqueness
  exists on that triple.
- Never compose a `ranking_label`, `action_label`, or `assignment_label`
  from hardcoded values, always look up the related rows at call time
  and assemble the string per the formula in each JTBD.
- Never set `selected_funding_level_id` on a `decision_package` to a
  funding level whose `decision_package_id` is anything other than this
  package's `id`. The DB does not enforce the cross-edge invariant.
- Never delete a `decision_packages` row directly. The model uses
  `restrict` on `approval_actions.decision_package_id` to preserve the
  audit trail; deletion will fail with a FK violation. Use `withdraw`
  on a `submitted` package instead, or leave terminal packages in place.
- Never POST to `users`, the platform built-in is reused; resolve
  existing user ids by email and reference them.

## What this skill does NOT do

- Schema changes, use `use-semantius` directly.
- RBAC / permissions, use `use-semantius` directly.
- One-off seed data, write a script, do not bake it into a JTBD.
- CSV / Excel bulk import of packages or line items, no webhook receivers
  are declared in the model; see `use-semantius` `references/webhook-import.md`
  if you need to set one up first.
- Cross-cost-center scopes (cross-functional initiatives, shared services
  across multiple cost centers).
- Multi-currency consolidation with FX rates (currency is currently a
  free-text ISO 4217 string on funding levels and line items).
- Justification supporting evidence (vendor quotes, slide decks),
  attachments are not modeled.
- Prior-period actuals or variance analysis, those live in upstream /
  downstream finance systems.
- Denormalized roll-up snapshots on `funding_levels`, totals are derived
  from `cost_line_items` at query time via the cube layer.
- Multi-scope rankings (corporate or function-level roll-ups), rankings
  are scoped to a single cost center.
