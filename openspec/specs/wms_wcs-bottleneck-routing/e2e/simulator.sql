\set QUIET on
\pset pager off
\pset format aligned
\set ON_ERROR_STOP on

-- ============================================================
-- wms_wcs-bottleneck-routing — psql simulator / verification script
-- (supabase/migrations/20260730_wcs_bottleneck_routing.sql)
--
-- Drives the bottleneck-routing contract exactly the way a real caller would:
-- it impersonates the seeded demo users by setting request.jwt.claims and
-- `set role authenticated`, so auth.uid(), wms.current_warehouse_ids() and
-- wms.has_role() behave as they do for a real Supabase session.
--
-- The equipment side (WCS_GATEWAY) is the same software-simulator idea as
-- areas 1-3 — no hardware, no PLC. Queue depth is produced by dispatching real
-- commands; fault frequency by raising and resolving real faults.
--
-- The last two sections are the ones that matter most: they prove the routing
-- verdict is actually consumed by wms_wes-material-flow-control's dispatch
-- path, not merely computable in isolation.
-- ============================================================

-- make the run repeatable without a full `supabase db reset`
truncate wms.wcs_routing_overrides, wms.wcs_routing_policies restart identity cascade;
truncate wms.work_orders, wms.dispatch_waves restart identity cascade;
truncate wms.sortation_profiles restart identity cascade;
truncate wms.equipment_status_events, wms.equipment_commands, wms.equipment_faults, wms.equipment
  restart identity cascade;
delete from wms.audit_events where command in (
  'wms_register_wcs_routing_policy','wms_update_wcs_routing_policy',
  'wms_exclude_equipment_from_routing','wms_clear_equipment_routing_exclusion',
  'wms_register_equipment','wms_dispatch_equipment_command','wms_report_command_result',
  'wms_report_equipment_status','wms_cancel_equipment_command',
  'wms_raise_equipment_fault','wms_resolve_equipment_fault',
  'wms_create_work_order','wms_dispatch_work_order','wms_retry_work_order_dispatch',
  'wms_cancel_work_order','wms_propagate_command_result');
delete from wms.idempotency_records where command_name in (
  'wms_register_wcs_routing_policy','wms_update_wcs_routing_policy',
  'wms_exclude_equipment_from_routing','wms_clear_equipment_routing_exclusion',
  'wms_register_equipment','wms_dispatch_equipment_command','wms_report_command_result',
  'wms_report_equipment_status','wms_cancel_equipment_command',
  'wms_raise_equipment_fault','wms_resolve_equipment_fault',
  'wms_create_work_order','wms_retry_work_order_dispatch','wms_cancel_work_order');

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

-- what wms.wcs_select_available_equipment would pick right now, as a code
create or replace function pg_temp.pick(p_zone text) returns text
language plpgsql as $fn$
declare v_id uuid;
begin
  v_id := wms.wcs_select_available_equipment(
    '10000000-0000-0000-0000-00000000000a',
    '20000000-0000-0000-0000-00000000000a',
    'AGV', p_zone);
  if v_id is null then return '(none — work order would stay QUEUED)'; end if;
  return (select equipment_code from wms.equipment where id = v_id);
end
$fn$;

-- dispatch helper: always reads the equipment's *current* version
create or replace function pg_temp.dispatch(p_equipment uuid, p_type text, p_actor uuid)
returns text language plpgsql as $fn$
begin
  return pg_temp.try(format(
    'select wms.wms_dispatch_equipment_command(%L,%L,''{}''::jsonb,%L,gen_random_uuid(),'
    || '(select version from wms.equipment where id = %L),%L,null,null)',
    p_equipment, p_type, p_actor, p_equipment, 'routing-sim'));
end
$fn$;

-- raise a fault and immediately resolve it, so the machine ends up IDLE again
-- but the fault stays inside the 30-minute observation window.
create or replace function pg_temp.fault_cycle(p_equipment uuid, p_code text, p_actor uuid)
returns text language plpgsql as $fn$
declare v_fault uuid;
begin
  v_fault := (wms.wms_raise_equipment_fault(
    p_equipment, p_code, 'WARNING', p_actor, gen_random_uuid(), 'routing-sim')->>'fault_id')::uuid;
  perform wms.wms_resolve_equipment_fault(
    v_fault, 'simulated recovery', p_actor, gen_random_uuid(),
    (select version from wms.equipment_faults where id = v_fault), 'routing-sim');
  return 'OK   fault ' || p_code || ' raised and resolved';
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
select id as buyer_a from auth.users where email = 'buyer-a@demo.local' \gset
select id as appr_a  from auth.users where email = 'approver-a@demo.local' \gset

\set QUIET off
\echo ''
\echo '=============================================================='
\echo '0. FIXTURE — three AGVs that compete for the same work, one'
\echo '   AGV in a queue-only zone, one SORTER with no policy, and a'
\echo '   receipt for area 2 work orders to hang off'
\echo '=============================================================='

select pg_temp.act('buyer-a@demo.local');
set role authenticated;
select wms.wms_create_rfq(:'tenant_a', :'wh_a', 'SKU-A-001', 40, null, :'buyer_a', gen_random_uuid(), 'routing-sim')->>'po_id' as po \gset
reset role;
select pg_temp.act('approver-a@demo.local');
set role authenticated;
select wms.wms_submit_purchase_approval(:'po', 'APPROVE', :'appr_a', 1, null)->>'version' as po_v \gset
reset role;
select pg_temp.act('buyer-a@demo.local');
set role authenticated;
select wms.wms_confirm_purchase_order(:'po', :'buyer_a', gen_random_uuid(), (:'po_v')::int)->>'receipt_id' as receipt \gset
reset role;

select pg_temp.act('wh-manager-a@demo.local');
set role authenticated;
select pg_temp.try(format(
  'select wms.wms_register_equipment(%L,%L,%L,%L,%L,%L,gen_random_uuid(),%L)',
  :'tenant_a', :'wh_a', 'RTE-AGV-01', 'AGV', 'ZONE-SIM-ROUTE', :'mgr_a', 'routing-sim')) as register_agv01;
select pg_temp.try(format(
  'select wms.wms_register_equipment(%L,%L,%L,%L,%L,%L,gen_random_uuid(),%L)',
  :'tenant_a', :'wh_a', 'RTE-AGV-02', 'AGV', 'ZONE-SIM-ROUTE', :'mgr_a', 'routing-sim')) as register_agv02;
select pg_temp.try(format(
  'select wms.wms_register_equipment(%L,%L,%L,%L,%L,%L,gen_random_uuid(),%L)',
  :'tenant_a', :'wh_a', 'RTE-AGV-03', 'AGV', 'ZONE-SIM-ROUTE', :'mgr_a', 'routing-sim')) as register_agv03;
select pg_temp.try(format(
  'select wms.wms_register_equipment(%L,%L,%L,%L,%L,%L,gen_random_uuid(),%L)',
  :'tenant_a', :'wh_a', 'RTE-AGV-09', 'AGV', 'ZONE-SIM-QUEUE', :'mgr_a', 'routing-sim')) as register_agv09;
select pg_temp.try(format(
  'select wms.wms_register_equipment(%L,%L,%L,%L,%L,%L,gen_random_uuid(),%L)',
  :'tenant_a', :'wh_a', 'RTE-SORT-01', 'SORTER', 'ZONE-SIM-QUEUE', :'mgr_a', 'routing-sim')) as register_sorter01;
reset role;

select id as agv01 from wms.equipment where equipment_code = 'RTE-AGV-01' \gset
select id as agv02 from wms.equipment where equipment_code = 'RTE-AGV-02' \gset
select id as agv03 from wms.equipment where equipment_code = 'RTE-AGV-03' \gset
select id as agv09 from wms.equipment where equipment_code = 'RTE-AGV-09' \gset
select id as sort01 from wms.equipment where equipment_code = 'RTE-SORT-01' \gset

select pg_temp.act('wcs-gateway-a@demo.local');
set role authenticated;
select pg_temp.try(format('select wms.wms_report_equipment_status(%L,%L,%L,gen_random_uuid(),1,null,%L)',
  :'agv01', 'IDLE', :'gw_a', 'routing-sim')) as boot_agv01;
select pg_temp.try(format('select wms.wms_report_equipment_status(%L,%L,%L,gen_random_uuid(),1,null,%L)',
  :'agv02', 'IDLE', :'gw_a', 'routing-sim')) as boot_agv02;
select pg_temp.try(format('select wms.wms_report_equipment_status(%L,%L,%L,gen_random_uuid(),1,null,%L)',
  :'agv03', 'IDLE', :'gw_a', 'routing-sim')) as boot_agv03;
select pg_temp.try(format('select wms.wms_report_equipment_status(%L,%L,%L,gen_random_uuid(),1,null,%L)',
  :'agv09', 'IDLE', :'gw_a', 'routing-sim')) as boot_agv09;
select pg_temp.try(format('select wms.wms_report_equipment_status(%L,%L,%L,gen_random_uuid(),1,null,%L)',
  :'sort01', 'IDLE', :'gw_a', 'routing-sim')) as boot_sorter01;
reset role;

select equipment_code, equipment_type, zone_code, status from wms.equipment order by equipment_code;

\echo ''
\echo '=============================================================='
\echo '1. Live load/health signals with no policy registered'
\echo '   (spec: "설비 부하·건강 신호 조회", "정책이 없는 설비 유형에는'
\echo '    기본 임계값이 적용된다")'
\echo '=============================================================='

\echo '  every machine is idle, so nothing is a bottleneck and the applied'
\echo '  thresholds are the system defaults (queue 3 / fault 1):'
select equipment_code, queue_depth, recent_completed_count, recent_fault_count,
       resolved_queue_depth_threshold as q_thr, resolved_fault_count_threshold as f_thr,
       (policy_id is null) as using_defaults, is_bottleneck, bottleneck_reasons
from wms.wcs_equipment_bottleneck_status order by equipment_code;

\echo ''
\echo '=============================================================='
\echo '2. Threshold policy registration'
\echo '   (spec: "병목 감지 임계값 정책 관리")'
\echo '=============================================================='

select pg_temp.act('wh-manager-a@demo.local');
set role authenticated;
\echo '  happy path — AGV gets queue 3 / fault 2 (stricter than the default 1)'
select pg_temp.try(format(
  'select wms.wms_register_wcs_routing_policy(%L,%L,%L,3,2,%L,gen_random_uuid(),%L)',
  :'tenant_a', :'wh_a', 'AGV', :'mgr_a', 'routing-sim')) as register_agv_policy;
\echo '  refusals'
select pg_temp.try(format(
  'select wms.wms_register_wcs_routing_policy(%L,%L,%L,5,2,%L,gen_random_uuid(),null)',
  :'tenant_a', :'wh_a', 'AGV', :'mgr_a')) as register_duplicate_type;
select pg_temp.try(format(
  'select wms.wms_register_wcs_routing_policy(%L,%L,%L,5,2,%L,gen_random_uuid(),null)',
  :'tenant_a', :'wh_a', 'DRONE', :'mgr_a')) as register_unknown_type;
select pg_temp.try(format(
  'select wms.wms_register_wcs_routing_policy(%L,%L,%L,0,2,%L,gen_random_uuid(),null)',
  :'tenant_a', :'wh_a', 'AMR', :'mgr_a')) as register_zero_queue_threshold;
select pg_temp.try(format(
  'select wms.wms_register_wcs_routing_policy(%L,%L,%L,3,0,%L,gen_random_uuid(),null)',
  :'tenant_a', :'wh_a', 'AMR', :'mgr_a')) as register_zero_fault_threshold;
select pg_temp.try(format(
  'select wms.wms_register_wcs_routing_policy(%L,%L,%L,3,2,%L,gen_random_uuid(),null)',
  :'tenant_a', :'wh_b', 'AMR', :'mgr_a')) as register_other_warehouse;
reset role;

\echo ''
\echo '  role refusals — WCS_OPERATOR may exclude equipment but may NOT tune'
\echo '  thresholds (migration DEVIATION 3), and an unrelated role gets nothing'
select pg_temp.act('wcs-operator-a@demo.local');
set role authenticated;
select pg_temp.try(format(
  'select wms.wms_register_wcs_routing_policy(%L,%L,%L,4,2,%L,gen_random_uuid(),null)',
  :'tenant_a', :'wh_a', 'SRM', :'op_a')) as register_as_wcs_operator;
reset role;
select pg_temp.act('quality-a@demo.local');
set role authenticated;
select pg_temp.try(format(
  'select wms.wms_register_wcs_routing_policy(%L,%L,%L,4,2,%L,gen_random_uuid(),null)',
  :'tenant_a', :'wh_a', 'SRM', :'qual_a')) as register_as_quality;
reset role;
select pg_temp.act('admin-b@demo.local');
set role authenticated;
select pg_temp.try(format(
  'select wms.wms_register_wcs_routing_policy(%L,%L,%L,4,2,%L,gen_random_uuid(),null)',
  :'tenant_a', :'wh_a', 'SRM', :'admin_b')) as register_cross_tenant;
select count(*) as tenant_b_sees_policies from wms.wcs_routing_policies;
reset role;

select id as agv_policy from wms.wcs_routing_policies where equipment_type = 'AGV' \gset

\echo ''
\echo '=============================================================='
\echo '3. Threshold policy update (spec: "정책의 임계값을 갱신한다",'
\echo '   "버전이 어긋나면 갱신이 거부된다")'
\echo '=============================================================='

select pg_temp.act('admin-a@demo.local');
set role authenticated;
\echo '  WMS_ADMIN widens the queue threshold with the right version'
select pg_temp.try(format(
  'select wms.wms_update_wcs_routing_policy(%L,%L,gen_random_uuid(),1,8,null,%L)',
  :'agv_policy', :'admin_a', 'routing-sim')) as update_queue_threshold;
\echo '  stale version / non-positive / nothing to update'
select pg_temp.try(format(
  'select wms.wms_update_wcs_routing_policy(%L,%L,gen_random_uuid(),1,9,null,null)',
  :'agv_policy', :'admin_a')) as update_stale_version;
select pg_temp.try(format(
  'select wms.wms_update_wcs_routing_policy(%L,%L,gen_random_uuid(),2,-1,null,null)',
  :'agv_policy', :'admin_a')) as update_negative_threshold;
select pg_temp.try(format(
  'select wms.wms_update_wcs_routing_policy(%L,%L,gen_random_uuid(),2,null,null,null)',
  :'agv_policy', :'admin_a')) as update_nothing;
\echo '  ...and back to 3 so the rest of the run uses a realistic value'
select pg_temp.try(format(
  'select wms.wms_update_wcs_routing_policy(%L,%L,gen_random_uuid(),2,3,null,null)',
  :'agv_policy', :'admin_a')) as update_back_to_three;
reset role;

select equipment_type, queue_depth_threshold, fault_count_threshold, version
from wms.wcs_routing_policies order by equipment_type;

\echo ''
\echo '=============================================================='
\echo '4. Bottleneck by QUEUE DEPTH (spec: "큐 길이가 임계값을 넘으면'
\echo '   병목으로 판정된다")'
\echo '=============================================================='

\echo '  three commands are stacked on RTE-AGV-09 (its own zone, so it never'
\echo '  competes with the routing tests below)'
select pg_temp.act('wh-manager-a@demo.local');
set role authenticated;
select pg_temp.dispatch(:'agv09', 'MOVE', :'mgr_a') as queue_cmd_1;
select pg_temp.dispatch(:'agv09', 'MOVE', :'mgr_a') as queue_cmd_2;
select pg_temp.dispatch(:'agv09', 'MOVE', :'mgr_a') as queue_cmd_3;
reset role;

select equipment_code, status, queue_depth, resolved_queue_depth_threshold as q_thr,
       is_bottleneck, bottleneck_reasons
from wms.wcs_equipment_bottleneck_status
where equipment_code in ('RTE-AGV-09', 'RTE-SORT-01') order by equipment_code;

\echo ''
\echo '  NOTE (migration DEVIATION 2): a machine with a queue is RUNNING and has'
\echo '  outstanding commands, so area 2 already refuses it as a candidate —'
\echo '  QUEUE_DEPTH_EXCEEDED is a monitoring signal, not a selection input.'
select 'RTE-AGV-09 would be routable?' as question,
       (not is_excluded) and status = 'IDLE' and queue_depth = 0 as answer
from wms.wcs_equipment_bottleneck_status where equipment_code = 'RTE-AGV-09';

\echo ''
\echo '=============================================================='
\echo '5. Bottleneck by FAULT FREQUENCY (spec: "최근 장애 건수가'
\echo '   임계값을 넘으면 병목으로 판정된다")'
\echo '=============================================================='

select pg_temp.act('wcs-operator-a@demo.local');
set role authenticated;
\echo '  one fault on RTE-AGV-02 — below the policy threshold of 2, so NOT yet'
select pg_temp.fault_cycle(:'agv02', 'SIM_DRIFT_1', :'op_a') as fault_cycle_1;
reset role;
select equipment_code, status, recent_fault_count, resolved_fault_count_threshold as f_thr,
       is_bottleneck, bottleneck_reasons
from wms.wcs_equipment_bottleneck_status where equipment_code = 'RTE-AGV-02';

select pg_temp.act('wcs-operator-a@demo.local');
set role authenticated;
\echo '  a second fault inside the 30-minute window tips it over'
select pg_temp.fault_cycle(:'agv02', 'SIM_DRIFT_2', :'op_a') as fault_cycle_2;
reset role;
select equipment_code, status, recent_fault_count, resolved_fault_count_threshold as f_thr,
       is_bottleneck, bottleneck_reasons
from wms.wcs_equipment_bottleneck_status where equipment_code = 'RTE-AGV-02';

\echo ''
\echo '  the machine is IDLE and command-free again — it is a perfectly legal'
\echo '  candidate that this contract merely PREFERS NOT to use:'
select equipment_code, status, queue_depth, recent_fault_count, is_bottleneck
from wms.wcs_equipment_bottleneck_status
where zone_code = 'ZONE-SIM-ROUTE' order by equipment_code;

\echo ''
\echo '=============================================================='
\echo '6. wms.wcs_select_available_equipment — the selection hook'
\echo '   (spec: "가용 설비 선택에 대한 병목 회피 반영", unit level)'
\echo '=============================================================='

\echo '  6a. all three clean-ish: area 2s original tie-break wins (oldest first)'
select pg_temp.pick('ZONE-SIM-ROUTE') as picked;

select pg_temp.act('wcs-operator-a@demo.local');
set role authenticated;
\echo ''
\echo '  6b. RTE-AGV-01 force-excluded -> candidates are AGV-02 (bottleneck)'
\echo '      and AGV-03 (clean). The clean one must win.'
select pg_temp.try(format(
  'select wms.wms_exclude_equipment_from_routing(%L,%L,%L,gen_random_uuid(),%L)',
  :'agv01', '계획 정비', :'op_a', 'routing-sim')) as exclude_agv01;
reset role;
select pg_temp.pick('ZONE-SIM-ROUTE') as picked;

select pg_temp.act('wcs-operator-a@demo.local');
set role authenticated;
\echo ''
\echo '  6c. AGV-03 excluded too -> only the bottleneck machine is left.'
\echo '      A bottleneck flag is a preference, not a veto: it IS selected.'
select pg_temp.try(format(
  'select wms.wms_exclude_equipment_from_routing(%L,%L,%L,gen_random_uuid(),%L)',
  :'agv03', '배터리 교체', :'op_a', 'routing-sim')) as exclude_agv03;
reset role;
select pg_temp.pick('ZONE-SIM-ROUTE') as picked;

select pg_temp.act('wcs-operator-a@demo.local');
set role authenticated;
\echo ''
\echo '  6d. AGV-02 excluded as well -> nothing at all. A force-exclusion IS a'
\echo '      veto, even when it removes the last candidate.'
select pg_temp.try(format(
  'select wms.wms_exclude_equipment_from_routing(%L,%L,%L,gen_random_uuid(),%L)',
  :'agv02', '센서 점검', :'op_a', 'routing-sim')) as exclude_agv02;
reset role;
select pg_temp.pick('ZONE-SIM-ROUTE') as picked;

select e.equipment_code, o.reason, o.status, o.version
from wms.wcs_routing_overrides o join wms.equipment e on e.id = o.equipment_id
order by e.equipment_code;

\echo ''
\echo '=============================================================='
\echo '7. Manual exclusion RPC edge cases'
\echo '   (spec: "설비 수동 라우팅 제외")'
\echo '=============================================================='

select pg_temp.act('wcs-operator-a@demo.local');
set role authenticated;
\echo '  duplicate ACTIVE exclusion / empty reason / unknown equipment'
select pg_temp.try(format(
  'select wms.wms_exclude_equipment_from_routing(%L,%L,%L,gen_random_uuid(),null)',
  :'agv01', '또 정비', :'op_a')) as exclude_duplicate;
select pg_temp.try(format(
  'select wms.wms_exclude_equipment_from_routing(%L,%L,%L,gen_random_uuid(),null)',
  :'agv09', '   ', :'op_a')) as exclude_blank_reason;
select pg_temp.try(format(
  'select wms.wms_exclude_equipment_from_routing(%L,%L,%L,gen_random_uuid(),null)',
  '00000000-0000-0000-0000-0000000000ff', 'nope', :'op_a')) as exclude_unknown_equipment;
\echo ''
\echo '  in-flight commands are NOT cancelled by an exclusion — the caller is told so'
select pg_temp.try(format(
  'select wms.wms_exclude_equipment_from_routing(%L,%L,%L,gen_random_uuid(),null)',
  :'agv09', '큐 소진 후 정비', :'op_a')) as exclude_busy_machine;
reset role;

\echo ''
\echo '  role / tenant refusals'
select pg_temp.act('quality-a@demo.local');
set role authenticated;
select pg_temp.try(format(
  'select wms.wms_exclude_equipment_from_routing(%L,%L,%L,gen_random_uuid(),null)',
  :'sort01', 'nope', :'qual_a')) as exclude_as_quality;
reset role;
select pg_temp.act('admin-b@demo.local');
set role authenticated;
select pg_temp.try(format(
  'select wms.wms_exclude_equipment_from_routing(%L,%L,%L,gen_random_uuid(),null)',
  :'sort01', 'nope', :'admin_b')) as exclude_cross_tenant;
select count(*) as tenant_b_sees_overrides from wms.wcs_routing_overrides;
reset role;

select id as ovr01 from wms.wcs_routing_overrides
  where equipment_id = :'agv01' and status = 'ACTIVE' \gset
select id as ovr02 from wms.wcs_routing_overrides
  where equipment_id = :'agv02' and status = 'ACTIVE' \gset
select id as ovr03 from wms.wcs_routing_overrides
  where equipment_id = :'agv03' and status = 'ACTIVE' \gset

\echo ''
\echo '  clearing: stale version -> CONFLICT, right version -> CLEARED,'
\echo '  second clear -> INVALID'
select pg_temp.act('wcs-operator-a@demo.local');
set role authenticated;
select pg_temp.try(format(
  'select wms.wms_clear_equipment_routing_exclusion(%L,%L,gen_random_uuid(),7,null)',
  :'ovr03', :'op_a')) as clear_stale_version;
select pg_temp.try(format(
  'select wms.wms_clear_equipment_routing_exclusion(%L,%L,gen_random_uuid(),1,%L)',
  :'ovr03', :'op_a', 'routing-sim')) as clear_agv03;
select pg_temp.try(format(
  'select wms.wms_clear_equipment_routing_exclusion(%L,%L,gen_random_uuid(),2,null)',
  :'ovr03', :'op_a')) as clear_again;
reset role;

select e.equipment_code, o.status, o.version, (o.cleared_by is not null) as has_cleared_by,
       (o.cleared_at is not null) as has_cleared_at
from wms.wcs_routing_overrides o join wms.equipment e on e.id = o.equipment_id
where e.equipment_code = 'RTE-AGV-03';

\echo ''
\echo '  AGV-03 is back in the candidate pool immediately (D2 — the verdict is'
\echo '  recomputed per query, nothing had to be rebuilt):'
select pg_temp.pick('ZONE-SIM-ROUTE') as picked;

\echo ''
\echo '=============================================================='
\echo '8. INTEGRATION with wms_wes-material-flow-control (area 2)'
\echo '   — the same four scenarios, but through the REAL dispatch RPC'
\echo '   instead of the selection function (tasks.md 6.2)'
\echo '=============================================================='

\echo '  state: AGV-01 excluded, AGV-02 excluded, AGV-03 free but'
\echo '  ...first make ALL of them excluded so the work order has nowhere to go.'
select pg_temp.act('wcs-operator-a@demo.local');
set role authenticated;
select pg_temp.try(format(
  'select wms.wms_exclude_equipment_from_routing(%L,%L,%L,gen_random_uuid(),%L)',
  :'agv03', '정비 재개', :'op_a', 'routing-sim')) as re_exclude_agv03;
reset role;

select pg_temp.act('wh-manager-a@demo.local');
set role authenticated;
\echo ''
\echo '  8a. every candidate force-excluded -> QUEUED + NO_EQUIPMENT_AVAILABLE'
select wms.wms_create_work_order(
  :'tenant_a', :'wh_a', 'PUTAWAY', 'receipt', :'receipt',
  'AGV', 'ZONE-SIM-ROUTE', 'MOVE', '{"to_zone":"ZONE-C"}'::jsonb, 'WAVELESS',
  :'mgr_a', gen_random_uuid(), null, 'routing-sim') as r \gset wo_
reset role;
select (:'wo_r'::jsonb)->>'status' as status, (:'wo_r'::jsonb)->'warnings' as warnings,
       (:'wo_r'::jsonb)->'links' as links;
select (:'wo_r'::jsonb)->>'work_order_id' as wo1 \gset

select pg_temp.act('wcs-operator-a@demo.local');
set role authenticated;
\echo ''
\echo '  8b. clear the CLEAN machine (AGV-03) and retry: it must be picked over'
\echo '      the bottleneck one, which is still excluded anyway'
select id as ovr03b from wms.wcs_routing_overrides
  where equipment_id = :'agv03' and status = 'ACTIVE' \gset
select pg_temp.try(format(
  'select wms.wms_clear_equipment_routing_exclusion(%L,%L,gen_random_uuid(),1,%L)',
  :'ovr03b', :'op_a', 'routing-sim')) as clear_agv03_again;
\echo '      ...and clear the BOTTLENECK machine too, so both compete honestly'
select pg_temp.try(format(
  'select wms.wms_clear_equipment_routing_exclusion(%L,%L,gen_random_uuid(),1,%L)',
  :'ovr02', :'op_a', 'routing-sim')) as clear_agv02;
reset role;

select equipment_code, status, is_bottleneck, is_excluded
from wms.wcs_equipment_bottleneck_status
where zone_code = 'ZONE-SIM-ROUTE' order by equipment_code;

select pg_temp.act('wh-manager-a@demo.local');
set role authenticated;
select wms.wms_retry_work_order_dispatch(:'wo1', :'mgr_a', gen_random_uuid(), 1, 'routing-sim') as r \gset rt_
reset role;
select (:'rt_r'::jsonb)->>'status' as status,
       (:'rt_r'::jsonb)->'links'->>'equipment_code' as dispatched_to,
       (:'rt_r'::jsonb)->'warnings' as warnings;

\echo ''
\echo '  8c. only the bottleneck machine is left free -> it IS used (fallback).'
\echo '      AGV-03 is now busy with 8b s command, AGV-01 is still excluded.'
select pg_temp.act('wh-manager-a@demo.local');
set role authenticated;
select wms.wms_create_work_order(
  :'tenant_a', :'wh_a', 'PUTAWAY', 'receipt', :'receipt',
  'AGV', 'ZONE-SIM-ROUTE', 'MOVE', '{"to_zone":"ZONE-D"}'::jsonb, 'WAVELESS',
  :'mgr_a', gen_random_uuid(), null, 'routing-sim') as r \gset wo2_
reset role;
select (:'wo2_r'::jsonb)->>'status' as status,
       (:'wo2_r'::jsonb)->'links'->>'equipment_code' as dispatched_to,
       (:'wo2_r'::jsonb)->'warnings' as warnings;

\echo ''
\echo '  8d. nothing free at all -> QUEUED again, without touching any override'
select pg_temp.act('wh-manager-a@demo.local');
set role authenticated;
select wms.wms_create_work_order(
  :'tenant_a', :'wh_a', 'PUTAWAY', 'receipt', :'receipt',
  'AGV', 'ZONE-SIM-ROUTE', 'MOVE', '{"to_zone":"ZONE-E"}'::jsonb, 'WAVELESS',
  :'mgr_a', gen_random_uuid(), null, 'routing-sim') as r \gset wo3_
reset role;
select (:'wo3_r'::jsonb)->>'status' as status, (:'wo3_r'::jsonb)->'warnings' as warnings;

\echo ''
\echo '  final work-order board (area 2 read model, unchanged by this contract):'
select wo.status, e.equipment_code, c.command_type, c.status as command_status
from wms.work_orders wo
left join wms.equipment_commands c on c.id = wo.equipment_command_id
left join wms.equipment e on e.id = c.equipment_id
order by wo.created_at;

\echo ''
\echo '=============================================================='
\echo '9. Read RPC — wms_get_equipment_routing_status'
\echo '=============================================================='

select pg_temp.act('wcs-operator-a@demo.local');
set role authenticated;
select jsonb_pretty(
  wms.wms_get_equipment_routing_status(:'tenant_a', :'wh_a', :'agv02')
) as routing_status_agv02;
select (wms.wms_get_equipment_routing_status(:'tenant_a', :'wh_a', null)->>'count')::int as machines_visible;
reset role;

\echo '  a tenant-B admin gets FORBIDDEN on warehouse A and sees nothing of its own'
select pg_temp.act('admin-b@demo.local');
set role authenticated;
select pg_temp.try(format('select wms.wms_get_equipment_routing_status(%L,%L,null)',
  :'tenant_a', :'wh_a')) as read_cross_tenant;
select (wms.wms_get_equipment_routing_status(:'tenant_b', :'wh_b', null)->>'count')::int as tenant_b_machines;
select count(*) as tenant_b_sees_load_rows from wms.wcs_equipment_bottleneck_status;
reset role;

\echo ''
\echo '=============================================================='
\echo '10. RLS / grants (spec: "테넌트·창고 단위 접근 통제")'
\echo '=============================================================='

select grantee, table_name, string_agg(privilege_type, ',' order by privilege_type) as privileges
from information_schema.role_table_grants
where table_schema = 'wms'
  and table_name in ('wcs_routing_policies', 'wcs_routing_overrides',
                     'wcs_equipment_load_snapshot', 'wcs_equipment_bottleneck_status')
  and grantee in ('authenticated', 'anon', 'public')
group by grantee, table_name order by table_name, grantee;

select relname, relrowsecurity as rls_enabled
from pg_class where relname in ('wcs_routing_policies', 'wcs_routing_overrides');

select pg_temp.act('wcs-operator-a@demo.local');
set role authenticated;
select pg_temp.try_exec(format(
  'insert into wms.wcs_routing_policies (tenant_id, warehouse_id, equipment_type,'
  || ' queue_depth_threshold, fault_count_threshold) values (%L,%L,%L,1,1)',
  :'tenant_a', :'wh_a', 'SRM')) as direct_insert_policy;
select pg_temp.try_exec(
  'update wms.wcs_routing_overrides set reason = ''hacked''') as direct_update_override;
select pg_temp.try_exec(
  'delete from wms.wcs_routing_overrides') as direct_delete_override;
\echo '  the internal selection hook is not callable by an app user:'
select pg_temp.try(format(
  'select to_jsonb(wms.wcs_select_available_equipment(%L,%L,%L,%L))',
  :'tenant_a', :'wh_a', 'AGV', 'ZONE-SIM-ROUTE')) as call_selection_hook_as_app_user;
reset role;

\echo '  ...and its ACL confirms it (no authenticated/PUBLIC EXECUTE):'
select proname, coalesce(array_to_string(proacl, ' '), '(owner only)') as acl
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'wms' and proname = 'wcs_select_available_equipment';

\echo ''
\echo '=============================================================='
\echo '11. Idempotency (tasks.md 3.8)'
\echo '=============================================================='

select gen_random_uuid() as idem \gset
select pg_temp.act('wcs-operator-a@demo.local');
set role authenticated;
select pg_temp.try(format(
  'select wms.wms_exclude_equipment_from_routing(%L,%L,%L,%L,null)',
  :'sort01', '멱등성 테스트', :'op_a', :'idem')) as exclude_first_call;
select pg_temp.try(format(
  'select wms.wms_exclude_equipment_from_routing(%L,%L,%L,%L,null)',
  :'sort01', '멱등성 테스트', :'op_a', :'idem')) as exclude_replay;
reset role;
select count(*) as override_rows_for_sorter
from wms.wcs_routing_overrides where equipment_id = :'sort01';

\echo ''
\echo '=============================================================='
\echo '12. Audit coverage (spec: "감사 추적")'
\echo '=============================================================='

select command, entity_type, count(*)
from wms.audit_events
where entity_type in ('wcs_routing_policy', 'wcs_routing_override')
group by command, entity_type order by command;

\echo '  the exclusion row carries after.status = ACTIVE, the clear row the transition:'
select command, before->>'status' as before_status, after->>'status' as after_status,
       after->>'reason' as reason
from wms.audit_events
where entity_type = 'wcs_routing_override'
order by created_at limit 6;

\echo ''
\echo '=============================================================='
\echo 'DONE'
\echo '=============================================================='
