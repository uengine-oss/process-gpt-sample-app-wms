-- One-time fixture for the "wms_sequential_dispatch_process" ProcessGPT demo.
-- Registers a single ROBOT_CELL, brings it IDLE, and turns on simulation with
-- failure_rate=0 so the wcs_gateway_simulator worker reliably completes the
-- happy-path PALLETIZE command during the demo recording (the OVERWEIGHT
-- exception branch is instead manufactured deterministically by
-- record_wms_sequential_dispatch_demo.mjs itself via a direct
-- wms_report_command_result call, not by this simulator).
--
-- Uses named parameter notation (function(p_x => value)) throughout —
-- positional calls against 6-12 argument RPCs are too easy to miscount.
--
-- Idempotent: register_equipment upserts on (warehouse_id, equipment_code);
-- the simulation profile insert is guarded by a NOT EXISTS check.
\set QUIET on
\set ON_ERROR_STOP on

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
\set wh_a     '20000000-0000-0000-0000-00000000000a'

select id as mgr_a from auth.users where email = 'wh-manager-a@demo.local' \gset
select id as gw_a  from auth.users where email = 'wcs-gateway-a@demo.local' \gset

\set QUIET off
\echo '== register DISPATCH-CELL-01 (idempotent — upserts on warehouse_id+code) =='
select pg_temp.act('wh-manager-a@demo.local');
set role authenticated;
select wms.wms_register_equipment(
  p_tenant_id => :'tenant_a', p_warehouse_id => :'wh_a',
  p_equipment_code => 'DISPATCH-CELL-01', p_equipment_type => 'ROBOT_CELL',
  p_zone_code => 'ZONE-DISPATCH-DEMO', p_actor_id => :'mgr_a',
  p_idempotency_key => gen_random_uuid(), p_correlation_id => 'sequential-dispatch-demo-setup');
reset role;

select id as cell_id from wms.equipment where warehouse_id = :'wh_a'
  and equipment_code = 'DISPATCH-CELL-01' \gset

\echo '== boot it IDLE (as the WCS_GATEWAY identity, same as a real bridge) =='
select pg_temp.act('wcs-gateway-a@demo.local');
set role authenticated;
select wms.wms_report_equipment_status(
  p_equipment_id => :'cell_id', p_new_status => 'IDLE', p_actor_id => :'gw_a',
  p_idempotency_key => gen_random_uuid(),
  p_expected_version => (select version from wms.equipment where id = :'cell_id'),
  p_correlation_id => 'sequential-dispatch-demo-setup');
reset role;

\echo '== turn on simulation (WAREHOUSE_MANAGER only) =='
select pg_temp.act('wh-manager-a@demo.local');
set role authenticated;
select wms.wms_set_equipment_simulation_mode(
  p_equipment_id => :'cell_id', p_is_simulated => true, p_actor_id => :'mgr_a',
  p_idempotency_key => gen_random_uuid(),
  p_expected_version => (select version from wms.equipment where id = :'cell_id'),
  p_correlation_id => 'sequential-dispatch-demo-setup');
reset role;

\echo '== register a zero-failure-rate profile if none exists yet =='
select pg_temp.act('wh-manager-a@demo.local');
set role authenticated;
select case when exists (select 1 from wms.simulation_profiles where equipment_id = :'cell_id')
  then 'profile already exists, skipping'
  else (
    select wms.wms_register_simulation_profile(
      p_equipment_id => :'cell_id',
      p_ack_delay_ms_min => 500, p_ack_delay_ms_max => 1200,
      p_progress_delay_ms_min => 800, p_progress_delay_ms_max => 2000,
      p_completion_delay_ms_min => 1500, p_completion_delay_ms_max => 3000,
      p_failure_rate => 0, p_jam_rate => 0,
      p_actor_id => :'mgr_a', p_idempotency_key => gen_random_uuid(),
      p_correlation_id => 'sequential-dispatch-demo-setup'
    )::text
  )
end as profile_setup_result;
reset role;

select equipment_code, equipment_type, status, is_simulated, version
from wms.equipment where id = :'cell_id';
select ack_delay_ms_min, ack_delay_ms_max, completion_delay_ms_min, completion_delay_ms_max,
       failure_rate, status
from wms.simulation_profiles where equipment_id = :'cell_id';
