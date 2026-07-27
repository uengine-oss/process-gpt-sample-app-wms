import { test, expect, type Page } from '@playwright/test'
import { execFileSync } from 'node:child_process'
import { mkdirSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

// End-to-end walk of the WCS digital-twin / simulation contract
// (openspec/changes/add-wcs-digital-twin-simulation).
//
// What makes this spec different from the five before it: the equipment side is
// no longer faked by a hand-written psql DO block. It is driven by the REAL
// external worker,
//     mcp/wms_mcp/simulator/wcs_gateway_simulator.py
// which signs in as wcs-gateway-a@demo.local over Supabase Auth and calls the
// same RPCs a physical PLC/WCS bridge would. The only psql in here is the boot
// (`report_equipment_status IDLE`), which belongs to area 1's contract and has
// no UI, plus a couple of read-only assertions.
//
// Screenshots taken along the way feed the DOCX operator manual under
// openspec/specs/wms_wcs-digital-twin-simulation/docs/.

const DB_CONTAINER = 'supabase_db_process-gpt-sample-app-wms'
const HERE = dirname(fileURLToPath(import.meta.url))
const REPO = resolve(HERE, '../../..')
const SHOT_DIR = resolve(REPO, 'openspec/specs/wms_wcs-digital-twin-simulation/e2e/screenshots')

// unique fixture namespace — nothing else in the suite uses TWIN-
const SIM_AGV = 'TWIN-AGV-01'
const REAL_CONV = 'TWIN-CONV-01'
const SCENARIO_NAME = 'TWIN 야간 축소 운전'

let shotIndex = 0

function psql(sql: string): string {
  return execFileSync(
    'docker',
    ['exec', '-i', DB_CONTAINER, 'psql', '-U', 'postgres', '-d', 'postgres', '-qAt',
     '-v', 'ON_ERROR_STOP=1', '-c', sql],
    { encoding: 'utf8' },
  ).trim()
}

/**
 * Runs the real simulator worker as a child process, exactly the way the
 * README documents it. `--once` is a drain pass: plan everything outstanding,
 * then keep advancing until no plan is left. No manual gateway call anywhere.
 */
function runSimulator(mode: '--once' | '--tick' = '--once'): string {
  return execFileSync(
    resolve(REPO, 'mcp/.venv/bin/python'),
    ['-m', 'wms_mcp.simulator.wcs_gateway_simulator', mode, '--max-seconds', '45'],
    { cwd: resolve(REPO, 'mcp'), encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] },
  )
}

/** The equipment boots and tells the WMS it is ready (area 1's contract, no UI). */
function gatewayBoots(equipmentCode: string) {
  psql(`
do $do$
declare v_actor uuid; v_eq wms.equipment%rowtype;
begin
  select id into v_actor from auth.users where email = 'wcs-gateway-a@demo.local';
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_actor::text, 'role', 'authenticated')::text, false);
  select * into v_eq from wms.equipment where equipment_code = '${equipmentCode}';
  perform wms.wms_report_equipment_status(
    v_eq.id, 'IDLE', v_actor, gen_random_uuid(), v_eq.version, null, 'twin-e2e');
end
$do$;`)
}

function commandStates(equipmentCode: string): string {
  return psql(`
    select coalesce(string_agg(c.status, ',' order by c.created_at), '(none)')
    from wms.equipment_commands c join wms.equipment e on e.id = c.equipment_id
    where e.equipment_code = '${equipmentCode}';`)
}

function schedulesFor(equipmentCode: string): number {
  return Number(psql(`
    select count(*) from wms.simulation_command_schedules s
    join wms.equipment e on e.id = s.equipment_id
    where e.equipment_code = '${equipmentCode}';`))
}

function totalCommands(): number {
  return Number(psql('select count(*) from wms.equipment_commands;'))
}

function cleanupFixtures() {
  // scenarios first (they reference equipment only by uuid[], so no cascade)
  psql(`delete from wms.simulation_scenarios where name like 'TWIN %';`)
  // equipment cascades to commands / events / faults / profiles / schedules
  psql(`delete from wms.equipment where equipment_code in ('${SIM_AGV}', '${REAL_CONV}');`)
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

function simRow(page: Page, code: string) {
  return page.locator(`tr[data-equipment-code="${code}"]`)
}

function scenarioRow(page: Page) {
  return page.locator(`tr[data-scenario-name="${SCENARIO_NAME}"]`)
}

async function registerEquipment(page: Page, code: string, type: string) {
  await page.goto('/wcs/equipment')
  await page.getByLabel('Equipment Code').fill(code)
  await page.getByLabel('Type').selectOption(type)
  await page.getByLabel('Zone', { exact: true }).fill('ZONE-TWIN')
  await page.getByRole('button', { name: 'Register Equipment' }).click()
  await expect(simRow(page, code)).toBeVisible()
}

async function dispatchMove(page: Page, code: string, zone: string) {
  await page.goto('/wcs/equipment')
  await simRow(page, code).getByLabel(`to_zone for ${code}`).fill(zone)
  await simRow(page, code).getByRole('button', { name: 'Dispatch MOVE' }).click()
  await expect(simRow(page, code).getByText('MOVE / PENDING')).toBeVisible()
}

// Test 2 builds on the fixtures test 1 leaves behind.
test.describe.configure({ mode: 'serial' })

test.beforeAll(() => {
  mkdirSync(SHOT_DIR, { recursive: true })
  cleanupFixtures()
})

test.afterAll(() => {
  cleanupFixtures()
})

test('mark equipment simulated -> profile -> dispatch -> the worker completes it', async ({ page }) => {
  await signIn(page, 'wh-manager-a@demo.local')

  // ---------------------------------------------------------------
  // 1. An AGV exists in the registry and boots. Nothing simulated yet.
  // ---------------------------------------------------------------
  await registerEquipment(page, SIM_AGV, 'AGV')
  gatewayBoots(SIM_AGV)

  await page.goto('/wcs/simulation')
  await expect(page.getByRole('heading', { name: 'WCS Simulation' })).toBeVisible()
  await expect(simRow(page, SIM_AGV).getByText('REAL')).toBeVisible()
  await shot(page, 'simulation-board-real')

  // ---------------------------------------------------------------
  // 2. Flip it into simulation mode. Only is_simulated changes — the
  //    machine is still IDLE, and the system defaults apply immediately
  //    (no profile needed to start simulating).
  // ---------------------------------------------------------------
  await simRow(page, SIM_AGV).getByRole('button', { name: 'Simulate' }).click()
  await expect(simRow(page, SIM_AGV).getByText('SIMULATED')).toBeVisible()
  await expect(simRow(page, SIM_AGV).getByText('IDLE')).toBeVisible()
  await expect(simRow(page, SIM_AGV).getByText('기본값')).toBeVisible()
  await shot(page, 'simulation-mode-on')

  // ---------------------------------------------------------------
  // 3. Register a fast, never-failing profile so the E2E does not sit
  //    through the default multi-second timings.
  // ---------------------------------------------------------------
  await page.getByLabel('ack min').fill('100')
  await page.getByLabel('ack max').fill('200')
  await page.getByLabel('progress min').fill('100')
  await page.getByLabel('progress max').fill('200')
  await page.getByLabel('completion min').fill('100')
  await page.getByLabel('completion max').fill('200')
  await page.getByLabel('failure rate').fill('0')
  await shot(page, 'profile-form')

  await page.getByRole('button', { name: 'Save Profile' }).click()
  await expect(simRow(page, SIM_AGV).getByText('등록 프로파일')).toBeVisible()
  await shot(page, 'profile-registered')

  // ---------------------------------------------------------------
  // 4. Dispatch a MOVE from the ordinary equipment screen — area 1's flow,
  //    completely unaware that this machine is a puppet.
  // ---------------------------------------------------------------
  await dispatchMove(page, SIM_AGV, 'ZONE-TWIN-B')
  expect(commandStates(SIM_AGV)).toBe('PENDING')

  // ---------------------------------------------------------------
  // 5. One worker pass. This is the whole point of the area: no psql, no
  //    hand-written gateway call — the real worker process signs in as
  //    WCS_GATEWAY and walks the command to its terminal state.
  // ---------------------------------------------------------------
  const log = runSimulator('--once')
  expect(log).toContain('planned')
  expect(log).toMatch(/MOVE \w+ -> COMPLETED/)

  // ---------------------------------------------------------------
  // 6. The ordinary UI shows it finished. Nobody touched the gateway.
  // ---------------------------------------------------------------
  await page.goto('/wcs/equipment')
  await expect(simRow(page, SIM_AGV).getByText('IDLE')).toBeVisible()
  await expect(simRow(page, SIM_AGV).getByText('—')).toBeVisible()
  expect(commandStates(SIM_AGV)).toBe('COMPLETED')
  await shot(page, 'equipment-completed-by-worker')

  await page.goto('/wcs/monitor')
  await expect(page.locator(`.card[data-equipment-code="${SIM_AGV}"]`)
    .getByText('COMMAND_COMPLETED')).toBeVisible()
  await shot(page, 'monitor-completed-by-worker')

  // the plan is gone — its history lives in the equipment event feed instead
  expect(schedulesFor(SIM_AGV)).toBe(0)
  await page.goto('/wcs/simulation')
  await expect(page.getByText('진행 중인 시뮬레이션 계획이 없습니다.')).toBeVisible()
})

test('failure injection, real equipment stays untouched, and a scenario dispatches nothing', async ({ page }) => {
  await signIn(page, 'wh-manager-a@demo.local')

  // ---------------------------------------------------------------
  // 1. A second machine that is deliberately NOT simulated.
  // ---------------------------------------------------------------
  await registerEquipment(page, REAL_CONV, 'CONVEYOR')
  gatewayBoots(REAL_CONV)
  await dispatchMove(page, REAL_CONV, 'ZONE-TWIN-C')

  // ---------------------------------------------------------------
  // 2. Turn the AGV's failure rate up to 1 and dispatch again.
  // ---------------------------------------------------------------
  await page.goto('/wcs/simulation')
  await page.getByLabel('failure rate').fill('1')
  await page.getByRole('button', { name: 'Save Profile' }).click()
  await expect(page.getByText(/프로파일을 갱신했습니다/)).toBeVisible()
  await shot(page, 'failure-rate-1')

  await dispatchMove(page, SIM_AGV, 'ZONE-TWIN-D')

  // The plan is visible BEFORE the worker runs, and it already knows the
  // command is going to fail — the dice were rolled at planning time.
  runSimulator('--tick')
  await page.goto('/wcs/simulation')
  const plan = page.locator(`tr[data-schedule-equipment="${SIM_AGV}"]`)
  await expect(plan).toBeVisible()
  await expect(plan.locator('.status.danger', { hasText: 'FAILED' })).toBeVisible()
  await shot(page, 'plan-preview-failed')

  // ---------------------------------------------------------------
  // 3. The unsimulated conveyor's command was NOT planned and is still
  //    PENDING — its transitions belong to a real gateway or a human.
  // ---------------------------------------------------------------
  expect(schedulesFor(REAL_CONV)).toBe(0)
  expect(commandStates(REAL_CONV)).toBe('PENDING')

  // ---------------------------------------------------------------
  // 4. Drain: the AGV's second command lands on FAILED, the conveyor's is
  //    still exactly where it was.
  // ---------------------------------------------------------------
  runSimulator('--once')
  expect(commandStates(SIM_AGV)).toBe('COMPLETED,FAILED')
  expect(commandStates(REAL_CONV)).toBe('PENDING')

  await page.goto('/wcs/monitor')
  await expect(page.locator(`.card[data-equipment-code="${SIM_AGV}"]`)
    .getByText('COMMAND_FAILED')).toBeVisible()
  await shot(page, 'monitor-simulated-failure')

  // ---------------------------------------------------------------
  // 5. what-if scenario. It must not create a single equipment command.
  // ---------------------------------------------------------------
  const commandsBefore = totalCommands()

  await page.goto('/wcs/simulation')
  await page.getByLabel('scenario name').fill(SCENARIO_NAME)
  await page.getByLabel('command count').fill('10')
  await page.getByLabel('linked entity type').fill('dispatch_wave')
  await page.getByLabel(`scenario include ${SIM_AGV}`).check()
  await page.getByLabel(`scenario include ${REAL_CONV}`).check()
  await shot(page, 'scenario-form')

  await page.getByRole('button', { name: 'Create Scenario' }).click()
  await expect(scenarioRow(page)).toBeVisible()
  await expect(scenarioRow(page).getByText('DRAFT')).toBeVisible()
  await expect(scenarioRow(page).getByText('아직 실행 전')).toBeVisible()
  await shot(page, 'scenario-draft')

  await scenarioRow(page).getByRole('button', { name: 'Run' }).click()
  await expect(scenarioRow(page).getByText('RUN')).toBeVisible()
  await expect(scenarioRow(page).locator('td[data-run-count="1"]')).toBeVisible()
  // 10 commands over 2 machines -> 5 rounds
  await expect(scenarioRow(page).getByText(/5회전/)).toBeVisible()
  // the conveyor has no profile, so the projection says so out loud
  const detail = page.locator(`tr[data-scenario-detail="${SCENARIO_NAME}"]`)
  await expect(detail).toContainText('DEFAULT_PROFILE_APPLIED')
  await expect(detail).toContainText(REAL_CONV)
  await expect(detail).toContainText('OPTIMISTIC_ESTIMATE')
  await shot(page, 'scenario-projected')

  expect(totalCommands()).toBe(commandsBefore)

  // ---------------------------------------------------------------
  // 6. Running it again keeps the old projection and adds a new one.
  // ---------------------------------------------------------------
  await scenarioRow(page).getByRole('button', { name: 'Run' }).click()
  await expect(scenarioRow(page).locator('td[data-run-count="2"]')).toBeVisible()
  expect(totalCommands()).toBe(commandsBefore)
  await shot(page, 'scenario-second-run')

  // ---------------------------------------------------------------
  // 7. Role split: a WCS_OPERATOR may tune profiles but may not decide
  //    which machines are simulated, and may not define scenarios.
  // ---------------------------------------------------------------
  await page.getByRole('button', { name: /sign out/i }).click()
  await signIn(page, 'wcs-operator-a@demo.local')
  await page.goto('/wcs/simulation')
  await expect(page.getByRole('button', { name: 'Save Profile' })).toBeVisible()
  await expect(page.getByRole('button', { name: 'Simulate' })).toHaveCount(0)
  await expect(page.getByRole('button', { name: 'Turn Off' })).toHaveCount(0)
  await expect(page.getByRole('button', { name: 'Create Scenario' })).toHaveCount(0)
  await shot(page, 'operator-view')

  // Every write in the flow left an audit event.
  const audit = psql(`
    select string_agg(distinct command, ',' order by command)
    from wms.audit_events where command like 'wms_%simulat%';`)
  expect(audit).toContain('wms_set_equipment_simulation_mode')
  expect(audit).toContain('wms_register_simulation_profile')
  expect(audit).toContain('wms_update_simulation_profile')
  expect(audit).toContain('wms_plan_simulated_command')
  expect(audit).toContain('wms_advance_simulated_command')
  expect(audit).toContain('wms_create_simulation_scenario')
  expect(audit).toContain('wms_run_simulation_scenario')
})
