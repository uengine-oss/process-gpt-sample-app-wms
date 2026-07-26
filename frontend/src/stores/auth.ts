import { defineStore } from 'pinia'
import { supabase } from '@/lib/supabase'

interface Membership {
  tenant_id: string
  role: string
  tenant_name: string
}

interface Warehouse {
  id: string
  code: string
  name: string
}

export const useAuthStore = defineStore('auth', {
  state: () => ({
    userId: null as string | null,
    email: null as string | null,
    memberships: [] as Membership[],
    warehouses: [] as Warehouse[],
    currentTenantId: null as string | null,
    currentWarehouseId: null as string | null,
  }),
  getters: {
    isSignedIn: (state) => !!state.userId,
    currentRole: (state) =>
      state.memberships.find((m) => m.tenant_id === state.currentTenantId)?.role ?? null,
  },
  actions: {
    async signIn(email: string, password: string) {
      const { data, error } = await supabase.auth.signInWithPassword({ email, password })
      if (error) throw error
      this.userId = data.user.id
      this.email = data.user.email ?? null
      await this.loadContext()
    },

    async signOut() {
      await supabase.auth.signOut()
      this.$reset()
    },

    async restoreSession() {
      const { data } = await supabase.auth.getSession()
      if (!data.session) return
      this.userId = data.session.user.id
      this.email = data.session.user.email ?? null
      await this.loadContext()
    },

    async loadContext() {
      const { data: memberships, error } = await supabase
        .from('memberships')
        .select('tenant_id, role, tenants(name)')
      if (error) throw error

      this.memberships = (memberships ?? []).map((m: any) => ({
        tenant_id: m.tenant_id,
        role: m.role,
        tenant_name: m.tenants?.name ?? m.tenant_id,
      }))

      if (this.memberships.length > 0) {
        this.currentTenantId = this.memberships[0].tenant_id
        await this.loadWarehouses()
      }
    },

    async loadWarehouses() {
      if (!this.currentTenantId) return
      const { data: warehouseIds, error: idsError } = await supabase.rpc('current_warehouse_ids', {
        p_tenant_id: this.currentTenantId,
      })
      if (idsError) throw idsError

      const { data: warehouses, error } = await supabase
        .from('warehouses')
        .select('id, code, name')
        .in('id', warehouseIds ?? [])
      if (error) throw error

      this.warehouses = warehouses ?? []
      this.currentWarehouseId = this.warehouses[0]?.id ?? null
    },

    async setTenant(tenantId: string) {
      this.currentTenantId = tenantId
      await this.loadWarehouses()
    },
  },
})
