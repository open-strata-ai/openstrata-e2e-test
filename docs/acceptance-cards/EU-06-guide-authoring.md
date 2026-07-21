# Acceptance Card — EU-06 Guide Authoring

> Source: `design/use-cases-v2.8.md` (EU-06). Frontend: **guide-portal** →
> backend: **ai-guide-service** :8080. Port map: guide-portal proxy → :8080.

## User-visible steps (acceptance criteria)
1. On Home, **"Start with a Chat Agent"** opens the Wizard **on the starter tab**
   (deep-linked, not a default-less wizard).
2. Selecting a **profile tab** (starter/standard/advanced/full) switches the tab
   **and auto-selects that profile's default capability modules**.
3. **"Confirm & apply"** dispatches the apply and shows an applied/ready state.

## Linked tests
- Stage 2 (unit): `ai-guide-portal/src/__tests__/assemblyStore.test.ts`
  - `selecting a profile auto-selects its default modules` — **RED** (gap).
  - `setProfile updates the active profile` — PASS (locks behavior).
- Stage 4 (e2e): `openstrata-e2e-test/e2e/guide.spec.ts`
  - `Start with a Chat Agent lands on the wizard starter tab` — **RED**.
  - `Confirm & apply applies the plan` — **RED**.

## Current status
- **RED.** Root causes: (a) `HomePage` navigates `/wizard` with no tab param;
  (b) `assemblyStore.setProfile` only flips the profile string — no default
  module selection; (c) `ApplyPage` "Confirm & apply" is disabled when no plan
  exists so the click never fires.

## Fix pointers (do NOT implement yet — pending sign-off)
- `src/features/HomePage.tsx`: `navigate('/wizard', { state: { profile: 'starter' } })`
  or `?tab=starter`; `WizardPage` reads it.
- `assemblyStore.setProfile`: apply the profile's default `enabledByDefault`
  capabilities from the catalog.
- `ApplyPage`: allow apply with a synthesized plan id when reached directly.
