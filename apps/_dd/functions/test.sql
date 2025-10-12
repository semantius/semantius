CREATE OR REPLACE FUNCTION get_server_date_and_locale()
RETURNS TABLE (
    server_date DATE,
    server_timezone TEXT,
    time_locale TEXT,
    collate_locale TEXT,
    ctype_locale TEXT
) 
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        CURRENT_DATE,
        current_setting('TimeZone'),
        current_setting('lc_time'),
        current_setting('lc_collate'),
        current_setting('lc_ctype');
END;
$$;