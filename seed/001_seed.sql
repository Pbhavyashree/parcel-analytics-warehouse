-- 001_seed.sql
-- Generates the dataset. Set-based generation in SQL rather than a row-by-row
-- loader: this writes ~10M rows in well under a minute, where an ORM inserting
-- one row per round trip would take hours and prove nothing about SQL.
--
-- The data is deliberately skewed, not uniform. Uniform random data makes every
-- index look equally good and hides the cases where the planner's choices
-- actually matter. Here: two carriers hold most of the volume, weekends are
-- quiet, November and December roughly double, and a small number of enterprise
-- customers ship far more than the long tail.

\timing on

-- ---------------------------------------------------------------------------
-- dim_date: 2023-01-01 .. 2025-12-31
-- ---------------------------------------------------------------------------
INSERT INTO dim_date (
    date_key, full_date, year, quarter, month, month_name,
    day_of_month, day_of_week, day_name, week_of_year, is_weekend, is_peak_season
)
SELECT
    (to_char(d, 'YYYYMMDD'))::integer,
    d::date,
    EXTRACT(year    FROM d)::smallint,
    EXTRACT(quarter FROM d)::smallint,
    EXTRACT(month   FROM d)::smallint,
    to_char(d, 'Month'),
    EXTRACT(day     FROM d)::smallint,
    EXTRACT(dow     FROM d)::smallint,
    to_char(d, 'Day'),
    EXTRACT(week    FROM d)::smallint,
    EXTRACT(dow FROM d) IN (0, 6),
    EXTRACT(month FROM d) IN (11, 12)
FROM generate_series(DATE '2023-01-01', DATE '2025-12-31', INTERVAL '1 day') AS d;

-- ---------------------------------------------------------------------------
-- dim_carrier
-- ---------------------------------------------------------------------------
INSERT INTO dim_carrier (carrier_code, carrier_name, transport_mode, is_active) VALUES
    ('DHL',  'DHL Paket',            'road', true),
    ('DPD',  'DPD Deutschland',      'road', true),
    ('GLS',  'GLS Germany',          'road', true),
    ('HRM',  'Hermes Germany',       'road', true),
    ('UPS',  'UPS Europe',           'road', true),
    ('FDX',  'FedEx Express',        'air',  true),
    ('TNT',  'TNT Express',          'air',  true),
    ('DBS',  'DB Schenker Rail',     'rail', true),
    ('MSK',  'Maersk Line',          'sea',  true),
    ('PSL',  'PostNL Legacy',        'road', false);

-- ---------------------------------------------------------------------------
-- dim_facility: 60 facilities across German regions
-- ---------------------------------------------------------------------------
INSERT INTO dim_facility (facility_code, facility_name, facility_type, city, region, country_code, capacity_per_day)
SELECT
    'FAC' || lpad(i::text, 4, '0'),
    city || ' ' || ftype,
    ftype,
    city,
    region,
    'DE',
    (20000 + (random() * 80000))::integer
FROM generate_series(1, 60) AS i
CROSS JOIN LATERAL (
    SELECT
        (ARRAY['sort_center','delivery_station','hub','depot'])[1 + (i % 4)] AS ftype,
        (ARRAY['Berlin','Hamburg','Munich','Cologne','Frankfurt','Stuttgart',
               'Duesseldorf','Leipzig','Dortmund','Bremen','Hanover','Nuremberg'])[1 + (i % 12)] AS city,
        (ARRAY['East','North','South','West','Central'])[1 + (i % 5)] AS region
) AS attrs;

-- ---------------------------------------------------------------------------
-- dim_service_level
-- ---------------------------------------------------------------------------
INSERT INTO dim_service_level (service_code, service_name, sla_hours, is_express) VALUES
    ('STD',  'Standard',        72,  false),
    ('ECO',  'Economy',        120,  false),
    ('EXP',  'Express',         24,  true),
    ('NXT',  'Next Day',        18,  true),
    ('SDY',  'Same Day',         8,  true),
    ('INT',  'International',  168,  false);

-- ---------------------------------------------------------------------------
-- dim_customer: 5,000 merchants
-- ---------------------------------------------------------------------------
INSERT INTO dim_customer (customer_code, customer_name, segment, country_code, onboarded_date)
SELECT
    'CUST' || lpad(i::text, 6, '0'),
    'Merchant ' || i,
    CASE
        WHEN i % 100 = 0 THEN 'enterprise'    -- 1%
        WHEN i % 20  = 0 THEN 'mid_market'    -- 4%
        WHEN i % 3   = 0 THEN 'marketplace'   -- ~32%
        ELSE 'sme'
    END,
    'DE',
    DATE '2022-01-01' + ((random() * 1000)::integer)
FROM generate_series(1, 5000) AS i;

ANALYZE dim_date;
ANALYZE dim_carrier;
ANALYZE dim_facility;
ANALYZE dim_service_level;
ANALYZE dim_customer;

-- ---------------------------------------------------------------------------
-- fact_shipment: 2,000,000 parcels
--
-- Volume is shaped, not flat:
--   * weekends get ~35% of a weekday's volume
--   * November/December get ~2x
--   * carrier share is skewed so DHL/DPD dominate
--   * ~8% of enterprise customers generate a disproportionate share
-- ---------------------------------------------------------------------------
-- Weighted day pool.
--
-- The naive way to skew dates is ORDER BY random()/weight inside a correlated
-- subquery, which sorts dim_date once per generated row -- 2M sorts of ~1,100
-- rows. This materialises the weighting instead: each day is expanded into as
-- many pool rows as its weight, so picking a skewed day becomes one indexed
-- lookup on a random integer. Generation drops from "still running" to seconds.
CREATE TEMP TABLE day_pool AS
SELECT
    row_number() OVER (ORDER BY full_date, w) AS pool_id,
    full_date
FROM dim_date
CROSS JOIN LATERAL generate_series(
    1,
    (CASE WHEN is_weekend     THEN 35 ELSE 100 END)
  * (CASE WHEN is_peak_season THEN  2 ELSE   1 END)
) AS w;

CREATE UNIQUE INDEX ON day_pool (pool_id);
ANALYZE day_pool;

INSERT INTO fact_shipment (
    tracking_number, shipped_at, delivered_at,
    date_key, carrier_key, origin_facility_key, dest_facility_key,
    service_key, customer_key,
    weight_grams, declared_value, shipping_cost, zone_count, status
)
SELECT
    'TRK' || lpad(g::text, 12, '0'),
    ship_ts,
    CASE
        WHEN st = 'delivered' THEN ship_ts + (transit_h || ' hours')::interval
        WHEN st = 'delayed'   THEN ship_ts + ((transit_h * 2.5) || ' hours')::interval
        ELSE NULL
    END,
    (to_char(ship_ts, 'YYYYMMDD'))::integer,
    ck,
    of_key,
    CASE WHEN df_key = of_key THEN 1 + (of_key % 60) ELSE df_key END,
    sk,
    cu,
    wt,
    ROUND((5 + random() * 495)::numeric, 2),
    ROUND((3.50 + random() * 28)::numeric, 2),
    1 + (random() * 5)::smallint,
    st
FROM (
    SELECT
        r.g,
        dp.full_date::timestamptz + ((random() * 86000)::integer * INTERVAL '1 second') AS ship_ts,
        CASE
            WHEN r_car < 0.34  THEN 1
            WHEN r_car < 0.60  THEN 2
            WHEN r_car < 0.74  THEN 3
            WHEN r_car < 0.85  THEN 4
            WHEN r_car < 0.92  THEN 5
            WHEN r_car < 0.96  THEN 6
            WHEN r_car < 0.985 THEN 7
            WHEN r_car < 0.995 THEN 8
            ELSE 9
        END AS ck,
        1 + (random() * 59)::integer AS of_key,
        1 + (random() * 59)::integer AS df_key,
        CASE
            WHEN r_svc < 0.55 THEN 1
            WHEN r_svc < 0.72 THEN 2
            WHEN r_svc < 0.86 THEN 3
            WHEN r_svc < 0.94 THEN 4
            WHEN r_svc < 0.98 THEN 5
            ELSE 6
        END AS sk,
        CASE
            WHEN random() < 0.08 THEN 1 + (random() * 49)::integer
            ELSE 1 + (random() * 4999)::integer
        END AS cu,
        (100 + random() * 29900)::integer AS wt,
        (6 + random() * 90)::integer AS transit_h,
        CASE
            WHEN r_st < 0.885 THEN 'delivered'
            WHEN r_st < 0.945 THEN 'in_transit'
            WHEN r_st < 0.985 THEN 'delayed'
            WHEN r_st < 0.996 THEN 'returned'
            ELSE 'lost'
        END AS st
    FROM (
        -- Randoms are generated in the select list of a subquery over
        -- generate_series so they are evaluated once per row. Putting them in a
        -- LATERAL that does not reference g lets the planner treat the whole
        -- subquery as a constant and evaluate it exactly once -- which produces
        -- two million identical rows. Found the hard way.
        SELECT
            g,
            random() AS r_car,
            random() AS r_svc,
            random() AS r_st,
            1 + floor(random() * (SELECT max(pool_id) FROM day_pool))::integer AS pid
        FROM generate_series(1, 2000000) AS g
    ) AS r
    JOIN day_pool dp ON dp.pool_id = r.pid
) AS shaped;

ANALYZE fact_shipment;
