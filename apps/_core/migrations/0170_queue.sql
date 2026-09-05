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

-- Per-queue authorization for the RPC consumers (release review S4), declared
-- as dictionary fields like entities.view_permission so the UI can manage them.
-- view_permission gates queue_read; manage_permission gates queue_pop,
-- queue_archive and queue_delete. Both default to admin and must name an
-- existing permission (queue_validate_permissions below).
INSERT INTO fields (table_name, field_name, title, format, is_pk, field_order, input_type, width, description, default_value, enum_values, ctype, reference_table, reference_delete_mode, relationship_label, unique_value)
VALUES
    ('queues', 'view_permission',   'View Permission',   'text', FALSE, 30, 'default', 'default', 'Permission required to read messages from this queue (queue_read). Readers see the table, id and operation of every table mapped to this queue.', 'admin', NULL, NULL, '', '', '', FALSE),
    ('queues', 'manage_permission', 'Manage Permission', 'text', FALSE, 40, 'default', 'default', 'Permission required to pop, archive or delete messages from this queue.', 'admin', NULL, NULL, '', '', '', FALSE);

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

COMMENT ON FUNCTION queue_after_insert() IS
'Trigger function that provisions the underlying pgmq queue (pgmq.create) when a row is inserted into the queues table.';

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

COMMENT ON FUNCTION queue_before_update() IS
'Trigger function that rejects any attempt to change queues.queue_name after creation (the name is immutable once the pgmq queue exists).';

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

COMMENT ON FUNCTION queue_before_delete() IS
'Trigger function that drops the underlying pgmq queue (pgmq.drop_queue) when a row is deleted from the queues table.';

CREATE TRIGGER queue_before_delete_trigger
    BEFORE DELETE ON queues
    FOR EACH ROW
    EXECUTE FUNCTION queue_before_delete();

CREATE OR REPLACE FUNCTION queue_validate_permissions()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT rbac.validate_permission_exists(NEW.view_permission) THEN
        RAISE EXCEPTION 'View permission "%" does not exist in permissions table', NEW.view_permission;
    END IF;

    IF NOT rbac.validate_permission_exists(NEW.manage_permission) THEN
        RAISE EXCEPTION 'Manage permission "%" does not exist in permissions table', NEW.manage_permission;
    END IF;

    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION queue_validate_permissions() IS
'Trigger function that rejects a queues row whose view_permission or manage_permission is not a registered permission name (the same rule entities apply to their permission columns).';

CREATE TRIGGER queue_validate_permissions_trigger
    BEFORE INSERT OR UPDATE ON queues
    FOR EACH ROW
    EXECUTE FUNCTION queue_validate_permissions();

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
        -- Allow when this is a cascade triggered by rename_dd_table()
        IF current_setting('dd.table_rename', TRUE) = OLD.table_name || ':' || NEW.table_name THEN
            RETURN NEW;
        END IF;
        RAISE EXCEPTION 'Cannot change table_name on a queue table event';
    END IF;
    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION queue_event_before_update() IS
'Trigger function that rejects changing queue_table_events.table_name on UPDATE (the mapping''s target table is immutable).';

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
    -- Messages are flushed in fixed windows rather than one array per statement.
    -- pgmq.send_batch takes a jsonb[], and an array is a single value bound by
    -- the 1 GB varlena limit: at roughly 190 bytes per message one array covers
    -- a few million rows and then the statement fails outright. Flushing keeps
    -- every array well under that bound, at the cost of one extra INSERT per
    -- window. It does not bound the trigger's memory: the transition table
    -- itself holds every affected row for the whole statement, in a tuplestore
    -- that spills past work_mem.
    c_batch_size CONSTANT INT := 1000;
    v_queue_name TEXT;
    v_id_field TEXT;
    v_event_type TEXT;
    v_msgs JSONB[] := ARRAY[]::JSONB[];
    v_msg JSONB;
BEGIN
    -- Find the queue_name, id_column, and event_handler via queue_table_events + queues + entities.
    -- Falls back to 'id' when the LEFT JOIN to entities returns no row (table not registered
    -- in the entity system). The entities.id_column column always has a value when the row exists.
    -- queue_table_events.table_name is unique, so at most one mapping can match.
    SELECT q.queue_name, COALESCE(e.id_column, 'id'), qte.event_handler
    INTO v_queue_name, v_id_field, v_event_type
    FROM queue_table_events qte
    JOIN queues q ON q.id = qte.queue_id
    LEFT JOIN entities e ON e.table_name = TG_TABLE_NAME
    WHERE qte.table_name = TG_TABLE_NAME
    LIMIT 1;

    IF v_queue_name IS NULL THEN
        RETURN NULL;
    END IF;

    -- new_rows and old_rows are the transition tables declared by the triggers
    -- below. They are ephemeral named relations, resolved from the query
    -- environment rather than through search_path, so they cannot be reached by
    -- a schema-qualified name. Each branch only ever executes under the trigger
    -- that declares the table it names: a DELETE trigger never reaches the
    -- new_rows statement and vice versa.
    --
    -- event_type is the mapping's event_handler, not TG_OP: a consumer
    -- subscribed to 'change' expects that label on every message, whichever DML
    -- statement produced it.
    IF TG_OP = 'DELETE' THEN
        FOR v_msg IN
            SELECT jsonb_build_object(
                       'op', TG_OP,
                       'ts', now(),
                       'table', TG_TABLE_NAME,
                       'id_field', v_id_field,
                       'id_value', to_jsonb(r) -> v_id_field,
                       'message_type', 'entity_event',
                       'event_type', v_event_type
                   )
            FROM old_rows r
        LOOP
            v_msgs := array_append(v_msgs, v_msg);
            IF array_length(v_msgs, 1) >= c_batch_size THEN
                PERFORM pgmq.send_batch(v_queue_name, v_msgs);
                v_msgs := ARRAY[]::JSONB[];
            END IF;
        END LOOP;
    ELSE
        FOR v_msg IN
            SELECT jsonb_build_object(
                       'op', TG_OP,
                       'ts', now(),
                       'table', TG_TABLE_NAME,
                       'id_field', v_id_field,
                       'id_value', to_jsonb(r) -> v_id_field,
                       'message_type', 'entity_event',
                       'event_type', v_event_type
                   )
            FROM new_rows r
        LOOP
            v_msgs := array_append(v_msgs, v_msg);
            IF array_length(v_msgs, 1) >= c_batch_size THEN
                PERFORM pgmq.send_batch(v_queue_name, v_msgs);
                v_msgs := ARRAY[]::JSONB[];
            END IF;
        END LOOP;
    END IF;

    -- A statement trigger also fires for a statement that touched no rows, and
    -- pgmq refuses an empty batch, so the tail flush is guarded rather than
    -- unconditional.
    --
    -- The single-message case takes pgmq.send instead: send_batch costs about
    -- 10 microseconds more than send for one message, which is the whole
    -- difference on a one-row write - the common shape for a REST caller. The
    -- batch is what pays from a handful of rows up.
    IF array_length(v_msgs, 1) = 1 THEN
        PERFORM pgmq.send(v_queue_name, v_msgs[1]);
    ELSIF array_length(v_msgs, 1) > 0 THEN
        PERFORM pgmq.send_batch(v_queue_name, v_msgs);
    END IF;

    RETURN NULL;
END;
$$;

-- Manage event trigger creation / removal

COMMENT ON FUNCTION queue_build_record_json() IS
'Statement-level AFTER trigger function (installed on target tables by queue_table_events) that serializes every affected record to JSON and enqueues them as pgmq messages on the mapped queue, in batches.';

CREATE OR REPLACE FUNCTION queue_event_after_insert()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql AS $$
DECLARE
    v_trigger_name TEXT;
    v_queue_name TEXT;
    v_event TEXT;
BEGIN
    -- Resolve the parent queue name
    SELECT q.queue_name INTO v_queue_name
    FROM queues q WHERE q.id = NEW.queue_id;

    IF v_queue_name IS NULL THEN
        RAISE EXCEPTION 'Parent queue not found for queue_id %', NEW.queue_id;
    END IF;

    -- One trigger per DML event, because PostgreSQL refuses a REFERENCING clause
    -- on a trigger defined for more than one event and the transition table is
    -- what makes the enqueue statement-level. So 'upsert' installs two triggers
    -- and 'change' three.
    --
    -- The name carries the event, not the handler:
    -- queue_<queue>_<event>_on_<table>. For a single-event handler the two words
    -- coincide. The name must end in _on_<table>, because 0140_dd_rename.sql
    -- renames these triggers by matching that suffix and swapping the new table
    -- name onto the end. The handler itself is not lost: it is read back from
    -- queue_table_events when a message is built.
    FOREACH v_event IN ARRAY (CASE NEW.event_handler
        WHEN 'insert' THEN ARRAY['INSERT']
        WHEN 'update' THEN ARRAY['UPDATE']
        WHEN 'upsert' THEN ARRAY['INSERT', 'UPDATE']
        WHEN 'delete' THEN ARRAY['DELETE']
        WHEN 'change' THEN ARRAY['INSERT', 'UPDATE', 'DELETE']
    END)
    LOOP
        v_trigger_name := 'queue_' || v_queue_name || '_' || lower(v_event) || '_on_' || NEW.table_name;

        -- DROP before CREATE, not CREATE OR REPLACE: a trigger of this name may
        -- survive an aborted install, and dropping first makes the install
        -- idempotent for the events this handler covers. It cannot repair a
        -- handler that changed in place - there is no AFTER UPDATE trigger on
        -- queue_table_events, so an event_handler edit reinstalls nothing.
        -- queue_event_after_delete compensates by dropping every event name
        -- rather than the handler's own.
        EXECUTE format('DROP TRIGGER IF EXISTS %I ON %I', v_trigger_name, NEW.table_name);
        EXECUTE format(
            'CREATE TRIGGER %I
                AFTER %s ON %I
                REFERENCING %s
                FOR EACH STATEMENT
                EXECUTE FUNCTION queue_build_record_json()',
            v_trigger_name,
            v_event,
            NEW.table_name,
            CASE WHEN v_event = 'DELETE' THEN 'OLD TABLE AS old_rows' ELSE 'NEW TABLE AS new_rows' END
        );
    END LOOP;

    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION queue_event_after_insert() IS
'Trigger function that installs one statement-level queue_build_record_json trigger per DML event on the mapped table when a queue_table_events mapping is inserted.';

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
    v_queue_name TEXT;
    v_event TEXT;
BEGIN
    -- Resolve the parent queue name
    SELECT q.queue_name INTO v_queue_name
    FROM queues q WHERE q.id = OLD.queue_id;

    IF v_queue_name IS NULL THEN
        -- Queue already deleted (cascade); nothing to clean up
        RETURN OLD;
    END IF;

    -- Every event name, not just the ones this handler covers: a mapping whose
    -- event_handler was narrowed after install still owns the triggers created
    -- for the wider set, and a mapping deleted without them leaves a table
    -- enqueuing to a queue it is no longer mapped to.
    FOREACH v_event IN ARRAY ARRAY['insert', 'update', 'delete']
    LOOP
        EXECUTE format(
            'DROP TRIGGER IF EXISTS %I ON %I',
            'queue_' || v_queue_name || '_' || v_event || '_on_' || OLD.table_name,
            OLD.table_name
        );
    END LOOP;

    -- The handler-named trigger from before the per-event split. Harmless when
    -- the handler is single-event (the loop above already dropped that name);
    -- necessary for 'upsert' and 'change', which never had a name of their own
    -- in the event set.
    EXECUTE format(
        'DROP TRIGGER IF EXISTS %I ON %I',
        'queue_' || v_queue_name || '_' || OLD.event_handler || '_on_' || OLD.table_name,
        OLD.table_name
    );

    RETURN OLD;
END;
$$;

COMMENT ON FUNCTION queue_event_after_delete() IS
'Trigger function that drops every queue_build_record_json trigger from the mapped table when a queue_table_events mapping is deleted.';

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
REVOKE EXECUTE ON FUNCTION queue_validate_permissions() FROM PUBLIC;

-- =====================================================
-- STEP 5: RPC functions for PostgREST consumers
-- =====================================================
-- Authorization (release review S4): every RPC resolves the queue through the
-- queues registry and requires the queue's view_permission (queue_read) or
-- manage_permission (queue_pop, queue_archive, queue_delete). Unregistered
-- names are refused. Callers without admin get the same 42501 for an
-- unregistered queue as for a denied one, so queue names cannot be
-- enumerated; admins get a clearer error. The request role never reaches the
-- pgmq tables directly (no table privileges), so these wrappers are the only
-- route to the messages and the check here is sufficient.

CREATE OR REPLACE FUNCTION public.queue_authorize(
    p_queue_name TEXT,
    p_manage BOOLEAN
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_view_permission TEXT;
    v_manage_permission TEXT;
BEGIN
    PERFORM rbac.uid();

    SELECT q.view_permission, q.manage_permission
    INTO v_view_permission, v_manage_permission
    FROM queues q
    WHERE q.queue_name = p_queue_name;

    IF NOT FOUND THEN
        IF rbac.has_permission('admin') THEN
            RAISE EXCEPTION 'Queue "%" is not registered', p_queue_name
                USING ERRCODE = 'undefined_object';
        END IF;
        RAISE EXCEPTION 'Permission denied for queue "%"', p_queue_name
            USING ERRCODE = 'insufficient_privilege';
    END IF;

    -- The columns are NOT NULL and validated, the fallback is belt and braces.
    PERFORM rbac.require_permission(
        COALESCE(NULLIF(trim(CASE WHEN p_manage THEN v_manage_permission ELSE v_view_permission END), ''), 'admin')
    );
END;
$$;

COMMENT ON FUNCTION public.queue_authorize(TEXT, BOOLEAN) IS
'Authorization gate for the queue RPCs: resolves p_queue_name through the queues registry and requires its view_permission (p_manage = false) or manage_permission (p_manage = true). Unregistered queues raise 42501 for non-admins and 42704 for admins. Internal: not granted to semantius_user, called only by the SECURITY DEFINER wrappers.';

REVOKE EXECUTE ON FUNCTION public.queue_authorize(TEXT, BOOLEAN) FROM PUBLIC;

-- queue_read: read messages without removing them (visibility timeout).
-- p_vt is clamped to 0..3600 seconds and p_qty to 1..100 so a single caller
-- cannot hide a whole queue for a day.
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
    v_vt INTEGER := LEAST(GREATEST(COALESCE(p_vt, 30), 0), 3600);
    v_qty INTEGER := LEAST(GREATEST(COALESCE(p_qty, 1), 1), 100);
BEGIN
    PERFORM rbac.uid();
    PERFORM public.queue_authorize(p_queue_name, FALSE);

    SELECT jsonb_agg(row_to_json(r))
    INTO v_result
    FROM pgmq.read(p_queue_name, v_vt, v_qty) r;

    RETURN COALESCE(v_result, '[]'::jsonb);
END;
$$;

COMMENT ON FUNCTION public.queue_read IS
'Reads messages from a registered pgmq queue with a visibility timeout (default 30s, clamped to 0..3600) and a batch size (default 1, clamped to 1..100). Requires the queue''s view_permission. Messages remain in the queue but become invisible to other readers for the specified duration.';

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
    PERFORM public.queue_authorize(p_queue_name, TRUE);

    SELECT jsonb_agg(row_to_json(r))
    INTO v_result
    FROM pgmq.pop(p_queue_name) r;

    RETURN COALESCE(v_result, '[]'::jsonb);
END;
$$;

COMMENT ON FUNCTION public.queue_pop IS
'Pops (reads and deletes) a single message from a registered pgmq queue. Requires the queue''s manage_permission.';

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
    PERFORM public.queue_authorize(p_queue_name, TRUE);

    SELECT pgmq.archive(p_queue_name, p_msg_id) INTO v_result;

    RETURN COALESCE(v_result, FALSE);
END;
$$;

COMMENT ON FUNCTION public.queue_archive IS
'Archives a message by moving it from the queue table to the archive table. Requires the queue''s manage_permission.';

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
    PERFORM public.queue_authorize(p_queue_name, TRUE);

    SELECT pgmq.delete(p_queue_name, p_msg_id) INTO v_result;

    RETURN COALESCE(v_result, FALSE);
END;
$$;

COMMENT ON FUNCTION public.queue_delete IS
'Permanently deletes a message from a registered pgmq queue. Requires the queue''s manage_permission.';

REVOKE EXECUTE ON FUNCTION public.queue_delete(TEXT, BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.queue_delete(TEXT, BIGINT) TO semantius_user;
