\set QUIET on
\pset pager off
\pset format aligned
\set ON_ERROR_STOP on

-- ============================================================
-- wms_wcs-digital-twin-simulation — worker E2E fixture
--
-- Companion to worker_e2e.sh. Unlike simulator.sql (which emulates the worker
-- inline with zero delays so one transaction can walk a command end to end),
-- this script only sets the stage and then STOPS. The state transitions are
-- made by the real external process:
--
--   .venv/bin/python -m wms_mcp.simulator.wcs_gateway_simulator --once
--
-- signing in as the seeded WCS_GATEWAY identity over Supabase Auth. Nothing in
-- here reports a command result; every PENDING -> ACKNOWLEDGED -> IN_PROGRESS
-- -> COMPLETED/FAILED move in worker-run.txt comes from that process calling
-- area 1's real wms_report_command_result.
--
-- The profile delays are deliberately NON-zero (unlike simulator.sql) so the
-- worker actually has to wait for next_run_at between rounds -- that is the
-- part a single SQL transaction cannot exercise.
-- ============================================================

truncate wms.simulation_scenario_runs, wms.simulation_scenarios,
         wms.simulation_command_schedules, wms.simulation_profiles
  restart identity cascade;
truncate wms.equipment_status_events, wms.equipment_commands, wms.equipment_faults, wms.equipment
  restart identity cascade;
delete from wms.audit_events where command like 'wms_%simulat%'
   or command in ('wms_register_equipment','wms_dispatch_equipment_command',
                  'wms_report_command_result','wms_report_equipment_status');
delete from wms.idempotency_records where command_name like 'wms_%simulat%'
   or command_name in ('wms_register_equipment','wms_dispatch_equipment_command',
                       'wms_report_command_result','wms_report_equipment_status');

create or replace function pg_temp.act(p_email text) returns void
language plpgsql as $fn$
declare v_id uuid;
begin
  select id into v_id from auth.users where email = p_email;
  if v_id is null then raise exception 'no such demo user %', p_email; end if;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_id::text, 'role', 'authenticated')::text, false);
end
$fn$;

\set tenant_a '10000000-0000-0000-0000-00000000000a'
\set wh_a     '20000000-0000-0000-0000-00000000000a'

select id as mgr_a from auth.users where email = 'wh-manager-a@demo.local' \gset
select id as op_a  from auth.users where email = 'wcs-operator-a@demo.local' \gset
select id as gw_a  from auth.users where email = 'wcs-gateway-a@demo.local' \gset

\set QUIET off
\echo ''
\echo '=============================================================='
\echo 'FIXTURE — three machines: a simulated AGV (happy path), a'
\echo 'simulated SORTER (jam_rate=1), and an AGV left REAL'
\echo '=============================================================='

select pg_temp.act('wh-manager-a@demo.local');
set role authenticated;

select wms.wms_register_equipment(:'tenant_a', :'wh_a', 'WRK-AGV', 'AGV',
  'ZONE-WRK', :'mgr_a', gen_random_uuid(), 'worker-e2e') is not null as agv_registered;
select wms.wms_register_equipment(:'tenant_a', :'wh_a', 'WRK-SORTER', 'SORTER',
  'ZONE-WRK', :'mgr_a', gen_random_uuid(), 'worker-e2e') is not null as sorter_registered;
select wms.wms_register_equipment(:'tenant_a', :'wh_a', 'WRK-REAL', 'AGV',
  'ZONE-WRK', :'mgr_a', gen_random_uuid(), 'worker-e2e') is not null as real_registered;
reset role;

select id as agv    from wms.equipment where equipment_code = 'WRK-AGV' \gset
select id as sorter from wms.equipment where equipment_code = 'WRK-SORTER' \gset
select id as real   from wms.equipment where equipment_code = 'WRK-REAL' \gset

select pg_temp.act('wcs-gateway-a@demo.local');
set role authenticated;
select wms.wms_report_equipment_status(:'agv',    'IDLE', :'gw_a', gen_random_uuid(), 1, null, 'worker-e2e') is not null as agv_idle;
select wms.wms_report_equipment_status(:'sorter', 'IDLE', :'gw_a', gen_random_uuid(), 1, null, 'worker-e2e') is not null as sorter_idle;
select wms.wms_report_equipment_status(:'real',   'IDLE', :'gw_a', gen_random_uuid(), 1, null, 'worker-e2e') is not null as real_idle;
reset role;

\echo ''
\echo '-- simulation mode ON for the AGV and the SORTER, OFF for WRK-REAL'
select pg_temp.act('wh-manager-a@demo.local');
set role authenticated;
select wms.wms_set_equipment_simulation_mode(:'agv', true, :'mgr_a', gen_random_uuid(),
  (select version from wms.equipment where id = :'agv'), 'worker-e2e') ->> 'is_simulated' as agv_simulated;
select wms.wms_set_equipment_simulation_mode(:'sorter', true, :'mgr_a', gen_random_uuid(),
  (select version from wms.equipment where id = :'sorter'), 'worker-e2e') ->> 'is_simulated' as sorter_simulated;

\echo ''
\echo '-- profiles with REAL (non-zero) delays: the worker must wait between rounds'
select wms.wms_register_simulation_profile(
  p_equipment_id => :'agv',
  p_ack_delay_ms_min => 200, p_ack_delay_ms_max => 400,
  p_progress_delay_ms_min => 300, p_progress_delay_ms_max => 600,
  p_completion_delay_ms_min => 400, p_completion_delay_ms_max => 800,
  p_failure_rate => 0, p_jam_rate => 0,
  p_actor_id => :'mgr_a', p_idempotency_key => gen_random_uuid(),
  p_correlation_id => 'worker-e2e') ->> 'status' as agv_profile;
-- jam_rate = 1 on a SORTER: every DIVERT must come back JAM and escalate (area 3)
select wms.wms_register_simulation_profile(
  p_equipment_id => :'sorter',
  p_ack_delay_ms_min => 100, p_ack_delay_ms_max => 200,
  p_progress_delay_ms_min => 100, p_progress_delay_ms_max => 200,
  p_completion_delay_ms_min => 100, p_completion_delay_ms_max => 200,
  p_failure_rate => 1, p_jam_rate => 1,
  p_actor_id => :'mgr_a', p_idempotency_key => gen_random_uuid(),
  p_correlation_id => 'worker-e2e') ->> 'status' as sorter_profile;
reset role;

\echo ''
\echo '-- area 3 requires an ACTIVE sortation profile before a DIVERT is accepted'
select pg_temp.act('wcs-operator-a@demo.local');
set role authenticated;
select wms.wms_create_sortation_profile(:'sorter', 40, 0.5, 2.5, 50, :'op_a',
  gen_random_uuid(), 'FIXED', 'MPS', 'worker-e2e') ->> 'status' as sortation_profile;
reset role;

\echo ''
\echo '-- dispatch: MOVE to the simulated AGV, DIVERT to the always-jamming SORTER,'
\echo '   MOVE to the REAL AGV (which the worker must leave completely alone)'
select pg_temp.act('wcs-operator-a@demo.local');
set role authenticated;
select wms.wms_dispatch_equipment_command(:'agv', 'MOVE',
  '{"from":"ZONE-WRK","to":"ZONE-OUT"}'::jsonb, :'op_a', gen_random_uuid(),
  (select version from wms.equipment where id = :'agv'), 'worker-e2e', null, null) ->> 'status' as agv_command;
select wms.wms_dispatch_equipment_command(:'sorter', 'DIVERT',
  '{"target_chute":"CHUTE-01","item_identifier":"ITEM-WRK-1"}'::jsonb, :'op_a', gen_random_uuid(),
  (select version from wms.equipment where id = :'sorter'), 'worker-e2e', null, null) ->> 'status' as sorter_command;
select wms.wms_dispatch_equipment_command(:'real', 'MOVE',
  '{"from":"ZONE-WRK","to":"ZONE-OUT"}'::jsonb, :'op_a', gen_random_uuid(),
  (select version from wms.equipment where id = :'real'), 'worker-e2e', null, null) ->> 'status' as real_command;
reset role;

\echo ''
\echo '-- state BEFORE the worker runs: both PENDING, no plans exist yet'
select e.equipment_code, e.is_simulated, c.command_type, c.status
from wms.equipment_commands c join wms.equipment e on e.id = c.equipment_id
where e.warehouse_id = :'wh_a' order by e.equipment_code;

select count(*) as simulation_plans_before from wms.simulation_command_schedules;
