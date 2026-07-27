\set QUIET on
\pset pager off
\pset format aligned
\set ON_ERROR_STOP on

-- ============================================================
-- wms_wcs-digital-twin-simulation — restart-safety fixture (design.md D3)
--
-- Slows WRK-AGV down so that a single --tick cannot drain the command, then
-- dispatches one MOVE. worker_e2e.sh then runs --tick as a SEQUENCE OF
-- SEPARATE OS PROCESSES: each one exits completely between rounds, which is
-- the restart. Because the plan (delays + the pre-rolled terminal outcome)
-- lives in wms.simulation_command_schedules and not in the worker's memory,
-- the next process picks the command up exactly where the previous one left
-- it -- nothing is re-rolled, re-reported or lost.
-- ============================================================

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
select id as agv   from wms.equipment where equipment_code = 'WRK-AGV' \gset
select id as prof  from wms.simulation_profiles where equipment_id = :'agv' \gset

\set QUIET off
\echo ''
\echo '=============================================================='
\echo 'F. Restart safety (design.md D3) — slow the AGV down, dispatch,'
\echo '   then drive it with SEPARATE --tick processes'
\echo '=============================================================='

select pg_temp.act('wh-manager-a@demo.local');
set role authenticated;
-- ~1.2s per step: a single --tick can never take this to a terminal state
select wms.wms_update_simulation_profile(
  p_profile_id => :'prof', p_actor_id => :'mgr_a',
  p_idempotency_key => gen_random_uuid(),
  p_expected_version => (select version from wms.simulation_profiles where id = :'prof'),
  p_ack_delay_ms_min => 1200, p_ack_delay_ms_max => 1200,
  p_progress_delay_ms_min => 1200, p_progress_delay_ms_max => 1200,
  p_completion_delay_ms_min => 1200, p_completion_delay_ms_max => 1200,
  p_failure_rate => 0, p_jam_rate => 0,
  p_correlation_id => 'worker-e2e') ->> 'status' as slowed_profile;
reset role;

select pg_temp.act('wcs-operator-a@demo.local');
set role authenticated;
select wms.wms_dispatch_equipment_command(:'agv', 'MOVE',
  '{"from":"ZONE-OUT","to":"ZONE-WRK"}'::jsonb, :'op_a', gen_random_uuid(),
  (select version from wms.equipment where id = :'agv'), 'worker-e2e-restart', null, null
) ->> 'status' as restart_command_status;
reset role;
