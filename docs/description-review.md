# Description review — all DD field descriptions

Every field description in the data dictionary, grouped by what happens to it.
201 fields. All groups reviewed and agreed.

- **title** — the current field title, shown so the restatement is visible in the row.
- **old** — the description at `f57f761~1`, the last commit before the description
  rework of 18 Sep. A `°` marks text that was a `COMMENT ON COLUMN` the rework
  deleted rather than a description.
- **current** — `schema.md` at HEAD (69fe953).
- **suggested** — the agreed action.

| action | count |
|---|---|
| retitle + remove description | 9 |
| retitle only | 1 |
| revert to the pre-18-Sep text | 19 |
| remove description | 18 |
| remove — generated filler | 6 |
| remove — restates the reference | 17 |
| remove — restates the title | 43 |
| trim | 7 |
| keep unchanged | 81 |

Net: 84 descriptions removed, 19 reverted, 7 trimmed, 10 titles changed.

## Retitle and remove description

Two where the title absorbs the fact. Seven reference fields where the reference already says what the field points at, so the title drops the redundant `Id` suffix and the description goes.

| entity.field | title | old | current | suggested |
|---|---|---|---|---|
| `audit_ddl_logs.event_time` | Event Time | When the DDL command completed | When the DDL command completed | **Event Time** → **Event Finish Time**, remove description |
| `audit_record_logs.record_pk` | Record PK | Primary key value of the affected record | Primary key value of the affected record | **Record PK** → **Record Primary Key**, remove description |
| `entities.module_id` | Module Id | — | Module this entity belongs to | **Module Id** → **Module**, remove description |
| `permissions.module_id` | Module Id | Module this permission belongs to | Module this permission belongs to | **Module Id** → **Module**, remove description |
| `role_permissions.role_id` | Role Id | Role this permission is granted to | Role this permission is granted to | **Role Id** → **Role**, remove description |
| `roles.module_id` | Module Id | Module this role belongs to | Module this role belongs to | **Module Id** → **Module**, remove description |
| `user_permissions.user_id` | User Id | User this permission is granted to | User this permission is granted to | **User Id** → **User**, remove description |
| `user_roles.user_id` | User Id | User this role is assigned to | User this role is assigned to | **User Id** → **User**, remove description |
| `user_roles.role_id` | Role Id | Role assigned to the user | Role assigned to the user | **Role Id** → **Role**, remove description |

## Retitle only

Description keeps its fact; only the title loses the `Id` suffix.

| entity.field | title | old | current | suggested |
|---|---|---|---|---|
| `audit_record_logs.user_id` | User Id | Internal user id from JWT context (0 when unavailable) | Internal user id from JWT context (0 when unavailable) | **User Id** → **User**, description unchanged |

## Revert to the pre-18-Sep text

The rework replaced working text. Restore what was there. `process_gates.id` had no description then, so it gets none now.

| entity.field | title | old | current | suggested |
|---|---|---|---|---|
| `dashboards.view_permission` | View Permission | Permission required to view this dashboard | Permission required to view this dashboard, by name | **revert to**: Permission required to view this dashboard |
| `entities.table_name` | Table Name | Physical table name in database | Physical table name in database: lowercase letters, digits and _, starting with a letter or _ | **revert to**: Physical table name in database |
| `entities.edit_permission` | Edit Permission | Permission required to INSERT/UPDATE/DELETE from this table | Permission required to INSERT/UPDATE/DELETE from this table, by name | **revert to**: Permission required to INSERT/UPDATE/DELETE from this table |
| `entities.id_column` | Id Column | Name of primary key column | Name of the primary key column, created automatically | **revert to**: Name of primary key column |
| `entities.label_column` | Label Column | Name of label/display column | Name of the label/display column, created automatically | **revert to**: Name of label/display column |
| `entities.label_parent` | Label Parent | Names the reference/parent FK that is this entity's identity spine for the composed _label. Empty = intrinsic/self-identifying (composed label = local label). | Reference or parent field of this entity whose record label the composed _label is built from (the identity spine). Empty = self-identifying: the composed label is the local label. Not allowed on a junction entity, and the spine must stay acyclic. | **revert to**: Names the reference/parent FK that is this entity's identity spine for the composed _label. Empty = intrinsic/self-identifying (composed label = local label). |
| `entities.order_column` | Order Column | Store a fixed row order in this column | Name of an integer column that stores a fixed row order. Setting it creates the column, and a record inserted without a value gets MAX + 10. Empty = no fixed order. | **revert to**: Store a fixed row order in this column |
| `entities.audit_log` | Audit Log | When enabled, DML operations on this table are logged to the audit log | When TRUE, DML operations on this table are logged to audit_record_logs | **revert to**: When enabled, DML operations on this table are logged to the audit log |
| `entities.computed_fields` | Computed Fields | JsonLogic derivations evaluated on every write | Ordered list of {name, jsonlogic, description?} entries, evaluated and stored on every insert and update: each entry derives the named field from the same record before the write | **revert to**: JsonLogic derivations evaluated on every write |
| `entities.validation_rules` | Validation Rules | JsonLogic invariants that must hold for the write to succeed | Ordered list of {code, message, jsonlogic, description?} entries; each must evaluate truthy for the write to succeed | **revert to**: JsonLogic invariants that must hold for the write to succeed |
| `entities.select_rule` | Select Rule | JsonLogic rule for per-row FOR SELECT RLS policy | JsonLogic rule evaluated per row for the FOR SELECT RLS policy: true = the current user may see the record. Empty = no per-row rule. | **revert to**: JsonLogic rule for per-row FOR SELECT RLS policy |
| `fields.field_name` | Field Name | Physical column name in database | Physical column name in database: lowercase letters, digits and _. Names starting with _ are reserved for generated system columns such as _label. | **revert to**: Physical column name in database |
| `fields.ctype` | Column Type | Special column type (id, label, etc.) | Marks a DD-managed core column: empty (normal user field), id (primary key), label (display field), audit (record-versioning columns such as created_at and updated_at) or core (other system columns). A core column cannot be deleted or renamed (the label column may be renamed), and its format and default value cannot change. Set by the DD only and never changed. | **revert to**: Special column type (id, label, etc.) |
| `fields.unique_value` | Unique Value | When TRUE, enforces a partial unique index (NULL and empty strings are not enforced) | When TRUE, enforces a partial unique index on this column. For string types, NULL and empty string values are excluded from the uniqueness check. | **revert to**: When TRUE, enforces a partial unique index (NULL and empty strings are not enforced) |
| `modules.view_permission` | View Permission | Permission required to view this module | Permission required to view this module, by name | **revert to**: Permission required to view this module |
| `modules.catalog_module_code` | Catalog Module Code | Catalog blueprint this module was provisioned/cloned from; also the domain axis (non-unique). Empty = greenfield. | Catalog blueprint this module was provisioned/cloned from; also the domain axis (non-unique). Write-once: set on create or filled once while empty, then never changed. Empty = not generated from a catalog spec. | **revert to**: Catalog blueprint this module was provisioned/cloned from; also the domain axis (non-unique). Empty = greenfield. |
| `permission_hierarchy.origin` | Origin | How this hierarchy entry was created | How the hierarchy entry was created: system (platform built-in), model (declared in the model of a domain module), model_master (created by the deployer for a master module, inside it or between it and other modules) or user (added by an admin). Set on insert and never changed. | **revert to**: How this hierarchy entry was created |
| `processes.module_id` | Module | Owning module | Owning module. NULL = cross-module or unowned process | **revert to**: Owning module |
| `process_gates.id` | Id | — | Internal identifier, assigned automatically | **revert** — no old description, so remove |

## Remove description

Kept by the first pass, cut on review.

| entity.field | title | old | current | suggested |
|---|---|---|---|---|
| `dashboards.id` | Id | — | Internal identifier, assigned automatically | **remove description** |
| `fields.description` | Description | Detailed description of the field (used for COMMENT ON COLUMN) ° | What the field represents. Also written into the column comment, which PostgREST shows in its OpenAPI output. | **remove description** |
| `modules.id` | Id | — | Internal identifier, assigned automatically | **remove description** |
| `processes.id` | Id | — | Internal identifier, assigned automatically | **remove description** |
| `queues.id` | Id | — | Internal identifier, assigned automatically | **remove description** |
| `queue_table_events.id` | Id | — | Internal identifier, assigned automatically | **remove description** |
| `raci_assignments.id` | Id | — | Internal identifier, assigned automatically | **remove description** |
| `raci_events.id` | Id | — | Internal identifier, assigned automatically | **remove description** |
| `roles.id` | Id | — | Internal identifier, assigned automatically | **remove description** |
| `user_bookmarks.id` | Id | — | Internal identifier, assigned automatically | **remove description** |
| `user_permissions.id` | Id | Generated identifier (user_id.permission_name) | Generated identifier (user_id.permission_name) | **remove description** |
| `user_roles.id` | Id | Generated identifier (user_id.role_id) | Generated identifier (user_id.role_id) | **remove description** |
| `users.id` | Id | — | Internal identifier, assigned automatically | **remove description** |
| `users.first_name` | First Name | First name from JWT given_name claim | First name from JWT given_name claim | **remove description** |
| `users.last_name` | Last Name | Last name from JWT family_name claim | Last name from JWT family_name claim | **remove description** |
| `users.display_name` | Display Name | — | Display name from the JWT name claim | **remove description** |
| `webhook_receiver_logs.id` | Id | — | Internal identifier, assigned automatically | **remove description** |
| `webhook_receivers.id` | Id | — | Internal identifier, assigned automatically | **remove description** |

## Remove — generated filler

Manufactured by `create_dd_table` ([0070_dd_functions.sql:533](../apps/_core/migrations/0070_dd_functions.sql#L533)) and the managed-enable path ([0145_managed_enable.sql:342](../apps/_core/migrations/0145_managed_enable.sql#L342)). Both canned strings go: the label one and `Internal identifier, assigned automatically` for the id column.

| entity.field | title | old | current | suggested |
|---|---|---|---|---|
| `dashboards.label` | Dashboard | — | Name that identifies this dashboard | **remove** — generated filler |
| `queues.queue_name` | Queue | — | Name that identifies this queue | **remove** — generated filler |
| `queue_table_events.event_name` | Queue Table Event | — | Name that identifies this queue table event | **remove** — generated filler |
| `user_bookmarks.title` | User Bookmark | — | Name that identifies this user bookmark | **remove** — generated filler |
| `webhook_receiver_logs.label` | Webhook Receiver Log | — | Name that identifies this webhook receiver log | **remove** — generated filler |
| `webhook_receivers.label` | Webhook Receiver | — | Name that identifies this webhook receiver | **remove** — generated filler |

## Remove — restates the reference

`reference_table` already says what the field points at.

| entity.field | title | old | current | suggested |
|---|---|---|---|---|
| `dashboards.module_id` | Module | Module this dashboard belongs to | Module this dashboard belongs to | **remove** — restates the reference |
| `fields.table_name` | Table Name | — | Entity this field belongs to | **remove** — restates the reference |
| `modules.manage_permission` | Manage Permission | The manage permission for this module. Populated by scaffold. ° | Manage permission of this module, by name | **remove** — restates the reference |
| `modules.admin_permission` | Admin Permission | The admin permission for this module. Populated when any entity carries edit_permission: admin. ° | Admin permission of this module, by name | **remove** — restates the reference |
| `modules.default_viewer_role_id` | Default Viewer Role | FK to the default viewer role for this module. Populated by scaffold. ° | Default viewer role of this module | **remove** — restates the reference |
| `modules.default_manager_role_id` | Default Manager Role | FK to the default manager role for this module. Populated by scaffold. ° | Default manager role of this module | **remove** — restates the reference |
| `modules.default_admin_role_id` | Default Admin Role | FK to the default admin role for this module. Populated when admin permission is present. ° | Default admin role of this module | **remove** — restates the reference |
| `process_gates.process_id` | Process | The governed process | The governed process | **remove** — restates the reference |
| `queue_table_events.queue_id` | Queue | Parent queue this event belongs to | Parent queue this event belongs to | **remove** — restates the reference |
| `raci_assignments.process_id` | Process | The governed process | The governed process | **remove** — restates the reference |
| `raci_events.process_id` | Process | The governed process | The governed process | **remove** — restates the reference |
| `role_permissions.permission_name` | Permission Name | Permission granted to the role | Permission granted to the role, by name | **remove** — restates the reference |
| `role_permissions.granted_by` | Granted By | User who granted this permission | User who granted this permission | **remove** — restates the reference |
| `user_permissions.permission_name` | Permission Name | Permission granted to the user | Permission granted to the user, by name | **remove** — restates the reference |
| `user_permissions.granted_by` | Granted By | User who granted this permission | User who granted this permission | **remove** — restates the reference |
| `user_roles.assigned_by` | Assigned By | User who assigned this role | User who assigned this role | **remove** — restates the reference |
| `webhook_receiver_logs.webhook_receiver_id` | Webhook Receiver | Reference to webhook receiver configuration | Parent webhook receiver this log belongs to | **remove** — restates the reference |

## Remove — restates the title

Says nothing the title does not.

| entity.field | title | old | current | suggested |
|---|---|---|---|---|
| `audit_ddl_logs.object_type` | Object Type | Type of database object affected | Type of database object affected | **remove** — restates the title |
| `audit_record_logs.ts` | Timestamp | When the operation occurred | When the operation occurred | **remove** — restates the title |
| `audit_record_logs.table_schema` | Table Schema | Schema containing the table | Schema containing the table | **remove** — restates the title |
| `audit_record_logs.table_name` | Table Name | Name of the affected table | Name of the affected table | **remove** — restates the title |
| `dashboards.config` | Configuration | Dashboard layout and widget configuration | Dashboard layout and widget configuration | **remove** — restates the title |
| `dashboards.position` | Position | Display order position | Display order position | **remove** — restates the title |
| `entities.icon_url` | Icon URL | Optional URL or path to icon for this table | Optional URL or path to icon for this table | **remove** — restates the title |
| `entities.description` | Description | — | What the entity represents | **remove** — restates the title |
| `entities.edit_mode` | Edit Mode | UI edit mode for records of this table: auto, sidebar, modal, or page | UI edit mode for records of this table: auto, sidebar, modal, or page | **remove** — restates the title |
| `entities.cube_mode` | Cube Mode | Cube mode for OLAP cube generation | Cube mode for OLAP cube generation | **remove** — restates the title |
| `fields.format` | Format | JSON Schema format or primitive type | JSON Schema format or primitive type | **remove** — restates the title |
| `fields.title` | Title | Human-readable display name for the field | Human-readable display name for the field | **remove** — restates the title |
| `fields.field_order` | Field Order | Display order for the field ° | Display order of the field within its entity | **remove** — restates the title |
| `fields.searchable` | Searchable | Whether field is included in full-text search | Whether field is included in full-text search | **remove** — restates the title |
| `modules.module_name` | Module Name | Unique module name | Unique module name | **remove** — restates the title |
| `modules.description` | Description | — | What the module covers | **remove** — restates the title |
| `modules.icon_name` | Icon Name | Icon or logo name identifier | Icon or logo name identifier | **remove** — restates the title |
| `modules.home_page` | Home Page | Default home page path for module | Default home page path for module | **remove** — restates the title |
| `modules.settings` | Settings | Module-specific settings and configuration | Module-specific settings and configuration | **remove** — restates the title |
| `modules.version_date` | Version Date | Timestamp of last version change | Timestamp of last version change | **remove** — restates the title |
| `permissions.description` | Description | — | What the permission allows | **remove** — restates the title |
| `processes.name` | Name | Display name of the process | Display name of the process | **remove** — restates the title |
| `processes.description` | Description | Detailed description of the process | Detailed description of the process | **remove** — restates the title |
| `processes.ordering` | Ordering | Optional display ordering | Optional display ordering | **remove** — restates the title |
| `process_gates.gate_kind` | Gate Kind | Type of governance gate | Type of governance gate | **remove** — restates the title |
| `raci_assignments.raci` | RACI | Responsibility letter | Responsibility letter | **remove** — restates the title |
| `raci_events.entity` | Entity | Governed table name | Governed table name | **remove** — restates the title |
| `role_permissions.granted_at` | Granted At | Timestamp when permission was granted | Timestamp when permission was granted | **remove** — restates the title |
| `roles.role_name` | Role Name | Unique role name | Unique role name | **remove** — restates the title |
| `roles.description` | Description | — | What the role is for | **remove** — restates the title |
| `user_bookmarks.url` | URL | Bookmark URL | Bookmark URL | **remove** — restates the title |
| `user_bookmarks.entity_name` | Entity | Name of the related entity table | Name of the related entity table | **remove** — restates the title |
| `user_permissions.granted_at` | Granted At | Timestamp when permission was granted | Timestamp when permission was granted | **remove** — restates the title |
| `user_roles.assigned_at` | Assigned At | Timestamp when role was assigned | Timestamp when role was assigned | **remove** — restates the title |
| `users.email` | Email | — | Email address of the user | **remove** — restates the title |
| `users.is_disabled` | Is Disabled | — | When TRUE, the user account is disabled | **remove** — restates the title |
| `users.settings` | Settings | User-specific settings and preferences | User-specific settings and preferences | **remove** — restates the title |
| `users.last_seen` | Last Seen | Timestamp when user was last active | Timestamp when user was last active | **remove** — restates the title |
| `webhook_receiver_logs.received_timestamp` | Received Timestamp | Timestamp when webhook was received | Timestamp when webhook was received | **remove** — restates the title |
| `webhook_receiver_logs.payload` | Payload | Webhook payload data | Webhook payload data | **remove** — restates the title |
| `webhook_receiver_logs.error_message` | Error Message | Error message if processing failed | Error message if processing failed | **remove** — restates the title |
| `webhook_receivers.description` | Description | Description of webhook receiver purpose | Description of webhook receiver purpose | **remove** — restates the title |
| `webhook_receivers.secret` | Secret | Secret for webhook authentication | Secret for webhook authentication | **remove** — restates the title |

## Trim

Keep the half that carries a fact, drop the half that restates the title or repeats the enum list the column comment already appends.

| entity.field | title | old | current | suggested |
|---|---|---|---|---|
| `entities.searchable` | Searchable | Whether table is included in full-text search (auto-computed) | Whether table is included in full-text search (auto-computed) | trim to `Auto-computed from the label field` |
| `entities.is_child` | Is Child | Whether table has any parent relationships (auto-computed) | Whether table has any parent relationships (auto-computed) | trim to `Auto-computed from the parent fields` |
| `fields.is_pk` | Is Primary Key | Whether this field is the primary key ° | Whether this field is the primary key; cannot change after the field is created | trim to `Cannot change after the field is created` |
| `fields.width` | Width | Display width for UI rendering: default (auto), s (small), m (medium), or w (wide) ° | Display width of the field in the UI: default (automatic), s (small), m (medium) or w (wide) | trim to `default (automatic), s (small), m (medium), w (wide)` |
| `modules.module_type` | Module Type | Module type: domain (normal) or master (promoted for sharing) | Module type: domain (normal) or master (promoted for sharing) | trim to `domain = normal module; master = promoted for sharing` |
| `modules.logo_color` | Logo Color | Hex color code for module logo | Hex color code for module logo | trim to `Hex color code` |
| `webhook_receivers.auth_type` | Authentication Type | Type of authentication (none, hmac, or custom header) | Type of authentication (none, hmac, or custom header) | trim to `hmac = HMAC signature over the body; header = expected value in a named header` |

## Keep unchanged

Includes the two fields that have no description at all (`audit_ddl_logs.id`, `audit_record_logs.id`).

| entity.field | title | old | current | suggested |
|---|---|---|---|---|
| `audit_ddl_logs.id` | Id | — | — | keep |
| `audit_ddl_logs.user_id` | User Id | Internal user id from JWT context (0 when unavailable) | Internal user id from JWT context (0 when unavailable, e.g. during migrations) | keep |
| `audit_ddl_logs.command_tag` | Command Tag | DDL command type (e.g. CREATE TABLE, ALTER TABLE) | DDL command type (e.g. CREATE TABLE, ALTER TABLE) | keep |
| `audit_ddl_logs.object_identity` | Object Identity | Fully qualified name of the affected object | Fully qualified name of the affected object | keep |
| `audit_ddl_logs.query_text` | Query Text | The SQL statement that triggered the event | The SQL statement that triggered the event | keep |
| `audit_record_logs.id` | Id | — | — | keep |
| `audit_record_logs.record_id` | Record Id | Deterministic UUID computed from table OID and primary key values | Deterministic UUID computed from table OID and primary key values | keep |
| `audit_record_logs.old_record_id` | Old Record Id | Record id before update/delete | Record id before update/delete | keep |
| `audit_record_logs.op` | Operation | DML operation type: INSERT, UPDATE, DELETE, TRUNCATE | DML operation type: INSERT, UPDATE, DELETE, TRUNCATE | keep |
| `audit_record_logs.db_role` | DB Role | (new field) | session_user: the role that authenticated the connection. Unchanged by SET ROLE and by SECURITY DEFINER, so it names the connection rather than the execution context. The API writes as the authenticator role; any other value is an out-of-band write. | keep |
| `audit_record_logs.is_superuser` | Is Superuser | (new field) | Whether the writing session had superuser privileges. TRUE on a data row means RLS was bypassed. Reports the session, not the owner of a SECURITY DEFINER function. | keep |
| `audit_record_logs.client_addr` | Client Addr | (new field) | Connecting client address (inet_client_addr()); NULL for a unix-socket connection, which means a shell on the database host rather than a client on the network | keep |
| `audit_record_logs.table_oid` | Table OID | PostgreSQL internal object identifier for the table | PostgreSQL internal object identifier for the table | keep |
| `audit_record_logs.record` | Record | Full record after INSERT/UPDATE (JSONB) | Full record after INSERT/UPDATE (JSONB) | keep |
| `audit_record_logs.old_record` | Old Record | Previous record before UPDATE/DELETE (JSONB) | Previous record before UPDATE/DELETE (JSONB) | keep |
| `entities.singular` | Singular | Singular form of table name (auto-derived from table_name when blank) | Singular form of table name (auto-derived from table_name when blank) | keep |
| `entities.plural` | Plural | Plural form of table name, auto-assigned to table_name | Plural form of table name, auto-assigned to table_name | keep |
| `entities.singular_label` | Singular Label | Human-readable singular label for UI/reports | Human-readable singular label for UI/reports (e.g. Customer) | keep |
| `entities.plural_label` | Plural Label | Human-readable plural label for UI/reports | Human-readable plural label for UI/reports (e.g. Customers) | keep |
| `entities.view_permission` | View Permission | Permission required to SELECT from this table | Permission required to SELECT from this table, by name | keep |
| `entities.managed` | Managed | When false, automatic DDL execution is disabled | When false, automatic DDL execution for table and field changes is disabled | keep |
| `entities.entity_type` | Entity Type | Data-class axis (operational_workflow | What kind of data this entity holds. operational_workflow: records move through a gated lifecycle (even one gated step such as draft to submitted counts). operational_record: everyday business records without such a lifecycle. catalog: reference or lookup data maintained by admins. junction: a pure link between entities with no fields of its own; the platform labels its rows by the records they link. computed: every field is derived and never written directly. unclassified: not classified yet (the default). | keep |
| `entities.catalog_entity_code` | Catalog Entity Code | Stable canonical identity this entity realizes (uber-model code, e.g. vendors); the rename/dialect/silo join key. table_name holds the deployed name. Empty = created outside the deploy pipeline. | Stable canonical identity this entity realizes (uber-model code, e.g. vendors); the rename/dialect/silo join key. table_name holds the deployed name. Write-once: set on create or filled once while empty, then never changed. Empty = not generated from a catalog spec. | keep |
| `entities.catalog_owner_module` | Catalog Owner Module | For an embedded-master placeholder, the slug of the module that should own this entity. Soft pointer (not an FK); empty when this module is the owner or the entity is local. | For an embedded-master placeholder, the slug of the module that should own this entity. Soft pointer (not an FK); empty when this module is the owner or the entity is local. | keep |
| `entities.catalog_entity_aliases` | Catalog Entity Aliases | Reuse/merge record: JSON array of {alias_code, source_domain, source_module, decided}. Append-only. Empty array = never a merge target. | Reuse/merge record: JSON array of {alias_code, source_domain, source_module, decided}. Append-only. Empty array = never a merge target. | keep |
| `fields.id` | Id | Generated identifier (table_name.field_name) | Generated identifier (table_name.field_name) | keep |
| `fields.default_value` | Default Value | Default value for the field (as SQL expression) ° | Column default: a literal value or an SQL expression such as CURRENT_TIMESTAMP | keep |
| `fields.input_type` | Input Type | Input type for UI rendering: default, required, readonly, disabled, or hidden ° | How the UI presents the field for input; input_type_rule can override it per record | keep |
| `fields.enum_values` | Enum Values | JSON array of allowed enum values | JSON array of the allowed values of an enum field, e.g. ["active", "inactive", "pending"] | keep |
| `fields.precision` | Precision | Decimal scale used when generating NUMERIC columns for number formats | Decimal scale (digits after the decimal point) used when generating NUMERIC columns for number formats | keep |
| `fields.reference_table` | Reference Table | Table name for foreign key relationships | Entity this field references, by table name. Required for reference and parent fields, empty for all others, and must name an existing entity. | keep |
| `fields.reference_delete_mode` | Reference Delete Mode | ON DELETE behavior: restrict, clear, or cascade | What happens to this record when the referenced record is deleted: restrict (the delete is blocked), clear (this field is set to NULL) or cascade (this record is deleted too). Empty on fields that are not a reference or parent; on a reference, empty acts as restrict. | keep |
| `fields.relationship_label` | Relationship Label | Verb describing what the referenced entity does to/with this entity | Verb describing what the referenced entity does to/with this entity (e.g. employs, heads). Used for ER diagram and navigation labels. | keep |
| `fields.singular_label_parent` | Singular Label Parent | Custom singular label for the parent entity (overrides default when set) | Custom singular label for the parent entity when format is parent; overrides the singular_label of the parent entity when set | keep |
| `fields.plural_label_parent` | Plural Label Parent | Custom plural label for the parent entity (overrides default when set) | Custom plural label for the parent entity when format is parent; overrides the plural_label of the parent entity when set | keep |
| `fields.cube_type` | Cube Type | — | Role of the field in the generated OLAP cube (dimension or measure); auto lets the platform choose, disabled leaves the field out | keep |
| `fields.input_type_rule` | Input Type Rule | JsonLogic condition for field visibility | JsonLogic rule evaluated client-side against the record being edited. It returns an input_type (default, required, readonly, disabled or hidden) that replaces the static input_type. Empty = no rule. | keep |
| `fields.catalog_field_code` | Catalog Field Code | Stable design-time field identity (blueprint field name, e.g. status); the field-rename join key. Empty = created outside the deploy pipeline. | Stable design-time field identity (blueprint field name, e.g. status); the field-rename join key. Write-once: set on create or filled once while empty, then never changed. Empty = not generated from a catalog spec. | keep |
| `modules.module_slug` | Module Slug | URL-safe unique identifier for module | URL-safe unique identifier for the module: lowercase, starting with a letter or digit, using only a-z, 0-9, - and _. Derived from the module name when left empty. | keep |
| `modules.domain_code` | Domain Code | Short uppercase code for the business domain this module belongs to (e.g. ATS, HCM, ITSM, CRM) | Short uppercase code for the business domain this module belongs to (e.g. ATS, HCM, ITSM, CRM) | keep |
| `modules.access_scope` | Access Scope | Basic for simple read/edit; full for role tiers, approvals & gating | Access tier: basic (simple read/edit) or full (role tiers, approvals and gating) | keep |
| `modules.dashboard_config` | Dashboard Configuration | — | Layout and widgets of the module dashboard | keep |
| `modules.version` | Version | Auto-incremented version number | Auto-incremented version number | keep |
| `permission_hierarchy.id` | Id | Generated identifier (including_permission_name.included_permission_name) | Generated identifier (including_permission_name.included_permission_name) | keep |
| `permission_hierarchy.including_permission_name` | Including Permission Name | The broader permission that includes other permissions | The broader permission, by name: holding it implies the included permission (e.g. crm:manage includes crm:read). | keep |
| `permission_hierarchy.included_permission_name` | Included Permission Name | The narrower permission that is included by the broader one | The narrower permission that is included by the broader one, by name | keep |
| `permissions.permission_name` | Permission Name | Unique permission name | The permission itself, and the key other tables use to name it. Colon-separated segments of a-z, 0-9, - and _, each starting with a letter or digit, e.g. crm:read or service-catalog:view. No spaces, commas or dots: scope strings are split on commas and whitespace, and a dot would make permission_hierarchy ids ambiguous. | keep |
| `processes.process_key` | Process Key | Stable snake_case identifier, unique within module | Stable snake_case identifier, unique within module | keep |
| `process_gates.name` | Name | Display label — mirrors the gate kind (computed) | Display label — mirrors the gate kind (computed) | keep |
| `process_gates.entity` | Entity | Governed table name (mirrors entities.table_name) | Governed table name (mirrors entities.table_name) | keep |
| `process_gates.to_state` | To State | Target lifecycle state (empty for non-state-targeted gates) | Target lifecycle state (empty for non-state-targeted gates) | keep |
| `process_gates.state_column` | State Column | Column that holds the lifecycle state in the governed table | Column that holds the lifecycle state in the governed table | keep |
| `process_gates.emits_events` | Emits Events | When TRUE, entering to_state inserts raci_events | When TRUE, entering to_state inserts raci_events for the consulted and informed actors | keep |
| `queues.view_permission` | View Permission | Permission required to read messages from this queue (queue_read). Readers see the table, id and operation of every table mapped to this queue. | Permission required to read messages from this queue (queue_read), by name. Readers see the table, id and operation of every table mapped to this queue. | keep |
| `queues.manage_permission` | Manage Permission | Permission required to pop, archive or delete messages from this queue. | Permission required to pop, archive or delete messages from this queue, by name. | keep |
| `queue_table_events.table_name` | Table | Table whose DML events are captured | Table whose DML events are captured | keep |
| `queue_table_events.event_handler` | Event Handler | Which DML operations trigger a queue message | Which DML operations trigger a queue message | keep |
| `raci_assignments.name` | Name | Display label — mirrors the RACI letter (computed) | Display label — mirrors the RACI letter (computed) | keep |
| `raci_assignments.role_id` | Role | The persona role assigned this letter | The persona role assigned this letter | keep |
| `raci_assignments.consult_mode` | Consult Mode | Consultation mode (only for raci=consulted) | How a consulted actor takes part: read (passive), notify (push) or block (gate). Applies only when raci is consulted. | keep |
| `raci_assignments.origin` | Origin | How this row was created | How this row was created: system (generated by the platform) or user (created or edited by a user) | keep |
| `raci_events.record_id` | Record Id | Governed record PK (text for non-integer PKs) | Governed record PK (text for non-integer PKs) | keep |
| `raci_events.raci` | RACI | consulted or informed | RACI role of the actor. Only consulted and informed actors generate events, so these are the only values. | keep |
| `raci_events.target_role_id` | Target Role | Role to be notified or consulted | Role to be notified or consulted | keep |
| `raci_events.status` | Status | pending → sent → acted | pending → sent → acted; acted = the consultation input was received | keep |
| `raci_events.acted_at` | Acted At | When the consulted party responded (NULL until acted) | When the consulted party responded (NULL until acted) | keep |
| `role_permissions.id` | Id | Generated identifier (role_id.permission_name) | Generated identifier (role_id.permission_name) | keep |
| `roles.slug` | Slug | Snake_case unique identifier for role, auto-generated from role_name | Snake_case unique identifier for the role, derived from role_name when omitted. Cannot be changed on a system role. | keep |
| `roles.catalog_role_code` | Catalog Role Code | Stable catalog persona/role this role was provisioned from (lineage; non-unique). Empty = created outside the pipeline. | Stable catalog persona/role this role was provisioned from (lineage; non-unique). Write-once: set on create or filled once while empty, then never changed. Empty = not generated from a catalog spec. | keep |
| `roles.origin` | Origin | How this role was created: system (platform built-ins), model (domain module scaffold), model_master (master module scaffold), or user (admin-created). ° | How the role was created: system (platform built-in), model (scaffold role of a domain module), model_master (scaffold role of a master module) or user (created by an admin). Set on insert and never changed. | keep |
| `user_bookmarks.user_id` | User | Owner of this bookmark (auto-assigned to current user) | Owner of this bookmark (auto-assigned to current user) | keep |
| `user_bookmarks.entity_id` | Entity ID | ID of the related record in the entity table (0 = no record) | ID of the related record in the entity table (0 = no record) | keep |
| `users.external_id` | External Id | Identity: the JWT sub claim. Users bring theirs from the authentication provider; an agent saved without one gets agent:<uuid> | Identity: the JWT sub claim from the authentication provider. Never empty: a human user must bring one, and an agent saved without one gets agent:<uuid>. | keep |
| `users.is_agent` | Is Agent | When TRUE this user is a service principal (agent) | When TRUE this user is a service principal (agent) | keep |
| `webhook_receiver_logs.message_id` | Message Id | (new field) | The sender's webhook-id header, or a key derived from the request when it sends none. A delivery whose message_id already succeeded is skipped. | keep |
| `webhook_receiver_logs.webhook_timestamp` | Webhook Timestamp | Timestamp from webhook source | Timestamp from webhook source | keep |
| `webhook_receiver_logs.result` | Result | Processing result: 10=received, 20=processed, 90=failed | Processing result: 10=success, 20=signature failed, 30=invalid JSON, 40=target table not found, 50=insert failed, 60=JSONata transform error | keep |
| `webhook_receivers.table_name` | Table | Target table for webhook data | Target table for webhook data | keep |
| `webhook_receivers.header_name` | Header Name | Custom header name for authentication | Custom header name for authentication | keep |
| `webhook_receivers.header_value` | Header Value | Expected value for custom header authentication | Expected value for custom header authentication | keep |
| `webhook_receivers.jsonata` | JSONata Expression | Optional JSONata expression to transform incoming data | Optional JSONata expression to transform incoming data | keep |
