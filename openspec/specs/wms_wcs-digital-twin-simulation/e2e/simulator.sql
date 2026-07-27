\set QUIET on
\pset pager off
\pset format aligned
\set ON_ERROR_STOP on

-- ============================================================
-- wms_wcs-digital-twin-simulation — psql verification script
-- (supabase/migrations/20260801_wcs_digital_twin_simulation.sql)
--
-- Drives the contract the way real callers do: it impersonates the seeded demo
-- users with request.jwt.claims + `set role authenticated`, so auth.uid(),
-- wms.current_warehouse_ids() and wms.has_role() behave exactly as they do for
-- a real Supabase session.
--
-- NOTE ON WHAT THIS SCRIPT IS *NOT*: it verifies the RPC contract. The actual
-- ticking — the thing that makes this area different from areas 1-5 — is done
-- by the external worker process, not by SQL. That is verified separately in
-- worker-run.txt (a real `python -m wms_mcp.simulator.wcs_gateway_simulator`
-- run) and in the Playwright spec. Here the "worker" is emulated by calling
-- plan/advance directly, with zero delays so a single transaction can walk a
-- command end to end.
-- ============================================================

-- repeatable without a full `supabase db reset`
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

create or replace function pg_temp.try(p_sql text) returns text
language plpgsql as $fn$
declare v_res jsonb;
begin
  execute p_sql into v_res;
  return 'OK   ' || coalesce(v_res::text, '(null)');
exception when others then
  return 'ERR  ' || sqlerrm;
end
$fn$;

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

create or replace function pg_temp.dispatch(p_equipment uuid, p_type text, p_payload jsonb, p_actor uuid)
returns text language plpgsql as $fn$
begin
  return pg_temp.try(format(
    'select wms.wms_dispatch_equipment_command(%L,%L,%L::jsonb,%L,gen_random_uuid(),'
    || '(select version from wms.equipment where id = %L),%L,null,null)',
    p_equipment, p_type, p_payload::text, p_actor, p_equipment, 'twin-sim'));
end
$fn$;

\set tenant_a '10000000-0000-0000-0000-00000000000a'
\set tenant_b '10000000-0000-0000-0000-00000000000b'
\set wh_a     '20000000-0000-0000-0000-00000000000a'

select id as mgr_a   from auth.users where email = 'wh-manager-a@demo.local' \gset
select id as op_a    from auth.users where email = 'wcs-operator-a@demo.local' \gset
select id as gw_a    from auth.users where email = 'wcs-gateway-a@demo.local' \gset
select id as pa_a    from auth.users where email = 'process-agent-a@demo.local' \gset
select id as admin_a from auth.users where email = 'admin-a@demo.local' \gset
select id as admin_b from auth.users where email = 'admin-b@demo.local' \gset
select id as qual_a  from auth.users where email = 'quality-a@demo.local' \gset

\set QUIET off
\echo ''
\echo '=============================================================='
\echo '0. FIXTURE — one AGV to simulate, one sorter, one AGV left real'
\echo '=============================================================='

select pg_temp.act('wh-manager-a@demo.local');
set role authenticated;
select pg_temp.try(format('select wms.wms_register_equipment(%L,%L,%L,%L,%L,%L,gen_random_uuid(),%L)',
  :'tenant_a', :'wh_a', 'SIM-TWIN-AGV', 'AGV', 'ZONE-TWIN', :'mgr_a', 'twin-sim')) as register_agv;
select pg_temp.try(format('select wms.wms_register_equipment(%L,%L,%L,%L,%L,%L,gen_random_uuid(),%L)',
  :'tenant_a', :'wh_a', 'SIM-TWIN-SORTER', 'SORTER', 'ZONE-TWIN', :'mgr_a', 'twin-sim')) as register_sorter;
select pg_temp.try(format('select wms.wms_register_equipment(%L,%L,%L,%L,%L,%L,gen_random_uuid(),%L)',
  :'tenant_a', :'wh_a', 'SIM-TWIN-REAL', 'AGV', 'ZONE-TWIN', :'mgr_a', 'twin-sim')) as register_real;
reset role;

select id as agv    from wms.equipment where equipment_code = 'SIM-TWIN-AGV' \gset
select id as sorter from wms.equipment where equipment_code = 'SIM-TWIN-SORTER' \gset
select id as real   from wms.equipment where equipment_code = 'SIM-TWIN-REAL' \gset

select pg_temp.act('wcs-gateway-a@demo.local');
set role authenticated;
select pg_temp.try(format('select wms.wms_report_equipment_status(%L,%L,%L,gen_random_uuid(),1,null,%L)',
  :'agv', 'IDLE', :'gw_a', 'twin-sim')) as boot_agv;
select pg_temp.try(format('select wms.wms_report_equipment_status(%L,%L,%L,gen_random_uuid(),1,null,%L)',
  :'sorter', 'IDLE', :'gw_a', 'twin-sim')) as boot_sorter;
select pg_temp.try(format('select wms.wms_report_equipment_status(%L,%L,%L,gen_random_uuid(),1,null,%L)',
  :'real', 'IDLE', :'gw_a', 'twin-sim')) as boot_real;
reset role;

\echo ''
\echo '=============================================================='
\echo '1. Simulation mode (spec: 설비 시뮬레이션 모드 지정)'
\echo '   status must NOT change; a stale version must be CONFLICT'
\echo '=============================================================='

select equipment_code, status, version, is_simulated
from wms.equipment where warehouse_id = :'wh_a' order by equipment_code;

select pg_temp.act('wh-manager-a@demo.local');
set role authenticated;
select pg_temp.try(format('select wms.wms_set_equipment_simulation_mode(%L,true,%L,gen_random_uuid(),'
  || '(select version from wms.equipment where id = %L),%L)',
  :'agv', :'mgr_a', :'agv', 'twin-sim')) as mode_on_agv;
-- the version just moved on, so replaying the version the boot left (2) is refused
select pg_temp.try(format('select wms.wms_set_equipment_simulation_mode(%L,false,%L,gen_random_uuid(),2,%L)',
  :'agv', :'mgr_a', 'twin-sim')) as stale_version_conflict;
select pg_temp.try(format('select wms.wms_set_equipment_simulation_mode(%L,true,%L,gen_random_uuid(),'
  || '(select version from wms.equipment where id = %L),%L)',
  :'sorter', :'mgr_a', :'sorter', 'twin-sim')) as mode_on_sorter;
reset role;

select equipment_code, status, version, is_simulated
from wms.equipment where warehouse_id = :'wh_a' order by equipment_code;

\echo '-- role gate: WCS_OPERATOR may tune profiles but not flip the flag'
select pg_temp.act('wcs-operator-a@demo.local');
set role authenticated;
select pg_temp.try(format('select wms.wms_set_equipment_simulation_mode(%L,true,%L,gen_random_uuid(),'
  || '(select version from wms.equipment where id = %L),%L)',
  :'real', :'op_a', :'real', 'twin-sim')) as operator_cannot_set_mode;
reset role;

\echo '-- cross tenant: tenant B admin has no scope here'
select pg_temp.act('admin-b@demo.local');
set role authenticated;
select pg_temp.try(format('select wms.wms_set_equipment_simulation_mode(%L,true,%L,gen_random_uuid(),1,%L)',
  :'real', :'admin_b', 'twin-sim')) as tenant_b_forbidden;
reset role;

\echo ''
\echo '=============================================================='
\echo '2. Profiles (spec: 프로파일 등록과 갱신 / 조회와 기본값 대체)'
\echo '=============================================================='

select pg_temp.act('wcs-operator-a@demo.local');
set role authenticated;
\echo '-- happy path: zero delays so this script can walk a command in one go'
select pg_temp.try(format('select wms.wms_register_simulation_profile(%L,0,0,0,0,0,0,0,%L,gen_random_uuid(),0,%L)',
  :'agv', :'op_a', 'twin-sim')) as register_profile_agv;
\echo '-- duplicate registration is refused'
select pg_temp.try(format('select wms.wms_register_simulation_profile(%L,0,0,0,0,0,0,0,%L,gen_random_uuid(),0,%L)',
  :'agv', :'op_a', 'twin-sim')) as duplicate_profile;
\echo '-- a machine that is not in simulation mode cannot have a profile'
select pg_temp.try(format('select wms.wms_register_simulation_profile(%L,0,0,0,0,0,0,0,%L,gen_random_uuid(),0,%L)',
  :'real', :'op_a', 'twin-sim')) as profile_on_real_equipment;
\echo '-- range and probability validation'
select pg_temp.try(format('select wms.wms_register_simulation_profile(%L,900,100,0,0,0,0,0,%L,gen_random_uuid(),0,%L)',
  :'sorter', :'op_a', 'twin-sim')) as min_greater_than_max;
select pg_temp.try(format('select wms.wms_register_simulation_profile(%L,0,0,0,0,0,0,1.5,%L,gen_random_uuid(),0,%L)',
  :'sorter', :'op_a', 'twin-sim')) as failure_rate_out_of_range;
reset role;

select id as profile_agv from wms.simulation_profiles where equipment_id = :'agv' \gset

\echo '-- idempotency: the same key twice must create exactly one profile'
select pg_temp.act('wcs-operator-a@demo.local');
set role authenticated;
select 'a0000000-0000-0000-0000-0000000000aa'::uuid as k \gset
select pg_temp.try(format('select wms.wms_register_simulation_profile(%L,0,0,0,0,0,0,0,%L,%L,0,%L)',
  :'sorter', :'op_a', :'k', 'twin-sim')) as idem_first;
select pg_temp.try(format('select wms.wms_register_simulation_profile(%L,0,0,0,0,0,0,0,%L,%L,0,%L)',
  :'sorter', :'op_a', :'k', 'twin-sim')) as idem_replay;
reset role;
select count(*) as sorter_profile_rows from wms.simulation_profiles where equipment_id = :'sorter';
select id as profile_sorter from wms.simulation_profiles where equipment_id = :'sorter' \gset

\echo '-- update: stale version is CONFLICT, empty update is INVALID'
select pg_temp.act('wcs-operator-a@demo.local');
set role authenticated;
select pg_temp.try(format('select wms.wms_update_simulation_profile(%L,%L,gen_random_uuid(),99,'
  || 'null,null,null,null,null,null,0.5,null,null,%L)', :'profile_agv', :'op_a', 'twin-sim')) as update_stale_version;
select pg_temp.try(format('select wms.wms_update_simulation_profile(%L,%L,gen_random_uuid(),1,'
  || 'null,null,null,null,null,null,null,null,null,%L)', :'profile_agv', :'op_a', 'twin-sim')) as update_nothing;
reset role;

\echo '-- read: registered vs system default, and the INACTIVE fallback'
select item->>'equipment_code' as code,
       item->>'is_simulated' as simulated,
       item->'effective_profile'->>'source' as source,
       item->'effective_profile'->>'failure_rate' as failure_rate,
       item->'registered_profile'->>'status' as registered_status
from jsonb_array_elements(
  wms.wms_get_simulation_profile(:'tenant_a', :'wh_a', null)->'equipment') item
order by 1;

select pg_temp.act('wcs-operator-a@demo.local');
set role authenticated;
select pg_temp.try(format('select wms.wms_update_simulation_profile(%L,%L,gen_random_uuid(),'
  || '(select version from wms.simulation_profiles where id = %L),'
  || 'null,null,null,null,null,null,null,null,%L,%L)',
  :'profile_sorter', :'op_a', :'profile_sorter', 'INACTIVE', 'twin-sim')) as deactivate_sorter_profile;
reset role;

\echo '-- SIM-TWIN-SORTER now falls back to the system defaults even though its row still exists'
select item->>'equipment_code' as code,
       item->'effective_profile'->>'source' as source,
       item->'effective_profile'->>'ack_delay_ms_max' as ack_max,
       item->'registered_profile'->>'status' as registered_status
from jsonb_array_elements(
  wms.wms_get_simulation_profile(:'tenant_a', :'wh_a', null)->'equipment') item
where item->>'equipment_code' = 'SIM-TWIN-SORTER';

\echo ''
\echo '=============================================================='
\echo '3. Planning (spec: 시뮬레이션 명령 계획 수립 / 어휘 매핑)'
\echo '=============================================================='

select pg_temp.act('wh-manager-a@demo.local');
set role authenticated;
select pg_temp.dispatch(:'agv', 'MOVE', '{"to_zone":"ZONE-TWIN-B"}'::jsonb, :'mgr_a') as dispatch_move;
select pg_temp.dispatch(:'real', 'MOVE', '{"to_zone":"ZONE-TWIN-C"}'::jsonb, :'mgr_a') as dispatch_on_real_equipment;
reset role;

select id as cmd_move from wms.equipment_commands where equipment_id = :'agv' order by created_at desc limit 1 \gset
select id as cmd_real from wms.equipment_commands where equipment_id = :'real' order by created_at desc limit 1 \gset

\echo '-- only WCS_GATEWAY may plan'
select pg_temp.act('wh-manager-a@demo.local');
set role authenticated;
select pg_temp.try(format('select wms.wms_plan_simulated_command(%L,%L,gen_random_uuid(),%L)',
  :'cmd_move', :'mgr_a', 'twin-sim')) as manager_cannot_plan;
reset role;

select pg_temp.act('wcs-gateway-a@demo.local');
set role authenticated;
select pg_temp.try(format('select wms.wms_plan_simulated_command(%L,%L,gen_random_uuid(),%L)',
  :'cmd_move', :'gw_a', 'twin-sim')) as plan_move;
\echo '-- idempotent: already_planned=true and no second row'
select pg_temp.try(format('select wms.wms_plan_simulated_command(%L,%L,gen_random_uuid(),%L)',
  :'cmd_move', :'gw_a', 'twin-sim')) as plan_move_again;
\echo '-- a command on non-simulated equipment cannot be planned at all'
select pg_temp.try(format('select wms.wms_plan_simulated_command(%L,%L,gen_random_uuid(),%L)',
  :'cmd_real', :'gw_a', 'twin-sim')) as plan_real_equipment;
reset role;

select count(*) as schedule_rows_for_move from wms.simulation_command_schedules where command_id = :'cmd_move';

\echo '-- vocabulary mapping: DIVERT gets the sortation words, MOVE the generic ones'
select pg_temp.act('wcs-operator-a@demo.local');
set role authenticated;
-- area 3 requires an ACTIVE sortation profile before a DIVERT is accepted
select pg_temp.try(format('select wms.wms_create_sortation_profile(%L,%s,%s,%s,%s,%L,gen_random_uuid(),%L,%L,%L)',
  :'sorter', 40, 0.5, 2.5, 50, :'op_a', 'FIXED', 'MPS', 'twin-sim')) as sortation_profile;
reset role;

select pg_temp.act('wcs-operator-a@demo.local');
set role authenticated;
select pg_temp.try(format('select wms.wms_update_simulation_profile(%L,%L,gen_random_uuid(),'
  || '(select version from wms.simulation_profiles where id = %L),'
  || '0,0,0,0,0,0,1,1,%L,%L)',
  :'profile_sorter', :'op_a', :'profile_sorter', 'ACTIVE', 'twin-sim')) as sorter_always_jams;
reset role;

select pg_temp.act('wh-manager-a@demo.local');
set role authenticated;
select pg_temp.dispatch(:'sorter', 'DIVERT',
  '{"target_chute":"CHUTE-01","item_identifier":"ITEM-TWIN-1"}'::jsonb, :'mgr_a') as dispatch_divert;
reset role;

select id as cmd_divert from wms.equipment_commands where equipment_id = :'sorter' order by created_at desc limit 1 \gset

select pg_temp.act('wcs-gateway-a@demo.local');
set role authenticated;
select pg_temp.try(format('select wms.wms_plan_simulated_command(%L,%L,gen_random_uuid(),%L)',
  :'cmd_divert', :'gw_a', 'twin-sim')) as plan_divert;
reset role;

select c.command_type, s.planned_terminal_status, s.planned_detail->>'outcome' as planned_outcome
from wms.simulation_command_schedules s join wms.equipment_commands c on c.id = s.command_id
order by c.command_type;

\echo ''
\echo '=============================================================='
\echo '4. Due actions (spec: 대기 중인 액션 조회 / 비대상 설비 배제)'
\echo '=============================================================='

\echo '-- as_of in the past: nothing has come due yet'
select pg_temp.act('wcs-gateway-a@demo.local');
set role authenticated;
select jsonb_pretty(jsonb_build_object(
  'due_count', d->'due_count', 'unplanned_count', d->'unplanned_count')) as before_due
from (select wms.wms_get_due_simulation_actions(:'tenant_a', :'wh_a', now() - interval '1 hour') d) x;

\echo '-- as_of = now: both plans are due (delays are 0), sorted by next_run_at'
select a->>'command_type' as command_type, a->>'next_status' as next_status
from jsonb_array_elements(
  wms.wms_get_due_simulation_actions(:'tenant_a', :'wh_a', now())->'due_actions') a;

\echo '-- the non-simulated AGV command appears in neither list'
select count(*) as real_equipment_entries
from jsonb_array_elements(
       wms.wms_get_due_simulation_actions(:'tenant_a', :'wh_a', now())->'due_actions'
       || wms.wms_get_due_simulation_actions(:'tenant_a', :'wh_a', now())->'unplanned_commands') a
where a->>'equipment_code' = 'SIM-TWIN-REAL';
reset role;

\echo '-- a non-gateway role cannot read the polling view at all'
select pg_temp.act('quality-a@demo.local');
set role authenticated;
select pg_temp.try(format('select wms.wms_get_due_simulation_actions(%L,%L,now())',
  :'tenant_a', :'wh_a')) as non_gateway_polling;
reset role;

\echo ''
\echo '=============================================================='
\echo '5. Advancing (spec: 시뮬레이션 명령 진행 보고)'
\echo '=============================================================='

select pg_temp.act('wcs-gateway-a@demo.local');
set role authenticated;
select pg_temp.try(format('select wms.wms_advance_simulated_command(%L,%L,gen_random_uuid(),%L)',
  :'cmd_move', :'gw_a', 'twin-sim')) as advance_1;
select next_status, planned_terminal_status from wms.simulation_command_schedules where command_id = :'cmd_move';
select pg_temp.try(format('select wms.wms_advance_simulated_command(%L,%L,gen_random_uuid(),%L)',
  :'cmd_move', :'gw_a', 'twin-sim')) as advance_2;
select pg_temp.try(format('select wms.wms_advance_simulated_command(%L,%L,gen_random_uuid(),%L)',
  :'cmd_move', :'gw_a', 'twin-sim')) as advance_3_terminal;
\echo '-- the plan is gone, so a fourth call has nothing to advance'
select pg_temp.try(format('select wms.wms_advance_simulated_command(%L,%L,gen_random_uuid(),%L)',
  :'cmd_move', :'gw_a', 'twin-sim')) as advance_without_plan;
reset role;

select status as move_command_status from wms.equipment_commands where id = :'cmd_move';
select event_type, detail->>'outcome' as outcome
from wms.equipment_status_events where command_id = :'cmd_move' order by seq;

\echo '-- JAM: the DIVERT plan is FAILED/JAM, and area 3''s escalation must fire'
select pg_temp.act('wcs-gateway-a@demo.local');
set role authenticated;
select pg_temp.try(format('select wms.wms_advance_simulated_command(%L,%L,gen_random_uuid(),%L)',
  :'cmd_divert', :'gw_a', 'twin-sim')) as divert_ack;
select pg_temp.try(format('select wms.wms_advance_simulated_command(%L,%L,gen_random_uuid(),%L)',
  :'cmd_divert', :'gw_a', 'twin-sim')) as divert_progress;
select pg_temp.try(format('select wms.wms_advance_simulated_command(%L,%L,gen_random_uuid(),%L)',
  :'cmd_divert', :'gw_a', 'twin-sim')) as divert_terminal;
reset role;

select c.status as divert_command_status, e.status as sorter_status
from wms.equipment_commands c join wms.equipment e on e.id = c.equipment_id where c.id = :'cmd_divert';
select fault_code, severity, status as fault_status from wms.equipment_faults;

\echo '-- a not-yet-due plan is refused'
select pg_temp.act('wh-manager-a@demo.local');
set role authenticated;
select pg_temp.try(format('select wms.wms_set_equipment_simulation_mode(%L,true,%L,gen_random_uuid(),'
  || '(select version from wms.equipment where id = %L),%L)', :'real', :'mgr_a', :'real', 'twin-sim'))
  as simulate_the_third_agv;
reset role;

select pg_temp.act('wcs-operator-a@demo.local');
set role authenticated;
select pg_temp.try(format('select wms.wms_register_simulation_profile(%L,60000,60000,0,0,0,0,0,%L,gen_random_uuid(),0,%L)',
  :'real', :'op_a', 'twin-sim')) as slow_profile;
reset role;

select pg_temp.act('wcs-gateway-a@demo.local');
set role authenticated;
select pg_temp.try(format('select wms.wms_plan_simulated_command(%L,%L,gen_random_uuid(),%L)',
  :'cmd_real', :'gw_a', 'twin-sim')) as plan_slow;
select pg_temp.try(format('select wms.wms_advance_simulated_command(%L,%L,gen_random_uuid(),%L)',
  :'cmd_real', :'gw_a', 'twin-sim')) as advance_not_due;
reset role;
select status as slow_command_status from wms.equipment_commands where id = :'cmd_real';

\echo '-- monitoring read: due_only filters the 60s-away plan out'
select jsonb_array_length(
  wms.wms_get_simulation_schedule_status(:'tenant_a', :'wh_a', null, false)->'schedules') as all_plans,
       jsonb_array_length(
  wms.wms_get_simulation_schedule_status(:'tenant_a', :'wh_a', null, true)->'schedules') as due_plans;

\echo ''
\echo '=============================================================='
\echo '6. Scenarios (spec: what-if 정의 / 실행과 예상 타임라인)'
\echo '=============================================================='

select count(*) as commands_before_scenarios from wms.equipment_commands \gset

select pg_temp.act('process-agent-a@demo.local');
set role authenticated;
select pg_temp.try(format('select wms.wms_create_simulation_scenario(%L,%L,%L,%s,%s,%L,gen_random_uuid(),%L,%L,null,%L)',
  :'tenant_a', :'wh_a', 'TWIN two-machine night shift',
  format('array[%L,%L]::uuid[]', :'agv', :'sorter'), 10,
  :'pa_a', 'EQUIPMENT_SUBSTITUTION', 'dispatch_wave', 'twin-sim')) as create_scenario;
\echo '-- empty equipment set / non-positive count / unknown equipment are refused'
select pg_temp.try(format('select wms.wms_create_simulation_scenario(%L,%L,%L,%s,%s,%L,gen_random_uuid(),%L,null,null,%L)',
  :'tenant_a', :'wh_a', 'TWIN empty', 'array[]::uuid[]', 5, :'pa_a', 'EQUIPMENT_SUBSTITUTION', 'twin-sim'))
  as empty_equipment_set;
select pg_temp.try(format('select wms.wms_create_simulation_scenario(%L,%L,%L,%s,%s,%L,gen_random_uuid(),%L,null,null,%L)',
  :'tenant_a', :'wh_a', 'TWIN zero', format('array[%L]::uuid[]', :'agv'), 0, :'pa_a', 'EQUIPMENT_SUBSTITUTION', 'twin-sim'))
  as zero_command_count;
select pg_temp.try(format('select wms.wms_create_simulation_scenario(%L,%L,%L,%s,%s,%L,gen_random_uuid(),%L,null,null,%L)',
  :'tenant_a', :'wh_a', 'TWIN foreign', 'array[gen_random_uuid()]::uuid[]', 5, :'pa_a', 'EQUIPMENT_SUBSTITUTION', 'twin-sim'))
  as unknown_equipment;
reset role;

select id as scenario from wms.simulation_scenarios where name = 'TWIN two-machine night shift' \gset

\echo '-- a role with no scenario rights is refused'
select pg_temp.act('quality-a@demo.local');
set role authenticated;
select pg_temp.try(format('select wms.wms_run_simulation_scenario(%L,%L,gen_random_uuid(),%L)',
  :'scenario', :'qual_a', 'twin-sim')) as quality_cannot_run;
reset role;

select pg_temp.act('process-agent-a@demo.local');
set role authenticated;
select pg_temp.try(format('select wms.wms_run_simulation_scenario(%L,%L,gen_random_uuid(),%L)',
  :'scenario', :'pa_a', 'twin-sim')) as run_1;
select pg_temp.try(format('select wms.wms_run_simulation_scenario(%L,%L,gen_random_uuid(),%L)',
  :'scenario', :'pa_a', 'twin-sim')) as run_2;
reset role;

select s.status as scenario_status, count(r.*) as run_count
from wms.simulation_scenarios s left join wms.simulation_scenario_runs r on r.scenario_id = s.id
where s.id = :'scenario' group by 1;

select projected_round_count, projected_duration_ms, projected_failure_count,
       assumptions->>'equipment_count' as machines,
       assumptions->>'mean_service_time_ms' as mean_ms,
       array_to_string(warnings, ' | ') as warnings
from wms.simulation_scenario_runs where scenario_id = :'scenario' order by created_at;

\echo '-- CRITICAL: running a scenario dispatched nothing'
select count(*) as commands_after_scenarios,
       (count(*) = :commands_before_scenarios) as unchanged
from wms.equipment_commands;

\echo ''
\echo '=============================================================='
\echo '7. RLS surface — no write grants, select scoped to the warehouse'
\echo '=============================================================='

select table_name, string_agg(privilege_type, ',' order by privilege_type) as grants
from information_schema.role_table_grants
where grantee in ('authenticated', 'anon') and table_schema = 'wms'
  and table_name in ('simulation_profiles','simulation_command_schedules',
                     'simulation_scenarios','simulation_scenario_runs')
group by table_name order by table_name;

select tablename, policyname, cmd
from pg_policies where schemaname = 'wms' and tablename like 'simulation%'
order by tablename;

\echo '-- tenant B sees none of tenant A''s simulation rows'
select pg_temp.act('admin-b@demo.local');
set role authenticated;
select (select count(*) from wms.simulation_profiles) as profiles,
       (select count(*) from wms.simulation_command_schedules) as schedules,
       (select count(*) from wms.simulation_scenarios) as scenarios,
       (select count(*) from wms.simulation_scenario_runs) as runs;
reset role;

\echo ''
\echo '=============================================================='
\echo '8. Audit trail (spec: 감사 추적)'
\echo '=============================================================='

select command, entity_type, count(*)
from wms.audit_events where command like 'wms_%simulat%'
group by 1,2 order by 1,2;

\echo '-- before/after are populated for a profile update'
select before->>'failure_rate' as before_failure_rate, after->>'failure_rate' as after_failure_rate
from wms.audit_events
where command = 'wms_update_simulation_profile' and entity_type = 'simulation_profile'
order by created_at limit 1;

\echo ''
\echo '=============================================================='
\echo 'DONE'
\echo '=============================================================='
