\set QUIET on
\pset pager off
\pset format aligned
\set ON_ERROR_STOP on

-- ============================================================
-- wms_wcs-sequential-dispatch — psql simulator / verification script
-- (supabase/migrations/20260731_wcs_sequential_dispatch.sql)
--
-- Drives the sequential-dispatch contract exactly the way a real caller would:
-- it impersonates the seeded demo users by setting request.jwt.claims and
-- `set role authenticated`, so auth.uid(), wms.current_warehouse_ids() and
-- wms.has_role() behave as they do for a real Supabase session.
--
-- The robot cells (WCS_GATEWAY) are the same software-simulator idea as
-- areas 1-4 — no hardware, no PLC, no grippers. A "palletising result" is just
-- a wms_report_command_result call carrying detail.loaded_items.
--
-- The sections that matter most are 6-8: they prove that ONE command result
-- fans out to N individual sequence assignments (the per-item generalisation of
-- area 2's command-level propagation), and that the planning-time ceiling check
-- and the measured-time OVERWEIGHT outcome are two genuinely different
-- observable failures (design.md D7).
-- ============================================================

-- make the run repeatable without a full `supabase db reset`
truncate wms.dispatch_sequences, wms.outbound_orders restart identity cascade;
truncate wms.work_orders, wms.dispatch_waves restart identity cascade;
truncate wms.wcs_routing_overrides, wms.wcs_routing_policies restart identity cascade;
truncate wms.sortation_profiles restart identity cascade;
truncate wms.equipment_status_events, wms.equipment_commands, wms.equipment_faults, wms.equipment
  restart identity cascade;
delete from wms.audit_events where command in (
  'wms_create_outbound_order','wms_assign_dispatch_sequence','wms_cancel_dispatch_sequence',
  'wms_dispatch_palletize_command','wms_propagate_palletize_result',
  'wms_register_equipment','wms_dispatch_equipment_command','wms_report_command_result',
  'wms_report_equipment_status','wms_cancel_equipment_command',
  'wms_raise_equipment_fault','wms_resolve_equipment_fault','wms_open_dispatch_wave',
  'wms_release_dispatch_wave');
delete from wms.idempotency_records where command_name in (
  'wms_create_outbound_order','wms_assign_dispatch_sequence','wms_cancel_dispatch_sequence',
  'wms_dispatch_palletize_command','wms_register_equipment','wms_dispatch_equipment_command',
  'wms_report_command_result','wms_report_equipment_status','wms_cancel_equipment_command',
  'wms_open_dispatch_wave','wms_release_dispatch_wave');

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

-- same idea, for statements that return nothing (INSERT/UPDATE probes)
create or replace function pg_temp.try_exec(p_sql text) returns text
language plpgsql as $fn$
begin
  execute p_sql;
  return 'OK   (statement executed)';
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

-- report a PALLETIZE result: ACK -> IN_PROGRESS -> terminal, always with the
-- command's current version, exactly like a real gateway would.
create or replace function pg_temp.report(p_command uuid, p_status text, p_detail jsonb, p_actor uuid)
returns text language plpgsql as $fn$
begin
  perform wms.wms_report_command_result(
    p_command, p_status, p_actor, gen_random_uuid(),
    (select version from wms.equipment_commands where id = p_command), p_detail, 'seq-sim');
  return 'OK   command now ' || (select status from wms.equipment_commands where id = p_command);
exception when others then
  return 'ERR  ' || sqlerrm;
end
$fn$;

\set tenant_a '10000000-0000-0000-0000-00000000000a'
\set tenant_b '10000000-0000-0000-0000-00000000000b'
\set wh_a     '20000000-0000-0000-0000-00000000000a'
\set wh_b     '20000000-0000-0000-0000-00000000000b'

select id as mgr_a   from auth.users where email = 'wh-manager-a@demo.local' \gset
select id as op_a    from auth.users where email = 'wcs-operator-a@demo.local' \gset
select id as gw_a    from auth.users where email = 'wcs-gateway-a@demo.local' \gset
select id as admin_a from auth.users where email = 'admin-a@demo.local' \gset
select id as admin_b from auth.users where email = 'admin-b@demo.local' \gset
select id as qual_a  from auth.users where email = 'quality-a@demo.local' \gset
select id as agent_a from auth.users where email = 'process-agent-a@demo.local' \gset

select id as sku1 from wms.products where sku = 'SKU-A-001' and tenant_id = :'tenant_a' \gset
select id as sku2 from wms.products where sku = 'SKU-A-002' and tenant_id = :'tenant_a' \gset
select id as sku3 from wms.products where sku = 'SKU-A-003' and tenant_id = :'tenant_a' \gset
select id as skub from wms.products where sku = 'SKU-B-001' and tenant_id = :'tenant_b' \gset

\set QUIET off
\echo ''
\echo '=============================================================='
\echo '0. FIXTURE — two ROBOT_CELLs, one AGV (wrong type on purpose),'
\echo '   and one OPEN dispatch wave to sequence into'
\echo '=============================================================='

select pg_temp.act('wh-manager-a@demo.local');
set role authenticated;
select pg_temp.try(format(
  'select wms.wms_register_equipment(%L,%L,%L,%L,%L,%L,gen_random_uuid(),%L)',
  :'tenant_a', :'wh_a', 'SEQ-CELL-01', 'ROBOT_CELL', 'ZONE-SIM-SEQ', :'mgr_a', 'seq-sim')) as register_cell01;
select pg_temp.try(format(
  'select wms.wms_register_equipment(%L,%L,%L,%L,%L,%L,gen_random_uuid(),%L)',
  :'tenant_a', :'wh_a', 'SEQ-CELL-02', 'ROBOT_CELL', 'ZONE-SIM-SEQ', :'mgr_a', 'seq-sim')) as register_cell02;
select pg_temp.try(format(
  'select wms.wms_register_equipment(%L,%L,%L,%L,%L,%L,gen_random_uuid(),%L)',
  :'tenant_a', :'wh_a', 'SEQ-AGV-07', 'AGV', 'ZONE-SIM-SEQ', :'mgr_a', 'seq-sim')) as register_agv07;
reset role;

select id as cell01 from wms.equipment where equipment_code = 'SEQ-CELL-01' \gset
select id as cell02 from wms.equipment where equipment_code = 'SEQ-CELL-02' \gset
select id as agv07  from wms.equipment where equipment_code = 'SEQ-AGV-07' \gset

select pg_temp.act('wcs-gateway-a@demo.local');
set role authenticated;
select pg_temp.try(format('select wms.wms_report_equipment_status(%L,%L,%L,gen_random_uuid(),1,null,%L)',
  :'cell01', 'IDLE', :'gw_a', 'seq-sim')) as boot_cell01;
select pg_temp.try(format('select wms.wms_report_equipment_status(%L,%L,%L,gen_random_uuid(),1,null,%L)',
  :'cell02', 'IDLE', :'gw_a', 'seq-sim')) as boot_cell02;
select pg_temp.try(format('select wms.wms_report_equipment_status(%L,%L,%L,gen_random_uuid(),1,null,%L)',
  :'agv07', 'IDLE', :'gw_a', 'seq-sim')) as boot_agv07;
reset role;

select pg_temp.act('wh-manager-a@demo.local');
set role authenticated;
select wms.wms_open_dispatch_wave(:'tenant_a', :'wh_a', :'mgr_a', gen_random_uuid(), 'seq-sim')->>'wave_id' as wave1 \gset
select wms.wms_open_dispatch_wave(:'tenant_a', :'wh_a', :'mgr_a', gen_random_uuid(), 'seq-sim')->>'wave_id' as wave2 \gset
reset role;

select equipment_code, equipment_type, zone_code, status from wms.equipment order by equipment_code;
select left(id::text, 8) as wave, status from wms.dispatch_waves order by created_at;

\echo ''
\echo '=============================================================='
\echo '1. Outbound unit registration'
\echo '   (spec: "출고 단위 등록")'
\echo '=============================================================='

select pg_temp.act('wh-manager-a@demo.local');
set role authenticated;
\echo '  happy path — STORE-042, 10 EA, declared 4.2kg / 3.1L'
select pg_temp.try(format(
  'select wms.wms_create_outbound_order(%L,%L,%L,%L,10,%L,gen_random_uuid(),%L,null,4.2,3.1,%L)',
  :'tenant_a', :'wh_a', 'STORE-042', :'sku1', :'mgr_a', 'OB-SIM-0001', 'seq-sim')) as create_order_1;
select pg_temp.try(format(
  'select wms.wms_create_outbound_order(%L,%L,%L,%L,4,%L,gen_random_uuid(),%L,null,6.0,5.0,%L)',
  :'tenant_a', :'wh_a', 'STORE-042', :'sku2', :'mgr_a', 'OB-SIM-0002', 'seq-sim')) as create_order_2;
select pg_temp.try(format(
  'select wms.wms_create_outbound_order(%L,%L,%L,%L,2,%L,gen_random_uuid(),%L,null,240.0,10.0,%L)',
  :'tenant_a', :'wh_a', 'STORE-088', :'sku3', :'mgr_a', 'OB-SIM-0003', 'seq-sim')) as create_order_3_heavy;
select pg_temp.try(format(
  'select wms.wms_create_outbound_order(%L,%L,%L,%L,1,%L,gen_random_uuid(),%L,null,30.0,4.0,%L)',
  :'tenant_a', :'wh_a', 'STORE-088', :'sku1', :'mgr_a', 'OB-SIM-0004', 'seq-sim')) as create_order_4_heavy;
select pg_temp.try(format(
  'select wms.wms_create_outbound_order(%L,%L,%L,%L,5,%L,gen_random_uuid(),%L,null,2.0,2.0,%L)',
  :'tenant_a', :'wh_a', 'STORE-101', :'sku2', :'mgr_a', 'OB-SIM-0005', 'seq-sim')) as create_order_5;

\echo '  refusals'
select pg_temp.try(format(
  'select wms.wms_create_outbound_order(%L,%L,%L,%L,0,%L,gen_random_uuid(),null,null,null,null,null)',
  :'tenant_a', :'wh_a', 'STORE-042', :'sku1', :'mgr_a')) as create_qty_zero;
select pg_temp.try(format(
  'select wms.wms_create_outbound_order(%L,%L,%L,%L,-3,%L,gen_random_uuid(),null,null,null,null,null)',
  :'tenant_a', :'wh_a', 'STORE-042', :'sku1', :'mgr_a')) as create_qty_negative;
select pg_temp.try(format(
  'select wms.wms_create_outbound_order(%L,%L,%L,%L,1,%L,gen_random_uuid(),null,null,null,null,null)',
  :'tenant_a', :'wh_a', '   ', :'sku1', :'mgr_a')) as create_blank_store;
select pg_temp.try(format(
  'select wms.wms_create_outbound_order(%L,%L,%L,%L,1,%L,gen_random_uuid(),null,null,null,null,null)',
  :'tenant_a', :'wh_a', 'STORE-042', :'skub', :'mgr_a')) as create_foreign_product;
select pg_temp.try(format(
  'select wms.wms_create_outbound_order(%L,%L,%L,%L,1,%L,gen_random_uuid(),null,null,-1,null,null)',
  :'tenant_a', :'wh_a', 'STORE-042', :'sku1', :'mgr_a')) as create_negative_weight;
\echo '  no warehouse scope (tenant A manager pointing at tenant B warehouse)'
select pg_temp.try(format(
  'select wms.wms_create_outbound_order(%L,%L,%L,%L,1,%L,gen_random_uuid(),null,null,null,null,null)',
  :'tenant_b', :'wh_b', 'STORE-042', :'skub', :'mgr_a')) as create_cross_tenant;
reset role;

\echo '  role check — WCS_OPERATOR may sequence but may NOT create outbound units'
select pg_temp.act('wcs-operator-a@demo.local');
set role authenticated;
select pg_temp.try(format(
  'select wms.wms_create_outbound_order(%L,%L,%L,%L,1,%L,gen_random_uuid(),null,null,null,null,null)',
  :'tenant_a', :'wh_a', 'STORE-042', :'sku1', :'op_a')) as create_as_operator;
reset role;
\echo '  QUALITY_INSPECTOR has no business here at all'
select pg_temp.act('quality-a@demo.local');
set role authenticated;
select pg_temp.try(format(
  'select wms.wms_create_outbound_order(%L,%L,%L,%L,1,%L,gen_random_uuid(),null,null,null,null,null)',
  :'tenant_a', :'wh_a', 'STORE-042', :'sku1', :'qual_a')) as create_as_quality;
reset role;

select order_number, store_code, qty, declared_weight_kg, declared_volume_l, status, version
from wms.outbound_orders order by order_number;

select id as ob1 from wms.outbound_orders where order_number = 'OB-SIM-0001' \gset
select id as ob2 from wms.outbound_orders where order_number = 'OB-SIM-0002' \gset
select id as ob3 from wms.outbound_orders where order_number = 'OB-SIM-0003' \gset
select id as ob4 from wms.outbound_orders where order_number = 'OB-SIM-0004' \gset
select id as ob5 from wms.outbound_orders where order_number = 'OB-SIM-0005' \gset

\echo ''
\echo '=============================================================='
\echo '2. Idempotency — the same key twice creates ONE row'
\echo '=============================================================='

select pg_temp.act('wh-manager-a@demo.local');
set role authenticated;
select gen_random_uuid() as idem \gset
select pg_temp.try(format(
  'select wms.wms_create_outbound_order(%L,%L,%L,%L,7,%L,%L,%L,null,1,1,null)',
  :'tenant_a', :'wh_a', 'STORE-IDEM', :'sku1', :'mgr_a', :'idem', 'OB-SIM-IDEM')) as first_call;
select pg_temp.try(format(
  'select wms.wms_create_outbound_order(%L,%L,%L,%L,7,%L,%L,%L,null,1,1,null)',
  :'tenant_a', :'wh_a', 'STORE-IDEM', :'sku1', :'mgr_a', :'idem', 'OB-SIM-IDEM')) as replayed_call;
reset role;
select count(*) as rows_for_store_idem from wms.outbound_orders where store_code = 'STORE-IDEM';

\echo ''
\echo '=============================================================='
\echo '3. Sequence assignment inside a dispatch wave'
\echo '   (spec: "디스패치 웨이브 내 서열 배정")'
\echo '=============================================================='

select pg_temp.act('wcs-operator-a@demo.local');
set role authenticated;
\echo '  STORE-042 pallet PLT-0001 — positions 1 and 2'
select pg_temp.try(format(
  'select wms.wms_assign_dispatch_sequence(%L,%L,1,%L,%L,gen_random_uuid(),1,%L)',
  :'ob1', :'wave1', 'PLT-0001', :'op_a', 'seq-sim')) as assign_1;
select pg_temp.try(format(
  'select wms.wms_assign_dispatch_sequence(%L,%L,2,%L,%L,gen_random_uuid(),1,%L)',
  :'ob2', :'wave1', 'PLT-0001', :'op_a', 'seq-sim')) as assign_2;
\echo '  STORE-088 pallet PLT-0002 — the two heavy ones (240 + 30 = 270kg)'
select pg_temp.try(format(
  'select wms.wms_assign_dispatch_sequence(%L,%L,3,%L,%L,gen_random_uuid(),1,%L)',
  :'ob3', :'wave1', 'PLT-0002', :'op_a', 'seq-sim')) as assign_3;
select pg_temp.try(format(
  'select wms.wms_assign_dispatch_sequence(%L,%L,4,%L,%L,gen_random_uuid(),1,%L)',
  :'ob4', :'wave1', 'PLT-0002', :'op_a', 'seq-sim')) as assign_4;

\echo '  refusals'
select pg_temp.try(format(
  'select wms.wms_assign_dispatch_sequence(%L,%L,1,%L,%L,gen_random_uuid(),1,null)',
  :'ob5', :'wave1', 'PLT-0003', :'op_a')) as assign_duplicate_position;
select pg_temp.try(format(
  'select wms.wms_assign_dispatch_sequence(%L,%L,9,%L,%L,gen_random_uuid(),'
  || '(select version from wms.outbound_orders where id = %L),null)',
  :'ob1', :'wave1', 'PLT-0003', :'op_a', :'ob1')) as assign_already_sequenced;
select pg_temp.try(format(
  'select wms.wms_assign_dispatch_sequence(%L,%L,0,%L,%L,gen_random_uuid(),1,null)',
  :'ob5', :'wave1', 'PLT-0003', :'op_a')) as assign_position_zero;
select pg_temp.try(format(
  'select wms.wms_assign_dispatch_sequence(%L,%L,9,%L,%L,gen_random_uuid(),1,null)',
  :'ob5', :'wave1', '  ', :'op_a')) as assign_blank_pallet;
select pg_temp.try(format(
  'select wms.wms_assign_dispatch_sequence(%L,%L,9,%L,%L,gen_random_uuid(),3,null)',
  :'ob5', :'wave1', 'PLT-0003', :'op_a')) as assign_stale_version;
select pg_temp.try(format(
  'select wms.wms_assign_dispatch_sequence(%L,%L,9,%L,%L,gen_random_uuid(),1,null)',
  :'ob5', '00000000-0000-0000-0000-0000000000ff', 'PLT-0003', :'op_a')) as assign_unknown_wave;
reset role;

\echo '  a RELEASED wave is closed to new sequencing (area 2 rule, reused)'
select pg_temp.act('wh-manager-a@demo.local');
set role authenticated;
select pg_temp.try(format(
  'select wms.wms_release_dispatch_wave(%L,%L,gen_random_uuid(),1,%L)',
  :'wave2', :'mgr_a', 'seq-sim')) as release_wave2;
select pg_temp.try(format(
  'select wms.wms_assign_dispatch_sequence(%L,%L,1,%L,%L,gen_random_uuid(),1,null)',
  :'ob5', :'wave2', 'PLT-0009', :'mgr_a')) as assign_into_released_wave;
reset role;

\echo '  cross-tenant: tenant B admin cannot touch tenant A outbound units'
select pg_temp.act('admin-b@demo.local');
set role authenticated;
select pg_temp.try(format(
  'select wms.wms_assign_dispatch_sequence(%L,%L,9,%L,%L,gen_random_uuid(),1,null)',
  :'ob5', :'wave1', 'PLT-0003', :'admin_b')) as assign_cross_tenant;
reset role;

select o.order_number, s.sequence_position, s.target_pallet_code, s.status as seq_status,
       o.status as order_status, o.version as order_version
from wms.dispatch_sequences s join wms.outbound_orders o on o.id = s.outbound_order_id
order by s.sequence_position;

select id as seq1 from wms.dispatch_sequences where outbound_order_id = :'ob1' \gset
select id as seq2 from wms.dispatch_sequences where outbound_order_id = :'ob2' \gset
select id as seq3 from wms.dispatch_sequences where outbound_order_id = :'ob3' \gset
select id as seq4 from wms.dispatch_sequences where outbound_order_id = :'ob4' \gset

\echo ''
\echo '=============================================================='
\echo '4. PALLETIZE dispatch — one command, N sequence assignments'
\echo '   (spec: "혼합 팔레타이징 명령 디스패치")'
\echo '=============================================================='

select pg_temp.act('wcs-operator-a@demo.local');
set role authenticated;
\echo '  planning-time ceiling (design.md D7, first half): PLT-0002 declares'
\echo '  270kg against a 250kg ceiling -> refused, nothing changes'
select pg_temp.try(format(
  'select wms.wms_dispatch_palletize_command(%L,%L,%L,%L,gen_random_uuid(),'
  || '(select version from wms.equipment where id = %L),250,null,%L)',
  :'cell01', :'wave1', 'PLT-0002', :'op_a', :'cell01', 'seq-sim')) as dispatch_overweight_plan;
select order_number, s.status as seq_status from wms.dispatch_sequences s
  join wms.outbound_orders o on o.id = s.outbound_order_id
  where s.target_pallet_code = 'PLT-0002' order by s.sequence_position;

\echo '  volume ceiling behaves the same way (10 + 4 = 14L vs a 10L ceiling)'
select pg_temp.try(format(
  'select wms.wms_dispatch_palletize_command(%L,%L,%L,%L,gen_random_uuid(),'
  || '(select version from wms.equipment where id = %L),null,10,%L)',
  :'cell01', :'wave1', 'PLT-0002', :'op_a', :'cell01', 'seq-sim')) as dispatch_overvolume_plan;

\echo '  empty batch — no QUEUED assignment on this (wave, pallet)'
select pg_temp.try(format(
  'select wms.wms_dispatch_palletize_command(%L,%L,%L,%L,gen_random_uuid(),'
  || '(select version from wms.equipment where id = %L),null,null,null)',
  :'cell01', :'wave1', 'PLT-0003', :'op_a', :'cell01')) as dispatch_empty_batch;

\echo '  wrong equipment type — an AGV cannot palletise'
select pg_temp.try(format(
  'select wms.wms_dispatch_palletize_command(%L,%L,%L,%L,gen_random_uuid(),'
  || '(select version from wms.equipment where id = %L),null,null,null)',
  :'agv07', :'wave1', 'PLT-0001', :'op_a', :'agv07')) as dispatch_to_agv;
\echo '  ...and the same through the generic RPC, so the trigger is the real guard'
select pg_temp.try(format(
  'select wms.wms_dispatch_equipment_command(%L,%L,'
  || '''{"target_pallet_code":"PLT-0001","sequence_items":[{"dispatch_sequence_id":"%s","sequence_position":1}]}''::jsonb,'
  || '%L,gen_random_uuid(),(select version from wms.equipment where id = %L),null,null,null)',
  :'agv07', 'PALLETIZE', :'seq1', :'op_a', :'agv07')) as raw_palletize_to_agv;

\echo '  stale equipment version -> CONFLICT'
select pg_temp.try(format(
  'select wms.wms_dispatch_palletize_command(%L,%L,%L,%L,gen_random_uuid(),99,null,null,null)',
  :'cell01', :'wave1', 'PLT-0001', :'op_a')) as dispatch_stale_version;

\echo '  happy path — PLT-0001 (2 items, 10.2kg / 8.1L) onto SEQ-CELL-01'
select pg_temp.try(format(
  'select wms.wms_dispatch_palletize_command(%L,%L,%L,%L,gen_random_uuid(),'
  || '(select version from wms.equipment where id = %L),250,500,%L)',
  :'cell01', :'wave1', 'PLT-0001', :'op_a', :'cell01', 'seq-sim')) as dispatch_plt0001;
reset role;

select o.order_number, s.sequence_position, s.status as seq_status, o.status as order_status,
       left(s.equipment_command_id::text, 8) as cmd
from wms.dispatch_sequences s join wms.outbound_orders o on o.id = s.outbound_order_id
where s.target_pallet_code = 'PLT-0001' order by s.sequence_position;

select id as cmd1 from wms.equipment_commands where command_type = 'PALLETIZE' order by created_at desc limit 1 \gset

\echo '  the payload the cell receives: items sorted by sequence_position'
select jsonb_pretty(payload) as palletize_payload from wms.equipment_commands where id = :'cmd1';

\echo '  the cell is now RUNNING, so a DIFFERENT pallet is refused on it (D4)'
select pg_temp.act('wcs-operator-a@demo.local');
set role authenticated;
select pg_temp.try(format(
  'select wms.wms_dispatch_palletize_command(%L,%L,%L,%L,gen_random_uuid(),'
  || '(select version from wms.equipment where id = %L),null,null,null)',
  :'cell01', :'wave1', 'PLT-0002', :'op_a', :'cell01')) as dispatch_second_pallet_same_cell;
reset role;

\echo '  role check — WMS_ADMIN is NOT in wms_dispatch_equipment_command''s role'
\echo '  set, so this contract refuses it up front rather than half-way'
\echo '  (migration DEVIATION 2)'
select pg_temp.act('admin-a@demo.local');
set role authenticated;
select pg_temp.try(format(
  'select wms.wms_dispatch_palletize_command(%L,%L,%L,%L,gen_random_uuid(),'
  || '(select version from wms.equipment where id = %L),null,null,null)',
  :'cell02', :'wave1', 'PLT-0002', :'admin_a', :'cell02')) as dispatch_as_admin;
reset role;
select pg_temp.act('quality-a@demo.local');
set role authenticated;
select pg_temp.try(format(
  'select wms.wms_dispatch_palletize_command(%L,%L,%L,%L,gen_random_uuid(),'
  || '(select version from wms.equipment where id = %L),null,null,null)',
  :'cell02', :'wave1', 'PLT-0002', :'qual_a', :'cell02')) as dispatch_as_quality;
reset role;

\echo ''
\echo '=============================================================='
\echo '5. Payload-shape validation through the generic dispatch RPC'
\echo '   (spec: "혼합 팔레타이징 명령 디스패치", "스트레치 포장 명령'
\echo '    payload 계약"; tasks.md 3.9)'
\echo '=============================================================='

select pg_temp.act('wcs-operator-a@demo.local');
set role authenticated;
\echo '  PALLETIZE with no sequence_items'
select pg_temp.try(format(
  'select wms.wms_dispatch_equipment_command(%L,%L,''{"target_pallet_code":"PLT-X"}''::jsonb,'
  || '%L,gen_random_uuid(),(select version from wms.equipment where id = %L),null,null,null)',
  :'cell02', 'PALLETIZE', :'op_a', :'cell02')) as palletize_no_items;
\echo '  PALLETIZE with an empty sequence_items array'
select pg_temp.try(format(
  'select wms.wms_dispatch_equipment_command(%L,%L,'
  || '''{"target_pallet_code":"PLT-X","sequence_items":[]}''::jsonb,'
  || '%L,gen_random_uuid(),(select version from wms.equipment where id = %L),null,null,null)',
  :'cell02', 'PALLETIZE', :'op_a', :'cell02')) as palletize_empty_items;
\echo '  PALLETIZE with no target_pallet_code'
select pg_temp.try(format(
  'select wms.wms_dispatch_equipment_command(%L,%L,'
  || '''{"sequence_items":[{"dispatch_sequence_id":"%s","sequence_position":1}]}''::jsonb,'
  || '%L,gen_random_uuid(),(select version from wms.equipment where id = %L),null,null,null)',
  :'cell02', 'PALLETIZE', :'seq3', :'op_a', :'cell02')) as palletize_no_pallet_code;
\echo '  PALLETIZE with items out of sequence order'
select pg_temp.try(format(
  'select wms.wms_dispatch_equipment_command(%L,%L,'
  || '''{"target_pallet_code":"PLT-X","sequence_items":['
  || '{"dispatch_sequence_id":"%s","sequence_position":4},'
  || '{"dispatch_sequence_id":"%s","sequence_position":3}]}''::jsonb,'
  || '%L,gen_random_uuid(),(select version from wms.equipment where id = %L),null,null,null)',
  :'cell02', 'PALLETIZE', :'seq4', :'seq3', :'op_a', :'cell02')) as palletize_unsorted;
\echo '  WRAP without wrap_program'
select pg_temp.try(format(
  'select wms.wms_dispatch_equipment_command(%L,%L,''{"pallet_code":"PLT-0001"}''::jsonb,'
  || '%L,gen_random_uuid(),(select version from wms.equipment where id = %L),null,null,null)',
  :'cell02', 'WRAP', :'op_a', :'cell02')) as wrap_no_program;
\echo '  WRAP with an unknown wrap_program'
select pg_temp.try(format(
  'select wms.wms_dispatch_equipment_command(%L,%L,'
  || '''{"pallet_code":"PLT-0001","wrap_program":"TURBO"}''::jsonb,'
  || '%L,gen_random_uuid(),(select version from wms.equipment where id = %L),null,null,null)',
  :'cell02', 'WRAP', :'op_a', :'cell02')) as wrap_unknown_program;
\echo '  WRAP on an AGV'
select pg_temp.try(format(
  'select wms.wms_dispatch_equipment_command(%L,%L,'
  || '''{"pallet_code":"PLT-0001","wrap_program":"STANDARD"}''::jsonb,'
  || '%L,gen_random_uuid(),(select version from wms.equipment where id = %L),null,null,null)',
  :'agv07', 'WRAP', :'op_a', :'agv07')) as wrap_on_agv;
reset role;
select count(*) as commands_created_by_section_5 from wms.equipment_commands
  where equipment_id = :'cell02';

\echo ''
\echo '=============================================================='
\echo '6. PALLETIZE result — full SUCCESS fans out to every assignment'
\echo '   (spec: "팔레타이징 결과 보고와 항목 단위 상태 반영")'
\echo '=============================================================='

select pg_temp.act('wcs-gateway-a@demo.local');
set role authenticated;
select pg_temp.report(:'cmd1', 'IN_PROGRESS', null, :'gw_a') as ack_in_progress;

\echo '  consistency guard first: COMPLETED + outcome=OVERWEIGHT is a lie'
select pg_temp.try(format(
  'select wms.wms_report_command_result(%L,%L,%L,gen_random_uuid(),'
  || '(select version from wms.equipment_commands where id = %L),'
  || '''{"outcome":"OVERWEIGHT","loaded_items":[{"dispatch_sequence_id":"%s","item_outcome":"SKIPPED"},'
  || '{"dispatch_sequence_id":"%s","item_outcome":"SKIPPED"}]}''::jsonb,null)',
  :'cmd1', 'COMPLETED', :'gw_a', :'cmd1', :'seq1', :'seq2')) as completed_with_overweight;
\echo '  ...and SUCCESS with a SKIPPED item is also refused'
select pg_temp.try(format(
  'select wms.wms_report_command_result(%L,%L,%L,gen_random_uuid(),'
  || '(select version from wms.equipment_commands where id = %L),'
  || '''{"outcome":"SUCCESS","loaded_items":[{"dispatch_sequence_id":"%s","load_position":1,"item_outcome":"LOADED"},'
  || '{"dispatch_sequence_id":"%s","item_outcome":"SKIPPED"}]}''::jsonb,null)',
  :'cmd1', 'COMPLETED', :'gw_a', :'cmd1', :'seq1', :'seq2')) as success_with_skipped;
\echo '  ...an unknown outcome value'
select pg_temp.try(format(
  'select wms.wms_report_command_result(%L,%L,%L,gen_random_uuid(),'
  || '(select version from wms.equipment_commands where id = %L),'
  || '''{"outcome":"WOBBLY","loaded_items":[{"dispatch_sequence_id":"%s","load_position":1,"item_outcome":"LOADED"}]}''::jsonb,null)',
  :'cmd1', 'COMPLETED', :'gw_a', :'cmd1', :'seq1')) as unknown_outcome;
\echo '  ...an item that does not belong to this command'
select pg_temp.try(format(
  'select wms.wms_report_command_result(%L,%L,%L,gen_random_uuid(),'
  || '(select version from wms.equipment_commands where id = %L),'
  || '''{"outcome":"SUCCESS","loaded_items":[{"dispatch_sequence_id":"%s","load_position":1,"item_outcome":"LOADED"}]}''::jsonb,null)',
  :'cmd1', 'COMPLETED', :'gw_a', :'cmd1', :'seq3')) as foreign_item;
\echo '  ...and a LOADED item without a load_position'
select pg_temp.try(format(
  'select wms.wms_report_command_result(%L,%L,%L,gen_random_uuid(),'
  || '(select version from wms.equipment_commands where id = %L),'
  || '''{"outcome":"SUCCESS","loaded_items":[{"dispatch_sequence_id":"%s","item_outcome":"LOADED"},'
  || '{"dispatch_sequence_id":"%s","load_position":2,"item_outcome":"LOADED"}]}''::jsonb,null)',
  :'cmd1', 'COMPLETED', :'gw_a', :'cmd1', :'seq1', :'seq2')) as loaded_without_position;

\echo '  nothing moved while those were refused:'
select o.order_number, s.status as seq_status, s.load_position, o.status as order_status
from wms.dispatch_sequences s join wms.outbound_orders o on o.id = s.outbound_order_id
where s.equipment_command_id = :'cmd1' order by s.sequence_position;

\echo '  the real report: SUCCESS, both items LOADED at positions 1 and 2'
select pg_temp.try(format(
  'select wms.wms_report_command_result(%L,%L,%L,gen_random_uuid(),'
  || '(select version from wms.equipment_commands where id = %L),'
  || '''{"outcome":"SUCCESS","total_actual_weight_kg":10.4,"total_actual_volume_l":8.0,'
  || '"loaded_items":[{"dispatch_sequence_id":"%s","load_position":1,"item_outcome":"LOADED"},'
  || '{"dispatch_sequence_id":"%s","load_position":2,"item_outcome":"LOADED"}]}''::jsonb,%L)',
  :'cmd1', 'COMPLETED', :'gw_a', :'cmd1', :'seq1', :'seq2', 'seq-sim')) as report_success;
reset role;

\echo '  one command result -> two assignments AND two outbound units updated:'
select o.order_number, s.status as seq_status, s.load_position, s.version as seq_version,
       o.status as order_status, o.version as order_version
from wms.dispatch_sequences s join wms.outbound_orders o on o.id = s.outbound_order_id
where s.equipment_command_id = :'cmd1' order by s.sequence_position;
select status as cell01_status from wms.equipment where id = :'cell01';

\echo ''
\echo '=============================================================='
\echo '7. Pallet manifest'
\echo '   (spec: "팔레트 매니페스트 조회")'
\echo '=============================================================='

select pg_temp.act('wh-manager-a@demo.local');
set role authenticated;
select jsonb_pretty(wms.wms_get_pallet_manifest(:'tenant_a', :'wh_a', :'cmd1', null)) as manifest_by_command;
\echo '  the same manifest can be reached by pallet code'
select jsonb_array_length(wms.wms_get_pallet_manifest(:'tenant_a', :'wh_a', null, 'PLT-0001')->'pallets')
  as pallets_for_plt0001;
\echo '  a warehouse the caller cannot see'
select pg_temp.try(format('select wms.wms_get_pallet_manifest(%L,%L,null,null)', :'tenant_b', :'wh_b'))
  as manifest_other_warehouse;
reset role;

\echo ''
\echo '=============================================================='
\echo '8. Partial load and measured overweight'
\echo '   (spec: "부분 적재가 완료 상태로 보고되고 SKIPPED 항목만 FAILED로'
\echo '    반영된다", "중량 초과가 실패 상태로 보고되면 ...")'
\echo '   design.md D7 second half: the SAME pallet that passed the'
\echo '   planning check can still come back OVERWEIGHT from the scale.'
\echo '=============================================================='

select pg_temp.act('wcs-operator-a@demo.local');
set role authenticated;
\echo '  PLT-0002 with a ceiling it fits (270kg vs 300kg) -> dispatch onto CELL-02'
select pg_temp.try(format(
  'select wms.wms_dispatch_palletize_command(%L,%L,%L,%L,gen_random_uuid(),'
  || '(select version from wms.equipment where id = %L),300,500,%L)',
  :'cell02', :'wave1', 'PLT-0002', :'op_a', :'cell02', 'seq-sim')) as dispatch_plt0002;
reset role;
select id as cmd2 from wms.equipment_commands
  where command_type = 'PALLETIZE' and equipment_id = :'cell02' order by created_at desc limit 1 \gset

select pg_temp.act('wcs-gateway-a@demo.local');
set role authenticated;
select pg_temp.report(:'cmd2', 'IN_PROGRESS', null, :'gw_a') as ack_plt0002;
\echo '  PARTIAL: item 3 loaded, item 4 skipped because the scale said no'
select pg_temp.try(format(
  'select wms.wms_report_command_result(%L,%L,%L,gen_random_uuid(),'
  || '(select version from wms.equipment_commands where id = %L),'
  || '''{"outcome":"PARTIAL","total_actual_weight_kg":244.8,'
  || '"loaded_items":[{"dispatch_sequence_id":"%s","load_position":1,"item_outcome":"LOADED"},'
  || '{"dispatch_sequence_id":"%s","load_position":null,"item_outcome":"SKIPPED","reason":"OVERWEIGHT"}]}''::jsonb,%L)',
  :'cmd2', 'COMPLETED', :'gw_a', :'cmd2', :'seq3', :'seq4', 'seq-sim')) as report_partial;
reset role;

select o.order_number, s.sequence_position, s.status as seq_status, s.load_position, s.reason,
       o.status as order_status
from wms.dispatch_sequences s join wms.outbound_orders o on o.id = s.outbound_order_id
where s.equipment_command_id = :'cmd2' order by s.sequence_position;

\echo '  now the pure measured-failure path: re-sequence the skipped unit and'
\echo '  have the cell report OVERWEIGHT for the whole build'
select pg_temp.act('wcs-operator-a@demo.local');
set role authenticated;
select pg_temp.try(format(
  'select wms.wms_assign_dispatch_sequence(%L,%L,7,%L,%L,gen_random_uuid(),'
  || '(select version from wms.outbound_orders where id = %L),%L)',
  :'ob5', :'wave1', 'PLT-0004', :'op_a', :'ob5', 'seq-sim')) as assign_plt0004;
select pg_temp.try(format(
  'select wms.wms_dispatch_palletize_command(%L,%L,%L,%L,gen_random_uuid(),'
  || '(select version from wms.equipment where id = %L),null,null,%L)',
  :'cell01', :'wave1', 'PLT-0004', :'op_a', :'cell01', 'seq-sim')) as dispatch_plt0004;
reset role;
select id as seq5 from wms.dispatch_sequences where outbound_order_id = :'ob5' and status <> 'CANCELLED' \gset
select id as cmd3 from wms.equipment_commands
  where command_type = 'PALLETIZE' and payload->>'target_pallet_code' = 'PLT-0004' \gset

select pg_temp.act('wcs-gateway-a@demo.local');
set role authenticated;
select pg_temp.try(format(
  'select wms.wms_report_command_result(%L,%L,%L,gen_random_uuid(),'
  || '(select version from wms.equipment_commands where id = %L),'
  || '''{"outcome":"OVERWEIGHT","total_actual_weight_kg":312.5,'
  || '"loaded_items":[{"dispatch_sequence_id":"%s","item_outcome":"SKIPPED","reason":"SCALE_LIMIT"}]}''::jsonb,%L)',
  :'cmd3', 'FAILED', :'gw_a', :'cmd3', :'seq5', 'seq-sim')) as report_overweight;
reset role;

select o.order_number, s.status as seq_status, s.reason, o.status as order_status
from wms.dispatch_sequences s join wms.outbound_orders o on o.id = s.outbound_order_id
where s.id = :'seq5';

\echo ''
\echo '  the two D7 failures side by side — same pallet concept, different'
\echo '  moment, different observable:'
select 'planning (declared vs ceiling)' as stage,
       'INVALID: dispatch refused, no command row' as observable
union all
select 'measurement (scale vs ceiling)',
       'command FAILED with outcome=OVERWEIGHT, assignments FAILED';

\echo ''
\echo '=============================================================='
\echo '9. WRAP is a thin extension — it must NOT touch assignments'
\echo '   (spec: "스트레치 포장 명령 payload 계약", design.md D8)'
\echo '=============================================================='

select count(*) filter (where status = 'COMPLETED') as completed_before
from wms.dispatch_sequences;

select pg_temp.act('wcs-operator-a@demo.local');
set role authenticated;
select pg_temp.try(format(
  'select wms.wms_dispatch_equipment_command(%L,%L,'
  || '''{"pallet_code":"PLT-0001","wrap_program":"STANDARD"}''::jsonb,'
  || '%L,gen_random_uuid(),(select version from wms.equipment where id = %L),%L,null,null)',
  :'cell01', 'WRAP', :'op_a', :'cell01', 'seq-sim')) as dispatch_wrap;
reset role;
select id as wrapcmd from wms.equipment_commands where command_type = 'WRAP' order by created_at desc limit 1 \gset

select pg_temp.act('wcs-gateway-a@demo.local');
set role authenticated;
\echo '  WRAP outcome consistency is checked too'
select pg_temp.try(format(
  'select wms.wms_report_command_result(%L,%L,%L,gen_random_uuid(),'
  || '(select version from wms.equipment_commands where id = %L),'
  || '''{"outcome":"FAILED","wrap_cycles":0}''::jsonb,null)',
  :'wrapcmd', 'COMPLETED', :'gw_a', :'wrapcmd')) as wrap_failed_as_completed;
select pg_temp.try(format(
  'select wms.wms_report_command_result(%L,%L,%L,gen_random_uuid(),'
  || '(select version from wms.equipment_commands where id = %L),'
  || '''{"outcome":"SUCCESS","wrap_cycles":3}''::jsonb,%L)',
  :'wrapcmd', 'COMPLETED', :'gw_a', :'wrapcmd', 'seq-sim')) as wrap_success;
reset role;

select count(*) filter (where status = 'COMPLETED') as completed_after
from wms.dispatch_sequences;
select command_type, status, detail->>'outcome' as outcome, detail->>'wrap_cycles' as cycles
from wms.equipment_status_events e
join wms.equipment_commands c on c.id = e.command_id
where c.command_type = 'WRAP' and e.detail ? 'outcome';

\echo ''
\echo '=============================================================='
\echo '10. Cancellation'
\echo '   (spec: "서열 배정 취소"; migration DEVIATION 4)'
\echo '=============================================================='

select pg_temp.act('wh-manager-a@demo.local');
set role authenticated;
\echo '  a QUEUED assignment: two fresh units on one pallet, cancel one'
select wms.wms_create_outbound_order(:'tenant_a', :'wh_a', 'STORE-777', :'sku1', 3,
  :'mgr_a', gen_random_uuid(), 'OB-SIM-0006', null, 1.0, 1.0, 'seq-sim')->>'outbound_order_id' as ob6 \gset
select wms.wms_create_outbound_order(:'tenant_a', :'wh_a', 'STORE-777', :'sku2', 3,
  :'mgr_a', gen_random_uuid(), 'OB-SIM-0007', null, 1.0, 1.0, 'seq-sim')->>'outbound_order_id' as ob7 \gset
select wms.wms_assign_dispatch_sequence(:'ob6', :'wave1', 11, 'PLT-0005',
  :'mgr_a', gen_random_uuid(), 1, 'seq-sim')->>'dispatch_sequence_id' as seq6 \gset
select wms.wms_assign_dispatch_sequence(:'ob7', :'wave1', 12, 'PLT-0005',
  :'mgr_a', gen_random_uuid(), 1, 'seq-sim')->>'dispatch_sequence_id' as seq7 \gset

select pg_temp.try(format(
  'select wms.wms_cancel_dispatch_sequence(%L,%L,gen_random_uuid(),1,%L,%L)',
  :'seq6', :'mgr_a', '고객 주문 취소', 'seq-sim')) as cancel_queued;
select pg_temp.try(format(
  'select wms.wms_cancel_dispatch_sequence(%L,%L,gen_random_uuid(),2,null,null)',
  :'seq6', :'mgr_a')) as cancel_already_cancelled;
select pg_temp.try(format(
  'select wms.wms_cancel_dispatch_sequence(%L,%L,gen_random_uuid(),99,null,null)',
  :'seq7', :'mgr_a')) as cancel_stale_version;
select pg_temp.try(format(
  'select wms.wms_cancel_dispatch_sequence(%L,%L,gen_random_uuid(),'
  || '(select version from wms.dispatch_sequences where id = %L),null,null)',
  :'seq1', :'mgr_a', :'seq1')) as cancel_completed;

\echo '  DEVIATION 3 in action: the cancelled unit went back to OPEN and can be'
\echo '  re-sequenced, reusing position 11'
select order_number, status, version from wms.outbound_orders where id = :'ob6';
select pg_temp.try(format(
  'select wms.wms_assign_dispatch_sequence(%L,%L,11,%L,%L,gen_random_uuid(),'
  || '(select version from wms.outbound_orders where id = %L),%L)',
  :'ob6', :'wave1', 'PLT-0005', :'mgr_a', :'ob6', 'seq-sim')) as reassign_after_cancel;
reset role;

\echo '  a DISPATCHED assignment: cancelling it cancels the shared PALLETIZE'
\echo '  command AND its siblings (DEVIATION 4)'
select pg_temp.act('wcs-operator-a@demo.local');
set role authenticated;
select pg_temp.try(format(
  'select wms.wms_dispatch_palletize_command(%L,%L,%L,%L,gen_random_uuid(),'
  || '(select version from wms.equipment where id = %L),null,null,%L)',
  :'cell02', :'wave1', 'PLT-0005', :'op_a', :'cell02', 'seq-sim')) as dispatch_plt0005;
reset role;
select id as cmd4 from wms.equipment_commands
  where command_type = 'PALLETIZE' and payload->>'target_pallet_code' = 'PLT-0005' \gset

\echo '  before any result is reported, the manifest for that command is EMPTY,'
\echo '  not an error (spec: "아직 결과가 보고되지 않은 명령의 매니페스트")'
select pg_temp.act('wh-manager-a@demo.local');
set role authenticated;
select p->>'command_status' as command_status, p->>'reported' as reported,
       jsonb_array_length(p->'items') as item_count, p->>'planned_item_count' as planned
from (select (wms.wms_get_pallet_manifest(:'tenant_a', :'wh_a', :'cmd4', null)->'pallets'->0) as p) x;
reset role;

select pg_temp.act('wh-manager-a@demo.local');
set role authenticated;
select pg_temp.try(format(
  'select wms.wms_cancel_dispatch_sequence(%L,%L,gen_random_uuid(),'
  || '(select version from wms.dispatch_sequences where id = %L),%L,%L)',
  :'seq7', :'mgr_a', :'seq7', '팔레트 재구성', 'seq-sim')) as cancel_dispatched;
reset role;

select o.order_number, s.sequence_position, s.status as seq_status, s.reason, o.status as order_status
from wms.dispatch_sequences s join wms.outbound_orders o on o.id = s.outbound_order_id
where s.target_pallet_code = 'PLT-0005' order by s.sequence_position;
select status as plt0005_command_status from wms.equipment_commands where id = :'cmd4';

\echo ''
\echo '=============================================================='
\echo '11. Read model — sequence / pallet status'
\echo '   (spec: "서열/팔레트 현황 조회")'
\echo '=============================================================='

select pg_temp.act('wh-manager-a@demo.local');
set role authenticated;
select jsonb_pretty(jsonb_build_object(
  'sequences', (wms.wms_get_dispatch_sequence_status(:'tenant_a', :'wh_a', :'wave1', null))->'sequences',
  'pallets',   (wms.wms_get_dispatch_sequence_status(:'tenant_a', :'wh_a', :'wave1', null))->'pallets'
)) as wave1_status;
\echo '  filtering by the OTHER wave returns nothing from wave 1'
select jsonb_array_length((wms.wms_get_dispatch_sequence_status(:'tenant_a', :'wh_a', :'wave2', null))->'sequences')
  as wave2_sequence_count;
\echo '  a warehouse the caller cannot see'
select pg_temp.try(format('select wms.wms_get_dispatch_sequence_status(%L,%L,null,null)', :'tenant_b', :'wh_b'))
  as status_other_warehouse;
reset role;

\echo '  tenant B admin sees zero rows of tenant A data through RLS'
select pg_temp.act('admin-b@demo.local');
set role authenticated;
select count(*) as outbound_rows_visible_to_tenant_b from wms.outbound_orders;
select count(*) as sequence_rows_visible_to_tenant_b from wms.dispatch_sequences;
reset role;

\echo ''
\echo '=============================================================='
\echo '12. RLS / privilege surface'
\echo '   (spec: "테넌트·창고 단위 접근 통제")'
\echo '=============================================================='

select grantee, table_name, string_agg(privilege_type, ',' order by privilege_type) as privileges
from information_schema.role_table_grants
where table_schema = 'wms' and table_name in ('outbound_orders', 'dispatch_sequences')
  and grantee in ('authenticated', 'anon')
group by grantee, table_name order by table_name, grantee;

select relname, relrowsecurity as rls_enabled
from pg_class where relname in ('outbound_orders', 'dispatch_sequences');

\echo '  direct writes are impossible even for a fully-privileged demo role'
select pg_temp.act('wh-manager-a@demo.local');
set role authenticated;
select pg_temp.try_exec(format(
  'insert into wms.outbound_orders (tenant_id, warehouse_id, store_code, product_id, qty) '
  || 'values (%L,%L,%L,%L,1)', :'tenant_a', :'wh_a', 'STORE-HACK', :'sku1')) as direct_insert;
select pg_temp.try_exec('update wms.dispatch_sequences set status = ''COMPLETED''') as direct_update;
select pg_temp.try_exec('delete from wms.outbound_orders') as direct_delete;
reset role;

\echo '  the security definer functions this contract adds'
select p.proname, p.prosecdef as security_definer
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'wms'
  and p.proname in ('wms_create_outbound_order','wms_assign_dispatch_sequence',
                    'wms_cancel_dispatch_sequence','wms_dispatch_palletize_command',
                    'wms_get_dispatch_sequence_status','wms_get_pallet_manifest',
                    '_wms_validate_palletize_command','_wms_validate_palletize_outcome',
                    '_wms_propagate_palletize_result')
order by p.proname;

\echo ''
\echo '=============================================================='
\echo '13. Audit trail'
\echo '   (spec: "감사 추적")'
\echo '=============================================================='

select command, entity_type, count(*) as events
from wms.audit_events
where entity_type in ('outbound_order', 'dispatch_sequence')
group by command, entity_type order by command, entity_type;

\echo '  the per-item automatic propagation nobody clicked, with before/after:'
select left(entity_id::text, 8) as sequence,
       before->>'status' as before_status, after->>'status' as after_status,
       after->>'load_position' as load_position, correlation_id
from wms.audit_events
where command = 'wms_propagate_palletize_result' and entity_type = 'dispatch_sequence'
order by created_at;

\echo ''
\echo '=============================================================='
\echo '14. command_type extension actually took effect'
\echo '   (migration DEVIATION 1 — the RPC hard-codes the list too)'
\echo '=============================================================='

select pg_get_constraintdef(oid) as command_type_check
from pg_constraint
where conrelid = 'wms.equipment_commands'::regclass and conname = 'equipment_commands_command_type_check';

select command_type, count(*) from wms.equipment_commands group by command_type order by command_type;

\echo ''
\echo '=============================================================='
\echo 'DONE'
\echo '=============================================================='
