-- ============================================================
-- Multi-tenant auto-provisioning for production.
--
-- seed.sql only runs on local `supabase start`/`db reset`. On a shared
-- SaaS Supabase project, a ProcessGPT tenant that talks to wms-mcp for the
-- first time has no wms.tenants row, no warehouse, no membership — every
-- wms_* RPC call fails (either FK errors or FORBIDDEN from has_role/
-- current_warehouse_ids). This RPC lets wms-mcp provision a brand-new
-- tenant on first contact instead of requiring a manual seed step per
-- tenant, without giving the MCP direct table-write access: it stays a
-- single SECURITY DEFINER RPC call like every other write path in this
-- schema (design.md D3 — no INSERT/UPDATE/DELETE policy is granted to
-- authenticated/anon; RPCs are the only way in).
--
-- Unlike every other RPC in this schema, this one is granted to
-- service_role only, not authenticated (see the grant at the bottom) — it
-- assigns tenant membership/roles by caller-supplied email, which would be
-- a cross-tenant privilege-escalation hole if any signed-in user could call
-- it. wms-mcp calls it with a dedicated service_role key kept server-side
-- (mcp/wms_mcp/client.py's `_service_role_client`), separate from the
-- per-identity anon-key sessions it uses for every actual business RPC.
--
-- Idempotent by construction: tenant/warehouse/demo-data creation runs at
-- most once per tenant. An advisory xact lock keyed on the tenant id
-- serializes concurrent calls for the same tenant (wms-mcp may fire several
-- tool calls back-to-back, and an instructor's onboarding call can race
-- one of those) so only one call does the tenant/warehouse insert; the
-- membership grants below are re-checked (on conflict do nothing) so a
-- later call adding an identity/trainee the earlier call didn't know about
-- is still safe to run against an already-provisioned tenant.
--
-- Grants membership + warehouse scope to whichever of the three fixed
-- service identities (PROCESS_AGENT / WCS_GATEWAY / AUDITOR) it's given an
-- email for — those are shared logins reused across every tenant (see
-- mcp/wms_mcp/client.py), not created per tenant; only the membership row
-- is new here. Emails are optional so this also works if a deployment only
-- wires up a subset of the three identities.
--
-- p_trainee_email/p_trainee_role: the human trainee who owns this tenant in
-- a multi-tenant training deployment. This is deliberately an *admin-supplied*
-- parameter, not something derived from the calling session — a training
-- instructor (or a trusted ProcessGPT-side provisioning step running with
-- elevated credentials) calls this once per trainee with their real login
-- email, the same way the three service identities above are wired up. It
-- is NOT safe to let an arbitrary authenticated caller self-grant membership
-- on any tenant_id they name (this Supabase project is shared with
-- ProcessGPT's own production data once deployed) — that would let any
-- signed-in user hand themselves WMS_ADMIN on someone else's tenant just by
-- guessing/observing a tenant_id. wms-frontend therefore never calls this
-- RPC itself; it is only ever invoked from wms-mcp (service identities) or
-- from a trusted admin/instructor path (trainee identity).
--
-- Demo master data (products/suppliers/opening stock) mirrors seed.sql's
-- tenant-A fixtures so a fresh tenant's WMS screens aren't empty on first
-- login, including one SKU already below reorder_min so the shortage ->
-- RFQ demo flow has something to react to immediately.
-- ============================================================

create or replace function wms.wms_ensure_tenant_provisioned(
  p_tenant_id text,
  p_process_agent_email text default null,
  p_wcs_gateway_email text default null,
  p_auditor_email text default null,
  p_tenant_name text default null,
  p_trainee_email text default null,
  p_trainee_role text default 'WMS_ADMIN'
) returns void
language plpgsql
security definer
set search_path = wms, public, auth
as $$
declare
  v_warehouse_id uuid;
  v_user_id uuid;
  v_product_id uuid;
  v_already_provisioned boolean;
begin
  if p_tenant_id is null or p_tenant_id = '' then
    raise exception 'INVALID: p_tenant_id is required';
  end if;

  -- Serialize concurrent first-calls for this tenant; re-check after the
  -- lock in case a racing call finished provisioning while we waited. The
  -- lock is held for the rest of the transaction so the trainee-membership
  -- grant below (which can run standalone against an already-provisioned
  -- tenant, e.g. an instructor onboarding a trainee after wms-mcp already
  -- touched the tenant) is also serialized against a concurrent first call.
  perform pg_advisory_xact_lock(hashtext(p_tenant_id));
  v_already_provisioned := exists (select 1 from wms.tenants where id = p_tenant_id);

  if v_already_provisioned then
    select id into v_warehouse_id from wms.warehouses where tenant_id = p_tenant_id order by created_at limit 1;
  else
    insert into wms.tenants (id, code, name)
    values (p_tenant_id, p_tenant_id, coalesce(p_tenant_name, p_tenant_id));

    insert into wms.warehouses (tenant_id, code, name)
    values (p_tenant_id, 'WH-01', 'Main Warehouse')
    returning id into v_warehouse_id;

    insert into wms.products (tenant_id, sku, name, uom, reorder_min, reorder_max) values
      (p_tenant_id, 'SKU-A-001', 'Corrugated Box (Medium)', 'EA', 50, 200),
      (p_tenant_id, 'SKU-A-002', 'Pallet Wrap Roll', 'EA', 20, 100),
      (p_tenant_id, 'SKU-A-003', 'Barcode Scanner Battery', 'EA', 10, 50);

    insert into wms.suppliers (tenant_id, name, email) values
      (p_tenant_id, 'Acme Packaging Co.', 'sales@acme-packaging.demo'),
      (p_tenant_id, 'Northwind Supplies', 'orders@northwind-supplies.demo');

    -- Opening stock: SKU-A-001 seeded below reorder_min so the shortage ->
    -- RFQ flow has something to detect without an extra setup step.
    select id into v_product_id from wms.products where tenant_id = p_tenant_id and sku = 'SKU-A-001';
    insert into wms.stock_ledger_entries (tenant_id, warehouse_id, product_id, qty_delta, status, source_type, source_id)
    values (p_tenant_id, v_warehouse_id, v_product_id, 30, 'AVAILABLE', 'opening_balance', null);

    select id into v_product_id from wms.products where tenant_id = p_tenant_id and sku = 'SKU-A-002';
    insert into wms.stock_ledger_entries (tenant_id, warehouse_id, product_id, qty_delta, status, source_type, source_id)
    values (p_tenant_id, v_warehouse_id, v_product_id, 60, 'AVAILABLE', 'opening_balance', null);
  end if;

  -- Service-identity + trainee membership grants run every call (not just on
  -- first creation), keyed off which email params are given, so a later call
  -- can add an identity/trainee the earlier call didn't know about yet
  -- without re-touching anything else.
  if p_process_agent_email is not null then
    select id into v_user_id from auth.users where email = p_process_agent_email;
    if found then
      insert into wms.memberships (user_id, tenant_id, role)
      values (v_user_id, p_tenant_id, 'PROCESS_AGENT')
      on conflict (user_id, tenant_id) do nothing;
      insert into wms.warehouse_scopes (user_id, tenant_id, warehouse_id)
      values (v_user_id, p_tenant_id, v_warehouse_id)
      on conflict (user_id, warehouse_id) do nothing;
    end if;
  end if;

  if p_wcs_gateway_email is not null then
    select id into v_user_id from auth.users where email = p_wcs_gateway_email;
    if found then
      insert into wms.memberships (user_id, tenant_id, role)
      values (v_user_id, p_tenant_id, 'WCS_GATEWAY')
      on conflict (user_id, tenant_id) do nothing;
      insert into wms.warehouse_scopes (user_id, tenant_id, warehouse_id)
      values (v_user_id, p_tenant_id, v_warehouse_id)
      on conflict (user_id, warehouse_id) do nothing;
    end if;
  end if;

  if p_auditor_email is not null then
    select id into v_user_id from auth.users where email = p_auditor_email;
    if found then
      insert into wms.memberships (user_id, tenant_id, role)
      values (v_user_id, p_tenant_id, 'AUDITOR')
      on conflict (user_id, tenant_id) do nothing;
      insert into wms.warehouse_scopes (user_id, tenant_id, warehouse_id)
      values (v_user_id, p_tenant_id, v_warehouse_id)
      on conflict (user_id, warehouse_id) do nothing;
    end if;
  end if;

  if p_trainee_email is not null then
    select id into v_user_id from auth.users where email = p_trainee_email;
    if found then
      insert into wms.memberships (user_id, tenant_id, role)
      values (v_user_id, p_tenant_id, coalesce(p_trainee_role, 'WMS_ADMIN'))
      on conflict (user_id, tenant_id) do nothing;
      insert into wms.warehouse_scopes (user_id, tenant_id, warehouse_id)
      values (v_user_id, p_tenant_id, v_warehouse_id)
      on conflict (user_id, warehouse_id) do nothing;
    end if;
  end if;
end;
$$;

-- service_role ONLY, not authenticated. This function assigns roles/tenant
-- membership by caller-supplied email — on a Supabase project shared with
-- ProcessGPT's own production users (as this deployment is), granting
-- `authenticated` execute would let any signed-in user hand any email
-- (including their own) WMS_ADMIN/PROCESS_AGENT/etc. on any tenant_id they
-- name. wms-mcp and the trainee-onboarding script both call this with a
-- dedicated service_role key (see mcp/wms_mcp/client.py, scripts/onboard_trainee.py)
-- kept out of the browser and out of the per-identity anon-key sessions
-- every other RPC in this schema uses.
-- The core schema migration only granted schema-level USAGE to
-- authenticated (20260726_wms_core_schema.sql), so service_role needs it
-- too before it can reach this function at all.
grant usage on schema wms to service_role;

-- Postgres grants EXECUTE to PUBLIC by default on function creation, which
-- would silently undo the service_role-only intent above (every role is a
-- member of PUBLIC, including authenticated/anon) — revoke that first.
revoke execute on function wms.wms_ensure_tenant_provisioned(text, text, text, text, text, text, text) from public;
grant execute on function wms.wms_ensure_tenant_provisioned(text, text, text, text, text, text, text) to service_role;
