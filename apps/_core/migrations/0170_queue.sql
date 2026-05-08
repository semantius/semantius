-- =====================================================
-- QUEUE SYSTEM
-- =====================================================
-- Provides managed message queues backed by pgmq.
--
-- Features:
--   1. queues entity: each row represents a pgmq queue
--   2. queue_table_events child entity: maps table DML events
--      to queues so that inserts/updates/deletes on managed tables
--      are automatically enqueued as messages
--   3. RPC functions: queue_read, queue_pop, queue_archive,
--      queue_delete for PostgREST consumers

-- =====================================================
-- STEP 1: Create the queues entity
-- =====================================================

INSERT INTO entities (
    table_name,
    singular,
    singular_label,
    plural_label,
    description,
    module_id,
    view_permission,
    edit_permission,
    id_column,
    label_column
)
VALUES (
    'queues',
    'queue',
    'Queue',
    'Queues',
    'Message queues backed by pgmq',
    1, -- _core module
    'admin',
    'admin',
    'id',
    'queue_name'
);

-- The label_column 'queue_name' is auto-created by the DD trigger.
-- Mark it as unique and required.
UPDATE fields SET unique_value = TRUE, input_type = 'required'
WHERE table_name = 'queues' AND field_name = 'queue_name';

-- Grant semantius_user access to pgmq schema (needed for RPC wrappers)
GRANT USAGE ON SCHEMA pgmq TO semantius_user;

-- =====================================================
-- STEP 2: Triggers on queues table
-- =====================================================
-- INSERT  -> pgmq.create(queue_name)
-- UPDATE  -> reject queue_name change
-- DELETE  -> pgmq.drop_queue(queue_name)

CREATE OR REPLACE FUNCTION queue_after_insert()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pgmq.create(NEW.queue_name);
    RETURN NEW;
END;
$$;

CREATE TRIGGER queue_after_insert_trigger
    AFTER INSERT ON queues
    FOR EACH ROW
    EXECUTE FUNCTION queue_after_insert();

CREATE OR REPLACE FUNCTION queue_before_update()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.queue_name IS DISTINCT FROM NEW.queue_name THEN
        RAISE EXCEPTION 'Cannot change queue_name after creation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER queue_before_update_trigger
    BEFORE UPDATE ON queues
    FOR EACH ROW
    EXECUTE FUNCTION queue_before_update();

CREATE OR REPLACE FUNCTION queue_before_delete()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pgmq.drop_queue(OLD.queue_name);
    RETURN OLD;
END;
$$;

CREATE TRIGGER queue_before_delete_trigger
    BEFORE DELETE ON queues
    FOR EACH ROW
    EXECUTE FUNCTION queue_before_delete();

-- =====================================================
-- STEP 3: Create queue_table_events child entity
-- =====================================================

INSERT INTO entities (
    table_name,
    singular,
    singular_label,
    plural_label,
    description,
    module_id,
    view_permission,
    edit_permission,
    id_column,
    label_column
)
VALUES (
    'queue_table_events',
    'queue_table_event',
    'Queue Table Event',
    'Queue Table Events',
    'Maps table DML events to queues',
    1, -- _core module
    'admin',
    'admin',
    'id',
    'event_name'
);

-- Pre-create table_name column as TEXT (entities.table_name is TEXT, not INTEGER)
ALTER TABLE queue_table_events ADD COLUMN IF NOT EXISTS table_name TEXT NOT NULL DEFAULT '';

INSERT INTO fields (table_name, field_name, title, format, is_pk, field_order, input_type, width, description, default_value, enum_values, ctype, reference_table, reference_delete_mode, relationship_label, unique_value)
VALUES
    ('queue_table_events', 'queue_id',      'Queue',         'parent',    FALSE,  5, 'default',  'default', 'Parent queue this event belongs to',           NULL, NULL,                                                          NULL, 'queues',   'cascade', 'has events', FALSE),
    ('queue_table_events', 'table_name',    'Table',         'reference', FALSE, 10, 'required', 'default', 'Table whose DML events are captured',          '',   NULL,                                                          NULL, 'entities', 'cascade', 'has queue events', TRUE),
    ('queue_table_events', 'event_handler', 'Event Handler', 'enum',      FALSE, 20, 'required', 'default', 'Which DML operations trigger a queue message', '',   '["insert", "update", "upsert", "delete", "change"]'::jsonb,  NULL, '',         '',        '', FALSE);

-- =====================================================
-- STEP 4: Triggers on queue_table_events
-- =====================================================
-- Reject table_name change on UPDATE.
-- On INSERT / DELETE, create or drop the per-table trigger function
-- that enqueues the record JSON into the parent queue.

CREATE OR REPLACE FUNCTION queue_event_before_update()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.table_name IS DISTINCT FROM NEW.table_name THEN
        RAISE EXCEPTION 'Cannot change table_name on a queue table event';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER queue_event_before_update_trigger
    BEFORE UPDATE ON queue_table_events
    FOR EACH ROW
    EXECUTE FUNCTION queue_event_before_update();

-- Helper: build the queue message with id_field and id_value
-- (record and old_record are omitted; id_field comes from entities.id_column)

CREATE OR REPLACE FUNCTION queue_build_record_json()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql AS $$
DECLARE
    v_queue_name TEXT;
    v_id_field TEXT;
    v_id_value JSONB;
    v_row_jsonb JSONB;
    v_msg JSONB;
BEGIN
    -- Find the queue_name and id_column via queue_table_events + queues + entities.
    -- Falls back to 'id' when the table is not registered in entities (e.g. non-managed tables).
    SELECT q.queue_name, COALESCE(e.id_column, 'id')
    INTO v_queue_name, v_id_field
    FROM queue_table_events qte
    JOIN queues q ON q.id = qte.queue_id
    LEFT JOIN entities e ON e.table_name = TG_TABLE_NAME
    WHERE qte.table_name = TG_TABLE_NAME
    LIMIT 1;

    IF v_queue_name IS NULL THEN
        RETURN COALESCE(NEW, OLD);
    END IF;

    -- Extract the id value preserving its native JSON type (number, text, etc.)
    IF TG_OP = 'DELETE' THEN
        v_row_jsonb := to_jsonb(OLD);
    ELSE
        v_row_jsonb := to_jsonb(NEW);
    END IF;
    v_id_value := v_row_jsonb -> v_id_field;

    v_msg := jsonb_build_object(
        'op', TG_OP,
        'ts', now(),
        'table', TG_TABLE_NAME,
        'id_field', v_id_field,
        'id_value', v_id_value
    );

    PERFORM pgmq.send(v_queue_name, v_msg);

    RETURN COALESCE(NEW, OLD);
END;
$$;

-- Manage event trigger creation / removal

CREATE OR REPLACE FUNCTION queue_event_after_insert()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql AS $$
DECLARE
    v_trigger_name TEXT;
    v_trigger_events TEXT;
    v_queue_name TEXT;
BEGIN
    -- Resolve the parent queue name
    SELECT q.queue_name INTO v_queue_name
    FROM queues q WHERE q.id = NEW.queue_id;

    IF v_queue_name IS NULL THEN
        RAISE EXCEPTION 'Parent queue not found for queue_id %', NEW.queue_id;
    END IF;

    -- Determine which trigger events to fire
    v_trigger_events := CASE NEW.event_handler
        WHEN 'insert' THEN 'INSERT'
        WHEN 'update' THEN 'UPDATE'
        WHEN 'upsert' THEN 'INSERT OR UPDATE'
        WHEN 'delete' THEN 'DELETE'
        WHEN 'change' THEN 'INSERT OR UPDATE OR DELETE'
    END;

    v_trigger_name := 'queue_' || v_queue_name || '_' || NEW.event_handler || '_on_' || NEW.table_name;

    -- Create the trigger on the target table
    EXECUTE format(
        'CREATE OR REPLACE TRIGGER %I
            AFTER %s ON %I
            FOR EACH ROW
            EXECUTE FUNCTION queue_build_record_json()',
        v_trigger_name,
        v_trigger_events,
        NEW.table_name
    );

    RETURN NEW;
END;
$$;

CREATE TRIGGER queue_event_after_insert_trigger
    AFTER INSERT ON queue_table_events
    FOR EACH ROW
    EXECUTE FUNCTION queue_event_after_insert();

CREATE OR REPLACE FUNCTION queue_event_after_delete()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql AS $$
DECLARE
    v_trigger_name TEXT;
    v_queue_name TEXT;
BEGIN
    -- Resolve the parent queue name
    SELECT q.queue_name INTO v_queue_name
    FROM queues q WHERE q.id = OLD.queue_id;

    IF v_queue_name IS NULL THEN
        -- Queue already deleted (cascade); nothing to clean up
        RETURN OLD;
    END IF;

    v_trigger_name := 'queue_' || v_queue_name || '_' || OLD.event_handler || '_on_' || OLD.table_name;

    -- Drop the trigger on the target table (ignore if missing)
    EXECUTE format(
        'DROP TRIGGER IF EXISTS %I ON %I',
        v_trigger_name,
        OLD.table_name
    );

    RETURN OLD;
END;
$$;

CREATE TRIGGER queue_event_after_delete_trigger
    AFTER DELETE ON queue_table_events
    FOR EACH ROW
    EXECUTE FUNCTION queue_event_after_delete();

-- Revoke public execute on trigger and helper functions
REVOKE EXECUTE ON FUNCTION queue_after_insert() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION queue_before_update() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION queue_before_delete() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION queue_event_before_update() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION queue_build_record_json() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION queue_event_after_insert() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION queue_event_after_delete() FROM PUBLIC;

-- =====================================================
-- STEP 5: RPC functions for PostgREST consumers
-- =====================================================

-- queue_read: read messages without removing them (visibility timeout)
CREATE OR REPLACE FUNCTION public.queue_read(
    p_queue_name TEXT,
    p_vt INTEGER DEFAULT 30,
    p_qty INTEGER DEFAULT 1
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_result JSONB;
BEGIN
    PERFORM rbac.uid();

    SELECT jsonb_agg(row_to_json(r))
    INTO v_result
    FROM pgmq.read(p_queue_name, p_vt, p_qty) r;

    RETURN COALESCE(v_result, '[]'::jsonb);
END;
$$;

COMMENT ON FUNCTION public.queue_read IS
'Reads messages from a pgmq queue with a visibility timeout (default 30s). Messages remain in the queue but become invisible to other readers for the specified duration.';

REVOKE EXECUTE ON FUNCTION public.queue_read(TEXT, INTEGER, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.queue_read(TEXT, INTEGER, INTEGER) TO semantius_user;

-- queue_pop: read and immediately delete a message
CREATE OR REPLACE FUNCTION public.queue_pop(
    p_queue_name TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_result JSONB;
BEGIN
    PERFORM rbac.uid();

    SELECT jsonb_agg(row_to_json(r))
    INTO v_result
    FROM pgmq.pop(p_queue_name) r;

    RETURN COALESCE(v_result, '[]'::jsonb);
END;
$$;

COMMENT ON FUNCTION public.queue_pop IS
'Pops (reads and deletes) a single message from a pgmq queue.';

REVOKE EXECUTE ON FUNCTION public.queue_pop(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.queue_pop(TEXT) TO semantius_user;

-- queue_archive: move a message to the archive table
CREATE OR REPLACE FUNCTION public.queue_archive(
    p_queue_name TEXT,
    p_msg_id BIGINT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_result BOOLEAN;
BEGIN
    PERFORM rbac.uid();

    SELECT pgmq.archive(p_queue_name, p_msg_id) INTO v_result;

    RETURN COALESCE(v_result, FALSE);
END;
$$;

COMMENT ON FUNCTION public.queue_archive IS
'Archives a message by moving it from the queue table to the archive table.';

REVOKE EXECUTE ON FUNCTION public.queue_archive(TEXT, BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.queue_archive(TEXT, BIGINT) TO semantius_user;

-- queue_delete: permanently delete a message
CREATE OR REPLACE FUNCTION public.queue_delete(
    p_queue_name TEXT,
    p_msg_id BIGINT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_result BOOLEAN;
BEGIN
    PERFORM rbac.uid();

    SELECT pgmq.delete(p_queue_name, p_msg_id) INTO v_result;

    RETURN COALESCE(v_result, FALSE);
END;
$$;

COMMENT ON FUNCTION public.queue_delete IS
'Permanently deletes a message from a pgmq queue.';

REVOKE EXECUTE ON FUNCTION public.queue_delete(TEXT, BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.queue_delete(TEXT, BIGINT) TO semantius_user;
