import { test, expect, type Page } from '@playwright/test'
import { execFileSync } from 'node:child_process'
import { mkdirSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

// End-to-end walk of the WES/MFS material-flow-control contract
// (openspec/changes/add-wes-material-flow-control).
//
// Three parties are involved and only one of them uses a browser:
//   - The WMS side (WAREHOUSE_MANAGER) opens a dispatch wave, queues work
//     orders into it and releases it, all in the Vue app at /wes/dispatch.
//   - This contract's middleware picks an idle piece of equipment and calls
//     wms_wcs-equipment-control's dispatch RPC for it — no UI, it happens
//     inside the release.
//   - The equipment side (WCS_GATEWAY) is a service identity nobody logs in
//     as, so it is driven off-UI through psql, exactly like a real PLC/WCS
//     bridge would call it. The UI is then re-asserted: the work order must
//     have followed its command to COMPLETED through the propagation trigger.
//
// Screenshots taken along the way feed the DOCX operator manual under
// openspec/specs/wms_wes-material-flow-control/docs/.

const DB_CONTAINER = 'supabase_db_process-gpt-sample-app-wms'
const EQUIPMENT_CODES = ['WES-AGV-01', 'WES-AGV-02']
// A zone of its own, so the two AGVs below are the *only* candidates no matter
// what the psql simulator or the MCP round-trip left registered in ZONE-B.
const ZONE = 'ZONE-WES'
const SHOT_DIR = resolve(
  dirname(fileURLToPath(import.meta.url)),
  '../../../openspec/specs/wms_wes-material-flow-control/e2e/screenshots',
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

/** Wraps a plpgsql body in a DO block authenticated as the given demo user. */
function asUser(email: string, body: string): string {
  return psql(`
do $do$
declare
  v_actor uuid;
  v_equipment wms.equipment%rowtype;
  v_command wms.equipment_commands%rowtype;
begin
  select id into v_actor from auth.users where email = '${email}';
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_actor::text, 'role', 'authenticated')::text, false);
  ${body}
end
$do$;`)
}

/**
 * Fixture: a receipt for the work orders to reference, plus two identical
 * idle AGVs so the flow-balancing rule (design.md D5) has a real choice.
 * Equipment registration and the inbound flow both belong to other specs, so
 * they are set up off-UI here rather than clicked through again.
 */
function seedFixture() {
  psql(`delete from wms.equipment where zone_code = '${ZONE}'
        or equipment_code in (${EQUIPMENT_CODES.map((c) => `'${c}'`).join(',')});`)
  psql(`
do $do$
declare
  v_buyer uuid; v_approver uuid; v_manager uuid; v_gateway uuid;
  v_tenant uuid := '10000000-0000-0000-0000-00000000000a';
  v_wh uuid := '20000000-0000-0000-0000-00000000000a';
  v_po jsonb; v_conf jsonb; v_eq wms.equipment%rowtype; v_code text;
begin
  select id into v_buyer from auth.users where email = 'buyer-a@demo.local';
  select id into v_approver from auth.users where email = 'approver-a@demo.local';
  select id into v_manager from auth.users where email = 'wh-manager-a@demo.local';
  select id into v_gateway from auth.users where email = 'wcs-gateway-a@demo.local';

  -- a receipt, through the real inbound RPCs
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_buyer::text, 'role', 'authenticated')::text, false);
  v_po := wms.wms_create_rfq(v_tenant, v_wh, 'SKU-A-001', 40, null, v_buyer, gen_random_uuid(), 'wes-e2e');
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_approver::text, 'role', 'authenticated')::text, false);
  perform wms.wms_submit_purchase_approval((v_po->>'po_id')::uuid, 'APPROVE', v_approver, 1, null);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_buyer::text, 'role', 'authenticated')::text, false);
  v_conf := wms.wms_confirm_purchase_order((v_po->>'po_id')::uuid, v_buyer, gen_random_uuid(), 2);

  -- two identical AGVs in ${ZONE}
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_manager::text, 'role', 'authenticated')::text, false);
  foreach v_code in array array[${EQUIPMENT_CODES.map((c) => `'${c}'`).join(',')}] loop
    perform wms.wms_register_equipment(v_tenant, v_wh, v_code, 'AGV', '${ZONE}', v_manager, gen_random_uuid(), 'wes-e2e');
  end loop;

  -- gateway boots them so they are dispatchable
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_gateway::text, 'role', 'authenticated')::text, false);
  foreach v_code in array array[${EQUIPMENT_CODES.map((c) => `'${c}'`).join(',')}] loop
    select * into v_eq from wms.equipment where equipment_code = v_code;
    perform wms.wms_report_equipment_status(v_eq.id, 'IDLE', v_gateway, gen_random_uuid(), v_eq.version, null, 'wes-e2e');
  end loop;
end
$do$;`)
}

function resetWesState() {
  psql('truncate wms.work_orders, wms.dispatch_waves restart identity cascade;')
}

/**
 * Puts back what the fixture added: the demo PO/receipt pair and the two
 * AGVs. The other specs in this directory (wms-flow, wcs-equipment-flow) use
 * strict single-match locators like getByText('CONFIRMED_PO'), so leaving an
 * extra purchase order or extra equipment rows behind would break them on the
 * next run. Work orders and waves are kept — beforeAll truncates them anyway.
 */
function cleanupFixture() {
  psql(`delete from wms.purchase_orders where correlation_id = 'wes-e2e';`)
  psql(`delete from wms.equipment where zone_code = '${ZONE}';`)
}

/** The equipment acknowledges, works and finishes a work order's command. */
function gatewayCompletesCommandOf(workOrderId: string) {
  asUser('wcs-gateway-a@demo.local', `
    select c.* into v_command from wms.equipment_commands c
      join wms.work_orders wo on wo.equipment_command_id = c.id
      where wo.id = '${workOrderId}';
    if not found then raise exception 'no command linked to work order %', '${workOrderId}'; end if;
    perform wms.wms_report_command_result(
      v_command.id, 'ACKNOWLEDGED', v_actor, gen_random_uuid(), v_command.version, null, 'wes-e2e');
    perform wms.wms_report_command_result(
      v_command.id, 'IN_PROGRESS', v_actor, gen_random_uuid(), v_command.version + 1, null, 'wes-e2e');
    perform wms.wms_report_command_result(
      v_command.id, 'COMPLETED', v_actor, gen_random_uuid(), v_command.version + 2,
      '{"travelled_m": 31}'::jsonb, 'wes-e2e');`)
}

/** The equipment reports a work order's command as FAILED. */
function gatewayFailsCommandOf(workOrderId: string) {
  asUser('wcs-gateway-a@demo.local', `
    select c.* into v_command from wms.equipment_commands c
      join wms.work_orders wo on wo.equipment_command_id = c.id
      where wo.id = '${workOrderId}';
    if not found then raise exception 'no command linked to work order %', '${workOrderId}'; end if;
    perform wms.wms_report_command_result(
      v_command.id, 'FAILED', v_actor, gen_random_uuid(), v_command.version,
      '{"reason": "OBSTACLE_DETECTED"}'::jsonb, 'wes-e2e');`)
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

/** Work-order rows in creation order (the read model is newest-first). */
function workOrderRows(page: Page) {
  return page.locator('tr[data-work-order]')
}

function rowById(page: Page, workOrderId: string) {
  return page.locator(`tr[data-work-order="${workOrderId}"]`)
}

// Test 2 asserts on the state test 1 leaves behind, so run them in order.
test.describe.configure({ mode: 'serial' })

test.beforeAll(() => {
  mkdirSync(SHOT_DIR, { recursive: true })
  resetWesState()
  seedFixture()
})

test.afterAll(() => {
  cleanupFixture()
})

test('open wave -> queue work orders -> release -> gateway completes -> work order COMPLETED', async ({ page }) => {
  // ---------------------------------------------------------------
  // 1. WAREHOUSE_MANAGER opens a dispatch wave.
  // ---------------------------------------------------------------
  await signIn(page, 'wh-manager-a@demo.local')
  await page.goto('/wes/dispatch')
  await expect(page.getByRole('heading', { name: 'WES Dispatch' })).toBeVisible()
  await shot(page, 'empty-board')

  await page.getByRole('button', { name: 'Open Wave' }).click()
  await expect(page.locator('tr[data-wave-id]')).toHaveCount(1)
  await expect(page.locator('tr[data-wave-id]').getByText('OPEN')).toBeVisible()
  await shot(page, 'wave-opened')

  // ---------------------------------------------------------------
  // 2. Three work orders are queued into the wave. Two AGVs are idle, so
  //    the third must stay QUEUED with a shortage warning at release.
  // ---------------------------------------------------------------
  for (const toZone of ['ZONE-C', 'ZONE-D', 'ZONE-E']) {
    await page.getByLabel('Target Zone').fill(ZONE)
    await page.getByLabel('to_zone').fill(toZone)
    await page.getByRole('button', { name: 'Create Work Order' }).click()
    await expect(page.getByTestId('wes-notice')).toContainText('QUEUED')
  }
  await expect(workOrderRows(page)).toHaveCount(3)
  // nothing is dispatched before the wave is released (spec: "Wave 업무 오더는
  // 큐잉만 되고 즉시 디스패치되지 않는다")
  await expect(page.getByTestId('work-order-status').filter({ hasText: 'QUEUED' })).toHaveCount(3)
  await expect(page.getByTestId('command-summary')).toHaveCount(0)
  await shot(page, 'work-orders-queued')

  // The board is newest-first, so index 2 is the ZONE-C order created first.
  const ids = await workOrderRows(page).evaluateAll((els) =>
    els.map((el) => el.getAttribute('data-work-order') as string),
  )
  const [woE, woD, woC] = ids

  // ---------------------------------------------------------------
  // 3. Release the wave: 2 dispatched, 1 stays QUEUED + warning.
  // ---------------------------------------------------------------
  await page.getByRole('button', { name: /^Release wave/ }).click()
  await expect(page.locator('tr[data-wave-id]').getByText('RELEASED')).toBeVisible()
  await expect(page.getByTestId('wes-notice')).toContainText('NO_EQUIPMENT_AVAILABLE')
  await expect(page.getByTestId('work-order-status').filter({ hasText: 'DISPATCHED' })).toHaveCount(2)
  await expect(page.getByTestId('work-order-status').filter({ hasText: 'QUEUED' })).toHaveCount(1)
  // flow balancing spread the two commands across both idle AGVs rather than
  // stacking them on one (design.md D5)
  await expect(rowById(page, woC).getByTestId('command-summary')).toContainText(EQUIPMENT_CODES[0])
  await expect(rowById(page, woD).getByTestId('command-summary')).toContainText(EQUIPMENT_CODES[1])
  await expect(rowById(page, woE).getByTestId('work-order-status')).toHaveText('QUEUED')
  await shot(page, 'wave-released')

  // ---------------------------------------------------------------
  // 4. Off-UI: the first AGV acknowledges, works and completes its command.
  //    The propagation trigger must carry that into the work order.
  // ---------------------------------------------------------------
  gatewayCompletesCommandOf(woC)
  await page.reload()
  await expect(rowById(page, woC).getByTestId('work-order-status')).toHaveText('COMPLETED')
  await expect(rowById(page, woC).getByTestId('command-summary')).toContainText('COMPLETED')
  await shot(page, 'work-order-completed')

  // ...and the receipt it points at is deliberately untouched (Non-Goal).
  expect(psql('select status from wms.receipts order by created_at desc limit 1;')).toBe('EXPECTED')

  // ---------------------------------------------------------------
  // 5. The freed AGV lets the leftover QUEUED work order be retried.
  // ---------------------------------------------------------------
  await page.getByRole('button', { name: /^Retry/ }).click()
  await expect(page.getByTestId('work-order-status').filter({ hasText: 'QUEUED' })).toHaveCount(0)
  await expect(rowById(page, woE).getByTestId('work-order-status')).toHaveText('DISPATCHED')
  await expect(rowById(page, woE).getByTestId('command-summary')).toContainText(EQUIPMENT_CODES[0])
  await shot(page, 'retry-dispatched')

  // ---------------------------------------------------------------
  // 6. Failure path: the second AGV reports its command FAILED.
  // ---------------------------------------------------------------
  gatewayFailsCommandOf(woD)
  await page.reload()
  await expect(rowById(page, woD).getByTestId('work-order-status')).toHaveText('FAILED')
  await shot(page, 'work-order-failed')

  // ---------------------------------------------------------------
  // 7. Cancelling a DISPATCHED work order cancels its equipment command too.
  // ---------------------------------------------------------------
  await rowById(page, woE).getByRole('button', { name: /^Cancel/ }).click()
  await expect(page.getByTestId('wes-notice')).toContainText('설비 명령')
  await expect(rowById(page, woE).getByTestId('work-order-status')).toHaveText('CANCELLED')
  await expect(rowById(page, woE).getByTestId('command-summary')).toContainText('CANCELLED')
  await shot(page, 'work-order-cancelled')
  await signOut(page)
})

test('WES board is read-only without an operating role, and the audit trail is complete', async ({ page }) => {
  // QUALITY_INSPECTOR holds none of the three WES roles: no forms, no actions.
  await signIn(page, 'quality-a@demo.local')
  await page.goto('/wes/dispatch')
  await expect(page.getByRole('button', { name: 'Open Wave' })).toHaveCount(0)
  await expect(page.getByRole('button', { name: 'Create Work Order' })).toHaveCount(0)
  await expect(workOrderRows(page)).toHaveCount(3)
  await shot(page, 'read-only-role')

  // Every write in the flow above left an audit event, including the
  // automatic propagation of the command result.
  const audit = psql(`
    select string_agg(distinct command, ',' order by command)
    from wms.audit_events
    where entity_type in ('work_order', 'dispatch_wave');`)
  expect(audit).toContain('wms_open_dispatch_wave')
  expect(audit).toContain('wms_create_work_order')
  expect(audit).toContain('wms_release_dispatch_wave')
  expect(audit).toContain('wms_dispatch_work_order')
  expect(audit).toContain('wms_retry_work_order_dispatch')
  expect(audit).toContain('wms_cancel_work_order')
  expect(audit).toContain('wms_propagate_command_result')

  // The propagation rows carry the real before/after transition.
  const propagated = psql(`
    select string_agg(before->>'status' || '->' || (after->>'status'), ',' order by before->>'status' || '->' || (after->>'status'))
    from wms.audit_events where command = 'wms_propagate_command_result';`)
  expect(propagated).toContain('DISPATCHED->COMPLETED')
  expect(propagated).toContain('DISPATCHED->FAILED')
})
