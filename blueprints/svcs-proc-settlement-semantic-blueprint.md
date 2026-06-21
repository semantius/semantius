---
artifact: semantic-blueprint
blueprint_version: "3.0"
license: MIT
system_name: SVCS-PROC-SETTLEMENT
system_description: Milestone Delivery and Settlement
tagline: Track milestones and deliverables to acceptance, then pay on what was actually delivered.
description: Run the delivery half of a services engagement. Break the statement of work into milestones and the deliverables that close them, then track each one to formal acceptance so payment follows delivered outcomes, not elapsed time. Raise milestone-based invoices against accepted work and keep a clear, auditable record of who accepted what and when. Outcome-based settlement that ties every payment back to a milestone the buyer signed off.
system_slug: svcs-proc-settlement
domain_modules:
  - svcs-proc-settlement
domain_code: SVCS-PROC
persona: []
created_at: 2026-06-19
---

# Milestone Delivery and Settlement

## 1. Overview

The delivery and settlement surface: break the engagement into milestones and deliverables, track each to acceptance, and settle on what was delivered through milestone-based invoices. Masters the milestone, the deliverable, the milestone invoice, and the acceptance record.

## 2. Entity summary

| Name | data_object | Description |
| --- | --- | --- |
| Milestone Invoices | `milestone_invoices` | Invoices a firm raises against an accepted milestone of a services engagement, so payment follows delivered outcomes rather than elapsed time. The settlement record for outcome-based services work, distinct from time-and-materials contingent invoices. |
| Service Acceptances | `service_acceptances` | Formal sign-off records capturing that the buyer accepted a deliverable or milestone, who accepted it, and when, gating the milestone invoice. Optional because some buyers accept implicitly on invoice rather than recording a typed acceptance. |
| Service Deliverables | `service_deliverables` | Concrete work products a firm produces under a statement of work, tracked from submission to acceptance against the milestone they close. Optional because some buyers settle on the milestone alone and inline deliverables as attributes. |
| SOW Milestones | `sow_milestones` | Schedule-and-payment checkpoints that break a services engagement into accountable stages, each tied to deliverables and to the milestone invoice it releases. The settlement mechanic that makes outcome-based services payment work. |

```mermaid
flowchart TD
  classDef master fill:#d4f4dd,stroke:#27ae60,color:#0b3d20;
  sow_milestones["SOW Milestones"]
  service_deliverables["Service Deliverables"]
  milestone_invoices["Milestone Invoices"]
  service_acceptances["Service Acceptances"]
  class sow_milestones master;
  class service_deliverables master;
  class milestone_invoices master;
  class service_acceptances master;
  style service_deliverables stroke-dasharray:5 5;
  style service_acceptances stroke-dasharray:5 5;
```

## 3. Entities catalog

| # | data_object | canonical code | singular | plural | role | mastered in | mastered label | necessity | pattern flags | entity_type | write tier | notes |
| ---: | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | `milestone_invoices` | `milestone_invoices` | Milestone Invoice | Milestone Invoices | master | - | - | required | - | operational_workflow | `:manage` | - |
| 2 | `service_acceptances` | `service_acceptances` | Service Acceptance | Service Acceptances | master | - | - | optional | single_approver | operational_record | `:manage` | - |
| 3 | `service_deliverables` | `service_deliverables` | Service Deliverable | Service Deliverables | master | - | - | optional | - | operational_workflow | `:manage` | - |
| 4 | `sow_milestones` | `sow_milestones` | SOW Milestone | SOW Milestones | master | - | - | required | - | operational_workflow | `:manage` | - |

## 4. Aliases and industry synonyms

_(none: no industry-scoped aliases for this scope)_

## 5. Relationships

### 5.1 Intra-scope edges

_(none: no relationships with both endpoints inside the scope)_

### 5.2 Built-in edges (`users` and other platform built-ins)

_(none: no relationships against platform built-ins)_

### 5.3 Cross-scope edges

#### 5.3a Outbound from this scope's masters and contributors

_Edges this scope drives: the in-scope endpoint has `role` of `master` or `contributor`._

_(none: no outbound cross-scope edges from this scope's masters or contributors)_

#### 5.3b Context edges on embedded shells and consumed entities

_Edges the canonical owner drives, shown for context: the in-scope endpoint has `role` of `embedded_master`, `consumer`, or `derived`._

_(none: no context cross-scope edges on this scope's embedded shells or consumed entities)_

## 6. Cross-domain context

### 6.1 Master consumers (other modules / domains that embed this scope's masters)

_(none: no other module embeds this scope's masters; the canonical owners do.)_

### 6.2 Outbound handoffs (events this scope publishes)

_(none: no outbound handoffs whose payload is in this scope)_

### 6.3 Inbound handoffs (events this scope reacts to)

_(none: no inbound handoffs whose payload is in this scope)_

### 6.4 Master providers (modules / domains that own masters this scope embeds)

_(none: this scope embeds no masters owned elsewhere; every entity is mastered here)_

## 7. Lifecycle states

_(none: no lifecycle states for the entities in this scope)_
## 8. Permissions and business rules (derived)

### 8.1 Permissions

| permission | tier | description | included in `:admin`? |
| --- | --- | --- | --- |
| `svcs-proc-settlement:read` | baseline-read | Read access to every entity in the module | ✓ |
| `svcs-proc-settlement:manage` | baseline-manage | Edit operational records | ✓ |
| `svcs-proc-settlement:admin` | baseline-admin | Edit reference data and inherit every workflow gate below | - |

### 8.2 Business rules

| rule_name | data_object | source flag | intent |
| --- | --- | --- | --- |
| `approve_service_acceptance_requires_approver` | `service_acceptances` | has_single_approver | Exactly one explicit approver required; uses the module's approval gate (`svcs-proc-settlement:approve_service_acceptance` if surfaced as a lifecycle workflow gate). |

## 9. Roles, RACI, and responsibilities (derived)

_Baseline roles, the permission hierarchy, and RACI realization are DERIVED from this scope's entity-type write tiers + `process_raci`; none of it is stored in the catalog (the deployer provisions it from this blueprint)._

### 9.1 `SVCS-PROC-SETTLEMENT`

**Baseline roles:**

| role | baseline grant |
| --- | --- |
| `svcs-proc-settlement_viewer` | `svcs-proc-settlement:read` |
| `svcs-proc-settlement_manager` | `svcs-proc-settlement:manage` |

**Permission hierarchy:**

| permission | includes |
| --- | --- |
| `svcs-proc-settlement:admin` | `svcs-proc-settlement:manage` |
| `svcs-proc-settlement:manage` | `svcs-proc-settlement:read` |

**RACI realization:**

_(none: no process_raci assignments wired to this module's gated processes yet)_

### 9.2 Functional ownership and default grants

_(none: no business_function_domains rows for this scope's domain)_
