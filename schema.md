# Database Schema Documentation

This document describes the database schema for the _core module.

**Generated:** 2026-02-07T11:11:11.092Z

---

## entities

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

### Fields

| field_name | title | description | format | is_pk | is_nullable | default_value | field_order | input_type | width | ctype | is_core | searchable | enum_values | reference_table | reference_delete_mode |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `table_name` 🔑 (id) | Table Name | Physical table name in database | text | true | false | - | 0 | default | m | id | true | true | - | - | restrict |
| `singular` | Singular | Singular form of table name | text | false | false | - | 10 | default | m | - | true | true | - | - | restrict |
| `plural` | Plural | Plural form of table name, auto-assigned to table_name | text | false | false | - | 20 | readonly | m | - | true | true | - | - | restrict |
| `singular_label` (label) | Singular Label | Human-readable singular label for UI/reports | text | false | false | - | 30 | required | m | label | true | true | - | - | restrict |
| `plural_label` | Plural Label | Human-readable plural label for UI/reports | text | false | false | - | 40 | default | m | - | true | true | - | - | restrict |
| `icon_url` | Icon URL | Optional URL or path to icon for this table | url | false | false | - | 50 | default | w | - | true | false | - | - | restrict |
| `description` | Description | Detailed description of the table | text | false | false | - | 60 | default | w | - | true | true | - | - | restrict |
| `module_id` | Module Id | Module this table belongs to | int32 | false | true | - | 70 | default | s | - | true | false | - | - | restrict |
| `view_permission` | View Permission | Permission required to SELECT from this table | text | false | false | - | 80 | default | m | - | true | false | - | - | restrict |
| `edit_permission` | Edit Permission | Permission required to INSERT/UPDATE/DELETE from this table | text | false | false | - | 90 | default | m | - | true | false | - | - | restrict |
| `id_column` | Id Column | Name of primary key column | text | false | false | - | 100 | default | m | - | true | false | - | - | restrict |
| `label_column` | Label Column | Name of label/display column | text | false | false | - | 110 | default | m | - | true | false | - | - | restrict |
| `managed` | Managed | When false, automatic DDL execution is disabled | boolean | false | false | - | 115 | default | s | - | true | false | - | - | restrict |
| `searchable` | Searchable | Whether table is included in full-text search | boolean | false | false | - | 117 | default | s | - | true | false | - | - | restrict |

---

## fields

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

### Fields

| field_name | title | description | format | is_pk | is_nullable | default_value | field_order | input_type | width | ctype | is_core | searchable | enum_values | reference_table | reference_delete_mode |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `id` 🔑 (id) | Id | Generated identifier (table_name.field_name) | text | true | false | - | 0 | readonly | m | id | true | false | - | - | restrict |
| `table_name` | Table Name | Table this field belongs to | text | false | false | - | 10 | default | m | - | true | true | - | - | restrict |
| `field_name` | Field Name | Physical column name in database | text | false | false | - | 20 | default | m | - | true | true | - | - | restrict |
| `title` (label) | Title | Human-readable display name for the field | text | false | false | - | 30 | required | m | label | true | true | - | - | restrict |
| `description` | Description | Detailed description of the field | text | false | false | - | 40 | default | w | - | true | true | - | - | restrict |
| `format` | Format | JSON Schema format or primitive type | enum | false | false | - | 50 | default | m | - | true | false | ["json","html","text","code","jsonata","reference","enum","date","time","date-time","duration","uri","uri-reference","uri-template","url","email","hostname","ipv4","ipv6","regex","uuid","json-pointer","json-pointer-uri-fragment","relative-json-pointer","byte","int32","int64","float","double","password","binary","string","number","integer","boolean","object","array","null"] | - | restrict |
| `is_pk` | Is Primary Key | Whether this field is the primary key | boolean | false | false | - | 60 | default | s | - | true | false | - | - | restrict |
| `is_nullable` | Is Nullable | Whether this field allows NULL values | boolean | false | false | - | 70 | default | s | - | true | false | - | - | restrict |
| `default_value` | Default Value | Default value for the field | text | false | false | - | 80 | default | m | - | true | false | - | - | restrict |
| `field_order` | Field Order | Display order for the field | int32 | false | false | - | 90 | default | s | - | true | false | - | - | restrict |
| `input_type` | Input Type | Input type for UI rendering | enum | false | false | - | 100 | default | m | - | true | false | ["default","required","readonly","disabled","hidden"] | - | restrict |
| `width` | Width | Display width for UI rendering | enum | false | false | - | 110 | default | s | - | true | false | ["s","m","w"] | - | restrict |
| `ctype` | Column Type | Special column type (id, label, etc.) | enum | false | false | - | 120 | default | m | - | true | false | ["","id","label"] | - | restrict |
| `is_core` | Is Core | Whether this is a core system field | boolean | false | false | - | 130 | default | s | - | true | false | - | - | restrict |
| `searchable` | Searchable | Whether field is included in full-text search | boolean | false | false | - | 135 | default | s | - | true | false | - | - | restrict |
| `enum_values` | Enum Values | JSON array of allowed enum values | json | false | true | - | 137 | default | w | - | true | false | - | - | restrict |
| `reference_table` | Reference Table | Table name for foreign key relationships | text | false | false | - | 138 | default | m | - | true | false | - | - | restrict |
| `reference_delete_mode` | Reference Delete Mode | ON DELETE behavior: restrict or clear | enum | false | false | - | 139 | default | s | - | true | false | ["restrict","clear"] | - | restrict |

---

## modules

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

### Fields

| field_name | title | description | format | is_pk | is_nullable | default_value | field_order | input_type | width | ctype | is_core | searchable | enum_values | reference_table | reference_delete_mode |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `id` 🔑 (id) | Id | Internal module identifier | int32 | true | false | - | 0 | readonly | s | id | true | false | - | - | restrict |
| `module_name` (label) | Module Name | Unique module name | text | false | false | - | 10 | required | m | label | true | true | - | - | restrict |
| `description` | Description | Description of the module | text | false | false | - | 20 | default | w | - | true | true | - | - | restrict |
| `view_permission` | View Permission | Permission required to view this module | text | false | false | - | 30 | default | m | - | true | false | - | - | restrict |
| `logo_url` | Logo URL | URL or base64 data URI for module logo | url | false | false | - | 35 | default | w | - | true | false | - | - | restrict |
| `logo_color` | Logo Color | Hex color code for module logo | text | false | false | - | 36 | default | s | - | true | false | - | - | restrict |
| `home_page` | Home Page | Default home page path for module | text | false | false | - | 37 | default | m | - | true | false | - | - | restrict |
| `alias` | Alias | Alternative name or identifier for module | text | false | false | - | 38 | default | m | - | true | false | - | - | restrict |
| `settings` | Settings | Module-specific settings and configuration | json | false | false | - | 39 | default | w | - | true | false | - | - | restrict |

---

## permission_hierarchy

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

### Fields

| field_name | title | description | format | is_pk | is_nullable | default_value | field_order | input_type | width | ctype | is_core | searchable | enum_values | reference_table | reference_delete_mode |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `id` 🔑 (id) | Id | Generated identifier (parent_permission_id.child_permission_id) | text | true | false | - | 0 | readonly | m | id | true | false | - | - | restrict |
| `parent_permission_id` | Parent Permission Id | Parent permission that implies child permissions | int32 | false | false | - | 10 | default | s | - | true | false | - | - | restrict |
| `child_permission_id` | Child Permission Id | Child permission implied by parent | int32 | false | false | - | 20 | default | s | - | true | false | - | - | restrict |

---

## permissions

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

### Fields

| field_name | title | description | format | is_pk | is_nullable | default_value | field_order | input_type | width | ctype | is_core | searchable | enum_values | reference_table | reference_delete_mode |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `id` 🔑 (id) | Id | Internal permission identifier | int32 | true | false | - | 0 | readonly | s | id | true | false | - | - | restrict |
| `permission_name` (label) | Permission Name | Unique permission name | text | false | false | - | 10 | required | m | label | true | true | - | - | restrict |
| `description` | Description | Description of the permission | text | false | false | - | 20 | default | w | - | true | true | - | - | restrict |
| `module_id` | Module Id | Module this permission belongs to | int32 | false | true | - | 30 | default | s | - | true | false | - | - | restrict |

---

## role_permissions

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

### Fields

| field_name | title | description | format | is_pk | is_nullable | default_value | field_order | input_type | width | ctype | is_core | searchable | enum_values | reference_table | reference_delete_mode |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `id` 🔑 (id) | Id | Generated identifier (role_id.permission_id) | text | true | false | - | 0 | readonly | m | id | true | false | - | - | restrict |
| `role_id` | Role Id | Role this permission is granted to | int32 | false | false | - | 10 | default | s | - | true | false | - | - | restrict |
| `permission_id` | Permission Id | Permission granted to the role | int32 | false | false | - | 20 | default | s | - | true | false | - | - | restrict |
| `granted_at` | Granted At | Timestamp when permission was granted | date-time | false | false | - | 30 | disabled | m | - | true | false | - | - | restrict |
| `granted_by` | Granted By | User who granted this permission | int32 | false | true | - | 40 | default | s | - | true | false | - | - | restrict |

---

## roles

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

### Fields

| field_name | title | description | format | is_pk | is_nullable | default_value | field_order | input_type | width | ctype | is_core | searchable | enum_values | reference_table | reference_delete_mode |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `id` 🔑 (id) | Id | Internal role identifier | int32 | true | false | - | 0 | readonly | s | id | true | false | - | - | restrict |
| `role_name` (label) | Role Name | Unique role name | text | false | false | - | 10 | required | m | label | true | true | - | - | restrict |
| `description` | Description | Description of the role | text | false | false | - | 20 | default | w | - | true | true | - | - | restrict |
| `module_id` | Module Id | Module this role belongs to | int32 | false | true | - | 30 | default | s | - | true | false | - | - | restrict |

---

## user_roles

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

### Fields

| field_name | title | description | format | is_pk | is_nullable | default_value | field_order | input_type | width | ctype | is_core | searchable | enum_values | reference_table | reference_delete_mode |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `id` 🔑 (id) | Id | Generated identifier (user_id.role_id) | text | true | false | - | 0 | readonly | m | id | true | false | - | - | restrict |
| `user_id` | User Id | User this role is assigned to | int32 | false | false | - | 10 | default | s | - | true | false | - | - | restrict |
| `role_id` | Role Id | Role assigned to the user | int32 | false | false | - | 20 | default | s | - | true | false | - | - | restrict |
| `assigned_at` | Assigned At | Timestamp when role was assigned | date-time | false | false | - | 30 | disabled | m | - | true | false | - | - | restrict |
| `assigned_by` | Assigned By | User who assigned this role | int32 | false | true | - | 40 | default | s | - | true | false | - | - | restrict |

---

## users

External users synchronized from JWT tokens

| field_name | label | value |
|------------|-------|-------|
| table_name | Table Name | `users` |
| singular | Singular | user |
| plural | Plural | users |
| singular_label | Singular Label | User |
| plural_label | Plural Label | Users |
| icon_url | Icon URL | - |
| description | Description | External users synchronized from JWT tokens |
| module_id | Module Id | 1 |
| view_permission | View Permission | `user:read` |
| edit_permission | Edit Permission | `user:manage` |
| id_column | Id Column | `id` |
| label_column | Label Column | `email` |
| managed | Managed | true |
| searchable | Searchable | true |

### Fields

| field_name | title | description | format | is_pk | is_nullable | default_value | field_order | input_type | width | ctype | is_core | searchable | enum_values | reference_table | reference_delete_mode |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `id` 🔑 (id) | Id | Internal user identifier | int32 | true | false | - | 0 | readonly | s | id | true | false | - | - | restrict |
| `external_id` | External Id | External identifier from authentication provider | text | false | false | - | 10 | readonly | m | - | true | true | - | - | restrict |
| `email` (label) | Email | User email address | email | false | false | - | 20 | default | m | label | true | true | - | - | restrict |
| `is_disabled` | Is Disabled | Whether user account is disabled | boolean | false | false | - | 30 | default | s | - | true | false | - | - | restrict |
| `settings` | Settings | User-specific settings and preferences | json | false | false | - | 35 | default | w | - | true | false | - | - | restrict |
| `last_seen` | Last Seen | Timestamp when user was last active | date-time | false | true | - | 60 | readonly | m | - | true | false | - | - | restrict |

---

## webhook_receiver_logs

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
| label_column | Label Column | `webhook_id` |
| managed | Managed | true |
| searchable | Searchable | true |

### Fields

| field_name | title | description | format | is_pk | is_nullable | default_value | field_order | input_type | width | ctype | is_core | searchable | enum_values | reference_table | reference_delete_mode |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `id` 🔑 (id) | Id | - | int32 | true | false | - | 0 | readonly | s | id | true | false | - | - | restrict |
| `webhook_id` (label) | Webhook Receiver Log | - | text | false | false | - | 1 | required | m | label | true | true | - | - | restrict |
| `webhook_receiver_id` | Webhook Receiver | Reference to webhook receiver configuration | int32 | false | false | - | 10 | default | s | - | false | false | - | - | restrict |
| `webhook_timestamp` | Webhook Timestamp | Timestamp from webhook source | date-time | false | false | - | 30 | default | m | - | false | false | - | - | restrict |
| `received_timestamp` | Received Timestamp | Timestamp when webhook was received | date-time | false | false | CURRENT_TIMESTAMP | 40 | disabled | m | - | false | false | - | - | restrict |
| `payload` | Payload | Webhook payload data | json | false | false | - | 50 | default | w | - | false | false | - | - | restrict |
| `result` | Result | Processing result: 10=received, 20=processed, 90=failed | enum | false | false | 10 | 60 | default | s | - | false | false | ["10","20","90"] | - | restrict |
| `error_message` | Error Message | Error message if processing failed | text | false | false | - | 70 | default | w | - | false | false | - | - | restrict |

---

## webhook_receivers

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

### Fields

| field_name | title | description | format | is_pk | is_nullable | default_value | field_order | input_type | width | ctype | is_core | searchable | enum_values | reference_table | reference_delete_mode |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `id` 🔑 (id) | Id | - | int32 | true | false | - | 0 | readonly | s | id | true | false | - | - | restrict |
| `label` (label) | Webhook Receiver | - | text | false | false | - | 1 | required | m | label | true | true | - | - | restrict |
| `table_name` | Table | Target table for webhook data | text | false | false | - | 10 | default | s | - | false | false | - | - | restrict |
| `description` | Description | Description of webhook receiver purpose | text | false | false | - | 20 | default | w | - | false | false | - | - | restrict |
| `auth_type` | Authentication Type | Type of authentication (none, hmac, or custom header) | enum | false | false | none | 30 | default | s | - | false | false | ["none","hmac","header"] | - | restrict |
| `secret` | Secret | Secret for webhook authentication | text | false | false | - | 40 | default | m | - | false | false | - | - | restrict |
| `header_name` | Header Name | Custom header name for authentication | text | false | false | - | 45 | default | m | - | false | false | - | - | restrict |
| `header_value` | Header Value | Expected value for custom header authentication | text | false | false | - | 46 | default | m | - | false | false | - | - | restrict |
| `jsonata` | JSONata Expression | Optional JSONata expression to transform incoming data | jsonata | false | false | - | 50 | default | w | - | false | false | - | - | restrict |

---

