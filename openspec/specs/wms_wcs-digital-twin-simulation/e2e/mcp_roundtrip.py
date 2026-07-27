"""MCP round-trip check for the WCS digital-twin / simulation tools.

Drives the eleven new @mcp.tool functions through an in-process fastmcp Client,
so it exercises the real MCP layer (schema, auth, error classification) on top
of the RPCs that
openspec/specs/wms_wcs-digital-twin-simulation/e2e/simulator.sql verifies at the
psql level.

The role story here has THREE parties, not two, and the tool layer shows all
three:

  * PROCESS_AGENT — the identity the MCP server signs in as for ordinary tools.
    It may define and run what-if scenarios (planning is an agent-shaped job),
    but it may NOT decide which machines are simulated and may NOT tune their
    timing profiles. Those are human operating judgements, so those tools
    answer FORBIDDEN here.
  * WCS_GATEWAY — plan/advance/poll go through _call_rpc_as_gateway, so the
    same MCP server drives them under a *different* login. This is the only
    area where an MCP tool changes area 1's command state.
  * Humans (WAREHOUSE_MANAGER / WCS_OPERATOR) — the setup writes below are done
    off-MCP as those users, which is itself the proof of the split.

The last section is the point of the contract: a MOVE dispatched by the
ordinary create-command path is walked to COMPLETED purely through this
contract's tools, with no hand-written wms_report_command_result anywhere.

Run from the repo's mcp/ directory against a running local Supabase:

    cd mcp && .venv/bin/python \
      ../openspec/specs/wms_wcs-digital-twin-simulation/e2e/mcp_roundtrip.py
"""

import asyncio, json, os, subprocess, sys, uuid

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "..", "..", "..", "..", "mcp"))

from fastmcp import Client
from wms_mcp.mcp_server import mcp

TENANT = "10000000-0000-0000-0000-00000000000a"
WH = "20000000-0000-0000-0000-00000000000a"
SUFFIX = uuid.uuid4().hex[:6].upper()
SIM = f"MCP-TWIN-{SUFFIX}-SIM"     # flipped into simulation mode
REAL = f"MCP-TWIN-{SUFFIX}-REAL"   # deliberately left alone
ZONE = f"ZONE-MCP-TWIN-{SUFFIX[:3]}"
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


def cleanup():
    psql(f"delete from wms.simulation_scenarios where name like 'MCP-TWIN-{SUFFIX}%';")
    psql(f"delete from wms.equipment where zone_code = '{ZONE}';")


def seed():
    """Two idle AGVs in a private zone. Nothing is simulated yet — the flip is
    done through the MCP tool layer below (as a human, off-MCP, because
    PROCESS_AGENT is refused)."""
    cleanup()
    return psql(f"""
do $do$
declare v_manager uuid; v_gateway uuid; v_eq wms.equipment%rowtype; v_code text;
begin
  select id into v_manager from auth.users where email = 'wh-manager-a@demo.local';
  select id into v_gateway from auth.users where email = 'wcs-gateway-a@demo.local';

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_manager::text, 'role', 'authenticated')::text, false);
  foreach v_code in array array['{SIM}', '{REAL}'] loop
    perform wms.wms_register_equipment('{TENANT}', '{WH}', v_code, 'AGV', '{ZONE}',
      v_manager, gen_random_uuid(), 'mcp-twin');
  end loop;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_gateway::text, 'role', 'authenticated')::text, false);
  foreach v_code in array array['{SIM}', '{REAL}'] loop
    select * into v_eq from wms.equipment where equipment_code = v_code;
    perform wms.wms_report_equipment_status(v_eq.id, 'IDLE', v_gateway, gen_random_uuid(),
      v_eq.version, null, 'mcp-twin');
  end loop;
end
$do$;""")


def as_manager_set_mode(code: str, simulated: bool) -> str:
    """The human write PROCESS_AGENT is refused — done off-MCP on purpose."""
    return psql(f"""
do $do$
declare v_manager uuid; v_eq wms.equipment%rowtype;
begin
  select id into v_manager from auth.users where email = 'wh-manager-a@demo.local';
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_manager::text, 'role', 'authenticated')::text, false);
  select * into v_eq from wms.equipment where equipment_code = '{code}';
  perform wms.wms_set_equipment_simulation_mode(
    v_eq.id, {str(simulated).lower()}, v_manager, gen_random_uuid(), v_eq.version, 'mcp-twin');
end
$do$;""")


def as_operator_register_profile(code: str) -> str:
    """Zero delays: this script drives the steps by hand, so nothing has to wait."""
    return psql(f"""
do $do$
declare v_op uuid; v_eq wms.equipment%rowtype;
begin
  select id into v_op from auth.users where email = 'wcs-operator-a@demo.local';
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_op::text, 'role', 'authenticated')::text, false);
  select * into v_eq from wms.equipment where equipment_code = '{code}';
  perform wms.wms_register_simulation_profile(
    v_eq.id, 0, 0, 0, 0, 0, 0, 0, v_op, gen_random_uuid(), 0, 'mcp-twin');
end
$do$;""")


async def main():
    seed()
    sim_id = psql(f"select id from wms.equipment where equipment_code = '{SIM}';")
    real_id = psql(f"select id from wms.equipment where equipment_code = '{REAL}';")

    async with Client(mcp) as c:
        # 1. the human-only writes are refused for PROCESS_AGENT --------
        forbidden_mode = out("set_equipment_simulation_mode (as PROCESS_AGENT)", await c.call_tool(
            "set_equipment_simulation_mode",
            {"equipment_id": sim_id, "is_simulated": True, "expected_version": 2}))
        assert forbidden_mode["result"] == "error", forbidden_mode
        assert forbidden_mode["error_kind"] == "FORBIDDEN", forbidden_mode

        # 2. a human turns it on, and a human gives it a profile ---------
        as_manager_set_mode(SIM, True)
        forbidden_profile = out("register_simulation_profile (as PROCESS_AGENT)", await c.call_tool(
            "register_simulation_profile",
            {"equipment_id": sim_id,
             "ack_delay_ms_min": 0, "ack_delay_ms_max": 0,
             "progress_delay_ms_min": 0, "progress_delay_ms_max": 0,
             "completion_delay_ms_min": 0, "completion_delay_ms_max": 0,
             "failure_rate": 0}))
        assert forbidden_profile["error_kind"] == "FORBIDDEN", forbidden_profile
        as_operator_register_profile(SIM)

        # 3. reading is open to everyone, and it explains the fallback ---
        profiles = out("get_simulation_profile", await c.call_tool(
            "get_simulation_profile", {"tenant_id": TENANT, "warehouse_id": WH}))
        by_code = {e["equipment_code"]: e for e in profiles["document"]["equipment"]}
        assert by_code[SIM]["is_simulated"] is True, by_code[SIM]
        assert by_code[SIM]["effective_profile"]["source"] == "REGISTERED", by_code[SIM]
        assert by_code[REAL]["is_simulated"] is False, by_code[REAL]
        assert by_code[REAL]["effective_profile"]["is_default"] is True, by_code[REAL]
        assert profiles["document"]["system_defaults"]["failure_rate"] == 0.05, profiles

        # 4. dispatch two MOVEs through the EXISTING area-1 tool. Neither the
        #    tool nor the caller knows one of these machines is a puppet.
        cmd_sim = out("dispatch_equipment_command (simulated AGV)", await c.call_tool(
            "dispatch_equipment_command",
            {"equipment_id": sim_id, "command_type": "MOVE", "expected_version":
             int(psql(f"select version from wms.equipment where id = '{sim_id}';")),
             "payload": {"to_zone": "ZONE-TWIN-X"}, "correlation_id": "mcp-twin"}))
        assert cmd_sim["status"] == "PENDING", cmd_sim
        cmd_sim_id = cmd_sim["document_id"]

        cmd_real = out("dispatch_equipment_command (real AGV)", await c.call_tool(
            "dispatch_equipment_command",
            {"equipment_id": real_id, "command_type": "MOVE", "expected_version":
             int(psql(f"select version from wms.equipment where id = '{real_id}';")),
             "payload": {"to_zone": "ZONE-TWIN-Y"}, "correlation_id": "mcp-twin"}))
        cmd_real_id = cmd_real["document_id"]

        # 5. the gateway-side polling view: one to plan, none due yet -----
        board = out("get_due_simulation_actions (before planning)", await c.call_tool(
            "get_due_simulation_actions", {"tenant_id": TENANT, "warehouse_id": WH}))
        doc = board["document"]
        unplanned = [u["command_id"] for u in doc["unplanned_commands"]]
        assert cmd_sim_id in unplanned, doc
        assert cmd_real_id not in unplanned, doc          # not simulated -> invisible
        assert doc["due_count"] == 0, doc

        # 6. plan it — idempotently ---------------------------------------
        plan = out("plan_simulated_command", await c.call_tool(
            "plan_simulated_command", {"command_id": cmd_sim_id, "correlation_id": "mcp-twin"}))
        assert plan["links"]["already_planned"] is False, plan
        assert plan["links"]["next_status"] == "ACKNOWLEDGED", plan
        assert plan["links"]["planned_terminal_status"] == "COMPLETED", plan  # failure_rate 0

        again = out("plan_simulated_command (replay)", await c.call_tool(
            "plan_simulated_command", {"command_id": cmd_sim_id}))
        assert again["links"]["already_planned"] is True, again
        assert again["document_id"] == plan["document_id"], again
        assert psql(f"select count(*) from wms.simulation_command_schedules "
                    f"where command_id = '{cmd_sim_id}';") == "1"

        refused = out("plan_simulated_command (real AGV)", await c.call_tool(
            "plan_simulated_command", {"command_id": cmd_real_id}))
        assert refused["error_kind"] == "INVALID", refused

        # 7. the monitoring read shows the plan before it happens ---------
        sched = out("get_simulation_schedule_status", await c.call_tool(
            "get_simulation_schedule_status", {"tenant_id": TENANT, "warehouse_id": WH}))
        rows = [s for s in sched["document"]["schedules"] if s["equipment_code"] == SIM]
        assert len(rows) == 1, sched
        assert rows[0]["planned_terminal_status"] == "COMPLETED", rows[0]
        assert rows[0]["profile_source"] == "REGISTERED", rows[0]

        # 8. walk it to COMPLETED — no wms_report_command_result by hand ---
        for expected_next, expected_remaining in (("ACKNOWLEDGED", True),
                                                  ("IN_PROGRESS", True),
                                                  ("COMPLETED", False)):
            step = out(f"advance_simulated_command -> {expected_next}", await c.call_tool(
                "advance_simulated_command",
                {"command_id": cmd_sim_id, "correlation_id": "mcp-twin"}))
            assert step["links"]["reported_status"] == expected_next, step
            assert step["links"]["plan_remaining"] is expected_remaining, step

        assert psql(f"select status from wms.equipment_commands where id = '{cmd_sim_id}';") \
            == "COMPLETED"
        assert psql(f"select status from wms.equipment_commands where id = '{cmd_real_id}';") \
            == "PENDING"
        assert psql(f"select count(*) from wms.simulation_command_schedules "
                    f"where command_id = '{cmd_sim_id}';") == "0"

        drained = out("advance_simulated_command (no plan left)", await c.call_tool(
            "advance_simulated_command", {"command_id": cmd_sim_id}))
        assert drained["error_kind"] == "INVALID", drained

        # the ordinary area-1 read agrees: back to IDLE, nothing in flight
        eq = out("get_equipment_status (simulated AGV)", await c.call_tool(
            "get_equipment_status",
            {"tenant_id": TENANT, "warehouse_id": WH, "equipment_id": sim_id,
             "event_limit": 6}))
        item = eq["document"]["equipment"][0]
        assert item["status"] == "IDLE", item
        assert item["has_active_command"] is False, item
        assert [e["event_type"] for e in item["recent_events"]][0] == "STATUS_CHANGED", item

        # 9. scenarios: PROCESS_AGENT IS allowed here ----------------------
        bad = out("create_simulation_scenario (empty equipment set)", await c.call_tool(
            "create_simulation_scenario",
            {"tenant_id": TENANT, "warehouse_id": WH, "name": f"MCP-TWIN-{SUFFIX} empty",
             "equipment_ids": [], "command_count": 5}))
        assert bad["error_kind"] == "INVALID", bad

        scenario = out("create_simulation_scenario", await c.call_tool(
            "create_simulation_scenario",
            {"tenant_id": TENANT, "warehouse_id": WH,
             "name": f"MCP-TWIN-{SUFFIX} two machines",
             "equipment_ids": [sim_id, real_id], "command_count": 9,
             "linked_entity_type": "dispatch_wave", "correlation_id": "mcp-twin"}))
        assert scenario["status"] == "DRAFT", scenario
        scenario_id = scenario["document_id"]

        commands_before = psql("select count(*) from wms.equipment_commands;")
        run1 = out("run_simulation_scenario", await c.call_tool(
            "run_simulation_scenario", {"scenario_id": scenario_id, "correlation_id": "mcp-twin"}))
        assert run1["status"] == "RUN", run1
        assert run1["links"]["projected_round_count"] == 5, run1     # ceil(9 / 2)
        warnings = " | ".join(run1["warnings"])
        assert "DEFAULT_PROFILE_APPLIED" in warnings, warnings       # REAL has no profile
        assert REAL in warnings, warnings
        assert "OPTIMISTIC_ESTIMATE" in warnings, warnings
        # THE point of the dry-run: not one command was dispatched
        assert psql("select count(*) from wms.equipment_commands;") == commands_before

        run2 = out("run_simulation_scenario (again)", await c.call_tool(
            "run_simulation_scenario", {"scenario_id": scenario_id}))
        assert run2["links"]["run_id"] != run1["links"]["run_id"], run2
        assert psql("select count(*) from wms.equipment_commands;") == commands_before

        status = out("get_simulation_scenario_status", await c.call_tool(
            "get_simulation_scenario_status",
            {"tenant_id": TENANT, "warehouse_id": WH, "scenario_id": scenario_id}))
        sc = status["document"]["scenarios"][0]
        assert sc["run_count"] == 2, sc
        assert sorted(sc["equipment_codes"]) == sorted([SIM, REAL]), sc
        assert sc["linked_entity_type"] == "dispatch_wave", sc

    cleanup()
    print("\nOK — digital-twin simulation MCP round-trip passed")


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except Exception:
        cleanup()
        raise
