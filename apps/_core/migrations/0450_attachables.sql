-- =====================================================
-- ATTACHABLE ENTITIES
-- =====================================================
-- An attachable entity's records are attached to records of other entities,
-- its targets: comments, files and tasks on an order or a customer. Whether
-- and how an entity is attachable is a property of the entity
-- (entities.attach_mode); the target entities it may be attached to are the
-- rows of entity_attachables. A target record is named by its record
-- reference (<table_name>:<key>, 0160_dd_functions.sql), so a target can be a
-- record of any entity and any key type.
--
--   attach_mode   target(s)                               view and edit
--   single        exactly one, in attached_to             follow the target
--   owned_shared  one owner in attached_to, further       follow the owner
--                 targets in <entity>_links that only
--                 show it
--   multiple      any number of equal targets in          the entity's own
--                 <entity>_links, or none                 permissions
--
-- What the dictionary keeps for it, all generated from the catalog:
--   attached_to               the field of a single or owned_shared entity, and
--                             of its link entity: text, required, ctype
--                             attached_to (a core marker), set on insert and
--                             never changed, indexed with text_pattern_ops so a
--                             lookup by a table's references can use it
--   <entity>_links            the link entity of an owned_shared or multiple
--                             entity, entities.link_of = the entity: its
--                             <entity>_id (a parent, cascading) and attached_to,
--                             unique together (<link>_attached_to_unique);
--                             maintained by the dictionary alone
--   d_attach_check            the attach step (common.attach_check) on the
--                             attachable table and its link table
--   attached_del/_trc         the delete and truncate triggers of every target
--                             (common.attached_step), and common.attached_<t>,
--                             its delete step (dd_build_attached_triggers)
--   the policies              built by build_select_rule_policy
--                             (0210_computed_validation.sql) from
--                             dd_attach_policy_terms
--   attached_to_label         the target's composed label
--                             (rebuild_entity_label_functions,
--                             0180_managed_enable.sql)
-- dd_attach_refresh rebuilds what depends on the targets and modes whenever
-- they change.
--
-- An is_a family is attachable through its root: the root declares the mode,
-- attached_to lives on the root table, whose triggers fire for every subtype
-- record, and the link entity references the root. A target listed as a base
-- admits the records of its is_a subtypes.
--
-- An attach and the changes that would leave it without a target or a mode
-- are kept apart by locks, at READ COMMITTED, the default and PostgREST's
-- level: the attach step locks the target row and the row of
-- entity_attachables that admits it FOR KEY SHARE, so a delete of the target
-- and a switch-off wait for the attach to commit and then find the attachment;
-- a change of the attach mode locks the entity's table before it looks for
-- records. pgdocker/pg-attach-race.sh
-- runs these races. A delete or a switch-off at REPEATABLE READ may still miss
-- an attachment committed just before it.

-- =====================================================
-- The settings of an attachable entity
-- =====================================================
-- What an entity may be, checked before anything is built. An attachable
-- entity is a managed entity whose table the dictionary builds (91001), not
-- is_a or has_a, which keep their records in a base: the root declares the
-- mode for its family (91002), and without a computed key (91003). Its name
-- has at most 22 bytes, so its link field <entity>_id on <entity>_links stays
-- within the field-name limit (reserve_field_name_length, 91004). A link
-- entity is refused by protect_link_entity below. The attach mode changes
-- only while the entity has no records: its records keep their targets in
-- attached_to or in the link entity, and a change would leave them without
-- (91005). A listed target stays managed: its delete step lives on its table
-- (91006). A single or owned_shared entity gets the field attached_to from
-- the dictionary, so a field of that name it already has is refused (91022).
-- An entity that becomes single or owned_shared starts to follow its targets,
-- none of which may follow it in turn (dd_attach_cycle_check, 91024). A change
-- of the mode first locks the entity's table ACCESS EXCLUSIVE, so a record
-- being inserted concurrently is either committed and counted, or waits for
-- the new mode. The link table needs no lock of its own: a link row names a
-- record of the table (a NOT NULL foreign key), and the rebuild of the
-- policies that follows takes ACCESS EXCLUSIVE anyway, so taking it first
-- leaves no lock to upgrade.
-- A rename of an owned_shared or multiple entity to a longer name reaches
-- 91004 here: the rename of its link entity (dd_attach_link_rename, which
-- runs first) waits for a name that fits.
-- As the definer, the record check sees rows the caller cannot read.

-- The longest name of an attachable entity, 22 bytes: its link field
-- <entity>_id on <entity>_links must fit the field-name limit
-- (reserve_field_name_length, 0180_managed_enable.sql).
CREATE OR REPLACE FUNCTION dd_attach_name_max()
RETURNS INTEGER AS $$
    SELECT 22;
$$ LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp;

COMMENT ON FUNCTION dd_attach_name_max() IS
'The longest name of an attachable entity in bytes, 22: its link field <entity>_id has to fit the field-name limit of <entity>_links.';

-- The WHEN of b_attach_link_rename_trigger reads it as the writer of entities.
REVOKE EXECUTE ON FUNCTION dd_attach_name_max() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION dd_attach_name_max() TO semantius_user;

-- Refuses p_attachable following p_target when reading the records of
-- p_target follows, through the targets of single and owned_shared entities,
-- to the records of p_attachable's family (91024). The policy of a single or
-- owned_shared record reads its target, and the target's own policy reads the
-- target's target in turn (the policy of a link row reads its record as well,
-- which reads nothing further unless it is single or owned_shared too), so
-- the policies of both would read each other without end. A family counts by
-- its root, which holds the attach mode and the records.
CREATE OR REPLACE FUNCTION dd_attach_cycle_check(p_target TEXT, p_attachable TEXT)
RETURNS VOID AS $$
BEGIN
    IF EXISTS (WITH RECURSIVE reach(root) AS (
                   SELECT a.table_name FROM dd_ancestors(p_target) a WHERE a.depth = 0
                   UNION
                   SELECT t.table_name
                     FROM reach r
                     JOIN entities e ON e.table_name = r.root AND e.attach_mode IN ('single', 'owned_shared')
                     JOIN entity_attachables ea ON ea.attachable = e.table_name
                    CROSS JOIN LATERAL dd_ancestors(ea.target) t
                    WHERE t.depth = 0)
               SELECT 1 FROM reach r
                 JOIN dd_ancestors(p_attachable) a ON a.depth = 0 AND a.table_name = r.root) THEN
        RAISE EXCEPTION 'The records of ${target} follow those of ${attachable}, so ${attachable} cannot follow ${target}'
            USING ERRCODE = '91024',
                  HINT = jsonb_build_object('target', p_target, 'attachable', p_attachable,
                                            'hint', 'Reading either would read the other without end.')::text;
    END IF;
END;
$$ LANGUAGE plpgsql STABLE SET search_path = public, pg_temp;

COMMENT ON FUNCTION dd_attach_cycle_check(TEXT, TEXT) IS
'Refuses (91024) an attachable entity following a target whose records follow, through the targets of single and owned_shared entities, the records of the attachable entity''s family.';

REVOKE EXECUTE ON FUNCTION dd_attach_cycle_check(TEXT, TEXT) FROM PUBLIC;

CREATE OR REPLACE FUNCTION check_entity_attach()
RETURNS TRIGGER AS $$
DECLARE
    v_rows   BOOLEAN := FALSE;
    v_listed TEXT;
BEGIN
    IF NEW.attach_mode <> 'none' THEN
        IF NOT NEW.managed THEN
            RAISE EXCEPTION 'Entity ${table} is not managed and cannot be attachable'
                USING ERRCODE = '91001',
                      HINT = jsonb_build_object('table', NEW.table_name)::text;
        END IF;
        IF NEW.id_type IN ('is_a', 'has_a') THEN
            RAISE EXCEPTION 'Entity ${table} keeps its records in a base and cannot be attachable'
                USING ERRCODE = '91002',
                      HINT = jsonb_build_object('table', NEW.table_name,
                                                'hint', 'An is_a family is attachable through its root.')::text;
        END IF;
        IF NEW.id_type = 'computed' THEN
            RAISE EXCEPTION 'Entity ${table} has a computed key and cannot be attachable'
                USING ERRCODE = '91003',
                      HINT = jsonb_build_object('table', NEW.table_name)::text;
        END IF;
        IF octet_length(NEW.table_name) > dd_attach_name_max() THEN
            RAISE EXCEPTION 'Entity name ${table} is ${length} bytes long: the name of an attachable entity fits only up to ${max} bytes'
                USING ERRCODE = '91004',
                      HINT = jsonb_build_object('table', NEW.table_name, 'length', octet_length(NEW.table_name),
                                                'max', dd_attach_name_max())::text;
        END IF;
        IF NEW.attach_mode IN ('single', 'owned_shared')
           AND EXISTS (SELECT 1 FROM fields f
                        WHERE f.table_name = NEW.table_name AND f.field_name = 'attached_to'
                          AND f.ctype <> 'attached_to') THEN
            RAISE EXCEPTION 'Entity ${table} has a field attached_to of its own, which a single or owned_shared entity keeps for its target'
                USING ERRCODE = '91022',
                      HINT = jsonb_build_object('table', NEW.table_name,
                                                'hint', 'Rename the field, or use the attach mode multiple.')::text;
        END IF;
    END IF;

    IF TG_OP = 'UPDATE' THEN
        IF NEW.attach_mode IN ('single', 'owned_shared') AND OLD.attach_mode NOT IN ('single', 'owned_shared') THEN
            PERFORM dd_attach_cycle_check(ea.target, OLD.table_name)
               FROM entity_attachables ea
              WHERE ea.attachable = OLD.table_name
              ORDER BY ea.target;
        END IF;

        IF OLD.attach_mode IS DISTINCT FROM NEW.attach_mode AND OLD.managed
           AND to_regclass(format('public.%I', dd_relation(OLD.table_name, OLD.id_type))) IS NOT NULL THEN
            EXECUTE format('LOCK TABLE public.%I IN ACCESS EXCLUSIVE MODE', dd_relation(OLD.table_name, OLD.id_type));
            EXECUTE format('SELECT EXISTS (SELECT 1 FROM public.%I)', dd_relation(OLD.table_name, OLD.id_type))
               INTO v_rows;
            IF v_rows THEN
                RAISE EXCEPTION 'The attach_mode of ${table} cannot change while it has records'
                    USING ERRCODE = '91005',
                          HINT = jsonb_build_object('table', NEW.table_name)::text;
            END IF;
        END IF;

        IF OLD.managed AND NOT NEW.managed THEN
            SELECT min(ea.attachable) INTO v_listed
              FROM entity_attachables ea
             WHERE ea.target = NEW.table_name;
            IF v_listed IS NOT NULL THEN
                RAISE EXCEPTION 'Entity ${target} stays managed while ${attachable} lists it as a target'
                    USING ERRCODE = '91006',
                          HINT = jsonb_build_object('target', NEW.table_name, 'attachable', v_listed)::text;
            END IF;
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

COMMENT ON FUNCTION check_entity_attach() IS
'BEFORE INSERT OR UPDATE trigger on entities: refuses an attach_mode on an entity that is not managed (91001), is_a or has_a (91002), has a computed key (91003) or a name longer than 22 bytes (91004), a single or owned_shared mode on an entity with a field attached_to of its own (91022) or a target that follows it (91024), a change of attach_mode while the entity has records (91005), and unmanaging an entity that is a listed target (91006).';

REVOKE EXECUTE ON FUNCTION check_entity_attach() FROM PUBLIC;

CREATE OR REPLACE TRIGGER check_entity_attach_trigger
    BEFORE INSERT OR UPDATE ON entities
    FOR EACH ROW
    EXECUTE FUNCTION check_entity_attach();

-- A link entity is the dictionary's: its row, its fields and its table follow
-- the attachable entity. A write by anybody but the dictionary's own code
-- (BYPASSRLS, as fields_ctype_lock tells it apart) is refused (91007); the
-- definer triggers below and the cascades of entities.link_of run as the
-- owner and pass.
CREATE OR REPLACE FUNCTION protect_link_entity()
RETURNS TRIGGER AS $$
DECLARE
    v_privileged BOOLEAN;
    v_table      TEXT;
BEGIN
    SELECT rolbypassrls INTO v_privileged FROM pg_roles WHERE rolname = current_user;
    IF COALESCE(v_privileged, FALSE) THEN
        RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
    END IF;

    IF TG_TABLE_NAME = 'entities' THEN
        IF (TG_OP <> 'INSERT' AND OLD.link_of IS NOT NULL) OR (TG_OP <> 'DELETE' AND NEW.link_of IS NOT NULL) THEN
            v_table := CASE WHEN TG_OP = 'DELETE' THEN OLD.table_name ELSE NEW.table_name END;
        END IF;
    ELSE
        SELECT e.table_name INTO v_table
          FROM entities e
         WHERE e.link_of IS NOT NULL
           AND e.table_name IN (CASE WHEN TG_OP = 'DELETE' THEN OLD.table_name ELSE NEW.table_name END,
                                CASE WHEN TG_OP = 'INSERT' THEN NEW.table_name ELSE OLD.table_name END);
    END IF;
    IF v_table IS NOT NULL THEN
        RAISE EXCEPTION '${table} is a link entity the dictionary maintains'
            USING ERRCODE = '91007',
                  HINT = jsonb_build_object('table', v_table,
                                            'hint', 'Change the attachable entity it belongs to instead.')::text;
    END IF;
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$ LANGUAGE plpgsql SECURITY INVOKER SET search_path = public, pg_temp;

COMMENT ON FUNCTION protect_link_entity() IS
'BEFORE INSERT OR UPDATE OR DELETE trigger on entities and fields: refuses a write of a link entity''s row or of its fields by anybody but the dictionary (91007).';

REVOKE EXECUTE ON FUNCTION protect_link_entity() FROM PUBLIC;

CREATE OR REPLACE TRIGGER protect_link_entity_trigger
    BEFORE INSERT OR UPDATE OR DELETE ON entities
    FOR EACH ROW
    EXECUTE FUNCTION protect_link_entity();

CREATE OR REPLACE TRIGGER protect_link_entity_trigger
    BEFORE INSERT OR UPDATE OR DELETE ON fields
    FOR EACH ROW
    EXECUTE FUNCTION protect_link_entity();

-- =====================================================
-- The target entities: entity_attachables
-- =====================================================
-- A row switches an attachable entity on for a target entity. A row changes
-- only with a rename of one of its entities, which the foreign keys carry; any
-- other change is a delete and an insert, so that each is checked (91008).
-- The attachable entity has an attach mode (91009). A target carries the
-- delete step on its table and has a key that never changes, so it is a
-- managed entity (91010) with a table of its own - not has_a, whose base is
-- the target (91011), nor a link entity (91012) - outside the attachable
-- entity's family, itself included (91013), one whose records do not follow
-- the attachable entity's in turn when that is single or owned_shared
-- (dd_attach_cycle_check, 91024), with an immutable key
-- (pk_immutable): neither a computed system table nor permissions or
-- entities, whose keys are renamed with ON UPDATE CASCADE (91014). An entity
-- that does not exist is left to the foreign keys.
CREATE OR REPLACE FUNCTION check_entity_attachable_row()
RETURNS TRIGGER AS $$
DECLARE
    v_attachable entities%ROWTYPE;
    v_target     entities%ROWTYPE;
    v_hint       TEXT := jsonb_build_object('target', NEW.target, 'attachable', NEW.attachable)::text;
BEGIN
    IF TG_OP = 'UPDATE' THEN
        IF EXISTS (SELECT 1 FROM entities e WHERE e.table_name = OLD.target)
           AND EXISTS (SELECT 1 FROM entities e WHERE e.table_name = OLD.attachable) THEN
            RAISE EXCEPTION 'The target ${target} of ${attachable} is not changed in place'
                USING ERRCODE = '91008',
                      HINT = jsonb_build_object('target', NEW.target, 'attachable', NEW.attachable,
                                                'hint', 'Delete the row of entity_attachables and insert the new one.')::text;
        END IF;
        RETURN NEW;
    END IF;

    SELECT * INTO v_attachable FROM entities WHERE table_name = NEW.attachable;
    SELECT * INTO v_target FROM entities WHERE table_name = NEW.target;
    IF v_attachable.table_name IS NULL OR v_target.table_name IS NULL THEN
        RETURN NEW;
    END IF;
    IF v_attachable.attach_mode = 'none' THEN
        RAISE EXCEPTION 'Entity ${attachable} has no attach_mode and cannot be switched on for ${target}'
            USING ERRCODE = '91009', HINT = v_hint;
    END IF;
    IF NOT v_target.managed THEN
        RAISE EXCEPTION 'Entity ${target} is not managed and cannot be a target of ${attachable}'
            USING ERRCODE = '91010', HINT = v_hint;
    END IF;
    IF v_target.id_type = 'has_a' THEN
        RAISE EXCEPTION 'Entity ${target} keeps its records in its base and cannot be a target of ${attachable}'
            USING ERRCODE = '91011',
                  HINT = jsonb_build_object('target', NEW.target, 'attachable', NEW.attachable,
                                            'hint', 'List its base as the target.')::text;
    END IF;
    IF v_target.link_of IS NOT NULL THEN
        RAISE EXCEPTION 'Entity ${target} is a link entity and cannot be a target of ${attachable}'
            USING ERRCODE = '91012', HINT = v_hint;
    END IF;
    IF NEW.target IN (SELECT f.table_name FROM dd_family(NEW.attachable) f) THEN
        RAISE EXCEPTION 'Entity ${target} is of the family of ${attachable} and cannot be its target'
            USING ERRCODE = '91013', HINT = v_hint;
    END IF;
    IF v_attachable.attach_mode IN ('single', 'owned_shared') THEN
        PERFORM dd_attach_cycle_check(NEW.target, NEW.attachable);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_trigger t
                    WHERE t.tgrelid = to_regclass(format('public.%I', dd_relation(v_target.table_name, v_target.id_type)))
                      AND t.tgname = 'pk_immutable') THEN
        RAISE EXCEPTION 'The key of ${target} can change, so it cannot be a target of ${attachable}'
            USING ERRCODE = '91014', HINT = v_hint;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

COMMENT ON FUNCTION check_entity_attachable_row() IS
'BEFORE INSERT OR UPDATE trigger on entity_attachables: refuses any change of a row but the rename its foreign keys carry (91008), an entity without an attach_mode (91009), and a target that is not managed (91010), has_a (91011), a link entity (91012), of the attachable entity''s family (91013), whose records follow the attachable entity''s (91024) or whose key can change (91014).';

REVOKE EXECUTE ON FUNCTION check_entity_attachable_row() FROM PUBLIC;

CREATE OR REPLACE TRIGGER check_entity_attachable_row_trigger
    BEFORE INSERT OR UPDATE ON entity_attachables
    FOR EACH ROW
    EXECUTE FUNCTION check_entity_attachable_row();

-- Whether records of an attachable entity are attached to records of one of
-- the given tables, in attached_to or in its link entity. The patterns are
-- constant prefixes, so the text_pattern_ops index of attached_to serves them.
-- SECURITY INVOKER: its callers are definer triggers and run as the owner, so
-- an attachment the caller cannot see still counts.
CREATE OR REPLACE FUNCTION dd_attachments_exist(p_attachable TEXT, p_tables TEXT[])
RETURNS BOOLEAN AS $$
DECLARE
    v_found BOOLEAN;
    v_match TEXT;
    r       RECORD;
BEGIN
    SELECT string_agg(format('x.attached_to LIKE %L', dd_ref_like(t)), ' OR ')
      INTO v_match
      FROM unnest(p_tables) AS t;
    IF v_match IS NULL THEN
        RETURN FALSE;
    END IF;
    FOR r IN
        SELECT dd_relation(e.table_name, e.id_type) AS rel
          FROM fields f
          JOIN entities e ON e.table_name = f.table_name
         WHERE f.ctype = 'attached_to'
           AND (e.table_name = p_attachable OR e.link_of = p_attachable)
    LOOP
        CONTINUE WHEN to_regclass(format('public.%I', r.rel)) IS NULL;
        EXECUTE format('SELECT EXISTS (SELECT 1 FROM public.%I x WHERE %s)', r.rel, v_match) INTO v_found;
        IF v_found THEN
            RETURN TRUE;
        END IF;
    END LOOP;
    RETURN FALSE;
END;
$$ LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = public, pg_temp;

COMMENT ON FUNCTION dd_attachments_exist(TEXT, TEXT[]) IS
'TRUE when records of the attachable entity are attached to a record of one of the tables, in attached_to or in its link entity, whether or not the caller can see them.';

REVOKE EXECUTE ON FUNCTION dd_attachments_exist(TEXT, TEXT[]) FROM PUBLIC;

-- Switching an attachable entity off for a target, by a delete of the row or
-- by the cascade of deleting the target entity, is refused while its records
-- are attached there (91015): they would keep a target nothing admits any
-- more, and whose delete step is gone. The records of the target's is_a
-- subtypes count, since a base admits them. An attachable entity or module
-- deleted in the same statement takes its records along, and does not count.
CREATE OR REPLACE FUNCTION check_entity_attachable_delete()
RETURNS TRIGGER AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM entities e JOIN modules m ON m.id = e.module_id
                    WHERE e.table_name = OLD.attachable) THEN
        RETURN OLD;
    END IF;
    IF dd_attachments_exist(OLD.attachable,
                            ARRAY[OLD.target] || ARRAY(SELECT s.table_name FROM dd_is_a_subtypes(OLD.target) s)) THEN
        RAISE EXCEPTION 'Records of ${attachable} are attached to ${target}'
            USING ERRCODE = '91015',
                  HINT = jsonb_build_object('attachable', OLD.attachable, 'target', OLD.target,
                                            'hint', 'Delete those records or their links first.')::text;
    END IF;
    RETURN OLD;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

COMMENT ON FUNCTION check_entity_attachable_delete() IS
'BEFORE DELETE trigger on entity_attachables: refuses switching an attachable entity off for a target entity, or deleting the target, while its records are attached to records of the target or of its is_a subtypes (91015).';

REVOKE EXECUTE ON FUNCTION check_entity_attachable_delete() FROM PUBLIC;

CREATE OR REPLACE TRIGGER check_entity_attachable_delete_trigger
    BEFORE DELETE ON entity_attachables
    FOR EACH ROW
    EXECUTE FUNCTION check_entity_attachable_delete();

CREATE OR REPLACE FUNCTION dd_entity_attachables_changed()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        PERFORM dd_attach_refresh(ARRAY[OLD.attachable, OLD.target]);
    ELSE
        PERFORM dd_attach_refresh(ARRAY[NEW.attachable, NEW.target]);
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

COMMENT ON FUNCTION dd_entity_attachables_changed() IS
'AFTER INSERT OR UPDATE OR DELETE trigger on entity_attachables: rebuilds what depends on the targets of the attachable entity (dd_attach_refresh).';

REVOKE EXECUTE ON FUNCTION dd_entity_attachables_changed() FROM PUBLIC;

CREATE OR REPLACE TRIGGER zz_entity_attachables_changed_trigger
    AFTER INSERT OR UPDATE OR DELETE ON entity_attachables
    FOR EACH ROW
    EXECUTE FUNCTION dd_entity_attachables_changed();

-- =====================================================
-- The attach step: d_attach_check
-- =====================================================
-- On insert of an attachable record (single, owned_shared) or of a link row,
-- common.attach_target checks the target. The reference is spelled
-- canonically first (dd_record_ref_canonical): text that is no reference, a
-- table that is no entity and a key that is no value of its type give none.
-- get_record_by_id then checks the caller's read rights on every level of the
-- record and answers NULL alike for a record that does not exist and one the
-- caller cannot see, so the one refusal for all of them (91018) tells nothing
-- about records the caller cannot see. The target's table must be one the
-- attachable entity admits (dd_attach_targets: a listed target or an is_a
-- subtype of one, 91019); the row of entity_attachables that admits it is
-- locked FOR KEY SHARE first, so a switch-off waits for this attach to commit
-- and then finds its record (91015), and one that committed while this waited
-- admits nothing any more. With the attach permission edit the caller must
-- hold the edit permission of every level of it (91020). Last, the target row
-- is locked FOR KEY SHARE, so a concurrent delete of it waits until the
-- attachment is committed and its delete step then finds it; a delete that
-- committed while the attach waited leaves no row to lock, and the attach is
-- refused as for a record that does not exist. The reference is written in its
-- canonical spelling.
--
-- A link row is written on behalf of its attachable record, so adding or
-- removing one needs the rights to change that record. The policies of the
-- link entity hold the record's edit permission, and on delete its visibility
-- and an owned_shared owner's edit rights (dd_attach_policy_terms). On insert
-- the record must be visible to the caller (91021) and an owned_shared
-- record's owner editable by the caller (91023). Then, on insert and on
-- delete, the record's own rules are asked, as for an update of it that
-- changes nothing (common.attach_record_rules): a task's rule 90279 refuses a
-- link to whoever may see the task but not change it. A link whose target
-- record is gone passes (dd_attach_target_exists): the delete step of a target
-- removes the links to it as a foreign-key cascade would, and a link to a
-- record that no longer exists is no change of the attachable record. A record
-- that is gone itself (its delete cascades to its links) has nothing to ask.
--
-- A target is set on insert and never changed: an update that changes
-- attached_to of an attachable record is refused (91025), and so is one that
-- changes a link row's record or target (91026), since a link is removed and
-- added, never changed. An update that sends the stored values passes.
--
-- SECURITY DEFINER, owned by the owner: they read entity_attachables and the
-- attachable records and lock the target, and get_record_by_id, which
-- authenticates through rbac.uid(), answers for the caller's own rights. A
-- privileged direct session (dd_privileged_session, a migration's seed) is not
-- held to the edit permissions nor to the rules; get_record_by_id reads for it
-- unchecked.

-- Whether the caller holds every edit permission of a target's levels
-- (dd_attach_targets), as attaching with the attach permission edit and
-- linking an owned_shared record need.
CREATE OR REPLACE FUNCTION dd_attach_may_edit(p_permissions TEXT[])
RETURNS BOOLEAN AS $$
    SELECT dd_privileged_session()
        OR NOT EXISTS (SELECT 1 FROM unnest(p_permissions) AS p WHERE NOT rbac.has_permission(p));
$$ LANGUAGE sql STABLE SET search_path = public, pg_temp;

COMMENT ON FUNCTION dd_attach_may_edit(TEXT[]) IS
'TRUE when the caller holds every one of the edit permissions of a target''s levels, or runs a privileged direct session.';

REVOKE EXECUTE ON FUNCTION dd_attach_may_edit(TEXT[]) FROM PUBLIC;

CREATE OR REPLACE FUNCTION common.attach_target(p_attachable TEXT, p_ref TEXT, p_edit BOOLEAN)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_ref    TEXT := dd_record_ref_canonical(p_ref);
    v_split  RECORD;
    v_target RECORD;
    v_locked INTEGER;
BEGIN
    SELECT * INTO v_split FROM dd_record_ref_split(v_ref);
    IF v_ref IS NOT NULL AND get_record_by_id(v_split.table_name, v_split.key) IS NOT NULL THEN
        PERFORM 1
           FROM entity_attachables ea
          WHERE ea.attachable = p_attachable
            AND ea.target IN (SELECT a.table_name FROM dd_ancestors(v_split.table_name) a)
            FOR KEY SHARE;
        SELECT * INTO v_target FROM dd_attach_targets(p_attachable) t WHERE t.table_name = v_split.table_name;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Records of ${attachable} cannot be attached to ${target}'
                USING ERRCODE = '91019',
                      HINT = jsonb_build_object('attachable', p_attachable, 'target', v_split.table_name)::text;
        END IF;
        IF p_edit AND NOT dd_attach_may_edit(v_target.edit_permissions) THEN
            RAISE EXCEPTION 'Attaching ${attachable} records to ${reference} needs the edit permission of ${target}'
                USING ERRCODE = '91020',
                      HINT = jsonb_build_object('attachable', p_attachable, 'reference', v_ref,
                                                'target', v_split.table_name)::text;
        END IF;
        -- rels[1] is the root's table, which holds a row for every record.
        EXECUTE format('SELECT 1 FROM public.%I t WHERE t.%I = $1::%s FOR KEY SHARE',
                       v_target.rels[1], v_target.id_column, v_target.key_type)
           INTO v_locked
          USING v_split.key;
    END IF;

    -- No reference, not found, not visible, or deleted while the lock waited.
    IF v_locked IS NULL THEN
        RAISE EXCEPTION 'No record ${reference} to attach ${attachable} records to'
            USING ERRCODE = '91018',
                  HINT = jsonb_build_object('reference', p_ref, 'attachable', p_attachable)::text;
    END IF;
    RETURN v_ref;
END;
$$;

COMMENT ON FUNCTION common.attach_target(TEXT, TEXT, BOOLEAN) IS
'The attach step for one target: refuses a target table the attachable entity does not admit (91019) and, with p_edit, a target whose levels'' edit permission the caller lacks (91020); locks the target row FOR KEY SHARE and refuses text that is no reference, a record that does not exist, that the caller cannot see or that a delete removed meanwhile, alike (91018). Returns the canonical reference.';

REVOKE EXECUTE ON FUNCTION common.attach_target(TEXT, TEXT, BOOLEAN) FROM PUBLIC;

-- Whether the record a reference names still exists, as the owner sees it:
-- the row in the table of the family's root, of an entity whose module is not
-- being deleted. A record of a target a module delete is dropping counts as
-- gone (dd_attach_target_purge runs before its table is dropped).
CREATE OR REPLACE FUNCTION dd_attach_target_exists(p_ref TEXT)
RETURNS BOOLEAN AS $$
DECLARE
    v_split RECORD;
    v_root  entities%ROWTYPE;
    v_found BOOLEAN;
BEGIN
    SELECT * INTO v_split FROM dd_record_ref_split(p_ref);
    SELECT e.* INTO v_root
      FROM dd_ancestors(v_split.table_name) a
      JOIN entities e ON e.table_name = a.table_name
      JOIN modules m ON m.id = e.module_id
     WHERE a.depth = 0;
    IF NOT FOUND OR to_regclass(format('public.%I', v_root.table_name)) IS NULL
       OR dd_key_cast(v_split.key, dd_key_type(v_root.table_name)) IS NULL THEN
        RETURN FALSE;
    END IF;
    EXECUTE format('SELECT EXISTS (SELECT 1 FROM public.%I t WHERE t.%I = $1::%s)',
                   v_root.table_name, v_root.id_column, dd_key_type(v_root.table_name))
       INTO v_found
      USING v_split.key;
    RETURN v_found;
END;
-- SECURITY INVOKER: its caller, common.attach_check, runs as the owner.
$$ LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = public, pg_temp;

COMMENT ON FUNCTION dd_attach_target_exists(TEXT) IS
'Whether the record a record reference names exists, read past row-level security; a record of an entity whose module is being deleted counts as gone.';

REVOKE EXECUTE ON FUNCTION dd_attach_target_exists(TEXT) FROM PUBLIC;

-- The rules of an attachable record asked as for an update that changes
-- nothing (mode update, the record as $old and as the new record), the record
-- read as the owner. A record that is gone, an entity without rules and a
-- privileged direct session pass.
CREATE OR REPLACE FUNCTION common.attach_record_rules(p_attachable TEXT, p_key TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_rules TEXT := 'record_rules_' || p_attachable;
    v_row   JSONB;
BEGIN
    IF dd_privileged_session()
       OR to_regprocedure(format('common.%I(text, jsonb, jsonb)', v_rules)) IS NULL THEN
        RETURN;
    END IF;
    EXECUTE format('SELECT to_jsonb(t) FROM public.%I t WHERE t.%I = $1::%s',
                   p_attachable, (SELECT e.id_column FROM entities e WHERE e.table_name = p_attachable),
                   dd_key_type(p_attachable))
       INTO v_row
      USING p_key;
    IF v_row IS NOT NULL THEN
        EXECUTE format('SELECT common.%I(''update'', $1, $1)', v_rules) USING v_row;
    END IF;
END;
$$;

COMMENT ON FUNCTION common.attach_record_rules(TEXT, TEXT) IS
'Evaluates the rules of an attachable record as for an update that changes nothing, so a failing validation rule refuses; a record that is gone, an entity without rules and a privileged direct session pass.';

REVOKE EXECUTE ON FUNCTION common.attach_record_rules(TEXT, TEXT) FROM PUBLIC;

CREATE OR REPLACE FUNCTION common.attach_check()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_entity     entities%ROWTYPE;
    v_attachable entities%ROWTYPE;
    v_link_field TEXT;
    v_ref        TEXT;
    v_record     TEXT;
    v_row        JSONB;
BEGIN
    SELECT * INTO v_entity FROM entities WHERE table_name = TG_TABLE_NAME;
    IF v_entity.link_of IS NOT NULL THEN
        SELECT * INTO v_attachable FROM entities WHERE table_name = v_entity.link_of;
        v_link_field := v_attachable.table_name || '_id';
    ELSE
        v_attachable := v_entity;
    END IF;

    -- Only a link table has the trigger on delete. A link to a record that is
    -- gone is removed without the rules.
    IF TG_OP = 'DELETE' THEN
        IF dd_attach_target_exists(to_jsonb(OLD) ->> 'attached_to') THEN
            PERFORM common.attach_record_rules(v_attachable.table_name, to_jsonb(OLD) ->> v_link_field);
        END IF;
        RETURN OLD;
    END IF;

    IF TG_OP = 'UPDATE' THEN
        IF EXISTS (SELECT 1 FROM unnest(ARRAY['attached_to', v_link_field]) AS c(name)
                    WHERE c.name IS NOT NULL AND to_jsonb(NEW) -> c.name IS DISTINCT FROM to_jsonb(OLD) -> c.name) THEN
            IF v_link_field IS NULL THEN
                RAISE EXCEPTION 'The target ${reference} of a record of ${attachable} is not changed'
                    USING ERRCODE = '91025',
                          HINT = jsonb_build_object('reference', to_jsonb(OLD) ->> 'attached_to',
                                                    'attachable', v_attachable.table_name,
                                                    'hint', 'Delete the record and attach a new one.')::text;
            END IF;
            RAISE EXCEPTION 'A link of ${attachable} to ${reference} is not changed'
                USING ERRCODE = '91026',
                      HINT = jsonb_build_object('reference', to_jsonb(OLD) ->> 'attached_to',
                                                'attachable', v_attachable.table_name,
                                                'hint', 'Remove the link and add the new one.')::text;
        END IF;
        RETURN NEW;
    END IF;

    -- An empty target is left to the required check of attached_to.
    v_ref := to_jsonb(NEW) ->> 'attached_to';
    IF coalesce(v_ref, '') = '' THEN
        RETURN NEW;
    END IF;
    v_ref := common.attach_target(v_attachable.table_name, v_ref, v_attachable.attach_permission = 'edit');

    IF v_link_field IS NOT NULL THEN
        v_record := to_jsonb(NEW) ->> v_link_field;
        v_row := get_record_by_id(v_attachable.table_name, v_record);
        IF v_row IS NULL THEN
            RAISE EXCEPTION 'No record ${reference} to link to ${target}'
                USING ERRCODE = '91021',
                      HINT = jsonb_build_object('reference', dd_record_ref(v_attachable.table_name, v_record),
                                                'target', v_ref)::text;
        END IF;
        IF v_attachable.attach_mode = 'owned_shared'
           AND NOT dd_attach_may_edit((SELECT t.edit_permissions
                                         FROM dd_attach_targets(v_attachable.table_name) t
                                        WHERE t.table_name = (dd_record_ref_split(v_row ->> 'attached_to')).table_name)) THEN
            RAISE EXCEPTION 'Linking ${reference} needs the edit permission of its owner ${owner}'
                USING ERRCODE = '91023',
                      HINT = jsonb_build_object('reference', dd_record_ref(v_attachable.table_name, v_record),
                                                'owner', v_row ->> 'attached_to')::text;
        END IF;
        PERFORM common.attach_record_rules(v_attachable.table_name, v_record);
    END IF;

    -- The row is rebuilt through EXECUTE, which plans against the table as it
    -- is now, as common.typeid_assign explains.
    EXECUTE 'SELECT r.* FROM jsonb_populate_record($1, $2) AS r'
       INTO NEW USING NEW, jsonb_build_object('attached_to', v_ref);
    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION common.attach_check() IS
'BEFORE trigger d_attach_check of an attachable entity''s table (single, owned_shared: INSERT OR UPDATE) and of its link table (INSERT OR UPDATE OR DELETE): on insert checks the target through common.attach_target and writes its canonical reference; a link row''s record must be visible (91021), an owned_shared one''s owner editable (91023), and the record''s rules pass, on insert and on the delete of a link whose target still exists (common.attach_record_rules). On update refuses a changed attached_to (91025) and a changed link row (91026).';

REVOKE EXECUTE ON FUNCTION common.attach_check() FROM PUBLIC;

-- =====================================================
-- The delete step on every target: attached_del and attached_trc
-- =====================================================
-- Every target table carries two statement-level triggers of
-- common.attached_step: after a delete it hands the keys of the deleted rows
-- to the table's delete step common.attached_<t>, and before a TRUNCATE, which
-- fires no delete triggers, it refuses while anything is attached to the table
-- (91017). They sit on the table that stores the target's records: for an is_a
-- target the root's, whose rows every subtype record has. The trigger names
-- carry no table name, so a rename leaves them as they are.
--
-- common.attached_<t>(keys) is generated per target table and rebuilt like the
-- rollup functions (rollup_build_link, 0440_rollup.sql). The reference of a
-- key names the subtype its prefix belongs to. For those references it
--   * refuses, for a single or owned_shared entity whose
--     attach_on_target_delete is restrict, while a record is attached in
--     attached_to (91016), and otherwise deletes those records;
--   * removes the link rows that name them. Their target is gone, so the
--     attachable entity's rules do not hold them back (common.attach_check);
--     a multiple record that lost its last target stays, as one created
--     without any target does.
-- The deletes run as the definer, past the row-level security of the
-- attachable entity, as a foreign-key cascade does; its row triggers, its
-- rules among them, run as they do for one. A record of an is_a attachable
-- entity is deleted through the view of its subtype, whose write routine
-- removes every part: a delete of the root row alone would be refused by the
-- parts that reference it.
CREATE OR REPLACE FUNCTION common.attached_step()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_names      TEXT[] := ARRAY[TG_TABLE_NAME::text] || ARRAY(SELECT s.table_name FROM dd_is_a_subtypes(TG_TABLE_NAME) s);
    v_keys       TEXT[];
    v_attachable TEXT;
BEGIN
    IF TG_OP = 'TRUNCATE' THEN
        SELECT ea.attachable INTO v_attachable
          FROM entity_attachables ea
         WHERE ea.target = ANY (v_names)
           AND dd_attachments_exist(ea.attachable, v_names)
         ORDER BY ea.attachable
         LIMIT 1;
        IF FOUND THEN
            RAISE EXCEPTION '${table} cannot be truncated while ${attachable} records are attached to its records'
                USING ERRCODE = '91017',
                      HINT = jsonb_build_object('table', TG_TABLE_NAME, 'attachable', v_attachable)::text;
        END IF;
        RETURN NULL;
    END IF;
    -- TG_ARGV[0] is the key column (dd_build_attached_triggers).
    EXECUTE format('SELECT array_agg(o.%I::text) FROM old_rows o', TG_ARGV[0]) INTO v_keys;
    IF v_keys IS NOT NULL THEN
        EXECUTE format('SELECT common.%I($1)', 'attached_' || TG_TABLE_NAME) USING v_keys;
    END IF;
    RETURN NULL;
END;
$$;

COMMENT ON FUNCTION common.attached_step() IS
'Statement-level trigger function of a target table (attached_del, attached_trc): after a delete, runs the table''s delete step common.attached_<table> for the deleted keys; refuses a TRUNCATE while records are attached to the table or its is_a subtypes (91017).';

REVOKE EXECUTE ON FUNCTION common.attached_step() FROM PUBLIC;

CREATE OR REPLACE FUNCTION dd_build_attached_triggers(p_root TEXT)
RETURNS VOID AS $fn$
DECLARE
    v_fn      TEXT := 'attached_' || p_root;
    v_root    entities%ROWTYPE;
    v_ref     TEXT;
    v_del     TEXT := '';
    v_link    TEXT;
    v_rels    TEXT[];
    v_names   TEXT[];
    v_hit     BOOLEAN := FALSE;
    r         RECORD;
BEGIN
    EXECUTE format('DROP FUNCTION IF EXISTS common.%I(text[])', v_fn);

    SELECT * INTO v_root FROM entities WHERE table_name = p_root;
    IF NOT FOUND OR to_regclass(format('public.%I', p_root)) IS NULL THEN
        RETURN;
    END IF;
    v_names := ARRAY[p_root] || ARRAY(SELECT s.table_name FROM dd_is_a_subtypes(p_root) s);

    -- The reference of a key (dd_record_ref).
    SELECT format('(CASE common.type_prefix(o.k)%s ELSE %L END || o.k)',
                  string_agg(format(' WHEN %L THEN %L', s.type_prefix, s.table_name || ':'), '' ORDER BY s.depth, s.table_name),
                  p_root || ':')
      INTO v_ref
      FROM dd_is_a_subtypes(p_root) s
    HAVING count(*) > 0;
    v_ref := coalesce(v_ref, format('(%L || o.k)', p_root || ':'));

    FOR r IN
        SELECT a.*
          FROM entities a
         WHERE a.attach_mode <> 'none' AND a.managed
           AND v_root.managed AND v_root.id_type NOT IN ('is_a', 'has_a', 'computed')
           AND to_regclass(format('public.%I', a.table_name)) IS NOT NULL
           -- One whose module a module delete is taking takes its records along.
           AND EXISTS (SELECT 1 FROM modules m WHERE m.id = a.module_id)
           AND EXISTS (SELECT 1 FROM entity_attachables ea
                        WHERE ea.attachable = a.table_name AND ea.target = ANY (v_names))
         ORDER BY a.table_name
    LOOP
        SELECT l.table_name INTO v_link FROM entities l WHERE l.link_of = r.table_name;
        -- Where its records are deleted: the view of each direct is_a subtype
        -- first, then the table.
        v_rels := ARRAY(SELECT s.table_name FROM dd_is_a_subtypes(r.table_name) s WHERE s.depth = 1
                         ORDER BY s.table_name) || r.table_name;

        IF r.attach_mode IN ('single', 'owned_shared') THEN
            IF r.attach_on_target_delete = 'restrict' THEN
                v_hit := TRUE;
                v_del := v_del || format($S$
    SELECT x.attached_to INTO v_hit FROM public.%1$I x WHERE x.attached_to = ANY (v_refs) LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'Record ${reference} cannot be deleted while ${attachable} records are attached to it'
            USING ERRCODE = '91016',
                  HINT = jsonb_build_object('reference', v_hit, 'attachable', %2$L)::text;
    END IF;$S$, r.table_name, r.table_name);
            ELSE
                v_del := v_del || (SELECT string_agg(format(E'\n    DELETE FROM public.%I x WHERE x.attached_to = ANY (v_refs);', rel), '' ORDER BY n)
                                     FROM unnest(v_rels) WITH ORDINALITY AS u(rel, n));
            END IF;
        END IF;

        IF v_link IS NOT NULL THEN
            v_del := v_del || format(E'\n    DELETE FROM public.%I l WHERE l.attached_to = ANY (v_refs);', v_link);
        END IF;
    END LOOP;

    IF v_del = '' THEN
        EXECUTE format('DROP TRIGGER IF EXISTS attached_del ON public.%I', p_root);
        EXECUTE format('DROP TRIGGER IF EXISTS attached_trc ON public.%I', p_root);
        RETURN;
    END IF;

    EXECUTE format('CREATE FUNCTION common.%I(p_keys text[]) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS %s',
                   v_fn, dd_dollar_quote(format($B$
DECLARE
    v_refs TEXT[];%3$s
BEGIN
    SELECT array_agg(%1$s) INTO v_refs FROM unnest(p_keys) AS o(k);
    IF v_refs IS NULL THEN
        RETURN;
    END IF;%2$s
END;
$B$, v_ref, v_del,
         -- The variables the steps above use, and only those.
         CASE WHEN v_hit THEN E'\n    v_hit  TEXT;' ELSE '' END)));
    EXECUTE format('REVOKE EXECUTE ON FUNCTION common.%I(text[]) FROM PUBLIC', v_fn);
    EXECUTE format('COMMENT ON FUNCTION common.%I(text[]) IS %L', v_fn,
        format('The delete step of %s for the given keys: refuses or cascades the records attached to them and removes their link rows. Run by common.attached_step after a delete, and by dd_attach_target_purge when a module delete drops the table. Generated by dd_build_attached_triggers.', p_root));
    EXECUTE format('CREATE OR REPLACE TRIGGER attached_del AFTER DELETE ON public.%I REFERENCING OLD TABLE AS old_rows
                        FOR EACH STATEMENT EXECUTE FUNCTION common.attached_step(%L)', p_root, v_root.id_column);
    EXECUTE format('CREATE OR REPLACE TRIGGER attached_trc BEFORE TRUNCATE ON public.%I
                        FOR EACH STATEMENT EXECUTE FUNCTION common.attached_step()', p_root);
END;
$fn$ LANGUAGE plpgsql SET search_path = public, pg_temp;

COMMENT ON FUNCTION dd_build_attached_triggers(TEXT) IS
'Drops and, when attachable entities list the table or one of its is_a subtypes as a target, regenerates the delete step common.attached_<table>(text[]) and the triggers attached_del (AFTER DELETE, statement level) and attached_trc (BEFORE TRUNCATE) of common.attached_step on the table.';

REVOKE EXECUTE ON FUNCTION dd_build_attached_triggers(TEXT) FROM PUBLIC;

-- A target entity deleted by a module delete takes the attachments to its
-- records along, as deleting each record would (its delete step), and its
-- records count as gone for the links (dd_attach_target_exists): the rows
-- are dropped with the table, which fires no delete trigger, and the
-- attachments would keep a target that is gone. The module's row is gone
-- already when the cascade reaches its entities, as delete_dd_table relies
-- on. The delete step is built again first: an attachable entity of the same
-- module may be gone already, or be going with the module and take its records
-- along, and the cascade that would rebuild it runs only at the end of the
-- statement. A target entity deleted on its own is refused while records are
-- attached (91015). Runs before delete_table_trigger drops the table.
CREATE OR REPLACE FUNCTION dd_attach_target_purge()
RETURNS TRIGGER AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM modules m WHERE m.id = OLD.module_id)
       AND to_regprocedure(format('common.%I(text[])', 'attached_' || OLD.table_name)) IS NOT NULL THEN
        PERFORM dd_build_attached_triggers(OLD.table_name);
        IF to_regprocedure(format('common.%I(text[])', 'attached_' || OLD.table_name)) IS NOT NULL THEN
            EXECUTE format('SELECT common.%I(ARRAY(SELECT t.%I::text FROM public.%I t))',
                           'attached_' || OLD.table_name, OLD.id_column, OLD.table_name);
        END IF;
    END IF;
    RETURN OLD;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

COMMENT ON FUNCTION dd_attach_target_purge() IS
'BEFORE DELETE trigger on entities: when a module delete deletes a target entity, runs its delete step over all its records, so what is attached to them goes as it would with each record.';

REVOKE EXECUTE ON FUNCTION dd_attach_target_purge() FROM PUBLIC;

CREATE OR REPLACE TRIGGER b_attach_target_purge_trigger
    BEFORE DELETE ON entities
    FOR EACH ROW
    EXECUTE FUNCTION dd_attach_target_purge();

-- =====================================================
-- Keeping it all up to date
-- =====================================================
-- What depends on an attachable entity's targets and mode, rebuilt for the
-- attachable entities concerned by a change of the given entities: those
-- named, and those that list one of their families as a target. For each, its
-- policies and those of its link entity (build_select_rule_policy, which
-- reads dd_attach_policy_terms), their label functions (attached_to_label),
-- and the attach step on both tables; then the delete step of every target
-- table concerned.
CREATE OR REPLACE FUNCTION dd_attach_refresh(p_tables TEXT[])
RETURNS VOID AS $$
DECLARE
    v_family TEXT[];
    v_roots  TEXT[];
    v_link   TEXT;
    v_rel    TEXT;
    r        RECORD;
BEGIN
    SELECT array_agg(DISTINCT f.table_name)
      INTO v_family
      FROM unnest(p_tables) AS t(name)
     CROSS JOIN LATERAL (SELECT t.name AS table_name
                         UNION SELECT x.table_name FROM dd_family(t.name) x) f;

    -- The attachable entities concerned, and a named entity that has left
    -- attachable: its attached_to went with the policies and the label
    -- function that read it, and its attach step stays behind.
    FOR r IN
        SELECT a.*
          FROM entities a
         WHERE a.managed
           AND ((a.attach_mode <> 'none'
                 AND (a.table_name = ANY (p_tables)
                      OR EXISTS (SELECT 1 FROM entity_attachables ea
                                  WHERE ea.attachable = a.table_name AND ea.target = ANY (v_family))))
                OR (a.table_name = ANY (p_tables)
                    AND EXISTS (SELECT 1 FROM pg_trigger t
                                 WHERE t.tgrelid = to_regclass(format('public.%I', dd_relation(a.table_name, a.id_type)))
                                   AND t.tgname = 'd_attach_check')))
         ORDER BY a.table_name
    LOOP
        PERFORM build_select_rule_policy(r.table_name);
        PERFORM rebuild_entity_label_functions(r.table_name);
        v_rel := dd_relation(r.table_name, r.id_type);
        IF r.attach_mode IN ('single', 'owned_shared') THEN
            EXECUTE format('CREATE OR REPLACE TRIGGER d_attach_check BEFORE INSERT OR UPDATE ON public.%I
                                FOR EACH ROW EXECUTE FUNCTION common.attach_check()', v_rel);
        ELSE
            EXECUTE format('DROP TRIGGER IF EXISTS d_attach_check ON public.%I', v_rel);
        END IF;

        SELECT l.table_name INTO v_link FROM entities l WHERE l.link_of = r.table_name;
        IF v_link IS NOT NULL AND to_regclass(format('public.%I', v_link)) IS NOT NULL THEN
            PERFORM build_select_rule_policy(v_link);
            PERFORM rebuild_entity_label_functions(v_link);
            EXECUTE format('CREATE OR REPLACE TRIGGER d_attach_check BEFORE INSERT OR UPDATE OR DELETE ON public.%I
                                FOR EACH ROW EXECUTE FUNCTION common.attach_check()', v_link);
        END IF;

        v_family := v_family || ARRAY(SELECT ea.target FROM entity_attachables ea WHERE ea.attachable = r.table_name);
    END LOOP;

    SELECT array_agg(DISTINCT a.table_name)
      INTO v_roots
      FROM unnest(v_family) AS t(name)
     CROSS JOIN LATERAL dd_ancestors(t.name) a
     WHERE a.depth = 0;
    FOR r IN SELECT unnest(coalesce(v_roots, ARRAY[]::TEXT[])) AS table_name LOOP
        PERFORM dd_build_attached_triggers(r.table_name);
    END LOOP;
END;
$$ LANGUAGE plpgsql SECURITY INVOKER SET search_path = public, pg_temp;

COMMENT ON FUNCTION dd_attach_refresh(TEXT[]) IS
'Rebuilds, for the attachable entities concerned by the given entities (named, or listing one of their families as a target), their policies and those of their link entities, their label functions and their attach step, and the delete step of every target table concerned. Called whenever targets, attach settings, permissions, names, members of a target family or managed flags change.';

REVOKE EXECUTE ON FUNCTION dd_attach_refresh(TEXT[]) FROM PUBLIC;

-- An entity's attach settings, name, permissions, rule or family changed.
--   * A new attach mode: single and owned_shared get the field attached_to,
--     inserted by the dictionary as create_dd_table inserts the label field;
--     owned_shared and multiple get the link entity <entity>_links. Leaving a
--     mode removes what it no longer has - the field by clearing its ctype
--     first, as dd_label_marker_follow does, since a core field cannot be
--     deleted - and leaving attachable altogether removes its targets. 91005
--     has made sure there are no records.
--   * A rename drops the delete step generated under the old name
--     (dd_attach_link_rename has carried the link entity along).
--   * The link entity keeps the permissions and the module of its attachable
--     entity.
-- Then dd_attach_refresh rebuilds what depends on it.
CREATE OR REPLACE FUNCTION dd_attach_entity_changed()
RETURNS TRIGGER AS $$
DECLARE
    v_link       TEXT;
    v_needs_attr BOOLEAN;
    v_needs_link BOOLEAN;
BEGIN
    -- Only a target has a delete step to drop, and only an is_a subtype a
    -- family whose targets change.
    IF TG_OP = 'DELETE' THEN
        IF to_regprocedure(format('common.%I(text[])', 'attached_' || OLD.table_name)) IS NOT NULL THEN
            EXECUTE format('DROP FUNCTION common.%I(text[])', 'attached_' || OLD.table_name);
        END IF;
        IF OLD.id_type = 'is_a' THEN
            PERFORM dd_attach_refresh(ARRAY[OLD.id_refentity]);
        END IF;
        RETURN NULL;
    END IF;

    -- Only an attachable entity, a target and the members of their families
    -- have anything here to keep up to date.
    IF TG_OP = 'UPDATE' AND OLD.attach_mode = 'none' AND NEW.attach_mode = 'none'
       AND NOT EXISTS (SELECT 1
                         FROM dd_family(NEW.table_name) f
                         JOIN entities e ON e.table_name = f.table_name
                        WHERE e.attach_mode <> 'none'
                           OR EXISTS (SELECT 1 FROM entity_attachables ea WHERE ea.target = f.table_name)) THEN
        RETURN NULL;
    END IF;

    SELECT l.table_name INTO v_link FROM entities l WHERE l.link_of = NEW.table_name;

    IF TG_OP = 'INSERT' OR OLD.attach_mode IS DISTINCT FROM NEW.attach_mode THEN
        v_needs_attr := NEW.attach_mode IN ('single', 'owned_shared');
        v_needs_link := NEW.attach_mode IN ('owned_shared', 'multiple');

        IF v_needs_attr AND NOT EXISTS (SELECT 1 FROM fields f
                                         WHERE f.table_name = NEW.table_name AND f.field_name = 'attached_to') THEN
            INSERT INTO fields (table_name, field_name, title, description, format, field_order, input_type, ctype)
            VALUES (NEW.table_name, 'attached_to', 'Attached to',
                    'The record this one is attached to, as its record reference <table_name>:<key>. Set when the record is created and never changed.',
                    'text', 25, 'required', 'attached_to');
        ELSIF NOT v_needs_attr AND EXISTS (SELECT 1 FROM fields f
                                            WHERE f.table_name = NEW.table_name AND f.ctype = 'attached_to') THEN
            UPDATE fields SET ctype = '' WHERE table_name = NEW.table_name AND ctype = 'attached_to';
            DELETE FROM fields WHERE table_name = NEW.table_name AND field_name = 'attached_to';
        END IF;

        IF v_needs_link AND v_link IS NULL THEN
            v_link := NEW.table_name || '_links';
            INSERT INTO entities (table_name, singular, singular_label, plural_label, description, module_id,
                                  view_permission, edit_permission, id_type, entity_type, link_of, icon_name, name_sort)
            VALUES (v_link, NEW.table_name || '_link', NEW.singular_label || ' Link', NEW.singular_label || ' Links',
                    format('Further target records of %s', NEW.plural_label), NEW.module_id,
                    NEW.view_permission, NEW.edit_permission, 'auto_increment', 'junction', NEW.table_name,
                    'link', '900');
            -- A link row needs no label of its own, its record and its target
            -- say what it is: the label stays empty, so it is neither
            -- required nor searched.
            UPDATE fields SET input_type = 'default', searchable = FALSE WHERE table_name = v_link AND field_name = 'label';
            INSERT INTO fields (table_name, field_name, title, description, format, field_order, input_type,
                                reference_table, reference_delete_mode, relationship_label, ctype)
            VALUES (v_link, NEW.table_name || '_id', NEW.singular_label,
                    format('The %s record that is attached', NEW.singular_label), 'parent', 30, 'required',
                    NEW.table_name, 'cascade', 'is attached through', ''),
                   (v_link, 'attached_to', 'Attached to',
                    'A further record the attachable record is attached to, as its record reference <table_name>:<key>. Set when the link is created and never changed.',
                    'text', 40, 'required', '', '', 'has', 'attached_to');
            -- One link per record and target, and the one index of
            -- attached_to (add_dd_field builds none for a link table): led by
            -- it under text_pattern_ops, it also serves the lookups by the
            -- prefix of a table's references. attached_to comes first because
            -- the dictionary builds idx_<link>_<entity>_id for the parent
            -- field whenever its foreign key is rebuilt, and an index led by
            -- that column would only repeat it. Named as a unique_value index
            -- of its first column, so a rename of the table carries the name
            -- along (0170_dd_rename.sql).
            PERFORM dd_index_name_free(v_link, v_link, 'attached_to', v_link || '_attached_to_unique');
            EXECUTE format('CREATE UNIQUE INDEX %I ON public.%I (attached_to text_pattern_ops, %I)',
                           v_link || '_attached_to_unique', v_link, NEW.table_name || '_id');
        ELSIF NOT v_needs_link AND v_link IS NOT NULL THEN
            DELETE FROM entities WHERE table_name = v_link;
            v_link := NULL;
        END IF;

        IF NEW.attach_mode = 'none' THEN
            DELETE FROM entity_attachables WHERE attachable = NEW.table_name;
        END IF;
    END IF;

    IF TG_OP = 'UPDATE' AND OLD.table_name IS DISTINCT FROM NEW.table_name THEN
        EXECUTE format('DROP FUNCTION IF EXISTS common.%I(text[])', 'attached_' || OLD.table_name);
    END IF;

    -- The link entity follows its attachable entity's permissions and module,
    -- so a module delete does not take it from an entity that moved away.
    UPDATE entities
       SET view_permission = NEW.view_permission, edit_permission = NEW.edit_permission, module_id = NEW.module_id
     WHERE table_name = v_link
       AND (view_permission, edit_permission, module_id)
           IS DISTINCT FROM (NEW.view_permission, NEW.edit_permission, NEW.module_id);

    PERFORM dd_attach_refresh(ARRAY[NEW.table_name]);
    RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

COMMENT ON FUNCTION dd_attach_entity_changed() IS
'AFTER INSERT, UPDATE and DELETE trigger on entities: gives an entity the attached_to field and the link entity its attach mode needs and removes those it no longer needs, gives the link entity the attachable entity''s permissions and module, drops the delete step of a deleted or renamed target, and rebuilds what depends on targets and modes (dd_attach_refresh).';

REVOKE EXECUTE ON FUNCTION dd_attach_entity_changed() FROM PUBLIC;

-- A rename of an attachable entity renames its link entity <entity>_links
-- and the link field <entity>_id with it. Before the entity's own rename
-- (rename_table_trigger sorts after this one), because the rename of the link
-- entity is a rename of its own: it sets the marker dd.table_rename that the
-- triggers of its fields rows check, and the fields rows of the entity
-- renamed here are moved by a cascade whose triggers fire only after every
-- AFTER trigger of this statement, so they must find this entity's marker
-- there. Run here, the rename of the link entity is complete before the
-- entity's begins. a_reserve_table_namespace_trigger has checked the new name
-- before; a name longer than an attachable entity's (dd_attach_name_max) is
-- left to check_entity_attach (91004), which runs after this trigger.
CREATE OR REPLACE FUNCTION dd_attach_link_rename()
RETURNS TRIGGER AS $$
BEGIN
    UPDATE entities SET table_name = NEW.table_name || '_links' WHERE link_of = OLD.table_name;
    UPDATE fields SET field_name = NEW.table_name || '_id'
     WHERE table_name = NEW.table_name || '_links' AND field_name = OLD.table_name || '_id';
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

COMMENT ON FUNCTION dd_attach_link_rename() IS
'BEFORE UPDATE trigger on entities: when an owned_shared or multiple entity is renamed, renames its link entity to <new name>_links and the link field to <new name>_id first.';

REVOKE EXECUTE ON FUNCTION dd_attach_link_rename() FROM PUBLIC;

CREATE OR REPLACE TRIGGER b_attach_link_rename_trigger
    BEFORE UPDATE ON entities
    FOR EACH ROW
    WHEN (OLD.table_name IS DISTINCT FROM NEW.table_name AND OLD.attach_mode IN ('owned_shared', 'multiple')
          AND octet_length(NEW.table_name) <= dd_attach_name_max())
    EXECUTE FUNCTION dd_attach_link_rename();

CREATE OR REPLACE TRIGGER zz_attach_entity_insert_trigger
    AFTER INSERT ON entities
    FOR EACH ROW
    WHEN (NEW.attach_mode <> 'none' OR NEW.id_type = 'is_a')
    EXECUTE FUNCTION dd_attach_entity_changed();

CREATE OR REPLACE TRIGGER zz_attach_entity_update_trigger
    AFTER UPDATE ON entities
    FOR EACH ROW
    WHEN (OLD.attach_mode IS DISTINCT FROM NEW.attach_mode
       OR OLD.attach_permission IS DISTINCT FROM NEW.attach_permission
       OR OLD.attach_on_target_delete IS DISTINCT FROM NEW.attach_on_target_delete
       OR OLD.table_name IS DISTINCT FROM NEW.table_name
       OR OLD.view_permission IS DISTINCT FROM NEW.view_permission
       OR OLD.edit_permission IS DISTINCT FROM NEW.edit_permission
       OR OLD.select_rule IS DISTINCT FROM NEW.select_rule
       OR OLD.managed IS DISTINCT FROM NEW.managed
       OR OLD.module_id IS DISTINCT FROM NEW.module_id)
    EXECUTE FUNCTION dd_attach_entity_changed();

CREATE OR REPLACE TRIGGER zz_attach_entity_delete_trigger
    AFTER DELETE ON entities
    FOR EACH ROW
    EXECUTE FUNCTION dd_attach_entity_changed();

-- On an upgrade the dictionary's definer code already runs as
-- semantius_owner, while a function new in this file stays owned by the
-- installer until 9900_owner_hardening.sql runs last.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'semantius_owner') THEN
        GRANT EXECUTE ON FUNCTION
            dd_attachments_exist(TEXT, TEXT[]),
            common.attach_record_rules(TEXT, TEXT),
            common.attach_target(TEXT, TEXT, BOOLEAN),
            common.attached_step(),
            dd_attach_may_edit(TEXT[]),
            dd_attach_cycle_check(TEXT, TEXT),
            dd_attach_name_max(),
            dd_build_attached_triggers(TEXT),
            dd_attach_refresh(TEXT[])
        TO semantius_owner;
    END IF;
END $$;
