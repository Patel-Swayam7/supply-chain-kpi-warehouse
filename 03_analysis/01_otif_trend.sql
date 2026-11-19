/*
Question: Is delivery performance (OTIF) improving or slipping week to week?
- Network-wide OTIF per promised week
- 4-week rolling OTIF (smooths out noisy weeks)
- Week-over-week change using LAG()
Weekly OTIF is noisy; the rolling rate shows the underlying trend.

Note: the rolling rate is computed from rolling SUMS of lines, not by
averaging weekly percentages, so busier weeks carry more weight.
*/

USE supply_chain;

WITH weekly AS (
    SELECT
        week_start,
        SUM(lines_due)  AS lines_due,
        SUM(lines_otif) AS lines_otif
    FROM vw_otif_weekly
    GROUP BY week_start
),
rolling AS (
    SELECT
        week_start,
        lines_due,
        lines_otif,
        lines_otif / lines_due AS otif_rate,
        SUM(lines_otif) OVER w4 / SUM(lines_due) OVER w4 AS otif_rolling_4wk
    FROM weekly
    WINDOW w4 AS (ORDER BY week_start ROWS BETWEEN 3 PRECEDING AND CURRENT ROW)
)
SELECT
    week_start,
    lines_due,
    ROUND(otif_rate * 100, 1)                                            AS otif_pct,
    ROUND(otif_rolling_4wk * 100, 1)                                     AS otif_rolling_4wk_pct,
    ROUND((otif_rate - LAG(otif_rate) OVER (ORDER BY week_start)) * 100, 1) AS wow_change_pts
FROM rolling
ORDER BY week_start DESC
LIMIT 13;
