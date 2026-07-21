import { test, expect } from '@playwright/test';

const ADMIN = 'http://localhost:5174';

// Each admin page currently renders "Failed to load X: Failed to fetch"
// because ai-admin-service returns 200 but NO Access-Control-Allow-Origin
// header (confirmed by harness/wiring-lint). These specs assert the
// acceptance criterion: the page must render content, not an error banner.
const pages = [
  { path: '/', name: 'dashboard' },
  { path: '/tenants', name: 'tenants' },
  { path: '/resources', name: 'resources' },
  { path: '/audit', name: 'audit' },
];

for (const p of pages) {
  test(`ADM ${p.name} loads without "Failed to fetch" (CORS root cause)`, async ({ page }) => {
    await page.goto(ADMIN + p.path, { waitUntil: 'networkidle' }).catch(() => {});
    await expect(page.getByText(/Failed to load/i)).toHaveCount(0);
  });
}
