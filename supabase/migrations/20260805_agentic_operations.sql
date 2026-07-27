-- ============================================================
-- Agentic operations contract
-- Scope: openspec/changes/add-agentic-operations
--        (proposal.md / design.md / specs/wms_agentic-operations/spec.md)
--
-- The tenth area, and the one that deliberately builds the LEAST machinery.
-- Manhattan Active WM embeds its Wave Coordinator / Labor / Associate agents
-- inside the WMS product. This repository does not, and this migration does
-- not change that: there is NO agent runtime here, no LLM call, no pg_cron
-- loop, no dynamic RPC dispatcher, no second BPM engine. ProcessGPT stays the
-- only orchestrator (docs/03-processgpt-integration.md).
--
-- What this area adds is three contracts and nothing else:
--
--   1. READ SIGNALS  — what an external agent is allowed to observe:
--        wms_get_labor_balance_signals    (over area 8's labor activities)
--        wms_get_dispatch_delay_signals   (over areas 2 + 4)
--        wms_get_worker_next_actions      (over area 1's receipts)
--   2. A DECISION / PROPOSAL LOG — one table, wms.agent_decisions, carrying
--      both the stateless "I did X because Y" record (status='LOGGED') and the
--      stateful "may I do X?" proposal (PROPOSED -> CONFIRMED/REJECTED).
--   3. AN ACTION BOUNDARY — log/propose are open to PROCESS_AGENT;
--      confirm/reject are human-only (WAREHOUSE_MANAGER / WMS_ADMIN).
--
-- Confirming a proposal changes a status column and NOTHING else (design.md
-- D7). No table outside wms.agent_decisions is written by any RPC in this
-- file, apart from the standard wms.audit_events / wms.idempotency_records
-- bookkeeping every other migration also does.
--
-- Conventions (schema, common columns, RLS helpers, RPC envelope,
-- CONFLICT:/FORBIDDEN:/INVALID: prefixes, idempotency records, audit events)
-- are identical to the ten migrations before it, and none of those files is
-- modified here.
--
-- ORDERING / DEPENDENCIES:
--   20260726_wms_core_schema.sql          — tenants, warehouses, receipts,
--                                           memberships, audit_events,
--                                           idempotency_records, has_role,
--                                           current_warehouse_ids
--   20260728_wes_material_flow_control.sql — wms.work_orders, wms.dispatch_waves
--   20260730_wcs_bottleneck_routing.sql    — wms.wcs_equipment_bottleneck_status
--   20260803_labor_management.sql          — wms.labor_activities
-- The last three are needed by the two signal RPCs only.
--
-- ============================================================
-- THE HONEST PREMISE, RE-VERIFIED AGAINST THE IMPLEMENTED CODE
-- ============================================================
--
-- design.md was written when areas 2, 4 and 8 were still unimplemented, and it
-- said so plainly: "wms.work_orders, wms.dispatch_waves,
-- wms.wcs_equipment_bottleneck_status는 그 두 변경의 design.md에 있는 검토용
-- 후보이며 실제 DB에는 존재하지 않는다", and the same for
-- wms_get_labor_productivity. tasks.md §5 therefore split those two signal
-- RPCs into a separate chapter that was not to be started yet.
--
-- All three areas have since landed for real. Re-checked against the shipped
-- migrations rather than their design docs:
--
--   $ grep -n 'create table wms.work_orders\|create table wms.dispatch_waves' \
--       supabase/migrations/20260728_wes_material_flow_control.sql
--   48:create table wms.dispatch_waves (
--   63:create table wms.work_orders (
--   $ grep -n 'create view wms.wcs_equipment_bottleneck_status' \
--       supabase/migrations/20260730_wcs_bottleneck_routing.sql
--   207:create view wms.wcs_equipment_bottleneck_status
--   $ grep -n 'create table wms.labor_activities' \
--       supabase/migrations/20260803_labor_management.sql
--   108:create table wms.labor_activities (
--
-- So tasks.md §5 is unblocked and both signal RPCs are implemented here, in
-- the same migration as the other six. They are written against the REAL
-- column names and semantics of those three files, which differ from what
-- design.md guessed in several places — every difference is a V-note below.
-- The "returns an empty result, not an error, when the upstream contract is
-- missing" promise in spec.md is still honoured: it now degrades on missing
-- DATA (no labor activity in the window, no QUEUED work order) rather than on
-- a missing table, and the response says which case it is instead of returning
-- a bare [].
--
-- ------------------------------------------------------------
-- DEVIATIONS from design.md, deliberate and small:
--
-- V0. PARAMETER ORDER: NOTHING TO FIX, FOR ONCE. The three migrations before
--     this one each had to hoist a defaulted parameter above a required one
--     because design.md's RPC table listed them in an order PostgreSQL
--     rejects (20260802 V?, 20260803 V1, 20260804 V1). All eight signatures
--     in this contract's RPC table were re-checked and every one of them
--     already puts its defaults last, so all eight are implemented exactly as
--     designed. Two trailing parameters are ADDED (V3, V6); neither displaces
--     anything and design.md's documented call forms still compile.
--
-- V1. wms_get_labor_balance_signals DOES NOT CALL wms_get_labor_productivity.
--     design.md D2 says to "wrap" it. Reading the shipped function (20260803
--     lines 511-609) shows that wrapping it would defeat the entire point of
--     this signal:
--
--       v_is_manager := wms.has_role(p_tenant_id, 'WAREHOUSE_MANAGER', 'WMS_ADMIN');
--       if v_is_manager then ... else v_scope := 'SELF';
--                                     v_actor_filter := auth.uid(); end if;
--
--     PROCESS_AGENT is not a manager, so a literal wrapper would hand the
--     agent exactly one row — its own — and "is this warehouse imbalanced?"
--     would be unanswerable. That is precisely the outcome D2's deliberate
--     role expansion exists to prevent, so the expansion has to live at the
--     query, not at a call site that has already been narrowed.
--
--     Two further reasons the call could not be reused as-is: area 8 groups
--     by (actor, date, activity_type) while a balance signal needs exactly one
--     row per actor; and its `rows` payload carries no per-actor total to
--     compare against a mean.
--
--     What IS reused verbatim is area 8's aggregation PREDICATE — same table,
--     status = 'COMPLETED' only (cancelled and still-running activities never
--     reach an aggregate), completed_at >= start and < end, same tenant and
--     warehouse. No new proxy for "how much work did this person do" is
--     invented here, which is what D2 was actually protecting against. If
--     area 8 ever changes what counts as completed work, this file's §
--     "Labor balance" is the one place that has to follow.
--
-- V2. THE IMBALANCE THRESHOLD IS A NAMED CONSTANT, RETURNED IN THE RESPONSE.
--     spec.md says a worker whose deviation exceeds "임계값" is flagged but
--     never names one. It is 0.40 — a worker 40% above or below the warehouse
--     mean completion count is flagged — and the response carries
--     `imbalance_threshold` so nobody has to read this file to know what the
--     boolean meant. spec.md's own worked example (12 vs 2) gives a mean of 7
--     and deviations of +0.714 / -0.714, so both workers flag, as the scenario
--     expects. Same convention as area 4's default thresholds, which are also
--     constants surfaced in the response
--     (default_queue_depth_threshold / default_fault_count_threshold).
--
--     `deviation_ratio` is signed on purpose: -1.0 (did nothing) and +2.0
--     (did triple the mean) are opposite operational problems and a rebalance
--     proposal needs to know which end it is looking at. `direction` spells
--     the same thing out as ABOVE / BELOW / AT.
--
--     A one-worker warehouse cannot be imbalanced against itself — its
--     deviation is 0 by construction — so the response adds a
--     SINGLE_WORKER_NO_COMPARISON note rather than quietly returning
--     is_imbalanced=false as if a comparison had happened.
--
-- V3. DISPATCH DELAY NEEDS A THRESHOLD, AND AREA 2 HAS NONE. spec.md talks
--     about work orders "지연 임계 시간을 넘겨" QUEUED, but nothing in
--     20260728 defines such a threshold — a work order is QUEUED or it is
--     not. p_delay_threshold_minutes (default 15) is therefore appended to
--     design.md's 3-parameter signature. It is defaulted, so the documented
--     3-argument call form still compiles, and the chosen value comes back in
--     the response.
--
--     "Queued since when" is measured from work_orders.updated_at, not
--     created_at. wms_retry_work_order_dispatch bumps updated_at on a failed
--     retry (20260728), so updated_at is "waiting since the last attempt",
--     which is the number an agent deciding whether to retry again actually
--     wants. created_at ships alongside it so the total age is visible too.
--
-- V4. THE BOTTLENECK VIEW IS PER-EQUIPMENT, SO THE JOIN IS BY CANDIDATE SET.
--     design.md imagined joining work orders to
--     wms.wcs_equipment_bottleneck_status directly. The shipped view (20260730
--     line 207) has one row per MACHINE and no work-order axis at all, and a
--     QUEUED work order by definition has no equipment assigned yet
--     (work_orders.equipment_command_id is null until a dispatch succeeds).
--
--     The join is therefore to the work order's CANDIDATE SET, computed with
--     the same predicate the real selection hook uses
--     (wms.wcs_select_available_equipment, 20260730 line 274):
--     equipment_type match, zone_code match or a null work-order zone meaning
--     "any zone", ACTIVE routing overrides excluded hard, IDLE + no
--     outstanding command to be routable. Every count in the row
--     (candidate_equipment_count / idle_candidate_count /
--     excluded_candidate_count / bottleneck_candidate_count) is over that set,
--     and `bottleneck_equipment` lists the flagged machines by code with the
--     view's own reasons, so "why is this stuck" is answerable without a
--     second query.
--
--     delay_causes is an ARRAY, not a single verdict, because the two causes
--     spec.md names are not exclusive — a zone can have no idle machine AND
--     have its only machine flagged as a bottleneck at the same time:
--       NO_EQUIPMENT_REGISTERED          — nothing of that type/zone exists
--       ALL_CANDIDATES_EXCLUDED          — every candidate is force-excluded
--       NO_IDLE_EQUIPMENT                — none is IDLE-and-free right now
--       ALL_ROUTABLE_CANDIDATES_BOTTLENECKED
--       BOTTLENECK_AMONG_CANDIDATES      — some, not all, are flagged
--       WAVE_NOT_RELEASED                — a WAVE work order whose wave is
--                                          still OPEN is not late, it is not
--                                          due yet (20260728 D6). It is still
--                                          reported, with this cause, so an
--                                          agent does not "fix" it by retrying.
--
-- V5. WORKER INVOLVEMENT IS DERIVED, BECAUSE wms.receipts HAS NO ACTOR COLUMN.
--     design.md D4 says to find the receipts a worker "관여한(actor_id로
--     식별)". Checked: wms.receipts (20260726 line 102) has no created_by, no
--     updated_by, no actor_id — the columns are id, tenant_id, warehouse_id,
--     po_id, product_id, expected_qty, received_qty, status, version,
--     created_at, updated_at. The person-to-receipt link exists in four other
--     places, and involvement is the union of all four:
--       wms.audit_events        (actor_id, entity_type='receipt', entity_id)
--       wms.quality_inspections (actor_id, receipt_id)
--       wms.inventory_dispositions (actor_id, receipt_id)
--       wms.labor_activities    (actor_id, linked_entity_type='receipt')
--     Each row reports `involvement_sources`, so a caller can see WHY a
--     receipt is on the worker's list rather than trusting an opaque filter.
--
-- V6. RECEIPT STATUSES: 'RECEIVING' DOES NOT EXIST IN THIS SCHEMA. spec.md's
--     scenario has a receipt sitting in 'RECEIVING'. The core schema collapsed
--     that state — its own comment at 20260726 line 110 says so — and the real
--     set is EXPECTED / ARRIVED / QC_PENDING / QC_COMPLETED / PUTAWAY_PENDING /
--     PUTAWAY_COMPLETED. The scenario's "worker is mid-inspection" state is
--     QC_PENDING. Open = the first five; PUTAWAY_COMPLETED is terminal and
--     excluded, which is exactly what the second scenario asks for.
--     p_include_closed (default false) is appended so an operator screen can
--     show a worker's finished items too; the default preserves design.md's
--     3-parameter call form and spec.md's behaviour.
--
--     The `next_actions` per status are the transitions the core-schema RPCs
--     actually accept, read off their own guards, not a hand-written list:
--       EXPECTED         -> register_arrival
--       ARRIVED          -> receive
--       QC_PENDING       -> record_quality_result
--       QC_COMPLETED     -> apply_disposition        (the failed-QC branch)
--       PUTAWAY_PENDING  -> create_putaway_tasks     (the passed-QC branch)
--
-- V7. proposal_type IS AN OPEN SET WITH A SHAPE CONSTRAINT. design.md's data
--     model calls it "열린 집합" while tasks.md 1.2 asks for a CHECK on it.
--     Both are honoured the only way they can both be: `status` gets a strict
--     four-value CHECK because it is a state machine this contract owns, and
--     `proposal_type` gets a non-empty CHECK only, because a follow-up area
--     adding a new proposal kind must not need a migration in this file. The
--     three values this contract uses (DISPATCH_RETRY, LABOR_REBALANCE,
--     EQUIPMENT_ROUTING_SUGGESTION) are documented on the column instead.
--
-- V8. correlation_id: THE ROW KEEPS THE CALLER'S, THE AUDIT EVENT FALLS BACK
--     TO THE DECISION ID. design.md D5 wants two different joins to work:
--     wms_operations-audit-log joining audit_events to agent_decisions on
--     correlation_id, and the agent's own autonomous action (e.g. the
--     wms_retry_work_order_dispatch audit event) sharing a correlation_id with
--     the reasoning it filed for it. Both hold if the COLUMN stores exactly
--     what the caller passed — that is what ties the reasoning to the action —
--     while the audit event this contract writes uses
--     coalesce(p_correlation_id, decision_id::text), so a decision filed with
--     no correlation_id is still reachable from the audit log by its own id.
-- ============================================================

-- ------------------------------------------------------------
-- Table
-- ------------------------------------------------------------

create table wms.agent_decisions (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references wms.tenants(id) on delete cascade,
  warehouse_id uuid not null references wms.warehouses(id) on delete cascade,
  -- V7: open set. Used by this contract: DISPATCH_RETRY (LOGGED),
  -- LABOR_REBALANCE / EQUIPMENT_ROUTING_SUGGESTION (PROPOSED).
  proposal_type text not null,
  -- loose reference, no FK — same pattern as wms.equipment_commands (area 1),
  -- wms.dock_appointments (area 7) and wms.labor_activities (area 8). The
  -- target may be a work order, a machine, a person, or something a later
  -- area invents.
  target_entity_type text,
  target_entity_id uuid,
  -- the signal RPC output the agent was looking at, kept verbatim so a human
  -- reviewing the proposal months later sees what the agent saw
  signals_snapshot jsonb,
  -- the whole point of the table: why. Never null, never blank.
  reasoning text not null,
  -- structured description of the action being proposed (RPC name, candidate
  -- parameters). Reference material for a human — D7: nothing executes it.
  proposed_action jsonb,
  status text not null
    check (status in ('LOGGED', 'PROPOSED', 'CONFIRMED', 'REJECTED')),
  confirmed_by uuid,
  confirmed_at timestamptz,
  rejected_by uuid,
  rejected_at timestamptz,
  rejection_reason text,
  version int not null default 1,
  correlation_id text,
  created_by uuid,
  updated_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint agent_decisions_reasoning_ck
    check (btrim(reasoning) <> ''),
  constraint agent_decisions_proposal_type_ck
    check (btrim(proposal_type) <> ''),
  -- a LOGGED record is a statement about something already done and carries no
  -- proposed action; every other status descends from a proposal and keeps it
  constraint agent_decisions_logged_no_action_ck
    check ((status = 'LOGGED') = (proposed_action is null)),
  constraint agent_decisions_confirmed_pair_ck
    check ((status = 'CONFIRMED') = (confirmed_by is not null and confirmed_at is not null)),
  constraint agent_decisions_rejected_pair_ck
    check ((status = 'REJECTED')
           = (rejected_by is not null and rejected_at is not null
              and btrim(coalesce(rejection_reason, '')) <> '')),
  constraint agent_decisions_target_pair_ck
    check ((target_entity_type is null) = (target_entity_id is null))
);

create index agent_decisions_warehouse_status_idx
  on wms.agent_decisions (warehouse_id, status, created_at desc);
create index agent_decisions_type_idx
  on wms.agent_decisions (warehouse_id, proposal_type);
create index agent_decisions_correlation_idx
  on wms.agent_decisions (correlation_id)
  where correlation_id is not null;
create index agent_decisions_target_idx
  on wms.agent_decisions (target_entity_type, target_entity_id);

comment on table wms.agent_decisions is
  'Agent decision + proposal log (add-agentic-operations D5). LOGGED rows are '
  'append-only statements of "I did X because Y"; PROPOSED rows are requests a '
  'human confirms or rejects. wms_operations-audit-log LEFT JOINs this table to '
  'wms.audit_events on correlation_id to fold the reasoning into its natural-'
  'language summaries — the schema owner is this contract.';

comment on column wms.agent_decisions.proposal_type is
  'Open set (V7). This contract writes DISPATCH_RETRY, LABOR_REBALANCE and '
  'EQUIPMENT_ROUTING_SUGGESTION; follow-up areas may add values without a '
  'migration here.';

-- ============================================================
-- RLS. SELECT-only for tenant/warehouse members, same as every other table in
-- this schema. Every write goes through the SECURITY DEFINER RPCs below; no
-- INSERT/UPDATE/DELETE policy exists, so RLS denies those by default.
--
-- Note this table is deliberately NOT as narrow as wms.labor_activities: an
-- agent's reasoning is an operational record the whole warehouse may audit,
-- not personal productivity data.
-- ============================================================

alter table wms.agent_decisions enable row level security;

create policy agent_decisions_select on wms.agent_decisions for select to authenticated
  using (warehouse_id in (select wms.current_warehouse_ids(tenant_id)));

grant select on wms.agent_decisions to authenticated;

-- ============================================================
-- Internal helper (no grant — same as wms._wms_load_labor_activity)
-- ============================================================

-- Everything confirm and reject both need: existence, warehouse scope, the
-- human-only role gate with an explicit PROCESS_AGENT refusal (D6), the
-- PROPOSED precondition, and optimistic version.
--
-- Order matters and is asserted by the E2E suite: an agent trying to confirm
-- gets FORBIDDEN, not INVALID — the role boundary is reported before anything
-- about the proposal's state is revealed.
create or replace function wms._wms_load_agent_proposal(
  p_decision_id uuid,
  p_expected_version int
) returns wms.agent_decisions
language plpgsql stable security definer
set search_path = wms, public
as $$
declare
  v_row wms.agent_decisions%rowtype;
begin
  select * into v_row from wms.agent_decisions where id = p_decision_id;
  if not found then
    raise exception 'INVALID: unknown agent decision %', p_decision_id;
  end if;
  if v_row.warehouse_id not in (select wms.current_warehouse_ids(v_row.tenant_id)) then
    raise exception 'FORBIDDEN: no warehouse scope for agent decision %', p_decision_id;
  end if;
  -- D6: named explicitly so the error says why, rather than "your role is not
  -- in the list". The generic check below would refuse it anyway — this is the
  -- readable version of the same refusal.
  if wms.has_role(v_row.tenant_id, 'PROCESS_AGENT')
     and not wms.has_role(v_row.tenant_id, 'WAREHOUSE_MANAGER', 'WMS_ADMIN') then
    raise exception
      'FORBIDDEN: PROCESS_AGENT may create proposals but not confirm or reject them (human review is the point)';
  end if;
  if not wms.has_role(v_row.tenant_id, 'WAREHOUSE_MANAGER', 'WMS_ADMIN') then
    raise exception 'FORBIDDEN: role cannot review agent proposals';
  end if;
  if v_row.status <> 'PROPOSED' then
    raise exception 'INVALID: agent decision % is not PROPOSED (status=%)', p_decision_id, v_row.status;
  end if;
  if p_expected_version is not null and v_row.version <> p_expected_version then
    raise exception 'CONFLICT: expected version % but found %', p_expected_version, v_row.version;
  end if;
  return v_row;
end;
$$;

-- ============================================================
-- Command RPCs (writes)
-- Envelope in:  tenant_id / warehouse_id (implied by the target row for
--               id-addressed calls), actor_id, idempotency_key,
--               expected_version, correlation_id.
-- Envelope out: {result, document_id, status, version, next_actions, warnings}.
-- Errors:       RAISE EXCEPTION with CONFLICT:/FORBIDDEN:/INVALID: prefix.
--
-- None of these four touches any table other than wms.agent_decisions (plus
-- the standard audit/idempotency bookkeeping). spec.md "자율 실행 범위의 역할
-- 제한" is a property of this file, and the E2E suite snapshots the other
-- tables around each call to keep it one.
-- ============================================================

create or replace function wms.wms_log_agent_decision(
  p_tenant_id uuid,
  p_warehouse_id uuid,
  p_reasoning text,
  p_actor_id uuid,
  p_idempotency_key uuid,
  p_proposal_type text default 'DISPATCH_RETRY',
  p_target_entity_type text default null,
  p_target_entity_id uuid default null,
  p_signals_snapshot jsonb default null,
  p_correlation_id text default null
) returns jsonb
language plpgsql security definer
set search_path = wms, public
as $$
declare
  v_cached jsonb;
  v_row wms.agent_decisions%rowtype;
begin
  if p_idempotency_key is not null then
    select response into v_cached from wms.idempotency_records
      where tenant_id = p_tenant_id and command_name = 'wms_log_agent_decision'
        and idempotency_key = p_idempotency_key;
    if found then return v_cached; end if;
  end if;

  if p_warehouse_id not in (select wms.current_warehouse_ids(p_tenant_id)) then
    raise exception 'FORBIDDEN: no warehouse scope for %', p_warehouse_id;
  end if;
  if not wms.has_role(p_tenant_id, 'PROCESS_AGENT', 'WMS_ADMIN') then
    raise exception 'FORBIDDEN: role cannot log agent decisions';
  end if;

  if p_reasoning is null or btrim(p_reasoning) = '' then
    raise exception 'INVALID: reasoning is required and must not be blank';
  end if;
  if p_proposal_type is null or btrim(p_proposal_type) = '' then
    raise exception 'INVALID: proposal_type must not be blank';
  end if;
  if (p_target_entity_type is null) <> (p_target_entity_id is null) then
    raise exception 'INVALID: target_entity_type and target_entity_id must be given together';
  end if;

  insert into wms.agent_decisions (
    tenant_id, warehouse_id, proposal_type, target_entity_type, target_entity_id,
    signals_snapshot, reasoning, proposed_action, status,
    correlation_id, created_by, updated_by
  ) values (
    p_tenant_id, p_warehouse_id, p_proposal_type, p_target_entity_type, p_target_entity_id,
    p_signals_snapshot, p_reasoning, null, 'LOGGED',
    p_correlation_id, p_actor_id, p_actor_id
  )
  returning * into v_row;

  -- V8: the row keeps the caller's correlation_id (that is what ties this
  -- reasoning to the action it explains); the audit event falls back to the
  -- decision id so wms_operations-audit-log can always reach it.
  insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, before, after, correlation_id)
  values (p_tenant_id, p_actor_id, 'wms_log_agent_decision', 'agent_decision', v_row.id,
          null, to_jsonb(v_row), coalesce(p_correlation_id, v_row.id::text));

  v_cached := jsonb_build_object(
    'result', 'ok',
    'document_id', v_row.id,
    'decision_id', v_row.id,
    'proposal_type', v_row.proposal_type,
    'status', v_row.status,
    'version', v_row.version,
    'correlation_id', v_row.correlation_id,
    'created_at', v_row.created_at,
    'warnings', '[]'::jsonb,
    -- a LOGGED record is terminal by construction (D5): there is nothing to
    -- confirm, only more to read
    'next_actions', jsonb_build_array('get_agent_decisions')
  );
  if p_idempotency_key is not null then
    insert into wms.idempotency_records (tenant_id, command_name, idempotency_key, response)
    values (p_tenant_id, 'wms_log_agent_decision', p_idempotency_key, v_cached)
    on conflict do nothing;
  end if;
  return v_cached;
end;
$$;

create or replace function wms.wms_propose_agent_action(
  p_tenant_id uuid,
  p_warehouse_id uuid,
  p_proposal_type text,
  p_reasoning text,
  p_proposed_action jsonb,
  p_actor_id uuid,
  p_idempotency_key uuid,
  p_target_entity_type text default null,
  p_target_entity_id uuid default null,
  p_signals_snapshot jsonb default null,
  p_correlation_id text default null
) returns jsonb
language plpgsql security definer
set search_path = wms, public
as $$
declare
  v_cached jsonb;
  v_row wms.agent_decisions%rowtype;
begin
  if p_idempotency_key is not null then
    select response into v_cached from wms.idempotency_records
      where tenant_id = p_tenant_id and command_name = 'wms_propose_agent_action'
        and idempotency_key = p_idempotency_key;
    if found then return v_cached; end if;
  end if;

  if p_warehouse_id not in (select wms.current_warehouse_ids(p_tenant_id)) then
    raise exception 'FORBIDDEN: no warehouse scope for %', p_warehouse_id;
  end if;
  if not wms.has_role(p_tenant_id, 'PROCESS_AGENT', 'WMS_ADMIN') then
    raise exception 'FORBIDDEN: role cannot create agent proposals';
  end if;

  if p_proposal_type is null or btrim(p_proposal_type) = '' then
    raise exception 'INVALID: proposal_type is required';
  end if;
  if p_reasoning is null or btrim(p_reasoning) = '' then
    raise exception 'INVALID: reasoning is required and must not be blank';
  end if;
  -- "비어 있으면 INVALID" covers null, JSON null, {} and [] — an empty object
  -- is not a proposal, it is a missing one.
  if p_proposed_action is null
     or p_proposed_action = 'null'::jsonb
     or p_proposed_action = '{}'::jsonb
     or p_proposed_action = '[]'::jsonb then
    raise exception 'INVALID: proposed_action is required — a proposal with no action is not reviewable';
  end if;
  if (p_target_entity_type is null) <> (p_target_entity_id is null) then
    raise exception 'INVALID: target_entity_type and target_entity_id must be given together';
  end if;

  insert into wms.agent_decisions (
    tenant_id, warehouse_id, proposal_type, target_entity_type, target_entity_id,
    signals_snapshot, reasoning, proposed_action, status,
    correlation_id, created_by, updated_by
  ) values (
    p_tenant_id, p_warehouse_id, p_proposal_type, p_target_entity_type, p_target_entity_id,
    p_signals_snapshot, p_reasoning, p_proposed_action, 'PROPOSED',
    p_correlation_id, p_actor_id, p_actor_id
  )
  returning * into v_row;

  insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, before, after, correlation_id)
  values (p_tenant_id, p_actor_id, 'wms_propose_agent_action', 'agent_decision', v_row.id,
          null, to_jsonb(v_row), coalesce(p_correlation_id, v_row.id::text));

  v_cached := jsonb_build_object(
    'result', 'ok',
    'document_id', v_row.id,
    'decision_id', v_row.id,
    'proposal_type', v_row.proposal_type,
    'status', v_row.status,
    'version', v_row.version,
    'correlation_id', v_row.correlation_id,
    'created_at', v_row.created_at,
    -- D7, said out loud on every proposal: confirming does not execute.
    'warnings', jsonb_build_array('HUMAN_REVIEW_REQUIRED_NO_AUTO_EXECUTION'),
    'next_actions', jsonb_build_array('confirm_agent_proposal', 'reject_agent_proposal')
  );
  if p_idempotency_key is not null then
    insert into wms.idempotency_records (tenant_id, command_name, idempotency_key, response)
    values (p_tenant_id, 'wms_propose_agent_action', p_idempotency_key, v_cached)
    on conflict do nothing;
  end if;
  return v_cached;
end;
$$;

create or replace function wms.wms_confirm_agent_proposal(
  p_decision_id uuid,
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
  v_before wms.agent_decisions%rowtype;
  v_row wms.agent_decisions%rowtype;
  v_tenant_id uuid;
begin
  select tenant_id into v_tenant_id from wms.agent_decisions where id = p_decision_id;
  if p_idempotency_key is not null and v_tenant_id is not null then
    select response into v_cached from wms.idempotency_records
      where tenant_id = v_tenant_id and command_name = 'wms_confirm_agent_proposal'
        and idempotency_key = p_idempotency_key;
    if found then return v_cached; end if;
  end if;

  v_before := wms._wms_load_agent_proposal(p_decision_id, p_expected_version);

  -- D7. This is the entire effect of confirming: a status flag, a signature,
  -- a timestamp. No RPC is looked up, nothing in proposed_action is executed,
  -- no other table is written.
  update wms.agent_decisions
  set status = 'CONFIRMED',
      confirmed_by = p_actor_id,
      confirmed_at = now(),
      version = version + 1,
      updated_by = p_actor_id,
      updated_at = now()
  where id = p_decision_id
  returning * into v_row;

  insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, before, after, correlation_id)
  values (v_row.tenant_id, p_actor_id, 'wms_confirm_agent_proposal', 'agent_decision', v_row.id,
          to_jsonb(v_before), to_jsonb(v_row), coalesce(p_correlation_id, v_row.id::text));

  v_cached := jsonb_build_object(
    'result', 'ok',
    'document_id', v_row.id,
    'decision_id', v_row.id,
    'proposal_type', v_row.proposal_type,
    'status', v_row.status,
    'version', v_row.version,
    'confirmed_by', v_row.confirmed_by,
    'confirmed_at', v_row.confirmed_at,
    'proposed_action', v_row.proposed_action,
    'warnings', jsonb_build_array('CONFIRMED_BUT_NOT_EXECUTED'),
    -- the follow-through is a separate, explicit call by a human or by the
    -- next BPMN step — this contract does not make it
    'next_actions', jsonb_build_array('get_agent_decisions')
  );
  if p_idempotency_key is not null then
    insert into wms.idempotency_records (tenant_id, command_name, idempotency_key, response)
    values (v_row.tenant_id, 'wms_confirm_agent_proposal', p_idempotency_key, v_cached)
    on conflict do nothing;
  end if;
  return v_cached;
end;
$$;

create or replace function wms.wms_reject_agent_proposal(
  p_decision_id uuid,
  p_reason text,
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
  v_before wms.agent_decisions%rowtype;
  v_row wms.agent_decisions%rowtype;
  v_tenant_id uuid;
begin
  select tenant_id into v_tenant_id from wms.agent_decisions where id = p_decision_id;
  if p_idempotency_key is not null and v_tenant_id is not null then
    select response into v_cached from wms.idempotency_records
      where tenant_id = v_tenant_id and command_name = 'wms_reject_agent_proposal'
        and idempotency_key = p_idempotency_key;
    if found then return v_cached; end if;
  end if;

  v_before := wms._wms_load_agent_proposal(p_decision_id, p_expected_version);

  -- Checked after the role/state gates on purpose: "you may not review this"
  -- and "this is already decided" are both more important than "you forgot
  -- the reason field".
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'INVALID: reason is required to reject a proposal';
  end if;

  update wms.agent_decisions
  set status = 'REJECTED',
      rejected_by = p_actor_id,
      rejected_at = now(),
      rejection_reason = p_reason,
      version = version + 1,
      updated_by = p_actor_id,
      updated_at = now()
  where id = p_decision_id
  returning * into v_row;

  insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, before, after, correlation_id)
  values (v_row.tenant_id, p_actor_id, 'wms_reject_agent_proposal', 'agent_decision', v_row.id,
          to_jsonb(v_before), to_jsonb(v_row), coalesce(p_correlation_id, v_row.id::text));

  v_cached := jsonb_build_object(
    'result', 'ok',
    'document_id', v_row.id,
    'decision_id', v_row.id,
    'proposal_type', v_row.proposal_type,
    'status', v_row.status,
    'version', v_row.version,
    'rejected_by', v_row.rejected_by,
    'rejected_at', v_row.rejected_at,
    'rejection_reason', v_row.rejection_reason,
    'warnings', '[]'::jsonb,
    'next_actions', jsonb_build_array('get_agent_decisions')
  );
  if p_idempotency_key is not null then
    insert into wms.idempotency_records (tenant_id, command_name, idempotency_key, response)
    values (v_row.tenant_id, 'wms_reject_agent_proposal', p_idempotency_key, v_cached)
    on conflict do nothing;
  end if;
  return v_cached;
end;
$$;

-- ============================================================
-- Read RPCs (signals + history)
--
-- All four are `stable security definer`, so RLS on the tables they read does
-- NOT apply inside them and every one restates the warehouse-scope check by
-- hand as its first statement. None of them writes anything, including an
-- audit event — observation is not an operational fact.
-- ============================================================

-- ------------------------------------------------------------
-- Labor balance (V1, V2)
-- ------------------------------------------------------------
create or replace function wms.wms_get_labor_balance_signals(
  p_tenant_id uuid,
  p_warehouse_id uuid,
  p_period_start timestamptz default now() - interval '1 day',
  p_period_end timestamptz default now()
) returns jsonb
language plpgsql stable security definer
set search_path = wms, public
as $$
declare
  -- V2. 40% away from the warehouse mean, in either direction.
  c_threshold constant numeric := 0.40;
  v_mean numeric;
  v_worker_count int;
  v_total int;
  v_rows jsonb;
  v_imbalanced int;
  v_notes jsonb := '[]'::jsonb;
begin
  if p_warehouse_id not in (select wms.current_warehouse_ids(p_tenant_id)) then
    raise exception 'FORBIDDEN: no warehouse scope for %', p_warehouse_id;
  end if;
  -- D2's deliberate exception, stated once and here: PROCESS_AGENT sees the
  -- whole warehouse from THIS rpc — and only this one. Its access to
  -- wms.labor_activities rows and to wms_get_labor_leaderboard is unchanged.
  -- Everyone else who is not a manager gets FORBIDDEN rather than a silently
  -- narrowed result, because a narrowed imbalance comparison is a wrong
  -- answer, not a smaller one.
  if not wms.has_role(p_tenant_id, 'WAREHOUSE_MANAGER', 'WMS_ADMIN', 'PROCESS_AGENT') then
    raise exception 'FORBIDDEN: role cannot read warehouse-wide labor balance signals';
  end if;
  if p_period_start is null or p_period_end is null then
    raise exception 'INVALID: period_start and period_end are required';
  end if;
  if p_period_end <= p_period_start then
    raise exception 'INVALID: period_end must be after period_start';
  end if;

  -- V1: area 8's aggregation predicate, one row per actor instead of per
  -- (actor, date, activity_type), at warehouse scope.
  select coalesce(avg(t.completed_count), 0), count(*), coalesce(sum(t.completed_count), 0)
  into v_mean, v_worker_count, v_total
  from (
    select la.actor_id, count(*)::int as completed_count
    from wms.labor_activities la
    where la.tenant_id = p_tenant_id
      and la.warehouse_id = p_warehouse_id
      and la.status = 'COMPLETED'
      and la.completed_at >= p_period_start
      and la.completed_at < p_period_end
    group by la.actor_id
  ) t;

  select coalesce(jsonb_agg(item order by (item->>'completed_count')::int desc,
                                          item->>'actor_email'), '[]'::jsonb)
  into v_rows
  from (
    select jsonb_build_object(
      'actor_id', a.actor_id,
      'actor_email', u.email,
      -- the denormalised snapshot area 8 keeps, so a promotion cannot rewrite
      -- history; a worker who changed role mid-window shows their most recent
      -- one here
      'actor_role', a.actor_role,
      'completed_count', a.completed_count,
      'total_unit_count', a.total_unit_count,
      'total_duration_seconds', a.total_duration_seconds,
      'avg_duration_seconds', case when a.completed_count = 0 then null
                                   else round(a.total_duration_seconds::numeric / a.completed_count, 1) end,
      'mean_completed_count', round(v_mean, 2),
      'deviation_ratio', case when v_mean = 0 then 0
                              else round((a.completed_count - v_mean) / v_mean, 4) end,
      'is_imbalanced', v_worker_count > 1
                       and v_mean > 0
                       and abs((a.completed_count - v_mean) / v_mean) >= c_threshold,
      'direction', case
        when v_mean = 0 or a.completed_count = v_mean then 'AT'
        when a.completed_count > v_mean then 'ABOVE'
        else 'BELOW' end
    ) as item
    from (
      select la.actor_id,
             -- the most recent role snapshot inside the window: area 8
             -- denormalises actor_role per activity so a promotion cannot
             -- rewrite history, which means one worker can legitimately carry
             -- two roles in one window
             (array_agg(la.actor_role order by la.completed_at desc))[1] as actor_role,
             count(*)::int          as completed_count,
             coalesce(sum(la.unit_count), 0) as total_unit_count,
             coalesce(sum(la.duration_seconds), 0)::bigint as total_duration_seconds
      from wms.labor_activities la
      where la.tenant_id = p_tenant_id
        and la.warehouse_id = p_warehouse_id
        and la.status = 'COMPLETED'
        and la.completed_at >= p_period_start
        and la.completed_at < p_period_end
      group by la.actor_id, la.warehouse_id
    ) a
    join auth.users u on u.id = a.actor_id
  ) rows;

  select count(*)::int into v_imbalanced
  from jsonb_array_elements(v_rows) e
  where (e.value->>'is_imbalanced')::boolean;

  if v_worker_count = 0 then
    v_notes := v_notes || jsonb_build_array('NO_COMPLETED_LABOR_ACTIVITY_IN_PERIOD');
  elsif v_worker_count = 1 then
    -- V2: one worker cannot deviate from themselves. Say so rather than
    -- returning is_imbalanced=false as though a comparison happened.
    v_notes := v_notes || jsonb_build_array('SINGLE_WORKER_NO_COMPARISON');
  end if;

  return jsonb_build_object(
    'result', 'ok',
    'tenant_id', p_tenant_id,
    'warehouse_id', p_warehouse_id,
    'period_start', p_period_start,
    'period_end', p_period_end,
    -- always WAREHOUSE — that is the D2 exception, and it is not conditional
    'scope', 'WAREHOUSE',
    'imbalance_threshold', c_threshold,
    'mean_completed_count', round(v_mean, 2),
    'worker_count', v_worker_count,
    'total_completed_count', v_total,
    'imbalanced_count', v_imbalanced,
    'rows', v_rows,
    'row_count', jsonb_array_length(v_rows),
    'notes', v_notes,
    'source', 'wms.labor_activities (wms_labor-management)'
  );
end;
$$;

-- ------------------------------------------------------------
-- Dispatch delay (V3, V4)
-- ------------------------------------------------------------
create or replace function wms.wms_get_dispatch_delay_signals(
  p_tenant_id uuid,
  p_warehouse_id uuid,
  p_wave_id uuid default null,
  p_delay_threshold_minutes int default 15
) returns jsonb
language plpgsql stable security definer
set search_path = wms, public
as $$
declare
  v_now timestamptz := now();
  v_rows jsonb;
  v_queued_total int;
  v_notes jsonb := '[]'::jsonb;
begin
  if p_warehouse_id not in (select wms.current_warehouse_ids(p_tenant_id)) then
    raise exception 'FORBIDDEN: no warehouse scope for %', p_warehouse_id;
  end if;
  if p_delay_threshold_minutes is null or p_delay_threshold_minutes < 0 then
    raise exception 'INVALID: delay_threshold_minutes must be zero or positive';
  end if;

  select count(*)::int into v_queued_total
  from wms.work_orders wo
  where wo.tenant_id = p_tenant_id and wo.warehouse_id = p_warehouse_id
    and wo.status = 'QUEUED'
    and (p_wave_id is null or wo.wave_id = p_wave_id);

  select coalesce(jsonb_agg(item order by (item->>'delay_minutes')::numeric desc), '[]'::jsonb)
  into v_rows
  from (
    select jsonb_build_object(
      'work_order_id', wo.id,
      'work_order_type', wo.work_order_type,
      'linked_entity_type', wo.linked_entity_type,
      'linked_entity_id', wo.linked_entity_id,
      'dispatch_mode', wo.dispatch_mode,
      'wave_id', wo.wave_id,
      'wave_status', w.status,
      'equipment_type', wo.equipment_type,
      'zone_code', wo.zone_code,
      'command_type', wo.command_type,
      'status', wo.status,
      'version', wo.version,
      'reason', wo.reason,
      'created_at', wo.created_at,
      -- V3: waiting since the LAST attempt, not since creation
      'queued_since', wo.updated_at,
      'delay_minutes', round(extract(epoch from (v_now - wo.updated_at))::numeric / 60, 1),
      'age_minutes', round(extract(epoch from (v_now - wo.created_at))::numeric / 60, 1),
      -- V4: the candidate set, computed with the real selection predicate
      'candidate_equipment_count', cand.total,
      'idle_candidate_count', cand.idle,
      'excluded_candidate_count', cand.excluded,
      'bottleneck_candidate_count', cand.bottlenecked,
      'routable_candidate_count', cand.routable,
      'bottleneck_equipment', cand.flagged,
      'delay_causes', (
        case when cand.total = 0
             then jsonb_build_array('NO_EQUIPMENT_REGISTERED') else '[]'::jsonb end
        || case when cand.total > 0 and cand.excluded = cand.total
             then jsonb_build_array('ALL_CANDIDATES_EXCLUDED') else '[]'::jsonb end
        || case when cand.total > 0 and cand.routable = 0
             then jsonb_build_array('NO_IDLE_EQUIPMENT') else '[]'::jsonb end
        || case when cand.routable > 0 and cand.routable_bottlenecked = cand.routable
             then jsonb_build_array('ALL_ROUTABLE_CANDIDATES_BOTTLENECKED')
             when cand.routable_bottlenecked > 0
             then jsonb_build_array('BOTTLENECK_AMONG_CANDIDATES') else '[]'::jsonb end
        -- an unreleased wave is not late, it is not due (20260728 D6)
        || case when wo.dispatch_mode = 'WAVE' and w.status = 'OPEN'
             then jsonb_build_array('WAVE_NOT_RELEASED') else '[]'::jsonb end
      )
    ) as item
    from wms.work_orders wo
    left join wms.dispatch_waves w on w.id = wo.wave_id
    cross join lateral (
      select
        count(*)::int                                          as total,
        count(*) filter (where b.status = 'IDLE')::int          as idle,
        count(*) filter (where b.is_excluded)::int              as excluded,
        count(*) filter (where b.is_bottleneck)::int            as bottlenecked,
        count(*) filter (where not b.is_excluded and b.status = 'IDLE'
                           and b.queue_depth = 0)::int          as routable,
        count(*) filter (where not b.is_excluded and b.status = 'IDLE'
                           and b.queue_depth = 0 and b.is_bottleneck)::int
                                                                as routable_bottlenecked,
        coalesce(jsonb_agg(jsonb_build_object(
          'equipment_id', b.equipment_id,
          'equipment_code', b.equipment_code,
          'equipment_status', b.status,
          'queue_depth', b.queue_depth,
          'recent_fault_count', b.recent_fault_count,
          'bottleneck_reasons', to_jsonb(b.bottleneck_reasons),
          'is_excluded', b.is_excluded
        ) order by b.equipment_code) filter (where b.is_bottleneck or b.is_excluded),
        '[]'::jsonb)                                            as flagged
      from wms.wcs_equipment_bottleneck_status b
      where b.tenant_id = wo.tenant_id
        and b.warehouse_id = wo.warehouse_id
        and b.equipment_type = wo.equipment_type
        -- a null work-order zone means "any zone in this warehouse", exactly
        -- as wms.wcs_select_available_equipment reads it
        and (wo.zone_code is null or b.zone_code = wo.zone_code)
    ) cand
    where wo.tenant_id = p_tenant_id
      and wo.warehouse_id = p_warehouse_id
      and wo.status = 'QUEUED'
      and (p_wave_id is null or wo.wave_id = p_wave_id)
      and wo.updated_at <= v_now - make_interval(mins => p_delay_threshold_minutes)
  ) rows;

  if v_queued_total = 0 then
    v_notes := v_notes || jsonb_build_array('NO_QUEUED_WORK_ORDERS');
  elsif jsonb_array_length(v_rows) = 0 then
    v_notes := v_notes || jsonb_build_array('ALL_QUEUED_WORK_ORDERS_WITHIN_THRESHOLD');
  end if;

  return jsonb_build_object(
    'result', 'ok',
    'tenant_id', p_tenant_id,
    'warehouse_id', p_warehouse_id,
    'wave_id', p_wave_id,
    'delay_threshold_minutes', p_delay_threshold_minutes,
    'evaluated_at', v_now,
    'queued_work_order_count', v_queued_total,
    'delayed_work_order_count', jsonb_array_length(v_rows),
    'rows', v_rows,
    'row_count', jsonb_array_length(v_rows),
    'notes', v_notes,
    'source', 'wms.work_orders (wms_wes-material-flow-control) x '
              'wms.wcs_equipment_bottleneck_status (wms_wcs-bottleneck-routing)'
  );
end;
$$;

-- ------------------------------------------------------------
-- Worker next actions (V5, V6)
-- ------------------------------------------------------------
create or replace function wms.wms_get_worker_next_actions(
  p_tenant_id uuid,
  p_warehouse_id uuid,
  p_actor_id uuid,
  p_include_closed boolean default false
) returns jsonb
language plpgsql stable security definer
set search_path = wms, public
as $$
declare
  v_rows jsonb;
  v_notes jsonb := '[]'::jsonb;
begin
  if p_warehouse_id not in (select wms.current_warehouse_ids(p_tenant_id)) then
    raise exception 'FORBIDDEN: no warehouse scope for %', p_warehouse_id;
  end if;
  if p_actor_id is null then
    raise exception 'INVALID: actor_id is required';
  end if;

  select coalesce(jsonb_agg(item order by item->>'updated_at' desc), '[]'::jsonb)
  into v_rows
  from (
    select jsonb_build_object(
      'item_type', 'receipt',
      'item_id', r.id,
      'status', r.status,
      -- V6: PUTAWAY_COMPLETED is the only terminal state
      'is_open', r.status <> 'PUTAWAY_COMPLETED',
      'po_id', r.po_id,
      'product_id', r.product_id,
      'sku', p.sku,
      'product_name', p.name,
      'expected_qty', r.expected_qty,
      'received_qty', r.received_qty,
      'version', r.version,
      'updated_at', r.updated_at,
      -- V5: why this row is on this worker's list
      'involvement_sources', inv.sources,
      'last_touched_at', inv.last_touched_at,
      'next_actions', case r.status
        when 'EXPECTED'        then jsonb_build_array('register_arrival')
        when 'ARRIVED'         then jsonb_build_array('receive')
        when 'QC_PENDING'      then jsonb_build_array('record_quality_result')
        when 'QC_COMPLETED'    then jsonb_build_array('apply_disposition')
        when 'PUTAWAY_PENDING' then jsonb_build_array('create_putaway_tasks')
        else '[]'::jsonb end
    ) as item
    from wms.receipts r
    join wms.products p on p.id = r.product_id
    cross join lateral (
      -- V5: wms.receipts has no actor column. Involvement is the union of the
      -- four places this repository does record who touched a receipt.
      select
        coalesce(jsonb_agg(distinct s.src), '[]'::jsonb) as sources,
        max(s.at)                                        as last_touched_at
      from (
        select 'audit_event'::text as src, ae.created_at as at
          from wms.audit_events ae
         where ae.tenant_id = r.tenant_id and ae.entity_type = 'receipt'
           and ae.entity_id = r.id and ae.actor_id = p_actor_id
        union all
        select 'quality_inspection', qi.created_at
          from wms.quality_inspections qi
         where qi.receipt_id = r.id and qi.actor_id = p_actor_id
        union all
        select 'inventory_disposition', d.created_at
          from wms.inventory_dispositions d
         where d.receipt_id = r.id and d.actor_id = p_actor_id
        union all
        select 'labor_activity', la.started_at
          from wms.labor_activities la
         where la.linked_entity_type = 'receipt' and la.linked_entity_id = r.id
           and la.actor_id = p_actor_id
      ) s
    ) inv
    where r.tenant_id = p_tenant_id
      and r.warehouse_id = p_warehouse_id
      and jsonb_array_length(inv.sources) > 0
      and (p_include_closed or r.status <> 'PUTAWAY_COMPLETED')
  ) rows;

  if jsonb_array_length(v_rows) = 0 then
    v_notes := v_notes || jsonb_build_array('NO_OPEN_ITEMS_FOR_ACTOR');
  end if;

  return jsonb_build_object(
    'result', 'ok',
    'tenant_id', p_tenant_id,
    'warehouse_id', p_warehouse_id,
    'actor_id', p_actor_id,
    'include_closed', p_include_closed,
    'rows', v_rows,
    'row_count', jsonb_array_length(v_rows),
    'notes', v_notes,
    -- honest about the boundary: this is the material for guidance, not the
    -- guidance itself (design.md D4)
    'source', 'wms.receipts (core schema); involvement derived from audit_events / '
              'quality_inspections / inventory_dispositions / labor_activities'
  );
end;
$$;

-- ------------------------------------------------------------
-- Decision / proposal history
-- ------------------------------------------------------------
create or replace function wms.wms_get_agent_decisions(
  p_tenant_id uuid,
  p_warehouse_id uuid,
  p_status text default null,
  p_proposal_type text default null
) returns jsonb
language plpgsql stable security definer
set search_path = wms, public
as $$
declare
  v_rows jsonb;
  v_counts jsonb;
begin
  if p_warehouse_id not in (select wms.current_warehouse_ids(p_tenant_id)) then
    raise exception 'FORBIDDEN: no warehouse scope for %', p_warehouse_id;
  end if;
  if p_status is not null and p_status not in ('LOGGED', 'PROPOSED', 'CONFIRMED', 'REJECTED') then
    raise exception 'INVALID: status must be one of LOGGED, PROPOSED, CONFIRMED, REJECTED';
  end if;

  select coalesce(jsonb_agg(item order by item->>'created_at' desc), '[]'::jsonb)
  into v_rows
  from (
    select jsonb_build_object(
      'decision_id', d.id,
      'proposal_type', d.proposal_type,
      'target_entity_type', d.target_entity_type,
      'target_entity_id', d.target_entity_id,
      'reasoning', d.reasoning,
      'proposed_action', d.proposed_action,
      'signals_snapshot', d.signals_snapshot,
      'status', d.status,
      'version', d.version,
      'correlation_id', d.correlation_id,
      'is_proposal', d.status <> 'LOGGED',
      'awaiting_review', d.status = 'PROPOSED',
      'created_at', d.created_at,
      'created_by', d.created_by,
      'created_by_email', cu.email,
      'confirmed_by', d.confirmed_by,
      'confirmed_by_email', fu.email,
      'confirmed_at', d.confirmed_at,
      'rejected_by', d.rejected_by,
      'rejected_by_email', ru.email,
      'rejected_at', d.rejected_at,
      'rejection_reason', d.rejection_reason
    ) as item
    from wms.agent_decisions d
    left join auth.users cu on cu.id = d.created_by
    left join auth.users fu on fu.id = d.confirmed_by
    left join auth.users ru on ru.id = d.rejected_by
    where d.tenant_id = p_tenant_id
      and d.warehouse_id = p_warehouse_id
      and (p_status is null or d.status = p_status)
      and (p_proposal_type is null or d.proposal_type = p_proposal_type)
  ) rows;

  -- counts are over the WHOLE warehouse, not the filtered slice, so a review
  -- queue showing only PROPOSED can still say how much history sits behind it
  select jsonb_object_agg(s.status, s.n)
  into v_counts
  from (
    select d.status, count(*)::int as n
    from wms.agent_decisions d
    where d.tenant_id = p_tenant_id and d.warehouse_id = p_warehouse_id
    group by d.status
  ) s;

  return jsonb_build_object(
    'result', 'ok',
    'tenant_id', p_tenant_id,
    'warehouse_id', p_warehouse_id,
    'filter', jsonb_build_object('status', p_status, 'proposal_type', p_proposal_type),
    'rows', v_rows,
    'row_count', jsonb_array_length(v_rows),
    'status_counts', coalesce(v_counts, '{}'::jsonb),
    'pending_review_count',
      coalesce((v_counts->>'PROPOSED')::int, 0)
  );
end;
$$;

-- ============================================================
-- Grants. The internal helper (_wms_load_agent_proposal) is deliberately not
-- granted, matching wms._wms_load_labor_activity and
-- wms._wms_pick_equipment_for_work_order.
-- ============================================================

grant execute on function wms.wms_log_agent_decision(uuid, uuid, text, uuid, uuid, text, text, uuid, jsonb, text) to authenticated;
grant execute on function wms.wms_propose_agent_action(uuid, uuid, text, text, jsonb, uuid, uuid, text, uuid, jsonb, text) to authenticated;
grant execute on function wms.wms_confirm_agent_proposal(uuid, uuid, uuid, int, text) to authenticated;
grant execute on function wms.wms_reject_agent_proposal(uuid, text, uuid, uuid, int, text) to authenticated;
grant execute on function wms.wms_get_labor_balance_signals(uuid, uuid, timestamptz, timestamptz) to authenticated;
grant execute on function wms.wms_get_dispatch_delay_signals(uuid, uuid, uuid, int) to authenticated;
grant execute on function wms.wms_get_worker_next_actions(uuid, uuid, uuid, boolean) to authenticated;
grant execute on function wms.wms_get_agent_decisions(uuid, uuid, text, text) to authenticated;
