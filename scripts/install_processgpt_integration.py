#!/usr/bin/env python3
"""Install the demo WMS MCP server and replenishment BPMN into ProcessGPT.

The installer is additive and idempotent:

* merges the ``wms`` server into ``public.tenants.mcp``;
* upserts one ProcessGPT agent whose allowed MCP server is ``wms``;
* upserts the WMS replenishment process and its three human-task forms.

It intentionally does not reset instances or WMS business data.
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
PROCESS_ID = "wms_replenishment_process"
PROCESS_NAME = "WMS 재보충·입고 프로세스"
WMS_AGENT_ID = "7b4e9ef4-6ed3-4f01-a7cf-49672902d5ba"
DEMO_USER_ID = "bd0e585b-3828-496c-92aa-3f93f336d3d3"
WMS_TENANT_ID = "localhost"
WMS_WAREHOUSE_ID = "20000000-0000-0000-0000-00000000000a"
DEMO_SKU = "SKU-A-001"


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
    request_form = f"{PROCESS_ID}_request_replenishment_form"
    approval_form = f"{PROCESS_ID}_approve_purchase_form"
    quality_form = f"{PROCESS_ID}_quality_inspection_form"
    scrap_form = f"{PROCESS_ID}_scrap_disposition_form"

    activities = [
        user_activity(
            "request_replenishment",
            "재고 부족 감지",
            "물류 관리자",
            "최소재고 미만 상품의 보충 실행을 시작한다. 데모 상품은 SKU-A-001이며 WMS 테넌트와 창고 식별자를 함께 제출한다.",
            [],
            ["재보충 요청"],
        ),
        service_activity(
            "check_stock",
            "재고·수요 확인",
            "get_availability",
            f"get_availability를 호출한다. tenant_id={WMS_TENANT_ID}, warehouse_id={WMS_WAREHOUSE_ID}, sku={DEMO_SKU}. 다른 도구는 호출하지 않는다.",
            [
                f"{request_form}.tenant_id",
                f"{request_form}.warehouse_id",
                f"{request_form}.sku",
            ],
            ["재고 가용량과 부족 여부"],
        ),
        service_activity(
            "create_rfq",
            "재보충 판단·RFQ 생성",
            "create_rfq",
            f"create_rfq를 호출한다. tenant_id={WMS_TENANT_ID}, warehouse_id={WMS_WAREHOUSE_ID}, sku={DEMO_SKU}, qty=170, dry_run=false. correlation_id에는 현재 프로세스 인스턴스 ID를 사용한다.",
            ["check_stock MCP 결과"],
            ["RFQ 문서 ID·상태·버전"],
        ),
        service_activity(
            "request_approval",
            "구매 승인 요청",
            "request_approval",
            "직전 create_rfq 결과의 document_id를 po_id로 사용해 request_approval을 호출한다. requires_human_approval과 WMS deep_link를 반환받는다.",
            ["create_rfq MCP 결과"],
            ["승인 필요 여부와 WMS deep link"],
        ),
        user_activity(
            "approve_purchase",
            "발주 승인 (HITL)",
            "구매 승인자",
            "WMS 구매주문 화면에서 문서를 검토하고 승인 또는 반려한다. 승인 후 최신 PO ID와 버전을 ProcessGPT에 제출한다.",
            ["request_approval MCP 결과"],
            ["구매 승인 결정"],
        ),
        service_activity(
            "confirm_po",
            "PO 확정",
            "confirm_po",
            "승인 폼의 po_id와 expected_version으로 confirm_po를 호출한다. dry_run=false이며 반환된 receipt_id를 보존한다.",
            [
                f"{approval_form}.po_id",
                f"{approval_form}.expected_version",
            ],
            ["확정 PO와 receipt ID"],
        ),
        service_activity(
            "register_arrival",
            "공급사 입하 통보",
            "register_arrival",
            "직전 confirm_po 결과의 document_id를 po_id로 사용해 register_arrival을 호출한다.",
            ["confirm_po MCP 결과"],
            ["도착 등록 receipt와 버전"],
        ),
        service_activity(
            "receive_goods",
            "하역·입고 등록",
            "receive",
            "직전 register_arrival 결과의 document_id를 receipt_id로, version을 expected_version으로 사용해 receive를 호출한다. qty=170, dry_run=false.",
            ["register_arrival MCP 결과"],
            ["QC_PENDING receipt"],
        ),
        user_activity(
            "quality_inspection",
            "입고 품질검사 (HITL)",
            "품질 담당",
            "WMS 품질 화면에서 실물 검사를 수행하고 합격 또는 불합격을 기록한 뒤 같은 결과와 receipt ID를 ProcessGPT에 제출한다.",
            ["receive_goods MCP 결과"],
            ["품질 판정"],
        ),
        service_activity(
            "putaway",
            "선반 배치·재고 활성화",
            "putaway",
            "품질 폼의 receipt_id로 putaway를 호출한다. 완료 결과가 AVAILABLE인지 확인한다.",
            [f"{quality_form}.receipt_id", f"{quality_form}.quality_result"],
            ["AVAILABLE 처분"],
        ),
        user_activity(
            "scrap_disposition",
            "폐기 처리 확인",
            "품질 담당",
            "WMS 품질 화면에서 불합격품 폐기를 완료한 뒤 폐기 사유와 receipt ID를 제출한다.",
            [f"{quality_form}.receipt_id", f"{quality_form}.quality_result"],
            ["폐기 완료"],
        ),
    ]

    sequences = [
        sequence("seq_start_request", "start_event", "request_replenishment"),
        sequence("seq_request_check", "request_replenishment", "check_stock"),
        sequence("seq_check_rfq", "check_stock", "create_rfq"),
        sequence("seq_rfq_reqapproval", "create_rfq", "request_approval"),
        sequence("seq_reqapproval_approve", "request_approval", "approve_purchase"),
        sequence("seq_approve_gateway", "approve_purchase", "gw_approved"),
        sequence("seq_approved_confirm", "gw_approved", "confirm_po", "승인", "approval_decision == 'APPROVED'"),
        sequence("seq_rejected_end", "gw_approved", "end_cancelled", "반려", "approval_decision == 'REJECTED'"),
        sequence("seq_confirm_arrival", "confirm_po", "register_arrival"),
        sequence("seq_arrival_receive", "register_arrival", "receive_goods"),
        sequence("seq_receive_quality", "receive_goods", "quality_inspection"),
        sequence("seq_quality_gateway", "quality_inspection", "gw_quality"),
        sequence("seq_pass_putaway", "gw_quality", "putaway", "합격", "quality_result == 'PASSED'"),
        sequence("seq_fail_scrap", "gw_quality", "scrap_disposition", "불합격", "quality_result == 'FAILED'"),
        sequence("seq_putaway_end", "putaway", "end_available"),
        sequence("seq_scrap_end", "scrap_disposition", "end_scrap"),
    ]

    roles = [
        {"name": "물류 관리자", "origin": "created", "endpoint": DEMO_USER_ID, "resolutionRule": ""},
        {"name": "구매 승인자", "origin": "created", "endpoint": DEMO_USER_ID, "resolutionRule": ""},
        {"name": "품질 담당", "origin": "created", "endpoint": DEMO_USER_ID, "resolutionRule": ""},
        {"name": "WMS 자동화", "origin": "created", "endpoint": WMS_AGENT_ID, "resolutionRule": ""},
    ]
    events = [
        {"id": "start_event", "name": "재고 부족", "role": "물류 관리자", "type": "startEvent", "process": PROCESS_ID, "trigger": "", "properties": "{}", "description": ""},
        {"id": "end_available", "name": "재고 활성화", "role": "물류 관리자", "type": "endEvent", "process": PROCESS_ID, "trigger": "", "properties": "{}", "description": ""},
        {"id": "end_cancelled", "name": "발주 취소", "role": "구매 승인자", "type": "endEvent", "process": PROCESS_ID, "trigger": "", "properties": "{}", "description": ""},
        {"id": "end_scrap", "name": "폐기 종료", "role": "품질 담당", "type": "endEvent", "process": PROCESS_ID, "trigger": "", "properties": "{}", "description": ""},
    ]
    gateways = [
        {
            "id": "gw_approved",
            "name": "승인?",
            "role": "구매 승인자",
            "type": "exclusiveGateway",
            "process": PROCESS_ID,
            "condition": {},
            "properties": "{}",
            "conditionData": [f"{approval_form}.approval_decision"],
        },
        {
            "id": "gw_quality",
            "name": "합격?",
            "role": "품질 담당",
            "type": "exclusiveGateway",
            "process": PROCESS_ID,
            "condition": {},
            "properties": "{}",
            "conditionData": [f"{quality_form}.quality_result"],
        },
    ]
    return {
        "processDefinitionName": PROCESS_NAME,
        "processDefinitionId": PROCESS_ID,
        "description": "Supabase WMS를 MCP로 호출해 재고 부족부터 RFQ, HITL 승인, PO, 입고, 품질과 적치/폐기까지 연결한다.",
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
        "start_event": ("startEvent", "재고 부족", 70, 280, 36, 36),
        "request_replenishment": ("userTask", "재고 부족 감지", 140, 260, 120, 76),
        "check_stock": ("serviceTask", "재고·수요 확인", 310, 260, 120, 76),
        "create_rfq": ("serviceTask", "재보충 판단·RFQ", 480, 260, 130, 76),
        "request_approval": ("serviceTask", "구매 승인 요청", 660, 260, 120, 76),
        "approve_purchase": ("userTask", "발주 승인 (HITL)", 830, 120, 130, 76),
        "gw_approved": ("exclusiveGateway", "승인?", 1010, 132, 50, 50),
        "end_cancelled": ("endEvent", "발주 취소", 1130, 50, 36, 36),
        "confirm_po": ("serviceTask", "PO 확정", 1130, 260, 120, 76),
        "register_arrival": ("serviceTask", "공급사 입하 통보", 1300, 260, 130, 76),
        "receive_goods": ("serviceTask", "하역·입고 등록", 1480, 260, 120, 76),
        "quality_inspection": ("userTask", "입고 품질검사", 1660, 430, 130, 76),
        "gw_quality": ("exclusiveGateway", "합격?", 1840, 443, 50, 50),
        "putaway": ("serviceTask", "선반 배치·재고 활성화", 1970, 350, 150, 76),
        "scrap_disposition": ("userTask", "폐기 처리 확인", 1970, 530, 130, 76),
        "end_available": ("endEvent", "재고 활성화", 2180, 370, 36, 36),
        "end_scrap": ("endEvent", "폐기 종료", 2180, 550, 36, 36),
    }
    flows = [
        ("seq_start_request", "start_event", "request_replenishment", ""),
        ("seq_request_check", "request_replenishment", "check_stock", ""),
        ("seq_check_rfq", "check_stock", "create_rfq", ""),
        ("seq_rfq_reqapproval", "create_rfq", "request_approval", ""),
        ("seq_reqapproval_approve", "request_approval", "approve_purchase", ""),
        ("seq_approve_gateway", "approve_purchase", "gw_approved", ""),
        ("seq_approved_confirm", "gw_approved", "confirm_po", "승인"),
        ("seq_rejected_end", "gw_approved", "end_cancelled", "반려"),
        ("seq_confirm_arrival", "confirm_po", "register_arrival", ""),
        ("seq_arrival_receive", "register_arrival", "receive_goods", ""),
        ("seq_receive_quality", "receive_goods", "quality_inspection", ""),
        ("seq_quality_gateway", "quality_inspection", "gw_quality", ""),
        ("seq_pass_putaway", "gw_quality", "putaway", "합격"),
        ("seq_fail_scrap", "gw_quality", "scrap_disposition", "불합격"),
        ("seq_putaway_end", "putaway", "end_available", ""),
        ("seq_scrap_end", "scrap_disposition", "end_scrap", ""),
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
        "Lane_automation": [
            "start_event",
            "request_replenishment",
            "check_stock",
            "create_rfq",
            "request_approval",
            "confirm_po",
            "register_arrival",
            "receive_goods",
            "end_available",
        ],
        "Lane_approval": ["approve_purchase", "gw_approved", "end_cancelled"],
        "Lane_quality": ["quality_inspection", "gw_quality", "putaway", "scrap_disposition", "end_scrap"],
    }
    lane_names = {
        "Lane_automation": "ProcessGPT · WMS 자동화",
        "Lane_approval": "구매 승인자",
        "Lane_quality": "품질·입고 담당",
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
            '<dc:Bounds x="20" y="20" width="2260" height="660"/></bpmndi:BPMNShape>',
            '<bpmndi:BPMNShape id="Lane_Automation_Shape" bpmnElement="Lane_automation">'
            '<dc:Bounds x="50" y="200" width="2230" height="180"/></bpmndi:BPMNShape>',
            '<bpmndi:BPMNShape id="Lane_Approval_Shape" bpmnElement="Lane_approval">'
            '<dc:Bounds x="50" y="20" width="2230" height="180"/></bpmndi:BPMNShape>',
            '<bpmndi:BPMNShape id="Lane_Quality_Shape" bpmnElement="Lane_quality">'
            '<dc:Bounds x="50" y="380" width="2230" height="300"/></bpmndi:BPMNShape>',
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
            "request_replenishment",
            [
                {"key": "sku", "text": "상품 SKU", "type": "text", "default": DEMO_SKU, **common},
                {"key": "tenant_id", "text": "WMS 테넌트 ID", "type": "text", "default": WMS_TENANT_ID, **common},
                {"key": "warehouse_id", "text": "WMS 창고 ID", "type": "text", "default": WMS_WAREHOUSE_ID, **common},
                {"key": "requested_qty", "text": "권장 보충 수량", "type": "number", "default": "170", **common},
                {"key": "request_note", "text": "실행 메모", "type": "textarea", **common},
            ],
        ),
        form_row(
            "approve_purchase",
            [
                {
                    "key": "approval_decision",
                    "text": "승인 결정",
                    "type": "radio",
                    "items": [{"APPROVED": "승인"}, {"REJECTED": "반려"}],
                    **common,
                },
                {"key": "po_id", "text": "WMS PO ID", "type": "text", **common},
                {"key": "expected_version", "text": "승인 후 WMS 문서 버전", "type": "number", **common},
                {"key": "wms_deep_link", "text": "WMS 문서 링크", "type": "text", **common},
                {"key": "approval_note", "text": "승인 의견", "type": "textarea", **common},
            ],
        ),
        form_row(
            "quality_inspection",
            [
                {
                    "key": "quality_result",
                    "text": "검사 결과",
                    "type": "radio",
                    "items": [{"PASSED": "합격"}, {"FAILED": "불합격"}],
                    **common,
                },
                {"key": "receipt_id", "text": "WMS Receipt ID", "type": "text", **common},
                {"key": "expected_version", "text": "WMS 문서 버전", "type": "number", **common},
                {"key": "inspection_note", "text": "검사 의견", "type": "textarea", **common},
            ],
        ),
        form_row(
            "scrap_disposition",
            [
                {"key": "receipt_id", "text": "WMS Receipt ID", "type": "text", **common},
                {"key": "reason_code", "text": "폐기 사유", "type": "text", **common},
                {"key": "scrap_confirmed", "text": "WMS 폐기 완료", "type": "checkbox", **common},
            ],
        ),
    ]


def install(api: Postgrest, mcp_url: str) -> None:
    tenants = api.request("tenants", query={"id": f"eq.{TENANT_ID}", "select": "id,mcp"})
    if not tenants:
        raise RuntimeError(f"ProcessGPT tenant '{TENANT_ID}' does not exist")
    mcp = tenants[0].get("mcp") or {}
    servers = mcp.setdefault("mcpServers", {})
    servers["wms"] = {
        "type": "http",
        "url": mcp_url,
        "transport": "streamable_http",
    }
    api.request(
        "tenants",
        method="PATCH",
        query={"id": f"eq.{TENANT_ID}"},
        payload={"mcp": mcp},
        prefer="return=representation",
    )

    api.upsert(
        "users",
        [
            {
                "id": WMS_AGENT_ID,
                "username": "WMS 실행 에이전트",
                "email": "wms-agent@localhost",
                "is_admin": False,
                "role": "WMS 자동화",
                "tenant_id": TENANT_ID,
                "goal": "ProcessGPT 서비스 활동에 지정된 WMS MCP 도구를 정확히 한 번 호출하고 구조화된 결과를 반환한다.",
                "persona": (
                    "Supabase WMS 전용 실행 에이전트다. 활동의 tool 필드로 지정된 MCP 도구만 호출한다. "
                    "문서 ID, 상태, 버전, receipt 연결을 임의로 만들지 않고 도구 반환값을 그대로 보존한다."
                ),
                "description": "ProcessGPT와 sample-app-wms를 연결하는 제한된 MCP 실행 에이전트",
                "tools": "wms",
                "skills": "",
                "is_agent": True,
                "agent_type": "agent",
                "model": "gpt-4.1",
                "alias": "wms-executor",
                "is_draft": False,
            }
        ],
        "id,tenant_id",
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
                "mcp_server": "wms",
                "mcp_url": mcp_url,
                "agent_id": WMS_AGENT_ID,
                "process_definition_id": PROCESS_ID,
                "process_definition_name": PROCESS_NAME,
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
    parser.add_argument("--mcp-url", default="http://host.docker.internal:8199/mcp")
    args = parser.parse_args()

    env = read_env(Path(args.env_file))
    service_key = os.getenv("SERVICE_ROLE_KEY") or env.get("SERVICE_ROLE_KEY")
    if not service_key:
        raise SystemExit("SERVICE_ROLE_KEY is required")
    install(Postgrest(args.processgpt_url, service_key), args.mcp_url)


if __name__ == "__main__":
    main()
