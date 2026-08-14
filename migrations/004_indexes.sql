-- 004_indexes.sql
-- Indexes, added after the data was loaded and measured.
--
-- Deliberately not "an index on every foreign key". Every index is paid for on
-- every INSERT and UPDATE and in storage; on a 10M-row partitioned fact table
-- that cost is real. Each one below exists because a query that matters was
-- measured without it first. See docs/BENCHMARKS.md for the before/after plans.
--
-- Indexes on a partitioned parent are propagated to every partition
-- automatically; declaring them once here creates 36 (or 39) physical indexes.

BEGIN;

-- ---------------------------------------------------------------------------
-- fact_scan_event (shipment_id, scan_sequence)
--
-- The single biggest win in the project. "Show me the journey of this parcel"
-- is the most common operational query there is, and without this index it is a
-- sequential scan of all 39 partitions -- ~1.6s to return six rows.
--
-- Composite rather than just (shipment_id): scan_sequence as the second column
-- means the rows come back already ordered, so the ORDER BY is satisfied by the
-- index and the sort disappears from the plan. On six rows the sort is
-- irrelevant; the point is that it costs nothing to get for free.
--
-- Note the partition key is NOT in this index. Postgres creates it per
-- partition, and a query filtering only on shipment_id cannot prune -- it hits
-- all 39 indexes. That is still ~39 cheap index probes instead of a 10M-row
-- scan. Pruning would need scanned_at in the predicate, which the operational
-- query does not have.
-- ---------------------------------------------------------------------------
CREATE INDEX idx_scan_shipment_seq
    ON fact_scan_event (shipment_id, scan_sequence);

-- ---------------------------------------------------------------------------
-- fact_shipment (customer_key, shipped_at DESC)
--
-- Per-customer reporting: "this merchant's shipments, most recent first".
-- customer_key leads because it is the equality predicate; shipped_at follows
-- because it is the range and the sort. The reverse order would work for the
-- range scan but would not support the equality lookup efficiently.
--
-- DESC because every UI that shows this list shows newest first. An ASC index
-- can be scanned backwards, so this is a marginal gain rather than a necessary
-- one -- but it is free to specify.
-- ---------------------------------------------------------------------------
CREATE INDEX idx_shipment_customer_date
    ON fact_shipment (customer_key, shipped_at DESC);

-- ---------------------------------------------------------------------------
-- fact_shipment (carrier_key, shipped_at) WHERE status <> 'delivered'
--
-- Partial index. Roughly 88% of rows are 'delivered', and the operational
-- question is almost always about the ones that are not: what is stuck, late,
-- lost, or coming back. Excluding the delivered rows makes the index about
-- one-eighth the size, which means it stays in cache and costs far less to
-- maintain -- an INSERT of a delivered parcel does not touch it at all.
--
-- The trade-off: the planner can only use this index when it can prove the
-- query excludes delivered rows. A query without that predicate ignores it
-- entirely. Partial indexes reward a well-understood access pattern and are
-- dead weight against an unpredictable one.
-- ---------------------------------------------------------------------------
CREATE INDEX idx_shipment_exceptions
    ON fact_shipment (carrier_key, shipped_at)
    WHERE status <> 'delivered';

-- ---------------------------------------------------------------------------
-- fact_shipment (tracking_number)
--
-- Customer-facing lookup by tracking number. Unique in the source system, but
-- declared as a plain index rather than UNIQUE: a unique constraint on a
-- partitioned table must include the partition key, and a tracking number
-- lookup has no date to offer. Uniqueness is enforced upstream at load.
-- ---------------------------------------------------------------------------
CREATE INDEX idx_shipment_tracking
    ON fact_shipment (tracking_number);

COMMIT;

-- Indexes change the statistics the planner reasons about; ANALYZE so it knows.
ANALYZE fact_shipment;
ANALYZE fact_scan_event;
