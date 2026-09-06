-- Test composed record labels: label_parent + _label / <fk>_label
-- Covers §6 composition, §6 fallback/degrade, §7 security (viewer-relative, no leak),
-- §6 currency, junctions, §5.4 discovery, §9 name reservation, §10 validation.
BEGIN;

SELECT plan(35);

-- =====================================================
-- SETUP: build a candidate -> application -> interview -> scorecard identity chain
-- (spines are nullable 'reference' FKs with ON DELETE clear so null/degrade/delete cases work),
-- plus a heuristic junction (two parent legs to candidates). Done as admin (user3).
-- =====================================================
SELECT authenticate_as('user3');

-- lt_candidates: root, intrinsic label. view='admin' so user1 cannot read it (security tests).
INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES ('lt_candidates', 'lt_candidate', 'Candidate', 'Candidates', 'test candidates', 1, 'admin', 'admin', 'id', 'full_name');

-- lt_applications: relational, spine = candidate_id. view public so user1 can read the child.
INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES ('lt_applications', 'lt_application', 'Application', 'Applications', 'test applications', 1, 'public:read', 'admin', 'id', 'job_title');
INSERT INTO fields (table_name, field_name, title, format, field_order, reference_table, reference_delete_mode)
VALUES ('lt_applications', 'candidate_id', 'Candidate', 'reference', 20, 'lt_candidates', 'clear');
UPDATE entities SET label_parent = 'candidate_id' WHERE table_name = 'lt_applications';

-- lt_interviews: relational, spine = application_id.
INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES ('lt_interviews', 'lt_interview', 'Interview', 'Interviews', 'test interviews', 1, 'public:read', 'admin', 'id', 'stage');
INSERT INTO fields (table_name, field_name, title, format, field_order, reference_table, reference_delete_mode)
VALUES ('lt_interviews', 'application_id', 'Application', 'reference', 20, 'lt_applications', 'clear');
UPDATE entities SET label_parent = 'application_id' WHERE table_name = 'lt_interviews';

-- lt_scorecards: relational, spine = interview_id (the original "Scorecard 6" problem).
INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES ('lt_scorecards', 'lt_scorecard', 'Scorecard', 'Scorecards', 'test scorecards', 1, 'public:read', 'admin', 'id', 'score_date');
INSERT INTO fields (table_name, field_name, title, format, field_order, reference_table, reference_delete_mode)
VALUES ('lt_scorecards', 'interview_id', 'Interview', 'reference', 20, 'lt_interviews', 'clear');
UPDATE entities SET label_parent = 'interview_id' WHERE table_name = 'lt_scorecards';

-- lt_link: heuristic junction (two parent legs to candidates, no payload field).
INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES ('lt_link', 'lt_link', 'Link', 'Links', 'test junction', 1, 'public:read', 'admin', 'id', 'label');
INSERT INTO fields (table_name, field_name, title, format, field_order, reference_table, reference_delete_mode)
VALUES ('lt_link', 'left_id', 'Left', 'parent', 20, 'lt_candidates', 'cascade'),
       ('lt_link', 'right_id', 'Right', 'parent', 30, 'lt_candidates', 'cascade');

-- Data
INSERT INTO lt_candidates (full_name) VALUES ('Chen Wei'), ('Jane Roe'), ('Temp Cand');
INSERT INTO lt_applications (job_title, candidate_id)
VALUES ('Sr Backend Engineer', (SELECT id FROM lt_candidates WHERE full_name = 'Chen Wei'));
INSERT INTO lt_interviews (stage, application_id)
VALUES ('phone screen', (SELECT id FROM lt_applications WHERE job_title = 'Sr Backend Engineer'));
INSERT INTO lt_scorecards (score_date, interview_id)
VALUES ('2026-06-13', (SELECT id FROM lt_interviews WHERE stage = 'phone screen'));
-- app2: null spine (A5); app3: empty local + spine set (A7); app4 on Temp Cand (D3 delete)
INSERT INTO lt_applications (job_title, candidate_id) VALUES ('Solo App', NULL);
INSERT INTO lt_applications (job_title, candidate_id)
VALUES ('', (SELECT id FROM lt_candidates WHERE full_name = 'Chen Wei'));
INSERT INTO lt_applications (job_title, candidate_id)
VALUES ('Temp App', (SELECT id FROM lt_candidates WHERE full_name = 'Temp Cand'));
-- junction row pairing Chen Wei (left) and Jane Roe (right)
INSERT INTO lt_link (label, left_id, right_id)
VALUES ('pair',
        (SELECT id FROM lt_candidates WHERE full_name = 'Chen Wei'),
        (SELECT id FROM lt_candidates WHERE full_name = 'Jane Roe'));

-- =====================================================
-- A. Composition (as admin / full visibility)
-- =====================================================
SELECT is(
    (SELECT public._label(c) FROM lt_candidates c WHERE c.full_name = 'Chen Wei'),
    'Chen Wei',
    'A1: root entity _label is the local label');

SELECT is(
    (SELECT public._label(a) FROM lt_applications a WHERE a.job_title = 'Sr Backend Engineer'),
    'Chen Wei › Sr Backend Engineer',
    'A2: relational _label folds parent._label › local');

SELECT is(
    (SELECT public._label(s) FROM lt_scorecards s WHERE s.score_date = '2026-06-13'),
    'Chen Wei › Sr Backend Engineer › phone screen › 2026-06-13',
    'A4: depth-3 chain folds the candidate into the scorecard label');

SELECT is(
    (SELECT public.interview_id_label(s) FROM lt_scorecards s WHERE s.score_date = '2026-06-13'),
    'Chen Wei › Sr Backend Engineer › phone screen',
    'B1: <fk>_label companion equals the parent composed label');

SELECT is(
    (SELECT public._label(a) FROM lt_applications a WHERE a.job_title = 'Solo App'),
    'Solo App',
    'A5: null spine degrades to local label (no leading separator)');

SELECT is(
    (SELECT public._label(a) FROM lt_applications a WHERE a.candidate_id IS NOT NULL AND a.job_title = ''),
    'Chen Wei',
    'A7: empty local + spine set yields parent chain only (no trailing separator)');

SELECT ok(
    (SELECT public.candidate_id_label(a) FROM lt_applications a WHERE a.job_title = 'Solo App') IS NULL,
    'B3: companion of a null FK is null');

-- =====================================================
-- J. Junction (as admin)
-- =====================================================
SELECT is(
    (SELECT public._label(l) FROM lt_link l WHERE l.label = 'pair'),
    'Chen Wei › Jane Roe',
    'J1/J2: junction _label combines its parent legs (no local term)');

-- =====================================================
-- D. Currency (no write to descendants)
-- =====================================================
UPDATE lt_candidates SET full_name = 'Chen Wei Updated' WHERE full_name = 'Chen Wei';
SELECT is(
    (SELECT public._label(a) FROM lt_applications a WHERE a.job_title = 'Sr Backend Engineer'),
    'Chen Wei Updated › Sr Backend Engineer',
    'D1: renaming an ancestor is reflected on next read, no descendant write');

UPDATE lt_applications SET candidate_id = (SELECT id FROM lt_candidates WHERE full_name = 'Jane Roe')
WHERE job_title = 'Solo App';
SELECT is(
    (SELECT public._label(a) FROM lt_applications a WHERE a.job_title = 'Solo App'),
    'Jane Roe › Solo App',
    'D2: re-pointing the spine FK changes _label immediately');

DELETE FROM lt_candidates WHERE full_name = 'Temp Cand';
SELECT is(
    (SELECT public._label(a) FROM lt_applications a WHERE a.job_title = 'Temp App'),
    'Temp App',
    'D3: deleting the parent (ON DELETE clear) degrades to local');

-- =====================================================
-- H. Discovery via get_schema (§5.4) — derived label columns are ORDINARY properties,
-- discriminated only by ctype (_label / fk_label); there is no separate list.
-- =====================================================
SELECT is(
    (public.get_schema('lt_applications')::jsonb)->'properties'->'_label'->>'ctype',
    '_label',
    'H1: _label is a property, discriminated by ctype "_label"');

SELECT is(
    (public.get_schema('lt_applications')::jsonb)->'properties'->'_label'->>'source',
    'candidate_id',
    'H9: _label property source reflects the spine FK (label_parent)');

SELECT is(
    (public.get_schema('lt_applications')::jsonb)->'properties'->'candidate_id_label'->>'ctype',
    'fk_label',
    'H4: <fk>_label companion is a property with ctype "fk_label"');

SELECT is(
    (public.get_schema('lt_applications')::jsonb)->'properties'->'candidate_id_label'->>'reference_table',
    'lt_candidates',
    'H4: <fk>_label companion property names its referenced table');

SELECT ok(
    NOT ((public.get_schema('lt_applications')::jsonb) ? 'label_columns'),
    'no separate label_columns list — derived columns live in properties');

-- =====================================================
-- F. Name reservation (§9) and label_parent validation (§10) — still admin
-- =====================================================
SELECT throws_ok(
    $$INSERT INTO fields (table_name, field_name, title, format) VALUES ('lt_scorecards', '_secret', 'X', 'text')$$,
    '23514', NULL,
    'F1: field name starting with "_" is rejected');

-- The "_label" SUFFIX is NOT reserved: denormalized display columns like customer_label are common.
SELECT lives_ok(
    $$INSERT INTO fields (table_name, field_name, title, format) VALUES ('lt_scorecards', 'customer_label', 'X', 'text')$$,
    'F2: a field name ending in "_label" is allowed (suffix is not reserved)');

SELECT lives_ok(
    $$INSERT INTO fields (table_name, field_name, title, format) VALUES ('lt_scorecards', 'extra_note', 'Note', 'text')$$,
    'F3: an ordinary field name is allowed');

-- Collision-aware: a REAL column that owns a <fk>_label name wins over the generated companion.
-- lt_scorecards has the FK interview_id (companion interview_id_label); add a real interview_id_label.
INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('lt_scorecards', 'interview_id_label', 'Authored Label', 'text', 80);
SELECT ok(
    ((public.get_schema('lt_scorecards')::jsonb)->'properties' ? 'interview_id_label')
    AND COALESCE((public.get_schema('lt_scorecards')::jsonb)->'properties'->'interview_id_label'->>'ctype','') <> 'fk_label',
    'collision: the authored interview_id_label is a normal property, not a generated fk_label companion');
SELECT is(
    (SELECT s.interview_id_label FROM lt_scorecards s WHERE s.score_date = '2026-06-13'),
    '',
    'collision: the real column wins (returns its own value, not the composed label)');

SELECT throws_ok(
    $$UPDATE entities SET label_parent = 'score_date' WHERE table_name = 'lt_scorecards'$$,
    '23514', NULL,
    'F6: label_parent naming a non-FK field is rejected');

SELECT throws_ok(
    $$UPDATE entities SET label_parent = 'no_such_field' WHERE table_name = 'lt_scorecards'$$,
    '23514', NULL,
    'F7: label_parent naming a non-existent field is rejected');

-- self-reference (§2): a spine FK pointing at its own entity is rejected
INSERT INTO fields (table_name, field_name, title, format, field_order, reference_table, reference_delete_mode)
VALUES ('lt_candidates', 'self_ref', 'Self', 'reference', 50, 'lt_candidates', 'clear');
SELECT throws_ok(
    $$UPDATE entities SET label_parent = 'self_ref' WHERE table_name = 'lt_candidates'$$,
    '23514', NULL,
    'F8a: self-referential label_parent is rejected');

-- cycle (§10): candidates -> applications -> candidates
INSERT INTO fields (table_name, field_name, title, format, field_order, reference_table, reference_delete_mode)
VALUES ('lt_candidates', 'app_ref', 'App', 'reference', 60, 'lt_applications', 'clear');
SELECT throws_ok(
    $$UPDATE entities SET label_parent = 'app_ref' WHERE table_name = 'lt_candidates'$$,
    '23514', NULL,
    'F8b: a label_parent edit forming a cycle is rejected');

-- label_parent targeting a junction (F10) and set on a junction (F11)
INSERT INTO fields (table_name, field_name, title, format, field_order, reference_table, reference_delete_mode)
VALUES ('lt_scorecards', 'link_ref', 'Link', 'reference', 70, 'lt_link', 'clear');
SELECT throws_ok(
    $$UPDATE entities SET label_parent = 'link_ref' WHERE table_name = 'lt_scorecards'$$,
    '23514', NULL,
    'F10: label_parent targeting a junction is rejected');

SELECT throws_ok(
    $$UPDATE entities SET label_parent = 'left_id' WHERE table_name = 'lt_link'$$,
    '23514', NULL,
    'F11: label_parent set on a junction entity is rejected');

-- =====================================================
-- K. The label rebuild is skipped for a field that cannot change a body
-- =====================================================
-- rebuild_entity_label_functions drops and recreates _label plus one function
-- per reference field, and every one of those is a DDL event. Most fields
-- cannot change any of those bodies, so dd_label_fn_sync_field() skips the
-- rebuild for them on INSERT. Skipping one that WAS needed fails silently - a
-- stale <fk>_label keeps answering with the old body - so each case below
-- checks the identity of the generated function, not just its output: a
-- rebuild drops and recreates, so the OID moves.
--
-- Two of the gate's five branches are not separate tests here. label_parent:
-- validate_label_parent only accepts a reference/parent field as a spine, so
-- inserting one is already the reference case. label_column: the data
-- dictionary creates the label field together with the entity and refuses to
-- delete it afterwards, so that branch fires on every entity creation - every
-- composition assertion above depends on it.
SELECT authenticate_as('user3');

INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id, view_permission, edit_permission, id_column, label_column)
VALUES ('lt_gate', 'lt_gate', 'Gate', 'Gates', 'label rebuild gate probe', 1, 'public:read', 'admin', 'id', 'label');
INSERT INTO lt_gate (label) VALUES ('gate one');

CREATE TEMP TABLE lt_oid(tag text, oid oid);
INSERT INTO lt_oid VALUES ('start', to_regprocedure('public._label(public.lt_gate)')::oid);

-- A plain scalar field: no body reads it, so no rebuild.
INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('lt_gate', 'note', 'Note', 'string', 30);

SELECT is(
    to_regprocedure('public._label(public.lt_gate)')::oid,
    (SELECT oid FROM lt_oid WHERE tag = 'start'),
    'K1: a plain scalar field does not rebuild the label functions');

SELECT is(
    (SELECT public._label(g) FROM lt_gate g WHERE g.label = 'gate one'),
    'gate one',
    'K1: and the composed label still answers');

-- A reference field adds an <fk>_label companion, so it must rebuild.
INSERT INTO fields (table_name, field_name, title, format, field_order, reference_table, reference_delete_mode)
VALUES ('lt_gate', 'cand_id', 'Candidate', 'reference', 40, 'lt_candidates', 'clear');

SELECT isnt(
    to_regprocedure('public._label(public.lt_gate)')::oid,
    (SELECT oid FROM lt_oid WHERE tag = 'start'),
    'K2: a reference field rebuilds, and its cand_id_label companion exists: '
        || COALESCE(to_regprocedure('public.cand_id_label(public.lt_gate)')::text, 'MISSING'));

-- A junction is recognized by a heuristic that reads EVERY field, so one plain
-- payload field flips the _label body from the combined parent legs to the
-- local term. lt_link has two parent legs.
INSERT INTO lt_oid VALUES ('link', to_regprocedure('public._label(public.lt_link)')::oid);
INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('lt_link', 'note', 'Note', 'string', 40);

SELECT isnt(
    to_regprocedure('public._label(public.lt_link)')::oid,
    (SELECT oid FROM lt_oid WHERE tag = 'link'),
    'K3: a plain field on an entity with two parent legs rebuilds');

-- A field whose name collides with an <fk>_label companion: a real column wins,
-- so the function it would shadow has to go.
INSERT INTO fields (table_name, field_name, title, format, field_order)
VALUES ('lt_gate', 'cand_id_label', 'Candidate Label', 'string', 50);

SELECT is(
    to_regprocedure('public.cand_id_label(public.lt_gate)')::text,
    NULL,
    'K4: a field colliding with an <fk>_label companion rebuilds and drops it');

-- =====================================================
-- C/J. Security: viewer-relative labels, no parent leak (as user1, who lacks 'admin')
-- user1 can read lt_applications (public:read) but NOT lt_candidates (admin).
-- =====================================================
SELECT authenticate_as('user1');

SELECT is(
    (SELECT public._label(a) FROM lt_applications a WHERE a.job_title = 'Sr Backend Engineer'),
    'Sr Backend Engineer',
    'C2: caller who cannot read the parent sees _label degraded to local');

SELECT ok(
    (SELECT public._label(a) FROM lt_applications a WHERE a.job_title = 'Sr Backend Engineer') NOT LIKE '%Chen Wei%',
    'C2: hidden parent label never leaks through _label');

SELECT ok(
    COALESCE((SELECT public._label(l) FROM lt_link l WHERE l.label = 'pair'), '') NOT LIKE '%Chen Wei%',
    'J3: junction with hidden legs leaks nothing');

SELECT * FROM finish();
ROLLBACK;
