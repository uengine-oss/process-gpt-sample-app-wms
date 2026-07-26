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
const qtyByReceipt = ref<Record<string, number>>({})

const canOperate = () => ['INBOUND_OPERATOR', 'WMS_ADMIN'].includes(auth.currentRole ?? '')

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

async function registerArrival(receipt: any) {
  submitting.value = receipt.id
  error.value = ''
  try {
    const { error: rpcError } = await supabase.rpc('wms_register_arrival', {
      p_po_id: receipt.po_id,
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

async function receive(receipt: any) {
  submitting.value = receipt.id
  error.value = ''
  try {
    const qty = qtyByReceipt.value[receipt.id] || receipt.expected_qty
    const { error: rpcError } = await supabase.rpc('wms_receive', {
      p_receipt_id: receipt.id,
      p_qty: qty,
      p_actor_id: auth.userId,
      p_idempotency_key: crypto.randomUUID(),
      p_expected_version: receipt.version,
    })
    if (rpcError) throw rpcError
    await load()
  } catch (e: any) {
    error.value = e.message ?? String(e)
  } finally {
    submitting.value = null
  }
}

function statusClass(status: string) {
  if (['PUTAWAY_COMPLETED'].includes(status)) return 'ok'
  return 'warn'
}

onMounted(load)
watch(() => auth.currentWarehouseId, load)
</script>

<template>
  <div>
    <h1>Receiving</h1>
    <p class="hint">확정된 PO의 입하 도착과 실입고 수량을 등록합니다. 현재 역할: {{ auth.currentRole }}</p>
    <div v-if="error" class="error-banner">{{ error }}</div>
    <table>
      <thead>
        <tr>
          <th>SKU</th>
          <th>Expected / Received</th>
          <th>Status</th>
          <th>Action</th>
        </tr>
      </thead>
      <tbody>
        <tr v-for="r in rows" :key="r.id">
          <td>{{ products.get(r.product_id) }}</td>
          <td>{{ r.expected_qty }} / {{ r.received_qty }}</td>
          <td><span class="status" :class="statusClass(r.status)">{{ r.status }}</span></td>
          <td>
            <button v-if="r.status === 'EXPECTED' && canOperate()" class="primary" :disabled="submitting === r.id" @click="registerArrival(r)">
              Register Arrival
            </button>
            <span v-else-if="r.status === 'ARRIVED' && canOperate()" class="row">
              <input type="number" v-model.number="qtyByReceipt[r.id]" :placeholder="String(r.expected_qty)" />
              <button class="primary" :disabled="submitting === r.id" @click="receive(r)">Receive</button>
            </span>
          </td>
        </tr>
      </tbody>
    </table>
  </div>
</template>

<style scoped>
.hint {
  color: var(--muted);
  margin-top: -0.5rem;
}
.row {
  display: inline-flex;
  gap: 0.4rem;
  align-items: center;
}
input {
  width: 70px;
  padding: 0.35rem;
  border: 1px solid var(--line);
  border-radius: 6px;
}
</style>
