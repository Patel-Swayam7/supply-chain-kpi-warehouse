-- =====================================================================
-- Step 2: Data Warehouse - load raw CSVs (ELT: staging -> warehouse)
-- Run after Step 1, from the project root folder:
--   mysql --local-infile=1 -u root < 01_warehouse/02_load_data.sql
--
-- Each CSV lands in an all-text staging table first, then a typed
-- INSERT ... SELECT converts dates to date keys and casts numbers.
-- =====================================================================

USE supply_chain;

-- ---------------------------------------------------------------------
-- 2a. Staging tables (all text, nothing lost on load)
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS stg_products, stg_customers, stg_warehouses,
                     stg_order_lines, stg_inventory_snapshots;

CREATE TABLE stg_products (product_id TEXT, sku TEXT, product_name TEXT, category TEXT,
                           unit_cost TEXT, unit_price TEXT);
CREATE TABLE stg_customers (customer_id TEXT, customer_name TEXT, region TEXT, segment TEXT);
CREATE TABLE stg_warehouses (warehouse_id TEXT, warehouse_name TEXT, city TEXT, state TEXT);
CREATE TABLE stg_order_lines (order_line_id TEXT, order_id TEXT, order_date TEXT, promised_date TEXT,
                              ship_date TEXT, delivery_date TEXT, product_id TEXT, customer_id TEXT,
                              warehouse_id TEXT, ordered_qty TEXT, shipped_qty TEXT,
                              unit_price TEXT, unit_cost TEXT, line_status TEXT);
CREATE TABLE stg_inventory_snapshots (snapshot_date TEXT, product_id TEXT, warehouse_id TEXT,
                                      on_hand_qty TEXT, unit_cost TEXT);

-- ---------------------------------------------------------------------
-- 2b. Load CSVs into staging
-- ---------------------------------------------------------------------
LOAD DATA LOCAL INFILE 'data/products.csv' INTO TABLE stg_products
CHARACTER SET utf8mb4 FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY ''
LINES TERMINATED BY '\n' IGNORE 1 LINES;

LOAD DATA LOCAL INFILE 'data/customers.csv' INTO TABLE stg_customers
CHARACTER SET utf8mb4 FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY ''
LINES TERMINATED BY '\n' IGNORE 1 LINES;

LOAD DATA LOCAL INFILE 'data/warehouses.csv' INTO TABLE stg_warehouses
CHARACTER SET utf8mb4 FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY ''
LINES TERMINATED BY '\n' IGNORE 1 LINES;

LOAD DATA LOCAL INFILE 'data/order_lines.csv' INTO TABLE stg_order_lines
CHARACTER SET utf8mb4 FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY ''
LINES TERMINATED BY '\n' IGNORE 1 LINES;

LOAD DATA LOCAL INFILE 'data/inventory_snapshots.csv' INTO TABLE stg_inventory_snapshots
CHARACTER SET utf8mb4 FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY ''
LINES TERMINATED BY '\n' IGNORE 1 LINES;

-- ---------------------------------------------------------------------
-- 2c. Staging -> warehouse (dimensions first, then facts)
-- Dates become integer keys: '2025-01-15' -> 20250115
-- Blank ship/delivery dates become NULL (not shipped / not delivered yet)
-- ---------------------------------------------------------------------
INSERT INTO dim_product (product_key, sku, product_name, category, unit_cost, unit_price)
SELECT CAST(product_id AS UNSIGNED), sku, product_name, category,
       CAST(unit_cost AS DECIMAL(10,2)), CAST(unit_price AS DECIMAL(10,2))
FROM stg_products;

INSERT INTO dim_customer (customer_key, customer_name, region, segment)
SELECT CAST(customer_id AS UNSIGNED), customer_name, region, segment
FROM stg_customers;

INSERT INTO dim_warehouse (warehouse_key, warehouse_name, city, state)
SELECT CAST(warehouse_id AS UNSIGNED), warehouse_name, city, state
FROM stg_warehouses;

INSERT INTO fact_order_lines (
    order_line_id, order_id, order_date_key, promised_date_key, ship_date_key,
    delivery_date_key, product_key, customer_key, warehouse_key, ordered_qty,
    shipped_qty, unit_price, unit_cost, line_status
)
SELECT
    CAST(order_line_id AS UNSIGNED),
    CAST(order_id AS UNSIGNED),
    CAST(REPLACE(order_date, '-', '') AS UNSIGNED),
    CAST(REPLACE(promised_date, '-', '') AS UNSIGNED),
    CASE WHEN ship_date = '' THEN NULL ELSE CAST(REPLACE(ship_date, '-', '') AS UNSIGNED) END,
    CASE WHEN delivery_date = '' THEN NULL ELSE CAST(REPLACE(delivery_date, '-', '') AS UNSIGNED) END,
    CAST(product_id AS UNSIGNED),
    CAST(customer_id AS UNSIGNED),
    CAST(warehouse_id AS UNSIGNED),
    CAST(ordered_qty AS UNSIGNED),
    CAST(shipped_qty AS UNSIGNED),
    CAST(unit_price AS DECIMAL(10,2)),
    CAST(unit_cost AS DECIMAL(10,2)),
    TRIM(line_status)
FROM stg_order_lines;

INSERT INTO fact_inventory_snapshot (snapshot_date_key, product_key, warehouse_key, on_hand_qty, unit_cost)
SELECT
    CAST(REPLACE(snapshot_date, '-', '') AS UNSIGNED),
    CAST(product_id AS UNSIGNED),
    CAST(warehouse_id AS UNSIGNED),
    CAST(on_hand_qty AS UNSIGNED),
    CAST(TRIM(unit_cost) AS DECIMAL(10,2))
FROM stg_inventory_snapshots;

-- ---------------------------------------------------------------------
-- 2d. Data quality checks
-- ---------------------------------------------------------------------
-- Row reconciliation: staging vs warehouse (diff should be 0 everywhere)
SELECT 'products'  AS table_name, (SELECT COUNT(*) FROM stg_products)  AS staged, (SELECT COUNT(*) FROM dim_product)  AS loaded
UNION ALL SELECT 'customers',  (SELECT COUNT(*) FROM stg_customers),  (SELECT COUNT(*) FROM dim_customer)
UNION ALL SELECT 'warehouses', (SELECT COUNT(*) FROM stg_warehouses), (SELECT COUNT(*) FROM dim_warehouse)
UNION ALL SELECT 'order_lines', (SELECT COUNT(*) FROM stg_order_lines), (SELECT COUNT(*) FROM fact_order_lines)
UNION ALL SELECT 'inventory_snapshots', (SELECT COUNT(*) FROM stg_inventory_snapshots), (SELECT COUNT(*) FROM fact_inventory_snapshot);

-- Business rule checks (all should be 0)
SELECT 'shipped more than ordered' AS rule_check, COUNT(*) AS violations
FROM fact_order_lines WHERE shipped_qty > ordered_qty
UNION ALL
SELECT 'delivered before shipped', COUNT(*)
FROM fact_order_lines WHERE delivery_date_key < ship_date_key
UNION ALL
SELECT 'shipped before ordered', COUNT(*)
FROM fact_order_lines WHERE ship_date_key < order_date_key
UNION ALL
SELECT 'open lines with a ship date', COUNT(*)
FROM fact_order_lines WHERE line_status = 'Open' AND ship_date_key IS NOT NULL
UNION ALL
SELECT 'delivered lines missing delivery date', COUNT(*)
FROM fact_order_lines WHERE line_status = 'Delivered' AND delivery_date_key IS NULL;

-- Clean up staging
DROP TABLE stg_products, stg_customers, stg_warehouses, stg_order_lines, stg_inventory_snapshots;
