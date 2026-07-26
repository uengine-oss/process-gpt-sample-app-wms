-- ============================================================
-- WMS core schema (demo-first vertical slice)
-- Scope: docs/02-contracts.md — shortage -> RFQ -> HITL approval ->
-- PO -> receiving -> quality -> scrap/putaway. See design.md for the
-- full target model; tables/enums here are a deliberate subset.
-- ============================================================

create schema if not exists wms;

-- ------------------------------------------------------------
-- Tenancy & access
-- ------------------------------------------------------------

create table wms.tenants (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name text not null,
  created_at timestamptz not null default now()
);

create table wms.warehouses (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references wms.tenants(id) on delete cascade,
  code text not null,
  name text not null,
  created_at timestamptz not null default now(),
  unique (tenant_id, code)
);

-- WMS_ADMIN / PROCUREMENT_BUYER / PURCHASE_APPROVER / INBOUND_OPERATOR /
-- QUALITY_INSPECTOR / AUDITOR / PROCESS_AGENT (design.md §12, subset used here)
create table wms.memberships (
  user_id uuid not null references auth.users(id) on delete cascade,
  tenant_id uuid not null references wms.tenants(id) on delete cascade,
  role text not null,
  created_at timestamptz not null default now(),
  primary key (user_id, tenant_id)
);

-- explicit warehouse scope; WMS_ADMIN implicitly sees every warehouse in
-- their tenant (see wms.current_warehouse_ids below) without a row here.
create table wms.warehouse_scopes (
  user_id uuid not null,
  tenant_id uuid not null,
  warehouse_id uuid not null references wms.warehouses(id) on delete cascade,
  primary key (user_id, warehouse_id),
  foreign key (user_id, tenant_id) references wms.memberships(user_id, tenant_id) on delete cascade
);

-- ------------------------------------------------------------
-- Master data
-- ------------------------------------------------------------

create table wms.products (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references wms.tenants(id) on delete cascade,
  sku text not null,
  name text not null,
  uom text not null default 'EA',
  reorder_min numeric not null default 0,
  reorder_max numeric not null default 0,
  created_at timestamptz not null default now(),
  unique (tenant_id, sku)
);

create table wms.suppliers (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references wms.tenants(id) on delete cascade,
  name text not null,
  email text,
  created_at timestamptz not null default now()
);

-- ------------------------------------------------------------
-- Procurement: RFQ and PO are the same row across its lifecycle
-- (docs/02-contracts.md 1.3: "RFQ와 PO를 하나의 상태 전이로 단순화")
-- ------------------------------------------------------------

create table wms.purchase_orders (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references wms.tenants(id) on delete cascade,
  warehouse_id uuid not null references wms.warehouses(id) on delete cascade,
  product_id uuid not null references wms.products(id),
  supplier_id uuid references wms.suppliers(id),
  qty numeric not null check (qty > 0),
  unit_price numeric,
  status text not null default 'TO_APPROVE'
    check (status in ('TO_APPROVE', 'APPROVED', 'REJECTED', 'CONFIRMED_PO', 'CANCELLED')),
  version int not null default 1,
  reason text,
  correlation_id text,
  created_by uuid,
  approved_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ------------------------------------------------------------
-- Inbound & quality
-- ------------------------------------------------------------

create table wms.receipts (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references wms.tenants(id) on delete cascade,
  warehouse_id uuid not null references wms.warehouses(id) on delete cascade,
  po_id uuid not null references wms.purchase_orders(id) on delete cascade,
  product_id uuid not null references wms.products(id),
  expected_qty numeric not null,
  received_qty numeric not null default 0,
  -- collapses design.md's RECEIVING/RECEIVED distinction for this slice; see wms_receive()
  status text not null default 'EXPECTED'
    check (status in ('EXPECTED', 'ARRIVED', 'QC_PENDING', 'QC_COMPLETED', 'PUTAWAY_PENDING', 'PUTAWAY_COMPLETED')),
  version int not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table wms.quality_inspections (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references wms.tenants(id) on delete cascade,
  receipt_id uuid not null references wms.receipts(id) on delete cascade,
  product_id uuid not null references wms.products(id),
  result text not null check (result in ('PASSED', 'FAILED')),
  reason_code text,
  actor_id uuid,
  created_at timestamptz not null default now()
);

create table wms.inventory_dispositions (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references wms.tenants(id) on delete cascade,
  receipt_id uuid not null references wms.receipts(id) on delete cascade,
  product_id uuid not null references wms.products(id),
  disposition_type text not null check (disposition_type in ('AVAILABLE', 'SCRAP')),
  qty numeric not null,
  reason_code text,
  actor_id uuid,
  created_at timestamptz not null default now()
);

-- ------------------------------------------------------------
-- Ledger (immutable), idempotency, audit
-- ------------------------------------------------------------

create table wms.stock_ledger_entries (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references wms.tenants(id) on delete cascade,
  warehouse_id uuid not null references wms.warehouses(id) on delete cascade,
  product_id uuid not null references wms.products(id),
  qty_delta numeric not null,
  status text not null check (status in ('RECEIVING', 'QC', 'AVAILABLE', 'SCRAP')),
  source_type text not null,
  source_id uuid,
  created_at timestamptz not null default now(),
  created_by uuid
);

create table wms.idempotency_records (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  command_name text not null,
  idempotency_key uuid not null,
  response jsonb not null,
  created_at timestamptz not null default now(),
  unique (tenant_id, command_name, idempotency_key)
);

create table wms.audit_events (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  actor_id uuid,
  command text not null,
  entity_type text not null,
  entity_id uuid,
  before jsonb,
  after jsonb,
  correlation_id text,
  created_at timestamptz not null default now()
);

-- ------------------------------------------------------------
-- Read views
-- ------------------------------------------------------------

create view wms.inventory_availability_v as
select
  tenant_id,
  warehouse_id,
  product_id,
  coalesce(sum(qty_delta) filter (where status = 'AVAILABLE'), 0) as available_qty,
  coalesce(sum(qty_delta) filter (where status = 'RECEIVING'), 0) as receiving_qty,
  coalesce(sum(qty_delta) filter (where status = 'QC'), 0) as qc_qty,
  coalesce(sum(qty_delta) filter (where status = 'SCRAP'), 0) as scrap_qty
from wms.stock_ledger_entries
group by tenant_id, warehouse_id, product_id;

-- ============================================================
-- RLS helper functions
-- ============================================================

create or replace function wms.current_tenant_ids()
returns setof uuid
language sql stable security definer
set search_path = wms, public
as $$
  select tenant_id from wms.memberships where user_id = auth.uid();
$$;

create or replace function wms.current_warehouse_ids(p_tenant_id uuid)
returns setof uuid
language sql stable security definer
set search_path = wms, public
as $$
  select ws.warehouse_id
  from wms.warehouse_scopes ws
  where ws.user_id = auth.uid() and ws.tenant_id = p_tenant_id
  union
  select w.id
  from wms.warehouses w
  join wms.memberships m on m.tenant_id = w.tenant_id and m.user_id = auth.uid()
  where w.tenant_id = p_tenant_id and m.role = 'WMS_ADMIN';
$$;

create or replace function wms.has_role(p_tenant_id uuid, variadic p_roles text[])
returns boolean
language sql stable security definer
set search_path = wms, public
as $$
  select exists (
    select 1 from wms.memberships
    where user_id = auth.uid() and tenant_id = p_tenant_id and role = any(p_roles)
  );
$$;

grant usage on schema wms to authenticated;
grant execute on function wms.current_tenant_ids() to authenticated;
grant execute on function wms.current_warehouse_ids(uuid) to authenticated;
grant execute on function wms.has_role(uuid, text[]) to authenticated;

-- ============================================================
-- RLS: read-only SELECT for tenant/warehouse members.
-- All writes go through the SECURITY DEFINER RPCs below — no
-- INSERT/UPDATE/DELETE policy is granted to authenticated/anon,
-- so RLS denies those by default (design.md D3).
-- ============================================================

alter table wms.tenants enable row level security;
create policy tenants_select on wms.tenants for select to authenticated
  using (id in (select wms.current_tenant_ids()));

alter table wms.warehouses enable row level security;
create policy warehouses_select on wms.warehouses for select to authenticated
  using (tenant_id in (select wms.current_tenant_ids()));

alter table wms.memberships enable row level security;
create policy memberships_select_self on wms.memberships for select to authenticated
  using (user_id = auth.uid());

alter table wms.products enable row level security;
create policy products_select on wms.products for select to authenticated
  using (tenant_id in (select wms.current_tenant_ids()));

alter table wms.suppliers enable row level security;
create policy suppliers_select on wms.suppliers for select to authenticated
  using (tenant_id in (select wms.current_tenant_ids()));

alter table wms.purchase_orders enable row level security;
create policy purchase_orders_select on wms.purchase_orders for select to authenticated
  using (warehouse_id in (select wms.current_warehouse_ids(tenant_id)));

alter table wms.receipts enable row level security;
create policy receipts_select on wms.receipts for select to authenticated
  using (warehouse_id in (select wms.current_warehouse_ids(tenant_id)));

alter table wms.quality_inspections enable row level security;
create policy quality_inspections_select on wms.quality_inspections for select to authenticated
  using (tenant_id in (select wms.current_tenant_ids()));

alter table wms.inventory_dispositions enable row level security;
create policy inventory_dispositions_select on wms.inventory_dispositions for select to authenticated
  using (tenant_id in (select wms.current_tenant_ids()));

alter table wms.stock_ledger_entries enable row level security;
create policy stock_ledger_entries_select on wms.stock_ledger_entries for select to authenticated
  using (warehouse_id in (select wms.current_warehouse_ids(tenant_id)));

alter table wms.idempotency_records enable row level security;
-- no select policy: idempotency records are an internal RPC concern only.

alter table wms.audit_events enable row level security;
create policy audit_events_select on wms.audit_events for select to authenticated
  using (tenant_id in (select wms.current_tenant_ids()));

grant select on all tables in schema wms to authenticated;
grant select on wms.inventory_availability_v to authenticated;

-- ============================================================
-- Command RPCs (docs/02-contracts.md §1.2)
-- Envelope: tenant_id, warehouse_id, actor_id, idempotency_key,
-- expected_version, correlation_id — see design.md §9.2. Errors use
-- RAISE EXCEPTION with a CONFLICT:/FORBIDDEN:/INVALID: prefix so
-- callers (wms-mcp, frontend) can classify 409/403/422 without a
-- custom Postgres error-code table for this slice.
-- ============================================================

create or replace function wms.wms_check_stock(
  p_tenant_id uuid,
  p_warehouse_id uuid,
  p_sku text
) returns jsonb
language plpgsql stable security definer
set search_path = wms, public
as $$
declare
  v_product wms.products%rowtype;
  v_avail jsonb;
begin
  if p_warehouse_id not in (select wms.current_warehouse_ids(p_tenant_id)) then
    raise exception 'FORBIDDEN: no warehouse scope for %', p_warehouse_id;
  end if;

  select * into v_product from wms.products where tenant_id = p_tenant_id and sku = p_sku;
  if not found then
    raise exception 'INVALID: unknown sku %', p_sku;
  end if;

  select jsonb_build_object(
    'available_qty', coalesce(available_qty, 0),
    'receiving_qty', coalesce(receiving_qty, 0),
    'qc_qty', coalesce(qc_qty, 0),
    'scrap_qty', coalesce(scrap_qty, 0)
  ) into v_avail
  from wms.inventory_availability_v
  where tenant_id = p_tenant_id and warehouse_id = p_warehouse_id and product_id = v_product.id;

  return jsonb_build_object(
    'product_id', v_product.id,
    'sku', v_product.sku,
    'reorder_min', v_product.reorder_min,
    'reorder_max', v_product.reorder_max,
    'availability', coalesce(v_avail, jsonb_build_object('available_qty', 0, 'receiving_qty', 0, 'qc_qty', 0, 'scrap_qty', 0)),
    'below_min', coalesce((v_avail->>'available_qty')::numeric, 0) < v_product.reorder_min
  );
end;
$$;

create or replace function wms.wms_create_rfq(
  p_tenant_id uuid,
  p_warehouse_id uuid,
  p_sku text,
  p_qty numeric,
  p_supplier_id uuid,
  p_actor_id uuid,
  p_idempotency_key uuid,
  p_correlation_id text default null
) returns jsonb
language plpgsql security definer
set search_path = wms, public
as $$
declare
  v_cached jsonb;
  v_product wms.products%rowtype;
  v_po wms.purchase_orders%rowtype;
begin
  if p_idempotency_key is not null then
    select response into v_cached from wms.idempotency_records
      where tenant_id = p_tenant_id and command_name = 'wms_create_rfq' and idempotency_key = p_idempotency_key;
    if found then return v_cached; end if;
  end if;

  if p_warehouse_id not in (select wms.current_warehouse_ids(p_tenant_id)) then
    raise exception 'FORBIDDEN: no warehouse scope for %', p_warehouse_id;
  end if;
  if not wms.has_role(p_tenant_id, 'PROCUREMENT_BUYER', 'WMS_ADMIN', 'PROCESS_AGENT') then
    raise exception 'FORBIDDEN: role cannot create RFQ';
  end if;
  if p_qty <= 0 then
    raise exception 'INVALID: qty must be positive';
  end if;

  select * into v_product from wms.products where tenant_id = p_tenant_id and sku = p_sku;
  if not found then
    raise exception 'INVALID: unknown sku %', p_sku;
  end if;

  insert into wms.purchase_orders (tenant_id, warehouse_id, product_id, supplier_id, qty, status, created_by, correlation_id)
  values (p_tenant_id, p_warehouse_id, v_product.id, p_supplier_id, p_qty, 'TO_APPROVE', p_actor_id, p_correlation_id)
  returning * into v_po;

  insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, after, correlation_id)
  values (p_tenant_id, p_actor_id, 'wms_create_rfq', 'purchase_order', v_po.id, to_jsonb(v_po), p_correlation_id);

  v_cached := jsonb_build_object('po_id', v_po.id, 'status', v_po.status, 'version', v_po.version);
  if p_idempotency_key is not null then
    insert into wms.idempotency_records (tenant_id, command_name, idempotency_key, response)
    values (p_tenant_id, 'wms_create_rfq', p_idempotency_key, v_cached)
    on conflict do nothing;
  end if;
  return v_cached;
end;
$$;

create or replace function wms.wms_submit_purchase_approval(
  p_po_id uuid,
  p_decision text,
  p_approver_id uuid,
  p_expected_version int,
  p_reason text default null
) returns jsonb
language plpgsql security definer
set search_path = wms, public
as $$
declare
  v_po wms.purchase_orders%rowtype;
  v_new_status text;
begin
  select * into v_po from wms.purchase_orders where id = p_po_id;
  if not found then
    raise exception 'INVALID: unknown po %', p_po_id;
  end if;
  if not wms.has_role(v_po.tenant_id, 'PURCHASE_APPROVER', 'WMS_ADMIN') then
    raise exception 'FORBIDDEN: role cannot approve purchases';
  end if;
  if v_po.version <> p_expected_version then
    raise exception 'CONFLICT: expected version % but found %', p_expected_version, v_po.version;
  end if;
  if v_po.status <> 'TO_APPROVE' then
    raise exception 'INVALID: po % is not awaiting approval (status=%)', p_po_id, v_po.status;
  end if;
  if p_decision not in ('APPROVE', 'REJECT') then
    raise exception 'INVALID: decision must be APPROVE or REJECT';
  end if;

  v_new_status := case when p_decision = 'APPROVE' then 'APPROVED' else 'REJECTED' end;

  update wms.purchase_orders
  set status = v_new_status, version = version + 1, approved_by = p_approver_id, reason = p_reason, updated_at = now()
  where id = p_po_id
  returning * into v_po;

  insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, after)
  values (v_po.tenant_id, p_approver_id, 'wms_submit_purchase_approval', 'purchase_order', v_po.id, to_jsonb(v_po));

  return jsonb_build_object('po_id', v_po.id, 'status', v_po.status, 'version', v_po.version);
end;
$$;

create or replace function wms.wms_confirm_purchase_order(
  p_po_id uuid,
  p_actor_id uuid,
  p_idempotency_key uuid,
  p_expected_version int
) returns jsonb
language plpgsql security definer
set search_path = wms, public
as $$
declare
  v_cached jsonb;
  v_po wms.purchase_orders%rowtype;
  v_receipt wms.receipts%rowtype;
  v_tenant_id uuid;
begin
  select tenant_id into v_tenant_id from wms.purchase_orders where id = p_po_id;
  if p_idempotency_key is not null then
    select response into v_cached from wms.idempotency_records
      where tenant_id = v_tenant_id and command_name = 'wms_confirm_purchase_order' and idempotency_key = p_idempotency_key;
    if found then return v_cached; end if;
  end if;

  select * into v_po from wms.purchase_orders where id = p_po_id;
  if not found then
    raise exception 'INVALID: unknown po %', p_po_id;
  end if;
  if not wms.has_role(v_po.tenant_id, 'PROCUREMENT_BUYER', 'WMS_ADMIN', 'PROCESS_AGENT') then
    raise exception 'FORBIDDEN: role cannot confirm purchase orders';
  end if;
  if v_po.version <> p_expected_version then
    raise exception 'CONFLICT: expected version % but found %', p_expected_version, v_po.version;
  end if;
  if v_po.status <> 'APPROVED' then
    raise exception 'INVALID: po % is not approved (status=%)', p_po_id, v_po.status;
  end if;

  update wms.purchase_orders
  set status = 'CONFIRMED_PO', version = version + 1, updated_at = now()
  where id = p_po_id
  returning * into v_po;

  insert into wms.receipts (tenant_id, warehouse_id, po_id, product_id, expected_qty)
  values (v_po.tenant_id, v_po.warehouse_id, v_po.id, v_po.product_id, v_po.qty)
  returning * into v_receipt;

  insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, after)
  values (v_po.tenant_id, p_actor_id, 'wms_confirm_purchase_order', 'purchase_order', v_po.id, to_jsonb(v_po));

  v_cached := jsonb_build_object('po_id', v_po.id, 'status', v_po.status, 'version', v_po.version, 'receipt_id', v_receipt.id);
  if p_idempotency_key is not null then
    insert into wms.idempotency_records (tenant_id, command_name, idempotency_key, response)
    values (v_po.tenant_id, 'wms_confirm_purchase_order', p_idempotency_key, v_cached)
    on conflict do nothing;
  end if;
  return v_cached;
end;
$$;

create or replace function wms.wms_register_arrival(
  p_po_id uuid,
  p_actor_id uuid,
  p_idempotency_key uuid
) returns jsonb
language plpgsql security definer
set search_path = wms, public
as $$
declare
  v_cached jsonb;
  v_receipt wms.receipts%rowtype;
  v_tenant_id uuid;
begin
  select tenant_id into v_tenant_id from wms.receipts where po_id = p_po_id;
  if p_idempotency_key is not null then
    select response into v_cached from wms.idempotency_records
      where tenant_id = v_tenant_id and command_name = 'wms_register_arrival' and idempotency_key = p_idempotency_key;
    if found then return v_cached; end if;
  end if;

  select * into v_receipt from wms.receipts where po_id = p_po_id;
  if not found then
    raise exception 'INVALID: no receipt for po %', p_po_id;
  end if;
  if not wms.has_role(v_receipt.tenant_id, 'INBOUND_OPERATOR', 'WMS_ADMIN', 'PROCESS_AGENT') then
    raise exception 'FORBIDDEN: role cannot register arrivals';
  end if;
  if v_receipt.status <> 'EXPECTED' then
    raise exception 'INVALID: receipt % is not EXPECTED (status=%)', v_receipt.id, v_receipt.status;
  end if;

  update wms.receipts set status = 'ARRIVED', version = version + 1, updated_at = now()
  where id = v_receipt.id
  returning * into v_receipt;

  insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, after)
  values (v_receipt.tenant_id, p_actor_id, 'wms_register_arrival', 'receipt', v_receipt.id, to_jsonb(v_receipt));

  v_cached := jsonb_build_object('receipt_id', v_receipt.id, 'status', v_receipt.status, 'version', v_receipt.version);
  if p_idempotency_key is not null then
    insert into wms.idempotency_records (tenant_id, command_name, idempotency_key, response)
    values (v_receipt.tenant_id, 'wms_register_arrival', p_idempotency_key, v_cached)
    on conflict do nothing;
  end if;
  return v_cached;
end;
$$;

create or replace function wms.wms_receive(
  p_receipt_id uuid,
  p_qty numeric,
  p_actor_id uuid,
  p_idempotency_key uuid,
  p_expected_version int
) returns jsonb
language plpgsql security definer
set search_path = wms, public
as $$
declare
  v_cached jsonb;
  v_receipt wms.receipts%rowtype;
  v_tenant_id uuid;
begin
  select tenant_id into v_tenant_id from wms.receipts where id = p_receipt_id;
  if p_idempotency_key is not null then
    select response into v_cached from wms.idempotency_records
      where tenant_id = v_tenant_id and command_name = 'wms_receive' and idempotency_key = p_idempotency_key;
    if found then return v_cached; end if;
  end if;

  select * into v_receipt from wms.receipts where id = p_receipt_id;
  if not found then
    raise exception 'INVALID: unknown receipt %', p_receipt_id;
  end if;
  if not wms.has_role(v_receipt.tenant_id, 'INBOUND_OPERATOR', 'WMS_ADMIN', 'PROCESS_AGENT') then
    raise exception 'FORBIDDEN: role cannot record receiving';
  end if;
  if v_receipt.version <> p_expected_version then
    raise exception 'CONFLICT: expected version % but found %', p_expected_version, v_receipt.version;
  end if;
  if v_receipt.status <> 'ARRIVED' then
    raise exception 'INVALID: receipt % is not ARRIVED (status=%)', p_receipt_id, v_receipt.status;
  end if;
  if p_qty <= 0 then
    raise exception 'INVALID: qty must be positive';
  end if;

  update wms.receipts
  set received_qty = received_qty + p_qty, status = 'QC_PENDING', version = version + 1, updated_at = now()
  where id = p_receipt_id
  returning * into v_receipt;

  insert into wms.stock_ledger_entries (tenant_id, warehouse_id, product_id, qty_delta, status, source_type, source_id, created_by)
  values (v_receipt.tenant_id, v_receipt.warehouse_id, v_receipt.product_id, p_qty, 'QC', 'receipt', v_receipt.id, p_actor_id);

  insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, after)
  values (v_receipt.tenant_id, p_actor_id, 'wms_receive', 'receipt', v_receipt.id, to_jsonb(v_receipt));

  v_cached := jsonb_build_object('receipt_id', v_receipt.id, 'status', v_receipt.status, 'version', v_receipt.version, 'received_qty', v_receipt.received_qty);
  if p_idempotency_key is not null then
    insert into wms.idempotency_records (tenant_id, command_name, idempotency_key, response)
    values (v_receipt.tenant_id, 'wms_receive', p_idempotency_key, v_cached)
    on conflict do nothing;
  end if;
  return v_cached;
end;
$$;

create or replace function wms.wms_record_quality_result(
  p_receipt_id uuid,
  p_result text,
  p_reason_code text,
  p_actor_id uuid,
  p_idempotency_key uuid
) returns jsonb
language plpgsql security definer
set search_path = wms, public
as $$
declare
  v_cached jsonb;
  v_receipt wms.receipts%rowtype;
  v_next_status text;
begin
  select * into v_receipt from wms.receipts where id = p_receipt_id;
  if not found then
    raise exception 'INVALID: unknown receipt %', p_receipt_id;
  end if;
  if p_idempotency_key is not null then
    select response into v_cached from wms.idempotency_records
      where tenant_id = v_receipt.tenant_id and command_name = 'wms_record_quality_result' and idempotency_key = p_idempotency_key;
    if found then return v_cached; end if;
  end if;
  if v_receipt.status <> 'QC_PENDING' then
    raise exception 'INVALID: receipt % is not QC_PENDING (status=%)', p_receipt_id, v_receipt.status;
  end if;
  if p_result not in ('PASSED', 'FAILED') then
    raise exception 'INVALID: result must be PASSED or FAILED';
  end if;
  if not wms.has_role(v_receipt.tenant_id, 'QUALITY_INSPECTOR', 'WMS_ADMIN') then
    raise exception 'FORBIDDEN: role cannot record quality result';
  end if;

  insert into wms.quality_inspections (tenant_id, receipt_id, product_id, result, reason_code, actor_id)
  values (v_receipt.tenant_id, v_receipt.id, v_receipt.product_id, p_result, p_reason_code, p_actor_id);

  v_next_status := case when p_result = 'PASSED' then 'PUTAWAY_PENDING' else 'QC_COMPLETED' end;

  update wms.receipts set status = v_next_status, version = version + 1, updated_at = now()
  where id = p_receipt_id
  returning * into v_receipt;

  insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, after)
  values (v_receipt.tenant_id, p_actor_id, 'wms_record_quality_result', 'receipt', v_receipt.id, to_jsonb(v_receipt));

  v_cached := jsonb_build_object('receipt_id', v_receipt.id, 'status', v_receipt.status, 'version', v_receipt.version, 'result', p_result);
  if p_idempotency_key is not null then
    insert into wms.idempotency_records (tenant_id, command_name, idempotency_key, response)
    values (v_receipt.tenant_id, 'wms_record_quality_result', p_idempotency_key, v_cached)
    on conflict do nothing;
  end if;
  return v_cached;
end;
$$;

-- Disposition helper shared by scrap and putaway paths: closes out the
-- QC-held quantity and opens the terminal ledger status in one movement.
create or replace function wms._wms_finalize_disposition(
  p_receipt wms.receipts,
  p_disposition_type text,
  p_reason_code text,
  p_actor_id uuid
) returns jsonb
language plpgsql security definer
set search_path = wms, public
as $$
begin
  insert into wms.stock_ledger_entries (tenant_id, warehouse_id, product_id, qty_delta, status, source_type, source_id, created_by)
  values (p_receipt.tenant_id, p_receipt.warehouse_id, p_receipt.product_id, -p_receipt.received_qty, 'QC', 'disposition', p_receipt.id, p_actor_id);

  insert into wms.stock_ledger_entries (tenant_id, warehouse_id, product_id, qty_delta, status, source_type, source_id, created_by)
  values (p_receipt.tenant_id, p_receipt.warehouse_id, p_receipt.product_id, p_receipt.received_qty, p_disposition_type, 'disposition', p_receipt.id, p_actor_id);

  insert into wms.inventory_dispositions (tenant_id, receipt_id, product_id, disposition_type, qty, reason_code, actor_id)
  values (p_receipt.tenant_id, p_receipt.id, p_receipt.product_id, p_disposition_type, p_receipt.received_qty, p_reason_code, p_actor_id);

  update wms.receipts set status = 'PUTAWAY_COMPLETED', version = version + 1, updated_at = now()
  where id = p_receipt.id;

  return jsonb_build_object('receipt_id', p_receipt.id, 'status', 'PUTAWAY_COMPLETED', 'disposition_type', p_disposition_type, 'qty', p_receipt.received_qty);
end;
$$;

create or replace function wms.wms_apply_disposition(
  p_receipt_id uuid,
  p_reason_code text,
  p_actor_id uuid,
  p_idempotency_key uuid
) returns jsonb
language plpgsql security definer
set search_path = wms, public
as $$
declare
  v_cached jsonb;
  v_receipt wms.receipts%rowtype;
begin
  select * into v_receipt from wms.receipts where id = p_receipt_id;
  if not found then
    raise exception 'INVALID: unknown receipt %', p_receipt_id;
  end if;
  if p_idempotency_key is not null then
    select response into v_cached from wms.idempotency_records
      where tenant_id = v_receipt.tenant_id and command_name = 'wms_apply_disposition' and idempotency_key = p_idempotency_key;
    if found then return v_cached; end if;
  end if;
  if v_receipt.status <> 'QC_COMPLETED' then
    raise exception 'INVALID: receipt % is not a failed-QC receipt awaiting disposition (status=%)', p_receipt_id, v_receipt.status;
  end if;
  if not wms.has_role(v_receipt.tenant_id, 'QUALITY_INSPECTOR', 'WMS_ADMIN') then
    raise exception 'FORBIDDEN: role cannot apply disposition';
  end if;
  if p_reason_code is null or p_reason_code = '' then
    raise exception 'INVALID: reason_code is required for scrap';
  end if;

  v_cached := wms._wms_finalize_disposition(v_receipt, 'SCRAP', p_reason_code, p_actor_id);

  insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, after)
  values (v_receipt.tenant_id, p_actor_id, 'wms_apply_disposition', 'receipt', v_receipt.id, v_cached);

  if p_idempotency_key is not null then
    insert into wms.idempotency_records (tenant_id, command_name, idempotency_key, response)
    values (v_receipt.tenant_id, 'wms_apply_disposition', p_idempotency_key, v_cached)
    on conflict do nothing;
  end if;
  return v_cached;
end;
$$;

create or replace function wms.wms_create_putaway_tasks(
  p_receipt_id uuid,
  p_actor_id uuid,
  p_idempotency_key uuid
) returns jsonb
language plpgsql security definer
set search_path = wms, public
as $$
declare
  v_cached jsonb;
  v_receipt wms.receipts%rowtype;
begin
  select * into v_receipt from wms.receipts where id = p_receipt_id;
  if not found then
    raise exception 'INVALID: unknown receipt %', p_receipt_id;
  end if;
  if p_idempotency_key is not null then
    select response into v_cached from wms.idempotency_records
      where tenant_id = v_receipt.tenant_id and command_name = 'wms_create_putaway_tasks' and idempotency_key = p_idempotency_key;
    if found then return v_cached; end if;
  end if;
  if v_receipt.status <> 'PUTAWAY_PENDING' then
    raise exception 'INVALID: receipt % is not PUTAWAY_PENDING (status=%)', p_receipt_id, v_receipt.status;
  end if;
  if not wms.has_role(v_receipt.tenant_id, 'INBOUND_OPERATOR', 'WMS_ADMIN', 'PROCESS_AGENT') then
    raise exception 'FORBIDDEN: role cannot execute putaway';
  end if;

  -- collapses task-lifecycle (7.1) into a single call for this slice.
  v_cached := wms._wms_finalize_disposition(v_receipt, 'AVAILABLE', null, p_actor_id);

  insert into wms.audit_events (tenant_id, actor_id, command, entity_type, entity_id, after)
  values (v_receipt.tenant_id, p_actor_id, 'wms_create_putaway_tasks', 'receipt', v_receipt.id, v_cached);

  if p_idempotency_key is not null then
    insert into wms.idempotency_records (tenant_id, command_name, idempotency_key, response)
    values (v_receipt.tenant_id, 'wms_create_putaway_tasks', p_idempotency_key, v_cached)
    on conflict do nothing;
  end if;
  return v_cached;
end;
$$;

grant execute on function wms.wms_check_stock(uuid, uuid, text) to authenticated;
grant execute on function wms.wms_create_rfq(uuid, uuid, text, numeric, uuid, uuid, uuid, text) to authenticated;
grant execute on function wms.wms_submit_purchase_approval(uuid, text, uuid, int, text) to authenticated;
grant execute on function wms.wms_confirm_purchase_order(uuid, uuid, uuid, int) to authenticated;
grant execute on function wms.wms_register_arrival(uuid, uuid, uuid) to authenticated;
grant execute on function wms.wms_receive(uuid, numeric, uuid, uuid, int) to authenticated;
grant execute on function wms.wms_record_quality_result(uuid, text, text, uuid, uuid) to authenticated;
grant execute on function wms.wms_apply_disposition(uuid, text, uuid, uuid) to authenticated;
grant execute on function wms.wms_create_putaway_tasks(uuid, uuid, uuid) to authenticated;
