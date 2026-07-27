import { test, expect, type Page } from '@playwright/test'
import { execFileSync } from 'node:child_process'
import { mkdirSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

// End-to-end walk of the WCS sortation-logic contract
// (openspec/changes/add-wcs-sortation-logic).
//
// Two parties, one browser:
//   - Humans (WAREHOUSE_MANAGER / WCS_OPERATOR) tune the sortation profile and
//     send DIVERT / SET_SPEED commands from /wcs/sortation.
//   - The sorter itself (WCS_GATEWAY) is a service identity nobody logs in as,
//     so its outcome reports are driven off-UI through psql — exactly the call
//     a real PLC/WCS bridge would make.
//
// Fixture isolation: every code here is prefixed SORT-E2E- and lives in its
// own zone, because the other specs in this directory use strict single-match
// locators (getByText('IDLE') etc.) that break if this spec leaves extra
// equipment rows behind.
//
// Screenshots taken along the way feed the DOCX operator manual under
// openspec/specs/wms_wcs-sortation-logic/docs/.

const DB_CONTAINER = 'supabase_db_process-gpt-sample-app-wms'
const SORTER = 'SORT-E2E-01'      // gets a profile through the UI
const BARE = 'SORT-E2E-02'        // deliberately left without a profile
const ZONE = 'ZONE-SORT-E2E'
const SHOT_DIR = resolve(
  dirname(fileURLToPath(import.meta.url)),
  '../../../openspec/specs/wms_wcs-sortation-logic/e2e/screenshots',
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
 * Fixture: two idle SORTERs in a private zone. Equipment registration belongs
 * to wms_wcs-equipment-control, so it is set up off-UI rather than clicked
 * through again; the profile is NOT created here — that is step 1 of the test.
 */
function seedFixture() {
  psql(`delete from wms.equipment where zone_code = '${ZONE}'
        or equipment_code in ('${SORTER}', '${BARE}');`)
  asUser('wh-manager-a@demo.local', `
    perform wms.wms_register_equipment(
      '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-00000000000a',
      '${SORTER}', 'SORTER', '${ZONE}', v_actor, gen_random_uuid(), 'sortation-e2e');
    perform wms.wms_register_equipment(
      '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-00000000000a',
      '${BARE}', 'SORTER', '${ZONE}', v_actor, gen_random_uuid(), 'sortation-e2e');`)
  asUser('wcs-gateway-a@demo.local', `
    for v_equipment in select * from wms.equipment where zone_code = '${ZONE}' loop
      perform wms.wms_report_equipment_status(
        v_equipment.id, 'IDLE', v_actor, gen_random_uuid(), v_equipment.version, null, 'sortation-e2e');
    end loop;`)
}

/** Puts back what the fixture added, so the other specs still see a clean DB. */
function cleanupFixture() {
  psql(`delete from wms.equipment where zone_code = '${ZONE}';`)
}

/** The sorter picks up its newest command and reports one outcome for it. */
function gatewayReportsOutcome(outcome: string, extraDetail = '') {
  const status = outcome === 'SUCCESS' ? 'COMPLETED' : 'FAILED'
  asUser('wcs-gateway-a@demo.local', `
    select * into v_equipment from wms.equipment where equipment_code = '${SORTER}';
    select * into v_command from wms.equipment_commands
      where equipment_id = v_equipment.id and command_type = 'DIVERT'
        and status in ('PENDING','ACKNOWLEDGED','IN_PROGRESS')
      order by created_at desc limit 1;
    if not found then raise exception 'no in-flight DIVERT to report'; end if;
    perform wms.wms_report_command_result(
      v_command.id, 'IN_PROGRESS', v_actor, gen_random_uuid(), v_command.version, null, 'sortation-e2e');
    perform wms.wms_report_command_result(
      v_command.id, '${status}', v_actor, gen_random_uuid(), v_command.version + 1,
      '{"outcome": "${outcome}"${extraDetail}}'::jsonb, 'sortation-e2e');`)
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

function card(page: Page, code = SORTER) {
  return page.locator(`.card[data-equipment-code="${code}"]`)
}

function monitorCard(page: Page, code = SORTER) {
  return page.locator(`.card[data-equipment-code="${code}"]`)
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

test('profile -> DIVERT -> MISROUTE (no fault) -> JAM (auto fault) -> operator resolves', async ({ page }) => {
  // ---------------------------------------------------------------
  // 1. Both sorters start without a profile, so nothing is dispatchable.
  // ---------------------------------------------------------------
  await signIn(page, 'wh-manager-a@demo.local')
  await page.goto('/wcs/sortation')
  await expect(page.getByRole('heading', { name: 'WCS Sortation' })).toBeVisible()
  await expect(card(page).getByTestId('no-profile')).toBeVisible()
  await expect(card(page, BARE).getByTestId('no-profile')).toBeVisible()
  await expect(card(page).getByRole('button', { name: 'Dispatch DIVERT' })).toHaveCount(0)
  await shot(page, 'no-profile')

  // ---------------------------------------------------------------
  // 2. The manager registers a sortation profile for SORT-E2E-01.
  // ---------------------------------------------------------------
  await card(page).getByLabel(`min carton gap for ${SORTER}`).fill('150')
  await card(page).getByLabel(`profile speed mode for ${SORTER}`).selectOption('FIXED')
  await card(page).getByLabel(`min speed for ${SORTER}`).fill('0.5')
  await card(page).getByLabel(`max speed for ${SORTER}`).fill('2')
  await card(page).getByLabel(`speed unit for ${SORTER}`).fill('MPS')
  await card(page).getByLabel(`sensor window for ${SORTER}`).fill('80')
  await shot(page, 'profile-form')

  await card(page).getByRole('button', { name: 'Create Profile' }).click()
  await expect(page.getByTestId('sortation-notice')).toContainText('프로파일 등록 완료')
  await expect(card(page).getByTestId('profile-summary')).toContainText('간격 ≥ 150mm')
  await expect(card(page).getByTestId('profile-summary')).toContainText('0.5–2 MPS')
  await shot(page, 'profile-created')

  // ---------------------------------------------------------------
  // 3. Payload/range validation is real: a speed outside the profile is
  //    refused by the DB before any command row is written.
  // ---------------------------------------------------------------
  await card(page).getByLabel(`speed value for ${SORTER}`).fill('3.5')
  await card(page).getByRole('button', { name: 'Dispatch SET_SPEED' }).click()
  await expect(page.locator('.error-banner')).toContainText('outside the profile range')
  await shot(page, 'speed-out-of-range')

  // ...and the same command inside the range goes through.
  await card(page).getByLabel(`speed value for ${SORTER}`).fill('1.8')
  await card(page).getByRole('button', { name: 'Dispatch SET_SPEED' }).click()
  await expect(page.getByTestId('sortation-notice')).toContainText('SET_SPEED 명령이 PENDING')
  await expect(card(page).getByTestId('active-commands')).toContainText('SET_SPEED (PENDING)')

  // ---------------------------------------------------------------
  // 4. A DIVERT command, then the sorter reports MISROUTE off-UI.
  //    MISROUTE fails the command but must NOT fault the machine.
  // ---------------------------------------------------------------
  await card(page).getByLabel(`target chute for ${SORTER}`).fill('CHUTE-12')
  await card(page).getByLabel(`item identifier for ${SORTER}`).fill('BC-0001')
  await card(page).getByRole('button', { name: 'Dispatch DIVERT' }).click()
  await expect(page.getByTestId('sortation-notice')).toContainText('DIVERT 명령이 PENDING')
  await expect(card(page).getByTestId('active-commands')).toContainText('DIVERT (PENDING)')
  await shot(page, 'divert-dispatched')

  gatewayReportsOutcome('MISROUTE', ', "actual_chute": "CHUTE-08"')
  await page.reload()
  await expect(card(page).getByTestId('last-outcome')).toContainText('MISROUTE')
  await expect(card(page).locator('.status.danger', { hasText: 'FAULT' })).toHaveCount(0)
  await shot(page, 'misroute-no-fault')

  // The monitor agrees: the command failed, the machine did not.
  await page.goto('/wcs/monitor')
  await expect(monitorCard(page).getByText('COMMAND_FAILED')).toBeVisible()
  await expect(monitorCard(page).locator('.fault')).toHaveCount(0)
  await shot(page, 'monitor-misroute')

  // ---------------------------------------------------------------
  // 5. A second DIVERT jams. That must raise a SORTATION_JAM fault by
  //    itself and take the still-pending SET_SPEED down with it.
  // ---------------------------------------------------------------
  await page.goto('/wcs/sortation')
  await card(page).getByLabel(`target chute for ${SORTER}`).fill('CHUTE-03')
  await card(page).getByLabel(`item identifier for ${SORTER}`).fill('BC-0002')
  await card(page).getByRole('button', { name: 'Dispatch DIVERT' }).click()
  await expect(card(page).getByTestId('active-commands')).toContainText('DIVERT (PENDING)')
  await expect(card(page).getByTestId('active-commands')).toContainText('SET_SPEED (PENDING)')

  gatewayReportsOutcome('JAM', ', "reason": "CARTON_STUCK"')
  await page.reload()
  await expect(card(page).getByTestId('last-outcome')).toContainText('JAM')
  await expect(card(page).locator('.status.danger', { hasText: 'FAULT' })).toBeVisible()
  // the fault force-failed every outstanding command
  await expect(card(page).getByTestId('active-commands')).toHaveCount(0)
  await shot(page, 'jam-auto-fault')

  // Nobody filed that fault — the JAM outcome did.
  expect(psql(`select fault_code || '/' || severity from wms.equipment_faults f
               join wms.equipment e on e.id = f.equipment_id
               where e.equipment_code = '${SORTER}' and f.status = 'OPEN';`)).toBe('SORTATION_JAM/CRITICAL')
  expect(psql(`select count(*) from wms.equipment_commands c
               join wms.equipment e on e.id = c.equipment_id
               where e.equipment_code = '${SORTER}' and c.fault_id is not null;`)).toBe('2')

  // ---------------------------------------------------------------
  // 6. The jam shows up in the monitor as a normal open fault, and a
  //    WCS_OPERATOR clears it through the existing procedure.
  // ---------------------------------------------------------------
  await page.goto('/wcs/monitor')
  await expect(monitorCard(page).locator('.fault')).toContainText('SORTATION_JAM')
  await expect(monitorCard(page).locator('.fault')).toContainText('CRITICAL')
  await shot(page, 'monitor-jam-fault')
  await signOut(page)

  await signIn(page, 'wcs-operator-a@demo.local')
  await page.goto('/wcs/monitor')
  await monitorCard(page)
    .getByLabel(`resolution note for ${SORTER}`)
    .fill('슈트 입구 카톤 제거 및 벨트 재기동 완료')
  await monitorCard(page).getByRole('button', { name: 'Resolve Fault' }).click()
  await expect(monitorCard(page).locator('.fault')).toHaveCount(0)
  await expect(monitorCard(page).locator('.status', { hasText: 'IDLE' })).toBeVisible()
  await shot(page, 'jam-resolved')

  // ...and the sorter accepts work again.
  await page.goto('/wcs/sortation')
  await expect(card(page).locator('.status.ok', { hasText: 'IDLE' })).toBeVisible()
  await card(page).getByLabel(`command speed mode for ${SORTER}`).selectOption('AUTO')
  await card(page).getByRole('button', { name: 'Dispatch SET_SPEED' }).click()
  await expect(page.getByTestId('sortation-notice')).toContainText('SET_SPEED 명령이 PENDING')
  await shot(page, 'auto-speed-after-recovery')
  await signOut(page)
})

test('WMS_ADMIN can tune a profile but cannot dispatch, and the audit trail is complete', async ({ page }) => {
  // The role split this contract inherits from wms_wcs-equipment-control:
  // wms_dispatch_equipment_command does not allow WMS_ADMIN, so the admin sees
  // the profile editor but no command forms.
  await signIn(page, 'admin-a@demo.local')
  await page.goto('/wcs/sortation')
  await expect(page.getByTestId('role-note')).toBeVisible()
  await expect(card(page).getByRole('button', { name: 'Save Profile' })).toBeVisible()
  await expect(card(page).getByRole('button', { name: 'Dispatch DIVERT' })).toHaveCount(0)
  await shot(page, 'admin-profile-only')

  // The admin widens the range; the write itself is allowed.
  await card(page).getByLabel(`max speed for ${SORTER}`).fill('2.5')
  await card(page).getByRole('button', { name: 'Save Profile' }).click()
  await expect(page.getByTestId('sortation-notice')).toContainText('프로파일 저장')
  await expect(card(page).getByTestId('profile-summary')).toContainText('0.5–2.5 MPS')
  await shot(page, 'admin-profile-saved')
  await signOut(page)

  // A role with none of the three permissions only reads.
  await signIn(page, 'quality-a@demo.local')
  await page.goto('/wcs/sortation')
  await expect(card(page).getByTestId('profile-summary')).toBeVisible()
  await expect(card(page).getByRole('button', { name: 'Save Profile' })).toHaveCount(0)
  await expect(card(page).getByRole('button', { name: 'Dispatch DIVERT' })).toHaveCount(0)
  await shot(page, 'read-only-role')

  // Every write in the flow above left an audit event, including the
  // automatic jam escalation nobody clicked.
  const audit = psql(`
    select string_agg(distinct command, ',' order by command)
    from wms.audit_events
    where entity_type in ('sortation_profile', 'equipment_fault');`)
  expect(audit).toContain('wms_create_sortation_profile')
  expect(audit).toContain('wms_update_sortation_profile')
  expect(audit).toContain('wms_escalate_sortation_jam')
  expect(audit).toContain('wms_resolve_equipment_fault')

  // The escalation row carries the equipment transition it caused.
  expect(psql(`
    select (before->>'equipment_status') || '->' || (after->>'equipment_status')
    from wms.audit_events where command = 'wms_escalate_sortation_jam'
    order by created_at desc limit 1;`)).toBe('RUNNING->FAULT')
})
