-- 002_seed_scans.sql
-- Scan events: one row per tracking scan, 3-8 per parcel with a long tail.
--
-- Run after 001_seed.sql. Generated from fact_shipment rather than
-- independently, so scan timestamps sit inside the parcel's actual transit
-- window and the two facts agree with each other. Independently generated
-- "related" data is the fastest way to build a warehouse whose joins produce
-- nonsense.

\timing on

INSERT INTO fact_scan_event (shipment_id, scanned_at, facility_key, scan_type, scan_sequence)
SELECT
    f.shipment_id,
    -- Scans are spread across the transit window. For undelivered parcels
    -- there is no delivered_at, so a nominal 48h window is used.
    f.shipped_at
      + ((s.seq - 1)::numeric / GREATEST(f.scan_count - 1, 1))
        * COALESCE(f.delivered_at - f.shipped_at, INTERVAL '48 hours'),
    CASE
        WHEN s.seq = 1                THEN f.origin_facility_key
        WHEN s.seq = f.scan_count     THEN f.dest_facility_key
        ELSE 1 + ((f.shipment_id * s.seq) % 60)::integer
    END,
    CASE
        WHEN s.seq = 1                            THEN 'accepted'
        WHEN s.seq = f.scan_count
             AND f.status = 'delivered'           THEN 'delivered'
        WHEN s.seq = f.scan_count                 THEN 'exception'
        WHEN s.seq = f.scan_count - 1             THEN 'out_for_delivery'
        WHEN s.seq % 2 = 0                        THEN 'departed'
        ELSE 'arrived'
    END,
    s.seq::smallint
FROM (
    SELECT
        shipment_id, shipped_at, delivered_at, status,
        origin_facility_key, dest_facility_key,
        -- Most parcels scan 4-6 times; a small tail bounces far more.
        CASE
            WHEN random() < 0.02 THEN 9 + (random() * 12)::integer
            ELSE 3 + (random() * 4)::integer
        END AS scan_count
    FROM fact_shipment
) AS f
CROSS JOIN LATERAL generate_series(1, f.scan_count) AS s(seq);

ANALYZE fact_scan_event;
