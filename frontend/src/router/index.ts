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
    { path: '/quality/inspections', name: 'quality', component: () => import('@/views/QualityView.vue') },
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
  return true
})
