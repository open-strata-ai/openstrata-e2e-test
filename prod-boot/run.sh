#!/usr/bin/env bash
#
# Prod-boot regression (P2-D).
#
# Boots every Java service in its `prod` Spring profile against the shared
# Postgres + Redis (the same backends the Docker Compose stack uses) and asserts
# each reaches the "Started" log line. This continuously verifies the prod boot
# path — including Flyway migrations, ddl-auto:validate, the RLS transaction
# manager, and the real SPI adapters wired in PlatformApiProductionConfig — so a
# regression in the release artifact is caught before tagging.
#
# Prerequisites: Postgres + Redis reachable at localhost:5432 / localhost:6379
# (e.g. `docker compose up -d postgres redis`, or the full stack).
#
# Usage:
#   REPOS=/path/to/repos ./prod-boot/run.sh

set -uo pipefail

REPOS="${REPOS:-/Users/weiping/Code/openstrata}"
JAVA="${JAVA:-java}"
TIMEOUT_S="${TIMEOUT_S:-45}"
PGHOST="${PGHOST:-localhost}"
PGPORT="${PGPORT:-5432}"
REDIS_HOST="${REDIS_HOST:-localhost}"

# name|http_port|db|user|pass
SERVICES=(
  "ai-platform-api|8081|platform_api|platform|platform"
  "ai-admin-service|8088|admin_gov|admin|admin"
  "ai-billing-service|8084|billing|billing|billing"
  "ai-srs-service|8083|srs|srs|srs"
)

LOGDIR="$(mktemp -d)"
PIDS=()

cleanup() {
  for p in "${PIDS[@]:-}"; do
    [ -n "$p" ] && kill "$p" 2>/dev/null || true
  done
}
trap cleanup EXIT

rc=0
for entry in "${SERVICES[@]}"; do
  IFS='|' read -r name port db user pass <<< "$entry"
  jar=$(ls "$REPOS/$name"/target/*.jar 2>/dev/null | head -1)
  if [ -z "$jar" ]; then
    echo "SKIP: $name (no built jar)"; continue
  fi
  log="$LOGDIR/$name.log"
  echo "== booting $name (port $port, db=$db) =="
  "$JAVA" -jar "$jar" --spring.profiles.active=prod --server.port="$port" \
    --spring.datasource.url="jdbc:postgresql://${PGHOST}:${PGPORT}/${db}" \
    --spring.datasource.username="$user" \
    --spring.datasource.password="$pass" \
    --spring.data.redis.host="$REDIS_HOST" \
    > "$log" 2>&1 &
  pid=$!
  PIDS+=("$pid")

  started=""
  for i in $(seq 1 "$TIMEOUT_S"); do
    if grep -q "Started .*Application in" "$log" 2>/dev/null; then
      started=1; break
    fi
    if ! kill -0 "$pid" 2>/dev/null; then break; fi
    sleep 1
  done

  if [ -n "$started" ]; then
    echo "PASS: $name started (pid $pid)"
  else
    echo "FAIL: $name did not start within ${TIMEOUT_S}s"
    tail -20 "$log"
    rc=1
    kill "$pid" 2>/dev/null || true
  fi
done

sleep 2
if [ "$rc" = "0" ]; then echo "PROD_BOOT_OK"; else echo "PROD_BOOT_FAIL"; fi
exit $rc
