import { defineStore } from 'pinia'
import { supabase } from '@/lib/supabase'
import { getTenantIdFromHost } from '@/lib/tenant'

function readCookie(name: string): string | undefined {
  return document.cookie
    .split('; ')
    .find((row) => row.startsWith(`${name}=`))
    ?.split('=')[1]
}

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

    /**
     * Resolves a session for this page. wms-frontend shares ProcessGPT's
     * Supabase project and is reached at `<tenant>.process-gpt.io/wms`
     * (same origin as ProcessGPT itself, gateway strips the /wms prefix) —
     * so ProcessGPT's own `access_token`/`refresh_token` cookies (set with
     * `domain=.process-gpt.io` on login, see process-gpt-vue3's
     * StorageBaseSupabase.writeUserData) are already visible to this page's
     * JS. No token handoff route is needed: if this origin doesn't already
     * have a Supabase session in localStorage (e.g. first visit), read
     * those cookies and hydrate one, exactly like ProcessGPT's own
     * StorageBaseSupabase.isConnection() does.
     */
    async restoreSession() {
      let { data } = await supabase.auth.getSession()
      if (!data.session) {
        const accessToken = readCookie('access_token')
        const refreshToken = readCookie('refresh_token')
        if (accessToken && refreshToken) {
          const { data: setData, error } = await supabase.auth.setSession({
            access_token: accessToken,
            refresh_token: refreshToken,
          })
          if (error) return
          data = setData
        }
      }
      if (!data.session) return
      this.userId = data.session.user.id
      this.email = data.session.user.email ?? null
      await this.loadContext(data.session.user.app_metadata?.tenant_id as string | undefined)
    },

    /**
     * tenant_id resolution order mirrors process-gpt-vue3's src/utils/tenant.js:
     * (1) subdomain parsed from the URL — the same value ProcessGPT's gateway
     * validated against the JWT before routing here, (2) the JWT's own
     * app_metadata.tenant_id claim, (3) the first membership. Never a hardcoded
     * fallback — an unrecognized/unlisted tenant just shows no memberships.
     */
    async loadContext(jwtTenantId?: string) {
      const { data: memberships, error } = await supabase
        .from('memberships')
        .select('tenant_id, role, tenants(name)')
      if (error) throw error

      this.memberships = (memberships ?? []).map((m: any) => ({
        tenant_id: m.tenant_id,
        role: m.role,
        tenant_name: m.tenants?.name ?? m.tenant_id,
      }))

      const hostTenantId = getTenantIdFromHost()
      const preferred = [hostTenantId, jwtTenantId].find((id) =>
        id && this.memberships.some((m) => m.tenant_id === id),
      )

      if (preferred) {
        await this.setTenant(preferred)
      } else if (this.memberships.length > 0) {
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
