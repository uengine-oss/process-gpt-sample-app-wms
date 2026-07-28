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
    {"email": "wh-manager-a@demo.local", "role": "WAREHOUSE_MANAGER"},
    {"email": "wcs-operator-a@demo.local", "role": "WCS_OPERATOR"},
    {"email": "wcs-gateway-a@demo.local",  "role": "WCS_GATEWAY"},
    {"email": "auditor-a@demo.local",  "role": "AUDITOR"},
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
  ('localhost', 'demo-a', 'Tenant A Logistics'),
  ('10000000-0000-0000-0000-00000000000b', 'demo-b', 'Tenant B Retail');

insert into wms.warehouses (id, tenant_id, code, name) values
  ('20000000-0000-0000-0000-00000000000a', 'localhost', 'WH-A1', 'Tenant A Main Warehouse'),
  ('20000000-0000-0000-0000-00000000000b', '10000000-0000-0000-0000-00000000000b', 'WH-B1', 'Tenant B Main Warehouse');

insert into wms.memberships (user_id, tenant_id, role)
select u.id, 'localhost', m.role
from auth.users u
join (values
  ('admin-a@demo.local', 'WMS_ADMIN'),
  ('buyer-a@demo.local', 'PROCUREMENT_BUYER'),
  ('approver-a@demo.local', 'PURCHASE_APPROVER'),
  ('inbound-a@demo.local', 'INBOUND_OPERATOR'),
  ('quality-a@demo.local', 'QUALITY_INSPECTOR'),
  ('process-agent-a@demo.local', 'PROCESS_AGENT'),
  -- WCS equipment-control contract (20260727_wcs_equipment_control.sql):
  -- WAREHOUSE_MANAGER owns the equipment registry and may dispatch commands;
  -- WCS_OPERATOR is a human monitoring/manual-command/fault-resolution role;
  -- WCS_GATEWAY is the equipment-side service identity (real PLC/WCS gateway
  -- or software simulator) that reports command results, status and faults.
  ('wh-manager-a@demo.local', 'WAREHOUSE_MANAGER'),
  ('wcs-operator-a@demo.local', 'WCS_OPERATOR'),
  ('wcs-gateway-a@demo.local', 'WCS_GATEWAY'),
  -- Natural-language audit log contract (20260806_operations_audit_log.sql):
  -- AUDITOR has been listed in the schema's role comment since the very first
  -- migration (20260726 line 30) and was never checked by any RPC. It is the
  -- read-only audit/finance identity: it may call wms_query_audit_log and
  -- wms_export_audit_log, and nothing else in this repo. Deliberately given no
  -- write role anywhere — an auditor who can also change the records is not an
  -- auditor. The warehouse scope row below exists only so the audit screen can
  -- resolve a warehouse label like every other screen; the audit RPCs are
  -- tenant-scoped and never consult it (design.md D2).
  ('auditor-a@demo.local', 'AUDITOR')
) as m(email, role) on m.email = u.email;

insert into wms.memberships (user_id, tenant_id, role)
select u.id, '10000000-0000-0000-0000-00000000000b', 'WMS_ADMIN'
from auth.users u where u.email = 'admin-b@demo.local';

-- Non-admin roles need an explicit warehouse scope row; WMS_ADMIN gets every
-- warehouse in its tenant automatically (see wms.current_warehouse_ids()).
insert into wms.warehouse_scopes (user_id, tenant_id, warehouse_id)
select u.id, 'localhost', '20000000-0000-0000-0000-00000000000a'
from auth.users u
where u.email in (
  'buyer-a@demo.local', 'approver-a@demo.local', 'inbound-a@demo.local',
  'quality-a@demo.local', 'process-agent-a@demo.local',
  'wh-manager-a@demo.local', 'wcs-operator-a@demo.local', 'wcs-gateway-a@demo.local',
  'auditor-a@demo.local'
);

-- ------------------------------------------------------------
-- Products & suppliers
-- ------------------------------------------------------------

insert into wms.products (tenant_id, sku, name, uom, reorder_min, reorder_max) values
  ('localhost', 'SKU-A-001', 'Corrugated Box (Medium)', 'EA', 50, 200),
  ('localhost', 'SKU-A-002', 'Pallet Wrap Roll', 'EA', 20, 100),
  ('localhost', 'SKU-A-003', 'Barcode Scanner Battery', 'EA', 10, 50),
  ('10000000-0000-0000-0000-00000000000b', 'SKU-B-001', 'Retail Shelf Label', 'EA', 100, 500),
  ('10000000-0000-0000-0000-00000000000b', 'SKU-B-002', 'Shopping Bag (Paper)', 'EA', 200, 1000);

insert into wms.suppliers (tenant_id, name, email) values
  ('localhost', 'Acme Packaging Co.', 'sales@acme-packaging.demo'),
  ('localhost', 'Northwind Supplies', 'orders@northwind-supplies.demo'),
  ('10000000-0000-0000-0000-00000000000b', 'Retail Basics Inc.', 'sales@retail-basics.demo');

-- ------------------------------------------------------------
-- Docks (20260802_yard_dock_scheduling.sql). Three doors in tenant A so the
-- schedule board has something to show on first login, and one in tenant B so
-- the cross-tenant RLS check has a real row to be denied.
-- ------------------------------------------------------------

insert into wms.docks (id, tenant_id, warehouse_id, code, name, status) values
  ('30000000-0000-0000-0000-00000000000a', '10000000-0000-0000-0000-00000000000a',
   '20000000-0000-0000-0000-00000000000a', 'DOCK-01', '입고 하역장 1', 'AVAILABLE'),
  ('30000000-0000-0000-0000-00000000000b', '10000000-0000-0000-0000-00000000000a',
   '20000000-0000-0000-0000-00000000000a', 'DOCK-02', '입고 하역장 2', 'AVAILABLE'),
  ('30000000-0000-0000-0000-00000000000c', '10000000-0000-0000-0000-00000000000a',
   '20000000-0000-0000-0000-00000000000a', 'DOCK-03', '출고 상차장 1', 'AVAILABLE'),
  ('30000000-0000-0000-0000-00000000000d', '10000000-0000-0000-0000-00000000000b',
   '20000000-0000-0000-0000-00000000000b', 'DOCK-B1', 'Tenant B 하역장', 'AVAILABLE');

-- One demo appointment so the board is not empty. It is OUTBOUND on purpose:
-- an INBOUND appointment needs a po_id (CHECK constraint), and this seed
-- deliberately creates no purchase orders — wms-flow.spec.ts drives the whole
-- PO lifecycle from the shortage state below and a pre-seeded PO would change
-- what its `.first()` selectors land on. The OUTBOUND type is fully supported
-- (migration header, D3-AMENDED); the loose link is left null here because the
-- seed creates no outbound orders either.
insert into wms.dock_appointments (
  tenant_id, warehouse_id, dock_id, appointment_type,
  carrier_name, vehicle_plate_no, scheduled_start, scheduled_end, status
) values (
  '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-00000000000a',
  '30000000-0000-0000-0000-00000000000c', 'OUTBOUND',
  '한빛운수', '77바1234',
  date_trunc('day', now()) + interval '14 hours',
  date_trunc('day', now()) + interval '15 hours',
  'SCHEDULED'
);

-- ------------------------------------------------------------
-- Labor activities (20260803_labor_management.sql). Two roles across three
-- past days so the productivity board, the leaderboard and the trailing-window
-- forecast all have real numbers on first login instead of empty tables.
--
-- Deliberately dated D-2..D-4, never "today" and never D-1: the Playwright
-- suite scopes its assertions to *today in the browser's local timezone*, and
-- these timestamps are anchored to date_trunc('day', now()) in the database's
-- (UTC). Those two "days" can be up to 14 hours apart, so a D-1 afternoon row
-- lands inside a UTC+9 "today" window and silently inflates the test's totals
-- — which is exactly what happened the first time. Backing off to D-2 puts
-- every seed row clear of the widest possible local-day window. The
-- trailing-7-day forecast still sees all of them.
--
-- inbound-a averages 60 units/hour (120 units per 2h activity);
-- quality-a averages 20 units/hour (30 units per 1.5h activity).
-- ------------------------------------------------------------

insert into wms.labor_activities (
  tenant_id, warehouse_id, actor_id, actor_role, activity_type, activity_label,
  unit_count, status, started_at, completed_at, created_by, updated_by
)
select
  '10000000-0000-0000-0000-00000000000a',
  '20000000-0000-0000-0000-00000000000a',
  u.id, s.role, s.activity_type, s.label, s.unit_count, 'COMPLETED',
  date_trunc('day', now()) - make_interval(days => s.days_ago) + make_interval(hours => s.start_hour),
  date_trunc('day', now()) - make_interval(days => s.days_ago) + make_interval(hours => s.start_hour) + make_interval(mins => s.minutes),
  u.id, u.id
from (values
  ('inbound-a@demo.local',  'INBOUND_OPERATOR',  'RECEIVING',         '오전 입고 검수 (시드)',   120, 4,  9, 120),
  ('inbound-a@demo.local',  'INBOUND_OPERATOR',  'PUTAWAY',           '오후 적치 (시드)',        120, 4, 13, 120),
  ('inbound-a@demo.local',  'INBOUND_OPERATOR',  'RECEIVING',         '오전 입고 검수 (시드)',   120, 3,  9, 120),
  ('inbound-a@demo.local',  'INBOUND_OPERATOR',  'PUTAWAY',           '오후 적치 (시드)',        120, 2, 13, 120),
  ('quality-a@demo.local',  'QUALITY_INSPECTOR', 'QUALITY_INSPECTION', '오전 품질 검사 (시드)',   30, 4, 10,  90),
  ('quality-a@demo.local',  'QUALITY_INSPECTOR', 'QUALITY_INSPECTION', '오후 품질 검사 (시드)',   30, 3, 14,  90),
  ('quality-a@demo.local',  'QUALITY_INSPECTOR', 'DISPOSITION',        '불합격 처분 (시드)',      30, 2, 11,  90)
) as s(email, role, activity_type, label, unit_count, days_ago, start_hour, minutes)
join auth.users u on u.email = s.email;

-- ------------------------------------------------------------
-- Starting stock: SKU-A-001 already below reorder_min to drive the demo's
-- shortage-detection scene without an extra setup step.
-- ------------------------------------------------------------

insert into wms.stock_ledger_entries (tenant_id, warehouse_id, product_id, qty_delta, status, source_type, source_id)
select 'localhost', '20000000-0000-0000-0000-00000000000a', p.id, 30, 'AVAILABLE', 'opening_balance', null
from wms.products p where p.sku = 'SKU-A-001' and p.tenant_id = 'localhost';

insert into wms.stock_ledger_entries (tenant_id, warehouse_id, product_id, qty_delta, status, source_type, source_id)
select 'localhost', '20000000-0000-0000-0000-00000000000a', p.id, 60, 'AVAILABLE', 'opening_balance', null
from wms.products p where p.sku = 'SKU-A-002' and p.tenant_id = 'localhost';
