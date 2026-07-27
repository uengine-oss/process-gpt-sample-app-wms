"""MCP round-trip check for the WCS equipment-control tools.

Drives the new @mcp.tool functions through an in-process fastmcp Client, so
it exercises the real MCP layer (schema, auth, error classification) on top of
the RPCs that openspec/specs/wms_wcs-equipment-control/e2e/simulator.sql
verifies at the psql level.

Run from the repo's mcp/ directory against a running local Supabase:

    cd mcp && .venv/bin/python \
      ../openspec/specs/wms_wcs-equipment-control/e2e/mcp_roundtrip.py
"""

import asyncio, json, os, sys, uuid

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "..", "..", "..", "..", "mcp"))

from fastmcp import Client
from wms_mcp.mcp_server import mcp

CODE = "MCP-AGV-" + uuid.uuid4().hex[:6].upper()
TENANT = "10000000-0000-0000-0000-00000000000a"
WH = "20000000-0000-0000-0000-00000000000a"


def out(label, res):
    data = res.data if hasattr(res, "data") else res
    print(f"\n### {label}\n{json.dumps(data, ensure_ascii=False, indent=2)[:900]}")
    return data


async def main():
    async with Client(mcp) as c:
        tools = sorted(t.name for t in await c.list_tools())
        print("TOOLS:", tools)

        # 1. register (PROCESS_AGENT lacks WMS_ADMIN -> expect FORBIDDEN)
        r = out("register_equipment as PROCESS_AGENT (expect FORBIDDEN)", await c.call_tool(
            "register_equipment",
            {"tenant_id": TENANT, "warehouse_id": WH, "equipment_code": CODE,
             "equipment_type": "AGV", "zone_code": "ZONE-M"}))
        assert r["result"] == "error" and r["error_kind"] == "FORBIDDEN", r

        # seed one piece of equipment directly (admin path is a human/UI concern)
        import subprocess
        subprocess.run([
            "docker", "exec", "-i", "supabase_db_process-gpt-sample-app-wms",
            "psql", "-U", "postgres", "-d", "postgres", "-qAt", "-c",
            f"""select set_config('request.jwt.claims',
                  json_build_object('sub',(select id from auth.users where email='admin-a@demo.local')::text,
                                    'role','authenticated')::text,false);
                select wms.wms_register_equipment('{TENANT}','{WH}','{CODE}','AGV','ZONE-M',
                  (select id from auth.users where email='admin-a@demo.local'), gen_random_uuid(), null);"""
        ], check=True, capture_output=True)

        # 2. read status
        d = out("get_equipment_status", await c.call_tool(
            "get_equipment_status", {"tenant_id": TENANT, "warehouse_id": WH}))
        assert d["result"] == "ok"
        eq = next(e for e in d["document"]["equipment"] if e["equipment_code"] == CODE)
        eid, ever = eq["equipment_id"], eq["version"]
        assert eq["status"] == "OFFLINE", eq

        # 3. gateway brings it online
        d = out("report_equipment_status OFFLINE->IDLE (WCS_GATEWAY)", await c.call_tool(
            "report_equipment_status",
            {"equipment_id": eid, "new_status": "IDLE", "expected_version": ever}))
        assert d["result"] == "ok" and d["status"] == "IDLE", d
        ever = d["version"]

        # 4. process agent dispatches
        d = out("dispatch_equipment_command MOVE (PROCESS_AGENT)", await c.call_tool(
            "dispatch_equipment_command",
            {"equipment_id": eid, "command_type": "MOVE", "expected_version": ever,
             "payload": {"to_zone": "ZONE-C"}, "linked_entity_type": "receipt",
             "linked_entity_id": "00000000-0000-0000-0000-0000000000bb",
             "correlation_id": "mcp-check-1"}))
        assert d["result"] == "ok" and d["status"] == "PENDING", d
        cid, cver = d["document_id"], d["version"]
        assert d["links"]["equipment_status"] == "RUNNING", d

        # 5. version conflict
        d = out("dispatch with stale version (expect CONFLICT)", await c.call_tool(
            "dispatch_equipment_command",
            {"equipment_id": eid, "command_type": "STOP", "expected_version": 1}))
        assert d["error_kind"] == "CONFLICT", d

        # 6. gateway reports ACK -> IN_PROGRESS -> COMPLETED
        for status in ("ACKNOWLEDGED", "IN_PROGRESS", "COMPLETED"):
            d = out(f"report_command_result {status} (WCS_GATEWAY)", await c.call_tool(
                "report_command_result",
                {"command_id": cid, "command_status": status, "expected_version": cver,
                 "detail": {"pct": 100} if status == "COMPLETED" else None}))
            assert d["result"] == "ok" and d["status"] == status, d
            cver = d["version"]
        assert d["links"]["equipment_status"] == "IDLE", d
        ever = d["links"]["equipment_version"]

        # 7. fault -> in-flight command failed
        d = out("dispatch LOAD then raise fault", await c.call_tool(
            "dispatch_equipment_command",
            {"equipment_id": eid, "command_type": "LOAD", "expected_version": ever}))
        cid2 = d["document_id"]
        d = out("raise_equipment_fault (WCS_GATEWAY)", await c.call_tool(
            "raise_equipment_fault",
            {"equipment_id": eid, "fault_code": "MCP_TEST_FAULT", "severity": "CRITICAL"}))
        assert d["result"] == "ok" and cid2 in d["failed_command_ids"], d
        assert d["links"]["equipment_status"] == "FAULT", d
        fid, fver = d["document_id"], d["version"]

        # 8. resolving as PROCESS_AGENT must be refused
        d = out("resolve_equipment_fault as PROCESS_AGENT (expect FORBIDDEN)", await c.call_tool(
            "resolve_equipment_fault",
            {"fault_id": fid, "resolution_note": "auto", "expected_version": fver}))
        assert d["error_kind"] == "FORBIDDEN", d

        # 9. idempotent cancel + terminal cancel rejection
        d = out("cancel already-FAILED command (expect INVALID)", await c.call_tool(
            "cancel_equipment_command", {"command_id": cid2, "expected_version": 2}))
        assert d["error_kind"] == "INVALID", d

        print("\n\nALL MCP ASSERTIONS PASSED")


asyncio.run(main())
