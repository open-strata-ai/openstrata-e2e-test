#!/bin/bash
# OpenStrata — create service databases and users.
# Runs once at Postgres first init (data dir is empty).
# Uses psql directly for statements that cannot run in transactions.

set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    -- Users (idempotent: skip if already exists)
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'billing') THEN
            CREATE USER billing WITH PASSWORD 'billing';
        END IF;
        IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'srs') THEN
            CREATE USER srs WITH PASSWORD 'srs';
        END IF;
        IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'platform') THEN
            CREATE USER platform WITH PASSWORD 'platform';
        END IF;
        IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'eval_user') THEN
            CREATE USER eval_user WITH PASSWORD 'eval';
        END IF;
        IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'guide') THEN
            CREATE USER guide WITH PASSWORD 'guide';
        END IF;
    END
    \$\$;
EOSQL

# Create databases — must run outside a transaction block.
for db in "admin_gov OWNER admin" "billing OWNER billing" "srs OWNER srs" "platform_api OWNER platform" "eval OWNER eval_user" "guide OWNER guide"; do
    name="${db%% *}"
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" -c "CREATE DATABASE $db;" 2>/dev/null || echo "  -> $name already exists, skipping"
done
