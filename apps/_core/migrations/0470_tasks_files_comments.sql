-- =====================================================
-- TASKS, FILES AND COMMENTS: what metadata does not say
-- =====================================================
-- The entities are 0460_tasks_files_comments.jsonc. Here: the size of a
-- file, which the database keeps, and a user's open tasks.

-- The size of a file's contents, in bytes. A BEFORE trigger rather than a
-- computed field: JsonLogic sees the bytea column as text and cannot measure
-- it. The name b_file_size places it after the key is assigned and before the
-- rules (the firing order in build_record_logic_trigger,
-- 0210_computed_validation.sql), so the rules see the size. On the root
-- table, so a file of an is_a subtype gets its size as well.
CREATE OR REPLACE FUNCTION common.file_size()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
    NEW.size := octet_length(NEW.content)::bigint;
    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION common.file_size() IS
'BEFORE INSERT OR UPDATE trigger b_file_size of files: sets size to the length of content in bytes.';

REVOKE EXECUTE ON FUNCTION common.file_size() FROM PUBLIC;

CREATE OR REPLACE TRIGGER b_file_size
    BEFORE INSERT OR UPDATE ON public.files
    FOR EACH ROW
    EXECUTE FUNCTION common.file_size();

-- The caller's open tasks, the universal inbox: the tasks assigned to the
-- caller, and those without an assignee that wait in the queue of one of the
-- caller's roles, unless snoozed until a time still to come. By due date, the
-- earliest first and the undated last, then by priority, the highest first.
-- SECURITY INVOKER, so the tasks' own row-level security applies and the
-- answer is never wider than a read of tasks. The two readers are sub-selects
-- the planner runs once per statement.
CREATE OR REPLACE FUNCTION public.my_tasks()
RETURNS SETOF public.tasks AS $$
    SELECT t.*
      FROM public.tasks t
     WHERE t.status = 'open'
       AND (t.assigned_user = (SELECT rbac.user_id())
            OR (t.assigned_user IS NULL AND t.assigned_role IN (SELECT unnest(rbac.user_role_ids()))))
       AND (t.snoozed_until IS NULL OR t.snoozed_until <= CURRENT_TIMESTAMP)
     ORDER BY t.due_at NULLS LAST, array_position(ARRAY['high', 'normal', 'low'], t.priority), t.id;
$$ LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public, pg_temp;

COMMENT ON FUNCTION public.my_tasks() IS
'The caller''s open tasks: assigned to the caller, or without an assignee in the queue of one of the caller''s roles, and not snoozed until a time to come; by due date, then by priority. SECURITY INVOKER, so the tasks'' row-level security applies.';

REVOKE EXECUTE ON FUNCTION public.my_tasks() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.my_tasks() TO semantius_user;
