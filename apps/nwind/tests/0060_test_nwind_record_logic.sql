-- =====================================================
-- NORTHWIND RECORD LOGIC TESTS (0060)
-- =====================================================
-- The rules the Northwind metadata ships on orders and order_details, through
-- the functions the dictionary generates from them: the numbered label and the
-- computed total of an order, the computed label and amount of a line, and the
-- subtotal rollup from the lines to their order (common.rollup_order_details_order_id
-- with its insert, update, delete and truncate triggers and the guard on orders).
-- Each trigger arm is fired and the parent total is asserted every time:
-- single and multi-parent inserts, a changed quantity, a changed discount, a
-- line moved to another order, two orders swapping their lines, a delete
-- that spans two orders, statements that touch no row, and a truncate.
-- Writes are made as user2 (Northwind Sales); the statements that need table
-- ownership run as the connecting role. Everything is rolled back.
-- Requires: deno task migrate --apps _core,nwind,test
-- =====================================================

BEGIN;

SELECT plan(39);

-- Look-ups by name, so no id of the seed is written into a test.
CREATE FUNCTION pg_temp.ord(p_ship_name TEXT) RETURNS BIGINT LANGUAGE sql AS $fn$
    SELECT id FROM public.orders WHERE ship_name = p_ship_name
$fn$;

CREATE FUNCTION pg_temp.prod(p_name TEXT) RETURNS BIGINT LANGUAGE sql AS $fn$
    SELECT id FROM public.products WHERE product_name = p_name
$fn$;

-- "subtotal total" of an order, as text so the scale is part of the answer.
CREATE FUNCTION pg_temp.money(p_ship_name TEXT) RETURNS TEXT LANGUAGE sql AS $fn$
    SELECT subtotal || ' ' || total FROM public.orders WHERE ship_name = p_ship_name
$fn$;

SELECT authenticate_as('user2');

-- =====================================================
-- orders: the numbered label and the computed total
-- =====================================================

INSERT INTO orders (ship_name, customer_id, freight)
VALUES ('RL Order A', (SELECT id FROM customers WHERE customer_id = 'ALFKI'), 5.00),
       ('RL Order B', (SELECT id FROM customers WHERE customer_id = 'ALFKI'), 0),
       ('RL Order C', (SELECT id FROM customers WHERE customer_id = 'ALFKI'), 1.00);

SELECT is(
    (SELECT label FROM orders WHERE ship_name = 'RL Order A'),
    'SO-' || pg_temp.ord('RL Order A'),
    'orders: an insert derives label from the id');

SELECT is(pg_temp.money('RL Order A'), '0.00 5.00',
    'orders: an insert derives total as subtotal plus freight');

UPDATE orders SET freight = 7.50 WHERE ship_name = 'RL Order A';

SELECT is(pg_temp.money('RL Order A'), '0.00 7.50',
    'orders: an update of freight moves total');

UPDATE orders SET label = 'typed', total = 1 WHERE ship_name = 'RL Order A';

SELECT is(
    (SELECT label || ' ' || total FROM orders WHERE ship_name = 'RL Order A'),
    'SO-' || pg_temp.ord('RL Order A') || ' 7.50',
    'orders: an update that writes label and total gets the kept label and the derived total back');

SELECT lives_ok(
    $$DELETE FROM orders WHERE ship_name = 'RL Order C'$$,
    'orders: a delete reaches the computed fields and passes');

SELECT is(
    (SELECT count(*)::int FROM orders WHERE ship_name = 'RL Order C'),
    0,
    'orders: the deleted order is gone');

-- =====================================================
-- order_details: the computed label and amount
-- =====================================================

INSERT INTO order_details (order_id, product_id, unit_price, quantity, discount)
VALUES (pg_temp.ord('RL Order A'), pg_temp.prod('Queso Cabrales'), 10.00, 3, 10);

SELECT is(
    (SELECT label || ' ' || amount FROM order_details WHERE order_id = pg_temp.ord('RL Order A')),
    '3 × Queso Cabrales 27.00',
    'order_details: an insert derives label from quantity and product and amount from the price, quantity and discount');

UPDATE order_details SET quantity = 5 WHERE order_id = pg_temp.ord('RL Order A');

SELECT is(
    (SELECT label || ' ' || amount FROM order_details WHERE order_id = pg_temp.ord('RL Order A')),
    '5 × Queso Cabrales 45.00',
    'order_details: an update of the quantity re-derives label and amount');

UPDATE order_details SET product_id = pg_temp.prod('Singaporean Hokkien Fried Mee')
 WHERE order_id = pg_temp.ord('RL Order A');

SELECT is(
    (SELECT label FROM order_details WHERE order_id = pg_temp.ord('RL Order A')),
    '5 × Singaporean Hokkien Fried Mee',
    'order_details: an update of the product re-derives the label from the new product');

UPDATE order_details SET amount = 1 WHERE order_id = pg_temp.ord('RL Order A');

SELECT is(
    (SELECT amount FROM order_details WHERE order_id = pg_temp.ord('RL Order A')),
    45.00,
    'order_details: an update that writes amount gets the derived value back');

-- =====================================================
-- The subtotal rollup: the parent total after every kind of write
-- =====================================================
-- Order A holds one line of 45.00 and has freight 7.50.

SELECT is(pg_temp.money('RL Order A'), '45.00 52.50',
    'rollup: the lines written so far are summed into the subtotal and the total follows');

-- Two lines of one order in a single statement.
INSERT INTO order_details (order_id, product_id, unit_price, quantity)
VALUES (pg_temp.ord('RL Order A'), pg_temp.prod('Queso Cabrales'), 4.50, 2),
       (pg_temp.ord('RL Order A'), pg_temp.prod('Queso Cabrales'), 1.00, 1);

SELECT is(pg_temp.money('RL Order A'), '55.00 62.50',
    'rollup insert: two lines of one order in one statement move its subtotal by both');

-- Lines of two orders in a single statement.
INSERT INTO order_details (order_id, product_id, unit_price, quantity)
VALUES (pg_temp.ord('RL Order A'), pg_temp.prod('Queso Cabrales'), 20.00, 1),
       (pg_temp.ord('RL Order B'), pg_temp.prod('Queso Cabrales'), 50.00, 2);

SELECT is(pg_temp.money('RL Order A'), '75.00 82.50',
    'rollup insert: a statement that spans two orders moves the first');

SELECT is(pg_temp.money('RL Order B'), '100.00 100.00',
    'rollup insert: a statement that spans two orders moves the second');

UPDATE order_details SET quantity = 4
 WHERE order_id = pg_temp.ord('RL Order A') AND unit_price = 4.50;

SELECT is(pg_temp.money('RL Order A'), '84.00 91.50',
    'rollup update: a changed quantity moves the subtotal through the amount');

UPDATE order_details SET discount = 50
 WHERE order_id = pg_temp.ord('RL Order A') AND unit_price = 20.00;

SELECT is(pg_temp.money('RL Order A'), '74.00 81.50',
    'rollup update: a changed discount moves the subtotal through the amount');

UPDATE order_details SET order_id = order_id WHERE order_id = pg_temp.ord('RL Order A');

SELECT is(pg_temp.money('RL Order A'), '74.00 81.50',
    'rollup update: a write that changes neither the order nor the amount leaves the subtotal alone');

UPDATE order_details SET order_id = pg_temp.ord('RL Order B')
 WHERE order_id = pg_temp.ord('RL Order A') AND unit_price = 1.00;

SELECT is(pg_temp.money('RL Order A'), '73.00 80.50',
    'rollup update: a line moved to another order leaves the order it came from');

SELECT is(pg_temp.money('RL Order B'), '101.00 101.00',
    'rollup update: a line moved to another order joins the order it went to');

-- Two orders trade all their lines in one statement: each is both the old and
-- the new order of some row.
UPDATE order_details
   SET order_id = CASE WHEN order_id = pg_temp.ord('RL Order A')
                       THEN pg_temp.ord('RL Order B')
                       ELSE pg_temp.ord('RL Order A') END
 WHERE order_id IN (pg_temp.ord('RL Order A'), pg_temp.ord('RL Order B'));

SELECT is(pg_temp.money('RL Order A'), '101.00 108.50',
    'rollup update: two orders that swap their lines each take the other''s subtotal (first)');

SELECT is(pg_temp.money('RL Order B'), '73.00 73.00',
    'rollup update: two orders that swap their lines each take the other''s subtotal (second)');

DELETE FROM order_details
 WHERE order_id = pg_temp.ord('RL Order A') AND unit_price = 1.00;

SELECT is(pg_temp.money('RL Order A'), '100.00 107.50',
    'rollup delete: a deleted line leaves its order');

DELETE FROM order_details
 WHERE order_id IN (pg_temp.ord('RL Order A'), pg_temp.ord('RL Order B'));

SELECT is(pg_temp.money('RL Order A'), '0.00 7.50',
    'rollup delete: a statement that spans two orders empties the first');

SELECT is(pg_temp.money('RL Order B'), '0.00 0.00',
    'rollup delete: a statement that spans two orders empties the second');

-- =====================================================
-- Statements that touch no row, and TRUNCATE
-- =====================================================
-- The guard on orders recomputes any subtotal that is written by hand, so a
-- stale subtotal can only be left in place with the guard disabled. A stale
-- subtotal shows which statements recompute a parent: a statement that touches
-- no row recomputes nothing, one that touches a line recomputes its order,
-- and TRUNCATE recomputes every order.

INSERT INTO order_details (order_id, product_id, unit_price, quantity)
VALUES (pg_temp.ord('RL Order A'), pg_temp.prod('Queso Cabrales'), 10.00, 2);

RESET ROLE;
SET LOCAL search_path TO public, pgtap;

ALTER TABLE orders DISABLE TRIGGER a_rollup_guard;
UPDATE orders SET subtotal = 999 WHERE ship_name IN ('RL Order A', 'RL Order B');

SELECT is(pg_temp.money('RL Order A'), '999.00 1006.50',
    'fixture: with the guard disabled a written subtotal stays');

SELECT lives_ok(
    $$INSERT INTO order_details (order_id, product_id, unit_price, quantity)
      SELECT pg_temp.ord('RL Order A'), pg_temp.prod('Queso Cabrales'), 1.00, 1 WHERE false$$,
    'rollup insert: a statement that inserts no row runs');

SELECT lives_ok(
    $$UPDATE order_details SET quantity = quantity + 1 WHERE false$$,
    'rollup update: a statement that updates no row runs');

SELECT lives_ok(
    $$DELETE FROM order_details WHERE false$$,
    'rollup delete: a statement that deletes no row runs');

SELECT is(pg_temp.money('RL Order A'), '999.00 1006.50',
    'rollup: statements that touch no row recompute no order (a)');

SELECT is(pg_temp.money('RL Order B'), '999.00 999.00',
    'rollup: statements that touch no row recompute no order (b)');

UPDATE order_details SET quantity = quantity WHERE order_id = pg_temp.ord('RL Order A');

SELECT is(pg_temp.money('RL Order A'), '20.00 27.50',
    'rollup update: a statement that touches a line recomputes its order');

SELECT is(pg_temp.money('RL Order B'), '999.00 999.00',
    'rollup update: and leaves an order none of its lines belongs to');

SELECT cmp_ok(
    (SELECT count(*)::int FROM orders WHERE subtotal <> 0), '>', 1,
    'fixture: the seeded orders carry subtotals before the truncate');

TRUNCATE order_details;

SELECT is(
    (SELECT count(*)::int FROM order_details),
    0,
    'rollup truncate: the lines are gone');

SELECT is(
    (SELECT count(*)::int FROM orders WHERE subtotal <> 0),
    0,
    'rollup truncate: every order is recomputed to the empty sum');

SELECT is(pg_temp.money('RL Order B'), '0.00 0.00',
    'rollup truncate: an order without lines gets the empty sum as well');

SELECT is(pg_temp.money('RL Order A'), '0.00 7.50',
    'rollup truncate: the total follows the subtotal');

ALTER TABLE orders ENABLE TRIGGER a_rollup_guard;

SELECT is(
    (SELECT tgenabled::text FROM pg_trigger WHERE tgrelid = 'public.orders'::regclass AND tgname = 'a_rollup_guard'),
    'O',
    'fixture: the guard is enabled again');

-- =====================================================
-- An error out of a computed field
-- =====================================================
-- The label of a line reads its product through set_record, which
-- authenticates the caller. A request session that has lost its claims fails
-- there, and the error leaves the generated function with its own SQLSTATE,
-- message and hint code; only the entity and the field are added to the hint,
-- because nothing else in a PostgreSQL error says which rule produced it.
-- The ids are put into settings first: reading orders without claims would
-- fail on the row policy before the trigger ran.

SELECT authenticate_as('user2');
SELECT set_config('rl.order', pg_temp.ord('RL Order A')::text, true);
SELECT set_config('rl.product', pg_temp.prod('Queso Cabrales')::text, true);
DO $$
BEGIN
    PERFORM set_config('request.jwt.claim.sub', '', true);
    PERFORM set_config('request.jwt.claim.role', '', true);
END $$;

SELECT is(
    catch_error($$INSERT INTO order_details (order_id, product_id, unit_price, quantity)
                  VALUES (current_setting('rl.order')::bigint, current_setting('rl.product')::bigint, 1, 1)$$),
    jsonb_build_object(
        'code', '42501',
        'message', 'Authentication required: No valid JWT claims found',
        'details', '',
        'hint', jsonb_build_object('code', '90001', 'entity', 'order_details', 'field', 'label')::text),
    'order_details: an error out of the label rule keeps its code and message and gains the entity and the field');

SELECT * FROM finish();
ROLLBACK;
