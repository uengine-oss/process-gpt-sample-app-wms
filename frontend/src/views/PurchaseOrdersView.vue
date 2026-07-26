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

const canApprove = () => ['PURCHASE_APPROVER', 'WMS_ADMIN'].includes(auth.currentRole ?? '')
const canConfirm = () => ['PROCUREMENT_BUYER', 'WMS_ADMIN'].includes(auth.currentRole ?? '')

async function load() {
  if (!auth.currentTenantId || !auth.currentWarehouseId) return
  loading.value = true
  error.value = ''
  try {
    const [{ data: pos, error: poErr }, { data: prods, error: pErr }] = await Promise.all([
      supabase
        .from('purchase_orders')
        .select('*')
        .eq('tenant_id', auth.currentTenantId)
        .eq('warehouse_id', auth.currentWarehouseId)
        .order('created_at', { ascending: false }),
      supabase.from('products').select('id, sku').eq('tenant_id', auth.currentTenantId),
    ])
    if (poErr) throw poErr
    if (pErr) throw pErr
    products.value = new Map((prods ?? []).map((p: any) => [p.id, p.sku]))
    rows.value = pos ?? []
  } catch (e: any) {
    error.value = e.message ?? String(e)
  } finally {
    loading.value = false
  }
}

async function decide(po: any, decision: 'APPROVE' | 'REJECT') {
  submitting.value = po.id
  error.value = ''
  try {
    const { error: rpcError } = await supabase.rpc('wms_submit_purchase_approval', {
      p_po_id: po.id,
      p_decision: decision,
      p_approver_id: auth.userId,
      p_expected_version: po.version,
      p_reason: decision === 'REJECT' ? '수동 반려' : null,
    })
    if (rpcError) throw rpcError
    await load()
  } catch (e: any) {
    error.value = e.message ?? String(e)
  } finally {
    submitting.value = null
  }
}

async function confirm(po: any) {
  submitting.value = po.id
  error.value = ''
  try {
    const { error: rpcError } = await supabase.rpc('wms_confirm_purchase_order', {
      p_po_id: po.id,
      p_actor_id: auth.userId,
      p_idempotency_key: crypto.randomUUID(),
      p_expected_version: po.version,
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
  if (status === 'CONFIRMED_PO') return 'ok'
  if (status === 'REJECTED' || status === 'CANCELLED') return 'danger'
  return 'warn'
}

onMounted(load)
watch(() => auth.currentWarehouseId, load)
</script>

<template>
  <div>
    <h1>Purchase Orders</h1>
    <p class="hint">RFQ가 승인되면 PO로 확정합니다. 현재 역할: {{ auth.currentRole }}</p>
    <div v-if="error" class="error-banner">{{ error }}</div>
    <table>
      <thead>
        <tr>
          <th>SKU</th>
          <th>Qty</th>
          <th>Status</th>
          <th>Version</th>
          <th>Action</th>
        </tr>
      </thead>
      <tbody>
        <tr v-for="po in rows" :key="po.id">
          <td>{{ products.get(po.product_id) }}</td>
          <td>{{ po.qty }}</td>
          <td><span class="status" :class="statusClass(po.status)">{{ po.status }}</span></td>
          <td>{{ po.version }}</td>
          <td>
            <template v-if="po.status === 'TO_APPROVE' && canApprove()">
              <button class="primary" :disabled="submitting === po.id" @click="decide(po, 'APPROVE')">Approve</button>
              <button class="danger" :disabled="submitting === po.id" @click="decide(po, 'REJECT')">Reject</button>
            </template>
            <template v-else-if="po.status === 'APPROVED' && canConfirm()">
              <button class="primary" :disabled="submitting === po.id" @click="confirm(po)">Confirm PO</button>
            </template>
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
button {
  margin-right: 0.4rem;
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
