\set QUIET on
\pset pager off
\pset format aligned
\set ON_ERROR_STOP on

-- ============================================================
-- wms_wcs-sortation-logic — psql simulator / verification script
-- (supabase/migrations/20260729_wcs_sortation_logic.sql)
--
-- Drives the sortation contract exactly the way a real caller would: it
-- impersonates the seeded demo users by setting request.jwt.claims and
-- `set role authenticated`, so auth.uid(), wms.current_warehouse_ids() and
-- wms.has_role() behave as they do for a real Supabase session.
--
-- The equipment side (WCS_GATEWAY) is the same software-simulator idea as
-- openspec/specs/wms_wcs-equipment-control/e2e/simulator.sql — no hardware,
-- no PLC. Everything a real sorter gateway would call is called here.
-- ============================================================

-- make the run repeatable without a full `supabase db reset`
truncate wms.sortation_profiles restart identity cascade;
truncate wms.work_orders, wms.dispatch_waves restart identity cascade;
truncate wms.equipment_status_events, wms.equipment_commands, wms.equipment_faults, wms.equipment
  restart identity cascade;
delete from wms.audit_events where command in (
  'wms_create_sortation_profile','wms_update_sortation_profile',
  'wms_register_equipment','wms_dispatch_equipment_command','wms_report_command_result',
  'wms_report_equipment_status','wms_cancel_equipment_command',
  'wms_raise_equipment_fault','wms_resolve_equipment_fault');
delete from wms.idempotency_records where command_name in (
  'wms_create_sortation_profile','wms_update_sortation_profile',
  'wms_register_equipment','wms_dispatch_equipment_command','wms_report_command_result',
  'wms_report_equipment_status','wms_cancel_equipment_command',
  'wms_raise_equipment_fault','wms_resolve_equipment_fault');

-- helper: run a statement and report OK/ERR instead of aborting
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

-- dispatch helper: always reads the equipment's *current* version, so the
-- script never has to track optimistic-concurrency counters by hand.
create or replace function pg_temp.dispatch(p_equipment uuid, p_type text, p_payload jsonb, p_actor uuid)
returns text language plpgsql as $fn$
begin
  return pg_temp.try(format(
    'select wms.wms_dispatch_equipment_command(%L,%L,%L::jsonb,%L,gen_random_uuid(),'
    || '(select version from wms.equipment where id = %L),%L,null,null)',
    p_equipment, p_type, p_payload::text, p_actor, p_equipment, 'sortation-sim'));
end
$fn$;

-- gateway feedback helper: reports one status transition for a command.
create or replace function pg_temp.report(p_command uuid, p_status text, p_detail jsonb, p_actor uuid)
returns text language plpgsql as $fn$
begin
  return pg_temp.try(format(
    'select wms.wms_report_command_result(%L,%L,%L,gen_random_uuid(),'
    || '(select version from wms.equipment_commands where id = %L),%s,%L)',
    p_command, p_status, p_actor, p_command,
    case when p_detail is null then 'null' else quote_literal(p_detail::text) || '::jsonb' end,
    'sortation-sim'));
end
$fn$;

\set tenant_a '10000000-0000-0000-0000-00000000000a'
\set tenant_b '10000000-0000-0000-0000-00000000000b'
\set wh_a     '20000000-0000-0000-0000-00000000000a'
\set wh_b     '20000000-0000-0000-0000-00000000000b'

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
\echo '0. FIXTURE — two sorters, one conveyor, one AGV (wrong type)'
\echo '=============================================================='

select pg_temp.act('wh-manager-a@demo.local');
set role authenticated;
select pg_temp.try(format(
  'select wms.wms_register_equipment(%L,%L,%L,%L,%L,%L,gen_random_uuid(),%L)',
  :'tenant_a', :'wh_a', 'SIM-SORTER-01', 'SORTER', 'ZONE-SIM', :'mgr_a', 'sortation-sim')) as register_sorter01;
select pg_temp.try(format(
  'select wms.wms_register_equipment(%L,%L,%L,%L,%L,%L,gen_random_uuid(),%L)',
  :'tenant_a', :'wh_a', 'SIM-SORTER-02', 'SORTER', 'ZONE-SIM', :'mgr_a', 'sortation-sim')) as register_sorter02;
select pg_temp.try(format(
  'select wms.wms_register_equipment(%L,%L,%L,%L,%L,%L,gen_random_uuid(),%L)',
  :'tenant_a', :'wh_a', 'SIM-CONV-01', 'CONVEYOR', 'ZONE-SIM', :'mgr_a', 'sortation-sim')) as register_conveyor;
select pg_temp.try(format(
  'select wms.wms_register_equipment(%L,%L,%L,%L,%L,%L,gen_random_uuid(),%L)',
  :'tenant_a', :'wh_a', 'SIM-AGV-01', 'AGV', 'ZONE-SIM', :'mgr_a', 'sortation-sim')) as register_agv;
reset role;

select id as sorter1 from wms.equipment where equipment_code = 'SIM-SORTER-01' \gset
select id as sorter2 from wms.equipment where equipment_code = 'SIM-SORTER-02' \gset
select id as conv1   from wms.equipment where equipment_code = 'SIM-CONV-01' \gset
select id as agv1    from wms.equipment where equipment_code = 'SIM-AGV-01' \gset

-- the gateway boots all four so they are dispatchable
select pg_temp.act('wcs-gateway-a@demo.local');
set role authenticated;
select pg_temp.try(format('select wms.wms_report_equipment_status(%L,%L,%L,gen_random_uuid(),1,null,%L)',
  :'sorter1', 'IDLE', :'gw_a', 'sortation-sim')) as boot_sorter01;
select pg_temp.try(format('select wms.wms_report_equipment_status(%L,%L,%L,gen_random_uuid(),1,null,%L)',
  :'sorter2', 'IDLE', :'gw_a', 'sortation-sim')) as boot_sorter02;
select pg_temp.try(format('select wms.wms_report_equipment_status(%L,%L,%L,gen_random_uuid(),1,null,%L)',
  :'conv1', 'IDLE', :'gw_a', 'sortation-sim')) as boot_conveyor;
select pg_temp.try(format('select wms.wms_report_equipment_status(%L,%L,%L,gen_random_uuid(),1,null,%L)',
  :'agv1', 'IDLE', :'gw_a', 'sortation-sim')) as boot_agv;
reset role;

\echo ''
\echo '=============================================================='
\echo '1. Profile registration (spec: 분류 설비 프로파일 등록)'
\echo '=============================================================='

select pg_temp.act('wh-manager-a@demo.local');
set role authenticated;
\echo '  happy path — SORTER gets a profile'
select pg_temp.try(format(
  'select wms.wms_create_sortation_profile(%L,150,0.5,2.0,80,%L,gen_random_uuid(),%L,%L,%L)',
  :'sorter1', :'mgr_a', 'FIXED', 'MPS', 'sortation-sim')) as create_profile_sorter01;
\echo '  a CONVEYOR is equally valid'
select pg_temp.try(format(
  'select wms.wms_create_sortation_profile(%L,200,0.2,1.0,120,%L,gen_random_uuid(),%L,%L,%L)',
  :'conv1', :'mgr_a', 'AUTO', 'MPS', 'sortation-sim')) as create_profile_conveyor;
\echo '  refusals'
select pg_temp.try(format(
  'select wms.wms_create_sortation_profile(%L,150,0.5,2.0,80,%L,gen_random_uuid(),%L,%L,null)',
  :'agv1', :'mgr_a', 'FIXED', 'MPS')) as create_profile_on_agv;
select pg_temp.try(format(
  'select wms.wms_create_sortation_profile(%L,150,0.5,2.0,80,%L,gen_random_uuid(),%L,%L,null)',
  :'sorter1', :'mgr_a', 'FIXED', 'MPS')) as create_profile_duplicate;
select pg_temp.try(format(
  'select wms.wms_create_sortation_profile(%L,0,0.5,2.0,80,%L,gen_random_uuid(),%L,%L,null)',
  :'sorter2', :'mgr_a', 'FIXED', 'MPS')) as create_profile_zero_gap;
select pg_temp.try(format(
  'select wms.wms_create_sortation_profile(%L,150,3.0,2.0,80,%L,gen_random_uuid(),%L,%L,null)',
  :'sorter2', :'mgr_a', 'FIXED', 'MPS')) as create_profile_inverted_range;
select pg_temp.try(format(
  'select wms.wms_create_sortation_profile(%L,150,0.5,2.0,0,%L,gen_random_uuid(),%L,%L,null)',
  :'sorter2', :'mgr_a', 'FIXED', 'MPS')) as create_profile_zero_window;
select pg_temp.try(format(
  'select wms.wms_create_sortation_profile(%L,150,0.5,2.0,80,%L,gen_random_uuid(),%L,%L,null)',
  :'sorter2', :'mgr_a', 'TURBO', 'MPS')) as create_profile_bad_mode;
reset role;

\echo '  SIM-SORTER-02 is deliberately left WITHOUT a profile:'
select e.equipment_code, e.equipment_type, (p.id is not null) as has_profile
from wms.equipment e left join wms.sortation_profiles p on p.equipment_id = e.id
where e.equipment_code like 'SIM-%' order by e.equipment_code;

\echo ''
\echo '  role / tenant refusals'
select pg_temp.act('quality-a@demo.local');
set role authenticated;
select pg_temp.try(format(
  'select wms.wms_create_sortation_profile(%L,150,0.5,2.0,80,%L,gen_random_uuid(),%L,%L,null)',
  :'sorter2', :'qual_a', 'FIXED', 'MPS')) as create_profile_as_quality;
reset role;
select pg_temp.act('admin-b@demo.local');
set role authenticated;
select pg_temp.try(format(
  'select wms.wms_create_sortation_profile(%L,150,0.5,2.0,80,%L,gen_random_uuid(),%L,%L,null)',
  :'sorter2', :'admin_b', 'FIXED', 'MPS')) as create_profile_cross_tenant;
select count(*) as tenant_b_sees_profiles from wms.sortation_profiles;
reset role;

\echo ''
\echo '=============================================================='
\echo '2. Profile update (spec: 분류 설비 프로파일 갱신)'
\echo '=============================================================='

select id as profile1 from wms.sortation_profiles where equipment_id = :'sorter1' \gset

select pg_temp.act('wcs-operator-a@demo.local');
set role authenticated;
\echo '  WCS_OPERATOR widens the speed range with the right version'
select pg_temp.try(format(
  'select wms.wms_update_sortation_profile(%L,%L,gen_random_uuid(),1,null,null,null,2.5,null,null,null,%L)',
  :'profile1', :'op_a', 'sortation-sim')) as update_max_speed;
\echo '  stale version'
select pg_temp.try(format(
  'select wms.wms_update_sortation_profile(%L,%L,gen_random_uuid(),1,null,null,null,3.0,null,null,null,null)',
  :'profile1', :'op_a')) as update_stale_version;
\echo '  inverted range'
select pg_temp.try(format(
  'select wms.wms_update_sortation_profile(%L,%L,gen_random_uuid(),2,null,null,9.0,null,null,null,null,null)',
  :'profile1', :'op_a')) as update_inverted_range;
select pg_temp.try(format(
  'select wms.wms_update_sortation_profile(%L,%L,gen_random_uuid(),2,null,null,null,null,null,null,%L,null)',
  :'profile1', :'op_a', 'PAUSED')) as update_bad_status;
reset role;

select min_carton_gap_mm, speed_mode, min_speed_value, max_speed_value, speed_unit,
       sensor_detection_window_ms, status, version
from wms.sortation_profiles where id = :'profile1';

\echo ''
\echo '=============================================================='
\echo '3. DIVERT payload validation (spec: Divert 명령 payload 계약)'
\echo '=============================================================='

select pg_temp.act('wh-manager-a@demo.local');
set role authenticated;
\echo '  happy path'
select pg_temp.dispatch(:'sorter1', 'DIVERT',
  '{"target_chute":"CHUTE-12","item_identifier":"BC-0001","expected_gap_mm":160}'::jsonb, :'mgr_a') as divert_ok;
\echo '  refusals'
select pg_temp.dispatch(:'sorter1', 'DIVERT',
  '{"target_chute":"CHUTE-12"}'::jsonb, :'mgr_a') as divert_missing_item;
select pg_temp.dispatch(:'sorter1', 'DIVERT',
  '{"item_identifier":"BC-0002"}'::jsonb, :'mgr_a') as divert_missing_chute;
select pg_temp.dispatch(:'sorter1', 'DIVERT',
  '{"target_chute":"CHUTE-12","item_identifier":"BC-0003","expected_gap_mm":-5}'::jsonb, :'mgr_a') as divert_bad_gap;
select pg_temp.dispatch(:'sorter2', 'DIVERT',
  '{"target_chute":"CHUTE-01","item_identifier":"BC-0004"}'::jsonb, :'mgr_a') as divert_no_profile;
select pg_temp.dispatch(:'agv1', 'DIVERT',
  '{"target_chute":"CHUTE-01","item_identifier":"BC-0005"}'::jsonb, :'mgr_a') as divert_wrong_type;
reset role;

select c.command_type, c.status, c.payload
from wms.equipment_commands c where c.equipment_id = :'sorter1' order by c.created_at;

\echo ''
\echo '=============================================================='
\echo '4. SET_SPEED payload + profile range (spec: 속도 조정 명령 …)'
\echo '=============================================================='

select pg_temp.act('wh-manager-a@demo.local');
set role authenticated;
\echo '  inside the profile range (0.5 .. 2.5 MPS)'
select pg_temp.dispatch(:'sorter1', 'SET_SPEED',
  '{"speed_mode":"FIXED","speed_value":1.8,"speed_unit":"MPS"}'::jsonb, :'mgr_a') as set_speed_ok;
\echo '  AUTO delegates to the equipment — no speed_value needed (design.md D8)'
select pg_temp.dispatch(:'sorter1', 'SET_SPEED',
  '{"speed_mode":"AUTO","speed_unit":"MPS"}'::jsonb, :'mgr_a') as set_speed_auto;
\echo '  refusals'
select pg_temp.dispatch(:'sorter1', 'SET_SPEED',
  '{"speed_mode":"FIXED","speed_value":3.5,"speed_unit":"MPS"}'::jsonb, :'mgr_a') as set_speed_above_max;
select pg_temp.dispatch(:'sorter1', 'SET_SPEED',
  '{"speed_mode":"FIXED","speed_value":0.1,"speed_unit":"MPS"}'::jsonb, :'mgr_a') as set_speed_below_min;
select pg_temp.dispatch(:'sorter1', 'SET_SPEED',
  '{"speed_mode":"FIXED","speed_value":1.0,"speed_unit":"FPM"}'::jsonb, :'mgr_a') as set_speed_unit_mismatch;
select pg_temp.dispatch(:'sorter1', 'SET_SPEED',
  '{"speed_mode":"FIXED","speed_unit":"MPS"}'::jsonb, :'mgr_a') as set_speed_fixed_without_value;
select pg_temp.dispatch(:'sorter1', 'SET_SPEED',
  '{"speed_mode":"CRUISE","speed_unit":"MPS"}'::jsonb, :'mgr_a') as set_speed_bad_mode;
select pg_temp.dispatch(:'sorter2', 'SET_SPEED',
  '{"speed_mode":"AUTO","speed_unit":"MPS"}'::jsonb, :'mgr_a') as set_speed_no_profile;
reset role;

\echo ''
\echo '  an INACTIVE profile is treated like no profile at all (design.md 데이터 모델)'
select id as profile_conv from wms.sortation_profiles where equipment_id = :'conv1' \gset
select pg_temp.act('wh-manager-a@demo.local');
set role authenticated;
select pg_temp.try(format(
  'select wms.wms_update_sortation_profile(%L,%L,gen_random_uuid(),1,null,null,null,null,null,null,%L,null)',
  :'profile_conv', :'mgr_a', 'INACTIVE')) as deactivate_conveyor_profile;
select pg_temp.dispatch(:'conv1', 'DIVERT',
  '{"target_chute":"CHUTE-99","item_identifier":"BC-9999"}'::jsonb, :'mgr_a') as divert_inactive_profile;
select pg_temp.try(format(
  'select wms.wms_update_sortation_profile(%L,%L,gen_random_uuid(),2,null,null,null,null,null,null,%L,null)',
  :'profile_conv', :'mgr_a', 'ACTIVE')) as reactivate_conveyor_profile;
reset role;

\echo ''
\echo '=============================================================='
\echo '5. Outcome <-> command status consistency (spec: 분류 결과 보고 …)'
\echo '=============================================================='

select id as div1 from wms.equipment_commands
  where equipment_id = :'sorter1' and command_type = 'DIVERT' order by created_at limit 1 \gset

select pg_temp.act('wcs-gateway-a@demo.local');
set role authenticated;
select pg_temp.report(:'div1', 'ACKNOWLEDGED', null, :'gw_a') as ack;
select pg_temp.report(:'div1', 'IN_PROGRESS', null, :'gw_a') as in_progress;
\echo '  inconsistent reports are refused'
select pg_temp.report(:'div1', 'COMPLETED', '{"outcome":"MISROUTE"}'::jsonb, :'gw_a') as completed_with_misroute;
select pg_temp.report(:'div1', 'FAILED', '{"outcome":"SUCCESS"}'::jsonb, :'gw_a') as failed_with_success;
select pg_temp.report(:'div1', 'COMPLETED', '{"outcome":"PARTIAL"}'::jsonb, :'gw_a') as completed_with_unknown;
\echo '  the consistent one goes through'
select pg_temp.report(:'div1', 'COMPLETED', '{"outcome":"SUCCESS","actual_chute":"CHUTE-12"}'::jsonb, :'gw_a') as completed_with_success;
reset role;

select status, (select detail->>'outcome' from wms.equipment_status_events s
                where s.command_id = c.id and s.detail ? 'outcome' order by s.seq desc limit 1) as outcome
from wms.equipment_commands c where c.id = :'div1';

\echo ''
\echo '  MISROUTE fails the command but never faults the machine (design.md D5)'
select pg_temp.act('wh-manager-a@demo.local');
set role authenticated;
select pg_temp.dispatch(:'sorter1', 'DIVERT',
  '{"target_chute":"CHUTE-07","item_identifier":"BC-0100"}'::jsonb, :'mgr_a') as divert_for_misroute;
reset role;
select id as div2 from wms.equipment_commands
  where equipment_id = :'sorter1' and command_type = 'DIVERT'
  and payload->>'item_identifier' = 'BC-0100' \gset
select pg_temp.act('wcs-gateway-a@demo.local');
set role authenticated;
select pg_temp.report(:'div2', 'FAILED', '{"outcome":"MISROUTE","actual_chute":"CHUTE-08"}'::jsonb, :'gw_a') as misroute_report;
reset role;
select
  (select status from wms.equipment_commands where id = :'div2') as command_status,
  (select status from wms.equipment where id = :'sorter1') as equipment_status,
  (select count(*) from wms.equipment_faults where equipment_id = :'sorter1') as faults_raised;

\echo ''
\echo '=============================================================='
\echo '6. JAM auto-escalation (spec: 잼(JAM) 결과의 자동 장애 승격)'
\echo '=============================================================='

select pg_temp.act('wh-manager-a@demo.local');
set role authenticated;
\echo '  one DIVERT that will jam, plus a second command left PENDING'
select pg_temp.dispatch(:'sorter1', 'DIVERT',
  '{"target_chute":"CHUTE-03","item_identifier":"BC-0200"}'::jsonb, :'mgr_a') as divert_for_jam;
select pg_temp.dispatch(:'sorter1', 'SET_SPEED',
  '{"speed_mode":"FIXED","speed_value":1.2,"speed_unit":"MPS"}'::jsonb, :'mgr_a') as pending_set_speed;
reset role;

select id as div3 from wms.equipment_commands
  where equipment_id = :'sorter1' and payload->>'item_identifier' = 'BC-0200' \gset
select id as spd1 from wms.equipment_commands
  where equipment_id = :'sorter1' and command_type = 'SET_SPEED' and status = 'PENDING'
  order by created_at desc limit 1 \gset

select pg_temp.act('wcs-gateway-a@demo.local');
set role authenticated;
select pg_temp.report(:'div3', 'IN_PROGRESS', null, :'gw_a') as jam_in_progress;
select pg_temp.report(:'div3', 'FAILED', '{"outcome":"JAM","reason":"CARTON_STUCK"}'::jsonb, :'gw_a') as jam_report;
reset role;

\echo '  the machine faulted and BOTH commands are FAILED and linked to the fault'
select
  (select status from wms.equipment where id = :'sorter1') as equipment_status,
  (select status from wms.equipment_commands where id = :'div3') as jammed_command,
  (select status from wms.equipment_commands where id = :'spd1') as other_command,
  (select fault_code from wms.equipment_faults where equipment_id = :'sorter1' and status = 'OPEN') as fault_code,
  (select severity from wms.equipment_faults where equipment_id = :'sorter1' and status = 'OPEN') as severity,
  (select count(distinct fault_id) from wms.equipment_commands
     where id in (:'div3', :'spd1') and fault_id is not null) as distinct_faults_linked,
  (select count(*) from wms.equipment_commands
     where id in (:'div3', :'spd1') and fault_id is not null) as commands_linked;

\echo '  no new command is accepted while the sorter is in FAULT'
select pg_temp.act('wh-manager-a@demo.local');
set role authenticated;
select pg_temp.dispatch(:'sorter1', 'DIVERT',
  '{"target_chute":"CHUTE-01","item_identifier":"BC-0300"}'::jsonb, :'mgr_a') as divert_while_faulted;
reset role;

\echo '  a human clears the jam through area 1''s existing procedure'
select id as fault1, version as fault1_v from wms.equipment_faults
  where equipment_id = :'sorter1' and status = 'OPEN' \gset
select pg_temp.act('wcs-operator-a@demo.local');
set role authenticated;
select pg_temp.try(format(
  'select wms.wms_resolve_equipment_fault(%L,%L,%L,gen_random_uuid(),%s,%L)',
  :'fault1', '카톤 제거 및 벨트 재기동 완료', :'op_a', :'fault1_v', 'sortation-sim')) as resolve_jam;
reset role;
select
  (select status from wms.equipment where id = :'sorter1') as equipment_status,
  (select status from wms.equipment_faults where id = :'fault1') as fault_status;

\echo ''
\echo '=============================================================='
\echo '7. Roles, tenants, RLS/grants'
\echo '=============================================================='

\echo '  DEVIATION 2 reproduction — WMS_ADMIN may tune a profile but may NOT'
\echo '  dispatch, because the shipped wms_dispatch_equipment_command excludes it.'
select pg_temp.act('admin-a@demo.local');
set role authenticated;
select pg_temp.try(format(
  'select wms.wms_create_sortation_profile(%L,180,0.4,1.6,90,%L,gen_random_uuid(),%L,%L,%L)',
  :'sorter2', :'admin_a', 'FIXED', 'MPS', 'sortation-sim')) as admin_create_profile;
select pg_temp.dispatch(:'sorter2', 'DIVERT',
  '{"target_chute":"CHUTE-05","item_identifier":"BC-0400"}'::jsonb, :'admin_a') as admin_dispatch_divert;
reset role;

\echo '  the same DIVERT from a dispatch-capable role goes through'
select pg_temp.act('wcs-operator-a@demo.local');
set role authenticated;
select pg_temp.dispatch(:'sorter2', 'DIVERT',
  '{"target_chute":"CHUTE-05","item_identifier":"BC-0400"}'::jsonb, :'op_a') as operator_dispatch_divert;
reset role;

\echo '  role lists side by side, extracted from the shipped function bodies'
select p.proname,
       (select string_agg(distinct m[1], ',' order by m[1])
        from regexp_matches(pg_get_functiondef(p.oid),
             '''(WMS_ADMIN|WAREHOUSE_MANAGER|WCS_OPERATOR|PROCESS_AGENT|WCS_GATEWAY)''', 'g') m) as roles
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'wms'
  and p.proname in ('wms_create_sortation_profile','wms_update_sortation_profile',
                    'wms_dispatch_equipment_command','wms_report_command_result',
                    'wms_raise_equipment_fault','wms_resolve_equipment_fault')
order by p.proname;

\echo ''
\echo '  grants on the new table: SELECT only, authenticated only'
select grantee, privilege_type from information_schema.role_table_grants
where table_schema = 'wms' and table_name = 'sortation_profiles'
order by grantee, privilege_type;

select pg_temp.act('wh-manager-a@demo.local');
set role authenticated;
select pg_temp.try('insert into wms.sortation_profiles (tenant_id, warehouse_id, equipment_id, min_carton_gap_mm, min_speed_value, max_speed_value, sensor_detection_window_ms) values (gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), 1, 1, 2, 1) returning to_jsonb(1)') as direct_insert;
select pg_temp.try('update wms.sortation_profiles set min_carton_gap_mm = 1 returning to_jsonb(1)') as direct_update;
select pg_temp.try('delete from wms.sortation_profiles returning to_jsonb(1)') as direct_delete;
reset role;

\echo '  tenant B sees nothing and is refused on the read RPC'
select pg_temp.act('admin-b@demo.local');
set role authenticated;
select count(*) as tenant_b_row_count from wms.sortation_profiles;
select pg_temp.try(format('select wms.wms_get_sortation_profile(%L,%L,null)', :'tenant_a', :'wh_a')) as tenant_b_reads_a;
reset role;

\echo ''
\echo '=============================================================='
\echo '8. Idempotency'
\echo '=============================================================='

-- a brand new conveyor, so the first call really creates something
select gen_random_uuid() as idem \gset
select pg_temp.act('wh-manager-a@demo.local');
set role authenticated;
select pg_temp.try(format(
  'select wms.wms_register_equipment(%L,%L,%L,%L,%L,%L,gen_random_uuid(),%L)',
  :'tenant_a', :'wh_a', 'SIM-CONV-02', 'CONVEYOR', 'ZONE-SIM', :'mgr_a', 'sortation-sim')) as register_conveyor02;
reset role;
select id as conv2 from wms.equipment where equipment_code = 'SIM-CONV-02' \gset

select pg_temp.act('wh-manager-a@demo.local');
set role authenticated;
select pg_temp.try(format(
  'select wms.wms_create_sortation_profile(%L,150,0.5,2.0,80,%L,%L,%L,%L,null)',
  :'conv2', :'mgr_a', :'idem', 'FIXED', 'MPS')) as replay_call_1;
select pg_temp.try(format(
  'select wms.wms_create_sortation_profile(%L,150,0.5,2.0,80,%L,%L,%L,%L,null)',
  :'conv2', :'mgr_a', :'idem', 'FIXED', 'MPS')) as replay_call_2;
reset role;
select count(*) as conveyor02_profiles from wms.sortation_profiles where equipment_id = :'conv2';

\echo ''
\echo '=============================================================='
\echo '9. Read model + audit coverage'
\echo '=============================================================='

select pg_temp.act('wh-manager-a@demo.local');
set role authenticated;
select jsonb_pretty(wms.wms_get_sortation_profile(:'tenant_a', :'wh_a', :'sorter1')) as read_model_sorter01;
reset role;

select item->>'equipment_code' as equipment_code,
       item->>'has_profile' as has_profile,
       item->'profile'->>'speed_mode' as speed_mode,
       item->'profile'->>'min_speed_value' as min_speed,
       item->'profile'->>'max_speed_value' as max_speed,
       item->'profile'->>'status' as profile_status,
       item->>'last_outcome' as last_outcome
from jsonb_array_elements(wms.wms_get_sortation_profile(:'tenant_a', :'wh_a', null)->'items') item;

select command, entity_type, count(*) as events
from wms.audit_events
where command in ('wms_create_sortation_profile','wms_update_sortation_profile',
                  'wms_escalate_sortation_jam',
                  'wms_raise_equipment_fault','wms_resolve_equipment_fault')
group by command, entity_type
order by command, entity_type;

\echo '  the auto escalation row carries the equipment transition (spec: 감사 추적)'
select command, entity_type,
       before->>'equipment_status' as before_status,
       after->>'equipment_status' as after_status,
       after->>'fault_code' as fault_code,
       after->>'outcome' as outcome
from wms.audit_events
where command = 'wms_escalate_sortation_jam'
order by created_at;

\echo ''
\echo 'simulator finished.'
