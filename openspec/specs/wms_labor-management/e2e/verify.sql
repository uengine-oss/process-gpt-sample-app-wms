\set QUIET on
\pset pager off
\pset format aligned
\set ON_ERROR_STOP on

-- ============================================================
-- wms_labor-management — psql verification suite
--
--   docker exec -i supabase_db_process-gpt-sample-app-wms \
--     psql -U postgres -d postgres -f - < verify.sql
--
-- Self-contained: creates its own LABOR-V-* fixtures, exercises every RPC and
-- every guard in specs/wms_labor-management/spec.md, then cleans up. Safe to
-- re-run without a db reset.
--
-- The privacy assertions (sections E, F, H) are the heart of this suite —
-- design.md D3 asks for the same rule to hold at two independent layers, so
-- each one is checked twice: once through the aggregation RPCs (which are
-- SECURITY DEFINER and therefore bypass RLS) and once against the table with
-- the session role dropped to `authenticated` (where RLS is the only guard).
-- ============================================================

\set tenant_a '10000000-0000-0000-0000-00000000000a'
\set wh_a     '20000000-0000-0000-0000-00000000000a'
\set tenant_b '10000000-0000-0000-0000-00000000000b'
\set wh_b     '20000000-0000-0000-0000-00000000000b'

create or replace function pg_temp.act(p_email text) returns void
language plpgsql as $fn$
declare v_id uuid;
begin
  select id into v_id from auth.users where email = p_email;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_id::text, 'role', 'authenticated')::text, false);
end
$fn$;

-- SECURITY DEFINER because section H drops the session role to
-- `authenticated`, which has no privilege on auth.users.
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

-- The RPCs stamp started_at = now() and completed_at = now(); in a script
-- where every statement is its own transaction those are milliseconds apart,
-- so a completed activity would always measure 0s. Backdating started_at by
-- hand (superuser, bypassing RLS) lets the generated duration_seconds column
-- be checked against a known number instead.
create or replace function pg_temp.backdate(p_id uuid, p_seconds int) returns void
language sql as $fn$
  update wms.labor_activities
  set started_at = started_at - make_interval(secs => p_seconds)
  where id = p_id;
$fn$;

-- ------------------------------------------------------------
-- Fixtures
-- ------------------------------------------------------------
delete from wms.labor_activities where activity_label like 'LABOR-V-%' or actor_role = 'LABOR-V-ROLE';
delete from wms.idempotency_records where command_name like 'wms_%labor%';
delete from wms.audit_events where entity_type = 'labor_activity'
  and (after->>'activity_label') like 'LABOR-V-%';

\echo ''
\echo '=============================================================='
\echo 'A. Schema shape'
\echo '=============================================================='

\echo '-- A1 columns, generated duration, CHECK constraints'
select column_name, data_type, is_generated
from information_schema.columns
where table_schema = 'wms' and table_name = 'labor_activities'
order by ordinal_position;

\echo ''
\echo '-- A2 CHECK constraints from design.md'
select conname
from pg_constraint
where conrelid = 'wms.labor_activities'::regclass and contype = 'c'
order by conname;

\echo ''
\echo '-- A3 the six RPCs exist and are SECURITY DEFINER'
select p.proname, p.prosecdef, p.provolatile
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'wms' and p.proname like '%labor%'
order by p.proname;
\echo '-- expected: 6 wms_* RPCs + 2 internal _wms_* helpers, all prosecdef=t'

\echo ''
\echo '=============================================================='
\echo 'B. Start (spec: 인력 활동 시작 기록 / 본인 명의 기록 원칙)'
\echo '=============================================================='

select pg_temp.act('inbound-a@demo.local');

\echo '-- B1 happy path: IN_PROGRESS, version 1, role snapshot taken'
select
  r->>'status' as status,
  r->>'version' as version,
  r->>'actor_role' as actor_role,
  r->>'next_actions' as next_actions
from (select wms.wms_start_labor_activity(
  :'tenant_a', :'wh_a', 'RECEIVING',
  pg_temp.uid('inbound-a@demo.local'), gen_random_uuid(),
  'LABOR-V-B1', 'receipt', gen_random_uuid(), 'verify-B1') as r) s;
\echo '-- expected: IN_PROGRESS | 1 | INBOUND_OPERATOR | [complete, cancel]'

\echo ''
\echo '-- B2 OTHER without activity_label -> INVALID; with one -> ok'
select
  pg_temp.expect_error(format(
    'select wms.wms_start_labor_activity(%L, %L, %L, %L, gen_random_uuid())',
    :'tenant_a', :'wh_a', 'OTHER', pg_temp.uid('inbound-a@demo.local'))) as other_without_label,
  pg_temp.expect_error(format(
    'select wms.wms_start_labor_activity(%L, %L, %L, %L, gen_random_uuid(), %L)',
    :'tenant_a', :'wh_a', 'BOGUS_TYPE', pg_temp.uid('inbound-a@demo.local'), 'LABOR-V-B2')) as unknown_type,
  (wms.wms_start_labor_activity(:'tenant_a', :'wh_a', 'OTHER',
     pg_temp.uid('inbound-a@demo.local'), gen_random_uuid(),
     'LABOR-V-B2-other', null, null, 'verify-B2'))->>'status' as other_with_label;
\echo '-- expected: INVALID | INVALID | IN_PROGRESS'

\echo ''
\echo '-- B3 D2 actor-spoofing guard: A cannot record under B''s name'
select pg_temp.error_text(format(
  'select wms.wms_start_labor_activity(%L, %L, %L, %L, gen_random_uuid(), %L)',
  :'tenant_a', :'wh_a', 'RECEIVING',
  pg_temp.uid('quality-a@demo.local'), 'LABOR-V-B3-spoof')) as spoof_attempt;
select count(*) as spoofed_rows_created from wms.labor_activities where activity_label = 'LABOR-V-B3-spoof';
\echo '-- expected: FORBIDDEN: actor_id must be the calling user ... | 0'

\echo ''
\echo '-- B4 WMS_ADMIN is the one proxy exception (offline worker, correction)'
select pg_temp.act('admin-a@demo.local');
select
  r->>'actor_role' as proxied_role,
  (r->>'actor_id') = pg_temp.uid('quality-a@demo.local')::text as attributed_to_b
from (select wms.wms_start_labor_activity(
  :'tenant_a', :'wh_a', 'QUALITY_INSPECTION',
  pg_temp.uid('quality-a@demo.local'), gen_random_uuid(),
  'LABOR-V-B4-proxy', null, null, 'verify-B4') as r) s;
\echo '-- expected: QUALITY_INSPECTOR | t   (role snapshot follows the WORKER, not the admin)'

\echo ''
\echo '-- B5 no warehouse scope -> FORBIDDEN (tenant B admin against warehouse A)'
select pg_temp.act('admin-b@demo.local');
select pg_temp.error_text(format(
  'select wms.wms_start_labor_activity(%L, %L, %L, %L, gen_random_uuid(), %L)',
  :'tenant_a', :'wh_a', 'RECEIVING',
  pg_temp.uid('admin-b@demo.local'), 'LABOR-V-B5')) as no_scope;

\echo ''
\echo '-- B6 a role outside the write set -> FORBIDDEN (PROCUREMENT_BUYER)'
select pg_temp.act('buyer-a@demo.local');
select pg_temp.error_text(format(
  'select wms.wms_start_labor_activity(%L, %L, %L, %L, gen_random_uuid(), %L)',
  :'tenant_a', :'wh_a', 'RECEIVING',
  pg_temp.uid('buyer-a@demo.local'), 'LABOR-V-B6')) as wrong_role;

\echo ''
\echo '-- B7 idempotency: the same key returns the same activity, once'
\echo '--    (the follow-up count is a SEPARATE statement on purpose — a'
\echo '--     sub-SELECT beside the RPC call would read the pre-statement'
\echo '--     snapshot and report 0. Harness artifact, not contract behaviour.)'
select pg_temp.act('inbound-a@demo.local');
select (wms.wms_start_labor_activity(:'tenant_a', :'wh_a', 'PUTAWAY',
   pg_temp.uid('inbound-a@demo.local'), '99999999-0000-0000-0000-0000000000b7',
   'LABOR-V-B7', null, null, 'verify-B7'))->>'document_id' as first_call;
select (wms.wms_start_labor_activity(:'tenant_a', :'wh_a', 'PUTAWAY',
   pg_temp.uid('inbound-a@demo.local'), '99999999-0000-0000-0000-0000000000b7',
   'LABOR-V-B7', null, null, 'verify-B7'))->>'document_id' as replayed_call;
select count(*) as rows_created from wms.labor_activities where activity_label = 'LABOR-V-B7';
\echo '-- expected: the same uuid twice | 1'

\echo ''
\echo '=============================================================='
\echo 'C. Complete (spec: 인력 활동 완료 기록)'
\echo '=============================================================='

\echo '-- C1 the spec''s worked example: started 09:00:00, completed 09:12:30,'
\echo '--    unit_count 48 -> duration_seconds 750'
select pg_temp.backdate((select id from wms.labor_activities where activity_label = 'LABOR-V-B1'), 750);
select pg_temp.act('inbound-a@demo.local');
select
  r->>'status' as status,
  r->>'version' as version,
  r->>'duration_seconds' as duration_seconds,
  r->>'unit_count' as unit_count
from (select wms.wms_complete_labor_activity(
  (select id from wms.labor_activities where activity_label = 'LABOR-V-B1'),
  pg_temp.uid('inbound-a@demo.local'), gen_random_uuid(), 1, 48, 'verify-C1') as r) s;
\echo '-- expected: COMPLETED | 2 | 750 | 48'

\echo ''
\echo '-- C2 completing twice -> INVALID, and a stale version -> CONFLICT'
select
  pg_temp.expect_error(format(
    'select wms.wms_complete_labor_activity(%L, %L, gen_random_uuid(), 2, 10)',
    (select id from wms.labor_activities where activity_label = 'LABOR-V-B1'),
    pg_temp.uid('inbound-a@demo.local'))) as complete_twice,
  pg_temp.expect_error(format(
    'select wms.wms_complete_labor_activity(%L, %L, gen_random_uuid(), 9, 10)',
    (select id from wms.labor_activities where activity_label = 'LABOR-V-B2-other'),
    pg_temp.uid('inbound-a@demo.local'))) as stale_version;
select status, version from wms.labor_activities where activity_label = 'LABOR-V-B2-other';
\echo '-- expected: INVALID | CONFLICT, and the target row untouched at IN_PROGRESS/1'

\echo ''
\echo '-- C3 D2 again on the closing side: A cannot close B''s activity'
select pg_temp.error_text(format(
  'select wms.wms_complete_labor_activity(%L, %L, gen_random_uuid(), 1, 5)',
  (select id from wms.labor_activities where activity_label = 'LABOR-V-B4-proxy'),
  pg_temp.uid('inbound-a@demo.local'))) as close_someone_elses;

\echo ''
\echo '-- C4 the admin closes the proxied activity it opened for worker B'
select pg_temp.backdate((select id from wms.labor_activities where activity_label = 'LABOR-V-B4-proxy'), 1800);
select pg_temp.act('admin-a@demo.local');
select
  r->>'duration_seconds' as duration_seconds,
  r->>'unit_count' as unit_count,
  r->>'status' as status
from (select wms.wms_complete_labor_activity(
  (select id from wms.labor_activities where activity_label = 'LABOR-V-B4-proxy'),
  pg_temp.uid('quality-a@demo.local'), gen_random_uuid(), 1, 60, 'verify-C4') as r) s;
\echo '-- expected: 1800 | 60 | COMPLETED'

\echo ''
\echo '-- C5 completing with no unit_count is allowed, and warns'
select pg_temp.act('inbound-a@demo.local');
select pg_temp.backdate((select id from wms.labor_activities where activity_label = 'LABOR-V-B7'), 600);
select
  r->>'unit_count' as unit_count,
  r->>'warnings' as warnings
from (select wms.wms_complete_labor_activity(
  (select id from wms.labor_activities where activity_label = 'LABOR-V-B7'),
  pg_temp.uid('inbound-a@demo.local'), gen_random_uuid(), 1, null, 'verify-C5') as r) s;
\echo '-- expected: (null) | ["NO_UNIT_COUNT_RECORDED"]'

\echo ''
\echo '=============================================================='
\echo 'D. Cancel (spec: 인력 활동 취소 — excluded from every aggregate)'
\echo '=============================================================='

\echo '-- D1 IN_PROGRESS -> CANCELLED'
select pg_temp.backdate((select id from wms.labor_activities where activity_label = 'LABOR-V-B2-other'), 3600);
select
  r->>'status' as status,
  r->>'reason' as reason,
  r->>'warnings' as warnings
from (select wms.wms_cancel_labor_activity(
  (select id from wms.labor_activities where activity_label = 'LABOR-V-B2-other'),
  pg_temp.uid('inbound-a@demo.local'), gen_random_uuid(), 1,
  '다른 작업으로 재배정됨', 'verify-D1') as r) s;
\echo '-- expected: CANCELLED | 다른 작업으로 재배정됨 | ["EXCLUDED_FROM_PRODUCTIVITY"]'

\echo ''
\echo '-- D2 a CANCELLED activity cannot be completed or cancelled again'
select
  pg_temp.expect_error(format(
    'select wms.wms_complete_labor_activity(%L, %L, gen_random_uuid(), 2, 10)',
    (select id from wms.labor_activities where activity_label = 'LABOR-V-B2-other'),
    pg_temp.uid('inbound-a@demo.local'))) as complete_cancelled,
  pg_temp.expect_error(format(
    'select wms.wms_cancel_labor_activity(%L, %L, gen_random_uuid(), 2, null)',
    (select id from wms.labor_activities where activity_label = 'LABOR-V-B2-other'),
    pg_temp.uid('inbound-a@demo.local'))) as cancel_twice;
\echo '-- expected: INVALID | INVALID'

\echo ''
\echo '-- D3 the cancelled hour (3600s) is nowhere in the aggregate'
select
  (r->'totals'->>'completed_count') as completed_count,
  (r->'totals'->>'total_duration_seconds') as total_duration_seconds,
  (r->'totals'->>'total_unit_count') as total_unit_count
from (select wms.wms_get_labor_productivity(
  :'tenant_a', :'wh_a', now() - interval '1 hour', now() + interval '1 hour',
  pg_temp.uid('inbound-a@demo.local'), null) as r) s;
\echo '-- expected: 2 | 1350 (=750+600) | 48   — the 3600s cancellation is absent'

\echo ''
\echo '=============================================================='
\echo 'E. Productivity aggregation (spec: 작업자별 생산성 집계 조회)'
\echo '=============================================================='

\echo '-- E1 the manager sees BOTH workers (scope=WAREHOUSE)'
select pg_temp.act('wh-manager-a@demo.local');
select
  r->>'scope' as scope,
  (r->'totals'->>'distinct_actor_count') as distinct_actors,
  (select count(*) from jsonb_array_elements(r->'rows') e
     where (e->>'actor_email') = 'quality-a@demo.local') as sees_worker_b
from (select wms.wms_get_labor_productivity(
  :'tenant_a', :'wh_a', now() - interval '1 hour', now() + interval '1 hour', null, null) as r) s;
\echo '-- expected: WAREHOUSE | 2 | 1'

\echo ''
\echo '-- E2 PRIVACY: worker A gets scope=SELF and worker B is invisible,'
\echo '--    even though A explicitly asked for B''s actor_id'
select pg_temp.act('inbound-a@demo.local');
select
  r->>'scope' as scope,
  (r->'totals'->>'distinct_actor_count') as distinct_actors,
  (select count(*) from jsonb_array_elements(r->'rows') e
     where (e->>'actor_email') <> 'inbound-a@demo.local') as foreign_rows,
  r->>'notes' as notes
from (select wms.wms_get_labor_productivity(
  :'tenant_a', :'wh_a', now() - interval '1 hour', now() + interval '1 hour',
  pg_temp.uid('quality-a@demo.local'), null) as r) s;
\echo '-- expected: SELF | 1 | 0 | ["SELF_SCOPE_ONLY"]   — the p_actor_id argument was overwritten, not refused'

\echo ''
\echo '-- E3 grouping is by worker x role x date x activity_type, and each row'
\echo '--    carries count / avg / total duration / total units'
select pg_temp.act('wh-manager-a@demo.local');
select jsonb_pretty(jsonb_agg(e order by e->>'actor_email', e->>'activity_type')) as rows
from (select wms.wms_get_labor_productivity(
  :'tenant_a', :'wh_a', now() - interval '1 hour', now() + interval '1 hour', null, null) as r) s,
  lateral jsonb_array_elements(s.r->'rows') e;

\echo ''
\echo '-- E4 a role filter narrows the aggregate'
select
  (r->'totals'->>'completed_count') as inbound_operator_only,
  (r->'totals'->>'distinct_actor_count') as actors
from (select wms.wms_get_labor_productivity(
  :'tenant_a', :'wh_a', now() - interval '1 hour', now() + interval '1 hour',
  null, 'INBOUND_OPERATOR') as r) s;
\echo '-- expected: 2 | 1'

\echo ''
\echo '-- E5 an out-of-scope warehouse -> FORBIDDEN; an inverted period -> INVALID'
select pg_temp.act('admin-b@demo.local');
select pg_temp.expect_error(format(
  'select wms.wms_get_labor_productivity(%L, %L, now() - interval ''1 day'', now())',
  :'tenant_a', :'wh_a')) as cross_tenant;
select pg_temp.act('wh-manager-a@demo.local');
select pg_temp.expect_error(format(
  'select wms.wms_get_labor_productivity(%L, %L, now(), now() - interval ''1 day'')',
  :'tenant_a', :'wh_a')) as inverted_period;
\echo '-- expected: FORBIDDEN | INVALID'

\echo ''
\echo '=============================================================='
\echo 'F. Leaderboard (spec: 생산성 리더보드 조회)'
\echo '=============================================================='

\echo '-- F1 the manager gets a ranked board over all workers'
select pg_temp.act('wh-manager-a@demo.local');
select
  e->>'rank' as rank,
  e->>'actor_email' as actor,
  e->>'actor_role' as role,
  e->>'completed_count' as completed,
  e->>'total_unit_count' as units,
  e->>'avg_duration_seconds' as avg_seconds
from (select wms.wms_get_labor_leaderboard(
  :'tenant_a', :'wh_a', now() - interval '1 hour', now() + interval '1 hour',
  'completed_count') as r) s,
  lateral jsonb_array_elements(s.r->'rows') e
order by (e->>'rank')::int;
\echo '-- expected: rank 1 = inbound-a (2 completions), rank 2 = quality-a (1)'

\echo ''
\echo '-- F2 the metric really changes the order'
select
  (r->'rows'->0->>'actor_email') as top_by_units,
  (r->>'metric') as metric
from (select wms.wms_get_labor_leaderboard(
  :'tenant_a', :'wh_a', now() - interval '1 hour', now() + interval '1 hour',
  'total_unit_count') as r) s;
select
  (r->'rows'->0->>'actor_email') as fastest_avg,
  (r->'rows'->0->>'avg_duration_seconds') as avg_seconds
from (select wms.wms_get_labor_leaderboard(
  :'tenant_a', :'wh_a', now() - interval '1 hour', now() + interval '1 hour',
  'avg_duration_seconds') as r) s;
\echo '-- expected: quality-a leads by units (60 > 48); inbound-a leads by speed (675s < 1800s)'

\echo ''
\echo '-- F3 PRIVACY: a non-manager gets ONE row (their own), no error, no rank'
select pg_temp.act('inbound-a@demo.local');
select
  r->>'scope' as scope,
  r->>'row_count' as row_count,
  (r->'rows'->0->>'actor_email') as only_row,
  (r->'rows'->0->'rank')::text as rank,
  r->>'notes' as notes
from (select wms.wms_get_labor_leaderboard(
  :'tenant_a', :'wh_a', now() - interval '1 hour', now() + interval '1 hour',
  'completed_count') as r) s;
\echo '-- expected: SELF | 1 | inbound-a@demo.local | null | [SELF_SCOPE_ONLY, SELF_SCOPE_RANK_WITHHELD]'
\echo '--    (V3: a fake rank=1 would be a lie, a true global rank would leak how'
\echo '--     many colleagues are ahead — so it is withheld and says so)'

\echo ''
\echo '-- F4 an unknown metric -> INVALID'
select pg_temp.expect_error(format(
  'select wms.wms_get_labor_leaderboard(%L, %L, now() - interval ''1 day'', now(), %L)',
  :'tenant_a', :'wh_a', 'points')) as bogus_metric;

\echo ''
\echo '=============================================================='
\echo 'G. Demand forecast (spec: 인력 수요 추정 — 단순 비율 계산)'
\echo '=============================================================='

\echo '-- G0 an ISOLATED sample so the arithmetic can be checked against a known'
\echo '--    number. actor_role is free text (design.md D4 reuses membership'
\echo '--    roles rather than constraining them), so a synthetic role gives a'
\echo '--    trailing window that neither the seeds nor the fixtures above touch:'
\echo '--    3 activities, 90 units, 16200s = 20 units/hour — exactly spec.md''s'
\echo '--    worked example.'
insert into wms.labor_activities (
  tenant_id, warehouse_id, actor_id, actor_role, activity_type, activity_label,
  unit_count, status, started_at, completed_at)
select :'tenant_a', :'wh_a', pg_temp.uid('inbound-a@demo.local'), 'LABOR-V-ROLE',
       'OTHER', 'LABOR-V-FC-' || g, 30, 'COMPLETED',
       now() - make_interval(days => g, secs => 5400), now() - make_interval(days => g)
from generate_series(1, 3) g;
select actor_role, count(*) as sample_count, sum(unit_count) as units, sum(duration_seconds) as seconds
from wms.labor_activities where actor_role = 'LABOR-V-ROLE' group by 1;
\echo '-- expected: LABOR-V-ROLE | 3 | 90 | 16200'

\echo ''
\echo '-- G1 spec.md''s worked example: 20 units/hour x 8h = 160 per person per'
\echo '--    shift; 480 / 160 = 3'
select pg_temp.act('wh-manager-a@demo.local');
select
  r->>'recommended_headcount' as headcount,
  (r->'basis'->>'avg_units_per_hour') as units_per_hour,
  (r->'basis'->>'units_per_person_per_shift') as per_person_per_shift,
  (r->'basis'->>'trailing_days') as trailing_days,
  (r->'basis'->>'sample_count') as sample_count,
  r->>'method' as method
from (select wms.wms_forecast_labor_demand(
  :'tenant_a', :'wh_a', 'LABOR-V-ROLE', 480, 7, 8) as r) s;
\echo '-- expected: 3 | 20.00 | 160.00 | 7 | 3 | SIMPLE_RATIO'

\echo ''
\echo '-- G1b the response says out loud that this is arithmetic, not ML'
select (wms.wms_forecast_labor_demand(:'tenant_a', :'wh_a', 'LABOR-V-ROLE', 480, 7, 8))->>'method_note' as method_note;

\echo ''
\echo '-- G2 rounding is UP — a fractional person is a whole person'
select
  (wms.wms_forecast_labor_demand(:'tenant_a', :'wh_a', 'LABOR-V-ROLE', 161, 7, 8))->>'recommended_headcount' as v161,
  (wms.wms_forecast_labor_demand(:'tenant_a', :'wh_a', 'LABOR-V-ROLE', 160, 7, 8))->>'recommended_headcount' as v160,
  (wms.wms_forecast_labor_demand(:'tenant_a', :'wh_a', 'LABOR-V-ROLE', 480, 7, 4))->>'recommended_headcount' as v480_half_shift;
\echo '-- expected: 2 | 1 | 6   (halving the shift doubles the headcount — pure ratio)'

\echo ''
\echo '-- G2b the trailing window really is a window: 1 day back sees 0 samples'
\echo '--    of a role whose activities are all 1-3 days old -> INVALID'
select pg_temp.expect_error(format(
  'select wms.wms_forecast_labor_demand(%L, %L, %L, 480, 1, 8)',
  :'tenant_a', :'wh_a', 'LABOR-V-ROLE')) as one_day_window;

\echo ''
\echo '-- G2c the same identity holds on the REAL seed data, whatever it contains:'
\echo '--     headcount == ceil(expected_volume / (units_per_hour * shift_hours))'
select
  (r->>'recommended_headcount')::int as headcount,
  ceil(480 / ((r->'basis'->>'avg_units_per_hour')::numeric * 8))::int as recomputed,
  (r->>'recommended_headcount')::int
    = ceil(480 / ((r->'basis'->>'avg_units_per_hour')::numeric * 8))::int as identity_holds
from (select wms.wms_forecast_labor_demand(
  :'tenant_a', :'wh_a', 'INBOUND_OPERATOR', 480, 7, 8) as r) s;
\echo '-- expected: identity_holds = t'

\echo ''
\echo '-- G3 no sample for the role -> INVALID, no number invented'
select pg_temp.error_text(format(
  'select wms.wms_forecast_labor_demand(%L, %L, %L, 480, 7, 8)',
  :'tenant_a', :'wh_a', 'PROCUREMENT_BUYER')) as no_sample;

\echo ''
\echo '-- G4 D4: a plain worker cannot forecast -> FORBIDDEN'
select pg_temp.act('inbound-a@demo.local');
select pg_temp.error_text(format(
  'select wms.wms_forecast_labor_demand(%L, %L, %L, 480, 7, 8)',
  :'tenant_a', :'wh_a', 'INBOUND_OPERATOR')) as worker_forecast;

\echo ''
\echo '-- G5 argument validation'
select pg_temp.act('wh-manager-a@demo.local');
select
  pg_temp.expect_error(format('select wms.wms_forecast_labor_demand(%L, %L, %L, 0, 7, 8)',
    :'tenant_a', :'wh_a', 'QUALITY_INSPECTOR')) as zero_volume,
  pg_temp.expect_error(format('select wms.wms_forecast_labor_demand(%L, %L, %L, 480, 0, 8)',
    :'tenant_a', :'wh_a', 'QUALITY_INSPECTOR')) as zero_days,
  pg_temp.expect_error(format('select wms.wms_forecast_labor_demand(%L, %L, %L, 480, 7, 0)',
    :'tenant_a', :'wh_a', 'QUALITY_INSPECTOR')) as zero_shift;
\echo '-- expected: INVALID | INVALID | INVALID'

\echo ''
\echo '=============================================================='
\echo 'H. RLS on the table itself (spec: 개인 생산성 데이터 접근 통제)'
\echo '--    Everything above went through SECURITY DEFINER RPCs, which bypass'
\echo '--    RLS. This section drops the session role to `authenticated` so the'
\echo '--    policy is the ONLY thing standing between the reader and the rows.'
\echo '=============================================================='

\echo '-- H1 worker A sees only their own rows — not colleague B''s'
select pg_temp.act('inbound-a@demo.local');
begin;
set local role authenticated;
select
  (select count(*) from wms.labor_activities where actor_id = pg_temp.uid('inbound-a@demo.local')) > 0 as sees_own,
  (select count(*) from wms.labor_activities where actor_id = pg_temp.uid('quality-a@demo.local')) as sees_colleague,
  (select count(distinct actor_id) from wms.labor_activities) as distinct_actors_visible;
rollback;
\echo '-- expected: t | 0 | 1'

\echo ''
\echo '-- H2 the WAREHOUSE_MANAGER sees both'
select pg_temp.act('wh-manager-a@demo.local');
begin;
set local role authenticated;
select (select count(distinct actor_id) from wms.labor_activities) as distinct_actors_visible;
rollback;
\echo '-- expected: 2'

\echo ''
\echo '-- H3 cross-tenant: tenant B''s admin sees zero tenant A rows'
select pg_temp.act('admin-b@demo.local');
begin;
set local role authenticated;
select
  (select count(*) from wms.labor_activities) as b_sees_any,
  (select count(*) from wms.labor_activities where tenant_id = '10000000-0000-0000-0000-00000000000a') as b_sees_a;
rollback;
\echo '-- expected: 0 | 0'

\echo ''
\echo '-- H4 direct writes as `authenticated` are denied (no INSERT/UPDATE policy)'
select pg_temp.act('inbound-a@demo.local');
begin;
set local role authenticated;
select pg_temp.expect_error(format($q$
  insert into wms.labor_activities (tenant_id, warehouse_id, actor_id, actor_role, activity_type)
  values (%L, %L, %L, 'INBOUND_OPERATOR', 'RECEIVING')$q$,
  '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-00000000000a',
  pg_temp.uid('inbound-a@demo.local'))) as direct_insert;
select pg_temp.expect_error(
  $q$update wms.labor_activities set unit_count = 9999 where activity_label like 'LABOR-V-%'$q$) as direct_update;
select pg_temp.expect_error(
  $q$delete from wms.labor_activities where activity_label like 'LABOR-V-%'$q$) as direct_delete;
rollback;
\echo '-- expected: permission-denied errors (or 0 affected rows), never a write'

\echo ''
\echo '-- H5 no DML privilege leaked to authenticated/anon'
select grantee, privilege_type
from information_schema.role_table_grants
where table_schema = 'wms' and table_name = 'labor_activities'
  and grantee in ('authenticated', 'anon')
order by grantee, privilege_type;
\echo '-- expected: SELECT for authenticated only'

\echo ''
\echo '=============================================================='
\echo 'I. Audit trail (spec: 인력 활동 감사 추적)'
\echo '=============================================================='

select command, entity_type,
       count(*) as events,
       count(*) filter (where before is not null) as with_before,
       count(*) filter (where after is not null) as with_after
from wms.audit_events
where command in ('wms_start_labor_activity', 'wms_complete_labor_activity', 'wms_cancel_labor_activity')
group by command, entity_type
order by command;
\echo '-- expected: all three commands, entity_type=labor_activity, complete/cancel carry before+after'

\echo ''
\echo '-- I2 the completion event''s before/after really is the transition'
select (before->>'status') || '->' || (after->>'status') as transition,
       (after->>'duration_seconds') as duration_after
from wms.audit_events
where command = 'wms_complete_labor_activity'
  and (after->>'activity_label') = 'LABOR-V-B1';
\echo '-- expected: IN_PROGRESS->COMPLETED | 750'

\echo ''
\echo '=============================================================='
\echo 'J. Independence from the inbound flow (design.md D1)'
\echo '--    This contract is instrumentation that sits BESIDE the receiving'
\echo '--    RPCs, never inside them. An untouched receipt must still walk the'
\echo '--    whole chain with no labor activity anywhere in sight.'
\echo '=============================================================='

delete from wms.receipts where po_id in (select id from wms.purchase_orders where reason = 'LABOR-V-FIXTURE');
delete from wms.purchase_orders where reason = 'LABOR-V-FIXTURE';
insert into wms.purchase_orders (id, tenant_id, warehouse_id, product_id, qty, status, reason)
select '4a000000-0000-0000-0000-0000000000a1', :'tenant_a', :'wh_a', p.id, 40, 'APPROVED', 'LABOR-V-FIXTURE'
from wms.products p where p.tenant_id = :'tenant_a' and p.sku = 'SKU-A-001';

select pg_temp.act('buyer-a@demo.local');
select (wms.wms_confirm_purchase_order('4a000000-0000-0000-0000-0000000000a1',
          pg_temp.uid('buyer-a@demo.local'), gen_random_uuid(), 1))->>'status' as po_confirmed;
select pg_temp.act('inbound-a@demo.local');
select (wms.wms_register_arrival('4a000000-0000-0000-0000-0000000000a1',
          pg_temp.uid('inbound-a@demo.local'), gen_random_uuid()))->>'status' as arrived;
select (wms.wms_receive(
          (select id from wms.receipts where po_id = '4a000000-0000-0000-0000-0000000000a1'),
          40, pg_temp.uid('inbound-a@demo.local'), gen_random_uuid(),
          (select version from wms.receipts where po_id = '4a000000-0000-0000-0000-0000000000a1')))->>'status' as received;
select pg_temp.act('quality-a@demo.local');
select (wms.wms_record_quality_result(
          (select id from wms.receipts where po_id = '4a000000-0000-0000-0000-0000000000a1'),
          'PASSED', null, pg_temp.uid('quality-a@demo.local'), gen_random_uuid()))->>'status' as inspected;
select pg_temp.act('inbound-a@demo.local');
select (wms.wms_create_putaway_tasks(
          (select id from wms.receipts where po_id = '4a000000-0000-0000-0000-0000000000a1'),
          pg_temp.uid('inbound-a@demo.local'), gen_random_uuid()))->>'status' as put_away;
\echo '-- expected: CONFIRMED_PO | ARRIVED | QC_PENDING | PUTAWAY_PENDING | PUTAWAY_COMPLETED'

\echo ''
\echo '-- J2 not one labor activity was created by that whole chain'
select count(*) as labor_rows_linked_to_the_receipt
from wms.labor_activities
where linked_entity_type = 'receipt'
  and linked_entity_id = (select id from wms.receipts where po_id = '4a000000-0000-0000-0000-0000000000a1');
\echo '-- expected: 0'

\echo ''
\echo '=============================================================='
\echo 'Cleanup'
\echo '=============================================================='
delete from wms.audit_events where entity_type = 'labor_activity'
  and (coalesce(after->>'activity_label', before->>'activity_label')) like 'LABOR-V-%';
delete from wms.labor_activities where activity_label like 'LABOR-V-%' or actor_role = 'LABOR-V-ROLE';
delete from wms.idempotency_records where command_name like 'wms_%labor%';
delete from wms.receipts where po_id in (select id from wms.purchase_orders where reason = 'LABOR-V-FIXTURE');
delete from wms.purchase_orders where reason = 'LABOR-V-FIXTURE';
select count(*) as leftover_fixtures from wms.labor_activities
where activity_label like 'LABOR-V-%' or actor_role = 'LABOR-V-ROLE';
\echo '-- expected: 0'
