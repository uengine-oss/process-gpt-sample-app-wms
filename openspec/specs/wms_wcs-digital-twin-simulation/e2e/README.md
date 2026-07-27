# `wms_wcs-digital-twin-simulation` — E2E verification

Verification artifacts for the WCS digital-twin / simulation contract
(`supabase/migrations/20260801_wcs_digital_twin_simulation.sql`): the
per-equipment `is_simulated` flag, the timing/failure profile that decides how a
fake machine behaves, the restart-safe per-command progress plan, and the
what-if scenario dry-run.

**What makes this area different from the five before it.** Areas 1–5 defined a
WMS↔WCS software contract whose equipment half — acknowledge, work, report the
result — this repository has no hardware for, so every round trip in those specs
had to be faked by hand in a psql `DO` block impersonating
`wcs-gateway-a@demo.local`. This area promotes that hand-waving into a real
process. `mcp/wms_mcp/simulator/wcs_gateway_simulator.py` signs in over Supabase
Auth as the seeded `WCS_GATEWAY` identity and calls the same RPCs a physical
PLC/WCS bridge would. **Every state transition in `worker-run.txt` was made by
that external process, not by SQL** — that file is the central evidence for this
area.

## Files

| File | What it is |
|---|---|
| `simulator.sql` | psql simulator + negative-path assertions across all spec requirements. Emulates the worker inline with **zero** delays so one transaction can walk a command end to end — it verifies the RPC *contract*, not the ticking |
| `simulator-run.txt` | captured output of a clean run against a freshly seeded DB |
| `worker_setup.sql` | fixture for the real-worker run: 3 machines (simulated AGV, always-jamming simulated SORTER, one AGV left REAL) + 3 `PENDING` commands, with **non-zero** delays. Stages only — reports nothing |
| `worker_verify.sql` | assertions about what the worker did (outcomes, transition trail, cross-area propagation, plan consumption, audit actor) |
| `worker_restart_safety.sql` | slows the AGV to ~1.2s/step and dispatches again, so a single `--tick` cannot drain it |
| `worker_palletize.sql` / `worker_palletize_verify.sql` | area 5's chain (wave → 2 outbound units → 2 sequences → one `PALLETIZE`) in front of a **simulated** `ROBOT_CELL`, and the per-item propagation assertions (tasks.md 6.3) |
| `worker_e2e.sh` | 8-step driver that runs the six above around **real** worker invocations |
| `worker-run.txt` | **the key artifact** — captured output of that driver |
| `mcp_roundtrip.py` | same contract driven through the MCP tool layer (in-process `fastmcp.Client`) |
| `mcp_roundtrip-run.txt` | captured output of a clean MCP round-trip |
| `playwright-run.txt` | captured output of the **full** browser E2E suite (13 tests, all specs) |
| `screenshots/` | 14 full-page screenshots captured during that run |

The browser spec itself lives with the app it drives, at
`frontend/playwright/e2e/wcs-simulation-flow.spec.ts` (Playwright's `testDir` is
fixed by `frontend/playwright.config.ts`). Its screenshots and run log land here.
The DOCX operator manual built from those screenshots is in `../docs/`.

## Running it

```bash
cd supabase && supabase start          # if not already running
supabase db reset                      # 7 migrations + seed

# 1. the RPC contract
docker exec -i supabase_db_process-gpt-sample-app-wms \
  psql -U postgres -d postgres -q < ../openspec/specs/wms_wcs-digital-twin-simulation/e2e/simulator.sql

# 2. THE REAL WORKER — fixture, `--once` drain, assertions, restart safety
../openspec/specs/wms_wcs-digital-twin-simulation/e2e/worker_e2e.sh

# 3. the MCP tool layer
cd ../mcp && .venv/bin/python \
  ../openspec/specs/wms_wcs-digital-twin-simulation/e2e/mcp_roundtrip.py

# 4. the browser
cd ../frontend && npx playwright test
```

The worker's own run modes (`--once` / `--tick` / `--loop`), its environment
variables and its restart semantics are documented at
`mcp/wms_mcp/simulator/README.md`. It is a process run from source, like
`mcp/main.py` — no new Docker image, no new credential (it reuses
`wcs-gateway-a@demo.local` from `supabase/seed.sql`).

`simulator.sql` and `worker_setup.sql` each truncate this contract's four tables
and the four WCS tables (plus their audit/idempotency rows) at the top, so both
are safely re-runnable without a full `db reset`. The Playwright suite as a whole
does need a fresh `supabase db reset` first — `wms-flow.spec.ts` consumes the
seeded `SKU-A-001` shortage, which is a pre-existing property of that spec, not
of this one. This contract's own browser spec is independently re-runnable
(unique `TWIN-` / `TWIN 야간 축소 운전` namespace plus an `afterAll` cleanup).

## The worker end-to-end run

This is what `worker-run.txt` proves, and it is the reason this area exists.

**Happy path, real process.** A `MOVE` is dispatched to a simulated AGV through
area 1's ordinary RPC by a `WCS_OPERATOR` who has no idea the machine is a
puppet. One `--once` invocation of `wcs_gateway_simulator` then signs in as
`WCS_GATEWAY`, plans the command (rolling the delays and the terminal outcome
once), and walks it `PENDING → ACKNOWLEDGED → IN_PROGRESS → COMPLETED` by calling
area 1's **real** `wms_report_command_result` three times. The equipment returns
to `IDLE`. Nothing in the run log was written by hand.

**Cross-area propagation fires for a fake machine.** The same invocation drives a
`DIVERT` on a `jam_rate=1` SORTER to `FAILED` with `outcome=JAM`, and area 3's
trigger escalates that into a `SORTATION_JAM` / `CRITICAL` / `OPEN` fault with
the sorter left in `FAULT`. Nobody reported a fault. This is the practical payoff
of routing the simulator through the real report RPC instead of writing rows: the
downstream contracts cannot tell the difference.

**A real machine in the same warehouse is untouched.** `WRK-REAL`
(`is_simulated=false`) has a `PENDING` `MOVE` throughout. It never appears in
`wms_get_due_simulation_actions`, never gets a plan, and is still `PENDING` when
the worker exits with `outstanding=0`. Mixed real/simulated fleets are safe.

**Restart safety is verified with actual process death** (design.md D3, tasks 5.3
/ 6.6). The AGV is slowed to ~1.2s per step and a second `MOVE` is dispatched.
The worker is then run as a **sequence of separate `--tick` OS processes** —
process 1 plans, exits; process 2 acknowledges, exits; process 3 progresses,
exits; process 4 completes. Between each, `worker_e2e.sh` prints the plan row so
you can watch `next_status` advance while `planned_terminal_status` stays frozen
at the value rolled by process 1. The final assertion counts exactly **1**
acknowledge, **1** progress and **1** terminal event: nothing was re-rolled,
re-reported or lost across four restarts. The plan row is then gone — terminal
plans are deleted, not orphaned.

**`PALLETIZE` per-item propagation is driven by the worker** (task 6.3). Area 5's
full chain — a wave, two outbound units, two sequences on one pallet — is built
in front of a *simulated* `ROBOT_CELL`, and one `PALLETIZE` command carrying both
`sequence_items` is dispatched. The worker's single `COMPLETED` report
(`outcome=SUCCESS`, every item `LOADED` with its own `load_position`) survives
area 5's `_wms_validate_palletize_outcome` trigger and drives
`_wms_propagate_palletize_result`, which moves **both** dispatch sequences and
**both** outbound orders to `COMPLETED` with distinct load positions. That is the
strongest available evidence that the vocabulary map in DEVIATION 1 is right: had
it emitted design.md's literal `PARTIAL`/`FAILURE`, the trigger would have
rejected the report outright.

**The audit actor is the worker.** `wms_plan_simulated_command`,
`wms_advance_simulated_command` and the resulting `wms_report_command_result`
rows all carry `wcs-gateway-a@demo.local` as `actor_id`, so "did a human or the
simulator finish this command?" is answerable after the fact.

## What `simulator.sql` covers

**Simulation mode** — `wms_set_equipment_simulation_mode` flips `is_simulated`
and **nothing else**; the script prints `status` before and after to show the
machine's operational state is untouched. A stale `expected_version` is
`CONFLICT`. Roles below `WAREHOUSE_MANAGER` are `FORBIDDEN`.

**Profiles** — registration requires the target to be in simulation mode
already, refuses a duplicate (update it instead), refuses `min > max` on any of
the three delay ranges and refuses a `failure_rate`/`jam_rate` outside 0–1.
Replaying an `idempotency_key` returns the cached response and creates exactly
one row. Update refuses a stale version and an all-`NULL` no-op.

**Default substitution** — `wms_get_simulation_profile` reports
`source=SYSTEM_DEFAULT` with the code's built-in constants for a machine with no
profile, and — the case worth having a test for — **also** for a machine whose
profile row exists but is `INACTIVE`. `registered_status` still shows `INACTIVE`
so the fallback is visible rather than silent.

**Planning and the vocabulary map** — the plan freezes all three delays and the
terminal outcome in one roll (design.md D3/D6, DEVIATION 2). Re-planning the same
command returns the existing plan idempotently. `command_type` selects the result
vocabulary from the string alone: `DIVERT` gets area 3's words, `PALLETIZE` gets
area 5's `loaded_items`, everything else gets the generic pair.

**Due-action filtering** — `next_run_at <= p_as_of`, ascending. A plan 60 s in
the future is excluded by `p_due_only`, and a command on an `is_simulated=false`
machine never enters the feed at all.

**Advancing** — mid-steps update the plan, the terminal step deletes it, and each
step goes through area 1's real report RPC. Advancing a not-yet-due plan is
refused.

**Scenarios** — an empty equipment set and a non-positive command count are both
refused. A run produces `projected_completion_at` / `projected_round_count` /
`projected_failure_count` and creates **zero** `wms.equipment_commands`; the
script counts commands before and after. Machines falling back to defaults are
named in `warnings` (`DEFAULT_PROFILE_APPLIED`), and every run adds a row rather
than overwriting the last one.

**RLS / privilege surface** — `authenticated` holds `SELECT` and nothing else on
all four new tables, RLS is enabled on all four, tenant B sees zero rows, and
tenant A's warehouse scope is enforced on the read RPCs.

**Audit trail** — all seven write paths (mode, register, update, plan, advance,
create scenario, run scenario) write `wms.audit_events` with populated
`before`/`after`.

## Role split (verified in `simulator.sql` §1–2, the browser spec §7, and above)

| RPC | Allowed |
|---|---|
| `wms_set_equipment_simulation_mode` | `WMS_ADMIN`, `WAREHOUSE_MANAGER` |
| `wms_register_simulation_profile` / `wms_update_simulation_profile` | + `WCS_OPERATOR` |
| `wms_plan_simulated_command` / `wms_get_due_simulation_actions` / `wms_advance_simulated_command` | `WCS_GATEWAY` **only** |
| `wms_create_simulation_scenario` / `wms_run_simulation_scenario` | `WMS_ADMIN`, `WAREHOUSE_MANAGER`, `PROCESS_AGENT` |

"Which machines are fake" is a warehouse policy decision; "how slow is the fake
one" is a floor adjustment. Hence `WCS_OPERATOR` gets the profile but not the
switch. The gateway-only group is the whole point of D2 — see below.

## Deviations from design.md found while implementing

These are documented at length in the migration header; summarised here.

**1. `PALLETIZE`→`PARTIAL` and `WRAP`→`FAILURE` are both impossible.** design.md
D5 says a failed palletising should be reproduced by marking some items
`SKIPPED` (outcome `PARTIAL`), and that `WRAP` falls into a generic
`SUCCESS|FAILURE` bucket. Area 5's shipped validators refuse both:
`_wms_validate_palletize_outcome` requires `PARTIAL` to arrive as
`COMMAND_COMPLETED`, so "failed → PARTIAL" is a contradiction, and the same
trigger accepts only `SUCCESS` or `FAILED` for `WRAP` — the word `FAILURE` would
be an `INVALID:`. The implemented map therefore uses `ABORTED` + all-`SKIPPED`
for a failed `PALLETIZE` and `FAILED` (not `FAILURE`) as the generic terminal
word, so an unknown command type can never generate a report area 5 rejects.

**2. The plan stores all three delays, not just `next_run_at`.** design.md's
column list for `wms.simulation_command_schedules` has only the next target time.
A plan holding only that would have to re-roll the later delays at every step,
which directly contradicts D3 ("계획 전체를 한 번에 굴려 저장한다") and D6
("계획에 고정한다") — and would break restart safety, since a restart would land
mid-command with un-rolled dice. `progress_delay_ms` and `completion_delay_ms`
are kept on the row.

**3. `wms_get_due_simulation_actions` also returns `unplanned_commands`
(additive).** design.md's worker loop makes discovery a separate call. Folding it
into the polling call halves the round trips per tick and — more importantly —
makes discovery impossible to drift out of sync with the due-action query's own
`is_simulated` filter, because they are now the same query's two halves.

**4. `wms_advance_simulated_command` tolerates a command that went terminal
behind the plan's back.** Area 3's JAM escalation calls
`wms_raise_equipment_fault`, which force-`FAILED`s every outstanding command on
that machine — including ones this contract holds live plans for. Rather than
crash the worker on "command is already terminal", the RPC drops the stale plan
and returns `result=ok` with a `COMMAND_ALREADY_TERMINAL` warning. This is
reachable in practice: it is exactly what happens when a simulated sorter jams
while another simulated command is queued on it.

**5. No `create or replace` of `wms_dispatch_equipment_command` this time.**
Worth recording because areas 3 and 5 each had to, and both wrote it up as a
trap. This area adds no `command_type`, so area 5's body (`20260731`) is left
untouched. The recurring trap did not recur.

## Known gaps (carried forward, not fixed here)

- **No deterministic replay.** The dice are `random()` at planning time with no
  seed. A single command's outcome is frozen once planned (that is what makes
  restarts safe), but two runs of the same scenario, or two dispatches of the
  same command shape, will differ. design.md lists this as a Non-Goal and
  `docs/04-wms-wcs-market-feature-catalog.md` §5 repeats it.
- **`p_command_count` is entered by hand.** A scenario does not derive its
  command count from a dispatch wave or any other live entity;
  `linked_entity_type`/`linked_entity_id` are labels only. Also a design.md Risk,
  also repeated in §5.
- **The scenario model ignores queueing.** `rounds = ceil(count / equipment)`
  with mean per-command time, no retries and no priority inversion. Every run
  emits an `OPTIMISTIC_ESTIMATE` warning saying so.
- **`simulator.sql` does not cover `PALLETIZE`.** Its §3 vocabulary check
  compares `DIVERT` against the generic `MOVE` words only. The `PALLETIZE`
  branch is instead covered by the worker run (steps 7–8 of `worker_e2e.sh`),
  which is the better place for it — the interesting part is the trigger
  interaction, and that needs a real report rather than an inline emulation.
- **The `--loop` mode is not exercised by any captured run.** Every artifact
  here uses `--once` or `--tick`, because a run log has to terminate. `--loop`
  is the same tick function on a `sleep` timer; the browser spec and the demo
  scripts both use `--once` for the same reason.
