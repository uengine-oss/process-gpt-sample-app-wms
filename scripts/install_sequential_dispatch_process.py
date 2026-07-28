#!/usr/bin/env python3
"""Install the demo WMS sequential-dispatch/palletizing BPMN into ProcessGPT.

Sibling of install_processgpt_integration.py (same Postgrest-upsert pattern,
same tenant/agent/demo-user identities) but for a different capability area:
`wms_wcs-sequential-dispatch` instead of the base replenishment slice. Reuses
the same `wms` MCP server registration (install_processgpt_integration.py
must have run at least once so `tenants.mcp.mcpServers.wms` exists) and the
same WMS execution agent — PROCESS_AGENT permissions are enforced by WMS-side
RLS per tool, not by a ProcessGPT-side allow-list, so no new agent is needed.

Prerequisite: run scripts/setup_sequential_dispatch_demo_equipment.sql once
against the WMS Postgres to register the DISPATCH-CELL-01 ROBOT_CELL this
process's instruction text references by fixed equipment_id.

The installer is additive and idempotent: it only upserts one new proc_def
row and its four human-task forms. It does not touch the replenishment
process, WMS business data, or existing instances.
"""

from __future__ import annotations

import argparse
import json
import os
import uuid
from pathlib import Path
from typing import Any
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import Request, urlopen


TENANT_ID = "localhost"
PROCESS_ID = "wms_sequential_dispatch_process"
PROCESS_NAME = "WMS 서열 출고·팔레타이징 프로세스"
WMS_AGENT_ID = "7b4e9ef4-6ed3-4f01-a7cf-49672902d5ba"  # same WMS execution agent as the replenishment process
DEMO_USER_ID = "bd0e585b-3828-496c-92aa-3f93f336d3d3"
WMS_TENANT_ID = "10000000-0000-0000-0000-00000000000a"
WMS_WAREHOUSE_ID = "20000000-0000-0000-0000-00000000000a"
SKU1_ID = "fa885126-07e7-45aa-a888-b0080abbb9d2"  # SKU-A-001
SKU2_ID = "6737f77b-1f88-45d1-9428-0d5402ce07f8"  # SKU-A-002
STORE_CODE = "STORE-042"
PALLET_CODE = "PLT-DISPATCH-DEMO"
EQUIPMENT_ID = "5feced81-ef6e-41a2-9d06-a9a076c3b608"  # DISPATCH-CELL-01, from setup_sequential_dispatch_demo_equipment.sql
EQUIPMENT_CODE = "DISPATCH-CELL-01"


def read_env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip().strip('"').strip("'")
    return values


class Postgrest:
    def __init__(self, base_url: str, service_key: str):
        self.base_url = base_url.rstrip("/")
        self.headers = {
            "apikey": service_key,
            "Authorization": f"Bearer {service_key}",
            "Content-Type": "application/json",
        }

    def request(
        self,
        table: str,
        *,
        method: str = "GET",
        query: dict[str, str] | None = None,
        payload: Any = None,
        prefer: str | None = None,
    ) -> Any:
        suffix = f"?{urlencode(query)}" if query else ""
        headers = dict(self.headers)
        if prefer:
            headers["Prefer"] = prefer
        body = None if payload is None else json.dumps(payload, ensure_ascii=False).encode()
        req = Request(
            f"{self.base_url}/rest/v1/{table}{suffix}",
            data=body,
            headers=headers,
            method=method,
        )
        try:
            with urlopen(req, timeout=30) as response:
                text = response.read().decode()
                return json.loads(text) if text else None
        except HTTPError as exc:
            detail = exc.read().decode(errors="replace")
            raise RuntimeError(f"{method} {table} failed ({exc.code}): {detail}") from exc

    def upsert(self, table: str, rows: list[dict[str, Any]], conflict: str) -> Any:
        return self.request(
            table,
            method="POST",
            query={"on_conflict": conflict},
            payload=rows,
            prefer="resolution=merge-duplicates,return=representation",
        )


def service_activity(
    activity_id: str,
    name: str,
    tool_name: str,
    description: str,
    inputs: list[str],
    outputs: list[str],
) -> dict[str, Any]:
    return {
        "id": activity_id,
        "name": name,
        "role": "WMS 자동화",
        "tool": f"mcp:{tool_name}",
        "type": "serviceTask",
        "agent": WMS_AGENT_ID,
        "skills": [],
        "process": PROCESS_ID,
        "duration": 1,
        "agentMode": "complete",
        "inputData": inputs,
        "outputData": outputs,
        "properties": "{}",
        "attachments": [],
        "checkpoints": [f"`{tool_name}` 도구를 정확히 1회 호출", "구조화된 MCP 결과 보존"],
        "description": description,
        "instruction": description,
        "orchestration": None,
        "attachedEvents": [],
        "customProperties": [],
        "agentAssignedFrom": "manual",
    }


def user_activity(
    activity_id: str,
    name: str,
    role: str,
    description: str,
    inputs: list[str],
    outputs: list[str],
) -> dict[str, Any]:
    return {
        "id": activity_id,
        "name": name,
        "role": role,
        "tool": f"formHandler:{PROCESS_ID}_{activity_id}_form",
        "type": "userTask",
        "agent": None,
        "skills": [],
        "process": PROCESS_ID,
        "duration": 1,
        "agentMode": "none",
        "inputData": inputs,
        "outputData": outputs,
        "properties": "{}",
        "attachments": [],
        "checkpoints": [],
        "description": description,
        "instruction": description,
        "orchestration": None,
        "attachedEvents": [],
        "customProperties": [],
    }


def sequence(seq_id: str, source: str, target: str, name: str = "", condition: str = "") -> dict[str, Any]:
    properties: dict[str, str] = {}
    if condition:
        properties = {"conditionFunction": condition, "condition": name}
    return {
        "id": seq_id,
        "name": name,
        "source": source,
        "target": target,
        "condition": name if condition else "",
        "properties": json.dumps(properties, ensure_ascii=False),
    }


def build_definition() -> dict[str, Any]:
    plan_form = f"{PROCESS_ID}_register_outbound_plan_form"
    result_form = f"{PROCESS_ID}_confirm_palletize_result_form"
    repack_form = f"{PROCESS_ID}_handle_repack_exception_form"

    activities = [
        user_activity(
            "register_outbound_plan",
            "출고 계획 등록",
            "출고 계획 담당자",
            f"{STORE_CODE} 매장으로 SKU-A-001·SKU-A-002를 한 팔레트({PALLET_CODE})로 묶어 서열 출고할 계획을 등록한다. 데모 값이 이미 채워져 있다.",
            [],
            ["출고 계획"],
        ),
        service_activity(
            "create_outbound_order_1",
            "출고 단위 등록 (SKU-A-001)",
            "create_outbound_order",
            f"create_outbound_order를 호출한다. tenant_id={WMS_TENANT_ID}, warehouse_id={WMS_WAREHOUSE_ID}, "
            f"store_code={STORE_CODE}, product_id={SKU1_ID}, qty=40, declared_weight_kg=18, declared_volume_l=30, "
            "order_number='OB-DEMO-001'. correlation_id에는 현재 프로세스 인스턴스 ID를 사용한다. 다른 도구는 호출하지 않는다.",
            [f"{plan_form}.store_code"],
            ["출고 단위 1 문서 ID·상태·버전"],
        ),
        service_activity(
            "create_outbound_order_2",
            "출고 단위 등록 (SKU-A-002)",
            "create_outbound_order",
            f"create_outbound_order를 호출한다. tenant_id={WMS_TENANT_ID}, warehouse_id={WMS_WAREHOUSE_ID}, "
            f"store_code={STORE_CODE}, product_id={SKU2_ID}, qty=25, declared_weight_kg=11, declared_volume_l=22, "
            "order_number='OB-DEMO-002'. correlation_id에는 현재 프로세스 인스턴스 ID를 사용한다. 다른 도구는 호출하지 않는다.",
            [f"{plan_form}.store_code"],
            ["출고 단위 2 문서 ID·상태·버전"],
        ),
        service_activity(
            "open_wave",
            "디스패치 웨이브 오픈",
            "open_dispatch_wave",
            f"open_dispatch_wave를 호출한다. tenant_id={WMS_TENANT_ID}, warehouse_id={WMS_WAREHOUSE_ID}. "
            "반환된 document_id를 이후 단계의 wave_id로 그대로 사용한다.",
            [],
            ["웨이브 ID"],
        ),
        service_activity(
            "assign_sequence_1",
            "서열 배정 (1번, SKU-A-001)",
            "assign_dispatch_sequence",
            f"직전 create_outbound_order_1 결과의 outbound_order_id와 open_wave 결과의 wave_id로 assign_dispatch_sequence를 "
            f"호출한다. sequence_position=1, target_pallet_code='{PALLET_CODE}', expected_version은 create_outbound_order_1이 "
            "반환한 version을 사용한다.",
            ["create_outbound_order_1 MCP 결과", "open_wave MCP 결과"],
            ["서열 배정 1 상태"],
        ),
        service_activity(
            "assign_sequence_2",
            "서열 배정 (2번, SKU-A-002)",
            "assign_dispatch_sequence",
            f"직전 create_outbound_order_2 결과의 outbound_order_id와 open_wave 결과의 wave_id로 assign_dispatch_sequence를 "
            f"호출한다. sequence_position=2, target_pallet_code='{PALLET_CODE}', expected_version은 create_outbound_order_2가 "
            "반환한 version을 사용한다.",
            ["create_outbound_order_2 MCP 결과", "open_wave MCP 결과"],
            ["서열 배정 2 상태"],
        ),
        service_activity(
            "get_equipment_status",
            "로봇 셀 상태 조회",
            "get_equipment_status",
            f"get_equipment_status를 호출해 {EQUIPMENT_CODE}(equipment_id={EQUIPMENT_ID})의 현재 상태와 version을 확인한다. "
            "이 호출이 반환하는 JSON의 최상위 'version' 숫자 필드가 다음 단계에서 그대로 써야 할 값이다 — "
            "1처럼 임의의 기본값을 지어내지 말고, 이 응답에 실제로 찍힌 숫자를 정확히 인용한다.",
            [],
            ["설비 상태·버전"],
        ),
        service_activity(
            "dispatch_palletize",
            "팔레타이징 명령 전송",
            "dispatch_palletize_command",
            f"dispatch_palletize_command를 호출한다. equipment_id={EQUIPMENT_ID}, wave_id는 open_wave 결과, "
            f"target_pallet_code='{PALLET_CODE}', max_weight_kg=250, max_volume_l=500. "
            "expected_version은 **직전 get_equipment_status 결과에 실제로 찍힌 'version' 숫자를 그대로** 써야 한다 "
            "— 1을 기본값으로 짐작해서 쓰지 마라, 반드시 이전 산출물 텍스트에서 그 숫자를 찾아 인용해야 한다. "
            "만약 이 호출이 'CONFLICT: expected version X but found Y' 형태의 에러를 반환하면, 에러 메시지에 적힌 "
            "found 뒤의 숫자 Y를 새 expected_version으로 삼아 즉시 한 번 더 호출한다(재시도는 최대 1회).",
            ["assign_sequence_1 MCP 결과", "assign_sequence_2 MCP 결과", "get_equipment_status MCP 결과"],
            ["PALLETIZE 명령 ID와 DISPATCHED 상태"],
        ),
        user_activity(
            "confirm_palletize_result",
            "팔레타이징 결과 확인 (HITL)",
            "설비 운영자",
            "WMS 서열출고 화면(/wcs/sequential-dispatch)에서 이 팔레트의 매니페스트를 확인하고, 설비가 실제로 보고한 결과"
            "(outcome)를 그대로 기록한다 — 좋게 보이도록 고쳐 쓰지 않는다.",
            ["dispatch_palletize MCP 결과"],
            ["팔레타이징 결과"],
        ),
        service_activity(
            "verify_dispatch_status",
            "출고 서열 현황 최종 확인",
            "get_dispatch_sequence_status",
            f"get_dispatch_sequence_status를 호출한다. tenant_id={WMS_TENANT_ID}, warehouse_id={WMS_WAREHOUSE_ID}, "
            "wave_id는 open_wave 결과. 두 서열 배정이 모두 COMPLETED인지 확인한다.",
            [f"{result_form}.outcome"],
            ["웨이브 최종 현황"],
        ),
        user_activity(
            "handle_repack_exception",
            "재포장 지시 (HITL)",
            "출고 계획 담당자",
            "중량/용적 초과 또는 적재 실패로 팔레트에 실리지 못한 품목의 재포장·재계획 지시를 기록한다. 실제 재출고는 "
            "별도 사이클(새 서열 배정)로 처리하며, 이 활동은 지시 기록까지만 담당한다.",
            [f"{result_form}.outcome", f"{result_form}.equipment_command_id"],
            ["재포장 지시"],
        ),
    ]

    sequences = [
        sequence("seq_start_plan", "start_event", "register_outbound_plan"),
        sequence("seq_plan_order1", "register_outbound_plan", "create_outbound_order_1"),
        sequence("seq_order1_order2", "create_outbound_order_1", "create_outbound_order_2"),
        sequence("seq_order2_wave", "create_outbound_order_2", "open_wave"),
        sequence("seq_wave_seq1", "open_wave", "assign_sequence_1"),
        sequence("seq_seq1_seq2", "assign_sequence_1", "assign_sequence_2"),
        sequence("seq_seq2_equipstatus", "assign_sequence_2", "get_equipment_status"),
        sequence("seq_equipstatus_dispatch", "get_equipment_status", "dispatch_palletize"),
        sequence("seq_dispatch_confirm", "dispatch_palletize", "confirm_palletize_result"),
        sequence("seq_confirm_gateway", "confirm_palletize_result", "gw_outcome"),
        sequence("seq_normal_verify", "gw_outcome", "verify_dispatch_status", "정상",
                 "outcome == 'SUCCESS' || outcome == 'PARTIAL'"),
        sequence("seq_exception_repack", "gw_outcome", "handle_repack_exception", "예외",
                 "outcome == 'OVERWEIGHT' || outcome == 'OVERVOLUME' || outcome == 'ABORTED'"),
        sequence("seq_verify_end", "verify_dispatch_status", "end_dispatched"),
        sequence("seq_repack_end", "handle_repack_exception", "end_exception"),
    ]

    roles = [
        {"name": "출고 계획 담당자", "origin": "created", "endpoint": DEMO_USER_ID, "resolutionRule": ""},
        {"name": "설비 운영자", "origin": "created", "endpoint": DEMO_USER_ID, "resolutionRule": ""},
        {"name": "WMS 자동화", "origin": "created", "endpoint": WMS_AGENT_ID, "resolutionRule": ""},
    ]
    events = [
        {"id": "start_event", "name": "출고 계획 필요", "role": "출고 계획 담당자", "type": "startEvent", "process": PROCESS_ID, "trigger": "", "properties": "{}", "description": ""},
        {"id": "end_dispatched", "name": "출고 완료", "role": "설비 운영자", "type": "endEvent", "process": PROCESS_ID, "trigger": "", "properties": "{}", "description": ""},
        {"id": "end_exception", "name": "예외 처리 완료 — 재출고 대기", "role": "출고 계획 담당자", "type": "endEvent", "process": PROCESS_ID, "trigger": "", "properties": "{}", "description": ""},
    ]
    gateways = [
        {
            "id": "gw_outcome",
            "name": "결과?",
            "role": "설비 운영자",
            "type": "exclusiveGateway",
            "process": PROCESS_ID,
            "condition": {},
            "properties": "{}",
            "conditionData": [f"{result_form}.outcome"],
        },
    ]
    return {
        "processDefinitionName": PROCESS_NAME,
        "processDefinitionId": PROCESS_ID,
        "description": (
            "두 매장 출고 단위를 하나의 팔레트로 묶어 로봇 셀에 팔레타이징 명령을 보내고, 정상 결과는 자동으로 "
            "마무리하되 중량/용적 초과나 적재 실패만 사람의 재포장 지시로 넘긴다 — 정상 경로엔 사람이 없고 "
            "예외에만 등장하는 패턴."
        ),
        "data": [],
        "roles": roles,
        "events": events,
        "skills": [],
        "gateways": gateways,
        "sequences": sequences,
        "activities": activities,
    }


def build_bpmn() -> str:
    nodes = {
        "start_event": ("startEvent", "출고 계획 필요", 60, 320, 36, 36),
        "register_outbound_plan": ("userTask", "출고 계획 등록", 130, 300, 130, 76),
        "create_outbound_order_1": ("serviceTask", "출고 단위 등록\n(SKU-A-001)", 310, 300, 140, 76),
        "create_outbound_order_2": ("serviceTask", "출고 단위 등록\n(SKU-A-002)", 500, 300, 140, 76),
        "open_wave": ("serviceTask", "디스패치 웨이브 오픈", 690, 300, 130, 76),
        "assign_sequence_1": ("serviceTask", "서열 배정 1", 870, 300, 120, 76),
        "assign_sequence_2": ("serviceTask", "서열 배정 2", 1040, 300, 120, 76),
        "get_equipment_status": ("serviceTask", "로봇 셀 상태 조회", 1210, 300, 130, 76),
        "dispatch_palletize": ("serviceTask", "팔레타이징 명령 전송", 1390, 300, 140, 76),
        "confirm_palletize_result": ("userTask", "팔레타이징 결과 확인\n(HITL)", 1580, 300, 150, 76),
        "gw_outcome": ("exclusiveGateway", "결과?", 1780, 313, 50, 50),
        "verify_dispatch_status": ("serviceTask", "출고 서열 현황 최종 확인", 1900, 190, 150, 76),
        "handle_repack_exception": ("userTask", "재포장 지시 (HITL)", 1900, 420, 140, 76),
        "end_dispatched": ("endEvent", "출고 완료", 2110, 210, 36, 36),
        "end_exception": ("endEvent", "예외 처리 완료", 2100, 440, 36, 36),
    }
    flows = [
        ("seq_start_plan", "start_event", "register_outbound_plan", ""),
        ("seq_plan_order1", "register_outbound_plan", "create_outbound_order_1", ""),
        ("seq_order1_order2", "create_outbound_order_1", "create_outbound_order_2", ""),
        ("seq_order2_wave", "create_outbound_order_2", "open_wave", ""),
        ("seq_wave_seq1", "open_wave", "assign_sequence_1", ""),
        ("seq_seq1_seq2", "assign_sequence_1", "assign_sequence_2", ""),
        ("seq_seq2_equipstatus", "assign_sequence_2", "get_equipment_status", ""),
        ("seq_equipstatus_dispatch", "get_equipment_status", "dispatch_palletize", ""),
        ("seq_dispatch_confirm", "dispatch_palletize", "confirm_palletize_result", ""),
        ("seq_confirm_gateway", "confirm_palletize_result", "gw_outcome", ""),
        ("seq_normal_verify", "gw_outcome", "verify_dispatch_status", "정상"),
        ("seq_exception_repack", "gw_outcome", "handle_repack_exception", "예외"),
        ("seq_verify_end", "verify_dispatch_status", "end_dispatched", ""),
        ("seq_repack_end", "handle_repack_exception", "end_exception", ""),
    ]
    incoming: dict[str, list[str]] = {key: [] for key in nodes}
    outgoing: dict[str, list[str]] = {key: [] for key in nodes}
    for flow_id, source, target, _name in flows:
        outgoing[source].append(flow_id)
        incoming[target].append(flow_id)

    def node_xml(node_id: str) -> str:
        kind, name, *_bounds = nodes[node_id]
        tag = f"bpmn:{kind}"
        io = "".join(f"<bpmn:incoming>{flow}</bpmn:incoming>" for flow in incoming[node_id])
        io += "".join(f"<bpmn:outgoing>{flow}</bpmn:outgoing>" for flow in outgoing[node_id])
        if kind in {"userTask", "serviceTask"}:
            definition = build_definition()
            activity = next(item for item in definition["activities"] if item["id"] == node_id)
            extension = (
                "<bpmn:extensionElements><uengine:properties><uengine:json>"
                + json.dumps(
                    {
                        "instruction": activity["instruction"],
                        "role": activity["role"],
                        "agent": activity["agent"],
                        "agentMode": activity["agentMode"],
                        "tool": activity["tool"],
                        "inputData": activity["inputData"],
                        "outputData": activity["outputData"],
                    },
                    ensure_ascii=False,
                )
                .replace("&", "&amp;")
                .replace("<", "&lt;")
                .replace(">", "&gt;")
                + "</uengine:json></uengine:properties></bpmn:extensionElements>"
            )
        else:
            extension = ""
        return f'<{tag} id="{node_id}" name="{name}">{io}{extension}</{tag}>'

    flow_xml = "".join(
        f'<bpmn:sequenceFlow id="{flow_id}"'
        + (f' name="{name}"' if name else "")
        + f' sourceRef="{source}" targetRef="{target}"/>'
        for flow_id, source, target, name in flows
    )
    node_markup = "".join(node_xml(node_id) for node_id in nodes)

    lane_members = {
        "Lane_planner": ["start_event", "register_outbound_plan", "handle_repack_exception", "end_exception"],
        "Lane_automation": [
            "create_outbound_order_1",
            "create_outbound_order_2",
            "open_wave",
            "assign_sequence_1",
            "assign_sequence_2",
            "get_equipment_status",
            "dispatch_palletize",
            "verify_dispatch_status",
        ],
        "Lane_operator": ["confirm_palletize_result", "gw_outcome", "end_dispatched"],
    }
    lane_names = {
        "Lane_planner": "출고 계획 담당자",
        "Lane_automation": "ProcessGPT · WMS 자동화",
        "Lane_operator": "설비 운영자",
    }
    lanes = "".join(
        f'<bpmn:lane id="{lane_id}" name="{lane_names[lane_id]}">'
        + "".join(f"<bpmn:flowNodeRef>{node}</bpmn:flowNodeRef>" for node in members)
        + "</bpmn:lane>"
        for lane_id, members in lane_members.items()
    )

    shapes = []
    for node_id, (_kind, _name, x, y, width, height) in nodes.items():
        marker = ' isMarkerVisible="true"' if _kind == "exclusiveGateway" else ""
        shapes.append(
            f'<bpmndi:BPMNShape id="Shape_{node_id}" bpmnElement="{node_id}"{marker}>'
            f'<dc:Bounds x="{x}" y="{y}" width="{width}" height="{height}"/>'
            "</bpmndi:BPMNShape>"
        )
    shapes.extend(
        [
            '<bpmndi:BPMNShape id="Participant_Shape" bpmnElement="Participant">'
            '<dc:Bounds x="20" y="20" width="2280" height="560"/></bpmndi:BPMNShape>',
            '<bpmndi:BPMNShape id="Lane_Planner_Shape" bpmnElement="Lane_planner">'
            '<dc:Bounds x="50" y="180" width="2250" height="220"/></bpmndi:BPMNShape>',
            '<bpmndi:BPMNShape id="Lane_Automation_Shape" bpmnElement="Lane_automation">'
            '<dc:Bounds x="50" y="20" width="2250" height="160"/></bpmndi:BPMNShape>',
            '<bpmndi:BPMNShape id="Lane_Operator_Shape" bpmnElement="Lane_operator">'
            '<dc:Bounds x="50" y="400" width="2250" height="180"/></bpmndi:BPMNShape>',
        ]
    )

    def center(node_id: str) -> tuple[float, float]:
        _kind, _name, x, y, width, height = nodes[node_id]
        return x + width / 2, y + height / 2

    edges = []
    for flow_id, source, target, _name in flows:
        sx, sy = center(source)
        tx, ty = center(target)
        edges.append(
            f'<bpmndi:BPMNEdge id="Edge_{flow_id}" bpmnElement="{flow_id}">'
            f'<di:waypoint x="{sx}" y="{sy}"/><di:waypoint x="{tx}" y="{ty}"/>'
            "</bpmndi:BPMNEdge>"
        )

    return (
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<bpmn:definitions xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
        'xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL" '
        'xmlns:bpmndi="http://www.omg.org/spec/BPMN/20100524/DI" '
        'xmlns:uengine="http://uengine" xmlns:dc="http://www.omg.org/spec/DD/20100524/DC" '
        'xmlns:di="http://www.omg.org/spec/DD/20100524/DI" '
        f'id="Definitions_{PROCESS_ID}" targetNamespace="http://bpmn.io/schema/bpmn">'
        f'<bpmn:collaboration id="Collaboration_1"><bpmn:participant id="Participant" name="{PROCESS_NAME}" processRef="Process_1"/></bpmn:collaboration>'
        f'<bpmn:process id="Process_1" name="{PROCESS_NAME}" isExecutable="true">'
        + flow_xml
        + node_markup
        + f'<bpmn:laneSet id="LaneSet_1">{lanes}</bpmn:laneSet>'
        + "</bpmn:process>"
        + '<bpmndi:BPMNDiagram id="BPMNDiagram_1"><bpmndi:BPMNPlane id="BPMNPlane_1" bpmnElement="Collaboration_1">'
        + "".join(shapes)
        + "".join(edges)
        + "</bpmndi:BPMNPlane></bpmndi:BPMNDiagram></bpmn:definitions>"
    )


def form_row(activity_id: str, fields: list[dict[str, Any]]) -> dict[str, Any]:
    form_id = f"{PROCESS_ID}_{activity_id}_form"
    return {
        "uuid": str(uuid.uuid5(uuid.NAMESPACE_URL, f"process-gpt:{TENANT_ID}:{form_id}")),
        "html": "",
        "proc_def_id": PROCESS_ID,
        "activity_id": activity_id,
        "tenant_id": TENANT_ID,
        "id": form_id,
        "fields_json": fields,
    }


def build_forms() -> list[dict[str, Any]]:
    common = {"disabled": "false", "readonly": "false"}
    return [
        form_row(
            "register_outbound_plan",
            [
                {"key": "store_code", "text": "매장 코드", "type": "text", "default": STORE_CODE, **common},
                {"key": "sku_1", "text": "품목 1", "type": "text", "default": "SKU-A-001 · 40개", **common},
                {"key": "sku_2", "text": "품목 2", "type": "text", "default": "SKU-A-002 · 25개", **common},
                {"key": "target_pallet_code", "text": "목표 팔레트", "type": "text", "default": PALLET_CODE, **common},
                {"key": "plan_note", "text": "계획 메모", "type": "textarea", **common},
            ],
        ),
        form_row(
            "confirm_palletize_result",
            [
                {
                    "key": "outcome",
                    "text": "설비 보고 결과",
                    "type": "radio",
                    "items": [
                        {"SUCCESS": "성공"},
                        {"PARTIAL": "부분 적재"},
                        {"OVERWEIGHT": "중량 초과"},
                        {"OVERVOLUME": "용적 초과"},
                        {"ABORTED": "중단"},
                    ],
                    **common,
                },
                {"key": "equipment_command_id", "text": "설비 명령 ID", "type": "text", **common},
                {"key": "pallet_code", "text": "팔레트 코드", "type": "text", "default": PALLET_CODE, **common},
                {"key": "confirm_note", "text": "확인 의견", "type": "textarea", **common},
            ],
        ),
        form_row(
            "handle_repack_exception",
            [
                {"key": "reason_code", "text": "예외 사유", "type": "text", **common},
                {"key": "repack_note", "text": "재포장·재계획 지시", "type": "textarea", **common},
                {"key": "escalated", "text": "관리자 에스컬레이션 필요", "type": "checkbox", **common},
            ],
        ),
    ]


def install(api: Postgrest) -> None:
    tenants = api.request("tenants", query={"id": f"eq.{TENANT_ID}", "select": "id,mcp"})
    if not tenants:
        raise RuntimeError(f"ProcessGPT tenant '{TENANT_ID}' does not exist")
    mcp = tenants[0].get("mcp") or {}
    if not (mcp.get("mcpServers") or {}).get("wms"):
        raise RuntimeError(
            "tenants.mcp.mcpServers.wms is not registered — run install_processgpt_integration.py first"
        )

    definition = build_definition()
    api.upsert(
        "proc_def",
        [
            {
                "id": PROCESS_ID,
                "name": PROCESS_NAME,
                "definition": definition,
                "bpmn": build_bpmn(),
                "prod_version": None,
                "uuid": str(uuid.uuid5(uuid.NAMESPACE_URL, f"process-gpt:{TENANT_ID}:{PROCESS_ID}")),
                "tenant_id": TENANT_ID,
                "isdeleted": False,
                "owner": DEMO_USER_ID,
                "agent_id": WMS_AGENT_ID,
                "type": "bpmn",
                "is_draft": False,
            }
        ],
        "uuid",
    )
    api.upsert("form_def", build_forms(), "uuid")

    print(
        json.dumps(
            {
                "tenant_id": TENANT_ID,
                "process_definition_id": PROCESS_ID,
                "process_definition_name": PROCESS_NAME,
                "equipment_id": EQUIPMENT_ID,
                "equipment_code": EQUIPMENT_CODE,
                "forms": [row["id"] for row in build_forms()],
            },
            ensure_ascii=False,
            indent=2,
        )
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--env-file", default=str(Path(__file__).resolve().parents[3] / ".env"))
    parser.add_argument("--processgpt-url", default="http://127.0.0.1:54321")
    args = parser.parse_args()

    env = read_env(Path(args.env_file))
    service_key = os.getenv("SERVICE_ROLE_KEY") or env.get("SERVICE_ROLE_KEY")
    if not service_key:
        raise SystemExit("SERVICE_ROLE_KEY is required")
    install(Postgrest(args.processgpt_url, service_key))


if __name__ == "__main__":
    main()
