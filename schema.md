# Database Schema Documentation

This document describes the database schema for the _core module.

**Generated:** 2026-09-21T20:42:40.234Z

---

## Entity: audit_ddl_logs

DDL audit trail for schema change events

| field_name | label | value |
|------------|-------|-------|
| table_name | Table Name | `audit_ddl_logs` |
| singular | Singular | audit_ddl_log |
| plural | Plural | audit_ddl_logs |
| singular_label | Singular Label | Audit DDL Log |
| plural_label | Plural Label | Audit DDL Logs |
| icon_url | Icon URL | - |
| description | Description | DDL audit trail for schema change events |
| module_id | Module | 1 |
| view_permission | View Permission | `admin` |
| edit_permission | Edit Permission | `admin` |
| id_column | Id Column | `id` |
| label_column | Label Column | `command_tag` |
| label_parent | Label Parent | - |
| order_column | Order Column | - |
| managed | Managed | false |
| searchable | Searchable | true |
| is_child | Is Child | false |
| edit_mode | Edit Mode | auto |
| cube_mode | Cube Mode | auto |
| entity_type | Entity Type | unclassified |
| audit_log | Audit Log | false |
| computed_fields | Computed Fields | - |
| validation_rules | Validation Rules | - |
| select_rule | Select Rule | - |
| catalog_entity_code | Catalog Entity Code | - |
| catalog_owner_module | Catalog Owner Module | - |
| catalog_entity_aliases | Catalog Entity Aliases | - |

### Fields

| field_name | format | title | description | type | is_pk | default_value | field_order | input_type | width | ctype | searchable | enum_values | precision | reference_table | reference_delete_mode | relationship_label | singular_label_parent | plural_label_parent | unique_value | cube_type | input_type_rule | catalog_field_code |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `id` 🔑 (id) | int64 | Id | - | integer | true | - | 1 | readonly | default | id | false | - | 2 | - | - | has | - | - | false | auto | - | - |
| `event_time` (core) | date-time | Event Finish Time | - | string | false | - | 10 | readonly | default | core | false | - | 2 | - | - | has | - | - | false | auto | - | - |
| `user_id` (core) | int32 | User | From the JWT context; 0 when unavailable, e.g. during migrations | integer | false | - | 20 | readonly | default | core | false | - | 2 | - | - | has | - | - | false | auto | - | - |
| `command_tag` (label) | text | Command Tag | DDL command type (e.g. CREATE TABLE, ALTER TABLE) | string | false | - | 30 | readonly | default | label | true | - | 2 | - | - | has | - | - | false | auto | - | - |
| `object_type` (core) | text | Object Type | - | string | false | - | 40 | readonly | default | core | true | - | 2 | - | - | has | - | - | false | auto | - | - |
| `object_identity` (core) | text | Object Identity | Fully qualified name of the affected object | string | false | - | 50 | readonly | w | core | true | - | 2 | - | - | has | - | - | false | auto | - | - |
| `query_text` (core) | text | Query Text | The SQL statement that triggered the event | string | false | - | 60 | readonly | w | core | false | - | 2 | - | - | has | - | - | false | auto | - | - |

---

## Entity: audit_record_logs

DML audit trail for entity table records

| field_name | label | value |
|------------|-------|-------|
| table_name | Table Name | `audit_record_logs` |
| singular | Singular | audit_record_log |
| plural | Plural | audit_record_logs |
| singular_label | Singular Label | Audit Record Log |
| plural_label | Plural Label | Audit Record Logs |
| icon_url | Icon URL | - |
| description | Description | DML audit trail for entity table records |
| module_id | Module | 1 |
| view_permission | View Permission | `admin` |
| edit_permission | Edit Permission | `admin` |
| id_column | Id Column | `id` |
| label_column | Label Column | `table_name` |
| label_parent | Label Parent | - |
| order_column | Order Column | - |
| managed | Managed | false |
| searchable | Searchable | true |
| is_child | Is Child | false |
| edit_mode | Edit Mode | auto |
| cube_mode | Cube Mode | auto |
| entity_type | Entity Type | unclassified |
| audit_log | Audit Log | false |
| computed_fields | Computed Fields | - |
| validation_rules | Validation Rules | - |
| select_rule | Select Rule | - |
| catalog_entity_code | Catalog Entity Code | - |
| catalog_owner_module | Catalog Owner Module | - |
| catalog_entity_aliases | Catalog Entity Aliases | - |

### Fields

| field_name | format | title | description | type | is_pk | default_value | field_order | input_type | width | ctype | searchable | enum_values | precision | reference_table | reference_delete_mode | relationship_label | singular_label_parent | plural_label_parent | unique_value | cube_type | input_type_rule | catalog_field_code |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `id` 🔑 (id) | int64 | Id | - | integer | true | - | 1 | readonly | default | id | false | - | 2 | - | - | has | - | - | false | auto | - | - |
| `record_id` (core) | uuid | Record UUID | Deterministic UUID computed from table OID and primary key values | string | false | - | 10 | readonly | default | core | false | - | 2 | - | - | has | - | - | false | auto | - | - |
| `old_record_id` (core) | uuid | Old Record UUID | Record id before update/delete | string | false | - | 20 | readonly | default | core | false | - | 2 | - | - | has | - | - | false | auto | - | - |
| `record_pk` (core) | text | Record Primary Key | - | string | false | - | 25 | readonly | default | core | true | - | 2 | - | - | has | - | - | false | auto | - | - |
| `op` (core) | text | Operation | DML operation type: INSERT, UPDATE, DELETE, TRUNCATE | string | false | - | 30 | readonly | default | core | false | - | 2 | - | - | has | - | - | false | auto | - | - |
| `ts` (core) | date-time | Timestamp | - | string | false | - | 40 | readonly | default | core | false | - | 2 | - | - | has | - | - | false | auto | - | - |
| `user_id` (core) | int32 | User | From the JWT context; 0 when unavailable | integer | false | - | 50 | readonly | default | core | false | - | 2 | - | - | has | - | - | false | auto | - | - |
| `db_role` (core) | text | DB Role | session_user: the role that authenticated the connection. Unchanged by SET ROLE and by SECURITY DEFINER, so it names the connection rather than the execution context. The API writes as the authenticator role; any other value is an out-of-band write. | string | false | - | 52 | readonly | default | core | false | - | 2 | - | - | has | - | - | false | auto | - | - |
| `is_superuser` (core) | boolean | Is Superuser | Whether the writing session had superuser privileges. On a data row that means RLS was bypassed. Reports the session, not the owner of a SECURITY DEFINER function. | boolean | false | - | 54 | readonly | default | core | false | - | 2 | - | - | has | - | - | false | auto | - | - |
| `client_addr` (core) | text | Client Addr | Connecting client address (inet_client_addr()); NULL for a unix-socket connection, which means a shell on the database host rather than a client on the network | string | false | - | 56 | readonly | default | core | false | - | 2 | - | - | has | - | - | false | auto | - | - |
| `table_oid` (core) | int32 | Table OID | PostgreSQL internal object identifier for the table | integer | false | - | 60 | readonly | default | core | false | - | 2 | - | - | has | - | - | false | auto | - | - |
| `table_schema` (core) | text | Table Schema | - | string | false | - | 70 | readonly | default | core | true | - | 2 | - | - | has | - | - | false | auto | - | - |
| `table_name` (label) | text | Table Name | - | string | false | - | 80 | readonly | default | label | true | - | 2 | - | - | has | - | - | false | auto | - | - |
| `record` (core) | json | Record | Full record after INSERT/UPDATE (JSONB) | json | false | - | 90 | readonly | w | core | false | - | 2 | - | - | has | - | - | false | auto | - | - |
| `old_record` (core) | json | Old Record | Previous record before UPDATE/DELETE (JSONB) | json | false | - | 100 | readonly | w | core | false | - | 2 | - | - | has | - | - | false | auto | - | - |

---

## Entity: dashboards

User-configured dashboard layouts and configurations

| field_name | label | value |
|------------|-------|-------|
| table_name | Table Name | `dashboards` |
| singular | Singular | dashboard |
| plural | Plural | dashboards |
| singular_label | Singular Label | Dashboard |
| plural_label | Plural Label | Dashboards |
| icon_url | Icon URL | - |
| description | Description | User-configured dashboard layouts and configurations |
| module_id | Module | 1 |
| view_permission | View Permission | `admin` |
| edit_permission | Edit Permission | `admin` |
| id_column | Id Column | `id` |
| label_column | Label Column | `label` |
| label_parent | Label Parent | - |
| order_column | Order Column | - |
| managed | Managed | true |
| searchable | Searchable | true |
| is_child | Is Child | false |
| edit_mode | Edit Mode | auto |
| cube_mode | Cube Mode | auto |
| entity_type | Entity Type | unclassified |
| audit_log | Audit Log | false |
| computed_fields | Computed Fields | - |
| validation_rules | Validation Rules | - |
| select_rule | Select Rule | - |
| catalog_entity_code | Catalog Entity Code | - |
| catalog_owner_module | Catalog Owner Module | - |
| catalog_entity_aliases | Catalog Entity Aliases | - |

### Fields

| field_name | format | title | description | type | is_pk | default_value | field_order | input_type | width | ctype | searchable | enum_values | precision | reference_table | reference_delete_mode | relationship_label | singular_label_parent | plural_label_parent | unique_value | cube_type | input_type_rule | catalog_field_code |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `id` 🔑 (id) | int32 | Id | - | integer | true | - | 10 | readonly | default | id | false | - | 2 | - | - | has | - | - | false | auto | - | - |
| `config` | json | Configuration | - | json | false | - | 10 | default | w | - | false | - | 2 | - | - | has | - | - | false | auto | - | - |
| `position` | int32 | Position | - | integer | false | 0 | 20 | default | default | - | false | - | 2 | - | - | has | - | - | false | auto | - | - |
| `label` (label) | text | Name | - | string | false | - | 20 | required | default | label | true | - | 2 | - | - | has | - | - | false | auto | - | - |
| `module_id` | reference | Module | - | integer | false | - | 30 | default | default | - | false | - | 2 | modules | cascade | has | - | - | false | auto | - | - |
| `view_permission` | reference | View Permission | Permission required to view this dashboard | string | false | - | 40 | default | default | - | false | - | 2 | permissions | clear | has | - | - | false | auto | - | - |

---

## Entity: entities

Catalog of tables in Semantius

| field_name | label | value |
|------------|-------|-------|
| table_name | Table Name | `entities` |
| singular | Singular | entity |
| plural | Plural | entities |
| singular_label | Singular Label | Entity |
| plural_label | Plural Label | Entities |
| icon_url | Icon URL | - |
| description | Description | Catalog of tables in Semantius |
| module_id | Module | 1 |
| view_permission | View Permission | `public:read` |
| edit_permission | Edit Permission | `admin` |
| id_column | Id Column | `table_name` |
| label_column | Label Column | `singular_label` |
| label_parent | Label Parent | - |
| order_column | Order Column | - |
| managed | Managed | true |
| searchable | Searchable | true |
| is_child | Is Child | false |
| edit_mode | Edit Mode | auto |
| cube_mode | Cube Mode | auto |
| entity_type | Entity Type | unclassified |
| audit_log | Audit Log | true |
| computed_fields | Computed Fields | - |
| validation_rules | Validation Rules | [{"code":"90201","message":"catalog_entity_code is write-once: it cannot be changed once set","jsonlogic":{"if":[{"value_changed":"catalog_entity_code"},{"or":[{"==":[{"var":"$old"},null]},{"==":[{"var":"$old.catalog_entity_code"},""]}]},true]},"source_module":"platform"}] |
| select_rule | Select Rule | - |
| catalog_entity_code | Catalog Entity Code | - |
| catalog_owner_module | Catalog Owner Module | - |
| catalog_entity_aliases | Catalog Entity Aliases | - |

### Fields

| field_name | format | title | description | type | is_pk | default_value | field_order | input_type | width | ctype | searchable | enum_values | precision | reference_table | reference_delete_mode | relationship_label | singular_label_parent | plural_label_parent | unique_value | cube_type | input_type_rule | catalog_field_code |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `table_name` 🔑 (id) | text | Table Name | Physical table name in database | string | true | - | 1 | required | default | id | true | - | 2 | - | - | - | - | - | false | auto | - | - |
| `singular` (core) | text | Singular | Singular form of table name (auto-derived from table_name when blank) | string | false | - | 10 | default | default | core | true | - | 2 | - | - | - | - | - | false | auto | - | - |
| `plural` (core) | text | Plural | Plural form of table name, auto-assigned to table_name | string | false | - | 20 | readonly | default | core | true | - | 2 | - | - | - | - | - | false | auto | - | - |
| `singular_label` (label) | text | Singular Label | Human-readable singular label for UI/reports (e.g. Customer) | string | false | - | 30 | default | default | label | true | - | 2 | - | - | - | - | - | false | auto | - | - |
| `plural_label` (core) | text | Plural Label | Human-readable plural label for UI/reports (e.g. Customers) | string | false | - | 40 | default | default | core | true | - | 2 | - | - | - | - | - | false | auto | - | - |
| `icon_url` (core) | url | Icon URL | - | string | false | - | 50 | default | w | core | false | - | 2 | - | - | - | - | - | false | auto | - | - |
| `description` (core) | text | Description | - | string | false | - | 60 | default | w | core | true | - | 2 | - | - | - | - | - | false | auto | - | - |
| `module_id` (core) | reference | Module | - | integer | false | - | 70 | required | default | core | false | - | 2 | modules | cascade | contains | - | - | false | auto | - | - |
| `view_permission` (core) | reference | View Permission | Permission required to SELECT from this table | string | false | public:read | 80 | default | default | core | false | - | 2 | permissions | restrict | gates viewing | - | - | false | auto | - | - |
| `edit_permission` (core) | reference | Edit Permission | Permission required to INSERT/UPDATE/DELETE from this table | string | false | admin | 90 | default | default | core | false | - | 2 | permissions | restrict | gates editing | - | - | false | auto | - | - |
| `id_column` (core) | text | Id Column | Name of primary key column | string | false | id | 100 | default | default | core | false | - | 2 | - | - | - | - | - | false | auto | - | - |
| `label_column` (core) | text | Label Column | Name of label/display column | string | false | label | 110 | default | default | core | false | - | 2 | - | - | - | - | - | false | auto | - | - |
| `label_parent` (core) | text | Label Parent | Names the reference/parent FK that is this entity's identity spine for the composed _label. Empty = intrinsic/self-identifying (composed label = local label). | string | false | - | 111 | default | default | core | false | - | 2 | - | - | - | - | - | false | auto | - | - |
| `order_column` (core) | text | Order Column | Store a fixed row order in this column | string | false | - | 112 | default | default | core | false | - | 2 | - | - | - | - | - | false | auto | - | - |
| `managed` (core) | boolean | Managed | When disabled, changes to this entity and its fields no longer run DDL | boolean | false | true | 115 | default | default | core | false | - | 2 | - | - | - | - | - | false | auto | - | - |
| `searchable` (core) | boolean | Searchable | Auto-computed from the label field | boolean | false | - | 117 | disabled | default | core | false | - | 2 | - | - | - | - | - | false | auto | - | - |
| `is_child` (core) | boolean | Is Child | Auto-computed from the parent fields | boolean | false | - | 118 | disabled | default | core | false | - | 2 | - | - | - | - | - | false | auto | - | - |
| `edit_mode` (core) | enum | Edit Mode | - | string | false | auto | 119 | default | default | core | false | ["auto","sidebar","modal","page"] | 2 | - | - | - | - | - | false | auto | - | - |
| `cube_mode` (core) | enum | Cube Mode | - | string | false | auto | 121 | default | default | core | false | ["disabled","auto"] | 2 | - | - | - | - | - | false | auto | - | - |
| `audit_log` (core) | boolean | Audit Log | When enabled, DML operations on this table are logged to audit_record_logs | boolean | false | false | 122 | default | default | core | false | - | 2 | - | - | has | - | - | false | auto | - | - |
| `entity_type` (core) | enum | Entity Type | What kind of data this entity holds. operational_workflow: records move through a gated lifecycle (even one gated step such as draft to submitted counts). operational_record: everyday business records without such a lifecycle. catalog: reference or lookup data maintained by admins. junction: a pure link between entities with no fields of its own; the platform labels its rows by the records they link. computed: every field is derived and never written directly. unclassified: not classified yet (the default). | string | false | unclassified | 122 | required | default | core | false | ["operational_workflow","operational_record","catalog","junction","computed","unclassified"] | 2 | - | - | - | - | - | false | auto | - | - |
| `computed_fields` (core) | jsonlogic | Computed Fields | JsonLogic derivations evaluated on every write | json | false | [] | 123 | default | w | core | false | - | 2 | - | - | - | - | - | false | auto | - | - |
| `validation_rules` (core) | jsonlogic | Validation Rules | JsonLogic invariants that must hold for the write to succeed | json | false | [] | 124 | default | w | core | false | - | 2 | - | - | - | - | - | false | auto | - | - |
| `select_rule` (core) | jsonlogic | Select Rule | JsonLogic rule for per-row FOR SELECT RLS policy | json | false | - | 125 | default | w | core | false | - | 2 | - | - | - | - | - | false | auto | - | - |
| `catalog_entity_code` (core) | text | Catalog Entity Code | Stable canonical identity this entity realizes (uber-model code, e.g. vendors); the rename/dialect/silo join key. table_name holds the deployed name. Write-once: set on create or filled once while empty, then never changed. Empty = not generated from a catalog spec. | string | false | - | 126 | default | default | core | false | - | 2 | - | - | - | - | - | false | auto | - | - |
| `catalog_owner_module` (core) | text | Catalog Owner Module | For an embedded-master placeholder, the slug of the module that should own this entity. Soft pointer (not an FK); empty when this module is the owner or the entity is local. | string | false | - | 127 | default | default | core | false | - | 2 | - | - | - | - | - | false | auto | - | - |
| `catalog_entity_aliases` (core) | json | Catalog Entity Aliases | Reuse/merge record: JSON array of {alias_code, source_domain, source_module, decided}. Append-only. Empty array = never a merge target. | json | false | [] | 129 | default | w | core | false | - | 2 | - | - | - | - | - | false | auto | - | - |

---

## Entity: fields

Catalog of the fields that make up a table

| field_name | label | value |
|------------|-------|-------|
| table_name | Table Name | `fields` |
| singular | Singular | field |
| plural | Plural | fields |
| singular_label | Singular Label | Field |
| plural_label | Plural Label | Fields |
| icon_url | Icon URL | - |
| description | Description | Catalog of the fields that make up a table |
| module_id | Module | 1 |
| view_permission | View Permission | `public:read` |
| edit_permission | Edit Permission | `admin` |
| id_column | Id Column | `id` |
| label_column | Label Column | `title` |
| label_parent | Label Parent | - |
| order_column | Order Column | field_order |
| managed | Managed | true |
| searchable | Searchable | true |
| is_child | Is Child | true |
| edit_mode | Edit Mode | auto |
| cube_mode | Cube Mode | auto |
| entity_type | Entity Type | unclassified |
| audit_log | Audit Log | true |
| computed_fields | Computed Fields | - |
| validation_rules | Validation Rules | [{"code":"90202","message":"catalog_field_code is write-once: it cannot be changed once set","jsonlogic":{"if":[{"value_changed":"catalog_field_code"},{"or":[{"==":[{"var":"$old"},null]},{"==":[{"var":"$old.catalog_field_code"},""]}]},true]},"source_module":"platform"}] |
| select_rule | Select Rule | - |
| catalog_entity_code | Catalog Entity Code | - |
| catalog_owner_module | Catalog Owner Module | - |
| catalog_entity_aliases | Catalog Entity Aliases | - |

### Fields

| field_name | format | title | description | type | is_pk | default_value | field_order | input_type | width | ctype | searchable | enum_values | precision | reference_table | reference_delete_mode | relationship_label | singular_label_parent | plural_label_parent | unique_value | cube_type | input_type_rule | catalog_field_code |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `id` 🔑 (id) | text | Id | Generated identifier (table_name.field_name) | string | true | - | 10 | readonly | default | id | false | - | 2 | - | - | - | - | - | false | auto | - | - |
| `table_name` (core) | parent | Entity | - | string | false | - | 20 | default | default | core | true | - | 2 | entities | cascade | has fields | - | - | false | auto | - | - |
| `field_name` (core) | text | Field Name | Physical column name in database | string | false | - | 30 | required | default | core | true | - | 2 | - | - | - | - | - | false | auto | - | - |
| `format` (core) | enum | Format | - | string | false | text | 40 | required | default | core | false | ["json","html","text","multiline","code","jsonata","jsonlogic","reference","parent","enum","date","time","date-time","duration","uri","uri-reference","iri","iri-reference","uri-template","url","email","idn-email","hostname","idn-hostname","ipv4","ipv6","regex","uuid","json-pointer","json-pointer-uri-fragment","relative-json-pointer","byte","binary","password","int32","int64","float","double","string","number","integer","boolean","object","array"] | 2 | - | - | - | - | - | false | auto | - | - |
| `title` (label) | text | Title | - | string | false | - | 50 | required | default | label | true | - | 2 | - | - | - | - | - | false | auto | - | - |
| `description` (core) | text | Description | - | string | false | - | 60 | default | w | core | true | - | 2 | - | - | - | - | - | false | auto | - | - |
| `is_pk` (core) | boolean | Is Primary Key | Cannot change after the field is created | boolean | false | - | 70 | default | default | core | false | - | 2 | - | - | - | - | - | false | auto | - | - |
| `default_value` (core) | text | Default Value | Column default: a literal value or an SQL expression such as CURRENT_TIMESTAMP | string | false | - | 90 | hidden | default | core | false | - | 2 | - | - | - | - | - | false | auto | {"if":[{"!=":[{"var":"format"},"boolean"]},"default","hidden"]} | - |
| `field_order` (core) | int32 | Field Order | - | integer | false | - | 100 | default | default | core | false | - | 2 | - | - | - | - | - | false | auto | - | - |
| `input_type` (core) | enum | Input Type | How the UI presents the field for input; input_type_rule can override it per record | string | false | default | 110 | required | default | core | false | ["default","required","readonly","disabled","hidden"] | 2 | - | - | - | - | - | false | auto | - | - |
| `width` (core) | enum | Width | default (automatic), s (small), m (medium), w (wide) | string | false | default | 120 | required | default | core | false | ["default","s","m","w"] | 2 | - | - | - | - | - | false | auto | - | - |
| `ctype` (core) | enum | Column Type | Special column type (id, label, etc.) | string | false | - | 130 | default | default | core | false | ["","id","label","audit","core"] | 2 | - | - | - | - | - | false | auto | - | - |
| `searchable` (core) | boolean | Searchable | - | boolean | false | - | 150 | hidden | default | core | false | - | 2 | - | - | - | - | - | false | auto | {"if":[{"in":[{"var":"format"},["string","text","multiline","html","code"]]},"default","hidden"]} | - |
| `enum_values` (core) | json | Enum Values | JSON array of the allowed values of an enum field, e.g. ["active", "inactive", "pending"] | json | false | - | 160 | hidden | w | core | false | - | 2 | - | - | - | - | - | false | auto | {"if":[{"==":[{"var":"format"},"enum"]},"required","hidden"]} | - |
| `precision` (core) | int32 | Precision | Decimal scale (digits after the decimal point) used when generating NUMERIC columns for number formats | integer | false | 2 | 170 | hidden | default | core | false | - | 2 | - | - | - | - | - | false | auto | {"if":[{"==":[{"var":"format"},"number"]},"required","hidden"]} | - |
| `reference_table` (core) | text | Reference Table | Entity this field references, by table name. Required for reference and parent fields, empty for all others, and must name an existing entity. | string | false | - | 180 | hidden | default | core | false | - | 2 | - | - | - | - | - | false | auto | {"if":[{"in":[{"var":"format"},["reference","parent"]]},"required","hidden"]} | - |
| `reference_delete_mode` (core) | enum | Reference Delete Mode | What happens to this record when the referenced record is deleted: restrict (the delete is blocked), clear (this field is set to NULL) or cascade (this record is deleted too). Empty on fields that are not a reference or parent; on a reference, empty acts as restrict. | string | false | restrict | 190 | hidden | default | core | false | ["","restrict","clear","cascade"] | 2 | - | - | - | - | - | false | auto | {"if":[{"in":[{"var":"format"},["reference","parent"]]},"required","hidden"]} | - |
| `relationship_label` (core) | text | Relationship Label | Verb describing what the referenced entity does to/with this entity (e.g. employs, heads). Used for ER diagram and navigation labels. | string | false | has | 200 | hidden | default | core | false | - | 2 | - | - | - | - | - | false | auto | {"if":[{"in":[{"var":"format"},["reference","parent"]]},"required","hidden"]} | - |
| `singular_label_parent` (core) | text | Singular Label Parent | Custom singular label for the parent entity when format is parent; overrides the singular_label of the parent entity when set | string | false | - | 210 | hidden | default | core | false | - | 2 | - | - | - | - | - | false | auto | {"if":[{"==":[{"var":"format"},"parent"]},"default","hidden"]} | - |
| `plural_label_parent` (core) | text | Plural Label Parent | Custom plural label for the parent entity when format is parent; overrides the plural_label of the parent entity when set | string | false | - | 220 | hidden | default | core | false | - | 2 | - | - | - | - | - | false | auto | {"if":[{"==":[{"var":"format"},"parent"]},"default","hidden"]} | - |
| `unique_value` (core) | boolean | Unique Value | When enabled, values in this column must be unique. NULL and empty strings are not checked. | boolean | false | - | 230 | hidden | default | core | false | - | 2 | - | - | - | - | - | false | auto | {"if":[{"in":[{"var":"format"},["boolean","multiline","html","code","json","jsonlogic","object","array"]]},"hidden","default"]} | - |
| `cube_type` (core) | enum | Cube Type | Role of the field in the generated OLAP cube (dimension or measure); auto lets the platform choose, disabled leaves the field out | string | false | auto | 240 | required | default | core | false | ["auto","dimension","measure","disabled"] | 2 | - | - | - | - | - | false | auto | - | - |
| `input_type_rule` (core) | jsonlogic | Input Type Rule | JsonLogic rule evaluated client-side against the record being edited. It returns an input_type (default, required, readonly, disabled or hidden) that replaces the static input_type. Empty = no rule. | json | false | - | 250 | default | w | core | false | - | 2 | - | - | - | - | - | false | auto | - | - |
| `catalog_field_code` (core) | text | Catalog Field Code | Stable design-time field identity (blueprint field name, e.g. status); the field-rename join key. Write-once: set on create or filled once while empty, then never changed. Empty = not generated from a catalog spec. | string | false | - | 260 | default | default | core | false | - | 2 | - | - | - | - | - | false | auto | - | - |

---

## Entity: modules

Groups of related tables and permissions

| field_name | label | value |
|------------|-------|-------|
| table_name | Table Name | `modules` |
| singular | Singular | module |
| plural | Plural | modules |
| singular_label | Singular Label | Module |
| plural_label | Plural Label | Modules |
| icon_url | Icon URL | - |
| description | Description | Groups of related tables and permissions |
| module_id | Module | 1 |
| view_permission | View Permission | `admin` |
| edit_permission | Edit Permission | `admin` |
| id_column | Id Column | `id` |
| label_column | Label Column | `module_name` |
| label_parent | Label Parent | - |
| order_column | Order Column | - |
| managed | Managed | true |
| searchable | Searchable | true |
| is_child | Is Child | false |
| edit_mode | Edit Mode | auto |
| cube_mode | Cube Mode | auto |
| entity_type | Entity Type | unclassified |
| audit_log | Audit Log | true |
| computed_fields | Computed Fields | - |
| validation_rules | Validation Rules | [{"code":"90701","message":"catalog_module_code is write-once: it cannot be changed once set","jsonlogic":{"if":[{"value_changed":"catalog_module_code"},{"or":[{"==":[{"var":"$old"},null]},{"==":[{"var":"$old.catalog_module_code"},""]}]},true]},"source_module":"platform"},{"code":"90702","message":"module_slug must be lowercase, start with a letter or digit, and contain only a-z, 0-9, '-' and '_'","jsonlogic":{"or":[{"==":[{"var":"module_slug"},""]},{"is_match":[{"var":"module_slug"},"^[a-z0-9][a-z0-9_-]*$"]}]},"source_module":"platform"}] |
| select_rule | Select Rule | - |
| catalog_entity_code | Catalog Entity Code | - |
| catalog_owner_module | Catalog Owner Module | - |
| catalog_entity_aliases | Catalog Entity Aliases | - |

### Fields

| field_name | format | title | description | type | is_pk | default_value | field_order | input_type | width | ctype | searchable | enum_values | precision | reference_table | reference_delete_mode | relationship_label | singular_label_parent | plural_label_parent | unique_value | cube_type | input_type_rule | catalog_field_code |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `id` 🔑 (id) | int32 | Id | - | integer | true | - | 1 | readonly | default | id | false | - | 2 | - | - | has | - | - | false | auto | - | - |
| `module_name` (label) | text | Module Name | - | string | false | - | 10 | required | default | label | true | - | 2 | - | - | has | - | - | false | auto | - | - |
| `description` (core) | text | Description | - | string | false | - | 20 | default | w | core | true | - | 2 | - | - | has | - | - | false | auto | - | - |
| `module_type` (core) | enum | Module Type | domain = normal module; master = promoted for sharing | string | false | domain | 25 | readonly | default | core | false | ["domain","master"] | 2 | - | - | has | - | - | false | auto | - | - |
| `view_permission` (core) | reference | View Permission | Permission required to view this module | string | false | user:read | 30 | default | default | core | false | - | 2 | permissions | restrict | has | - | - | false | auto | - | - |
| `logo_color` (core) | text | Logo Color | Hex color code | string | false | - | 36 | default | default | core | false | - | 2 | - | - | has | - | - | false | auto | - | - |
| `icon_name` (core) | text | Icon Name | - | string | false | - | 37 | default | default | core | false | - | 2 | - | - | has | - | - | false | auto | - | - |
| `home_page` (core) | text | Home Page | - | string | false | / | 38 | default | default | core | false | - | 2 | - | - | has | - | - | false | auto | - | - |
| `module_slug` (core) | text | Module Slug | URL-safe unique identifier for the module: lowercase, starting with a letter or digit, using only a-z, 0-9, - and _. Derived from the module name when left empty. | string | false | - | 38 | default | default | core | false | - | 2 | - | - | has | - | - | false | auto | - | - |
| `manage_permission` (core) | reference | Manage Permission | - | string | false | - | 39 | default | default | core | false | - | 2 | permissions | clear | has | - | - | false | auto | - | - |
| `admin_permission` (core) | reference | Admin Permission | - | string | false | - | 40 | default | default | core | false | - | 2 | permissions | clear | has | - | - | false | auto | - | - |
| `default_viewer_role_id` (core) | reference | Default Viewer Role | - | integer | false | - | 41 | default | default | core | false | - | 2 | roles | clear | has | - | - | false | auto | - | - |
| `default_manager_role_id` (core) | reference | Default Manager Role | - | integer | false | - | 42 | default | default | core | false | - | 2 | roles | clear | has | - | - | false | auto | - | - |
| `default_admin_role_id` (core) | reference | Default Admin Role | - | integer | false | - | 43 | default | default | core | false | - | 2 | roles | clear | has | - | - | false | auto | - | - |
| `catalog_module_code` (core) | text | Catalog Module Code | Catalog blueprint this module was provisioned/cloned from; also the domain axis (non-unique). Empty = greenfield. | string | false | - | 44 | default | default | core | false | - | 2 | - | - | has | - | - | false | auto | - | - |
| `domain_code` (core) | text | Domain Code | Short uppercase code for the business domain this module belongs to (e.g. ATS, HCM, ITSM, CRM) | string | false | - | 45 | default | default | core | false | - | 2 | - | - | has | - | - | false | auto | - | - |
| `access_scope` (core) | enum | Access Scope | Access tier: basic (simple read/edit) or full (role tiers, approvals and gating) | string | false | basic | 46 | required | default | core | false | ["basic","full"] | 2 | - | - | has | - | - | false | auto | - | - |
| `settings` (core) | json | Settings | - | json | false | - | 50 | default | w | core | false | - | 2 | - | - | has | - | - | false | auto | - | - |
| `dashboard_config` (core) | json | Dashboard Configuration | Layout and widgets of the module dashboard | json | false | - | 60 | default | w | core | false | - | 2 | - | - | has | - | - | false | auto | - | - |
| `version` (core) | int32 | Version | Auto-incremented version number | integer | false | - | 85 | readonly | default | core | false | - | 2 | - | - | has | - | - | false | auto | - | - |
| `version_date` (core) | date-time | Version Date | - | string | false | - | 86 | readonly | default | core | false | - | 2 | - | - | has | - | - | false | auto | - | - |

---

## Entity: permission_hierarchy

Defines permission inclusion (including permission implies included permissions)

| field_name | label | value |
|------------|-------|-------|
| table_name | Table Name | `permission_hierarchy` |
| singular | Singular | permission_hierarchy |
| plural | Plural | permission_hierarchy |
| singular_label | Singular Label | Permission Hierarchy |
| plural_label | Plural Label | Permission Hierarchy |
| icon_url | Icon URL | - |
| description | Description | Defines permission inclusion (including permission implies included permissions) |
| module_id | Module | 1 |
| view_permission | View Permission | `admin` |
| edit_permission | Edit Permission | `admin` |
| id_column | Id Column | `id` |
| label_column | Label Column | `id` |
| label_parent | Label Parent | - |
| order_column | Order Column | - |
| managed | Managed | true |
| searchable | Searchable | false |
| is_child | Is Child | true |
| edit_mode | Edit Mode | auto |
| cube_mode | Cube Mode | auto |
| entity_type | Entity Type | junction |
| audit_log | Audit Log | true |
| computed_fields | Computed Fields | - |
| validation_rules | Validation Rules | [{"code":"90205","message":"permission_hierarchy.origin is set on INSERT and cannot be changed","jsonlogic":{"if":[{"value_changed":"origin"},{"==":[{"var":"$old"},null]},true]},"source_module":"platform"}] |
| select_rule | Select Rule | - |
| catalog_entity_code | Catalog Entity Code | - |
| catalog_owner_module | Catalog Owner Module | - |
| catalog_entity_aliases | Catalog Entity Aliases | - |

### Fields

| field_name | format | title | description | type | is_pk | default_value | field_order | input_type | width | ctype | searchable | enum_values | precision | reference_table | reference_delete_mode | relationship_label | singular_label_parent | plural_label_parent | unique_value | cube_type | input_type_rule | catalog_field_code |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `id` 🔑 (id) | text | Id | Generated identifier (including_permission_name.included_permission_name) | string | true | - | 1 | readonly | default | id | false | - | 2 | - | - | - | - | - | false | auto | - | - |
| `including_permission_name` (core) | parent | Including Permission | The broader permission: holding it implies the included permission (e.g. crm:manage includes crm:read). | string | false | - | 10 | default | default | core | false | - | 2 | permissions | cascade | includes | Includes | Includes | false | auto | - | - |
| `included_permission_name` (core) | parent | Included Permission | The narrower permission that is included by the broader one | string | false | - | 20 | default | default | core | false | - | 2 | permissions | cascade | included in | Included in | Included in | false | auto | - | - |
| `origin` (core) | enum | Origin | How this hierarchy entry was created | string | false | user | 25 | readonly | default | core | false | ["system","model","model_master","user"] | 2 | - | - | - | - | - | false | auto | - | - |

---

## Entity: permissions

System permissions that can be assigned to roles and organized via hierarchy

| field_name | label | value |
|------------|-------|-------|
| table_name | Table Name | `permissions` |
| singular | Singular | permission |
| plural | Plural | permissions |
| singular_label | Singular Label | Permission |
| plural_label | Plural Label | Permissions |
| icon_url | Icon URL | - |
| description | Description | System permissions that can be assigned to roles and organized via hierarchy |
| module_id | Module | 1 |
| view_permission | View Permission | `admin` |
| edit_permission | Edit Permission | `admin` |
| id_column | Id Column | `permission_name` |
| label_column | Label Column | `permission_name` |
| label_parent | Label Parent | - |
| order_column | Order Column | - |
| managed | Managed | true |
| searchable | Searchable | true |
| is_child | Is Child | false |
| edit_mode | Edit Mode | auto |
| cube_mode | Cube Mode | auto |
| entity_type | Entity Type | unclassified |
| audit_log | Audit Log | true |
| computed_fields | Computed Fields | - |
| validation_rules | Validation Rules | - |
| select_rule | Select Rule | - |
| catalog_entity_code | Catalog Entity Code | - |
| catalog_owner_module | Catalog Owner Module | - |
| catalog_entity_aliases | Catalog Entity Aliases | - |

### Fields

| field_name | format | title | description | type | is_pk | default_value | field_order | input_type | width | ctype | searchable | enum_values | precision | reference_table | reference_delete_mode | relationship_label | singular_label_parent | plural_label_parent | unique_value | cube_type | input_type_rule | catalog_field_code |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `permission_name` 🔑 (id) | text | Permission Name | The permission itself, and the key other tables use to name it. Colon-separated segments of a-z, 0-9, - and _, each starting with a letter or digit, e.g. crm:read or service-catalog:view. No spaces, commas or dots: scope strings are split on commas and whitespace, and a dot would make permission_hierarchy ids ambiguous. | string | true | - | 1 | required | default | id | true | - | 2 | - | - | - | - | - | false | auto | - | - |
| `description` (core) | multiline | Description | - | string | false | - | 20 | default | w | core | true | - | 2 | - | - | - | - | - | false | auto | - | - |
| `module_id` (core) | reference | Module | - | integer | false | - | 30 | required | default | core | false | - | 2 | modules | cascade | contains | - | - | false | auto | - | - |

---

## Entity: processes

RACI process catalog

| field_name | label | value |
|------------|-------|-------|
| table_name | Table Name | `processes` |
| singular | Singular | process |
| plural | Plural | processes |
| singular_label | Singular Label | Process |
| plural_label | Plural Label | Processes |
| icon_url | Icon URL | - |
| description | Description | RACI process catalog |
| module_id | Module | 1 |
| view_permission | View Permission | `admin` |
| edit_permission | Edit Permission | `admin` |
| id_column | Id Column | `id` |
| label_column | Label Column | `name` |
| label_parent | Label Parent | - |
| order_column | Order Column | - |
| managed | Managed | true |
| searchable | Searchable | true |
| is_child | Is Child | false |
| edit_mode | Edit Mode | auto |
| cube_mode | Cube Mode | auto |
| entity_type | Entity Type | unclassified |
| audit_log | Audit Log | false |
| computed_fields | Computed Fields | - |
| validation_rules | Validation Rules | - |
| select_rule | Select Rule | - |
| catalog_entity_code | Catalog Entity Code | - |
| catalog_owner_module | Catalog Owner Module | - |
| catalog_entity_aliases | Catalog Entity Aliases | - |

### Fields

| field_name | format | title | description | type | is_pk | default_value | field_order | input_type | width | ctype | searchable | enum_values | precision | reference_table | reference_delete_mode | relationship_label | singular_label_parent | plural_label_parent | unique_value | cube_type | input_type_rule | catalog_field_code |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `id` 🔑 (id) | int32 | Id | - | integer | true | - | 10 | readonly | default | id | false | - | 2 | - | - | has | - | - | false | auto | - | - |
| `name` (label) | text | Name | - | string | false | - | 10 | required | default | label | true | - | 2 | - | - | has | - | - | false | auto | - | - |
| `module_id` | reference | Module | Owning module | integer | false | - | 20 | default | default | - | false | - | 2 | modules | clear | has | - | - | false | auto | - | - |
| `process_key` | text | Process Key | Stable snake_case identifier, unique within module | string | false | - | 30 | required | default | - | false | - | 2 | - | - | has | - | - | false | auto | - | - |
| `description` | multiline | Description | - | string | false | - | 40 | default | default | - | false | - | 2 | - | - | has | - | - | false | auto | - | - |
| `ordering` | integer | Ordering | - | integer | false | - | 50 | default | default | - | false | - | 2 | - | - | has | - | - | false | auto | - | - |

---

## Entity: process_gates

Governance registry: maps entity transitions to processes

| field_name | label | value |
|------------|-------|-------|
| table_name | Table Name | `process_gates` |
| singular | Singular | process_gate |
| plural | Plural | process_gates |
| singular_label | Singular Label | Process Gate |
| plural_label | Plural Label | Process Gates |
| icon_url | Icon URL | - |
| description | Description | Governance registry: maps entity transitions to processes |
| module_id | Module | 1 |
| view_permission | View Permission | `admin` |
| edit_permission | Edit Permission | `admin` |
| id_column | Id Column | `id` |
| label_column | Label Column | `name` |
| label_parent | Label Parent | - |
| order_column | Order Column | - |
| managed | Managed | true |
| searchable | Searchable | true |
| is_child | Is Child | true |
| edit_mode | Edit Mode | auto |
| cube_mode | Cube Mode | auto |
| entity_type | Entity Type | unclassified |
| audit_log | Audit Log | false |
| computed_fields | Computed Fields | [{"name":"name","jsonlogic":{"var":"gate_kind"}}] |
| validation_rules | Validation Rules | - |
| select_rule | Select Rule | - |
| catalog_entity_code | Catalog Entity Code | - |
| catalog_owner_module | Catalog Owner Module | - |
| catalog_entity_aliases | Catalog Entity Aliases | - |

### Fields

| field_name | format | title | description | type | is_pk | default_value | field_order | input_type | width | ctype | searchable | enum_values | precision | reference_table | reference_delete_mode | relationship_label | singular_label_parent | plural_label_parent | unique_value | cube_type | input_type_rule | catalog_field_code |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `name` (label) | text | Name | Display label — mirrors the gate kind (computed) | string | false | - | 5 | readonly | default | label | true | - | 2 | - | - | has | - | - | false | auto | - | - |
| `id` 🔑 (id) | int32 | Id | - | integer | true | - | 10 | readonly | default | id | false | - | 2 | - | - | has | - | - | false | auto | - | - |
| `process_id` | parent | Process | - | integer | false | - | 10 | required | default | - | false | - | 2 | processes | cascade | has | - | - | false | auto | - | - |
| `entity` | text | Entity | - | string | false | - | 20 | required | default | - | false | - | 2 | - | - | has | - | - | false | auto | - | - |
| `gate_kind` | enum | Gate Kind | - | string | false | - | 30 | required | default | - | false | ["approval","submit_lock","ownership","create","transition"] | 2 | - | - | has | - | - | false | auto | - | - |
| `to_state` | text | To State | Target lifecycle state (empty for non-state-targeted gates) | string | false | - | 40 | default | default | - | false | - | 2 | - | - | has | - | - | false | auto | - | - |
| `state_column` | text | State Column | Column that holds the lifecycle state in the governed table | string | false | status | 50 | default | default | - | false | - | 2 | - | - | has | - | - | false | auto | - | - |
| `emits_events` | boolean | Emits Events | When enabled, entering to_state inserts raci_events for the consulted and informed actors | boolean | false | - | 60 | default | default | - | false | - | 2 | - | - | has | - | - | false | auto | - | - |

---

## Entity: queues

Message queues backed by pgmq

| field_name | label | value |
|------------|-------|-------|
| table_name | Table Name | `queues` |
| singular | Singular | queue |
| plural | Plural | queues |
| singular_label | Singular Label | Queue |
| plural_label | Plural Label | Queues |
| icon_url | Icon URL | - |
| description | Description | Message queues backed by pgmq |
| module_id | Module | 1 |
| view_permission | View Permission | `admin` |
| edit_permission | Edit Permission | `admin` |
| id_column | Id Column | `id` |
| label_column | Label Column | `queue_name` |
| label_parent | Label Parent | - |
| order_column | Order Column | - |
| managed | Managed | true |
| searchable | Searchable | true |
| is_child | Is Child | false |
| edit_mode | Edit Mode | auto |
| cube_mode | Cube Mode | auto |
| entity_type | Entity Type | unclassified |
| audit_log | Audit Log | false |
| computed_fields | Computed Fields | - |
| validation_rules | Validation Rules | - |
| select_rule | Select Rule | - |
| catalog_entity_code | Catalog Entity Code | - |
| catalog_owner_module | Catalog Owner Module | - |
| catalog_entity_aliases | Catalog Entity Aliases | - |

### Fields

| field_name | format | title | description | type | is_pk | default_value | field_order | input_type | width | ctype | searchable | enum_values | precision | reference_table | reference_delete_mode | relationship_label | singular_label_parent | plural_label_parent | unique_value | cube_type | input_type_rule | catalog_field_code |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `id` 🔑 (id) | int32 | Id | - | integer | true | - | 10 | readonly | default | id | false | - | 2 | - | - | has | - | - | false | auto | - | - |
| `queue_name` (label) | text | Name | - | string | false | - | 20 | required | default | label | true | - | 2 | - | - | has | - | - | true | auto | - | - |
| `view_permission` | reference | View Permission | Permission required to read messages from this queue (queue_read). Readers see the table, id and operation of every table mapped to this queue. | string | false | admin | 30 | default | default | - | false | - | 2 | permissions | restrict | gates reading | - | - | false | auto | - | - |
| `manage_permission` | reference | Manage Permission | Permission required to pop, archive or delete messages from this queue. | string | false | admin | 40 | default | default | - | false | - | 2 | permissions | restrict | gates managing | - | - | false | auto | - | - |

---

## Entity: queue_table_events

Maps table DML events to queues

| field_name | label | value |
|------------|-------|-------|
| table_name | Table Name | `queue_table_events` |
| singular | Singular | queue_table_event |
| plural | Plural | queue_table_events |
| singular_label | Singular Label | Queue Table Event |
| plural_label | Plural Label | Queue Table Events |
| icon_url | Icon URL | - |
| description | Description | Maps table DML events to queues |
| module_id | Module | 1 |
| view_permission | View Permission | `admin` |
| edit_permission | Edit Permission | `admin` |
| id_column | Id Column | `id` |
| label_column | Label Column | `event_name` |
| label_parent | Label Parent | - |
| order_column | Order Column | - |
| managed | Managed | true |
| searchable | Searchable | true |
| is_child | Is Child | true |
| edit_mode | Edit Mode | auto |
| cube_mode | Cube Mode | auto |
| entity_type | Entity Type | unclassified |
| audit_log | Audit Log | false |
| computed_fields | Computed Fields | - |
| validation_rules | Validation Rules | - |
| select_rule | Select Rule | - |
| catalog_entity_code | Catalog Entity Code | - |
| catalog_owner_module | Catalog Owner Module | - |
| catalog_entity_aliases | Catalog Entity Aliases | - |

### Fields

| field_name | format | title | description | type | is_pk | default_value | field_order | input_type | width | ctype | searchable | enum_values | precision | reference_table | reference_delete_mode | relationship_label | singular_label_parent | plural_label_parent | unique_value | cube_type | input_type_rule | catalog_field_code |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `queue_id` | parent | Queue | - | integer | false | - | 5 | default | default | - | false | - | 2 | queues | cascade | has events | - | - | false | auto | - | - |
| `id` 🔑 (id) | int32 | Id | - | integer | true | - | 10 | readonly | default | id | false | - | 2 | - | - | has | - | - | false | auto | - | - |
| `table_name` | reference | Entity | Table whose DML events are captured | string | false | - | 10 | required | default | - | false | - | 2 | entities | cascade | has queue events | - | - | true | auto | - | - |
| `event_handler` | enum | Event Handler | Which DML operations trigger a queue message | string | false | - | 20 | required | default | - | false | ["insert","update","upsert","delete","change"] | 2 | - | - | - | - | - | false | auto | - | - |
| `event_name` (label) | text | Name | - | string | false | - | 20 | required | default | label | true | - | 2 | - | - | has | - | - | false | auto | - | - |

---

## Entity: raci_assignments

RACI matrix rows assigning roles to processes

| field_name | label | value |
|------------|-------|-------|
| table_name | Table Name | `raci_assignments` |
| singular | Singular | raci_assignment |
| plural | Plural | raci_assignments |
| singular_label | Singular Label | RACI Assignment |
| plural_label | Plural Label | RACI Assignments |
| icon_url | Icon URL | - |
| description | Description | RACI matrix rows assigning roles to processes |
| module_id | Module | 1 |
| view_permission | View Permission | `admin` |
| edit_permission | Edit Permission | `admin` |
| id_column | Id Column | `id` |
| label_column | Label Column | `name` |
| label_parent | Label Parent | - |
| order_column | Order Column | - |
| managed | Managed | true |
| searchable | Searchable | true |
| is_child | Is Child | true |
| edit_mode | Edit Mode | auto |
| cube_mode | Cube Mode | auto |
| entity_type | Entity Type | unclassified |
| audit_log | Audit Log | false |
| computed_fields | Computed Fields | [{"name":"name","jsonlogic":{"var":"raci"}}] |
| validation_rules | Validation Rules | - |
| select_rule | Select Rule | - |
| catalog_entity_code | Catalog Entity Code | - |
| catalog_owner_module | Catalog Owner Module | - |
| catalog_entity_aliases | Catalog Entity Aliases | - |

### Fields

| field_name | format | title | description | type | is_pk | default_value | field_order | input_type | width | ctype | searchable | enum_values | precision | reference_table | reference_delete_mode | relationship_label | singular_label_parent | plural_label_parent | unique_value | cube_type | input_type_rule | catalog_field_code |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `name` (label) | text | Name | Display label — mirrors the RACI letter (computed) | string | false | - | 5 | readonly | default | label | true | - | 2 | - | - | has | - | - | false | auto | - | - |
| `id` 🔑 (id) | int32 | Id | - | integer | true | - | 10 | readonly | default | id | false | - | 2 | - | - | has | - | - | false | auto | - | - |
| `process_id` | parent | Process | - | integer | false | - | 10 | required | default | - | false | - | 2 | processes | cascade | has | - | - | false | auto | - | - |
| `role_id` | reference | Role | The persona role assigned this letter | integer | false | - | 20 | required | default | - | false | - | 2 | roles | cascade | has | - | - | false | auto | - | - |
| `raci` | enum | RACI | - | string | false | - | 30 | required | default | - | false | ["responsible","accountable","consulted","informed"] | 2 | - | - | has | - | - | false | auto | - | - |
| `consult_mode` | enum | Consult Mode | How a consulted actor takes part: read (passive), notify (push) or block (gate). Applies only when raci is consulted. | string | false | read | 40 | default | default | - | false | ["read","notify","block"] | 2 | - | - | has | - | - | false | auto | - | - |
| `origin` | enum | Origin | How this row was created: system (generated by the platform) or user (created or edited by a user) | string | false | user | 50 | default | default | - | false | ["system","user"] | 2 | - | - | has | - | - | false | auto | - | - |

---

## Entity: raci_events

Notify/consult audit log for RACI-governed record transitions

| field_name | label | value |
|------------|-------|-------|
| table_name | Table Name | `raci_events` |
| singular | Singular | raci_event |
| plural | Plural | raci_events |
| singular_label | Singular Label | RACI Event |
| plural_label | Plural Label | RACI Events |
| icon_url | Icon URL | - |
| description | Description | Notify/consult audit log for RACI-governed record transitions |
| module_id | Module | 1 |
| view_permission | View Permission | `admin` |
| edit_permission | Edit Permission | `admin` |
| id_column | Id Column | `id` |
| label_column | Label Column | `record_id` |
| label_parent | Label Parent | - |
| order_column | Order Column | - |
| managed | Managed | true |
| searchable | Searchable | true |
| is_child | Is Child | true |
| edit_mode | Edit Mode | auto |
| cube_mode | Cube Mode | auto |
| entity_type | Entity Type | unclassified |
| audit_log | Audit Log | false |
| computed_fields | Computed Fields | - |
| validation_rules | Validation Rules | - |
| select_rule | Select Rule | - |
| catalog_entity_code | Catalog Entity Code | - |
| catalog_owner_module | Catalog Owner Module | - |
| catalog_entity_aliases | Catalog Entity Aliases | - |

### Fields

| field_name | format | title | description | type | is_pk | default_value | field_order | input_type | width | ctype | searchable | enum_values | precision | reference_table | reference_delete_mode | relationship_label | singular_label_parent | plural_label_parent | unique_value | cube_type | input_type_rule | catalog_field_code |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `process_id` | parent | Process | - | integer | false | - | 10 | required | default | - | false | - | 2 | processes | cascade | has | - | - | false | auto | - | - |
| `id` 🔑 (id) | int32 | Id | - | integer | true | - | 10 | readonly | default | id | false | - | 2 | - | - | has | - | - | false | auto | - | - |
| `entity` | text | Entity | - | string | false | - | 20 | required | default | - | false | - | 2 | - | - | has | - | - | false | auto | - | - |
| `record_id` (label) | text | Record | Governed record PK (text for non-integer PKs) | string | false | - | 30 | required | default | label | true | - | 2 | - | - | has | - | - | false | auto | - | - |
| `raci` | enum | RACI | RACI role of the actor. Only consulted and informed actors generate events, so these are the only values. | string | false | - | 40 | required | default | - | false | ["consulted","informed"] | 2 | - | - | has | - | - | false | auto | - | - |
| `target_role_id` | reference | Target Role | Role to be notified or consulted | integer | false | - | 50 | required | default | - | false | - | 2 | roles | cascade | has | - | - | false | auto | - | - |
| `status` | enum | Status | pending → sent → acted; acted = the consultation input was received | string | false | pending | 60 | required | default | - | false | ["pending","sent","acted"] | 2 | - | - | has | - | - | false | auto | - | - |
| `acted_at` | date-time | Acted At | When the consulted party responded (NULL until acted) | string | false | - | 70 | disabled | default | - | false | - | 2 | - | - | has | - | - | false | auto | - | - |

---

## Entity: role_permissions

Many-to-many mapping between roles and permissions

| field_name | label | value |
|------------|-------|-------|
| table_name | Table Name | `role_permissions` |
| singular | Singular | role_permission |
| plural | Plural | role_permissions |
| singular_label | Singular Label | Role Permission |
| plural_label | Plural Label | Role Permissions |
| icon_url | Icon URL | - |
| description | Description | Many-to-many mapping between roles and permissions |
| module_id | Module | 1 |
| view_permission | View Permission | `admin` |
| edit_permission | Edit Permission | `admin` |
| id_column | Id Column | `id` |
| label_column | Label Column | `id` |
| label_parent | Label Parent | - |
| order_column | Order Column | - |
| managed | Managed | true |
| searchable | Searchable | false |
| is_child | Is Child | true |
| edit_mode | Edit Mode | auto |
| cube_mode | Cube Mode | auto |
| entity_type | Entity Type | junction |
| audit_log | Audit Log | true |
| computed_fields | Computed Fields | - |
| validation_rules | Validation Rules | - |
| select_rule | Select Rule | - |
| catalog_entity_code | Catalog Entity Code | - |
| catalog_owner_module | Catalog Owner Module | - |
| catalog_entity_aliases | Catalog Entity Aliases | - |

### Fields

| field_name | format | title | description | type | is_pk | default_value | field_order | input_type | width | ctype | searchable | enum_values | precision | reference_table | reference_delete_mode | relationship_label | singular_label_parent | plural_label_parent | unique_value | cube_type | input_type_rule | catalog_field_code |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `id` 🔑 (id) | text | Id | Generated identifier (role_id.permission_name) | string | true | - | 1 | readonly | default | id | false | - | 2 | - | - | - | - | - | false | auto | - | - |
| `role_id` (core) | parent | Role | - | integer | false | - | 10 | default | default | core | false | - | 2 | roles | cascade | has permissions | Permission | Permissions | false | auto | - | - |
| `permission_name` (core) | parent | Permission | - | string | false | - | 20 | default | default | core | false | - | 2 | permissions | cascade | granted to | Permission | Permissions | false | auto | - | - |
| `granted_at` (core) | date-time | Granted At | - | string | false | - | 30 | disabled | default | core | false | - | 2 | - | - | - | - | - | false | auto | - | - |
| `granted_by` (core) | reference | Granted By | - | integer | false | - | 40 | default | default | core | false | - | 2 | users | clear | has granted | - | - | false | auto | - | - |

---

## Entity: roles

Groups of permissions that can be assigned to users

| field_name | label | value |
|------------|-------|-------|
| table_name | Table Name | `roles` |
| singular | Singular | role |
| plural | Plural | roles |
| singular_label | Singular Label | Role |
| plural_label | Plural Label | Roles |
| icon_url | Icon URL | - |
| description | Description | Groups of permissions that can be assigned to users |
| module_id | Module | 1 |
| view_permission | View Permission | `admin` |
| edit_permission | Edit Permission | `admin` |
| id_column | Id Column | `id` |
| label_column | Label Column | `role_name` |
| label_parent | Label Parent | - |
| order_column | Order Column | - |
| managed | Managed | true |
| searchable | Searchable | true |
| is_child | Is Child | false |
| edit_mode | Edit Mode | auto |
| cube_mode | Cube Mode | auto |
| entity_type | Entity Type | unclassified |
| audit_log | Audit Log | true |
| computed_fields | Computed Fields | - |
| validation_rules | Validation Rules | [{"code":"90203","message":"roles.origin is set on INSERT and cannot be changed","jsonlogic":{"if":[{"value_changed":"origin"},{"==":[{"var":"$old"},null]},true]},"source_module":"platform"},{"code":"90204","message":"system role slugs cannot be changed after creation","jsonlogic":{"if":[{"and":[{"value_changed":"slug"},{"==":[{"var":"origin"},"system"]}]},{"==":[{"var":"$old"},null]},true]},"source_module":"platform"},{"code":"90206","message":"catalog_role_code is write-once: it cannot be changed once set","jsonlogic":{"if":[{"value_changed":"catalog_role_code"},{"or":[{"==":[{"var":"$old"},null]},{"==":[{"var":"$old.catalog_role_code"},""]}]},true]},"source_module":"platform"}] |
| select_rule | Select Rule | - |
| catalog_entity_code | Catalog Entity Code | - |
| catalog_owner_module | Catalog Owner Module | - |
| catalog_entity_aliases | Catalog Entity Aliases | - |

### Fields

| field_name | format | title | description | type | is_pk | default_value | field_order | input_type | width | ctype | searchable | enum_values | precision | reference_table | reference_delete_mode | relationship_label | singular_label_parent | plural_label_parent | unique_value | cube_type | input_type_rule | catalog_field_code |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `id` 🔑 (id) | int32 | Id | - | integer | true | - | 1 | readonly | default | id | false | - | 2 | - | - | - | - | - | false | auto | - | - |
| `role_name` (label) | text | Role Name | - | string | false | - | 10 | required | default | label | true | - | 2 | - | - | - | - | - | false | auto | - | - |
| `slug` (core) | text | Slug | Snake_case unique identifier for the role, derived from role_name when omitted. Cannot be changed on a system role. | string | false | - | 15 | default | default | core | false | - | 2 | - | - | - | - | - | true | auto | - | - |
| `catalog_role_code` (core) | text | Catalog Role Code | Stable catalog persona/role this role was provisioned from (lineage; non-unique). Write-once: set on create or filled once while empty, then never changed. Empty = not generated from a catalog spec. | string | false | - | 16 | default | default | core | false | - | 2 | - | - | - | - | - | false | auto | - | - |
| `description` (core) | multiline | Description | - | string | false | - | 20 | default | w | core | true | - | 2 | - | - | - | - | - | false | auto | - | - |
| `origin` (core) | enum | Origin | How the role was created: system (platform built-in), model (scaffold role of a domain module), model_master (scaffold role of a master module) or user (created by an admin). Set on insert and never changed. | string | false | user | 25 | readonly | default | core | false | ["system","model","model_master","user"] | 2 | - | - | - | - | - | false | auto | - | - |
| `module_id` (core) | reference | Module | - | integer | false | - | 30 | default | default | core | false | - | 2 | modules | clear | contains | - | - | false | auto | - | - |

---

## Entity: user_bookmarks

Manage and order your facorites for quick access to frequently used apps and records.

| field_name | label | value |
|------------|-------|-------|
| table_name | Table Name | `user_bookmarks` |
| singular | Singular | user_bookmark |
| plural | Plural | user_bookmarks |
| singular_label | Singular Label | User Bookmark |
| plural_label | Plural Label | Favorites |
| icon_url | Icon URL | - |
| description | Description | Manage and order your facorites for quick access to frequently used apps and records. |
| module_id | Module | 1 |
| view_permission | View Permission | `user:read` |
| edit_permission | Edit Permission | `user:read` |
| id_column | Id Column | `id` |
| label_column | Label Column | `title` |
| label_parent | Label Parent | - |
| order_column | Order Column | row_order |
| managed | Managed | true |
| searchable | Searchable | true |
| is_child | Is Child | false |
| edit_mode | Edit Mode | auto |
| cube_mode | Cube Mode | auto |
| entity_type | Entity Type | unclassified |
| audit_log | Audit Log | false |
| computed_fields | Computed Fields | - |
| validation_rules | Validation Rules | - |
| select_rule | Select Rule | {"==":[{"var":"user_id"},{"var":"$user_id"}]} |
| catalog_entity_code | Catalog Entity Code | - |
| catalog_owner_module | Catalog Owner Module | - |
| catalog_entity_aliases | Catalog Entity Aliases | - |

### Fields

| field_name | format | title | description | type | is_pk | default_value | field_order | input_type | width | ctype | searchable | enum_values | precision | reference_table | reference_delete_mode | relationship_label | singular_label_parent | plural_label_parent | unique_value | cube_type | input_type_rule | catalog_field_code |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `user_id` | reference | User | Owner of this bookmark (auto-assigned to current user) | integer | false | - | 10 | hidden | default | - | false | - | 2 | users | cascade | has | - | - | false | auto | - | - |
| `id` 🔑 (id) | int32 | Id | - | integer | true | - | 10 | readonly | default | id | false | - | 2 | - | - | has | - | - | false | auto | - | - |
| `title` (label) | text | Name | - | string | false | - | 20 | required | default | label | true | - | 2 | - | - | has | - | - | false | auto | - | - |
| `url` | text | URL | - | string | false | - | 30 | default | w | - | false | - | 2 | - | - | has | - | - | false | auto | - | - |
| `entity_name` | text | Entity | - | string | false | - | 40 | default | default | - | false | - | 2 | - | - | has | - | - | false | auto | - | - |
| `entity_id` | int32 | Record | ID of the related record in the entity table (0 = no record) | integer | false | - | 50 | default | default | - | false | - | 2 | - | - | has | - | - | false | auto | - | - |

---

## Entity: user_permissions

Many-to-many mapping between users and permissions for direct per-user permission grants

| field_name | label | value |
|------------|-------|-------|
| table_name | Table Name | `user_permissions` |
| singular | Singular | user_permission |
| plural | Plural | user_permissions |
| singular_label | Singular Label | User Permission |
| plural_label | Plural Label | User Permissions |
| icon_url | Icon URL | - |
| description | Description | Many-to-many mapping between users and permissions for direct per-user permission grants |
| module_id | Module | 1 |
| view_permission | View Permission | `admin` |
| edit_permission | Edit Permission | `admin` |
| id_column | Id Column | `id` |
| label_column | Label Column | `id` |
| label_parent | Label Parent | - |
| order_column | Order Column | - |
| managed | Managed | true |
| searchable | Searchable | false |
| is_child | Is Child | true |
| edit_mode | Edit Mode | auto |
| cube_mode | Cube Mode | auto |
| entity_type | Entity Type | junction |
| audit_log | Audit Log | true |
| computed_fields | Computed Fields | - |
| validation_rules | Validation Rules | - |
| select_rule | Select Rule | - |
| catalog_entity_code | Catalog Entity Code | - |
| catalog_owner_module | Catalog Owner Module | - |
| catalog_entity_aliases | Catalog Entity Aliases | - |

### Fields

| field_name | format | title | description | type | is_pk | default_value | field_order | input_type | width | ctype | searchable | enum_values | precision | reference_table | reference_delete_mode | relationship_label | singular_label_parent | plural_label_parent | unique_value | cube_type | input_type_rule | catalog_field_code |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `id` 🔑 (id) | text | Id | Generated identifier (user_id.permission_name) | string | true | - | 1 | readonly | default | id | false | - | 2 | - | - | - | - | - | false | auto | - | - |
| `user_id` (core) | parent | User | - | integer | false | - | 10 | required | default | core | false | - | 2 | users | cascade | has permissions | Permission | Permissions | false | auto | - | - |
| `permission_name` (core) | parent | Permission | - | string | false | - | 20 | required | default | core | false | - | 2 | permissions | cascade | granted to | User | Users | false | auto | - | - |
| `granted_at` (core) | date-time | Granted At | - | string | false | - | 30 | disabled | default | core | false | - | 2 | - | - | - | - | - | false | auto | - | - |
| `granted_by` (core) | reference | Granted By | - | integer | false | - | 40 | default | default | core | false | - | 2 | users | clear | has granted | - | - | false | auto | - | - |

---

## Entity: user_roles

Many-to-many mapping between users and roles

| field_name | label | value |
|------------|-------|-------|
| table_name | Table Name | `user_roles` |
| singular | Singular | user_role |
| plural | Plural | user_roles |
| singular_label | Singular Label | User Role |
| plural_label | Plural Label | User Roles |
| icon_url | Icon URL | - |
| description | Description | Many-to-many mapping between users and roles |
| module_id | Module | 1 |
| view_permission | View Permission | `admin` |
| edit_permission | Edit Permission | `admin` |
| id_column | Id Column | `id` |
| label_column | Label Column | `id` |
| label_parent | Label Parent | - |
| order_column | Order Column | - |
| managed | Managed | true |
| searchable | Searchable | false |
| is_child | Is Child | true |
| edit_mode | Edit Mode | auto |
| cube_mode | Cube Mode | auto |
| entity_type | Entity Type | junction |
| audit_log | Audit Log | true |
| computed_fields | Computed Fields | - |
| validation_rules | Validation Rules | - |
| select_rule | Select Rule | - |
| catalog_entity_code | Catalog Entity Code | - |
| catalog_owner_module | Catalog Owner Module | - |
| catalog_entity_aliases | Catalog Entity Aliases | - |

### Fields

| field_name | format | title | description | type | is_pk | default_value | field_order | input_type | width | ctype | searchable | enum_values | precision | reference_table | reference_delete_mode | relationship_label | singular_label_parent | plural_label_parent | unique_value | cube_type | input_type_rule | catalog_field_code |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `id` 🔑 (id) | text | Id | Generated identifier (user_id.role_id) | string | true | - | 1 | readonly | default | id | false | - | 2 | - | - | - | - | - | false | auto | - | - |
| `user_id` (core) | parent | User | - | integer | false | - | 10 | required | default | core | false | - | 2 | users | cascade | has roles | Role | Roles | false | auto | - | - |
| `role_id` (core) | parent | Role | - | integer | false | - | 20 | required | default | core | false | - | 2 | roles | cascade | assigned to | User | Users | false | auto | - | - |
| `assigned_at` (core) | date-time | Assigned At | - | string | false | - | 30 | disabled | default | core | false | - | 2 | - | - | - | - | - | false | auto | - | - |
| `assigned_by` (core) | reference | Assigned By | - | integer | false | - | 40 | default | default | core | false | - | 2 | users | clear | has assigned | - | - | false | auto | - | - |

---

## Entity: users

Users and agents

| field_name | label | value |
|------------|-------|-------|
| table_name | Table Name | `users` |
| singular | Singular | user |
| plural | Plural | users |
| singular_label | Singular Label | User |
| plural_label | Plural Label | Users |
| icon_url | Icon URL | - |
| description | Description | Users and agents |
| module_id | Module | 1 |
| view_permission | View Permission | `user:read` |
| edit_permission | Edit Permission | `user:manage` |
| id_column | Id Column | `id` |
| label_column | Label Column | `email` |
| label_parent | Label Parent | - |
| order_column | Order Column | - |
| managed | Managed | true |
| searchable | Searchable | true |
| is_child | Is Child | false |
| edit_mode | Edit Mode | auto |
| cube_mode | Cube Mode | auto |
| entity_type | Entity Type | unclassified |
| audit_log | Audit Log | true |
| computed_fields | Computed Fields | - |
| validation_rules | Validation Rules | - |
| select_rule | Select Rule | - |
| catalog_entity_code | Catalog Entity Code | - |
| catalog_owner_module | Catalog Owner Module | - |
| catalog_entity_aliases | Catalog Entity Aliases | - |

### Fields

| field_name | format | title | description | type | is_pk | default_value | field_order | input_type | width | ctype | searchable | enum_values | precision | reference_table | reference_delete_mode | relationship_label | singular_label_parent | plural_label_parent | unique_value | cube_type | input_type_rule | catalog_field_code |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `id` 🔑 (id) | int32 | Id | - | integer | true | - | 1 | readonly | default | id | false | - | 2 | - | - | has | - | - | false | auto | - | - |
| `external_id` (core) | text | External Identity | Identity: the JWT sub claim from the authentication provider. Never empty: a human user must bring one, and an agent saved without one gets agent:<uuid>. | string | false | - | 10 | readonly | default | core | true | - | 2 | - | - | has | - | - | true | auto | - | - |
| `email` (label) | email | Email | - | string | false | - | 20 | default | default | label | true | - | 2 | - | - | has | - | - | false | auto | - | - |
| `first_name` (core) | text | First Name | - | string | false | - | 22 | default | default | core | true | - | 2 | - | - | has | - | - | false | auto | - | - |
| `last_name` (core) | text | Last Name | - | string | false | - | 23 | default | default | core | true | - | 2 | - | - | has | - | - | false | auto | - | - |
| `display_name` (core) | text | Display Name | - | string | false | - | 25 | default | default | core | true | - | 2 | - | - | has | - | - | false | auto | - | - |
| `is_disabled` (core) | boolean | Is Disabled | - | boolean | false | - | 30 | default | default | core | false | - | 2 | - | - | has | - | - | false | auto | - | - |
| `settings` (core) | json | Settings | - | json | false | - | 35 | default | w | core | false | - | 2 | - | - | has | - | - | false | auto | - | - |
| `last_seen` (core) | date-time | Last Seen | - | string | false | - | 60 | readonly | default | core | false | - | 2 | - | - | has | - | - | false | auto | - | - |
| `is_agent` | boolean | Is Agent | A service principal (agent) rather than a person | boolean | false | false | 100 | default | default | - | false | - | 2 | - | - | has | - | - | false | auto | - | - |

---

## Entity: webhook_receiver_logs

Log of webhook receiver events

| field_name | label | value |
|------------|-------|-------|
| table_name | Table Name | `webhook_receiver_logs` |
| singular | Singular | webhook_receiver_log |
| plural | Plural | webhook_receiver_logs |
| singular_label | Singular Label | Webhook Receiver Log |
| plural_label | Plural Label | Webhook Receiver Logs |
| icon_url | Icon URL | - |
| description | Description | Log of webhook receiver events |
| module_id | Module | 1 |
| view_permission | View Permission | `admin` |
| edit_permission | Edit Permission | `admin` |
| id_column | Id Column | `id` |
| label_column | Label Column | `label` |
| label_parent | Label Parent | - |
| order_column | Order Column | - |
| managed | Managed | true |
| searchable | Searchable | true |
| is_child | Is Child | true |
| edit_mode | Edit Mode | auto |
| cube_mode | Cube Mode | auto |
| entity_type | Entity Type | unclassified |
| audit_log | Audit Log | false |
| computed_fields | Computed Fields | - |
| validation_rules | Validation Rules | - |
| select_rule | Select Rule | - |
| catalog_entity_code | Catalog Entity Code | - |
| catalog_owner_module | Catalog Owner Module | - |
| catalog_entity_aliases | Catalog Entity Aliases | - |

### Fields

| field_name | format | title | description | type | is_pk | default_value | field_order | input_type | width | ctype | searchable | enum_values | precision | reference_table | reference_delete_mode | relationship_label | singular_label_parent | plural_label_parent | unique_value | cube_type | input_type_rule | catalog_field_code |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `webhook_receiver_id` | parent | Webhook Receiver | - | integer | false | - | 5 | default | default | - | false | - | 2 | webhook_receivers | cascade | has logs | - | - | false | auto | - | - |
| `id` 🔑 (id) | int32 | Id | - | integer | true | - | 10 | readonly | default | id | false | - | 2 | - | - | has | - | - | false | auto | - | - |
| `message_id` | text | Message | The sender's webhook-id header, or a key derived from the request when it sends none. A delivery whose message_id already succeeded is skipped. | string | false | - | 10 | default | default | - | false | - | 2 | - | - | - | - | - | false | auto | - | - |
| `label` (label) | text | Name | - | string | false | - | 20 | required | default | label | true | - | 2 | - | - | has | - | - | false | auto | - | - |
| `webhook_timestamp` | date-time | Webhook Timestamp | Timestamp from webhook source | string | false | - | 30 | default | default | - | false | - | 2 | - | - | - | - | - | false | auto | - | - |
| `received_timestamp` | date-time | Received Timestamp | - | string | false | CURRENT_TIMESTAMP | 40 | disabled | default | - | false | - | 2 | - | - | - | - | - | false | auto | - | - |
| `payload` | json | Payload | - | json | false | - | 50 | default | w | - | false | - | 2 | - | - | - | - | - | false | auto | - | - |
| `result` | enum | Result | Processing result: 10=success, 20=signature failed, 30=invalid JSON, 40=target table not found, 50=insert failed, 60=JSONata transform error | string | false | 10 | 60 | default | default | - | false | ["10","20","30","40","50","60"] | 2 | - | - | - | - | - | false | auto | - | - |
| `error_message` | text | Error Message | - | string | false | - | 70 | default | w | - | false | - | 2 | - | - | - | - | - | false | auto | - | - |

---

## Entity: webhook_receivers

Configuration for webhook endpoints

| field_name | label | value |
|------------|-------|-------|
| table_name | Table Name | `webhook_receivers` |
| singular | Singular | webhook_receiver |
| plural | Plural | webhook_receivers |
| singular_label | Singular Label | Webhook Receiver |
| plural_label | Plural Label | Webhook Receivers |
| icon_url | Icon URL | - |
| description | Description | Configuration for webhook endpoints |
| module_id | Module | 1 |
| view_permission | View Permission | `admin` |
| edit_permission | Edit Permission | `admin` |
| id_column | Id Column | `id` |
| label_column | Label Column | `label` |
| label_parent | Label Parent | - |
| order_column | Order Column | - |
| managed | Managed | true |
| searchable | Searchable | true |
| is_child | Is Child | false |
| edit_mode | Edit Mode | auto |
| cube_mode | Cube Mode | auto |
| entity_type | Entity Type | unclassified |
| audit_log | Audit Log | false |
| computed_fields | Computed Fields | - |
| validation_rules | Validation Rules | - |
| select_rule | Select Rule | - |
| catalog_entity_code | Catalog Entity Code | - |
| catalog_owner_module | Catalog Owner Module | - |
| catalog_entity_aliases | Catalog Entity Aliases | - |

### Fields

| field_name | format | title | description | type | is_pk | default_value | field_order | input_type | width | ctype | searchable | enum_values | precision | reference_table | reference_delete_mode | relationship_label | singular_label_parent | plural_label_parent | unique_value | cube_type | input_type_rule | catalog_field_code |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `table_name` | reference | Entity | Target table for webhook data | string | false | - | 10 | default | default | - | false | - | 2 | entities | cascade | has receivers | - | - | false | auto | - | - |
| `id` 🔑 (id) | int32 | Id | - | integer | true | - | 10 | readonly | default | id | false | - | 2 | - | - | has | - | - | false | auto | - | - |
| `description` | text | Description | - | string | false | - | 20 | default | w | - | false | - | 2 | - | - | - | - | - | false | auto | - | - |
| `label` (label) | text | Name | - | string | false | - | 20 | required | default | label | true | - | 2 | - | - | has | - | - | false | auto | - | - |
| `auth_type` | enum | Authentication Type | hmac = HMAC signature over the body; header = expected value in a named header | string | false | none | 30 | default | default | - | false | ["none","hmac","header"] | 2 | - | - | - | - | - | false | auto | - | - |
| `secret` | text | Secret | - | string | false | - | 40 | default | default | - | false | - | 2 | - | - | - | - | - | false | auto | - | - |
| `header_name` | text | Header Name | Custom header name for authentication | string | false | - | 45 | default | default | - | false | - | 2 | - | - | - | - | - | false | auto | - | - |
| `header_value` | text | Header Value | Expected value for custom header authentication | string | false | - | 46 | default | default | - | false | - | 2 | - | - | - | - | - | false | auto | - | - |
| `jsonata` | jsonata | JSONata Expression | Optional JSONata expression to transform incoming data | string | false | - | 50 | default | w | - | false | - | 2 | - | - | - | - | - | false | auto | - | - |

---

