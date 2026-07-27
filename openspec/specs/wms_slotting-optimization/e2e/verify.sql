\set QUIET on
\pset pager off
\pset format aligned
\set ON_ERROR_STOP on

-- ============================================================
-- wms_slotting-optimization — psql verification suite
--
--   docker exec -i supabase_db_process-gpt-sample-app-wms \
--     psql -U postgres -d postgres -f - < verify.sql
--
-- Self-contained: creates its own SLOT-V-* fixtures (products, locations,
-- policies, assignments and — see §D — synthetic ledger rows), exercises every
-- RPC and every guard in specs/wms_slotting-optimization/spec.md, then cleans
-- up. Safe to re-run without a db reset.
--
-- ------------------------------------------------------------
-- THE ONE THING TO READ BEFORE THE OUTPUT
--
-- §C proves the contract's honest default: with the repository exactly as it
-- ships, wms_compute_sku_velocity finds NOTHING, because no RPC anywhere in
-- this codebase writes a negative AVAILABLE qty_delta. That was re-checked
-- against the migrations as implemented, not against their design docs:
--
--     $ grep -n 'stock_ledger_entries' supabase/migrations/*.sql | grep -v 20260726
--     20260727_wcs_equipment_control.sql:25:  (a comment, nothing else)
--
-- Area 5's wms.outbound_orders (20260731) is real and does reach
-- status='COMPLETED', but it writes no ledger row on any path — so it cannot
-- serve as the consumption signal either. Area 6's simulation is
-- projection-only.
--
-- §D therefore INSERTS SYNTHETIC negative-AVAILABLE ledger rows as superuser.
-- Those rows are not produced by any RPC in this repository and are not
-- claimed to be: they stand in for the future outbound-fulfilment feature that
-- design.md's forward-looking contract is written against, and they exist only
-- so the ABC arithmetic can be exercised at all. Everything from §E onward is
-- computed off that stand-in data. The suite deletes it again in §L.
-- ------------------------------------------------------------

\set tenant_a '10000000-0000-0000-0000-00000000000a'
\set wh_a     '20000000-0000-0000-0000-00000000000a'
\set tenant_b '10000000-0000-0000-0000-00000000000b'
\set wh_b     '20000000-0000-0000-0000-00000000000b'

-- SECURITY DEFINER because §K drops the session role to `authenticated`,
-- which has no privilege on auth.users — but still has to switch identity.
create or replace function pg_temp.act(p_email text) returns void
language plpgsql security definer as $fn$
declare v_id uuid;
begin
  select id into v_id from auth.users where email = p_email;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_id::text, 'role', 'authenticated')::text, false);
end
$fn$;

-- SECURITY DEFINER because §K drops the session role to `authenticated`,
-- which has no privilege on auth.users.
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
  return left(sqlerrm, 110);
end
$fn$;

create or replace function pg_temp.pid(p_sku text) returns uuid
language sql stable security definer
as $fn$ select id from wms.products where sku = p_sku $fn$;

create or replace function pg_temp.lid(p_code text) returns uuid
language sql stable security definer
as $fn$ select id from wms.storage_locations where location_code = p_code $fn$;

create or replace function pg_temp.lver(p_code text) returns int
language sql stable security definer
as $fn$ select version from wms.storage_locations where location_code = p_code $fn$;

create or replace function pg_temp.aid(p_sku text) returns uuid
language sql stable security definer
as $fn$ select a.id from wms.sku_location_assignments a
        where a.product_id = (select id from wms.products where sku = p_sku) $fn$;

create or replace function pg_temp.aver(p_sku text) returns int
language sql stable security definer
as $fn$ select a.version from wms.sku_location_assignments a
        where a.product_id = (select id from wms.products where sku = p_sku) $fn$;

-- newest open/most recent recommendation for a SKU, and its version
create or replace function pg_temp.rid(p_sku text) returns uuid
language sql stable security definer
as $fn$ select r.id from wms.slotting_recommendations r
        where r.product_id = (select id from wms.products where sku = p_sku)
        order by r.created_at desc, r.id desc limit 1 $fn$;

create or replace function pg_temp.rver(p_sku text) returns int
language sql stable security definer
as $fn$ select r.version from wms.slotting_recommendations r
        where r.product_id = (select id from wms.products where sku = p_sku)
        order by r.created_at desc, r.id desc limit 1 $fn$;

-- where a SKU is declared to live, as a location_code
create or replace function pg_temp.at(p_sku text) returns text
language sql stable security definer
as $fn$ select l.location_code
        from wms.sku_location_assignments a
        join wms.storage_locations l on l.id = a.location_id
        where a.product_id = (select id from wms.products where sku = p_sku) $fn$;

-- ------------------------------------------------------------
-- Fixture teardown + setup
-- ------------------------------------------------------------
delete from wms.stock_ledger_entries where source_type = 'SLOT-V-synthetic-consumption';
delete from wms.audit_events where entity_type in
  ('storage_location', 'sku_location_assignment', 'slotting_class_policy',
   'sku_velocity_batch', 'slotting_recommendation');
delete from wms.idempotency_records where command_name in (
  'wms_register_storage_location', 'wms_set_storage_location_status',
  'wms_assign_sku_location', 'wms_reassign_sku_location',
  'wms_register_slotting_class_policy', 'wms_update_slotting_class_policy',
  'wms_compute_sku_velocity', 'wms_generate_slotting_recommendations',
  'wms_review_slotting_recommendation', 'wms_apply_slotting_recommendation');
delete from wms.sku_location_assignments;
delete from wms.slotting_recommendations;
delete from wms.sku_velocity_snapshots;
delete from wms.slotting_class_policies;
delete from wms.storage_locations;
delete from wms.products where sku like 'SLOT-V-%';

-- Four test SKUs so the ABC cutoffs have something to land on, plus tenant B
-- fixtures for the cross-tenant section.
insert into wms.products (tenant_id, sku, name, uom) values
  (:'tenant_a', 'SLOT-V-P1', 'Slotting verify SKU 1', 'EA'),
  (:'tenant_a', 'SLOT-V-P2', 'Slotting verify SKU 2', 'EA'),
  (:'tenant_a', 'SLOT-V-P3', 'Slotting verify SKU 3', 'EA'),
  (:'tenant_a', 'SLOT-V-P4', 'Slotting verify SKU 4', 'EA'),
  (:'tenant_b', 'SLOT-V-B1', 'Slotting verify SKU B1', 'EA');

\echo ''
\echo '=============================================================='
\echo 'A. Schema shape'
\echo '=============================================================='

\echo '-- A1 the five new tables exist with RLS enabled'
select c.relname, c.relrowsecurity
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'wms'
  and c.relname in ('storage_locations', 'sku_location_assignments',
                    'slotting_class_policies', 'sku_velocity_snapshots',
                    'slotting_recommendations')
order by c.relname;
\echo '-- expected: 5 rows, relrowsecurity = t on every one'

\echo ''
\echo '-- A2 exactly one SELECT policy per table, and nothing else'
select tablename, policyname, cmd
from pg_policies
where schemaname = 'wms'
  and tablename in ('storage_locations', 'sku_location_assignments',
                    'slotting_class_policies', 'sku_velocity_snapshots',
                    'slotting_recommendations')
order by tablename;
\echo '-- expected: 5 rows, cmd = SELECT on every one (writes go through the RPCs)'

\echo ''
\echo '-- A3 uniqueness + CHECK constraints from design.md / tasks.md 1.2, 1.3'
select conrelid::regclass::text as tbl, conname, contype
from pg_constraint
where connamespace = 'wms'::regnamespace
  and conrelid::regclass::text in
    ('wms.storage_locations', 'wms.sku_location_assignments',
     'wms.slotting_class_policies', 'wms.sku_velocity_snapshots',
     'wms.slotting_recommendations')
  and contype in ('u', 'c')
order by tbl, conname;
\echo '-- expected: storage_locations_code_uq, sku_location_assignments_uq,'
\echo '--           slotting_class_policies_uq + the rank/capacity/status CHECKs'

\echo ''
\echo '-- A4 the ten RPCs exist, SECURITY DEFINER'
select p.proname, p.prosecdef
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'wms'
  and (p.proname like '%slotting%' or p.proname like '%storage_location%'
       or p.proname like '%sku_location%' or p.proname like '%sku_velocity%')
order by p.proname;
\echo '-- expected: 10 wms_* RPCs + 3 internal _wms_* helpers, prosecdef=t'

\echo ''
\echo '-- A5 the overview view is security_invoker (inherits base-table RLS)'
select c.relname, c.reloptions
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'wms' and c.relname = 'slotting_recommendation_overview_v';
\echo '-- expected: {security_invoker=true}'

\echo ''
\echo '=============================================================='
\echo 'B. Location registry, assignments, policies'
\echo '   (spec: 창고별 보관 위치 등록 / 보관 위치 활성 상태 관리 /'
\echo '          SKU-위치 배정 선언 및 재배정 / 속도 등급별 목표 접근성 정책)'
\echo '=============================================================='

select pg_temp.act('wh-manager-a@demo.local');

\echo '-- B1 register: ACTIVE, version 1'
select
  r->>'location_code' as code, r->>'status' as status, r->>'version' as version,
  r->>'accessibility_rank' as rank, r->>'next_actions' as next_actions
from (select wms.wms_register_storage_location(
  :'tenant_a', :'wh_a', 'PACK_ADJACENT', 'SLOT-V-A-01', 1,
  pg_temp.uid('wh-manager-a@demo.local'), gen_random_uuid(), null, 'verify-B1') as r) s;
\echo '-- expected: SLOT-V-A-01 | ACTIVE | 1 | 1'

-- the rest of the registry, quietly
select wms.wms_register_storage_location(:'tenant_a', :'wh_a', 'PACK_ADJACENT', 'SLOT-V-A-02', 2,
         pg_temp.uid('wh-manager-a@demo.local'), gen_random_uuid()) is not null as ok \gset ok_
select wms.wms_register_storage_location(:'tenant_a', :'wh_a', 'PACK_ADJACENT', 'SLOT-V-A-03', 3,
         pg_temp.uid('wh-manager-a@demo.local'), gen_random_uuid()) is not null as ok \gset ok_
select wms.wms_register_storage_location(:'tenant_a', :'wh_a', 'BULK_STORAGE', 'SLOT-V-Z-20', 20,
         pg_temp.uid('wh-manager-a@demo.local'), gen_random_uuid(), 500) is not null as ok \gset ok_
select wms.wms_register_storage_location(:'tenant_a', :'wh_a', 'BULK_STORAGE', 'SLOT-V-Z-30', 30,
         pg_temp.uid('wh-manager-a@demo.local'), gen_random_uuid()) is not null as ok \gset ok_
select wms.wms_register_storage_location(:'tenant_a', :'wh_a', 'FAR_CORNER', 'SLOT-V-Z-40', 40,
         pg_temp.uid('wh-manager-a@demo.local'), gen_random_uuid()) is not null as ok \gset ok_
select wms.wms_register_storage_location(:'tenant_a', :'wh_a', 'FAR_CORNER', 'SLOT-V-Z-99', 99,
         pg_temp.uid('wh-manager-a@demo.local'), gen_random_uuid()) is not null as ok \gset ok_

\echo ''
\echo '-- B2 duplicate location_code in the same warehouse -> INVALID'
select pg_temp.error_text(format(
  'select wms.wms_register_storage_location(%L, %L, %L, %L, 7, %L, gen_random_uuid())',
  :'tenant_a', :'wh_a', 'PACK_ADJACENT', 'SLOT-V-A-01',
  pg_temp.uid('wh-manager-a@demo.local'))) as duplicate_code;
select count(*) as rows_with_that_code from wms.storage_locations where location_code = 'SLOT-V-A-01';
\echo '-- expected: INVALID: location_code SLOT-V-A-01 already exists ... | 1'

\echo ''
\echo '-- B3 a role outside the registry set -> FORBIDDEN'
select pg_temp.act('inbound-a@demo.local');
select pg_temp.error_text(format(
  'select wms.wms_register_storage_location(%L, %L, %L, %L, 5, %L, gen_random_uuid())',
  :'tenant_a', :'wh_a', 'PACK_ADJACENT', 'SLOT-V-DENIED',
  pg_temp.uid('inbound-a@demo.local'))) as inbound_operator;
select pg_temp.act('process-agent-a@demo.local');
select pg_temp.error_text(format(
  'select wms.wms_register_storage_location(%L, %L, %L, %L, 5, %L, gen_random_uuid())',
  :'tenant_a', :'wh_a', 'PACK_ADJACENT', 'SLOT-V-DENIED',
  pg_temp.uid('process-agent-a@demo.local'))) as process_agent;
\echo '-- expected: FORBIDDEN twice (registry is master data — D6)'

\echo ''
\echo '-- B4 invalid rank / capacity are refused'
select pg_temp.act('wh-manager-a@demo.local');
select
  pg_temp.expect_error(format(
    'select wms.wms_register_storage_location(%L, %L, %L, %L, 0, %L, gen_random_uuid())',
    :'tenant_a', :'wh_a', 'Z', 'SLOT-V-BAD-RANK', pg_temp.uid('wh-manager-a@demo.local'))) as rank_zero,
  pg_temp.expect_error(format(
    'select wms.wms_register_storage_location(%L, %L, %L, %L, 5, %L, gen_random_uuid(), -1)',
    :'tenant_a', :'wh_a', 'Z', 'SLOT-V-BAD-CAP', pg_temp.uid('wh-manager-a@demo.local'))) as capacity_negative;
\echo '-- expected: INVALID | INVALID'

\echo ''
\echo '-- B5 idempotency: same key, one location'
\echo '--    (the count is a SEPARATE statement on purpose — a sub-SELECT beside'
\echo '--     the RPC call reads the pre-statement snapshot and reports 0.)'
select (wms.wms_register_storage_location(:'tenant_a', :'wh_a', 'PACK_ADJACENT', 'SLOT-V-IDEM', 4,
  pg_temp.uid('wh-manager-a@demo.local'), '99999999-0000-0000-0000-0000000000b5'))->>'document_id' as first_call;
select (wms.wms_register_storage_location(:'tenant_a', :'wh_a', 'PACK_ADJACENT', 'SLOT-V-IDEM', 4,
  pg_temp.uid('wh-manager-a@demo.local'), '99999999-0000-0000-0000-0000000000b5'))->>'document_id' as replayed_call;
select count(*) as rows_created from wms.storage_locations where location_code = 'SLOT-V-IDEM';
\echo '-- expected: the same uuid twice | 1'

\echo ''
\echo '-- B6 status toggle honours expected_version; a stale one is a CONFLICT'
select pg_temp.error_text(format(
  'select wms.wms_set_storage_location_status(%L, %L, %L, gen_random_uuid(), 99)',
  pg_temp.lid('SLOT-V-Z-99'), 'INACTIVE', pg_temp.uid('wh-manager-a@demo.local'))) as stale_version;
select
  r->>'status' as status, r->>'version' as version
from (select wms.wms_set_storage_location_status(
  pg_temp.lid('SLOT-V-Z-99'), 'INACTIVE',
  pg_temp.uid('wh-manager-a@demo.local'), gen_random_uuid(), 1, 'verify-B6') as r) s;
\echo '-- expected: CONFLICT: expected version 99 but found 1 | INACTIVE | 2'

\echo ''
\echo '-- B7 an INACTIVE location may not be assigned to (spec SHALL NOT)'
select pg_temp.error_text(format(
  'select wms.wms_assign_sku_location(%L, %L, %L, %L, %L, gen_random_uuid())',
  :'tenant_a', :'wh_a', pg_temp.pid('SLOT-V-P1'), pg_temp.lid('SLOT-V-Z-99'),
  pg_temp.uid('wh-manager-a@demo.local'))) as assign_to_inactive;
\echo '-- expected: INVALID: storage location SLOT-V-Z-99 is INACTIVE'

\echo ''
\echo '-- B8 declare P1 @ Z-20 (rank 20) and P4 @ A-02 (rank 2)'
select
  r->>'location_code' as code, r->>'assigned_reason' as reason,
  r->>'version' as version, r->>'warnings' as warnings
from (select wms.wms_assign_sku_location(
  :'tenant_a', :'wh_a', pg_temp.pid('SLOT-V-P1'), pg_temp.lid('SLOT-V-Z-20'),
  pg_temp.uid('wh-manager-a@demo.local'), gen_random_uuid(), 'verify-B8') as r) s;
select wms.wms_assign_sku_location(:'tenant_a', :'wh_a', pg_temp.pid('SLOT-V-P4'),
  pg_temp.lid('SLOT-V-A-02'), pg_temp.uid('wh-manager-a@demo.local'),
  gen_random_uuid()) is not null as ok \gset ok_
\echo '-- expected: SLOT-V-Z-20 | MANUAL_DECLARATION | 1 | [DECLARATION_NOT_RECONCILED_WITH_PUTAWAY]'
\echo '--   D1: the warning is on EVERY declaration. Nothing reconciles it against'
\echo '--   physical putaway, because wms_create_putaway_tasks has no location axis.'

\echo ''
\echo '-- B9 a second declaration for the same SKU -> INVALID (one live row)'
select pg_temp.error_text(format(
  'select wms.wms_assign_sku_location(%L, %L, %L, %L, %L, gen_random_uuid())',
  :'tenant_a', :'wh_a', pg_temp.pid('SLOT-V-P1'), pg_temp.lid('SLOT-V-A-03'),
  pg_temp.uid('wh-manager-a@demo.local'))) as duplicate_assignment;
\echo '-- expected: INVALID: product ... already has an active assignment ... use wms_reassign'

\echo ''
\echo '-- B10 reassign checks the version, then moves the SKU'
select pg_temp.error_text(format(
  'select wms.wms_reassign_sku_location(%L, %L, %L, gen_random_uuid(), 42)',
  pg_temp.aid('SLOT-V-P1'), pg_temp.lid('SLOT-V-Z-30'),
  pg_temp.uid('wh-manager-a@demo.local'))) as stale_version;
select
  r->>'location_code' as code, r->>'version' as version
from (select wms.wms_reassign_sku_location(
  pg_temp.aid('SLOT-V-P1'), pg_temp.lid('SLOT-V-Z-30'),
  pg_temp.uid('wh-manager-a@demo.local'), gen_random_uuid(), 1, 'verify-B10') as r) s;
-- put it back at Z-20 for the recommendation sections below
select wms.wms_reassign_sku_location(pg_temp.aid('SLOT-V-P1'), pg_temp.lid('SLOT-V-Z-20'),
  pg_temp.uid('wh-manager-a@demo.local'), gen_random_uuid(), 2) is not null as ok \gset ok_
\echo '-- expected: CONFLICT: expected version 42 but found 1 | SLOT-V-Z-30 | 2'

\echo ''
\echo '-- B11 class policies: A <= rank 5, C <= rank 40. B is left UNDEFINED on'
\echo '--     purpose so §F can show it being skipped rather than defaulted (D2).'
select
  r->>'velocity_class' as class, r->>'max_accessibility_rank' as max_rank,
  r->>'qualifying_location_count' as qualifying, r->>'version' as version
from (select wms.wms_register_slotting_class_policy(
  :'tenant_a', :'wh_a', 'A', 5,
  pg_temp.uid('wh-manager-a@demo.local'), gen_random_uuid(), 'verify-B11') as r) s;
select wms.wms_register_slotting_class_policy(:'tenant_a', :'wh_a', 'C', 40,
  pg_temp.uid('wh-manager-a@demo.local'), gen_random_uuid()) is not null as ok \gset ok_
\echo '-- expected: A | 5 | 4 | 1   (A-01, A-02, A-03, IDEM are ACTIVE at rank <= 5)'

\echo ''
\echo '-- B12 duplicate (warehouse, class) -> INVALID; update honours the version'
select pg_temp.error_text(format(
  'select wms.wms_register_slotting_class_policy(%L, %L, %L, 9, %L, gen_random_uuid())',
  :'tenant_a', :'wh_a', 'A', pg_temp.uid('wh-manager-a@demo.local'))) as duplicate_policy;
select
  r->>'max_accessibility_rank' as max_rank, r->>'version' as version, r->>'warnings' as warnings
from (select wms.wms_update_slotting_class_policy(
  (select id from wms.slotting_class_policies where warehouse_id = :'wh_a' and velocity_class = 'A'),
  6, pg_temp.uid('wh-manager-a@demo.local'), gen_random_uuid(), 1, 'verify-B12') as r) s;
-- back to 5
select wms.wms_update_slotting_class_policy(
  (select id from wms.slotting_class_policies where warehouse_id = :'wh_a' and velocity_class = 'A'),
  5, pg_temp.uid('wh-manager-a@demo.local'), gen_random_uuid(), 2) is not null as ok \gset ok_
\echo '-- expected: INVALID: a A class policy already exists ... | 6 | 2 | [REGENERATE_TO_APPLY]'

\echo ''
\echo '=============================================================='
\echo 'C. THE HONEST DEFAULT — velocity over the repository as it ships'
\echo '   (spec: "소비 이력이 전혀 없는 SKU는 등급 없이 명시적으로 제외된다")'
\echo '=============================================================='
\echo ''
\echo '-- C1 not one row in the whole ledger is a consumption signal'
select
  count(*) filter (where status = 'AVAILABLE' and qty_delta < 0) as negative_available_rows,
  count(*) filter (where qty_delta < 0) as negative_rows_any_status,
  count(*) as total_ledger_rows
from wms.stock_ledger_entries;
\echo '-- expected: 0 | (only the QC offsets written by _wms_finalize_disposition) | n'
\echo '--   The 0 is the whole premise: wms_receive writes +qty to QC, disposition'
\echo '--   writes -qty to QC and +qty to AVAILABLE/SCRAP. Nothing decrements'
\echo '--   AVAILABLE. Area 5 (wms.outbound_orders, 20260731) is implemented and'
\echo '--   reaches COMPLETED, but writes no ledger row at all — verified below.'

\echo ''
\echo '-- C2 area 5 really is ledger-silent (not just claimed to be)'
select count(*) as outbound_sourced_ledger_rows
from wms.stock_ledger_entries
where source_type in ('outbound_order', 'dispatch_sequence', 'pallet', 'simulation');
\echo '-- expected: 0'

\echo ''
\echo '-- C3 so the computation returns nothing, and SAYS it returned nothing'
select pg_temp.act('process-agent-a@demo.local');
select
  r->>'status' as status,
  r->>'candidate_product_count' as candidates,
  r->>'included_product_count' as included,
  r->>'skipped_no_data_count' as skipped_no_data,
  r->>'warnings' as warnings
from (select wms.wms_compute_sku_velocity(
  :'tenant_a', :'wh_a', current_date - 30, current_date,
  pg_temp.uid('process-agent-a@demo.local'), gen_random_uuid(), 'verify-C3') as r) s;
\echo '-- expected: NO_SIGNAL | 7 | 0 | 7 | [NO_CONSUMPTION_SIGNAL_IN_WINDOW]'
\echo '--   No SKU is quietly graded C. included + skipped = candidates, always.'

\echo ''
\echo '-- C4 and no snapshot rows were fabricated'
select count(*) as snapshots_created from wms.sku_velocity_snapshots;
\echo '-- expected: 0'

\echo ''
\echo '-- C5 D6 role gate on the analysis RPCs: PROCESS_AGENT yes, buyer no'
select pg_temp.act('buyer-a@demo.local');
select pg_temp.error_text(format(
  'select wms.wms_compute_sku_velocity(%L, %L, current_date - 30, current_date, %L, gen_random_uuid())',
  :'tenant_a', :'wh_a', pg_temp.uid('buyer-a@demo.local'))) as buyer;
\echo '-- expected: FORBIDDEN: role cannot compute SKU velocity'

\echo ''
\echo '-- C6 window validation'
select pg_temp.act('wh-manager-a@demo.local');
select
  pg_temp.expect_error(format(
    'select wms.wms_compute_sku_velocity(%L, %L, current_date, current_date, %L, gen_random_uuid())',
    :'tenant_a', :'wh_a', pg_temp.uid('wh-manager-a@demo.local'))) as start_equals_end,
  pg_temp.expect_error(format(
    'select wms.wms_compute_sku_velocity(%L, %L, current_date, current_date - 7, %L, gen_random_uuid())',
    :'tenant_a', :'wh_a', pg_temp.uid('wh-manager-a@demo.local'))) as end_before_start;
\echo '-- expected: INVALID | INVALID'

\echo ''
\echo '=============================================================='
\echo 'D. SYNTHETIC CONSUMPTION — standing in for a feature that does'
\echo '   not exist yet'
\echo '=============================================================='
\echo ''
\echo '-- The rows below are inserted DIRECTLY, as superuser, bypassing every'
\echo '-- RPC. No code path in this repository produces them (see §C1/§C2).'
\echo '-- They simulate what a future outbound-fulfilment RPC would write, and'
\echo '-- they exist for exactly one reason: without them the ABC arithmetic'
\echo '-- can never be exercised. source_type is tagged SLOT-V-synthetic-'
\echo '-- consumption so they are trivially identifiable and are deleted in §L.'
\echo ''
\echo '-- Quantities are chosen so the cumulative share lands EXACTLY on both'
\echo '-- cutoffs — the boundary is the interesting case (migration V5):'
\echo '--   P1  60  -> cum  60 =  60%  -> A'
\echo '--   P4  20  -> cum  80 =  80%  -> A   <- exactly 80, inclusive'
\echo '--   P2  15  -> cum  95 =  95%  -> B   <- exactly 95, inclusive'
\echo '--   P3   5  -> cum 100 = 100%  -> C'

insert into wms.stock_ledger_entries
  (tenant_id, warehouse_id, product_id, qty_delta, status, source_type, source_id, created_at)
select :'tenant_a', :'wh_a', pg_temp.pid(s.sku), -s.qty, 'AVAILABLE',
       'SLOT-V-synthetic-consumption', null,
       date_trunc('day', now()) - make_interval(days => s.days_ago) + interval '10 hours'
from (values
  ('SLOT-V-P1', 30, 5), ('SLOT-V-P1', 20, 4), ('SLOT-V-P1', 10, 3),  -- 60 over 3 events
  ('SLOT-V-P4', 12, 5), ('SLOT-V-P4',  8, 3),                        -- 20 over 2 events
  ('SLOT-V-P2', 15, 4),                                              -- 15 over 1 event
  ('SLOT-V-P3',  5, 3)                                               --  5 over 1 event
) as s(sku, qty, days_ago);

\echo ''
\echo '-- D1 the injected signal, as the ledger now sees it'
select p.sku, sum(-e.qty_delta) as outbound_qty, count(*) as events
from wms.stock_ledger_entries e join wms.products p on p.id = e.product_id
where e.source_type = 'SLOT-V-synthetic-consumption'
group by p.sku order by 2 desc;
\echo '-- expected: P1 60/3, P4 20/2, P2 15/1, P3 5/1  (total 100)'

\echo ''
\echo '=============================================================='
\echo 'E. ABC classification (spec: SKU 출하 속도 계산)'
\echo '=============================================================='

select pg_temp.act('process-agent-a@demo.local');

\echo '-- E1 compute over a window that contains the injected events'
select
  r->>'status' as status,
  r->>'candidate_product_count' as candidates,
  r->>'included_product_count' as included,
  r->>'skipped_no_data_count' as skipped_no_data,
  r->>'total_outbound_qty' as total_qty,
  r->>'class_counts' as class_counts,
  r->>'method' as method
from (select wms.wms_compute_sku_velocity(
  :'tenant_a', :'wh_a', current_date - 7, current_date - 1,
  pg_temp.uid('process-agent-a@demo.local'),
  '99999999-0000-0000-0000-0000000000e1', 'verify-E1') as r) s;
\echo '-- expected: COMPUTED | 7 | 4 | 3 | 100 | {A:2, B:1, C:1} | CUMULATIVE_SHARE_ABC_80_95'
\echo '--   skipped_no_data = 3 is the three seed SKUs (SKU-A-001..003) that have'
\echo '--   no consumption signal. spec.md scenario "일부 SKU만 소비 이력이 있으면'
\echo '--   나머지는 개별적으로 제외된다", verified with real numbers.'

\echo ''
\echo '-- E2 the grades themselves, with the cumulative share that produced them'
with b as (
  select (response->>'batch_id')::uuid as batch_id
  from wms.idempotency_records
  where command_name = 'wms_compute_sku_velocity'
    and idempotency_key = '99999999-0000-0000-0000-0000000000e1'
)
select
  p.sku, s.outbound_qty, s.outbound_event_count, s.velocity_class,
  round(100.0 * sum(s.outbound_qty) over (order by s.outbound_qty desc, s.product_id
        rows between unbounded preceding and current row)
        / sum(s.outbound_qty) over (), 2) as cumulative_share_pct
from wms.sku_velocity_snapshots s
join wms.products p on p.id = s.product_id
where s.batch_id = (select batch_id from b)
order by s.outbound_qty desc, s.product_id;
\echo '-- expected: P1 60/3 A @60.00 | P4 20/2 A @80.00 | P2 15/1 B @95.00 | P3 5/1 C @100.00'
\echo '--   V5: 80.00 is A and 95.00 is B — the boundaries are INCLUSIVE, and the'
\echo '--   comparison is integer (cum*100 <= total*80) so an exact 80% cannot'
\echo '--   slip past through a floating-point artefact.'

\echo ''
\echo '-- E3 every snapshot of one call shares one batch_id, and SKUs with no'
\echo '--    signal have NO ROW AT ALL (not a row with class C)'
select
  count(distinct batch_id) as distinct_batches,
  count(*) as snapshot_rows,
  (select count(*) from wms.products where tenant_id = :'tenant_a') as tenant_products
from wms.sku_velocity_snapshots;
\echo '-- expected: 1 | 4 | 7'

\echo ''
\echo '-- E4 only AVAILABLE-negative counts. QC/SCRAP negatives are ignored,'
\echo '--    as are positive AVAILABLE rows (Non-Goals: no mixed signals).'
insert into wms.stock_ledger_entries
  (tenant_id, warehouse_id, product_id, qty_delta, status, source_type, created_at)
values
  (:'tenant_a', :'wh_a', pg_temp.pid('SLOT-V-P3'), -999, 'QC',
   'SLOT-V-synthetic-consumption', date_trunc('day', now()) - interval '3 days'),
  (:'tenant_a', :'wh_a', pg_temp.pid('SLOT-V-P3'), -999, 'SCRAP',
   'SLOT-V-synthetic-consumption', date_trunc('day', now()) - interval '3 days'),
  (:'tenant_a', :'wh_a', pg_temp.pid('SLOT-V-P3'), 999, 'AVAILABLE',
   'SLOT-V-synthetic-consumption', date_trunc('day', now()) - interval '3 days');
select
  (r->>'total_outbound_qty') as total_qty,
  (r->>'included_product_count') as included
from (select wms.wms_compute_sku_velocity(
  :'tenant_a', :'wh_a', current_date - 7, current_date - 1,
  pg_temp.uid('process-agent-a@demo.local'), gen_random_uuid(), 'verify-E4') as r) s;
\echo '-- expected: 100 | 4  — unchanged, the three decoy rows contributed nothing'
delete from wms.stock_ledger_entries
where source_type = 'SLOT-V-synthetic-consumption' and abs(qty_delta) = 999;

\echo ''
\echo '-- E5 a window that misses the events is empty again — the honest default'
\echo '--    is a property of the WINDOW, not a one-off starting condition'
select
  r->>'included_product_count' as included, r->>'skipped_no_data_count' as skipped
from (select wms.wms_compute_sku_velocity(
  :'tenant_a', :'wh_a', current_date - 60, current_date - 50,
  pg_temp.uid('process-agent-a@demo.local'), gen_random_uuid(), 'verify-E5') as r) s;
\echo '-- expected: 0 | 7'

\echo ''
\echo '=============================================================='
\echo 'F. Recommendation generation (spec: 재배치 추천 생성)'
\echo '=============================================================='
\echo ''
\echo '-- Board state going in:'
\echo '--   P1  A-class, declared @ Z-20 (rank 20) — A policy caps at 5  -> RELOCATE'
\echo '--   P4  A-class, declared @ A-02 (rank  2) — already inside cap  -> skip'
\echo '--   P2  B-class, no B policy defined                             -> skip + report'
\echo '--   P3  C-class, no declaration at all                           -> UNASSIGNED'

\echo ''
\echo '-- F1 generate off the E1 batch'
with b as (
  select (response->>'batch_id')::uuid as batch_id
  from wms.idempotency_records
  where command_name = 'wms_compute_sku_velocity'
    and idempotency_key = '99999999-0000-0000-0000-0000000000e1'
)
select
  r->>'status' as status,
  r->>'snapshot_count' as snapshots,
  r->>'generated_count' as generated,
  r->>'skipped_no_policy_classes' as no_policy,
  r->>'skipped_already_optimal_count' as already_optimal,
  r->>'skipped_open_recommendation_count' as open_rec,
  r->>'skipped_no_target_location_count' as no_target,
  r->>'next_actions' as next_actions
from (select wms.wms_generate_slotting_recommendations(
  :'tenant_a', :'wh_a', (select batch_id from b),
  pg_temp.uid('process-agent-a@demo.local'),
  '99999999-0000-0000-0000-0000000000f1', 'verify-F1') as r) s;
\echo '-- expected: GENERATED | 4 | 2 | ["B"] | 1 | 0 | 0 | [review_slotting_recommendation]'
\echo '--   D2: class B is skipped and NAMED. No default cap is invented for a'
\echo '--   warehouse that never defined one — that would manufacture a false'
\echo '--   recommendation, and accessibility_rank has no absolute meaning.'
\echo '--   D6: the agent generated these, and the next action it is offered is'
\echo '--   a HUMAN review. It cannot take that step itself (§G).'

\echo ''
\echo '-- F2 what was actually written, through the overview view'
select sku, velocity_class, reason_code, status,
       current_location_code, current_accessibility_rank,
       recommended_location_code, recommended_accessibility_rank,
       max_accessibility_rank, accessibility_gain
from wms.slotting_recommendation_overview_v
order by sku;
\echo '-- expected:'
\echo '--   P1 | A | RELOCATE_UNDERSERVED      | PENDING | SLOT-V-Z-20 | 20 | SLOT-V-A-01 |  1 |  5 | 19'
\echo '--   P3 | C | UNASSIGNED_HIGH_VELOCITY  | PENDING | (null)      |    | SLOT-V-A-03 |  3 | 40 | (null)'
\echo '--   D5: P3 gets a recommendation despite having no declared location.'
\echo '--   Excluding it would leave the least-managed SKUs least-managed forever.'
\echo '--   V3: P3 is not sent to A-01 even though rank 1 also satisfies its cap —'
\echo '--   A-01 is already the target of P1''s open recommendation, so the pick'
\echo '--   moves on. One batch spreads across distinct targets.'

\echo ''
\echo '-- F3 no recommendation for the already-optimal SKU, none for the'
\echo '--    policy-less class'
select
  (select count(*) from wms.slotting_recommendations
    where product_id = pg_temp.pid('SLOT-V-P4')) as p4_already_optimal,
  (select count(*) from wms.slotting_recommendations
    where product_id = pg_temp.pid('SLOT-V-P2')) as p2_no_b_policy;
\echo '-- expected: 0 | 0'

\echo ''
\echo '-- F4 V4: re-running generation does not stack duplicates'
with b as (
  select (response->>'batch_id')::uuid as batch_id
  from wms.idempotency_records
  where command_name = 'wms_compute_sku_velocity'
    and idempotency_key = '99999999-0000-0000-0000-0000000000e1'
)
select
  r->>'generated_count' as generated,
  r->>'skipped_open_recommendation_count' as open_rec
from (select wms.wms_generate_slotting_recommendations(
  :'tenant_a', :'wh_a', (select batch_id from b),
  pg_temp.uid('process-agent-a@demo.local'), gen_random_uuid(), 'verify-F4') as r) s;
select count(*) as total_recommendations from wms.slotting_recommendations;
\echo '-- expected: 0 | 2 | 2   (a deliberate re-run, not an idempotency replay)'

\echo ''
\echo '-- F5 an unknown / cross-warehouse batch is refused'
select pg_temp.error_text(format(
  'select wms.wms_generate_slotting_recommendations(%L, %L, %L, %L, gen_random_uuid())',
  :'tenant_a', :'wh_a', gen_random_uuid(),
  pg_temp.uid('process-agent-a@demo.local'))) as unknown_batch;
\echo '-- expected: INVALID: velocity batch ... has no snapshot in this warehouse'

\echo ''
\echo '=============================================================='
\echo 'G. HITL review (spec: 재배치 추천 검토 / D6)'
\echo '=============================================================='
\echo ''
\echo '-- G1 THE CENTRAL ROLE RULE. The agent that generated the recommendation'
\echo '--    may not act on it. Approving means moving physical stock.'
select pg_temp.act('process-agent-a@demo.local');
select pg_temp.error_text(format(
  'select wms.wms_review_slotting_recommendation(%L, %L, %L, gen_random_uuid(), 1)',
  pg_temp.rid('SLOT-V-P1'), 'APPROVE', pg_temp.uid('process-agent-a@demo.local'))) as process_agent_approve;
select pg_temp.error_text(format(
  'select wms.wms_apply_slotting_recommendation(%L, %L, gen_random_uuid(), 1)',
  pg_temp.rid('SLOT-V-P1'), pg_temp.uid('process-agent-a@demo.local'))) as process_agent_apply;
\echo '-- expected: FORBIDDEN (review, "human decision") | FORBIDDEN (apply)'

\echo ''
\echo '-- G2 INBOUND_OPERATOR may APPLY but may not DECIDE'
select pg_temp.act('inbound-a@demo.local');
select pg_temp.error_text(format(
  'select wms.wms_review_slotting_recommendation(%L, %L, %L, gen_random_uuid(), 1)',
  pg_temp.rid('SLOT-V-P1'), 'APPROVE', pg_temp.uid('inbound-a@demo.local'))) as inbound_operator_review;
\echo '-- expected: FORBIDDEN: role cannot review slotting recommendations'
\echo '--   The split is deliberate: deciding that stock should move is the'
\echo '--   manager''s; recording that it did move is the floor''s (§H2).'

\echo ''
\echo '-- G3 the manager approves — version-checked'
select pg_temp.act('wh-manager-a@demo.local');
select pg_temp.error_text(format(
  'select wms.wms_review_slotting_recommendation(%L, %L, %L, gen_random_uuid(), 77)',
  pg_temp.rid('SLOT-V-P1'), 'APPROVE', pg_temp.uid('wh-manager-a@demo.local'))) as stale_version;
select
  r->>'status' as status, r->>'version' as version,
  (r->>'reviewed_by') = pg_temp.uid('wh-manager-a@demo.local')::text as reviewer_recorded,
  (r->>'reviewed_at') is not null as reviewed_at_set,
  r->>'warnings' as warnings, r->>'next_actions' as next_actions
from (select wms.wms_review_slotting_recommendation(
  pg_temp.rid('SLOT-V-P1'), 'APPROVE', pg_temp.uid('wh-manager-a@demo.local'),
  gen_random_uuid(), 1, null, 'verify-G3') as r) s;
\echo '-- expected: CONFLICT | APPROVED | 2 | t | t |'
\echo '--           [ASSIGNMENT_UNCHANGED_UNTIL_APPLIED] | [apply_slotting_recommendation]'
\echo '--   D7: approving is not moving. Nothing on any shelf has changed yet.'

\echo ''
\echo '-- G4 the assignment really is untouched by the approval'
select pg_temp.at('SLOT-V-P1') as p1_still_at;
\echo '-- expected: SLOT-V-Z-20'

\echo ''
\echo '-- G5 re-reviewing a non-PENDING recommendation -> INVALID'
select pg_temp.error_text(format(
  'select wms.wms_review_slotting_recommendation(%L, %L, %L, gen_random_uuid(), 2)',
  pg_temp.rid('SLOT-V-P1'), 'APPROVE', pg_temp.uid('wh-manager-a@demo.local'))) as double_review;
select pg_temp.expect_error(format(
  'select wms.wms_review_slotting_recommendation(%L, %L, %L, gen_random_uuid(), 1)',
  pg_temp.rid('SLOT-V-P3'), 'MAYBE', pg_temp.uid('wh-manager-a@demo.local'))) as bad_decision;
\echo '-- expected: INVALID: recommendation ... is not PENDING (status=APPROVED) | INVALID'

\echo ''
\echo '-- G6 reject the P3 recommendation, with a reason'
select
  r->>'status' as status, r->>'review_reason' as reason, r->>'next_actions' as next_actions
from (select wms.wms_review_slotting_recommendation(
  pg_temp.rid('SLOT-V-P3'), 'REJECT', pg_temp.uid('wh-manager-a@demo.local'),
  gen_random_uuid(), 1, '해당 통로는 이번 분기 공사 중', 'verify-G6') as r) s;
\echo '-- expected: REJECTED | 해당 통로는 이번 분기 공사 중 | [generate_slotting_recommendations]'

\echo ''
\echo '=============================================================='
\echo 'H. Applying an approved recommendation (spec: 승인된 추천 적용 / D7)'
\echo '=============================================================='

\echo '-- H1 a PENDING/REJECTED recommendation cannot be applied'
select pg_temp.error_text(format(
  'select wms.wms_apply_slotting_recommendation(%L, %L, gen_random_uuid(), 2)',
  pg_temp.rid('SLOT-V-P3'), pg_temp.uid('wh-manager-a@demo.local'))) as apply_rejected;
select pg_temp.at('SLOT-V-P3') as p3_location_after_failed_apply;
\echo '-- expected: INVALID: recommendation ... is not APPROVED (status=REJECTED) | (null)'

\echo ''
\echo '-- H2 the floor applies the approved move (INBOUND_OPERATOR is allowed'
\echo '--    here — recording that the move HAPPENED is their knowledge)'
select pg_temp.act('inbound-a@demo.local');
select
  r->>'status' as status,
  r->>'location_code' as moved_to,
  r->>'assigned_reason' as assigned_reason,
  r->>'assignment_created' as created_new,
  r->>'assignment_version' as assignment_version,
  (r->>'applied_at') is not null as applied_at_set,
  r->>'warnings' as warnings
from (select wms.wms_apply_slotting_recommendation(
  pg_temp.rid('SLOT-V-P1'), pg_temp.uid('inbound-a@demo.local'),
  gen_random_uuid(), 2, 'verify-H2') as r) s;
\echo '-- expected: APPLIED | SLOT-V-A-01 | SLOTTING_RECOMMENDATION | false | 4 | t |'
\echo '--           [RECORD_ONLY_NO_PHYSICAL_MOVE_VERIFIED]'
\echo '--   Non-Goals, stated on every application: the RECORD moved. Nobody'
\echo '--   checked the shelf, and this contract cannot.'

\echo ''
\echo '-- H3 the assignment really did move, and remembers why'
select
  pg_temp.at('SLOT-V-P1') as p1_now_at,
  (select l.accessibility_rank from wms.sku_location_assignments a
     join wms.storage_locations l on l.id = a.location_id
    where a.product_id = pg_temp.pid('SLOT-V-P1')) as new_rank,
  (select a.assigned_reason from wms.sku_location_assignments a
    where a.product_id = pg_temp.pid('SLOT-V-P1')) as reason,
  (select a.source_recommendation_id = pg_temp.rid('SLOT-V-P1')
     from wms.sku_location_assignments a
    where a.product_id = pg_temp.pid('SLOT-V-P1')) as traceable_to_recommendation;
\echo '-- expected: SLOT-V-A-01 | 1 | SLOTTING_RECOMMENDATION | t   (rank 20 -> 1)'

\echo ''
\echo '-- H4 applying twice is refused (status is no longer APPROVED)'
select pg_temp.error_text(format(
  'select wms.wms_apply_slotting_recommendation(%L, %L, gen_random_uuid(), 3)',
  pg_temp.rid('SLOT-V-P1'), pg_temp.uid('inbound-a@demo.local'))) as double_apply;
\echo '-- expected: INVALID: recommendation ... is not APPROVED (status=APPLIED)'

\echo ''
\echo '-- H5 D5''s other half — applying an UNASSIGNED recommendation CREATES the'
\echo '--    assignment. P3''s first recommendation was rejected in G6, so'
\echo '--    regeneration is now allowed to produce a fresh one (V4).'
select pg_temp.act('wh-manager-a@demo.local');
with b as (
  select (response->>'batch_id')::uuid as batch_id
  from wms.idempotency_records
  where command_name = 'wms_compute_sku_velocity'
    and idempotency_key = '99999999-0000-0000-0000-0000000000e1'
)
select
  r->>'generated_count' as generated,
  r->>'skipped_already_optimal_count' as already_optimal
from (select wms.wms_generate_slotting_recommendations(
  :'tenant_a', :'wh_a', (select batch_id from b),
  pg_temp.uid('wh-manager-a@demo.local'), gen_random_uuid(), 'verify-H5') as r) s;
\echo '-- expected: 1 | 2   (P1 is now inside its cap too, so only P3 regenerates)'

select wms.wms_review_slotting_recommendation(pg_temp.rid('SLOT-V-P3'), 'APPROVE',
  pg_temp.uid('wh-manager-a@demo.local'), gen_random_uuid(), 1) is not null as ok \gset ok_
select
  r->>'assignment_created' as created_new,
  r->>'assigned_reason' as assigned_reason,
  r->>'location_code' as location_code,
  r->>'assignment_version' as assignment_version
from (select wms.wms_apply_slotting_recommendation(
  pg_temp.rid('SLOT-V-P3'), pg_temp.uid('wh-manager-a@demo.local'),
  gen_random_uuid(), 2, 'verify-H5b') as r) s;
\echo '-- expected: true | SLOTTING_RECOMMENDATION | SLOT-V-A-03 | 1'
\echo '--   version 1 = a brand-new assignment row, not an update.'

\echo ''
\echo '-- H6 a target deactivated between approval and application is refused'
\echo '--    (the shelf stopped being usable while the paperwork sat)'
select wms.wms_register_storage_location(:'tenant_a', :'wh_a', 'PACK_ADJACENT', 'SLOT-V-A-04', 4,
  pg_temp.uid('wh-manager-a@demo.local'), gen_random_uuid()) is not null as ok \gset ok_
select wms.wms_reassign_sku_location(pg_temp.aid('SLOT-V-P4'), pg_temp.lid('SLOT-V-Z-30'),
  pg_temp.uid('wh-manager-a@demo.local'), gen_random_uuid(), pg_temp.aver('SLOT-V-P4')) is not null as ok \gset ok_
with b as (
  select (response->>'batch_id')::uuid as batch_id
  from wms.idempotency_records
  where command_name = 'wms_compute_sku_velocity'
    and idempotency_key = '99999999-0000-0000-0000-0000000000e1'
)
select (wms.wms_generate_slotting_recommendations(:'tenant_a', :'wh_a', (select batch_id from b),
  pg_temp.uid('wh-manager-a@demo.local'), gen_random_uuid()))->>'generated_count' as generated_for_p4;
select wms.wms_review_slotting_recommendation(pg_temp.rid('SLOT-V-P4'), 'APPROVE',
  pg_temp.uid('wh-manager-a@demo.local'), gen_random_uuid(), 1) is not null as ok \gset ok_
-- deactivate whatever P4 was pointed at
select wms.wms_set_storage_location_status(
  (select recommended_location_id from wms.slotting_recommendations where id = pg_temp.rid('SLOT-V-P4')),
  'INACTIVE', pg_temp.uid('wh-manager-a@demo.local'), gen_random_uuid(),
  (select l.version from wms.storage_locations l
    where l.id = (select recommended_location_id from wms.slotting_recommendations
                   where id = pg_temp.rid('SLOT-V-P4')))) is not null as ok \gset ok_
select pg_temp.error_text(format(
  'select wms.wms_apply_slotting_recommendation(%L, %L, gen_random_uuid(), 2)',
  pg_temp.rid('SLOT-V-P4'), pg_temp.uid('wh-manager-a@demo.local'))) as target_went_inactive;
select pg_temp.at('SLOT-V-P4') as p4_unchanged;
\echo '-- expected: 1 | INVALID: storage location ... is INACTIVE | SLOT-V-Z-30'

\echo ''
\echo '=============================================================='
\echo 'I. Audit trail (spec: 감사 추적)'
\echo '=============================================================='

\echo '-- I1 every write RPC left an event with an actor'
select command, count(*) as events, count(*) filter (where actor_id is not null) as with_actor
from wms.audit_events
where command in ('wms_register_storage_location', 'wms_set_storage_location_status',
                  'wms_assign_sku_location', 'wms_reassign_sku_location',
                  'wms_register_slotting_class_policy', 'wms_update_slotting_class_policy',
                  'wms_compute_sku_velocity', 'wms_generate_slotting_recommendations',
                  'wms_review_slotting_recommendation', 'wms_apply_slotting_recommendation')
group by command order by command;
\echo '-- expected: all 10 commands present, events = with_actor on every row'

\echo ''
\echo '-- I2 the approval is auditable end to end (spec''s worked scenario)'
select
  command,
  before->>'status' as before_status,
  after->>'status' as after_status,
  actor_id = pg_temp.uid('wh-manager-a@demo.local') as by_the_manager
from wms.audit_events
where command = 'wms_review_slotting_recommendation'
  and entity_id = pg_temp.rid('SLOT-V-P1')
order by created_at;
\echo '-- expected: PENDING -> APPROVED, by_the_manager = t'

\echo ''
\echo '-- I3 the application audited BOTH the recommendation and the assignment'
select entity_type,
       coalesce(before->>'status', 'n/a') as before_status,
       coalesce(after->>'status', 'n/a')  as after_status,
       (select l.location_code from wms.storage_locations l
         where l.id::text = before->>'location_id')  as assignment_was_at,
       (select l.location_code from wms.storage_locations l
         where l.id::text = after->>'location_id')   as assignment_now_at
from wms.audit_events
where command = 'wms_apply_slotting_recommendation'
  and (entity_id = pg_temp.rid('SLOT-V-P1') or entity_id = pg_temp.aid('SLOT-V-P1'))
order by entity_type;
\echo '-- expected: sku_location_assignment  n/a -> n/a, SLOT-V-Z-20 -> SLOT-V-A-01'
\echo '--           slotting_recommendation  APPROVED -> APPLIED'
\echo '--   D1: the previous placement lives here, in the audit log. There is no'
\echo '--   separate assignment-history table by design — this row IS the history.'

\echo ''
\echo '=============================================================='
\echo 'J. Cross-tenant / warehouse scope (spec: 테넌트·창고 단위 접근 통제)'
\echo '=============================================================='

\echo '-- J1 tenant B''s admin cannot drive tenant A''s warehouse through any RPC'
select pg_temp.act('admin-b@demo.local');
select
  pg_temp.expect_error(format(
    'select wms.wms_register_storage_location(%L, %L, %L, %L, 1, %L, gen_random_uuid())',
    :'tenant_a', :'wh_a', 'X', 'SLOT-V-CROSS', pg_temp.uid('admin-b@demo.local'))) as register,
  pg_temp.expect_error(format(
    'select wms.wms_compute_sku_velocity(%L, %L, current_date - 7, current_date - 1, %L, gen_random_uuid())',
    :'tenant_a', :'wh_a', pg_temp.uid('admin-b@demo.local'))) as compute,
  pg_temp.expect_error(format(
    'select wms.wms_review_slotting_recommendation(%L, %L, %L, gen_random_uuid(), 1)',
    pg_temp.rid('SLOT-V-P4'), 'REJECT', pg_temp.uid('admin-b@demo.local'))) as review;
\echo '-- expected: FORBIDDEN | FORBIDDEN | FORBIDDEN'

\echo ''
\echo '=============================================================='
\echo 'K. RLS at the table level (session role dropped to `authenticated`,'
\echo '   where the policy is the ONLY guard)'
\echo '=============================================================='

set role authenticated;

\echo '-- K1 a tenant A member sees tenant A rows'
select pg_temp.act('inbound-a@demo.local');
select
  (select count(*) from wms.storage_locations) as locations,
  (select count(*) from wms.sku_location_assignments) as assignments,
  (select count(*) from wms.slotting_class_policies) as policies,
  (select count(*) from wms.sku_velocity_snapshots) as snapshots,
  (select count(*) from wms.slotting_recommendations) as recommendations,
  (select count(*) from wms.slotting_recommendation_overview_v) as overview_rows;
\echo '-- expected: non-zero across the board'

\echo ''
\echo '-- K2 tenant B''s admin sees NONE of it'
select pg_temp.act('admin-b@demo.local');
select
  (select count(*) from wms.storage_locations) as locations,
  (select count(*) from wms.sku_location_assignments) as assignments,
  (select count(*) from wms.slotting_class_policies) as policies,
  (select count(*) from wms.sku_velocity_snapshots) as snapshots,
  (select count(*) from wms.slotting_recommendations) as recommendations,
  (select count(*) from wms.slotting_recommendation_overview_v) as overview_rows;
\echo '-- expected: 0 across the board (the view is security_invoker, so it'
\echo '--           inherits the base-table policies rather than bypassing them)'

\echo ''
\echo '-- K3 no write privilege was granted to authenticated (tasks.md 2.2)'
select pg_temp.act('admin-a@demo.local');
select
  pg_temp.expect_error('insert into wms.storage_locations (tenant_id, warehouse_id, zone_code, location_code, accessibility_rank) values (''10000000-0000-0000-0000-00000000000a'', ''20000000-0000-0000-0000-00000000000a'', ''X'', ''SLOT-V-DIRECT'', 1)') as direct_insert,
  pg_temp.expect_error('update wms.slotting_recommendations set status = ''APPROVED''') as direct_update,
  pg_temp.expect_error('delete from wms.sku_location_assignments') as direct_delete;
\echo '-- expected: ERROR (permission denied) three times — not "0 rows"'

\echo ''
\echo '-- K4 the grant table itself'
reset role;
select table_name, string_agg(privilege_type, ',' order by privilege_type) as privs
from information_schema.role_table_grants
where table_schema = 'wms' and grantee = 'authenticated'
  and table_name in ('storage_locations', 'sku_location_assignments',
                     'slotting_class_policies', 'sku_velocity_snapshots',
                     'slotting_recommendations', 'slotting_recommendation_overview_v')
group by table_name order by table_name;
\echo '-- expected: SELECT only, on all six'

\echo ''
\echo '=============================================================='
\echo 'L. Teardown'
\echo '=============================================================='

reset role;
select set_config('request.jwt.claims', null, false) is not null as cleared;

delete from wms.stock_ledger_entries where source_type = 'SLOT-V-synthetic-consumption';
delete from wms.audit_events where entity_type in
  ('storage_location', 'sku_location_assignment', 'slotting_class_policy',
   'sku_velocity_batch', 'slotting_recommendation');
delete from wms.idempotency_records where command_name in (
  'wms_register_storage_location', 'wms_set_storage_location_status',
  'wms_assign_sku_location', 'wms_reassign_sku_location',
  'wms_register_slotting_class_policy', 'wms_update_slotting_class_policy',
  'wms_compute_sku_velocity', 'wms_generate_slotting_recommendations',
  'wms_review_slotting_recommendation', 'wms_apply_slotting_recommendation');
delete from wms.sku_location_assignments;
delete from wms.slotting_recommendations;
delete from wms.sku_velocity_snapshots;
delete from wms.slotting_class_policies;
delete from wms.storage_locations;
delete from wms.products where sku like 'SLOT-V-%';

select
  (select count(*) from wms.storage_locations) as locations_left,
  (select count(*) from wms.sku_velocity_snapshots) as snapshots_left,
  (select count(*) from wms.slotting_recommendations) as recommendations_left,
  (select count(*) from wms.stock_ledger_entries
    where source_type = 'SLOT-V-synthetic-consumption') as synthetic_ledger_rows_left;
\echo '-- expected: 0 | 0 | 0 | 0  — the synthetic consumption signal is gone too'
\echo ''
\echo '=============================================================='
\echo 'done.'
\echo '=============================================================='
