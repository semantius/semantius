# Database Naming Conventions

## Core Rules

### Tables
- **Use plural nouns**: `customers`, `orders`, `users`, `products`, `deals`, `contacts`
- Avoids SQL reserved words (`user` → `users`, `order` → `orders`)

### Primary Keys
- **Always named `id`** (never prefixed)
- Every table has exactly one primary key column named `id`

```sql
customers.id
orders.id
users.id
products.id
```

### Foreign Keys
- **Pattern**: `{singular_table_name}_id`
- References the `id` column of the target table

```sql
orders.customer_id → customers.id
orders.assigned_user_id → users.id
deals.customer_id → customers.id
deals.contact_id → contacts.id
order_items.order_id → orders.id
order_items.product_id → products.id
```

### Regular Columns
- **Use singular form** when prefixing with table entity name
- Use descriptive, unambiguous names

```sql
products.product_name (or products.name if context is clear)
products.product_code
customers.company_name
customers.customer_type
orders.order_date
orders.order_number
```

## Quick Reference

| Element | Pattern | Example |
|---------|---------|---------|
| Table | Plural noun | `customers`, `orders` |
| Primary Key | `id` | `customers.id` |
| Foreign Key | `{singular}_id` | `orders.customer_id` |
| Column | Singular prefix (when needed) | `products.product_name` |

## Join Pattern Examples

```sql
-- Standard join using convention
SELECT 
    c.company_name,
    o.order_date,
    o.order_number
FROM orders o
JOIN customers c ON o.customer_id = c.id;

-- Multi-table join
SELECT 
    c.company_name,
    d.deal_name,
    u.email as owner_email
FROM deals d
JOIN customers c ON d.customer_id = c.id
JOIN users u ON d.owner_user_id = u.id;
```

## LLM Query Generation Rules

1. **Primary keys**: Always `{table}.id`
2. **Foreign key lookup**: `{child_table}.{singular_parent}_id = {parent_table}.id`
3. **Column prefixes**: Use singular form of entity name
4. **Self-joins**: Append descriptive suffix to foreign key (e.g., `parent_customer_id`, `referred_by_user_id`)

## Special Cases

### Self-Referencing Foreign Keys
Use descriptive suffixes:
```sql
customers.parent_customer_id → customers.id
users.manager_user_id → users.id
categories.parent_category_id → categories.id
```

### Many-to-Many Junction Tables
Use both table names in alphabetical order (singular or plural based on preference):
```sql
-- Option 1: Both plural
products_tags (product_id, tag_id)

-- Option 2: Both singular  
product_tag (product_id, tag_id)
```

### Lookup/Reference Tables
Simple tables typically use just `name`:
```sql
statuses.name
categories.name
tags.name
```

## Benefits of This Convention

- ✅ Avoids SQL reserved words
- ✅ Self-documenting foreign key relationships
- ✅ Predictable for automated query generation
- ✅ Industry-standard pattern (Rails, Laravel, Salesforce)
- ✅ Clear distinction between primary keys (`id`) and foreign keys (`*_id`)