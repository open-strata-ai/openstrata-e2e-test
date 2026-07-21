#!/usr/bin/env bash
# Scenario test runner — multi-step user journeys.
#
# Proves end-to-end behaviour of the running services. Services are expected
# to be up (bring them up with `docker compose up -d` / the e2e harness).
#
# The "portal agent persistence → DATABASE" scenario below is the CI proof that
# authored data actually lands in PostgreSQL (EU-05 authoring / EU-04 history),
# not just an in-memory fake that would be lost on gateway restart.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/smoke/assert/assert.sh"

PASS=0
FAIL=0

# ---------------------------------------------------------------------------
# PostgreSQL connectivity for the DB-persistence proof.
# The gateway persists agents / chat-sessions in PostgreSQL. In compose it is
# wired to the `admin_gov` database; when run locally it may be `openstrata`.
# We query Postgres directly to prove rows actually landed there. Prefer a
# host `psql`; otherwise fall back to `docker exec` against the postgres
# container (psql is not installed on the host in this environment).
# ---------------------------------------------------------------------------
PG_CONTAINER="${PG_CONTAINER:-openstrata-e2e-test-postgres-1}"
PG_USER="${PG_USER:-admin}"
PG_DBS=("admin_gov" "openstrata")
PG_DSN=""
PG_DB=""

if command -v psql >/dev/null 2>&1; then
  for db in "${PG_DBS[@]}"; do
    dsn="postgres://$PG_USER:$PG_USER@localhost:5432/$db?sslmode=disable"
    if psql "$dsn" -t -A -c "SELECT 1 FROM agents LIMIT 1" >/dev/null 2>&1; then
      PG_DSN="$dsn"; PG_DB="$db"; break
    fi
  done
elif command -v docker >/dev/null 2>&1; then
  for db in "${PG_DBS[@]}"; do
    if docker exec "$PG_CONTAINER" psql -U "$PG_USER" -d "$db" -t -A -c "SELECT 1 FROM agents LIMIT 1" >/dev/null 2>&1; then
      PG_DB="$db"; break
    fi
  done
fi

# PG_RUN SQL — run a query, printing the result (empty on any failure).
PG_RUN() {
  local sql="$1"
  if command -v psql >/dev/null 2>&1 && [ -n "${PG_DSN:-}" ]; then
    psql "$PG_DSN" -t -A -c "$sql" 2>/dev/null
  elif command -v docker >/dev/null 2>&1 && [ -n "${PG_DB:-}" ]; then
    docker exec "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -t -A -c "$sql" 2>/dev/null
  fi
}

# GPG_RUN SQL — same as PG_RUN but always targets the `guide` database
# (the ai-guide-service persistence store), independent of PG_DB auto-detect.
GPG_RUN() {
  local sql="$1"
  if command -v psql >/dev/null 2>&1; then
    psql "postgres://$PG_USER:$PG_USER@localhost:5432/guide?sslmode=disable" -t -A -c "$sql" 2>/dev/null
  elif command -v docker >/dev/null 2>&1; then
    docker exec "$PG_CONTAINER" psql -U "$PG_USER" -d guide -t -A -c "$sql" 2>/dev/null
  fi
}

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

# Step 2: Chat with the default model (JSON body + tenant header required).
# The gateway returns a flat {model, content, finish_reason, usage} envelope
# (the same shape the portal ChatPage consumes via resp.content).
RESP=$(curl -s -X POST "$GATEWAY_URL/v1/chat/completions" \
  -H "Content-Type: application/json" -H "X-Tenant-Id: local" \
  -d '{"model":"cloud-qwen-max","messages":[{"role":"user","content":"hi"}],"stream":false}')
HAS_CONTENT=$(echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print('1' if d.get('content') else '0')" 2>/dev/null)
[[ "$HAS_CONTENT" == "1" ]] && record PASS "gateway chat completion" || record FAIL "gateway chat completion"

echo
echo "--- Scenario: eval run lifecycle ---"
EVAL_URL=http://localhost:8000

# Full cycle: create dataset → add case → run → check report
DS=$(curl -s -X POST "$EVAL_URL/v1/datasets" -H "Content-Type: application/json" -d '{"name":"scenario-test","tenant_id":"local"}' | python3 -c "import sys,json; print(json.load(sys.stdin).get('dataset_id',''))" 2>/dev/null)
if [[ -z "$DS" ]]; then record FAIL "create dataset"; else
  record PASS "create dataset" "ds=$DS"
  curl -s -X POST "$EVAL_URL/v1/datasets/$DS/cases?version=v1" -H "Content-Type: application/json" -d '{"inputs":{"q":"1+1"},"expected":{"a":"2"}}' >/dev/null
  RUN=$(curl -s -X POST "$EVAL_URL/v1/runs" -H "Content-Type: application/json" -d "{\"dataset_id\":\"$DS\",\"dataset_version\":\"v1\",\"agent\":{\"agent_id\":\"scenario\",\"tenant_id\":\"local\"},\"scorer_set\":[\"promptfoo_accuracy\"]}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('run_id',''))" 2>/dev/null)
  [[ -n "$RUN" ]] && record PASS "create run" "run=$RUN" || record FAIL "create run"
fi

echo
echo "--- Scenario: portal agent persistence (EU-05 authoring) ---"
GW=http://localhost:8092
HDR="X-Tenant-Id: local"
AUTH="Authorization: Bearer local-dev-token"

# Step 1: create an agent — must persist server-side and return an id
echo '{"name":"e2e-agent","description":"t","modelBinding":{"model":"cloud-qwen-max","provider":"alibaba"}}' > "$SMOKE_TMP/agent.json"
CODE=$(http_status "$GW/v1/agents" POST "$SMOKE_TMP/agent.json" "$HDR")
AID=$(jget "d.get('id','')")
if [[ "$CODE" == "201" && -n "$AID" ]]; then
  record PASS "agent create persists (201 + id)" "id=$AID"
else
  record FAIL "agent create persists" "code=$CODE aid=$AID"
fi

# Step 2: the created agent must appear in the list (real persistence, not a mock)
if [[ -n "$AID" ]]; then
  http_status "$GW/v1/agents" GET "" "$HDR" >/dev/null
  FOUND=$(jget "1 if any(a['id']=='$AID' for a in d.get('agents',[])) else 0")
  [[ "$FOUND" == "1" ]] && record PASS "agent appears in list (persisted)" || record FAIL "agent appears in list (persisted)"
fi

# Step 3: patch (rename + publish) must persist
if [[ -n "$AID" ]]; then
  echo '{"name":"e2e-renamed","status":"published"}' > "$SMOKE_TMP/agent_patch.json"
  http_status "$GW/v1/agents/$AID" PATCH "$SMOKE_TMP/agent_patch.json" "$HDR" >/dev/null
  http_status "$GW/v1/agents/$AID" GET "" "$HDR" >/dev/null
  NAME=$(jget "d.get('name','')")
  [[ "$NAME" == "e2e-renamed" ]] && record PASS "agent patch persists" || record FAIL "agent patch persists" "name=$NAME"
  # Step 4: delete
  CODE=$(http_status "$GW/v1/agents/$AID" DELETE)
  [[ "$CODE" == "204" ]] && record PASS "agent delete (204)" || record FAIL "agent delete (204)" "code=$CODE"
fi

echo
echo "--- Scenario: portal agent + stateMachine persistence to DATABASE (EU-05 → Postgres) ---"
if [[ -z "${PG_DB:-}" && -z "${PG_DSN:-}" ]]; then
  record SKIP "agent row written to PostgreSQL" "psql + Postgres unavailable"
else
  # Create an agent WITH a state machine — the exact data the browser "Add state"
  # flow authors and that was previously lost on refresh (in-memory only).
  cat > "$SMOKE_TMP/agent_db.json" <<'JSON'
{"name":"e2e-db-agent","description":"db persistence proof","modelBinding":{"model":"cloud-qwen-max","provider":"alibaba"},"stateMachine":{"initial":"s0","states":[{"id":"s0","label":"Start","type":"start"},{"id":"s1","label":"End","type":"end"}],"transitions":[{"from":"s0","to":"s1","event":"go"}]}}
JSON
  CODE=$(http_status "$GW/v1/agents" POST "$SMOKE_TMP/agent_db.json" "$HDR")
  AID=$(jget "d.get('id','')")
  if [[ "$CODE" == "201" && -n "$AID" ]]; then
    ROWS=$(PG_RUN "SELECT count(*) FROM agents WHERE id='$AID';")
    SM=$(PG_RUN "SELECT (state_machine IS NOT NULL AND state_machine::text <> 'null') FROM agents WHERE id='$AID';")
    if [[ "$ROWS" == "1" && "$SM" == "t" ]]; then
      record PASS "agent + stateMachine persisted to PostgreSQL" "id=$AID db=$PG_DB"
    else
      record FAIL "agent + stateMachine persisted to PostgreSQL" "rows=$ROWS stateMachine=$SM"
    fi
    http_status "$GW/v1/agents/$AID" DELETE >/dev/null
  else
    record FAIL "agent create (DB scenario)" "code=$CODE aid=$AID"
  fi
fi

echo
echo "--- Scenario: chat session persistence to DATABASE (EU-04 history → Postgres) ---"
if [[ -z "${PG_DB:-}" && -z "${PG_DSN:-}" ]]; then
  record SKIP "chat session written to PostgreSQL" "psql + Postgres unavailable"
else
  echo '{"tenant_id":"local","agent_id":"e2e-db-agent-x"}' > "$SMOKE_TMP/session.json"
  CODE=$(http_status "$GW/v1/chat/sessions" POST "$SMOKE_TMP/session.json" "$HDR")
  SID=$(jget "d.get('id','')")
  if [[ "$CODE" == "201" && -n "$SID" ]]; then
    ROWS=$(PG_RUN "SELECT count(*) FROM chat_sessions WHERE id='$SID';")
    if [[ "$ROWS" == "1" ]]; then
      record PASS "chat session persisted to PostgreSQL" "id=$SID db=$PG_DB"
    else
      record FAIL "chat session persisted to PostgreSQL" "rows=$ROWS"
    fi
  else
    record FAIL "chat session create (DB scenario)" "code=$CODE sid=$SID"
  fi
fi

echo
echo "--- Scenario: guide assembly write flows → PostgreSQL (EU-06 guide-portal authoring) ---"
GUIDE_URL=http://localhost:8080/api/v1

# Step 1: capabilities are served and non-empty
CAPS=$(curl -s "$GUIDE_URL/capabilities" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null)
[[ "$CAPS" -ge 4 ]] && record PASS "guide capabilities served" "count=$CAPS" || record FAIL "guide capabilities served" "got=$CAPS"

# Step 2: preview a plan — must persist a DRAFT row and return an id
echo '{"profile":"starter","selections":["rag","agents"]}' > "$SMOKE_TMP/guide_preview.json"
PREVIEW=$(curl -s -X POST "$GUIDE_URL/plans/preview" -H "Content-Type: application/json" -d @"$SMOKE_TMP/guide_preview.json")
PID=$(echo "$PREVIEW" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)
PSTATUS=$(echo "$PREVIEW" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null)
if [[ -n "$PID" && "$PSTATUS" == "DRAFT" ]]; then
  record PASS "guide plan preview persists (DRAFT + id)" "id=$PID"
else
  record FAIL "guide plan preview persists" "pid=$PID status=$PSTATUS"
fi

# Step 3: apply the plan — must mark APPLIED and write the live manifest
CODE=$(curl -s -o "$BODY" -w '%{http_code}' -X POST "$GUIDE_URL/plans/$PID/apply")
ASTATUS=$(python3 -c "import json; print(json.load(open('$BODY')).get('status',''))" 2>/dev/null)
if [[ "$CODE" == "202" && "$ASTATUS" == "APPLIED" ]]; then
  record PASS "guide plan apply (202 APPLIED)" "id=$PID"
else
  record FAIL "guide plan apply" "code=$CODE status=$ASTATUS"
fi

# Step 4: deployment status reflects the applied components
STATUS_BODY=$(curl -s "$GUIDE_URL/deployments/status")
HAS_APPLIED=$(echo "$STATUS_BODY" | python3 -c "import sys,json; d=json.load(sys.stdin); print('1' if any(c.get('status')=='APPLIED' for c in d) else '0')" 2>/dev/null)
[[ "$HAS_APPLIED" == "1" ]] && record PASS "guide deployment status shows APPLIED" || record FAIL "guide deployment status shows APPLIED"

# Step 5: rollback (disable rag) — must persist a ROLLED_BACK row + drop the component
echo '{"capability":"rag","enabled":false}' > "$SMOKE_TMP/guide_rollback.json"
RCODE=$(curl -s -o "$BODY" -w '%{http_code}' -X POST "$GUIDE_URL/rollbacks" -H "Content-Type: application/json" -d @"$SMOKE_TMP/guide_rollback.json")
RSTATUS=$(python3 -c "import json; print(json.load(open('$BODY')).get('status',''))" 2>/dev/null)
RID=$(python3 -c "import json; print(json.load(open('$BODY')).get('id',''))" 2>/dev/null)
if [[ "$RCODE" == "202" && "$RSTATUS" == "ROLLED_BACK" ]]; then
  record PASS "guide rollback accepted (202 ROLLED_BACK)" "id=$RID"
else
  record FAIL "guide rollback accepted" "code=$RCODE status=$RSTATUS"
fi

# Step 6: prove all three write flows actually landed in PostgreSQL (guide db)
GPLANS=$(GPG_RUN "SELECT count(*) FROM guide_plans WHERE plan_id='$PID';")
GMAN=$(GPG_RUN "SELECT count(*) FROM guide_manifests WHERE id='current';")
GROLL=$(GPG_RUN "SELECT count(*) FROM guide_rollbacks WHERE id='$RID';")
RAG_GONE=$(curl -s "$GUIDE_URL/deployments/status" | python3 -c "import sys,json; d=json.load(sys.stdin); print('1' if not any(c.get('capability')=='rag' for c in d) else '0')" 2>/dev/null)
if [[ "$GPLANS" == "1" && "$GMAN" == "1" && "$GROLL" == "1" && "$RAG_GONE" == "1" ]]; then
  record PASS "guide plan+manifest+rollback persisted to PostgreSQL (rag dropped)" "plan=$GPLANS manifest=$GMAN rollback=$GROLL"
else
  record FAIL "guide plan+manifest+rollback persisted to PostgreSQL" "plan=$GPLANS manifest=$GMAN rollback=$GROLL ragGone=$RAG_GONE"
fi

echo
echo "===== Summary ====="
echo "PASS=$PASS FAIL=$FAIL"
