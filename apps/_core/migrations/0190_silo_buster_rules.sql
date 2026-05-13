-- =====================================================
-- SILO BUSTER VALIDATION RULES (§10.2)
-- =====================================================
-- Install server-side validation rules on the roles and permission_hierarchy
-- core entities. These use the platform's value_changed operator to protect
-- origin and slug columns from invalid transitions.
--
-- Must run AFTER 0180_computed_validation.sql so the trigger generator
-- (build_record_logic_trigger) is available.

-- =====================================================
-- Rule 1 & 2: roles entity — origin_immutable_roles + system_role_slug_immutable
-- =====================================================

UPDATE entities
SET validation_rules = '[
  {
    "code": "origin_immutable_roles",
    "message": "roles.origin can only be set on INSERT or upgraded from ''user'' to ''default'' by the scaffold pass",
    "source_module": "platform",
    "jsonlogic": {
      "if": [
        { "value_changed": "origin" },
        {
          "or": [
            { "==": [{ "var": "$old" }, null] },
            { "and": [
              { "==": [{ "var": "$old.origin" }, "user"] },
              { "==": [{ "var": "origin" }, "default"] }
            ]}
          ]
        },
        true
      ]
    }
  },
  {
    "code": "system_role_slug_immutable",
    "message": "system role slugs (origin=''default'') cannot be changed after creation",
    "source_module": "platform",
    "jsonlogic": {
      "if": [
        { "and": [
          { "value_changed": "slug" },
          { "==": [{ "var": "origin" }, "default"] }
        ]},
        { "==": [{ "var": "$old" }, null] },
        true
      ]
    }
  }
]'::jsonb
WHERE table_name = 'roles';

-- =====================================================
-- Rule 3: permission_hierarchy entity — origin_immutable_hierarchy
-- =====================================================

UPDATE entities
SET validation_rules = '[
  {
    "code": "origin_immutable_hierarchy",
    "message": "permission_hierarchy.origin is set on INSERT and cannot be changed",
    "source_module": "platform",
    "jsonlogic": {
      "if": [
        { "value_changed": "origin" },
        { "==": [{ "var": "$old" }, null] },
        true
      ]
    }
  }
]'::jsonb
WHERE table_name = 'permission_hierarchy';
