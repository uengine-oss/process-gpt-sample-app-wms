<script setup lang="ts">
import { ref, watch, onMounted, computed } from 'vue'
import { useAuthStore } from '@/stores/auth'
import { supabase } from '@/lib/supabase'

// WCS equipment registry (openspec change add-wcs-equipment-control-contract).
// Reads through wms_get_equipment_status so the list already carries the
// derived "is anything in flight" flag; writes go through the SECURITY
// DEFINER RPCs, exactly like every other view in this app.

const auth = useAuthStore()
const rows = ref<any[]>([])
const loading = ref(false)
const error = ref('')
const submitting = ref<string | null>(null)

const form = ref({ equipment_code: '', equipment_type: 'AGV', zone_code: '' })
const targetZoneById = ref<Record<string, string>>({})

const EQUIPMENT_TYPES = ['SRM', 'CONVEYOR', 'SORTER', 'AGV', 'AMR', 'ROBOT_CELL']

const canRegister = computed(() => ['WMS_ADMIN', 'WAREHOUSE_MANAGER'].includes(auth.currentRole ?? ''))
const canDispatch = computed(() => ['WAREHOUSE_MANAGER', 'WCS_OPERATOR'].includes(auth.currentRole ?? ''))

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
      p_event_limit: 5,
    })
    if (rpcError) throw rpcError
    rows.value = data?.equipment ?? []
  } catch (e: any) {
    error.value = e.message ?? String(e)
  } finally {
    loading.value = false
  }
}

async function registerEquipment() {
  submitting.value = 'register'
  error.value = ''
  try {
    if (!form.value.equipment_code) throw new Error('설비 코드가 필요합니다')
    const { error: rpcError } = await supabase.rpc('wms_register_equipment', {
      p_tenant_id: auth.currentTenantId,
      p_warehouse_id: auth.currentWarehouseId,
      p_equipment_code: form.value.equipment_code,
      p_equipment_type: form.value.equipment_type,
      p_zone_code: form.value.zone_code || null,
      p_actor_id: auth.userId,
      p_idempotency_key: crypto.randomUUID(),
      p_correlation_id: null,
    })
    if (rpcError) throw rpcError
    form.value = { equipment_code: '', equipment_type: 'AGV', zone_code: '' }
    await load()
  } catch (e: any) {
    error.value = e.message ?? String(e)
  } finally {
    submitting.value = null
  }
}

async function dispatchMove(equipment: any) {
  submitting.value = equipment.equipment_id
  error.value = ''
  try {
    const toZone = targetZoneById.value[equipment.equipment_id]
    if (!toZone) throw new Error('목적지 구역(to_zone)이 필요합니다')
    const { error: rpcError } = await supabase.rpc('wms_dispatch_equipment_command', {
      p_equipment_id: equipment.equipment_id,
      p_command_type: 'MOVE',
      p_payload: { to_zone: toZone },
      p_actor_id: auth.userId,
      p_idempotency_key: crypto.randomUUID(),
      p_expected_version: equipment.version,
      p_correlation_id: null,
      p_linked_entity_type: null,
      p_linked_entity_id: null,
    })
    if (rpcError) throw rpcError
    targetZoneById.value[equipment.equipment_id] = ''
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
    <h1>WCS Equipment</h1>
    <p class="hint">
      자동화 설비(SRM/컨베이어/분류기/AGV/AMR/로봇 셀) 레지스트리와 제어 명령 디스패치.
      현재 역할: {{ auth.currentRole }}
    </p>
    <div v-if="error" class="error-banner">{{ error }}</div>

    <div v-if="canRegister" class="card">
      <h2>설비 등록</h2>
      <p class="hint">등록 직후 상태는 OFFLINE이며, 설비가 기동하면 WCS 게이트웨이가 IDLE로 보고합니다.</p>
      <div class="row">
        <label>
          Equipment Code
          <input v-model="form.equipment_code" placeholder="AGV-07" />
        </label>
        <label>
          Type
          <select v-model="form.equipment_type">
            <option v-for="t in EQUIPMENT_TYPES" :key="t" :value="t">{{ t }}</option>
          </select>
        </label>
        <label>
          Zone
          <input v-model="form.zone_code" placeholder="ZONE-B" />
        </label>
        <button class="primary" :disabled="submitting === 'register'" @click="registerEquipment">
          Register Equipment
        </button>
      </div>
    </div>

    <table v-if="!loading">
      <thead>
        <tr>
          <th>Code</th>
          <th>Type</th>
          <th>Zone</th>
          <th>Status</th>
          <th>Version</th>
          <th>In-flight</th>
          <th v-if="canDispatch">Dispatch</th>
        </tr>
      </thead>
      <tbody>
        <tr v-for="e in rows" :key="e.equipment_id" :data-equipment-code="e.equipment_code">
          <td>{{ e.equipment_code }}</td>
          <td>{{ e.equipment_type }}</td>
          <td>{{ e.zone_code }}</td>
          <td><span class="status" :class="statusClass(e.status)">{{ e.status }}</span></td>
          <td>{{ e.version }}</td>
          <td>{{ e.has_active_command ? e.active_commands[0]?.command_type + ' / ' + e.active_commands[0]?.status : '—' }}</td>
          <td v-if="canDispatch">
            <div v-if="e.status === 'IDLE'" class="row">
              <input
                v-model="targetZoneById[e.equipment_id]"
                :aria-label="`to_zone for ${e.equipment_code}`"
                placeholder="ZONE-C"
              />
              <button class="primary" :disabled="submitting === e.equipment_id" @click="dispatchMove(e)">
                Dispatch MOVE
              </button>
            </div>
            <span v-else class="hint">{{ e.status === 'FAULT' ? '장애 해소 후 가능' : '대기(IDLE) 상태에서만 가능' }}</span>
          </td>
        </tr>
      </tbody>
    </table>
    <p v-if="!loading && rows.length === 0">등록된 설비가 없습니다.</p>
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
td .row {
  margin-top: 0;
}
</style>
