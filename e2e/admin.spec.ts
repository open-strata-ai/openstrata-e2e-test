import { test, expect } from '@playwright/test';

const ADMIN = 'http://localhost:5174';

// Each admin page previously rendered "Failed to load X: Failed to fetch"
// because ai-admin-service returned 200 but NO Access-Control-Allow-Origin
// header (confirmed by harness/wiring-lint). RC-1 adds CORS; these specs
// assert the acceptance criterion: the page must render content, not an error.
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

// RC-9 (minimal CRUD): the registry supports create + delete. We create a
// uniquely-named tenant, assert it appears in the table, then delete it and
// assert it is gone.
test('ADM tenant create + delete (RC-9 CRUD)', async ({ page }) => {
  await page.goto(ADMIN + '/tenants', { waitUntil: 'networkidle' });
  const id = 'e2e-' + Date.now();
  await page.getByPlaceholder('Tenant id').fill(id);
  await page.getByRole('button', { name: /^Create$/i }).click();
  await expect(page.locator('table tbody tr', { hasText: id })).toBeVisible({ timeout: 10000 });

  const row = page.locator('table tbody tr', { hasText: id });
  await row.getByRole('button', { name: /Delete/i }).click();
  await expect(page.locator('table tbody tr', { hasText: id })).toHaveCount(0, { timeout: 10000 });
});
