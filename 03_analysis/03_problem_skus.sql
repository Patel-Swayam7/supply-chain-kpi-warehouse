/*
Question: Which products cause the most short shipments?
- Units ordered but not shipped (shortfall) per SKU, last 13 weeks
- Each SKU's share of the network's total shortfall (SUM() OVER ())
- Running cumulative share
- DENSE_RANK() of each SKU within its category
*/

USE supply_chain;

WITH recent AS (
    SELECT s.*
    FROM vw_order_line_status s
    WHERE s.is_due
      AND s.promised_week > (SELECT MAX(week_start) FROM vw_otif_weekly) - INTERVAL 13 WEEK
),
by_sku AS (
    SELECT
        p.sku,
        p.product_name,
        p.category,
        SUM(r.ordered_qty)                    AS units_ordered,
        SUM(r.ordered_qty - r.shipped_qty)    AS units_short,
        SUM(r.shipped_qty) / SUM(r.ordered_qty) AS fill_rate
    FROM recent r
    JOIN dim_product p ON p.product_key = r.product_key
    GROUP BY p.sku, p.product_name, p.category
),
ranked AS (
    SELECT
        *,
        units_short / SUM(units_short) OVER ()                      AS share_of_shortfall,
        SUM(units_short) OVER (ORDER BY units_short DESC, sku
                               ROWS UNBOUNDED PRECEDING)
          / SUM(units_short) OVER ()                                AS cumulative_share,
        DENSE_RANK() OVER (PARTITION BY category ORDER BY units_short DESC) AS rank_in_category
    FROM by_sku
)
SELECT
    sku,
    product_name,
    category,
    units_ordered,
    units_short,
    ROUND(fill_rate * 100, 1)           AS fill_rate_pct,
    ROUND(share_of_shortfall * 100, 1)  AS share_of_shortfall_pct,
    ROUND(cumulative_share * 100, 1)    AS cumulative_share_pct,
    rank_in_category
FROM ranked
ORDER BY units_short DESC
LIMIT 15;
