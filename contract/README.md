# Contract Conformance Tests

Cross-service contract conformance validation — verifies that each service
adheres to its published HTTP contract and that service pairs interoperate
correctly with real database state.

## Structure

```
contract/
  assert/        shared assertion helpers
  run.sh         orchestrator
  plan-apply/    resolver → provisioner round-trip
  gateway-models/ gateway model catalog consistency
  eval-runs/     eval-service run lifecycle
```

## Usage

```bash
# Requires all services running (via docker compose)
cd contract
./run.sh
```
