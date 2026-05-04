---
name: workforce-planning
description: >-
  Use this skill for anything involving Workforce Planning, the in-house
  domain that tracks the current org (departments, locations, cost
  centers, jobs, employees, positions) as the source-of-truth baseline
  and lets planners draft headcount plans with scenarios, stage
  add/eliminate/transfer actions, commit approved scenarios into real
  positions, and hand seats off to recruiting via lightweight
  requisitions. Trigger when the user says: "draft a headcount plan
  for FY26", "add a Senior Engineer to the aggressive growth scenario",
  "set the base case as active for the FY26 plan", "approve the FY26
  headcount plan", "commit the approved scenario into real positions",
  "open a requisition for the new SWE seat", "fill position POS-00123
  with Jane Doe", "Bob is leaving, terminate him and open his seat",
  "backfill Alice's seat", "what's our open headcount by department",
  "show planned vs filled FTE by cost center", "who approved the FY26
  plan". Loads alongside `use-semantius`, which owns CLI install,
  PostgREST encoding, and cube query mechanics.
semantic_model: workforce_planning
---

# Workforce Planning

This skill carries the domain map and the jobs-to-be-done for
Workforce Planning. Platform mechanics, CLI install, env vars,
PostgREST URL-encoding, `sqlToRest`, cube `discover`/`validate`/`load`,
and schema-management tools, live in `use-semantius`. Assume it loads
alongside; do not re-explain CLI basics here.

If a task is purely about defining schema, managing permissions, or
running ad-hoc queries against tables you already know, call
`use-semantius` directly, going through this skill adds nothing.

**Auto-managed fields** (set by Semantius on every table; never include
in POST/PATCH bodies): `id`, `created_at`, `updated_at`. Every other
required field is caller-populated and must appear in the POST body.
That includes the natural identifier columns each entity uses as its
label (`department_name`, `location_name`, `cost_center_code`,
`job_name`, `employee_full_name`, `position_code`, `plan_name`,
`scenario_name`, `requisition_number`), all required on insert, and
the explicitly caller-composed `headcount_actions.action_label`. The
composition convention for `action_label` is given in its JTBD below.

---

## Domain glossary

The planning loop runs **Headcount Plan -> Scenario -> Headcount
Action -> (commit) -> Position -> Hiring Requisition**, with
`Department`, `Location`, `Cost Center`, `Job`, and `Employee` as the
source-of-truth org baseline that scenarios reshape.

| Concept | Table | Notes |
|---|---|---|
| Department | `departments` | Org unit; optional self-hierarchy via `parent_department_id` |
| Location | `locations` | Office, regional hub, remote pool, or field site |
| Cost Center | `cost_centers` | Financial bucket headcount cost is budgeted against |
| Job | `jobs` | Reusable role definition (title + level + family) that templates positions |
| Employee | `employees` | Current workforce member; can occupy at most one position |
| Position | `positions` | A discrete seat (filled, open, approved-future, on-hold, eliminated) |
| Headcount Plan | `headcount_plans` | Named fiscal-period plan; container for scenarios |
| Scenario | `scenarios` | What-if version of a plan (base / optimistic / conservative / custom); exactly one per plan is `is_active_for_plan = true` |
| Headcount Action | `headcount_actions` | Staged add / eliminate / transfer inside a scenario; materializes into a position on commit |
| Hiring Requisition | `hiring_requisitions` | Lightweight handoff to recruiting once a seat is cleared |

## Key enums

Only the enums that gate JTBDs are listed; full enum sets live in the
semantic model. Arrows mark the typical lifecycle path; `|` separates
terminal states.

- `headcount_plans.plan_status`: `draft` -> `in_review` -> `approved` -> `active` -> `archived`
- `scenarios.scenario_status`: `draft` -> `in_review` -> `approved` -> `archived`
- `headcount_actions.action_type`: `add`, `eliminate`, `transfer` (polymorphic; required FK fields differ per type)
- `headcount_actions.action_status`: `proposed` -> `in_review` -> `approved` -> `committed` | `rejected`
- `positions.position_status`: `open`, `filled`, `approved_future`, `on_hold`, `eliminated`
- `employees.employment_status`: `pending_start` -> `active` -> `on_leave` | `terminated`
- `hiring_requisitions.requisition_status`: `open` -> `on_hold` | `filled` | `cancelled`

## Foreign-key cheatsheet

Only the FKs that JTBDs cross. Format: `child.field -> parent.id`
(delete behavior in parens).

- `scenarios.headcount_plan_id -> headcount_plans.id` (parent, cascade)
- `headcount_actions.scenario_id -> scenarios.id` (parent, cascade)
- `headcount_actions.target_position_id -> positions.id` (clear; required for `eliminate` and `transfer`, null for `add`)
- `headcount_actions.job_id -> jobs.id` (clear; required for `add`)
- `headcount_actions.department_id -> departments.id` (clear; required for `add`, target dept for `transfer`)
- `headcount_actions.location_id -> locations.id` (clear; required for `add`, target loc for `transfer`)
- `headcount_actions.cost_center_id -> cost_centers.id` (clear; required for `add`, target cc for `transfer`)
- `positions.job_id -> jobs.id` (**restrict**)
- `positions.department_id -> departments.id` (**restrict**)
- `positions.location_id -> locations.id` (**restrict**)
- `positions.cost_center_id -> cost_centers.id` (**restrict**)
- `positions.current_employee_id -> employees.id` (clear; **1:1, `unique_value: true`** -> at most one position per employee)
- `positions.backfill_for_position_id -> positions.id` (clear, self)
- `positions.originated_from_action_id -> headcount_actions.id` (clear; set on commit so the action -> position lineage is queryable)
- `hiring_requisitions.position_id -> positions.id` (**restrict**: positions with requisitions cannot be deleted; eliminate them via the right JTBD)
- `headcount_plans.owner_employee_id`, `.approved_by_employee_id -> employees.id` (clear)

**Unique columns** (409 on duplicate POST): `departments.department_name`,
`departments.department_code`, `cost_centers.cost_center_code`,
`jobs.job_code`, `employees.employee_number`, `employees.work_email`,
`positions.position_code`, `hiring_requisitions.requisition_number`,
plus `positions.current_employee_id` (the 1:1 employee-fills-position
constraint).

**No DB-level uniqueness on the natural "active scenario per plan"
key.** `scenarios(headcount_plan_id, is_active_for_plan = true)` is
not constrained; the rule that exactly one scenario per plan is the
active one is enforced client-side. Recipes that flip
`is_active_for_plan = true` must read existing actives in the plan
and clear them in the same flow.

**Audit-logged tables** (Semantius writes the audit rows automatically;
recipes do not manage them): `employees`, `positions`,
`headcount_plans`, `scenarios`, `headcount_actions`,
`hiring_requisitions`. The other tables are not audit-logged.

---

## Jobs to be done

### Stage a headcount action

**Triggers:** `add a Senior Engineer to the aggressive growth scenario`,
`stage an eliminate on POS-00123`, `transfer position POS-00045 from
Sales to Marketing`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `scenario_id` | yes | Resolve via plan + scenario name if the user names them |
| `action_type` | yes | One of `add`, `eliminate`, `transfer` |
| `effective_date` | yes | The date the change should take effect |
| For `add`: `job_id`, `department_id`, `location_id`, `cost_center_id`, `fte`, `budgeted_annual_cost` | yes (all FKs) | Lookup each by name; `fte` defaults to 1.0 if not given |
| For `eliminate`: `target_position_id` | yes | Lookup by `position_code=eq.<code>` |
| For `transfer`: `target_position_id` plus the destination `department_id` and/or `location_id` and/or `cost_center_id` | yes | Lookup target position by code; lookup destination FKs by name |
| `justification` | no | Free text |

**Lookup convention.** Semantius adds a `search_vector` column to
searchable entities for full-text search across all text fields. Use
it whenever the user passes a name, title, code, etc., not a UUID:

```bash
# Resolve a position by anything the user typed (code, job title, etc.)
semantius call crud postgrestRequest '{"method":"GET","path":"/positions?search_vector=wfts(simple).<term>&select=id,position_code,position_status,job_id,department_id,location_id,cost_center_id"}'
```

Use `wfts(simple).<term>` for fuzzy text searches, never `ilike` and
never `fts`, they bypass the search index and mismatch the platform
convention. `eq.<value>` is the right tool for known-exact values
(UUIDs, FK ids, status enums, unique columns like `position_code`,
`job_code`, `cost_center_code`, `department_code`).

**Caller-populated label.** `headcount_actions.action_label` is
required on insert and not auto-derived. Compose it as
`"{Type} {job.job_name} / {department.department_name} / {location.location_name} / {effective_date YYYY-Qn}"`
for `add` actions, e.g. `"Add Senior Engineer / Engineering /
Berlin / 2026-Q1"`. For `eliminate` use
`"Eliminate {position.position_code} ({job.job_name})"`. For
`transfer` use
`"Transfer {position.position_code} to {department.department_name} / {location.location_name}"`.
The recipe must read the referenced rows to have the values to
compose with.

**This is a Pattern B polymorphic insert.** The required FK set
differs per `action_type` and the schema accepts any combination; if
you POST an `add` without `job_id`, the row inserts and the commit
cascade then has nothing to materialize. Validate the type-specific
required fields client-side.

**Recipe (`add`):**

```bash
# 1. Resolve scenario, job, department, location, cost center
semantius call crud postgrestRequest '{"method":"GET","path":"/scenarios?search_vector=wfts(simple).<term>&select=id,scenario_name,scenario_status,headcount_plan_id"}'
semantius call crud postgrestRequest '{"method":"GET","path":"/jobs?search_vector=wfts(simple).<term>&select=id,job_name,job_level"}'
semantius call crud postgrestRequest '{"method":"GET","path":"/departments?search_vector=wfts(simple).<term>&select=id,department_name"}'
semantius call crud postgrestRequest '{"method":"GET","path":"/locations?search_vector=wfts(simple).<term>&select=id,location_name"}'
semantius call crud postgrestRequest '{"method":"GET","path":"/cost_centers?search_vector=wfts(simple).<term>&select=id,cost_center_code,cost_center_name"}'

# 2. Sanity-check: scenario.scenario_status is `draft` or `in_review` (you cannot stage actions on an approved or archived scenario)

# 3. Stage the add
semantius call crud postgrestRequest '{
  "method":"POST",
  "path":"/headcount_actions",
  "body":{
    "action_label":"Add <job.job_name> / <department.department_name> / <location.location_name> / <effective_date YYYY-Qn>",
    "scenario_id":"<scenario id>",
    "action_type":"add",
    "action_status":"proposed",
    "job_id":"<job id>",
    "department_id":"<department id>",
    "location_id":"<location id>",
    "cost_center_id":"<cost center id>",
    "effective_date":"<YYYY-MM-DD>",
    "fte":1.0,
    "budgeted_annual_cost":150000,
    "justification":"<text>"
  }
}'
```

**Recipe (`eliminate`):**

```bash
# 1. Resolve the target position and the scenario
semantius call crud postgrestRequest '{"method":"GET","path":"/positions?position_code=eq.<code>&select=id,position_code,position_status,job_id,job:job_id(job_name)"}'

# 2. Refuse if position.position_status is already `eliminated`

# 3. Stage the eliminate
semantius call crud postgrestRequest '{
  "method":"POST",
  "path":"/headcount_actions",
  "body":{
    "action_label":"Eliminate <position.position_code> (<job.job_name>)",
    "scenario_id":"<scenario id>",
    "action_type":"eliminate",
    "action_status":"proposed",
    "target_position_id":"<position id>",
    "effective_date":"<YYYY-MM-DD>",
    "justification":"<text>"
  }
}'
```

**Recipe (`transfer`):**

```bash
# 1. Resolve target position and the destination department / location / cost center (any subset can change)
semantius call crud postgrestRequest '{"method":"GET","path":"/positions?position_code=eq.<code>&select=id,position_code,department_id,location_id,cost_center_id"}'

# 2. Stage the transfer (set only the destination fields the user is changing)
semantius call crud postgrestRequest '{
  "method":"POST",
  "path":"/headcount_actions",
  "body":{
    "action_label":"Transfer <position.position_code> to <department.department_name> / <location.location_name>",
    "scenario_id":"<scenario id>",
    "action_type":"transfer",
    "action_status":"proposed",
    "target_position_id":"<position id>",
    "department_id":"<destination dept id, optional>",
    "location_id":"<destination location id, optional>",
    "cost_center_id":"<destination cost center id, optional>",
    "effective_date":"<YYYY-MM-DD>"
  }
}'
```

`effective_date`: set at call time from the user's intent; do not
copy the placeholder.

**Validation:** new row exists; `action_label` matches the
type-specific composition; the type-specific FK set is populated
(e.g. `add` has `job_id` + `department_id` + `location_id` +
`cost_center_id`, `eliminate` has `target_position_id`).

**Failure modes:**
- `scenario.scenario_status` is not `draft` or `in_review` -> refuse
  and tell the user; staging actions on an approved or archived
  scenario silently amends a finalized plan.
- `add` action posted without `job_id` -> the row inserts but the
  commit cascade has nothing to materialize; recover by PATCH-ing the
  missing FK before commit.
- `eliminate` / `transfer` posted with `target_position_id` pointing
  at an already-`eliminated` position -> commit will be a no-op; ask
  the user whether they meant a different seat.

---

### Set the active scenario for a plan

**Triggers:** `make the aggressive growth scenario the active one`,
`set base case as active for the FY26 plan`, `switch the active
scenario to conservative`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `scenario_id` (the new active) | yes | Resolve via plan + scenario name |

**This is a DB-unguarded uniqueness invariant.** The model declares
"exactly one scenario per plan should be `is_active_for_plan = true`"
but the schema does not enforce it. POSTing or PATCHing a second row
to `true` in the same plan succeeds silently and the commit JTBD
later picks an arbitrary one. Always read existing actives in the
plan and clear them in the same flow.

**Recipe:**

```bash
# 1. Read the new scenario to find its plan, and read all currently-active siblings in that plan
semantius call crud postgrestRequest '{"method":"GET","path":"/scenarios?id=eq.<new id>&select=id,scenario_name,headcount_plan_id"}'
semantius call crud postgrestRequest '{"method":"GET","path":"/scenarios?headcount_plan_id=eq.<plan id>&is_active_for_plan=eq.true&select=id,scenario_name"}'

# 2. Clear any existing actives (excluding the new one, which may already be true)
semantius call crud postgrestRequest '{
  "method":"PATCH",
  "path":"/scenarios?headcount_plan_id=eq.<plan id>&id=neq.<new id>&is_active_for_plan=eq.true",
  "body":{"is_active_for_plan":false}
}'

# 3. Flip the new one on
semantius call crud postgrestRequest '{
  "method":"PATCH",
  "path":"/scenarios?id=eq.<new id>",
  "body":{"is_active_for_plan":true}
}'
```

**Validation:** a follow-up read with
`headcount_plan_id=eq.<plan id>&is_active_for_plan=eq.true` returns
exactly one row, and that row is the new scenario.

**Failure modes:**
- Step 2 was skipped -> two scenarios in the plan are now `true`;
  recover by re-running step 2 (which is idempotent against the new
  id) and re-validating.
- The new scenario belongs to a different plan than the user named ->
  abort and ask; activating across plan boundaries is almost always a
  mistake.

---

### Approve a headcount plan

**Triggers:** `approve the FY26 headcount plan`, `mark the plan as
approved`, `sign off the FY26 plan`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `headcount_plan_id` | yes | Resolve via `plan_name` if the user names it |
| `approved_by_employee_id` | yes | Lookup employee by `work_email=eq.<email>` (unique) or fuzzy name |

**Paired write rule.** `plan_status=approved` and the side-effect
fields `approved_at` + `approved_by_employee_id` must move together
in a single PATCH. Setting `plan_status=approved` without the
approver and timestamp leaves a row that downstream reports treat as
"approved by unknown" and audit cannot reconstruct.

**Recipe:**

```bash
# 1. Resolve the plan and the approver
semantius call crud postgrestRequest '{"method":"GET","path":"/headcount_plans?search_vector=wfts(simple).<term>&select=id,plan_name,plan_status,fiscal_year_label"}'
semantius call crud postgrestRequest '{"method":"GET","path":"/employees?work_email=eq.<email>&select=id,employee_full_name"}'

# 2. Refuse if plan_status is not `in_review` (you cannot approve a `draft` directly; submit it for review first, and a plan that is already `approved`/`active`/`archived` should not be re-approved)

# 3. Approve in one call
semantius call crud postgrestRequest '{
  "method":"PATCH",
  "path":"/headcount_plans?id=eq.<plan id>",
  "body":{
    "plan_status":"approved",
    "approved_at":"<current ISO timestamp>",
    "approved_by_employee_id":"<approver id>"
  }
}'
```

`approved_at`: set to the current timestamp at call time; do not
copy the placeholder.

**Validation:** `plan_status=approved`, `approved_at` non-null,
`approved_by_employee_id` non-null on the row.

**Failure modes:**
- Plan flipped to `approved` without `approved_at` /
  `approved_by_employee_id` -> reports cannot answer "who approved
  this and when"; PATCH to add both.
- The active scenario for this plan has `scenario_status` other than
  `approved` -> the commit JTBD will refuse anyway; tell the user to
  approve the active scenario first, or pick a different scenario as
  active before approving the plan.

---

### Commit an approved scenario into real positions

**Triggers:** `commit the approved scenario into real positions`,
`materialize the FY26 plan`, `flip the approved actions into seats`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `scenario_id` | yes | Resolve via plan + scenario name; must be `is_active_for_plan = true` and `scenario_status = approved` |

**This is a Pattern C materialization.** Committing a scenario is
not a single PATCH; it ripples across multiple tables, and the
schema does not chain any of it:

1. For each action in the scenario with `action_status=approved`,
   apply the type-specific change to `positions` and back-link the
   resulting position via `originated_from_action_id`.
   - `add` -> POST a new position with `position_status=approved_future`,
     fields copied from the action (`job_id`, `department_id`,
     `location_id`, `cost_center_id`, `fte`, `budgeted_annual_cost`),
     `target_start_date = action.effective_date`,
     `originated_from_action_id = <action id>`,
     `position_code` = a freshly-generated unique code (e.g.
     `POS-<YYYY>-<seq>`).
   - `eliminate` -> PATCH the target position to
     `position_status=eliminated`, `end_date = action.effective_date`.
     If the position was `filled`, the employee assignment must be
     cleared first via the Terminate-an-employee JTBD; the action
     should refuse if `current_employee_id` is non-null and tell the
     user to terminate or transfer the occupant.
   - `transfer` -> PATCH the target position with the destination
     `department_id` / `location_id` / `cost_center_id` from the
     action (only the fields the action populated change).
2. PATCH each successfully applied action to
   `action_status=committed`.
3. PATCH the scenario: `scenario_status=approved` (if not already)
   and `committed_at = <current ISO timestamp>`.
4. PATCH the plan: `plan_status=active`.

The DB guards none of this. If you stop after step 1 the actions are
still `approved` and the next commit re-applies them; if you stop
after step 2 the plan stays `approved` and reports treat the org as
"committed but not active".

**Recipe:**

```bash
# 1. Resolve the scenario and verify it is the active scenario in its plan and that its status is `approved`
semantius call crud postgrestRequest '{"method":"GET","path":"/scenarios?id=eq.<scenario id>&select=id,scenario_name,scenario_status,is_active_for_plan,headcount_plan_id"}'
# Refuse if scenario_status != `approved` or is_active_for_plan != true.

# 2. Read all approved actions in the scenario, by type
semantius call crud postgrestRequest '{"method":"GET","path":"/headcount_actions?scenario_id=eq.<scenario id>&action_status=eq.approved&select=id,action_type,target_position_id,job_id,department_id,location_id,cost_center_id,fte,budgeted_annual_cost,effective_date"}'

# 3a. For each `add` action, generate a fresh position_code and POST a new position
semantius call crud postgrestRequest '{
  "method":"POST",
  "path":"/positions",
  "body":{
    "position_code":"POS-<YYYY>-<seq>",
    "position_status":"approved_future",
    "job_id":"<from action>",
    "department_id":"<from action>",
    "location_id":"<from action>",
    "cost_center_id":"<from action>",
    "fte":1.0,
    "target_start_date":"<action.effective_date>",
    "budgeted_annual_cost":150000,
    "originated_from_action_id":"<action id>"
  }
}'

# 3b. For each `eliminate` action, first verify the target is not filled; then PATCH the target
semantius call crud postgrestRequest '{"method":"GET","path":"/positions?id=eq.<target id>&select=id,position_status,current_employee_id"}'
# Refuse if current_employee_id is non-null; tell the user to terminate or transfer the occupant first.
semantius call crud postgrestRequest '{
  "method":"PATCH",
  "path":"/positions?id=eq.<target id>",
  "body":{
    "position_status":"eliminated",
    "end_date":"<action.effective_date>",
    "originated_from_action_id":"<action id>"
  }
}'

# 3c. For each `transfer` action, PATCH only the destination fields the action populated
semantius call crud postgrestRequest '{
  "method":"PATCH",
  "path":"/positions?id=eq.<target id>",
  "body":{
    "department_id":"<destination, if action set it>",
    "location_id":"<destination, if action set it>",
    "cost_center_id":"<destination, if action set it>",
    "originated_from_action_id":"<action id>"
  }
}'

# 4. For each action that was applied successfully, flip its status
semantius call crud postgrestRequest '{
  "method":"PATCH",
  "path":"/headcount_actions?id=eq.<action id>",
  "body":{"action_status":"committed"}
}'

# 5. Stamp the scenario
semantius call crud postgrestRequest '{
  "method":"PATCH",
  "path":"/scenarios?id=eq.<scenario id>",
  "body":{"committed_at":"<current ISO timestamp>"}
}'

# 6. Activate the plan
semantius call crud postgrestRequest '{
  "method":"PATCH",
  "path":"/headcount_plans?id=eq.<plan id>",
  "body":{"plan_status":"active"}
}'
```

`target_start_date`, `end_date`, `committed_at`: set from
`action.effective_date` or current timestamp at call time; do not
copy the placeholders.

**Validation:** every approved action now has `action_status=committed`
and a `positions` row exists with its id in `originated_from_action_id`
(for `add`) or the target position has the expected status / fields
(for `eliminate` / `transfer`); the scenario has `committed_at` set;
the plan has `plan_status=active`.

**Failure modes:**
- A position-write fails mid-cascade -> the scenario is now in a
  half-applied state. Do not retry the whole loop; read each action's
  `action_status` and re-apply only the ones still `approved`. Tell
  the user.
- Target of an `eliminate` is `filled` -> step 3b refuses; route the
  user to Terminate-an-employee for the occupant, or to staging a
  `transfer` action to move them, before re-running commit.
- An action references an FK target (job, department, location, cost
  center) that has since been soft-deleted or set inactive -> the
  position POST may succeed but the resulting seat is unbudgetable;
  flag the action and ask the user to repair the FK or revise the
  scenario.
- The plan's `plan_status` was not `approved` when the user invoked
  this -> refuse at step 1; activate the plan via Approve-a-plan
  first.

---

### Open a hiring requisition for a position

**Triggers:** `open a requisition for the new SWE seat`, `hand
POS-00123 to recruiting`, `start hiring for position X`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `position_id` | yes | Lookup by `position_code=eq.<code>` |
| `opened_date` | yes | Today's date; do not bake a literal value |
| `hiring_manager_employee_id` | recommended | Lookup employee by email |
| `recruiter_employee_id` | no | Lookup employee by email |
| `target_fill_date` | no | If the user names a deadline |
| `external_ats_url` | no | Handoff link to the recruiting tool |

**`requisition_number` is unique and caller-populated.** Generate a
fresh code (e.g. `REQ-<YYYY>-<seq>`) and check uniqueness before
POST; the schema enforces the constraint and a duplicate POST
returns 409.

**Position must be hireable.** Only `position_status` in
(`open`, `approved_future`) is a valid origin for a requisition;
`filled` already has someone, `on_hold` and `eliminated` are not
recruiting targets. The schema does not enforce this, the recipe
does.

**Recipe:**

```bash
# 1. Resolve the position; refuse unless its status is `open` or `approved_future`
semantius call crud postgrestRequest '{"method":"GET","path":"/positions?position_code=eq.<code>&select=id,position_code,position_status,current_employee_id,target_start_date"}'

# 2. Resolve the recruiter and hiring manager (if named)
semantius call crud postgrestRequest '{"method":"GET","path":"/employees?work_email=eq.<email>&select=id,employee_full_name"}'

# 3. Check the requisition_number you plan to use is free
semantius call crud postgrestRequest '{"method":"GET","path":"/hiring_requisitions?requisition_number=eq.<REQ-YYYY-seq>&select=id"}'

# 4. Open
semantius call crud postgrestRequest '{
  "method":"POST",
  "path":"/hiring_requisitions",
  "body":{
    "requisition_number":"REQ-<YYYY>-<seq>",
    "position_id":"<position id>",
    "requisition_status":"open",
    "opened_date":"<today, YYYY-MM-DD>",
    "target_fill_date":"<optional YYYY-MM-DD>",
    "recruiter_employee_id":"<optional>",
    "hiring_manager_employee_id":"<optional>",
    "external_ats_url":"<optional>"
  }
}'
```

`opened_date` and `target_fill_date`: set at call time; do not copy
the placeholders.

**Validation:** new row exists with `requisition_status=open`;
`position_id` resolves to a position whose status is `open` or
`approved_future`.

**Failure modes:**
- Position is `filled` -> there is already an occupant; refuse and
  ask whether the user meant to backfill (which needs an eliminate
  + add scenario flow, or a backfill position created via
  Terminate-an-employee).
- Position is `eliminated` or `on_hold` -> refuse; recruiting against
  a closed seat creates a candidate pipeline that has nowhere to
  land.
- 409 on `requisition_number` -> someone else just took that code;
  bump the sequence and retry.

---

### Fill a position

**Triggers:** `fill position POS-00123 with Jane Doe`, `Jane is
starting Monday in the Berlin SWE seat`, `record that we hired Alex
into the open req`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `position_id` | yes | Lookup by `position_code` |
| `employee` | yes | Either an existing `employee_id` (lookup by `work_email` or fuzzy name) or a new-hire payload |
| `actual_start_date` | yes | Today or a near-future date |
| `requisition_id` | no | The open requisition for this position, if any |

**This is a Pattern C cascade.** Filling a seat ripples across up
to three tables, none of it DB-enforced:

1. `positions`: `position_status=filled`, set `current_employee_id`
   (1:1 unique), set `actual_start_date`. The 1:1 constraint on
   `current_employee_id` means if the employee is already on another
   position, that other position must be cleared (transfer) first
   or the POST returns 409.
2. `employees`: if the row is new, POST it with
   `employment_status=active` (or `pending_start` if the start date
   is in the future) and `hire_date`; if the row exists and is
   `pending_start`, PATCH to `active` and set `hire_date`.
3. `hiring_requisitions`: if a requisition exists for the position,
   PATCH `requisition_status=filled` and set `filled_date`.

If you stop after step 1 the funnel report says "seat filled" but
the employee has no hire date and the requisition is still `open`.

**Recipe (existing employee, e.g. internal move into an
`approved_future` seat):**

```bash
# 1. Resolve the position; refuse unless its status is `open` or `approved_future`
semantius call crud postgrestRequest '{"method":"GET","path":"/positions?position_code=eq.<code>&select=id,position_code,position_status,current_employee_id"}'

# 2. Resolve the employee; refuse if they already occupy a different position
semantius call crud postgrestRequest '{"method":"GET","path":"/employees?work_email=eq.<email>&select=id,employee_full_name,employment_status,hire_date"}'
semantius call crud postgrestRequest '{"method":"GET","path":"/positions?current_employee_id=eq.<employee id>&select=id,position_code"}'
# If the employee currently fills another position, route the user to a transfer (or clear the old seat first); the 1:1 unique on positions.current_employee_id will 409 otherwise.

# 3. Look up the open requisition for this position, if any
semantius call crud postgrestRequest '{"method":"GET","path":"/hiring_requisitions?position_id=eq.<position id>&requisition_status=eq.open&select=id,requisition_number"}'

# 4a. PATCH the position
semantius call crud postgrestRequest '{
  "method":"PATCH",
  "path":"/positions?id=eq.<position id>",
  "body":{
    "position_status":"filled",
    "current_employee_id":"<employee id>",
    "actual_start_date":"<YYYY-MM-DD>"
  }
}'

# 4b. PATCH the employee (if they were `pending_start`, flip to `active` and set hire_date)
semantius call crud postgrestRequest '{
  "method":"PATCH",
  "path":"/employees?id=eq.<employee id>",
  "body":{
    "employment_status":"active",
    "hire_date":"<YYYY-MM-DD>"
  }
}'

# 4c. PATCH the requisition (if one was found in step 3)
semantius call crud postgrestRequest '{
  "method":"PATCH",
  "path":"/hiring_requisitions?id=eq.<req id>",
  "body":{
    "requisition_status":"filled",
    "filled_date":"<YYYY-MM-DD>"
  }
}'
```

**Recipe (new hire, employee row does not exist yet):**

```bash
# Step 1 + 3 same as above; step 2 becomes a POST to create the employee
semantius call crud postgrestRequest '{
  "method":"POST",
  "path":"/employees",
  "body":{
    "employee_full_name":"<name>",
    "work_email":"<email>",
    "employee_number":"<unique number>",
    "employment_type":"full_time",
    "employment_status":"active",
    "hire_date":"<YYYY-MM-DD>",
    "home_location_id":"<optional>",
    "manager_employee_id":"<optional>"
  }
}'
# Then continue with steps 4a and 4c using the new employee id.
```

`actual_start_date`, `hire_date`, `filled_date`: set at call time;
do not copy the placeholders.

**Validation:** position has `position_status=filled` and
`current_employee_id` set; employee has `employment_status=active`
and `hire_date` set; if a requisition was open, it now has
`requisition_status=filled` and `filled_date` set.

**Failure modes:**
- 409 on `positions.current_employee_id` -> the employee already
  fills another position. Ask whether to stage a `transfer` action
  or to clear the old seat first.
- Step 4a succeeded but 4b or 4c failed -> the seat looks filled but
  reports break. Read each row, identify which steps did not stick,
  and PATCH only those.
- Position is `eliminated` -> the seat is closed; do not resurrect
  it. Stage an `add` action in a fresh scenario and commit it.

---

### Terminate an employee

**Triggers:** `Bob is leaving, terminate him and open his seat`,
`record that Alice resigned`, `mark Carol terminated as of June 30`

**Inputs:**

| Name | Required | Notes |
|---|---|---|
| `employee_id` | yes | Lookup by `work_email=eq.<email>` (unique) or fuzzy name |
| `termination_date` | yes | Last working day |
| Backfill? | no | If yes, the seat is reopened; otherwise it stays open with no occupant or is eliminated separately |

**This is a Pattern C cascade.** Terminating an employee touches
two tables, plus optionally a third (the new backfill seat), and
the schema enforces none of it:

1. `employees`: `employment_status=terminated`, set
   `termination_date`. Audit-logged, no extra write needed.
2. `positions`: if the employee was filling a position, clear
   `current_employee_id` and flip `position_status` from `filled`
   back to `open` (or to `eliminated` if the seat is genuinely
   going away, which is a separate decision the user should make).
   The 1:1 `unique_value: true` on `current_employee_id` means the
   *next* hire into that seat will only succeed once this row is
   cleared.
3. `hiring_requisitions` (optional): if the user wants to backfill,
   open a new requisition against the now-`open` position via the
   Open-a-requisition JTBD. If the seat is being eliminated, any
   open requisitions on it should be `cancelled` first because
   `hiring_requisitions.position_id` is `restrict`.

**Backfill positions are a separate concept.** If the user wants the
new hire to be tracked as a backfill of the departing employee's
seat (typical for replacement hires), the canonical flow is to
stage an `add` action in a scenario with `is_backfill=true` and
`backfill_for_position_id = <departing seat>`, then commit. Doing
the backfill directly on the live org skips planning sign-off; tell
the user before going that path.

**Recipe (terminate, leave the seat open):**

```bash
# 1. Resolve the employee and find their position (if any)
semantius call crud postgrestRequest '{"method":"GET","path":"/employees?work_email=eq.<email>&select=id,employee_full_name,employment_status,hire_date"}'
semantius call crud postgrestRequest '{"method":"GET","path":"/positions?current_employee_id=eq.<employee id>&select=id,position_code,position_status"}'

# 2. Refuse if employment_status is already `terminated`

# 3. Flip the employee
semantius call crud postgrestRequest '{
  "method":"PATCH",
  "path":"/employees?id=eq.<employee id>",
  "body":{
    "employment_status":"terminated",
    "termination_date":"<YYYY-MM-DD>"
  }
}'

# 4. If a position was found, clear the occupancy and reopen the seat
semantius call crud postgrestRequest '{
  "method":"PATCH",
  "path":"/positions?id=eq.<position id>",
  "body":{
    "position_status":"open",
    "current_employee_id":null
  }
}'
```

**Recipe (terminate and eliminate the seat):**

```bash
# Steps 1-3 same as above. Step 4 changes:
# 4a. Cancel any open requisitions on this position (the FK is restrict, so they would block deletion, but we are not deleting; cancel them so reports do not show them as still open)
semantius call crud postgrestRequest '{
  "method":"PATCH",
  "path":"/hiring_requisitions?position_id=eq.<position id>&requisition_status=eq.open",
  "body":{"requisition_status":"cancelled"}
}'

# 4b. Eliminate the seat (this is the live-org shortcut; the planning-sign-off path is to stage an `eliminate` action in a scenario and commit)
semantius call crud postgrestRequest '{
  "method":"PATCH",
  "path":"/positions?id=eq.<position id>",
  "body":{
    "position_status":"eliminated",
    "current_employee_id":null,
    "end_date":"<YYYY-MM-DD>"
  }
}'
```

`termination_date`, `end_date`: set at call time; do not copy the
placeholders.

**Validation:** employee has `employment_status=terminated` and
`termination_date` set; if their position was cleared, it now has
`current_employee_id=null` and `position_status` is either `open`
(seat survives) or `eliminated` with `end_date` set (seat closed).

**Failure modes:**
- Step 3 succeeded but step 4 failed -> the employee is terminated
  but the position still shows them as `current_employee_id`. The
  next hire into that seat returns 409 on the 1:1 unique. Recover
  by re-running step 4 only.
- The seat had an open requisition and the user chose to eliminate ->
  the FK on `hiring_requisitions.position_id` is `restrict`; cancel
  requisitions first (4a) before flipping the position to
  `eliminated`.
- The user wants the replacement to track as a backfill -> route to
  staging an `add` action with `is_backfill=true` and
  `backfill_for_position_id = <this seat>` rather than reopening
  this seat directly.

---

## Common queries

These are starting points, not contracts. Cube schema names drift
when the model is regenerated, so always run `cube discover '{}'`
first and map the dimension and measure names below against
`discover`'s output. The cube name is usually the entity's table
name with the first letter capitalized (e.g. `HeadcountActions`),
but verify.

```bash
# Always first
semantius call cube discover '{}'
```

```bash
# Open headcount by department and status
semantius call cube load '{"query":{
  "measures":["Positions.count","Positions.sum_fte"],
  "dimensions":["Departments.department_name","Positions.position_status"],
  "filters":[{"member":"Positions.position_status","operator":"equals","values":["open","approved_future","filled"]}],
  "order":{"Positions.count":"desc"}
}}'
```

```bash
# Planned vs filled FTE by cost center
semantius call cube load '{"query":{
  "measures":["Positions.sum_fte","Positions.sum_budgeted_annual_cost"],
  "dimensions":["CostCenters.cost_center_code","Positions.position_status"],
  "order":{"Positions.sum_budgeted_annual_cost":"desc"}
}}'
```

```bash
# Scenario action mix: count of actions by type and status, for a given plan
semantius call cube load '{"query":{
  "measures":["HeadcountActions.count"],
  "dimensions":["Scenarios.scenario_name","HeadcountActions.action_type","HeadcountActions.action_status"],
  "filters":[{"member":"HeadcountPlans.fiscal_year_label","operator":"equals","values":["FY2026"]}],
  "order":{"Scenarios.scenario_name":"asc"}
}}'
```

```bash
# Time-to-fill: avg days from requisition opened_date to filled_date, by hire month
# Read the dateFilteringGuide that discover returns; the avg_days_to_fill measure name
# is illustrative, check discover output for the real one or compute via a custom measure.
semantius call cube load '{"query":{
  "measures":["HiringRequisitions.avg_days_to_fill"],
  "timeDimensions":[{"dimension":"HiringRequisitions.filled_date","granularity":"month","dateRange":"last 12 months"}]
}}'
```

```bash
# Open requisitions by department, with age in days
semantius call cube load '{"query":{
  "measures":["HiringRequisitions.count","HiringRequisitions.avg_days_open"],
  "dimensions":["Departments.department_name"],
  "filters":[{"member":"HiringRequisitions.requisition_status","operator":"equals","values":["open"]}],
  "order":{"HiringRequisitions.count":"desc"}
}}'
```

---

## Guardrails

- Never PATCH `headcount_plans.plan_status=approved` without setting
  `approved_at` and `approved_by_employee_id` in the same call.
- Never PATCH `scenarios.is_active_for_plan=true` without first
  clearing other actives in the same plan; the schema does not
  enforce one-active-per-plan.
- Never POST a `headcount_action` whose type-specific FK set is
  incomplete (e.g. `add` without `job_id`, or `eliminate` without
  `target_position_id`); the commit cascade will silently do
  nothing for that row.
- Never commit a scenario unless its `scenario_status=approved` and
  `is_active_for_plan=true`; commit on a different scenario in the
  same plan creates conflicting positions.
- Never PATCH `positions.position_status=eliminated` on a `filled`
  seat without first clearing `current_employee_id` (and flipping
  the employee to `terminated` or transferring them); leaving a
  cleared employee still pointing at the seat 409s the next hire.
- Never POST a `hiring_requisition` for a position whose
  `position_status` is `filled`, `on_hold`, or `eliminated`.
- Never delete a `position` that has any `hiring_requisitions`; the
  FK is `restrict`. Cancel the requisitions first or, better,
  eliminate the position via lifecycle status rather than DELETE.
- Lookups for human-friendly identifiers (names, titles, codes) use
  `search_vector=wfts(simple).<term>`; never `ilike` and never
  `fts`. `eq.<value>` is for known-exact values (UUIDs, FK ids,
  status enums, unique columns like `position_code`, `job_code`,
  `cost_center_code`, `work_email`).
- Audit-logged tables (`employees`, `positions`, `headcount_plans`,
  `scenarios`, `headcount_actions`, `hiring_requisitions`) write
  their own audit rows; do not hand-write to any audit table.

## What this skill does NOT do

- Schema changes, use `use-semantius` directly.
- RBAC / permissions, use `use-semantius` directly.
- One-off seed data, write a script, do not bake it into a JTBD.
- Position-occupancy history: only the current occupant is tracked
  on `positions.current_employee_id`; no `position_assignments`
  table exists yet.
- Skills / competencies catalog: no `skills` entity or M:N junction
  to `jobs` / `employees`; skills-based planning is not modeled.
- Promotions, reclassifications, and comp changes: `action_type` is
  only `add` / `eliminate` / `transfer`; non-seat changes are not
  modeled.
- Multi-subsidiary planning: no `legal_entities` entity; everything
  rolls up into a single org.
- Attrition assumptions on scenarios: no `attrition_assumptions`
  entity; scenarios capture explicit actions only.
- Org-structure scenarios: scenarios stage position changes only,
  not new departments or department splits / merges.
- Full ATS: `hiring_requisitions` is a lightweight handoff with no
  `candidates`, `applications`, `interview_stages`, or `offers`.
- SSO / login link on employees: no `employees.user_id` reference
  to the platform's built-in `users`.
- M:N cost-center funding: a position has exactly one
  `cost_center_id`; multi-funded seats are not modeled.
