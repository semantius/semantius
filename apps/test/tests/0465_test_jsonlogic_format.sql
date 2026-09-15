-- Test the jsonlogic field format.
--
-- jsonlogic sits next to jsonata as a custom format, but it is stored like json:
-- a JsonLogic rule is a JSON value that evaluate_json_logic() walks as jsonb,
-- while a JSONata expression is source text. The dictionary's own rule columns
-- carry the format so a UI can offer a rule editor instead of a raw JSON box.
--
-- Fixtures: ONE ephemeral entity `jl_fmt_probe` created in-tx as user3 (module
-- _core, public:read / admin, managed) with a single jsonlogic field.
BEGIN;

SELECT plan(9);

-- =====================================================
-- The format is known to the dictionary
-- =====================================================
SELECT ok(
    (SELECT enum_values ? 'jsonlogic' FROM fields WHERE table_name = 'fields' AND field_name = 'format'),
    'fields.format enum_values should list jsonlogic'
);

SELECT is(
    format_to_data_type('jsonlogic'), 'JSONB',
    'jsonlogic should map to a JSONB column'
);

SELECT is(
    format_to_json_type('jsonlogic'), format_to_json_type('json'),
    'jsonlogic should accept any JSON type, like json'
);

-- =====================================================
-- The dictionary columns that hold JsonLogic use it
-- =====================================================
SELECT set_eq(
    $$SELECT id FROM fields WHERE format = 'jsonlogic' AND table_name IN ('entities', 'fields')$$,
    ARRAY['entities.computed_fields', 'entities.validation_rules', 'entities.select_rule', 'fields.input_type_rule'],
    'the four JsonLogic rule columns should have format jsonlogic'
);

-- =====================================================
-- A jsonlogic field on a managed entity
-- =====================================================
select authenticate_as('user3');

INSERT INTO entities (
    table_name, singular, plural, singular_label, plural_label, description,
    module_id, view_permission, edit_permission, id_column, label_column, managed
)
VALUES (
    'jl_fmt_probe', 'jl_fmt_probe', 'jl_fmt_probes', 'JsonLogic Probe', 'JsonLogic Probes',
    'Ephemeral probe for the jsonlogic format',
    1, 'public:read', 'admin', 'id', 'label', TRUE
);

INSERT INTO fields (table_name, field_name, title, format, input_type, field_order)
VALUES ('jl_fmt_probe', 'rule', 'Rule', 'jsonlogic', 'default', 30);

SELECT is(
    (SELECT data_type FROM information_schema.columns
     WHERE table_schema = 'public' AND table_name = 'jl_fmt_probe' AND column_name = 'rule'),
    'jsonb',
    'a jsonlogic field should create a jsonb column'
);

SELECT is(
    public.get_schema('jl_fmt_probe')::jsonb #>> '{properties,rule,format}',
    'jsonlogic',
    'get_schema should emit format jsonlogic'
);

SELECT is(
    public.get_schema('jl_fmt_probe')::jsonb #> '{properties,rule,default}',
    '{}'::jsonb,
    'get_schema should default a jsonlogic property to {} like json'
);

SELECT ok(
    NOT (public.get_schema('jl_fmt_probe')::jsonb -> 'required') ? 'rule',
    'a jsonlogic property should not be required, like json'
);

INSERT INTO jl_fmt_probe (label, rule) VALUES ('probe', '{"==":[{"var":"label"},"probe"]}');

SELECT is(
    (SELECT evaluate_json_logic(rule, to_jsonb(p)) FROM jl_fmt_probe p WHERE label = 'probe'),
    'true'::jsonb,
    'a stored jsonlogic value should evaluate as a rule'
);

SELECT * FROM finish();
ROLLBACK;
