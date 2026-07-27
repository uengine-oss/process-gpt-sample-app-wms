#!/usr/bin/env bash
# ============================================================
# wms_yard-dock-scheduling — concurrent double-booking reproduction (tasks 5.2)
#
#   ./double_booking_concurrent.sh
#
# design.md D1 rejected the "SELECT ... FOR UPDATE then check in application
# code" design because two transactions can each see an empty window and both
# insert (phantom-row race). This script reproduces exactly that race against
# the shipped implementation and shows the storage engine settling it:
#
#   t=0.0  session 1  BEGIN, books DOCK-C-01 09:00-10:00, does NOT commit
#   t=1.0  session 2  BEGIN, books DOCK-C-01 09:30-10:30  -> BLOCKS
#          (it cannot know yet whether session 1 will commit or roll back)
#   t=3.0  session 1  COMMIT
#   t=3.0  session 2  unblocks and fails with CONFLICT:
#
# Exactly one appointment exists at the end. No advisory lock, no SERIALIZABLE.
# ============================================================
set -uo pipefail

DB_CONTAINER=${DB_CONTAINER:-supabase_db_process-gpt-sample-app-wms}
TENANT_A=10000000-0000-0000-0000-00000000000a
WH_A=20000000-0000-0000-0000-00000000000a

psql() { docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -qAt -v ON_ERROR_STOP=1 "$@"; }

echo "== setup: a dedicated dock + PO fixture =="
psql <<SQL
delete from wms.dock_appointments a using wms.docks d where a.dock_id = d.id and d.code = 'DOCK-C-01';
delete from wms.docks where code = 'DOCK-C-01';
delete from wms.purchase_orders where reason = 'DOCK-C-FIXTURE';

insert into wms.docks (tenant_id, warehouse_id, code, name)
values ('$TENANT_A', '$WH_A', 'DOCK-C-01', '동시성 검증 하역장');

insert into wms.purchase_orders (id, tenant_id, warehouse_id, product_id, qty, status, reason)
select '40000000-0000-0000-0000-0000000000c1', '$TENANT_A', '$WH_A', p.id, 10, 'CONFIRMED_PO', 'DOCK-C-FIXTURE'
from wms.products p where p.tenant_id = '$TENANT_A' and p.sku = 'SKU-A-001';
insert into wms.purchase_orders (id, tenant_id, warehouse_id, product_id, qty, status, reason)
select '40000000-0000-0000-0000-0000000000c2', '$TENANT_A', '$WH_A', p.id, 10, 'CONFIRMED_PO', 'DOCK-C-FIXTURE'
from wms.products p where p.tenant_id = '$TENANT_A' and p.sku = 'SKU-A-002';
SQL

session() {  # $1 = label, $2 = po id, $3 = start, $4 = end, $5 = sleep-before, $6 = hold-after
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -qAt <<SQL 2>&1 | sed "s/^/[$1] /"
\\timing off
select pg_sleep($5) is null as _;
begin;
select set_config('request.jwt.claims',
  json_build_object('sub', (select id::text from auth.users where email='inbound-a@demo.local'),
                    'role','authenticated')::text, false) is null as _;
select to_char(clock_timestamp(), 'SS.MS') || 's  attempting insert' as step;
select coalesce(
  (wms.wms_schedule_dock_appointment(
     (select id from wms.docks where code='DOCK-C-01'),
     '$3', '$4',
     (select id from auth.users where email='inbound-a@demo.local'),
     gen_random_uuid(), 'INBOUND', '$2', '$1', null, null, null, 'concurrent'))->>'status',
  'null') as outcome;
select to_char(clock_timestamp(), 'SS.MS') || 's  insert returned' as step;
select pg_sleep($6) is null as _;
commit;
select to_char(clock_timestamp(), 'SS.MS') || 's  committed' as step;
SQL
}

echo
echo "== race: overlapping windows on the same dock, from two connections =="
session S1 40000000-0000-0000-0000-0000000000c1 '2026-08-01T09:00:00Z' '2026-08-01T10:00:00Z' 0 3 &
S1_PID=$!
session S2 40000000-0000-0000-0000-0000000000c2 '2026-08-01T09:30:00Z' '2026-08-01T10:30:00Z' 1 0 &
S2_PID=$!
wait $S1_PID
wait $S2_PID

echo
echo "== result: exactly one active appointment survived =="
psql -c "select d.code, a.status, a.carrier_name, a.scheduled_start, a.scheduled_end
         from wms.dock_appointments a join wms.docks d on d.id = a.dock_id
         where d.code = 'DOCK-C-01' order by a.scheduled_start;"
psql -c "select count(*) as active_appointments from wms.dock_appointments a
           join wms.docks d on d.id = a.dock_id
         where d.code='DOCK-C-01' and a.status in ('SCHEDULED','CHECKED_IN','AT_DOCK');"
echo "-- expected: 1"

echo
echo "== cleanup =="
psql <<SQL
delete from wms.dock_appointments a using wms.docks d where a.dock_id = d.id and d.code = 'DOCK-C-01';
delete from wms.docks where code = 'DOCK-C-01';
delete from wms.purchase_orders where reason = 'DOCK-C-FIXTURE';
SQL
echo "done."
