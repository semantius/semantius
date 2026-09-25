-- Sweep every function the data dictionary generated for the entities this
-- deployment actually ships: _label, the <fk>_label companions, and the
-- single-argument select_rule overloads.
--
-- Why this exists next to 0370_test_composed_labels.sql, which already tests
-- labels thoroughly: 0370 builds its own entity shapes and ends in ROLLBACK,
-- like every pgTAP file here, so the functions it exercised no longer exist by
-- the time anything looks at the database again. Only the shipped entities'
-- generated functions survive, and none of their <fk>_label companions had ever
-- been called by anything. A generated function that fails to compile, or that
-- raises at runtime on a shape nobody wrote a fixture for - a junction, a
-- self-reference, a spine chain, an unmanaged audit table - would go unnoticed
-- until a client asked for that computed column in production.
--
-- The sweep reads pg_proc instead of deriving names from entities/fields. That
-- is deliberate: rebuild_entity_label_functions declines to emit a companion
-- under five separate conditions, one of them being that a real column already
-- owns the <fk>_label name. A test that rebuilt the expected set from the
-- dictionary would carry a second copy of those rules and would drift from the
-- generator the first time one of them changed. Asking the catalog what exists
-- cannot drift.
--
-- The smoke calls pass NULL rather than a row. The generated functions are not
-- STRICT, so a NULL argument still executes the body and still registers a call,
-- which makes the sweep independent of whether a shipped table happens to hold
-- rows. Selecting a row with LIMIT 1 would call nothing at all on an empty
-- table, and the sweep could decay to zero exercised functions without failing.
BEGIN;

SELECT plan(7);

-- Claims first, then back to the owner. Both halves are load-bearing. The
-- single-argument select_rule overload resolves jl_request_context() itself,
-- which raises "Authentication required" when no JWT claims are set, so a bare
-- RESET ROLE cannot call it at all. The owner is still the right identity to
-- run as: every generated function is REVOKEd from PUBLIC and granted only to
-- semantius_user, and the entity tables carry select_rule policies that would
-- reduce the value comparisons below to zero rows and pass vacuously.
-- authenticate_as sets the claims transaction-locally and switches role; only
-- the role is given back.
SELECT authenticate_as('user1');
RESET ROLE;

-- A row to compare against. The select_rule agreement below is a claim about
-- two functions returning the same verdict for the same record, which an empty
-- table turns into a claim about nothing.
INSERT INTO user_bookmarks (title, url)
VALUES ('Sweep Bookmark', 'https://example.com/sweep');

-- reltype joins the argument type back to its table so the relation name comes
-- from pg_class rather than from parsing a formatted signature.
CREATE TEMP TABLE _gen_fns ON COMMIT DROP AS
SELECT p.oid          AS fn_oid,
       p.proname      AS fn_name,
       c.relname      AS row_type,
       CASE WHEN p.proname LIKE 'select\_rule\_%' THEN 'select_rule'
            WHEN p.proname = '_label'             THEN 'label'
            ELSE                                       'fk_label'
       END            AS kind
FROM pg_catalog.pg_proc p
JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
JOIN pg_catalog.pg_class c     ON c.reltype = p.proargtypes[0]
WHERE n.nspname = 'public'
  AND p.pronargs = 1
  AND (   (p.proname LIKE '%\_label'        AND p.proargnames = ARRAY['rec'])
       OR (p.proname LIKE 'select\_rule\_%' AND p.proargnames = ARRAY['p_row']));

CREATE TEMP TABLE _sweep_errors (fn text, detail text) ON COMMIT DROP;
CREATE TEMP TABLE _sweep_called (fn_oid oid) ON COMMIT DROP;

-- Test 1 and 2: the catalog query must match something, and it must match the
-- companions specifically. A sweep whose pattern silently stops matching is
-- indistinguishable from a sweep that passes, so the shape is asserted first.
SELECT cmp_ok((SELECT count(*)::int FROM _gen_fns), '>', 0,
    'the generated-function sweep should find generated functions to call');

SELECT cmp_ok((SELECT count(*)::int FROM _gen_fns WHERE kind = 'fk_label'), '>', 0,
    'the sweep should find <fk>_label companions, the group nothing else calls');

-- Each call is its own subtransaction so one broken generated function reports
-- as a named failure instead of aborting the file.
DO $sweep$
DECLARE
    r RECORD;
BEGIN
    FOR r IN SELECT * FROM _gen_fns LOOP
        BEGIN
            EXECUTE format('SELECT public.%I(NULL::public.%I)', r.fn_name, r.row_type);
            INSERT INTO _sweep_called VALUES (r.fn_oid);
        EXCEPTION WHEN OTHERS THEN
            INSERT INTO _sweep_errors
            VALUES (format('%s(%s)', r.fn_name, r.row_type), SQLERRM);
        END;
    END LOOP;
END
$sweep$;

-- Test 3: string_agg over an empty table is NULL, so a passing run says nothing
-- and a failing one names the function and the error instead of a bare count.
SELECT is((SELECT string_agg(fn || ': ' || detail, '; ' ORDER BY fn) FROM _sweep_errors), NULL,
    'every generated function should execute without raising');

-- Test 4: what makes this a measurement rather than a loop that ran.
SELECT is((SELECT count(*)::int FROM _sweep_called),
          (SELECT count(*)::int FROM _gen_fns),
    'every generated function found should have been called');

-- <fk>_label(child) is generated as the parent's composed label, looked up by
-- the parent entity's id_column - which is not always "id": entities itself is
-- keyed on table_name. Resolving it the same way here proves the generator
-- emitted the right body rather than merely a body that runs.
CREATE TEMP TABLE _fk_mismatch (fn text, detail text) ON COMMIT DROP;

DO $fk$
DECLARE
    r           RECORD;
    v_field     text;
    v_parent    text;
    v_parent_id text;
    v_bad       bigint;
BEGIN
    FOR r IN SELECT * FROM _gen_fns WHERE kind = 'fk_label' LOOP
        v_field := left(r.fn_name, length(r.fn_name) - length('_label'));
        SELECT f.reference_table INTO v_parent
          FROM fields f
         WHERE f.table_name = r.row_type AND f.field_name = v_field;
        CONTINUE WHEN v_parent IS NULL OR v_parent = '';
        SELECT e.id_column INTO v_parent_id FROM entities e WHERE e.table_name = v_parent;
        CONTINUE WHEN v_parent_id IS NULL;
        EXECUTE format(
            'SELECT count(*) FROM public.%I c JOIN public.%I p ON p.%I = c.%I '
            'WHERE public.%I(c) IS DISTINCT FROM public._label(p)',
            r.row_type, v_parent, v_parent_id, v_field, r.fn_name)
        INTO v_bad;
        IF v_bad > 0 THEN
            INSERT INTO _fk_mismatch VALUES (r.fn_name, v_bad || ' rows');
        END IF;
    END LOOP;
END
$fk$;

-- Test 5
SELECT is((SELECT string_agg(fn || ': ' || detail, '; ' ORDER BY fn) FROM _fk_mismatch), NULL,
    'every <fk>_label should equal the referenced record''s composed label');

-- The single-argument select_rule overload resolves jl_request_context() itself
-- and delegates to the two-argument form the RLS policies use. It is SECURITY
-- DEFINER and granted to semantius_user, so it is reachable by any request role
-- while nothing had ever executed it; the two forms must agree on every row.
CREATE TEMP TABLE _rule_mismatch (fn text, detail text) ON COMMIT DROP;

CREATE TEMP TABLE _rule_rows (n bigint) ON COMMIT DROP;

DO $rule$
DECLARE
    r     RECORD;
    v_bad bigint;
    v_all bigint;
BEGIN
    FOR r IN SELECT * FROM _gen_fns WHERE kind = 'select_rule' LOOP
        EXECUTE format(
            'SELECT count(*) FILTER ('
            '         WHERE public.%I(t) IS DISTINCT FROM public.%I(t, public.jl_request_context())'
            '       ), count(*) FROM public.%I t',
            r.fn_name, r.fn_name, r.row_type)
        INTO v_bad, v_all;
        INSERT INTO _rule_rows VALUES (v_all);
        IF v_bad > 0 THEN
            INSERT INTO _rule_mismatch VALUES (r.fn_name, v_bad || ' rows');
        END IF;
    END LOOP;
END
$rule$;

-- Test 6
SELECT is((SELECT string_agg(fn || ': ' || detail, '; ' ORDER BY fn) FROM _rule_mismatch), NULL,
    'the 1-arg select_rule overload should agree with the explicit-context form');

-- Test 7: the agreement above is only evidence if it saw a record.
SELECT cmp_ok((SELECT COALESCE(sum(n), 0)::int FROM _rule_rows), '>', 0,
    'the select_rule overload comparison should cover at least one row');

SELECT * FROM finish();
ROLLBACK;
