<script setup lang="ts">
import { ref, watch, onMounted, computed } from 'vue'
import { useAuthStore } from '@/stores/auth'
import { supabase } from '@/lib/supabase'

// Slotting optimization (openspec change add-slotting-optimization).
//
// Five panels, ordered the way the contract runs:
//
//   1. 보관 위치      — the flat registry. accessibility_rank is a NUMBER A
//                      PERSON TYPES IN; nothing derives it from a floor plan.
//   2. SKU 배정       — an operator's declaration of where a SKU sits. It is
//                      not derived from the ledger, because the ledger has no
//                      location axis at all.
//   3. 등급 정책      — per-warehouse "A-class belongs at rank <= N". No system
//                      default: a class with no policy is skipped, not guessed.
//   4. 속도 계산      — ABC over AVAILABLE-negative ledger rows. The panel puts
//                      skipped_no_data_count on screen next to the included
//                      count, because with this repository as it ships the
//                      honest answer is almost always "no signal at all".
//   5. 재배치 추천    — PENDING -> APPROVED/REJECTED -> APPLIED. The approve and
//                      reject buttons are manager-only, and that is the whole
//                      point of the contract: an agent may generate these rows
//                      but may not act on them.
//
// Reads go straight at the tables and the overview view. Both are RLS-guarded
// (the view is security_invoker), so a plain select shows exactly what the
// database is willing to hand over — the screen filters nothing itself.

const auth = useAuthStore()

const locations = ref<any[]>([])
const assignments = ref<any[]>([])
const policies = ref<any[]>([])
const products = ref<any[]>([])
const recommendations = ref<any[]>([])
const velocity = ref<any>(null)
const generation = ref<any>(null)

const loading = ref(false)
const error = ref('')
const notice = ref('')
const submitting = ref<string | null>(null)

// design.md 역할 모델. The registry and the policies are master data; the
// review gate is the human-only decision (D6); applying is allowed on the
// floor because recording that a move happened is the floor's knowledge.
const role = computed(() => auth.currentRole ?? '')
const canManageRegistry = computed(() => ['WMS_ADMIN', 'WAREHOUSE_MANAGER'].includes(role.value))
const canAssign = computed(() =>
  ['WMS_ADMIN', 'WAREHOUSE_MANAGER', 'INBOUND_OPERATOR'].includes(role.value),
)
const canAnalyze = computed(() =>
  ['WMS_ADMIN', 'WAREHOUSE_MANAGER', 'PROCESS_AGENT'].includes(role.value),
)
const canReview = computed(() => ['WMS_ADMIN', 'WAREHOUSE_MANAGER'].includes(role.value))
const canApply = computed(() =>
  ['WMS_ADMIN', 'WAREHOUSE_MANAGER', 'INBOUND_OPERATOR'].includes(role.value),
)

function isoDaysAgo(days: number) {
  const d = new Date()
  d.setDate(d.getDate() - days)
  return d.toISOString().slice(0, 10)
}

const locationForm = ref({ zone_code: 'PACK_ADJACENT', location_code: '', accessibility_rank: '1', capacity_qty: '' })
const assignForm = ref({ product_id: '', location_id: '' })
const policyForm = ref({ velocity_class: 'A', max_accessibility_rank: '5' })
const window_ = ref({ from: isoDaysAgo(7), to: isoDaysAgo(1) })
const rejectReasons = ref<Record<string, string>>({})

const activeLocations = computed(() => locations.value.filter((l) => l.status === 'ACTIVE'))
const locationById = computed(() =>
  Object.fromEntries(locations.value.map((l) => [l.id, l])) as Record<string, any>,
)
const productById = computed(() =>
  Object.fromEntries(products.value.map((p) => [p.id, p])) as Record<string, any>,
)
// SKUs that already hold an assignment cannot be declared again (the RPC says
// INVALID), so the dropdown only offers the ones that can.
const assignableProducts = computed(() => {
  const taken = new Set(assignments.value.map((a) => a.product_id))
  return products.value.filter((p) => !taken.has(p.id))
})
const velocityRows = computed(() => velocity.value?.snapshots ?? [])
const openRecommendations = computed(() =>
  recommendations.value.filter((r) => ['PENDING', 'APPROVED'].includes(r.status)),
)

async function load() {
  if (!auth.currentTenantId || !auth.currentWarehouseId) return
  loading.value = true
  error.value = ''
  try {
    const [locRes, asgRes, polRes, prodRes, recRes] = await Promise.all([
      supabase.from('storage_locations').select('*')
        .eq('warehouse_id', auth.currentWarehouseId)
        .order('accessibility_rank', { ascending: true }),
      supabase.from('sku_location_assignments').select('*')
        .eq('warehouse_id', auth.currentWarehouseId),
      supabase.from('slotting_class_policies').select('*')
        .eq('warehouse_id', auth.currentWarehouseId)
        .order('velocity_class', { ascending: true }),
      supabase.from('products').select('id, sku, name')
        .eq('tenant_id', auth.currentTenantId)
        .order('sku', { ascending: true }),
      // security_invoker view: same RLS as the base tables, no extra scope.
      supabase.from('slotting_recommendation_overview_v').select('*')
        .eq('warehouse_id', auth.currentWarehouseId)
        .order('created_at', { ascending: false }),
    ])
    for (const r of [locRes, asgRes, polRes, prodRes, recRes]) {
      if (r.error) throw r.error
    }
    locations.value = locRes.data ?? []
    assignments.value = asgRes.data ?? []
    policies.value = polRes.data ?? []
    products.value = prodRes.data ?? []
    recommendations.value = recRes.data ?? []
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

function registerLocation() {
  return run('register-location', async () => {
    const { error: rpcError } = await supabase.rpc('wms_register_storage_location', {
      p_tenant_id: auth.currentTenantId,
      p_warehouse_id: auth.currentWarehouseId,
      p_zone_code: locationForm.value.zone_code,
      p_location_code: locationForm.value.location_code,
      p_accessibility_rank: Number(locationForm.value.accessibility_rank),
      p_actor_id: auth.userId,
      p_idempotency_key: crypto.randomUUID(),
      p_capacity_qty: locationForm.value.capacity_qty === '' ? null : Number(locationForm.value.capacity_qty),
      p_correlation_id: null,
    })
    if (rpcError) throw rpcError
    notice.value = `위치 ${locationForm.value.location_code} 등록 완료 (ACTIVE)`
    locationForm.value.location_code = ''
    locationForm.value.capacity_qty = ''
  })
}

function toggleLocation(loc: any) {
  return run(`loc-${loc.id}`, async () => {
    const next = loc.status === 'ACTIVE' ? 'INACTIVE' : 'ACTIVE'
    const { data, error: rpcError } = await supabase.rpc('wms_set_storage_location_status', {
      p_location_id: loc.id,
      p_status: next,
      p_actor_id: auth.userId,
      p_idempotency_key: crypto.randomUUID(),
      p_expected_version: loc.version,
      p_correlation_id: null,
    })
    if (rpcError) throw rpcError
    const warn = (data?.warnings ?? []).find((w: string) => w.startsWith('STILL_ASSIGNED_SKUS'))
    notice.value = `${loc.location_code} → ${next}` +
      (warn ? ` — 이 위치에 배정된 SKU가 아직 있습니다(${warn.split(': ')[1]}건). 비활성화는 새 배정만 막습니다.` : '')
  })
}

function assignSku() {
  return run('assign', async () => {
    const { error: rpcError } = await supabase.rpc('wms_assign_sku_location', {
      p_tenant_id: auth.currentTenantId,
      p_warehouse_id: auth.currentWarehouseId,
      p_product_id: assignForm.value.product_id,
      p_location_id: assignForm.value.location_id,
      p_actor_id: auth.userId,
      p_idempotency_key: crypto.randomUUID(),
      p_correlation_id: null,
    })
    if (rpcError) throw rpcError
    notice.value = '배정을 선언했습니다 — 이 값은 원장에서 유도된 것이 아니라 사람의 진술입니다'
    assignForm.value.product_id = ''
  })
}

function reassignSku(a: any, locationId: string) {
  return run(`asg-${a.id}`, async () => {
    const { error: rpcError } = await supabase.rpc('wms_reassign_sku_location', {
      p_assignment_id: a.id,
      p_location_id: locationId,
      p_actor_id: auth.userId,
      p_idempotency_key: crypto.randomUUID(),
      p_expected_version: a.version,
      p_correlation_id: null,
    })
    if (rpcError) throw rpcError
    notice.value = `${productById.value[a.product_id]?.sku} 재배정 완료`
  })
}

function registerPolicy() {
  return run('register-policy', async () => {
    const { data, error: rpcError } = await supabase.rpc('wms_register_slotting_class_policy', {
      p_tenant_id: auth.currentTenantId,
      p_warehouse_id: auth.currentWarehouseId,
      p_velocity_class: policyForm.value.velocity_class,
      p_max_accessibility_rank: Number(policyForm.value.max_accessibility_rank),
      p_actor_id: auth.userId,
      p_idempotency_key: crypto.randomUUID(),
      p_correlation_id: null,
    })
    if (rpcError) throw rpcError
    notice.value = `${policyForm.value.velocity_class}등급 정책 등록 — 상한을 만족하는 ACTIVE 위치 ${data?.qualifying_location_count}곳`
  })
}

function computeVelocity() {
  return run('compute', async () => {
    velocity.value = null
    generation.value = null
    const { data, error: rpcError } = await supabase.rpc('wms_compute_sku_velocity', {
      p_tenant_id: auth.currentTenantId,
      p_warehouse_id: auth.currentWarehouseId,
      p_window_start: window_.value.from,
      p_window_end: window_.value.to,
      p_actor_id: auth.userId,
      p_idempotency_key: crypto.randomUUID(),
      p_correlation_id: null,
    })
    if (rpcError) throw rpcError
    velocity.value = data
    notice.value = data.included_product_count === 0
      ? '이 윈도우에는 소비 신호가 하나도 없습니다 — 등급을 매기지 않고 전부 제외했습니다'
      : `${data.included_product_count}개 SKU 분류 완료, ${data.skipped_no_data_count}개는 신호 없음으로 제외`
  })
}

function generateRecommendations() {
  return run('generate', async () => {
    const { data, error: rpcError } = await supabase.rpc('wms_generate_slotting_recommendations', {
      p_tenant_id: auth.currentTenantId,
      p_warehouse_id: auth.currentWarehouseId,
      p_velocity_batch_id: velocity.value?.batch_id,
      p_actor_id: auth.userId,
      p_idempotency_key: crypto.randomUUID(),
      p_correlation_id: null,
    })
    if (rpcError) throw rpcError
    generation.value = data
    notice.value = `추천 ${data.generated_count}건 생성 — 승인 전에는 어떤 배정도 바뀌지 않습니다`
  })
}

function reviewRecommendation(r: any, decision: 'APPROVE' | 'REJECT') {
  return run(`rec-${r.recommendation_id}`, async () => {
    const { error: rpcError } = await supabase.rpc('wms_review_slotting_recommendation', {
      p_recommendation_id: r.recommendation_id,
      p_decision: decision,
      p_actor_id: auth.userId,
      p_idempotency_key: crypto.randomUUID(),
      p_expected_version: r.version,
      p_review_reason: decision === 'REJECT' ? (rejectReasons.value[r.recommendation_id] || '화면에서 반려') : null,
      p_correlation_id: null,
    })
    if (rpcError) throw rpcError
    notice.value = decision === 'APPROVE'
      ? `${r.sku} 승인 — 아직 배정은 그대로입니다. Apply를 눌러야 반영됩니다.`
      : `${r.sku} 반려`
    delete rejectReasons.value[r.recommendation_id]
  })
}

function applyRecommendation(r: any) {
  return run(`rec-${r.recommendation_id}`, async () => {
    const { data, error: rpcError } = await supabase.rpc('wms_apply_slotting_recommendation', {
      p_recommendation_id: r.recommendation_id,
      p_actor_id: auth.userId,
      p_idempotency_key: crypto.randomUUID(),
      p_expected_version: r.version,
      p_correlation_id: null,
    })
    if (rpcError) throw rpcError
    notice.value = `${r.sku} → ${data?.location_code} 반영 완료` +
      (data?.assignment_created ? ' (신규 배정 생성)' : ' (기존 배정 갱신)') +
      ' — 기록만 바뀌었습니다. 실물 이동은 확인하지 않습니다.'
  })
}

onMounted(load)
watch(() => auth.currentWarehouseId, load)
</script>

<template>
  <div>
    <h1>Slotting</h1>
    <p class="hint">
      SKU 출하 빈도(ABC 등급)와 보관 위치의 접근성을 대조해 재배치를 추천합니다.
      추천은 사람이 승인해야만 배정에 반영됩니다 — 자동으로 적용되는 경로는 없습니다.
      현재 역할: {{ role }}
    </p>
    <div v-if="error" class="error-banner" data-testid="slotting-error">{{ error }}</div>
    <div v-if="notice" class="notice-banner" data-testid="slotting-notice">{{ notice }}</div>

    <!-- ---------------------------------------------------------- 1 -->
    <h2 class="board-title">보관 위치 레지스트리</h2>
    <p class="hint">
      접근성 순위(rank)는 <b>낮을수록 좋습니다</b>(1 = 포장/출하 바로 옆). 이 값은
      사람이 직접 매기는 판단값이며, 시스템이 창고 도면이나 실제 동선을 계산해
      산출하지 않습니다. 수용량은 참고 기록일 뿐 어떤 검증에도 쓰이지 않습니다.
    </p>
    <div v-if="canManageRegistry" class="card">
      <div class="row">
        <label>
          Zone Code
          <input v-model="locationForm.zone_code" aria-label="Zone Code" />
        </label>
        <label>
          Location Code
          <input v-model="locationForm.location_code" aria-label="Location Code" placeholder="A-01-01" />
        </label>
        <label>
          Accessibility Rank
          <input v-model="locationForm.accessibility_rank" type="number" min="1" aria-label="Accessibility Rank" />
        </label>
        <label>
          Capacity (참고)
          <input v-model="locationForm.capacity_qty" type="number" min="0" aria-label="Capacity Qty" />
        </label>
        <button class="primary" :disabled="submitting === 'register-location'" @click="registerLocation">
          Register Location
        </button>
      </div>
    </div>
    <p v-else class="hint">위치 등록·활성화 관리는 WAREHOUSE_MANAGER / WMS_ADMIN만 할 수 있습니다.</p>
    <table>
      <thead>
        <tr>
          <th>Location</th>
          <th>Zone</th>
          <th>Rank</th>
          <th>Capacity</th>
          <th>Status</th>
          <th>Assigned SKUs</th>
          <th>Version</th>
          <th v-if="canManageRegistry">Actions</th>
        </tr>
      </thead>
      <tbody>
        <tr v-for="l in locations" :key="l.id" :data-location-code="l.location_code">
          <td>{{ l.location_code }}</td>
          <td>{{ l.zone_code }}</td>
          <td data-location-rank>{{ l.accessibility_rank }}</td>
          <td>{{ l.capacity_qty ?? '—' }}</td>
          <td>
            <span class="status" :class="l.status === 'ACTIVE' ? 'ok' : 'danger'">{{ l.status }}</span>
          </td>
          <td>{{ assignments.filter((a) => a.location_id === l.id).length }}</td>
          <td>{{ l.version }}</td>
          <td v-if="canManageRegistry">
            <button
              class="primary"
              :class="{ danger: l.status === 'ACTIVE' }"
              :disabled="submitting === `loc-${l.id}`"
              :aria-label="`toggle ${l.location_code}`"
              @click="toggleLocation(l)"
            >
              {{ l.status === 'ACTIVE' ? 'Deactivate' : 'Activate' }}
            </button>
          </td>
        </tr>
      </tbody>
    </table>
    <p v-if="!loading && locations.length === 0">등록된 보관 위치가 없습니다.</p>

    <!-- ---------------------------------------------------------- 2 -->
    <h2 class="board-title">SKU 위치 배정</h2>
    <p class="hint">
      이 값은 재고 원장에서 유도된 것이 <b>아닙니다</b> — 원장에는 위치 축이 아예
      없어서, "이 SKU가 지금 어디 있는가"는 사람이 선언하는 수밖에 없습니다.
      선언과 실제 적치를 맞춰 보는 장치는 이 화면에 없습니다.
    </p>
    <div v-if="canAssign" class="card">
      <div class="row">
        <label>
          SKU
          <select v-model="assignForm.product_id" aria-label="Assign SKU">
            <option value="">선택</option>
            <option v-for="p in assignableProducts" :key="p.id" :value="p.id">{{ p.sku }}</option>
          </select>
        </label>
        <label>
          Location
          <select v-model="assignForm.location_id" aria-label="Assign Location">
            <option value="">선택</option>
            <option v-for="l in activeLocations" :key="l.id" :value="l.id">
              {{ l.location_code }} (rank {{ l.accessibility_rank }})
            </option>
          </select>
        </label>
        <button
          class="primary"
          :disabled="submitting === 'assign' || !assignForm.product_id || !assignForm.location_id"
          @click="assignSku"
        >
          Declare Assignment
        </button>
      </div>
    </div>
    <table>
      <thead>
        <tr>
          <th>SKU</th>
          <th>Location</th>
          <th>Rank</th>
          <th>Reason</th>
          <th>Version</th>
          <th v-if="canAssign">Reassign</th>
        </tr>
      </thead>
      <tbody>
        <tr
          v-for="a in assignments"
          :key="a.id"
          :data-assignment-sku="productById[a.product_id]?.sku"
          :data-assignment-location="locationById[a.location_id]?.location_code"
        >
          <td>{{ productById[a.product_id]?.sku ?? a.product_id.slice(0, 8) }}</td>
          <td>{{ locationById[a.location_id]?.location_code }}</td>
          <td data-assignment-rank>{{ locationById[a.location_id]?.accessibility_rank }}</td>
          <td>
            <span class="status" :class="a.assigned_reason === 'SLOTTING_RECOMMENDATION' ? 'ok' : ''">
              {{ a.assigned_reason }}
            </span>
          </td>
          <td>{{ a.version }}</td>
          <td v-if="canAssign">
            <select
              :aria-label="`reassign ${productById[a.product_id]?.sku}`"
              :disabled="submitting === `asg-${a.id}`"
              @change="reassignSku(a, ($event.target as HTMLSelectElement).value)"
            >
              <option value="">이동…</option>
              <option
                v-for="l in activeLocations.filter((x) => x.id !== a.location_id)"
                :key="l.id"
                :value="l.id"
              >
                {{ l.location_code }}
              </option>
            </select>
          </td>
        </tr>
      </tbody>
    </table>
    <p v-if="!loading && assignments.length === 0">선언된 배정이 없습니다.</p>

    <!-- ---------------------------------------------------------- 3 -->
    <h2 class="board-title">등급별 목표 접근성 정책</h2>
    <p class="hint">
      "A등급 SKU는 순위 N 이하에 있어야 한다"를 창고별로 정합니다. 시스템 기본값은
      없습니다 — 위치가 5개인 창고와 500개인 창고에서 같은 숫자가 전혀 다른 뜻이기
      때문입니다. <b>정책이 없는 등급은 추천 생성에서 빠지고, 그 사실이 결과에
      그대로 표시됩니다.</b>
    </p>
    <div v-if="canManageRegistry" class="card">
      <div class="row">
        <label>
          Velocity Class
          <select v-model="policyForm.velocity_class" aria-label="Velocity Class">
            <option value="A">A</option>
            <option value="B">B</option>
            <option value="C">C</option>
          </select>
        </label>
        <label>
          Max Accessibility Rank
          <input v-model="policyForm.max_accessibility_rank" type="number" min="1" aria-label="Max Accessibility Rank" />
        </label>
        <button class="primary" :disabled="submitting === 'register-policy'" @click="registerPolicy">
          Register Policy
        </button>
      </div>
    </div>
    <table>
      <thead>
        <tr>
          <th>Class</th>
          <th>Max Rank</th>
          <th>Qualifying ACTIVE locations</th>
          <th>Version</th>
        </tr>
      </thead>
      <tbody>
        <tr v-for="p in policies" :key="p.id" :data-policy-class="p.velocity_class">
          <td>{{ p.velocity_class }}</td>
          <td data-policy-max-rank>{{ p.max_accessibility_rank }}</td>
          <td>{{ activeLocations.filter((l) => l.accessibility_rank <= p.max_accessibility_rank).length }}</td>
          <td>{{ p.version }}</td>
        </tr>
      </tbody>
    </table>
    <p v-if="!loading && policies.length === 0" data-testid="no-policies">등록된 등급 정책이 없습니다.</p>

    <!-- ---------------------------------------------------------- 4 -->
    <h2 class="board-title">출하 속도 계산 (ABC)</h2>
    <p class="hint">
      재고 원장에서 <code>AVAILABLE</code> 상태의 <b>음수</b> 수량 변동만 소비
      신호로 봅니다. 입고·검사·폐기 이력은 섞지 않습니다. 누적 소비 비중 80%까지
      A, 95%까지 B, 나머지 C입니다(경계값 포함).
    </p>
    <div v-if="canAnalyze" class="card">
      <div class="row">
        <label>
          관찰 시작일
          <input v-model="window_.from" type="date" aria-label="Window From" />
        </label>
        <label>
          관찰 종료일
          <input v-model="window_.to" type="date" aria-label="Window To" />
        </label>
        <button class="primary" :disabled="submitting === 'compute'" @click="computeVelocity">
          Compute Velocity
        </button>
      </div>
    </div>
    <p v-else class="hint">속도 계산은 WAREHOUSE_MANAGER / WMS_ADMIN / PROCESS_AGENT만 실행할 수 있습니다.</p>

    <div v-if="velocity" class="card totals" data-testid="velocity-summary">
      <span>
        상태
        <b class="status" :class="velocity.status === 'COMPUTED' ? 'ok' : 'warn'" data-testid="velocity-status">
          {{ velocity.status }}
        </b>
      </span>
      <span>대상 SKU <b data-testid="velocity-candidates">{{ velocity.candidate_product_count }}</b></span>
      <span>분류됨 <b data-testid="velocity-included">{{ velocity.included_product_count }}</b></span>
      <span>
        신호 없어 제외
        <b data-testid="velocity-skipped">{{ velocity.skipped_no_data_count }}</b>
      </span>
      <span>합계 소비량 <b>{{ velocity.total_outbound_qty }}</b></span>
    </div>
    <p v-if="velocity && velocity.included_product_count === 0" class="honesty" data-testid="velocity-no-signal">
      이 윈도우에 소비 신호가 있는 SKU가 하나도 없습니다. 제외된
      {{ velocity.skipped_no_data_count }}개 SKU에는 <b>등급을 매기지 않았습니다</b> —
      "전부 저빈도(C)"라고 넘겨짚지 않기 위해서입니다. 이 저장소에는 아직
      <code>AVAILABLE</code> 재고를 차감하는 출고 처리가 구현되어 있지 않으므로,
      실데이터에서는 이것이 정상 결과입니다.
    </p>
    <table v-if="velocity && velocityRows.length > 0">
      <thead>
        <tr>
          <th>SKU</th>
          <th>Class</th>
          <th>Outbound Qty</th>
          <th>Events</th>
        </tr>
      </thead>
      <tbody>
        <tr v-for="s in velocityRows" :key="s.product_id" :data-velocity-sku="s.sku">
          <td>{{ s.sku }}</td>
          <td>
            <span class="status" :class="s.velocity_class === 'A' ? 'ok' : s.velocity_class === 'B' ? 'warn' : ''"
                  data-velocity-class>{{ s.velocity_class }}</span>
          </td>
          <td>{{ s.outbound_qty }}</td>
          <td>{{ s.outbound_event_count }}</td>
        </tr>
      </tbody>
    </table>

    <div v-if="velocity" class="card">
      <div class="row">
        <button
          class="primary"
          :disabled="submitting === 'generate' || !canAnalyze || velocity.included_product_count === 0"
          @click="generateRecommendations"
        >
          Generate Recommendations
        </button>
        <span class="hint inline">
          같은 배치로 정책을 바꿔 가며 몇 번이든 다시 생성할 수 있습니다 (원장을 다시 훑지 않습니다).
        </span>
      </div>
      <div v-if="generation" class="card totals nested" data-testid="generation-summary">
        <span>생성 <b data-testid="generated-count">{{ generation.generated_count }}</b>건</span>
        <span>
          정책 없어 제외된 등급
          <b data-testid="skipped-no-policy">{{ generation.skipped_no_policy_classes.join(', ') || '없음' }}</b>
        </span>
        <span>이미 적정 위치 <b data-testid="skipped-optimal">{{ generation.skipped_already_optimal_count }}</b></span>
        <span>검토 대기 중이라 제외 <b>{{ generation.skipped_open_recommendation_count }}</b></span>
        <span>대상 위치 없음 <b>{{ generation.skipped_no_target_location_count }}</b></span>
      </div>
    </div>

    <!-- ---------------------------------------------------------- 5 -->
    <h2 class="board-title">
      재배치 추천
      <span class="status" :class="canReview ? 'ok' : 'warn'" data-testid="review-scope">
        {{ canReview ? '승인 권한 있음' : '조회 전용' }}
      </span>
    </h2>
    <p class="hint">
      추천을 만드는 것은 분석이지만, 승인은 지게차를 움직이게 만드는 운영 판단입니다.
      그래서 <b>승인·반려는 WAREHOUSE_MANAGER / WMS_ADMIN만</b> 할 수 있습니다.
      승인해도 배정은 아직 그대로이고, Apply를 눌러야 반영됩니다.
    </p>
    <table>
      <thead>
        <tr>
          <th>SKU</th>
          <th>Class</th>
          <th>Reason</th>
          <th>현재 위치</th>
          <th>추천 위치</th>
          <th>Gain</th>
          <th>Status</th>
          <th>Actions</th>
        </tr>
      </thead>
      <tbody>
        <tr
          v-for="r in recommendations"
          :key="r.recommendation_id"
          :data-recommendation-sku="r.sku"
          :data-recommendation-status="r.status"
        >
          <td>{{ r.sku }}</td>
          <td>{{ r.velocity_class }}</td>
          <td class="mono">{{ r.reason_code }}</td>
          <td data-current-location>
            {{ r.current_location_code ?? '—' }}
            <span v-if="r.current_accessibility_rank" class="rank">rank {{ r.current_accessibility_rank }}</span>
          </td>
          <td data-recommended-location>
            {{ r.recommended_location_code }}
            <span class="rank">rank {{ r.recommended_accessibility_rank }}</span>
          </td>
          <td>{{ r.accessibility_gain ?? '—' }}</td>
          <td>
            <span
              class="status"
              :class="r.status === 'APPLIED' ? 'ok' : r.status === 'REJECTED' ? 'danger' : 'warn'"
            >{{ r.status }}</span>
          </td>
          <td>
            <div v-if="r.status === 'PENDING'" class="row actions">
              <template v-if="canReview">
                <input
                  v-model="rejectReasons[r.recommendation_id]"
                  class="reason"
                  :aria-label="`reject reason for ${r.sku}`"
                  placeholder="반려 사유"
                />
                <button
                  class="primary"
                  :disabled="submitting === `rec-${r.recommendation_id}`"
                  :aria-label="`approve ${r.sku}`"
                  @click="reviewRecommendation(r, 'APPROVE')"
                >
                  Approve
                </button>
                <button
                  class="primary danger"
                  :disabled="submitting === `rec-${r.recommendation_id}`"
                  :aria-label="`reject ${r.sku}`"
                  @click="reviewRecommendation(r, 'REJECT')"
                >
                  Reject
                </button>
              </template>
              <span v-else class="hint" data-review-denied>승인은 창고관리자만 할 수 있습니다</span>
            </div>
            <div v-else-if="r.status === 'APPROVED'" class="row actions">
              <button
                v-if="canApply"
                class="primary"
                :disabled="submitting === `rec-${r.recommendation_id}`"
                :aria-label="`apply ${r.sku}`"
                @click="applyRecommendation(r)"
              >
                Apply
              </button>
              <span v-else class="hint">적용 권한이 없습니다</span>
            </div>
            <span v-else class="hint">—</span>
          </td>
        </tr>
      </tbody>
    </table>
    <p v-if="!loading && recommendations.length === 0" data-testid="no-recommendations">
      재배치 추천이 없습니다.
    </p>
    <p v-if="openRecommendations.length > 0" class="hint">
      검토 대기/승인 대기 {{ openRecommendations.length }}건. 같은 SKU에 열린 추천이 있는 동안에는
      재생성해도 중복이 쌓이지 않습니다.
    </p>
  </div>
</template>

<style scoped>
.hint {
  color: var(--muted);
  margin-top: -0.5rem;
}
.hint.inline {
  margin: 0;
  font-size: 0.8rem;
  max-width: 34rem;
}
h2 {
  font-size: 1rem;
  margin: 0 0 0.25rem;
}
.board-title {
  margin: 1.75rem 0 0.5rem;
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
.row.actions {
  margin-top: 0;
  gap: 0.35rem;
  align-items: center;
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
  width: 9rem;
}
.mono {
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  font-size: 0.8em;
}
.rank {
  color: var(--muted);
  font-size: 0.75rem;
  margin-left: 0.25rem;
}
.totals {
  display: flex;
  gap: 1.5rem;
  flex-wrap: wrap;
  font-size: 0.9rem;
  align-items: center;
}
.totals.nested {
  margin: 0.75rem 0 0;
  background: #f8fafc;
}
.notice-banner {
  background: #dcfce7;
  color: #166534;
  padding: 0.6rem 1rem;
  border-radius: 6px;
  margin-bottom: 1rem;
}
.honesty {
  background: #fef3c7;
  color: #92400e;
  padding: 0.7rem 1rem;
  border-radius: 6px;
  font-size: 0.88rem;
  line-height: 1.5;
}
code {
  background: #f1f5f9;
  padding: 0.05rem 0.3rem;
  border-radius: 4px;
  font-size: 0.85em;
}
</style>
