-- 001_dimensions.sql
-- Dimension tables. Surrogate integer keys throughout: business keys are text
-- and change (a carrier renames, a facility is recoded), and a fact table with
-- 20M rows should not carry a 30-byte key it has to compare on every join.

BEGIN;

-- ---------------------------------------------------------------------------
-- dim_date
--
-- A physical date dimension rather than deriving parts with EXTRACT() at query
-- time. EXTRACT(dow FROM ...) is not indexable without an expression index per
-- part, and "was this a public holiday" cannot be derived from the date at all.
-- Pre-computing it once costs ~4k rows and removes a function call from every
-- analytical query that groups by week, quarter, or weekday.
-- ---------------------------------------------------------------------------
CREATE TABLE dim_date (
    date_key        integer     PRIMARY KEY,          -- YYYYMMDD, human-readable
    full_date       date        NOT NULL UNIQUE,
    year            smallint    NOT NULL,
    quarter         smallint    NOT NULL CHECK (quarter BETWEEN 1 AND 4),
    month           smallint    NOT NULL CHECK (month BETWEEN 1 AND 12),
    month_name      text        NOT NULL,
    day_of_month    smallint    NOT NULL CHECK (day_of_month BETWEEN 1 AND 31),
    day_of_week     smallint    NOT NULL CHECK (day_of_week BETWEEN 0 AND 6),
    day_name        text        NOT NULL,
    week_of_year    smallint    NOT NULL,
    is_weekend      boolean     NOT NULL,
    is_peak_season  boolean     NOT NULL              -- Nov-Dec: parcel volume roughly doubles
);

COMMENT ON TABLE dim_date IS
    'Calendar dimension, one row per day. Pre-computed so grouping by week/quarter/weekday needs no function calls.';

-- ---------------------------------------------------------------------------
-- dim_carrier
--
-- Type 1 dimension: overwrite on change. Carrier attributes here (name, mode)
-- are descriptive, not historical, and nobody analyses "revenue while the
-- carrier was still called X". Where history mattered we would need Type 2
-- with valid_from/valid_to and a surrogate key per version.
-- ---------------------------------------------------------------------------
CREATE TABLE dim_carrier (
    carrier_key     integer     GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    carrier_code    text        NOT NULL UNIQUE,      -- natural key from source systems
    carrier_name    text        NOT NULL,
    transport_mode  text        NOT NULL CHECK (transport_mode IN ('road','air','rail','sea')),
    is_active       boolean     NOT NULL DEFAULT true
);

-- ---------------------------------------------------------------------------
-- dim_facility
--
-- Sort centres, delivery stations, hubs. region is denormalised onto the row
-- rather than kept in a separate dim_region: it is a stable 1:N attribute and
-- a snowflake join here would buy normalisation nobody benefits from while
-- costing a join on every regional rollup.
-- ---------------------------------------------------------------------------
CREATE TABLE dim_facility (
    facility_key    integer     GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    facility_code   text        NOT NULL UNIQUE,
    facility_name   text        NOT NULL,
    facility_type   text        NOT NULL CHECK (facility_type IN ('sort_center','delivery_station','hub','depot')),
    city            text        NOT NULL,
    region          text        NOT NULL,
    country_code    char(2)     NOT NULL,
    capacity_per_day integer    NOT NULL CHECK (capacity_per_day > 0)
);

-- ---------------------------------------------------------------------------
-- dim_service_level
--
-- sla_hours lives here rather than on the fact. It is an attribute of the
-- product sold, not of the individual shipment, and storing it once per service
-- level means an SLA change is one UPDATE instead of a rewrite of 20M rows.
-- The trade-off is that historical SLA breaches are recomputed against the
-- current SLA; a Type 2 dimension would fix that if it ever mattered.
-- ---------------------------------------------------------------------------
CREATE TABLE dim_service_level (
    service_key     integer     GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    service_code    text        NOT NULL UNIQUE,
    service_name    text        NOT NULL,
    sla_hours       integer     NOT NULL CHECK (sla_hours > 0),
    is_express      boolean     NOT NULL
);

-- ---------------------------------------------------------------------------
-- dim_customer
--
-- Merchants shipping parcels, not end recipients. segment is used constantly in
-- cohort queries so it is stored, not derived from order counts at query time.
-- ---------------------------------------------------------------------------
CREATE TABLE dim_customer (
    customer_key    integer     GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_code   text        NOT NULL UNIQUE,
    customer_name   text        NOT NULL,
    segment         text        NOT NULL CHECK (segment IN ('enterprise','mid_market','sme','marketplace')),
    country_code    char(2)     NOT NULL,
    onboarded_date  date        NOT NULL
);

COMMIT;
