<script setup lang="ts">
import { ref, computed, onMounted, watch } from 'vue'
import { useAuthStore } from '@/stores/auth'
import { supabase } from '@/lib/supabase'

// Agentic operations (openspec change add-agentic-operations).
//
// This screen exists because the contract's whole point is a HUMAN in the
// loop, and a human in the loop needs somewhere to stand. There is no agent
// running inside this app — everything on this page was either written by an
// external ProcessGPT agent through the MCP tools, or is a read-only signal
// that such an agent would be looking at.
//
// Three bands, in the order a reviewer actually works:
//
//   1. 검토 대기 제안 — the queue. Confirm or reject, with the agent's own
//      natural-language reasoning and the signal snapshot it was looking at
//      shown inline. You cannot review a proposal without reading why it was
//      made, because the reasoning is the row.
//   2. 판단·제안 이력 — everything, filterable. LOGGED entries (the agent
//      acted on its own and filed why) sit next to proposals so the audit
//      question "what has this agent been doing" has one answer.
//   3. 에이전트가 보는 신호 — the same two read RPCs the agent calls, so a
//      human can check the agent's homework rather than taking its word.
//
// The confirm/reject buttons are only rendered for WAREHOUSE_MANAGER /
// WMS_ADMIN. That is a courtesy, not the control: the RPCs return FORBIDDEN
// for everyone else, PROCESS_AGENT explicitly included.

const auth = useAuthStore()

const decisions = ref<any>(null)
const balance = ref<any>(null)
const delay = ref<any>(null)

const loading = ref(false)
const error = ref('')
const notice = ref('')
const submitting = ref<string | null>(null)

const statusFilter = ref('')
const typeFilter = ref('')
const rejectNotes = ref<Record<string, string>>({})
const delayThreshold = ref('15')
const balanceDays = ref('7')

// D6: the review gate. Everyone else gets the read-only view.
const canReview = computed(() =>
  ['WMS_ADMIN', 'WAREHOUSE_MANAGER'].includes(auth.currentRole ?? ''),
)
// D2's deliberate exception: the agent identity is on this list precisely
// because comparing workers is the point of the signal.
const canSeeBalance = computed(() =>
  ['WMS_ADMIN', 'WAREHOUSE_MANAGER', 'PROCESS_AGENT'].includes(auth.currentRole ?? ''),
)

const pending = computed(() =>
  (decisions.value?.rows ?? []).filter((d: any) => d.status === 'PROPOSED'),
)
const historyRows = computed(() => decisions.value?.rows ?? [])
const statusCounts = computed(() => decisions.value?.status_counts ?? {})
const balanceRows = computed(() => balance.value?.rows ?? [])
const delayRows = computed(() => delay.value?.rows ?? [])

function statusClass(status: string) {
  if (status === 'CONFIRMED') return 'ok'
  if (status === 'REJECTED') return 'danger'
  if (status === 'PROPOSED') return 'warn'
  return ''
}

function shortId(id: string | null) {
  return id ? id.slice(0, 8) : '—'
}

function when(ts: string | null) {
  if (!ts) return '—'
  return new Date(ts).toLocaleString('ko-KR', { hour12: false })
}

function pretty(value: unknown) {
  if (value === null || value === undefined) return '—'
  return JSON.stringify(value, null, 2)
}

async function load() {
  if (!auth.currentTenantId || !auth.currentWarehouseId) return
  loading.value = true
  error.value = ''
  try {
    const { data: hist, error: histError } = await supabase.rpc('wms_get_agent_decisions', {
      p_tenant_id: auth.currentTenantId,
      p_warehouse_id: auth.currentWarehouseId,
      p_status: statusFilter.value || null,
      p_proposal_type: typeFilter.value || null,
    })
    if (histError) throw histError
    decisions.value = hist

    // The delay signal is open to every warehouse member.
    const { data: dly, error: dlyError } = await supabase.rpc('wms_get_dispatch_delay_signals', {
      p_tenant_id: auth.currentTenantId,
      p_warehouse_id: auth.currentWarehouseId,
      p_wave_id: null,
      p_delay_threshold_minutes: Number(delayThreshold.value),
    })
    if (dlyError) throw dlyError
    delay.value = dly

    // The balance signal is not. Asking anyway would paint a FORBIDDEN banner
    // over a page that is otherwise working, so the screen does not ask.
    if (canSeeBalance.value) {
      const end = new Date()
      const start = new Date(end.getTime() - Number(balanceDays.value) * 86_400_000)
      const { data: bal, error: balError } = await supabase.rpc('wms_get_labor_balance_signals', {
        p_tenant_id: auth.currentTenantId,
        p_warehouse_id: auth.currentWarehouseId,
        p_period_start: start.toISOString(),
        p_period_end: end.toISOString(),
      })
      if (balError) throw balError
      balance.value = bal
    } else {
      balance.value = null
    }
  } catch (e: any) {
    error.value = e.message ?? String(e)
  } finally {
    loading.value = false
  }
}

async function run(key: string, fn: () => Promise<void>) {
  submitting.value = key
  error.value = ''
  notice.value = ''
  try {
    await fn()
    await load()
  } catch (e: any) {
    error.value = e.message ?? String(e)
  } finally {
    submitting.value = null
  }
}

function confirmProposal(d: any) {
  return run(d.decision_id, async () => {
    const { data, error: rpcError } = await supabase.rpc('wms_confirm_agent_proposal', {
      p_decision_id: d.decision_id,
      p_actor_id: auth.userId,
      p_idempotency_key: crypto.randomUUID(),
      p_expected_version: d.version,
      p_correlation_id: d.correlation_id,
    })
    if (rpcError) throw rpcError
    // D7 said out loud on the screen too: approving is a signature, not a run
    // button. If the operator now walks away thinking the robot moved, the UI
    // lied to them.
    notice.value =
      `제안을 승인했습니다 (${data?.status}) — 승인은 상태 전이일 뿐이며 제안된 조치는 ` +
      `자동 실행되지 않습니다. 실제 조치는 사람이 직접 수행하거나 다음 프로세스 단계가 호출합니다.`
  })
}

function rejectProposal(d: any) {
  return run(d.decision_id, async () => {
    const reason = (rejectNotes.value[d.decision_id] ?? '').trim()
    const { data, error: rpcError } = await supabase.rpc('wms_reject_agent_proposal', {
      p_decision_id: d.decision_id,
      p_reason: reason || null,
      p_actor_id: auth.userId,
      p_idempotency_key: crypto.randomUUID(),
      p_expected_version: d.version,
      p_correlation_id: d.correlation_id,
    })
    if (rpcError) throw rpcError
    delete rejectNotes.value[d.decision_id]
    notice.value = `제안을 반려했습니다 (${data?.status}) — 사유가 이력에 남습니다.`
  })
}

onMounted(load)
watch(() => auth.currentWarehouseId, load)
watch(() => [statusFilter.value, typeFilter.value], load)
</script>

<template>
  <div>
    <h1>Agent Decisions</h1>
    <p class="hint">
      ProcessGPT 쪽에서 실행되는 외부 에이전트가 남긴 판단·제안을 사람이 검토하는 화면입니다.
      이 앱 안에는 에이전트가 없습니다 — 여기 보이는 것은 에이전트가 MCP 도구로 남긴 기록과,
      에이전트가 보고 있는 것과 똑같은 읽기 신호뿐입니다.
      현재 역할: {{ auth.currentRole }}
    </p>
    <div v-if="error" class="error-banner" data-testid="agent-error">{{ error }}</div>
    <div v-if="notice" class="notice-banner" data-testid="agent-notice">{{ notice }}</div>

    <!-- ---------------------------------------------------------------- -->
    <h2 class="board-title">
      검토 대기 제안
      <span class="status warn" data-testid="pending-count">{{ pending.length }}</span>
    </h2>
    <p class="hint">
      에이전트가 자율 실행할 수 없는 조치는 여기에 제안으로만 쌓입니다.
      <b>승인해도 시스템이 그 조치를 자동으로 실행하지 않습니다</b> — 승인은 상태 전이일 뿐입니다.
      <template v-if="!canReview">
        승인·반려는 WAREHOUSE_MANAGER / WMS_ADMIN만 할 수 있습니다.
      </template>
    </p>

    <div
      v-for="d in pending"
      :key="d.decision_id"
      class="card proposal"
      :data-proposal-id="d.decision_id"
      :data-proposal-type="d.proposal_type"
    >
      <div class="proposal-head">
        <span class="status warn">{{ d.proposal_type }}</span>
        <span class="hint">
          {{ d.created_by_email ?? shortId(d.created_by) }} · {{ when(d.created_at) }} ·
          v{{ d.version }}
        </span>
      </div>
      <p class="reasoning" data-testid="proposal-reasoning">{{ d.reasoning }}</p>
      <details>
        <summary>제안된 조치 (자동 실행되지 않음)</summary>
        <pre class="json">{{ pretty(d.proposed_action) }}</pre>
      </details>
      <details v-if="d.signals_snapshot">
        <summary>판단 시점의 신호 스냅샷</summary>
        <pre class="json">{{ pretty(d.signals_snapshot) }}</pre>
      </details>
      <div v-if="canReview" class="row actions">
        <input
          v-model="rejectNotes[d.decision_id]"
          class="reason"
          :aria-label="`rejection reason for ${d.proposal_type}`"
          placeholder="반려 사유 (반려 시 필수)"
        />
        <button
          class="primary"
          :disabled="submitting === d.decision_id"
          :aria-label="`confirm ${d.proposal_type}`"
          @click="confirmProposal(d)"
        >
          Confirm
        </button>
        <button
          class="primary danger"
          :disabled="submitting === d.decision_id"
          :aria-label="`reject ${d.proposal_type}`"
          @click="rejectProposal(d)"
        >
          Reject
        </button>
      </div>
      <p v-else class="hint">검토 권한이 없습니다 — 읽기만 가능합니다.</p>
    </div>
    <p v-if="!loading && pending.length === 0" data-testid="pending-empty">
      검토를 기다리는 제안이 없습니다.
    </p>

    <!-- ---------------------------------------------------------------- -->
    <h2 class="board-title">판단·제안 이력</h2>
    <p class="hint">
      <span data-testid="status-counts">{{ pretty(statusCounts) }}</span>
      — 이 숫자는 필터와 무관하게 창고 전체를 셉니다.
      <code>LOGGED</code>는 에이전트가 이미 허용된 액션을 직접 실행하고 근거만 남긴 항목이고,
      나머지 셋은 제안의 생명주기입니다.
    </p>
    <div class="card filter-card">
      <div class="row">
        <label>
          Status
          <select v-model="statusFilter" aria-label="Status Filter">
            <option value="">(전체)</option>
            <option value="LOGGED">LOGGED</option>
            <option value="PROPOSED">PROPOSED</option>
            <option value="CONFIRMED">CONFIRMED</option>
            <option value="REJECTED">REJECTED</option>
          </select>
        </label>
        <label>
          Proposal Type
          <select v-model="typeFilter" aria-label="Proposal Type Filter">
            <option value="">(전체)</option>
            <option value="DISPATCH_RETRY">DISPATCH_RETRY</option>
            <option value="LABOR_REBALANCE">LABOR_REBALANCE</option>
            <option value="EQUIPMENT_ROUTING_SUGGESTION">EQUIPMENT_ROUTING_SUGGESTION</option>
          </select>
        </label>
        <button class="primary" @click="load">Refresh</button>
      </div>
    </div>
    <table>
      <thead>
        <tr>
          <th>Status</th>
          <th>Type</th>
          <th>Reasoning</th>
          <th>Filed by</th>
          <th>Reviewed by</th>
          <th>When</th>
        </tr>
      </thead>
      <tbody>
        <tr
          v-for="d in historyRows"
          :key="d.decision_id"
          :data-decision-id="d.decision_id"
          :data-decision-status="d.status"
          :data-decision-type="d.proposal_type"
        >
          <td><span class="status" :class="statusClass(d.status)">{{ d.status }}</span></td>
          <td>{{ d.proposal_type }}</td>
          <td class="reasoning-cell">{{ d.reasoning }}</td>
          <td>{{ d.created_by_email ?? shortId(d.created_by) }}</td>
          <td>
            <template v-if="d.status === 'CONFIRMED'">
              {{ d.confirmed_by_email ?? shortId(d.confirmed_by) }}
            </template>
            <template v-else-if="d.status === 'REJECTED'">
              {{ d.rejected_by_email ?? shortId(d.rejected_by) }}
              <span class="hint block">{{ d.rejection_reason }}</span>
            </template>
            <template v-else>—</template>
          </td>
          <td>{{ when(d.created_at) }}</td>
        </tr>
      </tbody>
    </table>
    <p v-if="!loading && historyRows.length === 0">해당 조건의 판단·제안 이력이 없습니다.</p>

    <!-- ---------------------------------------------------------------- -->
    <h2 class="board-title">에이전트가 보는 신호</h2>
    <p class="hint">
      아래 두 패널은 에이전트가 호출하는 것과 완전히 같은 읽기 RPC입니다 — 제안이 타당한지
      사람이 직접 확인할 수 있도록 나란히 둡니다.
    </p>

    <div class="card signal-card">
      <div class="row head">
        <h3>인력 작업량 불균형</h3>
        <label>
          관찰 기간(일)
          <input v-model="balanceDays" type="number" min="1" aria-label="Balance Days" />
        </label>
        <button class="primary" @click="load">Reload</button>
      </div>
      <template v-if="!canSeeBalance">
        <p class="hint">
          이 신호는 WAREHOUSE_MANAGER / WMS_ADMIN / PROCESS_AGENT만 조회할 수 있습니다 —
          창고 전체 작업자를 비교하는 정보이기 때문입니다.
        </p>
      </template>
      <template v-else-if="balance">
        <p class="hint" data-testid="balance-summary">
          scope <b data-testid="balance-scope">{{ balance.scope }}</b> ·
          평균 <b data-testid="balance-mean">{{ balance.mean_completed_count }}</b>건 ·
          임계값 {{ balance.imbalance_threshold }} ·
          불균형 <b data-testid="balance-imbalanced">{{ balance.imbalanced_count }}</b>명 ·
          작업자 {{ balance.worker_count }}명
          <span v-for="n in balance.notes" :key="n" class="status warn">{{ n }}</span>
        </p>
        <table>
          <thead>
            <tr>
              <th>Worker</th>
              <th>Role</th>
              <th>Completed</th>
              <th>Deviation</th>
              <th>Direction</th>
              <th>Imbalanced</th>
            </tr>
          </thead>
          <tbody>
            <tr
              v-for="r in balanceRows"
              :key="r.actor_id"
              :data-balance-actor="r.actor_email"
              :data-balance-imbalanced="String(r.is_imbalanced)"
            >
              <td>{{ r.actor_email }}</td>
              <td>{{ r.actor_role }}</td>
              <td>{{ r.completed_count }}</td>
              <td>{{ (Number(r.deviation_ratio) * 100).toFixed(1) }}%</td>
              <td>{{ r.direction }}</td>
              <td>
                <span class="status" :class="r.is_imbalanced ? 'danger' : 'ok'">
                  {{ r.is_imbalanced ? 'YES' : 'no' }}
                </span>
              </td>
            </tr>
          </tbody>
        </table>
        <p v-if="balanceRows.length === 0" class="hint">해당 기간에 완료된 활동이 없습니다.</p>
      </template>
    </div>

    <div class="card signal-card">
      <div class="row head">
        <h3>디스패치 지연</h3>
        <label>
          지연 임계(분)
          <input v-model="delayThreshold" type="number" min="0" aria-label="Delay Threshold" />
        </label>
        <button class="primary" @click="load">Reload</button>
      </div>
      <p v-if="delay" class="hint" data-testid="delay-summary">
        QUEUED {{ delay.queued_work_order_count }}건 중
        임계 초과 <b data-testid="delay-count">{{ delay.delayed_work_order_count }}</b>건
        (임계 {{ delay.delay_threshold_minutes }}분)
        <span v-for="n in delay.notes" :key="n" class="status warn">{{ n }}</span>
      </p>
      <table>
        <thead>
          <tr>
            <th>Work Order</th>
            <th>Equipment</th>
            <th>Zone</th>
            <th>Waiting</th>
            <th>Candidates</th>
            <th>Causes</th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="r in delayRows" :key="r.work_order_id" :data-delay-wo="r.work_order_id">
            <td class="mono">{{ shortId(r.work_order_id) }}</td>
            <td>{{ r.equipment_type }}</td>
            <td>{{ r.zone_code ?? '(any)' }}</td>
            <td>{{ r.delay_minutes }}분</td>
            <td>
              {{ r.routable_candidate_count }} / {{ r.candidate_equipment_count }}
              <span v-if="r.bottleneck_candidate_count > 0" class="status danger">
                병목 {{ r.bottleneck_candidate_count }}
              </span>
            </td>
            <td>
              <span v-for="c in r.delay_causes" :key="c" class="status danger cause">{{ c }}</span>
            </td>
          </tr>
        </tbody>
      </table>
      <p v-if="!loading && delayRows.length === 0" class="hint">
        임계 시간을 넘긴 업무 오더가 없습니다.
      </p>
    </div>
  </div>
</template>

<style scoped>
.hint {
  color: var(--muted);
  margin-top: -0.5rem;
}
.hint.block {
  display: block;
  margin: 0;
  font-size: 0.8rem;
}
h2 {
  font-size: 1rem;
  margin: 0 0 0.25rem;
}
h3 {
  font-size: 0.95rem;
  margin: 0;
}
.board-title {
  margin: 1.5rem 0 0.5rem;
  display: flex;
  align-items: center;
  gap: 0.5rem;
}
.row {
  display: flex;
  gap: 0.5rem;
  align-items: flex-end;
  flex-wrap: wrap;
  margin-top: 0.5rem;
}
.row.head {
  align-items: center;
  margin-top: 0;
  margin-bottom: 0.5rem;
}
.row.actions {
  gap: 0.35rem;
}
label {
  display: flex;
  flex-direction: column;
  gap: 0.2rem;
  font-size: 0.8rem;
  color: var(--muted);
}
input,
select {
  padding: 0.4rem;
  border: 1px solid var(--line);
  border-radius: 6px;
}
input.reason {
  flex: 1;
  min-width: 16rem;
}
.proposal {
  border-left: 4px solid #f59e0b;
}
.proposal-head {
  display: flex;
  align-items: center;
  gap: 0.6rem;
  margin-bottom: 0.4rem;
}
.reasoning {
  margin: 0.2rem 0 0.6rem;
  line-height: 1.5;
}
.reasoning-cell {
  max-width: 34rem;
  font-size: 0.85rem;
  line-height: 1.4;
}
.json {
  background: #f8fafc;
  border: 1px solid var(--line);
  border-radius: 6px;
  padding: 0.6rem;
  font-size: 0.75rem;
  overflow-x: auto;
  margin: 0.4rem 0 0;
}
details summary {
  cursor: pointer;
  font-size: 0.85rem;
  color: var(--accent);
}
.filter-card,
.signal-card {
  margin-top: 0.75rem;
}
.mono {
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  font-size: 0.85em;
}
.cause {
  margin-right: 0.25rem;
  display: inline-block;
}
.notice-banner {
  background: #dcfce7;
  color: #166534;
  padding: 0.6rem 1rem;
  border-radius: 6px;
  margin-bottom: 1rem;
}
</style>
