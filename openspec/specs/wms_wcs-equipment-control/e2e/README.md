# `wms_wcs-equipment-control` — E2E verification

Software simulator for the WCS equipment-control contract
(`supabase/migrations/20260727_wcs_equipment_control.sql`). No real PLC or
hardware is involved: the script authenticates as the seeded demo identities
and drives the contract's RPCs directly, which is exactly what a real
WCS/PLC gateway would do (design.md "Risks / Trade-offs").

## Files

| File | What it is |
|---|---|
| `simulator.sql` | psql state-machine simulator + negative-path assertions |
| `simulator-run.txt` | captured output of a clean run against a freshly seeded DB |
| `mcp_roundtrip.py` | same flow driven through the MCP tool layer (in-process `fastmcp.Client`) |
| `mcp_roundtrip-run.txt` | captured output of a clean MCP round-trip |
| `playwright-run.txt` | captured output of the browser E2E run |
| `screenshots/` | 11 full-page screenshots captured during that run |

The browser spec itself lives with the app it drives, at
`frontend/playwright/e2e/wcs-equipment-flow.spec.ts` (same directory as the
existing `wms-flow.spec.ts` — Playwright's `testDir` is fixed by
`frontend/playwright.config.ts`). Its screenshots and run log land here.

## Running it

```bash
cd supabase && supabase start          # if not already running
supabase db reset                      # migrations + seed
docker exec -i supabase_db_process-gpt-sample-app-wms \
  psql -U postgres -d postgres -q < ../openspec/specs/wms_wcs-equipment-control/e2e/simulator.sql
```

The script truncates only the four WCS tables (and their audit/idempotency
rows) at the top, so it is safely re-runnable without a full `db reset`.

It impersonates demo users by setting `request.jwt.claims` and
`set role authenticated`, so `auth.uid()`, `wms.current_warehouse_ids()`
and `wms.has_role()` behave exactly as they do for a real Supabase session.

## What it covers

**Happy path (simulator state machine)** — register `AGV-07` → gateway
reports `OFFLINE → IDLE` → operator dispatches `MOVE` → gateway reports
`ACKNOWLEDGED → IN_PROGRESS → COMPLETED` → equipment derives back to `IDLE`.

**Fault path** — dispatch `LOAD` to `SRM-02` (linked to a `receipt`) →
gateway reports `IN_PROGRESS` → gateway raises `MOTOR_OVERHEAT`/`CRITICAL`
→ the in-flight command flips to `FAILED` with `fault_id` set and the
equipment goes to `FAULT` → new dispatches are rejected → `WCS_OPERATOR`
resolves with a note → equipment returns to `IDLE`.

**Cancel path** — dispatch → cancel (`PENDING → CANCELLED`, equipment back
to `IDLE`); cancelling a terminal command is rejected.

**Negative paths** — every `CONFLICT:` / `FORBIDDEN:` / `INVALID:` branch:
duplicate `equipment_code`, unknown `equipment_type` / `command_type` /
status value, bad `severity`, stale `expected_version` on equipment / command
/ fault, missing `resolution_note`, terminal-command reporting, unknown
command id, dispatch to a `FAULT` equipment, and role/tenant refusals
(`QUALITY_INSPECTOR` cannot register, `PROCESS_AGENT` cannot report status,
`WCS_GATEWAY` cannot resolve faults, tenant B cannot touch tenant A).

**Idempotency** — the same `idempotency_key` replayed on
`wms_register_equipment` and `wms_dispatch_equipment_command` returns the
identical response and creates no second row.

**RLS / grants** — tenant B sees 0 rows in all four tables; direct
`INSERT`/`UPDATE`/`DELETE` as `authenticated` is refused
("permission denied"); `information_schema.role_table_grants` confirms
`SELECT` is the only privilege granted, and only to `authenticated`.

## MCP layer

```bash
cd mcp && .venv/bin/python \
  ../openspec/specs/wms_wcs-equipment-control/e2e/mcp_roundtrip.py
```

`mcp_roundtrip.py` re-runs the happy path, the fault path and the main
refusals through `fastmcp.Client`, asserting on the structured tool results
(`{"result": "ok", document_id, status, version, links, next_actions}` and
`{"result": "error", error_kind, http_status_equivalent}`). It picks a random
`MCP-AGV-xxxxxx` equipment code so it is re-runnable, and additionally proves
the two-identity split works over MCP: `report_equipment_status`,
`report_command_result` and `raise_equipment_fault` succeed (signed in as
`WCS_GATEWAY`) while `register_equipment` and `resolve_equipment_fault`
return `FORBIDDEN` for the `PROCESS_AGENT` login.

## Browser layer (Playwright)

```bash
cd frontend && npx playwright test wcs-equipment-flow.spec.ts
```

`wcs-equipment-flow.spec.ts` drives the two real Vue screens
(`/wcs/equipment`, `/wcs/monitor`) end to end. Because `WCS_GATEWAY` is a
service identity nobody logs into the frontend as, the equipment-side steps
are executed off-UI through `psql` — the same calls a real PLC/WCS bridge
would make — and the UI is then re-checked:

1. UI — `wh-manager-a@demo.local` (`WAREHOUSE_MANAGER`) registers `AGV-07`
   (`OFFLINE`).
2. Off-UI — the gateway reports `IDLE` (equipment boots).
3. UI — the manager dispatches `MOVE`; equipment goes `RUNNING`, command
   `PENDING`.
4. Off-UI — the gateway reports `ACKNOWLEDGED → IN_PROGRESS → COMPLETED`.
5. UI — the monitor shows `COMMAND_COMPLETED` and the equipment derived back
   to `IDLE`.
6. UI + off-UI — dispatch again, gateway raises `MOTOR_OVERHEAT`; the UI shows
   `FAULT`, the in-flight command as `COMMAND_FAILED`, and dispatch blocked.
7. UI — `wcs-operator-a@demo.local` resolves the fault with a note; equipment
   returns to `IDLE` and `FAULT_CLEARED` appears in the feed.

A second test asserts the registry form is hidden from `WCS_OPERATOR` and that
every write in the flow left an audit event.

Screenshots from this run are the source images for the operator manual in
`openspec/specs/wms_wcs-equipment-control/docs/`.

**Audit + event feed** — all seven write RPCs are shown emitting
`wms.audit_events` with the right `command`/`entity_type`, fault resolution
carries `before.status='OPEN'` / `after.status='RESOLVED'`, the linked
`receipt` gets its own audit row, and the 20-event
`wms.equipment_status_events` feed is printed in `seq` order.
