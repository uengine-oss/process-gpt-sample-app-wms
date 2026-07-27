\set QUIET on
\pset pager off
\pset format aligned
\set ON_ERROR_STOP on

-- ============================================================
-- wms_operations-audit-log — psql verification suite
--
--   docker exec -i supabase_db_process-gpt-sample-app-wms \
--     psql -U postgres -d postgres -f - < verify.sql
--
-- Self-contained: builds its own AUDIT-V-* fixtures, exercises
-- wms.describe_audit_event and both RPCs against every scenario in
-- specs/wms_operations-audit-log/spec.md, then cleans up. Safe to re-run
-- without a db reset.
--
-- What this suite exists to prove, in order of how easy it is to get wrong:
--
--   1. THE SUMMARY NEVER BREAKS A PAGE. 65 of 65 shipped commands have a
--      dedicated Korean template (§B1 counts them from the same grep the
--      migration header quotes), the fallback catches anything new, and a
--      NULL `before`, a NULL `after`, an empty JSONB and a NULL command all
--      produce a sentence rather than a NULL or an error.
--   2. THE ROLE GATE IS REAL AND THE OLD ONE IS UNCHANGED. §F refuses five
--      roles on both RPCs; §G then has one of those same refused users SELECT
--      wms.audit_events directly, under RLS, and succeed — because D2 says the
--      raw table stays open and only this contract's surface is narrowed.
--   3. THE EXPORT AUDITS ITSELF, AND NOT INTO ITS OWN RESULT. §H exports,
--      proves the returned rows do NOT contain the export event, then re-reads
--      and proves they now do.
--   4. THE AGENT-REASONING JOIN IS A JOIN, NOT A FAN-OUT. §I plants two
--      decisions under one correlation_id — the shape a plain LEFT JOIN would
--      duplicate rows on — and checks the event still appears exactly once.
-- ============================================================

\set tenant_a '10000000-0000-0000-0000-00000000000a'
\set wh_a     '20000000-0000-0000-0000-00000000000a'
\set tenant_b '10000000-0000-0000-0000-00000000000b'

-- SECURITY DEFINER because §G drops the session role to `authenticated`,
-- which has no privilege on auth.users.
create or replace function pg_temp.act(p_email text) returns void
language plpgsql security definer as $fn$
declare v_id uuid;
begin
  select id into v_id from auth.users where email = p_email;
  if v_id is null then raise exception 'no such demo user: %', p_email; end if;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_id::text, 'role', 'authenticated')::text, false);
end
$fn$;

create or replace function pg_temp.uid(p_email text) returns uuid
language sql stable security definer
as $fn$ select id from auth.users where email = p_email $fn$;

create or replace function pg_temp.expect_error(p_sql text) returns text
language plpgsql as $fn$
begin
  execute p_sql;
  return 'NO_ERROR';
exception when others then
  return split_part(sqlerrm, ':', 1);
end
$fn$;

create or replace function pg_temp.error_text(p_sql text) returns text
language plpgsql as $fn$
begin
  execute p_sql;
  return 'NO_ERROR';
exception when others then
  return left(sqlerrm, 120);
end
$fn$;

-- Same-statement snapshot trap (this bit four earlier areas): a row written
-- and read back inside ONE psql statement does not see itself. Anything that
-- needs an id it just created parks it here first.
create table if not exists pg_temp.v (k text primary key, val text);
create or replace function pg_temp.put(p_k text, p_v text) returns text
language sql as $fn$
  insert into pg_temp.v values (p_k, p_v)
  on conflict (k) do update set val = excluded.val returning val;
$fn$;
create or replace function pg_temp.get(p_k text) returns text
language sql stable as $fn$ select val from pg_temp.v where k = p_k $fn$;

-- ------------------------------------------------------------
-- Clean slate for this suite's own fixtures.
-- ------------------------------------------------------------
delete from wms.audit_events where correlation_id like 'AUDIT-V-%';
delete from wms.agent_decisions where reasoning like 'AUDIT-V%';
delete from wms.receipts where po_id in
  (select id from wms.purchase_orders where correlation_id like 'AUDIT-V-%');
delete from wms.purchase_orders where correlation_id like 'AUDIT-V-%';
delete from wms.docks where code like 'AUDIT-V-%';
truncate pg_temp.v;

\set QUIET off
\echo
\echo '============================================================'
\echo 'A. 대상 확인 — 계약이 얹히는 기존 자산'
\echo '============================================================'

select
  to_regclass('wms.audit_events')      is not null as audit_events_exists,
  to_regclass('wms.agent_decisions')   is not null as agent_decisions_exists,
  (select count(*) from information_schema.columns
    where table_schema='wms' and table_name='audit_events')::int as audit_event_columns,
  (select count(*) from pg_policies
    where schemaname='wms' and tablename='audit_events')::int as audit_event_policies;

-- The three functions this contract adds, and nothing else.
select p.proname, pg_get_function_result(p.oid) as returns,
       case p.provolatile when 'i' then 'immutable' when 's' then 'stable' else 'volatile' end as volatility,
       p.prosecdef as security_definer
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'wms'
  and p.proname in ('describe_audit_event','wms_query_audit_log','wms_export_audit_log')
order by p.proname;

-- D2 / tasks.md 2.5: the pre-existing policy, byte for byte.
select policyname, cmd, qual
from pg_policies where schemaname='wms' and tablename='audit_events';

\echo
\echo '============================================================'
\echo 'B. wms.describe_audit_event — 결정론적 한국어 요약'
\echo '============================================================'
\echo
\echo '-- B1. 실제로 쓰이는 65개 command 전부에 전용 템플릿이 있는가'
\echo '--     (fallback 문장과 다르면 전용 분기가 존재한다는 뜻)'

with shipped(command, entity_type) as (values
  ('wms_advance_simulated_command','simulation_command_schedule'),
  ('wms_apply_disposition','receipt'),
  ('wms_apply_slotting_recommendation','slotting_recommendation'),
  ('wms_assign_dispatch_sequence','dispatch_sequence'),
  ('wms_assign_sku_location','sku_location_assignment'),
  ('wms_cancel_dispatch_sequence','dispatch_sequence'),
  ('wms_cancel_dock_appointment','dock_appointment'),
  ('wms_cancel_equipment_command','equipment_command'),
  ('wms_cancel_labor_activity','labor_activity'),
  ('wms_cancel_work_order','work_order'),
  ('wms_check_in_vehicle','dock_appointment'),
  ('wms_clear_equipment_routing_exclusion','wcs_routing_override'),
  ('wms_complete_labor_activity','labor_activity'),
  ('wms_compute_sku_velocity','sku_velocity_batch'),
  ('wms_confirm_agent_proposal','agent_decision'),
  ('wms_confirm_purchase_order','purchase_order'),
  ('wms_create_outbound_order','outbound_order'),
  ('wms_create_putaway_tasks','receipt'),
  ('wms_create_rfq','purchase_order'),
  ('wms_create_simulation_scenario','simulation_scenario'),
  ('wms_create_sortation_profile','sortation_profile'),
  ('wms_create_work_order','work_order'),
  ('wms_depart_vehicle','dock_appointment'),
  ('wms_dispatch_equipment_command','equipment_command'),
  ('wms_dispatch_palletize_command','dispatch_sequence'),
  ('wms_dispatch_work_order','work_order'),
  ('wms_dock_vehicle','dock_appointment'),
  ('wms_escalate_sortation_jam','equipment_fault'),
  ('wms_exclude_equipment_from_routing','wcs_routing_override'),
  ('wms_generate_slotting_recommendations','slotting_recommendation'),
  ('wms_log_agent_decision','agent_decision'),
  ('wms_open_dispatch_wave','dispatch_wave'),
  ('wms_plan_simulated_command','simulation_command_schedule'),
  ('wms_propagate_command_result','work_order'),
  ('wms_propagate_palletize_result','dispatch_sequence'),
  ('wms_propose_agent_action','agent_decision'),
  ('wms_raise_equipment_fault','equipment_fault'),
  ('wms_reassign_sku_location','sku_location_assignment'),
  ('wms_receive','receipt'),
  ('wms_record_quality_result','receipt'),
  ('wms_register_arrival','receipt'),
  ('wms_register_dock','dock'),
  ('wms_register_equipment','equipment'),
  ('wms_register_simulation_profile','simulation_profile'),
  ('wms_register_slotting_class_policy','slotting_class_policy'),
  ('wms_register_storage_location','storage_location'),
  ('wms_register_wcs_routing_policy','wcs_routing_policy'),
  ('wms_reject_agent_proposal','agent_decision'),
  ('wms_release_dispatch_wave','dispatch_wave'),
  ('wms_report_command_result','equipment_command'),
  ('wms_report_equipment_status','equipment'),
  ('wms_resolve_equipment_fault','equipment_fault'),
  ('wms_retry_work_order_dispatch','work_order'),
  ('wms_review_slotting_recommendation','slotting_recommendation'),
  ('wms_run_simulation_scenario','simulation_scenario_run'),
  ('wms_schedule_dock_appointment','dock_appointment'),
  ('wms_set_dock_status','dock'),
  ('wms_set_equipment_simulation_mode','equipment'),
  ('wms_set_storage_location_status','storage_location'),
  ('wms_start_labor_activity','labor_activity'),
  ('wms_submit_purchase_approval','purchase_order'),
  ('wms_update_simulation_profile','simulation_profile'),
  ('wms_update_slotting_class_policy','slotting_class_policy'),
  ('wms_update_sortation_profile','sortation_profile'),
  ('wms_update_wcs_routing_policy','wcs_routing_policy')
), described as (
  select command, entity_type,
         wms.describe_audit_event(command, entity_type, null, '{}'::jsonb) as summary,
         format('%s 엔티티에 대해 %s 명령이 실행되었다.',
                wms._audit_entity_ko(entity_type), command) as fallback
  from shipped
)
select
  count(*)::int                                                      as shipped_commands,
  count(*) filter (where summary is distinct from fallback)::int     as with_dedicated_template,
  count(*) filter (where summary = fallback)::int                    as fell_through_to_fallback,
  count(*) filter (where summary is null or btrim(summary) = '')::int as null_or_blank
from described;

\echo
\echo '-- B1b. 전용 템플릿이 없는 command 목록 (비어 있어야 한다)'
with shipped(command, entity_type) as (values
  ('wms_advance_simulated_command','simulation_command_schedule'),
  ('wms_apply_disposition','receipt'),
  ('wms_apply_slotting_recommendation','slotting_recommendation'),
  ('wms_assign_dispatch_sequence','dispatch_sequence'),
  ('wms_assign_sku_location','sku_location_assignment'),
  ('wms_cancel_dispatch_sequence','dispatch_sequence'),
  ('wms_cancel_dock_appointment','dock_appointment'),
  ('wms_cancel_equipment_command','equipment_command'),
  ('wms_cancel_labor_activity','labor_activity'),
  ('wms_cancel_work_order','work_order'),
  ('wms_check_in_vehicle','dock_appointment'),
  ('wms_clear_equipment_routing_exclusion','wcs_routing_override'),
  ('wms_complete_labor_activity','labor_activity'),
  ('wms_compute_sku_velocity','sku_velocity_batch'),
  ('wms_confirm_agent_proposal','agent_decision'),
  ('wms_confirm_purchase_order','purchase_order'),
  ('wms_create_outbound_order','outbound_order'),
  ('wms_create_putaway_tasks','receipt'),
  ('wms_create_rfq','purchase_order'),
  ('wms_create_simulation_scenario','simulation_scenario'),
  ('wms_create_sortation_profile','sortation_profile'),
  ('wms_create_work_order','work_order'),
  ('wms_depart_vehicle','dock_appointment'),
  ('wms_dispatch_equipment_command','equipment_command'),
  ('wms_dispatch_palletize_command','dispatch_sequence'),
  ('wms_dispatch_work_order','work_order'),
  ('wms_dock_vehicle','dock_appointment'),
  ('wms_escalate_sortation_jam','equipment_fault'),
  ('wms_exclude_equipment_from_routing','wcs_routing_override'),
  ('wms_generate_slotting_recommendations','slotting_recommendation'),
  ('wms_log_agent_decision','agent_decision'),
  ('wms_open_dispatch_wave','dispatch_wave'),
  ('wms_plan_simulated_command','simulation_command_schedule'),
  ('wms_propagate_command_result','work_order'),
  ('wms_propagate_palletize_result','dispatch_sequence'),
  ('wms_propose_agent_action','agent_decision'),
  ('wms_raise_equipment_fault','equipment_fault'),
  ('wms_reassign_sku_location','sku_location_assignment'),
  ('wms_receive','receipt'),
  ('wms_record_quality_result','receipt'),
  ('wms_register_arrival','receipt'),
  ('wms_register_dock','dock'),
  ('wms_register_equipment','equipment'),
  ('wms_register_simulation_profile','simulation_profile'),
  ('wms_register_slotting_class_policy','slotting_class_policy'),
  ('wms_register_storage_location','storage_location'),
  ('wms_register_wcs_routing_policy','wcs_routing_policy'),
  ('wms_reject_agent_proposal','agent_decision'),
  ('wms_release_dispatch_wave','dispatch_wave'),
  ('wms_report_command_result','equipment_command'),
  ('wms_report_equipment_status','equipment'),
  ('wms_resolve_equipment_fault','equipment_fault'),
  ('wms_retry_work_order_dispatch','work_order'),
  ('wms_review_slotting_recommendation','slotting_recommendation'),
  ('wms_run_simulation_scenario','simulation_scenario_run'),
  ('wms_schedule_dock_appointment','dock_appointment'),
  ('wms_set_dock_status','dock'),
  ('wms_set_equipment_simulation_mode','equipment'),
  ('wms_set_storage_location_status','storage_location'),
  ('wms_start_labor_activity','labor_activity'),
  ('wms_submit_purchase_approval','purchase_order'),
  ('wms_update_simulation_profile','simulation_profile'),
  ('wms_update_slotting_class_policy','slotting_class_policy'),
  ('wms_update_sortation_profile','sortation_profile'),
  ('wms_update_wcs_routing_policy','wcs_routing_policy')
)
select command from shipped
where wms.describe_audit_event(command, entity_type, null, '{}'::jsonb)
    = format('%s 엔티티에 대해 %s 명령이 실행되었다.', wms._audit_entity_ko(entity_type), command);

\echo
\echo '-- B2. 알려지지 않은 명령 → 범용 폴백 (오류도 NULL도 아니다)'
select wms.describe_audit_event('wms_new_future_command','future_entity',null,null) as fallback_unknown_entity;
select wms.describe_audit_event('wms_new_future_command','purchase_order',null,null) as fallback_known_entity;
select wms.describe_audit_event(null, null, null, null) as fallback_all_null;

\echo
\echo '-- B3. before가 NULL이고 after만 있는 전형적 생성 이벤트'
select wms.describe_audit_event(
  'wms_create_rfq','purchase_order', null,
  jsonb_build_object('qty',120,'status','TO_APPROVE')) as create_rfq;
\echo '--     after의 일부 필드가 아예 없어도 문장이 깨지지 않는다'
select wms.describe_audit_event('wms_create_rfq','purchase_order', null, '{}'::jsonb) as create_rfq_empty_after;
select wms.describe_audit_event('wms_receive','receipt', null, jsonb_build_object('status','QC_PENDING')) as receive_partial;

\echo
\echo '-- B4. before → after 전이가 문장에 드러난다'
select wms.describe_audit_event(
  'wms_set_dock_status','dock',
  jsonb_build_object('code','DOCK-01','status','AVAILABLE'),
  jsonb_build_object('code','DOCK-01','status','MAINTENANCE','reason','정기 점검')) as dock_status_change;

\echo
\echo '-- B5. 선택 절은 값이 없으면 아예 렌더링되지 않는다 (", 사유 —" 같은 찌꺼기 금지)'
select wms.describe_audit_event('wms_cancel_work_order','work_order',
         jsonb_build_object('status','QUEUED'), jsonb_build_object('status','CANCELLED')) as no_reason,
       wms.describe_audit_event('wms_cancel_work_order','work_order',
         jsonb_build_object('status','QUEUED'),
         jsonb_build_object('status','CANCELLED','reason','상위 웨이브 취소')) as with_reason;

\echo
\echo '-- B6. 같은 command가 두 엔티티에 두 행을 남기는 경우 문장이 서로 다르다'
select wms.describe_audit_event('wms_dock_vehicle','dock',
         jsonb_build_object('code','DOCK-01','status','AVAILABLE'),
         jsonb_build_object('code','DOCK-01','status','OCCUPIED')) as as_dock;
select wms.describe_audit_event('wms_dock_vehicle','dock_appointment',
         jsonb_build_object('status','CHECKED_IN'),
         jsonb_build_object('status','DOCKED','vehicle_plate_no','77바1234')) as as_appointment;

\echo
\echo '-- B7. 판단 근거가 붙으면 문장 끝에 "(사유: ...)"가 덧붙는다'
select wms.describe_audit_event(
  'wms_dispatch_equipment_command','equipment_command', null,
  jsonb_build_object('command_type','MOVE','status','DISPATCHED'),
  '재고 부족으로 대체 설비로 재배치') as with_reasoning;
\echo '--     공백뿐인 근거는 붙이지 않는다'
select wms.describe_audit_event('wms_receive','receipt', null,
  jsonb_build_object('status','QC_PENDING'), '   ') as blank_reasoning;

\echo
\echo '-- B8. IMMUTABLE — 같은 입력은 항상 같은 문장'
select wms.describe_audit_event('wms_receive','receipt',null,jsonb_build_object('status','QC_PENDING'))
     = wms.describe_audit_event('wms_receive','receipt',null,jsonb_build_object('status','QC_PENDING'))
  as deterministic;

\echo
\echo '============================================================'
\echo 'C. happy path — 실제 명령이 남긴 감사 이벤트를 감사자가 읽는다'
\echo '============================================================'

select pg_temp.act('buyer-a@demo.local');
select pg_temp.put('po', (wms.wms_create_rfq(
  :'tenant_a', :'wh_a', 'SKU-A-001', 77,
  (select id from wms.suppliers where tenant_id = :'tenant_a' limit 1),
  pg_temp.uid('buyer-a@demo.local'), gen_random_uuid(), 'AUDIT-V-CORR-PO'))->>'po_id');

select pg_temp.act('approver-a@demo.local');
select wms.wms_submit_purchase_approval(
  pg_temp.get('po')::uuid, 'APPROVE', pg_temp.uid('approver-a@demo.local'), 1,
  'AUDIT-V: 재주문점 미달로 승인') ->> 'status' as approved;

select pg_temp.act('buyer-a@demo.local');
select wms.wms_confirm_purchase_order(
  pg_temp.get('po')::uuid, pg_temp.uid('buyer-a@demo.local'), gen_random_uuid(), 2) ->> 'status' as confirmed;

-- The PO chain writes its own audit rows; only wms_create_rfq carries a
-- correlation_id (the other two core RPCs never took one), so the entity id is
-- how this suite finds all three.
\echo
\echo '-- C1. 감사자가 이 발주 건의 이력을 조회한다 (최신순, 한국어 요약)'
select pg_temp.act('auditor-a@demo.local');
select r->>'command' as command,
       r->>'actor_email' as actor,
       r->>'summary_ko' as summary_ko
from jsonb_array_elements(
  wms.wms_query_audit_log(:'tenant_a', p_entity_id => pg_temp.get('po')::uuid) -> 'rows') r;

\echo
\echo '-- C2. WMS_ADMIN도 같은 조회를 할 수 있다 (역할 슈퍼셋 관례)'
select pg_temp.act('admin-a@demo.local');
select (wms.wms_query_audit_log(:'tenant_a', p_entity_id => pg_temp.get('po')::uuid))->>'total_count' as admin_total;

\echo
\echo '============================================================'
\echo 'D. 필터 — 기간 / 행위자 / 엔티티 / 명령 / 상관관계 ID'
\echo '============================================================'

select pg_temp.act('auditor-a@demo.local');

\echo '-- D1. command 필터'
select (wms.wms_query_audit_log(:'tenant_a', p_command => 'wms_create_rfq'))->>'total_count' as rfq_events;

\echo '-- D2. entity_type 필터'
select (wms.wms_query_audit_log(:'tenant_a', p_entity_type => 'purchase_order'))->>'total_count' as po_events,
       (wms.wms_query_audit_log(:'tenant_a', p_entity_type => 'no_such_entity'))->>'total_count' as unknown_entity_events;

\echo '-- D3. actor 필터'
select (wms.wms_query_audit_log(:'tenant_a', p_actor_id => pg_temp.uid('buyer-a@demo.local')))->>'total_count' as by_buyer,
       (wms.wms_query_audit_log(:'tenant_a', p_actor_id => pg_temp.uid('approver-a@demo.local')))->>'total_count' as by_approver;

\echo '-- D4. correlation_id 필터'
select (wms.wms_query_audit_log(:'tenant_a', p_correlation_id => 'AUDIT-V-CORR-PO'))->>'total_count' as by_correlation;

\echo '-- D5. 필터 조합 (기간 + entity_type + actor)'
select (wms.wms_query_audit_log(
          :'tenant_a',
          p_date_from   => now() - interval '1 hour',
          p_date_to     => now() + interval '1 hour',
          p_actor_id    => pg_temp.uid('buyer-a@demo.local'),
          p_entity_type => 'purchase_order'))->>'total_count' as combined;

\echo '-- D6. 기간 경계는 양끝 포함 (date_to는 inclusive)'
insert into wms.audit_events (tenant_id, actor_id, command, entity_type, correlation_id, created_at)
values (:'tenant_a', pg_temp.uid('buyer-a@demo.local'), 'wms_create_rfq', 'purchase_order',
        'AUDIT-V-BOUNDARY', timestamptz '2026-03-15 12:00:00+00');
select
  (wms.wms_query_audit_log(:'tenant_a', p_correlation_id => 'AUDIT-V-BOUNDARY',
     p_date_from => timestamptz '2026-03-15 12:00:00+00'))->>'total_count' as from_exactly_on_it,
  (wms.wms_query_audit_log(:'tenant_a', p_correlation_id => 'AUDIT-V-BOUNDARY',
     p_date_to   => timestamptz '2026-03-15 12:00:00+00'))->>'total_count' as to_exactly_on_it,
  (wms.wms_query_audit_log(:'tenant_a', p_correlation_id => 'AUDIT-V-BOUNDARY',
     p_date_from => timestamptz '2026-03-15 12:00:01+00'))->>'total_count' as from_one_second_later;

\echo
\echo '============================================================'
\echo 'E. 페이지네이션 — 120건 픽스처로 산수를 검증한다'
\echo '============================================================'

insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, after, correlation_id, created_at)
select :'tenant_a', pg_temp.uid('inbound-a@demo.local'), 'wms_receive', 'receipt', gen_random_uuid(),
       jsonb_build_object('status','QC_PENDING','received_qty',g,'expected_qty',g),
       'AUDIT-V-PAGE', now() - make_interval(secs => g)
from generate_series(1,120) g;

select pg_temp.act('auditor-a@demo.local');

\echo '-- E1. 1페이지 (limit 50, offset 0)'
select (q->>'row_count') as row_count, (q->>'total_count') as total_count,
       (q->>'page_count') as page_count, (q->>'has_more') as has_more
from (select wms.wms_query_audit_log(:'tenant_a', p_correlation_id => 'AUDIT-V-PAGE',
              p_limit => 50, p_offset => 0) q) s;

\echo '-- E2. 2페이지 (offset 50) — 51~100번째'
select (q->>'row_count') as row_count, (q->>'total_count') as total_count, (q->>'has_more') as has_more,
       (q->'rows'->0->'after'->>'received_qty') as first_row_qty,
       (q->'rows'->49->'after'->>'received_qty') as last_row_qty
from (select wms.wms_query_audit_log(:'tenant_a', p_correlation_id => 'AUDIT-V-PAGE',
              p_limit => 50, p_offset => 50) q) s;

\echo '-- E3. 마지막 페이지 (offset 100) — 20건, has_more=false'
select (q->>'row_count') as row_count, (q->>'has_more') as has_more
from (select wms.wms_query_audit_log(:'tenant_a', p_correlation_id => 'AUDIT-V-PAGE',
              p_limit => 50, p_offset => 100) q) s;

\echo '-- E4. 끝을 넘어선 페이지 — 행은 0이지만 total_count는 살아 있다'
\echo '--     (count(*) over()를 쓰지 않은 이유)'
select (q->>'row_count') as row_count, (q->>'total_count') as total_count, (q->>'has_more') as has_more
from (select wms.wms_query_audit_log(:'tenant_a', p_correlation_id => 'AUDIT-V-PAGE',
              p_limit => 50, p_offset => 500) q) s;

\echo '-- E5. 정렬은 최신순 — 첫 행이 가장 최근이다'
select (q->'rows'->0->>'created_at') > (q->'rows'->1->>'created_at') as newest_first
from (select wms.wms_query_audit_log(:'tenant_a', p_correlation_id => 'AUDIT-V-PAGE', p_limit => 5) q) s;

\echo '-- E6. limit / offset 범위 밖은 INVALID'
select pg_temp.error_text(format('select wms.wms_query_audit_log(%L, p_limit => 0)',   :'tenant_a')) as limit_zero,
       pg_temp.error_text(format('select wms.wms_query_audit_log(%L, p_limit => 501)', :'tenant_a')) as limit_over_max,
       pg_temp.error_text(format('select wms.wms_query_audit_log(%L, p_offset => -1)', :'tenant_a')) as negative_offset;

\echo '-- E7. 뒤집힌 기간도 INVALID'
select pg_temp.error_text(format(
  'select wms.wms_query_audit_log(%L, p_date_from => now(), p_date_to => now() - interval ''1 day'')',
  :'tenant_a')) as reversed_range;

\echo
\echo '============================================================'
\echo 'F. 역할 게이트 (D2) — 감사 표면은 WMS_ADMIN / AUDITOR 전용'
\echo '============================================================'

\echo '-- F1. 비허용 역할 4종 × 조회 RPC'
select pg_temp.act('inbound-a@demo.local');
select 'inbound-a' as who, pg_temp.error_text(format('select wms.wms_query_audit_log(%L)', :'tenant_a')) as query_rpc;
select pg_temp.act('quality-a@demo.local');
select 'quality-a' as who, pg_temp.error_text(format('select wms.wms_query_audit_log(%L)', :'tenant_a')) as query_rpc;
select pg_temp.act('buyer-a@demo.local');
select 'buyer-a' as who, pg_temp.error_text(format('select wms.wms_query_audit_log(%L)', :'tenant_a')) as query_rpc;
select pg_temp.act('process-agent-a@demo.local');
select 'process-agent-a' as who, pg_temp.error_text(format('select wms.wms_query_audit_log(%L)', :'tenant_a')) as query_rpc;

\echo '-- F2. 같은 4종 × 내보내기 RPC'
select pg_temp.act('inbound-a@demo.local');
select 'inbound-a' as who, pg_temp.error_text(format('select wms.wms_export_audit_log(%L)', :'tenant_a')) as export_rpc;
select pg_temp.act('quality-a@demo.local');
select 'quality-a' as who, pg_temp.error_text(format('select wms.wms_export_audit_log(%L)', :'tenant_a')) as export_rpc;
select pg_temp.act('buyer-a@demo.local');
select 'buyer-a' as who, pg_temp.error_text(format('select wms.wms_export_audit_log(%L)', :'tenant_a')) as export_rpc;
select pg_temp.act('process-agent-a@demo.local');
select 'process-agent-a' as who, pg_temp.error_text(format('select wms.wms_export_audit_log(%L)', :'tenant_a')) as export_rpc;

\echo '-- F3. 교차 테넌트 — 테넌트 A의 감사자가 테넌트 B를 조회하면 FORBIDDEN'
select pg_temp.act('auditor-a@demo.local');
select pg_temp.error_text(format('select wms.wms_query_audit_log(%L)', :'tenant_b')) as auditor_a_reading_tenant_b;
\echo '--     테넌트 B의 관리자는 테넌트 B를 읽을 수 있고, 테넌트 A는 못 읽는다'
select pg_temp.act('admin-b@demo.local');
select (wms.wms_query_audit_log(:'tenant_b'))->>'result' as admin_b_own_tenant;
select pg_temp.error_text(format('select wms.wms_query_audit_log(%L)', :'tenant_a')) as admin_b_reading_tenant_a;

\echo '-- F4. tenant_id 누락은 INVALID'
select pg_temp.act('auditor-a@demo.local');
select pg_temp.error_text('select wms.wms_query_audit_log(null)') as null_tenant;

\echo
\echo '============================================================'
\echo 'G. 기존 RLS는 좁혀지지 않았다 (D2, tasks.md 2.5)'
\echo '   — F1에서 거절당한 바로 그 사용자가 원본 테이블은 그대로 읽는다'
\echo '============================================================'

-- `set local role` needs an explicit transaction in psql, otherwise the reset
-- at statement end throws the role away before the SELECT runs.
begin;
  select pg_temp.act('inbound-a@demo.local');
  set local role authenticated;
  select count(*) > 0 as inbound_operator_can_still_select_raw_table
  from wms.audit_events where tenant_id = :'tenant_a';
  \echo '--     ...그리고 다른 테넌트의 행은 RLS가 여전히 막는다'
  select count(*)::int as rows_visible_from_tenant_b
  from wms.audit_events where tenant_id = :'tenant_b';
commit;

\echo
\echo '============================================================'
\echo 'H. 내보내기 (D4 / D5) — 자기 감사와 안전 상한'
\echo '============================================================'

select pg_temp.act('auditor-a@demo.local');

\echo '-- H1. 필터 조건에 맞는 전체 집합이 페이지네이션 없이 반환된다'
select (e->>'row_count') as row_count, (e->>'total_count') as total_count, (e->>'max_rows') as max_rows
from (select wms.wms_export_audit_log(:'tenant_a', p_correlation_id => 'AUDIT-V-PAGE') e) s;

\echo '-- H2. 내보내기 결과에는 자기 자신이 들어 있지 않다'
\echo '--     (자기 감사 행은 결과 집합을 확정한 뒤에 INSERT되므로, 그 행의 id는'
\echo '--      방금 돌려받은 rows 안에 없다. 다음 번 내보내기에서는 보인다 — H3)'
select
  (e->>'self_audit_event_id') is not null as wrote_a_self_audit_row,
  (select count(*)::int from jsonb_array_elements(e->'rows') r
     where r->>'event_id' = e->>'self_audit_event_id') as rows_containing_itself
from (select wms.wms_export_audit_log(:'tenant_a', p_correlation_id => 'AUDIT-V-PAGE') e) s;

\echo '-- H3. 그러나 직후 재조회하면 자기 감사 이벤트가 보인다 (spec.md 시나리오)'
select r->>'command' as command,
       r->>'actor_email' as exported_by,
       r->'after'->>'correlation_id' as filter_correlation_id,
       r->'after'->>'exported_row_count' as filter_row_count,
       r->>'summary_ko' as summary_ko
from jsonb_array_elements(
  (wms.wms_query_audit_log(:'tenant_a', p_command => 'wms_export_audit_log', p_limit => 3))->'rows') r;

\echo '-- H4. 자기 감사 행의 actor는 auth.uid()이지, actor 필터가 아니다 (V4)'
select (wms.wms_export_audit_log(
          :'tenant_a', p_correlation_id => 'AUDIT-V-PAGE',
          p_actor_id => pg_temp.uid('buyer-a@demo.local')))->>'exported_by' = pg_temp.uid('auditor-a@demo.local')::text
  as self_audit_actor_is_the_caller;

\echo '-- H5. 안전 상한 초과는 INVALID이고 아무 것도 내보내지 않는다 (D5 / V5)'
select pg_temp.error_text(format(
  'select wms.wms_export_audit_log(%L, p_correlation_id => ''AUDIT-V-PAGE'', p_max_rows => 3)',
  :'tenant_a')) as over_the_cap;
\echo '--     거절된 호출은 자기 감사 행도 남기지 않는다'
select pg_temp.put('exports_before',
  (select count(*)::text from wms.audit_events where command = 'wms_export_audit_log'));
select pg_temp.error_text(format(
  'select wms.wms_export_audit_log(%L, p_correlation_id => ''AUDIT-V-PAGE'', p_max_rows => 3)',
  :'tenant_a')) as rejected_again;
select pg_temp.get('exports_before')::int as before_count,
       (select count(*)::int from wms.audit_events where command = 'wms_export_audit_log') as after_count;

\echo '-- H6. 상한은 낮출 수만 있고 올릴 수는 없다 (하드 실링 10000)'
select pg_temp.error_text(format('select wms.wms_export_audit_log(%L, p_max_rows => 20000)', :'tenant_a')) as raise_the_cap,
       pg_temp.error_text(format('select wms.wms_export_audit_log(%L, p_max_rows => 0)', :'tenant_a')) as zero_cap,
       (wms.wms_export_audit_log(:'tenant_a', p_correlation_id => 'AUDIT-V-PAGE', p_max_rows => 10000))->>'row_count' as at_the_cap;

\echo
\echo '============================================================'
\echo 'I. 판단 근거 조인 (D3 / 2단계) — wms.agent_decisions'
\echo '============================================================'

\echo '-- I1. 에이전트가 같은 correlation_id로 조치와 근거를 남긴다'
select pg_temp.act('process-agent-a@demo.local');
select wms.wms_log_agent_decision(
  :'tenant_a', :'wh_a',
  'AUDIT-V: 대상 구역의 유일한 AGV가 30분 관찰 창에서 장애 1건으로 병목 판정되어 대체 설비로 재배치했다.',
  pg_temp.uid('process-agent-a@demo.local'), gen_random_uuid(),
  'DISPATCH_RETRY', null, null, null, 'AUDIT-V-CORR-AGENT') ->> 'status' as logged;

-- the "action" the agent took, stamped with the same correlation id
insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, after, correlation_id)
values (:'tenant_a', pg_temp.uid('process-agent-a@demo.local'),
        'wms_dispatch_equipment_command', 'equipment_command', gen_random_uuid(),
        jsonb_build_object('command_type','MOVE','status','DISPATCHED'), 'AUDIT-V-CORR-AGENT');

\echo '-- I2. 조회 결과에 근거 원문과, 그것이 반영된 요약이 함께 나온다'
select pg_temp.act('auditor-a@demo.local');
select r->>'command' as command,
       r->>'has_agent_reasoning' as has_reasoning,
       r->>'agent_decision_status' as decision_status,
       r->>'summary_ko' as summary_ko
from jsonb_array_elements(
  (wms.wms_query_audit_log(:'tenant_a', p_correlation_id => 'AUDIT-V-CORR-AGENT'))->'rows') r
order by 1;

\echo '-- I3. 같은 correlation_id에 판단 기록이 둘이어도 감사 이벤트는 한 번만 나온다 (V3)'
select pg_temp.act('process-agent-a@demo.local');
select wms.wms_log_agent_decision(
  :'tenant_a', :'wh_a',
  'AUDIT-V: 두 번째 기록 — 같은 상관관계 ID 아래 두 건이 쌓였다. 조인이 행을 불리면 안 된다.',
  pg_temp.uid('process-agent-a@demo.local'), gen_random_uuid(),
  'DISPATCH_RETRY', null, null, null, 'AUDIT-V-CORR-AGENT') ->> 'status' as second_logged;
select pg_temp.act('auditor-a@demo.local');
select (q->>'total_count') as total_count,
       (select count(*)::int from jsonb_array_elements(q->'rows') r
         where r->>'command' = 'wms_dispatch_equipment_command') as dispatch_rows
from (select wms.wms_query_audit_log(:'tenant_a', p_correlation_id => 'AUDIT-V-CORR-AGENT') q) s;

\echo '-- I4. 근거가 없는 사람 명령은 근거 문구 없이 정상 요약된다 (느슨한 결합)'
select r->>'command' as command,
       r->>'has_agent_reasoning' as has_reasoning,
       r->>'summary_ko' as summary_ko
from jsonb_array_elements(
  (wms.wms_query_audit_log(:'tenant_a', p_entity_id => pg_temp.get('po')::uuid))->'rows') r;

\echo '-- I5. correlation_id는 자유 텍스트다 — 다른 테넌트의 같은 값과 섞이지 않는다'
insert into wms.audit_events (tenant_id, actor_id, command, entity_type, correlation_id)
values (:'tenant_b', null, 'wms_receive', 'receipt', 'AUDIT-V-CORR-AGENT');
select pg_temp.act('auditor-a@demo.local');
select (wms.wms_query_audit_log(:'tenant_a', p_correlation_id => 'AUDIT-V-CORR-AGENT'))->>'total_count'
  as tenant_a_only;

\echo
\echo '============================================================'
\echo 'J. 정리'
\echo '============================================================'

delete from wms.audit_events where correlation_id like 'AUDIT-V-%';
delete from wms.audit_events where command = 'wms_export_audit_log'
  and after->>'correlation_id' like 'AUDIT-V-%';
delete from wms.agent_decisions where reasoning like 'AUDIT-V%';
delete from wms.audit_events where entity_id in
  (select id from wms.purchase_orders where correlation_id like 'AUDIT-V-%');
delete from wms.receipts where po_id in
  (select id from wms.purchase_orders where correlation_id like 'AUDIT-V-%');
delete from wms.stock_ledger_entries where source_id in
  (select id from wms.purchase_orders where correlation_id like 'AUDIT-V-%');
delete from wms.purchase_orders where correlation_id like 'AUDIT-V-%';
delete from wms.idempotency_records where created_at > now() - interval '10 minutes';

select
  (select count(*)::int from wms.audit_events where correlation_id like 'AUDIT-V-%') as leftover_events,
  (select count(*)::int from wms.agent_decisions where reasoning like 'AUDIT-V%')    as leftover_decisions,
  (select count(*)::int from wms.purchase_orders where correlation_id like 'AUDIT-V-%') as leftover_pos;

\echo
\echo '=== verify.sql 완료 ==='
