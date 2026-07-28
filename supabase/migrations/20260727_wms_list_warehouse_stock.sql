-- ============================================================
-- Tenant-wide stock listing: all warehouses in scope for the tenant,
-- each with every product's availability (companion read to
-- wms_check_stock, which is scoped to a single warehouse/sku).
-- ============================================================

create or replace function wms.wms_list_warehouse_stock(
  p_tenant_id uuid
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

grant execute on function wms.wms_list_warehouse_stock(uuid) to authenticated;
