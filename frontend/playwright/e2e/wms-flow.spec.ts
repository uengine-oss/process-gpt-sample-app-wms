import { test, expect, type Page } from '@playwright/test'

// End-to-end walk of docs/02-contracts.md's demo slice: shortage -> RFQ ->
// HITL approval -> PO -> receiving -> quality -> putaway/scrap. Each step
// signs in as the role that owns it, matching the RLS/role model in the
// core schema migration — this is also task 10.6's minimal E2E.

async function signIn(page: Page, email: string) {
  await page.goto('/login')
  await page.getByLabel('Email').fill(email)
  await page.getByLabel('Password').fill('Demo1234!')
  await page.getByRole('button', { name: /sign in/i }).click()
  await expect(page).toHaveURL(/overview/)
}

async function signOut(page: Page) {
  await page.getByRole('button', { name: /sign out/i }).click()
  await expect(page).toHaveURL(/login/)
}

test('shortage -> RFQ -> approval -> PO -> receiving -> quality -> putaway', async ({ page }) => {
  // 1. Buyer sees the shortage and creates an RFQ.
  await signIn(page, 'buyer-a@demo.local')
  await page.goto('/replenishment')
  await expect(page.getByText('SKU-A-001')).toBeVisible()
  await page.locator('.card', { hasText: 'SKU-A-001' }).getByRole('button', { name: 'Create RFQ' }).click()
  await expect(page.getByText('부족 재고가 없습니다.')).not.toBeVisible()
  await signOut(page)

  // 2. Approver approves it.
  await signIn(page, 'approver-a@demo.local')
  await page.goto('/procurement/purchase-orders')
  await expect(page.getByText('TO_APPROVE')).toBeVisible()
  await page.getByRole('button', { name: 'Approve' }).first().click()
  await expect(page.getByText('APPROVED')).toBeVisible()
  await signOut(page)

  // 3. Buyer confirms the PO, which opens a receipt.
  await signIn(page, 'buyer-a@demo.local')
  await page.goto('/procurement/purchase-orders')
  await page.getByRole('button', { name: 'Confirm PO' }).first().click()
  await expect(page.getByText('CONFIRMED_PO')).toBeVisible()
  await signOut(page)

  // 4. Inbound operator registers arrival then receives the goods.
  await signIn(page, 'inbound-a@demo.local')
  await page.goto('/inbound/receipts')
  await page.getByRole('button', { name: 'Register Arrival' }).first().click()
  await expect(page.getByText('ARRIVED')).toBeVisible()
  await page.getByRole('button', { name: 'Receive' }).first().click()
  await expect(page.getByText('QC_PENDING')).toBeVisible()
  await signOut(page)

  // 5. Quality inspector passes the receipt.
  await signIn(page, 'quality-a@demo.local')
  await page.goto('/quality/inspections')
  await page.getByRole('button', { name: 'Pass' }).first().click()
  await expect(page.getByText('PUTAWAY_PENDING')).toBeVisible()
  await signOut(page)

  // 6. Inbound operator completes putaway -> stock becomes AVAILABLE.
  await signIn(page, 'inbound-a@demo.local')
  await page.goto('/quality/inspections')
  await page.getByRole('button', { name: /Putaway/ }).first().click()
  await page.goto('/overview')
  await expect(page.getByText('OK').first()).toBeVisible()
})
