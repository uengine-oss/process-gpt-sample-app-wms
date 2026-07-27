import { test, expect, type Page } from '@playwright/test'
import { execFileSync } from 'node:child_process'
import { mkdirSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

// End-to-end walk of the slotting optimization contract
// (openspec/changes/add-slotting-optimization).
//
// The whole flow happens in the UI. psql is used for exactly three things,
// none of which is under test:
//
//   * creating four SLOT-E2E products, so the ABC cutoffs have something
//     deterministic to land on (the seed has three SKUs and no consumption);
//   * INJECTING SYNTHETIC CONSUMPTION — see the long comment on
//     seedSyntheticConsumption() below. This is the honest part of the run and
//     the test asserts the pre-injection state first, on purpose;
//   * cleanup.
//
// Screenshots taken along the way feed the DOCX operator manual under
// openspec/specs/wms_slotting-optimization/docs/.

const DB_CONTAINER = 'supabase_db_process-gpt-sample-app-wms'
const TENANT_A = '10000000-0000-0000-0000-00000000000a'
const WH_A = '20000000-0000-0000-0000-00000000000a'

// Four locations, deliberately spread across the accessibility range.
const LOC_A01 = 'SLOT-E2E-A-01' // rank 1  — next to packing
const LOC_A02 = 'SLOT-E2E-A-02' // rank 2
const LOC_A03 = 'SLOT-E2E-A-03' // rank 3
const LOC_Z20 = 'SLOT-E2E-Z-20' // rank 20 — bulk storage, far away

const SKU_FAST = 'SLOT-E2E-P1' // 60 units out — A class, badly slotted at rank 20
const SKU_MID = 'SLOT-E2E-P2' //  15 units out — B class, and B has NO policy
const SKU_SLOW = 'SLOT-E2E-P3' //   5 units out — C class, never declared anywhere
const SKU_OK = 'SLOT-E2E-P4' //  20 units out — A class, already at rank 2

const SHOT_DIR = resolve(
  dirname(fileURLToPath(import.meta.url)),
  '../../../openspec/specs/wms_slotting-optimization/e2e/screenshots',
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
  // audit rows first: they carry no FK, so nothing cascades them away.
  psql(`
    delete from wms.audit_events
      where entity_type in ('storage_location', 'sku_location_assignment',
                            'slotting_class_policy', 'sku_velocity_batch',
                            'slotting_recommendation');
    delete from wms.stock_ledger_entries
      where source_type = 'SLOT-E2E-synthetic-consumption';
    delete from wms.sku_location_assignments
      where location_id in (select id from wms.storage_locations where location_code like 'SLOT-E2E-%');
    delete from wms.slotting_recommendations
      where warehouse_id = '${WH_A}';
    delete from wms.sku_velocity_snapshots
      where warehouse_id = '${WH_A}';
    delete from wms.slotting_class_policies
      where warehouse_id = '${WH_A}';
    delete from wms.products where sku like 'SLOT-E2E-%';
    delete from wms.storage_locations where location_code like 'SLOT-E2E-%';
    delete from wms.idempotency_records where command_name like 'wms_%slotting%'
       or command_name like 'wms_%storage_location%'
       or command_name like 'wms_%sku_location%'
       or command_name like 'wms_%sku_velocity%';`)
}

function seedProducts() {
  psql(`
    insert into wms.products (tenant_id, sku, name, uom) values
      ('${TENANT_A}', '${SKU_FAST}', '슬롯팅 데모 SKU 1 (고빈도)', 'EA'),
      ('${TENANT_A}', '${SKU_MID}',  '슬롯팅 데모 SKU 2 (중빈도)', 'EA'),
      ('${TENANT_A}', '${SKU_SLOW}', '슬롯팅 데모 SKU 3 (저빈도)', 'EA'),
      ('${TENANT_A}', '${SKU_OK}',   '슬롯팅 데모 SKU 4 (고빈도, 위치 양호)', 'EA');`)
}

/**
 * SYNTHETIC CONSUMPTION — rows no RPC in this repository can produce.
 *
 * wms_compute_sku_velocity's only signal is `status = 'AVAILABLE' and
 * qty_delta < 0`, and nothing in this codebase writes that shape. Verified
 * against the migrations as implemented, not their design docs:
 *
 *     grep -n 'stock_ledger_entries' supabase/migrations/*.sql | grep -v 20260726
 *       -> one comment in 20260727, and nothing else
 *
 * Area 5's wms.outbound_orders (20260731) is real and reaches COMPLETED, but
 * writes no ledger row on any path; area 6's simulation is projection-only.
 * So the consumption history genuinely does not exist yet, and the first half
 * of test 1 asserts exactly that BEFORE this function is ever called.
 *
 * These rows stand in for a future outbound-fulfilment RPC. Quantities are
 * chosen so the cumulative share lands exactly on both ABC cutoffs:
 *   P1 60 -> 60% A | P4 20 -> 80% A | P2 15 -> 95% B | P3 5 -> 100% C
 *
 * Dated D-5..D-3 so they sit well inside the screen's default D-7..D-1 window
 * no matter how far the browser's local day is from the database's UTC day.
 */
function seedSyntheticConsumption() {
  psql(`
    insert into wms.stock_ledger_entries
      (tenant_id, warehouse_id, product_id, qty_delta, status, source_type, created_at)
    select '${TENANT_A}', '${WH_A}', p.id, -s.qty, 'AVAILABLE',
           'SLOT-E2E-synthetic-consumption',
           date_trunc('day', now()) - make_interval(days => s.days_ago) + interval '10 hours'
    from (values
      ('${SKU_FAST}', 30, 5), ('${SKU_FAST}', 20, 4), ('${SKU_FAST}', 10, 3),
      ('${SKU_OK}',   12, 5), ('${SKU_OK}',    8, 3),
      ('${SKU_MID}',  15, 4),
      ('${SKU_SLOW}',  5, 3)
    ) as s(sku, qty, days_ago)
    join wms.products p on p.sku = s.sku and p.tenant_id = '${TENANT_A}';`)
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

function locationRow(page: Page, code: string) {
  return page.locator(`tr[data-location-code="${code}"]`)
}
function assignmentRow(page: Page, sku: string) {
  return page.locator(`tr[data-assignment-sku="${sku}"]`)
}
function velocityRow(page: Page, sku: string) {
  return page.locator(`tr[data-velocity-sku="${sku}"]`)
}
function recommendationRow(page: Page, sku: string) {
  return page.locator(`tr[data-recommendation-sku="${sku}"]`)
}

async function registerLocation(page: Page, zone: string, code: string, rank: string) {
  await page.getByLabel('Zone Code').fill(zone)
  await page.getByLabel('Location Code').fill(code)
  // exact, or it also matches the policy panel's "Max Accessibility Rank"
  await page.getByLabel('Accessibility Rank', { exact: true }).fill(rank)
  await page.getByRole('button', { name: 'Register Location' }).click()
  await expect(locationRow(page, code)).toBeVisible()
}

async function declareAssignment(page: Page, sku: string, locationCode: string, rank: number) {
  await page.getByLabel('Assign SKU').selectOption({ label: sku })
  await page.getByLabel('Assign Location').selectOption({ label: `${locationCode} (rank ${rank})` })
  await page.getByRole('button', { name: 'Declare Assignment' }).click()
  await expect(assignmentRow(page, sku)).toBeVisible()
}

// Test 2 reviews what test 1 generated, so run them in order.
test.describe.configure({ mode: 'serial' })

test.beforeAll(() => {
  mkdirSync(SHOT_DIR, { recursive: true })
  resetFixtures()
  seedProducts()
})

test.afterAll(() => {
  resetFixtures()
})

test('the manager builds a slotting board, and the velocity computation refuses to invent grades', async ({
  page,
}) => {
  await signIn(page, 'wh-manager-a@demo.local')
  await page.goto('/slotting')
  await expect(page.getByRole('heading', { name: 'Slotting' })).toBeVisible()
  await expect(page.getByText('등록된 보관 위치가 없습니다.')).toBeVisible()
  await shot(page, 'empty-board')

  // ---------------------------------------------------------------
  // 1. The registry. Four locations across the accessibility range —
  //    slotting only means anything if locations can be COMPARED.
  // ---------------------------------------------------------------
  await registerLocation(page, 'PACK_ADJACENT', LOC_A01, '1')
  await registerLocation(page, 'PACK_ADJACENT', LOC_A02, '2')
  await registerLocation(page, 'PACK_ADJACENT', LOC_A03, '3')
  await registerLocation(page, 'BULK_STORAGE', LOC_Z20, '20')

  await expect(locationRow(page, LOC_A01).locator('[data-location-rank]')).toHaveText('1')
  await expect(locationRow(page, LOC_Z20).locator('[data-location-rank]')).toHaveText('20')
  await expect(locationRow(page, LOC_A01)).toContainText('ACTIVE')
  await shot(page, 'locations-registered')

  // ---------------------------------------------------------------
  // 2. Declared placements. P1 (which will turn out to be the fastest mover)
  //    is sitting in bulk storage at rank 20; P4 is already at rank 2.
  // ---------------------------------------------------------------
  await declareAssignment(page, SKU_FAST, LOC_Z20, 20)
  await declareAssignment(page, SKU_OK, LOC_A02, 2)
  await expect(assignmentRow(page, SKU_FAST).locator('[data-assignment-rank]')).toHaveText('20')
  await expect(assignmentRow(page, SKU_FAST)).toContainText('MANUAL_DECLARATION')
  // P3 is deliberately never declared — D5's "nobody knows where it is" case.
  await expect(assignmentRow(page, SKU_SLOW)).toHaveCount(0)

  // ---------------------------------------------------------------
  // 3. Class policies. A caps at rank 5, C at rank 40 — and B is left
  //    UNDEFINED on purpose, so the generator has to admit it later.
  // ---------------------------------------------------------------
  await page.getByLabel('Velocity Class').selectOption('A')
  await page.getByLabel('Max Accessibility Rank').fill('5')
  await page.getByRole('button', { name: 'Register Policy' }).click()
  await expect(page.locator('tr[data-policy-class="A"]')).toBeVisible()

  await page.getByLabel('Velocity Class').selectOption('C')
  await page.getByLabel('Max Accessibility Rank').fill('40')
  await page.getByRole('button', { name: 'Register Policy' }).click()
  await expect(page.locator('tr[data-policy-class="C"]')).toBeVisible()
  await expect(page.locator('tr[data-policy-class="B"]')).toHaveCount(0)
  await shot(page, 'assignments-and-policies')

  // ---------------------------------------------------------------
  // 4. THE HONEST DEFAULT. Nothing has been consumed, because no RPC in this
  //    repository decrements AVAILABLE stock. The screen must NOT respond by
  //    grading every SKU as "C — slow mover"; it must say it does not know.
  // ---------------------------------------------------------------
  await page.getByRole('button', { name: 'Compute Velocity' }).click()
  await expect(page.getByTestId('velocity-summary')).toBeVisible()
  await expect(page.getByTestId('velocity-status')).toHaveText('NO_SIGNAL')
  await expect(page.getByTestId('velocity-included')).toHaveText('0')
  // every product of the tenant was a candidate and every one was skipped
  const candidates = await page.getByTestId('velocity-candidates').innerText()
  await expect(page.getByTestId('velocity-skipped')).toHaveText(candidates)
  expect(Number(candidates)).toBeGreaterThanOrEqual(4)
  await expect(page.getByTestId('velocity-no-signal')).toContainText('등급을 매기지 않았습니다')
  // ...and with nothing graded there is nothing to recommend, so the button
  // is not even offered.
  await expect(page.getByRole('button', { name: 'Generate Recommendations' })).toBeDisabled()
  await shot(page, 'velocity-no-signal')

  // ---------------------------------------------------------------
  // 5. Now inject the consumption a future outbound RPC would have written
  //    (see seedSyntheticConsumption's comment) and compute again. Same
  //    contract, same window, unchanged code — only the signal is new.
  // ---------------------------------------------------------------
  seedSyntheticConsumption()
  await page.getByRole('button', { name: 'Compute Velocity' }).click()
  await expect(page.getByTestId('velocity-status')).toHaveText('COMPUTED')
  await expect(page.getByTestId('velocity-included')).toHaveText('4')
  // the three seed SKUs still have no signal, and are still not graded
  await expect(page.getByTestId('velocity-skipped')).toHaveText('3')
  await expect(page.getByTestId('velocity-no-signal')).toHaveCount(0)

  // ABC by cumulative share, with both cutoffs hit exactly:
  //   P1 60 -> 60% A | P4 20 -> 80% A | P2 15 -> 95% B | P3 5 -> 100% C
  await expect(velocityRow(page, SKU_FAST).locator('[data-velocity-class]')).toHaveText('A')
  await expect(velocityRow(page, SKU_OK).locator('[data-velocity-class]')).toHaveText('A')
  await expect(velocityRow(page, SKU_MID).locator('[data-velocity-class]')).toHaveText('B')
  await expect(velocityRow(page, SKU_SLOW).locator('[data-velocity-class]')).toHaveText('C')
  await expect(velocityRow(page, SKU_FAST)).toContainText('60')
  await shot(page, 'velocity-abc')

  // ---------------------------------------------------------------
  // 6. Generate. Two recommendations, and three different reasons for NOT
  //    recommending — each one reported rather than silently dropped.
  // ---------------------------------------------------------------
  await page.getByRole('button', { name: 'Generate Recommendations' }).click()
  await expect(page.getByTestId('generation-summary')).toBeVisible()
  await expect(page.getByTestId('generated-count')).toHaveText('2')
  await expect(page.getByTestId('skipped-no-policy')).toHaveText('B')
  await expect(page.getByTestId('skipped-optimal')).toHaveText('1')

  // P1: A-class stranded at rank 20, pulled to the best free slot at rank 1.
  await expect(recommendationRow(page, SKU_FAST)).toContainText('RELOCATE_UNDERSERVED')
  await expect(recommendationRow(page, SKU_FAST).locator('[data-current-location]')).toContainText(LOC_Z20)
  await expect(recommendationRow(page, SKU_FAST).locator('[data-recommended-location]')).toContainText(LOC_A01)
  await expect(recommendationRow(page, SKU_FAST)).toHaveAttribute('data-recommendation-status', 'PENDING')

  // P3: graded but never placed. current location is null, and that is a
  // fact about the warehouse, not missing data.
  await expect(recommendationRow(page, SKU_SLOW)).toContainText('UNASSIGNED_HIGH_VELOCITY')
  await expect(recommendationRow(page, SKU_SLOW).locator('[data-current-location]')).toHaveText('—')

  // P4 was already inside its cap; P2's class has no policy. Neither is
  // recommended, and neither was invented a default for.
  await expect(recommendationRow(page, SKU_OK)).toHaveCount(0)
  await expect(recommendationRow(page, SKU_MID)).toHaveCount(0)
  await shot(page, 'recommendations-generated')

  await signOut(page)
})

test('an agent may generate but not approve; the manager approves, applies, and the assignment moves', async ({
  page,
}) => {
  // ---------------------------------------------------------------
  // 7. The PROCESS_AGENT. It is allowed to run the analysis — and it is the
  //    role the contract expects to have produced these very rows — but the
  //    approve/reject buttons are not offered to it, because approving is a
  //    decision to move physical stock (design.md D6).
  // ---------------------------------------------------------------
  await signIn(page, 'process-agent-a@demo.local')
  await page.goto('/slotting')
  await expect(page.getByTestId('review-scope')).toHaveText('조회 전용')
  await expect(recommendationRow(page, SKU_FAST)).toBeVisible()
  await expect(recommendationRow(page, SKU_FAST)).toContainText('승인은 창고관리자만 할 수 있습니다')
  await expect(recommendationRow(page, SKU_FAST).getByRole('button', { name: 'Approve' })).toHaveCount(0)
  await expect(recommendationRow(page, SKU_FAST).getByRole('button', { name: 'Reject' })).toHaveCount(0)
  // but the analysis half of the contract is open to it
  await expect(page.getByRole('button', { name: 'Compute Velocity' })).toBeVisible()
  await shot(page, 'agent-cannot-approve')
  await signOut(page)

  // ---------------------------------------------------------------
  // 8. The manager rejects one and approves the other. Approving is NOT
  //    applying — the assignment must still read SLOT-E2E-Z-20 afterwards.
  // ---------------------------------------------------------------
  await signIn(page, 'wh-manager-a@demo.local')
  await page.goto('/slotting')
  await expect(page.getByTestId('review-scope')).toHaveText('승인 권한 있음')

  await recommendationRow(page, SKU_SLOW).getByLabel(/reject reason/).fill('해당 통로 공사 중')
  await recommendationRow(page, SKU_SLOW).getByRole('button', { name: 'Reject' }).click()
  await expect(recommendationRow(page, SKU_SLOW)).toHaveAttribute('data-recommendation-status', 'REJECTED')

  await recommendationRow(page, SKU_FAST).getByRole('button', { name: 'Approve' }).click()
  await expect(recommendationRow(page, SKU_FAST)).toHaveAttribute('data-recommendation-status', 'APPROVED')
  await expect(page.getByTestId('slotting-notice')).toContainText('아직 배정은 그대로입니다')
  // D7 on screen: approved, and the shelf has not changed.
  await expect(assignmentRow(page, SKU_FAST)).toHaveAttribute('data-assignment-location', LOC_Z20)
  await expect(assignmentRow(page, SKU_FAST).locator('[data-assignment-rank]')).toHaveText('20')
  await shot(page, 'approved-not-yet-applied')

  // ---------------------------------------------------------------
  // 9. Apply. The assignment really moves — rank 20 -> rank 1 — and the row
  //    now says the recommendation is why.
  // ---------------------------------------------------------------
  await recommendationRow(page, SKU_FAST).getByRole('button', { name: 'Apply' }).click()
  await expect(recommendationRow(page, SKU_FAST)).toHaveAttribute('data-recommendation-status', 'APPLIED')
  await expect(assignmentRow(page, SKU_FAST)).toHaveAttribute('data-assignment-location', LOC_A01)
  await expect(assignmentRow(page, SKU_FAST).locator('[data-assignment-rank]')).toHaveText('1')
  await expect(assignmentRow(page, SKU_FAST)).toContainText('SLOTTING_RECOMMENDATION')
  // ...and the screen says out loud that only the record moved.
  await expect(page.getByTestId('slotting-notice')).toContainText('실물 이동은 확인하지 않습니다')
  await shot(page, 'applied-assignment-moved')

  // ---------------------------------------------------------------
  // 10. The paper trail. Both halves of the HITL gate, and the assignment's
  //     previous placement, are in wms.audit_events — there is no separate
  //     assignment-history table by design (D1).
  // ---------------------------------------------------------------
  const commands = psql(`
    select string_agg(distinct command, ',' order by command)
    from wms.audit_events
    where command in ('wms_review_slotting_recommendation',
                      'wms_apply_slotting_recommendation',
                      'wms_generate_slotting_recommendations');`)
  expect(commands).toBe(
    'wms_apply_slotting_recommendation,wms_generate_slotting_recommendations,wms_review_slotting_recommendation',
  )

  const transition = psql(`
    select (before->>'status') || '->' || (after->>'status')
    from wms.audit_events
    where command = 'wms_apply_slotting_recommendation'
      and entity_type = 'slotting_recommendation';`)
  expect(transition).toBe('APPROVED->APPLIED')

  const moved = psql(`
    select (select location_code from wms.storage_locations where id::text = e.before->>'location_id')
        || '->'
        || (select location_code from wms.storage_locations where id::text = e.after->>'location_id')
    from wms.audit_events e
    where e.command = 'wms_apply_slotting_recommendation'
      and e.entity_type = 'sku_location_assignment';`)
  expect(moved).toBe(`${LOC_Z20}->${LOC_A01}`)

  // The contract never touched the ledger. Slotting moves records, not stock.
  const ledgerTouches = psql(`
    select count(*) from wms.stock_ledger_entries
    where source_type not in ('opening_balance', 'receipt', 'disposition',
                              'SLOT-E2E-synthetic-consumption');`)
  expect(ledgerTouches).toBe('0')
})
