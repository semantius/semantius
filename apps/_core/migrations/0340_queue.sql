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
-- Repeatable. The entities are defined in 0320_queue.jsonc, their column
-- constraints in 0330_queue_setup.once.sql.

-- Grant semantius_user access to pgmq schema (needed for RPC wrappers)
GRANT USAGE ON SCHEMA pgmq TO semantius_user;

-- pgmq.convert_archive_partitioned builds three statements by concatenating
-- its argument, which pgmq.format_table_name keeps only `$`, `;`, `--` and `'`
-- out of. It runs with its caller's rights and nothing here calls it, so the
-- request role, which reaches pgmq through the usage above, does not need it.
REVOKE EXECUTE ON FUNCTION pgmq.convert_archive_partitioned(TEXT, TEXT, TEXT, INTEGER) FROM PUBLIC;

-- =====================================================
-- STEP 2: Triggers on queues table
-- =====================================================
-- INSERT  -> pgmq.create(queue_name)
-- UPDATE  -> reject queue_name change
-- DELETE  -> pgmq.drop_queue(queue_name)

CREATE OR REPLACE FUNCTION queue_after_insert()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql AS $$
BEGIN
    -- A queue name has the shape of a table name, ^[a-z_][a-z0-9_]*$, and at
    -- most 47 bytes. pgmq names the tables of a queue q_<name> and a_<name>,
    -- in lower case, and allows 47 characters, so two names that differ in
    -- case only would share their tables. The name also goes into the
    -- triggers that map a table to the queue and into the statements pgmq
    -- builds; with letters, digits and underscores only, no quote, comment
    -- marker, line break or backslash reaches any of them. pgmq itself accepts
    -- more, and is vendored as it is.
    IF NEW.queue_name !~ '^[a-z_][a-z0-9_]*$' OR octet_length(NEW.queue_name) > 47 THEN
        RAISE EXCEPTION 'Queue name ${queue} has to start with a lower-case letter or an underscore, contain only lower-case letters, digits and underscores, and be at most 47 bytes long'
            USING ERRCODE = '90505',
                  HINT = jsonb_build_object('queue', NEW.queue_name)::text;
    END IF;

    PERFORM pgmq.create(NEW.queue_name);
    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION queue_after_insert() IS
'Trigger function that provisions the underlying pgmq queue (pgmq.create) when a row is inserted into the queues table.';

CREATE OR REPLACE TRIGGER queue_after_insert_trigger
    AFTER INSERT ON queues
    FOR EACH ROW
    EXECUTE FUNCTION queue_after_insert();

CREATE OR REPLACE FUNCTION queue_before_update()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.queue_name IS DISTINCT FROM NEW.queue_name THEN
        RAISE EXCEPTION 'Cannot change queue_name after creation' USING ERRCODE = '90501';
    END IF;
    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION queue_before_update() IS
'Trigger function that rejects any attempt to change queues.queue_name after creation (the name is immutable once the pgmq queue exists).';

CREATE OR REPLACE TRIGGER queue_before_update_trigger
    BEFORE UPDATE ON queues
    FOR EACH ROW
    EXECUTE FUNCTION queue_before_update();

CREATE OR REPLACE FUNCTION queue_before_delete()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql AS $$
BEGIN
    -- The mappings go first, while this row still exists: queue_event_after_delete
    -- needs the queue name to drop the triggers on the mapped tables, and the
    -- ON DELETE CASCADE would remove them only after the name is gone.
    DELETE FROM queue_table_events WHERE queue_id = OLD.id;
    PERFORM pgmq.drop_queue(OLD.queue_name);
    RETURN OLD;
END;
$$;

COMMENT ON FUNCTION queue_before_delete() IS
'Trigger function that, when a row is deleted from the queues table, deletes its queue_table_events mappings (which drops their triggers) and then the underlying pgmq queue.';

CREATE OR REPLACE TRIGGER queue_before_delete_trigger
    BEFORE DELETE ON queues
    FOR EACH ROW
    EXECUTE FUNCTION queue_before_delete();

-- =====================================================
-- STEP 4: Triggers on queue_table_events
-- =====================================================
-- Reject table_name change on UPDATE.
-- On INSERT, install the statement triggers on the mapped table that enqueue
-- its records into the parent queue; on DELETE, drop them; on a change of
-- event_handler or queue_id, drop the old queue's and install the new set.

CREATE OR REPLACE FUNCTION queue_event_before_update()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.table_name IS DISTINCT FROM NEW.table_name THEN
        -- Allow when this is a cascade triggered by rename_dd_table()
        IF current_setting('dd.table_rename', TRUE) = OLD.table_name || ':' || NEW.table_name THEN
            RETURN NEW;
        END IF;
        RAISE EXCEPTION 'Cannot change table_name on a queue table event' USING ERRCODE = '90502';
    END IF;
    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION queue_event_before_update() IS
'Trigger function that rejects changing queue_table_events.table_name on UPDATE (the mapping''s target table is immutable).';

CREATE OR REPLACE TRIGGER queue_event_before_update_trigger
    BEFORE UPDATE ON queue_table_events
    FOR EACH ROW
    EXECUTE FUNCTION queue_event_before_update();

-- Helper: build one queue message per affected record. A message carries the
-- operation, the timestamp, the table, the id column and the id value - enough
-- to fetch the record, never the record itself, so a queue reader needs its own
-- permission to read it. id_field comes from entities.id_column.

CREATE OR REPLACE FUNCTION queue_build_record_json()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = public, pg_temp
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
    -- Find the queue_name, id_column and event_handler via queue_table_events +
    -- queues + entities. queue_table_events.table_name references entities with
    -- a cascade, so the entity row exists for every mapping and the join is an
    -- inner one; id_column always has a value when the row exists.
    -- queue_table_events.table_name is unique, so at most one mapping can match.
    SELECT q.queue_name, e.id_column, qte.event_handler
    INTO v_queue_name, v_id_field, v_event_type
    FROM queue_table_events qte
    JOIN queues q ON q.id = qte.queue_id
    JOIN entities e ON e.table_name = TG_TABLE_NAME
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
'Statement-level AFTER trigger function (installed on target tables by queue_table_events) that enqueues one pgmq message per affected record on the mapped queue, in batches. A message carries the operation, timestamp, table, id column and id value - never the record itself.';

-- The install and the drop are shared by the three trigger functions below:
-- a mapping that is inserted installs, one that is deleted drops, and one
-- whose event_handler or queue_id changes does both.

CREATE OR REPLACE FUNCTION queue_event_install_triggers(p_table_name TEXT, p_queue_id BIGINT, p_event_handler TEXT)
RETURNS VOID
SET search_path = public, pg_temp
LANGUAGE plpgsql AS $$
DECLARE
    v_trigger_name TEXT;
    v_queue_name TEXT;
    v_event TEXT;
    v_id_type TEXT;
BEGIN
    -- An is_a or has_a entity is a view over the tables that store the parts
    -- of its records, and a write to one record reaches several of them; the
    -- statement triggers below would see parts, not records.
    SELECT e.id_type INTO v_id_type FROM entities e WHERE e.table_name = p_table_name;
    IF v_id_type IN ('is_a', 'has_a') THEN
        RAISE EXCEPTION '${feature} is not available for ${id_type} entity ${table}'
            USING ERRCODE = '90249',
                  HINT = jsonb_build_object('feature', 'queue_table_events', 'id_type', v_id_type, 'table', p_table_name)::text;
    END IF;

    -- Resolve the parent queue name
    SELECT q.queue_name INTO v_queue_name
    FROM queues q WHERE q.id = p_queue_id;

    IF v_queue_name IS NULL THEN
        RAISE EXCEPTION 'Parent queue not found for queue_id ${queue_id}'
            USING ERRCODE = '90503',
                  HINT = jsonb_build_object('queue_id', p_queue_id)::text;
    END IF;

    -- One trigger per DML event, because PostgreSQL refuses a REFERENCING clause
    -- on a trigger defined for more than one event and the transition table is
    -- what makes the enqueue statement-level. So 'upsert' installs two triggers
    -- and 'change' three.
    --
    -- The name carries the event, not the handler:
    -- queue_<queue>_<event>_on_<table>. For a single-event handler the two words
    -- coincide. The name must end in _on_<table>, because 0170_dd_rename.sql
    -- renames these triggers by matching that suffix and swapping the new table
    -- name onto the end. The handler itself is not lost: it is read back from
    -- queue_table_events when a message is built.
    FOREACH v_event IN ARRAY (CASE p_event_handler
        WHEN 'insert' THEN ARRAY['INSERT']
        WHEN 'update' THEN ARRAY['UPDATE']
        WHEN 'upsert' THEN ARRAY['INSERT', 'UPDATE']
        WHEN 'delete' THEN ARRAY['DELETE']
        WHEN 'change' THEN ARRAY['INSERT', 'UPDATE', 'DELETE']
    END)
    LOOP
        v_trigger_name := 'queue_' || v_queue_name || '_' || lower(v_event) || '_on_' || p_table_name;

        -- A trigger name is cut at 63 bytes like any identifier, and a cut
        -- name no longer ends in _on_<table>: the rename of the table would
        -- leave the trigger under its old name, where the removal of the
        -- mapping, which spells the name with the new table, no longer finds
        -- it. reserve_table_namespace (0180_managed_enable.sql) refuses a
        -- rename under which a name of the mapping would not fit; a trigger
        -- of no mapping is renamed unchecked and can still be cut.
        IF octet_length(v_trigger_name) > 63 THEN
            RAISE EXCEPTION 'Queue ${queue} and table ${table} are too long together: the trigger name ${name} would not fit 63 bytes'
                USING ERRCODE = '90506',
                      HINT = jsonb_build_object('queue', v_queue_name, 'table', p_table_name,
                                                'name', v_trigger_name)::text;
        END IF;

        -- DROP before CREATE, not CREATE OR REPLACE: a trigger of this name may
        -- survive an aborted install, and dropping first makes the install
        -- idempotent for the events this handler covers. The triggers of the
        -- other events are gone already when a mapping is edited:
        -- queue_event_after_update drops the old queue's names first.
        EXECUTE format('DROP TRIGGER IF EXISTS %I ON %I', v_trigger_name, p_table_name);
        EXECUTE format(
            'CREATE TRIGGER %I
                AFTER %s ON %I
                REFERENCING %s
                FOR EACH STATEMENT
                EXECUTE FUNCTION queue_build_record_json()',
            v_trigger_name,
            v_event,
            p_table_name,
            CASE WHEN v_event = 'DELETE' THEN 'OLD TABLE AS old_rows' ELSE 'NEW TABLE AS new_rows' END
        );
    END LOOP;
END;
$$;

COMMENT ON FUNCTION queue_event_install_triggers(TEXT, BIGINT, TEXT) IS
'Installs one statement-level queue_build_record_json trigger per DML event the handler covers on the mapped table, named queue_<queue>_<event>_on_<table>. Refuses an is_a or has_a entity (90249) and a trigger name longer than 63 bytes (90506). Shared by queue_event_after_insert and queue_event_after_update.';

CREATE OR REPLACE FUNCTION queue_event_drop_triggers(p_table_name TEXT, p_queue_id BIGINT)
RETURNS VOID
SET search_path = public, pg_temp
LANGUAGE plpgsql AS $$
DECLARE
    v_queue_name TEXT;
    v_event TEXT;
BEGIN
    -- Resolve the parent queue name
    SELECT q.queue_name INTO v_queue_name
    FROM queues q WHERE q.id = p_queue_id;

    IF v_queue_name IS NULL THEN
        -- No queue row, so nothing names the triggers. A queue delete does not end
        -- here: queue_before_delete removes the mappings while the queue still exists.
        RETURN;
    END IF;

    -- Every event name, not just the ones the handler covers: an edited
    -- mapping drops the names of its old queue whatever its old handler
    -- installed. A trigger that outlives its mapping (its queue deleted while
    -- queue_before_delete is switched off, or one created by hand) finds the
    -- mapping of its table, not of its name. While the table is not mapped it
    -- enqueues nothing and costs a lookup on every write; once the table is
    -- mapped again, it sends its event to that mapping's queue, whether the
    -- mapping covers the event or not. A rename of the table renames it too,
    -- unchecked, so its name can be cut.
    FOREACH v_event IN ARRAY ARRAY['insert', 'update', 'delete']
    LOOP
        EXECUTE format(
            'DROP TRIGGER IF EXISTS %I ON %I',
            'queue_' || v_queue_name || '_' || v_event || '_on_' || p_table_name,
            p_table_name
        );
    END LOOP;
END;
$$;

COMMENT ON FUNCTION queue_event_drop_triggers(TEXT, BIGINT) IS
'Drops the three queue_build_record_json trigger names queue_<queue>_<event>_on_<table> of the queue from the mapped table, whichever of them exist. Does nothing when the queue row is gone. Shared by queue_event_after_delete and queue_event_after_update.';

CREATE OR REPLACE FUNCTION queue_event_after_insert()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM queue_event_install_triggers(NEW.table_name, NEW.queue_id, NEW.event_handler);
    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION queue_event_after_insert() IS
'Trigger function that installs one statement-level queue_build_record_json trigger per DML event on the mapped table when a queue_table_events mapping is inserted.';

CREATE OR REPLACE TRIGGER queue_event_after_insert_trigger
    AFTER INSERT ON queue_table_events
    FOR EACH ROW
    EXECUTE FUNCTION queue_event_after_insert();

CREATE OR REPLACE FUNCTION queue_event_after_update()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql AS $$
BEGIN
    -- The drop goes first: with the queue unchanged, the old and the new set
    -- share names, and a drop after the install would remove the new triggers.
    PERFORM queue_event_drop_triggers(OLD.table_name, OLD.queue_id);
    PERFORM queue_event_install_triggers(NEW.table_name, NEW.queue_id, NEW.event_handler);
    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION queue_event_after_update() IS
'Trigger function that reinstalls the queue_build_record_json triggers of a queue_table_events mapping whose event_handler or queue_id changed: it drops the names of the old queue and installs the set of the new handler and queue.';

-- Only a real change reinstalls: a save that writes the same values back, as
-- a form sending every column does, takes no lock on the mapped table.
CREATE OR REPLACE TRIGGER queue_event_after_update_trigger
    AFTER UPDATE OF event_handler, queue_id ON queue_table_events
    FOR EACH ROW
    WHEN (OLD.event_handler IS DISTINCT FROM NEW.event_handler OR OLD.queue_id IS DISTINCT FROM NEW.queue_id)
    EXECUTE FUNCTION queue_event_after_update();

CREATE OR REPLACE FUNCTION queue_event_after_delete()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM queue_event_drop_triggers(OLD.table_name, OLD.queue_id);
    RETURN OLD;
END;
$$;

COMMENT ON FUNCTION queue_event_after_delete() IS
'Trigger function that drops every queue_build_record_json trigger from the mapped table when a queue_table_events mapping is deleted.';

CREATE OR REPLACE TRIGGER queue_event_after_delete_trigger
    AFTER DELETE ON queue_table_events
    FOR EACH ROW
    EXECUTE FUNCTION queue_event_after_delete();

-- Revoke public execute on trigger and helper functions
REVOKE EXECUTE ON FUNCTION queue_after_insert() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION queue_before_update() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION queue_before_delete() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION queue_event_before_update() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION queue_build_record_json() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION queue_event_install_triggers(TEXT, BIGINT, TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION queue_event_drop_triggers(TEXT, BIGINT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION queue_event_after_insert() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION queue_event_after_update() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION queue_event_after_delete() FROM PUBLIC;

-- =====================================================
-- STEP 5: RPC functions for PostgREST consumers
-- =====================================================
-- Authorization: every RPC resolves the queue through the queues registry and
-- requires the queue's view_permission (queue_read) or manage_permission
-- (queue_pop, queue_archive, queue_delete). Unregistered names are refused.
-- A caller without admin gets SQLSTATE 42501 for an unregistered queue and for
-- one it may not use, but not the same answer: an unregistered queue gives
-- "Permission denied for queue ${queue}" with hint code 90105, a registered
-- one "Permission denied: ${permission} required" with 90101 and the
-- permission, from another CONTEXT, so the answer tells whether a queue name
-- is registered. An administrator gets 90504 for an unregistered queue. The
-- request role never reaches the pgmq tables directly (no table privileges),
-- so these wrappers are the only route to the messages and the check here is
-- sufficient.

CREATE OR REPLACE FUNCTION public.queue_authorize(
    p_queue_name TEXT,
    p_manage BOOLEAN
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
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
            RAISE EXCEPTION 'Queue ${queue} is not registered'
                USING ERRCODE = '90504',
                      HINT = jsonb_build_object('queue', p_queue_name)::text;
        END IF;
        RAISE EXCEPTION 'Permission denied for queue ${queue}'
            USING ERRCODE = 'insufficient_privilege',
                  HINT = jsonb_build_object('code', '90105', 'queue', p_queue_name)::text;
    END IF;

    -- The columns are NOT NULL and validated, the fallback is belt and braces.
    PERFORM rbac.require_permission(
        COALESCE(NULLIF(trim(CASE WHEN p_manage THEN v_manage_permission ELSE v_view_permission END), ''), 'admin')
    );
END;
$$;

COMMENT ON FUNCTION public.queue_authorize(TEXT, BOOLEAN) IS
'Authorization gate for the queue RPCs: resolves p_queue_name through the queues registry and requires its view_permission (p_manage = false) or manage_permission (p_manage = true). Unregistered queues raise 42501 with hint code 90105 for non-admins and 90504 for admins. Internal: not granted to semantius_user, called only by the SECURITY DEFINER wrappers.';

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
SET search_path = public, pg_temp
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
SET search_path = public, pg_temp
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
SET search_path = public, pg_temp
AS $$
DECLARE
    v_result BOOLEAN;
BEGIN
    PERFORM rbac.uid();
    PERFORM public.queue_authorize(p_queue_name, TRUE);

    v_result := pgmq.archive(p_queue_name, p_msg_id);

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
SET search_path = public, pg_temp
AS $$
DECLARE
    v_result BOOLEAN;
BEGIN
    PERFORM rbac.uid();
    PERFORM public.queue_authorize(p_queue_name, TRUE);

    v_result := pgmq.delete(p_queue_name, p_msg_id);

    RETURN COALESCE(v_result, FALSE);
END;
$$;

COMMENT ON FUNCTION public.queue_delete IS
'Permanently deletes a message from a registered pgmq queue. Requires the queue''s manage_permission.';

REVOKE EXECUTE ON FUNCTION public.queue_delete(TEXT, BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.queue_delete(TEXT, BIGINT) TO semantius_user;
