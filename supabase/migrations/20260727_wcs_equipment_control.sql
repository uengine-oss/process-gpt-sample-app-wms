-- ============================================================
-- WCS equipment-control contract
-- Scope: openspec/changes/add-wcs-equipment-control-contract
--        (proposal.md / design.md / specs/wms_wcs-equipment-control/spec.md)
--
-- Adds an automation-equipment registry, a command dispatch log, an
-- append-only status/event feed, and a fault log to the existing `wms`
-- schema. Conventions (schema, common columns, RLS helpers, RPC envelope,
-- CONFLICT:/FORBIDDEN:/INVALID: error prefixes, idempotency records, audit
-- events) are identical to 20260726_wms_core_schema.sql — that file is not
-- modified by this migration.
--
-- This contract does NOT drive real PLC/fieldbus hardware. Whoever fills it
-- (a real WCS/PLC gateway or a software simulator) only has to honour these
-- RPCs. See design.md "Non-Goals".
-- ============================================================

-- ------------------------------------------------------------
-- Tables
--
-- Common columns for the three state-bearing tables (design.md D1):
--   id / tenant_id / warehouse_id / status / version /
--   created_at / created_by / updated_at / updated_by / correlation_id
-- `wms.equipment_status_events` is append-only (like
-- wms.stock_ledger_entries) so it carries no status/version/updated_*.
-- ------------------------------------------------------------

create table wms.equipment (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references wms.tenants(id) on delete cascade,
  warehouse_id uuid not null references wms.warehouses(id) on delete cascade,
  equipment_code text not null,
  equipment_type text not null
    check (equipment_type in ('SRM', 'CONVEYOR', 'SORTER', 'AGV', 'AMR', 'ROBOT_CELL')),
  zone_code text,
  status text not null default 'OFFLINE'
    check (status in ('OFFLINE', 'IDLE', 'RUNNING', 'FAULT', 'MAINTENANCE')),
  version int not null default 1,
  correlation_id text,
  created_by uuid,
  updated_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (warehouse_id, equipment_code)
);

create table wms.equipment_faults (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references wms.tenants(id) on delete cascade,
  warehouse_id uuid not null references wms.warehouses(id) on delete cascade,
  equipment_id uuid not null references wms.equipment(id) on delete cascade,
  fault_code text not null,
  severity text not null check (severity in ('WARNING', 'CRITICAL', 'BLOCKING')),
  status text not null default 'OPEN' check (status in ('OPEN', 'RESOLVED')),
  raised_by uuid,
  resolution_note text,
  resolved_by uuid,
  resolved_at timestamptz,
  version int not null default 1,
  correlation_id text,
  created_by uuid,
  updated_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table wms.equipment_commands (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references wms.tenants(id) on delete cascade,
  warehouse_id uuid not null references wms.warehouses(id) on delete cascade,
  equipment_id uuid not null references wms.equipment(id) on delete cascade,
  -- open set on purpose (design.md D7): follow-up specs extend this list
  -- (e.g. DIVERT / SET_SPEED for sorters) without changing table shape.
  command_type text not null
    check (command_type in ('MOVE', 'LOAD', 'UNLOAD', 'START', 'STOP', 'RESET', 'HOLD', 'RESUME')),
  payload jsonb not null default '{}'::jsonb,
  status text not null default 'PENDING'
    check (status in ('PENDING', 'ACKNOWLEDGED', 'IN_PROGRESS', 'COMPLETED', 'FAILED', 'REJECTED', 'CANCELLED')),
  -- loose reference to the WMS-side work this command serves (design.md D6):
  -- deliberately not a FK, so follow-up specs only add new type values.
  linked_entity_type text,
  linked_entity_id uuid,
  fault_id uuid references wms.equipment_faults(id) on delete set null,
  reason text,
  version int not null default 1,
  correlation_id text,
  created_by uuid,
  updated_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table wms.equipment_status_events (
  id uuid primary key default gen_random_uuid(),
  -- monotonic tiebreaker: several events can share one created_at when a
  -- single RPC emits them in the same transaction (e.g. raise_fault emits
  -- COMMAND_FAILED then FAULT_RAISED). Monitoring feeds order by this.
  seq bigserial not null,
  tenant_id uuid not null references wms.tenants(id) on delete cascade,
  warehouse_id uuid not null references wms.warehouses(id) on delete cascade,
  equipment_id uuid not null references wms.equipment(id) on delete cascade,
  command_id uuid references wms.equipment_commands(id) on delete set null,
  -- COMMAND_CANCELLED extends design.md's list so the monitoring feed also
  -- shows operator-initiated cancellations (wms_cancel_equipment_command).
  event_type text not null check (event_type in (
    'STATUS_CHANGED', 'COMMAND_ACKNOWLEDGED', 'COMMAND_PROGRESS', 'COMMAND_COMPLETED',
    'COMMAND_FAILED', 'COMMAND_CANCELLED', 'FAULT_RAISED', 'FAULT_CLEARED')),
  previous_status text,
  new_status text,
  detail jsonb,
  reported_by uuid,
  correlation_id text,
  created_at timestamptz not null default now()
);

create index equipment_commands_equipment_status_idx
  on wms.equipment_commands (equipment_id, status);
create index equipment_status_events_equipment_seq_idx
  on wms.equipment_status_events (equipment_id, seq desc);
create index equipment_faults_equipment_status_idx
  on wms.equipment_faults (equipment_id, status);

-- ============================================================
-- RLS: SELECT-only for tenant/warehouse members. Every write goes through
-- the SECURITY DEFINER RPCs below — no INSERT/UPDATE/DELETE policy is
-- granted to authenticated/anon, so RLS denies those by default
-- (20260726_wms_core_schema.sql / design.md D3).
-- ============================================================

alter table wms.equipment enable row level security;
create policy equipment_select on wms.equipment for select to authenticated
  using (warehouse_id in (select wms.current_warehouse_ids(tenant_id)));

alter table wms.equipment_commands enable row level security;
create policy equipment_commands_select on wms.equipment_commands for select to authenticated
  using (warehouse_id in (select wms.current_warehouse_ids(tenant_id)));

alter table wms.equipment_status_events enable row level security;
create policy equipment_status_events_select on wms.equipment_status_events for select to authenticated
  using (warehouse_id in (select wms.current_warehouse_ids(tenant_id)));

alter table wms.equipment_faults enable row level security;
create policy equipment_faults_select on wms.equipment_faults for select to authenticated
  using (warehouse_id in (select wms.current_warehouse_ids(tenant_id)));

grant select on wms.equipment to authenticated;
grant select on wms.equipment_commands to authenticated;
grant select on wms.equipment_status_events to authenticated;
grant select on wms.equipment_faults to authenticated;

-- ============================================================
-- Internal helpers
-- ============================================================

-- Derives the equipment status implied by its outstanding commands and
-- applies it if it differs. Returns the (possibly unchanged) equipment row.
-- Never overrides FAULT/MAINTENANCE/OFFLINE — those are set explicitly.
create or replace function wms._wms_sync_equipment_activity(
  p_equipment_id uuid,
  p_actor_id uuid,
  p_correlation_id text default null,
  p_command_id uuid default null
) returns wms.equipment
language plpgsql security definer
set search_path = wms, public
as $$
declare
  v_equipment wms.equipment%rowtype;
  v_has_active boolean;
  v_target text;
begin
  select * into v_equipment from wms.equipment where id = p_equipment_id;
  if v_equipment.status not in ('RUNNING', 'IDLE') then
    return v_equipment;
  end if;

  select exists (
    select 1 from wms.equipment_commands
    where equipment_id = p_equipment_id and status in ('PENDING', 'ACKNOWLEDGED', 'IN_PROGRESS')
  ) into v_has_active;

  v_target := case when v_has_active then 'RUNNING' else 'IDLE' end;
  if v_target = v_equipment.status then
    return v_equipment;
  end if;

  insert into wms.equipment_status_events (
    tenant_id, warehouse_id, equipment_id, command_id, event_type,
    previous_status, new_status, reported_by, correlation_id
  ) values (
    v_equipment.tenant_id, v_equipment.warehouse_id, v_equipment.id, p_command_id, 'STATUS_CHANGED',
    v_equipment.status, v_target, p_actor_id, p_correlation_id
  );

  update wms.equipment
  set status = v_target, version = version + 1, updated_by = p_actor_id, updated_at = now()
  where id = p_equipment_id
  returning * into v_equipment;

  return v_equipment;
end;
$$;

-- ============================================================
-- Command RPCs
-- Envelope in:  tenant_id / warehouse_id (implied by the target row for
--               id-addressed calls), actor_id, idempotency_key,
--               expected_version, correlation_id.
-- Envelope out: {result, document_id, status, version, next_actions, ...}.
-- Errors:       RAISE EXCEPTION with CONFLICT:/FORBIDDEN:/INVALID: prefix.
-- ============================================================

create or replace function wms.wms_register_equipment(
  p_tenant_id uuid,
  p_warehouse_id uuid,
  p_equipment_code text,
  p_equipment_type text,
  p_zone_code text,
  p_actor_id uuid,
  p_idempotency_key uuid,
  p_correlation_id text default null
) returns jsonb
language plpgsql security definer
set search_path = wms, public
as $$
declare
  v_cached jsonb;
  v_equipment wms.equipment%rowtype;
begin
  if p_idempotency_key is not null then
    select response into v_cached from wms.idempotency_records
      where tenant_id = p_tenant_id and command_name = 'wms_register_equipment' and idempotency_key = p_idempotency_key;
    if found then return v_cached; end if;
  end if;

  if p_warehouse_id not in (select wms.current_warehouse_ids(p_tenant_id)) then
    raise exception 'FORBIDDEN: no warehouse scope for %', p_warehouse_id;
  end if;
  if not wms.has_role(p_tenant_id, 'WMS_ADMIN', 'WAREHOUSE_MANAGER') then
    raise exception 'FORBIDDEN: role cannot register equipment';
  end if;
  if p_equipment_code is null or btrim(p_equipment_code) = '' then
    raise exception 'INVALID: equipment_code is required';
  end if;
  if p_equipment_type not in ('SRM', 'CONVEYOR', 'SORTER', 'AGV', 'AMR', 'ROBOT_CELL') then
    raise exception 'INVALID: unknown equipment_type %', p_equipment_type;
  end if;
  if exists (select 1 from wms.equipment where warehouse_id = p_warehouse_id and equipment_code = p_equipment_code) then
    raise exception 'INVALID: equipment_code % already registered in warehouse %', p_equipment_code, p_warehouse_id;
  end if;

  insert into wms.equipment (
    tenant_id, warehouse_id, equipment_code, equipment_type, zone_code,
    status, correlation_id, created_by, updated_by
  ) values (
    p_tenant_id, p_warehouse_id, p_equipment_code, p_equipment_type, p_zone_code,
    'OFFLINE', p_correlation_id, p_actor_id, p_actor_id
  )
  returning * into v_equipment;

  insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, before, after, correlation_id)
  values (p_tenant_id, p_actor_id, 'wms_register_equipment', 'equipment', v_equipment.id, null, to_jsonb(v_equipment), p_correlation_id);

  v_cached := jsonb_build_object(
    'result', 'ok',
    'document_id', v_equipment.id,
    'equipment_id', v_equipment.id,
    'status', v_equipment.status,
    'version', v_equipment.version,
    'next_actions', jsonb_build_array('report_equipment_status', 'dispatch_equipment_command')
  );
  if p_idempotency_key is not null then
    insert into wms.idempotency_records (tenant_id, command_name, idempotency_key, response)
    values (p_tenant_id, 'wms_register_equipment', p_idempotency_key, v_cached)
    on conflict do nothing;
  end if;
  return v_cached;
end;
$$;

-- expected_version is the EQUIPMENT version (design.md D3).
create or replace function wms.wms_dispatch_equipment_command(
  p_equipment_id uuid,
  p_command_type text,
  p_payload jsonb,
  p_actor_id uuid,
  p_idempotency_key uuid,
  p_expected_version int,
  p_correlation_id text default null,
  p_linked_entity_type text default null,
  p_linked_entity_id uuid default null
) returns jsonb
language plpgsql security definer
set search_path = wms, public
as $$
declare
  v_cached jsonb;
  v_equipment wms.equipment%rowtype;
  v_command wms.equipment_commands%rowtype;
  v_tenant_id uuid;
begin
  select tenant_id into v_tenant_id from wms.equipment where id = p_equipment_id;
  if p_idempotency_key is not null and v_tenant_id is not null then
    select response into v_cached from wms.idempotency_records
      where tenant_id = v_tenant_id and command_name = 'wms_dispatch_equipment_command' and idempotency_key = p_idempotency_key;
    if found then return v_cached; end if;
  end if;

  select * into v_equipment from wms.equipment where id = p_equipment_id;
  if not found then
    raise exception 'INVALID: unknown equipment %', p_equipment_id;
  end if;
  if v_equipment.warehouse_id not in (select wms.current_warehouse_ids(v_equipment.tenant_id)) then
    raise exception 'FORBIDDEN: no warehouse scope for equipment %', p_equipment_id;
  end if;
  if not wms.has_role(v_equipment.tenant_id, 'WAREHOUSE_MANAGER', 'WCS_OPERATOR', 'PROCESS_AGENT') then
    raise exception 'FORBIDDEN: role cannot dispatch equipment commands';
  end if;
  if v_equipment.version <> p_expected_version then
    raise exception 'CONFLICT: expected version % but found %', p_expected_version, v_equipment.version;
  end if;
  if p_command_type not in ('MOVE', 'LOAD', 'UNLOAD', 'START', 'STOP', 'RESET', 'HOLD', 'RESUME') then
    raise exception 'INVALID: unknown command_type %', p_command_type;
  end if;
  if v_equipment.status = 'FAULT' then
    raise exception 'INVALID: equipment % is in FAULT and cannot accept new commands', p_equipment_id;
  end if;
  if v_equipment.status = 'MAINTENANCE' then
    raise exception 'INVALID: equipment % is in MAINTENANCE and cannot accept new commands', p_equipment_id;
  end if;

  insert into wms.equipment_commands (
    tenant_id, warehouse_id, equipment_id, command_type, payload, status,
    linked_entity_type, linked_entity_id, correlation_id, created_by, updated_by
  ) values (
    v_equipment.tenant_id, v_equipment.warehouse_id, v_equipment.id, p_command_type,
    coalesce(p_payload, '{}'::jsonb), 'PENDING',
    p_linked_entity_type, p_linked_entity_id, p_correlation_id, p_actor_id, p_actor_id
  )
  returning * into v_command;

  -- an outstanding command means the equipment is now busy; keeps
  -- "다른 진행 중 명령이 없으면 IDLE" in wms_report_command_result meaningful.
  v_equipment := wms._wms_sync_equipment_activity(v_equipment.id, p_actor_id, p_correlation_id, v_command.id);

  insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, before, after, correlation_id)
  values (v_command.tenant_id, p_actor_id, 'wms_dispatch_equipment_command', 'equipment_command', v_command.id,
          null, to_jsonb(v_command), p_correlation_id);

  v_cached := jsonb_build_object(
    'result', 'ok',
    'document_id', v_command.id,
    'command_id', v_command.id,
    'equipment_id', v_equipment.id,
    'status', v_command.status,
    'version', v_command.version,
    'equipment_status', v_equipment.status,
    'equipment_version', v_equipment.version,
    'next_actions', jsonb_build_array('report_command_result', 'cancel_equipment_command')
  );
  if p_idempotency_key is not null then
    insert into wms.idempotency_records (tenant_id, command_name, idempotency_key, response)
    values (v_command.tenant_id, 'wms_dispatch_equipment_command', p_idempotency_key, v_cached)
    on conflict do nothing;
  end if;
  return v_cached;
end;
$$;

-- expected_version is the COMMAND version (design.md D3).
-- Params with defaults are moved to the tail of the signature (Postgres
-- requires it); callers use named arguments, so the order is not load-bearing.
create or replace function wms.wms_report_command_result(
  p_command_id uuid,
  p_command_status text,
  p_actor_id uuid,
  p_idempotency_key uuid,
  p_expected_version int,
  p_detail jsonb default null,
  p_correlation_id text default null
) returns jsonb
language plpgsql security definer
set search_path = wms, public
as $$
declare
  v_cached jsonb;
  v_command wms.equipment_commands%rowtype;
  v_before jsonb;
  v_equipment wms.equipment%rowtype;
  v_tenant_id uuid;
  v_event_type text;
begin
  select tenant_id into v_tenant_id from wms.equipment_commands where id = p_command_id;
  if p_idempotency_key is not null and v_tenant_id is not null then
    select response into v_cached from wms.idempotency_records
      where tenant_id = v_tenant_id and command_name = 'wms_report_command_result' and idempotency_key = p_idempotency_key;
    if found then return v_cached; end if;
  end if;

  select * into v_command from wms.equipment_commands where id = p_command_id;
  if not found then
    raise exception 'INVALID: unknown equipment command %', p_command_id;
  end if;
  if v_command.warehouse_id not in (select wms.current_warehouse_ids(v_command.tenant_id)) then
    raise exception 'FORBIDDEN: no warehouse scope for command %', p_command_id;
  end if;
  -- gateway-side feedback only: PROCESS_AGENT deliberately excluded
  -- (design.md "역할 모델 확장" / spec.md "역할이 없는 사용자는 상태 보고를 할 수 없다").
  if not wms.has_role(v_command.tenant_id, 'WCS_GATEWAY', 'WMS_ADMIN') then
    raise exception 'FORBIDDEN: role cannot report equipment command results';
  end if;
  if v_command.version <> p_expected_version then
    raise exception 'CONFLICT: expected version % but found %', p_expected_version, v_command.version;
  end if;
  if p_command_status not in ('ACKNOWLEDGED', 'IN_PROGRESS', 'COMPLETED', 'FAILED') then
    raise exception 'INVALID: command_status must be one of ACKNOWLEDGED, IN_PROGRESS, COMPLETED, FAILED';
  end if;
  if v_command.status in ('COMPLETED', 'FAILED', 'REJECTED', 'CANCELLED') then
    raise exception 'INVALID: command % is already terminal (status=%)', p_command_id, v_command.status;
  end if;

  v_before := to_jsonb(v_command);

  update wms.equipment_commands
  set status = p_command_status, version = version + 1, updated_by = p_actor_id, updated_at = now()
  where id = p_command_id
  returning * into v_command;

  v_event_type := case p_command_status
    when 'ACKNOWLEDGED' then 'COMMAND_ACKNOWLEDGED'
    when 'IN_PROGRESS' then 'COMMAND_PROGRESS'
    when 'COMPLETED' then 'COMMAND_COMPLETED'
    else 'COMMAND_FAILED'
  end;

  select * into v_equipment from wms.equipment where id = v_command.equipment_id;

  insert into wms.equipment_status_events (
    tenant_id, warehouse_id, equipment_id, command_id, event_type,
    previous_status, new_status, detail, reported_by, correlation_id
  ) values (
    v_command.tenant_id, v_command.warehouse_id, v_command.equipment_id, v_command.id, v_event_type,
    v_equipment.status, v_equipment.status, p_detail, p_actor_id, p_correlation_id
  );

  if p_command_status in ('COMPLETED', 'FAILED') then
    v_equipment := wms._wms_sync_equipment_activity(v_command.equipment_id, p_actor_id, p_correlation_id, v_command.id);
  end if;

  insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, before, after, correlation_id)
  values (v_command.tenant_id, p_actor_id, 'wms_report_command_result', 'equipment_command', v_command.id,
          v_before, to_jsonb(v_command), p_correlation_id);

  -- The linked WMS entity is only *notified* (audit trail); this contract
  -- never transitions it — consuming specs decide what to do (spec.md).
  if v_command.linked_entity_type is not null and v_command.linked_entity_id is not null then
    insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, before, after, correlation_id)
    values (v_command.tenant_id, p_actor_id, 'wms_report_command_result', v_command.linked_entity_type,
            v_command.linked_entity_id, null,
            jsonb_build_object('command_id', v_command.id, 'command_status', v_command.status,
                               'equipment_id', v_command.equipment_id, 'detail', p_detail),
            p_correlation_id);
  end if;

  v_cached := jsonb_build_object(
    'result', 'ok',
    'document_id', v_command.id,
    'command_id', v_command.id,
    'equipment_id', v_equipment.id,
    'status', v_command.status,
    'version', v_command.version,
    'equipment_status', v_equipment.status,
    'equipment_version', v_equipment.version,
    'next_actions', case
      when v_command.status in ('COMPLETED', 'FAILED') then jsonb_build_array('get_equipment_status')
      else jsonb_build_array('report_command_result')
    end
  );
  if p_idempotency_key is not null then
    insert into wms.idempotency_records (tenant_id, command_name, idempotency_key, response)
    values (v_command.tenant_id, 'wms_report_command_result', p_idempotency_key, v_cached)
    on conflict do nothing;
  end if;
  return v_cached;
end;
$$;

-- expected_version is the EQUIPMENT version (design.md D3).
create or replace function wms.wms_report_equipment_status(
  p_equipment_id uuid,
  p_new_status text,
  p_actor_id uuid,
  p_idempotency_key uuid,
  p_expected_version int,
  p_detail jsonb default null,
  p_correlation_id text default null
) returns jsonb
language plpgsql security definer
set search_path = wms, public
as $$
declare
  v_cached jsonb;
  v_equipment wms.equipment%rowtype;
  v_before jsonb;
  v_previous_status text;
  v_tenant_id uuid;
begin
  select tenant_id into v_tenant_id from wms.equipment where id = p_equipment_id;
  if p_idempotency_key is not null and v_tenant_id is not null then
    select response into v_cached from wms.idempotency_records
      where tenant_id = v_tenant_id and command_name = 'wms_report_equipment_status' and idempotency_key = p_idempotency_key;
    if found then return v_cached; end if;
  end if;

  select * into v_equipment from wms.equipment where id = p_equipment_id;
  if not found then
    raise exception 'INVALID: unknown equipment %', p_equipment_id;
  end if;
  if v_equipment.warehouse_id not in (select wms.current_warehouse_ids(v_equipment.tenant_id)) then
    raise exception 'FORBIDDEN: no warehouse scope for equipment %', p_equipment_id;
  end if;
  if not wms.has_role(v_equipment.tenant_id, 'WCS_GATEWAY', 'WMS_ADMIN') then
    raise exception 'FORBIDDEN: role cannot report equipment status';
  end if;
  if v_equipment.version <> p_expected_version then
    raise exception 'CONFLICT: expected version % but found %', p_expected_version, v_equipment.version;
  end if;
  if p_new_status not in ('OFFLINE', 'IDLE', 'RUNNING', 'FAULT', 'MAINTENANCE') then
    raise exception 'INVALID: unknown equipment status %', p_new_status;
  end if;
  -- FAULT is only reachable through wms_raise_equipment_fault so that the
  -- in-flight commands are always dealt with (design.md D4).
  if p_new_status = 'FAULT' then
    raise exception 'INVALID: use wms_raise_equipment_fault to move equipment into FAULT';
  end if;
  if v_equipment.status = 'FAULT' then
    raise exception 'INVALID: equipment % is in FAULT — resolve the open fault first', p_equipment_id;
  end if;

  v_before := to_jsonb(v_equipment);
  v_previous_status := v_equipment.status;

  update wms.equipment
  set status = p_new_status, version = version + 1, updated_by = p_actor_id, updated_at = now()
  where id = p_equipment_id
  returning * into v_equipment;

  insert into wms.equipment_status_events (
    tenant_id, warehouse_id, equipment_id, command_id, event_type,
    previous_status, new_status, detail, reported_by, correlation_id
  ) values (
    v_equipment.tenant_id, v_equipment.warehouse_id, v_equipment.id, null, 'STATUS_CHANGED',
    v_previous_status, v_equipment.status, p_detail, p_actor_id, p_correlation_id
  );

  insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, before, after, correlation_id)
  values (v_equipment.tenant_id, p_actor_id, 'wms_report_equipment_status', 'equipment', v_equipment.id,
          v_before, to_jsonb(v_equipment), p_correlation_id);

  v_cached := jsonb_build_object(
    'result', 'ok',
    'document_id', v_equipment.id,
    'equipment_id', v_equipment.id,
    'status', v_equipment.status,
    'version', v_equipment.version,
    'previous_status', v_previous_status,
    'next_actions', jsonb_build_array('dispatch_equipment_command', 'get_equipment_status')
  );
  if p_idempotency_key is not null then
    insert into wms.idempotency_records (tenant_id, command_name, idempotency_key, response)
    values (v_equipment.tenant_id, 'wms_report_equipment_status', p_idempotency_key, v_cached)
    on conflict do nothing;
  end if;
  return v_cached;
end;
$$;

-- Raising a fault force-fails every outstanding command on that equipment
-- (design.md D4) — retrying them is a consuming spec's responsibility.
create or replace function wms.wms_raise_equipment_fault(
  p_equipment_id uuid,
  p_fault_code text,
  p_severity text,
  p_actor_id uuid,
  p_idempotency_key uuid,
  p_correlation_id text default null
) returns jsonb
language plpgsql security definer
set search_path = wms, public
as $$
declare
  v_cached jsonb;
  v_equipment wms.equipment%rowtype;
  v_before jsonb;
  v_previous_status text;
  v_fault wms.equipment_faults%rowtype;
  v_command wms.equipment_commands%rowtype;
  v_failed uuid[] := '{}';
  v_tenant_id uuid;
begin
  select tenant_id into v_tenant_id from wms.equipment where id = p_equipment_id;
  if p_idempotency_key is not null and v_tenant_id is not null then
    select response into v_cached from wms.idempotency_records
      where tenant_id = v_tenant_id and command_name = 'wms_raise_equipment_fault' and idempotency_key = p_idempotency_key;
    if found then return v_cached; end if;
  end if;

  select * into v_equipment from wms.equipment where id = p_equipment_id;
  if not found then
    raise exception 'INVALID: unknown equipment %', p_equipment_id;
  end if;
  if v_equipment.warehouse_id not in (select wms.current_warehouse_ids(v_equipment.tenant_id)) then
    raise exception 'FORBIDDEN: no warehouse scope for equipment %', p_equipment_id;
  end if;
  if not wms.has_role(v_equipment.tenant_id, 'WCS_GATEWAY', 'WCS_OPERATOR', 'WMS_ADMIN') then
    raise exception 'FORBIDDEN: role cannot raise equipment faults';
  end if;
  if p_fault_code is null or btrim(p_fault_code) = '' then
    raise exception 'INVALID: fault_code is required';
  end if;
  if p_severity not in ('WARNING', 'CRITICAL', 'BLOCKING') then
    raise exception 'INVALID: severity must be one of WARNING, CRITICAL, BLOCKING';
  end if;

  v_before := to_jsonb(v_equipment);
  v_previous_status := v_equipment.status;

  insert into wms.equipment_faults (
    tenant_id, warehouse_id, equipment_id, fault_code, severity, status,
    raised_by, correlation_id, created_by, updated_by
  ) values (
    v_equipment.tenant_id, v_equipment.warehouse_id, v_equipment.id, p_fault_code, p_severity, 'OPEN',
    p_actor_id, p_correlation_id, p_actor_id, p_actor_id
  )
  returning * into v_fault;

  for v_command in
    select * from wms.equipment_commands
    where equipment_id = v_equipment.id and status in ('PENDING', 'ACKNOWLEDGED', 'IN_PROGRESS')
    for update
  loop
    update wms.equipment_commands
    set status = 'FAILED', fault_id = v_fault.id, version = version + 1,
        reason = coalesce(reason, 'equipment fault ' || p_fault_code),
        updated_by = p_actor_id, updated_at = now()
    where id = v_command.id;

    insert into wms.equipment_status_events (
      tenant_id, warehouse_id, equipment_id, command_id, event_type,
      previous_status, new_status, detail, reported_by, correlation_id
    ) values (
      v_command.tenant_id, v_command.warehouse_id, v_command.equipment_id, v_command.id, 'COMMAND_FAILED',
      v_previous_status, 'FAULT',
      jsonb_build_object('reason', 'EQUIPMENT_FAULT', 'fault_id', v_fault.id, 'fault_code', p_fault_code),
      p_actor_id, p_correlation_id
    );

    insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, before, after, correlation_id)
    values (v_command.tenant_id, p_actor_id, 'wms_raise_equipment_fault', 'equipment_command', v_command.id,
            to_jsonb(v_command),
            jsonb_build_object('status', 'FAILED', 'fault_id', v_fault.id), p_correlation_id);

    v_failed := v_failed || v_command.id;
  end loop;

  update wms.equipment
  set status = 'FAULT', version = version + 1, updated_by = p_actor_id, updated_at = now()
  where id = v_equipment.id
  returning * into v_equipment;

  insert into wms.equipment_status_events (
    tenant_id, warehouse_id, equipment_id, command_id, event_type,
    previous_status, new_status, detail, reported_by, correlation_id
  ) values (
    v_equipment.tenant_id, v_equipment.warehouse_id, v_equipment.id, null, 'FAULT_RAISED',
    v_previous_status, 'FAULT',
    jsonb_build_object('fault_id', v_fault.id, 'fault_code', p_fault_code, 'severity', p_severity),
    p_actor_id, p_correlation_id
  );

  insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, before, after, correlation_id)
  values (v_fault.tenant_id, p_actor_id, 'wms_raise_equipment_fault', 'equipment_fault', v_fault.id,
          v_before, to_jsonb(v_fault), p_correlation_id);

  v_cached := jsonb_build_object(
    'result', 'ok',
    'document_id', v_fault.id,
    'fault_id', v_fault.id,
    'equipment_id', v_equipment.id,
    'status', v_fault.status,
    'version', v_fault.version,
    'equipment_status', v_equipment.status,
    'equipment_version', v_equipment.version,
    'failed_command_ids', to_jsonb(v_failed),
    'next_actions', jsonb_build_array('resolve_equipment_fault')
  );
  if p_idempotency_key is not null then
    insert into wms.idempotency_records (tenant_id, command_name, idempotency_key, response)
    values (v_fault.tenant_id, 'wms_raise_equipment_fault', p_idempotency_key, v_cached)
    on conflict do nothing;
  end if;
  return v_cached;
end;
$$;

-- expected_version is the FAULT version. WCS_GATEWAY is deliberately absent
-- from the role list — clearing a fault is a human judgement (spec.md).
create or replace function wms.wms_resolve_equipment_fault(
  p_fault_id uuid,
  p_resolution_note text,
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
  v_fault wms.equipment_faults%rowtype;
  v_before jsonb;
  v_equipment wms.equipment%rowtype;
  v_previous_status text;
  v_open_left int;
  v_warnings jsonb := '[]'::jsonb;
  v_tenant_id uuid;
begin
  select tenant_id into v_tenant_id from wms.equipment_faults where id = p_fault_id;
  if p_idempotency_key is not null and v_tenant_id is not null then
    select response into v_cached from wms.idempotency_records
      where tenant_id = v_tenant_id and command_name = 'wms_resolve_equipment_fault' and idempotency_key = p_idempotency_key;
    if found then return v_cached; end if;
  end if;

  select * into v_fault from wms.equipment_faults where id = p_fault_id;
  if not found then
    raise exception 'INVALID: unknown equipment fault %', p_fault_id;
  end if;
  if v_fault.warehouse_id not in (select wms.current_warehouse_ids(v_fault.tenant_id)) then
    raise exception 'FORBIDDEN: no warehouse scope for fault %', p_fault_id;
  end if;
  if not wms.has_role(v_fault.tenant_id, 'WCS_OPERATOR', 'WAREHOUSE_MANAGER', 'WMS_ADMIN') then
    raise exception 'FORBIDDEN: role cannot resolve equipment faults';
  end if;
  if v_fault.version <> p_expected_version then
    raise exception 'CONFLICT: expected version % but found %', p_expected_version, v_fault.version;
  end if;
  if v_fault.status <> 'OPEN' then
    raise exception 'INVALID: fault % is not OPEN (status=%)', p_fault_id, v_fault.status;
  end if;
  if p_resolution_note is null or btrim(p_resolution_note) = '' then
    raise exception 'INVALID: resolution_note is required';
  end if;

  v_before := to_jsonb(v_fault);

  update wms.equipment_faults
  set status = 'RESOLVED', resolution_note = p_resolution_note, resolved_by = p_actor_id,
      resolved_at = now(), version = version + 1, updated_by = p_actor_id, updated_at = now()
  where id = p_fault_id
  returning * into v_fault;

  select count(*) into v_open_left from wms.equipment_faults
  where equipment_id = v_fault.equipment_id and status = 'OPEN';

  select * into v_equipment from wms.equipment where id = v_fault.equipment_id;
  v_previous_status := v_equipment.status;

  if v_open_left = 0 then
    update wms.equipment
    set status = 'IDLE', version = version + 1, updated_by = p_actor_id, updated_at = now()
    where id = v_fault.equipment_id
    returning * into v_equipment;
  else
    v_warnings := v_warnings || to_jsonb(format('%s other fault(s) still OPEN — equipment stays in FAULT', v_open_left));
  end if;

  insert into wms.equipment_status_events (
    tenant_id, warehouse_id, equipment_id, command_id, event_type,
    previous_status, new_status, detail, reported_by, correlation_id
  ) values (
    v_fault.tenant_id, v_fault.warehouse_id, v_fault.equipment_id, null, 'FAULT_CLEARED',
    v_previous_status, v_equipment.status,
    jsonb_build_object('fault_id', v_fault.id, 'resolution_note', p_resolution_note),
    p_actor_id, p_correlation_id
  );

  insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, before, after, correlation_id)
  values (v_fault.tenant_id, p_actor_id, 'wms_resolve_equipment_fault', 'equipment_fault', v_fault.id,
          v_before, to_jsonb(v_fault), p_correlation_id);

  v_cached := jsonb_build_object(
    'result', 'ok',
    'document_id', v_fault.id,
    'fault_id', v_fault.id,
    'equipment_id', v_equipment.id,
    'status', v_fault.status,
    'version', v_fault.version,
    'equipment_status', v_equipment.status,
    'equipment_version', v_equipment.version,
    'warnings', v_warnings,
    'next_actions', jsonb_build_array('dispatch_equipment_command', 'get_equipment_status')
  );
  if p_idempotency_key is not null then
    insert into wms.idempotency_records (tenant_id, command_name, idempotency_key, response)
    values (v_fault.tenant_id, 'wms_resolve_equipment_fault', p_idempotency_key, v_cached)
    on conflict do nothing;
  end if;
  return v_cached;
end;
$$;

-- expected_version is the COMMAND version.
create or replace function wms.wms_cancel_equipment_command(
  p_command_id uuid,
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
  v_command wms.equipment_commands%rowtype;
  v_before jsonb;
  v_equipment wms.equipment%rowtype;
  v_tenant_id uuid;
begin
  select tenant_id into v_tenant_id from wms.equipment_commands where id = p_command_id;
  if p_idempotency_key is not null and v_tenant_id is not null then
    select response into v_cached from wms.idempotency_records
      where tenant_id = v_tenant_id and command_name = 'wms_cancel_equipment_command' and idempotency_key = p_idempotency_key;
    if found then return v_cached; end if;
  end if;

  select * into v_command from wms.equipment_commands where id = p_command_id;
  if not found then
    raise exception 'INVALID: unknown equipment command %', p_command_id;
  end if;
  if v_command.warehouse_id not in (select wms.current_warehouse_ids(v_command.tenant_id)) then
    raise exception 'FORBIDDEN: no warehouse scope for command %', p_command_id;
  end if;
  if not wms.has_role(v_command.tenant_id, 'WAREHOUSE_MANAGER', 'WCS_OPERATOR', 'PROCESS_AGENT', 'WMS_ADMIN') then
    raise exception 'FORBIDDEN: role cannot cancel equipment commands';
  end if;
  if v_command.version <> p_expected_version then
    raise exception 'CONFLICT: expected version % but found %', p_expected_version, v_command.version;
  end if;
  if v_command.status in ('COMPLETED', 'FAILED', 'REJECTED', 'CANCELLED') then
    raise exception 'INVALID: command % is already terminal (status=%)', p_command_id, v_command.status;
  end if;

  v_before := to_jsonb(v_command);

  update wms.equipment_commands
  set status = 'CANCELLED', reason = p_reason, version = version + 1,
      updated_by = p_actor_id, updated_at = now()
  where id = p_command_id
  returning * into v_command;

  select * into v_equipment from wms.equipment where id = v_command.equipment_id;

  insert into wms.equipment_status_events (
    tenant_id, warehouse_id, equipment_id, command_id, event_type,
    previous_status, new_status, detail, reported_by, correlation_id
  ) values (
    v_command.tenant_id, v_command.warehouse_id, v_command.equipment_id, v_command.id, 'COMMAND_CANCELLED',
    v_equipment.status, v_equipment.status, jsonb_build_object('reason', p_reason),
    p_actor_id, p_correlation_id
  );

  v_equipment := wms._wms_sync_equipment_activity(v_command.equipment_id, p_actor_id, p_correlation_id, v_command.id);

  insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, before, after, correlation_id)
  values (v_command.tenant_id, p_actor_id, 'wms_cancel_equipment_command', 'equipment_command', v_command.id,
          v_before, to_jsonb(v_command), p_correlation_id);

  v_cached := jsonb_build_object(
    'result', 'ok',
    'document_id', v_command.id,
    'command_id', v_command.id,
    'equipment_id', v_equipment.id,
    'status', v_command.status,
    'version', v_command.version,
    'equipment_status', v_equipment.status,
    'equipment_version', v_equipment.version,
    'next_actions', jsonb_build_array('dispatch_equipment_command')
  );
  if p_idempotency_key is not null then
    insert into wms.idempotency_records (tenant_id, command_name, idempotency_key, response)
    values (v_command.tenant_id, 'wms_cancel_equipment_command', p_idempotency_key, v_cached)
    on conflict do nothing;
  end if;
  return v_cached;
end;
$$;

-- Read-only join: equipment + recent events + open faults + in-flight
-- command flag. Mirrors wms_check_stock's shape (stable security definer
-- with an explicit warehouse-scope guard).
create or replace function wms.wms_get_equipment_status(
  p_tenant_id uuid,
  p_warehouse_id uuid,
  p_equipment_id uuid default null,
  p_event_limit int default 5
) returns jsonb
language plpgsql stable security definer
set search_path = wms, public
as $$
declare
  v_items jsonb;
begin
  if p_warehouse_id not in (select wms.current_warehouse_ids(p_tenant_id)) then
    raise exception 'FORBIDDEN: no warehouse scope for %', p_warehouse_id;
  end if;

  select coalesce(jsonb_agg(item order by item->>'equipment_code'), '[]'::jsonb)
  into v_items
  from (
    select jsonb_build_object(
      'equipment_id', e.id,
      'equipment_code', e.equipment_code,
      'equipment_type', e.equipment_type,
      'zone_code', e.zone_code,
      'status', e.status,
      'version', e.version,
      'has_active_command', exists (
        select 1 from wms.equipment_commands c
        where c.equipment_id = e.id and c.status in ('PENDING', 'ACKNOWLEDGED', 'IN_PROGRESS')
      ),
      'active_commands', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'command_id', c.id, 'command_type', c.command_type, 'status', c.status,
          'version', c.version, 'payload', c.payload,
          'linked_entity_type', c.linked_entity_type, 'linked_entity_id', c.linked_entity_id
        ) order by c.created_at), '[]'::jsonb)
        from wms.equipment_commands c
        where c.equipment_id = e.id and c.status in ('PENDING', 'ACKNOWLEDGED', 'IN_PROGRESS')
      ),
      'open_faults', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'fault_id', f.id, 'fault_code', f.fault_code, 'severity', f.severity,
          'version', f.version, 'created_at', f.created_at
        ) order by f.created_at), '[]'::jsonb)
        from wms.equipment_faults f
        where f.equipment_id = e.id and f.status = 'OPEN'
      ),
      'recent_events', (
        select coalesce(jsonb_agg(ev order by seq desc), '[]'::jsonb)
        from (
          select s.seq, jsonb_build_object(
            'event_id', s.id, 'seq', s.seq, 'event_type', s.event_type, 'command_id', s.command_id,
            'previous_status', s.previous_status, 'new_status', s.new_status,
            'detail', s.detail, 'created_at', s.created_at
          ) as ev
          from wms.equipment_status_events s
          where s.equipment_id = e.id
          order by s.seq desc
          limit greatest(coalesce(p_event_limit, 5), 0)
        ) recent
      )
    ) as item
    from wms.equipment e
    where e.tenant_id = p_tenant_id
      and e.warehouse_id = p_warehouse_id
      and (p_equipment_id is null or e.id = p_equipment_id)
  ) rows;

  return jsonb_build_object(
    'result', 'ok',
    'tenant_id', p_tenant_id,
    'warehouse_id', p_warehouse_id,
    'equipment', v_items,
    'count', jsonb_array_length(v_items)
  );
end;
$$;

grant execute on function wms.wms_register_equipment(uuid, uuid, text, text, text, uuid, uuid, text) to authenticated;
grant execute on function wms.wms_dispatch_equipment_command(uuid, text, jsonb, uuid, uuid, int, text, text, uuid) to authenticated;
grant execute on function wms.wms_report_command_result(uuid, text, uuid, uuid, int, jsonb, text) to authenticated;
grant execute on function wms.wms_report_equipment_status(uuid, text, uuid, uuid, int, jsonb, text) to authenticated;
grant execute on function wms.wms_raise_equipment_fault(uuid, text, text, uuid, uuid, text) to authenticated;
grant execute on function wms.wms_resolve_equipment_fault(uuid, text, uuid, uuid, int, text) to authenticated;
grant execute on function wms.wms_cancel_equipment_command(uuid, uuid, uuid, int, text, text) to authenticated;
grant execute on function wms.wms_get_equipment_status(uuid, uuid, uuid, int) to authenticated;
