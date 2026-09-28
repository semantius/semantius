-- What a .jsonc migration runs on (0290_ensure_entities.sql): ensure_entities
-- and the jsonc_to_jsonb parser.
--
-- Each part sets up its own fixtures; a part after the first starts by
-- restoring the connection's role and the runner's search_path. Parts:
--   1. ensure_entities
--   2. jsonc_to_jsonb
--   3. ensure_entities with an is_a family
--   4. a family file applied again: grown, changed, and with records on
--      several levels
BEGIN;

SELECT plan(76);

-- =====================================================
-- PART 1: ensure_entities
-- =====================================================
-- ensure_entities (0290_ensure_entities.sql)
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
          // an enum entry is a value or a {value, label} pair
          {"field_name": "kind",  "title": "Kind",  "format": "enum",  "field_order": 70,
           "enum_values": ["plain", {"value": "gift", "label": "Gift"}]},
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
SELECT is((SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'ee_items_kind_check'),
    $$CHECK ((kind = ANY (ARRAY['plain'::text, 'gift'::text, ''::text])))$$,
    'a {value, label} entry puts only its value into the CHECK');
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

-- =====================================================
-- PART 2: jsonc_to_jsonb
-- =====================================================
-- jsonc_to_jsonb (0290_ensure_entities.sql)
-- The parser every runner hands a .jsonc migration to. What it must get right
-- is what a naive comment stripper gets wrong: markers and commas inside
-- strings, escaped quotes and backslashes, a comment that ends the file, CRLF
-- line ends, a byte order mark, and a trailing comma with a comment between it
-- and the bracket. Invalid JSON must still fail.

RESET ROLE;
SET LOCAL search_path TO public, pgtap;

SELECT is(
    jsonc_to_jsonb('{"a": 1, "b": [true, null]}'),
    '{"a": 1, "b": [true, null]}'::jsonb,
    'plain JSON passes through unchanged');

SELECT is(
    jsonc_to_jsonb('{"url": "https://example.com/a//b", "c": "/* not a comment */", "d": "x // y"}'),
    '{"url": "https://example.com/a//b", "c": "/* not a comment */", "d": "x // y"}'::jsonb,
    'comment markers inside strings are kept');

SELECT is(
    jsonc_to_jsonb(E'{"q": "say \\"hi\\" // still a string", "b": "back\\\\"} // after'),
    jsonb_build_object('q', 'say "hi" // still a string', 'b', E'back\\'),
    'escaped quotes and backslashes do not end a string early');

SELECT is(
    jsonc_to_jsonb(E'// leading\n{"a": /* inline */ 1}\n// trailing comment, no newline at the end'),
    '{"a": 1}'::jsonb,
    'line and block comments are removed, including one that ends the text');

SELECT is(
    jsonc_to_jsonb(E'{\r\n  "a": 1, // x\r\n  "b": 2\r\n}\r\n'),
    '{"a": 1, "b": 2}'::jsonb,
    'CRLF line ends');

SELECT is(
    jsonc_to_jsonb(chr(65279) || '{"a": 1}'),
    '{"a": 1}'::jsonb,
    'a byte order mark is dropped');

SELECT is(
    jsonc_to_jsonb(E'{"a": [1, 2, ], "b": {"c": 3, /* x */ }, "d": [4, // y\n ], }'),
    '{"a": [1, 2], "b": {"c": 3}, "d": [4]}'::jsonb,
    'trailing commas are dropped, also with a comment before the bracket');

SELECT is(
    jsonc_to_jsonb('{"s": "a, ]", "t": "b,}"}'),
    '{"s": "a, ]", "t": "b,}"}'::jsonb,
    'a comma and a bracket inside a string are not a trailing comma');

SELECT throws_ok(
    $$SELECT jsonc_to_jsonb('{"a": }')$$,
    '22P02', NULL,
    'invalid JSON is refused by the jsonb cast');

SELECT throws_ok(
    $$SELECT jsonc_to_jsonb('{"a": "unterminated}')$$,
    '22P02', NULL,
    'an unterminated string is refused');

-- =====================================================
-- PART 3: ensure_entities with an is_a family
-- =====================================================
-- A derived entity comes after its base in the file; its records carry the
-- fields of the whole record and are written through its view.

RESET ROLE;
SET LOCAL search_path TO public, pgtap;

CREATE TEMP TABLE ens_family_def AS SELECT '{
    "version": 1,
    "entities": [
        {"entity": {"table_name": "ens_parties", "module_name": "_core", "singular_label": "Party",
                    "plural_label": "Parties", "id_type": "typeid", "id_prefix": "enspty",
                    "fields": [{"field_name": "city", "title": "City", "format": "text", "field_order": 30}]}},
        {"entity": {"table_name": "ens_orgs", "module_name": "_core", "singular_label": "Org",
                    "plural_label": "Orgs", "id_type": "is_a", "id_prefix": "ensorg", "id_refentity": "ens_parties",
                    "fields": [{"field_name": "vat", "title": "VAT", "format": "text", "field_order": 30}]},
         "records": [{"id": "ensorg_01h455vb4pex5vsknk084sn02q", "label": "Org One", "city": "Rome", "vat": "IT1"}]}
    ]
}'::jsonb AS def;

SELECT lives_ok($$ SELECT public.ensure_entities((SELECT def FROM ens_family_def)) $$,
    'family: ensure_entities creates an is_a entity after its base, with records');

SELECT is(
    (SELECT p.city || ' ' || x.vat FROM ens_parties p JOIN ens_orgs_ext x ON x.id = p.id),
    'Rome IT1',
    'family: a record is written through the view into every table it spans');

SELECT is(
    public.ensure_entities((SELECT def FROM ens_family_def)) #> '{records,ens_orgs}',
    '{"inserted": 0, "updated": 0}'::jsonb,
    'family: applying the same definition again writes nothing');

SELECT is(
    public.ensure_entities(jsonb_set((SELECT def FROM ens_family_def), '{entities,1,records,0,city}', '"Milan"'))
        #> '{records,ens_orgs}',
    '{"inserted": 0, "updated": 1}'::jsonb,
    'family: a changed inherited field is an update of the record');

SELECT is((SELECT city FROM ens_parties), 'Milan',
    'family: ... which lands in the base''s table');

SELECT throws_ok($$
    SELECT public.ensure_entities('{
        "version": 1,
        "entities": [
            {"entity": {"table_name": "ens_late", "module_name": "_core", "singular_label": "Late",
                        "plural_label": "Lates", "id_type": "has_a", "id_refentity": "ens_later",
                        "fields": []}},
            {"entity": {"table_name": "ens_later", "module_name": "_core", "singular_label": "Later",
                        "plural_label": "Laters", "id_type": "typeid", "id_prefix": "enslater", "fields": []}}
        ]
    }'::jsonb) $$,
    '23503', NULL,
    'family: a derived entity named before its base fails on entities_id_refentity_fkey');

-- =====================================================
-- PART 4: a family file applied again: grown, changed, and with records on
-- several levels
-- =====================================================
-- A module's file is applied again on every migrate. A later version may add
-- members and fields to a family that has records, and may change the root's
-- label column while its derived entities still carry the label settings an
-- earlier export wrote for them; those settings are always the root's, so the
-- installer leaves them alone. An export lists a subtype record under every
-- level it was read through, so records are written from the deepest is_a
-- level up, then the bases, then the has_a extensions: the root row of a
-- subtype record exists by the time the root's records are written, and an
-- extension attaches to a record that exists.

RESET ROLE;
SET LOCAL search_path TO public, pgtap;

-- The one value a query returns, as text, or 'ERROR <sqlstate>', so an apply
-- that fails is reported instead of ending the file.
CREATE FUNCTION pg_temp.ens4_value(p_sql TEXT) RETURNS TEXT LANGUAGE plpgsql AS $fn$
DECLARE
    v_value TEXT;
BEGIN
    EXECUTE p_sql INTO v_value;
    RETURN v_value;
EXCEPTION WHEN OTHERS THEN
    RETURN 'ERROR ' || SQLSTATE;
END $fn$;

CREATE TEMP TABLE ens4_docs (name TEXT PRIMARY KEY, def JSONB NOT NULL);

INSERT INTO ens4_docs VALUES ('v1', '{
    "version": 1,
    "entities": [
        {"entity": {"table_name": "ens4_parties", "module_name": "_core", "singular_label": "Party",
                    "plural_label": "Parties", "id_type": "typeid", "id_prefix": "ensfpty",
                    "fields": [{"field_name": "city", "title": "City", "format": "text", "field_order": 30}]},
         "records": [{"id": "ensfpty_01h455vb4pex5vsknk084sn02q", "label": "P1", "city": "Rome"}]},
        {"entity": {"table_name": "ens4_orgs", "module_name": "_core", "singular_label": "Org",
                    "plural_label": "Orgs", "id_type": "is_a", "id_prefix": "ensforg", "id_refentity": "ens4_parties",
                    "fields": [{"field_name": "vat", "title": "VAT", "format": "text", "field_order": 30}]},
         "records": [{"id": "ensforg_01h455vb4pex5vsknk084sn02r", "label": "O1", "city": "Oslo", "vat": "NO1"}]}
    ]
}');

INSERT INTO ens4_docs VALUES ('v2', '{
    "version": 1,
    "entities": [
        {"entity": {"table_name": "ens4_parties", "module_name": "_core", "singular_label": "Party",
                    "plural_label": "Parties", "id_type": "typeid", "id_prefix": "ensfpty",
                    "fields": [{"field_name": "city", "title": "City", "format": "text", "field_order": 30},
                               {"field_name": "country", "title": "Country", "format": "text", "field_order": 40}]},
         "records": [{"id": "ensfpty_01h455vb4pex5vsknk084sn02q", "label": "P1", "city": "Rome"}]},
        {"entity": {"table_name": "ens4_orgs", "module_name": "_core", "singular_label": "Org",
                    "plural_label": "Orgs", "id_type": "is_a", "id_prefix": "ensforg", "id_refentity": "ens4_parties",
                    "fields": [{"field_name": "vat", "title": "VAT", "format": "text", "field_order": 30}]},
         "records": [{"id": "ensforg_01h455vb4pex5vsknk084sn02r", "label": "O1", "city": "Oslo", "vat": "NO1"}]},
        {"entity": {"table_name": "ens4_banks", "module_name": "_core", "singular_label": "Bank",
                    "plural_label": "Banks", "id_type": "is_a", "id_prefix": "ensfbnk", "id_refentity": "ens4_orgs",
                    "fields": [{"field_name": "bic", "title": "BIC", "format": "text", "field_order": 30}]}},
        {"entity": {"table_name": "ens4_vendors", "module_name": "_core", "singular_label": "Vendor",
                    "plural_label": "Vendors", "id_type": "has_a", "id_refentity": "ens4_parties",
                    "fields": [{"field_name": "terms", "title": "Terms", "format": "text", "field_order": 30}]}}
    ]
}');

-- v2 as an export made before the root's label column changed would carry it:
-- the root names its new label column, every derived entity the old one.
INSERT INTO ens4_docs
SELECT 'v3',
       jsonb_set(jsonb_set(jsonb_set(jsonb_set(def,
           '{entities,0,entity,label_column}', '"city"'),
           '{entities,1,entity,label_column}', '"label"'),
           '{entities,2,entity,label_column}', '"label"'),
           '{entities,3,entity,label_column}', '"label"')
  FROM ens4_docs WHERE name = 'v2';

-- A new derived entity whose label column in the file is not its root's.
INSERT INTO ens4_docs VALUES ('v4', '{
    "version": 1,
    "entities": [
        {"entity": {"table_name": "ens4_units", "module_name": "_core", "singular_label": "Unit",
                    "plural_label": "Units", "id_type": "is_a", "id_prefix": "ensfunt", "id_refentity": "ens4_parties",
                    "label_column": "label",
                    "fields": [{"field_name": "code", "title": "Code", "format": "text", "field_order": 30}]}}
    ]
}');

-- A subtype record listed under the root and under the subtype.
INSERT INTO ens4_docs VALUES ('v5', '{
    "version": 1,
    "entities": [
        {"entity": {"table_name": "ens4_parties"},
         "records": [{"id": "ensfpty_01h455vb4pex5vsknk084sn02q", "label": "P1", "city": "Rome"},
                     {"id": "ensforg_01h455vb4pex5vsknk084sn02s", "label": "O2", "city": "Genoa"}]},
        {"entity": {"table_name": "ens4_orgs"},
         "records": [{"id": "ensforg_01h455vb4pex5vsknk084sn02s", "label": "O2", "city": "Genoa", "vat": "IT2"}]}
    ]
}');

-- The same, with a root field that differs between the two copies.
INSERT INTO ens4_docs VALUES ('v6', '{
    "version": 1,
    "entities": [
        {"entity": {"table_name": "ens4_parties"},
         "records": [{"id": "ensforg_01h455vb4pex5vsknk084sn02t", "label": "O3", "city": "Turin"}]},
        {"entity": {"table_name": "ens4_orgs"},
         "records": [{"id": "ensforg_01h455vb4pex5vsknk084sn02t", "label": "O3", "city": "Naples", "vat": "IT3"}]}
    ]
}');

-- An extension of a subtype record, listed before the subtype.
INSERT INTO ens4_docs VALUES ('v7', '{
    "version": 1,
    "entities": [
        {"entity": {"table_name": "ens4_vendors"},
         "records": [{"id": "ensfbnk_01h455vb4pex5vsknk084sn02v", "terms": "net45"}]},
        {"entity": {"table_name": "ens4_banks"},
         "records": [{"id": "ensfbnk_01h455vb4pex5vsknk084sn02v", "label": "B2", "city": "Bonn", "vat": "DE2",
                      "bic": "BIC2"}]}
    ]
}');

-- Growing the family.
SELECT lives_ok($$SELECT public.ensure_entities((SELECT def FROM ens4_docs WHERE name = 'v1'))$$,
    'family file v1: a root and a subtype, with records');

SELECT lives_ok($$SELECT public.ensure_entities((SELECT def FROM ens4_docs WHERE name = 'v2'))$$,
    'family file v2: a grandchild, an extension and a root field are added to a family that has records');

SELECT lives_ok($$INSERT INTO ens4_banks (label, city, vat, bic) VALUES ('B1', 'Bern', 'CH1', 'BIC1')$$,
    'family file v2: the new grandchild takes records');

SELECT lives_ok($$INSERT INTO ens4_vendors (id, terms) SELECT id, 'net30' FROM ens4_parties WHERE label = 'B1'$$,
    'family file v2: the new extension attaches to a record');

SELECT is(pg_temp.ens4_value($$
    SELECT string_agg(p.label || ':' || p.city || coalesce(':' || x.vat, ''), ', ' ORDER BY p.label COLLATE "C")
      FROM ens4_parties p LEFT JOIN ens4_orgs_ext x ON x.id = p.id
     WHERE p.label IN ('P1', 'O1')$$),
    'O1:Oslo:NO1, P1:Rome',
    'family file v2: the records already there are untouched');

SELECT ok(
    EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = to_regclass('public.ens4_orgs') AND attname = 'country')
    AND EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = to_regclass('public.ens4_banks') AND attname = 'country')
    AND EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = to_regclass('public.ens4_vendors') AND attname = 'country'),
    'family file v2: the new root field reaches the views of the derived entities');

-- The root's label column changes.
SELECT lives_ok($$SELECT public.ensure_entities((SELECT def FROM ens4_docs WHERE name = 'v3'))$$,
    'family file v3: the root names a new label column, the derived entities the old one');

SELECT is(
    (SELECT string_agg(table_name || '=' || label_column, ', ' ORDER BY table_name COLLATE "C") FROM entities
      WHERE table_name IN ('ens4_parties', 'ens4_orgs', 'ens4_banks', 'ens4_vendors')),
    'ens4_banks=city, ens4_orgs=city, ens4_parties=city, ens4_vendors=city',
    'family file v3: the root''s new label column reaches every derived entity');

SELECT is(pg_temp.ens4_value($$SELECT public.ensure_entities((SELECT def FROM ens4_docs WHERE name = 'v3')) -> 'entities'$$),
    ('{"created": [], "updated": []}'::jsonb)::TEXT,
    'family file v3: applying it again writes no entity');

SELECT lives_ok($$SELECT public.ensure_entities((SELECT def FROM ens4_docs WHERE name = 'v4'))$$,
    'a derived entity whose label_column in the file is not its root''s is created');

SELECT is(pg_temp.ens4_value($$SELECT public.ensure_entities((SELECT def FROM ens4_docs WHERE name = 'v4')) -> 'entities'$$),
    ('{"created": [], "updated": []}'::jsonb)::TEXT,
    'the same file applied again succeeds and writes nothing: a derived entity''s label settings are its root''s');

SELECT is((SELECT label_column FROM entities WHERE table_name = 'ens4_units'), 'city',
    'the derived entity keeps its root''s label column');

-- Records spread over the levels.
SELECT lives_ok($$SELECT public.ensure_entities((SELECT def FROM ens4_docs WHERE name = 'v5'))$$,
    'records: a subtype record listed under the root and under the subtype is written');

SELECT is(pg_temp.ens4_value($$
    SELECT p.label || '/' || p.city || '/' || x.vat
      FROM ens4_parties p JOIN ens4_orgs_ext x ON x.id = p.id
     WHERE p.id = 'ensforg_01h455vb4pex5vsknk084sn02s'$$),
    'O2/Genoa/IT2',
    'records: the record is whole: its root row, its part and the subtype''s own field');

SELECT is(pg_temp.ens4_value($$SELECT public.ensure_entities((SELECT def FROM ens4_docs WHERE name = 'v5')) -> 'records'$$),
    ('{"ens4_orgs": {"inserted": 0, "updated": 0}, "ens4_parties": {"inserted": 0, "updated": 0}}'::jsonb)::TEXT,
    'records: applying the same file again writes nothing');

SELECT lives_ok($$SELECT public.ensure_entities((SELECT def FROM ens4_docs WHERE name = 'v6'))$$,
    'records: a subtype record whose root copy differs from the subtype''s copy is written');

SELECT is(pg_temp.ens4_value($$SELECT city FROM ens4_parties WHERE id = 'ensforg_01h455vb4pex5vsknk084sn02t'$$),
    'Turin',
    'records: the root''s copy is written last, so its value of a root field wins');

SELECT lives_ok($$SELECT public.ensure_entities((SELECT def FROM ens4_docs WHERE name = 'v7'))$$,
    'records: an extension listed before the subtype record it extends is written');

SELECT is(pg_temp.ens4_value($$
    SELECT v.terms || '/' || b.bic
      FROM ens4_vendors v JOIN ens4_banks b ON b.id = v.id
     WHERE v.id = 'ensfbnk_01h455vb4pex5vsknk084sn02v'$$),
    'net45/BIC2',
    'records: the extension is attached to the subtype record');

SELECT throws_ok($$
    SELECT public.ensure_entities('{
        "version": 1,
        "entities": [
            {"entity": {"table_name": "ens4_parties"},
             "records": [{"id": "ensforg_01h455vb4pex5vsknk084sn02w", "label": "O9", "city": "Ostia"}]}
        ]
    }'::jsonb) $$,
    '90237', NULL,
    'records: a subtype record listed under the root only is refused: it would have no part');

-- A subtype record that references a record of its base in the same file
-- would have to be written both before and after the base's records.
INSERT INTO fields (table_name, field_name, title, format, reference_table, reference_delete_mode, field_order)
VALUES ('ens4_orgs', 'party_ref', 'Party', 'reference', 'ens4_parties', 'restrict', 40);

SELECT throws_ok($$
    SELECT public.ensure_entities('{
        "version": 1,
        "entities": [
            {"entity": {"table_name": "ens4_parties"},
             "records": [{"id": "ensfpty_01h455vb4pex5vsknk084sn02x", "label": "P9", "city": "Pavia"}]},
            {"entity": {"table_name": "ens4_orgs"},
             "records": [{"id": "ensforg_01h455vb4pex5vsknk084sn02y", "label": "O8", "city": "Ostia", "vat": "IT8",
                          "party_ref": "ensfpty_01h455vb4pex5vsknk084sn02x"}]}
        ]
    }'::jsonb) $$,
    '22023', NULL,
    'records: a subtype record that references a record of its base in the same file cannot be ordered');

SELECT * FROM finish();
ROLLBACK;
