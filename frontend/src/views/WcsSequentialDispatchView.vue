<script setup lang="ts">
import { ref, watch, onMounted, computed } from 'vue'
import { useAuthStore } from '@/stores/auth'
import { supabase } from '@/lib/supabase'

// Sequential dispatch / intelligent palletising
// (openspec change add-wcs-sequential-dispatch).
//
// The outbound side of the demo: register a minimal outbound unit, give it a
// position and a target pallet inside a dispatch wave, then send one PALLETIZE
// command that carries every unit sharing that pallet to a robot cell, and read
// back what actually ended up on it.
//
// Reads go through wms_get_dispatch_sequence_status (already joined with the
// outbound unit, the wave and the equipment command) plus
// wms_get_pallet_manifest for the loaded-item detail. Writes go through the
// SECURITY DEFINER RPCs, like every other view in this app.
//
// Two different role sets are in play, and the difference is deliberate:
// creating/sequencing/cancelling accepts WMS_ADMIN, dispatching does not —
// wms_dispatch_palletize_command calls wms_dispatch_equipment_command, whose
// shipped role set excludes WMS_ADMIN (migration DEVIATION 2).

const auth = useAuthStore()
const orders = ref<any[]>([])
const sequences = ref<any[]>([])
const waves = ref<any[]>([])
const cells = ref<any[]>([])
const pallets = ref<any[]>([])
const manifests = ref<any[]>([])
const products = ref<any[]>([])
const loading = ref(false)
const error = ref('')
const notice = ref('')
const submitting = ref<string | null>(null)

const orderForm = ref({
  order_number: '',
  store_code: '',
  product_id: '',
  qty: 1,
  declared_weight_kg: '',
  declared_volume_l: '',
})

const sequenceForm = ref({
  outbound_order_id: '',
  wave_id: '',
  sequence_position: 1,
  target_pallet_code: 'PLT-0001',
})

const palletizeForm = ref({
  equipment_id: '',
  wave_id: '',
  target_pallet_code: 'PLT-0001',
  max_weight_kg: '',
  max_volume_l: '',
})

const wrapForm = ref({
  equipment_id: '',
  pallet_code: 'PLT-0001',
  wrap_program: 'STANDARD',
})

// creating a unit / sequencing / cancelling — WMS_ADMIN included
const canPlan = computed(() =>
  ['WMS_ADMIN', 'WAREHOUSE_MANAGER', 'WCS_OPERATOR', 'PROCESS_AGENT'].includes(auth.currentRole ?? ''),
)
// creating the outbound unit itself is an upstream decision — no WCS_OPERATOR
const canCreateOrder = computed(() =>
  ['WMS_ADMIN', 'WAREHOUSE_MANAGER', 'PROCESS_AGENT'].includes(auth.currentRole ?? ''),
)
// mirrors the shipped wms_dispatch_equipment_command role set — WMS_ADMIN is
// deliberately not in it (see the migration header, DEVIATION 2).
const canDispatch = computed(() =>
  ['WAREHOUSE_MANAGER', 'WCS_OPERATOR', 'PROCESS_AGENT'].includes(auth.currentRole ?? ''),
)

const openWaves = computed(() => waves.value.filter((w) => w.status === 'OPEN'))
const openOrders = computed(() => orders.value.filter((o) => o.status === 'OPEN'))

function statusClass(status: string) {
  if (status === 'FAILED') return 'danger'
  if (status === 'COMPLETED' || status === 'DISPATCHED' || status === 'RELEASED' || status === 'IDLE')
    return 'ok'
  if (status === 'CANCELLED') return 'muted-badge'
  return 'warn'
}

function shortId(id: string | null) {
  return id ? id.slice(0, 8) : '—'
}

function num(v: any) {
  return v === null || v === undefined ? '—' : Number(v)
}

async function load() {
  if (!auth.currentTenantId || !auth.currentWarehouseId) return
  loading.value = true
  error.value = ''
  try {
    const { data, error: rpcError } = await supabase.rpc('wms_get_dispatch_sequence_status', {
      p_tenant_id: auth.currentTenantId,
      p_warehouse_id: auth.currentWarehouseId,
      p_wave_id: null,
      p_outbound_order_id: null,
    })
    if (rpcError) throw rpcError
    orders.value = data?.outbound_orders ?? []
    sequences.value = data?.sequences ?? []
    waves.value = data?.waves ?? []
    cells.value = data?.robot_cells ?? []
    pallets.value = data?.pallets ?? []

    const { data: manifestData, error: manifestError } = await supabase.rpc('wms_get_pallet_manifest', {
      p_tenant_id: auth.currentTenantId,
      p_warehouse_id: auth.currentWarehouseId,
      p_equipment_command_id: null,
      p_target_pallet_code: null,
    })
    if (manifestError) throw manifestError
    manifests.value = manifestData?.pallets ?? []

    const { data: productRows, error: productError } = await supabase
      .from('products')
      .select('id, sku, name')
      .eq('tenant_id', auth.currentTenantId)
      .order('sku')
    if (productError) throw productError
    products.value = productRows ?? []

    if (!orderForm.value.product_id && products.value.length > 0) {
      orderForm.value.product_id = products.value[0].id
    }
    if (!sequenceForm.value.wave_id && openWaves.value.length > 0) {
      sequenceForm.value.wave_id = openWaves.value[0].wave_id
      palletizeForm.value.wave_id = openWaves.value[0].wave_id
    }
    if (!sequenceForm.value.outbound_order_id && openOrders.value.length > 0) {
      sequenceForm.value.outbound_order_id = openOrders.value[0].outbound_order_id
    }
    if (!palletizeForm.value.equipment_id && cells.value.length > 0) {
      palletizeForm.value.equipment_id = cells.value[0].equipment_id
      wrapForm.value.equipment_id = cells.value[0].equipment_id
    }
  } catch (e: any) {
    error.value = e.message ?? String(e)
  } finally {
    loading.value = false
  }
}

function applyWarnings(data: any, fallback: string) {
  const warnings: string[] = data?.warnings ?? []
  notice.value = warnings.length > 0 ? `${fallback} — ${warnings.join(' / ')}` : fallback
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
    sequenceForm.value.wave_id = data.wave_id
    palletizeForm.value.wave_id = data.wave_id
    notice.value = `웨이브 ${shortId(data.wave_id)} 개설 (OPEN)`
    await load()
  } catch (e: any) {
    error.value = e.message ?? String(e)
  } finally {
    submitting.value = null
  }
}

async function createOutboundOrder() {
  submitting.value = 'create-order'
  error.value = ''
  try {
    const f = orderForm.value
    const { data, error: rpcError } = await supabase.rpc('wms_create_outbound_order', {
      p_tenant_id: auth.currentTenantId,
      p_warehouse_id: auth.currentWarehouseId,
      p_store_code: f.store_code,
      p_product_id: f.product_id,
      p_qty: Number(f.qty),
      p_actor_id: auth.userId,
      p_idempotency_key: crypto.randomUUID(),
      p_order_number: f.order_number || null,
      p_requested_delivery_date: null,
      p_declared_weight_kg: f.declared_weight_kg === '' ? null : Number(f.declared_weight_kg),
      p_declared_volume_l: f.declared_volume_l === '' ? null : Number(f.declared_volume_l),
      p_correlation_id: null,
    })
    if (rpcError) throw rpcError
    notice.value = `출고 단위 ${shortId(data.outbound_order_id)} 등록 — ${data.status} (v${data.version})`
    orderForm.value.order_number = ''
    await load()
    sequenceForm.value.outbound_order_id = data.outbound_order_id
  } catch (e: any) {
    error.value = e.message ?? String(e)
  } finally {
    submitting.value = null
  }
}

async function assignSequence() {
  submitting.value = 'assign-sequence'
  error.value = ''
  try {
    const f = sequenceForm.value
    const order = orders.value.find((o) => o.outbound_order_id === f.outbound_order_id)
    if (!order) throw new Error('서열을 배정할 출고 단위를 선택하세요')
    if (!f.wave_id) throw new Error('OPEN 상태 웨이브를 선택하세요')
    const { data, error: rpcError } = await supabase.rpc('wms_assign_dispatch_sequence', {
      p_outbound_order_id: f.outbound_order_id,
      p_wave_id: f.wave_id,
      p_sequence_position: Number(f.sequence_position),
      p_target_pallet_code: f.target_pallet_code,
      p_actor_id: auth.userId,
      p_idempotency_key: crypto.randomUUID(),
      p_expected_version: order.version,
      p_correlation_id: null,
    })
    if (rpcError) throw rpcError
    notice.value =
      `서열 배정 ${shortId(data.dispatch_sequence_id)} — 위치 ${data.sequence_position}, ` +
      `팔레트 ${data.target_pallet_code} (출고 단위 ${data.outbound_order_status})`
    sequenceForm.value.sequence_position = Number(f.sequence_position) + 1
    await load()
  } catch (e: any) {
    error.value = e.message ?? String(e)
  } finally {
    submitting.value = null
  }
}

async function cancelSequence(seq: any) {
  submitting.value = seq.dispatch_sequence_id
  error.value = ''
  try {
    const { data, error: rpcError } = await supabase.rpc('wms_cancel_dispatch_sequence', {
      p_dispatch_sequence_id: seq.dispatch_sequence_id,
      p_actor_id: auth.userId,
      p_idempotency_key: crypto.randomUUID(),
      p_expected_version: seq.version,
      p_reason: '운영자 취소',
      p_correlation_id: null,
    })
    if (rpcError) throw rpcError
    applyWarnings(
      data,
      data.cancelled_equipment_command_id
        ? `서열 배정 취소 — 연결된 PALLETIZE 명령 ${shortId(data.cancelled_equipment_command_id)}도 함께 취소`
        : '서열 배정 취소',
    )
    await load()
  } catch (e: any) {
    error.value = e.message ?? String(e)
  } finally {
    submitting.value = null
  }
}

async function dispatchPalletize() {
  submitting.value = 'dispatch-palletize'
  error.value = ''
  try {
    const f = palletizeForm.value
    const cell = cells.value.find((c) => c.equipment_id === f.equipment_id)
    if (!cell) throw new Error('대상 ROBOT_CELL 설비를 선택하세요')
    if (!f.wave_id) throw new Error('웨이브를 선택하세요')
    const { data, error: rpcError } = await supabase.rpc('wms_dispatch_palletize_command', {
      p_equipment_id: f.equipment_id,
      p_wave_id: f.wave_id,
      p_target_pallet_code: f.target_pallet_code,
      p_actor_id: auth.userId,
      p_idempotency_key: crypto.randomUUID(),
      p_expected_version: cell.version,
      p_max_weight_kg: f.max_weight_kg === '' ? null : Number(f.max_weight_kg),
      p_max_volume_l: f.max_volume_l === '' ? null : Number(f.max_volume_l),
      p_correlation_id: null,
    })
    if (rpcError) throw rpcError
    applyWarnings(
      data,
      `PALLETIZE 명령 ${shortId(data.equipment_command_id)} — ${data.equipment_code}에 ` +
        `${data.item_count}건 (선언 ${data.declared_total_weight_kg}kg / ${data.declared_total_volume_l}L)`,
    )
    await load()
  } catch (e: any) {
    error.value = e.message ?? String(e)
  } finally {
    submitting.value = null
  }
}

async function dispatchWrap() {
  submitting.value = 'dispatch-wrap'
  error.value = ''
  try {
    const f = wrapForm.value
    const cell = cells.value.find((c) => c.equipment_id === f.equipment_id)
    if (!cell) throw new Error('대상 ROBOT_CELL 설비를 선택하세요')
    const { data, error: rpcError } = await supabase.rpc('wms_dispatch_equipment_command', {
      p_equipment_id: f.equipment_id,
      p_command_type: 'WRAP',
      p_payload: { pallet_code: f.pallet_code, wrap_program: f.wrap_program },
      p_actor_id: auth.userId,
      p_idempotency_key: crypto.randomUUID(),
      p_expected_version: cell.version,
      p_correlation_id: null,
      p_linked_entity_type: null,
      p_linked_entity_id: null,
    })
    if (rpcError) throw rpcError
    notice.value = `WRAP 명령 ${shortId(data.command_id)} — ${f.pallet_code} / ${f.wrap_program} (${data.status})`
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
    <h1>WCS Sequential Dispatch</h1>
    <p class="hint">
      매장별 출고 단위를 등록하고, 디스패치 웨이브 안에서 서열 위치와 목표 팔레트를 배정한 뒤,
      같은 팔레트로 묶인 항목 전부를 하나의 PALLETIZE 명령으로 로봇 셀에 보냅니다.
      현재 역할: {{ auth.currentRole }}
    </p>
    <div class="row">
      <button class="primary" @click="load">Refresh</button>
    </div>
    <div v-if="error" class="error-banner">{{ error }}</div>
    <div v-if="notice" class="notice-banner" data-testid="seq-notice">{{ notice }}</div>
    <p v-if="canPlan && !canDispatch" class="hint role-note" data-testid="role-note">
      이 역할은 출고 단위 등록과 서열 배정은 할 수 있지만 PALLETIZE/WRAP 명령은 보낼 수 없습니다
      (명령 디스패치는 WAREHOUSE_MANAGER / WCS_OPERATOR / PROCESS_AGENT).
    </p>

    <!-- waves ------------------------------------------------------- -->
    <div v-if="canPlan" class="card">
      <h2>디스패치 웨이브</h2>
      <p class="hint">서열은 웨이브 안에서만 의미가 있습니다. RELEASED된 웨이브에는 새 서열을 배정할 수 없습니다.</p>
      <div class="row">
        <button class="primary" :disabled="submitting === 'open-wave'" @click="openWave">Open Wave</button>
      </div>
      <table v-if="waves.length > 0" class="inner">
        <thead>
          <tr><th>Wave</th><th>Status</th><th>Version</th><th>Sequences</th><th>Queued</th></tr>
        </thead>
        <tbody>
          <tr v-for="w in waves" :key="w.wave_id" :data-wave-id="w.wave_id">
            <td>{{ shortId(w.wave_id) }}</td>
            <td><span class="status" :class="statusClass(w.status)">{{ w.status }}</span></td>
            <td>{{ w.version }}</td>
            <td>{{ w.sequence_count }}</td>
            <td>{{ w.queued_count }}</td>
          </tr>
        </tbody>
      </table>
      <p v-else class="hint">개설된 웨이브가 없습니다.</p>
    </div>

    <!-- outbound units ---------------------------------------------- -->
    <div v-if="canCreateOrder" class="card">
      <h2>출고 단위 등록</h2>
      <p class="hint">
        재고를 확인하거나 예약하지 않는 최소 골격입니다 — 상품 1건 = 행 1건. 중량/용적은
        상품 마스터데이터가 아니라 등록 시 선언하는 값이며, 팔레트 상한 검증의 기준이 됩니다.
      </p>
      <div class="row wrap">
        <label>
          Order Number
          <input v-model="orderForm.order_number" aria-label="order number" placeholder="OB-2026-0001" />
        </label>
        <label>
          Store Code
          <input v-model="orderForm.store_code" aria-label="store code" placeholder="STORE-042" />
        </label>
        <label>
          Product
          <select v-model="orderForm.product_id" aria-label="product">
            <option v-for="p in products" :key="p.id" :value="p.id">{{ p.sku }} · {{ p.name }}</option>
          </select>
        </label>
        <label>
          Qty
          <input v-model.number="orderForm.qty" type="number" aria-label="qty" />
        </label>
        <label>
          Declared Weight (kg)
          <input v-model="orderForm.declared_weight_kg" type="number" step="0.1" aria-label="declared weight" />
        </label>
        <label>
          Declared Volume (L)
          <input v-model="orderForm.declared_volume_l" type="number" step="0.1" aria-label="declared volume" />
        </label>
        <button class="primary" :disabled="submitting === 'create-order'" @click="createOutboundOrder">
          Create Outbound Order
        </button>
      </div>
    </div>

    <!-- sequencing --------------------------------------------------- -->
    <div v-if="canPlan" class="card">
      <h2>서열 배정</h2>
      <p class="hint">
        서열 위치와 목표 팔레트는 이 화면이 계산하지 않습니다 — 운영자가 정한 값을 저장·검증할 뿐입니다.
        같은 팔레트 코드를 가진 항목들이 나중에 하나의 PALLETIZE 명령으로 묶입니다.
      </p>
      <div class="row wrap">
        <label>
          Outbound Order (OPEN)
          <select v-model="sequenceForm.outbound_order_id" aria-label="outbound order">
            <option v-for="o in openOrders" :key="o.outbound_order_id" :value="o.outbound_order_id">
              {{ o.order_number || shortId(o.outbound_order_id) }} · {{ o.store_code }} · {{ o.sku }} ×
              {{ o.qty }}
            </option>
          </select>
        </label>
        <label>
          Wave
          <select v-model="sequenceForm.wave_id" aria-label="sequence wave">
            <option v-for="w in openWaves" :key="w.wave_id" :value="w.wave_id">
              {{ shortId(w.wave_id) }} (OPEN)
            </option>
          </select>
        </label>
        <label>
          Sequence Position
          <input
            v-model.number="sequenceForm.sequence_position"
            type="number"
            aria-label="sequence position"
          />
        </label>
        <label>
          Target Pallet
          <input v-model="sequenceForm.target_pallet_code" aria-label="target pallet code" />
        </label>
        <button class="primary" :disabled="submitting === 'assign-sequence'" @click="assignSequence">
          Assign Sequence
        </button>
      </div>
    </div>

    <!-- palletising -------------------------------------------------- -->
    <div v-if="canDispatch" class="card">
      <h2>팔레타이징 / 스트레치 포장 명령</h2>
      <p class="hint">
        하나의 팔레트는 한 로봇 셀에서 처음부터 끝까지 쌓입니다 — 대상 셀은 자동 선택되지 않고
        여기서 지정합니다. 상한을 지정하면 선언값 합계가 그 상한을 넘을 때 명령 자체가 거부됩니다.
      </p>
      <div class="row wrap">
        <label>
          Robot Cell
          <select v-model="palletizeForm.equipment_id" aria-label="robot cell">
            <option v-for="c in cells" :key="c.equipment_id" :value="c.equipment_id">
              {{ c.equipment_code }} · {{ c.status }}{{ c.active_palletize_pallet ? ' · ' + c.active_palletize_pallet : '' }}
            </option>
          </select>
        </label>
        <label>
          Wave
          <select v-model="palletizeForm.wave_id" aria-label="palletize wave">
            <option v-for="w in waves" :key="w.wave_id" :value="w.wave_id">
              {{ shortId(w.wave_id) }} ({{ w.status }})
            </option>
          </select>
        </label>
        <label>
          Target Pallet
          <input v-model="palletizeForm.target_pallet_code" aria-label="palletize pallet code" />
        </label>
        <label>
          Max Weight (kg)
          <input v-model="palletizeForm.max_weight_kg" type="number" step="1" aria-label="max weight" />
        </label>
        <label>
          Max Volume (L)
          <input v-model="palletizeForm.max_volume_l" type="number" step="1" aria-label="max volume" />
        </label>
        <button class="primary" :disabled="submitting === 'dispatch-palletize'" @click="dispatchPalletize">
          Dispatch PALLETIZE
        </button>
      </div>
      <div class="row wrap">
        <label>
          Wrap Cell
          <select v-model="wrapForm.equipment_id" aria-label="wrap cell">
            <option v-for="c in cells" :key="c.equipment_id" :value="c.equipment_id">
              {{ c.equipment_code }} · {{ c.status }}
            </option>
          </select>
        </label>
        <label>
          Pallet Code
          <input v-model="wrapForm.pallet_code" aria-label="wrap pallet code" />
        </label>
        <label>
          Wrap Program
          <select v-model="wrapForm.wrap_program" aria-label="wrap program">
            <option value="STANDARD">STANDARD</option>
            <option value="HEAVY">HEAVY</option>
          </select>
        </label>
        <button class="primary" :disabled="submitting === 'dispatch-wrap'" @click="dispatchWrap">
          Dispatch WRAP
        </button>
      </div>
    </div>

    <!-- pallet roll-up ------------------------------------------------ -->
    <h2 class="section">팔레트 현황</h2>
    <table v-if="pallets.length > 0" data-testid="pallet-rollup">
      <thead>
        <tr>
          <th>Pallet</th><th>Wave</th><th>Queued</th><th>Dispatched</th><th>Completed</th>
          <th>Failed</th><th>선언 중량</th><th>선언 용적</th><th>Command</th>
        </tr>
      </thead>
      <tbody>
        <tr v-for="p in pallets" :key="p.wave_id + p.target_pallet_code" :data-pallet="p.target_pallet_code">
          <td>{{ p.target_pallet_code }}</td>
          <td>{{ shortId(p.wave_id) }}</td>
          <td>{{ p.queued_count }}</td>
          <td>{{ p.dispatched_count }}</td>
          <td data-testid="pallet-completed">{{ p.completed_count }}</td>
          <td data-testid="pallet-failed">{{ p.failed_count }}</td>
          <td>{{ num(p.declared_weight_kg) }} kg</td>
          <td>{{ num(p.declared_volume_l) }} L</td>
          <td>{{ shortId(p.equipment_command_id) }}</td>
        </tr>
      </tbody>
    </table>
    <p v-else class="hint">아직 서열이 배정된 팔레트가 없습니다.</p>

    <!-- sequences ----------------------------------------------------- -->
    <h2 class="section">서열 배정</h2>
    <table v-if="!loading" data-testid="sequence-table">
      <thead>
        <tr>
          <th>#</th><th>Order</th><th>Store</th><th>SKU</th><th>Qty</th><th>Pallet</th>
          <th>Status</th><th>Load Pos</th><th>Version</th><th>Equipment Command</th>
          <th v-if="canPlan">Actions</th>
        </tr>
      </thead>
      <tbody>
        <tr v-for="s in sequences" :key="s.dispatch_sequence_id" :data-sequence="s.dispatch_sequence_id">
          <td>{{ s.sequence_position }}</td>
          <td>{{ s.order_number || shortId(s.outbound_order_id) }}</td>
          <td>{{ s.store_code }}</td>
          <td>{{ s.sku }}</td>
          <td>{{ s.qty }}</td>
          <td>{{ s.target_pallet_code }}</td>
          <td>
            <span class="status" :class="statusClass(s.status)" data-testid="sequence-status">{{ s.status }}</span>
          </td>
          <td>{{ s.load_position ?? '—' }}</td>
          <td>{{ s.version }}</td>
          <td>
            <span v-if="s.equipment_command" data-testid="command-summary">
              {{ s.equipment_command.equipment_code }} · {{ s.equipment_command.command_type }} /
              {{ s.equipment_command.status }}
            </span>
            <span v-else class="hint">—</span>
          </td>
          <td v-if="canPlan">
            <button
              v-if="['QUEUED', 'DISPATCHED'].includes(s.status)"
              class="primary danger"
              :aria-label="`Cancel sequence ${s.sequence_position}`"
              :disabled="submitting === s.dispatch_sequence_id"
              @click="cancelSequence(s)"
            >
              Cancel
            </button>
            <span v-else class="hint">종결</span>
          </td>
        </tr>
      </tbody>
    </table>
    <p v-if="!loading && sequences.length === 0">배정된 서열이 없습니다.</p>

    <!-- manifests ----------------------------------------------------- -->
    <h2 class="section">팔레트 매니페스트</h2>
    <p class="hint">
      로봇 셀이 실제로 무엇을 어느 위치에 실었는지입니다. 결과가 아직 보고되지 않은 명령은
      오류가 아니라 빈 매니페스트로 표시됩니다.
    </p>
    <div v-for="m in manifests" :key="m.equipment_command_id" class="card" :data-manifest="m.target_pallet_code">
      <div class="head">
        <strong>{{ m.target_pallet_code }}</strong>
        <span class="muted">{{ m.equipment_code }} · 명령 {{ shortId(m.equipment_command_id) }}</span>
        <span class="status" :class="statusClass(m.command_status)">{{ m.command_status }}</span>
        <span v-if="m.outcome" class="status" :class="m.outcome === 'SUCCESS' ? 'ok' : m.outcome === 'PARTIAL' ? 'warn' : 'danger'" data-testid="manifest-outcome">
          {{ m.outcome }}
        </span>
        <span v-else class="status warn" data-testid="manifest-pending">결과 미보고</span>
      </div>
      <div class="summary">
        <span>계획 {{ m.planned_item_count }}건</span>
        <span>선언 {{ num(m.declared_total_weight_kg) }}kg / {{ num(m.declared_total_volume_l) }}L</span>
        <span v-if="m.reported">실측 {{ num(m.total_actual_weight_kg) }}kg / {{ num(m.total_actual_volume_l) }}L</span>
        <span v-if="m.max_weight_kg">상한 {{ m.max_weight_kg }}kg</span>
      </div>
      <table v-if="m.items.length > 0" class="inner">
        <thead>
          <tr><th>Load Pos</th><th>Outcome</th><th>Store</th><th>SKU</th><th>Qty</th><th>선언 중량</th><th>Reason</th></tr>
        </thead>
        <tbody>
          <tr v-for="i in m.items" :key="i.dispatch_sequence_id">
            <td>{{ i.load_position ?? '—' }}</td>
            <td>
              <span class="status" :class="i.item_outcome === 'LOADED' ? 'ok' : 'danger'" data-testid="item-outcome">
                {{ i.item_outcome }}
              </span>
            </td>
            <td>{{ i.store_code }}</td>
            <td>{{ i.sku }}</td>
            <td>{{ i.qty }}</td>
            <td>{{ num(i.declared_weight_kg) }} kg</td>
            <td>{{ i.reason ?? '—' }}</td>
          </tr>
        </tbody>
      </table>
      <p v-else class="hint">아직 적재 결과가 보고되지 않았습니다 (계획 {{ m.planned_item_count }}건).</p>
    </div>
    <p v-if="manifests.length === 0" class="hint">디스패치된 PALLETIZE 명령이 없습니다.</p>
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
h2 {
  font-size: 1rem;
  margin: 0 0 0.25rem;
}
h2.section {
  margin: 1.5rem 0 0.5rem;
}
.row {
  display: flex;
  gap: 0.5rem;
  align-items: flex-end;
  margin-top: 0.5rem;
  flex-wrap: wrap;
}
.row.wrap {
  flex-wrap: wrap;
}
.head {
  display: flex;
  gap: 0.6rem;
  align-items: center;
  margin-bottom: 0.4rem;
}
.summary {
  display: flex;
  gap: 0.75rem;
  flex-wrap: wrap;
  font-size: 0.85rem;
  color: var(--muted);
  margin-bottom: 0.4rem;
}
.muted {
  color: var(--muted);
  font-size: 0.85rem;
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
  margin-top: 0.5rem;
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
