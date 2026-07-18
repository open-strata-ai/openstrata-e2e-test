# OpenStrata E2E Test Harness

System-integration and end-to-end test suite for the
[OpenStrata](https://openstrata.cc) AI platform.

## Layout

```
openstrata-e2e-test/
  smoke/     Integration smoke test — boots all services offline,
             exercises real HTTP contracts, drives the CLI via a
             reverse proxy. (PASS=27  FAIL=0  GAP=0)
  contract/  (future) Cross-service contract conformance tests.
  load/      (future) Load / soak / stress tests.
  scenario/  (future) Multi-step user-journey scenarios.
```

## Prerequisites

- Go 1.22+
- Python 3.12+
- curl
- All 18 OpenStrata code repositories cloned as **siblings** of this repo:

```
~/workspace/
  ai-cli/
  ai-gateway-core/
  ai-dependency-resolver/
  ai-provisioning-engine/
  ai-eval-service/
  ...
  openstrata-e2e-test/     ← you are here
```

## Run the smoke test

```bash
cd smoke
./run.sh               # full (Go + Python eval-service)
./run.sh --no-eval     # Go-only (faster)
```

The `openstrata-e2e-test` repo is part of the
[open-strata-ai](https://github.com/open-strata-ai) GitHub org.
