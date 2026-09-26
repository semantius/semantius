-- =====================================================
-- UUIDv7 AND TYPEID HELPERS
-- =====================================================
-- based on https://github.com/jetify-com/typeid-sql
-- (commit 92ff72a2c1c9a97baf3769bcf8eb2238222d0396), files sql/01_uuidv7.sql,
-- sql/02_base32.sql and the text functions of sql/03_typeid.sql
-- Copyright (c) Jetify Inc., Apache License 2.0
-- (full text and notice in THIRD_PARTY_NOTICES.md at the repository root)
-- modified: schema-qualified into common; only the text subset is kept (no
-- composite typeid type, no operators, no typeid_parse/typeid_print);
-- typeid_check_text is a one-argument, non-raising boolean check; the prefix
-- is read by typeid_prefix; base32_decode raises 22P02, checks the byte length
-- and is STABLE; uuid_v7 uses the native uuidv7() on PostgreSQL 18.
--
-- Repeatable: functions only. The common.typeid domain, which the key columns
-- of typeid entities are declared with, is in 0046_typeid.once.sql, because a
-- domain is a type and types run once.
--
-- Everything lives in `common`, not `public`: PostgREST exposes every function
-- in `public` as an RPC, and these are building blocks of column defaults,
-- triggers and a domain check, not calls a client makes.
--
-- Grants. A column default, a trigger body and a domain CHECK all run with the
-- rights of the role that writes the row, which on the request path is
-- semantius_user, so the value functions are granted to it; the default
-- REVOKE from PUBLIC does not hold on its own, see 0020_settings.once.sql.
-- The two trigger functions are not granted: PostgreSQL checks EXECUTE on a
-- trigger function when the trigger is created, not when it fires.

-- -----------------------------------------------------
-- common.uuid_v7()
-- -----------------------------------------------------
-- A version 7 UUID: 48 bits of Unix milliseconds, then random bits, so values
-- sort by creation time and index like a sequence rather than scattering
-- inserts across a B-tree the way gen_random_uuid() does.
--
-- PostgreSQL 18 has uuidv7() built in, with sub-millisecond precision and a
-- monotonic counter within a backend. PostgreSQL 17 does not, so the body is
-- chosen once, here, by the server version at migration time: a per-call test
-- would cost a version lookup on every insert. The PL/pgSQL fallback is
-- jetify's, and only has millisecond precision, so two values generated in the
-- same millisecond are ordered randomly - ordering is by time, not strict.
DO $do$
BEGIN
    IF current_setting('server_version_num')::int >= 180000 THEN
        EXECUTE $fn$
            CREATE OR REPLACE FUNCTION common.uuid_v7()
            RETURNS uuid
            LANGUAGE sql
            VOLATILE PARALLEL SAFE
            SET search_path = common, pg_catalog
            AS $body$ SELECT pg_catalog.uuidv7() $body$
        $fn$;
    ELSE
        EXECUTE $fn$
            CREATE OR REPLACE FUNCTION common.uuid_v7()
            RETURNS uuid
            LANGUAGE plpgsql
            VOLATILE PARALLEL SAFE
            SET search_path = common, pg_catalog
            AS $body$
            DECLARE
              unix_ts_ms bytea;
              uuid_bytes bytea;
            BEGIN
              unix_ts_ms = substring(int8send(floor(extract(epoch from clock_timestamp()) * 1000)::bigint) from 3);
              uuid_bytes = uuid_send(gen_random_uuid());
              uuid_bytes = overlay(uuid_bytes placing unix_ts_ms from 1 for 6);
              uuid_bytes = set_byte(uuid_bytes, 6, (b'0111' || get_byte(uuid_bytes, 6)::bit(4))::bit(8)::int);
              RETURN encode(uuid_bytes, 'hex')::uuid;
            END
            $body$
        $fn$;
    END IF;
END
$do$;

COMMENT ON FUNCTION common.uuid_v7() IS
'Generates a version 7 (time-ordered) UUID. Native uuidv7() on PostgreSQL 18, a PL/pgSQL fallback with millisecond precision on PostgreSQL 17; the body is chosen once when the migration runs. The default of uuid entity keys.';

-- -----------------------------------------------------
-- common.base32_encode(uuid) / common.base32_decode(text)
-- -----------------------------------------------------
-- The TypeID suffix: the 128 bits of a UUID as 26 characters of Crockford's
-- lowercase base32 alphabet, 2 padding bits first, so the first character is
-- always 0-7. Written out byte by byte, as jetify does, because PL/pgSQL has
-- no bit-string slicing that beats it.
CREATE OR REPLACE FUNCTION common.base32_encode(id uuid)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE STRICT PARALLEL SAFE
SET search_path = common, pg_catalog
AS $$
DECLARE
  bytes bytea;
  alphabet bytea = '0123456789abcdefghjkmnpqrstvwxyz';
  output text = '';
BEGIN
  bytes = uuid_send(id);

  -- 10 byte timestamp
  output = output || chr(get_byte(alphabet, (get_byte(bytes, 0) & 224) >> 5));
  output = output || chr(get_byte(alphabet, (get_byte(bytes, 0) & 31)));
  output = output || chr(get_byte(alphabet, (get_byte(bytes, 1) & 248) >> 3));
  output = output || chr(get_byte(alphabet, ((get_byte(bytes, 1) & 7) << 2) | ((get_byte(bytes, 2) & 192) >> 6)));
  output = output || chr(get_byte(alphabet, (get_byte(bytes, 2) & 62) >> 1));
  output = output || chr(get_byte(alphabet, ((get_byte(bytes, 2) & 1) << 4) | ((get_byte(bytes, 3) & 240) >> 4)));
  output = output || chr(get_byte(alphabet, ((get_byte(bytes, 3) & 15) << 1) | ((get_byte(bytes, 4) & 128) >> 7)));
  output = output || chr(get_byte(alphabet, (get_byte(bytes, 4) & 124) >> 2));
  output = output || chr(get_byte(alphabet, ((get_byte(bytes, 4) & 3) << 3) | ((get_byte(bytes, 5) & 224) >> 5)));
  output = output || chr(get_byte(alphabet, (get_byte(bytes, 5) & 31)));

  -- 16 bytes of entropy
  output = output || chr(get_byte(alphabet, (get_byte(bytes, 6) & 248) >> 3));
  output = output || chr(get_byte(alphabet, ((get_byte(bytes, 6) & 7) << 2) | ((get_byte(bytes, 7) & 192) >> 6)));
  output = output || chr(get_byte(alphabet, (get_byte(bytes, 7) & 62) >> 1));
  output = output || chr(get_byte(alphabet, ((get_byte(bytes, 7) & 1) << 4) | ((get_byte(bytes, 8) & 240) >> 4)));
  output = output || chr(get_byte(alphabet, ((get_byte(bytes, 8) & 15) << 1) | ((get_byte(bytes, 9) & 128) >> 7)));
  output = output || chr(get_byte(alphabet, (get_byte(bytes, 9) & 124) >> 2));
  output = output || chr(get_byte(alphabet, ((get_byte(bytes, 9) & 3) << 3) | ((get_byte(bytes, 10) & 224) >> 5)));
  output = output || chr(get_byte(alphabet, (get_byte(bytes, 10) & 31)));
  output = output || chr(get_byte(alphabet, (get_byte(bytes, 11) & 248) >> 3));
  output = output || chr(get_byte(alphabet, ((get_byte(bytes, 11) & 7) << 2) | ((get_byte(bytes, 12) & 192) >> 6)));
  output = output || chr(get_byte(alphabet, (get_byte(bytes, 12) & 62) >> 1));
  output = output || chr(get_byte(alphabet, ((get_byte(bytes, 12) & 1) << 4) | ((get_byte(bytes, 13) & 240) >> 4)));
  output = output || chr(get_byte(alphabet, ((get_byte(bytes, 13) & 15) << 1) | ((get_byte(bytes, 14) & 128) >> 7)));
  output = output || chr(get_byte(alphabet, (get_byte(bytes, 14) & 124) >> 2));
  output = output || chr(get_byte(alphabet, ((get_byte(bytes, 14) & 3) << 3) | ((get_byte(bytes, 15) & 224) >> 5)));
  output = output || chr(get_byte(alphabet, (get_byte(bytes, 15) & 31)));

  RETURN output;
END
$$;

COMMENT ON FUNCTION common.base32_encode(uuid) IS
'Encodes a UUID as the 26-character Crockford base32 suffix of a TypeID.';

-- Decoding raises on malformed input, unlike the check below: a caller that
-- decodes has already decided the text is a TypeID suffix and wants the UUID,
-- and a NULL would hide the bad value. The raises are PostgreSQL's
-- invalid_text_representation, the SQLSTATE a failed cast to uuid gives.
-- STABLE rather than jetify's IMMUTABLE: convert_to() is STABLE, since an
-- encoding conversion could in principle change. Nothing indexes on it.
CREATE OR REPLACE FUNCTION common.base32_decode(s text)
RETURNS uuid
LANGUAGE plpgsql
STABLE STRICT PARALLEL SAFE
SET search_path = common, pg_catalog
AS $$
DECLARE
  dec bytea = '\xFF FF FF FF FF FF FF FF FF FF'::bytea ||
              '\xFF FF FF FF FF FF FF FF FF FF'::bytea ||
              '\xFF FF FF FF FF FF FF FF FF FF'::bytea ||
              '\xFF FF FF FF FF FF FF FF FF FF'::bytea ||
              '\xFF FF FF FF FF FF FF FF 00 01'::bytea ||
              '\x02 03 04 05 06 07 08 09 FF FF'::bytea ||
              '\xFF FF FF FF FF FF FF FF FF FF'::bytea ||
              '\xFF FF FF FF FF FF FF FF FF FF'::bytea ||
              '\xFF FF FF FF FF FF FF FF FF FF'::bytea ||
              '\xFF FF FF FF FF FF FF 0A 0B 0C'::bytea ||
              '\x0D 0E 0F 10 11 FF 12 13 FF 14'::bytea ||
              '\x15 FF 16 17 18 19 1A FF 1B 1C'::bytea ||
              '\x1D 1E 1F FF FF FF FF FF FF FF'::bytea ||
              '\xFF FF FF FF FF FF FF FF FF FF'::bytea ||
              '\xFF FF FF FF FF FF FF FF FF FF'::bytea ||
              '\xFF FF FF FF FF FF FF FF FF FF'::bytea ||
              '\xFF FF FF FF FF FF FF FF FF FF'::bytea ||
              '\xFF FF FF FF FF FF FF FF FF FF'::bytea ||
              '\xFF FF FF FF FF FF FF FF FF FF'::bytea ||
              '\xFF FF FF FF FF FF FF FF FF FF'::bytea ||
              '\xFF FF FF FF FF FF FF FF FF FF'::bytea ||
              '\xFF FF FF FF FF FF FF FF FF FF'::bytea ||
              '\xFF FF FF FF FF FF FF FF FF FF'::bytea ||
              '\xFF FF FF FF FF FF FF FF FF FF'::bytea ||
              '\xFF FF FF FF FF FF FF FF FF FF'::bytea ||
              '\xFF FF FF FF FF FF'::bytea;
  v bytea = convert_to(s, 'UTF8');
  id bytea = '\x00000000000000000000000000000000';
BEGIN
  -- The byte-length test also stops a multi-byte character from indexing past
  -- the 256-entry table, which get_byte would report as an out-of-range error.
  IF length(s) <> 26 OR octet_length(v) <> 26 THEN
    RAISE EXCEPTION 'typeid suffix must be 26 characters' USING ERRCODE = 'invalid_text_representation';
  END IF;

  IF get_byte(dec, get_byte(v, 0)) = 255 or
     get_byte(dec, get_byte(v, 1)) = 255 or
     get_byte(dec, get_byte(v, 2)) = 255 or
     get_byte(dec, get_byte(v, 3)) = 255 or
     get_byte(dec, get_byte(v, 4)) = 255 or
     get_byte(dec, get_byte(v, 5)) = 255 or
     get_byte(dec, get_byte(v, 6)) = 255 or
     get_byte(dec, get_byte(v, 7)) = 255 or
     get_byte(dec, get_byte(v, 8)) = 255 or
     get_byte(dec, get_byte(v, 9)) = 255 or
     get_byte(dec, get_byte(v, 10)) = 255 or
     get_byte(dec, get_byte(v, 11)) = 255 or
     get_byte(dec, get_byte(v, 12)) = 255 or
     get_byte(dec, get_byte(v, 13)) = 255 or
     get_byte(dec, get_byte(v, 14)) = 255 or
     get_byte(dec, get_byte(v, 15)) = 255 or
     get_byte(dec, get_byte(v, 16)) = 255 or
     get_byte(dec, get_byte(v, 17)) = 255 or
     get_byte(dec, get_byte(v, 18)) = 255 or
     get_byte(dec, get_byte(v, 19)) = 255 or
     get_byte(dec, get_byte(v, 20)) = 255 or
     get_byte(dec, get_byte(v, 21)) = 255 or
     get_byte(dec, get_byte(v, 22)) = 255 or
     get_byte(dec, get_byte(v, 23)) = 255 or
     get_byte(dec, get_byte(v, 24)) = 255 or
     get_byte(dec, get_byte(v, 25)) = 255
  THEN
    RAISE EXCEPTION 'typeid suffix must only use characters from the base32 alphabet' USING ERRCODE = 'invalid_text_representation';
  END IF;

  IF chr(get_byte(v, 0)) > '7' THEN
    RAISE EXCEPTION 'typeid suffix must start with 0-7' USING ERRCODE = 'invalid_text_representation';
  END IF;
  -- Transform base32 to binary array
  -- 6 bytes timestamp (48 bits)
  id = set_byte(id, 0, (get_byte(dec, get_byte(v, 0)) << 5) | get_byte(dec, get_byte(v, 1)));
  id = set_byte(id, 1, (get_byte(dec, get_byte(v, 2)) << 3) | (get_byte(dec, get_byte(v, 3)) >> 2));
  id = set_byte(id, 2, ((get_byte(dec, get_byte(v, 3)) & 3) << 6) | (get_byte(dec, get_byte(v, 4)) << 1) | (get_byte(dec, get_byte(v, 5)) >> 4));
  id = set_byte(id, 3, ((get_byte(dec, get_byte(v, 5)) & 15) << 4) | (get_byte(dec, get_byte(v, 6)) >> 1));
  id = set_byte(id, 4, ((get_byte(dec, get_byte(v, 6)) & 1) << 7) | (get_byte(dec, get_byte(v, 7)) << 2) | (get_byte(dec, get_byte(v, 8)) >> 3));
  id = set_byte(id, 5, ((get_byte(dec, get_byte(v, 8)) & 7) << 5) | get_byte(dec, get_byte(v, 9)));

  -- 10 bytes of entropy (80 bits)
  id = set_byte(id, 6, (get_byte(dec, get_byte(v, 10)) << 3) | (get_byte(dec, get_byte(v, 11)) >> 2));
  id = set_byte(id, 7, ((get_byte(dec, get_byte(v, 11)) & 3) << 6) | (get_byte(dec, get_byte(v, 12)) << 1) | (get_byte(dec, get_byte(v, 13)) >> 4));
  id = set_byte(id, 8, ((get_byte(dec, get_byte(v, 13)) & 15) << 4) | (get_byte(dec, get_byte(v, 14)) >> 1));
  id = set_byte(id, 9, ((get_byte(dec, get_byte(v, 14)) & 1) << 7) | (get_byte(dec, get_byte(v, 15)) << 2) | (get_byte(dec, get_byte(v, 16)) >> 3));
  id = set_byte(id, 10, ((get_byte(dec, get_byte(v, 16)) & 7) << 5) | get_byte(dec, get_byte(v, 17)));
  id = set_byte(id, 11, (get_byte(dec, get_byte(v, 18)) << 3) | (get_byte(dec, get_byte(v, 19)) >> 2));
  id = set_byte(id, 12, ((get_byte(dec, get_byte(v, 19)) & 3) << 6) | (get_byte(dec, get_byte(v, 20)) << 1) | (get_byte(dec, get_byte(v, 21)) >> 4));
  id = set_byte(id, 13, ((get_byte(dec, get_byte(v, 21)) & 15) << 4) | (get_byte(dec, get_byte(v, 22)) >> 1));
  id = set_byte(id, 14, ((get_byte(dec, get_byte(v, 22)) & 1) << 7) | (get_byte(dec, get_byte(v, 23)) << 2) | (get_byte(dec, get_byte(v, 24)) >> 3));
  id = set_byte(id, 15, ((get_byte(dec, get_byte(v, 24)) & 7) << 5) | get_byte(dec, get_byte(v, 25)));
  RETURN encode(id, 'hex')::uuid;
END
$$;

COMMENT ON FUNCTION common.base32_decode(text) IS
'Decodes a 26-character TypeID suffix back into its UUID. Raises invalid_text_representation (22P02) on a malformed suffix.';

-- -----------------------------------------------------
-- common.typeid_check_text(text)
-- -----------------------------------------------------
-- TRUE when the text is a well-formed TypeID: an optional prefix of up to 63
-- lowercase letters and underscores that starts and ends with a letter, an
-- underscore separating it, and a 26-character base32 suffix whose first
-- character is 0-7 (the spec's two padding bits must be zero, or the suffix
-- would not fit 128 bits). That is exactly what jetify's parser accepts, as
-- one regular expression.
--
-- It never raises, so a malformed value fails the common.typeid domain's
-- named CHECK constraint (23514 typeid_format) rather than surfacing whatever
-- the parser happened to throw, and it is IMMUTABLE, which a domain CHECK
-- requires to be trustworthy. NULL in, NULL out: a domain CHECK passes NULL,
-- and nullability belongs to the column.
CREATE OR REPLACE FUNCTION common.typeid_check_text(typeid_str text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE STRICT PARALLEL SAFE
SET search_path = common, pg_catalog
AS $$
    SELECT typeid_str ~ '^([a-z]([a-z_]{0,61}[a-z])?_)?[0-7][0-9abcdefghjkmnpqrstvwxyz]{25}$'
$$;

COMMENT ON FUNCTION common.typeid_check_text(text) IS
'TRUE when the text is a well-formed TypeID (optional prefix, underscore, 26-character base32 suffix starting 0-7). Never raises; the check behind the common.typeid domain.';

-- -----------------------------------------------------
-- common.typeid_prefix(text)
-- -----------------------------------------------------
-- The prefix of a TypeID, '' when it has none. The suffix alphabet has no
-- underscore, so the prefix is everything before the last one. Meaningful only
-- for text that passes typeid_check_text.
CREATE OR REPLACE FUNCTION common.typeid_prefix(typeid_str text)
RETURNS text
LANGUAGE sql
IMMUTABLE STRICT PARALLEL SAFE
SET search_path = common, pg_catalog
AS $$
    SELECT coalesce(substring(typeid_str FROM '^(.*)_[^_]*$'), '')
$$;

COMMENT ON FUNCTION common.typeid_prefix(text) IS
'Returns the prefix of a TypeID, or an empty string when it has none.';

-- -----------------------------------------------------
-- common.typeid_generate_text(prefix)
-- -----------------------------------------------------
-- A new TypeID with the given prefix: prefix, underscore, base32 of a fresh
-- UUIDv7. An empty prefix gives the bare suffix, as the spec defines. The
-- prefix is validated because it is concatenated into the value: an
-- entity's prefix is already held to this shape by the entities CHECK, so a
-- failure here means a caller outside the dictionary passed a bad one.
CREATE OR REPLACE FUNCTION common.typeid_generate_text(prefix text)
RETURNS text
LANGUAGE plpgsql
VOLATILE PARALLEL SAFE
SET search_path = common, pg_catalog
AS $$
BEGIN
  IF (prefix IS NULL) OR NOT (prefix ~ '^([a-z]([a-z_]{0,61}[a-z])?)?$') THEN
    RAISE EXCEPTION 'typeid prefix must match the regular expression ^([a-z]([a-z_]{0,61}[a-z])?)?$'
        USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF prefix = '' THEN
    RETURN common.base32_encode(common.uuid_v7());
  END IF;
  RETURN prefix || '_' || common.base32_encode(common.uuid_v7());
END
$$;

COMMENT ON FUNCTION common.typeid_generate_text(text) IS
'Generates a new TypeID with the given prefix from a fresh UUIDv7. Raises invalid_parameter_value (22023) for a prefix outside the TypeID spec.';

-- -----------------------------------------------------
-- common.typeid_assign()  - BEFORE INSERT trigger of typeid entity tables
-- -----------------------------------------------------
-- TG_ARGV[0] is the key column, TG_ARGV[1] the entity's current prefix. A row
-- without an id gets a generated one; a row that brings its own id must carry
-- the current prefix. Only the prefix is checked here: the column's
-- common.typeid domain already holds the value to the TypeID format, and it
-- would reject a malformed id whatever this trigger did.
--
-- The prefix travels as a trigger argument, not as a lookup in entities, so
-- the check costs no query per row; changing an entity's prefix recreates the
-- trigger (dd_sync_typeid_prefix in 0160_dd_functions.sql). Only inserts are
-- checked: a key can never be updated (common.reject_pk_change), so a row that
-- was valid when it was written stays valid, and rows written under an earlier
-- prefix keep their ids.
--
-- The column is read and written through jsonb because PL/pgSQL cannot address
-- a record field whose name is only known at run time.
CREATE OR REPLACE FUNCTION common.typeid_assign()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = common, pg_catalog
AS $$
DECLARE
    v_column TEXT := TG_ARGV[0];
    v_prefix TEXT := TG_ARGV[1];
    v_id     TEXT := to_jsonb(NEW) ->> TG_ARGV[0];
BEGIN
    IF v_id IS NULL THEN
        NEW := jsonb_populate_record(NEW, jsonb_build_object(v_column, common.typeid_generate_text(v_prefix)));
    ELSIF common.typeid_prefix(v_id) IS DISTINCT FROM v_prefix THEN
        RAISE EXCEPTION 'Id ${id} does not carry the prefix ${prefix} of ${table}'
            USING ERRCODE = '90237',
                  HINT = jsonb_build_object('id', v_id, 'prefix', v_prefix, 'table', TG_TABLE_NAME)::text;
    END IF;
    RETURN NEW;
END
$$;

COMMENT ON FUNCTION common.typeid_assign() IS
'BEFORE INSERT trigger of a typeid entity table (TG_ARGV: key column, current prefix). Generates the id when none is supplied and rejects a supplied id without the current prefix (90237).';

-- -----------------------------------------------------
-- common.reject_pk_change()  - BEFORE UPDATE OF <key> trigger
-- -----------------------------------------------------
-- TG_ARGV[0] is the key column. A record's key is set once: foreign keys,
-- bookmarks, audit rows, exported files and URLs all hold it, and ON UPDATE
-- CASCADE would only repair the first of those. The comparison is IS DISTINCT
-- FROM, not "the column was in the SET list", because a client that PATCHes a
-- whole record sends its unchanged id back and must not be refused for it.
-- Installed on every dictionary-created table and on users, modules, roles and
-- _apikeys; not on entities and permissions, whose natural keys are renamable,
-- nor on the junction tables, whose generated keys follow their key columns.
CREATE OR REPLACE FUNCTION common.reject_pk_change()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = common, pg_catalog
AS $$
BEGIN
    IF (to_jsonb(NEW) -> TG_ARGV[0]) IS DISTINCT FROM (to_jsonb(OLD) -> TG_ARGV[0]) THEN
        RAISE EXCEPTION 'The key ${column} of ${table} cannot be changed'
            USING ERRCODE = '90236',
                  HINT = jsonb_build_object('column', TG_ARGV[0], 'table', TG_TABLE_NAME)::text;
    END IF;
    RETURN NEW;
END
$$;

COMMENT ON FUNCTION common.reject_pk_change() IS
'BEFORE UPDATE OF <key> trigger (TG_ARGV: key column): refuses a change of a record key with 90236. An update that writes the unchanged key back passes.';

REVOKE EXECUTE ON FUNCTION common.uuid_v7() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION common.base32_encode(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION common.base32_decode(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION common.typeid_check_text(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION common.typeid_prefix(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION common.typeid_generate_text(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION common.typeid_assign() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION common.reject_pk_change() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION common.uuid_v7() TO semantius_user;
GRANT EXECUTE ON FUNCTION common.base32_encode(uuid) TO semantius_user;
GRANT EXECUTE ON FUNCTION common.base32_decode(text) TO semantius_user;
GRANT EXECUTE ON FUNCTION common.typeid_check_text(text) TO semantius_user;
GRANT EXECUTE ON FUNCTION common.typeid_prefix(text) TO semantius_user;
GRANT EXECUTE ON FUNCTION common.typeid_generate_text(text) TO semantius_user;
