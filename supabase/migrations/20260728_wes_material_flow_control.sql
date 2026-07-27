-- ============================================================
-- WES/MFS material-flow-control contract
-- Scope: openspec/changes/add-wes-material-flow-control
--        (proposal.md / design.md / specs/wms_wes-material-flow-control/spec.md)
--
-- The middleware between "what the WMS wants done" and "how the equipment
-- does it". A work order records a WMS-side intent (today only: a receipt
-- that reached putaway), and this contract translates it into ONE standard
-- equipment command through wms_wcs-equipment-control
-- (supabase/migrations/20260727_wcs_equipment_control.sql), either
-- immediately (WAVELESS) or when a dispatch wave is released (WAVE).
--
-- Conventions (schema, common columns, RLS helpers, RPC envelope,
-- CONFLICT:/FORBIDDEN:/INVALID: prefixes, idempotency records, audit events)
-- are identical to the two migrations before it, and neither of those files
-- is modified here — the completion-propagation trigger is attached to
-- wms.equipment_commands from this file only (design.md D2).
--
-- ORDERING: this migration REQUIRES 20260727_wcs_equipment_control.sql to
-- have been applied first (wms.equipment, wms.equipment_commands,
-- wms.wms_dispatch_equipment_command, wms.wms_cancel_equipment_command).
--
-- ------------------------------------------------------------
-- DEVIATION from design.md's role table (D3), forced by the *implemented*
-- area-1 contract rather than its design draft:
--
--   design.md D3 requires this contract's write RPCs to allow EXACTLY the
--   roles that may call wms_dispatch_equipment_command, otherwise a caller
--   can register a work order and then have the inner dispatch fail with
--   FORBIDDEN — a confusing partial failure.
--
--   The shipped wms_dispatch_equipment_command allows
--     WAREHOUSE_MANAGER, WCS_OPERATOR, PROCESS_AGENT
--   and, unlike every other RPC in that migration, NOT WMS_ADMIN.
--
--   design.md/spec.md list WMS_ADMIN as a fourth allowed role here. Honouring
--   that list would reintroduce exactly the partial failure D3 exists to
--   prevent (WMS_ADMIN could open a wave and queue work orders but never get
--   anything dispatched). So the write RPCs below use the dispatch-capable
--   set. See openspec/specs/wms_wes-material-flow-control/e2e/README.md for
--   the reproduction of the mismatch (tasks.md 3.9).
-- ============================================================

-- ------------------------------------------------------------
-- Tables
-- ------------------------------------------------------------

create table wms.dispatch_waves (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references wms.tenants(id) on delete cascade,
  warehouse_id uuid not null references wms.warehouses(id) on delete cascade,
  status text not null default 'OPEN' check (status in ('OPEN', 'RELEASED')),
  version int not null default 1,
  correlation_id text,
  released_at timestamptz,
  released_by uuid,
  created_by uuid,
  updated_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table wms.work_orders (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references wms.tenants(id) on delete cascade,
  warehouse_id uuid not null references wms.warehouses(id) on delete cascade,
  -- open sets on purpose (design.md D1/D7 pattern): follow-up specs add
  -- values (e.g. 'REPLENISHMENT', 'outbound_wave') without reshaping the table.
  work_order_type text not null check (work_order_type in ('PUTAWAY')),
  linked_entity_type text not null check (linked_entity_type in ('receipt')),
  linked_entity_id uuid not null,
  -- target equipment condition; value sets are wms_wcs-equipment-control's.
  equipment_type text not null
    check (equipment_type in ('SRM', 'CONVEYOR', 'SORTER', 'AGV', 'AMR', 'ROBOT_CELL')),
  zone_code text,
  command_type text not null
    check (command_type in ('MOVE', 'LOAD', 'UNLOAD', 'START', 'STOP', 'RESET', 'HOLD', 'RESUME')),
  command_payload jsonb not null default '{}'::jsonb,
  dispatch_mode text not null check (dispatch_mode in ('WAVE', 'WAVELESS')),
  wave_id uuid references wms.dispatch_waves(id) on delete restrict,
  status text not null default 'QUEUED'
    check (status in ('QUEUED', 'DISPATCHED', 'COMPLETED', 'FAILED', 'CANCELLED')),
  -- filled only after a successful dispatch. 1:1 today; the column does not
  -- stop a follow-up spec from adding a 1:N child table (design.md D1).
  equipment_command_id uuid references wms.equipment_commands(id) on delete set null,
  reason text,
  version int not null default 1,
  correlation_id text,
  created_by uuid,
  updated_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- WAVE work orders belong to a wave, WAVELESS ones never do (design.md D6)
  constraint work_orders_wave_mode_ck check ((dispatch_mode = 'WAVE') = (wave_id is not null))
);

create index dispatch_waves_warehouse_status_idx
  on wms.dispatch_waves (warehouse_id, status);
create index work_orders_wave_status_idx
  on wms.work_orders (wave_id, status);
create index work_orders_warehouse_status_idx
  on wms.work_orders (warehouse_id, status);
create index work_orders_equipment_command_idx
  on wms.work_orders (equipment_command_id);

-- ============================================================
-- RLS: SELECT-only for tenant/warehouse members; every write goes through
-- the SECURITY DEFINER RPCs below (same pattern as the two prior migrations).
-- ============================================================

alter table wms.dispatch_waves enable row level security;
create policy dispatch_waves_select on wms.dispatch_waves for select to authenticated
  using (warehouse_id in (select wms.current_warehouse_ids(tenant_id)));

alter table wms.work_orders enable row level security;
create policy work_orders_select on wms.work_orders for select to authenticated
  using (warehouse_id in (select wms.current_warehouse_ids(tenant_id)));

grant select on wms.dispatch_waves to authenticated;
grant select on wms.work_orders to authenticated;

-- ============================================================
-- Internal helpers
-- ============================================================

-- Flow balancing (design.md D5) — deliberately NOT an optimiser:
--   1. equipment_type / zone_code match, status = 'IDLE'
--   2. no outstanding (PENDING/ACKNOWLEDGED/IN_PROGRESS) command
--   3. fewest commands COMPLETED in the recent window, then oldest equipment
-- A null work-order zone_code means "any zone in this warehouse".
create or replace function wms._wms_pick_equipment_for_work_order(
  p_work_order wms.work_orders,
  p_recent_window interval default interval '1 hour'
) returns wms.equipment
language plpgsql stable security definer
set search_path = wms, public
as $$
declare
  v_equipment wms.equipment%rowtype;
begin
  select e.* into v_equipment
  from wms.equipment e
  where e.tenant_id = p_work_order.tenant_id
    and e.warehouse_id = p_work_order.warehouse_id
    and e.equipment_type = p_work_order.equipment_type
    and (p_work_order.zone_code is null or e.zone_code = p_work_order.zone_code)
    and e.status = 'IDLE'
    and not exists (
      select 1 from wms.equipment_commands c
      where c.equipment_id = e.id and c.status in ('PENDING', 'ACKNOWLEDGED', 'IN_PROGRESS')
    )
  order by (
    select count(*) from wms.equipment_commands c
    where c.equipment_id = e.id
      and c.status = 'COMPLETED'
      and c.updated_at > now() - p_recent_window
  ) asc, e.created_at asc, e.equipment_code asc
  limit 1;

  return v_equipment;
end;
$$;

-- Translates one QUEUED work order into one equipment command, or leaves it
-- QUEUED with a NO_EQUIPMENT_AVAILABLE warning. Returns the (possibly
-- unchanged) work order plus the warning list.
--
-- wms_dispatch_equipment_command is SECURITY DEFINER but authorises on
-- auth.uid(), so the caller's identity — not the definer's — is what it sees
-- (design.md D3). That is why the role sets have to line up.
create or replace function wms._wms_try_dispatch_work_order(
  p_work_order_id uuid,
  p_actor_id uuid,
  p_correlation_id text default null
) returns jsonb
language plpgsql security definer
set search_path = wms, public
as $$
declare
  v_work_order wms.work_orders%rowtype;
  v_before jsonb;
  v_equipment wms.equipment%rowtype;
  v_dispatch jsonb;
begin
  select * into v_work_order from wms.work_orders where id = p_work_order_id for update;
  if not found then
    raise exception 'INVALID: unknown work order %', p_work_order_id;
  end if;
  if v_work_order.status <> 'QUEUED' then
    raise exception 'INVALID: work order % is not QUEUED (status=%)', p_work_order_id, v_work_order.status;
  end if;

  v_equipment := wms._wms_pick_equipment_for_work_order(v_work_order);

  if v_equipment.id is null then
    return jsonb_build_object(
      'dispatched', false,
      'work_order', to_jsonb(v_work_order),
      'warnings', jsonb_build_array('NO_EQUIPMENT_AVAILABLE')
    );
  end if;

  v_dispatch := wms.wms_dispatch_equipment_command(
    v_equipment.id,
    v_work_order.command_type,
    v_work_order.command_payload,
    p_actor_id,
    gen_random_uuid(),
    v_equipment.version,
    coalesce(p_correlation_id, v_work_order.correlation_id),
    'work_order',
    v_work_order.id
  );

  v_before := to_jsonb(v_work_order);

  update wms.work_orders
  set status = 'DISPATCHED',
      equipment_command_id = (v_dispatch->>'command_id')::uuid,
      version = version + 1,
      updated_by = p_actor_id,
      updated_at = now()
  where id = v_work_order.id
  returning * into v_work_order;

  insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, before, after, correlation_id)
  values (v_work_order.tenant_id, p_actor_id, 'wms_dispatch_work_order', 'work_order', v_work_order.id,
          v_before, to_jsonb(v_work_order), coalesce(p_correlation_id, v_work_order.correlation_id));

  return jsonb_build_object(
    'dispatched', true,
    'work_order', to_jsonb(v_work_order),
    'equipment_id', v_equipment.id,
    'equipment_code', v_equipment.equipment_code,
    'equipment_command_id', v_dispatch->>'command_id',
    'warnings', '[]'::jsonb
  );
end;
$$;

-- ============================================================
-- Completion propagation (design.md D2)
--
-- The subscription point wms_wcs-equipment-control deliberately left open:
-- when a command that carries linked_entity_type='work_order' reaches
-- COMPLETED/FAILED, the work order follows. The referenced upper WMS entity
-- (wms.receipts) is NOT touched — that is a consuming orchestration's job
-- (spec.md "설비 명령 결과의 업무 오더 반영").
--
-- SECURITY DEFINER so the propagation works no matter which identity's
-- statement fired it (gateway feedback, or the fault path force-failing
-- in-flight commands).
-- ============================================================

create or replace function wms._wms_propagate_command_result_to_work_order()
returns trigger
language plpgsql security definer
set search_path = wms, public
as $$
declare
  v_work_order wms.work_orders%rowtype;
  v_before jsonb;
  v_new_status text;
begin
  if new.linked_entity_id is null then
    return null;
  end if;

  select * into v_work_order from wms.work_orders where id = new.linked_entity_id for update;
  if not found then
    return null;
  end if;
  -- only an in-flight work order follows its command; a cancelled or already
  -- terminal one is left alone.
  if v_work_order.status <> 'DISPATCHED' then
    return null;
  end if;

  v_new_status := case when new.status = 'COMPLETED' then 'COMPLETED' else 'FAILED' end;
  v_before := to_jsonb(v_work_order);

  update wms.work_orders
  set status = v_new_status,
      version = version + 1,
      reason = case when v_new_status = 'FAILED' then coalesce(new.reason, 'equipment command failed') else reason end,
      updated_by = new.updated_by,
      updated_at = now()
  where id = v_work_order.id
  returning * into v_work_order;

  insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, before, after, correlation_id)
  values (v_work_order.tenant_id, new.updated_by, 'wms_propagate_command_result', 'work_order', v_work_order.id,
          v_before, to_jsonb(v_work_order), coalesce(new.correlation_id, v_work_order.correlation_id));

  return null;
end;
$$;

-- Attached to a table this migration does not own. If
-- wms_wcs-equipment-control ever reshapes wms.equipment_commands, revisit
-- this trigger (design.md "Risks / Trade-offs", tasks.md 1.3).
create trigger equipment_commands_propagate_work_order
after update of status on wms.equipment_commands
for each row
when (
  new.status in ('COMPLETED', 'FAILED')
  and old.status is distinct from new.status
  and new.linked_entity_type = 'work_order'
)
execute function wms._wms_propagate_command_result_to_work_order();

-- ============================================================
-- Command RPCs
-- Envelope in:  tenant_id / warehouse_id (implied by the target row for
--               id-addressed calls), actor_id, idempotency_key,
--               expected_version, correlation_id.
-- Envelope out: {result, document_id, status, version, next_actions, warnings}.
-- Errors:       RAISE EXCEPTION with CONFLICT:/FORBIDDEN:/INVALID: prefix.
-- ============================================================

create or replace function wms.wms_open_dispatch_wave(
  p_tenant_id uuid,
  p_warehouse_id uuid,
  p_actor_id uuid,
  p_idempotency_key uuid,
  p_correlation_id text default null
) returns jsonb
language plpgsql security definer
set search_path = wms, public
as $$
declare
  v_cached jsonb;
  v_wave wms.dispatch_waves%rowtype;
begin
  if p_idempotency_key is not null then
    select response into v_cached from wms.idempotency_records
      where tenant_id = p_tenant_id and command_name = 'wms_open_dispatch_wave' and idempotency_key = p_idempotency_key;
    if found then return v_cached; end if;
  end if;

  if p_warehouse_id not in (select wms.current_warehouse_ids(p_tenant_id)) then
    raise exception 'FORBIDDEN: no warehouse scope for %', p_warehouse_id;
  end if;
  if not wms.has_role(p_tenant_id, 'WAREHOUSE_MANAGER', 'WCS_OPERATOR', 'PROCESS_AGENT') then
    raise exception 'FORBIDDEN: role cannot open dispatch waves';
  end if;

  insert into wms.dispatch_waves (
    tenant_id, warehouse_id, status, correlation_id, created_by, updated_by
  ) values (
    p_tenant_id, p_warehouse_id, 'OPEN', p_correlation_id, p_actor_id, p_actor_id
  )
  returning * into v_wave;

  insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, before, after, correlation_id)
  values (p_tenant_id, p_actor_id, 'wms_open_dispatch_wave', 'dispatch_wave', v_wave.id,
          null, to_jsonb(v_wave), p_correlation_id);

  v_cached := jsonb_build_object(
    'result', 'ok',
    'document_id', v_wave.id,
    'wave_id', v_wave.id,
    'status', v_wave.status,
    'version', v_wave.version,
    'warnings', '[]'::jsonb,
    'next_actions', jsonb_build_array('create_work_order', 'release_dispatch_wave')
  );
  if p_idempotency_key is not null then
    insert into wms.idempotency_records (tenant_id, command_name, idempotency_key, response)
    values (p_tenant_id, 'wms_open_dispatch_wave', p_idempotency_key, v_cached)
    on conflict do nothing;
  end if;
  return v_cached;
end;
$$;

-- WAVELESS work orders attempt their dispatch inside this same transaction;
-- WAVE work orders wait for wms_release_dispatch_wave (design.md D6).
create or replace function wms.wms_create_work_order(
  p_tenant_id uuid,
  p_warehouse_id uuid,
  p_work_order_type text,
  p_linked_entity_type text,
  p_linked_entity_id uuid,
  p_equipment_type text,
  p_zone_code text,
  p_command_type text,
  p_command_payload jsonb,
  p_dispatch_mode text,
  p_actor_id uuid,
  p_idempotency_key uuid,
  p_wave_id uuid default null,
  p_correlation_id text default null
) returns jsonb
language plpgsql security definer
set search_path = wms, public
as $$
declare
  v_cached jsonb;
  v_work_order wms.work_orders%rowtype;
  v_wave wms.dispatch_waves%rowtype;
  v_attempt jsonb;
  v_warnings jsonb := '[]'::jsonb;
  v_links jsonb := '{}'::jsonb;
begin
  if p_idempotency_key is not null then
    select response into v_cached from wms.idempotency_records
      where tenant_id = p_tenant_id and command_name = 'wms_create_work_order' and idempotency_key = p_idempotency_key;
    if found then return v_cached; end if;
  end if;

  if p_warehouse_id not in (select wms.current_warehouse_ids(p_tenant_id)) then
    raise exception 'FORBIDDEN: no warehouse scope for %', p_warehouse_id;
  end if;
  if not wms.has_role(p_tenant_id, 'WAREHOUSE_MANAGER', 'WCS_OPERATOR', 'PROCESS_AGENT') then
    raise exception 'FORBIDDEN: role cannot create work orders';
  end if;
  if p_work_order_type not in ('PUTAWAY') then
    raise exception 'INVALID: unknown work_order_type %', p_work_order_type;
  end if;
  if p_linked_entity_type not in ('receipt') then
    raise exception 'INVALID: unknown linked_entity_type %', p_linked_entity_type;
  end if;
  if p_linked_entity_id is null then
    raise exception 'INVALID: linked_entity_id is required';
  end if;
  if not exists (
    select 1 from wms.receipts r
    where r.id = p_linked_entity_id and r.tenant_id = p_tenant_id and r.warehouse_id = p_warehouse_id
  ) then
    raise exception 'INVALID: unknown receipt % in warehouse %', p_linked_entity_id, p_warehouse_id;
  end if;
  if p_equipment_type not in ('SRM', 'CONVEYOR', 'SORTER', 'AGV', 'AMR', 'ROBOT_CELL') then
    raise exception 'INVALID: unknown equipment_type %', p_equipment_type;
  end if;
  if p_command_type not in ('MOVE', 'LOAD', 'UNLOAD', 'START', 'STOP', 'RESET', 'HOLD', 'RESUME') then
    raise exception 'INVALID: unknown command_type %', p_command_type;
  end if;
  if p_dispatch_mode not in ('WAVE', 'WAVELESS') then
    raise exception 'INVALID: dispatch_mode must be WAVE or WAVELESS';
  end if;

  if p_dispatch_mode = 'WAVE' then
    if p_wave_id is null then
      raise exception 'INVALID: wave_id is required when dispatch_mode is WAVE';
    end if;
    select * into v_wave from wms.dispatch_waves where id = p_wave_id;
    if not found then
      raise exception 'INVALID: unknown dispatch wave %', p_wave_id;
    end if;
    if v_wave.tenant_id <> p_tenant_id or v_wave.warehouse_id <> p_warehouse_id then
      raise exception 'INVALID: dispatch wave % belongs to another warehouse', p_wave_id;
    end if;
    if v_wave.status <> 'OPEN' then
      raise exception 'INVALID: dispatch wave % is not OPEN (status=%)', p_wave_id, v_wave.status;
    end if;
  elsif p_wave_id is not null then
    raise exception 'INVALID: wave_id must be null when dispatch_mode is WAVELESS';
  end if;

  insert into wms.work_orders (
    tenant_id, warehouse_id, work_order_type, linked_entity_type, linked_entity_id,
    equipment_type, zone_code, command_type, command_payload, dispatch_mode, wave_id,
    status, correlation_id, created_by, updated_by
  ) values (
    p_tenant_id, p_warehouse_id, p_work_order_type, p_linked_entity_type, p_linked_entity_id,
    p_equipment_type, p_zone_code, p_command_type, coalesce(p_command_payload, '{}'::jsonb),
    p_dispatch_mode, p_wave_id, 'QUEUED', p_correlation_id, p_actor_id, p_actor_id
  )
  returning * into v_work_order;

  insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, before, after, correlation_id)
  values (p_tenant_id, p_actor_id, 'wms_create_work_order', 'work_order', v_work_order.id,
          null, to_jsonb(v_work_order), p_correlation_id);

  if p_dispatch_mode = 'WAVELESS' then
    v_attempt := wms._wms_try_dispatch_work_order(v_work_order.id, p_actor_id, p_correlation_id);
    v_work_order := jsonb_populate_record(null::wms.work_orders, v_attempt->'work_order');
    v_warnings := v_attempt->'warnings';
    if (v_attempt->>'dispatched')::boolean then
      v_links := jsonb_build_object(
        'equipment_id', v_attempt->>'equipment_id',
        'equipment_code', v_attempt->>'equipment_code',
        'equipment_command_id', v_attempt->>'equipment_command_id'
      );
    end if;
  end if;

  v_cached := jsonb_build_object(
    'result', 'ok',
    'document_id', v_work_order.id,
    'work_order_id', v_work_order.id,
    'status', v_work_order.status,
    'version', v_work_order.version,
    'dispatch_mode', v_work_order.dispatch_mode,
    'wave_id', v_work_order.wave_id,
    'links', v_links,
    'warnings', v_warnings,
    'next_actions', case
      when v_work_order.status = 'DISPATCHED' then jsonb_build_array('get_work_order_status', 'cancel_work_order')
      when v_work_order.dispatch_mode = 'WAVE' then jsonb_build_array('release_dispatch_wave', 'cancel_work_order')
      else jsonb_build_array('retry_work_order_dispatch', 'cancel_work_order')
    end
  );
  if p_idempotency_key is not null then
    insert into wms.idempotency_records (tenant_id, command_name, idempotency_key, response)
    values (p_tenant_id, 'wms_create_work_order', p_idempotency_key, v_cached)
    on conflict do nothing;
  end if;
  return v_cached;
end;
$$;

-- expected_version is the WAVE version.
create or replace function wms.wms_release_dispatch_wave(
  p_wave_id uuid,
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
  v_wave wms.dispatch_waves%rowtype;
  v_before jsonb;
  v_tenant_id uuid;
  v_row record;
  v_attempt jsonb;
  v_dispatched int := 0;
  v_queued int := 0;
  v_warnings jsonb := '[]'::jsonb;
  v_results jsonb := '[]'::jsonb;
begin
  select tenant_id into v_tenant_id from wms.dispatch_waves where id = p_wave_id;
  if p_idempotency_key is not null and v_tenant_id is not null then
    select response into v_cached from wms.idempotency_records
      where tenant_id = v_tenant_id and command_name = 'wms_release_dispatch_wave' and idempotency_key = p_idempotency_key;
    if found then return v_cached; end if;
  end if;

  select * into v_wave from wms.dispatch_waves where id = p_wave_id for update;
  if not found then
    raise exception 'INVALID: unknown dispatch wave %', p_wave_id;
  end if;
  if v_wave.warehouse_id not in (select wms.current_warehouse_ids(v_wave.tenant_id)) then
    raise exception 'FORBIDDEN: no warehouse scope for dispatch wave %', p_wave_id;
  end if;
  if not wms.has_role(v_wave.tenant_id, 'WAREHOUSE_MANAGER', 'WCS_OPERATOR', 'PROCESS_AGENT') then
    raise exception 'FORBIDDEN: role cannot release dispatch waves';
  end if;
  if v_wave.version <> p_expected_version then
    raise exception 'CONFLICT: expected version % but found %', p_expected_version, v_wave.version;
  end if;
  if v_wave.status <> 'OPEN' then
    raise exception 'INVALID: dispatch wave % is not OPEN (status=%)', p_wave_id, v_wave.status;
  end if;

  v_before := to_jsonb(v_wave);

  update wms.dispatch_waves
  set status = 'RELEASED', released_at = now(), released_by = p_actor_id,
      version = version + 1, updated_by = p_actor_id, updated_at = now()
  where id = p_wave_id
  returning * into v_wave;

  -- sequential dispatch attempts: each one takes the least-loaded idle
  -- equipment, so the next attempt already sees it as busy (design.md D5).
  for v_row in
    select id from wms.work_orders
    where wave_id = p_wave_id and status = 'QUEUED'
    order by created_at, id
  loop
    v_attempt := wms._wms_try_dispatch_work_order(v_row.id, p_actor_id, p_correlation_id);
    if (v_attempt->>'dispatched')::boolean then
      v_dispatched := v_dispatched + 1;
    else
      v_queued := v_queued + 1;
    end if;
    v_results := v_results || jsonb_build_array(jsonb_build_object(
      'work_order_id', v_row.id,
      'dispatched', (v_attempt->>'dispatched')::boolean,
      'status', v_attempt->'work_order'->>'status',
      'equipment_code', v_attempt->>'equipment_code'
    ));
  end loop;

  if v_queued > 0 then
    v_warnings := v_warnings || to_jsonb(format('NO_EQUIPMENT_AVAILABLE: %s work order(s) stay QUEUED', v_queued));
  end if;

  insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, before, after, correlation_id)
  values (v_wave.tenant_id, p_actor_id, 'wms_release_dispatch_wave', 'dispatch_wave', v_wave.id,
          v_before, to_jsonb(v_wave) || jsonb_build_object('dispatched_count', v_dispatched, 'queued_count', v_queued),
          p_correlation_id);

  v_cached := jsonb_build_object(
    'result', 'ok',
    'document_id', v_wave.id,
    'wave_id', v_wave.id,
    'status', v_wave.status,
    'version', v_wave.version,
    'dispatched_count', v_dispatched,
    'queued_count', v_queued,
    'work_orders', v_results,
    'warnings', v_warnings,
    'next_actions', case
      when v_queued > 0 then jsonb_build_array('retry_work_order_dispatch', 'get_work_order_status')
      else jsonb_build_array('get_work_order_status')
    end
  );
  if p_idempotency_key is not null then
    insert into wms.idempotency_records (tenant_id, command_name, idempotency_key, response)
    values (v_wave.tenant_id, 'wms_release_dispatch_wave', p_idempotency_key, v_cached)
    on conflict do nothing;
  end if;
  return v_cached;
end;
$$;

-- expected_version is the WORK ORDER version.
create or replace function wms.wms_retry_work_order_dispatch(
  p_work_order_id uuid,
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
  v_work_order wms.work_orders%rowtype;
  v_attempt jsonb;
  v_tenant_id uuid;
  v_links jsonb := '{}'::jsonb;
begin
  select tenant_id into v_tenant_id from wms.work_orders where id = p_work_order_id;
  if p_idempotency_key is not null and v_tenant_id is not null then
    select response into v_cached from wms.idempotency_records
      where tenant_id = v_tenant_id and command_name = 'wms_retry_work_order_dispatch' and idempotency_key = p_idempotency_key;
    if found then return v_cached; end if;
  end if;

  select * into v_work_order from wms.work_orders where id = p_work_order_id;
  if not found then
    raise exception 'INVALID: unknown work order %', p_work_order_id;
  end if;
  if v_work_order.warehouse_id not in (select wms.current_warehouse_ids(v_work_order.tenant_id)) then
    raise exception 'FORBIDDEN: no warehouse scope for work order %', p_work_order_id;
  end if;
  if not wms.has_role(v_work_order.tenant_id, 'WAREHOUSE_MANAGER', 'WCS_OPERATOR', 'PROCESS_AGENT') then
    raise exception 'FORBIDDEN: role cannot retry work order dispatch';
  end if;
  if v_work_order.version <> p_expected_version then
    raise exception 'CONFLICT: expected version % but found %', p_expected_version, v_work_order.version;
  end if;
  if v_work_order.status <> 'QUEUED' then
    raise exception 'INVALID: work order % is not QUEUED (status=%)', p_work_order_id, v_work_order.status;
  end if;
  -- a WAVE work order only becomes dispatchable when its wave is released
  if v_work_order.dispatch_mode = 'WAVE'
     and (select status from wms.dispatch_waves where id = v_work_order.wave_id) = 'OPEN' then
    raise exception 'INVALID: work order % belongs to an OPEN wave — release the wave first', p_work_order_id;
  end if;

  v_attempt := wms._wms_try_dispatch_work_order(p_work_order_id, p_actor_id, p_correlation_id);
  v_work_order := jsonb_populate_record(null::wms.work_orders, v_attempt->'work_order');
  if (v_attempt->>'dispatched')::boolean then
    v_links := jsonb_build_object(
      'equipment_id', v_attempt->>'equipment_id',
      'equipment_code', v_attempt->>'equipment_code',
      'equipment_command_id', v_attempt->>'equipment_command_id'
    );
  end if;

  -- the retry itself is auditable even when it finds no equipment; the
  -- successful case additionally has _wms_try_dispatch_work_order's
  -- 'wms_dispatch_work_order' row (spec.md "감사 추적").
  insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, before, after, correlation_id)
  values (v_work_order.tenant_id, p_actor_id, 'wms_retry_work_order_dispatch', 'work_order', v_work_order.id,
          jsonb_build_object('status', 'QUEUED', 'version', p_expected_version),
          jsonb_build_object('status', v_work_order.status, 'version', v_work_order.version,
                             'warnings', v_attempt->'warnings'),
          p_correlation_id);

  v_cached := jsonb_build_object(
    'result', 'ok',
    'document_id', v_work_order.id,
    'work_order_id', v_work_order.id,
    'status', v_work_order.status,
    'version', v_work_order.version,
    'links', v_links,
    'warnings', v_attempt->'warnings',
    'next_actions', case
      when v_work_order.status = 'DISPATCHED' then jsonb_build_array('get_work_order_status', 'cancel_work_order')
      else jsonb_build_array('retry_work_order_dispatch', 'cancel_work_order')
    end
  );
  if p_idempotency_key is not null then
    insert into wms.idempotency_records (tenant_id, command_name, idempotency_key, response)
    values (v_work_order.tenant_id, 'wms_retry_work_order_dispatch', p_idempotency_key, v_cached)
    on conflict do nothing;
  end if;
  return v_cached;
end;
$$;

-- expected_version is the WORK ORDER version. A DISPATCHED work order also
-- cancels its equipment command (spec.md "업무 오더 취소").
create or replace function wms.wms_cancel_work_order(
  p_work_order_id uuid,
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
  v_work_order wms.work_orders%rowtype;
  v_before jsonb;
  v_command wms.equipment_commands%rowtype;
  v_tenant_id uuid;
  v_warnings jsonb := '[]'::jsonb;
  v_cancelled_command uuid;
begin
  select tenant_id into v_tenant_id from wms.work_orders where id = p_work_order_id;
  if p_idempotency_key is not null and v_tenant_id is not null then
    select response into v_cached from wms.idempotency_records
      where tenant_id = v_tenant_id and command_name = 'wms_cancel_work_order' and idempotency_key = p_idempotency_key;
    if found then return v_cached; end if;
  end if;

  select * into v_work_order from wms.work_orders where id = p_work_order_id for update;
  if not found then
    raise exception 'INVALID: unknown work order %', p_work_order_id;
  end if;
  if v_work_order.warehouse_id not in (select wms.current_warehouse_ids(v_work_order.tenant_id)) then
    raise exception 'FORBIDDEN: no warehouse scope for work order %', p_work_order_id;
  end if;
  if not wms.has_role(v_work_order.tenant_id, 'WAREHOUSE_MANAGER', 'WCS_OPERATOR', 'PROCESS_AGENT') then
    raise exception 'FORBIDDEN: role cannot cancel work orders';
  end if;
  if v_work_order.version <> p_expected_version then
    raise exception 'CONFLICT: expected version % but found %', p_expected_version, v_work_order.version;
  end if;
  if v_work_order.status in ('COMPLETED', 'FAILED', 'CANCELLED') then
    raise exception 'INVALID: work order % is already terminal (status=%)', p_work_order_id, v_work_order.status;
  end if;

  if v_work_order.status = 'DISPATCHED' and v_work_order.equipment_command_id is not null then
    select * into v_command from wms.equipment_commands where id = v_work_order.equipment_command_id;
    if found and v_command.status in ('PENDING', 'ACKNOWLEDGED', 'IN_PROGRESS') then
      perform wms.wms_cancel_equipment_command(
        v_command.id, p_actor_id, gen_random_uuid(), v_command.version,
        coalesce(p_reason, 'work order cancelled'), p_correlation_id
      );
      v_cancelled_command := v_command.id;
    else
      v_warnings := v_warnings || to_jsonb('LINKED_COMMAND_ALREADY_TERMINAL'::text);
    end if;
  end if;

  v_before := to_jsonb(v_work_order);

  update wms.work_orders
  set status = 'CANCELLED', reason = p_reason, version = version + 1,
      updated_by = p_actor_id, updated_at = now()
  where id = p_work_order_id
  returning * into v_work_order;

  insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, before, after, correlation_id)
  values (v_work_order.tenant_id, p_actor_id, 'wms_cancel_work_order', 'work_order', v_work_order.id,
          v_before, to_jsonb(v_work_order), p_correlation_id);

  v_cached := jsonb_build_object(
    'result', 'ok',
    'document_id', v_work_order.id,
    'work_order_id', v_work_order.id,
    'status', v_work_order.status,
    'version', v_work_order.version,
    'cancelled_equipment_command_id', v_cancelled_command,
    'warnings', v_warnings,
    'next_actions', jsonb_build_array('get_work_order_status')
  );
  if p_idempotency_key is not null then
    insert into wms.idempotency_records (tenant_id, command_name, idempotency_key, response)
    values (v_work_order.tenant_id, 'wms_cancel_work_order', p_idempotency_key, v_cached)
    on conflict do nothing;
  end if;
  return v_cached;
end;
$$;

-- Read-only join: work orders + their equipment command + wave, plus the
-- warehouse's waves. Mirrors wms_get_equipment_status's shape.
create or replace function wms.wms_get_work_order_status(
  p_tenant_id uuid,
  p_warehouse_id uuid,
  p_work_order_id uuid default null
) returns jsonb
language plpgsql stable security definer
set search_path = wms, public
as $$
declare
  v_work_orders jsonb;
  v_waves jsonb;
begin
  if p_warehouse_id not in (select wms.current_warehouse_ids(p_tenant_id)) then
    raise exception 'FORBIDDEN: no warehouse scope for %', p_warehouse_id;
  end if;

  select coalesce(jsonb_agg(item order by created_at desc), '[]'::jsonb)
  into v_work_orders
  from (
    select wo.created_at, jsonb_build_object(
      'work_order_id', wo.id,
      'work_order_type', wo.work_order_type,
      'linked_entity_type', wo.linked_entity_type,
      'linked_entity_id', wo.linked_entity_id,
      'equipment_type', wo.equipment_type,
      'zone_code', wo.zone_code,
      'command_type', wo.command_type,
      'command_payload', wo.command_payload,
      'dispatch_mode', wo.dispatch_mode,
      'wave_id', wo.wave_id,
      'wave_status', w.status,
      'status', wo.status,
      'version', wo.version,
      'reason', wo.reason,
      'created_at', wo.created_at,
      'updated_at', wo.updated_at,
      'has_equipment_command', wo.equipment_command_id is not null,
      'equipment_command', case when c.id is null then null else jsonb_build_object(
        'command_id', c.id,
        'command_type', c.command_type,
        'status', c.status,
        'version', c.version,
        'equipment_id', c.equipment_id,
        'equipment_code', e.equipment_code,
        'equipment_status', e.status
      ) end
    ) as item
    from wms.work_orders wo
    left join wms.dispatch_waves w on w.id = wo.wave_id
    left join wms.equipment_commands c on c.id = wo.equipment_command_id
    left join wms.equipment e on e.id = c.equipment_id
    where wo.tenant_id = p_tenant_id
      and wo.warehouse_id = p_warehouse_id
      and (p_work_order_id is null or wo.id = p_work_order_id)
  ) rows;

  select coalesce(jsonb_agg(item order by created_at desc), '[]'::jsonb)
  into v_waves
  from (
    select w.created_at, jsonb_build_object(
      'wave_id', w.id,
      'status', w.status,
      'version', w.version,
      'released_at', w.released_at,
      'created_at', w.created_at,
      'work_order_count', (select count(*) from wms.work_orders wo where wo.wave_id = w.id),
      'queued_count', (select count(*) from wms.work_orders wo where wo.wave_id = w.id and wo.status = 'QUEUED')
    ) as item
    from wms.dispatch_waves w
    where w.tenant_id = p_tenant_id and w.warehouse_id = p_warehouse_id
  ) rows;

  return jsonb_build_object(
    'result', 'ok',
    'tenant_id', p_tenant_id,
    'warehouse_id', p_warehouse_id,
    'work_orders', v_work_orders,
    'waves', v_waves,
    'count', jsonb_array_length(v_work_orders)
  );
end;
$$;

grant execute on function wms.wms_open_dispatch_wave(uuid, uuid, uuid, uuid, text) to authenticated;
grant execute on function wms.wms_create_work_order(uuid, uuid, text, text, uuid, text, text, text, jsonb, text, uuid, uuid, uuid, text) to authenticated;
grant execute on function wms.wms_release_dispatch_wave(uuid, uuid, uuid, int, text) to authenticated;
grant execute on function wms.wms_retry_work_order_dispatch(uuid, uuid, uuid, int, text) to authenticated;
grant execute on function wms.wms_cancel_work_order(uuid, uuid, uuid, int, text, text) to authenticated;
grant execute on function wms.wms_get_work_order_status(uuid, uuid, uuid) to authenticated;
