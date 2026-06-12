-- =====================================================
-- Catalog provenance tests (0360)
-- =====================================================
-- Validates the v0.1.2 provenance/lineage columns on entities/fields/modules/roles:
--   • existence + DD registration (ctype='core', is_core derives true)
--   • empty defaults + additive-safety (existing rows read "absent")
--   • shape/enum CHECKs (entity_type closed set, pattern_flags object, aliases array)
--   • write-once on the three scalar join-key codes (catalog_entity_code/_field_code/_module_code)
--   • append-only on catalog_entity_aliases
--   • non-uniqueness, soft pointer, core-column protection
--   • rename survival (the rename-discovery substrate)
--   • discovery joins + the three topologies (multi-recurrence, same-name share, alias)
-- See docs/provenance-core-0.1.2-changes.md §7. All operations run as admin (user3).
BEGIN;

SELECT plan(71);

SELECT authenticate_as('user3');

-- =====================================================
-- GROUP 1: physical columns exist
-- =====================================================
SELECT has_column('public', 'entities', 'catalog_entity_code',    'entities.catalog_entity_code exists');
SELECT has_column('public', 'entities', 'canonical_owner_module', 'entities.canonical_owner_module exists');
SELECT has_column('public', 'entities', 'entity_type',            'entities.entity_type exists');
SELECT has_column('public', 'entities', 'pattern_flags',          'entities.pattern_flags exists');
SELECT has_column('public', 'entities', 'catalog_entity_aliases', 'entities.catalog_entity_aliases exists');
SELECT has_column('public', 'fields',   'catalog_field_code',     'fields.catalog_field_code exists');
SELECT has_column('public', 'modules',  'catalog_module_code',    'modules.catalog_module_code exists');
SELECT has_column('public', 'roles',    'catalog_role_code',      'roles.catalog_role_code exists');

-- =====================================================
-- GROUP 2: DD registration (ctype='core' → is_core derives true), formats, enum_values
-- =====================================================
SELECT is((SELECT ctype FROM fields WHERE table_name='entities' AND field_name='catalog_entity_code'),    'core', 'catalog_entity_code registered ctype=core');
SELECT is((SELECT ctype FROM fields WHERE table_name='entities' AND field_name='canonical_owner_module'), 'core', 'canonical_owner_module registered ctype=core');
SELECT is((SELECT ctype FROM fields WHERE table_name='entities' AND field_name='entity_type'),            'core', 'entity_type registered ctype=core');
SELECT is((SELECT ctype FROM fields WHERE table_name='entities' AND field_name='pattern_flags'),          'core', 'pattern_flags registered ctype=core');
SELECT is((SELECT ctype FROM fields WHERE table_name='entities' AND field_name='catalog_entity_aliases'), 'core', 'catalog_entity_aliases registered ctype=core');
SELECT is((SELECT ctype FROM fields WHERE table_name='fields'   AND field_name='catalog_field_code'),     'core', 'catalog_field_code registered ctype=core');
SELECT is((SELECT ctype FROM fields WHERE table_name='modules'  AND field_name='catalog_module_code'),    'core', 'catalog_module_code registered ctype=core');
SELECT is((SELECT ctype FROM fields WHERE table_name='roles'    AND field_name='catalog_role_code'),      'core', 'catalog_role_code registered ctype=core');

SELECT is((SELECT format FROM fields WHERE table_name='entities' AND field_name='entity_type'),            'enum', 'entity_type format=enum');
SELECT is((SELECT format FROM fields WHERE table_name='entities' AND field_name='pattern_flags'),          'json', 'pattern_flags format=json');
SELECT is((SELECT format FROM fields WHERE table_name='entities' AND field_name='catalog_entity_aliases'), 'json', 'catalog_entity_aliases format=json');

SELECT is((public.get_schema('entities')::jsonb->'properties'->'catalog_entity_code'->>'is_core'), 'true', 'get_schema derives is_core=true for catalog_entity_code');
SELECT is((public.get_schema('fields')::jsonb->'properties'->'catalog_field_code'->>'is_core'),    'true', 'get_schema derives is_core=true for catalog_field_code');

SELECT is((SELECT jsonb_array_length(enum_values) FROM fields WHERE table_name='entities' AND field_name='entity_type'), 6, 'entity_type registered with 6 enum_values');

-- =====================================================
-- GROUP 3: defaults + additive-safety
-- =====================================================
-- A pre-existing seeded entity (modules) reads "absent" for every new column.
SELECT is((SELECT catalog_entity_code    FROM entities WHERE table_name='modules'), '',             'pre-existing entity: catalog_entity_code empty');
SELECT is((SELECT entity_type            FROM entities WHERE table_name='modules'), 'unclassified', 'pre-existing entity: entity_type unclassified');
SELECT is((SELECT pattern_flags          FROM entities WHERE table_name='modules'), '{}'::jsonb,    'pre-existing entity: pattern_flags {}');
SELECT is((SELECT catalog_entity_aliases FROM entities WHERE table_name='modules'), '[]'::jsonb,    'pre-existing entity: catalog_entity_aliases []');

-- A fresh probe entity reads the same defaults.
INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES ('prov_e', 'prov_e', 'Prov E', 'Prov Es', 'provenance probe', 1, 'public:read', 'admin', 'id', 'label');
SELECT is((SELECT catalog_entity_code    FROM entities WHERE table_name='prov_e'), '',             'fresh entity: catalog_entity_code empty');
SELECT is((SELECT canonical_owner_module FROM entities WHERE table_name='prov_e'), '',             'fresh entity: canonical_owner_module empty');
SELECT is((SELECT entity_type            FROM entities WHERE table_name='prov_e'), 'unclassified', 'fresh entity: entity_type unclassified');
SELECT is((SELECT pattern_flags          FROM entities WHERE table_name='prov_e'), '{}'::jsonb,    'fresh entity: pattern_flags {}');
SELECT is((SELECT catalog_entity_aliases FROM entities WHERE table_name='prov_e'), '[]'::jsonb,    'fresh entity: catalog_entity_aliases []');

-- =====================================================
-- GROUP 4: entity_type closed-enum CHECK (exactly 6, no '')
-- =====================================================
SELECT throws_ok($$UPDATE entities SET entity_type='platform' WHERE table_name='prov_e'$$, '23514', NULL, 'entity_type rejects an out-of-set value (platform)');
SELECT throws_ok($$UPDATE entities SET entity_type='' WHERE table_name='prov_e'$$, '23514', NULL, 'entity_type rejects empty string (closed 6-value set)');
SELECT lives_ok($$UPDATE entities SET entity_type='catalog' WHERE table_name='prov_e'$$, 'entity_type accepts catalog');
SELECT lives_ok($$UPDATE entities SET entity_type='operational_workflow' WHERE table_name='prov_e'$$, 'entity_type accepts operational_workflow');
SELECT lives_ok($$UPDATE entities SET entity_type='junction' WHERE table_name='prov_e'$$, 'entity_type accepts junction');

-- =====================================================
-- GROUP 5: pattern_flags object CHECK + round-trip
-- =====================================================
SELECT throws_ok($$UPDATE entities SET pattern_flags='[]'::jsonb WHERE table_name='prov_e'$$,  '23514', NULL, 'pattern_flags rejects a non-object (array)');
SELECT throws_ok($$UPDATE entities SET pattern_flags='"x"'::jsonb WHERE table_name='prov_e'$$, '23514', NULL, 'pattern_flags rejects a non-object (string)');
SELECT lives_ok($$UPDATE entities SET pattern_flags='{"personal_content":true,"submit_lock":true}'::jsonb WHERE table_name='prov_e'$$, 'pattern_flags accepts a JSON object');
SELECT is((SELECT pattern_flags->>'personal_content' FROM entities WHERE table_name='prov_e'), 'true', 'pattern_flags round-trip reads a key');

-- =====================================================
-- GROUP 6: catalog_entity_aliases array CHECK + round-trip; canonical_owner_module soft pointer
-- =====================================================
SELECT throws_ok($$UPDATE entities SET catalog_entity_aliases='{}'::jsonb WHERE table_name='prov_e'$$, '23514', NULL, 'catalog_entity_aliases rejects a non-array (object)');
SELECT lives_ok($$UPDATE entities SET catalog_entity_aliases='[{"alias_code":"suppliers","source_domain":"erp","source_module":"erp-procurement","decided":"2026-06-12"}]'::jsonb WHERE table_name='prov_e'$$, 'catalog_entity_aliases accepts an array of objects');
SELECT is((SELECT catalog_entity_aliases->0->>'alias_code' FROM entities WHERE table_name='prov_e'), 'suppliers', 'catalog_entity_aliases round-trip reads element 0');
SELECT lives_ok($$UPDATE entities SET canonical_owner_module='module-not-deployed-yet' WHERE table_name='prov_e'$$, 'canonical_owner_module accepts a not-yet-existing slug (soft pointer, not FK)');
SELECT is((SELECT canonical_owner_module FROM entities WHERE table_name='prov_e'), 'module-not-deployed-yet', 'canonical_owner_module round-trip');

-- =====================================================
-- GROUP 7: write-once on the three scalar join-key codes
-- =====================================================
-- catalog_entity_code: INSERT with a non-empty code is allowed (the modeler's stamping path).
INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column, catalog_entity_code)
VALUES ('prov_wo', 'prov_wo', 'Prov WO', 'Prov WOs', 'write-once probe', 1, 'public:read', 'admin', 'id', 'label', 'vendors');
SELECT is((SELECT catalog_entity_code FROM entities WHERE table_name='prov_wo'), 'vendors', 'INSERT with a non-empty catalog_entity_code is allowed (stamping path)');
SELECT throws_ok($$UPDATE entities SET catalog_entity_code='other' WHERE table_name='prov_wo'$$,
    '23514', 'catalog_entity_code is write-once: it cannot be changed once set',
    'catalog_entity_code rewrite (value->other) rejected with code + message');
SELECT lives_ok($$UPDATE entities SET description='changed' WHERE table_name='prov_wo'$$, 'unchanged-code UPDATE is allowed');
SELECT lives_ok($$UPDATE entities SET catalog_entity_code='backfilled' WHERE table_name='prov_e'$$, 'catalog_entity_code backfill (empty -> value) is allowed');
SELECT lives_ok($$DELETE FROM entities WHERE table_name='prov_wo'$$, 'DELETE of a code-bearing entity is not blocked');

-- catalog_field_code: create a field with a code, reject rewrite, allow backfill.
INSERT INTO fields (table_name, field_name, title, format, field_order, input_type, width, catalog_field_code)
VALUES ('prov_e', 'status', 'Status', 'text', 50, 'default', 'default', 'status');
SELECT is((SELECT catalog_field_code FROM fields WHERE table_name='prov_e' AND field_name='status'), 'status', 'field created with a catalog_field_code');
SELECT throws_ok($$UPDATE fields SET catalog_field_code='other' WHERE table_name='prov_e' AND field_name='status'$$, '23514', NULL, 'catalog_field_code rewrite is rejected');
INSERT INTO fields (table_name, field_name, title, format, field_order, input_type, width)
VALUES ('prov_e', 'note', 'Note', 'text', 60, 'default', 'default');
SELECT lives_ok($$UPDATE fields SET catalog_field_code='note' WHERE table_name='prov_e' AND field_name='note'$$, 'catalog_field_code backfill (empty -> value) is allowed');

-- catalog_module_code: create a module with a code, reject rewrite; verify the rule coexists with valid_module_slug.
INSERT INTO modules (module_name, module_slug, catalog_module_code) VALUES ('Prov Mod WO', 'prov_mod_wo', 'ATS-CANDIDATE-CRM');
SELECT throws_ok($$UPDATE modules SET catalog_module_code='OTHER' WHERE module_slug='prov_mod_wo'$$, '23514', NULL, 'catalog_module_code rewrite is rejected');
SELECT is((SELECT jsonb_array_length(validation_rules) FROM entities WHERE table_name='modules'), 2, 'modules keeps 2 validation rules (write-once appended, valid_module_slug not clobbered)');

-- =====================================================
-- GROUP 8: catalog_entity_aliases append-only (prov_e currently carries [suppliers])
-- =====================================================
SELECT lives_ok($$UPDATE entities SET catalog_entity_aliases='[{"alias_code":"suppliers","source_domain":"erp","source_module":"erp-procurement","decided":"2026-06-12"},{"alias_code":"partners","source_domain":"procurement","source_module":"procurement-core","decided":"2026-06-12"}]'::jsonb WHERE table_name='prov_e'$$, 'append-only: adding an element is allowed');
SELECT throws_ok($$UPDATE entities SET catalog_entity_aliases='[{"alias_code":"partners","source_domain":"procurement","source_module":"procurement-core","decided":"2026-06-12"}]'::jsonb WHERE table_name='prov_e'$$, '23514', NULL, 'append-only: removing an existing element is rejected');
SELECT lives_ok($$UPDATE entities SET catalog_entity_aliases='[{"alias_code":"partners","source_domain":"procurement","source_module":"procurement-core","decided":"2026-06-12"},{"alias_code":"suppliers","source_domain":"erp","source_module":"erp-procurement","decided":"2026-06-12"}]'::jsonb WHERE table_name='prov_e'$$, 'append-only: reordering existing elements is allowed (@> is order-insensitive)');

-- =====================================================
-- GROUP 9: non-uniqueness of the lineage codes
-- =====================================================
INSERT INTO roles (role_name, slug, catalog_role_code) VALUES ('Prov Role A', 'prov_role_a', 'recruiter');
SELECT lives_ok($$INSERT INTO roles (role_name, slug, catalog_role_code) VALUES ('Prov Role B', 'prov_role_b', 'recruiter')$$, 'two roles may share a catalog_role_code (non-unique)');
INSERT INTO modules (module_name, module_slug, catalog_module_code) VALUES ('Prov Mod A', 'prov_mod_a', 'SHARED-CODE');
SELECT lives_ok($$INSERT INTO modules (module_name, module_slug, catalog_module_code) VALUES ('Prov Mod B', 'prov_mod_b', 'SHARED-CODE')$$, 'two modules may share a catalog_module_code (non-unique)');

-- =====================================================
-- GROUP 10: core-column protection (inherited from ctype='core')
-- =====================================================
SELECT throws_ok($$DELETE FROM fields WHERE table_name='entities' AND field_name='catalog_entity_code'$$, 'P0001', NULL, 'a new core column cannot be deleted');
SELECT throws_ok($$UPDATE fields SET ctype='' WHERE table_name='entities' AND field_name='entity_type'$$, '42501', NULL, 'the ctype of a new core column cannot be cleared by an admin');

-- =====================================================
-- GROUP 11: rename survival (the rename-discovery substrate)
-- =====================================================
INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column, catalog_entity_code)
VALUES ('prov_suppliers', 'prov_supplier', 'Supplier', 'Suppliers', 'rename probe', 1, 'public:read', 'admin', 'id', 'label', 'vendors');
SELECT lives_ok($$UPDATE entities SET table_name='prov_vendors_x' WHERE table_name='prov_suppliers'$$, 'entity rename (table_name drift) succeeds');
SELECT is((SELECT catalog_entity_code FROM entities WHERE table_name='prov_vendors_x'), 'vendors', 'catalog_entity_code survives an entity rename (the join key is stable)');
INSERT INTO fields (table_name, field_name, title, format, field_order, input_type, width, catalog_field_code)
VALUES ('prov_vendors_x', 'status', 'Status', 'text', 70, 'default', 'default', 'status');
SELECT lives_ok($$UPDATE fields SET field_name='disposition' WHERE table_name='prov_vendors_x' AND field_name='status'$$, 'field rename (field_name drift) succeeds');
SELECT is((SELECT catalog_field_code FROM fields WHERE table_name='prov_vendors_x' AND field_name='disposition'), 'status', 'catalog_field_code survives a field rename');

-- =====================================================
-- GROUP 12: discovery joins + the three topologies
-- =====================================================
-- Three modules in three domains, three entities all canonically 'vendors'.
INSERT INTO modules (module_name, module_slug, catalog_module_code) VALUES
  ('Prov ERP',      'prov_erp',      'ERP-PROCUREMENT'),
  ('Prov Contract', 'prov_contract', 'CONTRACT-MGMT'),
  ('Prov Parties',  'prov_parties',  'PARTIES');
INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column, catalog_entity_code)
VALUES
  ('prov_erp_vendors',      'erp_vendor',      'ERP Vendor',      'ERP Vendors',      'erp silo',      (SELECT id FROM modules WHERE module_slug='prov_erp'),      'public:read','admin','id','label','vendors'),
  ('prov_contract_vendors', 'contract_vendor', 'Contract Vendor', 'Contract Vendors', 'contract silo', (SELECT id FROM modules WHERE module_slug='prov_contract'), 'public:read','admin','id','label','vendors'),
  ('prov_party_vendors',    'party_vendor',    'Party Vendor',    'Party Vendors',    'shared master', (SELECT id FROM modules WHERE module_slug='prov_parties'),    'public:read','admin','id','label','vendors');

-- catalog_entity_code is non-unique: multiple 'vendors' entities coexist.
SELECT ok((SELECT count(*) FROM entities WHERE catalog_entity_code='vendors') >= 3,
    'catalog_entity_code is non-unique: multiple vendors entities coexist');

-- Topology 1 — multi-recurrence disambiguation: step-2 scoped to one domain returns exactly that row.
SELECT is(
  (SELECT array_agg(e.table_name)
     FROM entities e
    WHERE e.catalog_entity_code='vendors'
      AND e.module_id IN (SELECT id FROM modules WHERE catalog_module_code = ANY(ARRAY['ERP-PROCUREMENT']))),
  ARRAY['prov_erp_vendors'],
  'topology 1: step-2 scoped to one domain returns exactly the in-domain vendors row, not all three');

-- Topology 3 — alias resolution: @> on (alias_code, source_domain) resolves the merged-away identity.
UPDATE entities SET catalog_entity_aliases='[{"alias_code":"suppliers","source_domain":"erp","source_module":"prov_erp","decided":"2026-06-12"}]'::jsonb
WHERE table_name='prov_party_vendors';
SELECT is(
  (SELECT table_name FROM entities
    WHERE catalog_entity_aliases @> '[{"alias_code":"suppliers","source_domain":"erp"}]'::jsonb
      AND module_id IN (SELECT id FROM modules WHERE catalog_module_code = ANY(ARRAY['PARTIES']))),
  'prov_party_vendors',
  'topology 3: alias @> on (alias_code, source_domain), scoped to the domain, resolves the merged-away identity');

-- Topology 2 — same-name share owned elsewhere: a consumer module has no own 'vendors' row;
-- step-2 scoped to it returns empty, and step-1 (the FK) resolves the shared entity.
INSERT INTO modules (module_name, module_slug, catalog_module_code) VALUES ('Prov AP', 'prov_ap', 'ACCOUNTS-PAYABLE');
INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES ('prov_po', 'prov_po', 'PO', 'POs', 'consumer (no own vendors row)', (SELECT id FROM modules WHERE module_slug='prov_ap'), 'public:read','admin','id','label');
INSERT INTO fields (table_name, field_name, title, format, field_order, input_type, width, reference_table, reference_delete_mode, catalog_field_code)
VALUES ('prov_po', 'vendor_id', 'Vendor', 'reference', 80, 'default', 'default', 'prov_party_vendors', 'restrict', 'vendor_id');
SELECT is(
  (SELECT count(*)::int FROM entities e
    WHERE e.catalog_entity_code='vendors'
      AND e.module_id IN (SELECT id FROM modules WHERE catalog_module_code = ANY(ARRAY['ACCOUNTS-PAYABLE']))),
  0,
  'topology 2: step-2 scoped to the consumer domain returns no own vendors row');
SELECT is(
  (SELECT reference_table FROM fields WHERE table_name='prov_po' AND field_name='vendor_id'),
  'prov_party_vendors',
  'topology 2: step-1 FK (reference_table) resolves the shared vendors entity');

SELECT * FROM finish();
ROLLBACK;
