<script setup lang="ts">
import { ref, watch, onMounted, computed } from 'vue'
import { useAuthStore } from '@/stores/auth'
import { supabase } from '@/lib/supabase'

// Routing / bottleneck board (openspec change add-wcs-bottleneck-routing).
//
// One read RPC (wms_get_equipment_routing_status) feeds the whole screen: every
// machine in the warehouse with its live queue depth, recent fault count, the
// thresholds actually applied to it, the bottleneck verdict and its reasons,
// plus any operator force-exclusion — and, separately, the warehouse's
// threshold policies.
//
// Nothing here is stored state: the verdict is recomputed on every read, so a
// threshold change or a cleared exclusion takes effect on the very next
// Refresh and on the very next dispatch. There is no recalculation batch.
//
// Two role sets are in play and they are deliberately different:
//   - thresholds  : WMS_ADMIN / WAREHOUSE_MANAGER          (operations tuning)
//   - exclusions  : ...plus WCS_OPERATOR                   (shop-floor call)
// A WCS_OPERATOR therefore sees the exclusion buttons but not the threshold
// editor, and the screen says so rather than silently hiding it.

const auth = useAuthStore()
const rows = ref<any[]>([])
const policies = ref<any[]>([])
const meta = ref<any>({})
const loading = ref(false)
const error = ref('')
const notice = ref('')
const submitting = ref<string | null>(null)
const reasonByEquipment = ref<Record<string, string>>({})

const EQUIPMENT_TYPES = ['SRM', 'CONVEYOR', 'SORTER', 'AGV', 'AMR', 'ROBOT_CELL']

type PolicyForm = { queue_depth_threshold: number; fault_count_threshold: number }
const policyForms = ref<Record<string, PolicyForm>>({})
const newPolicyType = ref('AGV')

const canManagePolicy = computed(() =>
  ['WMS_ADMIN', 'WAREHOUSE_MANAGER'].includes(auth.currentRole ?? ''),
)
const canExclude = computed(() =>
  ['WMS_ADMIN', 'WAREHOUSE_MANAGER', 'WCS_OPERATOR'].includes(auth.currentRole ?? ''),
)

const bottleneckCount = computed(() => rows.value.filter((r) => r.is_bottleneck).length)
const excludedCount = computed(() => rows.value.filter((r) => r.is_excluded).length)
const policiedTypes = computed(() => policies.value.map((p) => p.equipment_type))
const availableTypes = computed(() => EQUIPMENT_TYPES.filter((t) => !policiedTypes.value.includes(t)))

function statusClass(status: string) {
  if (status === 'FAULT') return 'danger'
  if (status === 'RUNNING' || status === 'IDLE') return 'ok'
  return 'warn'
}

function reasonLabel(reason: string) {
  return reason === 'QUEUE_DEPTH_EXCEEDED' ? '큐 적체' : '장애 잦음'
}

async function load() {
  if (!auth.currentTenantId || !auth.currentWarehouseId) return
  loading.value = true
  error.value = ''
  try {
    const { data, error: rpcError } = await supabase.rpc('wms_get_equipment_routing_status', {
      p_tenant_id: auth.currentTenantId,
      p_warehouse_id: auth.currentWarehouseId,
      p_equipment_id: null,
    })
    if (rpcError) throw rpcError
    rows.value = data?.items ?? []
    policies.value = data?.policies ?? []
    meta.value = data ?? {}
    for (const p of policies.value) {
      policyForms.value[p.policy_id] = {
        queue_depth_threshold: p.queue_depth_threshold,
        fault_count_threshold: p.fault_count_threshold,
      }
    }
    if (!availableTypes.value.includes(newPolicyType.value)) {
      newPolicyType.value = availableTypes.value[0] ?? ''
    }
  } catch (e: any) {
    error.value = e.message ?? String(e)
  } finally {
    loading.value = false
  }
}

const newPolicy = ref<PolicyForm>({ queue_depth_threshold: 3, fault_count_threshold: 1 })

async function registerPolicy() {
  submitting.value = 'new-policy'
  error.value = ''
  notice.value = ''
  try {
    const { data, error: rpcError } = await supabase.rpc('wms_register_wcs_routing_policy', {
      p_tenant_id: auth.currentTenantId,
      p_warehouse_id: auth.currentWarehouseId,
      p_equipment_type: newPolicyType.value,
      p_queue_depth_threshold: Number(newPolicy.value.queue_depth_threshold),
      p_fault_count_threshold: Number(newPolicy.value.fault_count_threshold),
      p_actor_id: auth.userId,
      p_idempotency_key: crypto.randomUUID(),
      p_correlation_id: null,
    })
    if (rpcError) throw rpcError
    notice.value = `${newPolicyType.value} 임계값 정책 등록 완료 (version ${data.version}) — 다음 조회부터 즉시 적용됩니다.`
    await load()
  } catch (e: any) {
    error.value = e.message ?? String(e)
  } finally {
    submitting.value = null
  }
}

async function savePolicy(policy: any) {
  submitting.value = policy.policy_id
  error.value = ''
  notice.value = ''
  try {
    const f = policyForms.value[policy.policy_id]
    const { data, error: rpcError } = await supabase.rpc('wms_update_wcs_routing_policy', {
      p_policy_id: policy.policy_id,
      p_actor_id: auth.userId,
      p_idempotency_key: crypto.randomUUID(),
      p_expected_version: policy.version,
      p_queue_depth_threshold: Number(f.queue_depth_threshold),
      p_fault_count_threshold: Number(f.fault_count_threshold),
      p_correlation_id: null,
    })
    if (rpcError) throw rpcError
    notice.value = `${policy.equipment_type} 임계값 저장 완료 (version ${data.version})`
    await load()
  } catch (e: any) {
    error.value = e.message ?? String(e)
  } finally {
    submitting.value = null
  }
}

async function excludeEquipment(row: any) {
  submitting.value = row.equipment_id
  error.value = ''
  notice.value = ''
  try {
    const reason = (reasonByEquipment.value[row.equipment_id] ?? '').trim()
    if (!reason) throw new Error('제외 사유(reason)가 필요합니다')
    const { data, error: rpcError } = await supabase.rpc('wms_exclude_equipment_from_routing', {
      p_equipment_id: row.equipment_id,
      p_reason: reason,
      p_actor_id: auth.userId,
      p_idempotency_key: crypto.randomUUID(),
      p_correlation_id: null,
    })
    if (rpcError) throw rpcError
    reasonByEquipment.value[row.equipment_id] = ''
    notice.value = (data.warnings ?? []).length
      ? `${row.equipment_code} 라우팅 제외됨 — ${data.warnings.join(', ')} (진행 중 명령은 취소되지 않습니다)`
      : `${row.equipment_code} 라우팅 제외됨 — 신규 작업은 더 이상 배정되지 않습니다.`
    await load()
  } catch (e: any) {
    error.value = e.message ?? String(e)
  } finally {
    submitting.value = null
  }
}

async function clearExclusion(row: any) {
  submitting.value = row.equipment_id
  error.value = ''
  notice.value = ''
  try {
    const { data, error: rpcError } = await supabase.rpc('wms_clear_equipment_routing_exclusion', {
      p_override_id: row.active_override.override_id,
      p_actor_id: auth.userId,
      p_idempotency_key: crypto.randomUUID(),
      p_expected_version: row.active_override.version,
      p_correlation_id: null,
    })
    if (rpcError) throw rpcError
    notice.value = `${row.equipment_code} 제외 해제됨 (version ${data.version}) — 즉시 자동 라우팅 대상으로 복귀합니다.`
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
    <h1>WCS Routing</h1>
    <p class="hint">
      설비별 부하·병목 현황을 보고, 계획 정비 등의 이유로 특정 설비를 자동 라우팅에서
      제외합니다. 판정은 저장된 상태가 아니라 조회 시점 계산값입니다
      (관찰 윈도우 {{ meta.observation_window ?? '30 minutes' }}). 현재 역할: {{ auth.currentRole }}
    </p>

    <div class="row">
      <button class="primary" @click="load">Refresh</button>
      <span class="summary-badges" data-testid="routing-summary">
        <span class="status" :class="bottleneckCount ? 'warn' : 'ok'">병목 {{ bottleneckCount }}대</span>
        <span class="status" :class="excludedCount ? 'danger' : 'ok'">강제 제외 {{ excludedCount }}대</span>
      </span>
    </div>

    <div v-if="error" class="error-banner">{{ error }}</div>
    <div v-if="notice" class="notice-banner" data-testid="routing-notice">{{ notice }}</div>
    <p v-if="canExclude && !canManagePolicy" class="hint role-note" data-testid="role-note">
      이 역할은 설비를 라우팅에서 제외할 수 있지만 임계값 정책은 바꿀 수 없습니다
      (임계값 튜닝은 WMS_ADMIN / WAREHOUSE_MANAGER).
    </p>

    <!-- ---------------------------------------------------------- -->
    <!-- Threshold policies                                          -->
    <!-- ---------------------------------------------------------- -->
    <div class="card">
      <h2>병목 판정 임계값</h2>
      <p class="muted">
        정책이 없는 설비 유형에는 시스템 기본값(큐 {{ meta.default_queue_depth_threshold ?? 3 }} /
        장애 {{ meta.default_fault_count_threshold ?? 1 }})이 적용됩니다 — 등록은 선택 사항입니다.
      </p>
      <table>
        <thead>
          <tr>
            <th>설비 유형</th>
            <th>큐 길이 임계값</th>
            <th>최근 장애 임계값</th>
            <th>버전</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="p in policies" :key="p.policy_id" :data-policy-type="p.equipment_type">
            <td><strong>{{ p.equipment_type }}</strong></td>
            <td>
              <input
                v-if="canManagePolicy && policyForms[p.policy_id]"
                v-model.number="policyForms[p.policy_id].queue_depth_threshold"
                type="number"
                :aria-label="`queue threshold for ${p.equipment_type}`"
              />
              <span v-else>{{ p.queue_depth_threshold }}</span>
            </td>
            <td>
              <input
                v-if="canManagePolicy && policyForms[p.policy_id]"
                v-model.number="policyForms[p.policy_id].fault_count_threshold"
                type="number"
                :aria-label="`fault threshold for ${p.equipment_type}`"
              />
              <span v-else>{{ p.fault_count_threshold }}</span>
            </td>
            <td class="muted">v{{ p.version }}</td>
            <td>
              <button
                v-if="canManagePolicy"
                class="primary"
                :disabled="submitting === p.policy_id"
                @click="savePolicy(p)"
              >
                Save Policy
              </button>
            </td>
          </tr>
          <tr v-if="policies.length === 0">
            <td colspan="5" class="muted" data-testid="no-policies">
              등록된 임계값 정책이 없습니다 — 모든 설비 유형에 시스템 기본값이 적용됩니다.
            </td>
          </tr>
        </tbody>
      </table>

      <div v-if="canManagePolicy && availableTypes.length > 0" class="row wrap new-policy">
        <label>
          설비 유형
          <select v-model="newPolicyType" aria-label="new policy equipment type">
            <option v-for="t in availableTypes" :key="t" :value="t">{{ t }}</option>
          </select>
        </label>
        <label>
          큐 길이 임계값
          <input v-model.number="newPolicy.queue_depth_threshold" type="number" aria-label="new queue threshold" />
        </label>
        <label>
          최근 장애 임계값
          <input v-model.number="newPolicy.fault_count_threshold" type="number" aria-label="new fault threshold" />
        </label>
        <button class="primary" :disabled="submitting === 'new-policy'" @click="registerPolicy">
          Register Policy
        </button>
      </div>
    </div>

    <!-- ---------------------------------------------------------- -->
    <!-- Per-equipment routing board                                 -->
    <!-- ---------------------------------------------------------- -->
    <div v-for="e in rows" :key="e.equipment_id" class="card" :data-equipment-code="e.equipment_code">
      <div class="head">
        <strong>{{ e.equipment_code }}</strong>
        <span class="muted">{{ e.equipment_type }} · {{ e.zone_code }}</span>
        <span class="status" :class="statusClass(e.equipment_status)">{{ e.equipment_status }}</span>
        <span
          v-if="e.is_bottleneck"
          class="status warn"
          data-testid="bottleneck-badge"
        >병목</span>
        <span
          v-if="e.is_excluded"
          class="status danger"
          data-testid="excluded-badge"
        >라우팅 제외</span>
        <span
          class="status"
          :class="e.routable ? 'ok' : 'warn'"
          data-testid="routable-badge"
        >{{ e.routable ? '배정 가능' : '배정 불가' }}</span>
      </div>

      <div class="signals" data-testid="signals">
        <span>
          큐 <strong>{{ e.queue_depth }}</strong> / {{ e.resolved_queue_depth_threshold }}
        </span>
        <span>
          최근 장애 <strong>{{ e.recent_fault_count }}</strong> / {{ e.resolved_fault_count_threshold }}
        </span>
        <span>최근 완료 {{ e.recent_completed_count }}</span>
        <span class="muted">
          임계값 출처: {{ e.threshold_source === 'POLICY' ? '정책' : '시스템 기본값' }}
        </span>
      </div>

      <p v-if="e.is_bottleneck" class="muted reasons" data-testid="bottleneck-reasons">
        병목 사유:
        <span v-for="r in e.bottleneck_reasons" :key="r" class="reason-chip">
          {{ reasonLabel(r) }} ({{ r }})
        </span>
        — 병목은 금지가 아니라 후순위입니다. 다른 후보가 없으면 이 설비가 선택됩니다.
      </p>

      <div v-if="e.is_excluded" class="exclusion" data-testid="exclusion-box">
        <span class="status danger">제외 중</span>
        <strong>{{ e.active_override.reason }}</strong>
        <span class="muted">override v{{ e.active_override.version }}</span>
        <button
          v-if="canExclude"
          class="primary"
          :disabled="submitting === e.equipment_id"
          @click="clearExclusion(e)"
        >
          Clear Exclusion
        </button>
        <span v-else class="muted">해제 권한이 없습니다 (WCS_OPERATOR 필요)</span>
      </div>
      <div v-else-if="canExclude" class="row exclude-form">
        <input
          v-model="reasonByEquipment[e.equipment_id]"
          :aria-label="`exclusion reason for ${e.equipment_code}`"
          placeholder="제외 사유 (필수, 예: 계획 정비)"
        />
        <button class="primary danger" :disabled="submitting === e.equipment_id" @click="excludeEquipment(e)">
          Exclude from Routing
        </button>
      </div>
    </div>

    <p v-if="!loading && rows.length === 0">등록된 설비가 없습니다.</p>
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
h2 {
  font-size: 1rem;
  margin: 0 0 0.25rem;
}
.row {
  display: flex;
  gap: 0.5rem;
  align-items: flex-end;
  margin-bottom: 0.75rem;
}
.row.wrap {
  flex-wrap: wrap;
}
.summary-badges {
  display: flex;
  gap: 0.4rem;
  align-items: center;
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
.signals {
  display: flex;
  gap: 1rem;
  flex-wrap: wrap;
  align-items: center;
  font-size: 0.85rem;
  margin-bottom: 0.4rem;
}
.reasons {
  margin: 0 0 0.5rem;
}
.reason-chip {
  background: #fef3c7;
  color: #92400e;
  border-radius: 999px;
  padding: 0.1rem 0.5rem;
  margin-right: 0.3rem;
  font-weight: 600;
}
.exclusion {
  display: flex;
  gap: 0.5rem;
  align-items: center;
  background: #fef2f2;
  border: 1px solid #fecaca;
  border-radius: 6px;
  padding: 0.5rem 0.75rem;
}
.exclude-form {
  margin-bottom: 0;
}
.new-policy {
  margin-top: 0.75rem;
  margin-bottom: 0;
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
.exclude-form input {
  flex: 1;
  max-width: 24rem;
}
</style>
