// Mirrors process-gpt-vue3's src/main.ts setupTenant() exactly, so wms-frontend
// resolves the same tenant_id ProcessGPT's own gateway (ForwardHostHeaderFilter)
// validates against the session JWT's app_metadata.tenant_id. Do not diverge from
// this algorithm — a different subdomain-parsing rule here than in process-gpt-vue3
// would make wms-frontend disagree with the gateway about which tenant a request is for.
export function getTenantIdFromHost(): string {
  const host = window.location.hostname
  const subdomain = host.split('.')[0]

  if (subdomain === 'www' || subdomain === 'process-gpt') return ''
  if (host.includes('localhost') || host.includes('192.168') || host.includes('127.0.0.1')) return 'localhost'
  return subdomain
}
