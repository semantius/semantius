-- =====================================================
-- BACKWARD COMPATIBILITY VIEW
-- =====================================================
-- Create an updatable view named "tables" that maps to "entities" table
-- This ensures external applications using the old "tables" name continue to work
-- Goal: semantius-core uses "entities", but old apps can still use "tables" view
-- =====================================================

-- Create updatable view that maps to entities table
CREATE OR REPLACE VIEW tables AS
SELECT 
    table_name,
    singular,
    plural,
    singular_label,
    plural_label,
    icon_url,
    description,
    module_id,
    view_permission,
    edit_permission,
    id_column,
    label_column,
    managed,
    searchable,
    created_at,
    updated_at
FROM entities;

COMMENT ON VIEW tables IS 
'Backward compatibility view for entities table. External apps can continue using "tables" name while semantius-core uses "entities".';

-- Make the view updatable with INSTEAD OF triggers
-- This allows INSERT/UPDATE/DELETE operations on the view to work transparently

CREATE OR REPLACE FUNCTION tables_instead_of_insert()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO entities (
        table_name,
        singular,
        plural,
        singular_label,
        plural_label,
        icon_url,
        description,
        module_id,
        view_permission,
        edit_permission,
        id_column,
        label_column,
        managed,
        searchable
    ) VALUES (
        NEW.table_name,
        NEW.singular,
        NEW.plural,
        NEW.singular_label,
        NEW.plural_label,
        NEW.icon_url,
        NEW.description,
        NEW.module_id,
        NEW.view_permission,
        NEW.edit_permission,
        NEW.id_column,
        NEW.label_column,
        NEW.managed,
        NEW.searchable
    );
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER tables_insert_trigger
    INSTEAD OF INSERT ON tables
    FOR EACH ROW
    EXECUTE FUNCTION tables_instead_of_insert();

CREATE OR REPLACE FUNCTION tables_instead_of_update()
RETURNS TRIGGER AS $$
BEGIN
    UPDATE entities SET
        singular = NEW.singular,
        plural = NEW.plural,
        singular_label = NEW.singular_label,
        plural_label = NEW.plural_label,
        icon_url = NEW.icon_url,
        description = NEW.description,
        module_id = NEW.module_id,
        view_permission = NEW.view_permission,
        edit_permission = NEW.edit_permission,
        id_column = NEW.id_column,
        label_column = NEW.label_column,
        managed = NEW.managed,
        searchable = NEW.searchable
    WHERE table_name = OLD.table_name;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER tables_update_trigger
    INSTEAD OF UPDATE ON tables
    FOR EACH ROW
    EXECUTE FUNCTION tables_instead_of_update();

CREATE OR REPLACE FUNCTION tables_instead_of_delete()
RETURNS TRIGGER AS $$
BEGIN
    DELETE FROM entities WHERE table_name = OLD.table_name;
    RETURN OLD;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER tables_delete_trigger
    INSTEAD OF DELETE ON tables
    FOR EACH ROW
    EXECUTE FUNCTION tables_instead_of_delete();

COMMENT ON FUNCTION tables_instead_of_insert IS 
'INSTEAD OF INSERT trigger function for tables view to support backward compatibility';

COMMENT ON FUNCTION tables_instead_of_update IS 
'INSTEAD OF UPDATE trigger function for tables view to support backward compatibility';

COMMENT ON FUNCTION tables_instead_of_delete IS 
'INSTEAD OF DELETE trigger function for tables view to support backward compatibility';
