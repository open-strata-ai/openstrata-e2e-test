# Load / Soak Tests

Basic load testing for key service endpoints. Uses simple `curl`-based
concurrency (no external tooling required). For formal benchmarks, wire
in `hey`, `k6`, or `vegeta`.

## Planned tests

| Test | Target | Rate | Duration |
|---|---|---|---|
| `gateway-chat` | POST /v1/chat/completions | 100 req/s | 60s |
| `gateway-models` | GET /v1/models | 500 req/s | 30s |
| `resolver-plan` | POST /v1/resolve | 20 req/s | 30s |
| `eval-runs` | POST /v1/runs + GET /v1/runs/{id} | 10 req/s | 60s |

## Usage

```bash
cd load
./run.sh
```
