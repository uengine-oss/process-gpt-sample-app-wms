"""wms-mcp: FastMCP tools wrapping the wms.wms_* Postgres RPCs.

Pattern mirrors services/office-mcp/office_mcp/mcp_server.py: a single
FastMCP instance, @mcp.tool async functions with Annotated/Field params,
served over streamable-HTTP by main.py.

Scope: docs/02-contracts.md — the demo-first vertical slice (shortage ->
RFQ -> HITL approval -> PO -> receiving -> quality -> scrap/putaway).
Tools not in that slice (notify_supplier, return_to_supplier, get_status,
compensate, outbound/returns/counting/traceability) are not implemented
here yet.
"""

import logging
import uuid
from typing import Annotated, Optional

from fastmcp import FastMCP
from pydantic import Field

from .client import (
    WmsCommandError,
    classify_error,
    ensure_tenant_provisioned,
    get_authed_client,
    get_auditor_client,
    get_gateway_client,
)

logger = logging.getLogger("wms_mcp")

mcp = FastMCP("process-gpt-wms-mcp")


def _new_key() -> str:
    return str(uuid.uuid4())


def _call_rpc(fn_name: str, params: dict) -> dict:
    client, _agent_user_id = get_authed_client()
    try:
        if params.get("p_tenant_id"):
            ensure_tenant_provisioned(params["p_tenant_id"])
        resp = client.rpc(fn_name, params).execute()
        return resp.data
    except Exception as exc:  # noqa: BLE001 - translated into a structured tool result below
        raise classify_error(exc) from exc


def _call_rpc_as_gateway(fn_name: str, params: dict) -> dict:
    """Same as _call_rpc but authenticated as the WCS_GATEWAY service identity.

    Used only by the equipment -> WMS feedback tools; PROCESS_AGENT is refused
    by RLS for those RPCs on purpose (design.md D5).
    """
    client, _gateway_user_id = get_gateway_client()
    try:
        if params.get("p_tenant_id"):
            ensure_tenant_provisioned(params["p_tenant_id"])
        resp = client.rpc(fn_name, params).execute()
        return resp.data
    except Exception as exc:  # noqa: BLE001 - translated into a structured tool result below
        raise classify_error(exc) from exc


def _call_rpc_as_auditor(fn_name: str, params: dict) -> dict:
    """Same as _call_rpc but authenticated as the read-only AUDITOR identity.

    Only the two audit-log tools use this. PROCESS_AGENT is refused by the RPC
    itself (20260806 D2) — auditing is a human oversight surface pointed AT the
    agent, so the agent does not get to read it.
    """
    client, _auditor_user_id = get_auditor_client()
    try:
        if params.get("p_tenant_id"):
            ensure_tenant_provisioned(params["p_tenant_id"])
        resp = client.rpc(fn_name, params).execute()
        return resp.data
    except Exception as exc:  # noqa: BLE001 - translated into a structured tool result below
        raise classify_error(exc) from exc


def _agent_user_id() -> str:
    _client, user_id = get_authed_client()
    return user_id


def _gateway_user_id() -> str:
    _client, user_id = get_gateway_client()
    return user_id


def _error_result(exc: WmsCommandError) -> dict:
    status_map = {"CONFLICT": 409, "FORBIDDEN": 403, "INVALID": 422, "UNKNOWN": 500}
    return {
        "result": "error",
        "error_kind": exc.kind,
        "http_status_equivalent": status_map[exc.kind],
        "message": str(exc),
    }


@mcp.tool
async def get_availability(
    tenant_id: Annotated[str, Field(description="테넌트 ID (ProcessGPT tenant_id)")],
    warehouse_id: Annotated[str, Field(description="창고 UUID")],
    sku: Annotated[str, Field(description="상품 SKU")],
) -> dict:
    """재고 가용량과 부족 여부를 조회한다 (읽기 전용, BPMN "재고·수요 확인" 활동)."""
    try:
        data = _call_rpc("wms_check_stock", {
            "p_tenant_id": tenant_id, "p_warehouse_id": warehouse_id, "p_sku": sku,
        })
        return {"result": "ok", "document": data}
    except WmsCommandError as exc:
        return _error_result(exc)


@mcp.tool
async def list_warehouse_stock(
    tenant_id: Annotated[str, Field(description="테넌트 ID (ProcessGPT tenant_id)")],
) -> dict:
    """테넌트의 모든 창고와 각 창고의 전 품목 재고 가용량을 조회한다 (읽기 전용).

    warehouse_id/sku를 모르는 상태에서 재고 현황을 한눈에 파악할 때 사용한다.
    호출자가 접근 권한을 가진 창고만 반환된다(wms.current_warehouse_ids).
    """
    try:
        data = _call_rpc("wms_list_warehouse_stock", {"p_tenant_id": tenant_id})
        return {"result": "ok", "document": data}
    except WmsCommandError as exc:
        return _error_result(exc)


@mcp.tool
async def create_rfq(
    tenant_id: Annotated[str, Field(description="테넌트 ID (ProcessGPT tenant_id)")],
    warehouse_id: Annotated[str, Field(description="창고 UUID")],
    sku: Annotated[str, Field(description="상품 SKU")],
    qty: Annotated[float, Field(description="제안 발주 수량")],
    supplier_id: Annotated[Optional[str], Field(description="공급사 UUID (선택)")] = None,
    correlation_id: Annotated[Optional[str], Field(description="ProcessGPT process_instance_id 등 상관관계 ID")] = None,
    idempotency_key: Annotated[Optional[str], Field(description="재시도 시 동일 키 재사용. 미지정 시 새로 생성")] = None,
    dry_run: Annotated[bool, Field(description="true면 실제 반영 없이 예상 결과만 반환")] = False,
) -> dict:
    """재보충 판단 결과로 RFQ(구매 필요 제안)를 생성한다. 생성 즉시 승인 대기(TO_APPROVE) 상태가 된다."""
    if dry_run:
        return {"result": "dry_run", "would_call": "wms_create_rfq", "input": {
            "tenant_id": tenant_id, "warehouse_id": warehouse_id, "sku": sku, "qty": qty, "supplier_id": supplier_id,
        }}
    try:
        data = _call_rpc("wms_create_rfq", {
            "p_tenant_id": tenant_id, "p_warehouse_id": warehouse_id, "p_sku": sku, "p_qty": qty,
            "p_supplier_id": supplier_id, "p_actor_id": _agent_user_id(),
            "p_idempotency_key": idempotency_key or _new_key(), "p_correlation_id": correlation_id,
        })
        return {
            "result": "ok", "document_id": data["po_id"], "status": data["status"], "version": data["version"],
            "next_actions": ["request_approval"],
        }
    except WmsCommandError as exc:
        return _error_result(exc)


@mcp.tool
async def request_approval(
    po_id: Annotated[str, Field(description="RFQ/PO UUID (create_rfq가 반환한 document_id)")],
) -> dict:
    """구매 승인 HITL을 트리거한다.

    이 도구는 판정을 내리지 않는다 — 승인/반려는 PURCHASE_APPROVER 역할의 실제
    사람이 WMS 프론트엔드에서 로그인해 결정해야 한다(design.md D6). 이 도구는
    현재 문서 상태를 조회해 사람 승인이 필요함을 구조화된 형태로 반환한다.
    """
    client, _ = get_authed_client()
    resp = client.table("purchase_orders").select("*").eq("id", po_id).execute()
    if not resp.data:
        return _error_result(WmsCommandError("INVALID", f"INVALID: unknown po {po_id}"))
    po = resp.data[0]
    return {
        "result": "ok",
        "requires_human_approval": po["status"] == "TO_APPROVE",
        "document": po,
        "deep_link": f"/procurement/purchase-orders/{po_id}",
    }


@mcp.tool
async def confirm_po(
    po_id: Annotated[str, Field(description="PO UUID")],
    expected_version: Annotated[int, Field(description="낙관적 동시성 버전 — request_approval/조회로 얻은 version")],
    idempotency_key: Annotated[Optional[str], Field(description="재시도 시 동일 키 재사용")] = None,
    dry_run: Annotated[bool, Field(description="true면 실제 반영 없이 예상 결과만 반환")] = False,
) -> dict:
    """승인된 RFQ를 PO로 확정한다. 확정과 동시에 입고 receipt이 EXPECTED 상태로 생성된다."""
    if dry_run:
        return {"result": "dry_run", "would_call": "wms_confirm_purchase_order", "input": {"po_id": po_id}}
    try:
        data = _call_rpc("wms_confirm_purchase_order", {
            "p_po_id": po_id, "p_actor_id": _agent_user_id(),
            "p_idempotency_key": idempotency_key or _new_key(), "p_expected_version": expected_version,
        })
        return {
            "result": "ok", "document_id": data["po_id"], "status": data["status"], "version": data["version"],
            "links": {"receipt_id": data["receipt_id"]}, "next_actions": ["register_arrival"],
        }
    except WmsCommandError as exc:
        return _error_result(exc)


@mcp.tool
async def register_arrival(
    po_id: Annotated[str, Field(description="PO UUID")],
    idempotency_key: Annotated[Optional[str], Field(description="재시도 시 동일 키 재사용")] = None,
    dry_run: Annotated[bool, Field(description="true면 실제 반영 없이 예상 결과만 반환")] = False,
) -> dict:
    """공급사 상품의 하역장 도착을 등록한다 (receipt: EXPECTED -> ARRIVED)."""
    if dry_run:
        return {"result": "dry_run", "would_call": "wms_register_arrival", "input": {"po_id": po_id}}
    try:
        data = _call_rpc("wms_register_arrival", {
            "p_po_id": po_id, "p_actor_id": _agent_user_id(), "p_idempotency_key": idempotency_key or _new_key(),
        })
        return {
            "result": "ok", "document_id": data["receipt_id"], "status": data["status"], "version": data["version"],
            "next_actions": ["receive"],
        }
    except WmsCommandError as exc:
        return _error_result(exc)


@mcp.tool
async def receive(
    receipt_id: Annotated[str, Field(description="Receipt UUID")],
    qty: Annotated[float, Field(description="실제 입고 수량")],
    expected_version: Annotated[int, Field(description="낙관적 동시성 버전")],
    idempotency_key: Annotated[Optional[str], Field(description="재시도 시 동일 키 재사용")] = None,
    dry_run: Annotated[bool, Field(description="true면 실제 반영 없이 예상 결과만 반환")] = False,
) -> dict:
    """입고 수량을 등록한다 (receipt: ARRIVED -> QC_PENDING, 원장에 QC 상태로 기록되어
    검수 전에는 가용재고로 잡히지 않는다)."""
    if dry_run:
        return {"result": "dry_run", "would_call": "wms_receive", "input": {"receipt_id": receipt_id, "qty": qty}}
    try:
        data = _call_rpc("wms_receive", {
            "p_receipt_id": receipt_id, "p_qty": qty, "p_actor_id": _agent_user_id(),
            "p_idempotency_key": idempotency_key or _new_key(), "p_expected_version": expected_version,
        })
        return {
            "result": "ok", "document_id": data["receipt_id"], "status": data["status"], "version": data["version"],
            "received_qty": data["received_qty"], "next_actions": ["inspect"],
        }
    except WmsCommandError as exc:
        return _error_result(exc)


@mcp.tool
async def inspect(
    receipt_id: Annotated[str, Field(description="Receipt UUID")],
    result: Annotated[str, Field(description="검사 결과: PASSED 또는 FAILED")],
    reason_code: Annotated[Optional[str], Field(description="불합격/특이사항 사유 코드")] = None,
    idempotency_key: Annotated[Optional[str], Field(description="재시도 시 동일 키 재사용")] = None,
) -> dict:
    """입고 품질 검사 결과를 기록한다. PASSED -> putaway 대기, FAILED -> 처분(scrap) 대기.

    QUALITY_INSPECTOR 또는 WMS_ADMIN 역할이 필요하다 — PROCESS_AGENT로는 실행할 수
    없다(design.md: 품질 판정은 사람 판단 영역). 이 도구를 자동 에이전트가 호출하면
    FORBIDDEN이 반환되며, 실제 검사자는 WMS 프론트엔드에서 로그인해 처리해야 한다.
    """
    try:
        data = _call_rpc("wms_record_quality_result", {
            "p_receipt_id": receipt_id, "p_result": result, "p_reason_code": reason_code,
            "p_actor_id": _agent_user_id(), "p_idempotency_key": idempotency_key or _new_key(),
        })
        next_actions = ["putaway"] if result == "PASSED" else ["scrap"]
        return {
            "result": "ok", "document_id": data["receipt_id"], "status": data["status"], "version": data["version"],
            "next_actions": next_actions,
        }
    except WmsCommandError as exc:
        return _error_result(exc)


@mcp.tool
async def scrap(
    receipt_id: Annotated[str, Field(description="Receipt UUID (검사 결과 FAILED)")],
    reason_code: Annotated[str, Field(description="폐기 사유 코드 (필수)")],
    idempotency_key: Annotated[Optional[str], Field(description="재시도 시 동일 키 재사용")] = None,
) -> dict:
    """불합격 재고를 폐기 처분한다. QC 보류 수량을 SCRAP 상태로 원장에 반영한다."""
    try:
        data = _call_rpc("wms_apply_disposition", {
            "p_receipt_id": receipt_id, "p_reason_code": reason_code, "p_actor_id": _agent_user_id(),
            "p_idempotency_key": idempotency_key or _new_key(),
        })
        return {"result": "ok", "document_id": data["receipt_id"], "status": data["status"], "disposition": "SCRAP"}
    except WmsCommandError as exc:
        return _error_result(exc)


@mcp.tool
async def putaway(
    receipt_id: Annotated[str, Field(description="Receipt UUID (검사 결과 PASSED)")],
    idempotency_key: Annotated[Optional[str], Field(description="재시도 시 동일 키 재사용")] = None,
) -> dict:
    """합격 재고를 적치해 가용재고(AVAILABLE)로 전환한다. 이 슬라이스에서는 작업
    생성과 완료를 하나의 호출로 축약한다(전체 작업 lifecycle은 tasks.md 7.1 범위)."""
    try:
        data = _call_rpc("wms_create_putaway_tasks", {
            "p_receipt_id": receipt_id, "p_actor_id": _agent_user_id(),
            "p_idempotency_key": idempotency_key or _new_key(),
        })
        return {"result": "ok", "document_id": data["receipt_id"], "status": data["status"], "disposition": "AVAILABLE"}
    except WmsCommandError as exc:
        return _error_result(exc)


# ============================================================
# WCS equipment control
# (openspec/changes/add-wcs-equipment-control-contract, migration
#  supabase/migrations/20260727_wcs_equipment_control.sql)
#
# Two identities are in play here, and RLS keeps them apart on purpose
# (design.md D5):
#   - PROCESS_AGENT may dispatch/cancel commands and read status. That is the
#     WES/MFS routing direction — ProcessGPT telling equipment what to do.
#   - WCS_GATEWAY reports back what the equipment actually did. Those tools
#     sign in separately via _call_rpc_as_gateway.
# register_equipment (WMS_ADMIN/WAREHOUSE_MANAGER) and resolve_equipment_fault
# (WCS_OPERATOR/WAREHOUSE_MANAGER/WMS_ADMIN) are exposed but will return
# FORBIDDEN for the process agent — same deliberate belt-and-braces as the
# existing inspect/scrap tools.
# ============================================================


async def register_equipment(
    tenant_id: Annotated[str, Field(description="테넌트 UUID")],
    warehouse_id: Annotated[str, Field(description="창고 UUID")],
    equipment_code: Annotated[str, Field(description="창고 내 고유 설비 코드 (예: AGV-07)")],
    equipment_type: Annotated[str, Field(description="설비 유형: SRM, CONVEYOR, SORTER, AGV, AMR, ROBOT_CELL 중 하나")],
    zone_code: Annotated[Optional[str], Field(description="설비가 위치한 구역/로케이션 코드 (예: ZONE-B)")] = None,
    correlation_id: Annotated[Optional[str], Field(description="ProcessGPT process_instance_id 등 상관관계 ID")] = None,
    idempotency_key: Annotated[Optional[str], Field(description="재시도 시 동일 키 재사용. 미지정 시 새로 생성")] = None,
    dry_run: Annotated[bool, Field(description="true면 실제 반영 없이 예상 결과만 반환")] = False,
) -> dict:
    """자동화 설비를 창고 레지스트리에 등록한다. 등록 직후 상태는 OFFLINE이다.

    WMS_ADMIN 또는 WAREHOUSE_MANAGER 역할이 필요하다 — 설비 레지스트리 관리는
    창고 운영 책임자의 영역이므로 PROCESS_AGENT로 호출하면 FORBIDDEN이 반환된다.
    """
    if dry_run:
        return {"result": "dry_run", "would_call": "wms_register_equipment", "input": {
            "tenant_id": tenant_id, "warehouse_id": warehouse_id,
            "equipment_code": equipment_code, "equipment_type": equipment_type, "zone_code": zone_code,
        }}
    try:
        data = _call_rpc("wms_register_equipment", {
            "p_tenant_id": tenant_id, "p_warehouse_id": warehouse_id,
            "p_equipment_code": equipment_code, "p_equipment_type": equipment_type,
            "p_zone_code": zone_code, "p_actor_id": _agent_user_id(),
            "p_idempotency_key": idempotency_key or _new_key(), "p_correlation_id": correlation_id,
        })
        return {
            "result": "ok", "document_id": data["document_id"], "status": data["status"],
            "version": data["version"],
            "next_actions": ["report_equipment_status", "dispatch_equipment_command"],
        }
    except WmsCommandError as exc:
        return _error_result(exc)


async def dispatch_equipment_command(
    equipment_id: Annotated[str, Field(description="설비 UUID (register_equipment/get_equipment_status가 반환)")],
    command_type: Annotated[str, Field(description="명령 유형: MOVE, LOAD, UNLOAD, START, STOP, RESET, HOLD, RESUME 중 하나. SORTER/CONVEYOR 설비에는 DIVERT, SET_SPEED도 가능(wms_wcs-sortation-logic — payload 규격은 get_sortation_profile 참고). ROBOT_CELL 설비에는 PALLETIZE, WRAP도 가능(wms_wcs-sequential-dispatch — PALLETIZE는 dispatch_palletize_command를 쓰는 편이 낫고, WRAP payload 규격은 dispatch_palletize_command 설명 참고)")],
    expected_version: Annotated[int, Field(description="낙관적 동시성 — 설비(equipment)의 현재 version")],
    payload: Annotated[Optional[dict], Field(description='명령별 세부 파라미터 (예: {"to_zone": "ZONE-C"})')] = None,
    linked_entity_type: Annotated[Optional[str], Field(description="이 명령이 수행하는 WMS 작업 종류 (예: receipt)")] = None,
    linked_entity_id: Annotated[Optional[str], Field(description="연결된 WMS 엔티티 UUID (예: receipt_id)")] = None,
    correlation_id: Annotated[Optional[str], Field(description="ProcessGPT process_instance_id 등 상관관계 ID")] = None,
    idempotency_key: Annotated[Optional[str], Field(description="재시도 시 동일 키 재사용. 미지정 시 새로 생성")] = None,
    dry_run: Annotated[bool, Field(description="true면 실제 반영 없이 예상 결과만 반환")] = False,
) -> dict:
    """등록된 설비에 제어 명령을 디스패치한다 (명령: PENDING 상태로 생성).

    expected_version은 명령이 아니라 **설비**의 version이다. 설비가 FAULT 또는
    MAINTENANCE 상태면 INVALID로 거부된다. 명령 결과는 설비 측(WCS 게이트웨이)이
    report_command_result로 되돌려준다.

    DIVERT/SET_SPEED(분류 명령)는 대상 설비에 분류 프로파일이 등록되어 있어야 하고
    payload 구조·속도 범위가 검증된다 — 규격은 get_sortation_profile 참고.

    PALLETIZE/WRAP(적재·포장 명령)은 ROBOT_CELL 설비 전용이고 payload 구조가
    DB 트리거로 검증된다. PALLETIZE는 이 도구로 직접 보내기보다
    dispatch_palletize_command를 쓰는 것이 옳다 — 그 도구가 서열 배정을 모아
    payload를 만들고 배정 상태까지 함께 전이시킨다. WRAP은 전용 도구가 없으므로
    이 도구에 payload={"pallet_code": "...", "wrap_program": "STANDARD"|"HEAVY"}로
    보낸다(서열 배정 상태는 바뀌지 않는다).
    """
    if dry_run:
        return {"result": "dry_run", "would_call": "wms_dispatch_equipment_command", "input": {
            "equipment_id": equipment_id, "command_type": command_type, "payload": payload,
        }}
    try:
        data = _call_rpc("wms_dispatch_equipment_command", {
            "p_equipment_id": equipment_id, "p_command_type": command_type,
            "p_payload": payload or {}, "p_actor_id": _agent_user_id(),
            "p_idempotency_key": idempotency_key or _new_key(),
            "p_expected_version": expected_version, "p_correlation_id": correlation_id,
            "p_linked_entity_type": linked_entity_type, "p_linked_entity_id": linked_entity_id,
        })
        return {
            "result": "ok", "document_id": data["document_id"], "status": data["status"],
            "version": data["version"],
            "links": {
                "equipment_id": data["equipment_id"],
                "equipment_status": data["equipment_status"],
                "equipment_version": data["equipment_version"],
            },
            "next_actions": ["report_command_result", "cancel_equipment_command"],
        }
    except WmsCommandError as exc:
        return _error_result(exc)


async def report_command_result(
    command_id: Annotated[str, Field(description="명령 UUID (dispatch_equipment_command가 반환한 document_id)")],
    command_status: Annotated[str, Field(description="보고할 명령 상태: ACKNOWLEDGED, IN_PROGRESS, COMPLETED, FAILED 중 하나")],
    expected_version: Annotated[int, Field(description="낙관적 동시성 — 명령(command)의 현재 version")],
    detail: Annotated[Optional[dict], Field(description='자유 형식 상세 (예: {"reason": "OBSTACLE_DETECTED"})')] = None,
    correlation_id: Annotated[Optional[str], Field(description="상관관계 ID")] = None,
    idempotency_key: Annotated[Optional[str], Field(description="재시도 시 동일 키 재사용. 미지정 시 새로 생성")] = None,
) -> dict:
    """설비 측이 특정 명령의 처리 결과를 WMS에 보고한다 (설비 → WMS 피드백).

    WCS_GATEWAY 서비스 아이덴티티로 호출된다 — PROCESS_AGENT는 RLS에서 거부된다
    (명령을 내리는 쪽과 결과를 보고하는 쪽을 분리, design.md D5). COMPLETED 또는
    FAILED로 보고하면 설비 상태도 파생 갱신된다(다른 진행 중 명령이 없으면 IDLE).
    expected_version은 설비가 아니라 **명령**의 version이다.
    """
    try:
        data = _call_rpc_as_gateway("wms_report_command_result", {
            "p_command_id": command_id, "p_command_status": command_status,
            "p_actor_id": _gateway_user_id(), "p_idempotency_key": idempotency_key or _new_key(),
            "p_expected_version": expected_version, "p_detail": detail,
            "p_correlation_id": correlation_id,
        })
        return {
            "result": "ok", "document_id": data["document_id"], "status": data["status"],
            "version": data["version"],
            "links": {
                "equipment_id": data["equipment_id"],
                "equipment_status": data["equipment_status"],
                "equipment_version": data["equipment_version"],
            },
            "next_actions": data["next_actions"],
        }
    except WmsCommandError as exc:
        return _error_result(exc)


async def report_equipment_status(
    equipment_id: Annotated[str, Field(description="설비 UUID")],
    new_status: Annotated[str, Field(description="새 설비 상태: OFFLINE, IDLE, RUNNING, MAINTENANCE 중 하나")],
    expected_version: Annotated[int, Field(description="낙관적 동시성 — 설비(equipment)의 현재 version")],
    detail: Annotated[Optional[dict], Field(description="센서값 등 자유 형식 상세")] = None,
    correlation_id: Annotated[Optional[str], Field(description="상관관계 ID")] = None,
    idempotency_key: Annotated[Optional[str], Field(description="재시도 시 동일 키 재사용. 미지정 시 새로 생성")] = None,
) -> dict:
    """설비 측이 명령과 무관한 자신의 상태 변화(기동/대기/오프라인/점검)를 보고한다.

    WCS_GATEWAY 서비스 아이덴티티로 호출된다 — PROCESS_AGENT는 RLS에서 거부된다.
    FAULT로의 전환은 이 도구로 할 수 없다 — 진행 중 명령을 함께 정리해야 하므로
    raise_equipment_fault를 써야 한다(INVALID로 거부됨).
    """
    try:
        data = _call_rpc_as_gateway("wms_report_equipment_status", {
            "p_equipment_id": equipment_id, "p_new_status": new_status,
            "p_actor_id": _gateway_user_id(), "p_idempotency_key": idempotency_key or _new_key(),
            "p_expected_version": expected_version, "p_detail": detail,
            "p_correlation_id": correlation_id,
        })
        return {
            "result": "ok", "document_id": data["document_id"], "status": data["status"],
            "version": data["version"], "previous_status": data["previous_status"],
            "next_actions": ["dispatch_equipment_command", "get_equipment_status"],
        }
    except WmsCommandError as exc:
        return _error_result(exc)


async def raise_equipment_fault(
    equipment_id: Annotated[str, Field(description="설비 UUID")],
    fault_code: Annotated[str, Field(description="장애 코드 (예: MOTOR_OVERHEAT)")],
    severity: Annotated[str, Field(description="심각도: WARNING, CRITICAL, BLOCKING 중 하나")],
    correlation_id: Annotated[Optional[str], Field(description="상관관계 ID")] = None,
    idempotency_key: Annotated[Optional[str], Field(description="재시도 시 동일 키 재사용. 미지정 시 새로 생성")] = None,
) -> dict:
    """설비 장애를 기록한다. 설비는 FAULT로 전환되고, 그 설비의 미종결 명령
    (PENDING/ACKNOWLEDGED/IN_PROGRESS)은 모두 FAILED로 일괄 전환되어 새 장애
    레코드와 연결된다(design.md D4 — "안전하게 종결"까지만 보장, 재시도는 상위
    라우팅 스펙의 책임).

    WCS_GATEWAY 서비스 아이덴티티로 호출된다 — PROCESS_AGENT는 RLS에서 거부된다.
    """
    try:
        data = _call_rpc_as_gateway("wms_raise_equipment_fault", {
            "p_equipment_id": equipment_id, "p_fault_code": fault_code, "p_severity": severity,
            "p_actor_id": _gateway_user_id(), "p_idempotency_key": idempotency_key or _new_key(),
            "p_correlation_id": correlation_id,
        })
        return {
            "result": "ok", "document_id": data["document_id"], "status": data["status"],
            "version": data["version"],
            "failed_command_ids": data["failed_command_ids"],
            "links": {
                "equipment_id": data["equipment_id"],
                "equipment_status": data["equipment_status"],
                "equipment_version": data["equipment_version"],
            },
            "next_actions": ["resolve_equipment_fault"],
        }
    except WmsCommandError as exc:
        return _error_result(exc)


async def resolve_equipment_fault(
    fault_id: Annotated[str, Field(description="장애 UUID (raise_equipment_fault가 반환한 document_id)")],
    resolution_note: Annotated[str, Field(description="해소 사유 (필수, 빈 값이면 INVALID)")],
    expected_version: Annotated[int, Field(description="낙관적 동시성 — 장애(fault)의 현재 version")],
    correlation_id: Annotated[Optional[str], Field(description="상관관계 ID")] = None,
    idempotency_key: Annotated[Optional[str], Field(description="재시도 시 동일 키 재사용. 미지정 시 새로 생성")] = None,
) -> dict:
    """열린 장애를 해소 처리하고 설비를 재가동 가능(IDLE) 상태로 되돌린다.

    WCS_OPERATOR, WAREHOUSE_MANAGER 또는 WMS_ADMIN 역할이 필요하다 — 장애 해소는
    현장 확인을 거친 사람의 판단이므로 PROCESS_AGENT도, 설비 쪽 WCS_GATEWAY도
    호출할 수 없고 FORBIDDEN이 반환된다. 실제 운영자는 WMS 프론트엔드에서
    로그인해 처리해야 한다.
    """
    try:
        data = _call_rpc("wms_resolve_equipment_fault", {
            "p_fault_id": fault_id, "p_resolution_note": resolution_note,
            "p_actor_id": _agent_user_id(), "p_idempotency_key": idempotency_key or _new_key(),
            "p_expected_version": expected_version, "p_correlation_id": correlation_id,
        })
        return {
            "result": "ok", "document_id": data["document_id"], "status": data["status"],
            "version": data["version"], "warnings": data["warnings"],
            "links": {
                "equipment_id": data["equipment_id"],
                "equipment_status": data["equipment_status"],
                "equipment_version": data["equipment_version"],
            },
            "next_actions": ["dispatch_equipment_command", "get_equipment_status"],
        }
    except WmsCommandError as exc:
        return _error_result(exc)


async def cancel_equipment_command(
    command_id: Annotated[str, Field(description="명령 UUID")],
    expected_version: Annotated[int, Field(description="낙관적 동시성 — 명령(command)의 현재 version")],
    reason: Annotated[Optional[str], Field(description="취소 사유")] = None,
    correlation_id: Annotated[Optional[str], Field(description="상관관계 ID")] = None,
    idempotency_key: Annotated[Optional[str], Field(description="재시도 시 동일 키 재사용. 미지정 시 새로 생성")] = None,
) -> dict:
    """아직 종결되지 않은(PENDING/ACKNOWLEDGED/IN_PROGRESS) 명령을 취소한다.

    이미 COMPLETED/FAILED/CANCELLED로 종결된 명령을 취소하려 하면 INVALID가
    반환된다. 취소로 진행 중 명령이 없어지면 설비는 IDLE로 되돌아간다.
    """
    try:
        data = _call_rpc("wms_cancel_equipment_command", {
            "p_command_id": command_id, "p_actor_id": _agent_user_id(),
            "p_idempotency_key": idempotency_key or _new_key(),
            "p_expected_version": expected_version, "p_reason": reason,
            "p_correlation_id": correlation_id,
        })
        return {
            "result": "ok", "document_id": data["document_id"], "status": data["status"],
            "version": data["version"],
            "links": {
                "equipment_id": data["equipment_id"],
                "equipment_status": data["equipment_status"],
                "equipment_version": data["equipment_version"],
            },
            "next_actions": ["dispatch_equipment_command"],
        }
    except WmsCommandError as exc:
        return _error_result(exc)


async def get_equipment_status(
    tenant_id: Annotated[str, Field(description="테넌트 UUID")],
    warehouse_id: Annotated[str, Field(description="창고 UUID")],
    equipment_id: Annotated[Optional[str], Field(description="특정 설비만 조회할 경우 그 UUID. 미지정 시 창고 전체")] = None,
    event_limit: Annotated[int, Field(description="설비별로 함께 반환할 최근 이벤트 건수")] = 5,
) -> dict:
    """설비 현황을 조회한다 (읽기 전용).

    설비별로 equipment_type, zone_code, status, version, 진행 중 명령 존재 여부와
    목록, 열린 장애, 최근 상태 이벤트를 함께 반환한다. 창고 스코프가 없으면
    FORBIDDEN이 반환된다.
    """
    try:
        data = _call_rpc("wms_get_equipment_status", {
            "p_tenant_id": tenant_id, "p_warehouse_id": warehouse_id,
            "p_equipment_id": equipment_id, "p_event_limit": event_limit,
        })
        return {"result": "ok", "document": data}
    except WmsCommandError as exc:
        return _error_result(exc)


# ============================================================
# WES/MFS material flow control
# (openspec/changes/add-wes-material-flow-control, migration
#  supabase/migrations/20260728_wes_material_flow_control.sql)
#
# The middleware layer between "what the WMS wants done" (a receipt awaiting
# putaway) and "how equipment does it" (wms_wcs-equipment-control). Everything
# here is the WMS-orchestration direction, so all six tools run as the normal
# PROCESS_AGENT identity — there is no gateway-side RPC in this contract
# (design.md D4: no new service role).
#
# NOTE on roles (design.md D3): the write RPCs allow
# WAREHOUSE_MANAGER / WCS_OPERATOR / PROCESS_AGENT — exactly the set that the
# shipped wms_dispatch_equipment_command allows. WMS_ADMIN is deliberately not
# in that set, because it is not in the dispatch RPC's set either and a
# mismatch would produce "work order created but dispatch FORBIDDEN" partial
# failures. PROCESS_AGENT is in it, so every tool below is callable by the
# process agent.
# ============================================================


async def open_dispatch_wave(
    tenant_id: Annotated[str, Field(description="테넌트 UUID")],
    warehouse_id: Annotated[str, Field(description="창고 UUID")],
    correlation_id: Annotated[Optional[str], Field(description="ProcessGPT process_instance_id 등 상관관계 ID")] = None,
    idempotency_key: Annotated[Optional[str], Field(description="재시도 시 동일 키 재사용. 미지정 시 새로 생성")] = None,
    dry_run: Annotated[bool, Field(description="true면 실제 반영 없이 예상 결과만 반환")] = False,
) -> dict:
    """디스패치 웨이브를 개설한다 (status=OPEN).

    웨이브는 "설비 명령을 언제 내보낼지"를 배치로 묶는 최소 계약이다(design.md D6).
    한 창고에 OPEN 웨이브를 여러 개 동시에 열어 둘 수 있고, 어떤 업무 오더를 어느
    웨이브에 담을지는 create_work_order 호출자가 wave_id로 명시한다.
    """
    if dry_run:
        return {"result": "dry_run", "would_call": "wms_open_dispatch_wave", "input": {
            "tenant_id": tenant_id, "warehouse_id": warehouse_id,
        }}
    try:
        data = _call_rpc("wms_open_dispatch_wave", {
            "p_tenant_id": tenant_id, "p_warehouse_id": warehouse_id,
            "p_actor_id": _agent_user_id(),
            "p_idempotency_key": idempotency_key or _new_key(), "p_correlation_id": correlation_id,
        })
        return {
            "result": "ok", "document_id": data["document_id"], "status": data["status"],
            "version": data["version"], "warnings": data["warnings"],
            "next_actions": ["create_work_order", "release_dispatch_wave"],
        }
    except WmsCommandError as exc:
        return _error_result(exc)


async def create_work_order(
    tenant_id: Annotated[str, Field(description="테넌트 UUID")],
    warehouse_id: Annotated[str, Field(description="창고 UUID")],
    work_order_type: Annotated[str, Field(description="업무 오더 종류. 현재 PUTAWAY만 지원")],
    linked_entity_type: Annotated[str, Field(description="상위 WMS 엔티티 종류. 현재 receipt만 지원")],
    linked_entity_id: Annotated[str, Field(description="상위 WMS 엔티티 UUID (예: receipt_id)")],
    equipment_type: Annotated[str, Field(description="목표 설비 종류: SRM, CONVEYOR, SORTER, AGV, AMR, ROBOT_CELL 중 하나")],
    command_type: Annotated[str, Field(description="디스패치할 설비 명령 종류: MOVE, LOAD, UNLOAD, START, STOP, RESET, HOLD, RESUME 중 하나")],
    dispatch_mode: Annotated[str, Field(description="이행 전략: WAVELESS(등록 즉시 디스패치 시도) 또는 WAVE(웨이브 릴리즈까지 큐잉)")],
    zone_code: Annotated[Optional[str], Field(description="목표 구역 코드. 비우면 창고 내 모든 구역이 후보")] = None,
    command_payload: Annotated[Optional[dict], Field(description='설비 명령 payload로 그대로 전달 (예: {"to_zone": "ZONE-C"})')] = None,
    wave_id: Annotated[Optional[str], Field(description="dispatch_mode=WAVE일 때 필수 — OPEN 상태 웨이브의 UUID")] = None,
    correlation_id: Annotated[Optional[str], Field(description="상관관계 ID")] = None,
    idempotency_key: Annotated[Optional[str], Field(description="재시도 시 동일 키 재사용. 미지정 시 새로 생성")] = None,
    dry_run: Annotated[bool, Field(description="true면 실제 반영 없이 예상 결과만 반환")] = False,
) -> dict:
    """WMS 상위 작업 의도를 업무 오더로 등록한다.

    dispatch_mode='WAVELESS'면 같은 트랜잭션 안에서 가용 설비를 골라 즉시
    디스패치까지 시도한다 — 성공하면 status는 DISPATCHED이고 links에 설비/명령
    id가 담긴다. 조건에 맞는 유휴 설비가 없으면 오류가 아니라 status=QUEUED에
    warnings=["NO_EQUIPMENT_AVAILABLE"]가 반환된다(정상 경로).

    dispatch_mode='WAVE'면 지정한 OPEN 웨이브에 큐잉만 되고,
    release_dispatch_wave가 호출될 때 일괄 디스패치를 시도한다.
    """
    if dry_run:
        return {"result": "dry_run", "would_call": "wms_create_work_order", "input": {
            "tenant_id": tenant_id, "warehouse_id": warehouse_id, "work_order_type": work_order_type,
            "linked_entity_type": linked_entity_type, "linked_entity_id": linked_entity_id,
            "equipment_type": equipment_type, "zone_code": zone_code, "command_type": command_type,
            "dispatch_mode": dispatch_mode, "wave_id": wave_id,
        }}
    try:
        data = _call_rpc("wms_create_work_order", {
            "p_tenant_id": tenant_id, "p_warehouse_id": warehouse_id,
            "p_work_order_type": work_order_type, "p_linked_entity_type": linked_entity_type,
            "p_linked_entity_id": linked_entity_id, "p_equipment_type": equipment_type,
            "p_zone_code": zone_code, "p_command_type": command_type,
            "p_command_payload": command_payload or {}, "p_dispatch_mode": dispatch_mode,
            "p_actor_id": _agent_user_id(), "p_idempotency_key": idempotency_key or _new_key(),
            "p_wave_id": wave_id, "p_correlation_id": correlation_id,
        })
        if data["status"] == "DISPATCHED":
            next_actions = ["get_work_order_status", "cancel_work_order"]
        elif data["dispatch_mode"] == "WAVE":
            next_actions = ["release_dispatch_wave"]
        else:
            next_actions = ["retry_work_order_dispatch"]
        return {
            "result": "ok", "document_id": data["document_id"], "status": data["status"],
            "version": data["version"], "links": data["links"], "warnings": data["warnings"],
            "next_actions": next_actions,
        }
    except WmsCommandError as exc:
        return _error_result(exc)


async def release_dispatch_wave(
    wave_id: Annotated[str, Field(description="웨이브 UUID (open_dispatch_wave가 반환한 document_id)")],
    expected_version: Annotated[int, Field(description="낙관적 동시성 — 웨이브(wave)의 현재 version")],
    correlation_id: Annotated[Optional[str], Field(description="상관관계 ID")] = None,
    idempotency_key: Annotated[Optional[str], Field(description="재시도 시 동일 키 재사용. 미지정 시 새로 생성")] = None,
    dry_run: Annotated[bool, Field(description="true면 실제 반영 없이 예상 결과만 반환")] = False,
) -> dict:
    """OPEN 웨이브를 릴리즈하고, 그 웨이브에 큐잉된 업무 오더를 순차 디스패치한다.

    가용 설비 수가 부족하면 일부만 DISPATCHED가 되고 나머지는 QUEUED로 남으며,
    warnings에 부족 건수가 담긴다(오류가 아니다 — 남은 건은
    retry_work_order_dispatch로 다시 시도한다). 이미 RELEASED인 웨이브를 다시
    릴리즈하면 INVALID가 반환된다. expected_version은 웨이브의 version이다.
    """
    if dry_run:
        return {"result": "dry_run", "would_call": "wms_release_dispatch_wave", "input": {"wave_id": wave_id}}
    try:
        data = _call_rpc("wms_release_dispatch_wave", {
            "p_wave_id": wave_id, "p_actor_id": _agent_user_id(),
            "p_idempotency_key": idempotency_key or _new_key(),
            "p_expected_version": expected_version, "p_correlation_id": correlation_id,
        })
        return {
            "result": "ok", "document_id": data["document_id"], "status": data["status"],
            "version": data["version"],
            "dispatched_count": data["dispatched_count"], "queued_count": data["queued_count"],
            "work_orders": data["work_orders"], "warnings": data["warnings"],
            "next_actions": (["retry_work_order_dispatch", "get_work_order_status"]
                             if data["queued_count"] else ["get_work_order_status"]),
        }
    except WmsCommandError as exc:
        return _error_result(exc)


async def retry_work_order_dispatch(
    work_order_id: Annotated[str, Field(description="업무 오더 UUID")],
    expected_version: Annotated[int, Field(description="낙관적 동시성 — 업무 오더(work order)의 현재 version")],
    correlation_id: Annotated[Optional[str], Field(description="상관관계 ID")] = None,
    idempotency_key: Annotated[Optional[str], Field(description="재시도 시 동일 키 재사용. 미지정 시 새로 생성")] = None,
    dry_run: Annotated[bool, Field(description="true면 실제 반영 없이 예상 결과만 반환")] = False,
) -> dict:
    """가용 설비 부족으로 QUEUED에 머문 업무 오더의 디스패치를 다시 시도한다.

    이미 DISPATCHED/COMPLETED/FAILED/CANCELLED로 전이된 업무 오더는 INVALID로
    거부된다. OPEN 웨이브에 속한 업무 오더도 거부된다 — 그건 웨이브를 릴리즈해야
    한다. 이번에도 설비가 없으면 오류가 아니라 QUEUED 유지 + 경고가 반환된다.
    """
    if dry_run:
        return {"result": "dry_run", "would_call": "wms_retry_work_order_dispatch",
                "input": {"work_order_id": work_order_id}}
    try:
        data = _call_rpc("wms_retry_work_order_dispatch", {
            "p_work_order_id": work_order_id, "p_actor_id": _agent_user_id(),
            "p_idempotency_key": idempotency_key or _new_key(),
            "p_expected_version": expected_version, "p_correlation_id": correlation_id,
        })
        return {
            "result": "ok", "document_id": data["document_id"], "status": data["status"],
            "version": data["version"], "links": data["links"], "warnings": data["warnings"],
            "next_actions": (["get_work_order_status", "cancel_work_order"]
                             if data["status"] == "DISPATCHED" else ["retry_work_order_dispatch"]),
        }
    except WmsCommandError as exc:
        return _error_result(exc)


async def cancel_work_order(
    work_order_id: Annotated[str, Field(description="업무 오더 UUID")],
    expected_version: Annotated[int, Field(description="낙관적 동시성 — 업무 오더(work order)의 현재 version")],
    reason: Annotated[Optional[str], Field(description="취소 사유")] = None,
    correlation_id: Annotated[Optional[str], Field(description="상관관계 ID")] = None,
    idempotency_key: Annotated[Optional[str], Field(description="재시도 시 동일 키 재사용. 미지정 시 새로 생성")] = None,
) -> dict:
    """아직 종결되지 않은(QUEUED/DISPATCHED) 업무 오더를 취소한다.

    DISPATCHED 상태였다면 연결된 설비 명령도 함께 CANCELLED로 취소된다.
    이미 COMPLETED/FAILED/CANCELLED로 종결된 업무 오더는 INVALID로 거부된다.
    """
    try:
        data = _call_rpc("wms_cancel_work_order", {
            "p_work_order_id": work_order_id, "p_actor_id": _agent_user_id(),
            "p_idempotency_key": idempotency_key or _new_key(),
            "p_expected_version": expected_version, "p_reason": reason,
            "p_correlation_id": correlation_id,
        })
        return {
            "result": "ok", "document_id": data["document_id"], "status": data["status"],
            "version": data["version"], "warnings": data["warnings"],
            "links": {"cancelled_equipment_command_id": data["cancelled_equipment_command_id"]},
            "next_actions": ["get_work_order_status"],
        }
    except WmsCommandError as exc:
        return _error_result(exc)


async def get_work_order_status(
    tenant_id: Annotated[str, Field(description="테넌트 UUID")],
    warehouse_id: Annotated[str, Field(description="창고 UUID")],
    work_order_id: Annotated[Optional[str], Field(description="특정 업무 오더만 조회할 경우 그 UUID. 미지정 시 창고 전체")] = None,
) -> dict:
    """업무 오더 현황과 디스패치 웨이브 현황을 조회한다 (읽기 전용).

    업무 오더별로 status, dispatch_mode, 소속 웨이브와 그 상태, 연결된 설비 명령
    존재 여부와 그 명령/설비의 현재 상태를 함께 반환한다. 창고 스코프가 없으면
    FORBIDDEN이 반환된다.
    """
    try:
        data = _call_rpc("wms_get_work_order_status", {
            "p_tenant_id": tenant_id, "p_warehouse_id": warehouse_id,
            "p_work_order_id": work_order_id,
        })
        return {"result": "ok", "document": data}
    except WmsCommandError as exc:
        return _error_result(exc)


# ============================================================
# WCS high-speed sortation logic
# (openspec/changes/add-wcs-sortation-logic, migration
#  supabase/migrations/20260729_wcs_sortation_logic.sql)
#
# Only three tools: the per-equipment sortation profile (carton gap, speed
# range, sensor window) is master data this contract owns. The two sorter
# commands it defines — DIVERT and SET_SPEED — deliberately get NO new tool:
# they ride on the existing dispatch_equipment_command tool above with
# command_type='DIVERT' / 'SET_SPEED' and the payload shapes documented in
# get_sortation_profile's docstring. Results come back through the existing
# report_command_result tool with detail={"outcome": SUCCESS|MISROUTE|JAM}.
#
# NOTE on roles: the profile RPCs allow WMS_ADMIN / WAREHOUSE_MANAGER /
# WCS_OPERATOR. PROCESS_AGENT is NOT in that set, so the two write tools below
# return FORBIDDEN for the process agent — deliberate, same belt-and-braces as
# register_equipment. Only get_sortation_profile belongs in the agent's
# allowlist (docs/03-processgpt-integration.md).
# ============================================================


async def create_sortation_profile(
    equipment_id: Annotated[str, Field(description="설비 UUID (equipment_type이 SORTER 또는 CONVEYOR여야 함)")],
    min_carton_gap_mm: Annotated[int, Field(description="카톤 간 최소 간격(mm), 0보다 커야 함")],
    min_speed_value: Annotated[float, Field(description="허용 최저 속도, 0보다 커야 함")],
    max_speed_value: Annotated[float, Field(description="허용 최고 속도, min_speed_value 이상")],
    sensor_detection_window_ms: Annotated[int, Field(description="스캔/감지 윈도우(ms), 0보다 커야 함")],
    speed_mode: Annotated[str, Field(description="프로파일 기본 속도 모드: FIXED 또는 AUTO")] = "FIXED",
    speed_unit: Annotated[str, Field(description="속도 단위 (예: MPS). 이 설비의 모든 SET_SPEED payload와 일치해야 함")] = "MPS",
    correlation_id: Annotated[Optional[str], Field(description="ProcessGPT process_instance_id 등 상관관계 ID")] = None,
    idempotency_key: Annotated[Optional[str], Field(description="재시도 시 동일 키 재사용. 미지정 시 새로 생성")] = None,
    dry_run: Annotated[bool, Field(description="true면 실제 반영 없이 예상 결과만 반환")] = False,
) -> dict:
    """분류 설비(SORTER/CONVEYOR)의 튜닝 프로파일을 등록한다 (설비당 1개).

    프로파일이 없는 설비에는 DIVERT/SET_SPEED 명령을 디스패치할 수 없다 —
    간격·속도 기준이 없으면 검증이 불가능하기 때문이다("설비 등록 → 프로파일 등록
    → 분류 명령 디스패치" 순서 강제). SORTER/CONVEYOR가 아닌 설비, 이미 프로파일이
    있는 설비는 INVALID로 거부된다.

    WMS_ADMIN / WAREHOUSE_MANAGER / WCS_OPERATOR 역할이 필요하다 — 설비 튜닝은
    운영 책임자의 영역이므로 PROCESS_AGENT로 호출하면 FORBIDDEN이 반환된다.
    """
    if dry_run:
        return {"result": "dry_run", "would_call": "wms_create_sortation_profile", "input": {
            "equipment_id": equipment_id, "min_carton_gap_mm": min_carton_gap_mm,
            "speed_mode": speed_mode, "min_speed_value": min_speed_value,
            "max_speed_value": max_speed_value, "speed_unit": speed_unit,
            "sensor_detection_window_ms": sensor_detection_window_ms,
        }}
    try:
        data = _call_rpc("wms_create_sortation_profile", {
            "p_equipment_id": equipment_id, "p_min_carton_gap_mm": min_carton_gap_mm,
            "p_min_speed_value": min_speed_value, "p_max_speed_value": max_speed_value,
            "p_sensor_detection_window_ms": sensor_detection_window_ms,
            "p_actor_id": _agent_user_id(), "p_idempotency_key": idempotency_key or _new_key(),
            "p_speed_mode": speed_mode, "p_speed_unit": speed_unit,
            "p_correlation_id": correlation_id,
        })
        return {
            "result": "ok", "document_id": data["document_id"], "status": data["status"],
            "version": data["version"], "warnings": data["warnings"],
            "links": {
                "equipment_id": data["equipment_id"],
                "equipment_code": data["equipment_code"],
            },
            "next_actions": ["dispatch_equipment_command", "get_sortation_profile",
                             "update_sortation_profile"],
        }
    except WmsCommandError as exc:
        return _error_result(exc)


async def update_sortation_profile(
    profile_id: Annotated[str, Field(description="프로파일 UUID (create/get_sortation_profile이 반환)")],
    expected_version: Annotated[int, Field(description="낙관적 동시성 — 프로파일(profile)의 현재 version")],
    min_carton_gap_mm: Annotated[Optional[int], Field(description="변경할 최소 화물 간격(mm). null이면 유지")] = None,
    speed_mode: Annotated[Optional[str], Field(description="변경할 기본 속도 모드: FIXED 또는 AUTO. null이면 유지")] = None,
    min_speed_value: Annotated[Optional[float], Field(description="변경할 허용 최저 속도. null이면 유지")] = None,
    max_speed_value: Annotated[Optional[float], Field(description="변경할 허용 최고 속도. null이면 유지")] = None,
    speed_unit: Annotated[Optional[str], Field(description="변경할 속도 단위. null이면 유지")] = None,
    sensor_detection_window_ms: Annotated[Optional[int], Field(description="변경할 센서 감지 윈도우(ms). null이면 유지")] = None,
    status: Annotated[Optional[str], Field(description="ACTIVE 또는 INACTIVE. INACTIVE면 그 설비의 DIVERT/SET_SPEED가 거부된다")] = None,
    correlation_id: Annotated[Optional[str], Field(description="상관관계 ID")] = None,
    idempotency_key: Annotated[Optional[str], Field(description="재시도 시 동일 키 재사용. 미지정 시 새로 생성")] = None,
    dry_run: Annotated[bool, Field(description="true면 실제 반영 없이 예상 결과만 반환")] = False,
) -> dict:
    """분류 프로파일 값을 갱신한다. 지정하지 않은(null) 항목은 그대로 유지된다.

    expected_version은 설비가 아니라 **프로파일**의 version이다. 어긋나면 CONFLICT가
    반환된다. 속도 범위를 좁혀도 이미 디스패치된 명령은 재검증되지 않으며, 그 경우
    warnings에 IN_FLIGHT_COMMANDS_NOT_REVALIDATED가 담긴다.

    WMS_ADMIN / WAREHOUSE_MANAGER / WCS_OPERATOR 역할이 필요하다.
    """
    if dry_run:
        return {"result": "dry_run", "would_call": "wms_update_sortation_profile",
                "input": {"profile_id": profile_id, "status": status,
                          "min_speed_value": min_speed_value, "max_speed_value": max_speed_value}}
    try:
        data = _call_rpc("wms_update_sortation_profile", {
            "p_profile_id": profile_id, "p_actor_id": _agent_user_id(),
            "p_idempotency_key": idempotency_key or _new_key(),
            "p_expected_version": expected_version,
            "p_min_carton_gap_mm": min_carton_gap_mm, "p_speed_mode": speed_mode,
            "p_min_speed_value": min_speed_value, "p_max_speed_value": max_speed_value,
            "p_speed_unit": speed_unit,
            "p_sensor_detection_window_ms": sensor_detection_window_ms,
            "p_status": status, "p_correlation_id": correlation_id,
        })
        return {
            "result": "ok", "document_id": data["document_id"], "status": data["status"],
            "version": data["version"], "warnings": data["warnings"],
            "links": {
                "equipment_id": data["equipment_id"],
                "equipment_code": data["equipment_code"],
            },
            "next_actions": ["get_sortation_profile", "dispatch_equipment_command"],
        }
    except WmsCommandError as exc:
        return _error_result(exc)


async def get_sortation_profile(
    tenant_id: Annotated[str, Field(description="테넌트 UUID")],
    warehouse_id: Annotated[str, Field(description="창고 UUID")],
    equipment_id: Annotated[Optional[str], Field(description="특정 설비만 조회할 경우 그 UUID. 미지정 시 창고의 SORTER/CONVEYOR 전체")] = None,
) -> dict:
    """분류 설비별 프로파일 현황을 조회한다 (읽기 전용).

    창고의 SORTER/CONVEYOR를 모두 돌려주며, 프로파일이 아직 없는 설비는
    has_profile=false, profile=null로 표시된다. 진행 중인 DIVERT/SET_SPEED 명령,
    마지막으로 보고된 분류 결과(last_outcome), 열린 장애도 함께 반환된다.

    이 값이 분류 명령의 payload 계약을 결정한다 — 명령은 별도 도구가 아니라
    dispatch_equipment_command로 보낸다:

      command_type='DIVERT'
        payload = {"target_chute": "CHUTE-12",       # 필수
                   "item_identifier": "BC-0001",     # 필수 (참조 무결성 없는 자유 텍스트)
                   "expected_gap_mm": 160}           # 선택, 생략 시 profile.min_carton_gap_mm

      command_type='SET_SPEED'
        payload = {"speed_mode": "FIXED",            # 필수, FIXED 또는 AUTO
                   "speed_value": 1.8,               # FIXED일 때 필수, 프로파일 범위 안이어야 함
                   "speed_unit": "MPS"}              # 필수, 프로파일의 speed_unit과 일치해야 함

    결과 보고는 report_command_result로 하며 detail은
    {"outcome": "SUCCESS"|"MISROUTE"|"JAM", "actual_chute": "..."} 형태다.
    SUCCESS는 COMPLETED와만, MISROUTE/JAM은 FAILED와만 짝지을 수 있고, JAM이
    보고되면 그 설비에 SORTATION_JAM 장애가 자동으로 발생한다.
    """
    try:
        data = _call_rpc("wms_get_sortation_profile", {
            "p_tenant_id": tenant_id, "p_warehouse_id": warehouse_id,
            "p_equipment_id": equipment_id,
        })
        return {"result": "ok", "document": data}
    except WmsCommandError as exc:
        return _error_result(exc)


# ============================================================
# WCS intelligent routing / bottleneck relief
# (openspec/changes/add-wcs-bottleneck-routing, migration
#  supabase/migrations/20260730_wcs_bottleneck_routing.sql)
#
# Five tools: two for the threshold policy, two for the manual force-exclusion,
# one read model. The selection hook itself
# (wms.wcs_select_available_equipment) is deliberately NOT a tool — it is
# called from inside wms_wes-material-flow-control's dispatch RPCs, so
# create_work_order / release_dispatch_wave / retry_work_order_dispatch already
# route around bottlenecks without the agent doing anything.
#
# NOTE on roles: every write RPC here excludes PROCESS_AGENT on purpose
# (design.md 역할 모델 — tuning thresholds and taking a machine out of service
# are human operating judgements), so the four write tools below return
# FORBIDDEN for the process agent. Only get_equipment_routing_status belongs in
# the agent's allowlist (docs/03-processgpt-integration.md).
# ============================================================


async def register_wcs_routing_policy(
    tenant_id: Annotated[str, Field(description="테넌트 UUID")],
    warehouse_id: Annotated[str, Field(description="창고 UUID")],
    equipment_type: Annotated[str, Field(description="설비 유형: SRM | CONVEYOR | SORTER | AGV | AMR | ROBOT_CELL")],
    queue_depth_threshold: Annotated[int, Field(description="이 개수 이상 미종결 명령이 쌓이면 병목으로 판정. 0보다 커야 함")],
    fault_count_threshold: Annotated[int, Field(description="최근 30분 내 이 건수 이상 장애가 발생하면 병목으로 판정. 0보다 커야 함")],
    correlation_id: Annotated[Optional[str], Field(description="ProcessGPT process_instance_id 등 상관관계 ID")] = None,
    idempotency_key: Annotated[Optional[str], Field(description="재시도 시 동일 키 재사용. 미지정 시 새로 생성")] = None,
    dry_run: Annotated[bool, Field(description="true면 실제 반영 없이 예상 결과만 반환")] = False,
) -> dict:
    """창고·설비 유형 단위 병목 감지 임계값 정책을 등록한다 (유형당 1개).

    정책 등록은 선택 사항이다 — 정책이 없는 설비 유형에는 시스템 기본값
    (queue_depth=3, fault_count=1)이 적용되며 병목 판정 자체는 항상 동작한다.
    같은 창고·유형에 이미 정책이 있으면 INVALID로 거부된다.

    관찰 윈도우는 30분 고정이며 정책으로 조정할 수 없다(design.md D6).

    WMS_ADMIN / WAREHOUSE_MANAGER 역할이 필요하다 — 임계값 튜닝은 운영 관리자의
    영역이므로 PROCESS_AGENT나 WCS_OPERATOR로 호출하면 FORBIDDEN이 반환된다.
    """
    if dry_run:
        return {"result": "dry_run", "would_call": "wms_register_wcs_routing_policy", "input": {
            "warehouse_id": warehouse_id, "equipment_type": equipment_type,
            "queue_depth_threshold": queue_depth_threshold,
            "fault_count_threshold": fault_count_threshold,
        }}
    try:
        data = _call_rpc("wms_register_wcs_routing_policy", {
            "p_tenant_id": tenant_id, "p_warehouse_id": warehouse_id,
            "p_equipment_type": equipment_type,
            "p_queue_depth_threshold": queue_depth_threshold,
            "p_fault_count_threshold": fault_count_threshold,
            "p_actor_id": _agent_user_id(), "p_idempotency_key": idempotency_key or _new_key(),
            "p_correlation_id": correlation_id,
        })
        return {
            "result": "ok", "document_id": data["document_id"], "status": data["status"],
            "version": data["version"], "warnings": data["warnings"],
            "links": {
                "policy_id": data["policy_id"],
                "equipment_type": data["equipment_type"],
            },
            "next_actions": ["get_equipment_routing_status", "update_wcs_routing_policy"],
        }
    except WmsCommandError as exc:
        return _error_result(exc)


async def update_wcs_routing_policy(
    policy_id: Annotated[str, Field(description="정책 UUID (register/get_equipment_routing_status가 반환)")],
    expected_version: Annotated[int, Field(description="낙관적 동시성 — 정책(policy)의 현재 version")],
    queue_depth_threshold: Annotated[Optional[int], Field(description="변경할 큐 길이 임계값. null이면 유지")] = None,
    fault_count_threshold: Annotated[Optional[int], Field(description="변경할 최근 장애 건수 임계값. null이면 유지")] = None,
    correlation_id: Annotated[Optional[str], Field(description="상관관계 ID")] = None,
    idempotency_key: Annotated[Optional[str], Field(description="재시도 시 동일 키 재사용. 미지정 시 새로 생성")] = None,
    dry_run: Annotated[bool, Field(description="true면 실제 반영 없이 예상 결과만 반환")] = False,
) -> dict:
    """병목 감지 임계값을 갱신한다. 지정하지 않은(null) 항목은 그대로 유지된다.

    expected_version은 설비가 아니라 **정책**의 version이다. 어긋나면 CONFLICT가
    반환된다. 두 임계값을 모두 null로 두면 INVALID로 거부된다.

    병목 판정은 저장된 상태가 아니라 조회 시점 계산값이므로(design.md D2),
    새 임계값은 다음 조회·다음 디스패치부터 즉시 적용된다 — 재계산 배치가 없다.

    WMS_ADMIN / WAREHOUSE_MANAGER 역할이 필요하다.
    """
    if dry_run:
        return {"result": "dry_run", "would_call": "wms_update_wcs_routing_policy", "input": {
            "policy_id": policy_id, "queue_depth_threshold": queue_depth_threshold,
            "fault_count_threshold": fault_count_threshold,
        }}
    try:
        data = _call_rpc("wms_update_wcs_routing_policy", {
            "p_policy_id": policy_id, "p_actor_id": _agent_user_id(),
            "p_idempotency_key": idempotency_key or _new_key(),
            "p_expected_version": expected_version,
            "p_queue_depth_threshold": queue_depth_threshold,
            "p_fault_count_threshold": fault_count_threshold,
            "p_correlation_id": correlation_id,
        })
        return {
            "result": "ok", "document_id": data["document_id"], "status": data["status"],
            "version": data["version"], "warnings": data["warnings"],
            "links": {
                "policy_id": data["policy_id"],
                "equipment_type": data["equipment_type"],
            },
            "next_actions": ["get_equipment_routing_status"],
        }
    except WmsCommandError as exc:
        return _error_result(exc)


async def exclude_equipment_from_routing(
    equipment_id: Annotated[str, Field(description="자동 라우팅에서 제외할 설비 UUID")],
    reason: Annotated[str, Field(description="제외 사유 (필수, 예: '계획 정비'). 빈 문자열은 거부된다")],
    correlation_id: Annotated[Optional[str], Field(description="상관관계 ID")] = None,
    idempotency_key: Annotated[Optional[str], Field(description="재시도 시 동일 키 재사용. 미지정 시 새로 생성")] = None,
    dry_run: Annotated[bool, Field(description="true면 실제 반영 없이 예상 결과만 반환")] = False,
) -> dict:
    """특정 설비를 자동 라우팅 대상에서 강제로 제외한다 (계획 정비 등).

    강제 제외는 병목 플래그와 다르게 취급된다 — 병목 플래그는 "다른 후보가
    있으면 그쪽을 쓴다"는 선호도일 뿐이지만, 강제 제외는 **절대 배정 금지**다.
    조건에 맞는 설비가 그 한 대뿐이어도 선택되지 않고, 업무 오더는 QUEUED로
    남으면서 NO_EQUIPMENT_AVAILABLE 경고가 반환된다.

    이미 진행 중인 명령은 취소되지 않는다 — 그런 명령이 있으면 warnings에
    IN_FLIGHT_COMMANDS_NOT_CANCELLED가 담긴다. 즉시 멈춰야 한다면
    cancel_equipment_command를 따로 호출해야 한다.

    같은 설비에 이미 활성 제외가 있으면 INVALID로 거부된다.

    WMS_ADMIN / WAREHOUSE_MANAGER / WCS_OPERATOR 역할이 필요하다 — 설비를
    라인에서 빼는 것은 사람의 운영 판단이므로 PROCESS_AGENT로 호출하면
    FORBIDDEN이 반환된다.
    """
    if dry_run:
        return {"result": "dry_run", "would_call": "wms_exclude_equipment_from_routing",
                "input": {"equipment_id": equipment_id, "reason": reason}}
    try:
        data = _call_rpc("wms_exclude_equipment_from_routing", {
            "p_equipment_id": equipment_id, "p_reason": reason,
            "p_actor_id": _agent_user_id(), "p_idempotency_key": idempotency_key or _new_key(),
            "p_correlation_id": correlation_id,
        })
        return {
            "result": "ok", "document_id": data["document_id"], "status": data["status"],
            "version": data["version"], "warnings": data["warnings"],
            "links": {
                "override_id": data["override_id"],
                "equipment_id": data["equipment_id"],
                "equipment_code": data["equipment_code"],
            },
            "next_actions": ["clear_equipment_routing_exclusion", "get_equipment_routing_status"],
        }
    except WmsCommandError as exc:
        return _error_result(exc)


async def clear_equipment_routing_exclusion(
    override_id: Annotated[str, Field(description="제외 레코드 UUID (exclude/get_equipment_routing_status가 반환)")],
    expected_version: Annotated[int, Field(description="낙관적 동시성 — 제외 레코드(override)의 현재 version")],
    correlation_id: Annotated[Optional[str], Field(description="상관관계 ID")] = None,
    idempotency_key: Annotated[Optional[str], Field(description="재시도 시 동일 키 재사용. 미지정 시 새로 생성")] = None,
    dry_run: Annotated[bool, Field(description="true면 실제 반영 없이 예상 결과만 반환")] = False,
) -> dict:
    """강제 제외를 해제해 설비를 자동 라우팅 대상으로 되돌린다.

    제외 레코드는 삭제되지 않고 status가 CLEARED로 바뀌며 cleared_by/cleared_at이
    기록된다 — 언제 누가 왜 뺐다가 되돌렸는지가 남는다. 이미 CLEARED인 레코드를
    다시 해제하면 INVALID, expected_version이 어긋나면 CONFLICT다.

    해제 즉시 다음 디스패치부터 후보로 복귀한다(재계산 배치 없음).

    WMS_ADMIN / WAREHOUSE_MANAGER / WCS_OPERATOR 역할이 필요하다.
    """
    if dry_run:
        return {"result": "dry_run", "would_call": "wms_clear_equipment_routing_exclusion",
                "input": {"override_id": override_id, "expected_version": expected_version}}
    try:
        data = _call_rpc("wms_clear_equipment_routing_exclusion", {
            "p_override_id": override_id, "p_actor_id": _agent_user_id(),
            "p_idempotency_key": idempotency_key or _new_key(),
            "p_expected_version": expected_version,
            "p_correlation_id": correlation_id,
        })
        return {
            "result": "ok", "document_id": data["document_id"], "status": data["status"],
            "version": data["version"], "warnings": data["warnings"],
            "links": {
                "override_id": data["override_id"],
                "equipment_id": data["equipment_id"],
                "equipment_code": data["equipment_code"],
            },
            "next_actions": ["get_equipment_routing_status", "exclude_equipment_from_routing"],
        }
    except WmsCommandError as exc:
        return _error_result(exc)


async def get_equipment_routing_status(
    tenant_id: Annotated[str, Field(description="테넌트 UUID")],
    warehouse_id: Annotated[str, Field(description="창고 UUID")],
    equipment_id: Annotated[Optional[str], Field(description="특정 설비만 조회할 경우 그 UUID. 미지정 시 창고의 전체 설비")] = None,
) -> dict:
    """설비별 실시간 부하·병목·라우팅 제외 현황을 조회한다 (읽기 전용).

    저장된 값이 아니라 조회 시점에 계산된 값이다 — 이력을 남기지 않으므로
    "언제부터 병목이었는가"에는 답하지 않는다(design.md D2).

    설비마다 다음을 반환한다:

      queue_depth               미종결(PENDING/ACKNOWLEDGED/IN_PROGRESS) 명령 수
      recent_fault_count        최근 30분 내 발생한 장애 수 (해소 여부 무관)
      recent_completed_count    최근 30분 내 완료된 명령 수 (참고용, 판정에는 미사용)
      resolved_*_threshold      실제로 적용된 임계값
      threshold_source          POLICY(등록된 정책) 또는 SYSTEM_DEFAULT
      is_bottleneck             두 임계값 중 하나라도 넘었는가
      bottleneck_reasons        QUEUE_DEPTH_EXCEEDED / FAULT_FREQUENCY_EXCEEDED
      is_excluded / active_override   운영자의 강제 제외 여부와 그 사유
      routable                  지금 이 설비가 신규 작업 후보가 될 수 있는가

    두 신호의 뜻이 다르다: queue_depth는 "지금 몰리고 있다", recent_fault_count는
    "요즘 불안정하다"이다. 다만 큐가 쌓인 설비는 이미 RUNNING이라 신규 작업
    후보에서 빠지므로, 실제로 후보 선택을 바꾸는 것은 장애 빈도 쪽이다 —
    QUEUE_DEPTH_EXCEEDED는 "왜 저기서 일이 밀리는가"를 보여주는 모니터링
    신호다(마이그레이션 헤더 DEVIATION 2).

    응답의 policies 배열에는 이 창고에 등록된 임계값 정책이 함께 담긴다.
    창고 스코프가 없으면 FORBIDDEN이 반환된다.
    """
    try:
        data = _call_rpc("wms_get_equipment_routing_status", {
            "p_tenant_id": tenant_id, "p_warehouse_id": warehouse_id,
            "p_equipment_id": equipment_id,
        })
        return {"result": "ok", "document": data}
    except WmsCommandError as exc:
        return _error_result(exc)


# ============================================================
# WCS sequential dispatch / intelligent palletising
# (openspec/changes/add-wcs-sequential-dispatch, migration
#  supabase/migrations/20260731_wcs_sequential_dispatch.sql)
#
# Six tools: one to register the minimal outbound unit, two for the sequence
# assignment and its cancellation, one batch palletising dispatch, two read
# models.
#
# There is deliberately NO tool for WRAP dispatch and none for reporting a
# PALLETIZE/WRAP result — those ride the existing
# dispatch_equipment_command / report_command_result tools with a
# command_type + payload, exactly the way DIVERT/SET_SPEED do (area 3's
# precedent). The payload shapes are documented on dispatch_palletize_command
# and get_pallet_manifest below.
#
# NOTE on roles: create/assign/cancel accept WMS_ADMIN, but
# dispatch_palletize_command does NOT — it calls
# wms_dispatch_equipment_command internally, whose shipped role set excludes
# WMS_ADMIN (migration DEVIATION 2). All four write tools are callable by
# PROCESS_AGENT, so all four belong in the agent allowlist
# (docs/03-processgpt-integration.md).
# ============================================================


async def create_outbound_order(
    tenant_id: Annotated[str, Field(description="테넌트 UUID")],
    warehouse_id: Annotated[str, Field(description="창고 UUID")],
    store_code: Annotated[str, Field(description="매장/배송처 식별자 (예: STORE-042). 빈 문자열은 거부된다")],
    product_id: Annotated[str, Field(description="상품 UUID (해당 테넌트의 상품이어야 함)")],
    qty: Annotated[float, Field(description="출고 수량. 0 이하는 거부된다")],
    order_number: Annotated[Optional[str], Field(description="외부/수동 참조 번호. 중복 허용 — 중복 방지는 idempotency_key의 몫")] = None,
    requested_delivery_date: Annotated[Optional[str], Field(description="희망 납기일 (YYYY-MM-DD)")] = None,
    declared_weight_kg: Annotated[Optional[float], Field(description="선언 중량(kg). 마스터데이터가 아니라 호출자 선언값이다")] = None,
    declared_volume_l: Annotated[Optional[float], Field(description="선언 용적(L). 마스터데이터가 아니라 호출자 선언값이다")] = None,
    correlation_id: Annotated[Optional[str], Field(description="ProcessGPT process_instance_id 등 상관관계 ID")] = None,
    idempotency_key: Annotated[Optional[str], Field(description="재시도 시 동일 키 재사용. 미지정 시 새로 생성")] = None,
    dry_run: Annotated[bool, Field(description="true면 실제 반영 없이 예상 결과만 반환")] = False,
) -> dict:
    """서열을 매길 최소 출고 단위를 등록한다 (상태 OPEN).

    이 도구는 **출고 이행 스펙이 아니다**. 재고 가용성을 확인하지 않고, 재고를
    예약하지 않으며, 원장(stock_ledger_entries)을 건드리지 않는다. FIFO/FEFO
    할당, 피킹, 포장·출하 확정, 취소 시 재고 복원은 전부 범위 밖이다 — 이
    레코드는 "무엇을 어느 매장으로 얼마나 내보낼지"만 담은, 서열을 매길 수 있는
    최소 골격이다.

    상품 하나당 행 하나로 평탄화되어 있다(wms.purchase_orders와 같은 관례).
    같은 매장으로 여러 상품을 보내려면 store_code가 같은 여러 건을 등록하고,
    같은 팔레트로 묶는 것은 assign_dispatch_sequence의 target_pallet_code가
    담당한다 — 주문 헤더 개념은 없다.

    declared_weight_kg / declared_volume_l은 wms.products에 중량·용적
    마스터데이터가 없기 때문에 호출자가 선언하는 값이다. 이 값의 합계가
    dispatch_palletize_command의 상한 검증 기준이 되므로, 팔레트 중량 관리를
    하려면 등록 시점에 채워 두는 것이 좋다.

    WMS_ADMIN / WAREHOUSE_MANAGER / PROCESS_AGENT 역할이 필요하다 —
    WCS_OPERATOR는 서열 배정은 할 수 있지만 출고 단위 생성은 할 수 없다
    (출고 단위 생성은 상위 업무 판단).
    """
    if dry_run:
        return {"result": "dry_run", "would_call": "wms_create_outbound_order", "input": {
            "warehouse_id": warehouse_id, "store_code": store_code,
            "product_id": product_id, "qty": qty,
        }}
    try:
        data = _call_rpc("wms_create_outbound_order", {
            "p_tenant_id": tenant_id, "p_warehouse_id": warehouse_id,
            "p_store_code": store_code, "p_product_id": product_id, "p_qty": qty,
            "p_actor_id": _agent_user_id(), "p_idempotency_key": idempotency_key or _new_key(),
            "p_order_number": order_number,
            "p_requested_delivery_date": requested_delivery_date,
            "p_declared_weight_kg": declared_weight_kg,
            "p_declared_volume_l": declared_volume_l,
            "p_correlation_id": correlation_id,
        })
        return {
            "result": "ok", "document_id": data["document_id"], "status": data["status"],
            "version": data["version"], "warnings": data["warnings"],
            "links": {
                "outbound_order_id": data["outbound_order_id"],
                "store_code": data["store_code"],
            },
            "next_actions": ["assign_dispatch_sequence", "get_dispatch_sequence_status"],
        }
    except WmsCommandError as exc:
        return _error_result(exc)


async def assign_dispatch_sequence(
    outbound_order_id: Annotated[str, Field(description="출고 단위 UUID (create_outbound_order가 반환)")],
    wave_id: Annotated[str, Field(description="디스패치 웨이브 UUID. OPEN 상태여야 한다 (open_dispatch_wave 참고)")],
    sequence_position: Annotated[int, Field(description="웨이브 안에서의 서열 위치. 0보다 커야 하고 같은 웨이브 안에서 유일해야 한다")],
    target_pallet_code: Annotated[str, Field(description="목표 팔레트 그룹 코드 (예: PLT-0001). 같은 코드끼리 한 번의 PALLETIZE 명령으로 묶인다")],
    expected_version: Annotated[int, Field(description="낙관적 동시성 — **출고 단위**(outbound order)의 현재 version. 서열 배정 레코드가 아니다")],
    correlation_id: Annotated[Optional[str], Field(description="상관관계 ID")] = None,
    idempotency_key: Annotated[Optional[str], Field(description="재시도 시 동일 키 재사용. 미지정 시 새로 생성")] = None,
    dry_run: Annotated[bool, Field(description="true면 실제 반영 없이 예상 결과만 반환")] = False,
) -> dict:
    """OPEN 상태의 출고 단위를 디스패치 웨이브 안에 서열 배정한다.

    두 가지를 동시에 정한다 — **언제**(어느 웨이브의 몇 번째)와 **어디에**(어느
    팔레트에). 서열 위치나 팔레트 배분을 계산해 주지는 않는다: 매장 진열 순서
    최적화, 배송 경로 최적화, 중량/용적 기반 자동 팔레트 분배(bin packing)는
    이 계약의 범위 밖이며, 호출자(사람 운영자 또는 상위 계획 엔진)가 이미
    결정한 값을 받아 저장·검증할 뿐이다.

    성공하면 서열 배정이 QUEUED 상태로 만들어지고 출고 단위는 SEQUENCED로
    전이한다. 거부되는 경우:

      - 출고 단위가 OPEN이 아님 (이미 서열이 배정되었거나 진행 중)  -> INVALID
      - 웨이브가 OPEN이 아님 (이미 RELEASED)                        -> INVALID
      - 같은 웨이브에 그 sequence_position이 이미 있음              -> INVALID
      - expected_version이 어긋남                                   -> CONFLICT

    취소된(CANCELLED) 배정은 위치와 출고 단위를 다시 풀어 준다 — 취소 후에는
    같은 위치·같은 출고 단위로 재배정할 수 있다.

    WMS_ADMIN / WAREHOUSE_MANAGER / WCS_OPERATOR / PROCESS_AGENT 역할이 필요하다.
    """
    if dry_run:
        return {"result": "dry_run", "would_call": "wms_assign_dispatch_sequence", "input": {
            "outbound_order_id": outbound_order_id, "wave_id": wave_id,
            "sequence_position": sequence_position, "target_pallet_code": target_pallet_code,
        }}
    try:
        data = _call_rpc("wms_assign_dispatch_sequence", {
            "p_outbound_order_id": outbound_order_id, "p_wave_id": wave_id,
            "p_sequence_position": sequence_position,
            "p_target_pallet_code": target_pallet_code,
            "p_actor_id": _agent_user_id(), "p_idempotency_key": idempotency_key or _new_key(),
            "p_expected_version": expected_version, "p_correlation_id": correlation_id,
        })
        return {
            "result": "ok", "document_id": data["document_id"], "status": data["status"],
            "version": data["version"], "warnings": data["warnings"],
            "links": {
                "dispatch_sequence_id": data["dispatch_sequence_id"],
                "outbound_order_id": data["outbound_order_id"],
                "outbound_order_status": data["outbound_order_status"],
                "outbound_order_version": data["outbound_order_version"],
                "wave_id": data["wave_id"],
                "target_pallet_code": data["target_pallet_code"],
            },
            "next_actions": ["dispatch_palletize_command", "cancel_dispatch_sequence",
                             "get_dispatch_sequence_status"],
        }
    except WmsCommandError as exc:
        return _error_result(exc)


async def cancel_dispatch_sequence(
    dispatch_sequence_id: Annotated[str, Field(description="서열 배정 UUID (assign_dispatch_sequence가 반환)")],
    expected_version: Annotated[int, Field(description="낙관적 동시성 — **서열 배정**(dispatch sequence)의 현재 version")],
    reason: Annotated[Optional[str], Field(description="취소 사유. 형제 배정에도 같은 사유가 기록된다")] = None,
    correlation_id: Annotated[Optional[str], Field(description="상관관계 ID")] = None,
    idempotency_key: Annotated[Optional[str], Field(description="재시도 시 동일 키 재사용. 미지정 시 새로 생성")] = None,
    dry_run: Annotated[bool, Field(description="true면 실제 반영 없이 예상 결과만 반환")] = False,
) -> dict:
    """아직 종결되지 않은(QUEUED / DISPATCHED) 서열 배정을 취소한다.

    **DISPATCHED 배정을 취소하면 형제 배정까지 취소된다.** PALLETIZE 명령은
    본질적으로 배치라서, 같은 (웨이브, 팔레트)에 묶인 여러 배정이 명령 하나를
    공유한다. 그 명령을 취소하면 형제 배정도 물리적으로 무의미해지므로 함께
    CANCELLED로 내리고, 응답의 cancelled_sibling_sequence_ids와
    SIBLING_SEQUENCES_CANCELLED 경고로 알려 준다. expected_version은 지정한
    배정 것만 검사한다(형제들의 version은 호출자가 알 수 없으므로).

    취소된 출고 단위는 OPEN으로 되돌아가므로 다시 서열을 매길 수 있다.
    이미 COMPLETED / FAILED / CANCELLED인 배정은 INVALID로 거부된다.

    이 취소는 **재고 측 효과가 전혀 없다** — 애초에 이 계약이 재고를 예약하지
    않기 때문이다(create_outbound_order 설명 참고).

    WMS_ADMIN / WAREHOUSE_MANAGER / WCS_OPERATOR / PROCESS_AGENT 역할이 필요하다.
    """
    if dry_run:
        return {"result": "dry_run", "would_call": "wms_cancel_dispatch_sequence", "input": {
            "dispatch_sequence_id": dispatch_sequence_id, "expected_version": expected_version,
        }}
    try:
        data = _call_rpc("wms_cancel_dispatch_sequence", {
            "p_dispatch_sequence_id": dispatch_sequence_id,
            "p_actor_id": _agent_user_id(), "p_idempotency_key": idempotency_key or _new_key(),
            "p_expected_version": expected_version, "p_reason": reason,
            "p_correlation_id": correlation_id,
        })
        return {
            "result": "ok", "document_id": data["document_id"], "status": data["status"],
            "version": data["version"], "warnings": data["warnings"],
            "links": {
                "dispatch_sequence_id": data["dispatch_sequence_id"],
                "outbound_order_id": data["outbound_order_id"],
                "cancelled_equipment_command_id": data["cancelled_equipment_command_id"],
                "cancelled_sibling_sequence_ids": data["cancelled_sibling_sequence_ids"],
            },
            "next_actions": ["assign_dispatch_sequence", "get_dispatch_sequence_status"],
        }
    except WmsCommandError as exc:
        return _error_result(exc)


async def dispatch_palletize_command(
    equipment_id: Annotated[str, Field(description="대상 ROBOT_CELL 설비 UUID. 자동 선택하지 않는다 — 호출자가 명시해야 한다")],
    wave_id: Annotated[str, Field(description="디스패치 웨이브 UUID")],
    target_pallet_code: Annotated[str, Field(description="이 명령으로 쌓을 팔레트 코드. 같은 (wave, pallet)의 QUEUED 배정 전부가 한 명령에 담긴다")],
    expected_version: Annotated[int, Field(description="낙관적 동시성 — **설비**(equipment)의 현재 version. 서열 배정 것이 아니다")],
    max_weight_kg: Annotated[Optional[float], Field(description="팔레트 중량 상한(kg). 지정하면 선언 중량 합계가 이를 넘을 때 디스패치 자체가 거부된다")] = None,
    max_volume_l: Annotated[Optional[float], Field(description="팔레트 용적 상한(L). 지정하면 선언 용적 합계가 이를 넘을 때 디스패치 자체가 거부된다")] = None,
    correlation_id: Annotated[Optional[str], Field(description="상관관계 ID")] = None,
    idempotency_key: Annotated[Optional[str], Field(description="재시도 시 동일 키 재사용. 미지정 시 새로 생성")] = None,
    dry_run: Annotated[bool, Field(description="true면 실제 반영 없이 예상 결과만 반환")] = False,
) -> dict:
    """같은 팔레트로 묶인 서열 배정 전부를 하나의 PALLETIZE 명령으로 로봇 셀에 보낸다.

    지정한 (wave_id, target_pallet_code)의 QUEUED 서열 배정을 모두 모아
    sequence_position 오름차순으로 정렬해 payload.sequence_items에 싣는다 —
    이것이 "혼합 팔레타이징"이다. 성공하면 그 배정들이 전부 DISPATCHED가 되고
    같은 equipment_command_id를 갖는다. 해당하는 QUEUED 배정이 하나도 없으면
    INVALID로 거부된다.

    **대상 셀은 자동 선택되지 않는다.** 하나의 물리 팔레트는 처음부터 끝까지
    같은 셀에서 쌓여야 하므로, 다른 계약(WES 업무 오더, 병목 라우팅)의 "가용
    설비 자동 선택"을 여기에는 적용하지 않는다. 셀은 IDLE이거나, 이미 **같은**
    팔레트를 쌓고 있는 RUNNING이어야 한다 — 다른 팔레트를 쌓는 중이면 INVALID다.

    중량/용적 상한은 두 시점에서 서로 다른 뜻으로 검증된다:

      - **계획 시점**(이 도구): 선언값 합계 > 상한 -> INVALID, 명령 자체가
        만들어지지 않는다. "애초에 잘못 짠 배치".
      - **실측 시점**(결과 보고): 실제 계근/체적이 상한을 넘으면
        report_command_result에 outcome=OVERWEIGHT / OVERVOLUME으로 돌아온다.
        "계획은 맞았지만 실물이 달랐다".

    결과 보고에는 별도 도구가 없다 — 설비 쪽(WCS_GATEWAY)이
    report_command_result를 호출하며 detail은 다음 형태다:

      {"outcome": "SUCCESS"|"PARTIAL"|"OVERWEIGHT"|"OVERVOLUME"|"ABORTED",
       "total_actual_weight_kg": 182.4,
       "total_actual_volume_l": 340.0,
       "loaded_items": [
         {"dispatch_sequence_id": "...", "load_position": 1, "item_outcome": "LOADED"},
         {"dispatch_sequence_id": "...", "load_position": null,
          "item_outcome": "SKIPPED", "reason": "OVERWEIGHT"}]}

    SUCCESS/PARTIAL은 command_status=COMPLETED와만, 나머지는 FAILED와만 짝지을
    수 있고, SUCCESS는 모든 항목이 LOADED여야, OVERWEIGHT/OVERVOLUME/ABORTED는
    모든 항목이 SKIPPED여야 한다. 보고가 통과하면 각 항목이 가리키는 서열 배정이
    **항목별로** COMPLETED(LOADED) 또는 FAILED(SKIPPED)로 자동 반영된다 —
    에이전트가 따로 상태를 되돌릴 필요가 없다.

    스트레치 포장(WRAP)도 별도 도구가 없다 — dispatch_equipment_command에
    command_type='WRAP', payload={"pallet_code": "...", "wrap_program":
    "STANDARD"|"HEAVY"}로 보낸다. WRAP은 서열 배정 상태를 바꾸지 않는다.

    WAREHOUSE_MANAGER / WCS_OPERATOR / PROCESS_AGENT 역할이 필요하다.
    **WMS_ADMIN은 제외된다** — 내부적으로 호출하는
    wms_dispatch_equipment_command가 WMS_ADMIN을 허용하지 않기 때문이다.
    """
    if dry_run:
        return {"result": "dry_run", "would_call": "wms_dispatch_palletize_command", "input": {
            "equipment_id": equipment_id, "wave_id": wave_id,
            "target_pallet_code": target_pallet_code,
            "max_weight_kg": max_weight_kg, "max_volume_l": max_volume_l,
        }}
    try:
        data = _call_rpc("wms_dispatch_palletize_command", {
            "p_equipment_id": equipment_id, "p_wave_id": wave_id,
            "p_target_pallet_code": target_pallet_code,
            "p_actor_id": _agent_user_id(), "p_idempotency_key": idempotency_key or _new_key(),
            "p_expected_version": expected_version,
            "p_max_weight_kg": max_weight_kg, "p_max_volume_l": max_volume_l,
            "p_correlation_id": correlation_id,
        })
        return {
            "result": "ok", "document_id": data["document_id"], "status": data["status"],
            "version": data["version"], "warnings": data["warnings"],
            "links": {
                "equipment_command_id": data["equipment_command_id"],
                "equipment_id": data["equipment_id"],
                "equipment_code": data["equipment_code"],
                "equipment_version": data["equipment_version"],
                "target_pallet_code": data["target_pallet_code"],
                "item_count": data["item_count"],
                "declared_total_weight_kg": data["declared_total_weight_kg"],
                "declared_total_volume_l": data["declared_total_volume_l"],
                "dispatch_sequence_ids": data["dispatch_sequence_ids"],
            },
            "next_actions": ["get_pallet_manifest", "get_dispatch_sequence_status",
                             "cancel_dispatch_sequence"],
        }
    except WmsCommandError as exc:
        return _error_result(exc)


async def get_dispatch_sequence_status(
    tenant_id: Annotated[str, Field(description="테넌트 UUID")],
    warehouse_id: Annotated[str, Field(description="창고 UUID")],
    wave_id: Annotated[Optional[str], Field(description="특정 웨이브만 조회할 경우 그 UUID. 미지정 시 창고 전체")] = None,
    outbound_order_id: Annotated[Optional[str], Field(description="특정 출고 단위만 조회할 경우 그 UUID")] = None,
) -> dict:
    """출고 단위·서열 배정 현황을 웨이브별/팔레트별로 조회한다 (읽기 전용).

    다섯 묶음을 돌려준다:

      outbound_orders  등록된 출고 단위 전부 (아직 서열이 없는 OPEN 건 포함)
      sequences        서열 배정 — sequence_position 순, 연결된 설비 명령 상태 포함
      waves            창고의 디스패치 웨이브와 배정 건수
      robot_cells      ROBOT_CELL 설비와 현재 쌓고 있는 팔레트 코드
      pallets          (wave, pallet) 단위 롤업 — QUEUED/DISPATCHED/COMPLETED/
                       FAILED 건수와 선언 중량·용적 합계

    "왜 이 배정이 아직 QUEUED인가"에 답하려면 pallets의 queued_count와
    robot_cells의 active_palletize_pallet을 함께 보면 된다 — 셀이 이미 다른
    팔레트를 쌓고 있으면 새 팔레트 빌드를 시작할 수 없다.

    창고 스코프가 없으면 FORBIDDEN이 반환된다.
    """
    try:
        data = _call_rpc("wms_get_dispatch_sequence_status", {
            "p_tenant_id": tenant_id, "p_warehouse_id": warehouse_id,
            "p_wave_id": wave_id, "p_outbound_order_id": outbound_order_id,
        })
        return {"result": "ok", "document": data}
    except WmsCommandError as exc:
        return _error_result(exc)


async def get_pallet_manifest(
    tenant_id: Annotated[str, Field(description="테넌트 UUID")],
    warehouse_id: Annotated[str, Field(description="창고 UUID")],
    equipment_command_id: Annotated[Optional[str], Field(description="특정 PALLETIZE 명령의 매니페스트만 조회할 경우 그 UUID")] = None,
    target_pallet_code: Annotated[Optional[str], Field(description="팔레트 코드로 필터링할 경우 그 값")] = None,
) -> dict:
    """팔레트에 실제로 무엇이 어느 위치에 실렸는지 조회한다 (읽기 전용).

    PALLETIZE 명령의 결과 보고(detail.loaded_items)를 펼쳐 서열 배정·출고
    단위와 조인한 결과다. 팔레트마다 다음을 돌려준다:

      command_status          PALLETIZE 명령의 현재 상태
      planned_item_count      디스패치 시점에 계획된 항목 수
      declared_total_*        선언 중량·용적 합계 (계획값)
      max_weight_kg/volume_l  디스패치 때 지정한 상한 (없으면 null)
      reported                결과가 보고되었는가
      outcome                 SUCCESS / PARTIAL / OVERWEIGHT / OVERVOLUME / ABORTED
      total_actual_*          설비가 실측해 보고한 중량·용적
      items[]                 항목별 load_position, item_outcome, reason과
                              해당 출고 단위의 매장·SKU·수량

    **아직 결과가 보고되지 않은 명령은 오류가 아니라 빈 매니페스트**로 돌아온다
    (reported=false, items=[]). planned_item_count는 그때도 채워지므로 "몇 개를
    보냈는데 아직 응답이 없다"를 구분할 수 있다.

    계획값(declared_total_*)과 실측값(total_actual_*)을 나란히 보면 선언 중량이
    실제와 얼마나 어긋나는지 관찰할 수 있다 — 이 저장소에는 상품 중량
    마스터데이터가 없어 선언값이 호출자 입력이기 때문에, 이 편차가 곧 데이터
    품질 신호다.

    창고 스코프가 없으면 FORBIDDEN이 반환된다.
    """
    try:
        data = _call_rpc("wms_get_pallet_manifest", {
            "p_tenant_id": tenant_id, "p_warehouse_id": warehouse_id,
            "p_equipment_command_id": equipment_command_id,
            "p_target_pallet_code": target_pallet_code,
        })
        return {"result": "ok", "document": data}
    except WmsCommandError as exc:
        return _error_result(exc)


# ============================================================
# WCS digital twin / simulation
# (openspec/changes/add-wcs-digital-twin-simulation, migration
#  supabase/migrations/20260801_wcs_digital_twin_simulation.sql)
#
# Two identities again, and for the same reason area 1 split them (design.md D5,
# D9 — no new service role was added here):
#   - Humans decide what is simulated and how fast it pretends to be. Those
#     tools run as PROCESS_AGENT and will return FORBIDDEN for it, exactly like
#     register_equipment does — the check lives in the RPC, not here.
#   - WCS_GATEWAY plans and advances commands. Those three tools go through
#     _call_rpc_as_gateway.
#
# The polling LOOP is deliberately NOT an MCP tool. It is a process:
#   mcp/wms_mcp/simulator/wcs_gateway_simulator.py  (see its README).
# An agent asking "tick the simulator once" would be the wrong shape — the
# clock has to keep running whether or not anyone is talking to the MCP server.
# ============================================================


async def set_equipment_simulation_mode(
    equipment_id: Annotated[str, Field(description="설비 UUID")],
    is_simulated: Annotated[bool, Field(description="true면 이 설비의 명령을 소프트웨어 시뮬레이터가 자동 이행한다")],
    expected_version: Annotated[int, Field(description="낙관적 동시성 — 설비(equipment)의 현재 version")],
    correlation_id: Annotated[Optional[str], Field(description="ProcessGPT process_instance_id 등 상관관계 ID")] = None,
    idempotency_key: Annotated[Optional[str], Field(description="재시도 시 동일 키 재사용. 미지정 시 새로 생성")] = None,
    dry_run: Annotated[bool, Field(description="true면 실제 반영 없이 예상 결과만 반환")] = False,
) -> dict:
    """설비를 시뮬레이션 대상으로 켜거나 끈다.

    켜면 그 설비에 디스패치된 명령을 외부 워커(wcs_gateway_simulator)가
    프로파일의 타이밍·실패율대로 자동 진행시킨다. 끄면 그 설비의 명령은 다시
    실제 게이트웨이나 사람 운영자의 몫이 되며, 진행 중이던 계획은 폐기된다
    (warnings에 PENDING_SIMULATION_PLANS_DISCARDED).

    설비의 status나 진행 중 명령은 이 호출로 바뀌지 않는다. WMS_ADMIN 또는
    WAREHOUSE_MANAGER 역할이 필요하다 — WCS_OPERATOR는 프로파일은 만질 수 있어도
    설비를 시뮬레이션 대상으로 전환할 수는 없다.
    """
    if dry_run:
        return {"result": "dry_run", "would_call": "wms_set_equipment_simulation_mode", "input": {
            "equipment_id": equipment_id, "is_simulated": is_simulated,
            "expected_version": expected_version,
        }}
    try:
        data = _call_rpc("wms_set_equipment_simulation_mode", {
            "p_equipment_id": equipment_id, "p_is_simulated": is_simulated,
            "p_actor_id": _agent_user_id(), "p_idempotency_key": idempotency_key or _new_key(),
            "p_expected_version": expected_version, "p_correlation_id": correlation_id,
        })
        return {
            "result": "ok", "document_id": data["document_id"], "status": data["status"],
            "version": data["version"], "warnings": data["warnings"],
            "links": {"equipment_id": data["equipment_id"], "is_simulated": data["is_simulated"]},
            "next_actions": ["register_simulation_profile", "get_simulation_profile"]
                            if data["is_simulated"] else ["get_simulation_profile"],
        }
    except WmsCommandError as exc:
        return _error_result(exc)


async def register_simulation_profile(
    equipment_id: Annotated[str, Field(description="설비 UUID. is_simulated=true여야 한다")],
    ack_delay_ms_min: Annotated[int, Field(description="PENDING→ACKNOWLEDGED 지연 최소값(ms)")],
    ack_delay_ms_max: Annotated[int, Field(description="PENDING→ACKNOWLEDGED 지연 최대값(ms)")],
    progress_delay_ms_min: Annotated[int, Field(description="ACKNOWLEDGED→IN_PROGRESS 지연 최소값(ms)")],
    progress_delay_ms_max: Annotated[int, Field(description="ACKNOWLEDGED→IN_PROGRESS 지연 최대값(ms)")],
    completion_delay_ms_min: Annotated[int, Field(description="IN_PROGRESS→종결 지연 최소값(ms)")],
    completion_delay_ms_max: Annotated[int, Field(description="IN_PROGRESS→종결 지연 최대값(ms)")],
    failure_rate: Annotated[float, Field(description="0~1. 명령이 COMPLETED가 아니라 FAILED로 끝날 확률")],
    jam_rate: Annotated[float, Field(description="0~1. 실패한 DIVERT 중 MISROUTE가 아니라 JAM이 될 조건부 확률. 다른 명령 타입에는 무의미")] = 0.0,
    correlation_id: Annotated[Optional[str], Field(description="ProcessGPT process_instance_id 등 상관관계 ID")] = None,
    idempotency_key: Annotated[Optional[str], Field(description="재시도 시 동일 키 재사용. 미지정 시 새로 생성")] = None,
    dry_run: Annotated[bool, Field(description="true면 실제 반영 없이 예상 결과만 반환")] = False,
) -> dict:
    """설비별 시뮬레이션 타이밍/실패율 프로파일을 등록한다 (설비당 1건).

    프로파일이 없어도 시뮬레이션은 시스템 기본값(ack 500~1500ms, progress
    1000~3000ms, completion 2000~5000ms, failure_rate 0.05, jam_rate 0)으로
    동작한다 — 프로파일은 그 기본값을 이 설비에 맞게 덮어쓰는 용도다.

    is_simulated=false인 설비이거나 이미 프로파일이 있으면 INVALID이 반환된다.
    각 지연 범위는 min <= max, 확률은 0~1이어야 한다.
    """
    if dry_run:
        return {"result": "dry_run", "would_call": "wms_register_simulation_profile", "input": {
            "equipment_id": equipment_id, "failure_rate": failure_rate, "jam_rate": jam_rate,
            "ack_delay_ms": [ack_delay_ms_min, ack_delay_ms_max],
            "progress_delay_ms": [progress_delay_ms_min, progress_delay_ms_max],
            "completion_delay_ms": [completion_delay_ms_min, completion_delay_ms_max],
        }}
    try:
        data = _call_rpc("wms_register_simulation_profile", {
            "p_equipment_id": equipment_id,
            "p_ack_delay_ms_min": ack_delay_ms_min, "p_ack_delay_ms_max": ack_delay_ms_max,
            "p_progress_delay_ms_min": progress_delay_ms_min,
            "p_progress_delay_ms_max": progress_delay_ms_max,
            "p_completion_delay_ms_min": completion_delay_ms_min,
            "p_completion_delay_ms_max": completion_delay_ms_max,
            "p_failure_rate": failure_rate, "p_jam_rate": jam_rate,
            "p_actor_id": _agent_user_id(), "p_idempotency_key": idempotency_key or _new_key(),
            "p_correlation_id": correlation_id,
        })
        return {
            "result": "ok", "document_id": data["document_id"], "status": data["status"],
            "version": data["version"],
            "links": {"profile_id": data["profile_id"], "equipment_id": data["equipment_id"],
                      "equipment_code": data["equipment_code"]},
            "next_actions": ["get_simulation_profile", "update_simulation_profile"],
        }
    except WmsCommandError as exc:
        return _error_result(exc)


async def update_simulation_profile(
    profile_id: Annotated[str, Field(description="시뮬레이션 프로파일 UUID (get_simulation_profile이 반환)")],
    expected_version: Annotated[int, Field(description="낙관적 동시성 — 프로파일의 현재 version")],
    ack_delay_ms_min: Annotated[Optional[int], Field(description="바꿀 값만 지정. 미지정 항목은 그대로 유지")] = None,
    ack_delay_ms_max: Annotated[Optional[int], Field(description="바꿀 값만 지정")] = None,
    progress_delay_ms_min: Annotated[Optional[int], Field(description="바꿀 값만 지정")] = None,
    progress_delay_ms_max: Annotated[Optional[int], Field(description="바꿀 값만 지정")] = None,
    completion_delay_ms_min: Annotated[Optional[int], Field(description="바꿀 값만 지정")] = None,
    completion_delay_ms_max: Annotated[Optional[int], Field(description="바꿀 값만 지정")] = None,
    failure_rate: Annotated[Optional[float], Field(description="0~1")] = None,
    jam_rate: Annotated[Optional[float], Field(description="0~1")] = None,
    status: Annotated[Optional[str], Field(description="ACTIVE 또는 INACTIVE. INACTIVE면 시스템 기본값으로 대체된다")] = None,
    correlation_id: Annotated[Optional[str], Field(description="ProcessGPT process_instance_id 등 상관관계 ID")] = None,
    idempotency_key: Annotated[Optional[str], Field(description="재시도 시 동일 키 재사용. 미지정 시 새로 생성")] = None,
    dry_run: Annotated[bool, Field(description="true면 실제 반영 없이 예상 결과만 반환")] = False,
) -> dict:
    """시뮬레이션 프로파일의 타이밍·확률·활성 여부를 갱신한다 (부분 갱신).

    아무 필드도 지정하지 않으면 INVALID이 반환된다 — 빈 갱신으로 version만
    올라가는 것을 막는다. status=INACTIVE로 두면 프로파일 행은 남지만 효력이
    사라져 시스템 기본값이 다시 적용된다(삭제 대신 쓰는 되돌리기 수단).
    """
    if dry_run:
        return {"result": "dry_run", "would_call": "wms_update_simulation_profile", "input": {
            "profile_id": profile_id, "expected_version": expected_version,
            "failure_rate": failure_rate, "jam_rate": jam_rate, "status": status,
        }}
    try:
        data = _call_rpc("wms_update_simulation_profile", {
            "p_profile_id": profile_id, "p_actor_id": _agent_user_id(),
            "p_idempotency_key": idempotency_key or _new_key(),
            "p_expected_version": expected_version,
            "p_ack_delay_ms_min": ack_delay_ms_min, "p_ack_delay_ms_max": ack_delay_ms_max,
            "p_progress_delay_ms_min": progress_delay_ms_min,
            "p_progress_delay_ms_max": progress_delay_ms_max,
            "p_completion_delay_ms_min": completion_delay_ms_min,
            "p_completion_delay_ms_max": completion_delay_ms_max,
            "p_failure_rate": failure_rate, "p_jam_rate": jam_rate, "p_status": status,
            "p_correlation_id": correlation_id,
        })
        return {
            "result": "ok", "document_id": data["document_id"], "status": data["status"],
            "version": data["version"],
            "links": {"profile_id": data["profile_id"], "equipment_id": data["equipment_id"]},
            "next_actions": ["get_simulation_profile"],
        }
    except WmsCommandError as exc:
        return _error_result(exc)


async def get_simulation_profile(
    tenant_id: Annotated[str, Field(description="테넌트 UUID")],
    warehouse_id: Annotated[str, Field(description="창고 UUID")],
    equipment_id: Annotated[Optional[str], Field(description="특정 설비만 조회할 경우 그 UUID. 미지정 시 창고 전체")] = None,
) -> dict:
    """설비별 시뮬레이션 모드와 적용 중인 타이밍 모델을 조회한다 (읽기 전용).

    설비마다 세 가지를 함께 돌려준다:

      is_simulated        이 설비를 시뮬레이터가 대신 응답하는가
      registered_profile  등록된 프로파일 행 (없으면 null, INACTIVE여도 보인다)
      effective_profile   실제로 적용되는 값. source가 SYSTEM_DEFAULT이고
                          is_default=true면 등록된 프로파일이 없거나 INACTIVE라
                          시스템 기본값이 쓰이고 있다는 뜻이다.

    응답 최상위의 system_defaults에 그 기본값 자체도 함께 실려 있어, 프로파일을
    새로 등록할 때 출발점으로 쓸 수 있다. 창고 스코프가 없으면 FORBIDDEN이다.
    """
    try:
        data = _call_rpc("wms_get_simulation_profile", {
            "p_tenant_id": tenant_id, "p_warehouse_id": warehouse_id,
            "p_equipment_id": equipment_id,
        })
        return {"result": "ok", "document": data}
    except WmsCommandError as exc:
        return _error_result(exc)


async def plan_simulated_command(
    command_id: Annotated[str, Field(description="설비 명령 UUID. 그 설비가 is_simulated=true여야 한다")],
    correlation_id: Annotated[Optional[str], Field(description="ProcessGPT process_instance_id 등 상관관계 ID")] = None,
    idempotency_key: Annotated[Optional[str], Field(description="재시도 시 동일 키 재사용. 미지정 시 새로 생성")] = None,
    dry_run: Annotated[bool, Field(description="true면 실제 반영 없이 예상 결과만 반환")] = False,
) -> dict:
    """시뮬레이션 명령의 진행 계획을 수립한다 (WCS_GATEWAY 신원으로 호출).

    프로파일(또는 기본값)의 지연 범위와 확률을 **이 시점에 한 번만** 굴려
    각 단계의 목표 시각, 최종 결과(COMPLETED/FAILED), 종결 시 보고할 결과
    payload를 계획으로 고정한다. 계획은 DB에 저장되므로 워커가 재시작돼도
    이어서 진행된다.

    이미 계획이 있는 명령을 다시 호출하면 새 계획을 만들지 않고 기존 계획을
    그대로 돌려준다(already_planned=true) — 주사위는 두 번 굴리지 않는다.

    보통은 사람이 직접 부를 도구가 아니다. 폴링 워커
    (mcp/wms_mcp/simulator/wcs_gateway_simulator.py)가 이 호출을 대신 한다.
    """
    if dry_run:
        return {"result": "dry_run", "would_call": "wms_plan_simulated_command",
                "input": {"command_id": command_id}}
    try:
        data = _call_rpc_as_gateway("wms_plan_simulated_command", {
            "p_command_id": command_id, "p_actor_id": _gateway_user_id(),
            "p_idempotency_key": idempotency_key or _new_key(), "p_correlation_id": correlation_id,
        })
        return {
            "result": "ok", "document_id": data["document_id"], "status": data["status"],
            "version": data["version"],
            "links": {
                "schedule_id": data["schedule_id"], "command_id": data["command_id"],
                "equipment_id": data["equipment_id"],
                "next_status": data["next_status"], "next_run_at": data["next_run_at"],
                "planned_terminal_status": data["planned_terminal_status"],
                "planned_detail": data["planned_detail"],
                "already_planned": data["already_planned"],
            },
            "next_actions": ["get_due_simulation_actions", "advance_simulated_command"],
        }
    except WmsCommandError as exc:
        return _error_result(exc)


async def get_due_simulation_actions(
    tenant_id: Annotated[str, Field(description="테넌트 UUID")],
    warehouse_id: Annotated[str, Field(description="창고 UUID")],
    as_of: Annotated[Optional[str], Field(description="이 시각 기준으로 도래 여부를 판정한다 (ISO8601). 미지정 시 서버의 now()")] = None,
) -> dict:
    """시뮬레이터 워커의 폴링 뷰를 조회한다 (WCS_GATEWAY 신원, 읽기 전용).

    두 묶음을 한 번에 돌려준다:

      unplanned_commands  is_simulated 설비에 떠 있는 진행 중 명령 중 아직 계획이
                          없는 것 — plan_simulated_command 대상
      due_actions         next_run_at이 도래한 계획, 도래 시각 오름차순 —
                          advance_simulated_command 대상

    is_simulated=false 설비의 명령은 어느 쪽에도 나타나지 않는다. 그런 명령의
    상태 전이는 실제 게이트웨이나 사람 운영자의 몫이다.
    """
    try:
        data = _call_rpc_as_gateway("wms_get_due_simulation_actions", {
            "p_tenant_id": tenant_id, "p_warehouse_id": warehouse_id, "p_as_of": as_of,
        })
        return {"result": "ok", "document": data}
    except WmsCommandError as exc:
        return _error_result(exc)


async def advance_simulated_command(
    command_id: Annotated[str, Field(description="설비 명령 UUID. 계획이 있고 도래해 있어야 한다")],
    correlation_id: Annotated[Optional[str], Field(description="ProcessGPT process_instance_id 등 상관관계 ID")] = None,
    idempotency_key: Annotated[Optional[str], Field(description="재시도 시 동일 키 재사용. 미지정 시 새로 생성")] = None,
    dry_run: Annotated[bool, Field(description="true면 실제 반영 없이 예상 결과만 반환")] = False,
) -> dict:
    """계획된 다음 단계를 실제로 보고한다 (WCS_GATEWAY 신원으로 호출).

    내부적으로 wms_wcs-equipment-control의 진짜 결과 보고 RPC를 호출하므로,
    시뮬레이션 명령이라도 업무 오더 완료 전파, 분류 결과 검증, JAM의 자동 장애
    승격, 팔레타이징 항목별 전파 같은 후속 계약의 트리거가 실제 설비와 똑같이
    동작한다.

    중간 단계면 계획이 다음 단계로 갱신되고(plan_remaining=true), 종결 단계면
    계획이 제거된다(plan_remaining=false). 계획이 없거나 아직 도래하지 않았으면
    INVALID이 반환된다. 다른 경로(장애 승격, 운영자 취소)가 명령을 먼저 종결시킨
    경우에는 오류 대신 계획만 폐기하고 warnings에 COMMAND_ALREADY_TERMINAL을
    담아 돌려준다.
    """
    if dry_run:
        return {"result": "dry_run", "would_call": "wms_advance_simulated_command",
                "input": {"command_id": command_id}}
    try:
        data = _call_rpc_as_gateway("wms_advance_simulated_command", {
            "p_command_id": command_id, "p_actor_id": _gateway_user_id(),
            "p_idempotency_key": idempotency_key or _new_key(), "p_correlation_id": correlation_id,
        })
        return {
            "result": "ok", "document_id": data["document_id"], "status": data["status"],
            "version": data["version"], "warnings": data["warnings"],
            "links": {
                "command_id": data["command_id"], "equipment_id": data["equipment_id"],
                "reported_status": data["reported_status"],
                "reported_detail": data["reported_detail"],
                "equipment_status": data["equipment_status"],
                "plan_remaining": data["plan_remaining"],
                "next_status": data["next_status"], "next_run_at": data["next_run_at"],
            },
            "next_actions": data["next_actions"],
        }
    except WmsCommandError as exc:
        return _error_result(exc)


async def get_simulation_schedule_status(
    tenant_id: Annotated[str, Field(description="테넌트 UUID")],
    warehouse_id: Annotated[str, Field(description="창고 UUID")],
    equipment_id: Annotated[Optional[str], Field(description="특정 설비만 조회할 경우 그 UUID")] = None,
    due_only: Annotated[bool, Field(description="true면 이미 도래한 계획만")] = False,
) -> dict:
    """진행 중인 시뮬레이션 계획을 조회한다 (읽기 전용, 모든 창고 멤버).

    계획마다 다음 보고 예정 상태(next_status), 예정 시각(next_run_at), 도래
    여부(is_due), 계획 수립 시점에 확정된 최종 결과(planned_terminal_status)와
    결과 payload(planned_detail), 그리고 그 계획이 등록 프로파일에서 나왔는지
    시스템 기본값에서 나왔는지(profile_source)를 함께 돌려준다.

    "이 명령이 언제 끝날 예정인가"에 답하는 창구다 — 시뮬레이션 진행이
    블랙박스가 되지 않도록 계획을 사람이 조회할 수 있게 열어 둔 것이다.
    """
    try:
        data = _call_rpc("wms_get_simulation_schedule_status", {
            "p_tenant_id": tenant_id, "p_warehouse_id": warehouse_id,
            "p_equipment_id": equipment_id, "p_due_only": due_only,
        })
        return {"result": "ok", "document": data}
    except WmsCommandError as exc:
        return _error_result(exc)


async def create_simulation_scenario(
    tenant_id: Annotated[str, Field(description="테넌트 UUID")],
    warehouse_id: Annotated[str, Field(description="창고 UUID")],
    name: Annotated[str, Field(description="사람이 읽는 시나리오 이름")],
    equipment_ids: Annotated[list[str], Field(description="이 시나리오가 가정하는 설비 UUID 목록 (1개 이상)")],
    command_count: Annotated[int, Field(description="그 설비 집합이 처리한다고 가정할 명령 건수 (> 0)")],
    linked_entity_type: Annotated[Optional[str], Field(description="참고용 상위 엔티티 종류 (예: dispatch_wave). 조인 대상이 아닌 라벨")] = None,
    linked_entity_id: Annotated[Optional[str], Field(description="참고용 상위 엔티티 UUID")] = None,
    correlation_id: Annotated[Optional[str], Field(description="ProcessGPT process_instance_id 등 상관관계 ID")] = None,
    idempotency_key: Annotated[Optional[str], Field(description="재시도 시 동일 키 재사용. 미지정 시 새로 생성")] = None,
    dry_run: Annotated[bool, Field(description="true면 실제 반영 없이 예상 결과만 반환")] = False,
) -> dict:
    """what-if 시나리오를 정의한다 (status=DRAFT).

    "이 설비 집합으로 이만큼의 명령을 처리하면 얼마나 걸릴까"를 묻기 위한
    정의다. 정의만으로는 아무 일도 일어나지 않으며, run_simulation_scenario를
    불러야 추정치가 산출된다.

    **command_count는 호출자가 직접 넘겨야 한다** — 이 계약은 웨이브나 업무
    오더를 조인하지 않는다(느슨한 참조만 라벨로 붙일 수 있다). "웨이브 X와
    사실상 동일한" 시나리오를 만들려면 get_work_order_status나
    get_dispatch_sequence_status로 실제 큐잉 건수를 먼저 세서 그 값을 넣어라.
    이 미해결 통합 지점은 의도적으로 열어 둔 것이다.

    설비 집합이 비었거나 command_count가 0 이하이면, 또는 지정한 설비가 그
    창고에 없으면 INVALID이 반환된다.
    """
    if dry_run:
        return {"result": "dry_run", "would_call": "wms_create_simulation_scenario", "input": {
            "tenant_id": tenant_id, "warehouse_id": warehouse_id, "name": name,
            "equipment_ids": equipment_ids, "command_count": command_count,
        }}
    try:
        data = _call_rpc("wms_create_simulation_scenario", {
            "p_tenant_id": tenant_id, "p_warehouse_id": warehouse_id, "p_name": name,
            "p_equipment_ids": equipment_ids, "p_command_count": command_count,
            "p_actor_id": _agent_user_id(), "p_idempotency_key": idempotency_key or _new_key(),
            "p_scenario_type": "EQUIPMENT_SUBSTITUTION",
            "p_linked_entity_type": linked_entity_type, "p_linked_entity_id": linked_entity_id,
            "p_correlation_id": correlation_id,
        })
        return {
            "result": "ok", "document_id": data["document_id"], "status": data["status"],
            "version": data["version"],
            "links": {"scenario_id": data["scenario_id"],
                      "equipment_count": data["equipment_count"],
                      "command_count": data["command_count"]},
            "next_actions": ["run_simulation_scenario", "get_simulation_scenario_status"],
        }
    except WmsCommandError as exc:
        return _error_result(exc)


async def run_simulation_scenario(
    scenario_id: Annotated[str, Field(description="시나리오 UUID")],
    correlation_id: Annotated[Optional[str], Field(description="ProcessGPT process_instance_id 등 상관관계 ID")] = None,
    idempotency_key: Annotated[Optional[str], Field(description="재시도 시 동일 키 재사용. 미지정 시 새로 생성")] = None,
    dry_run: Annotated[bool, Field(description="true면 실제 반영 없이 예상 결과만 반환")] = False,
) -> dict:
    """시나리오를 dry-run해 예상 완료 시점과 예상 실패 건수를 산출한다.

    **실제 설비 명령을 전혀 디스패치하지 않는다** — 순수 읽기 + 산술이며
    wms.equipment_commands에 아무 흔적도 남기지 않는다.

    모델은 의도적으로 단순하다:
        rounds   = ceil(command_count / 설비 수)
        1건 소요 = 설비별 (ack + progress + completion) 지연 범위 중간값의 합,
                   설비 집합 평균
        예상 완료 = now() + rounds × 1건 소요
        예상 실패 = command_count × 설비 집합 평균 failure_rate

    대기 행렬, 우선순위, 재시도, 설비별 처리량 차이를 전부 무시한 낙관적
    근사치이며 보장이 아니다 — 응답 warnings에 OPTIMISTIC_ESTIMATE로 항상
    명시된다. 등록 프로파일이 없어 기본값이 적용된 설비가 있으면
    DEFAULT_PROFILE_APPLIED 경고가, FAULT/MAINTENANCE/OFFLINE 설비가 섞여 있으면
    EQUIPMENT_NOT_AVAILABLE 경고가 함께 붙는다.

    같은 시나리오를 여러 번 실행할 수 있고, 실행마다 별개의 이력이 남는다.
    """
    if dry_run:
        return {"result": "dry_run", "would_call": "wms_run_simulation_scenario",
                "input": {"scenario_id": scenario_id}}
    try:
        data = _call_rpc("wms_run_simulation_scenario", {
            "p_scenario_id": scenario_id, "p_actor_id": _agent_user_id(),
            "p_idempotency_key": idempotency_key or _new_key(), "p_correlation_id": correlation_id,
        })
        return {
            "result": "ok", "document_id": data["document_id"], "status": data["status"],
            "version": data["version"], "warnings": data["warnings"],
            "links": {
                "run_id": data["run_id"], "scenario_id": data["scenario_id"],
                "projected_completion_at": data["projected_completion_at"],
                "projected_duration_ms": data["projected_duration_ms"],
                "projected_round_count": data["projected_round_count"],
                "projected_failure_count": data["projected_failure_count"],
                "assumptions": data["assumptions"],
            },
            "next_actions": ["get_simulation_scenario_status", "run_simulation_scenario"],
        }
    except WmsCommandError as exc:
        return _error_result(exc)


async def get_simulation_scenario_status(
    tenant_id: Annotated[str, Field(description="테넌트 UUID")],
    warehouse_id: Annotated[str, Field(description="창고 UUID")],
    scenario_id: Annotated[Optional[str], Field(description="특정 시나리오만 조회할 경우 그 UUID")] = None,
) -> dict:
    """정의된 시나리오와 그 실행 이력을 조회한다 (읽기 전용).

    시나리오마다 설비 집합(코드 포함), 가정 명령 건수, 실행 횟수, 그리고 실행
    이력 전체를 최신순으로 돌려준다. 같은 시나리오를 프로파일을 바꿔 가며 여러
    번 실행하면 이 목록에서 추정치가 어떻게 달라졌는지 비교할 수 있다 — 각
    실행의 assumptions에 그때 쓰인 설비별 프로파일 스냅샷이 들어 있다.
    """
    try:
        data = _call_rpc("wms_get_simulation_scenario_status", {
            "p_tenant_id": tenant_id, "p_warehouse_id": warehouse_id,
            "p_scenario_id": scenario_id,
        })
        return {"result": "ok", "document": data}
    except WmsCommandError as exc:
        return _error_result(exc)


# ============================================================
# Yard & dock scheduling
# (openspec/changes/add-yard-dock-scheduling, migration
#  supabase/migrations/20260802_yard_dock_scheduling.sql)
#
# The first non-WCS area. Nothing here talks to equipment: a dock is a physical
# door a truck backs onto, and every actor is a human (or an agent standing in
# for one). Hence no gateway identity — all eight tools use the normal
# PROCESS_AGENT session.
#
# NOTE on roles (design.md D5): only three of these are actually callable by
# PROCESS_AGENT, and the split is deliberate.
#   allowed  schedule_dock_appointment / cancel_dock_appointment /
#            get_dock_schedule — booking a slot is a planning decision.
#   refused  check_in_vehicle / dock_vehicle / depart_vehicle — these assert
#            that a truck PHYSICALLY moved. An agent has not seen the truck, so
#            the RPCs allow INBOUND_OPERATOR/WMS_ADMIN only and return FORBIDDEN
#            for the agent.
#   refused  register_dock / set_dock_status — registry and maintenance are
#            WMS_ADMIN/WAREHOUSE_MANAGER, like register_equipment.
# They are still exposed as tools, with the same belt-and-braces reasoning as
# inspect/scrap and register_equipment: the allowlist in
# docs/03-processgpt-integration.md is the first fence, RLS is the second.
# ============================================================


async def register_dock(
    tenant_id: Annotated[str, Field(description="테넌트 UUID")],
    warehouse_id: Annotated[str, Field(description="창고 UUID")],
    code: Annotated[str, Field(description="창고 내 고유 도크 코드 (예: DOCK-01)")],
    name: Annotated[str, Field(description="표시명 (예: 입고 하역장 1)")],
    correlation_id: Annotated[Optional[str], Field(description="ProcessGPT process_instance_id 등 상관관계 ID")] = None,
    idempotency_key: Annotated[Optional[str], Field(description="재시도 시 동일 키 재사용. 미지정 시 새로 생성")] = None,
    dry_run: Annotated[bool, Field(description="true면 실제 반영 없이 예상 결과만 반환")] = False,
) -> dict:
    """창고에 도크(하역장 게이트)를 등록한다. 등록 직후 상태는 AVAILABLE이다.

    WMS_ADMIN 또는 WAREHOUSE_MANAGER만 호출할 수 있다 — PROCESS_AGENT로
    호출하면 FORBIDDEN이 반환된다(마스터데이터 등록은 사람의 몫). 같은 창고에서
    code가 중복되면 INVALID이 반환된다.
    """
    if dry_run:
        return {"result": "dry_run", "would_call": "wms_register_dock", "input": {
            "tenant_id": tenant_id, "warehouse_id": warehouse_id, "code": code, "name": name,
        }}
    try:
        data = _call_rpc("wms_register_dock", {
            "p_tenant_id": tenant_id, "p_warehouse_id": warehouse_id,
            "p_code": code, "p_name": name, "p_actor_id": _agent_user_id(),
            "p_idempotency_key": idempotency_key or _new_key(), "p_correlation_id": correlation_id,
        })
        return {
            "result": "ok", "document_id": data["document_id"], "status": data["status"],
            "version": data["version"], "warnings": data["warnings"],
            "links": {"dock_id": data["dock_id"], "code": data["code"]},
            "next_actions": ["schedule_dock_appointment", "get_dock_schedule"],
        }
    except WmsCommandError as exc:
        return _error_result(exc)


async def set_dock_status(
    dock_id: Annotated[str, Field(description="도크 UUID")],
    new_status: Annotated[str, Field(description="AVAILABLE 또는 CLOSED. OCCUPIED는 지정할 수 없다")],
    expected_version: Annotated[int, Field(description="낙관적 동시성 버전 — get_dock_schedule로 얻은 도크 version")],
    reason: Annotated[Optional[str], Field(description="정비 사유 등")] = None,
    correlation_id: Annotated[Optional[str], Field(description="ProcessGPT process_instance_id 등 상관관계 ID")] = None,
    idempotency_key: Annotated[Optional[str], Field(description="재시도 시 동일 키 재사용. 미지정 시 새로 생성")] = None,
    dry_run: Annotated[bool, Field(description="true면 실제 반영 없이 예상 결과만 반환")] = False,
) -> dict:
    """도크를 정비를 위해 닫거나(CLOSED) 다시 연다(AVAILABLE).

    OCCUPIED는 이 도구로 지정할 수 없다 — 도크 점유는 차량 생애주기
    (dock_vehicle / depart_vehicle)에서 파생되는 상태다. 점유 중(OCCUPIED)인
    도크는 닫을 수 없다(먼저 출차 처리해야 함). CLOSED 도크에는 새 예약을
    만들 수 없다.

    WMS_ADMIN 또는 WAREHOUSE_MANAGER만 호출할 수 있다.
    """
    if dry_run:
        return {"result": "dry_run", "would_call": "wms_set_dock_status", "input": {
            "dock_id": dock_id, "new_status": new_status,
        }}
    try:
        data = _call_rpc("wms_set_dock_status", {
            "p_dock_id": dock_id, "p_new_status": new_status, "p_actor_id": _agent_user_id(),
            "p_idempotency_key": idempotency_key or _new_key(),
            "p_expected_version": expected_version, "p_reason": reason,
            "p_correlation_id": correlation_id,
        })
        return {
            "result": "ok", "document_id": data["document_id"], "status": data["status"],
            "version": data["version"], "warnings": data["warnings"],
            "links": {"dock_id": data["dock_id"], "code": data["code"]},
            "next_actions": data["next_actions"],
        }
    except WmsCommandError as exc:
        return _error_result(exc)


async def schedule_dock_appointment(
    dock_id: Annotated[str, Field(description="예약할 도크 UUID")],
    scheduled_start: Annotated[str, Field(description="예약 시작 시각 (ISO 8601, 예: 2026-08-01T09:00:00Z)")],
    scheduled_end: Annotated[str, Field(description="예약 종료 시각 (ISO 8601). scheduled_start보다 뒤여야 한다")],
    appointment_type: Annotated[str, Field(description="INBOUND 또는 OUTBOUND")] = "INBOUND",
    po_id: Annotated[Optional[str], Field(description="입고 PO UUID. INBOUND면 필수, OUTBOUND면 반드시 null")] = None,
    carrier_name: Annotated[Optional[str], Field(description="운송사명 (선택, 체크인 시 채워도 된다)")] = None,
    vehicle_plate_no: Annotated[Optional[str], Field(description="차량 번호 (선택)")] = None,
    linked_entity_type: Annotated[Optional[str], Field(description="OUTBOUND용 느슨한 참조 종류. 'outbound_order'만 검증되고 나머지는 그대로 저장")] = None,
    linked_entity_id: Annotated[Optional[str], Field(description="느슨한 참조 UUID. linked_entity_type과 함께 주어야 한다")] = None,
    correlation_id: Annotated[Optional[str], Field(description="ProcessGPT process_instance_id 등 상관관계 ID")] = None,
    idempotency_key: Annotated[Optional[str], Field(description="재시도 시 동일 키 재사용. 미지정 시 새로 생성")] = None,
    dry_run: Annotated[bool, Field(description="true면 실제 반영 없이 예상 결과만 반환")] = False,
) -> dict:
    """특정 도크의 특정 시간창을 예약한다 (status=SCHEDULED).

    **같은 도크에 진행 중(SCHEDULED/CHECKED_IN/AT_DOCK) 예약과 시간창이 겹치면
    CONFLICT가 반환된다.** 이 판정은 애플리케이션 체크가 아니라 Postgres
    exclusion 제약이 원자적으로 수행하므로, 두 호출이 동시에 들어와도 정확히
    하나만 성공한다. 취소(CANCELLED)되었거나 출차(DEPARTED)한 예약은 겹침
    판정에서 빠지므로 그 슬롯은 즉시 다시 예약할 수 있다.

    시간창은 반열림 구간이다 — 09:00~10:00 예약과 10:00~11:00 예약은 겹치지
    않는다. 예약을 잡기 전에 get_dock_schedule로 빈 슬롯을 먼저 확인하라.

    INBOUND면 po_id가 필수이며 그 PO는 도크와 같은 창고여야 한다. OUTBOUND면
    po_id는 null이어야 하고, 출고 단위와의 연결은
    linked_entity_type='outbound_order' + linked_entity_id로 건다(하드 FK는
    없지만 같은 창고에 존재하는지는 검증된다). CLOSED 도크는 예약할 수 없다.
    """
    if dry_run:
        return {"result": "dry_run", "would_call": "wms_schedule_dock_appointment", "input": {
            "dock_id": dock_id, "appointment_type": appointment_type, "po_id": po_id,
            "scheduled_start": scheduled_start, "scheduled_end": scheduled_end,
        }}
    try:
        data = _call_rpc("wms_schedule_dock_appointment", {
            "p_dock_id": dock_id, "p_scheduled_start": scheduled_start,
            "p_scheduled_end": scheduled_end, "p_actor_id": _agent_user_id(),
            "p_idempotency_key": idempotency_key or _new_key(),
            "p_appointment_type": appointment_type, "p_po_id": po_id,
            "p_carrier_name": carrier_name, "p_vehicle_plate_no": vehicle_plate_no,
            "p_linked_entity_type": linked_entity_type, "p_linked_entity_id": linked_entity_id,
            "p_correlation_id": correlation_id,
        })
        return {
            "result": "ok", "document_id": data["document_id"], "status": data["status"],
            "version": data["version"], "warnings": data["warnings"],
            "links": {
                "appointment_id": data["appointment_id"], "dock_id": data["dock_id"],
                "dock_code": data["dock_code"], "dock_status": data["dock_status"],
                "appointment_type": data["appointment_type"],
                "scheduled_start": data["scheduled_start"], "scheduled_end": data["scheduled_end"],
            },
            "next_actions": ["check_in_vehicle", "cancel_dock_appointment"],
        }
    except WmsCommandError as exc:
        return _error_result(exc)


async def cancel_dock_appointment(
    appointment_id: Annotated[str, Field(description="도크 예약 UUID")],
    expected_version: Annotated[int, Field(description="낙관적 동시성 버전 — get_dock_schedule로 얻은 예약 version")],
    reason: Annotated[Optional[str], Field(description="취소 사유")] = None,
    correlation_id: Annotated[Optional[str], Field(description="ProcessGPT process_instance_id 등 상관관계 ID")] = None,
    idempotency_key: Annotated[Optional[str], Field(description="재시도 시 동일 키 재사용. 미지정 시 새로 생성")] = None,
    dry_run: Annotated[bool, Field(description="true면 실제 반영 없이 예상 결과만 반환")] = False,
) -> dict:
    """아직 도킹하지 않은 예약(SCHEDULED 또는 CHECKED_IN)을 취소한다.

    취소하는 순간 그 시간창은 다시 예약 가능해진다 — 이중 예약 판정에서
    CANCELLED는 제외되기 때문이다. 이미 AT_DOCK/DEPARTED/CANCELLED인 예약은
    취소할 수 없고 INVALID이 반환된다(차량이 이미 도크에 붙어 있는 상태를
    취소로 되돌리지 않는다).
    """
    if dry_run:
        return {"result": "dry_run", "would_call": "wms_cancel_dock_appointment",
                "input": {"appointment_id": appointment_id}}
    try:
        data = _call_rpc("wms_cancel_dock_appointment", {
            "p_appointment_id": appointment_id, "p_actor_id": _agent_user_id(),
            "p_idempotency_key": idempotency_key or _new_key(),
            "p_expected_version": expected_version, "p_reason": reason,
            "p_correlation_id": correlation_id,
        })
        return {
            "result": "ok", "document_id": data["document_id"], "status": data["status"],
            "version": data["version"], "warnings": data["warnings"],
            "links": {"appointment_id": data["appointment_id"], "dock_id": data["dock_id"]},
            "next_actions": ["schedule_dock_appointment", "get_dock_schedule"],
        }
    except WmsCommandError as exc:
        return _error_result(exc)


async def check_in_vehicle(
    appointment_id: Annotated[str, Field(description="도크 예약 UUID")],
    expected_version: Annotated[int, Field(description="낙관적 동시성 버전")],
    carrier_name: Annotated[Optional[str], Field(description="운송사명 (예약 시 비워 뒀다면 여기서 기록)")] = None,
    vehicle_plate_no: Annotated[Optional[str], Field(description="차량 번호 (예: 12가3456)")] = None,
    correlation_id: Annotated[Optional[str], Field(description="ProcessGPT process_instance_id 등 상관관계 ID")] = None,
    idempotency_key: Annotated[Optional[str], Field(description="재시도 시 동일 키 재사용. 미지정 시 새로 생성")] = None,
    dry_run: Annotated[bool, Field(description="true면 실제 반영 없이 예상 결과만 반환")] = False,
) -> dict:
    """예약된 차량이 야드에 진입했음을 기록한다 (SCHEDULED -> CHECKED_IN).

    **도크 상태는 바뀌지 않는다** — 차량은 야드 안에 있지만 아직 도크에
    접안하지 않았다. 도크가 그 시점에 다른 차량으로 점유 중이면 경고
    DOCK_CURRENTLY_OCCUPIED가 함께 반환된다(체크인 자체는 성공한다).

    INBOUND_OPERATOR 또는 WMS_ADMIN만 호출할 수 있다 — 차량이 실제로 도착했다는
    관찰은 현장 사람의 것이므로 PROCESS_AGENT로 호출하면 FORBIDDEN이 반환된다
    (design.md D5).
    """
    if dry_run:
        return {"result": "dry_run", "would_call": "wms_check_in_vehicle",
                "input": {"appointment_id": appointment_id, "vehicle_plate_no": vehicle_plate_no}}
    try:
        data = _call_rpc("wms_check_in_vehicle", {
            "p_appointment_id": appointment_id, "p_actor_id": _agent_user_id(),
            "p_idempotency_key": idempotency_key or _new_key(),
            "p_expected_version": expected_version,
            "p_carrier_name": carrier_name, "p_vehicle_plate_no": vehicle_plate_no,
            "p_correlation_id": correlation_id,
        })
        return {
            "result": "ok", "document_id": data["document_id"], "status": data["status"],
            "version": data["version"], "warnings": data["warnings"],
            "links": {"appointment_id": data["appointment_id"], "dock_id": data["dock_id"],
                      "dock_status": data["dock_status"],
                      "vehicle_plate_no": data["vehicle_plate_no"]},
            "next_actions": ["dock_vehicle", "cancel_dock_appointment"],
        }
    except WmsCommandError as exc:
        return _error_result(exc)


async def dock_vehicle(
    appointment_id: Annotated[str, Field(description="도크 예약 UUID")],
    expected_version: Annotated[int, Field(description="낙관적 동시성 버전")],
    correlation_id: Annotated[Optional[str], Field(description="ProcessGPT process_instance_id 등 상관관계 ID")] = None,
    idempotency_key: Annotated[Optional[str], Field(description="재시도 시 동일 키 재사용. 미지정 시 새로 생성")] = None,
    dry_run: Annotated[bool, Field(description="true면 실제 반영 없이 예상 결과만 반환")] = False,
) -> dict:
    """체크인된 차량이 도크에 접안했음을 기록한다 (CHECKED_IN -> AT_DOCK).

    같은 트랜잭션에서 대상 도크가 OCCUPIED로 전환된다. 도크가 이미 OCCUPIED
    이거나 CLOSED면 INVALID이 반환되고 예약·도크 어느 쪽도 바뀌지 않는다.

    이 호출은 wms_register_arrival(입하 접수)과 직교한다 — 도킹이 입하 접수를
    자동으로 트리거하지 않고, 도킹 없이도 입하 접수는 성립한다(design.md D2).
    권장 운영 순서는 체크인 -> 도킹 -> register_arrival -> 출차이지만, DB가
    강제하는 제약은 아니다.

    INBOUND_OPERATOR 또는 WMS_ADMIN 전용이다.
    """
    if dry_run:
        return {"result": "dry_run", "would_call": "wms_dock_vehicle",
                "input": {"appointment_id": appointment_id}}
    try:
        data = _call_rpc("wms_dock_vehicle", {
            "p_appointment_id": appointment_id, "p_actor_id": _agent_user_id(),
            "p_idempotency_key": idempotency_key or _new_key(),
            "p_expected_version": expected_version, "p_correlation_id": correlation_id,
        })
        return {
            "result": "ok", "document_id": data["document_id"], "status": data["status"],
            "version": data["version"], "warnings": data["warnings"],
            "links": {"appointment_id": data["appointment_id"], "dock_id": data["dock_id"],
                      "dock_code": data["dock_code"], "dock_status": data["dock_status"],
                      "dock_version": data["dock_version"]},
            "next_actions": ["depart_vehicle", "register_arrival"],
        }
    except WmsCommandError as exc:
        return _error_result(exc)


async def depart_vehicle(
    appointment_id: Annotated[str, Field(description="도크 예약 UUID")],
    expected_version: Annotated[int, Field(description="낙관적 동시성 버전")],
    correlation_id: Annotated[Optional[str], Field(description="ProcessGPT process_instance_id 등 상관관계 ID")] = None,
    idempotency_key: Annotated[Optional[str], Field(description="재시도 시 동일 키 재사용. 미지정 시 새로 생성")] = None,
    dry_run: Annotated[bool, Field(description="true면 실제 반영 없이 예상 결과만 반환")] = False,
) -> dict:
    """하역을 마친 차량의 출차를 기록한다 (AT_DOCK -> DEPARTED).

    같은 트랜잭션에서 도크가 AVAILABLE로 되돌아간다. 단, 그 사이 관리자가
    도크를 CLOSED로 바꿨다면 도크는 CLOSED로 남고 경고
    DOCK_CLOSED_NOT_RELEASED가 반환된다 — 정비 결정을 출차가 덮어쓰지 않는다.

    예약이 AT_DOCK이 아니면 INVALID이 반환된다.
    INBOUND_OPERATOR 또는 WMS_ADMIN 전용이다.
    """
    if dry_run:
        return {"result": "dry_run", "would_call": "wms_depart_vehicle",
                "input": {"appointment_id": appointment_id}}
    try:
        data = _call_rpc("wms_depart_vehicle", {
            "p_appointment_id": appointment_id, "p_actor_id": _agent_user_id(),
            "p_idempotency_key": idempotency_key or _new_key(),
            "p_expected_version": expected_version, "p_correlation_id": correlation_id,
        })
        return {
            "result": "ok", "document_id": data["document_id"], "status": data["status"],
            "version": data["version"], "warnings": data["warnings"],
            "links": {"appointment_id": data["appointment_id"], "dock_id": data["dock_id"],
                      "dock_code": data["dock_code"], "dock_status": data["dock_status"],
                      "dock_version": data["dock_version"]},
            "next_actions": ["get_dock_schedule", "schedule_dock_appointment"],
        }
    except WmsCommandError as exc:
        return _error_result(exc)


async def get_dock_schedule(
    tenant_id: Annotated[str, Field(description="테넌트 UUID")],
    warehouse_id: Annotated[str, Field(description="창고 UUID")],
    from_ts: Annotated[Optional[str], Field(description="조회 시작 시각 (ISO 8601). 미지정이면 하한 없음")] = None,
    to_ts: Annotated[Optional[str], Field(description="조회 종료 시각 (ISO 8601). 미지정이면 상한 없음")] = None,
    dock_id: Annotated[Optional[str], Field(description="특정 도크만 조회할 경우 그 UUID")] = None,
    include_closed: Annotated[bool, Field(description="false면 CLOSED 도크를 결과에서 제외")] = True,
) -> dict:
    """창고의 도크별 예약 스케줄을 조회한다 (읽기 전용, 창고 스코프를 가진 모두).

    도크마다 현재 상태(AVAILABLE/OCCUPIED/CLOSED)와 version, 그리고 [from, to)
    구간과 겹치는 예약 목록을 시작시각 오름차순으로 돌려준다. 각 예약에는
    status, version, 차량/운송사, 체크인·도킹·출차 시각, 그리고 이중 예약
    판정에 포함되는지 여부(is_active)가 담긴다.

    예약을 만들기 전에 이 도구로 빈 슬롯을 확인하라 — 겹치는 시간창은
    schedule_dock_appointment에서 CONFLICT로 거부된다. 응답의 version 값들이
    곧 set_dock_status / cancel_dock_appointment / check_in_vehicle 등이
    요구하는 expected_version이다.
    """
    try:
        data = _call_rpc("wms_get_dock_schedule", {
            "p_tenant_id": tenant_id, "p_warehouse_id": warehouse_id,
            "p_from": from_ts, "p_to": to_ts, "p_dock_id": dock_id,
            "p_include_closed": include_closed,
        })
        return {"result": "ok", "document": data}
    except WmsCommandError as exc:
        return _error_result(exc)


# ============================================================
# Labor management
# (openspec/changes/add-labor-management, migration
#  supabase/migrations/20260803_labor_management.sql)
#
# Instrumentation, not orchestration. The three write tools record that a
# worker started / finished / abandoned a piece of work; the three read tools
# aggregate those intervals into productivity, a leaderboard and a headcount
# estimate.
#
# Two things make this area different from every one above it:
#
#   1. ACTOR SPOOFING IS REFUSED (design.md D2). Every other write RPC in this
#      repository accepts whatever p_actor_id it is handed; these three verify
#      it equals auth.uid(). The agent therefore records under its OWN
#      PROCESS_AGENT identity — it cannot log work "as" a human worker, and
#      there is no tool parameter to try. Agent-performed work shows up in the
#      aggregate with actor_role = 'PROCESS_AGENT', so human and machine
#      throughput are never silently mixed.
#
#   2. THE READS ARE PRIVACY-FILTERED, NOT PRIVACY-REFUSED (design.md D3). The
#      spec deliberated whether an agent should see across workers and landed
#      on "no": PROCESS_AGENT is not WAREHOUSE_MANAGER, so
#      get_labor_productivity returns scope='SELF' — the agent's own rows only.
#      That is a filtered success, not a FORBIDDEN, so an agent polling its own
#      throughput keeps working. get_labor_leaderboard is exposed for the same
#      reason but returns a single self row, which is why it is NOT in the
#      allowlist (docs/03-processgpt-integration.md) — there is nothing there
#      an agent can act on. forecast_labor_demand is manager/admin-only and
#      returns FORBIDDEN for the agent: belt-and-braces alongside the
#      allowlist, exactly like inspect/scrap.
# ============================================================


async def start_labor_activity(
    tenant_id: Annotated[str, Field(description="테넌트 UUID")],
    warehouse_id: Annotated[str, Field(description="창고 UUID")],
    activity_type: Annotated[str, Field(description="RECEIVING | QUALITY_INSPECTION | PUTAWAY | DISPOSITION | OTHER")],
    activity_label: Annotated[Optional[str], Field(description="사람이 읽는 설명. activity_type='OTHER'면 필수")] = None,
    linked_entity_type: Annotated[Optional[str], Field(description="느슨한 참조 종류 (예: 'receipt'). 하드 FK는 없다")] = None,
    linked_entity_id: Annotated[Optional[str], Field(description="느슨한 참조 UUID. linked_entity_type과 함께 주어야 한다")] = None,
    correlation_id: Annotated[Optional[str], Field(description="ProcessGPT process_instance_id 등 상관관계 ID")] = None,
    idempotency_key: Annotated[Optional[str], Field(description="재시도 시 동일 키 재사용. 미지정 시 새로 생성")] = None,
    dry_run: Annotated[bool, Field(description="true면 실제 반영 없이 예상 결과만 반환")] = False,
) -> dict:
    """업무 처리를 시작했음을 기록한다 (status=IN_PROGRESS, 시작 시각은 서버의 now()).

    이 도구는 기존 입고/검수/적치 RPC를 감싸는 **계측 계층**이다 — 호출해도
    receipt이나 재고 원장은 전혀 바뀌지 않는다. 권장 사용법은
    start_labor_activity → (register_arrival/receive/putaway 등 실제 업무 도구)
    → complete_labor_activity 순서로 감싸는 것이다.
    receive_with_labor_tracking이 그 참고 구현이다.

    **활동은 언제나 호출자 본인 명의로 기록된다**(design.md D2). 다른 사람의
    이름으로 기록할 수 있는 파라미터는 없다 — 생산성 수치 자체가 이 계약의
    산출물이라, 대리 기록을 열어 두면 리더보드와 집계가 오염된다. 에이전트가
    처리한 업무는 actor_role='PROCESS_AGENT'로 집계되어 사람 처리량과 섞이지
    않는다.

    activity_type='OTHER'로 시작하려면 activity_label이 반드시 있어야 한다
    (없으면 INVALID). 아직 이 저장소에 없는 업무(피킹·출고 등)를 계측할 때
    쓰는 탈출구다.
    """
    if dry_run:
        return {"result": "dry_run", "would_call": "wms_start_labor_activity", "input": {
            "tenant_id": tenant_id, "warehouse_id": warehouse_id,
            "activity_type": activity_type, "activity_label": activity_label,
        }}
    try:
        data = _call_rpc("wms_start_labor_activity", {
            "p_tenant_id": tenant_id, "p_warehouse_id": warehouse_id,
            "p_activity_type": activity_type, "p_actor_id": _agent_user_id(),
            "p_idempotency_key": idempotency_key or _new_key(),
            "p_activity_label": activity_label,
            "p_linked_entity_type": linked_entity_type,
            "p_linked_entity_id": linked_entity_id,
            "p_correlation_id": correlation_id,
        })
        return {
            "result": "ok", "document_id": data["document_id"], "status": data["status"],
            "version": data["version"], "warnings": data["warnings"],
            "links": {
                "activity_id": data["activity_id"], "actor_id": data["actor_id"],
                "actor_role": data["actor_role"], "activity_type": data["activity_type"],
                "started_at": data["started_at"],
            },
            "next_actions": ["complete_labor_activity", "cancel_labor_activity"],
        }
    except WmsCommandError as exc:
        return _error_result(exc)


async def complete_labor_activity(
    activity_id: Annotated[str, Field(description="인력 활동 UUID (start_labor_activity가 반환한 document_id)")],
    expected_version: Annotated[int, Field(description="낙관적 동시성 버전 — 시작 직후에는 1")],
    unit_count: Annotated[Optional[float], Field(description="처리한 수량 (선택). 생략하면 수요 추정의 표본이 되지 못한다")] = None,
    correlation_id: Annotated[Optional[str], Field(description="ProcessGPT process_instance_id 등 상관관계 ID")] = None,
    idempotency_key: Annotated[Optional[str], Field(description="재시도 시 동일 키 재사용. 미지정 시 새로 생성")] = None,
    dry_run: Annotated[bool, Field(description="true면 실제 반영 없이 예상 결과만 반환")] = False,
) -> dict:
    """진행 중(IN_PROGRESS)인 활동을 완료 처리한다 (status=COMPLETED).

    완료 시각이 서버의 now()로 찍히고 처리 시간(duration_seconds)이 자동
    계산되어 저장된다 — 호출자가 시간을 계산해 보낼 수 없다(그래서 위조할
    수도 없다).

    **unit_count를 채우는 것을 권장한다.** 인력 수요 추정
    (forecast_labor_demand)이 "시간당 처리량 = 처리 수량 ÷ 처리 시간"으로
    계산되기 때문에, 수량이 없는 활동만 쌓이면 그 역할은 추정 자체가
    불가능해진다(INVALID). 수량 없이 완료하면 경고
    NO_UNIT_COUNT_RECORDED가 반환된다.

    이미 COMPLETED/CANCELLED인 활동은 INVALID, version이 어긋나면 CONFLICT다.
    본인이 시작한 활동만 완료할 수 있다(WMS_ADMIN 예외).
    """
    if dry_run:
        return {"result": "dry_run", "would_call": "wms_complete_labor_activity", "input": {
            "activity_id": activity_id, "unit_count": unit_count,
        }}
    try:
        data = _call_rpc("wms_complete_labor_activity", {
            "p_activity_id": activity_id, "p_actor_id": _agent_user_id(),
            "p_idempotency_key": idempotency_key or _new_key(),
            "p_expected_version": expected_version, "p_unit_count": unit_count,
            "p_correlation_id": correlation_id,
        })
        return {
            "result": "ok", "document_id": data["document_id"], "status": data["status"],
            "version": data["version"], "warnings": data["warnings"],
            "links": {
                "activity_id": data["activity_id"], "actor_id": data["actor_id"],
                "actor_role": data["actor_role"], "activity_type": data["activity_type"],
                "started_at": data["started_at"], "completed_at": data["completed_at"],
                "duration_seconds": data["duration_seconds"], "unit_count": data["unit_count"],
            },
            "next_actions": ["start_labor_activity", "get_labor_productivity"],
        }
    except WmsCommandError as exc:
        return _error_result(exc)


async def cancel_labor_activity(
    activity_id: Annotated[str, Field(description="인력 활동 UUID")],
    expected_version: Annotated[int, Field(description="낙관적 동시성 버전")],
    reason: Annotated[Optional[str], Field(description="중단 사유 (예: '다른 작업으로 재배정됨')")] = None,
    correlation_id: Annotated[Optional[str], Field(description="ProcessGPT process_instance_id 등 상관관계 ID")] = None,
    idempotency_key: Annotated[Optional[str], Field(description="재시도 시 동일 키 재사용. 미지정 시 새로 생성")] = None,
    dry_run: Annotated[bool, Field(description="true면 실제 반영 없이 예상 결과만 반환")] = False,
) -> dict:
    """잘못 시작했거나 중단된 활동을 취소한다 (IN_PROGRESS -> CANCELLED).

    취소된 활동은 **모든 생산성 수치에서 완전히 빠진다** — 완료 건수, 평균/합계
    처리 시간, 리더보드, 수요 추정 어디에도 잡히지 않는다. 잘못 열어 둔
    활동을 그냥 완료 처리하면 그 시간이 통계를 오염시키므로, 실제로 하지 않은
    일은 반드시 이 도구로 닫아야 한다.

    이미 완료·취소된 활동은 INVALID다.
    """
    if dry_run:
        return {"result": "dry_run", "would_call": "wms_cancel_labor_activity",
                "input": {"activity_id": activity_id, "reason": reason}}
    try:
        data = _call_rpc("wms_cancel_labor_activity", {
            "p_activity_id": activity_id, "p_actor_id": _agent_user_id(),
            "p_idempotency_key": idempotency_key or _new_key(),
            "p_expected_version": expected_version, "p_reason": reason,
            "p_correlation_id": correlation_id,
        })
        return {
            "result": "ok", "document_id": data["document_id"], "status": data["status"],
            "version": data["version"], "warnings": data["warnings"],
            "links": {"activity_id": data["activity_id"], "actor_id": data["actor_id"],
                      "reason": data["reason"]},
            "next_actions": ["start_labor_activity"],
        }
    except WmsCommandError as exc:
        return _error_result(exc)


async def get_labor_productivity(
    tenant_id: Annotated[str, Field(description="테넌트 UUID")],
    warehouse_id: Annotated[str, Field(description="창고 UUID")],
    period_start: Annotated[str, Field(description="집계 시작 시각 (ISO 8601, 포함)")],
    period_end: Annotated[str, Field(description="집계 종료 시각 (ISO 8601, 미포함). period_start보다 뒤여야 한다")],
    actor_id: Annotated[Optional[str], Field(description="특정 작업자만 조회 (관리자 전용 필터). 비관리자가 지정하면 무시되고 본인으로 대체된다")] = None,
    role: Annotated[Optional[str], Field(description="특정 역할만 조회 (예: INBOUND_OPERATOR)")] = None,
) -> dict:
    """완료된 인력 활동을 작업자별·역할별·일자별·활동유형별로 집계 조회한다 (읽기 전용).

    각 행에 완료 건수, 평균/합계 처리 시간(초), 합계 처리 수량이 담기고,
    `totals`에 기간 전체 합계가 함께 온다. 취소된 활동과 아직 진행 중인
    활동은 어느 숫자에도 포함되지 않는다.

    **결과 범위는 호출자의 역할이 결정한다**(design.md D3). 응답의 `scope`를
    반드시 확인하라:
      - `WAREHOUSE`: 호출자가 WAREHOUSE_MANAGER/WMS_ADMIN이다. 창고 안 모든
        작업자가 보인다.
      - `SELF`: 그 외 역할(PROCESS_AGENT 포함)이다. **본인 행만** 온다.
        actor_id 파라미터로 다른 사람을 지정해도 오류가 아니라 조용히
        본인으로 대체된다(notes에 SELF_SCOPE_ONLY).

    즉 에이전트가 이 도구로 얻을 수 있는 것은 자기 자신의 처리량뿐이다 —
    "동료 A가 느리다"를 판단하는 데는 쓸 수 없고, 그 판단은 사람 관리자의
    몫으로 남겨 두는 것이 이 계약의 설계다.
    """
    try:
        data = _call_rpc("wms_get_labor_productivity", {
            "p_tenant_id": tenant_id, "p_warehouse_id": warehouse_id,
            "p_period_start": period_start, "p_period_end": period_end,
            "p_actor_id": actor_id, "p_role": role,
        })
        return {"result": "ok", "document": data}
    except WmsCommandError as exc:
        return _error_result(exc)


async def get_labor_leaderboard(
    tenant_id: Annotated[str, Field(description="테넌트 UUID")],
    warehouse_id: Annotated[str, Field(description="창고 UUID")],
    period_start: Annotated[str, Field(description="집계 시작 시각 (ISO 8601, 포함)")],
    period_end: Annotated[str, Field(description="집계 종료 시각 (ISO 8601, 미포함)")],
    metric: Annotated[str, Field(description="completed_count | total_unit_count | avg_duration_seconds")] = "completed_count",
) -> dict:
    """지정한 지표 기준으로 작업자 순위를 조회한다 (읽기 전용, 게이미피케이션 경량 대응).

    `completed_count`와 `total_unit_count`는 내림차순, `avg_duration_seconds`는
    오름차순(빠를수록 상위)으로 정렬된다. 포인트·배지·레벨 같은 게임 메커니즘은
    계산하지 않는다 — 순위표가 전부다.

    get_labor_productivity와 같은 프라이버시 규칙이 적용된다. 비관리자
    (PROCESS_AGENT 포함)가 호출하면 오류 없이 성공하지만 결과는 **본인 행 하나
    뿐**이고, 그 행의 `rank`는 null이다 — 가짜 1위를 돌려주면 거짓말이고 실제
    전체 순위를 돌려주면 "내 앞에 몇 명 있는지"가 새기 때문이다
    (notes: SELF_SCOPE_RANK_WITHHELD). 그래서 이 도구는 에이전트 허용 목록에
    넣지 않는다 — 에이전트가 얻을 수 있는 정보가 사실상 없다.
    """
    try:
        data = _call_rpc("wms_get_labor_leaderboard", {
            "p_tenant_id": tenant_id, "p_warehouse_id": warehouse_id,
            "p_period_start": period_start, "p_period_end": period_end,
            "p_metric": metric,
        })
        return {"result": "ok", "document": data}
    except WmsCommandError as exc:
        return _error_result(exc)


async def forecast_labor_demand(
    tenant_id: Annotated[str, Field(description="테넌트 UUID")],
    warehouse_id: Annotated[str, Field(description="창고 UUID")],
    role: Annotated[str, Field(description="추정 대상 역할 (예: INBOUND_OPERATOR) — 활동 시작 시점의 역할 스냅샷과 대조된다")],
    expected_volume: Annotated[float, Field(description="처리해야 할 예상 물량. unit_count와 같은 단위여야 한다")],
    trailing_days: Annotated[int, Field(description="평균 처리량을 낼 트레일링 기간(일)")] = 7,
    shift_hours: Annotated[float, Field(description="1인 1교대 표준 근무시간")] = 8,
) -> dict:
    """예상 물량을 처리하는 데 필요한 인원 수를 추정한다 (읽기 전용, 관리자 전용).

    **이것은 머신러닝 예측이 아니라 나눗셈이다.** 계산식은 응답의 `basis`에
    전부 드러나 있다:

        시간당 처리량 = 트레일링 기간의 합계 unit_count ÷ 합계 처리 시간(시간)
        1인 1교대 처리량 = 시간당 처리량 x shift_hours
        recommended_headcount = ceil(expected_volume ÷ 1인 1교대 처리량)

    계절성·추세·이상치 보정은 전혀 없고, 응답의 `method`는 항상
    'SIMPLE_RATIO'다. 이 숫자를 인력 계획의 출발점으로는 써도 근거로 인용할
    때는 반드시 표본 크기(basis.sample_count)와 함께 제시하라 — 표본이 3건
    미만이면 SMALL_SAMPLE 경고가 함께 온다.

    트레일링 기간에 그 역할의 완료된 활동이 하나도 없거나, 있어도 unit_count가
    전혀 기록되지 않았다면 INVALID을 반환한다 — 0으로 나누거나 근거 없는
    숫자를 조용히 만들어내지 않는다.

    WAREHOUSE_MANAGER 또는 WMS_ADMIN만 호출할 수 있다(design.md D4). 인력
    계획은 관리 판단이므로 PROCESS_AGENT로 호출하면 FORBIDDEN이 반환되고,
    같은 이유로 이 도구는 에이전트 허용 목록에서도 제외한다.
    """
    try:
        data = _call_rpc("wms_forecast_labor_demand", {
            "p_tenant_id": tenant_id, "p_warehouse_id": warehouse_id,
            "p_role": role, "p_expected_volume": expected_volume,
            "p_trailing_days": trailing_days, "p_shift_hours": shift_hours,
        })
        return {"result": "ok", "document": data}
    except WmsCommandError as exc:
        return _error_result(exc)


async def receive_with_labor_tracking(
    tenant_id: Annotated[str, Field(description="테넌트 UUID")],
    warehouse_id: Annotated[str, Field(description="창고 UUID")],
    receipt_id: Annotated[str, Field(description="Receipt UUID")],
    qty: Annotated[float, Field(description="실제 입고 수량")],
    expected_version: Annotated[int, Field(description="receipt의 낙관적 동시성 버전")],
    correlation_id: Annotated[Optional[str], Field(description="ProcessGPT process_instance_id 등 상관관계 ID")] = None,
    idempotency_key: Annotated[Optional[str], Field(description="wms_receive 재시도 시 동일 키 재사용")] = None,
    dry_run: Annotated[bool, Field(description="true면 실제 반영 없이 예상 결과만 반환")] = False,
) -> dict:
    """`receive`와 같은 입고 등록을 하되, 앞뒤를 인력 활동 계측으로 감싼다.

    design.md D1이 말하는 계측 패턴의 **참고 구현 1개**다. 순서는

        start_labor_activity(RECEIVING, linked_entity=('receipt', receipt_id))
          -> wms_receive(...)            <- 기존 RPC를 그대로 호출, 수정 없음
          -> complete_labor_activity(unit_count = 입고 수량)

    이고, 기존 `receive` 도구와 `wms_receive` RPC의 시그니처·동작은 전혀 바뀌지
    않았다. 계측은 나란히 얹히는 별개의 계층이라, 계측 없이 `receive`만 호출해도
    입고는 그대로 성립한다(계약이 강제하지 않는다).

    입고 자체가 실패하면 열어 둔 활동은 **완료가 아니라 취소**된다 — 하지 않은
    일이 처리 시간 통계에 남지 않게 하기 위함이다. 계측 호출이 실패하더라도
    입고는 성공한 그대로 두고, 응답의 warnings로만 알린다: 계측 실패가 원장을
    되돌리는 일은 없어야 한다.

    나머지 도구(register_arrival / inspect / apply_disposition /
    create_putaway_tasks)에 대한 같은 래퍼는 후속 작업으로 남겨 두었다
    (tasks.md 7.3).
    """
    if dry_run:
        return {"result": "dry_run", "would_call": "wms_start_labor_activity + wms_receive + wms_complete_labor_activity",
                "input": {"receipt_id": receipt_id, "qty": qty}}

    warnings: list[str] = []
    activity_id: Optional[str] = None
    activity_version: Optional[int] = None

    # 1. open the interval. A failure here must NOT block the actual work.
    try:
        started = _call_rpc("wms_start_labor_activity", {
            "p_tenant_id": tenant_id, "p_warehouse_id": warehouse_id,
            "p_activity_type": "RECEIVING", "p_actor_id": _agent_user_id(),
            "p_idempotency_key": _new_key(),
            "p_activity_label": None,
            "p_linked_entity_type": "receipt", "p_linked_entity_id": receipt_id,
            "p_correlation_id": correlation_id,
        })
        activity_id = started["activity_id"]
        activity_version = started["version"]
    except WmsCommandError as exc:
        warnings.append(f"LABOR_TRACKING_START_FAILED: {exc}")

    # 2. the real work — the untouched core RPC.
    try:
        data = _call_rpc("wms_receive", {
            "p_receipt_id": receipt_id, "p_qty": qty, "p_actor_id": _agent_user_id(),
            "p_idempotency_key": idempotency_key or _new_key(),
            "p_expected_version": expected_version,
        })
    except WmsCommandError as exc:
        if activity_id is not None:
            try:
                _call_rpc("wms_cancel_labor_activity", {
                    "p_activity_id": activity_id, "p_actor_id": _agent_user_id(),
                    "p_idempotency_key": _new_key(), "p_expected_version": activity_version,
                    "p_reason": f"입고 실패로 계측 취소: {exc}",
                    "p_correlation_id": correlation_id,
                })
            except WmsCommandError:
                logger.warning("could not cancel labor activity %s after a failed receive", activity_id)
        return _error_result(exc)

    # 3. close the interval with the quantity actually received.
    duration_seconds = None
    if activity_id is not None:
        try:
            completed = _call_rpc("wms_complete_labor_activity", {
                "p_activity_id": activity_id, "p_actor_id": _agent_user_id(),
                "p_idempotency_key": _new_key(), "p_expected_version": activity_version,
                "p_unit_count": qty, "p_correlation_id": correlation_id,
            })
            duration_seconds = completed["duration_seconds"]
        except WmsCommandError as exc:
            warnings.append(f"LABOR_TRACKING_COMPLETE_FAILED: {exc}")

    return {
        "result": "ok", "document_id": data["receipt_id"], "status": data["status"],
        "version": data["version"], "received_qty": data["received_qty"],
        "warnings": warnings,
        "links": {"labor_activity_id": activity_id, "duration_seconds": duration_seconds},
        "next_actions": ["inspect"],
    }


# ============================================================
# Slotting optimization (openspec change add-slotting-optimization,
# migration 20260804_slotting_optimization.sql)
#
# Ten tools. The role boundary inside this block is the point of the contract
# and it is NOT uniform:
#
#   PROCESS_AGENT may     — compute_sku_velocity, generate_slotting_recommendations
#                           (pure analysis over the ledger; nothing moves)
#   PROCESS_AGENT may NOT — review / apply (a decision to move physical stock,
#                           WMS_ADMIN or WAREHOUSE_MANAGER only, design.md D6)
#                         — the location registry and the class policies
#                           (master data, same line register_equipment and
#                           register_dock already drew)
#
# The four it may not call are excluded from the agent allowlist in
# docs/03-processgpt-integration.md, and the RPCs refuse them anyway.
# ============================================================


async def register_storage_location(
    tenant_id: Annotated[str, Field(description="테넌트 UUID")],
    warehouse_id: Annotated[str, Field(description="창고 UUID")],
    zone_code: Annotated[str, Field(description="구역 라벨 (예: PACK_ADJACENT, BULK_STORAGE). 계층이 아니라 자유 텍스트 라벨이다")],
    location_code: Annotated[str, Field(description="창고 안에서 고유한 위치 코드 (예: A-01-01)")],
    accessibility_rank: Annotated[int, Field(description="접근성 순위. 양의 정수이고 **낮을수록 접근성이 좋다**(1 = 포장/출하 바로 옆)")],
    capacity_qty: Annotated[Optional[float], Field(description="참고용 수용량. 기록만 되고 어떤 검증에도 쓰이지 않는다")] = None,
    correlation_id: Annotated[Optional[str], Field(description="ProcessGPT process_instance_id 등 상관관계 ID")] = None,
    idempotency_key: Annotated[Optional[str], Field(description="재시도 시 동일 키 재사용. 미지정 시 새로 생성")] = None,
    dry_run: Annotated[bool, Field(description="true면 실제 반영 없이 예상 결과만 반환")] = False,
) -> dict:
    """보관 위치를 레지스트리에 등록한다 (등록 즉시 ACTIVE).

    이 레지스트리는 **평평하다** — 통로·선반·빈 계층이 아니고, 용량 관리 규칙도,
    위험물/온도대 같은 위치-품목 적합성 규칙도 없다. 가지고 있는 것은 구역 라벨,
    고유 코드, 그리고 정수 하나(`accessibility_rank`)뿐이다.

    **accessibility_rank는 사람이 매기는 값이다.** 시스템이 창고 도면이나 실제
    동선을 계산해 산출하지 않으며, 잘못 매긴 순위는 그대로 잘못된 재배치 추천이
    된다. 순위의 절대값에는 의미가 없고 같은 창고 안에서의 상대 비교만 의미가
    있다 — 그래서 등급별 목표 순위도 창고별 정책으로 따로 정한다.

    `capacity_qty`를 넣으면 응답에 CAPACITY_NOT_ENFORCED 경고가 함께 온다. 적어
    두는 것은 자유지만 이 계약의 어떤 로직도 그 값을 읽지 않는다.

    WMS_ADMIN / WAREHOUSE_MANAGER 전용 (마스터데이터 성격). 같은 창고에 같은
    location_code를 다시 등록하면 INVALID다.
    """
    if dry_run:
        return {"result": "dry_run", "would_call": "wms_register_storage_location", "input": {
            "tenant_id": tenant_id, "warehouse_id": warehouse_id, "zone_code": zone_code,
            "location_code": location_code, "accessibility_rank": accessibility_rank,
        }}
    try:
        data = _call_rpc("wms_register_storage_location", {
            "p_tenant_id": tenant_id, "p_warehouse_id": warehouse_id,
            "p_zone_code": zone_code, "p_location_code": location_code,
            "p_accessibility_rank": accessibility_rank,
            "p_actor_id": _agent_user_id(),
            "p_idempotency_key": idempotency_key or _new_key(),
            "p_capacity_qty": capacity_qty, "p_correlation_id": correlation_id,
        })
        return {
            "result": "ok", "document_id": data["document_id"], "status": data["status"],
            "version": data["version"], "warnings": data["warnings"],
            "links": {"location_id": data["location_id"], "location_code": data["location_code"],
                      "accessibility_rank": data["accessibility_rank"]},
            "next_actions": data["next_actions"],
        }
    except WmsCommandError as exc:
        return _error_result(exc)


async def set_storage_location_status(
    location_id: Annotated[str, Field(description="보관 위치 UUID")],
    status: Annotated[str, Field(description="ACTIVE 또는 INACTIVE")],
    expected_version: Annotated[int, Field(description="위치의 낙관적 동시성 버전")],
    correlation_id: Annotated[Optional[str], Field(description="ProcessGPT process_instance_id 등 상관관계 ID")] = None,
    idempotency_key: Annotated[Optional[str], Field(description="재시도 시 동일 키 재사용")] = None,
    dry_run: Annotated[bool, Field(description="true면 실제 반영 없이 예상 결과만 반환")] = False,
) -> dict:
    """보관 위치를 ACTIVE / INACTIVE 사이로 전환한다.

    INACTIVE 위치는 **앞으로** 새 배정이나 재배치 추천의 대상이 되지 못한다.
    다만 이미 그 자리에 배정된 SKU를 쫓아내지는 않는다 — 배정 레코드는 "지금
    실물이 저기 있다"는 사실 진술이고, 위치를 비활성화한다고 실물이 움직이지는
    않기 때문이다. 그런 SKU가 남아 있으면 응답에 STILL_ASSIGNED_SKUS 경고가 그
    건수와 함께 온다.

    이미 승인된 추천의 대상 위치를 비활성화하면 그 추천은 적용 단계에서
    INVALID로 거부된다(적용 시점에 다시 확인한다).

    WMS_ADMIN / WAREHOUSE_MANAGER 전용. 이미 그 상태이면 INVALID다.
    """
    if dry_run:
        return {"result": "dry_run", "would_call": "wms_set_storage_location_status",
                "input": {"location_id": location_id, "status": status}}
    try:
        data = _call_rpc("wms_set_storage_location_status", {
            "p_location_id": location_id, "p_status": status,
            "p_actor_id": _agent_user_id(),
            "p_idempotency_key": idempotency_key or _new_key(),
            "p_expected_version": expected_version, "p_correlation_id": correlation_id,
        })
        return {
            "result": "ok", "document_id": data["document_id"], "status": data["status"],
            "version": data["version"], "warnings": data["warnings"],
            "links": {"location_id": data["location_id"], "location_code": data["location_code"]},
            "next_actions": data["next_actions"],
        }
    except WmsCommandError as exc:
        return _error_result(exc)


async def assign_sku_location(
    tenant_id: Annotated[str, Field(description="테넌트 UUID")],
    warehouse_id: Annotated[str, Field(description="창고 UUID")],
    product_id: Annotated[str, Field(description="상품 UUID")],
    location_id: Annotated[str, Field(description="보관 위치 UUID. ACTIVE 상태여야 한다")],
    correlation_id: Annotated[Optional[str], Field(description="ProcessGPT process_instance_id 등 상관관계 ID")] = None,
    idempotency_key: Annotated[Optional[str], Field(description="재시도 시 동일 키 재사용")] = None,
    dry_run: Annotated[bool, Field(description="true면 실제 반영 없이 예상 결과만 반환")] = False,
) -> dict:
    """"이 SKU는 지금 이 위치에 있다"를 최초로 선언한다.

    **이 값은 원장에서 유도되지 않는다.** `wms.stock_ledger_entries`에는 위치
    축이 아예 없어서, "이 SKU가 지금 어디 있는가"는 조회로 계산할 방법이 없다 —
    사람이 선언하는 수밖에 없다. 그래서 응답에는 항상
    DECLARATION_NOT_RECONCILED_WITH_PUTAWAY 경고가 붙는다: 이 선언과 실제 적치를
    맞춰 보는 장치가 이 계약에는 없고, 선언만 하고 실물을 옮기지 않아도 시스템은
    그 어긋남을 감지하지 못한다(실사/순환재고 영역의 몫).

    창고 안에서 SKU 하나는 활성 배정을 하나만 가진다. 이미 있는데 또 선언하면
    INVALID이고, 위치를 바꾸려면 reassign_sku_location을 쓴다.

    WMS_ADMIN / WAREHOUSE_MANAGER / INBOUND_OPERATOR가 호출할 수 있다.
    """
    if dry_run:
        return {"result": "dry_run", "would_call": "wms_assign_sku_location",
                "input": {"product_id": product_id, "location_id": location_id}}
    try:
        data = _call_rpc("wms_assign_sku_location", {
            "p_tenant_id": tenant_id, "p_warehouse_id": warehouse_id,
            "p_product_id": product_id, "p_location_id": location_id,
            "p_actor_id": _agent_user_id(),
            "p_idempotency_key": idempotency_key or _new_key(),
            "p_correlation_id": correlation_id,
        })
        return {
            "result": "ok", "document_id": data["document_id"], "status": data["status"],
            "version": data["version"], "warnings": data["warnings"],
            "links": {"assignment_id": data["assignment_id"], "product_id": data["product_id"],
                      "location_id": data["location_id"], "location_code": data["location_code"],
                      "accessibility_rank": data["accessibility_rank"]},
            "next_actions": data["next_actions"],
        }
    except WmsCommandError as exc:
        return _error_result(exc)


async def reassign_sku_location(
    assignment_id: Annotated[str, Field(description="SKU-위치 배정 UUID")],
    location_id: Annotated[str, Field(description="옮겨 갈 보관 위치 UUID. ACTIVE 상태여야 한다")],
    expected_version: Annotated[int, Field(description="배정의 낙관적 동시성 버전")],
    correlation_id: Annotated[Optional[str], Field(description="ProcessGPT process_instance_id 등 상관관계 ID")] = None,
    idempotency_key: Annotated[Optional[str], Field(description="재시도 시 동일 키 재사용")] = None,
    dry_run: Annotated[bool, Field(description="true면 실제 반영 없이 예상 결과만 반환")] = False,
) -> dict:
    """SKU의 선언된 위치를 손으로 바꾼다.

    바뀐 배정은 언제나 `assigned_reason='MANUAL_DECLARATION'`이 되고, 예전에
    추천 적용으로 생긴 배정이었더라도 `source_recommendation_id`는 지워진다 —
    사람이 손으로 옮긴 결과를 계속 그 추천의 성과로 남겨 두면 감사 기록이
    거짓이 되기 때문이다.

    이전 위치는 `wms.audit_events`의 before에 남는다. 배정 이력 테이블은 따로
    없고, 감사 로그가 곧 이력이다.

    WMS_ADMIN / WAREHOUSE_MANAGER / INBOUND_OPERATOR. 같은 위치로 재배정하면
    INVALID, 버전이 어긋나면 CONFLICT다.
    """
    if dry_run:
        return {"result": "dry_run", "would_call": "wms_reassign_sku_location",
                "input": {"assignment_id": assignment_id, "location_id": location_id}}
    try:
        data = _call_rpc("wms_reassign_sku_location", {
            "p_assignment_id": assignment_id, "p_location_id": location_id,
            "p_actor_id": _agent_user_id(),
            "p_idempotency_key": idempotency_key or _new_key(),
            "p_expected_version": expected_version, "p_correlation_id": correlation_id,
        })
        return {
            "result": "ok", "document_id": data["document_id"], "status": data["status"],
            "version": data["version"], "warnings": data["warnings"],
            "links": {"assignment_id": data["assignment_id"], "product_id": data["product_id"],
                      "location_id": data["location_id"], "location_code": data["location_code"],
                      "accessibility_rank": data["accessibility_rank"]},
            "next_actions": data["next_actions"],
        }
    except WmsCommandError as exc:
        return _error_result(exc)


async def register_slotting_class_policy(
    tenant_id: Annotated[str, Field(description="테넌트 UUID")],
    warehouse_id: Annotated[str, Field(description="창고 UUID")],
    velocity_class: Annotated[str, Field(description="속도 등급: A, B 또는 C")],
    max_accessibility_rank: Annotated[int, Field(description="이 등급 SKU가 있어야 할 접근성 순위 상한(이하). 양의 정수")],
    correlation_id: Annotated[Optional[str], Field(description="ProcessGPT process_instance_id 등 상관관계 ID")] = None,
    idempotency_key: Annotated[Optional[str], Field(description="재시도 시 동일 키 재사용")] = None,
    dry_run: Annotated[bool, Field(description="true면 실제 반영 없이 예상 결과만 반환")] = False,
) -> dict:
    """"A등급 SKU는 접근성 순위 N 이하에 있어야 한다"는 창고별 정책을 등록한다.

    **시스템 기본값은 없다.** 위치가 5개뿐인 창고와 500개인 창고에서 "순위 5
    이하"가 뜻하는 바가 전혀 다르기 때문에, 모든 창고에 같은 기본 임계값을
    적용하면 어떤 창고에서는 모든 위치가 A등급 자격을 얻어 추천이 무의미해진다.
    정책이 없는 등급은 추천 생성에서 **조용히 건너뛰는 대신 그 사실이
    `skipped_no_policy_classes`로 응답에 드러난다**.

    상한을 만족하는 ACTIVE 위치가 하나도 없으면 NO_QUALIFYING_LOCATION 경고가
    온다 — 등록은 되지만 그 등급에 대한 추천은 만들어지지 않는다.

    WMS_ADMIN / WAREHOUSE_MANAGER 전용. 같은 (창고, 등급)에 두 번 등록하면
    INVALID이고, 값을 바꾸려면 update_slotting_class_policy를 쓴다.
    """
    if dry_run:
        return {"result": "dry_run", "would_call": "wms_register_slotting_class_policy",
                "input": {"velocity_class": velocity_class,
                          "max_accessibility_rank": max_accessibility_rank}}
    try:
        data = _call_rpc("wms_register_slotting_class_policy", {
            "p_tenant_id": tenant_id, "p_warehouse_id": warehouse_id,
            "p_velocity_class": velocity_class,
            "p_max_accessibility_rank": max_accessibility_rank,
            "p_actor_id": _agent_user_id(),
            "p_idempotency_key": idempotency_key or _new_key(),
            "p_correlation_id": correlation_id,
        })
        return {
            "result": "ok", "document_id": data["document_id"], "status": data["status"],
            "version": data["version"], "warnings": data["warnings"],
            "links": {"policy_id": data["policy_id"], "velocity_class": data["velocity_class"],
                      "max_accessibility_rank": data["max_accessibility_rank"],
                      "qualifying_location_count": data["qualifying_location_count"]},
            "next_actions": data["next_actions"],
        }
    except WmsCommandError as exc:
        return _error_result(exc)


async def update_slotting_class_policy(
    policy_id: Annotated[str, Field(description="등급 정책 UUID")],
    max_accessibility_rank: Annotated[int, Field(description="새 접근성 순위 상한. 양의 정수")],
    expected_version: Annotated[int, Field(description="정책의 낙관적 동시성 버전")],
    correlation_id: Annotated[Optional[str], Field(description="ProcessGPT process_instance_id 등 상관관계 ID")] = None,
    idempotency_key: Annotated[Optional[str], Field(description="재시도 시 동일 키 재사용")] = None,
    dry_run: Annotated[bool, Field(description="true면 실제 반영 없이 예상 결과만 반환")] = False,
) -> dict:
    """등급별 목표 접근성 상한을 바꾼다.

    **이미 만들어진 추천은 바뀌지 않는다.** 정책을 고쳐도 기존 PENDING 추천은
    옛 상한으로 만들어진 그대로 남는다 — 응답의 REGENERATE_TO_APPLY 경고가 그
    뜻이다. 새 상한을 반영하려면 같은 속도 스냅샷 배치로
    generate_slotting_recommendations를 다시 부르면 된다(원장을 다시 훑을 필요는
    없다 — 속도 계산과 추천 생성을 나눠 둔 이유가 바로 이 정책 튜닝 반복이다).

    WMS_ADMIN / WAREHOUSE_MANAGER 전용.
    """
    if dry_run:
        return {"result": "dry_run", "would_call": "wms_update_slotting_class_policy",
                "input": {"policy_id": policy_id,
                          "max_accessibility_rank": max_accessibility_rank}}
    try:
        data = _call_rpc("wms_update_slotting_class_policy", {
            "p_policy_id": policy_id,
            "p_max_accessibility_rank": max_accessibility_rank,
            "p_actor_id": _agent_user_id(),
            "p_idempotency_key": idempotency_key or _new_key(),
            "p_expected_version": expected_version, "p_correlation_id": correlation_id,
        })
        return {
            "result": "ok", "document_id": data["document_id"], "status": data["status"],
            "version": data["version"], "warnings": data["warnings"],
            "links": {"policy_id": data["policy_id"], "velocity_class": data["velocity_class"],
                      "max_accessibility_rank": data["max_accessibility_rank"],
                      "qualifying_location_count": data["qualifying_location_count"]},
            "next_actions": data["next_actions"],
        }
    except WmsCommandError as exc:
        return _error_result(exc)


async def compute_sku_velocity(
    tenant_id: Annotated[str, Field(description="테넌트 UUID")],
    warehouse_id: Annotated[str, Field(description="창고 UUID")],
    window_start: Annotated[str, Field(description="관찰 윈도우 시작일 (YYYY-MM-DD, 포함)")],
    window_end: Annotated[str, Field(description="관찰 윈도우 종료일 (YYYY-MM-DD, 그날 하루를 포함). window_start보다 뒤여야 한다")],
    correlation_id: Annotated[Optional[str], Field(description="ProcessGPT process_instance_id 등 상관관계 ID")] = None,
    idempotency_key: Annotated[Optional[str], Field(description="재시도 시 동일 키 재사용")] = None,
    dry_run: Annotated[bool, Field(description="true면 실제 반영 없이 예상 결과만 반환")] = False,
) -> dict:
    """SKU별 출하 속도를 계산하고 ABC 등급 스냅샷 배치를 만든다 (분석, PROCESS_AGENT 가능).

    **응답의 `skipped_no_data_count`를 반드시 읽어라.** 이 계약은 신호가 없는
    SKU에 임의의 등급을 매기지 않는다 — 스냅샷 행 자체를 만들지 않고, 몇 개가
    그렇게 빠졌는지만 알려 준다. `candidate_product_count = included_product_count
    + skipped_no_data_count`가 항상 성립하므로, 빈 결과를 "다 저빈도 SKU였다"로
    오해할 여지가 없어야 한다.

    **오늘 이 저장소에서는 거의 언제나 included = 0이 나온다.** 신호로 삼는 것은
    `wms.stock_ledger_entries`에서 `status='AVAILABLE'`이면서 `qty_delta < 0`인
    행뿐인데, 이 저장소에 구현된 어떤 RPC도 그런 행을 쓰지 않기 때문이다 —
    입고는 QC에 +, 처분은 QC에 -와 AVAILABLE/SCRAP에 +를 쓸 뿐이고, area5의
    `wms.outbound_orders`는 COMPLETED까지 가더라도 원장을 건드리지 않는다.
    이것은 버그가 아니라 이 저장소의 현재 범위다. 나중에 출고 차감 RPC가
    생기는 순간 이 계약은 아무것도 고치지 않아도 실제 신호를 내기 시작한다.
    그때까지는 status가 NO_SIGNAL로 오고 NO_CONSUMPTION_SIGNAL_IN_WINDOW
    경고가 붙는다.

    등급은 전통적 ABC다 — 소비 수량 내림차순으로 정렬해 누적 비중 80%까지 A,
    95%까지 B, 나머지 C(경계값 포함). 컷오프는 이 스펙에서 상수로 고정돼 있다.
    입고·QC·폐기 이력은 섞지 않는다: 섞으면 "출하 빈도"라는 말의 뜻이 바뀐다.

    응답의 `batch_id`를 generate_slotting_recommendations에 그대로 넘긴다. 같은
    배치로 정책을 바꿔 가며 몇 번이든 다시 추천을 만들어 볼 수 있다.
    """
    if dry_run:
        return {"result": "dry_run", "would_call": "wms_compute_sku_velocity",
                "input": {"warehouse_id": warehouse_id,
                          "window_start": window_start, "window_end": window_end}}
    try:
        data = _call_rpc("wms_compute_sku_velocity", {
            "p_tenant_id": tenant_id, "p_warehouse_id": warehouse_id,
            "p_window_start": window_start, "p_window_end": window_end,
            "p_actor_id": _agent_user_id(),
            "p_idempotency_key": idempotency_key or _new_key(),
            "p_correlation_id": correlation_id,
        })
        return {
            "result": "ok", "document_id": data["document_id"], "status": data["status"],
            "version": data["version"], "warnings": data["warnings"],
            "document": data,
            "links": {"batch_id": data["batch_id"],
                      "candidate_product_count": data["candidate_product_count"],
                      "included_product_count": data["included_product_count"],
                      "skipped_no_data_count": data["skipped_no_data_count"],
                      "class_counts": data["class_counts"]},
            "next_actions": data["next_actions"],
        }
    except WmsCommandError as exc:
        return _error_result(exc)


async def generate_slotting_recommendations(
    tenant_id: Annotated[str, Field(description="테넌트 UUID")],
    warehouse_id: Annotated[str, Field(description="창고 UUID")],
    velocity_batch_id: Annotated[str, Field(description="compute_sku_velocity가 돌려준 batch_id")],
    correlation_id: Annotated[Optional[str], Field(description="ProcessGPT process_instance_id 등 상관관계 ID")] = None,
    idempotency_key: Annotated[Optional[str], Field(description="재시도 시 동일 키 재사용")] = None,
    dry_run: Annotated[bool, Field(description="true면 실제 반영 없이 예상 결과만 반환")] = False,
) -> dict:
    """속도 스냅샷 배치를 등급 정책과 대조해 재배치 추천을 만든다 (분석, PROCESS_AGENT 가능).

    만들어지는 추천은 전부 PENDING이고, **사람이 승인하기 전에는 어떤 배정도
    바뀌지 않는다**. 이 도구는 에이전트가 호출해도 안전한 마지막 단계이고,
    다음 단계인 review_slotting_recommendation은 PROCESS_AGENT에게 FORBIDDEN이다.

    두 가지 사유 코드가 나온다:
      - RELOCATE_UNDERSERVED — 배정된 위치의 접근성 순위가 등급 상한을 넘었다.
      - UNASSIGNED_HIGH_VELOCITY — 등급은 나왔는데 배정 선언 자체가 없다.
        `current_location_id`가 null인 것은 데이터 누락이 아니라 "아무도 이 SKU를
        어디 뒀는지 선언한 적이 없다"는 사실이고, 그런 SKU야말로 가장 먼저
        슬롯팅이 필요하다.

    빠진 것들도 전부 세어서 돌려준다 — 조용히 사라지는 SKU는 없다:
      - `skipped_no_policy_classes` — 그 등급의 정책을 이 창고가 정의한 적이 없다.
        기본값을 발명해 거짓 추천을 만드는 대신 등급 이름을 그대로 내놓는다.
      - `skipped_already_optimal_count` — 이미 상한 안에 있다. 움직일 이유가 없다.
      - `skipped_open_recommendation_count` — 아직 사람 검토를 기다리는 추천이
        이미 있다. 정책을 고치고 다시 불러도 중복이 쌓이지 않는다.
      - `skipped_no_target_location_count` — 상한을 만족하는 ACTIVE 위치가 없다.

    대상 위치는 "상한을 만족하는 ACTIVE 위치" 중에서 ① 아무도 배정되지 않은 곳,
    ② 다른 추천이 아직 노리지 않는 곳, ③ 접근성이 가장 좋은 곳 순으로 고른다.
    한 배치가 같은 자리를 여러 SKU에 동시에 추천하지 않게 하려는 것이고, 용량은
    보지 않는다(이 계약에 용량 엔진이 없다).
    """
    if dry_run:
        return {"result": "dry_run", "would_call": "wms_generate_slotting_recommendations",
                "input": {"warehouse_id": warehouse_id, "velocity_batch_id": velocity_batch_id}}
    try:
        data = _call_rpc("wms_generate_slotting_recommendations", {
            "p_tenant_id": tenant_id, "p_warehouse_id": warehouse_id,
            "p_velocity_batch_id": velocity_batch_id,
            "p_actor_id": _agent_user_id(),
            "p_idempotency_key": idempotency_key or _new_key(),
            "p_correlation_id": correlation_id,
        })
        return {
            "result": "ok", "document_id": data["document_id"], "status": data["status"],
            "version": data["version"], "warnings": data["warnings"],
            "document": data,
            "links": {"batch_id": data["batch_id"],
                      "generated_count": data["generated_count"],
                      "skipped_no_policy_classes": data["skipped_no_policy_classes"],
                      "skipped_already_optimal_count": data["skipped_already_optimal_count"],
                      "skipped_open_recommendation_count": data["skipped_open_recommendation_count"],
                      "skipped_no_target_location_count": data["skipped_no_target_location_count"],
                      "recommendations": data["recommendations"]},
            # D6: the next step belongs to a human, and the RPC enforces it.
            "next_actions": data["next_actions"],
        }
    except WmsCommandError as exc:
        return _error_result(exc)


async def review_slotting_recommendation(
    recommendation_id: Annotated[str, Field(description="재배치 추천 UUID")],
    decision: Annotated[str, Field(description="APPROVE 또는 REJECT")],
    expected_version: Annotated[int, Field(description="추천의 낙관적 동시성 버전")],
    review_reason: Annotated[Optional[str], Field(description="반려 사유 등 검토 메모")] = None,
    correlation_id: Annotated[Optional[str], Field(description="ProcessGPT process_instance_id 등 상관관계 ID")] = None,
    idempotency_key: Annotated[Optional[str], Field(description="재시도 시 동일 키 재사용")] = None,
    dry_run: Annotated[bool, Field(description="true면 실제 반영 없이 예상 결과만 반환")] = False,
) -> dict:
    """재배치 추천을 승인하거나 반려한다 — **사람 전용(WMS_ADMIN / WAREHOUSE_MANAGER)**.

    이 도구는 에이전트 tool 허용 목록에 **넣지 않는다**. 추천을 만드는 것은
    원장을 읽어 통계를 내는 분석이지만, 그 추천을 승인하는 것은 지게차가 실제로
    움직이게 만드는 운영 판단이다. PROCESS_AGENT로 호출하면 RPC가 FORBIDDEN을
    돌려준다(허용 목록에서 빠뜨려도 DB에 안전망이 있다). INBOUND_OPERATOR도
    검토는 할 수 없다 — 옮기라고 결정하는 것과 옮겼다고 기록하는 것은 다른
    일이고, 후자만 현장의 몫이다.

    승인해도 배정은 아직 그대로다(ASSIGNMENT_UNCHANGED_UNTIL_APPLIED). 실제
    반영은 apply_slotting_recommendation이 따로 한다 — "승인은 했지만 야간 작업
    윈도우에 옮긴다"를 표현할 수 있어야 하고, 승인 시점과 적용 시점이 감사에
    따로 남아야 하기 때문이다.

    PENDING이 아닌 추천을 다시 검토하면 INVALID다.
    """
    if dry_run:
        return {"result": "dry_run", "would_call": "wms_review_slotting_recommendation",
                "input": {"recommendation_id": recommendation_id, "decision": decision}}
    try:
        data = _call_rpc("wms_review_slotting_recommendation", {
            "p_recommendation_id": recommendation_id, "p_decision": decision,
            "p_actor_id": _agent_user_id(),
            "p_idempotency_key": idempotency_key or _new_key(),
            "p_expected_version": expected_version,
            "p_review_reason": review_reason, "p_correlation_id": correlation_id,
        })
        return {
            "result": "ok", "document_id": data["document_id"], "status": data["status"],
            "version": data["version"], "warnings": data["warnings"],
            "links": {"recommendation_id": data["recommendation_id"],
                      "product_id": data["product_id"], "decision": data["decision"],
                      "reviewed_by": data["reviewed_by"], "reviewed_at": data["reviewed_at"],
                      "review_reason": data["review_reason"]},
            "next_actions": data["next_actions"],
        }
    except WmsCommandError as exc:
        return _error_result(exc)


async def apply_slotting_recommendation(
    recommendation_id: Annotated[str, Field(description="APPROVED 상태의 재배치 추천 UUID")],
    expected_version: Annotated[int, Field(description="추천의 낙관적 동시성 버전")],
    correlation_id: Annotated[Optional[str], Field(description="ProcessGPT process_instance_id 등 상관관계 ID")] = None,
    idempotency_key: Annotated[Optional[str], Field(description="재시도 시 동일 키 재사용")] = None,
    dry_run: Annotated[bool, Field(description="true면 실제 반영 없이 예상 결과만 반환")] = False,
) -> dict:
    """승인된 추천을 실제 SKU-위치 배정에 반영한다 — 사람 전용(관리자 또는 현장 담당자).

    배정 갱신(없으면 신규 생성)과 추천의 APPLIED 전이가 한 트랜잭션으로
    처리된다. UNASSIGNED_HIGH_VELOCITY 추천이었다면 배정 레코드가 새로 생기고,
    응답의 `assignment_created`가 true다.

    **APPLIED는 "기록이 바뀌었다"는 뜻이지 "물건이 옮겨졌다"는 뜻이 아니다.**
    이 계약은 지게차 작업을 배정하지도, 이동 완료 스캔을 확인하지도 않는다 —
    응답에 항상 RECORD_ONLY_NO_PHYSICAL_MOVE_VERIFIED 경고가 붙는 이유다.
    실제로 옮기는 일은 사람이 하고, 옮기지 않았는데 적용하면 배정 레코드와
    현실이 어긋난 채로 남는다(이 계약은 그 어긋남을 감지하지 못한다).

    APPROVED가 아닌 추천은 INVALID다 — 승인 없이 배정이 바뀌는 경로는 없다.
    승인 이후에 대상 위치가 INACTIVE로 바뀌었다면 그것도 INVALID다.
    PROCESS_AGENT는 호출할 수 없고, 허용 목록에도 넣지 않는다.
    """
    if dry_run:
        return {"result": "dry_run", "would_call": "wms_apply_slotting_recommendation",
                "input": {"recommendation_id": recommendation_id}}
    try:
        data = _call_rpc("wms_apply_slotting_recommendation", {
            "p_recommendation_id": recommendation_id,
            "p_actor_id": _agent_user_id(),
            "p_idempotency_key": idempotency_key or _new_key(),
            "p_expected_version": expected_version, "p_correlation_id": correlation_id,
        })
        return {
            "result": "ok", "document_id": data["document_id"], "status": data["status"],
            "version": data["version"], "warnings": data["warnings"],
            "links": {"recommendation_id": data["recommendation_id"],
                      "product_id": data["product_id"],
                      "assignment_id": data["assignment_id"],
                      "assignment_created": data["assignment_created"],
                      "assignment_version": data["assignment_version"],
                      "location_id": data["location_id"],
                      "location_code": data["location_code"],
                      "accessibility_rank": data["accessibility_rank"],
                      "applied_at": data["applied_at"]},
            "next_actions": data["next_actions"],
        }
    except WmsCommandError as exc:
        return _error_result(exc)


# ============================================================
# Agentic operations (openspec change add-agentic-operations).
#
# These eight tools are the contract an EXTERNAL agent uses — there is no agent
# inside the WMS. Four read signals, two file what the agent thought, two are
# the human review gate and are deliberately NOT in the PROCESS_AGENT allowlist
# (docs/03-processgpt-integration.md; the DB refuses them anyway).
# ============================================================


async def get_labor_balance_signals(
    tenant_id: Annotated[str, Field(description="테넌트 UUID")],
    warehouse_id: Annotated[str, Field(description="창고 UUID")],
    period_start: Annotated[Optional[str], Field(description="관찰 시작 시각 (ISO8601). 미지정 시 24시간 전")] = None,
    period_end: Annotated[Optional[str], Field(description="관찰 종료 시각 (ISO8601, 미포함). 미지정 시 현재")] = None,
) -> dict:
    """작업자별 완료 건수와 창고 평균 대비 편차를 조회한다 (읽기 전용, Labor Agent의 관찰 신호).

    **이 도구는 `get_labor_productivity`와 다르다.** 후자는 비관리자 호출자에게
    `scope='SELF'`로 본인 행만 돌려주므로, 에이전트가 그것으로 "누가 상대적으로
    많이/적게 하고 있는가"를 판단할 방법이 없다. 인력 불균형은 본질적으로 여러
    작업자를 비교하는 질문이라, 이 신호 **하나에 한해서만** PROCESS_AGENT에게
    창고 전체 비교 결과를 연다(design.md D2의 의도적이고 좁은 예외). 원본 활동
    행이나 리더보드에 대한 접근권은 그대로 닫혀 있고, 이 신호를 보고 실제로
    재배치를 실행할 권한도 없다 — 볼 수 있는 것과 할 수 있는 것을 분리했다.

    `is_imbalanced`는 `deviation_ratio`의 절댓값이 `imbalance_threshold`(0.40)
    이상일 때 참이다. 임계값과 평균이 응답에 함께 오므로 판정을 직접 재계산해
    검증할 수 있다. `deviation_ratio`는 **부호가 있다** — -1.0(아무것도 안 함)과
    +2.0(평균의 세 배)은 정반대의 문제이고, 재배치 제안은 어느 쪽인지 알아야
    한다. `direction`이 ABOVE/BELOW/AT로 같은 말을 한 번 더 한다.

    `notes`를 읽어라. 기간에 완료된 활동이 없으면
    `NO_COMPLETED_LABOR_ACTIVITY_IN_PERIOD`, 작업자가 한 명뿐이면
    `SINGLE_WORKER_NO_COMPARISON`이 온다 — 후자는 "균형이 맞다"가 아니라
    "비교 자체가 성립하지 않는다"는 뜻이다.

    취소된 활동과 진행 중인 활동은 어떤 숫자에도 들어가지 않는다(area 8의 집계
    규칙 그대로). 관리자/관리자급 역할과 PROCESS_AGENT만 호출할 수 있고, 그
    외 역할은 FORBIDDEN이다.
    """
    try:
        params = {"p_tenant_id": tenant_id, "p_warehouse_id": warehouse_id}
        if period_start is not None:
            params["p_period_start"] = period_start
        if period_end is not None:
            params["p_period_end"] = period_end
        data = _call_rpc("wms_get_labor_balance_signals", params)
        return {
            "result": "ok", "document": data,
            "links": {"scope": data["scope"],
                      "worker_count": data["worker_count"],
                      "mean_completed_count": data["mean_completed_count"],
                      "imbalance_threshold": data["imbalance_threshold"],
                      "imbalanced_count": data["imbalanced_count"],
                      "notes": data["notes"]},
            "next_actions": ["propose_agent_action", "log_agent_decision"],
        }
    except WmsCommandError as exc:
        return _error_result(exc)


async def get_dispatch_delay_signals(
    tenant_id: Annotated[str, Field(description="테넌트 UUID")],
    warehouse_id: Annotated[str, Field(description="창고 UUID")],
    wave_id: Annotated[Optional[str], Field(description="특정 웨이브로 한정 (선택)")] = None,
    delay_threshold_minutes: Annotated[int, Field(description="이 분(minute) 이상 QUEUED로 대기한 업무 오더만 반환. 기본 15")] = 15,
) -> dict:
    """지연된 업무 오더와 그 지연의 원인을 함께 조회한다 (읽기 전용, Wave Coordinator Agent의 관찰 신호).

    "왜 아직 안 나갔는가"를 한 번의 호출로 답하는 것이 목적이다. 업무 오더 하나
    하나에 대해 그 오더의 **후보 설비 집합**을 실제 선택 로직과 똑같은 조건으로
    계산해서(설비 유형 일치, 구역 일치 또는 오더의 구역이 null이면 창고 전체,
    강제 제외는 하드 필터, IDLE + 미처리 명령 없음이 배차 가능) 개수와 병목
    판정을 붙여 돌려준다. `get_equipment_routing_status`를 따로 호출해 맞춰 볼
    필요가 없다.

    **`delay_causes`는 배열이고, 하나가 아닐 수 있다** — 구역에 IDLE 설비가
    없으면서 동시에 유일한 설비가 병목일 수 있기 때문이다:
      - `NO_EQUIPMENT_REGISTERED` — 그 유형/구역에 설비가 아예 없다.
      - `ALL_CANDIDATES_EXCLUDED` — 후보가 전부 사람에 의해 라우팅에서 제외됐다.
      - `NO_IDLE_EQUIPMENT` — 지금 배차 가능한 설비가 하나도 없다.
      - `ALL_ROUTABLE_CANDIDATES_BOTTLENECKED` / `BOTTLENECK_AMONG_CANDIDATES`
      - `WAVE_NOT_RELEASED` — **이건 지연이 아니다.** 웨이브가 아직 OPEN이라
        나갈 차례가 아닌 것뿐이다. 이 원인만 붙은 오더에 재시도를 거는 것은
        아무 효과가 없다; 필요한 것은 `release_dispatch_wave`다.

    대기 시간은 생성 시각이 아니라 **마지막 시도 시각**(`queued_since`)부터
    센다 — 재시도가 실패하면 그 시각이 갱신되므로, "또 재시도할 만한가"를
    판단하는 데 필요한 숫자가 그쪽이기 때문이다. 총 경과 시간은 `age_minutes`로
    따로 온다.

    이 신호를 보고 `retry_work_order_dispatch`를 직접 호출하는 것은 허용된다
    (기존 계약이 이미 PROCESS_AGENT에게 연 액션이다). 그때는
    `log_agent_decision`으로 근거를 남기고, 같은 `correlation_id`를 쓰면 감사
    로그에서 두 사실이 이어진다. 반면 설비 강제 제외나 라우팅 정책 변경은
    사람의 판단이므로 `propose_agent_action`으로 제안만 만들어야 한다.
    """
    try:
        data = _call_rpc("wms_get_dispatch_delay_signals", {
            "p_tenant_id": tenant_id, "p_warehouse_id": warehouse_id,
            "p_wave_id": wave_id,
            "p_delay_threshold_minutes": delay_threshold_minutes,
        })
        return {
            "result": "ok", "document": data,
            "links": {"delay_threshold_minutes": data["delay_threshold_minutes"],
                      "queued_work_order_count": data["queued_work_order_count"],
                      "delayed_work_order_count": data["delayed_work_order_count"],
                      "notes": data["notes"]},
            "next_actions": ["retry_work_order_dispatch", "log_agent_decision",
                             "propose_agent_action"],
        }
    except WmsCommandError as exc:
        return _error_result(exc)


async def get_worker_next_actions(
    tenant_id: Annotated[str, Field(description="테넌트 UUID")],
    warehouse_id: Annotated[str, Field(description="창고 UUID")],
    actor_id: Annotated[str, Field(description="대상 작업자의 사용자 UUID")],
    include_closed: Annotated[bool, Field(description="true면 종결된 항목도 포함. 기본 false")] = False,
) -> dict:
    """한 작업자가 관여한 미종결 항목과 각각의 유효한 다음 액션을 조회한다 (읽기 전용, Associate Agent의 재료).

    Manhattan Active WM의 Associate Agent가 하는 "작업자 온디바이스 가이던스"에
    해당하는 **재료**를 제공한다 — 자연어로 풀어 설명하는 것과 화면에 띄우는
    것은 ProcessGPT/프론트엔드의 몫이고, 이 도구는 구조화된 데이터만 준다.

    `next_actions`는 발명한 목록이 아니라 core schema의 RPC들이 그 상태에서
    **실제로 받아 주는** 전이다: EXPECTED→register_arrival, ARRIVED→receive,
    QC_PENDING→record_quality_result, QC_COMPLETED→apply_disposition,
    PUTAWAY_PENDING→create_putaway_tasks. PUTAWAY_COMPLETED는 종결이라 기본
    조회에서 빠진다.

    `wms.receipts`에는 담당자 컬럼이 없다. "관여"는 감사 이벤트·품질 판정·
    폐기 판정·인력 활동 네 곳의 합집합으로 유도하며, 어느 경로로 걸렸는지
    `involvement_sources`가 그대로 알려 준다 — 불투명한 필터를 믿게 하지
    않으려는 것이다. 관여한 항목이 없으면 오류가 아니라 빈 결과와
    `NO_OPEN_ITEMS_FOR_ACTOR` note가 온다.
    """
    try:
        data = _call_rpc("wms_get_worker_next_actions", {
            "p_tenant_id": tenant_id, "p_warehouse_id": warehouse_id,
            "p_actor_id": actor_id, "p_include_closed": include_closed,
        })
        return {
            "result": "ok", "document": data,
            "links": {"actor_id": data["actor_id"], "row_count": data["row_count"],
                      "notes": data["notes"]},
            "next_actions": ["get_agent_decisions"],
        }
    except WmsCommandError as exc:
        return _error_result(exc)


async def get_agent_decisions(
    tenant_id: Annotated[str, Field(description="테넌트 UUID")],
    warehouse_id: Annotated[str, Field(description="창고 UUID")],
    status: Annotated[Optional[str], Field(description="LOGGED / PROPOSED / CONFIRMED / REJECTED 중 하나로 필터 (선택)")] = None,
    proposal_type: Annotated[Optional[str], Field(description="제안 유형으로 필터 (선택)")] = None,
) -> dict:
    """에이전트 판단·제안 이력을 조회한다 (읽기 전용).

    한 테이블에 두 종류가 함께 산다. `status='LOGGED'`는 "이미 허용된 액션을
    했고 이유는 이렇다"는 상태 없는 기록이고, `PROPOSED`/`CONFIRMED`/`REJECTED`
    는 사람의 검토를 거치는 제안의 생명주기다. `is_proposal`과
    `awaiting_review`가 각 행에서 둘을 구분해 준다.

    `status_counts`와 `pending_review_count`는 **필터와 무관하게 창고 전체**를
    센다 — `status='PROPOSED'`로 좁혀 보면서도 뒤에 얼마나 많은 이력이 쌓여
    있는지 알 수 있게 하기 위해서다.

    자기가 남긴 판단을 다시 읽어 중복 제안을 피하는 데 쓸 수 있다. 승인/거부는
    이 도구로 하지 않는다 — 사람 전용이다.
    """
    try:
        data = _call_rpc("wms_get_agent_decisions", {
            "p_tenant_id": tenant_id, "p_warehouse_id": warehouse_id,
            "p_status": status, "p_proposal_type": proposal_type,
        })
        return {
            "result": "ok", "document": data,
            "links": {"row_count": data["row_count"],
                      "status_counts": data["status_counts"],
                      "pending_review_count": data["pending_review_count"]},
            "next_actions": ["log_agent_decision", "propose_agent_action"],
        }
    except WmsCommandError as exc:
        return _error_result(exc)


async def log_agent_decision(
    tenant_id: Annotated[str, Field(description="테넌트 UUID")],
    warehouse_id: Annotated[str, Field(description="창고 UUID")],
    reasoning: Annotated[str, Field(description="자연어 판단 근거. 빈 문자열이면 INVALID")],
    proposal_type: Annotated[str, Field(description="판단 유형. 기본 DISPATCH_RETRY (열린 집합)")] = "DISPATCH_RETRY",
    target_entity_type: Annotated[Optional[str], Field(description="대상 종류 (예: work_order, equipment, actor)")] = None,
    target_entity_id: Annotated[Optional[str], Field(description="대상 UUID. target_entity_type과 함께 줘야 한다")] = None,
    signals_snapshot: Annotated[Optional[dict], Field(description="판단 근거가 된 신호 RPC 응답을 그대로 보존")] = None,
    correlation_id: Annotated[Optional[str], Field(description="자율 실행한 액션의 audit 이벤트와 이어 줄 상관관계 ID")] = None,
    idempotency_key: Annotated[Optional[str], Field(description="재시도 시 동일 키 재사용")] = None,
    dry_run: Annotated[bool, Field(description="true면 실제 반영 없이 예상 결과만 반환")] = False,
) -> dict:
    """이미 자율 실행한 액션의 판단 근거를 남긴다 (PROCESS_AGENT 가능).

    **이 도구는 아무것도 실행하지 않는다.** 순서는 항상 "허용된 RPC를 먼저
    호출하고, 그 다음 왜 그랬는지 여기에 남긴다"이다. `retry_work_order_dispatch`
    를 부른 것과 같은 `correlation_id`를 넘겨라 — 그러면 감사 로그에서 "무엇을
    했는가"(audit 이벤트)와 "왜 했는가"(이 기록)가 한 줄로 이어진다. 그것이
    이 도구의 존재 이유 전부다.

    `reasoning`은 필수이고 공백만 있으면 INVALID다. 사람이 몇 달 뒤에 읽는다는
    전제로 써라 — "임계값 초과"가 아니라 "32분간 QUEUED였고 해당 구역의 유일한
    AGV가 30분 내 장애 1건으로 병목 판정되어 재시도했다"처럼. `signals_snapshot`
    에 신호 응답을 그대로 넣어 두면 그때 무엇을 보고 있었는지가 재현된다.

    이렇게 남긴 기록은 **append-only**다. 상태가 바뀌지 않고, 승인/거부 대상도
    아니다 — 이미 일어난 일에 대한 진술이기 때문이다. 사람의 결정이 필요한
    조치라면 이 도구가 아니라 `propose_agent_action`을 써야 한다.
    """
    if dry_run:
        return {"result": "dry_run", "would_call": "wms_log_agent_decision",
                "input": {"warehouse_id": warehouse_id, "proposal_type": proposal_type,
                          "reasoning": reasoning}}
    try:
        data = _call_rpc("wms_log_agent_decision", {
            "p_tenant_id": tenant_id, "p_warehouse_id": warehouse_id,
            "p_reasoning": reasoning, "p_actor_id": _agent_user_id(),
            "p_idempotency_key": idempotency_key or _new_key(),
            "p_proposal_type": proposal_type,
            "p_target_entity_type": target_entity_type,
            "p_target_entity_id": target_entity_id,
            "p_signals_snapshot": signals_snapshot,
            "p_correlation_id": correlation_id,
        })
        return {
            "result": "ok", "document_id": data["document_id"], "status": data["status"],
            "version": data["version"], "warnings": data["warnings"],
            "links": {"decision_id": data["decision_id"],
                      "proposal_type": data["proposal_type"],
                      "correlation_id": data["correlation_id"]},
            "next_actions": data["next_actions"],
        }
    except WmsCommandError as exc:
        return _error_result(exc)


async def propose_agent_action(
    tenant_id: Annotated[str, Field(description="테넌트 UUID")],
    warehouse_id: Annotated[str, Field(description="창고 UUID")],
    proposal_type: Annotated[str, Field(description="제안 유형. 예: LABOR_REBALANCE, EQUIPMENT_ROUTING_SUGGESTION (열린 집합)")],
    reasoning: Annotated[str, Field(description="자연어 판단 근거. 빈 문자열이면 INVALID")],
    proposed_action: Annotated[dict, Field(description="제안하는 조치의 구조화된 설명(호출할 RPC 이름, 파라미터 후보 등). 비어 있으면 INVALID")],
    target_entity_type: Annotated[Optional[str], Field(description="대상 종류 (예: equipment, actor)")] = None,
    target_entity_id: Annotated[Optional[str], Field(description="대상 UUID. target_entity_type과 함께 줘야 한다")] = None,
    signals_snapshot: Annotated[Optional[dict], Field(description="제안 근거가 된 신호 RPC 응답을 그대로 보존")] = None,
    correlation_id: Annotated[Optional[str], Field(description="ProcessGPT process_instance_id 등 상관관계 ID")] = None,
    idempotency_key: Annotated[Optional[str], Field(description="재시도 시 동일 키 재사용")] = None,
    dry_run: Annotated[bool, Field(description="true면 실제 반영 없이 예상 결과만 반환")] = False,
) -> dict:
    """자율 실행이 허용되지 않은 조치를 사람이 검토할 제안으로 만든다 (PROCESS_AGENT 가능).

    **제안을 만드는 것은 실행이 아니다.** `wms.agent_decisions`에
    `status='PROPOSED'` 행이 하나 생길 뿐, 다른 어떤 WMS 테이블도 바뀌지
    않는다. 그래서 이 도구는 에이전트에게 열려 있고, 다음 단계인
    `confirm_agent_proposal`/`reject_agent_proposal`은 열려 있지 않다.

    언제 이 도구를 쓰는가 — **실행 RPC가 사람 전용으로 막혀 있거나, 실행 RPC가
    아예 없을 때**다:
      - `LABOR_REBALANCE` — 인력 재배치 RPC는 이 저장소에 존재하지 않는다.
        불균형을 발견했다면 제안이 유일한 출구이고, 승인 뒤에도 실제 조치는
        사람이 수동으로 한다.
      - `EQUIPMENT_ROUTING_SUGGESTION` — `exclude_equipment_from_routing`과
        `register_wcs_routing_policy`는 사람의 운영 판단이라 계속 막혀 있다.
        제안에 그 RPC 이름과 파라미터 후보를 담아 두면 사람이 그대로 실행할 수
        있다.

    `proposed_action`은 필수이고 `{}`나 `[]`도 비어 있는 것으로 본다 — 조치가
    없는 제안은 검토할 수 없기 때문이다. 사람이 읽고 그대로 실행할 수 있을
    만큼 구체적으로 써라(`suggested_rpc`, 파라미터, 실행 RPC가 없다면 그 사실).

    **승인되어도 시스템이 자동 실행하지 않는다** — 응답의
    `HUMAN_REVIEW_REQUIRED_NO_AUTO_EXECUTION` 경고가 그 뜻이다. 승인은 상태
    전이일 뿐이고, 그 다음 호출은 사람이나 다음 BPMN 스텝이 명시적으로 한다.
    """
    if dry_run:
        return {"result": "dry_run", "would_call": "wms_propose_agent_action",
                "input": {"warehouse_id": warehouse_id, "proposal_type": proposal_type,
                          "proposed_action": proposed_action}}
    try:
        data = _call_rpc("wms_propose_agent_action", {
            "p_tenant_id": tenant_id, "p_warehouse_id": warehouse_id,
            "p_proposal_type": proposal_type, "p_reasoning": reasoning,
            "p_proposed_action": proposed_action,
            "p_actor_id": _agent_user_id(),
            "p_idempotency_key": idempotency_key or _new_key(),
            "p_target_entity_type": target_entity_type,
            "p_target_entity_id": target_entity_id,
            "p_signals_snapshot": signals_snapshot,
            "p_correlation_id": correlation_id,
        })
        return {
            "result": "ok", "document_id": data["document_id"], "status": data["status"],
            "version": data["version"], "warnings": data["warnings"],
            "links": {"decision_id": data["decision_id"],
                      "proposal_type": data["proposal_type"],
                      "correlation_id": data["correlation_id"]},
            # both of these are human-only; the agent files the proposal and stops
            "next_actions": data["next_actions"],
        }
    except WmsCommandError as exc:
        return _error_result(exc)


async def confirm_agent_proposal(
    decision_id: Annotated[str, Field(description="에이전트 제안 UUID")],
    expected_version: Annotated[int, Field(description="제안의 낙관적 동시성 버전")],
    correlation_id: Annotated[Optional[str], Field(description="ProcessGPT process_instance_id 등 상관관계 ID")] = None,
    idempotency_key: Annotated[Optional[str], Field(description="재시도 시 동일 키 재사용")] = None,
    dry_run: Annotated[bool, Field(description="true면 실제 반영 없이 예상 결과만 반환")] = False,
) -> dict:
    """에이전트 제안을 승인한다 — **사람 전용(WAREHOUSE_MANAGER / WMS_ADMIN)**.

    이 도구는 에이전트 tool 허용 목록에 **넣지 않는다**. 제안을 만드는 것과
    그것을 승인하는 것을 갈라놓는 것이 이 계약의 전부이므로, 같은 주체가 둘 다
    하면 계약이 사라진다. PROCESS_AGENT로 호출하면 RPC가 FORBIDDEN을 돌려준다
    (허용 목록에서 빠뜨려도 DB에 안전망이 있다).

    **승인은 상태 플래그일 뿐, 제안된 조치를 실행하지 않는다** — 응답의
    `CONFIRMED_BUT_NOT_EXECUTED` 경고가 그 뜻이다. `proposed_action`에 적힌
    RPC를 찾아 호출하는 디스패치 로직은 일부러 만들지 않았다. 그런 것은 그
    자체로 자율 실행 루프이고, 이 계약이 피하려는 구조를 되살리는 일이기
    때문이다. 승인 뒤 실제 조치는 사람이 직접 하거나 다음 BPMN 스텝이 명시적으로
    호출한다.

    PROPOSED가 아닌 제안(이미 승인/거부됨, 또는 애초에 LOGGED 기록)은 INVALID다.
    """
    if dry_run:
        return {"result": "dry_run", "would_call": "wms_confirm_agent_proposal",
                "input": {"decision_id": decision_id}}
    try:
        data = _call_rpc("wms_confirm_agent_proposal", {
            "p_decision_id": decision_id, "p_actor_id": _agent_user_id(),
            "p_idempotency_key": idempotency_key or _new_key(),
            "p_expected_version": expected_version, "p_correlation_id": correlation_id,
        })
        return {
            "result": "ok", "document_id": data["document_id"], "status": data["status"],
            "version": data["version"], "warnings": data["warnings"],
            "links": {"decision_id": data["decision_id"],
                      "confirmed_by": data["confirmed_by"],
                      "confirmed_at": data["confirmed_at"],
                      "proposed_action": data["proposed_action"]},
            "next_actions": data["next_actions"],
        }
    except WmsCommandError as exc:
        return _error_result(exc)


async def reject_agent_proposal(
    decision_id: Annotated[str, Field(description="에이전트 제안 UUID")],
    reason: Annotated[str, Field(description="반려 사유. 필수 — 빈 문자열이면 INVALID")],
    expected_version: Annotated[int, Field(description="제안의 낙관적 동시성 버전")],
    correlation_id: Annotated[Optional[str], Field(description="ProcessGPT process_instance_id 등 상관관계 ID")] = None,
    idempotency_key: Annotated[Optional[str], Field(description="재시도 시 동일 키 재사용")] = None,
    dry_run: Annotated[bool, Field(description="true면 실제 반영 없이 예상 결과만 반환")] = False,
) -> dict:
    """에이전트 제안을 반려한다 — **사람 전용(WAREHOUSE_MANAGER / WMS_ADMIN)**.

    승인과 마찬가지로 에이전트 tool 허용 목록에서 **제외**한다. PROCESS_AGENT로
    호출하면 FORBIDDEN이다.

    `reason`은 필수다. 반려 사유는 다음 번에 에이전트가 같은 제안을 다시 만들지
    않도록 하는 유일한 피드백 경로이고(이 저장소에는 학습 루프가 없으므로
    사람이 읽고 프롬프트를 고치는 것이 그 경로다), 감사 기록에도 그대로 남는다.
    "안 됨"이 아니라 왜 안 되는지를 써라.

    PROPOSED가 아닌 제안은 INVALID다.
    """
    if dry_run:
        return {"result": "dry_run", "would_call": "wms_reject_agent_proposal",
                "input": {"decision_id": decision_id, "reason": reason}}
    try:
        data = _call_rpc("wms_reject_agent_proposal", {
            "p_decision_id": decision_id, "p_reason": reason,
            "p_actor_id": _agent_user_id(),
            "p_idempotency_key": idempotency_key or _new_key(),
            "p_expected_version": expected_version, "p_correlation_id": correlation_id,
        })
        return {
            "result": "ok", "document_id": data["document_id"], "status": data["status"],
            "version": data["version"], "warnings": data["warnings"],
            "links": {"decision_id": data["decision_id"],
                      "rejected_by": data["rejected_by"],
                      "rejected_at": data["rejected_at"],
                      "rejection_reason": data["rejection_reason"]},
            "next_actions": data["next_actions"],
        }
    except WmsCommandError as exc:
        return _error_result(exc)


# ============================================================
# Natural-language operations audit log (wms_operations-audit-log,
# 20260806_operations_audit_log.sql).
#
# These two tools are DELIBERATELY ABSENT from the PROCESS_AGENT allowlist in
# docs/03-processgpt-integration.md, and they are the only tools in this file
# that sign in as a third identity. Every other read tool here exists so the
# agent can decide what to do next. These exist so a human can check what the
# agent already did — including reading the agent's own `reasoning` next to the
# action it justified. Handing the agent its own audit trail would collapse
# that distinction, so the tools authenticate as AUDITOR and the database
# refuses PROCESS_AGENT even if the allowlist is edited by mistake.
# ============================================================


async def query_audit_log(
    tenant_id: Annotated[str, Field(description="테넌트 UUID")],
    date_from: Annotated[Optional[str], Field(description="조회 시작 시각 (ISO 8601). 생략하면 처음부터")] = None,
    date_to: Annotated[Optional[str], Field(description="조회 종료 시각 (ISO 8601, 경계 포함). 생략하면 현재까지")] = None,
    actor_id: Annotated[Optional[str], Field(description="행위자 사용자 UUID로 필터")] = None,
    entity_type: Annotated[Optional[str], Field(description="엔티티 종류로 필터. 예: purchase_order, receipt, dock, equipment_command")] = None,
    entity_id: Annotated[Optional[str], Field(description="특정 엔티티 UUID로 필터 — 한 건의 전체 이력을 볼 때")] = None,
    command: Annotated[Optional[str], Field(description="명령 이름으로 필터. 예: wms_confirm_purchase_order")] = None,
    correlation_id: Annotated[Optional[str], Field(description="상관관계 ID로 필터 — 한 프로세스 인스턴스가 남긴 전부를 한 줄로 잇는다")] = None,
    limit: Annotated[int, Field(description="페이지 크기. 기본 50, 최대 500")] = 50,
    offset: Annotated[int, Field(description="페이지 오프셋. 기본 0")] = 0,
) -> dict:
    """감사 이벤트를 한국어 요약과 함께 필터링·페이지네이션해 조회한다 (읽기 전용, AUDITOR/WMS_ADMIN 전용).

    `wms.audit_events`는 이 저장소의 모든 쓰기 RPC가 남겨 온 구조화된 이력이다.
    이 도구는 거기에 아무것도 더 쓰지 않고, 두 가지를 얹어서 돌려준다:

      - `summary_ko` — `command`/`entity_type`/`before`/`after`를 결정론적
        템플릿으로 조립한 한국어 한 문장. LLM 호출이 아니라 Postgres 함수이므로
        같은 이벤트는 언제 읽어도 같은 문장이다.
      - `agent_reasoning` — 같은 `correlation_id`로 남은
        `wms.agent_decisions.reasoning`. 에이전트가 자율 실행한 액션이라면
        "무엇을 했는가"(감사 이벤트)와 "왜 했는가"(판단 근거)가 한 행에서 만난다.
        사람이 한 명령이면 이 값은 null이고 요약도 근거 문구 없이 나온다.

    `total_count`는 필터에 매칭되는 전체 건수이고 페이지를 넘어가도 유지된다 —
    마지막 페이지를 지나쳐도 총 건수를 잃지 않는다. `has_more`가 false가 될
    때까지 `offset`을 늘려 가면 된다.

    **이 도구는 PROCESS_AGENT 허용 목록에 없다.** 감사 로그는 에이전트를
    감시하는 쪽의 도구이고, RPC 자체가 `WMS_ADMIN`/`AUDITOR`만 받는다.
    """
    try:
        data = _call_rpc_as_auditor("wms_query_audit_log", {
            "p_tenant_id": tenant_id,
            "p_date_from": date_from, "p_date_to": date_to,
            "p_actor_id": actor_id, "p_entity_type": entity_type,
            "p_entity_id": entity_id, "p_command": command,
            "p_correlation_id": correlation_id,
            "p_limit": limit, "p_offset": offset,
        })
        return {
            "result": "ok", "document": data,
            "links": {"row_count": data["row_count"], "total_count": data["total_count"],
                      "page_count": data["page_count"], "has_more": data["has_more"],
                      "offset": data["offset"], "limit": data["limit"]},
            "next_actions": ["query_audit_log", "export_audit_log"],
        }
    except WmsCommandError as exc:
        return _error_result(exc)


async def export_audit_log(
    tenant_id: Annotated[str, Field(description="테넌트 UUID")],
    date_from: Annotated[Optional[str], Field(description="내보내기 시작 시각 (ISO 8601)")] = None,
    date_to: Annotated[Optional[str], Field(description="내보내기 종료 시각 (ISO 8601, 경계 포함)")] = None,
    actor_id: Annotated[Optional[str], Field(description="행위자 사용자 UUID로 필터")] = None,
    entity_type: Annotated[Optional[str], Field(description="엔티티 종류로 필터")] = None,
    entity_id: Annotated[Optional[str], Field(description="특정 엔티티 UUID로 필터")] = None,
    command: Annotated[Optional[str], Field(description="명령 이름으로 필터")] = None,
    correlation_id: Annotated[Optional[str], Field(description="상관관계 ID로 필터. 이번 내보내기 호출 자체의 상관관계 ID로도 기록된다")] = None,
    max_rows: Annotated[int, Field(description="안전 상한. 기본이자 최대 10000 — 낮출 수는 있어도 올릴 수는 없다")] = 10000,
) -> dict:
    """필터링된 감사 이벤트 전체를 한 번에 내보낸다 — CSV/보고서 생성용 (AUDITOR/WMS_ADMIN 전용).

    조회 도구와 필터는 같고 페이지네이션만 없다. 대신 두 가지가 다르다:

      1. **잘라내지 않고 거절한다.** 매칭 건수가 `max_rows`(기본 10,000)를
         넘으면 `INVALID`로 실패한다. 조용히 잘린 내보내기는 감사 자료로
         쓸 수 없기 때문이다 — 기간을 좁히거나 필터를 추가해서 다시 부르면
         된다.
      2. **이 호출 자체가 감사 대상이 된다.** 성공하면 `wms.audit_events`에
         `command='wms_export_audit_log'`, `entity_type='audit_export'`,
         `after`에 사용한 필터와 건수를 담은 행이 하나 남는다. 누가 언제 어떤
         조건으로 감사 로그를 내려받았는지도 다음 조회에서 그대로 보인다.
         결과 집합에는 그 행이 들어 있지 않고(결과를 확정한 뒤에 기록한다),
         다음 조회부터 보인다.

    실제 CSV 파일 생성은 호출자의 몫이다 — 이 도구는 `summary_ko`를 포함한
    행 배열까지만 돌려준다.

    **PROCESS_AGENT 허용 목록에 없다** (`query_audit_log`와 같은 이유).
    """
    try:
        data = _call_rpc_as_auditor("wms_export_audit_log", {
            "p_tenant_id": tenant_id,
            "p_date_from": date_from, "p_date_to": date_to,
            "p_actor_id": actor_id, "p_entity_type": entity_type,
            "p_entity_id": entity_id, "p_command": command,
            "p_correlation_id": correlation_id,
            "p_max_rows": max_rows,
        })
        return {
            "result": "ok", "document": data,
            "links": {"row_count": data["row_count"], "total_count": data["total_count"],
                      "max_rows": data["max_rows"],
                      "self_audit_event_id": data["self_audit_event_id"],
                      "exported_by": data["exported_by"]},
            "next_actions": ["query_audit_log"],
        }
    except WmsCommandError as exc:
        return _error_result(exc)
