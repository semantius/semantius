-- =====================================================
-- DASHBOARD TABLE
-- =====================================================
-- Create table for user-configured dashboards
-- =====================================================

-- =====================================================
-- CREATE dashboards TABLE
-- =====================================================

INSERT INTO entities (
    table_name,
    singular,
    singular_label,
    plural_label,
    description,
    module_id,
    view_permission,
    edit_permission,
    id_column,
    label_column
)
VALUES (
    'dashboards',
    'dashboard',
    'Dashboard',
    'Dashboards',
    'User-configured dashboard layouts and configurations',
    1, -- _core module
    'admin',
    'admin',
    'id',
    'label'
);

-- Add fields to dashboards table
INSERT INTO fields (table_name, field_name, title, format, field_order, input_type, width, description, default_value, reference_table, reference_delete_mode)
VALUES
    ('dashboards', 'config',   'Configuration', 'json',  10, 'default', 'w', 'Dashboard layout and widget configuration', '', '', ''),
    ('dashboards', 'position', 'Position',      'int32', 20, 'default', 'default', 'Display order position', '0', '', '');

INSERT INTO fields (table_name, field_name, title, format, field_order, input_type, width, description, reference_table, reference_delete_mode)
VALUES
    ('dashboards', 'module_id',       'Module',          'reference', 30, 'default', 'default', 'Module this dashboard belongs to',     'modules',     'cascade'),
    ('dashboards', 'view_permission', 'View Permission',  'reference', 40, 'default', 'default', 'Permission required to view this dashboard', 'permissions', 'clear');
