-- ============================================================
-- Yard & dock scheduling contract
-- Scope: openspec/changes/add-yard-dock-scheduling
--        (proposal.md / design.md / specs/wms_yard-dock-scheduling/spec.md)
--
-- The seventh area, and the first one that is NOT part of the WCS/WES chain.
-- It adds the "docks" half of the location model that main repo
-- openspec/changes/supabase-wms-erp-replacement/design.md §7.2 listed
-- (warehouses, zones, locations, docks) but 20260726_wms_core_schema.sql never
-- built: only wms.warehouses exists there.
--
--   * wms.docks              — per-warehouse dock registry (AVAILABLE/OCCUPIED/CLOSED)
--   * wms.dock_appointments  — a dock + a time window, with the vehicle's
--                              discrete journey SCHEDULED -> CHECKED_IN ->
--                              AT_DOCK -> DEPARTED (+ CANCELLED)
--
-- Conventions (schema, common columns, RLS helpers, RPC envelope,
-- CONFLICT:/FORBIDDEN:/INVALID: prefixes, idempotency records, audit events)
-- are identical to the seven migrations before it, and none of those files is
-- modified here.
--
-- ORDERING / DEPENDENCIES: this migration requires only
--   20260726_wms_core_schema.sql  (wms.tenants, wms.warehouses,
--                                  wms.purchase_orders, wms.idempotency_records,
--                                  wms.audit_events, wms.has_role,
--                                  wms.current_warehouse_ids)
-- It has NO dependency on areas 1-6 (equipment / commands / waves / sortation /
-- routing / simulation) — design.md's "이 영역은 area1~6과 독립적이다". The one
-- soft touch point is described under DECISION D3-AMENDED below.
--
-- NOT MODIFIED HERE: wms_register_arrival. design.md D2 makes the two contracts
-- orthogonal — a receipt can reach ARRIVED with no appointment at all, and an
-- appointment never triggers or blocks wms_register_arrival. Verified by
-- openspec/specs/wms_yard-dock-scheduling/e2e/independence.sql.
--
-- ------------------------------------------------------------
-- D1 (as designed) — double booking is refused by the storage engine
--
--   EXCLUDE USING gist (dock_id WITH =, during WITH &&)
--     WHERE (status IN ('SCHEDULED','CHECKED_IN','AT_DOCK'))
--
--   `dock_id WITH =` needs btree_gist, which no prior migration in this
--   repository enables (grep: there is no `create extension` anywhere under
--   supabase/), so it is enabled here. An application-level "is this window
--   free?" SELECT could not close the phantom-row race at READ COMMITTED; the
--   exclusion constraint does, atomically, with no isolation-level change.
--   wms_schedule_dock_appointment catches SQLSTATE 23P01 (exclusion_violation)
--   and re-raises it as a CONFLICT: — the same class callers already handle for
--   expected_version mismatches.
--
-- ------------------------------------------------------------
-- D3-AMENDED (deviation from design.md, deliberate) — OUTBOUND appointments
-- are implemented, not deferred
--
--   design.md D3 wrote that wms.outbound_orders was "아직 메인 스키마에 병합되지
--   않았다" and therefore left appointment_type='OUTBOUND' as a column-only
--   extension point with no logic. That premise is now false:
--   20260731_wcs_sequential_dispatch.sql really does create wms.outbound_orders,
--   and it is applied before this file. So OUTBOUND appointments are a working
--   appointment type here rather than dead metadata.
--
--   What did NOT change: there is still no hard FK to wms.outbound_orders. The
--   link stays the loose (linked_entity_type, linked_entity_id) pair that area 1
--   uses on wms.equipment_commands, so a future outbound model can slot in under
--   a different linked_entity_type without a migration. The only added logic is
--   a scope check inside the RPC: when linked_entity_type = 'outbound_order',
--   linked_entity_id must name a row in wms.outbound_orders in the SAME tenant
--   and warehouse. Any other linked_entity_type is accepted uninterpreted.
--
--   Consequence for the schema: po_id is required for INBOUND (spec.md) and
--   must be NULL for OUTBOUND (a PO is an inbound document; letting an OUTBOUND
--   row carry one would make po_id meaningless).
--
-- D4 (as designed) — dock OCCUPIED/AVAILABLE is derived, never set by hand.
--   wms_dock_vehicle takes the dock to OCCUPIED, wms_depart_vehicle releases it
--   back to AVAILABLE. wms_set_dock_status only moves AVAILABLE <-> CLOSED and
--   refuses to close an OCCUPIED dock.
--
-- D5 (as designed) — no new roles. Registry/maintenance is
--   WMS_ADMIN + WAREHOUSE_MANAGER; booking is INBOUND_OPERATOR + WMS_ADMIN +
--   PROCESS_AGENT; the three physical events (check-in / dock / depart) are
--   INBOUND_OPERATOR + WMS_ADMIN only — an agent must not assert that a truck
--   physically moved.
-- ============================================================

create extension if not exists btree_gist;

-- ------------------------------------------------------------
-- Tables
-- ------------------------------------------------------------

create table wms.docks (
  id uuid primary key default gen_random_uuid(),
  tenant_id text not null references wms.tenants(id) on delete cascade,
  warehouse_id uuid not null references wms.warehouses(id) on delete cascade,
  code text not null,
  name text not null,
  -- OCCUPIED is derived from the vehicle lifecycle (D4); only AVAILABLE and
  -- CLOSED are reachable by an explicit human command.
  status text not null default 'AVAILABLE'
    check (status in ('AVAILABLE', 'OCCUPIED', 'CLOSED')),
  reason text,
  version int not null default 1,
  correlation_id text,
  created_by uuid,
  updated_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (warehouse_id, code)
);

create table wms.dock_appointments (
  id uuid primary key default gen_random_uuid(),
  tenant_id text not null references wms.tenants(id) on delete cascade,
  warehouse_id uuid not null references wms.warehouses(id) on delete cascade,
  dock_id uuid not null references wms.docks(id) on delete cascade,
  appointment_type text not null default 'INBOUND'
    check (appointment_type in ('INBOUND', 'OUTBOUND')),
  -- required for INBOUND, forbidden for OUTBOUND (D3-AMENDED)
  po_id uuid references wms.purchase_orders(id) on delete cascade,
  -- loose reference, no FK — same pattern as wms.equipment_commands (D3)
  linked_entity_type text,
  linked_entity_id uuid,
  carrier_name text,
  vehicle_plate_no text,
  scheduled_start timestamptz not null,
  scheduled_end timestamptz not null,
  -- half-open on purpose: a 09:00-10:00 booking and a 10:00-11:00 booking on
  -- the same dock do NOT overlap (spec.md "겹치지 않는 시간창은 ... 예약할 수 있다").
  during tstzrange generated always as (tstzrange(scheduled_start, scheduled_end, '[)')) stored,
  status text not null default 'SCHEDULED'
    check (status in ('SCHEDULED', 'CHECKED_IN', 'AT_DOCK', 'DEPARTED', 'CANCELLED')),
  checked_in_at timestamptz,
  docked_at timestamptz,
  departed_at timestamptz,
  reason text,
  version int not null default 1,
  correlation_id text,
  created_by uuid,
  updated_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint dock_appointments_window_ck
    check (scheduled_end > scheduled_start),
  constraint dock_appointments_inbound_po_ck
    check (appointment_type <> 'INBOUND' or po_id is not null),
  constraint dock_appointments_outbound_po_ck
    check (appointment_type <> 'OUTBOUND' or po_id is null),
  constraint dock_appointments_linked_pair_ck
    check ((linked_entity_type is null) = (linked_entity_id is null)),
  -- D1: the whole point of this contract. CANCELLED and DEPARTED rows drop out
  -- of the predicate, so a cancelled booking frees its slot immediately.
  constraint dock_appointments_no_double_booking
    exclude using gist (dock_id with =, during with &&)
    where (status in ('SCHEDULED', 'CHECKED_IN', 'AT_DOCK'))
);

create index docks_warehouse_status_idx on wms.docks (warehouse_id, status);
create index dock_appointments_warehouse_window_idx
  on wms.dock_appointments (warehouse_id, scheduled_start);
create index dock_appointments_dock_status_idx
  on wms.dock_appointments (dock_id, status);
create index dock_appointments_po_idx on wms.dock_appointments (po_id);

-- ============================================================
-- RLS: SELECT-only for tenant/warehouse members; every write goes through the
-- SECURITY DEFINER RPCs below (same pattern as the seven prior migrations).
-- No INSERT/UPDATE/DELETE policy is created, so RLS denies those by default
-- for authenticated/anon (core schema design.md D3).
-- ============================================================

alter table wms.docks enable row level security;
create policy docks_select on wms.docks for select to authenticated
  using (warehouse_id in (select wms.current_warehouse_ids(tenant_id)));

alter table wms.dock_appointments enable row level security;
create policy dock_appointments_select on wms.dock_appointments for select to authenticated
  using (warehouse_id in (select wms.current_warehouse_ids(tenant_id)));

grant select on wms.docks to authenticated;
grant select on wms.dock_appointments to authenticated;

-- ============================================================
-- Internal helpers
-- ============================================================

-- Loads an appointment and enforces everything every lifecycle RPC needs to
-- check before it may touch the row: existence, warehouse scope, role and
-- optimistic version. Returns the row so the caller can branch on status.
create or replace function wms._wms_load_dock_appointment(
  p_appointment_id uuid,
  p_expected_version int,
  p_roles text[]
) returns wms.dock_appointments
language plpgsql stable security definer
set search_path = wms, public
as $$
declare
  v_appt wms.dock_appointments%rowtype;
begin
  select * into v_appt from wms.dock_appointments where id = p_appointment_id;
  if not found then
    raise exception 'INVALID: unknown dock appointment %', p_appointment_id;
  end if;
  if v_appt.warehouse_id not in (select wms.current_warehouse_ids(v_appt.tenant_id)) then
    raise exception 'FORBIDDEN: no warehouse scope for dock appointment %', p_appointment_id;
  end if;
  if not wms.has_role(v_appt.tenant_id, variadic p_roles) then
    raise exception 'FORBIDDEN: role cannot act on dock appointments';
  end if;
  if p_expected_version is not null and v_appt.version <> p_expected_version then
    raise exception 'CONFLICT: expected version % but found %', p_expected_version, v_appt.version;
  end if;
  return v_appt;
end;
$$;

-- ============================================================
-- Command RPCs
-- Envelope in:  tenant_id / warehouse_id (implied by the target row for
--               id-addressed calls), actor_id, idempotency_key,
--               expected_version, correlation_id.
-- Envelope out: {result, document_id, status, version, next_actions, warnings}.
-- Errors:       RAISE EXCEPTION with CONFLICT:/FORBIDDEN:/INVALID: prefix.
-- ============================================================

create or replace function wms.wms_register_dock(
  p_tenant_id text,
  p_warehouse_id uuid,
  p_code text,
  p_name text,
  p_actor_id uuid,
  p_idempotency_key uuid,
  p_correlation_id text default null
) returns jsonb
language plpgsql security definer
set search_path = wms, public
as $$
declare
  v_cached jsonb;
  v_dock wms.docks%rowtype;
begin
  if p_idempotency_key is not null then
    select response into v_cached from wms.idempotency_records
      where tenant_id = p_tenant_id and command_name = 'wms_register_dock' and idempotency_key = p_idempotency_key;
    if found then return v_cached; end if;
  end if;

  if p_warehouse_id not in (select wms.current_warehouse_ids(p_tenant_id)) then
    raise exception 'FORBIDDEN: no warehouse scope for %', p_warehouse_id;
  end if;
  if not wms.has_role(p_tenant_id, 'WMS_ADMIN', 'WAREHOUSE_MANAGER') then
    raise exception 'FORBIDDEN: role cannot register docks';
  end if;
  if p_code is null or btrim(p_code) = '' then
    raise exception 'INVALID: code is required';
  end if;
  if p_name is null or btrim(p_name) = '' then
    raise exception 'INVALID: name is required';
  end if;
  if exists (select 1 from wms.docks where warehouse_id = p_warehouse_id and code = p_code) then
    raise exception 'INVALID: dock code % already registered in warehouse %', p_code, p_warehouse_id;
  end if;

  insert into wms.docks (
    tenant_id, warehouse_id, code, name, status, correlation_id, created_by, updated_by
  ) values (
    p_tenant_id, p_warehouse_id, p_code, p_name, 'AVAILABLE', p_correlation_id, p_actor_id, p_actor_id
  )
  returning * into v_dock;

  insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, before, after, correlation_id)
  values (p_tenant_id, p_actor_id, 'wms_register_dock', 'dock', v_dock.id, null, to_jsonb(v_dock), p_correlation_id);

  v_cached := jsonb_build_object(
    'result', 'ok',
    'document_id', v_dock.id,
    'dock_id', v_dock.id,
    'code', v_dock.code,
    'status', v_dock.status,
    'version', v_dock.version,
    'warnings', '[]'::jsonb,
    'next_actions', jsonb_build_array('schedule_dock_appointment', 'set_dock_status')
  );
  if p_idempotency_key is not null then
    insert into wms.idempotency_records (tenant_id, command_name, idempotency_key, response)
    values (p_tenant_id, 'wms_register_dock', p_idempotency_key, v_cached)
    on conflict do nothing;
  end if;
  return v_cached;
end;
$$;

-- D4: maintenance only. OCCUPIED is never a valid target here — it is derived
-- from wms_dock_vehicle — and an OCCUPIED dock cannot be closed out from under
-- a truck that is currently unloading at it.
create or replace function wms.wms_set_dock_status(
  p_dock_id uuid,
  p_new_status text,
  p_actor_id uuid,
  p_idempotency_key uuid,
  p_expected_version int,
  p_reason text default null,
  p_correlation_id text default null
) returns jsonb
language plpgsql security definer
set search_path = wms, public
as $$
declare
  v_cached jsonb;
  v_dock wms.docks%rowtype;
  v_before jsonb;
  v_tenant_id text;
begin
  select tenant_id into v_tenant_id from wms.docks where id = p_dock_id;
  if p_idempotency_key is not null and v_tenant_id is not null then
    select response into v_cached from wms.idempotency_records
      where tenant_id = v_tenant_id and command_name = 'wms_set_dock_status' and idempotency_key = p_idempotency_key;
    if found then return v_cached; end if;
  end if;

  select * into v_dock from wms.docks where id = p_dock_id for update;
  if not found then
    raise exception 'INVALID: unknown dock %', p_dock_id;
  end if;
  if v_dock.warehouse_id not in (select wms.current_warehouse_ids(v_dock.tenant_id)) then
    raise exception 'FORBIDDEN: no warehouse scope for dock %', p_dock_id;
  end if;
  if not wms.has_role(v_dock.tenant_id, 'WMS_ADMIN', 'WAREHOUSE_MANAGER') then
    raise exception 'FORBIDDEN: role cannot change dock status';
  end if;
  if v_dock.version <> p_expected_version then
    raise exception 'CONFLICT: expected version % but found %', p_expected_version, v_dock.version;
  end if;
  if p_new_status not in ('AVAILABLE', 'CLOSED') then
    raise exception 'INVALID: new_status must be AVAILABLE or CLOSED (OCCUPIED is derived from the vehicle lifecycle)';
  end if;
  if v_dock.status = 'OCCUPIED' then
    raise exception 'INVALID: dock % is OCCUPIED — depart the vehicle before changing its status', p_dock_id;
  end if;
  if v_dock.status = p_new_status then
    raise exception 'INVALID: dock % is already %', p_dock_id, p_new_status;
  end if;

  v_before := to_jsonb(v_dock);

  update wms.docks
  set status = p_new_status, reason = p_reason, version = version + 1,
      updated_by = p_actor_id, updated_at = now(), correlation_id = coalesce(p_correlation_id, correlation_id)
  where id = p_dock_id
  returning * into v_dock;

  insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, before, after, correlation_id)
  values (v_dock.tenant_id, p_actor_id, 'wms_set_dock_status', 'dock', v_dock.id,
          v_before, to_jsonb(v_dock), p_correlation_id);

  v_cached := jsonb_build_object(
    'result', 'ok',
    'document_id', v_dock.id,
    'dock_id', v_dock.id,
    'code', v_dock.code,
    'status', v_dock.status,
    'version', v_dock.version,
    'warnings', '[]'::jsonb,
    'next_actions', case when v_dock.status = 'CLOSED'
      then jsonb_build_array('set_dock_status')
      else jsonb_build_array('schedule_dock_appointment') end
  );
  if p_idempotency_key is not null then
    insert into wms.idempotency_records (tenant_id, command_name, idempotency_key, response)
    values (v_dock.tenant_id, 'wms_set_dock_status', p_idempotency_key, v_cached)
    on conflict do nothing;
  end if;
  return v_cached;
end;
$$;

create or replace function wms.wms_schedule_dock_appointment(
  p_dock_id uuid,
  p_scheduled_start timestamptz,
  p_scheduled_end timestamptz,
  p_actor_id uuid,
  p_idempotency_key uuid,
  p_appointment_type text default 'INBOUND',
  p_po_id uuid default null,
  p_carrier_name text default null,
  p_vehicle_plate_no text default null,
  p_linked_entity_type text default null,
  p_linked_entity_id uuid default null,
  p_correlation_id text default null
) returns jsonb
language plpgsql security definer
set search_path = wms, public
as $$
declare
  v_cached jsonb;
  v_dock wms.docks%rowtype;
  v_appt wms.dock_appointments%rowtype;
  v_po wms.purchase_orders%rowtype;
  v_tenant_id text;
  v_type text := coalesce(p_appointment_type, 'INBOUND');
begin
  select tenant_id into v_tenant_id from wms.docks where id = p_dock_id;
  if p_idempotency_key is not null and v_tenant_id is not null then
    select response into v_cached from wms.idempotency_records
      where tenant_id = v_tenant_id and command_name = 'wms_schedule_dock_appointment' and idempotency_key = p_idempotency_key;
    if found then return v_cached; end if;
  end if;

  select * into v_dock from wms.docks where id = p_dock_id;
  if not found then
    raise exception 'INVALID: unknown dock %', p_dock_id;
  end if;
  if v_dock.warehouse_id not in (select wms.current_warehouse_ids(v_dock.tenant_id)) then
    raise exception 'FORBIDDEN: no warehouse scope for dock %', p_dock_id;
  end if;
  if not wms.has_role(v_dock.tenant_id, 'INBOUND_OPERATOR', 'WMS_ADMIN', 'PROCESS_AGENT') then
    raise exception 'FORBIDDEN: role cannot schedule dock appointments';
  end if;
  if v_type not in ('INBOUND', 'OUTBOUND') then
    raise exception 'INVALID: appointment_type must be INBOUND or OUTBOUND';
  end if;
  if p_scheduled_start is null or p_scheduled_end is null then
    raise exception 'INVALID: scheduled_start and scheduled_end are required';
  end if;
  if p_scheduled_end <= p_scheduled_start then
    raise exception 'INVALID: scheduled_end must be after scheduled_start';
  end if;
  if v_dock.status = 'CLOSED' then
    raise exception 'INVALID: dock % is CLOSED and cannot be booked', p_dock_id;
  end if;

  -- INBOUND: po_id is the contract (spec.md). OUTBOUND: a PO would be
  -- meaningless, the link goes through linked_entity_* instead (D3-AMENDED).
  if v_type = 'INBOUND' then
    if p_po_id is null then
      raise exception 'INVALID: po_id is required for an INBOUND appointment';
    end if;
    select * into v_po from wms.purchase_orders where id = p_po_id;
    if not found then
      raise exception 'INVALID: unknown po %', p_po_id;
    end if;
    if v_po.tenant_id <> v_dock.tenant_id or v_po.warehouse_id <> v_dock.warehouse_id then
      raise exception 'INVALID: po % does not belong to the warehouse of dock %', p_po_id, p_dock_id;
    end if;
  else
    if p_po_id is not null then
      raise exception 'INVALID: po_id must be null for an OUTBOUND appointment (use linked_entity_type/linked_entity_id)';
    end if;
  end if;

  if (p_linked_entity_type is null) <> (p_linked_entity_id is null) then
    raise exception 'INVALID: linked_entity_type and linked_entity_id must be given together';
  end if;
  -- The one interpreted linked_entity_type (D3-AMENDED). Every other value is
  -- stored verbatim and never joined on.
  if p_linked_entity_type = 'outbound_order' then
    if not exists (
      select 1 from wms.outbound_orders o
      where o.id = p_linked_entity_id
        and o.tenant_id = v_dock.tenant_id
        and o.warehouse_id = v_dock.warehouse_id
    ) then
      raise exception 'INVALID: unknown outbound_order % in the warehouse of dock %', p_linked_entity_id, p_dock_id;
    end if;
  end if;

  begin
    insert into wms.dock_appointments (
      tenant_id, warehouse_id, dock_id, appointment_type, po_id,
      linked_entity_type, linked_entity_id, carrier_name, vehicle_plate_no,
      scheduled_start, scheduled_end, status, correlation_id, created_by, updated_by
    ) values (
      v_dock.tenant_id, v_dock.warehouse_id, v_dock.id, v_type, p_po_id,
      p_linked_entity_type, p_linked_entity_id, p_carrier_name, p_vehicle_plate_no,
      p_scheduled_start, p_scheduled_end, 'SCHEDULED', p_correlation_id, p_actor_id, p_actor_id
    )
    returning * into v_appt;
  exception
    -- D1: SQLSTATE 23P01. The storage engine already rolled the INSERT back;
    -- translate it into the CONFLICT: class callers map to HTTP 409.
    when exclusion_violation then
      raise exception 'CONFLICT: dock % already has an active appointment overlapping [%, %)',
        v_dock.code, p_scheduled_start, p_scheduled_end;
  end;

  insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, before, after, correlation_id)
  values (v_appt.tenant_id, p_actor_id, 'wms_schedule_dock_appointment', 'dock_appointment', v_appt.id,
          null, to_jsonb(v_appt), p_correlation_id);

  v_cached := jsonb_build_object(
    'result', 'ok',
    'document_id', v_appt.id,
    'appointment_id', v_appt.id,
    'dock_id', v_dock.id,
    'dock_code', v_dock.code,
    'dock_status', v_dock.status,
    'appointment_type', v_appt.appointment_type,
    'scheduled_start', v_appt.scheduled_start,
    'scheduled_end', v_appt.scheduled_end,
    'status', v_appt.status,
    'version', v_appt.version,
    'warnings', '[]'::jsonb,
    'next_actions', jsonb_build_array('check_in_vehicle', 'cancel_dock_appointment')
  );
  if p_idempotency_key is not null then
    insert into wms.idempotency_records (tenant_id, command_name, idempotency_key, response)
    values (v_appt.tenant_id, 'wms_schedule_dock_appointment', p_idempotency_key, v_cached)
    on conflict do nothing;
  end if;
  return v_cached;
end;
$$;

create or replace function wms.wms_cancel_dock_appointment(
  p_appointment_id uuid,
  p_actor_id uuid,
  p_idempotency_key uuid,
  p_expected_version int,
  p_reason text default null,
  p_correlation_id text default null
) returns jsonb
language plpgsql security definer
set search_path = wms, public
as $$
declare
  v_cached jsonb;
  v_appt wms.dock_appointments%rowtype;
  v_before jsonb;
  v_tenant_id text;
begin
  select tenant_id into v_tenant_id from wms.dock_appointments where id = p_appointment_id;
  if p_idempotency_key is not null and v_tenant_id is not null then
    select response into v_cached from wms.idempotency_records
      where tenant_id = v_tenant_id and command_name = 'wms_cancel_dock_appointment' and idempotency_key = p_idempotency_key;
    if found then return v_cached; end if;
  end if;

  v_appt := wms._wms_load_dock_appointment(
    p_appointment_id, p_expected_version,
    array['INBOUND_OPERATOR', 'WMS_ADMIN', 'PROCESS_AGENT']);

  if v_appt.status not in ('SCHEDULED', 'CHECKED_IN') then
    raise exception 'INVALID: appointment % cannot be cancelled (status=%)', p_appointment_id, v_appt.status;
  end if;

  v_before := to_jsonb(v_appt);

  update wms.dock_appointments
  set status = 'CANCELLED', reason = p_reason, version = version + 1,
      updated_by = p_actor_id, updated_at = now(),
      correlation_id = coalesce(p_correlation_id, correlation_id)
  where id = p_appointment_id
  returning * into v_appt;

  insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, before, after, correlation_id)
  values (v_appt.tenant_id, p_actor_id, 'wms_cancel_dock_appointment', 'dock_appointment', v_appt.id,
          v_before, to_jsonb(v_appt), p_correlation_id);

  v_cached := jsonb_build_object(
    'result', 'ok',
    'document_id', v_appt.id,
    'appointment_id', v_appt.id,
    'dock_id', v_appt.dock_id,
    'status', v_appt.status,
    'version', v_appt.version,
    -- D1: the exclusion predicate drops CANCELLED rows, so the slot is free
    -- again the moment this commits.
    'warnings', '[]'::jsonb,
    'next_actions', jsonb_build_array('schedule_dock_appointment', 'get_dock_schedule')
  );
  if p_idempotency_key is not null then
    insert into wms.idempotency_records (tenant_id, command_name, idempotency_key, response)
    values (v_appt.tenant_id, 'wms_cancel_dock_appointment', p_idempotency_key, v_cached)
    on conflict do nothing;
  end if;
  return v_cached;
end;
$$;

-- Yard entry. Explicitly does NOT touch the dock — the truck is inside the
-- gate but has not backed onto a door yet (spec.md).
create or replace function wms.wms_check_in_vehicle(
  p_appointment_id uuid,
  p_actor_id uuid,
  p_idempotency_key uuid,
  p_expected_version int,
  p_carrier_name text default null,
  p_vehicle_plate_no text default null,
  p_correlation_id text default null
) returns jsonb
language plpgsql security definer
set search_path = wms, public
as $$
declare
  v_cached jsonb;
  v_appt wms.dock_appointments%rowtype;
  v_before jsonb;
  v_dock wms.docks%rowtype;
  v_tenant_id text;
begin
  select tenant_id into v_tenant_id from wms.dock_appointments where id = p_appointment_id;
  if p_idempotency_key is not null and v_tenant_id is not null then
    select response into v_cached from wms.idempotency_records
      where tenant_id = v_tenant_id and command_name = 'wms_check_in_vehicle' and idempotency_key = p_idempotency_key;
    if found then return v_cached; end if;
  end if;

  v_appt := wms._wms_load_dock_appointment(
    p_appointment_id, p_expected_version,
    array['INBOUND_OPERATOR', 'WMS_ADMIN']);

  if v_appt.status <> 'SCHEDULED' then
    raise exception 'INVALID: appointment % is not SCHEDULED (status=%)', p_appointment_id, v_appt.status;
  end if;

  v_before := to_jsonb(v_appt);

  update wms.dock_appointments
  set status = 'CHECKED_IN',
      checked_in_at = now(),
      carrier_name = coalesce(p_carrier_name, carrier_name),
      vehicle_plate_no = coalesce(p_vehicle_plate_no, vehicle_plate_no),
      version = version + 1, updated_by = p_actor_id, updated_at = now(),
      correlation_id = coalesce(p_correlation_id, correlation_id)
  where id = p_appointment_id
  returning * into v_appt;

  select * into v_dock from wms.docks where id = v_appt.dock_id;

  insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, before, after, correlation_id)
  values (v_appt.tenant_id, p_actor_id, 'wms_check_in_vehicle', 'dock_appointment', v_appt.id,
          v_before, to_jsonb(v_appt), p_correlation_id);

  v_cached := jsonb_build_object(
    'result', 'ok',
    'document_id', v_appt.id,
    'appointment_id', v_appt.id,
    'dock_id', v_appt.dock_id,
    -- unchanged by design: check-in is a yard event, not a door event
    'dock_status', v_dock.status,
    'status', v_appt.status,
    'version', v_appt.version,
    'vehicle_plate_no', v_appt.vehicle_plate_no,
    'warnings', case when v_dock.status = 'OCCUPIED'
      then jsonb_build_array('DOCK_CURRENTLY_OCCUPIED')
      else '[]'::jsonb end,
    'next_actions', jsonb_build_array('dock_vehicle', 'cancel_dock_appointment')
  );
  if p_idempotency_key is not null then
    insert into wms.idempotency_records (tenant_id, command_name, idempotency_key, response)
    values (v_appt.tenant_id, 'wms_check_in_vehicle', p_idempotency_key, v_cached)
    on conflict do nothing;
  end if;
  return v_cached;
end;
$$;

-- D4: the appointment and the dock move together, in one transaction.
create or replace function wms.wms_dock_vehicle(
  p_appointment_id uuid,
  p_actor_id uuid,
  p_idempotency_key uuid,
  p_expected_version int,
  p_correlation_id text default null
) returns jsonb
language plpgsql security definer
set search_path = wms, public
as $$
declare
  v_cached jsonb;
  v_appt wms.dock_appointments%rowtype;
  v_before jsonb;
  v_dock wms.docks%rowtype;
  v_dock_before jsonb;
  v_tenant_id text;
begin
  select tenant_id into v_tenant_id from wms.dock_appointments where id = p_appointment_id;
  if p_idempotency_key is not null and v_tenant_id is not null then
    select response into v_cached from wms.idempotency_records
      where tenant_id = v_tenant_id and command_name = 'wms_dock_vehicle' and idempotency_key = p_idempotency_key;
    if found then return v_cached; end if;
  end if;

  v_appt := wms._wms_load_dock_appointment(
    p_appointment_id, p_expected_version,
    array['INBOUND_OPERATOR', 'WMS_ADMIN']);

  if v_appt.status <> 'CHECKED_IN' then
    raise exception 'INVALID: appointment % is not CHECKED_IN (status=%)', p_appointment_id, v_appt.status;
  end if;

  -- lock the door before reading its status, so two trucks checked in against
  -- the same dock cannot both see AVAILABLE
  select * into v_dock from wms.docks where id = v_appt.dock_id for update;
  if v_dock.status = 'OCCUPIED' then
    raise exception 'INVALID: dock % is already OCCUPIED', v_dock.code;
  end if;
  if v_dock.status = 'CLOSED' then
    raise exception 'INVALID: dock % is CLOSED', v_dock.code;
  end if;

  v_before := to_jsonb(v_appt);
  v_dock_before := to_jsonb(v_dock);

  update wms.dock_appointments
  set status = 'AT_DOCK', docked_at = now(), version = version + 1,
      updated_by = p_actor_id, updated_at = now(),
      correlation_id = coalesce(p_correlation_id, correlation_id)
  where id = p_appointment_id
  returning * into v_appt;

  update wms.docks
  set status = 'OCCUPIED', version = version + 1, updated_by = p_actor_id, updated_at = now()
  where id = v_dock.id
  returning * into v_dock;

  insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, before, after, correlation_id)
  values (v_appt.tenant_id, p_actor_id, 'wms_dock_vehicle', 'dock_appointment', v_appt.id,
          v_before, to_jsonb(v_appt), p_correlation_id);
  insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, before, after, correlation_id)
  values (v_dock.tenant_id, p_actor_id, 'wms_dock_vehicle', 'dock', v_dock.id,
          v_dock_before, to_jsonb(v_dock), p_correlation_id);

  v_cached := jsonb_build_object(
    'result', 'ok',
    'document_id', v_appt.id,
    'appointment_id', v_appt.id,
    'dock_id', v_dock.id,
    'dock_code', v_dock.code,
    'dock_status', v_dock.status,
    'dock_version', v_dock.version,
    'status', v_appt.status,
    'version', v_appt.version,
    'warnings', '[]'::jsonb,
    -- D2: register_arrival is a separate aggregate. Suggesting it here is
    -- operational advice, not a precondition this contract enforces.
    'next_actions', jsonb_build_array('depart_vehicle', 'register_arrival')
  );
  if p_idempotency_key is not null then
    insert into wms.idempotency_records (tenant_id, command_name, idempotency_key, response)
    values (v_appt.tenant_id, 'wms_dock_vehicle', p_idempotency_key, v_cached)
    on conflict do nothing;
  end if;
  return v_cached;
end;
$$;

create or replace function wms.wms_depart_vehicle(
  p_appointment_id uuid,
  p_actor_id uuid,
  p_idempotency_key uuid,
  p_expected_version int,
  p_correlation_id text default null
) returns jsonb
language plpgsql security definer
set search_path = wms, public
as $$
declare
  v_cached jsonb;
  v_appt wms.dock_appointments%rowtype;
  v_before jsonb;
  v_dock wms.docks%rowtype;
  v_dock_before jsonb;
  v_warnings jsonb := '[]'::jsonb;
  v_tenant_id text;
begin
  select tenant_id into v_tenant_id from wms.dock_appointments where id = p_appointment_id;
  if p_idempotency_key is not null and v_tenant_id is not null then
    select response into v_cached from wms.idempotency_records
      where tenant_id = v_tenant_id and command_name = 'wms_depart_vehicle' and idempotency_key = p_idempotency_key;
    if found then return v_cached; end if;
  end if;

  v_appt := wms._wms_load_dock_appointment(
    p_appointment_id, p_expected_version,
    array['INBOUND_OPERATOR', 'WMS_ADMIN']);

  if v_appt.status <> 'AT_DOCK' then
    raise exception 'INVALID: appointment % is not AT_DOCK (status=%)', p_appointment_id, v_appt.status;
  end if;

  select * into v_dock from wms.docks where id = v_appt.dock_id for update;
  v_before := to_jsonb(v_appt);
  v_dock_before := to_jsonb(v_dock);

  update wms.dock_appointments
  set status = 'DEPARTED', departed_at = now(), version = version + 1,
      updated_by = p_actor_id, updated_at = now(),
      correlation_id = coalesce(p_correlation_id, correlation_id)
  where id = p_appointment_id
  returning * into v_appt;

  -- spec.md: if an admin closed the door while the truck was on it, departure
  -- must not silently re-open it for maintenance.
  if v_dock.status = 'CLOSED' then
    v_warnings := jsonb_build_array('DOCK_CLOSED_NOT_RELEASED');
  else
    update wms.docks
    set status = 'AVAILABLE', version = version + 1, updated_by = p_actor_id, updated_at = now()
    where id = v_dock.id
    returning * into v_dock;

    insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, before, after, correlation_id)
    values (v_dock.tenant_id, p_actor_id, 'wms_depart_vehicle', 'dock', v_dock.id,
            v_dock_before, to_jsonb(v_dock), p_correlation_id);
  end if;

  insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, before, after, correlation_id)
  values (v_appt.tenant_id, p_actor_id, 'wms_depart_vehicle', 'dock_appointment', v_appt.id,
          v_before, to_jsonb(v_appt), p_correlation_id);

  v_cached := jsonb_build_object(
    'result', 'ok',
    'document_id', v_appt.id,
    'appointment_id', v_appt.id,
    'dock_id', v_dock.id,
    'dock_code', v_dock.code,
    'dock_status', v_dock.status,
    'dock_version', v_dock.version,
    'status', v_appt.status,
    'version', v_appt.version,
    'warnings', v_warnings,
    'next_actions', jsonb_build_array('get_dock_schedule', 'schedule_dock_appointment')
  );
  if p_idempotency_key is not null then
    insert into wms.idempotency_records (tenant_id, command_name, idempotency_key, response)
    values (v_appt.tenant_id, 'wms_depart_vehicle', p_idempotency_key, v_cached)
    on conflict do nothing;
  end if;
  return v_cached;
end;
$$;

-- Read-only schedule board: every dock in the warehouse with the appointments
-- whose window intersects [from, to). Mirrors wms_get_equipment_status's shape
-- (stable security definer with an explicit warehouse-scope guard).
create or replace function wms.wms_get_dock_schedule(
  p_tenant_id text,
  p_warehouse_id uuid,
  p_from timestamptz default null,
  p_to timestamptz default null,
  p_dock_id uuid default null,
  p_include_closed boolean default true
) returns jsonb
language plpgsql stable security definer
set search_path = wms, public
as $$
declare
  v_range tstzrange := tstzrange(p_from, p_to, '[)');
  v_docks jsonb;
  v_appt_count int;
begin
  if p_warehouse_id not in (select wms.current_warehouse_ids(p_tenant_id)) then
    raise exception 'FORBIDDEN: no warehouse scope for %', p_warehouse_id;
  end if;

  select coalesce(jsonb_agg(item order by item->>'code'), '[]'::jsonb)
  into v_docks
  from (
    select jsonb_build_object(
      'dock_id', d.id,
      'code', d.code,
      'name', d.name,
      'status', d.status,
      'version', d.version,
      'reason', d.reason,
      'appointments', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'appointment_id', a.id,
          'dock_id', a.dock_id,
          'appointment_type', a.appointment_type,
          'po_id', a.po_id,
          'linked_entity_type', a.linked_entity_type,
          'linked_entity_id', a.linked_entity_id,
          'carrier_name', a.carrier_name,
          'vehicle_plate_no', a.vehicle_plate_no,
          'scheduled_start', a.scheduled_start,
          'scheduled_end', a.scheduled_end,
          'status', a.status,
          'version', a.version,
          'checked_in_at', a.checked_in_at,
          'docked_at', a.docked_at,
          'departed_at', a.departed_at,
          'reason', a.reason,
          'is_active', a.status in ('SCHEDULED', 'CHECKED_IN', 'AT_DOCK')
        ) order by a.scheduled_start), '[]'::jsonb)
        from wms.dock_appointments a
        where a.dock_id = d.id
          and a.during && v_range
      )
    ) as item
    from wms.docks d
    where d.tenant_id = p_tenant_id
      and d.warehouse_id = p_warehouse_id
      and (p_dock_id is null or d.id = p_dock_id)
      and (p_include_closed or d.status <> 'CLOSED')
  ) rows;

  select count(*) into v_appt_count
  from wms.dock_appointments a
  join wms.docks d on d.id = a.dock_id
  where d.tenant_id = p_tenant_id
    and d.warehouse_id = p_warehouse_id
    and (p_dock_id is null or d.id = p_dock_id)
    and a.during && v_range;

  return jsonb_build_object(
    'result', 'ok',
    'tenant_id', p_tenant_id,
    'warehouse_id', p_warehouse_id,
    'from', p_from,
    'to', p_to,
    'docks', v_docks,
    'dock_count', jsonb_array_length(v_docks),
    'appointment_count', v_appt_count
  );
end;
$$;

grant execute on function wms.wms_register_dock(text, uuid, text, text, uuid, uuid, text) to authenticated;
grant execute on function wms.wms_set_dock_status(uuid, text, uuid, uuid, int, text, text) to authenticated;
grant execute on function wms.wms_schedule_dock_appointment(uuid, timestamptz, timestamptz, uuid, uuid, text, uuid, text, text, text, uuid, text) to authenticated;
grant execute on function wms.wms_cancel_dock_appointment(uuid, uuid, uuid, int, text, text) to authenticated;
grant execute on function wms.wms_check_in_vehicle(uuid, uuid, uuid, int, text, text, text) to authenticated;
grant execute on function wms.wms_dock_vehicle(uuid, uuid, uuid, int, text) to authenticated;
grant execute on function wms.wms_depart_vehicle(uuid, uuid, uuid, int, text) to authenticated;
grant execute on function wms.wms_get_dock_schedule(text, uuid, timestamptz, timestamptz, uuid, boolean) to authenticated;

-- _wms_load_dock_appointment is an internal helper: no grant, exactly like
-- wms._wms_finalize_disposition in the core schema.
