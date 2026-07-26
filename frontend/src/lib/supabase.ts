import { createClient } from '@supabase/supabase-js'

// Runtime env override pattern matches services/frontend/src/main.ts, so the
// same docker image can be reconfigured per-environment without a rebuild.
const supabaseUrl = window._env_?.VITE_SUPABASE_URL || import.meta.env.VITE_SUPABASE_URL
const supabaseAnonKey = window._env_?.VITE_SUPABASE_ANON_KEY || import.meta.env.VITE_SUPABASE_ANON_KEY

export const supabase = createClient(supabaseUrl, supabaseAnonKey, {
  db: { schema: 'wms' },
})
