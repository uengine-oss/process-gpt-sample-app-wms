import { createRouter, createWebHistory } from 'vue-router'
import { useAuthStore } from '@/stores/auth'

export const router = createRouter({
  history: createWebHistory(),
  routes: [
    { path: '/login', name: 'login', component: () => import('@/views/LoginView.vue') },
    { path: '/', redirect: '/overview' },
    { path: '/overview', name: 'overview', component: () => import('@/views/OverviewView.vue') },
    {
      path: '/replenishment',
      name: 'replenishment',
      component: () => import('@/views/ReplenishmentView.vue'),
    },
    {
      path: '/procurement/purchase-orders',
      name: 'purchase-orders',
      component: () => import('@/views/PurchaseOrdersView.vue'),
    },
    { path: '/inbound/receipts', name: 'receiving', component: () => import('@/views/ReceivingView.vue') },
    {
      path: '/inbound/dock-schedule',
      name: 'dock-schedule',
      component: () => import('@/views/DockScheduleView.vue'),
    },
    { path: '/quality/inspections', name: 'quality', component: () => import('@/views/QualityView.vue') },
    { path: '/labor', name: 'labor', component: () => import('@/views/LaborView.vue') },
    { path: '/slotting', name: 'slotting', component: () => import('@/views/SlottingView.vue') },
    {
      path: '/agent/decisions',
      name: 'agent-decisions',
      component: () => import('@/views/AgentDecisionsView.vue'),
    },
    {
      // WMS_ADMIN / AUDITOR only. The guard below bounces everyone else back to
      // the overview; the view itself also refuses, and the RPCs refuse under
      // that. Three layers because only the last one is a control — the other
      // two just keep a dead-end page out of an operator's way.
      path: '/operations/audit-log',
      name: 'audit-log',
      meta: { roles: ['WMS_ADMIN', 'AUDITOR'] },
      component: () => import('@/views/AuditLogView.vue'),
    },
    {
      path: '/wcs/equipment',
      name: 'wcs-equipment',
      component: () => import('@/views/WcsEquipmentView.vue'),
    },
    { path: '/wcs/monitor', name: 'wcs-monitor', component: () => import('@/views/WcsMonitorView.vue') },
    {
      path: '/wcs/sortation',
      name: 'wcs-sortation',
      component: () => import('@/views/WcsSortationView.vue'),
    },
    {
      path: '/wcs/routing',
      name: 'wcs-routing',
      component: () => import('@/views/WcsRoutingView.vue'),
    },
    {
      path: '/wcs/sequential-dispatch',
      name: 'wcs-sequential-dispatch',
      component: () => import('@/views/WcsSequentialDispatchView.vue'),
    },
    {
      path: '/wcs/simulation',
      name: 'wcs-simulation',
      component: () => import('@/views/WcsSimulationView.vue'),
    },
    {
      path: '/wes/dispatch',
      name: 'wes-dispatch',
      component: () => import('@/views/WesDispatchView.vue'),
    },
  ],
})

router.beforeEach(async (to) => {
  const auth = useAuthStore()
  if (!auth.isSignedIn) {
    await auth.restoreSession()
  }
  if (to.name !== 'login' && !auth.isSignedIn) {
    return { name: 'login' }
  }
  const allowed = to.meta?.roles as string[] | undefined
  if (allowed && !allowed.includes(auth.currentRole ?? '')) {
    return { name: 'overview' }
  }
  return true
})
