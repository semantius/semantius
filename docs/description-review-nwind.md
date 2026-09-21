# Description review — nwind

Same rules as [description-review.md](description-review.md), applied to
`apps/nwind/migrations/0010_create.sql`. nwind was NOT touched by the 18 Sep
rework, so there is no "old" column: current text is original text.

36 fields carry a description. Most nwind fields have none at all (`''`), which
is already the state `_core` is being moved toward.

| action | count |
|---|---|
| remove — restates the reference | 9 |
| remove — restates the title | 6 |
| retitle + remove description | 2 |
| retitle + trim description | 2 |
| keep | 17 |
| title case only | 3 |

## Remove — restates the reference

`reference_table` names the target and `relationship_label` already carries the verb.

| entity.field | title | current | suggested |
|---|---|---|---|
| `employee_territories.employee_id` | Employee | Reference to the employee | remove |
| `employee_territories.territory_id` | Territory | Reference to the territory | remove |
| `order_details.order_id` | Order | Reference to the order | remove |
| `order_details.product_id` | Product | Reference to the product | remove |
| `products.category_id` | Category | Category this product belongs to | remove |
| `products.supplier_id` | Supplier | Supplier providing this product | remove (relationship_label = `supplies`) |
| `orders.customer_id` | Customer | Customer who placed the order | remove (relationship_label = `places`) |
| `orders.employee_id` | Employee | Employee who handled the order | remove (relationship_label = `handles`) |
| `territories.region_id` | Region | Region this territory belongs to | remove |

## Remove — restates the title

| entity.field | title | current | suggested |
|---|---|---|---|
| `categories.description` | Description | Description of the product category | remove |
| `employees.title_of_courtesy` | Title of Courtesy | Courtesy title (Mr., Ms., Dr., etc.) | remove — and it **contradicts** its own `enum_values` `["Mr.","Mrs.","Ms.","Dr."]`, which the comment appends anyway, so the column comment lists Mrs. and omits it in the same breath |
| `suppliers.homepage` | Homepage | Supplier website URL | remove — format is already `url` |
| `products.units_in_stock` | Units In Stock | Current stock quantity | remove |
| `products.discontinued` | Discontinued | Whether the product is discontinued | remove |
| `orders.status` | Status | Order lifecycle state | remove — `enum_values` `pending, shipped` is appended |

## Retitle + remove description

The title does not name the target, so the description is carrying that job.
Fix the title instead.

| entity.field | title | current | suggested |
|---|---|---|---|
| `employees.reports_to` | Reports To | Manager this employee reports to | **Reports To** → **Manager**, remove description |
| `orders.ship_via` | Shipped Via | Shipper used for this order | **Shipped Via** → **Shipper**, remove description |

## Retitle + trim description

Both are natural business keys — text codes, not references — so the `_id` rule
would produce a title that lies (`Customer` is already `orders.customer_id`).
`Code` says what they actually hold. `Unique` restates `unique_value = TRUE`.

| entity.field | title | current | suggested |
|---|---|---|---|
| `customers.customer_id` | Customer Id | Unique short code identifying the customer | **Customer Code**, trim to `Short code identifying the customer` |
| `territories.territory_id` | Territory Id | Unique code identifying the territory | **Territory Code**, trim to `Code identifying the territory` |

## Title case only

Short prepositions are lower case elsewhere in the file (`Title of Courtesy`).

| entity.field | title | suggested |
|---|---|---|
| `products.units_in_stock` | Units In Stock | Units in Stock |
| `products.units_on_order` | Units On Order | Units on Order |
| `products.quantity_per_unit` | Quantity Per Unit | Quantity per Unit |

## Keep — 17

`customers.contact_title`, `customers.region`, `customers.postal_code`,
`customers.phone`, `employees.title`, `employees.region`, `employees.postal_code`,
`employees.extension`, `suppliers.contact_title`, `suppliers.region`,
`suppliers.postal_code`, `suppliers.phone`, `products.quantity_per_unit`,
`products.units_on_order`, `products.reorder_level`, `orders.ship_region`,
`orders.freight`, `order_details.unit_price`, `order_details.quantity`,
`order_details.discount`.

`order_details.unit_price` ("Actual price per unit charged on this order") earns
its place precisely because `products.unit_price` exists and differs.

## Cross-cutting: what the trigger change does to nwind

All 11 nwind entities get their id and label fields from `create_dd_table`, so
today every one of them carries `Name that identifies this customer` and
`Internal identifier, assigned automatically` in a provisioned database — none of
it visible in this file. The trigger fix removes that for all of them.

The label **title** change (seeding `Name` instead of `singular_label`) needs a
decision here: it turns `customers.company_name` from `Customer` into `Name` and
`orders.ship_name` from `Order` into `Name`. For `employees.last_name` the file
already patches the title by hand at line 284, which is evidence the generated
title was wrong; but `Name` is not right for a company name or a ship-to name
either. Both may want their own explicit title in this file.
