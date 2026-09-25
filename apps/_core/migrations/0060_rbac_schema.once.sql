-- =====================================================
-- RBAC SYSTEM - DDL (Tables, Indexes, Constraints)
-- =====================================================

-- =====================================================
-- MODULES
-- =====================================================
-- Runs once: the RBAC tables, their indexes and the rbac schema with its
-- grants. The slug and updated_at triggers of these tables are in
-- 0070_rbac_schema.sql, which re-runs whenever it changes.

-- Modules: Logical groupings for roles and permissions
CREATE TABLE modules (
    id SERIAL PRIMARY KEY,
    module_name TEXT UNIQUE NOT NULL DEFAULT '',
    description TEXT DEFAULT '',
    module_type TEXT NOT NULL DEFAULT 'domain',
    view_permission TEXT DEFAULT 'user:read' NOT NULL,
    logo_color TEXT DEFAULT '',
    icon_name TEXT DEFAULT '',
    home_page TEXT DEFAULT '/' NOT NULL,
    module_slug TEXT DEFAULT '' NOT NULL UNIQUE,
    -- Catalog/blueprint lineage (v0.1.2): the catalog code this module was provisioned/cloned from.
    -- Non-unique (a clone deploys one code into several modules); module_slug stays the identity.
    catalog_module_code TEXT NOT NULL DEFAULT '',
    -- Short uppercase code for the business domain this module belongs to (e.g. ATS, HCM, ITSM, CRM).
    domain_code TEXT NOT NULL DEFAULT '',
    -- Access tier: 'basic' for simple read/edit; 'full' for role tiers, approvals & gating.
    access_scope TEXT NOT NULL DEFAULT 'basic',
    settings JSONB,
    dashboard_config JSONB,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    version INTEGER NOT NULL DEFAULT 0,
    version_date TIMESTAMPTZ,
    CONSTRAINT valid_module_type CHECK (module_type IN ('domain', 'master')),
    CONSTRAINT valid_access_scope CHECK (access_scope IN ('basic', 'full'))
);

-- =====================================================
-- PERMISSIONS AND ROLES
-- =====================================================

-- Permissions: Basic permissions in the system.
--
-- The name is the key. A serial id would be minted per database and mean
-- nothing outside it, while the name is what module packages seed, what every
-- generated RLS policy embeds as a literal, what has_permission() takes and
-- what an OAuth scope carries - so all of those would otherwise have to resolve
-- a name to a number first, and nothing could hold a foreign key to a
-- permission without storing a number nobody names. Deployment is one database
-- per tenant, so there is no cross-database id to preserve either.
--
-- Being the key is also what lets the five columns that name a permission
-- (entities.view_permission / edit_permission, modules.view_permission,
-- queues.view_permission / manage_permission) be ordinary foreign keys: before
-- that, deleting a permission left a dangling name that has_permission() failed
-- closed on, for administrators too.
CREATE TABLE permissions (
    permission_name TEXT PRIMARY KEY,
    description TEXT DEFAULT '',
    module_id INTEGER NOT NULL REFERENCES modules(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    -- Two things depend on this alphabet, and only two. A scope string is split
    -- on commas and whitespace, so a name containing either could never be
    -- granted through an OAuth scope. And permission_hierarchy's key is
    -- including || '.' || included, so with dots allowed ('a.b','c') and
    -- ('a','b.c') both generate 'a.b.c' and the second, legitimate pair fails
    -- with a primary key violation.
    --
    -- Everything else is allowed, and the segment alphabet deliberately equals
    -- the one modules.module_slug accepts (rule 90702 in 0150_dd_bootstrap.once.sql:
    -- ^[a-z0-9][a-z0-9_-]*$, hyphens included), because a module scaffold mints
    -- <slug>:<verb>. Narrowing this without narrowing that would make a module
    -- slugged service-catalog unable to name its own permissions.
    CONSTRAINT permission_name_shape CHECK (permission_name ~ '^[a-z0-9][a-z0-9_-]*(:[a-z0-9][a-z0-9_-]*)*$')
);

-- Roles: Groups of permissions
CREATE TABLE roles (
    id SERIAL PRIMARY KEY,
    role_name TEXT UNIQUE NOT NULL DEFAULT '',
    slug TEXT NOT NULL DEFAULT '' UNIQUE,
    -- Catalog/blueprint lineage (v0.1.2): the catalog persona this role was provisioned from.
    -- Non-unique lineage; roles.slug stays the identity. No consumer yet (D5 insurance).
    catalog_role_code TEXT NOT NULL DEFAULT '',
    description TEXT DEFAULT '',
    origin TEXT NOT NULL DEFAULT 'user',
    module_id INTEGER REFERENCES modules(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT valid_role_origin CHECK (origin IN ('system', 'model', 'model_master', 'user')),
    CONSTRAINT valid_role_slug CHECK (slug = '' OR slug ~ '^[a-z0-9_]+$')
);

-- Users and agents. A session is a JWT, and the caller is the row whose
-- external_id equals the sub claim.
CREATE TABLE users (
    id SERIAL PRIMARY KEY,
    -- external_id is the identity, so every principal needs one - agents
    -- included: an API key resolves to users.id, and the JWT minted from it
    -- carries this column as its sub. A user brings theirs from the
    -- authentication provider (get_userinfo upserts on it); there is no
    -- default, so a user row saved without one is refused. An agent (is_agent)
    -- saved without one, or with an empty one, gets a generated identity
    -- from assign_agent_external_id (0370_raci.sql): 'agent:' plus a random UUID. An empty or blank
    -- string is refused for both (users_external_id_not_empty, below), so no
    -- row can exist that no session could ever act as.
    --
    -- Uniqueness is not declared here. The data dictionary owns it:
    -- fields.unique_value is set for this column, and users_external_id_unique
    -- is the partial index it stands for, excluding NULL and ''. With the empty
    -- string refused that index is total in effect. A UNIQUE constraint here would be a second
    -- index over the same column. Callers upserting on this column must repeat
    -- the index predicate so PostgreSQL can infer the arbiter.
    external_id TEXT NOT NULL,
    email TEXT DEFAULT '',
    display_name TEXT DEFAULT '',
    is_disabled BOOLEAN DEFAULT FALSE,
    settings JSONB,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    last_seen TIMESTAMPTZ,
    first_name TEXT DEFAULT '',
    last_name TEXT DEFAULT '',
    is_agent BOOLEAN NOT NULL DEFAULT FALSE,
    CONSTRAINT users_external_id_not_empty CHECK (btrim(external_id) <> '')
);

-- User-Role mapping
CREATE TABLE user_roles (
    id TEXT GENERATED ALWAYS AS (user_id || '.' || role_id) STORED PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    role_id INTEGER NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
    assigned_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    assigned_by INTEGER REFERENCES users(id),
    UNIQUE (user_id, role_id)
);

-- Role-Permission mapping
CREATE TABLE role_permissions (
    id TEXT GENERATED ALWAYS AS (role_id || '.' || permission_name) STORED PRIMARY KEY,
    role_id INTEGER NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
    permission_name TEXT NOT NULL REFERENCES permissions(permission_name) ON DELETE CASCADE ON UPDATE CASCADE,
    granted_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    granted_by INTEGER REFERENCES users(id),
    UNIQUE (role_id, permission_name)
);

-- User-Permission mapping (direct per-user permissions)
CREATE TABLE user_permissions (
    id TEXT GENERATED ALWAYS AS (user_id || '.' || permission_name) STORED PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    permission_name TEXT NOT NULL REFERENCES permissions(permission_name) ON DELETE CASCADE ON UPDATE CASCADE,
    granted_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    granted_by INTEGER REFERENCES users(id),
    UNIQUE (user_id, permission_name)
);

-- =====================================================
-- PERMISSION HIERARCHY
-- =====================================================

-- Permission hierarchy: Defines which permissions imply others
-- Example: customer:manage implies customer:read and customer:write
CREATE TABLE permission_hierarchy (
    id TEXT GENERATED ALWAYS AS (including_permission_name || '.' || included_permission_name) STORED PRIMARY KEY,
    including_permission_name TEXT NOT NULL REFERENCES permissions(permission_name) ON DELETE CASCADE ON UPDATE CASCADE,
    included_permission_name TEXT NOT NULL REFERENCES permissions(permission_name) ON DELETE CASCADE ON UPDATE CASCADE,
    origin TEXT NOT NULL DEFAULT 'user',
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (including_permission_name, included_permission_name),
    CONSTRAINT no_self_reference CHECK (including_permission_name != included_permission_name),
    CONSTRAINT valid_permission_hierarchy_origin CHECK (origin IN ('system', 'model', 'model_master', 'user'))
);

-- =====================================================
-- ADD FK COLUMNS TO MODULES (after roles and permissions exist)
-- =====================================================

ALTER TABLE modules ADD COLUMN manage_permission TEXT
    REFERENCES permissions(permission_name) ON DELETE SET NULL ON UPDATE CASCADE;
ALTER TABLE modules ADD COLUMN admin_permission TEXT
    REFERENCES permissions(permission_name) ON DELETE SET NULL ON UPDATE CASCADE;
ALTER TABLE modules ADD COLUMN default_viewer_role_id INTEGER REFERENCES roles(id);
ALTER TABLE modules ADD COLUMN default_manager_role_id INTEGER REFERENCES roles(id);
ALTER TABLE modules ADD COLUMN default_admin_role_id INTEGER REFERENCES roles(id);

-- =====================================================
-- INDEXES
-- =====================================================
-- A column a unique index already covers - whole key or leading columns of a
-- composite - gets no plain index of its own. Swept by
-- 0330_test_rbac_indexes.sql.

CREATE INDEX idx_permissions_module ON permissions(module_id);

-- =====================================================
-- INDEXES - Roles
-- =====================================================

CREATE INDEX idx_roles_module ON roles(module_id);
CREATE INDEX idx_role_permissions_permission ON role_permissions(permission_name);
CREATE INDEX idx_role_permissions_granted_by ON role_permissions(granted_by);

-- =====================================================
-- INDEXES - User Permissions
-- =====================================================

CREATE INDEX idx_user_permissions_permission ON user_permissions(permission_name);
CREATE INDEX idx_user_permissions_granted_by ON user_permissions(granted_by);

-- =====================================================
-- INDEXES - Users
-- =====================================================

CREATE INDEX idx_users_email ON users(email);
CREATE INDEX idx_users_enabled ON users(is_disabled) WHERE is_disabled = FALSE;
CREATE INDEX idx_users_disabled ON users(is_disabled) WHERE is_disabled = TRUE;

-- =====================================================
-- INDEXES - User Roles
-- =====================================================

CREATE INDEX idx_user_roles_role ON user_roles(role_id);
CREATE INDEX idx_user_roles_assigned_by ON user_roles(assigned_by);

-- =====================================================
-- INDEXES - Permission Hierarchy
-- =====================================================

CREATE INDEX idx_permission_hierarchy_included ON permission_hierarchy(included_permission_name);

-- =====================================================
-- INDEXES - Modules FK columns
-- =====================================================

CREATE INDEX idx_modules_view_permission ON modules(view_permission);
CREATE INDEX idx_modules_manage_permission ON modules(manage_permission);
CREATE INDEX idx_modules_admin_permission ON modules(admin_permission);
CREATE INDEX idx_modules_default_viewer_role ON modules(default_viewer_role_id);
CREATE INDEX idx_modules_default_manager_role ON modules(default_manager_role_id);
CREATE INDEX idx_modules_default_admin_role ON modules(default_admin_role_id);
-- =====================================================
-- CREATE SCHEMA
-- =====================================================
CREATE SCHEMA IF NOT EXISTS rbac;

-- =====================================================
-- GRANT PERMISSIONS
-- =====================================================

-- Allow semantius_user users to use rbac schema and execute functions
GRANT USAGE ON SCHEMA rbac TO semantius_user;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA rbac TO semantius_user;

-- Ensure future functions are automatically granted (THIS IS KEY!)
ALTER DEFAULT PRIVILEGES IN SCHEMA rbac
    GRANT EXECUTE ON FUNCTIONS TO semantius_user;

-- Revoke default PUBLIC execute on future rbac functions
ALTER DEFAULT PRIVILEGES IN SCHEMA rbac
    REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
