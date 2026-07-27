\set QUIET on
\pset pager off
\pset format aligned
\set ON_ERROR_STOP on

-- ============================================================
-- wms_wes-material-flow-control — psql simulator / verification script
-- (supabase/migrations/20260728_wes_material_flow_control.sql)
--
-- Drives the WES middleware exactly the way a real caller would: it
-- impersonates the seeded demo users by setting request.jwt.claims and
-- `set role authenticated`, so auth.uid(), wms.current_warehouse_ids() and
-- wms.has_role() behave as they do for a real Supabase session.
--
-- The equipment side (WCS_GATEWAY) is the same software simulator idea as
-- openspec/specs/wms_wcs-equipment-control/e2e/simulator.sql — no hardware.
-- ============================================================

-- make the run repeatable without a full `supabase db reset`
truncate wms.work_orders, wms.dispatch_waves restart identity cascade;
truncate wms.equipment_status_events, wms.equipment_commands, wms.equipment_faults, wms.equipment
  restart identity cascade;
delete from wms.audit_events where command in (
  'wms_open_dispatch_wave','wms_create_work_order','wms_dispatch_work_order',
  'wms_release_dispatch_wave','wms_retry_work_order_dispatch','wms_cancel_work_order',
  'wms_propagate_command_result',
  'wms_register_equipment','wms_dispatch_equipment_command','wms_report_command_result',
  'wms_report_equipment_status','wms_cancel_equipment_command','wms_raise_equipment_fault');
delete from wms.idempotency_records where command_name in (
  'wms_open_dispatch_wave','wms_create_work_order','wms_release_dispatch_wave',
  'wms_retry_work_order_dispatch','wms_cancel_work_order',
  'wms_register_equipment','wms_dispatch_equipment_command','wms_report_command_result',
  'wms_report_equipment_status','wms_cancel_equipment_command');

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
select id as buyer_a from auth.users where email = 'buyer-a@demo.local' \gset
select id as appr_a  from auth.users where email = 'approver-a@demo.local' \gset
select id as qual_a  from auth.users where email = 'quality-a@demo.local' \gset

\set QUIET off
\echo ''
\echo '=============================================================='
\echo '0. FIXTURE — a receipt to hang work orders off, and two AGVs'
\echo '=============================================================='

-- The only WMS-side intent this contract knows today is a receipt
-- (design.md "정직한 전제 확인"), so make one through the real inbound RPCs.
select pg_temp.act('buyer-a@demo.local');
set role authenticated;
select wms.wms_create_rfq(:'tenant_a', :'wh_a', 'SKU-A-001', 40, null, :'buyer_a', gen_random_uuid(), 'wes-sim')->>'po_id' as po \gset
reset role;
select pg_temp.act('approver-a@demo.local');
set role authenticated;
select wms.wms_submit_purchase_approval(:'po', 'APPROVE', :'appr_a', 1, null)->>'version' as po_v \gset
reset role;
select pg_temp.act('buyer-a@demo.local');
set role authenticated;
select wms.wms_confirm_purchase_order(:'po', :'buyer_a', gen_random_uuid(), (:'po_v')::int)->>'receipt_id' as receipt \gset
reset role;
\echo '  receipt fixture:'
select :'receipt' as receipt_id, status from wms.receipts where id = :'receipt';

-- Two identical AGVs in ZONE-B so the flow-balancing rule has a real choice,
-- plus one in ZONE-Z that must never be picked for ZONE-B work.
select pg_temp.act('wh-manager-a@demo.local');
set role authenticated;
select pg_temp.try(format(
  'select wms.wms_register_equipment(%L,%L,%L,%L,%L,%L,gen_random_uuid(),%L)',
  :'tenant_a', :'wh_a', 'AGV-07', 'AGV', 'ZONE-B', :'mgr_a', 'wes-sim')) as register_agv07;
select pg_temp.try(format(
  'select wms.wms_register_equipment(%L,%L,%L,%L,%L,%L,gen_random_uuid(),%L)',
  :'tenant_a', :'wh_a', 'AGV-08', 'AGV', 'ZONE-B', :'mgr_a', 'wes-sim')) as register_agv08;
select pg_temp.try(format(
  'select wms.wms_register_equipment(%L,%L,%L,%L,%L,%L,gen_random_uuid(),%L)',
  :'tenant_a', :'wh_a', 'AGV-99', 'AGV', 'ZONE-Z', :'mgr_a', 'wes-sim')) as register_agv99;
reset role;

select id as agv07 from wms.equipment where equipment_code = 'AGV-07' \gset
select id as agv08 from wms.equipment where equipment_code = 'AGV-08' \gset
select id as agv99 from wms.equipment where equipment_code = 'AGV-99' \gset

-- gateway boots all three
select pg_temp.act('wcs-gateway-a@demo.local');
set role authenticated;
select pg_temp.try(format('select wms.wms_report_equipment_status(%L,%L,%L,gen_random_uuid(),1,null,%L)',
  :'agv07', 'IDLE', :'gw_a', 'wes-sim')) as boot_agv07;
select pg_temp.try(format('select wms.wms_report_equipment_status(%L,%L,%L,gen_random_uuid(),1,null,%L)',
  :'agv08', 'IDLE', :'gw_a', 'wes-sim')) as boot_agv08;
select pg_temp.try(format('select wms.wms_report_equipment_status(%L,%L,%L,gen_random_uuid(),1,null,%L)',
  :'agv99', 'IDLE', :'gw_a', 'wes-sim')) as boot_agv99;
reset role;

select equipment_code, equipment_type, zone_code, status, version from wms.equipment order by equipment_code;

\echo ''
\echo '=============================================================='
\echo '1. WAVELESS happy path — register, auto-dispatch, gateway'
\echo '   completes, work order follows to COMPLETED (spec: "설비'
\echo '   명령 결과의 업무 오더 반영")'
\echo '=============================================================='

select pg_temp.act('wh-manager-a@demo.local');
set role authenticated;
select wms.wms_create_work_order(
  :'tenant_a', :'wh_a', 'PUTAWAY', 'receipt', :'receipt',
  'AGV', 'ZONE-B', 'MOVE', '{"to_zone":"ZONE-C"}'::jsonb, 'WAVELESS',
  :'mgr_a', gen_random_uuid(), null, 'wes-sim') as waveless_create \gset wl_
reset role;
\echo '  create_work_order (WAVELESS):'
select :'wl_waveless_create'::jsonb as result;
select (:'wl_waveless_create'::jsonb)->>'work_order_id' as wo1 \gset
select (:'wl_waveless_create'::jsonb)->'links'->>'equipment_command_id' as cmd1 \gset

select wo.status as wo_status, wo.version as wo_version, c.status as cmd_status,
       c.linked_entity_type, e.equipment_code
from wms.work_orders wo
join wms.equipment_commands c on c.id = wo.equipment_command_id
join wms.equipment e on e.id = c.equipment_id
where wo.id = :'wo1';

\echo '  gateway walks the command ACKNOWLEDGED -> IN_PROGRESS -> COMPLETED:'
select pg_temp.act('wcs-gateway-a@demo.local');
set role authenticated;
select pg_temp.try(format('select wms.wms_report_command_result(%L,%L,%L,gen_random_uuid(),1,null,%L)',
  :'cmd1', 'ACKNOWLEDGED', :'gw_a', 'wes-sim')) as ack;
select pg_temp.try(format('select wms.wms_report_command_result(%L,%L,%L,gen_random_uuid(),2,null,%L)',
  :'cmd1', 'IN_PROGRESS', :'gw_a', 'wes-sim')) as progress;
select pg_temp.try(format('select wms.wms_report_command_result(%L,%L,%L,gen_random_uuid(),3,%L,%L)',
  :'cmd1', 'COMPLETED', :'gw_a', '{"travelled_m": 42}', 'wes-sim')) as complete;
reset role;

\echo '  work order auto-transitioned by the propagation trigger:'
select status, version, updated_by = :'gw_a' as updated_by_gateway
from wms.work_orders where id = :'wo1';

\echo '  ...and the linked receipt is deliberately UNCHANGED (Non-Goal):'
select status as receipt_status, version as receipt_version from wms.receipts where id = :'receipt';

\echo '  audit row written by the trigger:'
select command, entity_type, before->>'status' as before_status, after->>'status' as after_status, correlation_id
from wms.audit_events where command = 'wms_propagate_command_result' and entity_id = :'wo1';

\echo ''
\echo '=============================================================='
\echo '2. Flow balancing (design.md D5) — fewest recent COMPLETED wins,'
\echo '   busy equipment is excluded, zone mismatch is excluded'
\echo '=============================================================='

-- AGV-07 now has 1 recent COMPLETED command, AGV-08 has 0 -> AGV-08 must win.
select pg_temp.act('wh-manager-a@demo.local');
set role authenticated;
select wms.wms_create_work_order(
  :'tenant_a', :'wh_a', 'PUTAWAY', 'receipt', :'receipt',
  'AGV', 'ZONE-B', 'MOVE', '{"to_zone":"ZONE-C"}'::jsonb, 'WAVELESS',
  :'mgr_a', gen_random_uuid(), null, 'wes-sim') as r \gset bal_
reset role;
select (:'bal_r'::jsonb)->>'work_order_id' as wo2 \gset
\echo '  least-loaded candidate chosen:'
select (:'bal_r'::jsonb)->>'status' as wo_status,
       (:'bal_r'::jsonb)->'links'->>'equipment_code' as chosen_equipment;

-- AGV-08 is now busy (PENDING command) and AGV-07 is free again, so the next
-- ZONE-B work order must land on AGV-07.
select pg_temp.act('wh-manager-a@demo.local');
set role authenticated;
select wms.wms_create_work_order(
  :'tenant_a', :'wh_a', 'PUTAWAY', 'receipt', :'receipt',
  'AGV', 'ZONE-B', 'MOVE', '{"to_zone":"ZONE-D"}'::jsonb, 'WAVELESS',
  :'mgr_a', gen_random_uuid(), null, 'wes-sim') as r \gset bal2_
reset role;
select (:'bal2_r'::jsonb)->>'work_order_id' as wo3 \gset
\echo '  busy equipment excluded — the other idle candidate is used:'
select (:'bal2_r'::jsonb)->>'status' as wo_status,
       (:'bal2_r'::jsonb)->'links'->>'equipment_code' as chosen_equipment;

-- Both ZONE-B AGVs are busy now; AGV-99 sits IDLE in ZONE-Z and must be
-- ignored -> NO_EQUIPMENT_AVAILABLE, work order stays QUEUED.
select pg_temp.act('wh-manager-a@demo.local');
set role authenticated;
select wms.wms_create_work_order(
  :'tenant_a', :'wh_a', 'PUTAWAY', 'receipt', :'receipt',
  'AGV', 'ZONE-B', 'MOVE', '{"to_zone":"ZONE-E"}'::jsonb, 'WAVELESS',
  :'mgr_a', gen_random_uuid(), null, 'wes-sim') as r \gset nofit_
reset role;
select (:'nofit_r'::jsonb)->>'work_order_id' as wo4 \gset
\echo '  no candidate (all ZONE-B busy, ZONE-Z ignored):'
select (:'nofit_r'::jsonb)->>'status' as wo_status,
       (:'nofit_r'::jsonb)->'warnings' as warnings,
       (:'nofit_r'::jsonb)->'next_actions' as next_actions;

-- an equipment_type with no equipment at all in this warehouse
select pg_temp.act('wh-manager-a@demo.local');
set role authenticated;
select wms.wms_create_work_order(
  :'tenant_a', :'wh_a', 'PUTAWAY', 'receipt', :'receipt',
  'ROBOT_CELL', null, 'LOAD', '{}'::jsonb, 'WAVELESS',
  :'mgr_a', gen_random_uuid(), null, 'wes-sim') as r \gset norobot_
reset role;
select (:'norobot_r'::jsonb)->>'work_order_id' as wo5 \gset
\echo '  no ROBOT_CELL registered at all:'
select (:'norobot_r'::jsonb)->>'status' as wo_status, (:'norobot_r'::jsonb)->'warnings' as warnings;

\echo ''
\echo '=============================================================='
\echo '3. Retry — QUEUED becomes dispatchable once equipment frees up;'
\echo '   a DISPATCHED work order cannot be retried'
\echo '=============================================================='

-- free AGV-08 by completing its command
select id as cmd2 from wms.equipment_commands
  where equipment_id = :'agv08' and status = 'PENDING' order by created_at desc limit 1 \gset
select pg_temp.act('wcs-gateway-a@demo.local');
set role authenticated;
select pg_temp.try(format('select wms.wms_report_command_result(%L,%L,%L,gen_random_uuid(),1,null,%L)',
  :'cmd2', 'COMPLETED', :'gw_a', 'wes-sim')) as free_agv08;
reset role;

select version as wo4_v from wms.work_orders where id = :'wo4' \gset
select pg_temp.act('wh-manager-a@demo.local');
set role authenticated;
select pg_temp.try(format('select wms.wms_retry_work_order_dispatch(%L,%L,gen_random_uuid(),%s,%L)',
  :'wo4', :'mgr_a', :'wo4_v', 'wes-sim')) as retry_now_succeeds;
select pg_temp.try(format('select wms.wms_retry_work_order_dispatch(%L,%L,gen_random_uuid(),%s,%L)',
  :'wo4', :'mgr_a', (:'wo4_v')::int + 1, 'wes-sim')) as retry_already_dispatched;
select pg_temp.try(format('select wms.wms_retry_work_order_dispatch(%L,%L,gen_random_uuid(),%s,%L)',
  :'wo5', :'mgr_a', 99, 'wes-sim')) as retry_stale_version;
reset role;

\echo ''
\echo '=============================================================='
\echo '4. WAVE path — open, queue 3, release; only the available'
\echo '   equipment gets work, the rest stay QUEUED with a warning'
\echo '=============================================================='

select pg_temp.act('wh-manager-a@demo.local');
set role authenticated;
select wms.wms_open_dispatch_wave(:'tenant_a', :'wh_a', :'mgr_a', gen_random_uuid(), 'wes-sim') as r \gset wave_
reset role;
select (:'wave_r'::jsonb)->>'wave_id' as wave1 \gset
\echo '  wave opened:'
select (:'wave_r'::jsonb)->>'status' as wave_status, (:'wave_r'::jsonb)->>'version' as wave_version,
       (:'wave_r'::jsonb)->'next_actions' as next_actions;

-- free both ZONE-B AGVs first so exactly 2 of the 3 wave orders can go out
select pg_temp.act('wcs-gateway-a@demo.local');
set role authenticated;
select pg_temp.try(format(
         'select wms.wms_report_command_result(%L,%L,%L,gen_random_uuid(),%s,null,%L)',
         c.id, 'COMPLETED', :'gw_a', c.version, 'wes-sim')) as drain_in_flight_commands
from wms.equipment_commands c
where c.status in ('PENDING','ACKNOWLEDGED','IN_PROGRESS');
reset role;

select pg_temp.act('wh-manager-a@demo.local');
set role authenticated;
select wms.wms_create_work_order(:'tenant_a', :'wh_a', 'PUTAWAY', 'receipt', :'receipt',
  'AGV', 'ZONE-B', 'MOVE', '{"slot":1}'::jsonb, 'WAVE', :'mgr_a', gen_random_uuid(), :'wave1', 'wes-sim') as r \gset w1_
select wms.wms_create_work_order(:'tenant_a', :'wh_a', 'PUTAWAY', 'receipt', :'receipt',
  'AGV', 'ZONE-B', 'MOVE', '{"slot":2}'::jsonb, 'WAVE', :'mgr_a', gen_random_uuid(), :'wave1', 'wes-sim') as r \gset w2_
select wms.wms_create_work_order(:'tenant_a', :'wh_a', 'PUTAWAY', 'receipt', :'receipt',
  'AGV', 'ZONE-B', 'MOVE', '{"slot":3}'::jsonb, 'WAVE', :'mgr_a', gen_random_uuid(), :'wave1', 'wes-sim') as r \gset w3_
reset role;
\echo '  all three queued, nothing dispatched yet:'
select (:'w1_r'::jsonb)->>'status' as wo1_status, (:'w2_r'::jsonb)->>'status' as wo2_status,
       (:'w3_r'::jsonb)->>'status' as wo3_status,
       (select count(*) from wms.work_orders where wave_id = :'wave1' and equipment_command_id is not null) as dispatched_commands;

\echo '  release:'
select pg_temp.act('wh-manager-a@demo.local');
set role authenticated;
select wms.wms_release_dispatch_wave(:'wave1', :'mgr_a', gen_random_uuid(), 1, 'wes-sim') as r \gset rel_
reset role;
select (:'rel_r'::jsonb)->>'status' as wave_status,
       (:'rel_r'::jsonb)->>'dispatched_count' as dispatched_count,
       (:'rel_r'::jsonb)->>'queued_count' as queued_count,
       (:'rel_r'::jsonb)->'warnings' as warnings;
select (:'rel_r'::jsonb)->'work_orders' as per_work_order;

\echo '  negative: re-release, and a stale expected_version:'
select pg_temp.act('wh-manager-a@demo.local');
set role authenticated;
select pg_temp.try(format('select wms.wms_release_dispatch_wave(%L,%L,gen_random_uuid(),2,%L)',
  :'wave1', :'mgr_a', 'wes-sim')) as release_twice;
select pg_temp.try(format('select wms.wms_open_dispatch_wave(%L,%L,%L,gen_random_uuid(),%L)',
  :'tenant_a', :'wh_a', :'mgr_a', 'wes-sim')) as open_second_wave;
reset role;
select id as wave2 from wms.dispatch_waves where status = 'OPEN' order by created_at desc limit 1 \gset
select pg_temp.act('wh-manager-a@demo.local');
set role authenticated;
select pg_temp.try(format('select wms.wms_release_dispatch_wave(%L,%L,gen_random_uuid(),7,%L)',
  :'wave2', :'mgr_a', 'wes-sim')) as release_stale_version;
select status as wave2_status_unchanged from wms.dispatch_waves where id = :'wave2';
\echo '  negative: a RELEASED wave cannot take new work orders:'
select pg_temp.try(format(
  'select wms.wms_create_work_order(%L,%L,%L,%L,%L,%L,%L,%L,%L::jsonb,%L,%L,gen_random_uuid(),%L,%L)',
  :'tenant_a', :'wh_a', 'PUTAWAY', 'receipt', :'receipt', 'AGV', 'ZONE-B', 'MOVE', '{}', 'WAVE',
  :'mgr_a', :'wave1', 'wes-sim')) as create_into_released_wave;
select pg_temp.try(format(
  'select wms.wms_create_work_order(%L,%L,%L,%L,%L,%L,%L,%L,%L::jsonb,%L,%L,gen_random_uuid(),%L,%L)',
  :'tenant_a', :'wh_a', 'PUTAWAY', 'receipt', :'receipt', 'AGV', 'ZONE-B', 'MOVE', '{}', 'WAVE',
  :'mgr_a', '00000000-0000-0000-0000-0000000000ff', 'wes-sim')) as create_into_unknown_wave;
select pg_temp.try(format(
  'select wms.wms_create_work_order(%L,%L,%L,%L,%L,%L,%L,%L,%L::jsonb,%L,%L,gen_random_uuid(),null,%L)',
  :'tenant_a', :'wh_a', 'PUTAWAY', 'receipt', :'receipt', 'AGV', 'ZONE-B', 'MOVE', '{}', 'WAVE',
  :'mgr_a', 'wes-sim')) as wave_mode_without_wave_id;
reset role;

\echo ''
\echo '=============================================================='
\echo '5. Cancellation — QUEUED cancels outright, DISPATCHED cascades'
\echo '   into the linked equipment command, terminal is refused'
\echo '=============================================================='

select id as wo_q, version as wo_q_v from wms.work_orders
  where wave_id = :'wave1' and status = 'QUEUED' limit 1 \gset
select id as wo_d, version as wo_d_v, equipment_command_id as wo_d_cmd from wms.work_orders
  where wave_id = :'wave1' and status = 'DISPATCHED' limit 1 \gset

select version as wo1_v from wms.work_orders where id = :'wo1' \gset

select pg_temp.act('wh-manager-a@demo.local');
set role authenticated;
select pg_temp.try(format('select wms.wms_cancel_work_order(%L,%L,gen_random_uuid(),%s,%L,%L)',
  :'wo_q', :'mgr_a', :'wo_q_v', 'shift ended', 'wes-sim')) as cancel_queued;
select pg_temp.try(format('select wms.wms_cancel_work_order(%L,%L,gen_random_uuid(),%s,%L,%L)',
  :'wo_d', :'mgr_a', :'wo_d_v', 'aisle blocked', 'wes-sim')) as cancel_dispatched;
select pg_temp.try(format('select wms.wms_cancel_work_order(%L,%L,gen_random_uuid(),%s,%L,%L)',
  :'wo1', :'mgr_a', :'wo1_v', 'too late', 'wes-sim')) as cancel_completed_refused;
select pg_temp.try(format('select wms.wms_cancel_work_order(%L,%L,gen_random_uuid(),%s,%L,%L)',
  :'wo_q', :'mgr_a', 99, 'stale', 'wes-sim')) as cancel_stale_version;
reset role;

\echo '  cancellation cascaded into the equipment command:'
select wo.status as work_order_status, c.status as command_status, c.reason, e.status as equipment_status
from wms.work_orders wo
join wms.equipment_commands c on c.id = wo.equipment_command_id
join wms.equipment e on e.id = c.equipment_id
where wo.id = :'wo_d';

\echo ''
\echo '=============================================================='
\echo '6. FAILED propagation, and commands that are none of our'
\echo '   business (spec: "업무 오더와 무관한 설비 명령 결과")'
\echo '=============================================================='

select id as wo_f, equipment_command_id as cmd_f from wms.work_orders
  where status = 'DISPATCHED' limit 1 \gset
select version as cmd_f_v from wms.equipment_commands where id = :'cmd_f' \gset
select pg_temp.act('wcs-gateway-a@demo.local');
set role authenticated;
select pg_temp.try(format('select wms.wms_report_command_result(%L,%L,%L,gen_random_uuid(),%s,%L,%L)',
  :'cmd_f', 'FAILED', :'gw_a', :'cmd_f_v', '{"reason":"OBSTACLE_DETECTED"}', 'wes-sim')) as report_failed;
reset role;
select status, reason from wms.work_orders where id = :'wo_f';

\echo '  a command linked to a receipt (not a work order) touches no work order:'
select count(*) as propagations_before from wms.audit_events
  where command = 'wms_propagate_command_result' \gset
select pg_temp.act('wh-manager-a@demo.local');
set role authenticated;
select version as agv99_v from wms.equipment where id = :'agv99' \gset
select wms.wms_dispatch_equipment_command(:'agv99', 'MOVE', '{}'::jsonb, :'mgr_a', gen_random_uuid(),
  (:'agv99_v')::int, 'wes-sim', 'receipt', :'receipt')->>'command_id' as cmd_r \gset
reset role;
select pg_temp.act('wcs-gateway-a@demo.local');
set role authenticated;
select pg_temp.try(format('select wms.wms_report_command_result(%L,%L,%L,gen_random_uuid(),1,null,%L)',
  :'cmd_r', 'COMPLETED', :'gw_a', 'wes-sim')) as unrelated_command_completed;
reset role;
\echo '  no work order was updated by that (propagation audit rows unchanged):'
select :propagations_before as propagations_before,
       (select count(*) from wms.audit_events where command = 'wms_propagate_command_result') as propagations_after,
       (select count(*) from wms.work_orders where equipment_command_id = :'cmd_r') as work_orders_referencing_that_command;

\echo ''
\echo '=============================================================='
\echo '7. Roles and tenants'
\echo '=============================================================='

\echo '  QUALITY_INSPECTOR has none of the four WES roles:'
select pg_temp.act('quality-a@demo.local');
set role authenticated;
select pg_temp.try(format('select wms.wms_open_dispatch_wave(%L,%L,%L,gen_random_uuid(),null)',
  :'tenant_a', :'wh_a', :'qual_a')) as quality_open_wave;
select pg_temp.try(format(
  'select wms.wms_create_work_order(%L,%L,%L,%L,%L,%L,%L,%L,%L::jsonb,%L,%L,gen_random_uuid(),null,null)',
  :'tenant_a', :'wh_a', 'PUTAWAY', 'receipt', :'receipt', 'AGV', 'ZONE-B', 'MOVE', '{}', 'WAVELESS',
  :'qual_a')) as quality_create_work_order;
reset role;

\echo '  PROCESS_AGENT and WCS_OPERATOR are allowed (design.md D3/D4):'
select pg_temp.act('process-agent-a@demo.local');
set role authenticated;
select pg_temp.try(format('select wms.wms_open_dispatch_wave(%L,%L,%L,gen_random_uuid(),null)',
  :'tenant_a', :'wh_a', :'pa_a')) as process_agent_open_wave;
reset role;
select pg_temp.act('wcs-operator-a@demo.local');
set role authenticated;
select pg_temp.try(format('select wms.wms_open_dispatch_wave(%L,%L,%L,gen_random_uuid(),null)',
  :'tenant_a', :'wh_a', :'op_a')) as operator_open_wave;
reset role;

\echo '  D3 ROLE-SET CHECK (tasks.md 3.9) — WMS_ADMIN is NOT in the shipped'
\echo '  wms_dispatch_equipment_command role list, so it is deliberately kept'
\echo '  out of this contract too. Reproduction of the mismatch:'
select pg_temp.act('admin-a@demo.local');
set role authenticated;
select version as agv07_v from wms.equipment where id = :'agv07' \gset
select pg_temp.try(format('select wms.wms_dispatch_equipment_command(%L,%L,%L::jsonb,%L,gen_random_uuid(),%s,null,null,null)',
  :'agv07', 'MOVE', '{}', :'admin_a', :'agv07_v')) as admin_dispatch_equipment_command;
select pg_temp.try(format('select wms.wms_open_dispatch_wave(%L,%L,%L,gen_random_uuid(),null)',
  :'tenant_a', :'wh_a', :'admin_a')) as admin_open_dispatch_wave;
reset role;

\echo '  role sets, side by side:'
select p.proname,
       (select string_agg(x, ',' order by x) from regexp_matches(
          pg_get_functiondef(p.oid), 'has_role\([^,]+, ((?:''[A-Z_]+''(?:, )?)+)\)') m,
        lateral regexp_split_to_table(replace(m[1], '''', ''), ', ') x) as roles
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'wms'
  and p.proname in ('wms_dispatch_equipment_command','wms_cancel_equipment_command',
                    'wms_open_dispatch_wave','wms_create_work_order','wms_release_dispatch_wave',
                    'wms_retry_work_order_dispatch','wms_cancel_work_order')
order by p.proname;

\echo '  cross-tenant: tenant B admin cannot see or cancel tenant A work orders:'
select pg_temp.act('admin-b@demo.local');
set role authenticated;
select count(*) as tenant_b_sees_work_orders from wms.work_orders;
select count(*) as tenant_b_sees_waves from wms.dispatch_waves;
select pg_temp.try(format('select wms.wms_cancel_work_order(%L,%L,gen_random_uuid(),1,null,null)',
  :'wo5', :'admin_b')) as tenant_b_cancel_tenant_a_work_order;
select pg_temp.try(format('select wms.wms_get_work_order_status(%L,%L,null)',
  :'tenant_a', :'wh_a')) as tenant_b_reads_tenant_a;
reset role;

\echo ''
\echo '=============================================================='
\echo '8. Idempotency'
\echo '=============================================================='

select pg_temp.act('wh-manager-a@demo.local');
set role authenticated;
select gen_random_uuid() as idem \gset
select wms.wms_create_work_order(:'tenant_a', :'wh_a', 'PUTAWAY', 'receipt', :'receipt',
  'AMR', 'ZONE-B', 'MOVE', '{}'::jsonb, 'WAVELESS', :'mgr_a', :'idem', null, 'wes-sim') as r \gset i1_
select wms.wms_create_work_order(:'tenant_a', :'wh_a', 'PUTAWAY', 'receipt', :'receipt',
  'AMR', 'ZONE-B', 'MOVE', '{}'::jsonb, 'WAVELESS', :'mgr_a', :'idem', null, 'wes-sim') as r \gset i2_
select gen_random_uuid() as idem_w \gset
select pg_temp.try(format('select wms.wms_open_dispatch_wave(%L,%L,%L,%L,null)',
  :'tenant_a', :'wh_a', :'mgr_a', :'idem_w')) as open_wave_first;
select pg_temp.try(format('select wms.wms_open_dispatch_wave(%L,%L,%L,%L,null)',
  :'tenant_a', :'wh_a', :'mgr_a', :'idem_w')) as open_wave_replay;
reset role;
select (:'i1_r'::jsonb) = (:'i2_r'::jsonb) as identical_response,
       (select count(*) from wms.work_orders where equipment_type = 'AMR') as amr_work_orders_created;

\echo ''
\echo '=============================================================='
\echo '9. RLS / grants — SELECT only, writes go through the RPCs'
\echo '=============================================================='

select table_name, grantee, string_agg(privilege_type, ',' order by privilege_type) as privileges
from information_schema.role_table_grants
where table_schema = 'wms' and table_name in ('work_orders','dispatch_waves')
  and grantee in ('authenticated','anon')
group by table_name, grantee
order by table_name, grantee;

select pg_temp.act('wh-manager-a@demo.local');
set role authenticated;
select pg_temp.try(format(
  'insert into wms.work_orders (tenant_id, warehouse_id, work_order_type, linked_entity_type, linked_entity_id, equipment_type, command_type, dispatch_mode) values (%L,%L,%L,%L,%L,%L,%L,%L) returning to_jsonb(id)',
  :'tenant_a', :'wh_a', 'PUTAWAY', 'receipt', :'receipt', 'AGV', 'MOVE', 'WAVELESS')) as direct_insert;
select pg_temp.try(format('update wms.work_orders set status = ''COMPLETED'' where id = %L returning to_jsonb(id)',
  :'wo5')) as direct_update;
select pg_temp.try(format('delete from wms.dispatch_waves where id = %L returning to_jsonb(id)',
  :'wave2')) as direct_delete;
reset role;

\echo ''
\echo '=============================================================='
\echo '10. Read model + audit coverage'
\echo '=============================================================='

select pg_temp.act('wh-manager-a@demo.local');
set role authenticated;
select jsonb_pretty(jsonb_build_object(
  'waves', wms.wms_get_work_order_status(:'tenant_a', :'wh_a', null)->'waves',
  'count', wms.wms_get_work_order_status(:'tenant_a', :'wh_a', null)->'count')) as read_model_waves;
reset role;

select item->>'status' as status, item->>'dispatch_mode' as dispatch_mode,
       item->>'has_equipment_command' as has_command,
       item->'equipment_command'->>'status' as command_status,
       item->'equipment_command'->>'equipment_code' as equipment_code
from jsonb_array_elements(wms.wms_get_work_order_status(:'tenant_a', :'wh_a', null)->'work_orders') item;

select command, entity_type, count(*) as events
from wms.audit_events
where command in ('wms_open_dispatch_wave','wms_create_work_order','wms_dispatch_work_order',
                  'wms_release_dispatch_wave','wms_retry_work_order_dispatch','wms_cancel_work_order',
                  'wms_propagate_command_result')
group by command, entity_type
order by command;

\echo ''
\echo 'simulator finished.'
