import { defineConfig } from '@playwright/test';

// Stage 4 — E2E UI acceptance against the REAL running stack.
// The three dev servers are started separately (see SOP v1, Stage 4):
//   guide-portal   http://localhost:5173  -> guide-service   :8080
//   admin-frontend http://localhost:5174  -> admin-service   :8088
//   portal-frontend http://localhost:5175 -> gateway-core    :8092
// We do NOT launch webServer here so the tests run against the dev servers the
// developer already has up (and so failures reflect real wiring, not a fresh
// isolated instance).
export default defineConfig({
  testDir: './e2e',
  timeout: 30000,
  expect: { timeout: 10000 },
  retries: 0,
  use: {
    headless: true,
    trace: 'on-first-retry',
  },
  reporter: [['list']],
});
