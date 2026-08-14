-- data_quality.sql
--
-- Assertions about the warehouse that should hold after every load. Each test
-- raises an exception on failure, so `make test` exits non-zero and can gate a
-- CI pipeline. A warehouse without these silently serves wrong numbers -- which
-- is worse than being down, because nobody notices.
--
-- Run with: make test

\set ON_ERROR_STOP on

DO $$
DECLARE
    v_count   bigint;
    v_failed  integer := 0;

    PROCEDURE_NOTE text;
BEGIN
    RAISE NOTICE '--- data quality checks ---';

    -- 1. Referential integrity: every fact row points at a real dimension row.
    --    The dimension FKs enforce this, so a failure here means a constraint
    --    was dropped for a bulk load and never restored.
    SELECT count(*) INTO v_count
    FROM fact_shipment f
    LEFT JOIN dim_carrier c ON c.carrier_key = f.carrier_key
    WHERE c.carrier_key IS NULL;
    IF v_count > 0 THEN
        RAISE WARNING 'FAIL orphaned carrier_key: %', v_count; v_failed := v_failed + 1;
    ELSE RAISE NOTICE 'PASS no orphaned carrier keys';
    END IF;

    -- 2. fact_scan_event has no FK to fact_shipment by design (see 002_facts.sql),
    --    so this relationship is checked rather than constrained. This is the
    --    test that earns that design decision.
    SELECT count(*) INTO v_count
    FROM (
        SELECT se.shipment_id
        FROM fact_scan_event se
        LEFT JOIN fact_shipment f ON f.shipment_id = se.shipment_id
        WHERE f.shipment_id IS NULL
        LIMIT 1
    ) AS orphans;
    IF v_count > 0 THEN
        RAISE WARNING 'FAIL scan events referencing missing shipments'; v_failed := v_failed + 1;
    ELSE RAISE NOTICE 'PASS all scan events resolve to a shipment';
    END IF;

    -- 3. Temporal sanity: nothing is delivered before it was shipped. Enforced
    --    by a CHECK constraint; asserted here so that dropping the constraint
    --    fails the suite rather than passing silently.
    SELECT count(*) INTO v_count
    FROM fact_shipment WHERE delivered_at < shipped_at;
    IF v_count > 0 THEN
        RAISE WARNING 'FAIL delivered before shipped: %', v_count; v_failed := v_failed + 1;
    ELSE RAISE NOTICE 'PASS no negative transit times';
    END IF;

    -- 4. Status consistency: a delivered parcel must have a delivery timestamp,
    --    and an in-transit one must not. This is the kind of rule that cannot be
    --    a CHECK constraint cheaply across statuses and is exactly where a load
    --    bug shows up first.
    SELECT count(*) INTO v_count
    FROM fact_shipment
    WHERE (status = 'delivered'  AND delivered_at IS NULL)
       OR (status = 'in_transit' AND delivered_at IS NOT NULL);
    IF v_count > 0 THEN
        RAISE WARNING 'FAIL status/delivered_at mismatch: %', v_count; v_failed := v_failed + 1;
    ELSE RAISE NOTICE 'PASS status agrees with delivered_at';
    END IF;

    -- 5. Grain uniqueness: one row per parcel. A duplicated fact row is the
    --    classic double-load bug and inflates every sum in the warehouse.
    SELECT count(*) INTO v_count FROM (
        SELECT tracking_number FROM fact_shipment
        GROUP BY tracking_number HAVING count(*) > 1 LIMIT 1
    ) dupes;
    IF v_count > 0 THEN
        RAISE WARNING 'FAIL duplicate tracking numbers'; v_failed := v_failed + 1;
    ELSE RAISE NOTICE 'PASS tracking numbers unique';
    END IF;

    -- 6. Scan sequences start at 1 and have no gaps within a parcel. A gap means
    --    a scan was lost in the load, which silently shortens measured dwell time.
    --
    --    Sampled by shipment_id, NOT by a scanned_at window. The first version of
    --    this check filtered on a month of scan timestamps and failed -- because a
    --    parcel accepted on 30 June is still scanning in July, so a date window
    --    slices its sequence in half and the surviving rows legitimately start at
    --    4. The data was correct; the test was wrong. Any assertion about a whole
    --    entity has to select whole entities.
    SELECT count(*) INTO v_count FROM (
        SELECT shipment_id
        FROM fact_scan_event
        WHERE shipment_id % 997 = 0          -- ~2k parcels, whole journeys
        GROUP BY shipment_id
        HAVING min(scan_sequence) <> 1
            OR max(scan_sequence) <> count(*)
        LIMIT 1
    ) gaps;
    IF v_count > 0 THEN
        RAISE WARNING 'FAIL gapped or non-1-based scan sequences'; v_failed := v_failed + 1;
    ELSE RAISE NOTICE 'PASS scan sequences contiguous from 1';
    END IF;

    -- 7. Every fact row landed in the partition its timestamp implies. Proves
    --    partition routing is doing what the schema claims.
    SELECT count(*) INTO v_count
    FROM fact_shipment
    WHERE date_key <> (to_char(shipped_at, 'YYYYMMDD'))::integer;
    IF v_count > 0 THEN
        RAISE WARNING 'FAIL date_key disagrees with shipped_at: %', v_count; v_failed := v_failed + 1;
    ELSE RAISE NOTICE 'PASS date_key consistent with shipped_at';
    END IF;

    -- 8. The materialized view agrees with its source. If a refresh was missed,
    --    every dashboard is quietly wrong; this is the check that catches it.
    SELECT abs(mv.total - src.total) INTO v_count
    FROM (SELECT count(*) AS total FROM mv_daily_facility_throughput) mv,
         (SELECT count(*) AS total FROM (
              SELECT 1 FROM fact_shipment f
              JOIN dim_date d ON d.date_key = f.date_key
              GROUP BY f.origin_facility_key, d.full_date
          ) g) src;
    IF v_count > 0 THEN
        RAISE WARNING 'FAIL matview stale: % row difference', v_count; v_failed := v_failed + 1;
    ELSE RAISE NOTICE 'PASS matview grain matches source';
    END IF;

    RAISE NOTICE '--- % check(s) failed ---', v_failed;
    IF v_failed > 0 THEN
        RAISE EXCEPTION 'data quality suite failed: % check(s)', v_failed;
    END IF;
END $$;
