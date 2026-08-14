-- 003_partitions.sql
-- Create monthly partitions.
--
-- Written as a loop rather than 72 hand-written CREATE TABLE statements: the
-- boundaries are mechanical, and hand-maintaining them is how a missing month
-- becomes a failed insert at 3am on the 1st.
--
-- In production this would run from a scheduled job creating partitions a few
-- months ahead. A DEFAULT partition is deliberately NOT used: it silently
-- accepts rows that should have gone somewhere else, and once it holds data,
-- attaching a new partition covering that range requires scanning it.

BEGIN;

CREATE OR REPLACE FUNCTION create_monthly_partitions(
    parent_table text,
    start_month  date,
    month_count  integer
) RETURNS void AS $$
DECLARE
    i           integer;
    part_start  date;
    part_end    date;
    part_name   text;
BEGIN
    FOR i IN 0..month_count - 1 LOOP
        part_start := (date_trunc('month', start_month) + (i || ' months')::interval)::date;
        part_end   := (part_start + interval '1 month')::date;
        part_name  := format('%s_%s', parent_table, to_char(part_start, 'YYYY_MM'));

        EXECUTE format(
            'CREATE TABLE IF NOT EXISTS %I PARTITION OF %I FOR VALUES FROM (%L) TO (%L)',
            part_name, parent_table, part_start, part_end
        );
    END LOOP;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION create_monthly_partitions IS
    'Creates month_count monthly partitions of parent_table starting at start_month.';

-- Three years of history: 2023-01 through 2025-12.
SELECT create_monthly_partitions('fact_shipment', DATE '2023-01-01', 36);

-- fact_scan_event gets three extra months.
--
-- Scans trail their shipment. A parcel accepted on 31 December is still being
-- scanned in January, and an exception case can bounce for weeks -- so the scan
-- table's key range extends past the shipment table's. Sizing both to the same
-- 36 months fails on the last day of the range with "no partition of relation
-- found for row", which is the partitioned-table equivalent of an off-by-one:
-- everything works until the boundary.
--
-- This is the same reason production partition creation runs ahead of time
-- rather than just-in-time. A partition that does not exist is not created
-- automatically; the insert simply fails.
SELECT create_monthly_partitions('fact_scan_event', DATE '2023-01-01', 39);

COMMIT;
