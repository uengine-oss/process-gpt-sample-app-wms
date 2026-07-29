import { fileURLToPath, URL } from 'node:url'
import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'

export default defineConfig({
  // Standalone local dev (README) serves at root, so this defaults to '/'.
  // The gateway (process-gpt-vue3) reaches this app at <tenant>.process-gpt.io/wms
  // and strips the /wms prefix before forwarding (same RewritePath convention as
  // its other routes) — but the browser still resolves root-relative asset/script
  // URLs against the page's own address (/wms/...), so the build that ships behind
  // the gateway must set VITE_BASE_PATH=/wms/ (see frontend/Dockerfile and
  // docs/05-deployment.md) or every asset request 404s / gets routed to whatever
  // else the gateway's catch-all route serves at root.
  base: process.env.VITE_BASE_PATH || '/',
  plugins: [vue()],
  resolve: {
    alias: {
      '@': fileURLToPath(new URL('./src', import.meta.url)),
    },
  },
  server: {
    port: 5273,
  },
})
