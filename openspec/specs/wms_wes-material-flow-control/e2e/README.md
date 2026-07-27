# `wms_wes-material-flow-control` — E2E verification

Verification artifacts for the WES/MFS material-flow-control contract
(`supabase/migrations/20260728_wes_material_flow_control.sql`), the middleware
between a WMS-side intent (a receipt awaiting putaway) and the equipment
commands defined by `wms_wcs-equipment-control`.

No real PLC or hardware is involved. The equipment side is driven by the same
software-simulator idea as area 1: the scripts authenticate as the seeded demo
identities (`request.jwt.claims` + `set role authenticated`) and call the
contract's RPCs directly, which is exactly what a real WCS/PLC gateway would
do.

## Files

| File | What it is |
|---|---|
| `simulator.sql` | psql state-machine simulator + negative-path assertions |
| `simulator-run.txt` | captured output of a clean run against a freshly seeded DB |
| `mcp_roundtrip.py` | same flow driven through the MCP tool layer (in-process `fastmcp.Client`) |
| `mcp_roundtrip-run.txt` | captured output of a clean MCP round-trip |
| `playwright-run.txt` | captured output of the browser E2E run |
| `screenshots/` | 9 full-page screenshots captured during that run |

The browser spec itself lives with the app it drives, at
`frontend/playwright/e2e/wes-dispatch-flow.spec.ts` (Playwright's `testDir` is
fixed by `frontend/playwright.config.ts`). Its screenshots and run log land
here.

## Running it

```bash
cd supabase && supabase start          # if not already running
supabase db reset                      # 3 migrations + seed
docker exec -i supabase_db_process-gpt-sample-app-wms \
  psql -U postgres -d postgres -q < ../openspec/specs/wms_wes-material-flow-control/e2e/simulator.sql
```

The script truncates only `wms.work_orders` / `wms.dispatch_waves` and the four
WCS tables (plus their audit/idempotency rows) at the top, so it is safely
re-runnable without a full `db reset`. It creates its own receipt fixture
through the real inbound RPCs (`wms_create_rfq` → approval → `wms_confirm_purchase_order`)
because a work order must reference a real `wms.receipts` row.

## What it covers

**Happy path (WAVELESS)** — register a work order with
`dispatch_mode='WAVELESS'` → the middleware picks an idle `AGV` in `ZONE-B`,
calls `wms_dispatch_equipment_command` with
`linked_entity_type='work_order'` → the gateway reports
`ACKNOWLEDGED → IN_PROGRESS → COMPLETED` → the propagation trigger moves the
work order to `COMPLETED` and writes a `wms_propagate_command_result` audit row
with `before.status='DISPATCHED'` / `after.status='COMPLETED'`.
The referenced `wms.receipts` row is asserted **unchanged** — that boundary is
a deliberate Non-Goal (design.md).

**Flow balancing (design.md D5)** — with two identical idle AGVs in the same
zone, the one with fewer recently-`COMPLETED` commands is chosen; an AGV with
an outstanding command is excluded; an idle AGV in a different zone
(`ZONE-Z`) is never picked for `ZONE-B` work; an `equipment_type` with no
registered equipment at all (`ROBOT_CELL`) leaves the work order `QUEUED` with
a `NO_EQUIPMENT_AVAILABLE` warning rather than raising an error.

**Wave path** — open a wave → queue 3 work orders (all stay `QUEUED`, no
commands created) → release with only 2 idle AGVs → `dispatched_count=2`,
`queued_count=1` and a shortage warning; re-releasing a `RELEASED` wave, a
stale `expected_version`, adding a work order to a `RELEASED` or unknown wave,
and `dispatch_mode='WAVE'` without a `wave_id` are all refused.

**Retry** — a `QUEUED` work order becomes dispatchable once equipment frees up;
retrying a `DISPATCHED` one is `INVALID`; a stale version is `CONFLICT`.

**Cancellation** — a `QUEUED` work order cancels outright; a `DISPATCHED` one
also cascades into `wms_cancel_equipment_command` so the linked command becomes
`CANCELLED` and the equipment returns to `IDLE`; a terminal work order is
`INVALID`; a stale version is `CONFLICT`.

**FAILED propagation** — a command reported `FAILED` moves its work order to
`FAILED` with a reason.

**Unrelated commands** — a command carrying `linked_entity_type='receipt'`
(not `'work_order'`) reaching `COMPLETED` updates no work order and adds no
propagation audit row.

**Roles / tenants** — `QUALITY_INSPECTOR` is refused on every write;
`PROCESS_AGENT` and `WCS_OPERATOR` are allowed; tenant B sees 0 rows in both
new tables and gets `FORBIDDEN` on cancel/read of tenant A data.

**Idempotency** — replaying the same `idempotency_key` on
`wms_create_work_order` and `wms_open_dispatch_wave` returns the identical
response and creates no second row.

**RLS / grants** — `information_schema.role_table_grants` confirms `SELECT` is
the only privilege on `wms.work_orders` / `wms.dispatch_waves`, and only to
`authenticated`; direct `INSERT`/`UPDATE`/`DELETE` as `authenticated` is
"permission denied".

**Audit coverage** — all six write RPCs plus the propagation trigger emit
`wms.audit_events` rows with the right `command` / `entity_type`
(`work_order` or `dispatch_wave`).

## D3 role-set check (tasks.md 3.9) — documented deviation

design.md D3 requires this contract's write RPCs to allow **exactly** the roles
that may call `wms_dispatch_equipment_command`, so that a caller can never
"register a work order successfully but have the inner dispatch fail with
FORBIDDEN".

The shipped area-1 RPC allows `WAREHOUSE_MANAGER`, `WCS_OPERATOR`,
`PROCESS_AGENT` — and, unlike every other RPC in that migration, **not**
`WMS_ADMIN`. design.md/spec.md's role table for *this* contract lists
`WMS_ADMIN` as a fourth role. Honouring that list would recreate exactly the
partial failure D3 exists to prevent, so this implementation uses the
dispatch-capable set instead and leaves `WMS_ADMIN` out.

`simulator.sql` §7 reproduces the mismatch explicitly:

```
admin_dispatch_equipment_command | ERR  FORBIDDEN: role cannot dispatch equipment commands
admin_open_dispatch_wave         | ERR  FORBIDDEN: role cannot open dispatch waves
```

and prints both contracts' role lists side by side, extracted from
`pg_get_functiondef`:

```
 wms_cancel_equipment_command   | PROCESS_AGENT,WAREHOUSE_MANAGER,WCS_OPERATOR,WMS_ADMIN
 wms_cancel_work_order          | PROCESS_AGENT,WAREHOUSE_MANAGER,WCS_OPERATOR
 wms_create_work_order          | PROCESS_AGENT,WAREHOUSE_MANAGER,WCS_OPERATOR
 wms_dispatch_equipment_command | PROCESS_AGENT,WAREHOUSE_MANAGER,WCS_OPERATOR
 wms_open_dispatch_wave         | PROCESS_AGENT,WAREHOUSE_MANAGER,WCS_OPERATOR
 wms_release_dispatch_wave      | PROCESS_AGENT,WAREHOUSE_MANAGER,WCS_OPERATOR
 wms_retry_work_order_dispatch  | PROCESS_AGENT,WAREHOUSE_MANAGER,WCS_OPERATOR
```

If a follow-up change adds `WMS_ADMIN` to `wms_dispatch_equipment_command`, add
it to all six RPCs here in the same change.

## MCP layer

```bash
cd mcp && .venv/bin/python \
  ../openspec/specs/wms_wes-material-flow-control/e2e/mcp_roundtrip.py
```

`mcp_roundtrip.py` re-runs the wave path, the propagation, the retry, the
cancel cascade and the main refusals through `fastmcp.Client`, asserting on the
structured tool results (`{"result": "ok", document_id, status, version, links,
warnings, next_actions}` and `{"result": "error", error_kind,
http_status_equivalent}`). It uses a random `MCP-WES-xxxxxx-A/B` equipment pair
in its own zone so it is re-runnable, and it proves that everything in this
contract is callable by `PROCESS_AGENT` (design.md D4 — no new service role);
only the equipment-side feedback step reuses area 1's `report_command_result`,
which signs in as `WCS_GATEWAY` internally.

## Browser layer (Playwright)

```bash
cd frontend && npx playwright test wes-dispatch-flow.spec.ts
```

`wes-dispatch-flow.spec.ts` drives the real Vue screen `/wes/dispatch` end to
end. Equipment registration and the inbound flow belong to other specs, so the
fixture (one receipt, two idle AGVs) is created off-UI; the gateway steps are
executed off-UI through `psql` for the same reason as in area 1 — nobody logs
into the frontend as `WCS_GATEWAY`.

1. UI — `wh-manager-a@demo.local` (`WAREHOUSE_MANAGER`) opens a dispatch wave.
2. UI — three `WAVE`-mode work orders are queued; all `QUEUED`, no commands.
3. UI — the wave is released: 2 `DISPATCHED` across *both* AGVs (flow
   balancing), 1 `QUEUED` with the `NO_EQUIPMENT_AVAILABLE` notice.
4. Off-UI — the gateway reports `ACKNOWLEDGED → IN_PROGRESS → COMPLETED`.
5. UI — the work order has auto-transitioned to `COMPLETED`; the receipt is
   asserted still `EXPECTED`.
6. UI — `Retry` sends the leftover work order to the now-free AGV.
7. Off-UI — the other AGV reports `FAILED`; UI shows the work order `FAILED`.
8. UI — cancelling the remaining `DISPATCHED` work order also cancels its
   equipment command.

A second test signs in as `quality-a@demo.local` and asserts the operating
cards/actions are hidden while the board is still readable, and that the audit
trail contains all six write commands plus both
`DISPATCHED->COMPLETED` and `DISPATCHED->FAILED` propagation rows.

Screenshots from this run are the source images for the operator manual in
`openspec/specs/wms_wes-material-flow-control/docs/`.

## Known open integration point (design.md Non-Goals, tasks.md 6.3)

A work order reaching `COMPLETED` does **not** call `wms_create_putaway_tasks`
or otherwise transition `wms.receipts`. Nothing in this repository closes that
loop today — it needs a follow-up change (ProcessGPT orchestration or a
dedicated integration spec) that observes work-order completion and drives the
upper entity's next transition. This is verified rather than hidden: both
`simulator.sql` §1 and the Playwright spec assert the receipt stays `EXPECTED`
after its work order completes.
