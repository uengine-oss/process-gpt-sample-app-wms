\set QUIET on
\pset pager off
\pset format aligned
\set ON_ERROR_STOP on

-- ============================================================
-- wms_wcs-digital-twin-simulation — worker E2E assertions
--
-- Run AFTER worker_setup.sql + one real
--   .venv/bin/python -m wms_mcp.simulator.wcs_gateway_simulator --once
-- Every row printed below was written by that external process, not by SQL.
-- ============================================================

\set tenant_a '10000000-0000-0000-0000-00000000000a'
\set wh_a     '20000000-0000-0000-0000-00000000000a'

create or replace function pg_temp.act(p_email text) returns void
language plpgsql as $fn$
declare v_id uuid;
begin
  select id into v_id from auth.users where email = p_email;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_id::text, 'role', 'authenticated')::text, false);
end
$fn$;

\set QUIET off
\echo ''
\echo '=============================================================='
\echo 'A. Command outcomes — the worker moved these, nobody clicked'
\echo '=============================================================='
-- the reported result lives in the terminal status event (area 1's shape),
-- not on the command row itself
select e.equipment_code, e.is_simulated, c.command_type, c.status,
       (select ev.detail->>'outcome' from wms.equipment_status_events ev
         where ev.command_id = c.id and ev.detail ? 'outcome'
         order by ev.seq desc limit 1) as outcome,
       (select ev.detail->>'simulated' from wms.equipment_status_events ev
         where ev.command_id = c.id and ev.detail ? 'simulated'
         order by ev.seq desc limit 1) as simulated_flag
from wms.equipment_commands c join wms.equipment e on e.id = c.equipment_id
where e.warehouse_id = :'wh_a' order by e.equipment_code;

\echo ''
\echo '-- expected: WRK-AGV MOVE COMPLETED/SUCCESS, WRK-SORTER DIVERT FAILED/JAM,'
\echo '   WRK-REAL still PENDING (is_simulated=false is never touched)'
select
  (select count(*) from wms.equipment_commands c join wms.equipment e on e.id=c.equipment_id
    where e.equipment_code='WRK-AGV' and c.status='COMPLETED') = 1 as agv_completed,
  (select count(*) from wms.equipment_commands c join wms.equipment e on e.id=c.equipment_id
    join wms.equipment_status_events ev on ev.command_id = c.id
    where e.equipment_code='WRK-SORTER' and c.status='FAILED'
      and ev.detail->>'outcome'='JAM') = 1 as sorter_jammed,
  (select count(*) from wms.equipment_commands c join wms.equipment e on e.id=c.equipment_id
    where e.equipment_code='WRK-REAL' and c.status='PENDING') = 1 as real_untouched;

\echo ''
\echo '=============================================================='
\echo 'B. The full transition trail per command (area 1 status events)'
\echo '=============================================================='
select e.equipment_code, ev.seq, ev.event_type, ev.detail->>'outcome' as outcome
from wms.equipment_status_events ev
join wms.equipment e on e.id = ev.equipment_id
where ev.command_id is not null and e.warehouse_id = :'wh_a'
order by e.equipment_code, ev.seq;

\echo ''
\echo '=============================================================='
\echo 'C. Cross-area propagation fired for a SIMULATED machine'
\echo '   (area 3: JAM must escalate to a SORTATION_JAM fault)'
\echo '=============================================================='
select e.equipment_code, f.fault_code, f.severity, f.status as fault_status
from wms.equipment_faults f join wms.equipment e on e.id = f.equipment_id
order by e.equipment_code;

select e.equipment_code, e.status as equipment_status
from wms.equipment e where e.warehouse_id = :'wh_a' order by e.equipment_code;

\echo ''
\echo '=============================================================='
\echo 'D. Plans are consumed — terminal plans are deleted, none linger'
\echo '=============================================================='
select count(*) as plans_remaining from wms.simulation_command_schedules;

select pg_temp.act('wcs-gateway-a@demo.local');
set role authenticated;
select jsonb_array_length(
  wms.wms_get_simulation_schedule_status(:'tenant_a', :'wh_a', null, false)->'schedules'
) as schedule_status_rows;

\echo ''
\echo '-- the real AGV''s PENDING command never entered the due-action feed'
select jsonb_array_length(
  wms.wms_get_due_simulation_actions(:'tenant_a', :'wh_a')->'unplanned_commands'
) as unplanned_left;
reset role;

\echo ''
\echo '=============================================================='
\echo 'E. Audit trail written by the WORKER identity (WCS_GATEWAY)'
\echo '=============================================================='
select a.command, count(*) as events,
       (select email from auth.users u where u.id = a.actor_id) as actor
from wms.audit_events a
where a.command in ('wms_plan_simulated_command','wms_advance_simulated_command',
                    'wms_report_command_result')
group by a.command, a.actor_id order by 1;
