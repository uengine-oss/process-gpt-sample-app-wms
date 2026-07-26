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

from .client import WmsCommandError, classify_error, get_authed_client

logger = logging.getLogger("wms_mcp")

mcp = FastMCP("process-gpt-wms-mcp")


def _new_key() -> str:
    return str(uuid.uuid4())


def _call_rpc(fn_name: str, params: dict) -> dict:
    client, _agent_user_id = get_authed_client()
    try:
        resp = client.rpc(fn_name, params).execute()
        return resp.data
    except Exception as exc:  # noqa: BLE001 - translated into a structured tool result below
        raise classify_error(exc) from exc


def _agent_user_id() -> str:
    _client, user_id = get_authed_client()
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
    tenant_id: Annotated[str, Field(description="테넌트 UUID")],
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
async def create_rfq(
    tenant_id: Annotated[str, Field(description="테넌트 UUID")],
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
