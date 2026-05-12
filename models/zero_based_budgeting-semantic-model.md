---
artifact: semantic-model
version: "1.7"
system_name: Zero-Based Budgeting
system_description: Bottom-Up Budget Planning
system_slug: zero_based_budgeting
domain: Budgeting
naming_mode: agent-optimized
created_at: 2026-05-10
entities:
  - budget_cycles
  - cost_centers
  - decision_packages
  - funding_levels
  - cost_line_items
  - cost_categories
  - gl_accounts
  - cost_drivers
  - package_rankings
  - approval_actions
  - users
  - cost_center_assignments
related_domains:
  - ERP
  - FP&A
  - Procurement
  - Vendor Management
  - HRIS
  - Workforce Planning
  - Identity & Access
  - OKR
  - Project Management
departments:
  - Finance
initial_request: |
  we want to switch to Zero-Based Budgeting
---

# Zero-Based Budgeting, Semantic Model

## 1. Overview

A budgeting platform implementing Peter Pyhrr's Zero-Based Budgeting methodology: every cost-center owner rebuilds their budget from zero each cycle by submitting decision packages (discrete activities or expenditures), each with multiple funding levels (minimum, current, enhanced) and a granular cost breakdown. Packages are ranked within their cost center, reviewed through an explicit approval workflow, and the chosen funding level becomes the funded amount.

## 2. Entity summary

| # | Table name | Singular label | Purpose |
|---|---|---|---|
| 1 | `budget_cycles` | Budget Cycle | The planning period (e.g. FY26) over which budgets are rebuilt from zero |
| 2 | `cost_centers` | Cost Center | Org unit responsible for justifying its own budget (the ZBB "decision unit") |
| 3 | `decision_packages` | Decision Package | A discrete activity, service, or expenditure being justified (the atomic unit of ZBB) |
| 4 | `funding_levels` | Funding Level | A service-level option for a package (minimum / current / enhanced) with its own cost and benefit |
| 5 | `cost_line_items` | Cost Line Item | Granular cost row inside a funding level (e.g. salaries, software, travel) |
| 6 | `cost_categories` | Cost Category | Taxonomy of cost types (Salary, Contractor, Software, Travel, Capex, ...) |
| 7 | `gl_accounts` | GL Account | Chart-of-accounts entry linking cost lines to the general ledger |
| 8 | `cost_drivers` | Cost Driver | Quantitative driver reusable across line items (FTE count, transaction volume, square footage) |
| 9 | `package_rankings` | Package Ranking | Priority ordering of packages within a cost center, scoped to a cycle |
| 10 | `approval_actions` | Approval Action | Audit-trail entry for a review decision on a package |
| 11 | `users` | User | A person who owns, reviews, or approves packages |
| 12 | `cost_center_assignments` | Cost Center Assignment | Junction: which user holds which role on which cost center |

### Entity-relationship diagram

```mermaid
flowchart LR
    budget_cycles -->|scopes| decision_packages
    budget_cycles -->|scopes| package_rankings
    cost_centers -->|parent of| cost_centers
    cost_centers -->|owns| decision_packages
    cost_centers -->|staffs| cost_center_assignments
    cost_centers -->|prioritizes| package_rankings
    users -->|owns| cost_centers
    users -->|owns| decision_packages
    users -->|performs| approval_actions
    users -->|fills| cost_center_assignments
    decision_packages -->|offers| funding_levels
    funding_levels ---|funds| decision_packages
    decision_packages -->|tracks| approval_actions
    decision_packages -->|ranked in| package_rankings
    funding_levels -->|itemizes| cost_line_items
    funding_levels -->|evaluated in| approval_actions
    cost_categories -->|categorizes| cost_line_items
    cost_categories -->|parent of| cost_categories
    gl_accounts -->|aggregates| cost_line_items
    gl_accounts -->|parent of| gl_accounts
    cost_drivers -->|drives| cost_line_items
```

## 3. Entities

### 3.1 `budget_cycles`, Budget Cycle

**Plural label:** Budget Cycles
**Label column:** `cycle_name`
**Audit log:** yes
**Description:** A planning period (typically annual) during which cost centers rebuild their budgets from zero. The cycle bounds all packages, rankings, and approvals.

**Fields**

| Field name | Format | Required | Label | Reference / Notes |
|---|---|---|---|---|
| `cycle_name` | `string` | yes | Cycle Name | (label) e.g. "FY26 ZBB Cycle"; default: `""` |
| `fiscal_year` | `integer` | yes | Fiscal Year | e.g. 2026; default: `0` |
| `start_date` | `date` | yes | Start Date | |
| `end_date` | `date` | yes | End Date | |
| `cycle_status` | `enum` | yes | Status | values: `draft`, `planning`, `in_review`, `locked`, `archived`; default: `"draft"` |
| `description` | `text` | no | Description | |

**Relationships**

- A `budget_cycle` may scope many `decision_packages` (1:N, via `decision_packages.budget_cycle_id`).
- A `budget_cycle` may scope many `package_rankings` (1:N, via `package_rankings.budget_cycle_id`).

**Validation rules**

```json
[
  {
    "code": "cycle_dates_ordered",
    "message": "Cycle start date must be on or before end date.",
    "description": "The planning period must have a non-negative duration.",
    "jsonlogic": { "<=": [{ "var": "start_date" }, { "var": "end_date" }] }
  },
  {
    "code": "cycle_archived_is_terminal",
    "message": "A cycle that has been archived cannot return to an earlier status.",
    "description": "Once archived, the cycle is closed for further editing; reopening would silently invalidate downstream FP&A and ERP feeds.",
    "jsonlogic": {
      "or": [
        { "==": [{ "var": "$old" }, null] },
        { "!=": [{ "var": "$old.cycle_status" }, "archived"] },
        { "==": [{ "var": "cycle_status" }, "archived"] }
      ]
    }
  }
]
```

---

### 3.2 `cost_centers`, Cost Center

**Plural label:** Cost Centers
**Label column:** `cost_center_name`
**Audit log:** yes
**Description:** An organizational unit (department, function, team) accountable for justifying its own budget. In ZBB language this is the "decision unit". Hierarchical via `parent_cost_center_id`.

**Fields**

| Field name | Format | Required | Label | Reference / Notes |
|---|---|---|---|---|
| `cost_center_code` | `string` | yes | Code | unique, e.g. "CC-1001"; no safe default, see §8 |
| `cost_center_name` | `string` | yes | Name | (label); default: `""` |
| `parent_cost_center_id` | `reference` | no | Parent Cost Center | → `cost_centers` (N:1, self-ref hierarchy, clear on delete), relationship_label: `"parent of"` |
| `owner_user_id` | `reference` | no | Primary Owner | → `users` (N:1, clear on delete), relationship_label: `"owns"` |
| `gl_segment` | `string` | no | GL Segment | optional ERP linkage |
| `is_active` | `boolean` | yes | Active | default: `true` |

**Relationships**

- A `cost_center` may have a parent `cost_center` (N:1, self-referential).
- A `cost_center` may have a primary owner `user` (N:1).
- A `cost_center` owns many `decision_packages` (1:N, via `decision_packages.cost_center_id`, reference, restrict on delete).
- A `cost_center` has many `cost_center_assignments` (1:N, parent, cascade on delete).
- A `cost_center` has many `package_rankings` (1:N, parent, cascade on delete).

---

### 3.3 `decision_packages`, Decision Package

**Plural label:** Decision Packages
**Label column:** `package_title`
**Audit log:** yes
**Description:** The atomic unit of ZBB: a discrete activity, service, or expenditure being justified from zero. Every package is owned by a cost center, scoped to a cycle, broken into 2+ funding levels, and moves through an approval workflow.

**Fields**

| Field name | Format | Required | Label | Reference / Notes |
|---|---|---|---|---|
| `package_code` | `string` | yes | Code | unique, e.g. "PKG-FY26-001"; no safe default, see §8 |
| `package_title` | `string` | yes | Title | (label); default: `""` |
| `cost_center_id` | `reference` | yes | Cost Center | → `cost_centers` (N:1, restrict on delete), relationship_label: `"owns"` |
| `budget_cycle_id` | `reference` | yes | Budget Cycle | → `budget_cycles` (N:1, restrict on delete), relationship_label: `"scopes"` |
| `package_type` | `enum` | yes | Package Type | values: `continuing`, `new`, `discretionary`, `mandatory`; default: `"continuing"` |
| `priority_tier` | `enum` | no | Priority Tier | values: `must_have`, `should_have`, `nice_to_have` |
| `package_status` | `enum` | yes | Status | values: `draft`, `submitted`, `in_review`, `approved`, `rejected`, `cut`, `deferred`; default: `"draft"` |
| `business_justification` | `html` | yes | Business Justification | the "why" narrative, core ZBB artifact; default: `""` |
| `consequences_of_not_funding` | `html` | no | Consequences if Not Funded | what breaks if killed |
| `alternatives_considered` | `html` | no | Alternatives Considered | |
| `selected_funding_level_id` | `reference` | no | Selected Funding Level | → `funding_levels` (N:1, clear on delete); set after approval, relationship_label: `"funds"` |
| `owner_user_id` | `reference` | yes | Package Owner | → `users` (N:1, restrict on delete), relationship_label: `"owns"` |
| `submitted_at` | `date-time` | no | Submitted At | set once the package leaves draft |
| `approved_at` | `date-time` | no | Approved At | set once the package is approved or cut |

**Relationships**

- A `decision_package` belongs to one `cost_center` (N:1, reference, restrict on delete to preserve the package if a cost center is dissolved).
- A `decision_package` is scoped to one `budget_cycle` (N:1, required).
- A `decision_package` is owned by one `user` (N:1, required).
- A `decision_package` has many `funding_levels` (1:N, parent, cascade on delete).
- A `decision_package` may select one of its `funding_levels` as the funded option (N:1, via `selected_funding_level_id`, clear on delete). Circular reference with the parent edge above; `selected_funding_level_id.decision_package_id` must equal `this.id`.
- A `decision_package` has many `approval_actions` (1:N, reference, restrict on delete to preserve audit trail).
- A `decision_package` may appear in many `package_rankings` (1:N).

**Validation rules**

```json
[
  {
    "code": "package_status_is_one_way",
    "message": "A package that has reached a terminal status cannot return to an earlier state.",
    "description": "Terminal statuses (approved, rejected, cut, deferred) record an outcome; transitions back would silently invalidate downstream POs, projects, and audit history. See §7.2 for whether any of these should be reversible.",
    "jsonlogic": {
      "or": [
        { "==": [{ "var": "$old" }, null] },
        { "in": [{ "var": "$old.package_status" }, ["draft", "submitted", "in_review"]] },
        { "==": [{ "var": "package_status" }, { "var": "$old.package_status" }] }
      ]
    }
  },
  {
    "code": "selected_funding_level_only_when_funded",
    "message": "A selected funding level can only be set once the package is approved or cut.",
    "description": "The selected funding level represents the committed funding decision; it must not be set before the package has been actioned.",
    "jsonlogic": {
      "or": [
        { "==": [{ "var": "selected_funding_level_id" }, null] },
        { "in": [{ "var": "package_status" }, ["approved", "cut"]] }
      ]
    }
  },
  {
    "code": "selected_funding_level_required_when_funded",
    "message": "An approved or cut package must record the selected funding level.",
    "description": "Paired with selected_funding_level_only_when_funded: a funding outcome is incomplete without the level it commits to.",
    "jsonlogic": {
      "or": [
        { "in": [{ "var": "package_status" }, ["draft", "submitted", "in_review", "rejected", "deferred"]] },
        { "!=": [{ "var": "selected_funding_level_id" }, null] }
      ]
    }
  },
  {
    "code": "submitted_at_only_after_submit",
    "message": "Submitted-at timestamp can only be set once the package leaves draft.",
    "description": "Draft packages have not yet been submitted; recording a submission timestamp before submit is incoherent.",
    "jsonlogic": {
      "or": [
        { "==": [{ "var": "submitted_at" }, null] },
        { "!=": [{ "var": "package_status" }, "draft"] }
      ]
    }
  },
  {
    "code": "submitted_at_required_after_submit",
    "message": "A non-draft package must record the submitted-at timestamp.",
    "description": "Paired with submitted_at_only_after_submit: leaving the draft stage means submission happened; the timestamp must exist.",
    "jsonlogic": {
      "or": [
        { "==": [{ "var": "package_status" }, "draft"] },
        { "!=": [{ "var": "submitted_at" }, null] }
      ]
    }
  },
  {
    "code": "approved_at_only_when_funded",
    "message": "Approval timestamp can only be set on approved or cut packages.",
    "description": "Approved-at marks the funding decision; setting it on rejected or deferred packages misrepresents the outcome.",
    "jsonlogic": {
      "or": [
        { "==": [{ "var": "approved_at" }, null] },
        { "in": [{ "var": "package_status" }, ["approved", "cut"]] }
      ]
    }
  },
  {
    "code": "approved_at_required_when_funded",
    "message": "An approved or cut package must record the approval timestamp.",
    "description": "Paired with approved_at_only_when_funded: a funding decision is incomplete without the date it was made.",
    "jsonlogic": {
      "or": [
        { "in": [{ "var": "package_status" }, ["draft", "submitted", "in_review", "rejected", "deferred"]] },
        { "!=": [{ "var": "approved_at" }, null] }
      ]
    }
  }
]
```

---

### 3.4 `funding_levels`, Funding Level

**Plural label:** Funding Levels
**Label column:** `funding_level_label`
**Audit log:** yes
**Description:** A service-level option for a decision package (typically minimum / current / enhanced). Each level has its own cost stack and benefit narrative; the package owner recommends one and an approver selects one.

**Fields**

| Field name | Format | Required | Label | Reference / Notes |
|---|---|---|---|---|
| `funding_level_label` | `string` | yes | Level Label | (label) e.g. "Minimum", "Current", "Enhanced +2 FTE"; default: `""` |
| `decision_package_id` | `parent` | yes | Decision Package | ↳ `decision_packages` (N:1, cascade on delete), relationship_label: `"offers"` |
| `level_tier` | `enum` | yes | Tier | values: `minimum`, `current`, `enhanced`, `custom`; default: `"minimum"` |
| `level_order` | `integer` | yes | Order | 1 = lowest, ascending; default: `1` |
| `is_recommended_level` | `boolean` | yes | Recommended by Owner | default: `false`; the owner picks one before submission |
| `headcount_fte` | `number` | no | Headcount (FTE) | total FTE at this level; precision: 2 |
| `currency_code` | `string` | yes | Currency | ISO 4217, e.g. "USD"; default: `"USD"` |
| `service_description` | `html` | yes | Service Description | what's delivered at this level; default: `""` |
| `benefit_narrative` | `html` | no | Incremental Benefit | benefit vs the next-lower level |
| `risk_narrative` | `html` | no | Risk if Chosen | |

**Relationships**

- A `funding_level` belongs to one `decision_package` (N:1, parent, cascade on delete).
- A `funding_level` has many `cost_line_items` (1:N, parent, cascade on delete).
- A `funding_level` may be referenced by many `approval_actions` (1:N, via `approval_actions.funding_level_id`, clear on delete).
- A `funding_level` may be the selected level on its parent `decision_package` (1:0..1, via `decision_packages.selected_funding_level_id`).

**Validation rules**

```json
[
  {
    "code": "level_order_positive",
    "message": "Funding-level order must be 1 or greater.",
    "description": "Level 1 is the lowest funding option; non-positive orders break the lifecycle ranking used by approval UIs.",
    "jsonlogic": { ">=": [{ "var": "level_order" }, 1] }
  },
  {
    "code": "headcount_fte_non_negative",
    "message": "Headcount FTE cannot be negative.",
    "description": "FTE counts represent labor demand; negative values are incoherent.",
    "jsonlogic": {
      "or": [
        { "==": [{ "var": "headcount_fte" }, null] },
        { ">=": [{ "var": "headcount_fte" }, 0] }
      ]
    }
  }
]
```

---

### 3.5 `cost_line_items`, Cost Line Item

**Plural label:** Cost Line Items
**Label column:** `line_item_label`
**Audit log:** yes
**Description:** A granular cost row inside a funding level, e.g. "Senior Engineer salaries (×2)", "Datadog enterprise license". Supports either driver-based input (quantity × unit_cost) or lump-sum entry; `total_cost_amount` is always the canonical roll-up figure, auto-derived from `quantity × unit_cost_amount` when both are set.

**Fields**

| Field name | Format | Required | Label | Reference / Notes |
|---|---|---|---|---|
| `line_item_label` | `string` | yes | Description | (label); default: `""` |
| `funding_level_id` | `parent` | yes | Funding Level | ↳ `funding_levels` (N:1, cascade on delete), relationship_label: `"itemizes"` |
| `cost_category_id` | `reference` | yes | Cost Category | → `cost_categories` (N:1, restrict on delete), relationship_label: `"categorizes"` |
| `gl_account_id` | `reference` | no | GL Account | → `gl_accounts` (N:1, clear on delete), relationship_label: `"aggregates"` |
| `cost_driver_id` | `reference` | no | Cost Driver | → `cost_drivers` (N:1, clear on delete), relationship_label: `"drives"` |
| `quantity` | `number` | no | Quantity | precision: 4; optional driver-based input, e.g. 2 (FTE) |
| `unit_cost_amount` | `number` | no | Unit Cost | precision: 2; paired with `quantity` for driver-based entry |
| `total_cost_amount` | `number` | yes | Total Cost | precision: 2; canonical roll-up figure, computed from `quantity × unit_cost_amount` when both are set; default: `0` |
| `currency_code` | `string` | yes | Currency | ISO 4217; default: `"USD"` |
| `cost_period` | `enum` | yes | Period | values: `one_time`, `recurring_annual`; default: `"one_time"` |
| `notes` | `text` | no | Notes | |

**Relationships**

- A `cost_line_item` belongs to one `funding_level` (N:1, parent, cascade on delete).
- A `cost_line_item` belongs to one `cost_category` (N:1, required, restrict on delete).
- A `cost_line_item` may map to one `gl_account` (N:1, optional).
- A `cost_line_item` may be driven by one `cost_driver` (N:1, optional).

**Computed fields**

```json
[
  {
    "name": "total_cost_amount",
    "description": "When both quantity and unit_cost_amount are set, total_cost_amount = quantity × unit_cost_amount; otherwise pass through the caller-supplied value (lump-sum entry).",
    "jsonlogic": {
      "if": [
        {
          "and": [
            { "!=": [{ "var": "quantity" }, null] },
            { "!=": [{ "var": "unit_cost_amount" }, null] }
          ]
        },
        { "*": [{ "var": "quantity" }, { "var": "unit_cost_amount" }] },
        { "var": "total_cost_amount" }
      ]
    }
  }
]
```

**Validation rules**

```json
[
  {
    "code": "quantity_non_negative",
    "message": "Quantity cannot be negative.",
    "description": "Quantity drives cost roll-ups; negative values would silently subtract from the funding level total.",
    "jsonlogic": {
      "or": [
        { "==": [{ "var": "quantity" }, null] },
        { ">=": [{ "var": "quantity" }, 0] }
      ]
    }
  },
  {
    "code": "unit_cost_non_negative",
    "message": "Unit cost amount cannot be negative.",
    "description": "Unit cost is a monetary input; negative values would invert the roll-up.",
    "jsonlogic": {
      "or": [
        { "==": [{ "var": "unit_cost_amount" }, null] },
        { ">=": [{ "var": "unit_cost_amount" }, 0] }
      ]
    }
  },
  {
    "code": "total_cost_non_negative",
    "message": "Total cost amount cannot be negative.",
    "description": "Total cost is the canonical roll-up figure; negative values are incoherent.",
    "jsonlogic": { ">=": [{ "var": "total_cost_amount" }, 0] }
  },
  {
    "code": "quantity_unit_cost_mutual",
    "message": "Quantity and unit cost must be set together (or both left empty for lump-sum entry).",
    "description": "Driver-based input requires both columns to compose a credible cost-build; one without the other suggests partial data entry.",
    "jsonlogic": {
      "or": [
        {
          "and": [
            { "==": [{ "var": "quantity" }, null] },
            { "==": [{ "var": "unit_cost_amount" }, null] }
          ]
        },
        {
          "and": [
            { "!=": [{ "var": "quantity" }, null] },
            { "!=": [{ "var": "unit_cost_amount" }, null] }
          ]
        }
      ]
    }
  }
]
```

---

### 3.6 `cost_categories`, Cost Category

**Plural label:** Cost Categories
**Label column:** `category_name`
**Audit log:** no
**Description:** Taxonomy of cost types used to classify line items (Salary, Contractor, Software, Travel, Capex, etc.). Hierarchical via `parent_category_id` so categories can roll up.

**Fields**

| Field name | Format | Required | Label | Reference / Notes |
|---|---|---|---|---|
| `category_code` | `string` | yes | Code | unique, e.g. "SALARY"; no safe default, see §8 |
| `category_name` | `string` | yes | Name | (label); default: `""` |
| `category_type` | `enum` | yes | Type | values: `opex`, `capex`, `mixed`; default: `"opex"` |
| `parent_category_id` | `reference` | no | Parent Category | → `cost_categories` (N:1, self-ref, clear on delete), relationship_label: `"parent of"` |

**Relationships**

- A `cost_category` may have a parent `cost_category` (N:1, self-referential).
- A `cost_category` may classify many `cost_line_items` (1:N).

---

### 3.7 `gl_accounts`, GL Account

**Plural label:** GL Accounts
**Label column:** `account_name`
**Audit log:** no
**Description:** Chart-of-accounts entry that links ZBB cost line items back to the general ledger. Hierarchical (parent/child accounts).

**Fields**

| Field name | Format | Required | Label | Reference / Notes |
|---|---|---|---|---|
| `account_code` | `string` | yes | Code | unique, e.g. "5100"; no safe default, see §8 |
| `account_name` | `string` | yes | Name | (label) e.g. "Salaries Expense"; default: `""` |
| `account_type` | `enum` | yes | Type | values: `asset`, `liability`, `equity`, `revenue`, `expense`, `contra`; default: `"expense"` |
| `parent_account_id` | `reference` | no | Parent Account | → `gl_accounts` (N:1, self-ref, clear on delete), relationship_label: `"parent of"` |

**Relationships**

- A `gl_account` may have a parent `gl_account` (N:1, self-referential).
- A `gl_account` may aggregate many `cost_line_items` (1:N).

---

### 3.8 `cost_drivers`, Cost Driver

**Plural label:** Cost Drivers
**Label column:** `driver_name`
**Audit log:** no
**Description:** A reusable quantitative driver of cost, e.g. headcount, transaction volume, square footage. Cost line items can reference a driver to make the cost-build transparent and easy to flex.

**Fields**

| Field name | Format | Required | Label | Reference / Notes |
|---|---|---|---|---|
| `driver_code` | `string` | yes | Code | unique, e.g. "FTE_COUNT"; no safe default, see §8 |
| `driver_name` | `string` | yes | Name | (label) e.g. "Full-Time Equivalents"; default: `""` |
| `unit_of_measure` | `string` | yes | Unit | e.g. "headcount", "transactions/month"; default: `""` |
| `current_value` | `number` | no | Current Value | precision: 4; most recent quantity or per-unit rate |
| `description` | `text` | no | Description | |

**Relationships**

- A `cost_driver` may drive many `cost_line_items` (1:N).

**Validation rules**

```json
[
  {
    "code": "current_value_non_negative",
    "message": "Driver current value cannot be negative.",
    "description": "Cost drivers represent quantities, rates, or volumes; negative values are not meaningful in any of those.",
    "jsonlogic": {
      "or": [
        { "==": [{ "var": "current_value" }, null] },
        { ">=": [{ "var": "current_value" }, 0] }
      ]
    }
  }
]
```

---

### 3.9 `package_rankings`, Package Ranking

**Plural label:** Package Rankings
**Label column:** `ranking_label`
**Audit log:** yes
**Description:** A prioritization entry: within a cost center and cycle, this row says "package X is ranked at position Y". Used by the cost-center owner during the ZBB ranking ceremony and by finance during roll-up reviews.

**Fields**

| Field name | Format | Required | Label | Reference / Notes |
|---|---|---|---|---|
| `ranking_label` | `string` | yes | Ranking | (label) caller composes on insert, e.g. "FY26 / CC-1001 / #3 K8s Migration"; default: `""` |
| `cost_center_id` | `parent` | yes | Cost Center | ↳ `cost_centers` (N:1, cascade on delete); the scope of this ranking, relationship_label: `"prioritizes"` |
| `budget_cycle_id` | `reference` | yes | Budget Cycle | → `budget_cycles` (N:1, restrict on delete), relationship_label: `"scopes"` |
| `decision_package_id` | `parent` | yes | Decision Package | ↳ `decision_packages` (N:1, cascade on delete), relationship_label: `"ranked in"` |
| `rank_position` | `integer` | yes | Rank | 1 = highest priority; default: `1` |
| `rationale` | `text` | no | Rationale | |

> Composite uniqueness expected on `(cost_center_id, budget_cycle_id, rank_position)` and `(cost_center_id, budget_cycle_id, decision_package_id)`. Field-level `unique_value` does not cover composite tuples; the implementer enforces via DB constraint or application logic, see §8.

**Relationships**

- A `package_ranking` belongs to one `cost_center` (N:1, parent, cascade on delete). Junction-style: the row is meaningless without its cost_center.
- A `package_ranking` is scoped to one `budget_cycle` (N:1, reference, restrict on delete).
- A `package_ranking` ranks one `decision_package` (N:1, parent, cascade on delete). Junction-style: the row is meaningless without its decision_package.

**Validation rules**

```json
[
  {
    "code": "rank_position_positive",
    "message": "Rank position must be 1 or greater.",
    "description": "Position 1 is the highest priority; non-positive positions break the ranking ceremony semantics.",
    "jsonlogic": { ">=": [{ "var": "rank_position" }, 1] }
  }
]
```

---

### 3.10 `approval_actions`, Approval Action

**Plural label:** Approval Actions
**Label column:** `action_label`
**Audit log:** yes
**Description:** A single review event on a decision package: submission, approval, rejection, cut to a lower funding level, deferral. The full sequence of `approval_actions` for a package is the audit trail of how the package moved through governance.

**Fields**

| Field name | Format | Required | Label | Reference / Notes |
|---|---|---|---|---|
| `action_label` | `string` | yes | Action | (label) caller composes on insert, e.g. "Approve · Jane Doe · 2026-04-15"; default: `""` |
| `decision_package_id` | `reference` | yes | Decision Package | → `decision_packages` (N:1, restrict on delete to preserve audit trail), relationship_label: `"tracks"` |
| `funding_level_id` | `reference` | no | Funding Level | → `funding_levels` (N:1, clear on delete); level approved or cut to, relationship_label: `"evaluated in"` |
| `actor_user_id` | `reference` | yes | Actor | → `users` (N:1, restrict on delete), relationship_label: `"performs"` |
| `action_type` | `enum` | yes | Action Type | values: `submit`, `approve`, `reject`, `cut`, `defer`, `request_changes`, `withdraw`; default: `"submit"` |
| `comment` | `text` | no | Comment | |
| `acted_at` | `date-time` | yes | Acted At | default: `CURRENT_TIMESTAMP` |

**Relationships**

- An `approval_action` belongs to one `decision_package` (N:1, reference, restrict on delete).
- An `approval_action` may reference one `funding_level` (N:1).
- An `approval_action` is performed by one `user` (N:1, required).

**Validation rules**

```json
[
  {
    "code": "funding_level_only_when_funding_action",
    "message": "Funding level can only be referenced on approve or cut actions.",
    "description": "Submit, reject, defer, request_changes, and withdraw don't commit to a funding level; setting one misrepresents the action.",
    "jsonlogic": {
      "or": [
        { "==": [{ "var": "funding_level_id" }, null] },
        { "in": [{ "var": "action_type" }, ["approve", "cut"]] }
      ]
    }
  },
  {
    "code": "funding_level_required_when_funding_action",
    "message": "Approve and cut actions must reference the funding level being committed to.",
    "description": "Paired with funding_level_only_when_funding_action: an approve or cut without a target level is an incomplete audit record.",
    "jsonlogic": {
      "or": [
        { "in": [{ "var": "action_type" }, ["submit", "reject", "defer", "request_changes", "withdraw"]] },
        { "!=": [{ "var": "funding_level_id" }, null] }
      ]
    }
  },
  {
    "code": "acted_at_not_future",
    "message": "Acted-at timestamp cannot be in the future.",
    "description": "Approval actions record past events; a future timestamp suggests a clock error or fabricated entry.",
    "jsonlogic": { "<=": [{ "var": "acted_at" }, { "var": "$now" }] }
  }
]
```

---

### 3.11 `users`, User

**Plural label:** Users
**Label column:** `display_name`
**Audit log:** no
**Description:** A person who owns, reviews, or approves decision packages. The `table_name: users` matches the Semantius built-in exactly so the deployer can deduplicate against the platform user table.

**Fields**

| Field name | Format | Required | Label | Reference / Notes |
|---|---|---|---|---|
| `user_email` | `email` | yes | Email | unique, no safe default, see §8 |
| `display_name` | `string` | yes | Display Name | (label) e.g. "Jane Doe"; default: `""` |
| `is_active` | `boolean` | yes | Active | default: `true` |
| `department` | `string` | no | Department | |
| `job_title` | `string` | no | Job Title | |

**Relationships**

- A `user` may own many `cost_centers` (1:N, via `cost_centers.owner_user_id`).
- A `user` may own many `decision_packages` (1:N, via `decision_packages.owner_user_id`).
- A `user` may perform many `approval_actions` (1:N, via `approval_actions.actor_user_id`).
- A `user` may have many `cost_center_assignments` (1:N).

---

### 3.12 `cost_center_assignments`, Cost Center Assignment

**Plural label:** Cost Center Assignments
**Label column:** `assignment_label`
**Audit log:** no
**Description:** Junction entity that captures which user holds which ZBB role on which cost center: owner, reviewer, approver, or controller. Drives package routing and review permissions during the cycle.

**Fields**

| Field name | Format | Required | Label | Reference / Notes |
|---|---|---|---|---|
| `assignment_label` | `string` | yes | Assignment | (label) caller composes on insert, e.g. "Jane Doe · Owner · CC-1001"; default: `""` |
| `cost_center_id` | `parent` | yes | Cost Center | ↳ `cost_centers` (N:1, cascade on delete), relationship_label: `"staffs"` |
| `user_id` | `parent` | yes | User | ↳ `users` (N:1, cascade on delete), relationship_label: `"fills"` |
| `assignment_role` | `enum` | yes | Role | values: `owner`, `reviewer`, `approver`, `controller`; default: `"owner"` |
| `is_primary` | `boolean` | no | Primary | one primary per (cost_center, role) by convention |
| `valid_from` | `date` | no | Valid From | |
| `valid_to` | `date` | no | Valid To | |

**Relationships**

- A `cost_center_assignment` belongs to one `cost_center` (N:1, parent, cascade on delete). Junction-style: the row is meaningless without its cost_center.
- A `cost_center_assignment` belongs to one `user` (N:1, parent, cascade on delete). Junction-style: the row is meaningless without its user.
- `cost_centers` ↔ `users` is many-to-many through this junction (with role).

**Validation rules**

```json
[
  {
    "code": "assignment_dates_ordered",
    "message": "Valid-from date must be on or before valid-to date.",
    "description": "An assignment's effective window must have a non-negative duration when both endpoints are set.",
    "jsonlogic": {
      "or": [
        { "==": [{ "var": "valid_from" }, null] },
        { "==": [{ "var": "valid_to" }, null] },
        { "<=": [{ "var": "valid_from" }, { "var": "valid_to" }] }
      ]
    }
  }
]
```

## 4. Relationship summary

| From | Field | To | Cardinality | Kind | Delete behavior |
|---|---|---|---|---|---|
| `cost_centers` | `parent_cost_center_id` | `cost_centers` | N:1 | reference | clear |
| `cost_centers` | `owner_user_id` | `users` | N:1 | reference | clear |
| `decision_packages` | `cost_center_id` | `cost_centers` | N:1 | reference | restrict |
| `decision_packages` | `budget_cycle_id` | `budget_cycles` | N:1 | reference | restrict |
| `decision_packages` | `selected_funding_level_id` | `funding_levels` | N:1 | reference | clear |
| `decision_packages` | `owner_user_id` | `users` | N:1 | reference | restrict |
| `funding_levels` | `decision_package_id` | `decision_packages` | N:1 | parent | cascade |
| `cost_line_items` | `funding_level_id` | `funding_levels` | N:1 | parent | cascade |
| `cost_line_items` | `cost_category_id` | `cost_categories` | N:1 | reference | restrict |
| `cost_line_items` | `gl_account_id` | `gl_accounts` | N:1 | reference | clear |
| `cost_line_items` | `cost_driver_id` | `cost_drivers` | N:1 | reference | clear |
| `cost_categories` | `parent_category_id` | `cost_categories` | N:1 | reference | clear |
| `gl_accounts` | `parent_account_id` | `gl_accounts` | N:1 | reference | clear |
| `package_rankings` | `cost_center_id` | `cost_centers` | N:1 | parent | cascade |
| `package_rankings` | `budget_cycle_id` | `budget_cycles` | N:1 | reference | restrict |
| `package_rankings` | `decision_package_id` | `decision_packages` | N:1 | parent | cascade |
| `approval_actions` | `decision_package_id` | `decision_packages` | N:1 | reference | restrict |
| `approval_actions` | `funding_level_id` | `funding_levels` | N:1 | reference | clear |
| `approval_actions` | `actor_user_id` | `users` | N:1 | reference | restrict |
| `cost_center_assignments` | `cost_center_id` | `cost_centers` | N:1 | parent | cascade |
| `cost_center_assignments` | `user_id` | `users` | N:1 | parent | cascade |

`cost_centers` ↔ `users` is many-to-many through `cost_center_assignments` (with `assignment_role`).

## 5. Enumerations

### 5.1 `budget_cycles.cycle_status`
- `draft`
- `planning`
- `in_review`
- `locked`
- `archived`

### 5.2 `decision_packages.package_type`
- `continuing`
- `new`
- `discretionary`
- `mandatory`

### 5.3 `decision_packages.priority_tier`
- `must_have`
- `should_have`
- `nice_to_have`

### 5.4 `decision_packages.package_status`
- `draft`
- `submitted`
- `in_review`
- `approved`
- `rejected`
- `cut`
- `deferred`

### 5.5 `funding_levels.level_tier`
- `minimum`
- `current`
- `enhanced`
- `custom`

### 5.6 `cost_line_items.cost_period`
- `one_time`
- `recurring_annual`

### 5.7 `cost_categories.category_type`
- `opex`
- `capex`
- `mixed`

### 5.8 `gl_accounts.account_type`
- `asset`
- `liability`
- `equity`
- `revenue`
- `expense`
- `contra`

### 5.9 `approval_actions.action_type`
- `submit`
- `approve`
- `reject`
- `cut`
- `defer`
- `request_changes`
- `withdraw`

### 5.10 `cost_center_assignments.assignment_role`
- `owner`
- `reviewer`
- `approver`
- `controller`

## 6. Cross-model link suggestions

| From | To | Verb | Cardinality | Delete |
|---|---|---|---|---|
| `cost_line_items` | `vendors` | supplies | N:1 | clear |
| `purchase_orders` | `decision_packages` | authorizes | N:1 | clear |
| `forecasts` | `budget_cycles` | anchors | N:1 | clear |
| `variance_analyses` | `decision_packages` | is analyzed in | N:1 | clear |
| `purchase_requisitions` | `decision_packages` | is requisitioned against | N:1 | clear |
| `cost_centers` | `departments` | groups | N:1 | clear |
| `position_requisitions` | `funding_levels` | authorizes | N:1 | clear |
| `decision_packages` | `objectives` | drives | N:1 | clear |
| `projects` | `decision_packages` | funds | N:1 | clear |

Per-domain coverage notes (deploy-time hints for the deployer's catalog walk):

- **ERP** contributes rows 1 (cost lines → vendors master) and 2 (POs back-reference the package they were authorized by). `gl_accounts` overlaps the canonical CoA master and is handled by the deployer's name-collision detection.
- **FP&A** contributes rows 3 (forecasts anchored to a cycle) and 4 (variance analyses tied to a package). `driver_libraries` may pair-overlap this model's `cost_drivers`; deployer dedups on name.
- **Procurement** contributes row 5. `purchase_orders` already covered under ERP; not double-listed.
- **Vendor Management** contributes no additional rows; its `vendors` target is covered by row 1.
- **HRIS** contributes row 6 (cost_centers map to HRIS departments). Position-side linkage deferred to Workforce Planning.
- **Workforce Planning** contributes row 7 (position requisitions authorized by a funding level's headcount ask).
- **Identity & Access** contributes no rows; `users` is pair-overlap-only and the sibling shape (`groups`, `team_memberships`, `sessions`) extends users upward rather than referencing into ZBB.
- **OKR** contributes row 8 (strategic alignment for discretionary packages).
- **Project Management** contributes row 9 (projects reference the package that funded them).

## 7. Open questions

### 7.1 🔴 Decisions needed (blockers)

None.

### 7.2 🟡 Future considerations (deferred scope)

- Should any of the four terminal `package_status` values (`approved`, `rejected`, `cut`, `deferred`) be reversible? The current model treats all four as one-way (rule `package_status_is_one_way`); common practice reopens `rejected` and `deferred` to `draft` for rework. If reopening is needed, narrow the terminal set in the JsonLogic to `["approved", "cut"]`.
- Should ZBB scopes that span multiple cost centers (cross-functional initiatives, shared services) be supported via a `cost_center_groups` entity, or is the current single-`cost_center_id` link on `decision_packages` sufficient?
- Should `currency_code` be promoted to its own `currencies` entity with FX rates, to support multi-currency budget consolidation? Currently a free-text ISO 4217 string on `funding_levels` and `cost_line_items`.
- Should justification supporting evidence (spreadsheets, vendor quotes, slide decks) be modeled via an `attachments` entity, or kept in an external document store?
- Should prior-period actuals be loaded into the model for variance reporting, or always pulled from upstream finance systems at query time? (ZBB de-emphasizes prior periods, but reviewers often want the comparison.)
- Should funding-level cost roll-ups be stored as denormalized snapshots on `funding_levels` (for performance) or always derived from `cost_line_items` at query time?
- Should rankings be expressible at multiple scopes (cost center → function → corporate), via a `ranking_scope` enum and an optional roll-up parent ID, or stay scoped to cost centers only with corporate roll-up handled in the reporting layer?
- Should `cost_center_assignments` enforce a single concurrent assignment per (user, cost_center, role) via `valid_from`/`valid_to`, or permit overlapping assignments? Currently the date fields are optional.
- Does `decision_packages.priority_tier` (owner's coarse must/should/nice bucket) overlap with `package_rankings.rank_position` (cost-center-wide ordering) in a way that confuses users? Drop `priority_tier`, drop `package_rankings`, or keep both as different lenses?
- Should `cost_drivers` be split into `cost_drivers` + `driver_values` (per-cycle history) so drivers can evolve over time, or is the current single-snapshot shape sufficient?
- Should `package_metrics` (quantified KPIs / deliverables per funding level) be a structured entity, or stay folded into `funding_levels.benefit_narrative` HTML?
- Should `approval_actions` permit future-dated `acted_at` for scheduled approvals (auto-approve after deadline), or stay strictly past-only as the rule `acted_at_not_future` enforces?

## 8. Implementation notes for the downstream agent

A short checklist for the agent who will materialize this model in Semantius (or equivalent):

1. Create one module named `zero_based_budgeting` (the module name **must** equal the `system_slug` from the front-matter; do not invent a different slug here) and two baseline permissions (`zero_based_budgeting:read`, `zero_based_budgeting:manage`) before any entity.
2. Create entities in the order given in §2, entities referenced by others first. The circular reference between `decision_packages.selected_funding_level_id` and `funding_levels.decision_package_id` requires a two-pass approach: create both entities, then add `decision_packages.selected_funding_level_id` after `funding_levels` exists.
3. For each entity: set `label_column` to the snake_case field marked as label in §3, pass `module_id`, `view_permission`, `edit_permission`. Pass the `computed_fields` and `validation_rules` arrays from §3 verbatim into `create_entity` so the platform compiles them into BEFORE INSERT/UPDATE triggers. Do **not** manually create `id`, `created_at`, `updated_at`, or the auto-label field.
4. For each field in §3: pass `table_name`, `field_name`, `format`, `title` (the Label column), and for `reference`/`parent` fields also `reference_table`, `reference_delete_mode` consistent with §4, and `relationship_label` set to the verb annotated in the §3 Notes column (which matches the §2 Mermaid edge label byte-for-byte). For required fields with a `default:` annotation in §3, pass that value as `default_value` so Postgres can backfill existing rows when the column is added. (The §3 `Required` column is analyst intent; the platform manages nullability internally and does not need a per-field flag.)
5. **Fix up each entity's auto-created label-column field title.** `create_entity` auto-creates a field whose `field_name` equals the entity's `label_column`, and its `title` defaults to `singular_label`. Every entity in this model has a label_column whose §3 Label differs from `singular_label` (e.g. entity `cost_centers` would yield title "Cost Center" but we want "Name"). After each `create_entity` call, follow up with `update_field` to set the correct title. The `update_field` `id` is the **composite string** `"{table_name}.{field_name}"` (e.g. `"cost_centers.cost_center_name"`, `"decision_packages.package_title"`, `"funding_levels.funding_level_label"`); **pass it as a string, not an integer**, or the update will fail. The full list of fixups:
   - `budget_cycles.cycle_name` → "Cycle Name"
   - `cost_centers.cost_center_name` → "Name"
   - `decision_packages.package_title` → "Title"
   - `funding_levels.funding_level_label` → "Level Label"
   - `cost_line_items.line_item_label` → "Description"
   - `cost_categories.category_name` → "Name"
   - `gl_accounts.account_name` → "Name"
   - `cost_drivers.driver_name` → "Name"
   - `package_rankings.ranking_label` → "Ranking"
   - `approval_actions.action_label` → "Action"
   - `users.display_name` → "Display Name"
   - `cost_center_assignments.assignment_label` → "Assignment"
6. **Deduplicate against Semantius built-in tables.** This model is self-contained and declares `users`, which exists in Semantius as a built-in. For each declared entity, read Semantius first: if a built-in already covers it, **skip the create** and reuse the built-in as the `reference_table` target; do not attempt to recreate. Optionally add the model's required fields (`display_name`, `is_active`, `department`, `job_title`) to the built-in only if they are missing (additive, low-risk changes only). The same posture applies if `ERP`, `FP&A`, `Procurement`, `Vendor Management`, `HRIS`, `Workforce Planning`, `OKR`, or `Project Management` sibling modules are deployed alongside and own canonical `gl_accounts`, `cost_centers`, or other shared-master entities: skip the local create, rewire FKs to the sibling target.
7. **Apply §6 cross-model link suggestions.** Walk each row, look up the `To` concept in the live catalog. When the target exists, propose an additive `create_field` on `From` using the auto-generated `<target_singular>_id` field name with the row's `Verb` as `relationship_label` and `Delete` as `reference_delete_mode`. For inbound rows whose `From` does not yet exist (e.g. `purchase_orders → decision_packages` before any ERP module is deployed), skip silently. Batch a single user confirmation when several candidates match. The deployer's silent-skip behavior makes erring toward inclusion cheap.
8. **Junction-table label population.** Three entities have label fields the caller must populate on insert because they have no natural single-field label: `package_rankings.ranking_label`, `approval_actions.action_label`, `cost_center_assignments.assignment_label`. The implementing application or workflow should compose these from the related records (e.g. `"{cycle_name} / {cost_center_code} / #{rank_position} {package_title}"` for a ranking).
9. **Required-unique field strategy on populated tables.** Several fields are required + unique with no safe blanket default (`cost_centers.cost_center_code`, `decision_packages.package_code`, `cost_categories.category_code`, `gl_accounts.account_code`, `cost_drivers.driver_code`, `users.user_email`). When adding any of these columns to an entity that already contains rows, a blanket default like `""` would collide on the unique index for the second row. Recommended deploy-time strategy: (a) seed the column nullable first, (b) backfill per-row keyed off `id` via a one-off script, (c) add the unique + NOT NULL constraint after backfill. On empty entities (fresh module create) this is a non-issue.
10. **Composite uniqueness on `package_rankings`.** Field-level `unique_value` does not cover composite tuples. Add DB constraints (or application-level guards) for `(cost_center_id, budget_cycle_id, rank_position)` and `(cost_center_id, budget_cycle_id, decision_package_id)` after the entity exists.
11. After creation, spot-check that `label_column` on each entity resolves to a real field, that all `reference_table` targets exist, and that the `decision_packages` ↔ `funding_levels` circular reference resolves cleanly in both directions.
