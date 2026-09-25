-- =====================================================
-- ensure_entities (0290_ensure_entities.sql)
-- =====================================================
-- What a .jsonc migration relies on: a first apply creates the module
-- sections, entities, fields and records; applying the same definition again
-- writes nothing at all (checked by row position, ctid, which every UPDATE
-- moves); a partial definition changes only what it names; array order is
-- column order; omitted and null mean different things; the columns that name
-- fields (label_parent, computed_fields, validation_rules, select_rule) are in
-- place before any record is written; nothing is ever deleted; and every value
-- a trigger would rewrite, and every change that is not additive, is refused.
--
-- Runs as the installing superuser, like a migration; everything is rolled
-- back.
BEGIN;

SELECT plan(38);

CREATE TEMP TABLE ee_doc (doc JSONB);
INSERT INTO ee_doc VALUES (jsonc_to_jsonb($jsonc$
// A module with its own permissions, role and grant, and four entities.
{
  "version": 1,
  "module": {
    "module_name": "EE Test",
    "module_slug": "eetest",
    "description": "ensure_entities test module",
    "view_permission": "eetest:view",
    "manage_permission": "eetest:manage",
    "default_manager_role_slug": "eetest_mgr"
  },
  "permissions": [
    {"permission_name": "eetest:view", "description": "View"},
    {"permission_name": "eetest:manage", "description": "Manage"}
  ],
  "permission_hierarchy": [
    {"including_permission_name": "eetest:manage", "included_permission_name": "eetest:view"}
  ],
  "roles": [{"slug": "eetest_mgr", "role_name": "EE Test Manager", "origin": "model"}],
  "role_permissions": [{"role_slug": "eetest_mgr", "permission_name": "eetest:manage"}],
  "entities": [
    {
      "entity": {
        "table_name": "ee_items",
        "module_name": "EE Test",
        "singular_label": "Item",
        "plural_label": "Items",
        "view_permission": "eetest:view",
        "edit_permission": "eetest:manage",
        "order_column": "position",
        "select_rule": {"!=": [{"var": "label"}, "hidden"]},
        "validation_rules": [
          {"code": "99101", "message": "price must not be negative", "jsonlogic": {">=": [{"var": "price"}, 0]}}
        ],
        // array order is creation order, hence column order
        "fields": [
          {"field_name": "zeta",  "title": "Zeta",  "format": "text",  "field_order": 30},
          {"field_name": "alpha", "title": "Alpha", "format": "text",  "field_order": 40},
          {"field_name": "mid",   "title": "Mid",   "format": "int32", "field_order": 50, "description": "a number"},
          {"field_name": "price", "title": "Price", "format": "int32", "field_order": 60},
        ]
      },
      "records": [
        {"id": 10, "label": "one",   "zeta": "z1", "alpha": "a1", "mid": 1, "price": 5},
        {"id": 20, "label": "two",   "zeta": "z2", "alpha": "a2", "mid": 2, "price": 6},
        {"id": 30, "label": "three", "zeta": "z3", "alpha": "a3", "mid": 3, "price": 7}
      ]
    },
    {
      "entity": {
        "table_name": "ee_lines",
        "module_name": "EE Test",
        "singular_label": "Line",
        "plural_label": "Lines",
        "view_permission": "eetest:view",
        "edit_permission": "eetest:manage",
        "label_parent": "item_id",
        "computed_fields": [{"name": "total", "jsonlogic": {"+": [{"var": "qty"}, {"var": "qty"}]}}],
        "fields": [
          {"field_name": "item_id", "title": "Item", "format": "parent", "reference_table": "ee_items",
           "reference_delete_mode": "cascade", "field_order": 10},
          {"field_name": "qty",   "title": "Qty",   "format": "int32", "field_order": 30},
          {"field_name": "total", "title": "Total", "format": "int32", "field_order": 40}
        ]
      },
      "records": [{"id": 1, "item_id": 20, "label": "l1", "qty": 3, "total": 999}]
    },
    {
      "entity": {
        "table_name": "ee_ghosts",
        "module_name": "EE Test",
        "singular_label": "Ghost",
        "plural_label": "Ghosts",
        "managed": false,
        "fields": [
          {"field_name": "id",   "title": "Id",   "format": "int32", "is_pk": true, "ctype": "id",    "field_order": 1},
          {"field_name": "name", "title": "Name", "format": "text",                 "ctype": "label", "field_order": 10}
        ]
      }
    }
  ]
}
$jsonc$));

-- ---------------------------------------------------------------- create
SELECT lives_ok($$SELECT ensure_entities((SELECT doc FROM ee_doc))$$, 'a first apply succeeds');

SELECT is((SELECT count(*)::int FROM permissions WHERE permission_name LIKE 'eetest:%'), 2,
    'module section: the permissions are created');
SELECT ok(EXISTS (SELECT 1 FROM permission_hierarchy
                   WHERE including_permission_name = 'eetest:manage' AND included_permission_name = 'eetest:view'),
    'module section: the hierarchy row is created');
SELECT ok(EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                   WHERE r.slug = 'eetest_mgr' AND rp.permission_name = 'eetest:manage'),
    'module section: the role and its grant are created');
SELECT is((SELECT view_permission || '|' || manage_permission FROM modules WHERE module_name = 'EE Test'),
    'eetest:view|eetest:manage',
    'module section: the permission columns are written once the permissions exist');
SELECT is((SELECT default_manager_role_id FROM modules WHERE module_name = 'EE Test'),
    (SELECT id FROM roles WHERE slug = 'eetest_mgr'),
    'module section: a default role is given by slug and stored as its id');

SELECT is(
    (SELECT array_agg(attname::TEXT ORDER BY attnum) FROM pg_attribute
      WHERE attrelid = 'public.ee_items'::regclass AND attname IN ('zeta', 'alpha', 'mid', 'price')),
    ARRAY['zeta', 'alpha', 'mid', 'price'],
    'array order is the physical column order');
SELECT is((SELECT description FROM fields WHERE id = 'ee_items.alpha'), '',
    'an omitted key takes the column default on insert');
SELECT is((SELECT description FROM fields WHERE id = 'ee_items.mid'), 'a number',
    'a given key is written');
SELECT ok(to_regclass('public.ee_ghosts') IS NULL
          AND (SELECT NOT managed FROM entities WHERE table_name = 'ee_ghosts'),
    'managed: false registers the entity without a table');
SELECT is((SELECT string_agg(field_name || ':' || ctype, ',' ORDER BY field_order) FROM fields WHERE table_name = 'ee_ghosts'),
    'id:id,name:label',
    'the fields of an unmanaged entity are registered, ctype included');
SELECT is((SELECT label_parent FROM entities WHERE table_name = 'ee_lines'), 'item_id',
    'label_parent may name a field defined in the same file');
SELECT ok(EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'ee_items'
                   AND policyname = 'ee_items_select_policy' AND qual LIKE '%select_rule_ee_items%'),
    'select_rule is applied');

SELECT is((SELECT string_agg(id || ':' || label, ',' ORDER BY id) FROM ee_items), '10:one,20:two,30:three',
    'records are inserted with their ids');
SELECT is((SELECT total FROM ee_lines WHERE id = 1), 6,
    'records are written under the computed fields, and a computed column in a record is not written');
SELECT cmp_ok((SELECT nextval('public.ee_items_id_seq')), '>', 30::bigint,
    'the id sequence is moved past the highest id');

-- ------------------------------------------------- unchanged: no write
CREATE TEMP TABLE ee_snapshot AS
    SELECT 'entity ' || table_name AS k, ctid::TEXT AS c FROM entities WHERE table_name LIKE 'ee\_%'
    UNION ALL SELECT 'field ' || id, ctid::TEXT FROM fields WHERE table_name LIKE 'ee\_%'
    UNION ALL SELECT 'module', ctid::TEXT FROM modules WHERE module_name = 'EE Test'
    UNION ALL SELECT 'permission ' || permission_name, ctid::TEXT FROM permissions WHERE permission_name LIKE 'eetest:%'
    UNION ALL SELECT 'role', ctid::TEXT FROM roles WHERE slug = 'eetest_mgr'
    UNION ALL SELECT 'item ' || id, ctid::TEXT FROM ee_items
    UNION ALL SELECT 'line ' || id, ctid::TEXT FROM ee_lines;

SELECT is(
    ensure_entities((SELECT doc FROM ee_doc)) #> '{entities}',
    '{"created": [], "updated": []}'::jsonb,
    'an unchanged definition reports no entity change');
SELECT is_empty(
    $$SELECT k, c FROM ee_snapshot
      EXCEPT (
        SELECT 'entity ' || table_name, ctid::TEXT FROM entities WHERE table_name LIKE 'ee\_%'
        UNION ALL SELECT 'field ' || id, ctid::TEXT FROM fields WHERE table_name LIKE 'ee\_%'
        UNION ALL SELECT 'module', ctid::TEXT FROM modules WHERE module_name = 'EE Test'
        UNION ALL SELECT 'permission ' || permission_name, ctid::TEXT FROM permissions WHERE permission_name LIKE 'eetest:%'
        UNION ALL SELECT 'role', ctid::TEXT FROM roles WHERE slug = 'eetest_mgr'
        UNION ALL SELECT 'item ' || id, ctid::TEXT FROM ee_items
        UNION ALL SELECT 'line ' || id, ctid::TEXT FROM ee_lines)$$,
    'an unchanged definition writes no row: metadata, module sections and records keep their position');

-- ---------------------------------------------- partial update, by name
CREATE TEMP TABLE ee_result AS SELECT ensure_entities(jsonc_to_jsonb($jsonc$
{
  "version": 1,
  "module": {"module_name": "EE Test", "description": "changed"},
  "permissions": [{"permission_name": "eetest:view", "description": "View changed"}],
  "roles": [{"slug": "eetest_mgr", "role_name": "EE Test Lead"}],
  "entities": [
    {
      "entity": {
        "table_name": "ee_items",
        "description": "items, changed",
        "fields": [{"field_name": "alpha", "title": "Alpha 2", "description": null}]
      },
      "records": [{"id": 20, "label": "two", "price": 9}]
    }
  ]
}
$jsonc$)) AS summary;

SELECT is((SELECT description FROM modules WHERE module_name = 'EE Test'), 'changed',
    'the module is updated by name');
SELECT is((SELECT description FROM permissions WHERE permission_name = 'eetest:view'), 'View changed',
    'a permission is updated by name');
SELECT is((SELECT role_name FROM roles WHERE slug = 'eetest_mgr'), 'EE Test Lead',
    'a role is updated by slug');
SELECT is((SELECT description || '|' || singular_label FROM entities WHERE table_name = 'ee_items'),
    'items, changed|Item',
    'a partial entity updates what it names and leaves omitted keys untouched');
SELECT ok((SELECT title = 'Alpha 2' AND description IS NULL FROM fields WHERE id = 'ee_items.alpha'),
    'an explicit null writes NULL');
SELECT is((SELECT title FROM fields WHERE id = 'ee_items.zeta'), 'Zeta',
    'a field the definition does not list is untouched');
SELECT ok((SELECT summary -> 'fields_not_in_definition' @> '["ee_items.zeta", "ee_items.mid"]' FROM ee_result),
    'fields the definition does not list are reported');
SELECT is((SELECT string_agg(id || ':' || price || ':' || zeta, ',' ORDER BY id) FROM ee_items),
    '10:5:z1,20:9:z2,30:7:z3',
    'records: a differing row is updated in the given columns only, and no row is deleted');
SELECT is((SELECT summary #> '{records,ee_items}' FROM ee_result), '{"inserted": 0, "updated": 1}'::jsonb,
    'records: the summary counts one update');

-- ------------------------------------------------ references across files
SELECT lives_ok($$SELECT ensure_entities(jsonc_to_jsonb('{"version": 1, "entities": [{"entity": {
    "table_name": "ee_links", "module_name": "EE Test", "singular_label": "Link", "plural_label": "Links",
    "fields": [{"field_name": "item_id", "title": "Item", "format": "reference", "reference_table": "ee_items", "field_order": 10}]}}]}'))$$,
    'a definition may reference an entity created by an earlier one');
SELECT ok(EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ee_links_item_id_fkey'),
    '  and the foreign key is created');

-- -------------------------------------------------------------- refusals
SELECT throws_ok(
    $$SELECT ensure_entities('{"version": 1, "entities": [{"entity": {"table_name": "ee_items", "fields": [{"field_name": "zeta", "field_order": 0}]}}]}')$$,
    '22023', NULL, 'field_order 0 is refused (a trigger would replace it)');
SELECT throws_ok(
    $$SELECT ensure_entities('{"version": 1, "entities": [{"entity": {"table_name": "ee_items", "singular": "", "fields": []}}]}')$$,
    '22023', NULL, 'an empty singular is refused (a trigger would derive one)');
SELECT throws_ok(
    $$SELECT ensure_entities('{"version": 1, "entities": [{"entity": {"table_name": "ee_items", "fields": [{"field_name": "zeta", "enum_values": {"a": 1}}]}}]}')$$,
    '22023', NULL, 'enum_values that is not an array is refused');
SELECT throws_ok(
    $$SELECT ensure_entities('{"version": 1, "entities": [{"entity": {"table_name": "ee_items", "colour": "red", "fields": []}}]}')$$,
    '22023', NULL, 'an unknown entity key is refused');
SELECT throws_ok(
    $$SELECT ensure_entities('{"version": 1, "entities": [{"entity": {"table_name": "ee_new", "module_name": "No Such Module", "fields": []}}]}')$$,
    '22023', NULL, 'an unknown module is refused');
SELECT throws_ok(
    $$SELECT ensure_entities('{"version": 2, "entities": []}')$$,
    '22023', NULL, 'a version other than 1 is refused');
SELECT throws_ok(
    $$SELECT ensure_entities('{"version": 1, "entities": [{"entity": {"table_name": "ee_items", "order_column": "sort", "fields": []}}]}')$$,
    '0A000', NULL, 'changing order_column is refused (the old column would be dropped)');
SELECT throws_ok(
    $$SELECT ensure_entities('{"version": 1, "entities": [{"entity": {"table_name": "ee_items", "managed": false, "fields": []}}]}')$$,
    '0A000', NULL, 'managed true -> false is refused');
SELECT throws_ok(
    $$SELECT ensure_entities('{"version": 1, "entities": [{"entity": {"table_name": "ee_items"}, "records": [{"id": 40, "label": "neg", "zeta": "", "alpha": "", "mid": 0, "price": -1}]}]}')$$,
    '99101', 'price must not be negative',
    'records are written under the validation rules');

SELECT * FROM finish();
ROLLBACK;
