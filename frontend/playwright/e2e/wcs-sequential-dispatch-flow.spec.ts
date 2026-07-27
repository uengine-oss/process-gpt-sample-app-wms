import { test, expect, type Page } from '@playwright/test'
import { execFileSync } from 'node:child_process'
import { mkdirSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

// End-to-end walk of the WCS sequential-dispatch contract
// (openspec/changes/add-wcs-sequential-dispatch).
//
// Two parties, one browser:
//   - Humans (WAREHOUSE_MANAGER / WCS_OPERATOR) register outbound units,
//     sequence them into a wave and send the PALLETIZE / WRAP commands from
//     /wcs/sequential-dispatch.
//   - The robot cell itself (WCS_GATEWAY) is a service identity nobody logs in
//     as, so its per-item palletising results are driven off-UI through psql —
//     exactly the call a real WCS/PLC bridge would make.
//
// The one thing this spec exists to show in a browser: ONE command result
// carrying detail.loaded_items fans out to N individual sequence assignments,
// so a single PARTIAL report leaves one row COMPLETED and its neighbour FAILED
// without anybody touching them.
//
// Fixture isolation: every code here is prefixed SEQ-E2E- and lives in its own
// zone, because the other specs in this directory use strict single-match
// locators (getByText('IDLE') etc.) that break if this spec leaves extra
// equipment rows behind. Outbound units and their sequences are namespaced the
// same way and removed in afterAll.
//
// Screenshots taken along the way feed the DOCX operator manual under
// openspec/specs/wms_wcs-sequential-dispatch/docs/.

const DB_CONTAINER = 'supabase_db_process-gpt-sample-app-wms'
const CELL = 'SEQ-E2E-CELL-01'   // the robot cell that builds the pallet
const CELL2 = 'SEQ-E2E-CELL-02'  // a second, idle cell
const AGV = 'SEQ-E2E-AGV-07'     // the wrong equipment type, on purpose
const ZONE = 'ZONE-SEQ-E2E'
const PALLET = 'PLT-SEQ-E2E-1'
const HEAVY_PALLET = 'PLT-SEQ-E2E-2'
const STORE = 'STORE-SEQ-E2E'
const SHOT_DIR = resolve(
  dirname(fileURLToPath(import.meta.url)),
  '../../../openspec/specs/wms_wcs-sequential-dispatch/e2e/screenshots',
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
  v_seq wms.dispatch_sequences%rowtype;
begin
  select id into v_actor from auth.users where email = '${email}';
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_actor::text, 'role', 'authenticated')::text, false);
  ${body}
end
$do$;`)
}

/**
 * Fixture: two idle ROBOT_CELLs and one idle AGV in a private zone. Equipment
 * registration belongs to wms_wcs-equipment-control, so it is set up off-UI
 * rather than clicked through again. Outbound units, the wave and the
 * sequencing are NOT seeded — they are the test.
 */
function seedFixture() {
  cleanupFixture()
  asUser('wh-manager-a@demo.local', `
    perform wms.wms_register_equipment(
      '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-00000000000a',
      '${CELL}', 'ROBOT_CELL', '${ZONE}', v_actor, gen_random_uuid(), 'sequential-e2e');
    perform wms.wms_register_equipment(
      '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-00000000000a',
      '${CELL2}', 'ROBOT_CELL', '${ZONE}', v_actor, gen_random_uuid(), 'sequential-e2e');
    perform wms.wms_register_equipment(
      '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-00000000000a',
      '${AGV}', 'AGV', '${ZONE}', v_actor, gen_random_uuid(), 'sequential-e2e');`)
  asUser('wcs-gateway-a@demo.local', `
    for v_equipment in select * from wms.equipment where zone_code = '${ZONE}' loop
      perform wms.wms_report_equipment_status(
        v_equipment.id, 'IDLE', v_actor, gen_random_uuid(), v_equipment.version, null, 'sequential-e2e');
    end loop;`)
}

/** Puts back what the fixture added, so the other specs still see a clean DB. */
function cleanupFixture() {
  psql(`delete from wms.dispatch_sequences s using wms.outbound_orders o
        where o.id = s.outbound_order_id and o.store_code like '${STORE}%';`)
  psql(`delete from wms.outbound_orders where store_code like '${STORE}%';`)
  psql(`delete from wms.dispatch_waves w
        where w.correlation_id is null
          and not exists (select 1 from wms.work_orders wo where wo.wave_id = w.id)
          and not exists (select 1 from wms.dispatch_sequences s where s.wave_id = w.id)
          and w.created_at > now() - interval '2 hours';`)
  psql(`delete from wms.equipment where zone_code = '${ZONE}'
        or equipment_code in ('${CELL}', '${CELL2}', '${AGV}');`)
}

/**
 * The cell picks up its newest in-flight PALLETIZE command and reports one
 * per-item result set for it. `items` is a raw jsonb array literal so each test
 * can decide exactly which assignment loaded and which was skipped.
 */
function gatewayReportsPalletize(pallet: string, outcome: string, items: string, extraDetail = '') {
  const status = ['SUCCESS', 'PARTIAL'].includes(outcome) ? 'COMPLETED' : 'FAILED'
  return asUser('wcs-gateway-a@demo.local', `
    select * into v_command from wms.equipment_commands
      where command_type = 'PALLETIZE'
        and payload->>'target_pallet_code' = '${pallet}'
        and status in ('PENDING','ACKNOWLEDGED','IN_PROGRESS')
      order by created_at desc limit 1;
    if not found then raise exception 'no in-flight PALLETIZE for ${pallet}'; end if;
    perform wms.wms_report_command_result(
      v_command.id, 'IN_PROGRESS', v_actor, gen_random_uuid(), v_command.version, null, 'sequential-e2e');
    perform wms.wms_report_command_result(
      v_command.id, '${status}', v_actor, gen_random_uuid(), v_command.version + 1,
      '{"outcome": "${outcome}"${extraDetail}, "loaded_items": ${items}}'::jsonb, 'sequential-e2e');`)
}

/** dispatch_sequence_id of the assignment at a given position, for the report. */
function sequenceIdAt(position: number): string {
  return psql(`select s.id from wms.dispatch_sequences s
               join wms.outbound_orders o on o.id = s.outbound_order_id
               where o.store_code like '${STORE}%' and s.sequence_position = ${position}
                 and s.status <> 'CANCELLED';`)
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

/**
 * Scoped to the sequence table on purpose: the manifest tables further down
 * also start each row with a number (the load position), so an unscoped
 * `td:first-child` filter matches two different things.
 */
function sequenceRow(page: Page, position: number) {
  return page
    .getByTestId('sequence-table')
    .locator('tbody tr')
    .filter({ has: page.locator(`td:first-child:text-is("${position}")`) })
}

function palletRow(page: Page, pallet: string) {
  return page.locator(`tr[data-pallet="${pallet}"]`)
}

function manifestCard(page: Page, pallet: string) {
  return page.locator(`.card[data-manifest="${pallet}"]`)
}

/**
 * Playwright's selectOption({label}) only takes exact strings, but every select
 * on this screen renders a composite label (`CODE · status · pallet`). Pick the
 * first option whose text starts with `prefix` and select it by value.
 */
async function selectByPrefix(page: Page, ariaLabel: string, prefix: string) {
  const select = page.getByLabel(ariaLabel)
  const value = await select.locator('option').filter({ hasText: new RegExp(`^${prefix}`) })
    .first().getAttribute('value')
  if (!value) throw new Error(`no <option> starting with "${prefix}" in "${ariaLabel}"`)
  await select.selectOption(value)
}

async function createOutboundOrder(
  page: Page,
  opts: { orderNumber: string; store: string; sku: string; qty: number; weight: number; volume: number },
) {
  await page.getByLabel('order number').fill(opts.orderNumber)
  await page.getByLabel('store code').fill(opts.store)
  await selectByPrefix(page, 'product', opts.sku)
  await page.getByLabel('qty').fill(String(opts.qty))
  await page.getByLabel('declared weight').fill(String(opts.weight))
  await page.getByLabel('declared volume').fill(String(opts.volume))
  await page.getByRole('button', { name: 'Create Outbound Order' }).click()
  // Wait on the form reset, not on the notice: the notice already contains
  // "출고 단위" from the PREVIOUS create, so asserting on it returns
  // immediately and the next fill() races the in-flight RPC's form reset —
  // which silently wipes the order number of the unit being typed.
  await expect(page.getByLabel('order number')).toHaveValue('')
  await expect(page.getByTestId('seq-notice')).toContainText('출고 단위')
}

async function assignSequence(page: Page, orderNumber: string, position: number, pallet: string) {
  await selectByPrefix(page, 'outbound order', orderNumber)
  await page.getByLabel('sequence position').fill(String(position))
  await page.getByLabel('target pallet code').fill(pallet)
  await page.getByRole('button', { name: 'Assign Sequence' }).click()
}

// Test 2 asserts on the state test 1 leaves behind, so run them in order.
test.describe.configure({ mode: 'serial' })

test.beforeAll(() => {
  mkdirSync(SHOT_DIR, { recursive: true })
  seedFixture()
})

test.afterAll(() => {
  cleanupFixture()
})

test('outbound units -> sequencing -> PALLETIZE -> per-item result -> manifest', async ({ page }) => {
  // ---------------------------------------------------------------
  // 1. The screen starts empty: no wave, no outbound unit, no pallet.
  // ---------------------------------------------------------------
  await signIn(page, 'wh-manager-a@demo.local')
  await page.goto('/wcs/sequential-dispatch')
  await expect(page.getByRole('heading', { name: 'WCS Sequential Dispatch' })).toBeVisible()
  await expect(page.getByText('배정된 서열이 없습니다.')).toBeVisible()
  await shot(page, 'empty-board')

  // ---------------------------------------------------------------
  // 2. Open a dispatch wave — sequencing only exists inside one.
  // ---------------------------------------------------------------
  await page.getByRole('button', { name: 'Open Wave' }).click()
  await expect(page.getByTestId('seq-notice')).toContainText('개설 (OPEN)')
  await shot(page, 'wave-opened')

  // ---------------------------------------------------------------
  // 3. Three outbound units: two light ones for PLT-SEQ-E2E-1 and a
  //    240kg monster that will make the weight ceiling bite later.
  // ---------------------------------------------------------------
  await createOutboundOrder(page, {
    orderNumber: 'OB-SEQ-E2E-1', store: `${STORE}-A`, sku: 'SKU-A-001',
    qty: 10, weight: 4.2, volume: 3.1,
  })
  await createOutboundOrder(page, {
    orderNumber: 'OB-SEQ-E2E-2', store: `${STORE}-A`, sku: 'SKU-A-002',
    qty: 4, weight: 6, volume: 5,
  })
  await createOutboundOrder(page, {
    orderNumber: 'OB-SEQ-E2E-3', store: `${STORE}-B`, sku: 'SKU-A-003',
    qty: 2, weight: 240, volume: 10,
  })
  // a spare unit that stays OPEN, so the duplicate-position probe below has
  // something to point at after the first three are sequenced
  await createOutboundOrder(page, {
    orderNumber: 'OB-SEQ-E2E-4', store: `${STORE}-C`, sku: 'SKU-A-001',
    qty: 1, weight: 1, volume: 1,
  })
  await shot(page, 'outbound-orders-created')

  // ---------------------------------------------------------------
  // 4. Sequence them. Position 1 and 2 share a pallet; the heavy one
  //    gets its own. A duplicate position is refused by the DB.
  // ---------------------------------------------------------------
  await assignSequence(page, 'OB-SEQ-E2E-1', 1, PALLET)
  await expect(page.getByTestId('seq-notice')).toContainText('위치 1')
  await assignSequence(page, 'OB-SEQ-E2E-2', 2, PALLET)
  await expect(page.getByTestId('seq-notice')).toContainText('위치 2')
  await assignSequence(page, 'OB-SEQ-E2E-3', 3, HEAVY_PALLET)
  await expect(page.getByTestId('seq-notice')).toContainText('위치 3')
  await expect(palletRow(page, PALLET)).toContainText('10.2 kg')
  await shot(page, 'sequences-assigned')

  // the same position twice in one wave is impossible
  await assignSequence(page, 'OB-SEQ-E2E-4', 1, PALLET)
  await expect(page.locator('.error-banner')).toContainText('is already taken in wave')
  await shot(page, 'duplicate-position-rejected')

  // ---------------------------------------------------------------
  // 5. The weight ceiling is checked at PLANNING time: 240kg declared
  //    against a 100kg pallet limit never reaches the robot cell.
  // ---------------------------------------------------------------
  await selectByPrefix(page, 'robot cell', CELL)
  await page.getByLabel('palletize pallet code').fill(HEAVY_PALLET)
  await page.getByLabel('max weight').fill('100')
  await page.getByRole('button', { name: 'Dispatch PALLETIZE' }).click()
  await expect(page.locator('.error-banner')).toContainText('exceeds max_weight_kg')
  // nothing moved
  await expect(palletRow(page, HEAVY_PALLET)).toContainText('1')
  expect(psql(`select s.status from wms.dispatch_sequences s
               join wms.outbound_orders o on o.id = s.outbound_order_id
               where o.order_number = 'OB-SEQ-E2E-3';`)).toBe('QUEUED')
  await shot(page, 'weight-ceiling-blocks-dispatch')

  // ---------------------------------------------------------------
  // 6. The real dispatch: both PLT-SEQ-E2E-1 assignments ride ONE
  //    PALLETIZE command to one robot cell.
  // ---------------------------------------------------------------
  await page.getByLabel('palletize pallet code').fill(PALLET)
  await page.getByLabel('max weight').fill('250')
  await page.getByLabel('max volume').fill('500')
  await page.getByRole('button', { name: 'Dispatch PALLETIZE' }).click()
  await expect(page.getByTestId('seq-notice')).toContainText('PALLETIZE 명령')
  await expect(page.getByTestId('seq-notice')).toContainText('2건')
  await expect(sequenceRow(page, 1).getByTestId('sequence-status')).toHaveText('DISPATCHED')
  await expect(sequenceRow(page, 2).getByTestId('sequence-status')).toHaveText('DISPATCHED')
  // one command id, two assignments — the N:1 shape this contract exists for
  expect(psql(`select count(distinct s.equipment_command_id) from wms.dispatch_sequences s
               join wms.outbound_orders o on o.id = s.outbound_order_id
               where s.target_pallet_code = '${PALLET}' and o.store_code like '${STORE}%';`)).toBe('1')
  await shot(page, 'palletize-dispatched')

  // the cell is busy with THIS pallet, so a different one is refused
  await page.getByLabel('palletize pallet code').fill(HEAVY_PALLET)
  await page.getByLabel('max weight').fill('300')
  await page.getByRole('button', { name: 'Dispatch PALLETIZE' }).click()
  await expect(page.locator('.error-banner')).toContainText('one cell builds one pallet at a time')
  await shot(page, 'one-cell-one-pallet')

  // ---------------------------------------------------------------
  // 7. Until the cell speaks, the manifest is EMPTY — not an error.
  // ---------------------------------------------------------------
  await page.reload()
  await expect(manifestCard(page, PALLET).getByTestId('manifest-pending')).toBeVisible()
  await expect(manifestCard(page, PALLET)).toContainText('아직 적재 결과가 보고되지 않았습니다')
  await shot(page, 'manifest-before-report')

  // ---------------------------------------------------------------
  // 8. The cell reports PARTIAL off-UI: position 1 loaded, position 2
  //    skipped. One result, two DIFFERENT assignment outcomes.
  // ---------------------------------------------------------------
  const seq1 = sequenceIdAt(1)
  const seq2 = sequenceIdAt(2)
  gatewayReportsPalletize(
    PALLET,
    'PARTIAL',
    `[{"dispatch_sequence_id":"${seq1}","load_position":1,"item_outcome":"LOADED"},
      {"dispatch_sequence_id":"${seq2}","load_position":null,"item_outcome":"SKIPPED","reason":"OVERWEIGHT"}]`,
    ', "total_actual_weight_kg": 4.4, "total_actual_volume_l": 3.0',
  )
  await page.reload()
  await expect(sequenceRow(page, 1).getByTestId('sequence-status')).toHaveText('COMPLETED')
  await expect(sequenceRow(page, 2).getByTestId('sequence-status')).toHaveText('FAILED')
  await expect(sequenceRow(page, 1)).toContainText('PALLETIZE / COMPLETED')
  await expect(palletRow(page, PALLET).getByTestId('pallet-completed')).toHaveText('1')
  await expect(palletRow(page, PALLET).getByTestId('pallet-failed')).toHaveText('1')
  await shot(page, 'per-item-propagation')

  // ...and the outbound units followed their assignments, per item
  expect(psql(`select string_agg(order_number || '=' || status, ',' order by order_number)
               from wms.outbound_orders where order_number in ('OB-SEQ-E2E-1','OB-SEQ-E2E-2');`))
    .toBe('OB-SEQ-E2E-1=COMPLETED,OB-SEQ-E2E-2=FAILED')

  // ---------------------------------------------------------------
  // 9. The manifest now shows what actually landed, position by
  //    position, with declared vs measured weight side by side.
  // ---------------------------------------------------------------
  await expect(manifestCard(page, PALLET).getByTestId('manifest-outcome')).toHaveText('PARTIAL')
  await expect(manifestCard(page, PALLET)).toContainText('선언 10.2kg')
  await expect(manifestCard(page, PALLET)).toContainText('실측 4.4kg')
  await expect(manifestCard(page, PALLET).getByTestId('item-outcome')).toHaveCount(2)
  await expect(manifestCard(page, PALLET).getByTestId('item-outcome').first()).toHaveText('LOADED')
  await expect(manifestCard(page, PALLET).getByTestId('item-outcome').last()).toHaveText('SKIPPED')
  await shot(page, 'pallet-manifest')

  // ---------------------------------------------------------------
  // 10. WRAP is a thin extension: it goes to the same cell through the
  //     generic command envelope and must NOT touch any assignment.
  // ---------------------------------------------------------------
  const completedBefore = psql(`select count(*) from wms.dispatch_sequences where status = 'COMPLETED';`)
  await selectByPrefix(page, 'wrap cell', CELL)
  await page.getByLabel('wrap pallet code').fill(PALLET)
  await page.getByLabel('wrap program').selectOption('HEAVY')
  await page.getByRole('button', { name: 'Dispatch WRAP' }).click()
  await expect(page.getByTestId('seq-notice')).toContainText('WRAP 명령')
  await expect(page.getByTestId('seq-notice')).toContainText('HEAVY')
  expect(psql(`select count(*) from wms.dispatch_sequences where status = 'COMPLETED';`))
    .toBe(completedBefore)
  await shot(page, 'wrap-dispatched')
  await signOut(page)
})

test('operator cancels a dispatched batch, and WMS_ADMIN may plan but not dispatch', async ({ page }) => {
  // ---------------------------------------------------------------
  // 11. A WCS_OPERATOR sequences the heavy unit onto its own pallet and
  //     sends it to the second cell with a ceiling it fits.
  // ---------------------------------------------------------------
  await signIn(page, 'wcs-operator-a@demo.local')
  await page.goto('/wcs/sequential-dispatch')
  // the operator may sequence but not create outbound units
  await expect(page.getByRole('button', { name: 'Create Outbound Order' })).toHaveCount(0)
  await expect(page.getByRole('button', { name: 'Assign Sequence' })).toBeVisible()
  await shot(page, 'operator-cannot-create-orders')

  await selectByPrefix(page, 'robot cell', CELL2)
  await page.getByLabel('palletize pallet code').fill(HEAVY_PALLET)
  await page.getByLabel('max weight').fill('300')
  await page.getByLabel('max volume').fill('500')
  await page.getByRole('button', { name: 'Dispatch PALLETIZE' }).click()
  await expect(page.getByTestId('seq-notice')).toContainText('1건')
  await expect(sequenceRow(page, 3).getByTestId('sequence-status')).toHaveText('DISPATCHED')
  await shot(page, 'heavy-pallet-dispatched')

  // ---------------------------------------------------------------
  // 12. Cancelling a DISPATCHED assignment cancels the PALLETIZE
  //     command it was riding, and returns the unit to OPEN.
  // ---------------------------------------------------------------
  await sequenceRow(page, 3).getByRole('button', { name: 'Cancel sequence 3' }).click()
  await expect(page.getByTestId('seq-notice')).toContainText('연결된 PALLETIZE 명령')
  await expect(sequenceRow(page, 3).getByTestId('sequence-status')).toHaveText('CANCELLED')
  expect(psql(`select c.status from wms.equipment_commands c
               where c.command_type = 'PALLETIZE'
                 and c.payload->>'target_pallet_code' = '${HEAVY_PALLET}'
               order by c.created_at desc limit 1;`)).toBe('CANCELLED')
  // the unit is available again, so it can be re-sequenced
  expect(psql(`select status from wms.outbound_orders where order_number = 'OB-SEQ-E2E-3';`)).toBe('OPEN')
  await shot(page, 'dispatched-sequence-cancelled')
  await signOut(page)

  // ---------------------------------------------------------------
  // 13. The role split this contract inherits from
  //     wms_wcs-equipment-control: WMS_ADMIN may register outbound
  //     units and sequence them, but the shipped dispatch RPC does not
  //     allow WMS_ADMIN, so the command forms are hidden.
  // ---------------------------------------------------------------
  await signIn(page, 'admin-a@demo.local')
  await page.goto('/wcs/sequential-dispatch')
  await expect(page.getByTestId('role-note')).toBeVisible()
  await expect(page.getByRole('button', { name: 'Create Outbound Order' })).toBeVisible()
  await expect(page.getByRole('button', { name: 'Assign Sequence' })).toBeVisible()
  await expect(page.getByRole('button', { name: 'Dispatch PALLETIZE' })).toHaveCount(0)
  await expect(page.getByRole('button', { name: 'Dispatch WRAP' })).toHaveCount(0)
  await shot(page, 'admin-plans-only')

  // the admin re-sequences the freed unit — the write itself is allowed
  await assignSequence(page, 'OB-SEQ-E2E-3', 4, HEAVY_PALLET)
  await expect(page.getByTestId('seq-notice')).toContainText('위치 4')
  await expect(sequenceRow(page, 4).getByTestId('sequence-status')).toHaveText('QUEUED')
  await shot(page, 'admin-resequenced')
  await signOut(page)

  // ---------------------------------------------------------------
  // 14. A role with none of these permissions only reads.
  // ---------------------------------------------------------------
  await signIn(page, 'quality-a@demo.local')
  await page.goto('/wcs/sequential-dispatch')
  await expect(page.getByTestId('pallet-rollup')).toBeVisible()
  await expect(page.getByRole('button', { name: 'Create Outbound Order' })).toHaveCount(0)
  await expect(page.getByRole('button', { name: 'Assign Sequence' })).toHaveCount(0)
  await expect(page.getByRole('button', { name: 'Dispatch PALLETIZE' })).toHaveCount(0)
  await shot(page, 'read-only-role')

  // ---------------------------------------------------------------
  // 15. Every write above left an audit event, including the per-item
  //     propagation nobody clicked.
  // ---------------------------------------------------------------
  const audit = psql(`
    select string_agg(distinct command, ',' order by command)
    from wms.audit_events
    where entity_type in ('outbound_order', 'dispatch_sequence');`)
  expect(audit).toContain('wms_create_outbound_order')
  expect(audit).toContain('wms_assign_dispatch_sequence')
  expect(audit).toContain('wms_cancel_dispatch_sequence')
  expect(audit).toContain('wms_dispatch_palletize_command')
  expect(audit).toContain('wms_propagate_palletize_result')

  // The automatic propagation rows carry the per-item transition. `distinct`
  // keeps this re-runnable: wms.audit_events is append-only and afterAll only
  // removes this spec's own rows from the domain tables, so a second run
  // against the same DB would otherwise see the previous run's rows too.
  expect(psql(`
    select string_agg(distinct (before->>'status') || '->' || (after->>'status'), ',')
    from wms.audit_events
    where command = 'wms_propagate_palletize_result'
      and entity_type = 'dispatch_sequence'
      and correlation_id = 'sequential-e2e';`))
    .toBe('DISPATCHED->COMPLETED,DISPATCHED->FAILED')
})
