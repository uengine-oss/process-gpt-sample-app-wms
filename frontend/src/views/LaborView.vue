<script setup lang="ts">
import { ref, watch, onMounted, computed } from 'vue'
import { useAuthStore } from '@/stores/auth'
import { supabase } from '@/lib/supabase'

// Labor management (openspec change add-labor-management).
//
// Three panels, and which of them you see is the whole point of the contract:
//
//   1. "내 작업" — anyone who may record work. Start an activity, then close it
//      with a unit count (or cancel it if you never did the work).
//   2. 생산성 / 리더보드 — everyone, but the RPC decides the SCOPE. A manager
//      gets the whole warehouse; a worker gets their own row and nothing else.
//      The screen never filters that itself: it reads `scope` off the response
//      and says which one happened, so what you see is exactly what the
//      database was willing to hand over.
//   3. 인력 수요 추정 — WAREHOUSE_MANAGER / WMS_ADMIN only (design.md D4).
//
// In-progress activities are read straight off wms.labor_activities rather
// than through an RPC: RLS on that table already enforces the same
// self-or-manager rule, so a plain select is safe and shows the policy working.

const auth = useAuthStore()

const inProgress = ref<any[]>([])
const productivity = ref<any>(null)
const leaderboard = ref<any>(null)
const forecast = ref<any>(null)

const loading = ref(false)
const error = ref('')
const notice = ref('')
const submitting = ref<string | null>(null)

const ACTIVITY_TYPES = ['RECEIVING', 'QUALITY_INSPECTION', 'PUTAWAY', 'DISPOSITION', 'OTHER']

function todayISO() {
  return new Date().toISOString().slice(0, 10)
}

const startForm = ref({ activity_type: 'RECEIVING', activity_label: '' })
const completeForms = ref<Record<string, string>>({})
const period = ref({ from: todayISO(), to: todayISO() })
const metric = ref('completed_count')
const forecastForm = ref({
  role: 'INBOUND_OPERATOR',
  expected_volume: '480',
  trailing_days: '7',
  shift_hours: '8',
})

// design.md D4 + migration V2: the people who may log their own work.
const canRecord = computed(() =>
  ['WMS_ADMIN', 'WAREHOUSE_MANAGER', 'INBOUND_OPERATOR', 'QUALITY_INSPECTOR', 'PROCESS_AGENT'].includes(
    auth.currentRole ?? '',
  ),
)
const canForecast = computed(() =>
  ['WMS_ADMIN', 'WAREHOUSE_MANAGER'].includes(auth.currentRole ?? ''),
)
// D2: only the worker who opened an activity may close it. A manager can SEE
// a colleague's open row (RLS lets them) but closing it would come back
// FORBIDDEN, so the buttons are not offered — WMS_ADMIN is the one exception
// the RPC allows, and the only role that gets them here.
function canClose(a: any) {
  return a.actor_id === auth.userId || auth.currentRole === 'WMS_ADMIN'
}

/** A local wall-clock `YYYY-MM-DD` turned into that day's opening instant. */
function dayStart(dayStr: string) {
  return new Date(`${dayStr}T00:00:00`).toISOString()
}
/** ...and the exclusive upper bound, i.e. the next midnight. */
function dayEnd(dayStr: string) {
  const d = new Date(`${dayStr}T00:00:00`)
  d.setDate(d.getDate() + 1)
  return d.toISOString()
}

function hhmmss(ts: string | null) {
  if (!ts) return '—'
  return new Date(ts).toLocaleTimeString('ko-KR', {
    hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false,
  })
}

function mmss(seconds: number | null) {
  if (seconds === null || seconds === undefined) return '—'
  const s = Math.round(Number(seconds))
  const m = Math.floor(s / 60)
  return `${m}m ${String(s % 60).padStart(2, '0')}s`
}

const productivityRows = computed(() => productivity.value?.rows ?? [])
const leaderboardRows = computed(() => leaderboard.value?.rows ?? [])
const scopeLabel = computed(() =>
  productivity.value?.scope === 'WAREHOUSE' ? '창고 전체' : '본인 데이터만',
)

async function load() {
  if (!auth.currentTenantId || !auth.currentWarehouseId) return
  loading.value = true
  error.value = ''
  try {
    // RLS does the filtering here — a worker literally cannot select a
    // colleague's row, manager or not.
    const { data: openRows, error: openError } = await supabase
      .from('labor_activities')
      .select('*')
      .eq('warehouse_id', auth.currentWarehouseId)
      .eq('status', 'IN_PROGRESS')
      .order('started_at', { ascending: true })
    if (openError) throw openError
    inProgress.value = openRows ?? []

    const from = dayStart(period.value.from)
    const to = dayEnd(period.value.to)

    const { data: prod, error: prodError } = await supabase.rpc('wms_get_labor_productivity', {
      p_tenant_id: auth.currentTenantId,
      p_warehouse_id: auth.currentWarehouseId,
      p_period_start: from,
      p_period_end: to,
      p_actor_id: null,
      p_role: null,
    })
    if (prodError) throw prodError
    productivity.value = prod

    const { data: board, error: boardError } = await supabase.rpc('wms_get_labor_leaderboard', {
      p_tenant_id: auth.currentTenantId,
      p_warehouse_id: auth.currentWarehouseId,
      p_period_start: from,
      p_period_end: to,
      p_metric: metric.value,
    })
    if (boardError) throw boardError
    leaderboard.value = board
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

function startActivity() {
  return run('start', async () => {
    const { error: rpcError } = await supabase.rpc('wms_start_labor_activity', {
      p_tenant_id: auth.currentTenantId,
      p_warehouse_id: auth.currentWarehouseId,
      p_activity_type: startForm.value.activity_type,
      // D2: the RPC refuses anything other than the signed-in user, so the
      // screen never offers a "record on behalf of" field.
      p_actor_id: auth.userId,
      p_idempotency_key: crypto.randomUUID(),
      p_activity_label: startForm.value.activity_label || null,
      p_linked_entity_type: null,
      p_linked_entity_id: null,
      p_correlation_id: null,
    })
    if (rpcError) throw rpcError
    notice.value = `${startForm.value.activity_type} 활동을 시작했습니다 (IN_PROGRESS)`
    startForm.value.activity_label = ''
  })
}

function completeActivity(a: any) {
  return run(a.id, async () => {
    const raw = completeForms.value[a.id]
    const units = raw === undefined || raw === '' ? null : Number(raw)
    const { data, error: rpcError } = await supabase.rpc('wms_complete_labor_activity', {
      p_activity_id: a.id,
      p_actor_id: auth.userId,
      p_idempotency_key: crypto.randomUUID(),
      p_expected_version: a.version,
      p_unit_count: units,
      p_correlation_id: null,
    })
    if (rpcError) throw rpcError
    delete completeForms.value[a.id]
    notice.value = `활동 완료 — 처리 시간 ${data?.duration_seconds ?? 0}초` +
      (units === null ? ' (처리 수량 미기록: 수요 추정 표본에 들어가지 않습니다)' : `, 처리 수량 ${units}`)
  })
}

function cancelActivity(a: any) {
  return run(a.id, async () => {
    const { error: rpcError } = await supabase.rpc('wms_cancel_labor_activity', {
      p_activity_id: a.id,
      p_actor_id: auth.userId,
      p_idempotency_key: crypto.randomUUID(),
      p_expected_version: a.version,
      p_reason: '화면에서 취소',
      p_correlation_id: null,
    })
    if (rpcError) throw rpcError
    notice.value = '활동을 취소했습니다 — 생산성 집계에서 완전히 제외됩니다'
  })
}

function runForecast() {
  return run('forecast', async () => {
    forecast.value = null
    const { data, error: rpcError } = await supabase.rpc('wms_forecast_labor_demand', {
      p_tenant_id: auth.currentTenantId,
      p_warehouse_id: auth.currentWarehouseId,
      p_role: forecastForm.value.role,
      p_expected_volume: Number(forecastForm.value.expected_volume),
      p_trailing_days: Number(forecastForm.value.trailing_days),
      p_shift_hours: Number(forecastForm.value.shift_hours),
    })
    if (rpcError) throw rpcError
    forecast.value = data
    notice.value = `추정 완료 — 권장 인원 ${data?.recommended_headcount}명`
  })
}

onMounted(load)
watch(() => auth.currentWarehouseId, load)
watch(() => [period.value.from, period.value.to, metric.value], load)
</script>

<template>
  <div>
    <h1>Labor</h1>
    <p class="hint">
      작업자별 생산성 계측(작업 시작·완료·취소), 생산성 집계와 리더보드, 그리고 단순 비율 기반
      인력 수요 추정. 개인 생산성 데이터는 본인과 관리자만 볼 수 있습니다.
      현재 역할: {{ auth.currentRole }}
    </p>
    <div v-if="error" class="error-banner" data-testid="labor-error">{{ error }}</div>
    <div v-if="notice" class="notice-banner" data-testid="labor-notice">{{ notice }}</div>

    <div v-if="canRecord" class="card">
      <h2>작업 시작</h2>
      <p class="hint">
        시작 시각은 서버가 찍습니다. 활동은 언제나 로그인한 본인 명의로 기록됩니다 —
        다른 사람 이름으로 기록할 방법은 없습니다.
      </p>
      <div class="row">
        <label>
          Activity Type
          <select v-model="startForm.activity_type" aria-label="Activity Type">
            <option v-for="t in ACTIVITY_TYPES" :key="t" :value="t">{{ t }}</option>
          </select>
        </label>
        <label>
          Activity Label
          <input
            v-model="startForm.activity_label"
            aria-label="Activity Label"
            placeholder="OTHER 유형이면 필수"
          />
        </label>
        <button class="primary" :disabled="submitting === 'start'" @click="startActivity">
          Start Activity
        </button>
      </div>
    </div>

    <h2 class="board-title">진행 중인 작업</h2>
    <p class="hint">
      이 목록은 RPC가 아니라 테이블을 직접 조회합니다 — 동료의 행은 RLS가 막기 때문에
      작업자에게는 본인 것만, 관리자에게는 창고 전체가 보입니다.
    </p>
    <table>
      <thead>
        <tr>
          <th>Type</th>
          <th>Label</th>
          <th>Actor</th>
          <th>Role</th>
          <th>Started</th>
          <th>Version</th>
          <th>Actions</th>
        </tr>
      </thead>
      <tbody>
        <tr
          v-for="a in inProgress"
          :key="a.id"
          :data-activity-id="a.id"
          :data-activity-type="a.activity_type"
          :data-activity-label="a.activity_label ?? ''"
        >
          <td>{{ a.activity_type }}</td>
          <td>{{ a.activity_label || '—' }}</td>
          <td class="mono">{{ a.actor_id === auth.userId ? '나' : a.actor_id.slice(0, 8) }}</td>
          <td>{{ a.actor_role }}</td>
          <td>{{ hhmmss(a.started_at) }}</td>
          <td>{{ a.version }}</td>
          <td>
            <div v-if="canClose(a)" class="row actions">
              <input
                v-model="completeForms[a.id]"
                class="units"
                type="number"
                min="0"
                :aria-label="`unit count for ${a.activity_type}`"
                placeholder="수량"
              />
              <button
                class="primary"
                :disabled="submitting === a.id"
                :aria-label="`complete ${a.activity_type}`"
                @click="completeActivity(a)"
              >
                Complete
              </button>
              <button
                class="primary danger"
                :disabled="submitting === a.id"
                :aria-label="`cancel ${a.activity_type}`"
                @click="cancelActivity(a)"
              >
                Cancel
              </button>
            </div>
            <span v-else class="hint">본인만 종료할 수 있습니다</span>
          </td>
        </tr>
      </tbody>
    </table>
    <p v-if="!loading && inProgress.length === 0">진행 중인 작업이 없습니다.</p>

    <div class="card period-card">
      <div class="row">
        <label>
          집계 시작일
          <input v-model="period.from" type="date" aria-label="Period From" />
        </label>
        <label>
          집계 종료일
          <input v-model="period.to" type="date" aria-label="Period To" />
        </label>
        <label>
          Leaderboard Metric
          <select v-model="metric" aria-label="Leaderboard Metric">
            <option value="completed_count">completed_count</option>
            <option value="total_unit_count">total_unit_count</option>
            <option value="avg_duration_seconds">avg_duration_seconds</option>
          </select>
        </label>
        <button class="primary" @click="load">Refresh</button>
      </div>
    </div>

    <h2 class="board-title">
      생산성 집계
      <span class="status" :class="productivity?.scope === 'WAREHOUSE' ? 'ok' : 'warn'" data-testid="productivity-scope">
        {{ productivity?.scope ?? '—' }}
      </span>
      <span class="hint scope-note">{{ scopeLabel }}</span>
    </h2>
    <div v-if="productivity" class="card totals" data-testid="productivity-totals">
      <span>완료 <b data-testid="totals-completed">{{ productivity.totals.completed_count }}</b>건</span>
      <span>합계 처리 시간 <b>{{ mmss(productivity.totals.total_duration_seconds) }}</b></span>
      <span>평균 처리 시간 <b>{{ mmss(productivity.totals.avg_duration_seconds) }}</b></span>
      <span>합계 처리 수량 <b data-testid="totals-units">{{ productivity.totals.total_unit_count }}</b></span>
      <span>작업자 <b data-testid="totals-actors">{{ productivity.totals.distinct_actor_count }}</b>명</span>
    </div>
    <table>
      <thead>
        <tr>
          <th>Date</th>
          <th>Worker</th>
          <th>Role</th>
          <th>Activity</th>
          <th>Completed</th>
          <th>Avg</th>
          <th>Total</th>
          <th>Units</th>
        </tr>
      </thead>
      <tbody>
        <tr v-for="r in productivityRows" :key="`${r.actor_id}-${r.activity_date}-${r.activity_type}`"
            :data-productivity-row="`${r.actor_email} ${r.activity_type}`">
          <td>{{ r.activity_date }}</td>
          <td>{{ r.actor_email }}</td>
          <td>{{ r.actor_role }}</td>
          <td>{{ r.activity_type }}</td>
          <td>{{ r.completed_count }}</td>
          <td>{{ mmss(r.avg_duration_seconds) }}</td>
          <td>{{ mmss(r.total_duration_seconds) }}</td>
          <td>{{ r.total_unit_count }}</td>
        </tr>
      </tbody>
    </table>
    <p v-if="!loading && productivityRows.length === 0">해당 기간에 완료된 활동이 없습니다.</p>

    <h2 class="board-title">
      리더보드
      <span class="status" :class="leaderboard?.scope === 'WAREHOUSE' ? 'ok' : 'warn'" data-testid="leaderboard-scope">
        {{ leaderboard?.scope ?? '—' }}
      </span>
    </h2>
    <p class="hint">
      {{ metric }} 기준. 포인트·배지·레벨 같은 게임 메커니즘은 없습니다 — 순위표가 전부입니다.
      <template v-if="leaderboard?.scope === 'SELF'">
        본인 행만 표시되며, 순위는 표시하지 않습니다(다른 작업자 수치가 새지 않도록).
      </template>
    </p>
    <table>
      <thead>
        <tr>
          <th>Rank</th>
          <th>Worker</th>
          <th>Role</th>
          <th>Completed</th>
          <th>Units</th>
          <th>Avg Duration</th>
        </tr>
      </thead>
      <tbody>
        <tr v-for="r in leaderboardRows" :key="r.actor_id" :data-leaderboard-actor="r.actor_email">
          <td>{{ r.rank ?? '—' }}</td>
          <td>{{ r.actor_email }}</td>
          <td>{{ r.actor_role }}</td>
          <td>{{ r.completed_count }}</td>
          <td>{{ r.total_unit_count }}</td>
          <td>{{ mmss(r.avg_duration_seconds) }}</td>
        </tr>
      </tbody>
    </table>
    <p v-if="!loading && leaderboardRows.length === 0">해당 기간에 순위를 매길 데이터가 없습니다.</p>

    <div v-if="canForecast" class="card forecast-card">
      <h2>인력 수요 추정</h2>
      <p class="hint">
        트레일링 기간의 평균 시간당 처리량으로 필요한 인원을 나눗셈합니다.
        머신러닝 예측이 아니며, 표본이 없으면 숫자를 만들어내지 않고 오류를 돌려줍니다.
      </p>
      <div class="row">
        <label>
          Role
          <input v-model="forecastForm.role" aria-label="Forecast Role" />
        </label>
        <label>
          Expected Volume
          <input v-model="forecastForm.expected_volume" type="number" aria-label="Expected Volume" />
        </label>
        <label>
          Trailing Days
          <input v-model="forecastForm.trailing_days" type="number" aria-label="Trailing Days" />
        </label>
        <label>
          Shift Hours
          <input v-model="forecastForm.shift_hours" type="number" aria-label="Shift Hours" />
        </label>
        <button class="primary" :disabled="submitting === 'forecast'" @click="runForecast">
          Forecast
        </button>
      </div>
      <div v-if="forecast" class="card forecast-result" data-testid="forecast-result">
        <p class="headcount">
          권장 인원 <b data-testid="forecast-headcount">{{ forecast.recommended_headcount }}</b>명
          <span class="status warn">{{ forecast.method }}</span>
        </p>
        <p class="hint">
          트레일링 {{ forecast.basis.trailing_days }}일 · 표본 {{ forecast.basis.sample_count }}건 ·
          시간당 {{ forecast.basis.avg_units_per_hour }} · 1인 1교대
          {{ forecast.basis.units_per_person_per_shift }} ({{ forecast.basis.shift_hours }}h)
        </p>
        <p class="hint">{{ forecast.method_note }}</p>
      </div>
    </div>
    <p v-else class="hint">
      인력 수요 추정은 WAREHOUSE_MANAGER / WMS_ADMIN만 조회할 수 있습니다 — 관리 판단 정보이기 때문입니다.
    </p>
  </div>
</template>

<style scoped>
.hint {
  color: var(--muted);
  margin-top: -0.5rem;
}
h2 {
  font-size: 1rem;
  margin: 0 0 0.25rem;
}
.board-title {
  margin: 1.5rem 0 0.5rem;
  display: flex;
  align-items: center;
  gap: 0.5rem;
}
.scope-note {
  margin: 0;
  font-weight: 400;
  font-size: 0.8rem;
}
.row {
  display: flex;
  gap: 0.5rem;
  align-items: flex-end;
  flex-wrap: wrap;
  margin-top: 0.5rem;
}
.row.actions {
  margin-top: 0;
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
input.units {
  width: 5rem;
}
.mono {
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  font-size: 0.85em;
}
.period-card {
  margin-top: 1.5rem;
}
.totals {
  display: flex;
  gap: 1.5rem;
  flex-wrap: wrap;
  font-size: 0.9rem;
}
.forecast-card {
  margin-top: 1.5rem;
}
.forecast-result {
  margin: 0.75rem 0 0;
  background: #f8fafc;
}
.headcount {
  margin: 0 0 0.25rem;
  font-size: 1.1rem;
}
.notice-banner {
  background: #dcfce7;
  color: #166534;
  padding: 0.6rem 1rem;
  border-radius: 6px;
  margin-bottom: 1rem;
}
</style>
