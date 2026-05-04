# Database Schema Documentation

This document describes the database schema for the _core module.

**Generated:** 2026-05-04T16:32:20.842Z

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
| module_id | Module Id | 1 |
| view_permission | View Permission | `admin` |
| edit_permission | Edit Permission | `admin` |
| id_column | Id Column | `id` |
| label_column | Label Column | `command_tag` |
| managed | Managed | false |
| searchable | Searchable | true |
| is_child | Is Child | false |
| edit_mode | Edit Mode | auto |
| cube_mode | Cube Mode | auto |
| audit_log | Audit Log | false |

### Fields

| field_name | title | description | type | format | is_pk | is_nullable | default_value | field_order | input_type | width | ctype | is_core | searchable | enum_values | reference_table | precision | reference_delete_mode | relationship_label | singular_label_parent | plural_label_parent | unique_value | cube_type |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `id` 🔑 (id) | Id | - | integer | int64 | true | false | - | 1 | readonly | default | id | true | false | - | - | 2 | - | has | - | - | false | auto |
| `event_time` | Event Time | When the DDL command completed | string | date-time | false | true | - | 10 | readonly | default | - | true | false | - | - | 2 | - | has | - | - | false | auto |
| `user_id` | User Id | Internal user id from JWT context (0 when unavailable) | integer | int32 | false | false | - | 20 | readonly | default | - | true | false | - | - | 2 | - | has | - | - | false | auto |
| `command_tag` (label) | Command Tag | DDL command type (e.g. CREATE TABLE, ALTER TABLE) | string | text | false | false | - | 30 | readonly | default | label | true | true | - | - | 2 | - | has | - | - | false | auto |
| `object_type` | Object Type | Type of database object affected | string | text | false | false | - | 40 | readonly | default | - | true | true | - | - | 2 | - | has | - | - | false | auto |
| `object_identity` | Object Identity | Fully qualified name of the affected object | string | text | false | false | - | 50 | readonly | w | - | true | true | - | - | 2 | - | has | - | - | false | auto |
| `query_text` | Query Text | The SQL statement that triggered the event | string | text | false | false | - | 60 | readonly | w | - | true | false | - | - | 2 | - | has | - | - | false | auto |

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
| module_id | Module Id | 1 |
| view_permission | View Permission | `admin` |
| edit_permission | Edit Permission | `admin` |
| id_column | Id Column | `id` |
| label_column | Label Column | `table_name` |
| managed | Managed | false |
| searchable | Searchable | true |
| is_child | Is Child | false |
| edit_mode | Edit Mode | auto |
| cube_mode | Cube Mode | auto |
| audit_log | Audit Log | false |

### Fields

| field_name | title | description | type | format | is_pk | is_nullable | default_value | field_order | input_type | width | ctype | is_core | searchable | enum_values | reference_table | precision | reference_delete_mode | relationship_label | singular_label_parent | plural_label_parent | unique_value | cube_type |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `id` 🔑 (id) | Id | - | integer | int64 | true | false | - | 1 | readonly | default | id | true | false | - | - | 2 | - | has | - | - | false | auto |
| `record_id` | Record Id | Deterministic UUID computed from table OID and primary key values | string | uuid | false | false | - | 10 | readonly | default | - | true | false | - | - | 2 | - | has | - | - | false | auto |
| `old_record_id` | Old Record Id | Record id before update/delete | string | uuid | false | false | - | 20 | readonly | default | - | true | false | - | - | 2 | - | has | - | - | false | auto |
| `record_pk` | Record PK | Primary key value of the affected record | string | text | false | false | - | 25 | readonly | default | - | true | true | - | - | 2 | - | has | - | - | false | auto |
| `op` | Operation | DML operation type: INSERT, UPDATE, DELETE, TRUNCATE | string | text | false | false | - | 30 | readonly | default | - | true | false | - | - | 2 | - | has | - | - | false | auto |
| `ts` | Timestamp | When the operation occurred | string | date-time | false | true | - | 40 | readonly | default | - | true | false | - | - | 2 | - | has | - | - | false | auto |
| `user_id` | User Id | Internal user id from JWT context (0 when unavailable) | integer | int32 | false | false | - | 50 | readonly | default | - | true | false | - | - | 2 | - | has | - | - | false | auto |
| `table_oid` | Table OID | PostgreSQL internal object identifier for the table | integer | int32 | false | false | - | 60 | readonly | default | - | true | false | - | - | 2 | - | has | - | - | false | auto |
| `table_schema` | Table Schema | Schema containing the table | string | text | false | false | - | 70 | readonly | default | - | true | true | - | - | 2 | - | has | - | - | false | auto |
| `table_name` (label) | Table Name | Name of the affected table | string | text | false | false | - | 80 | readonly | default | label | true | true | - | - | 2 | - | has | - | - | false | auto |
| `record` | Record | Full record after INSERT/UPDATE (JSONB) | json | json | false | false | - | 90 | readonly | w | - | true | false | - | - | 2 | - | has | - | - | false | auto |
| `old_record` | Old Record | Previous record before UPDATE/DELETE (JSONB) | json | json | false | false | - | 100 | readonly | w | - | true | false | - | - | 2 | - | has | - | - | false | auto |

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
| module_id | Module Id | 1 |
| view_permission | View Permission | `admin` |
| edit_permission | Edit Permission | `admin` |
| id_column | Id Column | `id` |
| label_column | Label Column | `label` |
| managed | Managed | true |
| searchable | Searchable | true |
| is_child | Is Child | false |
| edit_mode | Edit Mode | auto |
| cube_mode | Cube Mode | auto |
| audit_log | Audit Log | false |

### Fields

| field_name | title | description | type | format | is_pk | is_nullable | default_value | field_order | input_type | width | ctype | is_core | searchable | enum_values | reference_table | precision | reference_delete_mode | relationship_label | singular_label_parent | plural_label_parent | unique_value | cube_type |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `id` 🔑 (id) | Id | - | integer | int32 | true | false | - | 1 | readonly | default | id | true | false | - | - | 2 | - | has | - | - | false | auto |
| `label` (label) | Dashboard | - | string | text | false | false | - | 1 | required | default | label | true | true | - | - | 2 | - | has | - | - | false | auto |
| `config` | Configuration | Dashboard layout and widget configuration | json | json | false | false | - | 10 | default | w | - | false | false | - | - | 2 | - | has | - | - | false | auto |
| `position` | Position | Display order position | integer | int32 | false | false | 0 | 20 | default | default | - | false | false | - | - | 2 | - | has | - | - | false | auto |
| `module_id` | Module | Module this dashboard belongs to | integer | reference | false | true | - | 30 | default | default | - | false | false | - | modules | 2 | cascade | has | - | - | false | auto |
| `view_permission` | View Permission | Permission required to view this dashboard | integer | reference | false | true | - | 40 | default | default | - | false | false | - | permissions | 2 | clear | has | - | - | false | auto |

---

## Entity: entities

Metadata for dynamically created tables

| field_name | label | value |
|------------|-------|-------|
| table_name | Table Name | `entities` |
| singular | Singular | entity |
| plural | Plural | entities |
| singular_label | Singular Label | Entity |
| plural_label | Plural Label | Entities |
| icon_url | Icon URL | - |
| description | Description | Metadata for dynamically created tables |
| module_id | Module Id | 1 |
| view_permission | View Permission | `public:read` |
| edit_permission | Edit Permission | `admin` |
| id_column | Id Column | `table_name` |
| label_column | Label Column | `singular_label` |
| managed | Managed | true |
| searchable | Searchable | true |
| is_child | Is Child | false |
| edit_mode | Edit Mode | auto |
| cube_mode | Cube Mode | auto |
| audit_log | Audit Log | true |

### Fields

| field_name | title | description | type | format | is_pk | is_nullable | default_value | field_order | input_type | width | ctype | is_core | searchable | enum_values | reference_table | precision | reference_delete_mode | relationship_label | singular_label_parent | plural_label_parent | unique_value | cube_type |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `table_name` 🔑 (id) | Table Name | Physical table name in database | string | text | true | false | - | 1 | required | default | id | true | true | - | - | 2 | - | - | - | - | false | auto |
| `singular` | Singular | Singular form of table name | string | text | false | false | - | 10 | required | default | - | true | true | - | - | 2 | - | - | - | - | false | auto |
| `plural` | Plural | Plural form of table name, auto-assigned to table_name | string | text | false | false | - | 20 | readonly | default | - | true | true | - | - | 2 | - | - | - | - | false | auto |
| `singular_label` (label) | Singular Label | Human-readable singular label for UI/reports | string | text | false | false | - | 30 | default | default | label | true | true | - | - | 2 | - | - | - | - | false | auto |
| `plural_label` | Plural Label | Human-readable plural label for UI/reports | string | text | false | false | - | 40 | default | default | - | true | true | - | - | 2 | - | - | - | - | false | auto |
| `icon_url` | Icon URL | Optional URL or path to icon for this table | string | url | false | false | - | 50 | default | w | - | true | false | - | - | 2 | - | - | - | - | false | auto |
| `description` | Description | - | string | text | false | false | - | 60 | default | w | - | true | true | - | - | 2 | - | - | - | - | false | auto |
| `module_id` | Module Id | - | integer | reference | false | true | - | 70 | default | default | - | true | false | - | modules | 2 | clear | contains | - | - | false | auto |
| `view_permission` | View Permission | Permission required to SELECT from this table | string | text | false | false | public:read | 80 | default | default | - | true | false | - | - | 2 | - | - | - | - | false | auto |
| `edit_permission` | Edit Permission | Permission required to INSERT/UPDATE/DELETE from this table | string | text | false | false | admin | 90 | default | default | - | true | false | - | - | 2 | - | - | - | - | false | auto |
| `id_column` | Id Column | Name of primary key column | string | text | false | false | id | 100 | default | default | - | true | false | - | - | 2 | - | - | - | - | false | auto |
| `label_column` | Label Column | Name of label/display column | string | text | false | false | label | 110 | default | default | - | true | false | - | - | 2 | - | - | - | - | false | auto |
| `managed` | Managed | When false, automatic DDL execution is disabled | boolean | boolean | false | false | true | 115 | default | default | - | true | false | - | - | 2 | - | - | - | - | false | auto |
| `searchable` | Searchable | Whether table is included in full-text search (auto-computed) | boolean | boolean | false | false | - | 117 | disabled | default | - | true | false | - | - | 2 | - | - | - | - | false | auto |
| `is_child` | Is Child | Whether table has any parent relationships (auto-computed) | boolean | boolean | false | false | - | 118 | disabled | default | - | true | false | - | - | 2 | - | - | - | - | false | auto |
| `edit_mode` | Edit Mode | UI edit mode for records of this table: auto, sidebar, modal, or page | string | enum | false | false | auto | 119 | default | default | - | true | false | ["auto","sidebar","modal","page"] | - | 2 | - | - | - | - | false | auto |
| `cube_mode` | Cube Mode | Cube mode for OLAP cube generation | string | enum | false | false | auto | 121 | default | default | - | true | false | ["disabled","auto"] | - | 2 | - | - | - | - | false | auto |
| `audit_log` | Audit Log | When enabled, DML operations on this table are logged to the audit log | boolean | boolean | false | false | false | 122 | default | default | - | true | false | - | - | 2 | - | has | - | - | false | auto |

---

## Entity: fields

Metadata for fields in dynamically created tables

| field_name | label | value |
|------------|-------|-------|
| table_name | Table Name | `fields` |
| singular | Singular | field |
| plural | Plural | fields |
| singular_label | Singular Label | Field |
| plural_label | Plural Label | Fields |
| icon_url | Icon URL | - |
| description | Description | Metadata for fields in dynamically created tables |
| module_id | Module Id | 1 |
| view_permission | View Permission | `public:read` |
| edit_permission | Edit Permission | `admin` |
| id_column | Id Column | `id` |
| label_column | Label Column | `title` |
| managed | Managed | true |
| searchable | Searchable | true |
| is_child | Is Child | true |
| edit_mode | Edit Mode | auto |
| cube_mode | Cube Mode | auto |
| audit_log | Audit Log | true |

### Fields

| field_name | title | description | type | format | is_pk | is_nullable | default_value | field_order | input_type | width | ctype | is_core | searchable | enum_values | reference_table | precision | reference_delete_mode | relationship_label | singular_label_parent | plural_label_parent | unique_value | cube_type |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `id` 🔑 (id) | Id | Generated identifier (table_name.field_name) | string | text | true | false | - | 1 | readonly | default | id | true | false | - | - | 2 | - | - | - | - | false | auto |
| `table_name` | Table Name | - | string | parent | false | false | - | 10 | default | default | - | true | true | - | entities | 2 | cascade | has fields | - | - | false | auto |
| `field_name` | Field Name | Physical column name in database | string | text | false | false | - | 20 | required | default | - | true | true | - | - | 2 | - | - | - | - | false | auto |
| `title` (label) | Title | Human-readable display name for the field | string | text | false | false | - | 30 | required | default | label | true | true | - | - | 2 | - | - | - | - | false | auto |
| `description` | Description | - | string | text | false | false | - | 40 | default | w | - | true | true | - | - | 2 | - | - | - | - | false | auto |
| `format` | Format | JSON Schema format or primitive type | string | enum | false | false | string | 50 | required | default | - | true | false | ["json","html","text","code","jsonata","reference","parent","enum","date","time","date-time","duration","uri","uri-reference","uri-template","url","email","hostname","ipv4","ipv6","regex","uuid","json-pointer","json-pointer-uri-fragment","relative-json-pointer","byte","int32","int64","float","double","password","binary","string","number","integer","boolean","object","array","null"] | - | 2 | - | - | - | - | false | auto |
| `is_pk` | Is Primary Key | - | boolean | boolean | false | false | - | 60 | default | default | - | true | false | - | - | 2 | - | - | - | - | false | auto |
| `is_nullable` | Is Nullable | Whether this field allows NULL values (computed from format) | boolean | boolean | false | false | - | 70 | readonly | default | - | true | false | - | - | 2 | - | - | - | - | false | auto |
| `default_value` | Default Value | - | string | text | false | false | - | 80 | default | default | - | true | false | - | - | 2 | - | - | - | - | false | auto |
| `field_order` | Field Order | - | integer | int32 | false | false | - | 90 | default | default | - | true | false | - | - | 2 | - | - | - | - | false | auto |
| `input_type` | Input Type | - | string | enum | false | false | default | 100 | default | default | - | true | false | ["default","required","readonly","disabled","hidden"] | - | 2 | - | - | - | - | false | auto |
| `width` | Width | - | string | enum | false | false | default | 110 | default | default | - | true | false | ["default","s","m","w"] | - | 2 | - | - | - | - | false | auto |
| `ctype` | Column Type | Special column type (id, label, etc.) | string | enum | false | false | - | 120 | default | default | - | true | false | ["","id","label"] | - | 2 | - | - | - | - | false | auto |
| `is_core` | Is Core | - | boolean | boolean | false | false | - | 130 | default | default | - | true | false | - | - | 2 | - | - | - | - | false | auto |
| `searchable` | Searchable | Whether field is included in full-text search | boolean | boolean | false | false | - | 135 | default | default | - | true | false | - | - | 2 | - | - | - | - | false | auto |
| `enum_values` | Enum Values | JSON array of allowed enum values | json | json | false | false | - | 137 | default | w | - | true | false | - | - | 2 | - | - | - | - | false | auto |
| `reference_table` | Reference Table | Table name for foreign key relationships | string | text | false | false | - | 138 | default | default | - | true | false | - | - | 2 | - | - | - | - | false | auto |
| `precision` | Precision | Decimal scale used when generating NUMERIC columns for number formats | integer | int32 | false | false | 2 | 138 | default | default | - | true | false | - | - | 2 | - | - | - | - | false | auto |
| `reference_delete_mode` | Reference Delete Mode | ON DELETE behavior: restrict, clear, or cascade | string | enum | false | false | restrict | 139 | default | default | - | true | false | ["","restrict","clear","cascade"] | - | 2 | - | - | - | - | false | auto |
| `relationship_label` | Relationship Label | Verb describing what the referenced entity does to/with this entity | string | text | false | false | has | 140 | default | default | - | true | false | - | - | 2 | - | - | - | - | false | auto |
| `singular_label_parent` | Singular Label Parent | Custom singular label for the parent entity (overrides default when set) | string | text | false | false | - | 141 | default | default | - | true | false | - | - | 2 | - | - | - | - | false | auto |
| `plural_label_parent` | Plural Label Parent | Custom plural label for the parent entity (overrides default when set) | string | text | false | false | - | 142 | default | default | - | true | false | - | - | 2 | - | - | - | - | false | auto |
| `unique_value` | Unique Value | When TRUE, enforces a partial unique index (NULL and empty strings are not enforced) | boolean | boolean | false | false | - | 143 | default | default | - | true | false | - | - | 2 | - | - | - | - | false | auto |
| `cube_type` | Cube Type | - | string | enum | false | false | auto | 144 | default | default | - | true | false | ["disabled","auto","dimension","measure"] | - | 2 | - | - | - | - | false | auto |

---

## Entity: modules

Logical modules that group related roles and permissions

| field_name | label | value |
|------------|-------|-------|
| table_name | Table Name | `modules` |
| singular | Singular | module |
| plural | Plural | modules |
| singular_label | Singular Label | Module |
| plural_label | Plural Label | Modules |
| icon_url | Icon URL | - |
| description | Description | Logical modules that group related roles and permissions |
| module_id | Module Id | 1 |
| view_permission | View Permission | `admin` |
| edit_permission | Edit Permission | `admin` |
| id_column | Id Column | `id` |
| label_column | Label Column | `module_name` |
| managed | Managed | true |
| searchable | Searchable | true |
| is_child | Is Child | false |
| edit_mode | Edit Mode | auto |
| cube_mode | Cube Mode | auto |
| audit_log | Audit Log | true |

### Fields

| field_name | title | description | type | format | is_pk | is_nullable | default_value | field_order | input_type | width | ctype | is_core | searchable | enum_values | reference_table | precision | reference_delete_mode | relationship_label | singular_label_parent | plural_label_parent | unique_value | cube_type |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `id` 🔑 (id) | Id | - | integer | int32 | true | false | - | 1 | readonly | default | id | true | false | - | - | 2 | - | has | - | - | false | auto |
| `module_name` (label) | Module Name | Unique module name | string | text | false | false | - | 10 | required | default | label | true | true | - | - | 2 | - | has | - | - | false | auto |
| `description` | Description | - | string | text | false | false | - | 20 | default | w | - | true | true | - | - | 2 | - | has | - | - | false | auto |
| `view_permission` | View Permission | Permission required to view this module | string | text | false | false | - | 30 | default | default | - | true | false | - | - | 2 | - | has | - | - | false | auto |
| `logo_url` | Logo URL | URL or base64 data URI for module logo | string | url | false | false | - | 35 | default | w | - | true | false | - | - | 2 | - | has | - | - | false | auto |
| `logo_color` | Logo Color | Hex color code for module logo | string | text | false | false | - | 36 | default | default | - | true | false | - | - | 2 | - | has | - | - | false | auto |
| `home_page` | Home Page | Default home page path for module | string | text | false | false | - | 37 | default | default | - | true | false | - | - | 2 | - | has | - | - | false | auto |
| `alias` | Alias | Alternative name or identifier for module | string | text | false | false | - | 38 | default | default | - | true | false | - | - | 2 | - | has | - | - | false | auto |
| `settings` | Settings | Module-specific settings and configuration | json | json | false | false | - | 50 | default | w | - | true | false | - | - | 2 | - | has | - | - | false | auto |
| `dashboard_config` | Dashboard Configuration | - | json | json | false | false | - | 60 | default | w | - | true | false | - | - | 2 | - | has | - | - | false | auto |

---

## Entity: permission_hierarchy

Defines permission inheritance (parent implies children)

| field_name | label | value |
|------------|-------|-------|
| table_name | Table Name | `permission_hierarchy` |
| singular | Singular | permission_hierarchy |
| plural | Plural | permission_hierarchy |
| singular_label | Singular Label | Permission Hierarchy |
| plural_label | Plural Label | Permission Hierarchy |
| icon_url | Icon URL | - |
| description | Description | Defines permission inheritance (parent implies children) |
| module_id | Module Id | 1 |
| view_permission | View Permission | `admin` |
| edit_permission | Edit Permission | `admin` |
| id_column | Id Column | `id` |
| label_column | Label Column | `id` |
| managed | Managed | true |
| searchable | Searchable | false |
| is_child | Is Child | true |
| edit_mode | Edit Mode | auto |
| cube_mode | Cube Mode | auto |
| audit_log | Audit Log | true |

### Fields

| field_name | title | description | type | format | is_pk | is_nullable | default_value | field_order | input_type | width | ctype | is_core | searchable | enum_values | reference_table | precision | reference_delete_mode | relationship_label | singular_label_parent | plural_label_parent | unique_value | cube_type |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `id` 🔑 (id) | Id | Generated identifier (parent_permission_id.child_permission_id) | string | text | true | false | - | 1 | readonly | default | id | true | false | - | - | 2 | - | - | - | - | false | auto |
| `parent_permission_id` | Parent Permission Id | Parent permission that implies child permissions | string | parent | false | false | - | 10 | default | default | - | true | false | - | permissions | 2 | cascade | parent of | - | - | false | auto |
| `child_permission_id` | Child Permission Id | Child permission implied by parent | string | parent | false | false | - | 20 | default | default | - | true | false | - | permissions | 2 | cascade | child of | - | - | false | auto |

---

## Entity: permissions

System permissions that can be assigned to roles

| field_name | label | value |
|------------|-------|-------|
| table_name | Table Name | `permissions` |
| singular | Singular | permission |
| plural | Plural | permissions |
| singular_label | Singular Label | Permission |
| plural_label | Plural Label | Permissions |
| icon_url | Icon URL | - |
| description | Description | System permissions that can be assigned to roles |
| module_id | Module Id | 1 |
| view_permission | View Permission | `admin` |
| edit_permission | Edit Permission | `admin` |
| id_column | Id Column | `id` |
| label_column | Label Column | `permission_name` |
| managed | Managed | true |
| searchable | Searchable | true |
| is_child | Is Child | false |
| edit_mode | Edit Mode | auto |
| cube_mode | Cube Mode | auto |
| audit_log | Audit Log | true |

### Fields

| field_name | title | description | type | format | is_pk | is_nullable | default_value | field_order | input_type | width | ctype | is_core | searchable | enum_values | reference_table | precision | reference_delete_mode | relationship_label | singular_label_parent | plural_label_parent | unique_value | cube_type |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `id` 🔑 (id) | Id | - | integer | int32 | true | false | - | 1 | readonly | default | id | true | false | - | - | 2 | - | - | - | - | false | auto |
| `permission_name` (label) | Permission Name | Unique permission name | string | text | false | false | - | 10 | required | default | label | true | true | - | - | 2 | - | - | - | - | false | auto |
| `description` | Description | - | string | text | false | false | - | 20 | default | w | - | true | true | - | - | 2 | - | - | - | - | false | auto |
| `module_id` | Module Id | Module this permission belongs to | integer | reference | false | true | - | 30 | default | default | - | true | false | - | modules | 2 | clear | contains | - | - | false | auto |

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
| module_id | Module Id | 1 |
| view_permission | View Permission | `admin` |
| edit_permission | Edit Permission | `admin` |
| id_column | Id Column | `id` |
| label_column | Label Column | `id` |
| managed | Managed | true |
| searchable | Searchable | false |
| is_child | Is Child | true |
| edit_mode | Edit Mode | auto |
| cube_mode | Cube Mode | auto |
| audit_log | Audit Log | true |

### Fields

| field_name | title | description | type | format | is_pk | is_nullable | default_value | field_order | input_type | width | ctype | is_core | searchable | enum_values | reference_table | precision | reference_delete_mode | relationship_label | singular_label_parent | plural_label_parent | unique_value | cube_type |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `id` 🔑 (id) | Id | Generated identifier (role_id.permission_id) | string | text | true | false | - | 1 | readonly | default | id | true | false | - | - | 2 | - | - | - | - | false | auto |
| `role_id` | Role Id | Role this permission is granted to | string | parent | false | false | - | 10 | default | default | - | true | false | - | roles | 2 | cascade | has permissions | Permission | Permissions | false | auto |
| `permission_id` | Permission Id | Permission granted to the role | string | parent | false | false | - | 20 | default | default | - | true | false | - | permissions | 2 | cascade | granted to | Permission | Permissions | false | auto |
| `granted_at` | Granted At | Timestamp when permission was granted | string | date-time | false | true | - | 30 | disabled | default | - | true | false | - | - | 2 | - | - | - | - | false | auto |
| `granted_by` | Granted By | User who granted this permission | integer | reference | false | true | - | 40 | default | default | - | true | false | - | users | 2 | clear | has granted | - | - | false | auto |

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
| module_id | Module Id | 1 |
| view_permission | View Permission | `admin` |
| edit_permission | Edit Permission | `admin` |
| id_column | Id Column | `id` |
| label_column | Label Column | `role_name` |
| managed | Managed | true |
| searchable | Searchable | true |
| is_child | Is Child | false |
| edit_mode | Edit Mode | auto |
| cube_mode | Cube Mode | auto |
| audit_log | Audit Log | true |

### Fields

| field_name | title | description | type | format | is_pk | is_nullable | default_value | field_order | input_type | width | ctype | is_core | searchable | enum_values | reference_table | precision | reference_delete_mode | relationship_label | singular_label_parent | plural_label_parent | unique_value | cube_type |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `id` 🔑 (id) | Id | - | integer | int32 | true | false | - | 1 | readonly | default | id | true | false | - | - | 2 | - | - | - | - | false | auto |
| `role_name` (label) | Role Name | Unique role name | string | text | false | false | - | 10 | required | default | label | true | true | - | - | 2 | - | - | - | - | false | auto |
| `description` | Description | - | string | text | false | false | - | 20 | default | w | - | true | true | - | - | 2 | - | - | - | - | false | auto |
| `module_id` | Module Id | Module this role belongs to | integer | reference | false | true | - | 30 | default | default | - | true | false | - | modules | 2 | clear | contains | - | - | false | auto |

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
| module_id | Module Id | 1 |
| view_permission | View Permission | `admin` |
| edit_permission | Edit Permission | `admin` |
| id_column | Id Column | `id` |
| label_column | Label Column | `id` |
| managed | Managed | true |
| searchable | Searchable | false |
| is_child | Is Child | true |
| edit_mode | Edit Mode | auto |
| cube_mode | Cube Mode | auto |
| audit_log | Audit Log | true |

### Fields

| field_name | title | description | type | format | is_pk | is_nullable | default_value | field_order | input_type | width | ctype | is_core | searchable | enum_values | reference_table | precision | reference_delete_mode | relationship_label | singular_label_parent | plural_label_parent | unique_value | cube_type |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `id` 🔑 (id) | Id | Generated identifier (user_id.permission_id) | string | text | true | false | - | 1 | readonly | default | id | true | false | - | - | 2 | - | - | - | - | false | auto |
| `user_id` | User Id | User this permission is granted to | string | parent | false | false | - | 10 | required | default | - | true | false | - | users | 2 | cascade | has permissions | Permission | Permissions | false | auto |
| `permission_id` | Permission Id | Permission granted to the user | string | parent | false | false | - | 20 | required | default | - | true | false | - | permissions | 2 | cascade | granted to | User | Users | false | auto |
| `granted_at` | Granted At | Timestamp when permission was granted | string | date-time | false | true | - | 30 | disabled | default | - | true | false | - | - | 2 | - | - | - | - | false | auto |
| `granted_by` | Granted By | User who granted this permission | integer | reference | false | true | - | 40 | default | default | - | true | false | - | users | 2 | clear | has granted | - | - | false | auto |

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
| module_id | Module Id | 1 |
| view_permission | View Permission | `admin` |
| edit_permission | Edit Permission | `admin` |
| id_column | Id Column | `id` |
| label_column | Label Column | `id` |
| managed | Managed | true |
| searchable | Searchable | false |
| is_child | Is Child | true |
| edit_mode | Edit Mode | auto |
| cube_mode | Cube Mode | auto |
| audit_log | Audit Log | true |

### Fields

| field_name | title | description | type | format | is_pk | is_nullable | default_value | field_order | input_type | width | ctype | is_core | searchable | enum_values | reference_table | precision | reference_delete_mode | relationship_label | singular_label_parent | plural_label_parent | unique_value | cube_type |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `id` 🔑 (id) | Id | Generated identifier (user_id.role_id) | string | text | true | false | - | 1 | readonly | default | id | true | false | - | - | 2 | - | - | - | - | false | auto |
| `user_id` | User Id | User this role is assigned to | string | parent | false | false | - | 10 | required | default | - | true | false | - | users | 2 | cascade | has roles | Role | Roles | false | auto |
| `role_id` | Role Id | Role assigned to the user | string | parent | false | false | - | 20 | required | default | - | true | false | - | roles | 2 | cascade | assigned to | User | Users | false | auto |
| `assigned_at` | Assigned At | Timestamp when role was assigned | string | date-time | false | true | - | 30 | disabled | default | - | true | false | - | - | 2 | - | - | - | - | false | auto |
| `assigned_by` | Assigned By | User who assigned this role | integer | reference | false | true | - | 40 | default | default | - | true | false | - | users | 2 | clear | has assigned | - | - | false | auto |

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
| module_id | Module Id | 1 |
| view_permission | View Permission | `user:read` |
| edit_permission | Edit Permission | `user:manage` |
| id_column | Id Column | `id` |
| label_column | Label Column | `email` |
| managed | Managed | true |
| searchable | Searchable | true |
| is_child | Is Child | false |
| edit_mode | Edit Mode | auto |
| cube_mode | Cube Mode | auto |
| audit_log | Audit Log | true |

### Fields

| field_name | title | description | type | format | is_pk | is_nullable | default_value | field_order | input_type | width | ctype | is_core | searchable | enum_values | reference_table | precision | reference_delete_mode | relationship_label | singular_label_parent | plural_label_parent | unique_value | cube_type |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `id` 🔑 (id) | Id | - | integer | int32 | true | false | - | 1 | readonly | default | id | true | false | - | - | 2 | - | has | - | - | false | auto |
| `external_id` | External Id | External identifier from authentication provider | string | text | false | false | - | 10 | readonly | default | - | true | true | - | - | 2 | - | has | - | - | false | auto |
| `email` (label) | Email | - | string | email | false | false | - | 20 | default | default | label | true | true | - | - | 2 | - | has | - | - | false | auto |
| `display_name` | Display Name | - | string | text | false | false | - | 25 | default | default | - | true | true | - | - | 2 | - | has | - | - | false | auto |
| `is_disabled` | Is Disabled | - | boolean | boolean | false | false | - | 30 | default | default | - | true | false | - | - | 2 | - | has | - | - | false | auto |
| `settings` | Settings | User-specific settings and preferences | json | json | false | false | - | 35 | default | w | - | true | false | - | - | 2 | - | has | - | - | false | auto |
| `last_seen` | Last Seen | Timestamp when user was last active | string | date-time | false | true | - | 60 | readonly | default | - | true | false | - | - | 2 | - | has | - | - | false | auto |

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
| module_id | Module Id | 1 |
| view_permission | View Permission | `admin` |
| edit_permission | Edit Permission | `admin` |
| id_column | Id Column | `id` |
| label_column | Label Column | `label` |
| managed | Managed | true |
| searchable | Searchable | true |
| is_child | Is Child | true |
| edit_mode | Edit Mode | auto |
| cube_mode | Cube Mode | auto |
| audit_log | Audit Log | false |

### Fields

| field_name | title | description | type | format | is_pk | is_nullable | default_value | field_order | input_type | width | ctype | is_core | searchable | enum_values | reference_table | precision | reference_delete_mode | relationship_label | singular_label_parent | plural_label_parent | unique_value | cube_type |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `label` (label) | Webhook Receiver Log | - | string | text | false | false | - | 1 | required | default | label | true | true | - | - | 2 | - | has | - | - | false | auto |
| `id` 🔑 (id) | Id | - | integer | int32 | true | false | - | 1 | readonly | default | id | true | false | - | - | 2 | - | has | - | - | false | auto |
| `webhook_id` | Webhook Receiver | Parent webhook receiver this log belongs to | string | parent | false | false | - | 5 | default | default | - | false | false | - | webhook_receivers | 2 | cascade | has logs | - | - | false | auto |
| `webhook_receiver_id` | Webhook Receiver | Reference to webhook receiver configuration | integer | reference | false | true | - | 10 | default | default | - | false | false | - | webhook_receivers | 2 | clear | has logs | - | - | false | auto |
| `webhook_timestamp` | Webhook Timestamp | Timestamp from webhook source | string | date-time | false | true | - | 30 | default | default | - | false | false | - | - | 2 | - | - | - | - | false | auto |
| `received_timestamp` | Received Timestamp | Timestamp when webhook was received | string | date-time | false | true | CURRENT_TIMESTAMP | 40 | disabled | default | - | false | false | - | - | 2 | - | - | - | - | false | auto |
| `payload` | Payload | Webhook payload data | json | json | false | false | - | 50 | default | w | - | false | false | - | - | 2 | - | - | - | - | false | auto |
| `result` | Result | Processing result: 10=received, 20=processed, 90=failed | string | enum | false | false | 10 | 60 | default | default | - | false | false | ["10","20","90"] | - | 2 | - | - | - | - | false | auto |
| `error_message` | Error Message | Error message if processing failed | string | text | false | false | - | 70 | default | w | - | false | false | - | - | 2 | - | - | - | - | false | auto |

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
| module_id | Module Id | 1 |
| view_permission | View Permission | `admin` |
| edit_permission | Edit Permission | `admin` |
| id_column | Id Column | `id` |
| label_column | Label Column | `label` |
| managed | Managed | true |
| searchable | Searchable | true |
| is_child | Is Child | false |
| edit_mode | Edit Mode | auto |
| cube_mode | Cube Mode | auto |
| audit_log | Audit Log | false |

### Fields

| field_name | title | description | type | format | is_pk | is_nullable | default_value | field_order | input_type | width | ctype | is_core | searchable | enum_values | reference_table | precision | reference_delete_mode | relationship_label | singular_label_parent | plural_label_parent | unique_value | cube_type |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `label` (label) | Webhook Receiver | - | string | text | false | false | - | 1 | required | default | label | true | true | - | - | 2 | - | has | - | - | false | auto |
| `id` 🔑 (id) | Id | - | integer | int32 | true | false | - | 1 | readonly | default | id | true | false | - | - | 2 | - | has | - | - | false | auto |
| `table_name` | Table | Target table for webhook data | integer | reference | false | true | - | 10 | default | default | - | false | false | - | entities | 2 | cascade | has receivers | - | - | false | auto |
| `description` | Description | Description of webhook receiver purpose | string | text | false | false | - | 20 | default | w | - | false | false | - | - | 2 | - | - | - | - | false | auto |
| `auth_type` | Authentication Type | Type of authentication (none, hmac, or custom header) | string | enum | false | false | none | 30 | default | default | - | false | false | ["none","hmac","header"] | - | 2 | - | - | - | - | false | auto |
| `secret` | Secret | Secret for webhook authentication | string | text | false | false | - | 40 | default | default | - | false | false | - | - | 2 | - | - | - | - | false | auto |
| `header_name` | Header Name | Custom header name for authentication | string | text | false | false | - | 45 | default | default | - | false | false | - | - | 2 | - | - | - | - | false | auto |
| `header_value` | Header Value | Expected value for custom header authentication | string | text | false | false | - | 46 | default | default | - | false | false | - | - | 2 | - | - | - | - | false | auto |
| `jsonata` | JSONata Expression | Optional JSONata expression to transform incoming data | string | jsonata | false | false | - | 50 | default | w | - | false | false | - | - | 2 | - | - | - | - | false | auto |

---

