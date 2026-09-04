-- =====================================================
-- USER BOOKMARKS
-- =====================================================
-- Personal bookmarks saved by users.
-- Each bookmark belongs to a specific user and can optionally
-- reference a specific entity and record.
-- Users can only see and edit their own bookmarks.
--
-- RLS design:
--   • A BEFORE INSERT OR UPDATE trigger (aaa_assign_user_id_user_bookmarks)
--     initializes the RBAC context and forces user_id = rbac.user_id() on
--     every write, preventing users from assigning bookmarks to other users.
--     The trigger is named with the 'aaa_' prefix so PostgreSQL's alphabetical
--     trigger-firing order guarantees it runs before any other BEFORE triggers
--     (e.g. compute_validate_trigger, zz_auto_order_*).
--   • select_rule {"==": [{"var":"user_id"},{"var":"$user_id"}]} generates a
--     per-row SELECT policy (own rows only) and scopes UPDATE/DELETE USING to
--     own rows (migration 0180).
--   • The INSERT policy is further hardened to WITH CHECK (user_id = rbac.user_id())
--     as a second layer of defense (the trigger fires first and sets the value,
--     so this check always passes for legitimate callers).
--   • order_column = 'row_order' enables drag-and-drop reordering (migration 0270).

-- =====================================================
-- STEP 1: Create user_bookmarks entity
-- =====================================================

INSERT INTO entities (
    table_name, singular, singular_label, plural_label,
    description, module_id, view_permission, edit_permission,
    id_column, label_column,
    select_rule
)
VALUES (
    'user_bookmarks',
    'user_bookmark',
    'User Bookmark',
    'Favorites',
    'Manage and order your facorites for quick access to frequently used apps and records.',
    (SELECT id FROM modules WHERE module_name = '_core'),
    'user:read',
    'user:read',
    'id',
    'title',
    '{"==": [{"var": "user_id"}, {"var": "$user_id"}]}'::jsonb
);

-- =====================================================
-- STEP 2: Add fields to user_bookmarks
-- =====================================================
-- Note: 'id' (id_column), 'title' (label_column), 'created_at', 'updated_at'
-- are automatically created by the create_dd_table trigger.

INSERT INTO fields (table_name, field_name, title, description, format, field_order, input_type, width, searchable, reference_table, reference_delete_mode)
VALUES
    ('user_bookmarks', 'user_id',     'User',      'Owner of this bookmark (auto-assigned to current user)',        'reference', 10, 'hidden',  'default', FALSE, 'users', 'cascade'),
    ('user_bookmarks', 'url',         'URL',        'Bookmark URL',                                                 'text',      30, 'default', 'w',       FALSE, '',      ''),
    ('user_bookmarks', 'entity_name', 'Entity',     'Name of the related entity table',                             'text',      40, 'default', 'default', FALSE, '',      ''),
    ('user_bookmarks', 'entity_id',   'Entity ID',  'ID of the related record in the entity table (0 = no record)', 'int32',     50, 'default', 'default', FALSE, '',      '');

-- =====================================================
-- STEP 3: Auto-assign user_id on INSERT and UPDATE
-- =====================================================
-- A BEFORE INSERT OR UPDATE trigger forces user_id to the current session user.
-- It also calls rbac.ensure_context_initialized() first so that the RBAC context
-- (app.current_user_id etc.) is available to any subsequent BEFORE triggers that
-- read $user_id (e.g. compute_validate_trigger from computed_fields).
--
-- Named 'aaa_assign_user_id_user_bookmarks' so it fires first among all BEFORE
-- triggers on this table (PostgreSQL fires BEFORE triggers in alphabetical order).

CREATE OR REPLACE FUNCTION assign_user_id_user_bookmarks()
RETURNS TRIGGER AS $$
BEGIN
    PERFORM rbac.ensure_context_initialized();
    NEW.user_id := rbac.user_id();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = rbac, public;

COMMENT ON FUNCTION assign_user_id_user_bookmarks IS
'BEFORE INSERT OR UPDATE trigger for user_bookmarks: initializes the RBAC context '
'and forces user_id to the current session user so bookmarks cannot be created or '
'reassigned on behalf of other users.';

REVOKE EXECUTE ON FUNCTION assign_user_id_user_bookmarks() FROM PUBLIC;

CREATE TRIGGER aaa_assign_user_id_user_bookmarks
    BEFORE INSERT OR UPDATE ON user_bookmarks
    FOR EACH ROW
    EXECUTE FUNCTION assign_user_id_user_bookmarks();

COMMENT ON TRIGGER aaa_assign_user_id_user_bookmarks ON user_bookmarks IS
'Forces user_id to the current session user on every INSERT and UPDATE. '
'Prefixed aaa_ to run first (alphabetical order) before other BEFORE triggers.';

-- =====================================================
-- STEP 4: Harden INSERT policy
-- =====================================================
-- The default INSERT policy only checks rbac.has_permission('user:read').
-- We also require the record's user_id to match the session user, as a second
-- layer of defense.  The aaa_ trigger above fires first and sets user_id, so
-- this check always passes for legitimate callers.

DROP POLICY IF EXISTS user_bookmarks_insert_policy ON user_bookmarks;
CREATE POLICY user_bookmarks_insert_policy ON user_bookmarks
    FOR INSERT
    TO semantius_user
    WITH CHECK ((SELECT rbac.has_permission('user:read')) AND user_id = rbac.user_id());

-- =====================================================
-- STEP 5: Enable drag-and-drop row ordering
-- =====================================================
-- Triggers handle_entity_order_column() to:
--   • ALTER TABLE user_bookmarks ADD COLUMN row_order INTEGER NOT NULL DEFAULT 0
--   • install the zz_auto_order_user_bookmarks BEFORE INSERT trigger that
--     auto-assigns MAX(row_order)+10 (or 10 for the first row) when row_order=0

UPDATE entities SET order_column = 'row_order' WHERE table_name = 'user_bookmarks';
