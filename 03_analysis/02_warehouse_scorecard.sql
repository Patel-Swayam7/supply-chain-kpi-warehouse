/*
Question: Which distribution center performs best and worst, and is each
one getting better or worse?
- Last 13 weeks vs the 13 weeks before, per warehouse
- OTIF and unit fill rate, ranked with RANK()
- Inventory turns for the last 3 months
*/

USE supply_chain;

WITH bounds AS (
    SELECT MAX(week_start) AS last_week FROM vw_otif_weekly
),
periods AS (
    SELECT
        o.warehouse_name,
        CASE
            WHEN o.week_start >  b.last_week - INTERVAL 13 WEEK THEN 'current'
            WHEN o.week_start >  b.last_week - INTERVAL 26 WEEK THEN 'prior'
        END AS period,
        o.lines_due,
        o.lines_otif,
        f.units_ordered,
        f.units_shipped
    FROM vw_otif_weekly o
    JOIN vw_fill_rate_weekly f
        ON f.week_start = o.week_start AND f.warehouse_name = o.warehouse_name
    CROSS JOIN bounds b
    WHERE o.week_start > b.last_week - INTERVAL 26 WEEK
),
summary AS (
    SELECT
        warehouse_name,
        SUM(CASE WHEN period = 'current' THEN lines_otif END)
          / SUM(CASE WHEN period = 'current' THEN lines_due END)     AS otif_current,
        SUM(CASE WHEN period = 'prior' THEN lines_otif END)
          / SUM(CASE WHEN period = 'prior' THEN lines_due END)       AS otif_prior,
        SUM(CASE WHEN period = 'current' THEN units_shipped END)
          / SUM(CASE WHEN period = 'current' THEN units_ordered END) AS fill_rate_current
    FROM periods
    GROUP BY warehouse_name
),
turns AS (
    SELECT warehouse_name, AVG(annualized_turns) AS turns_last_3m
    FROM vw_inventory_turns_monthly
    WHERE month > DATE_FORMAT((SELECT MAX(week_start) FROM vw_otif_weekly) - INTERVAL 3 MONTH, '%Y-%m')
    GROUP BY warehouse_name
)
SELECT
    RANK() OVER (ORDER BY s.otif_current DESC)            AS otif_rank,
    s.warehouse_name,
    ROUND(s.otif_current * 100, 1)                        AS otif_last_13wk_pct,
    ROUND(s.otif_prior * 100, 1)                          AS otif_prior_13wk_pct,
    ROUND((s.otif_current - s.otif_prior) * 100, 1)       AS change_pts,
    ROUND(s.fill_rate_current * 100, 1)                   AS unit_fill_rate_pct,
    RANK() OVER (ORDER BY s.fill_rate_current DESC)       AS fill_rate_rank,
    ROUND(t.turns_last_3m, 1)                             AS inventory_turns
FROM summary s
JOIN turns t ON t.warehouse_name = s.warehouse_name
ORDER BY otif_rank;
