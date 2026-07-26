<script setup lang="ts">
import { ref, watch, onMounted } from 'vue'
import { useAuthStore } from '@/stores/auth'
import { supabase } from '@/lib/supabase'

const auth = useAuthStore()
const rows = ref<Array<{
  id: string
  sku: string
  name: string
  reorder_min: number
  reorder_max: number
  available_qty: number
  below_min: boolean
}>>([])
const suppliers = ref<Array<{ id: string; name: string }>>([])
const loading = ref(false)
const error = ref('')
const submitting = ref<string | null>(null)
const qtyBySku = ref<Record<string, number>>({})
const supplierBySku = ref<Record<string, string>>({})

async function load() {
  if (!auth.currentTenantId || !auth.currentWarehouseId) return
  loading.value = true
  error.value = ''
  try {
    const [{ data: products, error: pErr }, { data: availability, error: aErr }, { data: sup, error: sErr }] =
      await Promise.all([
        supabase.from('products').select('id, sku, name, reorder_min, reorder_max').eq('tenant_id', auth.currentTenantId),
        supabase
          .from('inventory_availability_v')
          .select('product_id, available_qty')
          .eq('tenant_id', auth.currentTenantId)
          .eq('warehouse_id', auth.currentWarehouseId),
        supabase.from('suppliers').select('id, name').eq('tenant_id', auth.currentTenantId),
      ])
    if (pErr) throw pErr
    if (aErr) throw aErr
    if (sErr) throw sErr

    suppliers.value = sup ?? []
    const byProduct = new Map((availability ?? []).map((a: any) => [a.product_id, a]))
    rows.value = (products ?? [])
      .map((p: any) => {
        const available_qty = Number(byProduct.get(p.id)?.available_qty ?? 0)
        return { ...p, available_qty, below_min: available_qty < Number(p.reorder_min) }
      })
      .filter((r: any) => r.below_min)
  } catch (e: any) {
    error.value = e.message ?? String(e)
  } finally {
    loading.value = false
  }
}

async function createRfq(row: (typeof rows.value)[number]) {
  submitting.value = row.id
  error.value = ''
  try {
    const qty = qtyBySku.value[row.sku] || row.reorder_max - row.available_qty
    const { error: rpcError } = await supabase.rpc('wms_create_rfq', {
      p_tenant_id: auth.currentTenantId,
      p_warehouse_id: auth.currentWarehouseId,
      p_sku: row.sku,
      p_qty: qty,
      p_supplier_id: supplierBySku.value[row.sku] || null,
      p_actor_id: auth.userId,
      p_idempotency_key: crypto.randomUUID(),
      p_correlation_id: null,
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
    <h1>Replenishment</h1>
    <p class="hint">reorder_min 미만인 SKU. 수량/공급사를 지정해 RFQ를 생성하면 승인 대기 상태가 됩니다.</p>
    <div v-if="error" class="error-banner">{{ error }}</div>
    <p v-if="!loading && rows.length === 0">부족 재고가 없습니다.</p>
    <div v-for="r in rows" :key="r.id" class="card">
      <strong>{{ r.sku }} — {{ r.name }}</strong>
      <p>Available: {{ r.available_qty }} / Reorder Min: {{ r.reorder_min }} / Max: {{ r.reorder_max }}</p>
      <div class="row">
        <label>
          Qty
          <input
            type="number"
            :placeholder="String(r.reorder_max - r.available_qty)"
            v-model.number="qtyBySku[r.sku]"
          />
        </label>
        <label>
          Supplier
          <select v-model="supplierBySku[r.sku]">
            <option value="">(none)</option>
            <option v-for="s in suppliers" :key="s.id" :value="s.id">{{ s.name }}</option>
          </select>
        </label>
        <button class="primary" :disabled="submitting === r.id" @click="createRfq(r)">
          {{ submitting === r.id ? 'Creating…' : 'Create RFQ' }}
        </button>
      </div>
    </div>
  </div>
</template>

<style scoped>
.hint {
  color: var(--muted);
  margin-top: -0.5rem;
}
.row {
  display: flex;
  gap: 1rem;
  align-items: flex-end;
  margin-top: 0.5rem;
}
label {
  display: flex;
  flex-direction: column;
  gap: 0.25rem;
  font-size: 0.8rem;
  color: var(--muted);
}
input, select {
  padding: 0.4rem;
  border: 1px solid var(--line);
  border-radius: 6px;
}
</style>
