# `wms_wcs-sortation-logic` — E2E verification

Verification artifacts for the high-speed sortation contract
(`supabase/migrations/20260729_wcs_sortation_logic.sql`): per-equipment
sortation profiles, the `DIVERT` / `SET_SPEED` payload contract layered on
`wms_wcs-equipment-control`'s command envelope, the outcome↔status consistency
rule, and the automatic `SORTATION_JAM` escalation.

No real PLC or hardware is involved. The equipment side is driven by the same
software-simulator idea as areas 1 and 2: the scripts authenticate as the
seeded demo identities (`request.jwt.claims` + `set role authenticated`) and
call the contract's RPCs directly, which is exactly what a real WCS/PLC gateway
would do.

## Files

| File | What it is |
|---|---|
| `simulator.sql` | psql state-machine simulator + negative-path assertions |
| `simulator-run.txt` | captured output of a clean run against a freshly seeded DB |
| `mcp_roundtrip.py` | same contract driven through the MCP tool layer (in-process `fastmcp.Client`) |
| `mcp_roundtrip-run.txt` | captured output of a clean MCP round-trip |
| `playwright-run.txt` | captured output of the **full** browser E2E suite (7 tests, all specs) |
| `screenshots/` | 14 full-page screenshots captured during that run |

The browser spec itself lives with the app it drives, at
`frontend/playwright/e2e/wcs-sortation-flow.spec.ts` (Playwright's `testDir` is
fixed by `frontend/playwright.config.ts`). Its screenshots and run log land
here.

## Running it

```bash
cd supabase && supabase start          # if not already running
supabase db reset                      # 4 migrations + seed
docker exec -i supabase_db_process-gpt-sample-app-wms \
  psql -U postgres -d postgres -q < ../openspec/specs/wms_wcs-sortation-logic/e2e/simulator.sql
```

The script truncates only `wms.sortation_profiles`, the WES tables and the four
WCS tables (plus their audit/idempotency rows) at the top, so it is safely
re-runnable without a full `db reset`.

## What it covers

**Profile registration** — a `SORTER` and a `CONVEYOR` each get a profile;
an `AGV` is refused (`INVALID`), a duplicate profile is refused, and
`min_carton_gap_mm <= 0`, `sensor_detection_window_ms <= 0`,
`min_speed_value > max_speed_value` and an unknown `speed_mode` are all refused.
`QUALITY_INSPECTOR` gets `FORBIDDEN`; tenant B gets `FORBIDDEN` on tenant A's
equipment and sees 0 rows.

**Profile update** — `WCS_OPERATOR` widens the speed range with the right
`expected_version`; a stale version is `CONFLICT`; an inverted range and an
unknown status are `INVALID`.

**DIVERT payload (design.md D3)** — the happy path creates a `PENDING` command;
a missing `item_identifier`, a missing `target_chute`, a non-positive
`expected_gap_mm`, an equipment with **no** profile, an equipment whose profile
is `INACTIVE`, and a non-`SORTER`/`CONVEYOR` equipment are each refused with a
distinct `INVALID:` message — all through the *unmodified*
`wms_dispatch_equipment_command` call path (tasks.md 3.7).

**SET_SPEED payload + range** — `speed_value` inside the profile range is
accepted; above max, below min, a `speed_unit` that differs from the profile,
`speed_mode='FIXED'` without `speed_value`, and an unknown `speed_mode` are
refused. `speed_mode='AUTO'` is accepted **without** `speed_value` (design.md
D8) and is recorded as a mode-switch instruction only.

**Outcome consistency (design.md D4)** — `outcome='SUCCESS'` reported as
`FAILED`, `outcome='MISROUTE'` reported as `COMPLETED`, and an unknown outcome
value are all refused; the consistent pair is accepted and readable back
through the read model's `last_outcome`.

**MISROUTE** — fails the command only: the equipment stays `RUNNING` and zero
faults are raised.

**JAM auto-escalation (design.md D5)** — with one `IN_PROGRESS` `DIVERT` and one
other `PENDING` command on the same sorter, reporting
`FAILED` + `{"outcome":"JAM"}` moves the equipment to `FAULT`, force-fails
**both** commands, links both to the one new `SORTATION_JAM` / `CRITICAL` fault,
refuses any further dispatch, and is then cleared by a `WCS_OPERATOR` through
area 1's existing `wms_resolve_equipment_fault` (equipment back to `IDLE`).

**Roles / RLS / grants** — `information_schema.role_table_grants` confirms
`SELECT` is the only privilege on `wms.sortation_profiles` and only to
`authenticated`; direct `INSERT`/`UPDATE`/`DELETE` as `authenticated` is
"permission denied"; tenant B sees 0 rows and gets `FORBIDDEN` from the read
RPC.

**Idempotency** — replaying the same `idempotency_key` on
`wms_create_sortation_profile` returns the identical response and creates no
second row.

**Audit coverage** — profile create/update, the automatic escalation
(`wms_escalate_sortation_jam`) and area 1's fault rows are all present, and the
escalation row carries `before.equipment_status='RUNNING'` →
`after.equipment_status='FAULT'`.

## Documented deviations found while implementing

### 1. `wms_dispatch_equipment_command` had to be replaced, not just the CHECK constraint

design.md D2/D3 assumed that swapping
`wms.equipment_commands.command_type`'s `CHECK` constraint was enough to make
`DIVERT`/`SET_SPEED` dispatchable, and stated
"`wms_dispatch_equipment_command` RPC 자체는 수정하지 않는다".

The **shipped** area-1 RPC hard-codes the same list inside its own guard:

```sql
if p_command_type not in ('MOVE','LOAD','UNLOAD','START','STOP','RESET','HOLD','RESUME') then
  raise exception 'INVALID: unknown command_type %', p_command_type;
```

so relaxing the constraint alone is a no-op — every `DIVERT` would be refused
by the RPC before the constraint is ever consulted. The migration therefore
does a `create or replace` of that function with the two new values added to
that one list and nothing else changed, and it does so **from this migration's
file** — `20260727_wcs_equipment_control.sql` itself is untouched, exactly as
D2 requires. If area 1 ever reshapes that RPC, this replacement has to be
re-based on it (noted in the migration header as DEVIATION 1).

### 2. `WMS_ADMIN` may tune a profile but may not dispatch a sortation command

Area 2 already documented that the shipped `wms_dispatch_equipment_command`
allows `WAREHOUSE_MANAGER`, `WCS_OPERATOR`, `PROCESS_AGENT` and — unlike every
other RPC in that migration — **not** `WMS_ADMIN`.

This contract's design.md role table lists `WMS_ADMIN` for *profile* management
only and correctly defers dispatch permissions to area 1, so unlike area 2 there
is no partial-failure trap to avoid here: the three profile RPCs never dispatch
anything. The role list is therefore implemented exactly as designed, and the
consequence is surfaced rather than hidden — `simulator.sql` §7 reproduces it:

```
admin_create_profile   | OK   {"result": "ok", ... "equipment_code": "SIM-SORTER-02"}
admin_dispatch_divert  | ERR  FORBIDDEN: role cannot dispatch equipment commands
```

and the `/wcs/sortation` screen shows the profile editor but no command forms
for `WMS_ADMIN`, with an explicit note saying why (Playwright test 2).

If a follow-up change adds `WMS_ADMIN` to `wms_dispatch_equipment_command`, the
UI's `canDispatch` list in `frontend/src/views/WcsSortationView.vue` must be
updated in the same change.

### 3. Rejected payloads cannot leave an audit row

spec.md "감사 추적" asks for "Divert/속도 조정 명령의 payload 검증 거부" to be
written to `wms.audit_events`. That cannot be honoured as written: a rejection
is a `RAISE EXCEPTION`, which rolls the whole transaction back — including any
audit row the trigger just wrote. Persisting it would need an autonomous
transaction (`dblink` / `pg_background`), neither of which this repository uses.

What *is* audited: every successful write (profile create/update, the command
insert through area 1's dispatch RPC) plus the automatic jam escalation, which
adds its own `wms_escalate_sortation_jam` row on top of area 1's fault rows —
that extra row exists precisely because area 1's own audit row records
`before = the equipment row` / `after = the fault row` and so never spells out
the `RUNNING → FAULT` transition the spec's audit scenario asks for.

Rejections surface to the caller as the `INVALID:` error and nowhere else.

## MCP layer

```bash
cd mcp && .venv/bin/python \
  ../openspec/specs/wms_wcs-sortation-logic/e2e/mcp_roundtrip.py
```

`mcp_roundtrip.py` re-runs the profile read model, the `DIVERT`/`SET_SPEED`
dispatch path, the range/payload refusals, the `SUCCESS` report and the jam
escalation through `fastmcp.Client`, asserting on the structured tool results.
It uses a random `MCP-SORT-xxxxxx` / `MCP-BARE-xxxxxx` sorter pair in its own
zone so it is re-runnable, and it cleans them up afterwards.

It also proves the role split at the tool layer: `create_sortation_profile` and
`update_sortation_profile` answer `FORBIDDEN` for the `PROCESS_AGENT` identity
the MCP server signs in as, so only `get_sortation_profile` belongs in the
agent allowlist (`docs/03-processgpt-integration.md`). There is deliberately no
`dispatch_sortation_command` tool — the assertion `"dispatch_sortation_command"
not in tools` is part of the script.

## Browser layer (Playwright)

```bash
cd frontend && npx playwright test wcs-sortation-flow.spec.ts
```

`wcs-sortation-flow.spec.ts` drives the real Vue screen `/wcs/sortation` end to
end. Equipment registration belongs to area 1, so the fixture (two idle sorters
in `ZONE-SORT-E2E`) is created off-UI; the gateway outcome reports are executed
off-UI through `psql` for the same reason as in areas 1 and 2 — nobody logs into
the frontend as `WCS_GATEWAY`.

1. UI — both sorters show "프로파일 없음" and no command forms.
2. UI — `wh-manager-a@demo.local` registers a profile (150 mm, 0.5–2 MPS, 80 ms).
3. UI — `SET_SPEED` at 3.5 MPS is rejected with "outside the profile range";
   1.8 MPS is accepted and shows as an in-flight command.
4. UI — a `DIVERT` to `CHUTE-12` is dispatched.
5. Off-UI — the gateway reports `MISROUTE`; the UI shows the outcome and the
   monitor shows `COMMAND_FAILED` with **no** fault banner.
6. UI — a second `DIVERT`; off-UI the gateway reports `JAM`; the sorter is now
   `FAULT`, both outstanding commands are gone, and `/wcs/monitor` shows a
   `SORTATION_JAM` / `CRITICAL` fault nobody filed by hand.
7. UI — a `WCS_OPERATOR` resolves the fault; the sorter returns to `IDLE` and
   accepts an `AUTO`-mode `SET_SPEED`.

A second test signs in as `admin-a@demo.local` (`WMS_ADMIN`) to show deviation 2
in the UI, then as `quality-a@demo.local` to show the read-only view, and
asserts the audit trail contains all four commands including
`wms_escalate_sortation_jam` with its `RUNNING->FAULT` transition.

`playwright-run.txt` is the **whole** suite (`npx playwright test`), not just
this spec: 7 tests across `wms-flow`, `wcs-equipment-flow`, `wes-dispatch-flow`
and `wcs-sortation-flow`, all passing, confirming no regression in the earlier
areas.

> Note (pre-existing, not introduced here): `wms-flow.spec.ts` consumes the
> seeded `SKU-A-001` shortage and replenishes it, so the suite needs a
> `supabase db reset` between full runs. That is true of the suite as it stood
> before this change too.

## Fixture isolation

Every object this area creates is namespaced so the other specs' strict
single-match locators keep working:

| Layer | Codes | Zone | Cleanup |
|---|---|---|---|
| `simulator.sql` | `SIM-SORTER-01/02`, `SIM-CONV-01/02`, `SIM-AGV-01` | `ZONE-SIM` | truncates at the top of the next run |
| `mcp_roundtrip.py` | `MCP-SORT-<rand>`, `MCP-BARE-<rand>` | `ZONE-MCP-<rand>` | deletes the zone in `cleanup()` |
| Playwright | `SORT-E2E-01/02` | `ZONE-SORT-E2E` | deletes the zone in `afterAll` |
