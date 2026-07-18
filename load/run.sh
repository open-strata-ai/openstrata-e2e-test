#!/usr/bin/env bash
# Load test runner — basic curl-based concurrency.
set -uo pipefail

echo "===== Load Tests ====="
echo "NOTE: Load tests require all services running (docker compose up -d)"
echo "      and may take several minutes. Use --quick for a smoke check."
echo

TARGETS=(
  "gateway-models:GET:http://localhost:8092/v1/models"
  "gateway-chat:POST:http://localhost:8092/v1/chat/completions"
  "resolver-plan:POST:http://localhost:8090/v1/resolve"
  "eval-health:GET:http://localhost:8000/openapi.json"
)

quick() {
  local label="$1" method="$2" url="$3"
  local start end elapsed
  start=$(date +%s%N)
  for i in $(seq 1 5); do
    if [[ "$method" == "GET" ]]; then
      curl -s -o /dev/null -w '%{http_code}' "$url" >/dev/null
    else
      curl -s -o /dev/null -w '%{http_code}' -X POST "$url" -d '{}' >/dev/null
    fi
  done
  end=$(date +%s%N)
  elapsed=$(( (end - start) / 1000000 ))
  echo "  $label: 5 requests in ${elapsed}ms (avg $((elapsed/5))ms/req)"
}

echo "--- Quick smoke ($(date)) ---"
for target in "${TARGETS[@]}"; do
  IFS=':' read -r label method url <<< "$target"
  quick "$label" "$method" "$url"
done

echo
echo "===== Done ====="
