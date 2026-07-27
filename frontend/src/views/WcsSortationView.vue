<script setup lang="ts">
import { ref, watch, onMounted, computed } from 'vue'
import { useAuthStore } from '@/stores/auth'
import { supabase } from '@/lib/supabase'

// Sortation profiles + sorter commands (openspec change add-wcs-sortation-logic).
// Reads through wms_get_sortation_profile, which already returns every
// SORTER/CONVEYOR in the warehouse with its profile (null when not registered
// yet), its in-flight DIVERT/SET_SPEED commands and the last reported outcome.
//
// DIVERT / SET_SPEED have no RPC of their own on purpose: they reuse
// wms_wcs-equipment-control's wms_dispatch_equipment_command with the payload
// shape this contract defines. That is also why two different role sets are in
// play here — tuning a profile and dispatching a command are not the same
// permission (the shipped dispatch RPC excludes WMS_ADMIN).

const auth = useAuthStore()
const rows = ref<any[]>([])
const loading = ref(false)
const error = ref('')
const notice = ref('')
const submitting = ref<string | null>(null)

type ProfileForm = {
  min_carton_gap_mm: number
  speed_mode: string
  min_speed_value: number
  max_speed_value: number
  speed_unit: string
  sensor_detection_window_ms: number
  status: string
}

const profileForms = ref<Record<string, ProfileForm>>({})
const divertForms = ref<Record<string, { target_chute: string; item_identifier: string; expected_gap_mm: string }>>({})
const speedForms = ref<Record<string, { speed_mode: string; speed_value: string }>>({})

const canManageProfile = computed(() =>
  ['WMS_ADMIN', 'WAREHOUSE_MANAGER', 'WCS_OPERATOR'].includes(auth.currentRole ?? ''),
)
// mirrors the shipped wms_dispatch_equipment_command role set — WMS_ADMIN is
// deliberately not in it (see the migration header, DEVIATION 2).
const canDispatch = computed(() =>
  ['WAREHOUSE_MANAGER', 'WCS_OPERATOR', 'PROCESS_AGENT'].includes(auth.currentRole ?? ''),
)

function statusClass(status: string) {
  if (status === 'FAULT' || status === 'INACTIVE') return 'danger'
  if (status === 'RUNNING' || status === 'IDLE' || status === 'ACTIVE') return 'ok'
  return 'warn'
}

function outcomeClass(outcome: string) {
  if (outcome === 'JAM') return 'danger'
  if (outcome === 'MISROUTE') return 'warn'
  return 'ok'
}

function defaultForm(row: any): ProfileForm {
  const p = row.profile
  return p
    ? {
        min_carton_gap_mm: p.min_carton_gap_mm,
        speed_mode: p.speed_mode,
        min_speed_value: Number(p.min_speed_value),
        max_speed_value: Number(p.max_speed_value),
        speed_unit: p.speed_unit,
        sensor_detection_window_ms: p.sensor_detection_window_ms,
        status: p.status,
      }
    : {
        min_carton_gap_mm: 150,
        speed_mode: 'FIXED',
        min_speed_value: 0.5,
        max_speed_value: 2.0,
        speed_unit: 'MPS',
        sensor_detection_window_ms: 80,
        status: 'ACTIVE',
      }
}

async function load() {
  if (!auth.currentTenantId || !auth.currentWarehouseId) return
  loading.value = true
  error.value = ''
  try {
    const { data, error: rpcError } = await supabase.rpc('wms_get_sortation_profile', {
      p_tenant_id: auth.currentTenantId,
      p_warehouse_id: auth.currentWarehouseId,
      p_equipment_id: null,
    })
    if (rpcError) throw rpcError
    rows.value = data?.items ?? []
    for (const row of rows.value) {
      profileForms.value[row.equipment_id] = defaultForm(row)
      divertForms.value[row.equipment_id] ??= { target_chute: '', item_identifier: '', expected_gap_mm: '' }
      speedForms.value[row.equipment_id] ??= { speed_mode: 'FIXED', speed_value: '' }
    }
  } catch (e: any) {
    error.value = e.message ?? String(e)
  } finally {
    loading.value = false
  }
}

async function createProfile(row: any) {
  submitting.value = row.equipment_id
  error.value = ''
  notice.value = ''
  try {
    const f = profileForms.value[row.equipment_id]
    const { data, error: rpcError } = await supabase.rpc('wms_create_sortation_profile', {
      p_equipment_id: row.equipment_id,
      p_min_carton_gap_mm: Number(f.min_carton_gap_mm),
      p_min_speed_value: Number(f.min_speed_value),
      p_max_speed_value: Number(f.max_speed_value),
      p_sensor_detection_window_ms: Number(f.sensor_detection_window_ms),
      p_actor_id: auth.userId,
      p_idempotency_key: crypto.randomUUID(),
      p_speed_mode: f.speed_mode,
      p_speed_unit: f.speed_unit,
      p_correlation_id: null,
    })
    if (rpcError) throw rpcError
    notice.value = `${row.equipment_code} 프로파일 등록 완료 (version ${data.version}) — 이제 DIVERT/SET_SPEED를 보낼 수 있습니다.`
    await load()
  } catch (e: any) {
    error.value = e.message ?? String(e)
  } finally {
    submitting.value = null
  }
}

async function saveProfile(row: any) {
  submitting.value = row.equipment_id
  error.value = ''
  notice.value = ''
  try {
    const f = profileForms.value[row.equipment_id]
    const { data, error: rpcError } = await supabase.rpc('wms_update_sortation_profile', {
      p_profile_id: row.profile.profile_id,
      p_actor_id: auth.userId,
      p_idempotency_key: crypto.randomUUID(),
      p_expected_version: row.profile.version,
      p_min_carton_gap_mm: Number(f.min_carton_gap_mm),
      p_speed_mode: f.speed_mode,
      p_min_speed_value: Number(f.min_speed_value),
      p_max_speed_value: Number(f.max_speed_value),
      p_speed_unit: f.speed_unit,
      p_sensor_detection_window_ms: Number(f.sensor_detection_window_ms),
      p_status: f.status,
      p_correlation_id: null,
    })
    if (rpcError) throw rpcError
    notice.value = (data.warnings ?? []).length
      ? `${row.equipment_code} 프로파일 저장 (version ${data.version}) — ${data.warnings.join(', ')}`
      : `${row.equipment_code} 프로파일 저장 완료 (version ${data.version})`
    await load()
  } catch (e: any) {
    error.value = e.message ?? String(e)
  } finally {
    submitting.value = null
  }
}

async function dispatchSortationCommand(row: any, commandType: string, payload: Record<string, unknown>) {
  submitting.value = row.equipment_id
  error.value = ''
  notice.value = ''
  try {
    const { data, error: rpcError } = await supabase.rpc('wms_dispatch_equipment_command', {
      p_equipment_id: row.equipment_id,
      p_command_type: commandType,
      p_payload: payload,
      p_actor_id: auth.userId,
      p_idempotency_key: crypto.randomUUID(),
      p_expected_version: row.equipment_version,
      p_correlation_id: null,
      p_linked_entity_type: null,
      p_linked_entity_id: null,
    })
    if (rpcError) throw rpcError
    notice.value = `${row.equipment_code} — ${commandType} 명령이 ${data.status} 상태로 생성되었습니다.`
    await load()
  } catch (e: any) {
    error.value = e.message ?? String(e)
  } finally {
    submitting.value = null
  }
}

async function dispatchDivert(row: any) {
  const f = divertForms.value[row.equipment_id]
  const payload: Record<string, unknown> = {
    target_chute: f.target_chute,
    item_identifier: f.item_identifier,
  }
  if (f.expected_gap_mm !== '') payload.expected_gap_mm = Number(f.expected_gap_mm)
  await dispatchSortationCommand(row, 'DIVERT', payload)
  if (!error.value) divertForms.value[row.equipment_id] = { target_chute: '', item_identifier: '', expected_gap_mm: '' }
}

async function dispatchSetSpeed(row: any) {
  const f = speedForms.value[row.equipment_id]
  const payload: Record<string, unknown> = {
    speed_mode: f.speed_mode,
    speed_unit: row.profile.speed_unit,
  }
  if (f.speed_mode === 'FIXED') payload.speed_value = Number(f.speed_value)
  await dispatchSortationCommand(row, 'SET_SPEED', payload)
}

onMounted(load)
watch(() => auth.currentWarehouseId, load)
</script>

<template>
  <div>
    <h1>WCS Sortation</h1>
    <p class="hint">
      분류 설비(SORTER/CONVEYOR)의 화물 간격·속도 범위·센서 감지 윈도우를 관리하고,
      슈트 Divert와 속도 조정 명령을 보냅니다. 현재 역할: {{ auth.currentRole }}
    </p>
    <div class="row">
      <button class="primary" @click="load">Refresh</button>
    </div>
    <div v-if="error" class="error-banner">{{ error }}</div>
    <div v-if="notice" class="notice-banner" data-testid="sortation-notice">{{ notice }}</div>
    <p v-if="canManageProfile && !canDispatch" class="hint role-note" data-testid="role-note">
      이 역할은 프로파일을 관리할 수 있지만 설비 명령은 보낼 수 없습니다
      (명령 디스패치는 WAREHOUSE_MANAGER / WCS_OPERATOR / PROCESS_AGENT).
    </p>

    <div v-for="e in rows" :key="e.equipment_id" class="card" :data-equipment-code="e.equipment_code">
      <div class="head">
        <strong>{{ e.equipment_code }}</strong>
        <span class="muted">{{ e.equipment_type }} · {{ e.zone_code }}</span>
        <span class="status" :class="statusClass(e.equipment_status)">{{ e.equipment_status }}</span>
        <span class="muted">v{{ e.equipment_version }}</span>
        <span v-if="e.last_outcome" class="status" :class="outcomeClass(e.last_outcome)" data-testid="last-outcome">
          최근 분류 결과: {{ e.last_outcome }}
        </span>
      </div>

      <!-- profile: values + registration/edit -->
      <div class="profile">
        <div v-if="e.has_profile" class="summary" data-testid="profile-summary">
          <span>간격 ≥ {{ e.profile.min_carton_gap_mm }}mm</span>
          <span>속도 {{ e.profile.min_speed_value }}–{{ e.profile.max_speed_value }} {{ e.profile.speed_unit }}</span>
          <span>기본 모드 {{ e.profile.speed_mode }}</span>
          <span>감지 윈도우 {{ e.profile.sensor_detection_window_ms }}ms</span>
          <span class="status" :class="statusClass(e.profile.status)">{{ e.profile.status }}</span>
          <span class="muted">profile v{{ e.profile.version }}</span>
        </div>
        <p v-else class="muted" data-testid="no-profile">
          분류 프로파일이 없습니다 — 등록하기 전에는 DIVERT/SET_SPEED 명령을 보낼 수 없습니다.
        </p>

        <div v-if="canManageProfile && profileForms[e.equipment_id]" class="row wrap">
          <label>
            Min Carton Gap (mm)
            <input
              v-model.number="profileForms[e.equipment_id].min_carton_gap_mm"
              type="number"
              :aria-label="`min carton gap for ${e.equipment_code}`"
            />
          </label>
          <label>
            Speed Mode
            <select
              v-model="profileForms[e.equipment_id].speed_mode"
              :aria-label="`profile speed mode for ${e.equipment_code}`"
            >
              <option value="FIXED">FIXED</option>
              <option value="AUTO">AUTO</option>
            </select>
          </label>
          <label>
            Min Speed
            <input
              v-model.number="profileForms[e.equipment_id].min_speed_value"
              type="number"
              step="0.1"
              :aria-label="`min speed for ${e.equipment_code}`"
            />
          </label>
          <label>
            Max Speed
            <input
              v-model.number="profileForms[e.equipment_id].max_speed_value"
              type="number"
              step="0.1"
              :aria-label="`max speed for ${e.equipment_code}`"
            />
          </label>
          <label>
            Unit
            <input
              v-model="profileForms[e.equipment_id].speed_unit"
              :aria-label="`speed unit for ${e.equipment_code}`"
            />
          </label>
          <label>
            Sensor Window (ms)
            <input
              v-model.number="profileForms[e.equipment_id].sensor_detection_window_ms"
              type="number"
              :aria-label="`sensor window for ${e.equipment_code}`"
            />
          </label>
          <label v-if="e.has_profile">
            Profile Status
            <select
              v-model="profileForms[e.equipment_id].status"
              :aria-label="`profile status for ${e.equipment_code}`"
            >
              <option value="ACTIVE">ACTIVE</option>
              <option value="INACTIVE">INACTIVE</option>
            </select>
          </label>
          <button
            v-if="!e.has_profile"
            class="primary"
            :disabled="submitting === e.equipment_id"
            @click="createProfile(e)"
          >
            Create Profile
          </button>
          <button v-else class="primary" :disabled="submitting === e.equipment_id" @click="saveProfile(e)">
            Save Profile
          </button>
        </div>
      </div>

      <!-- sorter commands -->
      <div v-if="canDispatch && e.has_profile" class="commands">
        <div class="row wrap">
          <label>
            Target Chute
            <input
              v-model="divertForms[e.equipment_id].target_chute"
              :aria-label="`target chute for ${e.equipment_code}`"
              placeholder="CHUTE-12"
            />
          </label>
          <label>
            Item Identifier
            <input
              v-model="divertForms[e.equipment_id].item_identifier"
              :aria-label="`item identifier for ${e.equipment_code}`"
              placeholder="BC-0001"
            />
          </label>
          <label>
            Expected Gap (mm, 선택)
            <input
              v-model="divertForms[e.equipment_id].expected_gap_mm"
              type="number"
              :aria-label="`expected gap for ${e.equipment_code}`"
            />
          </label>
          <button class="primary" :disabled="submitting === e.equipment_id" @click="dispatchDivert(e)">
            Dispatch DIVERT
          </button>
        </div>
        <div class="row wrap">
          <label>
            Speed Mode
            <select
              v-model="speedForms[e.equipment_id].speed_mode"
              :aria-label="`command speed mode for ${e.equipment_code}`"
            >
              <option value="FIXED">FIXED</option>
              <option value="AUTO">AUTO</option>
            </select>
          </label>
          <label v-if="speedForms[e.equipment_id].speed_mode === 'FIXED'">
            Speed Value ({{ e.profile.speed_unit }})
            <input
              v-model="speedForms[e.equipment_id].speed_value"
              type="number"
              step="0.1"
              :aria-label="`speed value for ${e.equipment_code}`"
            />
          </label>
          <span v-else class="muted auto-note">
            AUTO — 설비가 {{ e.profile.min_speed_value }}–{{ e.profile.max_speed_value }}
            {{ e.profile.speed_unit }} 범위 안에서 스스로 조절합니다.
          </span>
          <button class="primary" :disabled="submitting === e.equipment_id" @click="dispatchSetSpeed(e)">
            Dispatch SET_SPEED
          </button>
        </div>
        <p v-if="e.equipment_status === 'FAULT'" class="muted">
          설비가 FAULT 상태입니다 — WCS Monitor에서 장애를 해소해야 명령을 보낼 수 있습니다.
        </p>
      </div>

      <div v-if="e.active_sortation_commands.length > 0" class="muted commands-list" data-testid="active-commands">
        진행 중 분류 명령:
        <span v-for="c in e.active_sortation_commands" :key="c.command_id">
          {{ c.command_type }} ({{ c.status }})
        </span>
      </div>
    </div>
    <p v-if="!loading && rows.length === 0">등록된 SORTER/CONVEYOR 설비가 없습니다.</p>
  </div>
</template>

<style scoped>
.hint {
  color: var(--muted);
  margin-top: -0.5rem;
}
.role-note {
  background: #fef3c7;
  color: #92400e;
  padding: 0.5rem 0.75rem;
  border-radius: 6px;
}
.notice-banner {
  background: #eff6ff;
  color: #1e40af;
  padding: 0.6rem 1rem;
  border-radius: 6px;
  margin-bottom: 1rem;
}
.row {
  display: flex;
  gap: 0.5rem;
  align-items: flex-end;
  margin-bottom: 0.5rem;
}
.row.wrap {
  flex-wrap: wrap;
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
.summary {
  display: flex;
  gap: 0.75rem;
  flex-wrap: wrap;
  align-items: center;
  font-size: 0.85rem;
  margin-bottom: 0.5rem;
}
.profile {
  border-bottom: 1px solid var(--line);
  padding-bottom: 0.5rem;
  margin-bottom: 0.5rem;
}
.commands-list span {
  margin-right: 0.4rem;
}
.auto-note {
  max-width: 22rem;
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
</style>
