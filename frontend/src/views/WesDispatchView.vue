<script setup lang="ts">
import { ref, watch, onMounted, computed } from 'vue'
import { useAuthStore } from '@/stores/auth'
import { supabase } from '@/lib/supabase'

// WES/MFS material flow control (openspec change add-wes-material-flow-control).
// The middleware screen between a WMS-side intent (a receipt awaiting putaway)
// and the WCS equipment commands that actually move it: open a dispatch wave,
// queue work orders into it, release the wave, and watch each work order follow
// its equipment command to COMPLETED. Reads go through wms_get_work_order_status
// (already joined with the wave and the linked command); writes go through the
// SECURITY DEFINER RPCs, like every other view in this app.

const auth = useAuthStore()
const workOrders = ref<any[]>([])
const waves = ref<any[]>([])
const receipts = ref<any[]>([])
const loading = ref(false)
const error = ref('')
const notice = ref('')
const submitting = ref<string | null>(null)

const EQUIPMENT_TYPES = ['SRM', 'CONVEYOR', 'SORTER', 'AGV', 'AMR', 'ROBOT_CELL']
const COMMAND_TYPES = ['MOVE', 'LOAD', 'UNLOAD', 'START', 'STOP', 'RESET', 'HOLD', 'RESUME']

const form = ref({
  linked_entity_id: '',
  equipment_type: 'AGV',
  zone_code: '',
  command_type: 'MOVE',
  to_zone: '',
  dispatch_mode: 'WAVE',
  wave_id: '',
})

// design.md D3: exactly the roles that wms_dispatch_equipment_command accepts.
// WMS_ADMIN is deliberately absent — see the migration header.
const canOperate = computed(() =>
  ['WAREHOUSE_MANAGER', 'WCS_OPERATOR', 'PROCESS_AGENT'].includes(auth.currentRole ?? ''),
)
const openWaves = computed(() => waves.value.filter((w) => w.status === 'OPEN'))

function statusClass(status: string) {
  if (status === 'FAILED') return 'danger'
  if (status === 'COMPLETED' || status === 'DISPATCHED' || status === 'RELEASED') return 'ok'
  if (status === 'CANCELLED') return 'muted-badge'
  return 'warn'
}

function shortId(id: string | null) {
  return id ? id.slice(0, 8) : '—'
}

async function load() {
  if (!auth.currentTenantId || !auth.currentWarehouseId) return
  loading.value = true
  error.value = ''
  try {
    const { data, error: rpcError } = await supabase.rpc('wms_get_work_order_status', {
      p_tenant_id: auth.currentTenantId,
      p_warehouse_id: auth.currentWarehouseId,
      p_work_order_id: null,
    })
    if (rpcError) throw rpcError
    workOrders.value = data?.work_orders ?? []
    waves.value = data?.waves ?? []

    const { data: receiptRows, error: receiptError } = await supabase
      .from('receipts')
      .select('id, status, expected_qty')
      .eq('warehouse_id', auth.currentWarehouseId)
      .order('created_at', { ascending: false })
    if (receiptError) throw receiptError
    receipts.value = receiptRows ?? []
    if (!form.value.linked_entity_id && receipts.value.length > 0) {
      form.value.linked_entity_id = receipts.value[0].id
    }
    if (!form.value.wave_id && openWaves.value.length > 0) {
      form.value.wave_id = openWaves.value[0].wave_id
    }
  } catch (e: any) {
    error.value = e.message ?? String(e)
  } finally {
    loading.value = false
  }
}

function applyWarnings(data: any, fallback: string) {
  const warnings: string[] = data?.warnings ?? []
  notice.value = warnings.length > 0 ? warnings.join(' / ') : fallback
}

async function openWave() {
  submitting.value = 'open-wave'
  error.value = ''
  try {
    const { data, error: rpcError } = await supabase.rpc('wms_open_dispatch_wave', {
      p_tenant_id: auth.currentTenantId,
      p_warehouse_id: auth.currentWarehouseId,
      p_actor_id: auth.userId,
      p_idempotency_key: crypto.randomUUID(),
      p_correlation_id: null,
    })
    if (rpcError) throw rpcError
    form.value.wave_id = data.wave_id
    notice.value = `웨이브 ${shortId(data.wave_id)} 개설 (OPEN)`
    await load()
  } catch (e: any) {
    error.value = e.message ?? String(e)
  } finally {
    submitting.value = null
  }
}

async function createWorkOrder() {
  submitting.value = 'create-work-order'
  error.value = ''
  try {
    if (!form.value.linked_entity_id) throw new Error('연결할 입고(receipt)를 선택하세요')
    if (form.value.dispatch_mode === 'WAVE' && !form.value.wave_id) {
      throw new Error('WAVE 모드에서는 OPEN 상태 웨이브를 선택해야 합니다')
    }
    const payload: Record<string, string> = {}
    if (form.value.to_zone) payload.to_zone = form.value.to_zone

    const { data, error: rpcError } = await supabase.rpc('wms_create_work_order', {
      p_tenant_id: auth.currentTenantId,
      p_warehouse_id: auth.currentWarehouseId,
      p_work_order_type: 'PUTAWAY',
      p_linked_entity_type: 'receipt',
      p_linked_entity_id: form.value.linked_entity_id,
      p_equipment_type: form.value.equipment_type,
      p_zone_code: form.value.zone_code || null,
      p_command_type: form.value.command_type,
      p_command_payload: payload,
      p_dispatch_mode: form.value.dispatch_mode,
      p_actor_id: auth.userId,
      p_idempotency_key: crypto.randomUUID(),
      p_wave_id: form.value.dispatch_mode === 'WAVE' ? form.value.wave_id : null,
      p_correlation_id: null,
    })
    if (rpcError) throw rpcError
    applyWarnings(data, `업무 오더 ${shortId(data.work_order_id)} — ${data.status}`)
    await load()
  } catch (e: any) {
    error.value = e.message ?? String(e)
  } finally {
    submitting.value = null
  }
}

async function releaseWave(wave: any) {
  submitting.value = wave.wave_id
  error.value = ''
  try {
    const { data, error: rpcError } = await supabase.rpc('wms_release_dispatch_wave', {
      p_wave_id: wave.wave_id,
      p_actor_id: auth.userId,
      p_idempotency_key: crypto.randomUUID(),
      p_expected_version: wave.version,
      p_correlation_id: null,
    })
    if (rpcError) throw rpcError
    applyWarnings(
      data,
      `웨이브 릴리즈 — 디스패치 ${data.dispatched_count}건, 대기 ${data.queued_count}건`,
    )
    await load()
  } catch (e: any) {
    error.value = e.message ?? String(e)
  } finally {
    submitting.value = null
  }
}

async function retryDispatch(wo: any) {
  submitting.value = wo.work_order_id
  error.value = ''
  try {
    const { data, error: rpcError } = await supabase.rpc('wms_retry_work_order_dispatch', {
      p_work_order_id: wo.work_order_id,
      p_actor_id: auth.userId,
      p_idempotency_key: crypto.randomUUID(),
      p_expected_version: wo.version,
      p_correlation_id: null,
    })
    if (rpcError) throw rpcError
    applyWarnings(data, `업무 오더 ${shortId(wo.work_order_id)} — ${data.status}`)
    await load()
  } catch (e: any) {
    error.value = e.message ?? String(e)
  } finally {
    submitting.value = null
  }
}

async function cancelWorkOrder(wo: any) {
  submitting.value = wo.work_order_id
  error.value = ''
  try {
    const { data, error: rpcError } = await supabase.rpc('wms_cancel_work_order', {
      p_work_order_id: wo.work_order_id,
      p_actor_id: auth.userId,
      p_idempotency_key: crypto.randomUUID(),
      p_expected_version: wo.version,
      p_reason: '운영자 취소',
      p_correlation_id: null,
    })
    if (rpcError) throw rpcError
    notice.value = data.cancelled_equipment_command_id
      ? `업무 오더 취소 — 연결된 설비 명령 ${shortId(data.cancelled_equipment_command_id)}도 함께 취소`
      : '업무 오더 취소'
    await load()
  } catch (e: any) {
    error.value = e.message ?? String(e)
  } finally {
    submitting.value = null
  }
}

onMounted(load)
watch(() => auth.currentWarehouseId, load)
</script>

<template>
  <div>
    <h1>WES Dispatch</h1>
    <p class="hint">
      상위 WMS 작업 의도(입고 적치)를 업무 오더로 등록하고, Wave(배치 큐잉·릴리즈) 또는
      Waveless(즉시 디스패치) 전략으로 설비 명령으로 번역합니다. 현재 역할: {{ auth.currentRole }}
    </p>
    <div v-if="error" class="error-banner">{{ error }}</div>
    <div v-if="notice" class="notice-banner" data-testid="wes-notice">{{ notice }}</div>

    <div v-if="canOperate" class="card">
      <h2>디스패치 웨이브</h2>
      <p class="hint">웨이브는 "설비 명령을 언제 내보낼지"만 배치로 묶습니다. 창고당 여러 개를 동시에 열어 둘 수 있습니다.</p>
      <div class="row">
        <button class="primary" :disabled="submitting === 'open-wave'" @click="openWave">Open Wave</button>
      </div>
      <table v-if="waves.length > 0" class="inner">
        <thead>
          <tr>
            <th>Wave</th>
            <th>Status</th>
            <th>Version</th>
            <th>Work Orders</th>
            <th>Queued</th>
            <th>Action</th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="w in waves" :key="w.wave_id" :data-wave-id="w.wave_id">
            <td>{{ shortId(w.wave_id) }}</td>
            <td><span class="status" :class="statusClass(w.status)">{{ w.status }}</span></td>
            <td>{{ w.version }}</td>
            <td>{{ w.work_order_count }}</td>
            <td>{{ w.queued_count }}</td>
            <td>
              <button
                v-if="w.status === 'OPEN'"
                class="primary"
                :aria-label="`Release wave ${shortId(w.wave_id)}`"
                :disabled="submitting === w.wave_id"
                @click="releaseWave(w)"
              >
                Release Wave
              </button>
              <span v-else class="hint">릴리즈 완료</span>
            </td>
          </tr>
        </tbody>
      </table>
      <p v-else class="hint">개설된 웨이브가 없습니다.</p>
    </div>

    <div v-if="canOperate" class="card">
      <h2>업무 오더 등록</h2>
      <p class="hint">
        WAVELESS는 등록 즉시 가용 설비를 골라 디스패치합니다. WAVE는 릴리즈될 때까지 QUEUED로 대기합니다.
      </p>
      <div class="row">
        <label>
          Receipt
          <select v-model="form.linked_entity_id">
            <option v-for="r in receipts" :key="r.id" :value="r.id">
              {{ shortId(r.id) }} · {{ r.status }} · {{ r.expected_qty }}
            </option>
          </select>
        </label>
        <label>
          Equipment Type
          <select v-model="form.equipment_type">
            <option v-for="t in EQUIPMENT_TYPES" :key="t" :value="t">{{ t }}</option>
          </select>
        </label>
        <label>
          Target Zone
          <input v-model="form.zone_code" placeholder="ZONE-B" />
        </label>
        <label>
          Command
          <select v-model="form.command_type">
            <option v-for="c in COMMAND_TYPES" :key="c" :value="c">{{ c }}</option>
          </select>
        </label>
        <label>
          to_zone
          <input v-model="form.to_zone" placeholder="ZONE-C" />
        </label>
        <label>
          Dispatch Mode
          <select v-model="form.dispatch_mode">
            <option value="WAVE">WAVE</option>
            <option value="WAVELESS">WAVELESS</option>
          </select>
        </label>
        <label v-if="form.dispatch_mode === 'WAVE'">
          Wave
          <select v-model="form.wave_id">
            <option v-for="w in openWaves" :key="w.wave_id" :value="w.wave_id">
              {{ shortId(w.wave_id) }} (OPEN)
            </option>
          </select>
        </label>
        <button class="primary" :disabled="submitting === 'create-work-order'" @click="createWorkOrder">
          Create Work Order
        </button>
      </div>
    </div>

    <table v-if="!loading">
      <thead>
        <tr>
          <th>Work Order</th>
          <th>Type</th>
          <th>Mode</th>
          <th>Wave</th>
          <th>Target</th>
          <th>Status</th>
          <th>Version</th>
          <th>Equipment Command</th>
          <th v-if="canOperate">Actions</th>
        </tr>
      </thead>
      <tbody>
        <tr v-for="wo in workOrders" :key="wo.work_order_id" :data-work-order="wo.work_order_id">
          <td>{{ shortId(wo.work_order_id) }}</td>
          <td>{{ wo.work_order_type }}</td>
          <td>{{ wo.dispatch_mode }}</td>
          <td>{{ shortId(wo.wave_id) }}</td>
          <td>{{ wo.equipment_type }}{{ wo.zone_code ? ' / ' + wo.zone_code : '' }}</td>
          <td>
            <span class="status" :class="statusClass(wo.status)" data-testid="work-order-status">{{ wo.status }}</span>
          </td>
          <td>{{ wo.version }}</td>
          <td>
            <span v-if="wo.equipment_command" data-testid="command-summary">
              {{ wo.equipment_command.equipment_code }} · {{ wo.equipment_command.command_type }} /
              {{ wo.equipment_command.status }}
            </span>
            <span v-else class="hint">—</span>
          </td>
          <td v-if="canOperate">
            <div class="row">
              <button
                v-if="wo.status === 'QUEUED' && wo.wave_status !== 'OPEN'"
                class="primary"
                :aria-label="`Retry ${shortId(wo.work_order_id)}`"
                :disabled="submitting === wo.work_order_id"
                @click="retryDispatch(wo)"
              >
                Retry
              </button>
              <button
                v-if="['QUEUED', 'DISPATCHED'].includes(wo.status)"
                class="primary danger"
                :aria-label="`Cancel ${shortId(wo.work_order_id)}`"
                :disabled="submitting === wo.work_order_id"
                @click="cancelWorkOrder(wo)"
              >
                Cancel
              </button>
              <span v-if="['COMPLETED', 'FAILED', 'CANCELLED'].includes(wo.status)" class="hint">종결</span>
            </div>
          </td>
        </tr>
      </tbody>
    </table>
    <p v-if="!loading && workOrders.length === 0">등록된 업무 오더가 없습니다.</p>
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
table.inner {
  margin-top: 0.75rem;
}
td .row {
  margin-top: 0;
}
.notice-banner {
  background: #eef2ff;
  color: #3730a3;
  padding: 0.6rem 1rem;
  border-radius: 6px;
  margin-bottom: 1rem;
}
.status.muted-badge {
  background: #e2e8f0;
  color: #475569;
}
</style>
