\set QUIET on
\pset pager off
\pset format aligned
\set ON_ERROR_STOP on

-- make the run repeatable without a full `supabase db reset`
truncate wms.equipment_status_events, wms.equipment_commands, wms.equipment_faults, wms.equipment
  restart identity cascade;
delete from wms.audit_events where command in (
  'wms_register_equipment','wms_dispatch_equipment_command','wms_report_command_result',
  'wms_report_equipment_status','wms_raise_equipment_fault','wms_resolve_equipment_fault',
  'wms_cancel_equipment_command');
delete from wms.idempotency_records where command_name in (
  'wms_register_equipment','wms_dispatch_equipment_command','wms_report_command_result',
  'wms_report_equipment_status','wms_raise_equipment_fault','wms_resolve_equipment_fault',
  'wms_cancel_equipment_command');

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

select id as admin_a from auth.users where email = 'admin-a@demo.local' \gset
select id as admin_b from auth.users where email = 'admin-b@demo.local' \gset
select id as op_a    from auth.users where email = 'wcs-operator-a@demo.local' \gset
select id as gw_a    from auth.users where email = 'wcs-gateway-a@demo.local' \gset
select id as pa_a    from auth.users where email = 'process-agent-a@demo.local' \gset
select id as qual_a  from auth.users where email = 'quality-a@demo.local' \gset

\set tenant_a '''10000000-0000-0000-0000-00000000000a'''
\set wh_a     '''20000000-0000-0000-0000-00000000000a'''
\set tenant_b '''10000000-0000-0000-0000-00000000000b'''
\set wh_b     '''20000000-0000-0000-0000-00000000000b'''

\set QUIET off

\echo '=============================================================='
\echo '1. REGISTER EQUIPMENT'
\echo '=============================================================='
select pg_temp.act('admin-a@demo.local');
set role authenticated;

\echo '-- 1.1 admin registers AGV-07 (expect OK, OFFLINE, v1)'
select pg_temp.try(format(
  'select wms.wms_register_equipment(%L,%L,%L,%L,%L,%L,%L,%L)',
  :tenant_a, :wh_a, 'AGV-07', 'AGV', 'ZONE-B', :'admin_a', gen_random_uuid(), 'corr-reg-1'));

\echo '-- 1.2 duplicate equipment_code in same warehouse (expect INVALID)'
select pg_temp.try(format(
  'select wms.wms_register_equipment(%L,%L,%L,%L,%L,%L,%L,null)',
  :tenant_a, :wh_a, 'AGV-07', 'AGV', 'ZONE-B', :'admin_a', gen_random_uuid()));

\echo '-- 1.3 bad equipment_type (expect INVALID)'
select pg_temp.try(format(
  'select wms.wms_register_equipment(%L,%L,%L,%L,%L,%L,%L,null)',
  :tenant_a, :wh_a, 'X-1', 'DRONE', 'ZONE-B', :'admin_a', gen_random_uuid()));

\echo '-- 1.4 second equipment SRM-02 for the fault scenario (expect OK)'
select pg_temp.try(format(
  'select wms.wms_register_equipment(%L,%L,%L,%L,%L,%L,%L,null)',
  :tenant_a, :wh_a, 'SRM-02', 'SRM', 'ZONE-A', :'admin_a', gen_random_uuid()));

\echo '-- 1.4b register idempotency retry (expect identical result, still 2 equipment)'
\set idem_reg '''aaaaaaaa-0000-0000-0000-00000000e001'''
select pg_temp.try(format(
  'select wms.wms_register_equipment(%L,%L,%L,%L,%L,%L,%L,null)',
  :tenant_a, :wh_a, 'CONV-09', 'CONVEYOR', 'ZONE-D', :'admin_a', :idem_reg));
select pg_temp.try(format(
  'select wms.wms_register_equipment(%L,%L,%L,%L,%L,%L,%L,null)',
  :tenant_a, :wh_a, 'CONV-09', 'CONVEYOR', 'ZONE-D', :'admin_a', :idem_reg));
reset role;
select count(*) as equipment_rows from wms.equipment;
select pg_temp.act('admin-a@demo.local');
set role authenticated;

\echo '-- 1.5 QUALITY_INSPECTOR tries to register (expect FORBIDDEN)'
reset role;
select pg_temp.act('quality-a@demo.local');
set role authenticated;
select pg_temp.try(format(
  'select wms.wms_register_equipment(%L,%L,%L,%L,%L,%L,%L,null)',
  :tenant_a, :wh_a, 'CONV-01', 'CONVEYOR', 'ZONE-C', :'qual_a', gen_random_uuid()));

\echo '-- 1.6 tenant-B admin registers into tenant-A warehouse (expect FORBIDDEN)'
reset role;
select pg_temp.act('admin-b@demo.local');
set role authenticated;
select pg_temp.try(format(
  'select wms.wms_register_equipment(%L,%L,%L,%L,%L,%L,%L,null)',
  :tenant_a, :wh_a, 'HACK-01', 'AGV', 'ZONE-B', :'admin_b', gen_random_uuid()));

reset role;
select id as agv from wms.equipment where equipment_code = 'AGV-07' \gset
select id as srm from wms.equipment where equipment_code = 'SRM-02' \gset

\echo '=============================================================='
\echo '2. EQUIPMENT STATUS REPORT (gateway)'
\echo '=============================================================='
select pg_temp.act('wcs-gateway-a@demo.local');
set role authenticated;

\echo '-- 2.1 gateway reports OFFLINE -> IDLE (expect OK, v2)'
select pg_temp.try(format(
  'select wms.wms_report_equipment_status(%L,%L,%L,%L,%s,%L,%L)',
  :'agv', 'IDLE', :'gw_a', gen_random_uuid(), 1, '{"boot":"ok"}', 'corr-st-1'));

\echo '-- 2.2 undefined status value (expect INVALID)'
select pg_temp.try(format(
  'select wms.wms_report_equipment_status(%L,%L,%L,%L,%s,null,null)',
  :'agv', 'UNKNOWN_STATE', :'gw_a', gen_random_uuid(), 2));

\echo '-- 2.3 wrong expected_version (expect CONFLICT)'
select pg_temp.try(format(
  'select wms.wms_report_equipment_status(%L,%L,%L,%L,%s,null,null)',
  :'agv', 'MAINTENANCE', :'gw_a', gen_random_uuid(), 99));

\echo '-- 2.4 SRM-02 online too (expect OK)'
select pg_temp.try(format(
  'select wms.wms_report_equipment_status(%L,%L,%L,%L,%s,null,null)',
  :'srm', 'IDLE', :'gw_a', gen_random_uuid(), 1));

\echo '-- 2.5 PROCESS_AGENT tries to report status (expect FORBIDDEN)'
reset role;
select pg_temp.act('process-agent-a@demo.local');
set role authenticated;
select pg_temp.try(format(
  'select wms.wms_report_equipment_status(%L,%L,%L,%L,%s,null,null)',
  :'agv', 'MAINTENANCE', :'pa_a', gen_random_uuid(), 2));

\echo '-- 2.5b WCS_OPERATOR can raise a fault manually, then resolve it (expect OK, OK)'
reset role;
select pg_temp.act('wcs-operator-a@demo.local');
set role authenticated;
select pg_temp.try(format(
  'select wms.wms_raise_equipment_fault(%L,%L,%L,%L,%L,null)',
  :'srm', 'MANUAL_CHECK', 'WARNING', :'op_a', gen_random_uuid()));
reset role;
select id as f0, version as f0_v from wms.equipment_faults where fault_code = 'MANUAL_CHECK' \gset
select pg_temp.act('wcs-operator-a@demo.local');
set role authenticated;
select pg_temp.try(format(
  'select wms.wms_resolve_equipment_fault(%L,%L,%L,%L,%s,null)',
  :'f0', 'false alarm', :'op_a', gen_random_uuid(), :f0_v));

\echo '-- 2.6 status event feed so far'
reset role;
select event_type, previous_status, new_status from wms.equipment_status_events order by created_at, id;

\echo '=============================================================='
\echo '3. DISPATCH COMMAND'
\echo '=============================================================='
select pg_temp.act('wcs-operator-a@demo.local');
set role authenticated;

\echo '-- 3.1 wrong expected_version (expect CONFLICT)'
select pg_temp.try(format(
  'select wms.wms_dispatch_equipment_command(%L,%L,%L::jsonb,%L,%L,%s,null,null,null)',
  :'agv', 'MOVE', '{"to_zone":"ZONE-C"}', :'op_a', gen_random_uuid(), 3));

\echo '-- 3.2 bad command_type (expect INVALID)'
select pg_temp.try(format(
  'select wms.wms_dispatch_equipment_command(%L,%L,%L::jsonb,%L,%L,%s,null,null,null)',
  :'agv', 'TELEPORT', '{}', :'op_a', gen_random_uuid(), 2));

\echo '-- 3.3 valid dispatch v2 (expect OK, PENDING, equipment -> RUNNING v3)'
\set idem_dispatch '''aaaaaaaa-0000-0000-0000-00000000d001'''
select pg_temp.try(format(
  'select wms.wms_dispatch_equipment_command(%L,%L,%L::jsonb,%L,%L,%s,%L,null,null)',
  :'agv', 'MOVE', '{"to_zone":"ZONE-C"}', :'op_a', :idem_dispatch, 2, 'corr-cmd-1'));

\echo '-- 3.4 SAME idempotency_key retry (expect identical result, no new row)'
select pg_temp.try(format(
  'select wms.wms_dispatch_equipment_command(%L,%L,%L::jsonb,%L,%L,%s,%L,null,null)',
  :'agv', 'MOVE', '{"to_zone":"ZONE-C"}', :'op_a', :idem_dispatch, 2, 'corr-cmd-1'));

\echo '-- 3.5 command row count for AGV-07 (expect exactly 1)'
reset role;
select count(*) as agv_commands from wms.equipment_commands where equipment_id = :'agv';
select status as agv_status, version as agv_version from wms.equipment where id = :'agv';
select id as cmd1 from wms.equipment_commands where equipment_id = :'agv' \gset

\echo '-- 3.6 tenant-B admin dispatches to tenant-A equipment (expect FORBIDDEN)'
select pg_temp.act('admin-b@demo.local');
set role authenticated;
select pg_temp.try(format(
  'select wms.wms_dispatch_equipment_command(%L,%L,%L::jsonb,%L,%L,%s,null,null,null)',
  :'agv', 'STOP', '{}', :'admin_b', gen_random_uuid(), 3));

\echo '=============================================================='
\echo '4. COMMAND RESULT REPORTING (gateway)'
\echo '=============================================================='
reset role;
select pg_temp.act('wcs-gateway-a@demo.local');
set role authenticated;

\echo '-- 4.1 ACKNOWLEDGED (cmd v1 -> v2)'
select pg_temp.try(format(
  'select wms.wms_report_command_result(%L,%L,%L,%L,%s,null,null)',
  :'cmd1', 'ACKNOWLEDGED', :'gw_a', gen_random_uuid(), 1));

\echo '-- 4.2 IN_PROGRESS (cmd v2 -> v3)'
select pg_temp.try(format(
  'select wms.wms_report_command_result(%L,%L,%L,%L,%s,%L,null)',
  :'cmd1', 'IN_PROGRESS', :'gw_a', gen_random_uuid(), 2, '{"pct":40}'));

\echo '-- 4.3 stale version (expect CONFLICT)'
select pg_temp.try(format(
  'select wms.wms_report_command_result(%L,%L,%L,%L,%s,null,null)',
  :'cmd1', 'COMPLETED', :'gw_a', gen_random_uuid(), 2));

\echo '-- 4.4 COMPLETED (cmd v3 -> v4, equipment RUNNING -> IDLE)'
select pg_temp.try(format(
  'select wms.wms_report_command_result(%L,%L,%L,%L,%s,null,%L)',
  :'cmd1', 'COMPLETED', :'gw_a', gen_random_uuid(), 3, 'corr-cmd-1'));

\echo '-- 4.5 report on terminal command (expect INVALID)'
select pg_temp.try(format(
  'select wms.wms_report_command_result(%L,%L,%L,%L,%s,null,null)',
  :'cmd1', 'FAILED', :'gw_a', gen_random_uuid(), 4));

\echo '-- 4.6 unknown command id (expect INVALID)'
select pg_temp.try(format(
  'select wms.wms_report_command_result(%L,%L,%L,%L,%s,null,null)',
  '00000000-0000-0000-0000-0000000000ff', 'COMPLETED', :'gw_a', gen_random_uuid(), 1));

\echo '-- 4.7 equipment should be IDLE again'
reset role;
select equipment_code, status, version from wms.equipment order by equipment_code;

\echo '=============================================================='
\echo '5. FAULT: raise -> in-flight command FAILED -> resolve -> IDLE'
\echo '=============================================================='
select pg_temp.act('wcs-operator-a@demo.local');
set role authenticated;

\echo '-- 5.1 dispatch LOAD to SRM-02 with linked receipt (expect OK)'
select v.version from wms.equipment v where v.id = :'srm' \gset srm0_
select pg_temp.try(format(
  'select wms.wms_dispatch_equipment_command(%L,%L,%L::jsonb,%L,%L,%s,%L,%L,%L)',
  :'srm', 'LOAD', '{"pallet":"P-9"}', :'op_a', gen_random_uuid(), :srm0_version, 'corr-fault-1',
  'receipt', '00000000-0000-0000-0000-0000000000aa'));

reset role;
select id as cmd2 from wms.equipment_commands where equipment_id = :'srm' \gset

select pg_temp.act('wcs-gateway-a@demo.local');
set role authenticated;
\echo '-- 5.2 gateway marks it IN_PROGRESS'
select pg_temp.try(format(
  'select wms.wms_report_command_result(%L,%L,%L,%L,%s,null,null)',
  :'cmd2', 'IN_PROGRESS', :'gw_a', gen_random_uuid(), 1));

\echo '-- 5.3 gateway raises MOTOR_OVERHEAT / CRITICAL (expect OK + failed_command_ids)'
select pg_temp.try(format(
  'select wms.wms_raise_equipment_fault(%L,%L,%L,%L,%L,%L)',
  :'srm', 'MOTOR_OVERHEAT', 'CRITICAL', :'gw_a', gen_random_uuid(), 'corr-fault-1'));

\echo '-- 5.4 bad severity (expect INVALID)'
select pg_temp.try(format(
  'select wms.wms_raise_equipment_fault(%L,%L,%L,%L,%L,null)',
  :'agv', 'X', 'CATASTROPHIC', :'gw_a', gen_random_uuid()));

\echo '-- 5.5 command should now be FAILED with fault_id, equipment FAULT'
reset role;
select c.status as cmd_status, c.fault_id is not null as linked_to_fault, c.reason
  from wms.equipment_commands c where c.id = :'cmd2';
select equipment_code, status, version from wms.equipment where id = :'srm';
select id as fault1, version as fault1_v from wms.equipment_faults
  where equipment_id = :'srm' and fault_code = 'MOTOR_OVERHEAT' \gset

\echo '-- 5.6 dispatch to FAULT equipment (expect INVALID)'
select pg_temp.act('wcs-operator-a@demo.local');
set role authenticated;
select v.version from wms.equipment v where v.id = :'srm' \gset srm_
select pg_temp.try(format(
  'select wms.wms_dispatch_equipment_command(%L,%L,%L::jsonb,%L,%L,%s,null,null,null)',
  :'srm', 'STOP', '{}', :'op_a', gen_random_uuid(), :srm_version));

\echo '-- 5.7 gateway tries to resolve the fault (expect FORBIDDEN)'
reset role;
select pg_temp.act('wcs-gateway-a@demo.local');
set role authenticated;
select pg_temp.try(format(
  'select wms.wms_resolve_equipment_fault(%L,%L,%L,%L,%s,null)',
  :'fault1', 'sensor replaced', :'gw_a', gen_random_uuid(), :fault1_v));

\echo '-- 5.8 operator resolves with empty note (expect INVALID)'
reset role;
select pg_temp.act('wcs-operator-a@demo.local');
set role authenticated;
select pg_temp.try(format(
  'select wms.wms_resolve_equipment_fault(%L,%L,%L,%L,%s,null)',
  :'fault1', '   ', :'op_a', gen_random_uuid(), :fault1_v));

\echo '-- 5.9 operator resolves with wrong version (expect CONFLICT)'
select pg_temp.try(format(
  'select wms.wms_resolve_equipment_fault(%L,%L,%L,%L,%s,null)',
  :'fault1', 'sensor replaced', :'op_a', gen_random_uuid(), 42));

\echo '-- 5.10 operator resolves properly (expect OK, equipment -> IDLE)'
select pg_temp.try(format(
  'select wms.wms_resolve_equipment_fault(%L,%L,%L,%L,%s,%L)',
  :'fault1', '센서 교체 완료', :'op_a', gen_random_uuid(), :fault1_v, 'corr-fault-1'));

\echo '-- 5.11 fault + equipment state'
reset role;
select status, resolution_note, resolved_by is not null as has_resolver, resolved_at is not null as has_ts
  from wms.equipment_faults where id = :'fault1';
select equipment_code, status, version from wms.equipment where id = :'srm';

\echo '=============================================================='
\echo '6. CANCEL COMMAND'
\echo '=============================================================='
select pg_temp.act('wcs-operator-a@demo.local');
set role authenticated;
select v.version from wms.equipment v where v.id = :'srm' \gset srm2_
\echo '-- 6.1 dispatch a new command to SRM-02'
select pg_temp.try(format(
  'select wms.wms_dispatch_equipment_command(%L,%L,%L::jsonb,%L,%L,%s,null,null,null)',
  :'srm', 'UNLOAD', '{}', :'op_a', gen_random_uuid(), :srm2_version));
reset role;
select id as cmd3 from wms.equipment_commands where equipment_id = :'srm' and command_type = 'UNLOAD' \gset

select pg_temp.act('wcs-operator-a@demo.local');
set role authenticated;
\echo '-- 6.2 cancel it (expect OK, CANCELLED, equipment back to IDLE)'
select pg_temp.try(format(
  'select wms.wms_cancel_equipment_command(%L,%L,%L,%s,%L,null)',
  :'cmd3', :'op_a', gen_random_uuid(), 1, 'operator abort'));

\echo '-- 6.3 cancel an already terminal command (expect INVALID)'
select pg_temp.try(format(
  'select wms.wms_cancel_equipment_command(%L,%L,%L,%s,null,null)',
  :'cmd1', :'op_a', gen_random_uuid(), 4));

\echo '-- 6.4 PROCESS_AGENT may cancel too (dispatch + cancel)'
reset role;
select pg_temp.act('process-agent-a@demo.local');
set role authenticated;
select v.version from wms.equipment v where v.id = :'agv' \gset agv2_
select pg_temp.try(format(
  'select wms.wms_dispatch_equipment_command(%L,%L,%L::jsonb,%L,%L,%s,null,null,null)',
  :'agv', 'HOLD', '{}', :'pa_a', gen_random_uuid(), :agv2_version));
reset role;
select id as cmd4 from wms.equipment_commands where equipment_id = :'agv' and command_type = 'HOLD' \gset
select pg_temp.act('process-agent-a@demo.local');
set role authenticated;
select pg_temp.try(format(
  'select wms.wms_cancel_equipment_command(%L,%L,%L,%s,null,null)',
  :'cmd4', :'pa_a', gen_random_uuid(), 1));

\echo '=============================================================='
\echo '7. READ-ONLY STATUS QUERY'
\echo '=============================================================='
reset role;
select pg_temp.act('wcs-operator-a@demo.local');
set role authenticated;
\echo '-- 7.1 operator queries warehouse A (expect 3 equipment, statuses + versions)'
select
  item->>'equipment_code' as code, item->>'status' as status, item->>'version' as version,
  item->>'has_active_command' as active, jsonb_array_length(item->'open_faults') as open_faults,
  jsonb_array_length(item->'recent_events') as recent_events
from jsonb_array_elements(wms.wms_get_equipment_status(:tenant_a::uuid, :wh_a::uuid, null, 3)->'equipment') item;

\echo '-- 7.1b single-equipment query with event detail'
select jsonb_pretty(wms.wms_get_equipment_status(:tenant_a::uuid, :wh_a::uuid, :'srm'::uuid, 3));

\echo '-- 7.2 tenant-B warehouse from a tenant-A user (expect FORBIDDEN)'
select pg_temp.try(format(
  'select wms.wms_get_equipment_status(%L,%L,null,3)', :tenant_b, :wh_b));

\echo '-- 7.3 direct table select honours RLS (tenant-B admin sees 0 rows)'
reset role;
select pg_temp.act('admin-b@demo.local');
set role authenticated;
select count(*) as visible_equipment_for_tenant_b from wms.equipment;
select count(*) as visible_commands_for_tenant_b from wms.equipment_commands;
select count(*) as visible_events_for_tenant_b from wms.equipment_status_events;
select count(*) as visible_faults_for_tenant_b from wms.equipment_faults;

\echo '-- 7.4 direct writes are denied to authenticated (expect ERR)'
reset role;
select pg_temp.act('admin-a@demo.local');
set role authenticated;
select pg_temp.try(format(
  'insert into wms.equipment (tenant_id, warehouse_id, equipment_code, equipment_type) values (%L,%L,%L,%L) returning to_jsonb(id)',
  :tenant_a, :wh_a, 'DIRECT-1', 'AGV'));
select pg_temp.try(format('update wms.equipment set status = %L where id = %L returning to_jsonb(id)', 'IDLE', :'agv'));
select pg_temp.try(format('delete from wms.equipment where id = %L returning to_jsonb(id)', :'agv'));

\echo '=============================================================='
\echo '8. GRANT / AUDIT CHECKS'
\echo '=============================================================='
reset role;
\echo '-- 8.1 table privileges granted to authenticated/anon (expect SELECT only)'
select table_name, string_agg(distinct privilege_type, ',' order by privilege_type) as privs, grantee
from information_schema.role_table_grants
where table_schema = 'wms'
  and table_name in ('equipment','equipment_commands','equipment_status_events','equipment_faults')
  and grantee in ('authenticated','anon')
group by table_name, grantee order by table_name, grantee;

\echo '-- 8.2 audit coverage per command (all 7 write RPCs must appear)'
select command, entity_type, count(*)
from wms.audit_events
where command in ('wms_register_equipment','wms_dispatch_equipment_command','wms_report_command_result',
                  'wms_report_equipment_status','wms_raise_equipment_fault','wms_resolve_equipment_fault',
                  'wms_cancel_equipment_command')
group by command, entity_type order by command, entity_type;

\echo '-- 8.3 fault resolution audit before/after'
select before->>'status' as before_status, after->>'status' as after_status
from wms.audit_events where command = 'wms_resolve_equipment_fault';

\echo '-- 8.4 linked-entity audit event from command result reporting'
select command, entity_type, entity_id, after->>'command_status' as cmd_status
from wms.audit_events where entity_type = 'receipt' and command = 'wms_report_command_result';

\echo '-- 8.5 full event feed (deterministic order via seq)'
select s.seq, e.equipment_code, s.event_type, s.previous_status, s.new_status
from wms.equipment_status_events s join wms.equipment e on e.id = s.equipment_id
order by s.seq;
