-- Test (P1, release review 2026-09-02): every RLS policy predicate that calls
-- rbac.has_permission() or rbac.has_any_permission() must do so through a scalar sub-select,
--     USING ((SELECT rbac.has_permission('x')))
-- never the bare form
--     USING (rbac.has_permission('x'))
-- The bare form is a per-row Filter: PostgreSQL re-evaluates the call for every row scanned
-- (1.7 s on a 100k-row table). The sub-select form becomes an InitPlan that the executor runs
-- once per statement and then treats as a constant (about 10 ms). Same result, same session
-- context, evaluated at execution time either way.
--
-- Part 1 sweeps the installed catalog: no policy in any schema may contain a bare call.
-- Part 2 drives every policy generator on throwaway entities and re-checks, so an edit that
-- reintroduces `USING (rbac.has_permission(%L))` in a generator fails here even though the
-- install-time catalog stays clean:
--   create_dd_table            (0070, entity INSERT)
--   update_entity_policies     (0070, edit_permission UPDATE)
--   build_select_rule_policy   (0180, the permission-only branch and the rule branch)
--   enable_dd_table            (0145, managed FALSE -> TRUE)
-- enable_dd_table and update_entity_policies hand SELECT/UPDATE/DELETE to build_select_rule_policy,
-- so of their own emissions only the INSERT policy reaches the catalog; a bare form in one of the
-- shadowed emissions is dead code and is not detected here (verified by mutation on 2026-09-03).
--
-- Detection: pg_policies renders the sub-select form as
--     ( SELECT rbac.has_permission('x'::text) AS has_permission)
-- Strip every `SELECT rbac.has_...(` occurrence from qual and with_check; any `rbac.has_...(`
-- left over is a bare, per-row call. The positive assertions (count of InitPlan-form policies)
-- keep the sweep from passing vacuously on a table that lost its permission check altogether.
--
-- Fixtures: user3 = Administrator. No DDL is issued directly (the request role cannot).
BEGIN;

SELECT plan(12);

SELECT authenticate_as('user3');

-- ---------------------------------------------------------------------------
-- Part 1: the installed catalog (0050, 0060, 0150, 0280 and the nwind entities)
-- ---------------------------------------------------------------------------
SELECT is(
    (SELECT string_agg(schemaname || '.' || tablename || '.' || policyname, ', '
                       ORDER BY schemaname, tablename, policyname)
     FROM pg_policies
     WHERE regexp_replace(coalesce(qual, '') || ' ' || coalesce(with_check, ''),
                          'SELECT rbac\.has_(any_)?permission\(', '', 'g')
           ~ 'rbac\.has_(any_)?permission\('),
    NULL::text,
    'installed catalog: no policy calls rbac.has_permission() outside a sub-select');

-- ---------------------------------------------------------------------------
-- Part 2: the generators
-- ---------------------------------------------------------------------------

-- create_dd_table (entity INSERT, managed by default)
INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
    module_id, view_permission, edit_permission, id_column, label_column)
VALUES ('p1_initplan', 'p1_initplan_item', 'P1 InitPlan', 'P1 InitPlans',
    'policy form probe', 1, 'public:read', 'nwind:manage', 'id', 'label');

SELECT is(
    (SELECT string_agg(policyname || ': ' || coalesce(qual, '-') || ' / ' || coalesce(with_check, '-'), '; ')
     FROM pg_policies
     WHERE tablename = 'p1_initplan'
       AND regexp_replace(coalesce(qual, '') || ' ' || coalesce(with_check, ''),
                          'SELECT rbac\.has_(any_)?permission\(', '', 'g')
           ~ 'rbac\.has_(any_)?permission\('),
    NULL::text,
    'create_dd_table: no bare rbac.has_permission() in the generated policies');

SELECT is(
    (SELECT count(*)::int FROM pg_policies
     WHERE tablename = 'p1_initplan'
       AND (qual IS NULL OR qual ~ 'SELECT rbac\.has_permission\(')
       AND (with_check IS NULL OR with_check ~ 'SELECT rbac\.has_permission\(')),
    4,
    'create_dd_table: SELECT, INSERT, UPDATE and DELETE policies are all in the InitPlan form');

-- update_entity_policies (INSERT policy) + build_select_rule_policy, permission-only branch
-- (SELECT/UPDATE/DELETE), both fired by an edit_permission change
UPDATE entities SET edit_permission = 'admin' WHERE table_name = 'p1_initplan';

SELECT is(
    (SELECT string_agg(policyname || ': ' || coalesce(qual, '-') || ' / ' || coalesce(with_check, '-'), '; ')
     FROM pg_policies
     WHERE tablename = 'p1_initplan'
       AND regexp_replace(coalesce(qual, '') || ' ' || coalesce(with_check, ''),
                          'SELECT rbac\.has_(any_)?permission\(', '', 'g')
           ~ 'rbac\.has_(any_)?permission\('),
    NULL::text,
    'edit_permission change: no bare rbac.has_permission() in the rebuilt policies');

SELECT is(
    (SELECT count(*)::int FROM pg_policies
     WHERE tablename = 'p1_initplan'
       AND (qual IS NULL OR qual ~ 'SELECT rbac\.has_permission\(')
       AND (with_check IS NULL OR with_check ~ 'SELECT rbac\.has_permission\(')),
    4,
    'edit_permission change: all four rebuilt policies are in the InitPlan form');

-- build_select_rule_policy, rule branch: UPDATE/DELETE keep the permission check next to the
-- per-row rule function; the permission half must still be the InitPlan form
UPDATE entities SET select_rule = '{"!=":[{"var":"label"},""]}'::jsonb
WHERE table_name = 'p1_initplan';

SELECT is(
    (SELECT string_agg(policyname || ': ' || coalesce(qual, '-') || ' / ' || coalesce(with_check, '-'), '; ')
     FROM pg_policies
     WHERE tablename = 'p1_initplan'
       AND regexp_replace(coalesce(qual, '') || ' ' || coalesce(with_check, ''),
                          'SELECT rbac\.has_(any_)?permission\(', '', 'g')
           ~ 'rbac\.has_(any_)?permission\('),
    NULL::text,
    'select_rule set: no bare rbac.has_permission() next to the per-row rule function');

SELECT is(
    (SELECT count(*)::int FROM pg_policies
     WHERE tablename = 'p1_initplan'
       AND policyname IN ('p1_initplan_update_policy', 'p1_initplan_delete_policy')
       AND qual ~ 'SELECT rbac\.has_permission\('
       AND qual ~ 'select_rule_p1_initplan\('),
    2,
    'select_rule set: UPDATE and DELETE combine the InitPlan-form permission check with the rule function');

-- build_select_rule_policy, permission-only branch again (rule removed)
UPDATE entities SET select_rule = '{}'::jsonb WHERE table_name = 'p1_initplan';

SELECT is(
    (SELECT string_agg(policyname || ': ' || coalesce(qual, '-') || ' / ' || coalesce(with_check, '-'), '; ')
     FROM pg_policies
     WHERE tablename = 'p1_initplan'
       AND regexp_replace(coalesce(qual, '') || ' ' || coalesce(with_check, ''),
                          'SELECT rbac\.has_(any_)?permission\(', '', 'g')
           ~ 'rbac\.has_(any_)?permission\('),
    NULL::text,
    'select_rule cleared: no bare rbac.has_permission() in the restored policies');

SELECT is(
    (SELECT count(*)::int FROM pg_policies
     WHERE tablename = 'p1_initplan'
       AND (qual IS NULL OR qual ~ 'SELECT rbac\.has_permission\(')
       AND (with_check IS NULL OR with_check ~ 'SELECT rbac\.has_permission\(')),
    4,
    'select_rule cleared: all four restored policies are in the InitPlan form');

-- enable_dd_table (0145): entity defined unmanaged, then managed
INSERT INTO entities (table_name, singular, singular_label, plural_label, description,
    module_id, view_permission, edit_permission, id_column, label_column, managed)
VALUES ('p1_unmanaged', 'p1_unmanaged_item', 'P1 Unmanaged', 'P1 Unmanageds',
    'policy form probe, managed toggle', 1, 'public:read', 'nwind:manage', 'id', 'label', FALSE);

UPDATE entities SET managed = TRUE WHERE table_name = 'p1_unmanaged';

SELECT is(
    (SELECT string_agg(policyname || ': ' || coalesce(qual, '-') || ' / ' || coalesce(with_check, '-'), '; ')
     FROM pg_policies
     WHERE tablename = 'p1_unmanaged'
       AND regexp_replace(coalesce(qual, '') || ' ' || coalesce(with_check, ''),
                          'SELECT rbac\.has_(any_)?permission\(', '', 'g')
           ~ 'rbac\.has_(any_)?permission\('),
    NULL::text,
    'enable_dd_table: no bare rbac.has_permission() in the policies of a managed-toggled entity');

SELECT is(
    (SELECT count(*)::int FROM pg_policies
     WHERE tablename = 'p1_unmanaged'
       AND (qual IS NULL OR qual ~ 'SELECT rbac\.has_permission\(')
       AND (with_check IS NULL OR with_check ~ 'SELECT rbac\.has_permission\(')),
    4,
    'enable_dd_table: all four policies are in the InitPlan form');

-- ---------------------------------------------------------------------------
-- Final sweep: the catalog including everything the generators just built
-- ---------------------------------------------------------------------------
SELECT is(
    (SELECT string_agg(schemaname || '.' || tablename || '.' || policyname, ', '
                       ORDER BY schemaname, tablename, policyname)
     FROM pg_policies
     WHERE regexp_replace(coalesce(qual, '') || ' ' || coalesce(with_check, ''),
                          'SELECT rbac\.has_(any_)?permission\(', '', 'g')
           ~ 'rbac\.has_(any_)?permission\('),
    NULL::text,
    'final sweep: no policy anywhere calls rbac.has_permission() outside a sub-select');

SELECT * FROM finish();
ROLLBACK;
