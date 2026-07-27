\set QUIET on
\pset pager off
\pset format aligned
\set ON_ERROR_STOP on

-- ============================================================
-- wms_yard-dock-scheduling — psql verification suite
--
--   docker exec -i supabase_db_process-gpt-sample-app-wms \
--     psql -U postgres -d postgres -f - < verify.sql
--
-- Self-contained: creates its own DOCK-V-* fixtures, exercises every RPC and
-- every guard in specs/wms_yard-dock-scheduling/spec.md, then cleans up. Safe
-- to re-run without a db reset.
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

create or replace function pg_temp.uid(p_email text) returns uuid
language sql as $fn$ select id from auth.users where email = p_email $fn$;

-- Calls a statement and returns the SQLERRM prefix class, so an expected
-- failure is data instead of a crashed script.
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

-- ------------------------------------------------------------
-- Fixtures. A PO is needed because INBOUND appointments require one; it is
-- inserted directly (superuser, no RLS) because the procurement flow is not
-- what is under test here.
-- ------------------------------------------------------------
delete from wms.dock_appointments a using wms.docks d
  where a.dock_id = d.id and d.code like 'DOCK-V-%';
delete from wms.docks where code like 'DOCK-V-%';
delete from wms.receipts where po_id in (select id from wms.purchase_orders where reason = 'DOCK-V-FIXTURE');
delete from wms.purchase_orders where reason = 'DOCK-V-FIXTURE';
delete from wms.idempotency_records where command_name like 'wms_%dock%'
   or command_name in ('wms_check_in_vehicle', 'wms_dock_vehicle', 'wms_depart_vehicle');

insert into wms.purchase_orders (id, tenant_id, warehouse_id, product_id, qty, status, reason)
select '40000000-0000-0000-0000-0000000000a1', :'tenant_a', :'wh_a', p.id, 10, 'CONFIRMED_PO', 'DOCK-V-FIXTURE'
from wms.products p where p.tenant_id = :'tenant_a' and p.sku = 'SKU-A-001';
insert into wms.purchase_orders (id, tenant_id, warehouse_id, product_id, qty, status, reason)
select '40000000-0000-0000-0000-0000000000a2', :'tenant_a', :'wh_a', p.id, 10, 'CONFIRMED_PO', 'DOCK-V-FIXTURE'
from wms.products p where p.tenant_id = :'tenant_a' and p.sku = 'SKU-A-002';
-- a PO in the OTHER tenant, for the cross-tenant checks
insert into wms.purchase_orders (id, tenant_id, warehouse_id, product_id, qty, status, reason)
select '40000000-0000-0000-0000-0000000000b1', :'tenant_b', :'wh_b', p.id, 10, 'CONFIRMED_PO', 'DOCK-V-FIXTURE'
from wms.products p where p.tenant_id = :'tenant_b' and p.sku = 'SKU-B-001';
-- receipts for the wms_register_arrival independence checks
insert into wms.receipts (tenant_id, warehouse_id, po_id, product_id, expected_qty, status)
select tenant_id, warehouse_id, id, product_id, qty, 'EXPECTED'
from wms.purchase_orders where reason = 'DOCK-V-FIXTURE' and tenant_id = :'tenant_a';

\set QUIET off
\echo ''
\echo '=============================================================='
\echo 'A. Dock registry — register, duplicate code, role/scope guards'
\echo '=============================================================='

select pg_temp.act('wh-manager-a@demo.local');
select
  (wms.wms_register_dock(:'tenant_a', :'wh_a', 'DOCK-V-01', '검증 하역장 1',
     pg_temp.uid('wh-manager-a@demo.local'), gen_random_uuid(), 'verify-A'))->>'status' as dock1_status,
  (wms.wms_register_dock(:'tenant_a', :'wh_a', 'DOCK-V-02', '검증 하역장 2',
     pg_temp.uid('wh-manager-a@demo.local'), gen_random_uuid(), 'verify-A'))->>'version' as dock2_version;

\echo '-- expected: AVAILABLE | 1   (spec: "등록 직후 도크 상태는 AVAILABLE")'

\echo ''
\echo '-- A2 duplicate code in the same warehouse -> INVALID'
select pg_temp.error_text(format(
  'select wms.wms_register_dock(%L, %L, %L, %L, %L, gen_random_uuid(), null)',
  :'tenant_a', :'wh_a', 'DOCK-V-01', 'dup', pg_temp.uid('wh-manager-a@demo.local'))) as dup_code;

\echo ''
\echo '-- A3 INBOUND_OPERATOR has no registry rights -> FORBIDDEN'
select pg_temp.act('inbound-a@demo.local');
select pg_temp.error_text(format(
  'select wms.wms_register_dock(%L, %L, %L, %L, %L, gen_random_uuid(), null)',
  :'tenant_a', :'wh_a', 'DOCK-V-99', 'nope', pg_temp.uid('inbound-a@demo.local'))) as wrong_role;

\echo ''
\echo '-- A4 tenant A admin registering into tenant B warehouse -> FORBIDDEN'
select pg_temp.act('admin-a@demo.local');
select pg_temp.error_text(format(
  'select wms.wms_register_dock(%L, %L, %L, %L, %L, gen_random_uuid(), null)',
  :'tenant_b', :'wh_b', 'DOCK-V-X', 'cross tenant', pg_temp.uid('admin-a@demo.local'))) as cross_tenant;

\echo ''
\echo '=============================================================='
\echo 'B. Appointment creation guards'
\echo '=============================================================='

select pg_temp.act('inbound-a@demo.local');

\echo '-- B1 happy path: INBOUND appointment against a real PO'
select
  (wms.wms_schedule_dock_appointment(
     (select id from wms.docks where code = 'DOCK-V-01'),
     '2026-08-01T09:00:00Z', '2026-08-01T10:00:00Z',
     pg_temp.uid('inbound-a@demo.local'), gen_random_uuid(),
     'INBOUND', '40000000-0000-0000-0000-0000000000a1', '한빛운수', '12가3456',
     null, null, 'verify-B'))->>'status' as appt_status;
\echo '-- expected: SCHEDULED'

\echo ''
\echo '-- B2 inverted window -> INVALID   B3 INBOUND without po_id -> INVALID'
select
  pg_temp.expect_error(format(
    'select wms.wms_schedule_dock_appointment(%L, %L, %L, %L, gen_random_uuid(), %L, %L)',
    (select id from wms.docks where code='DOCK-V-02'),
    '2026-08-01T10:00:00Z', '2026-08-01T09:00:00Z',
    pg_temp.uid('inbound-a@demo.local'), 'INBOUND', '40000000-0000-0000-0000-0000000000a1')) as inverted_window,
  pg_temp.expect_error(format(
    'select wms.wms_schedule_dock_appointment(%L, %L, %L, %L, gen_random_uuid(), %L, null)',
    (select id from wms.docks where code='DOCK-V-02'),
    '2026-08-01T09:00:00Z', '2026-08-01T10:00:00Z',
    pg_temp.uid('inbound-a@demo.local'), 'INBOUND')) as inbound_without_po;

\echo ''
\echo '-- B4 PO from another warehouse -> INVALID'
select pg_temp.error_text(format(
  'select wms.wms_schedule_dock_appointment(%L, %L, %L, %L, gen_random_uuid(), %L, %L)',
  (select id from wms.docks where code='DOCK-V-02'),
  '2026-08-01T09:00:00Z', '2026-08-01T10:00:00Z',
  pg_temp.uid('inbound-a@demo.local'), 'INBOUND', '40000000-0000-0000-0000-0000000000b1')) as foreign_po;

\echo ''
\echo '-- B5 CLOSED dock cannot be booked'
select pg_temp.act('wh-manager-a@demo.local');
select (wms.wms_set_dock_status((select id from wms.docks where code='DOCK-V-02'), 'CLOSED',
          pg_temp.uid('wh-manager-a@demo.local'), gen_random_uuid(),
          (select version from wms.docks where code='DOCK-V-02'), '정비', null))->>'status' as dock2_now;
select pg_temp.act('inbound-a@demo.local');
select pg_temp.error_text(format(
  'select wms.wms_schedule_dock_appointment(%L, %L, %L, %L, gen_random_uuid(), %L, %L)',
  (select id from wms.docks where code='DOCK-V-02'),
  '2026-08-01T09:00:00Z', '2026-08-01T10:00:00Z',
  pg_temp.uid('inbound-a@demo.local'), 'INBOUND', '40000000-0000-0000-0000-0000000000a1')) as closed_dock;
-- reopen for the rest of the suite
select pg_temp.act('wh-manager-a@demo.local');
select (wms.wms_set_dock_status((select id from wms.docks where code='DOCK-V-02'), 'AVAILABLE',
          pg_temp.uid('wh-manager-a@demo.local'), gen_random_uuid(),
          (select version from wms.docks where code='DOCK-V-02'), null, null))->>'status' as dock2_reopened;

\echo ''
\echo '-- B6 OUTBOUND appointment (D3-AMENDED: implemented, not deferred)'
\echo '--    po_id must be null; linked_entity_type=outbound_order is scope-checked'
insert into wms.outbound_orders (id, tenant_id, warehouse_id, order_number, store_code, product_id, qty)
select '50000000-0000-0000-0000-0000000000a1', :'tenant_a', :'wh_a', 'DOCK-V-OO-1', 'STORE-V1', p.id, 5
from wms.products p where p.tenant_id = :'tenant_a' and p.sku = 'SKU-A-001'
on conflict (id) do nothing;
select pg_temp.act('inbound-a@demo.local');
select
  (wms.wms_schedule_dock_appointment(
     (select id from wms.docks where code='DOCK-V-02'),
     '2026-08-01T13:00:00Z', '2026-08-01T14:00:00Z',
     pg_temp.uid('inbound-a@demo.local'), gen_random_uuid(),
     'OUTBOUND', null, '한빛운수', '99하9999',
     'outbound_order', '50000000-0000-0000-0000-0000000000a1', 'verify-B6'))->>'appointment_type' as outbound_ok,
  pg_temp.expect_error(format(
    'select wms.wms_schedule_dock_appointment(%L, %L, %L, %L, gen_random_uuid(), %L, %L)',
    (select id from wms.docks where code='DOCK-V-02'),
    '2026-08-01T15:00:00Z', '2026-08-01T16:00:00Z',
    pg_temp.uid('inbound-a@demo.local'), 'OUTBOUND', '40000000-0000-0000-0000-0000000000a1')) as outbound_with_po,
  pg_temp.expect_error(format(
    'select wms.wms_schedule_dock_appointment(%L, %L, %L, %L, gen_random_uuid(), %L, null, null, null, %L, %L)',
    (select id from wms.docks where code='DOCK-V-02'),
    '2026-08-01T15:00:00Z', '2026-08-01T16:00:00Z',
    pg_temp.uid('inbound-a@demo.local'), 'OUTBOUND',
    'outbound_order', '50000000-0000-0000-0000-00000000ffff')) as unknown_outbound_order;
\echo '-- expected: OUTBOUND | INVALID | INVALID'

\echo ''
\echo '=============================================================='
\echo 'C. Double booking (D1) — the exclusion constraint'
\echo '=============================================================='

\echo '-- C1 overlapping window on the same dock -> CONFLICT (via the RPC)'
select pg_temp.error_text(format(
  'select wms.wms_schedule_dock_appointment(%L, %L, %L, %L, gen_random_uuid(), %L, %L)',
  (select id from wms.docks where code='DOCK-V-01'),
  '2026-08-01T09:30:00Z', '2026-08-01T10:30:00Z',
  pg_temp.uid('inbound-a@demo.local'), 'INBOUND', '40000000-0000-0000-0000-0000000000a2')) as overlap;

\echo ''
\echo '-- C2 abutting window 10:00-11:00 is NOT an overlap (half-open range)'
select (wms.wms_schedule_dock_appointment(
     (select id from wms.docks where code='DOCK-V-01'),
     '2026-08-01T10:00:00Z', '2026-08-01T11:00:00Z',
     pg_temp.uid('inbound-a@demo.local'), gen_random_uuid(),
     'INBOUND', '40000000-0000-0000-0000-0000000000a2', null, null, null, null, 'verify-C2'))->>'status' as abutting;
\echo '-- expected: SCHEDULED'

\echo ''
\echo '-- C3 the DB refuses the overlap even when the RPC is bypassed entirely'
\echo '--    (superuser INSERT straight into the table — storage-engine level)'
select pg_temp.error_text(format($q$
  insert into wms.dock_appointments (tenant_id, warehouse_id, dock_id, appointment_type, po_id,
    scheduled_start, scheduled_end, status)
  values (%L, %L, %L, 'INBOUND', %L, '2026-08-01T09:15:00Z', '2026-08-01T09:45:00Z', 'SCHEDULED')$q$,
  :'tenant_a', :'wh_a', (select id from wms.docks where code='DOCK-V-01'),
  '40000000-0000-0000-0000-0000000000a2')) as raw_insert_blocked;
\echo '-- expected: conflicting key value violates exclusion constraint ...'

\echo ''
\echo '-- C4 the same INSERT succeeds once the sitting appointment is CANCELLED,'
\echo '--    because the exclusion predicate only covers SCHEDULED/CHECKED_IN/AT_DOCK'
select (wms.wms_cancel_dock_appointment(
    (select id from wms.dock_appointments where dock_id=(select id from wms.docks where code='DOCK-V-01')
       and scheduled_start='2026-08-01T09:00:00Z'),
    pg_temp.uid('inbound-a@demo.local'), gen_random_uuid(),
    (select version from wms.dock_appointments where dock_id=(select id from wms.docks where code='DOCK-V-01')
       and scheduled_start='2026-08-01T09:00:00Z'),
    '공급사 일정 변경', 'verify-C4'))->>'status' as cancelled;
select (wms.wms_schedule_dock_appointment(
     (select id from wms.docks where code='DOCK-V-01'),
     '2026-08-01T09:00:00Z', '2026-08-01T10:00:00Z',
     pg_temp.uid('inbound-a@demo.local'), gen_random_uuid(),
     'INBOUND', '40000000-0000-0000-0000-0000000000a1', '다시운수', '34나5678', null, null, 'verify-C4'))->>'status'
  as rebooked_same_slot;
\echo '-- expected: CANCELLED | SCHEDULED'

\echo ''
\echo '=============================================================='
\echo 'D. Vehicle lifecycle + derived dock status (D4)'
\echo '=============================================================='

\echo '-- D1 SCHEDULED -> CHECKED_IN leaves the dock alone'
select
  (wms.wms_check_in_vehicle(
    (select id from wms.dock_appointments where carrier_name='다시운수'),
    pg_temp.uid('inbound-a@demo.local'), gen_random_uuid(),
    (select version from wms.dock_appointments where carrier_name='다시운수'),
    null, '34나5678', 'verify-D'))->>'status' as appt,
  (select status from wms.docks where code='DOCK-V-01') as dock_after_checkin;
\echo '-- expected: CHECKED_IN | AVAILABLE'

\echo ''
\echo '-- D2 CHECKED_IN -> AT_DOCK takes the dock to OCCUPIED'
-- NOTE: the follow-up read is a separate statement on purpose. A sub-SELECT in
-- the same statement as the RPC call would read the pre-statement snapshot and
-- report the OLD status — a harness artifact, not a contract behaviour.
select
  (wms.wms_dock_vehicle(
    (select id from wms.dock_appointments where carrier_name='다시운수'),
    pg_temp.uid('inbound-a@demo.local'), gen_random_uuid(),
    (select version from wms.dock_appointments where carrier_name='다시운수'),
    'verify-D'))->>'dock_status' as dock_status;
select status as appt_status from wms.dock_appointments where carrier_name='다시운수';
\echo '-- expected: OCCUPIED | AT_DOCK'

\echo ''
\echo '-- D3 an OCCUPIED dock cannot be CLOSED, and cannot take a second truck'
select pg_temp.act('wh-manager-a@demo.local');
select pg_temp.expect_error(format(
  'select wms.wms_set_dock_status(%L, %L, %L, gen_random_uuid(), %s, null, null)',
  (select id from wms.docks where code='DOCK-V-01'), 'CLOSED',
  pg_temp.uid('wh-manager-a@demo.local'),
  (select version from wms.docks where code='DOCK-V-01'))) as close_occupied;
select pg_temp.act('inbound-a@demo.local');
select (wms.wms_check_in_vehicle(
    (select id from wms.dock_appointments where dock_id=(select id from wms.docks where code='DOCK-V-01')
       and scheduled_start='2026-08-01T10:00:00Z'),
    pg_temp.uid('inbound-a@demo.local'), gen_random_uuid(),
    (select version from wms.dock_appointments where dock_id=(select id from wms.docks where code='DOCK-V-01')
       and scheduled_start='2026-08-01T10:00:00Z'), null, '56다7890', null))->>'status' as second_checked_in;
select pg_temp.expect_error(format(
  'select wms.wms_dock_vehicle(%L, %L, gen_random_uuid(), %s, null)',
  (select id from wms.dock_appointments where vehicle_plate_no='56다7890'),
  pg_temp.uid('inbound-a@demo.local'),
  (select version from wms.dock_appointments where vehicle_plate_no='56다7890'))) as dock_already_occupied;
\echo '-- expected: INVALID | CHECKED_IN | INVALID'

\echo ''
\echo '-- D4 out-of-order transitions are refused'
select
  pg_temp.expect_error(format(
    'select wms.wms_depart_vehicle(%L, %L, gen_random_uuid(), %s, null)',
    (select id from wms.dock_appointments where vehicle_plate_no='56다7890'),
    pg_temp.uid('inbound-a@demo.local'),
    (select version from wms.dock_appointments where vehicle_plate_no='56다7890'))) as depart_before_docking,
  pg_temp.expect_error(format(
    'select wms.wms_check_in_vehicle(%L, %L, gen_random_uuid(), %s, null, null, null)',
    (select id from wms.dock_appointments where carrier_name='다시운수'),
    pg_temp.uid('inbound-a@demo.local'),
    (select version from wms.dock_appointments where carrier_name='다시운수'))) as recheckin_at_dock,
  pg_temp.expect_error(format(
    'select wms.wms_cancel_dock_appointment(%L, %L, gen_random_uuid(), %s, null, null)',
    (select id from wms.dock_appointments where carrier_name='다시운수'),
    pg_temp.uid('inbound-a@demo.local'),
    (select version from wms.dock_appointments where carrier_name='다시운수'))) as cancel_at_dock;
\echo '-- expected: INVALID | INVALID | INVALID'

\echo ''
\echo '-- D5 expected_version mismatch -> CONFLICT'
select pg_temp.expect_error(format(
  'select wms.wms_depart_vehicle(%L, %L, gen_random_uuid(), 99, null)',
  (select id from wms.dock_appointments where carrier_name='다시운수'),
  pg_temp.uid('inbound-a@demo.local'))) as stale_version;

\echo ''
\echo '-- D6 AT_DOCK -> DEPARTED releases the dock back to AVAILABLE'
select
  (wms.wms_depart_vehicle(
    (select id from wms.dock_appointments where carrier_name='다시운수'),
    pg_temp.uid('inbound-a@demo.local'), gen_random_uuid(),
    (select version from wms.dock_appointments where carrier_name='다시운수'),
    'verify-D6'))->>'dock_status' as dock_status;
select status as appt_status from wms.dock_appointments where carrier_name='다시운수';
\echo '-- expected: AVAILABLE | DEPARTED'

\echo ''
\echo '-- D7 PROCESS_AGENT may book and cancel, but may NOT move a physical truck (D5)'
select pg_temp.act('process-agent-a@demo.local');
select (wms.wms_schedule_dock_appointment(
     (select id from wms.docks where code='DOCK-V-02'),
     '2026-08-02T09:00:00Z', '2026-08-02T10:00:00Z',
     pg_temp.uid('process-agent-a@demo.local'), gen_random_uuid(),
     'INBOUND', '40000000-0000-0000-0000-0000000000a1', 'AGENT운수', null, null, null, 'verify-D7'))->>'status'
    as agent_can_schedule;
select
  pg_temp.expect_error(format(
    'select wms.wms_check_in_vehicle(%L, %L, gen_random_uuid(), %s, null, null, null)',
    (select id from wms.dock_appointments where carrier_name='AGENT운수'),
    pg_temp.uid('process-agent-a@demo.local'),
    (select version from wms.dock_appointments where carrier_name='AGENT운수'))) as agent_cannot_check_in,
  pg_temp.expect_error(format(
    'select wms.wms_dock_vehicle(%L, %L, gen_random_uuid(), %s, null)',
    (select id from wms.dock_appointments where carrier_name='AGENT운수'),
    pg_temp.uid('process-agent-a@demo.local'),
    (select version from wms.dock_appointments where carrier_name='AGENT운수'))) as agent_cannot_dock,
  pg_temp.expect_error(format(
    'select wms.wms_register_dock(%L, %L, %L, %L, %L, gen_random_uuid(), null)',
    :'tenant_a', :'wh_a', 'DOCK-V-AGENT', 'x',
    pg_temp.uid('process-agent-a@demo.local'))) as agent_cannot_register;
\echo '-- expected: SCHEDULED | FORBIDDEN | FORBIDDEN | FORBIDDEN'

\echo ''
\echo '-- D8 ... but the agent CAN cancel what it booked'
select (wms.wms_cancel_dock_appointment(
    (select id from wms.dock_appointments where carrier_name='AGENT운수'),
    pg_temp.uid('process-agent-a@demo.local'), gen_random_uuid(),
    (select version from wms.dock_appointments where carrier_name='AGENT운수'),
    '에이전트 취소', 'verify-D8'))->>'status' as agent_can_cancel;
\echo '-- expected: CANCELLED'

\echo ''
\echo '=============================================================='
\echo 'E. Idempotency'
\echo '=============================================================='

select pg_temp.act('inbound-a@demo.local');
\set idem_key '\'aaaaaaaa-0000-4000-8000-00000000e001\''
select
  (wms.wms_schedule_dock_appointment(
     (select id from wms.docks where code='DOCK-V-02'),
     '2026-08-03T09:00:00Z', '2026-08-03T10:00:00Z',
     pg_temp.uid('inbound-a@demo.local'), :idem_key,
     'INBOUND', '40000000-0000-0000-0000-0000000000a1', 'IDEM운수', null, null, null, 'verify-E'))->>'appointment_id'
    as first_call,
  (wms.wms_schedule_dock_appointment(
     (select id from wms.docks where code='DOCK-V-02'),
     '2026-08-03T09:00:00Z', '2026-08-03T10:00:00Z',
     pg_temp.uid('inbound-a@demo.local'), :idem_key,
     'INBOUND', '40000000-0000-0000-0000-0000000000a1', 'IDEM운수', null, null, null, 'verify-E'))->>'appointment_id'
    as replayed_call;
select count(*) as rows_created from wms.dock_appointments where carrier_name = 'IDEM운수';
\echo '-- expected: the same uuid twice, and exactly 1 row (the replay did not'
\echo '   re-insert, and it did not trip the exclusion constraint either)'

\echo ''
\echo '=============================================================='
\echo 'F. Read RPC + RLS / cross-tenant'
\echo '=============================================================='

select pg_temp.act('inbound-a@demo.local');
select
  d->>'code' as dock,
  d->>'status' as dock_status,
  jsonb_array_length(d->'appointments') as appts
from jsonb_array_elements(
  (wms.wms_get_dock_schedule(:'tenant_a', :'wh_a', '2026-08-01T00:00:00Z', '2026-08-04T00:00:00Z'))->'docks'
) d
where d->>'code' like 'DOCK-V-%';

\echo ''
\echo '-- F2 the window filter really filters'
select
  (wms.wms_get_dock_schedule(:'tenant_a', :'wh_a',
     '2026-08-01T00:00:00Z', '2026-08-02T00:00:00Z'))->>'appointment_count' as day1_only,
  (wms.wms_get_dock_schedule(:'tenant_a', :'wh_a',
     '2026-09-01T00:00:00Z', '2026-09-02T00:00:00Z'))->>'appointment_count' as empty_day;

\echo ''
\echo '-- F3 tenant A reading tenant B''s warehouse -> FORBIDDEN'
select pg_temp.error_text(format(
  'select wms.wms_get_dock_schedule(%L, %L, null, null)', :'tenant_b', :'wh_b')) as cross_tenant_read;

\echo ''
\echo '-- F4 RLS itself: tenant B admin sees zero tenant A rows.'
\echo '--    psql connects as the postgres superuser, which BYPASSES RLS, so the'
\echo '--    role really has to be dropped to `authenticated` for this to mean'
\echo '--    anything. (Everything above tests the RPC-level guard instead.)'
select pg_temp.act('admin-b@demo.local');
begin;
set local role authenticated;
select
  (select count(*) from wms.docks where code like 'DOCK-V-%') as b_sees_a_docks,
  (select count(*) from wms.dock_appointments
     where warehouse_id = '20000000-0000-0000-0000-00000000000a') as b_sees_a_appointments;
rollback;
\echo '-- expected: 0 | 0'

\echo ''
\echo '-- F4b the same query as tenant A''s inbound operator DOES see them'
select pg_temp.act('inbound-a@demo.local');
begin;
set local role authenticated;
select
  (select count(*) from wms.docks where code like 'DOCK-V-%') as a_sees_a_docks,
  (select count(*) > 0 from wms.dock_appointments
     where warehouse_id = '20000000-0000-0000-0000-00000000000a') as a_sees_a_appointments;
rollback;
\echo '-- expected: 2 | t'

\echo ''
\echo '-- F4c a direct write attempt as `authenticated` is denied by RLS'
\echo '--    (no INSERT policy exists — every write must go through an RPC)'
begin;
set local role authenticated;
select pg_temp.expect_error(format($q$
  insert into wms.docks (tenant_id, warehouse_id, code, name)
  values (%L, %L, 'DOCK-V-RLS', 'direct insert')$q$,
  '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-00000000000a')) as direct_insert;
select pg_temp.expect_error(
  $q$update wms.docks set status = 'CLOSED' where code like 'DOCK-V-%'$q$) as direct_update_rows;
rollback;
\echo '-- expected: a permission-denied error, then 0 rows updated'

\echo ''
\echo '-- F5 tenant B admin cannot book a tenant A dock -> FORBIDDEN'
select pg_temp.act('admin-b@demo.local');
select pg_temp.error_text(format(
  'select wms.wms_schedule_dock_appointment(%L, %L, %L, %L, gen_random_uuid(), %L, %L)',
  (select id from wms.docks where code='DOCK-V-01'),
  '2026-08-05T09:00:00Z', '2026-08-05T10:00:00Z',
  pg_temp.uid('admin-b@demo.local'), 'INBOUND', '40000000-0000-0000-0000-0000000000a1')) as cross_tenant_write;

\echo ''
\echo '-- F6 no direct DML privileges leaked to authenticated/anon'
select grantee, privilege_type, table_name
from information_schema.role_table_grants
where table_schema = 'wms' and table_name in ('docks', 'dock_appointments')
  and grantee in ('authenticated', 'anon')
order by table_name, grantee, privilege_type;
\echo '-- expected: SELECT rows only (no INSERT/UPDATE/DELETE)'

\echo ''
\echo '=============================================================='
\echo 'G. Independence from wms_register_arrival (D2)'
\echo '=============================================================='

select pg_temp.act('inbound-a@demo.local');
\echo '-- G1 a PO with NO appointment at all still transitions EXPECTED -> ARRIVED'
select (wms.wms_register_arrival('40000000-0000-0000-0000-0000000000a2',
          pg_temp.uid('inbound-a@demo.local'), gen_random_uuid()))->>'status' as no_appointment_po;

\echo ''
\echo '-- G2 a PO whose appointment is merely SCHEDULED is not blocked either'
select (wms.wms_register_arrival('40000000-0000-0000-0000-0000000000a1',
          pg_temp.uid('inbound-a@demo.local'), gen_random_uuid()))->>'status' as scheduled_appointment_po;
\echo '-- expected: ARRIVED | ARRIVED'

\echo ''
\echo '-- G3 register_arrival wrote nothing into this contract''s tables'
select
  (select count(*) from wms.audit_events
    where command = 'wms_register_arrival' and entity_type in ('dock', 'dock_appointment')) as leaked_audit,
  (select count(*) from wms.dock_appointments a join wms.docks d on d.id = a.dock_id
    where d.code like 'DOCK-V-%' and a.updated_at > a.created_at + interval '0'
      and a.status not in ('CANCELLED','CHECKED_IN','AT_DOCK','DEPARTED')) as unexpected_mutations;
\echo '-- expected: 0 | 0'

\echo ''
\echo '=============================================================='
\echo 'H. Audit coverage — all 7 write RPCs, with before/after'
\echo '=============================================================='

select command, entity_type, count(*) as events,
       count(*) filter (where before is not null) as with_before,
       count(*) filter (where after is not null) as with_after,
       count(*) filter (where correlation_id is not null) as with_correlation
from wms.audit_events
where command in ('wms_register_dock','wms_set_dock_status','wms_schedule_dock_appointment',
                  'wms_cancel_dock_appointment','wms_check_in_vehicle','wms_dock_vehicle','wms_depart_vehicle')
group by command, entity_type
order by command, entity_type;

\echo ''
\echo '-- H2 the docking event carries CHECKED_IN -> AT_DOCK (spec.md scenario)'
select before->>'status' as before_status, after->>'status' as after_status
from wms.audit_events
where command = 'wms_dock_vehicle' and entity_type = 'dock_appointment'
order by created_at desc limit 1;
\echo '-- expected: CHECKED_IN | AT_DOCK'

\echo ''
\echo '=============================================================='
\echo 'I. Cleanup'
\echo '=============================================================='
\set QUIET on
delete from wms.dock_appointments a using wms.docks d
  where a.dock_id = d.id and d.code like 'DOCK-V-%';
delete from wms.docks where code like 'DOCK-V-%';
delete from wms.dispatch_sequences where outbound_order_id = '50000000-0000-0000-0000-0000000000a1';
delete from wms.outbound_orders where id = '50000000-0000-0000-0000-0000000000a1';
delete from wms.receipts where po_id in (select id from wms.purchase_orders where reason = 'DOCK-V-FIXTURE');
delete from wms.purchase_orders where reason = 'DOCK-V-FIXTURE';
\set QUIET off
\echo 'fixtures removed.'
