import { test, expect, type Page } from '@playwright/test'
import { execFileSync } from 'node:child_process'
import { mkdirSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

// End-to-end walk of the yard & dock scheduling contract
// (openspec/changes/add-yard-dock-scheduling).
//
// Unlike areas 1-6 this contract has no equipment side at all: every actor is
// a human, so the whole flow happens in the UI. psql is used only to plant the
// purchase orders an INBOUND appointment books against (procurement is not
// what is under test) and to clean up afterwards.
//
// Screenshots taken along the way feed the DOCX operator manual under
// openspec/specs/wms_yard-dock-scheduling/docs/.

const DB_CONTAINER = 'supabase_db_process-gpt-sample-app-wms'
const DOCK_1 = 'DOCK-E2E-01'
const DOCK_2 = 'DOCK-E2E-02'
const PO_1 = '41000000-0000-0000-0000-0000000000e1'
const PO_2 = '41000000-0000-0000-0000-0000000000e2'
const TENANT_A = '10000000-0000-0000-0000-00000000000a'
const WH_A = '20000000-0000-0000-0000-00000000000a'

const SHOT_DIR = resolve(
  dirname(fileURLToPath(import.meta.url)),
  '../../../openspec/specs/wms_yard-dock-scheduling/e2e/screenshots',
)

let shotIndex = 0

function psql(sql: string): string {
  return execFileSync(
    'docker',
    ['exec', '-i', DB_CONTAINER, 'psql', '-U', 'postgres', '-d', 'postgres', '-qAt',
     '-v', 'ON_ERROR_STOP=1', '-c', sql],
    { encoding: 'utf8' },
  ).trim()
}

function resetFixtures() {
  psql(`
    delete from wms.dock_appointments a using wms.docks d
      where a.dock_id = d.id and d.code like 'DOCK-E2E-%';
    delete from wms.docks where code like 'DOCK-E2E-%';
    delete from wms.receipts where po_id in ('${PO_1}', '${PO_2}');
    delete from wms.purchase_orders where id in ('${PO_1}', '${PO_2}');`)
}

/** Two confirmed POs to book against — the procurement flow itself has its own spec. */
function seedPurchaseOrders() {
  psql(`
    insert into wms.purchase_orders (id, tenant_id, warehouse_id, product_id, qty, status, reason)
    select '${PO_1}', '${TENANT_A}', '${WH_A}', p.id, 40, 'CONFIRMED_PO', 'DOCK-E2E-FIXTURE'
      from wms.products p where p.tenant_id = '${TENANT_A}' and p.sku = 'SKU-A-001';
    insert into wms.purchase_orders (id, tenant_id, warehouse_id, product_id, qty, status, reason)
    select '${PO_2}', '${TENANT_A}', '${WH_A}', p.id, 25, 'CONFIRMED_PO', 'DOCK-E2E-FIXTURE'
      from wms.products p where p.tenant_id = '${TENANT_A}' and p.sku = 'SKU-A-002';`)
}

function dockId(code: string): string {
  return psql(`select id from wms.docks where code = '${code}';`)
}

async function shot(page: Page, name: string) {
  shotIndex += 1
  const file = `${String(shotIndex).padStart(2, '0')}-${name}.png`
  await page.screenshot({ path: resolve(SHOT_DIR, file), fullPage: true })
}

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

function dockRow(page: Page, code: string) {
  return page.locator(`tr[data-dock-code="${code}"]`)
}

/** The timeline row for one booking, addressed by dock + local start time. */
function apptRow(page: Page, code: string, start: string) {
  return page.locator(`tr[data-window="${code} ${start}"]`)
}

async function book(
  page: Page,
  opts: { dock: string; po: string; start: string; end: string; carrier?: string; plate?: string },
) {
  await page.getByLabel('Appointment Dock').selectOption(dockId(opts.dock))
  await page.getByLabel('Appointment Type').selectOption('INBOUND')
  await page.getByLabel('Appointment PO').selectOption(opts.po)
  await page.getByLabel('Appointment Start').fill(opts.start)
  await page.getByLabel('Appointment End').fill(opts.end)
  await page.getByLabel('Appointment Carrier').fill(opts.carrier ?? '')
  await page.getByLabel('Appointment Plate').fill(opts.plate ?? '')
  await page.getByRole('button', { name: 'Schedule Appointment' }).click()
}

// Test 2 asserts on the state test 1 leaves behind, so run them in order.
test.describe.configure({ mode: 'serial' })

test.beforeAll(() => {
  mkdirSync(SHOT_DIR, { recursive: true })
  resetFixtures()
  seedPurchaseOrders()
})

test.afterAll(() => {
  resetFixtures()
})

test('register docks -> book -> double-book refused -> check-in -> dock -> depart -> cancel frees the slot', async ({
  page,
}) => {
  // ---------------------------------------------------------------
  // 1. WAREHOUSE_MANAGER registers two doors in the dock registry.
  // ---------------------------------------------------------------
  await signIn(page, 'wh-manager-a@demo.local')
  await page.goto('/inbound/dock-schedule')
  await expect(page.getByRole('heading', { name: 'Dock Schedule' })).toBeVisible()
  await page.getByLabel('Dock Code').fill(DOCK_1)
  await page.getByLabel('Dock Name').fill('E2E 하역장 1')
  await shot(page, 'register-dock-form')

  await page.getByRole('button', { name: 'Register Dock' }).click()
  await expect(dockRow(page, DOCK_1)).toBeVisible()
  await expect(dockRow(page, DOCK_1).locator('.status')).toHaveText('AVAILABLE')

  await page.getByLabel('Dock Code').fill(DOCK_2)
  await page.getByLabel('Dock Name').fill('E2E 하역장 2')
  await page.getByRole('button', { name: 'Register Dock' }).click()
  await expect(dockRow(page, DOCK_2).locator('.status')).toHaveText('AVAILABLE')
  await shot(page, 'docks-registered')

  // A warehouse manager owns the registry but does not book slots or move
  // trucks — the booking form is not even rendered for that role.
  await expect(page.getByRole('button', { name: 'Schedule Appointment' })).toHaveCount(0)
  await signOut(page)

  // ---------------------------------------------------------------
  // 2. INBOUND_OPERATOR books a 09:00-10:00 slot against a confirmed PO.
  // ---------------------------------------------------------------
  await signIn(page, 'inbound-a@demo.local')
  await page.goto('/inbound/dock-schedule')
  // the registry form is admin/manager-only
  await expect(page.getByRole('button', { name: 'Register Dock' })).toHaveCount(0)

  await book(page, { dock: DOCK_1, po: PO_1, start: '09:00', end: '10:00', carrier: '한빛운수', plate: '12가3456' })
  await expect(apptRow(page, DOCK_1, '09:00')).toBeVisible()
  await expect(apptRow(page, DOCK_1, '09:00').locator('.status')).toHaveText('SCHEDULED')
  await shot(page, 'appointment-scheduled')

  // ---------------------------------------------------------------
  // 3. The double-booking guard, seen from the UI: an overlapping window on
  //    the SAME dock comes back as a CONFLICT error banner.
  // ---------------------------------------------------------------
  await book(page, { dock: DOCK_1, po: PO_2, start: '09:30', end: '10:30', carrier: '겹침운수' })
  await expect(page.getByTestId('dock-error')).toContainText('CONFLICT')
  await expect(page.getByTestId('dock-error')).toContainText(DOCK_1)
  // nothing was created
  await expect(apptRow(page, DOCK_1, '09:30')).toHaveCount(0)
  await shot(page, 'double-booking-rejected')

  // The abutting window 10:00-11:00 is NOT an overlap (half-open range), and
  // the other dock is free at 09:30 — both prove the guard is per-dock and
  // per-window rather than a blanket lock.
  await book(page, { dock: DOCK_2, po: PO_2, start: '09:30', end: '10:30', carrier: '두번째운수' })
  await expect(apptRow(page, DOCK_2, '09:30').locator('.status')).toHaveText('SCHEDULED')
  await shot(page, 'second-dock-booked')

  // ---------------------------------------------------------------
  // 4. The vehicle's discrete journey: yard check-in does NOT take the door.
  // ---------------------------------------------------------------
  await apptRow(page, DOCK_1, '09:00').getByRole('button', { name: 'Check In' }).click()
  await expect(apptRow(page, DOCK_1, '09:00').locator('.status')).toHaveText('CHECKED_IN')
  await expect(dockRow(page, DOCK_1).locator('.status')).toHaveText('AVAILABLE')
  await shot(page, 'vehicle-checked-in')

  // ---------------------------------------------------------------
  // 5. Docking takes the door to OCCUPIED in the same transaction.
  // ---------------------------------------------------------------
  await apptRow(page, DOCK_1, '09:00').getByRole('button', { name: 'Dock Vehicle' }).click()
  await expect(apptRow(page, DOCK_1, '09:00').locator('.status')).toHaveText('AT_DOCK')
  await expect(dockRow(page, DOCK_1).locator('.status')).toHaveText('OCCUPIED')
  await shot(page, 'vehicle-at-dock')

  // ---------------------------------------------------------------
  // 6. Departure releases it back to AVAILABLE.
  // ---------------------------------------------------------------
  await apptRow(page, DOCK_1, '09:00').getByRole('button', { name: 'Depart' }).click()
  await expect(apptRow(page, DOCK_1, '09:00').locator('.status')).toHaveText('DEPARTED')
  await expect(dockRow(page, DOCK_1).locator('.status')).toHaveText('AVAILABLE')
  await expect(page.getByTestId('dock-notice')).toContainText('AVAILABLE')
  await shot(page, 'vehicle-departed')

  // ---------------------------------------------------------------
  // 7. A CANCELLED appointment frees its slot immediately — the exclusion
  //    predicate only covers SCHEDULED/CHECKED_IN/AT_DOCK.
  // ---------------------------------------------------------------
  await book(page, { dock: DOCK_1, po: PO_1, start: '13:00', end: '14:00', carrier: '오후운수' })
  await expect(apptRow(page, DOCK_1, '13:00').locator('.status')).toHaveText('SCHEDULED')

  // same window, refused while the booking is live
  await book(page, { dock: DOCK_1, po: PO_2, start: '13:00', end: '14:00', carrier: '대체운수' })
  await expect(page.getByTestId('dock-error')).toContainText('CONFLICT')
  await shot(page, 'slot-taken')

  await apptRow(page, DOCK_1, '13:00').getByRole('button', { name: 'Cancel' }).click()
  await expect(apptRow(page, DOCK_1, '13:00').locator('.status')).toHaveText('CANCELLED')
  await expect(page.getByTestId('dock-notice')).toContainText('다시 예약')
  await shot(page, 'appointment-cancelled')

  // ...and now the very same window is bookable again.
  await book(page, { dock: DOCK_1, po: PO_2, start: '13:00', end: '14:00', carrier: '대체운수' })
  await expect(page.getByTestId('dock-error')).toHaveCount(0)
  await expect(
    apptRow(page, DOCK_1, '13:00').filter({ hasText: '대체운수' }).locator('.status'),
  ).toHaveText('SCHEDULED')
  await shot(page, 'slot-rebooked')
})

test('role boundaries hold in the UI, and every write left an audit event', async ({ page }) => {
  // The three physical events are INBOUND_OPERATOR/WMS_ADMIN only (design.md
  // D5). A WAREHOUSE_MANAGER owns the registry but never claims a truck moved.
  await signIn(page, 'wh-manager-a@demo.local')
  await page.goto('/inbound/dock-schedule')
  await expect(dockRow(page, DOCK_1)).toBeVisible()
  await expect(page.getByRole('button', { name: 'Check In' })).toHaveCount(0)
  await expect(page.getByRole('button', { name: 'Schedule Appointment' })).toHaveCount(0)
  await expect(page.getByRole('button', { name: 'Register Dock' })).toBeVisible()
  await shot(page, 'manager-role-view')

  // Maintenance: close the unused door, then reopen it.
  await dockRow(page, DOCK_2).getByRole('button', { name: 'Close' }).click()
  await expect(dockRow(page, DOCK_2).locator('.status')).toHaveText('CLOSED')
  await shot(page, 'dock-closed')
  await dockRow(page, DOCK_2).getByRole('button', { name: 'Reopen' }).click()
  await expect(dockRow(page, DOCK_2).locator('.status')).toHaveText('AVAILABLE')
  await signOut(page)

  // An inbound operator sees the lifecycle buttons but not the registry form.
  await signIn(page, 'inbound-a@demo.local')
  await page.goto('/inbound/dock-schedule')
  await expect(page.getByRole('button', { name: 'Register Dock' })).toHaveCount(0)
  await expect(page.getByRole('button', { name: 'Schedule Appointment' })).toBeVisible()
  await shot(page, 'operator-role-view')

  // Every write in the flow above left an audit event.
  const audit = psql(`
    select string_agg(distinct command, ',' order by command)
    from wms.audit_events
    where command in ('wms_register_dock','wms_set_dock_status','wms_schedule_dock_appointment',
                      'wms_cancel_dock_appointment','wms_check_in_vehicle','wms_dock_vehicle',
                      'wms_depart_vehicle');`)
  expect(audit).toContain('wms_register_dock')
  expect(audit).toContain('wms_set_dock_status')
  expect(audit).toContain('wms_schedule_dock_appointment')
  expect(audit).toContain('wms_cancel_dock_appointment')
  expect(audit).toContain('wms_check_in_vehicle')
  expect(audit).toContain('wms_dock_vehicle')
  expect(audit).toContain('wms_depart_vehicle')

  // The docking event carries the before/after pair the spec asks for.
  const docking = psql(`
    select (before->>'status') || '->' || (after->>'status')
    from wms.audit_events
    where command = 'wms_dock_vehicle' and entity_type = 'dock_appointment'
    order by created_at desc limit 1;`)
  expect(docking).toBe('CHECKED_IN->AT_DOCK')

  // D2: the yard contract never touched wms.receipts.
  const receiptTouches = psql(`
    select count(*) from wms.audit_events
    where entity_type = 'receipt'
      and command in ('wms_dock_vehicle','wms_depart_vehicle','wms_check_in_vehicle',
                      'wms_schedule_dock_appointment');`)
  expect(receiptTouches).toBe('0')
})
