# Parcel Analytics Warehouse

A PostgreSQL star schema for parcel logistics, built at a size where the design
decisions matter: **2 million shipments and 10.4 million scan events** across
three years, range-partitioned by month, with every index justified by a
measurement rather than a habit.

The schema is not the interesting part. Anyone can draw a star schema. What
follows is why each choice was made and what it cost.

## Running it

Needs Docker and `psql`.

```bash
make up        # PostgreSQL 16 in Docker, tuned so measurements mean something
make migrate   # schema, partitions, indexes, materialized view
make seed      # generate the data (~4 minutes)
make test      # data quality suite
make queries   # the analytical query library
```

`make build` does the first three in one go. `make help` lists everything.

## What is here

| Path | Purpose |
|---|---|
| `migrations/` | Schema in numbered, ordered files |
| `seed/` | Set-based data generation |
| `queries/analytics.sql` | Six analytical queries: window functions, CTEs, ordered-set aggregates |
| `tests/data_quality.sql` | Eight assertions, non-zero exit on failure |
| `benchmark/queries.sql` | The measured queries |
| `docs/BENCHMARKS.md` | Before/after plans and timings |

## The model

Two fact tables at different grains, five dimensions.

```
              dim_date ──┐
           dim_carrier ──┤
          dim_facility ──┼── fact_shipment ──── fact_scan_event
     dim_service_level ──┤    (2.0M rows)         (10.4M rows)
          dim_customer ──┘    monthly partitions   monthly partitions
```

`fact_shipment` is one row per parcel. `fact_scan_event` is one row per tracking
scan — typically 3–8 per parcel, occasionally 20 when something goes wrong.

Splitting them is the first real decision. The alternative is columns on
`fact_shipment` (`scan_1_at`, `scan_2_at`, …), which is the repeating-groups
anti-pattern: it caps at whatever N was guessed, wastes space on the common
case, and makes "how long did this parcel sit between scans" unanswerable
without unpivoting.

## Measured results

Full plans in [`docs/BENCHMARKS.md`](docs/BENCHMARKS.md). Median of three runs,
warm cache.

| Query | Before | After | Change |
|---|---|---|---|
| Scan history of one parcel | 1,592 ms | **0.95 ms** | ~1,600× |
| One customer's full history | 271 ms | **13.4 ms** | ~20× |
| Regional revenue, via matview | 979 ms | **14.5 ms** | ~67× |
| Carrier SLA breaches, one quarter | 127 ms | **120 ms** | ~1× |

**The last row is the honest one.** Adding indexes did essentially nothing for
the SLA query, because partition pruning had already done the work — the
predicate on `shipped_at` reduces 36 partitions to 3, and once you are reading
only a quarter of the data, a sequential scan of it is what you want. An index
would have to be dramatically more selective to beat a scan the planner has
already narrowed by 92%.

That result is worth more than the 1,600× one. It is the case where the obvious
optimisation was not the answer, and the only way to know was to measure both.

## Design decisions

**Partitioning is monthly, not daily.** Almost every query is bounded by a date
range, so pruning is the main win — but partition count is not free. The planner
considers every partition and locks per partition; daily over three years is
~1,100 of them and planning time starts showing up in short queries. Monthly
gives 36 partitions of ~55k rows each, which prunes well and stays cheap to
plan. Past ~50M rows in a single month, weekly would be next.

**The real reason for partitioning is retention, not speed.** Dropping a month
is `DETACH PARTITION` plus `DROP TABLE` — instant. A `DELETE` of 55k rows from a
single heap writes as much WAL as the insert did and leaves space needing
`VACUUM`. This matters more in practice than the query gains do.

**`fact_scan_event` has three more partitions than `fact_shipment`.** Scans
trail their shipment: a parcel accepted on 31 December is still scanning in
January. Sizing both to the same 36 months fails on the last day of the range
with `no partition of relation found for row` — everything works until the
boundary. This is also why production partition creation runs ahead of time
rather than just-in-time: a missing partition is not created automatically, the
insert simply fails.

**No default partition.** It silently accepts rows that belong elsewhere, and
once it holds data, attaching a partition covering that range requires scanning
it. Failing loudly is better.

**No foreign key from `fact_scan_event` to `fact_shipment`.** A foreign key into
a partitioned table must reference the full primary key, which here is
`(shipment_id, shipped_at)` — so the scan table would have to carry
`shipped_at` redundantly on all 10.4M rows purely to satisfy the constraint.
In a warehouse loaded by controlled ETL, integrity between two fact tables
belongs in the load. The trade-off is paid for by test 2 in the quality suite,
which asserts the relationship that the schema no longer enforces. Dimension
FKs are kept — those tables are tiny and the checks are cheap.

**One partial index.** `idx_shipment_exceptions` covers only
`status <> 'delivered'`. About 88% of rows are delivered and the operational
question is nearly always about the ones that are not: what is late, lost, or
coming back. Excluding delivered rows makes the index roughly one-eighth the
size, so it stays cached, and inserting a delivered parcel does not touch it at
all. The cost is that the planner can only use it when it can prove the query
excludes delivered rows — a partial index rewards a well-understood access
pattern and is dead weight against an unpredictable one.

**Composite index column order.** `(customer_key, shipped_at DESC)` — equality
predicate first, range and sort second. Reversed, it would still support the
range but not the equality lookup efficiently.

**A materialized view, not a plain view or a trigger-maintained table.** A plain
view re-aggregates 2M rows on every dashboard load. A trigger firing per row
turns a 2M-row bulk load into 2M extra updates against contended aggregate rows.
Bulk-load-then-refresh is the cheaper shape when staleness of minutes is
acceptable — which for daily throughput reporting it is, and for anything a
customer sees as live it is not.

**The matview has a unique index specifically to enable `REFRESH …
CONCURRENTLY`.** Without one, a refresh takes `ACCESS EXCLUSIVE` and every
dashboard query blocks until it completes. With it, readers keep serving the old
snapshot. Refresh takes 4.1 s here.

**Money is `numeric`, never `float`.** `0.1 + 0.2 <> 0.3` in binary floating
point, and an error of 1e-16 per row becomes a reconciliation ticket once it is
summed over two million.

**`dim_date` is a physical table.** `EXTRACT(dow FROM …)` is not indexable
without an expression index per part, and "was this a public holiday" cannot be
derived from a date at all. ~1,100 rows removes a function call from every query
that groups by week, quarter, or weekday.

**The generated data is skewed on purpose.** Uniform random data makes every
index look equally good and hides the cases where the planner's choices matter.
Here two carriers hold 60% of volume, weekends run at ~35% of a weekday, and
November–December roughly doubles — which the peak-season query confirms at a
1.97–1.99× multiplier across regions.

## Two bugs worth keeping in the record

**Generation produced two million identical rows.** The randoms were computed in
a `LATERAL` subquery that did not reference the outer `generate_series` column,
so PostgreSQL evaluated it once and treated the results as constants. Every
parcel shipped on the same day with the same status. Fixed by moving the
`random()` calls into the select list of a subquery over `generate_series`,
where they are evaluated per row. Volatility does not save you if the planner
decides the whole subquery is invariant.

**The scan-sequence test failed against correct data.** Test 6 asserts that each
parcel's scans run 1..n with no gaps, and it was filtering by a month of
`scanned_at`. A parcel accepted on 30 June is still scanning in July, so the
window sliced its sequence in half and the surviving rows legitimately started
at 4. The data was right; the test was wrong. Any assertion about a whole entity
has to select whole entities — the fix samples by `shipment_id`.

## What I would add next

- **Incremental refresh** of the matview. `REFRESH CONCURRENTLY` rebuilds the
  whole thing; at 66k rows that is fine, at 10M it would not be. The next step
  is a delta table keyed on the load watermark.
- **`BRIN` on `shipped_at`** as a comparison against the current B-tree. The data
  is naturally clustered by time, which is exactly the BRIN case, and the index
  would be a fraction of the size. Worth measuring rather than assuming.
- **A Type 2 dimension.** Every dimension here is Type 1 (overwrite on change),
  so an SLA change silently rewrites history — breaches are recomputed against
  today's SLA rather than the one in force at the time.
- **`pgTAP`** instead of hand-rolled `DO` blocks, for proper TAP output that a CI
  runner can parse.
- **A real ETL path.** The data is generated in-database; a production version
  would land files, stage them, and load with an idempotent upsert keyed on
  tracking number so a re-run does not double-count.
