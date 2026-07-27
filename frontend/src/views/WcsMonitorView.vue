<script setup lang="ts">
import { ref, watch, onMounted, computed } from 'vue'
import { useAuthStore } from '@/stores/auth'
import { supabase } from '@/lib/supabase'

// Real-time-ish WCS monitor: equipment status, open faults and the recent
// status/event feed (wms.equipment_status_events), plus the human-only fault
// resolution action. Polling rather than Supabase Realtime keeps this view in
// the same shape as the rest of the demo slice.

const auth = useAuthStore()
const rows = ref<any[]>([])
const loading = ref(false)
const error = ref('')
const submitting = ref<string | null>(null)
const noteByFault = ref<Record<string, string>>({})

const canResolve = computed(() =>
  ['WCS_OPERATOR', 'WAREHOUSE_MANAGER', 'WMS_ADMIN'].includes(auth.currentRole ?? ''),
)

function statusClass(status: string) {
  if (status === 'FAULT') return 'danger'
  if (status === 'RUNNING' || status === 'IDLE') return 'ok'
  return 'warn'
}

async function load() {
  if (!auth.currentTenantId || !auth.currentWarehouseId) return
  loading.value = true
  error.value = ''
  try {
    const { data, error: rpcError } = await supabase.rpc('wms_get_equipment_status', {
      p_tenant_id: auth.currentTenantId,
      p_warehouse_id: auth.currentWarehouseId,
      p_equipment_id: null,
      p_event_limit: 8,
    })
    if (rpcError) throw rpcError
    rows.value = data?.equipment ?? []
  } catch (e: any) {
    error.value = e.message ?? String(e)
  } finally {
    loading.value = false
  }
}

async function resolveFault(fault: any) {
  submitting.value = fault.fault_id
  error.value = ''
  try {
    const note = noteByFault.value[fault.fault_id]
    if (!note) throw new Error('해소 사유(resolution_note)가 필요합니다')
    const { error: rpcError } = await supabase.rpc('wms_resolve_equipment_fault', {
      p_fault_id: fault.fault_id,
      p_resolution_note: note,
      p_actor_id: auth.userId,
      p_idempotency_key: crypto.randomUUID(),
      p_expected_version: fault.version,
      p_correlation_id: null,
    })
    if (rpcError) throw rpcError
    noteByFault.value[fault.fault_id] = ''
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
    <h1>WCS Monitor</h1>
    <p class="hint">
      설비 상태·장애·최근 이벤트 모니터링. 장애 해소는 현장 확인을 거친 사람만 수행할 수 있습니다.
      현재 역할: {{ auth.currentRole }}
    </p>
    <div class="row">
      <button class="primary" @click="load">Refresh</button>
    </div>
    <div v-if="error" class="error-banner">{{ error }}</div>

    <div v-for="e in rows" :key="e.equipment_id" class="card" :data-equipment-code="e.equipment_code">
      <div class="head">
        <strong>{{ e.equipment_code }}</strong>
        <span class="muted">{{ e.equipment_type }} · {{ e.zone_code }}</span>
        <span class="status" :class="statusClass(e.status)">{{ e.status }}</span>
        <span class="muted">v{{ e.version }}</span>
      </div>

      <div v-if="e.open_faults.length > 0" class="faults">
        <div v-for="f in e.open_faults" :key="f.fault_id" class="fault">
          <span class="status danger">{{ f.severity }}</span>
          <strong>{{ f.fault_code }}</strong>
          <template v-if="canResolve">
            <input
              v-model="noteByFault[f.fault_id]"
              :aria-label="`resolution note for ${e.equipment_code}`"
              placeholder="해소 사유 (필수)"
            />
            <button class="primary" :disabled="submitting === f.fault_id" @click="resolveFault(f)">
              Resolve Fault
            </button>
          </template>
          <span v-else class="muted">해소 권한이 없습니다 (WCS_OPERATOR 필요)</span>
        </div>
      </div>

      <div v-if="e.active_commands.length > 0" class="muted commands">
        진행 중 명령:
        <span v-for="c in e.active_commands" :key="c.command_id">{{ c.command_type }} ({{ c.status }})</span>
      </div>

      <table v-if="e.recent_events.length > 0" class="events">
        <thead>
          <tr>
            <th>Event</th>
            <th>From</th>
            <th>To</th>
            <th>Detail</th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="ev in e.recent_events" :key="ev.event_id">
            <td>{{ ev.event_type }}</td>
            <td>{{ ev.previous_status }}</td>
            <td>{{ ev.new_status }}</td>
            <td class="muted">{{ ev.detail ? JSON.stringify(ev.detail) : '—' }}</td>
          </tr>
        </tbody>
      </table>
      <p v-else class="muted">아직 기록된 이벤트가 없습니다.</p>
    </div>
    <p v-if="!loading && rows.length === 0">등록된 설비가 없습니다.</p>
  </div>
</template>

<style scoped>
.hint {
  color: var(--muted);
  margin-top: -0.5rem;
}
.row {
  display: flex;
  gap: 0.5rem;
  align-items: center;
  margin-bottom: 0.75rem;
}
.head {
  display: flex;
  gap: 0.6rem;
  align-items: center;
  margin-bottom: 0.5rem;
}
.muted {
  color: var(--muted);
  font-size: 0.85rem;
}
.faults {
  margin-bottom: 0.5rem;
}
.fault {
  display: flex;
  gap: 0.5rem;
  align-items: center;
  background: #fef2f2;
  border: 1px solid #fecaca;
  border-radius: 6px;
  padding: 0.5rem 0.75rem;
  margin-bottom: 0.4rem;
}
.commands {
  margin-bottom: 0.5rem;
}
.commands span {
  margin-right: 0.4rem;
}
input {
  padding: 0.4rem;
  border: 1px solid var(--line);
  border-radius: 6px;
  flex: 1;
}
table.events {
  margin-top: 0.5rem;
}
</style>
