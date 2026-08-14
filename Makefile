.PHONY: help up down migrate seed build queries test benchmark refresh sizes psql reset

PGHOST ?= localhost
PGPORT ?= 5433
PGUSER ?= paw
PGDATABASE ?= parcel_analytics
export PGPASSWORD ?= paw

PSQL = psql -h $(PGHOST) -p $(PGPORT) -U $(PGUSER) -d $(PGDATABASE) -v ON_ERROR_STOP=1

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

up: ## Start PostgreSQL and wait for it to accept connections
	docker compose up -d
	@echo "waiting for postgres..."
	@until docker compose exec -T postgres pg_isready -U $(PGUSER) -d $(PGDATABASE) >/dev/null 2>&1; \
	 do sleep 1; done
	@echo "ready on port $(PGPORT)"

down: ## Stop PostgreSQL (keeps the volume)
	docker compose down

reset: ## Stop and destroy the data volume
	docker compose down -v

migrate: ## Apply schema migrations in order
	@for f in migrations/*.sql; do echo "-> $$f"; $(PSQL) -q -f $$f; done

seed: ## Generate dimensions, 2M shipments and ~10M scan events (~4 min)
	@for f in seed/*.sql; do echo "-> $$f"; $(PSQL) -q -f $$f; done

build: up migrate seed ## Full build from nothing to a loaded warehouse
	@$(MAKE) sizes

queries: ## Run the analytical query library
	@$(PSQL) -f queries/analytics.sql

test: ## Run the data quality suite (non-zero exit on failure)
	@$(PSQL) -f tests/data_quality.sql

benchmark: ## Re-measure the indexed queries
	@$(PSQL) -f benchmark/queries.sql

refresh: ## Refresh the materialized view without blocking readers
	@$(PSQL) -c "REFRESH MATERIALIZED VIEW CONCURRENTLY mv_daily_facility_throughput;"

sizes: ## Report row counts and on-disk sizes
	@$(PSQL) -c "\
	SELECT 'fact_shipment'   AS table, count(*) AS rows, \
	       pg_size_pretty(pg_total_relation_size('fact_shipment')) AS size FROM fact_shipment \
	UNION ALL \
	SELECT 'fact_scan_event', count(*), \
	       pg_size_pretty(pg_total_relation_size('fact_scan_event')) FROM fact_scan_event;"

psql: ## Open an interactive session
	@$(PSQL)
