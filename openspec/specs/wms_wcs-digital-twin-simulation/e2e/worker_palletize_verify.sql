\set QUIET on
\pset pager off
\pset format aligned
\set ON_ERROR_STOP on

-- ============================================================
-- wms_wcs-digital-twin-simulation — PALLETIZE assertions (tasks.md 6.3)
-- Run AFTER worker_palletize.sql + a real worker --once pass.
-- ============================================================

\set QUIET off
\echo ''
\echo '-- the worker''s ONE command report moved BOTH sequences and BOTH orders'
select o.store_code, s.sequence_position, s.status as sequence_status,
       s.load_position, o.status as order_status
from wms.dispatch_sequences s join wms.outbound_orders o on o.id = s.outbound_order_id
where s.target_pallet_code = 'PLT-WRK-1' order by s.sequence_position;

\echo ''
\echo '-- the terminal event the worker wrote: outcome SUCCESS, every item LOADED,'
\echo '   each with its own load_position (this is what area 5''s trigger consumed)'
select ev.detail->>'outcome' as outcome,
       ev.detail->>'simulated' as simulated,
       jsonb_array_length(ev.detail->'loaded_items') as item_count,
       (select string_agg(i->>'item_outcome', ',')
          from jsonb_array_elements(ev.detail->'loaded_items') i) as item_outcomes
from wms.equipment_status_events ev
join wms.equipment e on e.id = ev.equipment_id
where e.equipment_code = 'WRK-CELL' and ev.event_type = 'COMMAND_COMPLETED';

\echo ''
\echo '-- assertion: 2 sequences COMPLETED, 2 orders COMPLETED, distinct positions'
select
  (select count(*) from wms.dispatch_sequences
    where target_pallet_code='PLT-WRK-1' and status='COMPLETED') = 2 as sequences_completed,
  (select count(*) from wms.dispatch_sequences s
     join wms.outbound_orders o on o.id = s.outbound_order_id
    where s.target_pallet_code='PLT-WRK-1' and o.status='COMPLETED') = 2 as orders_completed,
  (select count(distinct load_position) from wms.dispatch_sequences
    where target_pallet_code='PLT-WRK-1') = 2 as distinct_load_positions;

\echo ''
\echo '-- the propagation audit rows nobody clicked (actor = the worker identity)'
select a.command, count(*) as events,
       (select email from auth.users u where u.id = a.actor_id) as actor
from wms.audit_events a
where a.command = 'wms_propagate_palletize_result'
group by a.command, a.actor_id;
