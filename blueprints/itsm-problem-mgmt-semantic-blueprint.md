---
artifact: semantic-blueprint
blueprint_version: "3.0"
license: MIT
system_name: Problem Management
tagline: Find the root cause behind recurring incidents and stop them coming back.
description: |
  Problem Management connects the dots across repeated incidents to surface the underlying fault, document the known error, and drive a permanent fix. Instead of firefighting the same outage week after week, your team works the cause once.

  A structured path from identification through analysis to resolution keeps investigations disciplined, and a shared record of known errors speeds up every future diagnosis. Fewer repeat incidents means a calmer service desk and lower operating cost.
system_slug: itsm-problem-mgmt
domain_modules:
  - itsm-problem-mgmt
domain_code: ITSM
icon_name: headset
related_modules: [aiops-predictive-intelligence, ats-recruitment-pipeline, cmdb-core, hcm-core-worker, hcm-org-positions, iga-access-request, itsm-incident-mgmt, iwms-location-master, rmm-agent-mgmt]
persona: [HR-BUSINESS-PARTNER, HR-HRIS-ADMIN, HR-ORG-DESIGN-ANALYST, PEOPLE-MANAGER]
created_at: 2026-06-27
---

# Problem Management

## 1. Overview

Root-cause analysis, known-error tracking, and corrective action for recurring or major incidents.

## 2. Entity summary

| Name | data_object | Description |
| --- | --- | --- |
| Problems | `service_problems` | Root-cause records for recurring or related incidents, with known-error workarounds and links to the fix that will resolve them. |
| Configuration Items | `configuration_items` | Canonical records of IT things under management: servers, containers, applications, services, network devices, databases, and cloud resources. |
| Locations | `locations` | Physical or organizational locations referenced across the system, used to place and group other records. |
| Org Units | `org_units` | Nodes in the organizational hierarchy such as divisions, departments, and teams, with manager, cost center alignment, geographic scope, and parent-child links. |

```mermaid
flowchart TD
  classDef master fill:#d4f4dd,stroke:#27ae60,color:#0b3d20;
  classDef embedded_master fill:#fff4cc,stroke:#c79100,color:#5b4500;
  classDef platform_builtin fill:#e0e0e0,stroke:#424242,color:#1a1a1a;
  service_problems["Problems"]
  configuration_items["Configuration Items"]
  locations["Locations"]
  org_units["Org Units"]
  users["Users"]
  org_units -->|"rolls_up_to"| org_units
  locations -->|"rolls_up_to"| locations
  users -->|"owned CIs"| configuration_items
  users -->|"leads"| org_units
  users -->|"owned problems"| service_problems
  org_units -->|"has members"| users
  locations -->|"houses"| users
  class service_problems master;
  class configuration_items embedded_master;
  class locations embedded_master;
  class org_units embedded_master;
  class users platform_builtin;
  style locations stroke-dasharray:5 5;
  style org_units stroke-dasharray:5 5;
```

## 3. Entities catalog

| # | data_object | canonical code | singular | plural | role | mastered in | mastered label | necessity | personal_content | entity_type | write tier | notes |
| ---: | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | `service_problems` | `service_problems` | Problem | Problems | master | - | - | required | - | operational_workflow | `:manage` | - |
| 2 | `configuration_items` | `configuration_items` | Configuration Item | Configuration Items | embedded_master | `cmdb-core` | CMDB Core Repository | required | - | operational_workflow | `:manage` | - |
| 3 | `locations` | `locations` | Location | Locations | embedded_master | `iwms-location-master` | Location and Property Master | optional | - | catalog | `:admin` | - |
| 4 | `org_units` | `org_units` | Org Unit | Org Units | embedded_master | `hcm-org-positions` | Organization and Position Management | optional | - | operational_workflow | `:manage` | - |

## 4. Aliases and industry synonyms

_(none: no industry-scoped aliases for this scope)_

## 5. Relationships

### 5.1 Intra-scope edges

| from | verb | to | cardinality | kind | necessity | owner_side | delete_mode | fk_format | notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `org_units` | rolls_up_to | `org_units` | one_to_many | reference | optional | source | clear | reference | - |
| `locations` | rolls_up_to | `locations` | one_to_many | reference | optional | source | clear | reference | - |

### 5.2 Built-in edges (`users` and other platform built-ins)

| from | verb | to | cardinality | necessity | owner_side | delete_mode | fk_format | notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `users` | owned CIs | `configuration_items` | one_to_many | optional | source | clear | reference | - |
| `users` | leads | `org_units` | one_to_many | optional | source | clear | reference | - |
| `users` | owned problems | `service_problems` | one_to_many | optional | source | clear | reference | - |
| `org_units` | has members | `users` | one_to_many | optional | target | clear | reference | - |
| `locations` | houses | `users` | one_to_many | optional | target | clear | reference | - |

### 5.3 Cross-scope edges

#### 5.3a Outbound from this scope's masters and contributors

_Edges this scope drives: the in-scope endpoint has `role` of `master` or `contributor`._

| from | verb | to | cardinality | necessity | delete_mode | fk_format | notes |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `service_problems` | is investigated by | `service_incidents` | one_to_many | optional | none | n/a | - |
| `service_problems` | results_in | `service_changes` | one_to_many | optional | none | n/a | - |
| `service_problems` | documented_in | `knowledge_articles` | one_to_many | optional | none | n/a | - |
| `root_cause_analyses` | informs | `service_problems` | one_to_many | optional | none | n/a | - |

#### 5.3b Context edges on embedded shells and consumed entities

_Edges the canonical owner drives, shown for context: the in-scope endpoint has `role` of `embedded_master`, `consumer`, or `derived`._

| from | verb | to | cardinality | necessity | delete_mode | fk_format | notes |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `service_changes` | updates | `configuration_items` | many_to_many | optional | none | n/a | - |
| `enterprise_applications` | mapped_to | `configuration_items` | many_to_many | optional | none | n/a | - |
| `enterprise_applications` | onboards_into | `configuration_items` | one_to_one | optional | none | n/a | - |
| `ci_classes` | classifies | `configuration_items` | one_to_many | required | none (required-if-present) | n/a | - |
| `configuration_items` | related_via | `ci_relationships` | one_to_many | optional | none | n/a | - |
| `configuration_items` | baselined_in | `ci_baselines` | many_to_many | optional | none | n/a | - |
| `configuration_items` | composes | `service_maps` | many_to_many | optional | none | n/a | - |
| `configuration_items` | backed_by | `hardware_assets` | one_to_one | optional | none | n/a | - |
| `configuration_items` | changed_by | `service_changes` | many_to_many | optional | none | n/a | - |
| `configuration_items` | triggers | `service_incidents` | one_to_many | optional | none | n/a | - |
| `hardware_assets` | represented_as | `configuration_items` | one_to_one | optional | none | n/a | - |
| `locations` | hosts_desk_bookings | `desk_bookings` | one_to_many | required | none (required-if-present) | n/a | - |
| `locations` | hosts_room_reservations | `room_reservations` | one_to_many | required | none (required-if-present) | n/a | - |
| `locations` | site_of_service_requests | `workplace_service_requests` | one_to_many | required | none (required-if-present) | n/a | - |
| `locations` | measured_by_reports | `space_utilization_reports` | one_to_many | required | none (required-if-present) | n/a | - |
| `locations` | subject_of_feedback | `workplace_experience_feedback` | one_to_many | optional | none | n/a | - |
| `org_units` | groups | `employees` | one_to_many | required | none (required-if-present) | n/a | - |
| `org_units` | contains | `hcm_positions` | one_to_many | required | none (required-if-present) | n/a | - |
| `cost_centers` | funds | `org_units` | one_to_many | required | none (required-if-present) | n/a | - |
| `org_units` | engages | `contingent_workers` | one_to_many | optional | none | n/a | - |
| `org_units` | is_scored_by | `engagement_drivers` | one_to_many | optional | none | n/a | - |
| `org_units` | is_measured_by | `people_kpis` | one_to_many | optional | none | n/a | - |
| `org_units` | triggers | `iga_entitlement_definitions` | one_to_many | optional | none | n/a | - |
| `org_units` | maps_to | `cost_centers` | one_to_one | optional | none | n/a | - |
| `org_units` | sponsors | `compliance_assignments` | one_to_many | optional | none | n/a | - |
| `org_units` | sponsors | `benefit_plans` | many_to_many | optional | none | n/a | - |
| `survey_campaigns` | targets | `org_units` | many_to_many | optional | none | n/a | - |
| `org_units` | owns | `action_plans` | one_to_many | optional | none | n/a | - |
| `service_incidents` | references | `configuration_items` | many_to_many | optional | none | n/a | - |
| `service_changes` | impacts | `configuration_items` | many_to_many | required | none (required-if-present) | n/a | - |
| `dc_port_connections` | updates | `configuration_items` | one_to_many | optional | none | n/a | - |
| `vulnerabilities` | affects | `configuration_items` | one_to_many | optional | none | n/a | - |

## 6. Cross-domain context

### 6.1 Master consumers (other modules / domains that embed this scope's masters)

_(none: no other module embeds this scope's masters; the canonical owners do.)_

### 6.2 Outbound handoffs (events this scope publishes)

| source module | target domain | target module | trigger_event | transition | payload | integration | friction | description |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| CMDB-CORE | ITSM | ITSM-INCIDENT-MGMT | `ci.unauthorized_change_detected` | _(state_change)_ | `configuration_items` | api_call | medium | Configuration drift against a CI baseline (or change without a CAB-approved change record) creates a compliance / security incident in ITSM. Friction is medium - false positives from legitimate-but-unrecorded operational tweaks are common. |
| HCM-ORG-POSITIONS | IGA | IGA-ACCESS-REQUEST | `org_unit.created` | _(state_change)_ | `org_units` | event_stream | medium | New org unit drives IGA group/role provisioning. Group-name conventions and ownership must be encoded; otherwise orphan groups proliferate. |
| HCM-ORG-POSITIONS | IGA | IGA-ACCESS-REQUEST | `org_unit.disbanded` | _(state_change)_ | `org_units` | event_stream | high | Org-unit disbandment requires IGA group cleanup; orphan-group risk if employees re-assigned slowly. |
| HCM-ORG-POSITIONS | IGA | IGA-ACCESS-REQUEST | `org_unit.merged` | _(state_change)_ | `org_units` | event_stream | high | Org-unit merge consolidates IGA groups: members migrate, entitlements deduplicated, SoD revalidated. Often runs as a batch project rather than event. |
| HCM-ORG-POSITIONS | HCM | HCM-CORE-WORKER | `org_unit.disbanded` | _(state_change)_ | `org_units` | lifecycle_progression | high | Disbanded org unit requires every incumbent employee to be re-placed before close; worker-record module blocks the close until reassignment completes. |
| HCM-ORG-POSITIONS | HCM | HCM-CORE-WORKER | `org_unit.merged` | _(state_change)_ | `org_units` | lifecycle_progression | medium | Org-unit consolidation cascades employee re-assignment, manager and dotted-line reassignment, and reporting-line recompute on the worker record. |
| HCM-ORG-POSITIONS | ATS | ATS-RECRUITMENT-PIPELINE | `org_unit.activated` | _(state_change)_ | `org_units` | api_call | low | - |
| HCM-ORG-POSITIONS | ATS | ATS-RECRUITMENT-PIPELINE | `org_unit.closed` | _(state_change)_ | `org_units` | api_call | high | - |
| HCM-ORG-POSITIONS | ATS | ATS-RECRUITMENT-PIPELINE | `org_unit.created` | _(state_change)_ | `org_units` | api_call | medium | - |
| HCM-ORG-POSITIONS | ATS | ATS-RECRUITMENT-PIPELINE | `org_unit.disbanded` | _(state_change)_ | `org_units` | api_call | high | - |
| HCM-ORG-POSITIONS | ATS | ATS-RECRUITMENT-PIPELINE | `org_unit.merged` | _(state_change)_ | `org_units` | api_call | high | - |
| HCM-ORG-POSITIONS | ATS | ATS-RECRUITMENT-PIPELINE | `org_unit.reorganized` | _(state_change)_ | `org_units` | api_call | high | - |
| HCM-ORG-POSITIONS | FIN | _(domain-level)_ | `org_unit.created` | _(state_change)_ | `org_units` | api_call | medium | New org unit usually maps to cost-center; ERP-FIN must reflect the structure for budgeting and labor allocation. |

### 6.3 Inbound handoffs (events this scope reacts to)

| target module | source domain | source module | trigger_event | transition | payload | integration | friction | description |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| ITSM-PROBLEM-MGMT | AIOPS | AIOPS-PREDICTIVE-INTELLIGENCE | `root_cause.identified` | `identified` _(signal)_ | `service_problems` | api_call | medium | Confirmed RCA seeds an ITSM problem record (the long-lived root-cause artifact) and links it to the incident(s) that triggered it. Friction sits in the human-in-the-loop confirmation step - most AIOps RCAs need analyst sign-off before they reach problem-management. |
| CMDB-CORE | DISCOVERY | _(domain-level)_ | `ci.discovered` | `discovered` _(signal)_ | `configuration_items` | event_stream | low | Discovered devices reconcile against the existing CMDB and either match (update existing CI), promote (create new CI), or queue for manual review (ambiguous match). Low friction when DISCOVERY and CMDB are same-vendor; medium otherwise. |
| CMDB-CORE | RMM | RMM-AGENT-MGMT | `ci_endpoint.discovered` | `discovered` _(signal)_ | `configuration_items` | api_call | high | RMM contributes CI attributes (OS, installed services, network config) to the CMDB. Failure modes: CMDB receives the same logical CI from multiple discovery sources (RMM, AD, agent-less scans, cloud APIs) with conflicting attribute values; reconciliation rules are CMDB-vendor-specific and rarely fully cover RMM's payload shape. |

### 6.4 Master providers (modules / domains that own masters this scope embeds)

| data_object | role here | necessity | canonical owner(s) | slice notes |
| --- | --- | --- | --- | --- |
| `configuration_items` | embedded_master | required | CMDB-CORE (CMDB) | - |
| `locations` | embedded_master | optional | IWMS-LOCATION-MASTER (IWMS) | - |
| `org_units` | embedded_master | optional | HCM-ORG-POSITIONS (HCM) | - |

## 7. Lifecycle states

### `configuration_items` (Configuration Item)

_This scope holds `configuration_items` as **embedded_master**; the canonical state machine is owned by `CMDB-CORE`._

| order | state_name | initial? | terminal? | requires_permission? | derived gate | description |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | `discovered` | ✓ | - | - | - | CI auto-detected by discovery feed; not yet curated. |
| 2 | `registered` | - | - | ✓ | `itsm-problem-mgmt:register_ci` | CI record curated and accepted into the CMDB of record. |
| 3 | `in_use` | - | - | - | - | CI is actively in operational use. |
| 4 | `retired` | - | - | ✓ | `itsm-problem-mgmt:retire_ci` | CI taken out of service but record retained. |
| 5 | `archived` | - | ✓ | ✓ | `itsm-problem-mgmt:archive_ci` | CI record archived after retirement; read-only for audit. |

### `org_units` (Org Unit)

_This scope holds `org_units` as **embedded_master**; the canonical state machine is owned by `HCM-ORG-POSITIONS`._

| order | state_name | initial? | terminal? | requires_permission? | derived gate | description |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | `draft` | ✓ | - | - | - | Org unit defined as part of a future structure; not yet operational. |
| 2 | `active` | - | - | ✓ | `itsm-problem-mgmt:active_org_unit` | Operational unit; carries headcount, cost-center linkage, and reporting lines. |
| 3 | `reorganized` | - | ✓ | ✓ | `itsm-problem-mgmt:reorganized_org_unit` | Unit folded into or replaced by a new structure; references remain for history. |
| 4 | `closed` | - | ✓ | ✓ | `itsm-problem-mgmt:closed_org_unit` | Unit dissolved; no employees or positions reside in it. |

### `service_problems` (Problem)

| order | state_name | initial? | terminal? | requires_permission? | derived gate | description |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | `identified` | ✓ | - | - | - | Problem record opened from one or more correlated incidents. |
| 2 | `analyzed` | - | - | - | - | Root-cause analysis in progress. |
| 3 | `known_error` | - | - | - | - | Root cause identified; workaround documented. |
| 4 | `resolved` | - | - | ✓ | `itsm-problem-mgmt:resolved_problem` | Permanent fix delivered (typically via a change). |
| 5 | `closed` | - | ✓ | - | - | Problem record finalized; no further action required. |

## 8. Permissions and business rules (derived)

### 8.1 Permissions

| permission | tier | description | included in `:admin`? |
| --- | --- | --- | --- |
| `itsm-problem-mgmt:read` | baseline-read | Read access to every entity in the module | ✓ |
| `itsm-problem-mgmt:manage` | baseline-manage | Edit operational records | ✓ |
| `itsm-problem-mgmt:admin` | baseline-admin | Edit reference data and inherit every workflow gate below | - |
| `itsm-problem-mgmt:active_org_unit` | workflow-gate (lifecycle) | Transition `org_units` into state `active` | ✓ |
| `itsm-problem-mgmt:reorganized_org_unit` | workflow-gate (lifecycle) | Transition `org_units` into state `reorganized` | ✓ |
| `itsm-problem-mgmt:closed_org_unit` | workflow-gate (lifecycle) | Transition `org_units` into state `closed` | ✓ |
| `itsm-problem-mgmt:resolved_problem` | workflow-gate (lifecycle) | Transition `service_problems` into state `resolved` | ✓ |
| `itsm-problem-mgmt:register_ci` | workflow-gate (lifecycle) | Transition `configuration_items` into state `registered` | ✓ |
| `itsm-problem-mgmt:retire_ci` | workflow-gate (lifecycle) | Transition `configuration_items` into state `retired` | ✓ |
| `itsm-problem-mgmt:archive_ci` | workflow-gate (lifecycle) | Transition `configuration_items` into state `archived` | ✓ |

### 8.2 Business rules

_(none: no flag-derived business rules)_

## 9. Roles, RACI, and responsibilities (derived)

_Baseline roles, the permission hierarchy, and RACI realization are DERIVED from this scope's entity-type write tiers + `process_raci`; none of it is stored in the catalog (the deployer provisions it from this blueprint)._

### 9.1 `ITSM-PROBLEM-MGMT`

**Baseline roles:**

| role | baseline grant |
| --- | --- |
| `itsm-problem-mgmt_viewer` | `itsm-problem-mgmt:read` |
| `itsm-problem-mgmt_manager` | `itsm-problem-mgmt:manage` |

**Permission hierarchy:**

| permission | includes |
| --- | --- |
| `itsm-problem-mgmt:admin` | `itsm-problem-mgmt:manage` |
| `itsm-problem-mgmt:manage` | `itsm-problem-mgmt:read` |
| `itsm-problem-mgmt:admin` | `itsm-problem-mgmt:active_org_unit` |
| `itsm-problem-mgmt:admin` | `itsm-problem-mgmt:reorganized_org_unit` |
| `itsm-problem-mgmt:admin` | `itsm-problem-mgmt:closed_org_unit` |
| `itsm-problem-mgmt:admin` | `itsm-problem-mgmt:resolved_problem` |
| `itsm-problem-mgmt:admin` | `itsm-problem-mgmt:register_ci` |
| `itsm-problem-mgmt:admin` | `itsm-problem-mgmt:retire_ci` |
| `itsm-problem-mgmt:admin` | `itsm-problem-mgmt:archive_ci` |

**Processes wired:**

| process_key | process_name | PCF code | PCF ID | level | description |
| --- | --- | --- | --- | --- | --- |
| `create_organizational_design` | Create organizational design | 1.2.5 | 10041 | 3 | Formulating a design for the organization's resources that allow it to meet its objectives. Develop a new framework for molding the organization's various processes into a coherent and seamless whole. |
| `conduct_organization` | Conduct organization restructuring opportunities | 1.1.5 | 16792 | 3 | Examining the scope and contingencies for restructuring based on market situation and internal realities. Map the market forces over which any and all probabilities can be probed for utility and viability. Once the restructuring options have been analyzed and the due-diligence performed, execute the deal. Consider seeking professional services for assistance in formalizing these opportunities. |

**RACI realization:**

| actor | kind | raci | process_key | realization |
| --- | --- | --- | --- | --- |
| `HR-ORG-DESIGN-ANALYST` | persona | responsible | `create_organizational_design` | grant gates [itsm-problem-mgmt:active_org_unit] + the gated entities' write tier |
| `HR-BUSINESS-PARTNER` | persona | accountable | `create_organizational_design` | approval gate |
| `PEOPLE-MANAGER` | persona | consulted | `create_organizational_design` | advisory read grant |
| `HR-HRIS-ADMIN` | persona | informed | `create_organizational_design` | notification side effect (trigger_event / webhook_receiver) |
| `HR-ORG-DESIGN-ANALYST` | persona | responsible | `conduct_organization` | grant gates [itsm-problem-mgmt:reorganized_org_unit] + the gated entities' write tier |
| `HR-BUSINESS-PARTNER` | persona | accountable | `conduct_organization` | approval gate |
| `PEOPLE-MANAGER` | persona | consulted | `conduct_organization` | advisory read grant |

### 9.2 Functional ownership and default grants

| responsibility | business function | default role | default tier |
| --- | --- | --- | --- |
| owner | IT Service Desk | `admin` | `:admin` |
| contributor | IT Operations | `manage` | `:manage` |
| contributor | Security | `manage` | `:manage` |
| consumer | Finance | `read` | `:read` |
| consumer | Human Resources | `read` | `:read` |
