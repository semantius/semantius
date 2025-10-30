-- =====================================================
-- RBAC SYSTEM - DDL (Tables, Indexes, Constraints)
-- =====================================================
-- NOTE: This file requires common_schema.sql to be executed first

-- =====================================================
-- MODULES
-- =====================================================

-- Modules: Logical groupings for roles and permissions
CREATE TABLE modules (
    module_id SERIAL PRIMARY KEY,
    module_name TEXT UNIQUE NOT NULL,
    description TEXT,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

COMMENT ON TABLE modules IS 'Logical modules that group related roles and permissions';

-- =====================================================
-- PERMISSIONS AND ROLES
-- =====================================================

-- Permissions: Basic permissions in the system
CREATE TABLE permissions (
    permission_id SERIAL PRIMARY KEY,
    permission_name TEXT UNIQUE NOT NULL,
    description TEXT,
    module_id INTEGER REFERENCES modules(module_id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

COMMENT ON TABLE permissions IS 'System permissions that can be assigned to roles and organized via hierarchy';
COMMENT ON COLUMN permissions.module_id IS 'Optional reference to a module for logical grouping';

-- Roles: Groups of permissions
CREATE TABLE roles (
    role_id SERIAL PRIMARY KEY,
    role_name TEXT UNIQUE NOT NULL,
    description TEXT,
    module_id INTEGER REFERENCES modules(module_id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

COMMENT ON TABLE roles IS 'Groups of permissions that can be assigned to users';
COMMENT ON COLUMN roles.module_id IS 'Optional reference to a module for logical grouping';

-- Users: External users from JWT
CREATE TABLE users (
    user_id SERIAL PRIMARY KEY,
    external_id TEXT UNIQUE NOT NULL,
    email TEXT,
    is_disabled BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    last_seen TIMESTAMPTZ
);

COMMENT ON TABLE users IS 'External users synchronized from JWT tokens';
COMMENT ON COLUMN users.external_id IS 'External identifier from authentication provider (e.g., Auth0, Firebase)';

-- User-Role mapping
CREATE TABLE user_roles (
    user_id INTEGER NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    role_id INTEGER NOT NULL REFERENCES roles(role_id) ON DELETE CASCADE,
    assigned_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    assigned_by INTEGER REFERENCES users(user_id),
    PRIMARY KEY (user_id, role_id)
);

COMMENT ON TABLE user_roles IS 'Many-to-many mapping between users and roles';

-- Role-Permission mapping
CREATE TABLE role_permissions (
    role_id INTEGER NOT NULL REFERENCES roles(role_id) ON DELETE CASCADE,
    permission_id INTEGER NOT NULL REFERENCES permissions(permission_id) ON DELETE CASCADE,
    granted_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    granted_by INTEGER REFERENCES users(user_id),
    PRIMARY KEY (role_id, permission_id)
);

COMMENT ON TABLE role_permissions IS 'Many-to-many mapping between roles and permissions';

-- =====================================================
-- PERMISSION HIERARCHY
-- =====================================================

-- Permission hierarchy: Defines which permissions imply others
-- Example: customer.manage implies customer.read and customer.write
CREATE TABLE permission_hierarchy (
    parent_permission_name TEXT NOT NULL REFERENCES permissions(permission_name) ON DELETE CASCADE,
    child_permission_name TEXT NOT NULL REFERENCES permissions(permission_name) ON DELETE CASCADE,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (parent_permission_name, child_permission_name),
    CONSTRAINT no_self_reference CHECK (parent_permission_name != child_permission_name)
);

COMMENT ON TABLE permission_hierarchy IS 'Defines permission inheritance (parent implies children)';
COMMENT ON COLUMN permission_hierarchy.parent_permission_name IS 'Parent permission that implies child permissions';
COMMENT ON COLUMN permission_hierarchy.child_permission_name IS 'Child permission implied by parent';

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
-- INDEXES - Modules
-- =====================================================

CREATE INDEX idx_modules_name ON modules(module_name);

-- =====================================================
-- INDEXES - Permissions
-- =====================================================

CREATE INDEX idx_permissions_name ON permissions(permission_name);
CREATE INDEX idx_permissions_module ON permissions(module_id);

-- =====================================================
-- INDEXES - Roles
-- =====================================================

CREATE INDEX idx_roles_name ON roles(role_name);
CREATE INDEX idx_roles_module ON roles(module_id);
CREATE INDEX idx_role_permissions_role ON role_permissions(role_id);
CREATE INDEX idx_role_permissions_permission ON role_permissions(permission_id);
CREATE INDEX idx_role_permissions_granted_by ON role_permissions(granted_by);

-- =====================================================
-- INDEXES - Users
-- =====================================================

CREATE INDEX idx_users_external_id ON users(external_id);
CREATE INDEX idx_users_email ON users(email);
CREATE INDEX idx_users_enabled ON users(is_disabled) WHERE is_disabled = FALSE;
CREATE INDEX idx_users_disabled ON users(is_disabled) WHERE is_disabled = TRUE;

-- =====================================================
-- INDEXES - User Roles
-- =====================================================

CREATE INDEX idx_user_roles_user ON user_roles(user_id);
CREATE INDEX idx_user_roles_role ON user_roles(role_id);
CREATE INDEX idx_user_roles_assigned_by ON user_roles(assigned_by);

-- =====================================================
-- INDEXES - Permission Hierarchy
-- =====================================================

CREATE INDEX idx_permission_hierarchy_parent ON permission_hierarchy(parent_permission_name);
CREATE INDEX idx_permission_hierarchy_child ON permission_hierarchy(child_permission_name);