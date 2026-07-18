#!/usr/bin/env bash
# Scenario test runner — multi-step user journeys.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/smoke/assert/assert.sh"

PASS=0
FAIL=0
echo "===== Scenario Tests ====="

echo
echo "--- Scenario: admin provisions gateway model ---"
GATEWAY_URL=http://localhost:8092

# Step 1: Check gateway is running with default models
MODELS=$(curl -s "$GATEWAY_URL/v1/models" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('data',[])))" 2>/dev/null)
if [[ "$MODELS" -ge 4 ]]; then
  record PASS "gateway has default models" "count=$MODELS"
else
  record FAIL "gateway has default models" "got=$MODELS"
fi

# Step 2: Chat with the default model
RESP=$(curl -s -X POST "$GATEWAY_URL/v1/chat/completions" \
  -d '{"model":"cloud-qwen-max","messages":[{"role":"user","content":"hi"}],"stream":false}')
CHOICES=$(echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('choices',[])))" 2>/dev/null)
[[ "$CHOICES" -gt 0 ]] && record PASS "gateway chat completion" || record FAIL "gateway chat completion"

echo
echo "--- Scenario: eval run lifecycle ---"
EVAL_URL=http://localhost:8000

# Full cycle: create dataset → add case → run → check report
DS=$(curl -s -X POST "$EVAL_URL/v1/datasets" -d '{"name":"scenario-test","tenant_id":"local"}' | python3 -c "import sys,json; print(json.load(sys.stdin).get('dataset_id',''))" 2>/dev/null)
if [[ -z "$DS" ]]; then record FAIL "create dataset"; else
  record PASS "create dataset" "ds=$DS"
  curl -s -X POST "$EVAL_URL/v1/datasets/$DS/cases?version=v1" -d '{"inputs":{"q":"1+1"},"expected":{"a":"2"}}' >/dev/null
  RUN=$(curl -s -X POST "$EVAL_URL/v1/runs" -d "{\"dataset_id\":\"$DS\",\"dataset_version\":\"v1\",\"agent\":{\"agent_id\":\"scenario\",\"tenant_id\":\"local\"},\"scorer_set\":[\"promptfoo_accuracy\"]}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('run_id',''))" 2>/dev/null)
  [[ -n "$RUN" ]] && record PASS "create run" "run=$RUN" || record FAIL "create run"
fi

echo
echo "===== Summary ====="
echo "PASS=$PASS FAIL=$FAIL"
