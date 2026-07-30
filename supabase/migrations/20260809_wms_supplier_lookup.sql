-- ============================================================
-- Supplier lookup (read-only) — companion to wms_create_rfq's optional
-- p_supplier_id. Until now the only way to resolve a supplier name/email
-- to its UUID (or browse a tenant's supplier list) was a direct table
-- select against wms.suppliers, which bypasses the envelope/tenant-scope
-- convention every other wms_* RPC follows. This closes that gap with the
-- same stable/security definer/tenant-scoped shape as wms_check_stock.
-- ============================================================

create or replace function wms.wms_list_suppliers(
  p_tenant_id text,
  p_query text default null
) returns jsonb
language plpgsql stable security definer
set search_path = wms, public
as $$
declare
  v_suppliers jsonb;
begin
  if p_tenant_id not in (select wms.current_tenant_ids()) then
    raise exception 'FORBIDDEN: no membership for tenant %', p_tenant_id;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'supplier_id', s.id,
    'name', s.name,
    'email', s.email
  ) order by s.name), '[]'::jsonb)
  into v_suppliers
  from wms.suppliers s
  where s.tenant_id = p_tenant_id
    and (
      p_query is null
      or s.name ilike '%' || p_query || '%'
      or s.email ilike '%' || p_query || '%'
    );

  return jsonb_build_object('tenant_id', p_tenant_id, 'suppliers', v_suppliers);
end;
$$;

grant execute on function wms.wms_list_suppliers(text, text) to authenticated;
