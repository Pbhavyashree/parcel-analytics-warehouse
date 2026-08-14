-- 005_matviews.sql
--
-- Why a materialized view and not a plain view:
--   A plain view is a stored query -- every read re-aggregates 2M rows. This
--   feeds a dashboard that several people load repeatedly during the day, on
--   data that only changes when the nightly load runs. Recomputing per page
--   view is work done many times to produce an identical answer.
--
-- Why not a summary table maintained by triggers:
--   A trigger firing per inserted row turns a bulk load of 2M rows into 2M
--   extra updates against a contended set of aggregate rows. Bulk-load-then-
--   refresh is the cheaper shape when latency of minutes is acceptable, which
--   for daily throughput reporting it is.
--
-- The cost: the data is stale between refreshes. That is a correct trade for a
-- daily operational metric and would be the wrong one for anything a customer
-- sees as live.

BEGIN;

CREATE MATERIALIZED VIEW mv_daily_facility_throughput AS
SELECT
    d.full_date,
    d.year,
    d.month,
    d.is_peak_season,
    fac.facility_key,
    fac.facility_code,
    fac.facility_name,
    fac.region,
    fac.capacity_per_day,
    count(*)                                                       AS shipments_out,
    count(*) FILTER (WHERE f.status = 'delivered')                 AS delivered,
    count(*) FILTER (WHERE f.status = 'delayed')                   AS delayed,
    count(*) FILTER (WHERE f.status IN ('lost','returned'))        AS failed,
    sum(f.shipping_cost)                                           AS revenue,
    sum(f.weight_grams) / 1000.0                                   AS total_weight_kg,
    -- Utilisation against the facility's rated capacity. ROUND to 4dp rather
    -- than storing a raw float: this is displayed as a percentage and the extra
    -- precision is noise.
    ROUND((count(*)::numeric / fac.capacity_per_day), 4)           AS capacity_utilisation
FROM fact_shipment f
JOIN dim_date     d   ON d.date_key = f.date_key
JOIN dim_facility fac ON fac.facility_key = f.origin_facility_key
GROUP BY d.full_date, d.year, d.month, d.is_peak_season,
         fac.facility_key, fac.facility_code, fac.facility_name,
         fac.region, fac.capacity_per_day;

-- A UNIQUE index is required for REFRESH MATERIALIZED VIEW CONCURRENTLY.
-- Without it, a refresh takes an ACCESS EXCLUSIVE lock and every dashboard
-- query blocks until it finishes. With it, readers keep reading the old
-- snapshot while the new one is built. The unique key here is the view's
-- natural grain: one row per facility per day.
CREATE UNIQUE INDEX idx_mv_throughput_pk
    ON mv_daily_facility_throughput (facility_key, full_date);

CREATE INDEX idx_mv_throughput_date
    ON mv_daily_facility_throughput (full_date);

CREATE INDEX idx_mv_throughput_region
    ON mv_daily_facility_throughput (region, full_date);

COMMIT;

ANALYZE mv_daily_facility_throughput;
