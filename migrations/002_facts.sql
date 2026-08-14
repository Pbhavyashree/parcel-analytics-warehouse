-- 002_facts.sql
-- Fact tables. Two grains, deliberately separated.

BEGIN;

-- ---------------------------------------------------------------------------
-- fact_shipment  — grain: one row per parcel
--
-- Range-partitioned monthly on shipped_at.
--
-- Why partition at all: almost every query here is bounded by a date range
-- ("last quarter", "November peak"), and partition pruning turns a scan of the
-- whole history into a scan of the months actually asked for. The second reason
-- matters more operationally: retention. Dropping a month of data is DETACH
-- PARTITION + DROP TABLE, which is instant and takes no locks worth worrying
-- about. A DELETE of 1.5M rows from a single heap writes as much WAL as the
-- insert did and leaves the space needing VACUUM.
--
-- Why monthly and not daily: partition count is not free. The planner considers
-- every partition, and locking is per-partition. Daily over three years is
-- ~1,100 partitions and planning time starts to show up in short queries.
-- Monthly gives ~36 partitions of ~1.5M rows each, which prunes well and stays
-- cheap to plan. If a single month grew past ~50M rows, weekly would be the
-- next step.
--
-- The primary key must include the partition column: Postgres cannot enforce a
-- unique constraint across partitions without it, because the index is per
-- partition. Hence (shipment_id, shipped_at) rather than shipment_id alone.
-- ---------------------------------------------------------------------------
CREATE TABLE fact_shipment (
    shipment_id      bigint       GENERATED ALWAYS AS IDENTITY,
    tracking_number  text         NOT NULL,
    shipped_at       timestamptz  NOT NULL,
    delivered_at     timestamptz,                       -- NULL while in transit

    -- dimension keys
    date_key         integer      NOT NULL REFERENCES dim_date(date_key),
    carrier_key      integer      NOT NULL REFERENCES dim_carrier(carrier_key),
    origin_facility_key integer   NOT NULL REFERENCES dim_facility(facility_key),
    dest_facility_key   integer   NOT NULL REFERENCES dim_facility(facility_key),
    service_key      integer      NOT NULL REFERENCES dim_service_level(service_key),
    customer_key     integer      NOT NULL REFERENCES dim_customer(customer_key),

    -- measures
    weight_grams     integer      NOT NULL CHECK (weight_grams > 0),
    declared_value   numeric(12,2) NOT NULL CHECK (declared_value >= 0),
    shipping_cost    numeric(10,2) NOT NULL CHECK (shipping_cost >= 0),
    zone_count       smallint     NOT NULL CHECK (zone_count > 0),

    -- degenerate dimension: status has no attributes of its own worth a table
    status           text         NOT NULL CHECK (status IN
                        ('in_transit','delivered','delayed','lost','returned')),

    -- A shipment cannot be delivered before it shipped. Cheap to enforce here,
    -- expensive to discover later in a report that silently reports negative
    -- transit times.
    CONSTRAINT delivered_after_shipped CHECK (delivered_at IS NULL OR delivered_at >= shipped_at),

    PRIMARY KEY (shipment_id, shipped_at)
) PARTITION BY RANGE (shipped_at);

COMMENT ON TABLE fact_shipment IS
    'One row per parcel. Range-partitioned monthly on shipped_at for pruning and cheap retention.';

-- Money is numeric, never float. 0.1 + 0.2 <> 0.3 in binary floating point, and
-- a shipping cost that is off by 1e-16 per row becomes a reconciliation ticket
-- once it is summed over a million rows.

-- ---------------------------------------------------------------------------
-- fact_scan_event  — grain: one row per tracking scan
--
-- Separate table, not extra columns on fact_shipment. A parcel produces a
-- variable number of scans (typically 4-8, occasionally 30 when it bounces
-- between facilities). Modelling that as scan_1_at, scan_2_at ... is the
-- repeating-groups anti-pattern: it caps at whatever N was guessed, wastes
-- space on the common case, and makes "how long between consecutive scans"
-- unanswerable without unpivoting.
--
-- This table is the larger of the two by roughly 6x, so it partitions on the
-- same monthly boundary.
-- ---------------------------------------------------------------------------
CREATE TABLE fact_scan_event (
    scan_id          bigint       GENERATED ALWAYS AS IDENTITY,
    shipment_id      bigint       NOT NULL,
    scanned_at       timestamptz  NOT NULL,
    facility_key     integer      NOT NULL REFERENCES dim_facility(facility_key),
    scan_type        text         NOT NULL CHECK (scan_type IN
                        ('accepted','departed','arrived','out_for_delivery','delivered','exception')),
    -- Sequence within the parcel's journey. Stored rather than derived with
    -- ROW_NUMBER() at query time so "the third scan" is indexable.
    scan_sequence    smallint     NOT NULL CHECK (scan_sequence > 0),

    PRIMARY KEY (scan_id, scanned_at)
) PARTITION BY RANGE (scanned_at);

-- No FK from fact_scan_event.shipment_id to fact_shipment.
--
-- This is a deliberate omission, not an oversight. A foreign key into a
-- partitioned table requires the referenced columns to be the full primary key,
-- which here is (shipment_id, shipped_at) — so the scan table would have to
-- carry shipped_at redundantly on every one of ~120M rows purely to satisfy the
-- constraint. In a warehouse loaded by a controlled ETL process, referential
-- integrity between two fact tables is enforced upstream in the load, and the
-- per-row cost of the constraint on bulk inserts is not worth paying.
-- Dimension FKs are kept: those tables are small and the checks are cheap.

COMMIT;
