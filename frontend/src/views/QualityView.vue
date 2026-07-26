<script setup lang="ts">
import { ref, watch, onMounted } from 'vue'
import { useAuthStore } from '@/stores/auth'
import { supabase } from '@/lib/supabase'

const auth = useAuthStore()
const rows = ref<any[]>([])
const products = ref<Map<string, string>>(new Map())
const loading = ref(false)
const error = ref('')
const submitting = ref<string | null>(null)
const reasonByReceipt = ref<Record<string, string>>({})

const canInspect = () => ['QUALITY_INSPECTOR', 'WMS_ADMIN'].includes(auth.currentRole ?? '')
const canPutaway = () => ['INBOUND_OPERATOR', 'WMS_ADMIN'].includes(auth.currentRole ?? '')

async function load() {
  if (!auth.currentTenantId || !auth.currentWarehouseId) return
  loading.value = true
  error.value = ''
  try {
    const [{ data: receipts, error: rErr }, { data: prods, error: pErr }] = await Promise.all([
      supabase
        .from('receipts')
        .select('*')
        .eq('tenant_id', auth.currentTenantId)
        .eq('warehouse_id', auth.currentWarehouseId)
        .in('status', ['QC_PENDING', 'QC_COMPLETED', 'PUTAWAY_PENDING'])
        .order('created_at', { ascending: false }),
      supabase.from('products').select('id, sku').eq('tenant_id', auth.currentTenantId),
    ])
    if (rErr) throw rErr
    if (pErr) throw pErr
    products.value = new Map((prods ?? []).map((p: any) => [p.id, p.sku]))
    rows.value = receipts ?? []
  } catch (e: any) {
    error.value = e.message ?? String(e)
  } finally {
    loading.value = false
  }
}

async function recordResult(receipt: any, result: 'PASSED' | 'FAILED') {
  submitting.value = receipt.id
  error.value = ''
  try {
    const { error: rpcError } = await supabase.rpc('wms_record_quality_result', {
      p_receipt_id: receipt.id,
      p_result: result,
      p_reason_code: reasonByReceipt.value[receipt.id] || null,
      p_actor_id: auth.userId,
      p_idempotency_key: crypto.randomUUID(),
    })
    if (rpcError) throw rpcError
    await load()
  } catch (e: any) {
    error.value = e.message ?? String(e)
  } finally {
    submitting.value = null
  }
}

async function putaway(receipt: any) {
  submitting.value = receipt.id
  error.value = ''
  try {
    const { error: rpcError } = await supabase.rpc('wms_create_putaway_tasks', {
      p_receipt_id: receipt.id,
      p_actor_id: auth.userId,
      p_idempotency_key: crypto.randomUUID(),
    })
    if (rpcError) throw rpcError
    await load()
  } catch (e: any) {
    error.value = e.message ?? String(e)
  } finally {
    submitting.value = null
  }
}

async function scrap(receipt: any) {
  submitting.value = receipt.id
  error.value = ''
  try {
    const reason = reasonByReceipt.value[receipt.id]
    if (!reason) throw new Error('폐기 사유 코드가 필요합니다')
    const { error: rpcError } = await supabase.rpc('wms_apply_disposition', {
      p_receipt_id: receipt.id,
      p_reason_code: reason,
      p_actor_id: auth.userId,
      p_idempotency_key: crypto.randomUUID(),
    })
    if (rpcError) throw rpcError
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
    <h1>Quality</h1>
    <p class="hint">검수 대기(QC_PENDING) 판정, 합격 적치(PUTAWAY_PENDING), 불합격 폐기(QC_COMPLETED). 현재 역할: {{ auth.currentRole }}</p>
    <div v-if="error" class="error-banner">{{ error }}</div>
    <div v-for="r in rows" :key="r.id" class="card">
      <strong>{{ products.get(r.product_id) }}</strong> — received {{ r.received_qty }}
      <span class="status warn">{{ r.status }}</span>

      <div v-if="r.status === 'QC_PENDING' && canInspect()" class="row">
        <input placeholder="reason code (선택)" v-model="reasonByReceipt[r.id]" />
        <button class="primary" :disabled="submitting === r.id" @click="recordResult(r, 'PASSED')">Pass</button>
        <button class="danger" :disabled="submitting === r.id" @click="recordResult(r, 'FAILED')">Fail</button>
      </div>

      <div v-else-if="r.status === 'PUTAWAY_PENDING' && canPutaway()" class="row">
        <button class="primary" :disabled="submitting === r.id" @click="putaway(r)">Putaway (→ Available)</button>
      </div>

      <div v-else-if="r.status === 'QC_COMPLETED' && canInspect()" class="row">
        <input placeholder="폐기 사유 코드 (필수)" v-model="reasonByReceipt[r.id]" />
        <button class="danger" :disabled="submitting === r.id" @click="scrap(r)">Scrap</button>
      </div>
    </div>
    <p v-if="!loading && rows.length === 0">대기 중인 검수/처분 건이 없습니다.</p>
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
  margin-top: 0.5rem;
}
input {
  padding: 0.4rem;
  border: 1px solid var(--line);
  border-radius: 6px;
  flex: 1;
}
button.danger {
  background: #dc2626;
  color: white;
  border: none;
  padding: 0.45rem 0.9rem;
  border-radius: 6px;
  cursor: pointer;
}
</style>
