-- ============================================================
-- WCS sequential-dispatch / intelligent-palletising contract
-- Scope: openspec/changes/add-wcs-sequential-dispatch
--        (proposal.md / design.md / specs/wms_wcs-sequential-dispatch/spec.md)
--
-- Two axes of the market catalogue's "서열 출고 / 지능형 적재"
-- (docs/04-wms-wcs-market-feature-catalog.md §2.3, §3):
--   1. a minimal outbound unit that can be ordered (wms.outbound_orders) and
--      an assignment of that unit to a position inside a dispatch wave
--      (wms.dispatch_sequences),
--   2. the ROBOT_CELL command payload contract for mixed palletising
--      (PALLETIZE) and automatic stretch wrapping (WRAP) that rides on top of
--      wms_wcs-equipment-control's generic command envelope, plus the
--      per-item completion propagation that turns one command result into N
--      individual sequence outcomes.
--
-- Conventions (schema, common columns, RLS helpers, RPC envelope,
-- CONFLICT:/FORBIDDEN:/INVALID: prefixes, idempotency records, audit events)
-- are identical to the five migrations before it, and none of those files is
-- modified here.
--
-- ORDERING: this migration REQUIRES
--   20260727_wcs_equipment_control.sql  (wms.equipment, wms.equipment_commands,
--                                        wms.equipment_status_events,
--                                        wms_dispatch_equipment_command,
--                                        wms_report_command_result,
--                                        wms_cancel_equipment_command)
--   20260728_wes_material_flow_control.sql — only wms.dispatch_waves. There is
--                                        NO dependency on wms.work_orders
--                                        (design.md D1).
-- It has no dependency on 20260729 (sortation) or 20260730 (bottleneck
-- routing), but it is ordered after them so the history stays linear and so
-- the command_type replacement below is rebased on the newest shipped body.
--
-- ------------------------------------------------------------
-- DEVIATION 1 from design.md ("command_type CHECK 제약 확장") — the exact same
-- trap add-wcs-sortation-logic hit, and it is still there:
--
--   design.md assumes relaxing wms.equipment_commands' CHECK constraint is
--   enough to make PALLETIZE/WRAP dispatchable. It is not. The shipped
--   wms_dispatch_equipment_command ALSO hard-codes the accepted command types
--   in its own guard:
--       if p_command_type not in ('MOVE',...,'RESUME','DIVERT','SET_SPEED') then
--         raise exception 'INVALID: unknown command_type %', p_command_type;
--   so a PALLETIZE would be refused by the RPC long before the relaxed CHECK
--   constraint is reached. Relaxing the constraint alone is a no-op.
--
--   The live body of that function is area 3's replacement (20260729), not
--   area 1's original — area 4 did not touch it (it replaced
--   _wms_pick_equipment_for_work_order instead). So the `create or replace`
--   below is rebased on area 3's body with 'PALLETIZE'/'WRAP' added to that one
--   list and NOTHING else changed. Area 1's and area 3's migration files stay
--   untouched. If either ever reshapes that RPC, this replacement must be
--   re-based on it again.
--
-- DEVIATION 2 from design.md's role table — WMS_ADMIN and the palletising
-- dispatch, the same partial-failure trap area 2 documented:
--
--   design.md lists WMS_ADMIN as an allowed caller of
--   wms_dispatch_palletize_command. But that RPC internally calls
--   wms_dispatch_equipment_command, which allows
--     WAREHOUSE_MANAGER, WCS_OPERATOR, PROCESS_AGENT
--   and, unlike every other RPC in area 1, NOT WMS_ADMIN. Honouring design.md
--   literally would let a WMS_ADMIN pass this contract's own guard and then get
--   FORBIDDEN from the inner dispatch — after the sequence rows had already
--   been read and the payload built. So wms_dispatch_palletize_command uses the
--   dispatch-capable set instead. The other three write RPCs never dispatch
--   anything, so they keep design.md's list (WMS_ADMIN included). The
--   consequence — WMS_ADMIN may register outbound orders and assign/cancel
--   sequences but may not send PALLETIZE/WRAP — is surfaced in the UI, not
--   hidden. See openspec/specs/wms_wcs-sequential-dispatch/e2e/README.md.
--
-- DEVIATION 3 from tasks.md 1.6 ("unique (outbound_order_id)",
-- "unique (wave_id, sequence_position)"):
--
--   Both are implemented as PARTIAL unique indexes rather than plain UNIQUE
--   constraints, because design.md's own wording is "출고 단위당 **활성** 서열
--   배정 1건만". A plain UNIQUE would make a cancelled assignment permanently
--   poison both the outbound order and the sequence position — you could never
--   re-sequence an order after cancelling it, which is exactly what the
--   "서열 배정 취소" requirement exists to enable. CANCELLED rows are therefore
--   excluded from both indexes, and a cancelled assignment returns its outbound
--   order to OPEN so it can be re-sequenced.
--
-- DEVIATION 4 — cancelling one DISPATCHED sequence cancels its siblings.
--
--   spec.md's "디스패치된 서열 배정을 취소하면 연결된 설비 명령도 취소된다"
--   was written as if a sequence owned its command 1:1. It does not: D3 makes
--   PALLETIZE deliberately N:1 (every sequence sharing a (wave, pallet) rides
--   one command). Cancelling that command therefore also invalidates every
--   sibling sequence on it — leaving them DISPATCHED against a CANCELLED
--   command would be a lie. So the cancel RPC moves the siblings to CANCELLED
--   too, audits each one, lists them in `cancelled_sibling_sequence_ids` and
--   raises a SIBLING_SEQUENCES_CANCELLED warning. Only the *addressed*
--   sequence's expected_version is checked (the caller cannot know the
--   siblings' versions).
-- ============================================================

-- ------------------------------------------------------------
-- Tables
-- ------------------------------------------------------------

-- The minimal outbound unit (design.md D2). Flattened exactly like
-- wms.purchase_orders — one product per row, no header/lines split. This is
-- NOT an outbound-fulfilment model: no allocation, no reservation, no lot or
-- serial, no ledger effect. It exists so that "서열" has something to order.
create table wms.outbound_orders (
  id uuid primary key default gen_random_uuid(),
  tenant_id text not null references wms.tenants(id) on delete cascade,
  warehouse_id uuid not null references wms.warehouses(id) on delete cascade,
  -- external/manual reference; duplicates are allowed on purpose — dedup is
  -- the idempotency_key's job, not this column's.
  order_number text,
  -- store / delivery destination; the catalogue's "매장 진열 순서" hangs off it
  store_code text not null,
  product_id uuid not null references wms.products(id),
  qty numeric not null check (qty > 0),
  requested_delivery_date date,
  -- caller-declared, NOT master data: wms.products has no weight/volume columns
  -- and this change does not add them (design.md "정직한 전제 확인").
  declared_weight_kg numeric check (declared_weight_kg >= 0),
  declared_volume_l numeric check (declared_volume_l >= 0),
  status text not null default 'OPEN'
    check (status in ('OPEN', 'SEQUENCED', 'DISPATCHED', 'COMPLETED', 'FAILED', 'CANCELLED')),
  version int not null default 1,
  correlation_id text,
  created_by uuid,
  updated_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- One outbound unit's position inside one dispatch wave (design.md D1).
-- Deliberately NOT wms.work_orders: PALLETIZE is a batch (N sequences : 1
-- command), which area 2's 1:1 work-order shape cannot express.
create table wms.dispatch_sequences (
  id uuid primary key default gen_random_uuid(),
  tenant_id text not null references wms.tenants(id) on delete cascade,
  warehouse_id uuid not null references wms.warehouses(id) on delete cascade,
  outbound_order_id uuid not null references wms.outbound_orders(id) on delete cascade,
  wave_id uuid not null references wms.dispatch_waves(id) on delete restrict,
  sequence_position int not null check (sequence_position > 0),
  -- the caller's grouping decision (design.md D3) — this contract never
  -- computes it (Non-Goals: no bin packing, no store-route optimiser).
  target_pallet_code text not null,
  status text not null default 'QUEUED'
    check (status in ('QUEUED', 'DISPATCHED', 'COMPLETED', 'FAILED', 'CANCELLED')),
  -- filled only after a successful PALLETIZE dispatch; N rows share one id.
  equipment_command_id uuid references wms.equipment_commands(id) on delete set null,
  -- reported by the robot cell; may differ from the planned sequence_position.
  load_position int,
  reason text,
  version int not null default 1,
  correlation_id text,
  created_by uuid,
  updated_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- DEVIATION 3: partial, so a CANCELLED assignment frees both the order and
-- the position again.
create unique index dispatch_sequences_active_order_uk
  on wms.dispatch_sequences (outbound_order_id)
  where status <> 'CANCELLED';
create unique index dispatch_sequences_active_position_uk
  on wms.dispatch_sequences (wave_id, sequence_position)
  where status <> 'CANCELLED';

create index outbound_orders_warehouse_status_idx
  on wms.outbound_orders (warehouse_id, status);
create index dispatch_sequences_wave_status_idx
  on wms.dispatch_sequences (wave_id, status);
create index dispatch_sequences_pallet_idx
  on wms.dispatch_sequences (wave_id, target_pallet_code, status);
create index dispatch_sequences_command_idx
  on wms.dispatch_sequences (equipment_command_id);

-- ============================================================
-- RLS: SELECT-only for tenant/warehouse members; every write goes through the
-- SECURITY DEFINER RPCs below (same pattern as the five prior migrations).
-- ============================================================

alter table wms.outbound_orders enable row level security;
create policy outbound_orders_select on wms.outbound_orders for select to authenticated
  using (warehouse_id in (select wms.current_warehouse_ids(tenant_id)));

alter table wms.dispatch_sequences enable row level security;
create policy dispatch_sequences_select on wms.dispatch_sequences for select to authenticated
  using (warehouse_id in (select wms.current_warehouse_ids(tenant_id)));

grant select on wms.outbound_orders to authenticated;
grant select on wms.dispatch_sequences to authenticated;

-- ============================================================
-- command_type extension
--
-- The constraint was already replaced once by 20260729_wcs_sortation_logic.sql
-- (DIVERT / SET_SPEED), so the current value set — not area 1's original — is
-- the baseline here. Verified with
--   select pg_get_constraintdef(oid) from pg_constraint
--   where conrelid = 'wms.equipment_commands'::regclass
--     and conname = 'equipment_commands_command_type_check';
-- ============================================================

alter table wms.equipment_commands
  drop constraint equipment_commands_command_type_check;
alter table wms.equipment_commands
  add constraint equipment_commands_command_type_check
  check (command_type in (
    'MOVE', 'LOAD', 'UNLOAD', 'START', 'STOP', 'RESET', 'HOLD', 'RESUME',
    'DIVERT', 'SET_SPEED',
    'PALLETIZE', 'WRAP'
  ));

-- ------------------------------------------------------------
-- DEVIATION 1 (see header): area 3's body of wms_dispatch_equipment_command
-- with 'PALLETIZE'/'WRAP' added to the command_type guard and nothing else
-- changed. Kept here so neither area 1's nor area 3's migration is edited.
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
  -- extended by wms_wcs-sequential-dispatch (20260731): PALLETIZE / WRAP
  if p_command_type not in ('MOVE', 'LOAD', 'UNLOAD', 'START', 'STOP', 'RESET', 'HOLD', 'RESUME',
                            'DIVERT', 'SET_SPEED',
                            'PALLETIZE', 'WRAP') then
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
-- Payload validation (design.md D4, D7, D8)
--
-- A BEFORE INSERT trigger, the same way area 2 and area 3 attach behaviour to
-- a table they do not own. Callers see a plain `INVALID:` coming out of
-- wms_dispatch_equipment_command — no separate error channel, and the
-- validation holds even when the generic dispatch RPC is called directly with
-- a hand-written PALLETIZE payload (tasks.md 3.9).
--
-- The weight/volume ceiling is checked HERE and not in
-- wms_dispatch_palletize_command, so there is exactly one implementation of
-- design.md D7's planning-time check no matter which door the command comes
-- through.
-- ============================================================

create or replace function wms._wms_validate_palletize_command()
returns trigger
language plpgsql security definer
set search_path = wms, public
as $$
declare
  v_equipment wms.equipment%rowtype;
  v_item jsonb;
  v_prev int := 0;
  v_pos int;
  v_count int := 0;
  v_weight numeric := 0;
  v_volume numeric := 0;
  v_max numeric;
begin
  if new.command_type not in ('PALLETIZE', 'WRAP') then
    return new;
  end if;

  select * into v_equipment from wms.equipment where id = new.equipment_id;
  if not found then
    raise exception 'INVALID: unknown equipment %', new.equipment_id;
  end if;
  if v_equipment.equipment_type <> 'ROBOT_CELL' then
    raise exception 'INVALID: % is only valid for ROBOT_CELL equipment (% is %)',
      new.command_type, v_equipment.equipment_code, v_equipment.equipment_type;
  end if;

  if new.command_type = 'WRAP' then
    -- design.md D8: thin on purpose — structure only, no state propagation.
    if coalesce(btrim(new.payload->>'pallet_code'), '') = '' then
      raise exception 'INVALID: WRAP payload requires pallet_code';
    end if;
    if coalesce(new.payload->>'wrap_program', '') not in ('STANDARD', 'HEAVY') then
      raise exception 'INVALID: WRAP payload requires wrap_program STANDARD or HEAVY';
    end if;
    return new;
  end if;

  -- PALLETIZE
  if coalesce(btrim(new.payload->>'target_pallet_code'), '') = '' then
    raise exception 'INVALID: PALLETIZE payload requires target_pallet_code';
  end if;
  if jsonb_typeof(new.payload->'sequence_items') is distinct from 'array' then
    raise exception 'INVALID: PALLETIZE payload requires a sequence_items array';
  end if;
  if jsonb_array_length(new.payload->'sequence_items') = 0 then
    raise exception 'INVALID: PALLETIZE payload sequence_items must not be empty';
  end if;

  for v_item in select * from jsonb_array_elements(new.payload->'sequence_items') loop
    v_count := v_count + 1;
    if coalesce(btrim(v_item->>'dispatch_sequence_id'), '') = '' then
      raise exception 'INVALID: PALLETIZE sequence_items[%] requires dispatch_sequence_id', v_count;
    end if;
    -- `is distinct from`, not `<>`: a MISSING key makes jsonb_typeof() return
    -- SQL NULL, and `null <> 'number'` is null, which plpgsql treats as false —
    -- the check would silently pass. Same reason everywhere below.
    if jsonb_typeof(v_item->'sequence_position') is distinct from 'number' then
      raise exception 'INVALID: PALLETIZE sequence_items[%] requires a numeric sequence_position', v_count;
    end if;
    v_pos := (v_item->>'sequence_position')::int;
    if v_pos <= v_prev then
      raise exception 'INVALID: PALLETIZE sequence_items must be sorted by ascending sequence_position (% after %)',
        v_pos, v_prev;
    end if;
    v_prev := v_pos;
    v_weight := v_weight + coalesce((v_item->>'declared_weight_kg')::numeric, 0);
    v_volume := v_volume + coalesce((v_item->>'declared_volume_l')::numeric, 0);
  end loop;

  -- design.md D7, planning-time half: the declared totals must fit the
  -- ceiling the caller stated. The measured half is outcome=OVERWEIGHT /
  -- OVERVOLUME reported back by the cell.
  if new.payload ? 'max_weight_kg' and jsonb_typeof(new.payload->'max_weight_kg') = 'number' then
    v_max := (new.payload->>'max_weight_kg')::numeric;
    if v_weight > v_max then
      raise exception 'INVALID: declared weight % kg exceeds max_weight_kg % for pallet %',
        v_weight, v_max, new.payload->>'target_pallet_code';
    end if;
  end if;
  if new.payload ? 'max_volume_l' and jsonb_typeof(new.payload->'max_volume_l') = 'number' then
    v_max := (new.payload->>'max_volume_l')::numeric;
    if v_volume > v_max then
      raise exception 'INVALID: declared volume % L exceeds max_volume_l % for pallet %',
        v_volume, v_max, new.payload->>'target_pallet_code';
    end if;
  end if;

  return new;
end;
$$;

-- A separate trigger from area 3's equipment_commands_validate_sortation:
-- same table, same timing, disjoint command types, no name collision
-- (tasks.md 1.3).
create trigger equipment_commands_validate_palletize
before insert on wms.equipment_commands
for each row
when (new.command_type in ('PALLETIZE', 'WRAP'))
execute function wms._wms_validate_palletize_command();

-- ============================================================
-- Outcome <-> command-status consistency (design.md D5)
--
-- Same pattern as area 3's DIVERT check, extended with the per-item array
-- PALLETIZE needs because one command covers N sequence assignments.
--
--   SUCCESS   -> COMPLETED only, every item LOADED
--   PARTIAL   -> COMPLETED only, LOADED/SKIPPED may mix
--   OVERWEIGHT | OVERVOLUME | ABORTED -> FAILED only, every item SKIPPED
--
-- Events with no `outcome` key pass straight through — that is what
-- wms_raise_equipment_fault emits when it force-fails in-flight commands.
-- ============================================================

create or replace function wms._wms_validate_palletize_outcome()
returns trigger
language plpgsql security definer
set search_path = wms, public
as $$
declare
  v_command wms.equipment_commands%rowtype;
  v_outcome text;
  v_item jsonb;
  v_item_outcome text;
  v_seq_id uuid;
  v_count int := 0;
begin
  if new.command_id is null or new.detail is null then
    return new;
  end if;
  v_outcome := new.detail->>'outcome';
  if v_outcome is null then
    return new;
  end if;

  select * into v_command from wms.equipment_commands where id = new.command_id;
  if not found or v_command.command_type not in ('PALLETIZE', 'WRAP') then
    return new;
  end if;

  if v_command.command_type = 'WRAP' then
    if v_outcome not in ('SUCCESS', 'FAILED') then
      raise exception 'INVALID: WRAP outcome must be SUCCESS or FAILED (got %)', v_outcome;
    end if;
    if v_outcome = 'SUCCESS' and new.event_type <> 'COMMAND_COMPLETED' then
      raise exception 'INVALID: outcome=SUCCESS requires command_status=COMPLETED';
    end if;
    if v_outcome = 'FAILED' and new.event_type <> 'COMMAND_FAILED' then
      raise exception 'INVALID: outcome=FAILED requires command_status=FAILED';
    end if;
    return new;
  end if;

  -- PALLETIZE
  if v_outcome not in ('SUCCESS', 'PARTIAL', 'OVERWEIGHT', 'OVERVOLUME', 'ABORTED') then
    raise exception 'INVALID: PALLETIZE outcome must be one of SUCCESS, PARTIAL, OVERWEIGHT, OVERVOLUME, ABORTED (got %)',
      v_outcome;
  end if;
  if v_outcome in ('SUCCESS', 'PARTIAL') and new.event_type <> 'COMMAND_COMPLETED' then
    raise exception 'INVALID: outcome=% requires command_status=COMPLETED', v_outcome;
  end if;
  if v_outcome in ('OVERWEIGHT', 'OVERVOLUME', 'ABORTED') and new.event_type <> 'COMMAND_FAILED' then
    raise exception 'INVALID: outcome=% requires command_status=FAILED', v_outcome;
  end if;

  if jsonb_typeof(new.detail->'loaded_items') is distinct from 'array'
     or jsonb_array_length(new.detail->'loaded_items') = 0 then
    raise exception 'INVALID: PALLETIZE result detail requires a non-empty loaded_items array';
  end if;

  for v_item in select * from jsonb_array_elements(new.detail->'loaded_items') loop
    v_count := v_count + 1;
    if coalesce(btrim(v_item->>'dispatch_sequence_id'), '') = '' then
      raise exception 'INVALID: loaded_items[%] requires dispatch_sequence_id', v_count;
    end if;
    v_seq_id := (v_item->>'dispatch_sequence_id')::uuid;
    if not exists (
      select 1 from wms.dispatch_sequences
      where id = v_seq_id and equipment_command_id = v_command.id
    ) then
      raise exception 'INVALID: loaded_items[%] dispatch_sequence_id % is not part of command %',
        v_count, v_seq_id, v_command.id;
    end if;
    v_item_outcome := v_item->>'item_outcome';
    if coalesce(v_item_outcome, '') not in ('LOADED', 'SKIPPED') then
      raise exception 'INVALID: loaded_items[%] item_outcome must be LOADED or SKIPPED (got %)',
        v_count, coalesce(v_item_outcome, 'null');
    end if;
    if v_outcome = 'SUCCESS' and v_item_outcome <> 'LOADED' then
      raise exception 'INVALID: outcome=SUCCESS requires every item to be LOADED (item % is %)',
        v_count, v_item_outcome;
    end if;
    if v_outcome in ('OVERWEIGHT', 'OVERVOLUME', 'ABORTED') and v_item_outcome <> 'SKIPPED' then
      raise exception 'INVALID: outcome=% requires every item to be SKIPPED (item % is %)',
        v_outcome, v_count, v_item_outcome;
    end if;
    if v_item_outcome = 'LOADED' and jsonb_typeof(v_item->'load_position') is distinct from 'number' then
      raise exception 'INVALID: loaded_items[%] with item_outcome=LOADED requires a numeric load_position', v_count;
    end if;
  end loop;

  return new;
end;
$$;

create trigger equipment_status_events_validate_palletize_outcome
before insert on wms.equipment_status_events
for each row
when (new.event_type in ('COMMAND_COMPLETED', 'COMMAND_FAILED'))
execute function wms._wms_validate_palletize_outcome();

-- ============================================================
-- Per-item completion propagation (design.md D6)
--
-- area 2's D2 propagates ONE command result to ONE work order with an
-- AFTER UPDATE OF status trigger on wms.equipment_commands. PALLETIZE covers N
-- sequence assignments, and the per-item verdict only exists inside the event's
-- `detail`, so this generalisation hangs off wms.equipment_status_events
-- instead and walks detail.loaded_items.
--
-- Ordering is guaranteed by TIMING, not by name: the consistency trigger above
-- is BEFORE INSERT, so a malformed report aborts the statement before this
-- AFTER INSERT trigger can act on it (tasks.md 1.5).
-- ============================================================

create or replace function wms._wms_propagate_palletize_result()
returns trigger
language plpgsql security definer
set search_path = wms, public
as $$
declare
  v_command wms.equipment_commands%rowtype;
  v_item jsonb;
  v_sequence wms.dispatch_sequences%rowtype;
  v_before jsonb;
  v_order_before jsonb;
  v_order wms.outbound_orders%rowtype;
  v_new_status text;
begin
  if new.command_id is null or new.detail is null then
    return null;
  end if;
  if jsonb_typeof(new.detail->'loaded_items') is distinct from 'array' then
    return null;
  end if;

  select * into v_command from wms.equipment_commands where id = new.command_id;
  if not found or v_command.command_type <> 'PALLETIZE' then
    return null;
  end if;

  for v_item in select * from jsonb_array_elements(new.detail->'loaded_items') loop
    select * into v_sequence from wms.dispatch_sequences
      where id = (v_item->>'dispatch_sequence_id')::uuid
        and equipment_command_id = v_command.id
      for update;
    if not found then
      continue;
    end if;
    -- only an in-flight assignment follows its command; a cancelled or already
    -- terminal one is left alone (same rule as area 2's D2).
    if v_sequence.status <> 'DISPATCHED' then
      continue;
    end if;

    v_new_status := case when v_item->>'item_outcome' = 'LOADED' then 'COMPLETED' else 'FAILED' end;
    v_before := to_jsonb(v_sequence);

    update wms.dispatch_sequences
    set status = v_new_status,
        load_position = case
          when jsonb_typeof(v_item->'load_position') = 'number' then (v_item->>'load_position')::int
          else load_position end,
        reason = case when v_new_status = 'FAILED'
                      then coalesce(v_item->>'reason', new.detail->>'outcome')
                      else reason end,
        version = version + 1,
        updated_by = new.reported_by,
        updated_at = now()
    where id = v_sequence.id
    returning * into v_sequence;

    insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, before, after, correlation_id)
    values (v_sequence.tenant_id, new.reported_by, 'wms_propagate_palletize_result', 'dispatch_sequence',
            v_sequence.id, v_before, to_jsonb(v_sequence),
            coalesce(new.correlation_id, v_sequence.correlation_id));

    -- the outbound unit follows its (single active) assignment
    select * into v_order from wms.outbound_orders where id = v_sequence.outbound_order_id for update;
    if found and v_order.status = 'DISPATCHED' then
      v_order_before := to_jsonb(v_order);
      update wms.outbound_orders
      set status = v_new_status, version = version + 1,
          updated_by = new.reported_by, updated_at = now()
      where id = v_order.id
      returning * into v_order;

      insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, before, after, correlation_id)
      values (v_order.tenant_id, new.reported_by, 'wms_propagate_palletize_result', 'outbound_order',
              v_order.id, v_order_before, to_jsonb(v_order),
              coalesce(new.correlation_id, v_order.correlation_id));
    end if;
  end loop;

  return null;
end;
$$;

create trigger equipment_status_events_propagate_palletize
after insert on wms.equipment_status_events
for each row
when (new.event_type in ('COMMAND_COMPLETED', 'COMMAND_FAILED'))
execute function wms._wms_propagate_palletize_result();

-- ============================================================
-- Command RPCs
-- Envelope in:  tenant_id / warehouse_id (implied by the target row for
--               id-addressed calls), actor_id, idempotency_key,
--               expected_version, correlation_id.
-- Envelope out: {result, document_id, status, version, next_actions, warnings}.
-- Errors:       RAISE EXCEPTION with CONFLICT:/FORBIDDEN:/INVALID: prefix.
--
-- WRAP dispatch and PALLETIZE/WRAP result reporting have NO RPC of their own —
-- they reuse wms_wcs-equipment-control's wms_dispatch_equipment_command /
-- wms_report_command_result, distinguished only by command_type + payload
-- (area 3's precedent).
-- ============================================================

create or replace function wms.wms_create_outbound_order(
  p_tenant_id text,
  p_warehouse_id uuid,
  p_store_code text,
  p_product_id uuid,
  p_qty numeric,
  p_actor_id uuid,
  p_idempotency_key uuid,
  p_order_number text default null,
  p_requested_delivery_date date default null,
  p_declared_weight_kg numeric default null,
  p_declared_volume_l numeric default null,
  p_correlation_id text default null
) returns jsonb
language plpgsql security definer
set search_path = wms, public
as $$
declare
  v_cached jsonb;
  v_order wms.outbound_orders%rowtype;
begin
  if p_idempotency_key is not null then
    select response into v_cached from wms.idempotency_records
      where tenant_id = p_tenant_id and command_name = 'wms_create_outbound_order' and idempotency_key = p_idempotency_key;
    if found then return v_cached; end if;
  end if;

  if p_warehouse_id not in (select wms.current_warehouse_ids(p_tenant_id)) then
    raise exception 'FORBIDDEN: no warehouse scope for %', p_warehouse_id;
  end if;
  -- WCS_OPERATOR deliberately absent: creating an outbound unit is an upstream
  -- business decision, not a floor-control action (design.md 역할 모델).
  if not wms.has_role(p_tenant_id, 'WMS_ADMIN', 'WAREHOUSE_MANAGER', 'PROCESS_AGENT') then
    raise exception 'FORBIDDEN: role cannot create outbound orders';
  end if;
  if coalesce(btrim(p_store_code), '') = '' then
    raise exception 'INVALID: store_code is required';
  end if;
  if p_qty is null or p_qty <= 0 then
    raise exception 'INVALID: qty must be greater than 0';
  end if;
  if not exists (select 1 from wms.products where id = p_product_id and tenant_id = p_tenant_id) then
    raise exception 'INVALID: unknown product % in tenant %', p_product_id, p_tenant_id;
  end if;
  if p_declared_weight_kg is not null and p_declared_weight_kg < 0 then
    raise exception 'INVALID: declared_weight_kg must be 0 or greater';
  end if;
  if p_declared_volume_l is not null and p_declared_volume_l < 0 then
    raise exception 'INVALID: declared_volume_l must be 0 or greater';
  end if;

  insert into wms.outbound_orders (
    tenant_id, warehouse_id, order_number, store_code, product_id, qty,
    requested_delivery_date, declared_weight_kg, declared_volume_l,
    status, correlation_id, created_by, updated_by
  ) values (
    p_tenant_id, p_warehouse_id, p_order_number, p_store_code, p_product_id, p_qty,
    p_requested_delivery_date, p_declared_weight_kg, p_declared_volume_l,
    'OPEN', p_correlation_id, p_actor_id, p_actor_id
  )
  returning * into v_order;

  insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, before, after, correlation_id)
  values (p_tenant_id, p_actor_id, 'wms_create_outbound_order', 'outbound_order', v_order.id,
          null, to_jsonb(v_order), p_correlation_id);

  v_cached := jsonb_build_object(
    'result', 'ok',
    'document_id', v_order.id,
    'outbound_order_id', v_order.id,
    'store_code', v_order.store_code,
    'status', v_order.status,
    'version', v_order.version,
    'warnings', '[]'::jsonb,
    'next_actions', jsonb_build_array('assign_dispatch_sequence', 'get_dispatch_sequence_status')
  );
  if p_idempotency_key is not null then
    insert into wms.idempotency_records (tenant_id, command_name, idempotency_key, response)
    values (p_tenant_id, 'wms_create_outbound_order', p_idempotency_key, v_cached)
    on conflict do nothing;
  end if;
  return v_cached;
end;
$$;

-- expected_version is the OUTBOUND ORDER version.
create or replace function wms.wms_assign_dispatch_sequence(
  p_outbound_order_id uuid,
  p_wave_id uuid,
  p_sequence_position int,
  p_target_pallet_code text,
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
  v_order wms.outbound_orders%rowtype;
  v_order_before jsonb;
  v_wave wms.dispatch_waves%rowtype;
  v_sequence wms.dispatch_sequences%rowtype;
  v_tenant_id text;
begin
  select tenant_id into v_tenant_id from wms.outbound_orders where id = p_outbound_order_id;
  if p_idempotency_key is not null and v_tenant_id is not null then
    select response into v_cached from wms.idempotency_records
      where tenant_id = v_tenant_id and command_name = 'wms_assign_dispatch_sequence' and idempotency_key = p_idempotency_key;
    if found then return v_cached; end if;
  end if;

  select * into v_order from wms.outbound_orders where id = p_outbound_order_id for update;
  if not found then
    raise exception 'INVALID: unknown outbound order %', p_outbound_order_id;
  end if;
  if v_order.warehouse_id not in (select wms.current_warehouse_ids(v_order.tenant_id)) then
    raise exception 'FORBIDDEN: no warehouse scope for outbound order %', p_outbound_order_id;
  end if;
  if not wms.has_role(v_order.tenant_id, 'WMS_ADMIN', 'WAREHOUSE_MANAGER', 'WCS_OPERATOR', 'PROCESS_AGENT') then
    raise exception 'FORBIDDEN: role cannot assign dispatch sequences';
  end if;
  if v_order.version <> p_expected_version then
    raise exception 'CONFLICT: expected version % but found %', p_expected_version, v_order.version;
  end if;
  if v_order.status <> 'OPEN' then
    raise exception 'INVALID: outbound order % is not OPEN (status=%)', p_outbound_order_id, v_order.status;
  end if;
  if coalesce(p_sequence_position, 0) <= 0 then
    raise exception 'INVALID: sequence_position must be greater than 0';
  end if;
  if coalesce(btrim(p_target_pallet_code), '') = '' then
    raise exception 'INVALID: target_pallet_code is required';
  end if;

  select * into v_wave from wms.dispatch_waves where id = p_wave_id;
  if not found then
    raise exception 'INVALID: unknown dispatch wave %', p_wave_id;
  end if;
  if v_wave.tenant_id <> v_order.tenant_id or v_wave.warehouse_id <> v_order.warehouse_id then
    raise exception 'INVALID: dispatch wave % belongs to another warehouse', p_wave_id;
  end if;
  -- area 2's rule, reused verbatim: a released wave is closed for new work.
  if v_wave.status <> 'OPEN' then
    raise exception 'INVALID: dispatch wave % is not OPEN (status=%)', p_wave_id, v_wave.status;
  end if;
  if exists (
    select 1 from wms.dispatch_sequences
    where wave_id = p_wave_id and sequence_position = p_sequence_position and status <> 'CANCELLED'
  ) then
    raise exception 'INVALID: sequence_position % is already taken in wave %', p_sequence_position, p_wave_id;
  end if;

  insert into wms.dispatch_sequences (
    tenant_id, warehouse_id, outbound_order_id, wave_id, sequence_position,
    target_pallet_code, status, correlation_id, created_by, updated_by
  ) values (
    v_order.tenant_id, v_order.warehouse_id, v_order.id, p_wave_id, p_sequence_position,
    p_target_pallet_code, 'QUEUED', p_correlation_id, p_actor_id, p_actor_id
  )
  returning * into v_sequence;

  v_order_before := to_jsonb(v_order);
  update wms.outbound_orders
  set status = 'SEQUENCED', version = version + 1, updated_by = p_actor_id, updated_at = now()
  where id = v_order.id
  returning * into v_order;

  insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, before, after, correlation_id)
  values (v_sequence.tenant_id, p_actor_id, 'wms_assign_dispatch_sequence', 'dispatch_sequence', v_sequence.id,
          null, to_jsonb(v_sequence), p_correlation_id);
  insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, before, after, correlation_id)
  values (v_order.tenant_id, p_actor_id, 'wms_assign_dispatch_sequence', 'outbound_order', v_order.id,
          v_order_before, to_jsonb(v_order), p_correlation_id);

  v_cached := jsonb_build_object(
    'result', 'ok',
    'document_id', v_sequence.id,
    'dispatch_sequence_id', v_sequence.id,
    'outbound_order_id', v_order.id,
    'outbound_order_status', v_order.status,
    'outbound_order_version', v_order.version,
    'wave_id', v_sequence.wave_id,
    'sequence_position', v_sequence.sequence_position,
    'target_pallet_code', v_sequence.target_pallet_code,
    'status', v_sequence.status,
    'version', v_sequence.version,
    'warnings', '[]'::jsonb,
    'next_actions', jsonb_build_array('dispatch_palletize_command', 'cancel_dispatch_sequence',
                                      'get_dispatch_sequence_status')
  );
  if p_idempotency_key is not null then
    insert into wms.idempotency_records (tenant_id, command_name, idempotency_key, response)
    values (v_sequence.tenant_id, 'wms_assign_dispatch_sequence', p_idempotency_key, v_cached)
    on conflict do nothing;
  end if;
  return v_cached;
end;
$$;

-- expected_version is the DISPATCH SEQUENCE version.
-- DEVIATION 4 (see header): a DISPATCHED assignment shares one PALLETIZE
-- command with its siblings, so cancelling it cancels them too.
create or replace function wms.wms_cancel_dispatch_sequence(
  p_dispatch_sequence_id uuid,
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
  v_sequence wms.dispatch_sequences%rowtype;
  v_before jsonb;
  v_sibling wms.dispatch_sequences%rowtype;
  v_sibling_before jsonb;
  v_command wms.equipment_commands%rowtype;
  v_tenant_id text;
  v_warnings jsonb := '[]'::jsonb;
  v_cancelled_command uuid;
  v_siblings uuid[] := '{}';
begin
  select tenant_id into v_tenant_id from wms.dispatch_sequences where id = p_dispatch_sequence_id;
  if p_idempotency_key is not null and v_tenant_id is not null then
    select response into v_cached from wms.idempotency_records
      where tenant_id = v_tenant_id and command_name = 'wms_cancel_dispatch_sequence' and idempotency_key = p_idempotency_key;
    if found then return v_cached; end if;
  end if;

  select * into v_sequence from wms.dispatch_sequences where id = p_dispatch_sequence_id for update;
  if not found then
    raise exception 'INVALID: unknown dispatch sequence %', p_dispatch_sequence_id;
  end if;
  if v_sequence.warehouse_id not in (select wms.current_warehouse_ids(v_sequence.tenant_id)) then
    raise exception 'FORBIDDEN: no warehouse scope for dispatch sequence %', p_dispatch_sequence_id;
  end if;
  if not wms.has_role(v_sequence.tenant_id, 'WMS_ADMIN', 'WAREHOUSE_MANAGER', 'WCS_OPERATOR', 'PROCESS_AGENT') then
    raise exception 'FORBIDDEN: role cannot cancel dispatch sequences';
  end if;
  if v_sequence.version <> p_expected_version then
    raise exception 'CONFLICT: expected version % but found %', p_expected_version, v_sequence.version;
  end if;
  if v_sequence.status in ('COMPLETED', 'FAILED', 'CANCELLED') then
    raise exception 'INVALID: dispatch sequence % is already terminal (status=%)',
      p_dispatch_sequence_id, v_sequence.status;
  end if;

  if v_sequence.status = 'DISPATCHED' and v_sequence.equipment_command_id is not null then
    select * into v_command from wms.equipment_commands where id = v_sequence.equipment_command_id;
    if found and v_command.status in ('PENDING', 'ACKNOWLEDGED', 'IN_PROGRESS') then
      -- WMS_ADMIN is inside wms_cancel_equipment_command's role set, so unlike
      -- the dispatch path this nested call cannot partially fail.
      perform wms.wms_cancel_equipment_command(
        v_command.id, p_actor_id, gen_random_uuid(), v_command.version,
        coalesce(p_reason, 'dispatch sequence cancelled'), p_correlation_id
      );
      v_cancelled_command := v_command.id;

      for v_sibling in
        select * from wms.dispatch_sequences
        where equipment_command_id = v_command.id
          and id <> v_sequence.id
          and status = 'DISPATCHED'
        for update
      loop
        v_sibling_before := to_jsonb(v_sibling);
        update wms.dispatch_sequences
        set status = 'CANCELLED',
            reason = coalesce(p_reason, 'sibling palletize command cancelled'),
            version = version + 1, updated_by = p_actor_id, updated_at = now()
        where id = v_sibling.id
        returning * into v_sibling;

        update wms.outbound_orders
        set status = 'OPEN', version = version + 1, updated_by = p_actor_id, updated_at = now()
        where id = v_sibling.outbound_order_id and status in ('SEQUENCED', 'DISPATCHED');

        insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, before, after, correlation_id)
        values (v_sibling.tenant_id, p_actor_id, 'wms_cancel_dispatch_sequence', 'dispatch_sequence',
                v_sibling.id, v_sibling_before, to_jsonb(v_sibling), p_correlation_id);

        v_siblings := v_siblings || v_sibling.id;
      end loop;

      if array_length(v_siblings, 1) > 0 then
        v_warnings := v_warnings || to_jsonb(format(
          'SIBLING_SEQUENCES_CANCELLED: %s other assignment(s) rode the same PALLETIZE command',
          array_length(v_siblings, 1)));
      end if;
    else
      v_warnings := v_warnings || to_jsonb('LINKED_COMMAND_ALREADY_TERMINAL'::text);
    end if;
  end if;

  v_before := to_jsonb(v_sequence);

  update wms.dispatch_sequences
  set status = 'CANCELLED', reason = p_reason, version = version + 1,
      updated_by = p_actor_id, updated_at = now()
  where id = v_sequence.id
  returning * into v_sequence;

  -- DEVIATION 3: back to OPEN so the unit can be re-sequenced.
  update wms.outbound_orders
  set status = 'OPEN', version = version + 1, updated_by = p_actor_id, updated_at = now()
  where id = v_sequence.outbound_order_id and status in ('SEQUENCED', 'DISPATCHED');

  insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, before, after, correlation_id)
  values (v_sequence.tenant_id, p_actor_id, 'wms_cancel_dispatch_sequence', 'dispatch_sequence', v_sequence.id,
          v_before, to_jsonb(v_sequence), p_correlation_id);

  v_cached := jsonb_build_object(
    'result', 'ok',
    'document_id', v_sequence.id,
    'dispatch_sequence_id', v_sequence.id,
    'outbound_order_id', v_sequence.outbound_order_id,
    'status', v_sequence.status,
    'version', v_sequence.version,
    'cancelled_equipment_command_id', v_cancelled_command,
    'cancelled_sibling_sequence_ids', to_jsonb(v_siblings),
    'warnings', v_warnings,
    'next_actions', jsonb_build_array('assign_dispatch_sequence', 'get_dispatch_sequence_status')
  );
  if p_idempotency_key is not null then
    insert into wms.idempotency_records (tenant_id, command_name, idempotency_key, response)
    values (v_sequence.tenant_id, 'wms_cancel_dispatch_sequence', p_idempotency_key, v_cached)
    on conflict do nothing;
  end if;
  return v_cached;
end;
$$;

-- expected_version is the EQUIPMENT version (same meaning as area 1's
-- wms_dispatch_equipment_command, which this RPC calls internally).
--
-- design.md D4: the target cell is named by the caller, never load-balanced.
-- One physical pallet has to be built by one cell from first carton to last,
-- so area 2/area 4's "pick the least loaded candidate" model does not apply.
create or replace function wms.wms_dispatch_palletize_command(
  p_equipment_id uuid,
  p_wave_id uuid,
  p_target_pallet_code text,
  p_actor_id uuid,
  p_idempotency_key uuid,
  p_expected_version int,
  p_max_weight_kg numeric default null,
  p_max_volume_l numeric default null,
  p_correlation_id text default null
) returns jsonb
language plpgsql security definer
set search_path = wms, public
as $$
declare
  v_cached jsonb;
  v_equipment wms.equipment%rowtype;
  v_wave wms.dispatch_waves%rowtype;
  v_row record;
  v_items jsonb := '[]'::jsonb;
  v_count int := 0;
  v_weight numeric := 0;
  v_volume numeric := 0;
  v_payload jsonb;
  v_dispatch jsonb;
  v_command_id uuid;
  v_sequence wms.dispatch_sequences%rowtype;
  v_sequence_id uuid;
  v_before jsonb;
  v_tenant_id text;
  v_warnings jsonb := '[]'::jsonb;
  v_sequence_ids uuid[] := '{}';
begin
  select tenant_id into v_tenant_id from wms.equipment where id = p_equipment_id;
  if p_idempotency_key is not null and v_tenant_id is not null then
    select response into v_cached from wms.idempotency_records
      where tenant_id = v_tenant_id and command_name = 'wms_dispatch_palletize_command' and idempotency_key = p_idempotency_key;
    if found then return v_cached; end if;
  end if;

  select * into v_equipment from wms.equipment where id = p_equipment_id;
  if not found then
    raise exception 'INVALID: unknown equipment %', p_equipment_id;
  end if;
  if v_equipment.warehouse_id not in (select wms.current_warehouse_ids(v_equipment.tenant_id)) then
    raise exception 'FORBIDDEN: no warehouse scope for equipment %', p_equipment_id;
  end if;
  -- DEVIATION 2: exactly wms_dispatch_equipment_command's role set, so the
  -- nested call below can never fail with FORBIDDEN after partial work.
  if not wms.has_role(v_equipment.tenant_id, 'WAREHOUSE_MANAGER', 'WCS_OPERATOR', 'PROCESS_AGENT') then
    raise exception 'FORBIDDEN: role cannot dispatch palletize commands';
  end if;
  if v_equipment.equipment_type <> 'ROBOT_CELL' then
    raise exception 'INVALID: PALLETIZE is only valid for ROBOT_CELL equipment (% is %)',
      v_equipment.equipment_code, v_equipment.equipment_type;
  end if;
  if coalesce(btrim(p_target_pallet_code), '') = '' then
    raise exception 'INVALID: target_pallet_code is required';
  end if;

  -- D4's availability rule: IDLE, or already RUNNING on THIS pallet.
  if v_equipment.status = 'RUNNING' then
    if not exists (
      select 1 from wms.equipment_commands c
      where c.equipment_id = v_equipment.id
        and c.command_type = 'PALLETIZE'
        and c.status in ('PENDING', 'ACKNOWLEDGED', 'IN_PROGRESS')
        and c.payload->>'target_pallet_code' = p_target_pallet_code
    ) then
      raise exception 'INVALID: robot cell % is RUNNING on another pallet — one cell builds one pallet at a time',
        v_equipment.equipment_code;
    end if;
  elsif v_equipment.status <> 'IDLE' then
    raise exception 'INVALID: robot cell % is % and cannot start a pallet build',
      v_equipment.equipment_code, v_equipment.status;
  end if;

  select * into v_wave from wms.dispatch_waves where id = p_wave_id;
  if not found then
    raise exception 'INVALID: unknown dispatch wave %', p_wave_id;
  end if;
  if v_wave.tenant_id <> v_equipment.tenant_id or v_wave.warehouse_id <> v_equipment.warehouse_id then
    raise exception 'INVALID: dispatch wave % belongs to another warehouse', p_wave_id;
  end if;

  -- D3: everything QUEUED on this (wave, pallet), in planned sequence order.
  for v_row in
    select s.*, o.declared_weight_kg, o.declared_volume_l, o.store_code, o.order_number
    from wms.dispatch_sequences s
    join wms.outbound_orders o on o.id = s.outbound_order_id
    where s.wave_id = p_wave_id
      and s.target_pallet_code = p_target_pallet_code
      and s.status = 'QUEUED'
    order by s.sequence_position
    for update of s
  loop
    v_count := v_count + 1;
    v_weight := v_weight + coalesce(v_row.declared_weight_kg, 0);
    v_volume := v_volume + coalesce(v_row.declared_volume_l, 0);
    v_items := v_items || jsonb_build_array(jsonb_build_object(
      'dispatch_sequence_id', v_row.id,
      'sequence_position', v_row.sequence_position,
      'outbound_order_id', v_row.outbound_order_id,
      'store_code', v_row.store_code,
      'order_number', v_row.order_number,
      'declared_weight_kg', v_row.declared_weight_kg,
      'declared_volume_l', v_row.declared_volume_l
    ));
    v_sequence_ids := v_sequence_ids || v_row.id;
  end loop;

  if v_count = 0 then
    raise exception 'INVALID: no QUEUED dispatch sequence for wave % and pallet %', p_wave_id, p_target_pallet_code;
  end if;
  if v_count > 28 then
    -- the catalogue's "최대 28종 패키지 혼합 적재" is a vendor figure, not a
    -- contract limit; surface it as a warning rather than refusing the build.
    v_warnings := v_warnings || to_jsonb('MIXED_PACKAGE_COUNT_ABOVE_REFERENCE_28'::text);
  end if;
  if v_weight = 0 and v_volume = 0 then
    v_warnings := v_warnings || to_jsonb('NO_DECLARED_WEIGHT_OR_VOLUME'::text);
  end if;

  v_payload := jsonb_build_object(
    'target_pallet_code', p_target_pallet_code,
    'sequence_items', v_items,
    'declared_total_weight_kg', v_weight,
    'declared_total_volume_l', v_volume
  );
  if p_max_weight_kg is not null then
    v_payload := v_payload || jsonb_build_object('max_weight_kg', p_max_weight_kg);
  end if;
  if p_max_volume_l is not null then
    v_payload := v_payload || jsonb_build_object('max_volume_l', p_max_volume_l);
  end if;

  -- The ceiling check (design.md D7) lives in the BEFORE INSERT trigger, so it
  -- fires from here AND from a direct wms_dispatch_equipment_command call. The
  -- INVALID: it raises rolls this whole transaction back — no sequence is left
  -- half-transitioned.
  v_dispatch := wms.wms_dispatch_equipment_command(
    v_equipment.id, 'PALLETIZE', v_payload, p_actor_id, gen_random_uuid(), p_expected_version,
    p_correlation_id, 'dispatch_wave', p_wave_id
  );
  v_command_id := (v_dispatch->>'command_id')::uuid;

  foreach v_sequence_id in array v_sequence_ids loop
    select * into v_sequence from wms.dispatch_sequences where id = v_sequence_id;
    v_before := to_jsonb(v_sequence);
    update wms.dispatch_sequences
    set status = 'DISPATCHED', equipment_command_id = v_command_id,
        version = version + 1, updated_by = p_actor_id, updated_at = now()
    where id = v_sequence_id
    returning * into v_sequence;

    update wms.outbound_orders
    set status = 'DISPATCHED', version = version + 1, updated_by = p_actor_id, updated_at = now()
    where id = v_sequence.outbound_order_id and status = 'SEQUENCED';

    insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, before, after, correlation_id)
    values (v_sequence.tenant_id, p_actor_id, 'wms_dispatch_palletize_command', 'dispatch_sequence',
            v_sequence.id, v_before, to_jsonb(v_sequence), p_correlation_id);
  end loop;

  v_cached := jsonb_build_object(
    'result', 'ok',
    'document_id', v_command_id,
    'equipment_command_id', v_command_id,
    'equipment_id', v_equipment.id,
    'equipment_code', v_equipment.equipment_code,
    'wave_id', p_wave_id,
    'target_pallet_code', p_target_pallet_code,
    'item_count', v_count,
    'declared_total_weight_kg', v_weight,
    'declared_total_volume_l', v_volume,
    'dispatch_sequence_ids', to_jsonb(v_sequence_ids),
    'status', v_dispatch->>'status',
    'version', (v_dispatch->>'version')::int,
    'equipment_status', v_dispatch->>'equipment_status',
    'equipment_version', (v_dispatch->>'equipment_version')::int,
    'warnings', v_warnings,
    'next_actions', jsonb_build_array('report_command_result', 'get_pallet_manifest',
                                      'cancel_dispatch_sequence')
  );
  if p_idempotency_key is not null then
    insert into wms.idempotency_records (tenant_id, command_name, idempotency_key, response)
    values (v_equipment.tenant_id, 'wms_dispatch_palletize_command', p_idempotency_key, v_cached)
    on conflict do nothing;
  end if;
  return v_cached;
end;
$$;

-- ============================================================
-- Read models
-- ============================================================

-- Sequence assignments joined with their outbound unit and equipment command,
-- plus the raw material the /wcs/sequential-dispatch screen needs (waves,
-- ROBOT_CELLs, pallet roll-up). Mirrors wms_get_work_order_status's shape.
create or replace function wms.wms_get_dispatch_sequence_status(
  p_tenant_id text,
  p_warehouse_id uuid,
  p_wave_id uuid default null,
  p_outbound_order_id uuid default null
) returns jsonb
language plpgsql stable security definer
set search_path = wms, public
as $$
declare
  v_orders jsonb;
  v_sequences jsonb;
  v_waves jsonb;
  v_cells jsonb;
  v_pallets jsonb;
begin
  if p_warehouse_id not in (select wms.current_warehouse_ids(p_tenant_id)) then
    raise exception 'FORBIDDEN: no warehouse scope for %', p_warehouse_id;
  end if;

  select coalesce(jsonb_agg(item order by sort_position, sort_created), '[]'::jsonb)
  into v_sequences
  from (
    select s.sequence_position as sort_position, s.created_at as sort_created, jsonb_build_object(
      'dispatch_sequence_id', s.id,
      'outbound_order_id', s.outbound_order_id,
      'order_number', o.order_number,
      'store_code', o.store_code,
      'sku', pr.sku,
      'product_name', pr.name,
      'qty', o.qty,
      'declared_weight_kg', o.declared_weight_kg,
      'declared_volume_l', o.declared_volume_l,
      'requested_delivery_date', o.requested_delivery_date,
      'outbound_order_status', o.status,
      'outbound_order_version', o.version,
      'wave_id', s.wave_id,
      'wave_status', w.status,
      'sequence_position', s.sequence_position,
      'target_pallet_code', s.target_pallet_code,
      'status', s.status,
      'version', s.version,
      'load_position', s.load_position,
      'reason', s.reason,
      'has_equipment_command', s.equipment_command_id is not null,
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
    from wms.dispatch_sequences s
    join wms.outbound_orders o on o.id = s.outbound_order_id
    join wms.products pr on pr.id = o.product_id
    left join wms.dispatch_waves w on w.id = s.wave_id
    left join wms.equipment_commands c on c.id = s.equipment_command_id
    left join wms.equipment e on e.id = c.equipment_id
    where s.tenant_id = p_tenant_id
      and s.warehouse_id = p_warehouse_id
      and (p_wave_id is null or s.wave_id = p_wave_id)
      and (p_outbound_order_id is null or s.outbound_order_id = p_outbound_order_id)
  ) rows;

  select coalesce(jsonb_agg(item order by created_at desc), '[]'::jsonb)
  into v_orders
  from (
    select o.created_at, jsonb_build_object(
      'outbound_order_id', o.id,
      'order_number', o.order_number,
      'store_code', o.store_code,
      'product_id', o.product_id,
      'sku', pr.sku,
      'product_name', pr.name,
      'qty', o.qty,
      'requested_delivery_date', o.requested_delivery_date,
      'declared_weight_kg', o.declared_weight_kg,
      'declared_volume_l', o.declared_volume_l,
      'status', o.status,
      'version', o.version,
      'created_at', o.created_at,
      'active_sequence_id', (
        select s.id from wms.dispatch_sequences s
        where s.outbound_order_id = o.id and s.status <> 'CANCELLED' limit 1
      )
    ) as item
    from wms.outbound_orders o
    join wms.products pr on pr.id = o.product_id
    where o.tenant_id = p_tenant_id
      and o.warehouse_id = p_warehouse_id
      and (p_outbound_order_id is null or o.id = p_outbound_order_id)
  ) rows;

  select coalesce(jsonb_agg(item order by created_at desc), '[]'::jsonb)
  into v_waves
  from (
    select w.created_at, jsonb_build_object(
      'wave_id', w.id,
      'status', w.status,
      'version', w.version,
      'created_at', w.created_at,
      'sequence_count', (select count(*) from wms.dispatch_sequences s
                         where s.wave_id = w.id and s.status <> 'CANCELLED'),
      'queued_count', (select count(*) from wms.dispatch_sequences s
                       where s.wave_id = w.id and s.status = 'QUEUED')
    ) as item
    from wms.dispatch_waves w
    where w.tenant_id = p_tenant_id and w.warehouse_id = p_warehouse_id
  ) rows;

  select coalesce(jsonb_agg(item order by item->>'equipment_code'), '[]'::jsonb)
  into v_cells
  from (
    select jsonb_build_object(
      'equipment_id', e.id,
      'equipment_code', e.equipment_code,
      'zone_code', e.zone_code,
      'status', e.status,
      'version', e.version,
      'active_palletize_pallet', (
        select c.payload->>'target_pallet_code' from wms.equipment_commands c
        where c.equipment_id = e.id and c.command_type = 'PALLETIZE'
          and c.status in ('PENDING', 'ACKNOWLEDGED', 'IN_PROGRESS')
        order by c.created_at desc limit 1
      )
    ) as item
    from wms.equipment e
    where e.tenant_id = p_tenant_id
      and e.warehouse_id = p_warehouse_id
      and e.equipment_type = 'ROBOT_CELL'
  ) rows;

  select coalesce(jsonb_agg(item order by item->>'target_pallet_code'), '[]'::jsonb)
  into v_pallets
  from (
    select jsonb_build_object(
      'wave_id', s.wave_id,
      'target_pallet_code', s.target_pallet_code,
      'queued_count', count(*) filter (where s.status = 'QUEUED'),
      'dispatched_count', count(*) filter (where s.status = 'DISPATCHED'),
      'completed_count', count(*) filter (where s.status = 'COMPLETED'),
      'failed_count', count(*) filter (where s.status = 'FAILED'),
      'declared_weight_kg', coalesce(sum(o.declared_weight_kg) filter (where s.status <> 'CANCELLED'), 0),
      'declared_volume_l', coalesce(sum(o.declared_volume_l) filter (where s.status <> 'CANCELLED'), 0),
      'equipment_command_id', max(s.equipment_command_id::text)
    ) as item
    from wms.dispatch_sequences s
    join wms.outbound_orders o on o.id = s.outbound_order_id
    where s.tenant_id = p_tenant_id
      and s.warehouse_id = p_warehouse_id
      and s.status <> 'CANCELLED'
      and (p_wave_id is null or s.wave_id = p_wave_id)
    group by s.wave_id, s.target_pallet_code
  ) rows;

  return jsonb_build_object(
    'result', 'ok',
    'tenant_id', p_tenant_id,
    'warehouse_id', p_warehouse_id,
    'outbound_orders', v_orders,
    'sequences', v_sequences,
    'waves', v_waves,
    'robot_cells', v_cells,
    'pallets', v_pallets,
    'count', jsonb_array_length(v_sequences)
  );
end;
$$;

-- What actually ended up on the pallet: the terminal PALLETIZE event's
-- detail.loaded_items expanded and joined back to the sequence assignments.
-- A command with no result reported yet returns an EMPTY manifest, not an
-- error (spec.md "아직 결과가 보고되지 않은 명령의 매니페스트는 비어 있다").
create or replace function wms.wms_get_pallet_manifest(
  p_tenant_id text,
  p_warehouse_id uuid,
  p_equipment_command_id uuid default null,
  p_target_pallet_code text default null
) returns jsonb
language plpgsql stable security definer
set search_path = wms, public
as $$
declare
  v_pallets jsonb;
begin
  if p_warehouse_id not in (select wms.current_warehouse_ids(p_tenant_id)) then
    raise exception 'FORBIDDEN: no warehouse scope for %', p_warehouse_id;
  end if;

  select coalesce(jsonb_agg(item order by created_at desc), '[]'::jsonb)
  into v_pallets
  from (
    select c.created_at, jsonb_build_object(
      'equipment_command_id', c.id,
      'target_pallet_code', c.payload->>'target_pallet_code',
      'wave_id', c.linked_entity_id,
      'equipment_id', c.equipment_id,
      'equipment_code', e.equipment_code,
      'command_status', c.status,
      'planned_item_count', jsonb_array_length(coalesce(c.payload->'sequence_items', '[]'::jsonb)),
      'declared_total_weight_kg', c.payload->'declared_total_weight_kg',
      'declared_total_volume_l', c.payload->'declared_total_volume_l',
      'max_weight_kg', c.payload->'max_weight_kg',
      'max_volume_l', c.payload->'max_volume_l',
      'reported', ev.id is not null,
      'outcome', ev.detail->>'outcome',
      'total_actual_weight_kg', ev.detail->'total_actual_weight_kg',
      'total_actual_volume_l', ev.detail->'total_actual_volume_l',
      'reported_at', ev.created_at,
      'items', case when ev.id is null then '[]'::jsonb else (
        select coalesce(jsonb_agg(entry order by ord), '[]'::jsonb)
        from (
          select ord, jsonb_build_object(
            'dispatch_sequence_id', li->>'dispatch_sequence_id',
            'load_position', li->'load_position',
            'item_outcome', li->>'item_outcome',
            'reason', li->>'reason',
            'sequence_position', s.sequence_position,
            'sequence_status', s.status,
            'outbound_order_id', s.outbound_order_id,
            'order_number', o.order_number,
            'store_code', o.store_code,
            'sku', pr.sku,
            'qty', o.qty,
            'declared_weight_kg', o.declared_weight_kg,
            'declared_volume_l', o.declared_volume_l
          ) as entry
          from jsonb_array_elements(ev.detail->'loaded_items') with ordinality as t(li, ord)
          left join wms.dispatch_sequences s on s.id = (t.li->>'dispatch_sequence_id')::uuid
          left join wms.outbound_orders o on o.id = s.outbound_order_id
          left join wms.products pr on pr.id = o.product_id
        ) expanded
      ) end
    ) as item
    from wms.equipment_commands c
    join wms.equipment e on e.id = c.equipment_id
    left join lateral (
      select s2.id, s2.detail, s2.created_at
      from wms.equipment_status_events s2
      where s2.command_id = c.id
        and s2.event_type in ('COMMAND_COMPLETED', 'COMMAND_FAILED')
        and s2.detail ? 'loaded_items'
      order by s2.seq desc
      limit 1
    ) ev on true
    where c.tenant_id = p_tenant_id
      and c.warehouse_id = p_warehouse_id
      and c.command_type = 'PALLETIZE'
      and (p_equipment_command_id is null or c.id = p_equipment_command_id)
      and (p_target_pallet_code is null or c.payload->>'target_pallet_code' = p_target_pallet_code)
  ) rows;

  return jsonb_build_object(
    'result', 'ok',
    'tenant_id', p_tenant_id,
    'warehouse_id', p_warehouse_id,
    'pallets', v_pallets,
    'count', jsonb_array_length(v_pallets)
  );
end;
$$;

grant execute on function wms.wms_create_outbound_order(text, uuid, text, uuid, numeric, uuid, uuid, text, date, numeric, numeric, text) to authenticated;
grant execute on function wms.wms_assign_dispatch_sequence(uuid, uuid, int, text, uuid, uuid, int, text) to authenticated;
grant execute on function wms.wms_cancel_dispatch_sequence(uuid, uuid, uuid, int, text, text) to authenticated;
grant execute on function wms.wms_dispatch_palletize_command(uuid, uuid, text, uuid, uuid, int, numeric, numeric, text) to authenticated;
grant execute on function wms.wms_get_dispatch_sequence_status(text, uuid, uuid, uuid) to authenticated;
grant execute on function wms.wms_get_pallet_manifest(text, uuid, uuid, text) to authenticated;
