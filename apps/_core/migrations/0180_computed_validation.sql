-- =====================================================
-- COMPUTED FIELDS AND VALIDATION RULES
-- =====================================================
-- Per-record derivation and invariant checks expressed as JsonLogic.
--
-- Schema for entities.computed_fields and entities.validation_rules lives in
-- 0060_dd_schema.sql alongside the rest of the entities table; this migration
-- contains only the runtime: a per-table BEFORE INSERT OR UPDATE OR DELETE
-- trigger function that is (re)generated whenever either array is non-empty, and
-- dropped when both are empty or the entity itself is deleted.
--
-- Reserved variables injected into the JsonLogic data:
--   $today    -> server date
--   $now      -> server timestamp
--   $user_id  -> internal user_id from JWT context, null when no context
--   $old      -> previous row as JSON on UPDATE and DELETE, null on INSERT
--   $mode     -> the operation: 'insert' | 'update' | 'delete'
--
-- DELETE arm (I7): the rules also fire on DELETE, evaluated against the row being
-- removed (OLD). Computed-field output is discarded on DELETE (the row is going
-- away), but validation_rules can abort the delete — e.g. a rule guarded by
-- {"!=": [{"var": "$mode"}, "delete"]} blocks deletion. Because the USING/WITH
-- CHECK predicate is per-row, this holds regardless of statement shape (A4).

-- =====================================================
-- STEP 1: Per-row trigger generator
-- =====================================================

CREATE OR REPLACE FUNCTION build_record_logic_trigger(p_table_name TEXT)
RETURNS VOID AS $$
DECLARE
    v_entity entities%ROWTYPE;
    v_fn_name TEXT;
    v_trg_name CONSTANT TEXT := 'compute_validate_trigger';
    v_body TEXT;
    v_rules_block TEXT := '';
    v_idx INT;
    v_item JSONB;
    v_name TEXT;
    v_path_sql TEXT;
    v_logic_lit TEXT;
    v_code TEXT;
    v_message TEXT;
    v_has_computed BOOLEAN;
    v_writeback TEXT;
    v_all_logic TEXT;
    v_extra_ctx TEXT := '';
BEGIN
    SELECT * INTO v_entity FROM entities WHERE table_name = p_table_name;
    IF NOT FOUND THEN
        -- Entity is being deleted — drop the function if it exists
        v_fn_name := 'compute_validate_' || p_table_name;
        EXECUTE format('DROP FUNCTION IF EXISTS public.%I() CASCADE', v_fn_name);
        RETURN;
    END IF;

    -- Skip unmanaged tables (no physical table to attach a trigger to)
    IF NOT v_entity.managed THEN
        RETURN;
    END IF;

    v_fn_name := 'compute_validate_' || p_table_name;

    -- Drop any existing trigger + function so we can recreate cleanly
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON %I', v_trg_name, p_table_name);
    EXECUTE format('DROP FUNCTION IF EXISTS public.%I() CASCADE', v_fn_name);

    -- Both arrays empty → nothing to install
    IF jsonb_array_length(COALESCE(v_entity.computed_fields, '[]'::jsonb)) = 0
       AND jsonb_array_length(COALESCE(v_entity.validation_rules, '[]'::jsonb)) = 0 THEN
        RETURN;
    END IF;

    v_has_computed := jsonb_array_length(COALESCE(v_entity.computed_fields, '[]'::jsonb)) > 0;

    -- $old is built only for entities whose rules read it: it serializes the
    -- whole previous row on every UPDATE and DELETE, for rules that mostly never
    -- look at it. $mode is a lowercased TG_OP and costs nothing, so it is always
    -- present - and it is the variable that guards DELETE, where a missing value
    -- makes a rule such as {"!=":[{"var":"$mode"},"delete"]} pass instead of
    -- blocking the delete.
    --
    -- The $old test is a substring search over the raw rule text rather than a
    -- lookup of a "$old" key, because a reference is usually a path -
    -- {"var":"$old.label"} - and an exact-key test would miss it and drop the
    -- value the rule needs. Three forms count as a reference:
    --   * the name appearing anywhere, which covers every literal path;
    --   * value_changed, which never names $old but reads the key itself and
    --     returns true whenever it is absent, so an entity using it would
    --     silently start reporting every field as changed;
    --   * a var whose argument is an object rather than a string. The
    --     interpreter evaluates that argument as JsonLogic, so {"var":{"cat":
    --     ["$ol","d.label"]}} resolves to $old.label with the name nowhere in
    --     the text. Such a rule cannot be searched, so any entity using one gets
    --     the full context.
    v_all_logic := COALESCE(v_entity.computed_fields::text, '') ||
                   COALESCE(v_entity.validation_rules::text, '');

    IF v_all_logic LIKE '%$old%'
       OR v_all_logic LIKE '%value_changed%'
       OR v_all_logic LIKE '%"var": {%' THEN
        v_extra_ctx := v_extra_ctx || $CTX$,
        '$old',     CASE WHEN TG_OP IN ('UPDATE', 'DELETE') THEN to_jsonb(OLD) ELSE 'null'::jsonb END$CTX$;
    END IF;

    v_extra_ctx := v_extra_ctx || $CTX$,
        '$mode',    to_jsonb(lower(TG_OP))$CTX$;

    -- Computed fields: evaluate each, write result into v_data at name (supports dotted paths)
    FOR v_idx IN 0 .. jsonb_array_length(COALESCE(v_entity.computed_fields, '[]'::jsonb)) - 1 LOOP
        v_item := v_entity.computed_fields -> v_idx;
        v_name := v_item ->> 'name';
        IF v_name IS NULL OR v_name = '' THEN
            RAISE EXCEPTION 'computed_fields[%] on "%" is missing required "name"', v_idx, p_table_name;
        END IF;
        IF (v_item -> 'jsonlogic') IS NULL THEN
            RAISE EXCEPTION 'computed_fields[%] on "%" is missing required "jsonlogic"', v_idx, p_table_name;
        END IF;
        v_logic_lit := quote_literal((v_item -> 'jsonlogic')::text);
        SELECT 'ARRAY[' || string_agg(quote_literal(part), ',') || ']::text[]'
          INTO v_path_sql
          FROM unnest(string_to_array(v_name, '.')) AS part;

        -- The field name is admin-supplied text that lands inside the generated
        -- function body: it is emitted as a quoted literal (with RAISE's %
        -- placeholders escaped) so quotes or dollar signs in it cannot break out
        -- of the string.
        v_rules_block := v_rules_block || E'\n' || format(
$BLOCK$    BEGIN
        v_result := evaluate_json_logic(%s::jsonb, v_data);
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION %s, SQLERRM;
    END;
    v_data := jsonb_set(v_data, %s, COALESCE(v_result, 'null'::jsonb), true);
$BLOCK$,
            v_logic_lit,
            quote_literal('computed_fields[' || replace(v_name, '%', '%%') || ']: %'),
            v_path_sql);
    END LOOP;

    -- Validation rules: evaluate each against post-derivation v_data, raise on falsy
    FOR v_idx IN 0 .. jsonb_array_length(COALESCE(v_entity.validation_rules, '[]'::jsonb)) - 1 LOOP
        v_item := v_entity.validation_rules -> v_idx;
        v_code := v_item ->> 'code';
        v_message := v_item ->> 'message';
        IF v_code IS NULL OR v_code = '' THEN
            RAISE EXCEPTION 'validation_rules[%] on "%" is missing required "code"', v_idx, p_table_name;
        END IF;
        IF v_message IS NULL THEN
            RAISE EXCEPTION 'validation_rules[%] on "%" is missing required "message"', v_idx, p_table_name;
        END IF;
        IF (v_item -> 'jsonlogic') IS NULL THEN
            RAISE EXCEPTION 'validation_rules[%] on "%" is missing required "jsonlogic"', v_idx, p_table_name;
        END IF;
        v_logic_lit := quote_literal((v_item -> 'jsonlogic')::text);

        -- code and message are admin-supplied text that lands inside the generated
        -- function body: both are emitted as quoted literals, with RAISE's %
        -- placeholders escaped where the literal is used as a RAISE format string.
        v_rules_block := v_rules_block || E'\n' || format(
$BLOCK$    BEGIN
        v_result := evaluate_json_logic(%s::jsonb, v_data);
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION %s, SQLERRM;
    END;
    IF NOT jl_truthy(v_result) THEN
        RAISE EXCEPTION %s USING ERRCODE = '23514', DETAIL = %s;
    END IF;
$BLOCK$,
            v_logic_lit,
            quote_literal('validation_rules[' || replace(v_code, '%', '%%') || ']: %'),
            quote_literal(replace(v_message, '%', '%%')),
            quote_literal('rule code: ' || v_code));
    END LOOP;

    -- Write-back tail. Validation rules never modify the row, so a validation-only
    -- entity returns NEW untouched — no need to rebuild it. An entity WITH computed
    -- fields must fold the derived values (written into v_data by the block above)
    -- back onto NEW.
    --
    -- The rebuild uses a DYNAMIC jsonb_populate_record (EXECUTE, re-planned each
    -- call) rather than a static NEW := jsonb_populate_record(NULL::public.<tbl>, …).
    -- A static call caches the target row type's tuple descriptor in the plpgsql
    -- expression's fn_extra and does NOT refresh it when the table gains a column
    -- LATER in the SAME transaction — so a column added and set after this trigger
    -- first fired (e.g. entities.order_column added in 0270 then set here) would be
    -- silently dropped, reverting that write. This only surfaces in a single-txn
    -- install (CREATE EXTENSION / one big script); the per-file migrate path commits
    -- between statements and refreshes the cache. EXECUTE re-resolves the descriptor
    -- every call, so mid-transaction columns survive.
    IF v_has_computed THEN
        v_writeback := $WB$    v_data := v_data - '$today' - '$now' - '$user_id' - '$old' - '$mode';
    EXECUTE format('SELECT (jsonb_populate_record(NULL::public.%I, $1)).*', TG_TABLE_NAME) INTO NEW USING v_data;
$WB$;
    ELSE
        v_writeback := '';
    END IF;

    -- Assemble full function.
    v_body := format($FUNC$
CREATE FUNCTION public.%I() RETURNS TRIGGER AS $TRIG$
DECLARE
    v_data jsonb;
    v_result jsonb;
    v_uid_text text;
BEGIN
    -- Derived through rbac (lazy context initialization), never read raw from the
    -- client-writable app.current_user_id setting; NULL when unauthenticated.
    v_uid_text := rbac.user_id_or_null()::text;
    -- On DELETE there is no NEW row; evaluate the rules against the row being removed (OLD).
    v_data := to_jsonb(CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END) || jsonb_build_object(
        '$today',   to_jsonb(CURRENT_DATE),
        '$now',     to_jsonb(CURRENT_TIMESTAMP),
        '$user_id', CASE
                       WHEN v_uid_text IS NULL OR v_uid_text = '' THEN 'null'::jsonb
                       ELSE to_jsonb(v_uid_text::int)
                   END%s
    );
%s
    -- DELETE keeps no computed output; the validation rules above may still abort it.
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
%s    RETURN NEW;
END;
$TRIG$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;
$FUNC$, v_fn_name, v_extra_ctx, v_rules_block, v_writeback);

    EXECUTE v_body;

    -- Revoke PUBLIC execute on trigger function (security best practice)
    EXECUTE format('REVOKE EXECUTE ON FUNCTION public.%I() FROM PUBLIC', v_fn_name);

    EXECUTE format(
        'COMMENT ON FUNCTION public.%I() IS %L',
        v_fn_name,
        format('Per-row BEFORE INSERT/UPDATE/DELETE trigger function evaluating computed_fields and validation_rules for entity "%s". Generated by build_record_logic_trigger.', p_table_name));

    EXECUTE format(
        'CREATE TRIGGER %I BEFORE INSERT OR UPDATE OR DELETE ON %I FOR EACH ROW EXECUTE FUNCTION public.%I()',
        v_trg_name, p_table_name, v_fn_name);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION build_record_logic_trigger IS
'Generates (or drops) the per-table BEFORE INSERT OR UPDATE OR DELETE trigger and trigger function used to evaluate computed_fields and validation_rules for the given entity. On DELETE the rules evaluate against OLD with $mode=delete; computed output is discarded but validation_rules can abort the delete.';

REVOKE EXECUTE ON FUNCTION build_record_logic_trigger(TEXT) FROM PUBLIC;

-- =====================================================
-- STEP 2: Trigger on entities to keep per-row trigger in sync
-- =====================================================

CREATE OR REPLACE FUNCTION manage_record_logic_trigger()
RETURNS TRIGGER AS $$
DECLARE
    v_fn_name TEXT;
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.managed AND (
              jsonb_array_length(COALESCE(NEW.computed_fields, '[]'::jsonb)) > 0
           OR jsonb_array_length(COALESCE(NEW.validation_rules, '[]'::jsonb)) > 0
        ) THEN
            PERFORM build_record_logic_trigger(NEW.table_name);
        END IF;
        RETURN NEW;
    END IF;

    IF TG_OP = 'UPDATE' THEN
        IF OLD.computed_fields IS DISTINCT FROM NEW.computed_fields
           OR OLD.validation_rules IS DISTINCT FROM NEW.validation_rules
           OR OLD.managed IS DISTINCT FROM NEW.managed
           OR OLD.table_name IS DISTINCT FROM NEW.table_name THEN
            PERFORM build_record_logic_trigger(NEW.table_name);
        END IF;
        RETURN NEW;
    END IF;

    IF TG_OP = 'DELETE' THEN
        v_fn_name := 'compute_validate_' || OLD.table_name;
        EXECUTE format('DROP FUNCTION IF EXISTS public.%I() CASCADE', v_fn_name);
        RETURN OLD;
    END IF;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION manage_record_logic_trigger IS
'Trigger function on entities that creates/updates/drops the per-table BEFORE row trigger for computed_fields and validation_rules.';

-- AFTER INSERT/UPDATE so it runs after create_table_trigger (which creates the
-- physical table). AFTER DELETE so it runs after delete_table_trigger drops the
-- table — at that point only the standalone trigger function survives, which we
-- explicitly drop.
CREATE TRIGGER manage_record_logic_trigger
    AFTER INSERT OR UPDATE OR DELETE ON entities
    FOR EACH ROW
    EXECUTE FUNCTION manage_record_logic_trigger();

REVOKE EXECUTE ON FUNCTION manage_record_logic_trigger() FROM PUBLIC;

-- =====================================================
-- STEP 3: Per-row SELECT policy generator (select_rule)
-- =====================================================
-- When an entity has a non-empty select_rule (a JsonLogic object), this
-- function generates two helper functions and rebuilds the SELECT, UPDATE and
-- DELETE policies so each row is filtered by the rule. The two-argument helper
-- merges the row with a statement context handed to it; the one-argument helper
-- resolves that context itself. Reserved variables are
-- ($today, $now, $user_id — there is no $old/$mode for a read),
-- evaluates the JsonLogic rule, and returns true only when the result is truthy.

-- The reserved JsonLogic variables that do not vary within a statement. RLS
-- quals reach this through an uncorrelated sub-select so the planner turns it
-- into an InitPlan and evaluates it once per statement instead of once per row;
-- 0445_test_policy_initplan_form.sql pins that shape against a well-meaning
-- edit to a bare call.
--
-- rbac.uid() is called directly and first. It is what refuses a session with no
-- valid claims, and this function is the only refusal on the select_rule read
-- path: that policy's USING clause carries no permission conjunct, and the
-- generated predicate swallows every error from rule evaluation. Reaching uid()
-- indirectly is not equivalent - rbac.ensure_context_initialized() returns early
-- on an already-initialized session without calling it, so the gate would hold
-- only on the first statement of a transaction.
--
-- The user id comes from rbac.user_id() rather than from app.current_user_id.
-- That setting is client-writable in a direct SQL session, and every other
-- reader in the codebase reaches the identity through the rbac helpers so that
-- hardening them hardens all of it at once; a raw read here would be the one
-- reader left behind. rbac.user_id() also raises 28000 for a subject with no
-- users row, which is the answer the other RLS paths give.
CREATE OR REPLACE FUNCTION public.jl_request_context()
RETURNS JSONB AS $$
DECLARE
    v_uid INTEGER;
BEGIN
    PERFORM rbac.uid();
    v_uid := rbac.user_id();
    RETURN jsonb_build_object(
        '$today',   to_jsonb(CURRENT_DATE),
        '$now',     to_jsonb(CURRENT_TIMESTAMP),
        -- An unresolved user is jsonb null, never SQL NULL: a NULL here would
        -- make the whole || merge in the caller NULL and silently empty the
        -- rule's data, so every rule would see a row with no columns.
        '$user_id', CASE WHEN v_uid IS NULL THEN 'null'::jsonb ELSE to_jsonb(v_uid) END
    );
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION public.jl_request_context() IS
'Statement-constant JsonLogic context: $today, $now and $user_id. Raises insufficient_privilege when the session carries no valid claims. Called from RLS quals through an uncorrelated sub-select so it runs once per statement.';

REVOKE EXECUTE ON FUNCTION public.jl_request_context() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.jl_request_context() TO semantius_user;

CREATE OR REPLACE FUNCTION build_select_rule_policy(p_table_name TEXT)
RETURNS VOID AS $$
DECLARE
    v_entity entities%ROWTYPE;
    v_fn_name TEXT;
    v_policy_name TEXT;
    v_body TEXT;
    v_logic_lit TEXT;
BEGIN
    SELECT * INTO v_entity FROM entities WHERE table_name = p_table_name;
    IF NOT FOUND THEN
        -- Entity is being deleted — drop both overloads if they exist. A
        -- DROP that names only one signature is a silent no-op for the other,
        -- and the CASCADE that removes the dependent policies rides on it.
        v_fn_name := 'select_rule_' || p_table_name;
        EXECUTE format('DROP FUNCTION IF EXISTS public.%I(public.%I, jsonb) CASCADE', v_fn_name, p_table_name);
        EXECUTE format('DROP FUNCTION IF EXISTS public.%I(public.%I) CASCADE', v_fn_name, p_table_name);
        RETURN;
    END IF;

    -- Skip unmanaged tables
    IF NOT v_entity.managed THEN
        RETURN;
    END IF;

    v_fn_name := 'select_rule_' || p_table_name;
    v_policy_name := p_table_name || '_select_policy';

    -- Always drop both overloads before rebuilding (CASCADE removes anything
    -- depending on them). Dropping only one leaves the other behind and the
    -- CREATE below then fails with a duplicate-function error.
    EXECUTE format('DROP FUNCTION IF EXISTS public.%I(public.%I, jsonb) CASCADE', v_fn_name, p_table_name);
    EXECUTE format('DROP FUNCTION IF EXISTS public.%I(public.%I) CASCADE', v_fn_name, p_table_name);

    -- Drop the existing select policy so we can recreate it
    EXECUTE format('DROP POLICY IF EXISTS %I ON %I', v_policy_name, p_table_name);

    -- Every rbac.has_permission() below is wrapped in a scalar sub-select so it runs once per
    -- statement (InitPlan), not per row; see the note in create_dd_table. Test 0445 pins it.
    -- If select_rule is empty, restore the default permission-only policies (read = view
    -- permission, writes = edit permission, no per-row rule).
    IF v_entity.select_rule = '{}'::jsonb THEN
        EXECUTE format(
            'CREATE POLICY %I ON %I FOR SELECT TO semantius_user USING ((SELECT rbac.has_permission(%L)))',
            v_policy_name, p_table_name, v_entity.view_permission);
        EXECUTE format('DROP POLICY IF EXISTS %I ON %I', p_table_name || '_update_policy', p_table_name);
        EXECUTE format('DROP POLICY IF EXISTS %I ON %I', p_table_name || '_delete_policy', p_table_name);
        EXECUTE format(
            'CREATE POLICY %I ON %I FOR UPDATE TO semantius_user USING ((SELECT rbac.has_permission(%L))) WITH CHECK ((SELECT rbac.has_permission(%L)))',
            p_table_name || '_update_policy', p_table_name, v_entity.edit_permission, v_entity.edit_permission);
        EXECUTE format(
            'CREATE POLICY %I ON %I FOR DELETE TO semantius_user USING ((SELECT rbac.has_permission(%L)))',
            p_table_name || '_delete_policy', p_table_name, v_entity.edit_permission);
        RETURN;
    END IF;

    v_logic_lit := quote_literal(v_entity.select_rule::text);

    -- Build the per-row evaluation function in two overloads.
    --
    -- The two-argument form takes the statement-constant context as a parameter
    -- so the policies can hoist it out of the per-row loop. It answers rule
    -- questions for anyone able to supply a context, which is unavoidable: an
    -- RLS qual runs with the querying role's privileges, so semantius_user must
    -- hold EXECUTE. It returns no row data - the caller already holds the row it
    -- passes in, and RLS still filters any relation being scanned. The
    -- permission operators resolve against the session rather than against
    -- $user_id, so a forged context cannot widen what a caller may see. It does
    -- merge the context over the row, so a caller can shadow a column and aim an
    -- operator such as has_consultation at a record it cannot read; the answer
    -- is one boolean, never its contents.
    --
    -- The one-argument form supplies the context itself and is the entry point
    -- for callers outside a policy, get_record_by_id in 0070_dd_functions.sql
    -- among them. It carries the authentication gate for those callers, which is
    -- why it must not be reduced to a convenience wrapper that skips it.
    v_body := format($FUNC$
CREATE FUNCTION public.%I(p_row public.%I, p_ctx jsonb) RETURNS BOOLEAN AS $SEL$
DECLARE
    v_data jsonb;
    v_result jsonb;
BEGIN
    v_data := to_jsonb(p_row) || p_ctx;

    BEGIN
        v_result := evaluate_json_logic(%s::jsonb, v_data);
    EXCEPTION WHEN OTHERS THEN
        RETURN FALSE;
    END;

    RETURN jl_truthy(v_result);
END;
$SEL$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public;

CREATE FUNCTION public.%I(p_row public.%I) RETURNS BOOLEAN AS $SEL$
    SELECT public.%I(p_row, public.jl_request_context());
$SEL$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public;
$FUNC$, v_fn_name, p_table_name, v_logic_lit, v_fn_name, p_table_name, v_fn_name);

    EXECUTE v_body;

    -- Both overloads need their own grants and comment: privileges and comments
    -- attach to a signature, not to a name, so an overload left out is callable
    -- by any role and undocumented. 0060_test_security.sql and
    -- 0240_test_no_unsafe_functions.sql sweep for exactly that.
    EXECUTE format('REVOKE EXECUTE ON FUNCTION public.%I(public.%I, jsonb) FROM PUBLIC', v_fn_name, p_table_name);
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%I(public.%I, jsonb) TO semantius_user', v_fn_name, p_table_name);
    EXECUTE format(
        'COMMENT ON FUNCTION public.%I(public.%I, jsonb) IS %L',
        v_fn_name, p_table_name,
        format('Per-row FOR SELECT RLS predicate evaluating the select_rule JsonLogic for entity "%s" against a caller-supplied statement context. Generated by build_select_rule_policy.', p_table_name));

    EXECUTE format('REVOKE EXECUTE ON FUNCTION public.%I(public.%I) FROM PUBLIC', v_fn_name, p_table_name);
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%I(public.%I) TO semantius_user', v_fn_name, p_table_name);
    EXECUTE format(
        'COMMENT ON FUNCTION public.%I(public.%I) IS %L',
        v_fn_name, p_table_name,
        format('Per-row FOR SELECT RLS predicate evaluating the select_rule JsonLogic for entity "%s", resolving the request context itself. Generated by build_select_rule_policy.', p_table_name));

    -- The context sub-select is uncorrelated, so the planner lifts it to an
    -- InitPlan and resolves the request once per statement rather than once per
    -- scanned row. It has to appear in all three policies: a USING clause is
    -- evaluated per row for every UPDATE and DELETE as well, so a policy left
    -- with a bare call keeps paying per row on the write path.
    EXECUTE format(
        'CREATE POLICY %I ON %I FOR SELECT TO semantius_user USING (public.%I(%I.*, (SELECT public.jl_request_context())))',
        v_policy_name, p_table_name, v_fn_name, p_table_name);

    -- The canonical predicate ALSO gates writes: edit_permission AND the row rule. Because a
    -- policy USING clause is evaluated per-row by PostgreSQL for every UPDATE/DELETE regardless
    -- of statement shape, a bare "UPDATE t SET ..." cannot reach rows the SELECT policy hides.
    -- WITH CHECK is edit_permission only: there is no post-image rule, so a write may move a
    -- row out of its own rule.
    EXECUTE format('DROP POLICY IF EXISTS %I ON %I', p_table_name || '_update_policy', p_table_name);
    EXECUTE format('DROP POLICY IF EXISTS %I ON %I', p_table_name || '_delete_policy', p_table_name);
    EXECUTE format(
        'CREATE POLICY %I ON %I FOR UPDATE TO semantius_user USING ((SELECT rbac.has_permission(%L)) AND public.%I(%I.*, (SELECT public.jl_request_context()))) WITH CHECK ((SELECT rbac.has_permission(%L)))',
        p_table_name || '_update_policy', p_table_name, v_entity.edit_permission, v_fn_name, p_table_name, v_entity.edit_permission);
    EXECUTE format(
        'CREATE POLICY %I ON %I FOR DELETE TO semantius_user USING ((SELECT rbac.has_permission(%L)) AND public.%I(%I.*, (SELECT public.jl_request_context())))',
        p_table_name || '_delete_policy', p_table_name, v_entity.edit_permission, v_fn_name, p_table_name);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION build_select_rule_policy IS
'Generates (or drops) a per-row FOR SELECT RLS policy function that evaluates the entity select_rule JsonLogic against each row. The generated function has EXECUTE revoked from PUBLIC.';

REVOKE EXECUTE ON FUNCTION build_select_rule_policy(TEXT) FROM PUBLIC;

-- =====================================================
-- STEP 4: Trigger on entities to keep select_rule policy in sync
-- =====================================================

CREATE OR REPLACE FUNCTION manage_select_rule_policy()
RETURNS TRIGGER AS $$
DECLARE
    v_fn_name TEXT;
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.managed AND NEW.select_rule IS NOT NULL AND NEW.select_rule != '{}'::jsonb THEN
            PERFORM build_select_rule_policy(NEW.table_name);
        END IF;
        RETURN NEW;
    END IF;

    IF TG_OP = 'UPDATE' THEN
        IF OLD.select_rule IS DISTINCT FROM NEW.select_rule
           OR OLD.view_permission IS DISTINCT FROM NEW.view_permission
           OR OLD.managed IS DISTINCT FROM NEW.managed
           OR OLD.table_name IS DISTINCT FROM NEW.table_name THEN
            PERFORM build_select_rule_policy(NEW.table_name);
        END IF;
        RETURN NEW;
    END IF;

    IF TG_OP = 'DELETE' THEN
        -- Both overloads, or the survivor blocks the next CREATE under this name.
        v_fn_name := 'select_rule_' || OLD.table_name;
        EXECUTE format('DROP FUNCTION IF EXISTS public.%I(public.%I, jsonb) CASCADE', v_fn_name, OLD.table_name);
        EXECUTE format('DROP FUNCTION IF EXISTS public.%I(public.%I) CASCADE', v_fn_name, OLD.table_name);
        RETURN OLD;
    END IF;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION manage_select_rule_policy IS
'Trigger function on entities that creates/updates/drops the per-table FOR SELECT RLS policy for select_rule.';

CREATE TRIGGER manage_select_rule_policy_trigger
    AFTER INSERT OR UPDATE OR DELETE ON entities
    FOR EACH ROW
    EXECUTE FUNCTION manage_select_rule_policy();

REVOKE EXECUTE ON FUNCTION manage_select_rule_policy() FROM PUBLIC;

-- =====================================================
-- STEP 5: Bootstrap triggers for entities inserted before this migration
-- =====================================================
-- Core entities (roles, permission_hierarchy, etc.) may have been inserted in
-- 0060_dd_schema.sql with non-empty validation_rules/computed_fields before the
-- manage_record_logic_trigger existed. Build their triggers now.

DO $$
DECLARE
    v_table_name TEXT;
BEGIN
    FOR v_table_name IN
        SELECT e.table_name FROM entities e
        WHERE jsonb_array_length(COALESCE(e.computed_fields, '[]'::jsonb)) > 0
           OR jsonb_array_length(COALESCE(e.validation_rules, '[]'::jsonb)) > 0
    LOOP
        PERFORM build_record_logic_trigger(v_table_name);
    END LOOP;
END;
$$;
