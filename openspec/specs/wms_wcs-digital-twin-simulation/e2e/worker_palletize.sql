\set QUIET on
\pset pager off
\pset format aligned
\set ON_ERROR_STOP on

-- ============================================================
-- wms_wcs-digital-twin-simulation — PALLETIZE fixture (tasks.md 6.3)
--
-- The vocabulary map (design.md D5 / migration DEVIATION 1) says a simulated
-- PALLETIZE must come back as outcome=SUCCESS with every planned item marked
-- LOADED. That claim is only worth anything if the resulting report survives
-- area 5's _wms_validate_palletize_outcome trigger AND drives its per-item
-- propagation -- i.e. if N dispatch sequences and their outbound orders all
-- reach COMPLETED because a WORKER, not a person, reported one command result.
--
-- This script builds the area-5 chain in front of a SIMULATED ROBOT_CELL and
-- stops at PENDING. worker_e2e.sh then runs the real worker; worker_palletize_
-- verify.sql checks the propagation.
-- ============================================================

-- repeatable: worker_setup.sql truncates the equipment side but not area 5's
truncate wms.dispatch_sequences, wms.outbound_orders, wms.dispatch_waves
  restart identity cascade;

\set tenant_a '10000000-0000-0000-0000-00000000000a'
\set wh_a     '20000000-0000-0000-0000-00000000000a'

create or replace function pg_temp.act(p_email text) returns void
language plpgsql as $fn$
declare v_id uuid;
begin
  select id into v_id from auth.users where email = p_email;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_id::text, 'role', 'authenticated')::text, false);
end
$fn$;

select id as mgr_a from auth.users where email = 'wh-manager-a@demo.local' \gset
select id as op_a  from auth.users where email = 'wcs-operator-a@demo.local' \gset
select id as gw_a  from auth.users where email = 'wcs-gateway-a@demo.local' \gset
select id as prod  from wms.products where tenant_id = :'tenant_a' limit 1 \gset

\set QUIET off
\echo ''
\echo '=============================================================='
\echo 'G. PALLETIZE through the worker (tasks.md 6.3) — a SIMULATED'
\echo '   robot cell must drive area 5 per-item completion propagation'
\echo '=============================================================='

select pg_temp.act('wh-manager-a@demo.local');
set role authenticated;
select wms.wms_register_equipment(:'tenant_a', :'wh_a', 'WRK-CELL', 'ROBOT_CELL',
  'ZONE-WRK', :'mgr_a', gen_random_uuid(), 'worker-e2e-pal') is not null as cell_registered;
reset role;

select id as cell from wms.equipment where equipment_code = 'WRK-CELL' \gset

select pg_temp.act('wcs-gateway-a@demo.local');
set role authenticated;
select wms.wms_report_equipment_status(:'cell', 'IDLE', :'gw_a', gen_random_uuid(), 1, null,
  'worker-e2e-pal') is not null as cell_idle;
reset role;

\echo ''
\echo '-- simulate the cell, with a fast never-failing profile'
select pg_temp.act('wh-manager-a@demo.local');
set role authenticated;
select wms.wms_set_equipment_simulation_mode(:'cell', true, :'mgr_a', gen_random_uuid(),
  (select version from wms.equipment where id = :'cell'), 'worker-e2e-pal') ->> 'is_simulated' as cell_simulated;
select wms.wms_register_simulation_profile(
  p_equipment_id => :'cell',
  p_ack_delay_ms_min => 100, p_ack_delay_ms_max => 200,
  p_progress_delay_ms_min => 100, p_progress_delay_ms_max => 200,
  p_completion_delay_ms_min => 100, p_completion_delay_ms_max => 200,
  p_failure_rate => 0, p_jam_rate => 0,
  p_actor_id => :'mgr_a', p_idempotency_key => gen_random_uuid(),
  p_correlation_id => 'worker-e2e-pal') ->> 'status' as cell_profile;

\echo ''
\echo '-- area 2 + area 5 chain: wave -> two outbound units -> two sequences'
select wms.wms_open_dispatch_wave(:'tenant_a', :'wh_a', :'mgr_a', gen_random_uuid(),
  'worker-e2e-pal') ->> 'wave_id' as wave_id \gset
select :'wave_id' as opened_wave;

select wms.wms_create_outbound_order(:'tenant_a', :'wh_a', 'STORE-WRK-1', :'prod', 3,
  :'mgr_a', gen_random_uuid(), 'OO-WRK-1', null, 4.0, 10.0,
  'worker-e2e-pal') ->> 'outbound_order_id' as oo1 \gset
select wms.wms_create_outbound_order(:'tenant_a', :'wh_a', 'STORE-WRK-2', :'prod', 2,
  :'mgr_a', gen_random_uuid(), 'OO-WRK-2', null, 6.0, 12.0,
  'worker-e2e-pal') ->> 'outbound_order_id' as oo2 \gset

select wms.wms_assign_dispatch_sequence(:'oo1', :'wave_id', 1, 'PLT-WRK-1', :'mgr_a',
  gen_random_uuid(), (select version from wms.outbound_orders where id = :'oo1'),
  'worker-e2e-pal') ->> 'status' as seq1;
select wms.wms_assign_dispatch_sequence(:'oo2', :'wave_id', 2, 'PLT-WRK-1', :'mgr_a',
  gen_random_uuid(), (select version from wms.outbound_orders where id = :'oo2'),
  'worker-e2e-pal') ->> 'status' as seq2;
reset role;

\echo ''
\echo '-- one PALLETIZE carrying BOTH sequences goes to the simulated cell'
select pg_temp.act('wcs-operator-a@demo.local');
set role authenticated;
select wms.wms_dispatch_palletize_command(:'cell', :'wave_id', 'PLT-WRK-1', :'op_a',
  gen_random_uuid(), (select version from wms.equipment where id = :'cell'),
  null, null, 'worker-e2e-pal') ->> 'result' as palletize_dispatched;
reset role;

\echo ''
\echo '-- BEFORE the worker: command PENDING, both sequences DISPATCHED'
select c.command_type, c.status as command_status,
       jsonb_array_length(c.payload->'sequence_items') as planned_items
from wms.equipment_commands c where c.equipment_id = :'cell';

select o.store_code, s.sequence_position, s.status as sequence_status, o.status as order_status
from wms.dispatch_sequences s join wms.outbound_orders o on o.id = s.outbound_order_id
where s.target_pallet_code = 'PLT-WRK-1' order by s.sequence_position;
