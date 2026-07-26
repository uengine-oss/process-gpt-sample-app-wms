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
  qc_qty: number
  below_min: boolean
}>>([])
const loading = ref(false)
const error = ref('')

async function load() {
  if (!auth.currentTenantId || !auth.currentWarehouseId) return
  loading.value = true
  error.value = ''
  try {
    const { data: products, error: pErr } = await supabase
      .from('products')
      .select('id, sku, name, reorder_min, reorder_max')
      .eq('tenant_id', auth.currentTenantId)
    if (pErr) throw pErr

    const { data: availability, error: aErr } = await supabase
      .from('inventory_availability_v')
      .select('product_id, available_qty, qc_qty')
      .eq('tenant_id', auth.currentTenantId)
      .eq('warehouse_id', auth.currentWarehouseId)
    if (aErr) throw aErr

    const byProduct = new Map((availability ?? []).map((a: any) => [a.product_id, a]))
    rows.value = (products ?? []).map((p: any) => {
      const avail = byProduct.get(p.id)
      const available_qty = Number(avail?.available_qty ?? 0)
      return {
        ...p,
        available_qty,
        qc_qty: Number(avail?.qc_qty ?? 0),
        below_min: available_qty < Number(p.reorder_min),
      }
    })
  } catch (e: any) {
    error.value = e.message ?? String(e)
  } finally {
    loading.value = false
  }
}

onMounted(load)
watch(() => auth.currentWarehouseId, load)
</script>

<template>
  <div>
    <h1>Overview</h1>
    <p class="hint">SKU별 가용재고와 재보충 최소량(reorder_min) 대비 부족 여부.</p>
    <div v-if="error" class="error-banner">{{ error }}</div>
    <table v-if="!loading">
      <thead>
        <tr>
          <th>SKU</th>
          <th>Name</th>
          <th>Available</th>
          <th>In QC</th>
          <th>Reorder Min / Max</th>
          <th>Status</th>
        </tr>
      </thead>
      <tbody>
        <tr v-for="r in rows" :key="r.id">
          <td>{{ r.sku }}</td>
          <td>{{ r.name }}</td>
          <td>{{ r.available_qty }}</td>
          <td>{{ r.qc_qty }}</td>
          <td>{{ r.reorder_min }} / {{ r.reorder_max }}</td>
          <td>
            <span class="status" :class="r.below_min ? 'warn' : 'ok'">
              {{ r.below_min ? 'BELOW MIN' : 'OK' }}
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
</style>
