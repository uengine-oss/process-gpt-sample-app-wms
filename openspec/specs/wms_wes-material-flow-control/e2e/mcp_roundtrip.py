"""MCP round-trip check for the WES/MFS material-flow-control tools.

Drives the six new @mcp.tool functions through an in-process fastmcp Client,
so it exercises the real MCP layer (schema, auth, error classification) on top
of the RPCs that
openspec/specs/wms_wes-material-flow-control/e2e/simulator.sql verifies at the
psql level.

Everything here runs as PROCESS_AGENT — unlike the equipment-control contract
there is no gateway-side RPC in this one (design.md D4), and PROCESS_AGENT is
inside the allowed role set, so all six tools must succeed. The equipment-side
feedback that makes a work order complete is still the gateway's job, so that
one step reuses the existing report_command_result tool (which signs in as
WCS_GATEWAY internally).

Run from the repo's mcp/ directory against a running local Supabase:

    cd mcp && .venv/bin/python \
      ../openspec/specs/wms_wes-material-flow-control/e2e/mcp_roundtrip.py
"""

import asyncio, json, os, subprocess, sys, uuid

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "..", "..", "..", "..", "mcp"))

from fastmcp import Client
from wms_mcp.mcp_server import mcp

TENANT = "10000000-0000-0000-0000-00000000000a"
WH = "20000000-0000-0000-0000-00000000000a"
SUFFIX = uuid.uuid4().hex[:6].upper()
CODES = [f"MCP-WES-{SUFFIX}-A", f"MCP-WES-{SUFFIX}-B"]
ZONE = f"ZONE-{SUFFIX[:3]}"
DB = "supabase_db_process-gpt-sample-app-wms"


def psql(sql: str) -> str:
    return subprocess.run(
        ["docker", "exec", "-i", DB, "psql", "-U", "postgres", "-d", "postgres",
         "-qAt", "-v", "ON_ERROR_STOP=1", "-c", sql],
        check=True, capture_output=True, text=True,
    ).stdout.strip()


def out(label, res):
    data = res.data if hasattr(res, "data") else res
    print(f"\n### {label}\n{json.dumps(data, ensure_ascii=False, indent=2)[:1200]}")
    return data


def seed():
    """A receipt to point work orders at, and two idle AGVs in a private zone.

    Both belong to other specs (inbound flow / equipment registry) and neither
    is callable by PROCESS_AGENT, so they are set up off-MCP.
    """
    codes = ",".join(f"'{c}'" for c in CODES)
    return psql(f"""
do $do$
declare
  v_buyer uuid; v_approver uuid; v_manager uuid; v_gateway uuid;
  v_po jsonb; v_conf jsonb; v_eq wms.equipment%rowtype; v_code text;
begin
  select id into v_buyer    from auth.users where email = 'buyer-a@demo.local';
  select id into v_approver from auth.users where email = 'approver-a@demo.local';
  select id into v_manager  from auth.users where email = 'wh-manager-a@demo.local';
  select id into v_gateway  from auth.users where email = 'wcs-gateway-a@demo.local';

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_buyer::text, 'role', 'authenticated')::text, false);
  v_po := wms.wms_create_rfq('{TENANT}', '{WH}', 'SKU-A-001', 25, null, v_buyer, gen_random_uuid(), 'mcp-wes');
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_approver::text, 'role', 'authenticated')::text, false);
  perform wms.wms_submit_purchase_approval((v_po->>'po_id')::uuid, 'APPROVE', v_approver, 1, null);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_buyer::text, 'role', 'authenticated')::text, false);
  v_conf := wms.wms_confirm_purchase_order((v_po->>'po_id')::uuid, v_buyer, gen_random_uuid(), 2);
  raise notice 'receipt %', v_conf->>'receipt_id';

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_manager::text, 'role', 'authenticated')::text, false);
  foreach v_code in array array[{codes}] loop
    perform wms.wms_register_equipment('{TENANT}', '{WH}', v_code, 'AGV', '{ZONE}',
      v_manager, gen_random_uuid(), 'mcp-wes');
  end loop;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_gateway::text, 'role', 'authenticated')::text, false);
  foreach v_code in array array[{codes}] loop
    select * into v_eq from wms.equipment where equipment_code = v_code;
    perform wms.wms_report_equipment_status(v_eq.id, 'IDLE', v_gateway, gen_random_uuid(),
      v_eq.version, null, 'mcp-wes');
  end loop;
end
$do$;
""")


async def main():
    seed()
    receipt = psql(f"select id from wms.receipts where warehouse_id = '{WH}' order by created_at desc limit 1;")
    print("fixture receipt:", receipt, "| equipment:", CODES, "in", ZONE)

    async with Client(mcp) as c:
        tools = sorted(t.name for t in await c.list_tools())
        print("TOOLS:", tools)
        for name in ("open_dispatch_wave", "create_work_order", "release_dispatch_wave",
                     "retry_work_order_dispatch", "cancel_work_order", "get_work_order_status"):
            assert name in tools, f"{name} not exposed"

        # 1. open a wave -------------------------------------------------
        wave = out("open_dispatch_wave", await c.call_tool(
            "open_dispatch_wave", {"tenant_id": TENANT, "warehouse_id": WH, "correlation_id": "mcp-wes"}))
        assert wave["result"] == "ok" and wave["status"] == "OPEN", wave
        wave_id = wave["document_id"]

        # 2. queue three work orders into it -----------------------------
        queued = []
        for slot in (1, 2, 3):
            wo = out(f"create_work_order (WAVE, slot {slot})", await c.call_tool("create_work_order", {
                "tenant_id": TENANT, "warehouse_id": WH, "work_order_type": "PUTAWAY",
                "linked_entity_type": "receipt", "linked_entity_id": receipt,
                "equipment_type": "AGV", "zone_code": ZONE, "command_type": "MOVE",
                "dispatch_mode": "WAVE", "wave_id": wave_id,
                "command_payload": {"slot": slot}, "correlation_id": "mcp-wes",
            }))
            assert wo["result"] == "ok" and wo["status"] == "QUEUED", wo
            assert wo["next_actions"] == ["release_dispatch_wave"], wo
            queued.append(wo["document_id"])

        # 3. release: two AGVs, three work orders -> 2 out, 1 warned -----
        rel = out("release_dispatch_wave", await c.call_tool("release_dispatch_wave", {
            "wave_id": wave_id, "expected_version": wave["version"], "correlation_id": "mcp-wes"}))
        assert rel["result"] == "ok" and rel["status"] == "RELEASED", rel
        assert rel["dispatched_count"] == 2 and rel["queued_count"] == 1, rel
        assert any("NO_EQUIPMENT_AVAILABLE" in w for w in rel["warnings"]), rel
        assert rel["next_actions"][0] == "retry_work_order_dispatch", rel

        # re-releasing is refused
        again = out("release_dispatch_wave again (expect INVALID)", await c.call_tool(
            "release_dispatch_wave", {"wave_id": wave_id, "expected_version": rel["version"]}))
        assert again["result"] == "error" and again["error_kind"] == "INVALID", again

        # 4. read model --------------------------------------------------
        board = out("get_work_order_status", await c.call_tool(
            "get_work_order_status", {"tenant_id": TENANT, "warehouse_id": WH}))
        assert board["result"] == "ok"
        mine = {w["work_order_id"]: w for w in board["document"]["work_orders"] if w["work_order_id"] in queued}
        assert len(mine) == 3, mine
        dispatched = [w for w in mine.values() if w["status"] == "DISPATCHED"]
        still_queued = [w for w in mine.values() if w["status"] == "QUEUED"]
        assert len(dispatched) == 2 and len(still_queued) == 1
        # flow balancing used both AGVs rather than stacking on one
        used = sorted(w["equipment_command"]["equipment_code"] for w in dispatched)
        assert used == sorted(CODES), used
        print("\nflow balance — commands landed on:", used)

        # 5. the gateway completes one command; the trigger must move the
        #    work order to COMPLETED without anyone calling a WES RPC ------
        target = dispatched[0]
        cmd = target["equipment_command"]
        for status, version in (("ACKNOWLEDGED", cmd["version"]),
                                ("IN_PROGRESS", cmd["version"] + 1),
                                ("COMPLETED", cmd["version"] + 2)):
            r = out(f"report_command_result {status} (WCS_GATEWAY)", await c.call_tool(
                "report_command_result", {"command_id": cmd["command_id"], "command_status": status,
                                          "expected_version": version, "correlation_id": "mcp-wes"}))
            assert r["result"] == "ok", r

        after = out("get_work_order_status after completion", await c.call_tool(
            "get_work_order_status", {"tenant_id": TENANT, "warehouse_id": WH,
                                      "work_order_id": target["work_order_id"]}))
        propagated = after["document"]["work_orders"][0]
        assert propagated["status"] == "COMPLETED", propagated
        print("\npropagation: work order", propagated["work_order_id"][:8], "->", propagated["status"])
        # the upper WMS entity is deliberately untouched
        assert psql(f"select status from wms.receipts where id = '{receipt}';") == "EXPECTED"

        # 6. retry the leftover QUEUED one now that an AGV is free --------
        leftover = still_queued[0]
        retried = out("retry_work_order_dispatch", await c.call_tool("retry_work_order_dispatch", {
            "work_order_id": leftover["work_order_id"], "expected_version": leftover["version"],
            "correlation_id": "mcp-wes"}))
        assert retried["result"] == "ok" and retried["status"] == "DISPATCHED", retried

        stale = out("retry with a stale version (expect CONFLICT)", await c.call_tool(
            "retry_work_order_dispatch", {"work_order_id": leftover["work_order_id"],
                                          "expected_version": leftover["version"]}))
        assert stale["result"] == "error" and stale["error_kind"] == "CONFLICT", stale

        # 7. cancel a DISPATCHED work order -> its command is cancelled ---
        cancelled = out("cancel_work_order (DISPATCHED -> cascade)", await c.call_tool("cancel_work_order", {
            "work_order_id": retried["document_id"], "expected_version": retried["version"],
            "reason": "mcp roundtrip", "correlation_id": "mcp-wes"}))
        assert cancelled["result"] == "ok" and cancelled["status"] == "CANCELLED", cancelled
        cascaded = cancelled["links"]["cancelled_equipment_command_id"]
        assert cascaded, cancelled
        assert psql(f"select status from wms.equipment_commands where id = '{cascaded}';") == "CANCELLED"

        terminal = out("cancel an already CANCELLED work order (expect INVALID)", await c.call_tool(
            "cancel_work_order", {"work_order_id": retried["document_id"],
                                  "expected_version": cancelled["version"]}))
        assert terminal["result"] == "error" and terminal["error_kind"] == "INVALID", terminal

        # 8. FORBIDDEN surfaces as a structured error --------------------
        other = out("get_work_order_status for tenant B warehouse (expect FORBIDDEN)", await c.call_tool(
            "get_work_order_status", {"tenant_id": "10000000-0000-0000-0000-00000000000b",
                                      "warehouse_id": "20000000-0000-0000-0000-00000000000b"}))
        assert other["result"] == "error" and other["error_kind"] == "FORBIDDEN", other
        assert other["http_status_equivalent"] == 403

        # 9. dry_run makes no change -------------------------------------
        dry = out("create_work_order dry_run", await c.call_tool("create_work_order", {
            "tenant_id": TENANT, "warehouse_id": WH, "work_order_type": "PUTAWAY",
            "linked_entity_type": "receipt", "linked_entity_id": receipt,
            "equipment_type": "AGV", "command_type": "MOVE", "dispatch_mode": "WAVELESS",
            "dry_run": True}))
        assert dry["result"] == "dry_run", dry

    print("\nAll MCP round-trip assertions passed.")


asyncio.run(main())
