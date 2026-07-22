import { test, expect } from '@playwright/test';

const PORTAL = 'http://localhost:5175';

test('DV-01 new Agent form starts empty (no stale agent info)', async ({ page }) => {
  await page.goto(PORTAL + '/agents');
  await page.getByRole('button', { name: /New Agent/i }).click();
  const nameInput = page.getByPlaceholder('Agent name');
  await expect(nameInput).toHaveValue('');
});

test('DV-01 create AgentSpec persists and appears in the Agents list', async ({ page }) => {
  await page.goto(PORTAL + '/agents');
  await page.getByRole('button', { name: /New Agent/i }).click();
  const name = 'E2E-' + Date.now();
  await page.getByPlaceholder('Agent name').fill(name);
  // RC-12: add a state to the state machine before saving — proves the full
  // spec (incl. stateMachine) round-trips through the gateway, not just the name.
  await page.getByPlaceholder('State name').fill('start');
  await page.getByRole('button', { name: /Add state/i }).click();
  await page.getByRole('button', { name: /Create AgentSpec/i }).click();
  await page.goto(PORTAL + '/agents');
  await expect(page.getByText(name)).toBeVisible({ timeout: 10000 });
});

test('MDL models catalog is not blank (seed gap: data:null)', async ({ page }) => {
  await page.goto(PORTAL + '/models');
  await expect(page.getByText(/Failed to load models/i)).toHaveCount(0);
  await expect(page.locator('.ant-card').first()).toBeVisible({ timeout: 10000 });
});
