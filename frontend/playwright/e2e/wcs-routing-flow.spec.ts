import { test, expect, type Page } from '@playwright/test'
import { execFileSync } from 'node:child_process'
import { mkdirSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

// End-to-end walk of the WCS bottleneck-routing contract
// (openspec/changes/add-wcs-bottleneck-routing).
//
// The whole point of this contract is that it changes a decision nobody can
// see directly — which machine area 2 hands the next work order to. So this
// spec always pairs the *observation* (the /wcs/routing board) with the
// *consequence* (a real work order created on /wes/dispatch landing somewhere
// else). Asserting only on the board would prove nothing.
//
// Three parties, one browser:
//   - Humans (WAREHOUSE_MANAGER / WCS_OPERATOR) read the routing board, tune
//     thresholds and force-exclude machines at /wcs/routing.
//   - WMS orchestration queues work orders at /wes/dispatch; the candidate
//     selection happens inside the DB and is never clicked.
//   - The equipment side (WCS_GATEWAY) is a service identity nobody logs in
//     as, so the faults that make a machine "flaky" are raised off-UI through
//     psql — exactly what a real PLC/WCS bridge would do.
//
// Fixture isolation: every code here is prefixed ROUTE-E2E- and lives in
// ZONE-ROUTE-E2E, because the other specs in this directory use strict
// single-match locators (getByText('IDLE') etc.) that break if this spec
// leaves extra equipment rows behind. afterAll deletes the zone.
//
// Screenshots taken along the way feed the DOCX operator manual under
// openspec/specs/wms_wcs-bottleneck-routing/docs/.

const DB_CONTAINER = 'supabase_db_process-gpt-sample-app-wms'
const CLEAN = 'ROUTE-E2E-01'    // nothing wrong with it
const FLAKY = 'ROUTE-E2E-02'    // two recent faults -> bottleneck flag
const SPARE = 'ROUTE-E2E-03'    // held back, then force-excluded
const ZONE = 'ZONE-ROUTE-E2E'
const CORR = 'routing-e2e'
const SHOT_DIR = resolve(
  dirname(fileURLToPath(import.meta.url)),
  '../../../openspec/specs/wms_wcs-bottleneck-routing/e2e/screenshots',
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
  v_fault uuid;
  v_code text;
begin
  select id into v_actor from auth.users where email = '${email}';
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_actor::text, 'role', 'authenticated')::text, false);
  ${body}
end
$do$;`)
}

/**
 * Fixture: a receipt for the work orders to hang off, and three identical idle
 * AGVs in a private zone. Equipment registration and the inbound flow belong
 * to other specs, so they are set up off-UI rather than clicked through again.
 * No faults and no exclusions yet — those are the steps of the test.
 */
function seedFixture() {
  psql(`delete from wms.equipment where zone_code = '${ZONE}'
        or equipment_code in ('${CLEAN}', '${FLAKY}', '${SPARE}');`)
  psql(`
do $do$
declare
  v_buyer uuid; v_approver uuid; v_manager uuid; v_gateway uuid;
  v_tenant uuid := '10000000-0000-0000-0000-00000000000a';
  v_wh uuid := '20000000-0000-0000-0000-00000000000a';
  v_po jsonb; v_eq wms.equipment%rowtype; v_code text;
begin
  select id into v_buyer from auth.users where email = 'buyer-a@demo.local';
  select id into v_approver from auth.users where email = 'approver-a@demo.local';
  select id into v_manager from auth.users where email = 'wh-manager-a@demo.local';
  select id into v_gateway from auth.users where email = 'wcs-gateway-a@demo.local';

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_buyer::text, 'role', 'authenticated')::text, false);
  v_po := wms.wms_create_rfq(v_tenant, v_wh, 'SKU-A-001', 30, null, v_buyer, gen_random_uuid(), '${CORR}');
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_approver::text, 'role', 'authenticated')::text, false);
  perform wms.wms_submit_purchase_approval((v_po->>'po_id')::uuid, 'APPROVE', v_approver, 1, null);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_buyer::text, 'role', 'authenticated')::text, false);
  perform wms.wms_confirm_purchase_order((v_po->>'po_id')::uuid, v_buyer, gen_random_uuid(), 2);

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_manager::text, 'role', 'authenticated')::text, false);
  foreach v_code in array array['${CLEAN}', '${FLAKY}', '${SPARE}'] loop
    perform wms.wms_register_equipment(v_tenant, v_wh, v_code, 'AGV', '${ZONE}',
      v_manager, gen_random_uuid(), '${CORR}');
  end loop;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_gateway::text, 'role', 'authenticated')::text, false);
  foreach v_code in array array['${CLEAN}', '${FLAKY}', '${SPARE}'] loop
    select * into v_eq from wms.equipment where equipment_code = v_code;
    perform wms.wms_report_equipment_status(v_eq.id, 'IDLE', v_gateway, gen_random_uuid(),
      v_eq.version, null, '${CORR}');
  end loop;
end
$do$;`)
}

function resetWesState() {
  psql('truncate wms.work_orders, wms.dispatch_waves restart identity cascade;')
  psql(`delete from wms.wcs_routing_policies
        where warehouse_id = '20000000-0000-0000-0000-00000000000a';`)
}

/**
 * Puts back what the fixture added. wms-flow / wcs-equipment-flow /
 * wes-dispatch-flow all use strict single-match locators, so an extra purchase
 * order or extra equipment row would break them on the next run.
 */
function cleanupFixture() {
  psql(`delete from wms.purchase_orders where correlation_id = '${CORR}';`)
  psql(`delete from wms.equipment where zone_code = '${ZONE}';`)
  psql(`delete from wms.wcs_routing_policies
        where warehouse_id = '20000000-0000-0000-0000-00000000000a';`)
}

/**
 * The equipment side reports a fault and an operator clears it again. Net
 * effect: the machine is IDLE and command-free (a perfectly legal candidate)
 * but its fault history inside the 30-minute window has grown by one.
 */
function faultCycle(equipmentCode: string, faultCode: string) {
  asUser('wcs-gateway-a@demo.local', `
    select * into v_equipment from wms.equipment where equipment_code = '${equipmentCode}';
    perform wms.wms_raise_equipment_fault(
      v_equipment.id, '${faultCode}', 'WARNING', v_actor, gen_random_uuid(), '${CORR}');`)
  asUser('wcs-operator-a@demo.local', `
    select f.id into v_fault from wms.equipment_faults f
      join wms.equipment e on e.id = f.equipment_id
      where e.equipment_code = '${equipmentCode}' and f.status = 'OPEN'
      order by f.created_at desc limit 1;
    perform wms.wms_resolve_equipment_fault(
      v_fault, '현장 확인 후 재기동', v_actor, gen_random_uuid(),
      (select version from wms.equipment_faults where id = v_fault), '${CORR}');`)
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

function card(page: Page, code: string) {
  return page.locator(`.card[data-equipment-code="${code}"]`)
}

/** The two warehouse-wide counters in the header badge. */
async function summaryCounts(page: Page): Promise<{ bottleneck: number; excluded: number }> {
  const text = await page.getByTestId('routing-summary').innerText()
  return {
    bottleneck: Number(/병목\s*(\d+)대/.exec(text)![1]),
    excluded: Number(/강제 제외\s*(\d+)대/.exec(text)![1]),
  }
}

/** Queues one WAVELESS work order for this zone through the real WES screen. */
async function createWorkOrder(page: Page, toZone: string) {
  await page.goto('/wes/dispatch')
  await page.getByLabel('Equipment Type').selectOption('AGV')
  await page.getByLabel('Target Zone').fill(ZONE)
  await page.getByLabel('to_zone').fill(toZone)
  // WAVELESS: the candidate selection this contract hooks into runs inside the
  // same transaction, so the routing decision is visible immediately.
  await page.getByLabel('Dispatch Mode').selectOption('WAVELESS')
  await page.getByRole('button', { name: 'Create Work Order' }).click()
  await expect(page.getByTestId('wes-notice')).toBeVisible()
}

/** Which machine the newest work order actually went to (or '' if none). */
function newestWorkOrderEquipment(): string {
  return psql(`
    select coalesce(e.equipment_code, '')
    from wms.work_orders wo
    left join wms.equipment_commands c on c.id = wo.equipment_command_id
    left join wms.equipment e on e.id = c.equipment_id
    order by wo.created_at desc limit 1;`)
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

test('flaky machine is avoided, force-excluded machine is never used, fallback still works', async ({ page }) => {
  // ---------------------------------------------------------------
  // 1. A clean board: three identical AGVs, no bottleneck, no exclusion.
  // ---------------------------------------------------------------
  await signIn(page, 'wh-manager-a@demo.local')
  await page.goto('/wcs/routing')
  await expect(page.getByRole('heading', { name: 'WCS Routing' })).toBeVisible()
  for (const code of [CLEAN, FLAKY, SPARE]) {
    await expect(card(page, code).getByTestId('bottleneck-badge')).toHaveCount(0)
    await expect(card(page, code).getByTestId('routable-badge')).toHaveText('배정 가능')
  }
  // The summary badges count the WHOLE warehouse, and the specs that run
  // before this one leave their own faulted equipment behind — so take a
  // baseline and assert on the delta this spec causes rather than on 0.
  const baseline = await summaryCounts(page)
  await shot(page, 'clean-board')

  // ---------------------------------------------------------------
  // 2. Off-UI: ROUTE-E2E-02 breaks down twice and is repaired twice.
  //    It ends up IDLE again — but "unstable lately".
  // ---------------------------------------------------------------
  faultCycle(FLAKY, 'ROUTE_E2E_DRIFT_1')
  faultCycle(FLAKY, 'ROUTE_E2E_DRIFT_2')
  await page.reload()

  // the default fault threshold is 1, so a single fault would already flag it;
  // the board shows both the count and the threshold it was compared against.
  await expect(card(page, FLAKY).getByTestId('bottleneck-badge')).toBeVisible()
  await expect(card(page, FLAKY).getByTestId('bottleneck-reasons'))
    .toContainText('FAULT_FREQUENCY_EXCEEDED')
  await expect(card(page, FLAKY).getByTestId('signals')).toContainText('최근 장애')
  await expect(card(page, CLEAN).getByTestId('bottleneck-badge')).toHaveCount(0)
  // a bottleneck flag lowers preference, it does not forbid: still routable
  await expect(card(page, FLAKY).getByTestId('routable-badge')).toHaveText('배정 가능')
  expect(await summaryCounts(page)).toEqual({
    bottleneck: baseline.bottleneck + 1,
    excluded: baseline.excluded,
  })
  await shot(page, 'bottleneck-detected')

  // ---------------------------------------------------------------
  // 3. Tune the threshold so the flag is explainable, not magic: with
  //    fault_count_threshold = 3 the same two faults are no longer enough.
  // ---------------------------------------------------------------
  await page.getByLabel('new policy equipment type').selectOption('AGV')
  await page.getByLabel('new queue threshold').fill('3')
  await page.getByLabel('new fault threshold').fill('3')
  await page.getByRole('button', { name: 'Register Policy' }).click()
  await expect(page.getByTestId('routing-notice')).toContainText('임계값 정책 등록 완료')
  await expect(card(page, FLAKY).getByTestId('bottleneck-badge')).toHaveCount(0)
  await shot(page, 'policy-raises-threshold')

  // ...and back down to 2, which the two faults do reach.
  await page.getByLabel('fault threshold for AGV').fill('2')
  await page.getByRole('button', { name: 'Save Policy' }).click()
  await expect(page.getByTestId('routing-notice')).toContainText('임계값 저장 완료')
  await expect(card(page, FLAKY).getByTestId('bottleneck-badge')).toBeVisible()
  await shot(page, 'policy-restored')

  // ---------------------------------------------------------------
  // 4. Hold ROUTE-E2E-03 back with a manual exclusion, so the next work
  //    order has exactly one clean and one flaky candidate.
  // ---------------------------------------------------------------
  await card(page, SPARE).getByLabel(`exclusion reason for ${SPARE}`).fill('계획 정비 (배터리 교체)')
  await card(page, SPARE).getByRole('button', { name: 'Exclude from Routing' }).click()
  await expect(page.getByTestId('routing-notice')).toContainText('라우팅 제외됨')
  await expect(card(page, SPARE).getByTestId('excluded-badge')).toBeVisible()
  await expect(card(page, SPARE).getByTestId('routable-badge')).toHaveText('배정 불가')
  await expect(card(page, SPARE).getByTestId('exclusion-box')).toContainText('계획 정비 (배터리 교체)')
  // only the exclusion counter is asserted here: the AGV policy registered in
  // step 3 also applies to any other AGV in this warehouse, so the
  // warehouse-wide bottleneck count is no longer a stable baseline + 1.
  expect((await summaryCounts(page)).excluded).toBe(baseline.excluded + 1)
  await shot(page, 'manual-exclusion')

  // ---------------------------------------------------------------
  // 5. THE POINT: a real work order, created through area 2's own screen,
  //    goes to the clean machine — not the flaky one.
  // ---------------------------------------------------------------
  await createWorkOrder(page, 'ZONE-C')
  await expect(page.getByTestId('work-order-status').first()).toHaveText('DISPATCHED')
  expect(newestWorkOrderEquipment()).toBe(CLEAN)
  await expect(page.getByTestId('command-summary').first()).toContainText(CLEAN)
  await shot(page, 'work-order-avoids-bottleneck')

  // ---------------------------------------------------------------
  // 6. The clean machine is busy now. The flaky one is all that is left,
  //    and a flag is not a veto — so it IS used. Better a slow machine
  //    than a work order that waits forever.
  // ---------------------------------------------------------------
  await createWorkOrder(page, 'ZONE-D')
  await expect(page.getByTestId('work-order-status').first()).toHaveText('DISPATCHED')
  expect(newestWorkOrderEquipment()).toBe(FLAKY)
  await shot(page, 'fallback-to-bottleneck')

  // ---------------------------------------------------------------
  // 7. Now only the force-excluded machine is idle. That IS a veto: the
  //    work order stays QUEUED with a shortage warning, and no command is
  //    ever written for ROUTE-E2E-03.
  // ---------------------------------------------------------------
  await createWorkOrder(page, 'ZONE-E')
  await expect(page.getByTestId('wes-notice')).toContainText('NO_EQUIPMENT_AVAILABLE')
  await expect(page.getByTestId('work-order-status').first()).toHaveText('QUEUED')
  expect(newestWorkOrderEquipment()).toBe('')
  expect(psql(`select count(*) from wms.equipment_commands c
               join wms.equipment e on e.id = c.equipment_id
               where e.equipment_code = '${SPARE}';`)).toBe('0')
  await shot(page, 'excluded-machine-never-used')

  // ---------------------------------------------------------------
  // 8. Clearing the exclusion puts it straight back in the pool — no
  //    recalculation batch, the verdict is computed per query.
  // ---------------------------------------------------------------
  await page.goto('/wcs/routing')
  await card(page, SPARE).getByRole('button', { name: 'Clear Exclusion' }).click()
  await expect(page.getByTestId('routing-notice')).toContainText('제외 해제됨')
  await expect(card(page, SPARE).getByTestId('excluded-badge')).toHaveCount(0)
  await expect(card(page, SPARE).getByTestId('routable-badge')).toHaveText('배정 가능')
  await shot(page, 'exclusion-cleared')

  await page.goto('/wes/dispatch')
  await page.getByRole('button', { name: /^Retry/ }).click()
  await expect(page.getByTestId('work-order-status').first()).toHaveText('DISPATCHED')
  expect(newestWorkOrderEquipment()).toBe(SPARE)
  await shot(page, 'retry-uses-recovered-machine')

  // The exclusion record is kept, not deleted — who lifted it and when.
  expect(psql(`select o.status || '/' || (o.cleared_by is not null)::text
               from wms.wcs_routing_overrides o
               join wms.equipment e on e.id = o.equipment_id
               where e.equipment_code = '${SPARE}';`)).toBe('CLEARED/true')
  await signOut(page)
})

test('roles are split between threshold tuning and exclusion, and the audit trail is complete', async ({ page }) => {
  // WCS_OPERATOR: may take a machine out of service, may not tune thresholds.
  await signIn(page, 'wcs-operator-a@demo.local')
  await page.goto('/wcs/routing')
  await expect(page.getByTestId('role-note')).toBeVisible()
  await expect(page.getByRole('button', { name: 'Register Policy' })).toHaveCount(0)
  await expect(page.getByRole('button', { name: 'Save Policy' })).toHaveCount(0)
  await expect(card(page, CLEAN).getByRole('button', { name: 'Exclude from Routing' })).toBeVisible()
  await shot(page, 'operator-exclusion-only')

  await card(page, CLEAN).getByLabel(`exclusion reason for ${CLEAN}`).fill('구동륜 소음 점검')
  await card(page, CLEAN).getByRole('button', { name: 'Exclude from Routing' }).click()
  await expect(card(page, CLEAN).getByTestId('excluded-badge')).toBeVisible()
  // that machine still has an in-flight command, so the contract says so
  // instead of pretending the exclusion stopped it
  await expect(page.getByTestId('routing-notice')).toContainText('IN_FLIGHT_COMMANDS_NOT_CANCELLED')
  await shot(page, 'exclusion-warns-in-flight')
  await signOut(page)

  // A role with neither permission only reads.
  await signIn(page, 'quality-a@demo.local')
  await page.goto('/wcs/routing')
  await expect(card(page, CLEAN).getByTestId('signals')).toBeVisible()
  await expect(page.getByRole('button', { name: 'Register Policy' })).toHaveCount(0)
  await expect(page.getByRole('button', { name: 'Exclude from Routing' })).toHaveCount(0)
  await expect(page.getByRole('button', { name: 'Clear Exclusion' })).toHaveCount(0)
  await shot(page, 'read-only-role')

  // Every write in the flow above left an audit event.
  const audit = psql(`
    select string_agg(distinct command, ',' order by command)
    from wms.audit_events
    where entity_type in ('wcs_routing_policy', 'wcs_routing_override');`)
  expect(audit).toContain('wms_register_wcs_routing_policy')
  expect(audit).toContain('wms_update_wcs_routing_policy')
  expect(audit).toContain('wms_exclude_equipment_from_routing')
  expect(audit).toContain('wms_clear_equipment_routing_exclusion')

  // The exclusion row records the reason and the ACTIVE state it created...
  expect(psql(`
    select after->>'status' from wms.audit_events
    where command = 'wms_exclude_equipment_from_routing'
    order by created_at desc limit 1;`)).toBe('ACTIVE')
  // ...and the clearing row records the transition it caused.
  expect(psql(`
    select (before->>'status') || '->' || (after->>'status') from wms.audit_events
    where command = 'wms_clear_equipment_routing_exclusion'
    order by created_at desc limit 1;`)).toBe('ACTIVE->CLEARED')
})
