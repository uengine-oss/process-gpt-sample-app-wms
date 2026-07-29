-- ============================================================
-- WCS high-speed sortation-logic contract
-- Scope: openspec/changes/add-wcs-sortation-logic
--        (proposal.md / design.md / specs/wms_wcs-sortation-logic/spec.md)
--
-- Adds the per-equipment tuning master data a real sorter exposes (minimum
-- carton gap, speed mode + allowed range, sensor detection window) and the
-- structured `payload` contract for the two sorter-specific commands
-- (DIVERT / SET_SPEED) that ride on top of wms_wcs-equipment-control's
-- generic command envelope. It also maps the sortation outcome
-- (SUCCESS / MISROUTE / JAM) onto that contract's command-result reporting
-- and escalates a JAM into a real equipment fault automatically.
--
-- Conventions (schema, common columns, RLS helpers, RPC envelope,
-- CONFLICT:/FORBIDDEN:/INVALID: prefixes, idempotency records, audit events)
-- are identical to the three migrations before it, and none of those files is
-- modified here.
--
-- ORDERING: this migration REQUIRES 20260727_wcs_equipment_control.sql to have
-- been applied first (wms.equipment, wms.equipment_commands,
-- wms.equipment_status_events, wms.wms_dispatch_equipment_command,
-- wms.wms_report_command_result, wms.wms_raise_equipment_fault). It has no
-- dependency on 20260728_wes_material_flow_control.sql, but it is ordered
-- after it so the migration history stays linear.
--
-- ------------------------------------------------------------
-- DEVIATION 1 from design.md D3 — forced by the *implemented* area-1 contract
-- rather than its design draft:
--
--   design.md D3 states "wms_dispatch_equipment_command RPC 자체는 수정하지
--   않는다" and assumes extending the table's CHECK constraint (D2) is enough
--   to make DIVERT/SET_SPEED dispatchable.
--
--   The shipped wms_dispatch_equipment_command *also* hard-codes the command
--   type list in its own guard:
--       if p_command_type not in ('MOVE','LOAD',...,'RESUME') then
--         raise exception 'INVALID: unknown command_type %', p_command_type;
--   so a DIVERT would be refused by the RPC before the relaxed CHECK
--   constraint is ever reached. Relaxing the constraint alone is a no-op.
--
--   This migration therefore does a `create or replace` of that function with
--   the two new values added to that one list and NOTHING else changed
--   (byte-identical otherwise). That is the smallest possible edit that
--   honours D2's intent ("command_type 값 집합을 확장하는 마이그레이션만
--   추가하면 된다") and it still leaves area 1's migration file untouched.
--   If area 1 ever reshapes that RPC, this replacement must be re-based on it.
--
-- DEVIATION 2 — the role note area 2 already documented, restated because it
-- shapes this contract's UI and E2E:
--
--   wms_dispatch_equipment_command allows WAREHOUSE_MANAGER / WCS_OPERATOR /
--   PROCESS_AGENT and, unlike every other RPC in that migration, NOT
--   WMS_ADMIN. This contract's own three profile RPCs use design.md's role
--   list (WMS_ADMIN / WAREHOUSE_MANAGER / WCS_OPERATOR) because they never
--   dispatch anything, so no partial failure is possible. The consequence —
--   WMS_ADMIN may tune a profile but may not send DIVERT/SET_SPEED — is
--   deliberate and surfaced in the UI, not hidden. See
--   openspec/specs/wms_wcs-sortation-logic/e2e/README.md.
--
-- DEVIATION 3 from spec.md "감사 추적":
--
--   That requirement asks for "Divert/속도 조정 명령의 payload 검증 거부"
--   (rejected payloads) to be written to wms.audit_events. It cannot be
--   honoured as written: a rejection is a RAISE EXCEPTION, which rolls the
--   whole transaction back — including any audit row the trigger just wrote.
--   Persisting it would need an autonomous transaction (dblink / pg_background),
--   neither of which this repository uses.
--
--   What is audited instead: every *successful* write (profile create/update,
--   the command insert itself via area 1's wms_dispatch_equipment_command, and
--   the automatic jam escalation below, which adds its own
--   'wms_escalate_sortation_jam' row on top of area 1's fault rows). Rejections
--   surface to the caller as the `INVALID:` error and nowhere else.
-- ============================================================

-- ------------------------------------------------------------
-- Table: one tuning profile per SORTER/CONVEYOR (design.md D1, D7).
--
-- The "equipment_type must be SORTER/CONVEYOR" rule is a cross-table
-- condition, so it lives in the RPC and in the command-validation trigger,
-- not in a CHECK constraint.
-- ------------------------------------------------------------

create table wms.sortation_profiles (
  id uuid primary key default gen_random_uuid(),
  tenant_id text not null references wms.tenants(id) on delete cascade,
  warehouse_id uuid not null references wms.warehouses(id) on delete cascade,
  -- unique: exactly one profile per equipment (design.md D7). A follow-up
  -- spec wanting equipment_type-level defaults would relax this column to
  -- nullable and add a partial unique index — the shape does not block it.
  equipment_id uuid not null unique references wms.equipment(id) on delete cascade,
  min_carton_gap_mm int not null check (min_carton_gap_mm > 0),
  speed_mode text not null default 'FIXED' check (speed_mode in ('FIXED', 'AUTO')),
  min_speed_value numeric not null check (min_speed_value > 0),
  max_speed_value numeric not null,
  -- free text, but every SET_SPEED payload for this equipment must match it
  -- (design.md D3) — the contract never converts between units.
  speed_unit text not null default 'MPS',
  sensor_detection_window_ms int not null check (sensor_detection_window_ms > 0),
  status text not null default 'ACTIVE' check (status in ('ACTIVE', 'INACTIVE')),
  version int not null default 1,
  correlation_id text,
  created_by uuid,
  updated_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint sortation_profiles_speed_range_ck check (min_speed_value <= max_speed_value)
);

create index sortation_profiles_warehouse_idx
  on wms.sortation_profiles (warehouse_id, status);

-- ============================================================
-- RLS: SELECT-only for tenant/warehouse members; every write goes through the
-- SECURITY DEFINER RPCs below (same pattern as the three prior migrations).
-- ============================================================

alter table wms.sortation_profiles enable row level security;
create policy sortation_profiles_select on wms.sortation_profiles for select to authenticated
  using (warehouse_id in (select wms.current_warehouse_ids(tenant_id)));

grant select on wms.sortation_profiles to authenticated;

-- ============================================================
-- command_type extension (design.md D2)
--
-- The constraint name below is the one Postgres actually generated for the
-- inline column CHECK in 20260727_wcs_equipment_control.sql, verified with
--   select conname from pg_constraint
--   where conrelid = 'wms.equipment_commands'::regclass and contype = 'c';
-- -> equipment_commands_command_type_check
-- ============================================================

alter table wms.equipment_commands
  drop constraint equipment_commands_command_type_check;
alter table wms.equipment_commands
  add constraint equipment_commands_command_type_check
  check (command_type in (
    'MOVE', 'LOAD', 'UNLOAD', 'START', 'STOP', 'RESET', 'HOLD', 'RESUME',
    'DIVERT', 'SET_SPEED'
  ));

-- ------------------------------------------------------------
-- DEVIATION 1 (see header): same body as
-- 20260727_wcs_equipment_control.sql's wms_dispatch_equipment_command, with
-- 'DIVERT'/'SET_SPEED' added to the command_type guard and nothing else
-- changed. Kept here rather than in area 1's file so that migration stays
-- untouched.
-- ------------------------------------------------------------

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
  v_tenant_id text;
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
  -- extended by wms_wcs-sortation-logic (20260729): DIVERT / SET_SPEED
  if p_command_type not in ('MOVE', 'LOAD', 'UNLOAD', 'START', 'STOP', 'RESET', 'HOLD', 'RESUME',
                            'DIVERT', 'SET_SPEED') then
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

-- ============================================================
-- Payload validation (design.md D3)
--
-- A BEFORE INSERT trigger rather than a new/edited dispatch RPC: the same
-- pattern add-wes-material-flow-control used (D2) for attaching behaviour to a
-- table another spec owns. Callers still see a plain `INVALID:` error coming
-- out of wms_dispatch_equipment_command — no separate error channel.
-- ============================================================

create or replace function wms._wms_validate_sortation_command()
returns trigger
language plpgsql security definer
set search_path = wms, public
as $$
declare
  v_equipment wms.equipment%rowtype;
  v_profile wms.sortation_profiles%rowtype;
  v_speed numeric;
begin
  if new.command_type not in ('DIVERT', 'SET_SPEED') then
    return new;
  end if;

  select * into v_equipment from wms.equipment where id = new.equipment_id;
  if not found then
    raise exception 'INVALID: unknown equipment %', new.equipment_id;
  end if;
  if v_equipment.equipment_type not in ('SORTER', 'CONVEYOR') then
    raise exception 'INVALID: % is only valid for SORTER/CONVEYOR equipment (% is %)',
      new.command_type, v_equipment.equipment_code, v_equipment.equipment_type;
  end if;

  -- No profile means no gap/speed baseline to validate against, so the
  -- operating order "register equipment -> register profile -> dispatch" is
  -- enforced here rather than left to convention (design.md D3).
  select * into v_profile from wms.sortation_profiles where equipment_id = new.equipment_id;
  if not found then
    raise exception 'INVALID: equipment % has no sortation profile — register one before dispatching %',
      v_equipment.equipment_code, new.command_type;
  end if;
  if v_profile.status <> 'ACTIVE' then
    raise exception 'INVALID: sortation profile for % is % — activate it before dispatching %',
      v_equipment.equipment_code, v_profile.status, new.command_type;
  end if;

  if new.command_type = 'DIVERT' then
    if coalesce(btrim(new.payload->>'target_chute'), '') = '' then
      raise exception 'INVALID: DIVERT payload requires target_chute';
    end if;
    if coalesce(btrim(new.payload->>'item_identifier'), '') = '' then
      raise exception 'INVALID: DIVERT payload requires item_identifier';
    end if;
    -- optional; when omitted the profile's min_carton_gap_mm is the expectation
    if new.payload ? 'expected_gap_mm' then
      if jsonb_typeof(new.payload->'expected_gap_mm') <> 'number'
         or (new.payload->>'expected_gap_mm')::numeric <= 0 then
        raise exception 'INVALID: DIVERT payload expected_gap_mm must be a positive number';
      end if;
    end if;
    return new;
  end if;

  -- SET_SPEED
  if coalesce(new.payload->>'speed_mode', '') not in ('FIXED', 'AUTO') then
    raise exception 'INVALID: SET_SPEED payload requires speed_mode FIXED or AUTO';
  end if;
  if coalesce(btrim(new.payload->>'speed_unit'), '') = '' then
    raise exception 'INVALID: SET_SPEED payload requires speed_unit';
  end if;
  if new.payload->>'speed_unit' <> v_profile.speed_unit then
    raise exception 'INVALID: SET_SPEED speed_unit % does not match the profile unit % for %',
      new.payload->>'speed_unit', v_profile.speed_unit, v_equipment.equipment_code;
  end if;

  -- AUTO delegates the decision to the equipment inside the profile range
  -- (design.md D8), so speed_value is not required and is ignored.
  if new.payload->>'speed_mode' = 'FIXED' then
    if not (new.payload ? 'speed_value') or jsonb_typeof(new.payload->'speed_value') <> 'number' then
      raise exception 'INVALID: SET_SPEED with speed_mode=FIXED requires a numeric speed_value';
    end if;
    v_speed := (new.payload->>'speed_value')::numeric;
    if v_speed < v_profile.min_speed_value or v_speed > v_profile.max_speed_value then
      raise exception 'INVALID: speed_value % is outside the profile range %..% % for %',
        v_speed, v_profile.min_speed_value, v_profile.max_speed_value, v_profile.speed_unit,
        v_equipment.equipment_code;
    end if;
  end if;

  return new;
end;
$$;

-- Attached to a table this migration does not own; revisit if
-- wms_wcs-equipment-control reshapes wms.equipment_commands
-- (design.md "Risks / Trade-offs").
create trigger equipment_commands_validate_sortation
before insert on wms.equipment_commands
for each row
when (new.command_type in ('DIVERT', 'SET_SPEED'))
execute function wms._wms_validate_sortation_command();

-- ============================================================
-- Outcome <-> command-status consistency (design.md D4)
--
-- No new command state: SUCCESS must arrive as COMPLETED, MISROUTE/JAM must
-- arrive as FAILED. Only terminal events reported for a DIVERT command are
-- checked; events emitted by the fault path carry no `outcome` and pass
-- straight through.
-- ============================================================

create or replace function wms._wms_validate_sortation_outcome()
returns trigger
language plpgsql security definer
set search_path = wms, public
as $$
declare
  v_command wms.equipment_commands%rowtype;
  v_outcome text;
begin
  if new.command_id is null or new.detail is null then
    return new;
  end if;
  v_outcome := new.detail->>'outcome';
  if v_outcome is null then
    return new;
  end if;

  select * into v_command from wms.equipment_commands where id = new.command_id;
  if not found or v_command.command_type <> 'DIVERT' then
    return new;
  end if;

  if v_outcome not in ('SUCCESS', 'MISROUTE', 'JAM') then
    raise exception 'INVALID: DIVERT outcome must be one of SUCCESS, MISROUTE, JAM (got %)', v_outcome;
  end if;
  if v_outcome = 'SUCCESS' and new.event_type <> 'COMMAND_COMPLETED' then
    raise exception 'INVALID: outcome=SUCCESS requires command_status=COMPLETED';
  end if;
  if v_outcome in ('MISROUTE', 'JAM') and new.event_type <> 'COMMAND_FAILED' then
    raise exception 'INVALID: outcome=% requires command_status=FAILED', v_outcome;
  end if;

  return new;
end;
$$;

create trigger equipment_status_events_validate_sortation_outcome
before insert on wms.equipment_status_events
for each row
when (new.event_type in ('COMMAND_COMPLETED', 'COMMAND_FAILED'))
execute function wms._wms_validate_sortation_outcome();

-- ============================================================
-- Automatic fault escalation on JAM (design.md D5)
--
-- A physical jam blocks every follow-up command, so it is promoted to a real
-- equipment fault with no separate manual report. MISROUTE is not — that is a
-- per-item routing miss and the machine keeps running.
--
-- The escalation calls wms_raise_equipment_fault itself rather than
-- re-implementing it, so equipment -> FAULT, outstanding commands -> FAILED,
-- the FAULT_RAISED event and the audit row are all exactly area 1's (D4).
-- The reporter (WCS_GATEWAY / WMS_ADMIN) is always inside that RPC's own role
-- set, so the nested call is authorised by the same session.
--
-- Re-entrancy: the events wms_raise_equipment_fault emits carry no
-- `outcome` key, so neither this trigger nor the validation trigger above
-- reacts to them.
-- ============================================================

create or replace function wms._wms_escalate_sortation_jam()
returns trigger
language plpgsql security definer
set search_path = wms, public
as $$
declare
  v_command wms.equipment_commands%rowtype;
  v_equipment wms.equipment%rowtype;
  v_fault jsonb;
begin
  if new.command_id is null then
    return null;
  end if;

  select * into v_command from wms.equipment_commands where id = new.command_id;
  if not found or v_command.command_type <> 'DIVERT' then
    return null;
  end if;

  select * into v_equipment from wms.equipment where id = new.equipment_id;
  -- already faulted (e.g. a second jam inside one transaction): area 1's
  -- fault state machine is already doing the right thing, don't stack faults.
  if v_equipment.status = 'FAULT' then
    return null;
  end if;

  v_fault := wms.wms_raise_equipment_fault(
    v_equipment.id, 'SORTATION_JAM', 'CRITICAL',
    new.reported_by, gen_random_uuid(), new.correlation_id
  );

  -- The jammed command was already moved to FAILED by
  -- wms_report_command_result before this event was written, so the fault
  -- RPC's "fail everything outstanding" loop does not see it. Link it to the
  -- fault anyway (spec.md: "새로 생성된 장애 레코드가 두 명령 모두와
  -- 연결된다"). No version bump — the reporting RPC has already returned that
  -- command's version to its caller.
  update wms.equipment_commands
  set fault_id = (v_fault->>'fault_id')::uuid,
      reason = coalesce(reason, 'sortation jam ' || coalesce(new.detail->>'reason', ''))
  where id = v_command.id and fault_id is null;

  -- area 1's own audit row records the fault document (before = the equipment
  -- row, after = the fault row), so it never spells out the equipment
  -- transition. spec.md "감사 추적" asks for exactly that, so the escalation
  -- adds its own row rather than rewriting area 1's.
  insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, before, after, correlation_id)
  values (
    v_equipment.tenant_id, new.reported_by, 'wms_escalate_sortation_jam', 'equipment_fault',
    (v_fault->>'fault_id')::uuid,
    jsonb_build_object(
      'equipment_status', v_equipment.status,
      'command_id', v_command.id,
      'command_type', v_command.command_type),
    jsonb_build_object(
      'equipment_status', v_fault->>'equipment_status',
      'fault_id', v_fault->>'fault_id',
      'fault_code', 'SORTATION_JAM',
      'severity', 'CRITICAL',
      'outcome', 'JAM',
      'reason', new.detail->>'reason',
      'failed_command_ids', v_fault->'failed_command_ids'),
    new.correlation_id
  );

  return null;
end;
$$;

create trigger equipment_status_events_escalate_sortation_jam
after insert on wms.equipment_status_events
for each row
when (new.event_type = 'COMMAND_FAILED' and new.detail->>'outcome' = 'JAM')
execute function wms._wms_escalate_sortation_jam();

-- ============================================================
-- Command RPCs
-- Envelope in:  tenant_id / warehouse_id (implied by the target row for
--               id-addressed calls), actor_id, idempotency_key,
--               expected_version, correlation_id.
-- Envelope out: {result, document_id, status, version, next_actions, warnings}.
-- Errors:       RAISE EXCEPTION with CONFLICT:/FORBIDDEN:/INVALID: prefix.
--
-- DIVERT / SET_SPEED dispatch, cancellation and result reporting have no RPC
-- of their own — they reuse wms_wcs-equipment-control's
-- wms_dispatch_equipment_command / wms_cancel_equipment_command /
-- wms_report_command_result, distinguished only by command_type + payload.
-- ============================================================

-- Params with defaults are moved to the tail of the signature (Postgres
-- requires it); callers use named arguments, so the order is not load-bearing.
create or replace function wms.wms_create_sortation_profile(
  p_equipment_id uuid,
  p_min_carton_gap_mm int,
  p_min_speed_value numeric,
  p_max_speed_value numeric,
  p_sensor_detection_window_ms int,
  p_actor_id uuid,
  p_idempotency_key uuid,
  p_speed_mode text default 'FIXED',
  p_speed_unit text default 'MPS',
  p_correlation_id text default null
) returns jsonb
language plpgsql security definer
set search_path = wms, public
as $$
declare
  v_cached jsonb;
  v_equipment wms.equipment%rowtype;
  v_profile wms.sortation_profiles%rowtype;
  v_tenant_id text;
begin
  select tenant_id into v_tenant_id from wms.equipment where id = p_equipment_id;
  if p_idempotency_key is not null and v_tenant_id is not null then
    select response into v_cached from wms.idempotency_records
      where tenant_id = v_tenant_id and command_name = 'wms_create_sortation_profile' and idempotency_key = p_idempotency_key;
    if found then return v_cached; end if;
  end if;

  select * into v_equipment from wms.equipment where id = p_equipment_id;
  if not found then
    raise exception 'INVALID: unknown equipment %', p_equipment_id;
  end if;
  if v_equipment.warehouse_id not in (select wms.current_warehouse_ids(v_equipment.tenant_id)) then
    raise exception 'FORBIDDEN: no warehouse scope for equipment %', p_equipment_id;
  end if;
  if not wms.has_role(v_equipment.tenant_id, 'WMS_ADMIN', 'WAREHOUSE_MANAGER', 'WCS_OPERATOR') then
    raise exception 'FORBIDDEN: role cannot manage sortation profiles';
  end if;
  if v_equipment.equipment_type not in ('SORTER', 'CONVEYOR') then
    raise exception 'INVALID: sortation profiles only apply to SORTER/CONVEYOR equipment (% is %)',
      v_equipment.equipment_code, v_equipment.equipment_type;
  end if;
  if exists (select 1 from wms.sortation_profiles where equipment_id = p_equipment_id) then
    raise exception 'INVALID: equipment % already has a sortation profile — update it instead',
      v_equipment.equipment_code;
  end if;
  if p_speed_mode not in ('FIXED', 'AUTO') then
    raise exception 'INVALID: speed_mode must be FIXED or AUTO';
  end if;
  if coalesce(p_min_carton_gap_mm, 0) <= 0 then
    raise exception 'INVALID: min_carton_gap_mm must be greater than 0';
  end if;
  if coalesce(p_sensor_detection_window_ms, 0) <= 0 then
    raise exception 'INVALID: sensor_detection_window_ms must be greater than 0';
  end if;
  if coalesce(p_min_speed_value, 0) <= 0 then
    raise exception 'INVALID: min_speed_value must be greater than 0';
  end if;
  if p_max_speed_value is null or p_min_speed_value > p_max_speed_value then
    raise exception 'INVALID: min_speed_value must be less than or equal to max_speed_value';
  end if;
  if coalesce(btrim(p_speed_unit), '') = '' then
    raise exception 'INVALID: speed_unit is required';
  end if;

  insert into wms.sortation_profiles (
    tenant_id, warehouse_id, equipment_id, min_carton_gap_mm, speed_mode,
    min_speed_value, max_speed_value, speed_unit, sensor_detection_window_ms,
    status, correlation_id, created_by, updated_by
  ) values (
    v_equipment.tenant_id, v_equipment.warehouse_id, v_equipment.id, p_min_carton_gap_mm, p_speed_mode,
    p_min_speed_value, p_max_speed_value, p_speed_unit, p_sensor_detection_window_ms,
    'ACTIVE', p_correlation_id, p_actor_id, p_actor_id
  )
  returning * into v_profile;

  insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, before, after, correlation_id)
  values (v_profile.tenant_id, p_actor_id, 'wms_create_sortation_profile', 'sortation_profile', v_profile.id,
          null, to_jsonb(v_profile), p_correlation_id);

  v_cached := jsonb_build_object(
    'result', 'ok',
    'document_id', v_profile.id,
    'profile_id', v_profile.id,
    'equipment_id', v_equipment.id,
    'equipment_code', v_equipment.equipment_code,
    'status', v_profile.status,
    'version', v_profile.version,
    'warnings', '[]'::jsonb,
    'next_actions', jsonb_build_array('dispatch_equipment_command', 'get_sortation_profile',
                                      'update_sortation_profile')
  );
  if p_idempotency_key is not null then
    insert into wms.idempotency_records (tenant_id, command_name, idempotency_key, response)
    values (v_profile.tenant_id, 'wms_create_sortation_profile', p_idempotency_key, v_cached)
    on conflict do nothing;
  end if;
  return v_cached;
end;
$$;

-- expected_version is the PROFILE version. Null parameters mean "leave as is".
create or replace function wms.wms_update_sortation_profile(
  p_profile_id uuid,
  p_actor_id uuid,
  p_idempotency_key uuid,
  p_expected_version int,
  p_min_carton_gap_mm int default null,
  p_speed_mode text default null,
  p_min_speed_value numeric default null,
  p_max_speed_value numeric default null,
  p_speed_unit text default null,
  p_sensor_detection_window_ms int default null,
  p_status text default null,
  p_correlation_id text default null
) returns jsonb
language plpgsql security definer
set search_path = wms, public
as $$
declare
  v_cached jsonb;
  v_profile wms.sortation_profiles%rowtype;
  v_before jsonb;
  v_equipment wms.equipment%rowtype;
  v_tenant_id text;
  v_min numeric;
  v_max numeric;
  v_warnings jsonb := '[]'::jsonb;
begin
  select tenant_id into v_tenant_id from wms.sortation_profiles where id = p_profile_id;
  if p_idempotency_key is not null and v_tenant_id is not null then
    select response into v_cached from wms.idempotency_records
      where tenant_id = v_tenant_id and command_name = 'wms_update_sortation_profile' and idempotency_key = p_idempotency_key;
    if found then return v_cached; end if;
  end if;

  select * into v_profile from wms.sortation_profiles where id = p_profile_id for update;
  if not found then
    raise exception 'INVALID: unknown sortation profile %', p_profile_id;
  end if;
  if v_profile.warehouse_id not in (select wms.current_warehouse_ids(v_profile.tenant_id)) then
    raise exception 'FORBIDDEN: no warehouse scope for sortation profile %', p_profile_id;
  end if;
  if not wms.has_role(v_profile.tenant_id, 'WMS_ADMIN', 'WAREHOUSE_MANAGER', 'WCS_OPERATOR') then
    raise exception 'FORBIDDEN: role cannot manage sortation profiles';
  end if;
  if v_profile.version <> p_expected_version then
    raise exception 'CONFLICT: expected version % but found %', p_expected_version, v_profile.version;
  end if;
  if p_speed_mode is not null and p_speed_mode not in ('FIXED', 'AUTO') then
    raise exception 'INVALID: speed_mode must be FIXED or AUTO';
  end if;
  if p_status is not null and p_status not in ('ACTIVE', 'INACTIVE') then
    raise exception 'INVALID: status must be ACTIVE or INACTIVE';
  end if;
  if p_min_carton_gap_mm is not null and p_min_carton_gap_mm <= 0 then
    raise exception 'INVALID: min_carton_gap_mm must be greater than 0';
  end if;
  if p_sensor_detection_window_ms is not null and p_sensor_detection_window_ms <= 0 then
    raise exception 'INVALID: sensor_detection_window_ms must be greater than 0';
  end if;

  v_min := coalesce(p_min_speed_value, v_profile.min_speed_value);
  v_max := coalesce(p_max_speed_value, v_profile.max_speed_value);
  if v_min <= 0 then
    raise exception 'INVALID: min_speed_value must be greater than 0';
  end if;
  if v_min > v_max then
    raise exception 'INVALID: min_speed_value must be less than or equal to max_speed_value';
  end if;
  if p_speed_unit is not null and btrim(p_speed_unit) = '' then
    raise exception 'INVALID: speed_unit is required';
  end if;

  v_before := to_jsonb(v_profile);

  update wms.sortation_profiles
  set min_carton_gap_mm = coalesce(p_min_carton_gap_mm, min_carton_gap_mm),
      speed_mode = coalesce(p_speed_mode, speed_mode),
      min_speed_value = v_min,
      max_speed_value = v_max,
      speed_unit = coalesce(p_speed_unit, speed_unit),
      sensor_detection_window_ms = coalesce(p_sensor_detection_window_ms, sensor_detection_window_ms),
      status = coalesce(p_status, status),
      correlation_id = coalesce(p_correlation_id, correlation_id),
      version = version + 1,
      updated_by = p_actor_id,
      updated_at = now()
  where id = p_profile_id
  returning * into v_profile;

  select * into v_equipment from wms.equipment where id = v_profile.equipment_id;

  -- narrowing the range does not retro-validate commands already dispatched;
  -- say so rather than pretend otherwise (design.md Non-Goals).
  if exists (
    select 1 from wms.equipment_commands
    where equipment_id = v_profile.equipment_id
      and command_type in ('DIVERT', 'SET_SPEED')
      and status in ('PENDING', 'ACKNOWLEDGED', 'IN_PROGRESS')
  ) then
    v_warnings := v_warnings || to_jsonb('IN_FLIGHT_COMMANDS_NOT_REVALIDATED'::text);
  end if;

  insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, before, after, correlation_id)
  values (v_profile.tenant_id, p_actor_id, 'wms_update_sortation_profile', 'sortation_profile', v_profile.id,
          v_before, to_jsonb(v_profile), p_correlation_id);

  v_cached := jsonb_build_object(
    'result', 'ok',
    'document_id', v_profile.id,
    'profile_id', v_profile.id,
    'equipment_id', v_profile.equipment_id,
    'equipment_code', v_equipment.equipment_code,
    'status', v_profile.status,
    'version', v_profile.version,
    'warnings', v_warnings,
    'next_actions', jsonb_build_array('get_sortation_profile', 'dispatch_equipment_command')
  );
  if p_idempotency_key is not null then
    insert into wms.idempotency_records (tenant_id, command_name, idempotency_key, response)
    values (v_profile.tenant_id, 'wms_update_sortation_profile', p_idempotency_key, v_cached)
    on conflict do nothing;
  end if;
  return v_cached;
end;
$$;

-- Read-only join: every SORTER/CONVEYOR in the warehouse with its profile
-- (null when none is registered yet) plus its in-flight sortation commands and
-- the last reported DIVERT outcome. Mirrors wms_get_equipment_status's shape.
create or replace function wms.wms_get_sortation_profile(
  p_tenant_id text,
  p_warehouse_id uuid,
  p_equipment_id uuid default null
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
      'equipment_status', e.status,
      'equipment_version', e.version,
      'has_profile', p.id is not null,
      'profile', case when p.id is null then null else jsonb_build_object(
        'profile_id', p.id,
        'min_carton_gap_mm', p.min_carton_gap_mm,
        'speed_mode', p.speed_mode,
        'min_speed_value', p.min_speed_value,
        'max_speed_value', p.max_speed_value,
        'speed_unit', p.speed_unit,
        'sensor_detection_window_ms', p.sensor_detection_window_ms,
        'status', p.status,
        'version', p.version,
        'updated_at', p.updated_at
      ) end,
      'active_sortation_commands', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'command_id', c.id, 'command_type', c.command_type, 'status', c.status,
          'version', c.version, 'payload', c.payload
        ) order by c.created_at), '[]'::jsonb)
        from wms.equipment_commands c
        where c.equipment_id = e.id
          and c.command_type in ('DIVERT', 'SET_SPEED')
          and c.status in ('PENDING', 'ACKNOWLEDGED', 'IN_PROGRESS')
      ),
      'last_outcome', (
        select s.detail->>'outcome'
        from wms.equipment_status_events s
        where s.equipment_id = e.id and s.detail ? 'outcome'
        order by s.seq desc
        limit 1
      ),
      'open_faults', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'fault_id', f.id, 'fault_code', f.fault_code, 'severity', f.severity, 'version', f.version
        ) order by f.created_at), '[]'::jsonb)
        from wms.equipment_faults f
        where f.equipment_id = e.id and f.status = 'OPEN'
      )
    ) as item
    from wms.equipment e
    left join wms.sortation_profiles p on p.equipment_id = e.id
    where e.tenant_id = p_tenant_id
      and e.warehouse_id = p_warehouse_id
      and e.equipment_type in ('SORTER', 'CONVEYOR')
      and (p_equipment_id is null or e.id = p_equipment_id)
  ) rows;

  return jsonb_build_object(
    'result', 'ok',
    'tenant_id', p_tenant_id,
    'warehouse_id', p_warehouse_id,
    'items', v_items,
    'count', jsonb_array_length(v_items)
  );
end;
$$;

grant execute on function wms.wms_create_sortation_profile(uuid, int, numeric, numeric, int, uuid, uuid, text, text, text) to authenticated;
grant execute on function wms.wms_update_sortation_profile(uuid, uuid, uuid, int, int, text, numeric, numeric, text, int, text, text) to authenticated;
grant execute on function wms.wms_get_sortation_profile(text, uuid, uuid) to authenticated;
