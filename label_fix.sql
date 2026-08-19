-- =====================================================================================
-- label_fix.sql  —  STANDALONE manual composed-label repair  (run by hand, NOT a migration)
-- =====================================================================================
-- This file lives at the REPO ROOT, outside apps/_core/migrations/, so the migration runner
-- never picks it up and it is NEVER auto-applied. Run it by hand against each broken tenant
-- (migrated before the composed-label feature landed) — e.g. paste into a SQL console or
-- `psql "$TENANT_URL" -f label_fix.sql`.
--
-- It is a SUPERSET of migration 0270_label_fix.sql: the full composed-label layer (column,
-- dd_* predicates, rebuild_entity_label_functions, validation/sync triggers, v0_label_fix)
-- PLUS the get_schema change (build_schema_for_table re-emit) so the derived _label / <fk>_label
-- columns are also ADVERTISED in get_schema's `properties`.
--
-- HOW TO RUN: just execute the WHOLE file. You do NOT need to call anything separately — the
-- final `SELECT public.v0_label_fix();` self-applies the rebuild across every entity. Every
-- statement is idempotent (CREATE OR REPLACE / ADD ... IF NOT EXISTS / DROP TRIGGER IF EXISTS),
-- so the file is safe to re-run and safe on already-healthy tenants. Run it inside one
-- transaction if you want all-or-nothing (BEGIN; \i label_fix.sql; COMMIT;).

-- =====================================================
-- §0  CTYPE CONSOLIDATION  (is_core → ctype data merge; pre-merge tenants only)
-- =====================================================
-- Tenants that predate the is_core→ctype merge have valid_ctype = ['','id','label','created_at',
-- 'updated_at'] and a separate is_core boolean. That blocks ctype='core' (the error you hit) and the
-- §9 get_schema re-emit. This block migrates the DATA to the new model so the rest of the file (and
-- get_schema) can apply: legacy timestamp ctypes → 'audit', is_core rows → 'core', constraint widened
-- to ['','id','label','audit','core'], ctype field-metadata refreshed, is_core field-metadata removed.
--
-- It does NOT drop the physical is_core column. On a pre-merge tenant ~25 function references across
-- 0070/0140/0145/0150/0190 still read fields.is_core; dropping the column would break them at runtime
-- (plpgsql plans column refs lazily). After this consolidation the column is vestigial and harmless —
-- get_schema derives is_core from ctype and ignores it. Triggers are disabled only for the data edits;
-- if the block errors it rolls back atomically (triggers restored, no half state). Idempotent: a
-- second run sees a 'core' ctype row already present and skips.
DO $ctype$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_schema='public' AND table_name='fields' AND column_name='is_core')
     AND NOT EXISTS (SELECT 1 FROM fields WHERE ctype = 'core') THEN

    ALTER TABLE fields DISABLE TRIGGER USER;                 -- privileged DD data surgery
    ALTER TABLE fields DROP CONSTRAINT IF EXISTS valid_ctype;

    UPDATE fields SET ctype = 'audit' WHERE ctype IN ('created_at', 'updated_at');
    UPDATE fields SET ctype = 'core'  WHERE is_core = TRUE AND COALESCE(ctype, '') = '';

    ALTER TABLE fields ADD CONSTRAINT valid_ctype
        CHECK (ctype = ANY (ARRAY['', 'id', 'label', 'audit', 'core']));

    -- refresh the ctype field's own metadata (enum list + mark it core), drop the is_core field row
    UPDATE fields SET enum_values = to_jsonb(ARRAY['', 'id', 'label', 'audit', 'core']), ctype = 'core'
      WHERE table_name = 'fields' AND field_name = 'ctype';
    DELETE FROM fields WHERE table_name = 'fields' AND field_name = 'is_core';

    ALTER TABLE fields ENABLE TRIGGER USER;
    RAISE NOTICE 'label_fix: consolidated ctype (created_at/updated_at→audit, is_core→core, constraint widened). The is_core column is retained (vestigial) — dropping it would break pre-merge functions that still read it.';
  ELSE
    RAISE NOTICE 'label_fix: ctype already consolidated (post-merge schema) — skipping §0.';
  END IF;
END $ctype$;

-- =====================================================
-- §1  SCHEMA — entities.label_parent column + junction stamping
-- =====================================================
-- The identity-spine column rebuild_entity_label_functions reads. Empty = intrinsic/self-identifying.
ALTER TABLE entities ADD COLUMN IF NOT EXISTS label_parent TEXT NOT NULL DEFAULT '';

-- label_parent is empty (intrinsic) or a column-name identifier (semantically validated against the
-- fields catalog by validate_label_parent below). Drop-then-add so the CHECK is present exactly once.
ALTER TABLE entities DROP CONSTRAINT IF EXISTS valid_label_parent;
ALTER TABLE entities ADD CONSTRAINT valid_label_parent
    CHECK (label_parent = '' OR label_parent ~ '^[a-z_][a-z0-9_]*$');

-- Field metadata for the new column (idempotent; surfaced in the entities admin UI). 'junction' is
-- already a valid entity_type on every tenant, so no enum change is needed.
-- Resilient to ctype drift: older tenants (pre is_core→ctype merge) have a valid_ctype CHECK that
-- does not permit 'core', so we try 'core' first and fall back to '' (always valid); if the row
-- still can't be inserted for any reason we skip it with a notice — the label_parent COLUMN and the
-- label functions do not depend on this metadata row.
DO $meta$
BEGIN
    BEGIN
        INSERT INTO fields (table_name, field_name, title, description, default_value, format, is_pk, field_order, input_type, width, ctype, searchable, reference_table, reference_delete_mode, relationship_label)
        VALUES
            ('entities', 'label_parent', 'Label Parent', 'Names the reference/parent FK that is this entity''s identity spine for the composed _label. Empty = intrinsic/self-identifying (composed label = local label).', '', 'text', FALSE, 111, 'default', 'default', 'core', FALSE, '', '', '')
        ON CONFLICT (table_name, field_name) DO NOTHING;
    EXCEPTION WHEN check_violation THEN
        INSERT INTO fields (table_name, field_name, title, description, default_value, format, is_pk, field_order, input_type, width, ctype, searchable, reference_table, reference_delete_mode, relationship_label)
        VALUES
            ('entities', 'label_parent', 'Label Parent', 'Names the reference/parent FK that is this entity''s identity spine for the composed _label. Empty = intrinsic/self-identifying (composed label = local label).', '', 'text', FALSE, 111, 'default', 'default', '', FALSE, '', '', '')
        ON CONFLICT (table_name, field_name) DO NOTHING;
    END;
EXCEPTION WHEN others THEN
    RAISE NOTICE 'label_fix: skipped entities.label_parent field metadata (% — %); the column + label functions are unaffected', SQLSTATE, SQLERRM;
END $meta$;

-- Backport the entities columns the always-run core path (§2–§8) references but very old tenants may
-- lack. dd_is_junction (§2, LANGUAGE sql) and the §6 entity-update trigger's WHEN (… entity_type …,
-- … managed …) clause validate these column references at CREATE time, so on a tenant without the
-- columns they fail with "column … does not exist". Adding them here (NOT NULL with the canonical
-- defaults) makes the rest of the file valid; existing rows take the defaults. label_parent (above),
-- entity_type and managed are the only non-ancient columns those sections touch — everything else
-- (table_name/id_column/label_column/format/reference_table/field_order) has existed for a long time.
ALTER TABLE entities ADD COLUMN IF NOT EXISTS entity_type TEXT NOT NULL DEFAULT 'unclassified';
ALTER TABLE entities ADD COLUMN IF NOT EXISTS managed BOOLEAN NOT NULL DEFAULT TRUE;

-- Stamp the pure RBAC junctions explicitly (entity_type='junction' is authoritative; see dd_is_junction).
-- permission_hierarchy needs the stamp because the structural heuristic misses it (origin is not an
-- audit-named/ctype column); the other three would be recognised by the heuristic but are stamped for
-- consistency. The backfill at the end then builds junction-shaped labels for them.
-- Resilient to enum drift: older tenants' valid_entity_type CHECK can predate 'junction' (causing
-- "violates check constraint valid_entity_type"). We first widen it to the current closed set
-- (widening only ADDS permitted values, so existing rows stay valid), then stamp. Both steps are
-- best-effort: if entity_type is absent or the stamp fails, we skip with a notice — dd_is_junction's
-- structural heuristic still recognises user_roles/role_permissions/user_permissions on its own
-- (only permission_hierarchy loses its junction shape without the stamp).
DO $junc$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='public' AND table_name='entities' AND column_name='entity_type') THEN
        BEGIN
            ALTER TABLE entities DROP CONSTRAINT IF EXISTS valid_entity_type;
            ALTER TABLE entities ADD CONSTRAINT valid_entity_type CHECK (entity_type IN
                ('operational_workflow', 'operational_record', 'catalog', 'junction', 'computed', 'unclassified'));
        EXCEPTION WHEN others THEN
            RAISE NOTICE 'label_fix: could not widen valid_entity_type (% — %); leaving constraint as-is', SQLSTATE, SQLERRM;
        END;
        BEGIN
            UPDATE entities SET entity_type = 'junction'
            WHERE table_name IN ('user_roles', 'role_permissions', 'user_permissions', 'permission_hierarchy')
              AND entity_type <> 'junction';
        EXCEPTION WHEN others THEN
            RAISE NOTICE 'label_fix: skipped junction stamping (% — %); dd_is_junction heuristic still recognises the RBAC pairing tables', SQLSTATE, SQLERRM;
        END;
    ELSE
        RAISE NOTICE 'label_fix: entities.entity_type absent — skipping junction stamping (dd_is_junction heuristic still recognises the RBAC junctions)';
    END IF;
END $junc$;

-- =====================================================
-- §2  SHARED PREDICATES
-- =====================================================
-- A field that carries a foreign key (and thus gets a <fk>_label companion). Used by BOTH the
-- generator and get_schema() so the advertised set never drifts from the built set.
CREATE OR REPLACE FUNCTION dd_is_fk_format(p_format TEXT)
RETURNS BOOLEAN
LANGUAGE sql IMMUTABLE
SET search_path = public
AS $$ SELECT p_format IN ('reference', 'parent') $$;

-- Junction recognition: entity_type='junction' is authoritative; until it is stamped, the fallback
-- heuristic recognises a pure pairing table — >=2 parent legs and every non-leg field is an
-- id/label/audit column. A status/rating/note payload field disqualifies it.
CREATE OR REPLACE FUNCTION dd_is_junction(p_table_name TEXT)
RETURNS BOOLEAN
LANGUAGE sql STABLE
SET search_path = public
AS $$
  SELECT CASE
    WHEN NOT EXISTS (SELECT 1 FROM entities WHERE table_name = p_table_name) THEN FALSE
    WHEN (SELECT entity_type FROM entities WHERE table_name = p_table_name) = 'junction' THEN TRUE
    ELSE COALESCE((
      SELECT count(*) FILTER (WHERE f.format = 'parent') >= 2
         AND count(*) FILTER (WHERE NOT (
                  f.format = 'parent'
               OR f.field_name = e.id_column
               OR f.field_name = e.label_column
               OR COALESCE(f.ctype, '') = 'audit'
               OR f.field_name IN ('created_at','updated_at','created_by','updated_by',
                                   'assigned_at','assigned_by','granted_at','granted_by')
             )) = 0
      FROM fields f
      CROSS JOIN entities e
      WHERE f.table_name = p_table_name AND e.table_name = p_table_name
    ), FALSE)
  END
$$;

-- The committed identity-spine parent of an entity (reference_table of its label_parent field), or ''
-- when it has no spine. Used by validate_label_parent() to walk the chain for cycles.
CREATE OR REPLACE FUNCTION dd_spine_parent(p_table_name TEXT)
RETURNS TEXT
LANGUAGE sql STABLE
SET search_path = public
AS $$
  SELECT COALESCE((
    SELECT f.reference_table
    FROM entities e
    JOIN fields f ON f.table_name = e.table_name AND f.field_name = NULLIF(e.label_parent, '')
    WHERE e.table_name = p_table_name
  ), '')
$$;

-- =====================================================
-- §3  GENERATOR — rebuild_entity_label_functions
-- =====================================================
-- (Re)generate _label and every <fk>_label for one entity from current metadata + physical columns.
-- Defensive: only references columns/tables that physically exist, so it produces valid SQL for any
-- entity shape. check_function_bodies is disabled around the CREATEs so order-independent /
-- mutually-referential generation never fails; the bodies are validated at first call instead.
CREATE OR REPLACE FUNCTION rebuild_entity_label_functions(p_table_name TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
    v_id_col      TEXT;
    v_label_col   TEXT;
    v_spine       TEXT;
    v_rowtype     TEXT;
    v_local       TEXT;
    v_body        TEXT;
    v_is_junction BOOLEAN;
    v_saved       TEXT;
    v_legs        TEXT[];
    v_parent_id   TEXT;
    v_spine_ref   TEXT;
    v_spine_fmt   TEXT;
    r             RECORD;
BEGIN
    -- Skip when entity metadata or the physical table is absent (drops / cascades / unmanaged).
    IF NOT EXISTS (SELECT 1 FROM entities WHERE table_name = p_table_name) THEN
        RETURN;
    END IF;
    v_rowtype := format('public.%I', p_table_name);
    IF to_regclass(v_rowtype) IS NULL THEN
        RETURN;
    END IF;

    SELECT id_column, label_column, NULLIF(label_parent, '')
      INTO v_id_col, v_label_col, v_spine
      FROM entities WHERE table_name = p_table_name;

    v_saved := current_setting('check_function_bodies');
    PERFORM set_config('check_function_bodies', 'off', true);

    -- Drop every label function currently bound to this row type (clears stale companions after a
    -- field rename / drop / format change before recreating the live set).
    FOR r IN
        SELECT p.oid::regprocedure AS sig
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND (p.proname = '_label' OR p.proname LIKE '%\_label')
          AND p.pronargs = 1
          AND p.proargtypes[0] = to_regtype(v_rowtype)::oid
    LOOP
        EXECUTE 'DROP FUNCTION IF EXISTS ' || r.sig;
    END LOOP;

    -- Local term: own label value with '' folded to NULL (so it contributes nothing).
    IF v_label_col IS NOT NULL AND EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = p_table_name AND column_name = v_label_col
    ) THEN
        v_local := format('NULLIF((rec.%I)::text, %L)', v_label_col, '');
    ELSE
        v_local := 'NULL::text';
    END IF;

    v_is_junction := dd_is_junction(p_table_name);

    IF v_is_junction THEN
        -- Junction: combine the parent legs (field order); no local term.
        v_legs := ARRAY[]::TEXT[];
        FOR r IN
            SELECT f.field_name, f.reference_table
            FROM fields f
            WHERE f.table_name = p_table_name
              AND f.format = 'parent'
              AND f.reference_table <> ''
              AND f.reference_table <> p_table_name
            ORDER BY f.field_order
        LOOP
            SELECT id_column INTO v_parent_id FROM entities WHERE table_name = r.reference_table;
            CONTINUE WHEN v_parent_id IS NULL;
            CONTINUE WHEN to_regclass(format('public.%I', r.reference_table)) IS NULL;
            CONTINUE WHEN NOT EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_schema='public' AND table_name=p_table_name AND column_name=r.field_name);
            v_legs := array_append(v_legs, format(
                '(SELECT public._label(p) FROM public.%I p WHERE p.%I = rec.%I)',
                r.reference_table, v_parent_id, r.field_name));
        END LOOP;

        IF array_length(v_legs, 1) >= 1 THEN
            v_body := format('SELECT NULLIF(concat_ws(%L, %s), %L)',
                             ' › ', array_to_string(v_legs, ', '), '');
        ELSE
            v_body := format('SELECT %s', v_local);
        END IF;

    ELSIF v_spine IS NOT NULL THEN
        -- Relational: parent._label › local, degrading to local when the spine does not resolve.
        SELECT format, reference_table INTO v_spine_fmt, v_spine_ref
          FROM fields WHERE table_name = p_table_name AND field_name = v_spine;
        IF dd_is_fk_format(v_spine_fmt)
           AND COALESCE(v_spine_ref, '') <> ''
           AND v_spine_ref <> p_table_name
           AND to_regclass(format('public.%I', v_spine_ref)) IS NOT NULL
           AND EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='public' AND table_name=p_table_name AND column_name=v_spine)
        THEN
            SELECT id_column INTO v_parent_id FROM entities WHERE table_name = v_spine_ref;
            v_body := format(
                'SELECT NULLIF(concat_ws(%L, (SELECT public._label(p) FROM public.%I p WHERE p.%I = rec.%I), %s), %L)',
                ' › ', v_spine_ref, v_parent_id, v_spine, v_local, '');
        ELSE
            v_body := format('SELECT %s', v_local);
        END IF;

    ELSE
        -- Root / self-identifying: composed label is the local label.
        v_body := format('SELECT %s', v_local);
    END IF;

    EXECUTE format(
        'CREATE OR REPLACE FUNCTION public._label(rec %s) RETURNS text '
        'LANGUAGE sql STABLE SET search_path = public AS $body$ %s $body$',
        v_rowtype, v_body);
    -- Computed-label functions are SECURITY INVOKER (default): keep them off PUBLIC but executable
    -- by the request role so they work as PostgREST computed columns and in nested _label calls.
    EXECUTE format('REVOKE EXECUTE ON FUNCTION public._label(%s) FROM PUBLIC', v_rowtype);
    EXECUTE format('GRANT EXECUTE ON FUNCTION public._label(%s) TO semantius_user', v_rowtype);

    -- <fk>_label companion for every reference/parent field (referenced record's composed label).
    FOR r IN
        SELECT f.field_name, f.reference_table
        FROM fields f
        WHERE f.table_name = p_table_name AND dd_is_fk_format(f.format) AND f.reference_table <> ''
        ORDER BY f.field_order
    LOOP
        SELECT id_column INTO v_parent_id FROM entities WHERE table_name = r.reference_table;
        CONTINUE WHEN v_parent_id IS NULL;
        CONTINUE WHEN to_regclass(format('public.%I', r.reference_table)) IS NULL;
        CONTINUE WHEN NOT EXISTS (SELECT 1 FROM information_schema.columns
            WHERE table_schema='public' AND table_name=p_table_name AND column_name=r.field_name);
        CONTINUE WHEN NOT EXISTS (SELECT 1 FROM information_schema.columns
            WHERE table_schema='public' AND table_name=r.reference_table AND column_name=v_parent_id);
        -- Collision-aware: if a REAL column already owns the <fk>_label name (e.g. a denormalised
        -- display column), it wins — skip the companion so the column is never shadowed by a function.
        CONTINUE WHEN EXISTS (SELECT 1 FROM information_schema.columns
            WHERE table_schema='public' AND table_name=p_table_name AND column_name = r.field_name || '_label');
        EXECUTE format(
            'CREATE OR REPLACE FUNCTION public.%I(rec %s) RETURNS text '
            'LANGUAGE sql STABLE SET search_path = public AS $body$ '
            'SELECT public._label(p) FROM public.%I p WHERE p.%I = rec.%I $body$',
            r.field_name || '_label', v_rowtype, r.reference_table, v_parent_id, r.field_name);
        EXECUTE format('REVOKE EXECUTE ON FUNCTION public.%I(%s) FROM PUBLIC', r.field_name || '_label', v_rowtype);
        EXECUTE format('GRANT EXECUTE ON FUNCTION public.%I(%s) TO semantius_user', r.field_name || '_label', v_rowtype);
    END LOOP;

    PERFORM set_config('check_function_bodies', v_saved, true);
END;
$fn$;

COMMENT ON FUNCTION rebuild_entity_label_functions(TEXT) IS
'Regenerates the _label and <fk>_label PostgREST computed-column functions for one entity from
current metadata + physical columns. SECURITY DEFINER (creates functions) but the generated
functions are SECURITY INVOKER so composed labels respect each caller''s row-level read permissions.';

-- =====================================================
-- §4  RESERVED FIELD-NAME NAMESPACE
-- =====================================================
-- Only the "_" prefix is reserved (protects the generated _label column and the system "_*"
-- namespace). The "_label" SUFFIX is NOT reserved. Privileged DD/migration code (BYPASSRLS) is exempt.
CREATE OR REPLACE FUNCTION reserve_field_namespace()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY INVOKER
SET search_path = public
AS $$
DECLARE v_priv BOOLEAN;
BEGIN
    SELECT rolbypassrls INTO v_priv FROM pg_roles WHERE rolname = current_user;
    IF COALESCE(v_priv, FALSE) THEN
        RETURN NEW;
    END IF;
    IF NEW.field_name ~ '^_' THEN
        RAISE EXCEPTION 'Field name "%" is reserved: names starting with "_" are reserved for generated/system columns (e.g. _label)', NEW.field_name
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS fields_reserve_namespace_trigger ON fields;
CREATE TRIGGER fields_reserve_namespace_trigger
    BEFORE INSERT OR UPDATE OF field_name ON fields
    FOR EACH ROW
    EXECUTE FUNCTION reserve_field_namespace();

-- =====================================================
-- §5  label_parent VALIDATION  (acyclic, no self-reference)
-- =====================================================
CREATE OR REPLACE FUNCTION validate_label_parent()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_fmt  TEXT;
    v_ref  TEXT;
    v_cur  TEXT;
    v_hops INT := 0;
BEGIN
    IF COALESCE(NEW.label_parent, '') = '' THEN
        RETURN NEW;
    END IF;

    IF dd_is_junction(NEW.table_name) THEN
        RAISE EXCEPTION 'label_parent cannot be set on junction entity "%"', NEW.table_name
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT format, reference_table INTO v_fmt, v_ref
      FROM fields WHERE table_name = NEW.table_name AND field_name = NEW.label_parent;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'label_parent "%" is not a field of entity "%"', NEW.label_parent, NEW.table_name
            USING ERRCODE = 'check_violation';
    END IF;

    IF NOT dd_is_fk_format(v_fmt) OR COALESCE(v_ref, '') = '' THEN
        RAISE EXCEPTION 'label_parent "%" on "%" must name a reference/parent field', NEW.label_parent, NEW.table_name
            USING ERRCODE = 'check_violation';
    END IF;

    IF v_ref = NEW.table_name THEN
        RAISE EXCEPTION 'label_parent "%" must not be self-referential (the identity spine must be acyclic)', NEW.label_parent
            USING ERRCODE = 'check_violation';
    END IF;

    IF dd_is_junction(v_ref) THEN
        RAISE EXCEPTION 'label_parent "%" must not target junction entity "%"', NEW.label_parent, v_ref
            USING ERRCODE = 'check_violation';
    END IF;

    -- Walk the committed spine chain from the target; returning to this entity is a cycle.
    v_cur := v_ref;
    WHILE COALESCE(v_cur, '') <> '' AND v_hops < 64 LOOP
        IF v_cur = NEW.table_name THEN
            RAISE EXCEPTION 'label_parent on "%" via "%" would create a cycle in the identity spine', NEW.table_name, NEW.label_parent
                USING ERRCODE = 'check_violation';
        END IF;
        v_cur := dd_spine_parent(v_cur);
        v_hops := v_hops + 1;
    END LOOP;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS validate_label_parent_trigger ON entities;
CREATE TRIGGER validate_label_parent_trigger
    BEFORE INSERT OR UPDATE OF label_parent ON entities
    FOR EACH ROW
    EXECUTE FUNCTION validate_label_parent();

-- =====================================================
-- §6  LIFECYCLE WIRING  (zzz_ names → fire AFTER the structural DD triggers)
-- =====================================================
CREATE OR REPLACE FUNCTION dd_label_fn_sync_entity()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF TG_OP = 'UPDATE' AND OLD.table_name IS DISTINCT FROM NEW.table_name THEN
        -- Table rename: rebuild self under the new name, and every entity whose generated bodies
        -- hard-code the old name (reference_table already cascaded to the new name by then).
        PERFORM rebuild_entity_label_functions(NEW.table_name);
        PERFORM rebuild_entity_label_functions(s.t)
          FROM (SELECT DISTINCT table_name AS t FROM fields WHERE reference_table = NEW.table_name) s;
    ELSE
        PERFORM rebuild_entity_label_functions(NEW.table_name);
    END IF;
    RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION dd_label_fn_sync_field()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    PERFORM rebuild_entity_label_functions(COALESCE(NEW.table_name, OLD.table_name));
    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS zzz_label_fn_entity_insert_trigger ON entities;
CREATE TRIGGER zzz_label_fn_entity_insert_trigger
    AFTER INSERT ON entities
    FOR EACH ROW
    EXECUTE FUNCTION dd_label_fn_sync_entity();

DROP TRIGGER IF EXISTS zzz_label_fn_entity_update_trigger ON entities;
CREATE TRIGGER zzz_label_fn_entity_update_trigger
    AFTER UPDATE ON entities
    FOR EACH ROW
    WHEN (OLD.table_name   IS DISTINCT FROM NEW.table_name
       OR OLD.label_parent IS DISTINCT FROM NEW.label_parent
       OR OLD.entity_type  IS DISTINCT FROM NEW.entity_type
       OR OLD.label_column IS DISTINCT FROM NEW.label_column
       OR OLD.managed      IS DISTINCT FROM NEW.managed)
    EXECUTE FUNCTION dd_label_fn_sync_entity();

DROP TRIGGER IF EXISTS zzz_label_fn_field_insert_trigger ON fields;
CREATE TRIGGER zzz_label_fn_field_insert_trigger
    AFTER INSERT ON fields
    FOR EACH ROW
    EXECUTE FUNCTION dd_label_fn_sync_field();

DROP TRIGGER IF EXISTS zzz_label_fn_field_delete_trigger ON fields;
CREATE TRIGGER zzz_label_fn_field_delete_trigger
    AFTER DELETE ON fields
    FOR EACH ROW
    EXECUTE FUNCTION dd_label_fn_sync_field();

DROP TRIGGER IF EXISTS zzz_label_fn_field_update_trigger ON fields;
CREATE TRIGGER zzz_label_fn_field_update_trigger
    AFTER UPDATE ON fields
    FOR EACH ROW
    WHEN (OLD.field_name      IS DISTINCT FROM NEW.field_name
       OR OLD.format          IS DISTINCT FROM NEW.format
       OR OLD.reference_table IS DISTINCT FROM NEW.reference_table)
    EXECUTE FUNCTION dd_label_fn_sync_field();

-- =====================================================
-- §7  GRANTS
-- =====================================================
REVOKE EXECUTE ON FUNCTION rebuild_entity_label_functions(TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION reserve_field_namespace() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION validate_label_parent() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION dd_label_fn_sync_entity() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION dd_label_fn_sync_field() FROM PUBLIC;
-- Pure predicates: off PUBLIC but available to the request role.
REVOKE EXECUTE ON FUNCTION dd_is_fk_format(TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION dd_is_junction(TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION dd_spine_parent(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION dd_is_fk_format(TEXT) TO semantius_user;
GRANT EXECUTE ON FUNCTION dd_is_junction(TEXT) TO semantius_user;
GRANT EXECUTE ON FUNCTION dd_spine_parent(TEXT) TO semantius_user;

-- =====================================================
-- §8  v0_label_fix — backfill entry point
-- =====================================================
-- (Re)generates _label and every <fk>_label for ALL entities from current metadata, returning the
-- number of entities processed. Order-independent (check_function_bodies is off per build inside
-- rebuild_entity_label_functions). Idempotent and safe to re-run at any time. The migration calls it
-- below; it also remains callable on demand: SELECT public.v0_label_fix();
CREATE OR REPLACE FUNCTION v0_label_fix()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    r       RECORD;
    v_count INTEGER := 0;
BEGIN
    FOR r IN SELECT table_name FROM entities ORDER BY table_name LOOP
        PERFORM rebuild_entity_label_functions(r.table_name);
        v_count := v_count + 1;
    END LOOP;
    RAISE NOTICE 'v0_label_fix: rebuilt composed-label functions for % entities', v_count;
    RETURN v_count;
END;
$$;

COMMENT ON FUNCTION v0_label_fix() IS
'Self-heal entry point: (re)generates the _label and <fk>_label computed-column functions for every
entity by calling rebuild_entity_label_functions across the catalog. Idempotent; returns the entity
count. Use to repair tenants where the composed-label layer is missing or stale.';

REVOKE EXECUTE ON FUNCTION v0_label_fix() FROM PUBLIC;

-- =====================================================
-- §9  GET_SCHEMA — advertise _label / <fk>_label in properties
-- =====================================================
-- Re-emit of build_schema_for_table from 0080_public_functions.sql so broken tenants' get_schema
-- surfaces the derived columns as ordinary `properties` entries (ctype _label / fk_label). Uses the
-- shared dd_is_fk_format predicate (created in §2) and entities.label_parent (added in §1).
--
-- GUARDED: a tenant can be old enough to predate columns this function reads (singular_label_parent,
-- is_nullable, …) or the is_core→ctype merge. Replacing the function on such a tenant would NOT fail
-- at paste time (plpgsql plans column refs lazily) — it would silently break get_schema at runtime.
-- So we only re-emit when the schema is compatible (required columns present AND a 'core' ctype row
-- exists, proving the post-merge schema); otherwise we skip with a notice. The _label / <fk>_label
-- columns still work via select=_label regardless of whether get_schema advertises them.
DO $bsft_guard$
BEGIN
    IF NOT (
         EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='fields' AND column_name='singular_label_parent')
     AND EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='fields' AND column_name='plural_label_parent')
     AND EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='fields' AND column_name='cube_type')
     AND EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='fields' AND column_name='unique_value')
     AND EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='fields' AND column_name='input_type_rule')
     AND EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='fields' AND column_name='is_nullable')
     AND EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='fields' AND column_name='relationship_label')
     AND EXISTS (SELECT 1 FROM fields WHERE ctype = 'core')
    ) THEN
        RAISE NOTICE 'label_fix: SKIPPED get_schema re-emit — this tenant''s schema predates columns/ctype it needs. The _label / <fk>_label columns still work via select=_label; only get_schema advertising is unchanged.';
        RETURN;
    END IF;

    EXECUTE $bsft$
CREATE OR REPLACE FUNCTION public.build_schema_for_table(p_table_name TEXT)
RETURNS JSON AS $$
DECLARE
    v_table_record RECORD;
    v_properties JSON;
    v_required_fields JSON;
    v_children JSON;
    v_result JSON;
    v_cache_version TEXT;
    v_db_version    TEXT;
BEGIN
    PERFORM rbac.uid();

    SELECT * INTO v_table_record
    FROM entities
    WHERE table_name = p_table_name;

    -- Permission gate + existence-hiding (b9). build_schema_for_table is GRANTed to the request
    -- role and reachable directly as /rpc/build_schema_for_table, so it must apply the SAME
    -- view_permission check + existence-hiding as get_schema()/get_schemas() rather than trusting
    -- callers — otherwise any request-role caller reads any table's full schema (including its
    -- select_rule logic) by calling this helper directly and skipping the wrappers. A missing
    -- table and a permission-denied table raise the IDENTICAL undefined_table error so existence
    -- cannot be probed. The four in-tree callers already pre-check, so the gate is redundant (and
    -- harmless) for them.
    IF NOT FOUND THEN
        SELECT value INTO v_cache_version FROM _settings WHERE name = 'cache_version';
        SELECT value INTO v_db_version    FROM _settings WHERE name = 'db_version';
        RAISE EXCEPTION 'Table "%" not found in entities', p_table_name
            USING ERRCODE = 'undefined_table',
                  DETAIL = json_build_object('cache_current', v_cache_version IS NOT NULL AND v_db_version IS NOT NULL AND v_cache_version >= v_db_version)::text;
    END IF;

    IF NOT rbac.has_permission(v_table_record.view_permission) THEN
        SELECT value INTO v_cache_version FROM _settings WHERE name = 'cache_version';
        SELECT value INTO v_db_version    FROM _settings WHERE name = 'db_version';
        RAISE EXCEPTION 'Table "%" not found in tables metadata', p_table_name
            USING ERRCODE = 'undefined_table',
                  DETAIL = json_build_object('cache_current', v_cache_version IS NOT NULL AND v_db_version IS NOT NULL AND v_cache_version >= v_db_version)::text;
    END IF;

    -- Build properties object from fields
    -- Each field becomes a property with JSON Schema attributes
    WITH ordered_fields AS (
        SELECT 
            f.field_name,
            f.format,
            f.title,
            f.description,
            f.default_value,
            f.input_type,
            f.width,
            f.field_order,
            f.enum_values,
            f.reference_table,
            f.reference_delete_mode,
            f.ctype,
            f.searchable,
            f.cube_type,
            f.singular_label_parent,
            f.plural_label_parent,
            f.unique_value,
            f."precision",
            f.relationship_label,
            f.input_type_rule,
            -- Join with tables to get id_column and label_column when reference_table is set
            -- COALESCE to empty string is intentional: provides consistent output when referenced table
            -- doesn't exist or is missing columns. These fields are only added to JSON output when
            -- format='reference' and reference_table is not empty (see line ~245).
            COALESCE(t.id_column, '') AS reference_table_id_column,
            COALESCE(t.label_column, '') AS reference_table_label_column,
            COALESCE(t.singular_label, '') AS reference_table_singular_label,
            COALESCE(t.plural_label, '') AS reference_table_plural_label
        FROM fields f
        LEFT JOIN entities t ON f.reference_table = t.table_name
        WHERE f.table_name = p_table_name
        ORDER BY f.field_order
    ),
    properties_with_defaults AS (
        SELECT 
            field_name,
            field_order,
            (jsonb_build_object(
                'type', CASE
                    WHEN format IN ('reference', 'parent') AND reference_table IN ('entities', 'fields')
                    THEN to_jsonb('string'::text)
                    ELSE format_to_json_type(format)
                END,
                'title', title,
                'description', description,
                'inputMode', input_type,
                'width', width,
                'field_order', field_order
            ) || 
            -- Add ctype field if present
            CASE 
                WHEN ctype IS NOT NULL AND ctype != ''
                THEN jsonb_build_object('ctype', ctype)
                ELSE '{}'::jsonb
            END ||
            -- Add is_core field — derived from ctype (is_core column was dropped; core = ctype<>'')
            jsonb_build_object('is_core', (coalesce(ctype, '') <> '')) ||
            -- Add searchable field
            jsonb_build_object('searchable', searchable) ||
            -- Add cube_type field
            jsonb_build_object('cube_type', cube_type) ||
            -- Add unique_value field
            jsonb_build_object('unique_value', unique_value) ||
            -- Add precision only for number formats
            CASE
                WHEN format_to_json_type(format)::text = '"number"'
                THEN jsonb_build_object('precision', "precision")
                ELSE '{}'::jsonb
            END ||
            -- Add input_type_rule only when a non-empty JsonLogic rule is set
            CASE
                WHEN input_type_rule IS NOT NULL AND input_type_rule != '{}'::jsonb
                THEN jsonb_build_object('input_type_rule', input_type_rule)
                ELSE '{}'::jsonb
            END ||
            -- Add format field only for string-based formats (email, url, etc), not for type mappers (int32, float, etc) or enum
            CASE 
                WHEN format IS NOT NULL 
                     AND format != '' 
                     AND format NOT IN ('int32', 'int64', 'integer', 'float', 'double', 'number', 'boolean', 'object', 'array', 'null', 'enum')
                THEN jsonb_build_object('format', format)
                ELSE '{}'::jsonb
            END ||
            -- Add enum field if enum_values is present
            CASE 
                WHEN enum_values IS NOT NULL AND jsonb_array_length(enum_values) > 0
                THEN jsonb_build_object('enum', effective_enum_values(input_type, enum_values))
                ELSE '{}'::jsonb
            END ||
            -- Add reference_table field if format is 'reference' or 'parent'
            CASE 
                WHEN format IN ('reference', 'parent') AND reference_table != ''
                THEN jsonb_build_object(
                    'reference_table', reference_table,
                    'reference_delete_mode', reference_delete_mode,
                    'relationship_label', relationship_label,
                    'reference_table_id_column', reference_table_id_column,
                    'reference_table_label_column', reference_table_label_column,
                    'reference_table_singular_label', reference_table_singular_label,
                    'reference_table_plural_label', reference_table_plural_label
                )
                ELSE '{}'::jsonb
            END ||
            -- Add singular_label_parent / plural_label_parent for parent fields when set
            CASE
                WHEN format = 'parent' AND singular_label_parent != ''
                THEN jsonb_build_object(
                    'singular_label_parent', singular_label_parent,
                    'plural_label_parent', plural_label_parent
                )
                ELSE '{}'::jsonb
            END ||
            -- Add default field separately to handle type conversion properly
            CASE
                -- Enum: use effective default (first value when required without explicit default, else '')
                WHEN format = 'enum' THEN
                    jsonb_build_object('default', effective_enum_default(default_value, input_type, enum_values))
                WHEN default_value IS NOT NULL AND trim(default_value) != '' THEN
                    CASE
                        -- Special case: reference/parent to entities/fields are string-typed
                        WHEN format IN ('reference', 'parent') AND reference_table IN ('entities', 'fields')
                        THEN jsonb_build_object('default', trim(both '''' from default_value))
                        WHEN format_to_json_type(format)::text = '"integer"' THEN jsonb_build_object('default', (default_value::INTEGER))
                        WHEN format_to_json_type(format)::text = '"number"' THEN jsonb_build_object('default', (default_value::NUMERIC))
                        WHEN format_to_json_type(format)::text = '"boolean"' THEN jsonb_build_object('default', (default_value::BOOLEAN))
                        WHEN format_to_json_type(format)::text IN ('"object"', '"array"') THEN jsonb_build_object('default', default_value::jsonb)
                        -- For strings, trim quotes if present (handles SQL literal strings like 'active')
                        ELSE jsonb_build_object('default', trim(both '''' from default_value))
                    END
                -- Special case: reference/parent to entities/fields get empty string default
                WHEN format IN ('reference', 'parent') AND reference_table IN ('entities', 'fields')
                THEN jsonb_build_object('default', '')
                -- For string types without explicit default, add empty string default
                WHEN format_to_json_type(format)::text = '"string"' THEN jsonb_build_object('default', '')
                -- For JSON types without explicit default, add empty object default
                WHEN format = 'json' THEN jsonb_build_object('default', '{}'::jsonb)
                ELSE '{}'::jsonb
            END) AS property_value
        FROM ordered_fields
    ),
    -- Derived composed-label columns are surfaced as ORDINARY properties, discriminated only by
    -- ctype (_label / fk_label) and ordered so each <fk>_label sits immediately after its FK. They
    -- are read-only computed columns (writable:false) and absent from the fields catalog / read_field.
    label_props AS (
        SELECT
            '_label'::text AS field_name,
            (COALESCE((SELECT field_order FROM fields
                       WHERE table_name = p_table_name AND ctype = 'label'
                       ORDER BY field_order LIMIT 1), 1)::numeric * 1000 + 1) AS sort_order,
            jsonb_build_object(
                'type', 'string', 'format', 'text',
                'title', v_table_record.singular_label,
                'description', 'Composed, human-readable label folded from the parent chain',
                'inputMode', 'readonly', 'width', 'default',
                'field_order', COALESCE((SELECT field_order FROM fields
                                         WHERE table_name = p_table_name AND ctype = 'label'
                                         ORDER BY field_order LIMIT 1), 1),
                'ctype', '_label', 'is_core', false, 'searchable', false,
                'writable', false, 'selectable', true,
                'source', NULLIF(v_table_record.label_parent, '')
            ) AS property_value
        UNION ALL
        SELECT
            f.field_name || '_label',
            (f.field_order::numeric * 1000 + 1) AS sort_order,
            jsonb_build_object(
                'type', 'string', 'format', 'text',
                'title', f.title,
                'description', 'Composed label of the referenced '
                               || COALESCE(e2.singular_label, f.reference_table),
                'inputMode', 'readonly', 'width', 'default',
                'field_order', f.field_order,
                'ctype', 'fk_label', 'is_core', false, 'searchable', false,
                'writable', false, 'selectable', true,
                'reference_table', f.reference_table,
                'source', jsonb_build_object('field', f.field_name, 'reference_table', f.reference_table)
            )
        FROM fields f
        LEFT JOIN entities e2 ON e2.table_name = f.reference_table
        WHERE f.table_name = p_table_name
          AND public.dd_is_fk_format(f.format)
          AND f.reference_table <> ''
          -- collision-aware: a real column owning the <fk>_label name wins, so add no phantom
          AND NOT EXISTS (SELECT 1 FROM fields f2
                          WHERE f2.table_name = p_table_name
                            AND f2.field_name = f.field_name || '_label')
    ),
    all_props AS (
        SELECT field_name, (field_order::numeric * 1000) AS sort_order, property_value
        FROM properties_with_defaults
        UNION ALL
        SELECT field_name, sort_order, property_value FROM label_props
    )
    SELECT COALESCE(
        json_object_agg(field_name, property_value ORDER BY sort_order),
        '{}'::json
    )
    INTO v_properties
    FROM all_props;
    
    -- Build required fields array (fields where nullability is false based on format)
    -- Exclude the id_column since it's auto-generated and not required for INSERT
    -- Exclude created_at and updated_at since they are auto-maintained by triggers
    WITH required_fields AS (
        SELECT field_name, field_order
        FROM fields
        WHERE table_name = p_table_name
          AND is_nullable = FALSE
          AND field_name != v_table_record.id_column
          AND field_name NOT IN ('created_at', 'updated_at')
          AND default_value IS NULL
          AND format != 'json'
        ORDER BY field_order
    )
    SELECT COALESCE(
        json_agg(field_name),
        '[]'::json
    )
    INTO v_required_fields
    FROM required_fields;
    
    -- Get children (fields in other tables that reference this table with format='parent')
    v_children := public.get_schema_children(p_table_name);

    -- Build the final JSON Schema result. The derived _label / <fk>_label columns are now ordinary
    -- entries inside `properties` (marked by ctype _label / fk_label) — there is no separate list.
    v_result := json_build_object(
        '$schema', 'https://semantius.com/meta/sem-schema/v1',
        '$id', 'https://example.com/schemas/' || p_table_name || '.schema.json',
        'title', v_table_record.singular_label,
        'description', v_table_record.description,
        'table', row_to_json(v_table_record),
        'type', 'object',
        'properties', v_properties,
        'required', v_required_fields,
        'children', v_children,
        'additionalProperties', false
    );
    
    RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION public.build_schema_for_table IS
'Builds a schema JSON for a single table. Self-gating: applies the view_permission check with existence-hiding (raises the same undefined_table error for a missing table and for a permission-denied table), matching get_schema(). Used by get_schema()/get_schemas()/get_module_cubes()/get_user_cubes() for consistent output from a single implementation.';

-- Revoke default PUBLIC execute, then grant only to semantius_user
REVOKE EXECUTE ON FUNCTION public.build_schema_for_table(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.build_schema_for_table(TEXT) TO semantius_user;
    $bsft$;
    RAISE NOTICE 'label_fix: get_schema re-emit applied (build_schema_for_table now advertises _label / <fk>_label).';
END $bsft_guard$;

-- =====================================================
-- APPLY — rebuild composed-label functions for every entity on this tenant
-- =====================================================
SELECT public.v0_label_fix();
