CREATE TABLE _tables (
    name TEXT PRIMARY KEY
);

CREATE TABLE _fields (
    table_name TEXT NOT NULL,
    name TEXT NOT NULL,
    description TEXT,
    column_type TEXT,
    PRIMARY KEY (table_name, name),
    FOREIGN KEY (table_name) REFERENCES _tables(name) ON DELETE CASCADE
);