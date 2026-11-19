/*
Question: How old is the current backlog, and how much of it is past due?
- Open (unshipped) order lines as of the last day of data
- Bucketed by days since order with CASE
- Value and share of total per bucket
*/

USE supply_chain;

WITH open_lines AS (
    SELECT
        s.*,
        DATEDIFF(s.as_of_date, s.order_date) AS age_days
    FROM vw_order_line_status s
    WHERE s.ship_date IS NULL
),
bucketed AS (
    SELECT
        w.warehouse_name,
        CASE
            WHEN age_days <= 7  THEN '1) 0-7 days'
            WHEN age_days <= 14 THEN '2) 8-14 days'
            WHEN age_days <= 30 THEN '3) 15-30 days'
            ELSE                     '4) 30+ days'
        END                                    AS age_bucket,
        ordered_qty * unit_price               AS open_value,
        (promised_date < as_of_date)           AS is_past_due
    FROM open_lines o
    JOIN dim_warehouse w ON w.warehouse_key = o.warehouse_key
)
SELECT
    age_bucket,
    COUNT(*)                                                       AS open_lines,
    ROUND(SUM(open_value), 0)                                      AS open_value,
    ROUND(SUM(open_value) / SUM(SUM(open_value)) OVER () * 100, 1) AS share_of_value_pct,
    SUM(is_past_due)                                               AS past_due_lines
FROM bucketed
GROUP BY age_bucket
ORDER BY age_bucket;
