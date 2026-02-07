# Database Schema Documentation

This document describes the database schema for the _core module.

**Generated:** 2026-02-07T10:28:27.354Z

---

## Entity

**Table Name:** `entities`

**Description:** Metadata for dynamically created tables

### Entity Metadata

| Property | Value |
|----------|-------|
| Table Name | `entities` |
| Singular | entity |
| Plural | entities |
| Singular Label | Entity |
| Plural Label | Entities |
| Module ID | 1 |
| View Permission | `public:read` |
| Edit Permission | `admin` |
| ID Column | `table_name` |
| Label Column | `singular_label` |
| Managed | true |
| Searchable | true |

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
| `created_at` | Created At | Timestamp when record was created | date-time | false | false | - | 120 | disabled | m | - | true | false | - | - | restrict |
| `updated_at` | Updated At | Timestamp when record was last updated | date-time | false | false | - | 130 | disabled | m | - | true | false | - | - | restrict |

---

## Field

**Table Name:** `fields`

**Description:** Metadata for fields in dynamically created tables

### Entity Metadata

| Property | Value |
|----------|-------|
| Table Name | `fields` |
| Singular | field |
| Plural | fields |
| Singular Label | Field |
| Plural Label | Fields |
| Module ID | 1 |
| View Permission | `public:read` |
| Edit Permission | `admin` |
| ID Column | `id` |
| Label Column | `title` |
| Managed | true |
| Searchable | true |

### Fields

| field_name | title | description | format | is_pk | is_nullable | default_value | field_order | input_type | width | ctype | is_core | searchable | enum_values | reference_table | reference_delete_mode |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `id` 🔑 (id) | Id | Generated identifier (table_name.field_name) | text | true | false | - | 0 | readonly | m | id | true | false | - | - | restrict |
| `table_name` | Table Name | Table this field belongs to | text | false | false | - | 10 | default | m | - | true | true | - | - | restrict |
| `field_name` | Field Name | Physical column name in database | text | false | false | - | 20 | default | m | - | true | true | - | - | restrict |
| `title` (label) | Title | Human-readable display name for the field | text | false | false | - | 30 | required | m | label | true | true | - | - | restrict |
| `description` | Description | Detailed description of the field | text | false | false | - | 40 | default | w | - | true | true | - | - | restrict |
| `format` | Format | JSON Schema format or primitive type | text | false | false | - | 50 | default | m | - | true | false | - | - | restrict |
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
| `created_at` | Created At | Timestamp when record was created | date-time | false | false | - | 140 | disabled | m | - | true | false | - | - | restrict |
| `updated_at` | Updated At | Timestamp when record was last updated | date-time | false | false | - | 150 | disabled | m | - | true | false | - | - | restrict |

---

## Module

**Table Name:** `modules`

**Description:** Logical modules that group related roles and permissions

### Entity Metadata

| Property | Value |
|----------|-------|
| Table Name | `modules` |
| Singular | module |
| Plural | modules |
| Singular Label | Module |
| Plural Label | Modules |
| Module ID | 1 |
| View Permission | `admin` |
| Edit Permission | `admin` |
| ID Column | `id` |
| Label Column | `module_name` |
| Managed | true |
| Searchable | true |

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
| `created_at` | Created At | Timestamp when record was created | date-time | false | false | - | 40 | disabled | m | - | true | false | - | - | restrict |
| `updated_at` | Updated At | Timestamp when record was last updated | date-time | false | false | - | 50 | disabled | m | - | true | false | - | - | restrict |

---

## Permission Hierarchy

**Table Name:** `permission_hierarchy`

**Description:** Defines permission inheritance (parent implies children)

### Entity Metadata

| Property | Value |
|----------|-------|
| Table Name | `permission_hierarchy` |
| Singular | permission_hierarchy |
| Plural | permission_hierarchy |
| Singular Label | Permission Hierarchy |
| Plural Label | Permission Hierarchy |
| Module ID | 1 |
| View Permission | `admin` |
| Edit Permission | `admin` |
| ID Column | `id` |
| Label Column | `id` |
| Managed | true |
| Searchable | false |

### Fields

| field_name | title | description | format | is_pk | is_nullable | default_value | field_order | input_type | width | ctype | is_core | searchable | enum_values | reference_table | reference_delete_mode |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `id` 🔑 (id) | Id | Generated identifier (parent_permission_id.child_permission_id) | text | true | false | - | 0 | readonly | m | id | true | false | - | - | restrict |
| `parent_permission_id` | Parent Permission Id | Parent permission that implies child permissions | int32 | false | false | - | 10 | default | s | - | true | false | - | - | restrict |
| `child_permission_id` | Child Permission Id | Child permission implied by parent | int32 | false | false | - | 20 | default | s | - | true | false | - | - | restrict |
| `created_at` | Created At | Timestamp when record was created | date-time | false | false | - | 30 | disabled | m | - | true | false | - | - | restrict |

---

## Permission

**Table Name:** `permissions`

**Description:** System permissions that can be assigned to roles

### Entity Metadata

| Property | Value |
|----------|-------|
| Table Name | `permissions` |
| Singular | permission |
| Plural | permissions |
| Singular Label | Permission |
| Plural Label | Permissions |
| Module ID | 1 |
| View Permission | `admin` |
| Edit Permission | `admin` |
| ID Column | `id` |
| Label Column | `permission_name` |
| Managed | true |
| Searchable | true |

### Fields

| field_name | title | description | format | is_pk | is_nullable | default_value | field_order | input_type | width | ctype | is_core | searchable | enum_values | reference_table | reference_delete_mode |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `id` 🔑 (id) | Id | Internal permission identifier | int32 | true | false | - | 0 | readonly | s | id | true | false | - | - | restrict |
| `permission_name` (label) | Permission Name | Unique permission name | text | false | false | - | 10 | required | m | label | true | true | - | - | restrict |
| `description` | Description | Description of the permission | text | false | false | - | 20 | default | w | - | true | true | - | - | restrict |
| `module_id` | Module Id | Module this permission belongs to | int32 | false | true | - | 30 | default | s | - | true | false | - | - | restrict |
| `created_at` | Created At | Timestamp when record was created | date-time | false | false | - | 40 | disabled | m | - | true | false | - | - | restrict |
| `updated_at` | Updated At | Timestamp when record was last updated | date-time | false | false | - | 50 | disabled | m | - | true | false | - | - | restrict |

---

## Role Permission

**Table Name:** `role_permissions`

**Description:** Many-to-many mapping between roles and permissions

### Entity Metadata

| Property | Value |
|----------|-------|
| Table Name | `role_permissions` |
| Singular | role_permission |
| Plural | role_permissions |
| Singular Label | Role Permission |
| Plural Label | Role Permissions |
| Module ID | 1 |
| View Permission | `admin` |
| Edit Permission | `admin` |
| ID Column | `id` |
| Label Column | `id` |
| Managed | true |
| Searchable | false |

### Fields

| field_name | title | description | format | is_pk | is_nullable | default_value | field_order | input_type | width | ctype | is_core | searchable | enum_values | reference_table | reference_delete_mode |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `id` 🔑 (id) | Id | Generated identifier (role_id.permission_id) | text | true | false | - | 0 | readonly | m | id | true | false | - | - | restrict |
| `role_id` | Role Id | Role this permission is granted to | int32 | false | false | - | 10 | default | s | - | true | false | - | - | restrict |
| `permission_id` | Permission Id | Permission granted to the role | int32 | false | false | - | 20 | default | s | - | true | false | - | - | restrict |
| `granted_at` | Granted At | Timestamp when permission was granted | date-time | false | false | - | 30 | disabled | m | - | true | false | - | - | restrict |
| `granted_by` | Granted By | User who granted this permission | int32 | false | true | - | 40 | default | s | - | true | false | - | - | restrict |

---

## Role

**Table Name:** `roles`

**Description:** Groups of permissions that can be assigned to users

### Entity Metadata

| Property | Value |
|----------|-------|
| Table Name | `roles` |
| Singular | role |
| Plural | roles |
| Singular Label | Role |
| Plural Label | Roles |
| Module ID | 1 |
| View Permission | `admin` |
| Edit Permission | `admin` |
| ID Column | `id` |
| Label Column | `role_name` |
| Managed | true |
| Searchable | true |

### Fields

| field_name | title | description | format | is_pk | is_nullable | default_value | field_order | input_type | width | ctype | is_core | searchable | enum_values | reference_table | reference_delete_mode |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `id` 🔑 (id) | Id | Internal role identifier | int32 | true | false | - | 0 | readonly | s | id | true | false | - | - | restrict |
| `role_name` (label) | Role Name | Unique role name | text | false | false | - | 10 | required | m | label | true | true | - | - | restrict |
| `description` | Description | Description of the role | text | false | false | - | 20 | default | w | - | true | true | - | - | restrict |
| `module_id` | Module Id | Module this role belongs to | int32 | false | true | - | 30 | default | s | - | true | false | - | - | restrict |
| `created_at` | Created At | Timestamp when record was created | date-time | false | false | - | 40 | disabled | m | - | true | false | - | - | restrict |
| `updated_at` | Updated At | Timestamp when record was last updated | date-time | false | false | - | 50 | disabled | m | - | true | false | - | - | restrict |

---

## User Role

**Table Name:** `user_roles`

**Description:** Many-to-many mapping between users and roles

### Entity Metadata

| Property | Value |
|----------|-------|
| Table Name | `user_roles` |
| Singular | user_role |
| Plural | user_roles |
| Singular Label | User Role |
| Plural Label | User Roles |
| Module ID | 1 |
| View Permission | `admin` |
| Edit Permission | `admin` |
| ID Column | `id` |
| Label Column | `id` |
| Managed | true |
| Searchable | false |

### Fields

| field_name | title | description | format | is_pk | is_nullable | default_value | field_order | input_type | width | ctype | is_core | searchable | enum_values | reference_table | reference_delete_mode |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `id` 🔑 (id) | Id | Generated identifier (user_id.role_id) | text | true | false | - | 0 | readonly | m | id | true | false | - | - | restrict |
| `user_id` | User Id | User this role is assigned to | int32 | false | false | - | 10 | default | s | - | true | false | - | - | restrict |
| `role_id` | Role Id | Role assigned to the user | int32 | false | false | - | 20 | default | s | - | true | false | - | - | restrict |
| `assigned_at` | Assigned At | Timestamp when role was assigned | date-time | false | false | - | 30 | disabled | m | - | true | false | - | - | restrict |
| `assigned_by` | Assigned By | User who assigned this role | int32 | false | true | - | 40 | default | s | - | true | false | - | - | restrict |

---

## User

**Table Name:** `users`

**Description:** External users synchronized from JWT tokens

### Entity Metadata

| Property | Value |
|----------|-------|
| Table Name | `users` |
| Singular | user |
| Plural | users |
| Singular Label | User |
| Plural Label | Users |
| Module ID | 1 |
| View Permission | `user:read` |
| Edit Permission | `user:manage` |
| ID Column | `id` |
| Label Column | `email` |
| Managed | true |
| Searchable | true |

### Fields

| field_name | title | description | format | is_pk | is_nullable | default_value | field_order | input_type | width | ctype | is_core | searchable | enum_values | reference_table | reference_delete_mode |
|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|------------|
| `id` 🔑 (id) | Id | Internal user identifier | int32 | true | false | - | 0 | readonly | s | id | true | false | - | - | restrict |
| `external_id` | External Id | External identifier from authentication provider | text | false | false | - | 10 | readonly | m | - | true | true | - | - | restrict |
| `email` (label) | Email | User email address | email | false | false | - | 20 | default | m | label | true | true | - | - | restrict |
| `is_disabled` | Is Disabled | Whether user account is disabled | boolean | false | false | - | 30 | default | s | - | true | false | - | - | restrict |
| `settings` | Settings | User-specific settings and preferences | json | false | false | - | 35 | default | w | - | true | false | - | - | restrict |
| `created_at` | Created At | Timestamp when record was created | date-time | false | false | - | 40 | disabled | m | - | true | false | - | - | restrict |
| `updated_at` | Updated At | Timestamp when record was last updated | date-time | false | false | - | 50 | disabled | m | - | true | false | - | - | restrict |
| `last_seen` | Last Seen | Timestamp when user was last active | date-time | false | true | - | 60 | readonly | m | - | true | false | - | - | restrict |

---

## Webhook Receiver Log

**Table Name:** `webhook_receiver_logs`

**Description:** Log of webhook receiver events

### Entity Metadata

| Property | Value |
|----------|-------|
| Table Name | `webhook_receiver_logs` |
| Singular | webhook_receiver_log |
| Plural | webhook_receiver_logs |
| Singular Label | Webhook Receiver Log |
| Plural Label | Webhook Receiver Logs |
| Module ID | 1 |
| View Permission | `admin` |
| Edit Permission | `admin` |
| ID Column | `id` |
| Label Column | `webhook_id` |
| Managed | true |
| Searchable | true |

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
| `created_at` | Created At | - | date-time | false | false | - | 999998 | disabled | m | - | true | false | - | - | restrict |
| `updated_at` | Updated At | - | date-time | false | false | - | 999999 | disabled | m | - | true | false | - | - | restrict |

---

## Webhook Receiver

**Table Name:** `webhook_receivers`

**Description:** Configuration for webhook endpoints

### Entity Metadata

| Property | Value |
|----------|-------|
| Table Name | `webhook_receivers` |
| Singular | webhook_receiver |
| Plural | webhook_receivers |
| Singular Label | Webhook Receiver |
| Plural Label | Webhook Receivers |
| Module ID | 1 |
| View Permission | `admin` |
| Edit Permission | `admin` |
| ID Column | `id` |
| Label Column | `label` |
| Managed | true |
| Searchable | true |

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
| `created_at` | Created At | - | date-time | false | false | - | 999998 | disabled | m | - | true | false | - | - | restrict |
| `updated_at` | Updated At | - | date-time | false | false | - | 999999 | disabled | m | - | true | false | - | - | restrict |

---

