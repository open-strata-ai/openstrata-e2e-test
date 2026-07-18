#!/usr/bin/env bash
# Run all test categories.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
echo "===== OpenStrata E2E Test Suite ====="
echo

PHASES=("smoke" "contract" "scenario" "load")
for phase in "${PHASES[@]}"; do
  echo
  echo "============================================="
  echo "  Phase: $phase"
  echo "============================================="
  if [[ -x "$ROOT/$phase/run.sh" ]]; then
    "$ROOT/$phase/run.sh"
  else
    echo "  SKIP: no run.sh in $phase/"
  fi
done

echo
echo "===== All phases complete ====="
