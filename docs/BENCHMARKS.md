# Benchmarks

PostgreSQL 16.14. 2,000,000 shipments across 36 monthly partitions;
10,402,834 scan events across 39. Median of three runs, warm cache.
`work_mem = 32MB`, `shared_buffers = 256MB`.

Reproduce with `make benchmark`.

## Summary

| Query | Before indexes | After | Change |
|---|---|---|---|
| B3 scan history of one parcel | 1,592 ms | **0.95 ms** | ~1,600x |
| B2 one customer, full history | 271 ms | **13.4 ms** | ~20x |
| B4 regional revenue via matview | 979 ms | **14.5 ms** | ~67x |
| B1 carrier SLA breaches, 1 quarter | 127 ms | **120 ms** | ~1x |

## B3 — scan history of one parcel

The largest win in the project, and the most common operational query:
"where has this parcel been?"

```sql
SELECT scan_type, scanned_at FROM fact_scan_event
WHERE shipment_id = 1234567 ORDER BY scan_sequence;
```

### Before — sequential scan of all 39 partitions
```
Execution Time: 1592.178 ms
```

### After — index scan on idx_scan_shipment_seq
```
Sort  (cost=640.21..640.69 rows=191 width=20) (actual time=0.795..0.804 rows=6 loops=1)
  Sort Key: fact_scan_event.scan_sequence
  Sort Method: quicksort  Memory: 25kB
  Buffers: shared hit=117
  ->  Append  (cost=0.42..632.98 rows=191 width=20) (actual time=0.259..0.740 rows=6 loops=1)
        Buffers: shared hit=114
        ->  Index Scan using fact_scan_event_2023_01_shipment_id_scan_sequence_idx on fact_scan_event_2023_01 fact_scan_event_1  (cost=0.42..17.28 rows=6 width=20) (actual time=0.035..0.036 rows=0 loops=1)
              Index Cond: (shipment_id = 1234567)
              Buffers: shared hit=6
  ... 36 further partition index scans elided ...
  Buffers: shared hit=2679
Planning Time: 6.295 ms
Execution Time: 0.961 ms
```

Note the plan still touches all 39 partitions: the query filters on
`shipment_id` only, and the partition key is `scanned_at`, so nothing can
be pruned. It is 39 cheap index probes instead of one 10.4M-row scan.
Pruning would require a date in the predicate, which this query does not
have and operationally should not need.

## B2 — one customer's full history

```sql
SELECT count(*), sum(shipping_cost) FROM fact_shipment WHERE customer_key = 17;
```

### Before
```
Execution Time: 271.165 ms   (Buffers: shared hit=2226 read=28563)
```

### After
```
Aggregate  (cost=10586.67..10586.68 rows=1 width=40) (actual time=16.564..16.628 rows=1 loops=1)
  Buffers: shared hit=3470 read=88
  ->  Append  (cost=4.99..10568.46 rows=3641 width=6) (actual time=0.065..15.899 rows=3682 loops=1)
        Buffers: shared hit=3470 read=88
        ->  Bitmap Heap Scan on fact_shipment_2023_01 fact_shipment_1  (cost=4.99..259.92 rows=90 width=6) (actual time=0.064..0.386 rows=82 loops=1)
              Recheck Cond: (customer_key = 17)
              Heap Blocks: exact=77
              Buffers: shared hit=77 read=2
  ... further partitions elided ...
  Buffers: shared hit=3554
Planning Time: 8.921 ms
Execution Time: 13.413 ms
```

Bitmap heap scans rather than plain index scans: ~3,700 matching rows are
scattered across the heap, so PostgreSQL builds a bitmap of pages first and
visits each once in physical order instead of chasing 3,700 random tuples.

## B1 — carrier SLA breaches, one quarter

The query where indexing did not help.

```
Before: 127.254 ms
After:  120.535 ms
```

Partition pruning had already done the work. The predicate on `shipped_at`
cuts 36 partitions to 3:

```
Finalize Aggregate  (cost=4953.72..4953.73 rows=1 width=8)
  ->  Gather  (cost=4953.51..4953.72 rows=2 width=8)
        Workers Planned: 2
        ->  Partial Aggregate  (cost=3953.51..3953.52 rows=1 width=8)
              ->  Parallel Append  (cost=0.00..3802.92 rows=60233 width=0)
                    ->  Parallel Seq Scan on fact_shipment_2025_07 fact_shipment_1  (cost=0.00..1206.70 rows=29308 width=0)
```

Once the planner is reading only a quarter of the data and needs most rows
in it, a sequential scan of that subset is the correct plan. An index would
have to be far more selective to win. Worth recording as a negative result:
the obvious optimisation was not the answer.

## B4 — materialized view vs. aggregating the fact table

### Aggregating fact_shipment directly
```
                                ->  Seq Scan on dim_facility fac  (cost=0.00..1.60 rows=60 width=10) (actual time=0.038..0.044 rows=60 loops=3)
Planning Time: 8.718 ms
Execution Time: 967.153 ms
```

### Reading mv_daily_facility_throughput
```
        Rows Removed by Filter: 43858
Planning Time: 0.850 ms
Execution Time: 20.004 ms
```

`REFRESH MATERIALIZED VIEW CONCURRENTLY` takes 4.1 s, so the trade is ~4 s
of write per refresh against ~965 ms saved on every read.
