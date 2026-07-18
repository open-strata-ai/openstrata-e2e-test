# OpenStrata cross-repo integration smoke test

A small, dependency-light harness that boots the OpenStrata services and
exercises them end-to-end. It runs against the **`feat/codegen-260718`**
branches (the generated implementation was never merged to `main`, so the
`v1.0.0-alpha` tag does not contain runnable code).

## Layout

```
smoke/
  ports.env        port map + endpoint URLs (resolves aictl:8080 vs platform-api:8081)
  proxy/           smoke-proxy (stdlib Go reverse proxy) + routes.json
  assert/assert.sh assertion helpers (http_status / jget / wait_for / record)
  run.sh           orchestrator: build -> boot -> E2E -> teardown -> report.md
  bin/             built binaries (git-ignored)
  logs/            per-service stdout (git-ignored)
  report.md        generated summary
```

## Run

```bash
cd smoke
./run.sh            # full: Go services + Python ai-eval-service
./run.sh --no-eval  # Go-only (faster; skips the venv/pip step)
```

Requires `go` (1.22+), `python3`, `curl`. The first run creates a Python
venv and `pip install`s the eval-service deps (~1 min, one-time).

## How it works

`aictl` assumes a **single** control-plane endpoint (`OPENSTRATA_ENDPOINT`)
and sends every command to it — but resolver / provisioner / gateway /
eval-service are separate servers. `smoke-proxy` (on `:8079`) fans requests
out by path prefix so aictl gets one URL while the services stay distinct.

The test runs in **dual mode**:

- **3A – direct-API**: validates each service against its **real** HTTP
  contract (correct request shapes). These are expected to PASS.
- **3B – aictl pass-through**: drives `aictl` through the proxy. This
  surfaces genuine CLI↔service contract mismatches as **GAP** (expected
  failures), not as harness errors.

## Latest result

```
PASS=27  FAIL=0  GAP=0
```

- All 7 services boot offline (in-memory/fakes): resolver, provisioner,
  gateway, tool-registry, sandbox, eval-service, proxy.
- 3A (direct-API): every service's real contract passes — including the full
  eval-service flow (datasets -> cases -> runs -> report).
- 3B (aictl): all 5 commands pass — the 4 previous CLI↔service contract
  mismatches are now FIXED (see gap-audit section below).

## Resolved contract gaps (findings → fixes)

These were real mismatches between `ai-cli`'s HTTP client and the services it
targets. They are **now fixed** (the CLI conforms to each service's real
contract); this section is kept as the audit trail:

1. **`aictl plan` → resolver `POST /v1/resolve`** — *FIXED*. The CLI now sends
   `{"tenant_id":...,"enabled":{...},"profile":"starter"}` (array→`map[string]bool`,
   `tenant`→`tenant_id`) and forwards the returned plan JSON to the provisioner.

2. **`aictl apply` → provisioner `POST /v1/apply`** — *FIXED*. The CLI now sends
   `{"plan":{<AssemblyPlan>},"profile":...,"tenant_id":...}` (object, not a
   checksum string). The plan is fetched by checksum from the resolver or read
   from local state.

3. **`aictl eval submit` → eval-service `POST /v1/runs`** — *FIXED*. The CLI now
   posts a `RunCreate` body (dataset_id, dataset_version, agent, scorer_set)
   read from a JSON task file, and `eval status`/`eval results` hit
   `/v1/runs/{id}` and `/v1/runs/{id}/report`.

4. **`aictl model list` → gateway `GET /v1/models`** — *FIXED*. The gateway
   returns an OpenAI-style `{"object":"list","data":[...]}` envelope; the CLI
   now unwraps `data` into `[]ModelView`.

### Required enablement patches (applied to `feat/codegen-260718`)

- `ai-provisioning-engine`, `ai-gateway-core`, `ai-tool-registry` hardcoded
  `0.0.0.0:8080`; patched to read `ADDR` (gateway also reads `CONFIG_PATH`)
  so all services can bind distinct ports.
- `ai-cli/cmd/aictl/main.go` (entrypoint, already present untracked) was
  fixed to honor the `--endpoint` flag (previously only `OPENSTRATA_ENDPOINT`
  env was used, so `--endpoint` was silently ignored and every command hit
  the default `:8080`).
- `ai-dependency-resolver` `AssemblyPlan`/`PlannedComponent` JSON tags were
  aligned with the provisioning-engine contract so a resolved plan round-trips
  to `POST /v1/apply` verbatim.
### Recommended follow-up

All 4 known contract gaps are now FIXED. The next step is to merge PR #2
(`feat/codegen-260718`) → `main` and re-cut/`retag` `v1.0.0-alpha` so the
release actually contains runnable code.
