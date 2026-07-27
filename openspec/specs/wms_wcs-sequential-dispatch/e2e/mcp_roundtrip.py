"""MCP round-trip check for the WCS sequential-dispatch tools.

Drives the six new @mcp.tool functions (create_outbound_order,
assign_dispatch_sequence, cancel_dispatch_sequence,
dispatch_palletize_command, get_dispatch_sequence_status,
get_pallet_manifest) through an in-process fastmcp Client, so it exercises the
real MCP layer (schema, auth, error classification) on top of the RPCs that
openspec/specs/wms_wcs-sequential-dispatch/e2e/simulator.sql verifies at the
psql level.

Unlike areas 3 and 4, PROCESS_AGENT is a first-class actor here: it may
register outbound units, sequence them, dispatch the palletising command and
cancel assignments — all four write tools work for the identity the MCP server
signs in as. What it may NOT do is report the result: that is WCS_GATEWAY's
job, and the server reaches it through the separate gateway credential
(report_command_result). So the "robot cell speaks" step below goes through the
existing report_command_result tool, not a new one, which is itself the proof
that this contract added no equipment-side RPC.

Two things this script is really testing:

  1. one PALLETIZE result fans out to N sequence assignments (the per-item
     generalisation of area 2's command-level propagation), and
  2. WRAP rides the generic dispatch_equipment_command tool with no tool of
     its own and touches no assignment state.

Run from the repo's mcp/ directory against a running local Supabase:

    cd mcp && .venv/bin/python \
      ../openspec/specs/wms_wcs-sequential-dispatch/e2e/mcp_roundtrip.py
"""

import asyncio, json, os, subprocess, sys, uuid

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "..", "..", "..", "..", "mcp"))

from fastmcp import Client
from wms_mcp.mcp_server import mcp

TENANT = "10000000-0000-0000-0000-00000000000a"
WH = "20000000-0000-0000-0000-00000000000a"
SUFFIX = uuid.uuid4().hex[:6].upper()
CELL = f"MCP-SEQ-{SUFFIX}-CELL"
AGV = f"MCP-SEQ-{SUFFIX}-AGV"
ZONE = f"ZONE-MCP-SEQ-{SUFFIX[:3]}"
PALLET = f"PLT-MCP-{SUFFIX}"
DB = "supabase_db_process-gpt-sample-app-wms"


def psql(sql: str) -> str:
    return subprocess.run(
        ["docker", "exec", "-i", DB, "psql", "-U", "postgres", "-d", "postgres",
         "-qAt", "-v", "ON_ERROR_STOP=1", "-c", sql],
        check=True, capture_output=True, text=True,
    ).stdout.strip()


def out(label, res):
    data = res.data if hasattr(res, "data") else res
    print(f"\n### {label}\n{json.dumps(data, ensure_ascii=False, indent=2)[:2200]}")
    return data


def seed():
    """One idle ROBOT_CELL, one idle AGV (the wrong type, on purpose), and an
    OPEN dispatch wave. Equipment registration and wave opening belong to
    areas 1 and 2, so they are done off-MCP as WAREHOUSE_MANAGER."""
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
  perform wms.wms_register_equipment('{TENANT}', '{WH}', '{CELL}', 'ROBOT_CELL', '{ZONE}',
    v_manager, gen_random_uuid(), 'mcp-seq');
  perform wms.wms_register_equipment('{TENANT}', '{WH}', '{AGV}', 'AGV', '{ZONE}',
    v_manager, gen_random_uuid(), 'mcp-seq');
  perform wms.wms_open_dispatch_wave('{TENANT}', '{WH}', v_manager, gen_random_uuid(), 'mcp-seq');

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_gateway::text, 'role', 'authenticated')::text, false);
  foreach v_code in array array['{CELL}', '{AGV}'] loop
    select * into v_eq from wms.equipment where equipment_code = v_code;
    perform wms.wms_report_equipment_status(v_eq.id, 'IDLE', v_gateway, gen_random_uuid(),
      v_eq.version, null, 'mcp-seq');
  end loop;
end
$do$;
""")


def cleanup():
    psql(f"delete from wms.dispatch_sequences s using wms.outbound_orders o "
         f"where o.id = s.outbound_order_id and o.correlation_id = 'mcp-seq';")
    psql("delete from wms.outbound_orders where correlation_id = 'mcp-seq';")
    psql("delete from wms.dispatch_waves where correlation_id = 'mcp-seq';")
    psql(f"delete from wms.equipment where zone_code = '{ZONE}';")


def equipment_version(code: str) -> int:
    return int(psql(f"select version from wms.equipment where equipment_code = '{code}';"))


def command_version(command_id: str) -> int:
    return int(psql(f"select version from wms.equipment_commands where id = '{command_id}';"))


async def main():
    seed()
    cell_id = psql(f"select id from wms.equipment where equipment_code = '{CELL}';")
    agv_id = psql(f"select id from wms.equipment where equipment_code = '{AGV}';")
    wave_id = psql("select id from wms.dispatch_waves where correlation_id = 'mcp-seq' "
                   "order by created_at desc limit 1;")
    sku1 = psql(f"select id from wms.products where sku = 'SKU-A-001' and tenant_id = '{TENANT}';")
    sku2 = psql(f"select id from wms.products where sku = 'SKU-A-002' and tenant_id = '{TENANT}';")
    print(f"fixture: {CELL} (ROBOT_CELL) / {AGV} (AGV) in {ZONE}, wave {wave_id[:8]}")

    async with Client(mcp) as c:
        tools = sorted(t.name for t in await c.list_tools())
        print("TOOLS:", tools)
        for name in ("create_outbound_order", "assign_dispatch_sequence",
                     "cancel_dispatch_sequence", "dispatch_palletize_command",
                     "get_dispatch_sequence_status", "get_pallet_manifest"):
            assert name in tools, f"{name} not exposed"
        # no tool of their own on purpose (design.md D8, area 3's precedent)
        assert "dispatch_wrap_command" not in tools, tools
        assert "report_palletize_result" not in tools, tools

        # 1. outbound units ---------------------------------------------
        o1 = out("create_outbound_order #1 (STORE-042, 4.2kg)", await c.call_tool(
            "create_outbound_order", {
                "tenant_id": TENANT, "warehouse_id": WH, "store_code": "STORE-042",
                "product_id": sku1, "qty": 10, "order_number": f"MCP-{SUFFIX}-1",
                "declared_weight_kg": 4.2, "declared_volume_l": 3.1,
                "correlation_id": "mcp-seq"}))
        assert o1["result"] == "ok" and o1["status"] == "OPEN", o1
        assert o1["next_actions"] == ["assign_dispatch_sequence", "get_dispatch_sequence_status"], o1
        ob1 = o1["links"]["outbound_order_id"]

        o2 = out("create_outbound_order #2 (STORE-042, 6.0kg)", await c.call_tool(
            "create_outbound_order", {
                "tenant_id": TENANT, "warehouse_id": WH, "store_code": "STORE-042",
                "product_id": sku2, "qty": 4, "order_number": f"MCP-{SUFFIX}-2",
                "declared_weight_kg": 6.0, "declared_volume_l": 5.0,
                "correlation_id": "mcp-seq"}))
        ob2 = o2["links"]["outbound_order_id"]

        bad = out("create_outbound_order (qty=0)", await c.call_tool(
            "create_outbound_order", {
                "tenant_id": TENANT, "warehouse_id": WH, "store_code": "STORE-042",
                "product_id": sku1, "qty": 0, "correlation_id": "mcp-seq"}))
        assert bad["result"] == "error" and bad["error_kind"] == "INVALID", bad
        assert bad["http_status_equivalent"] == 422, bad

        dry = out("create_outbound_order (dry_run)", await c.call_tool(
            "create_outbound_order", {
                "tenant_id": TENANT, "warehouse_id": WH, "store_code": "STORE-DRY",
                "product_id": sku1, "qty": 1, "dry_run": True}))
        assert dry["result"] == "dry_run", dry
        assert psql("select count(*) from wms.outbound_orders where store_code = 'STORE-DRY';") == "0"

        # 2. sequencing --------------------------------------------------
        s1 = out("assign_dispatch_sequence #1 (position 1)", await c.call_tool(
            "assign_dispatch_sequence", {
                "outbound_order_id": ob1, "wave_id": wave_id, "sequence_position": 1,
                "target_pallet_code": PALLET, "expected_version": o1["version"],
                "correlation_id": "mcp-seq"}))
        assert s1["result"] == "ok" and s1["status"] == "QUEUED", s1
        assert s1["links"]["outbound_order_status"] == "SEQUENCED", s1
        seq1 = s1["links"]["dispatch_sequence_id"]

        s2 = out("assign_dispatch_sequence #2 (position 2, same pallet)", await c.call_tool(
            "assign_dispatch_sequence", {
                "outbound_order_id": ob2, "wave_id": wave_id, "sequence_position": 2,
                "target_pallet_code": PALLET, "expected_version": o2["version"],
                "correlation_id": "mcp-seq"}))
        seq2 = s2["links"]["dispatch_sequence_id"]

        dup = out("assign_dispatch_sequence (duplicate position)", await c.call_tool(
            "assign_dispatch_sequence", {
                "outbound_order_id": ob1, "wave_id": wave_id, "sequence_position": 1,
                "target_pallet_code": PALLET, "expected_version": 2}))
        assert dup["result"] == "error" and dup["error_kind"] == "INVALID", dup

        stale = out("assign_dispatch_sequence (stale version)", await c.call_tool(
            "assign_dispatch_sequence", {
                "outbound_order_id": ob1, "wave_id": wave_id, "sequence_position": 9,
                "target_pallet_code": PALLET, "expected_version": 1}))
        assert stale["result"] == "error" and stale["error_kind"] == "CONFLICT", stale
        assert stale["http_status_equivalent"] == 409, stale

        # 3. palletising dispatch ----------------------------------------
        wrong = out("dispatch_palletize_command (AGV, wrong type)", await c.call_tool(
            "dispatch_palletize_command", {
                "equipment_id": agv_id, "wave_id": wave_id, "target_pallet_code": PALLET,
                "expected_version": equipment_version(AGV)}))
        assert wrong["result"] == "error" and wrong["error_kind"] == "INVALID", wrong

        heavy = out("dispatch_palletize_command (max_weight_kg=5 vs declared 10.2)",
                    await c.call_tool("dispatch_palletize_command", {
                        "equipment_id": cell_id, "wave_id": wave_id,
                        "target_pallet_code": PALLET, "max_weight_kg": 5,
                        "expected_version": equipment_version(CELL)}))
        assert heavy["result"] == "error" and heavy["error_kind"] == "INVALID", heavy
        assert "exceeds max_weight_kg" in heavy["message"], heavy
        # the refusal left both assignments alone
        assert psql(f"select string_agg(distinct status, ',') from wms.dispatch_sequences "
                    f"where target_pallet_code = '{PALLET}';") == "QUEUED"

        d = out("dispatch_palletize_command (happy path)", await c.call_tool(
            "dispatch_palletize_command", {
                "equipment_id": cell_id, "wave_id": wave_id, "target_pallet_code": PALLET,
                "max_weight_kg": 250, "max_volume_l": 500,
                "expected_version": equipment_version(CELL), "correlation_id": "mcp-seq"}))
        assert d["result"] == "ok" and d["status"] == "PENDING", d
        assert d["links"]["item_count"] == 2, d
        assert float(d["links"]["declared_total_weight_kg"]) == 10.2, d
        assert set(d["links"]["dispatch_sequence_ids"]) == {seq1, seq2}, d
        command_id = d["links"]["equipment_command_id"]

        # one command, two assignments — the N:1 shape this contract exists for
        assert psql(f"select count(distinct equipment_command_id) from wms.dispatch_sequences "
                    f"where target_pallet_code = '{PALLET}';") == "1"
        assert psql(f"select string_agg(distinct status, ',') from wms.dispatch_sequences "
                    f"where target_pallet_code = '{PALLET}';") == "DISPATCHED"

        # a second, DIFFERENT pallet on the same busy cell is refused (D4)
        other = out("dispatch_palletize_command (different pallet, cell busy)",
                    await c.call_tool("dispatch_palletize_command", {
                        "equipment_id": cell_id, "wave_id": wave_id,
                        "target_pallet_code": PALLET + "-X",
                        "expected_version": equipment_version(CELL)}))
        assert other["result"] == "error" and other["error_kind"] == "INVALID", other

        # 4. the manifest is empty until the cell speaks ------------------
        empty = out("get_pallet_manifest (before any result)", await c.call_tool(
            "get_pallet_manifest", {"tenant_id": TENANT, "warehouse_id": WH,
                                    "equipment_command_id": command_id}))
        pallet = empty["document"]["pallets"][0]
        assert pallet["reported"] is False, pallet
        assert pallet["items"] == [], pallet
        assert pallet["planned_item_count"] == 2, pallet

        # 5. the cell reports — through the EXISTING gateway tool ---------
        ack = out("report_command_result (IN_PROGRESS, WCS_GATEWAY)", await c.call_tool(
            "report_command_result", {
                "command_id": command_id, "command_status": "IN_PROGRESS",
                "expected_version": command_version(command_id)}))
        assert ack["result"] == "ok", ack

        lie = out("report_command_result (COMPLETED + outcome=OVERWEIGHT)", await c.call_tool(
            "report_command_result", {
                "command_id": command_id, "command_status": "COMPLETED",
                "expected_version": command_version(command_id),
                "detail": {"outcome": "OVERWEIGHT", "loaded_items": [
                    {"dispatch_sequence_id": seq1, "item_outcome": "SKIPPED"},
                    {"dispatch_sequence_id": seq2, "item_outcome": "SKIPPED"}]}}))
        assert lie["result"] == "error" and lie["error_kind"] == "INVALID", lie

        done = out("report_command_result (PARTIAL: one LOADED, one SKIPPED)",
                   await c.call_tool("report_command_result", {
                       "command_id": command_id, "command_status": "COMPLETED",
                       "expected_version": command_version(command_id),
                       "detail": {"outcome": "PARTIAL",
                                  "total_actual_weight_kg": 4.4,
                                  "loaded_items": [
                                      {"dispatch_sequence_id": seq1, "load_position": 1,
                                       "item_outcome": "LOADED"},
                                      {"dispatch_sequence_id": seq2, "load_position": None,
                                       "item_outcome": "SKIPPED", "reason": "OVERWEIGHT"}]},
                       "correlation_id": "mcp-seq"}))
        assert done["result"] == "ok" and done["status"] == "COMPLETED", done

        # 6. ONE result -> TWO different assignment outcomes --------------
        view = out("get_dispatch_sequence_status (after the report)", await c.call_tool(
            "get_dispatch_sequence_status", {"tenant_id": TENANT, "warehouse_id": WH,
                                             "wave_id": wave_id}))
        by_id = {s["dispatch_sequence_id"]: s for s in view["document"]["sequences"]}
        assert by_id[seq1]["status"] == "COMPLETED", by_id[seq1]
        assert by_id[seq1]["load_position"] == 1, by_id[seq1]
        assert by_id[seq1]["outbound_order_status"] == "COMPLETED", by_id[seq1]
        assert by_id[seq2]["status"] == "FAILED", by_id[seq2]
        assert by_id[seq2]["reason"] == "OVERWEIGHT", by_id[seq2]
        assert by_id[seq2]["outbound_order_status"] == "FAILED", by_id[seq2]
        rolled = {p["target_pallet_code"]: p for p in view["document"]["pallets"]}[PALLET]
        assert rolled["completed_count"] == 1 and rolled["failed_count"] == 1, rolled

        manifest = out("get_pallet_manifest (after the report)", await c.call_tool(
            "get_pallet_manifest", {"tenant_id": TENANT, "warehouse_id": WH,
                                    "target_pallet_code": PALLET}))
        pallet = manifest["document"]["pallets"][0]
        assert pallet["reported"] is True and pallet["outcome"] == "PARTIAL", pallet
        assert float(pallet["total_actual_weight_kg"]) == 4.4, pallet
        assert float(pallet["declared_total_weight_kg"]) == 10.2, pallet
        outcomes = {i["dispatch_sequence_id"]: i["item_outcome"] for i in pallet["items"]}
        assert outcomes == {seq1: "LOADED", seq2: "SKIPPED"}, outcomes

        # 7. WRAP has no tool of its own and changes no assignment --------
        before = psql("select count(*) from wms.dispatch_sequences where status = 'COMPLETED';")
        w = out("dispatch_equipment_command (WRAP, no dedicated tool)", await c.call_tool(
            "dispatch_equipment_command", {
                "equipment_id": cell_id, "command_type": "WRAP",
                "payload": {"pallet_code": PALLET, "wrap_program": "STANDARD"},
                "expected_version": equipment_version(CELL), "correlation_id": "mcp-seq"}))
        assert w["result"] == "ok", w
        wrap_id = w["document_id"]

        badwrap = out("dispatch_equipment_command (WRAP without wrap_program)",
                      await c.call_tool("dispatch_equipment_command", {
                          "equipment_id": cell_id, "command_type": "WRAP",
                          "payload": {"pallet_code": PALLET},
                          "expected_version": equipment_version(CELL)}))
        assert badwrap["result"] == "error" and badwrap["error_kind"] == "INVALID", badwrap

        wdone = out("report_command_result (WRAP SUCCESS)", await c.call_tool(
            "report_command_result", {
                "command_id": wrap_id, "command_status": "COMPLETED",
                "expected_version": command_version(wrap_id),
                "detail": {"outcome": "SUCCESS", "wrap_cycles": 3}}))
        assert wdone["result"] == "ok", wdone
        after = psql("select count(*) from wms.dispatch_sequences where status = 'COMPLETED';")
        assert before == after, (before, after)

        # 8. cancellation of a QUEUED assignment --------------------------
        o3 = out("create_outbound_order #3 (for the cancel path)", await c.call_tool(
            "create_outbound_order", {
                "tenant_id": TENANT, "warehouse_id": WH, "store_code": "STORE-777",
                "product_id": sku1, "qty": 2, "order_number": f"MCP-{SUFFIX}-3",
                "declared_weight_kg": 1.0, "correlation_id": "mcp-seq"}))
        ob3 = o3["links"]["outbound_order_id"]
        s3 = out("assign_dispatch_sequence #3", await c.call_tool(
            "assign_dispatch_sequence", {
                "outbound_order_id": ob3, "wave_id": wave_id, "sequence_position": 5,
                "target_pallet_code": PALLET + "-C", "expected_version": o3["version"],
                "correlation_id": "mcp-seq"}))
        seq3 = s3["links"]["dispatch_sequence_id"]

        cancelled = out("cancel_dispatch_sequence (QUEUED)", await c.call_tool(
            "cancel_dispatch_sequence", {
                "dispatch_sequence_id": seq3, "expected_version": s3["version"],
                "reason": "고객 주문 취소", "correlation_id": "mcp-seq"}))
        assert cancelled["result"] == "ok" and cancelled["status"] == "CANCELLED", cancelled
        assert cancelled["links"]["cancelled_equipment_command_id"] is None, cancelled
        # the unit is OPEN again and the position is free again
        assert psql(f"select status from wms.outbound_orders where id = '{ob3}';") == "OPEN"
        again = out("assign_dispatch_sequence (reuse position 5 after cancel)",
                    await c.call_tool("assign_dispatch_sequence", {
                        "outbound_order_id": ob3, "wave_id": wave_id, "sequence_position": 5,
                        "target_pallet_code": PALLET + "-C",
                        "expected_version": int(psql(
                            f"select version from wms.outbound_orders where id = '{ob3}';")),
                        "correlation_id": "mcp-seq"}))
        assert again["result"] == "ok", again

        twice = out("cancel_dispatch_sequence (already cancelled)", await c.call_tool(
            "cancel_dispatch_sequence", {"dispatch_sequence_id": seq3, "expected_version": 2}))
        assert twice["result"] == "error" and twice["error_kind"] == "INVALID", twice

        # 9. audit trail, including the automatic per-item propagation ----
        audit = psql("select string_agg(distinct command, ',' order by command) "
                     "from wms.audit_events "
                     "where entity_type in ('outbound_order', 'dispatch_sequence');")
        print("\n### audit commands\n" + audit)
        for expected in ("wms_create_outbound_order", "wms_assign_dispatch_sequence",
                         "wms_cancel_dispatch_sequence", "wms_dispatch_palletize_command",
                         "wms_propagate_palletize_result"):
            assert expected in audit, (expected, audit)

    print("\nALL MCP ROUND-TRIP ASSERTIONS PASSED")


if __name__ == "__main__":
    try:
        asyncio.run(main())
    finally:
        cleanup()
