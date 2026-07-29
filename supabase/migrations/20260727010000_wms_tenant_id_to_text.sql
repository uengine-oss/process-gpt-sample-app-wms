-- ============================================================
-- tenant_id: uuid -> text.
-- WMS tenant identity now aligns with ProcessGPT's tenant_id (e.g.
-- "localhost"), which is not a UUID. wms.tenants.id is the PK all
-- tenant_id columns/FKs point at, so it changes too. FK constraints
-- and the view/functions that reference these columns must be
-- dropped before the ALTER and recreated after.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Drop dependents: view, RLS policies (they call the functions
--    we're about to drop and recreate below), then the functions.
-- ------------------------------------------------------------

drop view if exists wms.inventory_availability_v;

drop policy if exists tenants_select on wms.tenants;
drop policy if exists warehouses_select on wms.warehouses;
drop policy if exists products_select on wms.products;
drop policy if exists suppliers_select on wms.suppliers;
drop policy if exists purchase_orders_select on wms.purchase_orders;
drop policy if exists receipts_select on wms.receipts;
drop policy if exists quality_inspections_select on wms.quality_inspections;
drop policy if exists inventory_dispositions_select on wms.inventory_dispositions;
drop policy if exists stock_ledger_entries_select on wms.stock_ledger_entries;
drop policy if exists audit_events_select on wms.audit_events;

drop function if exists wms.wms_list_warehouse_stock(uuid);
drop function if exists wms.wms_create_rfq(uuid, uuid, text, numeric, uuid, uuid, uuid, text);
drop function if exists wms.wms_check_stock(uuid, uuid, text);
drop function if exists wms.current_warehouse_ids(uuid);
drop function if exists wms.has_role(uuid, text[]);
drop function if exists wms.current_tenant_ids();

-- ------------------------------------------------------------
-- 2. Drop FK constraints that pin tenant_id/tenants.id to uuid.
--    Names are Postgres's default <table>_<column>_fkey.
-- ------------------------------------------------------------

alter table wms.warehouses drop constraint warehouses_tenant_id_fkey;
alter table wms.memberships drop constraint memberships_tenant_id_fkey;
alter table wms.warehouse_scopes drop constraint warehouse_scopes_user_id_tenant_id_fkey;
alter table wms.products drop constraint products_tenant_id_fkey;
alter table wms.suppliers drop constraint suppliers_tenant_id_fkey;
alter table wms.purchase_orders drop constraint purchase_orders_tenant_id_fkey;
alter table wms.receipts drop constraint receipts_tenant_id_fkey;
alter table wms.quality_inspections drop constraint quality_inspections_tenant_id_fkey;
alter table wms.inventory_dispositions drop constraint inventory_dispositions_tenant_id_fkey;
alter table wms.stock_ledger_entries drop constraint stock_ledger_entries_tenant_id_fkey;

-- ------------------------------------------------------------
-- 3. Alter column types. tenants.id loses its uuid default — tenant
--    ids are now supplied by the caller (ProcessGPT tenant_id).
-- ------------------------------------------------------------

alter table wms.tenants alter column id drop default;
alter table wms.tenants alter column id type text using id::text;

alter table wms.warehouses alter column tenant_id type text using tenant_id::text;
alter table wms.memberships alter column tenant_id type text using tenant_id::text;
alter table wms.warehouse_scopes alter column tenant_id type text using tenant_id::text;
alter table wms.products alter column tenant_id type text using tenant_id::text;
alter table wms.suppliers alter column tenant_id type text using tenant_id::text;
alter table wms.purchase_orders alter column tenant_id type text using tenant_id::text;
alter table wms.receipts alter column tenant_id type text using tenant_id::text;
alter table wms.quality_inspections alter column tenant_id type text using tenant_id::text;
alter table wms.inventory_dispositions alter column tenant_id type text using tenant_id::text;
alter table wms.stock_ledger_entries alter column tenant_id type text using tenant_id::text;
alter table wms.idempotency_records alter column tenant_id type text using tenant_id::text;
alter table wms.audit_events alter column tenant_id type text using tenant_id::text;

-- ------------------------------------------------------------
-- 4. Re-add FK constraints (default names regenerate unchanged).
-- ------------------------------------------------------------

alter table wms.warehouses add foreign key (tenant_id) references wms.tenants(id) on delete cascade;
alter table wms.memberships add foreign key (tenant_id) references wms.tenants(id) on delete cascade;
alter table wms.warehouse_scopes add foreign key (user_id, tenant_id) references wms.memberships(user_id, tenant_id) on delete cascade;
alter table wms.products add foreign key (tenant_id) references wms.tenants(id) on delete cascade;
alter table wms.suppliers add foreign key (tenant_id) references wms.tenants(id) on delete cascade;
alter table wms.purchase_orders add foreign key (tenant_id) references wms.tenants(id) on delete cascade;
alter table wms.receipts add foreign key (tenant_id) references wms.tenants(id) on delete cascade;
alter table wms.quality_inspections add foreign key (tenant_id) references wms.tenants(id) on delete cascade;
alter table wms.inventory_dispositions add foreign key (tenant_id) references wms.tenants(id) on delete cascade;
alter table wms.stock_ledger_entries add foreign key (tenant_id) references wms.tenants(id) on delete cascade;

-- ------------------------------------------------------------
-- 5. Recreate the view (unchanged shape, tenant_id is now text).
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

grant select on wms.inventory_availability_v to authenticated;

-- ------------------------------------------------------------
-- 6. Recreate RLS helper functions with p_tenant_id/tenant_id text.
-- ------------------------------------------------------------

create or replace function wms.current_tenant_ids()
returns setof text
language sql stable security definer
set search_path = wms, public
as $$
  select tenant_id from wms.memberships where user_id = auth.uid();
$$;

create or replace function wms.current_warehouse_ids(p_tenant_id text)
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

create or replace function wms.has_role(p_tenant_id text, variadic p_roles text[])
returns boolean
language sql stable security definer
set search_path = wms, public
as $$
  select exists (
    select 1 from wms.memberships
    where user_id = auth.uid() and tenant_id = p_tenant_id and role = any(p_roles)
  );
$$;

grant execute on function wms.current_tenant_ids() to authenticated;
grant execute on function wms.current_warehouse_ids(text) to authenticated;
grant execute on function wms.has_role(text, text[]) to authenticated;

-- ------------------------------------------------------------
-- 7. Recreate RLS policies (unchanged bodies; functions now take text).
-- ------------------------------------------------------------

create policy tenants_select on wms.tenants for select to authenticated
  using (id in (select wms.current_tenant_ids()));

create policy warehouses_select on wms.warehouses for select to authenticated
  using (tenant_id in (select wms.current_tenant_ids()));

create policy products_select on wms.products for select to authenticated
  using (tenant_id in (select wms.current_tenant_ids()));

create policy suppliers_select on wms.suppliers for select to authenticated
  using (tenant_id in (select wms.current_tenant_ids()));

create policy purchase_orders_select on wms.purchase_orders for select to authenticated
  using (warehouse_id in (select wms.current_warehouse_ids(tenant_id)));

create policy receipts_select on wms.receipts for select to authenticated
  using (warehouse_id in (select wms.current_warehouse_ids(tenant_id)));

create policy quality_inspections_select on wms.quality_inspections for select to authenticated
  using (tenant_id in (select wms.current_tenant_ids()));

create policy inventory_dispositions_select on wms.inventory_dispositions for select to authenticated
  using (tenant_id in (select wms.current_tenant_ids()));

create policy stock_ledger_entries_select on wms.stock_ledger_entries for select to authenticated
  using (warehouse_id in (select wms.current_warehouse_ids(tenant_id)));

create policy audit_events_select on wms.audit_events for select to authenticated
  using (tenant_id in (select wms.current_tenant_ids()));

-- ------------------------------------------------------------
-- 8. Recreate command/read RPCs with p_tenant_id text.
-- ------------------------------------------------------------

create or replace function wms.wms_check_stock(
  p_tenant_id text,
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
  p_tenant_id text,
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

create or replace function wms.wms_list_warehouse_stock(
  p_tenant_id text
) returns jsonb
language plpgsql stable security definer
set search_path = wms, public
as $$
declare
  v_warehouses jsonb;
begin
  select coalesce(jsonb_agg(w_row order by w_row->>'code'), '[]'::jsonb)
  into v_warehouses
  from (
    select jsonb_build_object(
      'warehouse_id', w.id,
      'code', w.code,
      'name', w.name,
      'items', coalesce((
        select jsonb_agg(jsonb_build_object(
          'product_id', p.id,
          'sku', p.sku,
          'name', p.name,
          'uom', p.uom,
          'reorder_min', p.reorder_min,
          'reorder_max', p.reorder_max,
          'available_qty', coalesce(a.available_qty, 0),
          'receiving_qty', coalesce(a.receiving_qty, 0),
          'qc_qty', coalesce(a.qc_qty, 0),
          'scrap_qty', coalesce(a.scrap_qty, 0),
          'below_min', coalesce(a.available_qty, 0) < p.reorder_min
        ) order by p.sku)
        from wms.products p
        left join wms.inventory_availability_v a
          on a.tenant_id = p.tenant_id and a.warehouse_id = w.id and a.product_id = p.id
        where p.tenant_id = p_tenant_id
      ), '[]'::jsonb)
    ) as w_row
    from wms.warehouses w
    where w.tenant_id = p_tenant_id
      and w.id in (select wms.current_warehouse_ids(p_tenant_id))
  ) sub;

  return jsonb_build_object('tenant_id', p_tenant_id, 'warehouses', v_warehouses);
end;
$$;

grant execute on function wms.wms_check_stock(text, uuid, text) to authenticated;
grant execute on function wms.wms_create_rfq(text, uuid, text, numeric, uuid, uuid, uuid, text) to authenticated;
grant execute on function wms.wms_list_warehouse_stock(text) to authenticated;
