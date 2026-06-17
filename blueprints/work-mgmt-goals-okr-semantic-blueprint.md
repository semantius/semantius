---
artifact: semantic-blueprint
blueprint_version: "3.0"
license: MIT
system_name: WORK-MGMT-GOALS-OKR
system_description: Team-Execution Goals and OKRs
tagline: Set objectives, score key results, and see progress roll up from the work behind them.
description: |
  Define objectives and measurable key results for the quarter or year, assign owners, and keep them current with regular check-ins. Link objectives to the tasks and projects that drive them so progress updates as work gets done instead of being re-entered by hand.

  Commit objectives once agreed, track them through the cycle, and score them at close so the team learns what worked.
system_slug: work-mgmt-goals-okr
domain_modules:
  - work-mgmt-goals-okr
domain_code: WORK-MGMT
related_modules: [eap-portfolio-roadmap, intgov-governance, mrm-planning, pm-roadmap-delivery, psa-project-delivery, sem-execution-tracking, sem-operating-rhythm, sem-strategy-definition, talent-performance-mgmt, work-mgmt-intake, work-mgmt-task-exec]
persona: [OKR-OWNER, OPERATIONS-WORK-CONTRIBUTOR, OPERATIONS-WORK-PROGRAM-LEAD]
created_at: 2026-06-17
---

# Team-Execution Goals and OKRs

## 1. Overview

Team-execution OKR tracking surface: objectives with key results that link to work items for automatic progress rollup, weekly check-in cadences, scoring, and closure. Deploys alongside the task-execution module for full integration, or standalone with a thin embedded work-item shell for KR linking.

## 2. Entity summary

| Name | data_object | Description |
| --- | --- | --- |
| Key Results | `okr_key_results` | Measurable result attached to an okr_objective. The unit of scoring on OKR programs - vendors universally model KR as first-class (Asana, Monday, ClickUp, Workfront). |
| Objective / OKRs | `okr_objectives` | Hierarchical objective with measurable key results, weighted progress rollup from child objectives or linked work_items, owner accountability, and cadence (quarterly/annual). Mastered by three distinct domains: WORK-MGMT (team-level execution OKRs), SPM (strategic portfolio OKRs), TALENT-MGMT (individual performance-management OKRs). Same primitive, three different lifecycles and review processes - canonical Signal-1 multi-master. |
| OKR Check-ins | `okr_check_ins` | Periodic status update on an okr_objective or key_result during the active cycle. Cadence-of-record (weekly/bi-weekly) for OKR programs. May discuss individual performance - flagged as personal content. |
| Work-to-Goal Links | `work_goal_links` | Contribution link between a work item or project and an okr_objective so that goal progress can roll up from the work that drives it. |
| Work Items | `work_items` | Atomic primitive in a work-management platform: task / item / card with owner, due date, status, priority, dependencies, subtasks, attachments, and comments. Same shape regardless of platform-specific terminology (task, item, row, card). |

```mermaid
flowchart TD
  classDef master fill:#d4f4dd,stroke:#27ae60,color:#0b3d20;
  classDef embedded_master fill:#fff4cc,stroke:#c79100,color:#5b4500;
  classDef platform_builtin fill:#e0e0e0,stroke:#424242,color:#1a1a1a;
  okr_objectives["Objective / OKRs"]
  work_items["Work Items"]
  okr_key_results["Key Results"]
  okr_check_ins["OKR Check-ins"]
  work_goal_links["Work-to-Goal Links"]
  users["Users"]
  okr_key_results -->|"belongs_to"| okr_objectives
  okr_check_ins -->|"belongs_to"| okr_objectives
  okr_check_ins -->|"references"| okr_key_results
  work_items -->|"depends_on"| work_items
  okr_objectives -->|"tracked_by"| work_items
  work_goal_links -->|"links"| work_items
  work_goal_links -->|"links_to"| okr_objectives
  users -->|"owns_key_results"| okr_key_results
  users -->|"authored_check_ins"| okr_check_ins
  users -->|"assigned items"| work_items
  users -->|"created items"| work_items
  users -->|"owns OKR"| okr_objectives
  class okr_objectives master;
  class work_items embedded_master;
  class okr_key_results master;
  class okr_check_ins master;
  class work_goal_links master;
  class users platform_builtin;
  style work_goal_links stroke-dasharray:5 5;
```

## 3. Entities catalog

| # | data_object | canonical code | singular | plural | role | mastered in | mastered label | necessity | pattern flags | entity_type | write tier | notes |
| ---: | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | `okr_key_results` | `okr_key_results` | Key Result | Key Results | master | - | - | required | - | operational_record | `:manage` | - |
| 2 | `okr_objectives` | `okr_objectives` | Objective / OKR | Objective / OKRs | master | - | - | required | personal_content | operational_workflow | `:manage` | - |
| 3 | `okr_check_ins` | `okr_check_ins` | OKR Check-in | OKR Check-ins | master | - | - | required | personal_content | operational_record | `:manage` | - |
| 4 | `work_goal_links` | `work_goal_links` | Work-to-Goal Link | Work-to-Goal Links | master | - | - | optional | - | junction | `:manage` | - |
| 5 | `work_items` | `work_items` | Work Item | Work Items | embedded_master | `work-mgmt-task-exec` | Task and Project Execution | required | - | operational_workflow | `:manage` | - |

## 4. Aliases and industry synonyms

_(none: no industry-scoped aliases for this scope)_

## 5. Relationships

### 5.1 Intra-scope edges

| from | verb | to | cardinality | kind | necessity | owner_side | delete_mode | fk_format | notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `okr_key_results` | belongs_to | `okr_objectives` | one_to_many | composition | required | target | cascade | parent | - |
| `okr_check_ins` | belongs_to | `okr_objectives` | one_to_many | composition | required | target | cascade | parent | - |
| `okr_check_ins` | references | `okr_key_results` | one_to_many | reference | optional | target | clear | reference | - |
| `work_items` | depends_on | `work_items` | many_to_many | association | optional | source | clear | reference | - |
| `okr_objectives` | tracked_by | `work_items` | one_to_many | reference | optional | source | clear | reference | - |
| `work_goal_links` | links | `work_items` | one_to_many | reference | required | target | restrict | reference | - |
| `work_goal_links` | links_to | `okr_objectives` | one_to_many | reference | required | target | restrict | reference | - |

### 5.2 Built-in edges (`users` and other platform built-ins)

| from | verb | to | cardinality | necessity | owner_side | delete_mode | fk_format | notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `users` | owns_key_results | `okr_key_results` | one_to_many | optional | source | clear | reference | - |
| `users` | authored_check_ins | `okr_check_ins` | one_to_many | optional | source | clear | reference | - |
| `users` | assigned items | `work_items` | one_to_many | optional | source | clear | reference | - |
| `users` | created items | `work_items` | one_to_many | required | source | restrict | reference | - |
| `users` | owns OKR | `okr_objectives` | one_to_many | required | source | restrict | reference | - |

### 5.3 Cross-scope edges

#### 5.3a Outbound from this scope's masters and contributors

_Edges this scope drives: the in-scope endpoint has `role` of `master` or `contributor`._

| from | verb | to | cardinality | necessity | delete_mode | fk_format | notes |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `strategy_maps` | organizes | `okr_objectives` | one_to_many | optional | none | n/a | - |
| `okr_objectives` | advanced_by | `strategic_initiatives` | many_to_many | optional | none | n/a | - |
| `okr_objectives` | reviewed_in | `operating_reviews` | many_to_many | optional | none | n/a | - |
| `strategy_decisions` | affects | `okr_objectives` | many_to_many | optional | none | n/a | - |
| `work_projects` | aligned_to | `okr_objectives` | many_to_many | optional | none | n/a | - |
| `performance_reviews` | evaluates | `okr_objectives` | one_to_many | optional | none | n/a | - |
| `performance_goals` | aligns_to | `okr_objectives` | many_to_many | optional | none | n/a | - |

#### 5.3b Context edges on embedded shells and consumed entities

_Edges the canonical owner drives, shown for context: the in-scope endpoint has `role` of `embedded_master`, `consumer`, or `derived`._

| from | verb | to | cardinality | necessity | delete_mode | fk_format | notes |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `test_defects` | spawns | `work_items` | one_to_many | optional | none | n/a | - |
| `work_dependencies` | blocks | `work_items` | many_to_many | required | none (required-if-present) | n/a | - |
| `work_approval_chains` | gates | `work_items` | many_to_many | optional | none | n/a | - |
| `work_user_workloads` | rolls_up | `work_items` | many_to_many | required | none (required-if-present) | n/a | - |
| `work_custom_field_values` | set_on | `work_items` | one_to_many | required | ⚠ audit: required composed child out of scope | n/a | - |
| `work_items` | placed_in | `work_sections` | one_to_many | optional | none | n/a | - |
| `work_task_templates` | seeds_item | `work_items` | one_to_many | optional | none | n/a | - |
| `work_item_tags` | tagged_on | `work_items` | one_to_many | required | ⚠ audit: required composed child out of scope | n/a | - |
| `work_item_comments` | belongs_to | `work_items` | one_to_many | required | ⚠ audit: required composed child out of scope | n/a | - |
| `work_item_attachments` | belongs_to | `work_items` | one_to_many | required | ⚠ audit: required composed child out of scope | n/a | - |
| `work_form_submissions` | converts_to | `work_items` | one_to_many | optional | none | n/a | - |
| `action_plans` | spawns | `work_items` | one_to_many | optional | none | n/a | - |
| `work_projects` | contains | `work_items` | one_to_many | required | ⚠ audit: required composed child out of scope | n/a | - |
| `work_automations` | drives | `work_items` | one_to_many | optional | none | n/a | - |
| `work_items` | mirrors_to | `service_requests` | one_to_one | optional | none | n/a | - |
| `strategic_initiatives` | portfolio rollup from | `work_items` | one_to_many | optional | none | n/a | - |
| `intranet_content_inventory_records` | spawns improvement | `work_items` | one_to_many | optional | none | n/a | - |
| `marketing_plan_lines` | is delivered by | `work_items` | one_to_many | optional | none | n/a | - |
| `proofing_sessions` | belongs_to | `work_items` | one_to_many | required | ⚠ audit: required composed child out of scope | n/a | - |
| `work_time_entries` | logged_against | `work_items` | one_to_many | required | ⚠ audit: required composed child out of scope | n/a | - |
| `work_statuses` | is_status_of | `work_items` | one_to_many | optional | none | n/a | - |
| `work_status_updates` | records_change_on | `work_items` | one_to_many | required | ⚠ audit: required composed child out of scope | n/a | - |

## 6. Cross-domain context

### 6.1 Master consumers (other modules / domains that embed this scope's masters)

| data_object | other module / domain | role | necessity | notes |
| --- | --- | --- | --- | --- |
| `okr_objectives` | EAP-PORTFOLIO-ROADMAP (Portfolio Backlog and Roadmaps) - EAP | consumer | optional | - |
| `okr_objectives` | PM-ROADMAP-DELIVERY (Roadmap, Release, and Strategy) - PROD-MGMT | consumer | optional | - |
| `okr_objectives` | SEM-EXECUTION-TRACKING (Execution Tracking) - SEM | consumer | required | - |
| `okr_objectives` | SEM-OPERATING-RHYTHM (Operating Rhythm) - SEM | consumer | required | - |
| `okr_objectives` | SEM-STRATEGY-DEFINITION (Strategy Definition) - SEM | embedded_master | required | - |
| `okr_objectives` | TALENT-PERFORMANCE-MGMT (Performance and Goal Management) - TALENT-MGMT | embedded_master | optional | - |

### 6.2 Outbound handoffs (events this scope publishes)

| source module | target domain | target module | trigger_event | transition | payload | integration | friction | description |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| WORK-MGMT-TASK-EXEC | SPM | _(domain-level)_ | `work_item.completed` | `in_progress` → `done` _(lifecycle)_ | `work_items` | batch_sync | medium | Work-management platforms publish task-completion data to portfolio dashboards in SPM tools. The portfolio rollup powers strategy-to-execution dashboards and OKR progress (via okr_objectives.key_results linking down to work_items). Nightly sync is the common pattern; richer real-time integrations exist but are vendor-specific. |
| WORK-MGMT-GOALS-OKR | SPM | _(domain-level)_ | `okr_objective.committed` | `drafted` → `committed` _(lifecycle)_ | `okr_objectives` | api_call | medium | Team-level OKR commits in WM cascade upward into SPM portfolio rollup. SPM tracks corporate / strategic OKRs and aggregates team commits for portfolio reporting. target_domain_module_id NULL because SPM is not yet modularized. |
| WORK-MGMT-GOALS-OKR | TALENT-MGMT | TALENT-PERFORMANCE-MGMT | `okr_objective.committed` | `drafted` → `committed` _(lifecycle)_ | `okr_objectives` | api_call | medium | Team OKR commits in WORK-MGMT-GOALS-OKR; TALENT-PERFORMANCE-MGMT reads the committed objective so per-employee performance_goals can align to its KRs. Most modern perf platforms (Lattice, 15Five, Culture Amp) ship OKR-tool sync; non-trivial when the OKR tool is separate from the perf tool because employee-to-KR mapping is manual. |
| WORK-MGMT-GOALS-OKR | TALENT-MGMT | TALENT-PERFORMANCE-MGMT | `okr_objective.scored` | `in_progress` → `scored` _(lifecycle)_ | `okr_objectives` | api_call | high | End-of-cycle OKR score feeds directly into per-employee performance review compensation discussion. High friction: most-cited integration pain point across Lattice/15Five/Culture Amp user surveys when the team OKR tool is a separate vendor from the perf review tool - managers re-derive scores manually, often after late-bound corrections to the OKR-side scoring. |
| WORK-MGMT-TASK-EXEC | PSA | PSA-PROJECT-DELIVERY | `work_item.completed` | `in_progress` → `done` _(lifecycle)_ | `work_items` | api_call | low | When WM is the work tracker for a PSA-managed delivery, work_item completion closes the loop on PSA-side time / utilization accounting. Pairs with the existing PSA -> WM project_task.completed inbound for the bidirectional sync pattern. |
| WORK-MGMT-TASK-EXEC | PROD-MGMT | PM-ROADMAP-DELIVERY | `work_item.completed` | `in_progress` → `done` _(lifecycle)_ | `work_items` | api_call | medium | WM work_item completion updates PROD-MGMT roadmap progress when items are linked to feature_requests or product_releases. Most product-mgmt tools (Aha, Productboard, Roadmunk) integrate via this signal but each integration is bespoke - friction is the mapping between work_item id and roadmap_item id. |
| WORK-MGMT-GOALS-OKR | PROD-MGMT | PM-ROADMAP-DELIVERY | `okr_objective.committed` | `drafted` → `committed` _(lifecycle)_ | `okr_objectives` | api_call | medium | Team OKR commits in WM; PROD-MGMT roadmaps that align to OKR cycles pick up the committed objective for alignment scoring. Aha, Productboard, and similar tools maintain OKR sync as a paid feature. |
| WORK-MGMT-GOALS-OKR | PROD-MGMT | PM-ROADMAP-DELIVERY | `okr_objective.scored` | `in_progress` → `scored` _(lifecycle)_ | `okr_objectives` | api_call | medium | End-of-cycle OKR score feeds PROD-MGMT retrospective and next-cycle roadmap prioritization. Distinct from committed (kickoff) and aligned to roadmap delivery KPIs. |
| WORK-MGMT-GOALS-OKR | WORK-MGMT | WORK-MGMT-TASK-EXEC | `okr_objective.committed` | `drafted` → `committed` _(lifecycle)_ | `okr_objectives` | lifecycle_progression | low | Committing an OKR unlocks KR-to-work_item linking and optionally auto-creates placeholder work_items per the objective's templates. Reverse direction of the rollup flow. |

### 6.3 Inbound handoffs (events this scope reacts to)

| target module | source domain | source module | trigger_event | transition | payload | integration | friction | description |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| WORK-MGMT-GOALS-OKR | SPM | _(domain-level)_ | `okr_objective.created` | `drafted` _(lifecycle)_ | `okr_objectives` | manual_handoff | high | Executive-level OKRs created in SPM (or in a slide deck, or an HCM perf system) need to cascade into team-level OKRs in the work-management tool. Almost universally manual: someone reads the corporate OKR and authors child OKRs in the WORK-MGMT goals module. The cascade gap is what dedicated OKR-platform vendors exist to close. |
| WORK-MGMT-GOALS-OKR | WORK-MGMT | WORK-MGMT-TASK-EXEC | `work_item.completed` | `in_progress` → `done` _(lifecycle)_ | `work_items` | lifecycle_progression | low | Terminal completion of a work item is the strongest progress signal - drives KR closure recalculation and triggers KR-fully-met evaluations on linked objectives. |
| WORK-MGMT-GOALS-OKR | WORK-MGMT | WORK-MGMT-TASK-EXEC | `work_item.status_changed` | `any` → `any` _(lifecycle)_ | `work_items` | lifecycle_progression | low | Work item status change triggers KR progress recalculation in GOALS-OKR for any objective that has linked the item to a key result. In-process FK + state read; no message moves. |
| WORK-MGMT-TASK-EXEC | WORK-MGMT | WORK-MGMT-INTAKE | `work_form_submission.converted` | `triaged` → `converted` _(lifecycle)_ | `work_items` | lifecycle_progression | low | A converted intake form submission spawns a work item in the task-execution module under the routed project. |
| WORK-MGMT-TASK-EXEC | INTRANET-GOV | INTGOV-GOVERNANCE | `intranet_content_attestation.flagged_stale` | `pending` → `flagged_stale` _(state_change)_ | `work_items` | api_call | medium | When content is flagged stale during recertification, an improvement work item is created in Work Management for remediation. |
| WORK-MGMT-TASK-EXEC | MRM | MRM-PLANNING | `marketing_plan_line.scheduled` | `scheduled` _(state_change)_ | `work_items` | api_call | medium | When a plan line is scheduled on the marketing calendar, the delivery work is handed to work-management as tasks and projects. Payload: the work item that delivers the plan line. |

### 6.4 Master providers (modules / domains that own masters this scope embeds)

| data_object | role here | necessity | canonical owner(s) | slice notes |
| --- | --- | --- | --- | --- |
| `work_items` | embedded_master | required | WORK-MGMT-TASK-EXEC (WORK-MGMT) | - |

## 7. Lifecycle states

### `okr_key_results` (Key Result)

| order | state_name | initial? | terminal? | requires_permission? | derived gate | description |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | `drafted` | ✓ | - | - | - | - |
| 2 | `committed` | - | - | ✓ | `work-mgmt-goals-okr:commit_okr_key_result` | - |
| 3 | `in_progress` | - | - | - | - | - |
| 4 | `at_risk` | - | - | - | - | - |
| 5 | `achieved` | - | ✓ | ✓ | `work-mgmt-goals-okr:achieve_okr_key_result` | - |
| 6 | `missed` | - | ✓ | ✓ | `work-mgmt-goals-okr:miss_okr_key_result` | - |

### `okr_objectives` (Objective / OKR)

| order | state_name | initial? | terminal? | requires_permission? | derived gate | description |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | `drafted` | ✓ | - | - | - | - |
| 2 | `committed` | - | - | ✓ | `work-mgmt-goals-okr:commit_okr_objective` | - |
| 3 | `in_progress` | - | - | - | - | - |
| 4 | `scored` | - | - | ✓ | `work-mgmt-goals-okr:score_okr_objective` | - |
| 5 | `closed` | - | ✓ | - | - | - |

### `work_items` (Work Item)

_This scope holds `work_items` as **embedded_master**; the canonical state machine is owned by `WORK-MGMT-TASK-EXEC`._

| order | state_name | initial? | terminal? | requires_permission? | derived gate | description |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | `open` | ✓ | - | - | - | - |
| 2 | `in_progress` | - | - | - | - | - |
| 3 | `blocked` | - | - | - | - | - |
| 4 | `done` | - | ✓ | - | - | - |
| 5 | `canceled` | - | ✓ | ✓ | `work-mgmt-goals-okr:cancel_work_item` | - |

## 8. Permissions and business rules (derived)

### 8.1 Permissions

| permission | tier | description | included in `:admin`? |
| --- | --- | --- | --- |
| `work-mgmt-goals-okr:read` | baseline-read | Read access to every entity in the module | ✓ |
| `work-mgmt-goals-okr:manage` | baseline-manage | Edit operational records | ✓ |
| `work-mgmt-goals-okr:admin` | baseline-admin | Edit reference data and inherit every workflow gate below | - |
| `work-mgmt-goals-okr:cancel_work_item` | workflow-gate (lifecycle) | Transition `work_items` into state `canceled` | ✓ |
| `work-mgmt-goals-okr:commit_okr_objective` | workflow-gate (lifecycle) | Transition `okr_objectives` into state `committed` | ✓ |
| `work-mgmt-goals-okr:score_okr_objective` | workflow-gate (lifecycle) | Transition `okr_objectives` into state `scored` | ✓ |
| `work-mgmt-goals-okr:commit_okr_key_result` | workflow-gate (lifecycle) | Transition `okr_key_results` into state `committed` | ✓ |
| `work-mgmt-goals-okr:achieve_okr_key_result` | workflow-gate (lifecycle) | Transition `okr_key_results` into state `achieved` | ✓ |
| `work-mgmt-goals-okr:miss_okr_key_result` | workflow-gate (lifecycle) | Transition `okr_key_results` into state `missed` | ✓ |
| `work-mgmt-goals-okr:view_all_objective_/_okrs` | override (personal_content) | View all `okr_objectives` rows beyond row-scope | ✓ |
| `work-mgmt-goals-okr:manage_all_objective_/_okrs` | override (personal_content) | Manage all `okr_objectives` rows beyond row-scope | ✓ |
| `work-mgmt-goals-okr:view_all_okr_check-ins` | override (personal_content) | View all `okr_check_ins` rows beyond row-scope | ✓ |
| `work-mgmt-goals-okr:manage_all_okr_check-ins` | override (personal_content) | Manage all `okr_check_ins` rows beyond row-scope | ✓ |

### 8.2 Business rules

| rule_name | data_object | source flag | intent |
| --- | --- | --- | --- |
| `objective_/_okr_edit_scope` | `okr_objectives` | has_personal_content | Row-scope by default; override via `work-mgmt-goals-okr:view_all_objective_/_okrs` / `work-mgmt-goals-okr:manage_all_objective_/_okrs` |
| `okr_check-in_edit_scope` | `okr_check_ins` | has_personal_content | Row-scope by default; override via `work-mgmt-goals-okr:view_all_okr_check-ins` / `work-mgmt-goals-okr:manage_all_okr_check-ins` |

## 9. Roles, RACI, and responsibilities (derived)

_Baseline roles, the permission hierarchy, and RACI realization are DERIVED from this scope's entity-type write tiers + `process_raci`; none of it is stored in the catalog (the deployer provisions it from this blueprint)._

### 9.1 `WORK-MGMT-GOALS-OKR`

**Baseline roles:**

| role | baseline grant |
| --- | --- |
| `work-mgmt-goals-okr_viewer` | `work-mgmt-goals-okr:read` |
| `work-mgmt-goals-okr_manager` | `work-mgmt-goals-okr:manage` |

**Permission hierarchy:**

| permission | includes |
| --- | --- |
| `work-mgmt-goals-okr:admin` | `work-mgmt-goals-okr:manage` |
| `work-mgmt-goals-okr:manage` | `work-mgmt-goals-okr:read` |
| `work-mgmt-goals-okr:admin` | `work-mgmt-goals-okr:cancel_work_item` |
| `work-mgmt-goals-okr:admin` | `work-mgmt-goals-okr:commit_okr_objective` |
| `work-mgmt-goals-okr:admin` | `work-mgmt-goals-okr:score_okr_objective` |
| `work-mgmt-goals-okr:admin` | `work-mgmt-goals-okr:commit_okr_key_result` |
| `work-mgmt-goals-okr:admin` | `work-mgmt-goals-okr:achieve_okr_key_result` |
| `work-mgmt-goals-okr:admin` | `work-mgmt-goals-okr:miss_okr_key_result` |
| `work-mgmt-goals-okr:admin` | `work-mgmt-goals-okr:view_all_objective_/_okrs` |
| `work-mgmt-goals-okr:admin` | `work-mgmt-goals-okr:manage_all_objective_/_okrs` |
| `work-mgmt-goals-okr:admin` | `work-mgmt-goals-okr:view_all_okr_check-ins` |
| `work-mgmt-goals-okr:admin` | `work-mgmt-goals-okr:manage_all_okr_check-ins` |

**Processes wired:**

| process_key | process_name | PCF code | PCF ID | level | description |
| --- | --- | --- | --- | --- | --- |
| `manage_projects` | Manage projects | 13.2.3 | 16410 | 3 | Establishing the scope of the projects. Create plans for implementing the projects. Initiate projects. Review and report project performance to management. Close projects. |
| `develop_set_organizational` | Develop and set organizational objectives | 1.2.6 | 10042 | 3 | Developing overall goals for the organization that help in accomplishing its mission. Formulate organization-wide targets in the near to middle term, which will accumulate and propel the organization to realize its long-term objectives, as outlined in Develop an overall mission statement [10037]. Enlist business unit heads or equivalent personnel, in close collaboration with senior management executives. |

**RACI realization:**

| actor | kind | raci | process_key | realization |
| --- | --- | --- | --- | --- |
| `OPERATIONS-WORK-CONTRIBUTOR` | persona | responsible | `manage_projects` | grant gates [work-mgmt-goals-okr:cancel_work_item] + the gated entities' write tier |
| `OPERATIONS-WORK-PROGRAM-LEAD` | persona | accountable | `manage_projects` | approval gate |
| `OKR-OWNER` | persona | responsible | `develop_set_organizational` | grant gates [work-mgmt-goals-okr:commit_okr_objective, work-mgmt-goals-okr:score_okr_objective] + the gated entities' write tier |
| `OKR-OWNER` | persona | accountable | `develop_set_organizational` | approval gate |

### 9.2 Functional ownership and default grants

| responsibility | business function | default role | default tier |
| --- | --- | --- | --- |
| owner | Business Operations | `admin` | `:admin` |
| contributor | Customer Success | `manage` | `:manage` |
| contributor | Marketing | `manage` | `:manage` |
| contributor | Product Management | `manage` | `:manage` |
| consumer | Sales | `read` | `:read` |
