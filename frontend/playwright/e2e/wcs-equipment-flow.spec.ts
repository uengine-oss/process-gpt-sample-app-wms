import { test, expect, type Page } from '@playwright/test'
import { execFileSync } from 'node:child_process'
import { mkdirSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

// End-to-end walk of the WCS equipment-control contract
// (openspec/changes/add-wcs-equipment-control-contract).
//
// The contract has two sides and only one of them is a UI:
//   - Humans (WAREHOUSE_MANAGER / WCS_OPERATOR) register equipment, dispatch
//     commands and resolve faults in the Vue app.
//   - The equipment side (WCS_GATEWAY) is a service identity — a real PLC/WCS
//     bridge or a simulator. Nobody logs into the frontend as it, so those
//     steps are driven off-UI through psql here, which is exactly the call a
//     real gateway would make.
//
// Screenshots taken along the way feed the DOCX operator manual under
// openspec/specs/wms_wcs-equipment-control/docs/.

const DB_CONTAINER = 'supabase_db_process-gpt-sample-app-wms'
const EQUIPMENT_CODE = 'AGV-07'
const SHOT_DIR = resolve(
  dirname(fileURLToPath(import.meta.url)),
  '../../../openspec/specs/wms_wcs-equipment-control/e2e/screenshots',
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

/** Runs a DO block authenticated as the WCS_GATEWAY service identity. */
function asGateway(body: string): string {
  return psql(`
do $do$
declare
  v_actor uuid;
  v_equipment wms.equipment%rowtype;
  v_command wms.equipment_commands%rowtype;
begin
  select id into v_actor from auth.users where email = 'wcs-gateway-a@demo.local';
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_actor::text, 'role', 'authenticated')::text, false);
  select * into v_equipment from wms.equipment where equipment_code = '${EQUIPMENT_CODE}';
  ${body}
end
$do$;`)
}

/** The equipment boots and tells the WMS it is ready for work. */
function gatewayReportsStatus(newStatus: string) {
  asGateway(`
    perform wms.wms_report_equipment_status(
      v_equipment.id, '${newStatus}', v_actor, gen_random_uuid(), v_equipment.version, null, null);`)
}

/** The equipment acknowledges, works, and finishes its outstanding command. */
function gatewayCompletesCommand() {
  asGateway(`
    select * into v_command from wms.equipment_commands
      where equipment_id = v_equipment.id and status in ('PENDING','ACKNOWLEDGED','IN_PROGRESS')
      order by created_at desc limit 1;
    if not found then raise exception 'no in-flight command to complete'; end if;
    perform wms.wms_report_command_result(
      v_command.id, 'ACKNOWLEDGED', v_actor, gen_random_uuid(), v_command.version, null, null);
    perform wms.wms_report_command_result(
      v_command.id, 'IN_PROGRESS', v_actor, gen_random_uuid(), v_command.version + 1, null, null);
    perform wms.wms_report_command_result(
      v_command.id, 'COMPLETED', v_actor, gen_random_uuid(), v_command.version + 2,
      '{"travelled_m": 42}'::jsonb, null);`)
}

/** A sensor trips and the gateway reports a fault. */
function gatewayRaisesFault(faultCode: string, severity: string) {
  asGateway(`
    perform wms.wms_raise_equipment_fault(
      v_equipment.id, '${faultCode}', '${severity}', v_actor, gen_random_uuid(), null);`)
}

function resetDemoEquipment() {
  // Cascades to commands / events / faults, so the run is repeatable without
  // a full `supabase db reset`.
  psql(`delete from wms.equipment where equipment_code = '${EQUIPMENT_CODE}';`)
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

function equipmentRow(page: Page) {
  return page.locator(`tr[data-equipment-code="${EQUIPMENT_CODE}"]`)
}

function monitorCard(page: Page) {
  return page.locator(`.card[data-equipment-code="${EQUIPMENT_CODE}"]`)
}

/** The open-fault banner only — the fault code also shows up inside the
 *  event-feed detail JSON, so plain text matching is ambiguous. */
function faultBanner(page: Page) {
  return monitorCard(page).locator('.fault')
}

// Test 2 asserts on the state test 1 leaves behind, so run them in order and
// skip the rest if an earlier step fails.
test.describe.configure({ mode: 'serial' })

test.beforeAll(() => {
  mkdirSync(SHOT_DIR, { recursive: true })
  resetDemoEquipment()
})

test('register -> dispatch -> gateway completes -> fault -> operator resolves', async ({ page }) => {
  // ---------------------------------------------------------------
  // 1. WAREHOUSE_MANAGER registers a new AGV in the equipment registry.
  // ---------------------------------------------------------------
  await signIn(page, 'wh-manager-a@demo.local')
  await page.goto('/wcs/equipment')
  await expect(page.getByRole('heading', { name: 'WCS Equipment' })).toBeVisible()
  await page.getByLabel('Equipment Code').fill(EQUIPMENT_CODE)
  await page.getByLabel('Type').selectOption('AGV')
  await page.getByLabel('Zone').fill('ZONE-B')
  await shot(page, 'register-form')

  await page.getByRole('button', { name: 'Register Equipment' }).click()
  await expect(equipmentRow(page)).toBeVisible()
  await expect(equipmentRow(page).getByText('OFFLINE')).toBeVisible()
  await shot(page, 'registered-offline')

  // ---------------------------------------------------------------
  // 2. Off-UI: the equipment boots and the gateway reports IDLE.
  // ---------------------------------------------------------------
  gatewayReportsStatus('IDLE')
  await page.reload()
  await expect(equipmentRow(page).getByText('IDLE')).toBeVisible()
  await shot(page, 'online-idle')

  // ---------------------------------------------------------------
  // 3. The manager dispatches a MOVE command from the UI.
  // ---------------------------------------------------------------
  await equipmentRow(page).getByLabel(`to_zone for ${EQUIPMENT_CODE}`).fill('ZONE-C')
  await equipmentRow(page).getByRole('button', { name: 'Dispatch MOVE' }).click()
  await expect(equipmentRow(page).getByText('RUNNING')).toBeVisible()
  await expect(equipmentRow(page).getByText('MOVE / PENDING')).toBeVisible()
  await shot(page, 'command-dispatched')

  // The monitor shows the same thing from the operations side.
  await page.goto('/wcs/monitor')
  await expect(monitorCard(page).getByText('MOVE (PENDING)')).toBeVisible()
  await shot(page, 'monitor-in-flight')

  // ---------------------------------------------------------------
  // 4. Off-UI: the gateway acknowledges, works and completes the command.
  // ---------------------------------------------------------------
  gatewayCompletesCommand()
  await page.reload()
  await expect(monitorCard(page).getByText('COMMAND_COMPLETED')).toBeVisible()
  await expect(monitorCard(page).locator('.status', { hasText: 'IDLE' })).toBeVisible()
  await shot(page, 'monitor-completed')

  // Equipment status derived back to IDLE -> dispatchable again.
  await page.goto('/wcs/equipment')
  await expect(equipmentRow(page).getByText('IDLE')).toBeVisible()
  await expect(equipmentRow(page).getByText('—')).toBeVisible()

  // ---------------------------------------------------------------
  // 5. Fault path: dispatch another command, then the gateway trips.
  // ---------------------------------------------------------------
  await equipmentRow(page).getByLabel(`to_zone for ${EQUIPMENT_CODE}`).fill('ZONE-D')
  await equipmentRow(page).getByRole('button', { name: 'Dispatch MOVE' }).click()
  await expect(equipmentRow(page).getByText('RUNNING')).toBeVisible()

  gatewayRaisesFault('MOTOR_OVERHEAT', 'CRITICAL')

  await page.goto('/wcs/monitor')
  await expect(monitorCard(page).locator('.status.danger', { hasText: 'FAULT' })).toBeVisible()
  await expect(faultBanner(page)).toContainText('MOTOR_OVERHEAT')
  await expect(faultBanner(page)).toContainText('CRITICAL')
  await expect(monitorCard(page).getByText('COMMAND_FAILED')).toBeVisible()
  await shot(page, 'fault-raised')

  // New commands are refused while the equipment is in FAULT.
  await page.goto('/wcs/equipment')
  await expect(equipmentRow(page).getByText('장애 해소 후 가능')).toBeVisible()
  await shot(page, 'dispatch-blocked')
  await signOut(page)

  // ---------------------------------------------------------------
  // 6. A WCS_OPERATOR inspects the machine and resolves the fault.
  // ---------------------------------------------------------------
  await signIn(page, 'wcs-operator-a@demo.local')
  await page.goto('/wcs/monitor')
  await expect(faultBanner(page)).toContainText('MOTOR_OVERHEAT')
  await monitorCard(page)
    .getByLabel(`resolution note for ${EQUIPMENT_CODE}`)
    .fill('과열 센서 교체 및 냉각팬 청소 완료')
  await shot(page, 'operator-resolving')

  await monitorCard(page).getByRole('button', { name: 'Resolve Fault' }).click()
  // the open-fault banner disappears; the fault stays in the event history
  await expect(faultBanner(page)).toHaveCount(0)
  await expect(monitorCard(page).getByText('FAULT_CLEARED')).toBeVisible()
  await expect(monitorCard(page).locator('.status', { hasText: 'IDLE' })).toBeVisible()
  await shot(page, 'fault-resolved')
})

test('WCS_OPERATOR cannot register equipment, and the audit trail is complete', async ({ page }) => {
  // The registry form is admin/manager-only; an operator never sees it.
  await signIn(page, 'wcs-operator-a@demo.local')
  await page.goto('/wcs/equipment')
  await expect(page.getByRole('button', { name: 'Register Equipment' })).toHaveCount(0)
  await shot(page, 'operator-no-register')

  // Every write in the flow above left an audit event.
  const audit = psql(`
    select string_agg(distinct command, ',' order by command)
    from wms.audit_events
    where command like 'wms_%equipment%' or command = 'wms_report_command_result';`)
  expect(audit).toContain('wms_register_equipment')
  expect(audit).toContain('wms_dispatch_equipment_command')
  expect(audit).toContain('wms_report_command_result')
  expect(audit).toContain('wms_report_equipment_status')
  expect(audit).toContain('wms_raise_equipment_fault')
  expect(audit).toContain('wms_resolve_equipment_fault')
})
