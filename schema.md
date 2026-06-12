# Database Schema Documentation

This document describes the database schema for the _core module.

**Generated:** 2026-06-12T14:31:51.557Z

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
| entity_type | Entity Type | unclassified |
| audit_log | Audit Log | false |
| computed_fields | Computed Fields |  |
| validation_rules | Validation Rules |  |
| select_rule | Select Rule | [object Object] |
| catalog_entity_code | Catalog Entity Code | - |
| canonical_owner_module | Canonical Owner Module | - |
| pattern_flags | Pattern Flags | [object Object] |
| catalog_entity_aliases | Catalog Entity Aliases |  |

### Fields

| field_name | format | title | description | type | is_pk | default_value | field_order | input_type | width | ctype | searchable | enum_values | precision | reference_table | reference_delete_mode | relationship_label | singular_label_parent | plural_label_parent | unique_value | cube_type | input_type_rule | catalog_field_code |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `id` 🔑 (id) | int64 | Id | - | integer | true | - | 1 | readonly | default | id | false | - | 2 | - | - | has | - | - | false | auto | [object Object] | - |
| `event_time` (core) | date-time | Event Time | When the DDL command completed | string | false | - | 10 | readonly | default | core | false | - | 2 | - | - | has | - | - | false | auto | [object Object] | - |
| `user_id` (core) | int32 | User Id | Internal user id from JWT context (0 when unavailable) | integer | false | - | 20 | readonly | default | core | false | - | 2 | - | - | has | - | - | false | auto | [object Object] | - |
| `command_tag` (label) | text | Command Tag | DDL command type (e.g. CREATE TABLE, ALTER TABLE) | string | false | - | 30 | readonly | default | label | true | - | 2 | - | - | has | - | - | false | auto | [object Object] | - |
| `object_type` (core) | text | Object Type | Type of database object affected | string | false | - | 40 | readonly | default | core | true | - | 2 | - | - | has | - | - | false | auto | [object Object] | - |
| `object_identity` (core) | text | Object Identity | Fully qualified name of the affected object | string | false | - | 50 | readonly | w | core | true | - | 2 | - | - | has | - | - | false | auto | [object Object] | - |
| `query_text` (core) | text | Query Text | The SQL statement that triggered the event | string | false | - | 60 | readonly | w | core | false | - | 2 | - | - | has | - | - | false | auto | [object Object] | - |

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
| entity_type | Entity Type | unclassified |
| audit_log | Audit Log | false |
| computed_fields | Computed Fields |  |
| validation_rules | Validation Rules |  |
| select_rule | Select Rule | [object Object] |
| catalog_entity_code | Catalog Entity Code | - |
| canonical_owner_module | Canonical Owner Module | - |
| pattern_flags | Pattern Flags | [object Object] |
| catalog_entity_aliases | Catalog Entity Aliases |  |

### Fields

| field_name | format | title | description | type | is_pk | default_value | field_order | input_type | width | ctype | searchable | enum_values | precision | reference_table | reference_delete_mode | relationship_label | singular_label_parent | plural_label_parent | unique_value | cube_type | input_type_rule | catalog_field_code |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `id` 🔑 (id) | int64 | Id | - | integer | true | - | 1 | readonly | default | id | false | - | 2 | - | - | has | - | - | false | auto | [object Object] | - |
| `record_id` (core) | uuid | Record Id | Deterministic UUID computed from table OID and primary key values | string | false | - | 10 | readonly | default | core | false | - | 2 | - | - | has | - | - | false | auto | [object Object] | - |
| `old_record_id` (core) | uuid | Old Record Id | Record id before update/delete | string | false | - | 20 | readonly | default | core | false | - | 2 | - | - | has | - | - | false | auto | [object Object] | - |
| `record_pk` (core) | text | Record PK | Primary key value of the affected record | string | false | - | 25 | readonly | default | core | true | - | 2 | - | - | has | - | - | false | auto | [object Object] | - |
| `op` (core) | text | Operation | DML operation type: INSERT, UPDATE, DELETE, TRUNCATE | string | false | - | 30 | readonly | default | core | false | - | 2 | - | - | has | - | - | false | auto | [object Object] | - |
| `ts` (core) | date-time | Timestamp | When the operation occurred | string | false | - | 40 | readonly | default | core | false | - | 2 | - | - | has | - | - | false | auto | [object Object] | - |
| `user_id` (core) | int32 | User Id | Internal user id from JWT context (0 when unavailable) | integer | false | - | 50 | readonly | default | core | false | - | 2 | - | - | has | - | - | false | auto | [object Object] | - |
| `table_oid` (core) | int32 | Table OID | PostgreSQL internal object identifier for the table | integer | false | - | 60 | readonly | default | core | false | - | 2 | - | - | has | - | - | false | auto | [object Object] | - |
| `table_schema` (core) | text | Table Schema | Schema containing the table | string | false | - | 70 | readonly | default | core | true | - | 2 | - | - | has | - | - | false | auto | [object Object] | - |
| `table_name` (label) | text | Table Name | Name of the affected table | string | false | - | 80 | readonly | default | label | true | - | 2 | - | - | has | - | - | false | auto | [object Object] | - |
| `record` (core) | json | Record | Full record after INSERT/UPDATE (JSONB) | json | false | - | 90 | readonly | w | core | false | - | 2 | - | - | has | - | - | false | auto | [object Object] | - |
| `old_record` (core) | json | Old Record | Previous record before UPDATE/DELETE (JSONB) | json | false | - | 100 | readonly | w | core | false | - | 2 | - | - | has | - | - | false | auto | [object Object] | - |

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
| entity_type | Entity Type | unclassified |
| audit_log | Audit Log | false |
| computed_fields | Computed Fields |  |
| validation_rules | Validation Rules |  |
| select_rule | Select Rule | [object Object] |
| catalog_entity_code | Catalog Entity Code | - |
| canonical_owner_module | Canonical Owner Module | - |
| pattern_flags | Pattern Flags | [object Object] |
| catalog_entity_aliases | Catalog Entity Aliases |  |

### Fields

| field_name | format | title | description | type | is_pk | default_value | field_order | input_type | width | ctype | searchable | enum_values | precision | reference_table | reference_delete_mode | relationship_label | singular_label_parent | plural_label_parent | unique_value | cube_type | input_type_rule | catalog_field_code |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `id` 🔑 (id) | int32 | Id | - | integer | true | - | 1 | readonly | default | id | false | - | 2 | - | - | has | - | - | false | auto | [object Object] | - |
| `label` (label) | text | Dashboard | - | string | false | - | 1 | required | default | label | true | - | 2 | - | - | has | - | - | false | auto | [object Object] | - |
| `config` | json | Configuration | Dashboard layout and widget configuration | json | false | - | 10 | default | w | - | false | - | 2 | - | - | has | - | - | false | auto | [object Object] | - |
| `position` | int32 | Position | Display order position | integer | false | 0 | 20 | default | default | - | false | - | 2 | - | - | has | - | - | false | auto | [object Object] | - |
| `module_id` | reference | Module | Module this dashboard belongs to | integer | false | - | 30 | default | default | - | false | - | 2 | modules | cascade | has | - | - | false | auto | [object Object] | - |
| `view_permission` | reference | View Permission | Permission required to view this dashboard | integer | false | - | 40 | default | default | - | false | - | 2 | permissions | clear | has | - | - | false | auto | [object Object] | - |

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
| entity_type | Entity Type | unclassified |
| audit_log | Audit Log | true |
| computed_fields | Computed Fields |  |
| validation_rules | Validation Rules | [object Object] |
| select_rule | Select Rule | [object Object] |
| catalog_entity_code | Catalog Entity Code | - |
| canonical_owner_module | Canonical Owner Module | - |
| pattern_flags | Pattern Flags | [object Object] |
| catalog_entity_aliases | Catalog Entity Aliases |  |

### Fields

| field_name | format | title | description | type | is_pk | default_value | field_order | input_type | width | ctype | searchable | enum_values | precision | reference_table | reference_delete_mode | relationship_label | singular_label_parent | plural_label_parent | unique_value | cube_type | input_type_rule | catalog_field_code |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `table_name` 🔑 (id) | text | Table Name | Physical table name in database | string | true | - | 1 | required | default | id | true | - | 2 | - | - | - | - | - | false | auto | [object Object] | - |
| `singular` (core) | text | Singular | Singular form of table name (auto-derived from table_name when blank) | string | false | - | 10 | default | default | core | true | - | 2 | - | - | - | - | - | false | auto | [object Object] | - |
| `plural` (core) | text | Plural | Plural form of table name, auto-assigned to table_name | string | false | - | 20 | readonly | default | core | true | - | 2 | - | - | - | - | - | false | auto | [object Object] | - |
| `singular_label` (label) | text | Singular Label | Human-readable singular label for UI/reports | string | false | - | 30 | default | default | label | true | - | 2 | - | - | - | - | - | false | auto | [object Object] | - |
| `plural_label` (core) | text | Plural Label | Human-readable plural label for UI/reports | string | false | - | 40 | default | default | core | true | - | 2 | - | - | - | - | - | false | auto | [object Object] | - |
| `icon_url` (core) | url | Icon URL | Optional URL or path to icon for this table | string | false | - | 50 | default | w | core | false | - | 2 | - | - | - | - | - | false | auto | [object Object] | - |
| `description` (core) | text | Description | - | string | false | - | 60 | default | w | core | true | - | 2 | - | - | - | - | - | false | auto | [object Object] | - |
| `module_id` (core) | reference | Module Id | - | integer | false | - | 70 | required | default | core | false | - | 2 | modules | clear | contains | - | - | false | auto | [object Object] | - |
| `view_permission` (core) | text | View Permission | Permission required to SELECT from this table | string | false | public:read | 80 | default | default | core | false | - | 2 | - | - | - | - | - | false | auto | [object Object] | - |
| `edit_permission` (core) | text | Edit Permission | Permission required to INSERT/UPDATE/DELETE from this table | string | false | admin | 90 | default | default | core | false | - | 2 | - | - | - | - | - | false | auto | [object Object] | - |
| `id_column` (core) | text | Id Column | Name of primary key column | string | false | id | 100 | default | default | core | false | - | 2 | - | - | - | - | - | false | auto | [object Object] | - |
| `label_column` (core) | text | Label Column | Name of label/display column | string | false | label | 110 | default | default | core | false | - | 2 | - | - | - | - | - | false | auto | [object Object] | - |
| `managed` (core) | boolean | Managed | When false, automatic DDL execution is disabled | boolean | false | true | 115 | default | default | core | false | - | 2 | - | - | - | - | - | false | auto | [object Object] | - |
| `searchable` (core) | boolean | Searchable | Whether table is included in full-text search (auto-computed) | boolean | false | - | 117 | disabled | default | core | false | - | 2 | - | - | - | - | - | false | auto | [object Object] | - |
| `is_child` (core) | boolean | Is Child | Whether table has any parent relationships (auto-computed) | boolean | false | - | 118 | disabled | default | core | false | - | 2 | - | - | - | - | - | false | auto | [object Object] | - |
| `edit_mode` (core) | enum | Edit Mode | UI edit mode for records of this table: auto, sidebar, modal, or page | string | false | auto | 119 | default | default | core | false | ["auto","sidebar","modal","page"] | 2 | - | - | - | - | - | false | auto | [object Object] | - |
| `cube_mode` (core) | enum | Cube Mode | Cube mode for OLAP cube generation | string | false | auto | 121 | default | default | core | false | ["disabled","auto"] | 2 | - | - | - | - | - | false | auto | [object Object] | - |
| `entity_type` (core) | enum | Entity Type | Data-class axis (operational_workflow|operational_record|catalog|junction|computed|unclassified). Write tier derives from it; unclassified = absent/derive-locally. | string | false | unclassified | 122 | readonly | default | core | false | ["operational_workflow","operational_record","catalog","junction","computed","unclassified"] | 2 | - | - | - | - | - | false | auto | [object Object] | - |
| `audit_log` (core) | boolean | Audit Log | When enabled, DML operations on this table are logged to the audit log | boolean | false | false | 122 | default | default | core | false | - | 2 | - | - | has | - | - | false | auto | [object Object] | - |
| `computed_fields` (core) | json | Computed Fields | JsonLogic derivations evaluated on every write | json | false | - | 123 | default | w | core | false | - | 2 | - | - | - | - | - | false | auto | [object Object] | - |
| `validation_rules` (core) | json | Validation Rules | JsonLogic invariants that must hold for the write to succeed | json | false | - | 124 | default | w | core | false | - | 2 | - | - | - | - | - | false | auto | [object Object] | - |
| `select_rule` (core) | json | Select Rule | JsonLogic rule for per-row FOR SELECT RLS policy | json | false | - | 125 | default | w | core | false | - | 2 | - | - | - | - | - | false | auto | [object Object] | - |
| `catalog_entity_code` (core) | text | Catalog Entity Code | Stable canonical identity this entity realizes (uber-model code, e.g. vendors); the rename/dialect/silo join key. table_name holds the deployed name. Empty = created outside the deploy pipeline. | string | false | - | 126 | default | default | core | false | - | 2 | - | - | - | - | - | false | auto | [object Object] | - |
| `canonical_owner_module` (core) | text | Canonical Owner Module | For an embedded-master placeholder, the slug of the module that should own this entity. Soft pointer (not an FK); empty when this module is the owner or the entity is local. | string | false | - | 127 | default | default | core | false | - | 2 | - | - | - | - | - | false | auto | [object Object] | - |
| `pattern_flags` (core) | json | Pattern Flags | Authored behaviour flags as a sparse JSON object of true-valued keys (e.g. personal_content, submit_lock, single_approver). Empty object = no special behaviour. | json | false | - | 128 | default | w | core | false | - | 2 | - | - | - | - | - | false | auto | [object Object] | - |
| `catalog_entity_aliases` (core) | json | Catalog Entity Aliases | Reuse/merge record: JSON array of {alias_code, source_domain, source_module, decided}. Append-only. Empty array = never a merge target. | json | false | - | 129 | default | w | core | false | - | 2 | - | - | - | - | - | false | auto | [object Object] | - |

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
| entity_type | Entity Type | unclassified |
| audit_log | Audit Log | true |
| computed_fields | Computed Fields |  |
| validation_rules | Validation Rules | [object Object] |
| select_rule | Select Rule | [object Object] |
| catalog_entity_code | Catalog Entity Code | - |
| canonical_owner_module | Canonical Owner Module | - |
| pattern_flags | Pattern Flags | [object Object] |
| catalog_entity_aliases | Catalog Entity Aliases |  |

### Fields

| field_name | format | title | description | type | is_pk | default_value | field_order | input_type | width | ctype | searchable | enum_values | precision | reference_table | reference_delete_mode | relationship_label | singular_label_parent | plural_label_parent | unique_value | cube_type | input_type_rule | catalog_field_code |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `id` 🔑 (id) | text | Id | Generated identifier (table_name.field_name) | string | true | - | 10 | readonly | default | id | false | - | 2 | - | - | - | - | - | false | auto | [object Object] | - |
| `table_name` (core) | parent | Table Name | - | string | false | - | 20 | default | default | core | true | - | 2 | entities | cascade | has fields | - | - | false | auto | [object Object] | - |
| `field_name` (core) | text | Field Name | Physical column name in database | string | false | - | 30 | required | default | core | true | - | 2 | - | - | - | - | - | false | auto | [object Object] | - |
| `format` (core) | enum | Format | JSON Schema format or primitive type | string | false | text | 40 | required | default | core | false | ["json","html","text","multiline","code","jsonata","reference","parent","enum","date","time","date-time","duration","uri","uri-reference","uri-template","url","email","hostname","ipv4","ipv6","regex","uuid","json-pointer","json-pointer-uri-fragment","relative-json-pointer","byte","int32","int64","float","double","password","binary","string","number","integer","boolean","object","array","null"] | 2 | - | - | - | - | - | false | auto | [object Object] | - |
| `title` (label) | text | Title | Human-readable display name for the field | string | false | - | 50 | required | default | label | true | - | 2 | - | - | - | - | - | false | auto | [object Object] | - |
| `description` (core) | text | Description | - | string | false | - | 60 | default | w | core | true | - | 2 | - | - | - | - | - | false | auto | [object Object] | - |
| `is_pk` (core) | boolean | Is Primary Key | - | boolean | false | - | 70 | default | default | core | false | - | 2 | - | - | - | - | - | false | auto | [object Object] | - |
| `default_value` (core) | text | Default Value | - | string | false | - | 90 | hidden | default | core | false | - | 2 | - | - | - | - | - | false | auto | [object Object] | - |
| `field_order` (core) | int32 | Field Order | - | integer | false | - | 100 | default | default | core | false | - | 2 | - | - | - | - | - | false | auto | [object Object] | - |
| `input_type` (core) | enum | Input Type | - | string | false | default | 110 | required | default | core | false | ["default","required","readonly","disabled","hidden"] | 2 | - | - | - | - | - | false | auto | [object Object] | - |
| `width` (core) | enum | Width | - | string | false | default | 120 | required | default | core | false | ["default","s","m","w"] | 2 | - | - | - | - | - | false | auto | [object Object] | - |
| `ctype` (core) | enum | Column Type | Special column type (id, label, etc.) | string | false | - | 130 | default | default | core | false | ["","id","label","audit","core"] | 2 | - | - | - | - | - | false | auto | [object Object] | - |
| `searchable` (core) | boolean | Searchable | Whether field is included in full-text search | boolean | false | - | 150 | hidden | default | core | false | - | 2 | - | - | - | - | - | false | auto | [object Object] | - |
| `enum_values` (core) | json | Enum Values | JSON array of allowed enum values | json | false | - | 160 | hidden | w | core | false | - | 2 | - | - | - | - | - | false | auto | [object Object] | - |
| `precision` (core) | int32 | Precision | Decimal scale used when generating NUMERIC columns for number formats | integer | false | 2 | 170 | hidden | default | core | false | - | 2 | - | - | - | - | - | false | auto | [object Object] | - |
| `reference_table` (core) | text | Reference Table | Table name for foreign key relationships | string | false | - | 180 | hidden | default | core | false | - | 2 | - | - | - | - | - | false | auto | [object Object] | - |
| `reference_delete_mode` (core) | enum | Reference Delete Mode | ON DELETE behavior: restrict, clear, or cascade | string | false | restrict | 190 | hidden | default | core | false | ["","restrict","clear","cascade"] | 2 | - | - | - | - | - | false | auto | [object Object] | - |
| `relationship_label` (core) | text | Relationship Label | Verb describing what the referenced entity does to/with this entity | string | false | has | 200 | hidden | default | core | false | - | 2 | - | - | - | - | - | false | auto | [object Object] | - |
| `singular_label_parent` (core) | text | Singular Label Parent | Custom singular label for the parent entity (overrides default when set) | string | false | - | 210 | hidden | default | core | false | - | 2 | - | - | - | - | - | false | auto | [object Object] | - |
| `plural_label_parent` (core) | text | Plural Label Parent | Custom plural label for the parent entity (overrides default when set) | string | false | - | 220 | hidden | default | core | false | - | 2 | - | - | - | - | - | false | auto | [object Object] | - |
| `unique_value` (core) | boolean | Unique Value | When TRUE, enforces a partial unique index (NULL and empty strings are not enforced) | boolean | false | - | 230 | hidden | default | core | false | - | 2 | - | - | - | - | - | false | auto | [object Object] | - |
| `cube_type` (core) | enum | Cube Type | - | string | false | auto | 240 | required | default | core | false | ["auto","dimension","measure","disabled"] | 2 | - | - | - | - | - | false | auto | [object Object] | - |
| `input_type_rule` (core) | json | Input Type Rule | JsonLogic condition for field visibility | json | false | - | 250 | default | w | core | false | - | 2 | - | - | - | - | - | false | auto | [object Object] | - |
| `catalog_field_code` (core) | text | Catalog Field Code | Stable design-time field identity (blueprint field name, e.g. status); the field-rename join key. Empty = created outside the deploy pipeline. | string | false | - | 260 | default | default | core | false | - | 2 | - | - | - | - | - | false | auto | [object Object] | - |

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
| entity_type | Entity Type | unclassified |
| audit_log | Audit Log | true |
| computed_fields | Computed Fields |  |
| validation_rules | Validation Rules | [object Object],[object Object] |
| select_rule | Select Rule | [object Object] |
| catalog_entity_code | Catalog Entity Code | - |
| canonical_owner_module | Canonical Owner Module | - |
| pattern_flags | Pattern Flags | [object Object] |
| catalog_entity_aliases | Catalog Entity Aliases |  |

### Fields

| field_name | format | title | description | type | is_pk | default_value | field_order | input_type | width | ctype | searchable | enum_values | precision | reference_table | reference_delete_mode | relationship_label | singular_label_parent | plural_label_parent | unique_value | cube_type | input_type_rule | catalog_field_code |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `id` 🔑 (id) | int32 | Id | - | integer | true | - | 1 | readonly | default | id | false | - | 2 | - | - | has | - | - | false | auto | [object Object] | - |
| `module_name` (label) | text | Module Name | Unique module name | string | false | - | 10 | required | default | label | true | - | 2 | - | - | has | - | - | false | auto | [object Object] | - |
| `description` (core) | text | Description | - | string | false | - | 20 | default | w | core | true | - | 2 | - | - | has | - | - | false | auto | [object Object] | - |
| `module_type` (core) | enum | Module Type | Module type: domain (normal) or master (promoted for sharing) | string | false | - | 25 | readonly | default | core | false | ["domain","master"] | 2 | - | - | has | - | - | false | auto | [object Object] | - |
| `view_permission` (core) | text | View Permission | Permission required to view this module | string | false | - | 30 | default | default | core | false | - | 2 | - | - | has | - | - | false | auto | [object Object] | - |
| `logo_url` (core) | url | Logo URL | URL or base64 data URI for module logo | string | false | - | 35 | default | w | core | false | - | 2 | - | - | has | - | - | false | auto | [object Object] | - |
| `logo_color` (core) | text | Logo Color | Hex color code for module logo | string | false | - | 36 | default | default | core | false | - | 2 | - | - | has | - | - | false | auto | [object Object] | - |
| `home_page` (core) | text | Home Page | Default home page path for module | string | false | - | 37 | default | default | core | false | - | 2 | - | - | has | - | - | false | auto | [object Object] | - |
| `module_slug` (core) | text | Module Slug | URL-safe unique identifier for module | string | false | - | 38 | required | default | core | false | - | 2 | - | - | has | - | - | false | auto | [object Object] | - |
| `manage_permission_id` (core) | reference | Manage Permission | - | integer | false | - | 39 | default | default | core | false | - | 2 | permissions | clear | has | - | - | false | auto | [object Object] | - |
| `admin_permission_id` (core) | reference | Admin Permission | - | integer | false | - | 40 | default | default | core | false | - | 2 | permissions | clear | has | - | - | false | auto | [object Object] | - |
| `default_viewer_role_id` (core) | reference | Default Viewer Role | - | integer | false | - | 41 | default | default | core | false | - | 2 | roles | clear | has | - | - | false | auto | [object Object] | - |
| `default_manager_role_id` (core) | reference | Default Manager Role | - | integer | false | - | 42 | default | default | core | false | - | 2 | roles | clear | has | - | - | false | auto | [object Object] | - |
| `default_admin_role_id` (core) | reference | Default Admin Role | - | integer | false | - | 43 | default | default | core | false | - | 2 | roles | clear | has | - | - | false | auto | [object Object] | - |
| `catalog_module_code` (core) | text | Catalog Module Code | Catalog blueprint this module was provisioned/cloned from; also the domain axis (non-unique). Empty = greenfield. | string | false | - | 44 | default | default | core | false | - | 2 | - | - | has | - | - | false | auto | [object Object] | - |
| `settings` (core) | json | Settings | Module-specific settings and configuration | json | false | - | 50 | default | w | core | false | - | 2 | - | - | has | - | - | false | auto | [object Object] | - |
| `dashboard_config` (core) | json | Dashboard Configuration | - | json | false | - | 60 | default | w | core | false | - | 2 | - | - | has | - | - | false | auto | [object Object] | - |

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
| entity_type | Entity Type | unclassified |
| audit_log | Audit Log | true |
| computed_fields | Computed Fields |  |
| validation_rules | Validation Rules | [object Object] |
| select_rule | Select Rule | [object Object] |
| catalog_entity_code | Catalog Entity Code | - |
| canonical_owner_module | Canonical Owner Module | - |
| pattern_flags | Pattern Flags | [object Object] |
| catalog_entity_aliases | Catalog Entity Aliases |  |

### Fields

| field_name | format | title | description | type | is_pk | default_value | field_order | input_type | width | ctype | searchable | enum_values | precision | reference_table | reference_delete_mode | relationship_label | singular_label_parent | plural_label_parent | unique_value | cube_type | input_type_rule | catalog_field_code |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `id` 🔑 (id) | text | Id | Generated identifier (including_permission_id.included_permission_id) | string | true | - | 1 | readonly | default | id | false | - | 2 | - | - | - | - | - | false | auto | [object Object] | - |
| `including_permission_id` (core) | parent | Including Permission Id | The broader permission that includes other permissions | string | false | - | 10 | default | default | core | false | - | 2 | permissions | cascade | includes | Includes | Includes | false | auto | [object Object] | - |
| `included_permission_id` (core) | parent | Included Permission Id | The narrower permission that is included by the broader one | string | false | - | 20 | default | default | core | false | - | 2 | permissions | cascade | included in | Included in | Included in | false | auto | [object Object] | - |
| `origin` (core) | enum | Origin | How this hierarchy entry was created | string | false | - | 25 | readonly | default | core | false | ["system","model","model_master","user"] | 2 | - | - | - | - | - | false | auto | [object Object] | - |

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
| entity_type | Entity Type | unclassified |
| audit_log | Audit Log | true |
| computed_fields | Computed Fields |  |
| validation_rules | Validation Rules |  |
| select_rule | Select Rule | [object Object] |
| catalog_entity_code | Catalog Entity Code | - |
| canonical_owner_module | Canonical Owner Module | - |
| pattern_flags | Pattern Flags | [object Object] |
| catalog_entity_aliases | Catalog Entity Aliases |  |

### Fields

| field_name | format | title | description | type | is_pk | default_value | field_order | input_type | width | ctype | searchable | enum_values | precision | reference_table | reference_delete_mode | relationship_label | singular_label_parent | plural_label_parent | unique_value | cube_type | input_type_rule | catalog_field_code |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `id` 🔑 (id) | int32 | Id | - | integer | true | - | 1 | readonly | default | id | false | - | 2 | - | - | - | - | - | false | auto | [object Object] | - |
| `permission_name` (label) | text | Permission Name | Unique permission name | string | false | - | 10 | required | default | label | true | - | 2 | - | - | - | - | - | true | auto | [object Object] | - |
| `description` (core) | multiline | Description | - | string | false | - | 20 | default | w | core | true | - | 2 | - | - | - | - | - | false | auto | [object Object] | - |
| `module_id` (core) | reference | Module Id | Module this permission belongs to | integer | false | - | 30 | default | default | core | false | - | 2 | modules | clear | contains | - | - | false | auto | [object Object] | - |

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
| module_id | Module Id | 1 |
| view_permission | View Permission | `admin` |
| edit_permission | Edit Permission | `admin` |
| id_column | Id Column | `id` |
| label_column | Label Column | `name` |
| managed | Managed | true |
| searchable | Searchable | true |
| is_child | Is Child | true |
| edit_mode | Edit Mode | auto |
| cube_mode | Cube Mode | auto |
| entity_type | Entity Type | unclassified |
| audit_log | Audit Log | false |
| computed_fields | Computed Fields | [object Object] |
| validation_rules | Validation Rules |  |
| select_rule | Select Rule | [object Object] |
| catalog_entity_code | Catalog Entity Code | - |
| canonical_owner_module | Canonical Owner Module | - |
| pattern_flags | Pattern Flags | [object Object] |
| catalog_entity_aliases | Catalog Entity Aliases |  |

### Fields

| field_name | format | title | description | type | is_pk | default_value | field_order | input_type | width | ctype | searchable | enum_values | precision | reference_table | reference_delete_mode | relationship_label | singular_label_parent | plural_label_parent | unique_value | cube_type | input_type_rule | catalog_field_code |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `id` 🔑 (id) | int32 | Id | - | integer | true | - | 1 | readonly | default | id | false | - | 2 | - | - | has | - | - | false | auto | [object Object] | - |
| `name` (label) | text | Name | Display label — mirrors the gate kind (computed) | string | false | - | 5 | readonly | default | label | true | - | 2 | - | - | has | - | - | false | auto | [object Object] | - |
| `process_id` | parent | Process | The governed process | string | false | - | 10 | required | default | - | false | - | 2 | processes | cascade | has | - | - | false | auto | [object Object] | - |
| `entity` | text | Entity | Governed table name (mirrors entities.table_name) | string | false | - | 20 | required | default | - | false | - | 2 | - | - | has | - | - | false | auto | [object Object] | - |
| `gate_kind` | enum | Gate Kind | Type of governance gate | string | false | - | 30 | required | default | - | false | ["approval","submit_lock","ownership","create","transition"] | 2 | - | - | has | - | - | false | auto | [object Object] | - |
| `to_state` | text | To State | Target lifecycle state (empty for non-state-targeted gates) | string | false | - | 40 | default | default | - | false | - | 2 | - | - | has | - | - | false | auto | [object Object] | - |
| `state_column` | text | State Column | Column that holds the lifecycle state in the governed table | string | false | status | 50 | default | default | - | false | - | 2 | - | - | has | - | - | false | auto | [object Object] | - |
| `emits_events` | boolean | Emits Events | When TRUE, entering to_state inserts raci_events | boolean | false | - | 60 | default | default | - | false | - | 2 | - | - | has | - | - | false | auto | [object Object] | - |

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
| module_id | Module Id | 1 |
| view_permission | View Permission | `admin` |
| edit_permission | Edit Permission | `admin` |
| id_column | Id Column | `id` |
| label_column | Label Column | `name` |
| managed | Managed | true |
| searchable | Searchable | true |
| is_child | Is Child | false |
| edit_mode | Edit Mode | auto |
| cube_mode | Cube Mode | auto |
| entity_type | Entity Type | unclassified |
| audit_log | Audit Log | false |
| computed_fields | Computed Fields |  |
| validation_rules | Validation Rules |  |
| select_rule | Select Rule | [object Object] |
| catalog_entity_code | Catalog Entity Code | - |
| canonical_owner_module | Canonical Owner Module | - |
| pattern_flags | Pattern Flags | [object Object] |
| catalog_entity_aliases | Catalog Entity Aliases |  |

### Fields

| field_name | format | title | description | type | is_pk | default_value | field_order | input_type | width | ctype | searchable | enum_values | precision | reference_table | reference_delete_mode | relationship_label | singular_label_parent | plural_label_parent | unique_value | cube_type | input_type_rule | catalog_field_code |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `id` 🔑 (id) | int32 | Id | - | integer | true | - | 1 | readonly | default | id | false | - | 2 | - | - | has | - | - | false | auto | [object Object] | - |
| `name` (label) | text | Name | Display name of the process | string | false | - | 10 | required | default | label | true | - | 2 | - | - | has | - | - | false | auto | [object Object] | - |
| `module_id` | reference | Module | Owning module | integer | false | - | 20 | default | default | - | false | - | 2 | modules | clear | has | - | - | false | auto | [object Object] | - |
| `process_key` | text | Process Key | Stable snake_case identifier, unique within module | string | false | - | 30 | required | default | - | false | - | 2 | - | - | has | - | - | false | auto | [object Object] | - |
| `description` | multiline | Description | Detailed description of the process | string | false | - | 40 | default | default | - | false | - | 2 | - | - | has | - | - | false | auto | [object Object] | - |
| `ordering` | integer | Ordering | Optional display ordering | integer | false | - | 50 | default | default | - | false | - | 2 | - | - | has | - | - | false | auto | [object Object] | - |

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
| module_id | Module Id | 1 |
| view_permission | View Permission | `admin` |
| edit_permission | Edit Permission | `admin` |
| id_column | Id Column | `id` |
| label_column | Label Column | `event_name` |
| managed | Managed | true |
| searchable | Searchable | true |
| is_child | Is Child | true |
| edit_mode | Edit Mode | auto |
| cube_mode | Cube Mode | auto |
| entity_type | Entity Type | unclassified |
| audit_log | Audit Log | false |
| computed_fields | Computed Fields |  |
| validation_rules | Validation Rules |  |
| select_rule | Select Rule | [object Object] |
| catalog_entity_code | Catalog Entity Code | - |
| canonical_owner_module | Canonical Owner Module | - |
| pattern_flags | Pattern Flags | [object Object] |
| catalog_entity_aliases | Catalog Entity Aliases |  |

### Fields

| field_name | format | title | description | type | is_pk | default_value | field_order | input_type | width | ctype | searchable | enum_values | precision | reference_table | reference_delete_mode | relationship_label | singular_label_parent | plural_label_parent | unique_value | cube_type | input_type_rule | catalog_field_code |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `event_name` (label) | text | Queue Table Event | - | string | false | - | 1 | required | default | label | true | - | 2 | - | - | has | - | - | false | auto | [object Object] | - |
| `id` 🔑 (id) | int32 | Id | - | integer | true | - | 1 | readonly | default | id | false | - | 2 | - | - | has | - | - | false | auto | [object Object] | - |
| `queue_id` | parent | Queue | Parent queue this event belongs to | string | false | - | 5 | default | default | - | false | - | 2 | queues | cascade | has events | - | - | false | auto | [object Object] | - |
| `table_name` | reference | Table | Table whose DML events are captured | integer | false | - | 10 | required | default | - | false | - | 2 | entities | cascade | has queue events | - | - | true | auto | [object Object] | - |
| `event_handler` | enum | Event Handler | Which DML operations trigger a queue message | string | false | - | 20 | required | default | - | false | ["insert","update","upsert","delete","change"] | 2 | - | - | - | - | - | false | auto | [object Object] | - |

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
| module_id | Module Id | 1 |
| view_permission | View Permission | `admin` |
| edit_permission | Edit Permission | `admin` |
| id_column | Id Column | `id` |
| label_column | Label Column | `queue_name` |
| managed | Managed | true |
| searchable | Searchable | true |
| is_child | Is Child | false |
| edit_mode | Edit Mode | auto |
| cube_mode | Cube Mode | auto |
| entity_type | Entity Type | unclassified |
| audit_log | Audit Log | false |
| computed_fields | Computed Fields |  |
| validation_rules | Validation Rules |  |
| select_rule | Select Rule | [object Object] |
| catalog_entity_code | Catalog Entity Code | - |
| canonical_owner_module | Canonical Owner Module | - |
| pattern_flags | Pattern Flags | [object Object] |
| catalog_entity_aliases | Catalog Entity Aliases |  |

### Fields

| field_name | format | title | description | type | is_pk | default_value | field_order | input_type | width | ctype | searchable | enum_values | precision | reference_table | reference_delete_mode | relationship_label | singular_label_parent | plural_label_parent | unique_value | cube_type | input_type_rule | catalog_field_code |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `id` 🔑 (id) | int32 | Id | - | integer | true | - | 1 | readonly | default | id | false | - | 2 | - | - | has | - | - | false | auto | [object Object] | - |
| `queue_name` (label) | text | Queue | - | string | false | - | 1 | required | default | label | true | - | 2 | - | - | has | - | - | true | auto | [object Object] | - |

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
| module_id | Module Id | 1 |
| view_permission | View Permission | `admin` |
| edit_permission | Edit Permission | `admin` |
| id_column | Id Column | `id` |
| label_column | Label Column | `name` |
| managed | Managed | true |
| searchable | Searchable | true |
| is_child | Is Child | true |
| edit_mode | Edit Mode | auto |
| cube_mode | Cube Mode | auto |
| entity_type | Entity Type | unclassified |
| audit_log | Audit Log | false |
| computed_fields | Computed Fields | [object Object] |
| validation_rules | Validation Rules |  |
| select_rule | Select Rule | [object Object] |
| catalog_entity_code | Catalog Entity Code | - |
| canonical_owner_module | Canonical Owner Module | - |
| pattern_flags | Pattern Flags | [object Object] |
| catalog_entity_aliases | Catalog Entity Aliases |  |

### Fields

| field_name | format | title | description | type | is_pk | default_value | field_order | input_type | width | ctype | searchable | enum_values | precision | reference_table | reference_delete_mode | relationship_label | singular_label_parent | plural_label_parent | unique_value | cube_type | input_type_rule | catalog_field_code |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `id` 🔑 (id) | int32 | Id | - | integer | true | - | 1 | readonly | default | id | false | - | 2 | - | - | has | - | - | false | auto | [object Object] | - |
| `name` (label) | text | Name | Display label — mirrors the RACI letter (computed) | string | false | - | 5 | readonly | default | label | true | - | 2 | - | - | has | - | - | false | auto | [object Object] | - |
| `process_id` | parent | Process | The governed process | string | false | - | 10 | required | default | - | false | - | 2 | processes | cascade | has | - | - | false | auto | [object Object] | - |
| `role_id` | reference | Role | The persona role assigned this letter | integer | false | - | 20 | required | default | - | false | - | 2 | roles | cascade | has | - | - | false | auto | [object Object] | - |
| `raci` | enum | RACI | Responsibility letter | string | false | - | 30 | required | default | - | false | ["responsible","accountable","consulted","informed"] | 2 | - | - | has | - | - | false | auto | [object Object] | - |
| `consult_mode` | enum | Consult Mode | Consultation mode (only for raci=consulted) | string | false | read | 40 | default | default | - | false | ["read","notify","block"] | 2 | - | - | has | - | - | false | auto | [object Object] | - |
| `origin` | enum | Origin | How this row was created | string | false | user | 50 | default | default | - | false | ["system","user"] | 2 | - | - | has | - | - | false | auto | [object Object] | - |

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
| module_id | Module Id | 1 |
| view_permission | View Permission | `admin` |
| edit_permission | Edit Permission | `admin` |
| id_column | Id Column | `id` |
| label_column | Label Column | `record_id` |
| managed | Managed | true |
| searchable | Searchable | true |
| is_child | Is Child | true |
| edit_mode | Edit Mode | auto |
| cube_mode | Cube Mode | auto |
| entity_type | Entity Type | unclassified |
| audit_log | Audit Log | false |
| computed_fields | Computed Fields |  |
| validation_rules | Validation Rules |  |
| select_rule | Select Rule | [object Object] |
| catalog_entity_code | Catalog Entity Code | - |
| canonical_owner_module | Canonical Owner Module | - |
| pattern_flags | Pattern Flags | [object Object] |
| catalog_entity_aliases | Catalog Entity Aliases |  |

### Fields

| field_name | format | title | description | type | is_pk | default_value | field_order | input_type | width | ctype | searchable | enum_values | precision | reference_table | reference_delete_mode | relationship_label | singular_label_parent | plural_label_parent | unique_value | cube_type | input_type_rule | catalog_field_code |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `id` 🔑 (id) | int32 | Id | - | integer | true | - | 1 | readonly | default | id | false | - | 2 | - | - | has | - | - | false | auto | [object Object] | - |
| `process_id` | parent | Process | The governed process | string | false | - | 10 | required | default | - | false | - | 2 | processes | cascade | has | - | - | false | auto | [object Object] | - |
| `entity` | text | Entity | Governed table name | string | false | - | 20 | required | default | - | false | - | 2 | - | - | has | - | - | false | auto | [object Object] | - |
| `record_id` (label) | text | Record Id | Governed record PK (text for non-integer PKs) | string | false | - | 30 | required | default | label | true | - | 2 | - | - | has | - | - | false | auto | [object Object] | - |
| `raci` | enum | RACI | consulted or informed | string | false | - | 40 | required | default | - | false | ["consulted","informed"] | 2 | - | - | has | - | - | false | auto | [object Object] | - |
| `target_role_id` | reference | Target Role | Role to be notified or consulted | integer | false | - | 50 | required | default | - | false | - | 2 | roles | cascade | has | - | - | false | auto | [object Object] | - |
| `status` | enum | Status | pending → sent → acted | string | false | pending | 60 | required | default | - | false | ["pending","sent","acted"] | 2 | - | - | has | - | - | false | auto | [object Object] | - |
| `acted_at` | date-time | Acted At | When the consulted party responded (NULL until acted) | string | false | - | 70 | disabled | default | - | false | - | 2 | - | - | has | - | - | false | auto | [object Object] | - |

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
| entity_type | Entity Type | unclassified |
| audit_log | Audit Log | true |
| computed_fields | Computed Fields |  |
| validation_rules | Validation Rules |  |
| select_rule | Select Rule | [object Object] |
| catalog_entity_code | Catalog Entity Code | - |
| canonical_owner_module | Canonical Owner Module | - |
| pattern_flags | Pattern Flags | [object Object] |
| catalog_entity_aliases | Catalog Entity Aliases |  |

### Fields

| field_name | format | title | description | type | is_pk | default_value | field_order | input_type | width | ctype | searchable | enum_values | precision | reference_table | reference_delete_mode | relationship_label | singular_label_parent | plural_label_parent | unique_value | cube_type | input_type_rule | catalog_field_code |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `id` 🔑 (id) | text | Id | Generated identifier (role_id.permission_id) | string | true | - | 1 | readonly | default | id | false | - | 2 | - | - | - | - | - | false | auto | [object Object] | - |
| `role_id` (core) | parent | Role Id | Role this permission is granted to | string | false | - | 10 | default | default | core | false | - | 2 | roles | cascade | has permissions | Permission | Permissions | false | auto | [object Object] | - |
| `permission_id` (core) | parent | Permission Id | Permission granted to the role | string | false | - | 20 | default | default | core | false | - | 2 | permissions | cascade | granted to | Permission | Permissions | false | auto | [object Object] | - |
| `granted_at` (core) | date-time | Granted At | Timestamp when permission was granted | string | false | - | 30 | disabled | default | core | false | - | 2 | - | - | - | - | - | false | auto | [object Object] | - |
| `granted_by` (core) | reference | Granted By | User who granted this permission | integer | false | - | 40 | default | default | core | false | - | 2 | users | clear | has granted | - | - | false | auto | [object Object] | - |

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
| entity_type | Entity Type | unclassified |
| audit_log | Audit Log | true |
| computed_fields | Computed Fields |  |
| validation_rules | Validation Rules | [object Object],[object Object] |
| select_rule | Select Rule | [object Object] |
| catalog_entity_code | Catalog Entity Code | - |
| canonical_owner_module | Canonical Owner Module | - |
| pattern_flags | Pattern Flags | [object Object] |
| catalog_entity_aliases | Catalog Entity Aliases |  |

### Fields

| field_name | format | title | description | type | is_pk | default_value | field_order | input_type | width | ctype | searchable | enum_values | precision | reference_table | reference_delete_mode | relationship_label | singular_label_parent | plural_label_parent | unique_value | cube_type | input_type_rule | catalog_field_code |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `id` 🔑 (id) | int32 | Id | - | integer | true | - | 1 | readonly | default | id | false | - | 2 | - | - | - | - | - | false | auto | [object Object] | - |
| `role_name` (label) | text | Role Name | Unique role name | string | false | - | 10 | required | default | label | true | - | 2 | - | - | - | - | - | false | auto | [object Object] | - |
| `slug` (core) | text | Slug | Snake_case unique identifier for role, auto-generated from role_name | string | false | - | 15 | readonly | default | core | false | - | 2 | - | - | - | - | - | true | auto | [object Object] | - |
| `catalog_role_code` (core) | text | Catalog Role Code | Stable catalog persona/role this role was provisioned from (lineage; non-unique). Empty = created outside the pipeline. | string | false | - | 16 | default | default | core | false | - | 2 | - | - | - | - | - | false | auto | [object Object] | - |
| `description` (core) | multiline | Description | - | string | false | - | 20 | default | w | core | true | - | 2 | - | - | - | - | - | false | auto | [object Object] | - |
| `origin` (core) | enum | Origin | - | string | false | - | 25 | readonly | default | core | false | ["system","model","model_master","user"] | 2 | - | - | - | - | - | false | auto | [object Object] | - |
| `module_id` (core) | reference | Module Id | Module this role belongs to | integer | false | - | 30 | default | default | core | false | - | 2 | modules | clear | contains | - | - | false | auto | [object Object] | - |

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
| entity_type | Entity Type | unclassified |
| audit_log | Audit Log | true |
| computed_fields | Computed Fields |  |
| validation_rules | Validation Rules |  |
| select_rule | Select Rule | [object Object] |
| catalog_entity_code | Catalog Entity Code | - |
| canonical_owner_module | Canonical Owner Module | - |
| pattern_flags | Pattern Flags | [object Object] |
| catalog_entity_aliases | Catalog Entity Aliases |  |

### Fields

| field_name | format | title | description | type | is_pk | default_value | field_order | input_type | width | ctype | searchable | enum_values | precision | reference_table | reference_delete_mode | relationship_label | singular_label_parent | plural_label_parent | unique_value | cube_type | input_type_rule | catalog_field_code |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `id` 🔑 (id) | text | Id | Generated identifier (user_id.permission_id) | string | true | - | 1 | readonly | default | id | false | - | 2 | - | - | - | - | - | false | auto | [object Object] | - |
| `user_id` (core) | parent | User Id | User this permission is granted to | string | false | - | 10 | required | default | core | false | - | 2 | users | cascade | has permissions | Permission | Permissions | false | auto | [object Object] | - |
| `permission_id` (core) | parent | Permission Id | Permission granted to the user | string | false | - | 20 | required | default | core | false | - | 2 | permissions | cascade | granted to | User | Users | false | auto | [object Object] | - |
| `granted_at` (core) | date-time | Granted At | Timestamp when permission was granted | string | false | - | 30 | disabled | default | core | false | - | 2 | - | - | - | - | - | false | auto | [object Object] | - |
| `granted_by` (core) | reference | Granted By | User who granted this permission | integer | false | - | 40 | default | default | core | false | - | 2 | users | clear | has granted | - | - | false | auto | [object Object] | - |

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
| entity_type | Entity Type | unclassified |
| audit_log | Audit Log | true |
| computed_fields | Computed Fields |  |
| validation_rules | Validation Rules |  |
| select_rule | Select Rule | [object Object] |
| catalog_entity_code | Catalog Entity Code | - |
| canonical_owner_module | Canonical Owner Module | - |
| pattern_flags | Pattern Flags | [object Object] |
| catalog_entity_aliases | Catalog Entity Aliases |  |

### Fields

| field_name | format | title | description | type | is_pk | default_value | field_order | input_type | width | ctype | searchable | enum_values | precision | reference_table | reference_delete_mode | relationship_label | singular_label_parent | plural_label_parent | unique_value | cube_type | input_type_rule | catalog_field_code |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `id` 🔑 (id) | text | Id | Generated identifier (user_id.role_id) | string | true | - | 1 | readonly | default | id | false | - | 2 | - | - | - | - | - | false | auto | [object Object] | - |
| `user_id` (core) | parent | User Id | User this role is assigned to | string | false | - | 10 | required | default | core | false | - | 2 | users | cascade | has roles | Role | Roles | false | auto | [object Object] | - |
| `role_id` (core) | parent | Role Id | Role assigned to the user | string | false | - | 20 | required | default | core | false | - | 2 | roles | cascade | assigned to | User | Users | false | auto | [object Object] | - |
| `assigned_at` (core) | date-time | Assigned At | Timestamp when role was assigned | string | false | - | 30 | disabled | default | core | false | - | 2 | - | - | - | - | - | false | auto | [object Object] | - |
| `assigned_by` (core) | reference | Assigned By | User who assigned this role | integer | false | - | 40 | default | default | core | false | - | 2 | users | clear | has assigned | - | - | false | auto | [object Object] | - |

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
| entity_type | Entity Type | unclassified |
| audit_log | Audit Log | true |
| computed_fields | Computed Fields |  |
| validation_rules | Validation Rules |  |
| select_rule | Select Rule | [object Object] |
| catalog_entity_code | Catalog Entity Code | - |
| canonical_owner_module | Canonical Owner Module | - |
| pattern_flags | Pattern Flags | [object Object] |
| catalog_entity_aliases | Catalog Entity Aliases |  |

### Fields

| field_name | format | title | description | type | is_pk | default_value | field_order | input_type | width | ctype | searchable | enum_values | precision | reference_table | reference_delete_mode | relationship_label | singular_label_parent | plural_label_parent | unique_value | cube_type | input_type_rule | catalog_field_code |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `id` 🔑 (id) | int32 | Id | - | integer | true | - | 1 | readonly | default | id | false | - | 2 | - | - | has | - | - | false | auto | [object Object] | - |
| `external_id` (core) | text | External Id | External identifier from authentication provider | string | false | - | 10 | readonly | default | core | true | - | 2 | - | - | has | - | - | true | auto | [object Object] | - |
| `email` (label) | email | Email | - | string | false | - | 20 | default | default | label | true | - | 2 | - | - | has | - | - | false | auto | [object Object] | - |
| `first_name` (core) | text | First Name | First name from JWT given_name claim | string | false | - | 22 | default | default | core | true | - | 2 | - | - | has | - | - | false | auto | [object Object] | - |
| `last_name` (core) | text | Last Name | Last name from JWT family_name claim | string | false | - | 23 | default | default | core | true | - | 2 | - | - | has | - | - | false | auto | [object Object] | - |
| `display_name` (core) | text | Display Name | - | string | false | - | 25 | default | default | core | true | - | 2 | - | - | has | - | - | false | auto | [object Object] | - |
| `is_disabled` (core) | boolean | Is Disabled | - | boolean | false | - | 30 | default | default | core | false | - | 2 | - | - | has | - | - | false | auto | [object Object] | - |
| `settings` (core) | json | Settings | User-specific settings and preferences | json | false | - | 35 | default | w | core | false | - | 2 | - | - | has | - | - | false | auto | [object Object] | - |
| `last_seen` (core) | date-time | Last Seen | Timestamp when user was last active | string | false | - | 60 | readonly | default | core | false | - | 2 | - | - | has | - | - | false | auto | [object Object] | - |
| `is_agent` | boolean | Is Agent | When TRUE this user is a service principal (agent) | boolean | false | false | 100 | default | default | - | false | - | 2 | - | - | has | - | - | false | auto | [object Object] | - |

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
| entity_type | Entity Type | unclassified |
| audit_log | Audit Log | false |
| computed_fields | Computed Fields |  |
| validation_rules | Validation Rules |  |
| select_rule | Select Rule | [object Object] |
| catalog_entity_code | Catalog Entity Code | - |
| canonical_owner_module | Canonical Owner Module | - |
| pattern_flags | Pattern Flags | [object Object] |
| catalog_entity_aliases | Catalog Entity Aliases |  |

### Fields

| field_name | format | title | description | type | is_pk | default_value | field_order | input_type | width | ctype | searchable | enum_values | precision | reference_table | reference_delete_mode | relationship_label | singular_label_parent | plural_label_parent | unique_value | cube_type | input_type_rule | catalog_field_code |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `label` (label) | text | Webhook Receiver Log | - | string | false | - | 1 | required | default | label | true | - | 2 | - | - | has | - | - | false | auto | [object Object] | - |
| `id` 🔑 (id) | int32 | Id | - | integer | true | - | 1 | readonly | default | id | false | - | 2 | - | - | has | - | - | false | auto | [object Object] | - |
| `webhook_id` | parent | Webhook Receiver | Parent webhook receiver this log belongs to | string | false | - | 5 | default | default | - | false | - | 2 | webhook_receivers | cascade | has logs | - | - | false | auto | [object Object] | - |
| `webhook_receiver_id` | reference | Webhook Receiver | Reference to webhook receiver configuration | integer | false | - | 10 | default | default | - | false | - | 2 | webhook_receivers | clear | has logs | - | - | false | auto | [object Object] | - |
| `webhook_timestamp` | date-time | Webhook Timestamp | Timestamp from webhook source | string | false | - | 30 | default | default | - | false | - | 2 | - | - | - | - | - | false | auto | [object Object] | - |
| `received_timestamp` | date-time | Received Timestamp | Timestamp when webhook was received | string | false | CURRENT_TIMESTAMP | 40 | disabled | default | - | false | - | 2 | - | - | - | - | - | false | auto | [object Object] | - |
| `payload` | json | Payload | Webhook payload data | json | false | - | 50 | default | w | - | false | - | 2 | - | - | - | - | - | false | auto | [object Object] | - |
| `result` | enum | Result | Processing result: 10=received, 20=processed, 90=failed | string | false | 10 | 60 | default | default | - | false | ["10","20","90"] | 2 | - | - | - | - | - | false | auto | [object Object] | - |
| `error_message` | text | Error Message | Error message if processing failed | string | false | - | 70 | default | w | - | false | - | 2 | - | - | - | - | - | false | auto | [object Object] | - |

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
| entity_type | Entity Type | unclassified |
| audit_log | Audit Log | false |
| computed_fields | Computed Fields |  |
| validation_rules | Validation Rules |  |
| select_rule | Select Rule | [object Object] |
| catalog_entity_code | Catalog Entity Code | - |
| canonical_owner_module | Canonical Owner Module | - |
| pattern_flags | Pattern Flags | [object Object] |
| catalog_entity_aliases | Catalog Entity Aliases |  |

### Fields

| field_name | format | title | description | type | is_pk | default_value | field_order | input_type | width | ctype | searchable | enum_values | precision | reference_table | reference_delete_mode | relationship_label | singular_label_parent | plural_label_parent | unique_value | cube_type | input_type_rule | catalog_field_code |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `label` (label) | text | Webhook Receiver | - | string | false | - | 1 | required | default | label | true | - | 2 | - | - | has | - | - | false | auto | [object Object] | - |
| `id` 🔑 (id) | int32 | Id | - | integer | true | - | 1 | readonly | default | id | false | - | 2 | - | - | has | - | - | false | auto | [object Object] | - |
| `table_name` | reference | Table | Target table for webhook data | integer | false | - | 10 | default | default | - | false | - | 2 | entities | cascade | has receivers | - | - | false | auto | [object Object] | - |
| `description` | text | Description | Description of webhook receiver purpose | string | false | - | 20 | default | w | - | false | - | 2 | - | - | - | - | - | false | auto | [object Object] | - |
| `auth_type` | enum | Authentication Type | Type of authentication (none, hmac, or custom header) | string | false | none | 30 | default | default | - | false | ["none","hmac","header"] | 2 | - | - | - | - | - | false | auto | [object Object] | - |
| `secret` | text | Secret | Secret for webhook authentication | string | false | - | 40 | default | default | - | false | - | 2 | - | - | - | - | - | false | auto | [object Object] | - |
| `header_name` | text | Header Name | Custom header name for authentication | string | false | - | 45 | default | default | - | false | - | 2 | - | - | - | - | - | false | auto | [object Object] | - |
| `header_value` | text | Header Value | Expected value for custom header authentication | string | false | - | 46 | default | default | - | false | - | 2 | - | - | - | - | - | false | auto | [object Object] | - |
| `jsonata` | jsonata | JSONata Expression | Optional JSONata expression to transform incoming data | string | false | - | 50 | default | w | - | false | - | 2 | - | - | - | - | - | false | auto | [object Object] | - |

---

