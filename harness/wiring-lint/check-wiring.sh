#!/usr/bin/env bash
# Stage 3 wiring/config lint entrypoint.
# Runs the Python checker that validates each frontend's vite proxy target and
# runtime base URL against the v2.8 port map, then probes the live endpoints.
set -euo pipefail
cd "$(dirname "$0")"
exec python3 check-wiring.py "$@"
