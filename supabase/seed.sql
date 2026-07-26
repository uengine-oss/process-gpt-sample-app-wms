-- Demo seed data: 2 tenants (cross-tenant RLS isolation demo), 1 warehouse
-- each, a handful of products/suppliers, and one user per role needed by
-- the docs/02-contracts.md flow. All demo passwords: Demo1234!

-- ------------------------------------------------------------
-- Demo auth users (local dev only — password auth via GoTrue)
-- ------------------------------------------------------------

do $$
declare
  v_instance_id uuid := '00000000-0000-0000-0000-000000000000';
  v_users jsonb := '[
    {"email": "admin-a@demo.local",    "role": "WMS_ADMIN"},
    {"email": "buyer-a@demo.local",    "role": "PROCUREMENT_BUYER"},
    {"email": "approver-a@demo.local", "role": "PURCHASE_APPROVER"},
    {"email": "inbound-a@demo.local",  "role": "INBOUND_OPERATOR"},
    {"email": "quality-a@demo.local",  "role": "QUALITY_INSPECTOR"},
    {"email": "process-agent-a@demo.local", "role": "PROCESS_AGENT"},
    {"email": "admin-b@demo.local",    "role": "WMS_ADMIN"}
  ]'::jsonb;
  v_user jsonb;
  v_user_id uuid;
begin
  for v_user in select * from jsonb_array_elements(v_users) loop
    v_user_id := gen_random_uuid();

    insert into auth.users (
      instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
      raw_app_meta_data, raw_user_meta_data, created_at, updated_at, confirmation_token,
      recovery_token, email_change_token_new, email_change
    ) values (
      v_instance_id, v_user_id, 'authenticated', 'authenticated', v_user->>'email',
      crypt('Demo1234!', gen_salt('bf')), now(),
      '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', '', '', ''
    );

    insert into auth.identities (
      id, provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at
    ) values (
      gen_random_uuid(), v_user_id, v_user_id,
      jsonb_build_object('sub', v_user_id::text, 'email', v_user->>'email'),
      'email', now(), now(), now()
    );
  end loop;
end $$;

-- ------------------------------------------------------------
-- Tenants, warehouses, memberships
-- ------------------------------------------------------------

insert into wms.tenants (id, code, name) values
  ('10000000-0000-0000-0000-00000000000a', 'demo-a', 'Tenant A Logistics'),
  ('10000000-0000-0000-0000-00000000000b', 'demo-b', 'Tenant B Retail');

insert into wms.warehouses (id, tenant_id, code, name) values
  ('20000000-0000-0000-0000-00000000000a', '10000000-0000-0000-0000-00000000000a', 'WH-A1', 'Tenant A Main Warehouse'),
  ('20000000-0000-0000-0000-00000000000b', '10000000-0000-0000-0000-00000000000b', 'WH-B1', 'Tenant B Main Warehouse');

insert into wms.memberships (user_id, tenant_id, role)
select u.id, '10000000-0000-0000-0000-00000000000a', m.role
from auth.users u
join (values
  ('admin-a@demo.local', 'WMS_ADMIN'),
  ('buyer-a@demo.local', 'PROCUREMENT_BUYER'),
  ('approver-a@demo.local', 'PURCHASE_APPROVER'),
  ('inbound-a@demo.local', 'INBOUND_OPERATOR'),
  ('quality-a@demo.local', 'QUALITY_INSPECTOR'),
  ('process-agent-a@demo.local', 'PROCESS_AGENT')
) as m(email, role) on m.email = u.email;

insert into wms.memberships (user_id, tenant_id, role)
select u.id, '10000000-0000-0000-0000-00000000000b', 'WMS_ADMIN'
from auth.users u where u.email = 'admin-b@demo.local';

-- Non-admin roles need an explicit warehouse scope row; WMS_ADMIN gets every
-- warehouse in its tenant automatically (see wms.current_warehouse_ids()).
insert into wms.warehouse_scopes (user_id, tenant_id, warehouse_id)
select u.id, '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-00000000000a'
from auth.users u
where u.email in (
  'buyer-a@demo.local', 'approver-a@demo.local', 'inbound-a@demo.local',
  'quality-a@demo.local', 'process-agent-a@demo.local'
);

-- ------------------------------------------------------------
-- Products & suppliers
-- ------------------------------------------------------------

insert into wms.products (tenant_id, sku, name, uom, reorder_min, reorder_max) values
  ('10000000-0000-0000-0000-00000000000a', 'SKU-A-001', 'Corrugated Box (Medium)', 'EA', 50, 200),
  ('10000000-0000-0000-0000-00000000000a', 'SKU-A-002', 'Pallet Wrap Roll', 'EA', 20, 100),
  ('10000000-0000-0000-0000-00000000000a', 'SKU-A-003', 'Barcode Scanner Battery', 'EA', 10, 50),
  ('10000000-0000-0000-0000-00000000000b', 'SKU-B-001', 'Retail Shelf Label', 'EA', 100, 500),
  ('10000000-0000-0000-0000-00000000000b', 'SKU-B-002', 'Shopping Bag (Paper)', 'EA', 200, 1000);

insert into wms.suppliers (tenant_id, name, email) values
  ('10000000-0000-0000-0000-00000000000a', 'Acme Packaging Co.', 'sales@acme-packaging.demo'),
  ('10000000-0000-0000-0000-00000000000a', 'Northwind Supplies', 'orders@northwind-supplies.demo'),
  ('10000000-0000-0000-0000-00000000000b', 'Retail Basics Inc.', 'sales@retail-basics.demo');

-- ------------------------------------------------------------
-- Starting stock: SKU-A-001 already below reorder_min to drive the demo's
-- shortage-detection scene without an extra setup step.
-- ------------------------------------------------------------

insert into wms.stock_ledger_entries (tenant_id, warehouse_id, product_id, qty_delta, status, source_type, source_id)
select '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-00000000000a', p.id, 30, 'AVAILABLE', 'opening_balance', null
from wms.products p where p.sku = 'SKU-A-001' and p.tenant_id = '10000000-0000-0000-0000-00000000000a';

insert into wms.stock_ledger_entries (tenant_id, warehouse_id, product_id, qty_delta, status, source_type, source_id)
select '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-00000000000a', p.id, 60, 'AVAILABLE', 'opening_balance', null
from wms.products p where p.sku = 'SKU-A-002' and p.tenant_id = '10000000-0000-0000-0000-00000000000a';
