-- =====================================================
-- SHIPPED RECORD RULES OF THE PLATFORM ENTITIES (0665)
-- =====================================================
-- Eight platform entities ship with rules in their metadata: entities,
-- fields, modules, roles and permission_hierarchy carry validation rules;
-- raci_assignments and process_gates derive their label from a computed
-- name; user_bookmarks sets user_id on insert, refuses an unauthenticated write and
-- reads through a select rule. modules carries a select rule of its own.
-- The dictionary turns each into generated functions
-- (common.record_rules_<t>, compute_validate_<t>, select_rule_<t>) that no
-- source file states, so this file pins them from the outside:
--   * every shipped validation rule fails once, and the error carries the
--     rule's own code and message, an empty DETAIL and the hint that names
--     the entity and the rule;
--   * a legal insert, update and delete reaches each trigger arm and passes;
--   * a computed field is recomputed on insert and update, whatever the
--     caller wrote;
--   * both shipped select rules take each of their branches, read as the
--     users that take them.
-- Fixture names carry the prefix sr_. Everything is rolled back.
-- Fixtures: user1 = plain user, user2 = Northwind Sales, user3 = administrator.

BEGIN;

SELECT plan(74);

-- The error a failed rule puts on the wire: its code as SQLSTATE, its message,
-- no DETAIL, and a hint holding the entity and the rule.
CREATE FUNCTION pg_temp.rule_error(p_code TEXT, p_message TEXT, p_entity TEXT)
RETURNS JSONB LANGUAGE sql AS $fn$
    SELECT jsonb_build_object(
        'code', p_code,
        'message', p_message,
        'details', '',
        'hint', jsonb_build_object('entity', p_entity, 'rule', p_code)::text)
$fn$;

SELECT authenticate_as('user3');

-- =====================================================
-- entities: 90201, 90233, 90253, 90245
-- =====================================================

SELECT lives_ok(
    $$INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
          module_id, view_permission, edit_permission, id_column, label_column, catalog_entity_code)
      VALUES ('sr_item', 'sr_item', 'SR Item', 'SR Items', 'record rules probe',
          1, 'public:read', 'admin', 'id', 'label', 'items')$$,
    'entities: an insert reaches the rules and passes');

SELECT is(
    (SELECT catalog_entity_code FROM entities WHERE table_name = 'sr_item'),
    'items',
    'entities: an insert may set catalog_entity_code');

SELECT is(
    catch_error($$UPDATE entities SET catalog_entity_code = 'other' WHERE table_name = 'sr_item'$$),
    pg_temp.rule_error('90201', 'catalog_entity_code is write-once: it cannot be changed once set', 'entities'),
    'entities: a set catalog_entity_code cannot be rewritten (90201)');

SELECT lives_ok(
    $$UPDATE entities SET description = 'changed' WHERE table_name = 'sr_item'$$,
    'entities: an update that leaves the guarded columns alone passes');

SELECT is(
    catch_error($$UPDATE entities SET id_type = 'uuid' WHERE table_name = 'sr_item'$$),
    pg_temp.rule_error('90233', 'id_type is set when an entity is created and cannot be changed', 'entities'),
    'entities: id_type cannot be changed after creation (90233)');

SELECT is(
    catch_error($$UPDATE entities SET id_column = 'key' WHERE table_name = 'sr_item'$$),
    pg_temp.rule_error('90253', 'id_column is set when an entity is created and cannot be changed', 'entities'),
    'entities: id_column cannot be changed after creation (90253)');

-- A typeid root and an is_a entity under it. The prefix of the root can
-- change; the prefix of the is_a entity is fixed when it is created.
INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, type_prefix)
VALUES ('sr_root', 'SR Root', 'SR Roots', 1, 'typeid', 'srroot');
INSERT INTO entities (table_name, singular_label, plural_label, module_id, id_type, type_prefix, id_refentity)
VALUES ('sr_sub', 'SR Sub', 'SR Subs', 1, 'is_a', 'srsub', 'sr_root');

SELECT is(
    catch_error($$UPDATE entities SET type_prefix = 'srsubx' WHERE table_name = 'sr_sub'$$),
    pg_temp.rule_error('90245', 'type_prefix of an is_a entity is set when it is created', 'entities'),
    'entities: the type_prefix of an is_a entity cannot be changed (90245)');

SELECT lives_ok(
    $$UPDATE entities SET type_prefix = 'srrootx' WHERE table_name = 'sr_root'$$,
    'entities: the type_prefix of a typeid root can be changed');

-- =====================================================
-- fields: 90202
-- =====================================================

SELECT lives_ok(
    $$INSERT INTO fields (table_name, field_name, title, format, field_order, catalog_field_code)
      VALUES ('sr_item', 'sr_note', 'Note', 'text', 10, 'note')$$,
    'fields: an insert reaches the rules and passes');

SELECT is(
    (SELECT catalog_field_code FROM fields WHERE table_name = 'sr_item' AND field_name = 'sr_note'),
    'note',
    'fields: an insert may set catalog_field_code');

SELECT is(
    catch_error($$UPDATE fields SET catalog_field_code = 'other'
                   WHERE table_name = 'sr_item' AND field_name = 'sr_note'$$),
    pg_temp.rule_error('90202', 'catalog_field_code is write-once: it cannot be changed once set', 'fields'),
    'fields: a set catalog_field_code cannot be rewritten (90202)');

SELECT lives_ok(
    $$UPDATE fields SET title = 'Remark' WHERE table_name = 'sr_item' AND field_name = 'sr_note'$$,
    'fields: an update that leaves catalog_field_code alone passes');

SELECT lives_ok(
    $$DELETE FROM fields WHERE table_name = 'sr_item' AND field_name = 'sr_note'$$,
    'fields: a delete reaches the rules and passes');

SELECT is(
    (SELECT count(*)::int FROM fields WHERE table_name = 'sr_item' AND field_name = 'sr_note'),
    0,
    'fields: the deleted field is gone');

-- The entity's own delete runs the entities rules with $mode = delete.
SELECT lives_ok(
    $$DELETE FROM entities WHERE table_name = 'sr_item'$$,
    'entities: a delete reaches the rules and passes');

SELECT is(
    (SELECT count(*)::int FROM entities WHERE table_name = 'sr_item')
    + (SELECT count(*)::int FROM pg_class WHERE relnamespace = 'public'::regnamespace AND relname = 'sr_item'),
    0,
    'entities: the deleted entity and its table are gone');

-- =====================================================
-- modules: 90701, 90702
-- =====================================================

SELECT lives_ok(
    $$INSERT INTO modules (module_name, module_slug, catalog_module_code)
      VALUES ('SR Module', 'sr_module', 'SR-MOD')$$,
    'modules: an insert reaches the rules and passes');

SELECT is(
    catch_error($$UPDATE modules SET catalog_module_code = 'OTHER' WHERE module_slug = 'sr_module'$$),
    pg_temp.rule_error('90701', 'catalog_module_code is write-once: it cannot be changed once set', 'modules'),
    'modules: a set catalog_module_code cannot be rewritten (90701)');

SELECT is(
    catch_error($$INSERT INTO modules (module_name, module_slug) VALUES ('SR Bad Slug', 'Bad Slug')$$),
    pg_temp.rule_error('90702',
        'module_slug must be lowercase, start with a letter or digit, and contain only a-z, 0-9, ''-'' and ''_''',
        'modules'),
    'modules: an insert with a malformed module_slug fails (90702)');

SELECT is(
    catch_error($$UPDATE modules SET module_slug = 'Bad Slug' WHERE module_slug = 'sr_module'$$),
    pg_temp.rule_error('90702',
        'module_slug must be lowercase, start with a letter or digit, and contain only a-z, 0-9, ''-'' and ''_''',
        'modules'),
    'modules: an update to a malformed module_slug fails (90702)');

SELECT lives_ok(
    $$UPDATE modules SET description = 'changed' WHERE module_slug = 'sr_module'$$,
    'modules: an update that leaves the guarded columns alone passes');

SELECT lives_ok(
    $$DELETE FROM modules WHERE module_slug = 'sr_module'$$,
    'modules: a delete reaches the rules and passes');

SELECT is(
    (SELECT count(*)::int FROM modules WHERE module_slug = 'sr_module'),
    0,
    'modules: the deleted module is gone');

-- =====================================================
-- roles: 90203, 90204, 90206
-- =====================================================

SELECT lives_ok(
    $$INSERT INTO roles (role_name, slug, catalog_role_code) VALUES ('SR Role', 'sr_role', 'sr-role')$$,
    'roles: an insert reaches the rules and passes');

SELECT is(
    catch_error($$UPDATE roles SET origin = 'model' WHERE slug = 'sr_role'$$),
    pg_temp.rule_error('90203', 'roles.origin is set on INSERT and cannot be changed', 'roles'),
    'roles: origin cannot be changed after the insert (90203)');

SELECT is(
    catch_error($$UPDATE roles SET slug = 'changed_slug' WHERE role_name = 'Administrator'$$),
    pg_temp.rule_error('90204', 'system role slugs cannot be changed after creation', 'roles'),
    'roles: the slug of a system role cannot be changed (90204)');

SELECT lives_ok(
    $$UPDATE roles SET slug = 'sr_role_renamed' WHERE slug = 'sr_role'$$,
    'roles: the slug of a user role can be changed');

SELECT is(
    catch_error($$UPDATE roles SET catalog_role_code = 'other' WHERE slug = 'sr_role_renamed'$$),
    pg_temp.rule_error('90206', 'catalog_role_code is write-once: it cannot be changed once set', 'roles'),
    'roles: a set catalog_role_code cannot be rewritten (90206)');

SELECT lives_ok(
    $$DELETE FROM roles WHERE slug = 'sr_role_renamed'$$,
    'roles: a delete reaches the rules and passes');

SELECT is(
    (SELECT count(*)::int FROM roles WHERE slug = 'sr_role_renamed'),
    0,
    'roles: the deleted role is gone');

-- =====================================================
-- permission_hierarchy: 90205
-- =====================================================

INSERT INTO permissions (permission_name, description, module_id) VALUES
    ('sr:a', 'record rules probe a', 1),
    ('sr:b', 'record rules probe b', 1),
    ('sr:c', 'record rules probe c', 1);

SELECT lives_ok(
    $$INSERT INTO permission_hierarchy (including_permission_name, included_permission_name)
      VALUES ('sr:a', 'sr:b')$$,
    'permission_hierarchy: an insert reaches the rules and passes');

SELECT is(
    catch_error($$UPDATE permission_hierarchy SET origin = 'model_master'
                   WHERE including_permission_name = 'sr:a'$$),
    pg_temp.rule_error('90205', 'permission_hierarchy.origin is set on INSERT and cannot be changed', 'permission_hierarchy'),
    'permission_hierarchy: origin cannot be changed after the insert (90205)');

SELECT lives_ok(
    $$UPDATE permission_hierarchy SET included_permission_name = 'sr:c'
       WHERE including_permission_name = 'sr:a'$$,
    'permission_hierarchy: an update that leaves origin alone passes');

SELECT lives_ok(
    $$DELETE FROM permission_hierarchy WHERE including_permission_name = 'sr:a'$$,
    'permission_hierarchy: a delete reaches the rules and passes');

SELECT is(
    (SELECT count(*)::int FROM permission_hierarchy WHERE including_permission_name = 'sr:a'),
    0,
    'permission_hierarchy: the deleted edge is gone');

-- =====================================================
-- raci_assignments and process_gates: the computed name
-- =====================================================

INSERT INTO processes (module_id, process_key, name) VALUES (1, 'sr_process', 'SR Process');
INSERT INTO roles (role_name, slug) VALUES ('SR Raci Role', 'sr_raci_role');

SELECT lives_ok(
    $$INSERT INTO raci_assignments (process_id, role_id, raci, name)
      SELECT p.id, r.id, 'responsible', 'typed by the caller'
        FROM processes p, roles r
       WHERE p.process_key = 'sr_process' AND r.slug = 'sr_raci_role'$$,
    'raci_assignments: an insert reaches the computed name');

SELECT is(
    (SELECT name FROM raci_assignments WHERE role_id = (SELECT id FROM roles WHERE slug = 'sr_raci_role')),
    'responsible',
    'raci_assignments: an insert derives name from raci, whatever the caller wrote');

UPDATE raci_assignments SET raci = 'consulted'
 WHERE role_id = (SELECT id FROM roles WHERE slug = 'sr_raci_role');

SELECT is(
    (SELECT name FROM raci_assignments WHERE role_id = (SELECT id FROM roles WHERE slug = 'sr_raci_role')),
    'consulted',
    'raci_assignments: an update derives name from the new raci');

UPDATE raci_assignments SET name = 'typed again'
 WHERE role_id = (SELECT id FROM roles WHERE slug = 'sr_raci_role');

SELECT is(
    (SELECT name FROM raci_assignments WHERE role_id = (SELECT id FROM roles WHERE slug = 'sr_raci_role')),
    'consulted',
    'raci_assignments: an update that writes name gets the derived value back');

SELECT lives_ok(
    $$DELETE FROM raci_assignments WHERE role_id = (SELECT id FROM roles WHERE slug = 'sr_raci_role')$$,
    'raci_assignments: a delete reaches the computed name and passes');

SELECT is(
    (SELECT count(*)::int FROM raci_assignments WHERE role_id = (SELECT id FROM roles WHERE slug = 'sr_raci_role')),
    0,
    'raci_assignments: the deleted assignment is gone');

-- A gate names an entity (a foreign key), so the governed entity exists first.
INSERT INTO entities (table_name, singular_label, plural_label, module_id, view_permission, edit_permission)
VALUES ('sr_probe', 'SR Probe', 'SR Probes', 1, 'public:read', 'admin');
INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('sr_probe', 'status', 'Status', 'text', 20);

SELECT lives_ok(
    $$INSERT INTO process_gates (process_id, entity, gate_kind, to_state, name)
      SELECT id, 'sr_probe', 'approval', 'approved', 'typed by the caller'
        FROM processes WHERE process_key = 'sr_process'$$,
    'process_gates: an insert reaches the computed name');

SELECT is(
    (SELECT name FROM process_gates WHERE entity = 'sr_probe'),
    'approval',
    'process_gates: an insert derives name from gate_kind, whatever the caller wrote');

UPDATE process_gates SET gate_kind = 'transition' WHERE entity = 'sr_probe';

SELECT is(
    (SELECT name FROM process_gates WHERE entity = 'sr_probe'),
    'transition',
    'process_gates: an update derives name from the new gate_kind');

SELECT lives_ok(
    $$DELETE FROM process_gates WHERE entity = 'sr_probe'$$,
    'process_gates: a delete reaches the computed name and passes');

SELECT is(
    (SELECT count(*)::int FROM process_gates WHERE entity = 'sr_probe'),
    0,
    'process_gates: the deleted gate is gone');

-- =====================================================
-- user_bookmarks: the computed user_id, rule 90207, the select rule
-- =====================================================

SELECT authenticate_as('user2');

SELECT lives_ok(
    $$INSERT INTO user_bookmarks (title, user_id)
      VALUES ('sr user2 bookmark', (SELECT id FROM users WHERE external_id = 'user3'))$$,
    'user_bookmarks: an insert naming another user_id passes');

SELECT is(
    (SELECT u.external_id FROM user_bookmarks b JOIN users u ON u.id = b.user_id WHERE b.title = 'sr user2 bookmark'),
    'user2',
    'user_bookmarks: an insert derives user_id from the caller, whatever the caller wrote');

UPDATE user_bookmarks SET title = 'sr user2 renamed', user_id = (SELECT id FROM users WHERE external_id = 'user3')
 WHERE title = 'sr user2 bookmark';

SELECT is(
    (SELECT u.external_id FROM user_bookmarks b JOIN users u ON u.id = b.user_id WHERE b.title = 'sr user2 renamed'),
    'user2',
    'user_bookmarks: an update keeps the owner, whatever the caller wrote');

-- A write without claims is refused by rule 90207. The claims are dropped
-- after the role is reset, so the statements run as the connecting role with
-- no identity.
RESET ROLE;
SET LOCAL search_path TO public, pgtap;
DO $$
BEGIN
    PERFORM set_config('request.jwt.claim.sub', '', true);
    PERFORM set_config('request.jwt.claim.role', '', true);
END $$;

SELECT is(
    catch_error($$INSERT INTO user_bookmarks (title) VALUES ('sr no claims')$$),
    pg_temp.rule_error('90207', 'A bookmark can only be written by an authenticated user', 'user_bookmarks'),
    'user_bookmarks: an insert without claims fails (90207)');

SELECT is(
    catch_error($$UPDATE user_bookmarks SET title = 'sr no claims' WHERE title = 'sr user2 renamed'$$),
    pg_temp.rule_error('90207', 'A bookmark can only be written by an authenticated user', 'user_bookmarks'),
    'user_bookmarks: an update without claims fails (90207)');

SELECT lives_ok(
    $$DELETE FROM user_bookmarks WHERE title = 'sr user2 renamed'$$,
    'user_bookmarks: a delete without claims passes, so deleting a user still cascades');

SELECT is(
    (SELECT count(*)::int FROM user_bookmarks WHERE title = 'sr user2 renamed'),
    0,
    'user_bookmarks: the deleted bookmark is gone');

-- =====================================================
-- select_rule_user_bookmarks: own rows only, for every caller
-- =====================================================

SELECT authenticate_as('user1');
INSERT INTO user_bookmarks (title) VALUES ('sr user1 bookmark');
SELECT authenticate_as('user2');
INSERT INTO user_bookmarks (title) VALUES ('sr user2 bookmark');
SELECT authenticate_as('user3');
INSERT INTO user_bookmarks (title) VALUES ('sr user3 bookmark');

-- The rule function is evaluated here without the policy in front of it: the
-- session is the connecting role, so every row is a candidate, and the
-- claims still say who is asking.
SELECT authenticate_as('user1');
RESET ROLE;
SET LOCAL search_path TO public, pgtap;
SELECT is(
    (SELECT string_agg(title, ',' ORDER BY title) FROM user_bookmarks b
      WHERE title LIKE 'sr user_ bookmark' AND public.select_rule_user_bookmarks(b)),
    'sr user1 bookmark',
    'select_rule_user_bookmarks: user1 passes its own bookmark only');

SELECT authenticate_as('user2');
RESET ROLE;
SET LOCAL search_path TO public, pgtap;
SELECT is(
    (SELECT string_agg(title, ',' ORDER BY title) FROM user_bookmarks b
      WHERE title LIKE 'sr user_ bookmark' AND public.select_rule_user_bookmarks(b)),
    'sr user2 bookmark',
    'select_rule_user_bookmarks: user2 passes its own bookmark only');

SELECT authenticate_as('user3');
RESET ROLE;
SET LOCAL search_path TO public, pgtap;
SELECT is(
    (SELECT string_agg(title, ',' ORDER BY title) FROM user_bookmarks b
      WHERE title LIKE 'sr user_ bookmark' AND public.select_rule_user_bookmarks(b)),
    'sr user3 bookmark',
    'select_rule_user_bookmarks: the administrator passes its own bookmark only');

-- With the context handed in, the verdict follows the $user_id it carries.
SELECT is(
    (SELECT string_agg(title, ',' ORDER BY title) FROM user_bookmarks b
      WHERE title LIKE 'sr user_ bookmark'
        AND public.select_rule_user_bookmarks(b,
              jsonb_build_object('$user_id', (SELECT id FROM users WHERE external_id = 'user1')))),
    'sr user1 bookmark',
    'select_rule_user_bookmarks: a context naming user1 passes user1''s bookmark');

SELECT is(
    (SELECT public.select_rule_user_bookmarks(b, '{}'::jsonb) FROM user_bookmarks b WHERE title = 'sr user1 bookmark'),
    false,
    'select_rule_user_bookmarks: a context without $user_id passes nothing');

-- Through the policy.
SELECT authenticate_as('user1');
SELECT is(
    (SELECT string_agg(title, ',' ORDER BY title) FROM user_bookmarks WHERE title LIKE 'sr user_ bookmark'),
    'sr user1 bookmark',
    'user_bookmarks: user1 reads its own bookmark and not those of user2 and user3');

SELECT authenticate_as('user2');
SELECT is(
    (SELECT string_agg(title, ',' ORDER BY title) FROM user_bookmarks WHERE title LIKE 'sr user_ bookmark'),
    'sr user2 bookmark',
    'user_bookmarks: user2 reads its own bookmark and not those of user1 and user3');

SELECT authenticate_as('user3');
SELECT is(
    (SELECT string_agg(title, ',' ORDER BY title) FROM user_bookmarks WHERE title LIKE 'sr user_ bookmark'),
    'sr user3 bookmark',
    'user_bookmarks: the administrator reads its own bookmark and not those of user1 and user2');

SELECT lives_ok(
    $$DELETE FROM user_bookmarks WHERE title = 'sr user3 bookmark'$$,
    'user_bookmarks: a delete of an own bookmark passes');

SELECT is(
    (SELECT count(*)::int FROM user_bookmarks WHERE title = 'sr user3 bookmark'),
    0,
    'user_bookmarks: the deleted bookmark is gone');

-- =====================================================
-- select_rule_modules: admin, or the module's view_permission
-- =====================================================
-- Three fixture modules: one anybody with user:read sees (the column default),
-- one behind a permission nobody holds, one with an empty view_permission.

SELECT authenticate_as('user3');
INSERT INTO modules (module_name, module_slug) VALUES ('SR Open', 'sr_open');
INSERT INTO modules (module_name, module_slug, view_permission) VALUES ('SR Hidden', 'sr_hidden', 'sr:nobody');
INSERT INTO modules (module_name, module_slug, view_permission) VALUES ('SR Blank', 'sr_blank', '');

-- The rule function itself, with the policy out of the way: the session is the
-- connecting role, so every module is a candidate, and the claims still say
-- who is asking. The reads below look at the platform module, the Northwind
-- module and the fixtures only.
SELECT authenticate_as('user1');
RESET ROLE;
SET LOCAL search_path TO public, pgtap;
SELECT is(
    (SELECT string_agg(module_slug, ',' ORDER BY module_slug) FROM modules m
      WHERE (module_slug IN ('admin', 'nwind') OR module_slug LIKE 'sr\_%')
        AND public.select_rule_modules(m)),
    'sr_open',
    'select_rule_modules: user1 passes the module its view permission names, and neither the others nor an empty one');

-- The two-argument form reads view_permission from the row merged with the
-- context, so a context that carries one decides.
SELECT is(
    (SELECT public.select_rule_modules(m, '{"view_permission": "user:read"}'::jsonb)
       FROM modules m WHERE module_slug = 'sr_hidden'),
    true,
    'select_rule_modules: a context that names a held permission lets the module through');

SELECT is(
    (SELECT public.select_rule_modules(m, '{}'::jsonb) FROM modules m WHERE module_slug = 'sr_hidden'),
    false,
    'select_rule_modules: a context that names nothing leaves the row''s own view permission in force');

SELECT authenticate_as('user2');
RESET ROLE;
SET LOCAL search_path TO public, pgtap;
SELECT is(
    (SELECT string_agg(module_slug, ',' ORDER BY module_slug) FROM modules m
      WHERE (module_slug IN ('admin', 'nwind') OR module_slug LIKE 'sr\_%')
        AND public.select_rule_modules(m)),
    'nwind,sr_open',
    'select_rule_modules: user2 adds the Northwind module through nwind:view');

SELECT authenticate_as('user3');
RESET ROLE;
SET LOCAL search_path TO public, pgtap;
SELECT is(
    (SELECT string_agg(module_slug, ',' ORDER BY module_slug) FROM modules m
      WHERE (module_slug IN ('admin', 'nwind') OR module_slug LIKE 'sr\_%')
        AND public.select_rule_modules(m)),
    'admin,nwind,sr_blank,sr_hidden,sr_open',
    'select_rule_modules: the administrator passes every module, one with an empty or unheld view permission included');

-- Through the policy.
SELECT authenticate_as('user1');
SELECT is(
    (SELECT string_agg(module_slug, ',' ORDER BY module_slug) FROM modules
      WHERE module_slug IN ('admin', 'nwind') OR module_slug LIKE 'sr\_%'),
    'sr_open',
    'modules: user1 reads the open module only');

SELECT authenticate_as('user2');
SELECT is(
    (SELECT string_agg(module_slug, ',' ORDER BY module_slug) FROM modules
      WHERE module_slug IN ('admin', 'nwind') OR module_slug LIKE 'sr\_%'),
    'nwind,sr_open',
    'modules: user2 reads the Northwind module and the open one');

SELECT authenticate_as('user3');
SELECT is(
    (SELECT string_agg(module_slug, ',' ORDER BY module_slug) FROM modules
      WHERE module_slug IN ('admin', 'nwind') OR module_slug LIKE 'sr\_%'),
    'admin,nwind,sr_blank,sr_hidden,sr_open',
    'modules: the administrator reads every module');

-- A session with no valid claims cannot be told who is asking. The one-argument
-- form raises at the request context; the two-argument form takes the context
-- as given, finds the permission check refused, and answers false instead of
-- raising, so a row can never be exposed by an evaluation error.
SELECT authenticate_as('user1');
RESET ROLE;
SET LOCAL search_path TO public, pgtap;
DO $$
BEGIN
    PERFORM set_config('request.jwt.claim.sub', '', true);
    PERFORM set_config('request.jwt.claim.role', '', true);
END $$;

SELECT throws_ok(
    $$SELECT public.select_rule_modules(m) FROM modules m WHERE module_slug = 'sr_open'$$,
    '42501', NULL,
    'select_rule_modules: without claims the request context refuses before the rule runs');

SELECT throws_ok(
    $$SELECT rbac.has_permission('user:read')$$,
    '42501', NULL,
    'rbac.has_permission: without claims the permission check raises, which is the error the rule function swallows');

SELECT is(
    (SELECT public.select_rule_modules(m, '{}'::jsonb) FROM modules m WHERE module_slug = 'sr_open'),
    false,
    'select_rule_modules: an evaluation error answers false, never true');

SELECT * FROM finish();
ROLLBACK;
