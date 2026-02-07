# Database Schema Documentation

This document describes the database schema for the _core module.

**Generated:** 2026-02-07T10:06:52.225Z

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

| Field Name | Title | Format | Type | Nullable | Default | Order | Input Type | Width | Core | Searchable | Enum Values | Reference Table | Reference Delete Mode |
|------------|-------|--------|------|----------|---------|-------|------------|-------|------|------------|-------------|-----------------|----------------------|
| `table_name` 🔑 (id) | Table Name | text | default | false | - | 0 | default | m | true | true | - | - | restrict |
| `singular` | Singular | text | default | false | - | 10 | default | m | true | true | - | - | restrict |
| `plural` | Plural | text | readonly | false | - | 20 | readonly | m | true | true | - | - | restrict |
| `singular_label` (label) | Singular Label | text | required | false | - | 30 | required | m | true | true | - | - | restrict |
| `plural_label` | Plural Label | text | default | false | - | 40 | default | m | true | true | - | - | restrict |
| `icon_url` | Icon URL | url | default | false | - | 50 | default | w | true | false | - | - | restrict |
| `description` | Description | text | default | false | - | 60 | default | w | true | true | - | - | restrict |
| `module_id` | Module Id | int32 | default | true | - | 70 | default | s | true | false | - | - | restrict |
| `view_permission` | View Permission | text | default | false | - | 80 | default | m | true | false | - | - | restrict |
| `edit_permission` | Edit Permission | text | default | false | - | 90 | default | m | true | false | - | - | restrict |
| `id_column` | Id Column | text | default | false | - | 100 | default | m | true | false | - | - | restrict |
| `label_column` | Label Column | text | default | false | - | 110 | default | m | true | false | - | - | restrict |
| `managed` | Managed | boolean | default | false | - | 115 | default | s | true | false | - | - | restrict |
| `searchable` | Searchable | boolean | default | false | - | 117 | default | s | true | false | - | - | restrict |
| `created_at` | Created At | date-time | disabled | false | - | 120 | disabled | m | true | false | - | - | restrict |
| `updated_at` | Updated At | date-time | disabled | false | - | 130 | disabled | m | true | false | - | - | restrict |

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

| Field Name | Title | Format | Type | Nullable | Default | Order | Input Type | Width | Core | Searchable | Enum Values | Reference Table | Reference Delete Mode |
|------------|-------|--------|------|----------|---------|-------|------------|-------|------|------------|-------------|-----------------|----------------------|
| `id` 🔑 (id) | Id | text | readonly | false | - | 0 | readonly | m | true | false | - | - | restrict |
| `table_name` | Table Name | text | default | false | - | 10 | default | m | true | true | - | - | restrict |
| `field_name` | Field Name | text | default | false | - | 20 | default | m | true | true | - | - | restrict |
| `title` (label) | Title | text | required | false | - | 30 | required | m | true | true | - | - | restrict |
| `description` | Description | text | default | false | - | 40 | default | w | true | true | - | - | restrict |
| `format` | Format | text | default | false | - | 50 | default | m | true | false | - | - | restrict |
| `is_pk` | Is Primary Key | boolean | default | false | - | 60 | default | s | true | false | - | - | restrict |
| `is_nullable` | Is Nullable | boolean | default | false | - | 70 | default | s | true | false | - | - | restrict |
| `default_value` | Default Value | text | default | false | - | 80 | default | m | true | false | - | - | restrict |
| `field_order` | Field Order | int32 | default | false | - | 90 | default | s | true | false | - | - | restrict |
| `input_type` | Input Type | enum | default | false | - | 100 | default | m | true | false | ["default","required","readonly","disabled","hidden"] | - | restrict |
| `width` | Width | enum | default | false | - | 110 | default | s | true | false | ["s","m","w"] | - | restrict |
| `ctype` | Column Type | enum | default | false | - | 120 | default | m | true | false | ["","id","label"] | - | restrict |
| `is_core` | Is Core | boolean | default | false | - | 130 | default | s | true | false | - | - | restrict |
| `searchable` | Searchable | boolean | default | false | - | 135 | default | s | true | false | - | - | restrict |
| `enum_values` | Enum Values | json | default | true | - | 137 | default | w | true | false | - | - | restrict |
| `reference_table` | Reference Table | text | default | false | - | 138 | default | m | true | false | - | - | restrict |
| `reference_delete_mode` | Reference Delete Mode | enum | default | false | - | 139 | default | s | true | false | ["restrict","clear"] | - | restrict |
| `created_at` | Created At | date-time | disabled | false | - | 140 | disabled | m | true | false | - | - | restrict |
| `updated_at` | Updated At | date-time | disabled | false | - | 150 | disabled | m | true | false | - | - | restrict |

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

| Field Name | Title | Format | Type | Nullable | Default | Order | Input Type | Width | Core | Searchable | Enum Values | Reference Table | Reference Delete Mode |
|------------|-------|--------|------|----------|---------|-------|------------|-------|------|------------|-------------|-----------------|----------------------|
| `id` 🔑 (id) | Id | int32 | readonly | false | - | 0 | readonly | s | true | false | - | - | restrict |
| `module_name` (label) | Module Name | text | required | false | - | 10 | required | m | true | true | - | - | restrict |
| `description` | Description | text | default | false | - | 20 | default | w | true | true | - | - | restrict |
| `view_permission` | View Permission | text | default | false | - | 30 | default | m | true | false | - | - | restrict |
| `logo_url` | Logo URL | url | default | false | - | 35 | default | w | true | false | - | - | restrict |
| `logo_color` | Logo Color | text | default | false | - | 36 | default | s | true | false | - | - | restrict |
| `home_page` | Home Page | text | default | false | - | 37 | default | m | true | false | - | - | restrict |
| `alias` | Alias | text | default | false | - | 38 | default | m | true | false | - | - | restrict |
| `settings` | Settings | json | default | false | - | 39 | default | w | true | false | - | - | restrict |
| `created_at` | Created At | date-time | disabled | false | - | 40 | disabled | m | true | false | - | - | restrict |
| `updated_at` | Updated At | date-time | disabled | false | - | 50 | disabled | m | true | false | - | - | restrict |

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

| Field Name | Title | Format | Type | Nullable | Default | Order | Input Type | Width | Core | Searchable | Enum Values | Reference Table | Reference Delete Mode |
|------------|-------|--------|------|----------|---------|-------|------------|-------|------|------------|-------------|-----------------|----------------------|
| `id` 🔑 (id) | Id | text | readonly | false | - | 0 | readonly | m | true | false | - | - | restrict |
| `parent_permission_id` | Parent Permission Id | int32 | default | false | - | 10 | default | s | true | false | - | - | restrict |
| `child_permission_id` | Child Permission Id | int32 | default | false | - | 20 | default | s | true | false | - | - | restrict |
| `created_at` | Created At | date-time | disabled | false | - | 30 | disabled | m | true | false | - | - | restrict |

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

| Field Name | Title | Format | Type | Nullable | Default | Order | Input Type | Width | Core | Searchable | Enum Values | Reference Table | Reference Delete Mode |
|------------|-------|--------|------|----------|---------|-------|------------|-------|------|------------|-------------|-----------------|----------------------|
| `id` 🔑 (id) | Id | int32 | readonly | false | - | 0 | readonly | s | true | false | - | - | restrict |
| `permission_name` (label) | Permission Name | text | required | false | - | 10 | required | m | true | true | - | - | restrict |
| `description` | Description | text | default | false | - | 20 | default | w | true | true | - | - | restrict |
| `module_id` | Module Id | int32 | default | true | - | 30 | default | s | true | false | - | - | restrict |
| `created_at` | Created At | date-time | disabled | false | - | 40 | disabled | m | true | false | - | - | restrict |
| `updated_at` | Updated At | date-time | disabled | false | - | 50 | disabled | m | true | false | - | - | restrict |

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

| Field Name | Title | Format | Type | Nullable | Default | Order | Input Type | Width | Core | Searchable | Enum Values | Reference Table | Reference Delete Mode |
|------------|-------|--------|------|----------|---------|-------|------------|-------|------|------------|-------------|-----------------|----------------------|
| `id` 🔑 (id) | Id | text | readonly | false | - | 0 | readonly | m | true | false | - | - | restrict |
| `role_id` | Role Id | int32 | default | false | - | 10 | default | s | true | false | - | - | restrict |
| `permission_id` | Permission Id | int32 | default | false | - | 20 | default | s | true | false | - | - | restrict |
| `granted_at` | Granted At | date-time | disabled | false | - | 30 | disabled | m | true | false | - | - | restrict |
| `granted_by` | Granted By | int32 | default | true | - | 40 | default | s | true | false | - | - | restrict |

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

| Field Name | Title | Format | Type | Nullable | Default | Order | Input Type | Width | Core | Searchable | Enum Values | Reference Table | Reference Delete Mode |
|------------|-------|--------|------|----------|---------|-------|------------|-------|------|------------|-------------|-----------------|----------------------|
| `id` 🔑 (id) | Id | int32 | readonly | false | - | 0 | readonly | s | true | false | - | - | restrict |
| `role_name` (label) | Role Name | text | required | false | - | 10 | required | m | true | true | - | - | restrict |
| `description` | Description | text | default | false | - | 20 | default | w | true | true | - | - | restrict |
| `module_id` | Module Id | int32 | default | true | - | 30 | default | s | true | false | - | - | restrict |
| `created_at` | Created At | date-time | disabled | false | - | 40 | disabled | m | true | false | - | - | restrict |
| `updated_at` | Updated At | date-time | disabled | false | - | 50 | disabled | m | true | false | - | - | restrict |

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

| Field Name | Title | Format | Type | Nullable | Default | Order | Input Type | Width | Core | Searchable | Enum Values | Reference Table | Reference Delete Mode |
|------------|-------|--------|------|----------|---------|-------|------------|-------|------|------------|-------------|-----------------|----------------------|
| `id` 🔑 (id) | Id | text | readonly | false | - | 0 | readonly | m | true | false | - | - | restrict |
| `user_id` | User Id | int32 | default | false | - | 10 | default | s | true | false | - | - | restrict |
| `role_id` | Role Id | int32 | default | false | - | 20 | default | s | true | false | - | - | restrict |
| `assigned_at` | Assigned At | date-time | disabled | false | - | 30 | disabled | m | true | false | - | - | restrict |
| `assigned_by` | Assigned By | int32 | default | true | - | 40 | default | s | true | false | - | - | restrict |

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

| Field Name | Title | Format | Type | Nullable | Default | Order | Input Type | Width | Core | Searchable | Enum Values | Reference Table | Reference Delete Mode |
|------------|-------|--------|------|----------|---------|-------|------------|-------|------|------------|-------------|-----------------|----------------------|
| `id` 🔑 (id) | Id | int32 | readonly | false | - | 0 | readonly | s | true | false | - | - | restrict |
| `external_id` | External Id | text | readonly | false | - | 10 | readonly | m | true | true | - | - | restrict |
| `email` (label) | Email | email | default | false | - | 20 | default | m | true | true | - | - | restrict |
| `is_disabled` | Is Disabled | boolean | default | false | - | 30 | default | s | true | false | - | - | restrict |
| `settings` | Settings | json | default | false | - | 35 | default | w | true | false | - | - | restrict |
| `created_at` | Created At | date-time | disabled | false | - | 40 | disabled | m | true | false | - | - | restrict |
| `updated_at` | Updated At | date-time | disabled | false | - | 50 | disabled | m | true | false | - | - | restrict |
| `last_seen` | Last Seen | date-time | readonly | true | - | 60 | readonly | m | true | false | - | - | restrict |

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

| Field Name | Title | Format | Type | Nullable | Default | Order | Input Type | Width | Core | Searchable | Enum Values | Reference Table | Reference Delete Mode |
|------------|-------|--------|------|----------|---------|-------|------------|-------|------|------------|-------------|-----------------|----------------------|
| `id` 🔑 (id) | Id | int32 | readonly | false | - | 0 | readonly | s | true | false | - | - | restrict |
| `webhook_id` (label) | Webhook Receiver Log | text | required | false | - | 1 | required | m | true | true | - | - | restrict |
| `webhook_receiver_id` | Webhook Receiver | int32 | default | false | - | 10 | default | s | false | false | - | - | restrict |
| `webhook_timestamp` | Webhook Timestamp | date-time | default | false | - | 30 | default | m | false | false | - | - | restrict |
| `received_timestamp` | Received Timestamp | date-time | disabled | false | CURRENT_TIMESTAMP | 40 | disabled | m | false | false | - | - | restrict |
| `payload` | Payload | json | default | false | - | 50 | default | w | false | false | - | - | restrict |
| `result` | Result | enum | default | false | 10 | 60 | default | s | false | false | ["10","20","90"] | - | restrict |
| `error_message` | Error Message | text | default | false | - | 70 | default | w | false | false | - | - | restrict |
| `created_at` | Created At | date-time | disabled | false | - | 999998 | disabled | m | true | false | - | - | restrict |
| `updated_at` | Updated At | date-time | disabled | false | - | 999999 | disabled | m | true | false | - | - | restrict |

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

| Field Name | Title | Format | Type | Nullable | Default | Order | Input Type | Width | Core | Searchable | Enum Values | Reference Table | Reference Delete Mode |
|------------|-------|--------|------|----------|---------|-------|------------|-------|------|------------|-------------|-----------------|----------------------|
| `id` 🔑 (id) | Id | int32 | readonly | false | - | 0 | readonly | s | true | false | - | - | restrict |
| `label` (label) | Webhook Receiver | text | required | false | - | 1 | required | m | true | true | - | - | restrict |
| `table_name` | Table | text | default | false | - | 10 | default | s | false | false | - | - | restrict |
| `description` | Description | text | default | false | - | 20 | default | w | false | false | - | - | restrict |
| `auth_type` | Authentication Type | enum | default | false | none | 30 | default | s | false | false | ["none","hmac","header"] | - | restrict |
| `secret` | Secret | text | default | false | - | 40 | default | m | false | false | - | - | restrict |
| `header_name` | Header Name | text | default | false | - | 45 | default | m | false | false | - | - | restrict |
| `header_value` | Header Value | text | default | false | - | 46 | default | m | false | false | - | - | restrict |
| `jsonata` | JSONata Expression | jsonata | default | false | - | 50 | default | w | false | false | - | - | restrict |
| `created_at` | Created At | date-time | disabled | false | - | 999998 | disabled | m | true | false | - | - | restrict |
| `updated_at` | Updated At | date-time | disabled | false | - | 999999 | disabled | m | true | false | - | - | restrict |

---

