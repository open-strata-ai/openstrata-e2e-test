# Scenario Tests

Multi-step user-journey scenarios that simulate real product workflows
across multiple services with persistent state.

## Planned scenarios

| Scenario | Steps | Services involved |
|---|---|---|
| `admin-provision-gateway` | Admin creates tenant → provisions gateway model → gateway serves chat | admin-service, provisioning-engine, gateway-core |
| `eval-llm-cycle` | User registers tool → agent runs eval → billing records usage | tool-registry, eval-service, billing-service |
| `sandbox-code-exec` | User acquires sandbox → runs code → checks audit trail | sandbox-manager, dependency-resolver |

## Usage

```bash
cd scenario
./run.sh
```
