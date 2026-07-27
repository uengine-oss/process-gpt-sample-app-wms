# WCS gateway simulator

The external worker process of `wms_wcs-digital-twin-simulation`
(`supabase/migrations/20260801_wcs_digital_twin_simulation.sql`).

This repository has no automation hardware. Areas 1–5 defined a WMS↔WCS
software contract whose equipment half — acknowledge, work, report the result —
has always had to be faked by hand in psql. This worker is that half, promoted
to a real process: it signs in as the seeded `WCS_GATEWAY` identity and drives
every command dispatched to equipment flagged `is_simulated` through
`PENDING → ACKNOWLEDGED → IN_PROGRESS → COMPLETED/FAILED` on a configurable
timing/failure model.

It is **not** a new service. Like `mcp/main.py` it is a local process run from
source, it owns no state (every plan lives in
`wms.simulation_command_schedules`), and it introduces no new credential — it
reuses `wcs-gateway-a@demo.local` from `supabase/seed.sql`.

## Why a process and not `pg_cron`

`wms_report_command_result` authorises with `wms.has_role(...)`, which reads
`auth.uid()` — the `sub` claim of a Supabase Auth session. A pg_cron job has no
session (`auth.uid()` is null), so a database-side scheduler could only work by
forging `request.jwt.claims`, bypassing the trust boundary area 1 D5 drew.
Running out here means the simulator authenticates exactly the way a real
PLC/WCS bridge would. See design.md D2.

## Prerequisites

1. Local Supabase up and migrated (`cd supabase && supabase start && supabase db reset`).
2. `mcp/.env` filled in — the same file the MCP server uses:

   ```
   SUPABASE_URL=http://127.0.0.1:55321
   SUPABASE_ANON_KEY=<anon key from `supabase status`>
   WMS_WCS_GATEWAY_EMAIL=wcs-gateway-a@demo.local
   WMS_WCS_GATEWAY_PASSWORD=Demo1234!
   ```

3. At least one piece of equipment with `is_simulated = true`. Turn it on from
   the **WCS Simulation** screen (`/wcs/simulation`) as `WAREHOUSE_MANAGER`, or
   through the `set_equipment_simulation_mode` MCP tool. A registered
   `wms.simulation_profiles` row is optional — without one the system defaults
   apply (ack 500–1500 ms, progress 1000–3000 ms, completion 2000–5000 ms,
   `failure_rate` 0.05, `jam_rate` 0).

## Running

```bash
cd services/sample-app-wms/mcp

# drain: plan and advance everything outstanding, then exit.
# One invocation takes a freshly dispatched command all the way to COMPLETED —
# this is what the Playwright spec and the demo scripts use.
.venv/bin/python -m wms_mcp.simulator.wcs_gateway_simulator --once

# literal single poll: plan what is new, advance only what is due right now.
.venv/bin/python -m wms_mcp.simulator.wcs_gateway_simulator --tick

# real background mode: poll forever.
.venv/bin/python -m wms_mcp.simulator.wcs_gateway_simulator --loop --interval 1
```

Useful flags:

| Flag | Meaning |
|---|---|
| `--interval N` | seconds between polls in `--loop` (default 1.0) |
| `--max-seconds N` | wall-clock budget for a `--once` drain (default 60) |
| `--tenant-id` / `--warehouse-id` | restrict the scope; by default the worker drives every warehouse its membership can see |
| `-q` | warnings and errors only |

Exit code is `1` if any RPC failed during the run, `0` otherwise.

## What one tick does

1. `wms_get_due_simulation_actions` — one round trip returning both
   `unplanned_commands` (live commands on simulated equipment with no plan) and
   `due_actions` (plans whose `next_run_at` has arrived).
2. `wms_plan_simulated_command` for each unplanned command. Idempotent: the
   delays and the terminal outcome are rolled **once** and frozen into the plan
   row, so two workers, or a restart, cannot re-roll them.
3. `wms_advance_simulated_command` for each due action. That RPC calls area 1's
   real `wms_report_command_result`, which is why areas 2–5's triggers —
   work-order propagation, sortation outcome validation, JAM → fault
   escalation, per-item palletising propagation — all fire for a simulated
   machine exactly as they would for a real one.

## Restart safety

Kill the worker mid-command and start it again: the plan is in the database, so
it resumes at the step it was on. Nothing is re-reported and nothing is lost
(design.md D3). The worker is an *optional* auto-responder, not a single point
of failure — with it stopped, a human `WCS_OPERATOR` can still drive the same
commands by hand through area 1's RPCs.

## Result vocabulary

The terminal payload depends on the command type (design.md D5), decided from
the `command_type` string alone — no other contract's tables are read:

| `command_type` | COMPLETED | FAILED |
|---|---|---|
| `DIVERT` | `{"outcome":"SUCCESS","actual_chute":…}` | `JAM` at `jam_rate`, otherwise `MISROUTE` |
| `PALLETIZE` | `SUCCESS`, every `loaded_items` entry `LOADED` | `ABORTED`, every entry `SKIPPED` |
| `WRAP` | `SUCCESS` | `FAILED` |
| anything else | `{"outcome":"SUCCESS"}` | `{"outcome":"FAILED","reason":"SIMULATED_FAILURE"}` |

A `jam_rate=1` `DIVERT` therefore reproduces area 3's automatic
`SORTATION_JAM` fault escalation end to end, with no hand-written SQL.

## Not covered

No 3D motion or physics, no PLC/fieldbus protocol, no deterministic replay
(the dice are rolled with `random()` at planning time and are not seeded), no
queueing model. See the change's design.md Non-Goals.
