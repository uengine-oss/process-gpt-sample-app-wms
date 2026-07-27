# `wms_wcs-bottleneck-routing` — E2E verification

Verification artifacts for the intelligent-routing / bottleneck-relief contract
(`supabase/migrations/20260730_wcs_bottleneck_routing.sql`): the live
load/health views over area 1's command queue and fault log, the two-threshold
bottleneck verdict, the manual force-exclusion lever, and — the part that
actually matters — the takeover of area 2's candidate-selection step so a new
work order really does land somewhere else.

No real PLC or hardware is involved. The equipment side is driven by the same
software-simulator idea as areas 1–3: the scripts authenticate as the seeded
demo identities (`request.jwt.claims` + `set role authenticated`) and call the
contract's RPCs directly, which is exactly what a real WCS/PLC gateway would do.

## Files

| File | What it is |
|---|---|
| `simulator.sql` | psql simulator + negative-path assertions, including the area-2 integration through the real dispatch RPC |
| `simulator-run.txt` | captured output of a clean run against a freshly seeded DB |
| `mcp_roundtrip.py` | same contract driven through the MCP tool layer (in-process `fastmcp.Client`) |
| `mcp_roundtrip-run.txt` | captured output of a clean MCP round-trip |
| `playwright-run.txt` | captured output of the **full** browser E2E suite (9 tests, all specs) |
| `screenshots/` | 13 full-page screenshots captured during that run |

The browser spec itself lives with the app it drives, at
`frontend/playwright/e2e/wcs-routing-flow.spec.ts` (Playwright's `testDir` is
fixed by `frontend/playwright.config.ts`). Its screenshots and run log land
here.

## Running it

```bash
cd supabase && supabase start          # if not already running
supabase db reset                      # 5 migrations + seed
docker exec -i supabase_db_process-gpt-sample-app-wms \
  psql -U postgres -d postgres -q < ../openspec/specs/wms_wcs-bottleneck-routing/e2e/simulator.sql
```

The script truncates only this contract's two tables, the WES tables,
`wms.sortation_profiles` and the four WCS tables (plus their audit/idempotency
rows) at the top, so it is safely re-runnable without a full `db reset`.

## What it covers

**Live signals with no policy** — every machine reports `queue_depth`,
`recent_completed_count`, `recent_fault_count` and the system default
thresholds (3 / 1), with `is_bottleneck=false` and an empty
`bottleneck_reasons`.

**Threshold policy** — `AGV` gets queue 3 / fault 2; a duplicate
`(warehouse, equipment_type)`, an unknown type, and a non-positive threshold are
each refused with a distinct `INVALID:`; another warehouse is `FORBIDDEN`.
`WCS_OPERATOR`, `QUALITY_INSPECTOR` and a tenant-B admin all get `FORBIDDEN`,
and tenant B sees 0 policy rows. Update: `WMS_ADMIN` widens the queue threshold
with the right `expected_version`; a stale version is `CONFLICT`; a negative
threshold and an all-null update are `INVALID`.

**Bottleneck by queue depth** — three commands stacked on one AGV push
`queue_depth` to 3 and produce `QUEUE_DEPTH_EXCEEDED`. The same section prints
the machine's `routable` flag (`false`) to make deviation 2 below concrete.

**Bottleneck by fault frequency** — one fault on an AGV whose policy threshold
is 2 is **not** enough; a second fault inside the 30-minute window tips it over
and produces `FAULT_FREQUENCY_EXCEEDED`. Both faults are resolved, so the
machine is `IDLE` and command-free — a perfectly legal candidate that the
contract merely prefers not to use.

**Selection hook (`wms.wcs_select_available_equipment`)** — four states in
sequence, each asserted by calling the function directly:

| candidates | result |
|---|---|
| clean, flagged, clean | the oldest clean one (area 2's original tie-break) |
| flagged + clean (one clean force-excluded) | the clean one |
| flagged only (both clean ones force-excluded) | the flagged one — a flag is a preference |
| all three force-excluded | `null` — an exclusion is a veto |

**Manual exclusion RPC** — duplicate `ACTIVE` exclusion, a blank `reason` and an
unknown equipment id are each `INVALID`; excluding a busy machine succeeds but
returns `IN_FLIGHT_COMMANDS_NOT_CANCELLED`; `QUALITY_INSPECTOR` and a tenant-B
admin get `FORBIDDEN`. Clearing: stale version is `CONFLICT`, the right version
sets `CLEARED` + `cleared_by` + `cleared_at`, a second clear is `INVALID`, and
the machine is back in the candidate pool on the very next call.

**Area-2 integration (tasks.md 6.2)** — the same four scenarios again, but
through `wms_create_work_order` (WAVELESS) and `wms_retry_work_order_dispatch`
instead of the function: all candidates excluded → `QUEUED` +
`NO_EQUIPMENT_AVAILABLE`; clean and flagged both free → dispatched to the clean
one; only the flagged one free → dispatched to it; nothing free → `QUEUED`
again. Zero commands are ever written for an excluded machine.

**Read RPC** — `wms_get_equipment_routing_status` returns per-machine signals,
resolved thresholds, `threshold_source`, the verdict, its reasons, the active
override and a `routable` flag, plus the warehouse's policy list. Tenant B gets
`FORBIDDEN` on warehouse A and sees 0 rows through the views.

**Roles / RLS / grants** — `information_schema.role_table_grants` confirms
`SELECT` is the only privilege on both tables and both views and only to
`authenticated`; direct `INSERT`/`UPDATE`/`DELETE` as `authenticated` is
"permission denied for table …"; `wms.wcs_select_available_equipment` answers
"permission denied for function" and its ACL is `postgres=X/postgres` (the
implicit `PUBLIC` EXECUTE grant is revoked in the migration).

**Idempotency** — replaying the same `idempotency_key` on
`wms_exclude_equipment_from_routing` returns the identical response and creates
no second row.

**Audit coverage** — all four write RPCs appear in `wms.audit_events` under
`entity_type in ('wcs_routing_policy','wcs_routing_override')`; the exclusion
row carries `after.status='ACTIVE'` and the reason, the clearing row carries
`ACTIVE → CLEARED`.

## Documented deviations found while implementing

### 1. Area 2's selection step is one whole-row helper, not three inline queries

design.md assumed area 2's three dispatch RPCs each ran their own inline
candidate query, and specified the takeover function as
`wms.wcs_select_available_equipment(tenant, warehouse, equipment_type,
zone_code) -> uuid`.

The **shipped** area 2 does not work that way. All three RPCs
(`wms_create_work_order` WAVELESS path, `wms_release_dispatch_wave`,
`wms_retry_work_order_dispatch`) funnel through `wms._wms_try_dispatch_work_order`,
which calls exactly one selection helper:

```sql
wms._wms_pick_equipment_for_work_order(
  p_work_order wms.work_orders,
  p_recent_window interval default interval '1 hour'
) returns wms.equipment
```

— a whole-row parameter, a whole-row return, and a tie-break window the *caller*
owns. So the integration is done the other way round from the draft:

- `wms.wcs_select_available_equipment` is still defined with design.md's
  documented signature, plus a **defaulted 5th parameter** carrying area 2's
  recent window (so the documented 4-argument call form still compiles);
- `wms._wms_pick_equipment_for_work_order` is then `create or replace`d **from
  this migration's file** into a thin adapter that delegates to it and re-reads
  the chosen row. `20260728_wes_material_flow_control.sql` itself is untouched,
  its signature and return type are unchanged, and its "all-null row means
  nothing available" contract is preserved.

Because area 2 has a single choke point, all three of its dispatch paths pick up
bottleneck avoidance at once — the outcome D5 wanted, reached through a
different door. If area 2 ever reshapes that helper, this replacement has to be
re-based on it (noted in the migration header as DEVIATION 1). This is the same
pattern area 3 used for `wms_dispatch_equipment_command`.

### 2. `QUEUE_DEPTH_EXCEEDED` cannot influence selection today

design.md D3 defines two bottleneck reasons and D5 assumes both of them bias
candidate selection. Against the shipped area 2 only one of them can.

Area 2's candidate filter already requires

```sql
not exists (select 1 from wms.equipment_commands c
            where c.equipment_id = e.id
              and c.status in ('PENDING','ACKNOWLEDGED','IN_PROGRESS'))
```

which is *exactly* the predicate `queue_depth` counts. Every candidate therefore
has `queue_depth = 0` by construction — and area 1's
`_wms_sync_equipment_activity` has already moved such a machine to `RUNNING`,
which fails the `status='IDLE'` filter as well. `QUEUE_DEPTH_EXCEEDED` is
structurally unreachable inside the candidate set;
`FAULT_FREQUENCY_EXCEEDED` — "this machine keeps breaking, prefer another one" —
is what actually drives soft avoidance.

The reason is kept rather than dropped, because it is not dead:

- it is what the monitoring answer (`wms_get_equipment_routing_status`,
  `/wcs/routing`) uses to tell an operator *why* work is piling up on a machine
  that is not currently a candidate;
- it becomes selection-relevant the moment a follow-up change relaxes area 2's
  zero-queue rule (e.g. "a machine may hold up to N queued commands").

`simulator.sql` §4 reproduces it explicitly:

```
 equipment_code | status  | queue_depth | q_thr | is_bottleneck |   bottleneck_reasons
 RTE-AGV-09     | RUNNING |           3 |     3 | t             | {QUEUE_DEPTH_EXCEEDED}

 RTE-AGV-09 would be routable? | f
```

and the DOCX manual's "알아 두면 좋은 한계" section says the same thing in
operator language rather than hiding it.

### 3. `WCS_OPERATOR` may exclude a machine but may not tune thresholds

design.md's role table gives `WCS_OPERATOR` exclusion rights but not policy
rights, and spec.md's scenario only requires "neither `WMS_ADMIN` nor
`WAREHOUSE_MANAGER` → `FORBIDDEN`". That is implemented literally.

Unlike area 2, no partial failure can result — the policy RPCs never dispatch
anything — so there was no reason to widen the set the way area 2 had to narrow
its own. The consequence is surfaced rather than hidden: `/wcs/routing` shows
the exclusion controls but a read-only threshold table for `WCS_OPERATOR`, with
an explicit note saying why (Playwright test 2), and `simulator.sql` §2
reproduces the refusal:

```
register_as_wcs_operator | ERR  FORBIDDEN: role cannot manage wcs routing policies
```

### 4. An exclusion does not stop work already in flight

Not a deviation from a written requirement, but a gap the spec text leaves open.
Excluding a busy machine only removes it from *future* candidate selection; its
outstanding commands keep running. Rather than silently doing half of what an
operator might expect, `wms_exclude_equipment_from_routing` returns
`IN_FLIGHT_COMMANDS_NOT_CANCELLED` in `warnings` when that is the case, the UI
shows it, and the manual tells the reader to cancel the command through
`/wcs/monitor` if the machine has to stop now.

## MCP layer

```bash
cd mcp && .venv/bin/python \
  ../openspec/specs/wms_wcs-bottleneck-routing/e2e/mcp_roundtrip.py
```

`mcp_roundtrip.py` re-runs the read model, the role refusals, a `dry_run` and
the full three-work-order routing sequence through `fastmcp.Client`, asserting
on the structured tool results. It uses a random `MCP-RTE-xxxxxx-A/B/C` AGV trio
in its own zone so it is re-runnable, and it cleans them up afterwards.

It also proves the role split at the tool layer: **all four** write tools answer
`FORBIDDEN`/`INVALID` for the `PROCESS_AGENT` identity the MCP server signs in
as, so only `get_equipment_routing_status` belongs in the agent allowlist
(`docs/03-processgpt-integration.md`). There is deliberately no
`select_available_equipment` tool — the assertions
`"select_available_equipment" not in tools` and
`"wcs_select_available_equipment" not in tools` are part of the script.

The interesting half is that the agent still *benefits* from the contract
without being able to touch it: the same `create_work_order` tool area 2 already
exposed routes around the excluded and the flagged machine, and falls back to
the flagged one when nothing else is left.

## Browser layer (Playwright)

```bash
cd frontend && npx playwright test wcs-routing-flow.spec.ts
```

`wcs-routing-flow.spec.ts` drives the real Vue screen `/wcs/routing` end to end,
and always pairs the *observation* with the *consequence* — asserting only on
the routing board would prove nothing, because the decision this contract
changes is invisible there.

1. UI — three identical idle AGVs, no bottleneck, no exclusion.
2. Off-UI — the gateway raises two faults on `ROUTE-E2E-02` and an operator
   resolves both; the board flags it `FAULT_FREQUENCY_EXCEEDED` while keeping it
   "배정 가능".
3. UI — registering an `AGV` policy with `fault_count_threshold=3` makes the flag
   disappear; lowering it to 2 brings it back. The verdict is a comparison, not
   magic.
4. UI — `ROUTE-E2E-03` is force-excluded with a reason and becomes "배정 불가".
5. UI — a work order created on `/wes/dispatch` goes to the clean AGV, verified
   both in the command summary and in `wms.work_orders` directly.
6. UI — with the clean one busy, the next work order **does** go to the flagged
   one (fallback).
7. UI — with only the excluded one left, the work order stays `QUEUED` with
   `NO_EQUIPMENT_AVAILABLE`, and zero commands exist for that machine.
8. UI — clearing the exclusion returns it to the pool immediately; `Retry`
   dispatches to it. The override row is `CLEARED`, not deleted.

A second test signs in as `wcs-operator-a@demo.local` to show deviation 3 in the
UI (and the in-flight warning of deviation 4), then as `quality-a@demo.local` to
show the read-only view, and asserts the audit trail contains all four commands
including the `ACTIVE->CLEARED` transition.

`playwright-run.txt` is the **whole** suite (`npx playwright test`), not just
this spec: 9 tests across `wms-flow`, `wcs-equipment-flow`, `wcs-routing-flow`,
`wcs-sortation-flow` and `wes-dispatch-flow`, all passing, confirming no
regression in the earlier areas — in particular that
`wes-dispatch-flow.spec.ts`'s flow-balancing assertions still hold now that its
selection helper is this contract's function (with no bottleneck and no
exclusion in play, the ordering degenerates to area 2's original one).

> Note (pre-existing, not introduced here): `wms-flow.spec.ts` consumes the
> seeded `SKU-A-001` shortage and replenishes it, so the suite needs a
> `supabase db reset` between full runs. That is true of the suite as it stood
> before this change too.

> Note on the warehouse-wide summary badge: `/wcs/routing` counts bottlenecks
> across the whole warehouse, and `wcs-equipment-flow.spec.ts` (which runs
> first) leaves its own faulted equipment behind. The spec therefore takes a
> baseline and asserts on the delta, and stops asserting on the bottleneck
> counter once it registers an `AGV` policy — that policy legitimately changes
> the verdict for other AGVs in the same warehouse too.

## Fixture isolation

Every object this area creates is namespaced so the other specs' strict
single-match locators keep working:

| Layer | Codes | Zone | Cleanup |
|---|---|---|---|
| `simulator.sql` | `RTE-AGV-01/02/03/09`, `RTE-SORT-01` | `ZONE-SIM-ROUTE`, `ZONE-SIM-QUEUE` | truncates at the top of the next run |
| `mcp_roundtrip.py` | `MCP-RTE-<rand>-A/B/C` | `ZONE-MCP-RTE-<rand>` | deletes the zone in `cleanup()` |
| Playwright | `ROUTE-E2E-01/02/03` | `ZONE-ROUTE-E2E` | deletes the zone, the fixture PO and the warehouse's routing policies in `afterAll` |
