-- =====================================================
-- _SETTINGS TABLE
-- =====================================================
-- Stores system-level configuration key/value pairs.
-- RLS is enabled with an explicit deny-all policy so that
-- the table is never exposed through PostgREST / the Data API.
-- SECURITY DEFINER functions (e.g. rbac.uid()) can still read
-- it because they run as the function owner who has BYPASSRLS.
-- =====================================================

CREATE TABLE _settings (
    name  TEXT PRIMARY KEY,
    value TEXT NOT NULL DEFAULT ''
);

-- Enable RLS — default is deny-all with no policies
ALTER TABLE _settings ENABLE ROW LEVEL SECURITY;

-- Explicit deny-all policy so that pg_policies contains an entry
-- for this table (required by the security audit in 0060_test_security.sql)
-- while still granting zero access to the semantius_user role.
CREATE POLICY settings_deny_all ON _settings
    FOR ALL
    TO semantius_user
    USING (false)
    WITH CHECK (false);
