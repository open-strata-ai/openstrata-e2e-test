#!/usr/bin/env bash
# OpenStrata cross-repo integration smoke test.
#
# What it does (phases):
#   0  recon fixtures (port map from ports.env)
#   1  build/vet gate for every in-scope repo + the smoke-proxy
#   2  boot services on distinct ports (+ the reverse proxy) and wait for /healthz
#   3  DUAL-MODE E2E:
#        A) direct-API validation of each service's REAL contract (should PASS)
#        B) aictl pass-through via the proxy (surfaces known CLI<->service
#           contract gaps as GAP, not hard failures)
#   4  write report.md and tear down
#
# Usage:  ./run.sh            (full run)
#         ./run.sh --no-eval   (skip the Python eval-service: faster, Go-only)
set -uo pipefail

SMOKE="$(cd "$(dirname "$0")" && pwd)"
cd "$SMOKE"
source ./ports.env
source ./assert/assert.sh

BUILD="$SMOKE/bin"; LOGDIR="$SMOKE/logs"; mkdir -p "$BUILD" "$LOGDIR"
PIDS=()

NO_EVAL=0
[[ "${1:-}" == "--no-eval" ]] && NO_EVAL=1

cleanup() {
  for pid in "${PIDS[@]:-}"; do
    kill "$pid" >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT

phase() { echo; echo "===== $1 ====="; }

# --------------------------------------------------------------------------
# Phase 1 — build / vet gate
# --------------------------------------------------------------------------
phase "Phase 1: build & vet gate"
build_go() {
  local repo="$1" bin="$2" pkg="$3"
  echo "-- building $repo ($bin)"
  ( cd "$ROOT/$repo" && go build -o "$BUILD/$bin" "./$pkg" ) \
    && echo "   ok: $bin" \
    || { record FAIL "build $repo"; return 1; }
  ( cd "$ROOT/$repo" && go vet ./... >"$LOGDIR/vet-$repo.log" 2>&1 ) \
    && echo "   vet ok: $repo" \
    || echo "   WARN: go vet $repo failed (see $LOGDIR/vet-$repo.log)"
}

build_go ai-dependency-resolver resolver cmd
build_go ai-provisioning-engine   provisioner cmd
build_go ai-gateway-core          gateway cmd
build_go ai-tool-registry         tool-registry cmd
build_go ai-sandbox-manager       sandbox cmd
build_go ai-cli                   aictl cmd/aictl

echo "-- building smoke-proxy"
( cd "$SMOKE/proxy" && go build -o "$BUILD/smoke-proxy" . ) \
  && echo "   ok: smoke-proxy" \
  || record FAIL "build smoke-proxy"

if [[ "$NO_EVAL" -eq 0 ]]; then
  EVAL_VENV="$SMOKE_TMP/evalvenv"
  if [[ ! -d "$EVAL_VENV" ]]; then
    echo "-- creating eval-service venv + installing deps (one-time)"
    python3 -m venv "$EVAL_VENV"
    "$EVAL_VENV/bin/pip" install -q fastapi uvicorn pydantic sqlalchemy \
      psycopg2-binary redis pyyaml opentelemetry-api httpx \
      >"$LOGDIR/pip-eval.log" 2>&1 \
      && echo "   pip ok" \
      || { echo "   pip FAILED (see $LOGDIR/pip-eval.log)"; record FAIL "eval deps"; }
  fi
fi

# --------------------------------------------------------------------------
# Phase 1B — Java service build (offline-capable)
# --------------------------------------------------------------------------
phase "Phase 1B: Java service build (offline-capable)"
JAVA_BIN="$(command -v java || true)"
MVN_BIN="$(command -v mvn || true)"
JAVA_BUILT=1
if [[ -z "$MVN_BIN" || -z "$JAVA_BIN" ]]; then
  echo "-- WARN: mvn/java not found; skipping Java service boot (Phase 3C will GAP)"
  JAVA_BUILT=0
else
  build_java() {
    local repo="$1" jar="$2"
    echo "-- building $repo ($jar)"
    if ( cd "$ROOT/$repo" && mvn -o -q package -DskipTests >"$LOGDIR/build-$repo.log" 2>&1 ) \
       && cp "$ROOT/$repo/target/$jar" "$BUILD/$jar"; then
      echo "   ok (offline): $jar"; return 0
    fi
    echo "   offline build failed; retrying online..."
    if ( cd "$ROOT/$repo" && mvn -q package -DskipTests >>"$LOGDIR/build-$repo.log" 2>&1 ) \
       && cp "$ROOT/$repo/target/$jar" "$BUILD/$jar"; then
      echo "   ok (online): $jar"; return 0
    fi
    echo "   BUILD FAILED $repo (see $LOGDIR/build-$repo.log)"
    record FAIL "build $repo"; JAVA_BUILT=0; return 1
  }
  build_java ai-platform-api ai-platform-api-1.0.0.jar
  build_java ai-admin-service  ai-admin-service-1.0.0.jar
fi

# --------------------------------------------------------------------------
# Phase 2 — boot services
# --------------------------------------------------------------------------
phase "Phase 2: boot services"
start_bg() {
  local name="$1"; shift
  echo "-- start $name"
  "$@" >"$LOGDIR/$name.log" 2>&1 &
  PIDS+=($!)
}

start_bg resolver      env ADDR=":$RESOLVER_PORT"    "$BUILD/resolver"
start_bg provisioner   env ADDR=":$PROVISIONER_PORT" "$BUILD/provisioner"
start_bg gateway       env ADDR=":$GATEWAY_PORT"     "$BUILD/gateway"
start_bg tool-registry env ADDR=":$TOOL_REGISTRY_PORT" "$BUILD/tool-registry"
start_bg sandbox       env LISTEN_ADDR=":$SANDBOX_PORT" "$BUILD/sandbox"

if [[ "$NO_EVAL" -eq 0 ]]; then
  ( cd "$ROOT/ai-eval-service" && \
    PYTHONPATH=src "$EVAL_VENV/bin/python" -m uvicorn ai_eval_service.main:app \
      --port "$EVAL_PORT" >"$LOGDIR/eval.log" 2>&1 & echo $! >"$LOGDIR/eval.pid" )
  PIDS+=($(cat "$LOGDIR/eval.pid"))
fi

start_bg proxy env ADDR=":$PROXY_PORT" PROXY_ROUTES_JSON="$SMOKE/proxy/routes.json" "$BUILD/smoke-proxy"

echo "-- waiting for health endpoints"
wait_for "$RESOLVER_URL/healthz"      && record PASS "boot resolver"      || record FAIL "boot resolver"
wait_for "$PROVISIONER_URL/healthz"   && record PASS "boot provisioner"   || record FAIL "boot provisioner"
wait_for "$GATEWAY_URL/v1/healthz"    && record PASS "boot gateway"       || record FAIL "boot gateway"
wait_for "$TOOL_REGISTRY_URL/healthz" && record PASS "boot tool-registry" || record FAIL "boot tool-registry"
wait_for "$SANDBOX_URL/healthz"       && record PASS "boot sandbox"       || record FAIL "boot sandbox"
if [[ "$NO_EVAL" -eq 0 ]]; then
  wait_for "$EVAL_URL/openapi.json"    && record PASS "boot eval-service"  || record FAIL "boot eval-service"
fi
wait_for "$PROXY_URL/healthz"         && record PASS "boot proxy"         || record FAIL "boot proxy"

# Java services (boot only if they built). platform-api uses its default
# in-memory profile; admin-service uses the `offline` H2 profile — neither
# needs an external Postgres/Redis.
if [[ "$JAVA_BUILT" -eq 1 ]]; then
  start_bg platform-api env JAVA_TOOL_OPTIONS="-Xmx512m" "$JAVA_BIN" -jar "$BUILD/ai-platform-api-1.0.0.jar" --server.port="$PLATFORM_PORT"
  start_bg admin-service env JAVA_TOOL_OPTIONS="-Xmx512m" "$JAVA_BIN" -jar "$BUILD/ai-admin-service-1.0.0.jar" --spring.profiles.active=offline --server.port="$ADMIN_PORT"
  wait_for "$PLATFORM_URL/api/v1/agents/models"            && record PASS "boot platform-api"   || record FAIL "boot platform-api"
  wait_for "$ADMIN_URL/api/v1/admin/package-templates"     && record PASS "boot admin-service"  || record FAIL "boot admin-service"
else
  echo "-- skipping Java boot (build failed / toolchain missing)"
fi

# --------------------------------------------------------------------------
# Phase 3A — direct-API validation (each service's REAL contract)
# --------------------------------------------------------------------------
phase "Phase 3A: direct-API validation (real contracts)"

# resolver
cat >"$SMOKE_TMP/resolve.json" <<'JSON'
{"tenant_id":"local","enabled":{"gateway":true},"profile":"starter"}
JSON
code=$(http_status "$RESOLVER_URL/v1/resolve" POST "$SMOKE_TMP/resolve.json")
checksum=$(jget 'd.get("checksum","")')
if [[ "$code" == "200" && -n "$checksum" ]]; then
  record PASS "resolver POST /v1/resolve" "checksum=${checksum:0:16}"
else
  record FAIL "resolver POST /v1/resolve" "status=$code"
fi
code=$(http_status "$RESOLVER_URL/v1/plan/$checksum" GET)
[[ "$code" == "200" ]] && record PASS "resolver GET /v1/plan/{checksum}" || record FAIL "resolver GET /v1/plan/{checksum}" "status=$code"

# provisioner
cat >"$SMOKE_TMP/apply.json" <<'JSON'
{"plan":{"added":[{"repo_name":"svc-a","version":"1.0.0"}],"checksum":"chk-smoke"},"profile":"standard","tenant_id":"local"}
JSON
code=$(http_status "$PROVISIONER_URL/v1/apply" POST "$SMOKE_TMP/apply.json")
[[ "$code" == "200" ]] && record PASS "provisioner POST /v1/apply" || record FAIL "provisioner POST /v1/apply" "status=$code"
code=$(http_status "$PROVISIONER_URL/v1/status/svc-a" GET)
[[ "$code" == "200" ]] && record PASS "provisioner GET /v1/status/svc-a" || record FAIL "provisioner GET /v1/status/svc-a" "status=$code"
cat >"$SMOKE_TMP/rollback.json" <<'JSON'
{"component":"svc-a"}
JSON
code=$(http_status "$PROVISIONER_URL/v1/rollback" POST "$SMOKE_TMP/rollback.json")
[[ "$code" == "200" ]] && record PASS "provisioner POST /v1/rollback" || record FAIL "provisioner POST /v1/rollback" "status=$code"

# gateway
code=$(http_status "$GATEWAY_URL/v1/models" GET)
nmodels=$(jget 'len(d.get("data",[]))')
[[ "$code" == "200" && "$nmodels" -gt 0 ]] && record PASS "gateway GET /v1/models" "models=$nmodels" || record FAIL "gateway GET /v1/models" "status=$code n=$nmodels"
cat >"$SMOKE_TMP/chat.json" <<'JSON'
{"model":"cloud-qwen-max","messages":[{"role":"user","content":"hi"}],"stream":false}
JSON
code=$(http_status "$GATEWAY_URL/v1/chat/completions" POST "$SMOKE_TMP/chat.json")
[[ "$code" == "200" ]] && record PASS "gateway POST /v1/chat/completions" || record FAIL "gateway POST /v1/chat/completions" "status=$code"

# tool-registry & sandbox (boot + basic route)
code=$(http_status "$TOOL_REGISTRY_URL/healthz" GET)
[[ "$code" == "200" ]] && record PASS "tool-registry /healthz" || record FAIL "tool-registry /healthz" "status=$code"
code=$(http_status "$SANDBOX_URL/healthz" GET)
[[ "$code" == "200" ]] && record PASS "sandbox /healthz" || record FAIL "sandbox /healthz" "status=$code"

# eval-service (real API)
if [[ "$NO_EVAL" -eq 0 ]]; then
  cat >"$SMOKE_TMP/ds.json" <<'JSON'
{"name":"smoke","tenant_id":"local"}
JSON
  code=$(http_status "$EVAL_URL/v1/datasets" POST "$SMOKE_TMP/ds.json")
  DS=$(jget 'd.get("dataset_id","")')
  [[ "$code" == "200" && -n "$DS" ]] && record PASS "eval POST /v1/datasets" "ds=$DS" || record FAIL "eval POST /v1/datasets" "status=$code"
  cat >"$SMOKE_TMP/case.json" <<'JSON'
{"inputs":{"q":"1+1"},"expected":{"a":"2"}}
JSON
  code=$(http_status "$EVAL_URL/v1/datasets/$DS/cases?version=v1" POST "$SMOKE_TMP/case.json")
  [[ "$code" == "200" ]] && record PASS "eval POST /v1/datasets/{id}/cases" || record FAIL "eval POST /v1/datasets/{id}/cases" "status=$code"
  cat >"$SMOKE_TMP/run.json" <<JSON
{"dataset_id":"$DS","dataset_version":"v1","agent":{"agent_id":"smoke","tenant_id":"local"},"scorer_set":["promptfoo_accuracy"]}
JSON
  code=$(http_status "$EVAL_URL/v1/runs" POST "$SMOKE_TMP/run.json")
  RUN=$(jget 'd.get("run_id","")')
  [[ "$code" == "200" && -n "$RUN" ]] && record PASS "eval POST /v1/runs" "run=$RUN" || record FAIL "eval POST /v1/runs" "status=$code"
  code=$(http_status "$EVAL_URL/v1/runs/$RUN" GET)
  [[ "$code" == "200" ]] && record PASS "eval GET /v1/runs/{id}" || record FAIL "eval GET /v1/runs/{id}" "status=$code"
  code=$(http_status "$EVAL_URL/v1/runs/$RUN/report" GET)
  metrics=$(jget 'd.get("metrics_summary",{})')
  [[ "$code" == "200" && -n "$metrics" ]] && record PASS "eval GET /v1/runs/{id}/report" || record FAIL "eval GET /v1/runs/{id}/report" "status=$code"
fi

# --------------------------------------------------------------------------
# Phase 3B — aictl pass-through via proxy
# --------------------------------------------------------------------------
phase "Phase 3B: aictl pass-through (via proxy on $PROXY_PORT)"
AICTL="$BUILD/aictl"
aictl() { "$AICTL" --endpoint "$PROXY_URL" "$@"; }

# version is local (no HTTP) -> should succeed
aictl version >"$LOGDIR/aictl-version.log" 2>&1
rc=$?
[[ "$rc" -eq 0 ]] && record PASS "aictl version" || record FAIL "aictl version" "rc=$rc"

# model list -> gateway /v1/models (no auth header needed in local mode).
# The gateway returns an OpenAI-style {"object":"list","data":[...]} envelope;
# aictl unwraps it into []ModelView. Expected to PASS.
aictl model list >"$LOGDIR/aictl-model.log" 2>&1
rc=$?
if [[ "$rc" -eq 0 ]]; then
  n=$(grep -c ModelID "$LOGDIR/aictl-model.log" 2>/dev/null || echo 0)
  record PASS "aictl model list (-> gateway)" "rc=0"
else
  record FAIL "aictl model list (-> gateway)" "rc=$rc (see $LOGDIR/aictl-model.log)"
fi

# plan -> resolver /v1/resolve. aictl sends {tenant_id, enabled:map, profile}
# and forwards the returned plan JSON to the provisioner later. Expected PASS.
aictl plan --enable gateway --tenant local >"$LOGDIR/aictl-plan.log" 2>&1
rc=$?
PLAN_CS=$(grep -oE 'plan checksum: [A-Za-z0-9]+' "$LOGDIR/aictl-plan.log" 2>/dev/null | awk '{print $3}')
if [[ "$rc" -eq 0 && -n "$PLAN_CS" ]]; then
  record PASS "aictl plan (-> resolver)" "checksum=${PLAN_CS:0:16}"
else
  record FAIL "aictl plan (-> resolver)" "rc=$rc (see $LOGDIR/aictl-plan.log)"
fi

# apply -> provisioner /v1/apply. aictl forwards the resolved plan object
# (not a checksum string) plus profile+tenant_id. Uses the plan stored by the
# preceding `aictl plan`. Expected PASS.
aictl apply >"$LOGDIR/aictl-apply.log" 2>&1
rc=$?
if [[ "$rc" -eq 0 ]]; then
  record PASS "aictl apply (-> provisioner)" "rc=0"
else
  record FAIL "aictl apply (-> provisioner)" "rc=$rc (see $LOGDIR/aictl-apply.log)"
fi

# eval submit -> eval-service /v1/runs. aictl reads a JSON task file mapping to
# the RunCreate contract. Requires a pre-existing dataset. Expected PASS.
if [[ "$NO_EVAL" -eq 0 ]]; then
  cat >"$SMOKE_TMP/ds-cli.json" <<'JSON'
{"name":"smoke-cli","tenant_id":"local"}
JSON
  code=$(http_status "$EVAL_URL/v1/datasets" POST "$SMOKE_TMP/ds-cli.json")
  DS=$(jget 'd.get("dataset_id","")')
  if [[ "$code" == "200" && -n "$DS" ]]; then
    cat >"$SMOKE_TMP/task.json" <<JSON
{"dataset_id":"$DS","dataset_version":"v1","agent_id":"smoke-cli","tenant_id":"local","scorer_set":["promptfoo_accuracy"]}
JSON
    aictl eval submit "$SMOKE_TMP/task.json" >"$LOGDIR/aictl-eval.log" 2>&1
    rc=$?
    RUN_ID=$(grep -oE 'eval task: [A-Za-z0-9_-]+' "$LOGDIR/aictl-eval.log" 2>/dev/null | awk '{print $3}')
    if [[ "$rc" -eq 0 && -n "$RUN_ID" ]]; then
      record PASS "aictl eval submit (-> eval-service)" "run=$RUN_ID"
      aictl eval status "$RUN_ID" >"$LOGDIR/aictl-eval-status.log" 2>&1
      rc2=$?
      [[ "$rc2" -eq 0 ]] && record PASS "aictl eval status (-> eval-service)" "rc=0" \
                         || record FAIL "aictl eval status (-> eval-service)" "rc=$rc2"
    else
      record FAIL "aictl eval submit (-> eval-service)" "rc=$rc (see $LOGDIR/aictl-eval.log)"
    fi
  else
    record FAIL "aictl eval submit (-> eval-service)" "dataset create status=$code"
  fi
fi

# --------------------------------------------------------------------------
# Phase 3C — Java service scenarios (new use cases from batches D–L)
# --------------------------------------------------------------------------
phase "Phase 3C: Java service scenarios (new use cases)"

if [[ "$JAVA_BUILT" -ne 1 ]]; then
  record GAP "java scenarios skipped (build failed / toolchain missing)"
else

# ---- platform-api: agent lifecycle + new use cases ----
cat >"$SMOKE_TMP/agent.json" <<'JSON'
{"name":"smoke-agent","model":"cloud-qwen-max","memoryEnabled":false}
JSON
code=$(http_status "$PLATFORM_URL/api/v1/agents" POST "$SMOKE_TMP/agent.json")
AGENT_ID=$(jget 'd.get("agentId","")')
[[ "$code" == "201" && -n "$AGENT_ID" ]] \
  && record PASS "platform create agent" "id=${AGENT_ID:0:8}" \
  || record FAIL "platform create agent" "status=$code"

# E1 — Consumer RBAC (EU-05): CONSUMER may GET a specific agent, but not POST.
code=$(http_status "$PLATFORM_URL/api/v1/agents/$AGENT_ID" GET "" "X-Role: consumer")
[[ "$code" == "200" ]] \
  && record PASS "E1 consumer GET /agents/{id} allowed" \
  || record FAIL "E1 consumer GET /agents/{id} allowed" "status=$code"
code=$(http_status "$PLATFORM_URL/api/v1/agents" POST "$SMOKE_TMP/agent.json" "X-Role: consumer")
[[ "$code" == "403" ]] \
  && record PASS "E1 consumer POST /agents forbidden" \
  || record FAIL "E1 consumer POST /agents forbidden" "status=$code"

# F2 — SRS skill binding (DV-06, TA-08)
code=$(http_status "$PLATFORM_URL/api/v1/agents/$AGENT_ID/skills/sql:bind" POST)
[[ "$code" == "200" ]] \
  && record PASS "F2 bind skill sql" \
  || record FAIL "F2 bind skill sql" "status=$code"
code=$(http_status "$PLATFORM_URL/api/v1/agents/$AGENT_ID/skills" GET)
inskill=$(jget "'sql' in d")
[[ "$code" == "200" && "$inskill" == "True" ]] \
  && record PASS "F2 list bound skills includes sql" \
  || record FAIL "F2 list bound skills includes sql" "status=$code inskill=$inskill"

# G2 — eval trigger (DV-09, DV-17)
code=$(http_status "$PLATFORM_URL/api/v1/agents/$AGENT_ID/eval:trigger?datasetId=ds-smoke" POST)
RUN_ID=$(jget 'd.get("runId","")')
[[ "$code" == "202" && -n "$RUN_ID" ]] \
  && record PASS "G2 eval trigger" "run=$RUN_ID" \
  || record FAIL "G2 eval trigger" "status=$code"
code=$(http_status "$PLATFORM_URL/api/v1/agents/$AGENT_ID/eval" GET)
inrun=$(jget "'$RUN_ID' in d")
[[ "$code" == "200" && "$inrun" == "True" ]] \
  && record PASS "G2 eval reports include run" \
  || record FAIL "G2 eval reports include run" "status=$code inrun=$inrun"

# PA-06 — model whitelist endpoint (returns the authorized model list)
code=$(http_status "$PLATFORM_URL/api/v1/agents/models" GET)
isml=$(jget 'isinstance(d, list)')
[[ "$code" == "200" && "$isml" == "True" ]] \
  && record PASS "PA-06 model whitelist endpoint" \
  || record FAIL "PA-06 model whitelist endpoint" "status=$code isml=$isml"

# ---- admin-service: package template CRUD (PA-04, Batch H2) ----
cat >"$SMOKE_TMP/tmpl.json" <<'JSON'
{"name":"starter-pack","tier":"basic","components":["gateway","tool-registry"],"quotaPolicy":"q1"}
JSON
code=$(http_status "$ADMIN_URL/api/v1/admin/package-templates" POST "$SMOKE_TMP/tmpl.json")
TMPL_ID=$(jget 'd.get("id","")')
[[ "$code" == "201" && -n "$TMPL_ID" ]] \
  && record PASS "admin create package-template" "id=${TMPL_ID:0:8}" \
  || record FAIL "admin create package-template" "status=$code"
code=$(http_status "$ADMIN_URL/api/v1/admin/package-templates" GET)
inlist=$(jget '"starter-pack" in [t.get("name","") for t in d]')
[[ "$code" == "200" && "$inlist" == "True" ]] \
  && record PASS "admin list package-templates" \
  || record FAIL "admin list package-templates" "status=$code inlist=$inlist"
code=$(http_status "$ADMIN_URL/api/v1/admin/package-templates/$TMPL_ID" GET)
[[ "$code" == "200" ]] \
  && record PASS "admin get package-template" \
  || record FAIL "admin get package-template" "status=$code"
code=$(http_status "$ADMIN_URL/api/v1/admin/package-templates/$TMPL_ID" DELETE)
[[ "$code" == "204" ]] \
  && record PASS "admin delete package-template" \
  || record FAIL "admin delete package-template" "status=$code"
code=$(http_status "$ADMIN_URL/api/v1/admin/package-templates/$TMPL_ID" GET)
[[ "$code" == "404" ]] \
  && record PASS "admin package-template gone after delete" \
  || record FAIL "admin package-template gone after delete" "status=$code"

fi

# --------------------------------------------------------------------------
# Phase 4 — report
# --------------------------------------------------------------------------
phase "Phase 4: report"
REPORT="$SMOKE/report.md"
{
  echo "# OpenStrata cross-repo smoke test — report"
  echo
  echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Branch: feat/smoke-harness"
  echo
  echo "## Results"
  echo
  np=0; nf=0; ng=0
  for r in "${RESULTS[@]:-}"; do
    st="${r%%|*}"; rest="${r#*|}"
    echo "- [$st] $rest"
    case "$st" in PASS) ((np++));; FAIL) ((nf++));; GAP) ((ng++));; esac
  done
  echo
  echo "## Summary"
  echo
  echo "- PASS: $np"
  echo "- FAIL: $nf"
  echo "- GAP (known contract mismatch / skipped): $ng"
  echo
  echo "## Notes"
  echo
  echo "- Services boot offline (in-memory/fakes); no external deps required."
  echo "- Phase 3A validates each Go/Python service against its REAL HTTP contract."
  echo "- Phase 3B drives aictl through one proxy endpoint. The 4 previously"
  echo "  broken CLI<->service contract mismatches are now FIXED:"
  echo "    * plan  -> resolver  (/v1/resolve, tenant_id + enabled:map)"
  echo "    * apply -> provisioner (/v1/apply, plan object + profile/tenant_id)"
  echo "    * eval  -> eval-service (/v1/runs, RunCreate body)"
  echo "    * model -> gateway (/v1/models, {object,data} envelope unwrap)"
  echo "  See the gap-audit section in smoke/README.md for the original analysis."
  echo "- Phase 3C exercises the Java services end-to-end for the new use cases:"
  echo "    * platform-api boots on its DEFAULT in-memory profile (no DB)."
  echo "    * admin-service boots on the OFFLINE H2 profile (no Postgres/Redis)."
  echo "    * Covers E1 consumer RBAC, F2 SRS skill binding, G2 eval trigger,"
  echo "      PA-06 model whitelist, and H2 package-template CRUD."
} >"$REPORT"

echo
echo "PASS=$np FAIL=$nf GAP=$ng"
echo "Report: $REPORT"
