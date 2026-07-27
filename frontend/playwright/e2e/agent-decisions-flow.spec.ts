import { test, expect, type Page } from '@playwright/test'
import { execFileSync } from 'node:child_process'
import { mkdirSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

// End-to-end walk of the agentic operations contract
// (openspec/changes/add-agentic-operations).
//
// This area has TWO actors and they are not both human, which is the point.
// Everything the agent does happens OFF the UI — there is no agent screen and
// there never will be one, because the agent does not live in this app. It
// arrives through the MCP tools as the PROCESS_AGENT service identity. So
// psql-as-PROCESS_AGENT (the same JWT-claim trick the verify suite uses, i.e.
// the RPCs see a real PROCESS_AGENT caller and enforce its real role) stands
// in for ProcessGPT here, and everything a HUMAN does happens in the browser:
//
//   agent (off-UI) files a decision + two proposals
//     -> manager (UI) reads the reasoning in the review queue
//     -> manager (UI) confirms one, rejects the other with a note
//     -> the agent (off-UI) is refused when it tries to review its own work
//
// The signal panels are asserted against the real areas 2/4/8 tables, seeded
// here: an imbalanced labor window (area 8) and a stalled work order whose
// only candidate machine is flagged as a bottleneck (areas 2 + 4).
//
// Screenshots taken along the way feed the DOCX operator manual under
// openspec/specs/wms_agentic-operations/docs/.

const DB_CONTAINER = 'supabase_db_process-gpt-sample-app-wms'
const TENANT_A = '10000000-0000-0000-0000-00000000000a'
const WH_A = '20000000-0000-0000-0000-00000000000a'

const REASON_LOGGED =
  'AGENT-E2E: 업무 오더가 41분간 QUEUED 상태였고 대상 구역의 유일한 AGV가 병목으로 판정되어, ' +
  '이미 허용된 wms_retry_work_order_dispatch를 자율 실행했다. 재시도 역시 실패했다.'
const REASON_LABOR =
  'AGENT-E2E: 관찰 기간 동안 inbound-a의 완료 건수가 창고 평균을 크게 웃돌고 quality-a는 크게 밑돈다. ' +
  '오후 적치 작업 일부를 quality-a에게 넘길 것을 제안한다. 재배치 실행 RPC가 없으므로 사람이 수동 조치해야 한다.'
const REASON_ROUTING =
  'AGENT-E2E: AGENT-E2E-AGV-01이 30분 관찰 창 안에서 장애 1건으로 병목 판정되었다. ' +
  '라우팅에서 임시 제외할 것을 제안한다 — 설비 제외는 에이전트 권한 밖이다.'
const REJECT_NOTE = 'AGENT-E2E-반려: 해당 AGV는 예정된 정비 직후라 장애 1건은 정상 범위다.'

const SHOT_DIR = resolve(
  dirname(fileURLToPath(import.meta.url)),
  '../../../openspec/specs/wms_agentic-operations/e2e/screenshots',
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
 * Run SQL with the RPCs seeing `email` as the caller. This is how the agent
 * acts in this suite: not as superuser, but as the PROCESS_AGENT membership,
 * so every role check in the migration is genuinely exercised.
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

/** Same, but tolerating (and returning) the error a refused call raises. */
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
    delete from wms.audit_events
      where entity_type = 'agent_decision'
        and coalesce(after->>'reasoning', before->>'reasoning') like 'AGENT-E2E%';
    delete from wms.agent_decisions where reasoning like 'AGENT-E2E%';
    delete from wms.labor_activities where activity_label like 'AGENT-E2E%';
    delete from wms.wcs_routing_overrides where equipment_id in
      (select id from wms.equipment where equipment_code like 'AGENT-E2E%');
    delete from wms.equipment_commands where equipment_id in
      (select id from wms.equipment where equipment_code like 'AGENT-E2E%');
    delete from wms.equipment_faults where fault_code like 'AGENT-E2E%';
    delete from wms.audit_events where correlation_id like 'AGENT-E2E%';
    delete from wms.work_orders where correlation_id like 'AGENT-E2E%';
    delete from wms.equipment where equipment_code like 'AGENT-E2E%';
    delete from wms.receipts where po_id in
      (select id from wms.purchase_orders where correlation_id like 'AGENT-E2E%');
    delete from wms.purchase_orders where correlation_id like 'AGENT-E2E%';`)
}

/**
 * A work order needs a real linked receipt (area 2 validates it). This suite
 * is not testing the inbound chain, so the PO/receipt pair is planted directly
 * rather than driven through five RPCs that have their own spec file.
 */
function seedLinkedReceipt() {
  psql(`
    with po as (
      insert into wms.purchase_orders (tenant_id, warehouse_id, product_id, qty, status, correlation_id)
      select '${TENANT_A}', '${WH_A}', p.id, 10, 'CONFIRMED_PO', 'AGENT-E2E-PO'
      from wms.products p
      where p.tenant_id = '${TENANT_A}' and p.sku = 'SKU-A-001'
      returning id, tenant_id, warehouse_id, product_id, qty
    )
    insert into wms.receipts (tenant_id, warehouse_id, po_id, product_id, expected_qty, status)
    select tenant_id, warehouse_id, id, product_id, qty, 'EXPECTED' from po;`)
}

/**
 * Area 8 fixture. 24 completions for one worker against the other worker's
 * seeded handful, which puts both well past the 0.40 threshold regardless of
 * what supabase/seed.sql happens to contain.
 *
 * Anchored to D-2, never today and never D-1: these timestamps are computed in
 * the database's UTC while the screen's window is computed in the browser's
 * local time, and those two "days" can be 14 hours apart. D-2 clears the
 * widest possible local-day window (the same trap area 8's own seed comment
 * documents). The panel's default 7-day window still reaches them.
 */
function seedImbalancedLabor() {
  psql(`
    insert into wms.labor_activities (
      tenant_id, warehouse_id, actor_id, actor_role, activity_type, activity_label,
      unit_count, status, started_at, completed_at, created_by, updated_by)
    select '${TENANT_A}', '${WH_A}', u.id, 'INBOUND_OPERATOR', 'RECEIVING',
           'AGENT-E2E-불균형 시드', 10, 'COMPLETED',
           date_trunc('day', now()) - interval '2 days' + make_interval(hours => 6, mins => g * 2),
           date_trunc('day', now()) - interval '2 days' + make_interval(hours => 6, mins => g * 2 + 1),
           u.id, u.id
    from auth.users u
    cross join lateral generate_series(1, 24) g
    where u.email = 'inbound-a@demo.local';`)
}

/**
 * Areas 2 + 4 fixture. A WAVELESS work order created while its zone is empty
 * stays QUEUED (area 2's own NO_EQUIPMENT_AVAILABLE path); the AGV is then
 * registered and given a fault inside area 4's 30-minute observation window,
 * which is exactly how wms.wcs_equipment_bottleneck_status decides
 * is_bottleneck. Backdating updated_at is done as superuser because nothing in
 * the contract lets a caller forge a wait.
 */
function seedStalledWorkOrder() {
  psqlAs('wh-manager-a@demo.local', `
    select wms.wms_create_work_order(
      '${TENANT_A}', '${WH_A}', 'PUTAWAY', 'receipt',
      (select r.id from wms.receipts r
        join wms.purchase_orders po on po.id = r.po_id
       where po.correlation_id = 'AGENT-E2E-PO'),
      'AGV', 'AGENT-E2E-ZONE', 'MOVE', '{"note":"AGENT-E2E"}'::jsonb, 'WAVELESS',
      (select id from auth.users where email = 'wh-manager-a@demo.local'),
      gen_random_uuid(), null, 'AGENT-E2E-WO');
    select wms.wms_register_equipment(
      '${TENANT_A}', '${WH_A}', 'AGENT-E2E-AGV-01', 'AGV', 'AGENT-E2E-ZONE',
      (select id from auth.users where email = 'wh-manager-a@demo.local'),
      gen_random_uuid());`)
  psql(`
    update wms.work_orders set updated_at = now() - interval '41 minutes'
      where correlation_id = 'AGENT-E2E-WO';
    update wms.equipment set status = 'IDLE' where equipment_code = 'AGENT-E2E-AGV-01';
    insert into wms.equipment_faults (tenant_id, warehouse_id, equipment_id, fault_code, severity, status)
    select '${TENANT_A}', '${WH_A}', e.id, 'AGENT-E2E-FAULT', 'WARNING', 'RESOLVED'
    from wms.equipment e where e.equipment_code = 'AGENT-E2E-AGV-01';`)
}

/** The agent's off-UI work: one autonomous decision, two proposals. */
function agentFilesItsWork() {
  const agent = "(select id from auth.users where email = 'process-agent-a@demo.local')"
  psqlAs('process-agent-a@demo.local', `
    select wms.wms_log_agent_decision(
      '${TENANT_A}', '${WH_A}', '${REASON_LOGGED}', ${agent}, gen_random_uuid(),
      'DISPATCH_RETRY', 'work_order',
      (select id from wms.work_orders where correlation_id = 'AGENT-E2E-WO'),
      jsonb_build_object('delayed_work_order_count', 1, 'delay_minutes', 41),
      'AGENT-E2E-CORR-RETRY');
    select wms.wms_propose_agent_action(
      '${TENANT_A}', '${WH_A}', 'LABOR_REBALANCE', '${REASON_LABOR}',
      jsonb_build_object('action', 'MOVE_PUTAWAY_WORKLOAD',
                         'from_actor_email', 'inbound-a@demo.local',
                         'to_actor_email', 'quality-a@demo.local',
                         'suggested_rpc', null,
                         'note', '실행 RPC가 존재하지 않으므로 사람이 수동으로 조치해야 한다'),
      ${agent}, gen_random_uuid(), 'actor',
      (select id from auth.users where email = 'inbound-a@demo.local'),
      jsonb_build_object('imbalance_threshold', 0.40, 'imbalanced_count', 2),
      'AGENT-E2E-CORR-LABOR');
    select wms.wms_propose_agent_action(
      '${TENANT_A}', '${WH_A}', 'EQUIPMENT_ROUTING_SUGGESTION', '${REASON_ROUTING}',
      jsonb_build_object('suggested_rpc', 'wms_exclude_equipment_from_routing',
                         'equipment_code', 'AGENT-E2E-AGV-01',
                         'reason', 'fault frequency exceeded'),
      ${agent}, gen_random_uuid(), 'equipment',
      (select id from wms.equipment where equipment_code = 'AGENT-E2E-AGV-01'),
      null, 'AGENT-E2E-CORR-ROUTING');`)
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

function proposalCard(page: Page, type: string) {
  return page.locator(`div[data-proposal-type="${type}"]`)
}

function decisionRow(page: Page, type: string) {
  return page.locator(`tr[data-decision-type="${type}"]`)
}

// Test 2 reads the state test 1 produced, so run them in order.
test.describe.configure({ mode: 'serial' })

test.beforeAll(() => {
  mkdirSync(SHOT_DIR, { recursive: true })
  resetFixtures()
  seedImbalancedLabor()
  seedLinkedReceipt()
  seedStalledWorkOrder()
  agentFilesItsWork()
})

test.afterAll(() => {
  resetFixtures()
})

test('the manager reviews the agent queue: reads the reasoning, confirms one proposal, rejects another', async ({
  page,
}) => {
  await signIn(page, 'wh-manager-a@demo.local')
  await page.goto('/agent/decisions')
  await expect(page.getByRole('heading', { name: 'Agent Decisions' })).toBeVisible()

  // ---------------------------------------------------------------
  // 1. The queue. Two proposals arrived without anyone in this app doing
  //    anything — they were filed through the RPCs by the PROCESS_AGENT
  //    identity in beforeAll.
  // ---------------------------------------------------------------
  await expect(page.getByTestId('pending-count')).toHaveText('2')
  await expect(proposalCard(page, 'LABOR_REBALANCE')).toBeVisible()
  await expect(proposalCard(page, 'EQUIPMENT_ROUTING_SUGGESTION')).toBeVisible()

  // The reasoning is not hidden behind a details toggle: you cannot review a
  // proposal in this UI without the sentence explaining it being on screen.
  await expect(proposalCard(page, 'LABOR_REBALANCE')).toContainText(
    '재배치 실행 RPC가 없으므로 사람이 수동 조치해야 한다',
  )
  await expect(proposalCard(page, 'EQUIPMENT_ROUTING_SUGGESTION')).toContainText(
    '설비 제외는 에이전트 권한 밖이다',
  )
  // ...and who filed it
  await expect(proposalCard(page, 'LABOR_REBALANCE')).toContainText('process-agent-a@demo.local')
  await shot(page, 'review-queue')

  // ---------------------------------------------------------------
  // 2. The signals the agent was looking at, shown to the human next to the
  //    proposals so the claim can be checked rather than believed.
  // ---------------------------------------------------------------
  await expect(page.getByTestId('balance-scope')).toHaveText('WAREHOUSE')
  const imbalanced = Number(await page.getByTestId('balance-imbalanced').innerText())
  expect(imbalanced).toBeGreaterThanOrEqual(2)
  await expect(
    page.locator('tr[data-balance-actor="inbound-a@demo.local"][data-balance-imbalanced="true"]'),
  ).toBeVisible()

  await expect(page.getByTestId('delay-count')).toHaveText('1')
  const delayRow = page.locator('tr[data-delay-wo]').first()
  await expect(delayRow).toContainText('ALL_ROUTABLE_CANDIDATES_BOTTLENECKED')
  await expect(delayRow).toContainText('AGENT-E2E-ZONE')
  await shot(page, 'signals-the-agent-sees')

  // Raising the threshold past the wait empties the panel — the filter really
  // is the threshold.
  await page.getByLabel('Delay Threshold').fill('120')
  await page.getByRole('button', { name: 'Reload' }).first().click()
  await expect(page.getByTestId('delay-count')).toHaveText('0')
  await page.getByLabel('Delay Threshold').fill('15')
  await page.getByRole('button', { name: 'Reload' }).first().click()
  await expect(page.getByTestId('delay-count')).toHaveText('1')

  // ---------------------------------------------------------------
  // 3. Confirm the labor proposal. The notice has to say that nothing ran,
  //    because a manager who walks away believing the rebalance happened has
  //    been misled by this screen (D7).
  // ---------------------------------------------------------------
  // Fingerprint of everything the proposal might plausibly have touched, so
  // "confirming executes nothing" can be checked rather than assumed.
  const beforeConfirm = psql(`
    select string_agg(t || '=' || n, ' ' order by t) from (
      select 'labor_rows' as t, count(*)::text as n from wms.labor_activities
      union all select 'labor_versions', coalesce(sum(version),0)::text from wms.labor_activities
      union all select 'labor_touched', coalesce(max(updated_at)::text,'-') from wms.labor_activities
      union all select 'work_orders', count(*)::text from wms.work_orders
      union all select 'wo_versions', coalesce(sum(version),0)::text from wms.work_orders
      union all select 'overrides', count(*)::text from wms.wcs_routing_overrides
      union all select 'ledger', count(*)::text from wms.stock_ledger_entries
      union all select 'receipts', count(*)::text from wms.receipts
    ) x;`)

  await proposalCard(page, 'LABOR_REBALANCE').getByRole('button', { name: 'Confirm' }).click()
  await expect(page.getByTestId('agent-notice')).toContainText('CONFIRMED')
  await expect(page.getByTestId('agent-notice')).toContainText('자동 실행되지 않습니다')
  await expect(page.getByTestId('pending-count')).toHaveText('1')
  await expect(proposalCard(page, 'LABOR_REBALANCE')).toHaveCount(0)

  // It moved to history as CONFIRMED, signed by the person who clicked.
  const labourRow = decisionRow(page, 'LABOR_REBALANCE')
  await expect(labourRow).toHaveAttribute('data-decision-status', 'CONFIRMED')
  await expect(labourRow).toContainText('wh-manager-a@demo.local')
  await shot(page, 'proposal-confirmed')

  // The database agrees, and the confirmation carries an identity and a time.
  const confirmed = psql(`
    select status || '|' || (confirmed_by = (select id from auth.users where email = 'wh-manager-a@demo.local'))::text
           || '|' || (confirmed_at is not null)::text || '|' || version
    from wms.agent_decisions where proposal_type = 'LABOR_REBALANCE'
      and reasoning like 'AGENT-E2E%';`)
  expect(confirmed).toBe('CONFIRMED|true|true|2')

  // D7 again, from the other side: confirming executed nothing. The proposal
  // named a workload move; not one labor row was created, closed, reassigned
  // or even version-bumped by the click, and nothing else moved either.
  const afterConfirm = psql(`
    select string_agg(t || '=' || n, ' ' order by t) from (
      select 'labor_rows' as t, count(*)::text as n from wms.labor_activities
      union all select 'labor_versions', coalesce(sum(version),0)::text from wms.labor_activities
      union all select 'labor_touched', coalesce(max(updated_at)::text,'-') from wms.labor_activities
      union all select 'work_orders', count(*)::text from wms.work_orders
      union all select 'wo_versions', coalesce(sum(version),0)::text from wms.work_orders
      union all select 'overrides', count(*)::text from wms.wcs_routing_overrides
      union all select 'ledger', count(*)::text from wms.stock_ledger_entries
      union all select 'receipts', count(*)::text from wms.receipts
    ) x;`)
  expect(afterConfirm).toBe(beforeConfirm)

  // ---------------------------------------------------------------
  // 4. Reject the routing proposal. A reason is mandatory — it is the only
  //    feedback channel this repository has back to whoever writes the agent.
  // ---------------------------------------------------------------
  const routingCard = proposalCard(page, 'EQUIPMENT_ROUTING_SUGGESTION')
  await routingCard.getByRole('button', { name: 'Reject' }).click()
  await expect(page.getByTestId('agent-error')).toContainText('INVALID')
  await expect(page.getByTestId('agent-error')).toContainText('reason is required')
  await expect(page.getByTestId('pending-count')).toHaveText('1')
  await shot(page, 'reject-needs-a-reason')

  await routingCard.getByLabel(/rejection reason/).fill(REJECT_NOTE)
  await routingCard.getByRole('button', { name: 'Reject' }).click()
  await expect(page.getByTestId('agent-notice')).toContainText('REJECTED')
  await expect(page.getByTestId('pending-count')).toHaveText('0')
  await expect(page.getByTestId('pending-empty')).toBeVisible()

  const routingRow = decisionRow(page, 'EQUIPMENT_ROUTING_SUGGESTION')
  await expect(routingRow).toHaveAttribute('data-decision-status', 'REJECTED')
  await expect(routingRow).toContainText(REJECT_NOTE)
  await shot(page, 'proposal-rejected')

  // The machine the proposal wanted excluded is still routable — rejecting a
  // proposal changes nothing either.
  const overrides = psql(`
    select count(*) from wms.wcs_routing_overrides o
    join wms.equipment e on e.id = o.equipment_id
    where e.equipment_code = 'AGENT-E2E-AGV-01' and o.status = 'ACTIVE';`)
  expect(overrides).toBe('0')

  // ---------------------------------------------------------------
  // 5. The LOGGED entry: the agent acted on its own (it was allowed to) and
  //    filed why. It sits in the same history, never enters the queue, and can
  //    never be confirmed.
  // ---------------------------------------------------------------
  const loggedRow = decisionRow(page, 'DISPATCH_RETRY')
  await expect(loggedRow).toHaveAttribute('data-decision-status', 'LOGGED')
  await expect(loggedRow).toContainText('자율 실행했다')
  await expect(loggedRow).toContainText('process-agent-a@demo.local')

  await page.getByLabel('Status Filter').selectOption('LOGGED')
  await expect(page.locator('tr[data-decision-id]')).toHaveCount(1)
  await expect(page.locator('tr[data-decision-status="LOGGED"]')).toHaveCount(1)
  await page.getByLabel('Status Filter').selectOption('PROPOSED')
  await expect(page.locator('tr[data-decision-id]')).toHaveCount(0)
  await page.getByLabel('Status Filter').selectOption('')
  await expect(page.locator('tr[data-decision-id]')).toHaveCount(3)
  await shot(page, 'decision-history')

  // Every write left an audit event with the transition on it.
  const audit = psql(`
    select string_agg(command || ':' || coalesce(before->>'status','-') || '>' || (after->>'status'), ' '
                      order by command)
    from wms.audit_events
    where entity_type = 'agent_decision'
      and coalesce(after->>'reasoning','') like 'AGENT-E2E%';`)
  expect(audit).toBe(
    'wms_confirm_agent_proposal:PROPOSED>CONFIRMED ' +
    'wms_log_agent_decision:->LOGGED ' +
    'wms_propose_agent_action:->PROPOSED wms_propose_agent_action:->PROPOSED ' +
    'wms_reject_agent_proposal:PROPOSED>REJECTED',
  )

  await signOut(page)
})

test('the agent cannot review its own proposals, and an operator sees the log but no buttons', async ({
  page,
}) => {
  // ---------------------------------------------------------------
  // 6. A fresh proposal for the agent to try (and fail) to confirm.
  // ---------------------------------------------------------------
  psqlAs('process-agent-a@demo.local', `
    select wms.wms_propose_agent_action(
      '${TENANT_A}', '${WH_A}', 'LABOR_REBALANCE',
      'AGENT-E2E: 두 번째 재배치 제안 — 에이전트의 자가 승인 시도 대상',
      jsonb_build_object('action', 'MOVE_PUTAWAY_WORKLOAD'),
      (select id from auth.users where email = 'process-agent-a@demo.local'),
      gen_random_uuid());`)

  const decisionId = psql(`
    select id::text from wms.agent_decisions
    where reasoning like 'AGENT-E2E: 두 번째%';`)

  // The agent CAN read everything — all four signal/history RPCs are open to
  // it, including the warehouse-wide balance comparison (D2's exception).
  const agentBalance = psqlAs('process-agent-a@demo.local', `
    select (wms.wms_get_labor_balance_signals(
      '${TENANT_A}', '${WH_A}', now() - interval '7 days', now()))->>'scope';`)
  expect(agentBalance).toBe('WAREHOUSE')

  // ...but its OWN productivity read stays SELF-scoped. The expansion is one
  // RPC wide, not a general promotion.
  const agentProductivity = psqlAs('process-agent-a@demo.local', `
    select (wms.wms_get_labor_productivity(
      '${TENANT_A}', '${WH_A}', now() - interval '7 days', now()))->>'scope';`)
  expect(agentProductivity).toBe('SELF')

  // And it cannot review. Both halves of the human gate, by the real role.
  const confirmAttempt = psqlAsExpectingError('process-agent-a@demo.local', `
    select wms.wms_confirm_agent_proposal(
      '${decisionId}'::uuid,
      (select id from auth.users where email = 'process-agent-a@demo.local'),
      gen_random_uuid(), 1);`)
  expect(confirmAttempt).toContain('FORBIDDEN')
  expect(confirmAttempt).toContain('PROCESS_AGENT may create proposals but not confirm or reject')

  const rejectAttempt = psqlAsExpectingError('process-agent-a@demo.local', `
    select wms.wms_reject_agent_proposal(
      '${decisionId}'::uuid, '스스로 반려',
      (select id from auth.users where email = 'process-agent-a@demo.local'),
      gen_random_uuid(), 1);`)
  expect(rejectAttempt).toContain('FORBIDDEN')

  expect(psql(`select status from wms.agent_decisions where id = '${decisionId}';`)).toBe('PROPOSED')

  // ---------------------------------------------------------------
  // 7. An operator opens the same screen. Full read access to the agent's
  //    reasoning — it is an operational record, not private data — but no
  //    review buttons, and no warehouse-wide labor comparison.
  // ---------------------------------------------------------------
  await signIn(page, 'inbound-a@demo.local')
  await page.goto('/agent/decisions')

  await expect(page.getByTestId('pending-count')).toHaveText('1')
  await expect(proposalCard(page, 'LABOR_REBALANCE')).toContainText('자가 승인 시도 대상')
  await expect(proposalCard(page, 'LABOR_REBALANCE').getByRole('button', { name: 'Confirm' }))
    .toHaveCount(0)
  await expect(proposalCard(page, 'LABOR_REBALANCE').getByRole('button', { name: 'Reject' }))
    .toHaveCount(0)
  await expect(proposalCard(page, 'LABOR_REBALANCE')).toContainText('검토 권한이 없습니다')

  // The history from test 1 is all still readable, decisions and outcomes.
  await expect(page.locator('tr[data-decision-status="CONFIRMED"]')).toHaveCount(1)
  await expect(page.locator('tr[data-decision-status="REJECTED"]')).toHaveCount(1)
  await expect(page.locator('tr[data-decision-status="LOGGED"]')).toHaveCount(1)

  // The balance panel is not rendered at all rather than rendering a FORBIDDEN
  // banner over a page that is otherwise working.
  await expect(page.getByTestId('balance-scope')).toHaveCount(0)
  await expect(page.getByText('창고 전체 작업자를 비교하는 정보이기 때문입니다')).toBeVisible()
  // The dispatch signal, which has no privacy dimension, is still there.
  await expect(page.getByTestId('delay-count')).toHaveText('1')
  await shot(page, 'operator-read-only')

  // The screen matches the database: clicking is not the thing being blocked,
  // the RPC is.
  const operatorAttempt = psqlAsExpectingError('inbound-a@demo.local', `
    select wms.wms_confirm_agent_proposal(
      '${decisionId}'::uuid,
      (select id from auth.users where email = 'inbound-a@demo.local'),
      gen_random_uuid(), 1);`)
  expect(operatorAttempt).toContain('FORBIDDEN')
  expect(operatorAttempt).toContain('role cannot review agent proposals')
})
