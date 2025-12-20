


---
--- drop tables
---


DROP TABLE IF EXISTS customer_customer_demo;
DROP TABLE IF EXISTS customer_demographics;
DROP TABLE IF EXISTS employee_territories;
DROP TABLE IF EXISTS order_details;
DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS customers;
DROP TABLE IF EXISTS products;
DROP TABLE IF EXISTS shippers;
DROP TABLE IF EXISTS suppliers;
DROP TABLE IF EXISTS territories;
DROP TABLE IF EXISTS us_states;
DROP TABLE IF EXISTS categories;
DROP TABLE IF EXISTS region;
DROP TABLE IF EXISTS employees;

--
-- Name: categories; Type: TABLE; Schema: public; Owner: -; Tablespace: 
--

CREATE TABLE categories (
    category_id smallint NOT NULL PRIMARY KEY,
    category_name character varying(15) NOT NULL DEFAULT '',
    description text DEFAULT '',
    picture bytea
);


--
-- Name: customer_demographics; Type: TABLE; Schema: public; Owner: -; Tablespace: 
--

CREATE TABLE customer_demographics (
    customer_type_id bpchar NOT NULL PRIMARY KEY,
    customer_desc text DEFAULT ''
);


--
-- Name: customers; Type: TABLE; Schema: public; Owner: -; Tablespace: 
--

CREATE TABLE customers (
    customer_id bpchar NOT NULL PRIMARY KEY,
    company_name character varying(40) NOT NULL DEFAULT '',
    contact_name character varying(30) DEFAULT '',
    contact_title character varying(30) DEFAULT '',
    address character varying(60) DEFAULT '',
    city character varying(15) DEFAULT '',
    region character varying(15) DEFAULT '',
    postal_code character varying(10) DEFAULT '',
    country character varying(15) DEFAULT '',
    phone character varying(24) DEFAULT '',
    fax character varying(24) DEFAULT ''
);

--
-- Name: customer_customer_demo; Type: TABLE; Schema: public; Owner: -; Tablespace: 
--

CREATE TABLE customer_customer_demo (
    customer_id bpchar NOT NULL DEFAULT '',
    customer_type_id bpchar NOT NULL DEFAULT '',
    PRIMARY KEY (customer_id, customer_type_id),
    FOREIGN KEY (customer_type_id) REFERENCES customer_demographics,
    FOREIGN KEY (customer_id) REFERENCES customers
);

--
-- Name: employees; Type: TABLE; Schema: public; Owner: -; Tablespace: 
--

CREATE TABLE employees (
    employee_id smallint NOT NULL PRIMARY KEY,
    last_name character varying(20) NOT NULL DEFAULT '',
    first_name character varying(10) NOT NULL DEFAULT '',
    title character varying(30) DEFAULT '',
    title_of_courtesy character varying(25) DEFAULT '',
    birth_date date,
    hire_date date,
    address character varying(60) DEFAULT '',
    city character varying(15) DEFAULT '',
    region character varying(15) DEFAULT '',
    postal_code character varying(10) DEFAULT '',
    country character varying(15) DEFAULT '',
    home_phone character varying(24) DEFAULT '',
    extension character varying(4) DEFAULT '',
    photo bytea,
    notes text DEFAULT '',
    reports_to smallint,
    photo_path character varying(255) DEFAULT '',
	FOREIGN KEY (reports_to) REFERENCES employees
);


--
-- Name: suppliers; Type: TABLE; Schema: public; Owner: -; Tablespace: 
--

CREATE TABLE suppliers (
    supplier_id smallint NOT NULL PRIMARY KEY,
    company_name character varying(40) NOT NULL DEFAULT '',
    contact_name character varying(30) DEFAULT '',
    contact_title character varying(30) DEFAULT '',
    address character varying(60) DEFAULT '',
    city character varying(15) DEFAULT '',
    region character varying(15) DEFAULT '',
    postal_code character varying(10) DEFAULT '',
    country character varying(15) DEFAULT '',
    phone character varying(24) DEFAULT '',
    fax character varying(24) DEFAULT '',
    homepage text DEFAULT ''
);


--
-- Name: products; Type: TABLE; Schema: public; Owner: -; Tablespace: 
--

CREATE TABLE products (
    product_id smallint NOT NULL PRIMARY KEY,
    product_name character varying(40) NOT NULL DEFAULT '',
    supplier_id smallint,
    category_id smallint,
    quantity_per_unit character varying(20) DEFAULT '',
    unit_price real DEFAULT 0.0,
    units_in_stock smallint DEFAULT 0,
    units_on_order smallint DEFAULT 0,
    reorder_level smallint DEFAULT 0,
    discontinued integer NOT NULL DEFAULT 0,
	FOREIGN KEY (category_id) REFERENCES categories,
	FOREIGN KEY (supplier_id) REFERENCES suppliers
);


--
-- Name: region; Type: TABLE; Schema: public; Owner: -; Tablespace: 
--

CREATE TABLE region (
    region_id smallint NOT NULL PRIMARY KEY,
    region_description bpchar NOT NULL DEFAULT ''
);


--
-- Name: shippers; Type: TABLE; Schema: public; Owner: -; Tablespace: 
--

CREATE TABLE shippers (
    shipper_id smallint NOT NULL PRIMARY KEY,
    company_name character varying(40) NOT NULL DEFAULT '',
    phone character varying(24) DEFAULT ''
);


--
-- Name: orders; Type: TABLE; Schema: public; Owner: -; Tablespace: 
--

CREATE TABLE orders (
    order_id smallint NOT NULL PRIMARY KEY,
    customer_id bpchar,
    employee_id smallint,
    order_date date,
    required_date date,
    shipped_date date,
    ship_via smallint,
    freight real DEFAULT 0.0,
    ship_name character varying(40) DEFAULT '',
    ship_address character varying(60) DEFAULT '',
    ship_city character varying(15) DEFAULT '',
    ship_region character varying(15) DEFAULT '',
    ship_postal_code character varying(10) DEFAULT '',
    ship_country character varying(15) DEFAULT '',
    FOREIGN KEY (customer_id) REFERENCES customers,
    FOREIGN KEY (employee_id) REFERENCES employees,
    FOREIGN KEY (ship_via) REFERENCES shippers
);


--
-- Name: territories; Type: TABLE; Schema: public; Owner: -; Tablespace: 
--

CREATE TABLE territories (
    territory_id character varying(20) NOT NULL PRIMARY KEY,
    territory_description bpchar NOT NULL DEFAULT '',
    region_id smallint NOT NULL DEFAULT 0,
	FOREIGN KEY (region_id) REFERENCES region
);


--
-- Name: employee_territories; Type: TABLE; Schema: public; Owner: -; Tablespace: 
--

CREATE TABLE employee_territories (
    employee_id smallint NOT NULL DEFAULT 0,
    territory_id character varying(20) NOT NULL DEFAULT '',
    PRIMARY KEY (employee_id, territory_id),
    FOREIGN KEY (territory_id) REFERENCES territories,
    FOREIGN KEY (employee_id) REFERENCES employees
);


--
-- Name: order_details; Type: TABLE; Schema: public; Owner: -; Tablespace: 
--

CREATE TABLE order_details (
    order_id smallint NOT NULL DEFAULT 0,
    product_id smallint NOT NULL DEFAULT 0,
    unit_price real NOT NULL DEFAULT 0.0,
    quantity smallint NOT NULL DEFAULT 0,
    discount real NOT NULL DEFAULT 0.0,
    PRIMARY KEY (order_id, product_id),
    FOREIGN KEY (product_id) REFERENCES products,
    FOREIGN KEY (order_id) REFERENCES orders
);


--
-- Name: us_states; Type: TABLE; Schema: public; Owner: -; Tablespace: 
--

CREATE TABLE us_states (
    state_id smallint NOT NULL PRIMARY KEY,
    state_name character varying(100) DEFAULT '',
    state_abbr character varying(2) DEFAULT '',
    state_region character varying(50) DEFAULT ''
);