"""MCP round-trip check for the WCS bottleneck-routing tools.

Drives the five new @mcp.tool functions (register/update_wcs_routing_policy,
exclude/clear_equipment_routing_exclusion, get_equipment_routing_status)
through an in-process fastmcp Client, so it exercises the real MCP layer
(schema, auth, error classification) on top of the RPCs that
openspec/specs/wms_wcs-bottleneck-routing/e2e/simulator.sql verifies at the
psql level.

The role story here is the inverse of area 2's: PROCESS_AGENT may create work
orders and therefore benefits from bottleneck avoidance, but it may NOT tune
thresholds or take a machine out of service — those are human operating
judgements (design.md 역할 모델). So all four write tools must answer FORBIDDEN
for the identity the MCP server signs in as, and only the read tool belongs in
the agent allowlist. The writes needed to set up the scenario are therefore
performed off-MCP as WAREHOUSE_MANAGER / WCS_OPERATOR, which is itself the
proof of that split.

The final section is the point of the whole contract: a work order created
through the *existing* create_work_order tool must route around the excluded
and the bottleneck-flagged machine without the agent knowing they exist.

Run from the repo's mcp/ directory against a running local Supabase:

    cd mcp && .venv/bin/python \
      ../openspec/specs/wms_wcs-bottleneck-routing/e2e/mcp_roundtrip.py
"""

import asyncio, json, os, subprocess, sys, uuid

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "..", "..", "..", "..", "mcp"))

from fastmcp import Client
from wms_mcp.mcp_server import mcp

TENANT = "10000000-0000-0000-0000-00000000000a"
WH = "20000000-0000-0000-0000-00000000000a"
SUFFIX = uuid.uuid4().hex[:6].upper()
CLEAN = f"MCP-RTE-{SUFFIX}-A"      # nothing wrong with it
FLAKY = f"MCP-RTE-{SUFFIX}-B"      # two recent faults -> bottleneck flag
BANNED = f"MCP-RTE-{SUFFIX}-C"     # force-excluded by an operator
ZONE = f"ZONE-MCP-RTE-{SUFFIX[:3]}"
DB = "supabase_db_process-gpt-sample-app-wms"


def psql(sql: str) -> str:
    return subprocess.run(
        ["docker", "exec", "-i", DB, "psql", "-U", "postgres", "-d", "postgres",
         "-qAt", "-v", "ON_ERROR_STOP=1", "-c", sql],
        check=True, capture_output=True, text=True,
    ).stdout.strip()


def out(label, res):
    data = res.data if hasattr(res, "data") else res
    print(f"\n### {label}\n{json.dumps(data, ensure_ascii=False, indent=2)[:1800]}")
    return data


def seed():
    """Three idle AGVs in a private zone plus a receipt for the work order.

    FLAKY gets two raise+resolve fault cycles so it is IDLE and command-free
    (a perfectly legal candidate) yet flagged as a bottleneck. BANNED gets an
    ACTIVE routing override. Neither of those writes is available to
    PROCESS_AGENT, which is exactly what the FORBIDDEN assertions below show.
    """
    psql(f"delete from wms.equipment where zone_code = '{ZONE}';")
    return psql(f"""
do $do$
declare
  v_buyer uuid; v_approver uuid; v_manager uuid; v_gateway uuid; v_operator uuid;
  v_po jsonb; v_eq wms.equipment%rowtype; v_code text; v_fault uuid;
begin
  select id into v_buyer from auth.users where email = 'buyer-a@demo.local';
  select id into v_approver from auth.users where email = 'approver-a@demo.local';
  select id into v_manager from auth.users where email = 'wh-manager-a@demo.local';
  select id into v_gateway from auth.users where email = 'wcs-gateway-a@demo.local';
  select id into v_operator from auth.users where email = 'wcs-operator-a@demo.local';

  -- a receipt, through the real inbound RPCs (area 2 needs one)
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_buyer::text, 'role', 'authenticated')::text, false);
  v_po := wms.wms_create_rfq('{TENANT}', '{WH}', 'SKU-A-001', 25, null, v_buyer,
                             gen_random_uuid(), 'mcp-routing');
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_approver::text, 'role', 'authenticated')::text, false);
  perform wms.wms_submit_purchase_approval((v_po->>'po_id')::uuid, 'APPROVE', v_approver, 1, null);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_buyer::text, 'role', 'authenticated')::text, false);
  perform wms.wms_confirm_purchase_order((v_po->>'po_id')::uuid, v_buyer, gen_random_uuid(), 2);

  -- three identical AGVs
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_manager::text, 'role', 'authenticated')::text, false);
  foreach v_code in array array['{CLEAN}', '{FLAKY}', '{BANNED}'] loop
    perform wms.wms_register_equipment('{TENANT}', '{WH}', v_code, 'AGV', '{ZONE}',
      v_manager, gen_random_uuid(), 'mcp-routing');
  end loop;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_gateway::text, 'role', 'authenticated')::text, false);
  foreach v_code in array array['{CLEAN}', '{FLAKY}', '{BANNED}'] loop
    select * into v_eq from wms.equipment where equipment_code = v_code;
    perform wms.wms_report_equipment_status(v_eq.id, 'IDLE', v_gateway, gen_random_uuid(),
      v_eq.version, null, 'mcp-routing');
  end loop;

  -- two fault cycles on FLAKY: it ends up IDLE again, but "unstable lately"
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_operator::text, 'role', 'authenticated')::text, false);
  select * into v_eq from wms.equipment where equipment_code = '{FLAKY}';
  foreach v_code in array array['MCP_DRIFT_1', 'MCP_DRIFT_2'] loop
    v_fault := (wms.wms_raise_equipment_fault(v_eq.id, v_code, 'WARNING', v_operator,
                  gen_random_uuid(), 'mcp-routing')->>'fault_id')::uuid;
    perform wms.wms_resolve_equipment_fault(v_fault, 'simulated recovery', v_operator,
      gen_random_uuid(), (select version from wms.equipment_faults where id = v_fault),
      'mcp-routing');
  end loop;
end
$do$;
""")


def cleanup():
    psql(f"delete from wms.work_orders where zone_code = '{ZONE}';")
    psql(f"delete from wms.equipment where zone_code = '{ZONE}';")
    psql("delete from wms.purchase_orders where correlation_id = 'mcp-routing';")


def as_operator_exclude(equipment_code: str, reason: str) -> str:
    """The operator write PROCESS_AGENT is not allowed to make."""
    return psql(f"""
do $do$
declare v_operator uuid; v_eq wms.equipment%rowtype;
begin
  select id into v_operator from auth.users where email = 'wcs-operator-a@demo.local';
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_operator::text, 'role', 'authenticated')::text, false);
  select * into v_eq from wms.equipment where equipment_code = '{equipment_code}';
  perform wms.wms_exclude_equipment_from_routing(v_eq.id, '{reason}', v_operator,
    gen_random_uuid(), 'mcp-routing');
end
$do$;""")


async def main():
    seed()
    clean_id = psql(f"select id from wms.equipment where equipment_code = '{CLEAN}';")
    flaky_id = psql(f"select id from wms.equipment where equipment_code = '{FLAKY}';")
    banned_id = psql(f"select id from wms.equipment where equipment_code = '{BANNED}';")
    receipt = psql("select id from wms.receipts order by created_at desc limit 1;")
    as_operator_exclude(BANNED, '계획 정비')
    print(f"fixture: {CLEAN} (clean) / {FLAKY} (2 recent faults) / {BANNED} (excluded) in {ZONE}")

    async with Client(mcp) as c:
        tools = sorted(t.name for t in await c.list_tools())
        print("TOOLS:", tools)
        for name in ("register_wcs_routing_policy", "update_wcs_routing_policy",
                     "exclude_equipment_from_routing", "clear_equipment_routing_exclusion",
                     "get_equipment_routing_status"):
            assert name in tools, f"{name} not exposed"
        # the selection hook is internal to area 2's dispatch RPCs, never a tool
        assert "select_available_equipment" not in tools, tools
        assert "wcs_select_available_equipment" not in tools, tools

        # 1. read model --------------------------------------------------
        view = out("get_equipment_routing_status (whole warehouse)", await c.call_tool(
            "get_equipment_routing_status", {"tenant_id": TENANT, "warehouse_id": WH}))
        assert view["result"] == "ok"
        doc = view["document"]
        assert doc["observation_window"] == "30 minutes", doc
        items = {i["equipment_code"]: i for i in doc["items"]}

        assert items[CLEAN]["is_bottleneck"] is False, items[CLEAN]
        assert items[CLEAN]["is_excluded"] is False, items[CLEAN]
        assert items[CLEAN]["routable"] is True, items[CLEAN]
        # SYSTEM_DEFAULT on a clean DB, POLICY if simulator.sql ran first and
        # left an AGV policy behind — either is a valid threshold source.
        assert items[CLEAN]["threshold_source"] in ("SYSTEM_DEFAULT", "POLICY"), items[CLEAN]

        assert items[FLAKY]["is_bottleneck"] is True, items[FLAKY]
        assert items[FLAKY]["bottleneck_reasons"] == ["FAULT_FREQUENCY_EXCEEDED"], items[FLAKY]
        assert items[FLAKY]["recent_fault_count"] == 2, items[FLAKY]
        assert (items[FLAKY]["recent_fault_count"]
                >= items[FLAKY]["resolved_fault_count_threshold"]), items[FLAKY]
        # a bottleneck flag is a preference, not a veto — it stays routable
        assert items[FLAKY]["routable"] is True, items[FLAKY]

        assert items[BANNED]["is_excluded"] is True, items[BANNED]
        assert items[BANNED]["active_override"]["reason"] == "계획 정비", items[BANNED]
        assert items[BANNED]["routable"] is False, items[BANNED]

        # 2. the four write tools are all FORBIDDEN for PROCESS_AGENT -----
        for label, name, args in [
            ("register_wcs_routing_policy", "register_wcs_routing_policy",
             {"tenant_id": TENANT, "warehouse_id": WH, "equipment_type": "AGV",
              "queue_depth_threshold": 3, "fault_count_threshold": 2}),
            ("update_wcs_routing_policy", "update_wcs_routing_policy",
             {"policy_id": str(uuid.uuid4()), "expected_version": 1,
              "queue_depth_threshold": 4}),
            ("exclude_equipment_from_routing", "exclude_equipment_from_routing",
             {"equipment_id": clean_id, "reason": "agent should not do this"}),
            ("clear_equipment_routing_exclusion", "clear_equipment_routing_exclusion",
             {"override_id": str(uuid.uuid4()), "expected_version": 1}),
        ]:
            res = out(f"{label} as PROCESS_AGENT", await c.call_tool(name, args))
            assert res["result"] == "error", res
            assert res["error_kind"] in ("FORBIDDEN", "INVALID"), res
        # the two that address a real row must be FORBIDDEN specifically —
        # the other two are refused before the row is even looked up.
        res = await c.call_tool("register_wcs_routing_policy", {
            "tenant_id": TENANT, "warehouse_id": WH, "equipment_type": "AGV",
            "queue_depth_threshold": 3, "fault_count_threshold": 2})
        assert (res.data if hasattr(res, "data") else res)["error_kind"] == "FORBIDDEN"
        res = await c.call_tool("exclude_equipment_from_routing", {
            "equipment_id": clean_id, "reason": "agent should not do this"})
        assert (res.data if hasattr(res, "data") else res)["error_kind"] == "FORBIDDEN"

        # 3. dry_run never touches the DB --------------------------------
        dry = out("exclude_equipment_from_routing (dry_run)", await c.call_tool(
            "exclude_equipment_from_routing",
            {"equipment_id": clean_id, "reason": "정비 예정", "dry_run": True}))
        assert dry["result"] == "dry_run", dry
        assert psql(f"select count(*) from wms.wcs_routing_overrides o "
                    f"join wms.equipment e on e.id = o.equipment_id "
                    f"where e.equipment_code = '{CLEAN}';") == "0"

        # 4. THE POINT: a work order routes around both machines ---------
        wo = out("create_work_order (PROCESS_AGENT, WAVELESS)", await c.call_tool(
            "create_work_order", {
                "tenant_id": TENANT, "warehouse_id": WH,
                "work_order_type": "PUTAWAY", "linked_entity_type": "receipt",
                "linked_entity_id": receipt, "equipment_type": "AGV",
                "zone_code": ZONE, "command_type": "MOVE",
                "command_payload": {"to_zone": "ZONE-C"},
                "dispatch_mode": "WAVELESS", "correlation_id": "mcp-routing",
            }))
        assert wo["result"] == "ok", wo
        assert wo["status"] == "DISPATCHED", wo
        # not the excluded one, and not the flaky one while a clean one exists
        assert wo["links"]["equipment_code"] == CLEAN, wo["links"]

        # 5. the clean one is now busy -> the bottleneck one is the fallback
        wo2 = out("create_work_order again (only the flaky AGV is free)",
                  await c.call_tool("create_work_order", {
                      "tenant_id": TENANT, "warehouse_id": WH,
                      "work_order_type": "PUTAWAY", "linked_entity_type": "receipt",
                      "linked_entity_id": receipt, "equipment_type": "AGV",
                      "zone_code": ZONE, "command_type": "MOVE",
                      "command_payload": {"to_zone": "ZONE-D"},
                      "dispatch_mode": "WAVELESS", "correlation_id": "mcp-routing",
                  }))
        assert wo2["status"] == "DISPATCHED", wo2
        assert wo2["links"]["equipment_code"] == FLAKY, wo2["links"]

        # 6. nothing free but the excluded one -> QUEUED, never BANNED ----
        wo3 = out("create_work_order a third time (only the EXCLUDED AGV is free)",
                  await c.call_tool("create_work_order", {
                      "tenant_id": TENANT, "warehouse_id": WH,
                      "work_order_type": "PUTAWAY", "linked_entity_type": "receipt",
                      "linked_entity_id": receipt, "equipment_type": "AGV",
                      "zone_code": ZONE, "command_type": "MOVE",
                      "command_payload": {"to_zone": "ZONE-E"},
                      "dispatch_mode": "WAVELESS", "correlation_id": "mcp-routing",
                  }))
        assert wo3["status"] == "QUEUED", wo3
        assert "NO_EQUIPMENT_AVAILABLE" in wo3["warnings"], wo3
        assert psql(f"select count(*) from wms.equipment_commands c "
                    f"join wms.equipment e on e.id = c.equipment_id "
                    f"where e.equipment_code = '{BANNED}';") == "0"

        # 7. the read model now explains why -----------------------------
        after = out("get_equipment_routing_status (after dispatching)", await c.call_tool(
            "get_equipment_routing_status",
            {"tenant_id": TENANT, "warehouse_id": WH, "equipment_id": flaky_id}))
        flaky = after["document"]["items"][0]
        assert flaky["queue_depth"] == 1, flaky
        assert flaky["equipment_status"] == "RUNNING", flaky
        assert flaky["routable"] is False, flaky

        assert banned_id  # referenced for clarity in the log above

    cleanup()
    print("\nOK — bottleneck-routing MCP round-trip passed")


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except Exception:
        cleanup()
        raise
