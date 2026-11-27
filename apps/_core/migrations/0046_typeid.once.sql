-- =====================================================
-- common.typeid AND common.typenumber DOMAINS
-- =====================================================
-- Runs once: a domain is a type. The check functions are in the repeatable
-- 0045_typeid.sql, which sorts before this file.
--
-- The key column of a typeid entity is declared with this domain, and
-- field_data_type() (0160_dd_functions.sql) copies a referenced key's declared
-- type, so every reference or parent column pointing at a typeid key gets the
-- same domain, collation and check without the dictionary knowing about it.
--
-- COLLATE "C": a Typed Id's suffix is base32 of a UUIDv7, so byte order is
-- creation order, and "C" makes the B-tree sort and compare it as bytes rather
-- than through the database's linguistic collation, which is slower and may
-- order '_' and letters differently. Declaring it on the domain rather than on
-- each column is what keeps a key and the foreign keys that point at it on the
-- same collation; a join between two collations raises instead of planning.
--
-- The CHECK is named so a client can translate the refusal: a violation
-- arrives as PostgreSQL's 23514 naming typeid_format.
CREATE DOMAIN common.typeid AS text COLLATE "C"
    CONSTRAINT typeid_format CHECK (common.typeid_check_text(VALUE));

COMMENT ON DOMAIN common.typeid IS
'A Typed Id, following the TypeID specification (https://github.com/jetify-com/typeid): optional lowercase prefix, underscore, 26-character base32 UUIDv7 suffix. Byte-ordered (COLLATE "C"). The key type of typeid entities and of the columns that reference them.';

-- USAGE on a type is granted to PUBLIC by default; stated here so the request
-- role's need is on record: it writes rows whose columns carry this domain.
GRANT USAGE ON DOMAIN common.typeid TO semantius_user;

-- The key type of typenumber entities, and of the columns that reference
-- them, for the same reasons: field_data_type() copies it to every reference,
-- and COLLATE "C" keeps a key and the foreign keys that point at it on one
-- collation. Byte order is not number order here (TASK-10 sorts before
-- TASK-9); the order of creation is created_at's. A violation arrives as
-- PostgreSQL's 23514 naming typenumber_format.
CREATE DOMAIN common.typenumber AS text COLLATE "C"
    CONSTRAINT typenumber_format CHECK (common.typenumber_check_text(VALUE));

COMMENT ON DOMAIN common.typenumber IS
'A Typed Number key such as TASK-125: an uppercase prefix of up to 10 letters and digits, starting with a letter, a hyphen, and a number of 1 to 18 digits. Byte-ordered (COLLATE "C"). The key type of typenumber entities and of the columns that reference them.';

GRANT USAGE ON DOMAIN common.typenumber TO semantius_user;
