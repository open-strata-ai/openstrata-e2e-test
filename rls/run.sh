#!/usr/bin/env bash
#
# RLS runtime enforcement test (R-002).
#
# Validates that tenant isolation is ACTUALLY ENFORCED at the PostgreSQL tier
# (not merely compiled), using a non-owner probe role that is subject to the
# `tenant_isolation` RLS policy installed by V2/V5 migrations.
#
# The application JDBC user owns the tables and would otherwise bypass RLS, so we
# exercise the policy through a dedicated `rls_probe` role (no table ownership,
# BYPASSRLS=false) — exactly the posture a tenant-scoped connection has in prod.
#
# Usage:
#   ./rls/run.sh                 # uses docker exec into the compose postgres
#   PSQL=/usr/bin/psql ./rls/run.sh   # or point at a host psql client

set -uo pipefail

PGUSER="${PGUSER:-admin}"
PGPASSWORD="${PGPASSWORD:-admin}"
PGDATABASE="${PGDATABASE:-platform_api}"
PG_CONTAINER="${PG_CONTAINER:-openstrata-e2e-test-postgres-1}"

# Resolve a psql CLI: prefer $PSQL, else host `psql`, else docker exec.
if [ -n "${PSQL:-}" ]; then
  PSQL_CMD=("$PSQL")
elif command -v psql >/dev/null 2>&1; then
  PSQL_CMD=(psql)
else
  PSQL_CMD=(docker exec -i "$PG_CONTAINER" psql -U "$PGUSER" -d "$PGDATABASE")
fi
# For docker-exec we must supply the password via env inside the container.
export PGPASSWORD

run_sql() { "${PSQL_CMD[@]}" -v ON_ERROR_STOP=1; }
# -tAq: tuples-only, unaligned, QUIET (suppress echoed SET/RESET command tags).
query()  { "${PSQL_CMD[@]}" -tAq -c "$1" 2>&1 | tr -d '[:space:]'; }

echo "== RLS runtime test (DB=$PGDATABASE, cli=${PSQL_CMD[*]}) =="

# --- one-time setup (idempotent) ---
run_sql >/dev/null <<'SQL'
DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='rls_probe') THEN
    CREATE ROLE rls_probe LOGIN PASSWORD 'probe';
  END IF;
END $$;
GRANT CONNECT ON DATABASE platform_api TO rls_probe;
GRANT USAGE ON SCHEMA public TO rls_probe;
GRANT SELECT ON tenants TO rls_probe;
INSERT INTO tenants (tenant_id, name, status, plan_id, multitenancy, created_at, updated_at)
VALUES ('tenantA','Tenant A','ACTIVE','plan_free', false, now(), now()),
       ('tenantB','Tenant B','ACTIVE','plan_free', false, now(), now())
ON CONFLICT (tenant_id) DO NOTHING;
SQL

rc=0
assert_count() {
  local want="$1"; local setup="$2"; local label="$3"
  local got
  got=$(query "SET ROLE rls_probe; ${setup} SELECT count(*) FROM tenants; RESET ROLE;")
  if [ "$got" = "$want" ]; then
    echo "PASS: ${label} -> ${got} (expected ${want})"
  else
    echo "FAIL: ${label} -> '${got}' (expected ${want})"
    rc=1
  fi
}

# NOTE: RlsTransactionManager always sets app.bypass_rls (to 'off' for normal
# tenants) before a query. The V5 policy references current_setting('app.bypass_rls'),
# which errors on an UNREGISTERED GUC — so the test must register it too.
assert_count 1 "SET app.bypass_rls='off'; SET app.tenant_id='tenantA';" "app.tenant_id=tenantA"
assert_count 1 "SET app.bypass_rls='off'; SET app.tenant_id='tenantB';" "app.tenant_id=tenantB"
assert_count 0 "SET app.bypass_rls='off'; RESET app.tenant_id;"      "app.tenant_id=NULL (reset)"

bypass=$(query "SET app.bypass_rls='on'; SET ROLE rls_probe; SELECT count(*) FROM tenants; RESET ROLE;")
if [ "$bypass" = "2" ]; then
  echo "PASS: app.bypass_rls=on -> ${bypass} (expected 2)"
else
  echo "FAIL: app.bypass_rls=on -> '${bypass}' (expected 2)"
  rc=1
fi

if [ "$rc" = "0" ]; then
  echo "RLS_RUNTIME_OK"
else
  echo "RLS_RUNTIME_FAIL"
  exit 1
fi
