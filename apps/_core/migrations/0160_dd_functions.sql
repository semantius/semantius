-- =====================================================
-- DYNAMIC TABLE MANAGEMENT FUNCTIONS
-- =====================================================
-- Automatically creates tables and fields when metadata is inserted
-- Integrates with RBAC for automatic RLS policy creation
-- =====================================================

-- =====================================================
-- FORMAT TO DATA TYPE MAPPING FUNCTION
-- =====================================================
-- Maps JSON Schema format values to PostgreSQL data types
-- This function converts the format column value to an actual PostgreSQL type
CREATE OR REPLACE FUNCTION format_to_data_type(p_format TEXT, p_precision SMALLINT DEFAULT NULL)
RETURNS TEXT AS $$
DECLARE
    v_scale SMALLINT := COALESCE(p_precision, 2::SMALLINT);
BEGIN
    RETURN CASE p_format
        -- Integer formats
        WHEN 'int32' THEN 'INTEGER'
        WHEN 'int64' THEN 'BIGINT'
        WHEN 'integer' THEN 'INTEGER'
        -- The fallback for a reference whose target key cannot be read (see
        -- field_data_type): BIGINT, the type of an auto_increment key, which is
        -- what an entity gets unless it declares otherwise.
        WHEN 'reference' THEN 'BIGINT'
        WHEN 'parent' THEN 'BIGINT'
        
        -- Number formats
        WHEN 'float' THEN 'REAL'
        WHEN 'double' THEN 'DOUBLE PRECISION'
        WHEN 'number' THEN 'NUMERIC(18, ' || v_scale || ')'
        
        -- Special types (not TEXT)
        WHEN 'uuid' THEN 'UUID'
        WHEN 'binary' THEN 'BYTEA'
        
        -- Date/Time formats
        WHEN 'date' THEN 'DATE'
        WHEN 'time' THEN 'TIME'
        WHEN 'date-time' THEN 'TIMESTAMPTZ'
        WHEN 'duration' THEN 'INTERVAL'
        
        -- Boolean format
        WHEN 'boolean' THEN 'BOOLEAN'
        
        -- JSON formats. jsonlogic is stored as JSONB, unlike jsonata: a JSONata
        -- expression is source text, a JsonLogic rule is itself a JSON value that
        -- evaluate_json_logic() walks as jsonb.
        WHEN 'json' THEN 'JSONB'
        WHEN 'jsonlogic' THEN 'JSONB'
        WHEN 'object' THEN 'JSONB'
        WHEN 'array' THEN 'JSONB'
        
        -- Default case (handles all string-like formats: text, email, url, hostname, etc.)
        ELSE 'TEXT'
    END;
END;
$$ LANGUAGE plpgsql IMMUTABLE SET search_path = public;

COMMENT ON FUNCTION format_to_data_type IS
'Maps JSON Schema format values to PostgreSQL data types for CREATE/ALTER TABLE statements. For "number" format, the optional p_precision argument controls the NUMERIC scale (default 2).';

-- =====================================================
-- ENTITY FAMILIES (id_type is_a and has_a)
-- =====================================================
-- An is_a entity is a subtype, a has_a entity an optional extension, of the
-- entity named in its id_refentity (its base); both share the base's TypeID
-- key. A family is a typeid root and every entity based on it, directly or
-- through other is_a entities. Every entity of a family is managed
-- (derived_entity_managed, and 90240/90252 for the bases).
--
-- Storage: the root is an ordinary table. A derived entity t keeps its own
-- fields in the physical table t_ext, whose key references the physical
-- relation of its base, and is read and written through the view t, which
-- joins t_ext with the relations of all its bases. The helpers below are what
-- every piece of the dictionary asks when it has to know which relation holds
-- an entity's columns, which entities a record spans, and which fields make up
-- a record.

-- The physical relation of an entity: t_ext for is_a and has_a, the entity's
-- own table for every other key type. The two-argument form is for callers
-- that already hold the entity row; the one-argument form looks the key type
-- up and answers the name itself for an unknown entity.
CREATE OR REPLACE FUNCTION dd_relation(p_table_name TEXT, p_id_type TEXT)
RETURNS TEXT AS $$
    SELECT CASE WHEN p_id_type IN ('is_a', 'has_a') THEN p_table_name || '_ext' ELSE p_table_name END;
$$ LANGUAGE sql IMMUTABLE SET search_path = public;

COMMENT ON FUNCTION dd_relation(TEXT, TEXT) IS
'Name of the physical table that holds an entity''s own columns: <entity>_ext for id_type is_a and has_a, the entity name for every other key type.';

CREATE OR REPLACE FUNCTION dd_relation(p_table_name TEXT)
RETURNS TEXT AS $$
    SELECT dd_relation(p_table_name, (SELECT e.id_type FROM entities e WHERE e.table_name = p_table_name));
$$ LANGUAGE sql STABLE SET search_path = public;

COMMENT ON FUNCTION dd_relation(TEXT) IS
'Name of the physical table that holds an entity''s own columns, looked up by the entity''s key type. The entity name itself for an unknown entity.';

-- The entity and the chain of bases above it, root first: depth 0 is the root,
-- the entity itself has the highest depth. A plain entity is its own chain of
-- one. id_refentity is write-once and names an entity that already existed, so
-- the chain cannot loop; the hop limit only keeps a corrupted catalog from
-- hanging the dictionary.
CREATE OR REPLACE FUNCTION dd_ancestors(p_table_name TEXT)
RETURNS TABLE (table_name TEXT, depth INTEGER) AS $$
    WITH RECURSIVE up(table_name, id_refentity, hops) AS (
        SELECT e.table_name, e.id_refentity, 0
          FROM entities e
         WHERE e.table_name = p_table_name
        UNION ALL
        SELECT b.table_name, b.id_refentity, up.hops + 1
          FROM up
          JOIN entities b ON b.table_name = up.id_refentity
         WHERE up.hops < 64
    )
    SELECT up.table_name, (max(up.hops) OVER () - up.hops)::integer
      FROM up
     ORDER BY 2;
$$ LANGUAGE sql STABLE SET search_path = public;

COMMENT ON FUNCTION dd_ancestors(TEXT) IS
'The chain of an entity: its root at depth 0, then each is_a/has_a level, the entity itself last. A plain entity returns itself alone. Empty for an unknown entity.';

-- Every entity based on this one, directly or further down, with its distance
-- (1 = based on it directly).
CREATE OR REPLACE FUNCTION dd_descendants(p_table_name TEXT)
RETURNS TABLE (table_name TEXT, depth INTEGER) AS $$
    WITH RECURSIVE down(table_name, depth) AS (
        SELECT e.table_name, 1
          FROM entities e
         WHERE e.id_refentity = p_table_name
        UNION ALL
        SELECT e.table_name, down.depth + 1
          FROM down
          JOIN entities e ON e.id_refentity = down.table_name
         WHERE down.depth < 64
    )
    SELECT down.table_name, down.depth
      FROM down
     ORDER BY down.depth, down.table_name;
$$ LANGUAGE sql STABLE SET search_path = public;

COMMENT ON FUNCTION dd_descendants(TEXT) IS
'Every is_a and has_a entity based on the given entity, directly or through other is_a entities, with its distance (1 = direct).';

-- The fields that make up a record of the entity: the root's fields first,
-- then each level's, then the entity's own. The bases' key and audit fields are
-- left out, because the entity's own stand in for them: a record has one key,
-- and its created_at and updated_at are its own level's. For a derived entity
-- the key comes first and the audit fields last, the order its view has; a
-- plain entity keeps its field_order unchanged.
--
-- This is the one column source for everything that describes or writes a
-- whole record: the view, the write routines, the labels, get_schema, the
-- searchable flag. The fields rows keep their table_name, which names the
-- entity that owns each field. Rows come in order; a caller that joins them
-- takes the order from WITH ORDINALITY.
CREATE OR REPLACE FUNCTION dd_family_fields(p_table_name TEXT)
RETURNS SETOF fields AS $$
    WITH chain AS (
        SELECT a.table_name, a.depth FROM dd_ancestors(p_table_name) a
    ), top AS (
        SELECT max(chain.depth) AS n FROM chain
    )
    SELECT f.*
      FROM chain
      JOIN fields f ON f.table_name = chain.table_name
     CROSS JOIN top
     WHERE chain.table_name = p_table_name
        OR coalesce(f.ctype, '') NOT IN ('id', 'audit')
     ORDER BY CASE WHEN top.n > 0 AND f.ctype = 'id' THEN -1
                   WHEN top.n > 0 AND f.ctype = 'audit' THEN top.n + 1
                   ELSE chain.depth
              END,
              f.field_order, f.field_name;
$$ LANGUAGE sql STABLE SET search_path = public;

COMMENT ON FUNCTION dd_family_fields(TEXT) IS
'The fields rows that make up a record of the entity, in order: for an is_a/has_a entity its key, the fields of its root and of each level (without their key and audit fields), its own fields, then its audit fields; for a plain entity its own fields in field_order. table_name names the entity that owns each field.';

-- An entity's records are readable only by who may view every level they are
-- stored in: the view is security_invoker and each table keeps its own RLS.
-- The schema RPCs and get_record_by_id gate on the same condition.
CREATE OR REPLACE FUNCTION dd_entity_viewable(p_table_name TEXT)
RETURNS BOOLEAN AS $$
    SELECT COALESCE(bool_and(rbac.has_permission(e.view_permission)), FALSE)
      FROM dd_ancestors(p_table_name) a
      JOIN entities e ON e.table_name = a.table_name;
$$ LANGUAGE sql STABLE SET search_path = public;

COMMENT ON FUNCTION dd_entity_viewable(TEXT) IS
'TRUE when the current user holds the view_permission of the entity and of every base it is stored in. FALSE for an unknown entity.';

-- entities.searchable: some field of the record is searchable. One predicate
-- for every place that computes the flag, so a derived entity is searchable
-- when one of its inherited fields is, the way its view's search_vector is.
CREATE OR REPLACE FUNCTION dd_entity_searchable(p_table_name TEXT)
RETURNS BOOLEAN AS $$
    SELECT EXISTS (SELECT 1 FROM dd_family_fields(p_table_name) f WHERE f.searchable);
$$ LANGUAGE sql STABLE SET search_path = public;

COMMENT ON FUNCTION dd_entity_searchable(TEXT) IS
'The value of entities.searchable: TRUE when any field of the entity''s record (dd_family_fields) is searchable.';

-- entities.is_child: some field of the record is a parent field. A record of
-- a derived entity is a record of every level above it, so it belongs to the
-- parent its root or a middle level names, and the application hides the
-- derived entity from the navigation together with its root.
CREATE OR REPLACE FUNCTION dd_entity_is_child(p_table_name TEXT)
RETURNS BOOLEAN AS $$
    SELECT EXISTS (SELECT 1 FROM dd_family_fields(p_table_name) f WHERE f.format = 'parent');
$$ LANGUAGE sql STABLE SET search_path = public;

COMMENT ON FUNCTION dd_entity_is_child(TEXT) IS
'The value of entities.is_child: TRUE when any field of the entity''s record (dd_family_fields) has format parent.';

-- =====================================================
-- ENTITY KEY TYPES (entities.id_type)
-- =====================================================
-- Every entity declares the type of its key. The helpers below are the one
-- place that turns an id_type into DDL, a field row and the key's triggers, so
-- the create path (create_dd_table) and the adoption path (enable_dd_table,
-- 0180_managed_enable.sql) cannot drift apart.
--
--   id_type         column                                       id field format
--   auto_increment  BIGINT GENERATED BY DEFAULT AS IDENTITY       int64
--   bigint          BIGINT, supplied by the caller                int64
--   text            TEXT, supplied by the caller                  text
--   uuid            UUID DEFAULT common.uuid_v7()                 uuid
--   typeid          common.typeid, filled by common.typeid_assign string
--   is_a, has_a     common.typeid in <entity>_ext, referencing     string
--                   the base's relation (ENTITY FAMILIES above)
--   computed        system tables only: a generated column        text
--
-- BY DEFAULT rather than ALWAYS: seeds, imports and ensure_entities write
-- explicit ids, and afterwards move the sequence past them (fix_id_sequence).
-- A caller may bring its own uuid or typeid too; only the typeid prefix is
-- checked.

-- The column type an id_type gives a key, upper-cased like field_data_type's
-- answers. Also what a reference to a registered entity without a table gets.
CREATE OR REPLACE FUNCTION dd_id_type_data_type(p_id_type TEXT)
RETURNS TEXT AS $$
    SELECT CASE p_id_type
        WHEN 'auto_increment' THEN 'BIGINT'
        WHEN 'bigint'         THEN 'BIGINT'
        WHEN 'uuid'           THEN 'UUID'
        WHEN 'typeid'         THEN 'COMMON.TYPEID'
        WHEN 'is_a'           THEN 'COMMON.TYPEID'
        WHEN 'has_a'          THEN 'COMMON.TYPEID'
        ELSE 'TEXT'  -- text, and computed, whose system keys are generated TEXT
    END;
$$ LANGUAGE sql IMMUTABLE SET search_path = public;

COMMENT ON FUNCTION dd_id_type_data_type(TEXT) IS
'Column type of an entity key for a given id_type (BIGINT, TEXT, UUID or COMMON.TYPEID), upper-cased like field_data_type.';

-- The key column's DDL and the values of its fields row, for one entity.
--   column_ddl       the column definition inside CREATE TABLE, PRIMARY KEY included
--   id_format        the fields.format of the key
--   input_type       the key's static input_type: readonly for generated keys;
--                    required for bigint and text, which the caller supplies
--   input_type_rule  for bigint and text, required while the key is empty and
--                    readonly once it is set, because a key never changes; the
--                    rule reads the entity's real id_column, not a fixed "id".
--                    has_a likewise, but optional: an id names the base record
--                    to attach to, none creates a new one
-- Raises 90234 for computed: those keys are generated columns over other
-- columns of a system table, which the dictionary cannot define.
--
-- For is_a and has_a the column is the key of <entity>_ext: the base record's
-- key, a RESTRICT foreign key to the base's physical relation, so a part can
-- never outlive the record it belongs to and a record is deleted bottom-up,
-- part by part, by the write routines. The entity row must already exist,
-- which it does in create_dd_table (AFTER INSERT).
CREATE OR REPLACE FUNCTION dd_id_column_ddl(
    p_table_name TEXT,
    p_id_column TEXT,
    p_id_type TEXT,
    OUT column_ddl TEXT,
    OUT id_format TEXT,
    OUT input_type TEXT,
    OUT input_type_rule JSONB
) AS $$
DECLARE
    v_base TEXT;
BEGIN
    input_type := 'readonly';
    input_type_rule := '{}'::jsonb;
    CASE p_id_type
        WHEN 'auto_increment' THEN
            column_ddl := format('%I BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY', p_id_column);
            id_format := 'int64';
        WHEN 'bigint' THEN
            column_ddl := format('%I BIGINT PRIMARY KEY', p_id_column);
            id_format := 'int64';
        WHEN 'text' THEN
            -- No default: an empty string could be saved as a key, and only once.
            column_ddl := format('%I TEXT PRIMARY KEY', p_id_column);
            id_format := 'text';
        WHEN 'uuid' THEN
            column_ddl := format('%I UUID PRIMARY KEY DEFAULT common.uuid_v7()', p_id_column);
            id_format := 'uuid';
        WHEN 'typeid' THEN
            -- No default: common.typeid_assign fills the key before the NOT
            -- NULL of the primary key is checked, and it knows the prefix.
            column_ddl := format('%I common.typeid PRIMARY KEY', p_id_column);
            id_format := 'string';
        WHEN 'is_a', 'has_a' THEN
            SELECT e.id_refentity INTO v_base FROM entities e WHERE e.table_name = p_table_name;
            column_ddl := format('%I common.typeid PRIMARY KEY REFERENCES public.%I(%I) ON DELETE RESTRICT',
                p_id_column, dd_relation(v_base), p_id_column);
            id_format := 'string';
            IF p_id_type = 'has_a' THEN
                input_type := 'default';
                input_type_rule := jsonb_build_object('if',
                    jsonb_build_array(jsonb_build_object('var', p_id_column), 'readonly', 'default'));
            END IF;
        ELSE
            RAISE EXCEPTION 'id_type ${id_type} is reserved for system tables and cannot be used for entity ${table}'
                USING ERRCODE = '90234',
                      HINT = jsonb_build_object('id_type', p_id_type, 'table', p_table_name)::text;
    END CASE;
    IF p_id_type IN ('bigint', 'text') THEN
        input_type := 'required';
        input_type_rule := jsonb_build_object('if',
            jsonb_build_array(jsonb_build_object('var', p_id_column), 'readonly', 'required'));
    END IF;
END;
-- STABLE, not IMMUTABLE: format() is STABLE.
$$ LANGUAGE plpgsql STABLE SET search_path = public;

COMMENT ON FUNCTION dd_id_column_ddl(TEXT, TEXT, TEXT) IS
'Key column DDL and id field row values (format, input_type, input_type_rule) for an entity''s id_type. Used by create_dd_table and enable_dd_table so both paths build the same key. For is_a/has_a the key of <entity>_ext, referencing the base''s relation. Raises 90234 for computed.';

-- Refuses to adopt an existing table whose key column does not match the
-- entity's id_type (90235). Registering an entity onto a table that already
-- exists - an INSERT whose CREATE TABLE IF NOT EXISTS finds one, or a flip of
-- managed to true - must not leave the dictionary describing a key the table
-- does not have: every reference to the entity is typed from id_type while the
-- table does not exist, and from the real column once it does, so the two
-- would disagree. A table with no key column at all is refused the same way;
-- the administrator adds the column first.
--
-- auto_increment accepts a BIGINT filled by an identity or by a sequence
-- default (bigserial): both assign ids the same way and fix_id_sequence can
-- move either. An int4 serial is refused, it is the 2.1 billion ceiling the
-- 64-bit keys exist to remove.
CREATE OR REPLACE FUNCTION dd_check_id_column(p_table_name TEXT, p_id_column TEXT, p_id_type TEXT)
RETURNS VOID AS $$
DECLARE
    v_type_oid   OID;
    v_actual     TEXT;
    v_identity   "char";
    v_default    TEXT;
    v_matches    BOOLEAN;
    v_expected   TEXT;
BEGIN
    SELECT a.atttypid, pg_catalog.format_type(a.atttypid, a.atttypmod), a.attidentity,
           pg_catalog.pg_get_expr(d.adbin, d.adrelid)
      INTO v_type_oid, v_actual, v_identity, v_default
      FROM pg_catalog.pg_attribute a
      LEFT JOIN pg_catalog.pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
     WHERE a.attrelid = pg_catalog.to_regclass(format('public.%I', p_table_name))::oid
       AND a.attname = p_id_column
       AND a.attnum > 0
       AND NOT a.attisdropped;

    v_expected := CASE p_id_type
        WHEN 'auto_increment' THEN 'bigint with an identity or sequence default'
        WHEN 'bigint'         THEN 'bigint'
        WHEN 'text'           THEN 'text'
        WHEN 'uuid'           THEN 'uuid'
        WHEN 'typeid'         THEN 'common.typeid'
        ELSE p_id_type
    END;

    v_matches := CASE p_id_type
        WHEN 'auto_increment' THEN v_type_oid = 'pg_catalog.int8'::regtype
                                   AND (v_identity <> '' OR v_default LIKE 'nextval(%')
        WHEN 'bigint'         THEN v_type_oid = 'pg_catalog.int8'::regtype
        WHEN 'text'           THEN v_type_oid = 'pg_catalog.text'::regtype
        WHEN 'uuid'           THEN v_type_oid = 'pg_catalog.uuid'::regtype
        WHEN 'typeid'         THEN v_type_oid = 'common.typeid'::regtype
        ELSE FALSE
    END;

    IF NOT COALESCE(v_matches, FALSE) THEN
        RAISE EXCEPTION 'Table ${table} cannot be adopted: its key column ${id_column} is ${actual_type}, but id_type ${id_type} needs ${expected_type}'
            USING ERRCODE = '90235',
                  HINT = jsonb_build_object(
                      'table', p_table_name,
                      'id_column', p_id_column,
                      'actual_type', COALESCE(v_actual, 'missing'),
                      'id_type', p_id_type,
                      'expected_type', v_expected,
                      'hint', 'Change the table''s key column to ${expected_type}, or declare the entity with the id_type that matches it.')::text;
    END IF;
END;
$$ LANGUAGE plpgsql STABLE SET search_path = public;

COMMENT ON FUNCTION dd_check_id_column(TEXT, TEXT, TEXT) IS
'Raises 90235 when an existing table''s key column does not match the entity''s id_type (or is missing). auto_increment accepts a BIGINT identity or bigserial.';

-- The key's triggers on an entity's physical relation:
--   pk_immutable  BEFORE UPDATE OF <key>: common.reject_pk_change, for every
--                 key type - keys are set once
--   typeid_assign BEFORE INSERT: common.typeid_assign with the current prefix
--                 and the prefixes of the entity's is_a subtypes, for typeid
--                 keys only (an is_a or has_a entity takes its ids from the
--                 root)
-- Neither name embeds the table name, so rename_dd_table has nothing to
-- rename, and both are dropped with the table. The prefixes are trigger
-- arguments, quoted with %L. This is the one installer of typeid_assign, and
-- it computes the subtype list itself, so every path that installs the trigger
-- - create_dd_table, enable_dd_table, dd_sync_typeid_prefix on a prefix change
-- and the family refresh when a subtype comes or goes - installs the same one.
-- A trigger with the root's prefix alone would refuse every subtype insert.
CREATE OR REPLACE FUNCTION dd_install_id_triggers(p_table_name TEXT, p_id_column TEXT, p_id_type TEXT, p_id_prefix TEXT)
RETURNS VOID AS $$
DECLARE
    v_rel     TEXT := dd_relation(p_table_name, p_id_type);
    v_subtype TEXT;
BEGIN
    EXECUTE format(
        'CREATE OR REPLACE TRIGGER pk_immutable BEFORE UPDATE OF %I ON public.%I
            FOR EACH ROW EXECUTE FUNCTION common.reject_pk_change(%L)',
        p_id_column, v_rel, p_id_column);

    IF p_id_type = 'typeid' THEN
        SELECT string_agg(format(', %L', e.id_prefix), '' ORDER BY e.id_prefix)
          INTO v_subtype
          FROM dd_descendants(p_table_name) d
          JOIN entities e ON e.table_name = d.table_name
         WHERE e.id_type = 'is_a';
        EXECUTE format(
            'CREATE OR REPLACE TRIGGER typeid_assign BEFORE INSERT ON public.%I
                FOR EACH ROW EXECUTE FUNCTION common.typeid_assign(%L, %L%s)',
            v_rel, p_id_column, p_id_prefix, coalesce(v_subtype, ''));
    END IF;
END;
-- SECURITY INVOKER: its callers (create_dd_table, enable_dd_table,
-- dd_sync_typeid_prefix, dd_refresh_family) are SECURITY DEFINER and already
-- run as the owner.
$$ LANGUAGE plpgsql SECURITY INVOKER SET search_path = public;

COMMENT ON FUNCTION dd_install_id_triggers(TEXT, TEXT, TEXT, TEXT) IS
'Creates the pk_immutable trigger (every key type) on an entity''s physical relation and, for typeid keys, the typeid_assign insert trigger carrying the current prefix and the prefixes of the entity''s is_a subtypes.';

-- =====================================================
-- HELPER FUNCTION: FIELD TO COLUMN DATA TYPE
-- =====================================================
-- The type a field's column actually gets. For everything except a reference
-- that is format_to_data_type(); for a reference or a parent it is the type of
-- the key the field points at, read from the catalog.
--
-- A reference cannot be typed from its format alone. `permissions` is keyed by
-- TEXT, `users` by BIGINT, a typeid entity by the common.typeid domain, and
-- format_to_data_type() sees only the word "reference", so it can only guess -
-- and a column typed differently from the key it is about to be constrained to
-- makes the ADD CONSTRAINT fail. Reading the key is the only answer that is
-- right for every entity.
--
-- Three sources, in order:
--   1. the declared type of the referenced key column in the catalog, when
--      the referenced entity has a physical table;
--   2. the referenced entity's id_type, when it is registered but its table
--      does not exist yet (an unmanaged entity, or one whose table is created
--      later in the same definition) - the type its key will get;
--   3. the format, which gives BIGINT for reference and parent, when the
--      referenced entity is unknown. With no table to point at, the ADD
--      CONSTRAINT then fails on the missing relation.
--
-- The result is upper-cased so quote_default_value's INTEGER/BOOLEAN tests and
-- the DDL builders' NOT NULL default table keep matching on it. A key declared
-- with the common.typeid domain comes back as COMMON.TYPEID: format_type()
-- schema-qualifies it because this function's search_path does not include
-- `common`, and the DDL builders emit the type unquoted, so PostgreSQL folds
-- it back to common.typeid. Quoting it would break that, which is why the
-- builders interpolate it with %s rather than %I.
CREATE OR REPLACE FUNCTION field_data_type(
    p_format TEXT,
    p_precision SMALLINT DEFAULT NULL,
    p_reference_table TEXT DEFAULT NULL
)
RETURNS TEXT AS $$
    SELECT COALESCE(
        CASE
            WHEN p_format IN ('reference', 'parent') AND COALESCE(p_reference_table, '') <> '' THEN COALESCE(
                (
                    SELECT upper(pg_catalog.format_type(a.atttypid, a.atttypmod))
                    FROM entities e
                    JOIN pg_catalog.pg_attribute a
                      ON a.attrelid = pg_catalog.to_regclass(format('public.%I', e.table_name))::oid
                     AND a.attname = e.id_column
                     AND a.attnum > 0
                     AND NOT a.attisdropped
                    WHERE e.table_name = p_reference_table
                ),
                (
                    SELECT dd_id_type_data_type(e.id_type)
                    FROM entities e
                    WHERE e.table_name = p_reference_table
                )
            )
        END,
        format_to_data_type(p_format, p_precision)
    );
$$ LANGUAGE sql STABLE SET search_path = public;

COMMENT ON FUNCTION field_data_type IS
'PostgreSQL type for a field''s column. Same as format_to_data_type except for reference/parent, which take the type of the referenced entity''s key column so the foreign key can be created: the catalog type when the table exists, else the type the entity''s id_type gives its key. Falls back to the format (BIGINT) when the referenced entity is unknown.';

-- =====================================================
-- HELPER FUNCTION: FORMAT TO JSON SCHEMA TYPE
-- =====================================================
-- Maps format values to JSON Schema primitive types
-- Used to avoid duplication in type and default value handling
-- This function is closely related to format_to_data_type above

CREATE OR REPLACE FUNCTION format_to_json_type(p_format TEXT)
RETURNS JSONB AS $$
BEGIN
    RETURN dd_formats()::jsonb -> p_format -> 'type';
END;
$$ LANGUAGE plpgsql IMMUTABLE SET search_path = public;

COMMENT ON FUNCTION format_to_json_type IS 
'Maps format values to JSON Schema types (returns JSONB - either a string for single type or array for json format).';

-- =====================================================
-- HELPER FUNCTION: FIELD TO JSON SCHEMA TYPE
-- =====================================================
-- The JSON Schema type a field's property gets. The sibling of field_data_type
-- above and it has to agree with it: the schema RPCs describe the very column
-- that function creates, so a reference is typed after the key it points at
-- here too. `entities` is keyed by TEXT and `users` by INTEGER, and a schema
-- that called both "integer" would make the UI cast 'orders' to a number and
-- PostgREST reject the write.
--
-- The referenced key's own format is what decides, not its catalog type. Both
-- routes agree on the JSON type for every key in the dictionary today; reading
-- the format is what keeps them agreeing when a key is declared as something
-- narrower than its column type, because format_to_json_type is the one
-- mapping either side consults. The format stands when the referenced entity is
-- unknown or has no field row for its key column.
CREATE OR REPLACE FUNCTION field_json_type(p_format TEXT, p_reference_table TEXT DEFAULT NULL)
RETURNS JSONB AS $$
    SELECT COALESCE(
        CASE
            WHEN p_format IN ('reference', 'parent') AND COALESCE(p_reference_table, '') <> '' THEN (
                SELECT format_to_json_type(rf.format)
                FROM entities e
                JOIN fields rf ON rf.table_name = e.table_name AND rf.field_name = e.id_column
                WHERE e.table_name = p_reference_table
            )
        END,
        format_to_json_type(p_format)
    );
$$ LANGUAGE sql STABLE SET search_path = public;

COMMENT ON FUNCTION field_json_type IS
'JSON Schema type for a field''s property. Same as format_to_json_type except for reference/parent, which take the type of the referenced entity''s key field. Falls back to the format when the referenced entity is unknown.';

-- =====================================================
-- IS_NULLABLE FUNCTION
-- =====================================================
-- Determines whether a column should allow NULL values based on its format.
-- Nullable formats: reference (optional FK), date (unknown date), date-time (not-yet timestamps)
-- All other formats use NOT NULL with appropriate defaults.

CREATE OR REPLACE FUNCTION is_nullable(p_format TEXT)
RETURNS BOOLEAN AS $$
BEGIN
    RETURN p_format IN ('reference', 'date', 'date-time');
END;
$$ LANGUAGE plpgsql IMMUTABLE SET search_path = public;

COMMENT ON FUNCTION is_nullable IS
'Determines whether a column should allow NULL values based on its format. Returns TRUE for reference, date, and date-time formats.';

-- =====================================================
-- ENUM HELPER FUNCTIONS
-- =====================================================
-- An entry of enum_values is a plain value ("active") or a value with its
-- display label ({"value": "on_hold", "label": "On hold"}). Only the values
-- reach the CHECK constraint and the column default.
-- Centralized handling of enum default behavior:
--   • enum_value_list        -- the values of an enum_values array, without labels.
--   • effective_enum_values  -- expands enum_values with '' for non-required enums,
--                               so empty defaults are accepted by the CHECK constraint.
--   • effective_enum_default -- resolves the actual column default for an enum field
--                               based on input_type and the explicit default_value.

CREATE OR REPLACE FUNCTION enum_value_list(p_enum_values JSONB)
RETURNS JSONB AS $$
    SELECT jsonb_agg(CASE WHEN jsonb_typeof(e) = 'object' THEN e -> 'value' ELSE e END ORDER BY n)
      FROM jsonb_array_elements(p_enum_values) WITH ORDINALITY AS t(e, n);
$$ LANGUAGE sql IMMUTABLE SET search_path = public;

COMMENT ON FUNCTION enum_value_list IS
'Returns the values of an enum_values array in order, taking the "value" of an entry that is a {value, label} object. NULL for an empty array.';

CREATE OR REPLACE FUNCTION effective_enum_values(p_input_type TEXT, p_enum_values JSONB)
RETURNS JSONB AS $$
BEGIN
    IF p_enum_values IS NULL OR jsonb_typeof(p_enum_values) != 'array' OR jsonb_array_length(p_enum_values) = 0 THEN
        RETURN p_enum_values;
    END IF;
    -- For non-required enums, ensure '' is in the allowed list so the implicit
    -- empty-string default does not violate the CHECK constraint.
    IF p_input_type IS DISTINCT FROM 'required' AND NOT (enum_value_list(p_enum_values) @> '[""]'::jsonb) THEN
        RETURN p_enum_values || '[""]'::jsonb;
    END IF;
    RETURN p_enum_values;
END;
$$ LANGUAGE plpgsql IMMUTABLE SET search_path = public;

COMMENT ON FUNCTION effective_enum_values IS
'Returns the effective list of allowed enum entries, values and {value, label} objects as stored: appends '''' for non-required enums so that the implicit empty-string default is accepted by the CHECK constraint.';

CREATE OR REPLACE FUNCTION effective_enum_default(p_default_value TEXT, p_input_type TEXT, p_enum_values JSONB)
RETURNS TEXT AS $$
BEGIN
    -- Explicit default takes precedence
    IF p_default_value IS NOT NULL AND trim(p_default_value) != '' THEN
        RETURN p_default_value;
    END IF;
    -- Required enum without explicit default: pick the first allowed value
    IF p_input_type = 'required'
       AND p_enum_values IS NOT NULL
       AND jsonb_typeof(p_enum_values) = 'array'
       AND jsonb_array_length(p_enum_values) > 0 THEN
        RETURN enum_value_list(p_enum_values)->>0;
    END IF;
    -- Non-required enum without explicit default: empty string
    RETURN '';
END;
$$ LANGUAGE plpgsql IMMUTABLE SET search_path = public;

COMMENT ON FUNCTION effective_enum_default IS
'Computes the effective default for an enum field: explicit default_value if set, else first enum value when input_type is required, else empty string.';

-- Nullability is derived on demand from a field's format via the is_nullable()
-- function above; callers invoke is_nullable(format) directly rather than reading
-- a stored column (no is_nullable column is materialized on the fields table).

-- =====================================================
-- HELPER FUNCTION: QUOTE DEFAULT VALUE
-- =====================================================
-- Properly quotes default values based on data type
-- Properly quotes default values based on data type for DDL statements

-- SECURITY: the result of this function is interpolated verbatim (%s) into
-- ALTER TABLE ... DEFAULT statements that run inside SECURITY DEFINER triggers,
-- i.e. as the table owner. fields.default_value is writable by every holder of
-- the admin permission, so this function must NEVER return caller-supplied text
-- unquoted. A default is a VALUE, not an expression: a quoted string literal is
-- cast by PostgreSQL to the column type, so quote_literal() is the safe general
-- case. Only a fixed allow-list of well-known, argument-less SQL expressions and
-- plain numeric/boolean/NULL literals are emitted bare.
CREATE OR REPLACE FUNCTION quote_default_value(p_default_value TEXT, p_data_type TEXT)
RETURNS TEXT AS $$
DECLARE
    v_value TEXT := trim(p_default_value);
    v_upper TEXT;
BEGIN
    -- If default value is NULL or empty, return as-is
    IF p_default_value IS NULL OR v_value = '' THEN
        RETURN p_default_value;
    END IF;

    v_upper := upper(v_value);

    -- The NULL keyword
    IF v_upper = 'NULL' THEN
        RETURN 'NULL';
    END IF;

    -- Boolean constants for boolean columns (t/f are normalized to keywords)
    IF p_data_type = 'BOOLEAN' AND v_upper IN ('TRUE', 'FALSE', 'T', 'F') THEN
        RETURN CASE WHEN v_upper IN ('TRUE', 'T') THEN 'TRUE' ELSE 'FALSE' END;
    END IF;

    -- Plain numeric constants for numeric columns (NUMERIC(18, n) included)
    IF p_data_type ~ '^(INTEGER|BIGINT|SMALLINT|NUMERIC|DECIMAL|REAL|DOUBLE PRECISION)'
       AND v_value ~ '^-?[0-9]+(\.[0-9]+)?$' THEN
        RETURN v_value;
    END IF;

    -- Allow-listed argument-less SQL expressions (exact, case-insensitive match)
    IF v_upper IN (
        'CURRENT_TIMESTAMP', 'CURRENT_DATE', 'CURRENT_TIME',
        'LOCALTIMESTAMP', 'LOCALTIME',
        'NOW()', 'CLOCK_TIMESTAMP()', 'STATEMENT_TIMESTAMP()', 'TRANSACTION_TIMESTAMP()',
        'GEN_RANDOM_UUID()',
        'CURRENT_USER', 'SESSION_USER'
    ) THEN
        RETURN v_upper;
    END IF;

    -- Everything else is a literal value; PostgreSQL casts it to the column type
    -- (so '[]' works for JSONB, '2026-01-01' for DATE, '1e3' for NUMERIC, ...).
    RETURN quote_literal(p_default_value);
END;
$$ LANGUAGE plpgsql IMMUTABLE SET search_path = public;

COMMENT ON FUNCTION quote_default_value IS
'Quotes a fields.default_value for use in DDL. Returns bare text only for NULL, boolean and numeric literals and a fixed allow-list of argument-less SQL expressions (CURRENT_TIMESTAMP, now(), gen_random_uuid(), ...); every other value becomes a quoted string literal that PostgreSQL casts to the column type. Never returns caller-supplied text unquoted.';

-- =====================================================
-- HELPER FUNCTIONS: BUILD OBJECT COMMENTS
-- =====================================================
-- Centralized construction of the COMMENT ON TABLE / COMMENT ON COLUMN bodies
-- applied by the DDL triggers, so the create and update paths stay identical.
--   • dd_table_comment  -- "<plural_label>" then a blank line + description (when set)
--   • dd_field_comment  -- "<title> (<format>)" then description, plus enum value list

CREATE OR REPLACE FUNCTION dd_table_comment(p_plural_label TEXT, p_description TEXT)
RETURNS TEXT AS $$
DECLARE
    v_body TEXT;
BEGIN
    -- Summary line: the plural label
    v_body := COALESCE(trim(p_plural_label), '');
    -- Description paragraph (blank line before it)
    IF p_description IS NOT NULL AND trim(p_description) != '' THEN
        v_body := CASE WHEN v_body = '' THEN '' ELSE v_body || E'\n\n' END || p_description;
    END IF;
    RETURN NULLIF(v_body, '');
END;
$$ LANGUAGE plpgsql IMMUTABLE SET search_path = public;

COMMENT ON FUNCTION dd_table_comment IS
'Builds the COMMENT ON TABLE body for an entity: the plural label as a summary line, followed by a blank line and the description when one is set. Returns NULL when both are empty. Used by the entity create and update DDL triggers so both paths stay in sync.';

CREATE OR REPLACE FUNCTION dd_field_comment(p_title TEXT, p_format TEXT, p_description TEXT, p_enum_values JSONB)
RETURNS TEXT AS $$
DECLARE
    v_body   TEXT;
    v_values TEXT;
BEGIN
    -- Summary line: "<title> (<format>)"
    v_body := trim(trim(COALESCE(p_title, '')) || ' (' || COALESCE(p_format, '') || ')');
    -- Description paragraph (blank line before it)
    IF p_description IS NOT NULL AND trim(p_description) != '' THEN
        v_body := v_body || E'\n\n' || p_description;
    END IF;
    -- Enum value list: comma-separated allowed values on their own line
    IF p_format = 'enum'
       AND p_enum_values IS NOT NULL
       AND jsonb_typeof(p_enum_values) = 'array'
       AND jsonb_array_length(p_enum_values) > 0 THEN
        SELECT string_agg(value, ', ') INTO v_values
        FROM jsonb_array_elements_text(enum_value_list(p_enum_values)) AS value;
        v_body := v_body || E'\n\n' || v_values;
    END IF;
    RETURN NULLIF(v_body, '');
END;
$$ LANGUAGE plpgsql IMMUTABLE SET search_path = public;

COMMENT ON FUNCTION dd_field_comment IS
'Builds the COMMENT ON COLUMN body for a field: a "<title> (<format>)" summary line, then the description (when set), then for enum fields a blank line and the comma-separated list of allowed values. Used by the field create and update DDL triggers so both paths stay in sync.';

-- =====================================================
-- RLS POLICIES OF AN ENTITY
-- =====================================================
-- The dictionary's four policies for a managed entity, from its row in
-- entities: SELECT on view_permission, INSERT/UPDATE/DELETE on
-- edit_permission. A select_rule, when set, is layered on afterwards by
-- build_select_rule_policy (0210_computed_validation.sql), which replaces
-- SELECT, UPDATE and DELETE. create_dd_table calls it for every new entity;
-- 0240_dd_bootstrap_complete.once.sql calls it for the core tables that were
-- registered before the dictionary existed.
--
-- The policies go on the entity's physical relation and are named after it
-- (<entity>_ext_select_policy for an is_a or has_a entity): each table of a
-- family carries its own entity's policies only, and the security_invoker view
-- and the invoker write routines apply all of them to a record.
CREATE OR REPLACE FUNCTION create_entity_policies(p_table_name TEXT)
RETURNS VOID AS $$
DECLARE
    v_view_permission TEXT;
    v_edit_permission TEXT;
    v_id_type         TEXT;
BEGIN
    SELECT view_permission, edit_permission, id_type
      INTO v_view_permission, v_edit_permission, v_id_type
      FROM entities
     WHERE table_name = p_table_name;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Table ${table} is not an entity'
            USING ERRCODE = '90231',
                  HINT = jsonb_build_object('table', p_table_name)::text;
    END IF;
    p_table_name := dd_relation(p_table_name, v_id_type);

    -- Policy predicates wrap rbac.has_permission() in a scalar sub-select: PostgreSQL then evaluates
    -- it once per statement (InitPlan) instead of once per row (1.7 s vs 10 ms on 100k rows).
    -- Test 0445 fails on the bare per-row form.
    EXECUTE format(
        'CREATE POLICY %I ON %I
            FOR SELECT
            TO semantius_user
            USING ((SELECT rbac.has_permission(%L)))',
        p_table_name || '_select_policy',
        p_table_name,
        v_view_permission
    );

    EXECUTE format(
        'CREATE POLICY %I ON %I
            FOR INSERT
            TO semantius_user
            WITH CHECK ((SELECT rbac.has_permission(%L)))',
        p_table_name || '_insert_policy',
        p_table_name,
        v_edit_permission
    );

    EXECUTE format(
        'CREATE POLICY %I ON %I
            FOR UPDATE
            TO semantius_user
            USING ((SELECT rbac.has_permission(%L)))
            WITH CHECK ((SELECT rbac.has_permission(%L)))',
        p_table_name || '_update_policy',
        p_table_name,
        v_edit_permission,
        v_edit_permission
    );

    EXECUTE format(
        'CREATE POLICY %I ON %I
            FOR DELETE
            TO semantius_user
            USING ((SELECT rbac.has_permission(%L)))',
        p_table_name || '_delete_policy',
        p_table_name,
        v_edit_permission
    );
END;
$$ LANGUAGE plpgsql SECURITY INVOKER SET search_path = public;

COMMENT ON FUNCTION create_entity_policies(TEXT) IS
'Creates the four RLS policies of a managed entity on its physical relation from its entities row: SELECT on view_permission, INSERT/UPDATE/DELETE on edit_permission. Called by create_dd_table for every new entity and once for the core tables registered before the dictionary existed.';

-- =====================================================
-- TRIGGER FUNCTION: CREATE TABLE ON INSERT
-- =====================================================

CREATE OR REPLACE FUNCTION create_dd_table()
RETURNS TRIGGER AS $$
DECLARE
    v_create_sql TEXT;
    v_comment    TEXT;
    v_sequence_name TEXT;
    v_key        RECORD;
    v_existed    BOOLEAN;
    v_derived    BOOLEAN := NEW.id_type IN ('is_a', 'has_a');
    v_rel        TEXT := dd_relation(NEW.table_name, NEW.id_type);
    v_name       TEXT;
BEGIN
    -- Skip DDL execution if table is not managed
    IF NOT NEW.managed THEN
        RAISE NOTICE 'Skipping table creation for "%" (managed=false)', NEW.table_name;
        RETURN NEW;
    END IF;

    -- Raises 90234 for id_type computed, before anything is created.
    v_key := dd_id_column_ddl(NEW.table_name, NEW.id_column, NEW.id_type);

    IF v_derived THEN
        -- An is_a or has_a entity is the view <entity> over the table
        -- <entity>_ext and its bases. Neither name may be taken: unlike a
        -- plain entity, which adopts a table that is already there, this one
        -- has nothing to adopt, and CREATE TABLE IF NOT EXISTS would silently
        -- keep a stranger's table as its storage.
        FOREACH v_name IN ARRAY ARRAY[NEW.table_name, v_rel] LOOP
            IF to_regclass(format('public.%I', v_name)) IS NOT NULL THEN
                RAISE EXCEPTION 'Table name ${relation} is already in use'
                    USING ERRCODE = '90250',
                          HINT = jsonb_build_object('relation', v_name)::text;
            END IF;
        END LOOP;
        v_existed := FALSE;
        -- No label column: the record's label is its root's.
        v_create_sql := format(
            'CREATE TABLE public.%I (
                %s,
                created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
                updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
            )',
            v_rel,
            v_key.column_ddl
        );
    ELSE
        v_existed := to_regclass(format('public.%I', NEW.table_name)) IS NOT NULL;
        v_create_sql := format(
            'CREATE TABLE IF NOT EXISTS public.%I (
                %s,
                %I TEXT NOT NULL DEFAULT '''',
                created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
                updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
            )',
            NEW.table_name,
            v_key.column_ddl,
            NEW.label_column
        );
    END IF;

    -- Create the table
    EXECUTE v_create_sql;

    -- An entity registered onto a table that was already there adopts it, and
    -- its key has to be the key id_type describes.
    IF v_existed THEN
        PERFORM dd_check_id_column(NEW.table_name, NEW.id_column, NEW.id_type);
    END IF;
    PERFORM dd_install_id_triggers(NEW.table_name, NEW.id_column, NEW.id_type, NEW.id_prefix);

    -- Set table comment: plural label summary + optional description
    v_comment := dd_table_comment(NEW.plural_label, NEW.description);
    IF v_comment IS NOT NULL THEN
        EXECUTE format('COMMENT ON TABLE %I IS %L', v_rel, v_comment);
    END IF;

    -- Add updated_at trigger using common schema function
    EXECUTE format(
        'CREATE TRIGGER %I
            BEFORE UPDATE ON %I
            FOR EACH ROW
            EXECUTE FUNCTION common.update_updated_at_column()',
        'update_' || v_rel || '_updated_at',
        v_rel
    );

    -- Only the entity's write routines write <entity>_ext (90244). The name
    -- sorts before every other BEFORE trigger, so a refused write runs nothing.
    IF v_derived THEN
        EXECUTE format(
            'CREATE TRIGGER a_ext_write_guard
                BEFORE INSERT OR UPDATE OR DELETE ON public.%I
                FOR EACH ROW
                EXECUTE FUNCTION common.ext_write_guard()',
            v_rel
        );
    END IF;

    -- Enable RLS on the new table
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', v_rel);

    -- The four RLS policies (view_permission for SELECT, edit_permission for
    -- INSERT, UPDATE and DELETE).
    PERFORM create_entity_policies(NEW.table_name);

    -- The request role has no default privileges in public, so a dictionary
    -- table is unreachable through the Data API until it is granted here. The
    -- grant comes last, after row-level security is on and the four policies
    -- above exist, so the table is never reachable in a state where its
    -- permission model is not yet in place. Ordering it first would not actually
    -- expose anything - RLS with no policy denies every non-owner - but the
    -- table would then be published by a statement that has not yet decided who
    -- may read it. <entity>_ext is granted like any entity table: the write
    -- routines run as the caller, and its view is security_invoker.
    EXECUTE format(
        'GRANT SELECT, INSERT, UPDATE, DELETE ON public.%I TO semantius_user',
        v_rel
    );
    -- An identity column's sequence is owned by it, so pg_get_serial_sequence
    -- finds it as it finds a serial's. The column exists: a table that was
    -- already there passed dd_check_id_column above, and pg_get_serial_sequence
    -- raises on a missing column rather than returning NULL, so the test stays
    -- as the guard it was. A key that is not a sequence has no grant to give.
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name   = v_rel
          AND column_name  = NEW.id_column
    ) THEN
        v_sequence_name := pg_get_serial_sequence(
            format('public.%I', v_rel), NEW.id_column);
        IF v_sequence_name IS NOT NULL THEN
            EXECUTE format(
                'GRANT USAGE, SELECT ON SEQUENCE %s TO semantius_user',
                v_sequence_name
            );
        END IF;
    END IF;

    -- Insert field records for id, label, created_at, and updated_at columns.
    -- All these are core fields (ctype <> '') that cannot be deleted, and cannot
    -- be renamed except the label column, which validate_field_rename_and_format
    -- lets through; ctype is set
    -- here by privileged DD code (the fields_ctype_lock trigger forbids users from setting it).
    -- The label column is marked as searchable=TRUE for full-text search.
    -- An is_a or has_a entity gets no label row: its label field is its
    -- root's. This INSERT is also what builds its view: the statement-level
    -- field triggers end in the family refresh (dd_refresh_family), so the
    -- view exists before the label triggers on entities fire.
    INSERT INTO fields (table_name, field_name, title, format, is_pk, field_order, input_type, width, ctype, searchable, reference_table, reference_delete_mode, input_type_rule)
    SELECT *
      FROM (VALUES
        (NEW.table_name, NEW.id_column, 'Id', v_key.id_format, TRUE, 10, v_key.input_type, 'default', 'id', FALSE, '', '', v_key.input_type_rule),
        (NEW.table_name, NEW.label_column, 'Name', 'text', FALSE, 20, 'required', 'default', 'label', TRUE, '', '', '{}'::jsonb),
        (NEW.table_name, 'created_at', 'Created At', 'date-time', FALSE, 999998, 'disabled', 'default', 'audit', FALSE, '', '', '{}'::jsonb),
        (NEW.table_name, 'updated_at', 'Updated At', 'date-time', FALSE, 999999, 'disabled', 'default', 'audit', FALSE, '', '', '{}'::jsonb)
      ) AS v(table_name, field_name, title, format, is_pk, field_order, input_type, width, ctype, searchable, reference_table, reference_delete_mode, input_type_rule)
     WHERE NOT (v_derived AND v.ctype = 'label');

    -- entities.searchable needs no write here. The INSERT above is a statement
    -- of its own even inside this trigger, so handle_field_searchable_insert_trigger
    -- fires on it and update_table_searchable_flag has already set the flag from
    -- the label field. Writing it again would fire the whole entities UPDATE
    -- trigger stack a second time for every table created.

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION create_dd_table IS
'Trigger function that creates a table with RLS policies when a row is inserted into entities table. For an is_a or has_a entity it creates <entity>_ext with its write guard; its view comes from the family refresh the field rows trigger.';

-- Apply trigger AFTER INSERT on entities
CREATE OR REPLACE TRIGGER create_table_trigger
    AFTER INSERT ON entities
    FOR EACH ROW
    EXECUTE FUNCTION create_dd_table();

-- =====================================================
-- TRIGGER FUNCTION: SYNC TABLE COMMENT ON UPDATE
-- =====================================================
-- Keeps COMMENT ON TABLE in sync when an entity's plural_label or description
-- changes (or the table is renamed). Fires AFTER UPDATE so the physical rename
-- performed by the BEFORE UPDATE rename trigger has already applied and
-- NEW.table_name refers to the current table.

CREATE OR REPLACE FUNCTION update_dd_table_comment()
RETURNS TRIGGER AS $$
DECLARE
    v_comment TEXT;
    v_rel     TEXT := dd_relation(NEW.table_name, NEW.id_type);
BEGIN
    -- Only managed tables that physically exist have a table to comment on
    IF NOT NEW.managed OR to_regclass(format('public.%I', v_rel)) IS NULL THEN
        RETURN NEW;
    END IF;

    -- Nothing to do unless a comment input or the table identity changed
    IF OLD.plural_label IS DISTINCT FROM NEW.plural_label
       OR OLD.description IS DISTINCT FROM NEW.description
       OR OLD.table_name IS DISTINCT FROM NEW.table_name THEN
        v_comment := dd_table_comment(NEW.plural_label, NEW.description);
        EXECUTE format('COMMENT ON TABLE %I IS %L', v_rel, v_comment);
        -- An is_a or has_a entity is read through its view, which is what
        -- PostgREST describes, so the view carries the same comment.
        IF v_rel <> NEW.table_name AND to_regclass(format('public.%I', NEW.table_name)) IS NOT NULL THEN
            EXECUTE format('COMMENT ON VIEW %I IS %L', NEW.table_name, v_comment);
        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION update_dd_table_comment IS
'Trigger function that re-applies COMMENT ON TABLE (plural label + description) when an entity''s plural_label, description or table_name changes, keeping the table comment in sync with the entity metadata. An is_a or has_a entity''s view gets the same comment as its <entity>_ext table.';

CREATE OR REPLACE TRIGGER update_table_comment_trigger
    AFTER UPDATE ON entities
    FOR EACH ROW
    EXECUTE FUNCTION update_dd_table_comment();

-- =====================================================
-- ctype LOCK: ctype is the single, un-tamperable core marker
-- =====================================================
-- ctype marks a DD-managed core column (id/label/audit/core); all structural protection
-- (no delete, no format or default change, and no rename but the label column's)
-- keys on `ctype <> ''`. For that to be sound the
-- marker must be settable ONLY by DD/migration code and immutable thereafter — otherwise a
-- tenant admin (who holds the fields edit permission) could mint a ctype, or clear the ctype
-- of the id column to "free" it for deletion. Privilege is decided by BYPASSRLS: the migration
-- owner and every SECURITY DEFINER DD function (create_dd_table, enable_dd_table, …) run as the
-- BYPASSRLS owner; the request path runs as semantius_user (NOBYPASSRLS). Non-privileged
-- callers get ctype forced to '' on INSERT and a hard rejection on any UPDATE that changes it.
CREATE OR REPLACE FUNCTION lock_field_ctype()
RETURNS TRIGGER AS $$
DECLARE
    v_privileged BOOLEAN;
BEGIN
    -- Normalize enum_values: coerce non-array JSONB (e.g. '{}') to NULL so
    -- jsonb_array_length() calls in get_schema / triggers never receive a non-array.
    IF NEW.enum_values IS NOT NULL AND jsonb_typeof(NEW.enum_values) != 'array' THEN
        NEW.enum_values := NULL;
    END IF;

    SELECT rolbypassrls INTO v_privileged FROM pg_roles WHERE rolname = current_user;
    IF COALESCE(v_privileged, FALSE) THEN
        RETURN NEW;  -- DD / migration code: trusted to set ctype
    END IF;

    IF TG_OP = 'INSERT' THEN
        NEW.ctype := '';  -- users cannot mint a core marker on a new field
    ELSIF NEW.ctype IS DISTINCT FROM OLD.ctype THEN
        RAISE EXCEPTION 'ctype is system-managed and cannot be changed on field ${field_name}'
            USING ERRCODE = '90214',
                  HINT = jsonb_build_object('field_name', NEW.field_name)::text;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY INVOKER SET search_path = public;

COMMENT ON FUNCTION lock_field_ctype IS
'BEFORE INSERT/UPDATE guard on fields: only a BYPASSRLS (DD/migration) caller may set or change ctype. Non-privileged users get ctype forced to '''' on INSERT and a rejection on any UPDATE that changes ctype. Keeps ctype (the core marker that "core = ctype <> ''" depends on) un-tamperable.';

REVOKE EXECUTE ON FUNCTION lock_field_ctype() FROM PUBLIC;

CREATE OR REPLACE TRIGGER fields_ctype_lock
    BEFORE INSERT OR UPDATE ON fields
    FOR EACH ROW
    EXECUTE FUNCTION lock_field_ctype();

-- =====================================================
-- TRIGGER FUNCTION: ADD FIELD ON INSERT
-- =====================================================

CREATE OR REPLACE FUNCTION add_dd_field()
RETURNS TRIGGER AS $$
DECLARE
    v_alter_sql TEXT;
    v_nullable_clause TEXT;
    v_default_clause TEXT;
    v_data_type TEXT;
    v_is_managed BOOLEAN;
    v_ref_id_column TEXT;
    v_fk_name TEXT;
    v_idx_name TEXT;
    v_on_delete TEXT;
    v_comment TEXT;
    v_rel TEXT;
BEGIN
    -- Suppress IF NOT EXISTS/IF EXISTS notices
    SET LOCAL client_min_messages = WARNING;
    
    -- Check if the parent table is managed
    -- The column goes into the entity's physical relation: <entity>_ext for
    -- an is_a or has_a entity, whose view the family refresh rebuilds after
    -- this statement.
    SELECT managed, dd_relation(table_name, id_type) INTO v_is_managed, v_rel
      FROM entities WHERE table_name = NEW.table_name;
    
    IF NOT v_is_managed THEN
        -- No DDL, but a column that already exists still gets its comment, as the
        -- update path does for unmanaged tables: the comment is what PostgREST shows.
        IF EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_schema = 'public'
              AND table_name   = v_rel
              AND column_name  = NEW.field_name
        ) THEN
            v_comment := dd_field_comment(NEW.title, NEW.format, NEW.description, NEW.enum_values);
            IF v_comment IS NOT NULL THEN
                EXECUTE format('COMMENT ON COLUMN %I.%I IS %L', v_rel, NEW.field_name, v_comment);
            END IF;
        END IF;
        RAISE NOTICE 'Skipping field addition for "%.%" (table managed=false)', NEW.table_name, NEW.field_name;
        RETURN NEW;
    END IF;
    
    -- Skip if this is the id or label column (already created by create_dd_table)
    IF NEW.field_name IN (
        SELECT id_column FROM entities WHERE table_name = NEW.table_name
        UNION
        SELECT label_column FROM entities WHERE table_name = NEW.table_name
    ) THEN
        -- Still set the column comment (title/format summary + description [+ enum values])
        v_comment := dd_field_comment(NEW.title, NEW.format, NEW.description, NEW.enum_values);
        IF v_comment IS NOT NULL THEN
            EXECUTE format('COMMENT ON COLUMN %I.%I IS %L', v_rel, NEW.field_name, v_comment);
        END IF;
        RETURN NEW;
    END IF;
    
    -- Convert format to PostgreSQL data type
    v_data_type := field_data_type(NEW.format, NEW."precision", NEW.reference_table);
    
    -- Build nullable clause based on format
    IF is_nullable(NEW.format) THEN
        v_nullable_clause := 'NULL';
    ELSE
        v_nullable_clause := 'NOT NULL';
    END IF;
    
    -- Build default clause with sensible defaults based on data type
    DECLARE
        v_resolved_default TEXT;
    BEGIN
        IF NEW.format = 'enum' THEN
            v_resolved_default := effective_enum_default(NEW.default_value, NEW.input_type, NEW.enum_values);
        ELSE
            v_resolved_default := NEW.default_value;
        END IF;

        IF v_resolved_default IS NOT NULL AND trim(v_resolved_default) != '' THEN
            v_default_clause := format('DEFAULT %s', quote_default_value(v_resolved_default, v_data_type));
        ELSIF NOT is_nullable(NEW.format) THEN
            -- Provide sensible defaults for NOT NULL columns without explicit default
            IF v_data_type IN ('JSONB', 'JSON') THEN
                IF NEW.format = 'array' THEN
                    v_default_clause := 'DEFAULT ''[]''::jsonb';
                ELSE
                    v_default_clause := 'DEFAULT ''{}''::jsonb';
                END IF;
            ELSE
                CASE
                    WHEN v_data_type = 'TEXT' THEN v_default_clause := 'DEFAULT ''''';
                    WHEN v_data_type IN ('INTEGER', 'BIGINT', 'SMALLINT') THEN v_default_clause := 'DEFAULT 0';
                    WHEN v_data_type IN ('REAL', 'DOUBLE PRECISION') OR v_data_type LIKE 'NUMERIC%' OR v_data_type LIKE 'DECIMAL%' THEN v_default_clause := 'DEFAULT 0.0';
                    WHEN v_data_type = 'BOOLEAN' THEN v_default_clause := 'DEFAULT FALSE';
                    WHEN v_data_type IN ('TIMESTAMP', 'TIMESTAMPTZ') THEN v_default_clause := 'DEFAULT CURRENT_TIMESTAMP';
                    WHEN v_data_type = 'DATE' THEN v_default_clause := 'DEFAULT CURRENT_DATE';
                    ELSE v_default_clause := '';
                END CASE;
            END IF;
        ELSE
            v_default_clause := '';
        END IF;
    END;
    
    -- Build ALTER TABLE statement
    v_alter_sql := format(
        'ALTER TABLE %I ADD COLUMN IF NOT EXISTS %I %s %s %s',
        v_rel,
        NEW.field_name,
        v_data_type,
        v_nullable_clause,
        v_default_clause
    );
    
    -- Add the column
    EXECUTE v_alter_sql;

    -- Set column comment: title/format summary + description [+ enum values]
    v_comment := dd_field_comment(NEW.title, NEW.format, NEW.description, NEW.enum_values);
    IF v_comment IS NOT NULL THEN
        EXECUTE format('COMMENT ON COLUMN %I.%I IS %L', v_rel, NEW.field_name, v_comment);
    END IF;

    -- If this is a primary key field, set it as primary key
    IF NEW.is_pk THEN
        -- Check if table already has a primary key
        IF EXISTS (
            SELECT 1 FROM fields 
            WHERE table_name = NEW.table_name
            AND is_pk = TRUE 
            AND field_name <> NEW.field_name
        ) THEN
            RAISE EXCEPTION 'Table ${table} already has a primary key'
                USING ERRCODE = '90215',
                      HINT = jsonb_build_object('table', NEW.table_name)::text;
        END IF;
        
        -- Add primary key constraint
        EXECUTE format(
            'ALTER TABLE %I DROP CONSTRAINT IF EXISTS %I',
            v_rel,
            v_rel || '_pkey'
        );
        
        EXECUTE format(
            'ALTER TABLE %I ADD PRIMARY KEY (%I)',
            v_rel,
            NEW.field_name
        );
    END IF;
    
    -- If this is a reference or parent field, add foreign key constraint
    IF NEW.format IN ('reference', 'parent') AND NEW.reference_table IS NOT NULL AND NEW.reference_table != '' THEN
        -- Get the id_column of the referenced table
        SELECT id_column INTO v_ref_id_column
        FROM entities
        WHERE table_name = NEW.reference_table;
        
        IF v_ref_id_column IS NULL THEN
            RAISE EXCEPTION 'Referenced table ${table} not found in entities'
                USING ERRCODE = '90212',
                      HINT = jsonb_build_object('table', NEW.reference_table)::text;
        END IF;
        
        -- Determine ON DELETE behavior based on reference_delete_mode
        IF NEW.reference_delete_mode = 'clear' THEN
            v_on_delete := 'SET NULL';
        ELSIF NEW.reference_delete_mode = 'cascade' THEN
            v_on_delete := 'CASCADE';
        ELSE
            v_on_delete := 'RESTRICT';
        END IF;
        
        -- Generate foreign key constraint name
        v_fk_name := format('%s_%s_fkey', v_rel, NEW.field_name);
        
        -- Add foreign key constraint (skip if constraint already exists - e.g. pre-existing schema FKs)
        -- ON UPDATE CASCADE carries a rewritten key value down to the referencing
        -- rows, which is what makes a referenced TEXT PK renameable (e.g.
        -- entities.table_name). A surrogate INTEGER key is never rewritten, so
        -- the clause sits there unused rather than doing something different.
        -- A reference to an is_a or has_a entity points at its <entity>_ext
        -- table: a view cannot be the target of a foreign key, and the record
        -- exists exactly when that part of it does.
        v_alter_sql := format(
            'ALTER TABLE %I ADD CONSTRAINT %I FOREIGN KEY (%I) REFERENCES %I(%I) ON DELETE %s ON UPDATE CASCADE',
            v_rel,
            v_fk_name,
            NEW.field_name,
            dd_relation(NEW.reference_table),
            v_ref_id_column,
            v_on_delete
        );
        BEGIN
            EXECUTE v_alter_sql;
        EXCEPTION WHEN duplicate_object THEN
            RAISE NOTICE 'Foreign key constraint "%" already exists on "%.%", skipping creation. Verify ON DELETE behavior matches expected: %',
                v_fk_name, NEW.table_name, NEW.field_name, v_on_delete;
        END;
        
        -- Create index for foreign key
        v_idx_name := format('idx_%s_%s', v_rel, NEW.field_name);
        v_alter_sql := format(
            'CREATE INDEX IF NOT EXISTS %I ON %I(%I)',
            v_idx_name,
            v_rel,
            NEW.field_name
        );
        EXECUTE v_alter_sql;
    END IF;
    
    -- If this is an enum field, add CHECK constraint for allowed values
    IF NEW.format = 'enum' AND NEW.enum_values IS NOT NULL AND jsonb_typeof(NEW.enum_values) = 'array' AND jsonb_array_length(NEW.enum_values) > 0 THEN
        DECLARE
            v_check_name TEXT;
            v_enum_values_sql TEXT;
            v_effective_enum JSONB;
        BEGIN
            -- Generate CHECK constraint name
            v_check_name := format('%s_%s_check', v_rel, NEW.field_name);
            
            -- Compute effective allowed values (adds '' for non-required enums)
            v_effective_enum := effective_enum_values(NEW.input_type, NEW.enum_values);

            -- Build SQL array from JSONB array for IN clause
            v_enum_values_sql := (
                SELECT string_agg(quote_literal(value::text), ', ')
                FROM jsonb_array_elements_text(enum_value_list(v_effective_enum)) AS value
            );
            
            -- Add CHECK constraint
            v_alter_sql := format(
                'ALTER TABLE %I ADD CONSTRAINT %I CHECK (%I IN (%s))',
                v_rel,
                v_check_name,
                NEW.field_name,
                v_enum_values_sql
            );
            EXECUTE v_alter_sql;
            
            RAISE NOTICE 'Added CHECK constraint "%" for enum field "%.%"',
                v_check_name, NEW.table_name, NEW.field_name;
        END;
    END IF;
    
    -- If unique_value is TRUE, create a partial unique index
    IF NEW.unique_value THEN
        DECLARE
            v_unique_idx_name TEXT;
            v_where_clause TEXT;
        BEGIN
            v_unique_idx_name := format('%s_%s_unique', v_rel, NEW.field_name);
            -- For string types, exclude NULL and empty string from uniqueness enforcement
            IF format_to_json_type(NEW.format)::text = '"string"' THEN
                v_where_clause := format('%I IS NOT NULL AND %I != ''''', NEW.field_name, NEW.field_name);
            ELSE
                v_where_clause := format('%I IS NOT NULL', NEW.field_name);
            END IF;
            EXECUTE format(
                'CREATE UNIQUE INDEX IF NOT EXISTS %I ON %I(%I) WHERE %s',
                v_unique_idx_name,
                v_rel,
                NEW.field_name,
                v_where_clause
            );
            RAISE NOTICE 'Created unique index "%" for field "%.%"', v_unique_idx_name, NEW.table_name, NEW.field_name;
        END;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION add_dd_field IS 
'Trigger function that adds a column to a table when a row is inserted into fields table.';

-- Apply trigger AFTER INSERT on fields
CREATE OR REPLACE TRIGGER add_field_trigger
    AFTER INSERT ON fields
    FOR EACH ROW
    EXECUTE FUNCTION add_dd_field();

-- =====================================================
-- TRIGGER FUNCTION: UPDATE FIELD ON UPDATE
-- =====================================================

-- apply_field_ddl() (0180_managed_enable.sql) and the BEFORE trigger
-- validate_field_rename_and_format (0170_dd_rename.sql) are defined later; no
-- fields row is updated during install before both exist.
CREATE OR REPLACE FUNCTION update_dd_field()
RETURNS TRIGGER AS $$
DECLARE
    v_alter_sql      TEXT;
    v_old_data_type  TEXT;
    v_new_data_type  TEXT;
    v_is_managed     BOOLEAN;
    v_ref_id_column  TEXT;
    v_fk_name        TEXT;
    v_idx_name       TEXT;
    v_on_delete      TEXT;
    v_comment        TEXT;
    v_rel            TEXT;
BEGIN
    -- Check if the parent table is managed. The DDL below goes to the entity's
    -- physical relation, <entity>_ext for an is_a or has_a entity.
    SELECT managed, dd_relation(table_name, id_type) INTO v_is_managed, v_rel
      FROM entities WHERE table_name = NEW.table_name;

    -- Prevent changing critical attributes
    IF OLD.table_name <> NEW.table_name THEN
        -- Allow only when this is a cascade triggered by rename_dd_table(),
        -- which sets the marker to 'old:new' immediately before updating the
        -- fields rows.
        --
        -- IS DISTINCT FROM, not <>. current_setting(..., TRUE) returns SQL NULL
        -- in a session that never set the variable, `NULL <> anything` is NULL,
        -- and an IF on NULL is not taken - so a plain `UPDATE fields SET
        -- table_name = ...` would walk straight through this guard and hand the
        -- field's metadata to another entity while the physical column stayed
        -- where it was, leaving the catalog and the tables disagreeing.
        IF current_setting('dd.table_rename', TRUE) IS DISTINCT FROM OLD.table_name || ':' || NEW.table_name THEN
            RAISE EXCEPTION 'Cannot change table_name of a field' USING ERRCODE = '90221';
        END IF;
        -- Cascade rename: metadata has been updated; no DDL needed here
        RETURN NEW;
    END IF;

    -- field_name was renamed by validate_field_rename_and_format() BEFORE trigger;
    -- no exception here — just continue with the rest of the DDL using NEW.field_name.

    IF OLD.is_pk <> NEW.is_pk THEN
        RAISE EXCEPTION 'Cannot change primary key status of existing field' USING ERRCODE = '90222';
    END IF;

    -- Prevent changing structural attributes of core fields (a non-empty ctype marks a
    -- DD-managed core column); ctype itself is immutable + privilege-locked (fields_ctype_lock).
    IF coalesce(OLD.ctype, '') <> '' THEN
        IF OLD.format <> NEW.format THEN
            RAISE EXCEPTION 'Cannot change format of core system field ${field_name}'
                USING ERRCODE = '90219',
                      HINT = jsonb_build_object('field_name', OLD.field_name)::text;
        END IF;

        IF OLD.default_value IS DISTINCT FROM NEW.default_value THEN
            RAISE EXCEPTION 'Cannot change default value of core system field ${field_name}'
                USING ERRCODE = '90220',
                      HINT = jsonb_build_object('field_name', OLD.field_name)::text;
        END IF;
    END IF;

    -- Skip DDL operations if table is not managed (but allow metadata updates like description)
    IF NOT v_is_managed THEN
        -- Keep the column comment in sync even if not managed, but only when the
        -- physical column actually exists (an unmanaged entity may be metadata-only
        -- with no physical table/column to comment on).
        IF (OLD.title IS DISTINCT FROM NEW.title
            OR OLD.format IS DISTINCT FROM NEW.format
            OR OLD.description IS DISTINCT FROM NEW.description
            OR OLD.enum_values IS DISTINCT FROM NEW.enum_values)
           AND EXISTS (
               SELECT 1 FROM information_schema.columns
               WHERE table_schema = 'public'
                 AND table_name   = v_rel
                 AND column_name  = NEW.field_name
           ) THEN
            v_comment := dd_field_comment(NEW.title, NEW.format, NEW.description, NEW.enum_values);
            IF v_comment IS NOT NULL THEN
                EXECUTE format('COMMENT ON COLUMN %I.%I IS %L', v_rel, NEW.field_name, v_comment);
            ELSE
                EXECUTE format('COMMENT ON COLUMN %I.%I IS NULL', v_rel, NEW.field_name);
            END IF;
        END IF;

        RAISE NOTICE 'Skipping DDL operations for "%.%" (table managed=false)', NEW.table_name, NEW.field_name;
        RETURN NEW;
    END IF;

    -- If the physical column is missing from a managed table (e.g. it was defined
    -- while managed=false), create it now with the new field values and return.
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name   = v_rel
          AND column_name  = NEW.field_name
    ) THEN
        PERFORM apply_field_ddl(NEW);
        RAISE NOTICE 'Created missing column "%.%" in managed table', NEW.table_name, NEW.field_name;
        RETURN NEW;
    END IF;

    -- Keep column comment in sync when title/format/description/enum values change
    IF OLD.title IS DISTINCT FROM NEW.title
       OR OLD.format IS DISTINCT FROM NEW.format
       OR OLD.description IS DISTINCT FROM NEW.description
       OR OLD.enum_values IS DISTINCT FROM NEW.enum_values THEN
        v_comment := dd_field_comment(NEW.title, NEW.format, NEW.description, NEW.enum_values);
        IF v_comment IS NOT NULL THEN
            EXECUTE format('COMMENT ON COLUMN %I.%I IS %L', v_rel, NEW.field_name, v_comment);
        ELSE
            EXECUTE format('COMMENT ON COLUMN %I.%I IS NULL', v_rel, NEW.field_name);
        END IF;
    END IF;

    -- Handle format change
    IF OLD.format <> NEW.format THEN
        v_old_data_type := field_data_type(OLD.format, OLD."precision", OLD.reference_table);
        v_new_data_type := field_data_type(NEW.format, NEW."precision", NEW.reference_table);

        IF v_old_data_type <> v_new_data_type THEN
            RAISE EXCEPTION
                'Cannot change format of field ${field_name} from ${old_format} to ${new_format} '
                'because it would require changing the column type from ${old_type} to ${new_type}. '
                'Drop and recreate the field instead.'
                USING ERRCODE = '90223',
                      HINT = jsonb_build_object(
                          'field_name', NEW.field_name,
                          'old_format', OLD.format,
                          'new_format', NEW.format,
                          'old_type',   v_old_data_type,
                          'new_type',   v_new_data_type)::text;
        END IF;

        RAISE NOTICE 'Changed format of column "%" from "%" to "%" in table "%" (data type unchanged: %)',
            NEW.field_name, OLD.format, NEW.format, NEW.table_name, v_new_data_type;
    END IF;

    -- Allow updating nullable constraint (derived from format)
    IF is_nullable(OLD.format) <> is_nullable(NEW.format) THEN
        IF is_nullable(NEW.format) THEN
            v_alter_sql := format(
                'ALTER TABLE %I ALTER COLUMN %I DROP NOT NULL',
                v_rel, NEW.field_name
            );
        ELSE
            v_alter_sql := format(
                'ALTER TABLE %I ALTER COLUMN %I SET NOT NULL',
                v_rel, NEW.field_name
            );
        END IF;
        EXECUTE v_alter_sql;
        RAISE NOTICE 'Changed column "%" nullable to % in table "%"',
            NEW.field_name, is_nullable(NEW.format), NEW.table_name;
    END IF;

    -- Allow updating default value
    IF OLD.default_value IS DISTINCT FROM NEW.default_value THEN
        IF NEW.default_value IS NULL THEN
            v_alter_sql := format(
                'ALTER TABLE %I ALTER COLUMN %I DROP DEFAULT',
                v_rel, NEW.field_name
            );
        ELSE
            v_alter_sql := format(
                'ALTER TABLE %I ALTER COLUMN %I SET DEFAULT %s',
                v_rel, NEW.field_name,
                quote_default_value(NEW.default_value, field_data_type(NEW.format, NEW."precision", NEW.reference_table))
            );
        END IF;
        EXECUTE v_alter_sql;
        RAISE NOTICE 'Changed column "%" default value in table "%"',
            NEW.field_name, NEW.table_name;
    END IF;

    -- Handle foreign key reference changes
    IF OLD.format IN ('reference', 'parent') OR NEW.format IN ('reference', 'parent') THEN
        v_fk_name  := format('%s_%s_fkey', v_rel, NEW.field_name);
        v_idx_name := format('idx_%s_%s',  v_rel, NEW.field_name);

        IF (OLD.reference_table IS DISTINCT FROM NEW.reference_table) OR
           (OLD.reference_delete_mode IS DISTINCT FROM NEW.reference_delete_mode) OR
           (OLD.format <> NEW.format)
        THEN
            -- Drop existing FK constraint if it exists
            IF OLD.format IN ('reference', 'parent') THEN
                EXECUTE format(
                    'ALTER TABLE %I DROP CONSTRAINT IF EXISTS %I',
                    v_rel, v_fk_name
                );
                RAISE NOTICE 'Dropped foreign key constraint "%"', v_fk_name;
            END IF;

            -- Add new FK constraint
            IF NEW.format IN ('reference', 'parent')
               AND NEW.reference_table IS NOT NULL
               AND NEW.reference_table != ''
            THEN
                SELECT id_column INTO v_ref_id_column
                FROM entities WHERE table_name = NEW.reference_table;

                IF v_ref_id_column IS NULL THEN
                    RAISE EXCEPTION 'Referenced table ${table} not found in entities'
                        USING ERRCODE = '90212',
                              HINT = jsonb_build_object('table', NEW.reference_table)::text;
                END IF;

                IF NEW.reference_delete_mode = 'clear' THEN
                    v_on_delete := 'SET NULL';
                ELSIF NEW.reference_delete_mode = 'cascade' THEN
                    v_on_delete := 'CASCADE';
                ELSE
                    v_on_delete := 'RESTRICT';
                END IF;

                v_alter_sql := format(
                    'ALTER TABLE %I ADD CONSTRAINT %I FOREIGN KEY (%I) REFERENCES %I(%I) ON DELETE %s ON UPDATE CASCADE',
                    v_rel, v_fk_name, NEW.field_name,
                    dd_relation(NEW.reference_table), v_ref_id_column, v_on_delete
                );
                EXECUTE v_alter_sql;

                v_alter_sql := format(
                    'CREATE INDEX IF NOT EXISTS %I ON %I(%I)',
                    v_idx_name, v_rel, NEW.field_name
                );
                EXECUTE v_alter_sql;

                RAISE NOTICE 'Updated foreign key "%" from %.% to %.% with ON DELETE %',
                    v_fk_name, NEW.table_name, NEW.field_name,
                    NEW.reference_table, v_ref_id_column, v_on_delete;
            ELSIF NEW.format NOT IN ('reference', 'parent') AND OLD.format IN ('reference', 'parent') THEN
                EXECUTE format('DROP INDEX IF EXISTS %I', v_idx_name);
                RAISE NOTICE 'Dropped index "%" for field "%.%"', v_idx_name, NEW.table_name, NEW.field_name;
            END IF;
        END IF;
    END IF;

    -- Handle enum CHECK constraint changes
    IF OLD.format = 'enum' OR NEW.format = 'enum' THEN
        DECLARE
            v_check_name      TEXT;
            v_enum_values_sql TEXT;
            v_effective_enum  JSONB;
        BEGIN
            v_check_name := format('%s_%s_check', v_rel, NEW.field_name);

            IF (OLD.enum_values IS DISTINCT FROM NEW.enum_values)
               OR (OLD.format <> NEW.format)
               OR (OLD.input_type IS DISTINCT FROM NEW.input_type) THEN
                IF OLD.format = 'enum' THEN
                    EXECUTE format(
                        'ALTER TABLE %I DROP CONSTRAINT IF EXISTS %I',
                        v_rel, v_check_name
                    );
                    RAISE NOTICE 'Dropped CHECK constraint "%"', v_check_name;
                END IF;

                IF NEW.format = 'enum'
                   AND NEW.enum_values IS NOT NULL
                   AND jsonb_typeof(NEW.enum_values) = 'array'
                   AND jsonb_array_length(NEW.enum_values) > 0
                THEN
                    v_effective_enum := effective_enum_values(NEW.input_type, NEW.enum_values);
                    v_enum_values_sql := (
                        SELECT string_agg(quote_literal(value::text), ', ')
                        FROM jsonb_array_elements_text(enum_value_list(v_effective_enum)) AS value
                    );
                    v_alter_sql := format(
                        'ALTER TABLE %I ADD CONSTRAINT %I CHECK (%I IN (%s))',
                        v_rel, v_check_name, NEW.field_name, v_enum_values_sql
                    );
                    EXECUTE v_alter_sql;
                    RAISE NOTICE 'Updated CHECK constraint "%" for enum field "%.%"',
                        v_check_name, NEW.table_name, NEW.field_name;
                END IF;
            END IF;
        END;
    END IF;

    -- Handle unique_value changes
    IF OLD.unique_value IS DISTINCT FROM NEW.unique_value THEN
        DECLARE
            v_unique_idx_name TEXT;
            v_where_clause    TEXT;
        BEGIN
            v_unique_idx_name := format('%s_%s_unique', v_rel, NEW.field_name);
            IF NEW.unique_value THEN
                IF format_to_json_type(NEW.format)::text = '"string"' THEN
                    v_where_clause := format('%I IS NOT NULL AND %I != ''''',
                        NEW.field_name, NEW.field_name);
                ELSE
                    v_where_clause := format('%I IS NOT NULL', NEW.field_name);
                END IF;
                EXECUTE format(
                    'CREATE UNIQUE INDEX IF NOT EXISTS %I ON %I(%I) WHERE %s',
                    v_unique_idx_name, v_rel, NEW.field_name, v_where_clause
                );
                RAISE NOTICE 'Created unique index "%" for field "%.%"',
                    v_unique_idx_name, NEW.table_name, NEW.field_name;
            ELSE
                EXECUTE format('DROP INDEX IF EXISTS %I', v_unique_idx_name);
                RAISE NOTICE 'Dropped unique index "%" for field "%.%"',
                    v_unique_idx_name, NEW.table_name, NEW.field_name;
            END IF;
        END;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION update_dd_field IS
'Trigger function that updates column properties when a field is updated.
table_name changes are allowed only as part of a cascade from rename_dd_table().
field_name renames are handled by the validate_field_rename_and_format BEFORE trigger.
format changes that alter the underlying data type are rejected by the BEFORE trigger.
When the physical column is missing from a managed table (e.g. defined while managed=false),
the column is created via apply_field_ddl() and the function returns early.';

-- Apply trigger AFTER UPDATE on fields
CREATE OR REPLACE TRIGGER update_field_trigger
    AFTER UPDATE ON fields
    FOR EACH ROW
    EXECUTE FUNCTION update_dd_field();

-- =====================================================
-- TRIGGER FUNCTION: DELETE FIELD ON DELETE
-- =====================================================

CREATE OR REPLACE FUNCTION delete_dd_field()
RETURNS TRIGGER AS $$
DECLARE
    v_is_managed BOOLEAN;
    v_table_exists BOOLEAN;
    v_fk_name TEXT;
    v_idx_name TEXT;
    v_rel TEXT;
BEGIN
    -- Check if the parent table still exists in entities table
    -- If it doesn't exist, this deletion is part of a CASCADE from table deletion, so allow it
    v_table_exists := EXISTS (SELECT 1 FROM entities WHERE table_name = OLD.table_name);
    
    IF NOT v_table_exists THEN
        -- Table is being deleted, allow cascade deletion of all fields including core fields
        RETURN OLD;
    END IF;
    
    -- Prevent deletion of core fields (a non-empty ctype marks a DD-managed core column)
    -- for standalone field deletions.
    IF coalesce(OLD.ctype, '') <> '' THEN
        RAISE EXCEPTION 'Cannot delete core system field ${field_name}. Core fields (ctype id/label/audit/core) cannot be deleted.'
            USING ERRCODE = '90217',
                  HINT = jsonb_build_object('field_name', OLD.field_name)::text;
    END IF;
    
    -- Check if the parent table is managed
    SELECT managed, dd_relation(table_name, id_type) INTO v_is_managed, v_rel
      FROM entities WHERE table_name = OLD.table_name;
    
    IF NOT v_is_managed THEN
        RAISE NOTICE 'Skipping field deletion for "%.%" (table managed=false)', OLD.table_name, OLD.field_name;
        RETURN OLD;
    END IF;
    
    -- Drop foreign key constraint if this is a reference or parent field
    IF OLD.format IN ('reference', 'parent') THEN
        v_fk_name := format('%s_%s_fkey', v_rel, OLD.field_name);
        EXECUTE format(
            'ALTER TABLE %I DROP CONSTRAINT IF EXISTS %I',
            v_rel,
            v_fk_name
        );
        RAISE NOTICE 'Dropped foreign key constraint "%"', v_fk_name;
        
        -- Drop index for foreign key
        v_idx_name := format('idx_%s_%s', v_rel, OLD.field_name);
        EXECUTE format(
            'DROP INDEX IF EXISTS %I',
            v_idx_name
        );
        RAISE NOTICE 'Dropped index "%"', v_idx_name;
    END IF;
    
    -- Drop unique index if unique_value was set
    IF OLD.unique_value THEN
        EXECUTE format('DROP INDEX IF EXISTS %I', format('%s_%s_unique', v_rel, OLD.field_name));
        RAISE NOTICE 'Dropped unique index "%"', format('%s_%s_unique', v_rel, OLD.field_name);
    END IF;
    
    -- Drop the column (CASCADE to drop any dependent objects like generated
    -- columns, and the views of the entity and its descendants that show it,
    -- which the family refresh at the end of the statement rebuilds). The
    -- views would take the objects built on them along before the refresh
    -- could see them, so those are checked here (90256).
    PERFORM dd_check_family_dependents(ARRAY[OLD.table_name]);
    EXECUTE format(
        'ALTER TABLE %I DROP COLUMN IF EXISTS %I CASCADE',
        v_rel,
        OLD.field_name
    );
    
    RAISE NOTICE 'Dropped column "%" from table "%"',
        OLD.field_name, OLD.table_name;
    
    RETURN OLD;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION delete_dd_field IS 
'Trigger function that drops a column when a field is deleted.';

-- Apply trigger BEFORE DELETE on fields
CREATE OR REPLACE TRIGGER delete_field_trigger
    BEFORE DELETE ON fields
    FOR EACH ROW
    EXECUTE FUNCTION delete_dd_field();

-- =====================================================
-- TRIGGER FUNCTION: DELETE TABLE ON DELETE
-- =====================================================

CREATE OR REPLACE FUNCTION delete_dd_table()
RETURNS TRIGGER AS $$
DECLARE
    v_derived    BOOLEAN := OLD.id_type IN ('is_a', 'has_a');
    v_rel        TEXT := dd_relation(OLD.table_name, OLD.id_type);
    v_dependents TEXT;
    v_has_rows   BOOLEAN := FALSE;
BEGIN
    -- The family refusals come first, before anything is dropped.
    --
    -- A base may not go while entities are based on it: their records are
    -- partly stored in its table. A dependent whose module row is already gone
    -- does not count - it is being deleted by the same module-delete cascade,
    -- in whatever order the cascade reaches the rows. The RESTRICT foreign key
    -- entities_id_refentity_fkey is the backstop for anything this misses.
    SELECT string_agg(d.table_name, ', ' ORDER BY d.table_name)
      INTO v_dependents
      FROM entities d
      JOIN modules m ON m.id = d.module_id
     WHERE d.id_refentity = OLD.table_name;
    IF v_dependents IS NOT NULL THEN
        RAISE EXCEPTION 'Entity ${table} cannot be deleted while ${dependents} are based on it'
            USING ERRCODE = '90248',
                  HINT = jsonb_build_object('table', OLD.table_name, 'dependents', v_dependents)::text;
    END IF;

    -- A plain entity is dropped with its data. A family entity is not: its
    -- records span several tables, and dropping one of them would leave the
    -- rest of every record behind (or, for a base, drop the foreign keys that
    -- hold its dependents' parts to it). The records go first, through the
    -- entity, where every part's rules and permissions apply. This holds
    -- inside a module-delete cascade too, which is therefore refused while a
    -- family entity of the module still has records. As the definer, which
    -- owns the table, the count sees every row, not only the caller's.
    IF OLD.managed
       AND (v_derived OR EXISTS (SELECT 1 FROM entities d WHERE d.id_refentity = OLD.table_name))
       AND to_regclass(format('public.%I', v_rel)) IS NOT NULL THEN
        EXECUTE format('SELECT EXISTS (SELECT 1 FROM public.%I)', v_rel) INTO v_has_rows;
    END IF;
    IF v_has_rows THEN
        RAISE EXCEPTION 'Entity ${table} still has records; delete them first'
            USING ERRCODE = '90247',
                  HINT = jsonb_build_object('table', OLD.table_name)::text;
    END IF;

    -- Skip DDL execution if table is not managed
    IF NOT OLD.managed THEN
        RAISE NOTICE 'Skipping table deletion for "%" (managed=false)', OLD.table_name;
        RETURN OLD;
    END IF;

    -- Dropping a family entity drops its view, and a root's DROP TABLE (only
    -- in a module-delete cascade) every view of its family; the rest of the
    -- family is rebuilt afterwards. Objects of another author built on those
    -- views would go with them, so the delete is refused while one exists
    -- (90256). A plain entity's delete still drops what is built on its table.
    PERFORM dd_check_family_dependents(ARRAY[OLD.table_name]);

    IF v_derived THEN
        -- The view takes its INSTEAD OF trigger, the write routine and the
        -- label functions (all typed by its row type) with it; the trigger
        -- function and the rules are dropped by name. IF EXISTS throughout: in
        -- a module-delete cascade the base may have gone first, and its DROP
        -- TABLE ... CASCADE took this view already. The rest of the family is
        -- rebuilt without this entity by zz_family_refresh_delete_trigger.
        EXECUTE format('DROP VIEW IF EXISTS public.%I CASCADE', OLD.table_name);
        EXECUTE format('DROP FUNCTION IF EXISTS common.%I() CASCADE', 'view_write_' || OLD.table_name);
        EXECUTE format('DROP FUNCTION IF EXISTS common.%I(text, jsonb, jsonb)', 'record_rules_' || OLD.table_name);
        EXECUTE format('DROP TABLE IF EXISTS public.%I CASCADE', v_rel);
    ELSE
        -- Drop the table (CASCADE will drop all dependent objects)
        EXECUTE format('DROP TABLE IF EXISTS %I CASCADE', OLD.table_name);
        -- A family root reaches here only in a module-delete cascade, where its
        -- dispatch trigger went with the table and the function stays behind.
        EXECUTE format('DROP FUNCTION IF EXISTS common.%I() CASCADE', 'is_a_dispatch_' || OLD.table_name);
    END IF;

    RAISE NOTICE 'Dropped table "%"', OLD.table_name;

    RETURN OLD;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION delete_dd_table IS
'Trigger function that drops a table when a row is deleted from entities table. Refuses first when entities are still based on it (90248) or when an is_a/has_a family entity still has records (90247); for an is_a or has_a entity it drops the view, its generated routines and <entity>_ext.';

-- Apply trigger BEFORE DELETE on entities
-- Note: Fields will be deleted via CASCADE on the foreign key
CREATE OR REPLACE TRIGGER delete_table_trigger
    BEFORE DELETE ON entities
    FOR EACH ROW
    EXECUTE FUNCTION delete_dd_table();

-- =====================================================
-- TRIGGER FUNCTION: update RLS policies on permission change
-- =====================================================
-- When entities.edit_permission is changed, the INSERT, UPDATE, and DELETE
-- RLS policies must be dropped and recreated with the new permission value.
--
-- NOTE: The SELECT policy is already handled by manage_select_rule_policy
-- (in 0210_computed_validation.sql) which fires when view_permission changes.

CREATE OR REPLACE FUNCTION update_entity_policies()
RETURNS TRIGGER AS $$
DECLARE
    v_rel TEXT := dd_relation(NEW.table_name, NEW.id_type);
BEGIN
    -- Only act on managed tables that have physical RLS policies
    IF NOT NEW.managed THEN
        RETURN NEW;
    END IF;

    -- Sub-select form: see the note in create_dd_table (P1).
    -- INSERT policy is edit_permission-only (there is no per-row rule on inserts).
    EXECUTE format('DROP POLICY IF EXISTS %I ON %I',
        v_rel || '_insert_policy', v_rel);
    EXECUTE format(
        'CREATE POLICY %I ON %I FOR INSERT TO semantius_user WITH CHECK ((SELECT rbac.has_permission(%L)))',
        v_rel || '_insert_policy', v_rel, NEW.edit_permission);

    -- SELECT/UPDATE/DELETE are rule-aware: build_select_rule_policy() rebuilds them on the
    -- canonical predicate (select_rule when set, else view/edit permission). Delegating here
    -- keeps the read policy, the read helpers, and the write USING clauses on ONE predicate,
    -- so an edit_permission change does not silently strip the row rule from writes.
    PERFORM build_select_rule_policy(NEW.table_name);

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION update_entity_policies IS
'AFTER UPDATE trigger on entities: drops and recreates INSERT, UPDATE, and DELETE
RLS policies when edit_permission changes. The SELECT policy is handled separately
by manage_select_rule_policy (0210_computed_validation.sql).';

CREATE OR REPLACE TRIGGER update_entity_policies_trigger
    AFTER UPDATE ON entities
    FOR EACH ROW
    WHEN (OLD.edit_permission IS DISTINCT FROM NEW.edit_permission)
    EXECUTE FUNCTION update_entity_policies();

COMMENT ON TRIGGER update_entity_policies_trigger ON entities IS
'Rebuilds INSERT/UPDATE/DELETE RLS policies when entities.edit_permission is updated';

-- =====================================================
-- TRIGGER FUNCTION: typeid prefix change
-- =====================================================
-- A typeid entity's prefix lives in two places: entities.id_prefix and the
-- argument of its table's typeid_assign trigger, which is what generates and
-- checks ids. Recreating the trigger takes a brief lock on the table and scans
-- nothing: existing rows keep the ids they were given, because a key never
-- changes, and there is no CHECK over the prefix that would have to be
-- re-validated. From the next insert on, new ids carry the new prefix and an
-- id with the old one is refused, so re-importing an export taken before the
-- change fails for the rows it would add.
--
-- A family root's trigger also carries its is_a subtypes' prefixes, which
-- dd_install_id_triggers adds itself; an is_a prefix never changes (90245).
-- The generated write routines of the root's has_a extensions check a
-- supplied id against the root's prefix, which is written into them, so the
-- family is rebuilt as well.
CREATE OR REPLACE FUNCTION dd_sync_typeid_prefix()
RETURNS TRIGGER AS $$
BEGIN
    IF NOT NEW.managed OR NEW.id_type <> 'typeid'
       OR to_regclass(format('public.%I', NEW.table_name)) IS NULL THEN
        RETURN NEW;
    END IF;
    PERFORM dd_install_id_triggers(NEW.table_name, NEW.id_column, NEW.id_type, NEW.id_prefix);
    PERFORM dd_refresh_family(ARRAY[NEW.table_name]);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION dd_sync_typeid_prefix() IS
'AFTER UPDATE OF id_prefix trigger on entities: recreates the typeid_assign trigger of a managed typeid entity''s table with the new prefix (and its is_a subtypes'' prefixes), and rebuilds its family''s write routines. Takes a brief lock, scans nothing; existing ids keep their prefix.';

CREATE OR REPLACE TRIGGER sync_typeid_prefix_trigger
    AFTER UPDATE OF id_prefix ON entities
    FOR EACH ROW
    WHEN (OLD.id_prefix IS DISTINCT FROM NEW.id_prefix)
    EXECUTE FUNCTION dd_sync_typeid_prefix();

-- =====================================================
-- FULL-TEXT SEARCH FUNCTIONS AND TRIGGERS
-- =====================================================
-- Manages search_vector column and GIN index based on searchable fields
-- Automatically maintains entities.searchable based on related fields

-- =====================================================
-- HELPER FUNCTION: Update search_vector column and index
-- =====================================================
-- This function generates and executes DDL to create/recreate the search_vector
-- column and GIN index for a table based on its searchable fields

CREATE OR REPLACE FUNCTION update_search_vector_column(p_table_name TEXT)
RETURNS VOID AS $$
DECLARE
    v_searchable_fields TEXT[];
    v_search_expr TEXT;
    v_table_exists BOOLEAN;
    v_relid REGCLASS;
    v_attnum SMALLINT;
    v_current_fingerprint TEXT;
    v_new_fingerprint TEXT;
    v_index_name TEXT;
    v_index_exists BOOLEAN;
    -- The entity's physical relation. An is_a or has_a entity's table keeps
    -- the search_vector of its own fields only; its view concatenates the
    -- vectors of all the tables the record is stored in.
    v_rel TEXT := dd_relation(p_table_name);
BEGIN
    -- Note: no rbac.uid() here — this function is called by triggers
    -- during migrations when there is no JWT context.

    -- Suppress IF NOT EXISTS/IF EXISTS notices
    SET LOCAL client_min_messages = WARNING;

    -- Check if the table actually exists in the database
    v_table_exists := EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'public' AND table_name = v_rel
    );
    
    IF NOT v_table_exists THEN

        RETURN;
    END IF;

    v_relid := format('public.%I', v_rel)::regclass;
    v_index_name := v_rel || '_search_vector_idx';

    -- What is installed right now: the generated column, if any, and the
    -- fingerprint we stamped into its comment the last time we built it. Both
    -- come back NULL when there is nothing to compare against.
    SELECT a.attnum, col_description(v_relid, a.attnum::int)
    INTO v_attnum, v_current_fingerprint
    FROM pg_attribute a
    WHERE a.attrelid = v_relid
      AND a.attname = 'search_vector'
      AND a.attgenerated = 's'
      AND NOT a.attisdropped;

    -- Get all searchable text-based fields for this table that actually exist as columns
    SELECT ARRAY_AGG(field_name ORDER BY field_order)
    INTO v_searchable_fields
    FROM fields f
    WHERE f.table_name = p_table_name
      AND f.searchable = TRUE
      AND format_to_json_type(f.format)::text = '"string"'  -- Only text-based fields
      AND EXISTS (  -- Only include fields that actually exist as columns in the table
          SELECT 1 FROM information_schema.columns c
          WHERE c.table_schema = 'public'
            AND c.table_name = v_rel
            AND c.column_name = f.field_name
      );
    
    -- If no searchable fields, drop the search_vector column and index if they exist
    IF v_searchable_fields IS NULL OR array_length(v_searchable_fields, 1) IS NULL THEN
        -- Nothing installed and nothing wanted: skip the DDL. ALTER TABLE takes
        -- ACCESS EXCLUSIVE before it evaluates IF EXISTS, so even a drop that
        -- matches nothing blocks the table for the rest of the transaction.
        IF v_attnum IS NULL THEN
            RETURN;
        END IF;

        -- Drop the GIN index first
        EXECUTE format(
            'DROP INDEX IF EXISTS %I',
            v_index_name
        );
        
        -- Drop the search_vector column. CASCADE takes the family views
        -- that show it; the family refresh at the end of the same field
        -- statement rebuilds them (dd_refresh_family, called from
        -- apply_field_searchable_change). Without it, the first searchable
        -- change on a family table would fail on the view depending on the
        -- column. The views would take the objects built on them along
        -- before the refresh could see them, so those are checked here
        -- (90256).
        PERFORM dd_check_family_dependents(ARRAY[p_table_name]);
        EXECUTE format(
            'ALTER TABLE %I DROP COLUMN IF EXISTS search_vector CASCADE',
            v_rel
        );
        

        RETURN;
    END IF;
    
    -- Build the tsvector expression by concatenating all searchable fields
    -- Using coalesce to handle NULL values and setweight for ranking
    v_search_expr := (
        SELECT string_agg(
            format('setweight(to_tsvector(''simple'', coalesce(%I, '''')), ''%s'')',
                f.field_name,
                CASE 
                    WHEN f.ctype = 'label' THEN 'A'  -- Label fields get highest weight
                    WHEN f.field_name IN ('title', 'name') THEN 'A'  -- Title/name fields
                    WHEN f.field_name LIKE '%description%' THEN 'B'  -- Description fields
                    ELSE 'C'  -- Other searchable fields
                END
            ),
            ' || '
            ORDER BY f.field_order
        )
        FROM fields f
        WHERE f.table_name = p_table_name
          AND f.searchable = TRUE
          AND format_to_json_type(f.format)::text = '"string"'
          AND EXISTS (  -- Only include fields that actually exist as columns
              SELECT 1 FROM information_schema.columns c
              WHERE c.table_schema = 'public'
                AND c.table_name = v_rel
                AND c.column_name = f.field_name
          )
    );
    
    -- Everything below is one full table rewrite: ADD COLUMN ... GENERATED ...
    -- STORED has to materialize the tsvector for every existing row, so it holds
    -- ACCESS EXCLUSIVE (blocking readers, not just writers) for the whole
    -- rewrite and rebuilds every index on the table -- about 650 ms per 100k
    -- rows, linear. Skip it when the installed column was generated from exactly
    -- this expression and its index is still in place.
    --
    -- The comparison is against a fingerprint of the text we generate, not
    -- against pg_get_expr(): PostgreSQL deparses the stored expression with
    -- casts of its own ('simple'::regconfig, 'A'::"char"), so the deparsed form
    -- never matches what is built above and the guard would never fire.
    v_new_fingerprint := 'fts:' || md5(v_search_expr);

    v_index_exists := EXISTS (
        SELECT 1
        FROM pg_class i
        JOIN pg_namespace n ON n.oid = i.relnamespace
        WHERE n.nspname = 'public'
          AND i.relname = v_index_name
          AND i.relkind = 'i'
    );

    IF v_index_exists AND v_current_fingerprint IS NOT DISTINCT FROM v_new_fingerprint THEN
        RETURN;
    END IF;

    -- Drop existing search_vector column if it exists (CASCADE: see above)
    PERFORM dd_check_family_dependents(ARRAY[p_table_name]);
    EXECUTE format(
        'ALTER TABLE %I DROP COLUMN IF EXISTS search_vector CASCADE',
        v_rel
    );
    
    -- Create the search_vector column as GENERATED ALWAYS
    EXECUTE format(
        'ALTER TABLE %I ADD COLUMN search_vector tsvector GENERATED ALWAYS AS (%s) STORED',
        v_rel,
        v_search_expr
    );
    
    -- Drop existing GIN index if it exists
    EXECUTE format(
        'DROP INDEX IF EXISTS %I',
        v_index_name
    );
    
    -- Create GIN index on the search_vector column
    EXECUTE format(
        'CREATE INDEX %I ON %I USING GIN (search_vector)',
        v_index_name,
        v_rel
    );

    -- Stamp the fingerprint so the next call can tell whether anything changed.
    EXECUTE format(
        'COMMENT ON COLUMN %I.search_vector IS %L',
        v_rel,
        v_new_fingerprint
    );

END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION update_search_vector_column IS 
'Creates or updates the search_vector GENERATED column and GIN index for a table based on searchable fields. Works for both managed and core tables as long as the physical table exists. Rebuilding is a full table rewrite under ACCESS EXCLUSIVE (~650 ms per 100k rows) that also rebuilds every index on the table, so it is skipped when the generated expression is unchanged; the check is a fingerprint stored in the column comment.';

-- =====================================================
-- HELPER FUNCTION: Update entities.searchable flag
-- =====================================================
-- Auto-maintains the searchable flag on tables based on related fields

CREATE OR REPLACE FUNCTION update_table_searchable_flag(p_table_name TEXT)
RETURNS VOID AS $$
BEGIN
    -- Note: no rbac.uid() here — this function is called by triggers
    -- during migrations when there is no JWT context.

    -- IS DISTINCT FROM is not a micro-optimization: this runs on every field
    -- write, and a no-op entities UPDATE still fires its whole trigger stack.
    -- The entities based on this one inherit its fields, so their flags move
    -- with its own.
    UPDATE entities e
    SET searchable = dd_entity_searchable(e.table_name)
    WHERE (e.table_name = p_table_name
           OR e.table_name IN (SELECT d.table_name FROM dd_descendants(p_table_name) d))
      AND e.searchable IS DISTINCT FROM dd_entity_searchable(e.table_name);

END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION update_table_searchable_flag IS 
'Auto-maintains the searchable flag of an entity and of the entities based on it (dd_entity_searchable).';

-- =====================================================
-- HELPER FUNCTION: Apply the searchable changes of one statement
-- =====================================================
-- Shared by the three statement-level triggers below.

CREATE OR REPLACE FUNCTION apply_field_searchable_change(
    p_rebuild TEXT[],
    p_touched TEXT[]
)
RETURNS VOID AS $$
DECLARE
    v_table_name TEXT;
BEGIN
    -- Note: no rbac.uid() here — this function is called by triggers
    -- during migrations when there is no JWT context.

    -- One rebuild per table per statement, never one per changed field row:
    -- a rebuild is a full table rewrite under ACCESS EXCLUSIVE.
    FOREACH v_table_name IN ARRAY coalesce(p_rebuild, ARRAY[]::TEXT[]) LOOP
        PERFORM update_search_vector_column(v_table_name);
    END LOOP;

    FOREACH v_table_name IN ARRAY coalesce(p_touched, ARRAY[]::TEXT[]) LOOP
        PERFORM update_table_searchable_flag(v_table_name);
    END LOOP;

    -- Last: the views of a family show the columns this statement added,
    -- renamed or dropped, and its search_vectors, which the rebuild above may
    -- have dropped with CASCADE. Reads and returns when no family is touched.
    PERFORM dd_refresh_family(p_touched);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION apply_field_searchable_change IS
'Rebuilds search_vector for every table in p_rebuild, recomputes entities.searchable for every table in p_touched and rebuilds the is_a/has_a families among them. Called once per statement by the handle_field_searchable_* triggers.';

-- =====================================================
-- TRIGGER FUNCTIONS: Handle field searchable changes
-- =====================================================
-- Statement-level, one function per event, because a trigger that uses
-- transition tables may only be defined for a single event. Statement level
-- rather than row level for two reasons:
--   * a statement that changes N fields of a table rebuilds that table once
--     instead of N times, and every rebuild is a full table rewrite;
--   * AFTER STATEMENT triggers run after all AFTER ROW triggers, so the physical
--     DDL from add_field_trigger and update_field_trigger has always been
--     applied by the time the tsvector expression is built. The row-level
--     version depended on trigger name ordering for that and only got it right
--     for add_field_trigger: update_field_trigger sorts after handle_field_*,
--     so an UPDATE changing both format and searchable used to build the
--     expression against the pre-ALTER column.

CREATE OR REPLACE FUNCTION handle_field_searchable_insert()
RETURNS TRIGGER AS $$
DECLARE
    v_rebuild TEXT[];
    v_touched TEXT[];
BEGIN
    SELECT array_agg(DISTINCT table_name) FILTER (WHERE searchable),
           array_agg(DISTINCT table_name)
    INTO v_rebuild, v_touched
    FROM new_fields;

    PERFORM apply_field_searchable_change(v_rebuild, v_touched);
    RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE OR REPLACE FUNCTION handle_field_searchable_update()
RETURNS TRIGGER AS $$
DECLARE
    v_rebuild TEXT[];
    v_touched TEXT[];
BEGIN
    -- Compare the set of searchable field names per table across the whole
    -- statement instead of pairing old rows with new ones: this catches one
    -- field being switched off while another is switched on, and needs no join
    -- key (fields.id is generated from table_name || field_name, so it moves
    -- when a field is renamed).
    SELECT array_agg(coalesce(n.table_name, o.table_name))
    INTO v_rebuild
    FROM (
        SELECT table_name,
               array_agg(field_name ORDER BY field_name) FILTER (WHERE searchable) AS searchable_names
        FROM new_fields
        GROUP BY table_name
    ) n
    FULL JOIN (
        SELECT table_name,
               array_agg(field_name ORDER BY field_name) FILTER (WHERE searchable) AS searchable_names
        FROM old_fields
        GROUP BY table_name
    ) o ON o.table_name = n.table_name
    WHERE n.searchable_names IS DISTINCT FROM o.searchable_names;

    SELECT array_agg(DISTINCT table_name) INTO v_touched FROM new_fields;

    PERFORM apply_field_searchable_change(v_rebuild, v_touched);
    RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE OR REPLACE FUNCTION handle_field_searchable_delete()
RETURNS TRIGGER AS $$
DECLARE
    v_rebuild TEXT[];
    v_touched TEXT[];
BEGIN
    SELECT array_agg(DISTINCT table_name) FILTER (WHERE searchable),
           array_agg(DISTINCT table_name)
    INTO v_rebuild, v_touched
    FROM old_fields;

    PERFORM apply_field_searchable_change(v_rebuild, v_touched);
    RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION handle_field_searchable_insert IS
'Statement-level trigger function: rebuilds search_vector once per table for the fields inserted by one statement.';
COMMENT ON FUNCTION handle_field_searchable_update IS
'Statement-level trigger function: rebuilds search_vector once per table whose set of searchable fields changed in one statement.';
COMMENT ON FUNCTION handle_field_searchable_delete IS
'Statement-level trigger function: rebuilds search_vector once per table for the fields deleted by one statement.';

-- One trigger per event: transition tables cannot be shared across events.
CREATE OR REPLACE TRIGGER handle_field_searchable_insert_trigger
    AFTER INSERT ON fields
    REFERENCING NEW TABLE AS new_fields
    FOR EACH STATEMENT
    EXECUTE FUNCTION handle_field_searchable_insert();

CREATE OR REPLACE TRIGGER handle_field_searchable_update_trigger
    AFTER UPDATE ON fields
    REFERENCING OLD TABLE AS old_fields NEW TABLE AS new_fields
    FOR EACH STATEMENT
    EXECUTE FUNCTION handle_field_searchable_update();

CREATE OR REPLACE TRIGGER handle_field_searchable_delete_trigger
    AFTER DELETE ON fields
    REFERENCING OLD TABLE AS old_fields
    FOR EACH STATEMENT
    EXECUTE FUNCTION handle_field_searchable_delete();

COMMENT ON TRIGGER handle_field_searchable_insert_trigger ON fields IS
'Automatically updates search_vector column and index when searchable fields are inserted';
COMMENT ON TRIGGER handle_field_searchable_update_trigger ON fields IS
'Automatically updates search_vector column and index when field searchable status changes';
COMMENT ON TRIGGER handle_field_searchable_delete_trigger ON fields IS
'Automatically updates search_vector column and index when searchable fields are deleted';

-- =====================================================
-- TRIGGER FUNCTION: Recompute entities.searchable on direct update
-- =====================================================
-- Ensures entities.searchable always reflects the actual state of fields
-- even if someone tries to update it directly

CREATE OR REPLACE FUNCTION enforce_table_searchable_consistency()
RETURNS TRIGGER AS $$
DECLARE
    v_computed_searchable BOOLEAN;
BEGIN
    -- If searchable was changed, recompute it from fields and override the value
    IF OLD.searchable IS DISTINCT FROM NEW.searchable THEN
        -- Compute the correct value from fields
        v_computed_searchable := dd_entity_searchable(NEW.table_name);
        
        -- Override any manual change with the computed value
        NEW.searchable := v_computed_searchable;

    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SET search_path = public;

COMMENT ON FUNCTION enforce_table_searchable_consistency IS 
'Trigger function that ensures entities.searchable always reflects the status of related fields, preventing manual overrides.';

CREATE OR REPLACE TRIGGER enforce_table_searchable_consistency_trigger
    BEFORE UPDATE ON entities
    FOR EACH ROW
    WHEN (OLD.searchable IS DISTINCT FROM NEW.searchable)
    EXECUTE FUNCTION enforce_table_searchable_consistency();

COMMENT ON TRIGGER enforce_table_searchable_consistency_trigger ON entities IS
'Ensures entities.searchable is always consistent with related fields, preventing manual changes';
-- =====================================================
-- IS_CHILD FUNCTIONS AND TRIGGERS
-- =====================================================
-- Manages entities.is_child based on whether any field of the record has
-- format='parent' (dd_entity_is_child), the way searchable is maintained.

-- =====================================================
-- HELPER FUNCTION: Update entities.is_child flag
-- =====================================================

-- The entities based on this one inherit its fields, so their flag is
-- recomputed with its own.
CREATE OR REPLACE FUNCTION update_table_is_child_flag(p_table_name TEXT)
RETURNS VOID AS $$
BEGIN
    -- Note: no rbac.uid() here — this function is called by triggers
    -- during migrations when there is no JWT context.

    -- Gated like update_table_searchable_flag above.
    UPDATE entities e
       SET is_child = dd_entity_is_child(e.table_name)
     WHERE (e.table_name = p_table_name
            OR e.table_name IN (SELECT d.table_name FROM dd_descendants(p_table_name) d))
       AND e.is_child IS DISTINCT FROM dd_entity_is_child(e.table_name);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION update_table_is_child_flag IS
'Auto-maintains the is_child flag of an entity and of the entities based on it: TRUE when any field of the record has format=''parent'' (dd_entity_is_child).';

-- =====================================================
-- TRIGGER FUNCTION: Handle field parent format changes
-- =====================================================

CREATE OR REPLACE FUNCTION handle_field_parent_format_change()
RETURNS TRIGGER AS $$
DECLARE
    v_parent_changed BOOLEAN := FALSE;
    v_table_name_to_update TEXT;
BEGIN
    IF TG_OP = 'INSERT' THEN
        v_table_name_to_update := NEW.table_name;
        v_parent_changed := (NEW.format = 'parent');
    ELSIF TG_OP = 'UPDATE' THEN
        v_table_name_to_update := NEW.table_name;
        v_parent_changed := (OLD.format IS DISTINCT FROM NEW.format AND (OLD.format = 'parent' OR NEW.format = 'parent'));
    ELSIF TG_OP = 'DELETE' THEN
        v_table_name_to_update := OLD.table_name;
        v_parent_changed := (OLD.format = 'parent');
    END IF;

    IF v_parent_changed THEN
        PERFORM update_table_is_child_flag(v_table_name_to_update);
    END IF;

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    ELSE
        RETURN NEW;
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION handle_field_parent_format_change IS 
'Trigger function that updates entities.is_child when fields with format=''parent'' are created, updated, or deleted.';

CREATE OR REPLACE TRIGGER handle_field_parent_format_change_trigger
    AFTER INSERT OR UPDATE OR DELETE ON fields
    FOR EACH ROW
    EXECUTE FUNCTION handle_field_parent_format_change();

COMMENT ON TRIGGER handle_field_parent_format_change_trigger ON fields IS
'Automatically updates entities.is_child when field parent format status changes';

-- =====================================================
-- TRIGGER FUNCTION: Recompute entities.is_child on direct update
-- =====================================================

CREATE OR REPLACE FUNCTION enforce_table_is_child_consistency()
RETURNS TRIGGER AS $$
DECLARE
    v_computed_is_child BOOLEAN;
BEGIN
    IF OLD.is_child IS DISTINCT FROM NEW.is_child THEN
        -- The row's own parent fields, or those of the levels above it.
        v_computed_is_child := EXISTS (
            SELECT 1 FROM fields
            WHERE table_name = NEW.table_name
              AND format = 'parent'
        ) OR (NEW.id_refentity IS NOT NULL AND dd_entity_is_child(NEW.id_refentity));

        NEW.is_child := v_computed_is_child;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SET search_path = public;

COMMENT ON FUNCTION enforce_table_is_child_consistency IS 
'Trigger function that ensures entities.is_child always reflects the status of related fields, preventing manual overrides.';

CREATE OR REPLACE TRIGGER enforce_table_is_child_consistency_trigger
    BEFORE UPDATE ON entities
    FOR EACH ROW
    WHEN (OLD.is_child IS DISTINCT FROM NEW.is_child)
    EXECUTE FUNCTION enforce_table_is_child_consistency();

COMMENT ON TRIGGER enforce_table_is_child_consistency_trigger ON entities IS
'Ensures entities.is_child is always consistent with related fields, preventing manual changes';

-- =====================================================
-- ENTITY FAMILIES: CHECKS
-- =====================================================
-- What an is_a or has_a entity may be based on, and what it inherits from its
-- base, is decided when it is created and held from then on:
--   90240  the base: an is_a entity on a managed typeid or is_a entity, a
--          has_a entity on a managed typeid entity, neither on itself
--   90241  id_refentity never changes
--   90242  label_column and label_parent come from the base
--   90249  no order_column (the root's order column is no field and not in
--          the views)
--   90252  a base stays managed while entities are based on it
--   90254  a new is_a entity's prefix is carried by no row of its root
-- The key column and the label column are set from the base on insert; the
-- label column is the root's, which every level of a chain shares. So is
-- is_child, which a parent field on any level above sets.
--
-- The name sorts before set_entity_defaults_trigger, which derives
-- singular_label from label_column and has to see the inherited one.
CREATE OR REPLACE FUNCTION check_entity_family()
RETURNS TRIGGER AS $$
DECLARE
    v_derived    BOOLEAN := NEW.id_type IN ('is_a', 'has_a');
    v_base       entities%ROWTYPE;
    v_has_base   BOOLEAN := FALSE;
    v_root       TEXT;
    v_root_label TEXT;
    v_taken      BOOLEAN;
    v_dependents TEXT;
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF v_derived AND NEW.id_refentity IS NOT NULL THEN
            SELECT * INTO v_base FROM entities WHERE table_name = NEW.id_refentity;
            v_has_base := FOUND;
            -- An unknown base is left to entities_id_refentity_fkey. Itself
            -- is not: the row being inserted satisfies its own foreign key.
            IF NEW.id_refentity = NEW.table_name
               OR (v_has_base AND (NOT v_base.managed
                    OR (NEW.id_type = 'has_a' AND v_base.id_type <> 'typeid')
                    OR (NEW.id_type = 'is_a' AND v_base.id_type NOT IN ('typeid', 'is_a')))) THEN
                RAISE EXCEPTION 'Entity ${table} cannot be based on ${base}'
                    USING ERRCODE = '90240',
                          HINT = jsonb_build_object(
                              'table', NEW.table_name,
                              'base', NEW.id_refentity,
                              'hint', 'An is_a entity is based on a managed typeid or is_a entity, a has_a entity on a managed typeid entity, and no entity on itself.')::text;
            END IF;
            IF v_has_base THEN
                SELECT e.label_column, e.table_name INTO v_root_label, v_root
                  FROM dd_ancestors(NEW.id_refentity) a
                  JOIN entities e ON e.table_name = a.table_name
                 WHERE a.depth = 0;
                -- The root dispatches a row to the subtype its id's prefix
                -- names. A prefix the root gave up is free again, but its rows
                -- keep it: a subtype taking it would be handed rows that have
                -- no part in it. One scan of the root, as the definer, so rows
                -- the caller cannot read count too.
                IF NEW.id_type = 'is_a'
                   AND pg_catalog.to_regclass(format('public.%I', v_root)) IS NOT NULL THEN
                    EXECUTE format('SELECT EXISTS (SELECT 1 FROM public.%I t WHERE common.typeid_prefix(t.%I) = $1)',
                                   v_root, v_base.id_column)
                       INTO v_taken
                      USING NEW.id_prefix;
                    IF v_taken THEN
                        RAISE EXCEPTION 'Records of ${base} already carry the prefix ${prefix}'
                            USING ERRCODE = '90254',
                                  HINT = jsonb_build_object(
                                      'table', NEW.table_name,
                                      'base', v_root,
                                      'prefix', NEW.id_prefix,
                                      'hint', 'The prefix names the type of a record. Choose a prefix no record of the family carries.')::text;
                    END IF;
                END IF;
                NEW.id_column := v_base.id_column;
                NEW.label_column := v_root_label;
                NEW.label_parent := '';
                -- It has no fields yet; a parent field above it makes it a
                -- child from the start.
                NEW.is_child := dd_entity_is_child(NEW.id_refentity);
            END IF;
        END IF;
    ELSE
        -- A rename of the base reaches this row through ON UPDATE CASCADE:
        -- the old name is gone and the new one exists. That is the one change
        -- id_refentity takes.
        IF OLD.id_refentity IS DISTINCT FROM NEW.id_refentity
           AND NOT (OLD.id_refentity IS NOT NULL AND NEW.id_refentity IS NOT NULL
                    AND NOT EXISTS (SELECT 1 FROM entities e WHERE e.table_name = OLD.id_refentity)
                    AND EXISTS (SELECT 1 FROM entities e WHERE e.table_name = NEW.id_refentity)) THEN
            RAISE EXCEPTION 'id_refentity is set when an entity is created and cannot be changed'
                USING ERRCODE = '90241',
                      HINT = jsonb_build_object('table', NEW.table_name)::text;
        END IF;

        -- Compared with the root's label column: a change of it reaches this
        -- row through family_label_column_trigger, once every level above has
        -- taken it. The chain is walked from the base, which exists under
        -- NEW.id_refentity even while this row is being renamed or follows
        -- its base's rename.
        IF v_derived THEN
            SELECT e.label_column INTO v_root_label
              FROM dd_ancestors(NEW.id_refentity) a
              JOIN entities e ON e.table_name = a.table_name
             WHERE a.depth = 0;
            IF NEW.label_column IS DISTINCT FROM v_root_label OR NEW.label_parent <> '' THEN
                RAISE EXCEPTION 'label_column and label_parent of ${table} come from its base ${base}'
                    USING ERRCODE = '90242',
                          HINT = jsonb_build_object('table', NEW.table_name, 'base', NEW.id_refentity)::text;
            END IF;
        END IF;

        IF OLD.managed AND NOT NEW.managed THEN
            SELECT string_agg(d.table_name, ', ' ORDER BY d.table_name)
              INTO v_dependents
              FROM entities d
             WHERE d.id_refentity = NEW.table_name;
            IF v_dependents IS NOT NULL THEN
                RAISE EXCEPTION 'Entity ${table} cannot become unmanaged while ${dependents} are based on it'
                    USING ERRCODE = '90252',
                          HINT = jsonb_build_object('table', NEW.table_name, 'dependents', v_dependents)::text;
            END IF;
        END IF;
    END IF;

    IF v_derived AND coalesce(NEW.order_column, '') <> '' THEN
        RAISE EXCEPTION '${feature} is not available for ${id_type} entity ${table}'
            USING ERRCODE = '90249',
                  HINT = jsonb_build_object('feature', 'order_column', 'id_type', NEW.id_type, 'table', NEW.table_name)::text;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION check_entity_family() IS
'BEFORE INSERT OR UPDATE trigger on entities: checks the base of an is_a/has_a entity (90240), keeps id_refentity write-once (90241) and label_column/label_parent inherited (90242), refuses an order_column on one (90249), refuses unmanaging a base with dependents (90252) and refuses a new is_a entity a prefix rows of its root carry (90254). Sets id_column, label_column, label_parent and is_child from the base on insert.';

CREATE OR REPLACE TRIGGER check_entity_family_trigger
    BEFORE INSERT OR UPDATE ON entities
    FOR EACH ROW
    EXECUTE FUNCTION check_entity_family();

-- Every level of a family carries the root's label column (90242 holds it
-- there), so a change of a base's label column is carried to the entities
-- based on it directly, and their own update carries it one level further.
-- Without it, a changed root would leave its descendants with a value 90242
-- refuses, and every later write to their rows - a rename, a searchable
-- change - would fail. The change is written before the rows below are
-- checked against it, because this runs after the base's row is updated.
-- A plain entity has nothing based on it, and the update writes no row.
CREATE OR REPLACE FUNCTION dd_family_label_column_changed()
RETURNS TRIGGER AS $$
BEGIN
    UPDATE entities
       SET label_column = NEW.label_column
     WHERE id_refentity = NEW.table_name
       AND label_column IS DISTINCT FROM NEW.label_column;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION dd_family_label_column_changed() IS
'AFTER UPDATE trigger on entities: carries a changed label_column to the is_a and has_a entities based on this one, whose own update carries it further down the family.';

CREATE OR REPLACE TRIGGER family_label_column_trigger
    AFTER UPDATE ON entities
    FOR EACH ROW
    WHEN (OLD.label_column IS DISTINCT FROM NEW.label_column)
    EXECUTE FUNCTION dd_family_label_column_changed();

-- Two checks on the fields of a family:
--   90243  a field name is unique across the entities that share records - an
--          entity, its bases and its descendants - because every view of the
--          family shows the fields of its whole chain side by side. Siblings
--          may repeat a name; the key and audit names are each entity's own.
--   90249  a reference field of an is_a subtype cannot cascade. An RI action
--          runs inside a trigger, where the _ext write guard lets it through,
--          so a cascade would delete one part of a record and leave the rest.
--          A has_a extension may cascade: that only detaches it.
-- The name sorts before validate_field_rename_and_format_trigger, so a rename
-- that would collide is refused before the column is renamed.
CREATE OR REPLACE FUNCTION validate_family_field()
RETURNS TRIGGER AS $$
DECLARE
    v_entity entities%ROWTYPE;
    v_other  TEXT;
BEGIN
    SELECT * INTO v_entity FROM entities WHERE table_name = NEW.table_name;
    IF NOT FOUND THEN
        RETURN NEW;
    END IF;

    IF v_entity.id_type = 'is_a'
       AND NEW.format IN ('reference', 'parent')
       AND NEW.reference_delete_mode = 'cascade' THEN
        RAISE EXCEPTION '${feature} is not available for ${id_type} entity ${table}'
            USING ERRCODE = '90249',
                  HINT = jsonb_build_object('feature', 'cascade', 'id_type', v_entity.id_type, 'table', NEW.table_name)::text;
    END IF;

    IF (TG_OP = 'INSERT' OR OLD.field_name IS DISTINCT FROM NEW.field_name)
       AND NEW.field_name NOT IN (v_entity.id_column, 'created_at', 'updated_at')
       AND (v_entity.id_type IN ('is_a', 'has_a')
            OR EXISTS (SELECT 1 FROM entities d WHERE d.id_refentity = NEW.table_name)) THEN
        SELECT f.table_name
          INTO v_other
          FROM fields f
         WHERE f.field_name = NEW.field_name
           AND f.table_name IN (SELECT a.table_name FROM dd_ancestors(NEW.table_name) a
                                 WHERE a.table_name <> NEW.table_name
                                UNION ALL
                                SELECT d.table_name FROM dd_descendants(NEW.table_name) d)
         ORDER BY f.table_name
         LIMIT 1;
        IF v_other IS NOT NULL THEN
            RAISE EXCEPTION 'Field ${field_name} of ${table} collides with ${other}, which shares its records'
                USING ERRCODE = '90243',
                      HINT = jsonb_build_object('field_name', NEW.field_name, 'table', NEW.table_name, 'other', v_other)::text;
        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION validate_family_field() IS
'BEFORE INSERT OR UPDATE trigger on fields: refuses a field name that an ancestor or descendant of the entity already uses (90243), and a cascading reference field on an is_a entity (90249).';

CREATE OR REPLACE TRIGGER validate_family_field_trigger
    BEFORE INSERT OR UPDATE ON fields
    FOR EACH ROW
    EXECUTE FUNCTION validate_family_field();

-- =====================================================
-- ENTITY FAMILIES: VIEWS AND WRITE ROUTINES
-- =====================================================
-- Every derived entity t gets, generated from the dictionary:
--   public.t                        the view: t_ext joined with the relation
--                                   of every base, security_invoker, so each
--                                   table's RLS applies to the reader
--   common.record_write_t           writes a record whose own type is t:
--                                   every part, every level's rules, locks
--                                   first (SECURITY INVOKER: RLS applies)
--   common.view_write_t             INSTEAD OF trigger of the view
-- and an is_a root gets common.is_a_dispatch_<root>, a BEFORE UPDATE OR
-- DELETE trigger that carries a write of a subtype record through the root
-- table down to the record's own type. All of it is static SQL, rebuilt by
-- dd_refresh_family whenever the family's fields or members change. The
-- routines live in common, which PostgREST does not expose, so none of them is
-- an RPC.
--
-- An is_a record's type is read from the prefix of its id, which never
-- changes (90245), so a write through a supertype - the root table or a
-- supertype's view - is carried down to the record's own type, whose rules and
-- permissions then apply to every part.
--
-- The depth invariant. Inside a trigger, only record_write_* and RI actions
-- write an _ext table or insert into a typeid root with a subtype prefix:
-- common.ext_write_guard and common.typeid_assign let exactly that through by
-- testing pg_trigger_depth(), and record_write_* checks the prefix of every id
-- it inserts. RI actions are limited to what cannot split a record: an is_a
-- subtype's reference field cannot cascade (90249), a SET NULL on an _ext
-- column runs without the derived rules (_ext has no rule trigger), and a
-- cascade or SET NULL into an is_a root reaches only the root row - a subtype
-- record's delete then fails on <t>_ext_id_fkey. Module triggers must not
-- write family tables (AGENTS.md).

-- The data columns of an entity's record with the level that stores them, in
-- the order of dd_family_fields: every field but the key and the audit fields,
-- whose physical column exists. The builders below take their columns from it.
CREATE OR REPLACE FUNCTION dd_family_columns(p_table_name TEXT)
RETURNS TABLE (ord BIGINT, depth INTEGER, rel TEXT, column_name TEXT) AS $$
    SELECT f.ordinality, a.depth, dd_relation(e.table_name, e.id_type), f.field_name
      FROM dd_family_fields(p_table_name) WITH ORDINALITY AS f
      JOIN dd_ancestors(p_table_name) a ON a.table_name = f.table_name
      JOIN entities e ON e.table_name = f.table_name
     WHERE coalesce(f.ctype, '') NOT IN ('id', 'audit')
       AND EXISTS (SELECT 1 FROM pg_catalog.pg_attribute att
                    WHERE att.attrelid = pg_catalog.to_regclass(format('public.%I', dd_relation(e.table_name, e.id_type)))
                      AND att.attname = f.field_name
                      AND att.attnum > 0
                      AND NOT att.attisdropped)
     ORDER BY f.ordinality;
$$ LANGUAGE sql STABLE SET search_path = public;

COMMENT ON FUNCTION dd_family_columns(TEXT) IS
'The data columns of an entity''s record (dd_family_fields without the key and audit fields) that exist physically, with the depth and physical relation of the level that stores each. Used by the family view and write-routine generators.';

-- The view of a derived entity. Its key is t_ext's, so PostgREST sees the
-- primary key and links references to the view; created_at is the entity's
-- own level's, updated_at the latest of all levels, and search_vector the
-- concatenation of the levels that have one - a full-text search over it
-- spans every level but cannot use the GIN indexes. The column defaults and
-- comments are copied from the physical columns, so an insert through the view
-- gets the defaults a table would, and PostgREST describes the view like one.
-- A view accepts RENAME COLUMN, SET DEFAULT, COMMENT and GRANT as well, so a
-- dictionary change that went to the view instead of the table would be
-- overwritten here from the table without failing anywhere; the tests assert
-- those changes on t_ext.
CREATE OR REPLACE FUNCTION dd_build_family_view(p_table_name TEXT)
RETURNS VOID AS $$
DECLARE
    v_entity  entities%ROWTYPE;
    v_n       INTEGER;
    v_from    TEXT := '';
    v_updated TEXT := '';
    v_search  TEXT := '';
    v_cols    TEXT;
    v_comment TEXT;
    r         RECORD;
BEGIN
    SELECT * INTO v_entity FROM entities WHERE table_name = p_table_name;
    SELECT max(a.depth) INTO v_n FROM dd_ancestors(p_table_name) a;

    FOR r IN
        SELECT a.depth, dd_relation(e.table_name, e.id_type) AS rel
          FROM dd_ancestors(p_table_name) a
          JOIN entities e ON e.table_name = a.table_name
         ORDER BY a.depth DESC
    LOOP
        IF r.depth = v_n THEN
            v_from := format('public.%I l%s', r.rel, r.depth);
        ELSE
            v_from := v_from || format(' JOIN public.%I l%s ON l%s.%I = l%s.%I',
                r.rel, r.depth, r.depth, v_entity.id_column, v_n, v_entity.id_column);
        END IF;
        v_updated := v_updated || CASE WHEN v_updated = '' THEN '' ELSE ', ' END
                     || format('l%s.updated_at', r.depth);
        IF EXISTS (SELECT 1 FROM pg_catalog.pg_attribute att
                    WHERE att.attrelid = pg_catalog.to_regclass(format('public.%I', r.rel))
                      AND att.attname = 'search_vector' AND NOT att.attisdropped) THEN
            -- Root first, like the columns.
            v_search := format('l%s.search_vector', r.depth)
                        || CASE WHEN v_search = '' THEN '' ELSE ' || ' || v_search END;
        END IF;
    END LOOP;

    SELECT string_agg(format('l%s.%I, ', c.depth, c.column_name), '' ORDER BY c.ord)
      INTO v_cols
      FROM dd_family_columns(p_table_name) c;

    EXECUTE format(
        'CREATE VIEW public.%I WITH (security_invoker = true) AS
            SELECT l%s.%I, %sl%s.created_at, GREATEST(%s) AS updated_at%s
              FROM %s',
        p_table_name,
        v_n, v_entity.id_column,
        coalesce(v_cols, ''),
        v_n, v_updated,
        CASE WHEN v_search = '' THEN '' ELSE format(', %s AS search_vector', v_search) END,
        v_from);

    -- Defaults and comments, column by column, from the relation each column
    -- is read from: the entity's own table for the key and the audit columns.
    FOR r IN
        SELECT x.column_name, x.rel,
               pg_catalog.pg_get_expr(d.adbin, d.adrelid) AS default_expr,
               pg_catalog.col_description(att.attrelid, att.attnum) AS comment
          FROM (SELECT c.column_name, c.rel FROM dd_family_columns(p_table_name) c
                UNION ALL
                SELECT v_entity.id_column, dd_relation(p_table_name, v_entity.id_type)
                UNION ALL
                SELECT 'created_at', dd_relation(p_table_name, v_entity.id_type)
                UNION ALL
                SELECT 'updated_at', dd_relation(p_table_name, v_entity.id_type)) x
          JOIN pg_catalog.pg_attribute att
            ON att.attrelid = pg_catalog.to_regclass(format('public.%I', x.rel))
           AND att.attname = x.column_name
           AND NOT att.attisdropped
          LEFT JOIN pg_catalog.pg_attrdef d
            ON d.adrelid = att.attrelid AND d.adnum = att.attnum AND att.attgenerated = ''
    LOOP
        IF r.default_expr IS NOT NULL THEN
            EXECUTE format('ALTER VIEW public.%I ALTER COLUMN %I SET DEFAULT %s',
                p_table_name, r.column_name, r.default_expr);
        END IF;
        IF r.comment IS NOT NULL THEN
            EXECUTE format('COMMENT ON COLUMN public.%I.%I IS %L', p_table_name, r.column_name, r.comment);
        END IF;
    END LOOP;

    v_comment := dd_table_comment(v_entity.plural_label, v_entity.description);
    EXECUTE format('COMMENT ON VIEW public.%I IS %L', p_table_name, v_comment);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON public.%I TO semantius_user', p_table_name);
END;
$$ LANGUAGE plpgsql SECURITY INVOKER SET search_path = public;

COMMENT ON FUNCTION dd_build_family_view(TEXT) IS
'Creates the security_invoker view of an is_a/has_a entity over its <entity>_ext table and the relations of its bases, with the column defaults and comments of the physical columns, its comment and the request-role grant. Called by dd_refresh_family.';

-- The write routine of a derived entity t: common.record_write_t(op, old,
-- new, from_root) writes one record whose own type is t, and every entry point
-- - t's view, the view of a supertype, the root table - calls it for such a
-- record. It returns the stored record, read back through the view, or the
-- input record when the caller cannot read it; NULL when the record is
-- skipped.
--
--   insert  is_a: the id is minted with t's prefix, or a supplied one must
--           carry it (90237); the root row, then each _ext level top-down. An
--           id that exists fails with 23505: the type is fixed at creation.
--           has_a: no id, or one no visible base row has, inserts the base row
--           too, with an id minted here with the base's prefix (a supplied one
--           must carry it, 90237 - the root's typeid_assign would accept a
--           subtype prefix from here and create a subtype root row without its
--           parts). Minting it here rather than in typeid_assign spares the
--           INSERT a RETURNING, which would need the caller to be able to read
--           the base row back. The id of a
--           visible base row attaches: only t_ext is inserted, and a base
--           value that differs from the stored one raises 90246, unless it is
--           the column default an insert through the view fills in.
--   update  writes the levels from the highest one whose columns changed down
--           to t, and always t; the levels above are untouched. The rules of
--           the derived levels at and below the change run, inherited first,
--           and since a computed field may set any column, the changed levels
--           are decided after them; a level that only a computed field changed
--           is written too, and its rules run in a second pass. A changed key
--           raises 90236. Each column is written only when it changed, so a
--           concurrent change to another column is kept.
--           has_a: a change of the base's columns on a record whose id names
--           an is_a subtype of the base is a change of that subtype record,
--           so it goes to the subtype's write routine, which runs the rules
--           and takes the locks of every level of the record; the extension
--           then writes only its own part. A record the caller cannot write
--           whole, or read through the subtype's view, is skipped. Written
--           here instead, the base row would change at trigger depth 2, where
--           the root's dispatch does not act, and every is_a level's rules and
--           edit permissions would be passed by. The extension's part is
--           locked before the subtype's levels, out of top-down order; every
--           writer that changes the base columns locks the base row first,
--           and that orders them.
--   delete  is_a: every derived level's delete rules, bottom-up, then every
--           part bottom-up and the root row. has_a: t's rules, then t_ext only
--           (detach); the base record stays.
--
-- Permissions without half-writes: before anything is written, every level
-- that will be written is locked top-down with SELECT ... FOR UPDATE, which
-- applies the UPDATE policy, whose predicate equals the DELETE policy's. A
-- level that cannot be locked makes the routine return NULL, and the record is
-- skipped like any row RLS filters. Locking top-down rules out deadlocks among
-- writers of one record. A refused INSERT raises 42501 through the tables'
-- INSERT policies.
--
-- from_root is set by the root's dispatch trigger: the root row is then
-- already locked and is written by the outer statement, so the routine leaves
-- it alone and returns the record, whose root columns the trigger copies into
-- NEW. The root's own rules stay the root table's trigger and run after the
-- derived rules, on the final root row.
CREATE OR REPLACE FUNCTION dd_build_record_write(p_table_name TEXT)
RETURNS VOID AS $$
DECLARE
    v_entity      entities%ROWTYPE;
    v_base        entities%ROWTYPE;
    v_root        entities%ROWTYPE;
    v_k           TEXT;
    v_n           INTEGER;
    v_is_a        BOOLEAN;
    v_type        TEXT := format('public.%I', p_table_name);
    v_fn          TEXT := 'record_write_' || p_table_name;
    v_top_expr    TEXT := '';
    v_rules_ins   TEXT := '';
    v_rules_upd1  TEXT := '';
    v_rules_upd2  TEXT := '';
    v_rules_del   TEXT := '';
    v_any_rules   BOOLEAN := FALSE;
    v_ins         TEXT := '';
    v_lock        TEXT := '';
    v_upd         TEXT := '';
    v_dlock       TEXT := '';
    v_del         TEXT := '';
    v_attach_in   TEXT := '';
    v_attach_out  TEXT := '';
    v_root_cols   TEXT[] := ARRAY[]::TEXT[];
    v_route_decls TEXT := '';
    v_route_whens TEXT := '';
    v_route       TEXT := '';
    v_si          INTEGER := 0;
    v_cols        TEXT[];
    v_cond        TEXT;
    v_stmt        TEXT;
    v_insert      TEXT;
    v_update      TEXT;
    v_body        TEXT;
    r             RECORD;
    c             RECORD;
BEGIN
    SELECT * INTO v_entity FROM entities WHERE table_name = p_table_name;
    SELECT * INTO v_base FROM entities WHERE table_name = v_entity.id_refentity;
    SELECT e.* INTO v_root
      FROM dd_ancestors(p_table_name) a JOIN entities e ON e.table_name = a.table_name
     WHERE a.depth = 0;
    v_k := v_entity.id_column;
    v_is_a := v_entity.id_type = 'is_a';
    SELECT max(a.depth) INTO v_n FROM dd_ancestors(p_table_name) a;

    FOR r IN
        SELECT a.depth, e.table_name, dd_relation(e.table_name, e.id_type) AS rel,
               to_regprocedure(format('common.%I(text, jsonb, jsonb)', 'record_rules_' || e.table_name)) IS NOT NULL
                   AS has_rules
          FROM dd_ancestors(p_table_name) a
          JOIN entities e ON e.table_name = a.table_name
         ORDER BY a.depth
    LOOP
        SELECT coalesce(array_agg(fc.column_name ORDER BY fc.ord), ARRAY[]::TEXT[])
          INTO v_cols
          FROM dd_family_columns(p_table_name) fc
         WHERE fc.depth = r.depth;
        IF r.depth = 0 THEN
            v_root_cols := v_cols;
        END IF;

        -- The highest level whose columns differ between v_new and p_old.
        IF cardinality(v_cols) > 0 THEN
            v_top_expr := v_top_expr || format(' WHEN ROW(%s) IS DISTINCT FROM ROW(%s) THEN %s',
                (SELECT string_agg(format('v_new.%I', x), ', ') FROM unnest(v_cols) x),
                (SELECT string_agg(format('p_old.%I', x), ', ') FROM unnest(v_cols) x),
                r.depth);
        END IF;

        -- The rules of the derived levels (the root's are its table's trigger).
        IF r.depth > 0 AND r.has_rules THEN
            v_any_rules := TRUE;
            v_rules_ins := v_rules_ins || format(E'\n        v_data := common.%I(''insert'', NULL, v_data);',
                'record_rules_' || r.table_name);
            v_rules_upd1 := v_rules_upd1 || format(
                E'\n            IF v_top <= %s THEN\n                v_data := common.%I(''update'', v_old, v_data);\n            END IF;',
                r.depth, 'record_rules_' || r.table_name);
            v_rules_upd2 := v_rules_upd2 || format(
                E'\n                IF v_top2 <= %s AND %s < v_top THEN\n                    v_data := common.%I(''update'', v_old, v_data);\n                END IF;',
                r.depth, r.depth, 'record_rules_' || r.table_name);
            v_rules_del := format(E'\n        PERFORM common.%I(''delete'', v_old, v_old);', 'record_rules_' || r.table_name)
                           || v_rules_del;
        END IF;

        -- The statements on this level's relation.
        v_insert := format('INSERT INTO public.%I (%I%s, created_at, updated_at) VALUES (v_new.%I%s, v_new.created_at, v_new.updated_at)',
            r.rel, v_k,
            (SELECT coalesce(string_agg(format(', %I', x), ''), '') FROM unnest(v_cols) x),
            v_k,
            (SELECT coalesce(string_agg(format(', v_new.%I', x), ''), '') FROM unnest(v_cols) x));
        v_update := format('UPDATE public.%I AS t SET %s WHERE t.%I = p_old.%I',
            r.rel,
            CASE WHEN cardinality(v_cols) = 0 THEN 'updated_at = t.updated_at'
                 ELSE (SELECT string_agg(format('%1$I = CASE WHEN v_new.%1$I IS DISTINCT FROM p_old.%1$I THEN v_new.%1$I ELSE t.%1$I END', x), ', ')
                         FROM unnest(v_cols) x)
            END,
            v_k, v_k);
        v_stmt := format(E'PERFORM 1 FROM public.%I AS t WHERE t.%I = p_old.%I FOR UPDATE;\n%%sIF NOT FOUND THEN\n%%s    RETURN NULL;\n%%sEND IF;',
            r.rel, v_k, v_k);

        v_cond := CASE WHEN r.depth = 0 THEN 'v_top <= 0 AND NOT p_from_root'
                       WHEN r.depth < v_n THEN format('v_top <= %s', r.depth)
                  END;

        IF r.depth = 0 AND NOT v_is_a THEN
            -- has_a: the base row is inserted when no base record is attached.
            v_ins := v_ins || format(E'\n        IF NOT v_attach THEN\n            %s;\n        END IF;', v_insert);
        ELSE
            v_ins := v_ins || format(E'\n        %s;', v_insert);
        END IF;
        IF v_cond IS NULL THEN
            v_lock := v_lock || E'\n        ' || format(v_stmt, '        ', '        ', '        ');
            v_upd := v_upd || format(E'\n        %s;', v_update);
        ELSE
            v_lock := v_lock || format(E'\n        IF %s THEN\n            %s\n        END IF;',
                v_cond, format(v_stmt, '            ', '            ', '            '));
            -- has_a: a base row the subtype's write routine wrote is not
            -- written again.
            v_upd := v_upd || format(E'\n        IF %s THEN\n            %s;\n        END IF;',
                v_cond || CASE WHEN r.depth = 0 AND NOT v_is_a THEN ' AND NOT v_routed' ELSE '' END,
                v_update);
        END IF;

        IF v_is_a OR r.depth = v_n THEN
            IF r.depth = 0 THEN
                v_dlock := v_dlock || format(E'\n        IF NOT p_from_root THEN\n            %s\n        END IF;',
                    format(v_stmt, '            ', '            ', '            '));
                v_del := format(E'\n        IF NOT p_from_root THEN\n            DELETE FROM public.%I AS t WHERE t.%I = p_old.%I;\n        END IF;',
                    r.rel, v_k, v_k) || v_del;
            ELSE
                v_dlock := v_dlock || E'\n        ' || format(v_stmt, '        ', '        ', '        ');
                v_del := format(E'\n        DELETE FROM public.%I AS t WHERE t.%I = p_old.%I;', r.rel, v_k, v_k) || v_del;
            END IF;
        END IF;

        -- has_a: what an attach may and may not bring for the base's columns.
        IF r.depth = 0 AND NOT v_is_a THEN
            FOR c IN
                SELECT x AS column_name,
                       pg_catalog.pg_get_expr(d.adbin, d.adrelid) AS default_expr,
                       EXISTS (SELECT 1 FROM pg_catalog.pg_depend dep
                                 JOIN pg_catalog.pg_proc p ON p.oid = dep.refobjid
                                WHERE dep.classid = 'pg_catalog.pg_attrdef'::regclass
                                  AND dep.objid = d.oid
                                  AND dep.refclassid = 'pg_catalog.pg_proc'::regclass
                                  AND p.provolatile = 'v') AS volatile_default
                  FROM unnest(v_cols) WITH ORDINALITY AS u(x, n)
                  JOIN pg_catalog.pg_attribute att
                    ON att.attrelid = pg_catalog.to_regclass(format('public.%I', r.rel))
                   AND att.attname = u.x
                  LEFT JOIN pg_catalog.pg_attrdef d
                    ON d.adrelid = att.attrelid AND d.adnum = att.attnum
                 ORDER BY u.n
            LOOP
                -- A column the insert did not name holds the view's default,
                -- copied from this column, and is not a value the caller
                -- brought. A volatile default cannot be recognized that way,
                -- so such a column's value is always taken from the base.
                v_attach_in := v_attach_in || format(
                    E'\n            IF v_new.%1$I IS DISTINCT FROM v_base.%1$I THEN%2$s\n                v_new.%1$I := v_base.%1$I;\n            END IF;',
                    c.column_name,
                    CASE WHEN c.volatile_default THEN ''
                         ELSE format(E'\n                IF v_new.%1$I IS DISTINCT FROM (%2$s) THEN\n                    RAISE EXCEPTION %3$L\n                        USING ERRCODE = ''90246'',\n                              HINT = jsonb_build_object(''table'', %4$L, ''base'', %5$L, ''id'', v_new.%6$I, ''field'', %1$L)::text;\n                END IF;',
                                     c.column_name, coalesce(c.default_expr, 'NULL'),
                                     'Attaching ${table} to ${base} record ${id}: ${field} differs from the stored value; change it through ${base}',
                                     p_table_name, v_base.table_name, v_k)
                    END);
                v_attach_out := v_attach_out || format(
                    E'\n            IF v_new.%1$I IS DISTINCT FROM v_base.%1$I THEN\n                RAISE EXCEPTION %2$L\n                    USING ERRCODE = ''90246'',\n                          HINT = jsonb_build_object(''table'', %3$L, ''base'', %4$L, ''id'', v_new.%5$I, ''field'', %1$L)::text;\n            END IF;',
                    c.column_name,
                    'Attaching ${table} to ${base} record ${id}: ${field} differs from the stored value; change it through ${base}',
                    p_table_name, v_base.table_name, v_k);
            END LOOP;
        END IF;
    END LOOP;

    -- has_a: a base change of a subtype record goes to the subtype's write
    -- routine, chosen by the id's prefix like the root's dispatch does. The
    -- record is read through the subtype's view as the caller; the base
    -- columns stored come back from the routine, whose computed fields may
    -- have set them.
    IF NOT v_is_a AND cardinality(v_root_cols) > 0 THEN
        FOR r IN
            SELECT e.table_name, e.id_prefix
              FROM dd_descendants(v_root.table_name) d
              JOIN entities e ON e.table_name = d.table_name
             WHERE e.id_type = 'is_a'
               AND pg_catalog.to_regclass(format('public.%I', e.table_name)) IS NOT NULL
             ORDER BY d.depth, e.table_name
        LOOP
            v_si := v_si + 1;
            v_route_decls := v_route_decls || format(E'\n    v_sub_old_%1$s public.%2$I;\n    v_sub_new_%1$s public.%2$I;',
                v_si, r.table_name);
            v_route_whens := v_route_whens || format($RT$
                WHEN %1$L THEN
                    SELECT * INTO v_sub_old_%2$s FROM public.%3$I AS t WHERE t.%4$I = p_old.%4$I;
                    IF NOT FOUND THEN
                        IF common.is_a_part_missing(%3$L, p_old.%4$I) THEN
                            RAISE EXCEPTION 'Record ${id} of ${table} has no part in ${subtype}, the type its id names'
                                USING ERRCODE = '90255',
                                      HINT = jsonb_build_object('id', p_old.%4$I, 'table', %5$L, 'subtype', %3$L)::text;
                        END IF;
                        RETURN NULL;
                    END IF;
                    v_sub_new_%2$s := v_sub_old_%2$s;%6$s
                    v_sub_new_%2$s := common.%7$I('update', v_sub_old_%2$s, v_sub_new_%2$s, false);
                    IF v_sub_new_%2$s IS NULL THEN
                        RETURN NULL;
                    END IF;%8$s
                    v_routed := true;$RT$,
                r.id_prefix, v_si, r.table_name, v_k, p_table_name,
                (SELECT string_agg(format(E'\n                    v_sub_new_%s.%I := v_new.%I;', v_si, x, x), '')
                   FROM unnest(v_root_cols) x),
                'record_write_' || r.table_name,
                (SELECT string_agg(format(E'\n                    v_new.%I := v_sub_new_%s.%I;', x, v_si, x), '')
                   FROM unnest(v_root_cols) x));
        END LOOP;
        IF v_route_whens <> '' THEN
            v_route := format(E'\n        -- A base change of a subtype record is written by the subtype.'
                              '\n        IF v_top <= 0 THEN'
                              '\n            CASE common.typeid_prefix(p_old.%1$I)%2$s'
                              '\n                ELSE'
                              '\n                    NULL;'
                              '\n            END CASE;'
                              '\n        END IF;',
                              v_k, v_route_whens);
        END IF;
    END IF;

    v_top_expr := CASE WHEN v_top_expr = '' THEN v_n::text
                       ELSE format('CASE%s ELSE %s END', v_top_expr, v_n) END;

    v_body := format($BODY$
CREATE OR REPLACE FUNCTION common.%1$I(p_op text, p_old %2$s, p_new %2$s, p_from_root boolean)
RETURNS %2$s
LANGUAGE plpgsql SECURITY INVOKER SET search_path = public, pg_catalog
AS $RW$
#variable_conflict use_variable
DECLARE
    v_new    %2$s := p_new;
    v_res    %2$s;
    v_old    jsonb := to_jsonb(p_old);
    v_data   jsonb;
    v_top    integer;
    v_top2   integer;
    v_base   public.%3$I;
    v_attach boolean := false;
    v_routed boolean := false;%14$s
BEGIN
    IF p_op = 'insert' THEN
%4$s
    ELSIF p_op = 'update' THEN
        IF v_new.%5$I IS DISTINCT FROM p_old.%5$I THEN
            RAISE EXCEPTION 'The key ${column} of ${table} cannot be changed'
                USING ERRCODE = '90236',
                      HINT = jsonb_build_object('column', %5$L, 'table', %6$L)::text;
        END IF;
        v_top := %7$s;%8$s
        -- Lock every level that will be written, top-down, before writing any.%9$s%15$s
%10$s
    ELSE
        -- Lock every part top-down before the rules run, so the rules of a
        -- record the caller may not delete are never evaluated.%11$s%12$s%13$s
        RETURN p_old;
    END IF;
    IF p_from_root THEN
        RETURN v_new;
    END IF;
    SELECT * INTO v_res FROM %2$s AS t WHERE t.%5$I = v_new.%5$I;
    IF NOT FOUND THEN
        RETURN v_new;
    END IF;
    RETURN v_res;
END;
$RW$;
$BODY$,
        v_fn,
        v_type,
        v_root.table_name,
        -- 4: insert
        CASE WHEN v_is_a THEN
            format(E'        IF v_new.%1$I IS NULL THEN\n            v_new.%1$I := common.typeid_generate_text(%2$L);\n        END IF;', v_k, v_entity.id_prefix)
            || CASE WHEN v_any_rules THEN E'\n        v_data := to_jsonb(v_new);' || v_rules_ins || E'\n        v_new := jsonb_populate_record(v_new, v_data);' ELSE '' END
            || format(E'\n        IF common.typeid_prefix(v_new.%1$I) IS DISTINCT FROM %2$L THEN\n            RAISE EXCEPTION ''Id ${id} does not carry the prefix ${prefix} of ${table}''\n                USING ERRCODE = ''90237'',\n                      HINT = jsonb_build_object(''id'', v_new.%1$I, ''prefix'', %2$L, ''table'', %3$L)::text;\n        END IF;',
                      v_k, v_entity.id_prefix, p_table_name)
            || v_ins
        ELSE
            format(E'        IF v_new.%1$I IS NOT NULL THEN\n            SELECT * INTO v_base FROM public.%2$I AS t WHERE t.%1$I = v_new.%1$I;\n            v_attach := FOUND;\n        END IF;\n        IF v_attach THEN%3$s\n        ELSIF v_new.%1$I IS NULL THEN\n            v_new.%1$I := common.typeid_generate_text(%4$L);\n        ELSIF common.typeid_prefix(v_new.%1$I) IS DISTINCT FROM %4$L THEN\n            RAISE EXCEPTION ''Id ${id} does not carry the prefix ${prefix} of ${table}''\n                USING ERRCODE = ''90237'',\n                      HINT = jsonb_build_object(''id'', v_new.%1$I, ''prefix'', %4$L, ''table'', %5$L)::text;\n        END IF;',
                   v_k, v_base.table_name, v_attach_in, v_base.id_prefix, v_base.table_name)
            || CASE WHEN v_any_rules THEN E'\n        v_data := to_jsonb(v_new);' || v_rules_ins || E'\n        v_new := jsonb_populate_record(v_new, v_data);'
                         || CASE WHEN v_attach_out = '' THEN '' ELSE E'\n        IF v_attach THEN' || v_attach_out || E'\n        END IF;' END
                    ELSE '' END
            || v_ins
        END,
        v_k,
        p_table_name,
        v_top_expr,
        -- 8: the rules of an update
        CASE WHEN v_any_rules THEN
            E'\n        -- The rules of the derived levels at and below the change, inherited first.'
            || E'\n        v_data := to_jsonb(v_new);' || v_rules_upd1
            || E'\n        v_new := jsonb_populate_record(v_new, v_data);'
            || format(E'\n        v_top2 := LEAST(v_top, %s);', v_top_expr)
            || E'\n        -- A computed field wrote into a level above the change: that level is'
            || E'\n        -- written as well, so its rules run too.'
            || E'\n        IF v_top2 < v_top THEN'
            || E'\n            v_data := to_jsonb(v_new);' || v_rules_upd2
            || E'\n            v_new := jsonb_populate_record(v_new, v_data);'
            || format(E'\n            v_top := LEAST(v_top2, %s);', v_top_expr)
            || E'\n        END IF;'
            || format(E'\n        IF v_new.%1$I IS DISTINCT FROM p_old.%1$I THEN\n            RAISE EXCEPTION ''The key ${column} of ${table} cannot be changed''\n                USING ERRCODE = ''90236'',\n                      HINT = jsonb_build_object(''column'', %1$L, ''table'', %2$L)::text;\n        END IF;',
                      v_k, p_table_name)
        ELSE '' END,
        v_lock,
        v_upd,
        v_dlock,
        v_rules_del,
        v_del,
        v_route_decls,
        v_route);

    EXECUTE v_body;
    EXECUTE format('REVOKE EXECUTE ON FUNCTION common.%I(text, %s, %s, boolean) FROM PUBLIC', v_fn, v_type, v_type);
    EXECUTE format('GRANT EXECUTE ON FUNCTION common.%I(text, %s, %s, boolean) TO semantius_user', v_fn, v_type, v_type);
    EXECUTE format('COMMENT ON FUNCTION common.%I(text, %s, %s, boolean) IS %L', v_fn, v_type, v_type,
        format('Writes (insert/update/delete) one record whose own type is "%s": every part of it, the rules of every derived level, locking every written level first. Returns the stored record, or NULL when the caller may not write a part. Generated by dd_refresh_family.', p_table_name));
END;
$$ LANGUAGE plpgsql SECURITY INVOKER SET search_path = public;

COMMENT ON FUNCTION dd_build_record_write(TEXT) IS
'Generates common.record_write_<entity>, the one routine that writes a record of an is_a/has_a entity. Called by dd_refresh_family.';

-- The CASE that carries a write through entity p_table_name - a supertype's
-- view, or the root table - down to the record's own type: for each is_a
-- descendant, load the full record through the descendant's view (as the
-- caller, so a part the caller cannot read skips the record), overlay the
-- columns the write names, and call the descendant's write routine. The view
-- trigger and the root's dispatch trigger both use it and differ only in
-- from_root and in what they return, so one builder serves both.
CREATE OR REPLACE FUNCTION dd_dispatch_case(
    p_table_name TEXT,
    p_from_root BOOLEAN,
    OUT decls TEXT,
    OUT branches TEXT
) AS $$
DECLARE
    v_k    TEXT := (SELECT e.id_column FROM entities e WHERE e.table_name = p_table_name);
    v_cols TEXT[];
    v_i    INTEGER := 0;
    r      RECORD;
BEGIN
    decls := '';
    branches := '';
    SELECT coalesce(array_agg(c.column_name ORDER BY c.ord), ARRAY[]::TEXT[])
      INTO v_cols
      FROM dd_family_columns(p_table_name) c;

    FOR r IN
        SELECT e.table_name, e.id_prefix
          FROM dd_descendants(p_table_name) d
          JOIN entities e ON e.table_name = d.table_name
         WHERE e.id_type = 'is_a'
           AND pg_catalog.to_regclass(format('public.%I', e.table_name)) IS NOT NULL
         ORDER BY d.depth, e.table_name
    LOOP
        v_i := v_i + 1;
        decls := decls || format(E'\n    v_old_%1$s public.%2$I;\n    v_new_%1$s public.%2$I;\n    v_res_%1$s public.%2$I;',
            v_i, r.table_name);
        -- Not found is a part the caller may not read, and the record is
        -- skipped like a row RLS hides; or a part that is missing, and the
        -- write is refused rather than reported as done.
        branches := branches || format($BR$
        WHEN %1$L THEN
            SELECT * INTO v_old_%2$s FROM public.%3$I AS t WHERE t.%4$I = OLD.%4$I;
            IF NOT FOUND THEN
                IF common.is_a_part_missing(%3$L, OLD.%4$I) THEN
                    RAISE EXCEPTION 'Record ${id} of ${table} has no part in ${subtype}, the type its id names'
                        USING ERRCODE = '90255',
                              HINT = jsonb_build_object('id', OLD.%4$I, 'table', %9$L, 'subtype', %3$L)::text;
                END IF;
                RETURN NULL;
            END IF;
            IF TG_OP = 'UPDATE' THEN
                v_new_%2$s := v_old_%2$s;
                v_new_%2$s.%4$I := NEW.%4$I;%5$s
                v_res_%2$s := common.%6$I('update', v_old_%2$s, v_new_%2$s, %7$s);
            ELSE
                v_res_%2$s := common.%6$I('delete', v_old_%2$s, v_old_%2$s, %7$s);
            END IF;
            IF v_res_%2$s IS NULL THEN
                RETURN NULL;
            END IF;%8$s$BR$,
            r.id_prefix, v_i, r.table_name, v_k,
            (SELECT coalesce(string_agg(format(E'\n                v_new_%s.%I := NEW.%I;', v_i, x, x), ''), '')
               FROM unnest(v_cols) x),
            'record_write_' || r.table_name,
            CASE WHEN p_from_root THEN 'true' ELSE 'false' END,
            CASE WHEN p_from_root
                 THEN format(E'\n            IF TG_OP = ''UPDATE'' THEN%s\n            END IF;',
                        (SELECT coalesce(string_agg(format(E'\n                NEW.%I := v_res_%s.%I;', x, v_i, x), ''), '')
                           FROM unnest(v_cols) x))
                 ELSE '' END,
            p_table_name);
    END LOOP;
END;
$$ LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = public;

COMMENT ON FUNCTION dd_dispatch_case(TEXT, BOOLEAN) IS
'The declarations and CASE branches that carry an UPDATE or DELETE through an entity down to the write routine of each is_a descendant, chosen by the prefix of the record''s id; a record the caller cannot read through the descendant''s view is skipped, one missing a part raises 90255. Shared by the view triggers and the root''s dispatch trigger.';

-- The INSTEAD OF trigger of a derived entity's view. An insert creates a
-- record of this entity. An update or delete of a record whose own type is a
-- descendant goes to the descendant's write routine, so PATCH /emails on a
-- classified email runs the classified_emails rules; the row returned is the
-- record as this view shows it.
CREATE OR REPLACE FUNCTION dd_build_view_write(p_table_name TEXT)
RETURNS VOID AS $$
DECLARE
    v_k    TEXT := (SELECT e.id_column FROM entities e WHERE e.table_name = p_table_name);
    v_fn   TEXT := 'view_write_' || p_table_name;
    v_case RECORD;
    v_own  TEXT;
BEGIN
    v_case := dd_dispatch_case(p_table_name, FALSE);
    v_own := format($OWN$
    v_res := common.%1$I(lower(TG_OP), OLD, CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END, false);
    IF v_res IS NULL THEN
        RETURN NULL;
    END IF;
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN v_res;$OWN$, 'record_write_' || p_table_name);

    EXECUTE format($BODY$
CREATE OR REPLACE FUNCTION common.%1$I()
RETURNS trigger
LANGUAGE plpgsql SECURITY INVOKER SET search_path = public, pg_catalog
AS $VW$
#variable_conflict use_variable
DECLARE
    v_res public.%2$I;%3$s
BEGIN
    IF TG_OP = 'INSERT' THEN
        v_res := common.%4$I('insert', NULL, NEW, false);
        RETURN v_res;
    END IF;%5$s
END;
$VW$;
$BODY$,
        v_fn, p_table_name, v_case.decls, 'record_write_' || p_table_name,
        CASE WHEN v_case.branches = '' THEN v_own
             ELSE format($CASE$
    CASE common.typeid_prefix(OLD.%1$I)%2$s
        ELSE%3$s
    END CASE;
    -- A descendant's record, returned as this view shows it.
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    SELECT * INTO v_res FROM public.%4$I AS t WHERE t.%1$I = NEW.%1$I;
    IF NOT FOUND THEN
        RETURN NEW;
    END IF;
    RETURN v_res;$CASE$,
                    v_k, v_case.branches, replace(v_own, E'\n    ', E'\n            '), p_table_name)
        END);

    EXECUTE format('REVOKE EXECUTE ON FUNCTION common.%I() FROM PUBLIC', v_fn);
    EXECUTE format('COMMENT ON FUNCTION common.%I() IS %L', v_fn,
        format('INSTEAD OF INSERT OR UPDATE OR DELETE trigger of the view "%s": writes through common.record_write_<type> of the record''s own type. Generated by dd_refresh_family.', p_table_name));
    EXECUTE format(
        'CREATE OR REPLACE TRIGGER view_write INSTEAD OF INSERT OR UPDATE OR DELETE ON public.%I
            FOR EACH ROW EXECUTE FUNCTION common.%I()',
        p_table_name, v_fn);
END;
$$ LANGUAGE plpgsql SECURITY INVOKER SET search_path = public;

COMMENT ON FUNCTION dd_build_view_write(TEXT) IS
'Generates the INSTEAD OF trigger common.view_write_<entity> of an is_a/has_a entity''s view and installs it. Called by dd_refresh_family.';

-- The dispatch trigger of an is_a root: a direct UPDATE or DELETE of the root
-- table that reaches a subtype record is carried down to the record's own
-- type, so PATCH /activities on a classified email runs the rules of emails and
-- classified_emails and DELETE /activities deletes every part. It acts only at
-- pg_trigger_depth() = 1, a direct write: at a deeper level the write comes
-- from a write routine, which has done that already, or from an RI action,
-- which reaches only the root row (the depth invariant above). A plain root
-- row costs one CASE. A row whose id names a subtype that has no part for it
-- is refused (90255) rather than skipped, which would report a write that
-- never happened. The name sorts before compute_validate_trigger, so the
-- root's own rules run after the derived ones, on the final root row.
CREATE OR REPLACE FUNCTION dd_build_is_a_dispatch(p_root TEXT)
RETURNS VOID AS $$
DECLARE
    v_k    TEXT := (SELECT e.id_column FROM entities e WHERE e.table_name = p_root);
    v_fn   TEXT := 'is_a_dispatch_' || p_root;
    v_case RECORD;
BEGIN
    v_case := dd_dispatch_case(p_root, TRUE);
    IF v_case.branches = '' THEN
        EXECUTE format('DROP FUNCTION IF EXISTS common.%I() CASCADE', v_fn);
        RETURN;
    END IF;

    EXECUTE format($BODY$
CREATE OR REPLACE FUNCTION common.%1$I()
RETURNS trigger
LANGUAGE plpgsql SECURITY INVOKER SET search_path = public, pg_catalog
AS $DISPATCH$
#variable_conflict use_variable
DECLARE%2$s
BEGIN
    -- Direct writes only: a deeper one comes from a write routine or an RI
    -- action (the depth invariant in 0160_dd_functions.sql).
    IF pg_trigger_depth() = 1 THEN
        CASE common.typeid_prefix(OLD.%3$I)%4$s
            ELSE
                NULL;
        END CASE;
    END IF;
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$DISPATCH$;
$BODY$,
        v_fn, v_case.decls, v_k, replace(v_case.branches, E'\n', E'\n    '));

    EXECUTE format('REVOKE EXECUTE ON FUNCTION common.%I() FROM PUBLIC', v_fn);
    EXECUTE format('COMMENT ON FUNCTION common.%I() IS %L', v_fn,
        format('BEFORE UPDATE OR DELETE trigger of the is_a root "%s": carries a direct write of a subtype record down to the write routine of its own type. Generated by dd_refresh_family.', p_root));
    EXECUTE format(
        'CREATE OR REPLACE TRIGGER a_is_a_dispatch BEFORE UPDATE OR DELETE ON public.%I
            FOR EACH ROW EXECUTE FUNCTION common.%I()',
        p_root, v_fn);
END;
$$ LANGUAGE plpgsql SECURITY INVOKER SET search_path = public;

COMMENT ON FUNCTION dd_build_is_a_dispatch(TEXT) IS
'Generates and installs the dispatch trigger of an is_a root (common.is_a_dispatch_<root>), or drops it when the root has no is_a subtype left. Called by dd_refresh_family.';

-- The delete guard of a has_a base: a base record that still has an
-- extension cannot be deleted (90251). Deletes never cascade into the parts of
-- a record; an extension is removed through its own entity first, where its
-- rules and permissions apply. The RESTRICT key of <extension>_ext is the
-- backstop. TG_ARGV[0] is the key column, the rest the extension entities.
-- SECURITY DEFINER, like a foreign key check, so an extension row the caller
-- cannot read still blocks the delete; the refusal names the extension, never
-- its contents.
CREATE OR REPLACE FUNCTION common.has_a_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = common, pg_catalog
AS $$
DECLARE
    v_found BOOLEAN;
BEGIN
    FOR i IN 1 .. TG_NARGS - 1 LOOP
        EXECUTE format('SELECT EXISTS (SELECT 1 FROM public.%I t WHERE t.%I = $1::common.typeid)',
                       TG_ARGV[i] || '_ext', TG_ARGV[0])
           INTO v_found
          USING to_jsonb(OLD) ->> TG_ARGV[0];
        IF v_found THEN
            RAISE EXCEPTION 'Record ${id} of ${table} still has a ${extension} record; remove it through ${extension} first'
                USING ERRCODE = '90251',
                      HINT = jsonb_build_object('id', to_jsonb(OLD) ->> TG_ARGV[0], 'table', TG_TABLE_NAME,
                                                'extension', TG_ARGV[i])::text;
        END IF;
    END LOOP;
    RETURN OLD;
END;
$$;

COMMENT ON FUNCTION common.has_a_guard() IS
'BEFORE DELETE trigger of a has_a base (TG_ARGV: key column, then the extension entities): refuses to delete a record that still has an extension record (90251).';

-- TRUE when the root holds a row with the id but some level of the is_a
-- entity p_table has no part for it: a record the dispatch cannot carry to
-- its own type. The dispatch reads the record through the subtype's view as
-- the caller, and finds nothing both for a part the caller may not read and
-- for a part that is not there; only the second is an error (90255), and
-- only the definer can tell them apart. It answers FALSE for a complete
-- record and for an id no row has, so it tells a caller nothing but that a
-- record is broken. A missing part cannot come from the dictionary's own
-- writes: 90254 keeps a new subtype off the prefixes of existing rows, and
-- the parts are written only by the write routines.
CREATE OR REPLACE FUNCTION common.is_a_part_missing(p_table TEXT, p_id TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
    v_key     TEXT;
    v_missing BOOLEAN;
    r         RECORD;
BEGIN
    SELECT e.id_column INTO v_key FROM entities e WHERE e.table_name = p_table AND e.id_type = 'is_a';
    IF NOT FOUND THEN
        RETURN FALSE;
    END IF;
    FOR r IN
        SELECT a.depth, dd_relation(e.table_name, e.id_type) AS rel
          FROM dd_ancestors(p_table) a
          JOIN entities e ON e.table_name = a.table_name
         ORDER BY a.depth
    LOOP
        EXECUTE format('SELECT NOT EXISTS (SELECT 1 FROM public.%I t WHERE t.%I = $1::common.typeid)', r.rel, v_key)
           INTO v_missing
          USING p_id;
        IF v_missing THEN
            -- No root row: no record at all, which is no broken one.
            RETURN r.depth > 0;
        END IF;
    END LOOP;
    RETURN FALSE;
END;
$$;

COMMENT ON FUNCTION common.is_a_part_missing(TEXT, TEXT) IS
'TRUE when the root of is_a entity p_table holds a row with id p_id but a level of p_table has no part for it. Run as the definer, so a part the caller may not read counts as present. Used by the generated dispatch to refuse a write it cannot carry to the record''s own type (90255).';

-- Objects built on a family view by someone else. A family is rebuilt by
-- dropping its views with CASCADE (dd_refresh_family, and the DROP COLUMN
-- ... CASCADE of a field delete or a search_vector rebuild before it), and
-- PostgreSQL drops whatever depends on a view with it: a report view, a
-- function over the view's row type, a policy that reads it. On a plain entity
-- a field change never touches what is built on its table, so these would
-- vanish without a word on a change that looks harmless, like a field add.
-- A change that drops a family view is therefore refused while such an object
-- exists (90256), and the refusal names it; the admin drops it, makes the
-- change and creates it again.
--
-- What the dictionary itself builds on a view is not counted, and neither is
-- what depends on that: the view's own rule, column defaults and row type
-- (with its array type), its view_write trigger, the write, view trigger and
-- dispatch routines, the one-argument _label / <fk>_label functions of its row
-- type (rebuild_entity_label_functions drops every one of those itself), and
-- the select_rule functions.
CREATE OR REPLACE FUNCTION dd_generated_view_dependent(p_classid OID, p_objid OID, p_views OID[])
RETURNS BOOLEAN AS $$
    SELECT CASE p_classid
        WHEN 'pg_catalog.pg_rewrite'::regclass THEN
            EXISTS (SELECT 1 FROM pg_catalog.pg_rewrite r
                     WHERE r.oid = p_objid AND r.ev_class = ANY (p_views))
        WHEN 'pg_catalog.pg_attrdef'::regclass THEN
            EXISTS (SELECT 1 FROM pg_catalog.pg_attrdef a
                     WHERE a.oid = p_objid AND a.adrelid = ANY (p_views))
        WHEN 'pg_catalog.pg_trigger'::regclass THEN
            EXISTS (SELECT 1 FROM pg_catalog.pg_trigger t
                     WHERE t.oid = p_objid AND t.tgrelid = ANY (p_views) AND t.tgname = 'view_write')
        WHEN 'pg_catalog.pg_type'::regclass THEN
            EXISTS (SELECT 1 FROM pg_catalog.pg_type t
                      JOIN pg_catalog.pg_class c ON c.reltype IN (t.oid, t.typelem)
                     WHERE t.oid = p_objid AND c.oid = ANY (p_views))
        WHEN 'pg_catalog.pg_proc'::regclass THEN
            EXISTS (SELECT 1 FROM pg_catalog.pg_proc p
                     WHERE p.oid = p_objid
                       AND ((p.pronamespace = 'common'::regnamespace
                             AND (p.proname LIKE 'record\_write\_%'
                                  OR p.proname LIKE 'view\_write\_%'
                                  OR p.proname LIKE 'is\_a\_dispatch\_%'))
                            OR (p.pronamespace = 'public'::regnamespace
                                AND (p.proname LIKE 'select\_rule\_%'
                                     OR (p.pronargs = 1
                                         AND (p.proname = '_label' OR p.proname LIKE '%\_label'))))))
        ELSE FALSE
    END;
$$ LANGUAGE sql STABLE SET search_path = public;

COMMENT ON FUNCTION dd_generated_view_dependent(OID, OID, OID[]) IS
'TRUE when the object (pg_depend classid, objid) that depends on one of the family views p_views is one the dictionary generates for them: a view''s rule, column default, row or array type, view_write trigger, write/view-trigger/dispatch routine, _label or <fk>_label function, or select_rule function.';

-- The objects that depend on the views p_views, directly or through a
-- generated object, and are not generated themselves; each with the view it
-- is built on. The walk follows pg_depend from the views and continues only
-- through generated objects: whatever depends on a foreign object is dropped
-- with it, and naming the first is enough.
CREATE OR REPLACE FUNCTION dd_family_view_dependents(p_views OID[])
RETURNS TABLE (view_name TEXT, dependent TEXT) AS $$
    WITH RECURSIVE dep(view_oid, classid, objid, generated, hops) AS (
        SELECT d.refobjid, d.classid, d.objid,
               dd_generated_view_dependent(d.classid, d.objid, p_views), 1
          FROM pg_catalog.pg_depend d
         WHERE d.refclassid = 'pg_catalog.pg_class'::regclass
           AND d.refobjid = ANY (p_views)
        UNION
        SELECT dep.view_oid, d.classid, d.objid,
               dd_generated_view_dependent(d.classid, d.objid, p_views), dep.hops + 1
          FROM dep
          JOIN pg_catalog.pg_depend d ON d.refclassid = dep.classid AND d.refobjid = dep.objid
         WHERE dep.generated
           AND dep.hops < 6
    )
    SELECT DISTINCT
           dep.view_oid::regclass::text,
           CASE WHEN dep.classid = 'pg_catalog.pg_rewrite'::regclass
                THEN (SELECT CASE c.relkind WHEN 'm' THEN 'materialized view ' ELSE 'view ' END
                             || c.oid::regclass::text
                        FROM pg_catalog.pg_rewrite r
                        JOIN pg_catalog.pg_class c ON c.oid = r.ev_class
                       WHERE r.oid = dep.objid)
                ELSE pg_catalog.pg_describe_object(dep.classid, dep.objid, 0)
           END
      FROM dep
     WHERE NOT dep.generated;
$$ LANGUAGE sql STABLE SET search_path = public;

COMMENT ON FUNCTION dd_family_view_dependents(OID[]) IS
'The objects built on the family views p_views, directly or through a generated object, that the dictionary did not generate (dd_generated_view_dependent), each with the view it depends on.';

-- Refuses (90256) a change that drops the views of the families containing
-- any of p_entities while objects of another author depend on them. Called
-- before the first DROP ... CASCADE that can reach a family view: at the start
-- of dd_refresh_family, and in delete_dd_field, update_search_vector_column and
-- delete_dd_table, whose drops come before the refresh. Reads only, and
-- returns at once for an entity outside every family.
CREATE OR REPLACE FUNCTION dd_check_family_dependents(p_entities TEXT[])
RETURNS VOID AS $$
DECLARE
    v_views      OID[];
    v_on         TEXT;
    v_dependents TEXT;
BEGIN
    SELECT array_agg(DISTINCT c.oid)
      INTO v_views
      FROM unnest(coalesce(p_entities, ARRAY[]::TEXT[])) AS t(name)
     CROSS JOIN LATERAL dd_ancestors(t.name) a
     CROSS JOIN LATERAL dd_descendants(a.table_name) d
      JOIN pg_catalog.pg_class c ON c.oid = pg_catalog.to_regclass(format('public.%I', d.table_name))
     WHERE a.depth = 0
       AND c.relkind = 'v';
    IF v_views IS NULL THEN
        RETURN;
    END IF;

    SELECT string_agg(DISTINCT x.view_name, ', ' ORDER BY x.view_name),
           string_agg(DISTINCT x.dependent, ', ' ORDER BY x.dependent)
      INTO v_on, v_dependents
      FROM dd_family_view_dependents(v_views) x;
    IF v_dependents IS NOT NULL THEN
        RAISE EXCEPTION 'This change drops ${views}, and with them ${dependents}, which the dictionary did not create'
            USING ERRCODE = '90256',
                  HINT = jsonb_build_object(
                      'views', v_on,
                      'dependents', v_dependents,
                      'hint', 'Drop those objects, make the change, then create them again.')::text;
    END IF;
END;
$$ LANGUAGE plpgsql STABLE SET search_path = public;

COMMENT ON FUNCTION dd_check_family_dependents(TEXT[]) IS
'Raises 90256 when objects the dictionary did not generate depend on a view of a family containing any of the given entities, before a change drops those views. Returns at once for entities outside every family.';

-- Rebuilds every family that contains one of the given entities: the views,
-- the write routines and view triggers, the root's typeid_assign (with the
-- subtype prefixes) and dispatch trigger, the has_a delete guard, and the
-- label functions. It runs at the end of every statement on fields (from
-- apply_field_searchable_change, after all row-level DDL), and after a change
-- to a family's members; for an entity outside every family it only reads and
-- returns, so an ordinary field write costs no more than before. A root that
-- lost its last dependent is visited once more, to take its dispatch trigger
-- and guard away.
CREATE OR REPLACE FUNCTION dd_refresh_family(p_touched TEXT[])
RETURNS VOID AS $$
DECLARE
    v_roots  TEXT[];
    v_root   entities%ROWTYPE;
    v_guard  TEXT;
    v_marked BOOLEAN;
    r        RECORD;
BEGIN
    SELECT array_agg(DISTINCT a.table_name)
      INTO v_roots
      FROM unnest(coalesce(p_touched, ARRAY[]::TEXT[])) AS t(name)
     CROSS JOIN LATERAL dd_ancestors(t.name) a
     WHERE a.depth = 0
       AND (EXISTS (SELECT 1 FROM entities d WHERE d.id_refentity = a.table_name)
            OR EXISTS (SELECT 1 FROM pg_catalog.pg_trigger tg
                        WHERE tg.tgrelid = pg_catalog.to_regclass(format('public.%I', a.table_name))
                          AND tg.tgname IN ('a_is_a_dispatch', 'a_has_a_guard')));
    IF v_roots IS NULL THEN
        RETURN;
    END IF;

    -- Step 1 drops every view with CASCADE: refused while an object of
    -- another author is built on one (90256).
    PERFORM dd_check_family_dependents(v_roots);

    SET LOCAL client_min_messages = WARNING;

    -- The rebuild follows from the change that caused it, and that change is
    -- what the DDL audit records: while this row exists its event triggers
    -- skip the rebuild's DDL (audit.log_ddl_event in 0200_audit_log.sql). The
    -- outermost call owns the row; an error rolls it back with everything else.
    INSERT INTO audit.generated_ddl DEFAULT VALUES ON CONFLICT DO NOTHING RETURNING TRUE INTO v_marked;

    FOR v_root IN SELECT e.* FROM entities e WHERE e.table_name = ANY (v_roots) LOOP
        -- In a module-delete cascade the root may already be gone.
        CONTINUE WHEN pg_catalog.to_regclass(format('public.%I', v_root.table_name)) IS NULL;

        -- 1. The views, all dropped before any is created: CASCADE takes the
        --    write routines and label functions typed by them.
        FOR r IN
            SELECT d.table_name FROM dd_descendants(v_root.table_name) d ORDER BY d.depth, d.table_name
        LOOP
            EXECUTE format('DROP VIEW IF EXISTS public.%I CASCADE', r.table_name);
        END LOOP;
        FOR r IN
            SELECT d.table_name FROM dd_descendants(v_root.table_name) d
             WHERE pg_catalog.to_regclass(format('public.%I', d.table_name || '_ext')) IS NOT NULL
             ORDER BY d.depth, d.table_name
        LOOP
            PERFORM dd_build_family_view(r.table_name);
        END LOOP;

        -- 2. The write routines, then the view triggers that call them.
        FOR r IN
            SELECT d.table_name FROM dd_descendants(v_root.table_name) d
             WHERE pg_catalog.to_regclass(format('public.%I', d.table_name)) IS NOT NULL
             ORDER BY d.depth, d.table_name
        LOOP
            PERFORM dd_build_record_write(r.table_name);
        END LOOP;
        FOR r IN
            SELECT d.table_name FROM dd_descendants(v_root.table_name) d
             WHERE pg_catalog.to_regclass(format('public.%I', d.table_name)) IS NOT NULL
             ORDER BY d.depth, d.table_name
        LOOP
            PERFORM dd_build_view_write(r.table_name);
        END LOOP;

        -- 3. The root's key triggers, which carry the subtype prefixes, and
        --    its dispatch trigger.
        PERFORM dd_install_id_triggers(v_root.table_name, v_root.id_column, v_root.id_type, v_root.id_prefix);
        PERFORM dd_build_is_a_dispatch(v_root.table_name);

        -- 4. The delete guard of a has_a base.
        SELECT string_agg(format(', %L', e.table_name), '' ORDER BY e.table_name)
          INTO v_guard
          FROM entities e
         WHERE e.id_refentity = v_root.table_name
           AND e.id_type = 'has_a';
        IF v_guard IS NULL THEN
            EXECUTE format('DROP TRIGGER IF EXISTS a_has_a_guard ON public.%I', v_root.table_name);
        ELSE
            EXECUTE format(
                'CREATE OR REPLACE TRIGGER a_has_a_guard BEFORE DELETE ON public.%I
                    FOR EACH ROW EXECUTE FUNCTION common.has_a_guard(%L%s)',
                v_root.table_name, v_root.id_column, v_guard);
        END IF;

        -- 5. The label functions of the views.
        FOR r IN
            SELECT d.table_name FROM dd_descendants(v_root.table_name) d ORDER BY d.depth, d.table_name
        LOOP
            PERFORM rebuild_entity_label_functions(r.table_name);
        END LOOP;
    END LOOP;

    IF v_marked THEN
        DELETE FROM audit.generated_ddl WHERE transaction_id = pg_current_xact_id();
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY INVOKER SET search_path = public;

COMMENT ON FUNCTION dd_refresh_family(TEXT[]) IS
'Rebuilds the families containing any of the given entities: views, write routines, view triggers, the root''s typeid_assign and dispatch trigger, the has_a delete guard and the label functions, keeping that DDL out of the DDL audit (audit.generated_ddl). Returns at once, without writing, when none of them belongs to a family.';

-- A family member renamed or deleted: the rest of its family is rebuilt under
-- the new name, or without it. After the rename triggers of 0170_dd_rename.sql
-- and the rule and policy rebuilds, whose names sort earlier.
CREATE OR REPLACE FUNCTION dd_family_member_changed()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        PERFORM dd_refresh_family(ARRAY[OLD.id_refentity]);
        RETURN OLD;
    END IF;
    PERFORM dd_refresh_family(ARRAY[NEW.table_name]);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION dd_family_member_changed() IS
'AFTER UPDATE (rename) and AFTER DELETE trigger on entities: rebuilds the family of a renamed entity, or of a deleted is_a/has_a entity''s base.';

CREATE OR REPLACE TRIGGER zz_family_refresh_rename_trigger
    AFTER UPDATE ON entities
    FOR EACH ROW
    WHEN (OLD.table_name IS DISTINCT FROM NEW.table_name)
    EXECUTE FUNCTION dd_family_member_changed();

CREATE OR REPLACE TRIGGER zz_family_refresh_delete_trigger
    AFTER DELETE ON entities
    FOR EACH ROW
    WHEN (OLD.id_refentity IS NOT NULL)
    EXECUTE FUNCTION dd_family_member_changed();

-- =====================================================
-- GET RECORD BY ID
-- =====================================================
-- Looks up an entity by table_name, reads its id_column, then queries the
-- physical table for the row matching the supplied id value. Returns the
-- full row as JSONB, or NULL when the entity or record does not exist.
--
-- The id is TEXT so one function serves every key type; it is cast to the
-- key column's own type inside the query, which keeps the primary key index
-- usable (comparing the column as text would not). An id that cannot be cast
-- raises 90238 rather than returning NULL: a malformed id is the caller's
-- mistake, not a record that is missing. The test is pg_input_is_valid, not a
-- caught cast error, because an exception block opens a subtransaction on
-- every call and set_record can reach this once per row; it covers the
-- common.typeid domain's CHECK as well as the base type's syntax and range.
--
-- get_record_by_id(TEXT, BIGINT) below keeps numeric callers working.

DROP FUNCTION IF EXISTS get_record_by_id(TEXT, INTEGER);

CREATE OR REPLACE FUNCTION get_record_by_id(p_entity_name TEXT, p_id TEXT)
RETURNS JSONB AS $$
DECLARE
    v_id_column       TEXT;
    v_result          JSONB;
    v_allowed         BOOLEAN;
    v_key_type        TEXT;
    v_valid           BOOLEAN;
    v_level           RECORD;
BEGIN
    -- Authenticate the caller. This function is SECURITY DEFINER and therefore
    -- bypasses RLS, so it MUST enforce the same access control that RLS would.
    -- rbac.uid() validates the JWT and raises on a session that carries no valid
    -- claims; the permission check further down builds the context cache if this
    -- is the first check of the transaction.
    PERFORM rbac.uid();

    -- Look up the entity to find its id_column.
    SELECT id_column INTO v_id_column
    FROM entities
    WHERE table_name = p_entity_name;

    -- Entity not found
    IF NOT FOUND OR p_id IS NULL THEN
        RETURN NULL;
    END IF;

    -- The key's declared type, as format_type spells it (a domain comes back
    -- schema-qualified, since `common` is not on this function's search_path),
    -- so it can be interpolated as a type name. No column means no table: an
    -- unmanaged entity registered without one. An is_a or has_a entity is read
    -- through its view, whose key column has the key's type.
    SELECT pg_catalog.format_type(a.atttypid, a.atttypmod)
      INTO v_key_type
      FROM pg_catalog.pg_attribute a
     WHERE a.attrelid = pg_catalog.to_regclass(format('public.%I', p_entity_name))::oid
       AND a.attname = v_id_column
       AND a.attnum > 0
       AND NOT a.attisdropped;
    IF v_key_type IS NULL THEN
        RETURN NULL;
    END IF;

    -- Through EXECUTE, not as a PL/pgSQL expression: pg_input_is_valid parses
    -- its type-name argument once and keeps it for later calls whenever that
    -- argument looks constant to the executor, which a PL/pgSQL variable does,
    -- and PL/pgSQL keeps the expression's state for the whole transaction. The
    -- second get_record_by_id of a transaction would then check the id against
    -- the first call's key type. A dynamic statement starts from scratch.
    EXECUTE format('SELECT pg_catalog.pg_input_is_valid($1, %L)', v_key_type)
       INTO v_valid USING p_id;

    -- Only a caller who may see the entity's schema learns that the id was
    -- malformed; anybody else gets the NULL that also answers "no such entity",
    -- so the refusal does not reveal that the entity exists or what its key is.
    IF NOT v_valid THEN
        IF dd_entity_viewable(p_entity_name) THEN
            RAISE EXCEPTION 'Invalid record id ${id} for entity ${table}'
                USING ERRCODE = '90238',
                      HINT = jsonb_build_object('id', p_id, 'table', p_entity_name)::text;
        END IF;
        RETURN NULL;
    END IF;

    -- Enforce the CANONICAL PREDICATE (spec authz-spec.md / D8), the SAME boundary
    -- the RLS SELECT policy uses — NOT view_permission alone — of every level
    -- the record is stored in: one for a plain entity, the root and each base
    -- for an is_a or has_a entity, whose security_invoker view applies all of
    -- their policies. Return NULL rather than raising when the row is
    -- inaccessible, so callers (incl. the set_record operator) cannot
    -- distinguish "not allowed" from "does not exist", preventing
    -- record-existence leakage.
    FOR v_level IN
        SELECT e.table_name, e.id_type, e.view_permission, e.select_rule
          FROM dd_ancestors(p_entity_name) a
          JOIN entities e ON e.table_name = a.table_name
         ORDER BY a.depth
    LOOP
        IF v_level.select_rule IS NULL OR v_level.select_rule = '{}'::jsonb THEN
            -- No row rule: view_permission is the access predicate (the default rule).
            IF NOT rbac.has_permission(v_level.view_permission) THEN
                RETURN NULL;
            END IF;
        ELSE
            -- select_rule REPLACES view_permission: evaluate the per-row rule for THIS row.
            -- (The select_rule_<table>() helper is created by build_select_rule_policy.)
            EXECUTE format(
                'SELECT public.%I(t) FROM public.%I t WHERE t.%I = $1::%s LIMIT 1',
                'select_rule_' || v_level.table_name, dd_relation(v_level.table_name, v_level.id_type),
                v_id_column, v_key_type
            ) INTO v_allowed USING p_id;
            IF NOT COALESCE(v_allowed, FALSE) THEN
                RETURN NULL;
            END IF;
        END IF;
    END LOOP;

    EXECUTE format(
        'SELECT row_to_json(t)::jsonb FROM public.%I t WHERE t.%I = $1::%s LIMIT 1',
        p_entity_name, v_id_column, v_key_type
    ) INTO v_result USING p_id;

    RETURN v_result;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION get_record_by_id(TEXT, TEXT) IS
'Returns a single entity record as JSONB by looking up the entity id_column and querying the physical table (the view of an is_a/has_a entity); the id is cast to the key''s type, so every key type works. SECURITY DEFINER: authenticates via rbac.uid() and enforces the canonical read predicate of every level the record is stored in (the same access boundary as RLS / get_schema). Returns NULL when the entity or record does not exist, or when the caller may not read it (indistinguishable, to avoid leaking record existence). Raises 90238 for an id that is not a valid value of the key type, to a caller who may see the entity.';

-- Numeric callers: a bigint or integer argument resolves here rather than to
-- the TEXT version, since PostgreSQL casts neither to text implicitly. The
-- parameter names differ from the TEXT version's on purpose: PostgREST picks
-- an RPC overload by the names of the JSON keys, so {p_entity_name, p_id} and
-- {p_entity, p_record_id} each reach exactly one function and never raise
-- PGRST203 (ambiguous overload). SECURITY INVOKER: the TEXT version does the
-- authentication and the access check.
CREATE OR REPLACE FUNCTION get_record_by_id(p_entity TEXT, p_record_id BIGINT)
RETURNS JSONB AS $$
    SELECT public.get_record_by_id(p_entity, p_record_id::text);
$$ LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public;

COMMENT ON FUNCTION get_record_by_id(TEXT, BIGINT) IS
'Numeric-key convenience overload of get_record_by_id(TEXT, TEXT): same result, same access checks.';

-- Revoke default PUBLIC execute on all DDL functions defined in this file
REVOKE EXECUTE ON FUNCTION get_record_by_id(TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_record_by_id(TEXT, TEXT) TO semantius_user;
REVOKE EXECUTE ON FUNCTION get_record_by_id(TEXT, BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_record_by_id(TEXT, BIGINT) TO semantius_user;
REVOKE EXECUTE ON FUNCTION dd_id_type_data_type(TEXT) FROM PUBLIC;
-- The family helpers read nothing the request role cannot read itself, and
-- enforce_table_searchable_consistency, which runs as the writer of the
-- entities row, reaches dd_entity_searchable and through it the others.
REVOKE EXECUTE ON FUNCTION dd_relation(TEXT, TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION dd_relation(TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION dd_ancestors(TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION dd_descendants(TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION dd_family_fields(TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION dd_entity_viewable(TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION dd_entity_searchable(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION dd_relation(TEXT, TEXT) TO semantius_user;
GRANT EXECUTE ON FUNCTION dd_relation(TEXT) TO semantius_user;
GRANT EXECUTE ON FUNCTION dd_ancestors(TEXT) TO semantius_user;
GRANT EXECUTE ON FUNCTION dd_descendants(TEXT) TO semantius_user;
GRANT EXECUTE ON FUNCTION dd_family_fields(TEXT) TO semantius_user;
GRANT EXECUTE ON FUNCTION dd_entity_viewable(TEXT) TO semantius_user;
GRANT EXECUTE ON FUNCTION dd_entity_searchable(TEXT) TO semantius_user;
REVOKE EXECUTE ON FUNCTION dd_entity_is_child(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION dd_entity_is_child(TEXT) TO semantius_user;
REVOKE EXECUTE ON FUNCTION dd_family_columns(TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION dd_build_family_view(TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION dd_build_record_write(TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION dd_dispatch_case(TEXT, BOOLEAN) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION dd_build_view_write(TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION dd_build_is_a_dispatch(TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION dd_refresh_family(TEXT[]) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION dd_generated_view_dependent(OID, OID, OID[]) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION dd_family_view_dependents(OID[]) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION dd_check_family_dependents(TEXT[]) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION dd_family_member_changed() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION check_entity_family() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION dd_family_label_column_changed() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION validate_family_field() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION common.has_a_guard() FROM PUBLIC;
-- Called by the generated dispatch, which runs as the caller.
REVOKE EXECUTE ON FUNCTION common.is_a_part_missing(TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION common.is_a_part_missing(TEXT, TEXT) TO semantius_user;
REVOKE EXECUTE ON FUNCTION dd_id_column_ddl(TEXT, TEXT, TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION dd_check_id_column(TEXT, TEXT, TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION dd_install_id_triggers(TEXT, TEXT, TEXT, TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION dd_sync_typeid_prefix() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION format_to_data_type(TEXT, SMALLINT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION field_data_type(TEXT, SMALLINT, TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION enum_value_list(JSONB) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION effective_enum_values(TEXT, JSONB) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION effective_enum_default(TEXT, TEXT, JSONB) FROM PUBLIC;
-- enum_value_list with them: both effective_* functions call it.
GRANT EXECUTE ON FUNCTION enum_value_list(JSONB) TO semantius_user;
GRANT EXECUTE ON FUNCTION effective_enum_values(TEXT, JSONB) TO semantius_user;
GRANT EXECUTE ON FUNCTION effective_enum_default(TEXT, TEXT, JSONB) TO semantius_user;
REVOKE EXECUTE ON FUNCTION is_nullable(TEXT) FROM PUBLIC;
-- Grant is_nullable to semantius_user: it is called directly (e.g. in get_schema's required-fields
-- query and the field DDL triggers) in the inserting user's context, so semantius_user needs EXECUTE.
GRANT EXECUTE ON FUNCTION is_nullable(TEXT) TO semantius_user;
REVOKE EXECUTE ON FUNCTION format_to_json_type(TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION field_json_type(TEXT, TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION quote_default_value(TEXT, TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION dd_table_comment(TEXT, TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION dd_field_comment(TEXT, TEXT, TEXT, JSONB) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION create_dd_table() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION create_entity_policies(TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION update_dd_table_comment() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION add_dd_field() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION update_dd_field() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION delete_dd_field() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION delete_dd_table() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION update_search_vector_column(TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION update_table_searchable_flag(TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION apply_field_searchable_change(TEXT[], TEXT[]) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION handle_field_searchable_insert() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION handle_field_searchable_update() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION handle_field_searchable_delete() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION enforce_table_searchable_consistency() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION update_table_is_child_flag(TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION handle_field_parent_format_change() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION enforce_table_is_child_consistency() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION update_entity_policies() FROM PUBLIC;
