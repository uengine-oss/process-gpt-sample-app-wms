-- ============================================================
-- WCS intelligent-routing / bottleneck-relief contract
-- Scope: openspec/changes/add-wcs-bottleneck-routing
--        (proposal.md / design.md / specs/wms_wcs-bottleneck-routing/spec.md)
--
-- Observes the facts wms_wcs-equipment-control already records (the command
-- queue and the fault log), decides with two explainable thresholds whether a
-- piece of equipment is a throughput bottleneck *right now*, and feeds that
-- verdict into the candidate-selection step that
-- wms_wes-material-flow-control performs when it dispatches a work order.
-- It also gives operators a manual lever: force-exclude a machine from
-- automatic routing (planned maintenance) and clear that exclusion again.
--
-- No ML, no optimiser, no conveyor topology graph: queue length and recent
-- fault frequency compared against thresholds, nothing more (design.md
-- Non-Goals). The load/health signals are VIEWS, never stored copies, so they
-- cannot drift from the underlying ledger (design.md D1/D2).
--
-- Conventions (schema, common columns, RLS helpers, RPC envelope,
-- CONFLICT:/FORBIDDEN:/INVALID: prefixes, idempotency records, audit events)
-- are identical to the four migrations before it, and none of those files is
-- modified here.
--
-- ORDERING: this migration REQUIRES 20260727_wcs_equipment_control.sql
-- (wms.equipment, wms.equipment_commands, wms.equipment_faults) and — because
-- of the integration below — 20260728_wes_material_flow_control.sql
-- (wms._wms_pick_equipment_for_work_order, wms.work_orders).
--
-- ------------------------------------------------------------
-- DEVIATION 1 from design.md's "함수 계약 — 가용 설비 선택 훅" and D5, forced by
-- the *implemented* area-2 contract rather than its design draft.
--
--   design.md assumed area 2's dispatch RPCs (wms_create_work_order /
--   wms_release_dispatch_wave / wms_retry_work_order_dispatch) each run an
--   inline candidate query that this contract would replace in three places.
--
--   The shipped area 2 does not work that way: all three RPCs go through ONE
--   internal helper, wms._wms_try_dispatch_work_order, which in turn calls ONE
--   selection helper:
--       wms._wms_pick_equipment_for_work_order(
--         p_work_order wms.work_orders,
--         p_recent_window interval default interval '1 hour'
--       ) returns wms.equipment
--   — a whole-row parameter and a whole-row return, not design.md's
--   (tenant, warehouse, equipment_type, zone_code) -> uuid shape, and with a
--   tie-break window that the *caller* owns.
--
--   So the integration is done the other way round from the draft: this
--   migration still defines wms.wcs_select_available_equipment with design.md's
--   documented signature (plus a defaulted 5th parameter carrying area 2's
--   recent window, so the documented 4-argument call form still works), and then
--   `create or replace`s area 2's _wms_pick_equipment_for_work_order into a thin
--   adapter that delegates to it and re-reads the chosen row. Area 2's file is
--   untouched, its signature/return type are unchanged, and every one of its
--   three dispatch paths picks up bottleneck avoidance at once because they all
--   funnel through that single helper. If area 2 ever reshapes that helper, this
--   replacement must be re-based on it.
--
-- DEVIATION 2 — QUEUE_DEPTH_EXCEEDED cannot influence selection today.
--
--   design.md D3 defines two bottleneck reasons and D5 assumes both of them
--   bias candidate selection. Against the shipped area 2 only one of them can:
--   its candidate filter already requires `not exists (any PENDING /
--   ACKNOWLEDGED / IN_PROGRESS command)`, which is *exactly* the predicate
--   queue_depth counts. Every candidate therefore has queue_depth = 0 by
--   construction (and area 1's _wms_sync_equipment_activity has already moved
--   such a machine to RUNNING, which fails the `status='IDLE'` filter as well),
--   so QUEUE_DEPTH_EXCEEDED is structurally unreachable inside the candidate
--   set. FAULT_FREQUENCY_EXCEEDED — "this machine keeps breaking, prefer
--   another one" — is the reason that actually drives soft avoidance.
--
--   QUEUE_DEPTH_EXCEEDED is kept, because it is not dead: it is what the
--   monitoring answer (wms_get_equipment_routing_status, /wcs/routing) uses to
--   tell an operator *why* work is piling up on a machine that is not currently
--   a candidate, and it becomes selection-relevant the moment a follow-up change
--   relaxes area 2's zero-queue rule (e.g. "a machine may hold up to N queued
--   commands"). This is documented rather than hidden: see
--   openspec/specs/wms_wcs-bottleneck-routing/e2e/README.md.
--
-- DEVIATION 3 from design.md's role table — WCS_OPERATOR and policy writes.
--
--   design.md's role table gives WCS_OPERATOR exclusion rights but not policy
--   rights, and spec.md's scenario only requires "neither WMS_ADMIN nor
--   WAREHOUSE_MANAGER -> FORBIDDEN". That is implemented literally
--   (WCS_OPERATOR cannot register/update a policy). Unlike area 2, no partial
--   failure can result — the policy RPCs never dispatch anything — so there is
--   no reason to widen the set. The consequence is surfaced in the UI rather
--   than hidden (frontend/src/views/WcsRoutingView.vue shows the exclusion
--   controls but not the threshold editor for WCS_OPERATOR).
-- ============================================================

-- ------------------------------------------------------------
-- Tables
-- ------------------------------------------------------------

-- Per (warehouse, equipment_type) thresholds. Registration is OPTIONAL: with
-- no row at all, the system defaults below still produce a verdict (D4).
create table wms.wcs_routing_policies (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references wms.tenants(id) on delete cascade,
  warehouse_id uuid not null references wms.warehouses(id) on delete cascade,
  -- same value set as wms.equipment.equipment_type (area 1)
  equipment_type text not null
    check (equipment_type in ('SRM', 'CONVEYOR', 'SORTER', 'AGV', 'AMR', 'ROBOT_CELL')),
  queue_depth_threshold int not null check (queue_depth_threshold > 0),
  fault_count_threshold int not null check (fault_count_threshold > 0),
  version int not null default 1,
  correlation_id text,
  created_by uuid,
  updated_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- one policy per equipment type per warehouse (design.md 데이터 모델)
  unique (warehouse_id, equipment_type)
);

-- Manual "never route to this machine" lever. Rows are never deleted; an
-- exclusion is CLEARED so the audit trail keeps the reason and who lifted it.
create table wms.wcs_routing_overrides (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references wms.tenants(id) on delete cascade,
  warehouse_id uuid not null references wms.warehouses(id) on delete cascade,
  equipment_id uuid not null references wms.equipment(id) on delete cascade,
  reason text not null check (btrim(reason) <> ''),
  status text not null default 'ACTIVE' check (status in ('ACTIVE', 'CLEARED')),
  version int not null default 1,
  correlation_id text,
  cleared_by uuid,
  cleared_at timestamptz,
  created_by uuid,
  updated_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- CLEARED rows must carry who/when; ACTIVE ones must not.
  constraint wcs_routing_overrides_cleared_ck
    check ((status = 'CLEARED') = (cleared_at is not null))
);

-- at most one ACTIVE exclusion per machine (design.md 데이터 모델)
create unique index wcs_routing_overrides_active_equipment_idx
  on wms.wcs_routing_overrides (equipment_id) where status = 'ACTIVE';
create index wcs_routing_overrides_warehouse_status_idx
  on wms.wcs_routing_overrides (warehouse_id, status);

-- ============================================================
-- RLS: SELECT-only for tenant/warehouse members; every write goes through the
-- SECURITY DEFINER RPCs below (same pattern as the four prior migrations).
-- ============================================================

alter table wms.wcs_routing_policies enable row level security;
create policy wcs_routing_policies_select on wms.wcs_routing_policies for select to authenticated
  using (warehouse_id in (select wms.current_warehouse_ids(tenant_id)));

alter table wms.wcs_routing_overrides enable row level security;
create policy wcs_routing_overrides_select on wms.wcs_routing_overrides for select to authenticated
  using (warehouse_id in (select wms.current_warehouse_ids(tenant_id)));

grant select on wms.wcs_routing_policies to authenticated;
grant select on wms.wcs_routing_overrides to authenticated;

-- ============================================================
-- Live load / health signals (design.md D1: views, not tables)
--
-- Both views are security_invoker so the caller's own RLS on wms.equipment,
-- wms.equipment_commands, wms.equipment_faults and wms.wcs_routing_* decides
-- what they can see — the views add no scope of their own.
--
-- The 30-minute observation window is a fixed constant on purpose (design.md
-- D6): thresholds are tunable, the window is not.
-- ============================================================

create view wms.wcs_equipment_load_snapshot
with (security_invoker = true) as
select
  e.id             as equipment_id,
  e.tenant_id,
  e.warehouse_id,
  e.equipment_code,
  e.equipment_type,
  e.zone_code,
  e.status,
  e.version        as equipment_version,
  -- outstanding work: exactly the predicate area 2's candidate filter uses
  (select count(*)::int from wms.equipment_commands c
    where c.equipment_id = e.id
      and c.status in ('PENDING', 'ACKNOWLEDGED', 'IN_PROGRESS'))
                   as queue_depth,
  -- informational only — same metric area 2 tie-breaks on, NOT part of the
  -- bottleneck verdict (design.md 데이터 모델)
  (select count(*)::int from wms.equipment_commands c
    where c.equipment_id = e.id
      and c.status = 'COMPLETED'
      and c.updated_at > now() - interval '30 minutes')
                   as recent_completed_count,
  -- resolved or not: "it has been breaking a lot lately" is the signal
  (select count(*)::int from wms.equipment_faults f
    where f.equipment_id = e.id
      and f.created_at > now() - interval '30 minutes')
                   as recent_fault_count
from wms.equipment e;

comment on view wms.wcs_equipment_load_snapshot is
  'Live per-equipment load/health signals computed at query time over '
  'wms.equipment_commands / wms.equipment_faults (add-wcs-bottleneck-routing D1). '
  'Never stored, so it cannot drift from the ledger. Observation window: 30 minutes.';

create view wms.wcs_equipment_bottleneck_status
with (security_invoker = true) as
select
  s.*,
  p.id                                        as policy_id,
  coalesce(p.queue_depth_threshold, 3)        as resolved_queue_depth_threshold,
  coalesce(p.fault_count_threshold, 1)        as resolved_fault_count_threshold,
  -- D3: OR of the two explainable conditions
  (s.queue_depth      >= coalesce(p.queue_depth_threshold, 3)
   or s.recent_fault_count >= coalesce(p.fault_count_threshold, 1))
                                              as is_bottleneck,
  (case when s.queue_depth >= coalesce(p.queue_depth_threshold, 3)
        then array['QUEUE_DEPTH_EXCEEDED'] else array[]::text[] end)
  || (case when s.recent_fault_count >= coalesce(p.fault_count_threshold, 1)
        then array['FAULT_FREQUENCY_EXCEEDED'] else array[]::text[] end)
                                              as bottleneck_reasons,
  (o.id is not null)                          as is_excluded,
  o.id                                        as active_override_id,
  o.reason                                    as exclusion_reason,
  o.version                                   as active_override_version,
  o.created_at                                as excluded_at
from wms.wcs_equipment_load_snapshot s
left join wms.wcs_routing_policies p
  on p.warehouse_id = s.warehouse_id and p.equipment_type = s.equipment_type
left join wms.wcs_routing_overrides o
  on o.equipment_id = s.equipment_id and o.status = 'ACTIVE';

comment on view wms.wcs_equipment_bottleneck_status is
  'wcs_equipment_load_snapshot + the applicable thresholds (policy row, else the '
  'system defaults queue_depth=3 / fault_count=1) + the is_bottleneck verdict, its '
  'reasons, and whether an operator has force-excluded the machine. Computed per '
  'query — there is deliberately no stored bottleneck state and no '
  'BOTTLENECK_DETECTED event (add-wcs-bottleneck-routing D2).';

grant select on wms.wcs_equipment_load_snapshot to authenticated;
grant select on wms.wcs_equipment_bottleneck_status to authenticated;

-- ============================================================
-- The candidate-selection hook (design.md D5)
--
-- Owns what area 2's "가용 설비 선택과 흐름 균형" step used to do inline, and
-- keeps every one of its rules:
--   1. equipment_type / zone_code match, status = 'IDLE'
--   2. no outstanding (PENDING/ACKNOWLEDGED/IN_PROGRESS) command
--   3. fewest commands COMPLETED in the recent window, then oldest equipment,
--      then equipment_code
-- ...and adds this contract's two filters around them:
--   HARD  — an ACTIVE wcs_routing_override removes the machine entirely, even
--           if it is the only candidate left (the work order stays QUEUED and
--           area 2 reports NO_EQUIPMENT_AVAILABLE).
--   SOFT  — a bottleneck-flagged machine sorts after every non-bottleneck one,
--           but is still selected when it is all there is. Expressing the
--           "split into two groups, fall back to the flagged group, tie-break
--           inside the chosen group" rule as `order by is_bottleneck, <area 2's
--           existing ordering>` is exactly equivalent and needs no branch.
--
-- p_recent_window is an addition to design.md's 4-parameter signature: the
-- shipped area 2 lets its caller own the tie-break window, so the adapter below
-- has to pass it through. It is defaulted, so design.md's documented
-- 4-argument call form still compiles.
--
-- SECURITY DEFINER and deliberately NOT granted to authenticated (nor left with
-- the implicit PUBLIC EXECUTE grant, which is revoked below) — it is called
-- from area 2's SECURITY DEFINER RPCs and from nowhere else, and it is not
-- exposed as an MCP tool.
-- ============================================================

create or replace function wms.wcs_select_available_equipment(
  p_tenant_id uuid,
  p_warehouse_id uuid,
  p_equipment_type text,
  p_zone_code text,
  p_recent_window interval default interval '1 hour'
) returns uuid
language plpgsql stable security definer
set search_path = wms, public
as $$
declare
  v_equipment_id uuid;
begin
  select cand.id into v_equipment_id
  from (
    select
      e.id,
      e.created_at,
      e.equipment_code,
      coalesce(b.is_bottleneck, false) as is_bottleneck,
      (select count(*) from wms.equipment_commands c
        where c.equipment_id = e.id
          and c.status = 'COMPLETED'
          and c.updated_at > now() - p_recent_window) as recent_completed
    from wms.equipment e
    left join wms.wcs_equipment_bottleneck_status b on b.equipment_id = e.id
    where e.tenant_id = p_tenant_id
      and e.warehouse_id = p_warehouse_id
      and e.equipment_type = p_equipment_type
      -- a null work-order zone_code means "any zone in this warehouse"
      and (p_zone_code is null or e.zone_code = p_zone_code)
      and e.status = 'IDLE'
      and not exists (
        select 1 from wms.equipment_commands c
        where c.equipment_id = e.id
          and c.status in ('PENDING', 'ACKNOWLEDGED', 'IN_PROGRESS')
      )
      -- HARD filter: this contract's only absolute veto
      and not exists (
        select 1 from wms.wcs_routing_overrides o
        where o.equipment_id = e.id and o.status = 'ACTIVE'
      )
  ) cand
  order by cand.is_bottleneck asc,      -- SOFT avoidance, with implicit fallback
           cand.recent_completed asc,   -- area 2's tie-break, unchanged
           cand.created_at asc,
           cand.equipment_code asc
  limit 1;

  return v_equipment_id;
end;
$$;

revoke execute on function
  wms.wcs_select_available_equipment(uuid, uuid, text, text, interval) from public;

comment on function wms.wcs_select_available_equipment(uuid, uuid, text, text, interval) is
  'Internal candidate selection for wms_wes-material-flow-control dispatch. '
  'Hard-excludes ACTIVE wcs_routing_overrides, soft-avoids bottleneck-flagged '
  'equipment (falling back to it when nothing else is left), then applies area '
  '2''s original tie-break. Not an RPC: no EXECUTE for authenticated, no MCP tool.';

-- ------------------------------------------------------------
-- DEVIATION 1 (see header): area 2's selection helper becomes a thin adapter
-- over the function above. Same signature, same return type, same null-row
-- contract for "nothing available" — the only change is where the decision is
-- made. 20260728_wes_material_flow_control.sql itself stays untouched.
-- ------------------------------------------------------------

create or replace function wms._wms_pick_equipment_for_work_order(
  p_work_order wms.work_orders,
  p_recent_window interval default interval '1 hour'
) returns wms.equipment
language plpgsql stable security definer
set search_path = wms, public
as $$
declare
  v_equipment wms.equipment%rowtype;
  v_equipment_id uuid;
begin
  v_equipment_id := wms.wcs_select_available_equipment(
    p_work_order.tenant_id,
    p_work_order.warehouse_id,
    p_work_order.equipment_type,
    p_work_order.zone_code,
    p_recent_window
  );

  -- callers test v_equipment.id is null, so an all-null row is the right
  -- "nothing available" answer (unchanged from area 2's own behaviour).
  if v_equipment_id is null then
    return v_equipment;
  end if;

  select * into v_equipment from wms.equipment where id = v_equipment_id;
  return v_equipment;
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

create or replace function wms.wms_register_wcs_routing_policy(
  p_tenant_id uuid,
  p_warehouse_id uuid,
  p_equipment_type text,
  p_queue_depth_threshold int,
  p_fault_count_threshold int,
  p_actor_id uuid,
  p_idempotency_key uuid,
  p_correlation_id text default null
) returns jsonb
language plpgsql security definer
set search_path = wms, public
as $$
declare
  v_cached jsonb;
  v_policy wms.wcs_routing_policies%rowtype;
begin
  if p_idempotency_key is not null then
    select response into v_cached from wms.idempotency_records
      where tenant_id = p_tenant_id and command_name = 'wms_register_wcs_routing_policy'
        and idempotency_key = p_idempotency_key;
    if found then return v_cached; end if;
  end if;

  if p_warehouse_id not in (select wms.current_warehouse_ids(p_tenant_id)) then
    raise exception 'FORBIDDEN: no warehouse scope for %', p_warehouse_id;
  end if;
  -- DEVIATION 3 (header): threshold tuning is an operations-management call,
  -- so WCS_OPERATOR is deliberately absent here.
  if not wms.has_role(p_tenant_id, 'WMS_ADMIN', 'WAREHOUSE_MANAGER') then
    raise exception 'FORBIDDEN: role cannot manage wcs routing policies';
  end if;
  if p_equipment_type not in ('SRM', 'CONVEYOR', 'SORTER', 'AGV', 'AMR', 'ROBOT_CELL') then
    raise exception 'INVALID: unknown equipment_type %', p_equipment_type;
  end if;
  if coalesce(p_queue_depth_threshold, 0) <= 0 then
    raise exception 'INVALID: queue_depth_threshold must be greater than 0';
  end if;
  if coalesce(p_fault_count_threshold, 0) <= 0 then
    raise exception 'INVALID: fault_count_threshold must be greater than 0';
  end if;
  if exists (
    select 1 from wms.wcs_routing_policies
    where warehouse_id = p_warehouse_id and equipment_type = p_equipment_type
  ) then
    raise exception 'INVALID: a routing policy for % already exists in this warehouse — update it instead',
      p_equipment_type;
  end if;

  insert into wms.wcs_routing_policies (
    tenant_id, warehouse_id, equipment_type, queue_depth_threshold, fault_count_threshold,
    correlation_id, created_by, updated_by
  ) values (
    p_tenant_id, p_warehouse_id, p_equipment_type, p_queue_depth_threshold, p_fault_count_threshold,
    p_correlation_id, p_actor_id, p_actor_id
  )
  returning * into v_policy;

  insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, before, after, correlation_id)
  values (v_policy.tenant_id, p_actor_id, 'wms_register_wcs_routing_policy', 'wcs_routing_policy', v_policy.id,
          null, to_jsonb(v_policy), p_correlation_id);

  v_cached := jsonb_build_object(
    'result', 'ok',
    'document_id', v_policy.id,
    'policy_id', v_policy.id,
    'equipment_type', v_policy.equipment_type,
    'queue_depth_threshold', v_policy.queue_depth_threshold,
    'fault_count_threshold', v_policy.fault_count_threshold,
    -- a policy row has no lifecycle of its own; ACTIVE keeps the envelope's
    -- `status` field meaningful for callers that log it.
    'status', 'ACTIVE',
    'version', v_policy.version,
    'warnings', '[]'::jsonb,
    'next_actions', jsonb_build_array('get_equipment_routing_status', 'update_wcs_routing_policy')
  );
  if p_idempotency_key is not null then
    insert into wms.idempotency_records (tenant_id, command_name, idempotency_key, response)
    values (p_tenant_id, 'wms_register_wcs_routing_policy', p_idempotency_key, v_cached)
    on conflict do nothing;
  end if;
  return v_cached;
end;
$$;

-- expected_version is the POLICY version. Null thresholds mean "leave as is".
create or replace function wms.wms_update_wcs_routing_policy(
  p_policy_id uuid,
  p_actor_id uuid,
  p_idempotency_key uuid,
  p_expected_version int,
  p_queue_depth_threshold int default null,
  p_fault_count_threshold int default null,
  p_correlation_id text default null
) returns jsonb
language plpgsql security definer
set search_path = wms, public
as $$
declare
  v_cached jsonb;
  v_policy wms.wcs_routing_policies%rowtype;
  v_before jsonb;
  v_tenant_id uuid;
begin
  select tenant_id into v_tenant_id from wms.wcs_routing_policies where id = p_policy_id;
  if p_idempotency_key is not null and v_tenant_id is not null then
    select response into v_cached from wms.idempotency_records
      where tenant_id = v_tenant_id and command_name = 'wms_update_wcs_routing_policy'
        and idempotency_key = p_idempotency_key;
    if found then return v_cached; end if;
  end if;

  select * into v_policy from wms.wcs_routing_policies where id = p_policy_id for update;
  if not found then
    raise exception 'INVALID: unknown wcs routing policy %', p_policy_id;
  end if;
  if v_policy.warehouse_id not in (select wms.current_warehouse_ids(v_policy.tenant_id)) then
    raise exception 'FORBIDDEN: no warehouse scope for wcs routing policy %', p_policy_id;
  end if;
  if not wms.has_role(v_policy.tenant_id, 'WMS_ADMIN', 'WAREHOUSE_MANAGER') then
    raise exception 'FORBIDDEN: role cannot manage wcs routing policies';
  end if;
  if v_policy.version <> p_expected_version then
    raise exception 'CONFLICT: expected version % but found %', p_expected_version, v_policy.version;
  end if;
  if p_queue_depth_threshold is not null and p_queue_depth_threshold <= 0 then
    raise exception 'INVALID: queue_depth_threshold must be greater than 0';
  end if;
  if p_fault_count_threshold is not null and p_fault_count_threshold <= 0 then
    raise exception 'INVALID: fault_count_threshold must be greater than 0';
  end if;
  if p_queue_depth_threshold is null and p_fault_count_threshold is null then
    raise exception 'INVALID: nothing to update — provide queue_depth_threshold and/or fault_count_threshold';
  end if;

  v_before := to_jsonb(v_policy);

  update wms.wcs_routing_policies
  set queue_depth_threshold = coalesce(p_queue_depth_threshold, queue_depth_threshold),
      fault_count_threshold = coalesce(p_fault_count_threshold, fault_count_threshold),
      correlation_id = coalesce(p_correlation_id, correlation_id),
      version = version + 1,
      updated_by = p_actor_id,
      updated_at = now()
  where id = p_policy_id
  returning * into v_policy;

  insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, before, after, correlation_id)
  values (v_policy.tenant_id, p_actor_id, 'wms_update_wcs_routing_policy', 'wcs_routing_policy', v_policy.id,
          v_before, to_jsonb(v_policy), p_correlation_id);

  v_cached := jsonb_build_object(
    'result', 'ok',
    'document_id', v_policy.id,
    'policy_id', v_policy.id,
    'equipment_type', v_policy.equipment_type,
    'queue_depth_threshold', v_policy.queue_depth_threshold,
    'fault_count_threshold', v_policy.fault_count_threshold,
    'status', 'ACTIVE',
    'version', v_policy.version,
    -- the verdict is recomputed per query (D2), so a new threshold takes effect
    -- on the very next read/dispatch. Say so instead of implying a backfill.
    'warnings', '[]'::jsonb,
    'next_actions', jsonb_build_array('get_equipment_routing_status')
  );
  if p_idempotency_key is not null then
    insert into wms.idempotency_records (tenant_id, command_name, idempotency_key, response)
    values (v_policy.tenant_id, 'wms_update_wcs_routing_policy', p_idempotency_key, v_cached)
    on conflict do nothing;
  end if;
  return v_cached;
end;
$$;

create or replace function wms.wms_exclude_equipment_from_routing(
  p_equipment_id uuid,
  p_reason text,
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
  v_override wms.wcs_routing_overrides%rowtype;
  v_tenant_id uuid;
  v_warnings jsonb := '[]'::jsonb;
begin
  select tenant_id into v_tenant_id from wms.equipment where id = p_equipment_id;
  if p_idempotency_key is not null and v_tenant_id is not null then
    select response into v_cached from wms.idempotency_records
      where tenant_id = v_tenant_id and command_name = 'wms_exclude_equipment_from_routing'
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
    raise exception 'FORBIDDEN: role cannot exclude equipment from routing';
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'INVALID: reason is required';
  end if;
  if exists (
    select 1 from wms.wcs_routing_overrides
    where equipment_id = p_equipment_id and status = 'ACTIVE'
  ) then
    raise exception 'INVALID: equipment % is already excluded from routing — clear the exclusion first',
      v_equipment.equipment_code;
  end if;

  insert into wms.wcs_routing_overrides (
    tenant_id, warehouse_id, equipment_id, reason, status,
    correlation_id, created_by, updated_by
  ) values (
    v_equipment.tenant_id, v_equipment.warehouse_id, v_equipment.id, btrim(p_reason), 'ACTIVE',
    p_correlation_id, p_actor_id, p_actor_id
  )
  returning * into v_override;

  -- honest about scope: this stops FUTURE routing only. Commands already on
  -- the machine keep running (cancel them through area 1 if that is wanted).
  if exists (
    select 1 from wms.equipment_commands
    where equipment_id = p_equipment_id
      and status in ('PENDING', 'ACKNOWLEDGED', 'IN_PROGRESS')
  ) then
    v_warnings := v_warnings || to_jsonb('IN_FLIGHT_COMMANDS_NOT_CANCELLED'::text);
  end if;

  insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, before, after, correlation_id)
  values (v_override.tenant_id, p_actor_id, 'wms_exclude_equipment_from_routing', 'wcs_routing_override',
          v_override.id, null, to_jsonb(v_override), p_correlation_id);

  v_cached := jsonb_build_object(
    'result', 'ok',
    'document_id', v_override.id,
    'override_id', v_override.id,
    'equipment_id', v_equipment.id,
    'equipment_code', v_equipment.equipment_code,
    'status', v_override.status,
    'version', v_override.version,
    'warnings', v_warnings,
    'next_actions', jsonb_build_array('clear_equipment_routing_exclusion', 'get_equipment_routing_status')
  );
  if p_idempotency_key is not null then
    insert into wms.idempotency_records (tenant_id, command_name, idempotency_key, response)
    values (v_override.tenant_id, 'wms_exclude_equipment_from_routing', p_idempotency_key, v_cached)
    on conflict do nothing;
  end if;
  return v_cached;
end;
$$;

-- expected_version is the OVERRIDE version.
create or replace function wms.wms_clear_equipment_routing_exclusion(
  p_override_id uuid,
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
  v_override wms.wcs_routing_overrides%rowtype;
  v_before jsonb;
  v_equipment wms.equipment%rowtype;
  v_tenant_id uuid;
begin
  select tenant_id into v_tenant_id from wms.wcs_routing_overrides where id = p_override_id;
  if p_idempotency_key is not null and v_tenant_id is not null then
    select response into v_cached from wms.idempotency_records
      where tenant_id = v_tenant_id and command_name = 'wms_clear_equipment_routing_exclusion'
        and idempotency_key = p_idempotency_key;
    if found then return v_cached; end if;
  end if;

  select * into v_override from wms.wcs_routing_overrides where id = p_override_id for update;
  if not found then
    raise exception 'INVALID: unknown routing exclusion %', p_override_id;
  end if;
  if v_override.warehouse_id not in (select wms.current_warehouse_ids(v_override.tenant_id)) then
    raise exception 'FORBIDDEN: no warehouse scope for routing exclusion %', p_override_id;
  end if;
  if not wms.has_role(v_override.tenant_id, 'WMS_ADMIN', 'WAREHOUSE_MANAGER', 'WCS_OPERATOR') then
    raise exception 'FORBIDDEN: role cannot clear routing exclusions';
  end if;
  if v_override.version <> p_expected_version then
    raise exception 'CONFLICT: expected version % but found %', p_expected_version, v_override.version;
  end if;
  if v_override.status <> 'ACTIVE' then
    raise exception 'INVALID: routing exclusion % is not ACTIVE (status=%)', p_override_id, v_override.status;
  end if;

  v_before := to_jsonb(v_override);

  update wms.wcs_routing_overrides
  set status = 'CLEARED',
      cleared_by = p_actor_id,
      cleared_at = now(),
      correlation_id = coalesce(p_correlation_id, correlation_id),
      version = version + 1,
      updated_by = p_actor_id,
      updated_at = now()
  where id = p_override_id
  returning * into v_override;

  select * into v_equipment from wms.equipment where id = v_override.equipment_id;

  insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, before, after, correlation_id)
  values (v_override.tenant_id, p_actor_id, 'wms_clear_equipment_routing_exclusion', 'wcs_routing_override',
          v_override.id, v_before, to_jsonb(v_override), p_correlation_id);

  v_cached := jsonb_build_object(
    'result', 'ok',
    'document_id', v_override.id,
    'override_id', v_override.id,
    'equipment_id', v_override.equipment_id,
    'equipment_code', v_equipment.equipment_code,
    'status', v_override.status,
    'version', v_override.version,
    'warnings', '[]'::jsonb,
    'next_actions', jsonb_build_array('get_equipment_routing_status', 'exclude_equipment_from_routing')
  );
  if p_idempotency_key is not null then
    insert into wms.idempotency_records (tenant_id, command_name, idempotency_key, response)
    values (v_override.tenant_id, 'wms_clear_equipment_routing_exclusion', p_idempotency_key, v_cached)
    on conflict do nothing;
  end if;
  return v_cached;
end;
$$;

-- Read-only routing board: every machine in the warehouse with its live load
-- signals, the thresholds actually applied to it, the bottleneck verdict and
-- its reasons, and any active exclusion — plus the warehouse's threshold
-- policies so one call can drive the whole /wcs/routing screen.
create or replace function wms.wms_get_equipment_routing_status(
  p_tenant_id uuid,
  p_warehouse_id uuid,
  p_equipment_id uuid default null
) returns jsonb
language plpgsql stable security definer
set search_path = wms, public
as $$
declare
  v_items jsonb;
  v_policies jsonb;
begin
  if p_warehouse_id not in (select wms.current_warehouse_ids(p_tenant_id)) then
    raise exception 'FORBIDDEN: no warehouse scope for %', p_warehouse_id;
  end if;

  select coalesce(jsonb_agg(item order by item->>'equipment_code'), '[]'::jsonb)
  into v_items
  from (
    select jsonb_build_object(
      'equipment_id', b.equipment_id,
      'equipment_code', b.equipment_code,
      'equipment_type', b.equipment_type,
      'zone_code', b.zone_code,
      'equipment_status', b.status,
      'equipment_version', b.equipment_version,
      'queue_depth', b.queue_depth,
      'recent_completed_count', b.recent_completed_count,
      'recent_fault_count', b.recent_fault_count,
      'resolved_queue_depth_threshold', b.resolved_queue_depth_threshold,
      'resolved_fault_count_threshold', b.resolved_fault_count_threshold,
      'policy_id', b.policy_id,
      'threshold_source', case when b.policy_id is null then 'SYSTEM_DEFAULT' else 'POLICY' end,
      'is_bottleneck', b.is_bottleneck,
      'bottleneck_reasons', to_jsonb(b.bottleneck_reasons),
      'is_excluded', b.is_excluded,
      'active_override', case when b.active_override_id is null then null else jsonb_build_object(
        'override_id', b.active_override_id,
        'reason', b.exclusion_reason,
        'version', b.active_override_version,
        'excluded_at', b.excluded_at
      ) end,
      -- what the selection hook would do with this machine right now
      'routable', (not b.is_excluded)
                  and b.status = 'IDLE'
                  and b.queue_depth = 0
    ) as item
    from wms.wcs_equipment_bottleneck_status b
    where b.tenant_id = p_tenant_id
      and b.warehouse_id = p_warehouse_id
      and (p_equipment_id is null or b.equipment_id = p_equipment_id)
  ) rows;

  select coalesce(jsonb_agg(jsonb_build_object(
    'policy_id', p.id,
    'equipment_type', p.equipment_type,
    'queue_depth_threshold', p.queue_depth_threshold,
    'fault_count_threshold', p.fault_count_threshold,
    'version', p.version,
    'updated_at', p.updated_at
  ) order by p.equipment_type), '[]'::jsonb)
  into v_policies
  from wms.wcs_routing_policies p
  where p.tenant_id = p_tenant_id and p.warehouse_id = p_warehouse_id;

  return jsonb_build_object(
    'result', 'ok',
    'tenant_id', p_tenant_id,
    'warehouse_id', p_warehouse_id,
    'observation_window', '30 minutes',
    'default_queue_depth_threshold', 3,
    'default_fault_count_threshold', 1,
    'items', v_items,
    'count', jsonb_array_length(v_items),
    'policies', v_policies
  );
end;
$$;

grant execute on function wms.wms_register_wcs_routing_policy(uuid, uuid, text, int, int, uuid, uuid, text) to authenticated;
grant execute on function wms.wms_update_wcs_routing_policy(uuid, uuid, uuid, int, int, int, text) to authenticated;
grant execute on function wms.wms_exclude_equipment_from_routing(uuid, text, uuid, uuid, text) to authenticated;
grant execute on function wms.wms_clear_equipment_routing_exclusion(uuid, uuid, uuid, int, text) to authenticated;
grant execute on function wms.wms_get_equipment_routing_status(uuid, uuid, uuid) to authenticated;
