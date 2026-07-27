import { test, expect, type Page } from '@playwright/test'
import { execFileSync } from 'node:child_process'
import { mkdirSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

// End-to-end walk of the labor management contract
// (openspec/changes/add-labor-management).
//
// Every actor here is a human, so — like the yard/dock area — the whole flow
// happens in the UI. psql is used for exactly three things, none of which is
// under test:
//   * planting a colleague's IN_PROGRESS row, so the RLS privacy rule can be
//     observed THROUGH THE SCREEN rather than only in a SQL harness;
//   * backdating started_at, because a start and a complete a second apart
//     would measure 0s and the duration column is part of the contract;
//   * cleanup.
//
// Screenshots taken along the way feed the DOCX operator manual under
// openspec/specs/wms_labor-management/docs/.

const DB_CONTAINER = 'supabase_db_process-gpt-sample-app-wms'
const TENANT_A = '10000000-0000-0000-0000-00000000000a'
const WH_A = '20000000-0000-0000-0000-00000000000a'

const LABEL_WORK = 'LABOR-E2E-오전 입고 검수'
const LABEL_ABANDONED = 'LABOR-E2E-잘못 시작한 작업'
const LABEL_COLLEAGUE = 'LABOR-E2E-동료의 작업'

const SHOT_DIR = resolve(
  dirname(fileURLToPath(import.meta.url)),
  '../../../openspec/specs/wms_labor-management/e2e/screenshots',
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
    delete from wms.audit_events
      where entity_type = 'labor_activity'
        and coalesce(after->>'activity_label', before->>'activity_label') like 'LABOR-E2E-%';
    delete from wms.labor_activities where activity_label like 'LABOR-E2E-%';`)
}

/** A colleague's open activity, so the privacy rule has something to hide. */
function seedColleagueActivity() {
  psql(`
    insert into wms.labor_activities (
      tenant_id, warehouse_id, actor_id, actor_role, activity_type, activity_label, status)
    select '${TENANT_A}', '${WH_A}', u.id, 'QUALITY_INSPECTOR',
           'QUALITY_INSPECTION', '${LABEL_COLLEAGUE}', 'IN_PROGRESS'
    from auth.users u where u.email = 'quality-a@demo.local';`)
}

/**
 * The RPCs stamp both timestamps with the server's now(), so a UI-driven
 * start->complete measures ~0s. Winding started_at back lets the screen show
 * the duration the contract actually computes.
 */
function backdate(label: string, seconds: number) {
  psql(`
    update wms.labor_activities
    set started_at = started_at - make_interval(secs => ${seconds})
    where activity_label = '${label}' and status = 'IN_PROGRESS';`)
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

function activityRow(page: Page, label: string) {
  return page.locator(`tr[data-activity-label="${label}"]`)
}

async function startActivity(page: Page, type: string, label: string) {
  await page.getByLabel('Activity Type').selectOption(type)
  await page.getByLabel('Activity Label').fill(label)
  await page.getByRole('button', { name: 'Start Activity' }).click()
  await expect(activityRow(page, label)).toBeVisible()
}

// Test 2 reads the numbers test 1 produced, so run them in order.
test.describe.configure({ mode: 'serial' })

test.beforeAll(() => {
  mkdirSync(SHOT_DIR, { recursive: true })
  resetFixtures()
  seedColleagueActivity()
})

test.afterAll(() => {
  resetFixtures()
})

test('worker starts + completes an activity, cancels another, and sees only their own productivity', async ({
  page,
}) => {
  // ---------------------------------------------------------------
  // 1. An INBOUND_OPERATOR opens a receiving activity.
  // ---------------------------------------------------------------
  await signIn(page, 'inbound-a@demo.local')
  await page.goto('/labor')
  await expect(page.getByRole('heading', { name: 'Labor' })).toBeVisible()

  // Before anything is recorded, the privacy rule is already visible: the
  // colleague's IN_PROGRESS row planted in beforeAll is simply not there.
  await expect(activityRow(page, LABEL_COLLEAGUE)).toHaveCount(0)
  await shot(page, 'worker-empty-board')

  await startActivity(page, 'RECEIVING', LABEL_WORK)
  await expect(activityRow(page, LABEL_WORK)).toContainText('INBOUND_OPERATOR')
  await expect(page.getByTestId('labor-notice')).toContainText('IN_PROGRESS')
  await shot(page, 'activity-started')

  // ---------------------------------------------------------------
  // 2. Twelve and a half minutes of work later (spec.md's worked example:
  //    09:00:00 -> 09:12:30 with 48 units = 750 seconds), it is closed.
  // ---------------------------------------------------------------
  backdate(LABEL_WORK, 750)
  await activityRow(page, LABEL_WORK).getByLabel(/unit count/).fill('48')
  await activityRow(page, LABEL_WORK).getByRole('button', { name: 'Complete' }).click()
  await expect(page.getByTestId('labor-notice')).toContainText('750초')
  await expect(page.getByTestId('labor-notice')).toContainText('48')
  // it left the in-progress list...
  await expect(activityRow(page, LABEL_WORK)).toHaveCount(0)
  // ...and arrived in the aggregate
  await expect(page.getByTestId('totals-completed')).toHaveText('1')
  await expect(page.getByTestId('totals-units')).toHaveText('48')
  await expect(
    page.locator('tr[data-productivity-row="inbound-a@demo.local RECEIVING"]'),
  ).toContainText('12m 30s')
  await shot(page, 'activity-completed')

  // ---------------------------------------------------------------
  // 3. A cancelled activity is invisible to every productivity number —
  //    an hour of "work" that never happened must not move the average.
  // ---------------------------------------------------------------
  await startActivity(page, 'PUTAWAY', LABEL_ABANDONED)
  backdate(LABEL_ABANDONED, 3600)
  await activityRow(page, LABEL_ABANDONED).getByRole('button', { name: 'Cancel' }).click()
  await expect(page.getByTestId('labor-notice')).toContainText('제외')
  await expect(activityRow(page, LABEL_ABANDONED)).toHaveCount(0)
  // unchanged: still one completion, still 48 units, still 12m30s average
  await expect(page.getByTestId('totals-completed')).toHaveText('1')
  await expect(page.getByTestId('totals-units')).toHaveText('48')
  await shot(page, 'cancelled-excluded')

  // ---------------------------------------------------------------
  // 4. PRIVACY, seen from the worker's side. The colleague completed work in
  //    this same warehouse (seed data + the row planted above), yet:
  //      - the aggregate says SELF and counts exactly one worker
  //      - the leaderboard has one row and no rank
  //      - the forecast panel is not rendered at all
  // ---------------------------------------------------------------
  await expect(page.getByTestId('productivity-scope')).toHaveText('SELF')
  await expect(page.getByTestId('totals-actors')).toHaveText('1')
  await expect(page.locator('tr[data-leaderboard-actor]')).toHaveCount(1)
  await expect(page.locator('tr[data-leaderboard-actor="inbound-a@demo.local"]')).toBeVisible()
  await expect(page.getByTestId('leaderboard-scope')).toHaveText('SELF')
  // V3: no fake rank, no leaked global rank
  await expect(
    page.locator('tr[data-leaderboard-actor="inbound-a@demo.local"] td').first(),
  ).toHaveText('—')
  await expect(page.getByRole('button', { name: 'Forecast' })).toHaveCount(0)
  await shot(page, 'worker-self-scope')

  // The colleague's open activity is still hidden even now.
  await expect(activityRow(page, LABEL_COLLEAGUE)).toHaveCount(0)
  await signOut(page)
})

test('the manager sees every worker ranked, and gets a headcount estimate', async ({ page }) => {
  await signIn(page, 'wh-manager-a@demo.local')
  await page.goto('/labor')

  // ---------------------------------------------------------------
  // 5. The same two RPCs, the same screen, a different scope — because the
  //    caller's role is what the database branches on, not anything the UI
  //    passed in.
  // ---------------------------------------------------------------
  await expect(page.getByTestId('productivity-scope')).toHaveText('WAREHOUSE')
  await expect(page.getByTestId('leaderboard-scope')).toHaveText('WAREHOUSE')
  // and the colleague's in-progress row that the worker could not see
  await expect(activityRow(page, LABEL_COLLEAGUE)).toBeVisible()
  await expect(activityRow(page, LABEL_COLLEAGUE)).toContainText('QUALITY_INSPECTOR')
  // ...but seeing it is not owning it. D2 says only the worker (or WMS_ADMIN)
  // may close an activity, so the manager gets no buttons on that row.
  await expect(activityRow(page, LABEL_COLLEAGUE)).toContainText('본인만 종료할 수 있습니다')
  await expect(
    activityRow(page, LABEL_COLLEAGUE).getByRole('button', { name: 'Complete' }),
  ).toHaveCount(0)

  // The worker from test 1 is on the board, ranked, with their real numbers.
  const workerRow = page.locator('tr[data-leaderboard-actor="inbound-a@demo.local"]')
  await expect(workerRow).toBeVisible()
  await expect(workerRow.locator('td').first()).toHaveText('1')
  await expect(workerRow).toContainText('48')
  await expect(workerRow).toContainText('12m 30s')
  await shot(page, 'manager-leaderboard')

  // Switching the metric re-sorts server-side.
  await page.getByLabel('Leaderboard Metric').selectOption('total_unit_count')
  await expect(page.locator('tr[data-leaderboard-actor]').first()).toContainText('48')
  await page.getByLabel('Leaderboard Metric').selectOption('completed_count')

  // ---------------------------------------------------------------
  // 6. Demand forecast — manager-only, and honest about being arithmetic.
  //    The trailing window reaches back past today, so the seeded history
  //    (D-1..D-3) is the sample rather than this test's single activity.
  // ---------------------------------------------------------------
  await page.getByLabel('Forecast Role').fill('INBOUND_OPERATOR')
  await page.getByLabel('Expected Volume').fill('4800')
  await page.getByLabel('Trailing Days').fill('7')
  await page.getByLabel('Shift Hours').fill('8')
  await page.getByRole('button', { name: 'Forecast' }).click()

  await expect(page.getByTestId('forecast-result')).toBeVisible()
  const headcount = await page.getByTestId('forecast-headcount').innerText()
  expect(Number(headcount)).toBeGreaterThanOrEqual(1)
  await expect(page.getByTestId('forecast-result')).toContainText('SIMPLE_RATIO')
  await expect(page.getByTestId('forecast-result')).toContainText('머신러닝 예측이 아닙니다')
  await shot(page, 'manager-forecast')

  // The number really is ceil(volume / per-person-per-shift) — recompute it
  // from the basis line the panel itself prints.
  const basis = await page.getByTestId('forecast-result').innerText()
  const perPerson = Number(basis.match(/1인 1교대\s*\n?\s*([\d.]+)/)?.[1])
  expect(perPerson).toBeGreaterThan(0)
  expect(Number(headcount)).toBe(Math.ceil(4800 / perPerson))

  // A role nobody has worked in has no sample, and the contract refuses to
  // invent one rather than dividing by zero.
  await page.getByLabel('Forecast Role').fill('PROCUREMENT_BUYER')
  await page.getByRole('button', { name: 'Forecast' }).click()
  await expect(page.getByTestId('labor-error')).toContainText('INVALID')
  await expect(page.getByTestId('labor-error')).toContainText('cannot estimate headcount')
  await shot(page, 'forecast-no-sample')

  // ---------------------------------------------------------------
  // 7. Every write in the flow above left an audit event with a before/after.
  // ---------------------------------------------------------------
  const commands = psql(`
    select string_agg(distinct command, ',' order by command)
    from wms.audit_events
    where command in ('wms_start_labor_activity', 'wms_complete_labor_activity',
                      'wms_cancel_labor_activity');`)
  expect(commands).toBe(
    'wms_cancel_labor_activity,wms_complete_labor_activity,wms_start_labor_activity',
  )

  const transition = psql(`
    select (before->>'status') || '->' || (after->>'status') || ':' || (after->>'duration_seconds')
    from wms.audit_events
    where command = 'wms_complete_labor_activity'
      and after->>'activity_label' = '${LABEL_WORK}';`)
  expect(transition).toBe('IN_PROGRESS->COMPLETED:750')

  // D1: the instrumentation layer never reached into the inbound documents.
  const receiptTouches = psql(`
    select count(*) from wms.audit_events
    where entity_type = 'receipt'
      and command in ('wms_start_labor_activity', 'wms_complete_labor_activity',
                      'wms_cancel_labor_activity');`)
  expect(receiptTouches).toBe('0')
})
