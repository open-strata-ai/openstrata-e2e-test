#!/usr/bin/env bash
# Contract conformance runner.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/smoke/assert/assert.sh"

PASS=0
FAIL=0

echo "===== Contract Conformance Tests ====="

echo
echo "--- resolver -> provisioner round-trip ---"
# Plan from resolver, apply to provisioner — verify plan is stored
RESOLVER_URL=http://localhost:8090
PROVISIONER_URL=http://localhost:8091

# Resolve a plan
cat >/tmp/contract_resolve.json <<JSON
{"tenant_id":"local","enabled":{"gateway":true},"profile":"starter"}
JSON
CS=$(curl -s "$RESOLVER_URL/v1/resolve" -d @/tmp/contract_resolve.json | python3 -c "import sys,json; print(json.load(sys.stdin).get('checksum',''))" 2>/dev/null)
if [[ -n "$CS" ]]; then
  record PASS "resolver produces checksum" "cs=${CS:0:16}"
  # Verify plan is retrievable
  PLAN=$(curl -s "$RESOLVER_URL/v1/plan/$CS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('checksum','') or 'ok')" 2>/dev/null)
  [[ -n "$PLAN" ]] && record PASS "resolver GET /v1/plan/{cs}" || record FAIL "resolver GET /v1/plan/{cs}"
else
  record FAIL "resolver produces checksum"
fi

echo
echo "--- gateway model catalog consistency ---"
GATEWAY_URL=http://localhost:8092
MODELS=$(curl -s "$GATEWAY_URL/v1/models" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('data',[])))" 2>/dev/null)
[[ "$MODELS" -gt 0 ]] && record PASS "gateway lists models" "count=$MODELS" || record FAIL "gateway lists models"

echo
echo "--- admin governance surface (ai-admin-service) ---"
ADM=http://localhost:8088
TEN=$(http_status "$ADM/api/v1/admin/tenants" GET "" "$HDR")
if [[ "$TEN" =~ ^2 ]]; then record PASS "admin lists tenants"; else record FAIL "admin lists tenants" "code=$TEN (needs ai-admin-service on :8088)"; fi
GOV=$(http_status "$ADM/api/v1/admin/global-resources" GET "" "$HDR")
if [[ "$GOV" =~ ^2 ]]; then record PASS "admin global-resources"; else record FAIL "admin global-resources" "code=$GOV (needs ai-admin-service on :8088)"; fi
AUD=$(http_status "$ADM/api/v1/admin/audit" GET "" "$HDR")
if [[ "$AUD" =~ ^2 ]]; then record PASS "admin audit log"; else record FAIL "admin audit log" "code=$AUD (needs ai-admin-service on :8088)"; fi

echo
echo "--- eval-service run lifecycle ---"
EVAL_URL=http://localhost:8000
# Create dataset
DS=$(curl -s -X POST "$EVAL_URL/v1/datasets" -d '{"name":"contract-test","tenant_id":"local"}' | python3 -c "import sys,json; print(json.load(sys.stdin).get('dataset_id',''))" 2>/dev/null)
if [[ -n "$DS" ]]; then
  record PASS "eval create dataset" "ds=$DS"
  # Create run
  RUN=$(curl -s -X POST "$EVAL_URL/v1/runs" -d "{\"dataset_id\":\"$DS\",\"dataset_version\":\"v1\",\"agent\":{\"agent_id\":\"ct\",\"tenant_id\":\"local\"},\"scorer_set\":[\"promptfoo_accuracy\"]}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('run_id',''))" 2>/dev/null)
  [[ -n "$RUN" ]] && record PASS "eval create run" "run=$RUN" || record FAIL "eval create run"
else
  record FAIL "eval create dataset"
fi

echo
echo "===== Summary ====="
echo "PASS=$PASS FAIL=$FAIL"
