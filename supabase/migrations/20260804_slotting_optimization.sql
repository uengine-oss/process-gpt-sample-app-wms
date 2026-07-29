-- ============================================================
-- Slotting optimization contract
-- Scope: openspec/changes/add-slotting-optimization
--        (proposal.md / design.md / specs/wms_slotting-optimization/spec.md)
--
-- The ninth area. Like areas 7 (yard/dock) and 8 (labor) it is NOT part of the
-- WCS/WES chain — it references no equipment, no command, no dock, no wave, no
-- outbound order. It adds five tables:
--
--   * wms.storage_locations        — a FLAT registry of storage locations with
--                                    an operator-assigned accessibility_rank.
--                                    Not a hierarchy, not a bin model.
--   * wms.sku_location_assignments — "operator declares SKU X currently sits at
--                                    location Y". One active row per SKU per
--                                    warehouse (D1).
--   * wms.slotting_class_policies  — per-warehouse "an A-class SKU belongs at
--                                    accessibility_rank <= N" (D2).
--   * wms.sku_velocity_snapshots   — ABC classification of consumption velocity
--                                    over a caller-chosen window (D3/D4).
--   * wms.slotting_recommendations — PENDING -> APPROVED/REJECTED -> APPLIED,
--                                    human-in-the-loop (D5/D6/D7).
--
-- and ten RPCs on top of them.
--
-- Conventions (schema, common columns, RLS helpers, RPC envelope,
-- CONFLICT:/FORBIDDEN:/INVALID: prefixes, idempotency records, audit events)
-- are identical to the nine migrations before it, and none of those files is
-- modified here.
--
-- ORDERING / DEPENDENCIES: this migration requires only
--   20260726_wms_core_schema.sql  (wms.tenants, wms.warehouses, wms.products,
--                                  wms.stock_ledger_entries, wms.memberships,
--                                  wms.idempotency_records, wms.audit_events,
--                                  wms.has_role, wms.current_warehouse_ids)
-- It has NO dependency on areas 1-8. In particular it does NOT read
-- wms.outbound_orders (area 5) — see the honest-premise note below.
--
-- ============================================================
-- THE HONEST PREMISE, RE-VERIFIED AGAINST THE IMPLEMENTED CODE
-- ============================================================
--
-- design.md was written when areas 5-8 were still unimplemented, and it
-- predicted that "no RPC in this repository ever decrements AVAILABLE stock".
-- That prediction was re-checked against the migrations as they now actually
-- exist (20260727 .. 20260803, all applied), not against their design docs:
--
--     $ grep -n 'stock_ledger_entries' supabase/migrations/*.sql \
--         | grep -v 20260726
--     20260727_wcs_equipment_control.sql:25:  -- (a comment, nothing else)
--
-- i.e. 20260726_wms_core_schema.sql is STILL the only migration in this
-- repository that writes wms.stock_ledger_entries at all, and every qty_delta
-- it writes is either positive or the same-transaction offset of a positive
-- one:
--
--   | RPC                            | status              | sign            |
--   |--------------------------------|---------------------|-----------------|
--   | wms_receive                    | 'QC'                | +p_qty          |
--   | _wms_finalize_disposition      | 'QC'                | -received_qty   |
--   | _wms_finalize_disposition      | 'AVAILABLE'/'SCRAP' | +received_qty   |
--
-- Area 5 (20260731) DID land wms.outbound_orders for real, and it does drive
-- an order all the way to status='COMPLETED' — but it writes no ledger row on
-- any path, exactly as its own design.md Non-Goals promised. Area 6's
-- simulation is projection-only and touches no ledger either. So the gap
-- design.md described is still real today: there is NO code path in this
-- repository that produces a negative AVAILABLE qty_delta.
--
-- This contract does not paper over that. wms_compute_sku_velocity reads
-- precisely `status = 'AVAILABLE' and qty_delta < 0`, which today matches
-- nothing, and:
--
--   * SKUs with no signal in the window get NO snapshot and NO class. They are
--     counted in `skipped_no_data_count` so a caller cannot mistake an empty
--     result for "everything is low priority".
--   * The moment a future outbound-fulfilment RPC starts writing that row
--     shape, this contract begins producing real signal with no change at all.
--
-- Verification therefore seeds synthetic negative-AVAILABLE ledger rows as
-- superuser (openspec/specs/wms_slotting-optimization/e2e/verify.sql §C and
-- frontend/playwright/e2e/slotting-flow.spec.ts) to exercise the ABC maths.
-- Those rows stand in for a feature that does not exist yet, and both scripts
-- say so at the point of insert.
--
-- ------------------------------------------------------------
-- DEVIATIONS from design.md, deliberate and small:
--
-- V1. PARAMETER ORDER. design.md's RPC table lists
--       wms_register_storage_location(..., p_capacity_qty default null,
--                                     p_actor_id, p_idempotency_key, ...)
--     which PostgreSQL rejects — a parameter without a default may not follow
--     one that has a default. p_capacity_qty is therefore moved after
--     p_idempotency_key. The SET of parameters and their names/types/defaults
--     is exactly as designed, and every caller in this repository (supabase-js,
--     MCP) passes them by name, so the order is not observable. Same fix as
--     20260803_labor_management.sql V1 and 20260802 before it. No other
--     signature in the table needed reordering.
--
-- V2. THE CANDIDATE UNIVERSE FOR skipped_no_data_count IS THE TENANT'S
--     PRODUCTS. spec.md says the count equals "창고에 등록된 대상 제품 수",
--     but wms.products is tenant-scoped in this repository — there is no
--     product-per-warehouse registry to enumerate (checked: wms.products has
--     tenant_id and no warehouse_id, and no join table exists). The universe
--     is therefore every product of the tenant, and the response returns it
--     explicitly as `candidate_product_count` so the arithmetic
--     (candidate = included + skipped) is auditable rather than implied.
--
-- V3. TARGET-LOCATION CHOICE IS RANKED, NOT ARBITRARY. design.md says the
--     recommended location is "상한을 만족하는 ACTIVE 위치 중 하나". Picking
--     literally any one of them would let a single batch recommend the same
--     door to eight SKUs, which is not actionable. The pick is ordered:
--       (1) locations nobody is assigned to, before occupied ones;
--       (2) locations not already the target of an open recommendation,
--           before ones that are — which also de-duplicates within one batch,
--           since rows are inserted as the loop runs;
--       (3) best accessibility_rank, then location_code, for determinism.
--     It is a preference, not a filter: if every qualifying location is
--     occupied and spoken for, one is still recommended rather than silently
--     dropping the SKU. Capacity is NOT consulted (Non-Goals) — capacity_qty
--     remains a reference number with no engine behind it.
--
-- V4. A SKU WITH AN OPEN RECOMMENDATION IS NOT RECOMMENDED AGAIN. Generation
--     is re-runnable by design (D3: tune the policy, regenerate off the same
--     snapshot batch), so without this a second run would pile a duplicate
--     PENDING row onto every SKU. Such SKUs are counted in
--     `skipped_open_recommendation_count`. Idempotency records already cover
--     the retry-the-identical-call case; this covers the deliberate re-run.
--
-- V5. ABC BOUNDARIES ARE INCLUSIVE AND COMPUTED IN EXACT INTEGER ARITHMETIC.
--     D4 fixes the cutoffs at 80/95. A SKU whose cumulative share lands
--     EXACTLY on 80% is A (and exactly 95% is B) — that is what spec.md's
--     worked scenario asks for. The comparison is written as
--     `cum_qty * 100 <= total_qty * 80` rather than dividing, so a share that
--     is exactly 80% cannot miss the boundary through a rounding artefact.
-- ============================================================

-- ------------------------------------------------------------
-- Tables
-- ------------------------------------------------------------

-- A FLAT registry. zone_code is a free-text label, not a level in a hierarchy;
-- accessibility_rank is a number an operator assigns by judgement, not one the
-- system derives from a floor plan (Non-Goals, and Risks: a wrong rank yields
-- a wrong recommendation and nothing here can tell).
create table wms.storage_locations (
  id uuid primary key default gen_random_uuid(),
  tenant_id text not null references wms.tenants(id) on delete cascade,
  warehouse_id uuid not null references wms.warehouses(id) on delete cascade,
  zone_code text not null,
  location_code text not null,
  -- lower is better: rank 1 is next to packing, rank 40 is the far corner.
  accessibility_rank int not null check (accessibility_rank > 0),
  -- reference only. There is no capacity engine (Non-Goals) and nothing in
  -- this migration reads this column.
  capacity_qty numeric check (capacity_qty is null or capacity_qty >= 0),
  status text not null default 'ACTIVE'
    check (status in ('ACTIVE', 'INACTIVE')),
  version int not null default 1,
  correlation_id text,
  created_by uuid,
  updated_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint storage_locations_code_uq unique (warehouse_id, location_code),
  constraint storage_locations_zone_code_ck check (btrim(zone_code) <> ''),
  constraint storage_locations_location_code_ck check (btrim(location_code) <> '')
);

create index storage_locations_warehouse_rank_idx
  on wms.storage_locations (warehouse_id, accessibility_rank)
  where status = 'ACTIVE';

-- D2. Per-warehouse, because accessibility_rank has no absolute meaning: a
-- five-location warehouse and a five-hundred-location warehouse cannot share a
-- threshold. A (warehouse, class) with no row here is skipped by generation
-- rather than defaulted — inventing a default would manufacture false
-- recommendations.
create table wms.slotting_class_policies (
  id uuid primary key default gen_random_uuid(),
  tenant_id text not null references wms.tenants(id) on delete cascade,
  warehouse_id uuid not null references wms.warehouses(id) on delete cascade,
  velocity_class text not null check (velocity_class in ('A', 'B', 'C')),
  max_accessibility_rank int not null check (max_accessibility_rank > 0),
  version int not null default 1,
  correlation_id text,
  created_by uuid,
  updated_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint slotting_class_policies_uq unique (warehouse_id, velocity_class)
);

-- D3/D4. A fresh batch every call, no cache, no incremental refresh: the row
-- count is bounded by SKUs-per-warehouse, and keeping every batch means "which
-- window produced this grade, and when" is auditable forever.
--
-- A SKU with outbound_event_count = 0 gets NO ROW HERE. That is the single
-- most important line in this file: the absence of a row is the contract's way
-- of saying "we do not know", and skipped_no_data_count is how the caller
-- learns how often that happened.
create table wms.sku_velocity_snapshots (
  id uuid primary key default gen_random_uuid(),
  tenant_id text not null references wms.tenants(id) on delete cascade,
  warehouse_id uuid not null references wms.warehouses(id) on delete cascade,
  product_id uuid not null references wms.products(id) on delete cascade,
  window_start date not null,
  window_end date not null,
  outbound_qty numeric not null check (outbound_qty > 0),
  outbound_event_count int not null check (outbound_event_count > 0),
  velocity_class text not null check (velocity_class in ('A', 'B', 'C')),
  -- ties every snapshot of one wms_compute_sku_velocity call together; this is
  -- what wms_generate_slotting_recommendations is handed.
  batch_id uuid not null,
  computed_at timestamptz not null default now(),
  computed_by uuid,
  correlation_id text,
  constraint sku_velocity_snapshots_window_ck check (window_start < window_end),
  constraint sku_velocity_snapshots_batch_product_uq unique (batch_id, product_id)
);

create index sku_velocity_snapshots_batch_idx
  on wms.sku_velocity_snapshots (batch_id);
create index sku_velocity_snapshots_warehouse_computed_idx
  on wms.sku_velocity_snapshots (warehouse_id, computed_at desc);

-- D5/D6/D7. The HITL object. Nothing here moves stock; APPLIED means "the
-- assignment record was updated", not "a forklift went somewhere"
-- (Non-Goals — the same scope reduction wms_create_putaway_tasks already made).
create table wms.slotting_recommendations (
  id uuid primary key default gen_random_uuid(),
  tenant_id text not null references wms.tenants(id) on delete cascade,
  warehouse_id uuid not null references wms.warehouses(id) on delete cascade,
  product_id uuid not null references wms.products(id) on delete cascade,
  velocity_snapshot_id uuid not null references wms.sku_velocity_snapshots(id) on delete cascade,
  -- D5: null is a legitimate value, not missing data. It means "this SKU is
  -- physically somewhere in the warehouse but nobody has ever declared where",
  -- which is precisely the SKU slotting should reach first.
  current_location_id uuid references wms.storage_locations(id) on delete set null,
  recommended_location_id uuid not null references wms.storage_locations(id) on delete cascade,
  reason_code text not null
    check (reason_code in ('RELOCATE_UNDERSERVED', 'UNASSIGNED_HIGH_VELOCITY')),
  status text not null default 'PENDING'
    check (status in ('PENDING', 'APPROVED', 'REJECTED', 'APPLIED', 'EXPIRED')),
  reviewed_by uuid,
  reviewed_at timestamptz,
  review_reason text,
  applied_at timestamptz,
  version int not null default 1,
  correlation_id text,
  created_by uuid,
  created_at timestamptz not null default now(),
  constraint slotting_recommendations_not_self_ck
    check (current_location_id is null or current_location_id <> recommended_location_id),
  -- D5 again, as a constraint: the reason code and the presence of a current
  -- location are two views of the same fact and may not disagree.
  constraint slotting_recommendations_reason_ck
    check ((reason_code = 'UNASSIGNED_HIGH_VELOCITY') = (current_location_id is null)),
  constraint slotting_recommendations_reviewed_ck
    check (status in ('PENDING', 'EXPIRED') or reviewed_at is not null),
  constraint slotting_recommendations_applied_ck
    check ((status = 'APPLIED') = (applied_at is not null))
);

create index slotting_recommendations_warehouse_status_idx
  on wms.slotting_recommendations (warehouse_id, status);
create index slotting_recommendations_open_product_idx
  on wms.slotting_recommendations (warehouse_id, product_id)
  where status in ('PENDING', 'APPROVED');
create index slotting_recommendations_snapshot_idx
  on wms.slotting_recommendations (velocity_snapshot_id);

-- D1. NOT derived from the ledger — the ledger has no location axis at all, so
-- "where is this SKU right now" is unanswerable by query and exists only as an
-- operator's declaration. State-holding (one live row per SKU) rather than
-- append-only, to match wms.purchase_orders / wms.receipts; the history of
-- previous placements lives in wms.audit_events, so no second history table.
--
-- Declared last because source_recommendation_id points at the table above.
create table wms.sku_location_assignments (
  id uuid primary key default gen_random_uuid(),
  tenant_id text not null references wms.tenants(id) on delete cascade,
  warehouse_id uuid not null references wms.warehouses(id) on delete cascade,
  product_id uuid not null references wms.products(id) on delete cascade,
  location_id uuid not null references wms.storage_locations(id) on delete cascade,
  assigned_reason text not null default 'MANUAL_DECLARATION'
    check (assigned_reason in ('MANUAL_DECLARATION', 'SLOTTING_RECOMMENDATION')),
  source_recommendation_id uuid references wms.slotting_recommendations(id) on delete set null,
  version int not null default 1,
  correlation_id text,
  created_by uuid,
  updated_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint sku_location_assignments_uq unique (warehouse_id, product_id)
);

create index sku_location_assignments_location_idx
  on wms.sku_location_assignments (location_id);

-- ------------------------------------------------------------
-- Read view
--
-- security_invoker so the caller's own RLS on the five base tables decides
-- what they see — the view adds no scope of its own (same pattern as area 4's
-- two views).
-- ------------------------------------------------------------

create view wms.slotting_recommendation_overview_v
with (security_invoker = true) as
select
  r.id                          as recommendation_id,
  r.tenant_id,
  r.warehouse_id,
  r.product_id,
  p.sku,
  p.name                        as product_name,
  r.velocity_snapshot_id,
  s.batch_id,
  s.velocity_class,
  s.outbound_qty,
  s.outbound_event_count,
  s.window_start,
  s.window_end,
  r.current_location_id,
  cl.location_code              as current_location_code,
  cl.zone_code                  as current_zone_code,
  cl.accessibility_rank         as current_accessibility_rank,
  r.recommended_location_id,
  rl.location_code              as recommended_location_code,
  rl.zone_code                  as recommended_zone_code,
  rl.accessibility_rank         as recommended_accessibility_rank,
  -- how much better the recommended slot is, in rank points. Null when the SKU
  -- had no declared location to improve on.
  case when cl.accessibility_rank is null then null
       else cl.accessibility_rank - rl.accessibility_rank end
                                as accessibility_gain,
  pol.max_accessibility_rank,
  r.reason_code,
  r.status,
  r.reviewed_by,
  r.reviewed_at,
  r.review_reason,
  r.applied_at,
  r.version,
  r.correlation_id,
  r.created_by,
  r.created_at
from wms.slotting_recommendations r
join wms.products p                on p.id = r.product_id
join wms.sku_velocity_snapshots s  on s.id = r.velocity_snapshot_id
join wms.storage_locations rl      on rl.id = r.recommended_location_id
left join wms.storage_locations cl on cl.id = r.current_location_id
left join wms.slotting_class_policies pol
       on pol.warehouse_id = r.warehouse_id and pol.velocity_class = s.velocity_class;

-- ============================================================
-- RLS. SELECT-only for warehouse members, identical to every other table in
-- this schema. Every write goes through the SECURITY DEFINER RPCs below; no
-- INSERT/UPDATE/DELETE policy exists, so RLS denies those by default.
-- ============================================================

alter table wms.storage_locations enable row level security;
create policy storage_locations_select on wms.storage_locations for select to authenticated
  using (warehouse_id in (select wms.current_warehouse_ids(tenant_id)));

alter table wms.sku_location_assignments enable row level security;
create policy sku_location_assignments_select on wms.sku_location_assignments for select to authenticated
  using (warehouse_id in (select wms.current_warehouse_ids(tenant_id)));

alter table wms.slotting_class_policies enable row level security;
create policy slotting_class_policies_select on wms.slotting_class_policies for select to authenticated
  using (warehouse_id in (select wms.current_warehouse_ids(tenant_id)));

alter table wms.sku_velocity_snapshots enable row level security;
create policy sku_velocity_snapshots_select on wms.sku_velocity_snapshots for select to authenticated
  using (warehouse_id in (select wms.current_warehouse_ids(tenant_id)));

alter table wms.slotting_recommendations enable row level security;
create policy slotting_recommendations_select on wms.slotting_recommendations for select to authenticated
  using (warehouse_id in (select wms.current_warehouse_ids(tenant_id)));

grant select on wms.storage_locations to authenticated;
grant select on wms.sku_location_assignments to authenticated;
grant select on wms.slotting_class_policies to authenticated;
grant select on wms.sku_velocity_snapshots to authenticated;
grant select on wms.slotting_recommendations to authenticated;
grant select on wms.slotting_recommendation_overview_v to authenticated;

-- ============================================================
-- Internal helpers (no grant — same as wms._wms_finalize_disposition)
-- ============================================================

-- Everything the two location-registry writers and the policy writers share:
-- warehouse scope plus the WMS_ADMIN/WAREHOUSE_MANAGER gate. Registry and
-- policy management is master-data work, so INBOUND_OPERATOR and PROCESS_AGENT
-- are out (same line wms.register_equipment and wms.register_dock drew).
create or replace function wms._wms_slotting_admin_guard(
  p_tenant_id text,
  p_warehouse_id uuid,
  p_what text
) returns void
language plpgsql stable security definer
set search_path = wms, public
as $$
begin
  if p_warehouse_id not in (select wms.current_warehouse_ids(p_tenant_id)) then
    raise exception 'FORBIDDEN: no warehouse scope for %', p_warehouse_id;
  end if;
  if not wms.has_role(p_tenant_id, 'WMS_ADMIN', 'WAREHOUSE_MANAGER') then
    raise exception 'FORBIDDEN: role cannot %', p_what;
  end if;
end;
$$;

-- Loads an ACTIVE location and checks it belongs to the warehouse in question.
-- spec.md: an INACTIVE location may never be the target of an assignment or a
-- recommendation.
create or replace function wms._wms_load_active_location(
  p_warehouse_id uuid,
  p_location_id uuid
) returns wms.storage_locations
language plpgsql stable security definer
set search_path = wms, public
as $$
declare
  v_loc wms.storage_locations%rowtype;
begin
  select * into v_loc from wms.storage_locations where id = p_location_id;
  if not found then
    raise exception 'INVALID: unknown storage location %', p_location_id;
  end if;
  if v_loc.warehouse_id <> p_warehouse_id then
    raise exception 'INVALID: storage location % belongs to another warehouse', p_location_id;
  end if;
  if v_loc.status <> 'ACTIVE' then
    raise exception 'INVALID: storage location % is INACTIVE', v_loc.location_code;
  end if;
  return v_loc;
end;
$$;

-- V3, in one place. Best qualifying ACTIVE location for a class cap, with the
-- current location (if any) excluded. Returns null when the warehouse has no
-- location at or below the cap at all — the caller decides what that means.
create or replace function wms._wms_pick_slotting_target(
  p_warehouse_id uuid,
  p_max_rank int,
  p_current_location_id uuid
) returns uuid
language sql stable security definer
set search_path = wms, public
as $$
  select l.id
  from wms.storage_locations l
  where l.warehouse_id = p_warehouse_id
    and l.status = 'ACTIVE'
    and l.accessibility_rank <= p_max_rank
    and (p_current_location_id is null or l.id <> p_current_location_id)
  order by
    -- (1) empty shelves first...
    (exists (select 1 from wms.sku_location_assignments a where a.location_id = l.id)),
    -- (2) ...then ones nobody else has already been pointed at. Rows inserted
    --     earlier in the same generation loop are visible here, so this also
    --     spreads one batch across distinct targets.
    (exists (select 1 from wms.slotting_recommendations r
              where r.recommended_location_id = l.id
                and r.status in ('PENDING', 'APPROVED'))),
    -- (3) ...then the best slot, deterministically.
    l.accessibility_rank,
    l.location_code
  limit 1;
$$;

-- ============================================================
-- Command RPCs (writes)
-- Envelope in:  tenant_id / warehouse_id (implied by the target row for
--               id-addressed calls), actor_id, idempotency_key,
--               expected_version, correlation_id.
-- Envelope out: {result, document_id, status, version, next_actions, warnings}.
-- Errors:       RAISE EXCEPTION with CONFLICT:/FORBIDDEN:/INVALID: prefix.
-- ============================================================

-- V1: p_capacity_qty moved after p_idempotency_key so the required parameters
-- precede the optional ones. Names/types/defaults are as designed.
create or replace function wms.wms_register_storage_location(
  p_tenant_id text,
  p_warehouse_id uuid,
  p_zone_code text,
  p_location_code text,
  p_accessibility_rank int,
  p_actor_id uuid,
  p_idempotency_key uuid,
  p_capacity_qty numeric default null,
  p_correlation_id text default null
) returns jsonb
language plpgsql security definer
set search_path = wms, public
as $$
declare
  v_cached jsonb;
  v_loc wms.storage_locations%rowtype;
begin
  if p_idempotency_key is not null then
    select response into v_cached from wms.idempotency_records
      where tenant_id = p_tenant_id and command_name = 'wms_register_storage_location'
        and idempotency_key = p_idempotency_key;
    if found then return v_cached; end if;
  end if;

  perform wms._wms_slotting_admin_guard(p_tenant_id, p_warehouse_id, 'register storage locations');

  if p_zone_code is null or btrim(p_zone_code) = '' then
    raise exception 'INVALID: zone_code is required';
  end if;
  if p_location_code is null or btrim(p_location_code) = '' then
    raise exception 'INVALID: location_code is required';
  end if;
  if p_accessibility_rank is null or p_accessibility_rank <= 0 then
    raise exception 'INVALID: accessibility_rank must be a positive integer (lower is more accessible)';
  end if;
  if p_capacity_qty is not null and p_capacity_qty < 0 then
    raise exception 'INVALID: capacity_qty must not be negative';
  end if;
  if exists (select 1 from wms.storage_locations
              where warehouse_id = p_warehouse_id and location_code = btrim(p_location_code)) then
    raise exception 'INVALID: location_code % already exists in this warehouse', btrim(p_location_code);
  end if;

  insert into wms.storage_locations (
    tenant_id, warehouse_id, zone_code, location_code, accessibility_rank,
    capacity_qty, status, correlation_id, created_by, updated_by
  ) values (
    p_tenant_id, p_warehouse_id, btrim(p_zone_code), btrim(p_location_code), p_accessibility_rank,
    p_capacity_qty, 'ACTIVE', p_correlation_id, auth.uid(), auth.uid()
  )
  returning * into v_loc;

  insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, before, after, correlation_id)
  values (p_tenant_id, p_actor_id, 'wms_register_storage_location', 'storage_location', v_loc.id,
          null, to_jsonb(v_loc), p_correlation_id);

  v_cached := jsonb_build_object(
    'result', 'ok',
    'document_id', v_loc.id,
    'location_id', v_loc.id,
    'location_code', v_loc.location_code,
    'zone_code', v_loc.zone_code,
    'accessibility_rank', v_loc.accessibility_rank,
    'capacity_qty', v_loc.capacity_qty,
    'status', v_loc.status,
    'version', v_loc.version,
    -- Non-Goals, said out loud: capacity_qty is a note to humans.
    'warnings', case when v_loc.capacity_qty is not null
      then jsonb_build_array('CAPACITY_NOT_ENFORCED')
      else '[]'::jsonb end,
    'next_actions', jsonb_build_array('assign_sku_location', 'register_slotting_class_policy')
  );
  if p_idempotency_key is not null then
    insert into wms.idempotency_records (tenant_id, command_name, idempotency_key, response)
    values (p_tenant_id, 'wms_register_storage_location', p_idempotency_key, v_cached)
    on conflict do nothing;
  end if;
  return v_cached;
end;
$$;

create or replace function wms.wms_set_storage_location_status(
  p_location_id uuid,
  p_status text,
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
  v_loc wms.storage_locations%rowtype;
  v_before jsonb;
  v_tenant_id text;
  v_orphaned int;
begin
  select tenant_id into v_tenant_id from wms.storage_locations where id = p_location_id;
  if p_idempotency_key is not null and v_tenant_id is not null then
    select response into v_cached from wms.idempotency_records
      where tenant_id = v_tenant_id and command_name = 'wms_set_storage_location_status'
        and idempotency_key = p_idempotency_key;
    if found then return v_cached; end if;
  end if;

  select * into v_loc from wms.storage_locations where id = p_location_id;
  if not found then
    raise exception 'INVALID: unknown storage location %', p_location_id;
  end if;
  perform wms._wms_slotting_admin_guard(v_loc.tenant_id, v_loc.warehouse_id, 'change storage location status');

  if p_status is null or p_status not in ('ACTIVE', 'INACTIVE') then
    raise exception 'INVALID: status must be ACTIVE or INACTIVE';
  end if;
  if p_expected_version is not null and v_loc.version <> p_expected_version then
    raise exception 'CONFLICT: expected version % but found %', p_expected_version, v_loc.version;
  end if;
  if v_loc.status = p_status then
    raise exception 'INVALID: storage location % is already %', v_loc.location_code, p_status;
  end if;

  v_before := to_jsonb(v_loc);

  update wms.storage_locations
  set status = p_status,
      version = version + 1,
      updated_by = auth.uid(),
      updated_at = now(),
      correlation_id = coalesce(p_correlation_id, correlation_id)
  where id = p_location_id
  returning * into v_loc;

  -- Deactivating does NOT evict whoever is standing there. The declaration
  -- records a physical fact and the physical fact has not changed; all the
  -- status does is stop NEW assignments and recommendations landing here. Say
  -- so rather than let the operator discover it.
  select count(*) into v_orphaned
  from wms.sku_location_assignments where location_id = p_location_id;

  insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, before, after, correlation_id)
  values (v_loc.tenant_id, p_actor_id, 'wms_set_storage_location_status', 'storage_location', v_loc.id,
          v_before, to_jsonb(v_loc), p_correlation_id);

  v_cached := jsonb_build_object(
    'result', 'ok',
    'document_id', v_loc.id,
    'location_id', v_loc.id,
    'location_code', v_loc.location_code,
    'status', v_loc.status,
    'version', v_loc.version,
    'warnings', case when p_status = 'INACTIVE' and v_orphaned > 0
      then jsonb_build_array(format('STILL_ASSIGNED_SKUS: %s', v_orphaned))
      else '[]'::jsonb end,
    'next_actions', jsonb_build_array('set_storage_location_status')
  );
  if p_idempotency_key is not null then
    insert into wms.idempotency_records (tenant_id, command_name, idempotency_key, response)
    values (v_loc.tenant_id, 'wms_set_storage_location_status', p_idempotency_key, v_cached)
    on conflict do nothing;
  end if;
  return v_cached;
end;
$$;

-- D1. INBOUND_OPERATOR is included: the person putting the box on the shelf is
-- the person who knows where it went (same reasoning that lets them run
-- wms_create_putaway_tasks).
create or replace function wms.wms_assign_sku_location(
  p_tenant_id text,
  p_warehouse_id uuid,
  p_product_id uuid,
  p_location_id uuid,
  p_actor_id uuid,
  p_idempotency_key uuid,
  p_correlation_id text default null
) returns jsonb
language plpgsql security definer
set search_path = wms, public
as $$
declare
  v_cached jsonb;
  v_loc wms.storage_locations%rowtype;
  v_asg wms.sku_location_assignments%rowtype;
  v_existing wms.sku_location_assignments%rowtype;
begin
  if p_idempotency_key is not null then
    select response into v_cached from wms.idempotency_records
      where tenant_id = p_tenant_id and command_name = 'wms_assign_sku_location'
        and idempotency_key = p_idempotency_key;
    if found then return v_cached; end if;
  end if;

  if p_warehouse_id not in (select wms.current_warehouse_ids(p_tenant_id)) then
    raise exception 'FORBIDDEN: no warehouse scope for %', p_warehouse_id;
  end if;
  if not wms.has_role(p_tenant_id, 'WMS_ADMIN', 'WAREHOUSE_MANAGER', 'INBOUND_OPERATOR') then
    raise exception 'FORBIDDEN: role cannot declare SKU locations';
  end if;

  if not exists (select 1 from wms.products where id = p_product_id and tenant_id = p_tenant_id) then
    raise exception 'INVALID: unknown product %', p_product_id;
  end if;

  select * into v_existing from wms.sku_location_assignments
  where warehouse_id = p_warehouse_id and product_id = p_product_id;
  if found then
    raise exception 'INVALID: product % already has an active assignment (assignment_id=%) — use wms_reassign_sku_location',
      p_product_id, v_existing.id;
  end if;

  v_loc := wms._wms_load_active_location(p_warehouse_id, p_location_id);

  insert into wms.sku_location_assignments (
    tenant_id, warehouse_id, product_id, location_id, assigned_reason,
    correlation_id, created_by, updated_by
  ) values (
    p_tenant_id, p_warehouse_id, p_product_id, p_location_id, 'MANUAL_DECLARATION',
    p_correlation_id, auth.uid(), auth.uid()
  )
  returning * into v_asg;

  insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, before, after, correlation_id)
  values (p_tenant_id, p_actor_id, 'wms_assign_sku_location', 'sku_location_assignment', v_asg.id,
          null, to_jsonb(v_asg), p_correlation_id);

  v_cached := jsonb_build_object(
    'result', 'ok',
    'document_id', v_asg.id,
    'assignment_id', v_asg.id,
    'product_id', v_asg.product_id,
    'location_id', v_asg.location_id,
    'location_code', v_loc.location_code,
    'accessibility_rank', v_loc.accessibility_rank,
    'assigned_reason', v_asg.assigned_reason,
    'status', 'ACTIVE',
    'version', v_asg.version,
    -- D1, said out loud on every single declaration: nothing reconciles this
    -- against physical reality.
    'warnings', jsonb_build_array('DECLARATION_NOT_RECONCILED_WITH_PUTAWAY'),
    'next_actions', jsonb_build_array('reassign_sku_location', 'compute_sku_velocity')
  );
  if p_idempotency_key is not null then
    insert into wms.idempotency_records (tenant_id, command_name, idempotency_key, response)
    values (p_tenant_id, 'wms_assign_sku_location', p_idempotency_key, v_cached)
    on conflict do nothing;
  end if;
  return v_cached;
end;
$$;

create or replace function wms.wms_reassign_sku_location(
  p_assignment_id uuid,
  p_location_id uuid,
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
  v_asg wms.sku_location_assignments%rowtype;
  v_loc wms.storage_locations%rowtype;
  v_before jsonb;
  v_tenant_id text;
begin
  select tenant_id into v_tenant_id from wms.sku_location_assignments where id = p_assignment_id;
  if p_idempotency_key is not null and v_tenant_id is not null then
    select response into v_cached from wms.idempotency_records
      where tenant_id = v_tenant_id and command_name = 'wms_reassign_sku_location'
        and idempotency_key = p_idempotency_key;
    if found then return v_cached; end if;
  end if;

  select * into v_asg from wms.sku_location_assignments where id = p_assignment_id;
  if not found then
    raise exception 'INVALID: unknown assignment %', p_assignment_id;
  end if;
  if v_asg.warehouse_id not in (select wms.current_warehouse_ids(v_asg.tenant_id)) then
    raise exception 'FORBIDDEN: no warehouse scope for assignment %', p_assignment_id;
  end if;
  if not wms.has_role(v_asg.tenant_id, 'WMS_ADMIN', 'WAREHOUSE_MANAGER', 'INBOUND_OPERATOR') then
    raise exception 'FORBIDDEN: role cannot reassign SKU locations';
  end if;
  if p_expected_version is not null and v_asg.version <> p_expected_version then
    raise exception 'CONFLICT: expected version % but found %', p_expected_version, v_asg.version;
  end if;
  if v_asg.location_id = p_location_id then
    raise exception 'INVALID: assignment % is already at that location', p_assignment_id;
  end if;

  v_loc := wms._wms_load_active_location(v_asg.warehouse_id, p_location_id);

  v_before := to_jsonb(v_asg);

  -- A hand reassignment is a manual declaration whatever it used to be, and it
  -- is no longer attributable to whatever recommendation once placed it.
  update wms.sku_location_assignments
  set location_id = p_location_id,
      assigned_reason = 'MANUAL_DECLARATION',
      source_recommendation_id = null,
      version = version + 1,
      updated_by = auth.uid(),
      updated_at = now(),
      correlation_id = coalesce(p_correlation_id, correlation_id)
  where id = p_assignment_id
  returning * into v_asg;

  insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, before, after, correlation_id)
  values (v_asg.tenant_id, p_actor_id, 'wms_reassign_sku_location', 'sku_location_assignment', v_asg.id,
          v_before, to_jsonb(v_asg), p_correlation_id);

  v_cached := jsonb_build_object(
    'result', 'ok',
    'document_id', v_asg.id,
    'assignment_id', v_asg.id,
    'product_id', v_asg.product_id,
    'location_id', v_asg.location_id,
    'location_code', v_loc.location_code,
    'accessibility_rank', v_loc.accessibility_rank,
    'assigned_reason', v_asg.assigned_reason,
    'status', 'ACTIVE',
    'version', v_asg.version,
    'warnings', jsonb_build_array('DECLARATION_NOT_RECONCILED_WITH_PUTAWAY'),
    'next_actions', jsonb_build_array('reassign_sku_location')
  );
  if p_idempotency_key is not null then
    insert into wms.idempotency_records (tenant_id, command_name, idempotency_key, response)
    values (v_asg.tenant_id, 'wms_reassign_sku_location', p_idempotency_key, v_cached)
    on conflict do nothing;
  end if;
  return v_cached;
end;
$$;

create or replace function wms.wms_register_slotting_class_policy(
  p_tenant_id text,
  p_warehouse_id uuid,
  p_velocity_class text,
  p_max_accessibility_rank int,
  p_actor_id uuid,
  p_idempotency_key uuid,
  p_correlation_id text default null
) returns jsonb
language plpgsql security definer
set search_path = wms, public
as $$
declare
  v_cached jsonb;
  v_pol wms.slotting_class_policies%rowtype;
  v_qualifying int;
begin
  if p_idempotency_key is not null then
    select response into v_cached from wms.idempotency_records
      where tenant_id = p_tenant_id and command_name = 'wms_register_slotting_class_policy'
        and idempotency_key = p_idempotency_key;
    if found then return v_cached; end if;
  end if;

  perform wms._wms_slotting_admin_guard(p_tenant_id, p_warehouse_id, 'manage slotting class policies');

  if p_velocity_class is null or p_velocity_class not in ('A', 'B', 'C') then
    raise exception 'INVALID: velocity_class must be A, B or C';
  end if;
  if p_max_accessibility_rank is null or p_max_accessibility_rank <= 0 then
    raise exception 'INVALID: max_accessibility_rank must be a positive integer';
  end if;
  if exists (select 1 from wms.slotting_class_policies
              where warehouse_id = p_warehouse_id and velocity_class = p_velocity_class) then
    raise exception 'INVALID: a % class policy already exists for this warehouse — use wms_update_slotting_class_policy',
      p_velocity_class;
  end if;

  insert into wms.slotting_class_policies (
    tenant_id, warehouse_id, velocity_class, max_accessibility_rank,
    correlation_id, created_by, updated_by
  ) values (
    p_tenant_id, p_warehouse_id, p_velocity_class, p_max_accessibility_rank,
    p_correlation_id, auth.uid(), auth.uid()
  )
  returning * into v_pol;

  -- A cap no location can satisfy generates no recommendation, ever. That is
  -- not an error (locations may be registered later) but it is worth knowing.
  select count(*) into v_qualifying
  from wms.storage_locations
  where warehouse_id = p_warehouse_id and status = 'ACTIVE'
    and accessibility_rank <= p_max_accessibility_rank;

  insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, before, after, correlation_id)
  values (p_tenant_id, p_actor_id, 'wms_register_slotting_class_policy', 'slotting_class_policy', v_pol.id,
          null, to_jsonb(v_pol), p_correlation_id);

  v_cached := jsonb_build_object(
    'result', 'ok',
    'document_id', v_pol.id,
    'policy_id', v_pol.id,
    'velocity_class', v_pol.velocity_class,
    'max_accessibility_rank', v_pol.max_accessibility_rank,
    'qualifying_location_count', v_qualifying,
    'status', 'ACTIVE',
    'version', v_pol.version,
    'warnings', case when v_qualifying = 0
      then jsonb_build_array('NO_QUALIFYING_LOCATION')
      else '[]'::jsonb end,
    'next_actions', jsonb_build_array('update_slotting_class_policy', 'generate_slotting_recommendations')
  );
  if p_idempotency_key is not null then
    insert into wms.idempotency_records (tenant_id, command_name, idempotency_key, response)
    values (p_tenant_id, 'wms_register_slotting_class_policy', p_idempotency_key, v_cached)
    on conflict do nothing;
  end if;
  return v_cached;
end;
$$;

create or replace function wms.wms_update_slotting_class_policy(
  p_policy_id uuid,
  p_max_accessibility_rank int,
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
  v_pol wms.slotting_class_policies%rowtype;
  v_before jsonb;
  v_tenant_id text;
  v_qualifying int;
begin
  select tenant_id into v_tenant_id from wms.slotting_class_policies where id = p_policy_id;
  if p_idempotency_key is not null and v_tenant_id is not null then
    select response into v_cached from wms.idempotency_records
      where tenant_id = v_tenant_id and command_name = 'wms_update_slotting_class_policy'
        and idempotency_key = p_idempotency_key;
    if found then return v_cached; end if;
  end if;

  select * into v_pol from wms.slotting_class_policies where id = p_policy_id;
  if not found then
    raise exception 'INVALID: unknown slotting class policy %', p_policy_id;
  end if;
  perform wms._wms_slotting_admin_guard(v_pol.tenant_id, v_pol.warehouse_id, 'manage slotting class policies');

  if p_max_accessibility_rank is null or p_max_accessibility_rank <= 0 then
    raise exception 'INVALID: max_accessibility_rank must be a positive integer';
  end if;
  if p_expected_version is not null and v_pol.version <> p_expected_version then
    raise exception 'CONFLICT: expected version % but found %', p_expected_version, v_pol.version;
  end if;

  v_before := to_jsonb(v_pol);

  update wms.slotting_class_policies
  set max_accessibility_rank = p_max_accessibility_rank,
      version = version + 1,
      updated_by = auth.uid(),
      updated_at = now(),
      correlation_id = coalesce(p_correlation_id, correlation_id)
  where id = p_policy_id
  returning * into v_pol;

  select count(*) into v_qualifying
  from wms.storage_locations
  where warehouse_id = v_pol.warehouse_id and status = 'ACTIVE'
    and accessibility_rank <= v_pol.max_accessibility_rank;

  insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, before, after, correlation_id)
  values (v_pol.tenant_id, p_actor_id, 'wms_update_slotting_class_policy', 'slotting_class_policy', v_pol.id,
          v_before, to_jsonb(v_pol), p_correlation_id);

  v_cached := jsonb_build_object(
    'result', 'ok',
    'document_id', v_pol.id,
    'policy_id', v_pol.id,
    'velocity_class', v_pol.velocity_class,
    'max_accessibility_rank', v_pol.max_accessibility_rank,
    'qualifying_location_count', v_qualifying,
    'status', 'ACTIVE',
    'version', v_pol.version,
    -- D3: existing snapshots are untouched, so the new cap only shows up when
    -- recommendations are generated again. That is the point of splitting the
    -- two RPCs.
    'warnings', case when v_qualifying = 0
      then jsonb_build_array('NO_QUALIFYING_LOCATION', 'REGENERATE_TO_APPLY')
      else jsonb_build_array('REGENERATE_TO_APPLY') end,
    'next_actions', jsonb_build_array('generate_slotting_recommendations')
  );
  if p_idempotency_key is not null then
    insert into wms.idempotency_records (tenant_id, command_name, idempotency_key, response)
    values (v_pol.tenant_id, 'wms_update_slotting_class_policy', p_idempotency_key, v_cached)
    on conflict do nothing;
  end if;
  return v_cached;
end;
$$;

-- ------------------------------------------------------------
-- D3/D4/V2/V5. The velocity calculation.
--
-- The ONLY signal is `status = 'AVAILABLE' and qty_delta < 0`. Receipts,
-- dispositions and QC movements are deliberately not mixed in (Non-Goals) —
-- calling inbound frequency "shipping frequency" would corrupt the word.
--
-- As the header explains, nothing in this repository writes that row shape
-- today, so on real data this returns included_product_count = 0 and
-- skipped_no_data_count = every product. That is the honest answer, and
-- spec.md has a scenario asserting exactly it.
-- ------------------------------------------------------------
create or replace function wms.wms_compute_sku_velocity(
  p_tenant_id text,
  p_warehouse_id uuid,
  p_window_start date,
  p_window_end date,
  p_actor_id uuid,
  p_idempotency_key uuid,
  p_correlation_id text default null
) returns jsonb
language plpgsql security definer
set search_path = wms, public
as $$
declare
  v_cached jsonb;
  v_batch_id uuid := gen_random_uuid();
  v_included int := 0;
  v_candidates int := 0;
  v_skipped int;
  v_class_counts jsonb;
  v_total_qty numeric;
  v_rows jsonb;
begin
  if p_idempotency_key is not null then
    select response into v_cached from wms.idempotency_records
      where tenant_id = p_tenant_id and command_name = 'wms_compute_sku_velocity'
        and idempotency_key = p_idempotency_key;
    if found then return v_cached; end if;
  end if;

  if p_warehouse_id not in (select wms.current_warehouse_ids(p_tenant_id)) then
    raise exception 'FORBIDDEN: no warehouse scope for %', p_warehouse_id;
  end if;
  -- D6: pure analysis over the ledger. An agent may do this unattended; it
  -- changes no placement and moves no stock.
  if not wms.has_role(p_tenant_id, 'WMS_ADMIN', 'WAREHOUSE_MANAGER', 'PROCESS_AGENT') then
    raise exception 'FORBIDDEN: role cannot compute SKU velocity';
  end if;
  if p_window_start is null or p_window_end is null then
    raise exception 'INVALID: window_start and window_end are required';
  end if;
  if p_window_start >= p_window_end then
    raise exception 'INVALID: window_end must be after window_start';
  end if;

  -- V2: the universe. wms.products is tenant-scoped; there is no
  -- product-per-warehouse registry in this repository.
  select count(*) into v_candidates from wms.products where tenant_id = p_tenant_id;

  -- One pass: aggregate the signal, order it, run the cumulative share, and
  -- persist. Products with no signal never enter `agg`, so they never get a
  -- row — that absence IS the contract (see the table comment).
  with agg as (
    select
      e.product_id,
      sum(-e.qty_delta)::numeric as outbound_qty,
      count(*)::int              as outbound_event_count
    from wms.stock_ledger_entries e
    where e.tenant_id = p_tenant_id
      and e.warehouse_id = p_warehouse_id
      and e.status = 'AVAILABLE'
      and e.qty_delta < 0
      and e.created_at >= p_window_start::timestamptz
      and e.created_at <  (p_window_end + 1)::timestamptz   -- window_end is inclusive as a DAY
    group by e.product_id
    having sum(-e.qty_delta) > 0
  ), ranked as (
    select
      agg.*,
      sum(outbound_qty) over (
        order by outbound_qty desc, product_id
        rows between unbounded preceding and current row
      ) as cum_qty,
      sum(outbound_qty) over () as total_qty
    from agg
  ), classified as (
    select
      ranked.*,
      -- V5: exact integer comparison, inclusive boundaries. 80% exactly -> A.
      case
        when cum_qty * 100 <= total_qty * 80 then 'A'
        when cum_qty * 100 <= total_qty * 95 then 'B'
        else 'C'
      end as velocity_class
    from ranked
  )
  insert into wms.sku_velocity_snapshots (
    tenant_id, warehouse_id, product_id, window_start, window_end,
    outbound_qty, outbound_event_count, velocity_class, batch_id,
    computed_at, computed_by, correlation_id
  )
  select
    p_tenant_id, p_warehouse_id, c.product_id, p_window_start, p_window_end,
    c.outbound_qty, c.outbound_event_count, c.velocity_class, v_batch_id,
    now(), p_actor_id, p_correlation_id
  from classified c;

  get diagnostics v_included = row_count;
  v_skipped := greatest(v_candidates - v_included, 0);

  select
    coalesce(sum(s.outbound_qty), 0),
    jsonb_build_object(
      'A', count(*) filter (where s.velocity_class = 'A'),
      'B', count(*) filter (where s.velocity_class = 'B'),
      'C', count(*) filter (where s.velocity_class = 'C')
    ),
    coalesce(jsonb_agg(jsonb_build_object(
      'product_id', s.product_id,
      'sku', p.sku,
      'outbound_qty', s.outbound_qty,
      'outbound_event_count', s.outbound_event_count,
      'velocity_class', s.velocity_class
    ) order by s.outbound_qty desc, s.product_id), '[]'::jsonb)
  into v_total_qty, v_class_counts, v_rows
  from wms.sku_velocity_snapshots s
  join wms.products p on p.id = s.product_id
  where s.batch_id = v_batch_id;

  insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, before, after, correlation_id)
  values (p_tenant_id, p_actor_id, 'wms_compute_sku_velocity', 'sku_velocity_batch', v_batch_id,
          null,
          jsonb_build_object('batch_id', v_batch_id, 'warehouse_id', p_warehouse_id,
                             'window_start', p_window_start, 'window_end', p_window_end,
                             'included_product_count', v_included,
                             'skipped_no_data_count', v_skipped),
          p_correlation_id);

  v_cached := jsonb_build_object(
    'result', 'ok',
    'document_id', v_batch_id,
    'batch_id', v_batch_id,
    'window_start', p_window_start,
    'window_end', p_window_end,
    'candidate_product_count', v_candidates,   -- V2
    'included_product_count', v_included,
    -- The headline honesty field. included + skipped = candidate, always.
    'skipped_no_data_count', v_skipped,
    'class_counts', v_class_counts,
    'total_outbound_qty', v_total_qty,
    'snapshots', v_rows,
    'method', 'CUMULATIVE_SHARE_ABC_80_95',
    'method_note', 'AVAILABLE 상태의 음수 qty_delta(소비/출고)만 신호로 씁니다. '
                || '입고·QC·폐기 이력은 섞지 않습니다. 신호가 없는 SKU는 임의 등급을 '
                || '받지 않고 skipped_no_data_count로만 보고됩니다.',
    'status', case when v_included = 0 then 'NO_SIGNAL' else 'COMPUTED' end,
    'version', 1,
    'warnings', case when v_included = 0
      then jsonb_build_array('NO_CONSUMPTION_SIGNAL_IN_WINDOW')
      else '[]'::jsonb end,
    'next_actions', case when v_included = 0
      then jsonb_build_array('compute_sku_velocity')
      else jsonb_build_array('generate_slotting_recommendations') end
  );
  if p_idempotency_key is not null then
    insert into wms.idempotency_records (tenant_id, command_name, idempotency_key, response)
    values (p_tenant_id, 'wms_compute_sku_velocity', p_idempotency_key, v_cached)
    on conflict do nothing;
  end if;
  return v_cached;
end;
$$;

-- ------------------------------------------------------------
-- D2/D5/V3/V4. Compare a snapshot batch against the warehouse's class policies
-- and write PENDING recommendations. Generating is analysis, so PROCESS_AGENT
-- may do it (D6); nothing here changes a placement.
-- ------------------------------------------------------------
create or replace function wms.wms_generate_slotting_recommendations(
  p_tenant_id text,
  p_warehouse_id uuid,
  p_velocity_batch_id uuid,
  p_actor_id uuid,
  p_idempotency_key uuid,
  p_correlation_id text default null
) returns jsonb
language plpgsql security definer
set search_path = wms, public
as $$
declare
  v_cached jsonb;
  v_snap record;
  v_pol wms.slotting_class_policies%rowtype;
  v_asg wms.sku_location_assignments%rowtype;
  v_cur wms.storage_locations%rowtype;
  v_target_id uuid;
  v_rec wms.slotting_recommendations%rowtype;
  v_generated int := 0;
  v_already_optimal int := 0;
  v_open_rec int := 0;
  v_no_target int := 0;
  v_snapshot_count int := 0;
  v_no_policy text[] := '{}';
  v_ids jsonb := '[]'::jsonb;
begin
  if p_idempotency_key is not null then
    select response into v_cached from wms.idempotency_records
      where tenant_id = p_tenant_id and command_name = 'wms_generate_slotting_recommendations'
        and idempotency_key = p_idempotency_key;
    if found then return v_cached; end if;
  end if;

  if p_warehouse_id not in (select wms.current_warehouse_ids(p_tenant_id)) then
    raise exception 'FORBIDDEN: no warehouse scope for %', p_warehouse_id;
  end if;
  if not wms.has_role(p_tenant_id, 'WMS_ADMIN', 'WAREHOUSE_MANAGER', 'PROCESS_AGENT') then
    raise exception 'FORBIDDEN: role cannot generate slotting recommendations';
  end if;
  if p_velocity_batch_id is null then
    raise exception 'INVALID: velocity_batch_id is required';
  end if;

  select count(*) into v_snapshot_count
  from wms.sku_velocity_snapshots
  where batch_id = p_velocity_batch_id
    and tenant_id = p_tenant_id and warehouse_id = p_warehouse_id;
  if v_snapshot_count = 0 then
    raise exception 'INVALID: velocity batch % has no snapshot in this warehouse', p_velocity_batch_id;
  end if;

  for v_snap in
    select s.id, s.product_id, s.velocity_class, s.outbound_qty, p.sku
    from wms.sku_velocity_snapshots s
    join wms.products p on p.id = s.product_id
    where s.batch_id = p_velocity_batch_id
      and s.tenant_id = p_tenant_id and s.warehouse_id = p_warehouse_id
    -- fastest movers get first pick of the good slots
    order by s.outbound_qty desc, s.product_id
  loop
    -- D2: no policy, no recommendation, and say which class was skipped rather
    -- than invent a default cap.
    select * into v_pol from wms.slotting_class_policies
    where warehouse_id = p_warehouse_id and velocity_class = v_snap.velocity_class;
    if not found then
      if not (v_snap.velocity_class = any(v_no_policy)) then
        v_no_policy := v_no_policy || v_snap.velocity_class;
      end if;
      continue;
    end if;

    -- V4: don't stack a second recommendation on a SKU already waiting for a
    -- human. Regeneration after a policy tweak is an expected workflow (D3).
    if exists (select 1 from wms.slotting_recommendations
                where warehouse_id = p_warehouse_id and product_id = v_snap.product_id
                  and status in ('PENDING', 'APPROVED')) then
      v_open_rec := v_open_rec + 1;
      continue;
    end if;

    select * into v_asg from wms.sku_location_assignments
    where warehouse_id = p_warehouse_id and product_id = v_snap.product_id;

    if found then
      select * into v_cur from wms.storage_locations where id = v_asg.location_id;
      -- Already good enough. Silence here is correct: churn for its own sake
      -- costs real forklift time.
      if v_cur.accessibility_rank <= v_pol.max_accessibility_rank then
        v_already_optimal := v_already_optimal + 1;
        continue;
      end if;
      v_target_id := wms._wms_pick_slotting_target(p_warehouse_id, v_pol.max_accessibility_rank, v_asg.location_id);
      if v_target_id is null then
        v_no_target := v_no_target + 1;
        continue;
      end if;
      insert into wms.slotting_recommendations (
        tenant_id, warehouse_id, product_id, velocity_snapshot_id,
        current_location_id, recommended_location_id, reason_code, status,
        correlation_id, created_by
      ) values (
        p_tenant_id, p_warehouse_id, v_snap.product_id, v_snap.id,
        v_asg.location_id, v_target_id, 'RELOCATE_UNDERSERVED', 'PENDING',
        p_correlation_id, auth.uid()
      )
      returning * into v_rec;
    else
      -- D5: a graded SKU nobody has placed. Excluding it would guarantee the
      -- least-managed SKUs stay least-managed forever.
      v_target_id := wms._wms_pick_slotting_target(p_warehouse_id, v_pol.max_accessibility_rank, null);
      if v_target_id is null then
        v_no_target := v_no_target + 1;
        continue;
      end if;
      insert into wms.slotting_recommendations (
        tenant_id, warehouse_id, product_id, velocity_snapshot_id,
        current_location_id, recommended_location_id, reason_code, status,
        correlation_id, created_by
      ) values (
        p_tenant_id, p_warehouse_id, v_snap.product_id, v_snap.id,
        null, v_target_id, 'UNASSIGNED_HIGH_VELOCITY', 'PENDING',
        p_correlation_id, auth.uid()
      )
      returning * into v_rec;
    end if;

    v_generated := v_generated + 1;
    v_ids := v_ids || jsonb_build_object(
      'recommendation_id', v_rec.id,
      'product_id', v_rec.product_id,
      'sku', v_snap.sku,
      'velocity_class', v_snap.velocity_class,
      'reason_code', v_rec.reason_code,
      'current_location_id', v_rec.current_location_id,
      'recommended_location_id', v_rec.recommended_location_id,
      'version', v_rec.version
    );

    insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, before, after, correlation_id)
    values (p_tenant_id, p_actor_id, 'wms_generate_slotting_recommendations', 'slotting_recommendation', v_rec.id,
            null, to_jsonb(v_rec), p_correlation_id);
  end loop;

  v_cached := jsonb_build_object(
    'result', 'ok',
    'document_id', p_velocity_batch_id,
    'batch_id', p_velocity_batch_id,
    'snapshot_count', v_snapshot_count,
    'generated_count', v_generated,
    -- D2's honesty field: "this warehouse has never defined a B policy".
    'skipped_no_policy_classes', to_jsonb(v_no_policy),
    'skipped_already_optimal_count', v_already_optimal,
    'skipped_open_recommendation_count', v_open_rec,   -- V4
    'skipped_no_target_location_count', v_no_target,   -- V3
    'recommendations', v_ids,
    'status', case when v_generated = 0 then 'NOTHING_TO_RECOMMEND' else 'GENERATED' end,
    'version', 1,
    'warnings', (
      case when array_length(v_no_policy, 1) is not null
        then jsonb_build_array(format('NO_POLICY_FOR_CLASSES: %s', array_to_string(v_no_policy, ',')))
        else '[]'::jsonb end
      || case when v_no_target > 0
        then jsonb_build_array(format('NO_QUALIFYING_TARGET_LOCATION: %s', v_no_target))
        else '[]'::jsonb end
    ),
    -- D6/D7: the next step is a person's, not an agent's.
    'next_actions', case when v_generated = 0
      then jsonb_build_array('compute_sku_velocity')
      else jsonb_build_array('review_slotting_recommendation') end
  );
  if p_idempotency_key is not null then
    insert into wms.idempotency_records (tenant_id, command_name, idempotency_key, response)
    values (p_tenant_id, 'wms_generate_slotting_recommendations', p_idempotency_key, v_cached)
    on conflict do nothing;
  end if;
  return v_cached;
end;
$$;

-- ------------------------------------------------------------
-- D6. The HITL gate. WMS_ADMIN / WAREHOUSE_MANAGER only — approving a
-- recommendation is a decision to move physical stock, and this contract
-- refuses to let an agent make it. PROCESS_AGENT gets FORBIDDEN here even
-- though it was allowed to generate the very recommendation being reviewed.
-- ------------------------------------------------------------
create or replace function wms.wms_review_slotting_recommendation(
  p_recommendation_id uuid,
  p_decision text,
  p_actor_id uuid,
  p_idempotency_key uuid,
  p_expected_version int,
  p_review_reason text default null,
  p_correlation_id text default null
) returns jsonb
language plpgsql security definer
set search_path = wms, public
as $$
declare
  v_cached jsonb;
  v_rec wms.slotting_recommendations%rowtype;
  v_before jsonb;
  v_tenant_id text;
  v_new_status text;
begin
  select tenant_id into v_tenant_id from wms.slotting_recommendations where id = p_recommendation_id;
  if p_idempotency_key is not null and v_tenant_id is not null then
    select response into v_cached from wms.idempotency_records
      where tenant_id = v_tenant_id and command_name = 'wms_review_slotting_recommendation'
        and idempotency_key = p_idempotency_key;
    if found then return v_cached; end if;
  end if;

  select * into v_rec from wms.slotting_recommendations where id = p_recommendation_id;
  if not found then
    raise exception 'INVALID: unknown slotting recommendation %', p_recommendation_id;
  end if;
  if v_rec.warehouse_id not in (select wms.current_warehouse_ids(v_rec.tenant_id)) then
    raise exception 'FORBIDDEN: no warehouse scope for recommendation %', p_recommendation_id;
  end if;
  -- D6. Deliberately narrower than the generating RPC above.
  if not wms.has_role(v_rec.tenant_id, 'WMS_ADMIN', 'WAREHOUSE_MANAGER') then
    raise exception 'FORBIDDEN: role cannot review slotting recommendations (human decision: WMS_ADMIN or WAREHOUSE_MANAGER)';
  end if;
  if p_decision is null or p_decision not in ('APPROVE', 'REJECT') then
    raise exception 'INVALID: decision must be APPROVE or REJECT';
  end if;
  if p_expected_version is not null and v_rec.version <> p_expected_version then
    raise exception 'CONFLICT: expected version % but found %', p_expected_version, v_rec.version;
  end if;
  if v_rec.status <> 'PENDING' then
    raise exception 'INVALID: recommendation % is not PENDING (status=%)', p_recommendation_id, v_rec.status;
  end if;

  v_new_status := case when p_decision = 'APPROVE' then 'APPROVED' else 'REJECTED' end;
  v_before := to_jsonb(v_rec);

  update wms.slotting_recommendations
  set status = v_new_status,
      reviewed_by = p_actor_id,
      reviewed_at = now(),
      review_reason = p_review_reason,
      version = version + 1,
      correlation_id = coalesce(p_correlation_id, correlation_id)
  where id = p_recommendation_id
  returning * into v_rec;

  insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, before, after, correlation_id)
  values (v_rec.tenant_id, p_actor_id, 'wms_review_slotting_recommendation', 'slotting_recommendation', v_rec.id,
          v_before, to_jsonb(v_rec), p_correlation_id);

  v_cached := jsonb_build_object(
    'result', 'ok',
    'document_id', v_rec.id,
    'recommendation_id', v_rec.id,
    'product_id', v_rec.product_id,
    'decision', p_decision,
    'reviewed_by', v_rec.reviewed_by,
    'reviewed_at', v_rec.reviewed_at,
    'review_reason', v_rec.review_reason,
    'status', v_rec.status,
    'version', v_rec.version,
    -- D7: approving is not moving. Nothing has changed on any shelf yet.
    'warnings', case when v_new_status = 'APPROVED'
      then jsonb_build_array('ASSIGNMENT_UNCHANGED_UNTIL_APPLIED')
      else '[]'::jsonb end,
    'next_actions', case when v_new_status = 'APPROVED'
      then jsonb_build_array('apply_slotting_recommendation')
      else jsonb_build_array('generate_slotting_recommendations') end
  );
  if p_idempotency_key is not null then
    insert into wms.idempotency_records (tenant_id, command_name, idempotency_key, response)
    values (v_rec.tenant_id, 'wms_review_slotting_recommendation', p_idempotency_key, v_cached)
    on conflict do nothing;
  end if;
  return v_cached;
end;
$$;

-- ------------------------------------------------------------
-- D7. Approval and application are separate so "approved, moving it on the
-- night shift" is representable, and so the two moments audit separately.
-- The assignment upsert and the status transition are one transaction.
--
-- INBOUND_OPERATOR is allowed: applying records that the move HAPPENED, which
-- is the floor's knowledge, not the manager's. (What it does NOT do is decide
-- that the move should happen — that was the review above.)
-- ------------------------------------------------------------
create or replace function wms.wms_apply_slotting_recommendation(
  p_recommendation_id uuid,
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
  v_rec wms.slotting_recommendations%rowtype;
  v_before jsonb;
  v_asg_before jsonb;
  v_asg wms.sku_location_assignments%rowtype;
  v_loc wms.storage_locations%rowtype;
  v_tenant_id text;
  v_created boolean := false;
begin
  select tenant_id into v_tenant_id from wms.slotting_recommendations where id = p_recommendation_id;
  if p_idempotency_key is not null and v_tenant_id is not null then
    select response into v_cached from wms.idempotency_records
      where tenant_id = v_tenant_id and command_name = 'wms_apply_slotting_recommendation'
        and idempotency_key = p_idempotency_key;
    if found then return v_cached; end if;
  end if;

  select * into v_rec from wms.slotting_recommendations where id = p_recommendation_id;
  if not found then
    raise exception 'INVALID: unknown slotting recommendation %', p_recommendation_id;
  end if;
  if v_rec.warehouse_id not in (select wms.current_warehouse_ids(v_rec.tenant_id)) then
    raise exception 'FORBIDDEN: no warehouse scope for recommendation %', p_recommendation_id;
  end if;
  if not wms.has_role(v_rec.tenant_id, 'WMS_ADMIN', 'WAREHOUSE_MANAGER', 'INBOUND_OPERATOR') then
    raise exception 'FORBIDDEN: role cannot apply slotting recommendations';
  end if;
  if p_expected_version is not null and v_rec.version <> p_expected_version then
    raise exception 'CONFLICT: expected version % but found %', p_expected_version, v_rec.version;
  end if;
  -- The whole point of the contract: no approval, no move.
  if v_rec.status <> 'APPROVED' then
    raise exception 'INVALID: recommendation % is not APPROVED (status=%)', p_recommendation_id, v_rec.status;
  end if;

  -- The target may have been deactivated between approval and application.
  v_loc := wms._wms_load_active_location(v_rec.warehouse_id, v_rec.recommended_location_id);

  v_before := to_jsonb(v_rec);

  select * into v_asg from wms.sku_location_assignments
  where warehouse_id = v_rec.warehouse_id and product_id = v_rec.product_id;

  if found then
    v_asg_before := to_jsonb(v_asg);
    update wms.sku_location_assignments
    set location_id = v_rec.recommended_location_id,
        assigned_reason = 'SLOTTING_RECOMMENDATION',
        source_recommendation_id = v_rec.id,
        version = version + 1,
        updated_by = auth.uid(),
        updated_at = now(),
        correlation_id = coalesce(p_correlation_id, correlation_id)
    where id = v_asg.id
    returning * into v_asg;
  else
    -- D5's other half: the UNASSIGNED_HIGH_VELOCITY case creates the record.
    v_asg_before := null;
    v_created := true;
    insert into wms.sku_location_assignments (
      tenant_id, warehouse_id, product_id, location_id, assigned_reason,
      source_recommendation_id, correlation_id, created_by, updated_by
    ) values (
      v_rec.tenant_id, v_rec.warehouse_id, v_rec.product_id, v_rec.recommended_location_id,
      'SLOTTING_RECOMMENDATION', v_rec.id, p_correlation_id, auth.uid(), auth.uid()
    )
    returning * into v_asg;
  end if;

  update wms.slotting_recommendations
  set status = 'APPLIED',
      applied_at = now(),
      version = version + 1,
      correlation_id = coalesce(p_correlation_id, correlation_id)
  where id = p_recommendation_id
  returning * into v_rec;

  insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, before, after, correlation_id)
  values (v_rec.tenant_id, p_actor_id, 'wms_apply_slotting_recommendation', 'slotting_recommendation', v_rec.id,
          v_before, to_jsonb(v_rec), p_correlation_id);
  insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, before, after, correlation_id)
  values (v_rec.tenant_id, p_actor_id, 'wms_apply_slotting_recommendation', 'sku_location_assignment', v_asg.id,
          v_asg_before, to_jsonb(v_asg), p_correlation_id);

  v_cached := jsonb_build_object(
    'result', 'ok',
    'document_id', v_rec.id,
    'recommendation_id', v_rec.id,
    'product_id', v_rec.product_id,
    'assignment_id', v_asg.id,
    'assignment_created', v_created,
    'assignment_version', v_asg.version,
    'location_id', v_asg.location_id,
    'location_code', v_loc.location_code,
    'accessibility_rank', v_loc.accessibility_rank,
    'assigned_reason', v_asg.assigned_reason,
    'applied_at', v_rec.applied_at,
    'status', v_rec.status,
    'version', v_rec.version,
    -- Non-Goals: APPLIED means the record moved. Nobody checked the shelf.
    'warnings', jsonb_build_array('RECORD_ONLY_NO_PHYSICAL_MOVE_VERIFIED'),
    'next_actions', jsonb_build_array('compute_sku_velocity')
  );
  if p_idempotency_key is not null then
    insert into wms.idempotency_records (tenant_id, command_name, idempotency_key, response)
    values (v_rec.tenant_id, 'wms_apply_slotting_recommendation', p_idempotency_key, v_cached)
    on conflict do nothing;
  end if;
  return v_cached;
end;
$$;

grant execute on function wms.wms_register_storage_location(text, uuid, text, text, int, uuid, uuid, numeric, text) to authenticated;
grant execute on function wms.wms_set_storage_location_status(uuid, text, uuid, uuid, int, text) to authenticated;
grant execute on function wms.wms_assign_sku_location(text, uuid, uuid, uuid, uuid, uuid, text) to authenticated;
grant execute on function wms.wms_reassign_sku_location(uuid, uuid, uuid, uuid, int, text) to authenticated;
grant execute on function wms.wms_register_slotting_class_policy(text, uuid, text, int, uuid, uuid, text) to authenticated;
grant execute on function wms.wms_update_slotting_class_policy(uuid, int, uuid, uuid, int, text) to authenticated;
grant execute on function wms.wms_compute_sku_velocity(text, uuid, date, date, uuid, uuid, text) to authenticated;
grant execute on function wms.wms_generate_slotting_recommendations(text, uuid, uuid, uuid, uuid, text) to authenticated;
grant execute on function wms.wms_review_slotting_recommendation(uuid, text, uuid, uuid, int, text, text) to authenticated;
grant execute on function wms.wms_apply_slotting_recommendation(uuid, uuid, uuid, int, text) to authenticated;

-- _wms_slotting_admin_guard, _wms_load_active_location and
-- _wms_pick_slotting_target are internal helpers: no grant, exactly like
-- wms._wms_finalize_disposition in the core schema.
