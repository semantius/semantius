-- =====================================================
-- RBAC SYSTEM - DDL (Tables, Indexes, Constraints)
-- =====================================================

-- =====================================================
-- MODULES
-- =====================================================

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
    CONSTRAINT valid_module_slug CHECK (module_slug = '' OR module_slug ~ '^[a-z0-9_]+$'),
    CONSTRAINT valid_module_type CHECK (module_type IN ('domain', 'master')),
    CONSTRAINT valid_access_scope CHECK (access_scope IN ('basic', 'full'))
);

-- Matches the format the DDL triggers apply (plural label + blank line + description),
-- so this bootstrap comment stays identical to what update_dd_table_comment would regenerate.
COMMENT ON TABLE modules IS E'Modules\n\nGroups of related tables and permissions';
COMMENT ON COLUMN modules.module_slug IS 'URL-safe unique identifier for module. Auto-generated from module_name if not provided.';
COMMENT ON COLUMN modules.domain_code IS 'Short uppercase code for the business domain this module belongs to (e.g. ATS, HCM, ITSM, CRM).';
COMMENT ON COLUMN modules.access_scope IS 'Access tier: basic for simple read/edit; full for role tiers, approvals & gating.';

-- =====================================================
-- AUTO-SET MODULE SLUG TRIGGER
-- =====================================================
-- Automatically generates module_slug from module_name when not provided

CREATE OR REPLACE FUNCTION auto_set_module_slug()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.module_slug IS NULL OR trim(NEW.module_slug) = '' THEN
        NEW.module_slug := lower(regexp_replace(NEW.module_name, '[^a-zA-Z0-9]+', '_', 'g'));
        -- Collapse consecutive underscores into a single one
        NEW.module_slug := regexp_replace(NEW.module_slug, '_+', '_', 'g');
        -- Remove leading/trailing underscores
        NEW.module_slug := trim(both '_' from NEW.module_slug);
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SET search_path = public;

COMMENT ON FUNCTION auto_set_module_slug IS
'Trigger function that auto-generates module_slug from module_name when not provided';

CREATE TRIGGER auto_set_module_slug_trigger
    BEFORE INSERT OR UPDATE ON modules
    FOR EACH ROW
    EXECUTE FUNCTION auto_set_module_slug();

COMMENT ON TRIGGER auto_set_module_slug_trigger ON modules IS
'Auto-generates module_slug from module_name when not explicitly provided';

-- Revoke default PUBLIC execute on trigger function
REVOKE EXECUTE ON FUNCTION auto_set_module_slug() FROM PUBLIC;

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
    -- the one modules.module_slug accepts (0200_module_slug_validation.sql:
    -- ^[a-z0-9][a-z0-9_-]*$, hyphens included), because a module scaffold mints
    -- <slug>:<verb>. Narrowing this without narrowing that would make a module
    -- slugged service-catalog unable to name its own permissions.
    CONSTRAINT permission_name_shape CHECK (permission_name ~ '^[a-z0-9][a-z0-9_-]*(:[a-z0-9][a-z0-9_-]*)*$')
);

COMMENT ON TABLE permissions IS 'System permissions that can be assigned to roles and organized via hierarchy';
COMMENT ON COLUMN permissions.permission_name IS 'The permission, and the key: colon-separated segments over the same alphabet module_slug uses, each starting with a letter or digit. Referenced by name from every table that grants or requires it.';
COMMENT ON COLUMN permissions.module_id IS 'Required reference to the module this permission belongs to';

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

COMMENT ON TABLE roles IS 'Groups of permissions that can be assigned to users';
COMMENT ON COLUMN roles.module_id IS 'Optional reference to a module for logical grouping';
COMMENT ON COLUMN roles.slug IS 'Snake_case unique identifier for role. Auto-generated from role_name if not provided.';
COMMENT ON COLUMN roles.origin IS 'How this role was created: system (platform built-ins), model (domain module scaffold), model_master (master module scaffold), or user (admin-created).';

-- =====================================================
-- AUTO-SET ROLE SLUG TRIGGER
-- =====================================================
-- Automatically generates slug from role_name when not provided

CREATE OR REPLACE FUNCTION auto_set_role_slug()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.slug IS NULL OR trim(NEW.slug) = '' THEN
        NEW.slug := lower(regexp_replace(NEW.role_name, '[^a-zA-Z0-9]+', '_', 'g'));
        -- Collapse consecutive underscores into a single one
        NEW.slug := regexp_replace(NEW.slug, '_+', '_', 'g');
        -- Remove leading/trailing underscores
        NEW.slug := trim(both '_' from NEW.slug);
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SET search_path = public;

COMMENT ON FUNCTION auto_set_role_slug IS
'Trigger function that auto-generates slug from role_name when not provided';

CREATE TRIGGER auto_set_role_slug_trigger
    BEFORE INSERT OR UPDATE ON roles
    FOR EACH ROW
    EXECUTE FUNCTION auto_set_role_slug();

COMMENT ON TRIGGER auto_set_role_slug_trigger ON roles IS
'Auto-generates slug from role_name when not explicitly provided';

-- Revoke default PUBLIC execute on trigger function
REVOKE EXECUTE ON FUNCTION auto_set_role_slug() FROM PUBLIC;

-- Users and agents. A session is a JWT, and the caller is the row whose
-- external_id equals the sub claim.
CREATE TABLE users (
    id SERIAL PRIMARY KEY,
    -- external_id is the identity, so every principal needs one - agents
    -- included: an API key resolves to users.id, and the JWT minted from it
    -- carries this column as its sub. A user brings theirs from the
    -- authentication provider (get_userinfo upserts on it); there is no
    -- default, so a user row saved without one is refused. An agent (is_agent,
    -- 0210) saved without one, or with an empty one, gets a generated identity
    -- from the trigger in 0210: 'agent:' plus a random UUID. An empty or blank
    -- string is refused for both (users_external_id_not_empty, below), so no
    -- row can exist that no session could ever act as.
    --
    -- Uniqueness is not declared here. The data dictionary owns it: 0190 sets
    -- fields.unique_value for this column, which builds users_external_id_unique
    -- as a partial index excluding NULL and ''. With the empty string refused
    -- that index is total in effect. A UNIQUE constraint here would be a second
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
    CONSTRAINT users_external_id_not_empty CHECK (btrim(external_id) <> '')
);

COMMENT ON TABLE users IS 'Users and agents';
COMMENT ON COLUMN users.external_id IS 'Identity: the JWT sub claim. Users bring theirs from the authentication provider; an agent saved without one gets agent:<uuid>. Never empty.';

-- User-Role mapping
CREATE TABLE user_roles (
    id TEXT GENERATED ALWAYS AS (user_id || '.' || role_id) STORED PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    role_id INTEGER NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
    assigned_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    assigned_by INTEGER REFERENCES users(id),
    UNIQUE (user_id, role_id)
);

COMMENT ON TABLE user_roles IS 'Many-to-many mapping between users and roles';

-- Role-Permission mapping
CREATE TABLE role_permissions (
    id TEXT GENERATED ALWAYS AS (role_id || '.' || permission_name) STORED PRIMARY KEY,
    role_id INTEGER NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
    permission_name TEXT NOT NULL REFERENCES permissions(permission_name) ON DELETE CASCADE ON UPDATE CASCADE,
    granted_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    granted_by INTEGER REFERENCES users(id),
    UNIQUE (role_id, permission_name)
);

COMMENT ON TABLE role_permissions IS 'Many-to-many mapping between roles and permissions';

-- User-Permission mapping (direct per-user permissions)
CREATE TABLE user_permissions (
    id TEXT GENERATED ALWAYS AS (user_id || '.' || permission_name) STORED PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    permission_name TEXT NOT NULL REFERENCES permissions(permission_name) ON DELETE CASCADE ON UPDATE CASCADE,
    granted_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    granted_by INTEGER REFERENCES users(id),
    UNIQUE (user_id, permission_name)
);

COMMENT ON TABLE user_permissions IS 'Many-to-many mapping between users and permissions for direct per-user permission grants';

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

COMMENT ON TABLE permission_hierarchy IS 'Defines permission inclusion (including permission implies included permissions)';
COMMENT ON COLUMN permission_hierarchy.including_permission_name IS 'The broader permission that includes other permissions';
COMMENT ON COLUMN permission_hierarchy.included_permission_name IS 'The narrower permission that is included by the broader one';
COMMENT ON COLUMN permission_hierarchy.origin IS 'How this hierarchy entry was created: system (platform-seeded), model (model file), model_master (promotion/wire-up), or user (admin-created).';

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

-- modules.view_permission is a foreign key to permissions(permission_name) too,
-- but it is NOT created here: it is DEFERRABLE INITIALLY DEFERRED, and a
-- deferred check queues a pending trigger event that PostgreSQL will not let a
-- later ALTER TABLE past. Adding the constraint after the first module is
-- seeded avoids ever queuing one - see 0040_rbac_seed.sql, where it is created
-- and the reasoning is written out.

COMMENT ON COLUMN modules.module_type IS 'Module type: domain (normal) or master (promoted for sharing).';
COMMENT ON COLUMN modules.manage_permission IS 'The manage permission for this module. Populated by scaffold.';
COMMENT ON COLUMN modules.admin_permission IS 'The admin permission for this module. Populated when any entity carries edit_permission: admin.';
COMMENT ON COLUMN modules.default_viewer_role_id IS 'FK to the default viewer role for this module. Populated by scaffold.';
COMMENT ON COLUMN modules.default_manager_role_id IS 'FK to the default manager role for this module. Populated by scaffold.';
COMMENT ON COLUMN modules.default_admin_role_id IS 'FK to the default admin role for this module. Populated when admin permission is present.';

-- =====================================================
-- TRIGGERS FOR updated_at AUTOMATION
-- =====================================================

CREATE TRIGGER update_modules_updated_at
    BEFORE UPDATE ON modules
    FOR EACH ROW EXECUTE FUNCTION common.update_updated_at_column();

CREATE TRIGGER update_permissions_updated_at
    BEFORE UPDATE ON permissions
    FOR EACH ROW EXECUTE FUNCTION common.update_updated_at_column();

CREATE TRIGGER update_roles_updated_at
    BEFORE UPDATE ON roles
    FOR EACH ROW EXECUTE FUNCTION common.update_updated_at_column();

CREATE TRIGGER update_users_updated_at
    BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION common.update_updated_at_column();

-- =====================================================
-- INDEXES
-- =====================================================
-- A column a unique index already covers - whole key or leading columns of a
-- composite - gets no plain index of its own. Swept by
-- 0450_test_rbac_indexes.sql.

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
