import { test, expect, type Page } from '@playwright/test'
import { execFileSync } from 'node:child_process'
import { mkdirSync, readFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

// End-to-end walk of the natural-language audit log contract
// (openspec/changes/add-operations-audit-log).
//
// This is the eleventh area and the only one whose screen shows nothing it
// produced itself. Every row it displays was written by some OTHER area's RPC.
// So the test is built the same way round: it does real work first, through
// the real UI, and only then opens the audit log to see whether that work can
// be read back as Korean sentences.
//
//   admin (UI, Dock Schedule) registers a dock, then closes it for maintenance
//     -> two genuine wms.audit_events rows, one creation and one transition
//   agent (off-UI, as PROCESS_AGENT) raises an RFQ and files its reasoning
//     under the same correlation_id
//     -> the D3 join has something real to join
//   auditor (UI, Audit Log) reads all of it, filters it, sees the agent's own
//     reasoning next to the action it justified, and exports it to CSV
//     -> and the export shows up in the log as an event of its own
//   buyer (UI + RPC) cannot get in by any of the three doors
//
// Nothing here plants an audit event directly except the 30-row pagination
// fixture, which is labelled as such: the point of this suite is that the
// summaries describe things that actually happened.
//
// Screenshots taken along the way feed the DOCX operator manual under
// openspec/specs/wms_operations-audit-log/docs/.

const DB_CONTAINER = 'supabase_db_process-gpt-sample-app-wms'
const TENANT_A = '10000000-0000-0000-0000-00000000000a'
const WH_A = '20000000-0000-0000-0000-00000000000a'

const DOCK_CODE = 'AUDIT-E2E-DOCK-01'
const DOCK_NAME = 'AUDIT-E2E 감사용 하역장'
const CORR_AGENT = 'AUDIT-E2E-CORR-AGENT'
const CORR_PAGE = 'AUDIT-E2E-PAGE'
const AGENT_REASON =
  'AUDIT-E2E: SKU-A-001 가용 재고가 재주문점 아래로 내려갔고 미착 발주가 없어, ' +
  '이미 허용된 wms_create_rfq를 자율 실행해 부족분을 채우는 구매 요청을 만들었다.'

const SHOT_DIR = resolve(
  dirname(fileURLToPath(import.meta.url)),
  '../../../openspec/specs/wms_operations-audit-log/e2e/screenshots',
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

/**
 * Run SQL with the RPCs seeing `email` as the caller — not as superuser, so
 * every wms.has_role() check in the migrations is genuinely exercised. This is
 * how the agent acts here (it has no screen) and how the buyer's refusal is
 * proved in test 2.
 */
function psqlAs(email: string, sql: string): string {
  return psql(`
    do $$ begin
      perform set_config('request.jwt.claims',
        json_build_object('sub', (select id::text from auth.users where email = '${email}'),
                          'role', 'authenticated')::text, false);
    end $$;
    ${sql}`)
}

function psqlAsExpectingError(email: string, sql: string): string {
  try {
    psqlAs(email, sql)
    return 'NO_ERROR'
  } catch (e: any) {
    return String(e.stderr ?? e.message ?? e)
  }
}

function resetFixtures() {
  psql(`
    delete from wms.audit_events where correlation_id like 'AUDIT-E2E-%';
    delete from wms.audit_events where command = 'wms_export_audit_log'
      and after->>'correlation_id' like 'AUDIT-E2E-%';
    delete from wms.audit_events where entity_id in
      (select id from wms.docks where code like 'AUDIT-E2E-%');
    delete from wms.agent_decisions where reasoning like 'AUDIT-E2E%';
    delete from wms.dock_appointments where dock_id in
      (select id from wms.docks where code like 'AUDIT-E2E-%');
    delete from wms.docks where code like 'AUDIT-E2E-%';
    delete from wms.audit_events where entity_id in
      (select id from wms.purchase_orders where correlation_id like 'AUDIT-E2E-%');
    delete from wms.receipts where po_id in
      (select id from wms.purchase_orders where correlation_id like 'AUDIT-E2E-%');
    delete from wms.purchase_orders where correlation_id like 'AUDIT-E2E-%';`)
}

/**
 * The agent's off-UI work. It calls a REAL, already-permitted RPC
 * (wms_create_rfq is on the PROCESS_AGENT allowlist) and then files its
 * reasoning under the SAME correlation_id, which is the join
 * add-agentic-operations D5 promised this contract and this contract consumes.
 */
function agentActsAndExplains() {
  const agent = "(select id from auth.users where email = 'process-agent-a@demo.local')"
  psqlAs('process-agent-a@demo.local', `
    select wms.wms_create_rfq(
      '${TENANT_A}', '${WH_A}', 'SKU-A-001', 90,
      (select id from wms.suppliers where tenant_id = '${TENANT_A}' order by name limit 1),
      ${agent}, gen_random_uuid(), '${CORR_AGENT}');
    select wms.wms_log_agent_decision(
      '${TENANT_A}', '${WH_A}', '${AGENT_REASON}', ${agent}, gen_random_uuid(),
      'REPLENISHMENT', 'purchase_order',
      (select id from wms.purchase_orders where correlation_id = '${CORR_AGENT}'),
      jsonb_build_object('available_qty', 30, 'reorder_min', 50),
      '${CORR_AGENT}');`)
}

/**
 * 30 synthetic events purely so the paginator has more than one page to turn.
 * This is the ONE place in this suite that writes wms.audit_events directly —
 * driving 30 real RPCs would test the eleventh area's pagination by way of the
 * first area's state machine, which is not a trade worth making.
 */
function seedPaginationFixture() {
  psql(`
    insert into wms.audit_events
      (tenant_id, actor_id, command, entity_type, entity_id, after, correlation_id, created_at)
    select '${TENANT_A}',
           (select id from auth.users where email = 'inbound-a@demo.local'),
           'wms_receive', 'receipt', gen_random_uuid(),
           jsonb_build_object('status','QC_PENDING','received_qty',g,'expected_qty',g),
           '${CORR_PAGE}', now() - make_interval(secs => g)
    from generate_series(1, 30) g;`)
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

function auditRow(page: Page, command: string) {
  return page.locator(`tr[data-command="${command}"]`)
}

async function search(page: Page) {
  await page.getByRole('button', { name: 'Search' }).click()
  await expect(page.getByRole('button', { name: 'Search' })).toBeEnabled()
}

test.describe.configure({ mode: 'serial' })

test.beforeAll(() => {
  mkdirSync(SHOT_DIR, { recursive: true })
  resetFixtures()
  agentActsAndExplains()
  seedPaginationFixture()
})

test.afterAll(() => {
  resetFixtures()
})

test('an admin does real work, then an auditor reads it back as Korean sentences, filters it, sees the agent reasoning and exports it', async ({
  page,
}) => {
  // ---------------------------------------------------------------
  // 1. Two genuine auditable actions, through the real screen. Neither of
  //    them knows this contract exists — they write wms.audit_events because
  //    every write RPC in this repo has always written wms.audit_events.
  // ---------------------------------------------------------------
  await signIn(page, 'admin-a@demo.local')
  await page.goto('/inbound/dock-schedule')
  await expect(page.getByRole('heading', { name: 'Dock Schedule' })).toBeVisible()

  await page.getByLabel('Dock Code').fill(DOCK_CODE)
  await page.getByLabel('Dock Name').fill(DOCK_NAME)
  await page.getByRole('button', { name: 'Register Dock' }).click()
  const dockRow = page.locator(`tr[data-dock-code="${DOCK_CODE}"]`)
  await expect(dockRow).toBeVisible()
  await expect(dockRow).toContainText('AVAILABLE')

  // ...and a status transition, so the summary templates have a before AND an
  // after to render as "A → B" rather than just a value.
  await dockRow.getByRole('button', { name: `close ${DOCK_CODE}` }).click()
  await expect(dockRow).toContainText('CLOSED')
  await shot(page, 'the-work-being-audited')

  // The admin never visits the audit log in this run; the auditor does.
  await signOut(page)

  // ---------------------------------------------------------------
  // 2. The auditor. A different person, a different role, a screen the admin
  //    could also reach but did not.
  // ---------------------------------------------------------------
  await signIn(page, 'auditor-a@demo.local')
  await expect(page.getByRole('link', { name: 'Audit Log' })).toBeVisible()
  await page.getByRole('link', { name: 'Audit Log' }).click()
  await expect(page).toHaveURL(/operations\/audit-log/)
  await expect(page.getByRole('heading', { name: 'Audit Log' })).toBeVisible()

  // The two actions from step 1, as sentences. Note what is being asserted:
  // not that a row exists, but that the row SAYS what happened — the dock's
  // own code, and the transition it went through.
  await expect(auditRow(page, 'wms_register_dock')).toContainText(
    `도크 ${DOCK_CODE}(${DOCK_NAME})가 등록되었다`,
  )
  await expect(auditRow(page, 'wms_set_dock_status')).toContainText(
    `도크 ${DOCK_CODE}의 상태가 변경되었다 — AVAILABLE → CLOSED`,
  )
  await expect(auditRow(page, 'wms_register_dock')).toContainText('admin-a@demo.local')
  await shot(page, 'audit-log-in-korean')

  const totalBefore = Number(await page.getByTestId('audit-total').innerText())
  expect(totalBefore).toBeGreaterThan(30)

  // ---------------------------------------------------------------
  // 3. Filter by command. The dropdown is populated from the tenant's real
  //    command vocabulary, not a hard-coded list.
  // ---------------------------------------------------------------
  await page.getByLabel('Command Filter').selectOption('wms_set_dock_status')
  await search(page)
  await expect(page.locator('tbody tr')).toHaveCount(1)
  await expect(auditRow(page, 'wms_set_dock_status')).toBeVisible()
  await expect(auditRow(page, 'wms_register_dock')).toHaveCount(0)
  await shot(page, 'filtered-by-command')

  // Every option in the command dropdown is a command this tenant has really
  // run, so none of them can come back empty — the facets are built from the
  // log itself. A filter that matches nothing therefore has to come from a
  // free-text field, and when it does the page says so instead of showing a
  // stale result set.
  await page.getByLabel('Correlation Id Filter').fill('AUDIT-E2E-NO-SUCH-CORRELATION')
  await search(page)
  await expect(page.getByTestId('audit-empty')).toBeVisible()
  await expect(page.getByTestId('audit-total')).toHaveText('0')
  await page.getByLabel('Correlation Id Filter').fill('')

  // ---------------------------------------------------------------
  // 4. The agent's reasoning, joined in by correlation_id (D3 / stage 2).
  //    The agent called wms_create_rfq and separately filed WHY; the audit log
  //    is where those two halves meet.
  // ---------------------------------------------------------------
  await page.getByLabel('Command Filter').selectOption('')
  await page.getByLabel('Correlation Id Filter').fill(CORR_AGENT)
  await search(page)

  const rfqRow = auditRow(page, 'wms_create_rfq')
  await expect(rfqRow).toHaveAttribute('data-has-reasoning', 'true')
  await expect(rfqRow).toContainText('구매 요청(RFQ)이 생성되었다 — 수량 90')
  await expect(rfqRow).toContainText('에이전트 판단 근거')
  await expect(rfqRow).toContainText('이미 허용된 wms_create_rfq를 자율 실행해')
  await expect(rfqRow).toContainText('process-agent-a@demo.local')
  // The summary sentence itself carries the reason, not just the panel beside it.
  await expect(rfqRow).toContainText('(사유: AUDIT-E2E:')
  await expect(page.getByTestId('audit-reasoning-count')).not.toHaveText('0')
  await shot(page, 'agent-reasoning-joined')

  // ---------------------------------------------------------------
  // 5. Pagination. 30 events under one correlation id, 20 to a page.
  // ---------------------------------------------------------------
  await page.getByLabel('Correlation Id Filter').fill(CORR_PAGE)
  await search(page)
  await expect(page.getByTestId('audit-total')).toHaveText('30')
  await expect(page.getByTestId('audit-rowcount')).toHaveText('20')
  await expect(page.getByTestId('audit-page')).toHaveText('1')

  await page.getByTestId('audit-next').click()
  await expect(page.getByTestId('audit-page')).toHaveText('2')
  await expect(page.getByTestId('audit-rowcount')).toHaveText('10')
  // The total survives the page turn — it is counted, not inferred from the
  // rows on screen.
  await expect(page.getByTestId('audit-total')).toHaveText('30')
  await expect(page.getByTestId('audit-next')).toBeDisabled()
  await shot(page, 'pagination-last-page')

  // ---------------------------------------------------------------
  // 6. Export. The file is real; so is the record that it was taken.
  // ---------------------------------------------------------------
  const exportsBefore = Number(
    psql(`select count(*) from wms.audit_events where command = 'wms_export_audit_log';`),
  )

  const [download] = await Promise.all([
    page.waitForEvent('download'),
    page.getByTestId('audit-export').click(),
  ])
  const csv = readFileSync(await download.path(), 'utf8')
  const csvLines = csv.trim().split('\r\n')
  expect(csvLines[0]).toContain('summary_ko')
  expect(csvLines).toHaveLength(31) // header + 30 rows, the whole filtered set
  expect(csv).toContain('입고 수량이 확정되었다')

  await expect(page.getByTestId('audit-notice')).toContainText('30건을 CSV로 내보냈습니다')
  await expect(page.getByTestId('audit-notice')).toContainText('감사 이벤트로 기록되었습니다')

  const exportsAfter = Number(
    psql(`select count(*) from wms.audit_events where command = 'wms_export_audit_log';`),
  )
  expect(exportsAfter).toBe(exportsBefore + 1)

  // ...and the auditor can see their own download in the log, described in the
  // same Korean the rest of the page is written in. It carries the filter that
  // was used, which is the part a finance reviewer actually cares about.
  await page.getByLabel('Correlation Id Filter').fill('')
  await page.getByLabel('Command Filter').selectOption('wms_export_audit_log')
  await search(page)
  const exportRow = auditRow(page, 'wms_export_audit_log').first()
  await expect(exportRow).toContainText('감사 로그 30건이 내보내졌다')
  await expect(exportRow).toContainText('auditor-a@demo.local')
  await shot(page, 'the-export-audits-itself')

  // ---------------------------------------------------------------
  // 7. The date filter is a real filter, not decoration.
  // ---------------------------------------------------------------
  const tomorrow = new Date(Date.now() + 86_400_000).toISOString().slice(0, 10)
  await page.getByLabel('Command Filter').selectOption('')
  await page.getByLabel('Date From').fill(tomorrow)
  await search(page)
  await expect(page.getByTestId('audit-total')).toHaveText('0')

  await page.getByRole('button', { name: 'Reset' }).click()
  await expect(page.getByTestId('audit-total')).not.toHaveText('0')
})

test('a role outside WMS_ADMIN / AUDITOR cannot reach the audit log by nav, by URL, or by RPC', async ({
  page,
}) => {
  await signIn(page, 'buyer-a@demo.local')

  // Door 1: the nav link is not rendered.
  await expect(page.getByRole('link', { name: 'Audit Log' })).toHaveCount(0)
  await shot(page, 'buyer-has-no-audit-nav')

  // Door 2: typing the URL bounces back to the overview.
  await page.goto('/operations/audit-log')
  await expect(page).toHaveURL(/overview/)
  await expect(page.getByRole('heading', { name: 'Audit Log' })).toHaveCount(0)

  // Door 3 — the only one that is actually a control. Skipping the browser
  // entirely and calling the RPCs as this user still fails, which is why the
  // first two doors are described as courtesies in the view's own comments.
  const queryError = psqlAsExpectingError(
    'buyer-a@demo.local',
    `select wms.wms_query_audit_log('${TENANT_A}');`,
  )
  expect(queryError).toContain('FORBIDDEN')
  expect(queryError).toContain('WMS_ADMIN or AUDITOR required')

  const exportError = psqlAsExpectingError(
    'buyer-a@demo.local',
    `select wms.wms_export_audit_log('${TENANT_A}');`,
  )
  expect(exportError).toContain('FORBIDDEN')

  // ...while the pre-existing, wider read on the raw table is untouched: the
  // same user still sees their tenant's audit events straight from the table.
  // Narrowing that policy would have broken other screens, so this contract
  // did not (design.md D2).
  const rawVisible = Number(
    psql(`
      begin;
      do $$ begin
        perform set_config('request.jwt.claims',
          json_build_object('sub', (select id::text from auth.users where email = 'buyer-a@demo.local'),
                            'role', 'authenticated')::text, false);
      end $$;
      set local role authenticated;
      select count(*) from wms.audit_events where tenant_id = '${TENANT_A}';
      commit;`),
  )
  expect(rawVisible).toBeGreaterThan(0)
})
