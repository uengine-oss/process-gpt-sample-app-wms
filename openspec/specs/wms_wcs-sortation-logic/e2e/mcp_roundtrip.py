"""MCP round-trip check for the WCS sortation-logic tools.

Drives the three new @mcp.tool functions (create/update/get_sortation_profile)
plus the two *existing* command tools they extend through an in-process
fastmcp Client, so it exercises the real MCP layer (schema, auth, error
classification) on top of the RPCs that
openspec/specs/wms_wcs-sortation-logic/e2e/simulator.sql verifies at the psql
level.

Two identities are involved, exactly as in production:

- PROCESS_AGENT drives dispatch_equipment_command with command_type
  DIVERT / SET_SPEED. It is deliberately NOT allowed to write profiles, so the
  two profile-write tools must answer FORBIDDEN for it — asserted below, and
  the fixture profile is therefore created off-MCP as WAREHOUSE_MANAGER.
- WCS_GATEWAY reports the sortation outcome through report_command_result;
  that tool signs in as the gateway internally.

Run from the repo's mcp/ directory against a running local Supabase:

    cd mcp && .venv/bin/python \
      ../openspec/specs/wms_wcs-sortation-logic/e2e/mcp_roundtrip.py
"""

import asyncio, json, os, subprocess, sys, uuid

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "..", "..", "..", "..", "mcp"))

from fastmcp import Client
from wms_mcp.mcp_server import mcp

TENANT = "10000000-0000-0000-0000-00000000000a"
WH = "20000000-0000-0000-0000-00000000000a"
SUFFIX = uuid.uuid4().hex[:6].upper()
SORTER = f"MCP-SORT-{SUFFIX}"
BARE = f"MCP-BARE-{SUFFIX}"     # a sorter with no profile, on purpose
ZONE = f"ZONE-MCP-{SUFFIX[:3]}"
DB = "supabase_db_process-gpt-sample-app-wms"


def psql(sql: str) -> str:
    return subprocess.run(
        ["docker", "exec", "-i", DB, "psql", "-U", "postgres", "-d", "postgres",
         "-qAt", "-v", "ON_ERROR_STOP=1", "-c", sql],
        check=True, capture_output=True, text=True,
    ).stdout.strip()


def out(label, res):
    data = res.data if hasattr(res, "data") else res
    print(f"\n### {label}\n{json.dumps(data, ensure_ascii=False, indent=2)[:1400]}")
    return data


def seed():
    """Two idle SORTERs in a private zone; only one of them gets a profile.

    Equipment registration (WAREHOUSE_MANAGER) and profile creation
    (WMS_ADMIN/WAREHOUSE_MANAGER/WCS_OPERATOR) are both outside PROCESS_AGENT's
    role set, so they are set up off-MCP here — which is also what the
    FORBIDDEN assertions below prove.
    """
    psql(f"delete from wms.equipment where zone_code = '{ZONE}';")
    return psql(f"""
do $do$
declare
  v_manager uuid; v_gateway uuid; v_eq wms.equipment%rowtype; v_code text;
begin
  select id into v_manager from auth.users where email = 'wh-manager-a@demo.local';
  select id into v_gateway from auth.users where email = 'wcs-gateway-a@demo.local';

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_manager::text, 'role', 'authenticated')::text, false);
  foreach v_code in array array['{SORTER}', '{BARE}'] loop
    perform wms.wms_register_equipment('{TENANT}', '{WH}', v_code, 'SORTER', '{ZONE}',
      v_manager, gen_random_uuid(), 'mcp-sortation');
  end loop;

  -- only the first one gets a tuning profile
  select * into v_eq from wms.equipment where equipment_code = '{SORTER}';
  perform wms.wms_create_sortation_profile(v_eq.id, 150, 0.5, 2.0, 80,
    v_manager, gen_random_uuid(), 'FIXED', 'MPS', 'mcp-sortation');

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_gateway::text, 'role', 'authenticated')::text, false);
  foreach v_code in array array['{SORTER}', '{BARE}'] loop
    select * into v_eq from wms.equipment where equipment_code = v_code;
    perform wms.wms_report_equipment_status(v_eq.id, 'IDLE', v_gateway, gen_random_uuid(),
      v_eq.version, null, 'mcp-sortation');
  end loop;
end
$do$;
""")


def cleanup():
    psql(f"delete from wms.equipment where zone_code = '{ZONE}';")


async def main():
    seed()
    sorter_id = psql(f"select id from wms.equipment where equipment_code = '{SORTER}';")
    bare_id = psql(f"select id from wms.equipment where equipment_code = '{BARE}';")
    print("fixture:", SORTER, "(profiled) /", BARE, "(no profile) in", ZONE)

    async with Client(mcp) as c:
        tools = sorted(t.name for t in await c.list_tools())
        print("TOOLS:", tools)
        for name in ("create_sortation_profile", "update_sortation_profile", "get_sortation_profile"):
            assert name in tools, f"{name} not exposed"
        # no new dispatch tool: DIVERT/SET_SPEED reuse the area-1 one
        assert "dispatch_sortation_command" not in tools, tools

        # 1. read model --------------------------------------------------
        view = out("get_sortation_profile (warehouse)", await c.call_tool(
            "get_sortation_profile", {"tenant_id": TENANT, "warehouse_id": WH}))
        assert view["result"] == "ok"
        items = {i["equipment_code"]: i for i in view["document"]["items"]}
        assert items[SORTER]["has_profile"] is True, items[SORTER]
        assert items[BARE]["has_profile"] is False and items[BARE]["profile"] is None, items[BARE]
        profile = items[SORTER]["profile"]
        assert profile["min_carton_gap_mm"] == 150 and profile["speed_unit"] == "MPS", profile

        # 2. profile writes are NOT the process agent's job ---------------
        denied = out("create_sortation_profile as PROCESS_AGENT (expect FORBIDDEN)", await c.call_tool(
            "create_sortation_profile", {"equipment_id": bare_id, "min_carton_gap_mm": 120,
                                         "min_speed_value": 0.4, "max_speed_value": 1.5,
                                         "sensor_detection_window_ms": 60}))
        assert denied["result"] == "error" and denied["error_kind"] == "FORBIDDEN", denied
        assert denied["http_status_equivalent"] == 403
        denied2 = out("update_sortation_profile as PROCESS_AGENT (expect FORBIDDEN)", await c.call_tool(
            "update_sortation_profile", {"profile_id": profile["profile_id"],
                                         "expected_version": profile["version"],
                                         "max_speed_value": 9.0}))
        assert denied2["result"] == "error" and denied2["error_kind"] == "FORBIDDEN", denied2

        dry = out("create_sortation_profile dry_run", await c.call_tool(
            "create_sortation_profile", {"equipment_id": bare_id, "min_carton_gap_mm": 120,
                                         "min_speed_value": 0.4, "max_speed_value": 1.5,
                                         "sensor_detection_window_ms": 60, "dry_run": True}))
        assert dry["result"] == "dry_run", dry

        # 3. DIVERT through the *existing* dispatch tool -------------------
        eq_version = int(psql(f"select version from wms.equipment where id = '{sorter_id}';"))
        divert = out("dispatch_equipment_command DIVERT", await c.call_tool(
            "dispatch_equipment_command", {
                "equipment_id": sorter_id, "command_type": "DIVERT",
                "expected_version": eq_version,
                "payload": {"target_chute": "CHUTE-12", "item_identifier": "MCP-BC-0001"},
                "correlation_id": "mcp-sortation"}))
        assert divert["result"] == "ok" and divert["status"] == "PENDING", divert
        divert_id = divert["document_id"]

        # payload validation surfaces through the same tool as INVALID
        eq_version = int(psql(f"select version from wms.equipment where id = '{sorter_id}';"))
        bad = out("DIVERT without item_identifier (expect INVALID)", await c.call_tool(
            "dispatch_equipment_command", {
                "equipment_id": sorter_id, "command_type": "DIVERT",
                "expected_version": eq_version, "payload": {"target_chute": "CHUTE-12"}}))
        assert bad["result"] == "error" and bad["error_kind"] == "INVALID", bad
        assert bad["http_status_equivalent"] == 422

        no_profile = out("DIVERT on a sorter with no profile (expect INVALID)", await c.call_tool(
            "dispatch_equipment_command", {
                "equipment_id": bare_id, "command_type": "DIVERT",
                "expected_version": int(psql(f"select version from wms.equipment where id = '{bare_id}';")),
                "payload": {"target_chute": "CHUTE-01", "item_identifier": "MCP-BC-0002"}}))
        assert no_profile["result"] == "error" and no_profile["error_kind"] == "INVALID", no_profile

        # 4. SET_SPEED range enforcement ----------------------------------
        eq_version = int(psql(f"select version from wms.equipment where id = '{sorter_id}';"))
        speed = out("dispatch_equipment_command SET_SPEED (in range)", await c.call_tool(
            "dispatch_equipment_command", {
                "equipment_id": sorter_id, "command_type": "SET_SPEED",
                "expected_version": eq_version,
                "payload": {"speed_mode": "FIXED", "speed_value": 1.8, "speed_unit": "MPS"},
                "correlation_id": "mcp-sortation"}))
        assert speed["result"] == "ok", speed
        speed_id = speed["document_id"]

        eq_version = int(psql(f"select version from wms.equipment where id = '{sorter_id}';"))
        too_fast = out("SET_SPEED above the profile max (expect INVALID)", await c.call_tool(
            "dispatch_equipment_command", {
                "equipment_id": sorter_id, "command_type": "SET_SPEED",
                "expected_version": eq_version,
                "payload": {"speed_mode": "FIXED", "speed_value": 3.5, "speed_unit": "MPS"}}))
        assert too_fast["result"] == "error" and too_fast["error_kind"] == "INVALID", too_fast

        # 5. gateway reports SUCCESS on the DIVERT -------------------------
        cmd_v = int(psql(f"select version from wms.equipment_commands where id = '{divert_id}';"))
        ok = out("report_command_result COMPLETED / outcome=SUCCESS", await c.call_tool(
            "report_command_result", {"command_id": divert_id, "command_status": "COMPLETED",
                                      "expected_version": cmd_v,
                                      "detail": {"outcome": "SUCCESS", "actual_chute": "CHUTE-12"},
                                      "correlation_id": "mcp-sortation"}))
        assert ok["result"] == "ok" and ok["status"] == "COMPLETED", ok

        # 6. a second DIVERT jams -> automatic SORTATION_JAM fault ---------
        eq_version = int(psql(f"select version from wms.equipment where id = '{sorter_id}';"))
        jam_cmd = out("dispatch_equipment_command DIVERT (will jam)", await c.call_tool(
            "dispatch_equipment_command", {
                "equipment_id": sorter_id, "command_type": "DIVERT",
                "expected_version": eq_version,
                "payload": {"target_chute": "CHUTE-03", "item_identifier": "MCP-BC-0003"},
                "correlation_id": "mcp-sortation"}))
        assert jam_cmd["result"] == "ok", jam_cmd
        jam_id = jam_cmd["document_id"]

        cmd_v = int(psql(f"select version from wms.equipment_commands where id = '{jam_id}';"))
        mismatch = out("outcome=JAM reported as COMPLETED (expect INVALID)", await c.call_tool(
            "report_command_result", {"command_id": jam_id, "command_status": "COMPLETED",
                                      "expected_version": cmd_v, "detail": {"outcome": "JAM"}}))
        assert mismatch["result"] == "error" and mismatch["error_kind"] == "INVALID", mismatch

        jammed = out("report_command_result FAILED / outcome=JAM", await c.call_tool(
            "report_command_result", {"command_id": jam_id, "command_status": "FAILED",
                                      "expected_version": cmd_v,
                                      "detail": {"outcome": "JAM", "reason": "CARTON_STUCK"},
                                      "correlation_id": "mcp-sortation"}))
        assert jammed["result"] == "ok" and jammed["status"] == "FAILED", jammed
        assert jammed["links"]["equipment_status"] == "FAULT", jammed

        # the still-PENDING SET_SPEED went down with the machine
        assert psql(f"select status from wms.equipment_commands where id = '{speed_id}';") == "FAILED"
        fault_code = psql(
            f"select fault_code from wms.equipment_faults where equipment_id = '{sorter_id}' and status = 'OPEN';")
        assert fault_code == "SORTATION_JAM", fault_code
        print("\nauto escalation: equipment ->", jammed["links"]["equipment_status"], "| fault:", fault_code)

        faulted = out("get_sortation_profile after the jam", await c.call_tool(
            "get_sortation_profile", {"tenant_id": TENANT, "warehouse_id": WH,
                                      "equipment_id": sorter_id}))
        item = faulted["document"]["items"][0]
        assert item["equipment_status"] == "FAULT" and item["last_outcome"] == "JAM", item
        assert item["open_faults"][0]["fault_code"] == "SORTATION_JAM", item

        # 7. a human clears it; PROCESS_AGENT may not ----------------------
        fault = item["open_faults"][0]
        refused = out("resolve_equipment_fault as PROCESS_AGENT (expect FORBIDDEN)", await c.call_tool(
            "resolve_equipment_fault", {"fault_id": fault["fault_id"], "resolution_note": "n/a",
                                        "expected_version": fault["version"]}))
        assert refused["result"] == "error" and refused["error_kind"] == "FORBIDDEN", refused
        psql(f"""
do $do$
declare v_op uuid;
begin
  select id into v_op from auth.users where email = 'wcs-operator-a@demo.local';
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_op::text, 'role', 'authenticated')::text, false);
  perform wms.wms_resolve_equipment_fault('{fault["fault_id"]}', '카톤 제거 완료', v_op,
    gen_random_uuid(), {fault["version"]}, 'mcp-sortation');
end
$do$;""")
        assert psql(f"select status from wms.equipment where id = '{sorter_id}';") == "IDLE"

        # 8. cross-tenant read is refused ----------------------------------
        other = out("get_sortation_profile for tenant B (expect FORBIDDEN)", await c.call_tool(
            "get_sortation_profile", {"tenant_id": "10000000-0000-0000-0000-00000000000b",
                                      "warehouse_id": "20000000-0000-0000-0000-00000000000b"}))
        assert other["result"] == "error" and other["error_kind"] == "FORBIDDEN", other

    cleanup()
    print("\nAll MCP round-trip assertions passed.")


asyncio.run(main())
