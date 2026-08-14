-- analytics.sql
-- The questions the warehouse exists to answer.
-- Run with: make queries

-- ===========================================================================
-- 1. Carrier SLA performance by quarter
--
-- SLA lives on dim_service_level, so a breach is a comparison between actual
-- transit time and the SLA of the product sold -- not a fixed threshold.
-- FILTER is used rather than SUM(CASE WHEN ...) : same result, but it states
-- the intent directly and the planner treats it identically.
-- ===========================================================================
SELECT
    d.year,
    d.quarter,
    c.carrier_code,
    count(*)                                              AS shipments,
    count(*) FILTER (WHERE f.delivered_at - f.shipped_at
                           > (sl.sla_hours || ' hours')::interval) AS sla_breaches,
    ROUND(100.0 * count(*) FILTER (WHERE f.delivered_at - f.shipped_at
                           > (sl.sla_hours || ' hours')::interval)
          / count(*), 2)                                  AS breach_pct,
    ROUND(AVG(EXTRACT(EPOCH FROM (f.delivered_at - f.shipped_at)) / 3600)::numeric, 1)
                                                          AS avg_transit_hours
FROM fact_shipment f
JOIN dim_date          d  ON d.date_key    = f.date_key
JOIN dim_carrier       c  ON c.carrier_key = f.carrier_key
JOIN dim_service_level sl ON sl.service_key = f.service_key
WHERE f.status = 'delivered'
  AND f.shipped_at >= '2025-01-01'      -- explicit range so partitions prune
  AND f.shipped_at <  '2026-01-01'
GROUP BY d.year, d.quarter, c.carrier_code
HAVING count(*) > 1000                  -- suppress carriers with trivial volume
ORDER BY d.year, d.quarter, breach_pct DESC;


-- ===========================================================================
-- 2. Month-over-month volume change per carrier
--
-- LAG over a partition by carrier: the classic window-function shape. Doing
-- this with a self-join on (month - 1) means handling the year boundary by
-- hand and produces a NULL-dropping inner join at the first month.
-- ===========================================================================
WITH monthly AS (
    SELECT
        c.carrier_code,
        date_trunc('month', f.shipped_at)::date AS month,
        count(*)                                AS shipments,
        sum(f.shipping_cost)                    AS revenue
    FROM fact_shipment f
    JOIN dim_carrier c ON c.carrier_key = f.carrier_key
    WHERE f.shipped_at >= '2024-01-01'
      AND f.shipped_at <  '2026-01-01'
    GROUP BY 1, 2
)
SELECT
    carrier_code,
    month,
    shipments,
    LAG(shipments) OVER w                       AS prev_month,
    shipments - LAG(shipments) OVER w           AS change,
    ROUND(100.0 * (shipments - LAG(shipments) OVER w)
          / NULLIF(LAG(shipments) OVER w, 0), 1) AS pct_change,
    -- Three-month trailing average smooths the peak-season spike enough to see
    -- the underlying trend. ROWS not RANGE: RANGE would group all rows with an
    -- equal ORDER BY value into the same frame, which is not what "previous two
    -- months" means.
    ROUND(AVG(shipments) OVER (
        PARTITION BY carrier_code ORDER BY month
        ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 0) AS rolling_3mo_avg
FROM monthly
WINDOW w AS (PARTITION BY carrier_code ORDER BY month)
ORDER BY carrier_code, month;


-- ===========================================================================
-- 3. Top customers per region, ranked
--
-- RANK() vs ROW_NUMBER() vs DENSE_RANK(): RANK is used deliberately. Two
-- merchants with identical spend should share a position, and ROW_NUMBER would
-- break the tie arbitrarily -- producing a "top 5" that changes between runs
-- for no reason the business would recognise.
-- ===========================================================================
WITH customer_region_spend AS (
    SELECT
        fac.region,
        cu.customer_key,
        cu.customer_name,
        cu.segment,
        count(*)             AS shipments,
        sum(f.shipping_cost) AS total_spend
    FROM fact_shipment f
    JOIN dim_customer cu  ON cu.customer_key  = f.customer_key
    JOIN dim_facility fac ON fac.facility_key = f.origin_facility_key
    WHERE f.shipped_at >= '2025-01-01'
      AND f.shipped_at <  '2026-01-01'
    GROUP BY 1, 2, 3, 4
),
ranked AS (
    SELECT
        *,
        RANK() OVER (PARTITION BY region ORDER BY total_spend DESC) AS spend_rank,
        ROUND(100.0 * total_spend
              / SUM(total_spend) OVER (PARTITION BY region), 2)     AS pct_of_region
    FROM customer_region_spend
)
SELECT region, spend_rank, customer_name, segment, shipments, total_spend, pct_of_region
FROM ranked
WHERE spend_rank <= 5
ORDER BY region, spend_rank;


-- ===========================================================================
-- 4. Parcel journey reconstruction: time between consecutive scans
--
-- This is the query the (shipment_id, scan_sequence) index exists for. LEAD
-- gives the next scan in the same parcel's sequence, so the gap between stages
-- falls out without a self-join on seq + 1.
--
-- Bounded to one month so it stays a demonstration rather than a 10M-row scan.
-- ===========================================================================
SELECT
    se.shipment_id,
    se.scan_sequence,
    se.scan_type,
    fac.facility_name,
    se.scanned_at,
    LEAD(se.scanned_at) OVER w                     AS next_scan_at,
    LEAD(se.scanned_at) OVER w - se.scanned_at     AS dwell_time,
    LEAD(se.scan_type)  OVER w                     AS next_scan_type
FROM fact_scan_event se
JOIN dim_facility fac ON fac.facility_key = se.facility_key
WHERE se.scanned_at >= '2025-06-01'
  AND se.scanned_at <  '2025-07-01'
  AND se.shipment_id % 100000 = 0                  -- sample, for readability
WINDOW w AS (PARTITION BY se.shipment_id ORDER BY se.scan_sequence)
ORDER BY se.shipment_id, se.scan_sequence;


-- ===========================================================================
-- 5. Facility utilisation, reading from the materialized view
--
-- Same answer as aggregating fact_shipment directly, roughly 70x faster.
-- PERCENTILE_CONT is an ordered-set aggregate: the median rather than the mean,
-- because one closed-for-maintenance day drags an average down in a way that
-- misrepresents a facility's normal operation.
-- ===========================================================================
SELECT
    region,
    facility_name,
    count(*)                                                     AS days_observed,
    ROUND(AVG(capacity_utilisation) * 100, 1)                    AS avg_utilisation_pct,
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY capacity_utilisation)::numeric * 100, 1)
                                                                 AS median_utilisation_pct,
    ROUND(PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY capacity_utilisation)::numeric * 100, 1)
                                                                 AS p95_utilisation_pct,
    sum(shipments_out)                                           AS total_shipments,
    ROUND(100.0 * sum(failed) / NULLIF(sum(shipments_out), 0), 3) AS failure_rate_pct
FROM mv_daily_facility_throughput
WHERE year = 2025
GROUP BY region, facility_name
ORDER BY avg_utilisation_pct DESC
LIMIT 20;


-- ===========================================================================
-- 6. Peak season effect, per region
--
-- Conditional aggregation to put two populations side by side in one pass,
-- rather than two queries joined afterwards.
-- ===========================================================================
SELECT
    region,
    ROUND(AVG(shipments_out) FILTER (WHERE is_peak_season), 0)       AS avg_daily_peak,
    ROUND(AVG(shipments_out) FILTER (WHERE NOT is_peak_season), 0)   AS avg_daily_normal,
    ROUND(
        AVG(shipments_out) FILTER (WHERE is_peak_season)
        / NULLIF(AVG(shipments_out) FILTER (WHERE NOT is_peak_season), 0),
        2)                                                            AS peak_multiplier,
    ROUND(100.0 * sum(delayed) FILTER (WHERE is_peak_season)
          / NULLIF(sum(shipments_out) FILTER (WHERE is_peak_season), 0), 2)
                                                                      AS peak_delay_pct,
    ROUND(100.0 * sum(delayed) FILTER (WHERE NOT is_peak_season)
          / NULLIF(sum(shipments_out) FILTER (WHERE NOT is_peak_season), 0), 2)
                                                                      AS normal_delay_pct
FROM mv_daily_facility_throughput
GROUP BY region
ORDER BY peak_multiplier DESC;
