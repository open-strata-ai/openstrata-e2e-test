#!/usr/bin/env bash
# OpenStrata smoke-test assertion library (sourced by run.sh).
# Provides: record(), http_status(), jget(), wait_for().
set -u

SMOKE_TMP="${SMOKE_TMP:-/tmp/smoke}"
BODY="$SMOKE_TMP/body.json"
mkdir -p "$SMOKE_TMP"

# Collected results: "PASS|name|detail" / "FAIL|name|detail" / "GAP|name|detail"
RESULTS=()

record() {
  local st="$1"; shift
  RESULTS+=("$st|$*")
  printf '  [%s] %s\n' "$st" "$*"
}

# http_status URL [METHOD] [BODY_FILE] [HEADER]
# Performs the request, saves the response body to $BODY, prints the HTTP code.
# HEADER is an optional "Name: value" string (e.g. "X-Role: consumer").
http_status() {
  local url="$1" method="${2:-GET}" body="${3:-}" hdr="${4:-}"
  local args=(-s -o "$BODY" -w '%{http_code}' -X "$method")
  if [ -n "$hdr" ]; then
    args+=(-H "$hdr")
  fi
  if [ -n "$body" ]; then
    args+=(-H 'content-type: application/json' --data @"$body")
  fi
  curl "${args[@]}" "$url"
}

# jget PYEXPR — evaluate PYEXPR against the parsed $BODY (a Python expression
# where `d` is the decoded JSON). Prints the result (empty on error).
jget() {
  python3 - "$1" <<'PY'
import json, sys
try:
    d = json.load(open('/tmp/smoke/body.json'))
    print(eval(sys.argv[1]))
except Exception:
    print('')
PY
}

# wait_for URL — poll until the endpoint responds with a non-000, non-5xx code.
wait_for() {
  local url="$1"
  for _ in $(seq 1 180); do
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' "$url")
    if [ "$code" != "000" ] && [ "${code%??}" -lt 5 ] 2>/dev/null; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}
