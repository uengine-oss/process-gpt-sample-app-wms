# 1.2–1.4 계약: BPMN 활동 ↔ RPC ↔ MCP 도구, Odoo 대체, 용어/스키마

> 데모 우선 핵심 수직 slice 범위로 작성. design.md §9~11의 전체 계약 중
> 이 슬라이스가 실제로 구현하는 부분만 확정하고, 나머지는 "범위 외(1차)"로 표시한다.

## 1.2 BPMN 활동 → RPC → MCP 도구 매핑

| # | BPMN 활동 | Postgres RPC | WMS MCP 도구 | 보상 명령 |
|---|---|---|---|---|
| 1 | 재고·수요 확인 | `wms_check_stock(tenant_id, warehouse_id, sku)` | `wms.inventory.get_availability` (읽기) | 없음 (읽기 전용) |
| 2 | 재보충 판단·RFQ 제안 | `wms_create_rfq(tenant_id, warehouse_id, sku, qty, supplier_ids, actor_id, idempotency_key)` | `wms.procurement.create_rfq` (쓰기) | `wms_cancel_rfq` |
| 3 | 발주 승인 (HITL) | `wms_submit_purchase_approval(rfq_id, decision, approver_id, expected_version)` | `wms.procurement.request_approval` (쓰기, `requires_human_approval` 반환) | 승인 취소는 상태 전이로 처리 (원장 영향 없음) |
| 4 | PO 확정 | `wms_confirm_purchase_order(rfq_id, actor_id, idempotency_key, expected_version)` | `wms.procurement.confirm_po` (쓰기) | `wms_cancel_purchase_order` |
| 5 | 하역장 접수(입하 도착) | `wms_register_arrival(po_id, actor_id, idempotency_key)` | `wms.inbound.register_arrival` (쓰기) | 상태 롤백(EXPECTED로 복귀) |
| 6 | 입고 검수(수량 등록) | `wms_receive(po_id, sku, qty, actor_id, idempotency_key, expected_version)` | `wms.inbound.receive` (쓰기) — 원장에 `RECEIVING` entry 기록 | `wms_reverse_receipt` (반대 방향 correction movement) |
| 7 | 품질 판정 | `wms_record_quality_result(receipt_id, sku, result, reason_code, actor_id, idempotency_key)` | `wms.quality.inspect` (쓰기) | 판정 재기록(새 entry, 기존 삭제 안 함) |
| 8a | 불합격 처분(폐기) | `wms_apply_disposition(receipt_id, sku, disposition='SCRAP', reason_code, actor_id, idempotency_key)` | `wms.inventory.scrap` (쓰기) | 없음 (폐기는 최종 상태) |
| 8b | 합격 처분(적치) | `wms_create_putaway_tasks(receipt_id, actor_id, idempotency_key)` | `wms.putaway.create_tasks` (쓰기) → 작업 완료 시 원장 `AVAILABLE` 반영 | `wms_cancel_putaway_task` |

### 범위 외 (1차 슬라이스에서 제외, design.md 원 계약 유지)

`wms.procurement.notify_supplier`, `wms.inventory.return_to_supplier`, `wms.documents.get_status`,
`wms.commands.compensate`(범용 보상), 출고·반품·실사·추적성 MCP 도구 전체 —
tasks.md 8장, 10.3(부분) 항목으로 이후 슬라이스에서 다룬다.

## 1.3 Odoo 대체 방식

실사 결과, 이 저장소 기준 "Odoo 연동"은 별도 서비스가 아니라
`services/completion`의 테넌트별 `mcp` 설정(JSONB, `tenants.mcp` 컬럼)에 등록된
**하나의 stdio MCP 서버 항목**(`python3 -m odoo_mcp`, `ODOO_URL/DB/USERNAME/PASSWORD` env)이다.
즉 "Odoo → WMS 전환"은 데이터 이관 문제라기보다 **테넌트 설정에서 MCP 서버 항목을
`odoo ERP`에서 `wms-mcp`(streamable-HTTP)로 교체하는 문제**다.

| Odoo 객체 | 신규 WMS 테이블 | 이 슬라이스 포함 여부 |
|---|---|---|
| `stock.quant` | `inventory_balances` (투영) | 포함 |
| `stock.move` | `stock_ledger_entries` | 포함 |
| `purchase.order` | `purchase_orders`, `rfqs` (RFQ와 PO를 하나의 상태 전이로 단순화) | 포함 |
| `stock.picking`(incoming) | `receipts` | 포함 |
| `stock.scrap` | `inventory_dispositions` (SCRAP) | 포함 |
| `stock.picking`(outgoing), package/LPN | — | 범위 외 (8장에서 다룸) |

**Odoo 실 데이터 이관(11.3~11.5, shadow run, cutover)은 이 슬라이스에 포함하지 않는다.**
이 저장소는 그린필드 데모이므로 시드 데이터로 시작한다.

## 1.4 용어집과 상태 enum (이 슬라이스 범위)

| 용어 | 정의 |
|---|---|
| RFQ | 구매 필요가 제안된 뒤, 승인 전 상태의 구매 요청 |
| PO | 승인된 RFQ가 확정된 구매 주문. 수량·가격·납기가 확정 |
| Receipt | 하나의 PO에 대한 입하 접수 및 검수 단위 |
| Disposition | 품질 판정 이후 재고 최종 처분(AVAILABLE/SCRAP) |
| Ledger entry | 위치·상품·상태별 signed quantity 불변 기록 (수정·삭제 없음) |

### 상태 enum (이 슬라이스)

```text
rfq_status:        DRAFT -> TO_APPROVE -> APPROVED -> CONFIRMED_PO
                                        -> REJECTED
                    CONFIRMED_PO -> CANCELLED

receipt_status:     EXPECTED -> ARRIVED -> RECEIVING -> RECEIVED
                    -> QC_PENDING -> QC_COMPLETED
                    -> PUTAWAY_PENDING -> PUTAWAY_COMPLETED

quality_result:     PASSED | FAILED

disposition_type:   AVAILABLE | SCRAP
```

### JSON Schema / OpenAPI

design.md §9.2의 공통 envelope(`tenant_id`, `warehouse_id`, `actor_id`, `idempotency_key`,
`expected_version`, `correlation_id`, `input`)를 그대로 따른다. 실제 JSON Schema는
`mcp/schemas/*.json`에 도구별로 정의한다(코드와 동일 파일에 두어 drift 방지).
