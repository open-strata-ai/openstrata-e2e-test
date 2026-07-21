# OpenStrata E2E Test Harness

System-integration and end-to-end test suite for the
[OpenStrata](https://openstrata.cc) AI platform.

## Layout

```
openstrata-e2e-test/
  smoke/     Integration smoke test — boots all services offline,
             exercises real HTTP contracts, drives the CLI via a
             reverse proxy. (PASS=27  FAIL=0  GAP=0)
  contract/  (future) Cross-service contract conformance tests.
  load/      (future) Load / soak / stress tests.
  scenario/  (future) Multi-step user-journey scenarios.
```

## Prerequisites

- Go 1.22+
- Python 3.12+
- curl
- All 18 OpenStrata code repositories cloned as **siblings** of this repo:

```
~/workspace/
  ai-cli/
  ai-gateway-core/
  ai-dependency-resolver/
  ai-provisioning-engine/
  ai-eval-service/
  ...
  openstrata-e2e-test/     ← you are here
```

## Run the smoke test

```bash
cd smoke
./run.sh               # full (Go + Python eval-service)
./run.sh --no-eval     # Go-only (faster)
```

The `openstrata-e2e-test` repo is part of the
[open-strata-ai](https://github.com/open-strata-ai) GitHub org.

## Configuration: `.env` vs `.env.example`

`docker-compose.yml` is driven by environment variables. The actual `.env`
file is **gitignored** (secret-free but machine-local), so it is **never
committed**. A tracked `.env.example` is provided as the template.

**After cloning, create your local `.env` once:**

```bash
cp .env.example .env
```

`docker-compose.yml` already supplies safe built-in defaults for every
variable (e.g. `${GUIDE_DB_USER:-guide}`), so the stack boots even if a
variable is absent from your `.env`. Edit `.env` only to override defaults
(e.g. a different Postgres password).

### Guide service notes

- `guide-service` (port **8080**) connects to the `guide` Postgres database.
- The `guide` **role** and **database** are created automatically by
  `infra/postgres/init/01-databases.sh` — but **only on a fresh Postgres
  volume** (first `docker compose up -d` with an empty data dir).
- If you are reusing an **already-initialized** Postgres volume, the init
  script will not re-run. Create them manually:

  ```bash
  docker compose exec postgres psql -U admin -d postgres -c \
    "DO \$\$ BEGIN
       IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='guide') THEN
         CREATE USER guide WITH PASSWORD 'guide'; END IF;
     END \$\$;"
  docker compose exec postgres psql -U admin -d postgres -c \
    "CREATE DATABASE guide OWNER guide;"
  ```

- Run it: `docker compose up -d guide-service` (waits for `postgres` healthy).
  The schema is generated from the JPA entities (`spring.jpa.hibernate.ddl-auto:
  update`; Flyway is disabled to avoid the Postgres 16 / Flyway 10 incompatibility).

