-- =====================================================================
-- Step 1: Data Warehouse - create the star schema
-- Run first. Safe to re-run (drops and recreates everything).
--
--   fact_order_lines          one row per order line (grain: order line)
--   fact_inventory_snapshot   one row per product per warehouse per week
--   dim_date                  one row per calendar day
--   dim_product               one row per SKU
--   dim_customer              one row per customer
--   dim_warehouse             one row per distribution center
--
-- Facts store integer date keys (YYYYMMDD) that join to dim_date, the
-- standard warehouse pattern for fast date filtering and grouping.
-- =====================================================================

CREATE DATABASE IF NOT EXISTS supply_chain
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_0900_ai_ci;

USE supply_chain;

-- Views first, then facts, then dimensions (foreign key order)
DROP VIEW IF EXISTS vw_otif_weekly, vw_fill_rate_weekly, vw_backlog_weekly,
                    vw_inventory_turns_monthly, vw_order_line_status;
DROP TABLE IF EXISTS fact_inventory_snapshot;
DROP TABLE IF EXISTS fact_order_lines;
DROP TABLE IF EXISTS dim_date;
DROP TABLE IF EXISTS dim_product;
DROP TABLE IF EXISTS dim_customer;
DROP TABLE IF EXISTS dim_warehouse;

-- ---------------------------------------------------------------------
-- Dimensions
-- ---------------------------------------------------------------------
CREATE TABLE dim_date (
    date_key         INT PRIMARY KEY,          -- e.g. 20250115
    full_date        DATE NOT NULL UNIQUE,
    year             SMALLINT NOT NULL,
    quarter          TINYINT NOT NULL,
    month            TINYINT NOT NULL,
    month_name       VARCHAR(9) NOT NULL,
    month_label      CHAR(7) NOT NULL,         -- e.g. 2025-01
    week_start_date  DATE NOT NULL,            -- Monday of the week
    iso_week         TINYINT NOT NULL,
    day_of_week      TINYINT NOT NULL,         -- 1 = Monday ... 7 = Sunday
    day_name         VARCHAR(9) NOT NULL,
    is_weekend       BOOLEAN NOT NULL
);

CREATE TABLE dim_product (
    product_key   INT PRIMARY KEY,
    sku           VARCHAR(20) NOT NULL UNIQUE,
    product_name  VARCHAR(100) NOT NULL,
    category      VARCHAR(50) NOT NULL,
    unit_cost     DECIMAL(10,2) NOT NULL,
    unit_price    DECIMAL(10,2) NOT NULL
);

CREATE TABLE dim_customer (
    customer_key   INT PRIMARY KEY,
    customer_name  VARCHAR(100) NOT NULL,
    region         VARCHAR(30) NOT NULL,
    segment        VARCHAR(30) NOT NULL
);

CREATE TABLE dim_warehouse (
    warehouse_key   INT PRIMARY KEY,
    warehouse_name  VARCHAR(50) NOT NULL,
    city            VARCHAR(50) NOT NULL,
    state           CHAR(2) NOT NULL
);

-- ---------------------------------------------------------------------
-- Facts
-- ---------------------------------------------------------------------
CREATE TABLE fact_order_lines (
    order_line_id      INT PRIMARY KEY,
    order_id           INT NOT NULL,
    order_date_key     INT NOT NULL,
    promised_date_key  INT NOT NULL,
    ship_date_key      INT NULL,               -- NULL = not shipped yet
    delivery_date_key  INT NULL,               -- NULL = not delivered yet
    product_key        INT NOT NULL,
    customer_key       INT NOT NULL,
    warehouse_key      INT NOT NULL,
    ordered_qty        INT NOT NULL,
    shipped_qty        INT NOT NULL,
    unit_price         DECIMAL(10,2) NOT NULL,
    unit_cost          DECIMAL(10,2) NOT NULL,
    line_status        VARCHAR(12) NOT NULL,   -- Open / Shipped / Delivered
    FOREIGN KEY (order_date_key)    REFERENCES dim_date(date_key),
    FOREIGN KEY (promised_date_key) REFERENCES dim_date(date_key),
    FOREIGN KEY (ship_date_key)     REFERENCES dim_date(date_key),
    FOREIGN KEY (delivery_date_key) REFERENCES dim_date(date_key),
    FOREIGN KEY (product_key)       REFERENCES dim_product(product_key),
    FOREIGN KEY (customer_key)      REFERENCES dim_customer(customer_key),
    FOREIGN KEY (warehouse_key)     REFERENCES dim_warehouse(warehouse_key),
    INDEX idx_order_id (order_id)
);

CREATE TABLE fact_inventory_snapshot (
    snapshot_date_key  INT NOT NULL,
    product_key        INT NOT NULL,
    warehouse_key      INT NOT NULL,
    on_hand_qty        INT NOT NULL,
    unit_cost          DECIMAL(10,2) NOT NULL,
    PRIMARY KEY (snapshot_date_key, product_key, warehouse_key),
    FOREIGN KEY (snapshot_date_key) REFERENCES dim_date(date_key),
    FOREIGN KEY (product_key)       REFERENCES dim_product(product_key),
    FOREIGN KEY (warehouse_key)     REFERENCES dim_warehouse(warehouse_key)
);

-- ---------------------------------------------------------------------
-- Populate dim_date with a recursive CTE (no CSV needed)
-- Covers 2024-12-01 to 2026-12-31 so every order/ship/delivery date has a key
-- ---------------------------------------------------------------------
SET SESSION cte_max_recursion_depth = 2000;

INSERT INTO dim_date
WITH RECURSIVE calendar AS (
    SELECT DATE('2024-12-01') AS d
    UNION ALL
    SELECT d + INTERVAL 1 DAY FROM calendar WHERE d < '2026-12-31'
)
SELECT
    CAST(DATE_FORMAT(d, '%Y%m%d') AS UNSIGNED)  AS date_key,
    d                                           AS full_date,
    YEAR(d)                                     AS year,
    QUARTER(d)                                  AS quarter,
    MONTH(d)                                    AS month,
    MONTHNAME(d)                                AS month_name,
    DATE_FORMAT(d, '%Y-%m')                     AS month_label,
    d - INTERVAL WEEKDAY(d) DAY                 AS week_start_date,
    WEEK(d, 3)                                  AS iso_week,
    WEEKDAY(d) + 1                              AS day_of_week,
    DAYNAME(d)                                  AS day_name,
    WEEKDAY(d) >= 5                             AS is_weekend
FROM calendar;

SELECT 'dim_date rows' AS check_name, COUNT(*) AS value FROM dim_date;
SHOW TABLES;
