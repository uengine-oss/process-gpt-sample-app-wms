# process-gpt-sample-app-wms

Sample WMS / light procurement app for ProcessGPT — replaces the Odoo MCP
integration for the shortage → RFQ → HITL approval → PO → receiving →
quality → scrap/putaway flow. See `docs/` for the openspec-derived contracts
this implements (`openspec/changes/supabase-wms-erp-replacement` in the main
`process-gpt` repo has the full proposal/design/spec set this is scoped
from).

This repo is meant to be vendored into the main `process-gpt` repo as a git
submodule at `services/sample-app-wms`, matching how `services/frontend`,
`services/deepagents`, etc. are vendored (see `.gitmodules` there).

## Scope

This is a **demo-first vertical slice**, not the full 55-task enterprise
backlog in `tasks.md`. It proves the BPMN flow end-to-end with a small,
real (not mocked) stack: Supabase Postgres + Auth + RLS, a FastMCP server,
and a Vue 3 frontend. See `docs/01-baseline-scope.md` for what's in vs.
out, and the bottom of the repo-root `tasks.md`'s copy for what's deferred.

## Layout

- `supabase/` — the `wms` Postgres schema, RLS policies, and the 9 command
  RPCs, plus demo seed data (2 tenants, 1 warehouse each, one user per role).
  `20260727_wcs_equipment_control.sql` adds the WCS equipment-control
  contract (equipment registry, command dispatch, status/event feed, faults)
  on top — see `openspec/specs/wms_wcs-equipment-control/e2e/` for its
  simulator and verification runs, and
  `openspec/specs/wms_wcs-equipment-control/docs/` for the Korean operator
  manual built from the Playwright screenshots.
  `20260728_wes_material_flow_control.sql` (dispatch waves + work orders) and
  `20260729_wcs_sortation_logic.sql` (per-sorter tuning profiles, the
  `DIVERT`/`SET_SPEED` payload contract and automatic `SORTATION_JAM`
  escalation) and `20260730_wcs_bottleneck_routing.sql` (threshold-based
  bottleneck detection over the command queue and fault log, manual routing
  exclusions, and the takeover of the work-order candidate-selection step)
  follow the same layout — each has its own `e2e/` verification bundle and
  `docs/` manual under `openspec/specs/`.
- `mcp/` — `wms-mcp`, a FastMCP server (same pattern as `services/office-mcp`)
  exposing the RPCs as MCP tools for ProcessGPT to call.
- `frontend/` — `wms-frontend`, a Vue 3 + Vite + TypeScript app with one
  screen per stage of the flow (Overview, Replenishment, Purchase Orders,
  Receiving, Quality) plus the automation screens (WCS Equipment, WCS Monitor,
  WCS Sortation, WCS Routing, WES Dispatch).
- `docs/` — the task-1 baseline/contracts artifacts this slice was built from.

## Running locally

```bash
# 1. Start Supabase (schema + RLS + RPCs + seed data)
cd supabase && supabase start
# copy the printed anon key into frontend/.env and mcp/.env

# 2. Frontend
cd frontend && npm install && cp .env.example .env  # fill VITE_SUPABASE_ANON_KEY
npm run dev   # http://localhost:5273

# 3. wms-mcp
cd mcp && pip install -r requirements.txt && cp .env.example .env  # fill SUPABASE_ANON_KEY
python main.py   # http://localhost:8199

# 4. ProcessGPT integration (ProcessGPT local stack must already be running)
python scripts/install_processgpt_integration.py
# Process definition: wms_replenishment_process
# ProcessGPT polling container reaches MCP at host.docker.internal:8199/mcp

# 5. WMS E2E
cd frontend && npx playwright install chromium && npm run test:e2e
```

Demo logins (password `Demo1234!` for all): `admin-a@demo.local`,
`buyer-a@demo.local`, `approver-a@demo.local`, `inbound-a@demo.local`,
`quality-a@demo.local`, `wh-manager-a@demo.local`, `wcs-operator-a@demo.local`,
`wcs-gateway-a@demo.local` (equipment-side service identity),
`auditor-a@demo.local` (read-only AUDITOR — the only login that reaches
`/operations/audit-log`, and the only one with no write role anywhere),
`admin-b@demo.local` (tenant B, for the cross-tenant RLS-isolation demo).
