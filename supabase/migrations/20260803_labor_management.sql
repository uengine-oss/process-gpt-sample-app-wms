-- ============================================================
-- Labor management contract
-- Scope: openspec/changes/add-labor-management
--        (proposal.md / design.md / specs/wms_labor-management/spec.md)
--
-- The eighth area. Like area 7 (yard/dock) it is NOT part of the WCS/WES
-- chain — it references no equipment, no command, no dock, no wave. It adds
-- exactly one table:
--
--   * wms.labor_activities — "worker X worked on Y from t0 to t1, handling N
--     units". A time-interval log, NOT a task queue: no assignment, no
--     priority, no claim contention, no SLA (design.md Non-Goals).
--
-- and six RPCs on top of it: three writes (start / complete / cancel) and
-- three reads (productivity aggregation / leaderboard / demand forecast).
--
-- Conventions (schema, common columns, RLS helpers, RPC envelope,
-- CONFLICT:/FORBIDDEN:/INVALID: prefixes, idempotency records, audit events)
-- are identical to the eight migrations before it, and none of those files is
-- modified here.
--
-- ORDERING / DEPENDENCIES: this migration requires only
--   20260726_wms_core_schema.sql  (wms.tenants, wms.warehouses,
--                                  wms.memberships, wms.idempotency_records,
--                                  wms.audit_events, wms.has_role,
--                                  wms.current_warehouse_ids)
-- It has NO dependency on areas 1-7.
--
-- NOT MODIFIED HERE: wms_register_arrival, wms_receive,
-- wms_record_quality_result, wms_apply_disposition, wms_create_putaway_tasks.
-- design.md D1 makes this an ORTHOGONAL instrumentation layer that a caller
-- wraps around those RPCs — their signatures and behaviour are untouched, and
-- a receipt can walk the whole inbound flow with no labor activity at all.
-- Verified by openspec/specs/wms_labor-management/e2e/verify.sql (§9).
--
-- ------------------------------------------------------------
-- D1 (as designed) — explicit start/complete pairs, not audit-log inference.
--   wms.audit_events records a single instant per command, and the same
--   receipt is routinely touched by several people, so back-computing "how
--   long did this person work" from event gaps would attribute idle time and
--   other people's work to whoever happened to close the document. The three
--   write RPCs below record the interval directly instead.
--
-- D2 (as designed) — actor spoofing is refused.
--   Unlike wms_receive et al., these RPCs verify p_actor_id = auth.uid().
--   Productivity numbers are the product here, so recording work under a
--   colleague's name would corrupt the leaderboard and any HR-adjacent use of
--   the aggregate. WMS_ADMIN is the single proxy exception (offline workers,
--   correcting a mis-filed activity).
--
-- D3 (as designed) — privacy is enforced TWICE, on purpose.
--   (a) RLS on the table: warehouse scope AND (own row OR manager/admin).
--       This covers PostgREST/supabase-js reading the table directly.
--   (b) The same predicate re-implemented by hand inside the aggregation
--       RPCs. They are SECURITY DEFINER, which bypasses RLS entirely, so the
--       policy in (a) would be no protection at all there — the repo's
--       existing read RPCs (wms_check_stock, wms_get_dock_schedule) already
--       hand-check warehouse scope for exactly this reason.
--   Non-managers are filtered SILENTLY rather than refused: "I wanted to see
--   my own rank and got a 403" is the wrong experience for a leaderboard.
--
-- D5 (as designed) — activity_type is a CHECK-constrained set matching the
--   business flows this repository actually has, plus OTHER as the escape
--   hatch. OTHER requires activity_label so the aggregate stays readable.
--
-- ------------------------------------------------------------
-- DEVIATIONS from design.md, deliberate and small:
--
-- V1. PARAMETER ORDER. design.md's RPC table lists e.g.
--       (p_tenant_id, p_warehouse_id, p_activity_type,
--        p_activity_label default null, ..., p_actor_id, p_idempotency_key)
--     which PostgreSQL rejects — a parameter without a default may not follow
--     one that has a default. The required (non-default) parameters are
--     therefore hoisted ahead of the optional ones. The SET of parameters and
--     their names/types/defaults are exactly as designed, and every caller in
--     this repository (supabase-js, MCP) passes them by name, so the order is
--     not observable to them.
--
-- V2. WAREHOUSE_MANAGER MAY ALSO RECORD ITS OWN ACTIVITIES. design.md's RPC
--     table lists the write roles as INBOUND_OPERATOR / QUALITY_INSPECTOR /
--     PROCESS_AGENT / WMS_ADMIN, but D4's prose says managers get "위 전체에
--     더해" the read-side powers. Excluding a working supervisor from logging
--     their own work would be an odd hole, and spec.md's requirement is
--     phrased as a SHALL-allow for those four rather than a SHALL-refuse for
--     everyone else. WAREHOUSE_MANAGER is therefore included in the write
--     roles. It grants no cross-worker power: D2's actor guard still applies,
--     and only WMS_ADMIN may record under someone else's name.
--
-- V3. LEADERBOARD RANK IS WITHHELD, NOT FAKED, IN SELF SCOPE. spec.md says a
--     non-manager's leaderboard must not expose "다른 작업자의 순위나 수치".
--     Returning rank=1 for a worker who is really third would be a lie;
--     returning their true global rank would leak how many colleagues are
--     ahead of them. So in SELF scope `rank` is null, `scope` is 'SELF', and
--     a note 'SELF_SCOPE_RANK_WITHHELD' says why.
--
-- V4. THE FORECAST MEASURES THROUGHPUT IN UNITS. "평균 시간당 처리량" needs a
--     unit of production, and the only one this contract records is
--     unit_count. If the trailing window has completed activities but no
--     unit_count on any of them, the forecast raises INVALID rather than
--     silently switching to "activities per hour" — same principle as the
--     no-sample case spec.md already mandates.
-- ============================================================

-- ------------------------------------------------------------
-- Table
-- ------------------------------------------------------------

create table wms.labor_activities (
  id uuid primary key default gen_random_uuid(),
  tenant_id text not null references wms.tenants(id) on delete cascade,
  warehouse_id uuid not null references wms.warehouses(id) on delete cascade,
  -- the worker the activity is attributed to. D2 keeps this honest.
  actor_id uuid not null references auth.users(id) on delete cascade,
  -- snapshot of wms.memberships.role at start time, denormalised on purpose:
  -- a promotion must not retroactively rewrite last quarter's aggregates.
  actor_role text not null,
  activity_type text not null
    check (activity_type in ('RECEIVING', 'QUALITY_INSPECTION', 'PUTAWAY', 'DISPOSITION', 'OTHER')),
  activity_label text,
  -- loose reference, no FK — same pattern as wms.equipment_commands (area 1)
  -- and wms.dock_appointments (area 7). A future generic warehouse_task model
  -- slots in here as ('warehouse_task', task_id) without a migration.
  linked_entity_type text,
  linked_entity_id uuid,
  unit_count numeric,
  status text not null default 'IN_PROGRESS'
    check (status in ('IN_PROGRESS', 'COMPLETED', 'CANCELLED')),
  started_at timestamptz not null default now(),
  completed_at timestamptz,
  -- Only a finished activity has a duration. CANCELLED rows get one too (they
  -- carry completed_at), but every aggregation below filters on
  -- status = 'COMPLETED', so cancelled time never reaches a productivity
  -- number (spec.md "인력 활동 취소").
  duration_seconds bigint generated always as (
    case when completed_at is null then null
         else (extract(epoch from (completed_at - started_at)))::bigint end
  ) stored,
  reason text,
  version int not null default 1,
  correlation_id text,
  created_by uuid,
  updated_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint labor_activities_other_needs_label_ck
    check (activity_type <> 'OTHER' or activity_label is not null),
  constraint labor_activities_in_progress_open_ck
    check (status <> 'IN_PROGRESS' or completed_at is null),
  constraint labor_activities_terminal_closed_ck
    check (status = 'IN_PROGRESS' or completed_at is not null),
  constraint labor_activities_unit_count_ck
    check (unit_count is null or unit_count >= 0),
  constraint labor_activities_window_ck
    check (completed_at is null or completed_at >= started_at),
  constraint labor_activities_linked_pair_ck
    check ((linked_entity_type is null) = (linked_entity_id is null))
);

create index labor_activities_warehouse_completed_idx
  on wms.labor_activities (warehouse_id, completed_at);
create index labor_activities_actor_status_idx
  on wms.labor_activities (actor_id, status);
create index labor_activities_role_completed_idx
  on wms.labor_activities (warehouse_id, actor_role, completed_at)
  where status = 'COMPLETED';
create index labor_activities_linked_idx
  on wms.labor_activities (linked_entity_type, linked_entity_id);

-- ============================================================
-- RLS (D3a). SELECT-only, and narrower than every other table in this schema:
-- warehouse scope is not enough, the row must be yours or you must be a
-- manager/admin. Every write goes through the SECURITY DEFINER RPCs below; no
-- INSERT/UPDATE/DELETE policy exists, so RLS denies those by default.
-- ============================================================

alter table wms.labor_activities enable row level security;

create policy labor_activities_select_self_or_manager
  on wms.labor_activities for select to authenticated
  using (
    warehouse_id in (select wms.current_warehouse_ids(tenant_id))
    and (
      actor_id = auth.uid()
      or wms.has_role(tenant_id, 'WAREHOUSE_MANAGER', 'WMS_ADMIN')
    )
  );

grant select on wms.labor_activities to authenticated;

-- ============================================================
-- Internal helpers (no grant — same as wms._wms_finalize_disposition and
-- wms._wms_load_dock_appointment)
-- ============================================================

-- D2 in one place. Returns true when the caller may act under p_actor_id.
create or replace function wms._wms_labor_actor_ok(
  p_tenant_id text,
  p_actor_id uuid
) returns boolean
language sql stable security definer
set search_path = wms, public
as $$
  select p_actor_id is not null
     and (p_actor_id = auth.uid() or wms.has_role(p_tenant_id, 'WMS_ADMIN'));
$$;

-- Loads an activity and enforces everything complete/cancel both need:
-- existence, warehouse scope, role, optimistic version, and the D2 ownership
-- rule (you may only close your own activity; WMS_ADMIN may close anyone's).
create or replace function wms._wms_load_labor_activity(
  p_activity_id uuid,
  p_actor_id uuid,
  p_expected_version int
) returns wms.labor_activities
language plpgsql stable security definer
set search_path = wms, public
as $$
declare
  v_act wms.labor_activities%rowtype;
begin
  select * into v_act from wms.labor_activities where id = p_activity_id;
  if not found then
    raise exception 'INVALID: unknown labor activity %', p_activity_id;
  end if;
  if v_act.warehouse_id not in (select wms.current_warehouse_ids(v_act.tenant_id)) then
    raise exception 'FORBIDDEN: no warehouse scope for labor activity %', p_activity_id;
  end if;
  if not wms.has_role(v_act.tenant_id, 'INBOUND_OPERATOR', 'QUALITY_INSPECTOR',
                      'PROCESS_AGENT', 'WAREHOUSE_MANAGER', 'WMS_ADMIN') then
    raise exception 'FORBIDDEN: role cannot act on labor activities';
  end if;
  -- D2: the p_actor_id envelope field must be the caller (admins excepted)...
  if not wms._wms_labor_actor_ok(v_act.tenant_id, p_actor_id) then
    raise exception 'FORBIDDEN: actor_id must be the calling user (only WMS_ADMIN may record on behalf of another worker)';
  end if;
  -- ...and the activity being closed must belong to the caller (same excepts).
  if v_act.actor_id <> auth.uid() and not wms.has_role(v_act.tenant_id, 'WMS_ADMIN') then
    raise exception 'FORBIDDEN: labor activity % belongs to another worker', p_activity_id;
  end if;
  if p_expected_version is not null and v_act.version <> p_expected_version then
    raise exception 'CONFLICT: expected version % but found %', p_expected_version, v_act.version;
  end if;
  return v_act;
end;
$$;

-- ============================================================
-- Command RPCs (writes)
-- Envelope in:  tenant_id / warehouse_id (implied by the target row for
--               id-addressed calls), actor_id, idempotency_key,
--               expected_version, correlation_id.
-- Envelope out: {result, document_id, status, version, next_actions, warnings}.
-- Errors:       RAISE EXCEPTION with CONFLICT:/FORBIDDEN:/INVALID: prefix.
-- ============================================================

create or replace function wms.wms_start_labor_activity(
  p_tenant_id text,
  p_warehouse_id uuid,
  p_activity_type text,
  p_actor_id uuid,
  p_idempotency_key uuid,
  p_activity_label text default null,
  p_linked_entity_type text default null,
  p_linked_entity_id uuid default null,
  p_correlation_id text default null
) returns jsonb
language plpgsql security definer
set search_path = wms, public
as $$
declare
  v_cached jsonb;
  v_act wms.labor_activities%rowtype;
  v_role text;
begin
  if p_idempotency_key is not null then
    select response into v_cached from wms.idempotency_records
      where tenant_id = p_tenant_id and command_name = 'wms_start_labor_activity'
        and idempotency_key = p_idempotency_key;
    if found then return v_cached; end if;
  end if;

  if p_warehouse_id not in (select wms.current_warehouse_ids(p_tenant_id)) then
    raise exception 'FORBIDDEN: no warehouse scope for %', p_warehouse_id;
  end if;
  -- V2: WAREHOUSE_MANAGER included; see the header.
  if not wms.has_role(p_tenant_id, 'INBOUND_OPERATOR', 'QUALITY_INSPECTOR',
                      'PROCESS_AGENT', 'WAREHOUSE_MANAGER', 'WMS_ADMIN') then
    raise exception 'FORBIDDEN: role cannot record labor activities';
  end if;
  -- D2
  if not wms._wms_labor_actor_ok(p_tenant_id, p_actor_id) then
    raise exception 'FORBIDDEN: actor_id must be the calling user (only WMS_ADMIN may record on behalf of another worker)';
  end if;

  if p_activity_type is null
     or p_activity_type not in ('RECEIVING', 'QUALITY_INSPECTION', 'PUTAWAY', 'DISPOSITION', 'OTHER') then
    raise exception 'INVALID: activity_type must be one of RECEIVING, QUALITY_INSPECTION, PUTAWAY, DISPOSITION, OTHER';
  end if;
  -- D5
  if p_activity_type = 'OTHER' and (p_activity_label is null or btrim(p_activity_label) = '') then
    raise exception 'INVALID: activity_label is required when activity_type is OTHER';
  end if;
  if (p_linked_entity_type is null) <> (p_linked_entity_id is null) then
    raise exception 'INVALID: linked_entity_type and linked_entity_id must be given together';
  end if;

  -- The role snapshot comes from the ATTRIBUTED worker, not the caller, so an
  -- admin proxy-recording for an inspector produces actor_role =
  -- QUALITY_INSPECTOR rather than WMS_ADMIN.
  select role into v_role
  from wms.memberships where user_id = p_actor_id and tenant_id = p_tenant_id;
  if v_role is null then
    raise exception 'INVALID: actor % is not a member of tenant %', p_actor_id, p_tenant_id;
  end if;

  insert into wms.labor_activities (
    tenant_id, warehouse_id, actor_id, actor_role, activity_type, activity_label,
    linked_entity_type, linked_entity_id, status, started_at,
    correlation_id, created_by, updated_by
  ) values (
    p_tenant_id, p_warehouse_id, p_actor_id, v_role, p_activity_type, p_activity_label,
    p_linked_entity_type, p_linked_entity_id, 'IN_PROGRESS', now(),
    p_correlation_id, auth.uid(), auth.uid()
  )
  returning * into v_act;

  insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, before, after, correlation_id)
  values (p_tenant_id, p_actor_id, 'wms_start_labor_activity', 'labor_activity', v_act.id,
          null, to_jsonb(v_act), p_correlation_id);

  v_cached := jsonb_build_object(
    'result', 'ok',
    'document_id', v_act.id,
    'activity_id', v_act.id,
    'actor_id', v_act.actor_id,
    'actor_role', v_act.actor_role,
    'activity_type', v_act.activity_type,
    'activity_label', v_act.activity_label,
    'started_at', v_act.started_at,
    'status', v_act.status,
    'version', v_act.version,
    'warnings', '[]'::jsonb,
    'next_actions', jsonb_build_array('complete_labor_activity', 'cancel_labor_activity')
  );
  if p_idempotency_key is not null then
    insert into wms.idempotency_records (tenant_id, command_name, idempotency_key, response)
    values (p_tenant_id, 'wms_start_labor_activity', p_idempotency_key, v_cached)
    on conflict do nothing;
  end if;
  return v_cached;
end;
$$;

create or replace function wms.wms_complete_labor_activity(
  p_activity_id uuid,
  p_actor_id uuid,
  p_idempotency_key uuid,
  p_expected_version int,
  p_unit_count numeric default null,
  p_correlation_id text default null
) returns jsonb
language plpgsql security definer
set search_path = wms, public
as $$
declare
  v_cached jsonb;
  v_act wms.labor_activities%rowtype;
  v_before jsonb;
  v_tenant_id text;
begin
  select tenant_id into v_tenant_id from wms.labor_activities where id = p_activity_id;
  if p_idempotency_key is not null and v_tenant_id is not null then
    select response into v_cached from wms.idempotency_records
      where tenant_id = v_tenant_id and command_name = 'wms_complete_labor_activity'
        and idempotency_key = p_idempotency_key;
    if found then return v_cached; end if;
  end if;

  v_act := wms._wms_load_labor_activity(p_activity_id, p_actor_id, p_expected_version);

  if v_act.status <> 'IN_PROGRESS' then
    raise exception 'INVALID: labor activity % is not IN_PROGRESS (status=%)', p_activity_id, v_act.status;
  end if;
  if p_unit_count is not null and p_unit_count < 0 then
    raise exception 'INVALID: unit_count must not be negative';
  end if;

  v_before := to_jsonb(v_act);

  -- duration_seconds is a generated column — it falls out of completed_at.
  update wms.labor_activities
  set status = 'COMPLETED',
      completed_at = now(),
      unit_count = coalesce(p_unit_count, unit_count),
      version = version + 1,
      updated_by = auth.uid(),
      updated_at = now(),
      correlation_id = coalesce(p_correlation_id, correlation_id)
  where id = p_activity_id
  returning * into v_act;

  insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, before, after, correlation_id)
  values (v_act.tenant_id, p_actor_id, 'wms_complete_labor_activity', 'labor_activity', v_act.id,
          v_before, to_jsonb(v_act), p_correlation_id);

  v_cached := jsonb_build_object(
    'result', 'ok',
    'document_id', v_act.id,
    'activity_id', v_act.id,
    'actor_id', v_act.actor_id,
    'actor_role', v_act.actor_role,
    'activity_type', v_act.activity_type,
    'started_at', v_act.started_at,
    'completed_at', v_act.completed_at,
    'duration_seconds', v_act.duration_seconds,
    'unit_count', v_act.unit_count,
    'status', v_act.status,
    'version', v_act.version,
    'warnings', case when v_act.unit_count is null
      then jsonb_build_array('NO_UNIT_COUNT_RECORDED')
      else '[]'::jsonb end,
    'next_actions', jsonb_build_array('start_labor_activity', 'get_labor_productivity')
  );
  if p_idempotency_key is not null then
    insert into wms.idempotency_records (tenant_id, command_name, idempotency_key, response)
    values (v_act.tenant_id, 'wms_complete_labor_activity', p_idempotency_key, v_cached)
    on conflict do nothing;
  end if;
  return v_cached;
end;
$$;

create or replace function wms.wms_cancel_labor_activity(
  p_activity_id uuid,
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
  v_act wms.labor_activities%rowtype;
  v_before jsonb;
  v_tenant_id text;
begin
  select tenant_id into v_tenant_id from wms.labor_activities where id = p_activity_id;
  if p_idempotency_key is not null and v_tenant_id is not null then
    select response into v_cached from wms.idempotency_records
      where tenant_id = v_tenant_id and command_name = 'wms_cancel_labor_activity'
        and idempotency_key = p_idempotency_key;
    if found then return v_cached; end if;
  end if;

  v_act := wms._wms_load_labor_activity(p_activity_id, p_actor_id, p_expected_version);

  if v_act.status <> 'IN_PROGRESS' then
    raise exception 'INVALID: labor activity % is not IN_PROGRESS (status=%)', p_activity_id, v_act.status;
  end if;

  v_before := to_jsonb(v_act);

  update wms.labor_activities
  set status = 'CANCELLED',
      completed_at = now(),
      reason = p_reason,
      version = version + 1,
      updated_by = auth.uid(),
      updated_at = now(),
      correlation_id = coalesce(p_correlation_id, correlation_id)
  where id = p_activity_id
  returning * into v_act;

  insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, before, after, correlation_id)
  values (v_act.tenant_id, p_actor_id, 'wms_cancel_labor_activity', 'labor_activity', v_act.id,
          v_before, to_jsonb(v_act), p_correlation_id);

  v_cached := jsonb_build_object(
    'result', 'ok',
    'document_id', v_act.id,
    'activity_id', v_act.id,
    'actor_id', v_act.actor_id,
    'status', v_act.status,
    'version', v_act.version,
    'reason', v_act.reason,
    -- spec.md: a cancelled activity is invisible to every productivity number.
    'warnings', jsonb_build_array('EXCLUDED_FROM_PRODUCTIVITY'),
    'next_actions', jsonb_build_array('start_labor_activity')
  );
  if p_idempotency_key is not null then
    insert into wms.idempotency_records (tenant_id, command_name, idempotency_key, response)
    values (v_act.tenant_id, 'wms_cancel_labor_activity', p_idempotency_key, v_cached)
    on conflict do nothing;
  end if;
  return v_cached;
end;
$$;

-- ============================================================
-- Query RPCs (reads)
--
-- All three are `stable security definer`, which means RLS on
-- wms.labor_activities does NOT apply inside them. The privacy predicate is
-- therefore restated by hand below (D3b) — deleting either copy would open a
-- hole, which is exactly why design.md asked for both.
-- ============================================================

create or replace function wms.wms_get_labor_productivity(
  p_tenant_id text,
  p_warehouse_id uuid,
  p_period_start timestamptz,
  p_period_end timestamptz,
  p_actor_id uuid default null,
  p_role text default null
) returns jsonb
language plpgsql stable security definer
set search_path = wms, public
as $$
declare
  v_is_manager boolean;
  v_scope text;
  v_actor_filter uuid;
  v_rows jsonb;
  v_totals jsonb;
begin
  if p_warehouse_id not in (select wms.current_warehouse_ids(p_tenant_id)) then
    raise exception 'FORBIDDEN: no warehouse scope for %', p_warehouse_id;
  end if;
  if p_period_start is null or p_period_end is null then
    raise exception 'INVALID: period_start and period_end are required';
  end if;
  if p_period_end <= p_period_start then
    raise exception 'INVALID: period_end must be after period_start';
  end if;

  v_is_manager := wms.has_role(p_tenant_id, 'WAREHOUSE_MANAGER', 'WMS_ADMIN');
  -- D3b. A non-manager's p_actor_id is not rejected, it is overwritten.
  if v_is_manager then
    v_scope := 'WAREHOUSE';
    v_actor_filter := p_actor_id;
  else
    v_scope := 'SELF';
    v_actor_filter := auth.uid();
  end if;

  select coalesce(jsonb_agg(item order by
           item->>'activity_date' desc, item->>'actor_email', item->>'activity_type'), '[]'::jsonb)
  into v_rows
  from (
    select jsonb_build_object(
      'actor_id', la.actor_id,
      'actor_email', u.email,
      'actor_role', la.actor_role,
      'activity_date', (la.completed_at)::date,
      'activity_type', la.activity_type,
      'completed_count', count(*),
      'avg_duration_seconds', round(avg(la.duration_seconds), 1),
      'total_duration_seconds', sum(la.duration_seconds),
      'total_unit_count', coalesce(sum(la.unit_count), 0)
    ) as item
    from wms.labor_activities la
    join auth.users u on u.id = la.actor_id
    where la.tenant_id = p_tenant_id
      and la.warehouse_id = p_warehouse_id
      -- cancelled and still-running activities never reach an aggregate
      and la.status = 'COMPLETED'
      and la.completed_at >= p_period_start
      and la.completed_at < p_period_end
      and (v_actor_filter is null or la.actor_id = v_actor_filter)
      and (p_role is null or la.actor_role = p_role)
    group by la.actor_id, u.email, la.actor_role, (la.completed_at)::date, la.activity_type
  ) rows;

  select jsonb_build_object(
    'completed_count', coalesce(count(*), 0),
    'avg_duration_seconds', round(avg(la.duration_seconds), 1),
    'total_duration_seconds', coalesce(sum(la.duration_seconds), 0),
    'total_unit_count', coalesce(sum(la.unit_count), 0),
    'distinct_actor_count', count(distinct la.actor_id)
  )
  into v_totals
  from wms.labor_activities la
  where la.tenant_id = p_tenant_id
    and la.warehouse_id = p_warehouse_id
    and la.status = 'COMPLETED'
    and la.completed_at >= p_period_start
    and la.completed_at < p_period_end
    and (v_actor_filter is null or la.actor_id = v_actor_filter)
    and (p_role is null or la.actor_role = p_role);

  return jsonb_build_object(
    'result', 'ok',
    'tenant_id', p_tenant_id,
    'warehouse_id', p_warehouse_id,
    'period_start', p_period_start,
    'period_end', p_period_end,
    'scope', v_scope,
    'rows', v_rows,
    'row_count', jsonb_array_length(v_rows),
    'totals', v_totals,
    'notes', case when v_scope = 'SELF'
      then jsonb_build_array('SELF_SCOPE_ONLY')
      else '[]'::jsonb end
  );
end;
$$;

create or replace function wms.wms_get_labor_leaderboard(
  p_tenant_id text,
  p_warehouse_id uuid,
  p_period_start timestamptz,
  p_period_end timestamptz,
  p_metric text default 'completed_count'
) returns jsonb
language plpgsql stable security definer
set search_path = wms, public
as $$
declare
  v_is_manager boolean;
  v_scope text;
  v_actor_filter uuid;
  v_metric text := coalesce(p_metric, 'completed_count');
  v_rows jsonb;
begin
  if p_warehouse_id not in (select wms.current_warehouse_ids(p_tenant_id)) then
    raise exception 'FORBIDDEN: no warehouse scope for %', p_warehouse_id;
  end if;
  if p_period_start is null or p_period_end is null then
    raise exception 'INVALID: period_start and period_end are required';
  end if;
  if p_period_end <= p_period_start then
    raise exception 'INVALID: period_end must be after period_start';
  end if;
  if v_metric not in ('completed_count', 'total_unit_count', 'avg_duration_seconds') then
    raise exception 'INVALID: metric must be completed_count, total_unit_count or avg_duration_seconds';
  end if;

  v_is_manager := wms.has_role(p_tenant_id, 'WAREHOUSE_MANAGER', 'WMS_ADMIN');
  -- D3b + V3: a worker gets their own row, silently, with no rank.
  if v_is_manager then
    v_scope := 'WAREHOUSE';
    v_actor_filter := null;
  else
    v_scope := 'SELF';
    v_actor_filter := auth.uid();
  end if;

  with agg as (
    select
      la.actor_id,
      u.email as actor_email,
      la.actor_role,
      count(*) as completed_count,
      coalesce(sum(la.unit_count), 0) as total_unit_count,
      round(avg(la.duration_seconds), 1) as avg_duration_seconds,
      sum(la.duration_seconds) as total_duration_seconds
    from wms.labor_activities la
    join auth.users u on u.id = la.actor_id
    where la.tenant_id = p_tenant_id
      and la.warehouse_id = p_warehouse_id
      and la.status = 'COMPLETED'
      and la.completed_at >= p_period_start
      and la.completed_at < p_period_end
      and (v_actor_filter is null or la.actor_id = v_actor_filter)
    group by la.actor_id, u.email, la.actor_role
  ), ranked as (
    select agg.*,
      -- avg_duration is the one metric where lower is better.
      row_number() over (
        order by
          case when v_metric = 'completed_count' then completed_count end desc nulls last,
          case when v_metric = 'total_unit_count' then total_unit_count end desc nulls last,
          case when v_metric = 'avg_duration_seconds' then avg_duration_seconds end asc nulls last,
          actor_email
      ) as position
    from agg
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'rank', case when v_scope = 'SELF' then null else position end,
    'actor_id', actor_id,
    'actor_email', actor_email,
    'actor_role', actor_role,
    'completed_count', completed_count,
    'total_unit_count', total_unit_count,
    'avg_duration_seconds', avg_duration_seconds,
    'total_duration_seconds', total_duration_seconds
  ) order by position), '[]'::jsonb)
  into v_rows
  from ranked;

  return jsonb_build_object(
    'result', 'ok',
    'tenant_id', p_tenant_id,
    'warehouse_id', p_warehouse_id,
    'period_start', p_period_start,
    'period_end', p_period_end,
    'metric', v_metric,
    'scope', v_scope,
    'rows', v_rows,
    'row_count', jsonb_array_length(v_rows),
    'notes', case when v_scope = 'SELF'
      then jsonb_build_array('SELF_SCOPE_ONLY', 'SELF_SCOPE_RANK_WITHHELD')
      else '[]'::jsonb end
  );
end;
$$;

-- Simple ratio arithmetic, NOT a forecast model. The response says so in a
-- machine-readable field (`method`) so no consumer can mistake it for one.
create or replace function wms.wms_forecast_labor_demand(
  p_tenant_id text,
  p_warehouse_id uuid,
  p_role text,
  p_expected_volume numeric,
  p_trailing_days int default 7,
  p_shift_hours numeric default 8
) returns jsonb
language plpgsql stable security definer
set search_path = wms, public
as $$
declare
  v_from timestamptz;
  v_sample_count int;
  v_total_units numeric;
  v_total_seconds numeric;
  v_units_per_hour numeric;
  v_units_per_person_per_shift numeric;
  v_headcount int;
begin
  if p_warehouse_id not in (select wms.current_warehouse_ids(p_tenant_id)) then
    raise exception 'FORBIDDEN: no warehouse scope for %', p_warehouse_id;
  end if;
  -- D4: planning information, managers only. A worker has no business asking
  -- "how many of us are needed tomorrow".
  if not wms.has_role(p_tenant_id, 'WAREHOUSE_MANAGER', 'WMS_ADMIN') then
    raise exception 'FORBIDDEN: role cannot forecast labor demand';
  end if;
  if p_role is null or btrim(p_role) = '' then
    raise exception 'INVALID: role is required';
  end if;
  if p_expected_volume is null or p_expected_volume <= 0 then
    raise exception 'INVALID: expected_volume must be positive';
  end if;
  if p_trailing_days is null or p_trailing_days <= 0 then
    raise exception 'INVALID: trailing_days must be positive';
  end if;
  if p_shift_hours is null or p_shift_hours <= 0 then
    raise exception 'INVALID: shift_hours must be positive';
  end if;

  v_from := now() - make_interval(days => p_trailing_days);

  select count(*), coalesce(sum(la.unit_count), 0), coalesce(sum(la.duration_seconds), 0)
  into v_sample_count, v_total_units, v_total_seconds
  from wms.labor_activities la
  where la.tenant_id = p_tenant_id
    and la.warehouse_id = p_warehouse_id
    and la.actor_role = p_role
    and la.status = 'COMPLETED'
    and la.completed_at >= v_from;

  -- spec.md: no sample -> no number. Never divide by zero, never invent one.
  if v_sample_count = 0 then
    raise exception 'INVALID: no completed % activities in the trailing % days — cannot estimate headcount', p_role, p_trailing_days;
  end if;
  if v_total_seconds <= 0 then
    raise exception 'INVALID: trailing % activities for % have no measurable duration — cannot estimate headcount', v_sample_count, p_role;
  end if;
  -- V4: throughput is measured in units, so unit_count must have been recorded.
  if v_total_units <= 0 then
    raise exception 'INVALID: trailing % activities for % recorded no unit_count — cannot estimate headcount', v_sample_count, p_role;
  end if;

  v_units_per_hour := v_total_units / (v_total_seconds / 3600.0);
  v_units_per_person_per_shift := v_units_per_hour * p_shift_hours;
  v_headcount := ceil(p_expected_volume / v_units_per_person_per_shift)::int;

  return jsonb_build_object(
    'result', 'ok',
    'tenant_id', p_tenant_id,
    'warehouse_id', p_warehouse_id,
    'role', p_role,
    'expected_volume', p_expected_volume,
    'recommended_headcount', v_headcount,
    'basis', jsonb_build_object(
      'trailing_days', p_trailing_days,
      'trailing_from', v_from,
      'sample_count', v_sample_count,
      'total_unit_count', v_total_units,
      'total_duration_seconds', v_total_seconds,
      'avg_units_per_hour', round(v_units_per_hour, 2),
      'shift_hours', p_shift_hours,
      'units_per_person_per_shift', round(v_units_per_person_per_shift, 2)
    ),
    -- spec.md MUST: say out loud that this is arithmetic, not ML.
    'method', 'SIMPLE_RATIO',
    'method_note', '트레일링 평균 처리량 ÷ 예상 물량의 단순 비율 계산입니다. 계절성·추세·이상치를 보정하는 머신러닝 예측이 아닙니다.',
    'warnings', case when v_sample_count < 3
      then jsonb_build_array('SMALL_SAMPLE')
      else '[]'::jsonb end
  );
end;
$$;

grant execute on function wms.wms_start_labor_activity(text, uuid, text, uuid, uuid, text, text, uuid, text) to authenticated;
grant execute on function wms.wms_complete_labor_activity(uuid, uuid, uuid, int, numeric, text) to authenticated;
grant execute on function wms.wms_cancel_labor_activity(uuid, uuid, uuid, int, text, text) to authenticated;
grant execute on function wms.wms_get_labor_productivity(text, uuid, timestamptz, timestamptz, uuid, text) to authenticated;
grant execute on function wms.wms_get_labor_leaderboard(text, uuid, timestamptz, timestamptz, text) to authenticated;
grant execute on function wms.wms_forecast_labor_demand(text, uuid, text, numeric, int, numeric) to authenticated;

-- _wms_labor_actor_ok and _wms_load_labor_activity are internal helpers:
-- no grant, exactly like wms._wms_finalize_disposition in the core schema.
