#!/bin/sh
set -eu

cat <<EOF > /usr/share/nginx/html/env.js
window._env_ = {
  VITE_SUPABASE_URL: "${VITE_SUPABASE_URL:-}",
  VITE_SUPABASE_ANON_KEY: "${VITE_SUPABASE_ANON_KEY:-}"
};
EOF
