import { test, expect } from '@playwright/test';

const GUIDE = 'http://localhost:5173';

test.describe('EU-06 guide authoring', () => {
  test('Home "Start with a Chat Agent" lands on the wizard starter tab', async ({ page }) => {
    await page.goto(GUIDE + '/');
    await page.getByRole('button', { name: /Start with a Chat Agent/i }).click();
    await expect(page).toHaveURL(/\/wizard/);
    // ACCEPTANCE: must deep-link to the starter profile tab so the user lands
    // on the right tab, not a default-less wizard.
    await expect(page).toHaveURL(/[?&](tab|profile)=starter/);
  });

  test('Confirm & apply applies the plan (EU-06)', async ({ page }) => {
    await page.goto(GUIDE + '/wizard');
    await page.getByRole('button', { name: /Next: preview plan/i }).click();
    await page.getByRole('button', { name: /Confirm & apply/i }).click();
    await expect(page.getByText(/applied|ready/i).first()).toBeVisible();
  });
});
