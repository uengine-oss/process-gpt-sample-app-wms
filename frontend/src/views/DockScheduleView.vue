<script setup lang="ts">
import { ref, watch, onMounted, computed } from 'vue'
import { useAuthStore } from '@/stores/auth'
import { supabase } from '@/lib/supabase'

// Yard & dock scheduling (openspec change add-yard-dock-scheduling).
//
// Reads through wms_get_dock_schedule so each dock arrives with its own
// appointment list already ordered by start time; writes go through the
// SECURITY DEFINER RPCs, exactly like every other view in this app.
//
// The "timeline" here is deliberately a table by dock and time, not a
// calendar widget — the contract's job is to make double booking impossible,
// and a plain table shows that just as well.

const auth = useAuthStore()
const docks = ref<any[]>([])
const pos = ref<any[]>([])
const loading = ref(false)
const error = ref('')
const notice = ref('')
const submitting = ref<string | null>(null)

// default the board to today
function todayISO() {
  return new Date().toISOString().slice(0, 10)
}
const day = ref(todayISO())

const dockForm = ref({ code: '', name: '' })
const apptForm = ref({
  dock_id: '',
  appointment_type: 'INBOUND',
  po_id: '',
  start_time: '09:00',
  end_time: '10:00',
  carrier_name: '',
  vehicle_plate_no: '',
})

const canManageDocks = computed(() =>
  ['WMS_ADMIN', 'WAREHOUSE_MANAGER'].includes(auth.currentRole ?? ''),
)
const canBook = computed(() =>
  ['WMS_ADMIN', 'INBOUND_OPERATOR', 'PROCESS_AGENT'].includes(auth.currentRole ?? ''),
)
// design.md D5: the three physical events are human-only.
const canMoveVehicles = computed(() =>
  ['WMS_ADMIN', 'INBOUND_OPERATOR'].includes(auth.currentRole ?? ''),
)

function dockStatusClass(status: string) {
  if (status === 'AVAILABLE') return 'ok'
  if (status === 'OCCUPIED') return 'warn'
  return 'danger'
}

function apptStatusClass(status: string) {
  if (status === 'AT_DOCK') return 'warn'
  if (status === 'DEPARTED') return 'ok'
  if (status === 'CANCELLED') return 'danger'
  return ''
}

function hhmm(ts: string) {
  return new Date(ts).toLocaleTimeString('ko-KR', { hour: '2-digit', minute: '2-digit', hour12: false })
}

/** A local wall-clock `YYYY-MM-DD` + `HH:MM` turned into an absolute instant. */
function instant(dayStr: string, time: string) {
  return new Date(`${dayStr}T${time}:00`).toISOString()
}

const dayStart = computed(() => instant(day.value, '00:00'))
const dayEnd = computed(() => {
  const d = new Date(`${day.value}T00:00:00`)
  d.setDate(d.getDate() + 1)
  return d.toISOString()
})

const rows = computed(() =>
  docks.value.flatMap((d: any) =>
    (d.appointments ?? []).map((a: any) => ({ ...a, dock_code: d.code, dock_status: d.status })),
  ),
)

async function load() {
  if (!auth.currentTenantId || !auth.currentWarehouseId) return
  loading.value = true
  error.value = ''
  try {
    const { data, error: rpcError } = await supabase.rpc('wms_get_dock_schedule', {
      p_tenant_id: auth.currentTenantId,
      p_warehouse_id: auth.currentWarehouseId,
      p_from: dayStart.value,
      p_to: dayEnd.value,
      p_dock_id: null,
      p_include_closed: true,
    })
    if (rpcError) throw rpcError
    docks.value = data?.docks ?? []
    if (!apptForm.value.dock_id) apptForm.value.dock_id = docks.value[0]?.dock_id ?? ''

    // Confirmed POs are what an inbound appointment books against.
    const { data: poData, error: poError } = await supabase
      .from('purchase_orders')
      .select('id, status, qty, created_at')
      .eq('warehouse_id', auth.currentWarehouseId)
      .in('status', ['CONFIRMED_PO', 'APPROVED'])
      .order('created_at', { ascending: false })
    if (poError) throw poError
    pos.value = poData ?? []
    if (!apptForm.value.po_id) apptForm.value.po_id = pos.value[0]?.id ?? ''
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

function registerDock() {
  return run('register', async () => {
    if (!dockForm.value.code) throw new Error('도크 코드가 필요합니다')
    if (!dockForm.value.name) throw new Error('도크 이름이 필요합니다')
    const { error: rpcError } = await supabase.rpc('wms_register_dock', {
      p_tenant_id: auth.currentTenantId,
      p_warehouse_id: auth.currentWarehouseId,
      p_code: dockForm.value.code,
      p_name: dockForm.value.name,
      p_actor_id: auth.userId,
      p_idempotency_key: crypto.randomUUID(),
      p_correlation_id: null,
    })
    if (rpcError) throw rpcError
    notice.value = `도크 ${dockForm.value.code} 등록 완료 (AVAILABLE)`
    dockForm.value = { code: '', name: '' }
  })
}

function scheduleAppointment() {
  return run('schedule', async () => {
    if (!apptForm.value.dock_id) throw new Error('도크를 선택하세요')
    const isInbound = apptForm.value.appointment_type === 'INBOUND'
    if (isInbound && !apptForm.value.po_id) throw new Error('INBOUND 예약에는 PO가 필요합니다')
    const { error: rpcError } = await supabase.rpc('wms_schedule_dock_appointment', {
      p_dock_id: apptForm.value.dock_id,
      p_scheduled_start: instant(day.value, apptForm.value.start_time),
      p_scheduled_end: instant(day.value, apptForm.value.end_time),
      p_actor_id: auth.userId,
      p_idempotency_key: crypto.randomUUID(),
      p_appointment_type: apptForm.value.appointment_type,
      p_po_id: isInbound ? apptForm.value.po_id : null,
      p_carrier_name: apptForm.value.carrier_name || null,
      p_vehicle_plate_no: apptForm.value.vehicle_plate_no || null,
      p_linked_entity_type: null,
      p_linked_entity_id: null,
      p_correlation_id: null,
    })
    if (rpcError) throw rpcError
    notice.value = '예약이 등록되었습니다 (SCHEDULED)'
  })
}

function cancelAppointment(a: any) {
  return run(a.appointment_id, async () => {
    const { error: rpcError } = await supabase.rpc('wms_cancel_dock_appointment', {
      p_appointment_id: a.appointment_id,
      p_actor_id: auth.userId,
      p_idempotency_key: crypto.randomUUID(),
      p_expected_version: a.version,
      p_reason: '화면에서 취소',
      p_correlation_id: null,
    })
    if (rpcError) throw rpcError
    notice.value = '예약이 취소되었습니다 — 해당 시간창은 다시 예약할 수 있습니다'
  })
}

function checkIn(a: any) {
  return run(a.appointment_id, async () => {
    const { error: rpcError } = await supabase.rpc('wms_check_in_vehicle', {
      p_appointment_id: a.appointment_id,
      p_actor_id: auth.userId,
      p_idempotency_key: crypto.randomUUID(),
      p_expected_version: a.version,
      p_carrier_name: null,
      p_vehicle_plate_no: null,
      p_correlation_id: null,
    })
    if (rpcError) throw rpcError
    notice.value = '차량이 야드에 체크인했습니다 (도크는 아직 점유되지 않습니다)'
  })
}

function dockVehicle(a: any) {
  return run(a.appointment_id, async () => {
    const { error: rpcError } = await supabase.rpc('wms_dock_vehicle', {
      p_appointment_id: a.appointment_id,
      p_actor_id: auth.userId,
      p_idempotency_key: crypto.randomUUID(),
      p_expected_version: a.version,
      p_correlation_id: null,
    })
    if (rpcError) throw rpcError
    notice.value = '차량이 도킹했습니다 — 도크가 OCCUPIED로 전환되었습니다'
  })
}

function departVehicle(a: any) {
  return run(a.appointment_id, async () => {
    const { data, error: rpcError } = await supabase.rpc('wms_depart_vehicle', {
      p_appointment_id: a.appointment_id,
      p_actor_id: auth.userId,
      p_idempotency_key: crypto.randomUUID(),
      p_expected_version: a.version,
      p_correlation_id: null,
    })
    if (rpcError) throw rpcError
    notice.value = (data?.warnings ?? []).includes('DOCK_CLOSED_NOT_RELEASED')
      ? '출차 완료 — 다만 도크가 정비로 CLOSED 상태라 AVAILABLE로 되돌리지 않았습니다'
      : '출차 완료 — 도크가 AVAILABLE로 되돌아갔습니다'
  })
}

function setDockStatus(d: any, newStatus: string) {
  return run(d.dock_id, async () => {
    const { error: rpcError } = await supabase.rpc('wms_set_dock_status', {
      p_dock_id: d.dock_id,
      p_new_status: newStatus,
      p_actor_id: auth.userId,
      p_idempotency_key: crypto.randomUUID(),
      p_expected_version: d.version,
      p_reason: newStatus === 'CLOSED' ? '정비' : null,
      p_correlation_id: null,
    })
    if (rpcError) throw rpcError
    notice.value = `도크 ${d.code} → ${newStatus}`
  })
}

onMounted(load)
watch(() => auth.currentWarehouseId, load)
watch(day, load)
</script>

<template>
  <div>
    <h1>Dock Schedule</h1>
    <p class="hint">
      입출고 차량의 도크 예약(Dock Appointment Scheduling)과 야드 체크인 → 도킹 → 출차 추적.
      같은 도크에 겹치는 시간창은 DB 레벨에서 거부됩니다. 현재 역할: {{ auth.currentRole }}
    </p>
    <div v-if="error" class="error-banner" data-testid="dock-error">{{ error }}</div>
    <div v-if="notice" class="notice-banner" data-testid="dock-notice">{{ notice }}</div>

    <div class="card">
      <div class="row">
        <label>
          조회 날짜
          <input v-model="day" type="date" aria-label="Schedule Date" />
        </label>
        <button class="primary" @click="load">Refresh</button>
      </div>
    </div>

    <div v-if="canManageDocks" class="card">
      <h2>도크 등록</h2>
      <p class="hint">등록 직후 상태는 AVAILABLE입니다. 창고 안에서 코드는 중복될 수 없습니다.</p>
      <div class="row">
        <label>
          Dock Code
          <input v-model="dockForm.code" placeholder="DOCK-04" />
        </label>
        <label>
          Dock Name
          <input v-model="dockForm.name" placeholder="입고 하역장 4" />
        </label>
        <button class="primary" :disabled="submitting === 'register'" @click="registerDock">
          Register Dock
        </button>
      </div>
    </div>

    <div v-if="canBook" class="card">
      <h2>도크 예약</h2>
      <p class="hint">
        시간창은 반열림 구간입니다 — 09:00~10:00 예약과 10:00~11:00 예약은 겹치지 않습니다.
        겹치면 CONFLICT 오류가 위에 표시됩니다.
      </p>
      <div class="row">
        <label>
          Dock
          <select v-model="apptForm.dock_id" aria-label="Appointment Dock">
            <option v-for="d in docks" :key="d.dock_id" :value="d.dock_id">
              {{ d.code }} ({{ d.status }})
            </option>
          </select>
        </label>
        <label>
          Type
          <select v-model="apptForm.appointment_type" aria-label="Appointment Type">
            <option value="INBOUND">INBOUND</option>
            <option value="OUTBOUND">OUTBOUND</option>
          </select>
        </label>
        <label v-if="apptForm.appointment_type === 'INBOUND'">
          Purchase Order
          <select v-model="apptForm.po_id" aria-label="Appointment PO">
            <option v-for="p in pos" :key="p.id" :value="p.id">
              {{ p.id.slice(0, 8) }} · {{ p.status }} · qty {{ p.qty }}
            </option>
          </select>
        </label>
        <label>
          Start
          <input v-model="apptForm.start_time" type="time" aria-label="Appointment Start" />
        </label>
        <label>
          End
          <input v-model="apptForm.end_time" type="time" aria-label="Appointment End" />
        </label>
        <label>
          Carrier
          <input v-model="apptForm.carrier_name" aria-label="Appointment Carrier" placeholder="한빛운수" />
        </label>
        <label>
          Plate No
          <input v-model="apptForm.vehicle_plate_no" aria-label="Appointment Plate" placeholder="12가3456" />
        </label>
        <button class="primary" :disabled="submitting === 'schedule'" @click="scheduleAppointment">
          Schedule Appointment
        </button>
      </div>
      <p v-if="apptForm.appointment_type === 'INBOUND' && pos.length === 0" class="hint">
        예약 가능한 PO가 없습니다 — 구매 발주를 먼저 확정하세요.
      </p>
    </div>

    <h2 class="board-title">도크 현황</h2>
    <table>
      <thead>
        <tr>
          <th>Dock</th>
          <th>Name</th>
          <th>Status</th>
          <th>Version</th>
          <th>오늘 예약</th>
          <th v-if="canManageDocks">정비</th>
        </tr>
      </thead>
      <tbody>
        <tr v-for="d in docks" :key="d.dock_id" :data-dock-code="d.code">
          <td>{{ d.code }}</td>
          <td>{{ d.name }}</td>
          <td><span class="status" :class="dockStatusClass(d.status)">{{ d.status }}</span></td>
          <td>{{ d.version }}</td>
          <td>{{ (d.appointments ?? []).filter((a: any) => a.is_active).length }}</td>
          <td v-if="canManageDocks">
            <button
              v-if="d.status === 'AVAILABLE'"
              class="primary"
              :disabled="submitting === d.dock_id"
              :aria-label="`close ${d.code}`"
              @click="setDockStatus(d, 'CLOSED')"
            >
              Close
            </button>
            <button
              v-else-if="d.status === 'CLOSED'"
              class="primary"
              :disabled="submitting === d.dock_id"
              :aria-label="`reopen ${d.code}`"
              @click="setDockStatus(d, 'AVAILABLE')"
            >
              Reopen
            </button>
            <span v-else class="hint">점유 중 — 출차 후 가능</span>
          </td>
        </tr>
      </tbody>
    </table>
    <p v-if="!loading && docks.length === 0">등록된 도크가 없습니다.</p>

    <h2 class="board-title">{{ day }} 예약 타임라인</h2>
    <table>
      <thead>
        <tr>
          <th>Dock</th>
          <th>Window</th>
          <th>Type</th>
          <th>Carrier / Plate</th>
          <th>Status</th>
          <th>Version</th>
          <th>Actions</th>
        </tr>
      </thead>
      <tbody>
        <tr
          v-for="a in rows"
          :key="a.appointment_id"
          :data-appointment-id="a.appointment_id"
          :data-window="`${a.dock_code} ${hhmm(a.scheduled_start)}`"
        >
          <td>{{ a.dock_code }}</td>
          <td>{{ hhmm(a.scheduled_start) }}–{{ hhmm(a.scheduled_end) }}</td>
          <td>{{ a.appointment_type }}</td>
          <td>{{ [a.carrier_name, a.vehicle_plate_no].filter(Boolean).join(' / ') || '—' }}</td>
          <td><span class="status" :class="apptStatusClass(a.status)">{{ a.status }}</span></td>
          <td>{{ a.version }}</td>
          <td>
            <div class="row actions">
              <template v-if="canMoveVehicles">
                <button
                  v-if="a.status === 'SCHEDULED'"
                  class="primary"
                  :disabled="submitting === a.appointment_id"
                  @click="checkIn(a)"
                >
                  Check In
                </button>
                <button
                  v-if="a.status === 'CHECKED_IN'"
                  class="primary"
                  :disabled="submitting === a.appointment_id"
                  @click="dockVehicle(a)"
                >
                  Dock Vehicle
                </button>
                <button
                  v-if="a.status === 'AT_DOCK'"
                  class="primary"
                  :disabled="submitting === a.appointment_id"
                  @click="departVehicle(a)"
                >
                  Depart
                </button>
              </template>
              <button
                v-if="canBook && ['SCHEDULED', 'CHECKED_IN'].includes(a.status)"
                class="primary danger"
                :disabled="submitting === a.appointment_id"
                @click="cancelAppointment(a)"
              >
                Cancel
              </button>
              <span v-if="['DEPARTED', 'CANCELLED'].includes(a.status)" class="hint">종료</span>
            </div>
          </td>
        </tr>
      </tbody>
    </table>
    <p v-if="!loading && rows.length === 0">{{ day }}에 예약이 없습니다.</p>
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
.notice-banner {
  background: #dcfce7;
  color: #166534;
  padding: 0.6rem 1rem;
  border-radius: 6px;
  margin-bottom: 1rem;
}
</style>
