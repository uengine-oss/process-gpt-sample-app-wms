<script setup lang="ts">
import { computed } from 'vue'
import { useRoute } from 'vue-router'
import { useAuthStore } from '@/stores/auth'

const route = useRoute()
const auth = useAuthStore()

// Grouped because a flat list of 13 was getting hard to scan: the WMS business
// documents first (the docs/02-contracts.md slice, plus the yard/dock contract
// that hangs off Receiving), then the automation-side WCS/WES screens, then the
// oversight screens that look BACK at what the other two produced.
//
// A link may carry `roles`, in which case it is only rendered for those roles.
// So far exactly one does — the audit log, which is WMS_ADMIN / AUDITOR only.
// Hiding it is a courtesy to the other roles, not a control: the route guard
// bounces a direct URL and the RPCs return FORBIDDEN under both.
const allNavGroups = [
  {
    label: 'WMS',
    links: [
      { to: '/overview', label: 'Overview' },
      { to: '/replenishment', label: 'Replenishment' },
      { to: '/procurement/purchase-orders', label: 'Purchase Orders' },
      { to: '/inbound/receipts', label: 'Receiving' },
      { to: '/inbound/dock-schedule', label: 'Dock Schedule' },
      { to: '/quality/inspections', label: 'Quality' },
      { to: '/labor', label: 'Labor' },
      { to: '/slotting', label: 'Slotting' },
      { to: '/agent/decisions', label: 'Agent Decisions' },
    ],
  },
  {
    label: 'WCS / WES',
    links: [
      { to: '/wcs/equipment', label: 'WCS Equipment' },
      { to: '/wcs/monitor', label: 'WCS Monitor' },
      { to: '/wcs/sortation', label: 'WCS Sortation' },
      { to: '/wcs/routing', label: 'WCS Routing' },
      { to: '/wcs/sequential-dispatch', label: 'WCS Sequencing' },
      { to: '/wcs/simulation', label: 'WCS Simulation' },
      { to: '/wes/dispatch', label: 'WES Dispatch' },
    ],
  },
  {
    label: 'Oversight',
    links: [
      { to: '/operations/audit-log', label: 'Audit Log', roles: ['WMS_ADMIN', 'AUDITOR'] },
    ],
  },
] as { label: string; links: { to: string; label: string; roles?: string[] }[] }[]

const navGroups = computed(() =>
  allNavGroups
    .map((g) => ({
      ...g,
      links: g.links.filter((l) => !l.roles || l.roles.includes(auth.currentRole ?? '')),
    }))
    .filter((g) => g.links.length > 0),
)

async function onTenantChange(event: Event) {
  const tenantId = (event.target as HTMLSelectElement).value
  await auth.setTenant(tenantId)
}
</script>

<template>
  <div v-if="route.name === 'login'">
    <router-view />
  </div>
  <div v-else class="shell">
    <header class="topbar">
      <div class="brand">WMS <span>· ProcessGPT Sample App</span></div>
      <div class="context">
        <select v-if="auth.memberships.length > 1" :value="auth.currentTenantId ?? ''" @change="onTenantChange">
          <option v-for="m in auth.memberships" :key="m.tenant_id" :value="m.tenant_id">
            {{ m.tenant_name }}
          </option>
        </select>
        <span v-else class="tenant-label">{{ auth.memberships[0]?.tenant_name }}</span>
        <span class="warehouse-label">{{ auth.warehouses.find((w) => w.id === auth.currentWarehouseId)?.name }}</span>
        <span class="role-badge">{{ auth.currentRole }}</span>
        <button class="link" @click="auth.signOut().then(() => $router.push('/login'))">Sign out</button>
      </div>
    </header>
    <div class="body">
      <nav class="sidenav">
        <template v-for="group in navGroups" :key="group.label">
          <div class="nav-group">{{ group.label }}</div>
          <router-link v-for="link in group.links" :key="link.to" :to="link.to">{{ link.label }}</router-link>
        </template>
      </nav>
      <main class="content">
        <router-view />
      </main>
    </div>
  </div>
</template>

<style>
:root {
  color-scheme: light;
  --ink: #1b2430;
  --muted: #64748b;
  --line: #e2e8f0;
  --accent: #2563eb;
  --bg: #f8fafc;
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
}
body {
  margin: 0;
  background: var(--bg);
  color: var(--ink);
}
.shell {
  display: flex;
  flex-direction: column;
  min-height: 100vh;
}
.topbar {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 0.75rem 1.5rem;
  background: white;
  border-bottom: 1px solid var(--line);
}
.brand {
  font-weight: 700;
}
.brand span {
  font-weight: 400;
  color: var(--muted);
  font-size: 0.85em;
}
.context {
  display: flex;
  align-items: center;
  gap: 0.75rem;
  font-size: 0.9em;
}
.role-badge {
  background: #eef2ff;
  color: var(--accent);
  padding: 0.15rem 0.6rem;
  border-radius: 999px;
  font-weight: 600;
}
.link {
  background: none;
  border: none;
  color: var(--accent);
  cursor: pointer;
}
.body {
  display: flex;
  flex: 1;
}
.sidenav {
  width: 220px;
  padding: 1rem;
  display: flex;
  flex-direction: column;
  gap: 0.25rem;
  border-right: 1px solid var(--line);
  background: white;
}
.sidenav a {
  padding: 0.5rem 0.75rem;
  border-radius: 6px;
  color: var(--ink);
  text-decoration: none;
}
.nav-group {
  font-size: 0.7rem;
  font-weight: 700;
  letter-spacing: 0.06em;
  text-transform: uppercase;
  color: var(--muted);
  padding: 0.75rem 0.75rem 0.25rem;
}
.nav-group:first-child {
  padding-top: 0;
}
.sidenav a.router-link-active {
  background: #eef2ff;
  color: var(--accent);
  font-weight: 600;
}
.content {
  flex: 1;
  padding: 1.5rem;
}
table {
  width: 100%;
  border-collapse: collapse;
  background: white;
  border: 1px solid var(--line);
  border-radius: 8px;
  overflow: hidden;
}
th, td {
  text-align: left;
  padding: 0.6rem 0.8rem;
  border-bottom: 1px solid var(--line);
  font-size: 0.9rem;
}
th {
  color: var(--muted);
  font-weight: 600;
  background: #f1f5f9;
}
button.primary {
  background: var(--accent);
  color: white;
  border: none;
  padding: 0.45rem 0.9rem;
  border-radius: 6px;
  cursor: pointer;
  font-weight: 600;
}
button.primary:disabled {
  opacity: 0.5;
  cursor: not-allowed;
}
button.danger {
  background: #dc2626;
}
.card {
  background: white;
  border: 1px solid var(--line);
  border-radius: 8px;
  padding: 1rem 1.25rem;
  margin-bottom: 1rem;
}
.status {
  padding: 0.1rem 0.5rem;
  border-radius: 999px;
  font-size: 0.75rem;
  font-weight: 600;
  background: #f1f5f9;
}
.status.warn {
  background: #fef3c7;
  color: #92400e;
}
.status.ok {
  background: #dcfce7;
  color: #166534;
}
.status.danger {
  background: #fee2e2;
  color: #991b1b;
}
.error-banner {
  background: #fee2e2;
  color: #991b1b;
  padding: 0.6rem 1rem;
  border-radius: 6px;
  margin-bottom: 1rem;
}
</style>
