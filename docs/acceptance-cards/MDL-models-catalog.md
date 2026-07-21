# Acceptance Card — MDL Models Catalog

> Frontend: **portal-frontend** → backend: **gateway-core** :8092
> (`/v1/models`). Port map: portal runtime base → :8092 (correct).

## User-visible steps (acceptance criteria)
- The Models page lists available models (cards with name/provider/health),
  not a blank page.

## Linked tests
- Stage 3 (wiring): `harness/wiring-lint/check-wiring.py`
  - **WARN**: `GET /v1/models` → 200 but body `{"object":"list","data":null}`.
- Stage 4 (e2e): `openstrata-e2e-test/e2e/portal.spec.ts`
  - `models catalog is not blank` — **RED**.

## Current status
- **RED.** Root cause (confirmed by wiring-lint): gateway `/v1/models` returns
  `data:null` — the model catalog is not seeded. Known pre-existing seed gap.

## Fix pointers (pending sign-off)
- gateway-core: seed `/v1/models` with at least one self-hosted model (catalog
  seeding) so the page renders content.
