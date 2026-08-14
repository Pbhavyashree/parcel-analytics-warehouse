-- queries.sql
-- The three queries measured in docs/BENCHMARKS.md, with EXPLAIN ANALYZE.
--
-- Each is run twice by `make benchmark`; the second timing is the one to read,
-- because the first pays for a cold page cache and measures the disk rather
-- than the plan.

\timing on

-- B1. Carrier SLA breaches for one quarter.
--     Bounded by shipped_at so partition pruning applies.
EXPLAIN (ANALYZE, BUFFERS)
SELECT c.carrier_code, count(*)
FROM fact_shipment f
JOIN dim_carrier c        USING (carrier_key)
JOIN dim_service_level s  USING (service_key)
WHERE f.shipped_at >= '2025-07-01'
  AND f.shipped_at <  '2025-10-01'
  AND f.delivered_at IS NOT NULL
  AND f.delivered_at - f.shipped_at > (s.sla_hours || ' hours')::interval
GROUP BY 1
ORDER BY 2 DESC;

-- B2. One customer's entire shipping history.
--     No date predicate, so every partition is in play; the win has to come
--     from idx_shipment_customer_date.
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*), sum(shipping_cost)
FROM fact_shipment
WHERE customer_key = 17;

-- B3. The scan history of a single parcel.
--     The most common operational lookup in the system.
EXPLAIN (ANALYZE, BUFFERS)
SELECT scan_type, scanned_at
FROM fact_scan_event
WHERE shipment_id = 1234567
ORDER BY scan_sequence;

-- B4. Regional revenue: materialized view vs. aggregating the fact table.
EXPLAIN (ANALYZE)
SELECT region, sum(revenue)
FROM mv_daily_facility_throughput
WHERE year = 2025
GROUP BY 1;

EXPLAIN (ANALYZE)
SELECT fac.region, sum(f.shipping_cost)
FROM fact_shipment f
JOIN dim_facility fac ON fac.facility_key = f.origin_facility_key
JOIN dim_date d       ON d.date_key = f.date_key
WHERE d.year = 2025
GROUP BY 1;
