# Infra — Docker Compose for OpenStrata E2E testing

Shared infrastructure for running OpenStrata services with real
external dependencies (PostgreSQL, Redis).

## Quick start

```bash
# Start everything
docker compose up -d

# Check service logs
docker compose logs -f

# Start infra only
docker compose up -d postgres redis
```

## Services included

| Service | Port | DB | Redis | Status |
|---|---|---|---|---|
| postgres | 5432 | — | — | Infra |
| redis | 6379 | — | — | Infra |
| admin-service | 8088 | postgres:admin_gov | InMemory adapter | Wired |
| billing-service | 8084 | postgres:billing | InMemory adapter | Wired |
| srs-service | 8083 | postgres:srs | InMemory adapter | Wired |
| platform-api | 8081 | postgres:platform_api | InMemory adapter | Wired |
| eval-service | 8000 | postgres:eval | redis:6379 | Wired |

Go services (gateway-core, provisioning-engine, tool-registry,
sandbox-manager, dependency-resolver) are commented out — they
only have in-memory fakes. Uncomment them after implementing
their PostgreSQL/Redis adapters.

## Database init

`postgres/init/01-databases.sql` creates the databases and users.
Flyway (Java) and SQLAlchemy (Python) handle table creation.
