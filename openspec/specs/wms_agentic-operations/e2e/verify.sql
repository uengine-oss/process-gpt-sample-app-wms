\set QUIET on
\pset pager off
\pset format aligned
\set ON_ERROR_STOP on

-- ============================================================
-- wms_agentic-operations — psql verification suite
--
--   docker exec -i supabase_db_process-gpt-sample-app-wms \
--     psql -U postgres -d postgres -f - < verify.sql
--
-- Self-contained: creates its own AGENT-V-* fixtures, exercises all eight
-- RPCs and every scenario in specs/wms_agentic-operations/spec.md, then cleans
-- up. Safe to re-run without a db reset.
--
-- The two things this suite exists to prove, above all the envelope checks:
--
--   1. THE ACTION BOUNDARY IS REAL AND IT IS IN THE DATABASE. PROCESS_AGENT
--      can log and propose; it gets FORBIDDEN on confirm and reject, and the
--      refusal comes before any state check so it cannot be probed for
--      information (§D2, §E3). Section J re-runs the four "already human-only"
--      RPCs from earlier areas to show this contract widened nothing.
--   2. NOTHING EXECUTES. Confirming a proposal writes one row in one table.
--      Section D4 snapshots every other WMS table around the call.
--
-- Sections H and I run the two signal RPCs against the REAL areas 8 / 2+4
-- schema (wms.labor_activities, wms.work_orders,
-- wms.wcs_equipment_bottleneck_status) with purpose-built imbalanced and
-- stalled fixtures — design.md wrote them against those areas' design docs
-- before they existed, and the migration's V1/V3/V4 notes record where the
-- shipped schema differed.
-- ============================================================

\set tenant_a '10000000-0000-0000-0000-00000000000a'
\set wh_a     '20000000-0000-0000-0000-00000000000a'
\set tenant_b '10000000-0000-0000-0000-00000000000b'
\set wh_b     '20000000-0000-0000-0000-00000000000b'

-- Both are SECURITY DEFINER because section K drops the session role to
-- `authenticated`, which has no privilege on auth.users.
create or replace function pg_temp.act(p_email text) returns void
language plpgsql security definer as $fn$
declare v_id uuid;
begin
  select id into v_id from auth.users where email = p_email;
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
  return sqlerrm;
end
$fn$;

-- Every psql statement is its own transaction, so a decision written and read
-- in two statements is not a snapshot problem — but a decision written and
-- read in the SAME statement is (this bit us in three earlier areas). Anything
-- that needs the id of a row it just created stores it here first.
create table if not exists pg_temp.v (k text primary key, val text);
create or replace function pg_temp.put(p_k text, p_v text) returns text
language sql as $fn$
  insert into pg_temp.v values (p_k, p_v)
  on conflict (k) do update set val = excluded.val
  returning val;
$fn$;
create or replace function pg_temp.get(p_k text) returns text
language sql stable as $fn$ select val from pg_temp.v where k = p_k $fn$;

-- ------------------------------------------------------------
-- Fixture reset
-- ------------------------------------------------------------
delete from wms.audit_events where entity_type = 'agent_decision';
delete from wms.agent_decisions where reasoning like 'AGENT-V-%' or proposal_type like 'AGENT-V-%';
delete from wms.idempotency_records where command_name in (
  'wms_log_agent_decision', 'wms_propose_agent_action',
  'wms_confirm_agent_proposal', 'wms_reject_agent_proposal');

\set QUIET off
\echo ''
\echo '============================================================'
\echo 'A. Schema shape'
\echo '============================================================'

select
  count(*) filter (where column_name = 'reasoning')        as has_reasoning,
  count(*) filter (where column_name = 'proposed_action')  as has_proposed_action,
  count(*) filter (where column_name = 'signals_snapshot') as has_signals_snapshot,
  count(*) filter (where column_name = 'correlation_id')   as has_correlation_id,
  count(*) filter (where column_name = 'version')          as has_version
from information_schema.columns
where table_schema = 'wms' and table_name = 'agent_decisions';

-- D5: the operations-audit-log contract joins on these three. If any of them
-- ever disappears, that contract's natural-language summary loses the agent's
-- reasoning silently — so the join is asserted here, in this contract's suite.
select
  (select count(*) from information_schema.columns
    where table_schema='wms' and table_name='agent_decisions'
      and column_name in ('status','reasoning','correlation_id')) as join_columns_present,
  (select count(*) from information_schema.columns
    where table_schema='wms' and table_name='audit_events'
      and column_name = 'correlation_id')                          as audit_side_present;

-- The status state machine is a CHECK; proposal_type is deliberately open
-- (migration V7).
select conname, pg_get_constraintdef(oid) as def
from pg_constraint
where conrelid = 'wms.agent_decisions'::regclass and contype = 'c'
order by conname;

\echo ''
\echo '============================================================'
\echo 'B. wms_log_agent_decision  (spec: 자율 실행 판단 근거 기록)'
\echo '============================================================'

select pg_temp.act('process-agent-a@demo.local');

-- B1. The happy path. This models the Wave Coordinator mapping: the agent has
--     ALREADY called an RPC it was allowed to call, and files why.
select pg_temp.put('log1', (wms.wms_log_agent_decision(
  :'tenant_a', :'wh_a',
  'AGENT-V-1: 업무 오더가 32분간 QUEUED 상태이고 대상 구역의 AGV 후보가 모두 병목으로 판정되어, 이미 허용된 wms_retry_work_order_dispatch를 호출했다.',
  pg_temp.uid('process-agent-a@demo.local'),
  gen_random_uuid(),
  'DISPATCH_RETRY',
  'work_order', gen_random_uuid(),
  jsonb_build_object('delayed_work_order_count', 1, 'delay_minutes', 32),
  'AGENT-V-CORR-1'
))->>'document_id') as logged_id;

select
  status, proposal_type, version,
  proposed_action is null                as action_is_null,
  correlation_id,
  left(reasoning, 24)                    as reasoning_head
from wms.agent_decisions where id = pg_temp.get('log1')::uuid;

-- B2. Blank reasoning is the one thing this table exists to prevent.
select
  pg_temp.expect_error($$select wms.wms_log_agent_decision(
    '10000000-0000-0000-0000-00000000000a','20000000-0000-0000-0000-00000000000a',
    '   ', pg_temp.uid('process-agent-a@demo.local'), gen_random_uuid())$$) as blank_reasoning,
  pg_temp.expect_error($$select wms.wms_log_agent_decision(
    '10000000-0000-0000-0000-00000000000a','20000000-0000-0000-0000-00000000000a',
    null, pg_temp.uid('process-agent-a@demo.local'), gen_random_uuid())$$) as null_reasoning;

-- B3. A role that is neither PROCESS_AGENT nor WMS_ADMIN.
select pg_temp.act('buyer-a@demo.local');
select pg_temp.error_text($$select wms.wms_log_agent_decision(
  '10000000-0000-0000-0000-00000000000a','20000000-0000-0000-0000-00000000000a',
  'AGENT-V-buyer가 기록을 시도한다', pg_temp.uid('buyer-a@demo.local'), gen_random_uuid())$$)
  as buyer_logs;

-- B4. WMS_ADMIN may also log (design.md role table).
select pg_temp.act('admin-a@demo.local');
select (wms.wms_log_agent_decision(
  :'tenant_a', :'wh_a', 'AGENT-V-2: 관리자가 대리로 남기는 판단 근거',
  pg_temp.uid('admin-a@demo.local'), gen_random_uuid(),
  'DISPATCH_RETRY'))->>'status' as admin_log_status;

-- B5. A LOGGED record is append-only: it can never be confirmed or rejected.
select pg_temp.act('wh-manager-a@demo.local');
select pg_temp.error_text(format($$select wms.wms_confirm_agent_proposal(
  %L::uuid, pg_temp.uid('wh-manager-a@demo.local'), gen_random_uuid(), 1)$$,
  pg_temp.get('log1'))) as confirm_a_logged_record;

\echo ''
\echo '============================================================'
\echo 'C. wms_propose_agent_action  (spec: 사람 승인이 필요한 제안 생성)'
\echo '============================================================'

select pg_temp.act('process-agent-a@demo.local');

-- C1. The Labor Agent mapping: there is no rebalance RPC anywhere in this
--     repository, so a proposal is the ONLY thing this agent can produce.
select pg_temp.put('prop1', (wms.wms_propose_agent_action(
  :'tenant_a', :'wh_a',
  'LABOR_REBALANCE',
  'AGENT-V-3: 관찰 기간 동안 inbound-a가 12건, quality-a가 2건을 완료해 평균(7건) 대비 편차가 각각 +71%, -71%다. 오후 적치 작업 일부를 quality-a에게 넘길 것을 제안한다.',
  jsonb_build_object(
    'suggested_rpc', null,
    'action', 'MOVE_PUTAWAY_WORKLOAD',
    'from_actor_email', 'inbound-a@demo.local',
    'to_actor_email', 'quality-a@demo.local',
    'note', '실행 RPC가 존재하지 않으므로 사람이 수동으로 조치해야 한다'),
  pg_temp.uid('process-agent-a@demo.local'), gen_random_uuid(),
  'actor', pg_temp.uid('inbound-a@demo.local'),
  jsonb_build_object('imbalance_threshold', 0.40, 'imbalanced_count', 2),
  'AGENT-V-CORR-3'
))->>'document_id') as proposal_id;

select status, proposal_type, version,
       proposed_action->>'action' as action,
       target_entity_type
from wms.agent_decisions where id = pg_temp.get('prop1')::uuid;

-- the envelope warns, on every single proposal, that confirming executes nothing
select (wms.wms_get_agent_decisions(:'tenant_a', :'wh_a', 'PROPOSED'))->'rows'->0->>'awaiting_review'
  as awaiting_review;

-- C2. A proposal with no action is not reviewable. null / JSON null / {} / []
--     all count as "empty" (migration).
select
  pg_temp.expect_error($$select wms.wms_propose_agent_action(
    '10000000-0000-0000-0000-00000000000a','20000000-0000-0000-0000-00000000000a',
    'LABOR_REBALANCE','AGENT-V-근거는 있다', null,
    pg_temp.uid('process-agent-a@demo.local'), gen_random_uuid())$$)      as null_action,
  pg_temp.expect_error($$select wms.wms_propose_agent_action(
    '10000000-0000-0000-0000-00000000000a','20000000-0000-0000-0000-00000000000a',
    'LABOR_REBALANCE','AGENT-V-근거는 있다', '{}'::jsonb,
    pg_temp.uid('process-agent-a@demo.local'), gen_random_uuid())$$)      as empty_object,
  pg_temp.expect_error($$select wms.wms_propose_agent_action(
    '10000000-0000-0000-0000-00000000000a','20000000-0000-0000-0000-00000000000a',
    'LABOR_REBALANCE','', '{"a":1}'::jsonb,
    pg_temp.uid('process-agent-a@demo.local'), gen_random_uuid())$$)      as blank_reasoning;

-- C3. Idempotency: the same key twice creates one row, not two.
select pg_temp.put('idem', gen_random_uuid()::text);
select (wms.wms_propose_agent_action(
  :'tenant_a', :'wh_a', 'EQUIPMENT_ROUTING_SUGGESTION',
  'AGENT-V-4: AGV-01이 30분 내 장애 1건으로 병목 판정되었다. 라우팅에서 임시 제외를 제안한다.',
  jsonb_build_object('suggested_rpc', 'wms_exclude_equipment_from_routing',
                     'equipment_code', 'AGENT-V-AGV-01'),
  pg_temp.uid('process-agent-a@demo.local'), pg_temp.get('idem')::uuid))->>'document_id'
  as first_call;
select (wms.wms_propose_agent_action(
  :'tenant_a', :'wh_a', 'EQUIPMENT_ROUTING_SUGGESTION',
  'AGENT-V-4: AGV-01이 30분 내 장애 1건으로 병목 판정되었다. 라우팅에서 임시 제외를 제안한다.',
  jsonb_build_object('suggested_rpc', 'wms_exclude_equipment_from_routing',
                     'equipment_code', 'AGENT-V-AGV-01'),
  pg_temp.uid('process-agent-a@demo.local'), pg_temp.get('idem')::uuid))->>'document_id'
  as retry_same_key;
select count(*) as rows_created
from wms.agent_decisions where reasoning like 'AGENT-V-4:%';

-- C4. A non-agent, non-admin role cannot propose either.
select pg_temp.act('inbound-a@demo.local');
select pg_temp.error_text($$select wms.wms_propose_agent_action(
  '10000000-0000-0000-0000-00000000000a','20000000-0000-0000-0000-00000000000a',
  'LABOR_REBALANCE','AGENT-V-작업자가 제안을 만든다','{"a":1}'::jsonb,
  pg_temp.uid('inbound-a@demo.local'), gen_random_uuid())$$) as operator_proposes;

\echo ''
\echo '============================================================'
\echo 'D. wms_confirm_agent_proposal  (spec: 에이전트 제안 승인)'
\echo '============================================================'

-- D1. Snapshot every other WMS table before the confirmation, so D4 can prove
--     the confirmation touched none of them (spec: 제안 생성이 다른 도메인
--     테이블을 변경하지 않는다 / D7 자동 실행 없음).
select pg_temp.put('snap_before', (
  select string_agg(t || '=' || n, ' ' order by t) from (
    select 'receipts' as t, count(*)::text as n from wms.receipts
    union all select 'purchase_orders', count(*)::text from wms.purchase_orders
    union all select 'stock_ledger', count(*)::text from wms.stock_ledger_entries
    union all select 'work_orders', count(*)::text from wms.work_orders
    union all select 'labor_activities', count(*)::text from wms.labor_activities
    union all select 'equipment', count(*)::text from wms.equipment
    union all select 'routing_overrides', count(*)::text from wms.wcs_routing_overrides
    union all select 'wo_versions', coalesce(sum(version),0)::text from wms.work_orders
    union all select 'la_versions', coalesce(sum(version),0)::text from wms.labor_activities
  ) x)) as snapshot_taken;

-- D2. PROCESS_AGENT is refused, and refused FIRST — before the version and
--     before the status are looked at. An agent probing with a wrong version
--     must not be able to tell a real proposal from a fake id.
select pg_temp.act('process-agent-a@demo.local');
select
  pg_temp.error_text(format($$select wms.wms_confirm_agent_proposal(
    %L::uuid, pg_temp.uid('process-agent-a@demo.local'), gen_random_uuid(), 1)$$,
    pg_temp.get('prop1')))                        as agent_confirms,
  pg_temp.expect_error(format($$select wms.wms_confirm_agent_proposal(
    %L::uuid, pg_temp.uid('process-agent-a@demo.local'), gen_random_uuid(), 99)$$,
    pg_temp.get('prop1')))                        as agent_confirms_wrong_version;

-- D3. A version mismatch by a human who IS allowed to confirm.
select pg_temp.act('wh-manager-a@demo.local');
select pg_temp.error_text(format($$select wms.wms_confirm_agent_proposal(
  %L::uuid, pg_temp.uid('wh-manager-a@demo.local'), gen_random_uuid(), 7)$$,
  pg_temp.get('prop1'))) as wrong_version;
select status, version from wms.agent_decisions where id = pg_temp.get('prop1')::uuid;

-- D4. The manager confirms.
select jsonb_pretty(wms.wms_confirm_agent_proposal(
  pg_temp.get('prop1')::uuid, pg_temp.uid('wh-manager-a@demo.local'),
  gen_random_uuid(), 1, 'AGENT-V-CORR-3')) as confirm_envelope;

select status, version,
       confirmed_by = pg_temp.uid('wh-manager-a@demo.local') as confirmed_by_manager,
       confirmed_at is not null                              as has_timestamp,
       rejected_by is null                                   as no_rejecter,
       proposed_action->>'action'                            as action_kept
from wms.agent_decisions where id = pg_temp.get('prop1')::uuid;

-- ...and nothing else in the database moved. D7 in one query.
select
  pg_temp.get('snap_before') = (
    select string_agg(t || '=' || n, ' ' order by t) from (
      select 'receipts' as t, count(*)::text as n from wms.receipts
      union all select 'purchase_orders', count(*)::text from wms.purchase_orders
      union all select 'stock_ledger', count(*)::text from wms.stock_ledger_entries
      union all select 'work_orders', count(*)::text from wms.work_orders
      union all select 'labor_activities', count(*)::text from wms.labor_activities
      union all select 'equipment', count(*)::text from wms.equipment
      union all select 'routing_overrides', count(*)::text from wms.wcs_routing_overrides
      union all select 'wo_versions', coalesce(sum(version),0)::text from wms.work_orders
      union all select 'la_versions', coalesce(sum(version),0)::text from wms.labor_activities
    ) x) as no_other_table_moved;

-- D5. Already-handled proposals cannot be confirmed again.
select pg_temp.error_text(format($$select wms.wms_confirm_agent_proposal(
  %L::uuid, pg_temp.uid('wh-manager-a@demo.local'), gen_random_uuid(), 2)$$,
  pg_temp.get('prop1'))) as double_confirm;

\echo ''
\echo '============================================================'
\echo 'E. wms_reject_agent_proposal  (spec: 에이전트 제안 거부)'
\echo '============================================================'

select pg_temp.act('process-agent-a@demo.local');
select pg_temp.put('prop2', (wms.wms_propose_agent_action(
  :'tenant_a', :'wh_a', 'EQUIPMENT_ROUTING_SUGGESTION',
  'AGENT-V-5: SRM-01의 대기열 깊이가 임계값 3을 넘어섰다. 라우팅에서 임시 제외를 제안한다.',
  jsonb_build_object('suggested_rpc', 'wms_exclude_equipment_from_routing',
                     'equipment_code', 'AGENT-V-SRM-01', 'reason', 'queue depth 5'),
  pg_temp.uid('process-agent-a@demo.local'), gen_random_uuid()
))->>'document_id') as proposal2_id;

-- E1. A rejection with no reason is itself rejected.
select pg_temp.act('wh-manager-a@demo.local');
select
  pg_temp.expect_error(format($$select wms.wms_reject_agent_proposal(
    %L::uuid, '', pg_temp.uid('wh-manager-a@demo.local'), gen_random_uuid(), 1)$$,
    pg_temp.get('prop2')))  as blank_reason,
  pg_temp.expect_error(format($$select wms.wms_reject_agent_proposal(
    %L::uuid, null, pg_temp.uid('wh-manager-a@demo.local'), gen_random_uuid(), 1)$$,
    pg_temp.get('prop2')))  as null_reason;

-- E2. Rejected with a note.
select (wms.wms_reject_agent_proposal(
  pg_temp.get('prop2')::uuid,
  'AGENT-V-반려: 해당 SRM은 야간 배치 작업 중이라 대기열이 깊은 것이 정상이다. 제외하면 야간 작업이 멈춘다.',
  pg_temp.uid('wh-manager-a@demo.local'), gen_random_uuid(), 1))->>'status' as reject_status;

select status, version,
       rejected_by = pg_temp.uid('wh-manager-a@demo.local') as rejected_by_manager,
       rejected_at is not null                              as has_timestamp,
       confirmed_by is null                                 as no_confirmer,
       left(rejection_reason, 20)                           as reason_head
from wms.agent_decisions where id = pg_temp.get('prop2')::uuid;

-- E3. PROCESS_AGENT cannot reject either.
select pg_temp.act('process-agent-a@demo.local');
select pg_temp.put('prop3', (wms.wms_propose_agent_action(
  :'tenant_a', :'wh_a', 'LABOR_REBALANCE',
  'AGENT-V-6: 세 번째 제안 — 에이전트의 거부 시도 대상',
  jsonb_build_object('action','NOOP'),
  pg_temp.uid('process-agent-a@demo.local'), gen_random_uuid()))->>'document_id') as proposal3_id;
select pg_temp.error_text(format($$select wms.wms_reject_agent_proposal(
  %L::uuid, '에이전트가 스스로 반려', pg_temp.uid('process-agent-a@demo.local'),
  gen_random_uuid(), 1)$$, pg_temp.get('prop3'))) as agent_rejects;

-- E4. Neither can a warehouse worker with no review authority.
select pg_temp.act('inbound-a@demo.local');
select pg_temp.error_text(format($$select wms.wms_reject_agent_proposal(
  %L::uuid, '작업자가 반려', pg_temp.uid('inbound-a@demo.local'),
  gen_random_uuid(), 1)$$, pg_temp.get('prop3'))) as operator_rejects;

-- ...and the proposal is untouched by either attempt.
select status, version from wms.agent_decisions where id = pg_temp.get('prop3')::uuid;

\echo ''
\echo '============================================================'
\echo 'F. wms_get_agent_decisions  (spec: 에이전트 판단·제안 이력 조회)'
\echo '============================================================'

select pg_temp.act('wh-manager-a@demo.local');

-- F1. Status filter. Two LOGGED (B1, B4), one CONFIRMED, one REJECTED,
--     two still PROPOSED (C3's idempotent pair counts once, plus E3).
select
  (wms.wms_get_agent_decisions(:'tenant_a', :'wh_a'))->'status_counts' as status_counts,
  (wms.wms_get_agent_decisions(:'tenant_a', :'wh_a'))->>'pending_review_count' as pending;

select
  (wms.wms_get_agent_decisions(:'tenant_a', :'wh_a', 'LOGGED'))->>'row_count'    as logged,
  (wms.wms_get_agent_decisions(:'tenant_a', :'wh_a', 'PROPOSED'))->>'row_count'  as proposed,
  (wms.wms_get_agent_decisions(:'tenant_a', :'wh_a', 'CONFIRMED'))->>'row_count' as confirmed,
  (wms.wms_get_agent_decisions(:'tenant_a', :'wh_a', 'REJECTED'))->>'row_count'  as rejected;

-- F2. proposal_type filter.
select
  (wms.wms_get_agent_decisions(:'tenant_a', :'wh_a', null, 'LABOR_REBALANCE'))->>'row_count'
    as labor_rebalance,
  (wms.wms_get_agent_decisions(:'tenant_a', :'wh_a', null, 'EQUIPMENT_ROUTING_SUGGESTION'))->>'row_count'
    as routing_suggestion,
  (wms.wms_get_agent_decisions(:'tenant_a', :'wh_a', null, 'DISPATCH_RETRY'))->>'row_count'
    as dispatch_retry;

-- F3. Both filters together, and an unknown status is INVALID rather than
--     silently matching nothing.
select
  (wms.wms_get_agent_decisions(:'tenant_a', :'wh_a', 'CONFIRMED', 'LABOR_REBALANCE'))->>'row_count'
    as confirmed_labor,
  pg_temp.expect_error($$select wms.wms_get_agent_decisions(
    '10000000-0000-0000-0000-00000000000a','20000000-0000-0000-0000-00000000000a','NOPE')$$)
    as bad_status;

-- F4. The reasoning is what a reviewer reads — it comes back whole, with the
--     signal snapshot and the reviewer's identity resolved to an email.
select jsonb_pretty(
  (wms.wms_get_agent_decisions(:'tenant_a', :'wh_a', 'CONFIRMED'))->'rows'->0) as confirmed_row;

\echo ''
\echo '============================================================'
\echo 'G. wms_get_worker_next_actions  (spec: 작업자 다음 행동 안내 조회)'
\echo '============================================================'

-- Drive a real receipt through the real core-schema RPCs, so involvement is
-- recorded the way production records it (migration V5: wms.receipts has no
-- actor column, so involvement is derived).
select pg_temp.act('buyer-a@demo.local');
select pg_temp.put('po', (wms.wms_create_rfq(
  :'tenant_a', :'wh_a', 'SKU-A-003', 24,
  (select id from wms.suppliers where tenant_id = :'tenant_a' limit 1),
  pg_temp.uid('buyer-a@demo.local'), gen_random_uuid(), 'AGENT-V-CORR-G'))->>'po_id') as po_id;

select pg_temp.act('approver-a@demo.local');
select (wms.wms_submit_purchase_approval(
  pg_temp.get('po')::uuid, 'APPROVE', pg_temp.uid('approver-a@demo.local'), 1))->>'status'
  as po_approved;

select pg_temp.act('buyer-a@demo.local');
select pg_temp.put('receipt', (wms.wms_confirm_purchase_order(
  pg_temp.get('po')::uuid, pg_temp.uid('buyer-a@demo.local'), gen_random_uuid(), 2))->>'receipt_id')
  as receipt_id;

-- G1. Nobody has touched the receipt yet, so nobody has it on their list —
--     the receipt exists but involvement does not.
select pg_temp.act('inbound-a@demo.local');
select
  (wms.wms_get_worker_next_actions(:'tenant_a', :'wh_a',
     pg_temp.uid('inbound-a@demo.local')))->>'row_count'  as before_touching,
  (wms.wms_get_worker_next_actions(:'tenant_a', :'wh_a',
     pg_temp.uid('inbound-a@demo.local')))->'notes'       as notes;

-- G2. The operator registers the arrival. Now it is theirs, and the guidance
--     names the transition the core schema will actually accept next.
select (wms.wms_register_arrival(
  pg_temp.get('po')::uuid, pg_temp.uid('inbound-a@demo.local'), gen_random_uuid()))->>'status'
  as arrival;

select jsonb_pretty((wms.wms_get_worker_next_actions(
  :'tenant_a', :'wh_a', pg_temp.uid('inbound-a@demo.local')))->'rows'->0) as after_arrival;

-- G3. It narrows as the receipt moves. ARRIVED -> receive -> QC_PENDING, which
--     is the state spec.md calls "RECEIVING" (migration V6).
select (wms.wms_receive(
  pg_temp.get('receipt')::uuid, 24, pg_temp.uid('inbound-a@demo.local'),
  gen_random_uuid(), 2))->>'status' as received;

select
  (wms.wms_get_worker_next_actions(:'tenant_a', :'wh_a',
     pg_temp.uid('inbound-a@demo.local')))->'rows'->0->>'status'       as status,
  (wms.wms_get_worker_next_actions(:'tenant_a', :'wh_a',
     pg_temp.uid('inbound-a@demo.local')))->'rows'->0->'next_actions'  as next_actions,
  (wms.wms_get_worker_next_actions(:'tenant_a', :'wh_a',
     pg_temp.uid('inbound-a@demo.local')))->'rows'->0->'involvement_sources' as sources;

-- G4. A different worker's involvement is recorded independently: the quality
--     inspector shows up on the same receipt only once they act on it, and
--     through a different source (wms.quality_inspections, migration V5).
select pg_temp.act('quality-a@demo.local');
select
  (wms.wms_get_worker_next_actions(:'tenant_a', :'wh_a',
     pg_temp.uid('quality-a@demo.local')))->>'row_count' as inspector_before;

select (wms.wms_record_quality_result(
  pg_temp.get('receipt')::uuid, 'PASSED', null,
  pg_temp.uid('quality-a@demo.local'), gen_random_uuid()))->>'status' as qc;

select
  (wms.wms_get_worker_next_actions(:'tenant_a', :'wh_a',
     pg_temp.uid('quality-a@demo.local')))->>'row_count'                    as inspector_after,
  (wms.wms_get_worker_next_actions(:'tenant_a', :'wh_a',
     pg_temp.uid('quality-a@demo.local')))->'rows'->0->'involvement_sources' as sources,
  (wms.wms_get_worker_next_actions(:'tenant_a', :'wh_a',
     pg_temp.uid('quality-a@demo.local')))->'rows'->0->'next_actions'        as next_actions;

-- G5. Terminal items drop off. PUTAWAY_PENDING -> create_putaway_tasks ->
--     PUTAWAY_COMPLETED, and the receipt leaves everyone's list.
select pg_temp.act('inbound-a@demo.local');
select (wms.wms_create_putaway_tasks(
  pg_temp.get('receipt')::uuid, pg_temp.uid('inbound-a@demo.local'), gen_random_uuid()))->>'status'
  as putaway;

select
  (select status from wms.receipts where id = pg_temp.get('receipt')::uuid) as receipt_status,
  (wms.wms_get_worker_next_actions(:'tenant_a', :'wh_a',
     pg_temp.uid('inbound-a@demo.local')))->>'row_count'        as open_items,
  -- ...unless you ask for them (migration V6, p_include_closed)
  (wms.wms_get_worker_next_actions(:'tenant_a', :'wh_a',
     pg_temp.uid('inbound-a@demo.local'), true))->>'row_count'  as including_closed;

-- G6. A worker who has never touched anything gets an empty result, not an
--     error.
select
  (wms.wms_get_worker_next_actions(:'tenant_a', :'wh_a',
     pg_temp.uid('wcs-operator-a@demo.local')))->>'row_count' as untouched_worker,
  (wms.wms_get_worker_next_actions(:'tenant_a', :'wh_a',
     pg_temp.uid('wcs-operator-a@demo.local')))->'notes'      as notes;

-- G7. The failed-QC branch, which the first receipt never reached: a receipt
--     that fails inspection sits in QC_COMPLETED waiting for a disposition.
--     Section J reuses it, because a role guard can only be observed on a row
--     whose state guard would otherwise pass.
select pg_temp.act('buyer-a@demo.local');
select pg_temp.put('po2', (wms.wms_create_rfq(
  :'tenant_a', :'wh_a', 'SKU-A-002', 8,
  (select id from wms.suppliers where tenant_id = :'tenant_a' limit 1),
  pg_temp.uid('buyer-a@demo.local'), gen_random_uuid(), 'AGENT-V-CORR-G2'))->>'po_id') as po2_id;
select pg_temp.act('approver-a@demo.local');
select (wms.wms_submit_purchase_approval(
  pg_temp.get('po2')::uuid, 'APPROVE', pg_temp.uid('approver-a@demo.local'), 1))->>'status' as po2;
select pg_temp.act('buyer-a@demo.local');
select pg_temp.put('receipt2', (wms.wms_confirm_purchase_order(
  pg_temp.get('po2')::uuid, pg_temp.uid('buyer-a@demo.local'), gen_random_uuid(), 2))->>'receipt_id')
  as receipt2_id;
select pg_temp.act('inbound-a@demo.local');
select (wms.wms_register_arrival(
  pg_temp.get('po2')::uuid, pg_temp.uid('inbound-a@demo.local'), gen_random_uuid()))->>'status' as a2;
select (wms.wms_receive(
  pg_temp.get('receipt2')::uuid, 8, pg_temp.uid('inbound-a@demo.local'),
  gen_random_uuid(), 2))->>'status' as r2;
select pg_temp.act('quality-a@demo.local');
select (wms.wms_record_quality_result(
  pg_temp.get('receipt2')::uuid, 'FAILED', 'DAMAGED',
  pg_temp.uid('quality-a@demo.local'), gen_random_uuid()))->>'status' as qc_failed;

select
  (select e->>'status' from jsonb_array_elements(
     (wms.wms_get_worker_next_actions(:'tenant_a', :'wh_a',
        pg_temp.uid('quality-a@demo.local')))->'rows') e
   where e->>'item_id' = pg_temp.get('receipt2'))                 as failed_receipt_status,
  (select e->'next_actions' from jsonb_array_elements(
     (wms.wms_get_worker_next_actions(:'tenant_a', :'wh_a',
        pg_temp.uid('quality-a@demo.local')))->'rows') e
   where e->>'item_id' = pg_temp.get('receipt2'))                 as failed_receipt_next;

\echo ''
\echo '============================================================'
\echo 'H. wms_get_labor_balance_signals  (spec: 인력 작업량 불균형 신호)'
\echo '    Runs against area 8 for real (20260803_labor_management.sql).'
\echo '============================================================'

-- spec.md's worked example: worker A 12, worker B 2, mean 7, deviations
-- +71% / -71%, both over the 40% threshold (migration V2).
-- Seeded as superuser: the RPCs stamp now() and D2 forbids proxy recording,
-- so a script cannot produce a 12-vs-2 window through them.
delete from wms.labor_activities where activity_label like 'AGENT-V-%';
insert into wms.labor_activities (
  tenant_id, warehouse_id, actor_id, actor_role, activity_type, activity_label,
  unit_count, status, started_at, completed_at, created_by, updated_by)
select :'tenant_a', :'wh_a', u.id, s.role, 'RECEIVING', 'AGENT-V-불균형 시드',
       10, 'COMPLETED',
       -- anchored D-2, clear of any browser-local "today" window
       date_trunc('day', now()) - interval '2 days' + make_interval(hours => 8, mins => g * 5),
       date_trunc('day', now()) - interval '2 days' + make_interval(hours => 8, mins => g * 5 + 4),
       u.id, u.id
from (values ('inbound-a@demo.local','INBOUND_OPERATOR',12),
             ('quality-a@demo.local','QUALITY_INSPECTOR',2)) as s(email, role, n)
join auth.users u on u.email = s.email
cross join lateral generate_series(1, s.n) g;

-- The window stops at D-2 10:00 so that supabase/seed.sql's own D-2 rows
-- (inbound-a 13:00, quality-a 11:00) stay out of it and the numbers are
-- exactly spec.md's 12-and-2 worked example rather than 13-and-3.
-- H1. A manager reads the deviation.
select pg_temp.act('wh-manager-a@demo.local');
select jsonb_pretty(jsonb_build_object(
  'mean',      r->'mean_completed_count',
  'threshold', r->'imbalance_threshold',
  'workers',   r->'worker_count',
  'imbalanced', r->'imbalanced_count',
  'rows', (select jsonb_agg(jsonb_build_object(
             'email', e->>'actor_email', 'count', e->>'completed_count',
             'deviation', e->>'deviation_ratio', 'imbalanced', e->>'is_imbalanced',
             'direction', e->>'direction'))
           from jsonb_array_elements(r->'rows') e)))
from (select wms.wms_get_labor_balance_signals(
        :'tenant_a', :'wh_a',
        date_trunc('day', now()) - interval '2 days',
        date_trunc('day', now()) - interval '2 days' + interval '10 hours') as r) t;

-- H2. THE D2 EXCEPTION. The same call as PROCESS_AGENT returns the same two
--     workers — not the one row wms_get_labor_productivity would hand it.
--     Both are shown side by side because the difference IS the decision.
select pg_temp.act('process-agent-a@demo.local');
select
  (wms.wms_get_labor_balance_signals(:'tenant_a', :'wh_a',
     date_trunc('day', now()) - interval '2 days',
     date_trunc('day', now()) - interval '2 days' + interval '10 hours'))->>'scope'
    as balance_scope,
  (wms.wms_get_labor_balance_signals(:'tenant_a', :'wh_a',
     date_trunc('day', now()) - interval '2 days',
     date_trunc('day', now()) - interval '2 days' + interval '10 hours'))->>'worker_count'
    as balance_workers,
  -- area 8's own RPC, same caller, same window: SELF scope, and the agent has
  -- logged no activity of its own, so it sees nothing at all
  (wms.wms_get_labor_productivity(:'tenant_a', :'wh_a',
     date_trunc('day', now()) - interval '2 days',
     date_trunc('day', now()) - interval '2 days' + interval '10 hours'))->>'scope'
    as productivity_scope,
  (wms.wms_get_labor_productivity(:'tenant_a', :'wh_a',
     date_trunc('day', now()) - interval '2 days',
     date_trunc('day', now()) - interval '2 days' + interval '10 hours'))->>'row_count'
    as productivity_rows;

-- H3. The expansion is narrow (D2): it does NOT open the raw activity rows or
--     the leaderboard to the agent.
select
  (wms.wms_get_labor_leaderboard(:'tenant_a', :'wh_a',
     date_trunc('day', now()) - interval '2 days',
     date_trunc('day', now()) - interval '2 days' + interval '10 hours'))->>'scope'
    as leaderboard_scope;

-- H4. An empty window is an empty result, not an error, and says which case
--     it is.
select
  (wms.wms_get_labor_balance_signals(:'tenant_a', :'wh_a',
     now() + interval '1 day', now() + interval '2 days'))->>'row_count' as empty_rows,
  (wms.wms_get_labor_balance_signals(:'tenant_a', :'wh_a',
     now() + interval '1 day', now() + interval '2 days'))->'notes'      as empty_notes;

-- H5. Roles with no business comparing colleagues are refused outright rather
--     than handed a meaningless one-row "comparison".
select pg_temp.act('inbound-a@demo.local');
select pg_temp.error_text($$select wms.wms_get_labor_balance_signals(
  '10000000-0000-0000-0000-00000000000a','20000000-0000-0000-0000-00000000000a')$$)
  as operator_reads_balance;

-- H6. Cross-warehouse.
select pg_temp.act('wh-manager-a@demo.local');
select pg_temp.expect_error($$select wms.wms_get_labor_balance_signals(
  '10000000-0000-0000-0000-00000000000b','20000000-0000-0000-0000-00000000000b')$$)
  as other_tenant_warehouse;

\echo ''
\echo '============================================================'
\echo 'I. wms_get_dispatch_delay_signals  (spec: 디스패치 지연 신호)'
\echo '    Runs against areas 2 + 4 for real'
\echo '    (20260728_wes_material_flow_control.sql, 20260730_wcs_bottleneck_routing.sql).'
\echo '============================================================'

delete from wms.work_orders where correlation_id like 'AGENT-V-%';
delete from wms.equipment_faults where fault_code like 'AGENT-V-%';
delete from wms.equipment where equipment_code like 'AGENT-V-%';

-- I1. A WAVELESS work order created while its zone has no machine at all stays
--     QUEUED with NO_EQUIPMENT_AVAILABLE (area 2's own behaviour, unchanged).
select pg_temp.act('wh-manager-a@demo.local');
select pg_temp.put('wo1', (wms.wms_create_work_order(
  :'tenant_a', :'wh_a', 'PUTAWAY', 'receipt', pg_temp.get('receipt')::uuid,
  'AGV', 'AGENT-V-ZONE', 'MOVE', '{"note":"AGENT-V"}'::jsonb, 'WAVELESS',
  pg_temp.uid('wh-manager-a@demo.local'), gen_random_uuid(), null, 'AGENT-V-WO-1'))->>'document_id')
  as wo1_id;
select status, reason from wms.work_orders where id = pg_temp.get('wo1')::uuid;

-- Backdate so it crosses the 15-minute default. Superuser, because nothing in
-- the contract lets a caller forge a wait.
update wms.work_orders set updated_at = now() - interval '32 minutes'
where id = pg_temp.get('wo1')::uuid;

select jsonb_pretty(jsonb_build_object(
  'threshold', r->'delay_threshold_minutes',
  'queued', r->'queued_work_order_count',
  'delayed', r->'delayed_work_order_count',
  'row', (select jsonb_build_object(
            'zone', e->>'zone_code', 'equipment_type', e->>'equipment_type',
            'delay_minutes', e->>'delay_minutes',
            'candidates', e->>'candidate_equipment_count',
            'causes', e->'delay_causes')
          from jsonb_array_elements(r->'rows') e limit 1)))
from (select wms.wms_get_dispatch_delay_signals(:'tenant_a', :'wh_a') as r) t;

-- I2. Now give the zone one AGV and flag it as a bottleneck the way area 4
--     actually computes it: a fault inside the 30-minute observation window.
--     The machine is IDLE and free, so it IS routable — and every routable
--     candidate is flagged, which is a different cause from "no machine".
select pg_temp.put('agv', (wms.wms_register_equipment(
  :'tenant_a', :'wh_a', 'AGENT-V-AGV-01', 'AGV', 'AGENT-V-ZONE',
  pg_temp.uid('wh-manager-a@demo.local'), gen_random_uuid()))->>'document_id') as agv_id;

update wms.equipment set status = 'IDLE' where id = pg_temp.get('agv')::uuid;
insert into wms.equipment_faults (tenant_id, warehouse_id, equipment_id, fault_code, severity, status)
values (:'tenant_a', :'wh_a', pg_temp.get('agv')::uuid, 'AGENT-V-FAULT', 'WARNING', 'RESOLVED');

-- area 4 agrees it is a bottleneck (sanity check against the shipped view)
select equipment_code, status, queue_depth, recent_fault_count, is_bottleneck, bottleneck_reasons
from wms.wcs_equipment_bottleneck_status where equipment_id = pg_temp.get('agv')::uuid;

select jsonb_pretty(jsonb_build_object(
  'row', (select jsonb_build_object(
            'candidates', e->>'candidate_equipment_count',
            'idle', e->>'idle_candidate_count',
            'routable', e->>'routable_candidate_count',
            'bottlenecked', e->>'bottleneck_candidate_count',
            'causes', e->'delay_causes',
            'flagged', e->'bottleneck_equipment')
          from jsonb_array_elements(r->'rows') e limit 1)))
from (select wms.wms_get_dispatch_delay_signals(:'tenant_a', :'wh_a') as r) t;

-- I3. A force-exclusion (area 4, human-only) removes the only candidate
--     entirely — a different cause again, and the one an agent must NOT try to
--     "fix" by retrying.
select (wms.wms_exclude_equipment_from_routing(
  pg_temp.get('agv')::uuid, 'AGENT-V-정비 예정',
  pg_temp.uid('wh-manager-a@demo.local'), gen_random_uuid()))->>'status' as excluded;

select (select e->'delay_causes' from jsonb_array_elements(r->'rows') e limit 1) as causes_after_exclusion
from (select wms.wms_get_dispatch_delay_signals(:'tenant_a', :'wh_a') as r) t;

-- I4. A fresh work order is not late. Same zone, same everything, not
--     backdated — it must not appear.
select pg_temp.put('wo2', (wms.wms_create_work_order(
  :'tenant_a', :'wh_a', 'PUTAWAY', 'receipt', pg_temp.get('receipt')::uuid,
  'AGV', 'AGENT-V-ZONE', 'MOVE', '{"note":"AGENT-V-fresh"}'::jsonb, 'WAVELESS',
  pg_temp.uid('wh-manager-a@demo.local'), gen_random_uuid(), null, 'AGENT-V-WO-2'))->>'document_id')
  as wo2_id;

select
  r->>'queued_work_order_count'  as queued,
  r->>'delayed_work_order_count' as delayed,
  (select count(*) from jsonb_array_elements(r->'rows') e
    where e->>'work_order_id' = pg_temp.get('wo2')) as fresh_wo_in_result
from (select wms.wms_get_dispatch_delay_signals(:'tenant_a', :'wh_a') as r) t;

-- ...and lowering the threshold to zero brings it in, which proves the filter
-- is the threshold and not something else.
select r->>'delayed_work_order_count' as delayed_at_threshold_0
from (select wms.wms_get_dispatch_delay_signals(:'tenant_a', :'wh_a', null, 0) as r) t;

-- I5. A WAVE work order whose wave is still OPEN is reported with
--     WAVE_NOT_RELEASED — it is not late, it is not due (migration V4).
select pg_temp.put('wave', (wms.wms_open_dispatch_wave(
  :'tenant_a', :'wh_a', pg_temp.uid('wh-manager-a@demo.local'), gen_random_uuid()))->>'document_id')
  as wave_id;
select pg_temp.put('wo3', (wms.wms_create_work_order(
  :'tenant_a', :'wh_a', 'PUTAWAY', 'receipt', pg_temp.get('receipt')::uuid,
  'AGV', 'AGENT-V-ZONE', 'MOVE', '{"note":"AGENT-V-wave"}'::jsonb, 'WAVE',
  pg_temp.uid('wh-manager-a@demo.local'), gen_random_uuid(),
  pg_temp.get('wave')::uuid, 'AGENT-V-WO-3'))->>'document_id') as wo3_id;
update wms.work_orders set updated_at = now() - interval '45 minutes'
where id = pg_temp.get('wo3')::uuid;

select
  (select e->'delay_causes' from jsonb_array_elements(r->'rows') e
    where e->>'work_order_id' = pg_temp.get('wo3')) as wave_causes,
  (select e->>'wave_status' from jsonb_array_elements(r->'rows') e
    where e->>'work_order_id' = pg_temp.get('wo3')) as wave_status
from (select wms.wms_get_dispatch_delay_signals(:'tenant_a', :'wh_a') as r) t;

-- I6. The p_wave_id filter narrows to one wave.
select
  r->>'delayed_work_order_count' as delayed_in_wave
from (select wms.wms_get_dispatch_delay_signals(
        :'tenant_a', :'wh_a', pg_temp.get('wave')::uuid) as r) t;

-- I7. PROCESS_AGENT reads the same signal (all four reads are open to it).
select pg_temp.act('process-agent-a@demo.local');
select (wms.wms_get_dispatch_delay_signals(:'tenant_a', :'wh_a'))->>'result' as agent_reads;

\echo ''
\echo '============================================================'
\echo 'J. The boundary this contract did NOT widen'
\echo '    (spec: 이 계약은 PROCESS_AGENT의 기존 금지 목록을 넓히지 않는다)'
\echo '============================================================'

-- One OPEN fault so the fault-resolution guard is observable on a row whose
-- state guard would otherwise pass (the same reason G7 exists).
select pg_temp.act('wcs-operator-a@demo.local');
select pg_temp.put('fault', (wms.wms_raise_equipment_fault(
  pg_temp.get('agv')::uuid, 'AGENT-V-FAULT-OPEN', 'WARNING',
  pg_temp.uid('wcs-operator-a@demo.local'), gen_random_uuid()))->>'document_id') as open_fault;

select pg_temp.act('process-agent-a@demo.local');
select
  pg_temp.error_text(format($$select wms.wms_submit_purchase_approval(
    %L::uuid, 'APPROVE', pg_temp.uid('process-agent-a@demo.local'), 3)$$,
    pg_temp.get('po')))                                        as purchase_approval,
  -- receipt2 is QC_COMPLETED (G7), i.e. exactly the state this RPC accepts —
  -- so the refusal here is the ROLE guard and nothing else
  pg_temp.error_text(format($$select wms.wms_apply_disposition(
    %L::uuid, 'DAMAGED', pg_temp.uid('process-agent-a@demo.local'), gen_random_uuid())$$,
    pg_temp.get('receipt2')))                                  as apply_disposition,
  pg_temp.error_text(format($$select wms.wms_resolve_equipment_fault(
    %L::uuid, '에이전트가 장애 해소를 선언', pg_temp.uid('process-agent-a@demo.local'),
    gen_random_uuid(), 1)$$, pg_temp.get('fault')))            as resolve_fault,
  pg_temp.error_text(format($$select wms.wms_exclude_equipment_from_routing(
    %L::uuid, '에이전트가 직접 제외', pg_temp.uid('process-agent-a@demo.local'),
    gen_random_uuid())$$, pg_temp.get('agv')))                 as exclude_equipment,
  pg_temp.error_text($$select wms.wms_register_wcs_routing_policy(
    '10000000-0000-0000-0000-00000000000a','20000000-0000-0000-0000-00000000000a',
    'AGV', 9, 9, pg_temp.uid('process-agent-a@demo.local'), gen_random_uuid())$$)
                                                               as routing_policy;

-- ...while the one action the Wave Coordinator mapping DOES allow autonomously
-- still works, which is the other half of D6.
select
  (wms.wms_retry_work_order_dispatch(
     pg_temp.get('wo1')::uuid, pg_temp.uid('process-agent-a@demo.local'),
     gen_random_uuid(),
     (select version from wms.work_orders where id = pg_temp.get('wo1')::uuid)))->>'status'
  as agent_retries_dispatch;

-- and the reasoning for it is filed on the same correlation_id, which is
-- exactly the join wms_operations-audit-log will consume (D5, migration V8).
select (wms.wms_log_agent_decision(
  :'tenant_a', :'wh_a',
  'AGENT-V-7: 32분 지연 + 유일 후보 AGV가 제외 상태여서 재시도했으나 여전히 배차 불가. 사람이 제외를 해제해야 한다.',
  pg_temp.uid('process-agent-a@demo.local'), gen_random_uuid(),
  'DISPATCH_RETRY', 'work_order', pg_temp.get('wo1')::uuid, null,
  'AGENT-V-JOIN-1'))->>'status' as reasoning_filed;

update wms.audit_events set correlation_id = 'AGENT-V-JOIN-1'
where command = 'wms_retry_work_order_dispatch'
  and entity_id = pg_temp.get('wo1')::uuid;

select ae.command, ae.entity_type, left(ad.reasoning, 20) as joined_reasoning, ad.status
from wms.audit_events ae
left join wms.agent_decisions ad on ad.correlation_id = ae.correlation_id
where ae.correlation_id = 'AGENT-V-JOIN-1'
order by ae.command;

\echo ''
\echo '============================================================'
\echo 'K. RLS, grants, cross-tenant'
\echo '============================================================'

-- K1. No write privilege leaked to authenticated/anon.
select grantee, string_agg(privilege_type, ',' order by privilege_type) as privileges
from information_schema.role_table_grants
where table_schema = 'wms' and table_name = 'agent_decisions'
  and grantee in ('authenticated', 'anon')
group by grantee order by grantee;

-- K2. Exactly one policy, SELECT only.
select policyname, cmd, qual
from pg_policies where schemaname = 'wms' and tablename = 'agent_decisions';

-- K3. With the session role dropped to `authenticated`, RLS is the only guard
--     left. This MUST run inside an explicit transaction block: psql
--     autocommits every statement, so a bare `set local role` outside one is a
--     no-op with a WARNING — and the checks below would then run as the table
--     OWNER, which bypasses RLS entirely and (worse) lets the negative
--     `delete` case succeed and wipe the fixtures. The rollback also undoes
--     anything the write probes manage to do.
begin;
set local role authenticated;
-- a tenant-A manager sees tenant A's rows...
select pg_temp.act('wh-manager-a@demo.local');
select current_user as effective_role, count(*) as tenant_a_manager_sees
from wms.agent_decisions;
-- ...and a tenant-B admin sees none of them.
select pg_temp.act('admin-b@demo.local');
select count(*) as tenant_b_admin_sees from wms.agent_decisions;
-- direct writes are denied outright
select pg_temp.error_text($$insert into wms.agent_decisions
  (tenant_id, warehouse_id, proposal_type, reasoning, status)
  values ('10000000-0000-0000-0000-00000000000a','20000000-0000-0000-0000-00000000000a',
          'X','direct insert','LOGGED')$$) as direct_insert;
select pg_temp.error_text($$update wms.agent_decisions set status = 'CONFIRMED'$$) as direct_update;
select pg_temp.error_text($$delete from wms.agent_decisions$$) as direct_delete;
rollback;

-- nothing survived the probes
select count(*) as rows_after_rls_probe from wms.agent_decisions;

-- K4. The RPCs refuse a cross-tenant call even for an admin of the other side.
select pg_temp.act('admin-b@demo.local');
select
  pg_temp.expect_error($$select wms.wms_get_agent_decisions(
    '10000000-0000-0000-0000-00000000000a','20000000-0000-0000-0000-00000000000a')$$)
      as read_other_tenant,
  pg_temp.expect_error($$select wms.wms_log_agent_decision(
    '10000000-0000-0000-0000-00000000000a','20000000-0000-0000-0000-00000000000a',
    'AGENT-V-교차 테넌트 기록', pg_temp.uid('admin-b@demo.local'), gen_random_uuid())$$)
      as log_other_tenant;

-- K5. ...and confirming a proposal in a warehouse you have no scope for is
--     FORBIDDEN even though your role would otherwise allow review.
select pg_temp.error_text(format($$select wms.wms_confirm_agent_proposal(
  %L::uuid, pg_temp.uid('admin-b@demo.local'), gen_random_uuid(), 1)$$,
  pg_temp.get('prop3'))) as confirm_out_of_scope;

\echo ''
\echo '============================================================'
\echo 'L. Audit trail  (spec: 감사 추적)'
\echo '============================================================'

select command, entity_type, count(*) as n,
       count(*) filter (where before is not null) as with_before,
       count(*) filter (where after is not null)  as with_after,
       count(*) filter (where correlation_id is not null) as with_correlation
from wms.audit_events
where entity_type = 'agent_decision'
group by command, entity_type
order by command;

-- the confirm event carries the transition, not just the end state
select
  before->>'status' || '->' || (after->>'status') as transition,
  after->>'confirmed_by' is not null              as after_has_confirmer
from wms.audit_events
where command = 'wms_confirm_agent_proposal' and entity_id = pg_temp.get('prop1')::uuid;

select
  before->>'status' || '->' || (after->>'status') as transition,
  left(after->>'rejection_reason', 16)            as reason_head
from wms.audit_events
where command = 'wms_reject_agent_proposal' and entity_id = pg_temp.get('prop2')::uuid;

-- V8: a decision filed with no caller correlation_id is still reachable from
-- the audit log, by its own id.
select
  (select count(*) from wms.audit_events ae
    join wms.agent_decisions ad on ad.id::text = ae.correlation_id
   where ae.entity_type = 'agent_decision' and ad.correlation_id is null)
  as fallback_correlation_rows;

\echo ''
\echo '============================================================'
\echo 'M. Cleanup'
\echo '============================================================'

delete from wms.audit_events where entity_type = 'agent_decision';
delete from wms.agent_decisions where reasoning like 'AGENT-V-%';
delete from wms.labor_activities where activity_label like 'AGENT-V-%';
delete from wms.work_orders where correlation_id like 'AGENT-V-%';
delete from wms.wcs_routing_overrides where equipment_id in
  (select id from wms.equipment where equipment_code like 'AGENT-V-%');
delete from wms.equipment_faults where fault_code like 'AGENT-V-%';
delete from wms.equipment_commands where equipment_id in
  (select id from wms.equipment where equipment_code like 'AGENT-V-%');
delete from wms.equipment where equipment_code like 'AGENT-V-%';
delete from wms.dispatch_waves where id = pg_temp.get('wave')::uuid;
delete from wms.audit_events where correlation_id like 'AGENT-V-%';
delete from wms.stock_ledger_entries
 where source_id in (pg_temp.get('receipt')::uuid, pg_temp.get('receipt2')::uuid);
delete from wms.quality_inspections
 where receipt_id in (pg_temp.get('receipt')::uuid, pg_temp.get('receipt2')::uuid);
delete from wms.inventory_dispositions
 where receipt_id in (pg_temp.get('receipt')::uuid, pg_temp.get('receipt2')::uuid);
delete from wms.audit_events where entity_id in
  (pg_temp.get('receipt')::uuid, pg_temp.get('po')::uuid,
   pg_temp.get('receipt2')::uuid, pg_temp.get('po2')::uuid);
delete from wms.receipts
 where id in (pg_temp.get('receipt')::uuid, pg_temp.get('receipt2')::uuid);
delete from wms.purchase_orders
 where id in (pg_temp.get('po')::uuid, pg_temp.get('po2')::uuid);
delete from wms.idempotency_records where command_name in (
  'wms_log_agent_decision', 'wms_propose_agent_action',
  'wms_confirm_agent_proposal', 'wms_reject_agent_proposal');

select
  (select count(*) from wms.agent_decisions)                                   as decisions_left,
  (select count(*) from wms.labor_activities where activity_label like 'AGENT-V-%') as labor_left,
  (select count(*) from wms.work_orders where correlation_id like 'AGENT-V-%')      as work_orders_left,
  (select count(*) from wms.equipment where equipment_code like 'AGENT-V-%')        as equipment_left;

\echo ''
\echo 'verify.sql complete.'
