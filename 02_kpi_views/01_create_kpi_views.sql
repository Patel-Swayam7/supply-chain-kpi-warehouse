-- =====================================================================
-- Step 3: Reusable KPI views
-- Run after Step 2. Analysts, the Excel report, and dashboards all read
-- from these views, so every KPI is defined in exactly one place.
--
--   vw_order_line_status        base view: one row per line with real dates + KPI flags
--   vw_otif_weekly              On Time In Full, by promised week and warehouse
--   vw_fill_rate_weekly         unit and line fill rate, by promised week and warehouse
--   vw_backlog_weekly           unshipped open orders at each week end, by warehouse
--   vw_inventory_turns_monthly  inventory turns and days of supply, by month and warehouse
--
-- Views store COUNTS and SUMS (additive) next to the ratios, so results can
-- be rolled up correctly: total OTIF = SUM(lines_otif) / SUM(lines_due),
-- never an average of weekly percentages.
-- =====================================================================

USE supply_chain;

-- ---------------------------------------------------------------------
-- Base view: every order line with readable dates and KPI flags
-- "as_of_date" = the last day of data. Lines promised after it are not due yet.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_order_line_status AS
WITH as_of AS (
    SELECT MAX(d.full_date) AS as_of_date
    FROM fact_order_lines f
    JOIN dim_date d ON d.date_key = f.order_date_key
)
SELECT
    f.order_line_id,
    f.order_id,
    f.warehouse_key,
    f.product_key,
    f.customer_key,
    od.full_date               AS order_date,
    pd.full_date               AS promised_date,
    pd.week_start_date         AS promised_week,
    sd.full_date               AS ship_date,
    dd.full_date               AS delivery_date,
    f.ordered_qty,
    f.shipped_qty,
    f.unit_price,
    f.unit_cost,
    f.line_status,
    a.as_of_date,
    -- A line counts toward OTIF / fill rate once its promised date has passed
    (pd.full_date <= a.as_of_date)                                   AS is_due,
    (dd.full_date IS NOT NULL AND dd.full_date <= pd.full_date)      AS is_on_time,
    (f.shipped_qty >= f.ordered_qty)                                 AS is_in_full,
    (dd.full_date IS NOT NULL AND dd.full_date <= pd.full_date
        AND f.shipped_qty >= f.ordered_qty)                          AS is_otif
FROM fact_order_lines f
CROSS JOIN as_of a
JOIN dim_date od      ON od.date_key = f.order_date_key
JOIN dim_date pd      ON pd.date_key = f.promised_date_key
LEFT JOIN dim_date sd ON sd.date_key = f.ship_date_key
LEFT JOIN dim_date dd ON dd.date_key = f.delivery_date_key;

-- ---------------------------------------------------------------------
-- OTIF: share of due order lines delivered by the promised date AND complete
-- Grain: promised week + warehouse (complete weeks only)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_otif_weekly AS
SELECT
    s.promised_week                       AS week_start,
    w.warehouse_name,
    COUNT(*)                              AS lines_due,
    SUM(s.is_on_time)                     AS lines_on_time,
    SUM(s.is_in_full)                     AS lines_in_full,
    SUM(s.is_otif)                        AS lines_otif,
    ROUND(SUM(s.is_otif) / COUNT(*), 4)   AS otif_rate
FROM vw_order_line_status s
JOIN dim_warehouse w ON w.warehouse_key = s.warehouse_key
WHERE s.is_due
  AND s.promised_week <= s.as_of_date - INTERVAL 6 DAY   -- complete weeks only
GROUP BY s.promised_week, w.warehouse_name;

-- ---------------------------------------------------------------------
-- Fill rate: how much of what customers ordered actually shipped
--   unit fill rate = shipped units / ordered units
--   line fill rate = lines shipped complete / lines ordered
-- Grain: promised week + warehouse
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_fill_rate_weekly AS
SELECT
    s.promised_week                                     AS week_start,
    w.warehouse_name,
    SUM(s.ordered_qty)                                  AS units_ordered,
    SUM(s.shipped_qty)                                  AS units_shipped,
    COUNT(*)                                            AS lines_ordered,
    SUM(s.is_in_full)                                   AS lines_filled_complete,
    ROUND(SUM(s.shipped_qty) / SUM(s.ordered_qty), 4)   AS unit_fill_rate,
    ROUND(SUM(s.is_in_full) / COUNT(*), 4)              AS line_fill_rate
FROM vw_order_line_status s
JOIN dim_warehouse w ON w.warehouse_key = s.warehouse_key
WHERE s.is_due
  AND s.promised_week <= s.as_of_date - INTERVAL 6 DAY   -- complete weeks only
GROUP BY s.promised_week, w.warehouse_name;

-- ---------------------------------------------------------------------
-- Backlog: orders received but not yet shipped, measured at each week end
-- (Sunday). Past due = already beyond its promised date at that week end.
-- Grain: week end + warehouse
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_backlog_weekly AS
WITH week_ends AS (
    SELECT full_date AS week_end
    FROM dim_date
    WHERE day_of_week = 7
      AND full_date BETWEEN '2025-01-05'
                        AND (SELECT MAX(as_of_date) FROM vw_order_line_status)
)
SELECT
    we.week_end,
    w.warehouse_name,
    COUNT(*)                                                    AS open_lines,
    SUM(s.ordered_qty)                                          AS open_units,
    ROUND(SUM(s.ordered_qty * s.unit_price), 2)                 AS open_value,
    SUM(s.promised_date < we.week_end)                          AS past_due_lines,
    ROUND(SUM(CASE WHEN s.promised_date < we.week_end
                   THEN s.ordered_qty * s.unit_price ELSE 0 END), 2) AS past_due_value
FROM week_ends we
JOIN vw_order_line_status s
    ON  s.order_date <= we.week_end
    AND (s.ship_date IS NULL OR s.ship_date > we.week_end)
JOIN dim_warehouse w ON w.warehouse_key = s.warehouse_key
GROUP BY we.week_end, w.warehouse_name;

-- ---------------------------------------------------------------------
-- Inventory turns: how many times inventory "turns over" per year
--   COGS              = shipped units x unit cost, by ship month
--   avg inventory     = average of the weekly inventory value snapshots in the month
--   annualized turns  = (monthly COGS x 12) / avg inventory value
--   days of supply    = avg inventory value / average daily COGS
-- Grain: month + warehouse
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_inventory_turns_monthly AS
WITH cogs AS (
    SELECT
        d.month_label,
        f.warehouse_key,
        SUM(f.shipped_qty * f.unit_cost) AS cogs
    FROM fact_order_lines f
    JOIN dim_date d ON d.date_key = f.ship_date_key
    GROUP BY d.month_label, f.warehouse_key
),
inventory_by_snapshot AS (
    SELECT
        d.month_label,
        i.warehouse_key,
        i.snapshot_date_key,
        SUM(i.on_hand_qty * i.unit_cost) AS inventory_value
    FROM fact_inventory_snapshot i
    JOIN dim_date d ON d.date_key = i.snapshot_date_key
    GROUP BY d.month_label, i.warehouse_key, i.snapshot_date_key
),
avg_inventory AS (
    SELECT month_label, warehouse_key, AVG(inventory_value) AS avg_inventory_value
    FROM inventory_by_snapshot
    GROUP BY month_label, warehouse_key
),
days_in_month AS (
    SELECT month_label, COUNT(*) AS days FROM dim_date GROUP BY month_label
)
SELECT
    a.month_label                                           AS month,
    w.warehouse_name,
    ROUND(c.cogs, 2)                                        AS cogs,
    ROUND(a.avg_inventory_value, 2)                         AS avg_inventory_value,
    ROUND(c.cogs * 12 / a.avg_inventory_value, 2)           AS annualized_turns,
    ROUND(a.avg_inventory_value / (c.cogs / dm.days), 1)    AS days_of_supply
FROM avg_inventory a
JOIN cogs c          ON c.month_label = a.month_label AND c.warehouse_key = a.warehouse_key
JOIN days_in_month dm ON dm.month_label = a.month_label
JOIN dim_warehouse w ON w.warehouse_key = a.warehouse_key;

-- ---------------------------------------------------------------------
-- Quick look at each view
-- ---------------------------------------------------------------------
SELECT 'vw_otif_weekly' AS view_name, COUNT(*) AS row_count FROM vw_otif_weekly
UNION ALL SELECT 'vw_fill_rate_weekly', COUNT(*) FROM vw_fill_rate_weekly
UNION ALL SELECT 'vw_backlog_weekly', COUNT(*) FROM vw_backlog_weekly
UNION ALL SELECT 'vw_inventory_turns_monthly', COUNT(*) FROM vw_inventory_turns_monthly;

-- Network-wide headline KPIs (rolled up from additive counts)
SELECT
    ROUND(SUM(lines_otif) / SUM(lines_due) * 100, 1)        AS otif_pct,
    ROUND(SUM(lines_on_time) / SUM(lines_due) * 100, 1)     AS on_time_pct,
    ROUND(SUM(lines_in_full) / SUM(lines_due) * 100, 1)     AS in_full_pct
FROM vw_otif_weekly;

SELECT
    ROUND(SUM(units_shipped) / SUM(units_ordered) * 100, 1)        AS unit_fill_rate_pct,
    ROUND(SUM(lines_filled_complete) / SUM(lines_ordered) * 100, 1) AS line_fill_rate_pct
FROM vw_fill_rate_weekly;
