-- =====================================================
-- TEST: user_bookmarks (migration 0410_user_bookmarks.jsonc)
-- =====================================================
-- Covers:
--   • Table and field metadata are registered correctly.
--   • user_id is auto-assigned to the current user on INSERT.
--   • user_id is always forced back to the current user on INSERT and UPDATE,
--     whatever the caller supplies, also after edit_permission changes (the
--     computed field user_id = $user_id).
--   • A write without claims is refused (platform rule 90207); a delete is not.
--   • SELECT is restricted to own rows (select_rule / RLS).
--   • UPDATE and DELETE are restricted to own rows (select_rule / RLS).
--   • row_order is auto-assigned and the order_column is registered.
BEGIN;

SELECT plan(30);

-- =====================================================
-- GROUP 1: Schema — entity and field metadata
-- =====================================================

-- Test 1: entity metadata registered
SELECT ok(
    (SELECT EXISTS (SELECT 1 FROM entities WHERE table_name = 'user_bookmarks')),
    'user_bookmarks entity metadata should exist'
);

-- Test 2: physical table created
SELECT ok(
    (SELECT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'public' AND table_name = 'user_bookmarks'
    )),
    'user_bookmarks physical table should exist'
);

-- Test 3: user_id field registered
SELECT ok(
    (SELECT EXISTS (SELECT 1 FROM fields WHERE table_name = 'user_bookmarks' AND field_name = 'user_id')),
    'user_bookmarks should have user_id field'
);

-- Test 4: user_id field is a reference to users
SELECT is(
    (SELECT reference_table FROM fields WHERE table_name = 'user_bookmarks' AND field_name = 'user_id'),
    'users',
    'user_id field should reference users table'
);

-- Test 5: url field registered
SELECT ok(
    (SELECT EXISTS (SELECT 1 FROM fields WHERE table_name = 'user_bookmarks' AND field_name = 'url')),
    'user_bookmarks should have url field'
);

-- Test 6: entity_name field registered
SELECT ok(
    (SELECT EXISTS (SELECT 1 FROM fields WHERE table_name = 'user_bookmarks' AND field_name = 'entity_name')),
    'user_bookmarks should have entity_name field'
);

-- Test 7: entity_id field registered
SELECT ok(
    (SELECT EXISTS (SELECT 1 FROM fields WHERE table_name = 'user_bookmarks' AND field_name = 'entity_id')),
    'user_bookmarks should have entity_id field'
);

-- Test 8: order_column set to row_order on entity
SELECT is(
    (SELECT order_column FROM entities WHERE table_name = 'user_bookmarks'),
    'row_order',
    'user_bookmarks entity should declare row_order as its order_column'
);

-- Test 9: row_order physical column exists
SELECT ok(
    (SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name   = 'user_bookmarks'
          AND column_name  = 'row_order'
    )),
    'row_order column should exist in user_bookmarks'
);

-- =====================================================
-- GROUP 1b: a session without claims
-- =====================================================
-- A fresh transaction carries no claims. $user_id is then null, so the
-- computed user_id would be null; rule 90207 refuses the write instead.

SELECT throws_ok(
    $$INSERT INTO user_bookmarks (title, url) VALUES ('No Claims', 'https://example.net')$$,
    '90207',
    'A bookmark can only be written by an authenticated user',
    'a bookmark write without claims is refused (rule 90207)'
);

-- A delete is exempt, so deleting a user still cascades to their bookmarks
-- from a maintenance session. The row is written the normal way, by user2;
-- then the role goes back to the connecting one and the claims are cleared, so
-- the delete runs without claims. Not with session_replication_role: setting
-- it needs superuser, which the suite must not require (Neon, Supabase).
SELECT authenticate_as('user2');
INSERT INTO user_bookmarks (title) VALUES ('Orphan Probe');
RESET ROLE;
DO $$
BEGIN
    PERFORM set_config('request.jwt.claim.sub', '', true);
    PERFORM set_config('request.jwt.claim.role', '', true);
END $$;
SELECT lives_ok(
    $$DELETE FROM user_bookmarks WHERE title = 'Orphan Probe'$$,
    'a bookmark delete without claims is allowed'
);

-- =====================================================
-- GROUP 2: user_id auto-assignment on INSERT
-- =====================================================

SELECT authenticate_as('user1');

-- Test 10: INSERT without supplying user_id; the computed field sets it to the current user
INSERT INTO user_bookmarks (title, url)
VALUES ('My Bookmark', 'https://example.com');

SELECT is(
    (SELECT user_id FROM user_bookmarks WHERE title = 'My Bookmark'),
    1001,
    'user_id should be auto-assigned to the current user (user1 = 1001) on INSERT'
);

-- Test 11: user_id is always forced to the session user, whatever the caller supplies
INSERT INTO user_bookmarks (title, url, user_id)
VALUES ('Override Attempt', 'https://example.org', 1002);

SELECT is(
    (SELECT user_id FROM user_bookmarks WHERE title = 'Override Attempt'),
    1001,
    'user_id should always be forced to the current user, ignoring any caller value'
);

-- An UPDATE cannot hand the bookmark to another user either.
UPDATE user_bookmarks SET user_id = 1002 WHERE title = 'Override Attempt';
SELECT is(
    (SELECT user_id FROM user_bookmarks WHERE title = 'Override Attempt'),
    1001,
    'an UPDATE of user_id is forced back to the current user'
);

-- Test 12: row_order is auto-assigned starting at 10
SELECT is(
    (SELECT MIN(row_order) FROM user_bookmarks WHERE user_id = 1001),
    10,
    'first bookmark should receive row_order = 10'
);

-- =====================================================
-- GROUP 3: SELECT isolation — users see only own rows
-- =====================================================

-- Add bookmarks for user3 (admin) and user2 to verify isolation
SELECT authenticate_as('user3');
INSERT INTO user_bookmarks (title, url) VALUES ('Admin Bookmark', 'https://admin.example.com');

SELECT authenticate_as('user2');
INSERT INTO user_bookmarks (title, url) VALUES ('User2 Bookmark', 'https://user2.example.com');

-- Test 13: user2 sees only own bookmark
SELECT is(
    (SELECT COUNT(*)::integer FROM user_bookmarks),
    1,
    'user2 should see exactly 1 bookmark (own row only)'
);

-- Test 14: user2 sees the correct bookmark
SELECT ok(
    (SELECT EXISTS (SELECT 1 FROM user_bookmarks WHERE title = 'User2 Bookmark')),
    'user2 should be able to see their own bookmark'
);

-- Test 15: user2 does NOT see user1 bookmark
SELECT ok(
    NOT EXISTS (SELECT 1 FROM user_bookmarks WHERE title = 'My Bookmark'),
    'user2 should NOT see user1 bookmark'
);

-- Test 16: user2 does NOT see admin bookmark
SELECT ok(
    NOT EXISTS (SELECT 1 FROM user_bookmarks WHERE title = 'Admin Bookmark'),
    'user2 should NOT see admin bookmark'
);

-- Switch to user1 and confirm they see their own rows only
SELECT authenticate_as('user1');

-- Test 17: user1 sees exactly 2 bookmarks (their own)
SELECT is(
    (SELECT COUNT(*)::integer FROM user_bookmarks),
    2,
    'user1 should see exactly 2 bookmarks (own rows only)'
);

-- =====================================================
-- GROUP 4: UPDATE isolation — users can only update own rows
-- =====================================================

-- Test 18: user1 can update their own bookmark
UPDATE user_bookmarks SET url = 'https://updated.example.com' WHERE title = 'My Bookmark';
SELECT is(
    (SELECT url FROM user_bookmarks WHERE title = 'My Bookmark'),
    'https://updated.example.com',
    'user1 should be able to update their own bookmark'
);

-- Test 19: user1 UPDATE on user2 rows silently affects 0 visible rows
-- (the USING clause from select_rule filters out rows that don't belong to user1)
SELECT authenticate_as('user1');
UPDATE user_bookmarks SET url = 'https://hijacked.example.com' WHERE title = 'User2 Bookmark';
SELECT is(
    (SELECT COUNT(*)::integer FROM user_bookmarks WHERE title = 'User2 Bookmark'),
    0,
    'user1 UPDATE on another user bookmark should affect 0 visible rows'
);

-- Test 20: user2 bookmark URL remains unchanged after user1 attempted update
SELECT authenticate_as('user2');
SELECT ok(
    (SELECT url != 'https://hijacked.example.com' FROM user_bookmarks WHERE title = 'User2 Bookmark'),
    'user2 bookmark URL should not have been changed by user1'
);

-- =====================================================
-- GROUP 5: DELETE isolation — users can only delete own rows
-- =====================================================

-- Test 21: user1 DELETE on user2 bookmark silently affects 0 rows
SELECT authenticate_as('user1');
DELETE FROM user_bookmarks WHERE title = 'User2 Bookmark';
SELECT authenticate_as('user2');
SELECT ok(
    (SELECT EXISTS (SELECT 1 FROM user_bookmarks WHERE title = 'User2 Bookmark')),
    'user2 bookmark should still exist after user1 tried to delete it'
);

-- =====================================================
-- GROUP 6: INSERT policy — user_id always forced to session user
-- =====================================================

-- Test 22: user_id is always the session user regardless of what we insert
SELECT authenticate_as('user1');
INSERT INTO user_bookmarks (title) VALUES ('Policy Check');
SELECT is(
    (SELECT user_id FROM user_bookmarks WHERE title = 'Policy Check'),
    1001,
    'INSERT policy: user_id must equal the session user (1001) after insert'
);

-- =====================================================
-- GROUP 7: Metadata integrity
-- =====================================================

-- Test 23: select_rule is set on entity
SELECT ok(
    (SELECT select_rule != '{}'::jsonb FROM entities WHERE table_name = 'user_bookmarks'),
    'user_bookmarks entity should have a non-empty select_rule'
);

-- Test 24: user_id is a computed field fed from $user_id
SELECT is(
    (SELECT computed_fields FROM entities WHERE table_name = 'user_bookmarks'),
    '[{"name": "user_id", "jsonlogic": {"var": "$user_id"}}]'::jsonb,
    'user_bookmarks derives user_id from $user_id (computed field)'
);

-- Test 25: the dictionary's compute trigger is installed on user_bookmarks
SELECT ok(
    EXISTS (SELECT 1 FROM pg_trigger
            WHERE tgrelid = 'public.user_bookmarks'::regclass
              AND tgname = 'compute_validate_trigger'
              AND tgfoid = 'public.compute_validate_user_bookmarks()'::regprocedure
              AND NOT tgisinternal),
    'compute_validate_trigger (compute_validate_user_bookmarks) should be installed'
);

-- Test 26: view_permission and edit_permission are both user:read
SELECT ok(
    (SELECT view_permission = 'user:read' AND edit_permission = 'user:read'
     FROM entities WHERE table_name = 'user_bookmarks'),
    'user_bookmarks permissions should be user:read for both view and edit'
);

-- =====================================================
-- GROUP 8: an edit_permission change keeps user_id forced
-- =====================================================
-- The dictionary rebuilds the write policies on such a change; the computed
-- field lives in the compute trigger, which that rebuild does not touch.
SELECT authenticate_as('user3');
UPDATE entities SET edit_permission = 'public:read' WHERE table_name = 'user_bookmarks';

SELECT authenticate_as('user1');
INSERT INTO user_bookmarks (title, user_id) VALUES ('After Permission Change', 1003);
SELECT is(
    (SELECT user_id FROM user_bookmarks WHERE title = 'After Permission Change'),
    1001,
    'after an edit_permission change, user_id is still forced to the current user'
);

SELECT * FROM finish();
ROLLBACK;

