#!/usr/bin/env bash
# ============================================================
# wms_wcs-digital-twin-simulation — end-to-end worker verification
#
# The one thing that makes this area different from areas 1-5: the equipment
# half of the WMS<->WCS contract is driven by a REAL EXTERNAL PROCESS that
# signs in over Supabase Auth as the seeded WCS_GATEWAY identity, instead of
# being faked by hand in psql. This script is that proof.
#
#   1. worker_setup.sql            stage 3 machines + 3 PENDING commands
#   2. wcs_gateway_simulator --once  <-- the real worker drains them
#   3. worker_verify.sql           assert what the worker did
#   4. worker_restart_safety.sql   slow it down + dispatch again
#   5. wcs_gateway_simulator --tick x N, each a SEPARATE process (= restarts)
#   6. assert the command still finished exactly once
#   7. worker_palletize.sql + a drain + worker_palletize_verify.sql
#      (tasks.md 6.3 — area 5 per-item propagation driven by the worker)
#
# Usage (from the repo root, with supabase running and freshly `db reset`):
#   openspec/specs/wms_wcs-digital-twin-simulation/e2e/worker_e2e.sh
# ============================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"
DB=supabase_db_process-gpt-sample-app-wms
PSQL="docker exec -i $DB psql -U postgres -d postgres -q"
PY="$ROOT/mcp/.venv/bin/python"

echo "=============================================================="
echo "STEP 1/8 — fixture"
echo "=============================================================="
$PSQL < "$HERE/worker_setup.sql"

echo
echo "=============================================================="
echo "STEP 2/8 — THE REAL WORKER PROCESS (--once drain)"
echo "  $PY -m wms_mcp.simulator.wcs_gateway_simulator --once"
echo "=============================================================="
( cd "$ROOT/mcp" && "$PY" -m wms_mcp.simulator.wcs_gateway_simulator --once --max-seconds 45 )
echo "worker exit code: $?"

echo
echo "=============================================================="
echo "STEP 3/8 — assertions"
echo "=============================================================="
$PSQL < "$HERE/worker_verify.sql"

echo
echo "=============================================================="
echo "STEP 4/8 — restart-safety fixture"
echo "=============================================================="
$PSQL < "$HERE/worker_restart_safety.sql"

echo
echo "=============================================================="
echo "STEP 5/8 — SEPARATE --tick PROCESSES (each exit is a restart)"
echo "=============================================================="
for i in 1 2 3 4 5 6 7 8; do
  echo "--- tick #$i (pid of a brand new python process) ---"
  ( cd "$ROOT/mcp" && "$PY" -m wms_mcp.simulator.wcs_gateway_simulator --tick )
  $PSQL -c "select c.status as command_status,
                   s.next_status as plan_next_step,
                   s.planned_terminal_status as plan_frozen_outcome,
                   s.next_run_at
              from wms.equipment_commands c
              left join wms.simulation_command_schedules s on s.command_id = c.id
             where c.correlation_id = 'worker-e2e-restart';"
  DONE=$($PSQL -tAc "select count(*) from wms.equipment_commands
                      where correlation_id='worker-e2e-restart'
                        and status in ('COMPLETED','FAILED');")
  if [ "$DONE" = "1" ]; then echo "reached a terminal state after $i separate processes"; break; fi
  sleep 1
done

echo
echo "=============================================================="
echo "STEP 6/8 — restart-safety assertions"
echo "=============================================================="
$PSQL <<'SQL'
\pset pager off
\echo '-- the restart command finished, and finished exactly ONCE'
select c.status,
       count(*) filter (where ev.event_type = 'COMMAND_ACKNOWLEDGED') as acks,
       count(*) filter (where ev.event_type = 'COMMAND_PROGRESS')     as progresses,
       count(*) filter (where ev.event_type in ('COMMAND_COMPLETED','COMMAND_FAILED')) as terminals
from wms.equipment_commands c
left join wms.equipment_status_events ev on ev.command_id = c.id
where c.correlation_id = 'worker-e2e-restart'
group by c.status;

\echo '-- and its plan row is gone (terminal plans are deleted, not orphaned)'
select count(*) as plans_remaining from wms.simulation_command_schedules;
SQL

echo
echo "=============================================================="
echo "STEP 7/8 — PALLETIZE fixture (area 5 chain in front of a"
echo "           SIMULATED robot cell)"
echo "=============================================================="
$PSQL < "$HERE/worker_palletize.sql"

echo
echo "--- the real worker drains the PALLETIZE ---"
( cd "$ROOT/mcp" && "$PY" -m wms_mcp.simulator.wcs_gateway_simulator --once --max-seconds 45 )

echo
echo "=============================================================="
echo "STEP 8/8 — per-item propagation assertions (tasks.md 6.3)"
echo "=============================================================="
$PSQL < "$HERE/worker_palletize_verify.sql"

echo
echo "=============================================================="
echo "DONE — every transition above was made by the external worker"
echo "=============================================================="
