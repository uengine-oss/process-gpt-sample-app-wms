<script setup lang="ts">
import { ref, watch, onMounted, computed } from 'vue'
import { useAuthStore } from '@/stores/auth'
import { supabase } from '@/lib/supabase'

// WCS digital twin / simulation (openspec change add-wcs-digital-twin-simulation).
//
// Three things live on this screen:
//   1. which machines answer in software (is_simulated) and how fast they
//      pretend to be (the timing/failure profile),
//   2. what the simulator is currently in the middle of (the live plans),
//   3. what-if scenarios — a pure arithmetic projection that dispatches nothing.
//
// The ticking itself is NOT here and cannot be: progressing a command needs a
// WCS_GATEWAY session, and nobody logs into this app as the gateway. That is
// the external worker's job (mcp/wms_mcp/simulator/wcs_gateway_simulator.py).
// This screen deliberately says so rather than pretending the button exists.

const auth = useAuthStore()

const equipment = ref<any[]>([])
const systemDefaults = ref<any>(null)
const schedules = ref<any[]>([])
const scenarios = ref<any[]>([])
const loading = ref(false)
const error = ref('')
const notice = ref('')
const submitting = ref<string | null>(null)

const profileForm = ref({
  equipment_id: '',
  ack_delay_ms_min: 200,
  ack_delay_ms_max: 500,
  progress_delay_ms_min: 200,
  progress_delay_ms_max: 600,
  completion_delay_ms_min: 400,
  completion_delay_ms_max: 1200,
  failure_rate: 0,
  jam_rate: 0,
})

const scenarioForm = ref({
  name: '',
  equipment_ids: [] as string[],
  command_count: 10,
  linked_entity_type: '',
})

const canSetMode = computed(() => ['WMS_ADMIN', 'WAREHOUSE_MANAGER'].includes(auth.currentRole ?? ''))
const canManageProfile = computed(() =>
  ['WMS_ADMIN', 'WAREHOUSE_MANAGER', 'WCS_OPERATOR'].includes(auth.currentRole ?? ''),
)
const canScenario = computed(() =>
  ['WMS_ADMIN', 'WAREHOUSE_MANAGER', 'PROCESS_AGENT'].includes(auth.currentRole ?? ''),
)

const simulatedEquipment = computed(() => equipment.value.filter((e) => e.is_simulated))

function statusClass(status: string) {
  if (status === 'FAULT') return 'danger'
  if (status === 'RUNNING' || status === 'IDLE') return 'ok'
  return 'warn'
}

function ms(n: number | null | undefined) {
  if (n === null || n === undefined) return '—'
  return n >= 1000 ? `${(n / 1000).toFixed(1)}s` : `${n}ms`
}

function range(p: any, key: string) {
  return `${ms(p?.[`${key}_ms_min`])}~${ms(p?.[`${key}_ms_max`])}`
}

function pct(n: number | null | undefined) {
  if (n === null || n === undefined) return '—'
  return `${(Number(n) * 100).toFixed(0)}%`
}

function clock(iso: string | null | undefined) {
  if (!iso) return '—'
  return new Date(iso).toLocaleTimeString()
}

async function load() {
  if (!auth.currentTenantId || !auth.currentWarehouseId) return
  loading.value = true
  error.value = ''
  const scope = { p_tenant_id: auth.currentTenantId, p_warehouse_id: auth.currentWarehouseId }
  try {
    const [profiles, schedule, scenario] = await Promise.all([
      supabase.rpc('wms_get_simulation_profile', { ...scope, p_equipment_id: null }),
      supabase.rpc('wms_get_simulation_schedule_status', {
        ...scope, p_equipment_id: null, p_due_only: false,
      }),
      supabase.rpc('wms_get_simulation_scenario_status', { ...scope, p_scenario_id: null }),
    ])
    if (profiles.error) throw profiles.error
    if (schedule.error) throw schedule.error
    if (scenario.error) throw scenario.error
    equipment.value = profiles.data?.equipment ?? []
    systemDefaults.value = profiles.data?.system_defaults ?? null
    schedules.value = schedule.data?.schedules ?? []
    scenarios.value = scenario.data?.scenarios ?? []
    if (!profileForm.value.equipment_id) {
      profileForm.value.equipment_id = simulatedEquipment.value[0]?.equipment_id ?? ''
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

function toggleSimulation(e: any) {
  return run(`mode-${e.equipment_id}`, async () => {
    const { data, error: rpcError } = await supabase.rpc('wms_set_equipment_simulation_mode', {
      p_equipment_id: e.equipment_id,
      p_is_simulated: !e.is_simulated,
      p_actor_id: auth.userId,
      p_idempotency_key: crypto.randomUUID(),
      p_expected_version: e.equipment_version,
      p_correlation_id: null,
    })
    if (rpcError) throw rpcError
    const warnings = (data?.warnings ?? []) as string[]
    notice.value = `${e.equipment_code} 시뮬레이션 ${data?.is_simulated ? 'ON' : 'OFF'}`
      + (warnings.length ? ` — ${warnings.join(', ')}` : '')
  })
}

function saveProfile() {
  const target = equipment.value.find((e) => e.equipment_id === profileForm.value.equipment_id)
  return run('profile', async () => {
    if (!target) throw new Error('설비를 선택하세요')
    const f = profileForm.value
    const existing = target.registered_profile
    if (existing) {
      const { error: rpcError } = await supabase.rpc('wms_update_simulation_profile', {
        p_profile_id: existing.profile_id,
        p_actor_id: auth.userId,
        p_idempotency_key: crypto.randomUUID(),
        p_expected_version: existing.version,
        p_ack_delay_ms_min: f.ack_delay_ms_min,
        p_ack_delay_ms_max: f.ack_delay_ms_max,
        p_progress_delay_ms_min: f.progress_delay_ms_min,
        p_progress_delay_ms_max: f.progress_delay_ms_max,
        p_completion_delay_ms_min: f.completion_delay_ms_min,
        p_completion_delay_ms_max: f.completion_delay_ms_max,
        p_failure_rate: f.failure_rate,
        p_jam_rate: f.jam_rate,
        p_status: 'ACTIVE',
        p_correlation_id: null,
      })
      if (rpcError) throw rpcError
      notice.value = `${target.equipment_code} 프로파일을 갱신했습니다`
    } else {
      const { error: rpcError } = await supabase.rpc('wms_register_simulation_profile', {
        p_equipment_id: f.equipment_id,
        p_ack_delay_ms_min: f.ack_delay_ms_min,
        p_ack_delay_ms_max: f.ack_delay_ms_max,
        p_progress_delay_ms_min: f.progress_delay_ms_min,
        p_progress_delay_ms_max: f.progress_delay_ms_max,
        p_completion_delay_ms_min: f.completion_delay_ms_min,
        p_completion_delay_ms_max: f.completion_delay_ms_max,
        p_failure_rate: f.failure_rate,
        p_actor_id: auth.userId,
        p_idempotency_key: crypto.randomUUID(),
        p_jam_rate: f.jam_rate,
        p_correlation_id: null,
      })
      if (rpcError) throw rpcError
      notice.value = `${target.equipment_code} 프로파일을 등록했습니다`
    }
  })
}

function createScenario() {
  return run('scenario', async () => {
    const f = scenarioForm.value
    if (!f.name) throw new Error('시나리오 이름이 필요합니다')
    if (f.equipment_ids.length === 0) throw new Error('설비를 1대 이상 선택하세요')
    const { error: rpcError } = await supabase.rpc('wms_create_simulation_scenario', {
      p_tenant_id: auth.currentTenantId,
      p_warehouse_id: auth.currentWarehouseId,
      p_name: f.name,
      p_equipment_ids: f.equipment_ids,
      p_command_count: Number(f.command_count),
      p_actor_id: auth.userId,
      p_idempotency_key: crypto.randomUUID(),
      p_scenario_type: 'EQUIPMENT_SUBSTITUTION',
      p_linked_entity_type: f.linked_entity_type || null,
      p_linked_entity_id: null,
      p_correlation_id: null,
    })
    if (rpcError) throw rpcError
    notice.value = `시나리오 "${f.name}"를 정의했습니다 (아직 실행 전)`
    scenarioForm.value = { name: '', equipment_ids: [], command_count: 10, linked_entity_type: '' }
  })
}

function runScenario(s: any) {
  return run(`run-${s.scenario_id}`, async () => {
    const { data, error: rpcError } = await supabase.rpc('wms_run_simulation_scenario', {
      p_scenario_id: s.scenario_id,
      p_actor_id: auth.userId,
      p_idempotency_key: crypto.randomUUID(),
      p_correlation_id: null,
    })
    if (rpcError) throw rpcError
    notice.value =
      `"${s.name}" 추정: ${data?.projected_round_count}회전 · `
      + `${ms(data?.projected_duration_ms)} 소요 · 실패 ${data?.projected_failure_count}건 예상`
  })
}

onMounted(load)
watch(() => auth.currentWarehouseId, load)
</script>

<template>
  <div>
    <h1>WCS Simulation</h1>
    <p class="hint">
      실제 설비 없이 설비 명령을 왕복시키는 디지털 트윈 화면. 현재 역할: {{ auth.currentRole }}
    </p>
    <div v-if="error" class="error-banner">{{ error }}</div>
    <div v-if="notice" class="notice-banner">{{ notice }}</div>

    <div class="card worker-note">
      <strong>진행은 외부 워커가 시킵니다.</strong>
      명령을 실제로 ACKNOWLEDGED → IN_PROGRESS → COMPLETED로 밀어 주는 것은 이 화면이 아니라
      <code>mcp/wms_mcp/simulator/wcs_gateway_simulator.py</code> 프로세스입니다
      (<code>python -m wms_mcp.simulator.wcs_gateway_simulator --loop --interval 1</code>).
      결과 보고에는 <code>WCS_GATEWAY</code> 세션이 필요한데, 이 앱에는 아무도 게이트웨이로
      로그인하지 않기 때문입니다. 워커가 꺼져 있어도 아래 계획은 DB에 그대로 남아 있다가
      워커를 다시 켜면 이어서 진행됩니다.
    </div>

    <!-- ------------------------------------------------------------ -->
    <div class="card">
      <h2>설비 시뮬레이션 모드</h2>
      <p class="hint">
        시뮬레이션 대상으로 켠 설비만 워커가 응답합니다. 끈 설비의 명령은 실제 게이트웨이나
        사람 운영자의 몫으로 남습니다.
      </p>
      <table>
        <thead>
          <tr>
            <th>Code</th>
            <th>Type</th>
            <th>Status</th>
            <th>Simulated</th>
            <th>Timing (ack / progress / completion)</th>
            <th>Failure</th>
            <th>Jam</th>
            <th>Source</th>
            <th v-if="canSetMode"></th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="e in equipment" :key="e.equipment_id" :data-equipment-code="e.equipment_code">
            <td>{{ e.equipment_code }}</td>
            <td>{{ e.equipment_type }}</td>
            <td><span class="status" :class="statusClass(e.equipment_status)">{{ e.equipment_status }}</span></td>
            <td>
              <span class="status" :class="e.is_simulated ? 'ok' : ''" :data-sim-flag="e.is_simulated">
                {{ e.is_simulated ? 'SIMULATED' : 'REAL' }}
              </span>
            </td>
            <td class="mono">
              {{ range(e.effective_profile, 'ack_delay') }} /
              {{ range(e.effective_profile, 'progress_delay') }} /
              {{ range(e.effective_profile, 'completion_delay') }}
            </td>
            <td>{{ pct(e.effective_profile?.failure_rate) }}</td>
            <td>{{ pct(e.effective_profile?.jam_rate) }}</td>
            <td>
              <span class="status" :class="e.effective_profile?.is_default ? 'warn' : 'ok'">
                {{ e.effective_profile?.is_default ? '기본값' : '등록 프로파일' }}
              </span>
              <span v-if="e.registered_profile && e.registered_profile.status !== 'ACTIVE'" class="hint">
                (프로파일 {{ e.registered_profile.status }})
              </span>
            </td>
            <td v-if="canSetMode">
              <button
                class="primary"
                :class="{ danger: e.is_simulated }"
                :disabled="submitting === `mode-${e.equipment_id}`"
                @click="toggleSimulation(e)"
              >
                {{ e.is_simulated ? 'Turn Off' : 'Simulate' }}
              </button>
            </td>
          </tr>
        </tbody>
      </table>
      <p v-if="!loading && equipment.length === 0" class="hint">등록된 설비가 없습니다.</p>
      <p v-if="systemDefaults" class="hint">
        시스템 기본값 — ack {{ range(systemDefaults, 'ack_delay') }},
        progress {{ range(systemDefaults, 'progress_delay') }},
        completion {{ range(systemDefaults, 'completion_delay') }},
        failure {{ pct(systemDefaults.failure_rate) }}, jam {{ pct(systemDefaults.jam_rate) }}.
        프로파일을 등록하지 않은 시뮬레이션 설비에는 이 값이 적용됩니다.
      </p>
    </div>

    <!-- ------------------------------------------------------------ -->
    <div v-if="canManageProfile" class="card">
      <h2>시뮬레이션 프로파일</h2>
      <p class="hint">
        선택한 설비에 프로파일이 없으면 등록하고, 있으면 갱신합니다.
        <code>failure_rate=1</code>이면 항상 실패하고, <code>DIVERT</code> 명령에
        <code>jam_rate=1</code>을 걸면 실패가 항상 잼(JAM)이 되어 자동 장애 승격까지 재현됩니다.
      </p>
      <div class="row">
        <label>
          Equipment
          <select v-model="profileForm.equipment_id" aria-label="profile equipment">
            <option v-for="e in simulatedEquipment" :key="e.equipment_id" :value="e.equipment_id">
              {{ e.equipment_code }}
            </option>
          </select>
        </label>
        <label>Ack min<input v-model.number="profileForm.ack_delay_ms_min" aria-label="ack min" type="number" /></label>
        <label>Ack max<input v-model.number="profileForm.ack_delay_ms_max" aria-label="ack max" type="number" /></label>
        <label>Progress min<input v-model.number="profileForm.progress_delay_ms_min" aria-label="progress min" type="number" /></label>
        <label>Progress max<input v-model.number="profileForm.progress_delay_ms_max" aria-label="progress max" type="number" /></label>
        <label>Completion min<input v-model.number="profileForm.completion_delay_ms_min" aria-label="completion min" type="number" /></label>
        <label>Completion max<input v-model.number="profileForm.completion_delay_ms_max" aria-label="completion max" type="number" /></label>
        <label>Failure rate<input v-model.number="profileForm.failure_rate" aria-label="failure rate" type="number" step="0.05" min="0" max="1" /></label>
        <label>Jam rate<input v-model.number="profileForm.jam_rate" aria-label="jam rate" type="number" step="0.05" min="0" max="1" /></label>
        <button
          class="primary"
          :disabled="submitting === 'profile' || simulatedEquipment.length === 0"
          @click="saveProfile"
        >
          Save Profile
        </button>
      </div>
      <p v-if="simulatedEquipment.length === 0" class="hint">
        먼저 설비를 시뮬레이션 대상으로 켜야 프로파일을 등록할 수 있습니다.
      </p>
    </div>

    <!-- ------------------------------------------------------------ -->
    <div class="card">
      <h2>진행 중인 계획</h2>
      <p class="hint">
        워커가 명령을 처음 발견하면 각 단계의 목표 시각과 최종 결과를 <em>그 자리에서 한 번만</em>
        굴려 계획으로 고정합니다. 그래서 아래 표는 "이 명령이 언제, 무엇으로 끝날 예정인지"를
        미리 보여 줍니다 — 시뮬레이션이 블랙박스가 되지 않도록.
      </p>
      <table>
        <thead>
          <tr>
            <th>Equipment</th>
            <th>Command</th>
            <th>Now</th>
            <th>Next</th>
            <th>At</th>
            <th>Due?</th>
            <th>Planned outcome</th>
            <th>Profile</th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="s in schedules" :key="s.schedule_id" :data-schedule-equipment="s.equipment_code">
            <td>{{ s.equipment_code }}</td>
            <td>{{ s.command_type }}</td>
            <td><span class="status">{{ s.command_status }}</span></td>
            <td><span class="status warn">{{ s.next_status }}</span></td>
            <td class="mono">{{ clock(s.next_run_at) }}</td>
            <td>{{ s.is_due ? '도래' : '대기' }}</td>
            <td>
              <span class="status" :class="s.planned_terminal_status === 'COMPLETED' ? 'ok' : 'danger'">
                {{ s.planned_terminal_status }}
              </span>
              <span class="hint">{{ s.planned_detail?.outcome }}</span>
            </td>
            <td class="hint">{{ s.profile_source }}</td>
          </tr>
        </tbody>
      </table>
      <p v-if="schedules.length === 0" class="hint">진행 중인 시뮬레이션 계획이 없습니다.</p>
      <button class="primary" @click="load">Refresh</button>
    </div>

    <!-- ------------------------------------------------------------ -->
    <div v-if="canScenario" class="card">
      <h2>what-if 시나리오</h2>
      <p class="hint">
        "이 설비 집합으로 이만큼의 명령을 처리하면 얼마나 걸릴까"를 묻는 dry-run입니다.
        <strong>실제 명령은 하나도 나가지 않습니다</strong> — 프로파일의 타이밍 모델을 재사용한
        산술 추정치이며, 대기 행렬·재시도·우선순위를 무시한 낙관적 근사치입니다.
        처리 건수는 시스템이 세어 주지 않고 운영자가 직접 넣습니다.
      </p>
      <div class="row">
        <label>
          Name
          <input v-model="scenarioForm.name" aria-label="scenario name" placeholder="야간 웨이브 축소 운전" />
        </label>
        <label>
          Command count
          <input v-model.number="scenarioForm.command_count" aria-label="command count" type="number" min="1" />
        </label>
        <label>
          Linked entity (참고 라벨)
          <input v-model="scenarioForm.linked_entity_type" aria-label="linked entity type" placeholder="dispatch_wave" />
        </label>
        <button class="primary" :disabled="submitting === 'scenario'" @click="createScenario">
          Create Scenario
        </button>
      </div>
      <div class="equipment-picker">
        <label v-for="e in equipment" :key="e.equipment_id" class="check">
          <input
            v-model="scenarioForm.equipment_ids"
            type="checkbox"
            :value="e.equipment_id"
            :aria-label="`scenario include ${e.equipment_code}`"
          />
          {{ e.equipment_code }}
          <span v-if="!e.is_simulated" class="hint">(real)</span>
        </label>
      </div>
    </div>

    <div class="card">
      <h2>시나리오 실행 결과</h2>
      <table>
        <thead>
          <tr>
            <th>Name</th>
            <th>Equipment</th>
            <th>Commands</th>
            <th>Status</th>
            <th>Runs</th>
            <th>최근 추정</th>
            <th v-if="canScenario"></th>
          </tr>
        </thead>
        <tbody>
          <template v-for="s in scenarios" :key="s.scenario_id">
            <tr :data-scenario-name="s.name">
              <td>{{ s.name }}</td>
              <td class="mono">{{ (s.equipment_codes ?? []).join(', ') }}</td>
              <td>{{ s.command_count }}</td>
              <td><span class="status" :class="s.status === 'RUN' ? 'ok' : 'warn'">{{ s.status }}</span></td>
              <td :data-run-count="s.run_count">{{ s.run_count }}</td>
              <td>
                <span v-if="s.runs?.length" class="mono">
                  {{ s.runs[0].projected_round_count }}회전 ·
                  {{ ms(s.runs[0].projected_duration_ms) }} ·
                  실패 {{ s.runs[0].projected_failure_count }}건
                </span>
                <span v-else class="hint">아직 실행 전</span>
              </td>
              <td v-if="canScenario">
                <button
                  class="primary"
                  :disabled="submitting === `run-${s.scenario_id}`"
                  @click="runScenario(s)"
                >
                  Run
                </button>
              </td>
            </tr>
            <tr v-if="s.runs?.length" class="detail-row" :data-scenario-detail="s.name">
              <td :colspan="canScenario ? 7 : 6">
                <div v-for="w in s.runs[0].warnings ?? []" :key="w" class="warning-line">⚠ {{ w }}</div>
                <div class="hint">
                  모델: {{ s.runs[0].assumptions?.model }} ·
                  설비 {{ s.runs[0].assumptions?.equipment_count }}대 ·
                  1건 평균 {{ ms(s.runs[0].assumptions?.mean_service_time_ms) }} ·
                  평균 실패율 {{ pct(s.runs[0].assumptions?.mean_failure_rate) }} ·
                  예상 완료 {{ clock(s.runs[0].projected_completion_at) }}
                </div>
              </td>
            </tr>
          </template>
        </tbody>
      </table>
      <p v-if="scenarios.length === 0" class="hint">정의된 시나리오가 없습니다.</p>
    </div>
  </div>
</template>

<style scoped>
.hint {
  color: var(--muted);
  font-size: 0.85rem;
}
h2 {
  font-size: 1rem;
  margin: 0 0 0.25rem;
}
.row {
  display: flex;
  gap: 0.5rem;
  align-items: flex-end;
  margin-top: 0.5rem;
  flex-wrap: wrap;
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
input[type='number'] {
  width: 6.5rem;
}
.mono {
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  font-size: 0.8rem;
}
.notice-banner {
  background: #dcfce7;
  color: #166534;
  padding: 0.6rem 1rem;
  border-radius: 6px;
  margin-bottom: 1rem;
}
.worker-note {
  border-left: 4px solid var(--accent);
  font-size: 0.85rem;
  color: var(--muted);
}
.worker-note code {
  background: #f1f5f9;
  padding: 0 0.25rem;
  border-radius: 3px;
}
.equipment-picker {
  display: flex;
  flex-wrap: wrap;
  gap: 0.75rem;
  margin-top: 0.75rem;
}
.check {
  flex-direction: row;
  align-items: center;
  gap: 0.3rem;
  color: var(--ink);
  font-size: 0.85rem;
}
.detail-row td {
  background: #f8fafc;
  font-size: 0.8rem;
}
.warning-line {
  color: #92400e;
}
table {
  margin-bottom: 0.5rem;
}
</style>
