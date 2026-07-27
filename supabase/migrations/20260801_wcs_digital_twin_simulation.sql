-- ============================================================
-- WCS digital-twin / simulation contract
-- Scope: openspec/changes/add-wcs-digital-twin-simulation
--        (proposal.md / design.md / specs/wms_wcs-digital-twin-simulation/spec.md)
--
-- The sixth and last WCS/WES area. Areas 1-5 defined a WMS<->WCS software
-- contract that only a real PLC/WCS gateway could fill; this repository has no
-- automation hardware at all, so until now every round trip in those specs had
-- to be faked by hand (a psql DO block impersonating wcs-gateway-a@demo.local).
-- This migration promotes that hand-waving into a first-class contract:
--
--   * wms.equipment.is_simulated       — "this machine answers in software"
--   * wms.simulation_profiles          — per-equipment timing / failure model
--   * wms.simulation_command_schedules — restart-safe per-command progress plan
--   * wms.simulation_scenarios         — what-if definition (equipment set + count)
--   * wms.simulation_scenario_runs     — one arithmetic projection per run
--
-- Conventions (schema, common columns, RLS helpers, RPC envelope,
-- CONFLICT:/FORBIDDEN:/INVALID: prefixes, idempotency records, audit events)
-- are identical to the six migrations before it, and none of those files is
-- modified here.
--
-- ORDERING: this migration REQUIRES
--   20260727_wcs_equipment_control.sql  (wms.equipment, wms.equipment_commands,
--                                        wms_report_command_result, the
--                                        WCS_GATEWAY role)
-- It has NO schema dependency on 20260728 (WES material flow), 20260729
-- (sortation), 20260730 (bottleneck routing) or 20260731 (sequential dispatch)
-- — design.md D8. The command_type -> result-vocabulary mapping in
-- wms_plan_simulated_command branches on the command_type *string* only; it
-- never reads wms.sortation_profiles or wms.dispatch_sequences.
--
-- NOT MODIFIED HERE: wms_dispatch_equipment_command. Areas 3 and 5 each had to
-- `create or replace` it because they added command types to the allow-list
-- hard-coded in its body. This area adds no command type, so the live body
-- (area 5's, 20260731) is left exactly as it is.
--
-- ------------------------------------------------------------
-- THE EXTERNAL WORKER (design.md D2) — why there is no pg_cron here
--
--   wms_report_command_result authorises with wms.has_role(...), which reads
--   auth.uid(), i.e. the Supabase Auth JWT of a real signed-in session. A
--   pg_cron background job has no such session (auth.uid() is null there), so
--   a database-side scheduler could only work by forging
--   request.jwt.claims — bypassing the very trust boundary area 1 D5 drew.
--   So the ticking lives OUTSIDE the database, in
--       mcp/wms_mcp/simulator/wcs_gateway_simulator.py
--   which signs in as wcs-gateway-a@demo.local (the seeded WCS_GATEWAY
--   identity) and calls the RPCs below over PostgREST — exactly the calls a
--   real gateway would make. Run it with:
--       cd mcp && .venv/bin/python -m wms_mcp.simulator.wcs_gateway_simulator --once
--       cd mcp && .venv/bin/python -m wms_mcp.simulator.wcs_gateway_simulator --loop --interval 1
--   See mcp/wms_mcp/simulator/README.md.
--
-- ------------------------------------------------------------
-- DEVIATION 1 from design.md D5 — PALLETIZE "PARTIAL" and WRAP "FAILURE"
--
--   design.md says a failed PALLETIZE should be reproduced by marking some
--   items SKIPPED so the outcome is PARTIAL, and that WRAP falls into the
--   generic {"outcome": "SUCCESS"|"FAILURE"} bucket. Both are refused by the
--   validators area 5 actually shipped:
--     - _wms_validate_palletize_outcome requires PARTIAL to arrive as
--       COMMAND_COMPLETED, not COMMAND_FAILED. A "failed -> PARTIAL" report is
--       a contradiction it rejects.
--     - the same trigger fires for WRAP and only accepts SUCCESS or FAILED —
--       the generic word "FAILURE" would be an INVALID:.
--   So the mapping implemented here is:
--     DIVERT     COMPLETED -> SUCCESS            FAILED -> JAM (jam_rate) | MISROUTE
--     PALLETIZE  COMPLETED -> SUCCESS, all LOADED FAILED -> ABORTED, all SKIPPED
--     WRAP       COMPLETED -> SUCCESS            FAILED -> FAILED
--     other      COMPLETED -> SUCCESS            FAILED -> FAILED
--   i.e. the generic terminal word is FAILED, not FAILURE, so an unknown
--   command type can never produce a report area 5's trigger would reject.
--
-- DEVIATION 2 from design.md's wms.simulation_command_schedules columns —
--   the table also stores progress_delay_ms / completion_delay_ms. design.md
--   only lists next_run_at, but a plan that stores only "the next target time"
--   would have to re-roll the later delays on every step, which contradicts D3
--   ("계획 전체를 한 번에 굴려 저장한다") and D6 ("계획에 고정한다"). Rolling
--   all three delays once and keeping the two future ones on the row is what
--   actually makes the plan restart-safe.
--
-- DEVIATION 3 (additive) — wms_get_due_simulation_actions also returns
--   `unplanned_commands`. design.md's worker loop step 1 says "find new PENDING
--   commands ... with area 1's wms_get_equipment_status or this contract's read
--   RPC". Folding that discovery into the same polling call means the worker
--   makes one round trip per tick instead of two, and it cannot drift out of
--   sync with the due-action query's own is_simulated filter.
--
-- DEVIATION 4 (robustness) — wms_advance_simulated_command tolerates a command
--   that went terminal behind the plan's back. Area 3's JAM escalation calls
--   wms_raise_equipment_fault, which force-FAILS every outstanding command on
--   that machine — including commands this contract had live plans for. Rather
--   than have the worker crash on "command is already terminal", the RPC drops
--   the stale plan and returns result=ok with a COMMAND_ALREADY_TERMINAL
--   warning.
-- ============================================================

-- ------------------------------------------------------------
-- wms.equipment (area 1 owns it) gains one flag — design.md D1.
-- The original migration file is NOT edited; same principle areas 3 and 5 used
-- for the command_type CHECK constraint.
-- ------------------------------------------------------------

alter table wms.equipment
  add column is_simulated boolean not null default false;

create index equipment_is_simulated_idx on wms.equipment (warehouse_id, is_simulated);

-- ------------------------------------------------------------
-- Tables
-- ------------------------------------------------------------

create table wms.simulation_profiles (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references wms.tenants(id) on delete cascade,
  warehouse_id uuid not null references wms.warehouses(id) on delete cascade,
  equipment_id uuid not null references wms.equipment(id) on delete cascade,
  -- PENDING -> ACKNOWLEDGED
  ack_delay_ms_min int not null check (ack_delay_ms_min >= 0),
  ack_delay_ms_max int not null check (ack_delay_ms_max >= 0),
  -- ACKNOWLEDGED -> IN_PROGRESS
  progress_delay_ms_min int not null check (progress_delay_ms_min >= 0),
  progress_delay_ms_max int not null check (progress_delay_ms_max >= 0),
  -- IN_PROGRESS -> COMPLETED/FAILED
  completion_delay_ms_min int not null check (completion_delay_ms_min >= 0),
  completion_delay_ms_max int not null check (completion_delay_ms_max >= 0),
  failure_rate numeric not null default 0 check (failure_rate >= 0 and failure_rate <= 1),
  -- conditional: of the FAILED DIVERTs, how many are a physical JAM rather
  -- than a MISROUTE (design.md D5). Irrelevant for other command types.
  jam_rate numeric not null default 0 check (jam_rate >= 0 and jam_rate <= 1),
  -- INACTIVE falls back to the system defaults, exactly like "no profile"
  status text not null default 'ACTIVE' check (status in ('ACTIVE', 'INACTIVE')),
  version int not null default 1,
  correlation_id text,
  created_by uuid,
  updated_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (equipment_id),
  constraint simulation_profiles_ack_range check (ack_delay_ms_min <= ack_delay_ms_max),
  constraint simulation_profiles_progress_range check (progress_delay_ms_min <= progress_delay_ms_max),
  constraint simulation_profiles_completion_range check (completion_delay_ms_min <= completion_delay_ms_max)
);

-- One live plan per command (design.md D3). Deleted when the terminal step is
-- reported — the history already lives in wms.equipment_status_events, and this
-- contract does not keep a second copy of a fact.
create table wms.simulation_command_schedules (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references wms.tenants(id) on delete cascade,
  warehouse_id uuid not null references wms.warehouses(id) on delete cascade,
  equipment_id uuid not null references wms.equipment(id) on delete cascade,
  command_id uuid not null references wms.equipment_commands(id) on delete cascade,
  next_status text not null
    check (next_status in ('ACKNOWLEDGED', 'IN_PROGRESS', 'COMPLETED', 'FAILED')),
  next_run_at timestamptz not null,
  planned_terminal_status text not null
    check (planned_terminal_status in ('COMPLETED', 'FAILED')),
  planned_detail jsonb,
  -- DEVIATION 2: the remaining two delays, rolled once at planning time.
  progress_delay_ms int not null check (progress_delay_ms >= 0),
  completion_delay_ms int not null check (completion_delay_ms >= 0),
  -- traceability: which profile (or the system default) produced this plan
  profile_source text not null default 'SYSTEM_DEFAULT'
    check (profile_source in ('REGISTERED', 'SYSTEM_DEFAULT')),
  correlation_id text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (command_id)
);

create table wms.simulation_scenarios (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references wms.tenants(id) on delete cascade,
  warehouse_id uuid not null references wms.warehouses(id) on delete cascade,
  name text not null,
  -- open set on purpose (area 1 D7's pattern): follow-ups add values without
  -- reshaping the table.
  scenario_type text not null default 'EQUIPMENT_SUBSTITUTION'
    check (scenario_type in ('EQUIPMENT_SUBSTITUTION')),
  -- loose reference (design.md D8): a label for humans, never joined on.
  linked_entity_type text,
  linked_entity_id uuid,
  -- no FK per element on purpose — validated element-wise in the RPC.
  equipment_ids uuid[] not null check (array_length(equipment_ids, 1) > 0),
  command_count int not null check (command_count > 0),
  status text not null default 'DRAFT' check (status in ('DRAFT', 'RUN')),
  version int not null default 1,
  correlation_id text,
  created_by uuid,
  updated_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table wms.simulation_scenario_runs (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references wms.tenants(id) on delete cascade,
  warehouse_id uuid not null references wms.warehouses(id) on delete cascade,
  scenario_id uuid not null references wms.simulation_scenarios(id) on delete cascade,
  projected_completion_at timestamptz not null,
  projected_duration_ms int not null,
  projected_round_count int not null,
  projected_failure_count int not null,
  -- per-equipment profile snapshot used by this run, so an old projection can
  -- still be explained after the profiles change
  assumptions jsonb not null default '{}'::jsonb,
  warnings text[] not null default '{}'::text[],
  correlation_id text,
  created_by uuid,
  created_at timestamptz not null default now()
);

create index simulation_command_schedules_due_idx
  on wms.simulation_command_schedules (warehouse_id, next_run_at);
create index simulation_command_schedules_equipment_idx
  on wms.simulation_command_schedules (equipment_id);
create index simulation_scenarios_warehouse_status_idx
  on wms.simulation_scenarios (warehouse_id, status);
create index simulation_scenario_runs_scenario_idx
  on wms.simulation_scenario_runs (scenario_id, created_at desc);

-- ============================================================
-- RLS: SELECT-only for tenant/warehouse members; every write goes through the
-- SECURITY DEFINER RPCs below (same pattern as the six prior migrations).
-- ============================================================

alter table wms.simulation_profiles enable row level security;
create policy simulation_profiles_select on wms.simulation_profiles for select to authenticated
  using (warehouse_id in (select wms.current_warehouse_ids(tenant_id)));

alter table wms.simulation_command_schedules enable row level security;
create policy simulation_command_schedules_select on wms.simulation_command_schedules for select to authenticated
  using (warehouse_id in (select wms.current_warehouse_ids(tenant_id)));

alter table wms.simulation_scenarios enable row level security;
create policy simulation_scenarios_select on wms.simulation_scenarios for select to authenticated
  using (warehouse_id in (select wms.current_warehouse_ids(tenant_id)));

alter table wms.simulation_scenario_runs enable row level security;
create policy simulation_scenario_runs_select on wms.simulation_scenario_runs for select to authenticated
  using (warehouse_id in (select wms.current_warehouse_ids(tenant_id)));

grant select on wms.simulation_profiles to authenticated;
grant select on wms.simulation_command_schedules to authenticated;
grant select on wms.simulation_scenarios to authenticated;
grant select on wms.simulation_scenario_runs to authenticated;

-- ============================================================
-- Internal helpers
-- ============================================================

-- design.md D4: an is_simulated machine with no profile (or an INACTIVE one)
-- must still simulate, otherwise "I turned simulation on and nothing happened".
-- The defaults are code constants, exactly like area 4's default thresholds.
create or replace function wms._wms_simulation_effective_profile(p_equipment_id uuid)
returns jsonb
language plpgsql stable security definer
set search_path = wms, public
as $$
declare
  v_profile wms.simulation_profiles%rowtype;
begin
  select * into v_profile from wms.simulation_profiles
   where equipment_id = p_equipment_id and status = 'ACTIVE';

  if not found then
    return jsonb_build_object(
      'source', 'SYSTEM_DEFAULT', 'is_default', true,
      'profile_id', null, 'profile_version', null, 'profile_status', null,
      'ack_delay_ms_min', 500, 'ack_delay_ms_max', 1500,
      'progress_delay_ms_min', 1000, 'progress_delay_ms_max', 3000,
      'completion_delay_ms_min', 2000, 'completion_delay_ms_max', 5000,
      'failure_rate', 0.05, 'jam_rate', 0
    );
  end if;

  return jsonb_build_object(
    'source', 'REGISTERED', 'is_default', false,
    'profile_id', v_profile.id, 'profile_version', v_profile.version,
    'profile_status', v_profile.status,
    'ack_delay_ms_min', v_profile.ack_delay_ms_min, 'ack_delay_ms_max', v_profile.ack_delay_ms_max,
    'progress_delay_ms_min', v_profile.progress_delay_ms_min,
    'progress_delay_ms_max', v_profile.progress_delay_ms_max,
    'completion_delay_ms_min', v_profile.completion_delay_ms_min,
    'completion_delay_ms_max', v_profile.completion_delay_ms_max,
    'failure_rate', v_profile.failure_rate, 'jam_rate', v_profile.jam_rate
  );
end;
$$;

create or replace function wms._wms_sim_pick_delay(p_min int, p_max int)
returns int
language sql volatile
as $$
  select p_min + floor(random() * (greatest(p_max - p_min, 0) + 1))::int;
$$;

-- design.md D5 + DEVIATION 1: pick the result vocabulary from the command_type
-- string alone. No other contract's tables are read, so areas 3 and 5 stay
-- optional dependencies.
create or replace function wms._wms_sim_plan_detail(
  p_command wms.equipment_commands,
  p_terminal_status text,
  p_jam_rate numeric
) returns jsonb
language plpgsql volatile security definer
set search_path = wms, public
as $$
declare
  v_items jsonb;
  v_weight numeric;
  v_volume numeric;
begin
  -- ---- area 3's sortation vocabulary -------------------------------------
  if p_command.command_type = 'DIVERT' then
    if p_terminal_status = 'COMPLETED' then
      return jsonb_build_object(
        'outcome', 'SUCCESS',
        'actual_chute', p_command.payload->>'target_chute',
        'simulated', true);
    end if;
    if random() < coalesce(p_jam_rate, 0) then
      return jsonb_build_object(
        'outcome', 'JAM', 'reason', 'SIMULATED_JAM', 'simulated', true);
    end if;
    return jsonb_build_object(
      'outcome', 'MISROUTE', 'actual_chute', 'CHUTE-REJECT',
      'reason', 'SIMULATED_MISROUTE', 'simulated', true);
  end if;

  -- ---- area 5's palletising vocabulary -----------------------------------
  if p_command.command_type = 'PALLETIZE'
     and jsonb_typeof(p_command.payload->'sequence_items') = 'array'
     and jsonb_array_length(p_command.payload->'sequence_items') > 0 then

    if p_terminal_status = 'COMPLETED' then
      select jsonb_agg(jsonb_build_object(
               'dispatch_sequence_id', it->>'dispatch_sequence_id',
               'item_outcome', 'LOADED',
               'load_position', coalesce((it->>'sequence_position')::int, 1))
             order by coalesce((it->>'sequence_position')::int, 1))
        into v_items
        from jsonb_array_elements(p_command.payload->'sequence_items') it;
      select coalesce(sum(coalesce((it->>'declared_weight_kg')::numeric, 0)), 0),
             coalesce(sum(coalesce((it->>'declared_volume_l')::numeric, 0)), 0)
        into v_weight, v_volume
        from jsonb_array_elements(p_command.payload->'sequence_items') it;
      return jsonb_build_object(
        'outcome', 'SUCCESS', 'loaded_items', v_items,
        'total_actual_weight_kg', v_weight, 'total_actual_volume_l', v_volume,
        'simulated', true);
    end if;

    -- DEVIATION 1: a FAILED palletising must be ABORTED with every item
    -- SKIPPED; PARTIAL is a COMPLETED outcome in area 5's validator.
    select jsonb_agg(jsonb_build_object(
             'dispatch_sequence_id', it->>'dispatch_sequence_id',
             'item_outcome', 'SKIPPED',
             'reason', 'SIMULATED_ABORT')
           order by coalesce((it->>'sequence_position')::int, 1))
      into v_items
      from jsonb_array_elements(p_command.payload->'sequence_items') it;
    return jsonb_build_object(
      'outcome', 'ABORTED', 'loaded_items', v_items,
      'reason', 'SIMULATED_ABORT', 'simulated', true);
  end if;

  -- ---- generic (MOVE/LOAD/.../WRAP and anything added later) --------------
  -- DEVIATION 1: the failed word is FAILED, not FAILURE, so a WRAP result also
  -- satisfies area 5's outcome validator without a special case here.
  if p_terminal_status = 'COMPLETED' then
    return jsonb_build_object('outcome', 'SUCCESS', 'simulated', true);
  end if;
  return jsonb_build_object(
    'outcome', 'FAILED', 'reason', 'SIMULATED_FAILURE', 'simulated', true);
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

-- expected_version is the EQUIPMENT version (area 1 owns that column).
-- Deliberately touches nothing but is_simulated: spec.md "설비의 status는
-- 변경되지 않는다".
create or replace function wms.wms_set_equipment_simulation_mode(
  p_equipment_id uuid,
  p_is_simulated boolean,
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
  v_equipment wms.equipment%rowtype;
  v_before jsonb;
  v_tenant_id uuid;
  v_warnings jsonb := '[]'::jsonb;
begin
  select tenant_id into v_tenant_id from wms.equipment where id = p_equipment_id;
  if p_idempotency_key is not null and v_tenant_id is not null then
    select response into v_cached from wms.idempotency_records
      where tenant_id = v_tenant_id and command_name = 'wms_set_equipment_simulation_mode'
        and idempotency_key = p_idempotency_key;
    if found then return v_cached; end if;
  end if;

  select * into v_equipment from wms.equipment where id = p_equipment_id;
  if not found then
    raise exception 'INVALID: unknown equipment %', p_equipment_id;
  end if;
  if v_equipment.warehouse_id not in (select wms.current_warehouse_ids(v_equipment.tenant_id)) then
    raise exception 'FORBIDDEN: no warehouse scope for equipment %', p_equipment_id;
  end if;
  -- WCS_OPERATOR is deliberately absent (design.md 역할 모델): turning a machine
  -- into a software puppet is a warehouse-management decision.
  if not wms.has_role(v_equipment.tenant_id, 'WMS_ADMIN', 'WAREHOUSE_MANAGER') then
    raise exception 'FORBIDDEN: role cannot change equipment simulation mode';
  end if;
  if v_equipment.version <> p_expected_version then
    raise exception 'CONFLICT: expected version % but found %', p_expected_version, v_equipment.version;
  end if;
  if p_is_simulated is null then
    raise exception 'INVALID: is_simulated is required';
  end if;

  v_before := to_jsonb(v_equipment);

  update wms.equipment
  set is_simulated = p_is_simulated, version = version + 1,
      updated_by = p_actor_id, updated_at = now()
  where id = p_equipment_id
  returning * into v_equipment;

  -- Turning simulation off leaves any live plan orphaned; drop it so the worker
  -- stops touching a machine that is now someone else's responsibility.
  if not p_is_simulated then
    delete from wms.simulation_command_schedules where equipment_id = p_equipment_id;
    if found then
      v_warnings := v_warnings || to_jsonb('PENDING_SIMULATION_PLANS_DISCARDED'::text);
    end if;
  end if;

  insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, before, after, correlation_id)
  values (v_equipment.tenant_id, p_actor_id, 'wms_set_equipment_simulation_mode', 'equipment',
          v_equipment.id, v_before, to_jsonb(v_equipment), p_correlation_id);

  v_cached := jsonb_build_object(
    'result', 'ok',
    'document_id', v_equipment.id,
    'equipment_id', v_equipment.id,
    'status', v_equipment.status,
    'version', v_equipment.version,
    'is_simulated', v_equipment.is_simulated,
    'warnings', v_warnings,
    'next_actions', case when v_equipment.is_simulated
      then jsonb_build_array('register_simulation_profile', 'get_simulation_profile')
      else jsonb_build_array('get_simulation_profile') end
  );
  if p_idempotency_key is not null then
    insert into wms.idempotency_records (tenant_id, command_name, idempotency_key, response)
    values (v_equipment.tenant_id, 'wms_set_equipment_simulation_mode', p_idempotency_key, v_cached)
    on conflict do nothing;
  end if;
  return v_cached;
end;
$$;

create or replace function wms.wms_register_simulation_profile(
  p_equipment_id uuid,
  p_ack_delay_ms_min int,
  p_ack_delay_ms_max int,
  p_progress_delay_ms_min int,
  p_progress_delay_ms_max int,
  p_completion_delay_ms_min int,
  p_completion_delay_ms_max int,
  p_failure_rate numeric,
  p_actor_id uuid,
  p_idempotency_key uuid,
  p_jam_rate numeric default 0,
  p_correlation_id text default null
) returns jsonb
language plpgsql security definer
set search_path = wms, public
as $$
declare
  v_cached jsonb;
  v_equipment wms.equipment%rowtype;
  v_profile wms.simulation_profiles%rowtype;
  v_tenant_id uuid;
begin
  select tenant_id into v_tenant_id from wms.equipment where id = p_equipment_id;
  if p_idempotency_key is not null and v_tenant_id is not null then
    select response into v_cached from wms.idempotency_records
      where tenant_id = v_tenant_id and command_name = 'wms_register_simulation_profile'
        and idempotency_key = p_idempotency_key;
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
    raise exception 'FORBIDDEN: role cannot manage simulation profiles';
  end if;
  if not v_equipment.is_simulated then
    raise exception 'INVALID: equipment % is not in simulation mode — set is_simulated first',
      v_equipment.equipment_code;
  end if;
  if exists (select 1 from wms.simulation_profiles where equipment_id = p_equipment_id) then
    raise exception 'INVALID: equipment % already has a simulation profile — update it instead',
      v_equipment.equipment_code;
  end if;
  if p_ack_delay_ms_min is null or p_ack_delay_ms_max is null
     or p_progress_delay_ms_min is null or p_progress_delay_ms_max is null
     or p_completion_delay_ms_min is null or p_completion_delay_ms_max is null then
    raise exception 'INVALID: all three delay ranges are required';
  end if;
  if p_ack_delay_ms_min < 0 or p_progress_delay_ms_min < 0 or p_completion_delay_ms_min < 0 then
    raise exception 'INVALID: delays must not be negative';
  end if;
  if p_ack_delay_ms_min > p_ack_delay_ms_max
     or p_progress_delay_ms_min > p_progress_delay_ms_max
     or p_completion_delay_ms_min > p_completion_delay_ms_max then
    raise exception 'INVALID: every delay range needs min <= max';
  end if;
  if p_failure_rate is null or p_failure_rate < 0 or p_failure_rate > 1 then
    raise exception 'INVALID: failure_rate must be between 0 and 1';
  end if;
  if coalesce(p_jam_rate, 0) < 0 or coalesce(p_jam_rate, 0) > 1 then
    raise exception 'INVALID: jam_rate must be between 0 and 1';
  end if;

  insert into wms.simulation_profiles (
    tenant_id, warehouse_id, equipment_id,
    ack_delay_ms_min, ack_delay_ms_max,
    progress_delay_ms_min, progress_delay_ms_max,
    completion_delay_ms_min, completion_delay_ms_max,
    failure_rate, jam_rate, status, correlation_id, created_by, updated_by
  ) values (
    v_equipment.tenant_id, v_equipment.warehouse_id, v_equipment.id,
    p_ack_delay_ms_min, p_ack_delay_ms_max,
    p_progress_delay_ms_min, p_progress_delay_ms_max,
    p_completion_delay_ms_min, p_completion_delay_ms_max,
    p_failure_rate, coalesce(p_jam_rate, 0), 'ACTIVE', p_correlation_id, p_actor_id, p_actor_id
  )
  returning * into v_profile;

  insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, before, after, correlation_id)
  values (v_profile.tenant_id, p_actor_id, 'wms_register_simulation_profile', 'simulation_profile',
          v_profile.id, null, to_jsonb(v_profile), p_correlation_id);

  v_cached := jsonb_build_object(
    'result', 'ok',
    'document_id', v_profile.id,
    'profile_id', v_profile.id,
    'equipment_id', v_equipment.id,
    'equipment_code', v_equipment.equipment_code,
    'status', v_profile.status,
    'version', v_profile.version,
    'next_actions', jsonb_build_array('get_simulation_profile', 'update_simulation_profile')
  );
  if p_idempotency_key is not null then
    insert into wms.idempotency_records (tenant_id, command_name, idempotency_key, response)
    values (v_profile.tenant_id, 'wms_register_simulation_profile', p_idempotency_key, v_cached)
    on conflict do nothing;
  end if;
  return v_cached;
end;
$$;

-- expected_version is the PROFILE version. Every field is optional; an
-- all-null update is refused (area 4's precedent) so a no-op cannot silently
-- burn a version.
create or replace function wms.wms_update_simulation_profile(
  p_profile_id uuid,
  p_actor_id uuid,
  p_idempotency_key uuid,
  p_expected_version int,
  p_ack_delay_ms_min int default null,
  p_ack_delay_ms_max int default null,
  p_progress_delay_ms_min int default null,
  p_progress_delay_ms_max int default null,
  p_completion_delay_ms_min int default null,
  p_completion_delay_ms_max int default null,
  p_failure_rate numeric default null,
  p_jam_rate numeric default null,
  p_status text default null,
  p_correlation_id text default null
) returns jsonb
language plpgsql security definer
set search_path = wms, public
as $$
declare
  v_cached jsonb;
  v_profile wms.simulation_profiles%rowtype;
  v_before jsonb;
  v_tenant_id uuid;
  v_ack_min int; v_ack_max int;
  v_prog_min int; v_prog_max int;
  v_comp_min int; v_comp_max int;
begin
  select tenant_id into v_tenant_id from wms.simulation_profiles where id = p_profile_id;
  if p_idempotency_key is not null and v_tenant_id is not null then
    select response into v_cached from wms.idempotency_records
      where tenant_id = v_tenant_id and command_name = 'wms_update_simulation_profile'
        and idempotency_key = p_idempotency_key;
    if found then return v_cached; end if;
  end if;

  select * into v_profile from wms.simulation_profiles where id = p_profile_id;
  if not found then
    raise exception 'INVALID: unknown simulation profile %', p_profile_id;
  end if;
  if v_profile.warehouse_id not in (select wms.current_warehouse_ids(v_profile.tenant_id)) then
    raise exception 'FORBIDDEN: no warehouse scope for simulation profile %', p_profile_id;
  end if;
  if not wms.has_role(v_profile.tenant_id, 'WMS_ADMIN', 'WAREHOUSE_MANAGER', 'WCS_OPERATOR') then
    raise exception 'FORBIDDEN: role cannot manage simulation profiles';
  end if;
  if v_profile.version <> p_expected_version then
    raise exception 'CONFLICT: expected version % but found %', p_expected_version, v_profile.version;
  end if;
  if p_ack_delay_ms_min is null and p_ack_delay_ms_max is null
     and p_progress_delay_ms_min is null and p_progress_delay_ms_max is null
     and p_completion_delay_ms_min is null and p_completion_delay_ms_max is null
     and p_failure_rate is null and p_jam_rate is null and p_status is null then
    raise exception 'INVALID: nothing to update';
  end if;
  if p_status is not null and p_status not in ('ACTIVE', 'INACTIVE') then
    raise exception 'INVALID: status must be ACTIVE or INACTIVE';
  end if;
  if p_failure_rate is not null and (p_failure_rate < 0 or p_failure_rate > 1) then
    raise exception 'INVALID: failure_rate must be between 0 and 1';
  end if;
  if p_jam_rate is not null and (p_jam_rate < 0 or p_jam_rate > 1) then
    raise exception 'INVALID: jam_rate must be between 0 and 1';
  end if;

  v_ack_min  := coalesce(p_ack_delay_ms_min, v_profile.ack_delay_ms_min);
  v_ack_max  := coalesce(p_ack_delay_ms_max, v_profile.ack_delay_ms_max);
  v_prog_min := coalesce(p_progress_delay_ms_min, v_profile.progress_delay_ms_min);
  v_prog_max := coalesce(p_progress_delay_ms_max, v_profile.progress_delay_ms_max);
  v_comp_min := coalesce(p_completion_delay_ms_min, v_profile.completion_delay_ms_min);
  v_comp_max := coalesce(p_completion_delay_ms_max, v_profile.completion_delay_ms_max);

  if v_ack_min < 0 or v_prog_min < 0 or v_comp_min < 0 then
    raise exception 'INVALID: delays must not be negative';
  end if;
  if v_ack_min > v_ack_max or v_prog_min > v_prog_max or v_comp_min > v_comp_max then
    raise exception 'INVALID: every delay range needs min <= max';
  end if;

  v_before := to_jsonb(v_profile);

  update wms.simulation_profiles
  set ack_delay_ms_min = v_ack_min, ack_delay_ms_max = v_ack_max,
      progress_delay_ms_min = v_prog_min, progress_delay_ms_max = v_prog_max,
      completion_delay_ms_min = v_comp_min, completion_delay_ms_max = v_comp_max,
      failure_rate = coalesce(p_failure_rate, failure_rate),
      jam_rate = coalesce(p_jam_rate, jam_rate),
      status = coalesce(p_status, status),
      version = version + 1, updated_by = p_actor_id, updated_at = now()
  where id = p_profile_id
  returning * into v_profile;

  insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, before, after, correlation_id)
  values (v_profile.tenant_id, p_actor_id, 'wms_update_simulation_profile', 'simulation_profile',
          v_profile.id, v_before, to_jsonb(v_profile), p_correlation_id);

  v_cached := jsonb_build_object(
    'result', 'ok',
    'document_id', v_profile.id,
    'profile_id', v_profile.id,
    'equipment_id', v_profile.equipment_id,
    'status', v_profile.status,
    'version', v_profile.version,
    'next_actions', jsonb_build_array('get_simulation_profile')
  );
  if p_idempotency_key is not null then
    insert into wms.idempotency_records (tenant_id, command_name, idempotency_key, response)
    values (v_profile.tenant_id, 'wms_update_simulation_profile', p_idempotency_key, v_cached)
    on conflict do nothing;
  end if;
  return v_cached;
end;
$$;

-- Read-only join: every machine in the warehouse with its effective timing
-- model. `is_default=true` marks the D4 fallback so the UI can say "these are
-- the system defaults, not something you configured".
create or replace function wms.wms_get_simulation_profile(
  p_tenant_id uuid,
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
      'is_simulated', e.is_simulated,
      -- the registered row as stored (null when there is none), so an INACTIVE
      -- profile is still visible even though the effective values fall back.
      'registered_profile', (
        select jsonb_build_object(
          'profile_id', sp.id, 'status', sp.status, 'version', sp.version,
          'ack_delay_ms_min', sp.ack_delay_ms_min, 'ack_delay_ms_max', sp.ack_delay_ms_max,
          'progress_delay_ms_min', sp.progress_delay_ms_min,
          'progress_delay_ms_max', sp.progress_delay_ms_max,
          'completion_delay_ms_min', sp.completion_delay_ms_min,
          'completion_delay_ms_max', sp.completion_delay_ms_max,
          'failure_rate', sp.failure_rate, 'jam_rate', sp.jam_rate,
          'updated_at', sp.updated_at)
        from wms.simulation_profiles sp where sp.equipment_id = e.id
      ),
      'effective_profile', wms._wms_simulation_effective_profile(e.id),
      'active_schedule', (
        select jsonb_build_object(
          'schedule_id', s.id, 'command_id', s.command_id,
          'next_status', s.next_status, 'next_run_at', s.next_run_at,
          'planned_terminal_status', s.planned_terminal_status)
        from wms.simulation_command_schedules s where s.equipment_id = e.id
        order by s.next_run_at limit 1
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
    'system_defaults', wms._wms_simulation_effective_profile('00000000-0000-0000-0000-000000000000'::uuid),
    'equipment', v_items,
    'count', jsonb_array_length(v_items)
  );
end;
$$;

-- WCS_GATEWAY only (design.md 역할 모델): planning is part of *being* the
-- equipment, not part of operating it.
create or replace function wms.wms_plan_simulated_command(
  p_command_id uuid,
  p_actor_id uuid,
  p_idempotency_key uuid,
  p_correlation_id text default null
) returns jsonb
language plpgsql security definer
set search_path = wms, public
as $$
declare
  v_cached jsonb;
  v_command wms.equipment_commands%rowtype;
  v_equipment wms.equipment%rowtype;
  v_schedule wms.simulation_command_schedules%rowtype;
  v_profile jsonb;
  v_ack int; v_prog int; v_comp int;
  v_terminal text;
  v_detail jsonb;
  v_next_status text;
  v_first_delay int;
  v_tenant_id uuid;
begin
  select tenant_id into v_tenant_id from wms.equipment_commands where id = p_command_id;
  if p_idempotency_key is not null and v_tenant_id is not null then
    select response into v_cached from wms.idempotency_records
      where tenant_id = v_tenant_id and command_name = 'wms_plan_simulated_command'
        and idempotency_key = p_idempotency_key;
    if found then return v_cached; end if;
  end if;

  select * into v_command from wms.equipment_commands where id = p_command_id for update;
  if not found then
    raise exception 'INVALID: unknown equipment command %', p_command_id;
  end if;
  if v_command.warehouse_id not in (select wms.current_warehouse_ids(v_command.tenant_id)) then
    raise exception 'FORBIDDEN: no warehouse scope for command %', p_command_id;
  end if;
  if not wms.has_role(v_command.tenant_id, 'WCS_GATEWAY') then
    raise exception 'FORBIDDEN: role cannot plan simulated commands';
  end if;

  -- D3: idempotent. A worker that sees the same command twice must not re-roll
  -- the dice, otherwise the "plan is fixed at planning time" promise (D6) dies.
  select * into v_schedule from wms.simulation_command_schedules where command_id = p_command_id;
  if found then
    return jsonb_build_object(
      'result', 'ok',
      'document_id', v_schedule.id,
      'schedule_id', v_schedule.id,
      'command_id', v_schedule.command_id,
      'equipment_id', v_schedule.equipment_id,
      'status', v_schedule.next_status,
      'version', 1,
      'next_status', v_schedule.next_status,
      'next_run_at', v_schedule.next_run_at,
      'planned_terminal_status', v_schedule.planned_terminal_status,
      'planned_detail', v_schedule.planned_detail,
      'already_planned', true,
      'next_actions', jsonb_build_array('get_due_simulation_actions', 'advance_simulated_command')
    );
  end if;

  select * into v_equipment from wms.equipment where id = v_command.equipment_id;
  if not v_equipment.is_simulated then
    raise exception 'INVALID: equipment % is not in simulation mode — its commands are the real gateway''s job',
      v_equipment.equipment_code;
  end if;
  if v_command.status in ('COMPLETED', 'FAILED', 'REJECTED', 'CANCELLED') then
    raise exception 'INVALID: command % is already terminal (status=%)', p_command_id, v_command.status;
  end if;

  v_profile := wms._wms_simulation_effective_profile(v_equipment.id);
  v_ack  := wms._wms_sim_pick_delay((v_profile->>'ack_delay_ms_min')::int, (v_profile->>'ack_delay_ms_max')::int);
  v_prog := wms._wms_sim_pick_delay((v_profile->>'progress_delay_ms_min')::int, (v_profile->>'progress_delay_ms_max')::int);
  v_comp := wms._wms_sim_pick_delay((v_profile->>'completion_delay_ms_min')::int, (v_profile->>'completion_delay_ms_max')::int);

  -- D6: one roll, now, frozen into the plan.
  v_terminal := case when random() < (v_profile->>'failure_rate')::numeric then 'FAILED' else 'COMPLETED' end;
  v_detail := wms._wms_sim_plan_detail(v_command, v_terminal, (v_profile->>'jam_rate')::numeric);

  -- Pick up wherever the command already is: a half-advanced command (e.g. a
  -- human operator acknowledged it manually) gets a plan for the rest.
  if v_command.status = 'PENDING' then
    v_next_status := 'ACKNOWLEDGED'; v_first_delay := v_ack;
  elsif v_command.status = 'ACKNOWLEDGED' then
    v_next_status := 'IN_PROGRESS'; v_first_delay := v_prog;
  else
    v_next_status := v_terminal; v_first_delay := v_comp;
  end if;

  insert into wms.simulation_command_schedules (
    tenant_id, warehouse_id, equipment_id, command_id,
    next_status, next_run_at, planned_terminal_status, planned_detail,
    progress_delay_ms, completion_delay_ms, profile_source, correlation_id
  ) values (
    v_command.tenant_id, v_command.warehouse_id, v_equipment.id, v_command.id,
    v_next_status, now() + make_interval(secs => v_first_delay / 1000.0),
    v_terminal, v_detail, v_prog, v_comp, v_profile->>'source',
    coalesce(p_correlation_id, v_command.correlation_id)
  )
  returning * into v_schedule;

  insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, before, after, correlation_id)
  values (v_schedule.tenant_id, p_actor_id, 'wms_plan_simulated_command', 'simulation_command_schedule',
          v_schedule.id, null, to_jsonb(v_schedule), p_correlation_id);

  v_cached := jsonb_build_object(
    'result', 'ok',
    'document_id', v_schedule.id,
    'schedule_id', v_schedule.id,
    'command_id', v_schedule.command_id,
    'equipment_id', v_schedule.equipment_id,
    'command_type', v_command.command_type,
    'status', v_schedule.next_status,
    'version', 1,
    'next_status', v_schedule.next_status,
    'next_run_at', v_schedule.next_run_at,
    'planned_terminal_status', v_schedule.planned_terminal_status,
    'planned_detail', v_schedule.planned_detail,
    'profile_source', v_schedule.profile_source,
    'already_planned', false,
    'next_actions', jsonb_build_array('get_due_simulation_actions', 'advance_simulated_command')
  );
  if p_idempotency_key is not null then
    insert into wms.idempotency_records (tenant_id, command_name, idempotency_key, response)
    values (v_schedule.tenant_id, 'wms_plan_simulated_command', p_idempotency_key, v_cached)
    on conflict do nothing;
  end if;
  return v_cached;
end;
$$;

-- The worker's polling query. DEVIATION 3: also returns the commands that need
-- a plan, so one round trip drives the whole loop.
create or replace function wms.wms_get_due_simulation_actions(
  p_tenant_id uuid,
  p_warehouse_id uuid,
  p_as_of timestamptz default now()
) returns jsonb
language plpgsql stable security definer
set search_path = wms, public
as $$
declare
  v_as_of timestamptz := coalesce(p_as_of, now());
  v_due jsonb;
  v_unplanned jsonb;
begin
  if p_warehouse_id not in (select wms.current_warehouse_ids(p_tenant_id)) then
    raise exception 'FORBIDDEN: no warehouse scope for %', p_warehouse_id;
  end if;
  if not wms.has_role(p_tenant_id, 'WCS_GATEWAY') then
    raise exception 'FORBIDDEN: role cannot read due simulation actions';
  end if;

  select coalesce(jsonb_agg(item order by due_at, command_id), '[]'::jsonb)
  into v_due
  from (
    select s.next_run_at as due_at, s.command_id::text as command_id,
      jsonb_build_object(
        'schedule_id', s.id,
        'command_id', s.command_id,
        'equipment_id', s.equipment_id,
        'equipment_code', e.equipment_code,
        'command_type', c.command_type,
        'command_status', c.status,
        'command_version', c.version,
        'next_status', s.next_status,
        'next_run_at', s.next_run_at,
        'planned_terminal_status', s.planned_terminal_status,
        'overdue_ms', round(extract(epoch from (v_as_of - s.next_run_at)) * 1000)
      ) as item
    from wms.simulation_command_schedules s
    join wms.equipment e on e.id = s.equipment_id
    join wms.equipment_commands c on c.id = s.command_id
    where s.tenant_id = p_tenant_id
      and s.warehouse_id = p_warehouse_id
      and s.next_run_at <= v_as_of
      -- "시뮬레이션 대상이 아닌 설비의 배제": belt and braces, in case the flag
      -- was flipped off while a plan was still live.
      and e.is_simulated
  ) rows;

  select coalesce(jsonb_agg(item order by created_at), '[]'::jsonb)
  into v_unplanned
  from (
    select c.created_at,
      jsonb_build_object(
        'command_id', c.id,
        'equipment_id', c.equipment_id,
        'equipment_code', e.equipment_code,
        'command_type', c.command_type,
        'command_status', c.status,
        'command_version', c.version,
        'created_at', c.created_at
      ) as item
    from wms.equipment_commands c
    join wms.equipment e on e.id = c.equipment_id
    where c.tenant_id = p_tenant_id
      and c.warehouse_id = p_warehouse_id
      and e.is_simulated
      and c.status in ('PENDING', 'ACKNOWLEDGED', 'IN_PROGRESS')
      and not exists (select 1 from wms.simulation_command_schedules s where s.command_id = c.id)
  ) rows;

  return jsonb_build_object(
    'result', 'ok',
    'tenant_id', p_tenant_id,
    'warehouse_id', p_warehouse_id,
    'as_of', v_as_of,
    'due_actions', v_due,
    'due_count', jsonb_array_length(v_due),
    'unplanned_commands', v_unplanned,
    'unplanned_count', jsonb_array_length(v_unplanned)
  );
end;
$$;

-- The only RPC in this contract that changes area 1's state, and it does so by
-- calling area 1's own RPC — so every trigger areas 2/3/5 hung off that path
-- (work-order propagation, sortation outcome validation, JAM escalation,
-- per-item palletising propagation) fires for a simulated machine exactly as it
-- would for a real one. That is the whole point of this area.
create or replace function wms.wms_advance_simulated_command(
  p_command_id uuid,
  p_actor_id uuid,
  p_idempotency_key uuid,
  p_correlation_id text default null
) returns jsonb
language plpgsql security definer
set search_path = wms, public
as $$
declare
  v_cached jsonb;
  v_schedule wms.simulation_command_schedules%rowtype;
  v_before jsonb;
  v_command wms.equipment_commands%rowtype;
  v_reported text;
  v_detail jsonb;
  v_report jsonb;
  v_terminal boolean;
  v_tenant_id uuid;
  v_warnings jsonb := '[]'::jsonb;
begin
  select tenant_id into v_tenant_id from wms.simulation_command_schedules where command_id = p_command_id;
  if p_idempotency_key is not null and v_tenant_id is not null then
    select response into v_cached from wms.idempotency_records
      where tenant_id = v_tenant_id and command_name = 'wms_advance_simulated_command'
        and idempotency_key = p_idempotency_key;
    if found then return v_cached; end if;
  end if;

  select * into v_schedule from wms.simulation_command_schedules
    where command_id = p_command_id for update;
  if not found then
    raise exception 'INVALID: no simulation plan for command % — plan it first', p_command_id;
  end if;
  if v_schedule.warehouse_id not in (select wms.current_warehouse_ids(v_schedule.tenant_id)) then
    raise exception 'FORBIDDEN: no warehouse scope for command %', p_command_id;
  end if;
  if not wms.has_role(v_schedule.tenant_id, 'WCS_GATEWAY') then
    raise exception 'FORBIDDEN: role cannot advance simulated commands';
  end if;
  if v_schedule.next_run_at > now() then
    raise exception 'INVALID: simulation step for command % is not due until % (now %)',
      p_command_id, v_schedule.next_run_at, now();
  end if;

  select * into v_command from wms.equipment_commands where id = p_command_id for update;

  -- DEVIATION 4: something else (a fault escalation, an operator cancel) ended
  -- the command behind the plan's back. Drop the plan, do not raise.
  if v_command.status in ('COMPLETED', 'FAILED', 'REJECTED', 'CANCELLED') then
    v_before := to_jsonb(v_schedule);
    delete from wms.simulation_command_schedules where id = v_schedule.id;
    insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, before, after, correlation_id)
    values (v_schedule.tenant_id, p_actor_id, 'wms_advance_simulated_command',
            'simulation_command_schedule', v_schedule.id, v_before,
            jsonb_build_object('discarded', true, 'command_status', v_command.status), p_correlation_id);
    v_cached := jsonb_build_object(
      'result', 'ok', 'document_id', v_schedule.id, 'schedule_id', v_schedule.id,
      'command_id', p_command_id, 'equipment_id', v_schedule.equipment_id,
      'status', v_command.status, 'version', v_command.version,
      'reported_status', null, 'plan_remaining', false,
      'warnings', jsonb_build_array('COMMAND_ALREADY_TERMINAL'),
      'next_actions', jsonb_build_array('get_due_simulation_actions'));
    if p_idempotency_key is not null then
      insert into wms.idempotency_records (tenant_id, command_name, idempotency_key, response)
      values (v_schedule.tenant_id, 'wms_advance_simulated_command', p_idempotency_key, v_cached)
      on conflict do nothing;
    end if;
    return v_cached;
  end if;

  v_reported := v_schedule.next_status;
  v_terminal := v_reported in ('COMPLETED', 'FAILED');
  -- Only the terminal report carries the planned outcome payload; the interim
  -- ones carry a marker with no `outcome` key, which every outcome validator
  -- areas 3/5 installed passes straight through.
  v_detail := case when v_terminal then v_schedule.planned_detail
                   else jsonb_build_object('simulated', true, 'phase', v_reported) end;

  -- area 1's RPC, called with this session's identity (WCS_GATEWAY), which is
  -- inside its own allowed role set.
  v_report := wms.wms_report_command_result(
    p_command_id, v_reported, p_actor_id, gen_random_uuid(), v_command.version,
    v_detail, coalesce(p_correlation_id, v_schedule.correlation_id));

  v_before := to_jsonb(v_schedule);

  if v_terminal then
    delete from wms.simulation_command_schedules where id = v_schedule.id;
  else
    update wms.simulation_command_schedules
    set next_status = case when v_reported = 'ACKNOWLEDGED'
                           then 'IN_PROGRESS' else v_schedule.planned_terminal_status end,
        next_run_at = now() + make_interval(secs => (
          case when v_reported = 'ACKNOWLEDGED'
               then v_schedule.progress_delay_ms else v_schedule.completion_delay_ms end) / 1000.0),
        updated_at = now()
    where id = v_schedule.id
    returning * into v_schedule;
  end if;

  insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, before, after, correlation_id)
  values ((v_before->>'tenant_id')::uuid, p_actor_id, 'wms_advance_simulated_command',
          'simulation_command_schedule', (v_before->>'id')::uuid, v_before,
          case when v_terminal
               then jsonb_build_object('reported_status', v_reported, 'plan_completed', true,
                                       'detail', v_detail)
               else to_jsonb(v_schedule) end,
          p_correlation_id);

  v_cached := jsonb_build_object(
    'result', 'ok',
    'document_id', (v_before->>'id')::uuid,
    'schedule_id', (v_before->>'id')::uuid,
    'command_id', p_command_id,
    'equipment_id', (v_before->>'equipment_id')::uuid,
    'status', v_report->>'status',
    'version', (v_report->>'version')::int,
    'reported_status', v_reported,
    'reported_detail', v_detail,
    'equipment_status', v_report->>'equipment_status',
    'plan_remaining', not v_terminal,
    'next_status', case when v_terminal then null else v_schedule.next_status end,
    'next_run_at', case when v_terminal then null::jsonb else to_jsonb(v_schedule.next_run_at) end,
    'warnings', v_warnings,
    'next_actions', case when v_terminal
      then jsonb_build_array('get_equipment_status', 'get_simulation_schedule_status')
      else jsonb_build_array('get_due_simulation_actions', 'advance_simulated_command') end
  );
  if p_idempotency_key is not null then
    insert into wms.idempotency_records (tenant_id, command_name, idempotency_key, response)
    values ((v_before->>'tenant_id')::uuid, 'wms_advance_simulated_command', p_idempotency_key, v_cached)
    on conflict do nothing;
  end if;
  return v_cached;
end;
$$;

-- Monitoring read, open to every warehouse member — unlike the gateway-only
-- polling RPC above, this one answers "when is my command going to finish?".
create or replace function wms.wms_get_simulation_schedule_status(
  p_tenant_id uuid,
  p_warehouse_id uuid,
  p_equipment_id uuid default null,
  p_due_only boolean default false
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

  select coalesce(jsonb_agg(item order by due_at), '[]'::jsonb)
  into v_items
  from (
    select s.next_run_at as due_at,
      jsonb_build_object(
        'schedule_id', s.id,
        'command_id', s.command_id,
        'equipment_id', s.equipment_id,
        'equipment_code', e.equipment_code,
        'equipment_type', e.equipment_type,
        'is_simulated', e.is_simulated,
        'command_type', c.command_type,
        'command_status', c.status,
        'command_version', c.version,
        'next_status', s.next_status,
        'next_run_at', s.next_run_at,
        'is_due', s.next_run_at <= now(),
        'planned_terminal_status', s.planned_terminal_status,
        'planned_detail', s.planned_detail,
        'profile_source', s.profile_source,
        'created_at', s.created_at,
        'updated_at', s.updated_at
      ) as item
    from wms.simulation_command_schedules s
    join wms.equipment e on e.id = s.equipment_id
    join wms.equipment_commands c on c.id = s.command_id
    where s.tenant_id = p_tenant_id
      and s.warehouse_id = p_warehouse_id
      and (p_equipment_id is null or s.equipment_id = p_equipment_id)
      and (not coalesce(p_due_only, false) or s.next_run_at <= now())
  ) rows;

  return jsonb_build_object(
    'result', 'ok',
    'tenant_id', p_tenant_id,
    'warehouse_id', p_warehouse_id,
    'due_only', coalesce(p_due_only, false),
    'schedules', v_items,
    'count', jsonb_array_length(v_items)
  );
end;
$$;

create or replace function wms.wms_create_simulation_scenario(
  p_tenant_id uuid,
  p_warehouse_id uuid,
  p_name text,
  p_equipment_ids uuid[],
  p_command_count int,
  p_actor_id uuid,
  p_idempotency_key uuid,
  p_scenario_type text default 'EQUIPMENT_SUBSTITUTION',
  p_linked_entity_type text default null,
  p_linked_entity_id uuid default null,
  p_correlation_id text default null
) returns jsonb
language plpgsql security definer
set search_path = wms, public
as $$
declare
  v_cached jsonb;
  v_scenario wms.simulation_scenarios%rowtype;
  v_missing uuid;
begin
  if p_idempotency_key is not null then
    select response into v_cached from wms.idempotency_records
      where tenant_id = p_tenant_id and command_name = 'wms_create_simulation_scenario'
        and idempotency_key = p_idempotency_key;
    if found then return v_cached; end if;
  end if;

  if p_warehouse_id not in (select wms.current_warehouse_ids(p_tenant_id)) then
    raise exception 'FORBIDDEN: no warehouse scope for %', p_warehouse_id;
  end if;
  if not wms.has_role(p_tenant_id, 'WMS_ADMIN', 'WAREHOUSE_MANAGER', 'PROCESS_AGENT') then
    raise exception 'FORBIDDEN: role cannot define simulation scenarios';
  end if;
  if p_name is null or btrim(p_name) = '' then
    raise exception 'INVALID: scenario name is required';
  end if;
  if coalesce(p_scenario_type, '') <> 'EQUIPMENT_SUBSTITUTION' then
    raise exception 'INVALID: unknown scenario_type %', p_scenario_type;
  end if;
  if p_equipment_ids is null or coalesce(array_length(p_equipment_ids, 1), 0) = 0 then
    raise exception 'INVALID: equipment_ids must not be empty';
  end if;
  if p_command_count is null or p_command_count <= 0 then
    raise exception 'INVALID: command_count must be greater than 0';
  end if;

  -- element-wise, because a uuid[] cannot carry a FK
  select x into v_missing
  from unnest(p_equipment_ids) as x
  where not exists (
    select 1 from wms.equipment e
    where e.id = x and e.tenant_id = p_tenant_id and e.warehouse_id = p_warehouse_id)
  limit 1;
  if v_missing is not null then
    raise exception 'INVALID: equipment % is not in warehouse %', v_missing, p_warehouse_id;
  end if;

  insert into wms.simulation_scenarios (
    tenant_id, warehouse_id, name, scenario_type, linked_entity_type, linked_entity_id,
    equipment_ids, command_count, status, correlation_id, created_by, updated_by
  ) values (
    p_tenant_id, p_warehouse_id, btrim(p_name), p_scenario_type,
    p_linked_entity_type, p_linked_entity_id,
    p_equipment_ids, p_command_count, 'DRAFT', p_correlation_id, p_actor_id, p_actor_id
  )
  returning * into v_scenario;

  insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, before, after, correlation_id)
  values (v_scenario.tenant_id, p_actor_id, 'wms_create_simulation_scenario', 'simulation_scenario',
          v_scenario.id, null, to_jsonb(v_scenario), p_correlation_id);

  v_cached := jsonb_build_object(
    'result', 'ok',
    'document_id', v_scenario.id,
    'scenario_id', v_scenario.id,
    'status', v_scenario.status,
    'version', v_scenario.version,
    'equipment_count', coalesce(array_length(v_scenario.equipment_ids, 1), 0),
    'command_count', v_scenario.command_count,
    'next_actions', jsonb_build_array('run_simulation_scenario', 'get_simulation_scenario_status')
  );
  if p_idempotency_key is not null then
    insert into wms.idempotency_records (tenant_id, command_name, idempotency_key, response)
    values (p_tenant_id, 'wms_create_simulation_scenario', p_idempotency_key, v_cached)
    on conflict do nothing;
  end if;
  return v_cached;
end;
$$;

-- design.md D7: pure read + arithmetic. It never calls
-- wms_dispatch_equipment_command, so running a scenario leaves area 1's command
-- history untouched. The model is deliberately naive — rounds = ceil(count/N),
-- one round costs the mean per-command service time — and the response says so.
create or replace function wms.wms_run_simulation_scenario(
  p_scenario_id uuid,
  p_actor_id uuid,
  p_idempotency_key uuid,
  p_correlation_id text default null
) returns jsonb
language plpgsql security definer
set search_path = wms, public
as $$
declare
  v_cached jsonb;
  v_scenario wms.simulation_scenarios%rowtype;
  v_before jsonb;
  v_run wms.simulation_scenario_runs%rowtype;
  v_eq uuid;
  v_equipment wms.equipment%rowtype;
  v_profile jsonb;
  v_assumptions jsonb := '[]'::jsonb;
  v_warnings text[] := '{}'::text[];
  v_default_codes text[] := '{}'::text[];
  v_offline_codes text[] := '{}'::text[];
  v_n int := 0;
  v_sum_ms numeric := 0;
  v_sum_failure numeric := 0;
  v_mean_ms numeric;
  v_rounds int;
  v_duration_ms int;
  v_tenant_id uuid;
begin
  select tenant_id into v_tenant_id from wms.simulation_scenarios where id = p_scenario_id;
  if p_idempotency_key is not null and v_tenant_id is not null then
    select response into v_cached from wms.idempotency_records
      where tenant_id = v_tenant_id and command_name = 'wms_run_simulation_scenario'
        and idempotency_key = p_idempotency_key;
    if found then return v_cached; end if;
  end if;

  select * into v_scenario from wms.simulation_scenarios where id = p_scenario_id for update;
  if not found then
    raise exception 'INVALID: unknown simulation scenario %', p_scenario_id;
  end if;
  if v_scenario.warehouse_id not in (select wms.current_warehouse_ids(v_scenario.tenant_id)) then
    raise exception 'FORBIDDEN: no warehouse scope for scenario %', p_scenario_id;
  end if;
  if not wms.has_role(v_scenario.tenant_id, 'WMS_ADMIN', 'WAREHOUSE_MANAGER', 'PROCESS_AGENT') then
    raise exception 'FORBIDDEN: role cannot run simulation scenarios';
  end if;

  foreach v_eq in array v_scenario.equipment_ids loop
    select * into v_equipment from wms.equipment where id = v_eq;
    if not found then
      v_warnings := v_warnings || format('EQUIPMENT_MISSING: %s', v_eq);
      continue;
    end if;
    v_profile := wms._wms_simulation_effective_profile(v_eq);
    if (v_profile->>'is_default')::boolean then
      v_default_codes := v_default_codes || v_equipment.equipment_code;
    end if;
    if v_equipment.status in ('FAULT', 'MAINTENANCE', 'OFFLINE') then
      v_offline_codes := v_offline_codes || format('%s(%s)', v_equipment.equipment_code, v_equipment.status);
    end if;

    v_n := v_n + 1;
    v_sum_ms := v_sum_ms
      + ((v_profile->>'ack_delay_ms_min')::numeric + (v_profile->>'ack_delay_ms_max')::numeric) / 2
      + ((v_profile->>'progress_delay_ms_min')::numeric + (v_profile->>'progress_delay_ms_max')::numeric) / 2
      + ((v_profile->>'completion_delay_ms_min')::numeric + (v_profile->>'completion_delay_ms_max')::numeric) / 2;
    v_sum_failure := v_sum_failure + (v_profile->>'failure_rate')::numeric;

    v_assumptions := v_assumptions || jsonb_build_object(
      'equipment_id', v_equipment.id,
      'equipment_code', v_equipment.equipment_code,
      'equipment_type', v_equipment.equipment_type,
      'equipment_status', v_equipment.status,
      'is_simulated', v_equipment.is_simulated,
      'profile', v_profile);
  end loop;

  if v_n = 0 then
    raise exception 'INVALID: scenario % has no resolvable equipment', p_scenario_id;
  end if;

  v_mean_ms := v_sum_ms / v_n;
  v_rounds := ceil(v_scenario.command_count::numeric / v_n)::int;
  v_duration_ms := round(v_rounds * v_mean_ms)::int;

  if array_length(v_default_codes, 1) is not null then
    v_warnings := v_warnings || format(
      'DEFAULT_PROFILE_APPLIED: %s — no registered ACTIVE simulation profile, system defaults used',
      array_to_string(v_default_codes, ', '));
  end if;
  if array_length(v_offline_codes, 1) is not null then
    v_warnings := v_warnings || format(
      'EQUIPMENT_NOT_AVAILABLE: %s — counted in the projection anyway',
      array_to_string(v_offline_codes, ', '));
  end if;
  v_warnings := v_warnings || (
    'OPTIMISTIC_ESTIMATE: rounds = ceil(command_count / equipment_count), no queueing, ' ||
    'no retries, no priority inversion — this is an approximation, not a guarantee');

  insert into wms.simulation_scenario_runs (
    tenant_id, warehouse_id, scenario_id, projected_completion_at, projected_duration_ms,
    projected_round_count, projected_failure_count, assumptions, warnings,
    correlation_id, created_by
  ) values (
    v_scenario.tenant_id, v_scenario.warehouse_id, v_scenario.id,
    now() + make_interval(secs => v_duration_ms / 1000.0), v_duration_ms,
    v_rounds, round(v_scenario.command_count * (v_sum_failure / v_n))::int,
    jsonb_build_object(
      'equipment', v_assumptions,
      'equipment_count', v_n,
      'command_count', v_scenario.command_count,
      'mean_service_time_ms', round(v_mean_ms),
      'mean_failure_rate', round(v_sum_failure / v_n, 4),
      'model', 'ceil(command_count / equipment_count) * mean(ack+progress+completion)'),
    v_warnings, coalesce(p_correlation_id, v_scenario.correlation_id), p_actor_id
  )
  returning * into v_run;

  v_before := to_jsonb(v_scenario);
  update wms.simulation_scenarios
  set status = 'RUN', version = version + 1, updated_by = p_actor_id, updated_at = now()
  where id = v_scenario.id
  returning * into v_scenario;

  insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, before, after, correlation_id)
  values (v_run.tenant_id, p_actor_id, 'wms_run_simulation_scenario', 'simulation_scenario_run',
          v_run.id, v_before, to_jsonb(v_run), p_correlation_id);

  v_cached := jsonb_build_object(
    'result', 'ok',
    'document_id', v_run.id,
    'run_id', v_run.id,
    'scenario_id', v_scenario.id,
    'status', v_scenario.status,
    'version', v_scenario.version,
    'projected_completion_at', v_run.projected_completion_at,
    'projected_duration_ms', v_run.projected_duration_ms,
    'projected_round_count', v_run.projected_round_count,
    'projected_failure_count', v_run.projected_failure_count,
    'assumptions', v_run.assumptions,
    'warnings', to_jsonb(v_run.warnings),
    'next_actions', jsonb_build_array('get_simulation_scenario_status', 'run_simulation_scenario')
  );
  if p_idempotency_key is not null then
    insert into wms.idempotency_records (tenant_id, command_name, idempotency_key, response)
    values (v_run.tenant_id, 'wms_run_simulation_scenario', p_idempotency_key, v_cached)
    on conflict do nothing;
  end if;
  return v_cached;
end;
$$;

create or replace function wms.wms_get_simulation_scenario_status(
  p_tenant_id uuid,
  p_warehouse_id uuid,
  p_scenario_id uuid default null
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

  select coalesce(jsonb_agg(item order by created_at desc), '[]'::jsonb)
  into v_items
  from (
    select sc.created_at,
      jsonb_build_object(
        'scenario_id', sc.id,
        'name', sc.name,
        'scenario_type', sc.scenario_type,
        'linked_entity_type', sc.linked_entity_type,
        'linked_entity_id', sc.linked_entity_id,
        'equipment_ids', to_jsonb(sc.equipment_ids),
        'equipment_codes', (
          select coalesce(jsonb_agg(e.equipment_code order by e.equipment_code), '[]'::jsonb)
          from wms.equipment e where e.id = any(sc.equipment_ids)),
        'command_count', sc.command_count,
        'status', sc.status,
        'version', sc.version,
        'created_at', sc.created_at,
        'run_count', (select count(*) from wms.simulation_scenario_runs r where r.scenario_id = sc.id),
        'runs', (
          select coalesce(jsonb_agg(jsonb_build_object(
            'run_id', r.id,
            'projected_completion_at', r.projected_completion_at,
            'projected_duration_ms', r.projected_duration_ms,
            'projected_round_count', r.projected_round_count,
            'projected_failure_count', r.projected_failure_count,
            'assumptions', r.assumptions,
            'warnings', to_jsonb(r.warnings),
            'created_at', r.created_at) order by r.created_at desc), '[]'::jsonb)
          from wms.simulation_scenario_runs r where r.scenario_id = sc.id)
      ) as item
    from wms.simulation_scenarios sc
    where sc.tenant_id = p_tenant_id
      and sc.warehouse_id = p_warehouse_id
      and (p_scenario_id is null or sc.id = p_scenario_id)
  ) rows;

  return jsonb_build_object(
    'result', 'ok',
    'tenant_id', p_tenant_id,
    'warehouse_id', p_warehouse_id,
    'scenarios', v_items,
    'count', jsonb_array_length(v_items)
  );
end;
$$;

-- ============================================================
-- Grants. The internal helpers are deliberately NOT granted: they are called
-- from inside SECURITY DEFINER bodies only.
-- ============================================================

grant execute on function wms.wms_set_equipment_simulation_mode(uuid, boolean, uuid, uuid, int, text) to authenticated;
grant execute on function wms.wms_register_simulation_profile(uuid, int, int, int, int, int, int, numeric, uuid, uuid, numeric, text) to authenticated;
grant execute on function wms.wms_update_simulation_profile(uuid, uuid, uuid, int, int, int, int, int, int, int, numeric, numeric, text, text) to authenticated;
grant execute on function wms.wms_get_simulation_profile(uuid, uuid, uuid) to authenticated;
grant execute on function wms.wms_plan_simulated_command(uuid, uuid, uuid, text) to authenticated;
grant execute on function wms.wms_get_due_simulation_actions(uuid, uuid, timestamptz) to authenticated;
grant execute on function wms.wms_advance_simulated_command(uuid, uuid, uuid, text) to authenticated;
grant execute on function wms.wms_get_simulation_schedule_status(uuid, uuid, uuid, boolean) to authenticated;
grant execute on function wms.wms_create_simulation_scenario(uuid, uuid, text, uuid[], int, uuid, uuid, text, text, uuid, text) to authenticated;
grant execute on function wms.wms_run_simulation_scenario(uuid, uuid, uuid, text) to authenticated;
grant execute on function wms.wms_get_simulation_scenario_status(uuid, uuid, uuid) to authenticated;
